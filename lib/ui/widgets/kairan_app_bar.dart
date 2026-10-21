/// ヘッダ。サブ画面では左に「＜ もどる」の文字付きボタンを置く。
library;

import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// アプリ共通の [AppBar]。
///
/// [showBack] が true なら「＜ もどる」を表示する（アイコンだけの戻るは使わない）。
class KairanAppBar extends StatelessWidget implements PreferredSizeWidget {
  const KairanAppBar({
    super.key,
    required this.title,
    this.showBack = false,
    this.onBack,
    this.actions,
  });

  final String title;
  final bool showBack;

  /// 省略時は [Navigator.maybePop]。
  final VoidCallback? onBack;
  final List<Widget>? actions;

  static const double _backWidth = 136;

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      automaticallyImplyLeading: false,
      leadingWidth: showBack ? _backWidth : null,
      leading: showBack ? BackTextButton(onPressed: onBack) : null,
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: actions,
    );
  }
}

/// 「＜ もどる」ボタン（白文字、タップ領域 48 以上）。
class BackTextButton extends StatelessWidget {
  const BackTextButton({super.key, this.onPressed, this.label = 'もどる'});

  final VoidCallback? onPressed;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          onPressed: onPressed ?? () => Navigator.of(context).maybePop(),
          style: const ButtonStyle(
            foregroundColor: WidgetStatePropertyAll(KairanColors.card),
            minimumSize: WidgetStatePropertyAll(Size(48, 48)),
            padding: WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            ),
          ),
          child: Text(
            '＜ $label',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            softWrap: false,
          ),
        ),
      ),
    );
  }
}
