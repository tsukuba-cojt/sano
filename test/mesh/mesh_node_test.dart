import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/core/envelope.dart';
import 'package:kairanban/mesh/message_store.dart';
import 'package:kairanban/transport/fake_transport.dart';

import 'helpers.dart';

void main() {
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

  Future<TestNode> makeNode(String id, int index,
      {int sessionByteBudget = 65536, int maxInitiatorLinks = 2}) async {
    final n = TestNode(radio, id,
        index: index,
        sessionByteBudget: sessionByteBudget,
        maxInitiatorLinks: maxInitiatorLinks);
    nodes.add(n);
    await n.start();
    return n;
  }

  int linksOpened() => radio.log.where((l) => l.startsWith('link ')).length;

  int connectAttempts() =>
      radio.log.where((l) => l.startsWith('link ') || l.startsWith('connect ')).length;

  test('start / stop とトランスポート状態の反映', () async {
    final a = await makeNode('A', 1);
    await radio.settle();
    expect(a.node.running, isTrue);
    expect(a.node.poweredOn, isTrue);
    expect(a.node.scanning, isTrue);
    expect(a.node.permission, 'granted');
    expect(a.transport.config!.nodeId, a.nodeId);
    expect(a.node.recentLog.any((l) => l.contains('開始')), isTrue);
    await a.node.stop();
    await radio.settle();
    expect(a.node.running, isFalse);
    expect(a.node.scanning, isFalse);
    await a.node.setLowPower(true);
    await a.node.start(lowPower: true);
    expect(a.node.running, isTrue);
    expect(a.transport.lowPower, isTrue);
    await a.node.setLowPower(false);
    expect(a.transport.lowPower, isFalse);
  });

  test('5 ノードの鎖: 隣同士が順にすれ違うだけで端から端へ届く（epidemic）',
      () async {
    final chain = <TestNode>[];
    for (var i = 0; i < 5; i++) {
      chain.add(await makeNode('N$i', i + 1));
    }
    await radio.settle();
    final notice = makeNotice(
        origin: chain[0].nodeId,
        createdAt: radio.clock.now(),
        title: '〇〇小学校に 水が とどきました');
    expect(await chain[0].node.publish(notice), AddResult.added);
    expect(chain[0].store.get(notice.msgId)!.isLocal, isTrue);

    for (var i = 0; i < 4; i++) {
      // まだ届いていない。
      expect(chain[i + 1].store.contains(notice.msgId), isFalse);
      // 片方向の発見にして、1 回のすれ違いにつきリンク 1 本にする。
      radio.discover('N$i', 'N${i + 1}');
      await radio.settle();
      expect(chain[i + 1].store.contains(notice.msgId), isTrue,
          reason: 'N${i + 1} に届くはず');
      expect(chain[i + 1].store.get(notice.msgId)!.envelope.hop, i + 1);
      expect(chain[i + 1].node.totalMessagesReceived, 1);
      expect(chain[i + 1].node.lastReceivedAt, radio.clock.now());
      await radio.elapse(const Duration(seconds: 5));
    }
    for (final n in chain) {
      expect(n.node.activeSessions, 0);
      expect(n.transport.openLinkIds, isEmpty);
    }
    expect(chain[0].node.totalSessions, 1);
    expect(chain[2].node.totalSessions, 2);
    expect(chain[4].node.totalSessions, 1);
    // 鎖の末端は 4 回中継された内容を持つ。
    expect(chain[4].store.get(notice.msgId)!.envelope.notice!.title,
        '〇〇小学校に 水が とどきました');
    // すれ違いは 4 回だけ（重複接続なし）。
    expect(linksOpened(), 4);
  });

  test('双方が同時に発見しても 1 本だけ残り、両方の在庫が揃う', () async {
    final a = await makeNode('A', 1);
    final b = await makeNode('B', 2);
    final t = radio.clock.now();
    await a.node.publish(makeNotice(origin: a.nodeId, createdAt: t, title: 'a'));
    await b.node.publish(makeNotice(origin: b.nodeId, createdAt: t, title: 'b'));
    radio.bringNear('A', 'B');
    await radio.settle();
    expect(linksOpened(), 2);
    expect(idsOf(a.store), idsOf(b.store));
    expect(a.store.count, 2);
    expect(a.node.activeSessions, 0);
    expect(b.node.activeSessions, 0);
    expect(a.transport.openLinkIds, isEmpty);
    expect(b.transport.openLinkIds, isEmpty);
    expect(a.node.recentLog.any((l) => l.contains('重複セッション')), isTrue);
    // 重複の方は失敗扱いにならず、再接続は 60 秒抑制だけが効く。
    await radio.elapse(const Duration(seconds: 61));
    radio.bringNear('A', 'B');
    await radio.settle();
    expect(linksOpened(), greaterThanOrEqualTo(3));
  });

  test('同じ相手との再同期は 60 秒空け、保存内容が変わればすぐ再同期する',
      () async {
    final a = await makeNode('A', 1);
    final b = await makeNode('B', 2);
    final t = radio.clock.now();
    await a.node.publish(makeNotice(origin: a.nodeId, createdAt: t));
    radio.discover('A', 'B');
    await radio.settle();
    expect(linksOpened(), 1);
    expect(b.store.count, 1);
    expect(a.node.totalSessions, 1);

    // 10 秒後にまた見えても再接続しない。
    await radio.elapse(const Duration(seconds: 10));
    radio.discover('A', 'B');
    await radio.settle();
    expect(linksOpened(), 1);
    // B から見ても同様（node_id 単位で抑制）。
    radio.discover('B', 'A');
    await radio.settle();
    expect(linksOpened(), 1);

    // 60 秒経てば再接続する。
    await radio.elapse(const Duration(seconds: 51));
    radio.discover('A', 'B');
    await radio.settle();
    expect(linksOpened(), 2);
    expect(a.node.totalSessions, 2);

    // 直後に A が投稿すると、待たずに再接続して広げる。
    await radio.elapse(const Duration(seconds: 5));
    final fresh = makeNotice(
        origin: a.nodeId, createdAt: radio.clock.now(), title: '新しい投稿');
    await a.node.publish(fresh);
    await radio.settle();
    expect(linksOpened(), 3);
    expect(b.store.contains(fresh.msgId), isTrue);

    // B 側の内容が変わった（B が投稿）場合は B が発見時に再接続する。
    await radio.elapse(const Duration(seconds: 5));
    final fromB = makeNotice(
        origin: b.nodeId, createdAt: radio.clock.now(), title: 'B の投稿');
    // 発見イベントの経路で確認するため、投稿後の自動再接続が済んだ後に
    // 「見えた」ときにも抑制されないことを確認する。
    await b.node.publish(fromB);
    await radio.settle();
    expect(a.store.contains(fromB.msgId), isTrue);
    final opened = linksOpened();
    // 直後の発見では（内容が同じなので）再接続しない。
    radio.bringNear('A', 'B');
    await radio.settle();
    expect(linksOpened(), opened);
  });

  test('投稿の自動再接続は 60 秒以内に見えた相手にだけ行う', () async {
    final a = await makeNode('A', 1);
    final b = await makeNode('B', 2);
    radio.discover('A', 'B');
    await radio.settle();
    expect(linksOpened(), 1);
    await radio.elapse(const Duration(seconds: 120));
    expect(a.node.nearbyCount, 0);
    await a.node.publish(
        makeNotice(origin: a.nodeId, createdAt: radio.clock.now()));
    await radio.settle();
    expect(linksOpened(), 1);
    expect(b.store.count, 0);
    radio.discover('A', 'B');
    await radio.settle();
    expect(linksOpened(), 2);
    expect(b.store.count, 1);
  });

  test('Apple 由来でサービスのない相手は 15 分無視する', () async {
    final a = await makeNode('A', 1);
    radio.discover('A', 'ghost', viaApple: true);
    await radio.settle();
    expect(connectAttempts(), 1);
    expect(radio.log.last, contains('service_not_found'));
    expect(a.node.peers.single.failures, 1);
    expect(a.node.recentLog.any((l) => l.contains('サービスなし')), isTrue);

    await radio.elapse(const Duration(minutes: 5));
    radio.discover('A', 'ghost', viaApple: true);
    await radio.settle();
    expect(connectAttempts(), 1);

    await radio.elapse(const Duration(minutes: 9, seconds: 59));
    radio.discover('A', 'ghost', viaApple: true);
    await radio.settle();
    expect(connectAttempts(), 1);

    await radio.elapse(const Duration(seconds: 2));
    radio.discover('A', 'ghost', viaApple: true);
    await radio.settle();
    expect(connectAttempts(), 2);
  });

  test('接続に失敗した相手は 30 秒待つ', () async {
    final a = await makeNode('A', 1);
    await makeNode('B', 2);
    radio.unreachable.add('B');
    radio.discover('A', 'B');
    await radio.settle();
    expect(connectAttempts(), 1);
    expect(a.node.peers.single.failures, 1);
    await radio.elapse(const Duration(seconds: 29));
    radio.discover('A', 'B');
    await radio.settle();
    expect(connectAttempts(), 1);
    await radio.elapse(const Duration(seconds: 2));
    radio.unreachable.clear();
    radio.discover('A', 'B');
    await radio.settle();
    expect(connectAttempts(), 2);
    expect(linksOpened(), 1);
    expect(a.node.peers.single.failures, 0);
  });

  test('central として同時に張るリンクは 2 本まで', () async {
    final a = await makeNode('A', 1);
    final others = <TestNode>[];
    for (var i = 0; i < 4; i++) {
      final n = await makeNode('P$i', 10 + i);
      await n.node.publish(makeNotice(
          origin: n.nodeId, createdAt: radio.clock.now(), title: 'p$i'));
      others.add(n);
    }
    // 4 台を同時に発見。セッションが終わる前に判断するため settle しない。
    for (var i = 0; i < 4; i++) {
      radio.discover('A', 'P$i');
    }
    await radio.settle();
    expect(linksOpened(), 2);
    expect(a.store.count, 2);
    expect(a.node.activeSessions, 0);
    // 空いたら残りも接続する。
    for (var i = 0; i < 4; i++) {
      radio.discover('A', 'P$i');
    }
    await radio.settle();
    expect(linksOpened(), 4);
    expect(a.store.count, 4);
  });

  test('nearbyCount は直近 60 秒に見えた端末数', () async {
    final a = await makeNode('A', 1);
    await makeNode('B', 2);
    await makeNode('C', 3);
    radio.discover('A', 'B');
    radio.discover('A', 'C');
    radio.discover('A', 'B');
    await radio.settle();
    expect(a.node.nearbyCount, 2);
    await radio.elapse(const Duration(seconds: 61));
    expect(a.node.nearbyCount, 0);
    radio.discover('A', 'C');
    await radio.settle();
    expect(a.node.nearbyCount, 1);
  });

  test('取り消しも広がり、相手の表示から消える', () async {
    final a = await makeNode('A', 1);
    final b = await makeNode('B', 2);
    final t = radio.clock.now();
    final notice = makeNotice(origin: a.nodeId, createdAt: t);
    await a.node.publish(notice);
    radio.discover('A', 'B');
    await radio.settle();
    expect(b.store.visibleNotices(now: radio.clock.now()).length, 1);

    await radio.elapse(const Duration(seconds: 10));
    final ts = makeTombstone(
        origin: a.nodeId, target: notice, createdAt: radio.clock.now());
    await a.node.publish(ts);
    await radio.settle();
    expect(b.store.contains(ts.msgId), isTrue);
    expect(b.store.get(notice.msgId)!.retracted, isTrue);
    expect(b.store.visibleNotices(now: radio.clock.now()), isEmpty);
    expect(b.store.inventory(now: radio.clock.now()).length, 2);
  });

  test('停止中は発見しても接続せず、停止で進行中のセッションを閉じる', () async {
    final a = await makeNode('A', 1);
    await makeNode('B', 2);
    await a.node.stop();
    await radio.settle();
    radio.discover('A', 'B');
    await radio.settle();
    expect(connectAttempts(), 0);
    await a.node.start();
    radio.discover('A', 'B');
    await radio.settle();
    expect(linksOpened(), 1);
    expect(a.node.activeSessions, 0);
  });

  test('推奨ログは 100 行まで', () async {
    final a = await makeNode('A', 1);
    for (var i = 0; i < 150; i++) {
      await a.node.publish(makeNotice(
          origin: a.nodeId, createdAt: radio.clock.now(), title: 't$i'));
    }
    expect(a.node.recentLog.length, 100);
    expect(a.node.recentLog.last, contains('投稿'));
  });

  test('publish の重複は duplicate で、再接続を起こさない', () async {
    final a = await makeNode('A', 1);
    await makeNode('B', 2);
    final n = makeNotice(origin: a.nodeId, createdAt: radio.clock.now());
    await a.node.publish(n);
    radio.discover('A', 'B');
    await radio.settle();
    expect(linksOpened(), 1);
    expect(await a.node.publish(n), AddResult.duplicate);
    await radio.settle();
    expect(linksOpened(), 1);
    expect(a.store.version, 1);
    expect(a.store.get(n.msgId)!.kind, MessageKind.notice);
  });
}
