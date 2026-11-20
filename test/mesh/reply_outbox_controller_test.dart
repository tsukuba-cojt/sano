import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/app/app_controller.dart';
import 'package:kairanban/core/envelope.dart';
import 'package:kairanban/mesh/groups.dart';
import 'package:kairanban/mesh/store_file.dart';
import 'package:kairanban/transport/fake_transport.dart';

import 'helpers.dart';
import 'report_inbox_test.dart' show FailableBackend, report;

void main() {
  test('1万件の返信が3千件の中継枠と再起動を越えて自動で受渡し確認まで進む', () async {
    final radio = FakeRadio(clock: FakeClock(startEpochSeconds: kT0));
    final relay = MemoryStoreBackend();
    final inbox = MemoryStoreBackend();
    final kv = MemoryKeyValueStore();
    var transport = radio.createTransport('HQ');
    AppController make() => AppController(
      transport: transport,
      storeBackend: relay,
      reportBackend: inbox,
      kv: kv,
      now: radio.clock.now,
      createTimer: radio.clock.createTimer,
      nodeId: nodeIdOf(1),
    );
    var hq = make();
    final carrier = TestNode(radio, 'carrier', index: 2);
    addTearDown(() async {
      hq.dispose();
      await transport.dispose();
      await carrier.dispose();
    });
    await hq.init();
    await hq.startMesh();
    await carrier.start();
    final group = await hq.createGroup(name: '本部', membersCanPost: false);
    for (var start = 0; start < 10000; start += 128) {
      await hq.store.addAll([
        for (var i = start; i < start + 128 && i < 10000; i++)
          report(i, group: group.code),
      ], now: kT0);
    }
    expect(await hq.acknowledgeAll(hq.receivedReports()), 10000);
    expect(hq.receivedReports().where((r) => r.replyPending), hasLength(10000));
    expect(hq.store.count, lessThanOrEqualTo(3000));
    final ackIds = hq.reportInbox.all.map((r) => r.ack!.msgId).toSet();
    final savedByCarrier = <int>{};
    carrier.store.addListener(() {
      savedByCarrier.addAll(
        carrier.store.all
            .where((m) => ackIds.contains(m.msgId))
            .map((m) => m.msgId),
      );
    });
    radio.discover('HQ', 'carrier');
    await radio.settle();
    final beforeRestart = hq.reportInbox.all
        .where((r) => r.ackHandedAt != null)
        .length;
    expect(beforeRestart, greaterThan(0));
    expect(beforeRestart, lessThan(10000));

    hq.dispose();
    await transport.dispose();
    transport = radio.createTransport('HQ-restarted');
    hq = make();
    await hq.init();
    await hq.startMesh();
    expect(
      hq.reportInbox.all.where((r) => r.ackHandedAt != null),
      hasLength(beforeRestart),
    );
    expect(
      await hq.acknowledgeAll(hq.receivedReports()),
      0,
      reason: '保存済みの返信は再登録せず自動で続ける',
    );
    radio.discover('HQ-restarted', 'carrier');
    await radio.settle();
    for (var round = 0; round < 100; round++) {
      if (hq.reportInbox.all.every((r) => r.ackHandedAt != null)) break;
      await radio.elapse(const Duration(seconds: 2));
    }
    expect(
      hq.reportInbox.all.where((r) => r.ackHandedAt != null),
      hasLength(10000),
    );
    expect(savedByCarrier, ackIds);
    expect(hq.receivedReports().where((r) => r.replyPending), isEmpty);
    expect(carrier.store.count, lessThanOrEqualTo(3000));
    expect(hq.store.count, lessThanOrEqualTo(3000));
    expect(hq.reportInbox.count, 10000);
    expect(hq.node.recentSessions.every((s) => s.succeeded), isTrue);
  });

  test('本部への返信保存後に中継保存だけ失敗しても再操作なしで送る', () async {
    final radio = FakeRadio(clock: FakeClock(startEpochSeconds: kT0));
    final relay = FailableBackend();
    final hq = AppController(
      transport: radio.createTransport('HQ'),
      storeBackend: relay,
      kv: MemoryKeyValueStore(),
      now: radio.clock.now,
      createTimer: radio.clock.createTimer,
      nodeId: nodeIdOf(1),
    );
    final carrier = TestNode(radio, 'carrier', index: 2);
    addTearDown(hq.dispose);
    addTearDown(carrier.dispose);
    await hq.init();
    await hq.startMesh();
    await carrier.start();
    final group = await hq.createGroup(name: '本部', membersCanPost: false);
    final target = report(1, group: group.code);
    await hq.store.add(target, now: kT0);
    relay.fail = true;
    await expectLater(hq.acknowledgeReport(target.msgId), throwsStateError);
    final ack = hq.reportInbox.get(target.msgId)!.ack!;
    expect(hq.store.contains(ack.msgId), isFalse);
    expect(hq.receivedReports().single.replyPending, isTrue);
    expect(await hq.acknowledgeReport(target.msgId), isNull);
    relay.fail = false;
    radio.discover('HQ', 'carrier');
    await radio.settle();
    expect(carrier.store.get(ack.msgId)?.kind, MessageKind.ack);
    expect(hq.receivedReports().single.replyPending, isFalse);
    expect(hq.receivedReports().single.replyHandedAt, kT0);
  });

  test('確認記録の保存失敗は待ちを維持し、再接続の正確な目録で確認を復旧する', () async {
    final radio = FakeRadio(clock: FakeClock(startEpochSeconds: kT0));
    final inbox = FailableBackend();
    final hq = AppController(
      transport: radio.createTransport('HQ'),
      storeBackend: MemoryStoreBackend(),
      reportBackend: inbox,
      kv: MemoryKeyValueStore(),
      now: radio.clock.now,
      createTimer: radio.clock.createTimer,
      nodeId: nodeIdOf(1),
    );
    final carrier = TestNode(radio, 'carrier', index: 2);
    addTearDown(hq.dispose);
    addTearDown(carrier.dispose);
    await hq.init();
    await hq.startMesh();
    await carrier.start();
    final group = await hq.createGroup(name: '本部', membersCanPost: false);
    final target = report(1, group: group.code);
    await hq.store.add(target, now: kT0);
    final ack = (await hq.acknowledgeReport(target.msgId))!;
    inbox.fail = true;
    radio.discover('HQ', 'carrier');
    await radio.settle();
    expect(carrier.store.contains(ack.msgId), isTrue);
    expect(hq.reportInbox.lastError, isNotNull);
    expect(hq.receivedReports().single.replyPending, isTrue);
    expect(hq.receivedReports().single.replyHandedAt, isNull);
    inbox.fail = false;
    await radio.elapse(const Duration(seconds: 61));
    expect(hq.receivedReports().single.replyPending, isFalse);
    expect(hq.receivedReports().single.replyHandedAt, isNotNull);
    expect(hq.reportInbox.lastError, isNull);
    expect(carrier.store.all.where((m) => m.msgId == ack.msgId), hasLength(1));
  });
}
