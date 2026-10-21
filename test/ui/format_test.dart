import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/ui/format.dart';

void main() {
  group('formatTimeJa', () {
    test('午後の時刻は 12 時間制で「午後3時20分」', () {
      expect(formatTimeJa(DateTime(2026, 10, 11, 15, 20)), '午後3時20分');
    });

    test('午前の時刻は「午前9時05分」（分は 2 桁）', () {
      expect(formatTimeJa(DateTime(2026, 10, 11, 9, 5)), '午前9時05分');
    });

    test('0 時台は「午前0時」、12 時台は「午後0時」', () {
      expect(formatTimeJa(DateTime(2026, 1, 1, 0, 0)), '午前0時00分');
      expect(formatTimeJa(DateTime(2026, 1, 1, 0, 30)), '午前0時30分');
      expect(formatTimeJa(DateTime(2026, 1, 1, 12, 0)), '午後0時00分');
      expect(formatTimeJa(DateTime(2026, 1, 1, 12, 59)), '午後0時59分');
    });

    test('11 時台は午前、23 時台は午後 11 時', () {
      expect(formatTimeJa(DateTime(2026, 1, 1, 11, 59)), '午前11時59分');
      expect(formatTimeJa(DateTime(2026, 1, 1, 23, 1)), '午後11時01分');
    });
  });

  group('formatDateTimeJa', () {
    test('docs の例「2026年10月11日 午後3時20分」', () {
      expect(
        formatDateTimeJa(DateTime(2026, 10, 11, 15, 20)),
        '2026年10月11日 午後3時20分',
      );
    });

    test('月日はゼロ埋めしない', () {
      expect(
        formatDateTimeJa(DateTime(2027, 1, 2, 8, 0)),
        '2027年1月2日 午前8時00分',
      );
    });
  });

  group('formatDateJa', () {
    test('「10月9日（木）」のように曜日を付ける', () {
      // 2026-10-09 は金曜、10-08 は木曜。
      expect(formatDateJa(DateTime(2026, 10, 9)), '10月9日（金）');
      expect(formatDateJa(DateTime(2026, 10, 8)), '10月8日（木）');
    });

    test('曜日 7 種がすべて出る', () {
      // 2026-10-05（月）〜 2026-10-11（日）
      final labels = [
        for (var d = 5; d <= 11; d++) formatDateJa(DateTime(2026, 10, d)),
      ];
      expect(labels, [
        '10月5日（月）',
        '10月6日（火）',
        '10月7日（水）',
        '10月8日（木）',
        '10月9日（金）',
        '10月10日（土）',
        '10月11日（日）',
      ]);
    });
  });

  group('formatRelativeJa', () {
    test('1 分未満は「たった今」', () {
      expect(formatRelativeJa(Duration.zero), 'たった今');
      expect(formatRelativeJa(const Duration(seconds: 59)), 'たった今');
    });

    test('未来（時計のずれ）も「たった今」', () {
      expect(formatRelativeJa(const Duration(minutes: -5)), 'たった今');
    });

    test('1 時間未満は分', () {
      expect(formatRelativeJa(const Duration(minutes: 1)), '1分前');
      expect(formatRelativeJa(const Duration(minutes: 59, seconds: 59)), '59分前');
    });

    test('24 時間未満は時間', () {
      expect(formatRelativeJa(const Duration(hours: 1)), '1時間前');
      expect(formatRelativeJa(const Duration(hours: 2, minutes: 30)), '2時間前');
      expect(formatRelativeJa(const Duration(hours: 23, minutes: 59)), '23時間前');
    });

    test('1 日以上は日', () {
      expect(formatRelativeJa(const Duration(days: 1)), '1日前');
      expect(formatRelativeJa(const Duration(days: 10, hours: 5)), '10日前');
    });
  });

  group('formatDurationJa', () {
    test('有効期限の 4 択', () {
      expect(formatDurationJa(const Duration(hours: 12)), '12時間');
      expect(formatDurationJa(const Duration(days: 1)), '1日');
      expect(formatDurationJa(const Duration(days: 3)), '3日');
      expect(formatDurationJa(const Duration(days: 7)), '7日');
    });

    test('割り切れないときは細かい単位', () {
      expect(formatDurationJa(const Duration(hours: 36)), '36時間');
      expect(formatDurationJa(const Duration(minutes: 90)), '90分');
      expect(formatDurationJa(const Duration(minutes: 30)), '30分');
    });

    test('0 以下は「0分」', () {
      expect(formatDurationJa(Duration.zero), '0分');
      expect(formatDurationJa(const Duration(minutes: -1)), '0分');
    });
  });

  group('dateHeaderJa', () {
    final now = DateTime(2026, 10, 11, 15, 30);

    test('同じ日は「今日」（時刻が違っても）', () {
      expect(dateHeaderJa(DateTime(2026, 10, 11, 0, 1), now: now), '今日');
      expect(dateHeaderJa(DateTime(2026, 10, 11, 23, 59), now: now), '今日');
    });

    test('前日は「きのう」（深夜をまたいでも）', () {
      expect(dateHeaderJa(DateTime(2026, 10, 10, 23, 59), now: now), 'きのう');
      expect(dateHeaderJa(DateTime(2026, 10, 10, 0, 0), now: now), 'きのう');
    });

    test('2 日以上前は月日と曜日', () {
      expect(dateHeaderJa(DateTime(2026, 10, 9, 12, 0), now: now), '10月9日（金）');
      expect(dateHeaderJa(DateTime(2026, 10, 1), now: now), '10月1日（木）');
    });

    test('年が違うときは年を付ける', () {
      expect(
        dateHeaderJa(DateTime(2025, 12, 31), now: now),
        '2025年12月31日（水）',
      );
    });

    test('未来の日付（時計のずれ）も月日で出す', () {
      expect(dateHeaderJa(DateTime(2026, 10, 12), now: now), '10月12日（月）');
    });

    test('now 省略時は現在時刻を基準にする', () {
      expect(dateHeaderJa(DateTime.now()), '今日');
      expect(
        dateHeaderJa(DateTime.now().subtract(const Duration(days: 1))),
        'きのう',
      );
    });
  });

  group('formatGroupCode / formatOfficialCode', () {
    test('6 桁を 3 桁区切りに', () {
      expect(formatGroupCode(123456), '123 456');
      expect(formatGroupCode(100000), '100 000');
      expect(formatGroupCode(999999), '999 999');
    });

    test('6 桁未満はゼロ埋め', () {
      expect(formatGroupCode(42), '000 042');
    });

    test('8 桁を 4 桁区切りに、8 桁以外はそのまま', () {
      expect(formatOfficialCode('12345678'), '1234 5678');
      expect(formatOfficialCode('1234567'), '1234567');
      expect(formatOfficialCode(''), '');
    });
  });

  test('formatCountJa', () {
    expect(formatCountJa(3, '件'), '3件');
    expect(formatCountJa(0, '台'), '0台');
  });
}
