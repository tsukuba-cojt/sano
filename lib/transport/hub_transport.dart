/// 開発用トランスポート: TCP ハブ（`tool/hub.dart`）経由で BLE を模擬する。
///
/// iOS シミュレータは BLE 非対応、Android エミュレータ同士も環境によっては
/// つながらないため、ホスト機で動くハブを「電波」としてメッセージを交換する。
/// 配線プロトコルは `lib/transport/hub_server.dart` を参照。
///
/// - Android エミュレータからホストへは `10.0.2.2`
/// - iOS シミュレータ / デスクトップからは `127.0.0.1`
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../mesh/transport.dart';

/// Android エミュレータから見たホスト機のアドレス。
const String kHubHostAndroidEmulator = '10.0.2.2';

/// iOS シミュレータ / デスクトップから見たホスト機のアドレス。
const String kHubHostLocal = '127.0.0.1';

/// `tool/hub.dart` の既定ポート。
const int kHubDefaultPort = 7777;

/// TCP ハブ経由の [Transport] 実装。
///
/// [start] でハブへ接続して登録し、切断されたら指数バックオフで再接続する。
/// [stop] で切断する。ハブが落ちている間に開いていたリンクは [LinkClosed] で
/// 通知される。
class HubTransport implements Transport {
  HubTransport(
    this.host,
    this.port, {
    String? peerId,
    this.initialBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 30),
    this.connectTimeout = const Duration(seconds: 5),
  }) : peerId = peerId ?? _randomPeerId();

  /// ハブのホスト名 / IP。
  final String host;

  /// ハブのポート。
  final int port;

  /// この端末の peerId（BLE のアドレスに相当）。再接続後も同じ値を使う。
  final String peerId;

  /// 再接続の初回待ち時間。
  final Duration initialBackoff;

  /// 再接続の最大待ち時間。
  final Duration maxBackoff;

  /// TCP 接続のタイムアウト。
  final Duration connectTimeout;

  final StreamController<TransportEvent> _events =
      StreamController<TransportEvent>.broadcast();

  Socket? _socket;
  StreamSubscription<String>? _lines;
  TransportConfig? _config;
  bool _running = false;
  bool _lowPower = false;
  bool _connecting = false;
  Duration _backoff = Duration.zero;
  Timer? _reconnectTimer;

  /// linkId → 相手の peerId。
  final Map<int, String> _links = <int, String>{};

  /// ハブに接続済みか。
  bool get connected => _socket != null;

  /// [start] 済みか。
  bool get running => _running;

  /// 省電力モードか（ハブ版では動作は変わらない）。
  bool get lowPower => _lowPower;

  /// 開いているリンク ID。
  Iterable<int> get openLinks => _links.keys;

  @override
  Stream<TransportEvent> get events => _events.stream;

  // ---------------------------------------------------------------- Transport

  @override
  Future<void> start(TransportConfig config) async {
    _config = config;
    _lowPower = config.lowPower;
    if (_running) {
      _log('すでに開始しています');
      return;
    }
    _running = true;
    _backoff = initialBackoff;
    await _connectOnce();
  }

  @override
  Future<void> stop() async {
    _running = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final socket = _socket;
    _socket = null;
    final lines = _lines;
    _lines = null;
    _closeAllLinks('停止');
    if (socket != null) {
      await lines?.cancel();
      socket.destroy();
      _log('ハブから切断しました');
    }
    _emitState();
  }

  @override
  Future<void> setLowPower(bool lowPower) async {
    _lowPower = lowPower;
    _log(lowPower ? '省電力モード: 入' : '省電力モード: 切');
  }

  @override
  Future<void> connect(String peerId) async {
    if (_socket == null) {
      _log('connect($peerId): ハブに接続していません');
      _emit(LinkClosed(linkId: 0, peerId: peerId, reason: 'ハブ未接続'));
      return;
    }
    try {
      await _write({'t': 'connect', 'peerId': peerId});
    } on Object catch (e) {
      _log('connect($peerId) 失敗: $e');
      _emit(LinkClosed(linkId: 0, peerId: peerId, reason: '$e'));
    }
  }

  @override
  Future<void> send(int linkId, Uint8List data) async {
    if (!_links.containsKey(linkId)) {
      throw StateError('リンク $linkId は開いていません');
    }
    // flush を待つことで TCP の背圧をそのままフロー制御にする。
    await _write({'t': 'data', 'linkId': linkId, 'data': base64Encode(data)});
  }

  @override
  Future<void> close(int linkId) async {
    if (!_links.containsKey(linkId)) {
      return;
    }
    if (_socket == null) {
      final peer = _links.remove(linkId);
      _emit(LinkClosed(linkId: linkId, peerId: peer, reason: 'ハブ未接続'));
      return;
    }
    try {
      // linkClosed はハブから両端に届く（実機の linkClosed イベントと同じ扱い）。
      await _write({'t': 'close', 'linkId': linkId});
    } on Object catch (e) {
      // 書き込み失敗時は _onDisconnected が全リンクを閉じている。
      _log('close($linkId) 失敗: $e');
    }
  }

  /// 停止してイベントストリームを閉じる。
  Future<void> dispose() async {
    await stop();
    await _events.close();
  }

  // ------------------------------------------------------------------ 接続

  Future<void> _connectOnce() async {
    if (!_running || _socket != null || _connecting) {
      return;
    }
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _connecting = true;
    final Socket socket;
    try {
      socket = await Socket.connect(host, port, timeout: connectTimeout);
    } on Object catch (e) {
      _connecting = false;
      _log('ハブ $host:$port に接続できません: $e');
      _emitState();
      _scheduleReconnect();
      return;
    }
    _connecting = false;
    if (!_running) {
      // 接続待ちの間に stop() された。
      socket.destroy();
      return;
    }
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } on Object {
      // 設定できなくても動作に支障はない。
    }
    _socket = socket;
    _backoff = initialBackoff;
    _lines = socket
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          _onLine,
          onError: (Object e) => _onDisconnected('$e'),
          onDone: () => _onDisconnected('切断されました'),
          cancelOnError: true,
        );
    // 登録 = 広告開始。
    try {
      await _write({
        't': 'register',
        'peerId': peerId,
        'nodeId': _hex(_config?.nodeId ?? Uint8List(0)),
      });
    } on Object {
      // _write 内で _onDisconnected 済み。
      return;
    }
    _log('ハブ $host:$port に接続しました (peerId=$peerId)');
    _emitState();
  }

  void _onDisconnected(String reason) {
    final socket = _socket;
    if (socket == null) {
      return;
    }
    _socket = null;
    _lines = null;
    socket.destroy();
    _closeAllLinks('ハブとの接続が切れました');
    _emitState();
    if (_running) {
      _log('ハブとの接続が切れました: $reason');
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (!_running || _reconnectTimer != null || _socket != null) {
      return;
    }
    final delay = _backoff;
    final next = _backoff * 2;
    _backoff = next > maxBackoff ? maxBackoff : next;
    _log('${(delay.inMilliseconds / 1000).toStringAsFixed(1)} 秒後に再接続します');
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      unawaited(_connectOnce());
    });
  }

  /// 書き込みは 1 本に直列化する。dart:io の [Socket.flush] は完了まで
  /// シンクを「bound」状態にするため、並行して write すると
  /// 「StreamSink is bound to a stream」で落ちる。
  Future<void> _writeChain = Future<void>.value();

  Future<void> _write(Map<String, Object?> msg) {
    final next = _writeChain.then((_) => _writeNow(msg));
    // 失敗しても次の書き込みを止めない。
    _writeChain = next.catchError((Object _) {});
    return next;
  }

  Future<void> _writeNow(Map<String, Object?> msg) async {
    final socket = _socket;
    if (socket == null) {
      throw StateError('ハブに接続していません');
    }
    try {
      socket.write('${jsonEncode(msg)}\n');
      await socket.flush();
    } on Object catch (e) {
      _onDisconnected('$e');
      rethrow;
    }
  }

  // ---------------------------------------------------------------- 受信

  void _onLine(String line) {
    if (line.trim().isEmpty) {
      return;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      _log('ハブからの JSON が不正です');
      return;
    }
    if (decoded is! Map) {
      return;
    }
    final msg = decoded.cast<String, Object?>();
    switch (msg['t']) {
      case 'discovered':
        final peer = msg['peerId'];
        if (peer is String && peer.isNotEmpty) {
          _emit(PeerDiscovered(peerId: peer, rssi: _intOf(msg['rssi'])));
        }
      case 'linkOpened':
        final linkId = _intOf(msg['linkId']);
        final peer = msg['peerId'] is String ? msg['peerId']! as String : '';
        _links[linkId] = peer;
        _emit(LinkOpened(
          linkId: linkId,
          peerId: peer,
          maxChunk: _intOf(msg['maxChunk'], fallback: 244),
          initiator: msg['initiator'] == true,
        ));
      case 'data':
        final linkId = _intOf(msg['linkId']);
        final data = msg['data'];
        if (!_links.containsKey(linkId) || data is! String) {
          return;
        }
        final Uint8List bytes;
        try {
          bytes = base64Decode(data);
        } on FormatException {
          _log('リンク $linkId: base64 が不正です');
          return;
        }
        _emit(LinkData(linkId: linkId, data: bytes));
      case 'linkClosed':
        final linkId = _intOf(msg['linkId']);
        final peer = _links.remove(linkId) ??
            (msg['peerId'] is String ? msg['peerId']! as String : null);
        _emit(LinkClosed(
          linkId: linkId,
          peerId: peer,
          reason: msg['reason'] is String ? msg['reason']! as String : '',
        ));
      case 'log':
        _log('ハブ: ${msg['message']}');
      default:
        _log('ハブからの不明なメッセージ: ${msg['t']}');
    }
  }

  // ---------------------------------------------------------------- 補助

  void _closeAllLinks(String reason) {
    if (_links.isEmpty) {
      return;
    }
    final closing = Map<int, String>.of(_links);
    _links.clear();
    for (final entry in closing.entries) {
      _emit(LinkClosed(linkId: entry.key, peerId: entry.value, reason: reason));
    }
  }

  void _emitState() {
    final online = _running && _socket != null;
    _emit(TransportState(
      // 停止中は「電波はあるが止めている」、稼働中に未接続なら「電波なし」。
      poweredOn: !_running || online,
      scanning: online,
      advertising: online,
      permission: 'granted',
    ));
  }

  void _log(String message) => _emit(TransportLog(message));

  void _emit(TransportEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  static int _intOf(Object? value, {int fallback = 0}) =>
      value is num ? value.toInt() : fallback;

  static String _hex(Uint8List bytes) {
    final buffer = StringBuffer();
    for (final b in bytes) {
      buffer.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static String _randomPeerId() {
    final random = Random();
    final value = random.nextInt(0x1000000);
    return 'hub-${value.toRadixString(16).padLeft(6, '0')}';
  }
}
