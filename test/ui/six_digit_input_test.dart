import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/app/theme.dart';
import 'package:kairanban/ui/widgets/six_digit_input.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: buildKairanTheme(),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  testWidgets('6 つの枠があり、各枠は幅 48 以上・高さ 48 以上', (tester) async {
    await tester.pumpWidget(_wrap(const SixDigitInput(autofocus: false)));
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(6));
    for (var i = 0; i < 6; i++) {
      final size = tester.getSize(fields.at(i));
      expect(size.width, greaterThanOrEqualTo(48), reason: '枠 $i の幅');
      expect(size.height, greaterThanOrEqualTo(48), reason: '枠 $i の高さ');
    }
  });

  testWidgets('数字キーパッドを使う', (tester) async {
    await tester.pumpWidget(_wrap(const SixDigitInput(autofocus: false)));
    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect(field.keyboardType, TextInputType.number);
  });

  testWidgets('1 桁入れると次の枠へ進み、onChanged に連結した値が来る', (tester) async {
    final changes = <String>[];
    await tester.pumpWidget(
      _wrap(SixDigitInput(onChanged: changes.add, autofocus: false)),
    );
    final fields = find.byType(TextField);

    await tester.tap(fields.at(0));
    await tester.pump();
    await tester.enterText(fields.at(0), '1');
    await tester.pump();
    expect(changes.last, '1');
    expect(
      tester.widget<TextField>(fields.at(1)).focusNode!.hasFocus,
      isTrue,
      reason: '2 桁目にフォーカスが移る',
    );

    await tester.enterText(fields.at(1), '2');
    await tester.pump();
    expect(changes.last, '12');
    expect(tester.widget<TextField>(fields.at(2)).focusNode!.hasFocus, isTrue);
  });

  testWidgets('6 桁そろうと onCompleted が呼ばれる', (tester) async {
    final completed = <String>[];
    await tester.pumpWidget(
      _wrap(SixDigitInput(onCompleted: completed.add, autofocus: false)),
    );
    final fields = find.byType(TextField);
    const digits = '123456';
    for (var i = 0; i < 6; i++) {
      await tester.enterText(fields.at(i), digits[i]);
      await tester.pump();
    }
    expect(completed, ['123456']);
    // 最後の枠にフォーカスが残る。
    expect(tester.widget<TextField>(fields.at(5)).focusNode!.hasFocus, isTrue);
  });

  testWidgets('複数桁の貼り付けは枠に振り分ける', (tester) async {
    final changes = <String>[];
    final completed = <String>[];
    await tester.pumpWidget(
      _wrap(
        SixDigitInput(
          onChanged: changes.add,
          onCompleted: completed.add,
          autofocus: false,
        ),
      ),
    );
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '987654');
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      expect(tester.widget<TextField>(fields.at(i)).controller!.text, '987654'[i]);
    }
    expect(changes.last, '987654');
    expect(completed, ['987654']);
  });

  testWidgets('途中の枠に貼り付けても、その枠から順に入る', (tester) async {
    final changes = <String>[];
    await tester.pumpWidget(
      _wrap(SixDigitInput(onChanged: changes.add, autofocus: false)),
    );
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(2), '12');
    await tester.pump();
    expect(tester.widget<TextField>(fields.at(0)).controller!.text, '');
    expect(tester.widget<TextField>(fields.at(2)).controller!.text, '1');
    expect(tester.widget<TextField>(fields.at(3)).controller!.text, '2');
    expect(changes.last, '12');
    expect(tester.widget<TextField>(fields.at(4)).focusNode!.hasFocus, isTrue);
  });

  testWidgets('数字以外は受け付けない', (tester) async {
    final changes = <String>[];
    await tester.pumpWidget(
      _wrap(SixDigitInput(onChanged: changes.add, autofocus: false)),
    );
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'a');
    await tester.pump();
    expect(tester.widget<TextField>(fields.at(0)).controller!.text, '');
    expect(changes.isEmpty || changes.last == '', isTrue);
  });

  testWidgets('空の枠で削除キーを押すと前の枠に戻って消す', (tester) async {
    final changes = <String>[];
    await tester.pumpWidget(
      _wrap(SixDigitInput(onChanged: changes.add, autofocus: false)),
    );
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '5');
    await tester.pump();
    expect(tester.widget<TextField>(fields.at(1)).focusNode!.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(tester.widget<TextField>(fields.at(0)).controller!.text, '');
    expect(tester.widget<TextField>(fields.at(0)).focusNode!.hasFocus, isTrue);
    expect(changes.last, '');
  });

  testWidgets('initialValue で枠を埋める', (tester) async {
    await tester.pumpWidget(
      _wrap(const SixDigitInput(initialValue: '12-34', autofocus: false)),
    );
    final fields = find.byType(TextField);
    expect(tester.widget<TextField>(fields.at(0)).controller!.text, '1');
    expect(tester.widget<TextField>(fields.at(3)).controller!.text, '4');
    expect(tester.widget<TextField>(fields.at(4)).controller!.text, '');
  });

  testWidgets('各枠に「n桁目」の読み上げラベルがある', (tester) async {
    await tester.pumpWidget(_wrap(const SixDigitInput(autofocus: false)));
    expect(find.bySemanticsLabel(RegExp('1桁目')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('6桁目')), findsOneWidget);
  });
}
