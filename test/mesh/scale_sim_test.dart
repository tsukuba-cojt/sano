/// 大量ユーザーの模擬（処理条件: ユーザー数）。実機を何百台も集められないので、
/// 模擬電波の上で多数の端末を動かし、全員に行き渡るまでの時間を測る。
///
/// 毎分、全員をランダムに 2 人ずつ組にし、組の相手とだけ電波が届く（すれ違い）とする。
/// 発見の通知は会ったときに 1 回だけ。
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/core/categories.dart';
import 'package:kairanban/core/envelope.dart';
import 'package:kairanban/transport/fake_transport.dart';

import 'helpers.dart';

void main() {
  Future<List<int>> simulate({
    required int count,
    required int minutes,
    required int seed,
    double meetRate = 1.0,
  }) async {
    final radio = FakeRadio(clock: FakeClock(startEpochSeconds: kT0));
    final nodes = <TestNode>[];
    for (var i = 0; i < count; i++) {
      final n = TestNode(radio, 'N$i', index: i + 1);
      await n.start();
      nodes.add(n);
    }
    var pairs = <String, String>{};
    radio.allowConnect = (from, to) => pairs[from.peerId] == to.peerId;
    final sos = makeNotice(
      origin: nodes.first.nodeId,
      createdAt: radio.clock.now(),
      category: NoticeCategory.evacuation,
      role: SenderRole.official,
      title: '〇〇川が あふれそうです。高台へ 避難してください',
    );
    await nodes.first.node.publish(sos);
    final random = Random(seed);
    final coverage = <int>[];
    for (var minute = 0; minute < minutes; minute++) {
      final order = [...nodes]..shuffle(random);
      pairs = {};
      for (var i = 0; i + 1 < order.length; i += 2) {
        if (random.nextDouble() > meetRate) {
          continue;
        }
        final x = order[i].id;
        final y = order[i + 1].id;
        pairs[x] = y;
        pairs[y] = x;
        radio.discover(x, y);
        radio.discover(y, x);
      }
      await radio.settle();
      await radio.elapse(const Duration(seconds: 60));
      final have = nodes.where((n) => n.store.contains(sos.msgId)).length;
      coverage.add(have);
      if (have == count) {
        break;
      }
    }
    for (final n in nodes) {
      await n.dispose();
    }
    return coverage;
  }

  test('200 台が毎分だれか 1 人とすれ違うと、1 台が出した避難情報は十数分で全員に届く', () async {
    final coverage = await simulate(count: 200, minutes: 30, seed: 1);
    // ignore: avoid_print
    print('200 台・毎分 1 人とすれ違う: 分ごとの到達台数 $coverage');
    expect(coverage.last, 200);
    expect(coverage.length, lessThanOrEqualTo(20));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('500 台で、すれ違う人が半分（毎分 50%）でも 30 分以内に全員に届く', () async {
    final coverage = await simulate(count: 500, minutes: 40, seed: 2, meetRate: 0.5);
    // ignore: avoid_print
    print('500 台・毎分 50% がすれ違う: 分ごとの到達台数 $coverage');
    expect(coverage.last, 500);
    expect(coverage.length, lessThanOrEqualTo(30));
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('2,000 台で、毎分 3 割の人だけがすれ違っても 1 時間以内に全員に届く', () async {
    final coverage = await simulate(count: 2000, minutes: 60, seed: 3, meetRate: 0.3);
    // ignore: avoid_print
    print('2,000 台・毎分 30% がすれ違う: 分ごとの到達台数 $coverage');
    expect(coverage.last, 2000);
    expect(coverage.length, lessThanOrEqualTo(60));
  }, timeout: const Timeout(Duration(minutes: 15)));
}
