/// 両方が同じ SOS を持っているとき、毎回の交換で先出しし直さないか。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/transport/fake_transport.dart';

import 'helpers.dart';
import 'mesh_spread_test.dart' show makeHelp;

void main() {
  test('両方が持っている SOS は、2 回目以降の交換で先出ししない', () async {
    final radio = FakeRadio(clock: FakeClock(startEpochSeconds: kT0));
    final a = TestNode(radio, 'A', index: 1);
    final b = TestNode(radio, 'B', index: 2);
    await a.start();
    await b.start();
    final sos = makeHelp(origin: a.nodeId, createdAt: kT0);
    await a.store.add(sos, now: kT0, isLocal: true);
    await b.store.add(sos, now: kT0);

    for (var round = 0; round < 3; round++) {
      radio.discover('B', 'A');
      await radio.settle();
      await radio.elapse(const Duration(minutes: 3));
    }
    final pushes = [...a.node.recentLog, ...b.node.recentLog]
        .where((l) => l.contains('先出し '))
        .toList();
    // 最初の交換で互いに先出しして確かめ合うまで（双方 1 回ずつ）。
    expect(pushes.length, lessThanOrEqualTo(2));
    await a.dispose();
    await b.dispose();
  });
}
