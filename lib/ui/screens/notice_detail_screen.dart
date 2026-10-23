/// お知らせ詳細（docs/08 C01 C10 C19 C20）。
library;

import 'package:flutter/material.dart';
import 'package:kairanban/app/app_controller.dart';
import 'package:kairanban/core/categories.dart';
import 'package:kairanban/core/envelope.dart';
import 'package:kairanban/core/epoch.dart';
import 'package:kairanban/core/report.dart';
import 'package:kairanban/mesh/message_store.dart';

import '../../app/theme.dart';
import '../format.dart';
import '../routes.dart';
import '../widgets/big_button.dart';
import '../widgets/dialogs.dart';
import '../widgets/kairan_app_bar.dart';
import '../widgets/section.dart';
import '../widgets/tags.dart';
import 'compose_screen.dart';

class NoticeDetailScreen extends StatefulWidget {
  const NoticeDetailScreen({
    super.key,
    required this.controller,
    required this.msgId,
  });

  final AppController controller;
  final int msgId;

  @override
  State<NoticeDetailScreen> createState() => _NoticeDetailScreenState();
}

class _NoticeDetailScreenState extends State<NoticeDetailScreen> {
  bool _busy = false;
  bool _speaking = false;

  AppController get _c => widget.controller;
  int get _msgId => widget.msgId;

  @override
  void dispose() {
    if (_speaking) {
      _c.stopSpeaking();
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action, {String? done}) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) {
        return;
      }
      if (done != null) {
        showSnack(context, done);
      }
    } catch (e) {
      if (!mounted) {
        return;
      }
      await showMessageDialog(
        context,
        title: 'できませんでした',
        message: describeError(e),
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _retract(StoredMessage m, NoticeBody notice) async {
    final group = _c.groups.byCode(m.groupId);
    final official = !m.isLocal && (group?.postsAsOfficial ?? false);
    final ok = await showConfirmDialog(
      context,
      title: official ? '公式として 取り消しますか？' : 'お知らせを 取り消しますか？',
      message: official
          ? '『${notice.title}』（${notice.senderName}）を ${group == null ? '公式' : _c.senderNameFor(group)} として 取り消します。近くの スマホにも 広がります。'
          : '終わった お知らせは「終わりました」を 使ってください。取り消すと 本文が 近くの スマホからも 消えます（届くまでに 時間が かかります）。',
      confirmLabel: '取り消す',
      danger: true,
    );
    if (!ok || !mounted) {
      return;
    }
    await _run(() => _c.retract(_msgId), done: '取り消しました。近くの スマホに 広がります。');
  }

  Future<void> _end(StoredMessage m, NoticeBody notice) async {
    final endTitle = m.envelope.category.endTitle(
      place: notice.place,
      official: m.envelope.role == SenderRole.official,
    );
    final ok = await showConfirmDialog(
      context,
      title: '終わりましたと 知らせますか？',
      message: '『$endTitle』と 知らせます。前の お知らせは 消えて、この 内容に 置き換わります。',
      confirmLabel: '知らせる',
    );
    if (!ok || !mounted) {
      return;
    }
    await _run(() => _c.endNotice(_msgId), done: '訂正しました。近くの スマホに 広がります。');
  }

  Future<void> _rewrite() async {
    await openComposeScreen(context, _c, rewriteOf: _msgId);
  }

  Future<void> _retractAndRewrite(StoredMessage m, NoticeBody notice) async {
    final group = _c.groups.byCode(m.groupId);
    final ok = await showConfirmDialog(
      context,
      title: '取り消して 新しく 書きますか？',
      message: '『${notice.title}』（${notice.senderName}）を ${group == null ? '公式' : _c.senderNameFor(group)} として 取り消し、新しい お知らせを 書きます。',
      confirmLabel: '取り消して 書く',
      danger: true,
    );
    if (!ok || !mounted) {
      return;
    }
    await _run(() => _c.retract(_msgId));
    if (!mounted) {
      return;
    }
    await openComposeScreen(
      context,
      _c,
      prefill: ComposePrefill(
        groupCode: m.groupId,
        category: m.envelope.category,
        place: notice.place,
        text: '${notice.senderName}さんの お知らせを 取り消しました。\n',
        bannerText: '元の 投稿: ${notice.senderName}',
      ),
    );
  }

  Future<void> _toggleSpeak(StoredMessage m, NoticeBody notice) async {
    if (_speaking) {
      setState(() => _speaking = false);
      await _c.stopSpeaking();
      return;
    }
    final env = m.envelope;
    final created = dateTimeFromEpoch(env.createdAt);
    final parts = <String>[
      env.category.label,
      env.role.label,
      notice.title,
      if (notice.place.isNotEmpty) '場所、${notice.place}',
      '出された時刻、${formatDateTimeJa(created)}',
      '発信元、${notice.senderName}',
      if (notice.text.trim().isNotEmpty) notice.text,
    ];
    setState(() => _speaking = true);
    await _c.speak(parts.join('。'));
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const KairanAppBar(title: 'お知らせ', showBack: true),
      body: ListenableBuilder(
        listenable: _c.store,
        builder: (context, _) {
          final m = _c.store.get(_msgId);
          if (m == null || m.isStub) {
            return const PageBody(
              children: [
                InfoBox(
                  'この お知らせは 見つかりません。期限が 切れたか、消されました。',
                ),
              ],
            );
          }
          final env = m.envelope;
          final body = env.notice;
          final created = dateTimeFromEpoch(env.createdAt);
          final received = dateTimeFromEpoch(m.receivedAt);
          final expires = dateTimeFromEpoch(_c.store.localExpiresAt(m));
          final elapsed = Duration(seconds: _c.now - env.createdAt);
          final receivedText = _sameDay(created, received)
              ? formatTimeJa(received)
              : formatDateTimeJa(received);
          final title = body?.title ?? '';
          final place = body?.place ?? '';
          final text = body?.text ?? '';
          final sender = body?.senderName ?? '';
          final active = !m.retracted && m.supersededBy == null && body != null;
          final owner = m.isLocal && active;
          final officialOther = !m.isLocal && active && _c.canRetract(m);
          final training = isTrainingTitle(title);
          final clockSuspicious = !m.isLocal &&
              (env.createdAt > m.receivedAt + 3600 ||
                  env.createdAt < m.receivedAt - 24 * 3600);
          final previous = env.supersedes != null ? _c.store.get(env.supersedes!) : null;
          final previousNotice = previous?.envelope.notice;
          final group = _c.groups.byCode(m.groupId);
          final asks = body != null && AppController.asksReply(m);

          final buttons = <Widget>[];
          if (body != null) {
            buttons.add(SecondaryButton(
              label: _speaking ? '読み上げを 止める' : '読み上げる',
              icon: _speaking ? Icons.stop : Icons.volume_up_outlined,
              onPressed: _busy ? null : () => _toggleSpeak(m, body),
            ));
          }
          if (owner) {
            if (env.category.endable && !looksLikeEndTitle(title)) {
              buttons.add(SecondaryButton(
                label: '終わりました',
                onPressed: _busy ? null : () => _end(m, body),
              ));
            }
            buttons.add(SecondaryButton(
              label: '書きなおす',
              onPressed: _busy ? null : _rewrite,
            ));
            buttons.add(SecondaryButton(
              label: '取り消す',
              danger: true,
              onPressed: _busy ? null : () => _retract(m, body),
            ));
          } else if (officialOther) {
            buttons.add(SecondaryButton(
              label: '公式として 取り消す',
              danger: true,
              onPressed: _busy ? null : () => _retract(m, body),
            ));
            buttons.add(SecondaryButton(
              label: '取り消して 新しく 書く',
              onPressed: _busy ? null : () => _retractAndRewrite(m, body),
            ));
          }

          return PageBody(
            bottom: buttons.isEmpty
                ? null
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < buttons.length; i++) ...[
                        if (i > 0) const SizedBox(height: KairanSizes.gap),
                        buttons[i],
                      ],
                    ],
                  ),
            children: [
              if (m.retracted) ...[
                InfoBox(
                  m.retractedByOfficial
                      ? 'この お知らせは 公式により 取り消されました。'
                      : 'この お知らせは 取り消されました。',
                  kind: InfoKind.danger,
                ),
                const SizedBox(height: 12),
              ] else if (m.supersededBy != null) ...[
                const InfoBox('この お知らせは 新しい内容に 置き換えられました。'),
                const SizedBox(height: 8),
                SecondaryButton(
                  label: '新しい 内容を 見る',
                  onPressed: () => openNoticeDetail(context, _c, m.supersededBy!),
                ),
                const SizedBox(height: 12),
              ],
              if (training) ...[
                const InfoBox(
                  'これは 訓練の お知らせです。本物の 災害では ありません。',
                  kind: InfoKind.caution,
                ),
                const SizedBox(height: 12),
              ],
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: KairanSizes.gap,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (training) const TrainingTag(),
                        CategoryTag(env.category.label),
                        RoleBadge(env.role),
                        if (m.isLocal) const StateTag('自分の 投稿'),
                        if (asks) const CautionTag('返事を ください'),
                        if (env.supersedes != null)
                          StateTag(looksLikeEndTitle(title) ? '終わりました' : '書きなおし'),
                      ],
                    ),
                  ),
                  const SizedBox(width: KairanSizes.gap),
                  Text(
                    '掲示番号 ${AppController.bulletinNumber(env.msgId)}',
                    style: KairanTextStyles.metaSecondary,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(title, style: KairanTextStyles.noticeTitle),
              const SizedBox(height: 8),
              if (place.isNotEmpty) ...[
                Text('場所: $place', style: KairanTextStyles.body),
                const SizedBox(height: 4),
              ],
              Text(
                '出された時刻: ${formatDateTimeJa(created)}（${formatRelativeJa(elapsed)}）',
                style: clockSuspicious ? KairanTextStyles.metaSecondary : KairanTextStyles.meta,
              ),
              if (clockSuspicious)
                const Text(
                  '（出した スマホの 時計が ずれている かもしれません）',
                  style: KairanTextStyles.metaSecondary,
                ),
              const SizedBox(height: 4),
              Text('発信元: $sender', style: KairanTextStyles.meta),
              if (group != null) ...[
                const SizedBox(height: 4),
                Text('グループ: ${displayGroupName(group.name)}', style: KairanTextStyles.meta),
              ],
              const SizedBox(height: 16),
              if (text.isNotEmpty)
                CardBox(child: SelectableText(text, style: KairanTextStyles.body))
              else
                const Text('（本文は ありません）', style: KairanTextStyles.metaSecondary),
              if (asks) ...[
                const SizedBox(height: 16),
                _ReplyPanel(controller: _c, request: m, active: active),
              ],
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 12),
              if (previousNotice != null) ...[
                Text(
                  '前の 内容（${formatTimeJa(dateTimeFromEpoch(previous!.envelope.createdAt))} 発信）: ${previousNotice.title}',
                  style: KairanTextStyles.metaSecondary,
                ),
                if (previous.isLocal && previousNotice.place.isNotEmpty)
                  Text('場所: ${previousNotice.place}', style: KairanTextStyles.metaSecondary),
                if (previous.isLocal && previousNotice.text.trim().isNotEmpty)
                  Text(previousNotice.text, style: KairanTextStyles.metaSecondary),
                const SizedBox(height: 8),
              ],
              Text(
                m.isLocal
                    ? 'この端末から 出しました: $receivedText'
                    : 'この端末に 届いた時刻: $receivedText（近くの人の スマホから）',
                style: KairanTextStyles.meta,
              ),
              const SizedBox(height: 4),
              if (!m.isLocal)
                Text('転送 ${formatCountJa(env.hop, '回')}', style: KairanTextStyles.meta),
              const SizedBox(height: 4),
              Text(
                '有効期限: ${formatDateTimeJa(expires)} まで',
                style: KairanTextStyles.meta,
              ),
              const SizedBox(height: 16),
            ],
          );
        },
      ),
    );
  }
}

/// 安否確認（返事を 求める お知らせ）の返事の欄。
///
/// 本部・スタッフ・出した本人には返事の集計と「返事を 見る」、それ以外には
/// 「無事です」「家に います」「困っています」「助けて」のボタンと、送った返事の状態を出す。
class _ReplyPanel extends StatelessWidget {
  const _ReplyPanel({
    required this.controller,
    required this.request,
    required this.active,
  });

  final AppController controller;
  final StoredMessage request;

  /// 取り消し・置き換えされていない（返事を受け付ける）か。
  final bool active;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final now = dateTimeFromEpoch(c.now);
    if (c.canSeeReports(request.groupId) || request.isLocal) {
      final replies = c.receivedReports(
        groupCode: request.groupId,
        inReplyTo: request.msgId,
      );
      final summary = AppController.summarize(replies);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InfoBox(
            '${summary.line()}${summary.unacked > 0 ? '\nまだ 返事を していない: ${formatCountJa(summary.unacked, '件')}' : ''}',
            title: '返事 ${formatCountJa(summary.total, '件')}',
            kind: summary.unackedSos > 0 ? InfoKind.danger : InfoKind.plain,
          ),
          const SizedBox(height: KairanSizes.gap),
          SecondaryButton(
            label: '返事を 見る',
            onPressed: () => openReportsScreen(
              context,
              c,
              groupCode: request.groupId,
              inReplyTo: request.msgId,
            ),
          ),
        ],
      );
    }
    final mine = c.myReports(inReplyTo: request.msgId);
    final children = <Widget>[];
    if (active && c.canReportTo(request.groupId, inReplyTo: request.msgId)) {
      void open(ReportType type) => openReportScreen(
            context,
            c,
            type: type,
            inReplyTo: request.msgId,
            groupCode: request.groupId,
          );
      children.addAll([
        const InfoBox(
          'この お知らせは 返事を 求めて います。当てはまる ボタンを 押してください。',
          title: '返事を してください',
          kind: InfoKind.caution,
        ),
        const SizedBox(height: KairanSizes.gap),
        PrimaryButton(label: ReportType.safe.label, onPressed: () => open(ReportType.safe)),
        const SizedBox(height: KairanSizes.gap),
        SecondaryButton(label: ReportType.home.label, onPressed: () => open(ReportType.home)),
        const SizedBox(height: KairanSizes.gap),
        SecondaryButton(label: ReportType.need.label, onPressed: () => open(ReportType.need)),
        const SizedBox(height: KairanSizes.gap),
        SecondaryButton(
          label: ReportType.sos.label,
          danger: true,
          onPressed: () => open(ReportType.sos),
        ),
      ]);
    }
    for (final e in mine) {
      final sent = formatDayTimeJa(dateTimeFromEpoch(e.message.envelope.createdAt), now: now);
      final ack = e.ack;
      children.addAll([
        const SizedBox(height: KairanSizes.gap),
        InfoBox(
          ack == null
              ? '「${e.info.type.label}」を 送りました（$sent）。まだ 受け取りの 返事は ありません。'
              : '「${e.info.type.label}」を 送りました（$sent）。${c.ackSenderLabel(ack)}が 受け取りました（${formatDayTimeJa(dateTimeFromEpoch(ack.envelope.createdAt), now: now)}）。',
          kind: ack == null ? InfoKind.plain : InfoKind.success,
        ),
      ]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}
