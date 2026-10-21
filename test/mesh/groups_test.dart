import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/core/envelope.dart' show SenderRole;
import 'package:kairanban/core/ids.dart';
import 'package:kairanban/mesh/groups.dart';

void main() {
  late MemoryKeyValueStore kv;
  late GroupManager gm;

  setUp(() async {
    kv = MemoryKeyValueStore();
    gm = GroupManager(kv, random: Random(42));
    await gm.load();
  });

  test('create: 6 桁コードと 8 桁発信者コードを発行し、ホストとして投稿できる',
      () async {
    final g = await gm.create(
        name: '〇〇市 防災', hostName: '防災課', membersCanPost: false);
    expect(g.code, inInclusiveRange(100000, 999999));
    expect(g.officialCode, matches(RegExp(r'^[1-9]\d{7}$')));
    expect(g.isHost, isTrue);
    expect(g.isOfficial, isTrue);
    expect(g.membersCanPost, isFalse);
    expect(g.canPost, isTrue);
    expect(g.postsAsOfficial, isTrue);
    expect(g.hostName, '防災課');
    expect(gm.groups.length, 1);
    expect(gm.byCode(g.code), same(g));
    expect(gm.codes, {g.code});
  });

  test('JSON で 1 キーに永続化され、再読み込みで復元される', () async {
    final g = await gm.create(
        name: 'A', hostName: 'host', membersCanPost: true);
    await gm.join(222222, name: 'B');
    final raw = kv.snapshot[GroupManager.storageKey];
    expect(raw, isNotNull);
    final json = jsonDecode(raw!) as Map<String, Object?>;
    expect((json['groups'] as List).length, 2);
    expect(kv.snapshot.keys, [GroupManager.storageKey]);

    final gm2 = GroupManager(kv);
    await gm2.load();
    expect(gm2.groups.length, 2);
    final a = gm2.byCode(g.code)!;
    expect(a.name, 'A');
    expect(a.isHost, isTrue);
    expect(a.officialCode, g.officialCode);
    expect(a.hostName, 'host');
    final b = gm2.byCode(222222)!;
    expect(b.name, 'B');
    expect(b.isHost, isFalse);
    expect(b.isOfficial, isFalse);
    expect(b.membersCanPost, isTrue);
    expect(b.officialCode, isNull);
  });

  test('join: 参加者として追加、再 join は同じものを返し名前だけ補完', () async {
    final g = await gm.join(333333);
    expect(g.isHost, isFalse);
    expect(g.name, '');
    expect(g.canPost, isTrue); // membersCanPost 既定 true
    final again = await gm.join(333333, name: '補完された名前');
    expect(identical(g, again), isTrue);
    expect(g.name, '補完された名前');
    final third = await gm.join(333333, name: '別の名前');
    expect(third.name, '補完された名前'); // 既に名前があれば上書きしない
    expect(gm.groups.length, 1);
  });

  test('join: 範囲外のコードは ArgumentError', () async {
    expect(() => gm.join(1000000), throwsArgumentError);
    expect(() => gm.join(-1), throwsArgumentError);
  });

  test('leave で消え、永続化にも反映される', () async {
    await gm.join(444444);
    await gm.join(555555);
    await gm.leave(444444);
    expect(gm.codes, {555555});
    final gm2 = GroupManager(kv);
    await gm2.load();
    expect(gm2.codes, {555555});
    await gm.leave(999999); // 存在しなくてもエラーにならない
  });

  test('elevate: ホスト端末では本部コード／スタッフコードが一致したときだけ昇格する', () async {
    final g = await gm.create(
        name: 'A', hostName: 'h', membersCanPost: false);
    expect(g.hqCode, matches(RegExp(r'^1\d{7}$')));
    expect(g.staffCode, matches(RegExp(r'^2\d{7}$')));
    expect(await gm.elevate(g.code, '00000000'), ElevateResult.invalid);
    expect(await gm.elevate(g.code, '19999999'), ElevateResult.mismatch);
    expect(await gm.elevate(g.code, g.hqCode!), ElevateResult.hq);
    expect(await gm.elevate(g.code, '${g.hqCode!.substring(0, 4)} '
        '${g.hqCode!.substring(4)}'), ElevateResult.hq);
    expect(await gm.elevate(g.code, '29999999'), ElevateResult.mismatch);
    expect(await gm.elevate(g.code, g.staffCode!), ElevateResult.staff);
  });

  test('elevate: 参加者端末はスタッフコードを受理し、本部コードは group_info のダイジェストと照合する',
      () async {
    await gm.join(666666, name: 'G');
    final g = gm.byCode(666666)!;
    expect(g.membersCanPost, isTrue);
    await gm.updatePolicy(666666, membersCanPost: false);
    expect(gm.byCode(666666)!.canPost, isFalse);

    expect(await gm.elevate(666666, 'abc'), ElevateResult.invalid);
    expect(await gm.elevate(666666, '1234567'), ElevateResult.invalid);
    expect(await gm.elevate(666666, '34567890'), ElevateResult.invalid);
    // ダイジェスト未受信: 本部コードは保留、スタッフコードは受理。
    expect(await gm.elevate(666666, '12345678'), ElevateResult.notReady);
    expect(await gm.elevate(666666, '23456789'), ElevateResult.staff);
    final staff = gm.byCode(666666)!;
    expect(staff.isStaff, isTrue);
    expect(staff.isOfficial, isFalse);
    expect(staff.canPost, isTrue);
    expect(staff.postsAsOfficial, isFalse);
    expect(staff.postRole, SenderRole.staff);
    expect(staff.staffCode, '23456789');

    // ダイジェストが届いたら照合する。
    final digest = computeCodeDigest(hqCode: '12345678', staffCode: '23456789');
    await gm.updatePolicy(666666, codeDigestHex: hexOf(digest));
    expect(await gm.elevate(666666, '18765432'), ElevateResult.mismatch);
    expect(await gm.elevate(666666, '12345678'), ElevateResult.hq);
    final hq = gm.byCode(666666)!;
    expect(hq.isOfficial, isTrue);
    expect(hq.postsAsOfficial, isTrue);
    expect(hq.postRole, SenderRole.official);
    expect(hq.hqCode, '12345678');

    final gm2 = GroupManager(kv);
    await gm2.load();
    expect(gm2.byCode(666666)!.isOfficial, isTrue);
    expect(gm2.byCode(666666)!.isStaff, isTrue);
    expect(gm2.byCode(666666)!.membersCanPost, isFalse);

    // ダイジェストと合わないスタッフコードは再検証で外れる。
    await gm.updatePolicy(666666,
        codeDigestHex: hexOf(computeCodeDigest(hqCode: '12345678', staffCode: '20000000')));
    await gm.reverifyStaff(666666);
    expect(gm.byCode(666666)!.isStaff, isFalse);
    expect(gm.byCode(666666)!.isOfficial, isTrue);
  });

  test('elevate: 未参加のグループは notJoined', () async {
    expect(await gm.elevate(777777, '12345678'), ElevateResult.notJoined);
  });

  test('updateName / updatePolicy は変更時だけ保存し通知する', () async {
    await gm.join(888888);
    var notified = 0;
    gm.addListener(() => notified++);
    await gm.updateName(888888, '新しい名前');
    expect(gm.byCode(888888)!.name, '新しい名前');
    expect(notified, 1);
    await gm.updateName(888888, '新しい名前');
    expect(notified, 1);
    await gm.updatePolicy(888888, membersCanPost: true);
    expect(notified, 1);
    await gm.updatePolicy(888888, membersCanPost: false);
    expect(notified, 2);
    await gm.updateName(999999, 'x'); // 未参加は無視
    expect(notified, 2);
  });

  test('壊れた JSON や壊れた項目は読み飛ばして起動できる', () async {
    await kv.setString(GroupManager.storageKey, '{not json');
    final a = GroupManager(kv);
    await a.load();
    expect(a.groups, isEmpty);

    await kv.setString(
        GroupManager.storageKey,
        jsonEncode({
          'groups': [
            {'code': 'bad'},
            {'code': 123456, 'name': 'ok'},
            {'code': 123456, 'name': 'dup'},
            'garbage',
          ],
        }));
    final b = GroupManager(kv);
    await b.load();
    expect(b.groups.length, 1);
    expect(b.byCode(123456)!.name, 'ok');
  });

  test('create はコードの重複を避ける', () async {
    final fixed = _FixedRandom([5, 5, 6]);
    final g = GroupManager(kv, random: fixed);
    await g.load();
    final first = await g.create(name: 'a', hostName: 'h', membersCanPost: true);
    final second =
        await g.create(name: 'b', hostName: 'h', membersCanPost: true);
    expect(first.code, isNot(second.code));
  });
}

/// nextInt が与えた値を順に返す（最後の値を繰り返す）乱数。
class _FixedRandom implements Random {
  _FixedRandom(this._values);
  final List<int> _values;
  int _i = 0;

  @override
  int nextInt(int max) {
    final v = _values[_i < _values.length ? _i : _values.length - 1];
    _i++;
    return v % max;
  }

  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;
}
