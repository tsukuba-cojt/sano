import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/core/ids.dart';

void main() {
  group('generateNodeId', () {
    test('8 バイトを返す', () {
      expect(generateNodeId().length, 8);
      expect(generateNodeId(Random(1)).length, 8);
    });

    test('同じシードなら同じ値、別の呼び出しは異なる', () {
      expect(generateNodeId(Random(7)), generateNodeId(Random(7)));
      expect(generateNodeId(), isNot(equals(generateNodeId())));
    });
  });

  group('hexOf / bytesFromHex', () {
    test('往復できる', () {
      final bytes = Uint8List.fromList([0x00, 0x01, 0x7f, 0x80, 0xab, 0xff]);
      expect(hexOf(bytes), '00017f80abff');
      expect(bytesFromHex('00017f80abff'), bytes);
      expect(bytesFromHex('00017F80ABFF'), bytes);
      expect(hexOf(Uint8List(0)), '');
      expect(bytesFromHex(''), Uint8List(0));
    });

    test('不正な 16 進は FormatException', () {
      expect(() => bytesFromHex('abc'), throwsFormatException);
      expect(() => bytesFromHex('zz'), throwsFormatException);
      expect(() => bytesFromHex('0g'), throwsFormatException);
      expect(() => bytesFromHex('あい'), throwsFormatException);
    });
  });

  group('u64FromBytes / u64ToBytes', () {
    test('リトルエンディアンで往復できる', () {
      final bytes = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      final v = u64FromBytes(bytes);
      expect(v, 0x0807060504030201);
      expect(u64ToBytes(v), bytes);
    });

    test('最上位ビットが立つ値は負の int として往復する', () {
      final bytes = Uint8List.fromList([0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]);
      final v = u64FromBytes(bytes);
      expect(v, -1);
      expect(u64ToBytes(v), bytes);
      final bytes2 = Uint8List.fromList([0, 0, 0, 0, 0, 0, 0, 0x80]);
      final v2 = u64FromBytes(bytes2);
      expect(v2, isNegative);
      expect(u64ToBytes(v2), bytes2);
    });

    test('offset を指定して読める', () {
      final bytes = Uint8List.fromList([9, 9, 1, 0, 0, 0, 0, 0, 0, 0, 9]);
      expect(u64FromBytes(bytes, 2), 1);
    });

    test('8 バイト読めなければ ArgumentError', () {
      expect(() => u64FromBytes(Uint8List(7)), throwsArgumentError);
      expect(() => u64FromBytes(Uint8List(8), 1), throwsArgumentError);
      expect(() => u64FromBytes(Uint8List(8), -1), throwsArgumentError);
    });

    test('ランダムな値を往復できる', () {
      final rng = Random(3);
      for (var i = 0; i < 500; i++) {
        final b = Uint8List.fromList(List.generate(8, (_) => rng.nextInt(256)));
        expect(u64ToBytes(u64FromBytes(b)), b);
      }
    });
  });

  group('generateGroupCode', () {
    test('100000..999999 の範囲', () {
      final rng = Random(11);
      for (var i = 0; i < 2000; i++) {
        final code = generateGroupCode(rng);
        expect(code, inInclusiveRange(100000, 999999));
      }
      expect(generateGroupCode(), inInclusiveRange(100000, 999999));
    });
  });

  group('generateOfficialCode', () {
    test('8 桁の数字', () {
      final rng = Random(5);
      for (var i = 0; i < 2000; i++) {
        final code = generateOfficialCode(rng);
        expect(code, matches(RegExp(r'^[1-9][0-9]{7}$')));
      }
      expect(generateOfficialCode(), matches(RegExp(r'^[1-9][0-9]{7}$')));
    });
  });
}
