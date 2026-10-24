/// 目録の要約（Bloom フィルタ、docs/02 §3 INVENTORY_FILTER、v2.3）。
///
/// すれ違いの時間は短い。3,000 件の目録を msg_id（8 バイト）の列で送ると 24 KB に
/// なり、それだけで数秒かかる。持っている msg_id を 1 件あたり約 10 ビットの
/// Bloom フィルタに要約して送れば約 3.6 KB で済み、すぐに本題（メッセージ）へ移れる。
///
/// - 偽陽性（持っていないのに「持っている」と判定）は約 1%。その分はそのセッション
///   では送られないが、セッションごとに [salt] を変えるので次のすれ違いで送られる。
/// - 偽陰性はない（持っているものを「持っていない」とは判定しない）。
///
/// ワイヤ形式（payload）: `salt u32 LE ‖ hash_count u8 ‖ item_count u32 LE ‖ bits`。
library;

import 'dart:math' show Random;
import 'dart:typed_data';

/// 1 件あたりのビット数（偽陽性 約 1%）。
const double kFilterBitsPerItem = 9.6;

/// ハッシュ関数の数（偽陽性 1% の最適値）。
const int kFilterHashCount = 7;

/// payload の先頭（salt・hash_count・item_count）の長さ。
const int kFilterHeaderLength = 9;

/// ビット列の上限（フレーム 1 つに収める）。
const int kFilterMaxBytes = 8191 - kFilterHeaderLength;

/// 目録の要約。
class InventoryFilter {
  InventoryFilter._(this.salt, this.hashCount, this.itemCount, this.bits);

  /// [ids] を要約する。[salt] はセッションごとに変える（32 ビット）。
  factory InventoryFilter.build(Iterable<int> ids, {required int salt}) {
    final list = ids.toList(growable: false);
    var bytes = ((list.length * kFilterBitsPerItem) / 8).ceil();
    if (bytes < 8) {
      bytes = 8;
    }
    if (bytes > kFilterMaxBytes) {
      bytes = kFilterMaxBytes;
    }
    final filter = InventoryFilter._(
        salt & 0xFFFFFFFF, kFilterHashCount, list.length, Uint8List(bytes));
    for (final id in list) {
      filter._add(id);
    }
    return filter;
  }

  /// セッション用の新しい salt。
  static int randomSalt([Random? random]) =>
      (random ?? Random()).nextInt(1 << 32);

  /// 要約に使った salt。
  final int salt;

  /// ハッシュ関数の数。
  final int hashCount;

  /// 要約した件数（参考値）。
  final int itemCount;

  /// ビット列。
  final Uint8List bits;

  int get _bitCount => bits.length * 8;

  void _add(int id) {
    final m = _bitCount;
    final h1 = _mix(id ^ salt);
    final h2 = _mix(h1 ^ 0x5851F42D4C957F2D) | 1;
    for (var i = 0; i < hashCount; i++) {
      final bit = ((h1 + i * h2) >>> 1) % m;
      bits[bit >> 3] |= 1 << (bit & 7);
    }
  }

  /// [id] を持っているかもしれないか（false なら確実に持っていない）。
  bool mightContain(int id) {
    final m = _bitCount;
    final h1 = _mix(id ^ salt);
    final h2 = _mix(h1 ^ 0x5851F42D4C957F2D) | 1;
    for (var i = 0; i < hashCount; i++) {
      final bit = ((h1 + i * h2) >>> 1) % m;
      if (bits[bit >> 3] & (1 << (bit & 7)) == 0) {
        return false;
      }
    }
    return true;
  }

  /// payload に直列化する。
  Uint8List encode() {
    final out = Uint8List(kFilterHeaderLength + bits.length);
    final view = ByteData.sublistView(out);
    view.setUint32(0, salt, Endian.little);
    out[4] = hashCount;
    view.setUint32(5, itemCount, Endian.little);
    out.setRange(kFilterHeaderLength, out.length, bits);
    return out;
  }

  /// payload から復元する。不正なら [FormatException]。
  static InventoryFilter decode(Uint8List payload) {
    if (payload.length < kFilterHeaderLength + 1) {
      throw const FormatException('INVENTORY_FILTER が短すぎます');
    }
    final view = ByteData.sublistView(payload);
    final salt = view.getUint32(0, Endian.little);
    final k = payload[4];
    if (k < 1 || k > 16) {
      throw FormatException('INVENTORY_FILTER のハッシュ数が不正です（$k）');
    }
    final count = view.getUint32(5, Endian.little);
    return InventoryFilter._(salt, k, count,
        Uint8List.fromList(payload.sublist(kFilterHeaderLength)));
  }

  /// splitmix64 の仕上げ（msg_id は SHA-256 由来でほぼ一様だが、salt と混ぜて
  /// セッションごとに別のビットへ散らす）。
  static int _mix(int z) {
    var x = z;
    x = (x ^ (x >>> 30)) * -4658895280553007687; // 0xBF58476D1CE4E5B9
    x = (x ^ (x >>> 27)) * -7723592293110705685; // 0x94D049BB133111EB
    return x ^ (x >>> 31);
  }
}
