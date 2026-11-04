import 'dart:async';
import 'dart:typed_data';

/// 1 回に書ける・通知できるバイト数の上限。ATT は MTU − 3（最大 514）まで許すが、
/// Android の GATT は属性値を 512 バイトまでしか扱わない（#152 の実測）。
const int kMaxChunkBytes = 512;

/// すれ違い通信のリンク層インターフェース。
///
/// 実装: [BleTransport]（ネイティブ BLE）、[HubTransport]（開発用 TCP ハブ）、
/// [FakeTransport]（テスト用インメモリ）。詳細は docs/03_architecture.md §3。
abstract class Transport {
  /// リンク層イベントのストリーム。購読は 1 つだけを想定（broadcast 可）。
  Stream<TransportEvent> get events;

  /// 広告・スキャン・GATT サーバ等を開始する。
  Future<void> start(TransportConfig config);

  /// すべて停止する。
  Future<void> stop();

  /// 省電力モードを切り替える。
  Future<void> setLowPower(bool lowPower);

  /// [peerId] へ接続を試みる。結果は [LinkOpened] / [LinkClosed] で通知される。
  Future<void> connect(String peerId);

  /// 1 チャンクを送る。`data.length <= maxChunk` であること。
  /// 送信がスタックに受け付けられるまで完了しない（直列に await してフロー制御する）。
  Future<void> send(int linkId, Uint8List data);

  /// リンクを閉じる。
  Future<void> close(int linkId);
}

class TransportConfig {
  const TransportConfig({
    required this.nodeId,
    this.lowPower = false,
  });

  /// 8 バイトのノード ID。
  final Uint8List nodeId;
  final bool lowPower;
}

/// リンク層イベントの基底。
sealed class TransportEvent {
  const TransportEvent();
}

/// トランスポートの状態変化。
class TransportState extends TransportEvent {
  const TransportState({
    required this.poweredOn,
    required this.scanning,
    required this.advertising,
    this.permission = 'unknown',
  });
  final bool poweredOn;
  final bool scanning;
  final bool advertising;

  /// granted / denied / unknown
  final String permission;
}

/// 近くに候補端末を発見した。
class PeerDiscovered extends TransportEvent {
  const PeerDiscovered({required this.peerId, this.rssi = 0, this.viaApple = false});
  final String peerId;
  final int rssi;

  /// Apple の overflow 広告（製造者データ）経由の推定候補。接続して確認が必要。
  final bool viaApple;
}

/// リンクが確立した。
class LinkOpened extends TransportEvent {
  const LinkOpened({
    required this.linkId,
    required this.peerId,
    required this.maxChunk,
    required this.initiator,
  });
  final int linkId;
  final String peerId;

  /// 1 回の送信で送れる最大バイト数（ATT MTU − 3）。
  final int maxChunk;

  /// 自分が接続を開始した側（central）なら true。
  final bool initiator;
}

/// チャンクを受信した。
class LinkData extends TransportEvent {
  const LinkData({required this.linkId, required this.data});
  final int linkId;
  final Uint8List data;
}

/// リンクが閉じた（接続失敗を含む）。
class LinkClosed extends TransportEvent {
  const LinkClosed({required this.linkId, this.peerId, this.reason = ''});
  final int linkId;

  /// 接続失敗時など、linkId が割り当てられる前に閉じた場合は peerId で通知する。
  final String? peerId;
  final String reason;
}

/// 診断ログ。
class TransportLog extends TransportEvent {
  const TransportLog(this.message);
  final String message;
}
