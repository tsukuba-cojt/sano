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
        return !e.acked || e.replyPending;
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
  bool _showHistory = false;
  int _completedReplies = 0;
  int _totalReplies = 0;

  AppController get _c => widget.controller;

  Future<void> _copy(List<ReportEntry> entries) async {
    await Clipboard.setData(ClipboardData(text: _c.reportsAsText(entries)));
    if (!mounted) {
      return;
    }
    showSnack(context, '${formatCountJa(entries.length, '件')}を 文章で コピーしました。');
  }

  Future<void> _ackAll(List<ReportEntry> entries) async {
    final pending = entries
        .where((e) => (!e.acked || e.replyPending) && !e.expired)
        .toList();
    if (pending.isEmpty) {
      return;
    }
    final ok = await showConfirmDialog(
      context,
      title: 'まとめて 返事を しますか？',
      message:
          '表示中の ${formatCountJa(pending.length, '件')}に「受け取りました」を 返します。'
          '近くの スマホを 通して 送るため、返信を 記録します。対応の 約束では ありません。',
      confirmLabel: '返事を する',
    );
    if (!ok || !mounted) {
      return;
    }
    setState(() {
      _busy = true;
      _completedReplies = 0;
      _totalReplies = pending.length;
    });
    try {
      await _c.acknowledgeAll(
        pending,
        onProgress: (completed, total) {
          if (!mounted) return;
          setState(() {
            _completedReplies = completed;
            _totalReplies = total;
          });
        },
      );
      if (mounted) {
        final ids = pending.map((e) => e.msgId).toSet();
        final recorded = _c
            .receivedReports(includeExpired: true)
            .where((e) => ids.contains(e.msgId) && e.acked)
            .toList();
        final waiting = recorded.where((e) => e.replyPending).length;
        final ready = recorded.length - waiting;
        if (waiting > 0) {
          await showMessageDialog(
            context,
            title: '返信を 記録しました',
            message:
                '返信の 記録: ${formatCountJa(recorded.length, '件')}\n'
                '近くへ 広げる 準備が できた返信: ${formatCountJa(ready, '件')}\n'
                '準備待ちの 返信: ${formatCountJa(waiting, '件')}\n\n'
                '相手への 到着を 確認した 件数では ありません。'
                '準備待ちは「まだ 返事を していない」から もう一度 試せます。',
          );
        } else {
          showSnack(
            context,
            '${formatCountJa(recorded.length, '件')}の 返信を 保存しました。'
            '近くの スマホと 交換すると 広がります。',
          );
        }
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
        listenable: Listenable.merge([_c, _c.store, _c.groups]),
        builder: (context, _) {
          final received = _c.receivedReports(
            groupCode: widget.groupCode,
            inReplyTo: widget.inReplyTo,
            includeExpired: _showHistory,
          );
          final all = _showHistory
              ? received.where((e) => e.expired).toList()
              : received;
          final summary = _showHistory
              ? AppController.summarize(all)
              : _c.receivedReportSummary(
                  groupCode: widget.groupCode,
                  inReplyTo: widget.inReplyTo,
                );
          final shown = all.where(_filter.matches).toList();
          final now = dateTimeFromEpoch(_c.now);
          final request = widget.inReplyTo == null
              ? null
              : _c.store.get(widget.inReplyTo!)?.envelope.notice;
          final unacked = shown
              .where((e) => (!e.acked || e.replyPending) && !e.expired)
              .length;
          final header = <Widget>[
            if (_c.storageError != null)
              InfoBox(
                _c.storageError!,
                title: '保存できていない 情報があります',
                kind: InfoKind.danger,
              ),
            if (request != null) InfoBox('『${request.title}』への 返事です。'),
            if (_showHistory)
              const InfoBox(
                '期限が 切れた 知らせの 記録です。今の 安否では ありません。届いてから 30日間 残ります。',
                title: '過去の 記録',
                kind: InfoKind.caution,
              ),
            if (!_showHistory && summary.unackedSos > 0)
              InfoBox(
                'まだ 返事を していない SOS が ${formatCountJa(summary.unackedSos, '件')} あります。'
                '場所を 確かめて、係の 人を 向かわせてください。',
                title: 'SOS',
                kind: InfoKind.danger,
              ),
            InfoBox(
              '${summary.line()}\nまだ 返事を していない: ${formatCountJa(summary.unacked, '件')}',
              title: _showHistory
                  ? '過去の 記録 ${formatCountJa(summary.total, '件')}'
                  : '届いた 知らせ ${formatCountJa(summary.total, '件')}',
            ),
            const Text(
              '同じ 人が 何回か 送ることも あります。人数は 目安です。',
              style: KairanTextStyles.metaSecondary,
            ),
            SecondaryButton(
              label: _showHistory ? '現在の 知らせを 見る' : '過去の 記録を 見る',
              onPressed: () => setState(() {
                _showHistory = !_showHistory;
              }),
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
              InfoBox(
                _showHistory
                    ? '過去の 記録は ありません。'
                    : '住民からの 知らせは まだ 届いて いません。'
                          'グループの「住民からの 知らせを 受け付ける」が オンだと、住民が SOS・無事です・在宅避難・困っています を 送れます。'
                          '安否確認の お知らせに 付けた 返事の ボタンからも 届きます。',
              )
            else if (shown.isEmpty)
              const Text('この 条件の 知らせは ありません。', style: KairanTextStyles.meta),
          ];
          return Column(
            children: [
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(KairanSizes.pagePadding),
                  itemCount: header.length + shown.length,
                  itemBuilder: (context, index) {
                    if (index < header.length) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: header[index],
                      );
                    }
                    final e = shown[index - header.length];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: KairanSizes.gap),
                      child: ReportCard(
                        type: e.info.type,
                        title: e.body.title,
                        place: e.body.place,
                        note: e.body.text,
                        time: dateTimeFromEpoch(e.message.receivedAt),
                        now: now,
                        acked: e.acked,
                        historical: e.expired,
                        isReply: e.info.inReplyTo != null,
                        stateLine: e.replyPending
                            ? '返信を 広げる 準備が できていません。もう一度 返してください'
                            : e.expired
                            ? '期限切れの 過去の 記録'
                            : e.ack == null
                            ? 'まだ 返事を していません'
                            : '受け取りました と 返しました（${formatDayTimeJa(dateTimeFromEpoch(e.ack!.envelope.createdAt), now: now)}）',
                        onTap: () => openReportDetail(context, _c, e.msgId),
                      ),
                    );
                  },
                ),
              ),
              if (all.isNotEmpty)
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.all(KairanSizes.pagePadding),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_busy) ...[
                          Text(
                            '返信を 記録しています '
                            '$_completedReplies / ${formatCountJa(_totalReplies, '件')}',
                            style: KairanTextStyles.meta,
                          ),
                          const SizedBox(height: 8),
                          LinearProgressIndicator(
                            value: _totalReplies == 0
                                ? 0
                                : _completedReplies / _totalReplies,
                          ),
                          const SizedBox(height: KairanSizes.gap),
                        ],
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
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
