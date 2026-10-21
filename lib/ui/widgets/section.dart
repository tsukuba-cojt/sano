/// 画面内の小さな部品: 節見出し・案内枠・ラベルと値の行・画面の余白。
library;

import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// 節の見出し（18 Bold）。
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 8),
        child: Text(text, style: KairanTextStyles.sectionTitle),
      ),
    );
  }
}

/// 案内の種類。
enum InfoKind { plain, caution, danger, success }

/// 枠付きの案内文（注意は橙枠、危険は赤枠、完了は緑枠）。
class InfoBox extends StatelessWidget {
  const InfoBox(this.text, {super.key, this.kind = InfoKind.plain, this.title});

  final String text;
  final InfoKind kind;
  final String? title;

  Color get _border {
    switch (kind) {
      case InfoKind.plain:
        return KairanColors.border;
      case InfoKind.caution:
        return KairanColors.caution;
      case InfoKind.danger:
        return KairanColors.danger;
      case InfoKind.success:
        return KairanColors.success;
    }
  }

  Color get _titleColor {
    switch (kind) {
      case InfoKind.plain:
        return KairanColors.text;
      case InfoKind.caution:
        return KairanColors.caution;
      case InfoKind.danger:
        return KairanColors.dangerText;
      case InfoKind.success:
        return KairanColors.success;
    }
  }

  @override
  Widget build(BuildContext context) {
    final titleText = title;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: KairanColors.card,
        border: Border.all(color: _border, width: 2),
        borderRadius: const BorderRadius.all(
          Radius.circular(KairanSizes.radius),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (titleText != null) ...[
            Text(
              titleText,
              style: KairanTextStyles.sectionTitle.copyWith(color: _titleColor),
            ),
            const SizedBox(height: 4),
          ],
          Text(text, style: KairanTextStyles.body),
        ],
      ),
    );
  }
}

/// 「ラベル: 値」の 1 行（診断画面・詳細画面）。
class LabelValueRow extends StatelessWidget {
  const LabelValueRow(this.label, this.value, {super.key, this.selectable = false});

  final String label;
  final String value;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 132,
            child: Text(label, style: KairanTextStyles.metaSecondary),
          ),
          const SizedBox(width: KairanSizes.gap),
          Expanded(
            child: selectable
                ? SelectableText(value, style: KairanTextStyles.body)
                : Text(value, style: KairanTextStyles.body),
          ),
        ],
      ),
    );
  }
}

/// 画面本体の標準余白付きスクロール領域。
class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.children, this.bottom});

  final List<Widget> children;

  /// 画面下に固定する主ボタンなど。
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    final list = ListView(
      padding: const EdgeInsets.fromLTRB(
        KairanSizes.pagePadding,
        KairanSizes.pagePadding,
        KairanSizes.pagePadding,
        24,
      ),
      children: children,
    );
    final bottomWidget = bottom;
    if (bottomWidget == null) {
      return list;
    }
    return Column(
      children: [
        Expanded(child: list),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              KairanSizes.pagePadding,
              8,
              KairanSizes.pagePadding,
              12,
            ),
            child: bottomWidget,
          ),
        ),
      ],
    );
  }
}

/// 白いカード枠。
class CardBox extends StatelessWidget {
  const CardBox({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        color: KairanColors.card,
        border: Border.fromBorderSide(
          BorderSide(color: KairanColors.borderDecorative),
        ),
        borderRadius: BorderRadius.all(Radius.circular(KairanSizes.radius)),
      ),
      child: child,
    );
  }
}
