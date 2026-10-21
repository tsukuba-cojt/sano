import ActivityKit
import Foundation
import UIKit
import os

/// Live Activity「回覧板 近くの人と 交換中 / 最後に 受け取ったのは …」を出し入れする。
///
/// - Dart の `start` で開始し、`stop` で終了する（BleBridge から呼ぶ）。
/// - 「最後に受け取った時刻」の更新は `updateInterval`（15 分）に 1 回に抑える。
/// - iOS 26 では Live Activity を出している間、画面点灯中（ロック中を含む）はバックグラウンドでも
///   前面と同等の権限でスキャンできるため、iPhone 同士の発見機会が増える。
/// - iOS 16.1 未満では何もしない。Live Activity の開始は前面でしか許されないため、
///   バックグラウンドで `start` が来たときは次に前面へ来たときに開始する。
/// - メインスレッドで使う。
final class LiveActivityController {
  /// Live Activity を更新する最短間隔。
  static let updateInterval: TimeInterval = 15 * 60

  private var driverBox: Any?

  @available(iOS 16.1, *)
  private var driver: LiveActivityDriver {
    if let existing = driverBox as? LiveActivityDriver {
      return existing
    }
    let created = LiveActivityDriver(updateInterval: LiveActivityController.updateInterval)
    driverBox = created
    return created
  }

  /// 通信開始。Live Activity を出す（前面でなければ、次に前面へ来たときに出す）。
  func start() {
    if #available(iOS 16.1, *) {
      driver.start()
    }
  }

  /// 通信停止。Live Activity を消す。
  func stop() {
    if #available(iOS 16.1, *) {
      driver.stop()
    }
  }

  /// お知らせを受け取った。表示は間引いて更新する。
  func noteReceived(at date: Date) {
    if #available(iOS 16.1, *) {
      driver.noteReceived(at: date)
    }
  }
}

/// ActivityKit を直接触る部分（iOS 16.1 以上）。
@available(iOS 16.1, *)
private final class LiveActivityDriver {
  private let updateInterval: TimeInterval
  private let logger = Logger(subsystem: "jp.kairanban", category: "liveActivity")

  private var running = false
  private var activity: Activity<KairanActivityAttributes>?
  /// 最後に受け取った時刻（Dart から通知された値）。
  private var lastReceivedAt: Date?
  /// 最後に Live Activity へ反映した受け取り時刻。
  private var shownReceivedAt: Date?
  /// 最後に Live Activity を更新した時刻（間引き用）。
  private var lastUpdatedAt: Date?
  private var updateTimer: Timer?
  private var foregroundObserver: NSObjectProtocol?

  init(updateInterval: TimeInterval) {
    self.updateInterval = updateInterval
    foregroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.appDidBecomeActive()
    }
  }

  deinit {
    if let observer = foregroundObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    updateTimer?.invalidate()
  }

  func start() {
    running = true
    ensureActivity()
  }

  func stop() {
    running = false
    updateTimer?.invalidate()
    updateTimer = nil
    lastReceivedAt = nil
    shownReceivedAt = nil
    lastUpdatedAt = nil
    activity = nil
    endAll()
  }

  func noteReceived(at date: Date) {
    lastReceivedAt = date
    guard running else { return }
    scheduleUpdate()
  }

  private var state: KairanActivityAttributes.ContentState {
    return KairanActivityAttributes.ContentState(lastReceivedAt: lastReceivedAt)
  }

  private func appDidBecomeActive() {
    guard running else { return }
    ensureActivity()
  }

  /// 生きている Live Activity を探す。無ければ（前面にいるときだけ）新しく出す。
  private func ensureActivity() {
    if let current = activity, current.activityState == .active {
      return
    }
    // 復元起動などで、前回出した Live Activity が残っていればそれを使う
    if let existing = Activity<KairanActivityAttributes>.activities.first(where: { $0.activityState == .active }) {
      activity = existing
      logger.info("既存の Live Activity を引き継ぎ")
      return
    }
    activity = nil
    guard UIApplication.shared.applicationState == .active else {
      logger.info("前面でないため Live Activity の開始を保留")
      return
    }
    guard ActivityAuthorizationInfo().areActivitiesEnabled else {
      logger.info("Live Activity が許可されていない")
      return
    }
    do {
      activity = try request(state)
      shownReceivedAt = lastReceivedAt
      lastUpdatedAt = Date()
      logger.info("Live Activity を開始")
    } catch {
      logger.error("Live Activity の開始に失敗: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// 表示を更新する。前回の更新から `updateInterval` 経っていなければ、その時刻まで待つ。
  private func scheduleUpdate() {
    guard updateTimer == nil else { return }
    let elapsed = lastUpdatedAt.map { Date().timeIntervalSince($0) } ?? updateInterval
    let delay = max(0, updateInterval - elapsed)
    if delay == 0 {
      pushUpdate()
      return
    }
    updateTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
      guard let self = self else { return }
      self.updateTimer = nil
      self.pushUpdate()
    }
  }

  private func pushUpdate() {
    guard running else { return }
    ensureActivity()
    guard let current = activity, current.activityState == .active else { return }
    guard shownReceivedAt != lastReceivedAt else { return }
    let content = state
    shownReceivedAt = lastReceivedAt
    lastUpdatedAt = Date()
    Task { await self.update(current, content) }
  }

  private func endAll() {
    let activities = Activity<KairanActivityAttributes>.activities
    guard !activities.isEmpty else { return }
    let content = state
    Task {
      for item in activities {
        await self.end(item, content)
      }
    }
  }

  // MARK: ActivityKit の API 差（16.1 は旧 API、16.2 以降は ActivityContent）

  private func request(_ content: KairanActivityAttributes.ContentState) throws -> Activity<KairanActivityAttributes> {
    if #available(iOS 16.2, *) {
      return try Activity.request(
        attributes: KairanActivityAttributes(),
        content: ActivityContent(state: content, staleDate: nil),
        pushType: nil)
    }
    return try requestLegacy(content)
  }

  private func update(_ activity: Activity<KairanActivityAttributes>, _ content: KairanActivityAttributes.ContentState) async {
    if #available(iOS 16.2, *) {
      await activity.update(ActivityContent(state: content, staleDate: nil))
    } else {
      await updateLegacy(activity, content)
    }
  }

  private func end(_ activity: Activity<KairanActivityAttributes>, _ content: KairanActivityAttributes.ContentState) async {
    if #available(iOS 16.2, *) {
      await activity.end(ActivityContent(state: content, staleDate: nil), dismissalPolicy: .immediate)
    } else {
      await endLegacy(activity, content)
    }
  }

  // iOS 16.1 向けの旧 API。呼び出し側を同じバージョンで deprecated にして警告を抑える。
  @available(iOS, introduced: 16.1, deprecated: 16.2)
  private func requestLegacy(_ content: KairanActivityAttributes.ContentState) throws -> Activity<KairanActivityAttributes> {
    return try Activity.request(attributes: KairanActivityAttributes(), contentState: content, pushType: nil)
  }

  @available(iOS, introduced: 16.1, deprecated: 16.2)
  private func updateLegacy(_ activity: Activity<KairanActivityAttributes>, _ content: KairanActivityAttributes.ContentState) async {
    await activity.update(using: content)
  }

  @available(iOS, introduced: 16.1, deprecated: 16.2)
  private func endLegacy(_ activity: Activity<KairanActivityAttributes>, _ content: KairanActivityAttributes.ContentState) async {
    await activity.end(using: content, dismissalPolicy: .immediate)
  }
}
