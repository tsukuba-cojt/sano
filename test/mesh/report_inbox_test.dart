import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/app/app_controller.dart';
import 'package:kairanban/core/categories.dart';
import 'package:kairanban/core/envelope.dart';
import 'package:kairanban/core/report.dart';
import 'package:kairanban/mesh/groups.dart';
import 'package:kairanban/mesh/message_store.dart';
import 'package:kairanban/mesh/report_inbox.dart';
import 'package:kairanban/mesh/store_file.dart';
import 'package:kairanban/transport/fake_transport.dart';

import 'helpers.dart';

Envelope report(
  int i, {
  int group = kGroupA,
  ReportType type = ReportType.safe,
}) {
  final info = ReportInfo(type: type, people: 1);
  return Envelope.create(
    kind: MessageKind.help,
    groupId: group,
    originId: nodeIdOf(i + 20),
    createdAt: kT0,
    expiresAt: kT0 + type.ttl.inSeconds,
    category: NoticeCategory.request,
    role: SenderRole.resident,
    bodyPlain: NoticeBody(
      senderName: '',
      title: info.title(),
      place: 'A町 $i',
      ext: info.encode(),
    ).encode(),
  );
}

class FailableBackend extends MemoryStoreBackend {
  bool fail = false;
  @override
  Future<void> append(Uint8List record) async {
    if (fail) throw StateError('disk full');
    await super.append(record);
  }

  @override
  Future<void> appendAll(List<Uint8List> records) async {
    if (fail) throw StateError('disk full');
    await super.appendAll(records);
  }

  @override
  Future<void> rewrite(List<Uint8List> records) async {
    if (fail) throw StateError('disk full');
    await super.rewrite(records);
  }
}

void main() {
  test('1,500 件へ一括返信しても全記録と返信が残り、再起動で復元する', () async {
    final relay = MemoryStoreBackend();
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
    final controller = make('HQ');
    await controller.init();
    controller.setForeground(true);
    final group = await controller.createGroup(
      name: '本部',
      membersCanPost: false,
      acceptsHelp: true,
    );
    await controller.store.addAll([
      for (var i = 0; i < 1500; i++) report(i, group: group.code),
    ], now: kT0);
    expect(controller.receivedReports().length, 1500);
    expect(await controller.acknowledgeAll(controller.receivedReports()), 1500);
    expect(controller.receivedReports().length, 1500);
    expect(controller.receivedReports().every((r) => r.acked), isTrue);
    expect(controller.reportInbox.count, 1500);
    expect(controller.store.count, lessThanOrEqualTo(3000));
    controller.dispose();

    final restarted = make('HQ-restarted');
    await restarted.init();
    expect(restarted.receivedReports().length, 1500);
    expect(restarted.receivedReports().every((r) => r.acked), isTrue);
    restarted.dispose();
  });

  test('中継から消えた報告の詳細と返信を本部記録から扱える', () async {
    final radio = FakeRadio(clock: FakeClock(startEpochSeconds: kT0));
    final c = AppController(
      transport: radio.createTransport('HQ'),
      storeBackend: MemoryStoreBackend(),
      kv: MemoryKeyValueStore(),
      now: radio.clock.now,
      createTimer: radio.clock.createTimer,
    );
    await c.init();
    final g = await c.createGroup(name: '本部', membersCanPost: false);
    final e = report(1, group: g.code);
    await c.store.add(e, now: kT0);
    await c.store.removeWhere((m) => m.msgId == e.msgId);
    expect(c.reportMessage(e.msgId), isNotNull);
    await c.acknowledgeReport(e.msgId);
    expect(c.receivedReports().single.acked, isTrue);
    c.dispose();
  });

  test('記録保存失敗は中継にも受信済みを公開せず、再試行で残る', () async {
    final reports = FailableBackend();
    final radio = FakeRadio(clock: FakeClock(startEpochSeconds: kT0));
    final c = AppController(
      transport: radio.createTransport('HQ'),
      storeBackend: MemoryStoreBackend(),
      reportBackend: reports,
      kv: MemoryKeyValueStore(),
      now: radio.clock.now,
      createTimer: radio.clock.createTimer,
    );
    await c.init();
    final g = await c.createGroup(name: '本部', membersCanPost: false);
    final e = report(2, group: g.code);
    reports.fail = true;
    await expectLater(c.store.add(e, now: kT0), throwsStateError);
    expect(c.store.contains(e.msgId), isFalse);
    expect(c.reportInbox.count, 0);
    expect(c.storageError, isNotNull);
    reports.fail = false;
    await c.store.add(e, now: kT0);
    expect(c.reportInbox.count, 1);
    expect(c.storageError, isNull);
    c.dispose();
  });

  test('返信の記録だけ保存できた場合、同じ返信を再送準備できる', () async {
    final relay = FailableBackend();
    final radio = FakeRadio(clock: FakeClock(startEpochSeconds: kT0));
    final c = AppController(
      transport: radio.createTransport('HQ'),
      storeBackend: relay,
      kv: MemoryKeyValueStore(),
      now: radio.clock.now,
      createTimer: radio.clock.createTimer,
    );
    await c.init();
    final g = await c.createGroup(name: '本部', membersCanPost: false);
    final e = report(3, group: g.code);
    await c.store.add(e, now: kT0);
    relay.fail = true;
    await expectLater(c.acknowledgeReport(e.msgId), throwsStateError);
    final savedAck = c.reportInbox.get(e.msgId)!.ack!;
    expect(c.store.contains(savedAck.msgId), isFalse);
    relay.fail = false;
    final retry = await c.acknowledgeReport(e.msgId);
    expect(retry!.msgId, savedAck.msgId);
    expect(c.store.contains(savedAck.msgId), isTrue);
    c.dispose();
  });

  test('件数とバイト上限では既存記録を消さずに保存を拒否する', () async {
    final store = MessageStore(MemoryStoreBackend());
    await store.load();
    await store.addAll([report(1), report(2)], now: kT0);
    final inbox = ReportInbox(MemoryStoreBackend(), maxRecords: 1);
    await inbox.load(now: kT0);
    await inbox.capture(store, [store.all.first], kT0, canSee: (_) => true);
    await expectLater(
      inbox.capture(store, store.all.toList(), kT0, canSee: (_) => true),
      throwsA(isA<StoreCapacityException>()),
    );
    expect(inbox.count, 1);
    expect(inbox.get(store.all.first.msgId), isNotNull);
    final bytes = ReportInbox(MemoryStoreBackend(), maxBytes: 1);
    await bytes.load(now: kT0);
    await expectLater(
      bytes.capture(store, store.all.toList(), kT0, canSee: (_) => true),
      throwsA(isA<StoreCapacityException>()),
    );
    expect(bytes.count, 0);
  });

  test('中継期限切れは履歴に残り、受信30日後に消える。再受信で延長しない', () async {
    final backend = MemoryStoreBackend();
    final store = MessageStore(MemoryStoreBackend());
    await store.load();
    final e = report(1);
    await store.add(e, now: kT0);
    final inbox = ReportInbox(backend);
    await inbox.load(now: kT0);
    await inbox.capture(store, store.all.toList(), kT0, canSee: (_) => true);
    final later = StoredMessage(envelope: e, receivedAt: kT0 + 20 * 86400);
    await inbox.capture(store, [later], kT0 + 20 * 86400, canSee: (_) => true);
    expect(inbox.get(e.msgId)!.message.receivedAt, kT0);
    final restarted = ReportInbox(backend);
    await restarted.load(now: kT0 + 4 * 86400);
    expect(restarted.count, 1);
    await restarted.purgeExpired(kT0 + kReportInboxRetentionSeconds);
    expect(restarted.count, 0);
  });

  test('権限のないグループと自分の投稿は本部記録に入れない', () async {
    final store = MessageStore(MemoryStoreBackend());
    await store.load();
    await store.add(report(1), now: kT0);
    await store.add(report(2, group: kGroupB), now: kT0);
    await store.add(report(3), now: kT0, isLocal: true);
    final inbox = ReportInbox(MemoryStoreBackend());
    await inbox.load(now: kT0);
    await inbox.capture(
      store,
      store.all.toList(),
      kT0,
      canSee: (g) => g == kGroupA,
    );
    expect(inbox.count, 1);
    expect(inbox.get(report(1).msgId), isNotNull);
  });

  test('中継から消えた後の取消も本部記録に反映する', () async {
    final radio = FakeRadio(clock: FakeClock(startEpochSeconds: kT0));
    final c = AppController(
      transport: radio.createTransport('HQ'),
      storeBackend: MemoryStoreBackend(),
      kv: MemoryKeyValueStore(),
      now: radio.clock.now,
      createTimer: radio.clock.createTimer,
    );
    await c.init();
    final g = await c.createGroup(name: '本部', membersCanPost: false);
    final e = report(1, group: g.code);
    await c.store.add(e, now: kT0);
    await c.store.removeWhere((m) => m.msgId == e.msgId);
    final cancel = makeTombstone(
      origin: nodeIdOf(21),
      target: e,
      createdAt: kT0 + 1,
    );
    await c.store.add(cancel, now: kT0 + 1);
    expect(c.receivedReports(includeExpired: true), isEmpty);
    expect(c.reportMessage(e.msgId)!.retracted, isTrue);
    c.dispose();
  });

  test('スタッフの取消は追記ログの旧本文も即座に消し、再起動で戻らない', () async {
    final backend = MemoryStoreBackend();
    final store = MessageStore(MemoryStoreBackend());
    await store.load();
    final inbox = ReportInbox(backend);
    await inbox.load(now: kT0);
    store.beforeCommit = (staged, additions, now) =>
        inbox.capture(staged, additions, now, canSee: (_) => true);
    final e = report(11);
    await store.add(e, now: kT0);
    expect(inbox.get(e.msgId)!.message.envelope.bodyPlain, isNotEmpty);
    final cancel = makeTombstone(
      origin: nodeIdOf(31),
      target: e,
      createdAt: kT0 + 1,
    );
    await store.add(cancel, now: kT0 + 1);
    expect(inbox.get(e.msgId)!.message.isStub, isTrue);
    expect(backend.rewriteCount, 1);
    for (final bytes in backend.records) {
      final row = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final message = row['message'] as Map<String, dynamic>;
      expect(message['stub'], isTrue);
      final saved = Envelope.decodeStub(
        base64Decode(message['wire'] as String),
      );
      expect(saved.bodyPlain, isEmpty);
    }
    final restarted = ReportInbox(backend);
    await restarted.load(now: kT0 + 1);
    expect(restarted.get(e.msgId)!.message.isStub, isTrue);
    expect(restarted.get(e.msgId)!.message.envelope.bodyPlain, isEmpty);
  });

  test('旧中継データは本部の起動時とスタッフ昇格時に移行する', () async {
    final relay = MemoryStoreBackend();
    final inbox = MemoryStoreBackend();
    final kv = MemoryKeyValueStore();
    final manager = GroupManager(kv);
    await manager.load();
    final group = await manager.create(
      name: '本部',
      hostName: '防災課',
      membersCanPost: false,
    );
    final legacy = MessageStore(relay);
    await legacy.load();
    await legacy.add(report(21, group: group.code), now: kT0);
    final radio = FakeRadio(clock: FakeClock(startEpochSeconds: kT0));
    final hq = AppController(
      transport: radio.createTransport('HQ'),
      storeBackend: relay,
      reportBackend: inbox,
      kv: kv,
      now: radio.clock.now,
      createTimer: radio.clock.createTimer,
    );
    await hq.init();
    expect(hq.reportInbox.count, 1);
    expect(
      hq.receivedReports().single.msgId,
      report(21, group: group.code).msgId,
    );
    hq.dispose();

    final staff = AppController(
      transport: radio.createTransport('staff'),
      storeBackend: MemoryStoreBackend(),
      kv: MemoryKeyValueStore(),
      now: radio.clock.now,
      createTimer: radio.clock.createTimer,
    );
    await staff.init();
    await staff.joinGroup(group.code);
    final e = report(22, group: group.code);
    await staff.store.add(e, now: kT0);
    expect(staff.reportInbox.count, 0);
    expect(
      await staff.elevate(group.code, group.staffCode!),
      ElevateResult.staff,
    );
    expect(staff.reportInbox.get(e.msgId), isNotNull);
    await staff.leaveGroup(group.code);
    expect(staff.receivedReports(), isEmpty);
    expect(staff.reportInbox.get(e.msgId), isNotNull);
    staff.dispose();
  });
}
