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
    if launchedForBluetooth && application.applicationState == .background {
      startBackgroundEngine()
    }
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

  private func stopBackgroundEngine() {
    guard let engine = backgroundEngine else { return }
    bleBridge = nil
    engine.destroyContext()
    backgroundEngine = nil
  }
}
