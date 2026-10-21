import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/core/categories.dart';
import 'package:kairanban/core/envelope.dart';
import 'package:kairanban/core/frames.dart';
import 'package:kairanban/core/ids.dart';

Uint8List _bytes(List<int> list) => Uint8List.fromList(list);

final Uint8List _nodeId = _bytes([1, 2, 3, 4, 5, 6, 7, 8]);

/// 連結したバイト列を [parser] にいろいろな切り方で流し込み、
/// 取り出せたフレームを返す。
List<Frame> _feed(FrameParser parser, Uint8List stream, List<int> cuts) {
  var pos = 0;
  final frames = <Frame>[];
  for (final cut in cuts) {
    final end = min(pos + cut, stream.length);
    parser.addChunk(stream.sublist(pos, end));
    pos = end;
    Frame? f;
    while ((f = parser.nextFrame()) != null) {
      frames.add(f!);
    }
    if (pos >= stream.length) {
      break;
    }
  }
  if (pos < stream.length) {
    parser.addChunk(stream.sublist(pos));
    Frame? f;
    while ((f = parser.nextFrame()) != null) {
      frames.add(f!);
    }
  }
  return frames;
}

void _expectFrame(Frame actual, Frame expected) {
  expect(actual.rawType, expected.rawType);
  expect(actual.payload, expected.payload);
}

void main() {
  group('Frame.encode', () {
    test('u16 len + type + payload（リトルエンディアン）', () {
      final f = Frame(0x10, _bytes([0xAA, 0xBB, 0xCC]));
      expect(f.encode(), _bytes([0x04, 0x00, 0x10, 0xAA, 0xBB, 0xCC]));
      expect(Frame.bye().encode(), _bytes([0x01, 0x00, 0x20]));
      expect(Frame.inventoryEnd().encode(), _bytes([0x01, 0x00, 0x03]));
      expect(Frame.messagesEnd().encode(), _bytes([0x01, 0x00, 0x11]));
    });

    test('type の対応', () {
      expect(Frame.hello(nodeId: _nodeId, storeCount: 0).type, FrameType.hello);
      expect(Frame.inventory(const []).type, FrameType.inventory);
      expect(Frame.inventoryEnd().type, FrameType.inventoryEnd);
      expect(Frame.message(Uint8List(0)).type, FrameType.message);
      expect(Frame.messagesEnd().type, FrameType.messagesEnd);
      expect(Frame.bye().type, FrameType.bye);
      expect(Frame(0x7F, Uint8List(0)).type, isNull);
      expect(FrameType.hello.code, 0x01);
      expect(FrameType.inventory.code, 0x02);
      expect(FrameType.inventoryEnd.code, 0x03);
      expect(FrameType.message.code, 0x10);
      expect(FrameType.messagesEnd.code, 0x11);
      expect(FrameType.bye.code, 0x20);
    });

    test('8192 を超えるフレームは作れない', () {
      expect(Frame(0x10, Uint8List(8191)).encode().length, 2 + 8192);
      expect(() => Frame(0x10, Uint8List(8192)).encode(), throwsArgumentError);
    });
  });

  group('HELLO', () {
    test('往復できる', () {
      final f = Frame.hello(nodeId: _nodeId, storeCount: 0x1234);
      expect(f.payload.length, 12);
      expect(f.payload, _bytes([1, 1, 2, 3, 4, 5, 6, 7, 8, 0x34, 0x12, 0]));
      final info = HelloInfo.parse(f.payload);
      expect(info.version, 1);
      expect(info.nodeId, _nodeId);
      expect(info.storeCount, 0x1234);
      expect(info.caps, 0);
    });

    test('store_count は u16 に丸める', () {
      expect(HelloInfo.parse(Frame.hello(nodeId: _nodeId, storeCount: 70000).payload)
          .storeCount, 0xFFFF);
    });

    test('nodeId は 8 バイト', () {
      expect(() => Frame.hello(nodeId: Uint8List(7), storeCount: 0),
          throwsArgumentError);
    });

    test('短い payload は FrameFormatException', () {
      expect(() => HelloInfo.parse(Uint8List(11)),
          throwsA(isA<FrameFormatException>()));
      expect(() => HelloInfo.parse(Uint8List(0)),
          throwsA(isA<FrameFormatException>()));
    });

    test('長い payload の余分は無視する（将来拡張）', () {
      final p = _bytes([1, 1, 2, 3, 4, 5, 6, 7, 8, 5, 0, 0, 0xEE, 0xFF]);
      expect(HelloInfo.parse(p).storeCount, 5);
    });
  });

  group('INVENTORY', () {
    test('往復できる（負の値を含む）', () {
      final ids = [1, -1, 0x7fffffffffffffff, -0x8000000000000000, 0, 42];
      final f = Frame.inventory(ids);
      expect(f.payload.length, 2 + ids.length * 8);
      expect(parseInventory(f.payload), ids);
      expect(parseInventory(Frame.inventory(const []).payload), isEmpty);
    });

    test('バイト配置: count(u16 LE) + msg_id × count（u64 LE）', () {
      final f = Frame.inventory([0x0807060504030201]);
      expect(f.payload, _bytes([1, 0, 1, 2, 3, 4, 5, 6, 7, 8]));
    });

    test('1 フレームの上限は 1023 件', () {
      expect(kMaxInventoryPerFrame, 1023);
      final max = List<int>.generate(1023, (i) => i);
      // length = type(1) + count(2) + 1023 × 8 = 8187 ≤ 8192
      expect(Frame.inventory(max).encode().length, 2 + 1 + 2 + 1023 * 8);
      expect(Frame.inventory(max).encode().length, lessThanOrEqualTo(2 + kMaxFrameLength));
      // 1024 件だと payload が 8,194 バイトになり上限を超える
      expect(2 + 1024 * 8, greaterThan(kMaxFramePayloadBytes));
      expect(() => Frame.inventory(List<int>.filled(1024, 0)), throwsArgumentError);
    });

    test('inventoryFrames は分割する', () {
      expect(Frame.inventoryFrames(const []), isEmpty);
      final ids = List<int>.generate(2000, (i) => i * 7);
      final frames = Frame.inventoryFrames(ids);
      expect(frames.length, 2);
      final joined = frames.expand((f) => parseInventory(f.payload)).toList();
      expect(joined, ids);
    });

    test('短い payload は FrameFormatException', () {
      expect(() => parseInventory(Uint8List(1)),
          throwsA(isA<FrameFormatException>()));
      expect(() => parseInventory(_bytes([2, 0, 1, 2, 3, 4, 5, 6, 7, 8])),
          throwsA(isA<FrameFormatException>()));
    });
  });

  group('FrameParser', () {
    final frames = <Frame>[
      Frame.hello(nodeId: _nodeId, storeCount: 3),
      Frame.inventory([1, 2, 3]),
      Frame.inventoryEnd(),
      Frame(0x10, _bytes(List.generate(1000, (i) => i & 0xFF))),
      Frame(0x77, Uint8List(0)), // 不明な type
      Frame(0x78, _bytes([9, 9, 9])), // 不明な type（payload あり）
      Frame.messagesEnd(),
      Frame.bye(),
    ];
    final stream = _bytes(frames.expand((f) => f.encode()).toList());

    test('複数フレームが 1 チャンクに入っていても分割できる', () {
      final parser = FrameParser();
      expect(parser.nextFrame(), isNull);
      parser.addChunk(stream);
      final got = <Frame>[];
      Frame? f;
      while ((f = parser.nextFrame()) != null) {
        got.add(f!);
      }
      expect(got.length, frames.length);
      for (var i = 0; i < frames.length; i++) {
        _expectFrame(got[i], frames[i]);
      }
      expect(parser.pendingBytes, 0);
      expect(parser.nextFrame(), isNull);
    });

    test('1 バイトずつでも復元できる', () {
      final parser = FrameParser();
      final got = _feed(parser, stream, List.filled(stream.length, 1));
      expect(got.length, frames.length);
      for (var i = 0; i < frames.length; i++) {
        _expectFrame(got[i], frames[i]);
      }
    });

    test('あらゆる境界で 2 分割しても復元できる', () {
      for (var cut = 0; cut <= stream.length; cut++) {
        final parser = FrameParser();
        final got = _feed(parser, stream, [cut, stream.length - cut]);
        expect(got.length, frames.length, reason: 'cut=$cut');
        for (var i = 0; i < frames.length; i++) {
          _expectFrame(got[i], frames[i]);
        }
      }
    });

    test('ランダムなチャンク長でも復元できる', () {
      final rng = Random(99);
      for (var trial = 0; trial < 200; trial++) {
        final cuts = <int>[];
        var total = 0;
        while (total < stream.length) {
          final c = 1 + rng.nextInt(300);
          cuts.add(c);
          total += c;
        }
        final parser = FrameParser();
        final got = _feed(parser, stream, cuts);
        expect(got.length, frames.length, reason: 'trial=$trial');
        for (var i = 0; i < frames.length; i++) {
          _expectFrame(got[i], frames[i]);
        }
        expect(parser.pendingBytes, 0);
      }
    });

    test('同じストリームを繰り返し流してもバッファが残らない', () {
      final parser = FrameParser();
      for (var i = 0; i < 20; i++) {
        parser.addChunk(stream);
      }
      var count = 0;
      while (parser.nextFrame() != null) {
        count++;
      }
      expect(count, frames.length * 20);
      expect(parser.pendingBytes, 0);
    });

    test('最大長 8192 のフレームを扱える', () {
      final big = Frame(0x10, Uint8List(8191));
      final parser = FrameParser();
      final enc = big.encode();
      parser.addChunk(enc.sublist(0, 100));
      expect(parser.nextFrame(), isNull);
      parser.addChunk(enc.sublist(100));
      final f = parser.nextFrame();
      expect(f, isNotNull);
      expect(f!.payload.length, 8191);
    });

    test('length が 8192 を超えるフレームは FrameFormatException', () {
      final parser = FrameParser();
      // length = 8193
      expect(() => parser.addChunk(_bytes([0x01, 0x20])),
          throwsA(isA<FrameFormatException>()));
      final parser2 = FrameParser();
      parser2.addChunk(_bytes([0xFF]));
      expect(parser2.nextFrame(), isNull);
      expect(() => parser2.addChunk(_bytes([0xFF])),
          throwsA(isA<FrameFormatException>()));
    });

    test('length が 0 のフレームは FrameFormatException', () {
      final parser = FrameParser();
      expect(() => parser.addChunk(_bytes([0x00, 0x00, 0x20])),
          throwsA(isA<FrameFormatException>()));
    });

    test('正常なフレームの後に不正な length が来ても前のフレームは取り出せる', () {
      final parser = FrameParser();
      final ok = Frame.bye().encode();
      expect(() => parser.addChunk(_bytes([...ok, 0x00, 0x40])),
          throwsA(isA<FrameFormatException>()));
      _expectFrame(parser.nextFrame()!, Frame.bye());
    });

    test('ランダムなごみは FrameFormatException 以外を投げない', () {
      final rng = Random(7);
      for (var i = 0; i < 500; i++) {
        final parser = FrameParser();
        final chunks = 1 + rng.nextInt(5);
        try {
          for (var c = 0; c < chunks; c++) {
            final n = rng.nextInt(64);
            parser.addChunk(_bytes(List.generate(n, (_) => rng.nextInt(256))));
            while (parser.nextFrame() != null) {}
          }
        } on FrameFormatException {
          // 期待どおり
        } catch (e) {
          fail('想定外の例外 ${e.runtimeType}: $e');
        }
      }
    });

    test('MESSAGE フレームに載せた封筒を復元できる', () {
      final env = Envelope.create(
        kind: MessageKind.notice,
        groupId: 123456,
        originId: _nodeId,
        createdAt: 1000,
        expiresAt: 2000,
        category: NoticeCategory.supply,
        role: SenderRole.official,
        bodyPlain: const NoticeBody(
          senderName: '〇〇市 防災課',
          title: '〇〇小学校に 水と 毛布が とどきました',
          place: '〇〇小学校',
          text: '午後3時から 体育館で 配布します。',
        ).encode(),
      );
      final stream = _bytes([
        ...Frame.hello(nodeId: _nodeId, storeCount: 1).encode(),
        ...Frame.message(env.encode()).encode(),
        ...Frame.messagesEnd().encode(),
      ]);
      final parser = FrameParser();
      final got = _feed(parser, stream, [5, 7, 11, 13, 17, 19, 23, 29, 31, 1000]);
      expect(got.length, 3);
      expect(got[1].type, FrameType.message);
      final decoded = Envelope.decode(got[1].payload);
      expect(decoded.msgId, env.msgId);
      expect(u64ToBytes(decoded.msgId), u64ToBytes(env.msgId));
      expect(decoded.notice!.title, '〇〇小学校に 水と 毛布が とどきました');
    });
  });
}
