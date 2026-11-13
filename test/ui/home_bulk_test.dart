import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/app/app_controller.dart';
import 'package:kairanban/app/theme.dart';
import 'package:kairanban/core/envelope.dart';
import 'package:kairanban/mesh/groups.dart';
import 'package:kairanban/mesh/store_file.dart';
import 'package:kairanban/transport/fake_transport.dart';
import 'package:kairanban/ui/screens/home_screen.dart';
import 'package:kairanban/ui/widgets/notice_card.dart';

import '../mesh/helpers.dart';

// 保存エラーの表示だけを差し替え、一覧と集計は実物の処理を使う。
class _ListController extends AppController {
  _ListController(FakeRadio radio)
    : super(
        transport: radio.createTransport('home-bulk'),
        storeBackend: MemoryStoreBackend(),
        kv: MemoryKeyValueStore(),
        now: radio.clock.now,
        createTimer: radio.clock.createTimer,
      );

  String? error;

  @override
  String? get storageError => error ?? super.storageError;
}

class _ReadCountingEnvelope extends Envelope {
  _ReadCountingEnvelope(Envelope source)
    : super(
        kind: source.kind,
        groupId: source.groupId,
        msgId: source.msgId,
        createdAt: source.createdAt,
        expiresAt: source.expiresAt,
        bodyPlain: source.bodyPlain,
        role: source.role,
        category: source.category,
      );

  int bodyReads = 0;

  @override
  NoticeBody? get notice {
    bodyReads++;
    return super.notice;
  }
}

void main() {
  testWidgets('保存失敗はグループ参加の有無にかかわらずホームに表示する', (tester) async {
    final radio = FakeRadio(clock: FakeClock(startEpochSeconds: kT0));
    final controller = _ListController(radio);
    await controller.init();
    addTearDown(controller.dispose);
    controller.error = '端末の 空き容量を 確かめてください。';
    await tester.pumpWidget(
      MaterialApp(
        theme: buildKairanTheme(),
        home: HomeScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('保存できていない 情報があります'), findsOneWidget);
    expect(find.text(controller.error!), findsOneWidget);

    await controller.createGroup(name: '試験', membersCanPost: true);
    await tester.pumpAndSettle();
    expect(find.text('保存できていない 情報があります'), findsOneWidget);
    expect(find.text(controller.error!), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('既読のお知らせは表示と先読みの範囲に入るまで本文を読み取らない', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final radio = FakeRadio(clock: FakeClock(startEpochSeconds: kT0 + 1000));
    final controller = _ListController(radio);
    await controller.init();
    addTearDown(controller.dispose);
    final group = await controller.createGroup(
      name: '試験',
      membersCanPost: true,
    );
    final messages = [
      for (var i = 0; i < 1000; i++)
        _ReadCountingEnvelope(
          makeNotice(
            origin: nodeIdOf(i + 1),
            createdAt: kT0 + i,
            groupId: group.code,
            title: 'お知らせ $i',
          ),
        ),
    ];
    await controller.store.addAll(messages, now: controller.now, isLocal: true);
    for (final message in messages) {
      message.bodyReads = 0;
    }

    await tester.pumpWidget(
      MaterialApp(
        theme: buildKairanTheme(),
        home: HomeScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('お知らせ 999'), findsOneWidget);
    expect(messages.last.bodyReads, greaterThan(0));
    expect(messages.first.bodyReads, 0);
    expect(messages.where((m) => m.bodyReads > 0).length, lessThan(30));
    expect(find.byType(NoticeCard).evaluate().length, lessThan(30));

    final scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    for (var i = 0; i < 4; i++) {
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
      await tester.pumpAndSettle();
    }
    expect(find.text('お知らせ 0'), findsOneWidget);
    expect(messages.first.bodyReads, greaterThan(0));
  });
}
