/// 開発用 TCP ハブ（`hub_server.dart`）と `HubTransport` の結合テスト。
/// ハブをインプロセスで起動し、2 つの HubTransport で
/// 発見 → 接続 → 双方向データ → 切断 を確認する。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/mesh/transport.dart';
import 'package:kairanban/transport/hub_server.dart';
import 'package:kairanban/transport/hub_transport.dart';

/// broadcast ストリームを購読して溜め、条件に合うイベントを待つ補助。
class _EventTap {
  _EventTap(Stream<TransportEvent> stream) {
    _sub = stream.listen((event) {
      all.add(event);
      _check();
    });
  }

  final List<TransportEvent> all = [];
  final List<_Waiter> _waiters = [];
  late final StreamSubscription<TransportEvent> _sub;
  int _consumed = 0;

  /// まだ消費していないイベントのうち、最初に [where] を満たすものを返す。
  Future<T> next<T extends TransportEvent>({
    bool Function(T event)? where,
    Duration timeout = const Duration(seconds: 5),
  }) {
    final waiter = _Waiter<T>(where ?? (_) => true);
    _waiters.add(waiter);
    _check();
    return waiter.completer.future.timeout(
      timeout,
      onTimeout: () {
        _waiters.remove(waiter);
        throw TimeoutException(
          '$T を待ちましたが届きません。受信済み: ${all.map(_describe).join(', ')}',
        );
      },
    );
  }

  void _check() {
    if (_waiters.isEmpty) {
      return;
    }
    while (_waiters.isNotEmpty && _consumed < all.length) {
      final event = all[_consumed++];
      final waiter = _waiters.first;
      if (waiter.matches(event)) {
        _waiters.removeAt(0);
        waiter.complete(event);
      }
    }
  }

  Iterable<T> ofType<T extends TransportEvent>() => all.whereType<T>();

  Future<void> close() => _sub.cancel();

  static String _describe(TransportEvent e) => switch (e) {
        TransportState() =>
          'State(on=${e.poweredOn},scan=${e.scanning},adv=${e.advertising})',
        PeerDiscovered() => 'Discovered(${e.peerId},${e.rssi})',
        LinkOpened() =>
          'Opened(${e.linkId},${e.peerId},init=${e.initiator},max=${e.maxChunk})',
        LinkData() => 'Data(${e.linkId},${e.data.length}B)',
        LinkClosed() => 'Closed(${e.linkId},${e.peerId},${e.reason})',
        TransportLog() => 'Log(${e.message})',
      };
}

class _Waiter<T extends TransportEvent> {
  _Waiter(this.where);
  final bool Function(T) where;
  final Completer<T> completer = Completer<T>();

  bool matches(TransportEvent e) => e is T && where(e);

  void complete(TransportEvent e) {
    if (!completer.isCompleted) {
      completer.complete(e as T);
    }
  }
}

Uint8List _nodeId(int seed) =>
    Uint8List.fromList(List<int>.generate(8, (i) => (seed * 31 + i) & 0xFF));

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('条件が満たされませんでした');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late HubServer hub;
  final transports = <HubTransport>[];
  final taps = <_EventTap>[];

  HubTransport makeTransport(String peerId, {int? port}) {
    final t = HubTransport(
      '127.0.0.1',
      port ?? hub.port,
      peerId: peerId,
      initialBackoff: const Duration(milliseconds: 100),
      maxBackoff: const Duration(milliseconds: 400),
    );
    transports.add(t);
    return t;
  }

  _EventTap tap(HubTransport t) {
    final tap = _EventTap(t.events);
    taps.add(tap);
    return tap;
  }

  setUp(() async {
    hub = await startHub(
      port: 0,
      address: InternetAddress.loopbackIPv4,
      discoveryInterval: const Duration(milliseconds: 200),
    );
  });

  tearDown(() async {
    for (final t in transports) {
      await t.dispose();
    }
    transports.clear();
    for (final tap in taps) {
      await tap.close();
    }
    taps.clear();
    await hub.close();
  });

  /// A と B を起動し、A が B を発見して接続した状態を作る。
  Future<({HubTransport a, HubTransport b, _EventTap ta, _EventTap tb, int linkId})>
      openLink() async {
    final a = makeTransport('peer-A');
    final b = makeTransport('peer-B');
    final ta = tap(a);
    final tb = tap(b);
    await a.start(TransportConfig(nodeId: _nodeId(1)));
    await b.start(TransportConfig(nodeId: _nodeId(2)));
    await ta.next<PeerDiscovered>(where: (e) => e.peerId == 'peer-B');
    await a.connect('peer-B');
    final openedA = await ta.next<LinkOpened>();
    final openedB = await tb.next<LinkOpened>();
    expect(openedA.linkId, openedB.linkId);
    return (a: a, b: b, ta: ta, tb: tb, linkId: openedA.linkId);
  }

  test('起動するとハブに登録され、状態イベントが流れる', () async {
    final a = makeTransport('peer-A');
    final ta = tap(a);
    expect(a.connected, isFalse);
    await a.start(TransportConfig(nodeId: _nodeId(1)));
    expect(a.connected, isTrue);
    expect(a.running, isTrue);
    final state = await ta.next<TransportState>(where: (e) => e.scanning);
    expect(state.poweredOn, isTrue);
    expect(state.advertising, isTrue);
    expect(state.permission, 'granted');
    await _waitUntil(() => hub.peerIds.contains('peer-A'));
  });

  test('2 台が互いを発見する（登録直後と周期通知）', () async {
    final a = makeTransport('peer-A');
    final b = makeTransport('peer-B');
    final ta = tap(a);
    final tb = tap(b);
    await a.start(TransportConfig(nodeId: _nodeId(1)));
    await b.start(TransportConfig(nodeId: _nodeId(2)));

    final seenByA = await ta.next<PeerDiscovered>();
    final seenByB = await tb.next<PeerDiscovered>();
    expect(seenByA.peerId, 'peer-B');
    expect(seenByB.peerId, 'peer-A');
    expect(seenByA.rssi, inInclusiveRange(-90, -40));
    expect(seenByA.viaApple, isFalse);

    // 周期通知（200 ms 間隔）でも届き続ける。
    await ta.next<PeerDiscovered>(where: (e) => e.peerId == 'peer-B');
    await ta.next<PeerDiscovered>(where: (e) => e.peerId == 'peer-B');
    // 自分自身は発見しない。
    expect(ta.ofType<PeerDiscovered>().any((e) => e.peerId == 'peer-A'), isFalse);
  });

  test('接続 → 双方向データ → 切断', () async {
    final link = await openLink();
    final openedA = link.ta.ofType<LinkOpened>().single;
    final openedB = link.tb.ofType<LinkOpened>().single;
    expect(openedA.initiator, isTrue);
    expect(openedB.initiator, isFalse);
    expect(openedA.peerId, 'peer-B');
    expect(openedB.peerId, 'peer-A');
    expect(openedA.maxChunk, kHubMaxChunk);
    expect(openedB.maxChunk, kHubMaxChunk);
    expect(hub.linkCount, 1);

    // A → B
    final payload = Uint8List.fromList(List<int>.generate(244, (i) => i & 0xFF));
    await link.a.send(link.linkId, payload);
    final receivedByB = await link.tb.next<LinkData>();
    expect(receivedByB.linkId, link.linkId);
    expect(receivedByB.data, payload);

    // B → A（複数チャンクの順序も保たれる）
    for (var i = 0; i < 5; i++) {
      await link.b.send(link.linkId, Uint8List.fromList([i, i + 1, i + 2]));
    }
    for (var i = 0; i < 5; i++) {
      final d = await link.ta.next<LinkData>();
      expect(d.data, [i, i + 1, i + 2]);
    }

    // A が閉じると両端に linkClosed が届く。
    await link.a.close(link.linkId);
    final closedA = await link.ta.next<LinkClosed>();
    final closedB = await link.tb.next<LinkClosed>();
    expect(closedA.linkId, link.linkId);
    expect(closedB.linkId, link.linkId);
    expect(closedA.peerId, 'peer-B');
    expect(closedB.peerId, 'peer-A');
    expect(link.a.openLinks, isEmpty);
    expect(link.b.openLinks, isEmpty);
    await _waitUntil(() => hub.linkCount == 0);

    // 閉じたリンクへの送信は失敗する。
    expect(
      () => link.a.send(link.linkId, Uint8List(1)),
      throwsA(isA<StateError>()),
    );
  });

  test('存在しない相手への接続は LinkClosed(peerId) で失敗を通知する', () async {
    final a = makeTransport('peer-A');
    final ta = tap(a);
    await a.start(TransportConfig(nodeId: _nodeId(1)));
    await a.connect('nobody');
    final closed = await ta.next<LinkClosed>();
    expect(closed.linkId, 0);
    expect(closed.peerId, 'nobody');
    expect(closed.reason, isNotEmpty);
    expect(ta.ofType<LinkOpened>(), isEmpty);
  });

  test('片方が停止するとハブが相手側のリンクを閉じる', () async {
    final link = await openLink();
    await link.b.stop();
    // 停止した側は自分で LinkClosed を出す。
    final closedB = link.tb.ofType<LinkClosed>().single;
    expect(closedB.linkId, link.linkId);
    // 相手側にはハブから linkClosed が届く。
    final closedA = await link.ta.next<LinkClosed>();
    expect(closedA.linkId, link.linkId);
    expect(closedA.peerId, 'peer-B');
    await _waitUntil(() => hub.linkCount == 0 && !hub.peerIds.contains('peer-B'));
    // 停止後は発見通知も止まる。
    final stopped = link.tb.ofType<TransportState>().last;
    expect(stopped.scanning, isFalse);
    expect(stopped.advertising, isFalse);
  });

  test('maxChunk を超えるチャンクはリンクが切られる', () async {
    final link = await openLink();
    await link.a.send(link.linkId, Uint8List(kHubMaxChunk + 1));
    final closedA = await link.ta.next<LinkClosed>();
    final closedB = await link.tb.next<LinkClosed>();
    expect(closedA.linkId, link.linkId);
    expect(closedB.linkId, link.linkId);
    expect(link.tb.ofType<LinkData>(), isEmpty);
  });

  test('ハブが落ちるとバックオフで再接続し、リンクは閉じられる', () async {
    final link = await openLink();
    final port = hub.port;
    await hub.close();

    final closedA = await link.ta.next<LinkClosed>();
    expect(closedA.linkId, link.linkId);
    final offline = await link.ta.next<TransportState>(where: (e) => !e.poweredOn);
    expect(offline.scanning, isFalse);
    await _waitUntil(() => !link.a.connected && !link.b.connected);

    // 同じポートでハブを再起動する（bind 直後は使用中のことがあるので少し粘る）。
    HubServer? restarted;
    for (var i = 0; i < 50 && restarted == null; i++) {
      try {
        restarted = await startHub(
          port: port,
          address: InternetAddress.loopbackIPv4,
          discoveryInterval: const Duration(milliseconds: 200),
        );
      } on SocketException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    expect(restarted, isNotNull, reason: 'ポート $port で再起動できません');
    hub = restarted!;

    final online = await link.ta.next<TransportState>(
      where: (e) => e.poweredOn && e.scanning,
    );
    expect(online.advertising, isTrue);
    await _waitUntil(() => hub.peerIds.toSet().containsAll({'peer-A', 'peer-B'}));
    // 再接続後も発見・接続できる。
    await link.ta.next<PeerDiscovered>(where: (e) => e.peerId == 'peer-B');
    await link.a.connect('peer-B');
    final reopened = await link.ta.next<LinkOpened>();
    expect(reopened.peerId, 'peer-B');
    expect(reopened.initiator, isTrue);
    await link.tb.next<LinkOpened>(where: (e) => e.linkId == reopened.linkId);
  });

  test('同じ peerId で再登録すると古い接続が追い出される', () async {
    final a1 = makeTransport('peer-A');
    final t1 = tap(a1);
    await a1.start(TransportConfig(nodeId: _nodeId(1)));
    await _waitUntil(() => hub.peerIds.contains('peer-A'));

    final a2 = makeTransport('peer-A');
    await a2.start(TransportConfig(nodeId: _nodeId(1)));
    // 古い接続は切られ、再接続を試みるが再び追い出されることはない
    // （a2 が生きている間に a1 を止める）。
    await t1.next<TransportState>(where: (e) => !e.poweredOn);
    await a1.stop();
    await _waitUntil(() => hub.clientCount == 1 && hub.peerIds.contains('peer-A'));
  });

  test('ハブ未接続時の connect は LinkClosed、send は StateError', () async {
    final a = makeTransport('peer-A', port: 1);
    final ta = tap(a);
    await a.start(TransportConfig(nodeId: _nodeId(1)));
    expect(a.connected, isFalse);
    expect(a.running, isTrue);
    await a.connect('peer-B');
    final closed = await ta.next<LinkClosed>();
    expect(closed.peerId, 'peer-B');
    expect(() => a.send(1, Uint8List(1)), throwsA(isA<StateError>()));
    await a.stop();
    expect(a.running, isFalse);
  });

  test('peerId を省略するとランダムな peerId が付く', () {
    final a = HubTransport('127.0.0.1', 1);
    final b = HubTransport('127.0.0.1', 1);
    expect(a.peerId, startsWith('hub-'));
    expect(a.peerId.length, 'hub-'.length + 6);
    expect(a.peerId, isNot(b.peerId));
  });
}
