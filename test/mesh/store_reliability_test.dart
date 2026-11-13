import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/core/categories.dart';
import 'package:kairanban/core/envelope.dart';
import 'package:kairanban/core/report.dart';
import 'package:kairanban/mesh/message_store.dart';
import 'package:kairanban/mesh/store_file.dart';

import 'helpers.dart';

class FaultBackend extends MemoryStoreBackend {
  bool failNext = false;
  bool writeBeforeFailure = false;
  Completer<void>? gate;
  Completer<void>? entered;

  Future<void> write(Future<void> Function() operation) async {
    final wait = gate;
    if (wait != null) {
      if (!(entered?.isCompleted ?? true)) entered!.complete();
      await wait.future;
    }
    if (failNext) {
      failNext = false;
      if (writeBeforeFailure) await operation();
      throw StateError('simulated storage failure');
    }
    await operation();
  }

  @override
  Future<void> append(Uint8List record) => write(() => super.append(record));
  @override
  Future<void> appendAll(List<Uint8List> records) =>
      write(() => super.appendAll(records));
  @override
  Future<void> rewrite(List<Uint8List> records) =>
      write(() => super.rewrite(records));
}

/// 追記なら最初のレコードだけ残して停止。全置換なら rename 前に停止する。
class InterruptedBackend extends MemoryStoreBackend {
  bool interruptNext = false;

  @override
  Future<void> appendAll(List<Uint8List> records) async {
    if (interruptNext) {
      interruptNext = false;
      await super.append(records.first);
      throw StateError('interrupted append');
    }
    await super.appendAll(records);
  }

  @override
  Future<void> rewrite(List<Uint8List> records) async {
    if (interruptNext) {
      interruptNext = false;
      throw StateError('interrupted before atomic replacement');
    }
    await super.rewrite(records);
  }
}

Envelope sos(int id) => Envelope.create(
  kind: MessageKind.help,
  groupId: kGroupA,
  originId: nodeIdOf(id),
  createdAt: kT0,
  expiresAt: kT0 + 86400,
  role: SenderRole.resident,
  category: NoticeCategory.request,
  bodyPlain: NoticeBody(
    senderName: '',
    title: '助けて $id',
    ext: const ReportInfo(type: ReportType.sos).encode(),
  ).encode(),
);

void main() {
  test('保存待ちの追加を一覧・目録に出さず、同時追加も直列に確定する', () async {
    final backend = FaultBackend();
    final store = MessageStore(backend);
    await store.load();
    var notifications = 0;
    store.addListener(() => notifications++);
    backend.gate = Completer<void>();
    backend.entered = Completer<void>();
    final a = makeNotice(origin: nodeIdOf(1), createdAt: kT0);
    final b = makeNotice(origin: nodeIdOf(2), createdAt: kT0);
    final first = store.add(a, now: kT0);
    final second = store.add(b, now: kT0);
    await backend.entered!.future;
    expect(store.count, 0);
    expect(store.inventory(now: kT0), isEmpty);
    expect(store.isDurablyStored(a.msgId), isFalse);
    expect(notifications, 0);
    backend.gate!.complete();
    await Future.wait([first, second]);
    expect(store.count, 2);
    expect(notifications, 2);
    final restored = MessageStore(backend);
    await restored.load();
    expect(idsOf(restored), {a.msgId, b.msgId});
  });

  test('失敗した部分追記を後続の保存へ混ぜず、同じデータを再試行できる', () async {
    final backend = FaultBackend()..writeBeforeFailure = true;
    final store = MessageStore(backend);
    await store.load();
    final a = makeNotice(origin: nodeIdOf(1), createdAt: kT0);
    final b = makeNotice(origin: nodeIdOf(2), createdAt: kT0);
    backend.failNext = true;
    await expectLater(store.add(a, now: kT0), throwsStateError);
    expect(store.contains(a.msgId), isFalse);
    expect(store.version, 0);
    expect(store.lastStorageError, isNotNull);
    await store.add(b, now: kT0);
    final restored = MessageStore(backend);
    await restored.load();
    expect(idsOf(restored), {b.msgId});
    expect(store.lastStorageError, isNull);
    expect(await store.add(a, now: kT0), AddResult.added);
    expect(store.version, 2);
  });

  test('取り消しの保存失敗では本文や表示状態を消さない', () async {
    final backend = FaultBackend();
    final store = MessageStore(backend);
    await store.load();
    final notice = makeNotice(origin: nodeIdOf(1), createdAt: kT0, text: '本文');
    await store.add(notice, now: kT0);
    final reference = store.get(notice.msgId)!;
    final cancel = makeTombstone(
      origin: nodeIdOf(1),
      target: notice,
      createdAt: kT0 + 1,
    );
    backend.failNext = true;
    await expectLater(store.add(cancel, now: kT0 + 1), throwsStateError);
    expect(reference.retracted, isFalse);
    expect(reference.envelope.notice!.text, '本文');
    expect(store.contains(cancel.msgId), isFalse);
    await store.add(cancel, now: kT0 + 1);
    expect(reference.retracted, isTrue);
    expect(reference.isStub, isTrue);
  });

  test('専用受信箱への保存失敗でも、中継側は未受信のまま再試行する', () async {
    final store = MessageStore(MemoryStoreBackend());
    await store.load();
    final report = sos(1);
    store.beforeCommit = (draft, additions, now) async {
      expect(draft.contains(report.msgId), isTrue);
      expect(store.contains(report.msgId), isFalse);
      expect(additions.single.receivedAt, kT0);
      throw const StoreCapacityException('受信箱がいっぱいです');
    };
    await expectLater(
      store.add(report, now: kT0),
      throwsA(isA<StoreCapacityException>()),
    );
    expect(store.count, 0);
    store.beforeCommit = null;
    await store.add(report, now: kT0);
    expect(store.count, 1);
  });

  test('3000件満杯へ一般情報が来ても、未確認SOSは消えない', () async {
    final store = MessageStore(MemoryStoreBackend())
      ..joinedGroupIds = {kGroupA};
    await store.load();
    final urgent = sos(1);
    await store.add(urgent, now: kT0);
    await store.addAll([
      for (var i = 1; i < 3000; i++)
        makeNotice(
          origin: nodeIdOf(i),
          createdAt: kT0 + i,
          role: SenderRole.official,
          title: '一般情報 $i',
        ),
    ], now: kT0 + 3000);
    await store.add(
      makeNotice(
        origin: nodeIdOf(9000),
        createdAt: kT0 + 3001,
        groupId: kGroupB,
      ),
      now: kT0 + 3001,
    );
    expect(store.count, 2701);
    expect(store.contains(urgent.msgId), isTrue);
  });

  test('全件未確認SOSなら新着SOSでも押し出さず、確認後は空きを作れる', () async {
    final backend = MemoryStoreBackend();
    final store = MessageStore(backend, maxMessages: 3);
    await store.load();
    final reports = [for (var i = 1; i <= 3; i++) sos(i)];
    await store.addAll(reports, now: kT0);
    await expectLater(
      store.add(sos(4), now: kT0),
      throwsA(isA<StoreCapacityException>()),
    );
    expect(idsOf(store), reports.map((e) => e.msgId).toSet());
    final restored = MessageStore(backend, maxMessages: 3);
    await restored.load();
    expect(idsOf(restored), idsOf(store));
    final ack = Envelope.create(
      kind: MessageKind.ack,
      groupId: kGroupA,
      originId: nodeIdOf(50),
      createdAt: kT0,
      expiresAt: kT0 + 86400,
      category: NoticeCategory.request,
      role: SenderRole.official,
      supersedes: reports.first.msgId,
      bodyPlain: Uint8List(0),
    );
    // 正規の返信を保存する同一トランザクションで、その対象だけ保護を解除する。
    await store.add(ack, now: kT0);
    expect(store.ackFor(reports.first.msgId), isNotNull);
    expect(store.contains(reports[1].msgId), isTrue);
    expect(store.contains(reports[2].msgId), isTrue);
    await store.purgeExpired(kT0 + 86401);
    expect(store.count, 0);
    expect(await store.add(sos(4), now: kT0 + 86401), AddResult.added);
  });

  test('返信索引は同一宛先の複数返信・削除・再読み込みに追従する', () async {
    final backend = MemoryStoreBackend();
    final store = MessageStore(backend);
    await store.load();
    final report = sos(1);
    Envelope ack(int seconds) => Envelope.create(
      kind: MessageKind.ack,
      groupId: kGroupA,
      originId: nodeIdOf(2),
      createdAt: kT0 + seconds,
      expiresAt: kT0 + 172800,
      role: SenderRole.official,
      category: NoticeCategory.request,
      supersedes: report.msgId,
      bodyPlain: Uint8List(0),
    );
    final a = ack(1), b = ack(2);
    await store.addAll([report, a, b], now: kT0);
    expect(store.ackFor(report.msgId)!.msgId, b.msgId);
    await store.removeWhere((m) => m.msgId == b.msgId);
    expect(store.ackFor(report.msgId)!.msgId, a.msgId);
    final restored = MessageStore(backend);
    await restored.load();
    expect(restored.ackFor(report.msgId)!.msgId, a.msgId);
    await restored.removeWhere((m) => m.kind == MessageKind.ack);
    expect(restored.ackFor(report.msgId), isNull);
  });

  test('満杯SOSへの返信保存を中断して直ちに再起動してもSOSだけが消えない', () async {
    final backend = InterruptedBackend();
    final store = MessageStore(backend, maxMessages: 3);
    await store.load();
    final reports = [for (var i = 1; i <= 3; i++) sos(i)];
    await store.addAll(reports, now: kT0);
    final ack = Envelope.create(
      kind: MessageKind.ack,
      groupId: kGroupA,
      originId: nodeIdOf(50),
      createdAt: kT0,
      expiresAt: kT0 + 86400,
      category: NoticeCategory.request,
      role: SenderRole.official,
      supersedes: reports.first.msgId,
      bodyPlain: Uint8List(0),
    );
    backend.interruptNext = true;
    await expectLater(store.add(ack, now: kT0), throwsStateError);
    // 同プロセス内の _needsRepair に頼らず、新しいストアで読み込む。
    final restored = MessageStore(backend, maxMessages: 3);
    await restored.load();
    expect(idsOf(restored), reports.map((r) => r.msgId).toSet());
    expect(restored.ackFor(reports.first.msgId), isNull);
    await restored.add(ack, now: kT0);
    final again = MessageStore(backend, maxMessages: 3);
    await again.load();
    expect(again.ackFor(reports.first.msgId), isNotNull);
  });

  test('住民役割や別グループの返信ではSOSの削除保護を解除しない', () async {
    for (final wrongGroup in [false, true]) {
      final store = MessageStore(MemoryStoreBackend(), maxMessages: 3)
        ..joinedGroupIds = {kGroupA};
      await store.load();
      final urgent = sos(1);
      await store.add(urgent, now: kT0);
      final invalidAck = Envelope.create(
        kind: MessageKind.ack,
        groupId: wrongGroup ? kGroupB : kGroupA,
        originId: nodeIdOf(2),
        createdAt: kT0 + 1,
        expiresAt: kT0 + 86400,
        category: NoticeCategory.request,
        role: wrongGroup ? SenderRole.staff : SenderRole.resident,
        supersedes: urgent.msgId,
        bodyPlain: Uint8List(0),
      );
      await store.add(invalidAck, now: kT0 + 1);
      expect(store.ackFor(urgent.msgId), isNull);
      await store.add(
        makeNotice(
          origin: nodeIdOf(3),
          createdAt: kT0 + 2,
          role: SenderRole.official,
        ),
        now: kT0 + 2,
      );
      await store.add(
        makeNotice(
          origin: nodeIdOf(4),
          createdAt: kT0 + 3,
          role: SenderRole.official,
        ),
        now: kT0 + 3,
      );
      expect(store.contains(urgent.msgId), isTrue);
    }
  });
}
