/// 知らせ 1 件の詳細（本部・スタッフは「受け取りました」を返す、送った本人は状態を見る）。
library;

import 'package:flutter/material.dart';
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

class ReportDetailScreen extends StatefulWidget {
  const ReportDetailScreen({
    super.key,
    required this.controller,
    required this.msgId,
  });

  final AppController controller;
  final int msgId;

  @override
  State<ReportDetailScreen> createState() => _ReportDetailScreenState();
}

class _ReportDetailScreenState extends State<ReportDetailScreen> {
  bool _busy = false;

  AppController get _c => widget.controller;

  Future<void> _run(
    Future<void> Function() action, {
    required String done,
  }) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) {
        showSnack(context, done);
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

  Future<void> _ack() => _run(
    () => _c.acknowledgeReport(widget.msgId),
    done: '受け取りました と 返しました。近くの スマホを 通って 本人に 届きます。',
  );

  Future<void> _retract() async {
    final ok = await showConfirmDialog(
      context,
      title: '知らせを 取り消しますか？',
      message:
          'もう 大丈夫な ときや、まちがえて 送った ときに 使います。'
          '本部の 一覧からも 消えます（届くまでに 時間が かかります）。',
      confirmLabel: '取り消す',
      danger: true,
    );
    if (!ok || !mounted) {
      return;
    }
    await _run(() => _c.retract(widget.msgId), done: '取り消しました。近くの スマホに 広がります。');
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const KairanAppBar(title: '知らせ', showBack: true),
      body: ListenableBuilder(
        listenable: Listenable.merge([_c, _c.store, _c.groups]),
        builder: (context, _) {
          final m = _c.reportMessage(widget.msgId);
          final e = m == null ? null : _c.reportEntryOf(m);
          if (m == null || e == null || m.retracted) {
            return const PageBody(
              children: [InfoBox('この 知らせは 見つかりません。期限が 切れたか、取り消されました。')],
            );
          }
          final now = dateTimeFromEpoch(_c.now);
          final mine = m.isLocal;
          final manager = !mine && _c.canSeeReports(m.groupId);
          if (!mine && !manager) {
            return const PageBody(
              children: [InfoBox('この 知らせは 本部・スタッフの 端末だけで 見られます。')],
            );
          }
          final group = _c.groups.byCode(m.groupId);
          final ack = e.ack;
          final reply = e.info.inReplyTo;
          final request = reply == null ? null : _c.store.get(reply);
          final requestNotice = request?.envelope.notice;
          final time = dateTimeFromEpoch(
            mine ? m.envelope.createdAt : m.receivedAt,
          );
          final expires = dateTimeFromEpoch(_c.store.localExpiresAt(m));

          Widget? bottom;
          if (manager && (ack == null || e.replyPending) && !e.expired) {
            bottom = PrimaryButton(
              label: '受け取りました と 返す',
              icon: Icons.check,
              onPressed: _busy ? null : _ack,
            );
          } else if (mine) {
            bottom = SecondaryButton(
              label: '取り消す（もう 大丈夫です）',
              danger: true,
              onPressed: _busy ? null : _retract,
            );
          }

          return PageBody(
            bottom: bottom,
            children: [
              Row(
                children: [
                  ReportTypeTag(e.info.type),
                  const Spacer(),
                  Text(
                    '番号 ${AppController.bulletinNumber(m.msgId)}',
                    style: KairanTextStyles.metaSecondary,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SelectableText(e.body.title, style: KairanTextStyles.noticeTitle),
              const SizedBox(height: 12),
              if (e.expired)
                const InfoBox(
                  '期限が 切れた 知らせの 記録です。今の 安否では ありません。新しい 知らせを 確かめてください。',
                  title: '過去の 記録',
                  kind: InfoKind.caution,
                )
              else if (e.replyPending)
                const InfoBox(
                  '返信を 広げる 準備が できていません。空き容量を 確かめて、もう一度 返してください。',
                  kind: InfoKind.caution,
                )
              else if (ack != null)
                InfoBox(
                  mine
                      ? '${_c.ackSenderLabel(ack)}が 受け取りました（${formatDayTimeJa(dateTimeFromEpoch(ack.envelope.createdAt), now: now)}）。'
                            '対応の 約束では ありません。急ぐ ときは 近所の 人にも 声を かけてください。'
                      : '受け取りました と 返しました（${formatDayTimeJa(dateTimeFromEpoch(ack.envelope.createdAt), now: now)}）。',
                  kind: InfoKind.success,
                )
              else if (mine)
                const InfoBox(
                  'まだ 受け取りの 返事は ありません。近くの スマホを 通って 届くまで 時間が かかります。',
                  kind: InfoKind.caution,
                )
              else
                InfoBox(
                  e.info.type == ReportType.sos
                      ? '助けを 求めて います。場所を 確かめて 係の 人を 向かわせ、「受け取りました」を 返してください。'
                      : '「受け取りました」を 返すと、送った 人の スマホに 届きます。対応の 約束では ありません。',
                  kind: e.info.type == ReportType.sos
                      ? InfoKind.danger
                      : InfoKind.plain,
                ),
              const SizedBox(height: 12),
              CardBox(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    LabelValueRow('種類', e.info.type.label),
                    if (e.info.people > 0)
                      LabelValueRow('人数', reportPeopleLabel(e.info.people)),
                    if (e.info.injured)
                      const LabelValueRow('けが', 'けがを している 人が いる'),
                    if (e.info.needs.isNotEmpty)
                      LabelValueRow(
                        '困っている こと',
                        e.info.needs.map((n) => n.label).join('\n'),
                      ),
                    if (e.body.senderName.isNotEmpty)
                      LabelValueRow('名前', e.body.senderName, selectable: true),
                    LabelValueRow(
                      '場所',
                      e.body.place.isEmpty ? '（書いて いません）' : e.body.place,
                      selectable: true,
                    ),
                    if (e.body.text.trim().isNotEmpty)
                      LabelValueRow(
                        'ひとこと',
                        e.body.text.trim(),
                        selectable: true,
                      ),
                    if (group != null)
                      LabelValueRow('グループ', displayGroupName(group.name)),
                    LabelValueRow(
                      mine ? '送った 時刻' : '届いた 時刻',
                      formatDateTimeJa(time),
                    ),
                    if (!mine)
                      LabelValueRow('転送', formatCountJa(m.envelope.hop, '回')),
                    LabelValueRow('有効期限', '${formatDateTimeJa(expires)} まで'),
                  ],
                ),
              ),
              if (reply != null) ...[
                const SizedBox(height: 12),
                Text(
                  requestNotice == null
                      ? '安否確認への 返事です。'
                      : '安否確認『${requestNotice.title}』への 返事です。',
                  style: KairanTextStyles.meta,
                ),
                if (requestNotice != null) ...[
                  const SizedBox(height: 4),
                  SecondaryButton(
                    label: '安否確認の お知らせを 見る',
                    onPressed: () => openNoticeDetail(context, _c, reply),
                  ),
                ],
              ],
              const SizedBox(height: 16),
            ],
          );
        },
      ),
    );
  }
}
