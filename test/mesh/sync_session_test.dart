import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/core/envelope.dart';
import 'package:kairanban/core/frames.dart';
import 'package:kairanban/mesh/message_store.dart';
import 'package:kairanban/mesh/store_file.dart';
import 'package:kairanban/mesh/sync_session.dart';
import 'package:kairanban/mesh/transport.dart';
import 'package:kairanban/transport/fake_transport.dart';

import 'helpers.dart';

/// トランスポートを購読し、リンクが開いたら SyncSession を作る最小の土台。
class Peer {
  Peer(
    this.radio,
    this.id, {
    required int index,
    this.sessionByteBudget = 65536,
    this.autoSession = true,
    this.caps = kDefaultCaps,
    StoreBackend? backend,
  })  : transport = radio.createTransport(id),
        nodeId = nodeIdOf(index) {
    store = MessageStore(backend ?? MemoryStoreBackend());
    transport.events.listen(_onEvent);
  }

  final FakeRadio radio;
  final String id;
  final FakeTransport transport;
  final Uint8List nodeId;
  final int sessionByteBudget;

  /// false なら LinkOpened でセッションを作らない（手動応答のテスト用）。
  final bool autoSession;

  /// HELLO に載せる能力ビット（旧版の模擬に使う）。
  final int caps;

  late final MessageStore store;
  final List<SyncSession> sessions = <SyncSession>[];
  final List<LinkOpened> opened = <LinkOpened>[];
  final List<LinkClosed> closed = <LinkClosed>[];
  final List<Uint8List> received = <Uint8List>[];
  final List<String> log = <String>[];

  SyncSession get session => sessions.single;

  Future<void> start() async {
    await store.load();
    await transport.start(TransportConfig(nodeId: nodeId));
  }

  void _onEvent(TransportEvent e) {
    switch (e) {
      case LinkOpened():
        opened.add(e);
        if (autoSession) {
          final s = SyncSession(
            linkId: e.linkId,
            peerId: e.peerId,
            initiator: e.initiator,
            maxChunk: e.maxChunk,
            store: store,
            nodeId: nodeId,
            send: (c) => transport.send(e.linkId, c),
            close: () => transport.close(e.linkId),
            now: radio.clock.now,
            sessionByteBudget: sessionByteBudget,
            log: log.add,
            createTimer: radio.clock.createTimer,
            caps: caps,
          );
          sessions.add(s);
          unawaited(s.start());
        }
      case LinkData():
        received.add(e.data);
        for (final s in sessions) {
          if (s.linkId == e.linkId) {
            s.onData(e.data);
          }
        }
      case LinkClosed():
        closed.add(e);
        for (final s in sessions) {
          if (s.linkId == e.linkId) {
            s.onClosed();
          }
        }
      default:
        break;
    }
  }
}

/// 受信バイト列をフレームに分解する（検証用）。
List<Frame> framesOf(List<Uint8List> chunks) {
  final parser = FrameParser();
  final out = <Frame>[];
  for (final c in chunks) {
    parser.addChunk(c);
    Frame? f;
    while ((f = parser.nextFrame()) != null) {
      out.add(f!);
    }
  }
  return out;
}

void main() {
  late FakeRadio radio;
  late Peer a;
  late Peer b;

  setUp(() {
    radio = FakeRadio(clock: FakeClock(startEpochSeconds: kT0));
  });

  Future<void> connectAB() async {
    await a.start();
    await b.start();
    await radio.settle();
    await a.transport.connect('B');
    await radio.settle();
  }

  test('続けて送るお知らせは 1 回の書き込みに詰める（maxChunk いっぱいまで）', () async {
    radio = FakeRadio(
        clock: FakeClock(startEpochSeconds: kT0), defaultMaxChunk: 512);
    a = Peer(radio, 'A', index: 1);
    b = Peer(radio, 'B', index: 2);
    final t = radio.clock.now();
    for (var i = 0; i < 40; i++) {
      await a.store.add(
          makeNotice(origin: a.nodeId, createdAt: t - 100 + i, text: '水$i'),
          now: t,
          isLocal: true);
    }
    await connectAB();
    expect(b.store.count, 40);
    expect(b.session.messagesReceived, 40);
    final total = b.received.fold<int>(0, (n, c) => n + c.length);
    expect(b.received.every((c) => c.length <= 512), isTrue);
    // 1 件ずつ書けば 40 回を超える。詰めればほぼ total / 512 回。
    expect(b.received.length, lessThan(total ~/ 512 + 10));
    expect(framesOf(b.received).where((f) => f.type == FrameType.message).length,
        40);
  });

  test('ばらばらな在庫の 2 ノードが同期後に同じ内容になり、開始側が閉じる', () async {
    a = Peer(radio, 'A', index: 1);
    b = Peer(radio, 'B', index: 2);
    final t = radio.clock.now();
    for (var i = 0; i < 5; i++) {
      await a.store.add(
          makeNotice(origin: a.nodeId, createdAt: t - 100 + i, text: 'A$i' * 40),
          now: t,
          isLocal: true);
    }
    for (var i = 0; i < 3; i++) {
      await b.store.add(makeNotice(origin: b.nodeId, createdAt: t - 50 + i),
          now: t, isLocal: true);
    }
    await b.store.add(makeGroupInfo(origin: b.nodeId, createdAt: t - 10),
        now: t, isLocal: true);
    final shared = makeNotice(origin: nodeIdOf(9), createdAt: t - 200);
    await a.store.add(shared, now: t);
    await b.store.add(shared, now: t);

    await connectAB();

    expect(a.session.state, SessionState.done);
    expect(b.session.state, SessionState.done);
    expect(a.session.succeeded, isTrue);
    expect(b.session.succeeded, isTrue);
    expect(a.session.initiator, isTrue);
    expect(b.session.initiator, isFalse);
    expect(a.store.count, 10);
    expect(idsOf(a.store), idsOf(b.store));
    expect(a.session.messagesSent, 5);
    expect(b.session.messagesSent, 4);
    expect(a.session.messagesReceived, 4);
    expect(b.session.messagesReceived, 5);
    expect(a.session.peerNodeId, b.nodeId);
    expect(b.session.peerNodeId, a.nodeId);
    expect(a.session.peerStoreCount, 5);
    expect(b.session.peerStoreCount, 6);

    // hop は受信側で +1 される（shared は直接入れたので 0 のまま）。
    for (final m in a.store.all) {
      final expected = m.isLocal || m.msgId == shared.msgId ? 0 : 1;
      expect(m.envelope.hop, expected, reason: '$m');
    }

    // B が受け取ったフレーム列: HELLO, INVENTORY, INVENTORY_END, MESSAGE×5,
    // MESSAGES_END, STORED（保存確認）, BYE。最後は BYE（開始側 A が送る）。
    final framesAtB = framesOf(b.received).map((f) => f.type).toList();
    expect(framesAtB.first, FrameType.hello);
    expect(framesAtB.last, FrameType.bye);
    expect(framesAtB.where((t) => t == FrameType.message).length, 5);
    expect(framesAtB.indexOf(FrameType.inventoryEnd),
        lessThan(framesAtB.indexOf(FrameType.message)));
    // 相手の在庫を受け取るまで MESSAGE は出さない: A は B の INVENTORY_END の
    // 後にだけ MESSAGE を送っている（B が受けたのも同じ順）。
    final framesAtA = framesOf(a.received).map((f) => f.type).toList();
    expect(framesAtA.last, FrameType.stored);
    expect(framesAtA.indexOf(FrameType.messagesEnd),
        lessThan(framesAtA.indexOf(FrameType.stored)));
    expect(framesAtA, isNot(contains(FrameType.bye)));

    // リンクは閉じている。
    expect(a.transport.openLinkIds, isEmpty);
    expect(b.transport.openLinkIds, isEmpty);
    expect(a.closed.length, 1);
    expect(b.closed.length, 1);
    // 開始側は BYE を書き終えたら閉じ、応答側も BYE を受けたら閉じる（どちらが
    // 先でもよい。送信をまとめて書くようにしてから順は決まらない）。
    expect(radio.log.where((l) => l.startsWith('closed ')).length, 1);
    // 送った MESSAGE の優先順: group_info が先。
    final messagesAtA = framesOf(a.received)
        .where((f) => f.type == FrameType.message)
        .map((f) => Envelope.decode(f.payload).kind)
        .toList();
    expect(messagesAtA.first, MessageKind.groupInfo);
  });

  test('双方が対応していれば目録を要約（INVENTORY_FILTER）で送り、同じ内容にそろう', () async {
    a = Peer(radio, 'A', index: 1);
    b = Peer(radio, 'B', index: 2);
    final t = radio.clock.now();
    for (var i = 0; i < 20; i++) {
      await a.store.add(makeNotice(origin: nodeIdOf(30 + i), createdAt: t - i), now: t);
    }
    await b.store.add(makeNotice(origin: nodeIdOf(80), createdAt: t - 5), now: t);
    await connectAB();
    expect(a.session.succeeded, isTrue);
    expect(idsOf(a.store), idsOf(b.store));
    final framesAtB = framesOf(b.received).map((f) => f.type).toList();
    expect(framesAtB, contains(FrameType.inventoryFilter));
    expect(framesAtB, isNot(contains(FrameType.inventory)));
  });

  test('要約に対応していない旧版の相手とは、一覧（INVENTORY）で同期できる', () async {
    a = Peer(radio, 'A', index: 1);
    b = Peer(radio, 'B', index: 2, caps: kDefaultCaps & ~kCapInventoryFilter);
    final t = radio.clock.now();
    for (var i = 0; i < 20; i++) {
      await a.store.add(makeNotice(origin: nodeIdOf(30 + i), createdAt: t - i), now: t);
    }
    for (var i = 0; i < 3; i++) {
      await b.store.add(makeNotice(origin: nodeIdOf(90 + i), createdAt: t - i), now: t);
    }
    await connectAB();
    expect(a.session.succeeded, isTrue);
    expect(b.session.succeeded, isTrue);
    expect(a.store.count, 23);
    expect(idsOf(a.store), idsOf(b.store));
    final framesAtB = framesOf(b.received).map((f) => f.type).toList();
    final framesAtA = framesOf(a.received).map((f) => f.type).toList();
    expect(framesAtB, contains(FrameType.inventory));
    expect(framesAtB, isNot(contains(FrameType.inventoryFilter)));
    expect(framesAtA, isNot(contains(FrameType.inventoryFilter)));
  });

  test('同じものを持っていれば何も送らない', () async {
    a = Peer(radio, 'A', index: 1);
    b = Peer(radio, 'B', index: 2);
    final t = radio.clock.now();
    for (var i = 0; i < 3; i++) {
      final n = makeNotice(origin: nodeIdOf(7), createdAt: t - i);
      await a.store.add(n, now: t);
      await b.store.add(n, now: t);
    }
    await connectAB();
    expect(a.session.succeeded, isTrue);
    expect(b.session.succeeded, isTrue);
    expect(a.session.messagesSent, 0);
    expect(b.session.messagesSent, 0);
    expect(a.store.version, 3);
    expect(b.store.version, 3);
  });

  test('バイト上限に達したら送信を打ち切り、それでも正常に終わる', () async {
    a = Peer(radio, 'A', index: 1, sessionByteBudget: 2500);
    b = Peer(radio, 'B', index: 2);
    final t = radio.clock.now();
    // 圧縮が効かない（擬似乱数の漢字）本文で 1 件 600 バイト程度にする。
    var seed = 12345;
    String noise(int chars) {
      final sb = StringBuffer();
      for (var k = 0; k < chars; k++) {
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
        sb.writeCharCode(0x4E00 + (seed >> 8) % 0x2000);
      }
      return sb.toString();
    }

    for (var i = 0; i < 30; i++) {
      await a.store.add(
          makeNotice(
              origin: a.nodeId, createdAt: t - 1000 + i, text: noise(200)),
          now: t,
          isLocal: true);
    }
    await connectAB();
    expect(a.session.succeeded, isTrue);
    expect(b.session.succeeded, isTrue);
    expect(a.session.budgetExhausted, isTrue);
    expect(a.session.messagesSent, lessThan(30));
    expect(a.session.messagesSent, greaterThan(0));
    expect(b.store.count, a.session.messagesSent);
    // 新しい順に送られる。
    final sent = b.store.all.map((m) => m.envelope.createdAt).toList()..sort();
    expect(sent.first, t - 1000 + 30 - a.session.messagesSent);
    // 打ち切っても MESSAGES_END と BYE は送る。
    final types = framesOf(b.received).map((f) => f.type).toList();
    expect(types, contains(FrameType.messagesEnd));
    expect(types.last, FrameType.bye);
  });

  test('maxChunk が小さくてもフレームは正しく組み立てられる', () async {
    radio = FakeRadio(clock: FakeClock(startEpochSeconds: kT0), defaultMaxChunk: 7);
    a = Peer(radio, 'A', index: 1);
    b = Peer(radio, 'B', index: 2);
    final t = radio.clock.now();
    await a.store.add(
        makeNotice(origin: a.nodeId, createdAt: t, text: 'ながい本文 ' * 100),
        now: t,
        isLocal: true);
    await connectAB();
    expect(a.session.succeeded, isTrue);
    expect(b.store.count, 1);
    expect(b.received.every((c) => c.length <= 7), isTrue);
  });

  test('不正なフレーム（length 超過）を受けるとリンクを切る', () async {
    a = Peer(radio, 'A', index: 1);
    b = Peer(radio, 'B', index: 2, autoSession: false);
    await a.start();
    await b.start();
    await radio.settle();
    await a.transport.connect('B');
    await radio.settle();
    expect(a.session.state, SessionState.hello);
    // length = 9000 のフレームを B から流す。
    final bLink = b.opened.single.linkId;
    b.transport.injectRaw(bLink, Uint8List.fromList([0x28, 0x23, 0x01, 0, 0]));
    await radio.settle();
    expect(a.session.state, SessionState.failed);
    expect(a.session.failureReason, contains('不正なフレーム'));
    expect(a.transport.openLinkIds, isEmpty);
    expect(b.transport.openLinkIds, isEmpty);
    expect(b.closed.length, 1);
  });

  test('length 0 のフレームも不正', () async {
    a = Peer(radio, 'A', index: 1);
    b = Peer(radio, 'B', index: 2, autoSession: false);
    await a.start();
    await b.start();
    await radio.settle();
    await a.transport.connect('B');
    await radio.settle();
    b.transport.injectRaw(b.opened.single.linkId, Uint8List.fromList([0, 0]));
    await radio.settle();
    expect(a.session.state, SessionState.failed);
    expect(a.transport.openLinkIds, isEmpty);
  });

  test('HELLO が 5 秒来なければ閉じる', () async {
    a = Peer(radio, 'A', index: 1);
    b = Peer(radio, 'B', index: 2, autoSession: false);
    await a.start();
    await b.start();
    await radio.settle();
    await a.transport.connect('B');
    await radio.settle();
    expect(a.session.state, SessionState.hello);
    await radio.elapse(const Duration(seconds: 4));
    expect(a.session.state, SessionState.hello);
    expect(a.transport.openLinkIds.length, 1);
    await radio.elapse(const Duration(seconds: 1));
    expect(a.session.state, SessionState.failed);
    expect(a.session.failureReason, contains('HELLO'));
    expect(a.transport.openLinkIds, isEmpty);
    // BYE を送ってから閉じている。
    final types = framesOf(b.received).map((f) => f.type).toList();
    expect(types.last, FrameType.bye);
  });

  test('全体 30 秒で打ち切る', () async {
    a = Peer(radio, 'A', index: 1);
    b = Peer(radio, 'B', index: 2, autoSession: false);
    await a.start();
    await b.start();
    await radio.settle();
    await a.transport.connect('B');
    await radio.settle();
    // HELLO だけ返して黙る相手。
    final bLink = b.opened.single.linkId;
    await b.transport.send(
        bLink, Frame.hello(nodeId: b.nodeId, storeCount: 0).encode());
    await radio.settle();
    expect(a.session.state, SessionState.inventory);
    await radio.elapse(const Duration(seconds: 29));
    expect(a.session.state, SessionState.inventory);
    await radio.elapse(const Duration(seconds: 1));
    expect(a.session.state, SessionState.failed);
    expect(a.session.failureReason, contains('タイムアウト'));
    expect(a.transport.openLinkIds, isEmpty);
  });

  test('不正な封筒は捨てるがセッションは続き、受信は hop+1 で保存される', () async {
    a = Peer(radio, 'A', index: 1);
    b = Peer(radio, 'B', index: 2, autoSession: false);
    await a.start();
    await b.start();
    await radio.settle();
    await a.transport.connect('B');
    await radio.settle();
    final bLink = b.opened.single.linkId;
    final t = radio.clock.now();
    final good = makeNotice(origin: b.nodeId, createdAt: t - 5, hop: 2);
    final expired = makeNotice(
        origin: b.nodeId, createdAt: t - 7200, ttl: const Duration(hours: 1));
    final tooFar = makeNotice(origin: b.nodeId, createdAt: t - 6, hop: 63);
    final garbage = Uint8List.fromList(List.generate(40, (i) => i * 7 & 0xFF));
    Future<void> sendFrame(Frame f) async {
      final bytes = f.encode();
      for (var off = 0; off < bytes.length; off += 244) {
        final end = off + 244 < bytes.length ? off + 244 : bytes.length;
        await b.transport.send(bLink, bytes.sublist(off, end));
      }
    }

    await sendFrame(Frame.hello(nodeId: b.nodeId, storeCount: 3));
    await sendFrame(Frame.inventory([1, 2, 3]));
    await sendFrame(Frame.inventoryEnd());
    await sendFrame(Frame.message(garbage));
    await sendFrame(Frame(0x7F, Uint8List(3))); // 不明 type は読み飛ばす
    await sendFrame(Frame.message(good.encode()));
    await sendFrame(Frame.message(expired.encode()));
    await sendFrame(Frame.message(tooFar.encode()));
    await sendFrame(Frame.messagesEnd());
    await radio.settle();

    expect(a.session.state, SessionState.done);
    expect(a.session.succeeded, isTrue);
    // 発信側の時計で期限切れのものも受け取り、受信時刻からの相対時間で期限を決める（C12）。
    expect(a.session.messagesReceived, 2);
    expect(a.store.count, 2);
    expect(a.store.get(good.msgId)!.envelope.hop, 3);
    expect(a.store.get(good.msgId)!.receivedAt, t);
    expect(a.store.localExpiresAt(a.store.get(expired.msgId)!), t + 3600);
    expect(a.log.any((l) => l.contains('不正な封筒')), isTrue);
    final types = framesOf(b.received).map((f) => f.type).toList();
    expect(types, [
      FrameType.hello,
      FrameType.time,
      FrameType.inventoryEnd,
      FrameType.messagesEnd,
      FrameType.bye,
    ]);
    expect(a.transport.openLinkIds, isEmpty);
  });

  test('HELLO より前に他のフレームが来たら失敗', () async {
    a = Peer(radio, 'A', index: 1);
    b = Peer(radio, 'B', index: 2, autoSession: false);
    await a.start();
    await b.start();
    await radio.settle();
    await a.transport.connect('B');
    await radio.settle();
    await b.transport.send(b.opened.single.linkId, Frame.inventoryEnd().encode());
    await radio.settle();
    expect(a.session.state, SessionState.failed);
    expect(a.transport.openLinkIds, isEmpty);
  });

  test('相手のリンク切断で失敗になり、done が完了する', () async {
    a = Peer(radio, 'A', index: 1);
    b = Peer(radio, 'B', index: 2, autoSession: false);
    await a.start();
    await b.start();
    await radio.settle();
    await a.transport.connect('B');
    await radio.settle();
    var finished = false;
    unawaited(a.session.done.then((_) => finished = true));
    await b.transport.close(b.opened.single.linkId);
    await radio.settle();
    expect(finished, isTrue);
    expect(a.session.state, SessionState.failed);
    expect(a.session.failureReason, contains('切断'));
  });

  test('abort は BYE を送って閉じ、相手側も終了する', () async {
    a = Peer(radio, 'A', index: 1);
    b = Peer(radio, 'B', index: 2, autoSession: false);
    await a.start();
    await b.start();
    await radio.settle();
    await a.transport.connect('B');
    await radio.settle();
    a.session.abort('テスト');
    await radio.settle();
    expect(a.session.state, SessionState.failed);
    expect(a.session.failureReason, 'テスト');
    final types = framesOf(b.received).map((f) => f.type).toList();
    expect(types.last, FrameType.bye);
    expect(b.closed.length, 1);
    // 二重 abort / 終了後の onData は無害。
    a.session.abort('again');
    a.session.onData(Uint8List.fromList([1, 2, 3]));
    a.session.onClosed();
    expect(a.session.failureReason, 'テスト');
  });

  test('peripheral 側は BYE が来なくてもリンク切断で正常終了する', () async {
    a = Peer(radio, 'A', index: 1, autoSession: false);
    b = Peer(radio, 'B', index: 2);
    await a.start();
    await b.start();
    await radio.settle();
    await a.transport.connect('B');
    await radio.settle();
    final aLink = a.opened.single.linkId;
    Future<void> sendFrame(Frame f) =>
        a.transport.send(aLink, f.encode());
    await sendFrame(Frame.hello(nodeId: a.nodeId, storeCount: 0));
    await sendFrame(Frame.inventoryEnd());
    await sendFrame(Frame.messagesEnd());
    await radio.settle();
    expect(b.session.state, SessionState.closing);
    await a.transport.close(aLink);
    await radio.settle();
    expect(b.session.state, SessionState.done);
    expect(b.session.succeeded, isTrue);
  });
}
