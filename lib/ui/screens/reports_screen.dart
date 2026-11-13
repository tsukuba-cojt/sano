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
  sending('自動送信待ち'),
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
      case ReportFilter.sending:
        return e.replyPending;
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
    final pending = entries.where((e) => !e.acked && !e.expired).toList();
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
        final handed = recorded.where((e) => e.replyHandedAt != null).length;
        await showMessageDialog(
          context,
          title: '返信を 保存しました',
          message:
              '保存した 返信: ${formatCountJa(recorded.length, '件')}\n'
              '自動送信待ち: ${formatCountJa(waiting, '件')}\n'
              '近くの スマホで 保存を 確認: ${formatCountJa(handed, '件')}\n\n'
              '通信が できるときに 自動で 送ります。'
              '近くでの 保存確認は、本人への 到着や 対応完了を 示すものでは ありません。',
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
        listenable: Listenable.merge([_c, _c.store, _c.groups]),
        builder: (context, _) {
          final showingPending = _filter == ReportFilter.sending;
          final received = _c.receivedReports(
            groupCode: widget.groupCode,
            inReplyTo: widget.inReplyTo,
            includeExpired: _showHistory || showingPending,
          );
          final all = _showHistory
              ? received.where((e) => e.expired).toList()
              : showingPending
              ? received.where((e) => e.replyPending).toList()
              : received;
          final summary = _showHistory || showingPending
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
          final unacked = shown.where((e) => !e.acked && !e.expired).length;
          final sending = all.where((e) => e.replyPending).length;
          final handed = all.where((e) => e.replyHandedAt != null).length;
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
            if (!_showHistory && !showingPending && summary.unackedSos > 0)
              InfoBox(
                'まだ 返事を していない SOS が ${formatCountJa(summary.unackedSos, '件')} あります。'
                '場所を 確かめて、係の 人を 向かわせてください。',
                title: 'SOS',
                kind: InfoKind.danger,
              ),
            if (showingPending)
              InfoBox(
                '返信は 保存済みです。近くの スマホと 交換できるときに、自動で 送ります。'
                '元の 知らせが 期限切れのものも 含みます。今の 安否を 示す一覧では ありません。',
                title: '自動送信待ち ${formatCountJa(sending, '件')}',
              )
            else ...[
              InfoBox(
                '${summary.line()}\nまだ 返事を していない: ${formatCountJa(summary.unacked, '件')}'
                '\nこの一覧の 自動送信待ち: ${formatCountJa(sending, '件')}'
                '\n近くの スマホで 保存を 確認: ${formatCountJa(handed, '件')}',
                title: _showHistory
                    ? '過去の 記録 ${formatCountJa(summary.total, '件')}'
                    : '届いた 知らせ ${formatCountJa(summary.total, '件')}',
              ),
              const Text(
                '同じ 人が 何回か 送ることも あります。人数は 目安です。',
                style: KairanTextStyles.metaSecondary,
              ),
            ],
            SecondaryButton(
              label: _showHistory ? '現在の 知らせを 見る' : '過去の 記録を 見る',
              onPressed: () => setState(() {
                _showHistory = !_showHistory;
                if (showingPending) _filter = ReportFilter.all;
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
                    onPressed: () => setState(() {
                      _filter = f;
                      if (f == ReportFilter.sending) _showHistory = false;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (all.isEmpty)
              InfoBox(
                showingPending
                    ? '自動送信待ちの 返信は ありません。'
                    : _showHistory
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
                        stateLine: _replyState(e, now),
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

  String _replyState(ReportEntry e, DateTime now) {
    final ack = e.ack;
    if (ack == null) {
      return e.expired ? '期限切れの 過去の 記録' : 'まだ 返事を していません';
    }
    final prefix = e.expired ? '過去の 知らせへの 返信・' : '';
    if (e.replyPending) return '$prefix保存済み・自動送信待ち';
    final handedAt = e.replyHandedAt;
    if (handedAt != null) {
      return '$prefix近くの スマホで 保存を 確認'
          '（${formatDayTimeJa(dateTimeFromEpoch(handedAt), now: now)}）';
    }
    if (ack.isLocal && ack.envelope.expiresAt < _c.now) {
      return '$prefix返信の 期限切れ・受け渡し確認なし';
    }
    if (ack.isLocal) return '$prefix返信は 保存済み・受け渡し確認なし';
    return '$prefixほかの 端末から 受け取りの 返信あり';
  }
}
