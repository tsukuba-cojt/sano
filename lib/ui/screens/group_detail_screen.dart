/// グループ詳細（コード・QR、本部コード／スタッフコード入力、本部端末の設定、抜ける）。
/// docs/08 C09 C21 C23 C24。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kairanban/app/app_controller.dart';
import 'package:kairanban/mesh/groups.dart';

import '../../app/theme.dart';
import '../format.dart';
import '../routes.dart';
import '../widgets/big_button.dart';
import '../widgets/dialogs.dart';
import '../widgets/group_qr.dart';
import '../widgets/kairan_app_bar.dart';
import '../widgets/section.dart';
import 'groups_screen.dart';

class GroupDetailScreen extends StatefulWidget {
  const GroupDetailScreen({
    super.key,
    required this.controller,
    required this.code,
  });

  final AppController controller;
  final int code;

  @override
  State<GroupDetailScreen> createState() => _GroupDetailScreenState();
}

class _GroupDetailScreenState extends State<GroupDetailScreen> {
  bool _busy = false;

  AppController get _c => widget.controller;

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

  /// 8 桁コードと発信元名を聞く（本部 / スタッフ）。
  Future<void> _elevate(JoinedGroup g, {required bool hq}) async {
    final input = await showDialog<_ElevateInput>(
      context: context,
      builder: (context) => _ElevateDialog(
        hq: hq,
        initialSenderName: hq ? displayGroupName(g.name) : _c.settings.displayName,
      ),
    );
    if (input == null || !mounted) {
      return;
    }
    if (hq) {
      final ok = await showConfirmDialog(
        context,
        title: 'この端末を 本部端末に しますか？',
        message: '本部端末は 公式として お知らせを 出し、他の人の お知らせを 取り消せます。',
        confirmLabel: '本部端末に する',
      );
      if (!ok || !mounted) {
        return;
      }
    }
    await _run(() async {
      final result = await _c.elevate(widget.code, input.code);
      if (!mounted) {
        return;
      }
      switch (result) {
        case ElevateResult.hq:
        case ElevateResult.staff:
          await _c.setGroupSenderName(widget.code, input.senderName);
          if (!mounted) {
            return;
          }
          await showMessageDialog(
            context,
            title: result == ElevateResult.hq ? '本部端末に なりました' : 'スタッフに なりました',
            message: result == ElevateResult.hq
                ? 'これから 公式として お知らせを 出せます。発信元名は「${input.senderName}」です。'
                : 'これから スタッフとして お知らせを 出せます。発信元名は「${input.senderName}」です。',
          );
        case ElevateResult.notReady:
          await showMessageDialog(
            context,
            title: 'まだ 確かめられません',
            message: 'グループの 情報が まだ 届いていません。近くで もう一度 試してください。',
          );
        case ElevateResult.mismatch:
          await showMessageDialog(
            context,
            title: '番号が ちがいます',
            message: '8桁の 番号を もう一度 確かめてください。',
          );
        case ElevateResult.invalid:
          await showMessageDialog(
            context,
            title: '番号を 確かめてください',
            message: '8桁の 数字を 入れてください。本部コードは 1、スタッフコードは 2 で 始まります。',
          );
        case ElevateResult.notJoined:
          await showMessageDialog(
            context,
            title: 'できませんでした',
            message: 'この グループには 参加していません。',
          );
      }
    });
  }

  Future<void> _editSenderName(JoinedGroup g) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _TextDialog(
        title: 'この グループでの 発信元名',
        hint: '例: 〇〇総合病院、〇〇小学校 受付',
        initial: _c.senderNameFor(g),
        maxLength: 16,
      ),
    );
    if (name == null || !mounted) {
      return;
    }
    await _run(() => _c.setGroupSenderName(widget.code, name), done: '発信元名を 保存しました。');
  }

  Future<void> _republish() =>
      _run(() => _c.republishGroupInfo(widget.code), done: 'グループの 情報を もう一度 広げます。');

  Future<void> _setMembersCanPost(bool v) =>
      _run(() => _c.setMembersCanPost(widget.code, v));

  Future<void> _setAcceptsHelp(bool v) => _run(() => _c.setAcceptsHelp(widget.code, v));

  Future<void> _regenerateCodes() async {
    final ok = await showConfirmDialog(
      context,
      title: 'コードを 作り直しますか？',
      message: '本部コードと スタッフコードを 新しく します。すでに 昇格した 端末は そのまま 残ります。新しい コードを 紙に 書いて 保管してください。',
      confirmLabel: '作り直す',
      danger: true,
    );
    if (!ok || !mounted) {
      return;
    }
    await _run(() => _c.regenerateCodes(widget.code), done: 'コードを 作り直しました。');
  }

  Future<void> _retractTraining() async {
    final ok = await showConfirmDialog(
      context,
      title: '訓練の お知らせを すべて 取り消しますか？',
      message: '見出しが【訓練】で 始まる お知らせを 取り消します。近くの スマホにも 広がります。',
      confirmLabel: '取り消す',
      danger: true,
    );
    if (!ok || !mounted) {
      return;
    }
    await _run(() async {
      final n = await _c.retractTraining(widget.code);
      if (mounted) {
        showSnack(context, '訓練の お知らせを ${formatCountJa(n, '件')} 取り消しました。');
      }
    });
  }

  Future<void> _leave(String name) async {
    if (_c.settings.relayMode) {
      await showMessageDialog(
        context,
        title: '先に 中継役を やめてください',
        message: '中継役として 動いている あいだは、グループから 抜けられません。設定 → 通信 で 中継役を やめてから もう一度 試してください。',
      );
      return;
    }
    final ok = await showConfirmDialog(
      context,
      title: 'このグループから 抜けますか？',
      message: '「$name」の お知らせが 届かなく なります。もう一度 参加するには 参加コードが 必要です。',
      confirmLabel: '抜ける',
      danger: true,
    );
    if (!ok || !mounted) {
      return;
    }
    try {
      await _c.leaveGroup(widget.code);
    } catch (e) {
      if (!mounted) {
        return;
      }
      await showMessageDialog(
        context,
        title: '抜けられませんでした',
        message: describeError(e),
      );
      return;
    }
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const KairanAppBar(title: 'グループ', showBack: true),
      body: ListenableBuilder(
        listenable: Listenable.merge([_c.groups, _c]),
        builder: (context, _) {
          final g = _c.groups.byCode(widget.code);
          if (g == null) {
            return const PageBody(
              children: [InfoBox('この グループには 参加していません。')],
            );
          }
          final hq = g.hqCode;
          final staff = g.staffCode;
          final relay = _c.settings.relayMode;
          return PageBody(
            children: [
              Text(displayGroupName(g.name), style: KairanTextStyles.noticeTitle),
              const SizedBox(height: 4),
              Text('あなたの 役割: ${roleLabelOf(g)}', style: KairanTextStyles.meta),
              Text(
                g.membersCanPost ? '参加者も お知らせを 出せます。' : '発信者（本部・スタッフ）だけが お知らせを 出せます。',
                style: KairanTextStyles.meta,
              ),
              if (g.description.trim().isNotEmpty) ...[
                const SizedBox(height: 4),
                Text('問い合わせ先: ${g.description}', style: KairanTextStyles.meta),
              ],
              if (g.closed) ...[
                const SizedBox(height: 8),
                InfoBox(
                  g.successor > 0
                      ? 'この グループは 終了しました。新しい 参加コードは ${formatGroupCode(g.successor)} と 届いています。広報紙の 番号と 同じときだけ、参加してください。'
                      : 'この グループは 終了しました。',
                  kind: InfoKind.caution,
                ),
              ],
              if (g.postRole.index > 0) ...[
                const SizedBox(height: 8),
                Text('発信元名: ${_c.senderNameFor(g)}', style: KairanTextStyles.meta),
                const SizedBox(height: 4),
                SecondaryButton(
                  label: '発信元名を 変える',
                  onPressed: _busy ? null : () => _editSenderName(g),
                ),
              ],
              const SectionTitle('参加コード（6桁）'),
              BigCodeText(
                formatGroupCode(g.code),
                semanticsLabel: '参加コード ${formatGroupCode(g.code)}',
              ),
              const SizedBox(height: 12),
              GroupQrCode(g.code),
              const SizedBox(height: 8),
              const Text(
                'この 番号か QR を 伝えると、ほかの人も 参加できます。',
                style: KairanTextStyles.body,
              ),
              if (g.canManage && !relay) ...[
                if (hq != null) ...[
                  const SectionTitle('本部コード（8桁）'),
                  BigCodeText(
                    formatOfficialCode(hq),
                    semanticsLabel: '本部コード ${formatOfficialCode(hq)}',
                  ),
                  const SizedBox(height: 8),
                  const InfoBox(
                    '本部コードは 防災課の 端末だけに 教えてください。入れた端末は 公式として お知らせを 出し、他の人の お知らせを 取り消せます。',
                    title: '本部だけに',
                    kind: InfoKind.caution,
                  ),
                ],
                if (staff != null) ...[
                  const SectionTitle('スタッフコード（8桁）'),
                  BigCodeText(
                    formatOfficialCode(staff),
                    semanticsLabel: 'スタッフコード ${formatOfficialCode(staff)}',
                  ),
                  const SizedBox(height: 8),
                  const InfoBox(
                    'スタッフコードは 避難所や 病院・薬局・電力・バスの 担当者に 教えてください。入れた端末は「スタッフ」として お知らせを 出せます。住民には 教えないでください。',
                    title: 'スタッフにだけ',
                    kind: InfoKind.caution,
                  ),
                ],
                const SizedBox(height: 8),
                const Text(
                  'この 8桁は 紙に 書いて 2人以上で 保管してください。端末を 替えたときに 使います。',
                  style: KairanTextStyles.metaSecondary,
                ),
                const SectionTitle('グループの 設定'),
                Material(
                  color: KairanColors.card,
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(KairanSizes.radius)),
                    side: BorderSide(color: KairanColors.borderDecorative),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      SwitchListTile(
                        value: g.membersCanPost,
                        onChanged: _busy ? null : _setMembersCanPost,
                        title: const Text('参加者も 投稿できる'),
                        subtitle: Text(
                          g.membersCanPost
                              ? 'オン: 参加した人は だれでも お知らせを 出せます。'
                              : 'オフ: 本部・スタッフだけが お知らせを 出せます。',
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      ),
                      const Divider(),
                      SwitchListTile(
                        value: g.acceptsHelp,
                        onChanged: _busy ? null : _setAcceptsHelp,
                        title: const Text('住民からの 知らせを 受け付ける'),
                        subtitle: const Text(
                          'オンにすると、住民が「本部に 知らせる」から SOS・無事です・在宅避難・困っています を 送れます。'
                          '見る 係の 人を 置いてから オンにしてください。安否確認の 返事は オフでも 届きます。',
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SecondaryButton(
                  label: 'グループの 情報を もう一度 広げる',
                  onPressed: _busy ? null : _republish,
                ),
                const SizedBox(height: KairanSizes.gap),
                SecondaryButton(
                  label: 'コードを 作り直す',
                  onPressed: _busy ? null : _regenerateCodes,
                ),
              ] else if (!g.canManage) ...[
                const SectionTitle('係の 人は コードを 入れる'),
                const Text(
                  '本部（防災課）から もらった 8桁の 番号を 入れると、公式または スタッフとして お知らせを 出せます。',
                  style: KairanTextStyles.body,
                ),
                const SizedBox(height: 8),
                SecondaryButton(
                  label: '本部コードを 入れる',
                  onPressed: _busy ? null : () => _elevate(g, hq: true),
                ),
                const SizedBox(height: KairanSizes.gap),
                SecondaryButton(
                  label: g.isStaff ? 'スタッフコードを 入れ直す' : 'スタッフコードを 入れる',
                  onPressed: _busy ? null : () => _elevate(g, hq: false),
                ),
              ],
              if (g.canManage || g.isStaff) ...[
                const SizedBox(height: 16),
                SecondaryButton(
                  label: '住民からの 知らせを 見る',
                  icon: Icons.campaign_outlined,
                  onPressed: () => openReportsScreen(context, _c, groupCode: g.code),
                ),
              ],
              if (g.postRole.index > 0) ...[
                const SizedBox(height: 16),
                SecondaryButton(
                  label: '訓練の お知らせを すべて 取り消す',
                  onPressed: _busy ? null : _retractTraining,
                ),
              ],
              const SizedBox(height: 32),
              SecondaryButton(
                label: 'このグループから 抜ける',
                danger: true,
                onPressed: _busy ? null : () => _leave(displayGroupName(g.name)),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ElevateInput {
  const _ElevateInput(this.code, this.senderName);
  final String code;
  final String senderName;
}

/// 8 桁コードと発信元名の入力ダイアログ。
class _ElevateDialog extends StatefulWidget {
  const _ElevateDialog({required this.hq, required this.initialSenderName});

  final bool hq;
  final String initialSenderName;

  @override
  State<_ElevateDialog> createState() => _ElevateDialogState();
}

class _ElevateDialogState extends State<_ElevateDialog> {
  final _codeCtl = TextEditingController();
  late final TextEditingController _nameCtl =
      TextEditingController(text: widget.initialSenderName);

  @override
  void dispose() {
    _codeCtl.dispose();
    _nameCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canSubmit = _codeCtl.text.trim().length == 8 && _nameCtl.text.trim().isNotEmpty;
    return AlertDialog(
      title: Text(widget.hq ? '本部コードを 入れる' : 'スタッフコードを 入れる'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _codeCtl,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(8),
              ],
              maxLength: 8,
              autofocus: true,
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                letterSpacing: 3,
                color: KairanColors.text,
              ),
              decoration: InputDecoration(
                labelText: widget.hq ? '本部コード（8桁）' : 'スタッフコード（8桁）',
                hintText: widget.hq ? '1xxxxxxx' : '2xxxxxxx',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameCtl,
              maxLength: 16,
              style: KairanTextStyles.body,
              decoration: const InputDecoration(
                labelText: 'この グループでの 発信元名',
                hintText: '例: 〇〇総合病院、〇〇小学校 受付',
                helperText: '施設名・部署名を 入れてください。個人名は 入れないでください。',
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('やめる'),
        ),
        TextButton(
          onPressed: canSubmit
              ? () => Navigator.of(context).pop(
                    _ElevateInput(_codeCtl.text.trim(), _nameCtl.text.trim()),
                  )
              : null,
          child: const Text('決める'),
        ),
      ],
    );
  }
}

/// 1 行の文字入力ダイアログ。
class _TextDialog extends StatefulWidget {
  const _TextDialog({
    required this.title,
    required this.hint,
    required this.initial,
    this.maxLength = 40,
  });

  final String title;
  final String hint;
  final String initial;
  final int maxLength;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final TextEditingController _ctl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _ctl,
        maxLength: widget.maxLength,
        autofocus: true,
        style: KairanTextStyles.body,
        decoration: InputDecoration(hintText: widget.hint),
        onChanged: (_) => setState(() {}),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('やめる'),
        ),
        TextButton(
          onPressed: _ctl.text.trim().isEmpty
              ? null
              : () => Navigator.of(context).pop(_ctl.text.trim()),
          child: const Text('保存する'),
        ),
      ],
    );
  }
}
