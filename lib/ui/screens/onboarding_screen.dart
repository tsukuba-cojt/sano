/// はじめに（初回のみ、5 ステップ。文言は docs/08 C06 C07 C11）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:kairanban/app/app_controller.dart';

import '../../app/theme.dart';
import '../widgets/big_button.dart';
import '../widgets/dialogs.dart';
import '../widgets/kairan_app_bar.dart';
import '../widgets/section.dart';
import 'settings_screen.dart' show kThingsToKnow;

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.controller,
    required this.onFinished,
  });

  final AppController controller;

  /// 「はじめる」が完了したら呼ぶ。
  final VoidCallback onFinished;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  static const int _stepCount = 5;

  /// 各ステップの番号（0 始まり）。
  static const int _stepIntro = 0;
  static const int _stepBluetooth = 1;
  static const int _stepNotification = 2;
  static const int _stepRequests = 3;
  static const int _stepName = 4;

  int _step = _stepIntro;

  /// null = まだ要求していない。
  bool? _permissionGranted;
  bool _requesting = false;

  /// 通知の許可。null = まだ要求していない。
  bool? _notificationGranted;
  bool _requestingNotification = false;

  bool _starting = false;
  final _nameCtl = TextEditingController();

  AppController get _c => widget.controller;

  @override
  void dispose() {
    _nameCtl.dispose();
    super.dispose();
  }

  void _next() {
    if (_step < _stepCount - 1) {
      setState(() => _step++);
    }
  }

  void _back() {
    if (_step > 0) {
      setState(() => _step--);
    }
  }

  Future<void> _requestPermission() async {
    if (_requesting) {
      return;
    }
    setState(() => _requesting = true);
    bool granted;
    try {
      granted = await _c.requestPermissions();
    } catch (_) {
      granted = false;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _requesting = false;
      _permissionGranted = granted;
    });
  }

  Future<void> _requestNotificationPermission() async {
    if (_requestingNotification) {
      return;
    }
    setState(() => _requestingNotification = true);
    bool granted;
    try {
      granted = await _c.requestNotificationPermission();
    } catch (_) {
      granted = false;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _requestingNotification = false;
      _notificationGranted = granted;
    });
  }

  Future<void> _openSettings() async {
    try {
      await _c.openAppSettings();
    } catch (e) {
      if (!mounted) {
        return;
      }
      await showMessageDialog(
        context,
        title: '開けませんでした',
        message: describeError(e),
      );
    }
  }

  Future<void> _start() async {
    if (_starting) {
      return;
    }
    setState(() => _starting = true);
    final name = _nameCtl.text.trim();
    try {
      final s = _c.settings;
      s.displayName = name.isEmpty ? '名前なし' : name;
      s.onboardingDone = true;
      await _c.saveSettings(s);
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() => _starting = false);
      await showMessageDialog(
        context,
        title: '保存できませんでした',
        message: describeError(e),
      );
      return;
    }
    try {
      await _c.startMesh();
    } catch (_) {
      // 通信は設定画面から改めて始められるので、ここでは止めない。
    }
    if (!mounted) {
      return;
    }
    widget.onFinished();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: KairanAppBar(
        title: 'はじめに',
        showBack: _step > 0,
        onBack: _back,
      ),
      body: PageBody(
        bottom: _stepButtons(),
        children: [
          Semantics(
            label: '${_step + 1}番目の 説明、全部で $_stepCount つ',
            child: ExcludeSemantics(
              child: Text(
                '${_step + 1} / $_stepCount',
                style: KairanTextStyles.metaSecondary,
              ),
            ),
          ),
          const SizedBox(height: 12),
          ..._stepContent(),
        ],
      ),
    );
  }

  List<Widget> _stepContent() {
    switch (_step) {
      case _stepIntro:
        return const [
          Text('回覧板', style: KairanTextStyles.screenTitle),
          SizedBox(height: 16),
          Text(
            'このアプリは、近くのスマホと Bluetooth で お知らせを 交換します。インターネットは 使いません。届くまで 時間が かかるので、避難の 呼びかけは 防災無線や ラジオでも 確かめてください。',
            style: KairanTextStyles.body,
          ),
          SizedBox(height: 16),
          Text(
            '紙の 回覧板が 隣の 家に 回るように、すれ違った スマホに お知らせが 広がります。',
            style: KairanTextStyles.body,
          ),
        ];
      case _stepBluetooth:
        final granted = _permissionGranted;
        return [
          const Text('Bluetooth を 使います', style: KairanTextStyles.screenTitle),
          const SizedBox(height: 16),
          const Text(
            'お知らせを 交換するために、Bluetooth の 許可が 必要です。ボタンを 押すと、スマホが 許可を 聞いてきます。',
            style: KairanTextStyles.body,
          ),
          const SizedBox(height: 16),
          if (granted == true)
            const InfoBox('Bluetooth が 許可されました。', kind: InfoKind.success)
          else if (granted == false) ...[
            const InfoBox(
              '許可されませんでした。あとから スマホの 設定で 許可できます。',
              kind: InfoKind.danger,
            ),
            const SizedBox(height: 8),
            SecondaryButton(label: 'スマホの 設定を 開く', onPressed: _openSettings),
          ],
        ];
      case _stepNotification:
        final granted = _notificationGranted;
        return [
          const Text('お知らせが 届いたら 知らせる', style: KairanTextStyles.screenTitle),
          const SizedBox(height: 16),
          const Text(
            '新しい お知らせが 届いたら、アプリを 閉じていても スマホの 通知で 知らせます。ふだんは 公式と 大事なものだけ 知らせます。ボタンを 押すと、スマホが 許可を 聞いてきます。',
            style: KairanTextStyles.body,
          ),
          const SizedBox(height: 16),
          if (granted == true)
            const InfoBox('通知が 許可されました。', kind: InfoKind.success)
          else if (granted == false) ...[
            const InfoBox(
              '許可されませんでした。あとから スマホの 設定で 許可できます。',
              kind: InfoKind.danger,
            ),
            const SizedBox(height: 8),
            SecondaryButton(label: 'スマホの 設定を 開く', onPressed: _openSettings),
          ],
        ];
      case _stepRequests:
        final isIos = defaultTargetPlatform == TargetPlatform.iOS;
        return [
          const Text('お願い', style: KairanTextStyles.screenTitle),
          const SizedBox(height: 16),
          const _NumberedItem(1, 'アプリを 上に スワイプして 終了しないでください。'),
          const _NumberedItem(2, 'Bluetooth を 切らないでください。'),
          const _NumberedItem(3, '電池が 少なくなると、ゆっくり 交換します。'),
          const _NumberedItem(
            4,
            '出かけるときは、スマホを カバンの 中ではなく、画面を 点けて 手に 持つと 届きやすく なります。',
          ),
          if (isIos)
            const _NumberedItem(5, '電池が 切れて 充電したら、アプリを 一度 開いてください。'),
          const SizedBox(height: 16),
          const Text('知っておいて ほしいこと', style: KairanTextStyles.sectionTitle),
          const SizedBox(height: 8),
          for (final line in kThingsToKnow.take(3)) _BulletItem(line),
        ];
      default:
        return [
          const Text('表示名', style: KairanTextStyles.screenTitle),
          const SizedBox(height: 16),
          const Text(
            'お知らせを 出すときに 表示される 名前です。入れなくても 使えます。本名で なくて かまいません。役割が 分かる 名前を おすすめします（例: 3班 佐藤、〇〇小学校 受付）。',
            style: KairanTextStyles.body,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _nameCtl,
            maxLength: 16,
            textInputAction: TextInputAction.done,
            style: KairanTextStyles.body,
            enabled: !_starting,
            decoration: const InputDecoration(
              labelText: '表示名',
              hintText: '名前なし',
            ),
          ),
        ];
    }
  }

  Widget _stepButtons() {
    switch (_step) {
      case _stepIntro:
      case _stepRequests:
        return PrimaryButton(label: 'つぎへ', onPressed: _next);
      case _stepBluetooth:
        if (_permissionGranted == true) {
          return PrimaryButton(label: 'つぎへ', onPressed: _next);
        }
        return _permissionButtons(
          label: _requesting ? '許可を 聞いています…' : 'Bluetooth を 許可する',
          busy: _requesting,
          onPressed: _requestPermission,
        );
      case _stepNotification:
        if (_notificationGranted == true) {
          return PrimaryButton(label: 'つぎへ', onPressed: _next);
        }
        return _permissionButtons(
          label: _requestingNotification ? '許可を 聞いています…' : '通知を 許可する',
          busy: _requestingNotification,
          onPressed: _requestNotificationPermission,
        );
      case _stepName:
      default:
        return PrimaryButton(
          label: _starting ? '準備しています…' : 'はじめる',
          onPressed: _starting ? null : _start,
        );
    }
  }

  /// 「許可する」主ボタンと「あとで 許可する」（スキップ）の組。
  Widget _permissionButtons({
    required String label,
    required bool busy,
    required VoidCallback onPressed,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PrimaryButton(
          label: label,
          onPressed: busy ? null : onPressed,
        ),
        const SizedBox(height: KairanSizes.gap),
        TextButton(
          onPressed: busy ? null : _next,
          child: const Text('あとで 許可する'),
        ),
      ],
    );
  }
}

class _NumberedItem extends StatelessWidget {
  const _NumberedItem(this.number, this.text);

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 32,
            child: Text(
              '$number.',
              style: KairanTextStyles.body.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(child: Text(text, style: KairanTextStyles.body)),
        ],
      ),
    );
  }
}

class _BulletItem extends StatelessWidget {
  const _BulletItem(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('・', style: KairanTextStyles.body),
          Expanded(child: Text(text, style: KairanTextStyles.body)),
        ],
      ),
    );
  }
}
