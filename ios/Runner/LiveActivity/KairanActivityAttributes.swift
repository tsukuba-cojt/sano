import ActivityKit
import Foundation

/// 回覧板の Live Activity（ロック画面・Dynamic Island に出す「近くの人と 交換中」）の属性。
///
/// アプリ本体（Runner）と Widget Extension（KairanLiveActivity）の両方でコンパイルする。
/// 変化する値は `ContentState` だけで、更新は 15 分に 1 回程度に抑える（LiveActivityController）。
@available(iOS 16.1, *)
struct KairanActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    /// 最後にお知らせを受け取った時刻。まだ受け取っていなければ nil。
    var lastReceivedAt: Date?
  }
}
