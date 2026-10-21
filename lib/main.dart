/// 回覧板 起動。
///
/// Android ではアクティビティのない状態（Application / BOOT_COMPLETED）でも
/// この main() が走るため、runApp より前に画面の存在を前提にしない。
library;

import 'package:flutter/material.dart';
import 'package:kairanban/app/app_controller.dart';

import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppController controller;
  try {
    controller = await AppController.createDefault();
    await controller.init();
  } catch (e, stack) {
    debugPrint('起動に失敗しました: $e\n$stack');
    runApp(KairanStartupErrorApp(message: '$e'));
    return;
  }
  runApp(KairanApp(controller));
}
