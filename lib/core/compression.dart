/// 封筒 body の圧縮・伸長。
///
/// ワイヤ形式は **raw deflate（zlib ヘッダなし、windowBits=-15）+ 事前共有辞書
/// [kDictionaryV1]**（docs/02_protocol.md §2）。
///
/// 実装上の注意: Dart SDK（3.12 時点）の `dart:io` zlib は `raw: true` のとき
/// `dictionary` を**無視する**（圧縮・伸長とも。zlib ラッパ付きのときだけ
/// FDICT として辞書が効く）。そこでここでは
/// - 圧縮: zlib ラッパ付き + 辞書で deflate し、2 バイトのヘッダ・4 バイトの
///   DICTID・末尾 4 バイトの Adler-32 を取り除く（deflate ブロック列は
///   windowBits=-15 で圧縮した場合と同一）。
/// - 伸長: 受け取った raw deflate 列の前に合成した zlib ヘッダ + DICTID を付けて
///   辞書付きで inflate する。Adler-32 トレーラは付けない（inflate は
///   ブロック列を読み終えた時点で出力を完了する）。
/// という手順で、他実装（zlib の `-15` + `setDictionary`）と相互運用できる
/// バイト列を生成・受理する。
library;

import 'dart:io';
import 'dart:typed_data';

import 'dictionary.dart';
import 'envelope.dart' show EnvelopeFormatException;

/// 伸長後の body の上限（バイト）。超過する入力は破棄する。
const int kMaxBodyPlainBytes = 4096;

/// deflate の圧縮レベル（最大）。
const int kDeflateLevel = 9;

/// deflate のウィンドウサイズ（2^15 = 32 KB）。
const int kDeflateWindowBits = 15;

// zlib ヘッダ: CMF=0x78（deflate, 32 KB window）、FLG=0xF9（FDICT=1、
// FLEVEL=3、FCHECK は (CMF*256+FLG) % 31 == 0 を満たす値）。
const int _zlibCmf = 0x78;
const int _zlibFlg = 0xF9;
const int _zlibFlagDict = 0x20;
const int _zlibHeaderLength = 2;
const int _zlibDictIdLength = 4;
const int _zlibTrailerLength = 4;

/// [kDictionaryV1] の Adler-32（zlib ヘッダの DICTID として使う）。
final int _dictionaryAdler32 = _adler32(kDictionaryV1);

int _adler32(List<int> data) {
  const mod = 65521;
  var a = 1;
  var b = 0;
  for (final byte in data) {
    a = (a + byte) % mod;
    b = (b + a) % mod;
  }
  return (b << 16) | a;
}

/// [plain] を raw deflate + 辞書で圧縮する。
///
/// 圧縮結果が元より大きくなることもある。縮まないときに圧縮しない判断は
/// 呼び出し側（`Envelope.encode`）が行う。
Uint8List compressBody(Uint8List plain) {
  final filter = RawZLibFilter.deflateFilter(
    level: kDeflateLevel,
    windowBits: kDeflateWindowBits,
    dictionary: kDictionaryV1,
  );
  final zlibStream = _drain(filter, plain, limit: null);
  // 出力は CMF ‖ FLG ‖ [DICTID] ‖ deflate ブロック列 ‖ Adler-32。
  final hasDictId = (zlibStream[1] & _zlibFlagDict) != 0;
  final prefix = _zlibHeaderLength + (hasDictId ? _zlibDictIdLength : 0);
  return zlibStream.sublist(prefix, zlibStream.length - _zlibTrailerLength);
}

/// raw deflate + 辞書で圧縮された [data] を伸長する。
///
/// 出力が [kMaxBodyPlainBytes] を超えた時点で打ち切り、破損・上限超過は
/// [EnvelopeFormatException] を投げる。入力は信用しない。
Uint8List decompressBody(Uint8List data) {
  final wrapped = Uint8List(_zlibHeaderLength + _zlibDictIdLength + data.length);
  wrapped[0] = _zlibCmf;
  wrapped[1] = _zlibFlg;
  ByteData.sublistView(wrapped).setUint32(2, _dictionaryAdler32, Endian.big);
  wrapped.setRange(_zlibHeaderLength + _zlibDictIdLength, wrapped.length, data);

  final filter = RawZLibFilter.inflateFilter(
    windowBits: kDeflateWindowBits,
    dictionary: kDictionaryV1,
  );
  try {
    return _drain(filter, wrapped, limit: kMaxBodyPlainBytes);
  } on EnvelopeFormatException {
    rethrow;
  } catch (_) {
    // zlib は破損データを FormatException として報告する。種類を問わず
    // すべて「不正な封筒」として扱う。
    throw const EnvelopeFormatException('body の伸長に失敗しました');
  }
}

/// [filter] に [input] を通し、出力をすべて集める。
///
/// [limit] が指定されたとき、出力がそれを超えた時点で
/// [EnvelopeFormatException] を投げて打ち切る。
Uint8List _drain(RawZLibFilter filter, Uint8List input, {required int? limit}) {
  final out = BytesBuilder(copy: false);
  void take(List<int> chunk) {
    out.add(chunk);
    if (limit != null && out.length > limit) {
      throw EnvelopeFormatException('伸長後の body が $limit バイトを超えました');
    }
  }

  filter.process(input, 0, input.length);
  List<int>? chunk;
  while ((chunk = filter.processed(flush: false)) != null) {
    take(chunk!);
  }
  while ((chunk = filter.processed(flush: true, end: true)) != null) {
    take(chunk!);
  }
  return out.takeBytes();
}
