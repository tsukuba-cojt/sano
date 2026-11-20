import Foundation
import UserNotifications
import os

/// 「新しい お知らせ」のローカル通知（Dart の `requestNotificationPermission` / `showNotice` /
/// `cancelNotice` / `scheduleReminder`）。
///
/// - 権限は `UNUserNotificationCenter.requestAuthorization([.alert, .sound, .badge])` で要求する。
///   すでに決まっている（許可・拒否）ならダイアログは出さず、その結果を返す。
/// - 通知は即時トリガー（`trigger: nil`）で出す。identifier は Dart が渡す id の文字列で、
///   同じ id は置き換わる（「N 件」への更新）。
/// - 重要度（docs/08 C05）: urgent = 公式の避難情報・注意喚起（timeSensitive、夜も音あり）、
///   important = 大事なもの（active。午後 10 時〜午前 6 時は音なし）、normal = それ以外（passive）。
///   timeSensitive は Time Sensitive Notifications の capability が無いと active 相当になる。
/// - アプリが前面のときは Dart 側が `showNotice` を呼ばないので、前面表示のデリゲートは持たない。
/// - メインスレッドで使う。完了ハンドラはメインスレッドで呼ぶ。
final class NoticeNotifier {
  private let center = UNUserNotificationCenter.current()
  private let logger = Logger(subsystem: "jp.kairanban", category: "notice")

  /// 月 1 回の確認通知の identifier（C07）。
  static let reminderIdentifier = "monthly-reminder"

  /// 通知の権限を要求する。許可されていれば true。
  func requestPermission(_ completion: @escaping (Bool) -> Void) {
    center.getNotificationSettings { [weak self] settings in
      guard let self = self else {
        DispatchQueue.main.async { completion(false) }
        return
      }
      switch settings.authorizationStatus {
      case .authorized, .provisional, .ephemeral:
        DispatchQueue.main.async { completion(true) }
      case .denied:
        DispatchQueue.main.async { completion(false) }
      case .notDetermined:
        self.center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
          if let error = error {
            self.logger.error("通知の許可要求に失敗: \(error.localizedDescription, privacy: .public)")
          }
          DispatchQueue.main.async { completion(granted) }
        }
      @unknown default:
        DispatchQueue.main.async { completion(false) }
      }
    }
  }

  /// 通知を出せるか（許可済みなら true。まだ聞いていない・断られたなら false）。
  func isAuthorized(_ completion: @escaping (Bool) -> Void) {
    center.getNotificationSettings { settings in
      let allowed: Bool
      switch settings.authorizationStatus {
      case .authorized, .provisional, .ephemeral:
        allowed = true
      default:
        allowed = false
      }
      DispatchQueue.main.async { completion(allowed) }
    }
  }

  /// 午後 10 時〜午前 6 時か（important の音を止める時間帯）。
  private static func isQuietHours(_ date: Date = Date()) -> Bool {
    let hour = Calendar.current.component(.hour, from: date)
    return hour >= 22 || hour < 6
  }

  /// ローカル通知を出す。
  /// - Parameters:
  ///   - importance: "urgent" / "important" / "normal"
  ///   - msgId: タップで開く詳細の msg_id（なければ nil）
  func show(id: Int, title: String, body: String, groupCode: Int, importance: String, msgId: Int?) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.threadIdentifier = importance == "urgent" ? "alerts" : "notices"
    var userInfo: [String: Any] = ["groupCode": groupCode, "importance": importance]
    if let msgId = msgId {
      userInfo["msgId"] = msgId
    }
    content.userInfo = userInfo
    switch importance {
    case "urgent":
      content.sound = .defaultCritical
      if #available(iOS 15.0, macOS 12.0, *) {
        content.interruptionLevel = .timeSensitive
      }
    case "normal":
      content.sound = nil
      if #available(iOS 15.0, macOS 12.0, *) {
        content.interruptionLevel = .passive
      }
    default:
      content.sound = NoticeNotifier.isQuietHours() ? nil : .default
      if #available(iOS 15.0, macOS 12.0, *) {
        content.interruptionLevel = .active
      }
    }
    let request = UNNotificationRequest(identifier: String(id), content: content, trigger: nil)
    center.add(request) { [logger] error in
      if let error = error {
        logger.error("通知を出せません: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  /// 出した通知を消す（取り消された避難情報など、C05）。
  func cancel(id: Int) {
    let identifier = String(id)
    center.removeDeliveredNotifications(withIdentifiers: [identifier])
    center.removePendingNotificationRequests(withIdentifiers: [identifier])
  }

  /// 月 1 回の確認通知を [at] に予約する（1 回限り。Dart が前面になるたびに予約し直す、C07）。
  func scheduleReminder(title: String, body: String, at: Date) {
    center.removePendingNotificationRequests(withIdentifiers: [NoticeNotifier.reminderIdentifier])
    let interval = at.timeIntervalSinceNow
    guard interval > 60 else {
      logger.info("確認通知の予約時刻が近すぎるため予約しません")
      return
    }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    content.threadIdentifier = "reminder"
    if #available(iOS 15.0, macOS 12.0, *) {
      content.interruptionLevel = .active
    }
    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
    let request = UNNotificationRequest(
      identifier: NoticeNotifier.reminderIdentifier, content: content, trigger: trigger)
    center.add(request) { [logger] error in
      if let error = error {
        logger.error("確認通知を予約できません: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  /// 月 1 回の確認通知を取り消す。
  func cancelReminder() {
    center.removePendingNotificationRequests(withIdentifiers: [NoticeNotifier.reminderIdentifier])
  }
}
