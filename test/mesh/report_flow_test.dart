import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/app/app_controller.dart';
import 'package:kairanban/core/categories.dart';
import 'package:kairanban/core/envelope.dart';
import 'package:kairanban/core/report.dart';
import 'package:kairanban/mesh/groups.dart';
import 'package:kairanban/mesh/store_file.dart';
import 'package:kairanban/transport/fake_transport.dart';

import 'helpers.dart';

/// 出した通知（重要度付き）。
class Shown {
  const Shown(this.id, this.title, this.body, this.importance);

  final int id;
  final String title;
  final String body;
  final NoticeImportance importance;
}

class RecordingPlatform extends NoopPlatformActions {
  final List<Shown> shown = <Shown>[];

  @override
  Future<void> showNotice({
    required int id,
    required String title,
    required String body,
    required int groupCode,
    NoticeImportance importance = NoticeImportance.important,
    int? msgId,
  }) async {
    shown.add(Shown(id, title, body, importance));
  }
}

void main() {
  late FakeRadio radio;
  final controllers = <AppController>[];

  setUp(() {
    radio = FakeRadio(clock: FakeClock(startEpochSeconds: kT0));
    controllers.clear();
  });

  tearDown(() {
    for (final c in controllers) {
      c.dispose();
    }
  });

  Future<AppController> make(
    String id,
    int index, {
    RecordingPlatform? platform,
  }) async {
    final c = AppController(
      transport: radio.createTransport(id),
      storeBackend: MemoryStoreBackend(),
      kv: MemoryKeyValueStore(),
      platform: platform,
      now: radio.clock.now,
      createTimer: radio.clock.createTimer,
      nodeId: nodeIdOf(index),
    );
    controllers.add(c);
    await c.init();
    await c.startMesh();
    return c;
  }

  /// [a] と [b] をすれ違わせる（同じ相手との再同期の待ちを越えるため 2 分進める）。
  Future<void> meet(String a, String b) async {
    await radio.elapse(const Duration(minutes: 2));
    radio.discover(a, b);
    await radio.settle();
    await radio.elapse(const Duration(seconds: 5));
  }

  test('住民の「無事です」は中継されて本部だけに見え、「受け取りました」が本人に返る', () async {
    final hq = await make('HQ', 1);
    final b = await make('B', 2);
    final c = await make('C', 3);
    await hq.saveSettings(hq.settings.copy()..displayName = '〇〇市 防災課');
    final g = await hq.createGroup(
      name: '〇〇市 防災',
      membersCanPost: false,
      acceptsHelp: true,
    );
    await b.joinGroup(g.code);
    await c.joinGroup(g.code);
    // 受け付けているかは group_info で知る。届く前は送れない。
    expect(b.reportGroups, isEmpty);
    await expectLater(
      () => b.sendReport(groupCode: g.code, type: ReportType.safe),
      throwsStateError,
    );

    await meet('B', 'HQ');
    expect(b.groups.byCode(g.code)!.acceptsHelp, isTrue);
    expect(b.reportGroups.map((x) => x.code), [g.code]);
    expect(hq.reportGroups, isEmpty); // 本部は自分に送らない
    expect(hq.seesAnyReports, isTrue);
    expect(b.seesAnyReports, isFalse);

    final env = await b.sendReport(
      groupCode: g.code,
      type: ReportType.safe,
      people: 3,
      name: '山田 花子',
      place: '〇〇町2丁目',
      note: '公民館に います',
    );
    expect(env.kind, MessageKind.help);
    expect(env.category, NoticeCategory.request);
    expect(env.ttlSeconds, ReportType.safe.ttl.inSeconds);
    expect(b.myReports().single.acked, isFalse);
    expect(b.receivedReports(), isEmpty);

    // B → C（住民）: 保存・中継するが表示しない。
    await meet('C', 'B');
    expect(c.store.contains(env.msgId), isTrue);
    expect(c.receivedReports(), isEmpty);
    expect(c.myReports(), isEmpty);

    // C → 本部: 本部の一覧に出る。
    await meet('HQ', 'C');
    final got = hq.receivedReports();
    expect(got.length, 1);
    final e = got.single;
    expect(e.info.type, ReportType.safe);
    expect(e.info.people, 3);
    expect(e.body.senderName, '山田 花子');
    expect(e.body.title, '【無事】山田 花子 さんは 無事です（3人）');
    expect(e.body.place, '〇〇町2丁目');
    expect(e.message.envelope.hop, greaterThanOrEqualTo(1));
    expect(e.acked, isFalse);
    expect(AppController.summarize(got).line(), '無事 1件（3人）');

    final ack = await hq.acknowledgeReport(e.msgId);
    expect(ack, isNotNull);
    expect(ack!.kind, MessageKind.ack);
    expect(ack.supersedes, e.msgId);
    expect(ack.role, SenderRole.official);
    expect(hq.receivedReports().single.acked, isTrue);
    // 2 回目は何もしない。
    expect(await hq.acknowledgeReport(e.msgId), isNull);

    // 本部 → C → B: 本人に「受け取りました」が届く。
    await meet('C', 'HQ');
    await meet('B', 'C');
    final mine = b.myReports().single;
    expect(mine.acked, isTrue);
    expect(b.ackSenderLabel(mine.ack!), '〇〇市 防災課');
    // 住民の端末は「受け取りました」で表示を変えない（置き換え扱いにしない）。
    expect(b.store.isDisplayable(mine.message, b.now), isTrue);
  });

  test('同じ種類は 30 分（SOS は 10 分）たつまで送り直せない。取り消すと本部の一覧から消える', () async {
    final hq = await make('HQ', 1);
    final b = await make('B', 2);
    final g = await hq.createGroup(
      name: '町内会',
      membersCanPost: true,
      acceptsHelp: true,
    );
    await b.joinGroup(g.code);
    await meet('B', 'HQ');

    await b.sendReport(
      groupCode: g.code,
      type: ReportType.need,
      needs: [ReportNeed.water],
    );
    await expectLater(
      () => b.sendReport(
        groupCode: g.code,
        type: ReportType.need,
        needs: [ReportNeed.medical],
      ),
      throwsA(isA<ReportTooSoonException>()),
    );
    // 困りごとは 1 つ以上選ぶ。
    await expectLater(
      () => b.sendReport(groupCode: g.code, type: ReportType.need),
      throwsA(anything),
    );
    // 種類が違えば送れる。
    final sos = await b.sendReport(
      groupCode: g.code,
      type: ReportType.sos,
      people: 1,
    );
    await radio.elapse(const Duration(minutes: 9));
    await expectLater(
      () => b.sendReport(groupCode: g.code, type: ReportType.sos),
      throwsA(isA<ReportTooSoonException>()),
    );
    await radio.elapse(const Duration(minutes: 2));
    await b.sendReport(groupCode: g.code, type: ReportType.sos);
    await radio.elapse(const Duration(minutes: 20));
    await b.sendReport(
      groupCode: g.code,
      type: ReportType.need,
      needs: [ReportNeed.medical],
    );
    expect(b.myReports().length, 4);

    await meet('HQ', 'B');
    expect(hq.receivedReports().length, 4);
    expect(hq.unackedSosCount, 2);

    // 本人が取り消す（もう 大丈夫です）→ 本部の一覧から消える。
    await b.retract(sos.msgId);
    expect(b.myReports().length, 3);
    await meet('HQ', 'B');
    expect(hq.receivedReports().length, 3);
    expect(hq.unackedSosCount, 1);
  });

  test('安否確認（返事を 求める お知らせ）には「受け付ける」が オフでも返事を 送れ、本部で返事ごとに集計できる', () async {
    final hq = await make('HQ', 1);
    final b = await make('B', 2);
    final c = await make('C', 3);
    final g = await hq.createGroup(name: '〇〇市 防災', membersCanPost: false);
    expect(hq.groups.byCode(g.code)!.acceptsHelp, isFalse);
    await b.joinGroup(g.code);
    await c.joinGroup(g.code);

    final request = await hq.postNotice(
      groupCode: g.code,
      category: NoticeCategory.safety,
      title: '安否確認です。下の ボタンで 返事を してください',
      asksReply: true,
    );
    final other = await hq.postNotice(
      groupCode: g.code,
      category: NoticeCategory.water,
      title: '給水します',
    );
    expect(AppController.asksReply(hq.store.get(request.msgId)!), isTrue);
    expect(AppController.asksReply(hq.store.get(other.msgId)!), isFalse);

    await meet('B', 'HQ');
    await meet('C', 'B');
    expect(b.reportGroups, isEmpty); // ホームのボタンは出ない
    expect(b.canReportTo(g.code), isFalse);
    expect(b.canReportTo(g.code, inReplyTo: request.msgId), isTrue);
    expect(b.canReportTo(g.code, inReplyTo: other.msgId), isFalse);
    await expectLater(
      () => b.sendReport(
        groupCode: g.code,
        type: ReportType.safe,
        inReplyTo: other.msgId,
      ),
      throwsStateError,
    );

    await b.sendReport(
      groupCode: g.code,
      type: ReportType.safe,
      people: 2,
      inReplyTo: request.msgId,
    );
    await c.sendReport(
      groupCode: g.code,
      type: ReportType.home,
      people: 4,
      needs: [ReportNeed.water],
      inReplyTo: request.msgId,
    );
    expect(b.myReports(inReplyTo: request.msgId).length, 1);
    expect(b.myReports(inReplyTo: other.msgId), isEmpty);
    // 同じ安否確認への同じ返事は 30 分止めるが、別の安否確認への返事は送れる。
    await expectLater(
      () => b.sendReport(
        groupCode: g.code,
        type: ReportType.safe,
        inReplyTo: request.msgId,
      ),
      throwsA(isA<ReportTooSoonException>()),
    );
    final request2 = await hq.postNotice(
      groupCode: g.code,
      category: NoticeCategory.safety,
      title: '〇〇地区の 安否確認です',
      asksReply: true,
    );
    await meet('B', 'HQ');
    await b.sendReport(
      groupCode: g.code,
      type: ReportType.safe,
      inReplyTo: request2.msgId,
    );
    expect(b.myReports(inReplyTo: request2.msgId).length, 1);

    await meet('B', 'C');
    await meet('HQ', 'B');
    final replies = hq.receivedReports(inReplyTo: request.msgId);
    expect(replies.length, 2);
    expect(hq.receivedReports(inReplyTo: other.msgId), isEmpty);
    expect(AppController.summarize(replies).line(), '無事 1件（2人） ・ 在宅避難 1件（4人）');

    // まとめて「受け取りました」を返す。
    expect(await hq.acknowledgeAll(replies), 2);
    expect(
      hq.receivedReports(inReplyTo: request.msgId).every((e) => e.acked),
      isTrue,
    );
    final text = hq.reportsAsText(hq.receivedReports(inReplyTo: request.msgId));
    expect(text.split('\n').length, 2);
    expect(text, contains('受け取り済み'));

    // 書きなおしても「返事を 求める」は引き継ぐ。
    final rewritten = await hq.supersedeNotice(
      request.msgId,
      title: '安否確認（2回目）です',
    );
    expect(AppController.asksReply(hq.store.get(rewritten.msgId)!), isTrue);
  });

  test('本部の端末は背面で SOS を urgent で、ほかの知らせを まとめて通知し、本人は「受け取りました」を通知で知る', () async {
    final hqPlatform = RecordingPlatform();
    final bPlatform = RecordingPlatform();
    final hq = await make('HQ', 1, platform: hqPlatform);
    final b = await make('B', 2, platform: bPlatform);
    await hq.saveSettings(hq.settings.copy()..displayName = '防災課');
    final g = await hq.createGroup(
      name: '〇〇市',
      membersCanPost: false,
      acceptsHelp: true,
    );
    await b.joinGroup(g.code);
    await meet('B', 'HQ');

    hqPlatform.shown.clear();
    await b.sendReport(
      groupCode: g.code,
      type: ReportType.sos,
      people: 2,
      place: '〇〇町 公民館の 裏',
      note: '2階に います',
    );
    await b.sendReport(groupCode: g.code, type: ReportType.safe, people: 1);
    await b.sendReport(groupCode: g.code, type: ReportType.home, people: 3);

    await meet('HQ', 'B');
    final sos = hqPlatform.shown
        .where((s) => s.importance == NoticeImportance.urgent)
        .toList();
    expect(sos.length, 1);
    expect(sos.single.title, '住民から SOS が 届きました');
    expect(sos.single.body, '場所: 〇〇町 公民館の 裏 ／ 2人 ／ 2階に います');
    await radio.elapse(const Duration(seconds: 6));
    final batched = hqPlatform.shown
        .where((s) => s.importance == NoticeImportance.important)
        .toList();
    expect(batched.length, 1);
    expect(batched.single.title, '住民からの 知らせが 2件 届きました');
    expect(batched.single.body, '無事 1件（1人） ・ 在宅避難 1件（3人）');

    // 前面の本部端末は通知しない（ホームの帯で知らせる）。
    hq.setForeground(true);
    bPlatform.shown.clear();
    for (final e in hq.receivedReports()) {
      await hq.acknowledgeReport(e.msgId);
    }
    expect(hq.unackedSosCount, 0);

    await meet('B', 'HQ');
    final acks = bPlatform.shown
        .where((s) => s.title == '防災課が 受け取りました')
        .toList();
    expect(acks.length, 3);
    expect(acks.map((s) => s.body), contains('【SOS】助けが 必要です（2人）'));

    // 通知オフなら出さない。
    await b.saveSettings(
      b.settings.copy()..notificationLevel = NotificationLevel.off,
    );
    expect(b.myReports().every((e) => e.acked), isTrue);
  });

  test('スタッフも知らせを見て返事ができ、住民の端末は受け取りましたを出せない', () async {
    final hq = await make('HQ', 1);
    final staff = await make('S', 2);
    final b = await make('B', 3);
    final g = await hq.createGroup(
      name: '〇〇市',
      membersCanPost: false,
      acceptsHelp: true,
    );
    await staff.joinGroup(g.code);
    await b.joinGroup(g.code);
    await meet('S', 'HQ');
    final result = await staff.elevate(
      g.code,
      hq.groups.byCode(g.code)!.staffCode!,
    );
    expect(result, ElevateResult.staff);
    expect(staff.seesAnyReports, isTrue);
    expect(staff.reportGroups, isEmpty);
    await meet('B', 'S');

    final env = await b.sendReport(
      groupCode: g.code,
      type: ReportType.need,
      needs: [ReportNeed.toilet, ReportNeed.power],
      people: 2,
    );
    await expectLater(() => b.acknowledgeReport(env.msgId), throwsStateError);
    await meet('S', 'B');
    final e = staff.receivedReports().single;
    expect(e.info.needs, [ReportNeed.toilet, ReportNeed.power]);
    final ack = await staff.acknowledgeReport(e.msgId);
    expect(ack!.role, SenderRole.staff);
    await meet('B', 'S');
    final mine = b.myReports().single;
    expect(b.ackSenderLabel(mine.ack!), 'スタッフ');
  });
}
