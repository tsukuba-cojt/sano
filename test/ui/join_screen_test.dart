import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/app/theme.dart';
import 'package:kairanban/ui/screens/join_screen.dart';
import 'package:kairanban/ui/widgets/six_digit_input.dart';

/// 近隣から届いたグループ名の模擬。
class _FakeNames extends ChangeNotifier {
  final Map<int, String> names = {};

  void deliver(int code, String name) {
    names[code] = name;
    notifyListeners();
  }
}

Future<void> _typeCode(WidgetTester tester, String code) async {
  final fields = find.descendant(
    of: find.byType(SixDigitInput),
    matching: find.byType(TextField),
  );
  for (var i = 0; i < code.length; i++) {
    await tester.enterText(fields.at(i), code[i]);
    await tester.pump();
  }
}

void main() {
  testWidgets('6 桁そろうまで「参加する」は押せない', (tester) async {
    final joined = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildKairanTheme(),
        home: JoinScreen(
          lookupName: (_) => null,
          isJoined: (_) => false,
          onJoin: (code) async => joined.add(code),
        ),
      ),
    );
    final button = find.widgetWithText(ElevatedButton, '参加する');
    expect(button, findsOneWidget);
    expect(tester.widget<ElevatedButton>(button).enabled, isFalse);

    await _typeCode(tester, '12345');
    expect(tester.widget<ElevatedButton>(button).enabled, isFalse);

    await _typeCode(tester, '123456');
    expect(tester.widget<ElevatedButton>(button).enabled, isTrue);
    expect(joined, isEmpty);
  });

  testWidgets('名前が未着なら案内を出し、届いたら名前を出す', (tester) async {
    final names = _FakeNames();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildKairanTheme(),
        home: JoinScreen(
          lookupName: (code) => names.names[code],
          isJoined: (_) => false,
          onJoin: (_) async {},
          listenable: names,
        ),
      ),
    );
    await _typeCode(tester, '123456');
    expect(find.textContaining('名前が まだ 届いていません'), findsOneWidget);

    names.deliver(123456, '〇〇市 防災課');
    await tester.pump();
    expect(find.text('〇〇市 防災課'), findsOneWidget);
    expect(find.text('グループ名'), findsOneWidget);
  });

  testWidgets('参加済みのコードは案内を出し、ボタンを押せない', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildKairanTheme(),
        home: JoinScreen(
          lookupName: (_) => 'すでに',
          isJoined: (code) => code == 111111,
          onJoin: (_) async {},
        ),
      ),
    );
    await _typeCode(tester, '111111');
    expect(find.textContaining('もう 参加しています'), findsOneWidget);
    final button = find.widgetWithText(ElevatedButton, '参加する');
    expect(tester.widget<ElevatedButton>(button).enabled, isFalse);
  });

  testWidgets('「参加する」で onJoin が呼ばれ、完了ダイアログの後に閉じる', (tester) async {
    final joined = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildKairanTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<bool>(
                      builder: (_) => JoinScreen(
                        lookupName: (_) => '〇〇市 防災課',
                        isJoined: (_) => false,
                        onJoin: (code) async => joined.add(code),
                      ),
                    ),
                  );
                },
                child: const Text('開く'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('開く'));
    await tester.pumpAndSettle();
    expect(find.text('参加する'), findsWidgets);

    await _typeCode(tester, '654321');
    await tester.tap(find.widgetWithText(ElevatedButton, '参加する'));
    await tester.pumpAndSettle();
    expect(joined, [654321]);
    expect(find.text('参加しました'), findsOneWidget);
    expect(find.textContaining('「〇〇市 防災課」に 参加しました'), findsOneWidget);

    await tester.tap(find.text('とじる'));
    await tester.pumpAndSettle();
    expect(find.byType(JoinScreen), findsNothing);
    expect(find.text('開く'), findsOneWidget);
  });

  testWidgets('onJoin が失敗したらエラーダイアログを出して画面に留まる', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildKairanTheme(),
        home: JoinScreen(
          lookupName: (_) => null,
          isJoined: (_) => false,
          onJoin: (_) async => throw StateError('だめ'),
        ),
      ),
    );
    await _typeCode(tester, '222222');
    await tester.tap(find.widgetWithText(ElevatedButton, '参加する'));
    await tester.pumpAndSettle();
    expect(find.text('参加できませんでした'), findsOneWidget);
    await tester.tap(find.text('とじる'));
    await tester.pumpAndSettle();
    expect(find.byType(JoinScreen), findsOneWidget);
  });

  testWidgets('ヘッダに「＜ もどる」がある', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildKairanTheme(),
        home: JoinScreen(
          lookupName: (_) => null,
          isJoined: (_) => false,
          onJoin: (_) async {},
        ),
      ),
    );
    expect(find.text('＜ もどる'), findsOneWidget);
    expect(find.byType(BackButton), findsNothing);
  });
}
