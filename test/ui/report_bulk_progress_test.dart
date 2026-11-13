import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/app/app_controller.dart';
import 'package:kairanban/app/theme.dart';
import 'package:kairanban/mesh/groups.dart';
import 'package:kairanban/mesh/store_file.dart';
import 'package:kairanban/transport/fake_transport.dart';
import 'package:kairanban/ui/screens/reports_screen.dart';
import 'package:kairanban/ui/widgets/big_button.dart';

import '../mesh/helpers.dart';
import '../mesh/report_inbox_test.dart' show report;

class _PausedBackend extends MemoryStoreBackend {
  int remainingWrites = -1;
  Completer<void>? paused;

  Future<void> _pause() async {
    if (remainingWrites < 0) return;
    if (remainingWrites-- == 0) {
      paused = Completer<void>();
      await paused!.future;
    }
  }

  @override
  Future<void> appendAll(List<Uint8List> records) async {
    await _pause();
    await super.appendAll(records);
  }

  @override
  Future<void> rewrite(List<Uint8List> records) async {
    await _pause();
    await super.rewrite(records);
  }
}

Future<AppController> _showReports(
  WidgetTester tester, {
  required int count,
  StoreBackend? inbox,
}) async {
  tester.view.physicalSize = const Size(800, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final radio = FakeRadio(clock: FakeClock(startEpochSeconds: kT0));
  final c = AppController(
    transport: radio.createTransport('HQ'),
    storeBackend: MemoryStoreBackend(),
    reportBackend: inbox,
    kv: MemoryKeyValueStore(),
    now: radio.clock.now,
    createTimer: radio.clock.createTimer,
  );
  await c.init();
  c.setForeground(true);
  addTearDown(c.dispose);
  final group = await c.createGroup(name: '本部', membersCanPost: false);
  await c.store.addAll([
    for (var i = 0; i < count; i++) report(i, group: group.code),
  ], now: kT0);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildKairanTheme(),
      home: ReportsScreen(controller: c),
    ),
  );
  await tester.pumpAndSettle();
  return c;
}

Future<void> _startAll(WidgetTester tester) async {
  await tester.tap(find.textContaining('に 受け取りましたと 返す'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('返事を する'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('一括返信の保存件数を途中表示し、保存待ちの間も絞り込める', (tester) async {
    final backend = _PausedBackend();
    final c = await _showReports(tester, count: 250, inbox: backend);
    backend.remainingWrites = 1;
    await _startAll(tester);
    expect(backend.paused, isNotNull);
    expect(find.text('返信を 記録しています 100 / 250件'), findsOneWidget);
    expect(c.receivedReports().where((e) => e.acked), hasLength(100));
    expect(
      tester.widget<PrimaryButton>(find.byType(PrimaryButton)).onPressed,
      isNull,
    );
    await tester.tap(find.widgetWithText(ChoiceButton, '無事'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<ChoiceButton>(find.byType(ChoiceButton))
          .singleWhere((button) => button.label == '無事')
          .selected,
      isTrue,
    );
    backend.paused!.complete();
    await tester.pumpAndSettle();
    expect(c.receivedReports().every((e) => e.acked), isTrue);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.textContaining('250件の 返信を 保存しました'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('中継枠を超える一括返信は準備待ちを知らせ、未返信の絞り込みに残す', (tester) async {
    final c = await _showReports(tester, count: 3200);
    await _startAll(tester);
    final entries = c.receivedReports();
    final waiting = entries.where((e) => e.replyPending).length;
    expect(entries.every((e) => e.acked), isTrue);
    expect(waiting, greaterThan(0));
    expect(find.text('返信を 記録しました'), findsOneWidget);
    expect(find.textContaining('返信の 記録: 3200件'), findsOneWidget);
    expect(find.textContaining('準備待ちの 返信: $waiting件'), findsOneWidget);
    expect(find.textContaining('相手への 到着を 確認した 件数では'), findsOneWidget);
    await tester.tap(find.text('とじる'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('まだ 返事を していない'));
    await tester.pumpAndSettle();
    expect(find.text('表示中の $waiting件に 受け取りましたと 返す'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
