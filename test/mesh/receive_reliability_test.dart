import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/core/frames.dart';
import 'package:kairanban/mesh/message_store.dart';
import 'package:kairanban/mesh/receive_budget.dart';
import 'package:kairanban/mesh/store_file.dart';
import 'package:kairanban/mesh/sync_session.dart';
import 'package:kairanban/transport/fake_transport.dart';

import 'helpers.dart';
import 'sync_session_test.dart' show Peer, framesOf;

class FailingBackend extends MemoryStoreBackend {
  bool fail = true;

  @override
  Future<void> append(Uint8List record) async {
    if (fail) throw StateError('simulated disk full');
    await super.append(record);
  }

  @override
  Future<void> appendAll(List<Uint8List> records) async {
    if (fail) throw StateError('simulated disk full');
    await super.appendAll(records);
  }
}

class GatedBackend extends MemoryStoreBackend {
  final gate = Completer<void>();

  @override
  Future<void> append(Uint8List record) async {
    await gate.future;
    await super.append(record);
  }

  @override
  Future<void> appendAll(List<Uint8List> records) async {
    await gate.future;
    await super.appendAll(records);
  }
}

void main() {
  Future<void> connect(FakeRadio radio, Peer a, Peer b) async {
    await a.start();
    await b.start();
    await a.transport.connect('B');
    await radio.settle();
  }

  test('双方の永続保存を確認してから成功し、保存確認IDだけを渡した台数に使う', () async {
    final radio = FakeRadio(clock: FakeClock(startEpochSeconds: kT0));
    final a = Peer(radio, 'A', index: 1);
    final b = Peer(radio, 'B', index: 2);
    final notice = makeNotice(origin: a.nodeId, createdAt: kT0);
    await a.store.add(notice, now: kT0, isLocal: true);
    await connect(radio, a, b);
    expect(a.session.succeeded, isTrue);
    expect(b.session.succeeded, isTrue);
    expect(a.session.peerStorageConfirmed, isTrue);
    expect(a.session.confirmedSentMessageIds, [notice.msgId]);
    final incoming = framesOf(a.received);
    expect(incoming.where((f) => f.type == FrameType.stored).length, 2);
  });

  for (final failingSide in ['central', 'peripheral']) {
    test('$failingSide の保存失敗は両側とも失敗となり、復旧後の再送で保存できる', () async {
      final radio = FakeRadio(clock: FakeClock(startEpochSeconds: kT0));
      final failing = FailingBackend();
      final a = Peer(
        radio,
        'A',
        index: 1,
        backend: failingSide == 'central' ? failing : null,
      );
      final b = Peer(
        radio,
        'B',
        index: 2,
        backend: failingSide == 'peripheral' ? failing : null,
      );
      final receiver = failingSide == 'central' ? a : b;
      final sender = failingSide == 'central' ? b : a;
      final notice = makeNotice(origin: sender.nodeId, createdAt: kT0);
      await sender.store.add(notice, now: kT0, isLocal: true);
      await connect(radio, a, b);
      expect(receiver.sessions.last.succeeded, isFalse);
      expect(sender.sessions.last.succeeded, isFalse);
      expect(sender.sessions.last.confirmedSentMessageIds, isEmpty);
      expect(receiver.store.contains(notice.msgId), isFalse);
      failing.fail = false;
      await a.transport.connect('B');
      await radio.settle();
      expect(receiver.sessions.last.succeeded, isTrue);
      expect(sender.sessions.last.succeeded, isTrue);
      final reloaded = MessageStore(failing);
      await reloaded.load();
      expect(reloaded.contains(notice.msgId), isTrue);
      expect(sender.sessions.last.confirmedSentMessageIds, [notice.msgId]);
    });
  }

  test('旧版と同期できるが、未確認送信を保存確認済みとは数えない', () async {
    final radio = FakeRadio(clock: FakeClock(startEpochSeconds: kT0));
    final a = Peer(radio, 'A', index: 1);
    final b = Peer(
      radio,
      'B',
      index: 2,
      caps: kDefaultCaps & ~kCapStoreConfirmation,
    );
    final notice = makeNotice(origin: a.nodeId, createdAt: kT0);
    await a.store.add(notice, now: kT0, isLocal: true);
    await connect(radio, a, b);
    expect(a.session.succeeded, isTrue);
    expect(b.store.contains(notice.msgId), isTrue);
    expect(a.session.peerStorageConfirmed, isFalse);
    expect(a.session.confirmedSentMessageIds, isEmpty);
    expect(
      framesOf(b.received).where((f) => f.type == FrameType.stored),
      isEmpty,
    );
  });

  Future<SyncSession> direct({
    StoreBackend? backend,
    ReceiveBudget? budget,
    bool relay = false,
    bool confirm = false,
  }) async {
    final store = MessageStore(backend ?? MemoryStoreBackend());
    await store.load();
    final clock = FakeClock(startEpochSeconds: kT0);
    final session = SyncSession(
      linkId: 1,
      peerId: 'peer',
      initiator: false,
      maxChunk: 512,
      store: store,
      nodeId: nodeIdOf(1),
      send: (_) async {},
      close: () async {},
      now: clock.now,
      createTimer: clock.createTimer,
      receiveBudget: budget,
      caps: kDefaultCaps | (relay ? kCapRelayNode : 0),
    );
    await session.start();
    session.onData(
      Frame.hello(
        nodeId: nodeIdOf(2),
        storeCount: 0,
        caps:
            (relay ? kCapRelayNode : 0) | (confirm ? kCapStoreConfirmation : 0),
      ).encode(),
    );
    return session;
  }

  test('保存確認対応の相手が確認前に切断しても同期成功にならない', () async {
    final session = await direct(confirm: true);
    session.onData(Frame.inventoryEnd().encode());
    session.onData(Frame.messagesEnd().encode());
    await Future<void>.delayed(Duration.zero);
    expect(session.state, SessionState.closing);
    session.onClosed();
    await session.done;
    expect(session.succeeded, isFalse);
  });

  test('通常セッションは64KiBを超えるMESSAGEを受け付けない', () async {
    final session = await direct();
    session.onData(Frame.inventoryEnd().encode());
    final frame = Frame.message(
      makeNotice(origin: nodeIdOf(2), createdAt: kT0).encode(),
    ).encode();
    while (!session.isFinished) {
      session.onData(frame);
    }
    await session.done;
    expect(session.failureReason, contains('MESSAGE の受信上限'));
    expect(
      session.bytesReceived,
      lessThan(kDefaultSessionByteBudget + frame.length + 100),
    );
  });

  test('中継役の保存が止まってもセッションの保存待ちは2048件以内', () async {
    final backend = GatedBackend();
    final budget = ReceiveBudget();
    final session = await direct(backend: backend, budget: budget, relay: true);
    session.onData(Frame.inventoryEnd().encode());
    final frame = Frame.message(
      makeNotice(origin: nodeIdOf(2), createdAt: kT0).encode(),
    ).encode();
    var maxPending = 0;
    for (var i = 0; i < 10000 && !session.isFinished; i++) {
      session.onData(frame);
      if (session.pendingReceiveMessages > maxPending) {
        maxPending = session.pendingReceiveMessages;
      }
    }
    expect(maxPending, kMaxPendingReceiveMessages);
    expect(session.failureReason, contains('保存待ちの受信上限'));
    expect(budget.messages, 1); // 実行中の書き込みだけ。未開始分は解放済み。
    backend.gate.complete();
    await session.done;
    await Future<void>.delayed(Duration.zero);
    expect(budget.messages, 0);
    expect(budget.bytes, 0);
  });

  test('同時接続でも端末全体の保存待ち上限を共有する', () async {
    final budget = ReceiveBudget(maxMessages: 3);
    final firstBackend = GatedBackend();
    final secondBackend = GatedBackend();
    final a = await direct(backend: firstBackend, budget: budget, relay: true);
    final b = await direct(backend: secondBackend, budget: budget, relay: true);
    final frame = Frame.message(
      makeNotice(origin: nodeIdOf(3), createdAt: kT0).encode(),
    ).encode();
    a.onData(frame);
    b.onData(frame);
    a.onData(frame);
    expect(budget.messages, 3);
    b.onData(frame);
    expect(b.isFinished, isTrue);
    expect(b.failureReason, contains('保存待ちの受信上限'));
    expect(budget.messages, 3);
    a.abort('test complete');
    firstBackend.gate.complete();
    secondBackend.gate.complete();
    await Future.wait([a.done, b.done]);
    await Future<void>.delayed(Duration.zero);
    expect(budget.messages, 0);
    expect(budget.bytes, 0);
  });

  test('圧縮率が高い本文でも保存待ちは展開後4MiB以内', () async {
    final backend = GatedBackend();
    final budget = ReceiveBudget();
    final session = await direct(backend: backend, budget: budget, relay: true);
    final frame = Frame.message(
      makeNotice(
        origin: nodeIdOf(2),
        createdAt: kT0,
        text: 'x' * 3000,
      ).encode(),
    ).encode();
    var peakBytes = 0;
    var peakCount = 0;
    while (!session.isFinished) {
      session.onData(frame);
      if (session.pendingReceiveBytes > peakBytes) {
        peakBytes = session.pendingReceiveBytes;
      }
      if (session.pendingReceiveMessages > peakCount) {
        peakCount = session.pendingReceiveMessages;
      }
    }
    expect(session.failureReason, contains('保存待ちの受信上限'));
    expect(peakBytes, lessThanOrEqualTo(kMaxPendingReceiveBytes));
    expect(peakCount, lessThan(kMaxPendingReceiveMessages));
    backend.gate.complete();
    await session.done;
    await Future<void>.delayed(Duration.zero);
    expect(budget.bytes, 0);
  });

  test('中継役もMESSAGEは1MiBで打ち切る', () async {
    final session = await direct(relay: true);
    // 不正な短い封筒も受信量に数える。保存キューを使わず上限だけを試す。
    final frame = Frame.message(Uint8List(4000)).encode();
    while (!session.isFinished) {
      session.onData(frame);
    }
    await session.done;
    expect(session.failureReason, contains('MESSAGE の受信上限'));
    expect(
      session.bytesReceived,
      lessThan(kRelaySessionByteBudget + frame.length + 100),
    );
  });

  test('未知の制御フレームを送り続けても64KiBで打ち切る', () async {
    final session = await direct();
    final frame = Frame(0x77, Uint8List(8000)).encode();
    while (!session.isFinished) {
      session.onData(frame);
    }
    await session.done;
    expect(session.failureReason, contains('制御データの受信上限'));
    expect(
      session.bytesReceived,
      lessThan(kMaxSessionControlBytes + frame.length + 100),
    );
  });

  test('目録が3000IDを超えたら接続を終了する', () async {
    final session = await direct();
    for (var i = 0; i < 3; i++) {
      session.onData(
        Frame.inventory(List.generate(1000, (n) => i * 1000 + n)).encode(),
      );
    }
    expect(session.isFinished, isFalse);
    session.onData(Frame.inventory([3000]).encode());
    await session.done;
    expect(session.failureReason, contains('目録の受信上限'));
  });

  test('送信していないIDの保存確認は受け付けない', () async {
    final session = await direct(confirm: true);
    session.onData(Frame.inventoryEnd().encode());
    session.onData(Frame.messagesEnd().encode());
    session.onData(Frame.stored([123]).encode());
    await session.done;
    expect(session.succeeded, isFalse);
    expect(session.failureReason, contains('送っていない ID'));
  });
}
