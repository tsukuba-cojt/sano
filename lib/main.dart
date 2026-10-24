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
  // iOS の Bluetooth によるバックグラウンド起動（画面なしのエンジン）では描く先が無い。
  // すれ違いの同期は controller が動かすので、画面は作らない。
  if (WidgetsBinding.instance.platformDispatcher.implicitView == null) {
    debugPrint('画面なしで起動しました（すれ違い通信だけ動かします）');
    return;
  }
  runApp(KairanApp(controller));
}
