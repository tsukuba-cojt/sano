import SwiftUI
import WidgetKit

/// 回覧板の Widget Extension。Live Activity だけを提供する（ホーム画面ウィジェットは無い）。
@main
struct KairanLiveActivityBundle: WidgetBundle {
  var body: some Widget {
    KairanLiveActivity()
  }
}
