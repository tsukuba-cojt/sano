/// 開発者メニュー（#152）と、通信の状態の「交換ごとの 量と 秒数」の画面テスト。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/app/app_controller.dart';
import 'package:kairanban/app/theme.dart';
import 'package:kairanban/core/epoch.dart';
import 'package:kairanban/mesh/groups.dart';
import 'package:kairanban/mesh/mesh_node.dart';
import 'package:kairanban/mesh/store_file.dart';
import 'package:kairanban/transport/fake_transport.dart';
import 'package:kairanban/ui/screens/diagnostics_screen.dart';
import 'package:kairanban/ui/screens/settings_screen.dart';

Future<void> _tap(WidgetTester tester, Finder finder) async {
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('バージョンを 7 回 押すと開発者メニューが出て、30 件を入れて消せる', (tester) async {
    final radio = FakeRadio(
      clock: FakeClock(
        startEpochSeconds: epochSecondsFrom(DateTime(2026, 11, 5, 10, 0)),
      ),
    );
    final c = AppController(
      transport: radio.createTransport('A'),
      storeBackend: MemoryStoreBackend(),
      kv: MemoryKeyValueStore(),
      now: radio.clock.now,
      createTimer: radio.clock.createTimer,
    );
    await c.init();
    final g = await c.createGroup(name: '試験', membersCanPost: true);

    await tester.pumpWidget(MaterialApp(
      theme: buildKairanTheme(),
      home: SettingsScreen(controller: c),
    ));
    await tester.pumpAndSettle();
    expect(find.text('開発者メニュー'), findsNothing);
    final version = find.text('回覧板 バージョン $kAppVersionLabel');
    await tester.scrollUntilVisible(
      version,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    for (var i = 0; i < 7; i++) {
      await tester.tap(version);
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(c.settings.developerMode, isTrue);

    await _tap(tester, find.text('開発者メニュー'));
    expect(find.text('開発者メニュー'), findsOneWidget); // 画面の見出し
    await _tap(tester, find.text('30 件（TD1 普段の 差分）'));
    expect(c.testDataCount, 30);
    expect(c.store.visibleNotices(now: c.now, groupIds: {g.code}).length, 30);

    await _tap(tester, find.text('テストデータを この端末から 消す'));
    await _tap(tester, find.text('消す'));
    expect(c.testDataCount, 0);

    await _tap(tester, find.text('開発者メニューを 隠す'));
    expect(c.settings.developerMode, isFalse);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  test('交換 1 回の行に、件数・量・秒数・速さ・最初の 1 件までの秒数が出る', () {
    final line = DiagnosticsScreen.sessionLine(SessionStat(
      at: epochSecondsFrom(DateTime(2026, 11, 5, 10, 2, 3)),
      peerNodeHex: 'a1b2c3d4e5f60708',
      initiator: true,
      succeeded: true,
      messagesSent: 3,
      messagesReceived: 120,
      bytesSent: 1024,
      bytesReceived: 30 * 1024,
      elapsed: const Duration(milliseconds: 2500),
      firstMessageAfter: const Duration(milliseconds: 400),
      hasMore: true,
    ));
    expect(
      line,
      '10:02:03 相手 a1b2c3（こちらから） 受信 120 件・送信 3 件 31.0 KB 2.5 秒'
      '（12.4 KB/秒） 最初の 1 件 0.4 秒 続きあり',
    );
  });
}
