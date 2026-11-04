/// 開発者メニュー（実機テスト用のデータを入れる、#152）。
///
/// 設定画面の「バージョン」を 7 回 押すと出る。入れるのはテスト仕様書の TD1〜TD5。
library;

import 'package:flutter/material.dart';
import 'package:kairanban/app/app_controller.dart';
import 'package:kairanban/app/test_data.dart';
import 'package:kairanban/core/report.dart';

import '../../app/theme.dart';
import '../format.dart';
import '../routes.dart';
import '../widgets/big_button.dart';
import '../widgets/dialogs.dart';
import '../widgets/kairan_app_bar.dart';
import '../widgets/section.dart';

class DeveloperScreen extends StatefulWidget {
  const DeveloperScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<DeveloperScreen> createState() => _DeveloperScreenState();
}

class _DeveloperScreenState extends State<DeveloperScreen> {
  late final Listenable _listenable;
  int? _groupCode;
  bool _busy = false;

  AppController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _listenable = Listenable.merge([_c, _c.store, _c.groups]);
  }

  Future<void> _add(String label, Future<int> Function(int code) action) async {
    final code = _groupCode;
    if (_busy || code == null) {
      return;
    }
    setState(() => _busy = true);
    final watch = Stopwatch()..start();
    try {
      final added = await action(code);
      if (mounted) {
        showSnack(
          context,
          '$label: ${formatCountJa(added, '件')} 入れました'
          '（${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} 秒）',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _remove() async {
    final count = _c.testDataCount;
    if (_busy || count == 0) {
      return;
    }
    final ok = await showConfirmDialog(
      context,
      title: 'テストデータを 消しますか',
      message: 'この端末から ${formatCountJa(count, '件')} 消します。'
          'ほかの 端末に 渡した 分は 残ります。',
      confirmLabel: '消す',
      danger: true,
    );
    if (!ok || !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      final removed = await _c.removeTestData();
      if (mounted) {
        showSnack(context, '${formatCountJa(removed, '件')} 消しました');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _hide() async {
    await _c.setDeveloperMode(false);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const KairanAppBar(title: '開発者メニュー', showBack: true),
      body: ListenableBuilder(
        listenable: _listenable,
        builder: (context, _) {
          final groups = _c.groups.groups;
          if (_groupCode == null || !groups.any((g) => g.code == _groupCode)) {
            _groupCode = groups.isEmpty ? null : groups.first.code;
          }
          final store = _c.store;
          final room = store.maxMessages - store.count;
          final enabled = !_busy && _groupCode != null;
          return PageBody(
            children: [
              const InfoBox(
                '実機テスト用の データを 入れます（テスト仕様書の TD1〜TD5）。'
                '見出しに「$kTestTitlePrefix」が 付き、通知は 出ません。'
                '近くの 端末にも 渡るので、テストに 使う 端末だけで 使ってください。',
                kind: InfoKind.caution,
              ),
              const SectionTitle('保存'),
              CardBox(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LabelValueRow(
                      '保存件数',
                      '${formatCountJa(store.count, '件')}'
                          '（上限 ${formatCountJa(store.maxMessages, '件')}）',
                    ),
                    LabelValueRow(
                      'テストデータ',
                      formatCountJa(_c.testDataCount, '件'),
                    ),
                  ],
                ),
              ),
              const SectionTitle('入れる グループ'),
              if (groups.isEmpty)
                const Text(
                  '先に グループに 参加してください。',
                  style: KairanTextStyles.body,
                )
              else
                ChoiceGrid(
                  children: [
                    for (final g in groups)
                      ChoiceButton(
                        label: displayGroupName(g.name),
                        selected: g.code == _groupCode,
                        onPressed: _busy
                            ? null
                            : () => setState(() => _groupCode = g.code),
                      ),
                  ],
                ),
              const SectionTitle('お知らせ'),
              SecondaryButton(
                label: '30 件（TD1 普段の 差分）',
                onPressed: enabled
                    ? () => _add('お知らせ', (code) => _c.addTestNotices(
                          groupCode: code,
                          count: 30,
                        ))
                    : null,
              ),
              const SizedBox(height: 8),
              SecondaryButton(
                label: '300 件（TD2）',
                onPressed: enabled
                    ? () => _add('お知らせ', (code) => _c.addTestNotices(
                          groupCode: code,
                          count: 300,
                        ))
                    : null,
              ),
              const SizedBox(height: 8),
              SecondaryButton(
                label: '1,500 件（TD3 ばらばらの 文字）',
                onPressed: enabled
                    ? () => _add('お知らせ', (code) => _c.addTestNotices(
                          groupCode: code,
                          count: 1500,
                          body: TestBody.noise,
                        ))
                    : null,
              ),
              const SizedBox(height: 8),
              SecondaryButton(
                label: '上限まで 埋める（TD4、あと ${formatCountJa(room < 0 ? 0 : room, '件')}）',
                onPressed: enabled && room > 0
                    ? () => _add('お知らせ',
                        (code) => _c.fillTestNotices(groupCode: code))
                    : null,
              ),
              const SectionTitle('住民からの 知らせ'),
              SecondaryButton(
                label: '無事です 100 件（TD5）',
                onPressed: enabled
                    ? () => _add('無事です', (code) => _c.addTestReports(
                          groupCode: code,
                          count: 100,
                        ))
                    : null,
              ),
              const SizedBox(height: 8),
              SecondaryButton(
                label: 'SOS 20 件',
                onPressed: enabled
                    ? () => _add('SOS', (code) => _c.addTestReports(
                          groupCode: code,
                          count: 20,
                          type: ReportType.sos,
                        ))
                    : null,
              ),
              const SizedBox(height: 4),
              const Text(
                '通知の 確かめには、各端末の「本部に 知らせる」から 本物の SOS を 送ってください。',
                style: KairanTextStyles.metaSecondary,
              ),
              const SectionTitle('片付け'),
              SecondaryButton(
                label: 'テストデータを この端末から 消す',
                icon: Icons.delete_outline,
                onPressed: !_busy && _c.testDataCount > 0 ? _remove : null,
              ),
              const SizedBox(height: 8),
              SecondaryButton(
                label: '交換の 記録（量と 秒数）を 見る',
                onPressed: () => openDiagnostics(context, _c),
              ),
              const SizedBox(height: 8),
              SecondaryButton(
                label: '開発者メニューを 隠す',
                onPressed: _busy ? null : _hide,
              ),
              const SizedBox(height: 16),
            ],
          );
        },
      ),
    );
  }
}
