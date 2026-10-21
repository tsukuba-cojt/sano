import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// BLE エンジン。状態復元（willRestoreState）が働くよう、Flutter エンジンより先に
  /// didFinishLaunching 内で生成する。
  private(set) var bleEngine: BleEngine?
  private var bleBridge: BleBridge?

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
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let engine = bleEngine,
      let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "jp.kairanban.BleBridge")
    else { return }
    bleBridge = BleBridge(messenger: registrar.messenger(), engine: engine)
  }
}
