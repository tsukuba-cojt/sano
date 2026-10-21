import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/mesh/transport.dart';
import 'package:kairanban/transport/fake_transport.dart';

import 'helpers.dart';

void main() {
  group('FakeClock', () {
    test('タイマーは期限順に発火し、now が追従する', () async {
      final clock = FakeClock(startEpochSeconds: 100);
      final fired = <String>[];
      clock.createTimer(const Duration(seconds: 5), () {
        fired.add('b@${clock.now()}');
      });
      clock.createTimer(const Duration(seconds: 2), () {
        fired.add('a@${clock.now()}');
      });
      final cancelled = clock.createTimer(const Duration(seconds: 3), () {
        fired.add('x');
      });
      cancelled.cancel();
      expect(cancelled.isActive, isFalse);
      await clock.elapse(const Duration(seconds: 4));
      expect(fired, ['a@102']);
      expect(clock.now(), 104);
      await clock.elapse(const Duration(seconds: 1));
      expect(fired, ['a@102', 'b@105']);
      expect(clock.pendingTimers, 0);
    });

    test('発火中に作ったタイマーも同じ elapse 内で期限が来れば発火する', () async {
      final clock = FakeClock();
      final fired = <int>[];
      clock.createTimer(const Duration(seconds: 1), () {
        fired.add(clock.now());
        clock.createTimer(const Duration(seconds: 1), () {
          fired.add(clock.now());
        });
      });
      await clock.elapse(const Duration(seconds: 10));
      expect(fired, [1, 2]);
      expect(clock.now(), 10);
    });
  });

  group('FakeTransport', () {
    late FakeRadio radio;
    late FakeTransport a;
    late FakeTransport b;
    late List<TransportEvent> eventsA;
    late List<TransportEvent> eventsB;

    setUp(() async {
      radio = FakeRadio(defaultMaxChunk: 20);
      a = radio.createTransport('A');
      b = radio.createTransport('B');
      eventsA = [];
      eventsB = [];
      a.events.listen(eventsA.add);
      b.events.listen(eventsB.add);
      await a.start(TransportConfig(nodeId: nodeIdOf(1)));
      await b.start(TransportConfig(nodeId: nodeIdOf(2)));
      await radio.settle();
      eventsA.clear();
      eventsB.clear();
    });

    test('start で状態イベントが出る', () async {
      final c = radio.createTransport('C');
      final events = <TransportEvent>[];
      c.events.listen(events.add);
      await c.start(TransportConfig(nodeId: nodeIdOf(3), lowPower: true));
      await radio.settle();
      final state = events.single as TransportState;
      expect(state.poweredOn, isTrue);
      expect(state.scanning, isTrue);
      expect(state.permission, 'granted');
      expect(c.lowPower, isTrue);
    });

    test('bringNear で両方に PeerDiscovered が届く', () async {
      radio.bringNear('A', 'B', viaApple: true, rssi: -70);
      await radio.settle();
      final da = eventsA.single as PeerDiscovered;
      final db = eventsB.single as PeerDiscovered;
      expect(da.peerId, 'B');
      expect(da.viaApple, isTrue);
      expect(da.rssi, -70);
      expect(db.peerId, 'A');
    });

    test('未登録 peer への接続は peerId 付きの LinkClosed で失敗する', () async {
      await a.connect('ghost');
      await radio.settle();
      final closed = eventsA.single as LinkClosed;
      expect(closed.peerId, 'ghost');
      expect(closed.reason, 'service_not_found');
      expect(eventsB, isEmpty);
    });

    test('停止中の peer / unreachable への接続は失敗する', () async {
      await b.stop();
      await radio.settle();
      eventsA.clear();
      await a.connect('B');
      await radio.settle();
      expect((eventsA.single as LinkClosed).reason, 'timeout');

      await b.start(TransportConfig(nodeId: nodeIdOf(2)));
      radio.unreachable.add('B');
      eventsA.clear();
      await a.connect('B');
      await radio.settle();
      expect((eventsA.single as LinkClosed).reason, 'timeout');
    });

    test('接続・送受信・切断がペアで起こり、データは順序通り', () async {
      await a.connect('B');
      await radio.settle();
      final openedA = eventsA.single as LinkOpened;
      final openedB = eventsB.single as LinkOpened;
      expect(openedA.initiator, isTrue);
      expect(openedB.initiator, isFalse);
      expect(openedA.peerId, 'B');
      expect(openedB.peerId, 'A');
      expect(openedA.maxChunk, 20);
      expect(openedA.linkId, isNot(openedB.linkId));
      eventsA.clear();
      eventsB.clear();

      await a.send(openedA.linkId, Uint8List.fromList([1, 2, 3]));
      await a.send(openedA.linkId, Uint8List.fromList([4]));
      await b.send(openedB.linkId, Uint8List.fromList([9, 9]));
      await radio.settle();
      expect(eventsB.map((e) => (e as LinkData).data.toList()).toList(), [
        [1, 2, 3],
        [4],
      ]);
      expect((eventsA.single as LinkData).data, [9, 9]);
      expect((eventsA.single as LinkData).linkId, openedA.linkId);
      expect(radio.bytesSent, 6);
      expect(radio.chunksSent, 3);
      eventsA.clear();
      eventsB.clear();

      await expectLater(
        () => a.send(openedA.linkId, Uint8List(21)),
        throwsArgumentError,
      );

      await b.close(openedB.linkId);
      await expectLater(
        () => b.send(openedB.linkId, Uint8List(1)),
        throwsStateError,
      );
      await radio.settle();
      expect((eventsA.single as LinkClosed).linkId, openedA.linkId);
      expect((eventsA.single as LinkClosed).peerId, 'B');
      expect((eventsB.single as LinkClosed).linkId, openedB.linkId);
      expect(a.openLinkIds, isEmpty);
      expect(b.openLinkIds, isEmpty);
      await expectLater(
        () => a.send(openedA.linkId, Uint8List(1)),
        throwsStateError,
      );
      // 二重 close は無害。
      await a.close(openedA.linkId);
    });

    test('close 前に送ったデータは届いてから LinkClosed になる', () async {
      await a.connect('B');
      await radio.settle();
      final openedA = eventsA.single as LinkOpened;
      eventsB.clear();
      await a.send(openedA.linkId, Uint8List.fromList([7]));
      await a.close(openedA.linkId);
      await radio.settle();
      expect(eventsB.length, 2);
      expect(eventsB[0], isA<LinkData>());
      expect(eventsB[1], isA<LinkClosed>());
    });

    test('stop は開いているリンクをすべて閉じる', () async {
      await a.connect('B');
      await radio.settle();
      eventsA.clear();
      eventsB.clear();
      await a.stop();
      await radio.settle();
      expect(eventsB.whereType<LinkClosed>().length, 1);
      expect(eventsA.whereType<LinkClosed>().length, 1);
      expect(eventsA.whereType<TransportState>().single.scanning, isFalse);
      expect(a.running, isFalse);
      await expectLater(() => a.connect('B'), throwsStateError);
    });

    test('同じ peerId は 2 回登録できない', () {
      expect(() => radio.createTransport('A'), throwsArgumentError);
    });
  });
}
