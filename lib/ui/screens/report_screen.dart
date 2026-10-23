/// 「本部に 知らせる」画面（SOS・無事です・在宅避難・困っています、docs/04 §4.7）。
///
/// 1 画面目で種類を選び、2 画面目で人数・場所などを選んで送る。安否確認の
/// お知らせの「返事の ボタン」から開いたときは、種類と返事先が決まった状態で開く。
library;

import 'package:flutter/material.dart';
import 'package:kairanban/app/app_controller.dart';
import 'package:kairanban/core/epoch.dart';
import 'package:kairanban/core/report.dart';
import 'package:kairanban/mesh/groups.dart';

import '../../app/theme.dart';
import '../format.dart';
import '../routes.dart';
import '../widgets/big_button.dart';
import '../widgets/dialogs.dart';
import '../widgets/kairan_app_bar.dart';
import '../widgets/report_card.dart';
import '../widgets/section.dart';

/// 119 番・110 番の案内（SOS）。
const String kEmergencyCallCaution =
    '命に かかわる ときは 119番・110番に 電話してください。'
    'つながらない ときは 大きな 声や 笛で 近所に 知らせてください。';

/// 送る内容の注意（平文で中継されること、C21）。
const String kReportPrivacyCaution =
    '近くの スマホを 通って 本部に 届きます。暗号化 されないので、'
    '病名や 番地は 書かないでください。';

class ReportScreen extends StatefulWidget {
  const ReportScreen({
    super.key,
    required this.controller,
    this.initialType,
    this.inReplyTo,
    this.groupCode,
  });

  final AppController controller;

  /// 最初から選んでおく種類（安否確認の返事ボタンから）。
  final ReportType? initialType;

  /// 返事先の安否確認お知らせの msg_id。
  final int? inReplyTo;

  /// 送り先のグループ（返事のときは安否確認のグループ）。
  final int? groupCode;

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  late final List<JoinedGroup> _groups;
  int? _groupCode;
  ReportType? _type;
  int _people = 1;
  final Set<ReportNeed> _needs = <ReportNeed>{};
  bool _injured = false;
  final _placeCtl = TextEditingController();
  final _nameCtl = TextEditingController();
  final _noteCtl = TextEditingController();
  bool _sending = false;

  AppController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    final reply = widget.inReplyTo;
    final request = reply == null ? null : _c.store.get(reply);
    if (request != null) {
      final g = _c.groups.byCode(request.groupId);
      _groups = g == null ? const [] : [g];
    } else {
      _groups = _c.reportGroups;
    }
    final preferred = widget.groupCode ?? request?.groupId;
    if (preferred != null && _groups.any((g) => g.code == preferred)) {
      _groupCode = preferred;
    } else if (_groups.isNotEmpty) {
      _groupCode = _groups.first.code;
    }
    _type = widget.initialType;
    final name = _c.settings.displayName.trim();
    if (name.isNotEmpty) {
      _nameCtl.text = name;
    }
  }

  @override
  void dispose() {
    _placeCtl.dispose();
    _nameCtl.dispose();
    _noteCtl.dispose();
    super.dispose();
  }

  JoinedGroup? get _group {
    final code = _groupCode;
    if (code == null) {
      return null;
    }
    for (final g in _groups) {
      if (g.code == code) {
        return g;
      }
    }
    return null;
  }

  void _choose(ReportType type) {
    setState(() {
      _type = type;
      _needs.clear();
      _injured = false;
      _people = 1;
    });
  }

  ReportInfo _draft(ReportType type) => ReportInfo(
    type: type,
    people: _people,
    needs: [
      for (final n in ReportNeed.values)
        if (_needs.contains(n)) n,
    ],
    injured: _injured,
    inReplyTo: widget.inReplyTo,
  );

  Future<void> _send() async {
    final type = _type;
    final group = _group;
    if (type == null || group == null) {
      return;
    }
    if (type.requiresNeeds && _needs.isEmpty) {
      await showMessageDialog(
        context,
        title: '送れません',
        message: '困っている ことを 1つ 以上 選んでください。',
      );
      return;
    }
    final name = type.allowsName ? _nameCtl.text.trim() : '';
    final ok = await showConfirmDialog(
      context,
      title: type == ReportType.sos ? '助けを 求める 知らせを 送りますか？' : '送りますか？',
      message:
          '近くの スマホを 通って、${displayGroupName(group.name)}の 本部・係の 人に 届きます。'
          '届くまで 時間が かかります。急ぐときは 近所の 人にも 声を かけてください。'
          '${name.isEmpty ? '名前は 送りません。' : '名前「$name」も 送ります。'}',
      confirmLabel: '送る',
      danger: type == ReportType.sos,
    );
    if (!ok || !mounted) {
      return;
    }
    setState(() => _sending = true);
    try {
      await _c.sendReport(
        groupCode: group.code,
        type: type,
        people: _people,
        needs: [
          for (final n in ReportNeed.values)
            if (_needs.contains(n)) n,
        ],
        injured: _injured,
        place: _placeCtl.text,
        name: name,
        note: _noteCtl.text,
        inReplyTo: widget.inReplyTo,
      );
    } on ReportTooSoonException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() => _sending = false);
      await showMessageDialog(
        context,
        title: 'さきほど 送りました',
        message: e.toString(),
      );
      return;
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() => _sending = false);
      await showMessageDialog(
        context,
        title: '送れませんでした',
        message: describeError(e),
      );
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() => _sending = false);
    await showMessageDialog(
      context,
      title: '送りました',
      message:
          '近くの スマホに 渡しながら 本部へ 届きます。'
          '本部が 受け取ると、通知と「送った 知らせ」で 分かります。',
    );
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final type = _type;
    return Scaffold(
      appBar: KairanAppBar(
        title: widget.inReplyTo != null ? '安否確認に 返事を する' : '本部に 知らせる',
        showBack: true,
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([_c.store, _c.groups]),
        builder: (context, _) =>
            type == null ? _buildChooser(context) : _buildForm(context, type),
      ),
    );
  }

  Widget _requestBox() {
    final reply = widget.inReplyTo;
    final request = reply == null ? null : _c.store.get(reply);
    final notice = request?.envelope.notice;
    if (notice == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InfoBox('『${notice.title}』（${notice.senderName}）への 返事です。'),
    );
  }

  Widget _buildChooser(BuildContext context) {
    final mine = _c.myReports(inReplyTo: widget.inReplyTo);
    final now = dateTimeFromEpoch(_c.now);
    return PageBody(
      children: [
        _requestBox(),
        if (_groups.isEmpty)
          const InfoBox('知らせを 受け付けて いる グループが ありません。', kind: InfoKind.caution),
        if (_groups.length > 1) ...[
          const SectionTitle('送り先'),
          ChoiceGrid(
            columns: 1,
            children: [
              for (final g in _groups)
                ChoiceButton(
                  label: displayGroupName(g.name),
                  selected: g.code == _groupCode,
                  onPressed: () => setState(() => _groupCode = g.code),
                ),
            ],
          ),
        ],
        const SectionTitle('どれを 知らせますか'),
        for (final t in ReportType.values) ...[
          _TypeTile(type: t, onTap: _groups.isEmpty ? null : () => _choose(t)),
          const SizedBox(height: KairanSizes.gap),
        ],
        const SizedBox(height: 4),
        const InfoBox(kEmergencyCallCaution, kind: InfoKind.danger),
        if (mine.isNotEmpty) ...[
          const SectionTitle('送った 知らせ'),
          for (final e in mine) ...[
            ReportCard(
              type: e.info.type,
              title: e.body.title,
              place: e.body.place,
              note: e.body.text,
              time: dateTimeFromEpoch(e.message.envelope.createdAt),
              now: now,
              timeLabel: '送った',
              acked: e.acked,
              isReply: e.info.inReplyTo != null,
              stateLine: e.ack == null
                  ? 'まだ 受け取りの 返事は ありません'
                  : '${_c.ackSenderLabel(e.ack!)}が 受け取りました（${formatDayTimeJa(dateTimeFromEpoch(e.ack!.envelope.createdAt), now: now)}）',
              onTap: () => openReportDetail(context, _c, e.msgId),
            ),
            const SizedBox(height: KairanSizes.gap),
          ],
        ],
      ],
    );
  }

  String _peopleTitle(ReportType type) {
    switch (type) {
      case ReportType.sos:
        return '助けが 必要な 人数';
      case ReportType.safe:
        return '無事な 人数（自分を 入れて）';
      case ReportType.home:
        return '家に いる 人数（自分を 入れて）';
      case ReportType.need:
        return '困っている 人数';
    }
  }

  String _noteHint(ReportType type) {
    switch (type) {
      case ReportType.sos:
        return '例: 2階に 閉じこめられて います';
      case ReportType.safe:
        return '例: 〇〇小学校に 避難して います';
      case ReportType.home:
        return '例: 高齢の 母と 2人です';
      case ReportType.need:
        return '例: 薬が あと 2日分です';
    }
  }

  Widget _buildForm(BuildContext context, ReportType type) {
    final group = _group;
    final preview = _draft(
      type,
    ).title(name: type.allowsName ? _nameCtl.text.trim() : '');
    return PageBody(
      bottom: PrimaryButton(
        label: _sending
            ? '送っています…'
            : (type == ReportType.sos ? '助けを 求める 知らせを 送る' : '送る'),
        icon: Icons.send,
        onPressed: _sending || group == null ? null : _send,
      ),
      children: [
        _requestBox(),
        Row(
          children: [
            ReportTypeTag(type),
            const SizedBox(width: KairanSizes.gap),
            Expanded(
              child: Text(type.label, style: KairanTextStyles.noticeTitle),
            ),
            TextButton(
              onPressed: _sending ? null : () => setState(() => _type = null),
              child: const Text('選びなおす'),
            ),
          ],
        ),
        if (group != null)
          Text(
            '送り先: ${displayGroupName(group.name)}',
            style: KairanTextStyles.meta,
          ),
        if (type == ReportType.sos) ...[
          const SizedBox(height: 8),
          const InfoBox(kEmergencyCallCaution, kind: InfoKind.danger),
        ],
        SectionTitle(_peopleTitle(type)),
        ChoiceGrid(
          columns: 3,
          children: [
            for (final n in kReportPeopleChoices)
              ChoiceButton(
                label: reportPeopleLabel(n),
                selected: _people == n,
                onPressed: () => setState(() => _people = n),
              ),
          ],
        ),
        if (type.allowsNeeds) ...[
          SectionTitle(
            type.requiresNeeds ? '困っている こと（いくつでも）' : '困っている ことが あれば（いくつでも）',
          ),
          ChoiceGrid(
            columns: 1,
            children: [
              for (final n in ReportNeed.values)
                ChoiceButton(
                  label: n.label,
                  selected: _needs.contains(n),
                  onPressed: () => setState(() {
                    if (!_needs.remove(n)) {
                      _needs.add(n);
                    }
                  }),
                ),
            ],
          ),
        ],
        if (type.allowsInjured) ...[
          const SizedBox(height: 12),
          ChoiceButton(
            label: 'けがを している 人が いる',
            selected: _injured,
            onPressed: () => setState(() => _injured = !_injured),
          ),
        ],
        if (type.allowsName) ...[
          const SectionTitle('名前（なくても よい）'),
          TextField(
            controller: _nameCtl,
            maxLength: 16,
            textInputAction: TextInputAction.next,
            style: KairanTextStyles.body,
            decoration: const InputDecoration(
              hintText: '例: 山田 花子',
              helperText: '家族を さがす ときに 役立ちます。書かなくても 送れます。',
              helperMaxLines: 2,
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
        SectionTitle(
          type == ReportType.sos ? '場所（できるだけ 書いてください）' : '場所（なくても よい）',
        ),
        TextField(
          controller: _placeCtl,
          maxLength: 40,
          textInputAction: TextInputAction.next,
          style: KairanTextStyles.body,
          decoration: const InputDecoration(
            hintText: '例: 〇〇町2丁目 公民館の 近く',
            helperText: '町名と 目印だけ（番地は 書かない）',
          ),
        ),
        const SectionTitle('ひとこと（なくても よい）'),
        TextField(
          controller: _noteCtl,
          maxLength: 40,
          style: KairanTextStyles.body,
          decoration: InputDecoration(hintText: _noteHint(type)),
        ),
        const SizedBox(height: 8),
        const InfoBox(kReportPrivacyCaution, kind: InfoKind.caution),
        const SizedBox(height: 12),
        Text('見出し: $preview', style: KairanTextStyles.meta),
        const SizedBox(height: 16),
      ],
    );
  }
}

/// 種類を選ぶ大きなボタン（SOS は赤地白文字）。
class _TypeTile extends StatelessWidget {
  const _TypeTile({required this.type, required this.onTap});

  final ReportType type;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final sos = type == ReportType.sos;
    final fg = sos ? KairanColors.card : KairanColors.text;
    return Semantics(
      button: true,
      label: '${type.label}。${type.description}',
      onTap: onTap,
      child: ExcludeSemantics(
        child: Material(
          color: sos ? KairanColors.danger : KairanColors.card,
          shape: RoundedRectangleBorder(
            borderRadius: const BorderRadius.all(
              Radius.circular(KairanSizes.radius),
            ),
            side: BorderSide(
              color: sos ? KairanColors.danger : KairanColors.border,
              width: 2,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 72),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            type.label,
                            style: KairanTextStyles.noticeTitle.copyWith(
                              color: fg,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            type.description,
                            style: KairanTextStyles.meta.copyWith(color: fg),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, color: fg, size: 32),
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
