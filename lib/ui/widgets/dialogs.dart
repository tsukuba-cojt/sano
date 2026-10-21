/// 確認ダイアログ・お知らせダイアログ・スナックバーの共通呼び出し。
library;

import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// 確認ダイアログ。[confirmLabel] を押すと true、それ以外は false。
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'やめる',
  bool danger = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: Text(title),
        content: Text(message),
        actionsAlignment: MainAxisAlignment.end,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(cancelLabel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: danger
                ? const ButtonStyle(
                    foregroundColor: WidgetStatePropertyAll(
                      KairanColors.dangerText,
                    ),
                  )
                : null,
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return result ?? false;
}

/// 結果を知らせるダイアログ（ボタン 1 つ）。
Future<void> showMessageDialog(
  BuildContext context, {
  required String title,
  required String message,
  String buttonLabel = 'とじる',
}) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(buttonLabel),
          ),
        ],
      );
    },
  );
}

/// 下部に短い知らせを出す。
void showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 4),
      ),
    );
}

/// 例外を人に読める 1 文にする。
String describeError(Object error) {
  final text = error.toString();
  if (text.isEmpty) {
    return 'エラーが 起きました。';
  }
  return text;
}
