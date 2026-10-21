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

/// 時計のずれの判定に使う直近の TIME の件数。
const int kClockSamples = 8;

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

class _NodeSync {
  _NodeSync({required this.lastSyncAt, required this.version, this.relay = false});
  final int lastSyncAt;
  final int version;

  /// 相手が中継役だったか（中継役どうしは短い間隔で再接続する）。
  final bool relay;
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

  StreamSubscription<TransportEvent>? _subscription;
  final Map<String, PeerRecord> _peers = <String, PeerRecord>{};
  final Map<String, _NodeSync> _nodeSync = <String, _NodeSync>{};
  final Map<int, SyncSession> _sessions = <int, SyncSession>{};
  final Map<String, int> _pendingConnects = <String, int>{};
  final Set<SyncSession> _abortedByNode = <SyncSession>{};
  final Queue<String> _log = Queue<String>();
  final Queue<int> _clockOffsets = Queue<int>();

  bool _running = false;
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

  /// 直近 60 秒に見えた端末数。
  int get nearbyCount {
    final t = _now();
    return _peers.values
        .where((p) => t - p.lastSeen <= kNearbyWindowSeconds)
        .length;
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
    _logLine('開始 node=$_nodeIdHex${lowPower ? ' (省電力)' : ''}'
        '${_relayMode ? ' (中継役)' : ''}');
    notifyListeners();
  }

  Future<void> stop() async {
    if (!_running) {
      return;
    }
    _running = false;
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
    _subscription?.cancel();
    _subscription = null;
    super.dispose();
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

  void _reconnectRecentPeers() {
    if (!_running) {
      return;
    }
    final t = _now();
    for (final p in _peers.values) {
      // 受信リンクでしか見ていない相手（central 側のランダムアドレス）には
      // 接続できないので、広告で発見した相手だけに再接続する。
      if (p.lastDiscoveredAt != null && t - p.lastSeen <= kNearbyWindowSeconds) {
        _maybeConnect(p);
      }
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
        final interval = (sync.relay && _relayMode)
            ? kRelayResyncIntervalSeconds
            : resyncIntervalSeconds;
        if (t - sync.lastSyncAt < interval && sync.version == _store.version) {
          return;
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

  void _onConnectFailed(PeerRecord p, String reason) {
    _pendingConnects.remove(p.peerId);
    p.failures++;
    final t = _now();
    final noService = reason.toLowerCase().contains('service');
    if ((p.viaApple && !p.serviceConfirmed) || noService) {
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
    );
    _sessions[e.linkId] = session;
    _totalSessions++;
    _logLine('リンク確立 ${e.peerId} link=${e.linkId} '
        '${e.initiator ? 'central' : 'peripheral'} chunk=${e.maxChunk}');
    unawaited(session.done.then((_) => _onSessionDone(session, p)));
    unawaited(session.start());
    notifyListeners();
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

  void _onSessionDone(SyncSession session, PeerRecord p) {
    _sessions.remove(session.linkId);
    final t = _now();
    final peerNode = session.peerNodeId;
    final hex = peerNode != null ? hexOf(peerNode) : null;
    if (hex != null) {
      p.nodeIdHex = hex;
    }
    _totalMessagesReceived += session.messagesReceived;
    _totalMessagesSent += session.messagesSent;
    if (session.messagesReceived > 0) {
      _lastReceivedAt = t;
    }
    if (session.messagesSent > 0) {
      _lastSentAt = t;
    }
    if (session.succeeded) {
      p.failures = 0;
      p.lastSyncAt = t;
      p.lastSyncedVersion = _store.version;
      p.backoffUntil = 0;
      _lastSyncAt = t;
      if (hex != null) {
        _nodeSync[hex] = _NodeSync(
            lastSyncAt: t, version: _store.version, relay: session.peerIsRelay);
      }
      _logLine('同期完了 ${p.peerId} 受信 ${session.messagesReceived} 件 '
          '送信 ${session.messagesSent} 件');
      onSyncCompleted?.call(t, session.messagesSent, session.messagesReceived);
    } else if (!_abortedByNode.remove(session)) {
      // 同じ相手と別のセッションが進行中／直前に成功している場合は、
      // 相手側が重複リンクを閉じただけなので失敗に数えない。
      final otherActive = hex != null &&
          _sessions.values.any((s) {
            final n = s.peerNodeId;
            return n != null && hexOf(n) == hex;
          });
      final justSynced =
          p.lastSyncAt != null && t - p.lastSyncAt! < resyncIntervalSeconds;
      if (!otherActive && !justSynced) {
        p.failures++;
        p.backoffUntil = t + failureBackoffSeconds;
      }
      _logLine('同期失敗 ${p.peerId}: ${session.failureReason ?? ''}');
    }
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

  void _logLine(String message) {
    final time = dateTimeFromEpoch(_now());
    String two(int v) => v.toString().padLeft(2, '0');
    _log.addLast(
        '${two(time.hour)}:${two(time.minute)}:${two(time.second)} $message');
    while (_log.length > kRecentLogLines) {
      _log.removeFirst();
    }
  }
}
