/// グループに参加する画面（6 桁の参加コード入力、docs/08 C22）。
///
/// [AppController] に依存せず、必要な操作をコールバックで受け取る
/// （テストで差し替えられるようにするため）。結線は `lib/ui/routes.dart`。
library;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../format.dart';
import '../widgets/big_button.dart';
import '../widgets/dialogs.dart';
import '../widgets/kairan_app_bar.dart';
import '../widgets/section.dart';
import '../widgets/six_digit_input.dart';

/// 近くで流れている（未参加の）グループ 1 件。
class NearbyGroup {
  const NearbyGroup({
    required this.code,
    required this.name,
    required this.hostName,
    this.description = '',
    required this.receivedAt,
  });

  final int code;
  final String name;
  final String hostName;
  final String description;
  final DateTime receivedAt;
}

class JoinScreen extends StatefulWidget {
  const JoinScreen({
    super.key,
    required this.lookupName,
    required this.isJoined,
    required this.onJoin,
    this.nearbyGroups,
    this.listenable,
  });

  /// 近隣から受け取ったグループ名（未受信なら null）。
  final String? Function(int code) lookupName;

  /// すでに参加しているか。
  final bool Function(int code) isJoined;

  /// 参加処理。失敗は例外で知らせる。
  final Future<void> Function(int code) onJoin;

  /// 近くで流れているグループ（最大 3 件、新しい順）。null なら機能を出さない。
  final List<NearbyGroup> Function()? nearbyGroups;

  /// 変化を監視する対象（グループ情報が届いたら名前を出し直す）。
  final Listenable? listenable;

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  String _code = '';
  bool _busy = false;
  bool _showNearby = false;

  bool get _complete => _code.length == SixDigitInput.length;

  int? get _codeValue => _complete ? int.tryParse(_code) : null;

  Future<void> _join(int code) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.onJoin(code);
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      await showMessageDialog(
        context,
        title: '参加できませんでした',
        message: describeError(e),
      );
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    final name = widget.lookupName(code);
    await showMessageDialog(
      context,
      title: '参加しました',
      message: name == null
          ? '参加コード ${formatGroupCode(code)} の グループに 参加しました。お知らせが 届くように なります。参加する 前に 届いていた お知らせも 見られます。'
          : '「$name」に 参加しました。お知らせが 届くように なります。参加する 前に 届いていた お知らせも 見られます。',
    );
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop(true);
  }

  Future<void> _joinNearby(NearbyGroup g) async {
    final ok = await showConfirmDialog(
      context,
      title: 'この グループに 参加しますか？',
      message: '「${g.name}」（参加コード ${formatGroupCode(g.code)}）に 参加します。市の 広報紙や 係の人の 番号と 同じか 確かめてください。',
      confirmLabel: '参加する',
    );
    if (!ok || !mounted) {
      return;
    }
    await _join(g.code);
  }

  Widget _buildNameArea() {
    final code = _codeValue;
    if (code == null) {
      return const SizedBox.shrink();
    }
    if (widget.isJoined(code)) {
      return const InfoBox(
        'この グループには もう 参加しています。',
        kind: InfoKind.caution,
      );
    }
    final name = widget.lookupName(code);
    if (name == null) {
      return const InfoBox(
        '近くの スマホから 名前が まだ 届いていません。そのまま 参加できます。名前は あとで 届きます。',
      );
    }
    return InfoBox(name, title: 'グループ名', kind: InfoKind.success);
  }

  Widget _buildNearby() {
    final provider = widget.nearbyGroups;
    if (provider == null || !_showNearby) {
      return const SizedBox.shrink();
    }
    final groups = provider();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionTitle('近くで 流れている グループ'),
        if (groups.isEmpty)
          const InfoBox('近くの スマホから グループの 名前が 届くと ここに 出ます。')
        else
          for (final g in groups)
            Padding(
              padding: const EdgeInsets.only(bottom: KairanSizes.gap),
              child: Semantics(
                button: true,
                label: '${g.name}、作った人 ${g.hostName}、参加コード ${formatGroupCode(g.code)}',
                onTap: _busy ? null : () => _joinNearby(g),
                child: ExcludeSemantics(
                  child: Material(
                    color: KairanColors.card,
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(KairanSizes.radius)),
                      side: BorderSide(color: KairanColors.borderDecorative),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: _busy ? null : () => _joinNearby(g),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(g.name, style: KairanTextStyles.noticeTitle),
                            Text('作った人: ${g.hostName} ・ 参加コード ${formatGroupCode(g.code)}',
                                style: KairanTextStyles.meta),
                            if (g.description.trim().isNotEmpty)
                              Text('問い合わせ先: ${g.description}', style: KairanTextStyles.meta),
                            Text(
                              '${formatRelativeJa(DateTime.now().difference(g.receivedAt))}に 受け取りました',
                              style: KairanTextStyles.metaSecondary,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        const Text(
          '同じ 名前が 2つ あるときは 係の人に 確かめてください。',
          style: KairanTextStyles.metaSecondary,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final listenable = widget.listenable;
    final nameArea = listenable == null
        ? _buildNameArea()
        : ListenableBuilder(
            listenable: listenable,
            builder: (context, _) => _buildNameArea(),
          );
    final nearby = listenable == null
        ? _buildNearby()
        : ListenableBuilder(
            listenable: listenable,
            builder: (context, _) => _buildNearby(),
          );
    final code = _codeValue;
    final canJoin = code != null && !_busy && !widget.isJoined(code);
    return Scaffold(
      appBar: const KairanAppBar(title: '参加する', showBack: true),
      body: PageBody(
        bottom: PrimaryButton(
          label: _busy ? '参加しています…' : '参加する',
          onPressed: canJoin ? () => _join(code) : null,
        ),
        children: [
          const Text(
            'グループの 6桁の 番号を 入れてください。',
            style: KairanTextStyles.body,
          ),
          const SizedBox(height: 16),
          SixDigitInput(
            onChanged: (value) => setState(() => _code = value),
          ),
          const SizedBox(height: 16),
          nameArea,
          const SizedBox(height: 16),
          const Text(
            '番号は、市の 広報紙・ホームページ・町内会の 案内に 載っています。同じ 番号か 確かめてください。',
            style: KairanTextStyles.metaSecondary,
          ),
          if (widget.nearbyGroups != null) ...[
            const SizedBox(height: 16),
            SecondaryButton(
              label: _showNearby ? '近くの グループを 閉じる' : '番号が 分かりません',
              onPressed: () => setState(() => _showNearby = !_showNearby),
            ),
            nearby,
          ],
        ],
      ),
    );
  }
}
