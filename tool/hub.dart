/// 開発用 TCP ハブ（模擬電波）の CLI。
///
/// 使い方:
///   dart run tool/hub.dart --port 7777
///   dart run tool/hub.dart --port 7777 --bind 127.0.0.1 --interval 3
///
/// アプリ側は `HubTransport(host, port)` で接続する。
/// - Android エミュレータ: host = 10.0.2.2
/// - iOS シミュレータ / デスクトップ: host = 127.0.0.1
library;

import 'dart:async';
import 'dart:io';

import 'package:kairanban/transport/hub_server.dart';

Future<void> main(List<String> args) async {
  var port = 7777;
  var bind = InternetAddress.anyIPv4;
  var interval = kHubDiscoveryInterval;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    String? valueOf(String name) {
      if (arg == name) {
        if (i + 1 >= args.length) {
          _fail('$name には値が必要です');
        }
        return args[++i];
      }
      if (arg.startsWith('$name=')) {
        return arg.substring(name.length + 1);
      }
      return null;
    }

    if (arg == '--help' || arg == '-h') {
      _usage();
      return;
    }
    final portText = valueOf('--port') ?? valueOf('-p');
    if (portText != null) {
      final parsed = int.tryParse(portText);
      if (parsed == null || parsed < 0 || parsed > 65535) {
        _fail('ポート番号が不正です: $portText');
      }
      port = parsed;
      continue;
    }
    final bindText = valueOf('--bind');
    if (bindText != null) {
      final parsed = InternetAddress.tryParse(bindText);
      if (parsed == null) {
        _fail('bind アドレスが不正です: $bindText');
      }
      bind = parsed;
      continue;
    }
    final intervalText = valueOf('--interval');
    if (intervalText != null) {
      final parsed = double.tryParse(intervalText);
      if (parsed == null || parsed <= 0) {
        _fail('発見間隔（秒）が不正です: $intervalText');
      }
      interval = Duration(milliseconds: (parsed * 1000).round());
      continue;
    }
    _fail('不明な引数: $arg');
  }

  final HubServer hub;
  try {
    hub = await startHub(
      port: port,
      address: bind,
      discoveryInterval: interval,
      log: (message) => stdout.writeln('[${_now()}] $message'),
    );
  } on SocketException catch (e) {
    stderr.writeln('ハブを起動できません: ${e.message}');
    exitCode = 1;
    return;
  }

  stdout
    ..writeln('回覧板 開発用ハブ: ${hub.address.address}:${hub.port} で待機中')
    ..writeln('  発見通知の間隔: ${interval.inMilliseconds / 1000} 秒')
    ..writeln("  Android エミュレータ: HubTransport('10.0.2.2', ${hub.port})")
    ..writeln("  iOS シミュレータ / デスクトップ: HubTransport('127.0.0.1', ${hub.port})")
    ..writeln('  Ctrl+C で終了');

  final done = Completer<void>();
  late final StreamSubscription<ProcessSignal> sigint;
  sigint = ProcessSignal.sigint.watch().listen((_) {
    sigint.cancel();
    if (!done.isCompleted) {
      done.complete();
    }
  });
  await done.future;
  stdout.writeln('終了します…');
  await hub.close();
}

String _now() {
  final t = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

void _usage() {
  stdout.writeln('''
使い方: dart run tool/hub.dart [--port 7777] [--bind 0.0.0.0] [--interval 3]
  --port, -p  待ち受けポート（既定 7777）
  --bind      待ち受けアドレス（既定 0.0.0.0 = すべての IPv4）
  --interval  発見通知（広告の模擬）の間隔（秒、既定 3）
''');
}

Never _fail(String message) {
  stderr.writeln(message);
  _usage();
  exit(2);
}
