# 回覧板（kairanban）

携帯網も Wi-Fi も使えない被災地で、スマートフォン同士の Bluetooth Low Energy（BLE）すれ違い通信だけで
「〇〇避難所に水が届きました」のような文字情報を広げるアプリです。
紙の回覧板が隣家へ回るように、端末がすれ違うたびに情報が複製されて広がります（store-and-forward）。

- iOS 15 以上 / Android 8.0 以上、Flutter 製（UI と同期ロジックは Dart、BLE だけ Swift / Kotlin）
- ペアリング不要、サーバ不要、暗号化なし（要件）。グループは 6 桁の参加コードで分ける
- 高齢者も使える「市役所の掲示板」風 UI（大きな文字、1 画面 1 目的、下部タブ 3 つ）
- 新しいお知らせが届いたら、アプリを閉じていても OS の通知で知らせる。通知は「ぜんぶ 知らせる / 公式と 大事なものだけ（既定）/ 知らせない」の 3 段階。公式・スタッフの避難情報・注意喚起は 1 件ずつ即時、それ以外の大事なものは 5 秒でまとめて「新しい お知らせが N 件 あります」（v2: C05）
- グループ作成者は 6 桁の参加コードに加えて「本部コード」（8 桁、先頭 1）と「スタッフコード」（8 桁、先頭 2）を配れる。本部コードで昇格した端末は公式（作成者と同じ権限）、スタッフコードで昇格した端末はスタッフ（投稿権のみ）（v2: C09, C24）
- 発信者は自分のお知らせを「書きなおす」「終わりました」で訂正できる。公式端末は同じグループの住民・スタッフの投稿を「公式として 取り消す」ことができ、取り消されたお知らせは受信端末から本文が消える（v2: C01, C10, C20）
- 設定「中継役として 使う」で、受付・集会所・物資車両などの端末を画面点灯・同時接続 3 台・中継役どうしは 1 MB までの交換に切り替えられる（v2: C04, C17）
- お知らせの期限は受信側の「届いた時刻 ＋ 残り時間」で判定し、端末の時計を信用しない。理解できない新しい版の封筒も中継だけは行うので、更新できない端末が混ざっても網が切れない（v2: C12, C13）

## ドキュメント

| ファイル | 内容 |
|---|---|
| [docs/01_requirements.md](docs/01_requirements.md) | 要件定義（機能・非機能・既知の制約） |
| [docs/02_protocol.md](docs/02_protocol.md) | ワイヤプロトコル（封筒 28 バイト、フレーム、同期セッション、v2 の変更一覧と割り当て表） |
| [docs/03_architecture.md](docs/03_architecture.md) | モジュール構成、Dart ↔ ネイティブの契約、バックグラウンド戦略 |
| [docs/04_ui_design.md](docs/04_ui_design.md) | UI 設計（配色・文字サイズ・画面一覧・文言規則） |
| [docs/05_dart_api.md](docs/05_dart_api.md) | Dart 内部 API |
| [docs/06_prior_art_and_novelty.md](docs/06_prior_art_and_novelty.md) | 先行事例（国内外の類似アプリ・研究・特許）と新規性の評価 |
| [docs/07_regulations.md](docs/07_regulations.md) | 関係する規制・ストア要件（Google Play / App Store / 日本の法令・ガイドライン）と対応状況 |
| [docs/09_operations.md](docs/09_operations.md) | 運用手引き（下書き）: 平時の準備とコードの扱い、中継役の置き方、運び役、住民からの知らせ、公式の書き方、訓練、デマ対応、掲示の紙。実測待ちの値は実機テストで埋める（C16） |
| [docs/08_use_cases.md](docs/08_use_cases.md) | ユースケース 74 件（誰が・いつ・何を、現行の ◯△✕）と v2 の仕様変更 C01〜C25（確定仕様・導入順・落とした案・変えないこと） |

## ビルド

```bash
flutter pub get
flutter build apk --debug            # Android
flutter build ios --simulator --debug --no-codesign   # iOS シミュレータ
flutter build ios --release          # iOS 実機（署名はプロジェクトの設定に従う）
flutter build macos --debug          # macOS（Mac ↔ iPhone の BLE 実測用、下記「macOS で試す」）
```

Android SDK は `ANDROID_HOME` で指す（この環境では `/opt/homebrew/share/android-commandlinetools`）。

## テスト

```bash
flutter analyze
flutter test                         # ユニットテスト（封筒・圧縮・ストア・同期・UI、約 300 件）
```

### 実機なしで通信を試す

**Android エミュレータ 2 台（本物の BLE スタックを仮想無線でつなぐ）**

```bash
emulator -avd kairanA -port 5554 -packet-streamer-endpoint default &
emulator -avd kairanB -port 5556 -packet-streamer-endpoint default &
flutter build apk --debug
adb -s emulator-5554 install -r build/app/outputs/flutter-apk/app-debug.apk
adb -s emulator-5556 install -r build/app/outputs/flutter-apk/app-debug.apk
```

2 台が `netsimd` 経由で互いを発見し、GATT で同期します（MTU 517）。片方でグループを作って投稿すると、数秒で他方に届きます。

**iOS シミュレータ（BLE 非対応）は TCP ハブで模擬**

```bash
dart run tool/hub.dart --port 7777
flutter build ios --simulator --debug --no-codesign --dart-define=KAIRANBAN_HUB=127.0.0.1:7777
xcrun simctl install booted build/ios/iphonesimulator/Runner.app
```

Android エミュレータからハブを使う場合は `--dart-define=KAIRANBAN_HUB=10.0.2.2:7777`。

### 画面を自動操作する統合テスト

```bash
dart run tool/hub.dart --port 7777      # 別ターミナルで
# 1 台で「はじめに → グループ作成 → 投稿」まで
flutter test integration_test/mesh_e2e_test.dart -d <device> --dart-define=KAIRANBAN_HUB=127.0.0.1:7777
# 2 台で往復（同時に起動する）
flutter test integration_test/mesh_e2e_test.dart -d <iOS simulator> \
  --dart-define=KAIRANBAN_HUB=127.0.0.1:7777 --dart-define=KAIRANBAN_TEST_ROLE=host
flutter test integration_test/mesh_e2e_test.dart -d <Android emulator> \
  --dart-define=KAIRANBAN_HUB=10.0.2.2:7777 --dart-define=KAIRANBAN_TEST_ROLE=guest
```

## アプリアイコン

`assets/icon/icon.png`（iOS 用 1024px）と `assets/icon/icon_foreground.png`（Android アダプティブ用の前景）が元画像です。
変更したら次で全サイズを再生成します。

```bash
dart run flutter_launcher_icons
```

## 構成

```
lib/core        封筒・フレーム・辞書付き圧縮・カテゴリ
lib/mesh        保存・同期セッション・発見/接続判断・グループ
lib/transport   BLE（Platform Channel）/ TCP ハブ / テスト用フェイク
lib/ui          画面とウィジェット
android/        Kotlin: 広告・スキャン・GATT サーバ/クライアント・常駐サービス
ios/Runner/Ble  Swift: CoreBluetooth central + peripheral（状態復元・既知ピアへの接続待ち）
ios/Runner/LiveActivity  Swift: Live Activity の出し入れ（iOS 16.1 以上）
ios/KairanLiveActivity   Widget Extension: Live Activity の表示
macos/          macOS 版（BLE は ios/Runner/Ble を共用。ウィンドウと BLE の生成は macos/Runner/MainFlutterWindow.swift）
tool/hub.dart   開発用の模擬電波ハブ
integration_test/  端末上の自動操作テスト
```

### iPhone 2 台で試す（実機）

iOS シミュレータは BLE が使えないため、既知ピアへの自動再接続と Live Activity は実機でしか確認できません。
2 台とも `flutter build ios --release`（または Xcode から Run）で入れたうえで、次の順に試します。

1. 両方で「はじめに」を済ませ、Bluetooth を許可し、片方でグループを作ってもう片方が 6 桁の参加コードで参加する。作った側に表示される本部コード（先頭 1）・スタッフコード（先頭 2）は、もう片方をグループ詳細の「本部コードを 入れる」「スタッフコードを 入れる」で公式・スタッフに昇格させるときに使う（本部コードは、グループ情報が届いてコードのダイジェストと一致したときだけ受理される）。（v2: C09, C24）
2. 両方ともアプリを前面にしたまま近づける。設定 → 通信の状態（診断）に「発見」「リンク確立」「同期完了」が出ることを確認する。ロック画面と Dynamic Island に「回覧板 近くの人と 交換中」が出る（iOS 16.1 以上）。
3. 両方ともホームへ戻って**画面を消し**、どちらかで（画面を点けて）お知らせを投稿してから再び画面を消す。1〜2 分以内にもう片方へ届けば、既知ピアへの接続待ち（切断後 60 秒で再発行）が働いている。診断には「connect: 接続待ち」「connected: 自動接続」が出る。
4. 片方を 30 m 以上離してから 5 分ほどで戻す（20 分以内）。戻ったときに自動で「リンク確立」が出れば、圏外→圏内の自動接続が働いている。20 分を超えてから戻した場合は、相手の BLE アドレスが回転しているため再発見（画面点灯）が必要。
5. iOS 26 の端末では、両方とも画面消灯で届かないことを確かめたあと、片方の画面を点けたまま（ロック中でよい）にして届くことを確かめる（Live Activity が出ている間はロック中でも前面と同じようにスキャンできる）。
6. 設定 → 通信を 止める、で Live Activity が消え、接続待ちも取り消されることを確認する。

ログは Console.app で `subsystem:jp.kairanban` を絞り込むと、Dart へ流したものと同じ内容が見られる。

### macOS で試す（Mac ↔ iPhone の BLE 実測）

Mac にも同じアプリを入れると、Mac と iPhone の間で本物の BLE 同期を試せます。
BLE 部分は `ios/Runner/Ble` の Swift を macOS でもそのままコンパイルしています（Live Activity と状態復元は macOS にはありません）。

```bash
flutter build macos --debug
open build/macos/Build/Products/Debug/kairanban.app
```

- 初回起動時に macOS が Bluetooth の許可を求めます。あとから変えるときは システム設定 → プライバシーとセキュリティ → Bluetooth で「回覧板」を許可します（アプリの 設定 →「設定を開く」からも開けます）。
- 手順: Mac で グループを作る → iPhone で 参加コードを入れて参加 → Mac から投稿 → 数秒〜1 分で iPhone に届く。iPhone がロック中なら OS の通知で知らせる。
- ログは `log show --last 5m --predicate 'subsystem == "jp.kairanban"' --style compact`、または Console.app で `subsystem:jp.kairanban` を絞り込む。

**Mac 側を自動で動かす（demo ロール）**: 統合テストの `demo` ロールは、ハブなしの本物の BLE で
「はじめに → グループ作成 → 参加コードを画面とログに表示 → 5 分ごとに投稿 → 届いたお知らせをログに出す」を
指定した分数だけ続けます。iPhone 側は人が操作し、ログに出た 6 桁の参加コードで参加します。

```bash
flutter build macos --debug -t integration_test/mesh_e2e_test.dart \
  --dart-define=KAIRANBAN_TEST_ROLE=demo --dart-define=KAIRANBAN_DEMO_MINUTES=30
open build/macos/Build/Products/Debug/kairanban.app
tail -f ~/Library/Containers/jp.kairanban.kairanban/Data/Library/Application\ Support/jp.kairanban.kairanban/demo_log.txt
```

`flutter test -d macos` ではなく `open` で起動するのは、テストランナーの子プロセスとして起動すると macOS（TCC）が
親プロセスの Info.plist を見て「Bluetooth の説明文がない」として落とすためです。
ログの `[demo hh:mm:ss] 参加コード: 123 456` がコード、`★ 受信:` が iPhone から届いたお知らせです。

## 既知の制約

- iPhone 同士は両方の画面が消えていると互いを発見できません（Apple の仕様）。画面が点いていれば（ロック中でも）見つけられます。一度つながった相手とは、切断後も 20 分間は接続待ちを出しておくので、両方とも画面消灯でも圏内に戻れば自動で再接続します（最大 4 台）。iOS 26 では Live Activity を出している間、画面点灯中はロック中でも前面と同等に発見できます。Android が近くに 1 台あれば橋渡しされます。避難所の受付端末・集会所・物資車両などは 設定 → 通信 →「中継役として 使う」をオンにしてください（画面を消さず、同時接続を 3 台に広げ、交換が終わるたびに音で知らせます。電池を多く使うので充電しながら使い、iPhone はアプリを前面にしたままにします）。（v2: C04）
- iOS の Live Activity は iOS 16.1 以上で表示されます。開始はアプリが前面のときだけ許されるため、バックグラウンドで通信が再開した場合は次にアプリを開いたときに表示されます。
- Android では常駐通知が出ます。機種によっては省電力設定の除外が必要です。
- 新しいお知らせの通知は OS の通知許可が必要です（初回案内で求めます。あとから設定 →「通知を 許可する」でも求められます）。アプリを開いている間は通知を出さず、画面の「新しい お知らせが N 件 あります」で示します（公式・スタッフの避難情報・注意喚起は赤い帯と振動で示します）。自分の投稿・参加していないグループのお知らせは通知しません。既定の「公式と 大事なものだけ」では住民の一般のお知らせは通知しません（「ぜんぶ 知らせる」で通知）。緊急の通知はグループごとに 10 分で 3 件までで、超えた分はまとめます。（v2: C05）
- 暗号化・署名がないため、公式表示は参加コードと本部コード／スタッフコードの運用で守ります（封筒に将来の署名用フィールドを予約済み）。本部コードはグループ情報に載るダイジェストと照合しますが、なりすまし対策ではありません。公式による取り消しも偽れるため、公式は再投稿で回復する運用とします。理解できない新しい版のお知らせは内容を確認せずに運びます。（v2: C09, C24, C10, C13）
