/// 実機テスト用のデータ（開発者メニュー、#152）と、交換ごとの量・秒数の記録。
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/app/app_controller.dart';
import 'package:kairanban/app/test_data.dart';
import 'package:kairanban/core/categories.dart';
import 'package:kairanban/core/envelope.dart';
import 'package:kairanban/core/report.dart';
import 'package:kairanban/mesh/groups.dart';
import 'package:kairanban/mesh/message_store.dart';
import 'package:kairanban/mesh/store_file.dart';
import 'package:kairanban/transport/fake_transport.dart';

import 'helpers.dart';

class _CountingPlatform extends NoopPlatformActions {
  int shown = 0;

  @override
  Future<void> showNotice({
    required int id,
    required String title,
    required String body,
    required int groupCode,
    NoticeImportance importance = NoticeImportance.important,
    int? msgId,
  }) async {
    shown++;
  }
}

void main() {
  group('テスト用データの生成', () {
    test('お知らせは見出しに【試験】が付き、種別が混ざり、ストアに入る', () async {
      final envs = makeTestNotices(
        count: 30,
        groupId: kGroupA,
        now: kT0,
        random: Random(1),
      );
      expect(envs.length, 30);
      expect(envs.map((e) => e.msgId).toSet().length, 30);
      expect(envs.every(isTestEnvelope), isTrue);
      expect(envs.map((e) => e.category).toSet().length, greaterThan(10));
      for (final e in envs) {
        expect(e.notice!.text.length, lessThanOrEqualTo(300));
        expect(e.role, isNot(SenderRole.resident));
        expect(e.createdAt, inInclusiveRange(kT0 - 7200, kT0));
      }
      final store = MessageStore(MemoryStoreBackend());
      await store.load();
      expect(await store.addAll(envs, now: kT0), 30);
    });

    test('ばらばらの文字の本文は 40〜100 文字で、普段の文より大きい', () {
      final noise = makeTestNotices(
        count: 50,
        groupId: kGroupA,
        now: kT0,
        random: Random(2),
        body: TestBody.noise,
      );
      for (final e in noise) {
        expect(e.notice!.text.runes.length, inInclusiveRange(40, 100));
        // 圧縮がほとんど効かない（UTF-8 の 7 割以上が残る）。
        final raw = utf8.encode(e.notice!.text).length;
        expect(e.bodyPlain.length, greaterThan(raw * 0.7));
      }
    });

    test('住民からの知らせは本文の先頭に【試験】が付き、種類が読める', () {
      final envs = makeTestReports(
        count: 20,
        groupId: kGroupA,
        now: kT0,
        random: Random(3),
        type: ReportType.sos,
      );
      expect(envs.every(isTestEnvelope), isTrue);
      expect(envs.map((e) => e.msgId).toSet().length, 20);
      for (final e in envs) {
        expect(e.kind, MessageKind.help);
        expect(ReportInfo.decode(e.help!.ext!)!.type, ReportType.sos);
      }
    });

    test('ふつうのお知らせはテスト用データと見なさない', () {
      final e = makeNotice(origin: nodeIdOf(1), createdAt: kT0);
      expect(isTestEnvelope(e), isFalse);
    });
  });

  group('ストアのまとめ入れと片付け', () {
    test('addAll は上限を守り、removeWhere は当てはまるものだけ消す', () async {
      final backend = MemoryStoreBackend();
      final store = MessageStore(backend, maxMessages: 100);
      await store.load();
      final mine = makeNotice(origin: nodeIdOf(1), createdAt: kT0);
      await store.add(mine, now: kT0, isLocal: true);
      var notified = 0;
      store.addListener(() => notified++);
      final added = await store.addAll(
        makeTestNotices(count: 150, groupId: kGroupA, now: kT0, random: Random(4)),
        now: kT0,
      );
      expect(added, 150);
      expect(notified, 1);
      // 上限に達すると少し余裕を持たせて古いものから消す。
      expect(store.count, inInclusiveRange(90, 100));
      expect(store.contains(mine.msgId), isTrue); // 自分の投稿は消えない

      final before = store.count;
      final removed =
          await store.removeWhere((m) => isTestEnvelope(m.envelope));
      expect(removed, before - 1);
      expect(store.count, 1);

      // 保存し直しても消えたまま。
      final reloaded = MessageStore(backend, maxMessages: 100);
      await reloaded.load();
      expect(reloaded.count, 1);
      expect(reloaded.contains(mine.msgId), isTrue);
    });
  });

  test('まとめて保存すると、ファイルへの書き込みは 1 回で済む', () async {
    final backend = MemoryStoreBackend();
    final store = MessageStore(backend);
    await store.load();
    await store.addAll(
      makeTestNotices(count: 300, groupId: kGroupA, now: kT0, random: Random(6)),
      now: kT0,
    );
    expect(backend.appendCount, 1);
    expect((await backend.readAll()).length, 300);
    final reloaded = MessageStore(backend);
    await reloaded.load();
    expect(reloaded.count, 300);
  });

  test('受け取った 300 件をすべて保存し、交換の記録に件数が残る', () async {
    final radio = FakeRadio(clock: FakeClock(startEpochSeconds: kT0));
    final a = TestNode(radio, 'A', index: 1);
    final b = TestNode(radio, 'B', index: 2);
    await a.start();
    await b.start();
    await a.store.addAll(
      makeTestNotices(count: 300, groupId: kGroupA, now: kT0, random: Random(5)),
      now: kT0,
    );
    radio.discover('B', 'A');
    await radio.settle();
    await radio.elapse(const Duration(seconds: 5));
    expect(b.store.count, 300);
    final stat = b.node.recentSessions.lastWhere((s) => s.messagesReceived > 0);
    expect(stat.messagesReceived, 300);
    await a.dispose();
    await b.dispose();
  });

  group('開発者メニューの操作', () {
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

    Future<AppController> make(String id, int index,
        {_CountingPlatform? platform}) async {
      final c = AppController(
        transport: radio.createTransport(id),
        storeBackend: MemoryStoreBackend(),
        kv: MemoryKeyValueStore(),
        platform: platform,
        now: radio.clock.now,
        createTimer: radio.clock.createTimer,
        nodeId: nodeIdOf(index),
      );
      controllers.add(c);
      await c.init();
      await c.startMesh();
      return c;
    }

    test('入れたデータは既読で、別の端末に渡り、通知は出ず、交換の量と秒数が残る', () async {
      final bPlatform = _CountingPlatform();
      final a = await make('A', 1);
      final b = await make('B', 2, platform: bPlatform);
      await b.saveSettings(
        b.settings.copy()..notificationLevel = NotificationLevel.all,
      );
      final g = await a.createGroup(name: '試験', membersCanPost: true);
      await b.joinGroup(g.code);

      expect(a.settings.developerMode, isFalse);
      await a.setDeveloperMode(true);
      expect(a.settings.developerMode, isTrue);

      expect(await a.addTestNotices(groupCode: g.code, count: 30), 30);
      expect(await a.addTestReports(groupCode: g.code, count: 5), 5);
      expect(a.testDataCount, 35);
      expect(a.store.unreadCount(now: radio.clock.now()), 0);

      radio.discover('B', 'A');
      await radio.settle();
      await radio.elapse(const Duration(seconds: 5));
      expect(b.testDataCount, 35);
      await radio.elapse(const Duration(seconds: 10));
      expect(bPlatform.shown, 0);

      final stats = b.node.recentSessions.where((s) => s.succeeded).toList();
      expect(stats, isNotEmpty);
      final received = stats.fold<int>(0, (n, s) => n + s.messagesReceived);
      expect(received, greaterThanOrEqualTo(35));
      final big = stats.firstWhere((s) => s.messagesReceived > 0);
      expect(big.bytesReceived, greaterThan(0));
      expect(big.firstMessageAfter, isNotNull);
      expect(big.peerNodeHex, isNotNull);

      expect(await b.removeTestData(), 35);
      expect(b.testDataCount, 0);
      expect(a.testDataCount, 35);
    });

    test('上限まで埋めると 3,000 件になり、自分の投稿は残る', () async {
      final a = await make('A', 1);
      final g = await a.createGroup(name: '試験', membersCanPost: true);
      final mine = await a.postNotice(
        groupCode: g.code,
        category: NoticeCategory.water,
        title: '〇〇小学校で 給水します',
      );
      final added = await a.fillTestNotices(groupCode: g.code);
      expect(a.store.count, kDefaultMaxMessages);
      expect(added, kDefaultMaxMessages - 2); // group_info と自分の投稿の分
      expect(a.store.contains(mine.msgId), isTrue);
      expect(await a.fillTestNotices(groupCode: g.code), 0);
    });

    test('自分の投稿を直接渡した台数を数え、受け取っただけの投稿は数えない（C18）', () async {
      final a = await make('A', 1);
      final b = await make('B', 2);
      final c = await make('C', 3);
      final g = await a.createGroup(name: '〇〇町', membersCanPost: true);
      await b.joinGroup(g.code);
      await c.joinGroup(g.code);
      final mine = await a.postNotice(
        groupCode: g.code,
        category: NoticeCategory.water,
        title: '〇〇小学校で 給水します',
      );
      final stored = a.store.get(mine.msgId)!;
      expect(a.handedOf(stored)!.devices, 0);
      expect(a.handedOf(stored)!.lastAt, isNull);

      radio.discover('B', 'A');
      await radio.settle();
      await radio.elapse(const Duration(seconds: 5));
      expect(b.store.contains(mine.msgId), isTrue);
      expect(a.handedOf(a.store.get(mine.msgId)!)!.devices, 1);
      expect(a.handedDeviceCount, 1);
      expect(a.lastHandedAt, isNotNull);
      expect(a.lastHandedCount, greaterThan(0));
      // 住民の B が受け取っただけのお知らせは数えない。
      expect(b.handedOf(b.store.get(mine.msgId)!), isNull);

      await radio.elapse(const Duration(minutes: 2));
      radio.discover('C', 'A');
      await radio.settle();
      await radio.elapse(const Duration(seconds: 5));
      expect(c.store.contains(mine.msgId), isTrue);
      final info = a.handedOf(a.store.get(mine.msgId)!)!;
      expect(info.devices, 2);
      expect(a.handedDeviceCount, 2);
    });
  });
}
