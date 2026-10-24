import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/core/inventory_filter.dart';

void main() {
  final random = Random(7);
  int randomId() => (random.nextInt(1 << 32) << 32) | random.nextInt(1 << 32);

  test('3,000 件を約 3.6 KB に要約し、持っているものは必ず「持っている」と判定する', () {
    final ids = [for (var i = 0; i < 3000; i++) randomId()];
    final filter = InventoryFilter.build(ids, salt: 12345);
    expect(filter.bits.length, inInclusiveRange(3500, 3700));
    expect(filter.bits.length * 6, lessThan(3000 * 8)); // 一覧（24 KB）の 1/6 以下
    for (final id in ids) {
      expect(filter.mightContain(id), isTrue);
    }
  });

  test('持っていないものを「持っている」と誤る割合は約 1%、salt を変えると誤る相手が変わる', () {
    final ids = [for (var i = 0; i < 3000; i++) randomId()];
    final others = [for (var i = 0; i < 20000; i++) randomId()];
    final a = InventoryFilter.build(ids, salt: 1);
    final b = InventoryFilter.build(ids, salt: 2);
    final fpA = others.where(a.mightContain).toSet();
    final fpB = others.where(b.mightContain).toSet();
    expect(fpA.length / others.length, lessThan(0.02));
    expect(fpB.length / others.length, lessThan(0.02));
    // 同じものが 2 回続けて誤られることはまれ（次のすれ違いで送られる）。
    expect(fpA.intersection(fpB).length, lessThan(fpA.length ~/ 10 + 1));
  });

  test('直列化して戻せる。空でも作れる。不正な payload は FormatException', () {
    final ids = [for (var i = 0; i < 50; i++) randomId()];
    final filter = InventoryFilter.build(ids, salt: 0xFFFFFFFF);
    final back = InventoryFilter.decode(filter.encode());
    expect(back.salt, 0xFFFFFFFF);
    expect(back.itemCount, 50);
    for (final id in ids) {
      expect(back.mightContain(id), isTrue);
    }
    final empty = InventoryFilter.build(const [], salt: 3);
    expect(empty.mightContain(randomId()), isFalse);
    expect(() => InventoryFilter.decode(empty.encode().sublist(0, 5)), throwsFormatException);
    final bad = filter.encode()..[4] = 0;
    expect(() => InventoryFilter.decode(bad), throwsFormatException);
  });
}
