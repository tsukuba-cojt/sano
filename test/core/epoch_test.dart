import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/core/epoch.dart';

void main() {
  group('epoch', () {
    test('エポックは 2026-01-01T00:00:00Z', () {
      expect(kEpochUnixSeconds, 1767225600);
      expect(
        DateTime.fromMillisecondsSinceEpoch(kEpochUnixSeconds * 1000,
            isUtc: true),
        DateTime.utc(2026, 1, 1),
      );
    });

    test('エポック時刻は 0 になる', () {
      expect(epochSecondsFrom(DateTime.utc(2026, 1, 1)), 0);
      expect(epochSecondsFrom(DateTime.utc(2026, 1, 1, 0, 0, 1)), 1);
      expect(epochSecondsFrom(DateTime.utc(2026, 1, 2)), 86400);
    });

    test('UTC とローカルの同じ瞬間は同じ値になる', () {
      final utc = DateTime.utc(2026, 10, 11, 6, 20, 30);
      final local = utc.toLocal();
      expect(local.isUtc, isFalse);
      expect(epochSecondsFrom(local), epochSecondsFrom(utc));
    });

    test('ミリ秒は切り捨てる', () {
      expect(
        epochSecondsFrom(DateTime.utc(2026, 1, 1, 0, 0, 5, 999)),
        5,
      );
    });

    test('エポックより前の時刻は 0 に丸める（端末時計を信用しない）', () {
      expect(epochSecondsFrom(DateTime.utc(2020, 1, 1)), 0);
      expect(epochSecondsFrom(DateTime.utc(2025, 12, 31, 23, 59, 59)), 0);
    });

    test('uint32 の上限で丸める', () {
      expect(epochSecondsFrom(DateTime.utc(2200, 1, 1)), kMaxEpochSeconds);
    });

    test('dateTimeFromEpoch はローカル時刻を返し往復できる', () {
      const seconds = 24 * 3600 * 283 + 15 * 3600 + 20 * 60;
      final dt = dateTimeFromEpoch(seconds);
      expect(dt.isUtc, isFalse);
      expect(dt.toUtc(), DateTime.utc(2026, 10, 11, 15, 20));
      expect(epochSecondsFrom(dt), seconds);
      expect(dateTimeFromEpoch(0).toUtc(), DateTime.utc(2026, 1, 1));
    });

    test('nowEpochSeconds は現在時刻に対応する', () {
      final before = epochSecondsFrom(DateTime.now());
      final now = nowEpochSeconds();
      final after = epochSecondsFrom(DateTime.now());
      expect(now, greaterThanOrEqualTo(before));
      expect(now, lessThanOrEqualTo(after));
    });
  });
}
