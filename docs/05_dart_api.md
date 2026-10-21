# Dart 内部 API 契約 v1（v2 改訂）

UI（`lib/ui`）と同期ロジック（`lib/core`, `lib/mesh`, `lib/app/app_controller.dart`）を並行実装するための契約。
シグネチャは原則この通りに実装する（追加のメンバーは可、変更は不可）。

v2 は [08_use_cases.md](08_use_cases.md) の仕様変更 C01〜C25 を実装した版。変更・追加した行の末尾に「（v2: C13）」のように変更 id を付ける。ワイヤ・保存の規則は [02_protocol.md](02_protocol.md)、Platform Channel の契約は [03_architecture.md](03_architecture.md) §3。正はコード（引数の既定値・例外は各ファイルの doc コメント）。

```dart
// ---------------- lib/core/epoch.dart ----------------
const int kEpochUnixSeconds = 1767225600; // 2026-01-01T00:00:00Z
const int kMaxEpochSeconds = 0xFFFFFFFF;
int epochSecondsFrom(DateTime time);          // DateTime(UTC/ローカルどちらでも可) → エポック秒。2026 年より前は 0 に丸める（時計ずれの検知に使う）（v2: C12）
DateTime dateTimeFromEpoch(int epochSeconds); // → ローカル DateTime
int nowEpochSeconds();

// ---------------- lib/core/categories.dart ----------------
const String kTrainingPrefix = '【訓練】';          // 訓練投稿の見出し接頭辞。封筒の flags は使わない（v2: C23）
bool isTrainingTitle(String title);                // 見出しが「【訓練】」で始まるか（v2: C23）
bool looksLikeEndTitle(String title);              // 「終わりました」の見出しらしいか（「書きなおし」と区別して表示する）（v2: C01）
const String kPersonalInfoCaution;                 // 投稿画面の注意枠（個人情報）（v2: C11）
const String kEvacuationCaution;                   // 投稿画面の注意枠（避難情報）（v2: C11）
enum NoticeImportance { normal, important, urgent } // OS 通知の重要度。normal は「ぜんぶ 知らせる」のときだけ、important は 5 秒まとめ、urgent は 1 件ずつ即時（v2: C05）
enum NoticeCategory {
  general, evacuation, shelter, supply, water, food, medical, safety,
  traffic, lifeline, warning, sanitation, shops, admin, request, damage;
  int get code;                 // 0..15（宣言順。末尾追加のみ）
  String get label;             // 「お知らせ」「避難情報」「避難所」「物資」「給水」「炊き出し・食事」「医療・救護」「安否・名簿の 案内」「交通・道路」「ライフライン」「注意喚起」「トイレ・入浴・洗濯」「店舗・燃料・銀行」「行政手続き」「支援要請」「被害情報」（v2: C11, C15）
  Duration get defaultTtl;      // docs/02_protocol.md §2.2 の表（v2: C02）
  List<String> get titleTemplates; // 見出しの例文 1〜3 文。先頭が既定。{名前}{住所}{病名} を含まない（v2: C15, C11）
  String get titleTemplate;     // titleTemplates.first
  String? get endTemplate;      // 「終わりました」の見出し。null なら汎用文「{場所}の お知らせは 終わりました」（v2: C01）
  bool get endOnlyOfficial;     // endTemplate を公式（role=2）のときだけ使う（注意喚起）（v2: C01）
  bool get endable;             // 「終わりました」ボタンを出すか（避難情報は false）（v2: C01）
  String? get caution;          // 投稿画面で見出し欄の上に出す注意（安否・医療・支援要請・被害情報・避難情報）（v2: C11）
  String? get ttlHint;          // 期限ボタンの下の 1 行ヒント（v2: C02）
  String? get bodyHint;         // 本文欄のヒント（物資）（v2: C15）
  bool get showsEndTime;        // 一覧カードに「午後6時まで」を併記するか（物資・給水・炊き出し・医療）（v2: C02）
  NoticeImportance get importance; // 種別固有の重要度（避難情報・注意喚起 = urgent、避難所・物資・給水・炊き出し・医療 = important）。役割による格上げは AppController.importanceOf（v2: C05）
  String endTitle({required String place, required bool official}); // 「終わりました」の見出し。場所が空なら「{場所}の 」を省く（v2: C01）
  static NoticeCategory fromCode(int code); // 範囲外は general
}

// ---------------- lib/core/envelope.dart ----------------
const int kEnvelopeHeaderLength = 28; const int kMaxGroupId = 999999; const int kMaxHopValue = 255;
const int kFlagCompressed = 0x01; const int kFlagSupersedes = 0x02; const int kFlagsReservedMask = 0xFC;
const int kMaxTtlSeconds = 30 * 24 * 60 * 60;                       // 有効期間の上限（notice / help）（v2: C12）
const int kPolicyMembersCanPost = 0x01; const int kPolicyClosed = 0x02; const int kPolicyAcceptsHelp = 0x04; // group_info の policy（v2: C24, C21）
const int kCodeDigestLength = 8; const int kGroupInfoExtLength = 13;  // ext = digest 8 ‖ generation u16 ‖ successor uint24（v2: C24）

enum MessageKind { notice(0), groupInfo(1), tombstone(2), help(3), ack(4), unknown(0xFF);  // help / ack は C21。unknown は不透明メッセージ専用でワイヤには載せない（v2: C21, C13）
  int get code; static MessageKind? fromCode(int code); } // 未知なら null
enum SenderRole { resident, staff, official; int get code; String get label; static SenderRole? fromCode(int code); } // label: 住民 / スタッフ / 公式

class NoticeBody {   // kind=notice / help の body
  const NoticeBody({required this.senderName, required this.title, this.place = '', this.text = ''});
  final String senderName, title, place, text;
  Uint8List encode();                       // u16 len + UTF-8 ×4
  static NoticeBody decode(Uint8List bytes); // 長さ超過・不正は EnvelopeFormatException。5 番目以降のフィールドは無視（v2: C13, C25）
}

class GroupInfoBody {
  const GroupInfoBody({required this.name, required this.hostName, this.membersCanPost = true, this.description = '',
      this.closed = false, this.acceptsHelp = false, this.codeDigest, this.generation = 0, this.successor = 0}); // （v2: C24, C21）
  final String name, hostName, description; final bool membersCanPost;
  final bool closed;            // policy bit1（引っ越し済み）（v2: C24）
  final bool acceptsHelp;       // policy bit2（困りごとを受け付ける）（v2: C21）
  final Uint8List? codeDigest;  // 本部 4 B ‖ スタッフ 4 B。なければ null（v2: C24）
  final int generation;         // 世代。コード作り直し・引っ越しごとに +1（v2: C24）
  final int successor;          // 後継の参加コード（0 = なし）（v2: C24）
  bool get hasExt;              // codeDigest != null || generation != 0 || successor != 0。true のとき 5 番目の ext を書く（v2: C24）
  Uint8List encode(); static GroupInfoBody decode(Uint8List bytes); // ext は省略可（4 フィールドの旧形式も受ける）。6 番目以降は無視（v2: C24, C13）
}

class EnvelopeFormatException implements Exception { final String message; }

class Envelope {
  Envelope({
    required this.kind, required this.groupId, required this.msgId,
    required this.createdAt, required this.expiresAt, this.hop = 0,
    this.category = NoticeCategory.general, this.role = SenderRole.resident,
    this.supersedes, required this.bodyPlain,
    this.version = kProtocolVersion, this.opaqueBytes, this.isStub = false,   // （v2: C13, C20）
  });
  final MessageKind kind; final int groupId; final int msgId; // msgId は 64bit 符号付き int として保持（ビット列は同一）
  final int createdAt, expiresAt, hop; final NoticeCategory category; final SenderRole role;
  final int? supersedes; final Uint8List bodyPlain;
  final int version;            // ワイヤ上の version（不透明メッセージでは 1 以外もあり得る）（v2: C13）
  final Uint8List? opaqueBytes; // 不透明メッセージの生バイト（ヘッダを含む封筒全体）。通常は null（v2: C13）
  final bool isStub;            // 本文を消した空殻か（v2: C20）
  bool get isOpaque;            // opaqueBytes != null（v2: C13）
  bool get isDisplayable;       // !isOpaque && !isStub（v2: C13, C20）
  int get ttlSeconds;           // expiresAt − createdAt（v2: C12）

  /// 発信用。msgId を計算して生成する（supersedes があれば msgId に含める）。（v2）
  factory Envelope.create({
    required MessageKind kind, required int groupId, required Uint8List originId,
    required int createdAt, required int expiresAt, required NoticeCategory category,
    required SenderRole role, int? supersedes, required Uint8List bodyPlain,
  });
  static int computeMsgId({required int groupId, required MessageKind kind, required Uint8List originId, required int createdAt, required Uint8List bodyPlain, int? supersedes}); // （v2）
  Uint8List encode({bool compress = true});     // 圧縮して縮むときだけ flags bit0。不透明は生バイトの hop（offset 23）と expires_at（offset 19）だけ書き換えて返す。空殻は body_len 0 のヘッダだけ（送信には使わない）（v2: C13, C20）
  static Envelope decode(Uint8List bytes, {bool strict = false}); // 「中継できる条件」を満たさなければ EnvelopeFormatException。「表示できる条件」を満たさなければ strict なら例外、そうでなければ不透明メッセージ（docs/02 §2.1）（v2: C13）
  static Envelope decodeStub(Uint8List bytes);  // 空殻（ヘッダだけ）を復元する。保存ファイルの読み込み用（v2: C20）
  Envelope copyWith({int? hop, int? expiresAt}); // 中継時の hop+1 と残り時間の書き換え（v2: C12）
  Envelope asStub();             // 本文を消した空殻にする（取り消し時）（v2: C20）
  NoticeBody? get notice;        // kind==notice かつ isDisplayable のとき
  NoticeBody? get help;          // kind==help かつ isDisplayable のとき（v2: C21）
  GroupInfoBody? get groupInfo;  // kind==groupInfo かつ isDisplayable のとき
  bool isExpiredAt(int epochSeconds); // 発信側の expires_at で判定（受信側の相対判定は MessageStore.localExpiresAt）
}

// ---------------- lib/core/frames.dart ----------------
const int kMaxFrameLength = 8192; const int kMaxInventoryPerFrame = 1023;
const int kMaxHelloGroups = 8;              // HELLO 末尾の参加グループ一覧の上限（v2: C17）
const int kProtocolVersionForHello = 1;     // 不一致でも切らない（v2: C13）
const int kCapRelayUnknown = 0x01;          // caps bit0: 未知版中継可（v2: C13）
const int kCapRelayNode = 0x02;             // caps bit1: 中継役（v2: C04, C17）
const int kCapGroupList = 0x04;             // caps bit2: 参加グループ一覧あり（v2: C17）
const int kCapPush = 0x08;                  // caps bit3: 先出し可（v2: C08）
const int kDefaultCaps = kCapRelayUnknown | kCapPush; // この実装が常に立てる caps（v2: C13）
enum FrameType { hello(0x01), inventory(0x02), inventoryEnd(0x03), time(0x04), inventoryCutoff(0x05), message(0x10), messagesEnd(0x11), bye(0x20); // time / inventoryCutoff（v2: C12, C08）
  int get code; static FrameType? fromCode(int code); }
class Frame {
  const Frame(this.rawType, this.payload);
  final int rawType; final Uint8List payload;
  FrameType? get type;            // 不明なら null
  Uint8List encode();             // u16 len + type + payload
  static Frame hello({required Uint8List nodeId, required int storeCount, int caps = 0, List<int> groupIds = const []}); // groupIds が非空なら caps bit2 を立てて末尾に載せる（8 件まで）（v2: C13, C17）
  static Frame inventory(List<int> msgIds);          // 1,023 件まで
  static List<Frame> inventoryFrames(List<int> msgIds); // 1,023 件ずつに分割（INVENTORY_END は含まない）
  static Frame inventoryEnd();
  static Frame time(int epochSeconds);               // u32（v2: C12）
  static Frame inventoryCutoff(int createdAt);       // u32（v2: C08）
  static Frame message(Uint8List envelopeBytes); static Frame messagesEnd(); static Frame bye();
}
int parseU32Payload(Uint8List payload, {required String name}); // TIME / INVENTORY_CUTOFF の u32。短ければ FrameFormatException（v2: C12, C08）
class HelloInfo {
  final int version; final Uint8List nodeId; final int storeCount;
  final int caps;                 // 能力ビット（v2: C13）
  final List<int> groupIds;       // 相手の参加グループ（caps bit2 のときだけ）（v2: C17）
  bool get relaysUnknown;         // caps bit0（v2: C13）
  bool get isRelayNode;           // caps bit1（v2: C17）
  bool get acceptsPush;           // caps bit3（v2: C08）
  static HelloInfo parse(Uint8List payload); // 12 バイト未満は FrameFormatException。読めない余分は無視（v2: C13）
}
List<int> parseInventory(Uint8List payload);
class FrameParser {
  void addChunk(Uint8List chunk);   // length > 8192 または 0 のフレームは FrameFormatException
  Frame? nextFrame();               // 揃っていなければ null
}
class FrameFormatException implements Exception { final String message; }

// ---------------- lib/core/compression.dart ----------------
const int kMaxBodyPlainBytes = 4096;
Uint8List compressBody(Uint8List plain);                 // raw deflate + kDictionaryV1
Uint8List decompressBody(Uint8List data);                // 上限超過・破損は EnvelopeFormatException

// ---------------- lib/core/dictionary.dart ----------------
final Uint8List kDictionaryV1;  // 災害通知コーパス辞書（UTF-8、4〜8 KB）。v2 でも変えない（v2: C15）

// ---------------- lib/core/ids.dart ----------------
const String kHqCodePrefix = '1'; const String kStaffCodePrefix = '2';   // 8 桁コードの先頭桁（v2: C09）
Uint8List generateNodeId([Random? random]);  // 8 バイト
String hexOf(Uint8List bytes); Uint8List bytesFromHex(String hex);
int u64FromBytes(Uint8List bytes, [int offset = 0]); Uint8List u64ToBytes(int value);
int generateGroupCode([Random? random]);        // 100000..999999
String generateHqCode([Random? random]);        // 本部コード 8 桁（先頭 1 + 7 桁）（v2: C09）
String generateStaffCode([Random? random]);     // スタッフコード 8 桁（先頭 2 + 7 桁）（v2: C09）
String generateOfficialCode([Random? random]);  // 旧名。generateHqCode と同じ
String? normalizeEightDigitCode(String input);  // 空白・ハイフンを除く。8 桁の数字でなければ null（v2: C09）
bool? isHqCode(String code);                    // 先頭 1 → true、先頭 2 → false、それ以外 → null（v2: C09）
Uint8List codeDigestPart(String code);          // SHA-256(ASCII) の先頭 4 バイト（v2: C24）
Uint8List computeCodeDigest({required String hqCode, required String staffCode}); // group_info に載せる 8 バイト（本部 4 ‖ スタッフ 4）（v2: C24）
bool codeMatchesDigest(String code, Uint8List digest, {required bool hq});       // digest の本部側／スタッフ側と一致するか（v2: C24）

// ---------------- lib/mesh/transport.dart ---------------- （実装済み。変更不可）

// ---------------- lib/mesh/store_file.dart ----------------
abstract class StoreBackend {
  Future<List<Uint8List>> readAll();            // 記録順
  Future<void> append(Uint8List record);
  Future<void> rewrite(List<Uint8List> records); // 圧縮（全置換）。本文を消したときは必ず実行する（v2: C20）
}
class MemoryStoreBackend implements StoreBackend {}
class FileStoreBackend implements StoreBackend { FileStoreBackend(String path); } // レコード = u32 len + bytes、破損末尾は切り捨て

// ---------------- lib/mesh/message_store.dart ----------------
const int kMaxRelayHop = 64; const int kTombstoneGraceSeconds = 24 * 60 * 60;
const int kDefaultMaxMessages = 3000;
const int kDefaultInventoryLimit = kDefaultMaxMessages;   // 目録上限 3,000（v2: C08）
const int kSmallChunkInventoryLimit = 300;                // maxChunk が小さいときの目録件数（v2: C08）
const int kMaxOpaqueMessages = 300;                       // 不透明メッセージの件数上限（全体の 10% とも比べる）（v2: C13）
const int kMaxResidentNoticesPerGroup = 500;              // 1 グループあたりの住民 notice（v2: C08）
const int kMaxGroupInfoTtlSeconds = 366 * 24 * 60 * 60;   // group_info・不透明の有効期間上限（v2: C12）
const int kPushMaxCount = 16; const int kPushMaxBytes = 8 * 1024; const int kPushWindowSeconds = 24 * 60 * 60; // 先出し（v2: C08）
enum AddResult { added, duplicate, rejected }
class StoredMessage {
  Envelope get envelope;          // 取り消しで本文を消すと空殻（isStub）に置き換わる（v2: C20）
  final int receivedAt;           // 届いた時刻。自端末発信なら発信時刻
  final bool isLocal;             // 自端末発信
  bool read; int? supersededBy; bool retracted;
  bool retractedByOfficial;       // 公式（role=2）の tombstone で住民・スタッフの投稿が取り消された（v2: C10）
  int? retainUntil;               // tombstone / 書きなおしの保持期限（対象の local_expiry + 24 時間）（v2: C01）
  int get msgId; MessageKind get kind; int get groupId;
  bool get isOpaque;              // 不透明メッセージ（v2: C13）
  bool get isStub;                // 空殻（v2: C20）
  Uint8List get wireBytes;        // 保存用のワイヤ形式（受け取った expires_at のまま。キャッシュ）
  Uint8List wireBytesAt(int now, {required int localExpiresAt}); // 中継用。受信したものは expires_at を created_at + 残り時間に書き換える。自端末発信はそのまま（v2: C12）
}
class InventorySelection { const InventorySelection(this.msgIds, {this.cutoffCreatedAt}); final List<int> msgIds; final int? cutoffCreatedAt; } // 目録を絞ったときの最古 created_at。絞っていなければ null（v2: C08）
class MessageStore extends ChangeNotifier {
  MessageStore(StoreBackend backend, {int maxMessages = 3000});
  Set<int> joinedGroupIds;              // 参加中のグループ。削除順・先出し・表示の判定に使う（AppController が同期）
  Set<int> officialGroupIds;            // この端末が公式（ホスト・本部端末）のグループ。取り消された本文を残す（v2: C20）
  Future<void> load();
  int get count; int get version;       // version は内容が増えるたび +1（既読化・削除では変えない）
  bool get isLoaded; Iterable<StoredMessage> get all;
  int get opaqueCount;                  // 保存している不透明メッセージの件数（v2: C13）
  int get opaqueLimit;                  // min(300, maxMessages ~/ 10)（v2: C13）
  bool contains(int msgId); StoredMessage? get(int msgId);
  Future<AddResult> add(Envelope envelope, {required int now, bool isLocal = false}); // msg_id 既知 → duplicate。hop≥64・有効期間 0 以下または上限超・空殻・supersedes==msgId・body 不正 → rejected。受信時刻と expires_at は比べない。満杯時は 10% まとめ削除、不透明と住民 notice は別枠。tombstone/supersedes は role 規則で反映し、取り消された他人の notice は空殻にする（v2: C12, C13, C08, C10, C20）
  int localExpiresAt(StoredMessage m);  // 自端末発信は expires_at、受信したものは receivedAt + ttl（v2: C12）
  bool isExpired(StoredMessage m, int now);     // 保持期限（retainUntil を含む）で判定（v2: C01）
  bool isDisplayable(StoredMessage m, int now); // 表示できるか（不透明・空殻・取消・置き換え・自身の期限切れを除く）（v2: C13, C20）
  List<int> inventory({required int now, int limit = kDefaultInventoryLimit});     // 新しい順。空殻も載せる
  InventorySelection inventorySelection({required int now, bool small = false}); // small なら受信時刻の新しい順 300 件に絞り cutoff を返す（v2: C08）
  List<StoredMessage> messagesMissingFrom(Set<int> peerHas, {required int now,
      bool peerRelaysUnknown = false,   // 相手の caps bit0。false なら不透明を送らない（v2: C13）
      int? cutoffCreatedAt,             // 相手の INVENTORY_CUTOFF。それより古い notice / help は送らない（v2: C08）
      Set<int>? peerGroups,             // 相手の参加グループ。あればそのグループのものを先に（v2: C17）
      Set<int> exclude = const {}});    // 先出し済み（v2: C08）
                                        // 優先順: kind（group_info → tombstone → ack → notice/help）→ peerGroups → role 降順 → created_at 降順。空殻は含めない
  List<StoredMessage> pushCandidates({required int now, int maxCount = kPushMaxCount}); // 先出し候補: 参加グループの最新 group_info → tombstone（24 時間以内）→ 公式 notice（24 時間以内、未取消・未置き換え）（v2: C08）
  List<StoredMessage> visibleNotices({required int now, Set<int>? groupIds, bool byReceived = false}); // notice, 表示可, 新しい順。byReceived なら届いた時刻の順（v2: C12）
  List<StoredMessage> visibleHelpRequests({required int now, Set<int>? groupIds}); // kind=help, 表示可, 新しい順（v2: C21）
  StoredMessage? ackFor(int msgId);     // msgId への「受け取りました」（kind=ack）。なければ null（v2: C21）
  StoredMessage? latestGroupInfo(int groupId); // 世代 → created_at の順で新しいもの（v2: C24）
  List<StoredMessage> unjoinedGroupInfos({required int now, int limit = 3}); // 未参加グループの group_info を最後に受け取った順に（v2: C22）
  int unreadCount({required int now, Set<int>? groupIds});
  Future<void> markRead(int msgId); Future<void> markAllRead(Set<int> msgIds);
  Future<void> purgeExpired(int now);
}

// ---------------- lib/mesh/groups.dart ----------------
abstract class KeyValueStore { Future<String?> getString(String key); Future<void> setString(String key, String value); Future<void> remove(String key); }
class MemoryKeyValueStore implements KeyValueStore {}
enum ElevateResult { hq, staff, mismatch, notReady, invalid, notJoined } // 本部になった / スタッフになった / 番号がちがう / group_info 未受信 / 8 桁でない・先頭桁が 1・2 でない / 未参加（v2: C09）
class JoinedGroup {
  final int code; String name; final bool isHost; bool isOfficial; bool membersCanPost;
  bool isStaff;             // スタッフコードで昇格済み（v2: C09）
  String? hqCode;           // 本部コード（8 桁、先頭 1）。ホストと本部端末が持つ（v2: C09）
  String? staffCode;        // スタッフコード（8 桁、先頭 2）。ホストは配布用、スタッフ端末は入力した値（v2: C09）
  String? hostName;         // ホストの表示名（ホスト端末のみ）
  String? senderName;       // このグループでの発信元名（施設名・部署名）。null なら設定の表示名（v2: C09）
  String description;       // 問い合わせ先・ひとこと（v2: C24）
  bool acceptsHelp;         // 困りごとを受け付ける（policy bit2）（v2: C21）
  bool closed;              // 閉鎖済み（policy bit1）（v2: C24）
  int successor;            // 後継の参加コード（0 = なし）（v2: C24）
  int generation;           // group_info の世代（v2: C24）
  String? codeDigestHex;    // 受け取った code_digest（16 進）。本部昇格の検証に使う（v2: C24）
  bool get canPost => isHost || isOfficial || isStaff || membersCanPost; // （v2: C09）
  String? get officialCode => hqCode;             // 旧名
  bool get postsAsOfficial => isHost || isOfficial; // 投稿時の役割が公式か（v2: C09）
  bool get canManage => isHost || isOfficial;       // 再発信・方針・コード作り直し・引っ越しを扱えるか（v2: C09）
  SenderRole get postRole;  // 公式 → official、スタッフ → staff、それ以外 → resident（v2: C09）
  Uint8List? get codeDigest; // codeDigestHex のバイト列（8 バイトでなければ null）（v2: C24）
}
class GroupManager extends ChangeNotifier {
  GroupManager(KeyValueStore kv);   // テスト用に Random を注入できる
  Future<void> load();
  List<JoinedGroup> get groups; Set<int> get codes; JoinedGroup? byCode(int code);
  Set<int> get officialCodes;    // postsAsOfficial なグループ ID（v2: C20）
  Future<JoinedGroup> create({required String name, required String hostName, required bool membersCanPost, bool acceptsHelp = false, String description = ''}); // 本部コード・スタッフコードを発行。isOfficial=true、senderName=name（v2: C09, C21, C24）
  Future<JoinedGroup> join(int code, {String? name});
  Future<void> leave(int code);
  Future<ElevateResult> elevate(int code, String input, {Uint8List? knownDigest}); // 先頭 1: ホストは自分のコードと、参加者は knownDigest（なければ保存済み digest）と照合。未受信なら notReady。先頭 2: digest があれば照合、なければ受理（v2: C09, C24）
  Future<void> reverifyStaff(int code);  // 受信した group_info の digest でスタッフ昇格を再検証し、不一致なら isStaff を外す（v2: C09）
  Future<void> setSenderName(int code, String name); // 空なら null（v2: C09）
  Future<void> updateName(int code, String name);
  Future<void> updatePolicy(int code, {bool? membersCanPost, bool? acceptsHelp, bool? closed, int? successor, int? generation, String? codeDigestHex, String? description}); // group_info から反映（v2: C24, C21）
  Future<JoinedGroup> regenerateCodes(int code); // 本部端末が両コードを新発行し世代 +1。canManage でなければ StateError（v2: C24）
  Future<void> closeGroup(int code, {required int successor}); // closed=true、successor、世代 +1（v2: C24）
}

// ---------------- lib/mesh/sync_session.dart ----------------
const Duration kHelloTimeout = Duration(seconds: 5); const Duration kSessionTimeout = Duration(seconds: 30);
const Duration kRelaySessionTimeout = Duration(seconds: 300);   // 中継役どうし（v2: C17）
const int kDefaultSessionByteBudget = 65536;
const int kRelaySessionByteBudget = 1 << 20; const int kRelaySmallChunkByteBudget = 256 * 1024; // 中継役どうし（maxChunk < 180 なら 256 KB）（v2: C17）
const int kSmallChunkThreshold = 100;        // これ未満の maxChunk なら目録を絞る（v2: C08）
const int kRelaySmallChunkThreshold = 180;   // （v2: C17）
const int kMaxOpaqueBytesPerSession = 16 * 1024; // （v2: C13）
typedef TimerFactory = Timer Function(Duration duration, void Function() callback);
enum SessionState { hello, inventory, transfer, closing, done, failed }
class SyncSession {
  SyncSession({
    required int linkId, required String peerId, required bool initiator, required int maxChunk,
    required MessageStore store, required Uint8List nodeId,
    required Future<void> Function(Uint8List chunk) send, required Future<void> Function() close,
    required int Function() now, int sessionByteBudget = 65536,
    void Function(String)? log, TimerFactory? createTimer,
    Duration helloTimeout = kHelloTimeout, Duration sessionTimeout = kSessionTimeout,
    void Function(SyncSession session)? onHello,     // 相手の HELLO 受信時（重複セッションの判定。中で abort してよい）
    int caps = kDefaultCaps,                         // 自分の HELLO に載せる caps（v2: C13）
    List<int> groupIds = const [],                   // 自分の HELLO に載せる参加グループ（中継役のときだけ非空）（v2: C17）
    void Function(int offsetSeconds)? onPeerTime,    // 相手の TIME 受信時（相手の時計 − 自分の時計、秒）（v2: C12）
  });
  SessionState get state; Uint8List? get peerNodeId; int? get peerStoreCount;
  final int caps; final List<int> groupIds;
  int get peerCaps;                 // 相手の caps（HELLO 受信後）（v2: C13）
  List<int> get peerGroupIds;       // 相手の参加グループ（相手が中継役で載せてきたときだけ）（v2: C17）
  bool get peerIsRelay;             // 相手が中継役か（v2: C17）
  bool get isRelay;                 // 自分が中継役か（caps bit1）（v2: C17）
  bool get relaxed;                 // 中継役どうしで上限を緩めたセッションか（v2: C17）
  int? get clockOffset;             // 相手の時計 − 自分の時計（秒）。TIME 未受信なら null（v2: C12）
  int get bytesSent; int get bytesReceived; int get messagesReceived;
  int get messagesSent;             // 送った MESSAGE の件数（先出しを含む）
  int get pushedCount;              // 先出しした件数（v2: C08）
  List<int> get sentMessageIds;     // 送った MESSAGE の msg_id（順）（v2: C18）
  bool get budgetExhausted; bool get succeeded; String? get failureReason; bool get isFinished;
  Future<void> start();                 // HELLO → TIME → INVENTORY（+CUTOFF）→ INVENTORY_END を送る。相手の HELLO で caps bit3 なら先出し（v2: C12, C08）
  void onData(Uint8List chunk);         // 受信チャンク
  void onClosed();                      // リンク切断
  Future<void> get done;                // 終了（成功/失敗）
  void abort(String reason);            // BYE を送って閉じる
}

// ---------------- lib/mesh/mesh_node.dart ----------------
const int kResyncIntervalSeconds = 60; const int kFailureBackoffSeconds = 30; const int kAppleNoServiceIgnoreSeconds = 15 * 60;
const int kRelayResyncIntervalSeconds = 10;  // 中継役どうしの再接続間隔（v2: C17）
const int kMaxInitiatorLinks = 2; const int kRelayMaxInitiatorLinks = 3; // central の同時リンク（中継役は 3）（v2: C04）
const int kClockSamples = 8;                 // 時計の差の中央値に使う直近の TIME 件数（v2: C12）
class PeerRecord { final String peerId; int lastSeen; int? lastDiscoveredAt; int? lastSyncedVersion; int failures; String? nodeIdHex; int? lastSyncAt; int backoffUntil; int ignoreUntil; bool viaApple; bool serviceConfirmed; int rssi; }
class MeshNode extends ChangeNotifier {
  MeshNode({required Transport transport, required MessageStore store, required Uint8List nodeId, int Function()? now,
      TimerFactory? createTimer, int maxInitiatorLinks = kMaxInitiatorLinks, int sessionByteBudget = kDefaultSessionByteBudget,
      int resyncIntervalSeconds = kResyncIntervalSeconds, int failureBackoffSeconds = kFailureBackoffSeconds, int appleIgnoreSeconds = kAppleNoServiceIgnoreSeconds,
      Duration helloTimeout = kHelloTimeout, Duration sessionTimeout = kSessionTimeout,
      void Function(int epochSeconds, int sent, int received)? onSyncCompleted}); // 同期が完了するたび（時刻の保存・交換完了の音用）（v2: C04, C07）
  Future<void> start({bool lowPower = false}); Future<void> stop(); Future<void> setLowPower(bool v);
  bool get running; bool get lowPower; bool get poweredOn; bool get scanning; bool get advertising; String get permission;
  bool get relayMode; void setRelayMode(bool v); // 中継役。HELLO の caps bit1、参加グループ一覧、同時接続数、再接続間隔に効く（v2: C04, C17）
  int get caps;                         // kDefaultCaps | (relayMode ? kCapRelayNode : 0)（v2: C13）
  int get maxInitiatorLinks;            // 中継役なら 3、それ以外は生成時の値（v2: C04）
  int get nearbyCount;                  // 直近 60 秒に見えた peer 数
  int get activeSessions; int? get lastReceivedAt; int get totalSessions; int get totalMessagesReceived;
  int get totalMessagesSent;            // 送った MESSAGE の累計（v2: C18）
  int? get lastSyncAt;                  // 最後に同期が完了した時刻（起動後）（v2: C07）
  int? get lastSentAt;                  // 最後に MESSAGE を渡した時刻（v2: C18）
  int? get startedAt;                   // 通信を開始した時刻（v2: C07）
  int? get lastPeerSeenAt;              // 最後に何かの端末を見かけた時刻（v2: C07）
  int? get clockOffsetSeconds;          // 近くの端末との時計の差（相手 − 自分、秒）の中央値。測定前は null（v2: C12）
  List<String> get recentLog;           // 最新 100 行
  List<PeerRecord> get peers; List<SyncSession> get sessions;
  Future<AddResult> publish(Envelope envelope); // store.add(isLocal) + 直ちに再接続許可
  // 接続判断: discovered → PeerRecord → バックオフ(docs/02 §4) → connect。central 同時 2（中継役 3）。
  // 再接続: 同じ node_id とは 60 秒（自分が中継役で相手も中継役だった相手とは 10 秒）。store.version が変われば待たない。（v2: C17）
}

// ---------------- lib/app/app_controller.dart ----------------
const Duration kEndNoticeTtl = Duration(hours: 12);      // 「終わりました」の既定期限（v2: C01）
const Duration kMaxNoticeTtl = Duration(days: 30);       // （v2: C02）
const Duration kKeepScreenOnDuration = Duration(minutes: 30); // （v2: C07）
const int kUrgentPerGroupLimit = 3; const int kUrgentWindowSeconds = 10 * 60; // urgent 通知はグループごと 10 分 3 件まで（v2: C05）
const int kLowBatteryPercent = 20; const int kLowBatteryRecoverPercent = 50;   // 自動「長持ち」のヒステリシス（v2: C06）
enum NotificationLevel { all, important, off }  // ぜんぶ 知らせる / 公式と 大事なものだけ（既定）/ 知らせない（v2: C05）
class BatteryInfo { final int level; final bool charging; }  // （v2: C06）
class AppSettings {
  String displayName; double textScale; /*1.0,1.25,1.5*/ bool lowPowerPreferred; bool onboardingDone; bool meshEnabled;
  NotificationLevel notificationLevel; /*既定 important*/   // （v2: C05）
  bool relayMode;        /*既定 false*/  // 中継役として使う（v2: C04）
  bool chimeEnabled;     /*既定 true*/   // 交換完了の音（中継役のとき）（v2: C04）
  int? lastSyncAt;                       // 最後に同期が完了した時刻（永続）（v2: C07）
  int? lastOpenedAt;                     // 最後にアプリを前面にした時刻（v2: C07）
  bool get notificationsEnabled; set notificationsEnabled(bool v); // notificationLevel != off の短縮（v1 の 2 択から引き継ぐ）
}
abstract class PlatformActions {
  Future<bool> requestPermissions(); Future<bool> requestBatteryOptimizationExemption(); Future<void> openAppSettings(); Future<bool> requestNotificationPermission();
  Future<void> showNotice({required int id, required String title, required String body, required int groupCode, NoticeImportance importance = NoticeImportance.important, int? msgId}); // （v2: C05）
  Future<void> cancelNotice(int id);          // 取り消された緊急通知を消す（v2: C05）
  Future<void> setKeepScreenOn(bool on);      // （v2: C04, C07）
  Future<void> playChime();                   // 交換完了の短い音と振動（v2: C04）
  Future<BatteryInfo?> getBattery();          // 取れない環境では null（v2: C06）
  Future<void> speak(String text); Future<void> stopSpeaking(); // OS 標準の音声合成（v2: C19）
  Future<void> scheduleMonthlyReminder(); Future<void> cancelMonthlyReminder(); // 月 1 回の確認通知（v2: C07）
}
class NoopPlatformActions implements PlatformActions {}      // ハブ・テスト用
class BleTransportActions implements PlatformActions { BleTransportActions(BleTransport ble); } // BleTransport の追加メソッドへ委譲
class AppController extends ChangeNotifier {
  AppController({required Transport transport, required StoreBackend storeBackend, required KeyValueStore kv, PlatformActions? platform,
      int Function()? now, TimerFactory? createTimer, Uint8List? nodeId, Future<void> Function(bool enabled)? onMeshEnabledChanged, Future<void> Function(DateTime at)? onReceived});
  static Future<AppController> createDefault();   // 実機: BleTransport + FileStoreBackend + SharedPreferences（KAIRANBAN_HUB 指定時は HubTransport + NoopPlatformActions）
  Future<void> init();                            // load settings/groups/store、relayMode を node に反映、1 分ごとの期限掃除と電池確認、meshEnabled なら start
  AppSettings get settings; MessageStore get store; GroupManager get groups; MeshNode get node; Uint8List get nodeId;
  Future<void> saveSettings(AppSettings s);       // relayMode の変更は node.setRelayMode と setKeepScreenOn に反映。通知レベルの変更は月 1 回の確認通知の予約／取消に反映（v2: C04, C07）
  Future<void> startMesh(); Future<void> stopMesh(); Future<bool> requestPermissions(); Future<bool> requestBatteryExemption(); Future<void> openAppSettings();
  Future<bool> requestNotificationPermission();
  void setForeground(bool inForeground); bool get inForeground; // 前面に戻ったらまとめ待ちの通知を捨て lastOpenedAt を保存。背面に行ったら「画面を 点けたままにする」を解除（v2: C07）
  // 通知（docs/03 §4）
  List<int> get foregroundUrgentIds;              // 前面で届いた緊急（公式・スタッフの避難情報・注意喚起）の msg_id。画面の赤帯用（v2: C05）
  void acknowledgeUrgent();                       // 赤帯をタップして消す（v2: C05）
  NoticeImportance importanceOf(StoredMessage m, NoticeBody notice); // 訓練 → normal。公式・スタッフの避難情報・注意喚起 → urgent。公式・スタッフ、または種別が important 以上 → important。残り → normal（v2: C05）
  static String notificationBody(StoredMessage m, NoticeBody notice); // 「場所: 〇〇 ／ 本文 1 行目（30 文字）」。本文は避難情報・注意喚起・避難所・給水・炊き出し・物資だけ。空なら「〇〇 から」（v2: C05）
  // 電池・画面・読み上げ
  BatteryInfo? get battery;                       // （v2: C06）
  bool get autoLowPower;                          // 残量 20% 以下（非充電）で自動的に「長持ち」に入っているか（v2: C06）
  Future<void> refreshBattery();                  // 1 分ごとと init 時に呼ぶ。充電中 → ふつう、20% 以下 → 長持ち、50% 超 → 戻す。中継役は常にふつう（v2: C06）
  int? get keepScreenOnUntil;                     // 「画面を 点けたままにする」の期限。していなければ null（v2: C07）
  Future<void> keepScreenOn(); Future<void> stopKeepScreenOn(); // 30 分。中継役のときは画面点灯を続ける（v2: C07）
  Future<void> speak(String text); Future<void> stopSpeaking(); // （v2: C19）
  int? get clockOffsetSeconds;                    // node.clockOffsetSeconds（v2: C12）
  bool get clockLooksWrong;                       // now が 0（2026 年より前）または近くの端末と 24 時間超のずれ（v2: C12）
  // 投稿
  String senderNameFor(JoinedGroup group);        // グループごとの発信元名 → ホスト名 → 設定の表示名（v2: C09）
  Future<Envelope> postNotice({required int groupCode, required NoticeCategory category, required String title, String place = '', String text = '', Duration? ttl,
      int? supersedes,                            // 「書きなおし」。元の msg_id（v2: C01）
      bool training = false});                    // 公式・スタッフなら見出しに「【訓練】」を付ける（v2: C23）
                                                  // role は group.postRole、sender_name は senderNameFor、ttl は 30 日で頭打ち（v2: C09, C02）
  Future<Envelope> supersedeNotice(int msgId, {NoticeCategory? category, required String title, String place = '', String text = '', Duration? ttl}); // 自分の投稿を書きなおす（v2: C01）
  Future<Envelope> endNotice(int msgId);          // 自分の投稿を「終わりました」で置き換える（見出しは category.endTitle、本文「（〇月〇日 午後〇時〇分に 終わりました）」、期限 12 時間）（v2: C01）
  bool canRetract(StoredMessage m);               // 本人、または同じグループの公式端末（v2: C10）
  Future<void> retract(int msgId);                // tombstone を発信。公式端末が他人の投稿を取り消すときは role=2（v2: C10）
  Future<int> retractTraining(int groupCode);     // 見出しが【訓練】の自分の投稿（公式端末は他人の分も）をすべて取り消す。件数を返す（v2: C23）
  // グループ
  Future<JoinedGroup> createGroup({required String name, required bool membersCanPost, String description = '', bool acceptsHelp = false}); // group_info も発信（v2: C24, C21）
  Future<JoinedGroup> joinGroup(int code);        // store の latestGroupInfo から名前・方針を補完
  Future<void> leaveGroup(int code);
  Future<ElevateResult> elevate(int code, String input); // 8 桁コードで昇格。本部コードは受信済み group_info の code_digest と照合（v2: C09, C24）
  Future<void> setGroupSenderName(int code, String name); // このグループでの発信元名（v2: C09）
  Future<void> setMembersCanPost(int code, bool v);  // 本部端末。group_info を再発信（v2: C09）
  Future<void> setAcceptsHelp(int code, bool v);     // 本部端末。group_info を再発信（v2: C21）
  Future<JoinedGroup> regenerateCodes(int code);     // 本部端末。両コードを作り直し世代 +1 で再発信（v2: C24）
  Future<JoinedGroup> moveGroup(int oldCode, {required String newName}); // 新グループを作り、旧 group_info を closed・successor 付きで再発信（v2: C24）
  Future<void> republishGroupInfo(int code);      // ホスト・本部端末が再発信（code_digest・generation・successor・description 付き）（v2: C09, C24）
  List<StoredMessage> nearbyGroupInfos({int limit = 3}); // 近くで流れている（未参加の）グループ（v2: C22）
  // 表示
  List<StoredMessage> notices({int? groupCode, bool byReceived = true}); // 参加グループのみ。既定は届いた時刻の新しい順（v2: C12）
  List<StoredMessage> pinnedAlerts({int? groupCode, int limit = 3}); // 固定枠: 公式の避難情報・注意喚起（訓練を除く）を created_at の新しい順に最大 3 件（v2: C03）
  int get unreadCount; int get unreadTrainingCount; // （v2: C23）
  Future<void> markRead(int msgId);
  Future<void> markVisibleRead({int? groupCode}); // 一覧に表示した未読をすべて既読に（v2: C03）
  static String bulletinNumber(int msgId);        // 掲示番号: msg_id の下位 20 ビットを 10 進 6 桁（v2: C19）
  int get now;                                    // epoch 秒（テスト差し替え可）
}

// ---------------- lib/transport/ble_transport.dart ----------------
class BleTransport implements Transport {
  // Transport の start / stop / setLowPower / connect / send / close に加えて docs/03 §3 のメソッドを 1 対 1 で持つ。
  // PlatformException / MissingPluginException は TransportLog に流して null を返す（connect / send だけ再送出）。
  Future<BleState> getState(); Future<bool> requestPermissions(); Future<bool> requestBatteryOptimizationExemption(); Future<void> openAppSettings();
  Future<void> noteReceived(DateTime at); Future<bool> requestNotificationPermission();
  Future<void> showNotice({required int id, required String title, required String body, required int groupCode, String importance = 'important', int? msgId}); // （v2: C05）
  Future<void> cancelNotice(int id);                       // （v2: C05）
  Future<void> setKeepScreenOn(bool on);                   // （v2: C04, C07）
  Future<void> playChime();                                // （v2: C04）
  Future<({int level, bool charging})?> getBattery();      // level < 0 や未対応は null（v2: C06）
  Future<void> speak(String text, {double rate = 0.8}); Future<void> stopSpeaking(); // （v2: C19）
  Future<void> scheduleMonthlyReminder({required String title, required String body}); Future<void> cancelMonthlyReminder(); // scheduleReminder / cancelReminder（v2: C07）
}
```

## 画面側の依存
- `main.dart` は `AppController.createDefault()` → `init()` → `runApp(KairanApp(controller))`。
- UI は `AnimatedBuilder`/`ListenableBuilder` で `AppController` と `store`/`node`/`groups` を監視する。
- 日付・時刻の表示は `lib/ui/format.dart` に `formatDateTimeJa(DateTime)`（例「2026年10月11日 午後3時20分」）、`formatRelativeJa(Duration)`（「2時間前」）、`dateHeaderJa(DateTime)`（「今日」「きのう」「10月9日（木）」）を置く。
- 一覧の並び順と日付見出しは `notices()`（届いた時刻の順）、カードの時刻は `envelope.createdAt`。固定枠は `pinnedAlerts()`。前面の赤帯は `foregroundUrgentIds` と `acknowledgeUrgent()`。（v2: C12, C03, C05）
- 詳細の「終わりました」「書きなおす」「取り消す」は `endNotice` / `supersedeNotice` / `retract`。公式端末の「公式として 取り消す」は `canRetract` で出し分ける。読み上げは `speak` / `stopSpeaking`、掲示番号は `bulletinNumber`。（v2: C01, C10, C19）
- 中継役の状態表示は `settings.relayMode`・`node.nearbyCount`・`node.lastReceivedAt`・`node.lastSentAt`・`store.count`。設定の電池欄は `battery` と `autoLowPower`。（v2: C04, C06）

## 改訂履歴

| 版 | 日付 | 内容 |
|---|---|---|
| v1 | 2026-10-11 | 初版 |
| v2 | 2026-10-21 | 実装に合わせて改訂。categories（例文・終わりました・重要度・訓練）、envelope（kind 3/4・不透明・空殻・supersedes 入り msg_id・GroupInfoBody の ext）、frames（TIME / INVENTORY_CUTOFF / caps / 参加グループ一覧）、ids（本部・スタッフコードとダイジェスト）、MessageStore（相対期限・不透明・先出し・目録の絞り込み・help/ack・世代）、SyncSession / MeshNode（中継役・時計差・lastSyncAt）、GroupManager（2 本のコード・発信元名・世代・閉鎖）、AppController / AppSettings / PlatformActions / BleTransport（通知 3 段階・電池・画面点灯・読み上げ・書きなおし・公式取消・訓練・引っ越し） |
