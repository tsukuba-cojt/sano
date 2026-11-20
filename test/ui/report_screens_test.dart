/// 「本部に 知らせる」（住民）と「住民からの 知らせ」（本部）の画面テスト。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/app/app_controller.dart';
import 'package:kairanban/app/theme.dart';
import 'package:kairanban/core/categories.dart';
import 'package:kairanban/core/envelope.dart';
import 'package:kairanban/core/epoch.dart';
import 'package:kairanban/core/report.dart';
import 'package:kairanban/mesh/groups.dart';
import 'package:kairanban/mesh/store_file.dart';
import 'package:kairanban/transport/fake_transport.dart';
import 'package:kairanban/ui/routes.dart';
import 'package:kairanban/ui/screens/home_screen.dart';
import 'package:kairanban/ui/screens/notice_detail_screen.dart';

Future<void> _tap(WidgetTester tester, Finder finder) async {
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// [open] を押すと画面を開くだけの土台。
Widget _host(void Function(BuildContext) open) => MaterialApp(
  key: UniqueKey(),
  theme: buildKairanTheme(),
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () => open(context),
          child: const Text('開く'),
        ),
      ),
    ),
  ),
);

void main() {
  late FakeRadio radio;
  late AppController hq;
  late AppController resident;

  Future<AppController> make(String id) async {
    final c = AppController(
      transport: radio.createTransport(id),
      storeBackend: MemoryStoreBackend(),
      kv: MemoryKeyValueStore(),
      now: radio.clock.now,
      createTimer: radio.clock.createTimer,
    );
    await c.init();
    return c;
  }

  /// すれ違いの代わりに、[from] の封筒を [to] の保存領域へ写す（hop + 1）。
  Future<void> transfer(AppController from, AppController to) async {
    for (final m in from.store.all) {
      if (to.store.contains(m.msgId) || m.isStub) {
        continue;
      }
      final env = Envelope.decode(
        m.envelope.encode(),
      ).copyWith(hop: m.envelope.hop + 1);
      await to.store.add(env, now: to.now);
    }
  }

  Future<void> meet(
    WidgetTester tester,
    AppController a,
    AppController b,
  ) async {
    await transfer(a, b);
    await transfer(b, a);
    await tester.pump();
  }

  setUp(() {
    radio = FakeRadio(
      clock: FakeClock(
        startEpochSeconds: epochSecondsFrom(DateTime(2026, 10, 23, 15, 0)),
      ),
    );
  });

  testWidgets('住民が「無事です」を送り、本部が一覧で見て「受け取りました」を返す', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    hq = await make('HQ');
    resident = await make('B');
    addTearDown(hq.dispose);
    addTearDown(resident.dispose);
    await hq.saveSettings(hq.settings.copy()..displayName = '〇〇市 防災課');
    final g = await hq.createGroup(
      name: '〇〇市 防災',
      membersCanPost: false,
      acceptsHelp: true,
    );
    await resident.joinGroup(g.code);
    await meet(tester, resident, hq);
    expect(resident.reportGroups, isNotEmpty);

    // ---- 住民のホーム: 「本部に 知らせる」ボタン ----
    await tester.pumpWidget(
      MaterialApp(
        key: UniqueKey(),
        theme: buildKairanTheme(),
        home: HomeScreen(controller: resident),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('本部に 知らせる（SOS・安否）'), findsOneWidget);
    expect(find.textContaining('住民からの 知らせ'), findsNothing);

    // ---- 送る画面 ----
    await tester.pumpWidget(
      _host((context) => openReportScreen(context, resident)),
    );
    await _tap(tester, find.text('開く'));
    expect(find.text('どれを 知らせますか'), findsOneWidget);
    for (final t in ReportType.values) {
      expect(find.text(t.label), findsOneWidget);
    }
    expect(find.textContaining('119番・110番'), findsOneWidget);

    await _tap(tester, find.text('無事です'));
    expect(find.text('無事な 人数（自分を 入れて）'), findsOneWidget);
    await _tap(tester, find.text('3人'));
    await _tap(tester, find.text('けがを している 人が いる'));
    await tester.enterText(find.byType(TextField).at(0), '山田 花子');
    await tester.enterText(find.byType(TextField).at(1), '〇〇町2丁目');
    await tester.pumpAndSettle();
    expect(find.text('見出し: 【無事】山田 花子 さんは 無事です（3人） けが人 あり'), findsOneWidget);

    await _tap(tester, find.widgetWithText(ElevatedButton, '送る'));
    expect(find.textContaining('名前「山田 花子」も 送ります'), findsOneWidget);
    await _tap(tester, find.widgetWithText(TextButton, '送る'));
    expect(find.text('送りました'), findsOneWidget);
    await _tap(tester, find.text('とじる'));
    expect(find.text('開く'), findsOneWidget);

    final mine = resident.myReports().single;
    expect(mine.info.type, ReportType.safe);
    expect(mine.info.people, 3);
    expect(mine.info.injured, isTrue);
    expect(mine.body.senderName, '山田 花子');
    expect(mine.body.place, '〇〇町2丁目');

    // 30 分以内の送り直しは止める。
    await _tap(tester, find.text('開く'));
    expect(find.text('送った 知らせ'), findsOneWidget);
    expect(find.text('まだ 受け取りの 返事は ありません'), findsOneWidget);
    await _tap(tester, find.text('無事です'));
    await _tap(tester, find.widgetWithText(ElevatedButton, '送る'));
    await _tap(tester, find.widgetWithText(TextButton, '送る'));
    expect(find.text('さきほど 送りました'), findsOneWidget);
    await _tap(tester, find.text('とじる'));
    expect(resident.myReports().length, 1);

    // ---- 本部 ----
    await meet(tester, hq, resident);
    expect(hq.receivedReports().length, 1);
    await tester.pumpWidget(
      MaterialApp(
        key: UniqueKey(),
        theme: buildKairanTheme(),
        home: HomeScreen(controller: hq),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('住民からの 知らせ: 無事 1件（3人）'), findsOneWidget);
    expect(find.text('本部に 知らせる（SOS・安否）'), findsNothing);

    await tester.pumpWidget(_host((context) => openReportsScreen(context, hq)));
    await _tap(tester, find.text('開く'));
    expect(find.text('届いた 知らせ 1件'), findsOneWidget);
    expect(find.textContaining('無事 1件（3人）'), findsOneWidget);
    await _tap(tester, find.text('【無事】山田 花子 さんは 無事です（3人） けが人 あり'));
    expect(find.text('山田 花子'), findsOneWidget);
    expect(find.text('〇〇町2丁目'), findsOneWidget);
    await _tap(tester, find.widgetWithText(ElevatedButton, '受け取りました と 返す'));
    expect(find.text('返信は 自動送信待ちです'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, '受け取りました と 返す'), findsNothing);
    expect(hq.receivedReports().single.acked, isTrue);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('安否確認の お知らせに 返事の ボタンが 出て、押すと 種類が 決まった 画面が 開く', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    hq = await make('HQ');
    resident = await make('B');
    addTearDown(hq.dispose);
    addTearDown(resident.dispose);
    final g = await hq.createGroup(name: '〇〇市 防災', membersCanPost: false);
    await resident.joinGroup(g.code);
    final request = await hq.postNotice(
      groupCode: g.code,
      category: NoticeCategory.safety,
      title: '安否確認です。下の ボタンで 返事を してください',
      asksReply: true,
    );
    await meet(tester, resident, hq);
    expect(resident.reportGroups, isEmpty);

    await tester.pumpWidget(
      _host(
        (context) => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                NoticeDetailScreen(controller: resident, msgId: request.msgId),
          ),
        ),
      ),
    );
    await _tap(tester, find.text('開く'));
    expect(find.text('返事を ください'), findsOneWidget);
    expect(find.text('返事を してください'), findsOneWidget);
    await _tap(tester, find.widgetWithText(OutlinedButton, '家に います（在宅避難）'));
    expect(find.text('安否確認に 返事を する'), findsOneWidget);
    expect(find.textContaining('への 返事です。'), findsOneWidget);
    expect(find.text('家に いる 人数（自分を 入れて）'), findsOneWidget);
    await _tap(tester, find.text('2人'));
    await _tap(tester, find.text('水・食べ物が ない'));
    await _tap(tester, find.widgetWithText(ElevatedButton, '送る'));
    await _tap(tester, find.widgetWithText(TextButton, '送る'));
    await _tap(tester, find.text('とじる'));

    final mine = resident.myReports(inReplyTo: request.msgId).single;
    expect(mine.info.type, ReportType.home);
    expect(mine.info.needs, [ReportNeed.water]);
    // 詳細に戻ると送った返事の状態が出る。
    expect(find.textContaining('「家に います（在宅避難）」を 送りました'), findsOneWidget);

    // 本部側の詳細には集計が出る。
    await meet(tester, hq, resident);
    await tester.pumpWidget(
      _host(
        (context) => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                NoticeDetailScreen(controller: hq, msgId: request.msgId),
          ),
        ),
      ),
    );
    await _tap(tester, find.text('開く'));
    expect(find.text('返事 1件'), findsOneWidget);
    expect(find.textContaining('在宅避難 1件（2人）'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '無事です'), findsNothing);
    await _tap(tester, find.widgetWithText(OutlinedButton, '返事を 見る'));
    // 画面の題名と、カードの「安否確認への 返事」の印。
    expect(find.text('安否確認への 返事'), findsNWidgets(2));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}
