/// 実物の [AppController]（フェイクのトランスポート・保存・時計）で
/// 画面を最初から最後まで通して動かす煙テスト。
///
/// はじめに → グループ作成 → お知らせ投稿 → 詳細 → 取り消し → 設定 → 通信の停止/再開。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/app/app_controller.dart';
import 'package:kairanban/core/categories.dart';
import 'package:kairanban/core/epoch.dart';
import 'package:kairanban/mesh/groups.dart';
import 'package:kairanban/mesh/store_file.dart';
import 'package:kairanban/transport/fake_transport.dart';
import 'package:kairanban/ui/app.dart';
import 'package:kairanban/ui/format.dart';
import 'package:kairanban/ui/widgets/notice_card.dart';
import 'package:qr_flutter/qr_flutter.dart';

class _FakePlatform extends NoopPlatformActions {
  int permissionRequests = 0;
  int notificationRequests = 0;
  int settingsOpened = 0;
  int noticesShown = 0;
  bool grant = true;
  bool grantNotification = true;

  @override
  Future<bool> requestPermissions() async {
    permissionRequests++;
    return grant;
  }

  @override
  Future<bool> requestBatteryOptimizationExemption() async => true;

  @override
  Future<void> openAppSettings() async {
    settingsOpened++;
  }

  @override
  Future<bool> requestNotificationPermission() async {
    notificationRequests++;
    return grantNotification;
  }

  @override
  Future<void> showNotice({
    required int id,
    required String title,
    required String body,
    required int groupCode,
    NoticeImportance importance = NoticeImportance.important,
    int? msgId,
  }) async {
    noticesShown++;
  }
}

Finder _navLabel(String label) => find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text(label),
    );

Future<void> _tap(WidgetTester tester, Finder finder) async {
  expect(finder, findsOneWidget);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// スナックバーの表示時間（4 秒）を過ぎさせる。
Future<void> _letSnackBarsExpire(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('初回起動から 投稿・取り消し・設定まで 通して動く', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final clock = FakeClock(
      startEpochSeconds: epochSecondsFrom(DateTime(2026, 10, 11, 15, 0)),
    );
    final radio = FakeRadio(clock: clock);
    final platform = _FakePlatform();
    final controller = AppController(
      transport: radio.createTransport('ui-test'),
      storeBackend: MemoryStoreBackend(),
      kv: MemoryKeyValueStore(),
      platform: platform,
      now: clock.now,
      createTimer: clock.createTimer,
    );
    await controller.init();
    addTearDown(controller.dispose);

    await tester.pumpWidget(KairanApp(controller));
    await tester.pumpAndSettle();

    // ---- はじめに 1/5 ----
    expect(find.text('1 / 5'), findsOneWidget);
    expect(find.textContaining('インターネットは 使いません'), findsOneWidget);
    await _tap(tester, find.widgetWithText(ElevatedButton, 'つぎへ'));

    // ---- 2/5 Bluetooth ----
    expect(find.text('2 / 5'), findsOneWidget);
    await _tap(tester, find.widgetWithText(ElevatedButton, 'Bluetooth を 許可する'));
    expect(platform.permissionRequests, 1);
    expect(find.text('Bluetooth が 許可されました。'), findsOneWidget);
    await _tap(tester, find.widgetWithText(ElevatedButton, 'つぎへ'));

    // ---- 3/5 通知 ----
    expect(find.text('3 / 5'), findsOneWidget);
    expect(find.text('お知らせが 届いたら 知らせる'), findsOneWidget);
    expect(find.textContaining('アプリを 閉じていても'), findsOneWidget);
    await _tap(tester, find.widgetWithText(ElevatedButton, '通知を 許可する'));
    expect(platform.notificationRequests, 1);
    expect(find.text('通知が 許可されました。'), findsOneWidget);
    await _tap(tester, find.widgetWithText(ElevatedButton, 'つぎへ'));

    // ---- 4/5 お願い ----
    expect(find.text('4 / 5'), findsOneWidget);
    expect(find.text('お願い'), findsOneWidget);
    expect(find.textContaining('スワイプして 終了しないでください'), findsOneWidget);
    expect(find.textContaining('Bluetooth を 切らないでください'), findsOneWidget);
    await _tap(tester, find.widgetWithText(ElevatedButton, 'つぎへ'));

    // ---- 5/5 表示名 → はじめる ----
    expect(find.text('5 / 5'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '山田');
    await tester.pump();
    await _tap(tester, find.widgetWithText(ElevatedButton, 'はじめる'));

    // ---- 下部タブと ホームの空状態 ----
    expect(controller.settings.onboardingDone, isTrue);
    expect(controller.settings.displayName, '山田');
    expect(controller.node.running, isTrue);
    expect(find.byType(NavigationBar), findsOneWidget);
    for (final label in ['お知らせ', 'グループ', '設定']) {
      expect(_navLabel(label), findsOneWidget, reason: 'タブ $label');
    }
    expect(find.text('グループに 参加すると お知らせが 届きます'), findsOneWidget);
    expect(find.textContaining('近くの人と 交換中'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'お知らせを 書く'), findsNothing);

    // ---- グループを 作る ----
    await _tap(tester, _navLabel('グループ'));
    expect(find.textContaining('まだ グループに 参加していません'), findsOneWidget);
    await _tap(tester, find.widgetWithText(OutlinedButton, 'グループを 作る'));
    expect(
      tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, '作る')).enabled,
      isFalse,
    );
    await tester.enterText(find.byType(TextField).first, '〇〇市 防災課');
    await tester.pump();
    await _tap(tester, find.widgetWithText(ElevatedButton, '作る'));

    final group = controller.groups.groups.single;
    expect(group.isHost, isTrue);
    expect(find.text('作りました'), findsOneWidget);
    expect(find.text(formatGroupCode(group.code)), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text(formatOfficialCode(group.hqCode!)), findsOneWidget);
    expect(find.text(formatOfficialCode(group.staffCode!)), findsOneWidget);
    expect(find.textContaining('紙に 書いて'), findsWidgets);
    await _tap(tester, find.widgetWithText(ElevatedButton, 'とじる'));

    expect(find.text('〇〇市 防災課'), findsOneWidget);
    expect(find.text('本部（作った人）'), findsOneWidget);
    expect(find.text('参加コード: ${formatGroupCode(group.code)}'), findsOneWidget);

    // ---- グループ詳細 ----
    await _tap(tester, find.text('〇〇市 防災課'));
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'このグループから 抜ける'), findsOneWidget);
    await _tap(tester, find.text('＜ もどる'));

    // ---- お知らせを 書く ----
    await _tap(tester, _navLabel('お知らせ'));
    await _tap(tester, find.widgetWithText(ElevatedButton, 'お知らせを 書く'));
    await _tap(tester, find.widgetWithText(OutlinedButton, '物資'));
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(3));
    TextField field(int i) => tester.widget<TextField>(fields.at(i));
    expect(field(1).controller!.text, '{場所}に {物資}が とどきました');

    await tester.enterText(fields.at(0), '〇〇小学校');
    await tester.pump();
    expect(field(1).controller!.text, '〇〇小学校に {物資}が とどきました');

    // 穴埋めが残っていると送れない。
    await _tap(tester, find.widgetWithText(ElevatedButton, '送る'));
    expect(find.textContaining('書きかえてください'), findsWidgets);
    await _tap(tester, find.widgetWithText(TextButton, 'とじる'));

    await tester.enterText(fields.at(1), '〇〇小学校に 水が とどきました');
    await tester.enterText(fields.at(2), '1人 2本まで。');
    await tester.pump();
    await _tap(tester, find.widgetWithText(ElevatedButton, '送る'));
    expect(find.textContaining('この内容で 送ります。近くの スマホに 広がり'), findsOneWidget);
    await _tap(tester, find.widgetWithText(TextButton, '送る'));
    expect(find.text('送りました。すれ違う人に 広がります。'), findsOneWidget);
    await _tap(tester, find.widgetWithText(TextButton, 'とじる'));

    // ---- ホームに 出る ----
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('〇〇小学校に 水が とどきました'), findsOneWidget);
    expect(find.text('今日 届いた'), findsOneWidget);
    expect(find.text('物資'), findsOneWidget);
    expect(find.text('公式'), findsOneWidget);
    expect(find.text('場所: 〇〇小学校'), findsOneWidget);
    // 物資は「〜まで」を併記する（12 時間後 = 翌 午前3時）。
    expect(find.text('2026年10月11日 午後3時00分 ・ 午前3時まで'), findsOneWidget);
    expect(find.text('1人 2本まで。'), findsOneWidget);
    final msg = controller.store.visibleNotices(now: controller.now).single;
    expect(msg.isLocal, isTrue);

    // ---- 詳細と 取り消し ----
    await _tap(tester, find.byType(NoticeCard));
    expect(find.textContaining('出された時刻: 2026年10月11日 午後3時00分'), findsOneWidget);
    expect(find.textContaining('この端末から 出しました'), findsOneWidget);
    expect(find.text('転送 0回'), findsNothing);
    expect(find.textContaining('掲示番号'), findsOneWidget);
    expect(find.text('1人 2本まで。'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '終わりました'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '書きなおす'), findsOneWidget);
    await _tap(tester, find.widgetWithText(OutlinedButton, '取り消す'));
    expect(find.text('お知らせを 取り消しますか？'), findsOneWidget);
    await _tap(tester, find.widgetWithText(TextButton, '取り消す'));
    expect(controller.store.get(msg.msgId)!.retracted, isTrue);
    expect(find.text('この お知らせは 取り消されました。'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '取り消す'), findsNothing);
    await _letSnackBarsExpire(tester);
    await _tap(tester, find.text('＜ もどる'));
    expect(find.byType(NoticeCard), findsNothing);

    // ---- 設定: 文字の大きさ ----
    await _tap(tester, _navLabel('設定'));
    await _tap(tester, find.widgetWithText(OutlinedButton, 'とても大きい'));
    expect(controller.settings.textScale, 1.5);
    final scaled = MediaQuery.textScalerOf(tester.element(find.text('文字の大きさ')));
    expect(scaled.scale(16), closeTo(24, 0.01));
    await _tap(tester, find.widgetWithText(OutlinedButton, '標準'));
    expect(controller.settings.textScale, 1.0);

    // ---- 設定: 表示名 ----
    await tester.enterText(
      find.widgetWithText(TextField, '山田'),
      '佐藤',
    );
    await _tap(tester, find.widgetWithText(OutlinedButton, '名前を 保存する'));
    expect(controller.settings.displayName, '佐藤');
    await _letSnackBarsExpire(tester);

    // ---- 設定: 電池 ----
    await _tap(tester, find.widgetWithText(OutlinedButton, '長持ち'));
    expect(controller.settings.lowPowerPreferred, isTrue);

    // ---- 設定: 通知（3 段階） ----
    expect(controller.settings.notificationsEnabled, isTrue);
    expect(controller.settings.notificationLevel, NotificationLevel.important);
    expect(find.textContaining('大事なものだけ 知らせます'), findsOneWidget);
    await _tap(tester, find.widgetWithText(OutlinedButton, '通知を 許可する'));
    expect(platform.notificationRequests, 2);
    expect(find.text('通知が 許可されました。'), findsOneWidget);
    await _letSnackBarsExpire(tester);
    await _tap(tester, find.widgetWithText(OutlinedButton, '知らせない'));
    expect(controller.settings.notificationsEnabled, isFalse);
    expect(find.textContaining('通知は 出しません'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '通知を 許可する'), findsNothing);
    await _tap(tester, find.widgetWithText(OutlinedButton, 'ぜんぶ 知らせる'));
    expect(controller.settings.notificationLevel, NotificationLevel.all);
    expect(controller.settings.notificationsEnabled, isTrue);
    // 自分の投稿しか無いので、OS 通知は一度も出ていない。
    expect(platform.noticesShown, 0);

    // ---- 設定: 通信を 止める → ホームで 再開 ----
    await _tap(tester, find.widgetWithText(OutlinedButton, '通信を 止める'));
    await _tap(tester, find.widgetWithText(TextButton, '止める'));
    expect(controller.node.running, isFalse);
    expect(find.widgetWithText(ElevatedButton, '通信を 始める'), findsOneWidget);
    await _letSnackBarsExpire(tester);

    await _tap(tester, _navLabel('お知らせ'));
    expect(find.text('交換が 止まっています'), findsOneWidget);
    await _tap(tester, find.widgetWithText(OutlinedButton, '再開する'));
    expect(controller.node.running, isTrue);
    expect(find.textContaining('近くの人と 交換中'), findsOneWidget);

    // ---- 通信の状態（診断） ----
    await _tap(tester, _navLabel('設定'));
    await _tap(tester, find.widgetWithText(OutlinedButton, '通信の 状態を 見る'));
    expect(find.text('通信の状態'), findsOneWidget);
    expect(find.textContaining('動いています'), findsOneWidget);
    expect(find.text('1件'), findsWidgets);
    await _tap(tester, find.widgetWithText(OutlinedButton, '更新'));
    await _tap(tester, find.text('＜ もどる'));
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('はじめに: 許可されなかったときは 設定を 開く ボタンを 出す', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final clock = FakeClock(startEpochSeconds: 1000);
    final radio = FakeRadio(clock: clock);
    final platform = _FakePlatform()
      ..grant = false
      ..grantNotification = false;
    final controller = AppController(
      transport: radio.createTransport('ui-test-2'),
      storeBackend: MemoryStoreBackend(),
      kv: MemoryKeyValueStore(),
      platform: platform,
      now: clock.now,
      createTimer: clock.createTimer,
    );
    await controller.init();
    addTearDown(controller.dispose);

    await tester.pumpWidget(KairanApp(controller));
    await tester.pumpAndSettle();
    await _tap(tester, find.widgetWithText(ElevatedButton, 'つぎへ'));
    await _tap(tester, find.widgetWithText(ElevatedButton, 'Bluetooth を 許可する'));
    expect(find.textContaining('許可されませんでした'), findsOneWidget);
    await _tap(tester, find.widgetWithText(OutlinedButton, 'スマホの 設定を 開く'));
    expect(platform.settingsOpened, 1);
    // 許可しなくても 先に 進める。
    await _tap(tester, find.widgetWithText(TextButton, 'あとで 許可する'));

    // 通知も 同じように 断れる。
    expect(find.text('3 / 5'), findsOneWidget);
    expect(find.text('お知らせが 届いたら 知らせる'), findsOneWidget);
    await _tap(tester, find.widgetWithText(ElevatedButton, '通知を 許可する'));
    expect(platform.notificationRequests, 1);
    expect(find.textContaining('許可されませんでした'), findsOneWidget);
    await _tap(tester, find.widgetWithText(OutlinedButton, 'スマホの 設定を 開く'));
    expect(platform.settingsOpened, 2);
    await _tap(tester, find.widgetWithText(TextButton, 'あとで 許可する'));
    expect(find.text('お願い'), findsOneWidget);
    // 「＜ もどる」で 前の 説明に 戻れる。
    await _tap(tester, find.text('＜ もどる'));
    expect(find.text('3 / 5'), findsOneWidget);
    await _tap(tester, find.text('＜ もどる'));
    expect(find.text('2 / 5'), findsOneWidget);
  });

  testWidgets('はじめに が 済んでいれば 最初から 下部タブを 出す', (tester) async {
    final clock = FakeClock(startEpochSeconds: 1000);
    final radio = FakeRadio(clock: clock);
    final controller = AppController(
      transport: radio.createTransport('ui-test-3'),
      storeBackend: MemoryStoreBackend(),
      kv: MemoryKeyValueStore(),
      now: clock.now,
      createTimer: clock.createTimer,
    );
    await controller.init();
    addTearDown(controller.dispose);
    final s = controller.settings;
    s.onboardingDone = true;
    await controller.saveSettings(s);

    await tester.pumpWidget(KairanApp(controller));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('1 / 5'), findsNothing);
    // 通信は 始めていないので 停止中の 帯が 出る。
    expect(find.text('交換が 止まっています'), findsOneWidget);
  });
}
