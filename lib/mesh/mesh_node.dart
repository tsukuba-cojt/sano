/// 発見 → 接続判断 → セッション生成、バックオフ、再接続（docs/02 §4、docs/03 §5）。
library;

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../core/envelope.dart';
import '../core/epoch.dart';
import '../core/frames.dart';
import '../core/ids.dart';
import 'message_store.dart';
import 'receive_budget.dart';
import 'sync_session.dart';
import 'transport.dart';

/// 同じ node_id との再接続を空ける秒数。
const int kResyncIntervalSeconds = 60;

/// 中継役どうしの再接続間隔（C17）。
const int kRelayResyncIntervalSeconds = 10;

/// 接続失敗した peerId のバックオフ秒数。
const int kFailureBackoffSeconds = 30;

/// Apple 製造者データ由来でサービスが見つからなかった peerId を無視する秒数。
const int kAppleNoServiceIgnoreSeconds = 15 * 60;

/// central（接続を開始する側）として同時に張るリンクの上限。
const int kMaxInitiatorLinks = 2;

/// 中継役のときの central リンク上限（C04）。
const int kRelayMaxInitiatorLinks = 3;

/// 「近くの端末」として数える猶予秒数。
const int kNearbyWindowSeconds = 60;

/// 診断ログの保持行数。
const int kRecentLogLines = 100;

/// 残しておく交換の記録の件数（転送の量と秒数、#152）。
const int kRecentSessionStats = 30;

/// 時計のずれの判定に使う直近の TIME の件数。
const int kClockSamples = 8;

/// 近くの端末と同期し直せるかを見直す間隔。発見の通知が繰り返し来ない環境
/// （iOS の背面など）や、同時接続の上限で後回しにした相手にも広げるため。
const int kMeshTickSeconds = 15;

/// 見かけなくなった端末の記録を忘れるまでの秒数。
const int kForgetPeerSeconds = 30 * 60;

/// 相手がこちらへ接続できない（受信リンクでしか会えない）ときの再同期間隔。
const int kPollIntervalSeconds = 20;

/// 送信上限で打ち切った同期の続きを始めるまでの秒数。
const int kContinueDelaySeconds = 2;

/// 接続要求が応答なしのまま放置されたとみなす秒数（スロット解放用）。
const int _stalePendingConnectSeconds = 30;

/// 発見した端末 1 つの記録。
class PeerRecord {
  PeerRecord(this.peerId, {required this.lastSeen});

  final String peerId;

  /// 最後に見かけた時刻（エポック秒）。発見・接続のどちらでも更新する。
  int lastSeen;

  /// 最後に広告で発見した時刻（エポック秒）。受信リンクだけで見た相手は null。
  int? lastDiscoveredAt;

  /// 最後に同期が完了したときの store.version。
  int? lastSyncedVersion;

  /// 連続失敗回数。
  int failures = 0;

  /// HELLO で分かった相手のノード ID（16 進）。
  String? nodeIdHex;

  /// 最後に同期が完了した時刻。
  int? lastSyncAt;

  /// 重複リンクが動いている間に別の同期が成功したかを区別する。
  int _completedSyncs = 0;

  /// この時刻までは接続しない（失敗バックオフ）。
  int backoffUntil = 0;

  /// この時刻までは無視する（Apple 候補でサービスなし）。
  int ignoreUntil = 0;

  /// Apple の製造者データ経由で見つかった候補か。
  bool viaApple = false;

  /// サービスの存在を確認できたか（Service UUID で発見、またはリンク確立）。
  bool serviceConfirmed = false;

  int rssi = 0;

  @override
  String toString() =>
      'PeerRecord($peerId, node: $nodeIdHex, lastSeen: $lastSeen, '
      'failures: $failures, lastSyncAt: $lastSyncAt)';
}

/// 1 回の交換の記録。転送の量と秒数を実機で測るために残す（#152）。
class SessionStat {
  const SessionStat({
    required this.at,
    required this.peerNodeHex,
    required this.initiator,
    required this.succeeded,
    required this.messagesSent,
    required this.messagesReceived,
    required this.bytesSent,
    required this.bytesReceived,
    required this.elapsed,
    this.firstMessageAfter,
    this.hasMore = false,
    this.failureReason,
  });

  /// 終わった時刻（エポック秒）。
  final int at;

  /// 相手のノード ID（16 進）。HELLO 前に切れたら null。
  final String? peerNodeHex;

  /// こちらから接続したか。
  final bool initiator;
  final bool succeeded;
  final int messagesSent;
  final int messagesReceived;
  final int bytesSent;
  final int bytesReceived;

  /// 始めてから終わるまでの時間。
  final Duration elapsed;

  /// 始めてから最初のお知らせを受け取るまでの時間。
  final Duration? firstMessageAfter;

  /// 送りきれずに続きがあったか。
  final bool hasMore;
  final String? failureReason;

  /// 1 秒あたりに運んだバイト数（送受信の合計）。時間が 0 なら null。
  double? get bytesPerSecond {
    final ms = elapsed.inMilliseconds;
    if (ms <= 0) {
      return null;
    }
    return (bytesSent + bytesReceived) * 1000 / ms;
  }
}

class _NodeSync {
  _NodeSync({
    required this.lastSyncAt,
    required this.known,
    this.relay = false,
    this.more = false,
    this.poll = false,
  });
  final int lastSyncAt;

  /// 同期の後に相手が持っているはずの msg_id。
  final Set<int> known;

  /// [_hasNewFor] の結果の覚え（store.version が同じ間は再計算しない）。
  int? checkedVersion;
  bool hasNew = false;

  /// 相手が中継役だったか（中継役どうしは短い間隔で再接続する）。
  final bool relay;

  /// どちらかが送信上限で打ち切った（すぐ続きを同期する）。
  final bool more;

  /// 相手がこちらへ接続できない（短い間隔で同期しに行く）。
  final bool poll;
}

/// メッシュノード。トランスポートのイベントを購読し、同期セッションを管理する。
class MeshNode extends ChangeNotifier {
  MeshNode({
    required this._transport,
    required this._store,
    required Uint8List nodeId,
    int Function()? now,
    this._createTimer,
    int maxInitiatorLinks = kMaxInitiatorLinks,
    this.sessionByteBudget = kDefaultSessionByteBudget,
    this.resyncIntervalSeconds = kResyncIntervalSeconds,
    this.failureBackoffSeconds = kFailureBackoffSeconds,
    this.appleIgnoreSeconds = kAppleNoServiceIgnoreSeconds,
    this._helloTimeout = kHelloTimeout,
    this._sessionTimeout = kSessionTimeout,
    this.onSyncCompleted,
    this.onHanded,
    this.onPeerStored,
  })  : nodeId = Uint8List.fromList(nodeId),
        _nodeIdHex = hexOf(nodeId),
        _now = now ?? nowEpochSeconds,
        _baseMaxInitiatorLinks = maxInitiatorLinks {
    if (nodeId.length != kNodeIdLength) {
      throw ArgumentError.value(nodeId.length, 'nodeId', '8 バイトが必要です');
    }
    _subscription = _transport.events.listen(_onEvent);
  }

  final Transport _transport;
  final MessageStore _store;
  final ReceiveBudget _receiveBudget = ReceiveBudget();

  /// このノードの ID（8 バイト）。
  final Uint8List nodeId;
  final String _nodeIdHex;
  final int Function() _now;
  final TimerFactory? _createTimer;
  final Duration _helloTimeout;
  final Duration _sessionTimeout;

  final int _baseMaxInitiatorLinks;
  final int sessionByteBudget;
  final int resyncIntervalSeconds;
  final int failureBackoffSeconds;
  final int appleIgnoreSeconds;

  /// 同期が完了するたびに呼ばれる（時刻の保存・交換完了の音用、C04 C07）。
  final void Function(int epochSeconds, int sent, int received)? onSyncCompleted;

  /// 同期が完了し、相手（ノード ID の 16 進）に MESSAGE を渡したときに呼ばれる
  /// （「この端末から 渡した 台数」用、C18）。
  final void Function(String peerNodeHex, List<int> sentIds, int epochSeconds)?
      onHanded;

  /// 相手の保存を ID で確認できた分。途中切断でも既に届いた確認は有効。
  /// 一覧目録・STORED・相手から受信した ID だけを渡し、Bloom は含めない。
  final void Function(String peerNodeHex, Set<int> ids, int epochSeconds)?
      onPeerStored;

  StreamSubscription<TransportEvent>? _subscription;
  final Map<String, PeerRecord> _peers = <String, PeerRecord>{};
  final Map<String, _NodeSync> _nodeSync = <String, _NodeSync>{};

  /// 相手（ノード ID）が持っているはずの msg_id と、記録した時刻。途中で切れた
  /// セッションの分も足しておき、次のすれ違いの先出しで同じものを送り直さない（v2.3）。
  final Map<String, ({int at, Set<int> ids})> _peerKnown =
      <String, ({int at, Set<int> ids})>{};
  final Map<int, SyncSession> _sessions = <int, SyncSession>{};
  final Map<String, int> _pendingConnects = <String, int>{};
  final Set<SyncSession> _abortedByNode = <SyncSession>{};
  final Queue<String> _log = Queue<String>();
  final Queue<SessionStat> _sessionStats = Queue<SessionStat>();
  final Queue<int> _clockOffsets = Queue<int>();

  bool _running = false;
  Timer? _tickTimer;
  bool _disposed = false;
  bool _lowPower = false;
  bool _relayMode = false;
  bool _poweredOn = false;
  bool _scanning = false;
  bool _advertising = false;
  String _permission = 'unknown';
  int? _lastReceivedAt;
  int? _lastSyncAt;
  int? _lastSentAt;
  int? _startedAt;
  int _totalSessions = 0;
  int _totalMessagesReceived = 0;
  int _totalMessagesSent = 0;

  MessageStore get store => _store;

  bool get running => _running;
  bool get lowPower => _lowPower;

  /// 中継役として動いているか（C04）。
  bool get relayMode => _relayMode;
  bool get poweredOn => _poweredOn;
  bool get scanning => _scanning;
  bool get advertising => _advertising;
  String get permission => _permission;

  /// central として同時に張るリンクの上限（中継役なら 3）。
  int get maxInitiatorLinks =>
      _relayMode ? kRelayMaxInitiatorLinks : _baseMaxInitiatorLinks;

  /// HELLO に載せる能力ビット。
  int get caps => kDefaultCaps | (_relayMode ? kCapRelayNode : 0);

  /// 直近 60 秒に見えた端末数。同じ端末がアドレスを変えて見えても 1 台と数える
  /// （HELLO で分かったノード ID でまとめる）。
  int get nearbyCount {
    final t = _now();
    final seen = <String>{};
    for (final p in _peers.values) {
      if (t - p.lastSeen <= kNearbyWindowSeconds) {
        seen.add(p.nodeIdHex ?? 'peer:${p.peerId}');
      }
    }
    return seen.length;
  }

  int get activeSessions => _sessions.length;
  int? get lastReceivedAt => _lastReceivedAt;

  /// 最後に同期が完了した時刻（エポック秒）。起動後に 1 度もなければ null。
  int? get lastSyncAt => _lastSyncAt;

  /// 最後に MESSAGE を渡した時刻（エポック秒）。
  int? get lastSentAt => _lastSentAt;

  /// 通信を開始した時刻（エポック秒）。未開始なら null。
  int? get startedAt => _startedAt;

  /// 最後に何かの端末を見かけた時刻（エポック秒）。まだなければ null。
  int? get lastPeerSeenAt {
    int? best;
    for (final p in _peers.values) {
      if (best == null || p.lastSeen > best) {
        best = p.lastSeen;
      }
    }
    return best;
  }
  int get totalSessions => _totalSessions;
  int get totalMessagesReceived => _totalMessagesReceived;
  int get totalMessagesSent => _totalMessagesSent;

  /// 近くの端末との時計の差（相手 − 自分、秒）の中央値。測定前は null。
  int? get clockOffsetSeconds {
    if (_clockOffsets.isEmpty) {
      return null;
    }
    final sorted = _clockOffsets.toList()..sort();
    return sorted[sorted.length ~/ 2];
  }

  /// 最新 100 行の診断ログ（古い順）。
  List<String> get recentLog => List.unmodifiable(_log);

  /// 最近の交換の記録（古い順、最大 [kRecentSessionStats] 件）。
  List<SessionStat> get recentSessions => List.unmodifiable(_sessionStats);

  /// 発見済みの端末記録。
  List<PeerRecord> get peers => List.unmodifiable(_peers.values);

  /// 進行中のセッション。
  List<SyncSession> get sessions => List.unmodifiable(_sessions.values);

  // ---------------------------------------------------------------------------
  // 開始 / 停止
  // ---------------------------------------------------------------------------

  Future<void> start({bool lowPower = false}) async {
    if (_running) {
      if (lowPower != _lowPower) {
        await setLowPower(lowPower);
      }
      return;
    }
    _lowPower = lowPower;
    try {
      await _transport.start(
          TransportConfig(nodeId: nodeId, lowPower: lowPower));
    } on Object catch (e) {
      _logLine('開始に失敗: $e');
      rethrow;
    }
    _running = true;
    _startedAt = _now();
    _armTick();
    _logLine(
      '開始 node=$_nodeIdHex${lowPower ? ' (省電力)' : ''}'
      '${_relayMode ? ' (中継役)' : ''}',
    );
    notifyListeners();
  }

  Future<void> stop() async {
    if (!_running) {
      return;
    }
    _running = false;
    _tickTimer?.cancel();
    _tickTimer = null;
    for (final s in _sessions.values.toList()) {
      _abortedByNode.add(s);
      s.abort('停止');
    }
    _pendingConnects.clear();
    try {
      await _transport.stop();
    } on Object catch (e) {
      _logLine('停止に失敗: $e');
    }
    _logLine('停止');
    notifyListeners();
  }

  Future<void> setLowPower(bool v) async {
    _lowPower = v;
    if (_running) {
      await _transport.setLowPower(v);
    }
    notifyListeners();
  }

  /// 中継役として動くか（HELLO の caps、同時接続数、再接続間隔に効く）。
  /// 保存が外から増えた（実機テスト用のデータなど）。近くの端末とすぐ同期し直す。
  void nudge() {
    _reconnectRecentPeers();
    notifyListeners();
  }

  void setRelayMode(bool v) {
    if (_relayMode == v) {
      return;
    }
    _relayMode = v;
    _logLine(v ? '中継役として動きます' : '中継役をやめます');
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _tickTimer?.cancel();
    _tickTimer = null;
    _subscription?.cancel();
    _subscription = null;
    super.dispose();
  }

  void _armTick() {
    _tickTimer?.cancel();
    final create = _createTimer ?? Timer.new;
    _tickTimer = create(const Duration(seconds: kMeshTickSeconds), _onTick);
  }

  void _onTick() {
    _tickTimer = null;
    if (!_running || _disposed) {
      return;
    }
    // 1 時間以上同期していない相手の記録は捨てる（メモリを増やし続けない）。
    final t = _now();
    _nodeSync.removeWhere((_, v) => t - v.lastSyncAt > 3600);
    _peerKnown.removeWhere((_, v) => t - v.at > 3600);
    // アドレスが変わるたびに記録が増えるので、30 分見ていない相手は忘れる。
    _peers.removeWhere((id, p) =>
        t - p.lastSeen > kForgetPeerSeconds &&
        !_pendingConnects.containsKey(id) &&
        !_sessions.values.any((s) => s.peerId == id));
    _reconnectRecentPeers();
    _armTick();
  }

  // ---------------------------------------------------------------------------
  // 投稿
  // ---------------------------------------------------------------------------

  /// 自端末のメッセージを保存し、近くの端末へすぐに広げる
  /// （保存内容が変わるので再接続抑制は自動的に解除される）。
  Future<AddResult> publish(Envelope envelope) async {
    final result = await _store.add(envelope, now: _now(), isLocal: true);
    if (result == AddResult.added) {
      _logLine('投稿 ${envelope.kind.name} '
          'msg=0x${envelope.msgId.toRadixString(16)}');
      _reconnectRecentPeers();
      notifyListeners();
    }
    return result;
  }

  /// 一度同期できた相手に、発見の通知が来なくても同期し直しを試みる秒数。
  /// iOS の背面では同じ相手の発見が繰り返し通知されないため、近くに居続ける
  /// 相手とも定期的に同期し直せるようにする（離れた相手には 1〜2 回失敗するだけ）。
  int get _lingerWindowSeconds => resyncIntervalSeconds * 2 + kMeshTickSeconds;

  /// 近くの端末へ、まだ渡していない（または相手から受け取れる）ものがあれば接続する。
  /// まだ同期していない相手 → 最後の同期が古い相手 → 電波の強い相手の順。
  void _reconnectRecentPeers() {
    if (!_running || _disposed) {
      return;
    }
    final t = _now();
    final candidates =
        _peers.values.where((p) {
          // 受信リンクでしか見ていない相手（central 側のランダムアドレス）には
          // 接続できないので、広告で発見した相手だけに再接続する。
          if (p.lastDiscoveredAt == null) {
            return false;
          }
          final age = t - p.lastSeen;
          if (age <= kNearbyWindowSeconds) {
            return true;
          }
          return p.lastSyncAt != null && age <= _lingerWindowSeconds;
        }).toList()..sort((a, b) {
          final sa = a.lastSyncAt;
          final sb = b.lastSyncAt;
          if (sa == null || sb == null) {
            if (sa != sb) {
              return sa == null ? -1 : 1;
            }
          } else if (sa != sb) {
            return sa.compareTo(sb);
          }
          return b.rssi.compareTo(a.rssi);
        });
    for (final p in candidates) {
      if (_initiatorCount >= maxInitiatorLinks) {
        break;
      }
      _maybeConnect(p);
    }
  }

  // ---------------------------------------------------------------------------
  // イベント
  // ---------------------------------------------------------------------------

  void _onEvent(TransportEvent event) {
    try {
      switch (event) {
        case TransportState():
          _poweredOn = event.poweredOn;
          _scanning = event.scanning;
          _advertising = event.advertising;
          _permission = event.permission;
          notifyListeners();
        case PeerDiscovered():
          _onDiscovered(event);
        case LinkOpened():
          _onLinkOpened(event);
        case LinkData():
          _sessions[event.linkId]?.onData(event.data);
        case LinkClosed():
          _onLinkClosed(event);
        case TransportLog():
          _logLine('[transport] ${event.message}');
      }
    } on Object catch (e, st) {
      _logLine('イベント処理でエラー: $e');
      debugPrintStack(stackTrace: st, label: 'MeshNode._onEvent');
    }
  }

  void _onDiscovered(PeerDiscovered e) {
    final t = _now();
    final p = _peers.putIfAbsent(e.peerId, () {
      _logLine('発見 ${e.peerId}${e.viaApple ? ' (Apple)' : ''}');
      return PeerRecord(e.peerId, lastSeen: t);
    });
    p.lastSeen = t;
    p.lastDiscoveredAt = t;
    p.rssi = e.rssi;
    if (e.viaApple) {
      p.viaApple = true;
    } else {
      p.serviceConfirmed = true;
    }
    if (_running) {
      _maybeConnect(p);
    }
    notifyListeners();
  }

  int get _initiatorCount {
    final t = _now();
    _pendingConnects.removeWhere(
        (_, startedAt) => t - startedAt > _stalePendingConnectSeconds);
    return _pendingConnects.length + _sessions.values.where((s) => s.initiator).length;
  }

  /// バックオフ表を見て、接続してよければ接続する。
  void _maybeConnect(PeerRecord p) {
    if (!_running) {
      return;
    }
    final t = _now();
    if (p.ignoreUntil > t || p.backoffUntil > t) {
      return;
    }
    if (_pendingConnects.containsKey(p.peerId)) {
      return;
    }
    if (_sessions.values.any((s) => s.peerId == p.peerId)) {
      return;
    }
    final hex = p.nodeIdHex;
    if (hex != null) {
      if (_sessions.values.any((s) {
        final n = s.peerNodeId;
        return n != null && hexOf(n) == hex;
      })) {
        return;
      }
      final sync = _nodeSync[hex];
      if (sync != null) {
        if (sync.more) {
          if (t - sync.lastSyncAt < kContinueDelaySeconds) {
            return;
          }
        } else {
          var interval = (sync.relay && _relayMode)
              ? kRelayResyncIntervalSeconds
              : resyncIntervalSeconds;
          if (sync.poll && interval > kPollIntervalSeconds) {
            interval = kPollIntervalSeconds;
          }
          // 間隔内でも、相手がまだ持っていないものが入っていればすぐ渡す。
          if (t - sync.lastSyncAt < interval && !_hasNewFor(sync, t)) {
            return;
          }
        }
      }
    }
    if (_initiatorCount >= maxInitiatorLinks) {
      return;
    }
    _pendingConnects[p.peerId] = t;
    _logLine('接続 ${p.peerId}');
    _transport.connect(p.peerId).then((_) {}, onError: (Object e) {
      if (_pendingConnects.containsKey(p.peerId)) {
        _onConnectFailed(p, 'connect error: $e');
      }
    });
  }

  /// 前回の同期の後に、相手がまだ持っていない中継できるものが入ったか。
  bool _hasNewFor(_NodeSync sync, int now) {
    final v = _store.version;
    if (sync.checkedVersion != v) {
      sync.checkedVersion = v;
      sync.hasNew = _store.hasRelayableNotIn(sync.known, now: now);
    }
    return sync.hasNew;
  }

  /// ネイティブ側が自分で断った（接続を試していない）理由。失敗に数えない。
  static const Set<String> _notAttemptedReasons = {
    'busy',
    'duplicate',
    'alreadyConnecting',
    'not_running',
    'poweredOff',
  };

  /// 相手に回覧板のサービスが無いと確かめられた理由。
  static const Set<String> _noServiceReasons = {
    'no_service',
    'service_not_found',
    'serviceNotFound',
  };

  /// Apple の背面広告から見つけた候補が、サービス未確認のまま続けて失敗したら無視する回数。
  static const int _appleFailuresBeforeIgnore = 3;

  void _onConnectFailed(PeerRecord p, String reason) {
    _pendingConnects.remove(p.peerId);
    final t = _now();
    if (_notAttemptedReasons.contains(reason)) {
      // 接続の枠や状態の都合で断っただけ。次の見直しでまた試す。
      _logLine('接続を見送り ${p.peerId}: $reason');
      notifyListeners();
      return;
    }
    p.failures++;
    final noService = _noServiceReasons.contains(reason);
    final appleGiveUp =
        p.viaApple &&
        !p.serviceConfirmed &&
        p.failures >= _appleFailuresBeforeIgnore;
    if (noService || appleGiveUp) {
      p.ignoreUntil = t + appleIgnoreSeconds;
      _logLine('接続失敗 ${p.peerId}（サービスなし、$appleIgnoreSeconds 秒無視）: $reason');
    } else {
      p.backoffUntil = t + failureBackoffSeconds;
      _logLine('接続失敗 ${p.peerId}（$failureBackoffSeconds 秒待つ）: $reason');
    }
    notifyListeners();
  }

  void _onLinkOpened(LinkOpened e) {
    _pendingConnects.remove(e.peerId);
    final t = _now();
    final p = _peers.putIfAbsent(
        e.peerId, () => PeerRecord(e.peerId, lastSeen: t));
    p.lastSeen = t;
    p.serviceConfirmed = true;
    if (_sessions.containsKey(e.linkId)) {
      _logLine('linkId ${e.linkId} が重複しています');
      return;
    }
    if (!_running) {
      unawaited(_transport.close(e.linkId).then((_) {}, onError: (_) {}));
      return;
    }
    final groupIds = _relayMode
        ? _store.joinedGroupIds.take(kMaxHelloGroups).toList()
        : const <int>[];
    final session = SyncSession(
      linkId: e.linkId,
      peerId: e.peerId,
      initiator: e.initiator,
      maxChunk: e.maxChunk,
      store: _store,
      nodeId: nodeId,
      send: (chunk) => _transport.send(e.linkId, chunk),
      close: () => _transport.close(e.linkId),
      now: _now,
      sessionByteBudget: sessionByteBudget,
      log: _logLine,
      createTimer: _createTimer,
      helloTimeout: _helloTimeout,
      sessionTimeout: _sessionTimeout,
      onHello: _onSessionHello,
      caps: caps,
      groupIds: groupIds,
      onPeerTime: _onPeerTime,
      cannotReachPeer: _cannotReach,
      knownPeerIds: (node) => _peerKnown[hexOf(node)]?.ids,
      receiveBudget: _receiveBudget,
    );
    _sessions[e.linkId] = session;
    _totalSessions++;
    _logLine('リンク確立 ${e.peerId} link=${e.linkId} '
        '${e.initiator ? 'central' : 'peripheral'} chunk=${e.maxChunk}');
    final completedSyncsAtStart = p._completedSyncs;
    unawaited(session.done.then((_) =>
        _onSessionDone(session, p, completedSyncsAtStart)));
    unawaited(session.start());
    notifyListeners();
  }

  /// HELLO で分かった相手に、こちらから接続できないか（広告で見つけた記録がない）。
  bool _cannotReach(SyncSession session) {
    final peerNode = session.peerNodeId;
    if (peerNode == null) {
      return false;
    }
    final hex = hexOf(peerNode);
    final t = _now();
    return !_peers.values.any(
      (p) =>
          p.nodeIdHex == hex &&
          p.lastDiscoveredAt != null &&
          t - p.lastSeen <= _lingerWindowSeconds,
    );
  }

  void _onPeerTime(int offsetSeconds) {
    _clockOffsets.addLast(offsetSeconds);
    while (_clockOffsets.length > kClockSamples) {
      _clockOffsets.removeFirst();
    }
    if (offsetSeconds.abs() > 3600) {
      _logLine('時計の差 ${offsetSeconds > 0 ? '+' : ''}$offsetSeconds 秒');
    }
  }

  /// HELLO を受け取った。自分自身・重複セッションを判定する。
  void _onSessionHello(SyncSession session) {
    final peerNode = session.peerNodeId;
    if (peerNode == null) {
      return;
    }
    final hex = hexOf(peerNode);
    final p = _peers[session.peerId];
    if (p != null) {
      p.nodeIdHex = hex;
    }
    if (hex == _nodeIdHex) {
      _abortedByNode.add(session);
      session.abort('自分自身との接続');
      if (p != null) {
        p.ignoreUntil = _now() + appleIgnoreSeconds;
      }
      return;
    }
    for (final other in _sessions.values) {
      if (identical(other, session) || other.isFinished) {
        continue;
      }
      final otherNode = other.peerNodeId;
      if (otherNode == null || hexOf(otherNode) != hex) {
        continue;
      }
      // 同じ相手と 2 本のリンクがある。双方で同じ判断になるよう、
      // 「ノード ID が小さい側が開始したリンク」を残してもう一方を閉じる。
      final weAreSmaller = _compareBytes(nodeId, peerNode) < 0;
      final keepThis = session.initiator == weAreSmaller;
      final victim = keepThis ? other : session;
      _abortedByNode.add(victim);
      _logLine('重複セッション link=${victim.linkId} を閉じる');
      victim.abort('重複セッション');
      break;
    }
  }

  void _onSessionDone(
      SyncSession session, PeerRecord p, int completedSyncsAtStart) {
    _sessions.remove(session.linkId);
    final t = _now();
    final peerNode = session.peerNodeId;
    final hex = peerNode != null ? hexOf(peerNode) : null;
    if (hex != null) {
      p.nodeIdHex = hex;
    }
    _totalMessagesReceived += session.messagesReceived;
    _totalMessagesSent += session.messagesSent;
    _sessionStats.addLast(SessionStat(
      at: t,
      peerNodeHex: hex,
      initiator: session.initiator,
      succeeded: session.succeeded,
      messagesSent: session.messagesSent,
      messagesReceived: session.messagesReceived,
      bytesSent: session.bytesSent,
      bytesReceived: session.bytesReceived,
      elapsed: session.elapsed,
      firstMessageAfter: session.firstMessageAfter,
      hasMore: session.hasMore,
      failureReason: session.failureReason,
    ));
    while (_sessionStats.length > kRecentSessionStats) {
      _sessionStats.removeFirst();
    }
    if (session.messagesReceived > 0) {
      _lastReceivedAt = t;
    }
    if (session.messagesSent > 0) {
      _lastSentAt = t;
    }
    if (hex != null) {
      final confirmed = session.knownByPeerConfirmed;
      final previous = _peerKnown[hex]?.ids;
      // 成功したら確定所持で置き換えるが、前回までに確定したもので今回の
      // 目録にもまだあるものは引き継ぐ（なくすと、先出しのない交換を挟むたびに
      // 双方が持っている SOS などを毎回先出しし直す）。
      final ids = session.succeeded
          ? <int>{...confirmed, ...session.stillHeldByPeer(previous)}
          : <int>{...?previous, ...confirmed};
      _peerKnown[hex] = (at: t, ids: ids);
      if (confirmed.isNotEmpty) {
        onPeerStored?.call(hex, Set.unmodifiable(confirmed), t);
      }
    }
    if (session.succeeded) {
      p._completedSyncs++;
      p.failures = 0;
      p.lastSyncAt = t;
      p.lastSeen = t;
      p.lastSyncedVersion = _store.version;
      p.backoffUntil = 0;
      _lastSyncAt = t;
      if (hex != null) {
        _nodeSync[hex] = _NodeSync(
          lastSyncAt: t,
          known: session.knownByPeer,
          relay: session.peerIsRelay,
          more: session.hasMore,
          poll: session.peerWantsPoll,
        );
      }
      _logLine(
        '同期完了 ${p.peerId} 受信 ${session.messagesReceived} 件 '
        '送信 ${session.messagesSent} 件${session.hasMore ? '（続きあり）' : ''}',
      );
      onSyncCompleted?.call(t, session.messagesSent, session.messagesReceived);
      if (hex != null && session.confirmedSentMessageIds.isNotEmpty) {
        onHanded?.call(hex, session.confirmedSentMessageIds, t);
      }
      if (session.hasMore) {
        // 打ち切った続きを少し待って同期する（相手が接続してくる場合もある）。
        (_createTimer ?? Timer.new)(
          const Duration(seconds: kContinueDelaySeconds),
          _reconnectRecentPeers,
        );
      }
    } else if (!_abortedByNode.remove(session)) {
      // 同じ相手の別のセッションが進行中、またはこのリンクの開始後に成功
      // した場合は重複リンク扱い。前回の成功より後に始めた同期の保存失敗は
      // 通常のバックオフにしないと、未保存分を即座に送り直し続けてしまう。
      final otherActive = hex != null &&
          _sessions.values.any((s) {
            final n = s.peerNodeId;
            return n != null && hexOf(n) == hex;
          });
      final supersededBySuccess = p._completedSyncs > completedSyncsAtStart;
      if (!otherActive && !supersededBySuccess) {
        p.failures++;
        p.backoffUntil = t + failureBackoffSeconds;
      }
      _logLine('同期失敗 ${p.peerId}: ${session.failureReason ?? ''}');
    }
    // 接続の枠が空いた。受け取ったものがあれば近くの別の端末へすぐ渡し、
    // 上限で後回しにした相手とも同期する。
    _reconnectRecentPeers();
    notifyListeners();
  }

  void _onLinkClosed(LinkClosed e) {
    final session = _sessions[e.linkId];
    if (session != null) {
      session.onClosed();
      return;
    }
    final peerId = e.peerId;
    if (peerId != null && _pendingConnects.containsKey(peerId)) {
      final p = _peers.putIfAbsent(
          peerId, () => PeerRecord(peerId, lastSeen: _now()));
      _onConnectFailed(p, e.reason);
    }
  }

  static int _compareBytes(Uint8List a, Uint8List b) {
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      if (a[i] != b[i]) {
        return a[i].compareTo(b[i]);
      }
    }
    return a.length.compareTo(b.length);
  }

  /// 記録の 1 行ごとに呼ぶ（実機の調査用。OS のログへ流す）。
  void Function(String line)? onLogLine;

  void _logLine(String message) {
    final time = dateTimeFromEpoch(_now());
    String two(int v) => v.toString().padLeft(2, '0');
    final line =
        '${two(time.hour)}:${two(time.minute)}:${two(time.second)} $message';
    _log.addLast(line);
    onLogLine?.call(line);
    while (_log.length > kRecentLogLines) {
      _log.removeFirst();
    }
  }
}
