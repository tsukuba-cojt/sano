/// 種別タグ・役割バッジ・新着タグ・訓練タグ・赤帯。
library;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/envelope.dart';

/// 種別タグ（例「物資」）。白地に灰枠、16 Bold。
class CategoryTag extends StatelessWidget {
  const CategoryTag(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return _TagBox(
      label: label,
      background: KairanColors.card,
      border: KairanColors.border,
      foreground: KairanColors.text,
    );
  }
}

/// 役割バッジ。公式は青地白文字、スタッフは白地青枠、住民は灰枠。
class RoleBadge extends StatelessWidget {
  const RoleBadge(this.role, {super.key});

  final SenderRole role;

  @override
  Widget build(BuildContext context) {
    switch (role) {
      case SenderRole.official:
        return _TagBox(
          label: role.label,
          background: KairanColors.primary,
          border: KairanColors.primary,
          foreground: KairanColors.card,
        );
      case SenderRole.staff:
        return _TagBox(
          label: role.label,
          background: KairanColors.card,
          border: KairanColors.primary,
          foreground: KairanColors.primary,
        );
      case SenderRole.resident:
        return _TagBox(
          label: role.label,
          background: KairanColors.card,
          border: KairanColors.border,
          foreground: KairanColors.textSecondary,
        );
    }
  }
}

/// 「新着」タグ（注意色）。
class NewTag extends StatelessWidget {
  const NewTag({super.key});

  @override
  Widget build(BuildContext context) {
    return const _TagBox(
      label: '新着',
      background: KairanColors.card,
      border: KairanColors.caution,
      foreground: KairanColors.caution,
    );
  }
}

/// 「訓練」タグ（注意色地・白文字、C23）。
class TrainingTag extends StatelessWidget {
  const TrainingTag({super.key});

  @override
  Widget build(BuildContext context) {
    return const _TagBox(
      label: '訓練',
      background: KairanColors.caution,
      border: KairanColors.caution,
      foreground: KairanColors.card,
    );
  }
}

/// 注意色の文字タグ（「まもなく 終わります」など）。
class CautionTag extends StatelessWidget {
  const CautionTag(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return _TagBox(
      label: label,
      background: KairanColors.card,
      border: KairanColors.caution,
      foreground: KairanColors.caution,
    );
  }
}

/// 汎用タグ。[emphasis] なら青地白文字、そうでなければ灰枠。
class PlainTag extends StatelessWidget {
  const PlainTag(this.label, {super.key, this.emphasis = false});

  final String label;
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    if (emphasis) {
      return _TagBox(
        label: label,
        background: KairanColors.primary,
        border: KairanColors.primary,
        foreground: KairanColors.card,
      );
    }
    return _TagBox(
      label: label,
      background: KairanColors.card,
      border: KairanColors.border,
      foreground: KairanColors.textSecondary,
    );
  }
}

/// 「取り消されました」などの状態タグ（灰地）。
class StateTag extends StatelessWidget {
  const StateTag(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return _TagBox(
      label: label,
      background: KairanColors.band,
      border: KairanColors.band,
      foreground: KairanColors.textSecondary,
    );
  }
}

/// 公式の避難情報・注意喚起のカード上辺の赤帯（赤地・白文字、C03）。
class AlertBand extends StatelessWidget {
  const AlertBand(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: KairanColors.danger,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(
        label,
        style: KairanTextStyles.tag.copyWith(color: KairanColors.card),
      ),
    );
  }
}

class _TagBox extends StatelessWidget {
  const _TagBox({
    required this.label,
    required this.background,
    required this.border,
    required this.foreground,
  });

  final String label;
  final Color background;
  final Color border;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        border: Border.all(color: border),
        borderRadius: const BorderRadius.all(
          Radius.circular(KairanSizes.radius),
        ),
      ),
      child: Text(
        label,
        style: KairanTextStyles.tag.copyWith(color: foreground),
        softWrap: false,
      ),
    );
  }
}
