/// 1 本のリンク上の同期セッション（docs/02_protocol.md §4）。
///
/// central / peripheral の区別なく対称に動き、接続を開始した側
/// （[initiator]）だけが最後に BYE を送ってリンクを閉じる。
///
/// v2（docs/08）: HELLO の version 不一致で切らない（C13）、HELLO 直後に
/// TIME を送って時計のずれを測る（C12）、相手が受けられるなら公式の新着を
/// 目録交換の前に先出しする（C08）、中継役どうしは上限とタイムアウトを
/// 緩める（C17）。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../core/envelope.dart';
import '../core/frames.dart';
import '../core/inventory_filter.dart';
import '../core/ids.dart';
import 'message_store.dart';
import 'receive_budget.dart';

/// HELLO 待ちの既定タイムアウト。
const Duration kHelloTimeout = Duration(seconds: 5);

/// セッション全体の既定タイムアウト。
const Duration kSessionTimeout = Duration(seconds: 30);

/// 中継役どうしのセッション全体のタイムアウト（C17）。
const Duration kRelaySessionTimeout = Duration(seconds: 300);

/// 1 セッションで送る MESSAGE の既定バイト上限。
const int kDefaultSessionByteBudget = 65536;

/// 中継役どうしの MESSAGE バイト上限（C17）。
const int kRelaySessionByteBudget = 1 << 20;

/// 中継役どうしで maxChunk が小さいときの MESSAGE バイト上限（C17）。
const int kRelaySmallChunkByteBudget = 256 * 1024;

/// この maxChunk 未満なら目録を絞る（C08）。
const int kSmallChunkThreshold = 100;

/// この maxChunk 未満なら中継役どうしの上限を 256 KB にする（C17）。
const int kRelaySmallChunkThreshold = 180;

/// 1 セッションで送る不透明メッセージのバイト上限（C13）。
const int kMaxOpaqueBytesPerSession = 16 * 1024;

const int kMaxPendingReceiveMessages = 2048;
const int kMaxPendingReceiveBytes = 4 * 1024 * 1024;
const int kStoreBatchSize = 128;
const int kMaxSessionControlBytes = 64 * 1024;

/// タイマー生成関数の型（テストでは仮想時計に差し替える）。
typedef TimerFactory =
    Timer Function(Duration duration, void Function() callback);

Timer _realTimer(Duration duration, void Function() callback) =>
    Timer(duration, callback);

/// セッションの状態。
enum SessionState {
  /// 相手の HELLO 待ち。
  hello,

  /// 相手の INVENTORY 受信中。
  inventory,

  /// MESSAGE の送受信中。
  transfer,

  /// 双方の MESSAGES_END が済み、BYE / 切断待ち。
  closing,

  /// 正常終了。
  done,

  /// 失敗（タイムアウト・不正フレーム・切断など）。
  failed,
}

/// 同期セッション。
class SyncSession {
  SyncSession({
    required this.linkId,
    required this.peerId,
    required this.initiator,
    required int maxChunk,
    required this._store,
    required this._nodeId,
    required this._send,
    required this._close,
    required this._now,
    this.sessionByteBudget = kDefaultSessionByteBudget,
    this._log,
    TimerFactory? createTimer,
    this._helloTimeout = kHelloTimeout,
    this._sessionTimeout = kSessionTimeout,
    this.onHello,
    this.caps = kDefaultCaps,
    this.groupIds = const [],
    this.onPeerTime,
    this.cannotReachPeer,
    this.knownPeerIds,
    ReceiveBudget? receiveBudget,
  }) : maxChunk = maxChunk < 1 ? 1 : maxChunk,
       _receiveBudget = receiveBudget ?? ReceiveBudget(),
       _createTimer = createTimer ?? _realTimer,
       _byteBudget = _budgetFor(sessionByteBudget, maxChunk);

  /// 小さいチャンク（MTU の交渉に失敗した端末など）では 1 回の同期で送る量を
  /// 減らし、30 秒以内に終えて続きは次の同期で送る（打ち切りの「続きあり」）。
  static int _budgetFor(int budget, int maxChunk) {
    if (maxChunk >= kSmallChunkThreshold) {
      return budget;
    }
    final small = maxChunk * 256 < 4096 ? 4096 : maxChunk * 256;
    return small < budget ? small : budget;
  }

  final int linkId;
  final String peerId;

  /// 自分が接続を開始した側（central）か。
  final bool initiator;

  /// 1 回の送信で送れる最大バイト数。
  final int maxChunk;

  /// MESSAGE 送信の合計バイト上限（通常時）。
  final int sessionByteBudget;

  /// 自分の HELLO に載せる能力ビット。
  final int caps;

  /// 自分の HELLO に載せる参加グループ（中継役のときだけ非空、C17）。
  final List<int> groupIds;

  /// 相手の HELLO を受け取ったときに呼ばれる（重複セッションの判定用）。
  /// この中で [abort] を呼んでもよい。
  final void Function(SyncSession session)? onHello;

  /// 受け側（peripheral）が、相手に自分から接続できないか（HELLO 後に判定）。
  /// true なら MESSAGES_END で「短い間隔で同期しに来てほしい」と伝える。
  final bool Function(SyncSession session)? cannotReachPeer;

  /// 相手（ノード ID）が前回の同期の後に持っているはずの msg_id（先出しを省く、v2.3）。
  final Set<int>? Function(Uint8List nodeId)? knownPeerIds;

  /// 相手の TIME を受け取ったときに呼ばれる（相手の時計 − 自分の時計、秒）。
  final void Function(int offsetSeconds)? onPeerTime;

  final MessageStore _store;
  final Uint8List _nodeId;
  final Future<void> Function(Uint8List chunk) _send;
  final Future<void> Function() _close;
  final int Function() _now;
  final void Function(String)? _log;
  final TimerFactory _createTimer;
  final Duration _helloTimeout;
  Duration _sessionTimeout;
  int _byteBudget;
  final ReceiveBudget _receiveBudget;
  int _pendingReceiveMessages = 0;
  int _pendingReceiveBytes = 0;
  int _messageBytesReceived = 0;
  int _controlBytesReceived = 0;
  int _inventoryIdsReceived = 0;
  bool _sentStoreConfirmation = false;
  bool _peerStoreConfirmation = false;
  final Set<int> _confirmedSentIds = <int>{};
  bool _finishingInitiator = false;

  final FrameParser _parser = FrameParser();
  final Set<int> _peerHas = <int>{};

  /// 相手の目録の要約（INVENTORY_FILTER、v2.3）。
  InventoryFilter? _peerFilter;

  /// 自分の要約に使う salt（セッションごとに変え、偽陽性で送られなかったものが
  /// 次のすれ違いで送られるようにする）。
  final int _salt = InventoryFilter.randomSalt();

  /// 相手の HELLO が届いた（目録の形式を決めるため待つ）。
  final Completer<void> _peerHelloReceived = Completer<void>();

  /// 先出しが終わるまで（先出しを目録より先に流す）。
  Future<void> _pushDone = Future<void>.value();
  final Set<int> _pushed = <int>{};
  final List<int> _sentIds = <int>[];

  /// 相手から MESSAGE で受け取った msg_id（新規・既知どちらも）。
  final Set<int> _receivedIds = <int>{};
  final Completer<void> _doneCompleter = Completer<void>();
  final Completer<void> _startCompleter = Completer<void>();
  final Completer<void> _peerInventoryEnd = Completer<void>();

  SessionState _state = SessionState.hello;
  HelloInfo? _peerHello;
  int? _peerCutoff;
  int? _clockOffset;
  int _bytesSent = 0;
  int _bytesReceived = 0;
  int _messageBytesSent = 0;
  int _opaqueBytesSent = 0;
  int _messagesSent = 0;
  int _messagesReceived = 0;
  bool _started = false;
  bool _sentMessagesEnd = false;
  bool _peerMessagesEnd = false;
  bool _closeRequested = false;
  bool _budgetExhausted = false;
  bool _peerHasMore = false;
  bool _peerWantsPoll = false;
  bool _relaxed = false;
  String? _failureReason;
  Timer? _helloTimer;
  Timer? _sessionTimer;
  final Stopwatch _watch = Stopwatch();
  Duration? _firstMessageAfter;

  /// 送信待ちのフレーム。順に詰めて、1 回の書き込みを maxChunk いっぱいに使う
  /// （お知らせ 1 件 約 160 B を 1 回ずつ書くと 512 B の 3 割しか使えない、#152）。
  final Queue<({Uint8List bytes, Completer<void>? done})> _out =
      Queue<({Uint8List bytes, Completer<void>? done})>();
  int _outOffset = 0;
  int _outBuffered = 0;
  bool _pumping = false;
  Completer<void>? _drained;
  Object? _sendError;

  /// 受信した MESSAGE の保存（[_drainStores]）が終わると完了する。
  Future<void> _storeQueue = Future<void>.value();

  /// 保存待ちの受信封筒。書き込み中に届いた分はまとめて 1 回で保存する
  /// （1 件ずつ fsync すると 300 件で 50 秒かかった、#152 の実測）。
  final Queue<({Envelope envelope, int bytes})> _pendingStores = Queue();
  bool _storing = false;

  SessionState get state => _state;

  /// 保存確認を使うのは両方の HELLO で対応が分かったときだけ。
  bool get confirmsStorage => (caps & peerCaps & kCapStoreConfirmation) != 0;
  bool get peerStorageConfirmed => confirmsStorage && _peerStoreConfirmation;
  List<int> get confirmedSentMessageIds => List.unmodifiable(_confirmedSentIds);
  int get pendingReceiveMessages => _pendingReceiveMessages;
  int get pendingReceiveBytes => _pendingReceiveBytes;
  bool get _storageReady =>
      !confirmsStorage || (_sentStoreConfirmation && _peerStoreConfirmation);

  /// 相手のノード ID（HELLO 受信後）。
  Uint8List? get peerNodeId => _peerHello?.nodeId;

  /// 相手の保存件数（HELLO 受信後）。
  int? get peerStoreCount => _peerHello?.storeCount;

  /// 相手の能力ビット（HELLO 受信後）。
  int get peerCaps => _peerHello?.caps ?? 0;

  /// 相手の参加グループ（相手が中継役で載せてきたときだけ）。
  List<int> get peerGroupIds => _peerHello?.groupIds ?? const [];

  /// 相手が中継役か。
  bool get peerIsRelay => _peerHello?.isRelayNode ?? false;

  /// 自分が中継役か。
  bool get isRelay => (caps & kCapRelayNode) != 0;

  /// 中継役どうしで上限を緩めたセッションか。
  bool get relaxed => _relaxed;

  /// 相手の時計 − 自分の時計（秒）。TIME 未受信なら null。
  int? get clockOffset => _clockOffset;

  /// リンクに送った総バイト数。
  int get bytesSent => _bytesSent;

  /// リンクから受け取った総バイト数。
  int get bytesReceived => _bytesReceived;

  /// 送った MESSAGE の件数（先出しを含む）。
  int get messagesSent => _messagesSent;

  /// 始めてから終わるまで（終わっていなければ今まで）の時間。転送速度の実測用。
  Duration get elapsed => _watch.elapsed;

  /// 始めてから最初の MESSAGE を受け取るまでの時間。受け取っていなければ null。
  Duration? get firstMessageAfter => _firstMessageAfter;

  /// 先出しした件数。
  int get pushedCount => _pushed.length;

  /// 送った MESSAGE の msg_id（順）。
  List<int> get sentMessageIds => List.unmodifiable(_sentIds);

  /// このセッションの後に相手が持っているはずの msg_id（相手の目録 ∪ 渡したもの
  /// ∪ 受け取ったもの）。次に同期し直す必要があるかの判定に使う。
  Set<int> get knownByPeer {
    final known = <int>{..._peerHas, ..._confirmedSentIds, ..._receivedIds};
    final filter = _peerFilter;
    if (filter != null) {
      for (final m in _store.all) {
        if (filter.mightContain(m.msgId)) {
          known.add(m.msgId);
        }
      }
    }
    return known;
  }

  /// 途中で切れたセッションでも確かな「相手が持っているもの」（相手の目録 ∪
  /// 相手から受け取ったもの。渡したものは届いたか分からないので含めない）。
  Set<int> get knownByPeerConfirmed {
    final known = <int>{..._peerHas, ..._confirmedSentIds, ..._receivedIds};
    final filter = _peerFilter;
    if (filter != null) {
      for (final m in _store.all) {
        if (filter.mightContain(m.msgId)) {
          known.add(m.msgId);
        }
      }
    }
    return known;
  }

  /// 相手が [msgId] を持っているか（目録の一覧、または要約での判定）。
  bool _peerMayHave(int msgId) =>
      _peerHas.contains(msgId) || (_peerFilter?.mightContain(msgId) ?? false);

  /// 新規に保存できた受信 MESSAGE の件数。
  int get messagesReceived => _messagesReceived;

  /// バイト上限で送信を打ち切ったか。
  bool get budgetExhausted => _budgetExhausted;

  /// 相手が送信上限で打ち切った（まだ渡すものがある）と知らせてきたか。
  bool get peerHasMore => _peerHasMore;

  /// 相手（受け側）がこちらへ接続できないので、短い間隔で同期しに来てほしいと言ったか。
  bool get peerWantsPoll => _peerWantsPoll;

  /// どちらかに渡しきれなかったものがある（すぐ続きの同期をする）。
  bool get hasMore => _budgetExhausted || _peerHasMore;

  /// 正常終了したか（[done] 完了後に有効）。
  bool get succeeded => _state == SessionState.done;

  /// 失敗理由（失敗時のみ）。
  String? get failureReason => _failureReason;

  bool get isFinished =>
      _state == SessionState.done || _state == SessionState.failed;

  /// 終了（成功 / 失敗どちらでも完了する。エラーにはならない）。
  Future<void> get done => _doneCompleter.future;

  /// HELLO と TIME を送る。送り終えたら完了する。目録（相手の HELLO を見て
  /// 要約か一覧かを決める）以降の転送はバックグラウンドで続く（[done] で待つ）。
  Future<void> start() {
    if (_started) {
      return _startCompleter.future;
    }
    _started = true;
    _watch.start();
    _helloTimer = _createTimer(_helloTimeout, () {
      if (_state == SessionState.hello) {
        _fail('HELLO 待ちタイムアウト');
      }
    });
    _armSessionTimer();
    unawaited(_run());
    return _startCompleter.future;
  }

  void _armSessionTimer() {
    _sessionTimer?.cancel();
    _sessionTimer = _createTimer(_sessionTimeout, () {
      if (_state == SessionState.closing && _storageReady) {
        // 双方の保存確認後（旧版は旧手順）、BYE が来ない場合の後片付け。
        unawaited(_finishAfterStores(success: true));
      } else {
        _fail('セッションタイムアウト');
      }
    });
  }

  Future<void> _run() async {
    try {
      final now = _now();
      await _enqueueSend(
        Frame.hello(
          nodeId: _nodeId,
          storeCount: _store.count,
          caps: caps,
          groupIds: isRelay ? groupIds : const [],
        ).encode(),
      );
      await _enqueueSend(Frame.time(now).encode());
      if (!_startCompleter.isCompleted) {
        _startCompleter.complete();
      }
      // 相手の HELLO を見て目録の形式を決める。先出し（SOS・避難情報など）を先に流す。
      await _peerHelloReceived.future;
      if (isFinished) {
        return;
      }
      await _pushDone;
      if (isFinished) {
        return;
      }
      if ((caps & kCapInventoryFilter) != 0 &&
          (peerCaps & kCapInventoryFilter) != 0) {
        // 双方が対応していれば、目録を要約（約 1/7 の大きさ）で送る。
        final ids = _store.inventory(now: _now());
        final filter = InventoryFilter.build(ids, salt: _salt);
        await _enqueueSend(Frame.inventoryFilter(filter.encode()).encode());
        await _enqueueSend(Frame.inventoryEnd().encode());
        _logLine('在庫 ${ids.length} 件を要約で送信（${filter.bits.length} B）');
      } else {
        final selection = _store.inventorySelection(
          now: _now(),
          small: maxChunk < kSmallChunkThreshold,
        );
        for (final frame in Frame.inventoryFrames(selection.msgIds)) {
          await _enqueueSend(frame.encode());
        }
        final cutoff = selection.cutoffCreatedAt;
        if (cutoff != null) {
          await _enqueueSend(Frame.inventoryCutoff(cutoff).encode());
        }
        await _enqueueSend(Frame.inventoryEnd().encode());
        _logLine(
          '在庫 ${selection.msgIds.length} 件を送信'
          '${cutoff != null ? '（絞り込み）' : ''}',
        );
      }

      await _peerInventoryEnd.future;
      if (isFinished) {
        return;
      }
      final peer = _peerHello;
      final missing = _store.messagesMissingFrom(
        _peerMayHave,
        now: _now(),
        peerRelaysUnknown: peer?.relaysUnknown ?? false,
        cutoffCreatedAt: _peerCutoff,
        peerGroups: (peer != null && peer.groupIds.isNotEmpty)
            ? peer.groupIds.toSet()
            : null,
        exclude: _pushed,
      );
      for (final m in missing) {
        if (isFinished) {
          return;
        }
        final sent = _sendMessage(m);
        if (sent == _SendOutcome.budget) {
          _budgetExhausted = true;
          _logLine('送信上限 $_byteBudget バイトに達したため打ち切り');
          break;
        }
        if (_outBuffered > maxChunk * 2) {
          await _waitDrain();
        }
      }
      if (isFinished) {
        return;
      }
      final pollMe = !initiator && (cannotReachPeer?.call(this) ?? false);
      await _enqueueSend(
        Frame.messagesEnd(more: _budgetExhausted, pollMe: pollMe).encode(),
      );
      _sentMessagesEnd = true;
      _logLine(
        'MESSAGE $_messagesSent 件を送信'
        '${_pushed.isNotEmpty ? '（先出し ${_pushed.length} 件）' : ''}',
      );
      _checkBothDone();
    } on Object catch (e) {
      _fail('送信エラー: $e');
    }
  }

  /// 1 件の MESSAGE を上限内で送信待ちに積む。
  _SendOutcome _sendMessage(StoredMessage m) {
    final wire = m.wireBytesAt(
      _now(),
      localExpiresAt: _store.localExpiresAt(m),
    );
    final bytes = Frame.message(wire).encode();
    if (_messageBytesSent + bytes.length > _byteBudget) {
      return _SendOutcome.budget;
    }
    if (m.isOpaque) {
      if (_opaqueBytesSent + bytes.length > kMaxOpaqueBytesPerSession) {
        return _SendOutcome.skipped;
      }
      _opaqueBytesSent += bytes.length;
    }
    _bufferSend(bytes);
    _messageBytesSent += bytes.length;
    _messagesSent++;
    _sentIds.add(m.msgId);
    return _SendOutcome.sent;
  }

  /// 相手の HELLO 直後に、公式の新着などを目録交換を待たずに送る（C08）。
  Future<void> _sendPush() async {
    final peerNode = peerNodeId;
    final known = peerNode == null ? null : knownPeerIds?.call(peerNode);
    final candidates = _store.pushCandidates(
      now: _now(),
      skip: known ?? const <int>{},
    );
    var bytes = 0;
    for (final m in candidates) {
      if (isFinished || _sentMessagesEnd) {
        return;
      }
      final wire = m.wireBytesAt(
        _now(),
        localExpiresAt: _store.localExpiresAt(m),
      );
      final frame = Frame.message(wire).encode();
      if (bytes + frame.length > kPushMaxBytes) {
        break;
      }
      if (_messageBytesSent + frame.length > _byteBudget) {
        break;
      }
      bytes += frame.length;
      _pushed.add(m.msgId);
      _bufferSend(frame);
      _messageBytesSent += frame.length;
      _messagesSent++;
      _sentIds.add(m.msgId);
      if (_outBuffered > maxChunk * 2) {
        await _waitDrain();
      }
    }
    if (_pushed.isNotEmpty) {
      _logLine('先出し ${_pushed.length} 件 ($bytes B)');
    }
  }

  /// フレームを送信待ちに積み、書き終えたら完了する（順序は積んだ順）。
  Future<void> _enqueueSend(Uint8List bytes) {
    final err = _sendError;
    if (err != null) {
      return Future<void>.error(err);
    }
    final done = Completer<void>();
    done.future.ignore();
    _queueOut(bytes, done);
    return done.future;
  }

  /// フレームを送信待ちに積むだけで、書き終えるのは待たない（お知らせを続けて
  /// 送るとき、書き込みを詰めるため）。積みすぎないよう [_waitDrain] と組にする。
  void _bufferSend(Uint8List bytes) {
    final err = _sendError;
    if (err != null) {
      throw err;
    }
    _queueOut(bytes, null);
  }

  /// 送信待ちが 2 チャンク分を超えている間だけ待つ。
  Future<void> _waitDrain() async {
    while (_outBuffered > maxChunk * 2 && _sendError == null) {
      await (_drained ??= Completer<void>()).future;
    }
    final err = _sendError;
    if (err != null) {
      throw err;
    }
  }

  void _queueOut(Uint8List bytes, Completer<void>? done) {
    _out.add((bytes: bytes, done: done));
    _outBuffered += bytes.length;
    if (!_pumping) {
      _pumping = true;
      unawaited(_pump());
    }
  }

  void _wakeDrained() {
    final d = _drained;
    if (d != null && (_outBuffered <= maxChunk * 2 || _sendError != null)) {
      _drained = null;
      d.complete();
    }
  }

  /// 送信待ちを先頭から maxChunk ずつ詰めて書く。フレームの境目はまたいでよい
  /// （受け手はバイト列としてつなげてから区切る）。
  Future<void> _pump() async {
    var finished = <Completer<void>>[];
    try {
      while (_out.isNotEmpty) {
        if (isFinished) {
          throw StateError('セッションは終了しています');
        }
        final b = BytesBuilder(copy: false);
        finished = <Completer<void>>[];
        while (b.length < maxChunk && _out.isNotEmpty) {
          final head = _out.first;
          final rest = head.bytes.length - _outOffset;
          final room = maxChunk - b.length;
          final take = rest < room ? rest : room;
          b.add(
            Uint8List.sublistView(head.bytes, _outOffset, _outOffset + take),
          );
          _outOffset += take;
          if (_outOffset == head.bytes.length) {
            _out.removeFirst();
            _outOffset = 0;
            final done = head.done;
            if (done != null) {
              finished.add(done);
            }
          }
        }
        final data = b.takeBytes();
        await _send(data);
        _bytesSent += data.length;
        _outBuffered -= data.length;
        for (final c in finished) {
          c.complete();
        }
        finished = <Completer<void>>[];
        _wakeDrained();
      }
    } on Object catch (e, st) {
      _sendError = e;
      for (final c in finished) {
        c.completeError(e, st);
      }
      for (final item in _out) {
        item.done?.completeError(e, st);
      }
      _out.clear();
      _outOffset = 0;
      _outBuffered = 0;
      _wakeDrained();
      _fail('送信エラー: $e');
    } finally {
      _pumping = false;
    }
  }

  // ---------------------------------------------------------------------------
  // 受信
  // ---------------------------------------------------------------------------

  /// 受信チャンクを処理する。
  void onData(Uint8List chunk) {
    if (isFinished) {
      return;
    }
    _bytesReceived += chunk.length;
    final receiveLimit = relaxed
        ? kRelaySessionByteBudget
        : kDefaultSessionByteBudget;
    if (_bytesReceived > receiveLimit + kMaxSessionControlBytes) {
      _fail('受信総量の上限を超えました');
      return;
    }
    try {
      _parser.addChunk(chunk);
    } on FrameFormatException catch (e) {
      _fail('不正なフレーム: ${e.message}');
      return;
    }
    Frame? frame;
    while (!isFinished && (frame = _parser.nextFrame()) != null) {
      _handleFrame(frame!);
    }
  }

  void _handleFrame(Frame frame) {
    final type = frame.type;
    if (type != FrameType.message) {
      _controlBytesReceived += 3 + frame.payload.length;
      if (_controlBytesReceived > kMaxSessionControlBytes) {
        _fail('制御データの受信上限を超えました');
        return;
      }
    }
    if (type == null) {
      // 不明な type は読み飛ばす。
      return;
    }
    if (_state == SessionState.hello && type != FrameType.hello) {
      _fail('HELLO より前に ${type.name} を受信');
      return;
    }
    switch (type) {
      case FrameType.hello:
        _onHello(frame);
      case FrameType.time:
        _onTime(frame);
      case FrameType.inventory:
        _onInventory(frame);
      case FrameType.inventoryCutoff:
        _onInventoryCutoff(frame);
      case FrameType.inventoryFilter:
        _onInventoryFilter(frame);
      case FrameType.inventoryEnd:
        _onInventoryEnd();
      case FrameType.message:
        _onMessage(frame);
      case FrameType.messagesEnd:
        _peerHasMore = Frame.messagesEndHasMore(frame.payload);
        _peerWantsPoll = initiator && Frame.messagesEndPollMe(frame.payload);
        _onMessagesEnd();
      case FrameType.stored:
        _onStored(frame);
      case FrameType.bye:
        _onBye();
    }
  }

  void _onHello(Frame frame) {
    if (_state != SessionState.hello) {
      _fail('HELLO を二重に受信');
      return;
    }
    final HelloInfo hello;
    try {
      hello = HelloInfo.parse(frame.payload);
    } on FrameFormatException catch (e) {
      _fail('不正な HELLO: ${e.message}');
      return;
    }
    _peerHello = hello;
    _helloTimer?.cancel();
    _helloTimer = null;
    _state = SessionState.inventory;
    _logLine(
      'HELLO 受信 node=${hexOf(hello.nodeId)} 件数=${hello.storeCount}'
      '${hello.version != kProtocolVersionForHello ? ' version=${hello.version}' : ''}'
      '${hello.isRelayNode ? ' 中継役' : ''}',
    );
    if (isRelay && hello.isRelayNode) {
      _relaxed = true;
      _byteBudget = maxChunk < kRelaySmallChunkThreshold
          ? kRelaySmallChunkByteBudget
          : kRelaySessionByteBudget;
      _sessionTimeout = kRelaySessionTimeout;
      _armSessionTimer();
      _logLine('中継役どうし: 上限 $_byteBudget バイト、${_sessionTimeout.inSeconds} 秒');
    }
    onHello?.call(this);
    if (!isFinished && hello.acceptsPush) {
      _pushDone = _sendPush().catchError((Object e) {
        _logLine('先出しに失敗: $e');
      });
    }
    if (!_peerHelloReceived.isCompleted) {
      _peerHelloReceived.complete();
    }
  }

  void _onTime(Frame frame) {
    try {
      final peerTime = parseU32Payload(frame.payload, name: 'TIME');
      final offset = peerTime - _now();
      _clockOffset = offset;
      onPeerTime?.call(offset);
    } on FrameFormatException catch (e) {
      _logLine('不正な TIME を無視: ${e.message}');
    }
  }

  void _onInventory(Frame frame) {
    if (_state != SessionState.inventory) {
      _fail('INVENTORY の順序が不正');
      return;
    }
    try {
      final ids = parseInventory(frame.payload);
      _inventoryIdsReceived += ids.length;
      if (_inventoryIdsReceived > kDefaultInventoryLimit ||
          _peerFilter != null) {
        _fail('目録の受信上限または形式が不正');
        return;
      }
      _peerHas.addAll(ids);
    } on FrameFormatException catch (e) {
      _fail('不正な INVENTORY: ${e.message}');
    }
  }

  void _onInventoryFilter(Frame frame) {
    if (_state != SessionState.inventory) {
      _fail('INVENTORY_FILTER の順序が不正');
      return;
    }
    try {
      final filter = InventoryFilter.decode(frame.payload);
      if (_peerFilter != null ||
          _inventoryIdsReceived != 0 ||
          filter.itemCount > kDefaultInventoryLimit) {
        _fail('目録の受信上限または形式が不正');
        return;
      }
      _peerFilter = filter;
    } on FormatException catch (e) {
      _fail('不正な INVENTORY_FILTER: ${e.message}');
    }
  }

  void _onInventoryCutoff(Frame frame) {
    if (_state != SessionState.inventory) {
      return;
    }
    try {
      _peerCutoff = parseU32Payload(frame.payload, name: 'INVENTORY_CUTOFF');
    } on FrameFormatException catch (e) {
      _logLine('不正な INVENTORY_CUTOFF を無視: ${e.message}');
    }
  }

  void _onInventoryEnd() {
    if (_state != SessionState.inventory) {
      _fail('INVENTORY_END の順序が不正');
      return;
    }
    _state = SessionState.transfer;
    final filter = _peerFilter;
    _logLine(
      filter != null
          ? '相手の在庫 ${filter.itemCount} 件（要約 ${filter.bits.length} B）'
          : '相手の在庫 ${_peerHas.length} 件',
    );
    if (!_peerInventoryEnd.isCompleted) {
      _peerInventoryEnd.complete();
    }
  }

  void _onMessage(Frame frame) {
    // 先出し（C08）は相手の INVENTORY より前に届くことがある。
    if (_state != SessionState.inventory && _state != SessionState.transfer) {
      _fail('MESSAGE の順序が不正');
      return;
    }
    if (_peerMessagesEnd) {
      _fail('MESSAGES_END の後に MESSAGE を受信');
      return;
    }
    _messageBytesReceived += 3 + frame.payload.length;
    final receiveLimit = relaxed
        ? kRelaySessionByteBudget
        : kDefaultSessionByteBudget;
    if (_messageBytesReceived > receiveLimit) {
      _fail('MESSAGE の受信上限を超えました');
      return;
    }
    final Envelope envelope;
    try {
      envelope = Envelope.decode(frame.payload);
    } on EnvelopeFormatException catch (e) {
      // 不正な封筒は捨てるが、セッションは続ける。
      _logLine('不正な封筒を破棄: ${e.message}');
      return;
    }
    _firstMessageAfter ??= _watch.elapsed;
    _receivedIds.add(envelope.msgId);
    final nextHop = envelope.hop + 1 > kMaxHopValue
        ? kMaxHopValue
        : envelope.hop + 1;
    final relayed = envelope.copyWith(hop: nextHop);
    final bytes =
        frame.payload.length +
        (envelope.isOpaque ? 0 : envelope.bodyPlain.length) +
        128;
    if (_pendingReceiveMessages >= kMaxPendingReceiveMessages ||
        _pendingReceiveBytes + bytes > kMaxPendingReceiveBytes ||
        !_receiveBudget.reserve(bytes)) {
      _fail('保存待ちの受信上限に達しました。次の交換で再試行します');
      return;
    }
    _pendingReceiveMessages++;
    _pendingReceiveBytes += bytes;
    _pendingStores.add((envelope: relayed, bytes: bytes));
    if (!_storing) {
      _storing = true;
      _storeQueue = _drainStores();
    }
  }

  Future<void> _drainStores() async {
    try {
      while (_pendingStores.isNotEmpty && !isFinished) {
        final batch = <Envelope>[];
        var bytes = 0;
        while (_pendingStores.isNotEmpty && batch.length < kStoreBatchSize) {
          final pending = _pendingStores.removeFirst();
          batch.add(pending.envelope);
          bytes += pending.bytes;
        }
        try {
          _messagesReceived += await _store.addAll(batch, now: _now());
        } on Object catch (e) {
          _fail('保存に失敗: $e');
        } finally {
          _releaseReceived(batch.length, bytes);
        }
      }
    } finally {
      _storing = false;
    }
  }

  void _releaseReceived(int count, int bytes) {
    _pendingReceiveMessages -= count;
    _pendingReceiveBytes -= bytes;
    _receiveBudget.release(count, bytes);
  }

  void _discardPendingStores() {
    var bytes = 0;
    for (final pending in _pendingStores) {
      bytes += pending.bytes;
    }
    _releaseReceived(_pendingStores.length, bytes);
    _pendingStores.clear();
  }

  /// 受け取った封筒をすべて保存し終えるまで待つ。
  Future<void> _waitStores() async {
    while (_storing) {
      await _storeQueue;
    }
  }

  void _onMessagesEnd() {
    if (_state != SessionState.transfer) {
      _fail('MESSAGES_END の順序が不正');
      return;
    }
    if (_peerMessagesEnd) {
      _fail('MESSAGES_END を二重に受信');
      return;
    }
    _peerMessagesEnd = true;
    _checkBothDone();
  }

  void _onStored(Frame frame) {
    // 旧版には送らない。余分な確認や、送っていない ID の確認は受理しない。
    if (!confirmsStorage ||
        !_peerMessagesEnd ||
        _peerStoreConfirmation ||
        frame.payload.length < 3 ||
        (frame.payload[0] & ~1) != 0) {
      _fail('STORED の順序または形式が不正');
      return;
    }
    try {
      final ids = parseInventory(Uint8List.sublistView(frame.payload, 1));
      final sent = _sentIds.toSet();
      if (ids.any((id) => !sent.contains(id)) ||
          _confirmedSentIds.length + ids.length > _sentIds.length) {
        _fail('送っていない ID の保存確認');
        return;
      }
      final last = (frame.payload[0] & 1) != 0;
      if (last && ids.isNotEmpty) {
        _fail('STORED 最終フレームには ID を載せられません');
        return;
      }
      _confirmedSentIds.addAll(ids);
      if (last) {
        _peerStoreConfirmation = true;
        _maybeFinishInitiator();
      }
    } on FrameFormatException catch (e) {
      _fail('不正な STORED: ${e.message}');
    }
  }

  void _onBye() {
    if (_state == SessionState.closing && _storageReady) {
      unawaited(_finishAfterStores(success: true));
    } else {
      _fail('保存確認前に相手から BYE を受信');
    }
  }

  /// 双方の送信完了後に保存を待ち、対応端末間では保存確認を交換する。
  void _checkBothDone() {
    if (isFinished || _state == SessionState.closing) {
      return;
    }
    if (_sentMessagesEnd && _peerMessagesEnd) {
      _state = SessionState.closing;
      unawaited(_confirmStored());
    }
  }

  Future<void> _confirmStored() async {
    await _waitStores();
    if (isFinished) {
      return;
    }
    if (confirmsStorage) {
      try {
        final ids = _receivedIds.where(_store.isDurablyStored).toList();
        for (
          var offset = 0;
          offset < ids.length;
          offset += kMaxInventoryPerFrame
        ) {
          final end = offset + kMaxInventoryPerFrame;
          await _enqueueSend(
            Frame.stored(
              ids.sublist(offset, end < ids.length ? end : ids.length),
            ).encode(),
          );
        }
        // 相手が最終フレームに即応して BYE を返しても、保存済みと判定できる。
        _sentStoreConfirmation = true;
        await _enqueueSend(Frame.stored(const [], last: true).encode());
      } on Object catch (e) {
        _fail('保存確認の送信に失敗: $e');
        return;
      }
    }
    _maybeFinishInitiator();
  }

  void _maybeFinishInitiator() {
    if (!isFinished &&
        _state == SessionState.closing &&
        initiator &&
        _storageReady &&
        !_finishingInitiator) {
      _finishingInitiator = true;
      unawaited(_finishAsInitiator());
    }
  }

  Future<void> _finishAsInitiator() async {
    await _waitStores();
    if (isFinished) {
      return;
    }
    try {
      await _enqueueSend(Frame.bye().encode());
    } on Object catch (_) {
      // 相手が先に切っていても正常終了扱い。
    }
    await _requestClose();
    _finish(SessionState.done, null);
  }

  Future<void> _finishAfterStores({required bool success}) async {
    await _waitStores();
    if (isFinished) {
      return;
    }
    await _requestClose();
    _finish(
      success ? SessionState.done : SessionState.failed,
      success ? null : '切断',
    );
  }

  /// リンクが閉じられた。
  void onClosed() {
    if (isFinished) {
      return;
    }
    if (_state == SessionState.closing && _storageReady) {
      _closeRequested = true;
      unawaited(_finishAfterStores(success: true));
    } else {
      _closeRequested = true;
      _fail('リンクが切断されました');
    }
  }

  /// BYE を送ってリンクを閉じ、失敗として終了する。
  void abort(String reason) {
    if (isFinished) {
      return;
    }
    _fail(reason, sendBye: true);
  }

  void _fail(String reason, {bool sendBye = true}) {
    if (isFinished) {
      return;
    }
    _failureReason = reason;
    _logLine('失敗: $reason');
    _state = SessionState.failed;
    _discardPendingStores();
    unawaited(_shutdown(sendBye: sendBye));
  }

  Future<void> _shutdown({required bool sendBye}) async {
    if (sendBye && !_closeRequested) {
      try {
        await _send(Frame.bye().encode());
      } on Object catch (_) {
        // 送れなくても閉じる。
      }
    }
    await _requestClose();
    _finish(SessionState.failed, _failureReason);
  }

  Future<void> _requestClose() async {
    if (_closeRequested) {
      return;
    }
    _closeRequested = true;
    try {
      await _close();
    } on Object catch (_) {
      // 既に閉じていれば無視。
    }
  }

  void _finish(SessionState finalState, String? reason) {
    _watch.stop();
    _helloTimer?.cancel();
    _sessionTimer?.cancel();
    _helloTimer = null;
    _sessionTimer = null;
    _state = finalState;
    _failureReason = reason;
    if (!_peerInventoryEnd.isCompleted) {
      _peerInventoryEnd.complete();
    }
    if (!_peerHelloReceived.isCompleted) {
      _peerHelloReceived.complete();
    }
    if (!_startCompleter.isCompleted) {
      _startCompleter.complete();
    }
    if (!_doneCompleter.isCompleted) {
      if (finalState == SessionState.done) {
        _logLine(
          '完了 送信 $_messagesSent 件 / 受信 $_messagesReceived 件 '
          '($_bytesSent B ↑ / $_bytesReceived B ↓)',
        );
      }
      _doneCompleter.complete();
    }
  }

  void _logLine(String message) {
    _log?.call('[link $linkId ${initiator ? 'C' : 'P'}] $message');
  }
}

enum _SendOutcome { sent, skipped, budget }
