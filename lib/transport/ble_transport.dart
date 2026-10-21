/// ネイティブ BLE（Swift / Kotlin）への橋渡し。
///
/// docs/03_architecture.md §3 の Platform Channel 契約をそのまま Dart の
/// [Transport] に写す。MethodChannel `jp.kairanban/ble` と
/// EventChannel `jp.kairanban/ble/events` を使う。
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../mesh/transport.dart';

/// 回覧板サービス UUID（docs/02_protocol.md §1）。
const String kServiceUuid = '6b616972-616e-4b41-4952-414e00000010';

/// RX characteristic（central → peripheral、Write Without Response）。
const String kRxCharacteristicUuid = '6b616972-616e-4b41-4952-414e00000011';

/// TX characteristic（peripheral → central、Notify）。
const String kTxCharacteristicUuid = '6b616972-616e-4b41-4952-414e00000012';

/// MethodChannel 名。
const String kBleMethodChannelName = 'jp.kairanban/ble';

/// EventChannel 名。
const String kBleEventChannelName = 'jp.kairanban/ble/events';

/// `getState` の戻り値。
class BleState {
  const BleState({
    required this.supported,
    required this.poweredOn,
    required this.permission,
    required this.running,
  });

  /// この端末・環境で BLE が使えるか（シミュレータ等では false）。
  final bool supported;

  /// Bluetooth が ON か。
  final bool poweredOn;

  /// granted / denied / unknown
  final String permission;

  /// `start` 済みか。
  final bool running;

  /// ネイティブ側が存在しない環境（シミュレータ・デスクトップ）の既定値。
  static const BleState unavailable = BleState(
    supported: false,
    poweredOn: false,
    permission: 'unknown',
    running: false,
  );

  @override
  String toString() =>
      'BleState(supported: $supported, poweredOn: $poweredOn, '
      'permission: $permission, running: $running)';
}

/// ネイティブ BLE トランスポート。
///
/// - すべてのメソッド呼び出しは [PlatformException] を [TransportLog] として
///   流す。`connect` / `send` は呼び出し元が失敗を知る必要があるため再送出し、
///   それ以外（start / stop / setLowPower / close）はログのみで握りつぶす。
/// - ネイティブ側が未実装の環境（[MissingPluginException]）も同様に扱う。
/// - `send` はネイティブがスタックへ渡し終えるまで完了しない（フロー制御）。
class BleTransport implements Transport {
  BleTransport() {
    _events = StreamController<TransportEvent>.broadcast(
      onListen: _subscribeNative,
    );
  }

  static const MethodChannel _methods = MethodChannel(kBleMethodChannelName);
  static const EventChannel _eventChannel = EventChannel(kBleEventChannelName);

  late final StreamController<TransportEvent> _events;
  StreamSubscription<Object?>? _nativeSubscription;
  bool _disposed = false;

  @override
  Stream<TransportEvent> get events => _events.stream;

  // ---------------------------------------------------------------- Transport

  @override
  Future<void> start(TransportConfig config) async {
    // 購読前に届いたイベントはネイティブ側がバッファしているため、
    // start 時点で必ず購読を張っておく。
    _subscribeNative();
    await _guard<Object?>(
      'start',
      () => _methods.invokeMethod<Object?>('start', <String, Object?>{
        'serviceUuid': kServiceUuid,
        'rxUuid': kRxCharacteristicUuid,
        'txUuid': kTxCharacteristicUuid,
        'nodeId': _asUint8List(config.nodeId),
        'lowPower': config.lowPower,
      }),
    );
  }

  @override
  Future<void> stop() async {
    await _guard<Object?>('stop', () => _methods.invokeMethod<Object?>('stop'));
  }

  @override
  Future<void> setLowPower(bool lowPower) async {
    await _guard<Object?>(
      'setLowPower',
      () => _methods.invokeMethod<Object?>('setLowPower', <String, Object?>{
        'lowPower': lowPower,
      }),
    );
  }

  @override
  Future<void> connect(String peerId) async {
    await _guard<Object?>(
      'connect',
      () => _methods.invokeMethod<Object?>('connect', <String, Object?>{
        'peerId': peerId,
      }),
      rethrowOnError: true,
    );
  }

  @override
  Future<void> send(int linkId, Uint8List data) async {
    // ネイティブがスタックに渡し終えるまで戻らない。呼び出し元は直列に await する。
    await _guard<Object?>(
      'send',
      () => _methods.invokeMethod<Object?>('send', <String, Object?>{
        'linkId': linkId,
        'data': _asUint8List(data),
      }),
      rethrowOnError: true,
    );
  }

  @override
  Future<void> close(int linkId) async {
    await _guard<Object?>(
      'close',
      () => _methods.invokeMethod<Object?>('close', <String, Object?>{
        'linkId': linkId,
      }),
    );
  }

  // ----------------------------------------------------------- 追加メソッド

  /// 現在のネイティブ状態。ネイティブが無い環境では [BleState.unavailable]。
  Future<BleState> getState() async {
    final map = await _guard<Map<String, Object?>?>(
      'getState',
      () => _methods.invokeMapMethod<String, Object?>('getState'),
    );
    if (map == null) {
      return BleState.unavailable;
    }
    return BleState(
      supported: _asBool(map['supported'], fallback: true),
      poweredOn: _asBool(map['poweredOn']),
      permission: _asString(map['permission'], fallback: 'unknown'),
      running: _asBool(map['running']),
    );
  }

  /// Bluetooth 権限を要求する。許可されたら true。
  Future<bool> requestPermissions() async {
    final granted = await _guard<bool?>(
      'requestPermissions',
      () => _methods.invokeMethod<bool>('requestPermissions'),
    );
    return granted ?? false;
  }

  /// Android の電池最適化除外を要求する。iOS・未対応環境は true。
  Future<bool> requestBatteryOptimizationExemption() async {
    final exempted = await _guard<bool?>(
      'requestBatteryOptimizationExemption',
      () => _methods.invokeMethod<bool>('requestBatteryOptimizationExemption'),
    );
    return exempted ?? true;
  }

  /// OS のアプリ設定画面を開く。
  Future<void> openAppSettings() async {
    await _guard<Object?>(
      'openAppSettings',
      () => _methods.invokeMethod<Object?>('openAppSettings'),
    );
  }

  /// お知らせを受け取ったことをネイティブへ知らせる（Unix ミリ秒）。
  /// iOS は Live Activity の「最後に 受け取ったのは …」に使う（更新は 15 分に 1 回程度に間引く）。
  /// Android・未対応環境では何もしない。
  Future<void> noteReceived(DateTime at) async {
    await _guard<Object?>(
      'noteReceived',
      () => _methods.invokeMethod<Object?>('noteReceived', <String, Object?>{
        'at': at.toUtc().millisecondsSinceEpoch,
      }),
    );
  }

  /// OS の通知権限を要求する。許可されたら true。
  /// Android 12 以下・iOS で許可済みなど、要求が不要なら true。未対応環境も true。
  Future<bool> requestNotificationPermission() async {
    final granted = await _guard<bool?>(
      'requestNotificationPermission',
      () => _methods.invokeMethod<bool>('requestNotificationPermission'),
    );
    return granted ?? true;
  }

  /// 新しいお知らせを OS のローカル通知で知らせる。同じ [id] は置き換える。
  /// [id] は 31 ビットの非負整数（msg_id の下位 31 ビット）。
  /// [importance] は urgent / important / normal（docs/08 C05。チャネルと
  /// 割り込みレベルをネイティブが選ぶ）。[msgId] はタップで詳細を開くための msg_id。
  Future<void> showNotice({
    required int id,
    required String title,
    required String body,
    required int groupCode,
    String importance = 'important',
    int? msgId,
  }) async {
    await _guard<Object?>(
      'showNotice',
      () => _methods.invokeMethod<Object?>('showNotice', <String, Object?>{
        'id': id,
        'title': title,
        'body': body,
        'groupCode': groupCode,
        'importance': importance,
        'msgId': ?msgId,
      }),
    );
  }

  /// 出した通知を消す（取り消された避難情報など）。
  Future<void> cancelNotice(int id) async {
    await _guard<Object?>(
      'cancelNotice',
      () => _methods.invokeMethod<Object?>('cancelNotice', <String, Object?>{
        'id': id,
      }),
    );
  }

  /// 画面を消さない（中継役・「30 分 画面を 点けたままにする」、C04 C07）。
  Future<void> setKeepScreenOn(bool on) async {
    await _guard<Object?>(
      'setKeepScreenOn',
      () => _methods.invokeMethod<Object?>('setKeepScreenOn', <String, Object?>{
        'on': on,
      }),
    );
  }

  /// 交換完了の短い音と振動（C04）。
  Future<void> playChime() async {
    await _guard<Object?>(
      'playChime',
      () => _methods.invokeMethod<Object?>('playChime'),
    );
  }

  /// 電池残量（0..100）と充電中か。取れない環境では null（C06）。
  Future<({int level, bool charging})?> getBattery() async {
    final map = await _guard<Map<String, Object?>?>(
      'getBattery',
      () => _methods.invokeMapMethod<String, Object?>('getBattery'),
    );
    if (map == null) {
      return null;
    }
    final level = _asInt(map['level'], fallback: -1);
    if (level < 0) {
      return null;
    }
    return (level: level, charging: _asBool(map['charging']));
  }

  /// OS 標準の音声合成で読み上げる（C19）。
  Future<void> speak(String text, {double rate = 0.8}) async {
    await _guard<Object?>(
      'speak',
      () => _methods.invokeMethod<Object?>('speak', <String, Object?>{
        'text': text,
        'rate': rate,
      }),
    );
  }

  /// 読み上げを止める。
  Future<void> stopSpeaking() async {
    await _guard<Object?>(
      'stopSpeaking',
      () => _methods.invokeMethod<Object?>('stopSpeaking'),
    );
  }

  /// 確認通知を [at] に予約する（1 回限り。アプリを開くたびに予約し直す、C07）。
  Future<void> scheduleMonthlyReminder({
    required String title,
    required String body,
    required DateTime at,
  }) async {
    await _guard<Object?>(
      'scheduleReminder',
      () => _methods.invokeMethod<Object?>('scheduleReminder', <String, Object?>{
        'title': title,
        'body': body,
        'at': at.toUtc().millisecondsSinceEpoch,
      }),
    );
  }

  /// 月 1 回の確認通知を取り消す。
  Future<void> cancelMonthlyReminder() async {
    await _guard<Object?>(
      'cancelReminder',
      () => _methods.invokeMethod<Object?>('cancelReminder'),
    );
  }

  /// ネイティブ購読を解除し、イベントストリームを閉じる。
  Future<void> dispose() async {
    _disposed = true;
    await _nativeSubscription?.cancel();
    _nativeSubscription = null;
    await _events.close();
  }

  // ------------------------------------------------------------------ 内部

  void _subscribeNative() {
    if (_disposed || _nativeSubscription != null) {
      return;
    }
    _nativeSubscription = _eventChannel.receiveBroadcastStream().listen(
      _onNativeEvent,
      onError: (Object error) {
        _log('イベント受信エラー: ${_describe(error)}');
      },
      onDone: () {
        _nativeSubscription = null;
      },
    );
  }

  void _onNativeEvent(Object? event) {
    final parsed = parseEvent(event);
    if (parsed == null) {
      _log('不明なイベント: $event');
      return;
    }
    _emit(parsed);
  }

  /// ネイティブから届いた Map を [TransportEvent] に変換する。
  /// 形式が不正なら null。
  static TransportEvent? parseEvent(Object? event) {
    if (event is! Map) {
      return null;
    }
    final map = event.cast<Object?, Object?>();
    switch (_asString(map['type'])) {
      case 'state':
        return TransportState(
          poweredOn: _asBool(map['poweredOn']),
          scanning: _asBool(map['scanning']),
          advertising: _asBool(map['advertising']),
          permission: _asString(map['permission'], fallback: 'unknown'),
        );
      case 'discovered':
        final peerId = _asString(map['peerId']);
        if (peerId.isEmpty) {
          return null;
        }
        return PeerDiscovered(
          peerId: peerId,
          rssi: _asInt(map['rssi']),
          viaApple: _asBool(map['viaApple']),
        );
      case 'linkOpened':
        return LinkOpened(
          linkId: _asInt(map['linkId']),
          peerId: _asString(map['peerId']),
          maxChunk: _asInt(map['maxChunk']),
          initiator: _asBool(map['initiator']),
        );
      case 'data':
        return LinkData(
          linkId: _asInt(map['linkId']),
          data: _asBytes(map['data']),
        );
      case 'linkClosed':
        final peerId = _asString(map['peerId']);
        return LinkClosed(
          linkId: _asInt(map['linkId']),
          peerId: peerId.isEmpty ? null : peerId,
          reason: _asString(map['reason']),
        );
      case 'log':
        return TransportLog(_asString(map['message']));
      default:
        return null;
    }
  }

  Future<T?> _guard<T>(
    String method,
    Future<T> Function() call, {
    bool rethrowOnError = false,
  }) async {
    try {
      return await call();
    } on PlatformException catch (e) {
      _log('$method 失敗: ${e.code}'
          '${e.message == null || e.message!.isEmpty ? '' : ' ${e.message}'}');
      if (rethrowOnError) {
        rethrow;
      }
      return null;
    } on MissingPluginException {
      _log('$method: この環境ではネイティブ BLE を使えません');
      if (rethrowOnError) {
        rethrow;
      }
      return null;
    }
  }

  void _log(String message) => _emit(TransportLog(message));

  void _emit(TransportEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  static String _describe(Object error) {
    if (error is PlatformException) {
      return '${error.code} ${error.message ?? ''}'.trim();
    }
    return error.toString();
  }

  static Uint8List _asUint8List(List<int> bytes) =>
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

  static Uint8List _asBytes(Object? value) {
    if (value is Uint8List) {
      return value;
    }
    if (value is List) {
      return Uint8List.fromList(value.cast<int>());
    }
    return Uint8List(0);
  }

  static int _asInt(Object? value, {int fallback = 0}) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return fallback;
  }

  static bool _asBool(Object? value, {bool fallback = false}) =>
      value is bool ? value : fallback;

  static String _asString(Object? value, {String fallback = ''}) =>
      value is String ? value : fallback;
}
