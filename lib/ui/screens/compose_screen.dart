/// お知らせを書く画面（docs/08 C01 C02 C11 C12 C14 C15 C23）。
library;

import 'package:flutter/material.dart';
import 'package:kairanban/app/app_controller.dart';
import 'package:kairanban/core/categories.dart';
import 'package:kairanban/core/envelope.dart';
import 'package:kairanban/core/epoch.dart';
import 'package:kairanban/mesh/groups.dart';

import '../../app/theme.dart';
import '../format.dart';
import '../widgets/big_button.dart';
import '../widgets/dialogs.dart';
import '../widgets/kairan_app_bar.dart';
import '../widgets/section.dart';

/// 有効期限の選択肢（docs/04 §4.4、C02）。「30日」は公式・スタッフだけに出す。
const List<Duration> kTtlChoices = [
  Duration(hours: 3),
  Duration(hours: 6),
  Duration(hours: 12),
  Duration(days: 1),
  Duration(days: 3),
  Duration(days: 7),
  Duration(days: 30),
];

/// 同報できるグループ数の上限（C14）。
const int kMaxBroadcastGroups = 5;

/// 見出しテンプレートの `{場所}` を [place] で置き換える。
///
/// [place] が空なら置き換えない（ほかの `{...}` は利用者が書き換える）。
String applyTitleTemplate(String template, String place) {
  final trimmed = place.trim();
  if (trimmed.isEmpty) {
    return template;
  }
  return template.replaceAll('{場所}', trimmed);
}

/// 見出しに `{...}` の穴埋めが残っているか。
bool hasUnfilledPlaceholder(String title) => RegExp(r'\{[^}]*\}').hasMatch(title);

/// 書く画面の初期値（「取り消して 新しく 書く」などから渡す）。
class ComposePrefill {
  const ComposePrefill({
    this.groupCode,
    this.category,
    this.place = '',
    this.title,
    this.text = '',
    this.bannerText,
  });

  final int? groupCode;
  final NoticeCategory? category;
  final String place;
  final String? title;
  final String text;

  /// 画面上部の帯（例「元の 投稿: 〇〇さん」）。
  final String? bannerText;
}

class ComposeScreen extends StatefulWidget {
  const ComposeScreen({
    super.key,
    required this.controller,
    this.rewriteOf,
    this.prefill,
  });

  final AppController controller;

  /// 書きなおす元の msg_id（C01）。
  final int? rewriteOf;

  /// 初期値。
  final ComposePrefill? prefill;

  @override
  State<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends State<ComposeScreen> {
  late final List<JoinedGroup> _postable;
  final Set<int> _selectedGroups = <int>{};
  NoticeCategory _category = NoticeCategory.general;
  int _templateIndex = 0;
  Duration _ttl = NoticeCategory.general.defaultTtl;

  /// 「時刻を 決める」で選んだ終わる時刻（エポック秒）。null なら [_ttl]。
  int? _ttlUntil;
  bool _training = false;
  final _placeCtl = TextEditingController();
  final _titleCtl = TextEditingController();
  final _textCtl = TextEditingController();

  /// 利用者が見出しを手で書き換えたら、テンプレートで上書きしない。
  bool _titleEdited = false;
  bool _sending = false;

  AppController get _c => widget.controller;
  bool get _isRewrite => widget.rewriteOf != null;

  @override
  void initState() {
    super.initState();
    final rewriteOf = widget.rewriteOf;
    final prefill = widget.prefill;
    if (rewriteOf != null) {
      final m = _c.store.get(rewriteOf);
      final notice = m?.envelope.notice;
      final group = m == null ? null : _c.groups.byCode(m.groupId);
      _postable = group == null ? const [] : [group];
      if (m != null) {
        _selectedGroups.add(m.groupId);
        _category = m.envelope.category;
        _ttl = _category.defaultTtl;
      }
      if (notice != null) {
        _placeCtl.text = notice.place;
        _titleCtl.text = notice.title;
        _textCtl.text = notice.text;
        _titleEdited = true;
        _training = isTrainingTitle(notice.title);
      }
      return;
    }
    _postable = _c.groups.groups.where((g) => g.canPost).toList();
    if (prefill?.groupCode != null &&
        _postable.any((g) => g.code == prefill!.groupCode)) {
      _selectedGroups.add(prefill!.groupCode!);
    } else if (_postable.isNotEmpty) {
      _selectedGroups.add(_postable.first.code);
    }
    if (prefill != null) {
      _category = prefill.category ?? _category;
      _ttl = _category.defaultTtl;
      _placeCtl.text = prefill.place;
      _textCtl.text = prefill.text;
      final title = prefill.title;
      if (title != null && title.isNotEmpty) {
        _titleCtl.text = title;
        _titleEdited = true;
      }
    }
    _applyTemplate();
  }

  @override
  void dispose() {
    _placeCtl.dispose();
    _titleCtl.dispose();
    _textCtl.dispose();
    super.dispose();
  }

  /// 選んだグループのうち、公式・スタッフとして投稿できるものがあるか。
  bool get _postsAsStaffOrOfficial => _postable
      .where((g) => _selectedGroups.contains(g.code))
      .any((g) => g.postRole != SenderRole.resident);

  void _applyTemplate() {
    if (_titleEdited) {
      return;
    }
    final templates = _category.titleTemplates;
    final index = _templateIndex < templates.length ? _templateIndex : 0;
    _titleCtl.text = applyTitleTemplate(templates[index], _placeCtl.text);
  }

  void _selectCategory(NoticeCategory category) {
    setState(() {
      _category = category;
      _templateIndex = 0;
      _ttl = _training ? const Duration(hours: 3) : category.defaultTtl;
      _ttlUntil = null;
      _applyTemplate();
    });
  }

  void _selectTemplate(int index) {
    setState(() {
      _templateIndex = index;
      _titleEdited = false;
      _applyTemplate();
    });
  }

  void _onTitleChanged(String text) {
    setState(() {
      if (text.isEmpty) {
        // 全部消したらテンプレートに戻す。
        _titleEdited = false;
        _applyTemplate();
      } else {
        _titleEdited = true;
      }
    });
  }

  void _toggleGroup(int code) {
    setState(() {
      if (_selectedGroups.contains(code)) {
        if (_selectedGroups.length > 1) {
          _selectedGroups.remove(code);
        }
      } else if (_selectedGroups.length < kMaxBroadcastGroups) {
        _selectedGroups.add(code);
      }
    });
  }

  void _setTraining(bool v) {
    setState(() {
      _training = v;
      if (v) {
        _ttl = const Duration(hours: 3);
        _ttlUntil = null;
      } else {
        _ttl = _category.defaultTtl;
      }
    });
  }

  Future<void> _pickEndTime() async {
    final now = dateTimeFromEpoch(_c.now);
    final picked = await showDialog<DateTime>(
      context: context,
      builder: (context) => _EndTimeDialog(now: now),
    );
    if (picked == null || !mounted) {
      return;
    }
    final until = epochSecondsFrom(picked);
    if (until <= _c.now) {
      await showMessageDialog(
        context,
        title: '終わる 時刻が 過ぎています',
        message: '今より あとの 時刻を 選んでください。',
      );
      return;
    }
    setState(() => _ttlUntil = until);
  }

  Duration get _effectiveTtl {
    final until = _ttlUntil;
    if (until != null) {
      final seconds = until - _c.now;
      return Duration(seconds: seconds < 60 ? 60 : seconds);
    }
    return _ttl;
  }

  String? _validate() {
    if (_selectedGroups.isEmpty) {
      return 'お知らせを 出せる グループが ありません。';
    }
    final title = _titleCtl.text.trim();
    if (title.isEmpty) {
      return '見出しを 入れてください。';
    }
    if (hasUnfilledPlaceholder(title)) {
      return '見出しの { } の ところを 書きかえてください。';
    }
    final until = _ttlUntil;
    if (until != null && until <= _c.now) {
      return '終わる 時刻が 過ぎています。';
    }
    return null;
  }

  Future<void> _send() async {
    final problem = _validate();
    if (problem != null) {
      await showMessageDialog(context, title: '送れません', message: problem);
      return;
    }
    final groups =
        _postable.where((g) => _selectedGroups.contains(g.code)).toList();
    final String message;
    if (_isRewrite) {
      message = '前の お知らせは 消えて、この 内容に 置き換わります。近くの スマホに 広がります。';
    } else if (_training) {
      message = '訓練として 送ります。見出しに【訓練】が 付きます。';
    } else if (groups.length > 1) {
      final names = groups
          .map((g) => '${displayGroupName(g.name)}（${g.postRole.label}）')
          .join('、');
      message = '$names に 送ります（${groups.length} 件分 広がります）。取り消しても 他の スマホからは すぐには 消えません。';
    } else {
      message = 'この内容で 送ります。近くの スマホに 広がり、取り消しても 他の スマホからは すぐには 消えません。';
    }
    final ok = await showConfirmDialog(
      context,
      title: '送りますか？',
      message: message,
      confirmLabel: '送る',
    );
    if (!ok || !mounted) {
      return;
    }
    setState(() => _sending = true);
    try {
      final rewriteOf = widget.rewriteOf;
      if (rewriteOf != null) {
        await _c.supersedeNotice(
          rewriteOf,
          category: _category,
          title: _titleCtl.text.trim(),
          place: _placeCtl.text.trim(),
          text: _textCtl.text.trim(),
          ttl: _effectiveTtl,
        );
      } else {
        for (final g in groups) {
          await _c.postNotice(
            groupCode: g.code,
            category: _category,
            title: _titleCtl.text.trim(),
            place: _placeCtl.text.trim(),
            text: _textCtl.text.trim(),
            ttl: _effectiveTtl,
            training: _training,
          );
        }
      }
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
      title: _isRewrite ? '訂正しました' : '送りました',
      message: _isRewrite
          ? '訂正しました。近くの スマホに 広がります。'
          : '送りました。すれ違う人に 広がります。',
    );
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop();
  }

  String _ttlLabel() {
    final until = _ttlUntil;
    if (until != null) {
      return '${formatDayTimeJa(dateTimeFromEpoch(until), now: dateTimeFromEpoch(_c.now))} まで';
    }
    return '${formatDurationJa(_ttl)}（${formatDayTimeJa(dateTimeFromEpoch(_c.now + _ttl.inSeconds), now: dateTimeFromEpoch(_c.now))} まで）';
  }

  @override
  Widget build(BuildContext context) {
    final canSend =
        !_sending && _selectedGroups.isNotEmpty && _titleCtl.text.trim().isNotEmpty;
    final staffOrOfficial = _postsAsStaffOrOfficial;
    final templates = _category.titleTemplates;
    final caution = _category.caution;
    final ttlHint = _category.ttlHint;
    final banner = widget.prefill?.bannerText;
    return Scaffold(
      appBar: KairanAppBar(
        title: _isRewrite ? 'お知らせを 書きなおす' : 'お知らせを 書く',
        showBack: true,
      ),
      body: PageBody(
        bottom: PrimaryButton(
          label: _sending ? '送っています…' : '送る',
          onPressed: canSend ? _send : null,
        ),
        children: [
          if (_isRewrite) ...[
            const InfoBox('前の お知らせは 消えて、この 内容に 置き換わります。'),
            const SizedBox(height: 8),
          ],
          if (banner != null) ...[
            InfoBox(banner),
            const SizedBox(height: 8),
          ],
          if (_c.clockLooksWrong) ...[
            InfoBox(
              'この スマホの 時計が 合っていません（${formatDateTimeJa(dateTimeFromEpoch(_c.now))}）。時計を 直してから 送ってください。',
              title: '時計を 確かめてください',
              kind: InfoKind.danger,
            ),
            const SizedBox(height: 8),
            SecondaryButton(label: 'スマホの 設定を 開く', onPressed: _c.openAppSettings),
            const SizedBox(height: 8),
          ],
          if (_postable.isEmpty)
            const InfoBox(
              'お知らせを 出せる グループが ありません。本部コードか スタッフコードを 入れるか、投稿できる グループに 参加してください。',
              kind: InfoKind.caution,
            ),
          if (!_isRewrite && _postable.length > 1) ...[
            const SectionTitle('出す グループ（複数 選べます）'),
            ChoiceGrid(
              columns: 1,
              children: [
                for (final g in _postable)
                  ChoiceButton(
                    label: '${displayGroupName(g.name)}（${g.postRole.label}）',
                    selected: _selectedGroups.contains(g.code),
                    onPressed: () => _toggleGroup(g.code),
                  ),
              ],
            ),
          ] else if (_postable.length == 1) ...[
            const SectionTitle('出す グループ'),
            Text(
              '${displayGroupName(_postable.first.name)}（${_postable.first.postRole.label} として）',
              style: KairanTextStyles.body,
            ),
          ],
          if (staffOrOfficial && !_isRewrite) ...[
            const SizedBox(height: 8),
            Material(
              color: KairanColors.card,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(KairanSizes.radius)),
                side: BorderSide(color: KairanColors.borderDecorative),
              ),
              clipBehavior: Clip.antiAlias,
              child: SwitchListTile(
                value: _training,
                onChanged: _sending ? null : _setTraining,
                title: const Text('これは 訓練です'),
                subtitle: const Text('見出しに【訓練】が 付き、期限は 3時間に なります。'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              ),
            ),
          ],
          const SectionTitle('種別'),
          ChoiceGrid(
            children: [
              for (final category in NoticeCategory.values)
                ChoiceButton(
                  label: category.label,
                  selected: category == _category,
                  onPressed: () => _selectCategory(category),
                ),
            ],
          ),
          if (caution != null) ...[
            const SizedBox(height: 12),
            InfoBox(caution, kind: InfoKind.caution),
          ],
          if (templates.length > 1) ...[
            const SectionTitle('例文を 選ぶ'),
            ChoiceGrid(
              columns: 1,
              children: [
                for (var i = 0; i < templates.length; i++)
                  ChoiceButton(
                    label: templates[i],
                    selected: !_titleEdited && i == _templateIndex,
                    onPressed: () => _selectTemplate(i),
                  ),
              ],
            ),
          ],
          const SectionTitle('場所（なくても よい）'),
          TextField(
            controller: _placeCtl,
            maxLength: 40,
            textInputAction: TextInputAction.next,
            style: KairanTextStyles.body,
            decoration: const InputDecoration(hintText: '例: 〇〇小学校'),
            onChanged: (_) => setState(_applyTemplate),
          ),
          const SectionTitle('見出し（必ず 入れてください）'),
          TextField(
            controller: _titleCtl,
            maxLength: 40,
            maxLines: 2,
            minLines: 1,
            textInputAction: TextInputAction.next,
            style: KairanTextStyles.body,
            decoration: const InputDecoration(
              helperText: '{ } の ところは 書きかえてください。',
            ),
            onChanged: _onTitleChanged,
          ),
          const SectionTitle('本文（なくても よい）'),
          TextField(
            controller: _textCtl,
            maxLength: 1000,
            minLines: 4,
            maxLines: 10,
            keyboardType: TextInputType.multiline,
            style: KairanTextStyles.body,
            decoration: InputDecoration(
              hintText: '例: ${_category.bodyHint ?? '1人 2本まで。午後5時まで 配ります。'}',
            ),
          ),
          const SectionTitle('いつまで 表示しますか'),
          Text(
            '${_category.label}の 既定は ${formatDurationJa(_category.defaultTtl)}です。期限が 切れると 自動で 消えます。',
            style: KairanTextStyles.metaSecondary,
          ),
          const SizedBox(height: 8),
          ChoiceGrid(
            children: [
              for (final ttl in kTtlChoices)
                if (ttl < const Duration(days: 30) || staffOrOfficial)
                  ChoiceButton(
                    label: formatDurationJa(ttl),
                    selected: _ttlUntil == null && ttl == _ttl,
                    onPressed: () => setState(() {
                      _ttl = ttl;
                      _ttlUntil = null;
                    }),
                  ),
              ChoiceButton(
                label: '時刻を 決める',
                selected: _ttlUntil != null,
                onPressed: _pickEndTime,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text('表示は ${_ttlLabel()}', style: KairanTextStyles.meta),
          if (ttlHint != null) ...[
            const SizedBox(height: 4),
            Text(ttlHint, style: KairanTextStyles.metaSecondary),
          ],
          if (_ttlUntil == null && _ttl >= const Duration(days: 7)) ...[
            const SizedBox(height: 4),
            const Text(
              '長く 残ります。人の 名前や 住所は 書かないでください',
              style: KairanTextStyles.metaSecondary,
            ),
          ],
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

/// 「今日 / あした」→「午前6時〜午後10時」の 2 段で終わる時刻を選ぶ（C02）。
class _EndTimeDialog extends StatefulWidget {
  const _EndTimeDialog({required this.now});

  final DateTime now;

  @override
  State<_EndTimeDialog> createState() => _EndTimeDialogState();
}

class _EndTimeDialogState extends State<_EndTimeDialog> {
  bool _tomorrow = false;

  @override
  Widget build(BuildContext context) {
    final base = DateTime(widget.now.year, widget.now.month, widget.now.day)
        .add(Duration(days: _tomorrow ? 1 : 0));
    final hours = <int>[for (var h = 6; h <= 22; h++) h];
    return AlertDialog(
      title: const Text('いつまで 表示しますか'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ChoiceGrid(
                children: [
                  ChoiceButton(
                    label: '今日',
                    selected: !_tomorrow,
                    onPressed: () => setState(() => _tomorrow = false),
                  ),
                  ChoiceButton(
                    label: 'あした',
                    selected: _tomorrow,
                    onPressed: () => setState(() => _tomorrow = true),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ChoiceGrid(
                children: [
                  for (final h in hours)
                    ChoiceButton(
                      label: formatEndTimeJa(base.add(Duration(hours: h))),
                      selected: false,
                      onPressed: () =>
                          Navigator.of(context).pop(base.add(Duration(hours: h))),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('やめる'),
        ),
      ],
    );
  }
}
