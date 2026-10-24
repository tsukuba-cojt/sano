import Cocoa
import FlutterMacOS

/// メインウィンドウ。Flutter の画面を載せ、BLE エンジンとブリッジ（ios/Runner/Ble を共用）を生成して保持する。
class MainFlutterWindow: NSWindow {
  /// スマートフォンに近い既定サイズと最小サイズ（ポイント）。
  private static let defaultContentSize = NSSize(width: 430, height: 900)
  private static let minimumContentSize = NSSize(width: 360, height: 640)

  /// BLE エンジンとブリッジ。ウィンドウと同じ寿命で保持する。
  private var bleEngine: BleEngine?
  private var bleBridge: BleBridge?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // macOS には状態復元が無いので、復元識別子なしで生成する（権限が未決定なら requestPermissions まで待つ）
    let engine = BleEngine()
    bleEngine = engine
    bleBridge = BleBridge(messenger: flutterViewController.engine.binaryMessenger, engine: engine)

    // 閉じても解放しない（アプリは動き続け、Dock から開き直す）。
    isReleasedWhenClosed = false
    contentMinSize = MainFlutterWindow.minimumContentSize
    setContentSize(MainFlutterWindow.defaultContentSize)
    center()

    super.awakeFromNib()
  }
}
