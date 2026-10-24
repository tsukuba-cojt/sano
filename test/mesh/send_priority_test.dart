/// すれ違いが短くても大事なものから渡す仕組み（v2.3）のテスト:
/// 送る順の段、古い版を中継しないこと、先出しの中身、短いすれ違いの模擬。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/core/categories.dart';
import 'package:kairanban/core/envelope.dart';
import 'package:kairanban/core/report.dart';
import 'package:kairanban/mesh/message_store.dart';
import 'package:kairanban/mesh/store_file.dart';
import 'package:kairanban/transport/fake_transport.dart';

import 'helpers.dart';

Envelope makeHelp({
  required Uint8List origin,
  required int createdAt,
  ReportType type = ReportType.sos,
  int groupId = kGroupA,
}) {
  final info = ReportInfo(type: type, people: 2);
  return Envelope.create(
    kind: MessageKind.help,
    groupId: groupId,
    originId: origin,
    createdAt: createdAt,
    expiresAt: createdAt + type.ttl.inSeconds,
    category: NoticeCategory.request,
    role: SenderRole.resident,
    bodyPlain: NoticeBody(
      senderName: '',
      title: info.title(),
      place: '〇〇町 公民館の 裏',
      ext: info.encode(),
    ).encode(),
  );
}

Envelope makeAck(Uint8List origin, Envelope target, int createdAt) => Envelope.create(
      kind: MessageKind.ack,
      groupId: target.groupId,
      originId: origin,
      createdAt: createdAt,
      expiresAt: createdAt + 48 * 3600,
      category: NoticeCategory.request,
      role: SenderRole.official,
      supersedes: target.msgId,
      bodyPlain: Uint8List(0),
    );

/// 圧縮で縮まない、ばらばらの文字の本文。
String noise(int n, int seed) {
  var x = seed;
  final buf = StringBuffer();
  for (var i = 0; i < n; i++) {
    x = (x * 1103515245 + 12345) & 0x7FFFFFFF;
    buf.writeCharCode(0x4E00 + x % 0x5000);
  }
  return buf.toString();
}

void main() {
  final origin = nodeIdOf(9);

  group('送る順の段', () {
    test('SOS・避難情報 → 取り消しなど → ほかの知らせ → 公式の大事なもの → 返事済み → 住民 → 訓練', () async {
      final store = MessageStore(MemoryStoreBackend());
      await store.load();
      final t = kT0;
      final resident = makeNotice(origin: origin, createdAt: t + 9, title: '住民の お知らせ');
      final water = makeNotice(
          origin: origin,
          createdAt: t + 8,
          category: NoticeCategory.water,
          role: SenderRole.official,
          title: '給水');
      final evac = makeNotice(
          origin: origin,
          createdAt: t + 1,
          category: NoticeCategory.evacuation,
          role: SenderRole.official,
          title: '避難');
      final training = makeNotice(
          origin: origin,
          createdAt: t + 10,
          category: NoticeCategory.evacuation,
          role: SenderRole.official,
          title: '$kTrainingPrefix避難');
      final sos = makeHelp(origin: origin, createdAt: t + 2);
      final ackedSos = makeHelp(origin: nodeIdOf(8), createdAt: t + 3);
      final ack = makeAck(origin, ackedSos, t + 4);
      final safe = makeHelp(origin: origin, createdAt: t + 5, type: ReportType.safe);
      final info = makeGroupInfo(origin: origin, createdAt: t);
      for (final e in [resident, water, evac, training, sos, ackedSos, ack, safe, info]) {
        await store.add(e, now: t + 20);
      }
      final order = store
          .messagesMissingFrom(<int>{}.contains, now: t + 20)
          .map((m) => m.msgId)
          .toList();
      int at(Envelope e) => order.indexOf(e.msgId);
      expect(store.sendTier(store.get(sos.msgId)!), 0);
      expect(store.sendTier(store.get(evac.msgId)!), 0);
      expect(store.sendTier(store.get(ackedSos.msgId)!), 4);
      expect(at(sos), lessThan(at(ack)));
      expect(at(evac), lessThan(at(info)));
      expect(at(info), lessThan(at(safe)));
      expect(at(safe), lessThan(at(water)));
      expect(at(water), lessThan(at(ackedSos)));
      expect(at(ackedSos), lessThan(at(resident)));
      expect(at(resident), lessThan(at(training)));
    });
  });

  group('古い版は中継しない', () {
    test('書きなおされた古いお知らせは送らず、目録には載せる。満杯なら先に消す', () async {
      final store = MessageStore(MemoryStoreBackend(), maxMessages: 10);
      await store.load();
      final old = makeNotice(origin: origin, createdAt: kT0, title: '給水 9時から');
      final rewrite = makeNotice(
          origin: origin, createdAt: kT0 + 60, title: '給水 10時から', supersedes: old.msgId);
      await store.add(old, now: kT0 + 1);
      await store.add(rewrite, now: kT0 + 61);
      final ids = store.messagesMissingFrom(<int>{}.contains, now: kT0 + 61).map((m) => m.msgId);
      expect(ids, [rewrite.msgId]);
      expect(store.inventory(now: kT0 + 61), contains(old.msgId));
      expect(store.hasRelayableNotIn({rewrite.msgId}, now: kT0 + 61), isFalse);

      // 満杯になったら、古い版から先に消える（住民の新しいお知らせより先）。
      for (var i = 0; i < 9; i++) {
        await store.add(
            makeNotice(origin: nodeIdOf(20 + i), createdAt: kT0 + 100 + i, title: 'n$i'),
            now: kT0 + 100 + i);
      }
      expect(store.contains(old.msgId), isFalse);
      expect(store.contains(rewrite.msgId), isTrue);
    });

    test('同じグループの古い group_info は中継しない。読み直しても同じ', () async {
      final backend = MemoryStoreBackend();
      final store = MessageStore(backend);
      await store.load();
      final v1 = makeGroupInfo(origin: origin, createdAt: kT0, name: 'v1');
      final v2 = makeGroupInfo(origin: origin, createdAt: kT0 + 100, name: 'v2');
      await store.add(v1, now: kT0);
      await store.add(v2, now: kT0 + 100);
      expect(store.get(v1.msgId)!.staleInfo, isTrue);
      expect(store.get(v2.msgId)!.staleInfo, isFalse);
      final ids = store.messagesMissingFrom(<int>{}.contains, now: kT0 + 100).map((m) => m.msgId);
      expect(ids, [v2.msgId]);

      // 読み直しても同じ判定になる。
      final reloaded = MessageStore(MemoryStoreBackend(backend.records));
      await reloaded.load();
      expect(reloaded.get(v1.msgId)!.staleInfo, isTrue);
    });
  });

  group('先出し', () {
    test('中継中のほかの人の SOS と、どのグループの避難情報も先に出す。返事済み・相手が持っているものは出さない', () async {
      final store = MessageStore(MemoryStoreBackend());
      await store.load();
      store.joinedGroupIds = {kGroupA};
      final t = kT0;
      final info = makeGroupInfo(origin: origin, createdAt: t);
      final sos = makeHelp(origin: nodeIdOf(30), createdAt: t + 5, groupId: kGroupB);
      final acked = makeHelp(origin: nodeIdOf(31), createdAt: t + 6, groupId: kGroupB);
      final ack = makeAck(origin, acked, t + 7);
      final evac = makeNotice(
          origin: nodeIdOf(32),
          createdAt: t + 3,
          groupId: kGroupB,
          category: NoticeCategory.evacuation,
          role: SenderRole.official,
          title: '避難');
      for (final e in [info, sos, acked, ack, evac]) {
        await store.add(e, now: t + 10);
      }
      final push = store.pushCandidates(now: t + 10).map((m) => m.msgId).toList();
      expect(push.first, sos.msgId);
      expect(push[1], evac.msgId);
      expect(push, contains(info.msgId));
      expect(push, isNot(contains(acked.msgId)));
      final skipped = store
          .pushCandidates(now: t + 10, skip: {sos.msgId})
          .map((m) => m.msgId)
          .toList();
      expect(skipped.first, evac.msgId);
    });
  });

  group('短いすれ違い', () {
    late FakeRadio radio;
    final nodes = <TestNode>[];

    setUp(() {
      radio = FakeRadio(clock: FakeClock(startEpochSeconds: kT0));
      nodes.clear();
    });

    tearDown(() async {
      for (final n in nodes) {
        await n.dispose();
      }
    });

    Future<TestNode> make(String id, int index) async {
      final n = TestNode(radio, id, index: index);
      nodes.add(n);
      await n.start();
      return n;
    }

    test('6 KB しか運べない一瞬のすれ違いでも、1,500 件の中から SOS と避難情報が先に届く', () async {
      final a = await make('A', 1);
      final b = await make('B', 2);
      final t = radio.clock.now();
      for (var i = 0; i < 1500; i++) {
        await a.store.add(
          makeNotice(origin: nodeIdOf(100 + i), createdAt: t - 600 + i % 500, title: 'n$i', text: noise(40, i)),
          now: t,
        );
      }
      final sos = makeHelp(origin: nodeIdOf(50), createdAt: t - 30, groupId: kGroupB);
      final evac = makeNotice(
          origin: nodeIdOf(51),
          createdAt: t - 60,
          groupId: kGroupB,
          category: NoticeCategory.evacuation,
          role: SenderRole.official,
          title: '〇〇川が あふれそうです。高台へ 避難してください');
      await a.store.add(sos, now: t);
      await a.store.add(evac, now: t);

      radio.linkByteLimit = 6000;
      radio.discover('B', 'A');
      await radio.settle();
      expect(radio.log.any((l) => l.contains('out_of_range')), isTrue);
      expect(b.store.contains(sos.msgId), isTrue);
      expect(b.store.contains(evac.msgId), isTrue);
    });

    test('短いすれ違いを何度か繰り返すと、受け取り直しなしで全部そろう', () async {
      final a = await make('A', 1);
      final b = await make('B', 2);
      final t = radio.clock.now();
      final all = <int>{};
      for (var i = 0; i < 200; i++) {
        final e = makeNotice(
            origin: nodeIdOf(100 + i), createdAt: t - 600 + i, title: 'n$i', text: noise(100, i));
        await a.store.add(e, now: t);
        all.add(e.msgId);
      }
      radio.linkByteLimit = 8000;
      var received = 0;
      b.store.addListener(() => received = b.store.count);
      for (var round = 0; round < 40 && b.store.count < all.length; round++) {
        radio.discover('B', 'A');
        await radio.settle();
        await radio.elapse(const Duration(seconds: 40));
      }
      expect(idsOf(b.store), all);
      expect(received, all.length);
    });
  });
}
