import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/app/theme.dart';
import 'package:kairanban/core/categories.dart';
import 'package:kairanban/core/envelope.dart';
import 'package:kairanban/ui/widgets/notice_card.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: buildKairanTheme(),
    home: Scaffold(
      body: ListView(padding: const EdgeInsets.all(16), children: [child]),
    ),
  );
}

void main() {
  final createdAt = DateTime(2026, 10, 11, 15, 20);

  testWidgets('種別・役割・新着・見出し・場所・日時・発信元を表示する', (tester) async {
    await tester.pumpWidget(
      _wrap(
        NoticeCard(
          category: NoticeCategory.supply,
          role: SenderRole.official,
          title: '〇〇小学校に 水と 毛布が とどきました',
          place: '〇〇小学校（避難所）',
          createdAt: createdAt,
          senderName: '〇〇市 防災課',
          isNew: true,
          onTap: () {},
        ),
      ),
    );
    expect(find.text('物資'), findsOneWidget);
    expect(find.text('公式'), findsOneWidget);
    expect(find.text('新着'), findsOneWidget);
    expect(find.text('〇〇小学校に 水と 毛布が とどきました'), findsOneWidget);
    expect(find.text('場所: 〇〇小学校（避難所）'), findsOneWidget);
    expect(find.text('2026年10月11日 午後3時20分'), findsOneWidget);
    expect(find.text('〇〇市 防災課'), findsOneWidget);
    expect(find.text('取り消されました'), findsNothing);
  });

  testWidgets('高さは 72 以上', (tester) async {
    await tester.pumpWidget(
      _wrap(
        NoticeCard(
          category: NoticeCategory.general,
          role: SenderRole.resident,
          title: '短い',
          createdAt: createdAt,
          senderName: '名前なし',
          onTap: () {},
        ),
      ),
    );
    expect(tester.getSize(find.byType(NoticeCard)).height, greaterThanOrEqualTo(72));
  });

  testWidgets('タップで onTap が呼ばれ、ボタンとして読み上げられる', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _wrap(
        NoticeCard(
          category: NoticeCategory.water,
          role: SenderRole.staff,
          title: '給水',
          createdAt: createdAt,
          senderName: 'スタッフ',
          onTap: () => taps++,
        ),
      ),
    );
    final handle = tester.ensureSemantics();
    final semantics = tester.getSemantics(find.byType(NoticeCard));
    expect(semantics, matchesSemantics(isButton: true, hasTapAction: true));
    expect(semantics.label, contains('給水、スタッフ、'));
    handle.dispose();
    await tester.tap(find.byType(NoticeCard));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('取り消し済みは帯を出し、新着タグは出さない', (tester) async {
    await tester.pumpWidget(
      _wrap(
        NoticeCard(
          category: NoticeCategory.food,
          role: SenderRole.official,
          title: '炊き出し',
          createdAt: createdAt,
          senderName: '〇〇市',
          isNew: true,
          retracted: true,
          onTap: () {},
        ),
      ),
    );
    expect(find.text('取り消されました'), findsOneWidget);
    expect(find.text('新着'), findsNothing);
  });

  testWidgets('置き換え済みは帯を出す', (tester) async {
    await tester.pumpWidget(
      _wrap(
        NoticeCard(
          category: NoticeCategory.food,
          role: SenderRole.official,
          title: '炊き出し',
          createdAt: createdAt,
          senderName: '〇〇市',
          superseded: true,
          onTap: () {},
        ),
      ),
    );
    expect(find.text('新しい内容に 置き換えられました'), findsOneWidget);
  });

  testWidgets('場所が空なら「場所:」行を出さない。自分の投稿はタグを出す', (tester) async {
    await tester.pumpWidget(
      _wrap(
        NoticeCard(
          category: NoticeCategory.warning,
          role: SenderRole.resident,
          title: '余震に 注意',
          createdAt: createdAt,
          senderName: '住民A',
          isLocal: true,
          onTap: () {},
        ),
      ),
    );
    expect(find.textContaining('場所:'), findsNothing);
    expect(find.text('自分の 投稿'), findsOneWidget);
  });

  testWidgets('長い見出しは省略せず折り返す', (tester) async {
    const longTitle =
        '〇〇小学校の 体育館に 飲み水と 毛布と 非常食が たくさん とどきましたので 必要な方は 受付まで 来てください';
    await tester.pumpWidget(
      _wrap(
        NoticeCard(
          category: NoticeCategory.supply,
          role: SenderRole.official,
          title: longTitle,
          createdAt: createdAt,
          senderName: '〇〇市',
          onTap: () {},
        ),
      ),
    );
    final text = tester.widget<Text>(find.text(longTitle));
    expect(text.maxLines, isNull);
    expect(text.overflow, isNot(TextOverflow.ellipsis));
  });
}
