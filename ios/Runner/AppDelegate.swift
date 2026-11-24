import CoreLocation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// BLE エンジン。状態復元（willRestoreState）が働くよう、Flutter エンジンより先に
  /// didFinishLaunching 内で生成する。
  private(set) var bleEngine: BleEngine?
  private var bleBridge: BleBridge?

  /// iOS がアプリを終了させたあと、Bluetooth の出来事でバックグラウンド起動されたときに
  /// 動かす画面なしの Flutter エンジン。このときはシーンがつながらず暗黙のエンジンが作られない
  /// ため、これが無いと Dart（すれ違いの同期）が動かず、メッセージが中継されない。
  /// 利用者が開いて画面のエンジンができたら止める（同じ保存ファイルを 2 つで触らない）。
  private var backgroundEngine: FlutterEngine?

  /// 近くの Android などが出す iBeacon で、終了したアプリを起こし直す（「アプリを 閉じても 受け取る」）。
  /// 位置情報の「常に」が許可されているときだけ働く。起動のたびに作らないと領域の出来事を受け取れない。
  let beaconWake = BeaconWake()
  private var wakeTask: UIBackgroundTaskIdentifier = .invalid

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // 復元起動で渡される識別子はログ用。マネージャ自体は常に固定の識別子
    // （jp.kairanban.central / jp.kairanban.peripheral）で初期化する。
    let restoredCentrals = launchOptions?[.bluetoothCentrals] as? [String] ?? []
    let restoredPeripherals = launchOptions?[.bluetoothPeripherals] as? [String] ?? []
    bleEngine = BleEngine(
      restoredCentralIdentifiers: restoredCentrals,
      restoredPeripheralIdentifiers: restoredPeripherals)
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    let launchedForBluetooth = !restoredCentrals.isEmpty || !restoredPeripherals.isEmpty
    let launchedForLocation = launchOptions?[.location] != nil
    if (launchedForBluetooth || launchedForLocation) && application.applicationState == .background {
      startBackgroundEngine()
    }
    beaconWake.onWake = { [weak self] in self?.wokenByBeacon() }
    return result
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    stopBackgroundEngine()
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let engine = bleEngine,
      let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "jp.kairanban.BleBridge")
    else { return }
    bleBridge = BleBridge(messenger: registrar.messenger(), engine: engine)
  }

  /// 画面なしのエンジンで main() を動かし、BLE ブリッジをつなぐ。
  private func startBackgroundEngine() {
    guard backgroundEngine == nil, let ble = bleEngine else { return }
    let engine = FlutterEngine(name: "jp.kairanban.background", project: nil, allowHeadlessExecution: true)
    guard engine.run() else { return }
    GeneratedPluginRegistrant.register(with: engine)
    bleBridge = BleBridge(messenger: engine.binaryMessenger, engine: ble)
    backgroundEngine = engine
  }

  /// iBeacon の領域に入った。画面のエンジンも画面なしのエンジンも無ければ（終了していた）、
  /// 画面なしのエンジンで Dart を動かし、すれ違いの交換を始める。起動と最初の交換の間だけ
  /// 背面の実行時間をもらう（その後は Bluetooth の出来事で起こされる）。
  private func wokenByBeacon() {
    let application = UIApplication.shared
    guard application.applicationState == .background else { return }
    if bleBridge == nil {
      startBackgroundEngine()
    }
    guard wakeTask == .invalid else { return }
    wakeTask = application.beginBackgroundTask(withName: "jp.kairanban.beacon") { [weak self] in
      self?.endWakeTask()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
      self?.endWakeTask()
    }
  }

  private func endWakeTask() {
    guard wakeTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(wakeTask)
    wakeTask = .invalid
  }

  private func stopBackgroundEngine() {
    guard let engine = backgroundEngine else { return }
    bleBridge = nil
    engine.destroyContext()
    backgroundEngine = nil
  }
}

/// 回覧板の iBeacon（docs/02_protocol.md §1）の領域を見張る。
///
/// iOS は、利用者が上に払って終了したアプリを Bluetooth の出来事では起こさないが、
/// 領域の監視（位置情報の「常に」）では起こし直す。Android の端末は iBeacon も出しているので、
/// 近づくとこのアプリが起動し、画面なしのエンジンで交換する。電池への影響は小さい
/// （OS が見張るので、アプリは起きていない）。
final class BeaconWake: NSObject, CLLocationManagerDelegate {
  static let uuid = UUID(uuidString: "D6F98894-6EFB-4826-8E17-F7DD7152327A")!

  private let manager = CLLocationManager()
  private var pending: [(String) -> Void] = []

  /// 領域に入った（または画面を点けたときに中にいた）。
  var onWake: (() -> Void)?

  override init() {
    super.init()
    manager.delegate = self
    startMonitoringIfAllowed()
  }

  /// "always"（働く）/ "whenInUse"（「常に」が要る）/ "denied" / "notDetermined" / "unavailable"
  var status: String {
    guard CLLocationManager.isMonitoringAvailable(for: CLBeaconRegion.self) else { return "unavailable" }
    switch manager.authorizationStatus {
    case .authorizedAlways: return "always"
    case .authorizedWhenInUse: return "whenInUse"
    case .denied, .restricted: return "denied"
    default: return "notDetermined"
    }
  }

  /// 「常に」の許可を求める。まだ聞いていなければ OS が聞き、終わったら状態を返す。
  /// 「使用中のみ」から「常に」へは、OS が一度だけ聞く（断られていれば設定を開く必要がある）。
  func requestAlways(_ completion: @escaping (String) -> Void) {
    switch manager.authorizationStatus {
    case .notDetermined, .authorizedWhenInUse:
      pending.append(completion)
      manager.requestAlwaysAuthorization()
      // 「使用中のみ」から変わらない（もう聞けない）場合に備えて待ちすぎない。
      DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.flush() }
    default:
      completion(status)
    }
  }

  private func flush() {
    let callbacks = pending
    pending.removeAll()
    callbacks.forEach { $0(status) }
  }

  private func startMonitoringIfAllowed() {
    guard manager.authorizationStatus == .authorizedAlways,
      CLLocationManager.isMonitoringAvailable(for: CLBeaconRegion.self)
    else { return }
    let region = CLBeaconRegion(uuid: BeaconWake.uuid, identifier: "jp.kairanban.beacon")
    region.notifyOnEntry = true
    region.notifyOnExit = true
    region.notifyEntryStateOnDisplay = true
    manager.startMonitoring(for: region)
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    startMonitoringIfAllowed()
    if manager.authorizationStatus != .notDetermined {
      flush()
    }
  }

  func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
    if state == .inside {
      onWake?()
    }
  }

  func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
    onWake?()
  }
}
