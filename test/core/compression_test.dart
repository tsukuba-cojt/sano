import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/core/compression.dart';
import 'package:kairanban/core/envelope.dart';

/// 300 文字程度の典型的なお知らせ本文。
const String kSampleNotice300 =
    '〇〇小学校 避難所からの お知らせです。本日 午後3時から 体育館で 水と 毛布を 配布します。'
    '一人 一個です。容器を 持ってきてください。数に 限りが あります。なくなり次第 終わります。'
    '高齢者の方と 小さな お子さんが いる方を 優先します。明日の 午前9時から 校庭で 給水車が 来ます。'
    'ポリタンクを 持ってきてください。体調が 悪い方は 1階の 救護所へ 来てください。'
    '余震に 注意してください。詐欺の 電話に 注意してください。分からないことは 受付で 聞いてください。'
    '今日の 炊き出しは 午後5時から 校庭で 行います。おにぎりと みそ汁を 配ります。'
    'トイレは 校舎 1階の ものが 使えます。ご協力 お願いします。〇〇市 防災課 災害対策本部。';

/// 辞書に沿わない自由文（それでも極端に悪化しないことを確認する）。
const String kFreeText =
    '橋のたもとの倉庫に、昨夜届いた段ボールが山積みになっています。中身は確認中ですが、'
    '衣類と紙おむつが多いようです。仕分けを手伝ってくださる方は、朝の体操のあとに集まってください。';

Uint8List _bytes(List<int> list) => Uint8List.fromList(list);

/// raw deflate の stored ブロック（圧縮なし）を手で組み立てる。
/// BFINAL=1, BTYPE=00 → 先頭バイト 0x01、続いて LEN / NLEN（LE）、データ。
Uint8List _storedBlock(List<int> data, {int? lenOverride, int? nlenOverride}) {
  final len = lenOverride ?? data.length;
  final nlen = nlenOverride ?? (~len & 0xFFFF);
  return _bytes([
    0x01,
    len & 0xFF,
    (len >> 8) & 0xFF,
    nlen & 0xFF,
    (nlen >> 8) & 0xFF,
    ...data,
  ]);
}

void main() {
  group('compressBody / decompressBody', () {
    test('空の入力を往復できる', () {
      final c = compressBody(Uint8List(0));
      expect(decompressBody(c), Uint8List(0));
    });

    test('日本語の短文を往復できる', () {
      final plain = _bytes(utf8.encode('〇〇小学校に 水と 毛布が とどきました'));
      final c = compressBody(plain);
      expect(decompressBody(c), plain);
      expect(c.length, lessThan(plain.length));
    });

    test('300 文字の日本語お知らせは UTF-8 の 60% 未満に縮む', () {
      expect(kSampleNotice300.length, greaterThanOrEqualTo(300));
      final plain = _bytes(utf8.encode(kSampleNotice300));
      final c = compressBody(plain);
      final ratio = c.length / plain.length;
      // ignore: avoid_print
      print('300 文字お知らせ: ${plain.length} → ${c.length} バイト '
          '(${(ratio * 100).toStringAsFixed(1)}%)');
      expect(ratio, lessThan(0.6));
      expect(decompressBody(c), plain);

      // NoticeBody として直列化した全体でも同様に縮む。
      final body = NoticeBody(
        senderName: '〇〇市 防災課',
        title: '〇〇小学校に 水と 毛布が とどきました',
        place: '〇〇小学校 体育館',
        text: kSampleNotice300,
      ).encode();
      final cb = compressBody(body);
      expect(cb.length / body.length, lessThan(0.6));
      expect(decompressBody(cb), body);
    });

    test('辞書に沿わない自由文でも往復でき、元より大きくならない', () {
      final plain = _bytes(utf8.encode(kFreeText));
      final c = compressBody(plain);
      expect(decompressBody(c), plain);
      expect(c.length, lessThanOrEqualTo(plain.length));
    });

    test('辞書なしの deflate より小さくなる（辞書が実際に効いている）', () {
      final plain = _bytes(utf8.encode(kSampleNotice300));
      final withDict = compressBody(plain);
      final withoutDict = ZLibEncoder(raw: true, level: 9).convert(plain);
      expect(withDict.length, lessThan(withoutDict.length));
    });

    test('上限ちょうど 4096 バイトを往復できる', () {
      final rng = Random(1);
      final plain = _bytes(List.generate(4096, (_) => rng.nextInt(256)));
      expect(decompressBody(compressBody(plain)), plain);
      final zeros = Uint8List(4096);
      expect(decompressBody(compressBody(zeros)), zeros);
    });

    test('いろいろな長さのランダムなバイト列を往復できる', () {
      final rng = Random(2);
      for (final n in [1, 2, 3, 7, 64, 255, 256, 1000, 2047, 4095]) {
        final plain = _bytes(List.generate(n, (_) => rng.nextInt(256)));
        expect(decompressBody(compressBody(plain)), plain, reason: 'n=$n');
      }
    });

    test('伸長後が 4097 バイトになる入力は拒否する', () {
      final c = compressBody(Uint8List(4097));
      expect(() => decompressBody(c), throwsA(isA<EnvelopeFormatException>()));
    });

    test('伸長爆弾（4 MB）は EnvelopeFormatException で拒否する', () {
      final bomb = compressBody(Uint8List(4 * 1024 * 1024));
      expect(bomb.length, lessThan(8192));
      expect(
        () => decompressBody(bomb),
        throwsA(isA<EnvelopeFormatException>()),
      );
    });

    test('stored ブロック（zlib ヘッダなしの raw deflate）を伸長できる', () {
      final data = utf8.encode('raw deflate 確認');
      expect(decompressBody(_storedBlock(data)), _bytes(data));
      expect(decompressBody(_storedBlock(const [])), Uint8List(0));
      final full = List<int>.filled(4096, 0x41);
      expect(decompressBody(_storedBlock(full)), _bytes(full));
    });

    test('stored ブロックで 4097 バイトは拒否する', () {
      final over = List<int>.filled(4097, 0x41);
      expect(
        () => decompressBody(_storedBlock(over)),
        throwsA(isA<EnvelopeFormatException>()),
      );
    });

    test('NLEN が壊れた stored ブロックは拒否する', () {
      final data = utf8.encode('abc');
      expect(
        () => decompressBody(_storedBlock(data, nlenOverride: 0x1234)),
        throwsA(isA<EnvelopeFormatException>()),
      );
    });

    test('参照実装（Python zlib: wbits=-15 + zdict=kDictionaryV1）の出力を伸長できる', () {
      // 生成方法:
      //   co = zlib.compressobj(9, zlib.DEFLATED, -15, 8,
      //                         zlib.Z_DEFAULT_STRATEGY, zdict=kDictionaryV1)
      //   raw = co.compress(plain) + co.flush()
      // 辞書を変えるとこのフィクスチャも変わる（辞書は変更禁止）。
      const plainText = '〇〇小学校に 水と 毛布が とどきました。午後3時から 体育館で 配布します。一人 一個です。';
      final fixture = _bytes([
        0x43, 0x4b, 0xb3, 0xe0, 0xea, 0x9e, 0x70, 0x1b, 0x1c, 0xe8, 0x50, 0x88,
        0xa7, 0x8d, 0x11, 0xbd, 0x6c, 0x78, 0xca, 0x00, 0xf9, 0x16, 0xd6, 0xca,
        0x85, 0x66, 0x69, 0xa0, 0x7a, 0x48, 0x6b, 0x57, 0x01, 0xb9, 0xb9, 0x0b,
        0x14, 0x05, 0x00,
      ]);
      final plain = _bytes(utf8.encode(plainText));
      expect(plain.length, 127);
      expect(decompressBody(fixture), plain);
      // こちらの圧縮結果も同程度に小さい（辞書が同じ効き方をしている）。
      expect(compressBody(plain).length, lessThanOrEqualTo(fixture.length + 8));
    });

    test('壊れた入力は EnvelopeFormatException 以外を投げない', () {
      final rng = Random(42);
      final plain = _bytes(utf8.encode(kSampleNotice300));
      final valid = compressBody(plain);

      void check(Uint8List input, String reason) {
        try {
          final out = decompressBody(input);
          expect(out.length, lessThanOrEqualTo(kMaxBodyPlainBytes),
              reason: reason);
        } on EnvelopeFormatException {
          // 期待どおり
        } catch (e) {
          fail('$reason: 想定外の例外 ${e.runtimeType}: $e');
        }
      }

      // ランダムなごみ
      for (var i = 0; i < 300; i++) {
        final n = rng.nextInt(200);
        check(_bytes(List.generate(n, (_) => rng.nextInt(256))), 'garbage#$i');
      }
      // 途中で切れたもの
      for (var n = 0; n < valid.length; n++) {
        check(valid.sublist(0, n), 'truncated@$n');
      }
      // ビット反転
      for (var i = 0; i < 500; i++) {
        final m = Uint8List.fromList(valid);
        final flips = 1 + rng.nextInt(3);
        for (var f = 0; f < flips; f++) {
          final pos = rng.nextInt(m.length);
          m[pos] ^= 1 << rng.nextInt(8);
        }
        check(m, 'flip#$i');
      }
      // 末尾にごみ
      check(_bytes([...valid, 0, 1, 2, 3, 0xff]), 'trailing');
    });
  });
}
