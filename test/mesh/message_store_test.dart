import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/core/categories.dart';
import 'package:kairanban/core/envelope.dart';
import 'package:kairanban/mesh/message_store.dart';
import 'package:kairanban/mesh/store_file.dart';

import 'helpers.dart';

void main() {
  final origin = nodeIdOf(1);
  final other = nodeIdOf(2);
  late MemoryStoreBackend backend;
  late MessageStore store;

  setUp(() async {
    backend = MemoryStoreBackend();
    store = MessageStore(backend);
    await store.load();
  });

  group('add', () {
    test('新規は added、同じ msg_id は duplicate、version は追加でだけ増える',
        () async {
      final n = makeNotice(origin: origin, createdAt: kT0);
      expect(store.version, 0);
      expect(await store.add(n, now: kT0), AddResult.added);
      expect(store.version, 1);
      expect(store.count, 1);
      expect(store.contains(n.msgId), isTrue);
      expect(store.get(n.msgId)!.receivedAt, kT0);
      expect(store.get(n.msgId)!.isLocal, isFalse);
      expect(store.get(n.msgId)!.read, isFalse);

      expect(await store.add(n, now: kT0 + 10), AddResult.duplicate);
      expect(await store.add(n.copyWith(hop: 5), now: kT0 + 10),
          AddResult.duplicate);
      expect(store.version, 1);
      expect(store.count, 1);

      await store.markRead(n.msgId);
      expect(store.version, 1);
    });

    test('自端末発信は isLocal・既読・receivedAt=createdAt', () async {
      final n = makeNotice(origin: origin, createdAt: kT0);
      await store.add(n, now: kT0 + 5, isLocal: true);
      final m = store.get(n.msgId)!;
      expect(m.isLocal, isTrue);
      expect(m.read, isTrue);
      expect(m.receivedAt, kT0);
    });

    test('hop が 64 以上は rejected、63 は保存される', () async {
      final a = makeNotice(origin: origin, createdAt: kT0, hop: 64);
      expect(await store.add(a, now: kT0), AddResult.rejected);
      final b = makeNotice(origin: origin, createdAt: kT0 + 1, hop: 63);
      expect(await store.add(b, now: kT0), AddResult.added);
      final c = makeNotice(origin: origin, createdAt: kT0 + 2, hop: 200);
      expect(await store.add(c, now: kT0), AddResult.rejected);
      expect(store.count, 1);
      expect(store.version, 1);
    });

    test('発信側の expires_at が過ぎていても受け取り、受信時刻 + 有効期間で期限を決める（C12）',
        () async {
      final n = makeNotice(
          origin: origin, createdAt: kT0, ttl: const Duration(hours: 1));
      expect(await store.add(n, now: kT0 + 3601), AddResult.added);
      final m = store.get(n.msgId)!;
      expect(store.localExpiresAt(m), kT0 + 3601 + 3600);
      expect(store.isExpired(m, kT0 + 3601 + 3600), isFalse);
      expect(store.isExpired(m, kT0 + 3601 + 3601), isTrue);
      // 中継時は expires_at を「created_at + 残り時間」に書き換える。
      final wire = m.wireBytesAt(kT0 + 3601 + 600,
          localExpiresAt: store.localExpiresAt(m));
      expect(Envelope.decode(wire).expiresAt, kT0 + 3000);
      expect(Envelope.decode(wire).msgId, n.msgId);
      // 有効期間が 0 以下や 30 日超は受け取らない。
      final zero =
          makeNotice(origin: origin, createdAt: kT0 + 1, ttl: Duration.zero);
      expect(await store.add(zero, now: kT0), AddResult.rejected);
      final tooLong = makeNotice(
          origin: origin, createdAt: kT0 + 2, ttl: const Duration(days: 31));
      expect(await store.add(tooLong, now: kT0), AddResult.rejected);
      // group_info は 365 日でよい。
      expect(await store.add(makeGroupInfo(origin: origin, createdAt: kT0), now: kT0),
          AddResult.added);
    });

    test('変更通知が出る', () async {
      var notified = 0;
      store.addListener(() => notified++);
      await store.add(makeNotice(origin: origin, createdAt: kT0), now: kT0);
      expect(notified, 1);
      await store.add(makeNotice(origin: origin, createdAt: kT0), now: kT0);
      expect(notified, 1);
    });
  });

  group('期限', () {
    test('発信者の時計が進んでいても受信時刻 + 有効期間で期限切れになる', () async {
      // 発信者の時計が 10 日進んでいる 12 時間 TTL のお知らせ。
      final n = makeNotice(
        origin: origin,
        createdAt: kT0 + 10 * 86400,
        ttl: const Duration(hours: 12),
      );
      expect(await store.add(n, now: kT0), AddResult.added);
      final m = store.get(n.msgId)!;
      expect(store.isExpired(m, kT0 + 12 * 3600), isFalse);
      expect(store.isExpired(m, kT0 + 12 * 3600 + 1), isTrue);
      expect(store.inventory(now: kT0 + 12 * 3600 + 1), isEmpty);
      expect(store.visibleNotices(now: kT0 + 12 * 3600 + 1), isEmpty);
    });

    test('purgeExpired は期限切れだけ消し、通知する', () async {
      final short = makeNotice(
          origin: origin, createdAt: kT0, ttl: const Duration(hours: 1));
      final long = makeNotice(
          origin: origin, createdAt: kT0 + 1, ttl: const Duration(days: 1));
      await store.add(short, now: kT0);
      await store.add(long, now: kT0);
      var notified = 0;
      store.addListener(() => notified++);
      await store.purgeExpired(kT0 + 3600);
      expect(store.count, 2);
      expect(notified, 0);
      await store.purgeExpired(kT0 + 3601);
      expect(store.count, 1);
      expect(store.contains(long.msgId), isTrue);
      expect(notified, 1);
      expect(store.version, 2);
    });

    test('tombstone は対象の expires_at + 24 時間まで保持される', () async {
      final target = makeNotice(
          origin: origin, createdAt: kT0, ttl: const Duration(hours: 1));
      // 発信者が短い期限を付けた tombstone でも、対象がある間は延長される。
      final ts = makeTombstone(
          origin: origin,
          target: target,
          createdAt: kT0 + 10,
          expiresAt: kT0 + 20);
      await store.add(target, now: kT0);
      await store.add(ts, now: kT0 + 10);
      expect(store.get(target.msgId)!.retracted, isTrue);

      await store.purgeExpired(kT0 + 3600 + 1);
      expect(store.contains(target.msgId), isFalse);
      // 対象が消えても、対象の expires_at + 24 時間までは残る。
      expect(store.contains(ts.msgId), isTrue);
      await store.purgeExpired(kT0 + 3600 + 24 * 3600);
      expect(store.contains(ts.msgId), isTrue);
      await store.purgeExpired(kT0 + 3600 + 24 * 3600 + 1);
      expect(store.contains(ts.msgId), isFalse);

      // 対象が残っている間は延長される。
      final target2 = makeNotice(
          origin: origin, createdAt: kT0 + 100, ttl: const Duration(hours: 1));
      final ts2 = makeTombstone(
          origin: origin,
          target: target2,
          createdAt: kT0 + 110,
          expiresAt: kT0 + 120);
      await store.add(target2, now: kT0 + 100);
      await store.add(ts2, now: kT0 + 110);
      await store.purgeExpired(kT0 + 3000);
      expect(store.contains(ts2.msgId), isTrue);
      expect(store.inventory(now: kT0 + 3000), contains(ts2.msgId));
      expect(store.get(ts2.msgId)!.retainUntil, kT0 + 100 + 3600 + 24 * 3600);

      // 保持期限は永続化され、再読み込み後も対象が消えた後の保持に効く。
      final reloaded = MessageStore(backend);
      await reloaded.load();
      expect(reloaded.get(ts2.msgId)!.retainUntil, kT0 + 100 + 3600 + 24 * 3600);
      await reloaded.purgeExpired(kT0 + 100 + 3600 + 1);
      expect(reloaded.contains(target2.msgId), isFalse);
      expect(reloaded.contains(ts2.msgId), isTrue);
    });

    test('tombstone が先に届いても対象を見た時点で保持期限が延びる', () async {
      final target = makeNotice(
          origin: origin, createdAt: kT0, ttl: const Duration(hours: 1));
      final ts = makeTombstone(
          origin: origin, target: target, createdAt: kT0 + 1, expiresAt: kT0 + 5);
      await store.add(ts, now: kT0 + 1);
      expect(store.get(ts.msgId)!.retainUntil, isNull);
      await store.add(target, now: kT0 + 2);
      // 保持期限は受信時刻 + 有効期間（この端末での期限）+ 24 時間。
      expect(store.get(ts.msgId)!.retainUntil, kT0 + 2 + 3600 + 24 * 3600);
      expect(store.get(target.msgId)!.retracted, isTrue);
      await store.purgeExpired(kT0 + 3603);
      expect(store.contains(ts.msgId), isTrue);
      final reloaded = MessageStore(backend);
      await reloaded.load();
      expect(reloaded.get(ts.msgId)!.retainUntil, kT0 + 2 + 3600 + 24 * 3600);
    });
  });

  group('tombstone / supersedes', () {
    test('tombstone が先でも後でも対象は取り消し済みになる', () async {
      final target = makeNotice(origin: origin, createdAt: kT0);
      final ts = makeTombstone(origin: origin, target: target, createdAt: kT0 + 1);

      // 後から tombstone。
      await store.add(target, now: kT0);
      expect(store.visibleNotices(now: kT0 + 2).length, 1);
      expect(await store.add(ts, now: kT0 + 2), AddResult.added);
      expect(store.get(target.msgId)!.retracted, isTrue);
      expect(store.visibleNotices(now: kT0 + 2), isEmpty);
      // 中継用には残る。
      expect(store.inventory(now: kT0 + 2), containsAll([target.msgId, ts.msgId]));

      // 先に tombstone。
      final s2 = MessageStore(MemoryStoreBackend());
      await s2.load();
      await s2.add(ts, now: kT0 + 2);
      expect(await s2.add(target, now: kT0 + 3), AddResult.added);
      expect(s2.get(target.msgId)!.retracted, isTrue);
      expect(s2.visibleNotices(now: kT0 + 3), isEmpty);
    });

    test('別グループの tombstone は効かない', () async {
      final target = makeNotice(origin: origin, createdAt: kT0);
      final fake = Envelope.create(
        kind: MessageKind.tombstone,
        groupId: kGroupB,
        originId: other,
        createdAt: kT0 + 1,
        expiresAt: kT0 + 100,
        category: NoticeCategory.general,
        role: SenderRole.official,
        supersedes: target.msgId,
        bodyPlain: Uint8List(0),
      );
      await store.add(target, now: kT0);
      await store.add(fake, now: kT0 + 1);
      expect(store.get(target.msgId)!.retracted, isFalse);
      expect(store.visibleNotices(now: kT0 + 1).length, 1);
    });

    test('supersedes 付き notice は対象を表示から外す（順序によらない）', () async {
      final old = makeNotice(origin: origin, createdAt: kT0, title: '古い');
      final fix = makeNotice(
          origin: origin,
          createdAt: kT0 + 60,
          title: '訂正',
          supersedes: old.msgId);

      await store.add(old, now: kT0);
      await store.add(fix, now: kT0 + 60);
      expect(store.get(old.msgId)!.supersededBy, fix.msgId);
      final visible = store.visibleNotices(now: kT0 + 60);
      expect(visible.map((m) => m.msgId), [fix.msgId]);

      final s2 = MessageStore(MemoryStoreBackend());
      await s2.load();
      await s2.add(fix, now: kT0 + 60);
      await s2.add(old, now: kT0 + 61);
      expect(s2.get(old.msgId)!.supersededBy, fix.msgId);
      expect(s2.visibleNotices(now: kT0 + 61).map((m) => m.msgId), [fix.msgId]);
    });

    test('tombstone は保存時に supersedes なし/本文ありを受け付けない', () {
      expect(
        () => Envelope(
          kind: MessageKind.tombstone,
          groupId: kGroupA,
          msgId: 1,
          createdAt: kT0,
          expiresAt: kT0 + 1,
          bodyPlain: Uint8List(0),
        ),
        throwsArgumentError,
      );
    });
  });

  group('inventory / messagesMissingFrom', () {
    test('inventory は新しい順・上限あり・期限切れを含まない', () async {
      final ids = <int>[];
      for (var i = 0; i < 10; i++) {
        final n = makeNotice(
            origin: origin,
            createdAt: kT0 + i * 10,
            ttl: Duration(hours: i == 3 ? 1 : 24));
        await store.add(n, now: kT0 + i * 10);
        ids.add(n.msgId);
      }
      final inv = store.inventory(now: kT0 + 100);
      expect(inv, ids.reversed.toList());
      expect(store.inventory(now: kT0 + 100, limit: 3),
          ids.reversed.take(3).toList());
      // i=3 は kT0+30+3600 で切れる。
      final later = store.inventory(now: kT0 + 30 + 3601);
      expect(later.length, 9);
      expect(later, isNot(contains(ids[3])));
    });

    test('messagesMissingFrom は group_info → tombstone → notice、role 降順、新しい順',
        () async {
      final notices = <Envelope>[
        makeNotice(
            origin: origin,
            createdAt: kT0 + 5,
            role: SenderRole.resident,
            title: 'r5'),
        makeNotice(
            origin: origin,
            createdAt: kT0 + 9,
            role: SenderRole.resident,
            title: 'r9'),
        makeNotice(
            origin: origin,
            createdAt: kT0 + 1,
            role: SenderRole.official,
            title: 'o1'),
        makeNotice(
            origin: origin,
            createdAt: kT0 + 7,
            role: SenderRole.staff,
            title: 's7'),
        makeNotice(
            origin: origin,
            createdAt: kT0 + 3,
            role: SenderRole.official,
            title: 'o3'),
      ];
      final info = makeGroupInfo(origin: origin, createdAt: kT0);
      final ts = makeTombstone(origin: origin, target: notices[0], createdAt: kT0 + 6);
      for (final e in [...notices, ts, info]) {
        await store.add(e, now: kT0 + 10);
      }
      final order = store
          .messagesMissingFrom(<int>{}.contains, now: kT0 + 10)
          .map((m) => m.kind == MessageKind.notice
              ? m.envelope.notice!.title
              : m.kind.name)
          .toList();
      // r5 は取り消されて本文を消した空殻になり、目録には載るが MESSAGE では送らない（C20）。
      expect(order, ['groupInfo', 'tombstone', 'o3', 'o1', 's7', 'r9']);
      expect(store.get(notices[0].msgId)!.isStub, isTrue);
      expect(store.inventory(now: kT0 + 10), contains(notices[0].msgId));

      final filtered = store.messagesMissingFrom(
          {info.msgId, notices[4].msgId, notices[1].msgId}.contains,
          now: kT0 + 10);
      expect(
          filtered
              .map((m) => m.kind == MessageKind.notice
                  ? m.envelope.notice!.title
                  : m.kind.name)
              .toList(),
          ['tombstone', 'o1', 's7']);
    });
  });

  group('表示', () {
    test('visibleNotices はグループで絞れ、group_info は含まない', () async {
      final a = makeNotice(origin: origin, createdAt: kT0, groupId: kGroupA);
      final b = makeNotice(origin: origin, createdAt: kT0 + 1, groupId: kGroupB);
      final info = makeGroupInfo(origin: origin, createdAt: kT0 + 2);
      for (final e in [a, b, info]) {
        await store.add(e, now: kT0 + 2);
      }
      expect(store.visibleNotices(now: kT0 + 2).map((m) => m.msgId),
          [b.msgId, a.msgId]);
      expect(
          store.visibleNotices(now: kT0 + 2, groupIds: {kGroupA}).map(
              (m) => m.msgId),
          [a.msgId]);
      expect(store.visibleNotices(now: kT0 + 2, groupIds: {}), isEmpty);
    });

    test('unreadCount / markRead / markAllRead', () async {
      final a = makeNotice(origin: origin, createdAt: kT0);
      final b = makeNotice(origin: origin, createdAt: kT0 + 1, groupId: kGroupB);
      final mine = makeNotice(origin: origin, createdAt: kT0 + 2, title: 'mine');
      await store.add(a, now: kT0);
      await store.add(b, now: kT0);
      await store.add(mine, now: kT0, isLocal: true);
      expect(store.unreadCount(now: kT0 + 2), 2);
      expect(store.unreadCount(now: kT0 + 2, groupIds: {kGroupB}), 1);
      await store.markRead(a.msgId);
      expect(store.unreadCount(now: kT0 + 2), 1);
      await store.markAllRead({a.msgId, b.msgId, 12345});
      expect(store.unreadCount(now: kT0 + 2), 0);
    });

    test('latestGroupInfo は最新の created_at を返す', () async {
      final g1 = makeGroupInfo(origin: origin, createdAt: kT0, name: '古い名前');
      final g2 = makeGroupInfo(origin: origin, createdAt: kT0 + 100, name: '新しい名前');
      final gb = makeGroupInfo(origin: origin, createdAt: kT0 + 200, groupId: kGroupB);
      await store.add(g2, now: kT0 + 200);
      await store.add(g1, now: kT0 + 200);
      await store.add(gb, now: kT0 + 200);
      expect(store.latestGroupInfo(kGroupA)!.envelope.groupInfo!.name, '新しい名前');
      expect(store.latestGroupInfo(kGroupB)!.msgId, gb.msgId);
      expect(store.latestGroupInfo(111111), isNull);
    });
  });

  group('上限と削除順', () {
    test('期限切れ → 未参加グループの古い順 → 参加グループの古い順', () async {
      final s = MessageStore(MemoryStoreBackend(), maxMessages: 5);
      await s.load();
      s.joinedGroupIds = {kGroupA};
      final joinedOld = makeNotice(origin: origin, createdAt: kT0, groupId: kGroupA);
      final joinedNew = makeNotice(origin: origin, createdAt: kT0 + 50, groupId: kGroupA);
      final otherOld = makeNotice(origin: origin, createdAt: kT0 + 10, groupId: kGroupB);
      final otherNew = makeNotice(origin: origin, createdAt: kT0 + 40, groupId: kGroupB);
      final expiring = makeNotice(
          origin: origin,
          createdAt: kT0 + 45,
          groupId: kGroupA,
          ttl: const Duration(seconds: 10));
      for (final e in [joinedOld, joinedNew, otherOld, otherNew, expiring]) {
        expect(await s.add(e, now: kT0 + 50), AddResult.added);
      }
      expect(s.count, 5);

      // 期限切れがあればそれから。
      // expiring は受信（kT0+50）+ 10 秒 = kT0+60 まで有効なので、その後に足す。
      final n1 = makeNotice(origin: origin, createdAt: kT0 + 60, groupId: kGroupB);
      expect(await s.add(n1, now: kT0 + 61), AddResult.added);
      expect(s.count, 5);
      expect(s.contains(expiring.msgId), isFalse);

      // 次は未参加グループの古い順。
      final n2 = makeNotice(origin: origin, createdAt: kT0 + 61, groupId: kGroupA);
      await s.add(n2, now: kT0 + 61);
      expect(s.contains(otherOld.msgId), isFalse);
      expect(s.contains(otherNew.msgId), isTrue);

      final n3 = makeNotice(origin: origin, createdAt: kT0 + 62, groupId: kGroupA);
      await s.add(n3, now: kT0 + 62);
      expect(s.contains(otherNew.msgId), isFalse);
      expect(s.contains(n1.msgId), isTrue);
      expect(s.contains(joinedOld.msgId), isTrue);

      // 未参加グループで残っているのは n1 だけ（新しくても参加グループより先）。
      final n4 = makeNotice(origin: origin, createdAt: kT0 + 63, groupId: kGroupA);
      await s.add(n4, now: kT0 + 63);
      expect(s.contains(n1.msgId), isFalse);
      expect(s.contains(joinedOld.msgId), isTrue);

      // 未参加がなくなったら参加グループの古い順。
      final n5 = makeNotice(origin: origin, createdAt: kT0 + 64, groupId: kGroupA);
      await s.add(n5, now: kT0 + 64);
      expect(s.contains(joinedOld.msgId), isFalse);
      expect(s.contains(joinedNew.msgId), isTrue);
      expect(idsOf(s), {joinedNew.msgId, n2.msgId, n3.msgId, n4.msgId, n5.msgId});
      expect(s.count, 5);
    });

    test('自端末発信は最後まで残る', () async {
      final s = MessageStore(MemoryStoreBackend(), maxMessages: 2);
      await s.load();
      final mine = makeNotice(origin: origin, createdAt: kT0, title: 'mine');
      await s.add(mine, now: kT0, isLocal: true);
      for (var i = 1; i <= 5; i++) {
        await s.add(makeNotice(origin: other, createdAt: kT0 + i), now: kT0 + i);
      }
      expect(s.count, 2);
      expect(s.contains(mine.msgId), isTrue);
    });
  });

  group('永続化', () {
    test('追加・既読・取消・削除が再読み込みで復元される', () async {
      final a = makeNotice(origin: origin, createdAt: kT0, title: 'a');
      final b = makeNotice(origin: origin, createdAt: kT0 + 1, title: 'b', text: 'x' * 500);
      final c = makeNotice(origin: origin, createdAt: kT0 + 2, title: 'c');
      final mine = makeNotice(origin: origin, createdAt: kT0 + 3, title: 'mine');
      final ts = makeTombstone(origin: origin, target: a, createdAt: kT0 + 4);
      final fix = makeNotice(
          origin: origin, createdAt: kT0 + 5, title: 'fix', supersedes: c.msgId);
      final info = makeGroupInfo(origin: origin, createdAt: kT0 + 6);
      await store.add(a, now: kT0 + 10);
      await store.add(b.copyWith(hop: 3), now: kT0 + 11);
      await store.add(c, now: kT0 + 12);
      await store.add(mine, now: kT0 + 13, isLocal: true);
      await store.add(ts, now: kT0 + 14);
      await store.add(fix, now: kT0 + 15);
      await store.add(info, now: kT0 + 16);
      await store.markRead(b.msgId);

      final reloaded = MessageStore(backend);
      await reloaded.load();
      expect(reloaded.count, 7);
      expect(idsOf(reloaded), idsOf(store));
      expect(reloaded.get(a.msgId)!.retracted, isTrue);
      expect(reloaded.get(a.msgId)!.receivedAt, kT0 + 10);
      final rb = reloaded.get(b.msgId)!;
      expect(rb.read, isTrue);
      expect(rb.envelope.hop, 3);
      expect(rb.envelope.notice!.text, 'x' * 500);
      expect(reloaded.get(c.msgId)!.supersededBy, fix.msgId);
      expect(reloaded.get(mine.msgId)!.isLocal, isTrue);
      expect(reloaded.get(mine.msgId)!.read, isTrue);
      expect(reloaded.get(mine.msgId)!.receivedAt, kT0 + 3);
      expect(reloaded.latestGroupInfo(kGroupA)!.msgId, info.msgId);
      // 更新レコードがあったので圧縮されている。
      expect(backend.rewriteCount, greaterThanOrEqualTo(1));
      expect(backend.records.length, 7);

      // 圧縮後もう一度読んでも同じ。
      final third = MessageStore(backend);
      await third.load();
      expect(third.get(a.msgId)!.retracted, isTrue);
      expect(third.get(b.msgId)!.read, isTrue);
      expect(third.get(c.msgId)!.supersededBy, fix.msgId);
      expect(third.version, 0);
    });

    test('削除はレコードに残り、再読み込みで消えている', () async {
      final s = MessageStore(backend, maxMessages: 2);
      await s.load();
      final a = makeNotice(origin: other, createdAt: kT0);
      final b = makeNotice(origin: other, createdAt: kT0 + 1);
      final c = makeNotice(origin: other, createdAt: kT0 + 2);
      await s.add(a, now: kT0);
      await s.add(b, now: kT0);
      await s.add(c, now: kT0);
      expect(s.contains(a.msgId), isFalse);
      final r = MessageStore(backend);
      await r.load();
      expect(idsOf(r), {b.msgId, c.msgId});
    });

    test('壊れたレコードは読み飛ばす', () async {
      final a = makeNotice(origin: origin, createdAt: kT0);
      await store.add(a, now: kT0);
      await backend.append(Uint8List.fromList([1, 0, 1, 2, 3]));
      await backend.append(Uint8List.fromList([9, 9]));
      await backend.append(Uint8List(0));
      final b = makeNotice(origin: origin, createdAt: kT0 + 1);
      await store.add(b, now: kT0);
      final r = MessageStore(backend);
      await r.load();
      expect(idsOf(r), {a.msgId, b.msgId});
    });

    test('既読が溜まると圧縮される', () async {
      final ids = <int>[];
      for (var i = 0; i < 20; i++) {
        final n = makeNotice(origin: origin, createdAt: kT0 + i);
        await store.add(n, now: kT0);
        ids.add(n.msgId);
      }
      expect(backend.rewriteCount, 0);
      for (var round = 0; round < 30; round++) {
        for (final id in ids) {
          store.get(id)!.read = false;
        }
        await store.markAllRead(ids.toSet());
      }
      expect(backend.rewriteCount, greaterThanOrEqualTo(1));
      // 20 件 × 30 回 = 600 更新のうち 500 を超えた時点で圧縮され、
      // 残りの更新だけが追記されている。
      expect(backend.records.length, lessThan(200));
      final r = MessageStore(backend);
      await r.load();
      expect(r.count, 20);
      expect(r.all.every((m) => m.read), isTrue);
    });
  });
}
