import CoreBluetooth
import Foundation
import os
#if os(iOS)
import UIKit
#endif

/// ネイティブ BLE エンジンが Dart へ流すイベント（docs/03_architecture.md §3 のイベント表に対応）。
enum BleEvent {
  case state(poweredOn: Bool, scanning: Bool, advertising: Bool, permission: String)
  case discovered(peerId: String, rssi: Int, viaApple: Bool)
  case linkOpened(linkId: Int, peerId: String, maxChunk: Int, initiator: Bool)
  case data(linkId: Int, data: Data)
  case linkClosed(linkId: Int, peerId: String, reason: String)
  case log(message: String)
}

/// `send` などが失敗したときに Dart へ返すエラー。
struct BleError: Error {
  let code: String
  let message: String
}

/// 回覧板の BLE エンジン（iOS / macOS 共用）。
///
/// CBCentralManager（発見・接続・RX への書き込み）と CBPeripheralManager（広告・RX/TX の提供）を
/// 1 本の直列キュー上で動かす。docs/03_architecture.md §3「ネイティブ側の責務」と §4 に従う。
/// macOS には状態復元（復元識別子・willRestoreState）が無いため、その部分だけ `#if os(iOS)` で外す。
/// 一度リンクが開いた相手には切断後も接続待ち（pending connect）を出し直し、両方の画面が消えた
/// バックグラウンドでも圏内に戻れば OS が自動で接続するようにする（`KnownPeer`）。
/// 公開メソッドはどのスレッドから呼んでもよい（内部で `queue` へ移す）。
/// `onEvent` は `queue` 上で呼ばれる。
final class BleEngine: NSObject {
  // MARK: - 定数

  /// 状態復元用の識別子。起動のたびに同じ値を使う。
  static let centralRestoreIdentifier = "jp.kairanban.central"
  static let peripheralRestoreIdentifier = "jp.kairanban.peripheral"

  /// docs/02_protocol.md §1 の既定 UUID。Dart の `start` が届く前（状態復元時）に使う。
  static let defaultServiceUUID = CBUUID(string: "6B616972-616E-4B41-4952-414E00000010")
  static let defaultRxUUID = CBUUID(string: "6B616972-616E-4B41-4952-414E00000011")
  static let defaultTxUUID = CBUUID(string: "6B616972-616E-4B41-4952-414E00000012")

  /// `connect` のタイムアウト（iOS の connect は自然にはタイムアウトしない）。
  private static let connectTimeout: TimeInterval = 10
  /// 発見した peripheral の強参照を保持する期間。
  private static let discoveredExpiry: TimeInterval = 5 * 60
  /// 同じ peerId の `discovered` 通知を間引く間隔。
  private static let discoveredThrottle: TimeInterval = 2
  /// 権限ダイアログの結果を待つ上限。
  private static let permissionPollLimit: TimeInterval = 3
  /// 「最近つながった相手」を保持する期間。iPhone の BLE アドレスは約 15 分で回転するため、
  /// それより少し長い程度にとどめる（回転後の接続待ちは相手に届かない）。
  private static let knownPeerExpiry: TimeInterval = 20 * 60
  /// 「最近つながった相手」の上限。
  private static let knownPeerLimit = 4
  /// 切断後に接続待ちを出し直すまでの間隔。Dart 側の再同期間隔（60 秒）に合わせ、
  /// 圏内に居続ける相手と数秒おきに接続と切断を繰り返さないようにする。
  private static let knownPeerReconnectDelay: TimeInterval = 60
  /// 背面のときの接続待ちの出し直し間隔。背面のアプリは最後の BLE イベントから約 10 秒で
  /// 止まるため、バックグラウンドタスクで延ばせる範囲（約 30 秒）に収める。
  private static let backgroundReconnectDelay: TimeInterval = 20
  /// 背面でスキャンをかけ直す間隔。背面のスキャンは同じ相手を 1 回しか知らせないので、
  /// BLE イベントで起きたときに古ければかけ直し、近くにいる相手を知らせ直させる。
  private static let backgroundScanRefresh: TimeInterval = 30
  /// Dart の start が届く前（状態復元の起動）にも動き続けるための保存キー。
  private static let savedRunningKey = "jp.kairanban.ble.running"
  private static let savedLowPowerKey = "jp.kairanban.ble.lowPower"
  private static let savedServiceKey = "jp.kairanban.ble.service"
  private static let savedRxKey = "jp.kairanban.ble.rx"
  private static let savedTxKey = "jp.kairanban.ble.tx"
  /// Dart がまだ受け取れないときに溜めておくイベントの上限。
  private static let pendingEventLimit = 1024

  // MARK: - 状態

  /// 現在状態のスナップショット（`getState` 用）。
  struct Snapshot {
    let supported: Bool
    let poweredOn: Bool
    let permission: String
    let running: Bool
  }

  /// イベント受け取り口。`queue` 上で呼ばれる。[setEventHandler] で設定する。
  private var onEvent: ((BleEvent) -> Void)?

  /// 受け取り口が無い間（状態復元で Flutter より先に動いたとき）のイベント。
  private var pendingEvents: [BleEvent] = []

  /// 最後にスキャンを始めた時刻。
  private var lastScanStart: Date?

  #if os(macOS)
  /// App Nap でタイマーが間引かれないようにする（動作中だけ）。
  private var activity: NSObjectProtocol?
  #endif

  /// 両マネージャ共通の直列キュー。
  let queue = DispatchQueue(label: "jp.kairanban.ble")
  private let logger = Logger(subsystem: "jp.kairanban", category: "ble")

  private var central: CBCentralManager?
  private var peripheralManager: CBPeripheralManager?

  private var serviceUUID = BleEngine.defaultServiceUUID
  private var rxUUID = BleEngine.defaultRxUUID
  private var txUUID = BleEngine.defaultTxUUID
  private var nodeId = Data()
  private var lowPower = false
  private var running = false

  /// 省電力の間欠スキャン（docs/08 C06）: 前面のとき 20 秒スキャン / 40 秒停止。
  /// 背面は OS の間引きに任せて連続スキャンのまま（suspend でタイマーが止まると「停止したまま」になるため）。
  private var scanPaused = false
  private var dutyTimer: DispatchSourceTimer?
  private var dutyTick = 0
  private var inForeground = true
  private static let dutyTickSeconds: TimeInterval = 20

  private var scanning = false
  private var advertising = false
  private var advertisingPending = false
  private var serviceAdded = false
  private var serviceAddPending = false

  private var nextLinkId = 1

  /// リンク ID から central 側 / peripheral 側のリンクを引く索引。
  private enum LinkRef {
    case central(UUID)
    case peripheral(UUID)
  }

  private var linkIndex: [Int: LinkRef] = [:]

  // MARK: central 側

  /// 自分が central として開いた（開こうとしている）リンク。
  private final class CentralLink {
    let linkId: Int
    let peripheral: CBPeripheral
    var rx: CBCharacteristic?
    var tx: CBCharacteristic?
    var opened = false
    var timer: DispatchSourceTimer?
    var pendingWrite: (data: Data, completion: (Error?) -> Void)?
    /// 前回の購読が残っていたので解除 → 再購読をしたか（1 回だけ）。
    var resubscribed = false

    init(linkId: Int, peripheral: CBPeripheral) {
      self.linkId = linkId
      self.peripheral = peripheral
    }
  }

  private struct DiscoveredEntry {
    let peripheral: CBPeripheral
    var lastSeen: Date
    var lastEmitted: Date?
  }

  /// 発見した peripheral（peripheral.identifier → エントリ）。強参照を保持しないと接続できない。
  private var discovered: [UUID: DiscoveredEntry] = [:]
  /// peripheral.identifier → リンク。
  private var centralLinks: [UUID: CentralLink] = [:]
  /// 状態復元で受け取った peripheral。poweredOn になってから処理する。
  private var restoredPeripherals: [CBPeripheral] = []

  /// 最近リンクが開いた相手。切断後も接続待ち（pending connect）を出し続けておくと、
  /// 両方の画面が消えたバックグラウンドでも、圏内に戻ってきたときに OS が自動で接続する
  /// （スキャンでは互いを発見できない iPhone 同士の緩和策）。
  private final class KnownPeer {
    let peripheral: CBPeripheral
    /// 最後にリンクが開いた時刻（上限を超えたら古いものから忘れる）。
    var lastLinked: Date
    var expiryTimer: DispatchSourceTimer?
    var reconnectTimer: DispatchSourceTimer?

    init(peripheral: CBPeripheral, lastLinked: Date) {
      self.peripheral = peripheral
      self.lastLinked = lastLinked
    }

    func cancelTimers() {
      expiryTimer?.cancel()
      expiryTimer = nil
      reconnectTimer?.cancel()
      reconnectTimer = nil
    }
  }

  /// peripheral.identifier → 最近つながった相手（最大 `knownPeerLimit` 台、`knownPeerExpiry` で期限切れ）。
  private var knownPeers: [UUID: KnownPeer] = [:]

  // MARK: peripheral 側

  /// 相手が central として開いたリンク。
  private final class PeripheralLink {
    let linkId: Int
    let central: CBCentral
    var pendingNotify: (data: Data, completion: (Error?) -> Void)?

    init(linkId: Int, central: CBCentral) {
      self.linkId = linkId
      self.central = central
    }
  }

  private var service: CBMutableService?
  private var rxCharacteristic: CBMutableCharacteristic?
  private var txCharacteristic: CBMutableCharacteristic?
  /// central.identifier → リンク。
  private var peripheralLinks: [UUID: PeripheralLink] = [:]
  /// こちら（Dart）側が閉じたリンクの central。購読状態が変わる（didSubscribeTo /
  /// didUnsubscribeFrom）まで、この central からの書き込みではリンクを開き直さない。
  /// 閉じた直後に届く相手の BYE や送信済みチャンクで幻のセッションが生まれるのを防ぐ。
  private var closedCentrals: Set<UUID> = []

  // MARK: - 生成

  /// - Parameters:
  ///   - restoredCentralIdentifiers: `UIApplicationLaunchOptionsBluetoothCentralsKey` の内容（復元起動なら非空）
  ///   - restoredPeripheralIdentifiers: `UIApplicationLaunchOptionsBluetoothPeripheralsKey` の内容
  init(restoredCentralIdentifiers: [String] = [], restoredPeripheralIdentifiers: [String] = []) {
    super.init()
    let restoring = !restoredCentralIdentifiers.isEmpty || !restoredPeripheralIdentifiers.isEmpty
    if restoring {
      logger.info("復元起動: centrals=\(restoredCentralIdentifiers, privacy: .public) peripherals=\(restoredPeripheralIdentifiers, privacy: .public)")
    }
    // 権限が未決定のうちにマネージャを作ると OS のダイアログが出てしまうので、
    // 初回は オンボーディングからの requestPermissions まで待つ。
    // 復元起動、または権限が決まっている場合は didFinishLaunching 中に作る（状態復元の条件）。
    if restoring || CBManager.authorization != .notDetermined {
      queue.sync {
        if restoring {
          restoreSavedRunningOnQueue()
        }
        ensureManagersOnQueue()
      }
    }
    #if os(iOS)
    inForeground = UIApplication.shared.applicationState == .active
    let center = NotificationCenter.default
    center.addObserver(
      self, selector: #selector(appDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification, object: nil)
    center.addObserver(
      self, selector: #selector(appWillResignActive),
      name: UIApplication.willResignActiveNotification, object: nil)
    #endif
  }

  #if os(iOS)
  @objc private func appDidBecomeActive() {
    queue.async {
      self.inForeground = true
      self.updateDutyCycle()
      // 前面では同じ相手を繰り返し知らせるスキャンに切り替える
      self.restartScan(reason: "前面")
    }
  }

  @objc private func appWillResignActive() {
    queue.async {
      self.inForeground = false
      self.updateDutyCycle()
      self.restartScan(reason: "背面")
    }
  }
  #endif

  /// 状態復元の起動で、前回 Dart が start したままなら、その設定で動き続ける
  /// （Dart の start を待たずに広告・スキャン・接続待ちを止めない）。
  private func restoreSavedRunningOnQueue() {
    let defaults = UserDefaults.standard
    guard defaults.bool(forKey: BleEngine.savedRunningKey) else { return }
    if let s = defaults.string(forKey: BleEngine.savedServiceKey) { serviceUUID = CBUUID(string: s) }
    if let s = defaults.string(forKey: BleEngine.savedRxKey) { rxUUID = CBUUID(string: s) }
    if let s = defaults.string(forKey: BleEngine.savedTxKey) { txUUID = CBUUID(string: s) }
    lowPower = defaults.bool(forKey: BleEngine.savedLowPowerKey)
    running = true
    logger.info("復元起動: 前回の動作中の設定で続ける")
  }

  private func saveRunning() {
    let defaults = UserDefaults.standard
    defaults.set(running, forKey: BleEngine.savedRunningKey)
    defaults.set(lowPower, forKey: BleEngine.savedLowPowerKey)
    defaults.set(serviceUUID.uuidString, forKey: BleEngine.savedServiceKey)
    defaults.set(rxUUID.uuidString, forKey: BleEngine.savedRxKey)
    defaults.set(txUUID.uuidString, forKey: BleEngine.savedTxKey)
  }

  /// イベントの受け取り口を設定する（どのスレッドからでもよい）。溜まっていたイベントを流す。
  func setEventHandler(_ handler: ((BleEvent) -> Void)?) {
    queue.async {
      self.onEvent = handler
      guard let handler = handler, !self.pendingEvents.isEmpty else { return }
      let events = self.pendingEvents
      self.pendingEvents.removeAll()
      for event in events {
        handler(event)
      }
    }
  }

  // MARK: - 公開 API（任意のスレッド）

  /// 現在状態を返す。
  func snapshot() -> Snapshot {
    return queue.sync {
      Snapshot(
        supported: central?.state != .unsupported,
        poweredOn: central?.state == .poweredOn,
        permission: BleEngine.permissionString(),
        running: running)
    }
  }

  /// CoreBluetooth の権限を要求する（マネージャ生成で OS ダイアログが出る）。
  /// 結果が出るまで最大 3 秒待ち、`allowedAlways` なら true。`completion` は `queue` 上で呼ばれる。
  func requestPermissions(completion: @escaping (Bool) -> Void) {
    queue.async {
      self.ensureManagersOnQueue()
      self.pollAuthorization(deadline: Date().addingTimeInterval(BleEngine.permissionPollLimit), completion: completion)
    }
  }

  /// 広告 + GATT サーバ + スキャンを開始する。何度呼んでもよい。
  func start(serviceUUID: CBUUID, rxUUID: CBUUID, txUUID: CBUUID, nodeId: Data, lowPower: Bool) {
    queue.async {
      self.serviceUUID = serviceUUID
      self.rxUUID = rxUUID
      self.txUUID = txUUID
      self.nodeId = nodeId
      self.lowPower = lowPower
      if self.running {
        self.log("start: すでに動作中")
        self.emitState()
        return
      }
      self.running = true
      self.saveRunning()
      #if os(macOS)
      if self.activity == nil {
        self.activity = ProcessInfo.processInfo.beginActivity(
          options: [.userInitiatedAllowingIdleSystemSleep],
          reason: "回覧板のすれ違い通信")
      }
      #endif
      self.ensureManagersOnQueue()
      self.updateScanning()
      self.updateDutyCycle()
      self.updatePeripheral()
      self.ensurePendingConnectsForKnownPeers()
      self.emitState()
      self.log("start: lowPower=\(lowPower)")
    }
  }

  /// すべて停止する。何度呼んでもよい。
  func stop() {
    queue.async { self.stopOnQueue() }
  }

  /// 省電力モードを切り替える。iOS のスキャンに省電力の設定はないため、前面では
  /// 20 秒スキャン / 40 秒停止の間欠にする（広告と既知ピアの接続待ちは続ける、C06）。
  func setLowPower(_ value: Bool) {
    queue.async {
      self.lowPower = value
      self.log("lowPower=\(value)")
      self.updateDutyCycle()
    }
  }

  /// 間欠スキャンのタイマーを状態に合わせて始める / 止める（queue 上）。
  private func updateDutyCycle() {
    let wantCycle = lowPower && running && inForeground
    if wantCycle {
      if dutyTimer == nil {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        dutyTick = 0
        timer.schedule(
          deadline: .now() + BleEngine.dutyTickSeconds, repeating: BleEngine.dutyTickSeconds)
        timer.setEventHandler { [weak self] in self?.onDutyTick() }
        timer.resume()
        dutyTimer = timer
        log("scan: 間欠（20 秒 / 40 秒）を始める")
      }
    } else if dutyTimer != nil {
      dutyTimer?.cancel()
      dutyTimer = nil
      if scanPaused {
        scanPaused = false
        updateScanning()
      }
      log("scan: 間欠をやめる")
    }
  }

  /// 20 秒ごとのティック。0→20 秒スキャン、20→60 秒停止、を繰り返す。
  private func onDutyTick() {
    dutyTick += 1
    let phase = dutyTick % 3
    if phase == 1 && !scanPaused {
      scanPaused = true
      updateScanning()
    } else if phase == 0 && scanPaused {
      scanPaused = false
      updateScanning()
    }
  }

  /// スキャンをかけ直す（重複の設定を変える・近くの相手を知らせ直させる）。
  private func restartScan(reason: String) {
    guard scanning, let central = central, central.state == .poweredOn else { return }
    central.stopScan()
    scanning = false
    log("scan: かけ直し（\(reason)）")
    updateScanning()
  }

  /// 背面で BLE イベントにより起きたとき、スキャンが古ければかけ直す。
  private func refreshScanIfStale() {
    guard running, !inForeground, scanning else { return }
    if let last = lastScanStart, Date().timeIntervalSince(last) < BleEngine.backgroundScanRefresh {
      return
    }
    restartScan(reason: "背面の知らせ直し")
  }

  /// `peerId` へ接続する。結果は linkOpened / linkClosed で通知する。
  func connect(peerId: String) {
    queue.async { self.connectOnQueue(peerId: peerId) }
  }

  /// 1 チャンクを送る。スタックに渡し終えたら `completion(nil)`（`queue` 上）。
  func send(linkId: Int, data: Data, completion: @escaping (Error?) -> Void) {
    queue.async { self.sendOnQueue(linkId: linkId, data: data, completion: completion) }
  }

  /// リンクを閉じる。
  func close(linkId: Int) {
    queue.async {
      guard let ref = self.linkIndex[linkId] else { return }
      switch ref {
      case .central(let id):
        if let link = self.centralLinks[id] { self.closeCentralLink(link, reason: "closed") }
      case .peripheral(let id):
        if let link = self.peripheralLinks[id] { self.closePeripheralLink(link, reason: "closed") }
      }
    }
  }

  // MARK: - 権限

  static func permissionString() -> String {
    switch CBManager.authorization {
    case .allowedAlways:
      return "granted"
    case .denied, .restricted:
      return "denied"
    case .notDetermined:
      return "unknown"
    @unknown default:
      return "unknown"
    }
  }

  private func pollAuthorization(deadline: Date, completion: @escaping (Bool) -> Void) {
    let authorization = CBManager.authorization
    if authorization != .notDetermined || Date() >= deadline {
      completion(authorization == .allowedAlways)
      return
    }
    queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      self?.pollAuthorization(deadline: deadline, completion: completion)
    }
  }

  // MARK: - 内部（queue 上）

  private func ensureManagersOnQueue() {
    if central == nil {
      #if os(iOS)
      let centralOptions: [String: Any] = [
        CBCentralManagerOptionRestoreIdentifierKey: BleEngine.centralRestoreIdentifier,
        CBCentralManagerOptionShowPowerAlertKey: false,
      ]
      #else
      // macOS には状態復元が無いので復元識別子は渡さない
      let centralOptions: [String: Any] = [CBCentralManagerOptionShowPowerAlertKey: false]
      #endif
      central = CBCentralManager(delegate: self, queue: queue, options: centralOptions)
    }
    if peripheralManager == nil {
      #if os(iOS)
      let peripheralOptions: [String: Any] = [
        CBPeripheralManagerOptionRestoreIdentifierKey: BleEngine.peripheralRestoreIdentifier
      ]
      #else
      let peripheralOptions: [String: Any] = [:]
      #endif
      peripheralManager = CBPeripheralManager(delegate: self, queue: queue, options: peripheralOptions)
    }
  }

  private func allocateLinkId() -> Int {
    let id = nextLinkId
    nextLinkId += 1
    return id
  }

  private func emit(_ event: BleEvent) {
    if let handler = onEvent {
      handler(event)
      return
    }
    if case .log = event { return }
    pendingEvents.append(event)
    if pendingEvents.count > BleEngine.pendingEventLimit {
      pendingEvents.removeFirst(pendingEvents.count - BleEngine.pendingEventLimit)
    }
  }

  private func emitState() {
    emit(.state(
      poweredOn: central?.state == .poweredOn,
      scanning: scanning,
      advertising: advertising,
      permission: BleEngine.permissionString()))
  }

  /// os.Logger に記録し、短いログを Dart へも流す。
  private func log(_ message: String) {
    logger.info("\(message, privacy: .public)")
    emit(.log(message: message))
  }

  private func stopOnQueue() {
    let wasRunning = running
    running = false
    if wasRunning {
      saveRunning()
    }
    #if os(macOS)
    if let activity = activity {
      ProcessInfo.processInfo.endActivity(activity)
      self.activity = nil
    }
    #endif
    dutyTimer?.cancel()
    dutyTimer = nil
    scanPaused = false
    for link in Array(centralLinks.values) {
      closeCentralLink(link, reason: "stopped")
    }
    for link in Array(peripheralLinks.values) {
      closePeripheralLink(link, reason: "stopped")
    }
    closedCentrals.removeAll()
    forgetAllKnownPeers()
    restoredPeripherals.removeAll()
    if let central = central, central.state == .poweredOn, central.isScanning {
      central.stopScan()
    }
    scanning = false
    if let manager = peripheralManager, manager.state == .poweredOn {
      if manager.isAdvertising || advertisingPending {
        manager.stopAdvertising()
      }
      if serviceAdded || serviceAddPending {
        manager.removeAllServices()
      }
    }
    advertising = false
    advertisingPending = false
    serviceAdded = false
    serviceAddPending = false
    service = nil
    rxCharacteristic = nil
    txCharacteristic = nil
    discovered.removeAll()
    emitState()
    if wasRunning {
      log("stop")
    }
  }

  // MARK: central: スキャン・接続

  private func updateScanning() {
    guard let central = central else { return }
    let shouldScan = running && central.state == .poweredOn && !scanPaused
    if shouldScan && !scanning {
      // 前面では同じ相手を繰り返し知らせる（間引きは didDiscover の 2 秒）。背面では OS が
      // 重複を落とすので false（かけ直しは refreshScanIfStale）。
      central.scanForPeripherals(
        withServices: [serviceUUID],
        options: [CBCentralManagerScanOptionAllowDuplicatesKey: inForeground])
      scanning = true
      lastScanStart = Date()
      log("scan: 開始")
    } else if !shouldScan && scanning {
      if central.state == .poweredOn {
        central.stopScan()
      }
      scanning = false
      log("scan: 停止")
    }
  }

  /// 状態復元で戻ってきた peripheral を再採用する（poweredOn 後に呼ぶ）。
  private func adoptRestoredPeripherals() {
    guard central != nil else { return }
    let peripherals = restoredPeripherals
    restoredPeripherals.removeAll()
    for peripheral in peripherals {
      peripheral.delegate = self
      discovered[peripheral.identifier] = DiscoveredEntry(peripheral: peripheral, lastSeen: Date(), lastEmitted: nil)
      switch peripheral.state {
      case .connected:
        // 接続が生きていればセッションを続ける（サービス探索から再開し linkOpened を出す）
        guard centralLinks[peripheral.identifier] == nil else { continue }
        let link = CentralLink(linkId: allocateLinkId(), peripheral: peripheral)
        centralLinks[peripheral.identifier] = link
        linkIndex[link.linkId] = .central(peripheral.identifier)
        startConnectTimer(link)
        log("復元: 接続中の peripheral を再採用 \(peripheral.identifier.uuidString)")
        peripheral.discoverServices([serviceUUID])
      case .connecting:
        // OS が引き継いだ接続待ち。「最近つながった相手」として取り込み、圏内に戻ったときの
        // 自動接続を生かす（期限は今から数え直す。Dart の start 前でも接続は受け入れる）
        rememberKnownPeer(peripheral, now: Date())
        log("復元: 接続待ちを引き継ぎ \(peripheral.identifier.uuidString)")
      default:
        break
      }
    }
  }

  private func pruneDiscovered(now: Date) {
    for (id, entry) in discovered
    where now.timeIntervalSince(entry.lastSeen) > BleEngine.discoveredExpiry && centralLinks[id] == nil {
      discovered.removeValue(forKey: id)
    }
  }

  private func connectOnQueue(peerId: String) {
    let linkId = allocateLinkId()
    guard let uuid = UUID(uuidString: peerId) else {
      emit(.linkClosed(linkId: linkId, peerId: peerId, reason: "invalidPeerId"))
      return
    }
    guard let central = central, central.state == .poweredOn else {
      emit(.linkClosed(linkId: linkId, peerId: peerId, reason: "poweredOff"))
      return
    }
    if centralLinks[uuid] != nil {
      log("connect: すでに接続処理中 \(peerId)")
      emit(.linkClosed(linkId: linkId, peerId: peerId, reason: "alreadyConnecting"))
      return
    }
    var peripheral = discovered[uuid]?.peripheral
    if peripheral == nil, let known = central.retrievePeripherals(withIdentifiers: [uuid]).first {
      peripheral = known
      discovered[uuid] = DiscoveredEntry(peripheral: known, lastSeen: Date(), lastEmitted: nil)
    }
    guard let target = peripheral else {
      emit(.linkClosed(linkId: linkId, peerId: peerId, reason: "unknownPeer"))
      return
    }
    let link = CentralLink(linkId: linkId, peripheral: target)
    centralLinks[uuid] = link
    linkIndex[linkId] = .central(uuid)
    target.delegate = self
    startConnectTimer(link)
    log("connect: \(peerId) link=\(linkId)")
    central.connect(target, options: connectOptions(for: uuid))
  }

  private func startConnectTimer(_ link: CentralLink) {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + BleEngine.connectTimeout)
    timer.setEventHandler { [weak self, weak link] in
      guard let self = self, let link = link, !link.opened else { return }
      self.closeCentralLink(link, reason: "timeout")
    }
    timer.resume()
    link.timer = timer
  }

  /// central 側リンクを閉じて linkClosed を 1 回だけ出す。
  private func closeCentralLink(_ link: CentralLink, reason: String) {
    let id = link.peripheral.identifier
    guard centralLinks[id] === link else { return }
    centralLinks.removeValue(forKey: id)
    linkIndex.removeValue(forKey: link.linkId)
    link.timer?.cancel()
    link.timer = nil
    if let pending = link.pendingWrite {
      link.pendingWrite = nil
      pending.completion(BleError(code: "linkClosed", message: "リンクが閉じました"))
    }
    if let central = central, central.state == .poweredOn {
      // 物理接続が残ったまま次のリンクを開くと、相手の peripheral 側は didSubscribeTo を
      // 受け取れず（購読が継続しているため）書き込みを「未購読」として捨てる。
      // 閉じるときは必ず購読を解除して、相手に didUnsubscribeFrom を届ける。
      if link.peripheral.state == .connected, let tx = link.tx, tx.isNotifying {
        link.peripheral.setNotifyValue(false, for: tx)
      }
      if link.peripheral.state == .connecting && running && knownPeers[id] != nil {
        // 最近つながった相手への接続待ちは取り消さず、圏内に戻ったときの自動接続に回す
        log("connect: 接続待ちを残す \(id.uuidString)")
      } else if peripheralLinks[id] != nil {
        // 同じ相手が central としてこちらに接続中。物理接続は共有なので切らない
        log("connect: 相手側のリンクが残っているので切断しない \(id.uuidString)")
      } else if link.peripheral.state != .disconnected {
        central.cancelPeripheralConnection(link.peripheral)
      }
    }
    log("linkClosed: link=\(link.linkId) \(reason)")
    emit(.linkClosed(linkId: link.linkId, peerId: id.uuidString, reason: reason))
    // 切断が完了したあと（didDisconnect）にも予約するが、接続待ちの取り消しでは
    // didDisconnect が来ないことがあるため、ここでも予約しておく（二重予約は上書き）
    scheduleReconnect(id)
  }

  // MARK: central: 最近つながった相手への接続待ち

  /// iOS 17 / macOS 14 以降は OS の自動再接続を有効にして接続する。それ未満は通常の接続。
  private static var autoReconnectOptions: [String: Any]? {
    if #available(iOS 17.0, macOS 14.0, *) {
      return [CBConnectPeripheralOptionEnableAutoReconnect: true]
    }
    return nil
  }

  private func connectOptions(for id: UUID) -> [String: Any]? {
    return knownPeers[id] != nil ? BleEngine.autoReconnectOptions : nil
  }

  /// リンクが開いた相手を「最近つながった相手」として覚える（期限は `knownPeerExpiry`）。
  private func rememberKnownPeer(_ peripheral: CBPeripheral, now: Date) {
    let id = peripheral.identifier
    let peer: KnownPeer
    if let existing = knownPeers[id] {
      peer = existing
      peer.lastLinked = now
    } else {
      // 上限を超えるなら、最後につながったのが最も古い相手から忘れる
      while knownPeers.count >= BleEngine.knownPeerLimit,
        let oldest = knownPeers.values.min(by: { $0.lastLinked < $1.lastLinked })
      {
        forgetKnownPeer(oldest.peripheral.identifier, reason: "上限")
      }
      peer = KnownPeer(peripheral: peripheral, lastLinked: now)
      knownPeers[id] = peer
    }
    peer.expiryTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + BleEngine.knownPeerExpiry)
    timer.setEventHandler { [weak self] in
      self?.forgetKnownPeer(id, reason: "期限切れ")
    }
    timer.resume()
    peer.expiryTimer = timer
    log("知っている相手: \(id.uuidString) を \(Int(BleEngine.knownPeerExpiry / 60)) 分保持 (\(knownPeers.count) 台)")
  }

  /// 相手を忘れる。リンクが無く接続待ちだけなら取り消す（進行中のリンクはそのまま続ける）。
  private func forgetKnownPeer(_ id: UUID, reason: String) {
    guard let peer = knownPeers.removeValue(forKey: id) else { return }
    peer.cancelTimers()
    if centralLinks[id] == nil, peer.peripheral.state == .connecting,
      let central = central, central.state == .poweredOn
    {
      central.cancelPeripheralConnection(peer.peripheral)
      log("connect: 接続待ちを取り消し \(id.uuidString)")
    }
    log("知っている相手: \(id.uuidString) を忘れる (\(reason))")
  }

  private func forgetAllKnownPeers() {
    for id in Array(knownPeers.keys) {
      forgetKnownPeer(id, reason: "stop")
    }
  }

  /// 切断後 `knownPeerReconnectDelay` 経ってから接続待ちを出し直す。
  private func scheduleReconnect(_ id: UUID) {
    guard let peer = knownPeers[id] else { return }
    peer.reconnectTimer?.cancel()
    var delay = BleEngine.knownPeerReconnectDelay
    #if os(iOS)
    // 背面ではアプリがすぐ止まり 60 秒のタイマーが動かないので、バックグラウンドタスクで
    // 起きている間（約 30 秒）に収まる間隔で出し直す。
    var task = UIBackgroundTaskIdentifier.invalid
    if !inForeground {
      delay = BleEngine.backgroundReconnectDelay
      task = UIApplication.shared.beginBackgroundTask(withName: "jp.kairanban.reconnect") {
        if task != .invalid {
          UIApplication.shared.endBackgroundTask(task)
          task = .invalid
        }
      }
    }
    #endif
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + delay)
    timer.setEventHandler { [weak self] in
      if let self = self {
        self.knownPeers[id]?.reconnectTimer = nil
        self.ensurePendingConnect(id)
      }
      #if os(iOS)
      if task != .invalid {
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
      }
      #endif
    }
    timer.resume()
    peer.reconnectTimer = timer
  }

  /// 最近つながった相手への接続待ちが無ければ出す（リンク中・接続待ち中なら何もしない）。
  private func ensurePendingConnect(_ id: UUID) {
    guard running, let central = central, central.state == .poweredOn, let peer = knownPeers[id] else {
      return
    }
    guard centralLinks[id] == nil, peer.peripheral.state == .disconnected else { return }
    central.connect(peer.peripheral, options: BleEngine.autoReconnectOptions)
    log("connect: 接続待ち \(id.uuidString)")
  }

  /// 動作開始時・Bluetooth が再び ON になったときに、知っている相手すべての接続待ちを出し直す。
  private func ensurePendingConnectsForKnownPeers() {
    for id in Array(knownPeers.keys) {
      ensurePendingConnect(id)
    }
  }

  // MARK: peripheral: サービス・広告

  private func updatePeripheral() {
    guard let manager = peripheralManager else { return }
    let shouldRun = running && manager.state == .poweredOn
    if shouldRun {
      if !serviceAdded && !serviceAddPending {
        let rx = CBMutableCharacteristic(
          type: rxUUID, properties: [.write, .writeWithoutResponse], value: nil, permissions: [.writeable])
        let tx = CBMutableCharacteristic(
          type: txUUID, properties: [.notify], value: nil, permissions: [.readable])
        let newService = CBMutableService(type: serviceUUID, primary: true)
        newService.characteristics = [rx, tx]
        rxCharacteristic = rx
        txCharacteristic = tx
        service = newService
        serviceAddPending = true
        manager.add(newService)
      } else if serviceAdded && !advertising && !advertisingPending {
        advertisingPending = true
        // 広告には Service UUID のみ（Local Name なし）
        manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceUUID]])
      }
    } else if manager.state == .poweredOn {
      if advertising || advertisingPending {
        manager.stopAdvertising()
        advertising = false
        advertisingPending = false
        log("advertise: 停止")
      }
    }
  }

  private func openPeripheralLink(for central: CBCentral) {
    if peripheralLinks[central.identifier] != nil { return }
    let link = PeripheralLink(linkId: allocateLinkId(), central: central)
    peripheralLinks[central.identifier] = link
    linkIndex[link.linkId] = .peripheral(central.identifier)
    log("linkOpened: link=\(link.linkId) peripheral側 maxChunk=\(central.maximumUpdateValueLength)")
    emit(.linkOpened(
      linkId: link.linkId,
      peerId: central.identifier.uuidString,
      maxChunk: central.maximumUpdateValueLength,
      initiator: false))
  }

  /// peripheral 側リンクを閉じて linkClosed を 1 回だけ出す。
  /// iOS には central を切断する API がないため、リンクを忘れて以後の書き込みを無視する。
  private func closePeripheralLink(_ link: PeripheralLink, reason: String) {
    let id = link.central.identifier
    guard peripheralLinks[id] === link else { return }
    peripheralLinks.removeValue(forKey: id)
    linkIndex.removeValue(forKey: link.linkId)
    if reason == "closed" {
      // 相手の central はまだ購読したままかもしれない。購読し直すまで書き込みでは開かない
      closedCentrals.insert(id)
    }
    if let pending = link.pendingNotify {
      link.pendingNotify = nil
      pending.completion(BleError(code: "linkClosed", message: "リンクが閉じました"))
    }
    log("linkClosed: link=\(link.linkId) \(reason)")
    emit(.linkClosed(linkId: link.linkId, peerId: id.uuidString, reason: reason))
  }

  // MARK: 送信

  private func sendOnQueue(linkId: Int, data: Data, completion: @escaping (Error?) -> Void) {
    guard let ref = linkIndex[linkId] else {
      completion(BleError(code: "noLink", message: "リンクがありません"))
      return
    }
    switch ref {
    case .central(let id):
      guard let link = centralLinks[id], link.opened, let rx = link.rx else {
        completion(BleError(code: "notOpen", message: "リンクが開いていません"))
        return
      }
      guard data.count <= link.peripheral.maximumWriteValueLength(for: .withoutResponse) else {
        completion(BleError(code: "tooLarge", message: "maxChunk を超えています"))
        return
      }
      guard link.pendingWrite == nil else {
        completion(BleError(code: "busy", message: "前の送信が完了していません"))
        return
      }
      if link.peripheral.canSendWriteWithoutResponse {
        link.peripheral.writeValue(data, for: rx, type: .withoutResponse)
        completion(nil)
      } else {
        // peripheralIsReady(toSendWriteWithoutResponse:) で再開する
        link.pendingWrite = (data, completion)
      }
    case .peripheral(let id):
      guard let link = peripheralLinks[id], let tx = txCharacteristic, let manager = peripheralManager else {
        completion(BleError(code: "notOpen", message: "リンクが開いていません"))
        return
      }
      guard data.count <= link.central.maximumUpdateValueLength else {
        completion(BleError(code: "tooLarge", message: "maxChunk を超えています"))
        return
      }
      guard link.pendingNotify == nil else {
        completion(BleError(code: "busy", message: "前の送信が完了していません"))
        return
      }
      if manager.updateValue(data, for: tx, onSubscribedCentrals: [link.central]) {
        completion(nil)
      } else {
        // 送信キューが一杯。peripheralManagerIsReady(toUpdateSubscribers:) で再試行する
        link.pendingNotify = (data, completion)
      }
    }
  }
}

// MARK: - CBCentralManagerDelegate

extension BleEngine: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    log("central: state=\(central.state.rawValue)")
    if central.state == .poweredOn {
      scanning = central.isScanning
      adoptRestoredPeripherals()
      updateScanning()
      // Bluetooth が OFF の間に失われた接続待ちを出し直す
      ensurePendingConnectsForKnownPeers()
    } else {
      scanning = false
      for link in Array(centralLinks.values) {
        closeCentralLink(link, reason: "poweredOff")
      }
    }
    emitState()
  }

  #if os(iOS)
  // 状態復元は iOS のみ（macOS はバックグラウンドで再起動されない）
  func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
    if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
      for peripheral in peripherals {
        peripheral.delegate = self
        discovered[peripheral.identifier] = DiscoveredEntry(peripheral: peripheral, lastSeen: Date(), lastEmitted: nil)
      }
      restoredPeripherals = peripherals
      log("central: 復元 peripherals=\(peripherals.count)")
    }
  }
  #endif

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
    let overflow = advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
    guard advertised.contains(serviceUUID) || overflow.contains(serviceUUID) else { return }
    let now = Date()
    pruneDiscovered(now: now)
    let id = peripheral.identifier
    var entry = discovered[id] ?? DiscoveredEntry(peripheral: peripheral, lastSeen: now, lastEmitted: nil)
    entry.lastSeen = now
    if let last = entry.lastEmitted, now.timeIntervalSince(last) < BleEngine.discoveredThrottle {
      discovered[id] = entry
      return
    }
    entry.lastEmitted = now
    discovered[id] = entry
    emit(.discovered(peerId: id.uuidString, rssi: RSSI.intValue, viaApple: false))
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    refreshScanIfStale()
    let id = peripheral.identifier
    if let link = centralLinks[id] {
      log("connected: link=\(link.linkId)")
    } else if knownPeers[id] != nil {
      // 接続待ちからの自動接続。Dart が要求した接続と同じ流れ
      // （サービス探索 → TX 通知の有効化 → linkOpened(initiator: true)）に乗せる
      let link = CentralLink(linkId: allocateLinkId(), peripheral: peripheral)
      centralLinks[id] = link
      linkIndex[link.linkId] = .central(id)
      startConnectTimer(link)
      log("connected: 自動接続 link=\(link.linkId) \(id.uuidString)")
    } else {
      central.cancelPeripheralConnection(peripheral)
      return
    }
    peripheral.delegate = self
    peripheral.discoverServices([serviceUUID])
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    if let link = centralLinks[peripheral.identifier] {
      closeCentralLink(link, reason: "connectFailed: \(error?.localizedDescription ?? "")")
    } else {
      scheduleReconnect(peripheral.identifier)
    }
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    handleDisconnect(peripheral, error: error, systemReconnecting: false)
  }

  /// iOS 17 / macOS 14 以降はこちらが呼ばれる（`isReconnecting` は OS の自動再接続が進行中かどうか）。
  /// プロトコル要件の可用性に合わせる必要があるため @available は付けない（本体は iOS 15 でも動く型だけを使う）。
  func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    timestamp: CFAbsoluteTime,
    isReconnecting: Bool,
    error: Error?
  ) {
    handleDisconnect(peripheral, error: error, systemReconnecting: isReconnecting)
  }

  private func handleDisconnect(_ peripheral: CBPeripheral, error: Error?, systemReconnecting: Bool) {
    refreshScanIfStale()
    let id = peripheral.identifier
    if let link = centralLinks[id] {
      if let error = error {
        closeCentralLink(link, reason: "disconnected: \(error.localizedDescription)")
      } else {
        closeCentralLink(link, reason: "disconnected")
      }
    }
    guard knownPeers[id] != nil else { return }
    if systemReconnecting {
      // OS が再接続を試みている。つながれば didConnect が来る（予約済みの接続待ちは状態を見て何もしない）
      log("disconnected: OS が再接続中 \(id.uuidString)")
    } else {
      scheduleReconnect(id)
    }
  }
}

// MARK: - CBPeripheralDelegate（central として接続した相手）

extension BleEngine: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard let link = centralLinks[peripheral.identifier] else { return }
    if let error = error {
      closeCentralLink(link, reason: "serviceDiscoveryFailed: \(error.localizedDescription)")
      return
    }
    guard let found = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
      closeCentralLink(link, reason: "no_service")
      return
    }
    peripheral.discoverCharacteristics([rxUUID, txUUID], for: found)
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    guard let link = centralLinks[peripheral.identifier] else { return }
    if let error = error {
      closeCentralLink(link, reason: "characteristicDiscoveryFailed: \(error.localizedDescription)")
      return
    }
    for characteristic in service.characteristics ?? [] {
      if characteristic.uuid == rxUUID {
        link.rx = characteristic
      } else if characteristic.uuid == txUUID {
        link.tx = characteristic
      }
    }
    guard let tx = link.tx, link.rx != nil else {
      closeCentralLink(link, reason: "no_service")
      return
    }
    if tx.isNotifying {
      // 物理接続が残っていて前回の購読が生きている。相手に新しい didSubscribeTo を
      // 届けるため、一度解除してから購読し直す（didUpdateNotificationStateFor で再開）
      link.resubscribed = true
      log("notify: 前回の購読が残っているので購読し直す link=\(link.linkId)")
      peripheral.setNotifyValue(false, for: tx)
    } else {
      peripheral.setNotifyValue(true, for: tx)
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard let link = centralLinks[peripheral.identifier], characteristic.uuid == txUUID else { return }
    if let error = error {
      closeCentralLink(link, reason: "notifyFailed: \(error.localizedDescription)")
      return
    }
    if characteristic.isNotifying {
      guard !link.opened else { return }
      link.opened = true
      link.timer?.cancel()
      link.timer = nil
      let maxChunk = peripheral.maximumWriteValueLength(for: .withoutResponse)
      rememberKnownPeer(peripheral, now: Date())
      log("linkOpened: link=\(link.linkId) central側 maxChunk=\(maxChunk)")
      emit(.linkOpened(
        linkId: link.linkId,
        peerId: peripheral.identifier.uuidString,
        maxChunk: maxChunk,
        initiator: true))
    } else if link.opened {
      closeCentralLink(link, reason: "notifyStopped")
    } else if link.resubscribed {
      // 解除が完了したので購読し直す
      link.resubscribed = false
      peripheral.setNotifyValue(true, for: characteristic)
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    guard let link = centralLinks[peripheral.identifier], link.opened, characteristic.uuid == txUUID,
      error == nil, let value = characteristic.value, !value.isEmpty
    else { return }
    emit(.data(linkId: link.linkId, data: value))
  }

  func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
    guard let link = centralLinks[peripheral.identifier], let pending = link.pendingWrite, let rx = link.rx else {
      return
    }
    link.pendingWrite = nil
    peripheral.writeValue(pending.data, for: rx, type: .withoutResponse)
    pending.completion(nil)
  }

  func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
    guard let link = centralLinks[peripheral.identifier],
      invalidatedServices.contains(where: { $0.uuid == serviceUUID })
    else { return }
    closeCentralLink(link, reason: "serviceInvalidated")
  }
}

// MARK: - CBPeripheralManagerDelegate

extension BleEngine: CBPeripheralManagerDelegate {
  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    log("peripheral: state=\(peripheral.state.rawValue)")
    if peripheral.state == .poweredOn {
      advertising = peripheral.isAdvertising
      advertisingPending = false
      updatePeripheral()
    } else {
      // 電源が切れるとサービスと広告は失われる
      advertising = false
      advertisingPending = false
      serviceAdded = false
      serviceAddPending = false
      for link in Array(peripheralLinks.values) {
        closePeripheralLink(link, reason: "poweredOff")
      }
      closedCentrals.removeAll()
    }
    emitState()
  }

  #if os(iOS)
  func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
    if let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] {
      for restored in services where restored.uuid == serviceUUID {
        service = restored
        for characteristic in restored.characteristics ?? [] {
          guard let mutable = characteristic as? CBMutableCharacteristic else { continue }
          if mutable.uuid == rxUUID {
            rxCharacteristic = mutable
          } else if mutable.uuid == txUUID {
            txCharacteristic = mutable
          }
        }
        serviceAdded = true
        // すでに TX を購読している central はリンクとして採用する
        for central in txCharacteristic?.subscribedCentrals ?? [] {
          openPeripheralLink(for: central)
        }
      }
      log("peripheral: 復元 services=\(services.count)")
    }
    if dict[CBPeripheralManagerRestoredStateAdvertisementDataKey] != nil {
      advertising = true
    }
  }
  #endif

  func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
    serviceAddPending = false
    if let error = error {
      log("service: 追加失敗 \(error.localizedDescription)")
      return
    }
    serviceAdded = true
    log("service: 追加")
    updatePeripheral()
  }

  func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
    advertisingPending = false
    if let error = error {
      advertising = false
      log("advertise: 失敗 \(error.localizedDescription)")
    } else {
      advertising = true
      log("advertise: 開始")
    }
    emitState()
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager,
    central: CBCentral,
    didSubscribeTo characteristic: CBCharacteristic
  ) {
    guard characteristic.uuid == txUUID else { return }
    refreshScanIfStale()
    closedCentrals.remove(central.identifier)
    openPeripheralLink(for: central)
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager,
    central: CBCentral,
    didUnsubscribeFrom characteristic: CBCharacteristic
  ) {
    guard characteristic.uuid == txUUID else { return }
    refreshScanIfStale()
    // 切断時にも呼ばれる。次に購読してきたら新しいリンクとして受け付ける
    closedCentrals.remove(central.identifier)
    guard let link = peripheralLinks[central.identifier] else { return }
    closePeripheralLink(link, reason: "unsubscribed")
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
    var result = CBATTError.Code.success
    for request in requests {
      guard request.characteristic.uuid == rxUUID else {
        result = .attributeNotFound
        continue
      }
      let centralId = request.central.identifier
      var link = peripheralLinks[centralId]
      if link == nil {
        if closedCentrals.contains(centralId) {
          // こちらが閉じたセッションの残り（相手の BYE や送信済みチャンク）。
          // 相手が購読し直すまではリンクにしない
          log("write: 閉じたリンクへの残りの書き込みを無視 central=\(centralId.uuidString.prefix(8))")
          continue
        }
        // 相手が物理接続と購読を残したまま次のセッションを始めた（購読通知が来ない）。
        // 購読中の central なら、書き込みを合図にリンクを開き直す
        let subscribed = txCharacteristic?.subscribedCentrals?
          .contains(where: { $0.identifier == centralId }) ?? false
        if subscribed {
          log("write: 購読中の central からの書き込みでリンクを開き直す")
          openPeripheralLink(for: request.central)
          link = peripheralLinks[centralId]
        }
      }
      guard let link = link else {
        log("write: 未購読の central からの書き込みを無視")
        continue
      }
      if let value = request.value, !value.isEmpty {
        emit(.data(linkId: link.linkId, data: value))
      }
    }
    // 応答は先頭のリクエストに 1 回だけ返す（Write Without Response でも呼んでよい）
    if let first = requests.first {
      peripheral.respond(to: first, withResult: result)
    }
  }

  func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
    guard let tx = txCharacteristic else { return }
    for link in peripheralLinks.values {
      guard let pending = link.pendingNotify else { continue }
      if peripheral.updateValue(pending.data, for: tx, onSubscribedCentrals: [link.central]) {
        link.pendingNotify = nil
        pending.completion(nil)
      } else {
        // まだ一杯。次の peripheralManagerIsReady を待つ
        break
      }
    }
  }
}
