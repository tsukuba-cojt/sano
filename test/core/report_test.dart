import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/core/categories.dart';
import 'package:kairanban/core/envelope.dart';
import 'package:kairanban/core/report.dart';

void main() {
  group('ReportInfo', () {
    test('ext は 4 バイト（返事先なし）/ 12 バイト（返事先あり）で往復する', () {
      const a = ReportInfo(
        type: ReportType.home,
        people: 3,
        needs: [ReportNeed.water, ReportNeed.medical],
        injured: true,
      );
      final ea = a.encode();
      expect(ea.length, kReportExtBaseLength);
      final da = ReportInfo.decode(ea)!;
      expect(da.type, ReportType.home);
      expect(da.people, 3);
      expect(da.needs, [ReportNeed.water, ReportNeed.medical]);
      expect(da.injured, isTrue);
      expect(da.inReplyTo, isNull);

      const b = ReportInfo(
        type: ReportType.safe,
        people: 2,
        inReplyTo: -1234567890123,
      );
      final eb = b.encode();
      expect(eb.length, kReportExtLength);
      final db = ReportInfo.decode(eb)!;
      expect(db.type, ReportType.safe);
      expect(db.inReplyTo, -1234567890123);
    });

    test('短い ext は null、未知の種類は「困っています」、余りと未知のビットは無視', () {
      expect(ReportInfo.decode(null), isNull);
      expect(ReportInfo.decode(Uint8List.fromList([0, 1, 0])), isNull);
      final unknown = ReportInfo.decode(
        Uint8List.fromList([99, 2, 0xC1, 0xFE, 0, 0, 0, 0, 0, 0, 0, 0, 7, 7]),
      )!;
      expect(unknown.type, ReportType.need);
      expect(unknown.needs, [ReportNeed.water]);
      expect(unknown.injured, isFalse);
      expect(unknown.inReplyTo, isNull); // 0 は「なし」
    });

    test('見出しは種類ごとに自動で作り、120 バイトに収める', () {
      expect(
        const ReportInfo(type: ReportType.sos, people: 2).title(),
        '【SOS】助けが 必要です（2人）',
      );
      expect(
        const ReportInfo(type: ReportType.safe, people: 5).title(name: '山田 花子'),
        '【無事】山田 花子 さんは 無事です（5人以上）',
      );
      expect(const ReportInfo(type: ReportType.safe).title(), '【無事】無事です');
      expect(
        const ReportInfo(
          type: ReportType.home,
          people: 3,
          injured: true,
          needs: [ReportNeed.water, ReportNeed.toilet],
        ).title(),
        '【在宅避難】家に います（3人） けが人 あり ・ 水・食べ物が ない ほか',
      );
      final all = const ReportInfo(
        type: ReportType.need,
        people: 4,
        needs: ReportNeed.values,
      ).title();
      expect(all.startsWith('【困りごと】水・食べ物が ない、薬・医療が 必要'), isTrue);
      expect(utf8.encode(all).length, lessThanOrEqualTo(kMaxTitleBytes));
    });

    test('人数の表示', () {
      expect(reportPeopleLabel(0), '');
      expect(reportPeopleLabel(1), '1人');
      expect(reportPeopleLabel(5), '5人以上');
      expect(reportPeopleLabel(9), '5人以上');
    });
  });

  group('ReportSummary', () {
    test('種類ごとの件数・人数と、未返事・未返事の SOS を数える', () {
      final s = ReportSummary.of([
        (info: const ReportInfo(type: ReportType.sos, people: 2), acked: false),
        (info: const ReportInfo(type: ReportType.sos), acked: true),
        (info: const ReportInfo(type: ReportType.safe, people: 3), acked: true),
        (info: const ReportInfo(type: ReportType.safe), acked: false),
        (
          info: const ReportInfo(type: ReportType.home, people: 5),
          acked: false,
        ),
      ]);
      expect(s.total, 5);
      expect(s.counts[ReportType.sos], 2);
      expect(s.people[ReportType.safe], 4); // 人数なしは 1 人と数える
      expect(s.unacked, 3);
      expect(s.unackedSos, 1);
      expect(s.line(), 'SOS 2件 ・ 無事 2件（4人） ・ 在宅避難 1件（5人）');
      expect(ReportSummary.of(const []).line(), 'まだ 届いて いません');
    });
  });

  group('NoticeBody の拡張（5 番目のフィールド）', () {
    test('ext なしは 4 フィールドのまま（旧版と同じバイト列）', () {
      const body = NoticeBody(
        senderName: '防災課',
        title: '給水',
        place: '公民館',
        text: '本文',
      );
      final bytes = body.encode();
      final back = NoticeBody.decode(bytes);
      expect(back.ext, isNull);
      expect(back.title, '給水');
    });

    test('ext 付きは往復し、6 番目以降と壊れた 5 番目は無視する', () {
      final body = NoticeBody(
        senderName: '',
        title: '安否確認です',
        ext: noticeExtAskingReply(),
      );
      final bytes = body.encode();
      final back = NoticeBody.decode(bytes);
      expect(noticeAsksReply(back.ext), isTrue);
      expect(noticeAsksReply(null), isFalse);
      expect(noticeAsksReply(Uint8List(1)), isFalse);

      // 6 番目のフィールドを足しても読める。
      final extended = Uint8List.fromList([...bytes, 2, 0, 0xAA, 0xBB]);
      expect(noticeAsksReply(NoticeBody.decode(extended).ext), isTrue);

      // 5 番目の長さが実データより長い（壊れている）→ ext なしとして読む。
      const plain = NoticeBody(senderName: 'a', title: 'b');
      final broken = Uint8List.fromList([...plain.encode(), 0x10, 0x00, 1]);
      final b2 = NoticeBody.decode(broken);
      expect(b2.title, 'b');
      expect(b2.ext, isNull);

      // 上限（64 バイト）を超える ext は書けない。
      expect(
        () =>
            NoticeBody(senderName: '', title: 't', ext: Uint8List(65)).encode(),
        throwsA(isA<EnvelopeFormatException>()),
      );
    });

    test('kind=help の封筒は ext ごと往復し、help ゲッターで読める', () {
      const info = ReportInfo(type: ReportType.sos, people: 1, inReplyTo: 42);
      final env = Envelope.create(
        kind: MessageKind.help,
        groupId: 123456,
        originId: Uint8List(8),
        createdAt: 1000,
        expiresAt: 1000 + 86400,
        category: NoticeCategory.request,
        role: SenderRole.resident,
        bodyPlain: NoticeBody(
          senderName: '',
          title: info.title(),
          place: '〇〇町2丁目',
          ext: info.encode(),
        ).encode(),
      );
      final back = Envelope.decode(env.encode(), strict: true);
      expect(back.kind, MessageKind.help);
      final body = back.help!;
      expect(body.place, '〇〇町2丁目');
      final decoded = ReportInfo.decode(body.ext)!;
      expect(decoded.type, ReportType.sos);
      expect(decoded.inReplyTo, 42);
      expect(back.notice, isNull);
    });
  });
}
