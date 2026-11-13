import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/app/app_controller.dart';
import 'package:kairanban/app/theme.dart';
import 'package:kairanban/mesh/groups.dart';
import 'package:kairanban/mesh/store_file.dart';
import 'package:kairanban/transport/fake_transport.dart';
import 'package:kairanban/ui/screens/report_detail_screen.dart';
import 'package:kairanban/ui/screens/reports_screen.dart';
import 'package:kairanban/ui/widgets/report_card.dart';

import '../mesh/helpers.dart';
import '../mesh/report_inbox_test.dart' show FailableBackend, report;

void main() {
  testWidgets('返信記録だけ保存された後に再起動しても、画面から同じ返信を再試行できる', (tester) async {
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
    expect(find.text('受け取りました と 返す'), findsOneWidget);
    expect(find.textContaining('返信を 広げる 準備が できていません'), findsOneWidget);
    await tester.tap(find.text('受け取りました と 返す'));
    await tester.pumpAndSettle();
    expect(restarted.store.contains(savedAck.msgId), isTrue);
    expect(
      restarted.reportInbox.get(message.msgId)!.ack!.msgId,
      savedAck.msgId,
    );
    expect(restarted.receivedReports().single.replyPending, isFalse);
    expect(find.text('受け取りました と 返す'), findsNothing);
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
