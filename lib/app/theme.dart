/// 回覧板のテーマ（デジタル庁デザインシステム準拠）。
///
/// 「市役所の掲示板」の見た目: 白地に黒文字、自治体ブルー 1 色、
/// 影・グラデーション・紫・絵文字なし。docs/04_ui_design.md §1〜§3。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 配色。docs/04_ui_design.md §1 の値をそのまま使う。
abstract final class KairanColors {
  /// ページ背景。
  static const Color pageBackground = Color(0xFFF2F2F2);

  /// カード・入力欄の白。
  static const Color card = Color(0xFFFFFFFF);

  /// 本文の黒。
  static const Color text = Color(0xFF1A1A1A);

  /// 副次的な文字（これより薄くしない）。
  static const Color textSecondary = Color(0xFF4D4D4D);

  /// 自治体ブルー（主ボタン・ヘッダ・リンク）。
  static const Color primary = Color(0xFF0017C1);

  /// 主ボタン押下時。
  static const Color primaryPressed = Color(0xFF00118F);

  /// 選択中の背景（薄い青。DADS blue-200）。
  static const Color selectedFill = Color(0xFFC5D7FB);

  /// 緊急・取消（面）。
  static const Color danger = Color(0xFFEC0000);

  /// 緊急・取消（文字）。
  static const Color dangerText = Color(0xFFCE0000);

  /// 注意。
  static const Color caution = Color(0xFFC74700);

  /// 完了。
  static const Color success = Color(0xFF197A4B);

  /// 意味のある枠線。
  static const Color border = Color(0xFF949494);

  /// 装飾的な枠線・区切り線。
  static const Color borderDecorative = Color(0xFFCCCCCC);

  /// 状態帯などの灰地。
  static const Color band = Color(0xFFE6E6E6);

  /// 無効なボタンの面。
  static const Color disabled = Color(0xFF949494);
}

/// 寸法。
abstract final class KairanSizes {
  /// 主ボタン・副ボタンの高さ。
  static const double buttonHeight = 56;

  /// タップ対象の最小辺。
  static const double minTapTarget = 48;

  /// 角丸（4px 以下）。
  static const double radius = 4;

  /// 画面の左右余白。
  static const double pagePadding = 16;

  /// 要素間の最小間隔。
  static const double gap = 8;

  /// お知らせカードの最小高さ。
  static const double cardMinHeight = 72;
}

/// タイポグラフィ（既定スケール。OS の拡大設定と設定画面の倍率が乗る）。
///
/// ウェイトは Regular / Bold のみ。サイズは 24 / 22 / 18 / 16 のみ。
abstract final class KairanTextStyles {
  /// 画面タイトル 24 Bold。
  static const TextStyle screenTitle = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.bold,
    height: 1.4,
    color: KairanColors.text,
  );

  /// お知らせ見出し 22 Bold（折り返し、省略しない）。
  static const TextStyle noticeTitle = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.bold,
    height: 1.4,
    color: KairanColors.text,
  );

  /// 見出し（節）18 Bold。
  static const TextStyle sectionTitle = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.bold,
    height: 1.5,
    color: KairanColors.text,
  );

  /// 本文 18 Regular、行間 1.6。
  static const TextStyle body = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.normal,
    height: 1.6,
    color: KairanColors.text,
  );

  /// メタ情報 16 Regular。
  static const TextStyle meta = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.normal,
    height: 1.5,
    color: KairanColors.text,
  );

  /// 副次的なメタ情報 16 Regular（灰文字）。
  static const TextStyle metaSecondary = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.normal,
    height: 1.5,
    color: KairanColors.textSecondary,
  );

  /// ボタン 18 Bold。
  static const TextStyle button = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.bold,
    height: 1.3,
  );

  /// タグ 16 Bold。
  static const TextStyle tag = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.bold,
    height: 1.3,
  );
}

/// ボタンの共通形（角丸 4px、影なし）。
const RoundedRectangleBorder _buttonShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(KairanSizes.radius)),
);

/// アプリ全体の [ThemeData]。ライトのみ（ダークも同じ見た目にする）。
ThemeData buildKairanTheme() {
  const colorScheme = ColorScheme.light(
    primary: KairanColors.primary,
    onPrimary: KairanColors.card,
    secondary: KairanColors.primary,
    onSecondary: KairanColors.card,
    surface: KairanColors.card,
    onSurface: KairanColors.text,
    error: KairanColors.danger,
    onError: KairanColors.card,
    outline: KairanColors.border,
    outlineVariant: KairanColors.borderDecorative,
    surfaceContainerHighest: KairanColors.band,
    onSurfaceVariant: KairanColors.textSecondary,
    primaryContainer: KairanColors.selectedFill,
    onPrimaryContainer: KairanColors.text,
    secondaryContainer: KairanColors.selectedFill,
    onSecondaryContainer: KairanColors.text,
    surfaceTint: Colors.transparent,
  );

  const textTheme = TextTheme(
    displayLarge: KairanTextStyles.screenTitle,
    displayMedium: KairanTextStyles.screenTitle,
    displaySmall: KairanTextStyles.screenTitle,
    headlineLarge: KairanTextStyles.screenTitle,
    headlineMedium: KairanTextStyles.screenTitle,
    headlineSmall: KairanTextStyles.noticeTitle,
    titleLarge: KairanTextStyles.noticeTitle,
    titleMedium: KairanTextStyles.sectionTitle,
    titleSmall: KairanTextStyles.tag,
    bodyLarge: KairanTextStyles.body,
    bodyMedium: KairanTextStyles.meta,
    bodySmall: KairanTextStyles.metaSecondary,
    labelLarge: KairanTextStyles.button,
    labelMedium: KairanTextStyles.tag,
    labelSmall: KairanTextStyles.tag,
  );

  final elevatedButtonStyle = ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(
      Size(KairanSizes.minTapTarget, KairanSizes.buttonHeight),
    ),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    ),
    shape: const WidgetStatePropertyAll(_buttonShape),
    elevation: const WidgetStatePropertyAll(0),
    shadowColor: const WidgetStatePropertyAll(Colors.transparent),
    surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
    overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    textStyle: const WidgetStatePropertyAll(KairanTextStyles.button),
    foregroundColor: const WidgetStatePropertyAll(KairanColors.card),
    backgroundColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) {
        return KairanColors.disabled;
      }
      if (states.contains(WidgetState.pressed)) {
        return KairanColors.primaryPressed;
      }
      return KairanColors.primary;
    }),
    tapTargetSize: MaterialTapTargetSize.padded,
  );

  final outlinedButtonStyle = ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(
      Size(KairanSizes.minTapTarget, KairanSizes.buttonHeight),
    ),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    ),
    shape: const WidgetStatePropertyAll(_buttonShape),
    elevation: const WidgetStatePropertyAll(0),
    overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    textStyle: const WidgetStatePropertyAll(KairanTextStyles.button),
    foregroundColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) {
        return KairanColors.disabled;
      }
      return KairanColors.primary;
    }),
    backgroundColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.pressed)) {
        return KairanColors.selectedFill;
      }
      return KairanColors.card;
    }),
    side: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) {
        return const BorderSide(color: KairanColors.disabled, width: 2);
      }
      return const BorderSide(color: KairanColors.primary, width: 2);
    }),
    tapTargetSize: MaterialTapTargetSize.padded,
  );

  final textButtonStyle = ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(
      Size(KairanSizes.minTapTarget, KairanSizes.minTapTarget),
    ),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    ),
    shape: const WidgetStatePropertyAll(_buttonShape),
    overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    textStyle: const WidgetStatePropertyAll(KairanTextStyles.button),
    foregroundColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) {
        return KairanColors.disabled;
      }
      if (states.contains(WidgetState.pressed)) {
        return KairanColors.primaryPressed;
      }
      return KairanColors.primary;
    }),
    tapTargetSize: MaterialTapTargetSize.padded,
  );

  const inputBorder = OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(KairanSizes.radius)),
    borderSide: BorderSide(color: KairanColors.border),
  );

  return ThemeData(
    colorScheme: colorScheme,
    brightness: Brightness.light,
    scaffoldBackgroundColor: KairanColors.pageBackground,
    canvasColor: KairanColors.card,
    cardColor: KairanColors.card,
    dividerColor: KairanColors.borderDecorative,
    disabledColor: KairanColors.disabled,
    splashColor: Colors.transparent,
    highlightColor: KairanColors.selectedFill,
    hoverColor: Colors.transparent,
    focusColor: KairanColors.selectedFill,
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    appBarTheme: const AppBarTheme(
      // 青いヘッダの上では時計・電池のアイコンを白にする。
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
      backgroundColor: KairanColors.primary,
      foregroundColor: KairanColors.card,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleSpacing: KairanSizes.pagePadding,
      toolbarHeight: 64,
      titleTextStyle: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.bold,
        height: 1.3,
        color: KairanColors.card,
      ),
      iconTheme: IconThemeData(color: KairanColors.card, size: 28),
      actionsIconTheme: IconThemeData(color: KairanColors.card, size: 28),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(style: elevatedButtonStyle),
    filledButtonTheme: FilledButtonThemeData(style: elevatedButtonStyle),
    outlinedButtonTheme: OutlinedButtonThemeData(style: outlinedButtonStyle),
    textButtonTheme: TextButtonThemeData(style: textButtonStyle),
    navigationBarTheme: NavigationBarThemeData(
      height: 84,
      backgroundColor: KairanColors.card,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      indicatorColor: KairanColors.selectedFill,
      indicatorShape: _buttonShape,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return KairanTextStyles.tag.copyWith(
          color: selected ? KairanColors.primary : KairanColors.text,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          size: 28,
          color: selected ? KairanColors.primary : KairanColors.text,
        );
      }),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: KairanColors.card,
      border: inputBorder,
      enabledBorder: inputBorder,
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(KairanSizes.radius)),
        borderSide: BorderSide(color: KairanColors.borderDecorative),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(KairanSizes.radius)),
        borderSide: BorderSide(color: KairanColors.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(KairanSizes.radius)),
        borderSide: BorderSide(color: KairanColors.danger, width: 2),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(KairanSizes.radius)),
        borderSide: BorderSide(color: KairanColors.danger, width: 2),
      ),
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      labelStyle: KairanTextStyles.meta,
      floatingLabelStyle: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.bold,
        color: KairanColors.primary,
      ),
      hintStyle: KairanTextStyles.metaSecondary,
      helperStyle: KairanTextStyles.metaSecondary,
      counterStyle: KairanTextStyles.metaSecondary,
      errorStyle: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.bold,
        color: KairanColors.dangerText,
      ),
      errorMaxLines: 3,
      helperMaxLines: 3,
    ),
    cardTheme: const CardThemeData(
      color: KairanColors.card,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(KairanSizes.radius)),
        side: BorderSide(color: KairanColors.borderDecorative),
      ),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: KairanColors.card,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(KairanSizes.radius)),
      ),
      titleTextStyle: KairanTextStyles.noticeTitle,
      contentTextStyle: KairanTextStyles.body,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: KairanColors.text,
      contentTextStyle: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.normal,
        height: 1.5,
        color: KairanColors.card,
      ),
      behavior: SnackBarBehavior.fixed,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      actionTextColor: KairanColors.card,
    ),
    dividerTheme: const DividerThemeData(
      color: KairanColors.borderDecorative,
      thickness: 1,
      space: 1,
    ),
    listTileTheme: const ListTileThemeData(
      minVerticalPadding: 12,
      minTileHeight: KairanSizes.buttonHeight,
      titleTextStyle: KairanTextStyles.body,
      subtitleTextStyle: KairanTextStyles.metaSecondary,
      iconColor: KairanColors.text,
      textColor: KairanColors.text,
      tileColor: KairanColors.card,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return KairanColors.card;
        }
        return KairanColors.textSecondary;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return KairanColors.primary;
        }
        return KairanColors.card;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return KairanColors.primary;
        }
        return KairanColors.border;
      }),
      materialTapTargetSize: MaterialTapTargetSize.padded,
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return KairanColors.primary;
        }
        return KairanColors.border;
      }),
      materialTapTargetSize: MaterialTapTargetSize.padded,
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return KairanColors.primary;
        }
        return KairanColors.card;
      }),
      checkColor: const WidgetStatePropertyAll(KairanColors.card),
      side: const BorderSide(color: KairanColors.border, width: 2),
      materialTapTargetSize: MaterialTapTargetSize.padded,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(
          Size(KairanSizes.minTapTarget, KairanSizes.minTapTarget),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        ),
        textStyle: const WidgetStatePropertyAll(KairanTextStyles.tag),
        side: const WidgetStatePropertyAll(
          BorderSide(color: KairanColors.primary, width: 2),
        ),
        shape: const WidgetStatePropertyAll(_buttonShape),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return KairanColors.text;
          }
          return KairanColors.primary;
        }),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return KairanColors.selectedFill;
          }
          return KairanColors.card;
        }),
        tapTargetSize: MaterialTapTargetSize.padded,
      ),
    ),
    badgeTheme: const BadgeThemeData(
      backgroundColor: KairanColors.danger,
      textColor: KairanColors.card,
      textStyle: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
      largeSize: 22,
      padding: EdgeInsets.symmetric(horizontal: 6),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: KairanColors.primary,
      linearTrackColor: KairanColors.borderDecorative,
      circularTrackColor: KairanColors.borderDecorative,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: KairanColors.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
    ),
  );
}

/// 設定の「文字の大きさ」の倍率（標準 / 大きい / とても大きい）。
abstract final class KairanTextScale {
  static const double standard = 1.0;
  static const double large = 1.25;
  static const double extraLarge = 1.5;

  /// 合成後の倍率の下限・上限（OS 設定 × アプリ設定）。
  static const double minFactor = 0.8;
  static const double maxFactor = 2.4;

  /// 近い既定値に丸める（保存値が壊れていても 3 段階のどれかにする）。
  static double normalize(double value) {
    if (value >= 1.4) {
      return extraLarge;
    }
    if (value >= 1.15) {
      return large;
    }
    return standard;
  }

  /// 設定画面のラベル。
  static String labelOf(double value) {
    switch (normalize(value)) {
      case large:
        return '大きい';
      case extraLarge:
        return 'とても大きい';
      default:
        return '標準';
    }
  }

  /// OS の拡大設定（[base]）にアプリ設定の倍率（[appScale]）を乗じた
  /// [TextScaler] を返す。極端な値にならないよう上下限で丸める。
  static TextScaler combine(TextScaler base, double appScale) {
    // 非線形スケーラでも 16px 基準で近似する。
    final osFactor = base.scale(16) / 16;
    final factor = osFactor * normalize(appScale);
    return TextScaler.linear(factor).clamp(
      minScaleFactor: minFactor,
      maxScaleFactor: maxFactor,
    );
  }
}
