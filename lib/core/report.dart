/// 住民から本部への「知らせ」（SOS・無事です・在宅避難・困っています）の定義。
///
/// 封筒は kind=help（docs/02 §2、docs/08 C21 の拡張）。body は notice と同じ
/// 4 フィールドに、5 番目の拡張（ext）として種類・人数・困りごと・返事先を載せる:
///
/// ```text
/// type u8 ‖ people u8 ‖ needs u8 ‖ flags u8 ‖ in_reply_to i64 LE（省略可）
/// ```
///
/// - type: 0 = SOS、1 = 無事です、2 = 在宅避難、3 = 困っています（未知は「困っています」扱い）
/// - people: 人数（0 = 書いていない、5 = 5人以上）
/// - needs: 困りごとのビット（[ReportNeed]）
/// - flags: bit0 = けがを している 人が いる
/// - in_reply_to: 返事先の「安否確認」お知らせの msg_id（0 / 省略 = なし）
///
/// ext が 4 バイト未満なら種類不明（見出しだけ表示）、12 バイト以上なら返事先あり。
/// 余りは将来の拡張として無視する。
///
/// notice の ext は `flags u8`（bit0 = 返事を 求める「安否確認」）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'categories.dart';

/// 知らせの種類。[code] がワイヤ上の値。
enum ReportType {
  /// 助けて（SOS）。本部端末には urgent で通知する。
  sos(
    0,
    label: '助けて（SOS）',
    shortLabel: 'SOS',
    titlePrefix: '【SOS】',
    description: 'けが・閉じこめ・急病など、すぐに 助けが 必要',
    ttl: Duration(days: 1),
    resendInterval: Duration(minutes: 10),
    importance: NoticeImportance.urgent,
  ),

  /// 無事です（安否）。
  safe(
    1,
    label: '無事です',
    shortLabel: '無事',
    titlePrefix: '【無事】',
    description: '自分や 家族が 無事な ことを 知らせる',
    ttl: Duration(days: 3),
    resendInterval: Duration(minutes: 30),
    allowsName: true,
    allowsInjured: true,
  ),

  /// 家に います（在宅避難）。
  home(
    2,
    label: '家に います（在宅避難）',
    shortLabel: '在宅避難',
    titlePrefix: '【在宅避難】',
    description: '避難所には 行かず 家で 過ごして いる',
    ttl: Duration(days: 3),
    resendInterval: Duration(minutes: 30),
    allowsName: true,
    allowsInjured: true,
    allowsNeeds: true,
  ),

  /// 困っています（物・薬・トイレなど、C21）。
  need(
    3,
    label: '困っています',
    shortLabel: '困りごと',
    titlePrefix: '【困りごと】',
    description: '水・食べ物・薬・トイレ・電気などが 足りない',
    ttl: Duration(days: 2),
    resendInterval: Duration(minutes: 30),
    allowsNeeds: true,
    requiresNeeds: true,
  );

  const ReportType(
    this.code, {
    required this.label,
    required this.shortLabel,
    required this.titlePrefix,
    required this.description,
    required this.ttl,
    required this.resendInterval,
    this.importance = NoticeImportance.important,
    this.allowsName = false,
    this.allowsInjured = false,
    this.allowsNeeds = false,
    this.requiresNeeds = false,
  });

  /// ワイヤ上のコード。
  final int code;

  /// ボタンの文言。
  final String label;

  /// タグ・集計の短い名前。
  final String shortLabel;

  /// 見出しの先頭。
  final String titlePrefix;

  /// ボタンの下の説明。
  final String description;

  /// 有効期間（届くまでの時間と、古い知らせが残り続けないことの釣り合い）。
  final Duration ttl;

  /// 同じグループに同じ種類を送り直せるまでの間隔（C21: 30 分）。
  final Duration resendInterval;

  /// 本部端末での通知の重要度。
  final NoticeImportance importance;

  /// 名前を書けるか（安否を名簿と照らし合わせるため。SOS・困りごとは名前なし、C21）。
  final bool allowsName;

  /// 「けがを している 人が いる」を付けられるか。
  final bool allowsInjured;

  /// 困りごとを選べるか。
  final bool allowsNeeds;

  /// 困りごとを 1 つ以上選ぶ必要があるか。
  final bool requiresNeeds;

  /// コードから種類を得る。未知なら null。
  static ReportType? fromCode(int code) {
    for (final t in values) {
      if (t.code == code) {
        return t;
      }
    }
    return null;
  }
}

/// 困りごと（6 択、C21）。宣言順がビット位置。
enum ReportNeed {
  water('水・食べ物が ない'),
  medical('薬・医療が 必要'),
  mobility('動けない・助けが 必要'),
  toilet('トイレが 使えない'),
  power('電気・ガスが 止まっている'),
  other('その他');

  const ReportNeed(this.label);

  /// ボタンと見出しの文言。
  final String label;

  /// ビット。
  int get bit => 1 << index;

  /// ビット列から選ばれたものを宣言順に返す（未知のビットは無視）。
  static List<ReportNeed> fromBits(int bits) => [
    for (final n in values)
      if ((bits & n.bit) != 0) n,
  ];

  /// 選ばれたものをビット列にする。
  static int toBits(Iterable<ReportNeed> needs) {
    var bits = 0;
    for (final n in needs) {
      bits |= n.bit;
    }
    return bits;
  }
}

/// 人数の選択肢（5 は「5人以上」）。
const List<int> kReportPeopleChoices = [1, 2, 3, 4, 5];

/// 「N人以上」として扱う人数。
const int kReportPeopleMax = 5;

/// 人数の表示（「3人」「5人以上」、0 は空）。
String reportPeopleLabel(int people) {
  if (people <= 0) {
    return '';
  }
  if (people >= kReportPeopleMax) {
    return '$kReportPeopleMax人以上';
  }
  return '$people人';
}

/// help body の拡張の長さ（返事先なし / あり）。
const int kReportExtBaseLength = 4;
const int kReportExtLength = kReportExtBaseLength + 8;

/// ext flags bit0: けがを している 人が いる。
const int kReportFlagInjured = 0x01;

/// notice ext flags bit0: 返事を 求める（安否確認）。
const int kNoticeExtAsksReply = 0x01;

/// 知らせ（kind=help）の拡張の中身。
class ReportInfo {
  const ReportInfo({
    required this.type,
    this.people = 0,
    this.needs = const <ReportNeed>[],
    this.injured = false,
    this.inReplyTo,
  });

  final ReportType type;

  /// 人数（0 = 書いていない、5 = 5人以上）。
  final int people;
  final List<ReportNeed> needs;
  final bool injured;

  /// 返事先の「安否確認」お知らせの msg_id。
  final int? inReplyTo;

  /// ext のバイト列にする。
  Uint8List encode() {
    final reply = inReplyTo;
    final out = Uint8List(
      reply == null ? kReportExtBaseLength : kReportExtLength,
    );
    out[0] = type.code;
    out[1] = people.clamp(0, 255);
    out[2] = ReportNeed.toBits(needs) & 0xFF;
    out[3] = injured ? kReportFlagInjured : 0;
    if (reply != null) {
      ByteData.sublistView(
        out,
      ).setInt64(kReportExtBaseLength, reply, Endian.little);
    }
    return out;
  }

  /// ext を読む。短すぎれば null。未知の種類は「困っています」として読む。
  static ReportInfo? decode(Uint8List? ext) {
    if (ext == null || ext.length < kReportExtBaseLength) {
      return null;
    }
    int? reply;
    if (ext.length >= kReportExtLength) {
      final v = ByteData.sublistView(
        ext,
      ).getInt64(kReportExtBaseLength, Endian.little);
      reply = v == 0 ? null : v;
    }
    return ReportInfo(
      type: ReportType.fromCode(ext[0]) ?? ReportType.need,
      people: ext[1],
      needs: ReportNeed.fromBits(ext[2]),
      injured: (ext[3] & kReportFlagInjured) != 0,
      inReplyTo: reply,
    );
  }

  /// 自動で作る見出し（≤ 120 バイト）。例「【在宅避難】3人 ・ 水・食べ物が ない ほか」。
  String title({String name = ''}) {
    final parts = <String>[];
    final who = name.trim();
    switch (type) {
      case ReportType.sos:
        parts.add('助けが 必要です');
      case ReportType.safe:
        parts.add(who.isEmpty ? '無事です' : '$who さんは 無事です');
      case ReportType.home:
        parts.add(who.isEmpty ? '家に います' : '$who さんは 家に います');
      case ReportType.need:
        if (needs.isEmpty) {
          parts.add('困っています');
        } else {
          parts.add(needs.map((n) => n.label).join('、'));
        }
    }
    final count = reportPeopleLabel(people);
    if (count.isNotEmpty) {
      parts.add('（$count）');
    }
    if (injured) {
      parts.add(' けが人 あり');
    }
    if (type == ReportType.home && needs.isNotEmpty) {
      parts.add(' ・ ${needs.first.label}${needs.length > 1 ? ' ほか' : ''}');
    }
    return truncateUtf8('${type.titlePrefix}${parts.join()}', 120);
  }

  @override
  String toString() =>
      'ReportInfo(type: ${type.name}, people: $people, needs: $needs, '
      'injured: $injured, inReplyTo: $inReplyTo)';
}

/// notice の ext に載せる「返事を 求める」印。
Uint8List noticeExtAskingReply() => Uint8List.fromList([kNoticeExtAsksReply]);

/// notice の ext が「返事を 求める」（安否確認）か。
bool noticeAsksReply(Uint8List? ext) =>
    ext != null && ext.isNotEmpty && (ext[0] & kNoticeExtAsksReply) != 0;

/// 知らせの集計（本部の一覧の上に出す）。
class ReportSummary {
  ReportSummary._(this.counts, this.people, this.unacked, this.unackedSos);

  /// 種類ごとの件数。
  final Map<ReportType, int> counts;

  /// 種類ごとの人数の合計（人数を書いていないものは 1 人と数える。5人以上は 5）。
  final Map<ReportType, int> people;

  /// まだ「受け取りました」を返していない件数。
  final int unacked;

  /// そのうち SOS の件数。
  final int unackedSos;

  int get total => counts.values.fold(0, (a, b) => a + b);

  /// [items]（種類・人数と、受け取りの返事を済ませたか）から集計する。
  static ReportSummary of(Iterable<({ReportInfo info, bool acked})> items) {
    final counts = <ReportType, int>{};
    final people = <ReportType, int>{};
    var unacked = 0;
    var unackedSos = 0;
    for (final item in items) {
      final t = item.info.type;
      counts[t] = (counts[t] ?? 0) + 1;
      people[t] =
          (people[t] ?? 0) + (item.info.people <= 0 ? 1 : item.info.people);
      if (!item.acked) {
        unacked++;
        if (t == ReportType.sos) {
          unackedSos++;
        }
      }
    }
    return ReportSummary._(counts, people, unacked, unackedSos);
  }

  /// 1 行の要約（例「SOS 1件 ・ 無事 12件（20人） ・ 在宅避難 5件（11人）」）。
  String line() {
    if (total == 0) {
      return 'まだ 届いて いません';
    }
    final parts = <String>[];
    for (final t in ReportType.values) {
      final n = counts[t] ?? 0;
      if (n == 0) {
        continue;
      }
      if (t == ReportType.safe || t == ReportType.home) {
        parts.add('${t.shortLabel} $n件（${people[t]}人）');
      } else {
        parts.add('${t.shortLabel} $n件');
      }
    }
    return parts.join(' ・ ');
  }
}

/// UTF-8 で [maxBytes] 以内に収まるよう末尾を切り詰める（文字の途中では切らない）。
String truncateUtf8(String s, int maxBytes) {
  if (utf8.encode(s).length <= maxBytes) {
    return s;
  }
  final out = StringBuffer();
  var bytes = 0;
  for (final rune in s.runes) {
    final n = utf8.encode(String.fromCharCode(rune)).length;
    if (bytes + n > maxBytes) {
      break;
    }
    out.writeCharCode(rune);
    bytes += n;
  }
  return out.toString();
}
