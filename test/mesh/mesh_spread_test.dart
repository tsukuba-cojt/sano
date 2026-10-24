/// 多数の端末で、すべての種類のメッセージが行き渡るか（epidemic 中継の網羅テスト）。
///
/// - 発見の通知は最初の 1 回だけ（iOS の背面のように繰り返し来ない）とする。
/// - 電波の届く範囲は [FakeRadio.allowConnect] で隣どうしに限る。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/core/categories.dart';
import 'package:kairanban/core/envelope.dart';
import 'package:kairanban/core/report.dart';
import 'package:kairanban/mesh/mesh_node.dart';
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
      place: '〇〇町',
      ext: info.encode(),
    ).encode(),
  );
}

Envelope makeAck({
  required Uint8List origin,
  required Envelope target,
  required int createdAt,
}) {
  return Envelope.create(
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
}

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

  Future<TestNode> makeNode(
    String id,
    int index, {
    int sessionByteBudget = 65536,
  }) async {
    final n = TestNode(
      radio,
      id,
      index: index,
      sessionByteBudget: sessionByteBudget,
    );
    nodes.add(n);
    await n.start();
    return n;
  }

  /// 全端末が同じ msg_id の集合を持っているか。
  void expectConverged(List<TestNode> group, Set<int> expected) {
    for (final n in group) {
      expect(idsOf(n.store), expected, reason: '${n.id} に届いていないものがある');
    }
  }

  test('12 台の一列（隣どうしだけ電波が届く・発見は最初の 1 回）で、全種類が端から端まで届き、あとから出したものも広がる', () async {
    const count = 12;
    final line = <TestNode>[];
    for (var i = 0; i < count; i++) {
      line.add(await makeNode('N$i', i + 1));
    }
    int indexOf(String id) => int.parse(id.substring(1));
    radio.allowConnect = (from, to) =>
        (indexOf(from.peerId) - indexOf(to.peerId)).abs() == 1;
    // 発見は 1 回だけ。半分の組は片方向だけ（受信リンクだけで知る側がある）。
    for (var i = 0; i + 1 < count; i++) {
      radio.discover('N$i', 'N${i + 1}');
      if (i.isEven) {
        radio.discover('N${i + 1}', 'N$i');
      }
    }
    await radio.settle();

    final all = <int>{};
    Future<Envelope> post(int at, Envelope e) async {
      await line[at].node.publish(e);
      all.add(e.msgId);
      return e;
    }

    var t = radio.clock.now();
    final info = await post(
      0,
      makeGroupInfo(origin: line[0].nodeId, createdAt: t),
    );
    final notice = await post(
      0,
      makeNotice(origin: line[0].nodeId, createdAt: t, title: '給水'),
    );
    final help = await post(
      11,
      makeHelp(origin: line[11].nodeId, createdAt: t),
    );
    await radio.elapse(const Duration(minutes: 3));
    expectConverged(line, all);
    expect(info.kind, MessageKind.groupInfo);

    // あとから出したもの（書きなおし・取り消し・受け取りました・別の知らせ）も広がる。
    t = radio.clock.now();
    final rewrite = await post(
      0,
      makeNotice(
        origin: line[0].nodeId,
        createdAt: t,
        title: '給水（場所変更）',
        supersedes: notice.msgId,
      ),
    );
    final other = await post(
      5,
      makeNotice(origin: line[5].nodeId, createdAt: t, title: '炊き出し'),
    );
    await post(0, makeAck(origin: line[0].nodeId, target: help, createdAt: t));
    await post(
      6,
      makeHelp(origin: line[6].nodeId, createdAt: t, type: ReportType.safe),
    );
    await radio.elapse(const Duration(seconds: 10));
    await post(
      5,
      makeTombstone(
        origin: line[5].nodeId,
        target: other,
        createdAt: radio.clock.now(),
      ),
    );
    await radio.elapse(const Duration(minutes: 4));
    expectConverged(line, all);

    final now = radio.clock.now();
    for (final n in line) {
      final visible = n.store
          .visibleNotices(now: now)
          .map((m) => m.msgId)
          .toSet();
      expect(visible, {rewrite.msgId}, reason: n.id);
      expect(n.store.ackFor(help.msgId), isNotNull, reason: n.id);
    }
  });

  test('2 つの集まりの間を 1 台が行き来すると、両方の集まりに全部が届く', () async {
    final x = <TestNode>[
      for (var i = 0; i < 4; i++) await makeNode('X$i', 10 + i),
    ];
    final y = <TestNode>[
      for (var i = 0; i < 4; i++) await makeNode('Y$i', 20 + i),
    ];
    final carrier = await makeNode('M', 30);
    var carrierIn = 'X';
    String clusterOf(String id) => id == 'M' ? carrierIn : id.substring(0, 1);
    radio.allowConnect = (from, to) =>
        clusterOf(from.peerId) == clusterOf(to.peerId);

    void meetCluster(List<TestNode> cluster) {
      for (final a in [...cluster, carrier]) {
        for (final b in [...cluster, carrier]) {
          if (a != b) {
            radio.discover(a.id, b.id);
          }
        }
      }
    }

    final all = <int>{};
    final t = radio.clock.now();
    for (final n in [...x, ...y]) {
      final e = makeNotice(
        origin: n.nodeId,
        createdAt: t,
        title: 'from ${n.id}',
      );
      await n.node.publish(e);
      all.add(e.msgId);
    }
    meetCluster(x);
    meetCluster(y);
    await radio.elapse(const Duration(minutes: 2));
    final xIds = idsOf(x.first.store);
    expect(xIds.length, 4);
    expect(idsOf(carrier.store), xIds);

    // 運び役が Y へ移動（着いたときに 1 回だけ発見される）。
    carrierIn = 'Y';
    meetCluster(y);
    await radio.elapse(const Duration(minutes: 3));
    expectConverged([...y, carrier], all);

    // X へ戻る。
    carrierIn = 'X';
    meetCluster(x);
    await radio.elapse(const Duration(minutes: 3));
    expectConverged([...x, ...y, carrier], all);
  });

  test('1 回のすれ違いで送りきれない量は、続けて同期して全部渡す（送信上限での打ち切り）', () async {
    final a = await makeNode('A', 1, sessionByteBudget: 4096);
    final b = await makeNode('B', 2, sessionByteBudget: 4096);
    final all = <int>{};
    final t = radio.clock.now();
    // 圧縮で縮まないよう、ばらばらの文字で本文を作る。
    var seed = 12345;
    String noise(int n) {
      final buf = StringBuffer();
      for (var k = 0; k < n; k++) {
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
        buf.writeCharCode(0x4E00 + seed % 0x5000);
      }
      return buf.toString();
    }

    for (var i = 0; i < 40; i++) {
      final e = makeNotice(
        origin: a.nodeId,
        createdAt: t - i,
        title: 'お知らせ $i',
        text: noise(300),
      );
      await a.node.publish(e);
      all.add(e.msgId);
    }
    radio.discover('B', 'A'); // 発見は 1 回だけ
    await radio.settle();
    expect(b.store.count, lessThan(40));
    expect(b.node.sessions, isEmpty);
    await radio.elapse(const Duration(minutes: 2));
    expect(idsOf(b.store), all);
    // 送りきるまで 60 秒待たずに続けている（数秒おき）。
    expect(
      radio.log.where((l) => l.startsWith('link ')).length,
      greaterThan(3),
    );
  });

  test('新しく受け取ったものは、同期したばかりの別の相手にもすぐ渡す（60 秒を待たない）', () async {
    final a = await makeNode('A', 1);
    await makeNode('B', 2);
    final c = await makeNode('C', 3);
    // B は A と C の両方を発見している。A と C は互いに届かない。
    radio.allowConnect = (from, to) => from.peerId == 'B' || to.peerId == 'B';
    radio.discover('B', 'A');
    radio.discover('B', 'C');
    await radio.settle();
    await radio.elapse(const Duration(seconds: 5));
    final e = makeNotice(
      origin: a.nodeId,
      createdAt: radio.clock.now(),
      title: '急ぎ',
    );
    await a.node.publish(e);
    // B が A と同期し直す（60 秒以内）→ 受け取ったらすぐ C へ。
    await radio.elapse(
      const Duration(seconds: kResyncIntervalSeconds + kMeshTickSeconds),
    );
    expect(c.store.contains(e.msgId), isTrue);
  });
}
