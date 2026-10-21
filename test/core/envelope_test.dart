import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/core/categories.dart';
import 'package:kairanban/core/compression.dart';
import 'package:kairanban/core/envelope.dart';
import 'package:kairanban/core/ids.dart';

Uint8List _bytes(List<int> list) => Uint8List.fromList(list);

final Uint8List _originA = _bytes([1, 2, 3, 4, 5, 6, 7, 8]);
final Uint8List _originB = _bytes([8, 7, 6, 5, 4, 3, 2, 1]);

const NoticeBody _shortNotice = NoticeBody(
  senderName: '〇〇市 防災課',
  title: '〇〇小学校に 水と 毛布が とどきました',
  place: '〇〇小学校 体育館',
  text: '午後3時から 配布します。',
);

const String _longText =
    '〇〇小学校 避難所からの お知らせです。本日 午後3時から 体育館で 水と 毛布を 配布します。'
    '一人 一個です。容器を 持ってきてください。数に 限りが あります。なくなり次第 終わります。'
    '高齢者の方と 小さな お子さんが いる方を 優先します。明日の 午前9時から 校庭で 給水車が 来ます。'
    'ポリタンクを 持ってきてください。体調が 悪い方は 1階の 救護所へ 来てください。'
    '余震に 注意してください。詐欺の 電話に 注意してください。分からないことは 受付で 聞いてください。'
    '今日の 炊き出しは 午後5時から 校庭で 行います。おにぎりと みそ汁を 配ります。'
    'トイレは 校舎 1階の ものが 使えます。ご協力 お願いします。〇〇市 防災課 災害対策本部。';

const NoticeBody _longNotice = NoticeBody(
  senderName: '〇〇市 防災課',
  title: '〇〇小学校に 水と 毛布が とどきました',
  place: '〇〇小学校 体育館',
  text: _longText,
);

const GroupInfoBody _groupInfoBody = GroupInfoBody(
  name: '〇〇町 避難所 連絡網',
  hostName: '〇〇町 防災課',
  membersCanPost: false,
  description: '〇〇町の 公式の お知らせを 配ります。',
);

Envelope _notice({
  NoticeBody body = _shortNotice,
  int hop = 0,
  int? supersedes,
  Uint8List? origin,
  NoticeCategory category = NoticeCategory.supply,
  SenderRole role = SenderRole.official,
  int createdAt = 1000,
  int expiresAt = 1000 + 3 * 86400,
}) {
  return Envelope.create(
    kind: MessageKind.notice,
    groupId: 123456,
    originId: origin ?? _originA,
    createdAt: createdAt,
    expiresAt: expiresAt,
    category: category,
    role: role,
    supersedes: supersedes,
    bodyPlain: body.encode(),
  ).copyWith(hop: hop);
}

Envelope _groupInfo() {
  return Envelope.create(
    kind: MessageKind.groupInfo,
    groupId: 654321,
    originId: _originA,
    createdAt: 5000,
    expiresAt: 5000 + 365 * 86400,
    category: NoticeCategory.general,
    role: SenderRole.official,
    bodyPlain: _groupInfoBody.encode(),
  );
}

Envelope _tombstone(int target) {
  return Envelope.create(
    kind: MessageKind.tombstone,
    groupId: 123456,
    originId: _originA,
    createdAt: 2000,
    expiresAt: 2000 + 86400,
    category: NoticeCategory.general,
    role: SenderRole.official,
    supersedes: target,
    bodyPlain: Uint8List(0),
  );
}

void _expectSame(Envelope actual, Envelope expected) {
  expect(actual.kind, expected.kind);
  expect(actual.groupId, expected.groupId);
  expect(actual.msgId, expected.msgId);
  expect(actual.createdAt, expected.createdAt);
  expect(actual.expiresAt, expected.expiresAt);
  expect(actual.hop, expected.hop);
  expect(actual.category, expected.category);
  expect(actual.role, expected.role);
  expect(actual.supersedes, expected.supersedes);
  expect(actual.bodyPlain, expected.bodyPlain);
}

Matcher get _throwsFormat => throwsA(isA<EnvelopeFormatException>());

void main() {
  group('NoticeBody', () {
    test('u16 len + UTF-8 × 4 の配置', () {
      const body = NoticeBody(senderName: 'ab', title: 'c', place: '', text: 'd');
      expect(body.encode(), _bytes([2, 0, 0x61, 0x62, 1, 0, 0x63, 0, 0, 1, 0, 0x64]));
    });

    test('日本語を往復できる（任意フィールドは省略可）', () {
      final decoded = NoticeBody.decode(_shortNotice.encode());
      expect(decoded.senderName, _shortNotice.senderName);
      expect(decoded.title, _shortNotice.title);
      expect(decoded.place, _shortNotice.place);
      expect(decoded.text, _shortNotice.text);

      const minimal = NoticeBody(senderName: '名前なし', title: '見出し');
      final d2 = NoticeBody.decode(minimal.encode());
      expect(d2.place, '');
      expect(d2.text, '');
      expect(NoticeBody.decode(_longNotice.encode()).text, _longText);
    });

    test('フィールド長の上限ちょうどは許可、超過は拒否（エンコード）', () {
      String ascii(int n) => 'a' * n;
      expect(
        NoticeBody(senderName: ascii(48), title: ascii(120), place: ascii(120), text: ascii(3000))
            .encode()
            .length,
        8 + 48 + 120 + 120 + 3000,
      );
      expect(() => NoticeBody(senderName: ascii(49), title: 't').encode(), _throwsFormat);
      expect(() => NoticeBody(senderName: 's', title: ascii(121)).encode(), _throwsFormat);
      expect(() => NoticeBody(senderName: 's', title: 't', place: ascii(121)).encode(),
          _throwsFormat);
      expect(() => NoticeBody(senderName: 's', title: 't', text: ascii(3001)).encode(),
          _throwsFormat);
      // 上限はバイト数（日本語は 1 文字 3 バイト）
      expect(NoticeBody(senderName: 'あ' * 16, title: 't').encode().length, 8 + 48 + 1);
      expect(() => NoticeBody(senderName: 'あ' * 17, title: 't').encode(), _throwsFormat);
    });

    test('フィールド長の超過を拒否（デコード）', () {
      // sender_name の長さフィールドに 49 を入れて 49 バイト分続ける
      final crafted = _bytes([49, 0, ...List.filled(49, 0x61), 1, 0, 0x74, 0, 0, 0, 0]);
      expect(() => NoticeBody.decode(crafted), _throwsFormat);
      // text が 3001 バイト
      final crafted2 = _bytes([
        1, 0, 0x73, 1, 0, 0x74, 0, 0, 0xB9, 0x0B, ...List.filled(3001, 0x61),
      ]);
      expect(() => NoticeBody.decode(crafted2), _throwsFormat);
    });

    test('途中で切れた入力・不正な UTF-8 を拒否し、末尾の余分（将来の 5 番目以降）は無視する', () {
      final valid = _shortNotice.encode();
      for (var n = 0; n < valid.length; n++) {
        expect(() => NoticeBody.decode(valid.sublist(0, n)), _throwsFormat,
            reason: 'truncated@$n');
      }
      expect(NoticeBody.decode(_bytes([...valid, 0])).title, _shortNotice.title);
      expect(NoticeBody.decode(_bytes([...valid, 2, 0, 0x41, 0x42])).text,
          _shortNotice.text);
      // 不正な UTF-8（孤立した継続バイト）
      expect(() => NoticeBody.decode(_bytes([2, 0, 0x80, 0x80, 1, 0, 0x74, 0, 0, 0, 0])),
          _throwsFormat);
      // サロゲートを UTF-8 風に符号化したもの（CESU-8）は不正
      expect(() => NoticeBody.decode(_bytes([3, 0, 0xED, 0xA0, 0x80, 1, 0, 0x74, 0, 0, 0, 0])),
          _throwsFormat);
    });
  });

  group('GroupInfoBody', () {
    test('配置: name, host_name, policy(1 バイト), description', () {
      const body = GroupInfoBody(name: 'g', hostName: 'h', membersCanPost: true, description: 'd');
      expect(body.encode(), _bytes([1, 0, 0x67, 1, 0, 0x68, 1, 0, 0x01, 1, 0, 0x64]));
      const body2 = GroupInfoBody(name: 'g', hostName: 'h', membersCanPost: false);
      expect(body2.encode(), _bytes([1, 0, 0x67, 1, 0, 0x68, 1, 0, 0x00, 0, 0]));
    });

    test('往復できる', () {
      final d = GroupInfoBody.decode(_groupInfoBody.encode());
      expect(d.name, _groupInfoBody.name);
      expect(d.hostName, _groupInfoBody.hostName);
      expect(d.membersCanPost, isFalse);
      expect(d.description, _groupInfoBody.description);
      const open = GroupInfoBody(name: 'n', hostName: 'h');
      expect(GroupInfoBody.decode(open.encode()).membersCanPost, isTrue);
      expect(GroupInfoBody.decode(open.encode()).description, '');
    });

    test('policy の bit0 だけを見る', () {
      final crafted = _bytes([1, 0, 0x67, 1, 0, 0x68, 1, 0, 0x03, 0, 0]);
      expect(GroupInfoBody.decode(crafted).membersCanPost, isTrue);
      final crafted2 = _bytes([1, 0, 0x67, 1, 0, 0x68, 1, 0, 0x02, 0, 0]);
      expect(GroupInfoBody.decode(crafted2).membersCanPost, isFalse);
    });

    test('policy が 1 バイトでなければ拒否', () {
      expect(() => GroupInfoBody.decode(_bytes([1, 0, 0x67, 1, 0, 0x68, 0, 0, 0, 0])),
          _throwsFormat);
      expect(() => GroupInfoBody.decode(_bytes([1, 0, 0x67, 1, 0, 0x68, 2, 0, 1, 1, 0, 0])),
          _throwsFormat);
    });

    test('フィールド長の上限', () {
      String ascii(int n) => 'a' * n;
      expect(
        GroupInfoBody(name: ascii(60), hostName: ascii(48), description: ascii(300))
            .encode()
            .length,
        8 + 60 + 48 + 1 + 300,
      );
      expect(() => GroupInfoBody(name: ascii(61), hostName: 'h').encode(), _throwsFormat);
      expect(() => GroupInfoBody(name: 'n', hostName: ascii(49)).encode(), _throwsFormat);
      expect(() => GroupInfoBody(name: 'n', hostName: 'h', description: ascii(301)).encode(),
          _throwsFormat);
    });

    test('途中で切れた入力を拒否し、末尾の余分（ext より後）は無視する', () {
      final valid = _groupInfoBody.encode();
      for (var n = 0; n < valid.length; n++) {
        expect(() => GroupInfoBody.decode(valid.sublist(0, n)), _throwsFormat,
            reason: 'truncated@$n');
      }
      expect(GroupInfoBody.decode(_bytes([...valid, 0])).name, _groupInfoBody.name);
      // 壊れた ext は「ext なし」として扱う。
      expect(GroupInfoBody.decode(_bytes([...valid, 9, 0, 1])).codeDigest, isNull);
    });

    test('ext（code_digest / generation / successor）を往復できる（C24）', () {
      final digest = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      final body = GroupInfoBody(
        name: 'g',
        hostName: 'h',
        membersCanPost: false,
        closed: true,
        acceptsHelp: true,
        codeDigest: digest,
        generation: 3,
        successor: 654321,
      );
      final d = GroupInfoBody.decode(body.encode());
      expect(d.codeDigest, digest);
      expect(d.generation, 3);
      expect(d.successor, 654321);
      expect(d.closed, isTrue);
      expect(d.acceptsHelp, isTrue);
      expect(d.membersCanPost, isFalse);
      // ext なしの 4 フィールド形式も読める。
      final v1 = GroupInfoBody.decode(_groupInfoBody.encode());
      expect(v1.codeDigest, isNull);
      expect(v1.generation, 0);
      expect(v1.successor, 0);
      expect(v1.hasExt, isFalse);
    });
  });

  group('Envelope.computeMsgId', () {
    test('SHA-256(group_id(3 LE) ‖ kind ‖ origin_id ‖ created_at(4 LE) ‖ body) の先頭 8 バイト', () {
      final body = _shortNotice.encode();
      final env = _notice(body: _shortNotice);
      final input = <int>[
        0x40, 0xE2, 0x01, // 123456 = 0x01E240 LE
        0, // kind=notice
        ..._originA,
        0xE8, 0x03, 0, 0, // created_at=1000 LE
        ...body,
      ];
      final digest = sha256.convert(input).bytes;
      expect(u64ToBytes(env.msgId), _bytes(digest.sublist(0, 8)));
    });

    test('同じ入力なら同じ値、入力が変われば変わる', () {
      final a = _notice();
      expect(_notice().msgId, a.msgId);
      expect(_notice(origin: _originB).msgId, isNot(a.msgId));
      expect(_notice(createdAt: 1001).msgId, isNot(a.msgId));
      expect(
        _notice(body: const NoticeBody(senderName: '〇〇市 防災課', title: '別の見出し')).msgId,
        isNot(a.msgId),
      );
      expect(
        Envelope.computeMsgId(
          groupId: 123457,
          kind: MessageKind.notice,
          originId: _originA,
          createdAt: 1000,
          bodyPlain: _shortNotice.encode(),
        ),
        isNot(a.msgId),
      );
      expect(
        Envelope.computeMsgId(
          groupId: 123456,
          kind: MessageKind.groupInfo,
          originId: _originA,
          createdAt: 1000,
          bodyPlain: _shortNotice.encode(),
        ),
        isNot(a.msgId),
      );
    });

    test('hop / category / role / expires_at に依存せず、supersedes には依存する', () {
      final a = _notice();
      expect(_notice(hop: 5).msgId, a.msgId);
      expect(_notice(hop: 255).msgId, a.msgId);
      expect(_notice(category: NoticeCategory.warning).msgId, a.msgId);
      expect(_notice(role: SenderRole.resident).msgId, a.msgId);
      expect(_notice(expiresAt: 999999).msgId, a.msgId);
      // 同じ秒に出した複数の取り消しが衝突しないよう、対象 ID は含める（v2）。
      expect(_notice(supersedes: 12345).msgId, isNot(a.msgId));
      expect(_notice(supersedes: 12345).msgId, _notice(supersedes: 12345).msgId);
      expect(_tombstone(1).msgId, isNot(_tombstone(2).msgId));
    });

    test('originId は 8 バイト必須', () {
      expect(
        () => Envelope.computeMsgId(
          groupId: 1,
          kind: MessageKind.notice,
          originId: Uint8List(7),
          createdAt: 0,
          bodyPlain: Uint8List(0),
        ),
        throwsArgumentError,
      );
    });
  });

  group('Envelope.encode', () {
    test('ヘッダ 28 バイトの配置（非圧縮）', () {
      final env = _notice(hop: 3);
      final body = _shortNotice.encode();
      final bytes = env.encode(compress: false);
      expect(bytes.length, 28 + body.length);
      expect(bytes[0], 0x4B);
      expect(bytes[1], 1);
      expect(bytes[2], 0); // notice
      expect(bytes[3], 0); // flags
      expect(bytes.sublist(4, 7), _bytes([0x40, 0xE2, 0x01]));
      expect(bytes.sublist(7, 15), u64ToBytes(env.msgId));
      expect(bytes.sublist(15, 19), _bytes([0xE8, 0x03, 0, 0]));
      final view = ByteData.sublistView(bytes);
      expect(view.getUint32(19, Endian.little), 1000 + 3 * 86400);
      expect(bytes[23], 3); // hop
      expect(bytes[24], NoticeCategory.supply.code);
      expect(bytes[25], SenderRole.official.code);
      expect(view.getUint16(26, Endian.little), body.length);
      expect(bytes.sublist(28), body);
    });

    test('supersedes があれば flags bit1 とヘッダ 36 バイト', () {
      final env = _notice(supersedes: -2);
      final bytes = env.encode(compress: false);
      expect(bytes[3] & 0x02, 0x02);
      expect(bytes.sublist(28, 36), u64ToBytes(-2));
      expect(bytes.length, 36 + _shortNotice.encode().length);
    });

    test('tombstone は body 空、supersedes 必須', () {
      final env = _tombstone(777);
      final bytes = env.encode();
      expect(bytes.length, 36);
      expect(bytes[2], 2);
      expect(bytes[3], 0x02);
      expect(bytes.sublist(28, 36), u64ToBytes(777));
      expect(ByteData.sublistView(bytes).getUint16(26, Endian.little), 0);
    });

    test('圧縮して縮むときだけ flags bit0 を立てる', () {
      final long = _notice(body: _longNotice);
      final plain = _longNotice.encode();
      final compressed = long.encode();
      expect(compressed[3] & 0x01, 0x01);
      final bodyLen = ByteData.sublistView(compressed).getUint16(26, Endian.little);
      expect(bodyLen, lessThan(plain.length));
      expect(compressed.length, 28 + bodyLen);
      expect(compressed.length, lessThan(28 + plain.length));

      // compress: false なら決して立てない
      final raw = long.encode(compress: false);
      expect(raw[3] & 0x01, 0);
      expect(raw.sublist(28), plain);

      // 縮まない body（ごく短い）はそのまま載せる
      const tiny = NoticeBody(senderName: 'a', title: 'b');
      final tinyBody = tiny.encode();
      expect(compressBody(tinyBody).length, greaterThanOrEqualTo(tinyBody.length),
          reason: 'このテストの前提: 圧縮しても縮まない body');
      final tinyEnv = _notice(body: tiny).encode();
      expect(tinyEnv[3] & 0x01, 0);
      expect(tinyEnv.sublist(28), tinyBody);
    });
  });

  group('Envelope.decode 往復', () {
    test('notice（圧縮あり / なし）', () {
      for (final body in [_shortNotice, _longNotice]) {
        final env = _notice(body: body, hop: 2);
        for (final compress in [true, false]) {
          final decoded = Envelope.decode(env.encode(compress: compress));
          _expectSame(decoded, env);
          expect(decoded.notice!.title, body.title);
          expect(decoded.notice!.text, body.text);
          expect(decoded.groupInfo, isNull);
        }
      }
    });

    test('notice + supersedes（訂正）', () {
      final target = _notice().msgId;
      final env = _notice(body: _longNotice, supersedes: target, hop: 1);
      final decoded = Envelope.decode(env.encode());
      _expectSame(decoded, env);
      expect(decoded.supersedes, target);
    });

    test('group_info', () {
      final env = _groupInfo();
      final decoded = Envelope.decode(env.encode());
      _expectSame(decoded, env);
      expect(decoded.groupInfo!.name, _groupInfoBody.name);
      expect(decoded.groupInfo!.hostName, _groupInfoBody.hostName);
      expect(decoded.groupInfo!.membersCanPost, isFalse);
      expect(decoded.groupInfo!.description, _groupInfoBody.description);
      expect(decoded.notice, isNull);
    });

    test('tombstone', () {
      final env = _tombstone(_notice().msgId);
      final decoded = Envelope.decode(env.encode());
      _expectSame(decoded, env);
      expect(decoded.notice, isNull);
      expect(decoded.groupInfo, isNull);
      expect(decoded.bodyPlain, isEmpty);
    });

    test('hop は保存され msg_id は hop に依存しない', () {
      final base = _notice(body: _longNotice);
      for (final hop in [0, 1, 63, 64, 255]) {
        final decoded = Envelope.decode(base.copyWith(hop: hop).encode());
        expect(decoded.hop, hop);
        expect(decoded.msgId, base.msgId);
        expect(u64ToBytes(decoded.msgId), u64ToBytes(base.msgId));
      }
    });

    test('最大サイズの notice を往復できる', () {
      final rng = Random(5);
      // 辞書に沿わないランダムな日本語で 3,000 バイト（1,000 文字）
      final text = String.fromCharCodes(
          List.generate(1000, (_) => 0x4E00 + rng.nextInt(0x2000)));
      final body = NoticeBody(
        senderName: 'あ' * 16,
        title: 'い' * 40,
        place: 'う' * 40,
        text: text,
      );
      expect(body.encode().length, 8 + 48 + 120 + 120 + 3000);
      final env = _notice(body: body);
      for (final compress in [true, false]) {
        final decoded = Envelope.decode(env.encode(compress: compress));
        _expectSame(decoded, env);
        expect(decoded.notice!.text, text);
      }
    });

    test('全カテゴリ・全役割を往復できる', () {
      for (final c in NoticeCategory.values) {
        for (final r in SenderRole.values) {
          final env = _notice(category: c, role: r);
          final decoded = Envelope.decode(env.encode());
          expect(decoded.category, c);
          expect(decoded.role, r);
        }
      }
    });

    test('group_id の両端を往復できる', () {
      for (final gid in [0, 1, 999999]) {
        final env = Envelope.create(
          kind: MessageKind.notice,
          groupId: gid,
          originId: _originA,
          createdAt: 0,
          expiresAt: 0xFFFFFFFF,
          category: NoticeCategory.general,
          role: SenderRole.resident,
          bodyPlain: _shortNotice.encode(),
        );
        final decoded = Envelope.decode(env.encode());
        expect(decoded.groupId, gid);
        expect(decoded.createdAt, 0);
        expect(decoded.expiresAt, 0xFFFFFFFF);
      }
    });
  });

  group('Envelope.decode 検証', () {
    late Uint8List valid;
    setUp(() {
      valid = _notice().encode(compress: false);
    });

    Uint8List mutate(void Function(Uint8List b) f) {
      final b = Uint8List.fromList(valid);
      f(b);
      return b;
    }

    test('ヘッダが短い', () {
      expect(() => Envelope.decode(Uint8List(0)), _throwsFormat);
      expect(() => Envelope.decode(Uint8List(27)), _throwsFormat);
      expect(() => Envelope.decode(valid.sublist(0, 27)), _throwsFormat);
    });

    /// 未知の形式は strict なら拒否、既定では不透明メッセージとして受け取る（C13）。
    void expectOpaque(Uint8List bytes, {int? version}) {
      expect(() => Envelope.decode(bytes, strict: true), _throwsFormat);
      final opaque = Envelope.decode(bytes);
      expect(opaque.isOpaque, isTrue);
      expect(opaque.kind, MessageKind.unknown);
      expect(opaque.isDisplayable, isFalse);
      expect(opaque.notice, isNull);
      expect(opaque.bodyPlain, isEmpty);
      expect(opaque.msgId, _notice().msgId);
      if (version != null) {
        expect(opaque.version, version);
      }
      // 生バイトのまま中継でき、hop と expires_at だけ書き換わる。
      final relayed = opaque.copyWith(hop: 7, expiresAt: 1234).encode();
      expect(relayed.length, bytes.length);
      expect(relayed[23], 7);
      expect(ByteData.sublistView(relayed).getUint32(19, Endian.little), 1234);
      expect(relayed.sublist(28), bytes.sublist(28));
    }

    test('magic は常に拒否、version の不一致は不透明メッセージ', () {
      expect(() => Envelope.decode(mutate((b) => b[0] = 0x4C)), _throwsFormat);
      expect(() => Envelope.decode(mutate((b) => b[0] = 0x4C), strict: true), _throwsFormat);
      expectOpaque(mutate((b) => b[1] = 0), version: 0);
      expectOpaque(mutate((b) => b[1] = 2), version: 2);
    });

    test('未知の kind / 予約 flags / 未知の role は不透明メッセージ', () {
      // kind 3（help）は notice と同じ body なので通常どおり読める。
      expect(Envelope.decode(mutate((b) => b[2] = 3)).kind, MessageKind.help);
      final cases = <void Function(Uint8List)>[
        (b) => b[2] = 5,
        (b) => b[2] = 255,
        (b) => b[3] = 0x04,
        (b) => b[3] = 0x80,
        (b) => b[25] = 3,
        (b) => b[25] = 255,
      ];
      for (final f in cases) {
        expectOpaque(mutate(f));
      }
    });

    test('category の範囲外は general として受理する', () {
      final decoded = Envelope.decode(mutate((b) => b[24] = 200));
      expect(decoded.category, NoticeCategory.general);
    });

    test('group_id > 999999', () {
      // 1,000,000 = 0x0F4240
      expect(
        () => Envelope.decode(mutate((b) {
          b[4] = 0x40;
          b[5] = 0x42;
          b[6] = 0x0F;
        })),
        _throwsFormat,
      );
      expect(
        () => Envelope.decode(mutate((b) {
          b[4] = 0xFF;
          b[5] = 0xFF;
          b[6] = 0xFF;
        })),
        _throwsFormat,
      );
    });

    test('expires_at < created_at', () {
      expect(
        () => Envelope.decode(mutate((b) {
          ByteData.sublistView(b).setUint32(19, 999, Endian.little);
        })),
        _throwsFormat,
      );
      // ちょうど同じなら許可
      final same = Envelope.decode(mutate((b) {
        ByteData.sublistView(b).setUint32(19, 1000, Endian.little);
      }));
      expect(same.expiresAt, 1000);
    });

    test('body_len と実長の不一致', () {
      expect(() => Envelope.decode(_bytes([...valid, 0])), _throwsFormat);
      expect(() => Envelope.decode(valid.sublist(0, valid.length - 1)), _throwsFormat);
      expect(
        () => Envelope.decode(mutate((b) {
          ByteData.sublistView(b).setUint16(26, 5, Endian.little);
        })),
        _throwsFormat,
      );
      expect(
        () => Envelope.decode(mutate((b) {
          ByteData.sublistView(b).setUint16(26, 0xFFFF, Endian.little);
        })),
        _throwsFormat,
      );
    });

    test('body_len > 4096 は本体を見る前に拒否', () {
      final header = Uint8List.fromList(valid.sublist(0, 28));
      ByteData.sublistView(header).setUint16(26, 4097, Endian.little);
      final crafted = _bytes([...header, ...List.filled(4097, 0)]);
      expect(() => Envelope.decode(crafted), _throwsFormat);
    });

    test('supersedes flag があるのに 8 バイト足りない', () {
      final header = Uint8List.fromList(valid.sublist(0, 28));
      header[3] = 0x02;
      ByteData.sublistView(header).setUint16(26, 0, Endian.little);
      expect(() => Envelope.decode(header), _throwsFormat);
      expect(() => Envelope.decode(_bytes([...header, 1, 2, 3])), _throwsFormat);
    });

    /// body が読めないものは strict なら拒否、既定では不透明メッセージ。
    void expectBodyOpaque(Uint8List bytes) {
      expect(() => Envelope.decode(bytes, strict: true), _throwsFormat);
      final opaque = Envelope.decode(bytes);
      expect(opaque.isOpaque, isTrue);
      expect(opaque.kind, MessageKind.unknown);
      expect(opaque.bodyPlain, isEmpty);
    }

    test('tombstone は supersedes 必須・body 空（満たさなければ不透明メッセージ）', () {
      final ts = _tombstone(1).encode();
      // flags から supersedes を落とし、長さを合わせる
      final noSupersedes = Uint8List.fromList(ts.sublist(0, 28));
      noSupersedes[3] = 0;
      expectBodyOpaque(noSupersedes);
      // body を 1 バイト付ける
      final withBody = Uint8List.fromList([...ts, 0x41]);
      ByteData.sublistView(withBody).setUint16(26, 1, Endian.little);
      expectBodyOpaque(withBody);
    });

    test('圧縮 flag の不正（空 / ごみ / 非圧縮 body に flag）は不透明メッセージ', () {
      final ts = _tombstone(1).encode();
      final emptyCompressed = Uint8List.fromList(ts);
      emptyCompressed[3] |= 0x01;
      expectBodyOpaque(emptyCompressed);

      // 非圧縮の body に圧縮 flag
      expectBodyOpaque(mutate((b) => b[3] |= 0x01));

      // ごみ body
      final header = Uint8List.fromList(valid.sublist(0, 28));
      header[3] = 0x01;
      ByteData.sublistView(header).setUint16(26, 8, Endian.little);
      expectBodyOpaque(_bytes([...header, 0xFF, 0xFE, 0xFD, 0xFC, 1, 2, 3, 4]));
    });

    test('伸長爆弾は伸長せず不透明メッセージとして扱う（strict なら拒否）', () {
      final bomb = compressBody(Uint8List(2 * 1024 * 1024));
      expect(bomb.length, lessThan(4096));
      final header = Uint8List.fromList(valid.sublist(0, 28));
      header[3] = 0x01;
      ByteData.sublistView(header).setUint16(26, bomb.length, Endian.little);
      expectBodyOpaque(_bytes([...header, ...bomb]));

      // 伸長後ちょうど 4,097 バイトも同じ
      final over = compressBody(Uint8List(4097));
      ByteData.sublistView(header).setUint16(26, over.length, Endian.little);
      expectBodyOpaque(_bytes([...header, ...over]));
    });

    test('body のフィールド長超過は不透明メッセージ、末尾の余分は無視（圧縮あり・なし）', () {
      final badBody = _bytes([49, 0, ...List.filled(49, 0x61), 1, 0, 0x74, 0, 0, 0, 0]);
      final header = Uint8List.fromList(valid.sublist(0, 28));
      ByteData.sublistView(header).setUint16(26, badBody.length, Endian.little);
      expectBodyOpaque(_bytes([...header, ...badBody]));

      final compressedBad = compressBody(badBody);
      header[3] = 0x01;
      ByteData.sublistView(header).setUint16(26, compressedBad.length, Endian.little);
      expectBodyOpaque(_bytes([...header, ...compressedBad]));

      final trailing = _bytes([..._shortNotice.encode(), 0]);
      header[3] = 0;
      ByteData.sublistView(header).setUint16(26, trailing.length, Endian.little);
      final decoded = Envelope.decode(_bytes([...header, ...trailing]));
      expect(decoded.isOpaque, isFalse);
      expect(decoded.notice!.title, _shortNotice.title);
    });

    test('group_info の body が notice 形式なら不透明メッセージ', () {
      final gi = Uint8List.fromList(valid);
      gi[2] = 1; // kind=group_info だが body は notice
      expectBodyOpaque(gi);
    });

    test('空殻（body を消した notice）は保存用に往復でき、送信用には使わない', () {
      final env = _notice(supersedes: 42);
      final stub = env.asStub();
      expect(stub.isStub, isTrue);
      expect(stub.notice, isNull);
      expect(stub.msgId, env.msgId);
      final bytes = stub.encode();
      expect(bytes.length, 36);
      final back = Envelope.decodeStub(bytes);
      expect(back.isStub, isTrue);
      expect(back.msgId, env.msgId);
      expect(back.supersedes, 42);
      expect(back.category, env.category);
    });
  });

  group('Envelope.decode 耐性（不正入力は EnvelopeFormatException 以外を投げない）', () {
    final samples = <Uint8List>[
      _notice().encode(compress: false),
      _notice(body: _longNotice).encode(),
      _notice(body: _longNotice, supersedes: 99).encode(),
      _groupInfo().encode(),
      _tombstone(123).encode(),
    ];

    void check(Uint8List input, String reason) {
      try {
        final env = Envelope.decode(input);
        expect(env.bodyPlain.length, lessThanOrEqualTo(kMaxBodyPlainBytes), reason: reason);
      } on EnvelopeFormatException {
        // 期待どおり
      } catch (e) {
        fail('$reason: 想定外の例外 ${e.runtimeType}: $e');
      }
    }

    test('途中で切れた封筒は必ず拒否される', () {
      for (var s = 0; s < samples.length; s++) {
        final bytes = samples[s];
        for (var n = 0; n < bytes.length; n++) {
          expect(() => Envelope.decode(bytes.sublist(0, n)), _throwsFormat,
              reason: 'sample=$s truncated@$n');
        }
      }
    });

    test('ビット反転', () {
      final rng = Random(2026);
      for (var i = 0; i < 3000; i++) {
        final m = Uint8List.fromList(samples[i % samples.length]);
        final flips = 1 + rng.nextInt(4);
        for (var f = 0; f < flips; f++) {
          m[rng.nextInt(m.length)] ^= 1 << rng.nextInt(8);
        }
        check(m, 'flip#$i');
      }
    });

    test('ランダムなごみ', () {
      final rng = Random(7);
      for (var i = 0; i < 2000; i++) {
        final n = rng.nextInt(120);
        final g = _bytes(List.generate(n, (_) => rng.nextInt(256)));
        check(g, 'garbage#$i');
        if (n >= 2) {
          // magic / version を正しくして奥まで進ませる
          g[0] = 0x4B;
          g[1] = 1;
          check(g, 'garbage-with-magic#$i');
        }
      }
    });

    test('末尾の切り詰め + ごみの付加の組み合わせ', () {
      final rng = Random(3);
      for (var i = 0; i < 500; i++) {
        final s = samples[rng.nextInt(samples.length)];
        final cut = rng.nextInt(s.length + 1);
        final extra = List.generate(rng.nextInt(40), (_) => rng.nextInt(256));
        check(_bytes([...s.sublist(0, cut), ...extra]), 'mix#$i');
      }
    });
  });

  group('Envelope その他', () {
    test('isExpiredAt は expires_at ちょうどまで有効', () {
      final env = _notice(createdAt: 1000, expiresAt: 2000);
      expect(env.isExpiredAt(1999), isFalse);
      expect(env.isExpiredAt(2000), isFalse);
      expect(env.isExpiredAt(2001), isTrue);
    });

    test('copyWith は hop だけを変える', () {
      final env = _notice(body: _longNotice, supersedes: 5);
      final copy = env.copyWith(hop: 9);
      expect(copy.hop, 9);
      _expectSame(copy.copyWith(hop: env.hop), env);
      expect(env.copyWith().hop, env.hop);
    });

    test('コンストラクタは範囲外を ArgumentError で拒否', () {
      Envelope make({
        int groupId = 1,
        int createdAt = 10,
        int expiresAt = 20,
        int hop = 0,
        MessageKind kind = MessageKind.notice,
        int? supersedes,
        Uint8List? body,
      }) {
        return Envelope(
          kind: kind,
          groupId: groupId,
          msgId: 1,
          createdAt: createdAt,
          expiresAt: expiresAt,
          hop: hop,
          supersedes: supersedes,
          bodyPlain: body ?? _shortNotice.encode(),
        );
      }

      expect(() => make(), returnsNormally);
      expect(() => make(groupId: -1), throwsArgumentError);
      expect(() => make(groupId: 1000000), throwsArgumentError);
      expect(() => make(createdAt: 30), throwsArgumentError);
      expect(() => make(createdAt: -1), throwsArgumentError);
      expect(() => make(expiresAt: 0x100000000), throwsArgumentError);
      expect(() => make(hop: 256), throwsArgumentError);
      expect(() => make(hop: -1), throwsArgumentError);
      expect(() => make(body: Uint8List(4097)), throwsArgumentError);
      expect(() => make(kind: MessageKind.tombstone, body: Uint8List(0)), throwsArgumentError);
      expect(
        () => make(kind: MessageKind.tombstone, supersedes: 1, body: Uint8List(1)),
        throwsArgumentError,
      );
      expect(() => make(kind: MessageKind.tombstone, supersedes: 1, body: Uint8List(0)),
          returnsNormally);
    });

    test('MessageKind / SenderRole のコードとラベル', () {
      expect(MessageKind.notice.code, 0);
      expect(MessageKind.groupInfo.code, 1);
      expect(MessageKind.tombstone.code, 2);
      expect(MessageKind.help.code, 3);
      expect(MessageKind.ack.code, 4);
      expect(MessageKind.unknown.code, 0xFF);
      expect(MessageKind.fromCode(3), MessageKind.help);
      expect(MessageKind.fromCode(4), MessageKind.ack);
      expect(MessageKind.fromCode(5), isNull);
      expect(MessageKind.fromCode(0xFF), isNull);
      expect(SenderRole.resident.code, 0);
      expect(SenderRole.staff.code, 1);
      expect(SenderRole.official.code, 2);
      expect(SenderRole.fromCode(3), isNull);
      expect(SenderRole.values.map((r) => r.label).toList(), ['住民', 'スタッフ', '公式']);
    });

    test('toString は例外を投げない', () {
      expect(_notice().toString(), contains('notice'));
      expect(_groupInfo().toString(), contains('groupInfo'));
      expect(_tombstone(1).toString(), contains('tombstone'));
      expect(_shortNotice.toString(), contains(_shortNotice.title));
      expect(_groupInfoBody.toString(), contains(_groupInfoBody.name));
      expect(const EnvelopeFormatException('x').toString(), contains('x'));
      expect(utf8.encode(_longText).length, greaterThan(300));
    });
  });
}
