/// リンク上のフレーム（docs/02_protocol.md §3）のエンコードと
/// チャンク境界に依存しないストリームパーサ。
///
/// `frame = u16 length (type + payload の長さ) ‖ u8 type ‖ payload`
library;

import 'dart:collection';
import 'dart:typed_data';

import 'ids.dart' show u64FromBytes, u64ToBytes;

/// length フィールドの上限。これを超えるフレームは不正としてリンクを切る。
const int kMaxFrameLength = 8192;

/// payload の上限（length から type の 1 バイトを引いたもの）。
const int kMaxFramePayloadBytes = kMaxFrameLength - 1;

/// HELLO の基本 payload 長（version(1) ‖ node_id(8) ‖ store_count(2) ‖ caps(1)）。
const int kHelloPayloadLength = 12;

/// HELLO 末尾の参加グループ一覧の最大件数（C17）。
const int kMaxHelloGroups = 8;

/// 1 つの INVENTORY フレームに載せられる msg_id の最大数（1,023）。
const int kMaxInventoryPerFrame = (kMaxFramePayloadBytes - 2) ~/ 8;

/// HELLO に載せるプロトコルバージョン。不一致でも切らず min(version) で続ける（C13）。
const int kProtocolVersionForHello = 1;

/// HELLO caps bit0: 未知の version/kind/flags の封筒を中継できる（C13）。
const int kCapRelayUnknown = 0x01;

/// HELLO caps bit1: 中継役（設定「中継役として 使う」オン、C04 C17）。
const int kCapRelayNode = 0x02;

/// HELLO caps bit2: HELLO 末尾に参加グループ一覧あり（C17）。
const int kCapGroupList = 0x04;

/// HELLO caps bit3: HELLO 直後の先出し（PUSH）を受けられる（C08）。
const int kCapPush = 0x08;

/// HELLO caps bit4: 目録を要約（INVENTORY_FILTER、Bloom フィルタ）で送受できる（v2.3）。
/// 双方が立てているときだけ、msg_id の列の代わりに要約を送る。
const int kCapInventoryFilter = 0x10;

/// MESSAGES_END payload bit0: 送信上限で打ち切った（続きがある）。
const int kMessagesEndMore = 0x01;

/// MESSAGES_END payload bit1: こちらからは接続できない（広告で見つけられていない）
/// ので、近くにいる間は短い間隔で同期しに来てほしい。受け側（peripheral）だけが立てる。
const int kMessagesEndPollMe = 0x02;

/// この実装が常に立てる caps。
const int kDefaultCaps = kCapRelayUnknown | kCapPush | kCapInventoryFilter;

/// フレームの種類。
enum FrameType {
  hello(0x01),
  inventory(0x02),
  inventoryEnd(0x03),

  /// u32 現在エポック秒。HELLO 直後に送る（C12）。
  time(0x04),

  /// u32 目録最古の created_at。INVENTORY_END の直前（C08）。
  inventoryCutoff(0x05),

  /// 目録の要約（Bloom フィルタ）。INVENTORY の代わりに 1 つだけ送る（v2.3）。
  inventoryFilter(0x06),
  message(0x10),
  messagesEnd(0x11),
  bye(0x20);

  const FrameType(this.code);

  /// ワイヤ上の type 値。
  final int code;

  /// type 値から種類を得る。不明なら null。
  static FrameType? fromCode(int code) {
    for (final t in values) {
      if (t.code == code) {
        return t;
      }
    }
    return null;
  }
}

/// フレーム形式が不正なときに投げる例外。
class FrameFormatException implements Exception {
  const FrameFormatException(this.message);

  final String message;

  @override
  String toString() => 'FrameFormatException: $message';
}

/// 1 つのフレーム。
class Frame {
  const Frame(this.rawType, this.payload);

  /// ワイヤ上の type 値（不明な値も保持する）。
  final int rawType;

  final Uint8List payload;

  /// 既知の種類。不明なら null（受信側は読み飛ばす）。
  FrameType? get type => FrameType.fromCode(rawType);

  /// `u16 len + type + payload` に直列化する。
  Uint8List encode() {
    final length = 1 + payload.length;
    if (length > kMaxFrameLength) {
      throw ArgumentError.value(
          payload.length, 'payload', '$kMaxFramePayloadBytes バイトを超えています');
    }
    if (rawType < 0 || rawType > 0xFF) {
      throw ArgumentError.value(rawType, 'rawType', '0..255');
    }
    final out = Uint8List(2 + length);
    out[0] = length & 0xFF;
    out[1] = (length >> 8) & 0xFF;
    out[2] = rawType;
    out.setRange(3, out.length, payload);
    return out;
  }

  /// HELLO: version(1) ‖ node_id(8) ‖ store_count(u16) ‖ caps(1)
  /// ‖ [group_count(u8) ‖ group_id(uint24) × count]（caps bit2 のときだけ）。
  static Frame hello({
    required Uint8List nodeId,
    required int storeCount,
    int caps = 0,
    List<int> groupIds = const [],
  }) {
    if (nodeId.length != 8) {
      throw ArgumentError.value(nodeId.length, 'nodeId', '8 バイトが必要です');
    }
    final groups = groupIds.length > kMaxHelloGroups
        ? groupIds.sublist(0, kMaxHelloGroups)
        : groupIds;
    final count = storeCount.clamp(0, 0xFFFF);
    final withGroups = groups.isNotEmpty;
    final payload = Uint8List(
        kHelloPayloadLength + (withGroups ? 1 + 3 * groups.length : 0));
    payload[0] = kProtocolVersionForHello;
    payload.setRange(1, 9, nodeId);
    payload[9] = count & 0xFF;
    payload[10] = (count >> 8) & 0xFF;
    payload[11] = (caps | (withGroups ? kCapGroupList : 0)) & 0xFF;
    if (withGroups) {
      payload[12] = groups.length;
      var offset = 13;
      for (final g in groups) {
        payload[offset] = g & 0xFF;
        payload[offset + 1] = (g >> 8) & 0xFF;
        payload[offset + 2] = (g >> 16) & 0xFF;
        offset += 3;
      }
    }
    return Frame(FrameType.hello.code, payload);
  }

  /// INVENTORY: count(u16) ‖ msg_id × count。
  /// [msgIds] は [kMaxInventoryPerFrame] 件以下であること（超える場合は
  /// [inventoryFrames] で分割する）。
  static Frame inventory(List<int> msgIds) {
    if (msgIds.length > kMaxInventoryPerFrame) {
      throw ArgumentError.value(msgIds.length, 'msgIds',
          '1 フレームには $kMaxInventoryPerFrame 件までです');
    }
    final payload = Uint8List(2 + msgIds.length * 8);
    payload[0] = msgIds.length & 0xFF;
    payload[1] = (msgIds.length >> 8) & 0xFF;
    var offset = 2;
    for (final id in msgIds) {
      payload.setRange(offset, offset + 8, u64ToBytes(id));
      offset += 8;
    }
    return Frame(FrameType.inventory.code, payload);
  }

  /// [msgIds] を [kMaxInventoryPerFrame] 件ずつの INVENTORY フレームに分割する。
  /// 空なら空リスト（INVENTORY_END は含まない）。
  static List<Frame> inventoryFrames(List<int> msgIds) {
    final frames = <Frame>[];
    for (var i = 0; i < msgIds.length; i += kMaxInventoryPerFrame) {
      final end = (i + kMaxInventoryPerFrame).clamp(0, msgIds.length);
      frames.add(inventory(msgIds.sublist(i, end)));
    }
    return frames;
  }

  static Frame inventoryEnd() => Frame(FrameType.inventoryEnd.code, Uint8List(0));

  /// INVENTORY_FILTER（payload は [InventoryFilter.encode] の結果、v2.3）。
  static Frame inventoryFilter(Uint8List payload) =>
      Frame(FrameType.inventoryFilter.code, payload);

  /// TIME: u32 現在エポック秒（C12）。
  static Frame time(int epochSeconds) =>
      Frame(FrameType.time.code, _u32(epochSeconds));

  /// INVENTORY_CUTOFF: u32 目録最古の created_at（C08）。
  static Frame inventoryCutoff(int createdAt) =>
      Frame(FrameType.inventoryCutoff.code, _u32(createdAt));

  /// MESSAGE: 封筒 1 件のバイト列をそのまま載せる。
  static Frame message(Uint8List envelopeBytes) =>
      Frame(FrameType.message.code, envelopeBytes);

  /// MESSAGES_END。[more] なら payload に 1 バイト（bit0 = 送信上限で打ち切った、
  /// まだ渡すものがある）を載せる。旧版は payload を読まないので互換がある。
  static Frame messagesEnd({bool more = false, bool pollMe = false}) {
    final flags =
        (more ? kMessagesEndMore : 0) | (pollMe ? kMessagesEndPollMe : 0);
    return Frame(
      FrameType.messagesEnd.code,
      flags == 0 ? Uint8List(0) : Uint8List.fromList([flags]),
    );
  }

  /// MESSAGES_END の payload が「まだ渡すものがある」か。
  static bool messagesEndHasMore(Uint8List payload) =>
      payload.isNotEmpty && (payload[0] & kMessagesEndMore) != 0;

  /// MESSAGES_END の payload が「短い間隔で同期しに来てほしい」か。
  static bool messagesEndPollMe(Uint8List payload) =>
      payload.isNotEmpty && (payload[0] & kMessagesEndPollMe) != 0;

  static Frame bye() => Frame(FrameType.bye.code, Uint8List(0));

  static Uint8List _u32(int value) {
    final out = Uint8List(4);
    ByteData.sublistView(out)
        .setUint32(0, value.clamp(0, 0xFFFFFFFF), Endian.little);
    return out;
  }

  @override
  String toString() =>
      'Frame(type: ${type?.name ?? '0x${rawType.toRadixString(16)}'}, '
      'payload: ${payload.length} バイト)';
}

/// u32 だけの payload（TIME / INVENTORY_CUTOFF）を読む。短ければ [FrameFormatException]。
int parseU32Payload(Uint8List payload, {required String name}) {
  if (payload.length < 4) {
    throw FrameFormatException('$name が短すぎます（${payload.length} バイト）');
  }
  return ByteData.sublistView(payload).getUint32(0, Endian.little);
}

/// HELLO の内容。
class HelloInfo {
  const HelloInfo({
    required this.version,
    required this.nodeId,
    required this.storeCount,
    this.caps = 0,
    this.groupIds = const [],
  });

  final int version;

  /// 相手のノード ID（8 バイト）。
  final Uint8List nodeId;

  /// 相手の保存件数。
  final int storeCount;

  /// 能力ビット（[kCapRelayUnknown] など）。
  final int caps;

  /// 相手の参加グループ（caps bit2 のときだけ。中継役が立てる）。
  final List<int> groupIds;

  bool get relaysUnknown => (caps & kCapRelayUnknown) != 0;
  bool get isRelayNode => (caps & kCapRelayNode) != 0;
  bool get acceptsPush => (caps & kCapPush) != 0;

  /// HELLO の payload を解釈する。短すぎれば [FrameFormatException]。
  /// 将来の拡張のため、読めない余分は無視する。
  static HelloInfo parse(Uint8List payload) {
    if (payload.length < kHelloPayloadLength) {
      throw FrameFormatException(
          'HELLO が短すぎます（${payload.length} バイト）');
    }
    final caps = payload[11];
    final groups = <int>[];
    if ((caps & kCapGroupList) != 0 && payload.length > kHelloPayloadLength) {
      final count = payload[12];
      var offset = 13;
      for (var i = 0; i < count && i < kMaxHelloGroups; i++) {
        if (payload.length - offset < 3) {
          break;
        }
        groups.add(payload[offset] |
            (payload[offset + 1] << 8) |
            (payload[offset + 2] << 16));
        offset += 3;
      }
    }
    return HelloInfo(
      version: payload[0],
      nodeId: Uint8List.fromList(payload.sublist(1, 9)),
      storeCount: payload[9] | (payload[10] << 8),
      caps: caps,
      groupIds: groups,
    );
  }

  @override
  String toString() =>
      'HelloInfo(version: $version, storeCount: $storeCount, caps: $caps, '
      'groups: $groupIds)';
}

/// INVENTORY の payload から msg_id の一覧を取り出す。
/// count に対して payload が短ければ [FrameFormatException]。
List<int> parseInventory(Uint8List payload) {
  if (payload.length < 2) {
    throw const FrameFormatException('INVENTORY に count がありません');
  }
  final count = payload[0] | (payload[1] << 8);
  if (payload.length - 2 < count * 8) {
    throw FrameFormatException(
        'INVENTORY が短すぎます（count=$count、${payload.length} バイト）');
  }
  final ids = List<int>.filled(count, 0);
  for (var i = 0; i < count; i++) {
    ids[i] = u64FromBytes(payload, 2 + i * 8);
  }
  return ids;
}

/// 受信チャンクを連結し、フレーム単位に切り出すストリームパーサ。
///
/// フレームはチャンク境界と無関係に分割・連結されて届く。[addChunk] で
/// バイト列を足し、[nextFrame] で揃ったフレームを順に取り出す。
class FrameParser {
  Uint8List _buffer = Uint8List(1024);
  int _length = 0;
  final Queue<Frame> _ready = Queue<Frame>();

  /// まだフレームとして確定していないバイト数（診断用）。
  int get pendingBytes => _length;

  /// 取り出し待ちのフレーム数。
  int get readyCount => _ready.length;

  /// チャンクを追加する。length が [kMaxFrameLength] を超える、または 0 の
  /// フレームが見えた時点で [FrameFormatException] を投げる
  /// （呼び出し側はリンクを切る）。
  void addChunk(Uint8List chunk) {
    _ensureCapacity(_length + chunk.length);
    _buffer.setRange(_length, _length + chunk.length, chunk);
    _length += chunk.length;
    _extractFrames();
  }

  /// 揃っているフレームを 1 つ返す。なければ null。
  Frame? nextFrame() => _ready.isEmpty ? null : _ready.removeFirst();

  void _ensureCapacity(int needed) {
    if (needed <= _buffer.length) {
      return;
    }
    var size = _buffer.length;
    while (size < needed) {
      size *= 2;
    }
    final grown = Uint8List(size);
    grown.setRange(0, _length, _buffer);
    _buffer = grown;
  }

  void _extractFrames() {
    var start = 0;
    while (_length - start >= 2) {
      final length = _buffer[start] | (_buffer[start + 1] << 8);
      if (length == 0) {
        throw const FrameFormatException('length が 0 のフレームです');
      }
      if (length > kMaxFrameLength) {
        throw FrameFormatException(
            'length が上限を超えています（$length > $kMaxFrameLength）');
      }
      if (_length - start < 2 + length) {
        break;
      }
      final type = _buffer[start + 2];
      final payload =
          Uint8List.fromList(_buffer.sublist(start + 3, start + 2 + length));
      _ready.add(Frame(type, payload));
      start += 2 + length;
    }
    if (start > 0) {
      _buffer.setRange(0, _length - start, _buffer, start);
      _length -= start;
    }
  }
}
