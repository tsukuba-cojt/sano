/// 日時・番号の表示用整形（やさしい日本語、12 時間制、午前/午後）。
///
/// docs/04_ui_design.md §5 の文言規則に従う。
library;

/// 曜日の日本語 1 文字（[DateTime.weekday] 1=月 … 7=日）。
const List<String> _weekdayJa = ['月', '火', '水', '木', '金', '土', '日'];

/// 「午後3時20分」のように時刻だけを返す。
///
/// 0 時台は「午前0時」、12 時台は「午後0時」とする。分は 2 桁で揃える。
String formatTimeJa(DateTime time) {
  final period = time.hour < 12 ? '午前' : '午後';
  final hour = time.hour % 12;
  final minute = time.minute.toString().padLeft(2, '0');
  return '$period$hour時$minute分';
}

/// 「午後6時」「午後6時10分」のように、0 分なら分を省いた時刻（「〜まで」の併記用）。
String formatEndTimeJa(DateTime time) {
  final period = time.hour < 12 ? '午前' : '午後';
  final hour = time.hour % 12;
  if (time.minute == 0) {
    return '$period$hour時';
  }
  return '$period$hour時${time.minute.toString().padLeft(2, '0')}分';
}

/// 「2026年10月11日 午後3時20分」のように日付と時刻を返す。
String formatDateTimeJa(DateTime time) {
  return '${time.year}年${time.month}月${time.day}日 ${formatTimeJa(time)}';
}

/// 「10月1日 午後3時」のように年なし・分なしの短い日時（状態帯用）。
String formatShortDateTimeJa(DateTime time) {
  return '${time.month}月${time.day}日 ${formatEndTimeJa(time)}';
}

/// 「10月9日（木）」のように日付と曜日を返す（年なし）。
String formatDateJa(DateTime time) {
  return '${time.month}月${time.day}日（${_weekdayJa[time.weekday - 1]}）';
}

/// 「2時間前」のような相対表現。
///
/// 1 分未満（将来の時刻を含む）は「たった今」。
/// 1 時間未満は分、24 時間未満は時間、それ以上は日で表す。
String formatRelativeJa(Duration elapsed) {
  if (elapsed < const Duration(minutes: 1)) {
    return 'たった今';
  }
  if (elapsed < const Duration(hours: 1)) {
    return '${elapsed.inMinutes}分前';
  }
  if (elapsed < const Duration(days: 1)) {
    return '${elapsed.inHours}時間前';
  }
  return '${elapsed.inDays}日前';
}

/// 「12時間」「1日」「30分」のような期間の長さ。
///
/// 日で割り切れれば日、時間で割り切れれば時間、それ以外は分で表す。
String formatDurationJa(Duration duration) {
  if (duration.isNegative || duration == Duration.zero) {
    return '0分';
  }
  if (duration.inDays >= 1 && duration.inHours % 24 == 0) {
    return '${duration.inDays}日';
  }
  if (duration.inHours >= 1 && duration.inMinutes % 60 == 0) {
    return '${duration.inHours}時間';
  }
  return '${duration.inMinutes}分';
}

/// 一覧の日付見出し。「今日」「きのう」、それ以外は「10月9日（木）」。
///
/// 年が [now] と異なるときは「2025年12月31日（水）」のように年を付ける。
/// [now] はテスト用に差し替えられる（省略時は現在時刻）。
String dateHeaderJa(DateTime time, {DateTime? now}) {
  final today = _dateOnly(now ?? DateTime.now());
  final day = _dateOnly(time);
  final diff = today.difference(day).inDays;
  if (diff == 0) {
    return '今日';
  }
  if (diff == 1) {
    return 'きのう';
  }
  if (day.year != today.year) {
    return '${day.year}年${formatDateJa(day)}';
  }
  return formatDateJa(day);
}

/// 「届いた時刻」で並べる一覧の見出し。「今日 届いた」「きのう 届いた」「10月9日（木）に 届いた」。
String receivedHeaderJa(DateTime time, {DateTime? now}) {
  final base = dateHeaderJa(time, now: now);
  if (base == '今日' || base == 'きのう') {
    return '$base 届いた';
  }
  return '$baseに 届いた';
}

/// 「今日 午後5時」「あした 午前9時」のような短い日時（期限の時刻指定用）。
String formatDayTimeJa(DateTime time, {DateTime? now}) {
  final header = dateHeaderJa(time, now: now);
  final day = _dateOnly(time);
  final today = _dateOnly(now ?? DateTime.now());
  final String dayLabel;
  if (header == '今日') {
    dayLabel = '今日';
  } else if (today.add(const Duration(days: 1)) == day) {
    dayLabel = 'あした';
  } else {
    dayLabel = formatDateJa(day);
  }
  return '$dayLabel ${formatEndTimeJa(time)}';
}

DateTime _dateOnly(DateTime time) => DateTime(time.year, time.month, time.day);

/// 6 桁の参加コードを「123 456」のように 3 桁で区切る。
String formatGroupCode(int code) {
  final digits = code.toString().padLeft(6, '0');
  return '${digits.substring(0, 3)} ${digits.substring(3)}';
}

/// 8 桁の本部コード・スタッフコードを「1234 5678」のように 4 桁で区切る。
///
/// 8 桁でない場合はそのまま返す。
String formatOfficialCode(String code) {
  if (code.length != 8) {
    return code;
  }
  return '${code.substring(0, 4)} ${code.substring(4)}';
}

/// 「3件」「12台」のように数と単位をつなぐ（全角・半角の混在を防ぐ）。
String formatCountJa(int count, String unit) => '$count$unit';

/// グループ名が空（まだ近くから届いていない）ときの表示名。
const String kUnknownGroupName = '名前は まだ 届いていません';

String displayGroupName(String name) =>
    name.trim().isEmpty ? kUnknownGroupName : name;
