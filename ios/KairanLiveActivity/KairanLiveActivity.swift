import ActivityKit
import SwiftUI
import WidgetKit

/// docs/04_ui_design.md §1 の配色（自治体ブルー #0017C1、白地、本文 #1A1A1A）。装飾なし。
enum KairanPalette {
  static let blue = Color(red: 0x00 / 255.0, green: 0x17 / 255.0, blue: 0xC1 / 255.0)
  static let text = Color(red: 0x1A / 255.0, green: 0x1A / 255.0, blue: 0x1A / 255.0)
  static let background = Color.white
}

/// 「午後3時10分」のように時刻を返す（Dart 側 formatTimeJa と同じ書式）。
func kairanTimeJa(_ date: Date) -> String {
  let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
  let hour = parts.hour ?? 0
  let minute = parts.minute ?? 0
  let period = hour < 12 ? "午前" : "午後"
  return "\(period)\(hour % 12)時\(String(format: "%02d", minute))分"
}

/// 「最後に 受け取ったのは 午後3時10分」/「まだ 受け取っていません」。
func kairanLastReceivedLine(_ state: KairanActivityAttributes.ContentState) -> String {
  if let at = state.lastReceivedAt {
    return "最後に 受け取ったのは \(kairanTimeJa(at))"
  }
  return "まだ 受け取っていません"
}

/// ロック画面・通知センター・Dynamic Island 展開時の表示。
struct KairanActivityView: View {
  let state: KairanActivityAttributes.ContentState

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("回覧板")
        .font(.system(size: 22, weight: .bold))
        .foregroundColor(KairanPalette.blue)
      Text("近くの人と 交換中")
        .font(.system(size: 18))
        .foregroundColor(KairanPalette.text)
      Text(kairanLastReceivedLine(state))
        .font(.system(size: 18))
        .foregroundColor(KairanPalette.text)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
  }
}

struct KairanLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: KairanActivityAttributes.self) { context in
      KairanActivityView(state: context.state)
        .activityBackgroundTint(KairanPalette.background)
        .activitySystemActionForegroundColor(KairanPalette.blue)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.bottom) {
          KairanActivityView(state: context.state)
            .foregroundColor(.white)
        }
      } compactLeading: {
        Text("回覧板")
          .font(.system(size: 14, weight: .bold))
      } compactTrailing: {
        if let at = context.state.lastReceivedAt {
          Text(at, style: .time)
            .font(.system(size: 14))
        } else {
          Text("交換中")
            .font(.system(size: 14))
        }
      } minimal: {
        Text("回")
          .font(.system(size: 14, weight: .bold))
      }
    }
  }
}
