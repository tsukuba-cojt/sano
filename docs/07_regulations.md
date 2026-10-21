# 回覧板 関係する規制・ストア要件（2026 年 10 月時点）

最終更新: 2026-10-14

本書は、回覧板（BLE すれ違い通信によるオフライン災害お知らせ配信アプリ、[01_requirements.md](01_requirements.md) / [03_architecture.md](03_architecture.md)）を**配布・運用するうえで関係する法令・ガイドライン・アプリストアのポリシー**を、2026 年 10 月時点で有効または予定されているものに絞って整理したものである。類似アプリ・先行研究との比較と新規性は [06_prior_art_and_novelty.md](06_prior_art_and_novelty.md) に書いてあり、本書では扱わない。

調査は Web の一次情報（Google・Apple・省庁の公式ページ）を優先し、二次情報しか無いものは「二次情報」と明記した。期限や数値の重要なもの（§1 A1・A4・A5、§2 B1）は公式ページを再取得して確認済み。本リポジトリの現状は 2026-10-14 時点のソースとビルド成果物で確認した。出典は末尾 §6、本文中は [番号]。

## 0. 要点

- **今すぐ対応が必要なもの**は 5 つ: (1) Play Console の Foreground Service 申告（`connectedDevice`）と機能説明動画、(2) Play の Government apps 申告（自治体名を名乗る場合）、(3) 電池最適化除外を直接要求していることの正当化（Safety app として）、(4) 個人情報の扱いの明文化（表示名は任意・本名非推奨、平文で端末間を中継する旨をプライバシーポリシーに）、(5) 自治体との委託契約・調達仕様への安全管理条項。いずれも**コード変更ではなく提出資料・運用文書**の話である。
- **技術要件はおおむね充足している**: Xcode 26 / iOS 26 SDK でビルド済み（2026-04 から必須）、targetSdk 36（2026-08 から必須）、16 KB ページサイズ整列済み（2027-02 から更新ブロック）、iOS deployment target 15.0（2026-09 からの「iOS 13 以上」を充足）、FOREGROUND_SERVICE_CONNECTED_DEVICE 権限あり、プラグインのプライバシーマニフェスト同梱。
- **2027 年に効いてくる最大の変更は Android の開発者本人確認（developer verification）**で、Play 以外の経路（自治体サイトから APK 直配布など）を残すなら 2026 年中に組織アカウント（D-U-N-S）とパッケージ登録が要る。iOS 側はスマホ新法で代替マーケットプレイスが日本でも可能になったが、運営要件（USD 100 万の信用状）から自治体の独自配布は非現実的で、**App Store 配布が現実解**。
- **影響なし**: 電波法（技適済み端末の BLE は免許不要局、アプリ側手続きなし）、Android 15〜17 の BLE・FGS 関連の動作変更（`connectedDevice` と非ボンディング BLE は対象外）、ISMAP（クラウド非依存のため直接対象外）。
- 国のガイドラインに「住民のスマホ同士の BLE 通信」を名指しで扱ったものは見つからなかった。消防庁の手引きは防災アプリを「主たる手段ではなく補完手段」と位置づけており、自治体向け説明もその用語に合わせる。

## 1. Google Play / Android

凡例: 影響 = 高・中・低。「現状」は本リポジトリ（2026-10-14）で確認した状態。

| # | 項目 | 内容（要点） | 施行・期限 | 影響 | 現状と必要な対応 | 出典 |
|---|---|---|---|---|---|---|
| A1 | ターゲット API レベル要件 | 新規アプリ・更新は **API 36（Android 16）以上**。既存アプリは API 35 以上でないと、より新しい OS の端末の新規ユーザーに非表示。延長申請で 2026-11-01 まで猶予。2027 年の要求レベルは公式ページに未掲載（最終更新 2026-10-01 時点） | 2026-08-31（延長 2026-11-01） | 低 | **充足**（targetSdk = compileSdk = 36、docs/01 N-1）。2027 年夏に API 37 が要求される前提で Android 17 の変更（A3）を先取り確認 | [1] |
| A2 | Foreground Service 種類の申告 | Play Console「App content」で FGS 種類ごとに、機能説明・中断時の影響・**機能を起動する手順を示す動画**・ユースケースの申告が必要。`connectedDevice` の許容ユースケースは「Continuous Data Transfer to an External Device（Bluetooth, NFC, IR, USB, ネットワーク接続を要する外部機器とのデータ転送）」。API 34+ では `FOREGROUND_SERVICE_CONNECTED_DEVICE` 権限が必須 | 施行済み（Android 14 以降） | 中 | 権限は Manifest に宣言済み。**申告文面と動画**（起動 → 通信開始 → 常駐通知の流れ）を用意する。「近くのスマホ（外部 Bluetooth 機器）との継続的データ転送」と説明。却下に備え `specialUse` の申告文も準備 | [2][3] |
| A3 | Android 15 / 16 / 17 の動作変更 | **Android 15**: BOOT_COMPLETED から起動できない FGS 種別は dataSync / camera / mediaPlayback / phoneCall / mediaProjection / microphone で、**`connectedDevice` は対象外**。6 時間制限も dataSync / mediaProcessing のみ。**Android 16**: FGS 実行中でも JobScheduler / WorkManager のジョブがクォータ対象。BLE はボンディング喪失時の挙動変更のみ。API 36 向けは sw600dp 以上で画面向き固定が無効、edge-to-edge 強制。**Android 17**: RFCOMM read の -1 返却（Bluetooth Classic のみ）、ローカルネットワーク権限（BLE は対象外）、画面向きオプトアウト廃止。BLE スキャン・広告、FGS、通知、電池最適化、BOOT_COMPLETED に関する新規制限は公式ページに記載なし。Android 15 の「通知クールダウン」（連続通知の減音）はユーザー設定で、開発者 API は無い（二次情報） | Android 15: 2024-10 / 16: 2025-06 / 17: 2026-06（安定版の日付は二次情報） | 低〜中 | 起動時の FGS 開始は現状のまま可。WorkManager は未使用。新着通知は 5 秒のデバウンスで 1 件にまとめている（docs/03 §4）ので連投による減音の影響は小さい。タブレットで画面向き固定に依存しない UI（現状は依存なし） | [4][5][6][7][8] |
| A4 | 16 KB ページサイズ対応 | 「all apps targeting Android 15 (API level 35) and higher must support 16 KB memory page sizes on 64-bit devices on Google Play. **Starting February 1, 2027**, if your app updates don't support 16 KB memory page sizes, you won't be able to release these updates.」Java / Kotlin のみのアプリは対応不要、ネイティブ `.so` を含むアプリは整列の確認が要る | 2027-02-01（更新ブロック） | 中 | **充足を確認**: 2026-10-12 ビルドの debug APK を `zipalign -c -P 16 -v 4` で検証し「Verification successful」。arm64 の libflutter.so / libdartjni.so / libdatastore_shared_counter.so の ELF LOAD 整列は 16 KB 以上。リリース AAB（AOT の libapp.so を含む）は提出前に同じ検証を行う（Play Console の App Bundle Explorer「Memory page size」でも確認できる） | [9][10] |
| A5 | Android 開発者の本人確認（developer verification） | 認定 Android 端末（Android 7+）に入る**全アプリ**（サイドロード・他ストア含む）が、登録済み開発者のものに限られる。**2026-08**: Android Developer Console（Play 外配布用）、限定配布アカウント（最大 20 台・本人確認書類不要）、上級者向けフロー開始。**2026-09-30**: ブラジル・インドネシア・シンガポール・タイで施行。**2027 年**: 全世界へ拡大（日本の日付は未公表）。組織は D-U-N-S 番号（取得に最大 28 日）と検証済みウェブサイトが必要（ガイド・FAQ による）。未登録アプリは「開発者モードを有効化して 1 日待つ」上級者向けフローか ADB でしか入らない | 2026-08 / 2026-09-30 / 2027 年 | **高**（独自配布を残す場合） | Play 配布だけなら Play Console の登録で済む。**自治体サイトからの APK 直配布を残すなら、2027 年までに Android Developer Console で組織アカウント（D-U-N-S）を取得し、パッケージ名と署名鍵を登録**する。名義（自治体か委託事業者か）を早期に決める。住民に開発者モードを有効化させる運用は非現実的 | [11][12][13] |
| A6 | Government apps ポリシー | 政府機関との関係を偽る・無許可で行政サービスを提供するアプリは禁止。**2023-01-31 以降、Play Console「App content」の Government apps declaration が必須**。政府系アプリは公式ドメインのメールアドレスでのアカウント作成と、政府機関発行の権限確認書類の提出を推奨。条件を満たせば公式バッジ表示の対象。非公式に行政情報を扱うアプリは「政府を代表しない」旨の明示と情報源の表示が必要 | 施行済み | 中 | 自治体名を名乗る場合、**Government apps declaration を提出**し、自治体ドメイン（`lg.jp`）の連絡先と、自治体発行の委託・公認文書を用意する。複数自治体なら自治体ごと。委託事業者名義で出すなら「自治体公認」の証跡を審査ノートに添える | [14][15] |
| A7 | 電池最適化の除外要求 | 「Google Play policies prohibit apps from requesting direct exemption from Power Management features—Doze and App Standby—in Android 6.0 and above unless the core function of the app is adversely affected.」許容例に **Safety app（ユーザーと家族の安全を守るアプリ）** と「ペリフェラルと常時接続を維持するコンパニオンアプリ」。「定期同期だけ」「標準 BT プロファイルのみ」は不可 | 施行済み | 中 | 現状は `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`（直接ダイアログ）を使っている（設定画面からの任意操作）。**審査ノートに「通信途絶時に安全情報を届ける Safety app で、Doze により BLE の交換が止まる」根拠を記載**する。却下されたら `ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS`（権限不要の設定画面誘導）へ切り替える | [16] |

## 2. Apple / iOS

| # | 項目 | 内容（要点） | 施行・期限 | 影響 | 現状と必要な対応 | 出典 |
|---|---|---|---|---|---|---|
| B1 | 提出に必要な SDK / Xcode | 「Apps uploaded to App Store Connect must be built with **Xcode 26 or later using an SDK for iOS 26**」（2026-04-28 から）。「iOS and iPadOS apps uploaded to App Store Connect must **target iOS 13 or later**」（2026-09-09 から）。日本向けの新しい DPLA への同意（2026-03-17 まで）は Apple の日本向け配布ページによる | 2026-04-28 / 2026-09-09 | 高（必須・施行済み） | **充足**: 開発機は Xcode 26.6 で、2026-10-12 に `flutter build ios` が通っている。deployment target 15.0。CI を作るなら Xcode 26 以降を指定。DPLA の同意状況は Account Holder で確認 | [17][18] |
| B2 | バックグラウンド Bluetooth（central / peripheral） | 審査ガイドライン 2.5.4「Multitasking apps may only use background services for their intended purposes: VoIP, audio playback, location, task completion, local notifications, etc.」。Core Bluetooth の背面制約: central はスキャン間隔が長くなり `AllowDuplicates` が無視される。peripheral は**ローカル名を広告せず、サービス UUID は overflow 領域に入り「can be discovered only by an iOS device that is explicitly scanning for them」**。起床後の処理は約 10 秒。`NSBluetoothAlwaysUsageDescription` 必須。審査で動画提出を求める明文規定は確認できず | 施行済み | 高（設計上の制約） | **設計で対処済み**: Android 側は Apple 製造者データ（0x004C）でもスキャンして overflow 広告を拾い、iOS 側は `CBAdvertisementDataOverflowServiceUUIDsKey` も見る（docs/03 §3）。iPhone 同士が両方背面だと発見できない限界は docs/03 §4・docs/06 §4 に明記し、再接続待ちと Live Activity で緩和。`NSBluetoothAlwaysUsageDescription` は Info.plist に記載済み。**審査ノートに 2 台での確認手順・オフライン前提・災害用途を書き、可能なら動画 URL を添える** | [19][20][21] |
| B3 | プライバシーマニフェスト / Required Reason API | 「Starting May 1, 2024, apps that don't describe their use of required reason API in their privacy manifest file aren't accepted by App Store Connect.」Apple の一覧に Flutter 本体、path_provider、shared_preferences 等が明記。実装側は `shared_preferences_foundation` 2.3.5 以降、`path_provider_foundation` 2.3.2 以降でマニフェスト同梱。アプリ自身のコードで UserDefaults・ファイル更新日時などを使うならアプリ側 `PrivacyInfo.xcprivacy` に理由コードが要る | 2024-05-01 施行済み | 中 | **概ね充足**: 解決バージョンは shared_preferences_foundation 2.5.7 / path_provider_foundation 2.6.0（マニフェスト同梱）。Runner と Widget Extension の Swift コードは UserDefaults 等の Required Reason API を使っていない（grep で確認）ので、アプリ側マニフェストは必須ではない。ただし **App Store Connect の「App Privacy」申告**（表示名・投稿内容は端末間で平文中継、収集はしない）は提出時に必要。将来 App Group の UserDefaults を使うなら `1C8F.1`（App Group 共有）などの理由コードを書いたマニフェストを両ターゲットに追加 | [22][23][24][25][26] |
| B4 | Live Activities・ローカル通知 | Live Activity は**最長 8 時間**で自動終了、その後最大 4 時間ロック画面に残る。**開始は前面のときのみ**、更新・終了は背面でも可。データは 4 KB 以内、Live Activity 自体はネットワーク不可。`NSSupportsLiveActivities` 必須。審査 4.5.3（Live Activities 等でのスパム禁止）、4.5.4「Push Notifications must not be required for the app to function」、5.1.2(i)（システム機能の有効化を利用の条件にしない）。ローカル通知は 2.5.4 で正当な背面用途 | 施行済み | 中 | **設計で対処済み**: 8 時間終了は didBecomeActive で再開（docs/03 §3）、`NSSupportsLiveActivities` は Info.plist に記載済み。通知許可は初回案内で「あとで 許可する」を選べ、拒否しても受信・閲覧できる（R-26）。新着通知は 5 秒でまとめて 1 件（4.5.3 のスパム判定を避ける） | [27][19] |
| B5 | スマホソフトウェア競争促進法（スマホ新法）と iOS の代替配布 | 公正取引委員会: Apple Inc.・iTunes㈱・Google LLC を指定（2025-03-26）、**全面施行 2025-12-18**。公取委資料では「Web サイトから直接ダウンロードできるようにすることまでは義務付けない」。Apple は 2025-12-17 発表・**iOS 26.2** で日本向けに (a) 認可した代替アプリマーケットプレイス、(b) 代替決済・外部リンク、(c) 全アプリの Notarization を導入。EU 型の Web Distribution（開発者サイトからの直接配布）は日本では提供されていない。マーケットプレイス運営には組織登録と **USD 100 万のスタンドバイ信用状**（または 2 年以上の会員資格＋前年 100 万初回インストール）、知財審査・不正監視体制が必要 | 2025-12-18（法）/ 2025-12-17（Apple） | 低〜中 | 自治体が独自マーケットプレイスを運営するのは信用状要件から非現実的。第三者マーケットプレイス経由は住民側の手間が大きい。**災害前に住民へ配る手段としては App Store 配布が現実解**で、Notarization は App Store 提出で同時に満たされる | [28][29][30][18] |

## 3. 日本の法令・ガイドライン

| # | 項目 | 内容（要点） | 施行・期限 | 影響 | 現状と必要な対応 | 出典 |
|---|---|---|---|---|---|---|
| C1 | 個人情報保護法 | **2023-04-01 から地方公共団体の機関に法が直接適用**。行政機関等編ガイドライン（令和 8 年 7 月一部改正）: 個人情報は「氏名、生年月日その他の記述等により特定の個人を識別することができるもの（他の情報と容易に照合…を含む）」で、「暗号化等によって秘匿化されているかどうかを問わない」。行政機関の長等には安全管理措置義務（法 66 条 1 項）、委託先の監督、漏えい等報告（法 68 条）。**令和 8 年改正法**は 2026-07-10 成立・07-17 公布、施行は公布から 2 年以内（委員会ロードマップでは 2028 年春〜7 月見込み）。改正内容: 統計作成等の同意不要化、16 歳未満は法定代理人を対象、委託先義務の見直し、漏えい本人通知の緩和、「個人情報ではないが特定の個人への働きかけが可能な情報」の不適正利用禁止、課徴金導入、公的部門にも同様の規律 | 2023-04-01 / 改正法は 2028-07 までに施行 | 中 | 本アプリは表示名（任意）と投稿内容を**平文で住民端末間に中継し、受け取った端末から消す手段がない**（取消 tombstone は表示を消すだけ）。自治体を運用主体にする場合: (1) この性質をプライバシーポリシー・利用規約に明示、(2) 表示名欄に「本名を入れなくてよい」注意書き（現状は「入れなくても 使えます」のみ）、(3) 安否・健康状態など要配慮個人情報の投稿を UI の注意書きで抑制、(4) 公式投稿の改ざん防止（署名フィールドは予約済み、docs/06 §4）を 66 条の安全管理措置の観点で検討、(5) 委託契約に安全管理・再委託・監査条項、(6) 2028 年施行に向け 16 歳未満の利用の扱いを決める | [31][32][33][34] |
| C2 | 電波法 | 技適制度は「免許不要での利用（電波法第４条）を可能とする制度」で、Bluetooth 等は免許不要局。無線 LAN 等は「製造メーカー側で電波法に関する必要な手続きを行っている」ため利用者の手続き不要。技適のない海外端末の使用は利用者側の違反になり得る（1 年以下の拘禁刑または 100 万円以下の罰金） | 施行済み | 低 | **対応不要**。BLE の送信出力・チャネルは OS が管理し、アプリから技適外の動作は起こせない。利用案内に「技適マークのある端末で使う」と書く程度 | [35][36] |
| C3 | 災害対策基本法・防災基本計画の改正 | **令和 7 年改正（法律 51 号）**: 2025-06-04 公布、2025-07-01 全面施行。能登半島地震の教訓から、国の先手支援、災害救助の種類に「福祉サービスの提供」追加、**被災者援護協力団体の登録制度**、**広域避難**での避難元・避難先の情報連携と「広域避難者に対する情報提供の充実」、**防災 DX**（被災者支援へのデジタル技術活用）。**防災基本計画 2025-07-01 修正**で上記を反映。**2026-07-14 修正**: 気象業務法改正（「危険警報」等）、「地方公共団体によるＬアラート（災害情報共有システム）を通じた迅速・正確な情報発信」、指定緊急避難場所の避難環境確保、要配慮者向けバリアフリー。防災庁設置法は 2026-07-13 成立、2026 年 11 月設置予定（二次情報）。住民間の端末間通信への直接の言及は無し | 2025-07-01 / 2026-07-14 | 中 | 自治体の地域防災計画で「情報伝達手段の多重化」の一手段として位置づけてもらう前提で、(1) お知らせに Lアラート発信情報と突き合わせられる発令時刻・出典を持たせられる形式を検討、(2) **広域避難者が避難先自治体のお知らせも受け取れる**よう、複数グループ参加（R-7〜R-15 で実装済み）を自治体向け説明に明記 | [37][38][39][40] |
| C4 | 消防庁・総務省・デジタル庁の災害情報伝達ガイドライン | **消防庁「災害情報伝達手段の整備等に関する手引き」令和 8 年 3 月改訂**: 多重化＝「１つの手段に頼らず、複数の災害情報伝達手段を組み合わせること」。「令和６年能登半島地震発災直後においては、広範な地域で携帯電話網などの通信経路が途絶し、一つの伝達手段のみに依存することの危険性が明らかになった」。住民のスマホを受信機とする防災アプリは「情報機器を持たない住民へは情報伝達ができないことから、『主たる災害情報伝達手段に必要な要件』を満たしていない」（アプリ導入だけでは防災行政無線等の代替にならない）。長期停電時は掲示板・ビラ等のアナログ手段も必要。**Lアラート**は「2026年12月より総務省において運用を開始する予定」（令和 8 年版情報通信白書）。**デジタル庁 防災 DX**: 「防災DXサービスマップ」「防災DXサービスカタログ」で自治体の調達を支援。BLE すれ違い通信を名指しした指針は無し | 手引き 2026-03 / Lアラート 2026-12 | 中 | 自治体向け資料で「**主たる手段ではなく補完手段（通信途絶時の多重化の一層）**」と手引きの用語で説明する。避難所の紙の掲示（アナログ手段）と併用する運用を README・自治体向け手引きに書く。防災 DX サービスカタログ掲載を目指すなら掲載要件を確認。Lアラート発信情報を自治体端末から取り込む入力経路（将来の API 連携）を設計に残す | [41][42][43][44] |
| C5 | アクセシビリティ・やさしい日本語 | **障害者差別解消法改正**: 2024-04-01 施行で事業者の合理的配慮の提供が義務化（行政機関等は従前から義務）。**障害者情報アクセシビリティ・コミュニケーション施策推進法**（2022-05-25 施行）は「防災・防犯及び緊急通報の迅速な情報取得のための体制整備」を基本的施策に含む。**JIS X 8341-3:2016**（WCAG 2.0 相当）が現行。WCAG 2.2（ISO/IEC 40500:2025）一致規格への改正原案作成が 2025 年 10 月に始まり、発行は 2026 年度内見込み（二次情報・未確定）。**総務省「みんなの公共サイト運用ガイドライン」改定研究会**: 2026-08-19 公表、2027 年 3 月まで。論点に「スマートフォン向けアプリ（ネイティブアプリ）の扱い」。**デジタル庁 ウェブアクセシビリティ導入ガイドブック**: 2024-03-29 版で「4.3 スマートフォンのアクセシビリティ」追加、2025-10-16 にデジタル社会推進標準ガイドラインへ編入。**やさしい日本語ガイドライン**（出入国在留管理庁・文化庁、2020 年 8 月）は改定なし | 2024-04-01 施行 / JIS 改正 2026〜2027 年度 | 中 | 要件 R-18〜R-24（18pt 以上・3 タブ・スワイプ非依存・やさしい日本語・文字拡大追従）は改正前の規格には沿う。**2027 年の JIS 改正・運用ガイドライン改定後に WCAG 2.2 の新達成基準（ターゲットサイズ 24×24、ドラッグ操作の代替、フォーカス表示）で再点検**。TalkBack / VoiceOver で一覧・通知・Live Activity が読み上げられるか（Semantics ラベル）を確認項目に追加。自治体投稿のテンプレートに「やさしい日本語」例文（実装済み）と、将来の多言語欄 | [45][46][47][48][49] |
| C6 | 自治体の調達・セキュリティ要件 | **総務省「地方公共団体における情報セキュリティポリシーに関するガイドライン」令和 7 年 3 月版**（2025-03-28 公表）: 機器調達で **JC-STAR**（IoT 製品セキュリティ適合評価）ラベル参照、脆弱性起因インシデントの再発防止など。**地方自治法改正（令和 6 年法律 65 号）第 244 条の 6**: 自治体に「サイバーセキュリティを確保するための方針」の策定・措置を**義務化、2026-04-01 施行**、総務大臣指針（2026-04-01 通知）。**ISMAP** は政府機関のクラウド調達の原則で、自治体でも選定基準として言及（二次情報）。住民向けアプリ固有のセキュリティ要件を定めた国の統一文書は無し | 2025-03-28 / 2026-04-01 | 低〜中 | 本アプリは**クラウド非依存（BLE のみ）で ISMAP の直接対象外**。(1) 自治体の「サイバーセキュリティ方針」「情報セキュリティ対策基準」に沿う調達仕様（脆弱性診断、ソースコード・署名鍵の管理、委託契約の安全管理条項）を想定して設計書を整備、(2) 自治体の管理用クライアントや配信サーバを将来追加するなら ISMAP 登録サービス上で構築、(3) 平文中継を「扱う情報は公開情報（自治体のお知らせ）に限る」設計として機密性区分で説明できるよう明文化 | [50][51][52][53] |

## 4. まとめ

### 今すぐ対応（提出前に用意するもの）
- Play Console: **FGS（connectedDevice）の申告文と動画**、**Government apps declaration**（自治体名義または公認文書）、**電池最適化除外の正当化**（Safety app）。
- App Store Connect: **App Privacy の申告**（収集なし、端末間で平文中継）、審査ノート（2 台での確認手順、オフライン前提、災害用途、バックグラウンド Bluetooth の用途）。
- 運用文書: **プライバシーポリシー・利用規約**に「表示名は任意・本名不要」「投稿は近くの端末へ平文で広がり、受け取った端末から消せない」を明示。自治体との**委託契約に安全管理・再委託・監査条項**。自治体向け説明は「補完手段（多重化の一層）」の位置づけで。

### 2026〜2027 年に期限が来るもの
| 期限 | 内容 | 本アプリ |
|---|---|---|
| 2026-11-01 | Play target API 36 の延長期限 | 充足済み |
| 2026-12 | Lアラートの総務省による運用開始予定 | 連携設計の参照先が変わる |
| 2027-02-01 | Play: 16 KB 非対応の更新がブロック | debug APK で整列を確認済み。リリース AAB も提出前に `zipalign -c -P 16` |
| 2027 年（日付未公表） | Android developer verification の全世界施行 | 独自配布を残すなら 2026 年中に組織アカウント（D-U-N-S）と登録 |
| 2027 年夏頃（見込み） | Play target API 37 要求 | Android 17 の変更を先行確認 |
| 2026 年度内〜2027-03 | JIS X 8341-3 改正（WCAG 2.2）、公共サイト運用ガイドライン改定 | 新達成基準で UI を再点検 |
| 2028-07 まで | 令和 8 年改正個人情報保護法の施行 | 16 歳未満の扱い、委託先義務、課徴金 |

### 影響なし・確認済み
- 電波法: スマホの BLE は技適取得済みの免許不要局。アプリ・利用者とも手続き不要。
- Android 15 の BOOT_COMPLETED 制限・6 時間制限: `connectedDevice` は対象外。
- Android 16 / 17 の BLE 変更: ボンディングと RFCOMM のみで、非ボンディングの BLE 広告・スキャンには影響なし。
- iOS deployment target 15.0: 2026-09-09 からの「iOS 13 以上」要件を充足。Xcode 26.6 でビルド済み。
- スマホ新法による iOS 代替配布: 日本では Web Distribution なし、マーケットプレイス運営は信用状要件のため自治体には非現実的。App Store 配布の方針は変更不要。
- ISMAP: クラウド非依存の現設計では直接対象外。

## 5. 未確認事項（一次情報で確認できなかったもの）

- Play の 2027 年ターゲット API 要求レベルと期限（公式ページ未掲載）。
- Android 17 安定版の正式リリース日（二次情報では 2026-06-16）。
- Android 15「通知クールダウン」の仕様（開発者向け一次情報なし）。
- Flutter の 16 KB 対応の最小バージョン（二次情報では 3.22+。本リポジトリの 3.44 ビルドは整列を実測で確認）。
- Apple が Bluetooth 系アプリに審査用動画を要求する明文規定。
- JIS X 8341-3 改正版の発行日。
- 非常時ローミング（緊急通報のみ方式）の 2026 年 10 月時点の提供状況。
- 住民間の端末間（BLE）通信に言及した国のガイドライン（見つからず）。
- Google の developer verification における日本での施行日。

## 6. 参考文献

1. Google Play ターゲット API レベル要件 https://developer.android.com/google/play/requirements/target-sdk
2. Play Console ヘルプ: Foreground Service の申告要件 https://support.google.com/googleplay/android-developer/answer/13392821
3. Android: Changes to foreground services https://developer.android.com/develop/background-work/services/fgs/changes
4. Android 15 behavior changes (API 35) https://developer.android.com/about/versions/15/behavior-changes-15
5. Android 16 behavior changes (all apps) https://developer.android.com/about/versions/16/behavior-changes-all
6. Android 16 behavior changes (API 36) https://developer.android.com/about/versions/16/behavior-changes-16
7. Android 17 behavior changes (API 37) https://developer.android.com/about/versions/17/behavior-changes-17
8. Android 17 behavior changes (all apps) https://developer.android.com/about/versions/17/behavior-changes-all
9. Support 16 KB page sizes https://developer.android.com/guide/practices/page-sizes
10. Android Developers Blog (2025-07) Transition to 16 KB page sizes https://android-developers.googleblog.com/2025/07/transition-to-16-kb-page-sizes-android-apps-games-android-studio.html
11. Android developer verification https://developer.android.com/developer-verification
12. Developer verification guides / FAQ https://developer.android.com/developer-verification/guides 、https://developer.android.com/developer-verification/guides/faq
13. Android Developer Console ヘルプ https://support.google.com/android-developer-console/answer/16561738
14. Play: Requirements for apps that communicate government information https://support.google.com/googleplay/android-developer/answer/9514050
15. Android for Government https://developer.android.com/security/government
16. Optimize for Doze and App Standby（Play ポリシー上の除外要求の扱い） https://developer.android.com/training/monitoring-device-state/doze-standby
17. Apple: Upcoming requirements https://developer.apple.com/news/upcoming-requirements/
18. Apple: Changes to iOS in Japan（配布・DPLA） https://developer.apple.com/support/app-distribution-in-japan
19. App Store Review Guidelines https://developer.apple.com/app-store/review/guidelines/
20. Core Bluetooth Background Processing https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html
21. NSBluetoothAlwaysUsageDescription https://developer.apple.com/documentation/bundleresources/information-property-list/nsbluetoothalwaysusagedescription
22. Privacy manifest files https://developer.apple.com/documentation/bundleresources/privacy-manifest-files
23. Describing use of required reason API https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
24. Third-party SDK requirements https://developer.apple.com/support/third-party-SDK-requirements/
25. shared_preferences_foundation changelog https://pub.dev/packages/shared_preferences_foundation/changelog
26. path_provider_foundation changelog https://pub.dev/packages/path_provider_foundation/changelog
27. Displaying live data with Live Activities https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities
28. 公正取引委員会 スマホソフトウェア競争促進法 https://www.jftc.go.jp/msca/
29. Apple Newsroom (2025-12) Apple announces changes to iOS in Japan https://www.apple.com/newsroom/2025/12/apple-announces-changes-to-ios-in-japan/
30. Apple: Alternative app marketplace in Japan https://developer.apple.com/support/alternative-app-marketplace-jp
31. 個人情報保護委員会 行政機関等編ガイドライン（令和 8 年 7 月） https://www.ppc.go.jp/files/pdf/260731_koutekibumon_guidelines.pdf
32. 個人情報保護委員会 令和 8 年改正法 https://www.ppc.go.jp/personalinfo/legal/r8kaiseihogohou/
33. 改正法の概要 https://www.ppc.go.jp/files/pdf/260717_kaiseihounitsuite.pdf
34. 今後の取組（施行ロードマップ） https://www.ppc.go.jp/files/pdf/260731_kongonotorikumi.pdf
35. 総務省 無線 LAN 等に関する制度と現状（令和 4 年 3 月） https://www.soumu.go.jp/main_content/000844486.pdf
36. 北海道総合通信局 電波利用環境 FAQ https://www.soumu.go.jp/soutsu/hokkaido/K/FAQ.htm
37. 令和 8 年版防災白書 第 1 部 2-1 https://www.bousai.go.jp/kaigirep/hakusho/r08/honbun/1b_1s_02_01.html
38. 中央防災会議 第 45 回 資料 4（災害対策基本法等改正の概要） https://www.bousai.go.jp/kaigirep/chuobou/45/pdf/shiryo4.pdf
39. 令和 8 年版防災白書 第 1 部 2-2 https://www.bousai.go.jp/kaigirep/hakusho/r08/honbun/1b_1s_02_02.html
40. 中央防災会議 第 46 回 資料 1（防災基本計画修正の概要） https://www.bousai.go.jp/kaigirep/chuobou/46/pdf/shiryo1.pdf
41. 消防庁 災害情報伝達手段の整備等に関する手引き https://www.fdma.go.jp/mission/prepare/transmission/transmission001.html
42. 同 本編（令和 8 年 3 月） https://www.fdma.go.jp/mission/prepare/transmission/items/honpen_2608.pdf
43. 令和 8 年版情報通信白書（Lアラート） https://www.soumu.go.jp/johotsusintokei/whitepaper/ja/r08/html/nd226230.html
44. デジタル庁 防災 DX https://www.digital.go.jp/policies/disaster_prevention
45. 内閣府 障害者差別解消法 https://www8.cao.go.jp/shougai/suishin/sabekai.html
46. 総務省 情報アクセシビリティ https://www.soumu.go.jp/info-accessibility-portal/info-accessibility/
47. 総務省 みんなの公共サイト運用ガイドライン改定研究会（2026-08-19） https://www.soumu.go.jp/menu_news/s-news/01ryutsu06_02000486.html
48. デジタル庁 ウェブアクセシビリティ導入ガイドブック https://www.digital.go.jp/resources/introduction-to-web-accessibility-guidebook
49. 出入国在留管理庁・文化庁 やさしい日本語ガイドライン https://www.moj.go.jp/isa/support/portal/plainjapanese_guideline.html
50. 総務省 地方公共団体における情報セキュリティポリシーに関するガイドライン 改定（2025-03-28） https://www.soumu.go.jp/menu_news/s-news/01gyosei02_02000355.html
51. 同 改定ポイント（別紙 1） https://www.soumu.go.jp/main_content/001000931.pdf
52. 総務省 通知（地方自治法第 244 条の 6、サイバーセキュリティ方針） https://www.soumu.go.jp/main_content/001081615.pdf
53. ISMAP ポータル https://www.ismap.go.jp/
