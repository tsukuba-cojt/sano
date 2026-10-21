/// ノード ID・グループコード・本部コード／スタッフコードの生成と、
/// 8 バイト整数 / 16 進文字列の相互変換。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

/// ノード ID の長さ（バイト）。
const int kNodeIdLength = 8;

/// 本部コードの先頭桁（C09）。
const String kHqCodePrefix = '1';

/// スタッフコードの先頭桁（C09）。
const String kStaffCodePrefix = '2';

/// 8 バイトのノード ID を生成する。[random] 省略時は暗号学的乱数を使う。
Uint8List generateNodeId([Random? random]) {
  final rng = random ?? Random.secure();
  final id = Uint8List(kNodeIdLength);
  for (var i = 0; i < id.length; i++) {
    id[i] = rng.nextInt(256);
  }
  return id;
}

const String _hexDigits = '0123456789abcdef';

/// バイト列を小文字 16 進文字列にする。
String hexOf(Uint8List bytes) {
  final buffer = StringBuffer();
  for (final b in bytes) {
    buffer
      ..write(_hexDigits[b >> 4])
      ..write(_hexDigits[b & 0x0F]);
  }
  return buffer.toString();
}

/// 16 進文字列（大文字小文字どちらでも可）をバイト列に戻す。
///
/// 長さが奇数、または 16 進以外の文字を含む場合は [FormatException]。
Uint8List bytesFromHex(String hex) {
  if (hex.length.isOdd) {
    throw FormatException('16 進文字列の長さが奇数です', hex);
  }
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final hi = _hexValue(hex.codeUnitAt(i * 2));
    final lo = _hexValue(hex.codeUnitAt(i * 2 + 1));
    if (hi < 0 || lo < 0) {
      throw FormatException('16 進以外の文字を含みます', hex, i * 2);
    }
    out[i] = (hi << 4) | lo;
  }
  return out;
}

int _hexValue(int codeUnit) {
  if (codeUnit >= 0x30 && codeUnit <= 0x39) {
    return codeUnit - 0x30;
  }
  if (codeUnit >= 0x61 && codeUnit <= 0x66) {
    return codeUnit - 0x61 + 10;
  }
  if (codeUnit >= 0x41 && codeUnit <= 0x46) {
    return codeUnit - 0x41 + 10;
  }
  return -1;
}

/// [bytes] の [offset] から 8 バイトをリトルエンディアンで読み、
/// 64 ビット符号付き int として返す（ビット列は uint64 と同一）。
int u64FromBytes(Uint8List bytes, [int offset = 0]) {
  if (offset < 0 || bytes.length - offset < 8) {
    throw ArgumentError.value(offset, 'offset', '8 バイト読めません');
  }
  return ByteData.sublistView(bytes).getInt64(offset, Endian.little);
}

/// 64 ビット int を 8 バイトのリトルエンディアンにする。
Uint8List u64ToBytes(int value) {
  final out = Uint8List(8);
  ByteData.sublistView(out).setInt64(0, value, Endian.little);
  return out;
}

/// 6 桁のグループ参加コード（100000..999999）を生成する。
int generateGroupCode([Random? random]) {
  final rng = random ?? Random.secure();
  return 100000 + rng.nextInt(900000);
}

String _sevenDigits(Random rng) => rng.nextInt(10000000).toString().padLeft(7, '0');

/// 8 桁の本部コード（先頭 1 + 7 桁）を生成する（C09）。
String generateHqCode([Random? random]) =>
    kHqCodePrefix + _sevenDigits(random ?? Random.secure());

/// 8 桁のスタッフコード（先頭 2 + 7 桁）を生成する（C09）。
String generateStaffCode([Random? random]) =>
    kStaffCodePrefix + _sevenDigits(random ?? Random.secure());

/// 旧名。本部コードと同じ。
String generateOfficialCode([Random? random]) => generateHqCode(random);

/// 入力された 8 桁コードを正規化する（空白・ハイフンを除く）。
/// 8 桁の数字でなければ null。
String? normalizeEightDigitCode(String input) {
  final normalized = input.replaceAll(RegExp(r'[\s\-]'), '');
  return RegExp(r'^\d{8}$').hasMatch(normalized) ? normalized : null;
}

/// 8 桁コードの先頭桁から種類を判定する。本部なら true、スタッフなら false、
/// どちらでもなければ null。
bool? isHqCode(String code) {
  if (code.startsWith(kHqCodePrefix)) {
    return true;
  }
  if (code.startsWith(kStaffCodePrefix)) {
    return false;
  }
  return null;
}

/// SHA-256(コードの ASCII) の先頭 4 バイト。
Uint8List codeDigestPart(String code) =>
    Uint8List.fromList(sha256.convert(ascii.encode(code)).bytes.sublist(0, 4));

/// group_info に載せる code_digest（本部 4 B ‖ スタッフ 4 B）（C24）。
Uint8List computeCodeDigest({required String hqCode, required String staffCode}) {
  final out = Uint8List(8);
  out.setRange(0, 4, codeDigestPart(hqCode));
  out.setRange(4, 8, codeDigestPart(staffCode));
  return out;
}

/// [digest]（8 バイト）の本部側／スタッフ側が [code] と一致するか。
bool codeMatchesDigest(String code, Uint8List digest, {required bool hq}) {
  if (digest.length != 8) {
    return false;
  }
  final part = codeDigestPart(code);
  final offset = hq ? 0 : 4;
  for (var i = 0; i < 4; i++) {
    if (digest[offset + i] != part[i]) {
      return false;
    }
  }
  return true;
}
