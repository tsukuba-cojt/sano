/// 2026 エポック変換。
///
/// 封筒の created_at / expires_at は 2026-01-01T00:00:00Z を起点とした
/// uint32 秒で表す（docs/02_protocol.md §1）。
library;

/// エポックの起点（2026-01-01T00:00:00Z）を Unix 秒で表した値。
const int kEpochUnixSeconds = 1767225600;

/// uint32 で表せるエポック秒の最大値。
const int kMaxEpochSeconds = 0xFFFFFFFF;

/// [time]（UTC / ローカルどちらでも可）をエポック秒に変換する。
///
/// 端末の時計がエポックより前を指している場合は 0、uint32 の上限を
/// 超える場合は [kMaxEpochSeconds] に丸める（封筒に収まる範囲に保つ）。
int epochSecondsFrom(DateTime time) {
  final unixSeconds =
      time.toUtc().millisecondsSinceEpoch ~/ Duration.millisecondsPerSecond;
  final seconds = unixSeconds - kEpochUnixSeconds;
  if (seconds < 0) {
    return 0;
  }
  if (seconds > kMaxEpochSeconds) {
    return kMaxEpochSeconds;
  }
  return seconds;
}

/// エポック秒をローカル時刻の [DateTime] に変換する。
DateTime dateTimeFromEpoch(int epochSeconds) {
  return DateTime.fromMillisecondsSinceEpoch(
    (kEpochUnixSeconds + epochSeconds) * Duration.millisecondsPerSecond,
  );
}

/// 現在時刻のエポック秒。
int nowEpochSeconds() => epochSecondsFrom(DateTime.now());
