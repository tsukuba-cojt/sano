/// 実機テスト用のデータ（テスト仕様書の TD1〜TD5、#152）。
///
/// 開発者メニューから入れる。お知らせは見出し、住民からの知らせは本文の先頭に
/// 「【試験】」を付け、受け取った端末でも本物と見分けられるようにする（通知を
/// 出さない・まとめて消せる）。封筒には発信元のノード ID が載らないので、目印は本文に置く。
library;

import 'dart:math';
import 'dart:typed_data';

import '../core/categories.dart';
import '../core/envelope.dart';
import '../core/report.dart';

/// テスト用データの目印（お知らせは見出し、住民からの知らせは本文の先頭）。
const String kTestTitlePrefix = '【試験】';

/// テスト用データか。
bool isTestEnvelope(Envelope e) {
  try {
    final notice = e.notice;
    if (notice != null) {
      return notice.title.startsWith(kTestTitlePrefix);
    }
    final help = e.help;
    if (help != null) {
      return help.text.startsWith(kTestTitlePrefix);
    }
  } on EnvelopeFormatException {
    return false;
  }
  return false;
}

/// テスト用データの発信元（乱数のノード ID）。
Uint8List _origin(Random random) => Uint8List.fromList([
      for (var i = 0; i < 8; i++) random.nextInt(256),
    ]);

/// 本文の作り方。
enum TestBody {
  /// 普段のお知らせに近い文（0〜300 文字、辞書付き圧縮がよく効く）。TD1・TD2。
  plain,

  /// ばらばらの文字（40〜100 文字、圧縮がほとんど効かない）。TD3・TD4。
  noise,
}

const List<String> _places = [
  '〇〇小学校',
  '△△公民館',
  '□□中学校 体育館',
  '中央公園',
  '市役所 本庁舎',
  '北地区 集会所',
  '駅前広場',
  '第二 保育園',
];

const List<String> _sentences = [
  '水は 1人 3リットルまで です。',
  '容器を 持ってきて ください。',
  '毛布と 食料が 届きました。',
  '高齢の方を 優先します。',
  '受付は 入口の 右側です。',
  '道路が 通れません。迂回して ください。',
  'トイレは 体育館の 裏に あります。',
  '午後3時から 配ります。',
  '携帯の 充電が できます。',
  '薬が 必要な方は 申し出て ください。',
];

/// テスト用のお知らせ [count] 件。種別を順に混ぜ、作成時刻は今から 2 時間前までに
/// ばらす。役割は公式とスタッフを交互にする（住民の投稿はグループごとの上限で
/// 古いものから消えるため、量の試験に向かない）。
List<Envelope> makeTestNotices({
  required int count,
  required int groupId,
  required int now,
  required Random random,
  TestBody body = TestBody.plain,
  int startIndex = 1,
}) {
  final categories = NoticeCategory.values;
  final out = <Envelope>[];
  for (var i = 0; i < count; i++) {
    final n = startIndex + i;
    final category = categories[n % categories.length];
    final place = _places[random.nextInt(_places.length)];
    final createdAt = now - random.nextInt(7200);
    final String text;
    switch (body) {
      case TestBody.plain:
        final b = StringBuffer();
        final target = random.nextInt(301);
        while (b.length < target) {
          b.write(_sentences[random.nextInt(_sentences.length)]);
        }
        text = b.length > target ? b.toString().substring(0, target) : '$b';
      case TestBody.noise:
        text = _noise(random, 40 + random.nextInt(61));
    }
    out.add(Envelope.create(
      kind: MessageKind.notice,
      groupId: groupId,
      originId: _origin(random),
      createdAt: createdAt,
      expiresAt: createdAt + const Duration(days: 2).inSeconds,
      category: category,
      role: n.isEven ? SenderRole.official : SenderRole.staff,
      bodyPlain: NoticeBody(
        senderName: '試験',
        title: '$kTestTitlePrefix${category.label} $n',
        place: place,
        text: text,
      ).encode(),
    ));
  }
  return out;
}

/// テスト用の住民からの知らせ [count] 件（TD5 の「無事です 100 件」など）。
/// 1 件ずつ別の発信元にする（同じ人の送り直しの制限にかからない）。
List<Envelope> makeTestReports({
  required int count,
  required int groupId,
  required int now,
  required Random random,
  ReportType type = ReportType.safe,
  SenderRole role = SenderRole.resident,
}) {
  final out = <Envelope>[];
  for (var i = 0; i < count; i++) {
    final createdAt = now - random.nextInt(1800);
    final info = ReportInfo(
      type: type,
      people: 1 + random.nextInt(5),
      needs: type.allowsNeeds
          ? [ReportNeed.values[random.nextInt(ReportNeed.values.length)]]
          : const <ReportNeed>[],
    );
    final name = type.allowsName ? '試験 ${i + 1}' : '';
    out.add(Envelope.create(
      kind: MessageKind.help,
      groupId: groupId,
      originId: _origin(random),
      createdAt: createdAt,
      expiresAt: createdAt + type.ttl.inSeconds,
      category: NoticeCategory.request,
      role: role,
      bodyPlain: NoticeBody(
        senderName: name,
        title: info.title(name: name),
        place: '${_places[random.nextInt(_places.length)]} 付近',
        text: '$kTestTitlePrefix ${i + 1}',
        ext: info.encode(),
      ).encode(),
    ));
  }
  return out;
}

/// ひらがな・カタカナ・漢字をばらばらに並べた [length] 文字。
String _noise(Random random, int length) {
  final codes = <int>[];
  for (var i = 0; i < length; i++) {
    switch (random.nextInt(3)) {
      case 0:
        codes.add(0x3041 + random.nextInt(0x56)); // ひらがな
      case 1:
        codes.add(0x30A1 + random.nextInt(0x5A)); // カタカナ
      default:
        codes.add(0x4E00 + random.nextInt(0x5000)); // 漢字
    }
  }
  return String.fromCharCodes(codes);
}
