import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/app/app_controller.dart';
import 'package:kairanban/core/envelope.dart';
import 'package:kairanban/core/report.dart';
import 'package:kairanban/mesh/groups.dart';
import 'package:kairanban/mesh/store_file.dart';
import 'package:kairanban/transport/fake_transport.dart';

import 'helpers.dart';
import 'report_inbox_test.dart' show report;

class _CountingHelpEnvelope extends Envelope {
  _CountingHelpEnvelope(Envelope source)
    : super(
        kind: source.kind,
        groupId: source.groupId,
        msgId: source.msgId,
        createdAt: source.createdAt,
        expiresAt: source.expiresAt,
        bodyPlain: source.bodyPlain,
        role: source.role,
        category: source.category,
      );

  int bodyReads = 0;

  @override
  NoticeBody? get help {
    bodyReads++;
    return super.help;
  }
}

class _FailingKeyValueStore extends MemoryKeyValueStore {
  bool fail = false;

  @override
  Future<void> setString(String key, String value) async {
    if (fail) throw StateError('settings write failed');
    await super.setString(key, value);
  }
}

Future<AppController> _controller({
  int Function()? now,
  KeyValueStore? kv,
}) async {
  final radio = FakeRadio(clock: FakeClock(startEpochSeconds: kT0));
  final controller = AppController(
    transport: radio.createTransport('HQ'),
    storeBackend: MemoryStoreBackend(),
    kv: kv ?? MemoryKeyValueStore(),
    now: now ?? radio.clock.now,
    createTimer: radio.clock.createTimer,
  );
  await controller.init();
  controller.setForeground(true);
  addTearDown(controller.dispose);
  return controller;
}

void main() {
  test('1万件の一覧・SOS集計を繰り返しても本文を再解析しない', () async {
    var now = kT0;
    final c = await _controller(now: () => now);
    final group = await c.createGroup(name: '本部', membersCanPost: false);
    final messages = [
      for (var i = 0; i < 10000; i++)
        _CountingHelpEnvelope(
          report(
            i,
            group: group.code,
            type: i % 100 == 0 ? ReportType.sos : ReportType.safe,
          ),
        ),
    ];
    await c.store.addAll(messages, now: now);
    for (final message in messages) {
      message.bodyReads = 0;
    }
    final first = c.receivedReports();
    expect(first, hasLength(10000));
    final firstReads = messages.fold<int>(0, (sum, m) => sum + m.bodyReads);
    expect(firstReads, 10000);
    for (var i = 0; i < 10; i++) {
      now++;
      expect(identical(c.receivedReports(), first), isTrue);
      expect(c.receivedReportSummary().total, 10000);
      expect(c.unackedSosCount, 100);
    }
    expect(messages.fold<int>(0, (sum, m) => sum + m.bodyReads), firstReads);
    expect(() => first.clear(), throwsUnsupportedError);

    await c.acknowledgeReport(messages.first.msgId);
    final replied = c.receivedReports();
    expect(replied, hasLength(10000));
    expect(
      replied.firstWhere((e) => e.msgId == messages.first.msgId).acked,
      isTrue,
    );
    expect(c.unackedSosCount, 99);
    expect(messages.fold<int>(0, (sum, m) => sum + m.bodyReads), firstReads);
  });

  test('期限切れは本文を読む前に除外し、履歴・時計の巻き戻りも反映する', () async {
    var now = kT0;
    final c = await _controller(now: () => now);
    final group = await c.createGroup(name: '本部', membersCanPost: false);
    final message = _CountingHelpEnvelope(report(1, group: group.code));
    await c.store.add(message, now: now);
    message.bodyReads = 0;
    now = message.expiresAt + 1;
    expect(c.receivedReports(), isEmpty);
    expect(c.receivedReportSummary().total, 0);
    expect(message.bodyReads, 0);
    final history = c.receivedReports(includeExpired: true);
    expect(history.single.expired, isTrue);
    expect(message.bodyReads, 1);
    now = kT0;
    expect(c.receivedReports().single.expired, isFalse);
    expect(message.bodyReads, 1);
    now = kT0 + 30 * 86400;
    expect(c.receivedReports(includeExpired: true), isEmpty);
    expect(c.reportMessage(message.msgId), isNull);
  });

  test('集計の再利用中でも期限・取消・グループ脱退を反映する', () async {
    var now = kT0;
    final c = await _controller(now: () => now);
    final group = await c.createGroup(name: '本部', membersCanPost: false);
    final sos = report(1, group: group.code, type: ReportType.sos);
    final safe = report(2, group: group.code);
    await c.store.addAll([sos, safe], now: now);
    expect(c.unackedSosCount, 1);
    now = sos.expiresAt + 1;
    expect(c.unackedSosCount, 0);
    expect(c.receivedReports(), hasLength(1));
    expect(c.receivedReports(includeExpired: true), hasLength(2));
    await c.store.add(
      makeTombstone(origin: nodeIdOf(5), target: safe, createdAt: now),
      now: now,
    );
    expect(c.receivedReports(), isEmpty);
    expect(c.receivedReports(includeExpired: true), hasLength(1));
    await c.leaveGroup(group.code);
    expect(c.receivedReports(includeExpired: true), isEmpty);
    expect(c.receivedReportSummary().total, 0);
  });

  test('一括返信は保存の合間にイベントを処理し、保存完了分を進捗通知する', () async {
    final c = await _controller();
    final group = await c.createGroup(name: '本部', membersCanPost: false);
    await c.store.addAll([
      for (var i = 0; i < 250; i++) report(i, group: group.code),
    ], now: kT0);
    final progress = <(int, int)>[];
    var finished = false;
    var eventBeforeFinish = false;
    Timer.run(() => eventBeforeFinish = !finished);
    final count = await c.acknowledgeAll(
      c.receivedReports(),
      onProgress: (completed, total) {
        progress.add((completed, total));
        final saved = c.receivedReports().where((e) => e.acked).length;
        expect(saved, completed);
      },
    );
    finished = true;
    expect(count, 250);
    expect(eventBeforeFinish, isTrue);
    expect(progress, [(0, 250), (100, 250), (200, 250), (250, 250)]);
  });

  test('権限の変更後に設定保存が失敗しても、以前の一覧を再表示しない', () async {
    final kv = _FailingKeyValueStore();
    final c = await _controller(kv: kv);
    final group = await c.createGroup(name: '本部', membersCanPost: false);
    await c.store.add(report(1, group: group.code), now: kT0);
    expect(c.receivedReports(), hasLength(1));
    kv.fail = true;
    await expectLater(c.leaveGroup(group.code), throwsStateError);
    expect(c.canSeeReports(group.code), isFalse);
    expect(c.receivedReports(), isEmpty);
    expect(c.receivedReportSummary().total, 0);
  });
}
