// 実ファイルで本部記録の受信・集計・返信・再起動を計測する。
// flutter test --concurrency=1 tool/benchmarks/report_capacity_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
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

const _now = 317 * 86400;

Uint8List _nodeId(int n) =>
    Uint8List(8)..buffer.asByteData().setUint64(0, n, Endian.little);

class _CountingBackend implements StoreBackend {
  _CountingBackend(String path) : inner = FileStoreBackend(path);
  final FileStoreBackend inner;
  int writtenBytes = 0;
  int rewrittenRecords = 0;
  int rewrites = 0;

  @override
  Future<List<Uint8List>> readAll() => inner.readAll();

  @override
  Future<void> append(Uint8List record) => appendAll([record]);

  @override
  Future<void> appendAll(List<Uint8List> records) async {
    writtenBytes += records.fold<int>(0, (sum, r) => sum + r.length + 4);
    await inner.appendAll(records);
  }

  @override
  Future<void> rewrite(List<Uint8List> records) async {
    rewrites++;
    rewrittenRecords += records.length;
    writtenBytes += records.fold<int>(0, (sum, r) => sum + r.length + 4);
    await inner.rewrite(records);
  }
}

Future<({T value, double ms, double maxEventGapMs})> _measure<T>(
  Future<T> Function() action,
) async {
  final watch = Stopwatch()..start();
  var last = 0;
  var largestGap = 0;
  void sample() {
    final now = watch.elapsedMicroseconds;
    largestGap = max(largestGap, now - last);
    last = now;
  }

  final timer = Timer.periodic(
    const Duration(milliseconds: 10),
    (_) => sample(),
  );
  try {
    final value = await action();
    sample();
    return (
      value: value,
      ms: watch.elapsedMicroseconds / 1000,
      maxEventGapMs: largestGap / 1000,
    );
  } finally {
    timer.cancel();
  }
}

List<Envelope> _reports(int count, int group) {
  final random = Random(20261113);
  return List.generate(count, (i) {
    final type = i % 100 == 0
        ? ReportType.sos
        : [ReportType.safe, ReportType.home, ReportType.need][i % 3];
    final info = ReportInfo(
      type: type,
      people: 1 + i % 4,
      needs: type.allowsNeeds ? [ReportNeed.water] : [],
    );
    final note = String.fromCharCodes(
      List.generate(120, (_) => 0x61 + random.nextInt(26)),
    );
    final createdAt = _now - 600 + i % 600;
    return Envelope.create(
      kind: MessageKind.help,
      groupId: group,
      originId: _nodeId(i + 20),
      createdAt: createdAt,
      expiresAt: createdAt + type.ttl.inSeconds,
      category: NoticeCategory.request,
      role: SenderRole.resident,
      bodyPlain: NoticeBody(
        senderName: type.allowsName ? 'テスト $i' : '',
        title: info.title(),
        place: '検証地区 ${i % 100} 番',
        text: note,
        ext: info.encode(),
      ).encode(),
    );
  });
}

void main() {
  final sizes = const String.fromEnvironment(
    'SANO_BENCH_COUNTS',
    defaultValue: '1000,10000',
  ).split(',').map(int.parse).toList();
  for (final count in sizes) {
    test(
      '本部 $count 件: ファイル保存・集計・一括返信・再起動',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'sano-capacity-',
        );
        final relay = _CountingBackend('${directory.path}/messages.bin');
        final inbox = _CountingBackend('${directory.path}/reports.bin');
        final kv = MemoryKeyValueStore();
        final radio = FakeRadio(clock: FakeClock(startEpochSeconds: _now));
        AppController make(String id) => AppController(
          transport: radio.createTransport(id),
          storeBackend: relay,
          reportBackend: inbox,
          kv: kv,
          now: radio.clock.now,
          createTimer: radio.clock.createTimer,
          nodeId: _nodeId(1),
        );
        var controller = make('HQ');
        try {
          await controller.init();
          controller.setForeground(true);
          final group = await controller.createGroup(
            name: '計測本部',
            membersCanPost: false,
            acceptsHelp: true,
          );
          final reports = _reports(count, group.code);
          final receive = await _measure(() async {
            for (var i = 0; i < reports.length; i += 128) {
              await controller.store.addAll(
                reports.sublist(i, min(i + 128, reports.length)),
                now: _now,
              );
            }
          });
          expect(controller.reportInbox.count, count);
          final firstQuery = Stopwatch()..start();
          final receivedEntries = controller.receivedReports();
          final firstQueryMs = firstQuery.elapsedMicroseconds / 1000;
          expect(receivedEntries.length, count);
          final querySamples = <double>[];
          for (var i = 0; i < 21; i++) {
            final watch = Stopwatch()..start();
            final entries = controller.receivedReports();
            AppController.summarize(entries);
            final sos = controller.unackedSosCount;
            querySamples.add(watch.elapsedMicroseconds / 1000);
            expect(entries.length, count);
            expect(sos, (count + 99) ~/ 100);
          }
          querySamples.sort();
          final ingestWrites = inbox.writtenBytes;
          final ingestRewrites = inbox.rewrites;
          final acknowledge = await _measure(
            () => controller.acknowledgeAll(receivedEntries),
          );
          expect(acknowledge.value, count);
          final afterAck = controller.receivedReports();
          expect(afterAck.length, count);
          expect(afterAck.every((e) => e.acked), isTrue);
          final pendingReplies = afterAck.where((e) => e.replyPending).length;
          final relayCount = controller.store.count;
          expect(relayCount, lessThanOrEqualTo(kDefaultMaxMessages));
          final rssBeforeReload = ProcessInfo.currentRss;
          controller.dispose();
          controller = make('HQ-restarted');
          final reload = await _measure(() => controller.init());
          final restored = controller.receivedReports();
          expect(restored.length, count);
          expect(restored.every((e) => e.acked), isTrue);
          final rssAfterReload = ProcessInfo.currentRss;
          var capacityBoundaryVerified = false;
          if (count == kReportInboxMaxRecords) {
            final extra = Envelope.create(
              kind: MessageKind.help,
              groupId: group.code,
              originId: _nodeId(count + 100),
              createdAt: _now,
              expiresAt: _now + ReportType.safe.ttl.inSeconds,
              category: NoticeCategory.request,
              role: SenderRole.resident,
              bodyPlain: NoticeBody(
                senderName: '',
                title: '容量境界の検証',
                ext: const ReportInfo(
                  type: ReportType.safe,
                  people: 1,
                ).encode(),
              ).encode(),
            );
            await expectLater(
              controller.store.add(extra, now: _now),
              throwsA(isA<StoreCapacityException>()),
            );
            expect(controller.reportInbox.count, count);
            expect(controller.store.contains(extra.msgId), isFalse);
            expect(controller.receivedReports().length, count);
            capacityBoundaryVerified = true;
          }
          final result = <String, Object>{
            'reports': count,
            'receive_ms': receive.ms,
            'receive_max_event_gap_ms': receive.maxEventGapMs,
            'first_query_ms': firstQueryMs,
            'query_and_sos_p50_ms': querySamples[10],
            'query_and_sos_p95_ms': querySamples[19],
            'acknowledge_ms': acknowledge.ms,
            'acknowledge_max_event_gap_ms': acknowledge.maxEventGapMs,
            'reload_ms': reload.ms,
            'reload_max_event_gap_ms': reload.maxEventGapMs,
            'inbox_ingest_written_bytes': ingestWrites,
            'inbox_ingest_rewrites': ingestRewrites,
            'inbox_total_written_bytes': inbox.writtenBytes,
            'inbox_total_rewritten_records': inbox.rewrittenRecords,
            'inbox_file_bytes': await File(inbox.inner.path).length(),
            'relay_count': relayCount,
            'pending_replies_after_ack': pendingReplies,
            'rss_before_reload_bytes': rssBeforeReload,
            'rss_after_reload_bytes': rssAfterReload,
            'capacity_boundary_verified': capacityBoundaryVerified,
          };
          // ignore: avoid_print
          print('SANO_BENCH ${jsonEncode(result)}');
        } finally {
          controller.dispose();
          await directory.delete(recursive: true);
        }
      },
      timeout: const Timeout(Duration(minutes: 10)),
    );
  }
}
