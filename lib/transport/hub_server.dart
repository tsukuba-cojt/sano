/// 開発用 TCP ハブ（模擬電波）。
///
/// iOS シミュレータ / Android エミュレータ / デスクトップなど BLE が使えない
/// 環境で、複数のアプリインスタンスにメッセージを交換させるための「電波」。
/// `tool/hub.dart`（CLI）と `test/transport/hub_test.dart`（インプロセス）が
/// 共有する。Flutter には依存しない（dart:io のみ）。
///
/// ## 配線プロトコル（改行区切り JSON、1 行 1 メッセージ）
///
/// クライアント → ハブ
/// - `{"t":"register","peerId":"…","nodeId":"…"}` 参加（広告開始に相当）
/// - `{"t":"connect","peerId":"…"}` 相手へ接続
/// - `{"t":"data","linkId":N,"data":"<base64>"}` 1 チャンク送信
/// - `{"t":"close","linkId":N}` リンク切断
///
/// ハブ → クライアント
/// - `{"t":"discovered","peerId":"…","rssi":-60}` 他の登録済みクライアント
///   （登録直後と、以後 [HubServer.discoveryInterval] ごと）
/// - `{"t":"linkOpened","linkId":N,"peerId":"…","maxChunk":244,"initiator":bool}`
/// - `{"t":"data","linkId":N,"data":"<base64>"}`
/// - `{"t":"linkClosed","linkId":N,"peerId":"…","reason":"…"}`
///   （接続失敗時は linkId=0、peerId に相手）
/// - `{"t":"log","message":"…"}` 診断
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// ハブが両端に通知する 1 チャンクの最大バイト数（ATT MTU 247 − 3）。
const int kHubMaxChunk = 244;

/// 既定の発見通知間隔（広告の模擬）。
const Duration kHubDiscoveryInterval = Duration(seconds: 3);

/// ハブを起動する。[port] が 0 なら空きポートを使う（[HubServer.port] で取得）。
Future<HubServer> startHub({
  int port = 0,
  InternetAddress? address,
  Duration discoveryInterval = kHubDiscoveryInterval,
  void Function(String message)? log,
}) async {
  final server = await ServerSocket.bind(
    address ?? InternetAddress.anyIPv4,
    port,
  );
  return HubServer._(server, discoveryInterval, log);
}

/// 起動中のハブ。
class HubServer {
  HubServer._(this._server, this.discoveryInterval, this._log) {
    _server.listen(_onConnection, onError: (Object e) {
      _log?.call('受け入れエラー: $e');
    });
    _discoveryTimer = Timer.periodic(discoveryInterval, (_) {
      _broadcastDiscovery();
    });
  }

  final ServerSocket _server;
  final void Function(String message)? _log;
  final Duration discoveryInterval;
  final Random _random = Random();
  final Set<_HubClient> _clients = <_HubClient>{};
  final Map<int, _HubLink> _links = <int, _HubLink>{};
  int _nextLinkId = 1;
  Timer? _discoveryTimer;
  bool _closed = false;

  /// 待ち受けアドレス。
  InternetAddress get address => _server.address;

  /// 待ち受けポート。
  int get port => _server.port;

  /// 接続中のクライアント数（未登録を含む）。
  int get clientCount => _clients.length;

  /// 登録済み peerId の一覧。
  List<String> get peerIds => [
        for (final c in _clients)
          if (c.peerId != null) c.peerId!,
      ];

  /// 開いているリンク数。
  int get linkCount => _links.length;

  /// 全クライアントを切断して待ち受けを終了する。
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _discoveryTimer?.cancel();
    _discoveryTimer = null;
    for (final client in _clients.toList()) {
      client.socket.destroy();
    }
    _clients.clear();
    _links.clear();
    await _server.close();
    _log?.call('ハブを終了しました');
  }

  // ---------------------------------------------------------------- 接続処理

  void _onConnection(Socket socket) {
    // 切断直後の書き込みエラー（Broken pipe）が未処理例外にならないようにする。
    unawaited(socket.done.catchError((Object _) {}));
    socket.setOption(SocketOption.tcpNoDelay, true);
    final client = _HubClient(socket);
    _clients.add(client);
    _log?.call('接続: ${client.remote}');
    socket
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          (line) => _onLine(client, line),
          onError: (Object e) => _onDisconnect(client, '$e'),
          onDone: () => _onDisconnect(client, '切断'),
          cancelOnError: true,
        );
  }

  void _onDisconnect(_HubClient client, String reason) {
    if (!_clients.remove(client)) {
      return;
    }
    client.socket.destroy();
    for (final linkId in client.links.toList()) {
      _closeLink(linkId, by: client, reason: '相手が離脱');
    }
    _log?.call('離脱: ${client.label} ($reason)');
  }

  void _onLine(_HubClient client, String line) {
    if (line.trim().isEmpty) {
      return;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      client.send({'t': 'log', 'message': 'JSON が不正です'});
      return;
    }
    if (decoded is! Map) {
      client.send({'t': 'log', 'message': 'オブジェクトではありません'});
      return;
    }
    final msg = decoded.cast<String, Object?>();
    switch (msg['t']) {
      case 'register':
        _register(client, msg);
      case 'connect':
        _connect(client, msg);
      case 'data':
        _forwardData(client, msg);
      case 'close':
        final linkId = _intOf(msg['linkId']);
        final link = _links[linkId];
        if (link != null && link.has(client)) {
          _closeLink(linkId, by: client, reason: 'close');
        }
      default:
        client.send({'t': 'log', 'message': '不明なメッセージ: ${msg['t']}'});
    }
  }

  void _register(_HubClient client, Map<String, Object?> msg) {
    final peerId = msg['peerId'];
    if (peerId is! String || peerId.isEmpty || peerId.length > 64) {
      client.send({'t': 'log', 'message': 'peerId が不正です'});
      return;
    }
    // 同じ peerId の古い接続（再接続前のもの）は追い出す。
    for (final other in _clients.toList()) {
      if (!identical(other, client) && other.peerId == peerId) {
        _log?.call('重複 peerId $peerId: 古い接続を切断します');
        _onDisconnect(other, '同じ peerId で再登録');
      }
    }
    client
      ..peerId = peerId
      ..nodeId = msg['nodeId'] is String ? msg['nodeId']! as String : '';
    _log?.call('登録: ${client.label} nodeId=${client.nodeId}');
    // 広告開始に相当: 新規参加者と既存参加者は互いにすぐ見える。
    _broadcastDiscovery();
  }

  void _connect(_HubClient client, Map<String, Object?> msg) {
    final target = msg['peerId'];
    if (target is! String) {
      client.send({'t': 'log', 'message': 'connect: peerId が不正です'});
      return;
    }
    if (client.peerId == null) {
      client.send(_connectFailed(target, '未登録です'));
      return;
    }
    _HubClient? other;
    for (final c in _clients) {
      if (!identical(c, client) && c.peerId == target) {
        other = c;
        break;
      }
    }
    if (other == null) {
      client.send(_connectFailed(target, '相手が見つかりません'));
      return;
    }
    final linkId = _nextLinkId++;
    final link = _HubLink(linkId, client, other);
    _links[linkId] = link;
    client.links.add(linkId);
    other.links.add(linkId);
    _log?.call('リンク $linkId: ${client.label} → ${other.label}');
    client.send({
      't': 'linkOpened',
      'linkId': linkId,
      'peerId': other.peerId,
      'maxChunk': kHubMaxChunk,
      'initiator': true,
    });
    other.send({
      't': 'linkOpened',
      'linkId': linkId,
      'peerId': client.peerId,
      'maxChunk': kHubMaxChunk,
      'initiator': false,
    });
  }

  static Map<String, Object?> _connectFailed(String peerId, String reason) => {
        't': 'linkClosed',
        'linkId': 0,
        'peerId': peerId,
        'reason': reason,
      };

  void _forwardData(_HubClient client, Map<String, Object?> msg) {
    final linkId = _intOf(msg['linkId']);
    final link = _links[linkId];
    if (link == null || !link.has(client)) {
      client.send({'t': 'log', 'message': 'data: リンク $linkId は開いていません'});
      return;
    }
    final data = msg['data'];
    if (data is! String) {
      client.send({'t': 'log', 'message': 'data: data が不正です'});
      return;
    }
    final int length;
    try {
      length = base64Decode(data).length;
    } on FormatException {
      client.send({'t': 'log', 'message': 'data: base64 が不正です'});
      return;
    }
    if (length > kHubMaxChunk) {
      // 実機では MTU 超えの書き込みは失敗する。開発中に気付けるようリンクを切る。
      client.send({
        't': 'log',
        'message': 'data: $length バイトは maxChunk($kHubMaxChunk) を超えています',
      });
      _closeLink(linkId, by: client, reason: 'maxChunk 超過');
      return;
    }
    link.other(client).send({'t': 'data', 'linkId': linkId, 'data': data});
  }

  void _closeLink(int linkId, {required _HubClient by, required String reason}) {
    final link = _links.remove(linkId);
    if (link == null) {
      return;
    }
    link.a.links.remove(linkId);
    link.b.links.remove(linkId);
    for (final end in [link.a, link.b]) {
      end.send({
        't': 'linkClosed',
        'linkId': linkId,
        'peerId': link.other(end).peerId,
        'reason': identical(end, by) ? reason : '相手が切断 ($reason)',
      });
    }
    _log?.call('リンク $linkId 終了 ($reason)');
  }

  void _broadcastDiscovery() {
    final registered = [
      for (final c in _clients)
        if (c.peerId != null) c,
    ];
    if (registered.length < 2) {
      return;
    }
    for (final to in registered) {
      for (final from in registered) {
        if (identical(to, from)) {
          continue;
        }
        to.send({
          't': 'discovered',
          'peerId': from.peerId,
          'rssi': -40 - _random.nextInt(50),
        });
      }
    }
  }

  static int _intOf(Object? value) => value is num ? value.toInt() : 0;
}

class _HubClient {
  _HubClient(this.socket);

  final Socket socket;
  String? peerId;
  String nodeId = '';
  final Set<int> links = <int>{};

  String get remote {
    try {
      return '${socket.remoteAddress.address}:${socket.remotePort}';
    } on Object {
      return '?';
    }
  }

  String get label => peerId ?? remote;

  void send(Map<String, Object?> msg) {
    try {
      socket.write('${jsonEncode(msg)}\n');
    } on Object {
      // 切断直後の書き込み失敗は onDone 側で処理する。
    }
  }
}

class _HubLink {
  _HubLink(this.id, this.a, this.b);

  final int id;
  final _HubClient a;
  final _HubClient b;

  bool has(_HubClient c) => identical(c, a) || identical(c, b);

  _HubClient other(_HubClient c) => identical(c, a) ? b : a;
}
