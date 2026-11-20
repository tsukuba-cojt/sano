import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/app/app_controller.dart';
import 'package:kairanban/core/categories.dart';
import 'package:kairanban/core/envelope.dart';
import 'package:kairanban/core/epoch.dart';
import 'package:kairanban/core/ids.dart';
import 'package:kairanban/mesh/groups.dart';
import 'package:kairanban/mesh/mesh_node.dart';
import 'package:kairanban/mesh/store_file.dart';
import 'package:kairanban/transport/fake_transport.dart';

import 'helpers.dart';

/// [FakePlatform.showNotice] に渡された内容。
class ShownNotice {
  const ShownNotice(this.id, this.title, this.body, this.groupCode);

  final int id;
  final String title;
  final String body;
  final int groupCode;
}

class FakePlatform extends NoopPlatformActions {
  int permissionCalls = 0;
  int batteryCalls = 0;
  int settingsCalls = 0;
  int notificationPermissionCalls = 0;
  bool grant = true;
  bool grantNotification = true;
  final List<ShownNotice> shown = <ShownNotice>[];

  @override
  Future<bool> requestPermissions() async {
    permissionCalls++;
    return grant;
  }

  @override
  Future<bool> requestBatteryOptimizationExemption() async {
    batteryCalls++;
    return true;
  }

  @override
  Future<void> openAppSettings() async {
    settingsCalls++;
  }

  @override
  Future<bool> requestNotificationPermission() async {
    notificationPermissionCalls++;
    if (grantNotification) {
      notificationsOn = true;
    }
    return grantNotification;
  }

  /// OS の通知の許可（[requestNotificationPermission] で許可されると true になる）。
  bool notificationsOn = true;

  @override
  Future<bool> notificationsAllowed() async => notificationsOn;

  @override
  Future<void> showNotice({
    required int id,
    required String title,
    required String body,
    required int groupCode,
    NoticeImportance importance = NoticeImportance.important,
    int? msgId,
  }) async {
    shown.add(ShownNotice(id, title, body, groupCode));
  }
}

void main() {
  late FakeRadio radio;
  final controllers = <AppController>[];

  setUp(() {
    radio = FakeRadio(clock: FakeClock(startEpochSeconds: kT0));
    controllers.clear();
  });

  tearDown(() {
    for (final c in controllers) {
      c.dispose();
    }
  });

  AppController make(
    String id, {
    int? index,
    MemoryKeyValueStore? kv,
    MemoryStoreBackend? backend,
    FakePlatform? platform,
    Future<void> Function(DateTime at)? onReceived,
  }) {
    final c = AppController(
      transport: radio.createTransport(id),
      storeBackend: backend ?? MemoryStoreBackend(),
      kv: kv ?? MemoryKeyValueStore(),
      platform: platform,
      now: radio.clock.now,
      createTimer: radio.clock.createTimer,
      nodeId: index != null ? nodeIdOf(index) : null,
      onReceived: onReceived,
    );
    controllers.add(c);
    return c;
  }

  test('init: ノード ID を生成して永続化し、2 回目は同じ ID を使う', () async {
    final kv = MemoryKeyValueStore();
    final a = make('A', kv: kv);
    expect(() => a.nodeId, throwsStateError);
    expect(() => a.node, throwsStateError);
    await a.init();
    expect(a.isInitialized, isTrue);
    expect(a.nodeId.length, 8);
    expect(kv.snapshot[AppController.nodeIdKey], hexOf(a.nodeId));
    expect(a.settings.meshEnabled, isFalse);
    expect(a.settings.displayName, '');
    expect(a.node.running, isFalse);
    expect(a.now, kT0);

    final b = make('B', kv: kv);
    await b.init();
    expect(b.nodeId, a.nodeId);
    await b.init(); // 二重 init は無害
  });

  test('設定は永続化され、meshEnabled なら起動時に通信を自動再開する', () async {
    final kv = MemoryKeyValueStore();
    final a = make('A', kv: kv, index: 1);
    await a.init();
    var notified = 0;
    a.addListener(() => notified++);
    final s = a.settings.copy()
      ..displayName = '防災課'
      ..textScale = 1.25
      ..lowPowerPreferred = true
      ..onboardingDone = true;
    await a.saveSettings(s);
    expect(notified, 1);
    expect(a.settings.displayName, '防災課');
    expect(jsonDecode(kv.snapshot[AppController.settingsKey]!)['textScale'], 1.25);
    expect(kv.snapshot[AppController.meshEnabledKey], 'false');

    await a.startMesh();
    await radio.settle();
    expect(a.node.running, isTrue);
    expect(a.settings.meshEnabled, isTrue);
    expect(kv.snapshot[AppController.meshEnabledKey], 'true');
    final transportA = radio.transports['A']!;
    expect(transportA.lowPower, isTrue);

    // 省電力の切替は動作中のノードに反映される。
    await a.saveSettings(a.settings.copy()..lowPowerPreferred = false);
    expect(transportA.lowPower, isFalse);

    await a.stopMesh();
    await radio.settle();
    expect(a.node.running, isFalse);
    expect(a.settings.meshEnabled, isFalse);
    await a.startMesh();
    await radio.settle();

    final b = make('B', kv: kv, index: 1);
    await b.init();
    await radio.settle();
    expect(b.settings.displayName, '防災課');
    expect(b.settings.textScale, 1.25);
    expect(b.settings.onboardingDone, isTrue);
    expect(b.settings.meshEnabled, isTrue);
    expect(b.node.running, isTrue);
  });

  test('createGroup はホストとして登録し group_info を発信する', () async {
    final a = make('A', index: 1);
    await a.init();
    await a.saveSettings(a.settings.copy()..displayName = '〇〇市 防災課');
    final g = await a.createGroup(name: '〇〇市 防災', membersCanPost: false);
    expect(g.isHost, isTrue);
    expect(g.hostName, '〇〇市 防災課');
    expect(a.groups.codes, {g.code});
    expect(a.store.joinedGroupIds, {g.code});
    expect(a.store.count, 1);
    final info = a.store.latestGroupInfo(g.code)!;
    expect(info.isLocal, isTrue);
    expect(info.envelope.role, SenderRole.official);
    expect(info.envelope.createdAt, kT0);
    expect(info.envelope.expiresAt, kT0 + 365 * 24 * 3600);
    final body = info.envelope.groupInfo!;
    expect(body.name, '〇〇市 防災');
    expect(body.hostName, '〇〇市 防災課');
    expect(body.membersCanPost, isFalse);
    expect(a.notices(), isEmpty);

    await radio.elapse(const Duration(seconds: 1));
    await a.republishGroupInfo(g.code);
    expect(a.store.count, 2);
    expect(a.store.latestGroupInfo(g.code)!.envelope.createdAt, kT0 + 1);

    await expectLater(() => a.createGroup(name: '  ', membersCanPost: true),
        throwsArgumentError);
    await expectLater(() => a.republishGroupInfo(999999), throwsStateError);
  });

  test('postNotice: 発信元名・役割・既定 TTL、投稿不可のときはエラー', () async {
    final a = make('A', index: 1);
    await a.init();
    final g = await a.createGroup(name: 'G', membersCanPost: true);
    // 公式（ホスト）の発信元名はグループ名（C09）。
    final e1 = await a.postNotice(
      groupCode: g.code,
      category: NoticeCategory.supply,
      title: ' 〇〇小学校に 水が とどきました ',
      place: '〇〇小学校',
      text: '一人 2 本まで です。',
    );
    expect(e1.kind, MessageKind.notice);
    expect(e1.groupId, g.code);
    expect(e1.role, SenderRole.official);
    expect(e1.category, NoticeCategory.supply);
    expect(e1.createdAt, kT0);
    expect(e1.expiresAt, kT0 + 12 * 3600);
    expect(e1.notice!.senderName, 'G');
    expect(e1.notice!.title, '〇〇小学校に 水が とどきました');
    expect(e1.notice!.place, '〇〇小学校');
    expect(e1.notice!.text, '一人 2 本まで です。');
    final stored = a.store.get(e1.msgId)!;
    expect(stored.isLocal, isTrue);
    expect(stored.read, isTrue);
    expect(a.notices().map((m) => m.msgId), [e1.msgId]);
    expect(a.notices(groupCode: g.code).length, 1);
    expect(a.notices(groupCode: 111111), isEmpty);
    expect(a.unreadCount, 0);

    await a.saveSettings(a.settings.copy()..displayName = '山田');
    await radio.elapse(const Duration(seconds: 1));
    final e2 = await a.postNotice(
      groupCode: g.code,
      category: NoticeCategory.warning,
      title: '余震に 注意してください',
      ttl: const Duration(days: 7),
    );
    expect(e2.expiresAt, kT0 + 1 + 7 * 24 * 3600);
    // ホストの投稿は表示名を変えてもグループごとの発信元名で出る。
    expect(e2.notice!.senderName, 'G');
    expect(a.notices().first.msgId, e2.msgId);

    // 参加者として投稿できないグループ。
    final joined = await a.joinGroup(222222);
    await a.groups.updatePolicy(222222, membersCanPost: false);
    expect(joined.canPost, isFalse);
    await expectLater(
      () => a.postNotice(
          groupCode: 222222, category: NoticeCategory.general, title: 't'),
      throwsStateError,
    );
    await expectLater(
      () => a.postNotice(
          groupCode: 333333, category: NoticeCategory.general, title: 't'),
      throwsStateError,
    );
    await expectLater(
      () => a.postNotice(
          groupCode: g.code, category: NoticeCategory.general, title: '  '),
      throwsArgumentError,
    );

    // 参加者（投稿可）は住民として、表示名で投稿する。
    await a.groups.updatePolicy(222222, membersCanPost: true);
    final e3 = await a.postNotice(
        groupCode: 222222, category: NoticeCategory.general, title: '住民の投稿');
    expect(e3.role, SenderRole.resident);
    expect(e3.notice!.senderName, '山田');
    // 本部コードは group_info のダイジェストが届くまで保留、スタッフコードは受理。
    expect(await a.elevate(222222, '12345678'), ElevateResult.notReady);
    expect(await a.elevate(222222, '23456789'), ElevateResult.staff);
    final e4 = await a.postNotice(
        groupCode: 222222, category: NoticeCategory.general, title: '昇格後');
    expect(e4.role, SenderRole.staff);
    expect(e4.notice!.senderName, '山田');
    await a.setGroupSenderName(222222, '〇〇小学校 受付');
    final e5 = await a.postNotice(
        groupCode: 222222, category: NoticeCategory.general, title: '発信元名');
    expect(e5.notice!.senderName, '〇〇小学校 受付');
  });

  test('retract は tombstone を発信し、一覧から消える', () async {
    final a = make('A', index: 1);
    await a.init();
    final g = await a.createGroup(name: 'G', membersCanPost: true);
    final e = await a.postNotice(
        groupCode: g.code, category: NoticeCategory.supply, title: 't');
    await radio.elapse(const Duration(seconds: 30));
    await a.retract(e.msgId);
    expect(a.notices(), isEmpty);
    expect(a.store.get(e.msgId)!.retracted, isTrue);
    final ts = a.store.all.firstWhere((m) => m.kind == MessageKind.tombstone);
    expect(ts.envelope.supersedes, e.msgId);
    expect(ts.envelope.groupId, g.code);
    expect(ts.envelope.createdAt, kT0 + 30);
    expect(ts.envelope.expiresAt, e.expiresAt + 24 * 3600);
    expect(ts.isLocal, isTrue);

    // 公式端末は同じグループの他人のお知らせを取り消せる（C10）。本文は公式端末に残る。
    final foreign = makeNotice(origin: nodeIdOf(9), createdAt: kT0, groupId: g.code);
    await a.store.add(foreign, now: kT0 + 30);
    expect(a.canRetract(a.store.get(foreign.msgId)!), isTrue);
    await a.retract(foreign.msgId);
    final retracted = a.store.get(foreign.msgId)!;
    expect(retracted.retracted, isTrue);
    expect(retracted.retractedByOfficial, isTrue);
    expect(retracted.isStub, isFalse);
    final officialTs = a.store.all.firstWhere(
        (m) => m.kind == MessageKind.tombstone && m.envelope.supersedes == foreign.msgId);
    expect(officialTs.envelope.role, SenderRole.official);

    // 参加者としての端末では他人のお知らせは取り消せない。
    await a.joinGroup(222222);
    final other = makeNotice(origin: nodeIdOf(9), createdAt: kT0 + 1, groupId: 222222);
    await a.store.add(other, now: kT0 + 30);
    expect(a.canRetract(a.store.get(other.msgId)!), isFalse);
    await expectLater(() => a.retract(other.msgId), throwsStateError);
    await expectLater(() => a.retract(424242), throwsStateError);
  });

  test('すれ違いで届いた group_info からグループ名が補完され、お知らせが見える',
      () async {
    final a = make('A', index: 1);
    final b = make('B', index: 2);
    await a.init();
    await b.init();
    await a.saveSettings(a.settings.copy()..displayName = '防災課');
    await a.startMesh();
    await b.startMesh();
    await radio.settle();
    final g = await a.createGroup(name: '〇〇市 防災', membersCanPost: false);
    await a.postNotice(
        groupCode: g.code, category: NoticeCategory.water, title: '給水します');

    // B は先に（名前の分からないまま）参加しておく。
    final joined = await b.joinGroup(g.code);
    expect(joined.name, '');
    expect(b.notices(), isEmpty);

    var notified = 0;
    b.addListener(() => notified++);
    radio.discover('B', 'A');
    await radio.settle();
    expect(b.store.count, 2);
    expect(notified, greaterThan(0));
    expect(b.groups.byCode(g.code)!.name, '〇〇市 防災');
    expect(b.groups.byCode(g.code)!.membersCanPost, isFalse);
    expect(b.groups.byCode(g.code)!.canPost, isFalse);
    final visible = b.notices();
    expect(visible.length, 1);
    expect(visible.single.envelope.notice!.senderName, '〇〇市 防災');
    expect(visible.single.envelope.hop, 1);
    expect(b.unreadCount, 1);
    await b.markRead(visible.single.msgId);
    expect(b.unreadCount, 0);

    // 後から参加する端末は参加時点で名前が補完される。
    final c = make('C', index: 3);
    await c.init();
    await c.startMesh();
    await radio.settle();
    radio.discover('C', 'B');
    await radio.settle();
    expect(c.store.count, 2);
    expect(c.notices(), isEmpty); // 未参加なので表示されない（中継はする）
    final cg = await c.joinGroup(g.code);
    expect(cg.name, '〇〇市 防災');
    expect(cg.membersCanPost, isFalse);
    expect(c.notices().length, 1);
    expect(c.unreadCount, 1);

    await c.leaveGroup(g.code);
    expect(c.notices(), isEmpty);
    expect(c.store.joinedGroupIds, isEmpty);
    expect(c.store.count, 2);
  });

  test('期限切れは 1 分ごとの掃除で消える', () async {
    final a = make('A', index: 1);
    await a.init();
    final g = await a.createGroup(name: 'G', membersCanPost: true);
    await a.postNotice(
        groupCode: g.code,
        category: NoticeCategory.general,
        title: 'すぐ切れる',
        ttl: const Duration(seconds: 30));
    expect(a.store.count, 2);
    await radio.elapse(const Duration(seconds: 59));
    expect(a.store.count, 2);
    expect(a.notices(), isEmpty); // 表示は now で判定される
    await radio.elapse(const Duration(seconds: 2));
    expect(a.store.count, 1);
    // 以後も繰り返し動く。
    await a.postNotice(
        groupCode: g.code,
        category: NoticeCategory.general,
        title: '次',
        ttl: const Duration(seconds: 10));
    await radio.elapse(const Duration(minutes: 1));
    expect(a.store.count, 1);
  });

  test('通知が許可されていなければホームで知らせ、許可されたら消える', () async {
    final platform = FakePlatform()
      ..notificationsOn = false
      ..grantNotification = false;
    final a = make('A', index: 1, platform: platform);
    await a.init();
    await Future<void>.delayed(Duration.zero);
    expect(a.notificationsBlocked, isTrue);

    // 一度断られていれば、OS の設定画面を開く。
    await a.allowNotifications();
    expect(platform.notificationPermissionCalls, 1);
    expect(platform.settingsCalls, 1);
    expect(a.notificationsBlocked, isTrue);

    // 設定で許可して戻ってくると消える。
    a.setForeground(false);
    platform.notificationsOn = true;
    a.setForeground(true);
    await Future<void>.delayed(Duration.zero);
    expect(a.notificationsBlocked, isFalse);

    // 通知を出さない設定なら、許可がなくても知らせない。
    platform.notificationsOn = false;
    await a.refreshNotificationPermission();
    expect(a.notificationsBlocked, isTrue);
    await a.saveSettings(
      a.settings.copy()..notificationLevel = NotificationLevel.off,
    );
    expect(a.notificationsBlocked, isFalse);
  });

  test('まだ聞いていなければ、ホームの帯から OS が許可を聞く', () async {
    final platform = FakePlatform()..notificationsOn = false;
    final a = make('A', index: 1, platform: platform);
    await a.init();
    await Future<void>.delayed(Duration.zero);
    expect(a.notificationsBlocked, isTrue);
    await a.allowNotifications();
    expect(platform.settingsCalls, 0);
    expect(a.notificationsBlocked, isFalse);
  });

  test('OS 操作は PlatformActions に委譲され、なければ既定値', () async {
    final platform = FakePlatform();
    final a = make('A', index: 1, platform: platform);
    await a.init();
    expect(await a.requestPermissions(), isTrue);
    platform.grant = false;
    expect(await a.requestPermissions(), isFalse);
    expect(await a.requestBatteryExemption(), isTrue);
    await a.openAppSettings();
    expect(await a.requestNotificationPermission(), isTrue);
    platform.grantNotification = false;
    expect(await a.requestNotificationPermission(), isFalse);
    expect(platform.permissionCalls, 2);
    expect(platform.batteryCalls, 1);
    expect(platform.settingsCalls, 1);
    expect(platform.notificationPermissionCalls, 2);

    final b = make('B', index: 2);
    await b.init();
    expect(await b.requestPermissions(), isTrue);
    expect(await b.requestBatteryExemption(), isTrue);
    expect(await b.requestNotificationPermission(), isTrue);
    await b.openAppSettings();
  });

  // ---------------------------------------------------------------------------
  // 新しいお知らせの OS 通知
  // ---------------------------------------------------------------------------

  test('非ローカルの notice が store に入ると、5 秒後に showNotice が 1 回呼ばれる',
      () async {
    final platform = FakePlatform();
    final b = make('B', index: 2, platform: platform);
    await b.init();
    await b.joinGroup(kGroupA);
    // 住民の「お知らせ」は「ぜんぶ 知らせる」のときだけ通知する（C05）。
    await b.saveSettings(b.settings.copy()..notificationLevel = NotificationLevel.all);
    // 前面かどうかを知らされるまでは背面扱い。
    expect(b.inForeground, isFalse);

    final e = makeNotice(
      origin: nodeIdOf(1),
      createdAt: kT0,
      title: '第一小学校に 水が とどきました',
      senderName: '防災課',
    );
    await b.store.add(e, now: kT0);
    // すぐには出さない（続けて届く分をまとめる）。
    expect(platform.shown, isEmpty);
    await radio.elapse(const Duration(seconds: 4));
    expect(platform.shown, isEmpty);
    await radio.elapse(const Duration(seconds: 2));
    expect(platform.shown.length, 1);
    final n = platform.shown.single;
    expect(n.id, e.msgId & 0x7FFFFFFF);
    expect(n.title, '第一小学校に 水が とどきました');
    expect(n.body, '場所: 〇〇小学校');
    expect(n.groupCode, kGroupA);

    // 既読化などストアの変化では再通知しない。
    await b.markRead(e.msgId);
    await radio.elapse(const Duration(seconds: 10));
    expect(platform.shown.length, 1);
  });

  test('すれ違いで届いたお知らせも通知される（group_info だけでは通知しない）', () async {
    final platform = FakePlatform();
    final a = make('A', index: 1);
    final b = make('B', index: 2, platform: platform);
    await a.init();
    await b.init();
    await a.saveSettings(a.settings.copy()..displayName = '防災課');
    await a.startMesh();
    await b.startMesh();
    await radio.settle();
    final g = await a.createGroup(name: '〇〇市 防災', membersCanPost: false);
    await b.joinGroup(g.code);

    // group_info だけが届く。
    radio.discover('B', 'A');
    await radio.settle();
    expect(b.store.count, 1);
    await radio.elapse(const Duration(seconds: 10));
    expect(platform.shown, isEmpty);

    // お知らせが届く。
    await radio.elapse(const Duration(minutes: 2));
    await a.postNotice(
      groupCode: g.code,
      category: NoticeCategory.water,
      title: '給水します',
    );
    // B は直前に A と同期し直しているので、次の同期（60 秒間隔）で受け取る。
    radio.discover('B', 'A');
    await radio.elapse(
      const Duration(seconds: kResyncIntervalSeconds + kMeshTickSeconds),
    );
    expect(b.store.count, 2);
    expect(platform.shown.length, 1);
    expect(platform.shown.single.title, '給水します');
    // 公式の発信元名はグループ名（C09）。場所も本文もないので「〜 から」。
    expect(platform.shown.single.body, '〇〇市 防災 から');
    expect(platform.shown.single.groupCode, g.code);
  });

  test('続けて届いたお知らせは「N 件」の 1 通知にまとまり、同じ通知 ID を更新する', () async {
    final platform = FakePlatform();
    final b = make('B', index: 2, platform: platform);
    await b.init();
    await b.joinGroup(kGroupA);
    await b.saveSettings(b.settings.copy()..notificationLevel = NotificationLevel.all);
    final e1 = makeNotice(origin: nodeIdOf(1), createdAt: kT0, title: '1 件目');
    final e2 = makeNotice(origin: nodeIdOf(1), createdAt: kT0 + 1, title: '2 件目');
    await b.store.add(e1, now: b.now);
    await radio.elapse(const Duration(seconds: 3));
    await b.store.add(e2, now: b.now);
    await radio.elapse(const Duration(seconds: 3));
    // 2 件目が届いたので待ち直す。
    expect(platform.shown, isEmpty);
    await radio.elapse(const Duration(seconds: 3));
    expect(platform.shown.length, 1);
    expect(platform.shown.single.title, '新しい お知らせが 2件 あります');
    expect(platform.shown.single.body, '2 件目 ほか');
    expect(platform.shown.single.id, e1.msgId & 0x7FFFFFFF);

    // さらに届けば、同じ ID で「3 件」に更新する。
    final e3 = makeNotice(origin: nodeIdOf(1), createdAt: kT0 + 2, title: '3 件目');
    await b.store.add(e3, now: b.now);
    await radio.elapse(const Duration(seconds: 5));
    expect(platform.shown.length, 2);
    expect(platform.shown.last.title, '新しい お知らせが 3件 あります');
    expect(platform.shown.last.body, '3 件目 ほか');
    expect(platform.shown.last.id, e1.msgId & 0x7FFFFFFF);

    // 前面に戻ると、まとめ待ちは捨てられ、次の新着は新しい ID で始まる。
    final e4 = makeNotice(origin: nodeIdOf(1), createdAt: kT0 + 3, title: '4 件目');
    await b.store.add(e4, now: b.now);
    b.setForeground(true);
    await radio.elapse(const Duration(seconds: 10));
    expect(platform.shown.length, 2);
    b.setForeground(false);
    final e5 = makeNotice(origin: nodeIdOf(1), createdAt: kT0 + 4, title: '5 件目');
    await b.store.add(e5, now: b.now);
    await radio.elapse(const Duration(seconds: 5));
    expect(platform.shown.length, 3);
    expect(platform.shown.last.title, '5 件目');
    expect(platform.shown.last.id, e5.msgId & 0x7FFFFFFF);
  });

  test('前面のときは showNotice を呼ばない（画面の未読表示に任せる）', () async {
    final platform = FakePlatform();
    final b = make('B', index: 2, platform: platform);
    await b.init();
    await b.joinGroup(kGroupA);
    b.setForeground(true);
    expect(b.inForeground, isTrue);
    await b.store.add(makeNotice(origin: nodeIdOf(1), createdAt: kT0), now: kT0);
    await radio.elapse(const Duration(seconds: 10));
    expect(platform.shown, isEmpty);
    expect(b.unreadCount, 1);
    // 背面に回ったあとも、前面で届いたものは通知しない。
    b.setForeground(false);
    await radio.elapse(const Duration(seconds: 10));
    expect(platform.shown, isEmpty);
  });

  test('自分の投稿では showNotice を呼ばない', () async {
    final platform = FakePlatform();
    final a = make('A', index: 1, platform: platform);
    await a.init();
    final g = await a.createGroup(name: 'G', membersCanPost: true);
    await a.postNotice(
        groupCode: g.code, category: NoticeCategory.water, title: '給水します');
    await radio.elapse(const Duration(seconds: 10));
    expect(platform.shown, isEmpty);
    expect(a.notices().single.isLocal, isTrue);
  });

  test('通知オフでは showNotice を呼ばない。オンに戻しても過去の分は通知しない', () async {
    final platform = FakePlatform();
    final b = make('B', index: 2, platform: platform);
    await b.init();
    expect(b.settings.notificationsEnabled, isTrue);
    expect(b.settings.notificationLevel, NotificationLevel.important);
    await b.joinGroup(kGroupA);
    await b.saveSettings(b.settings.copy()..notificationsEnabled = false);
    expect(b.settings.notificationLevel, NotificationLevel.off);
    await b.store.add(makeNotice(origin: nodeIdOf(1), createdAt: kT0), now: kT0);
    await radio.elapse(const Duration(seconds: 10));
    expect(platform.shown, isEmpty);
    expect(b.unreadCount, 1);

    await b.saveSettings(b.settings.copy()..notificationLevel = NotificationLevel.all);
    await radio.elapse(const Duration(seconds: 10));
    expect(platform.shown, isEmpty);

    // 以後に届いたものは通知する。
    await b.store.add(
        makeNotice(origin: nodeIdOf(1), createdAt: kT0 + 1), now: b.now);
    await radio.elapse(const Duration(seconds: 5));
    expect(platform.shown.length, 1);

    // まとめ待ちの途中でオフにすると出さない。
    await b.store.add(
        makeNotice(origin: nodeIdOf(1), createdAt: kT0 + 2), now: b.now);
    await radio.elapse(const Duration(seconds: 2));
    await b.saveSettings(b.settings.copy()..notificationsEnabled = false);
    await radio.elapse(const Duration(seconds: 10));
    expect(platform.shown.length, 1);
  });

  test('起動時に保存されていた未読と、未参加グループのお知らせは通知しない', () async {
    final backend = MemoryStoreBackend();
    final kv = MemoryKeyValueStore();
    final a = make('A', index: 2, kv: kv, backend: backend);
    await a.init();
    await a.joinGroup(kGroupA);
    a.setForeground(true);
    await a.store.add(makeNotice(origin: nodeIdOf(1), createdAt: kT0), now: kT0);
    a.dispose();
    controllers.remove(a);

    final platform = FakePlatform();
    final b = make('B', index: 2, kv: kv, backend: backend, platform: platform);
    await b.init();
    expect(b.unreadCount, 1);
    await radio.elapse(const Duration(seconds: 10));
    expect(platform.shown, isEmpty);

    // 未参加グループ（中継だけ）のお知らせは通知しない。
    await b.store.add(
        makeNotice(origin: nodeIdOf(1), createdAt: kT0 + 1, groupId: kGroupB),
        now: b.now);
    await radio.elapse(const Duration(seconds: 10));
    expect(platform.shown, isEmpty);

    // あとから参加しても（前面での操作）通知にはならない。
    b.setForeground(true);
    await b.joinGroup(kGroupB);
    expect(b.unreadCount, 2);
    b.setForeground(false);
    await radio.elapse(const Duration(seconds: 10));
    expect(platform.shown, isEmpty);
  });

  test('お知らせを受け取ると onReceived に受信時刻が知らされる（同じ受信は 1 回だけ）',
      () async {
    final received = <DateTime>[];
    final a = make('A', index: 1);
    final b = make(
      'B',
      index: 2,
      onReceived: (at) async => received.add(at),
    );
    await a.init();
    await b.init();
    await a.startMesh();
    await b.startMesh();
    await radio.settle();
    // 何も受け取っていないうちは呼ばれない。
    expect(received, isEmpty);

    final g = await a.createGroup(name: 'G', membersCanPost: true);
    await a.postNotice(
        groupCode: g.code, category: NoticeCategory.water, title: '給水します');
    radio.discover('B', 'A');
    await radio.settle();
    expect(b.store.count, 2);
    expect(received.length, 1);
    expect(received.single, dateTimeFromEpoch(b.node.lastReceivedAt!));

    // 受信のない状態変化（設定の保存など）では再通知しない。
    await b.saveSettings(b.settings.copy()..displayName = 'B');
    await radio.elapse(const Duration(seconds: 5));
    expect(received.length, 1);

    // 新しいお知らせを受け取れば、また知らされる。
    await radio.elapse(const Duration(minutes: 2));
    await a.postNotice(
        groupCode: g.code, category: NoticeCategory.food, title: '炊き出し');
    radio.discover('B', 'A');
    await radio.elapse(
      const Duration(seconds: kResyncIntervalSeconds + kMeshTickSeconds),
    );
    expect(b.store.count, 3);
    expect(received.length, 2);
    expect(received.last.isAfter(received.first), isTrue);
  });

  test('壊れた設定 JSON でも既定値で起動する', () async {
    final kv = MemoryKeyValueStore();
    await kv.setString(AppController.settingsKey, '{broken');
    await kv.setString(AppController.nodeIdKey, 'zz');
    final a = make('A', kv: kv);
    await a.init();
    expect(a.settings.textScale, 1.0);
    expect(a.nodeId.length, 8);
    expect(kv.snapshot[AppController.nodeIdKey], hexOf(a.nodeId));
  });

  test('保存済みのメッセージは init で読み込まれ、参加グループに応じて表示される',
      () async {
    final backend = MemoryStoreBackend();
    final kv = MemoryKeyValueStore();
    final a = make('A', index: 1, kv: kv, backend: backend);
    await a.init();
    final g = await a.createGroup(name: 'G', membersCanPost: true);
    await a.postNotice(
        groupCode: g.code, category: NoticeCategory.general, title: 'x');
    a.dispose();
    controllers.remove(a);

    final b = make('B', index: 1, kv: kv, backend: backend);
    await b.init();
    expect(b.store.count, 2);
    expect(b.groups.byCode(g.code)!.isHost, isTrue);
    expect(b.notices().length, 1);
    expect(b.notices().single.isLocal, isTrue);
  });
}
