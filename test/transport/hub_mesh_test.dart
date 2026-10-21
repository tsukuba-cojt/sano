/// ハブ経由で 2 つの MeshNode が同時に接続し合っても同期が完了することを確かめる。
library;


import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/core/categories.dart';
import 'package:kairanban/core/envelope.dart';
import 'package:kairanban/core/epoch.dart';
import 'package:kairanban/core/ids.dart';
import 'package:kairanban/mesh/mesh_node.dart';
import 'package:kairanban/mesh/message_store.dart';
import 'package:kairanban/mesh/store_file.dart';
import 'package:kairanban/mesh/transport.dart';
import 'package:kairanban/transport/hub_server.dart';
import 'package:kairanban/transport/hub_transport.dart';

Future<void> _until(bool Function() cond, Duration timeout, String what) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('$what を ${timeout.inSeconds} 秒 待ちましたが 満たされませんでした');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  test('同時に接続し合っても切断せずに同期が完了し、投稿が届く', () async {
    final hub = await startHub(port: 0, discoveryInterval: const Duration(milliseconds: 500));
    addTearDown(hub.close);

    final logs = <String>[];
    MeshNode makeNode(String name) {
      final transport = HubTransport('127.0.0.1', hub.port, peerId: name);
      final store = MessageStore(MemoryStoreBackend());
      final node = MeshNode(
          transport: transport, store: store, nodeId: generateNodeId());
      transport.events.listen((e) {
        if (e is TransportLog) {
          logs.add('$name: ${e.message}');
        }
      });
      return node;
    }

    final a = makeNode('A');
    final b = makeNode('B');
    await a.store.load();
    await b.store.load();
    await a.start();
    await b.start();
    addTearDown(() async {
      await a.stop();
      await b.stop();
    });

    // 両者が互いを発見して同時に接続する。
    await _until(() => a.totalSessions >= 1 && b.totalSessions >= 1 &&
        a.activeSessions == 0 && b.activeSessions == 0,
        const Duration(seconds: 15), '最初の同期');

    final disconnects = logs.where((l) => l.contains('接続が切れました')).toList();
    expect(disconnects, isEmpty, reason: logs.join('\n'));

    // A が投稿すると B に届く。
    final now = nowEpochSeconds();
    final env = Envelope.create(
      kind: MessageKind.notice,
      groupId: 123456,
      originId: a.nodeId,
      createdAt: now,
      expiresAt: now + 3600,
      category: NoticeCategory.supply,
      role: SenderRole.official,
      bodyPlain: const NoticeBody(senderName: '防災課', title: '水が とどきました').encode(),
    );
    await a.publish(env);
    await _until(() => b.store.contains(env.msgId), const Duration(seconds: 15),
        'B への配信');
    expect(logs.where((l) => l.contains('接続が切れました')), isEmpty,
        reason: logs.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
