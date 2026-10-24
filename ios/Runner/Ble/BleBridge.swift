import AVFoundation
import CoreBluetooth
#if os(macOS)
import AppKit
import FlutterMacOS
#else
import AudioToolbox
import Flutter
import UIKit
#endif

/// Dart ↔ ネイティブの橋渡し。
///
/// MethodChannel `jp.kairanban/ble` と EventChannel `jp.kairanban/ble/events` を
/// docs/03_architecture.md §3 の契約どおりに実装する。Live Activity の出し入れ（iOS のみ）もここで行う。
/// iOS と macOS で同じソースをコンパイルする（macOS 側は macos/Runner.xcodeproj からこのファイルを参照）。
/// Dart 側がイベントの購読を始める前に起きたイベントはバッファし、購読開始時にまとめて流す。
/// このクラスのメソッドはメインスレッドで呼ばれる（Flutter の platform channel の規約）。
final class BleBridge: NSObject, FlutterStreamHandler {
  static let methodChannelName = "jp.kairanban/ble"
  static let eventChannelName = "jp.kairanban/ble/events"

  /// 購読前にためておくイベントの上限（超えたら古いものから捨てる）。
  private static let bufferLimit = 4096

  private let engine: BleEngine
  #if os(iOS)
  /// Live Activity（iOS 16.1 以上）。start で出し、stop で消す。macOS には無い。
  private let liveActivity = LiveActivityController()
  #endif
  /// 新しいお知らせのローカル通知。
  private let noticeNotifier = NoticeNotifier()
  /// 画面点灯・交換完了の音・電池・読み上げ。
  private let device = DeviceActions()
  private let methodChannel: FlutterMethodChannel
  private let eventChannel: FlutterEventChannel

  /// Dart 側のシンク。メインスレッドでのみ触る。
  private var sink: FlutterEventSink?
  /// シンクが付くまでのバッファ。メインスレッドでのみ触る。
  private var buffer: [[String: Any]] = []

  init(messenger: FlutterBinaryMessenger, engine: BleEngine) {
    self.engine = engine
    methodChannel = FlutterMethodChannel(name: BleBridge.methodChannelName, binaryMessenger: messenger)
    eventChannel = FlutterEventChannel(name: BleBridge.eventChannelName, binaryMessenger: messenger)
    super.init()
    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    eventChannel.setStreamHandler(self)
    engine.setEventHandler { [weak self] event in
      let map = BleBridge.encode(event)
      DispatchQueue.main.async { self?.deliver(map) }
    }
  }

  // MARK: - イベント

  private static func encode(_ event: BleEvent) -> [String: Any] {
    switch event {
    case .state(let poweredOn, let scanning, let advertising, let permission):
      return [
        "type": "state",
        "poweredOn": poweredOn,
        "scanning": scanning,
        "advertising": advertising,
        "permission": permission,
      ]
    case .discovered(let peerId, let rssi, let viaApple):
      return ["type": "discovered", "peerId": peerId, "rssi": rssi, "viaApple": viaApple]
    case .linkOpened(let linkId, let peerId, let maxChunk, let initiator):
      return [
        "type": "linkOpened",
        "linkId": linkId,
        "peerId": peerId,
        "maxChunk": maxChunk,
        "initiator": initiator,
      ]
    case .data(let linkId, let data):
      return ["type": "data", "linkId": linkId, "data": FlutterStandardTypedData(bytes: data)]
    case .linkClosed(let linkId, let peerId, let reason):
      return ["type": "linkClosed", "linkId": linkId, "peerId": peerId, "reason": reason]
    case .log(let message):
      return ["type": "log", "message": message]
    }
  }

  private func deliver(_ map: [String: Any]) {
    if let sink = sink {
      sink(map)
    } else {
      buffer.append(map)
      if buffer.count > BleBridge.bufferLimit {
        buffer.removeFirst(buffer.count - BleBridge.bufferLimit)
      }
    }
  }

  // MARK: FlutterStreamHandler

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    let pending = buffer
    buffer.removeAll()
    for map in pending {
      events(map)
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  // MARK: - メソッド

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "getState":
      let state = engine.snapshot()
      result([
        "supported": state.supported,
        "poweredOn": state.poweredOn,
        "permission": state.permission,
        "running": state.running,
      ])

    case "requestPermissions":
      engine.requestPermissions { granted in
        DispatchQueue.main.async { result(granted) }
      }

    case "start":
      guard let serviceUuid = BleBridge.parseUUID(args["serviceUuid"]),
        let rxUuid = BleBridge.parseUUID(args["rxUuid"]),
        let txUuid = BleBridge.parseUUID(args["txUuid"])
      else {
        result(FlutterError(code: "badArgs", message: "UUID が不正です", details: nil))
        return
      }
      let nodeId = (args["nodeId"] as? FlutterStandardTypedData)?.data ?? Data()
      let lowPower = args["lowPower"] as? Bool ?? false
      engine.start(serviceUUID: serviceUuid, rxUUID: rxUuid, txUUID: txUuid, nodeId: nodeId, lowPower: lowPower)
      #if os(iOS)
      liveActivity.start()
      #endif
      result(nil)

    case "stop":
      engine.stop()
      #if os(iOS)
      liveActivity.stop()
      #endif
      result(nil)

    case "noteReceived":
      // お知らせを受け取った（Unix ミリ秒）。Live Activity の「最後に受け取った時刻」に使う（iOS のみ）
      #if os(iOS)
      let at: Date
      if let millis = args["at"] as? Int {
        at = Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
      } else if let millis = args["at"] as? Double {
        at = Date(timeIntervalSince1970: millis / 1000)
      } else {
        at = Date()
      }
      liveActivity.noteReceived(at: at)
      #endif
      result(nil)

    case "setLowPower":
      engine.setLowPower(args["lowPower"] as? Bool ?? false)
      result(nil)

    case "connect":
      guard let peerId = args["peerId"] as? String else {
        result(FlutterError(code: "badArgs", message: "peerId がありません", details: nil))
        return
      }
      engine.connect(peerId: peerId)
      result(nil)

    case "send":
      guard let linkId = args["linkId"] as? Int,
        let data = (args["data"] as? FlutterStandardTypedData)?.data
      else {
        result(FlutterError(code: "badArgs", message: "linkId または data がありません", details: nil))
        return
      }
      engine.send(linkId: linkId, data: data) { error in
        DispatchQueue.main.async {
          if let error = error as? BleError {
            result(FlutterError(code: error.code, message: error.message, details: nil))
          } else if let error = error {
            result(FlutterError(code: "sendFailed", message: error.localizedDescription, details: nil))
          } else {
            result(nil)
          }
        }
      }

    case "close":
      guard let linkId = args["linkId"] as? Int else {
        result(FlutterError(code: "badArgs", message: "linkId がありません", details: nil))
        return
      }
      engine.close(linkId: linkId)
      result(nil)

    case "requestBatteryOptimizationExemption":
      // iOS / macOS には該当する設定がない
      result(true)

    case "requestNotificationPermission":
      noticeNotifier.requestPermission { granted in
        result(granted)
      }

    case "showNotice":
      guard let id = args["id"] as? Int, let title = args["title"] as? String else {
        result(FlutterError(code: "badArgs", message: "id または title がありません", details: nil))
        return
      }
      let body = args["body"] as? String ?? ""
      let groupCode = args["groupCode"] as? Int ?? 0
      let importance = args["importance"] as? String ?? "important"
      let msgId = args["msgId"] as? Int
      noticeNotifier.show(
        id: id, title: title, body: body, groupCode: groupCode, importance: importance, msgId: msgId)
      result(nil)

    case "cancelNotice":
      if let id = args["id"] as? Int {
        noticeNotifier.cancel(id: id)
      }
      result(nil)

    case "setKeepScreenOn":
      device.setKeepScreenOn(args["on"] as? Bool ?? false)
      result(nil)

    case "playChime":
      device.playChime()
      result(nil)

    case "getBattery":
      result(device.battery())

    case "speak":
      device.speak(args["text"] as? String ?? "", rate: args["rate"] as? Double ?? 0.8)
      result(nil)

    case "stopSpeaking":
      device.stopSpeaking()
      result(nil)

    case "scheduleReminder":
      let title = args["title"] as? String ?? ""
      let body = args["body"] as? String ?? ""
      let at: Date
      if let millis = args["at"] as? Int {
        at = Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
      } else if let millis = args["at"] as? Double {
        at = Date(timeIntervalSince1970: millis / 1000)
      } else {
        at = Date().addingTimeInterval(30 * 24 * 3600)
      }
      noticeNotifier.scheduleReminder(title: title, body: body, at: at)
      result(nil)

    case "cancelReminder":
      noticeNotifier.cancelReminder()
      result(nil)

    case "openAppSettings":
      #if os(macOS)
      // システム設定 → プライバシーとセキュリティ → Bluetooth を開く
      if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
        NSWorkspace.shared.open(url)
      }
      #else
      if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
      }
      #endif
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Dart から来た UUID 文字列を CBUUID にする。不正な文字列で CBUUID が例外を投げないよう事前に検証する。
  private static func parseUUID(_ value: Any?) -> CBUUID? {
    guard let text = value as? String else { return nil }
    if UUID(uuidString: text) != nil {
      return CBUUID(string: text)
    }
    // 16/32 ビットの短縮形（"180A" など）も許容する
    let short = text.uppercased()
    let isHex = short.allSatisfy { $0.isHexDigit }
    if isHex && (short.count == 4 || short.count == 8) {
      return CBUUID(string: short)
    }
    return nil
  }
}

/// 画面点灯・交換完了の音・電池・読み上げ（docs/03 §3、docs/08 C04 C06 C19）。メインスレッドで使う。
final class DeviceActions: NSObject {
  private let synthesizer = AVSpeechSynthesizer()
  #if os(macOS)
  private var activity: NSObjectProtocol?
  #endif

  /// 画面を消さない（中継役・「30 分 画面を 点けたままにする」）。
  func setKeepScreenOn(_ on: Bool) {
    #if os(iOS)
    UIApplication.shared.isIdleTimerDisabled = on
    #else
    if on {
      if activity == nil {
        activity = ProcessInfo.processInfo.beginActivity(
          options: [.idleDisplaySleepDisabled, .userInitiated], reason: "回覧板 中継役")
      }
    } else if let current = activity {
      ProcessInfo.processInfo.endActivity(current)
      activity = nil
    }
    #endif
  }

  /// 交換完了の短い音と振動。
  func playChime() {
    #if os(iOS)
    AudioServicesPlaySystemSound(1007)
    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    #else
    NSSound.beep()
    #endif
  }

  /// 電池残量（0..100）と充電中か。取れなければ nil。
  func battery() -> [String: Any]? {
    #if os(iOS)
    let device = UIDevice.current
    device.isBatteryMonitoringEnabled = true
    let level = device.batteryLevel
    if level < 0 {
      return nil
    }
    let charging = device.batteryState == .charging || device.batteryState == .full
    return ["level": Int((level * 100).rounded()), "charging": charging]
    #else
    return nil
    #endif
  }

  /// OS 標準の音声合成（ja-JP）で読み上げる。[rate] は既定の速さに対する倍率。
  func speak(_ text: String, rate: Double) {
    guard !text.isEmpty else { return }
    if synthesizer.isSpeaking {
      synthesizer.stopSpeaking(at: .immediate)
    }
    #if os(iOS)
    try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
    try? AVAudioSession.sharedInstance().setActive(true)
    #endif
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(rate)
    synthesizer.speak(utterance)
  }

  func stopSpeaking() {
    synthesizer.stopSpeaking(at: .immediate)
  }
}
