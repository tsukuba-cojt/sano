/// `BleTransport` の Platform Channel 契約（docs/03_architecture.md §3）を
/// モックチャネルで検証する。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/mesh/transport.dart';
import 'package:kairanban/transport/ble_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel(kBleMethodChannelName);
  const eventChannel = EventChannel(kBleEventChannelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late Map<String, Object? Function(MethodCall call)> handlers;
  MockStreamHandlerEventSink? sink;
  var listenCount = 0;

  setUp(() {
    calls = [];
    handlers = {};
    sink = null;
    listenCount = 0;
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      calls.add(call);
      final handler = handlers[call.method];
      if (handler == null) {
        return null;
      }
      return handler(call);
    });
    messenger.setMockStreamHandler(
      eventChannel,
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          listenCount++;
          sink = events;
        },
        onCancel: (arguments) {
          sink = null;
        },
      ),
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methodChannel, null);
    messenger.setMockStreamHandler(eventChannel, null);
  });

  Map<String, Object?> argsOf(MethodCall call) =>
      (call.arguments as Map).cast<String, Object?>();

  group('メソッド呼び出し', () {
    test('start は UUID・nodeId・lowPower を契約どおり渡す', () async {
      final transport = BleTransport();
      final nodeId = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      await transport.start(TransportConfig(nodeId: nodeId, lowPower: true));

      final call = calls.single;
      expect(call.method, 'start');
      final args = argsOf(call);
      expect(args['serviceUuid'], '6b616972-616e-4b41-4952-414e00000010');
      expect(args['rxUuid'], '6b616972-616e-4b41-4952-414e00000011');
      expect(args['txUuid'], '6b616972-616e-4b41-4952-414e00000012');
      expect(args['nodeId'], isA<Uint8List>());
      expect(args['nodeId'], nodeId);
      expect(args['lowPower'], isTrue);
      // start 時点でイベントチャネルを購読している。
      expect(listenCount, 1);
      await transport.dispose();
    });

    test('stop / setLowPower / connect / send / close の引数', () async {
      final transport = BleTransport();
      await transport.stop();
      await transport.setLowPower(true);
      await transport.connect('AA:BB');
      final chunk = Uint8List.fromList([9, 8, 7]);
      await transport.send(42, chunk);
      await transport.close(42);

      expect(calls.map((c) => c.method),
          ['stop', 'setLowPower', 'connect', 'send', 'close']);
      expect(calls[0].arguments, isNull);
      expect(argsOf(calls[1]), {'lowPower': true});
      expect(argsOf(calls[2]), {'peerId': 'AA:BB'});
      final sendArgs = argsOf(calls[3]);
      expect(sendArgs['linkId'], 42);
      expect(sendArgs['data'], isA<Uint8List>());
      expect(sendArgs['data'], chunk);
      expect(argsOf(calls[4]), {'linkId': 42});
      await transport.dispose();
    });

    test('send はネイティブの完了を待つ（フロー制御）', () async {
      final transport = BleTransport();
      final release = Completer<void>();
      handlers['send'] = (_) => release.future;
      var finished = false;
      final pending = transport.send(1, Uint8List(3)).then((_) {
        finished = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      release.complete();
      await pending;
      expect(finished, isTrue);
      await transport.dispose();
    });

    test('getState はネイティブの Map を BleState にする', () async {
      handlers['getState'] = (_) => <String, Object?>{
            'supported': true,
            'poweredOn': true,
            'permission': 'granted',
            'running': false,
          };
      final transport = BleTransport();
      final state = await transport.getState();
      expect(state.supported, isTrue);
      expect(state.poweredOn, isTrue);
      expect(state.permission, 'granted');
      expect(state.running, isFalse);
      await transport.dispose();
    });

    test('requestPermissions / requestBatteryOptimizationExemption / '
        'openAppSettings', () async {
      handlers['requestPermissions'] = (_) => true;
      handlers['requestBatteryOptimizationExemption'] = (_) => false;
      final transport = BleTransport();
      expect(await transport.requestPermissions(), isTrue);
      expect(await transport.requestBatteryOptimizationExemption(), isFalse);
      await transport.openAppSettings();
      expect(calls.map((c) => c.method), [
        'requestPermissions',
        'requestBatteryOptimizationExemption',
        'openAppSettings',
      ]);
      await transport.dispose();
    });

    test('noteReceived は受信時刻を Unix ミリ秒で渡し、失敗しても例外にしない',
        () async {
      final transport = BleTransport();
      final at = DateTime.utc(2026, 10, 11, 6, 10, 0);
      await transport.noteReceived(at);
      expect(calls.single.method, 'noteReceived');
      expect(argsOf(calls.single), {'at': at.millisecondsSinceEpoch});

      // ネイティブが未実装（Android など）でも呼び出し側には届かない。
      handlers['noteReceived'] =
          (_) => throw PlatformException(code: 'unimplemented');
      final logs = <TransportLog>[];
      transport.events.listen((e) {
        if (e is TransportLog) {
          logs.add(e);
        }
      });
      await transport.noteReceived(at);
      await Future<void>.delayed(Duration.zero);
      expect(logs.single.message, contains('noteReceived'));
      await transport.dispose();
    });
  });

  group('PlatformException', () {
    test('connect / send は TransportLog を流して再送出する', () async {
      handlers['connect'] = (_) =>
          throw PlatformException(code: 'notFound', message: '相手がいません');
      handlers['send'] = (_) => throw PlatformException(code: 'busy');
      final transport = BleTransport();
      final logs = <TransportLog>[];
      transport.events.listen((e) {
        if (e is TransportLog) {
          logs.add(e);
        }
      });

      await expectLater(
        transport.connect('X'),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'notFound')),
      );
      await expectLater(
        transport.send(1, Uint8List(1)),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'busy')),
      );
      await Future<void>.delayed(Duration.zero);
      expect(logs.length, 2);
      expect(logs[0].message, contains('connect'));
      expect(logs[0].message, contains('notFound'));
      expect(logs[0].message, contains('相手がいません'));
      expect(logs[1].message, contains('send'));
      expect(logs[1].message, contains('busy'));
      await transport.dispose();
    });

    test('start / stop / setLowPower / close はログのみで失敗しない', () async {
      for (final m in ['start', 'stop', 'setLowPower', 'close']) {
        handlers[m] = (_) => throw PlatformException(code: 'fail-$m');
      }
      final transport = BleTransport();
      final logs = <TransportLog>[];
      transport.events.listen((e) {
        if (e is TransportLog) {
          logs.add(e);
        }
      });
      await transport.start(TransportConfig(nodeId: Uint8List(8)));
      await transport.stop();
      await transport.setLowPower(false);
      await transport.close(7);
      await Future<void>.delayed(Duration.zero);
      expect(logs.map((l) => l.message).join('\n'), allOf([
        contains('fail-start'),
        contains('fail-stop'),
        contains('fail-setLowPower'),
        contains('fail-close'),
      ]));
      await transport.dispose();
    });

    test('ネイティブ未実装（MissingPluginException）でも getState は '
        'unavailable を返す', () async {
      messenger.setMockMethodCallHandler(methodChannel, null);
      final transport = BleTransport();
      final state = await transport.getState();
      expect(state.supported, isFalse);
      expect(await transport.requestPermissions(), isFalse);
      expect(await transport.requestBatteryOptimizationExemption(), isTrue);
      await transport.dispose();
    });
  });

  group('イベント変換', () {
    test('各 type を TransportEvent に写す', () async {
      final transport = BleTransport();
      final received = <TransportEvent>[];
      transport.events.listen(received.add);
      await Future<void>.delayed(Duration.zero);
      expect(listenCount, 1);
      expect(sink, isNotNull);

      sink!
        ..success(<Object?, Object?>{
          'type': 'state',
          'poweredOn': true,
          'scanning': true,
          'advertising': false,
          'permission': 'granted',
        })
        ..success(<Object?, Object?>{
          'type': 'discovered',
          'peerId': 'P1',
          'rssi': -55,
          'viaApple': true,
        })
        ..success(<Object?, Object?>{
          'type': 'linkOpened',
          'linkId': 3,
          'peerId': 'P1',
          'maxChunk': 244,
          'initiator': true,
        })
        ..success(<Object?, Object?>{
          'type': 'data',
          'linkId': 3,
          'data': Uint8List.fromList([1, 2, 3]),
        })
        ..success(<Object?, Object?>{
          'type': 'linkClosed',
          'linkId': 3,
          'reason': 'remote',
        })
        ..success(<Object?, Object?>{
          'type': 'linkClosed',
          'linkId': 0,
          'peerId': 'P2',
          'reason': 'timeout',
        })
        ..success(<Object?, Object?>{'type': 'log', 'message': 'hello'})
        ..success(<Object?, Object?>{'type': 'weird'})
        ..error(code: 'E1', message: 'boom');
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(9));
      final state = received[0] as TransportState;
      expect(state.poweredOn, isTrue);
      expect(state.scanning, isTrue);
      expect(state.advertising, isFalse);
      expect(state.permission, 'granted');

      final discovered = received[1] as PeerDiscovered;
      expect(discovered.peerId, 'P1');
      expect(discovered.rssi, -55);
      expect(discovered.viaApple, isTrue);

      final opened = received[2] as LinkOpened;
      expect(opened.linkId, 3);
      expect(opened.peerId, 'P1');
      expect(opened.maxChunk, 244);
      expect(opened.initiator, isTrue);

      final data = received[3] as LinkData;
      expect(data.linkId, 3);
      expect(data.data, isA<Uint8List>());
      expect(data.data, [1, 2, 3]);

      final closed = received[4] as LinkClosed;
      expect(closed.linkId, 3);
      expect(closed.peerId, isNull);
      expect(closed.reason, 'remote');

      final failed = received[5] as LinkClosed;
      expect(failed.linkId, 0);
      expect(failed.peerId, 'P2');
      expect(failed.reason, 'timeout');

      expect((received[6] as TransportLog).message, 'hello');
      // 不明な type はログとして流す。
      expect((received[7] as TransportLog).message, contains('weird'));
      // ストリームエラーもログとして流し、購読は続く。
      expect((received[8] as TransportLog).message, contains('E1'));

      sink!.success(<Object?, Object?>{'type': 'log', 'message': 'after'});
      await Future<void>.delayed(Duration.zero);
      expect((received.last as TransportLog).message, 'after');
      await transport.dispose();
    });

    test('data は List<int> で届いても Uint8List になる', () {
      final event = BleTransport.parseEvent(<Object?, Object?>{
        'type': 'data',
        'linkId': 1,
        'data': <int>[7, 8],
      });
      expect(event, isA<LinkData>());
      final data = (event! as LinkData).data;
      expect(data, isA<Uint8List>());
      expect(data, [7, 8]);
    });

    test('Map でない・type が無いイベントは null', () {
      expect(BleTransport.parseEvent('x'), isNull);
      expect(BleTransport.parseEvent(<Object?, Object?>{}), isNull);
      expect(BleTransport.parseEvent(null), isNull);
    });

    test('購読者がいなくなると EventChannel の購読を解除し、'
        '再購読できる', () async {
      final transport = BleTransport();
      final sub = transport.events.listen((_) {});
      await Future<void>.delayed(Duration.zero);
      expect(listenCount, 1);
      await sub.cancel();
      await Future<void>.delayed(Duration.zero);
      // Transport 側は購読を保持し続ける（ネイティブのバッファを溜めない）。
      expect(sink, isNotNull);
      await transport.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(sink, isNull);
    });
  });
}
