import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/app/app_controller.dart';
import 'package:kairanban/app/theme.dart';
import 'package:kairanban/core/report.dart';
import 'package:kairanban/mesh/groups.dart';
import 'package:kairanban/mesh/store_file.dart';
import 'package:kairanban/transport/fake_transport.dart';
import 'package:kairanban/ui/screens/report_detail_screen.dart';
import 'package:kairanban/ui/screens/reports_screen.dart';
import 'package:kairanban/ui/widgets/report_card.dart';

import '../mesh/helpers.dart';
import '../mesh/report_inbox_test.dart' show FailableBackend, report;

void main() {
  testWidgets('旧中継枠だけの自分の返信を他端末の返信や受渡し済みと表示しない', (tester) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final relay = MemoryStoreBackend();
    final kv = MemoryKeyValueStore();
    final radio = FakeRadio(clock: FakeClock(startEpochSeconds: kT0));
    AppController make(String id, StoreBackend inbox) => AppController(
      transport: radio.createTransport(id),
      storeBackend: relay,
      reportBackend: inbox,
      kv: kv,
      now: radio.clock.now,
      createTimer: radio.clock.createTimer,
      nodeId: nodeIdOf(1),
    );
    final original = make('old-HQ', MemoryStoreBackend());
    await original.init();
    final group = await original.createGroup(name: '本部', membersCanPost: false);
    final message = report(1, group: group.code);
    await original.store.add(message, now: kT0);
    await original.acknowledgeReport(message.msgId);
    original.dispose();

    final inbox = FailableBackend()..fail = true;
    final controller = make('HQ', inbox);
    await controller.init();
    addTearDown(controller.dispose);
    expect(controller.reportInbox.count, 0);
    final entry = controller.receivedReports().single;
    expect(entry.ack!.isLocal, isTrue);
    expect(entry.replyPending, isFalse);
    expect(entry.replyHandedAt, isNull);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildKairanTheme(),
        home: ReportsScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('返信は 保存済み・受け渡し確認なし'), findsOneWidget);
    expect(find.textContaining('ほかの 端末から 受け取りの 返信あり'), findsNothing);
    expect(find.textContaining('に 受け取りましたと 返す'), findsNothing);
    await tester.pumpWidget(
      MaterialApp(
        key: UniqueKey(),
        theme: buildKairanTheme(),
        home: ReportDetailScreen(controller: controller, msgId: message.msgId),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('返信は 保存済み・受け渡し確認なし'), findsOneWidget);
    expect(find.text('返信は 自動送信待ちです'), findsNothing);
    expect(find.text('近くの スマホへ 渡しました'), findsNothing);
    expect(find.text('受け取りました と 返す'), findsNothing);
  });

  testWidgets('返信記録だけ保存された後の再起動では自動送信を待ち、受渡し確認で表示が変わる', (tester) async {
    final relay = FailableBackend();
    final inbox = MemoryStoreBackend();
    final kv = MemoryKeyValueStore();
    final radio = FakeRadio(clock: FakeClock(startEpochSeconds: kT0));
    AppController make(String id) => AppController(
      transport: radio.createTransport(id),
      storeBackend: relay,
      reportBackend: inbox,
      kv: kv,
      now: radio.clock.now,
      createTimer: radio.clock.createTimer,
      nodeId: nodeIdOf(1),
    );
    final first = make('HQ');
    await first.init();
    final group = await first.createGroup(name: '本部', membersCanPost: false);
    final message = report(1, group: group.code);
    await first.store.add(message, now: kT0);
    relay.fail = true;
    await expectLater(first.acknowledgeReport(message.msgId), throwsStateError);
    final savedAck = first.reportInbox.get(message.msgId)!.ack!;
    first.dispose();

    relay.fail = false;
    final restarted = make('HQ-restarted');
    await restarted.init();
    addTearDown(restarted.dispose);
    expect(restarted.receivedReports().single.replyPending, isTrue);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildKairanTheme(),
        home: ReportDetailScreen(controller: restarted, msgId: message.msgId),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('受け取りました と 返す'), findsNothing);
    expect(find.text('返信は 自動送信待ちです'), findsOneWidget);
    expect(find.textContaining('もう一度 返してください'), findsNothing);
    await restarted.reportInbox.markRepliesHanded([savedAck.msgId], at: kT0);
    await tester.pumpAndSettle();
    expect(restarted.store.contains(savedAck.msgId), isFalse);
    expect(
      restarted.reportInbox.get(message.msgId)!.ack!.msgId,
      savedAck.msgId,
    );
    expect(restarted.receivedReports().single.replyPending, isFalse);
    expect(restarted.receivedReports().single.replyHandedAt, kT0);
    expect(find.text('近くの スマホへ 渡しました'), findsOneWidget);
    expect(find.textContaining('本人への 到着や 対応完了を 示すものでは'), findsOneWidget);
    expect(find.text('受け取りました と 返す'), findsNothing);
  });

  testWidgets('元の知らせが期限切れでも送信待ちから開け、返信期限切れを受渡し済みにしない', (tester) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var now = kT0;
    final radio = FakeRadio(clock: FakeClock(startEpochSeconds: now));
    final controller = AppController(
      transport: radio.createTransport('HQ'),
      storeBackend: MemoryStoreBackend(),
      kv: MemoryKeyValueStore(),
      now: () => now,
      createTimer: radio.clock.createTimer,
    );
    await controller.init();
    addTearDown(controller.dispose);
    final group = await controller.createGroup(
      name: '本部',
      membersCanPost: false,
    );
    final message = report(1, group: group.code, type: ReportType.sos);
    await controller.store.add(message, now: now);
    final ack = (await controller.acknowledgeReport(message.msgId))!;
    now = message.expiresAt + 1;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildKairanTheme(),
        home: ReportsScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.receivedReports(), isEmpty);
    await tester.tap(find.text('自動送信待ち'));
    await tester.pumpAndSettle();
    expect(find.text('自動送信待ち 1件'), findsOneWidget);
    expect(find.text('過去の 知らせへの 返信・保存済み・自動送信待ち'), findsOneWidget);
    expect(find.textContaining('に 受け取りましたと 返す'), findsNothing);
    await tester.tap(find.text(message.help!.title));
    await tester.pumpAndSettle();
    expect(find.text('過去の 記録'), findsOneWidget);
    expect(find.text('返信は 自動送信待ちです'), findsOneWidget);
    expect(find.text('受け取りました と 返す'), findsNothing);

    now = ack.expiresAt + 1;
    await tester.pumpWidget(
      MaterialApp(
        key: UniqueKey(),
        theme: buildKairanTheme(),
        home: ReportDetailScreen(controller: controller, msgId: message.msgId),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('返信の 期限が 切れました'), findsOneWidget);
    expect(find.text('近くの スマホへ 渡しました'), findsNothing);
    expect(find.text('返信は 自動送信待ちです'), findsNothing);
    expect(find.text('受け取りました と 返す'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('期限切れの安否は現役集計から外れ、過去の記録で読める', (tester) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var now = kT0;
    final radio = FakeRadio(clock: FakeClock(startEpochSeconds: now));
    final controller = AppController(
      transport: radio.createTransport('HQ'),
      storeBackend: MemoryStoreBackend(),
      kv: MemoryKeyValueStore(),
      now: () => now,
      createTimer: radio.clock.createTimer,
    );
    await controller.init();
    addTearDown(controller.dispose);
    final group = await controller.createGroup(
      name: '本部',
      membersCanPost: false,
    );
    final message = report(1, group: group.code);
    await controller.store.add(message, now: now);
    now += 4 * 86400;
    await controller.store.purgeExpired(now);
    expect(controller.receivedReports(), isEmpty);
    expect(
      controller.receivedReports(includeExpired: true).single.expired,
      isTrue,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildKairanTheme(),
        home: ReportsScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('過去の 記録を 見る'));
    await tester.pumpAndSettle();
    expect(find.textContaining('今の 安否では ありません'), findsOneWidget);
    expect(find.text('期限切れの 過去の 記録'), findsOneWidget);
    expect(find.textContaining('に 受け取りましたと 返す'), findsNothing);
  });

  testWidgets('大量の安否記録も表示範囲のカードだけを構築する', (tester) async {
    final radio = FakeRadio(clock: FakeClock(startEpochSeconds: kT0));
    final controller = AppController(
      transport: radio.createTransport('HQ'),
      storeBackend: MemoryStoreBackend(),
      kv: MemoryKeyValueStore(),
      now: radio.clock.now,
      createTimer: radio.clock.createTimer,
    );
    await controller.init();
    addTearDown(controller.dispose);
    final group = await controller.createGroup(
      name: '本部',
      membersCanPost: false,
    );
    await controller.store.addAll([
      for (var i = 0; i < 1000; i++) report(i, group: group.code),
    ], now: kT0);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildKairanTheme(),
        home: ReportsScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ReportCard).evaluate().length, lessThan(20));
    expect(controller.receivedReports().length, 1000);
    expect(tester.takeException(), isNull);
  });
}
