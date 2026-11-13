import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/core/categories.dart';
import 'package:kairanban/core/envelope.dart';
import 'package:kairanban/mesh/message_store.dart';
import 'package:kairanban/mesh/report_inbox.dart';
import 'package:kairanban/mesh/store_file.dart';

import 'helpers.dart';
import 'report_inbox_test.dart' show FailableBackend, report;

StoredMessage _received(Envelope envelope) =>
    StoredMessage(envelope: envelope, receivedAt: kT0);

StoredMessage _reply(
  Envelope target, {
  int sequence = 1,
  bool local = true,
  int? expiresAt,
}) => StoredMessage(
  envelope: Envelope.create(
    kind: MessageKind.ack,
    groupId: target.groupId,
    originId: nodeIdOf(local ? 1 : 2),
    createdAt: kT0 + sequence,
    expiresAt: expiresAt ?? kT0 + 72 * 3600,
    category: NoticeCategory.request,
    role: SenderRole.official,
    supersedes: target.msgId,
    bodyPlain: Uint8List(0),
  ),
  receivedAt: kT0 + sequence,
  isLocal: local,
);

class _BlockingBackend extends FailableBackend {
  Completer<void>? started;
  Completer<void>? release;

  @override
  Future<void> appendAll(List<Uint8List> records) async {
    started?.complete();
    started = null;
    await release?.future;
    await super.appendAll(records);
  }
}

void main() {
  late MessageStore staged;

  setUp(() async {
    staged = MessageStore(MemoryStoreBackend());
    await staged.load();
  });

  Future<void> capture(ReportInbox inbox, List<StoredMessage> messages) =>
      inbox.capture(staged, messages, kT0, canSee: (_) => true);

  List<int> pending(ReportInbox inbox, {int now = kT0}) => inbox
      .pendingReplies(now: now, canSee: (_) => true)
      .map((m) => m.msgId)
      .toList();

  test('v1 の確認時刻なし返信は未確認として復元し、確認は再起動後も残る', () async {
    final backend = MemoryStoreBackend();
    final inbox = ReportInbox(backend);
    await inbox.load(now: kT0);
    final target = report(1);
    final ack = _reply(target);
    await capture(inbox, [_received(target), ack]);
    final legacy = MemoryStoreBackend([
      for (final bytes in backend.records)
        Uint8List.fromList(
          utf8.encode(
            jsonEncode(
              (jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>)
                ..remove('ackHandedAt'),
            ),
          ),
        ),
    ]);
    final restored = ReportInbox(legacy);
    await restored.load(now: kT0);
    expect(restored.get(target.msgId)!.ackHandedAt, isNull);
    expect(pending(restored), [ack.msgId]);

    await restored.markRepliesHanded([ack.msgId], at: kT0 + 10);
    expect(pending(restored), isEmpty);
    final restarted = ReportInbox(legacy);
    await restarted.load(now: kT0);
    expect(restarted.get(target.msgId)!.ackHandedAt, kT0 + 10);
    expect(pending(restarted), isEmpty);
    expect(restarted.containsMessageId(ack.msgId), isTrue);
  });

  test('重複確認・報告 ID・未知 ID・他端末の返信は確認状態を変えない', () async {
    final backend = MemoryStoreBackend();
    final inbox = ReportInbox(backend);
    await inbox.load(now: kT0);
    final ownReport = report(1);
    final otherReport = report(2);
    final own = _reply(ownReport);
    final other = _reply(otherReport, local: false);
    await capture(inbox, [
      _received(ownReport),
      _received(otherReport),
      own,
      other,
    ]);
    await inbox.markRepliesHanded([own.msgId, own.msgId], at: kT0 + 10);
    final appends = backend.appendCount;
    await inbox.markRepliesHanded([
      own.msgId,
      ownReport.msgId,
      other.msgId,
      999999,
    ], at: kT0 + 20);
    expect(inbox.get(ownReport.msgId)!.ackHandedAt, kT0 + 10);
    expect(inbox.get(otherReport.msgId)!.ackHandedAt, isNull);
    expect(pending(inbox), isEmpty);
    expect(backend.appendCount, appends);
  });

  test('同じ返信と報告を再受信しても確認を維持し、新しい返信だけ未確認へ戻す', () async {
    final backend = MemoryStoreBackend();
    final inbox = ReportInbox(backend);
    await inbox.load(now: kT0);
    final target = report(1);
    final first = _reply(target);
    await capture(inbox, [_received(target), first]);
    await inbox.markRepliesHanded([first.msgId], at: kT0 + 10);
    await capture(inbox, [_received(target), first]);
    expect(inbox.get(target.msgId)!.ackHandedAt, kT0 + 10);
    expect(pending(inbox), isEmpty);

    final newer = _reply(target, sequence: 20);
    await capture(inbox, [newer]);
    expect(inbox.get(target.msgId)!.ackHandedAt, isNull);
    expect(pending(inbox), [newer.msgId]);
    expect(inbox.containsMessageId(first.msgId), isFalse);
    await inbox.markRepliesHanded([first.msgId], at: kT0 + 30);
    expect(pending(inbox), [newer.msgId]);
    await inbox.markRepliesHanded([newer.msgId], at: kT0 + 40);
    expect(inbox.get(target.msgId)!.ackHandedAt, kT0 + 40);
  });

  test('送信待ちは権限・取消・返信の期限・30日の保管期限を守る', () async {
    final inbox = ReportInbox(MemoryStoreBackend());
    await inbox.load(now: kT0);
    final normal = report(1);
    final hidden = report(2, group: kGroupB);
    final cancelled = report(3);
    final noReply = report(4);
    final ack = _reply(normal, expiresAt: kT0 + 100);
    final hiddenAck = _reply(hidden);
    final cancelledAck = _reply(cancelled);
    await capture(inbox, [
      _received(normal),
      _received(hidden),
      _received(cancelled),
      _received(noReply),
      ack,
      hiddenAck,
      cancelledAck,
    ]);
    await capture(inbox, [
      _received(
        makeTombstone(
          origin: nodeIdOf(23),
          target: cancelled,
          createdAt: kT0 + 2,
        ),
      ),
    ]);
    expect(
      inbox
          .pendingReplies(now: kT0 + 100, canSee: (g) => g == kGroupA)
          .map((m) => m.msgId),
      [ack.msgId],
    );
    expect(
      inbox.pendingReplies(now: kT0 + 101, canSee: (g) => g == kGroupA),
      isEmpty,
    );
    expect(inbox.get(cancelled.msgId)!.message.isStub, isTrue);

    // ACK の期限を越える場合と保管期限を越える場合をそれぞれ独立に確認する。
    final longAck = _reply(normal, sequence: 10, expiresAt: kT0 + 40 * 86400);
    await capture(inbox, [longAck]);
    expect(pending(inbox, now: kT0 + kReportInboxRetentionSeconds - 1), [
      longAck.msgId,
    ]);
    expect(pending(inbox, now: kT0 + kReportInboxRetentionSeconds), isEmpty);
  });

  test('取消後も確認時刻を残し、遅れて届いた確認は送信待ちを復活させない', () async {
    final backend = MemoryStoreBackend();
    final inbox = ReportInbox(backend);
    await inbox.load(now: kT0);
    final confirmed = report(1);
    final pendingReport = report(2);
    final firstAck = _reply(confirmed);
    final secondAck = _reply(pendingReport);
    await capture(inbox, [
      _received(confirmed),
      _received(pendingReport),
      firstAck,
      secondAck,
    ]);
    await inbox.markRepliesHanded([firstAck.msgId], at: kT0 + 5);
    await capture(inbox, [
      for (final target in [confirmed, pendingReport])
        _received(
          makeTombstone(
            origin: nodeIdOf(3),
            target: target,
            createdAt: kT0 + 6,
          ),
        ),
    ]);
    expect(inbox.get(confirmed.msgId)!.ackHandedAt, kT0 + 5);
    expect(pending(inbox), isEmpty);
    await inbox.markRepliesHanded([secondAck.msgId], at: kT0 + 7);
    expect(inbox.get(pendingReport.msgId)!.ackHandedAt, kT0 + 7);
    expect(pending(inbox), isEmpty);
    final restored = ReportInbox(backend);
    await restored.load(now: kT0 + 8);
    expect(restored.get(confirmed.msgId)!.ackHandedAt, kT0 + 5);
    expect(restored.get(pendingReport.msgId)!.ackHandedAt, kT0 + 7);
    expect(pending(restored), isEmpty);
  });

  test('確認時刻は保存が完了してから公開し、待ち一覧の反復も壊さない', () async {
    final backend = _BlockingBackend();
    final inbox = ReportInbox(backend);
    await inbox.load(now: kT0);
    final target = report(1);
    final ack = _reply(target);
    await capture(inbox, [_received(target), ack]);
    final snapshot = inbox.pendingReplies(now: kT0, canSee: (_) => true);
    backend.started = Completer<void>();
    backend.release = Completer<void>();
    final started = backend.started!.future;
    final mark = inbox.markRepliesHanded([ack.msgId], at: kT0 + 10);
    await started;
    expect(inbox.get(target.msgId)!.ackHandedAt, isNull);
    expect(pending(inbox), [ack.msgId]);
    backend.release!.complete();
    await mark;
    expect(inbox.get(target.msgId)!.ackHandedAt, kT0 + 10);
    expect(pending(inbox), isEmpty);
    expect(snapshot.map((m) => m.msgId), [ack.msgId]);
  });

  test('確認保存の失敗では未確認を維持し、再試行した成功分だけを保存する', () async {
    final backend = FailableBackend();
    final inbox = ReportInbox(backend);
    await inbox.load(now: kT0);
    final target = report(1);
    final ack = _reply(target);
    await capture(inbox, [_received(target), ack]);
    backend.fail = true;
    await expectLater(
      inbox.markRepliesHanded([ack.msgId], at: kT0 + 10),
      throwsStateError,
    );
    expect(inbox.get(target.msgId)!.ackHandedAt, isNull);
    expect(pending(inbox), [ack.msgId]);
    expect(inbox.lastError, isNotNull);
    final restored = ReportInbox(backend);
    await restored.load(now: kT0);
    expect(pending(restored), [ack.msgId]);
    backend.fail = false;
    await inbox.markRepliesHanded([ack.msgId], at: kT0 + 20);
    expect(inbox.get(target.msgId)!.ackHandedAt, kT0 + 20);
    expect(inbox.lastError, isNull);
    final retried = ReportInbox(backend);
    await retried.load(now: kT0);
    expect(pending(retried), isEmpty);
    expect(retried.get(target.msgId)!.ackHandedAt, kT0 + 20);
  });

  test('確認時刻がバイト上限を超えると既存返信と未確認状態を守る', () async {
    final backend = MemoryStoreBackend();
    final inbox = ReportInbox(backend);
    await inbox.load(now: kT0);
    final target = report(1);
    final ack = _reply(target);
    await capture(inbox, [_received(target), ack]);
    final limit = backend.records.fold<int>(0, (sum, r) => sum + r.length + 4);
    final bounded = ReportInbox(backend, maxBytes: limit);
    await bounded.load(now: kT0);
    final before = backend.records.map(base64Encode).toList();
    await expectLater(
      bounded.markRepliesHanded([ack.msgId], at: kT0 + 10),
      throwsA(isA<StoreCapacityException>()),
    );
    expect(bounded.get(target.msgId)!.ackHandedAt, isNull);
    expect(pending(bounded), [ack.msgId]);
    expect(backend.records.map(base64Encode), before);
  });
}
