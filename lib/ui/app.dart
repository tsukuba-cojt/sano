/// アプリのルートウィジェット。
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:kairanban/app/app_controller.dart';

import '../app/theme.dart';
import 'screens/onboarding_screen.dart';
import 'screens/shell_screen.dart';

/// 回覧板アプリ。
///
/// - テーマはライトのみ（ダークも同じ見た目）。
/// - 設定の「文字の大きさ」を OS の拡大設定に乗じて [MediaQuery] に流す。
/// - 初回は「はじめに」、以後は下部タブの画面を表示する。
/// - アプリが前面かどうか（[AppLifecycleState.resumed]）を [AppController.setForeground] に
///   伝える。前面のときは OS 通知を出さず、画面の「新しい お知らせが N 件」に任せる。
class KairanApp extends StatefulWidget {
  const KairanApp(this.controller, {super.key});

  final AppController controller;

  @override
  State<KairanApp> createState() => _KairanAppState();
}

class _KairanAppState extends State<KairanApp> with WidgetsBindingObserver {
  late bool _onboardingDone = widget.controller.settings.onboardingDone;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 登録前に起きた状態変化は届かないので、現在の状態で初期化する。
    // null（まだ分からない）は背面扱いにし、resumed が来たら前面にする。
    widget.controller.setForeground(
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.controller.setForeground(state == AppLifecycleState.resumed);
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final theme = buildKairanTheme();
    return MaterialApp(
      title: '回覧板',
      debugShowCheckedModeBanner: false,
      theme: theme,
      darkTheme: theme,
      themeMode: ThemeMode.light,
      locale: const Locale('ja'),
      supportedLocales: const [Locale('ja')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) {
        return ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final scaler = KairanTextScale.combine(
              MediaQuery.textScalerOf(context),
              controller.settings.textScale,
            );
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: scaler),
              child: child ?? const SizedBox.shrink(),
            );
          },
        );
      },
      home: _onboardingDone
          ? ShellScreen(controller: controller)
          : OnboardingScreen(
              controller: controller,
              onFinished: () => setState(() => _onboardingDone = true),
            ),
    );
  }
}

/// 起動に失敗したときに出す画面（原因と、やり直し方を示す）。
class KairanStartupErrorApp extends StatelessWidget {
  const KairanStartupErrorApp({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '回覧板',
      debugShowCheckedModeBanner: false,
      theme: buildKairanTheme(),
      locale: const Locale('ja'),
      supportedLocales: const [Locale('ja')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(
        appBar: AppBar(title: const Text('回覧板')),
        body: ListView(
          padding: const EdgeInsets.all(KairanSizes.pagePadding),
          children: [
            const Text('起動できませんでした', style: KairanTextStyles.screenTitle),
            const SizedBox(height: 16),
            const Text(
              'アプリを いちど 閉じて、もう一度 開いてください。それでも 直らないときは、下の 内容を スタッフに 伝えてください。',
              style: KairanTextStyles.body,
            ),
            const SizedBox(height: 16),
            SelectableText(message, style: KairanTextStyles.meta),
          ],
        ),
      ),
    );
  }
}
