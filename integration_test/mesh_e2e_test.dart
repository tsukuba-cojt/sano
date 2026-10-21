/// 端末上で実際の画面を操作して、すれ違い通信の往復を確かめる統合テスト。
///
/// 使い方（開発用 TCP ハブ `dart run tool/hub.dart --port 7777` を起動しておく）:
///
/// ```
/// # 1 台だけで画面の流れを確認する（投稿まで）
/// flutter test integration_test/mesh_e2e_test.dart -d <device> \
///   --dart-define=KAIRANBAN_HUB=127.0.0.1:7777
///
/// # 2 台で往復を確認する（host と guest を同時に走らせる）
/// flutter test integration_test/mesh_e2e_test.dart -d <iOS simulator> \
///   --dart-define=KAIRANBAN_HUB=127.0.0.1:7777 --dart-define=KAIRANBAN_TEST_ROLE=host
/// flutter test integration_test/mesh_e2e_test.dart -d <Android emulator> \
///   --dart-define=KAIRANBAN_HUB=10.0.2.2:7777 --dart-define=KAIRANBAN_TEST_ROLE=guest
/// ```
///
/// - host: グループを作り、物資のお知らせを出し、guest からの返事が届くのを待つ。
/// - guest: 近くから届いた group_info で参加コードを知り、参加して、
///   host のお知らせを受け取り、返事を出す。
/// - solo（既定）: host と同じ操作を 1 台で行い、返事は待たない。
/// - demo: 実機・Mac で本物の BLE を使う長時間デモ。ハブなしで起動し、グループを作って
///   参加コードを画面とログに出し、数分おきにお知らせを投稿しながら、相手から届いたものをログに出す。
///   `--dart-define=KAIRANBAN_DEMO_MINUTES=30` で長さを変えられる（既定 30 分）。
///
///   macOS では、テストランナーの子プロセスとして起動すると TCC が親プロセスの Info.plist を見て
///   Bluetooth で落ちるため、テストを本体にしたアプリを作って `open` で起動する:
///
/// ```
/// flutter build macos --debug -t integration_test/mesh_e2e_test.dart \
///   --dart-define=KAIRANBAN_TEST_ROLE=demo --dart-define=KAIRANBAN_DEMO_MINUTES=30
/// open build/macos/Build/Products/Debug/kairanban.app
/// tail -f ~/Library/Containers/jp.kairanban.kairanban/Data/Library/Application\ Support/jp.kairanban.kairanban/demo_log.txt
/// ```
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kairanban/app/app_controller.dart';
import 'package:kairanban/core/categories.dart';
import 'package:kairanban/core/envelope.dart';
import 'package:kairanban/mesh/groups.dart';
import 'package:kairanban/mesh/message_store.dart';
import 'package:kairanban/ui/app.dart';
import 'package:kairanban/ui/widgets/six_digit_input.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kRole =
    String.fromEnvironment('KAIRANBAN_TEST_ROLE', defaultValue: 'solo');

const String kHostGroupName = 'テスト市 防災課';
const String kHostPlace = '第一小学校';
const String kHostTitle = '第一小学校に 水が とどきました';
const String kHostText = '1人 2本まで。午後5時まで 配ります。';
const String kGuestTitle = '返事です。お知らせを 受け取りました';

const Duration kPeerWait = Duration(seconds: 240);

/// demo ロールの長さ（分）。
const int kDemoMinutes =
    int.fromEnvironment('KAIRANBAN_DEMO_MINUTES', defaultValue: 30);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('すれ違い通信の往復（role=$kRole）', (tester) async {
    // demo は、保存先に demo_resume.flag があれば前回の状態（グループ・参加コード）を引き継ぐ。
    final resume = kRole == 'demo' && await _demoResumeRequested();
    if (!resume) {
      await _resetAppState();
    }
    if (kRole == 'demo') {
      await _openDemoLog(append: resume);
    }

    final controller = await AppController.createDefault();
    await controller.init();
    await tester.pumpWidget(KairanApp(controller));
    await tester.pumpAndSettle();

    if (resume && find.text('はじめに').evaluate().isEmpty) {
      _log('前回の状態を引き継いで再開します');
      if (!controller.node.running) {
        await controller.startMesh();
      }
    } else {
      await _runOnboarding(tester,
          displayName: kRole == 'guest' ? '鈴木' : '防災課',
          lenient: kRole == 'demo');
    }

    switch (kRole) {
      case 'guest':
        await _guestFlow(tester, controller);
      case 'host':
        await _hostFlow(tester, controller, waitForReply: true);
      case 'demo':
        await _demoFlow(tester, controller);
      default:
        await _hostFlow(tester, controller, waitForReply: false);
    }
  },
      timeout: Timeout(kRole == 'demo'
          ? Duration(minutes: kDemoMinutes + 10)
          : const Duration(minutes: 12)));
}

// ---------------------------------------------------------------------------
// 流れ
// ---------------------------------------------------------------------------

/// [lenient] のとき（demo）は、OS の許可ダイアログを人が押すまで最大 2 分待ち、
/// 許可されなくても「あとで 許可する」で先へ進む。
Future<void> _runOnboarding(WidgetTester tester,
    {required String displayName, bool lenient = false}) async {
  final permissionWait =
      lenient ? const Duration(seconds: 120) : const Duration(seconds: 10);
  expect(find.text('はじめに'), findsOneWidget);
  await _tapText(tester, 'つぎへ');
  await _tapText(tester, 'Bluetooth を 許可する');
  if (lenient) {
    _log('OS の Bluetooth 許可ダイアログが出ていれば「許可」を押してください（最大 120 秒 待ちます）');
  }
  await _passPermissionStep(tester, permissionWait, lenient: lenient);
  // 通知の許可（Bluetooth の許可と一緒に POST_NOTIFICATIONS も取っているので、すぐ「つぎへ」になる）。
  expect(find.text('お知らせが 届いたら 知らせる'), findsOneWidget);
  await _tapText(tester, '通知を 許可する');
  if (lenient) {
    _log('OS の通知許可ダイアログが出ていれば「許可」を押してください');
  }
  await _passPermissionStep(tester, permissionWait, lenient: lenient);
  expect(find.text('お願い'), findsOneWidget);
  await _tapText(tester, 'つぎへ');
  expect(find.text('表示名'), findsWidgets);
  await tester.enterText(find.byType(TextField).first, displayName);
  await tester.pumpAndSettle();
  await _tapText(tester, 'はじめる');
  await _waitFor(tester, () => find.text('お知らせ').evaluate().isNotEmpty,
      const Duration(seconds: 10));
  // 通信が始まっている。
  await _waitFor(
    tester,
    () => find.textContaining('交換中').evaluate().isNotEmpty,
    lenient ? const Duration(seconds: 120) : const Duration(seconds: 15),
    describe: '「交換中」の表示',
    failOnTimeout: !lenient,
  );
}

/// 許可ステップを抜ける。「つぎへ」が出れば押す。lenient なら代わりに「あとで 許可する」でも進む。
Future<void> _passPermissionStep(WidgetTester tester, Duration wait,
    {required bool lenient}) async {
  // 問い合わせ中（「許可を 聞いています…」）は「あとで 許可する」が無効なので、結果が出るまで待つ。
  bool busy() => find.text('許可を 聞いています…').evaluate().isNotEmpty;
  await _waitFor(
    tester,
    () =>
        find.text('つぎへ').evaluate().isNotEmpty ||
        (lenient && !busy() && find.text('あとで 許可する').evaluate().isNotEmpty),
    wait,
    describe: '許可の結果',
  );
  if (find.text('つぎへ').evaluate().isNotEmpty) {
    await _tapText(tester, 'つぎへ');
  } else {
    _log('許可されなかったので「あとで 許可する」で進みます');
    await _tapText(tester, 'あとで 許可する');
  }
}

Future<void> _hostFlow(WidgetTester tester, AppController controller,
    {required bool waitForReply}) async {
  // グループを作る。
  await _tapText(tester, 'グループ');
  await _tapText(tester, 'グループを 作る');
  await tester.enterText(find.byType(TextField).first, kHostGroupName);
  await tester.pumpAndSettle();
  await _tapText(tester, '作る');
  await _waitFor(tester, () => controller.groups.groups.isNotEmpty,
      const Duration(seconds: 10));
  final group = controller.groups.groups.first;
  expect(group.isHost, isTrue);
  expect(find.textContaining(_formatCode(group.code)), findsWidgets);
  await _tapText(tester, 'とじる');

  // お知らせを書く。
  await _tapText(tester, 'お知らせ');
  await _tapText(tester, 'お知らせを 書く');
  await _tapText(tester, '物資');
  await _enterField(tester, _placeField, kHostPlace);
  await _enterField(tester, _titleField, kHostTitle);
  await _enterField(tester, _bodyField, kHostText);
  await _tapText(tester, '送る');
  // 確認ダイアログの「送る」。
  await _tapText(tester, '送る', last: true);
  await _waitFor(tester, () => find.text('送りました').evaluate().isNotEmpty,
      const Duration(seconds: 10));
  await _tapText(tester, 'とじる');

  // 一覧に出る。
  await _waitFor(tester, () => find.text(kHostTitle).evaluate().isNotEmpty,
      const Duration(seconds: 10));
  expect(find.text('公式'), findsWidgets);
  expect(controller.notices().length, 1);

  if (!waitForReply) {
    return;
  }

  // guest からの返事を待つ。
  await _waitFor(
    tester,
    () => controller.notices().any((m) => !m.isLocal),
    kPeerWait,
    describe: 'guest からの返事',
  );
  final reply = controller.notices().firstWhere((m) => !m.isLocal);
  expect(reply.envelope.notice!.title, kGuestTitle);
  expect(reply.envelope.hop, greaterThanOrEqualTo(1));
  await _waitFor(tester, () => find.text(kGuestTitle).evaluate().isNotEmpty,
      const Duration(seconds: 10));
  await _tapText(tester, kGuestTitle);
  await _waitFor(tester,
      () => find.textContaining('この端末に 届いた時刻').evaluate().isNotEmpty,
      const Duration(seconds: 10));
  expect(find.text('住民'), findsWidgets);
}

Future<void> _guestFlow(WidgetTester tester, AppController controller) async {
  // host の group_info が近くから届くのを待つ。
  await _waitFor(
    tester,
    () => _firstGroupInfo(controller) != null,
    kPeerWait,
    describe: 'host の group_info',
  );
  final info = _firstGroupInfo(controller)!;
  final code = info.groupId;
  expect(info.envelope.groupInfo!.name, kHostGroupName);

  // 6 桁を入れて参加する。
  await _tapText(tester, 'グループ');
  await _tapText(tester, 'グループに 参加する');
  final boxes = find.descendant(
      of: find.byType(SixDigitInput), matching: find.byType(TextField));
  final digits = code.toString().padLeft(6, '0');
  for (var i = 0; i < 6; i++) {
    await tester.enterText(boxes.at(i), digits[i]);
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
  expect(find.text(kHostGroupName), findsWidgets);
  await _tapText(tester, '参加する');
  await _waitFor(tester, () => find.text('参加しました').evaluate().isNotEmpty,
      const Duration(seconds: 10));
  await _tapText(tester, 'とじる');
  expect(controller.groups.byCode(code), isNotNull);

  // host のお知らせが一覧に出る。
  await _tapText(tester, 'お知らせ');
  await _waitFor(
    tester,
    () => find.text(kHostTitle).evaluate().isNotEmpty,
    kPeerWait,
    describe: 'host のお知らせ',
  );
  await _tapText(tester, kHostTitle);
  await _waitFor(tester,
      () => find.textContaining('この端末に 届いた時刻').evaluate().isNotEmpty,
      const Duration(seconds: 10));
  expect(find.textContaining('転送'), findsWidgets);
  await _tapText(tester, 'もどる', contains: true);

  // 返事を書く。
  await _waitFor(tester, () => find.text('お知らせを 書く').evaluate().isNotEmpty,
      const Duration(seconds: 10));
  await _tapText(tester, 'お知らせを 書く');
  await _enterField(tester, _titleField, kGuestTitle);
  await _tapText(tester, '送る');
  await _tapText(tester, '送る', last: true);
  await _waitFor(tester, () => find.text('送りました').evaluate().isNotEmpty,
      const Duration(seconds: 10));
  await _tapText(tester, 'とじる');
  await _waitFor(tester, () => find.text(kGuestTitle).evaluate().isNotEmpty,
      const Duration(seconds: 10));

  // host に届くまでしばらく通信を続ける。
  await _waitFor(
    tester,
    () => controller.node.totalSessions >= 2,
    const Duration(seconds: 60),
    describe: '返事の送信セッション',
    failOnTimeout: false,
  );
  await Future<void>.delayed(const Duration(seconds: 10));
}

/// 実機デモ: グループを作り、参加コードを見せ、定期的に投稿しながら受信をログに出す。
Future<void> _demoFlow(WidgetTester tester, AppController controller) async {
  final deadline = DateTime.now().add(Duration(minutes: kDemoMinutes));
  final supportDir = await getApplicationSupportDirectory();
  final requestFile = File('${supportDir.path}/post_request.txt');

  // 前回のグループがあればそれを使い、なければ作る。
  JoinedGroup? group;
  for (final g in controller.groups.groups) {
    if (g.isHost && g.name == kHostGroupName) {
      group = g;
      break;
    }
  }
  final resumed = group != null;
  if (group == null) {
    await _tapText(tester, 'グループ');
    await _tapText(tester, 'グループを 作る');
    await tester.enterText(find.byType(TextField).first, kHostGroupName);
    await tester.pumpAndSettle();
    await _tapText(tester, '作る');
    await _waitFor(tester, () => controller.groups.groups.isNotEmpty,
        const Duration(seconds: 10));
    group = controller.groups.groups.first;
  }
  final code = _formatCode(group.code);
  _log('==========================================');
  _log(resumed
      ? 'グループ「$kHostGroupName」を 引き継ぎました'
      : 'グループ「$kHostGroupName」を 作りました');
  _log('参加コード: $code');
  _log('発信者コード: ${group.officialCode ?? '(なし)'}');
  _log('==========================================');

  final seen = <int>{};
  for (final m in controller.notices()) {
    seen.add(m.envelope.msgId);
  }

  if (!resumed) {
    // 近くの端末が見つかるまで（最大 3 分）コード画面を見せておく。
    await _waitFor(
      tester,
      () => controller.node.nearbyCount > 0,
      const Duration(minutes: 3),
      describe: '近くの端末',
      failOnTimeout: false,
    );
    _log('近くの端末: ${controller.node.nearbyCount} 台（コード画面を閉じて投稿します）');
    await _tapText(tester, 'とじる');

    // 1 件目は画面から投稿する。
    await _tapText(tester, 'お知らせ');
    await _tapText(tester, 'お知らせを 書く');
    await _tapText(tester, '物資');
    await _enterField(tester, _placeField, kHostPlace);
    await _enterField(tester, _titleField, kHostTitle);
    await _enterField(tester, _bodyField, kHostText);
    await _tapText(tester, '送る');
    await _tapText(tester, '送る', last: true);
    await _waitFor(tester, () => find.text('送りました').evaluate().isNotEmpty,
        const Duration(seconds: 10));
    await _tapText(tester, 'とじる');
    await _waitFor(tester, () => find.text(kHostTitle).evaluate().isNotEmpty,
        const Duration(seconds: 10));
    _log('投稿しました: $kHostTitle');
  } else {
    // 再開したことを知らせる 1 件をすぐ出す。
    final t = DateTime.now();
    final hhmm = '${t.hour}:${t.minute.toString().padLeft(2, '0')}';
    final title = 'お知らせ テスト $hhmm Mac を 再起動しました';
    final env = await controller.postNotice(
      groupCode: group.code,
      category: NoticeCategory.general,
      title: title,
      place: kHostPlace,
      text: '$hhmm に Mac から 送った テストです。届いたら 返事を 投稿してください。',
    );
    seen.add(env.msgId);
    _log('投稿しました: $title');
  }

  // 以後は定期的に状態を出し、5 分ごとに投稿し、届いたものを逐一ログに出す。
  // 保存先に post_request.txt（1 行目 見出し、2 行目 場所、3 行目以降 本文。見出しは
  // 「[給水] 見出し」のように種別を先頭に付けられる）を置くと、すぐに投稿して消す。
  var lastPost = DateTime.now();
  var lastStatus = DateTime.now();
  var lastSessions = controller.node.totalSessions;
  var postIndex = 0;
  const categories = <NoticeCategory>[
    NoticeCategory.water,
    NoticeCategory.food,
    NoticeCategory.medical,
    NoticeCategory.lifeline,
    NoticeCategory.general,
  ];
  // macOS はウィンドウが完全に隠れると描画が止まり、`tester.pump()` が返ってこなくなる。
  // 通信と記録は描画と無関係に進めたいので、pump は「前の pump が終わっていれば頼む」だけにする。
  Future<void>? pendingPump;
  void pumpSoft() {
    if (pendingPump != null) return;
    pendingPump = tester.pump().whenComplete(() => pendingPump = null);
  }

  while (DateTime.now().isBefore(deadline)) {
    pumpSoft();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final now = DateTime.now();

    // 手動の投稿依頼。
    if (requestFile.existsSync()) {
      try {
        final lines = requestFile.readAsLinesSync();
        requestFile.deleteSync();
        if (lines.isNotEmpty && lines.first.trim().isNotEmpty) {
          var title = lines.first.trim();
          var category = NoticeCategory.general;
          final m = RegExp(r'^\[(.+?)\]\s*(.*)$').firstMatch(title);
          if (m != null) {
            for (final c in NoticeCategory.values) {
              if (c.label == m.group(1)) {
                category = c;
                title = m.group(2)!.trim();
              }
            }
          }
          final place = lines.length > 1 ? lines[1].trim() : '';
          final text = lines.length > 2 ? lines.sublist(2).join('\n') : '';
          final env = await controller.postNotice(
            groupCode: group.code,
            category: category,
            title: title,
            place: place,
            text: text,
          );
          seen.add(env.msgId);
          lastPost = now;
          _log('投稿しました（手動）: [${category.label}] $title');
          pumpSoft();
        }
      } catch (e) {
        _log('手動の投稿に失敗: $e');
      }
    }

    // 届いたもの。
    for (final m in controller.notices()) {
      if (!seen.add(m.envelope.msgId)) continue;
      if (m.isLocal) continue;
      final n = m.envelope.notice;
      _log('★ 受信: 「${n?.title}」 from ${n?.senderName} '
          'hop=${m.envelope.hop} ${_categoryLabel(m.envelope.category)}');
    }
    // 同期セッションの増減。
    if (controller.node.totalSessions != lastSessions) {
      lastSessions = controller.node.totalSessions;
      _log('同期セッション 合計 $lastSessions 回 '
          '（受信 合計 ${controller.node.totalMessagesReceived} 件、'
          '保存 ${controller.store.all.length} 件）');
      final recent = controller.node.recentLog;
      for (final line in recent.skip(recent.length > 8 ? recent.length - 8 : 0)) {
        _log('  log: $line');
      }
    }
    // 30 秒ごとの状態。
    if (now.difference(lastStatus) >= const Duration(seconds: 30)) {
      lastStatus = now;
      final node = controller.node;
      _log('状態: 電源=${node.poweredOn} 権限=${node.permission} '
          'スキャン=${node.scanning} 広告=${node.advertising} '
          '近く=${node.nearbyCount}台 接続中=${node.activeSessions} '
          'お知らせ=${controller.notices().length}件 保存=${controller.store.all.length}件 '
          '残り=${deadline.difference(now).inMinutes}分');
    }
    // 5 分ごとに投稿。
    if (now.difference(lastPost) >= const Duration(minutes: 5)) {
      lastPost = now;
      final category = categories[postIndex % categories.length];
      postIndex++;
      final hhmm =
          '${now.hour}:${now.minute.toString().padLeft(2, '0')}';
      final title = '${_categoryLabel(category)} テスト $hhmm Mac から';
      try {
        final env = await controller.postNotice(
          groupCode: group.code,
          category: category,
          title: title,
          place: kHostPlace,
          text: '$hhmm に Mac から 送った $postIndex 件目の テストです。',
        );
        seen.add(env.msgId);
        _log('投稿しました: $title');
      } catch (e) {
        _log('投稿に失敗: $e');
      }
      pumpSoft();
    }
  }
  _log('デモを終了します（$kDemoMinutes 分）。お知らせ ${controller.notices().length} 件、'
      '同期 ${controller.node.totalSessions} 回、受信 ${controller.node.totalMessagesReceived} 件');
}

String _categoryLabel(NoticeCategory c) => c.label;

/// demo のログの書き出し先（標準出力に加えて、`open` で起動したときにも読めるようにファイルへ）。
File? _demoLogFile;

Future<void> _openDemoLog({bool append = false}) async {
  final dir = await getApplicationSupportDirectory();
  _demoLogFile = File('${dir.path}/demo_log.txt');
  await _demoLogFile!.writeAsString('',
      mode: append ? FileMode.append : FileMode.write, flush: true);
  _log('ログファイル: ${_demoLogFile!.path}');
}

/// 保存先に demo_resume.flag があれば、状態を消さずに前回のグループで再開する。
Future<bool> _demoResumeRequested() async {
  final dir = await getApplicationSupportDirectory();
  return File('${dir.path}/demo_resume.flag').exists();
}

void _log(String message) {
  final t = DateTime.now();
  final stamp = '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}';
  final line = '[demo $stamp] $message';
  // ignore: avoid_print
  print(line);
  try {
    _demoLogFile?.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  } catch (_) {
    // ログに書けなくても続ける。
  }
}

// ---------------------------------------------------------------------------
// 補助
// ---------------------------------------------------------------------------

StoredMessage? _firstGroupInfo(AppController controller) {
  for (final m in controller.store.all) {
    if (m.kind == MessageKind.groupInfo) {
      return m;
    }
  }
  return null;
}

/// 投稿画面の入力欄（ListView で遅延生成されるので、見えるまでスクロールしてから入力する）。
final Finder _placeField = find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.hintText == '例: 〇〇小学校');
final Finder _titleField = find.byWidgetPredicate((w) =>
    w is TextField &&
    (w.decoration?.helperText ?? '').contains('書きかえてください'));
final Finder _bodyField = find.byWidgetPredicate((w) =>
    w is TextField && (w.decoration?.hintText ?? '').startsWith('例: 1人'));

Future<void> _enterField(
    WidgetTester tester, Finder field, String text) async {
  await tester.scrollUntilVisible(field, 200,
      scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
  await tester.enterText(field, text);
  await tester.pumpAndSettle();
}

String _formatCode(int code) {
  final s = code.toString().padLeft(6, '0');
  return '${s.substring(0, 3)} ${s.substring(3)}';
}

Future<void> _tapText(WidgetTester tester, String text,
    {bool last = false, bool contains = false}) async {
  final finder = contains ? find.textContaining(text) : find.text(text);
  await _waitFor(tester, () => finder.evaluate().isNotEmpty,
      const Duration(seconds: 10), describe: '「$text」');
  final target = last ? finder.last : finder.first;
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target, warnIfMissed: false);
  await tester.pumpAndSettle();
}

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() condition,
  Duration timeout, {
  String? describe,
  bool failOnTimeout = true,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      if (failOnTimeout) {
        fail('${describe ?? '条件'} を ${timeout.inSeconds} 秒 待ちましたが 満たされませんでした');
      }
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

/// 前回の実行の設定・保存を消して、毎回「はじめに」から始める。
Future<void> _resetAppState() async {
  await SharedPreferencesAsync().clear();
  final legacy = await SharedPreferences.getInstance();
  await legacy.clear();
  final dir = await getApplicationSupportDirectory();
  final store = File('${dir.path}/messages.bin');
  if (await store.exists()) {
    await store.delete();
  }
}
