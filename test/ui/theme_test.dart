import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/app/theme.dart';
import 'package:kairanban/ui/widgets/big_button.dart';
import 'package:kairanban/ui/widgets/kairan_app_bar.dart';

void main() {
  group('buildKairanTheme', () {
    final theme = buildKairanTheme();

    test('白地・黒文字・自治体ブルー', () {
      expect(theme.scaffoldBackgroundColor, const Color(0xFFF2F2F2));
      expect(theme.colorScheme.primary, const Color(0xFF0017C1));
      expect(theme.colorScheme.onSurface, const Color(0xFF1A1A1A));
      expect(theme.colorScheme.surface, const Color(0xFFFFFFFF));
      expect(theme.brightness, Brightness.light);
    });

    test('タイポグラフィは 24/22/18/16、ウェイトは Regular/Bold のみ', () {
      final t = theme.textTheme;
      expect(t.headlineMedium!.fontSize, 24);
      expect(t.headlineMedium!.fontWeight, FontWeight.bold);
      expect(t.titleLarge!.fontSize, 22);
      expect(t.titleLarge!.fontWeight, FontWeight.bold);
      expect(t.bodyLarge!.fontSize, 18);
      expect(t.bodyLarge!.fontWeight, FontWeight.normal);
      expect(t.bodyLarge!.height, 1.6);
      expect(t.bodyMedium!.fontSize, 16);
      expect(t.labelLarge!.fontSize, 18);
      expect(t.labelLarge!.fontWeight, FontWeight.bold);
      for (final style in [
        t.displayLarge,
        t.headlineSmall,
        t.titleMedium,
        t.titleSmall,
        t.bodySmall,
        t.labelMedium,
        t.labelSmall,
      ]) {
        expect(style!.fontSize, isIn([24.0, 22.0, 18.0, 16.0]));
        expect(style.fontWeight, isIn([FontWeight.normal, FontWeight.bold]));
      }
    });

    test('ボタンは高さ 56・角丸 4・影なし', () {
      final style = theme.elevatedButtonTheme.style!;
      expect(style.minimumSize!.resolve({})!.height, 56);
      expect(style.elevation!.resolve({}), 0);
      final shape = style.shape!.resolve({})! as RoundedRectangleBorder;
      expect(shape.borderRadius, BorderRadius.circular(4));
      expect(theme.outlinedButtonTheme.style!.minimumSize!.resolve({})!.height, 56);
      expect(
        theme.outlinedButtonTheme.style!.side!.resolve({})!.color,
        const Color(0xFF0017C1),
      );
      expect(
        style.backgroundColor!.resolve({WidgetState.pressed}),
        const Color(0xFF00118F),
      );
    });

    test('下部タブは文字ラベル常時表示', () {
      expect(
        theme.navigationBarTheme.labelBehavior,
        NavigationDestinationLabelBehavior.alwaysShow,
      );
    });
  });

  group('KairanTextScale', () {
    test('3 段階に丸める', () {
      expect(KairanTextScale.normalize(1.0), 1.0);
      expect(KairanTextScale.normalize(1.25), 1.25);
      expect(KairanTextScale.normalize(1.5), 1.5);
      expect(KairanTextScale.normalize(0.3), 1.0);
      expect(KairanTextScale.normalize(9.0), 1.5);
    });

    test('OS の倍率に乗算し、上下限で丸める', () {
      expect(
        KairanTextScale.combine(const TextScaler.linear(1.0), 1.25).scale(16),
        closeTo(20, 0.001),
      );
      expect(
        KairanTextScale.combine(const TextScaler.linear(1.3), 1.5).scale(16),
        closeTo(16 * 1.3 * 1.5, 0.001),
      );
      expect(
        KairanTextScale.combine(const TextScaler.linear(3.0), 1.5).scale(16),
        closeTo(16 * KairanTextScale.maxFactor, 0.001),
      );
      expect(
        KairanTextScale.combine(const TextScaler.linear(0.5), 1.0).scale(16),
        closeTo(16 * KairanTextScale.minFactor, 0.001),
      );
    });

    test('ラベル', () {
      expect(KairanTextScale.labelOf(1.0), '標準');
      expect(KairanTextScale.labelOf(1.25), '大きい');
      expect(KairanTextScale.labelOf(1.5), 'とても大きい');
    });
  });

  testWidgets('PrimaryButton / SecondaryButton は幅いっぱい・高さ 56', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildKairanTheme(),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                PrimaryButton(label: '主', onPressed: () {}),
                SecondaryButton(label: '副', onPressed: () {}),
                SecondaryButton(label: '危', danger: true, onPressed: () {}),
                ChoiceButton(label: '選', selected: true, onPressed: () {}),
              ],
            ),
          ),
        ),
      ),
    );
    final width = tester.getSize(find.byType(Column)).width;
    for (final label in ['主', '副', '危', '選']) {
      final finder = find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate(
          (w) => w is ElevatedButton || w is OutlinedButton,
        ),
      );
      final size = tester.getSize(finder);
      expect(size.height, greaterThanOrEqualTo(56), reason: '$label の高さ');
      expect(size.width, width, reason: '$label の幅');
    }
  });

  testWidgets('KairanAppBar の「＜ もどる」は 48 以上で、押すと戻る', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildKairanTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const Scaffold(
                      appBar: KairanAppBar(title: 'サブ画面', showBack: true),
                    ),
                  ),
                ),
                child: const Text('進む'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('進む'));
    await tester.pumpAndSettle();
    final back = find.widgetWithText(TextButton, '＜ もどる');
    expect(back, findsOneWidget);
    final size = tester.getSize(back);
    expect(size.height, greaterThanOrEqualTo(48));
    expect(size.width, greaterThanOrEqualTo(48));
    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(find.text('サブ画面'), findsNothing);
    expect(find.text('進む'), findsOneWidget);
  });
}
