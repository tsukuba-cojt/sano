/// 住民からの知らせ（SOS・無事です・在宅避難・困っています）のカードと種類タグ。
library;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/report.dart';
import '../format.dart';

/// 知らせの種類タグ。SOS は赤地白文字、無事は緑枠、在宅避難は青枠、困りごとは橙枠。
class ReportTypeTag extends StatelessWidget {
  const ReportTypeTag(this.type, {super.key});

  final ReportType type;

  @override
  Widget build(BuildContext context) {
    final Color background;
    final Color border;
    final Color foreground;
    switch (type) {
      case ReportType.sos:
        background = KairanColors.danger;
        border = KairanColors.danger;
        foreground = KairanColors.card;
      case ReportType.safe:
        background = KairanColors.card;
        border = KairanColors.success;
        foreground = KairanColors.success;
      case ReportType.home:
        background = KairanColors.card;
        border = KairanColors.primary;
        foreground = KairanColors.primary;
      case ReportType.need:
        background = KairanColors.card;
        border = KairanColors.caution;
        foreground = KairanColors.caution;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        border: Border.all(color: border, width: 2),
        borderRadius: const BorderRadius.all(
          Radius.circular(KairanSizes.radius),
        ),
      ),
      child: Text(
        type.shortLabel,
        style: KairanTextStyles.tag.copyWith(color: foreground),
        softWrap: false,
      ),
    );
  }
}

/// 知らせ 1 件のカード（本部の一覧・自分が送った一覧）。全体がタップ領域。
///
/// 1 行目: 種類タグ・「返事」タグ
/// 2 行目: 見出し
/// 3 行目: 場所・ひとこと
/// 4 行目: 届いた（送った）時刻
/// 5 行目: 受け取りの状態（「受け取りました（午後3時10分）」/「まだ 返事を していません」）
class ReportCard extends StatelessWidget {
  const ReportCard({
    super.key,
    required this.type,
    required this.title,
    required this.time,
    required this.now,
    required this.stateLine,
    required this.acked,
    required this.onTap,
    this.place = '',
    this.note = '',
    this.isReply = false,
    this.timeLabel = '届いた',
    this.historical = false,
  });

  final ReportType type;
  final String title;
  final String place;
  final String note;

  /// 届いた（送った）時刻。
  final DateTime time;
  final DateTime now;

  /// 「届いた」「送った」。
  final String timeLabel;

  /// 受け取りの状態の 1 行。
  final String stateLine;
  final bool acked;
  final bool historical;

  /// 安否確認への返事か。
  final bool isReply;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final sosOpen = type == ReportType.sos && !acked && !historical;
    final semantics = StringBuffer()
      ..write('${type.shortLabel}、')
      ..write(isReply ? '安否確認への 返事、' : '')
      ..write('$title、')
      ..write(place.isEmpty ? '' : '場所: $place、')
      ..write(note.isEmpty ? '' : '$note、')
      ..write('$timeLabel ${formatDayTimeJa(time, now: now)}、')
      ..write(stateLine);
    return Semantics(
      button: true,
      label: semantics.toString(),
      onTap: onTap,
      child: ExcludeSemantics(
        child: Material(
          color: KairanColors.card,
          shape: RoundedRectangleBorder(
            borderRadius: const BorderRadius.all(
              Radius.circular(KairanSizes.radius),
            ),
            side: BorderSide(
              color: sosOpen
                  ? KairanColors.danger
                  : KairanColors.borderDecorative,
              width: sosOpen ? 2 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: KairanSizes.cardMinHeight,
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: KairanSizes.gap,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        ReportTypeTag(type),
                        if (isReply)
                          Text(
                            '安否確認への 返事',
                            style: KairanTextStyles.metaSecondary,
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      title,
                      style: KairanTextStyles.noticeTitle,
                      softWrap: true,
                    ),
                    if (place.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        '場所: $place',
                        style: KairanTextStyles.meta,
                        softWrap: true,
                      ),
                    ],
                    if (note.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(note, style: KairanTextStyles.meta, softWrap: true),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      '$timeLabel: ${formatDayTimeJa(time, now: now)}',
                      style: KairanTextStyles.meta,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      stateLine,
                      style: KairanTextStyles.meta.copyWith(
                        color: acked
                            ? KairanColors.success
                            : KairanColors.caution,
                        fontWeight: FontWeight.bold,
                      ),
                      softWrap: true,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
