/// 本部・スタッフの「住民からの 知らせ」一覧（docs/04 §4.7）。
///
/// 上に集計（SOS・無事・在宅避難・困りごとの件数と人数）、その下に絞り込みと一覧。
/// 安否確認のお知らせから開いたときは、その返事だけを出す。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kairanban/app/app_controller.dart';
import 'package:kairanban/core/epoch.dart';
import 'package:kairanban/core/report.dart';

import '../../app/theme.dart';
import '../format.dart';
import '../routes.dart';
import '../widgets/big_button.dart';
import '../widgets/dialogs.dart';
import '../widgets/kairan_app_bar.dart';
import '../widgets/report_card.dart';
import '../widgets/section.dart';

/// 一覧の絞り込み。
enum ReportFilter {
  all('すべて'),
  unacked('まだ 返事を していない'),
  sos('SOS'),
  safe('無事'),
  home('在宅避難'),
  need('困りごと');

  const ReportFilter(this.label);

  final String label;

  bool matches(ReportEntry e) {
    switch (this) {
      case ReportFilter.all:
        return true;
      case ReportFilter.unacked:
        return !e.acked;
      case ReportFilter.sos:
        return e.info.type == ReportType.sos;
      case ReportFilter.safe:
        return e.info.type == ReportType.safe;
      case ReportFilter.home:
        return e.info.type == ReportType.home;
      case ReportFilter.need:
        return e.info.type == ReportType.need;
    }
  }
}

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({
    super.key,
    required this.controller,
    this.groupCode,
    this.inReplyTo,
  });

  final AppController controller;
  final int? groupCode;

  /// 安否確認お知らせの msg_id（その返事だけを出す）。
  final int? inReplyTo;

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  ReportFilter _filter = ReportFilter.all;
  bool _busy = false;

  AppController get _c => widget.controller;

  Future<void> _copy(List<ReportEntry> entries) async {
    await Clipboard.setData(ClipboardData(text: _c.reportsAsText(entries)));
    if (!mounted) {
      return;
    }
    showSnack(context, '${formatCountJa(entries.length, '件')}を 文章で コピーしました。');
  }

  Future<void> _ackAll(List<ReportEntry> entries) async {
    final pending = entries.where((e) => !e.acked).toList();
    if (pending.isEmpty) {
      return;
    }
    final ok = await showConfirmDialog(
      context,
      title: 'まとめて 返事を しますか？',
      message:
          '表示中の ${formatCountJa(pending.length, '件')}に「受け取りました」を 返します。'
          '送った 人の スマホに 届きます。対応の 約束では ありません。',
      confirmLabel: '返事を する',
    );
    if (!ok || !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      final n = await _c.acknowledgeAll(pending);
      if (mounted) {
        showSnack(
          context,
          '${formatCountJa(n, '件')}に 返事を しました。近くの スマホに 広がります。',
        );
      }
    } catch (e) {
      if (mounted) {
        await showMessageDialog(
          context,
          title: 'できませんでした',
          message: describeError(e),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: KairanAppBar(
        title: widget.inReplyTo != null ? '安否確認への 返事' : '住民からの 知らせ',
        showBack: true,
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([_c.store, _c.groups]),
        builder: (context, _) {
          final all = _c.receivedReports(
            groupCode: widget.groupCode,
            inReplyTo: widget.inReplyTo,
          );
          final summary = AppController.summarize(all);
          final shown = all.where(_filter.matches).toList();
          final now = dateTimeFromEpoch(_c.now);
          final reply = widget.inReplyTo;
          final request = reply == null
              ? null
              : _c.store.get(reply)?.envelope.notice;
          final unacked = shown.where((e) => !e.acked).length;
          return PageBody(
            bottom: all.isEmpty
                ? null
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (unacked > 0) ...[
                        PrimaryButton(
                          label:
                              '表示中の ${formatCountJa(unacked, '件')}に 受け取りましたと 返す',
                          onPressed: _busy ? null : () => _ackAll(shown),
                        ),
                        const SizedBox(height: KairanSizes.gap),
                      ],
                      SecondaryButton(
                        label: '表示中の 知らせを 文章で コピー',
                        icon: Icons.copy,
                        onPressed: shown.isEmpty ? null : () => _copy(shown),
                      ),
                    ],
                  ),
            children: [
              if (request != null) ...[
                InfoBox('『${request.title}』への 返事です。'),
                const SizedBox(height: 8),
              ],
              if (summary.unackedSos > 0) ...[
                InfoBox(
                  'まだ 返事を していない SOS が ${formatCountJa(summary.unackedSos, '件')} あります。'
                  '場所を 確かめて、係の 人を 向かわせてください。',
                  title: 'SOS',
                  kind: InfoKind.danger,
                ),
                const SizedBox(height: 8),
              ],
              InfoBox(
                '${summary.line()}\nまだ 返事を していない: ${formatCountJa(summary.unacked, '件')}',
                title: '届いた 知らせ ${formatCountJa(summary.total, '件')}',
              ),
              const SizedBox(height: 4),
              const Text(
                '同じ 人が 何回か 送ることも あります。人数は 目安です。',
                style: KairanTextStyles.metaSecondary,
              ),
              const SectionTitle('しぼりこむ'),
              ChoiceGrid(
                columns: 3,
                children: [
                  for (final f in ReportFilter.values)
                    ChoiceButton(
                      label: f.label,
                      selected: f == _filter,
                      onPressed: () => setState(() => _filter = f),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              if (all.isEmpty)
                const InfoBox(
                  '住民からの 知らせは まだ 届いて いません。'
                  'グループの「住民からの 知らせを 受け付ける」が オンだと、住民が SOS・無事です・在宅避難・困っています を 送れます。'
                  '安否確認の お知らせに 付けた 返事の ボタンからも 届きます。',
                )
              else if (shown.isEmpty)
                const Text('この 条件の 知らせは ありません。', style: KairanTextStyles.meta),
              for (final e in shown) ...[
                ReportCard(
                  type: e.info.type,
                  title: e.body.title,
                  place: e.body.place,
                  note: e.body.text,
                  time: dateTimeFromEpoch(e.message.receivedAt),
                  now: now,
                  acked: e.acked,
                  isReply: e.info.inReplyTo != null,
                  stateLine: e.ack == null
                      ? 'まだ 返事を していません'
                      : '受け取りました と 返しました（${formatDayTimeJa(dateTimeFromEpoch(e.ack!.envelope.createdAt), now: now)}）',
                  onTap: () => openReportDetail(context, _c, e.msgId),
                ),
                const SizedBox(height: KairanSizes.gap),
              ],
            ],
          );
        },
      ),
    );
  }
}
