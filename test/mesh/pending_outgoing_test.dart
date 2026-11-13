import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/core/categories.dart';
import 'package:kairanban/core/envelope.dart';
import 'package:kairanban/core/frames.dart';
import 'package:kairanban/core/inventory_filter.dart';
import 'package:kairanban/mesh/mesh_node.dart';
import 'package:kairanban/mesh/message_store.dart';
import 'package:kairanban/mesh/store_file.dart';
import 'package:kairanban/mesh/sync_session.dart';
import 'package:kairanban/transport/fake_transport.dart';

import 'helpers.dart';
import 'receive_reliability_test.dart' show GatedBackend;
import 'send_priority_test.dart' show makeHelp;
import 'sync_session_test.dart' show Peer, framesOf;

Envelope ack(
  int target, {
  int createdAt = kT0,
  int? expiresAt,
  int group = kGroupA,
}) => Envelope.create(
  kind: MessageKind.ack,
  groupId: group,
  originId: nodeIdOf(1),
  createdAt: createdAt,
  expiresAt: expiresAt ?? createdAt + 48 * 3600,
  category: NoticeCategory.request,
  role: SenderRole.staff,
  supersedes: target,
  bodyPlain: Uint8List(0),
);

StoredMessage outgoing(Envelope e) =>
    StoredMessage(envelope: e, receivedAt: e.createdAt, isLocal: true);

void main() {
  test('外部返信は重複なく候補へ入り、SOS・緊急の次に古い未受渡し返信から送る', () async {
    final store = MessageStore(MemoryStoreBackend())
      ..joinedGroupIds = {kGroupA};
    await store.load();
    final oldest = ack(1, createdAt: kT0 - 20);
    final recent = ack(2, createdAt: kT0 - 10);
    final handed = ack(3);
    final sos = makeHelp(origin: nodeIdOf(50), createdAt: kT0);
    final alert = makeNotice(
      origin: nodeIdOf(51),
      createdAt: kT0,
      role: SenderRole.official,
      category: NoticeCategory.evacuation,
    );
    await store.addAll([recent, handed, sos, alert], now: kT0);
    store.pendingOutgoing = () => [
      outgoing(recent),
      outgoing(oldest),
      outgoing(recent),
    ];
    final all = store.messagesMissingFrom(
      (_) => false,
      now: kT0,
      peerGroups: {kGroupA},
    );
    final ids = all.map((m) => m.msgId).toList();
    expect(ids.toSet().length, ids.length);
    expect(ids.take(2).toSet(), {sos.msgId, alert.msgId});
    expect(ids.skip(2), [oldest.msgId, recent.msgId, handed.msgId]);
    final pushed = store.pushCandidates(now: kT0).map((m) => m.msgId).toList();
    expect(pushed.take(2).toSet(), {sos.msgId, alert.msgId});
    expect(pushed.skip(2), [oldest.msgId, recent.msgId, handed.msgId]);
    expect(store.inventory(now: kT0), isNot(contains(oldest.msgId)));
    expect(store.count, 4);
    expect(
      store.hasRelayableNotIn(store.inventory(now: kT0).toSet(), now: kT0),
      isTrue,
    );
    expect(store.hasRelayableNotIn(ids.toSet(), now: kT0), isFalse);
    expect(
      store
          .messagesMissingFrom((_) => false, now: kT0, exclude: {oldest.msgId})
          .map((m) => m.msgId),
      isNot(contains(oldest.msgId)),
    );
  });

  test('外部返信にも期限・hop・空殻・取消・上書きの制限を適用する', () async {
    final store = MessageStore(MemoryStoreBackend())
      ..joinedGroupIds = {kGroupA};
    await store.load();
    final valid = outgoing(ack(1));
    final expired = outgoing(ack(2, createdAt: kT0 - 2, expiresAt: kT0 - 1));
    final tooFar = outgoing(ack(3).copyWith(hop: kMaxRelayHop));
    final stub = outgoing(ack(4).asStub());
    final cancelled = outgoing(ack(5))..retracted = true;
    final superseded = outgoing(ack(6))..supersededBy = 99;
    final foreign = StoredMessage(envelope: ack(7), receivedAt: kT0);
    store.pendingOutgoing = () => [
      expired,
      tooFar,
      stub,
      cancelled,
      superseded,
      foreign,
      valid,
    ];
    expect(
      store.messagesMissingFrom((_) => false, now: kT0).map((m) => m.msgId),
      [valid.msgId],
    );
    expect(store.pushCandidates(now: kT0).map((m) => m.msgId), [valid.msgId]);
    expect(store.hasRelayableNotIn({valid.msgId}, now: kT0), isFalse);
  });

  test('戻ってきた中継コピーの期限とhopで発信元の外部返信を失わない', () async {
    final store = MessageStore(MemoryStoreBackend());
    await store.load();
    final original = ack(1);
    final returned = original.copyWith(
      hop: kMaxRelayHop - 1,
      expiresAt: kT0 + 1,
    );
    await store.add(returned, now: kT0);
    final source = outgoing(original);
    store.pendingOutgoing = () => [source];
    final selected = store
        .messagesMissingFrom((_) => false, now: kT0 + 2)
        .single;
    expect(identical(selected, source), isTrue);
    expect(selected.envelope.hop, 0);
    expect(selected.envelope.expiresAt, original.expiresAt);

    // 原本と同じ ID に明示的な取消状態がある場合は復活させない。
    store.get(original.msgId)!.retracted = true;
    expect(store.messagesMissingFrom((_) => false, now: kT0 + 2), isEmpty);
  });

  test('beforeCommit 内の外部返信通知をrelayの公開で巻き戻さない', () async {
    final store = MessageStore(MemoryStoreBackend());
    await store.load();
    final pending = outgoing(ack(1));
    var notifiedVersion = -1;
    store.beforeCommit = (_, _, _) async {
      store.pendingOutgoing = () => [pending];
      store.notifyOutgoingChanged();
      notifiedVersion = store.version;
    };
    await store.add(
      makeNotice(origin: nodeIdOf(1), createdAt: kT0),
      now: kT0,
    );
    expect(store.version, greaterThan(notifiedVersion));
    expect(
      store.hasRelayableNotIn(store.inventory(now: kT0).toSet(), now: kT0),
      isTrue,
    );
  });

  for (final kind in ['legacy-list', 'bloom', 'partial-stored']) {
    test('途中切断の保存確認: $kind', () async {
      final radio = FakeRadio(clock: FakeClock(startEpochSeconds: kT0));
      final transport = radio.createTransport('A');
      final store = MessageStore(MemoryStoreBackend());
      await store.load();
      final first = outgoing(ack(1));
      final second = outgoing(ack(2));
      store.pendingOutgoing = () => [first, second];
      final confirms = <Set<int>>[];
      final handed = <List<int>>[];
      final node = MeshNode(
        transport: transport,
        store: store,
        nodeId: nodeIdOf(1),
        now: radio.clock.now,
        createTimer: radio.clock.createTimer,
        onPeerStored: (_, ids, _) => confirms.add(ids),
        onHanded: (_, ids, _) => handed.add(ids),
      );
      final peer = Peer(radio, 'B', index: 2, autoSession: false);
      addTearDown(() async {
        node.dispose();
        await transport.dispose();
        await peer.transport.dispose();
      });
      await node.start();
      await peer.start();
      await transport.connect('B');
      await radio.settle();
      final link = peer.opened.single.linkId;
      final caps = kind == 'partial-stored'
          ? kCapStoreConfirmation
          : kind == 'bloom'
          ? kCapInventoryFilter
          : 0;
      await peer.transport.send(
        link,
        Frame.hello(nodeId: peer.nodeId, storeCount: 1, caps: caps).encode(),
      );
      if (kind == 'legacy-list') {
        await peer.transport.send(
          link,
          Frame.inventory([first.msgId]).encode(),
        );
      } else if (kind == 'bloom') {
        await peer.transport.send(
          link,
          Frame.inventoryFilter(
            InventoryFilter.build([first.msgId], salt: 1).encode(),
          ).encode(),
        );
      } else {
        await peer.transport.send(link, Frame.inventoryEnd().encode());
        await peer.transport.send(link, Frame.messagesEnd().encode());
        await radio.settle();
        expect(
          framesOf(peer.received).where((f) => f.type == FrameType.message),
          hasLength(2),
        );
        await peer.transport.send(link, Frame.stored([first.msgId]).encode());
      }
      await radio.settle();
      await peer.transport.close(link);
      await radio.settle();
      expect(node.recentSessions.single.succeeded, isFalse);
      expect(handed, isEmpty);
      expect(
        confirms,
        kind == 'bloom'
            ? isEmpty
            : [
                {first.msgId},
              ],
      );
    });
  }

  test('外部返信だけ増えたときもnudgeで直前の同期抑制を解除する', () async {
    final radio = FakeRadio(clock: FakeClock(startEpochSeconds: kT0));
    final a = TestNode(radio, 'A', index: 1);
    final b = TestNode(radio, 'B', index: 2);
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    await a.start();
    await b.start();
    radio.discover('A', 'B');
    await radio.settle();
    final prior = a.node.totalSessions;
    final pending = outgoing(ack(1));
    a.store.pendingOutgoing = () => [pending];
    a.store.notifyOutgoingChanged();
    a.node.nudge();
    await radio.settle();
    expect(a.node.totalSessions, greaterThan(prior));
    expect(b.store.contains(pending.msgId), isTrue);
    expect(radio.clock.now(), kT0);
  });

  test('24時間を過ぎた未確認返信もBloom一致だけで止めず保存確認を取り直す', () async {
    final radio = FakeRadio(clock: FakeClock(startEpochSeconds: kT0));
    final transport = radio.createTransport('A');
    final store = MessageStore(MemoryStoreBackend());
    await store.load();
    final original = ack(1, createdAt: kT0 - 25 * 3600);
    await store.add(original, now: kT0 - 25 * 3600, isLocal: true);
    store.pendingOutgoing = () => [outgoing(original)];
    final confirmed = <int>{};
    final node = MeshNode(
      transport: transport,
      store: store,
      nodeId: nodeIdOf(1),
      now: radio.clock.now,
      createTimer: radio.clock.createTimer,
      onPeerStored: (_, ids, _) => confirmed.addAll(ids),
    );
    final peer = Peer(radio, 'B', index: 2);
    addTearDown(() async {
      node.dispose();
      await transport.dispose();
      await peer.transport.dispose();
    });
    await node.start();
    await peer.start();
    // 返信は相手にも保存済みだが、送信側の確認記録だけ保存できなかった状態。
    await peer.store.add(original, now: kT0 - 25 * 3600);
    expect(store.pushCandidates(now: kT0), isEmpty);
    await transport.connect('B');
    await radio.settle();
    expect(
      framesOf(peer.received).where((f) => f.type == FrameType.inventoryFilter),
      isNotEmpty,
    );
    expect(confirmed, contains(original.msgId));
    expect(node.recentSessions.single.succeeded, isTrue);
    expect(peer.store.count, 1);
  });

  test('中継役の小さい返信も2048件以内で保存確認へ進む', () async {
    final radio = FakeRadio(
      clock: FakeClock(startEpochSeconds: kT0),
      defaultMaxChunk: 512,
    );
    final backend = GatedBackend();
    final a = Peer(radio, 'A', index: 1, caps: kDefaultCaps | kCapRelayNode);
    final b = Peer(
      radio,
      'B',
      index: 2,
      caps: kDefaultCaps | kCapRelayNode,
      backend: backend,
    );
    addTearDown(a.transport.dispose);
    addTearDown(b.transport.dispose);
    addTearDown(() {
      if (!backend.gate.isCompleted) backend.gate.complete();
    });
    final pending = [for (var i = 1; i <= 2500; i++) outgoing(ack(i))];
    a.store.pendingOutgoing = () => pending;
    await a.start();
    await b.start();
    await a.transport.connect('B');
    await radio.settle();
    expect(a.session.messagesSent, kMaxPendingReceiveMessages);
    expect(a.session.budgetExhausted, isTrue);
    expect(b.session.pendingReceiveMessages, kMaxPendingReceiveMessages);
    expect(b.session.isFinished, isFalse);
    backend.gate.complete();
    await radio.settle();
    expect(a.session.succeeded, isTrue);
    expect(b.session.succeeded, isTrue);
    expect(
      a.session.confirmedSentMessageIds,
      hasLength(kMaxPendingReceiveMessages),
    );
  });

  test('高圧縮の中継送信も展開後4MiB以内で保存確認へ進む', () async {
    final radio = FakeRadio(
      clock: FakeClock(startEpochSeconds: kT0),
      defaultMaxChunk: 512,
    );
    final backend = GatedBackend();
    final a = Peer(radio, 'A', index: 1, caps: kDefaultCaps | kCapRelayNode);
    final b = Peer(
      radio,
      'B',
      index: 2,
      caps: kDefaultCaps | kCapRelayNode,
      backend: backend,
    );
    addTearDown(a.transport.dispose);
    addTearDown(b.transport.dispose);
    addTearDown(() {
      if (!backend.gate.isCompleted) backend.gate.complete();
    });
    await a.store.addAll([
      for (var i = 1; i <= 1500; i++)
        makeNotice(
          origin: nodeIdOf(i),
          createdAt: kT0,
          role: SenderRole.official,
          text: 'x' * 3000,
        ),
    ], now: kT0);
    await a.start();
    await b.start();
    await a.transport.connect('B');
    await radio.settle();
    expect(a.session.messagesSent, lessThan(1500));
    expect(a.session.budgetExhausted, isTrue);
    expect(
      b.session.pendingReceiveBytes,
      lessThanOrEqualTo(kMaxPendingReceiveBytes),
    );
    expect(b.session.isFinished, isFalse);
    backend.gate.complete();
    await radio.settle();
    expect(a.session.succeeded, isTrue);
    expect(b.session.succeeded, isTrue);
    expect(
      a.session.confirmedSentMessageIds,
      hasLength(a.session.messagesSent),
    );
  });
}
