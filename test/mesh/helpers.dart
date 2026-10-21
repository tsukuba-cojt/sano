/// test/mesh 共通の補助。封筒の生成と、FakeRadio 上のノード一式。
library;

import 'dart:typed_data';

import 'package:kairanban/core/categories.dart';
import 'package:kairanban/core/envelope.dart';
import 'package:kairanban/mesh/mesh_node.dart';
import 'package:kairanban/mesh/message_store.dart';
import 'package:kairanban/mesh/store_file.dart';
import 'package:kairanban/transport/fake_transport.dart';

/// テストの基準時刻（エポック秒。2026-10-11 頃）。
const int kT0 = 283 * 24 * 3600 + 15 * 3600;

const int kGroupA = 123456;
const int kGroupB = 654321;

/// 決定論的なノード ID。
Uint8List nodeIdOf(int n) => Uint8List.fromList([
      n & 0xFF,
      (n >> 8) & 0xFF,
      (n >> 16) & 0xFF,
      0x10,
      0x20,
      0x30,
      0x40,
      0xA5,
    ]);

Envelope makeNotice({
  required Uint8List origin,
  required int createdAt,
  int groupId = kGroupA,
  int? expiresAt,
  Duration ttl = const Duration(days: 3),
  NoticeCategory category = NoticeCategory.general,
  SenderRole role = SenderRole.resident,
  String senderName = '防災課',
  String title = '〇〇小学校に 水と 毛布が とどきました',
  String place = '〇〇小学校',
  String text = '',
  int? supersedes,
  int hop = 0,
}) {
  final env = Envelope.create(
    kind: MessageKind.notice,
    groupId: groupId,
    originId: origin,
    createdAt: createdAt,
    expiresAt: expiresAt ?? createdAt + ttl.inSeconds,
    category: category,
    role: role,
    supersedes: supersedes,
    bodyPlain: NoticeBody(
      senderName: senderName,
      title: title,
      place: place,
      text: text,
    ).encode(),
  );
  return hop == 0 ? env : env.copyWith(hop: hop);
}

Envelope makeGroupInfo({
  required Uint8List origin,
  required int createdAt,
  int groupId = kGroupA,
  String name = '〇〇市 防災グループ',
  String hostName = '〇〇市 防災課',
  bool membersCanPost = true,
  Duration ttl = const Duration(days: 365),
}) {
  return Envelope.create(
    kind: MessageKind.groupInfo,
    groupId: groupId,
    originId: origin,
    createdAt: createdAt,
    expiresAt: createdAt + ttl.inSeconds,
    category: NoticeCategory.general,
    role: SenderRole.official,
    bodyPlain: GroupInfoBody(
      name: name,
      hostName: hostName,
      membersCanPost: membersCanPost,
    ).encode(),
  );
}

Envelope makeTombstone({
  required Uint8List origin,
  required Envelope target,
  required int createdAt,
  int? expiresAt,
}) {
  return Envelope.create(
    kind: MessageKind.tombstone,
    groupId: target.groupId,
    originId: origin,
    createdAt: createdAt,
    expiresAt: expiresAt ?? target.expiresAt + 24 * 3600,
    category: target.category,
    role: target.role,
    supersedes: target.msgId,
    bodyPlain: Uint8List(0),
  );
}

/// ストア内の msg_id 集合。
Set<int> idsOf(MessageStore store) => store.all.map((m) => m.msgId).toSet();

/// FakeRadio 上の 1 ノード（トランスポート + ストア + MeshNode）。
class TestNode {
  TestNode(
    this.radio,
    this.id, {
    required int index,
    int maxMessages = 3000,
    int sessionByteBudget = 65536,
    int maxInitiatorLinks = 2,
  })  : transport = radio.createTransport(id),
        backend = MemoryStoreBackend(),
        nodeId = nodeIdOf(index) {
    store = MessageStore(backend, maxMessages: maxMessages);
    node = MeshNode(
      transport: transport,
      store: store,
      nodeId: nodeId,
      now: radio.clock.now,
      createTimer: radio.clock.createTimer,
      sessionByteBudget: sessionByteBudget,
      maxInitiatorLinks: maxInitiatorLinks,
    );
  }

  final FakeRadio radio;
  final String id;
  final FakeTransport transport;
  final MemoryStoreBackend backend;
  final Uint8List nodeId;
  late final MessageStore store;
  late final MeshNode node;

  Future<void> start() async {
    await store.load();
    await node.start();
  }

  Future<void> dispose() async {
    node.dispose();
    await transport.dispose();
  }
}
