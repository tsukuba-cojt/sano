/// メッセージの保存・検索・優先度付け・削除（docs/02_protocol.md §4-3, §5）。
///
/// v2（docs/08）での変更点:
/// - 期限は「受信からの相対時間」で判定し、中継時に expires_at を残り時間に
///   書き換える（C12）。
/// - 未知の形式の封筒を「不透明メッセージ」として保存・中継する（C13）。
/// - 取り消し・書きなおしの適用は封筒の role が対象の role 以上のときだけ（C10）。
/// - 取り消された他人の notice は本文を消して空殻にする（C20）。
/// - 先出し候補、小さい MTU 向けの目録、役割を見る削除順（C08）。
///
/// 永続化は [StoreBackend] への追記型レコードで行い、更新・削除が溜まったら
/// 全置換（圧縮）する。レコード形式はこのファイル内で閉じている。
library;

import 'package:flutter/foundation.dart';

import '../core/envelope.dart';
import 'store_file.dart';

/// 中継しなくなる hop 数（これ以上は保存もしない）。
const int kMaxRelayHop = 64;

/// tombstone / 書きなおしを対象より長く保持する秒数（24 時間）。
const int kTombstoneGraceSeconds = 24 * 60 * 60;

/// 保存件数の既定上限。
const int kDefaultMaxMessages = 3000;

/// 在庫として送る msg_id の既定上限（保存上限と同じ、C08）。
const int kDefaultInventoryLimit = kDefaultMaxMessages;

/// maxChunk が小さいときの目録件数（受信時刻の新しい順、C08）。
const int kSmallChunkInventoryLimit = 300;

/// 不透明メッセージの端末内上限（件数。全体の 10% とも比べる、C13）。
const int kMaxOpaqueMessages = 300;

/// 1 グループあたりの住民投稿（role=0 の notice）の端末内上限（C08）。
const int kMaxResidentNoticesPerGroup = 500;

/// group_info の有効期間の上限（365 日 + 1 日の余裕）。
const int kMaxGroupInfoTtlSeconds = 366 * 24 * 60 * 60;

/// 先出し（PUSH）の上限（C08）。
const int kPushMaxCount = 16;
const int kPushMaxBytes = 8 * 1024;
const int kPushWindowSeconds = 24 * 60 * 60;

/// [MessageStore.add] の結果。
enum AddResult {
  /// 新規に保存した。
  added,

  /// 既に持っていた（msg_id 既知）。
  duplicate,

  /// 検証に失敗した、期限切れ、hop 超過など。
  rejected,
}

/// 保存されたメッセージ 1 件。
class StoredMessage {
  StoredMessage({
    required this._envelope,
    required this.receivedAt,
    this.isLocal = false,
    bool? read,
    this.supersededBy,
    this.retracted = false,
    this.retractedByOfficial = false,
    this.retainUntil,
  }) : read = read ?? isLocal;

  Envelope _envelope;

  /// 封筒。取り消しで本文を消すと空殻（[Envelope.isStub]）に置き換わる。
  Envelope get envelope => _envelope;

  /// この端末に届いた時刻（エポック秒）。自端末発信なら発信時刻。
  final int receivedAt;

  /// 自端末が発信したものか。
  final bool isLocal;

  /// 既読か（自端末発信は最初から既読）。
  bool read;

  /// 上書き（supersedes 付き notice）された場合、その notice の msg_id。
  int? supersededBy;

  /// tombstone で取り消されたか。
  bool retracted;

  /// 公式（role=2）の tombstone で、住民・スタッフの投稿が取り消されたか。
  bool retractedByOfficial;

  /// tombstone / 書きなおしを対象より長く保持するための期限（対象の実効期限 + 24 時間）。
  /// 対象を見たときに決まり、対象が消えた後も有効。
  int? retainUntil;

  Uint8List? _wireCache;

  int get msgId => _envelope.msgId;
  MessageKind get kind => _envelope.kind;
  int get groupId => _envelope.groupId;

  /// 未知の形式を生バイトのまま持つ不透明メッセージか。
  bool get isOpaque => _envelope.isOpaque;

  /// 本文を消した空殻か。
  bool get isStub => _envelope.isStub;

  /// 保存用のワイヤ形式（hop は保存時の値、expires_at は受け取った値）。結果はキャッシュする。
  Uint8List get wireBytes => _wireCache ??= _envelope.encode();

  /// 中継用のワイヤ形式。受信したものは expires_at を
  /// 「created_at + 残り時間」に書き換える（C12。msg_id は expires_at を含まない）。
  Uint8List wireBytesAt(int now, {required int localExpiresAt}) {
    final base = wireBytes;
    if (isLocal) {
      return base;
    }
    final remaining = localExpiresAt - now;
    if (remaining <= 0) {
      return base;
    }
    var expires = _envelope.createdAt + remaining;
    if (expires > 0xFFFFFFFF) {
      expires = 0xFFFFFFFF;
    }
    if (expires == _envelope.expiresAt) {
      return base;
    }
    final out = Uint8List.fromList(base);
    ByteData.sublistView(out).setUint32(19, expires, Endian.little);
    return out;
  }

  void _replaceEnvelope(Envelope e) {
    _envelope = e;
    _wireCache = null;
  }

  @override
  String toString() =>
      'StoredMessage(${_envelope.kind.name}, msgId: 0x${msgId.toRadixString(16)}, '
      'receivedAt: $receivedAt, isLocal: $isLocal, read: $read, '
      'retracted: $retracted, supersededBy: $supersededBy'
      '${isStub ? ', stub' : ''}${isOpaque ? ', opaque' : ''})';
}

/// 目録の選択結果（msg_id と、絞ったときの最古 created_at）。
class InventorySelection {
  const InventorySelection(this.msgIds, {this.cutoffCreatedAt});

  final List<int> msgIds;

  /// 目録を絞ったとき、含めた中で最古の created_at。絞っていなければ null。
  final int? cutoffCreatedAt;
}

/// メッセージストア。
///
/// [version] は「新しいメッセージが加わるたび」に +1 する（既読化・削除では
/// 変えない）。再接続抑制の無効化判定（docs/02 §4）に使うため、相手に
/// 渡せる内容が増えたときだけ動かす。
class MessageStore extends ChangeNotifier {
  MessageStore(this._backend, {this.maxMessages = kDefaultMaxMessages});

  final StoreBackend _backend;

  /// 保存件数の上限。超えた分は docs/02 §5 の順で削除する。
  final int maxMessages;

  final Map<int, StoredMessage> _messages = <int, StoredMessage>{};

  /// tombstone の対象 msg_id → tombstone の msg_id 群。
  final Map<int, Set<int>> _tombstoneTargets = <int, Set<int>>{};

  /// supersedes 付き notice の対象 msg_id → 上書きする notice の msg_id 群。
  final Map<int, Set<int>> _supersedeTargets = <int, Set<int>>{};

  /// 参加中のグループ ID。削除順の判定（未参加グループを先に捨てる）に使う。
  /// [AppController] が同期する。
  Set<int> joinedGroupIds = <int>{};

  /// この端末が公式（ホスト・本部端末）であるグループ ID。取り消された
  /// お知らせの本文を残す（再投稿で復旧できるように、C20）。
  Set<int> officialGroupIds = <int>{};

  int _version = 0;
  bool _loaded = false;
  int _opaqueCount = 0;

  /// 追記した更新・削除レコード数（圧縮の判断用）。
  int _dirtyRecords = 0;

  /// 永続化を直列化するためのチェーン。
  Future<void> _io = Future<void>.value();

  /// 更新・削除レコードがこの数を超えたら全置換して圧縮する。
  static const int _compactThreshold = 500;

  int get count => _messages.length;

  /// 保存している不透明メッセージの件数。
  int get opaqueCount => _opaqueCount;

  /// 不透明メッセージの上限（300 件かつ全体の 10%）。
  int get opaqueLimit {
    final tenth = maxMessages ~/ 10;
    return tenth < kMaxOpaqueMessages ? tenth : kMaxOpaqueMessages;
  }

  /// 内容が増えるたびに +1 される版数。
  int get version => _version;

  bool get isLoaded => _loaded;

  bool contains(int msgId) => _messages.containsKey(msgId);

  StoredMessage? get(int msgId) => _messages[msgId];

  /// 保存されているすべてのメッセージ（順不同）。
  Iterable<StoredMessage> get all => _messages.values;

  // ---------------------------------------------------------------------------
  // 読み込み
  // ---------------------------------------------------------------------------

  /// バックエンドから読み込む。壊れたレコードは読み飛ばす。
  Future<void> load() async {
    final records = await _backend.readAll();
    _messages.clear();
    _tombstoneTargets.clear();
    _supersedeTargets.clear();
    var needsCompaction = false;
    for (final record in records) {
      try {
        final applied = _applyRecord(record);
        if (applied != _RecordType.add) {
          needsCompaction = true;
        }
      } on Object {
        // 壊れたレコードは無視する（残りは読む）。
        needsCompaction = true;
      }
    }
    _rebuildIndexes();
    _opaqueCount = _messages.values.where((m) => m.isOpaque).length;
    _loaded = true;
    _dirtyRecords = 0;
    if (needsCompaction) {
      await _compact();
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 追加
  // ---------------------------------------------------------------------------

  /// メッセージを保存する。
  ///
  /// - msg_id 既知 → [AddResult.duplicate]
  /// - hop ≥ 64、有効期間が 0 以下または 30 日超、tombstone/supersedes の不整合 →
  ///   [AddResult.rejected]
  /// - 受信時刻と発信側の expires_at は比べない（時計のずれに耐える、C12）。
  /// - 上限超過時は docs/02 §5 の順で古いものを削除してから保存する。
  /// - tombstone / supersedes 付き notice は対象の表示状態に反映する。
  Future<AddResult> add(
    Envelope envelope, {
    required int now,
    bool isLocal = false,
  }) async {
    if (_messages.containsKey(envelope.msgId)) {
      return AddResult.duplicate;
    }
    if (envelope.hop >= kMaxRelayHop) {
      return AddResult.rejected;
    }
    final ttl = envelope.ttlSeconds;
    if (ttl <= 0 || ttl > _maxTtlFor(envelope.kind)) {
      return AddResult.rejected;
    }
    if (envelope.isStub) {
      return AddResult.rejected;
    }
    if (!envelope.isOpaque) {
      // body の形式検証（decode 済みの封筒なら通るが、ローカル生成も同じ経路）。
      try {
        switch (envelope.kind) {
          case MessageKind.notice:
          case MessageKind.help:
            NoticeBody.decode(envelope.bodyPlain);
          case MessageKind.groupInfo:
            GroupInfoBody.decode(envelope.bodyPlain);
          case MessageKind.tombstone:
          case MessageKind.ack:
            if (envelope.supersedes == null || envelope.bodyPlain.isNotEmpty) {
              return AddResult.rejected;
            }
          case MessageKind.unknown:
            return AddResult.rejected;
        }
      } on EnvelopeFormatException {
        return AddResult.rejected;
      }
      if (envelope.supersedes == envelope.msgId) {
        return AddResult.rejected;
      }
    }

    final removed = <StoredMessage>[];
    if (envelope.isOpaque) {
      removed.addAll(_makeRoomForOpaque());
    } else if (!isLocal &&
        envelope.kind == MessageKind.notice &&
        envelope.role == SenderRole.resident) {
      removed.addAll(_capResidentNotices(envelope.groupId, now));
    }
    removed.addAll(_makeRoom(now));

    final message = StoredMessage(
      envelope: envelope,
      receivedAt: isLocal ? envelope.createdAt : now,
      isLocal: isLocal,
    );
    _messages[envelope.msgId] = message;
    if (envelope.isOpaque) {
      _opaqueCount++;
    }
    final touched = <StoredMessage>[];
    var erased = false;
    if (!envelope.isOpaque) {
      erased = _indexNew(message, touched);
    }
    _version++;

    final records = <Uint8List>[
      for (final r in removed) _encodeRemove(r.msgId),
      _encodeAdd(message),
      for (final t in touched) _encodeUpdate(t),
    ];
    _dirtyRecords += removed.length + touched.length;
    await _persistRecords(records,
        forceCompactIf: erased || removed.length >= 50);
    notifyListeners();
    return AddResult.added;
  }

  /// 種類ごとの有効期間の上限（C12）。お知らせは 30 日、取り消しは対象 + 24 時間、
  /// group_info は 365 日（+1 日の余裕）。
  static int _maxTtlFor(MessageKind kind) {
    switch (kind) {
      case MessageKind.notice:
      case MessageKind.help:
        return kMaxTtlSeconds;
      case MessageKind.tombstone:
      case MessageKind.ack:
        return kMaxTtlSeconds + kTombstoneGraceSeconds;
      case MessageKind.groupInfo:
      case MessageKind.unknown:
        return kMaxGroupInfoTtlSeconds;
    }
  }

  /// 取り消し・書きなおしを適用してよいか（封筒の role が対象の role 以上、C10）。
  static bool _mayApply(Envelope actor, StoredMessage target) =>
      actor.role.code >= target.envelope.role.code;

  /// 取り消された [target] の本文を消すべきか（C20）。
  bool _shouldEraseBody(StoredMessage target) =>
      !target.isLocal &&
      !target.isStub &&
      (target.kind == MessageKind.notice || target.kind == MessageKind.help) &&
      !officialGroupIds.contains(target.groupId);

  /// 新しく入った [message] を索引に反映し、表示状態が変わった既存メッセージを
  /// [touched] に集める。本文を消したものがあれば true（全置換が必要）。
  bool _indexNew(StoredMessage message, List<StoredMessage> touched) {
    final env = message.envelope;
    final target = env.supersedes;
    var erased = false;
    if (target != null) {
      if (env.kind == MessageKind.tombstone) {
        _tombstoneTargets.putIfAbsent(target, () => <int>{}).add(env.msgId);
        final t = _messages[target];
        if (t != null && t.groupId == env.groupId && _mayApply(env, t)) {
          message.retainUntil = localExpiresAt(t) + kTombstoneGraceSeconds;
          if (!t.retracted) {
            t.retracted = true;
            if (env.role == SenderRole.official &&
                t.envelope.role != SenderRole.official) {
              t.retractedByOfficial = true;
            }
            if (_shouldEraseBody(t)) {
              t._replaceEnvelope(t.envelope.asStub());
              erased = true;
            }
            touched.add(t);
          }
        }
      } else if (env.kind == MessageKind.notice) {
        _supersedeTargets.putIfAbsent(target, () => <int>{}).add(env.msgId);
        final t = _messages[target];
        if (t != null &&
            t.groupId == env.groupId &&
            t.kind == MessageKind.notice &&
            _mayApply(env, t)) {
          message.retainUntil = localExpiresAt(t) + kTombstoneGraceSeconds;
          if (_isNewerSuperseder(t, message)) {
            t.supersededBy = env.msgId;
            touched.add(t);
          }
        }
      }
    }
    // 先に届いていた tombstone / 上書きを、今入ったメッセージに適用する。
    final tombstones = _tombstoneTargets[env.msgId];
    if (tombstones != null) {
      final retainUntil = localExpiresAt(message) + kTombstoneGraceSeconds;
      for (final id in tombstones) {
        final ts = _messages[id];
        if (ts != null &&
            ts.groupId == env.groupId &&
            _mayApply(ts.envelope, message)) {
          message.retracted = true;
          if (ts.envelope.role == SenderRole.official &&
              env.role != SenderRole.official) {
            message.retractedByOfficial = true;
          }
          if ((ts.retainUntil ?? 0) < retainUntil) {
            ts.retainUntil = retainUntil;
            touched.add(ts);
          }
        }
      }
      if (message.retracted && _shouldEraseBody(message)) {
        message._replaceEnvelope(message.envelope.asStub());
        erased = true;
      }
    }
    if (env.kind == MessageKind.notice) {
      final supers = _supersedeTargets[env.msgId];
      if (supers != null) {
        StoredMessage? best;
        final retainUntil = localExpiresAt(message) + kTombstoneGraceSeconds;
        for (final id in supers) {
          final s = _messages[id];
          if (s != null &&
              s.groupId == env.groupId &&
              _mayApply(s.envelope, message)) {
            if (best == null || s.envelope.createdAt > best.envelope.createdAt) {
              best = s;
            }
            if ((s.retainUntil ?? 0) < retainUntil) {
              s.retainUntil = retainUntil;
              touched.add(s);
            }
          }
        }
        if (best != null) {
          message.supersededBy = best.msgId;
        }
      }
    }
    return erased;
  }

  /// [candidate] が [target] の現在の上書き元より新しいか。
  bool _isNewerSuperseder(StoredMessage target, StoredMessage candidate) {
    final current = target.supersededBy;
    if (current == null) {
      return true;
    }
    final cur = _messages[current];
    if (cur == null) {
      return true;
    }
    return candidate.envelope.createdAt >= cur.envelope.createdAt;
  }

  /// 全メッセージから索引と表示状態を組み直す（読み込み時）。
  /// 本文の消去はここでは行わない（公式グループの判定が後から来るため）。
  void _rebuildIndexes() {
    _tombstoneTargets.clear();
    _supersedeTargets.clear();
    for (final m in _messages.values) {
      final target = m.envelope.supersedes;
      if (target == null || m.isOpaque) {
        continue;
      }
      if (m.kind == MessageKind.tombstone) {
        _tombstoneTargets.putIfAbsent(target, () => <int>{}).add(m.msgId);
      } else if (m.kind == MessageKind.notice) {
        _supersedeTargets.putIfAbsent(target, () => <int>{}).add(m.msgId);
      }
    }
    for (final m in _messages.values) {
      if (m.isOpaque) {
        continue;
      }
      final tombstones = _tombstoneTargets[m.msgId];
      if (tombstones != null) {
        final retainUntil = localExpiresAt(m) + kTombstoneGraceSeconds;
        for (final id in tombstones) {
          final ts = _messages[id];
          if (ts != null &&
              ts.groupId == m.groupId &&
              _mayApply(ts.envelope, m)) {
            m.retracted = true;
            if (ts.envelope.role == SenderRole.official &&
                m.envelope.role != SenderRole.official) {
              m.retractedByOfficial = true;
            }
            if ((ts.retainUntil ?? 0) < retainUntil) {
              ts.retainUntil = retainUntil;
            }
          }
        }
      }
      if (m.kind == MessageKind.notice) {
        final supers = _supersedeTargets[m.msgId];
        if (supers != null) {
          StoredMessage? best;
          final retainUntil = localExpiresAt(m) + kTombstoneGraceSeconds;
          for (final id in supers) {
            final s = _messages[id];
            if (s != null &&
                s.groupId == m.groupId &&
                _mayApply(s.envelope, m)) {
              if (best == null ||
                  s.envelope.createdAt > best.envelope.createdAt) {
                best = s;
              }
              if ((s.retainUntil ?? 0) < retainUntil) {
                s.retainUntil = retainUntil;
              }
            }
          }
          if (best != null) {
            m.supersededBy = best.msgId;
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 期限・削除
  // ---------------------------------------------------------------------------

  /// この端末での有効期限（エポック秒）。自端末発信は expires_at、受信したものは
  /// 「受信時刻 + 有効期間」（発信側の時計を信用しない、C12）。
  int localExpiresAt(StoredMessage m) {
    if (m.isLocal) {
      return m.envelope.expiresAt;
    }
    return m.receivedAt + m.envelope.ttlSeconds;
  }

  /// 実効的な保持期限。tombstone / 書きなおしは対象の期限 + 24 時間まで延長する
  /// （[StoredMessage.retainUntil]。対象が先に消えても保持される）。
  int _effectiveExpiresAt(StoredMessage m) {
    final expires = localExpiresAt(m);
    final retain = m.retainUntil;
    return retain != null && retain > expires ? retain : expires;
  }

  /// [now] の時点で期限切れか（保持期限で判定）。
  bool isExpired(StoredMessage m, int now) => _effectiveExpiresAt(m) < now;

  /// [now] の時点で表示できるか（自身の有効期限で判定し、取り消し・置き換え・
  /// 不透明・空殻を除く）。
  bool isDisplayable(StoredMessage m, int now) =>
      m.envelope.isDisplayable &&
      !m.retracted &&
      m.supersededBy == null &&
      localExpiresAt(m) >= now;

  /// 期限内で目録に載せられるか（空殻も載せて再受信を防ぐ）。
  bool _isListable(StoredMessage m, int now) =>
      m.envelope.hop < kMaxRelayHop && !isExpired(m, now);

  /// 期限内で中継可能か（空殻は送らない）。
  bool _isRelayable(StoredMessage m, int now) =>
      _isListable(m, now) && !m.isStub;

  /// 上限に収まるよう削除する（追加前に呼ぶ）。満杯なら 10% をまとめて削除する。
  /// 削除したものを返す。
  List<StoredMessage> _makeRoom(int now) {
    if (_messages.length < maxMessages) {
      return const [];
    }
    var excess = _messages.length - maxMessages + 1;
    final batch = maxMessages ~/ 10;
    if (excess < batch) {
      excess = batch;
    }
    final candidates = _messages.values.toList()
      ..sort((a, b) {
        final ta = _evictionTier(a, now);
        final tb = _evictionTier(b, now);
        if (ta != tb) {
          return ta.compareTo(tb);
        }
        final r = a.receivedAt.compareTo(b.receivedAt);
        if (r != 0) {
          return r;
        }
        final c = a.envelope.createdAt.compareTo(b.envelope.createdAt);
        if (c != 0) {
          return c;
        }
        return a.msgId.compareTo(b.msgId);
      });
    final removed = candidates.take(excess).toList();
    for (final m in removed) {
      _remove(m);
    }
    return removed;
  }

  /// 不透明メッセージが上限なら最も古いものを削除する。
  List<StoredMessage> _makeRoomForOpaque() {
    if (_opaqueCount < opaqueLimit) {
      return const [];
    }
    StoredMessage? oldest;
    for (final m in _messages.values) {
      if (!m.isOpaque) {
        continue;
      }
      if (oldest == null || m.receivedAt < oldest.receivedAt) {
        oldest = m;
      }
    }
    if (oldest == null) {
      return const [];
    }
    _remove(oldest);
    return [oldest];
  }

  /// [groupId] の住民投稿が上限なら、最も古いものを削除する（C08）。
  List<StoredMessage> _capResidentNotices(int groupId, int now) {
    var n = 0;
    StoredMessage? oldest;
    for (final m in _messages.values) {
      if (m.groupId != groupId ||
          m.isLocal ||
          m.kind != MessageKind.notice ||
          m.envelope.role != SenderRole.resident) {
        continue;
      }
      n++;
      if (oldest == null || m.receivedAt < oldest.receivedAt) {
        oldest = m;
      }
    }
    if (n < kMaxResidentNoticesPerGroup || oldest == null) {
      return const [];
    }
    _remove(oldest);
    return [oldest];
  }

  /// 削除順: 期限切れ(0) → 不透明(1) → 未参加グループ（住民 2 / スタッフ 3 / 公式 4）
  /// → 参加グループ（5 / 6 / 7）→ 自端末発信(9)。同じ段では受信の古い順。
  int _evictionTier(StoredMessage m, int now) {
    if (isExpired(m, now)) {
      return 0;
    }
    if (m.isOpaque) {
      return 1;
    }
    if (m.isLocal) {
      return 9;
    }
    final base = joinedGroupIds.contains(m.groupId) ? 5 : 2;
    return base + m.envelope.role.code;
  }

  void _remove(StoredMessage m) {
    _messages.remove(m.msgId);
    if (m.isOpaque) {
      _opaqueCount--;
    }
    final target = m.envelope.supersedes;
    if (target != null) {
      _tombstoneTargets[target]?.remove(m.msgId);
      _supersedeTargets[target]?.remove(m.msgId);
    }
  }

  /// 期限切れを削除する。
  Future<void> purgeExpired(int now) async {
    final expired = _messages.values.where((m) => isExpired(m, now)).toList();
    if (expired.isEmpty) {
      return;
    }
    for (final m in expired) {
      _remove(m);
    }
    _dirtyRecords += expired.length;
    await _persistRecords(
      [for (final m in expired) _encodeRemove(m.msgId)],
      forceCompactIf: expired.length >= 50,
    );
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 検索
  // ---------------------------------------------------------------------------

  static int _newestFirst(StoredMessage a, StoredMessage b) {
    final c = b.envelope.createdAt.compareTo(a.envelope.createdAt);
    if (c != 0) {
      return c;
    }
    final r = b.receivedAt.compareTo(a.receivedAt);
    if (r != 0) {
      return r;
    }
    return a.msgId.compareTo(b.msgId);
  }

  static int _newestReceivedFirst(StoredMessage a, StoredMessage b) {
    final r = b.receivedAt.compareTo(a.receivedAt);
    if (r != 0) {
      return r;
    }
    return _newestFirst(a, b);
  }

  /// 有効な（期限内・hop<64）msg_id を新しい順に最大 [limit] 件。
  List<int> inventory({required int now, int limit = kDefaultInventoryLimit}) {
    final valid = _messages.values.where((m) => _isListable(m, now)).toList()
      ..sort(_newestFirst);
    final n = valid.length < limit ? valid.length : limit;
    return [for (var i = 0; i < n; i++) valid[i].msgId];
  }

  /// [ids] に無い、中継できるメッセージがあるか（同期し直す必要があるかの判定）。
  bool hasRelayableNotIn(Set<int> ids, {required int now}) {
    for (final m in _messages.values) {
      if (!ids.contains(m.msgId) && _isRelayable(m, now)) {
        return true;
      }
    }
    return false;
  }

  /// 目録を選ぶ。[small]（maxChunk が小さい）なら受信時刻の新しい順に
  /// [kSmallChunkInventoryLimit] 件へ絞り、最古の created_at を返す（C08）。
  InventorySelection inventorySelection({required int now, bool small = false}) {
    if (!small) {
      return InventorySelection(inventory(now: now));
    }
    final valid = _messages.values.where((m) => _isListable(m, now)).toList()
      ..sort(_newestReceivedFirst);
    if (valid.length <= kSmallChunkInventoryLimit) {
      return InventorySelection([for (final m in valid) m.msgId]);
    }
    final chosen = valid.sublist(0, kSmallChunkInventoryLimit);
    var cutoff = 0xFFFFFFFF;
    for (final m in chosen) {
      if (m.envelope.createdAt < cutoff) {
        cutoff = m.envelope.createdAt;
      }
    }
    return InventorySelection([for (final m in chosen) m.msgId],
        cutoffCreatedAt: cutoff);
  }

  static int _kindPriority(MessageKind kind) {
    switch (kind) {
      case MessageKind.groupInfo:
        return 0;
      case MessageKind.tombstone:
        return 1;
      case MessageKind.ack:
        return 2;
      case MessageKind.help:
        // 住民からの知らせ（SOS・安否）は小さく急ぐので、お知らせより先に送る。
        return 3;
      case MessageKind.notice:
      case MessageKind.unknown:
        return 4;
    }
  }

  /// 「自分にあって相手にない」有効なメッセージを送信優先順で返す。
  ///
  /// 優先順: kind（group_info → tombstone → ack → help → notice）、
  /// [peerGroups] があればそのグループのもの、role 降順、created_at 降順。
  /// 不透明メッセージは [peerRelaysUnknown] のときだけ、[cutoffCreatedAt] より
  /// 古い notice は送らない（C08 C13）。[exclude] は先出し済み。
  List<StoredMessage> messagesMissingFrom(
    Set<int> peerHas, {
    required int now,
    bool peerRelaysUnknown = false,
    int? cutoffCreatedAt,
    Set<int>? peerGroups,
    Set<int> exclude = const <int>{},
  }) {
    final missing = _messages.values.where((m) {
      if (peerHas.contains(m.msgId) || exclude.contains(m.msgId)) {
        return false;
      }
      if (!_isRelayable(m, now)) {
        return false;
      }
      if (m.isOpaque && !peerRelaysUnknown) {
        return false;
      }
      if (cutoffCreatedAt != null &&
          (m.kind == MessageKind.notice || m.kind == MessageKind.help) &&
          m.envelope.createdAt < cutoffCreatedAt) {
        return false;
      }
      return true;
    }).toList()
      ..sort((a, b) {
        final k = _kindPriority(a.kind).compareTo(_kindPriority(b.kind));
        if (k != 0) {
          return k;
        }
        if (peerGroups != null) {
          final ga = peerGroups.contains(a.groupId) ? 0 : 1;
          final gb = peerGroups.contains(b.groupId) ? 0 : 1;
          if (ga != gb) {
            return ga.compareTo(gb);
          }
        }
        final r = b.envelope.role.code.compareTo(a.envelope.role.code);
        if (r != 0) {
          return r;
        }
        return _newestFirst(a, b);
      });
    return missing;
  }

  /// HELLO 直後に先出しする候補（C08）: 参加グループの最新 group_info →
  /// 参加グループの tombstone（24 時間以内）→ 自分が出した知らせ（kind=help、
  /// 24 時間以内、まだ「受け取りました」が無いもの）→ 参加グループの ack
  /// （24 時間以内）→ 参加グループの公式 notice（24 時間以内、取消・置き換え済みを
  /// 除く）。それぞれ新しい順。
  List<StoredMessage> pushCandidates({
    required int now,
    int maxCount = kPushMaxCount,
  }) {
    final since = now - kPushWindowSeconds;
    bool recent(StoredMessage m) =>
        (m.isLocal ? m.envelope.createdAt : m.receivedAt) >= since;
    final infos = <StoredMessage>[];
    for (final g in joinedGroupIds) {
      final info = latestGroupInfo(g);
      if (info != null && _isRelayable(info, now)) {
        infos.add(info);
      }
    }
    final tombstones = _messages.values
        .where((m) =>
            m.kind == MessageKind.tombstone &&
            joinedGroupIds.contains(m.groupId) &&
            recent(m) &&
            _isRelayable(m, now))
        .toList()
      ..sort(_newestFirst);
    final officials = _messages.values
        .where((m) =>
            m.kind == MessageKind.notice &&
            m.envelope.role == SenderRole.official &&
            joinedGroupIds.contains(m.groupId) &&
            recent(m) &&
            _isRelayable(m, now) &&
            !m.retracted &&
            m.supersededBy == null)
        .toList()
      ..sort(_newestFirst);
    final ackedTargets = <int>{
      for (final m in _messages.values)
        if (m.kind == MessageKind.ack && m.envelope.supersedes != null)
          m.envelope.supersedes!,
    };
    final reports = _messages.values
        .where((m) =>
            m.kind == MessageKind.help &&
            m.isLocal &&
            recent(m) &&
            _isRelayable(m, now) &&
            !m.retracted &&
            !ackedTargets.contains(m.msgId))
        .toList()
      ..sort(_newestFirst);
    final acks = _messages.values
        .where((m) =>
            m.kind == MessageKind.ack &&
            joinedGroupIds.contains(m.groupId) &&
            recent(m) &&
            _isRelayable(m, now))
        .toList()
      ..sort(_newestFirst);
    final out = <StoredMessage>[
      ...infos,
      ...tombstones,
      ...reports,
      ...acks,
      ...officials,
    ];
    return out.length > maxCount ? out.sublist(0, maxCount) : out;
  }

  /// 表示対象の notice（期限内・未取消・未上書き）を新しい順に返す。
  /// [groupIds] を渡すとそのグループだけに絞る。[byReceived] なら届いた時刻の順。
  List<StoredMessage> visibleNotices({
    required int now,
    Set<int>? groupIds,
    bool byReceived = false,
  }) {
    final list = _messages.values
        .where((m) =>
            m.kind == MessageKind.notice &&
            isDisplayable(m, now) &&
            (groupIds == null || groupIds.contains(m.groupId)))
        .toList()
      ..sort(byReceived ? _newestReceivedFirst : _newestFirst);
    return list;
  }

  /// 表示対象の困りごと（kind=help）を新しい順に返す（C21）。
  List<StoredMessage> visibleHelpRequests({required int now, Set<int>? groupIds}) {
    final list = _messages.values
        .where((m) =>
            m.kind == MessageKind.help &&
            isDisplayable(m, now) &&
            (groupIds == null || groupIds.contains(m.groupId)))
        .toList()
      ..sort(_newestFirst);
    return list;
  }

  /// [msgId] への「受け取りました」（kind=ack）。なければ null。
  StoredMessage? ackFor(int msgId) {
    StoredMessage? best;
    for (final m in _messages.values) {
      if (m.kind != MessageKind.ack || m.envelope.supersedes != msgId) {
        continue;
      }
      if (best == null || _newestFirst(m, best) < 0) {
        best = m;
      }
    }
    return best;
  }

  /// [groupId] の最新の group_info（世代 → created_at の順で新しいもの）。
  StoredMessage? latestGroupInfo(int groupId) {
    StoredMessage? best;
    GroupInfoBody? bestBody;
    for (final m in _messages.values) {
      if (m.kind != MessageKind.groupInfo || m.groupId != groupId || m.isOpaque) {
        continue;
      }
      final GroupInfoBody body;
      try {
        body = GroupInfoBody.decode(m.envelope.bodyPlain);
      } on EnvelopeFormatException {
        continue;
      }
      if (best == null || bestBody == null) {
        best = m;
        bestBody = body;
        continue;
      }
      if (body.generation != bestBody.generation) {
        if (body.generation > bestBody.generation) {
          best = m;
          bestBody = body;
        }
        continue;
      }
      if (_newestFirst(m, best) < 0) {
        best = m;
        bestBody = body;
      }
    }
    return best;
  }

  /// 参加していないグループの group_info を、最後に受け取った時刻の新しい順に
  /// 最大 [limit] 件（C22）。
  List<StoredMessage> unjoinedGroupInfos({required int now, int limit = 3}) {
    final byGroup = <int, StoredMessage>{};
    for (final m in _messages.values) {
      if (m.kind != MessageKind.groupInfo ||
          m.isOpaque ||
          joinedGroupIds.contains(m.groupId) ||
          isExpired(m, now)) {
        continue;
      }
      final cur = byGroup[m.groupId];
      if (cur == null || m.receivedAt > cur.receivedAt) {
        byGroup[m.groupId] = m;
      }
    }
    final list = byGroup.values.toList()..sort(_newestReceivedFirst);
    return list.length > limit ? list.sublist(0, limit) : list;
  }

  /// 未読の表示対象 notice の数。
  int unreadCount({required int now, Set<int>? groupIds}) =>
      visibleNotices(now: now, groupIds: groupIds)
          .where((m) => !m.read)
          .length;

  Future<void> markRead(int msgId) => markAllRead({msgId});

  Future<void> markAllRead(Set<int> msgIds) async {
    final changed = <StoredMessage>[];
    for (final id in msgIds) {
      final m = _messages[id];
      if (m != null && !m.read) {
        m.read = true;
        changed.add(m);
      }
    }
    if (changed.isEmpty) {
      return;
    }
    _dirtyRecords += changed.length;
    await _persistRecords([for (final m in changed) _encodeUpdate(m)]);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 永続化
  // ---------------------------------------------------------------------------

  Future<void> _persistRecords(List<Uint8List> records,
      {bool forceCompactIf = false}) {
    final compact = forceCompactIf || _dirtyRecords > _compactThreshold;
    return _enqueueIo(() async {
      if (compact) {
        _dirtyRecords = 0;
        await _backend.rewrite(_snapshotRecords());
      } else {
        for (final r in records) {
          await _backend.append(r);
        }
      }
    });
  }

  Future<void> _compact() => _enqueueIo(() async {
        _dirtyRecords = 0;
        await _backend.rewrite(_snapshotRecords());
      });

  Future<void> _enqueueIo(Future<void> Function() op) {
    final next = _io.then((_) => op());
    _io = next.then((_) {}, onError: (_) {});
    return next;
  }

  List<Uint8List> _snapshotRecords() =>
      [for (final m in _messages.values) _encodeAdd(m)];

  // --- レコード形式 ---------------------------------------------------------
  //
  // u8 recordVersion(=1) ‖ u8 type ‖ 本体
  //   type 0 (add):    u32 receivedAt ‖ u8 flags ‖ [u64 supersededBy]
  //                    ‖ [u32 retainUntil] ‖ u16 len ‖ envelope
  //   type 1 (update): u64 msgId ‖ u8 flags ‖ [u64 supersededBy] ‖ [u32 retainUntil]
  //   type 2 (remove): u64 msgId
  // flags: bit0 isLocal, bit1 read, bit2 retracted, bit3 supersededBy あり,
  //        bit4 retainUntil あり, bit5 空殻（envelope はヘッダだけ）,
  //        bit6 公式による取り消し

  static const int _recordVersion = 1;
  static const int _flagLocal = 0x01;
  static const int _flagRead = 0x02;
  static const int _flagRetracted = 0x04;
  static const int _flagSuperseded = 0x08;
  static const int _flagRetain = 0x10;
  static const int _flagStub = 0x20;
  static const int _flagOfficialRetract = 0x40;

  static int _flagsOf(StoredMessage m) =>
      (m.isLocal ? _flagLocal : 0) |
      (m.read ? _flagRead : 0) |
      (m.retracted ? _flagRetracted : 0) |
      (m.supersededBy != null ? _flagSuperseded : 0) |
      (m.retainUntil != null ? _flagRetain : 0) |
      (m.isStub ? _flagStub : 0) |
      (m.retractedByOfficial ? _flagOfficialRetract : 0);

  /// flags に応じた可変部（supersededBy / retainUntil）を書き、次の offset を返す。
  static int _writeOptional(ByteData view, int offset, StoredMessage m) {
    final superseded = m.supersededBy;
    if (superseded != null) {
      view.setInt64(offset, superseded, Endian.little);
      offset += 8;
    }
    final retain = m.retainUntil;
    if (retain != null) {
      view.setUint32(offset, retain.clamp(0, 0xFFFFFFFF), Endian.little);
      offset += 4;
    }
    return offset;
  }

  static int _optionalLength(StoredMessage m) =>
      (m.supersededBy != null ? 8 : 0) + (m.retainUntil != null ? 4 : 0);

  static Uint8List _encodeAdd(StoredMessage m) {
    final env = m.wireBytes;
    final out = Uint8List(2 + 4 + 1 + _optionalLength(m) + 2 + env.length);
    final view = ByteData.sublistView(out);
    out[0] = _recordVersion;
    out[1] = _RecordType.add.index;
    view.setUint32(2, m.receivedAt, Endian.little);
    out[6] = _flagsOf(m);
    var off = _writeOptional(view, 7, m);
    view.setUint16(off, env.length, Endian.little);
    off += 2;
    out.setRange(off, off + env.length, env);
    return out;
  }

  static Uint8List _encodeUpdate(StoredMessage m) {
    final out = Uint8List(2 + 8 + 1 + _optionalLength(m));
    final view = ByteData.sublistView(out);
    out[0] = _recordVersion;
    out[1] = _RecordType.update.index;
    view.setInt64(2, m.msgId, Endian.little);
    out[10] = _flagsOf(m) & ~_flagLocal & ~_flagStub;
    _writeOptional(view, 11, m);
    return out;
  }

  static Uint8List _encodeRemove(int msgId) {
    final out = Uint8List(2 + 8);
    out[0] = _recordVersion;
    out[1] = _RecordType.remove.index;
    ByteData.sublistView(out).setInt64(2, msgId, Endian.little);
    return out;
  }

  /// レコードを in-memory 状態に適用する（読み込み時）。
  _RecordType _applyRecord(Uint8List record) {
    if (record.length < 2 || record[0] != _recordVersion) {
      throw const FormatException('不明なレコード形式');
    }
    final type = _RecordType.values[record[1]];
    final view = ByteData.sublistView(record);
    switch (type) {
      case _RecordType.add:
        final receivedAt = view.getUint32(2, Endian.little);
        final flags = record[6];
        var off = 7;
        int? supersededBy;
        if ((flags & _flagSuperseded) != 0) {
          supersededBy = view.getInt64(off, Endian.little);
          off += 8;
        }
        int? retainUntil;
        if ((flags & _flagRetain) != 0) {
          retainUntil = view.getUint32(off, Endian.little);
          off += 4;
        }
        final len = view.getUint16(off, Endian.little);
        off += 2;
        if (record.length - off != len) {
          throw const FormatException('封筒長が一致しません');
        }
        final bytes = Uint8List.sublistView(record, off);
        final env = (flags & _flagStub) != 0
            ? Envelope.decodeStub(bytes)
            : Envelope.decode(bytes);
        final m = StoredMessage(
          envelope: env,
          receivedAt: receivedAt,
          isLocal: (flags & _flagLocal) != 0,
          read: (flags & _flagRead) != 0,
          supersededBy: supersededBy,
          retracted: (flags & _flagRetracted) != 0,
          retractedByOfficial: (flags & _flagOfficialRetract) != 0,
          retainUntil: retainUntil,
        );
        if (!env.isStub) {
          m._wireCache = Uint8List.fromList(bytes);
        }
        _messages[env.msgId] = m;
      case _RecordType.update:
        final msgId = view.getInt64(2, Endian.little);
        final flags = record[10];
        var off = 11;
        int? supersededBy;
        if ((flags & _flagSuperseded) != 0) {
          supersededBy = view.getInt64(off, Endian.little);
          off += 8;
        }
        int? retainUntil;
        if ((flags & _flagRetain) != 0) {
          retainUntil = view.getUint32(off, Endian.little);
          off += 4;
        }
        final m = _messages[msgId];
        if (m != null) {
          m.read = (flags & _flagRead) != 0;
          m.retracted = (flags & _flagRetracted) != 0;
          m.retractedByOfficial = (flags & _flagOfficialRetract) != 0;
          m.supersededBy = supersededBy;
          m.retainUntil = retainUntil;
        }
      case _RecordType.remove:
        final msgId = view.getInt64(2, Endian.little);
        final m = _messages[msgId];
        if (m != null) {
          _messages.remove(msgId);
        }
    }
    return type;
  }
}

enum _RecordType { add, update, remove }
