# 回覧板 先行事例と新規性（prior art & novelty）

最終更新: 2026-10-14

本書は、回覧板（BLE すれ違い通信によるオフライン災害お知らせ配信アプリ、[01_requirements.md](01_requirements.md) / [02_protocol.md](02_protocol.md)）を既存のアプリ・製品・研究・特許と比較し、何が既知で何が新しいかを正直に整理したものである。2026-10 の設計時文献調査（BitChat / Bridgefy / Briar / Berty / FireChat / Serval / Meshtastic / Exposure Notification / Herald / StreetPass / docomo SDK / スマホdeリレー の一次資料確認）を土台に、2026-10-14 に Web で追加調査した（出典は末尾 §7、本文中は [番号]）。

## 0. 要点

- **個々の技術要素（BLE 蓄積転送、目録交換、ホップ上限+有効期限、iOS↔Android 相互、ペアリング不要）はすべて既知**である。epidemic 配信は 2000 年の論文 [40]、スマホ同士の災害時リレーは東北大「スマホdeリレー」（2011 研究開始、2019 高知市で正式運用）[1][2]、BLE すれ違いの大規模商用例は YAMAP「みまもり機能」（2019〜、累計 280 万 DL 時点）[5][6] がある。
- **新しいのは組み合わせと用途の切り方**である。「自治体の掲示板」モデル（6 桁グループコード・役割・16 種別と種別ごとの有効期限・取消/訂正）× サーバ不要の BLE epidemic 配信 × iOS↔Android 相互 × 日本語辞書圧縮 × 高齢者向け UI（デジタル庁デザインシステム・やさしい日本語）を一つのアプリにまとめ、設計文書を公開している先行例は、日本・世界ともに見つからなかった。
- 日本の自治体で運用中の唯一の端末間リレー系アプリは高知市津波SOSアプリ（安否 SOS の集約が目的、GW サーバあり、docomo SDK 依存で新規開発者は SDK 入手不可）[1][2][3]。2024〜2026 年に自治体が BLE メッシュの「お知らせ配信」を実証した公開事例は見つからなかった（2025 年の東北大学生プロジェクトが開発中 [7]）。
- 弱みも明確である：暗号化・署名なし（なりすまし可能）、iOS 同士が両方バックグラウンドだと発見できない（YAMAP も同じ制約を明記 [6]）、実運用・到達率の実績ゼロ。

## 1. 比較表

凡例: BG = バックグラウンド動作、○ = あり/可、× = なし/不可、△ = 条件付き。「—」は公開資料に記載なし。

### 1.1 日本：端末間（オフライン）通信を使うもの

| 名称 | 提供元 | 年 | OS | 通信方式 | ペアリング | BG | サーバ | 対象 | 現状 | 出典 |
|---|---|---|---|---|---|---|---|---|---|---|
| **回覧板（本アプリ）** | 本プロジェクト | 2026 | iOS 15+ / Android 8+ | BLE 広告（Service UUID のみ）+ GATT、蓄積転送、全グループ中継 | 不要 | △ iOS: central/peripheral モード、Android: 常駐サービス。iOS 同士両方 BG は不可 | 不要 | 自治体・避難所・住民（高齢者含む） | v1 実装済み・検証中 | 本書 |
| 高知市津波SOSアプリ | 高知市防災政策課（スマホdeリレー採用） | 2017-12 v1.0、2019-04 正式運用 | iOS 16.6+ / Android | Wi-Fi/Bluetooth で近く（100 m 前後）の端末へバケツリレー、GW で集約 | 不要 | △「中継役」としてアプリ起動が必要 | GW/集約サーバあり | 高知市民（市外不可）。警報発令時のみ SOS | 運用中（v2.4.1、iOS 26.1 対応） | [1] |
| スマホdeリレー | 構造計画研究所（東北大 加藤・西山研発） | 2011 研究開始、2016 商用化 | iOS / Android | docomo Adhoc Communication SDK、DTN 蓄積転送 + GW（衛星/インターネット） | 不要 | — | GW あり | 自治体（高知市・中野区・日向市・高知県・内閣府） | BtoG で継続。SDK は 2021-03 に配布終了 | [2][3][4] |
| docomo Adhoc Communication SDK | NTT ドコモ（NTT コムウェア 2012 研究が前身） | 2012 研究、2013 Android、2015-03 iOS↔Android SDK | iOS 7.1+ / Android（Nexus 限定） | BLE 広告で探索しテキスト・画像交換、バケツリレー | 不要 | — | 任意（安否は Person Finder へ） | 開発者 | 終了（docomo Developer support 2021-03-31 終了） | [3][4][18] |
| YAMAP みまもり機能（こんにちは通信） | ヤマップ | 2019-07（2021-11 に「まとめて交換」へ進化） | iOS / Android | BLE すれ違いで位置情報を交換し、どちらかがオンラインになった時にサーバへ送信 | 不要 | △ iPhone 同士がスリープ時は通信不可（公式ヘルプ） | 最終配信はサーバ | 登山者（家族への見守り） | 運用中。特願 2020-110196 | [5][6][37] |
| Blette | オフラインジャパン | 2024-07 | Android のみ（USB-C 専用スティック必要） | BLE 5.0、直径約 1.1 km、テキスト + 位置 | — | — | 不要 | 災害時の救助要請 | 販売中（専用ハード） | [8] |
| BLE Messenger | 個人開発（Ohkubo Yuhei） | — | iOS 14+ | Bluetooth 直接 1 対 1 チャット、中継なし | 不要 | — | 不要 | 一般 | ストア配信中 | [9] |
| 東北大「スマホと Bluetooth で電波がなくても"つながる"安心を！」 | 東北大 学生 3 名（ともプロ！2025） | 2025 | iOS 先行、Android 予定 | Bluetooth で SOS を中継、UWB で位置、避難所入退室記録 | — | — | 不要 | 被災者・避難所・自治体 | 開発中（寄付募集）、OSS 公開予定 | [7] |
| ビットマイスター 耐災害情報伝播システム | ビットマイスター | 2017 頃 | Android / iOS / Raspbian | BLE で近隣端末を発見し Wi-Fi Direct で差分交換 | — | — | 不要 | 研究・検証 | 受託開発事例 | [10] |
| すれちがい通信型情報共有システム（首都大） | 首都大学東京 坂上・高間 | 2012 | Android 2.2 | Bluetooth デバイス名にメッセージを載せ周辺検索で受信、送信情報を自動選択 | 不要 | — | 不要 | 避難者 | 研究 | [11] |
| DTN 避難ナビ（関西学院大 三輪研） | 関西学院大 | 2008–2012 | — | Bluetooth 蓄積搬送、ITS Japan 企画賞 2012 | — | — | 不要 | 避難者 | 研究 | [12] |
| DTN 避難誘導（近畿大） | 中壷・柏崎・井口 | 2024 | （シミュレーション The ONE） | すれ違い通信で誘導先を伝搬 | — | — | 不要 | 避難者 | 研究（避難場所を知らない人の 30% を誘導） | [13] |
| D2D DTN 災害情報システム（福岡工大/NICT/岩手県立大） | Uchida・Sato・Shibata | 2019 | Android（D2D API） | DTN + データトリアージ、優先ノード選択 | — | — | 不要 | 避難者 | 研究 | [14] |
| EMSS（金沢大） | 金沢大 | 2017 | Android | Bluetooth MANET で避難者が情報共有 | — | — | 不要 | 避難者 | 研究（6 名実験） | [15] |

### 1.2 日本：参考（インターネット前提、または衛星）

| 名称 | 提供元 | 年 | OS | 通信方式 | 圏外動作 | 現状 | 出典 |
|---|---|---|---|---|---|---|---|
| Yahoo!防災速報 | LINE ヤフー | — | iOS 18+ / Android 10+ | プッシュ通知、災害マップ（投稿） | × | 運用中 | [16] |
| NHK ONE ニュース・防災 | NHK | 2025-10 リニューアル | iOS / Android | プッシュ通知、記事・動画・ライブ | × | 運用中 | [17] |
| LINE 安否確認・スマート通知 | LINE ヤフー | — | iOS / Android | 震度 6 弱以上で自動有効化、Yahoo!防災速報連携 | × | 運用中 | [19] |
| ハザードン | アルカディア（自治体導入型） | — | iOS / Android | 自治体からのプッシュ通知、避難所開設状況、ハザードマップ | × | 運用中（箕面市・宮崎市・伊賀市ほか） | [20] |
| 全国避難所ガイド | ファーストメディア | — | iOS / Android | 避難所検索、地図キャッシュ | △ 事前取得分の閲覧のみ | 運用中（Ver.6.0） | [21] |
| iPhone 衛星経由の緊急SOS / 衛星経由のメッセージ | Apple | 緊急SOS 2024-07-30、メッセージ 2025-12-09（日本） | iPhone 14+、iOS 18+ | 衛星、iMessage/SMS、Dynamic Island で衛星方向を案内 | ○（屋外・空が見える場所） | 運用中、2 年無料、キャリア契約必要 | [22][23] |
| Pixel 衛星 SOS | Google | 2024-08（米国） | Pixel 9 以降（9a 除く） | 衛星、緊急通報のみ | ○ | 34 か国・地域。**日本は未提供** | [24] |
| au / SoftBank / docomo Starlink Direct | KDDI 2025-04、ソフトバンク 2026-04-10、ドコモ 2026-04-27 | 2025–2026 | 対応機種（iPhone 13/14 以降、Android 衛星モード対応機） | Starlink Direct to Cell。SMS/RCS/iMessage、対応アプリ（YAMAP 等）、緊急速報受信。音声不可 | ○ 圏外エリアのみ、屋外 | 運用中（当面無料） | [25][26][27] |

### 1.3 世界

| 名称 | 提供元 | 年 | OS | 通信方式 | ペアリング | BG | サーバ | 対象 | 現状 | 出典 |
|---|---|---|---|---|---|---|---|---|---|---|
| BitChat | Jack Dorsey / Block ほか | 2025-07 | iOS / Android | BLE GATT（central+peripheral）、TTL 7、Noise 暗号、GCS 目録同期、クーリエ（spray-and-wait） | 不要 | △ Android: foreground service。iOS: 復元識別子 | 不要（Nostr は任意） | 抗議・通信遮断下の一般利用者 | 運用中。中国 App Store（2026-04）、インド両ストア（2026-10-03）で削除 | [28][29] |
| Bridgefy | Bridgefy（メキシコ） | 2014〜 | iOS / Android | BLE（Classic も）、ホップ/TTL/転送回数プロファイル、Signal 暗号 | 不要 | — | 初回設定にインターネット | 一般・SDK 利用者 | 運用中（商用 SDK） | [30][31] |
| Briar | Briar Project | 2018〜 | Android のみ | Bluetooth Classic RFCOMM、Wi-Fi、Tor。連絡先（QR 対面）同士のみ同期 | 対面 QR 交換 | △ 不安定と自認 | 不要 | 活動家・ジャーナリスト | 2026-07-09 メンテナンスモード | [32] |
| Berty（Wesh） | Berty Technologies | 2018〜 | iOS / Android | BLE（OS 間）、Multipeer/Nearby（同 OS） | 不要 | — | 不要 | 一般 | 開発継続、未監査 | [33] |
| FireChat | Open Garden | 2014–2018 | iOS / Android | Bluetooth / Wi-Fi / Multipeer、FireChat Alerts（マリキナ市） | 不要 | — | 不要 | 一般・自治体（フィリピン） | 終了 | [34] |
| OSHI | OSHI | 2025–2026 | iOS / Android | BLE + Wi-Fi Direct、最大 5 ホップ蓄積転送、X3DH/Double Ratchet | 不要 | × アプリを開いている必要 | 不要（インターネット経路は OSHI サーバ） | 一般 | 運用中（コアは MIT、アプリ本体非公開） | [35] |
| qaul.net | qaul（Mathias Jud） | 2012〜、Rust 2.0 開発中 | iOS / Android / PC | BLE + LAN + インターネット、DTN | 不要 | — | 不要 | 一般 | 開発中（FOSDEM 2026 発表） | [36] |
| Serval Mesh / Rhizome | Serval Project | 2011〜 | Android | Wi-Fi アドホック、Rhizome 蓄積転送 | 不要 | — | 不要 | 一般 | 実験的・休止 | [38] |
| Ditto SDK | Ditto | 商用 | iOS / Android ほか | BLE + Wi-Fi + AWDL、CRDT 同期、多ホップ | 不要 | — | 任意 | アプリ開発者（航空・軍 ATAK） | 運用中（有料） | [39] |
| Meshtastic | OSS（GPL-3.0） | 2020〜 | iOS / Android + LoRa 機 | LoRa、managed flood、hop 既定 3 最大 7 | 機器と BLE 接続 | ○（無線機側） | 不要 | 愛好家・災害ボランティア | 運用中（専用ハード必要） | [41] |
| Apple/Google Exposure Notification | Apple / Google | 2020–2023 | OS 内蔵 | BLE 広告のみ（非接続型） | 不要 | ○（OS 特権） | 保健当局サーバ | 国民 | 2023-09-18 終了 | [42] |
| AirDrop / Quick Share | Apple / Google | — | iOS / Android | Bluetooth + Wi-Fi の 1 対 1 転送。中継・蓄積なし | 不要（近接確認） | × | 不要（iPhone↔Android の QR 方式はインターネット必要） | 一般 | 運用中 | [43][44] |

## 2. 新規性の評価（軸ごと）

| 軸 | 既知の先行例 | 本アプリ | 判定 |
|---|---|---|---|
| 端末間蓄積転送（epidemic / DTN） | Epidemic routing 2000 [40]、Spray and Wait 2005 [40]、スマホdeリレー [2]、Rhizome [38]、BitChat クーリエ [28] | 目録交換後に不足分のみ送る、hop 上限 64、有効期限で中継停止 | **既知** |
| 目録（在庫）交換で重複送信を避ける | Briar OFFER/REQUEST、BitChat GCS、Serval LBARD [28][32][38] | msg_id 一覧（最大 2,000 件）の対称交換 | **既知**（単純化版） |
| ペアリング不要・相手選択不要 | docomo SDK、YAMAP、BitChat、OSHI など全般 [3][5][28][35] | 同じ | **既知** |
| iOS↔Android 相互運用 | docomo SDK 2015（当時世界初）[3]、BitChat、Bridgefy、OSHI、Ditto [28][30][35][39] | GATT のみで相互、Service UUID 1 個 | **既知** |
| バックグラウンド動作 | YAMAP「iPhone 同士スリープ時は不可」[6]、OSHI「開いている必要」[35]、Apple DTS「回避策なし」[45]、Herald の Android→iOS 起床 [46] | iOS 両モード + 復元 + 再接続待ち（20 分・4 台）、Android 常駐、Android を橋に iPhone 同士を配信 | **既知の限界の中での既知の手法**。限界を UI と運用（中継役端末）で明示する点は高知市方式 [1] と同じ思想 |
| サーバ不要 | BitChat、Briar、OSHI [28][32][35]。一方スマホdeリレー・YAMAP は GW/サーバで集約 [2][5] | 完全にサーバなし | **既知**（日本の自治体向けでは新しい） |
| 暗号化なし・平文 | FireChat 初期 [34]、首都大 2012 [11] | 平文、署名フィールドを予約 | **既知**（セキュリティ面では後退。§4） |
| 自治体単位の 6 桁グループコード、参加は番号入力のみ、中継は全グループ・表示は参加グループ | BitChat の geohash チャンネル（表示側分離）、Briar のグループ共有先選択 [28][32]、高知市アプリの「市外不可」[1] | 市町村ごとの参加コード、QR、発信者コードで公式昇格、group_info 自体も BLE で伝搬 | **新規の組み合わせ**。地理ではなく自治体運用単位で切る発想は先行例なし |
| 種別（16 カテゴリ）ごとの既定有効期限、期限切れは表示も中継も停止 | Bridgefy のプロファイル TTL（1 時間〜7 日）[31]、BitChat 24 h [28]、総務省研究会が「情報鮮度管理」を課題に列挙 [47] | 物資 12 h／避難所 7 日など避難所運営に即した既定値 | **新規の組み合わせ**（カテゴリ別 TTL を災害お知らせに適用した例は未発見） |
| 取消・訂正（tombstone / supersedes） | docomo が「伝達終結」を課題に列挙 [47]。Rhizome の bundle 更新 [38] | kind=tombstone、supersedes、対象より 24 h 長く保持 | **既知の概念の適用** |
| 日本語辞書付き圧縮 | BitChat LZ4、Bridgefy gzip [28][31] | raw deflate + 事前共有辞書（行政・避難所語彙）、伸長上限 4 KB（Bridgefy の zip bomb 事故を踏襲） | **新規の組み合わせ**（日本語災害語彙の辞書は未発見） |
| 役割（住民/スタッフ/公式）表示、発信時刻と受信時刻の分離表示 | FireChat Alerts（自治体発信）[34] | 役割を封筒に持ち、遅延を隠さない UI | **小さな新規性** |
| 高齢者向け UI（デジタル庁デザインシステム、やさしい日本語、3 タブ、スワイプ非依存） | 既存メッシュアプリは技術者・抗議者向け。高知市アプリは市民向けだが操作性の公開資料なし [1] | 要件 R-18〜R-24 | **新規**（メッシュ系アプリでこの設計方針を明文化した例は未発見） |
| 設計文書・プロトコルの公開 | BitChat WHITEPAPER [28]、Briar 仕様 [32] | 要件・プロトコル・検証を日本語で公開 | **既知**（日本語・自治体向けとしては新しい） |

**結論**: 技術的な一次発明はない。新規性は「自治体の避難所運営に即した情報モデル（グループ・役割・種別 TTL・取消訂正）」「日本語辞書圧縮」「高齢者向け UI」を、サーバ不要の BLE epidemic 配信と iOS↔Android 相互運用に組み合わせた点にある。日本の先行製品（スマホdeリレー）が「安否 SOS を GW へ集める上り方向」なのに対し、本アプリは「運営側のお知らせを住民へ広げる下り方向」で、用途が異なる。

## 3. 差別化ポイント（報告・発表用）

1. **自治体単位の 6 桁グループコード**: 住民は番号を入れるだけ。認証も個人情報も不要。他自治体の情報は表示されないが中継はするので、隣接市町村の住民も運び役になる（R-7〜R-15）。
2. **「掲示板」としての情報設計**: 16 種別と種別ごとの有効期限（物資は 12 時間、避難所開設は 7 日）、公式/スタッフ/住民の役割表示、取消・訂正。古い情報が残り続ける DTN の弱点に運用側の知識で対処する（R-3〜R-6）。
3. **日本語辞書圧縮で 1 回のすれ違いに運べる件数を増やす**: 本文を UTF-8 比 約 1/3 に圧縮（R-2）。1 セッション 64 KB の上限内で、単純計算で非圧縮の約 3 倍の件数を運べる。歩いてすれ違う数秒〜10 秒の接続時間（§5 既知の制約）を最大限使う。
4. **iOS↔Android 相互・ペアリング不要・サーバ不要、Android を橋にした iPhone 同士の配信**: Apple が「仕様・回避策なし」と明言する iOS 同士バックグラウンドの限界 [45] を隠さず、Herald 方式の Android 起床 [46]、再接続待ち、避難所端末の中継役運用で補う。
5. **高齢者を含む全員向け UI と設計文書の公開**: デジタル庁デザインシステム準拠、やさしい日本語、18pt 以上、3 タブ固定、発信時刻と到着時刻の分離表示。要件・プロトコル仕様を公開し、他自治体・他開発者が検証・再実装できる。

## 4. 弱み・先行例に劣る点

1. **暗号化・署名がない**: BitChat（Noise）、Bridgefy（Signal）、Briar（Cure53 監査）、OSHI（Double Ratchet）はすべて暗号化済み [28][30][32][35]。本アプリは「公式」表示を技術的に偽れる。参加コード運用と将来の Ed25519 署名（フィールド予約済み）で補う計画だが、v1 では総務省研究会が筆頭に挙げた「なりすまし」課題 [47] に未対応。
2. **iOS 同士がバックグラウンドで届かない**: YAMAP が 2019 年から同じ制約を明記しており [6]、2026 年の Apple DTS 回答でも回避策なし [45]。Exposure Notification のような OS 内蔵の常時動作 [42] には構造的に及ばず、衛星経由メッセージ（iPhone 14+、2025-12 日本対応）[23] や Starlink Direct [25][26][27] のように「屋外なら確実に届く」保証もない。到達は近隣の Android 端末や中継役端末の有無に依存する。
3. **実運用・到達率の実績がない**: 高知市は 2019 年から運用 [1]、YAMAP は数百万 DL 規模 [37]、BitChat は 1 日 33 万人規模の実使用 [29] がある。本アプリはエミュレータ・少数実機での検証段階で、人口密度・歩行速度・機種差を含む到達率の実測値を持たない。また BLE GATT のみで到達 10〜30 m 程度、画像不可であり、Blette（1.1 km、専用ハード）[8] や Meshtastic（数 km、LoRa）[41] のような距離は出せない。

補足: スマホdeリレーの GW（衛星・インターネットへの集約）[2] や YAMAP のサーバ連携 [5] に相当する「外へ出す経路」が v1 にはない（スコープ外 §6）。

## 5. 類似特許・論文（深追いしない）

特許・出願
- 米国特許 10,051,546 / 日本特許 6,323,856「スマホdeリレー」（東北大学、DTN 的蓄積転送 + MANET + Wi-Fi のマルチホップ）[4]
- 特願 2020-110196「みまもりシステム、みまもり方法及びプログラム」（ヤマップ、2021-11 発表。すれ違い時に位置情報を交換し、蓄積分をまとめて連鎖交換）[37]
- JP6669066B2 / JPWO2016024399A1「無線通信ネットワークにおけるグループ間通信方法およびシステム」（NEC、優先日 2014-08-12。Wi-Fi Direct の P2P グループ間を「デリバリノード」が移動して災害情報等を運ぶ）[48]
- 特許第 7388784 号（NICT、移動体間を DTN で蓄積転送し送信期限を制御）[49]
- 特許第 6036675 号（カシオ、すれ違い通信の双方向性保証）、京セラ（すれ違い相手 ID・位置・時刻の履歴を次の相手へ転送）[50]

論文・報告
- Vahdat & Becker, "Epidemic Routing for Partially-Connected Ad Hoc Networks" (2000)；Spyropoulos et al., "Spray and Wait" (2005) [40]
- Nishiyama, Ito, Kato, "Relay-by-Smartphone: Realizing Multihop Device-to-Device Communications" IEEE Communications Magazine (2014、2017 IEEE ComSoc AP Outstanding Paper Award) [4]
- 坂上・高間「すれ違い通信を用いた避難行動時情報共有システム」知能と情報 (2013)；FSS 2012「すれちがい通信を用いた情報共有システムの提案」[11]
- Fujihara & Miwa, "Real-time disaster evacuation guidance using opportunistic communication" SAINT (2012) [12]
- Uchida, Sato, Shibata, "Device-to-Device Communication based DTN for Disaster Information System..." JISIS 9(3) (2019) [14]
- 中壷・柏崎・井口「災害時の避難誘導における DTN を活用した自律分散手法のシミュレーション評価」情報処理学会関西支部大会 G-06 (2024) [13]
- 吉田・下田・池本・山口・高田・宮島「災害時における携帯端末を用いた避難共助支援システムの開発及び小規模避難実験」（EMSS、Bluetooth MANET）土木学会論文集 F6 (2017) [15]
- Albrecht et al., "Bridgefy security analysis" USENIX Security (2022)；総務省「非常時のアドホック通信ネットワークの活用に関する研究会 中間取りまとめ」(2016) [31][47]

## 6. 未確認事項

- 高知市津波SOSアプリ／スマホdeリレーの到達率・遅延の運用統計は公開されていない（構造計画研究所・高知市への照会が必要）[1][2]。
- 東北大 2025 学生プロジェクト [7] の実装詳細（プロトコル、OS 間相互）は未公開。OSS 公開後に再比較する。
- ヤマップ特願 2020-110196 の請求項（中継・蓄積の範囲）は全文未確認。本アプリは位置情報を扱わず用途も異なるが、「すれ違い時に蓄積した第三者情報をまとめて交換する」構成が近いため、必要なら J-PlatPat で請求項を確認する [37]。

## 7. 参考文献

1. 高知市津波SOSアプリ（App Store）https://apps.apple.com/jp/app/id1321332473
2. スマホdeリレー 製品ページ・事例 https://www.smart-relay.kke.co.jp/ 、https://www.smart-relay.kke.co.jp/case
3. docomo Adhoc Communication SDK 報道発表（docomo Developer support 終了告知を含む）https://www.docomo.ne.jp/info/news_release/2013/10/18_00.html
4. 東北大学 スマホdeリレー（特許番号・受賞）https://www.t-technoarch.co.jp/data/anken_h/T13-121_S18-012.html 、https://www.r-info.tohoku.ac.jp/ja/142a0326d86a887185cfdca639f6df2e.html
5. YAMAP みまもり機能（開発者対談）https://yamap.com/magazine/24771
6. YAMAP ヘルプセンター「こんにちは通信とは」（iPhone 同士スリープ時は通信不可）https://help.yamap.com/hc/ja/articles/900000920486
7. 東北大学基金 ともプロ！2025 No.07 https://www.kikin.tohoku.ac.jp/project/tomopro/2025/pj_007_2025
8. オフラインジャパン Blette（PR TIMES、2024-07）https://prtimes.jp/main/html/rd/p/000000025.000010570.html
9. BLE Messenger（App Store）https://apps.apple.com/jp/app/ble-messenger/id1196831220
10. ビットマイスター 耐災害情報伝播システム https://www.bitmeister.jp/works/archives/16
11. 首都大学東京 FSS 2012 https://www.jstage.jst.go.jp/article/fss/28/0/28_245/_pdf/-char/en
12. 関西学院大学 三輪研究室 DTN https://cs.kwansei.ac.jp/miwa/miwaLab/?page_id=87
13. 情報処理学会関西支部 2024 G-06 https://kansai.ipsj.or.jp/record/pdf/2024/G-06.pdf
14. JISIS 2019 vol.9 no.3 https://isyou.info/jisis/vol9/no3/jisis-2019-vol9-no3-03.pdf
15. 吉田・下田ほか「災害時における携帯端末を用いた避難共助支援システムの開発及び小規模避難実験」土木学会論文集 F6 73(2) I_91–I_96 (2017) https://www.jstage.jst.go.jp/article/jscejsp/73/2/73_I_91/_article/-char/ja/
16. Yahoo!防災速報 https://emg.yahoo.co.jp/
17. NHK ONE ニュース・防災（リニューアル報道）https://iphone-mania.jp/news-122218/ 、https://app-liv.jp/5354126/
18. NTT コムウェア 2012-12-18 Bluetooth ローカルネットワーク https://www.nttcom.co.jp/news/pr12121801.html 、ITmedia 2013-11 https://www.itmedia.co.jp/mobile/articles/1311/21/news098.html
19. LINE 緊急時の使い方 https://guide.line.me/ja/features-and-columns/emergency-tips.html
20. ハザードン（アルカディア）https://www.arcadia.co.jp/products/hazardon
21. 全国避難所ガイド https://www.hinanjyo.jp/ 、苫小牧市案内 https://www.city.tomakomai.hokkaido.jp/kurashi/bosai/jishin/evacuation/hinanjoguide.html
22. Apple 衛星経由の緊急SOS 日本提供開始（2024-07-30）https://www.apple.com/jp/newsroom/2024/07/emergency-sos-via-satellite-available-today/
23. Apple 衛星経由のメッセージ 日本提供開始（2025-12-09）https://www.apple.com/jp/newsroom/2025/12/messages-via-satellite-is-now-available-in-japan/
24. Google Pixel Satellite SOS 対応国 https://support.google.com/pixelphone/answer/15254448
25. au Starlink Direct https://www.au.com/mobile/service/starlink-direct/
26. SoftBank Starlink Direct 提供開始（2026-04-10）https://www.watch.impress.co.jp/docs/news/2100778.html
27. docomo Starlink Direct 報道発表（2026-04-02、提供開始 04-27）https://www.docomo.ne.jp/info/news_release/2026/04/02_01.html
28. BitChat リポジトリ・WHITEPAPER・TransportConfig https://github.com/permissionlesstech/bitchat 、https://github.com/permissionlesstech/bitchat-android
29. BitChat（Wikipedia、利用実績・削除の経緯）https://en.wikipedia.org/wiki/BitChat
30. Bridgefy SDK docs https://docs.bridgefy.me/sdk/android/usage
31. Albrecht, Eikenberg, Paterson, "Breaking Bridgefy, again: Adopting libsignal is not enough" USENIX Security 2022 https://www.usenix.org/conference/usenixsecurity22/presentation/albrecht
32. Briar メンテナンスモード（2026-07-09）https://briarproject.org/news/2026-maintenance-mode/
33. Berty https://berty.tech/
34. FireChat（Wikipedia、2014-03 iOS / 04 Android、2018 以降更新なし）https://en.wikipedia.org/wiki/FireChat 、TechCrunch 2014-06 iOS↔Android 相互 https://techcrunch.com/2014/06/24/firechat-enables-cross-platform-off-the-grid-chat-between-ios-and-android/
35. OSHI オフラインメッセンジャー比較 https://oshi-messenger.com/best-offline-messenger
36. qaul.net https://qaul.net/ 、FOSDEM 2026 https://fosdem.org/2026/schedule/event/qaul-mesh-messenger-app
37. ヤマップ 進化したみまもり機能と特許取得（PR TIMES、2021-11-16）https://prtimes.jp/main/html/rd/p/000000088.000011352.html
38. Serval Project（Rhizome / LBARD）https://github.com/servalproject/serval-dna
39. Ditto mesh networking https://docs.ditto.live/key-concepts/mesh-networking
40. Vahdat & Becker 2000 https://issg.cs.duke.edu/epidemic/epidemic.pdf 、Spyropoulos 2005 https://doi.org/10.1145/1080139.1080143
41. Meshtastic LoRa 設定（hop_limit）https://meshtastic.org/docs/configuration/radio/lora/
42. Google Exposure Notifications API 終了 https://developers.google.com/android/exposure-notifications/exposure-notifications-api
43. Apple AirDrop の使い方 https://support.apple.com/ja-jp/119857
44. Google クイック共有 https://support.google.com/android/answer/9286773?hl=ja
45. Apple Developer Forums（DTS 回答、iOS 同士バックグラウンド発見の構造的限界）https://developer.apple.com/forums/thread/824822
46. Herald（scan-then-interrogate、calling card）https://heraldprox.io/
47. 総務省 非常時のアドホック通信ネットワークの活用に関する研究会 中間取りまとめ（2016）https://www.soumu.go.jp/main_content/000424633.pdf
48. NEC JPWO2016024399A1 https://patents.google.com/patent/JPWO2016024399A1/ja
49. 開放特許情報データベース（NICT 特許第 7388784 号）https://www.plidb.inpit.go.jp//pldb/html/HTML.L/2023/000/L2023000320.html
50. カシオ・京セラ すれ違い通信特許の紹介 http://m-y.main.jp/tm/archives/1112 、http://m-y.main.jp/tm/archives/2438
