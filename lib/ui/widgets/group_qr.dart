/// 参加コードの QR と、大きな番号の表示。
library;

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/theme.dart';
import '../format.dart';

/// 参加コード [code] を `kairanban:<6桁>` の文字列として QR にする。
class GroupQrCode extends StatelessWidget {
  const GroupQrCode(this.code, {super.key, this.size = 200});

  final int code;
  final double size;

  /// QR に入れる文字列。
  static String dataOf(int code) => 'kairanban:${code.toString().padLeft(6, '0')}';

  @override
  Widget build(BuildContext context) {
    return Semantics(
      image: true,
      label: '参加コード ${formatGroupCode(code)} の QR コード',
      child: ExcludeSemantics(
        child: Center(
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: const BoxDecoration(
              color: KairanColors.card,
              border: Border.fromBorderSide(
                BorderSide(color: KairanColors.borderDecorative),
              ),
              borderRadius: BorderRadius.all(
                Radius.circular(KairanSizes.radius),
              ),
            ),
            child: QrImageView(
              data: dataOf(code),
              version: QrVersions.auto,
              size: size,
              padding: EdgeInsets.zero,
              backgroundColor: KairanColors.card,
              eyeStyle: const QrEyeStyle(
                eyeShape: QrEyeShape.square,
                color: KairanColors.text,
              ),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: KairanColors.text,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 「123 456」のような番号を大きく（24 Bold、字間広め）表示する。コピー可。
class BigCodeText extends StatelessWidget {
  const BigCodeText(this.text, {super.key, this.semanticsLabel});

  final String text;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticsLabel,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        decoration: const BoxDecoration(
          color: KairanColors.card,
          border: Border.fromBorderSide(BorderSide(color: KairanColors.border)),
          borderRadius: BorderRadius.all(Radius.circular(KairanSizes.radius)),
        ),
        child: SelectableText(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            letterSpacing: 3,
            height: 1.4,
            color: KairanColors.text,
          ),
        ),
      ),
    );
  }
}
