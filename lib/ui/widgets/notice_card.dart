/// お知らせ一覧のカード。全体がタップ領域、高さ 72 以上。
library;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/categories.dart';
import '../../core/envelope.dart';
import '../format.dart';
import 'tags.dart';

/// お知らせカード。
///
/// 上辺: 公式の避難情報・注意喚起なら赤帯（C03）。
/// 1 行目: 訓練タグ・種別タグ・役割バッジ・新着タグ・書きなおし／終わりました
/// 2 行目: 見出し 22 Bold（折り返し、省略しない）
/// 3 行目: 本文 1 行目（30 文字まで、C03）
/// 4 行目: 場所
/// 5 行目: 出された日時（給水などは「午後6時まで」を併記、C02）・ 発信元
/// 取り消し済みは灰色＋「取り消されました」帯。
class NoticeCard extends StatelessWidget {
  const NoticeCard({
    super.key,
    required this.category,
    required this.role,
    required this.title,
    required this.createdAt,
    required this.senderName,
    this.place = '',
    this.textPreview = '',
    this.isNew = false,
    this.retracted = false,
    this.retractedByOfficial = false,
    this.superseded = false,
    this.isLocal = false,
    this.rewrite = false,
    this.ended = false,
    this.training = false,
    this.alert = false,
    this.endsAt,
    this.endingSoon = false,
    this.clockSuspicious = false,
    required this.onTap,
  });

  final NoticeCategory category;
  final SenderRole role;
  final String title;
  final DateTime createdAt;
  final String senderName;
  final String place;

  /// 本文の 1 行目（空なら出さない）。
  final String textPreview;
  final bool isNew;
  final bool retracted;

  /// 公式により取り消された（住民・スタッフの投稿）。
  final bool retractedByOfficial;

  /// 訂正で置き換えられた古い版。
  final bool superseded;

  /// 自分の端末から出したお知らせ。
  final bool isLocal;

  /// 書きなおし（前のお知らせを置き換えた新版）。
  final bool rewrite;

  /// 「終わりました」の知らせ。
  final bool ended;

  /// 訓練投稿。
  final bool training;

  /// 公式の避難情報・注意喚起（上辺に赤帯）。
  final bool alert;

  /// 「午後6時まで」と併記する期限（給水・炊き出し・物資・医療だけ）。
  final DateTime? endsAt;

  /// 期限まで 1 時間以内。
  final bool endingSoon;

  /// 発信側の時計がずれているかもしれない（時刻を灰色にして注記）。
  final bool clockSuspicious;
  final VoidCallback onTap;

  bool get _inactive => retracted || superseded;

  @override
  Widget build(BuildContext context) {
    final textColor = _inactive ? KairanColors.textSecondary : KairanColors.text;
    final ends = endsAt;
    final timeLine = ends == null
        ? formatDateTimeJa(createdAt)
        : '${formatDateTimeJa(createdAt)} ・ ${formatEndTimeJa(ends)}まで';
    final alertLabel =
        category == NoticeCategory.evacuation ? '避難' : '注意';
    final retractedLabel =
        retractedByOfficial ? '公式により 取り消されました' : '取り消されました';
    final semanticsLabel = StringBuffer()
      ..write(alert ? '$alertLabel、' : '')
      ..write(training ? '訓練、' : '')
      ..write('${category.label}、${role.label}、')
      ..write(isNew ? '新着、' : '')
      ..write(ended ? '終わりました、' : (rewrite ? '書きなおし、' : ''))
      ..write(retracted ? '$retractedLabel、' : '')
      ..write(superseded ? '新しい内容に 置き換えられました、' : '')
      ..write('$title、')
      ..write(textPreview.isEmpty ? '' : '$textPreview、')
      ..write(place.isEmpty ? '' : '場所: $place、')
      ..write('$timeLine、$senderName');

    return Semantics(
      button: true,
      label: semanticsLabel.toString(),
      // 内側の InkWell の意味情報は除外するので、タップ操作をここに付ける。
      onTap: onTap,
      child: ExcludeSemantics(
        child: Material(
          color: _inactive ? KairanColors.pageBackground : KairanColors.card,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(
              Radius.circular(KairanSizes.radius),
            ),
            side: BorderSide(color: KairanColors.borderDecorative),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: KairanSizes.cardMinHeight,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (alert && !_inactive) AlertBand(alertLabel),
                  if (retracted) _Band(retractedLabel),
                  if (superseded && !retracted)
                    const _Band('新しい内容に 置き換えられました'),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: KairanSizes.gap,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (training) const TrainingTag(),
                            CategoryTag(category.label),
                            RoleBadge(role),
                            if (isNew && !_inactive) const NewTag(),
                            if (ended)
                              const StateTag('終わりました')
                            else if (rewrite)
                              const StateTag('書きなおし'),
                            if (endingSoon && !_inactive && !ended)
                              const CautionTag('まもなく 終わります'),
                            if (isLocal) const StateTag('自分の 投稿'),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          title,
                          style: KairanTextStyles.noticeTitle.copyWith(
                            color: textColor,
                          ),
                          softWrap: true,
                        ),
                        if (textPreview.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            textPreview,
                            style: KairanTextStyles.meta.copyWith(
                              color: textColor,
                            ),
                            softWrap: true,
                          ),
                        ],
                        if (place.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            '場所: $place',
                            style: KairanTextStyles.meta.copyWith(
                              color: textColor,
                            ),
                            softWrap: true,
                          ),
                        ],
                        const SizedBox(height: 4),
                        Text(
                          timeLine,
                          style: KairanTextStyles.meta.copyWith(
                            color: clockSuspicious
                                ? KairanColors.textSecondary
                                : textColor,
                          ),
                          softWrap: true,
                        ),
                        if (clockSuspicious)
                          const Text(
                            '（出した スマホの 時計が ずれている かもしれません）',
                            style: KairanTextStyles.metaSecondary,
                            softWrap: true,
                          ),
                        const SizedBox(height: 2),
                        Text(
                          senderName,
                          style: KairanTextStyles.metaSecondary,
                          softWrap: true,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// カード上部の灰色の帯。
class _Band extends StatelessWidget {
  const _Band(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: KairanColors.band,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(
        label,
        style: KairanTextStyles.tag.copyWith(color: KairanColors.textSecondary),
      ),
    );
  }
}
