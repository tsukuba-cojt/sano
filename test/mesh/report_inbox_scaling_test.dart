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
import 'report_inbox_test.dart' show report;

class _CountingBackend extends MemoryStoreBackend {
  int rewrittenRecords = 0;
  bool failAfterAppend = false;
  Completer<void>? blocked;
  Completer<void>? started;

  @override
  Future<void> appendAll(List<Uint8List> records) async {
    started?.complete();
    started = null;
    await blocked?.future;
    if (failAfterAppend) {
      failAfterAppend = false;
      await super.appendAll(records.take(1).toList());
      throw StateError('partial append');
    }
    await super.appendAll(records);
  }

  @override
  Future<void> rewrite(List<Uint8List> records) async {
    rewrittenRecords += records.length;
    await super.rewrite(records);
  }
}

StoredMessage _received(Envelope e, {int at = kT0}) =>
    StoredMessage(envelope: e, receivedAt: at);

StoredMessage _ack(Envelope target, {int sequence = 1}) => _received(
  Envelope.create(
    kind: MessageKind.ack,
    groupId: target.groupId,
    originId: nodeIdOf(1),
    createdAt: kT0 + sequence,
    expiresAt: kT0 + 7 * 86400,
    category: NoticeCategory.request,
    role: SenderRole.official,
    supersedes: target.msgId,
    bodyPlain: Uint8List(0),
  ),
);

void main() {
  late MessageStore staged;

  setUp(() async {
    staged = MessageStore(MemoryStoreBackend());
    await staged.load();
  });

  Future<void> capture(ReportInbox inbox, List<StoredMessage> batch) =>
      inbox.capture(staged, batch, kT0, canSee: (_) => true);

  test('10,000 件の新規受信は追記だけで保存し、返信も全件書き直しを抑える', () async {
    final backend = _CountingBackend();
    final inbox = ReportInbox(backend);
    await inbox.load(now: kT0);
    final reports = [for (var i = 0; i < 10000; i++) report(i)];
    for (var start = 0; start < reports.length; start += 100) {
      await capture(inbox, [
        for (final e in reports.skip(start).take(100)) _received(e),
      ]);
    }
    expect(inbox.count, 10000);
    expect(backend.rewriteCount, 0);
    for (var start = 0; start < reports.length; start += 100) {
      await capture(inbox, [
        for (final e in reports.skip(start).take(100)) _ack(e),
      ]);
    }
    expect(inbox.all.every((r) => r.ack != null), isTrue);
    // 旧実装は受信・返信で延べ 300,000 件以上を書き直していた。
    expect(backend.rewrittenRecords, lessThan(80000));
    final restored = ReportInbox(backend);
    await restored.load(now: kT0);
    expect(restored.count, 10000);
    expect(restored.all.every((r) => r.ack != null), isTrue);
  });

  test('読み込みは保存バイトを再利用し、復元中にイベント処理へ戻る', () async {
    final backend = _CountingBackend();
    final inbox = ReportInbox(backend);
    await inbox.load(now: kT0);
    await capture(inbox, [for (var i = 0; i < 1024; i++) _received(report(i))]);
    final before = backend.records.map(base64Encode).toList();
    final rewrites = backend.rewriteCount;
    var loading = true;
    var events = 0;
    void onEvent() {
      if (!loading) return;
      events++;
      Timer.run(onEvent);
    }

    Timer.run(onEvent);
    final restored = ReportInbox(backend);
    try {
      await restored.load(now: kT0);
    } finally {
      loading = false;
    }
    expect(restored.count, 1024);
    expect(events, greaterThan(1));
    expect(backend.rewriteCount, rewrites);
    expect(backend.records.map(base64Encode), before);
  });

  test('件数とバイトのちょうど上限は復元でき、超過ファイルは削除せず拒否する', () async {
    final backend = _CountingBackend();
    final inbox = ReportInbox(backend);
    await inbox.load(now: kT0);
    await capture(inbox, [_received(report(1)), _received(report(2))]);
    final bytes = backend.records.fold<int>(0, (sum, r) => sum + r.length + 4);
    final before = backend.records.map(base64Encode).toList();
    final exact = ReportInbox(backend, maxRecords: 2, maxBytes: bytes);
    await exact.load(now: kT0);
    expect(exact.count, 2);

    for (final bounded in [
      ReportInbox(backend, maxRecords: 1),
      ReportInbox(backend, maxBytes: bytes - 1),
    ]) {
      await expectLater(
        bounded.load(now: kT0),
        throwsA(isA<StoreCapacityException>()),
      );
      expect(bounded.count, 0);
      expect(bounded.lastError, contains('いっぱい'));
      expect(backend.records.map(base64Encode), before);
    }
  });

  test('新規追加・返信の容量は差分で数え、失敗後も上限を緩めない', () async {
    final source = _CountingBackend();
    final example = ReportInbox(source);
    await example.load(now: kT0);
    final first = report(1);
    final second = report(2);
    final ack = _ack(first);
    await capture(example, [_received(first), _received(second), ack]);
    final limit = source.records.fold<int>(0, (sum, r) => sum + r.length + 4);

    final backend = _CountingBackend();
    final bounded = ReportInbox(backend, maxRecords: 2, maxBytes: limit);
    await bounded.load(now: kT0);
    await capture(bounded, [_received(first), _received(second)]);
    await capture(bounded, [ack]);
    expect(bounded.count, 2);
    expect(bounded.containsMessageId(ack.msgId), isTrue);
    final before = backend.records.map(base64Encode).toList();
    await expectLater(
      capture(bounded, [_received(report(3))]),
      throwsA(isA<StoreCapacityException>()),
    );
    expect(bounded.count, 2);
    expect(backend.records.map(base64Encode), before);

    final tooSmall = ReportInbox(_CountingBackend(), maxBytes: limit - 1);
    await tooSmall.load(now: kT0);
    await capture(tooSmall, [_received(first), _received(second)]);
    await expectLater(
      capture(tooSmall, [ack]),
      throwsA(isA<StoreCapacityException>()),
    );
    expect(tooSmall.get(first.msgId)!.ack, isNull);
    expect(tooSmall.containsMessageId(ack.msgId), isFalse);
  });

  test('500 件未満の更新で再起動を繰り返しても古いログをため続けない', () async {
    final backend = _CountingBackend();
    var inbox = ReportInbox(backend);
    await inbox.load(now: kT0);
    final e = report(1);
    await capture(inbox, [_received(e)]);
    for (var restart = 0; restart < 10; restart++) {
      for (var i = 1; i <= 100; i++) {
        await capture(inbox, [_ack(e, sequence: restart * 100 + i)]);
      }
      inbox = ReportInbox(backend);
      await inbox.load(now: kT0);
    }
    expect(inbox.count, 1);
    expect(inbox.get(e.msgId)!.ack!.envelope.createdAt, kT0 + 1000);
    expect(backend.rewriteCount, greaterThan(0));
    expect(backend.records.length, lessThan(700));
  });

  test('書き込みが終わるまで差分と返信 ID を公開しない', () async {
    final backend = _CountingBackend();
    final inbox = ReportInbox(backend);
    await inbox.load(now: kT0);
    final e = report(1);
    await capture(inbox, [_received(e)]);
    final ack = _ack(e);
    backend.blocked = Completer<void>();
    backend.started = Completer<void>();
    final started = backend.started!.future;
    final save = capture(inbox, [ack]);
    await started;
    expect(inbox.get(e.msgId)!.ack, isNull);
    expect(inbox.containsMessageId(ack.msgId), isFalse);
    backend.blocked!.complete();
    await save;
    expect(inbox.get(e.msgId)!.ack!.msgId, ack.msgId);
    expect(inbox.containsMessageId(ack.msgId), isTrue);
  });

  test('部分追記の失敗後は既知の状態から書き直してから差分を公開する', () async {
    final backend = _CountingBackend();
    final inbox = ReportInbox(backend);
    await inbox.load(now: kT0);
    final existing = report(1);
    final rejected = report(2);
    final retry = report(3);
    await capture(inbox, [_received(existing)]);
    backend.failAfterAppend = true;
    await expectLater(capture(inbox, [_received(rejected)]), throwsStateError);
    expect(inbox.count, 1);
    expect(inbox.get(rejected.msgId), isNull);
    await capture(inbox, [_received(retry)]);
    expect(backend.rewriteCount, 1);
    final restored = ReportInbox(backend);
    await restored.load(now: kT0);
    expect(restored.count, 2);
    expect(restored.get(existing.msgId), isNotNull);
    expect(restored.get(retry.msgId), isNotNull);
    expect(restored.get(rejected.msgId), isNull);
  });

  test('期限切れを除いた現存記録で容量を判定し、受信期限の索引も更新する', () async {
    final backend = _CountingBackend();
    final inbox = ReportInbox(backend);
    await inbox.load(now: kT0);
    final older = report(1);
    final newer = report(2);
    await capture(inbox, [_received(older), _received(newer, at: kT0 + 10)]);
    final bounded = ReportInbox(backend, maxRecords: 1);
    await bounded.load(now: kT0 + kReportInboxRetentionSeconds);
    expect(bounded.count, 1);
    expect(bounded.get(older.msgId), isNull);
    expect(bounded.get(newer.msgId), isNotNull);
    await bounded.purgeExpired(kT0 + kReportInboxRetentionSeconds + 10);
    expect(bounded.count, 0);
    expect(backend.records, isEmpty);
  });
}
