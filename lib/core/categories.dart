/// お知らせの種別（カテゴリ）定義。
///
/// コード・ラベル・既定の有効期限は docs/02_protocol.md §2 の表に従う。
/// enum は末尾追加のみ。順序変更・削除は禁止（ワイヤ上のコードが宣言順）。
/// 見出しテンプレートの `{...}` は投稿画面で置き換える穴埋め箇所。
library;

/// 訓練投稿の見出しに付ける接頭辞（封筒の flags は使わない、C23）。
const String kTrainingPrefix = '【訓練】';

/// 見出しが訓練投稿か。
bool isTrainingTitle(String title) => title.startsWith(kTrainingPrefix);

/// 「終わりました」の知らせらしい見出しか（書きなおしと区別して表示する、C01）。
bool looksLikeEndTitle(String title) {
  const suffixes = [
    'は 終わりました',
    'は 閉じました',
    'は 解除されました',
    'は 通れるように なりました',
    'の 配布は 終わりました',
    '終わりました',
  ];
  return suffixes.any(title.endsWith);
}

/// OS 通知の重要度（docs/08 C05）。
enum NoticeImportance {
  /// 「ぜんぶ 知らせる」のときだけ通知する。
  normal,

  /// 「公式と 大事なものだけ」でも通知する（5 秒まとめ）。
  important,

  /// 公式・スタッフの避難情報・注意喚起。まとめずに 1 件ずつ即時。
  urgent,
}

/// 個人情報の注意枠の文言（C11）。
const String kPersonalInfoCaution =
    '本人の 同意が ない 人の 名前・住所・病気・けがは 書かないでください。'
    '送った 内容は 近くの スマホに 残り、あとから 消せません';

/// 避難情報の注意枠の文言（C11）。
const String kEvacuationCaution =
    '避難の 呼びかけは 防災無線や 声でも 伝えてください。'
    'このアプリは 届くまで 時間が かかります';

/// お知らせの種別。宣言順がそのままワイヤ上のコード（0..15）になる。
enum NoticeCategory {
  /// お知らせ（その他全般。平時の行事・ゴミ収集もここ）
  general(
    'お知らせ',
    Duration(days: 3),
    [
      '{場所}からの お知らせです',
      '{日付} {場所}で {行事}が あります',
      '{日付}の {ゴミ}の 収集は {変更}です',
    ],
  ),

  /// 避難情報
  evacuation(
    '避難情報',
    Duration(days: 3),
    ['{場所}に 避難してください'],
    caution: kEvacuationCaution,
    importance: NoticeImportance.urgent,
    endable: false,
  ),

  /// 避難所の開設・閉鎖
  shelter(
    '避難所',
    Duration(days: 7),
    [
      '{場所}が 避難所として 開きました',
      '{場所}が 福祉避難所として 開きました（対象: {高齢の方・障害のある方}）',
    ],
    endTemplate: '{場所}の 避難所は 閉じました',
    importance: NoticeImportance.important,
  ),

  /// 物資の到着・配布
  supply(
    '物資',
    Duration(hours: 12),
    ['{場所}に {物資}が とどきました'],
    endTemplate: '{場所}の 物資の 配布は 終わりました',
    ttlHint: '薬の 在庫や 給油、人数など すぐ 変わる ものは 6時間を 選んでください',
    bodyHint: '1人 2本まで。なくなり次第 終わります。',
    showsEndTime: true,
    importance: NoticeImportance.important,
  ),

  /// 給水
  water(
    '給水',
    Duration(hours: 12),
    ['{場所}で 給水を しています'],
    endTemplate: '{場所}の 給水は 終わりました',
    showsEndTime: true,
    importance: NoticeImportance.important,
  ),

  /// 炊き出し・食事
  food(
    '炊き出し・食事',
    Duration(hours: 12),
    [
      '{場所}で 炊き出しを します',
      '{場所}で {午後5時}から 炊き出しを します',
    ],
    endTemplate: '{場所}の 炊き出しは 終わりました',
    showsEndTime: true,
    importance: NoticeImportance.important,
  ),

  /// 医療・救護
  medical(
    '医療・救護',
    Duration(days: 1),
    [
      '{場所}で 医師の 診察が 受けられます',
      '{場所}で 薬が もらえます（お薬手帳が なくても 可）',
      '{場所}の 外来は 休みです。救急だけ 受け入れます',
    ],
    caution: kPersonalInfoCaution,
    ttlHint: '薬の 在庫や 給油、人数など すぐ 変わる ものは 6時間を 選んでください',
    showsEndTime: true,
    importance: NoticeImportance.important,
  ),

  /// 安否・名簿の案内（個人名は載せない、C11）
  safety(
    '安否・名簿の 案内',
    Duration(days: 3),
    ['{場所}に 避難者名簿が あります。家族を さがす人は 受付へ'],
    caution: kPersonalInfoCaution,
  ),

  /// 交通・道路
  traffic(
    '交通・道路',
    Duration(days: 1),
    [
      '{場所}の 道路は 通行止めです',
      '{路線}の バスは {午前8時・正午・午後4時}に {場所}から 出ます',
      '{路線}は 運休です',
    ],
    endTemplate: '{場所}は 通れるように なりました',
  ),

  /// ライフライン（電気・水道・ガス）
  lifeline(
    'ライフライン',
    Duration(days: 3),
    [
      '{場所}の {電気}が 復旧しました',
      '{場所}の {電気}は {10月13日}までに 復旧する 見込みです',
      '{場所}で スマホ・医療機器の 充電が できます',
    ],
  ),

  /// 注意喚起
  warning(
    '注意喚起',
    Duration(days: 1),
    ['{余震}に 注意してください'],
    endTemplate: '{場所}の 注意喚起は 解除されました',
    endOnlyOfficial: true,
    importance: NoticeImportance.urgent,
  ),

  /// トイレ・入浴・洗濯
  sanitation(
    'トイレ・入浴・洗濯',
    Duration(days: 1),
    [
      '{場所}に トイレが できました',
      '{場所}で {入浴}が できます',
    ],
  ),

  /// 店舗・燃料・銀行
  shops(
    '店舗・燃料・銀行',
    Duration(days: 1),
    [
      '{場所}の {お店}が 開いています',
      '{場所}で {午前9時}から ガソリンを 売ります（1台 {10}リットルまで）',
      '{場所}で 通帳が なくても お金を 下ろせます',
    ],
    endTemplate: '{場所}の 販売は 終わりました',
    ttlHint: '薬の 在庫や 給油、人数など すぐ 変わる ものは 6時間を 選んでください',
  ),

  /// 行政手続き
  admin(
    '行政手続き',
    Duration(days: 7),
    ['{場所}で {手続き}の 受付を しています'],
  ),

  /// 支援要請
  request(
    '支援要請',
    Duration(days: 3),
    ['{場所}で {物資}が 足りません'],
    caution: kPersonalInfoCaution,
    ttlHint: '運ぶ人が 来るまで 時間が かかります。期限は 3日が おすすめです',
  ),

  /// 被害情報
  damage(
    '被害情報',
    Duration(days: 3),
    ['{場所}で 被害が 出ています'],
    caution: kPersonalInfoCaution,
  );

  const NoticeCategory(
    this.label,
    this.defaultTtl,
    this.titleTemplates, {
    this.endTemplate,
    this.endOnlyOfficial = false,
    this.endable = true,
    this.caution,
    this.ttlHint,
    this.bodyHint,
    this.showsEndTime = false,
    this.importance = NoticeImportance.normal,
  });

  /// 画面に表示する日本語ラベル。
  final String label;

  /// 既定の有効期限。
  final Duration defaultTtl;

  /// 見出しの例文（1〜3 文）。先頭が既定。`{場所}` などを投稿画面で置き換える。
  final List<String> titleTemplates;

  /// 見出しの既定テンプレート（例文の先頭）。
  String get titleTemplate => titleTemplates.first;

  /// 「終わりました」の見出し。null なら汎用文「{場所}の お知らせは 終わりました」。
  final String? endTemplate;

  /// [endTemplate] を公式（role=2）のときだけ使う（それ以外は汎用文）。
  final bool endOnlyOfficial;

  /// 「終わりました」ボタンを出すか（避難情報は「書きなおす」で解除を明示する）。
  final bool endable;

  /// 投稿画面で見出し欄の上に出す注意（個人情報・即時性）。null なら出さない。
  final String? caution;

  /// 期限ボタンの下に出す 1 行のヒント。null なら出さない。
  final String? ttlHint;

  /// 本文欄のヒント。null なら既定。
  final String? bodyHint;

  /// 一覧カードに「午後6時まで」を併記するか（C02）。
  final bool showsEndTime;

  /// OS 通知の重要度（C05。役割による格上げは呼び出し側で行う）。
  final NoticeImportance importance;

  /// 「終わりました」の見出しを作る。[place] が空なら「{場所}の 」を省く。
  String endTitle({required String place, required bool official}) {
    var template = endTemplate;
    if (template == null || (endOnlyOfficial && !official)) {
      template = '{場所}の お知らせは 終わりました';
    }
    final trimmed = place.trim();
    if (trimmed.isEmpty) {
      return template.replaceAll('{場所}の ', '').replaceAll('{場所}', '');
    }
    return template.replaceAll('{場所}', trimmed);
  }

  /// ワイヤ上のコード（0..15、宣言順）。
  int get code => index;

  /// コードから種別を得る。範囲外は [general]。
  static NoticeCategory fromCode(int code) {
    if (code < 0 || code >= values.length) {
      return general;
    }
    return values[code];
  }
}
