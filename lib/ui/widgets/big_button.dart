/// 高さ 56・幅いっぱいの主ボタン / 副ボタン / 選択ボタン。
library;

import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// 主ボタン（青地白文字）。1 画面に 1 つだけ置く。
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;

  /// null なら無効表示。
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onPressed,
        child: _ButtonLabel(label: label, icon: icon),
      ),
    );
  }
}

/// 副ボタン（白地青枠青文字）。[danger] で赤枠赤文字（取り消し・抜ける）。
class SecondaryButton extends StatelessWidget {
  const SecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.danger = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    ButtonStyle? style;
    if (danger) {
      style = ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return KairanColors.disabled;
          }
          return KairanColors.dangerText;
        }),
        side: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return const BorderSide(color: KairanColors.disabled, width: 2);
          }
          return const BorderSide(color: KairanColors.danger, width: 2);
        }),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.pressed)) {
            return const Color(0xFFFFE0E0);
          }
          return KairanColors.card;
        }),
      );
    }
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: onPressed,
        style: style,
        child: _ButtonLabel(label: label, icon: icon),
      ),
    );
  }
}

/// 選択肢ボタン（種別・有効期限・文字の大きさなど）。
///
/// 選択中は薄い青地に青枠、チェック印付き。主ボタンと見分けがつくようにする。
class ChoiceButton extends StatelessWidget {
  const ChoiceButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final style = ButtonStyle(
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return KairanColors.disabled;
        }
        return selected ? KairanColors.primary : KairanColors.text;
      }),
      side: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return const BorderSide(color: KairanColors.disabled, width: 2);
        }
        return selected
            ? const BorderSide(color: KairanColors.primary, width: 3)
            : const BorderSide(color: KairanColors.border, width: 1);
      }),
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (selected || states.contains(WidgetState.pressed)) {
          return KairanColors.selectedFill;
        }
        return KairanColors.card;
      }),
      textStyle: WidgetStatePropertyAll(
        KairanTextStyles.button.copyWith(
          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    );
    return Semantics(
      selected: selected,
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          onPressed: onPressed,
          style: style,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (selected) ...[
                const Icon(Icons.check, size: 24),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(label, textAlign: TextAlign.center, softWrap: true),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 選択肢を 2 列に並べる（最後が奇数なら 1 列分の空きを置く）。
class ChoiceGrid extends StatelessWidget {
  const ChoiceGrid({super.key, required this.children, this.columns = 2});

  final List<Widget> children;
  final int columns;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += columns) {
      final cells = <Widget>[];
      for (var c = 0; c < columns; c++) {
        if (c > 0) {
          cells.add(const SizedBox(width: KairanSizes.gap));
        }
        final index = i + c;
        cells.add(
          Expanded(
            child: index < children.length
                ? children[index]
                : const SizedBox.shrink(),
          ),
        );
      }
      if (rows.isNotEmpty) {
        rows.add(const SizedBox(height: KairanSizes.gap));
      }
      rows.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: cells,
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }
}

class _ButtonLabel extends StatelessWidget {
  const _ButtonLabel({required this.label, this.icon});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    if (icon == null) {
      return Text(label, textAlign: TextAlign.center, softWrap: true);
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 24),
        const SizedBox(width: 8),
        Flexible(
          child: Text(label, textAlign: TextAlign.center, softWrap: true),
        ),
      ],
    );
  }
}
