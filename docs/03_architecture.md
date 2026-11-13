# 回覧板 アーキテクチャ v1（v2 改訂）

v2 は [08_use_cases.md](08_use_cases.md) の仕様変更 C01〜C25 を実装に合わせて反映した版。変更・追加した行の末尾に「（v2: C13）」のように変更 id を付ける。ワイヤ・同期・保存の規則は [02_protocol.md](02_protocol.md)、Dart の公開 API は [05_dart_api.md](05_dart_api.md)。（v2: C13）

大量受信時の保存確定・本部記録・受信待ちの設計は [11_bulk_data_reliability.md](11_bulk_data_reliability.md) を参照（v2.4）。

1 万件での計測と、本部記録の差分保存・ログ整理・一覧の再利用・通信の再試行の改善は [12_capacity_measurements.md](12_capacity_measurements.md) に記録する。

## 1. スタック

| 層 | 技術 | 理由 |
|---|---|---|
| UI | Flutter (Dart) | 1 つの UI 実装で iOS/Android 共通。シミュレータ/エミュレータで画面検証できる |
| プロトコル・保存・同期 | Dart（`lib/core`, `lib/mesh`） | 単一実装。フェイクトランスポートで多ノード模擬テストが可能 |
| BLE トランスポート | Swift (CoreBluetooth) / Kotlin (android.bluetooth) | バックグラウンド規則は OS ごとに異なり、プラグインに依存しない |
| 永続化 | 中継用 `messages.bin`、本部記録 `reports.bin` の追記型ログ（削除を伴う追加・本文消去では全置換）+ `shared_preferences` | 本部記録を中継キャッシュから分離し、各保存枠と受信待ちに上限を設ける |

調査では「フルネイティブ」が最軽量と出たが、ソロ開発で両 OS の UI と同期ロジックを二重実装するリスクを避け、**UI と同期ロジックを Dart に一本化し BLE だけネイティブ**にする。バイナリは数 MB 増えるが、画面・ロジックの検証可能性を優先した。

## 2. モジュール構成

```
lib/
  main.dart                 起動。AppController を生成し runApp
  app/
    theme.dart              DADS 準拠の配色・タイポグラフィ・サイズ
    app_controller.dart     ノード/ストア/設定の生成と UI への公開（ChangeNotifier）。通知 3 段階・電池・画面点灯・訂正と取り消し（v2: C05, C06, C07, C01, C10）
  core/
    epoch.dart              2026 エポック変換
    envelope.dart           封筒のエンコード/デコード/2 段の検証（不透明メッセージ・空殻）（v2: C13, C20）
    frames.dart             リンクフレームのエンコード/デコード（ストリームパーサ）
    compression.dart        raw deflate + 辞書、伸長上限
    dictionary.dart         kDictionaryV1（災害通知コーパス辞書）
    categories.dart         カテゴリ定義・ラベル・既定 TTL・例文・「終わりました」の見出し・通知の重要度・訓練の接頭辞（v2: C15, C01, C05, C23）
    ids.dart                node_id / 参加コード / 本部コード・スタッフコードとそのダイジェスト（v2: C09, C24）
  mesh/
    transport.dart          Transport インターフェースと TransportEvent
    message_store.dart      保存・検索・優先度・削除・相対期限・不透明メッセージ・空殻・先出し候補（永続化は store_file.dart）（v2: C12, C13, C20, C08）
    report_inbox.dart       本部・スタッフの受信記録（報告＋最新返信、30 日、容量上限）（v2.4）
    receive_budget.dart     複数接続で共有する保存待ちの件数・バイト上限（v2.4）
    store_file.dart         追記型ログの読み書き
    sync_session.dart       1 リンクの同期状態機械（先出し・TIME・中継役どうしの緩和）（v2: C08, C12, C17）
    mesh_node.dart          発見→接続判断→セッション生成、バックオフ、再接続、中継役モード、時計差の中央値（v2: C04, C12）
    groups.dart             参加グループ・本部／スタッフ昇格・発信元名・世代と閉鎖の管理（v2: C09, C24）
  transport/
    ble_transport.dart      MethodChannel/EventChannel で ネイティブへ
    hub_transport.dart      開発用: TCP ハブ経由（tool/hub.dart）
    fake_transport.dart     テスト用: インメモリ、決定論
  ui/
    screens/ (shell, home, notice_detail, compose, groups, group_detail, group_created, join, create_group, settings, onboarding, diagnostics)
    widgets/ (notice_card, big_button, status_bar, ...)
android/app/src/main/kotlin/jp/kairanban/kairanban/
  KairanApplication.kt      FlutterEngine をキャッシュ生成（"main"）
  MainActivity.kt           キャッシュ済みエンジンを使う FlutterActivity
  MeshService.kt            connectedDevice 型 Foreground Service
  BootReceiver.kt           BOOT_COMPLETED → MeshService
  ble/BleBridge.kt          MethodChannel/EventChannel の実装
  ble/BleEngine.kt          advertiser + scanner + GATT server + GATT client
ios/Runner/
  AppDelegate.swift         プラグイン登録 + BleBridge 登録
  Ble/BleBridge.swift       MethodChannel/EventChannel
  Ble/BleEngine.swift       CBCentralManager + CBPeripheralManager（復元対応）
tool/hub.dart               開発用 TCP ハブ（模擬電波）
test/                       Dart ユニットテスト・多ノード模擬テスト
```

## 3. Dart ↔ ネイティブ契約（Platform Channel）

MethodChannel: `jp.kairanban/ble`、EventChannel: `jp.kairanban/ble/events`。
すべての引数・戻り値は Map/List/基本型/Uint8List のみ。

### メソッド

| method | 引数 | 戻り値 | 説明 |
|---|---|---|---|
| `getState` | なし | `{supported: bool, poweredOn: bool, permission: "granted"\|"denied"\|"unknown", running: bool}` | 現在状態 |
| `requestPermissions` | なし | `bool` | Bluetooth 権限を要求（Android 12+: SCAN/ADVERTISE/CONNECT、Android 11 以下: FINE_LOCATION、iOS: CoreBluetooth 初期化で自動） |
| `start` | `{serviceUuid, rxUuid, txUuid: String, nodeId: Uint8List(8), lowPower: bool}` | なし | 広告 + GATT サーバ + スキャンを開始。Android は MeshService を前景起動 |
| `stop` | なし | なし | すべて停止（Android は MeshService 停止） |
| `setLowPower` | `{lowPower: bool}` | なし | スキャン/広告の省電力モード切替 |
| `connect` | `{peerId: String}` | なし | 接続要求。結果は `linkOpened` / `linkClosed` イベント |
| `send` | `{linkId: int, data: Uint8List}` | なし | 1 チャンク送信。**スタックに渡し終わるまで完了しない**（Dart は直列に await してフロー制御する）。`data.length <= maxChunk` |
| `close` | `{linkId: int}` | なし | リンク切断 |
| `requestBatteryOptimizationExemption` | なし | `bool` | Android のみ。iOS は true を返す |
| `openAppSettings` | なし | なし | OS の設定画面を開く |
| `noteReceived` | `{at: int}`（Unix ミリ秒） | なし | お知らせを受け取った。iOS は Live Activity の「最後に 受け取ったのは …」に使う（更新は 15 分に 1 回程度に間引く）。Android・未対応環境は何もしない |
| `requestNotificationPermission` | なし | `bool` | OS の通知権限を要求（Android 13+: POST_NOTIFICATIONS、iOS: `UNUserNotificationCenter.requestAuthorization([.alert, .sound, .badge])`）。許可済み・Android 12 以下は要求せず true。画面が無い（Android で Activity 未接続）なら false |
| `showNotice` | `{id: int, title: String, body: String, groupCode: int, importance: "urgent"\|"important"\|"normal", msgId?: int}` | なし | 新しいお知らせの OS ローカル通知を出す。`id` は msg_id の下位 31 ビット（同じ id は置き換える。続けて届いた分を「N 件」に更新するため）。`importance` でチャネルと割り込みレベルを選ぶ（Android: urgent = IMPORTANCE_HIGH・振動 3 回、important = DEFAULT、normal = LOW。iOS: timeSensitive / active / passive。午後 10 時〜午前 6 時は urgent だけ音）。`msgId` があればタップでその詳細を開く。Dart 側の既定は important。前面かどうかの判定は Dart 側が行い、前面では呼ばない（v2: C05） |
| `cancelNotice` | `{id: int}` | なし | 出した通知を消す（取り消し・置き換えされた避難情報・注意喚起）（v2: C05） |
| `setKeepScreenOn` | `{on: bool}` | なし | 画面を消さない（iOS `isIdleTimerDisabled`、Android は Activity のウィンドウフラグ `FLAG_KEEP_SCREEN_ON`）。中継役の間と「画面を 点けたままにする（30 分）」で使う（v2: C04, C07） |
| `playChime` | なし | なし | 交換完了の短い音 1 回＋振動 1 回（iOS `AudioServicesPlaySystemSound`、Android `ToneGenerator`。外部プラグインなし）（v2: C04） |
| `getBattery` | なし | `{level: 0..100, charging: bool}` | 電池残量と充電中か（Android `ACTION_BATTERY_CHANGED`、iOS `UIDevice.batteryLevel`）。取れない環境は null または level < 0 を返し、Dart 側は自動「長持ち」判定をしない（v2: C06） |
| `speak` | `{text: String, rate: double}` | なし | OS 標準の音声合成で読み上げる（iOS `AVSpeechSynthesizer` ja-JP、Android `TextToSpeech`）。Dart は rate 0.8 固定で呼ぶ（v2: C19） |
| `stopSpeaking` | なし | なし | 読み上げを止める（v2: C19） |
| `scheduleReminder` | `{title: String, body: String}` | なし | 月 1 回（毎月 1 日 午前 10 時）の確認通知を予約する（iOS `UNCalendarNotificationTrigger(repeats)`、Android 非正確アラーム＋BootReceiver）。Dart は通知レベルが「知らせない」以外のとき init 時と設定変更時に呼ぶ。「直近 14 日 アプリを開いていない端末だけ」の判定は未実装（Dart は `lastOpenedAt` を設定に保存するのみ）（v2: C07） |
| `cancelReminder` | なし | なし | 月 1 回の確認通知を取り消す（通知レベルが「知らせない」のとき）（v2: C07） |

**ネイティブ側の実装状況と未対応環境の方針**（v2: C04〜C07, C19）: v2 で追加したメソッド（`cancelNotice` 以降と、`showNotice` の `importance` / `msgId`）は iOS / macOS（`BleBridge.swift` の `DeviceActions`、`NoticeNotifier.swift`）と Android（`BleBridge.kt`、`NoticeNotifier.kt`、`ReminderReceiver.kt`）で実装済み。macOS は電池を返さず（`getBattery` → null）、音は `NSSound.beep()`、画面点灯は `ProcessInfo.beginActivity`。iOS の `.timeSensitive` は Time Sensitive Notifications の capability を付けるまで `.active` 相当で出る。ハブ／テスト用トランスポート（`NoopPlatformActions`）やネイティブが無い環境では、Dart 側の `BleTransport._guard` が `PlatformException` / `MissingPluginException` を `TransportLog`（診断ログの `[transport] ... 失敗` 行）にして握りつぶし、null を返す（`connect` / `send` だけは呼び出し元が失敗を知る必要があるため再送出）。したがってこれらの機能は、ネイティブが無い環境では「何も起きない」だけでアプリは動く。

### イベント（Map）

| type | フィールド | 説明 |
|---|---|---|
| `state` | `poweredOn, scanning, advertising, permission` | 状態変化 |
| `discovered` | `peerId: String, rssi: int, viaApple: bool` | 候補を発見。同じ peerId の連続通知はネイティブで 2 秒に 1 回に間引く |
| `linkOpened` | `linkId: int, peerId: String, maxChunk: int, initiator: bool` | リンク確立。`initiator=true` は自分が central |
| `data` | `linkId: int, data: Uint8List` | 受信チャンク |
| `linkClosed` | `linkId: int, reason: String` | 切断 |
| `log` | `message: String` | 診断ログ |

### ネイティブ側の責務
- **Android**: `BluetoothLeAdvertiser`（legacy, connectable, Service UUID のみ, BALANCED/LOW_POWER）、`BluetoothLeScanner`（ScanFilter: Service UUID と Apple 製造者データ 0x004C 先頭 0x01 の 2 本、BALANCED/LOW_POWER、10 分ごとに張り直し、30 秒 5 回制限を守る）、`BluetoothGattServer`（RX: WRITE_NO_RESPONSE|WRITE、TX: NOTIFY + CCCD）、GATT client（`requestMtu(517)` → サービス探索 → TX の通知有効化 → `linkOpened`）。peripheral 側は central が TX の通知を有効化した時点で `linkOpened(initiator=false, maxChunk = 負ノゴシエート MTU − 3)`。`send` は central なら RX へ Write Without Response（API 33+ は戻り値 BUSY を見て待つ）、peripheral なら TX の `notifyCharacteristicChanged`（`onNotificationSent` を待つ）。同時接続は central として最大 2、peripheral として最大 4（中継役の central 3 は Dart 側 `MeshNode.maxInitiatorLinks` で制御する。ネイティブ側の上限引き上げは未実装）（v2: C04）。`connectedDevice` 型 Foreground Service（通知タイトル「回覧板」、本文「近くの人と情報を交換しています」）。BOOT_COMPLETED で再開。
- **iOS**: `CBCentralManager`（restore identifier `jp.kairanban.central`、`scanForPeripherals(withServices: [service])`、AllowDuplicates false）、`CBPeripheralManager`（restore identifier `jp.kairanban.peripheral`、service + RX/TX、`startAdvertising([CBAdvertisementDataServiceUUIDsKey: [service]])`）。central は `maximumWriteValueLength(for: .withoutResponse)` を maxChunk とし、`canSendWriteWithoutResponse` を待って書く。peripheral は `updateValue` が false を返したら `peripheralManagerIsReady` を待つ。`didDiscover` の advertisementData では `CBAdvertisementDataServiceUUIDsKey` と `CBAdvertisementDataOverflowServiceUUIDsKey` の両方を見る。`willRestoreState` で復元した peripheral を再接続する。Dart 側が準備できる前のイベントはバッファして流す。
  - **購読の後始末（再接続時の取りこぼし防止）**: Apple 同士では両方の役割が 1 本の物理接続を共有するため、片方が `cancelPeripheralConnection` しても接続と TX 通知の購読が残ることがある。その状態で次のリンクを開くと central 側の `setNotifyValue(true)` は CCCD を書き直さず、peripheral 側に `didSubscribeTo` が来ないので書き込みを「未購読」として捨て、HELLO 待ちタイムアウト（5 秒）が毎回起きる（2026-10-14 の Mac ↔ iPhone 実測で発見）。対策は 5 つ: ①リンクを閉じるときは `setNotifyValue(false)` で購読を明示的に解除する ②特性発見時に `isNotifying` ならいったん解除してから購読し直す ③peripheral 側は `subscribedCentrals` に含まれる central からの書き込みが来たらリンクを開き直す ④同じ相手が central としてこちらに接続中なら物理接続を切らない ⑤③の例外として、こちら（Dart）側が閉じたリンクの central は `closedCentrals` に覚えておき、相手が購読し直す（`didUnsubscribeFrom` → `didSubscribeTo`）までは書き込みでリンクを開き直さない。これがないと、重複セッションの整理やタイムアウトでこちらが閉じた直後に届く相手の BYE や送信済みチャンクが「新しいセッション」と誤認され、HELLO より前に BYE を受けて失敗するだけの幻のセッションが毎回記録され、相手に 30 秒のバックオフが付く（2026-10-15 のコードレビューで指摘）。
  - **既知ピアへの接続待ち（pending connect）**: central としてリンクが開いた相手（サービスと TX 通知まで確認できた CBPeripheral）を「最近つながった相手」として最大 4 台覚え、切断の 60 秒後に `connect(peripheral, options: [CBConnectPeripheralOptionEnableAutoReconnect: true])`（iOS 17 未満は通常の `connect`）を出し直す。iOS の `connect` はタイムアウトしないため、両方の画面が消えたバックグラウンドでも相手が圏内に戻ればOS が自動で接続し、`didConnect` から通常の流れ（サービス探索 → TX 通知の有効化 → `linkOpened(initiator: true)`）に乗せる。Dart 側の `MeshNode` は `linkOpened` を受ければ同期を始めるので、Dart の変更は不要。iPhone の BLE アドレスは約 15 分で回転するため保持は 20 分で期限切れにし、期限切れ・上限超過・`stop` では `cancelPeripheralConnection` で接続待ちを取り消す（リンク中なら取り消さずにリンクが終わるまで続ける）。60 秒待つのは、圏内に居続ける相手と数秒おきに接続と切断を繰り返さないため（Dart の再同期間隔と同じ）。`willRestoreState` で復元された「接続待ち」の peripheral も同じ仕組みに取り込む。Bluetooth が OFF → ON になったときと Dart の `start` 時にも、覚えている相手の接続待ちを出し直す。
  - **Live Activity（iOS 16.1 以上）**: `start` で「回覧板 近くの人と 交換中 / 最後に 受け取ったのは …」の Live Activity を出し、`stop` で消す（`ios/Runner/LiveActivity/LiveActivityController.swift`、表示は Widget Extension `ios/KairanLiveActivity`）。`noteReceived` で受け取った時刻は 15 分に 1 回までしか表示に反映しない。Live Activity の開始は前面でしか許されないため、バックグラウンドで `start` が来たときは次に前面へ来たときに出す。iOS 26 では Live Activity を出している間、画面点灯中（ロック中を含む）はバックグラウンドでも前面と同等の権限でスキャンできる（Apple の Core Bluetooth 概要に記載）。
- 両 OS とも `connect` のタイムアウトは 10 秒（iOS は `connect` がタイムアウトしないため自前でキャンセル）。

## 4. バックグラウンド戦略
- Android: Dart の `start` → `MeshService.startForeground`。`KairanApplication.onCreate` で FlutterEngine を生成し Dart `main()` を実行、`FlutterEngineCache` に登録。`MainActivity` はキャッシュ済みエンジンを使うため、画面を閉じても Dart は生き続ける。BOOT_COMPLETED → `MeshService` 起動 → Application 経由でエンジン生成 → Dart が設定を読み自動で `start`。
- iOS: `UIBackgroundModes = [bluetooth-central, bluetooth-peripheral]`。状態復元で再起動された場合、`AppDelegate` が Flutter エンジンを起動し、Dart が設定を読んで `start` → ネイティブはバッファしたイベントを流す。
  - 制約: iPhone 同士が両方とも画面消灯のバックグラウンドだと互いを発見できない（バックグラウンドの広告は overflow 領域に入り、バックグラウンドのスキャンはそれを拾えない。Apple が回避策なしと明言）。緩和策は 2 つ: (1) 既知ピアへの接続待ち（§3）— 一度つながった相手とは、両方とも画面消灯でも圏内に戻れば再接続して同期できる（20 分以内の再会に限る）。(2) Live Activity（§3）— iOS 26 では Live Activity を出している間、画面が点いていれば（ロック中でも）前面と同等にスキャンできる。Android が近くに 1 台あれば、Android は両方を発見できるので橋渡しされる。
- Dart 側は `start` 済みかを `shared_preferences` の `mesh.enabled` に保存し、起動時に自動再開する。
- **取りこぼし対策（v2.2、2026-10-24）**:
  - iOS の状態復元起動（iOS がアプリを終了させたあと BLE の出来事で背面起動）ではシーンがつながらず暗黙のエンジンが作られないため、`AppDelegate` が画面なしの `FlutterEngine` を起動して `main()`（`implicitView` が無ければ `runApp` しない）と BleBridge を動かす。利用者が開いて暗黙のエンジンができたら画面なしのエンジンを止める（同じ保存ファイルを 2 つで触らない）。`BleEngine` は Dart の `start` を待たずに前回の動作設定（UserDefaults）で広告・スキャンを続け、受け口が無い間のイベントを溜めて `setEventHandler` で流す。
  - iOS の背面では既知ピアへの接続待ちの出し直しを 60 秒 → 20 秒にし、バックグラウンドタスクで起きている間に出す（60 秒のタイマーは背面で止まるため）。前面のスキャンは重複を知らせる（`AllowDuplicates`、通知は 2 秒に 1 回へ間引く）。背面では BLE の出来事で起きたときにスキャンが 30 秒以上前ならかけ直し、近くの相手を知らせ直させる。前面・背面の切り替えでもかけ直す。サービスが無い相手の理由は `no_service` に統一（Dart はこのときだけ 15 分無視する）。
  - Android は native の同時接続上限を 4 にして Dart（通常 2・中継役 3）の判断を断らない。API 33 未満では `connectGatt` に handler を渡さない（通知の値が上書きされて取りこぼすため）。BLE の出来事のたびに期限付きの部分ウェイクロック（発見 10 秒、リンク・受信 60 秒）を取り、画面オフでもタイマーが止まらないようにする（`WAKE_LOCK`）。peripheral 側は MTU の知らせが購読より後に来る端末のため最大 0.5 秒待ってから `linkOpened` を出し、その間の受信は溜める。central 側は切断前に購読を解除する（物理接続が残ったとき iPhone が次の書き込みを捨てないように）。接続を受けたあとの広告のかけ直しはしない（Android は広告を始め直すたびにアドレスが変わり、相手が別の端末と見て接続し続けるため。エミュレータで確認）。
  - Mac は窓を閉じてもアプリを終了せず（Dock から開き直す）、動作中は App Nap を止める（`beginActivity`）。
- **新しいお知らせの OS 通知**（docs/01 R-26、docs/08 C05）: `AppController` が `MessageStore` の変化を監視し、参加グループに新しく入った「自分の投稿でない未読の notice」を集める。起動時点でストアにあったもの・未参加グループのものは対象外。ハブ／テスト用トランスポートでは `NoopPlatformActions` が何もしない。（v2: C05）
  - **3 段階**（`NotificationLevel`）: 「ぜんぶ 知らせる」（all）／「公式と 大事なものだけ 知らせる」（important、既定）／「知らせない」（off）。v1 の 2 択は important / off に引き継ぐ。（v2: C05）
  - **重要度の決め方**（`NoticeImportance`、`AppController.importanceOf`）: 見出しが「【訓練】」なら normal。役割が公式・スタッフで種別が避難情報・注意喚起なら **urgent**。役割が公式・スタッフ、または種別固有の重要度が normal でない（避難情報・注意喚起・避難所・物資・給水・炊き出し・医療・救護。住民の避難情報はここに入る）なら **important**。残りは **normal**。設定 important のとき normal は通知しない（画面の「新しい お知らせが N 件」だけ）。role・category は署名がないため偽れる（docs/01 §5）。（v2: C05, C23）
  - **urgent**: まとめずに 1 件ずつ即時。通知 ID はその msg_id の下位 31 ビット、`msgId` 付き（タップで詳細）。見出し先頭の「【避難】」「【注意】」は role=2 のときだけ。グループごとに 10 分に 3 件まで、超えた分は important のまとめ通知に回す。取り消し・置き換えされた urgent は `cancelNotice` で同じ id の通知を消す。（v2: C05）
  - **important / normal**: 背面では 5 秒待って続けて届いた分をまとめ、1 件なら「見出し ／ 文面」、複数なら「新しい お知らせが N件 あります ／ 最新の見出し ほか」（訓練だけなら「【訓練】新しい お知らせが N件」、混在なら「新しい お知らせが N件（うち 訓練 M件）」）を `showNotice` で出す。通知 ID は最初に届いた msg_id の下位 31 ビットで、前面に戻るまで同じ通知を更新する。重要度はまとめた中の最大（urgent は important に下げる）。出す直前に既読・取り消し・置き換え・期限切れ・脱退済みを除く。（v2: C05, C23）
  - **文面**（`AppController.notificationBody`）: 「場所: 〇〇 ／ 本文 1 行目（30 文字、末尾「…」）」。本文 1 行目を入れるのは避難情報・注意喚起・避難所・給水・炊き出し・物資だけ。どちらも空なら「〇〇 から」。（v2: C05）
  - **前面**（`WidgetsBindingObserver` の `AppLifecycleState.resumed`。`KairanApp` が `AppController.setForeground` で伝える）では OS 通知を出さず、画面の「新しい お知らせが N 件 あります」に任せる。urgent は `foregroundUrgentIds` に積み、画面が赤地白文字の帯「避難情報が 届きました ▶ 見る」と振動 3 回で示す（`acknowledgeUrgent` で消す）。前面に戻ったらまとめ待ちは捨て、`lastOpenedAt` を設定に保存する。（v2: C05, C07）
- **月 1 回の確認通知**（docs/08 C07）: 通知レベルが off 以外なら init 時と設定変更時に `scheduleReminder`（「回覧板の 確認です。災害では ありません ／ 開いて 動いているか 確かめてください」）、off なら `cancelReminder`。独立したスイッチは置かない。（v2: C07）
- **電池と自動「長持ち」**（docs/01 R-25、docs/08 C06）: `AppController.refreshBattery` が init 時と 1 分ごと（期限掃除と同じタイマー）に `getBattery` を読み、充電中なら「ふつう」、20% 以下（非充電）なら「長持ち」、50% を超えたら「ふつう」に戻す（20〜50% の間は前の判定を保つ）。実際に `MeshNode.setLowPower` へ渡す値は、中継役なら常に false、それ以外は「設定の 長持ち OR 自動判定」。設定画面は `battery` と `autoLowPower` で「今の 残量 35%（充電中）・ 今は ふつう」を出す。`getBattery` が null の環境では判定しない。（v2: C06, C04）
- **画面点灯**（docs/08 C04, C07）: 中継役をオンにすると `setKeepScreenOn(true)` を保ち続ける（オフで解除）。「画面を 点けたままにする（30 分）」は `AppController.keepScreenOn` が 30 分のタイマーを張り、`keepScreenOnUntil` を公開する。背面に行ったら即解除。中継役の間は解除しても消灯させない。（v2: C04, C07）

## 5. 同期ロジックの要点（`mesh_node.dart`）
- `discovered` → バックオフ表（peerId / node_id）を確認 → 空きスロットがあれば `connect`。
- `linkOpened` → `SyncSession` を生成（§4 of protocol）。
- 送信は `Transport.send` を直列 await（フロー制御）。
- 保存内容が変わったら `storeVersion++`、バックオフ表の「同期済み」を無効化。
- **再接続の見直し**（v2.2）: 15 秒ごとのティックとセッション終了のたびに `_reconnectRecentPeers` で近くの相手（60 秒以内に見えた相手、または 1 度同期できて 2 × 再接続間隔 + 15 秒以内に見えた相手）を「未同期 → 最後の同期が古い → 電波が強い」順に見直す。同期の後に相手が持っているはずの msg_id（相手の目録 ∪ 渡した ∪ 受け取った）を node_id ごとに覚え、それに無い中継できるものが入ったら間隔内でもすぐ接続する（受け取ったものを別の相手へすぐ渡す）。打ち切り（MESSAGES_END bit0）は 2 秒後に続き、受信リンクでしか会えない相手（bit1）とは 20 秒間隔。ネイティブが自分で断った接続（`busy`・`duplicate`・`alreadyConnecting`・`not_running`・`poweredOff`）は失敗に数えない。Apple の背面広告由来の候補は 3 回続けて失敗したときだけ 15 分無視する。近くの端末数は HELLO の node_id でまとめて数え、30 分見ていない相手の記録は捨てる。
- **中継役モード**（`MeshNode.setRelayMode`、docs/08 C04, C17）: HELLO の caps に bit1 を立て、参加グループ（`store.joinedGroupIds` の先頭 8 件）を末尾に載せる（私物端末は載せない）。central の同時リンク上限を 2 → 3 に広げる（`maxInitiatorLinks`）。自分が中継役で、前回の同期で相手も中継役だった node_id とは再接続間隔を 60 秒 → 10 秒に縮める（`store.version` が変われば待たないのは v1 と同じ）。セッション上限 1 MB（maxChunk < 180 なら 256 KB）・全体 300 秒への差し替えは `SyncSession` が両方の HELLO を見て転送開始前に行う。`AppSettings.relayMode` の変更は `AppController.saveSettings` が `setRelayMode` と `setKeepScreenOn` に反映する。（v2: C04, C17）
- **時計の差**（docs/08 C12）: 各セッションが HELLO 直後の TIME から「相手の時計 − 自分の時計」を受け取り（`SyncSession.onPeerTime`）、`MeshNode` は直近 8 件の中央値を `clockOffsetSeconds` として公開する。1 時間を超えるずれは診断ログに残す。`AppController.clockLooksWrong` は「now が 0（2026 年より前）または中央値が 24 時間超」で、書く画面の警告に使う。（v2: C12）
- **時刻の記録**（docs/08 C07, C18）: 同期が成功するたび `lastSyncAt`、MESSAGE を 1 件以上送ったら `lastSentAt`、受け取ったら `lastReceivedAt` を更新し、`totalMessagesSent` を足す。`onSyncCompleted(at, sent, received)` で `AppController` が `settings.lastSyncAt` を永続化し、中継役かつ「交換の 音」オンで送受どちらかが 1 件以上なら `playChime` を呼ぶ。（v2: C07, C04, C18）

## 6. テスト
- `test/core/*`: 封筒・フレーム・圧縮のラウンドトリップ、境界、破損入力。
- `test/mesh/*`: FakeTransport で 2 ノード同期、3〜20 ノードの epidemic 伝播（すれ違い順をシード固定）、再接続抑制、容量上限。
- Android エミュレータ 2 台（netsim）で実機なしに発見→接続→同期を確認。
- iOS シミュレータは BLE 非対応のため `hub_transport` で UI と同期を確認。

## 7. 既知の制約（v2。前提は docs/01 §5、変えないと決めたことは docs/08 §5）

- **不透明メッセージ**（C13）: 理解できない版・種類・フラグの封筒は内容を確認せずに運ぶ（docs/02 §2.1）。表示も伸長もしないが、端末の保存枠（300 件かつ保存上限の 10%）とセッションの帯域（1 セッション 16 KB）を使う。旧版（v1）の端末は不透明メッセージを捨てるため、v2 の拡張を含む封筒は v1 の検証を通る形（version=1・既知 kind・予約 flags=0。help / ack と group_info の ext は v1 では破棄される）に収めている。診断画面には「表示できない お知らせ N 件（新しい 版）」とだけ出す（`store.opaqueCount`）。（v2: C13）
- **公式による取り消し**（C10, C20）: 署名がないため role=2 の tombstone も偽れる。「封筒の role が対象以上のときだけ適用」は正規アプリの住民操作を止めるだけで防御ではない。取り消しは受信端末からの本文消去（空殻化）を伴うため、偽造時の影響は v1 より大きい。本文は発信者本人の端末とそのグループの公式端末（`store.officialGroupIds`）に残るので、公式は再投稿で回復する運用とする。（v2: C10, C20）
- **相対期限**（C12）: 受信側は expires_at を自分の時計と比べないため、時計が狂った端末の投稿も届く（v1 では届かなかった）。代わりに中継のたびに expires_at を残り時間に書き直すので、受信側の時計で計った総寿命は元の有効期間を超えない。一覧の並び順は「届いた時刻」とし、created_at が未来・24 時間以上前のカードには時計ずれの注記を出す。保存ファイルには受け取った expires_at をそのまま書き、期限は読み込み後に受信時刻から計算し直す。（v2: C12）
- **ネイティブの追加メソッド**（C04〜C07, C19）: §3 の「ネイティブ側の実装状況と未対応環境の方針」のとおり。ネイティブが無い環境では何も起きないだけで通信には影響しない。（v2: C04）

## 改訂履歴

| 版 | 日付 | 内容 |
|---|---|---|
| v1 | 2026-10-11 | 初版 |
| v2 | 2026-10-21 | [08_use_cases.md](08_use_cases.md) の仕様変更を実装に合わせて反映。§2 モジュールの説明、§3 Platform Channel の追加メソッドと未実装時の方針、§4 通知 3 段階・月 1 回の確認通知・電池・画面点灯、§5 中継役モード・時計差・時刻の記録、§7 既知の制約を新設 |
| v2.2 | 2026-10-24 | メッシュの取りこぼし対策（§4 iOS の画面なしエンジン・イベントの溜め置き・背面の再接続とスキャン、Android の上限・handler・ウェイクロック・MTU 待ち・購読解除、Mac の常駐、§5 再接続の見直し） |
