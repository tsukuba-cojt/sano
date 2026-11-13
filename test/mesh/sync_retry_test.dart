import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/core/frames.dart';
import 'package:kairanban/core/inventory_filter.dart';
import 'package:kairanban/mesh/message_store.dart';
import 'package:kairanban/mesh/store_file.dart';
import 'package:kairanban/mesh/sync_session.dart';
import 'package:kairanban/transport/fake_transport.dart';

import 'helpers.dart';
import 'mesh_spread_test.dart' show makeHelp;
import 'sync_session_test.dart' show Peer, framesOf;

void main() {
  for (final scenario in [
    (completes: false, exact: false, name: '目録要約の偽陽性を切断後の SOS 先出し抑制に使わない'),
    (completes: true, exact: false, name: '目録要約の偽陽性を正常終了後の SOS 先出し抑制に使わない'),
    (completes: true, exact: true, name: '一覧目録で確認した SOS は次の先出しで重複送信しない'),
  ]) {
    final completes = scenario.completes;
    test(scenario.name, () async {
      final radio = FakeRadio(clock: FakeClock(startEpochSeconds: kT0));
      final a = TestNode(radio, 'A', index: 1);
      final b = Peer(radio, 'B', index: 2, autoSession: false);
      addTearDown(a.dispose);
      addTearDown(b.transport.dispose);
      await a.start();
      await b.start();
      final sos = makeHelp(origin: a.nodeId, createdAt: kT0);
      await a.store.add(sos, now: kT0, isLocal: true);

      // 実際には SOS を持たない相手の正規 Bloom 目録で偽陽性を作る。
      final peerIds = List.generate(1000, (i) => i + 1);
      expect(peerIds, isNot(contains(sos.msgId)));
      InventoryFilter? collision;
      for (var salt = 0; salt < 10000; salt++) {
        final filter = InventoryFilter.build(peerIds, salt: salt);
        if (filter.mightContain(sos.msgId)) {
          collision = filter;
          break;
        }
      }
      expect(collision, isNotNull);
      radio.discover('A', 'B');
      await radio.settle();
      final firstLink = b.opened.last.linkId;
      await b.transport.send(
        firstLink,
        Frame.hello(
          nodeId: b.nodeId,
          storeCount: peerIds.length,
          // 初回は先出しなしで要約による省略を再現する。
          caps: kCapInventoryFilter | kCapStoreConfirmation,
        ).encode(),
      );
      final filterBytes = scenario.exact
          ? Frame.inventory([sos.msgId]).encode()
          : Frame.inventoryFilter(collision!.encode()).encode();
      for (var start = 0; start < filterBytes.length; start += 244) {
        final end = (start + 244).clamp(0, filterBytes.length);
        await b.transport.send(
          firstLink,
          Uint8List.sublistView(filterBytes, start, end),
        );
      }
      if (completes) {
        await b.transport.send(firstLink, Frame.inventoryEnd().encode());
        await b.transport.send(firstLink, Frame.messagesEnd().encode());
        await radio.settle();
        await b.transport.send(
          firstLink,
          Frame.stored(const [], last: true).encode(),
        );
      } else {
        await radio.settle();
        await b.transport.close(firstLink);
      }
      await radio.settle();
      expect(a.node.recentSessions.single.succeeded, completes);
      expect(
        framesOf(b.received).where((f) => f.type == FrameType.message),
        isEmpty,
      );

      // 次は短い接触。目録交換に入る前の先出しだけで SOS が届く必要がある。
      b.received.clear();
      await b.transport.connect('A');
      await radio.settle();
      await b.transport.send(
        b.opened.last.linkId,
        Frame.hello(
          nodeId: b.nodeId,
          storeCount: peerIds.length,
          caps: kDefaultCaps,
        ).encode(),
      );
      await radio.settle();
      expect(
        framesOf(b.received).where((f) => f.type == FrameType.message),
        hasLength(scenario.exact ? 0 : 1),
      );
    });
  }

  test('終了用 BYE の応答が止まってもタイムアウトでリンクとセッションを解放する', () async {
    final clock = FakeClock(startEpochSeconds: kT0);
    final store = MessageStore(MemoryStoreBackend());
    await store.load();
    final blockedSend = Completer<void>();
    var closes = 0;
    var finished = false;
    final session = SyncSession(
      linkId: 1,
      peerId: 'blocked',
      initiator: true,
      maxChunk: 512,
      store: store,
      nodeId: nodeIdOf(1),
      send: (chunk) async {
        if (framesOf([chunk]).any((f) => f.type == FrameType.bye)) {
          await blockedSend.future;
        }
      },
      close: () async {
        closes++;
      },
      now: clock.now,
      createTimer: clock.createTimer,
    );
    session.done.then((_) => finished = true);
    await session.start();
    await clock.elapse(kHelloTimeout);
    await Future<void>.delayed(Duration.zero);
    try {
      expect(session.state, SessionState.failed);
      expect(closes, 1);
      expect(finished, isTrue);
    } finally {
      blockedSend.complete();
      await session.done;
    }
  });

  test('保存上限エラーの直後は接続を連打せず、復旧後は再試行できる', () async {
    final radio = FakeRadio(clock: FakeClock(startEpochSeconds: kT0));
    final a = TestNode(radio, 'A', index: 1);
    final b = TestNode(radio, 'B', index: 2, maxMessages: 1);
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    await a.start();
    await b.start();
    await b.store.add(
      makeHelp(origin: b.nodeId, createdAt: kT0),
      now: kT0,
      isLocal: true,
    );
    var attempts = 0;
    radio.allowConnect = (_, _) => ++attempts <= 2; // 回帰時の無限再接続を止める。
    radio.discover('A', 'B');
    await radio.settle();
    expect(a.node.recentSessions.single.succeeded, isTrue);
    expect(attempts, 1);

    final notice = makeNotice(origin: a.nodeId, createdAt: kT0);
    await a.node.publish(notice);
    await radio.settle();
    expect(a.node.recentSessions.last.succeeded, isFalse);
    expect(attempts, 2, reason: '保存失敗後はバックオフし、同じ時刻に再接続しない');
    expect(a.node.peers.single.backoffUntil, greaterThan(kT0));

    // 保存先に空きができてもバックオフ中は待ち、期限後の再試行で届ける。
    await b.store.removeWhere((_) => true);
    await a.store.removeWhere((m) => m.msgId != notice.msgId);
    radio.allowConnect = (_, _) {
      attempts++;
      return true;
    };
    await radio.elapse(const Duration(seconds: 29));
    expect(attempts, 2);
    await radio.elapse(const Duration(seconds: 2));
    expect(attempts, 3);
    expect(b.store.contains(notice.msgId), isTrue);
    expect(a.node.recentSessions.last.succeeded, isTrue);
  });
}
