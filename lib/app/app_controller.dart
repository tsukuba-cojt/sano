/// ノード / ストア / 設定の生成と UI への公開（ChangeNotifier）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/categories.dart';
import '../core/envelope.dart';
import '../core/epoch.dart';
import '../core/ids.dart';
import '../core/report.dart';
import '../mesh/groups.dart';
import '../mesh/mesh_node.dart';
import '../mesh/message_store.dart';
import '../mesh/store_file.dart';
import '../mesh/sync_session.dart' show TimerFactory;
import '../mesh/transport.dart';
import 'handed_log.dart';
import 'test_data.dart';
import '../transport/ble_transport.dart';
import '../transport/hub_transport.dart';

/// 表示名が空のときに使う名前。
const String kDefaultDisplayName = '名前なし';

/// group_info の有効期間（365 日）。
const Duration kGroupInfoTtl = Duration(days: 365);

/// 期限切れメッセージを掃除する間隔。
const Duration kPurgeInterval = Duration(minutes: 1);

/// 新しいお知らせを OS 通知にまとめるまでの待ち時間（連続受信を 1 件にまとめる）。
const Duration kNoticeNotificationDebounce = Duration(seconds: 5);

/// 「終わりました」の既定有効期限（C01）。
const Duration kEndNoticeTtl = Duration(hours: 12);

/// 有効期限の上限（30 日、C02）。
const Duration kMaxNoticeTtl = Duration(days: 30);

/// 「画面を 点けたままにする」の時間（C07）。
const Duration kKeepScreenOnDuration = Duration(minutes: 30);

/// urgent 通知をグループごとに 10 分間に出す上限（超過分はまとめ通知、C05）。
const int kUrgentPerGroupLimit = 3;
const int kUrgentWindowSeconds = 10 * 60;

/// 自動「長持ち」に入る残量と、戻す残量（ヒステリシス、C06）。
const int kLowBatteryPercent = 20;
const int kLowBatteryRecoverPercent = 50;

/// 月 1 回の確認通知の文面（C07）。
const String kMonthlyReminderTitle = '回覧板の 確認です。災害では ありません';
const String kMonthlyReminderBody = '開いて 動いているか 確かめてください';

/// 「受け取りました」（ack）の有効期間の上限（元の知らせの期限 + 24 時間、最大 72 時間）。
const Duration kReportAckGrace = Duration(hours: 24);
const Duration kReportAckMaxTtl = Duration(hours: 72);

/// 同じ知らせを短い間に送り直そうとしたとき（C21）。
class ReportTooSoonException implements Exception {
  const ReportTooSoonException(this.type, this.sentAt);

  final ReportType type;

  /// 前に送った時刻（エポック秒）。
  final int sentAt;

  @override
  String toString() => type == ReportType.sos
      ? 'さきほど 送りました。もう少し 待ってから 送り直してください。急ぐときは 近所の 人にも 声を かけてください。'
      : 'さきほど 送りました。受け取りの 返事を 待ってください。';
}

/// 住民からの知らせ 1 件（画面用）。
class ReportEntry {
  const ReportEntry({
    required this.message,
    required this.body,
    required this.info,
    this.ack,
  });

  final StoredMessage message;
  final NoticeBody body;
  final ReportInfo info;

  /// 「受け取りました」。まだなら null。
  final StoredMessage? ack;

  int get msgId => message.msgId;
  int get groupId => message.groupId;
  bool get acked => ack != null;
}

/// OS 通知の出し方（docs/08 C05）。
enum NotificationLevel {
  /// すべて知らせる。
  all,

  /// 公式と大事なものだけ（既定）。
  important,

  /// 知らせない。
  off,
}

/// 電池の状態（C06）。
class BatteryInfo {
  const BatteryInfo({required this.level, required this.charging});

  /// 残量（0..100）。
  final int level;

  /// 充電中か。
  final bool charging;
}

/// アプリ設定。
class AppSettings {
  AppSettings({
    this.displayName = '',
    this.textScale = 1.0,
    this.lowPowerPreferred = false,
    this.onboardingDone = false,
    this.meshEnabled = false,
    this.notificationLevel = NotificationLevel.important,
    this.relayMode = false,
    this.chimeEnabled = true,
    this.lastSyncAt,
    this.lastOpenedAt,
    this.developerMode = false,
  });

  /// 表示名（住民投稿の発信元名）。空なら「名前なし」。
  String displayName;

  /// 文字の大きさ（1.0 / 1.25 / 1.5）。
  double textScale;

  /// 「電池を長持ち」を選んでいるか。
  bool lowPowerPreferred;

  /// 初回案内を終えたか。
  bool onboardingDone;

  /// 通信を開始済みか（起動時に自動再開する）。
  bool meshEnabled;

  /// OS 通知の出し方。
  NotificationLevel notificationLevel;

  /// 中継役として使う（受付・集会所・運び役、C04）。
  bool relayMode;

  /// 交換完了の音を鳴らす（中継役のとき、C04）。
  bool chimeEnabled;

  /// 最後に同期が完了した時刻（エポック秒、C07）。
  int? lastSyncAt;

  /// 最後にアプリを開いた時刻（エポック秒、C07）。
  int? lastOpenedAt;

  /// 開発者メニュー（実機テスト用のデータ投入）を出すか（#152）。
  bool developerMode;

  /// 新しいお知らせを OS の通知で知らせるか（[notificationLevel] の短縮）。
  bool get notificationsEnabled => notificationLevel != NotificationLevel.off;
  set notificationsEnabled(bool v) {
    if (v) {
      if (notificationLevel == NotificationLevel.off) {
        notificationLevel = NotificationLevel.important;
      }
    } else {
      notificationLevel = NotificationLevel.off;
    }
  }

  AppSettings copy() => AppSettings(
        displayName: displayName,
        textScale: textScale,
        lowPowerPreferred: lowPowerPreferred,
        onboardingDone: onboardingDone,
        meshEnabled: meshEnabled,
        notificationLevel: notificationLevel,
        relayMode: relayMode,
        chimeEnabled: chimeEnabled,
        lastSyncAt: lastSyncAt,
        lastOpenedAt: lastOpenedAt,
        developerMode: developerMode,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'displayName': displayName,
        'textScale': textScale,
        'lowPowerPreferred': lowPowerPreferred,
        'onboardingDone': onboardingDone,
        'meshEnabled': meshEnabled,
        'notificationLevel': notificationLevel.name,
        'notificationsEnabled': notificationsEnabled,
        'relayMode': relayMode,
        'chimeEnabled': chimeEnabled,
        'lastSyncAt': lastSyncAt,
        'lastOpenedAt': lastOpenedAt,
        'developerMode': developerMode,
      };

  static AppSettings fromJson(Map<String, Object?> json) {
    final levelName = json['notificationLevel'] as String?;
    NotificationLevel level;
    if (levelName != null) {
      level = NotificationLevel.values.firstWhere(
        (l) => l.name == levelName,
        orElse: () => NotificationLevel.important,
      );
    } else {
      // v1 の 2 択から引き継ぐ。
      level = ((json['notificationsEnabled'] as bool?) ?? true)
          ? NotificationLevel.important
          : NotificationLevel.off;
    }
    return AppSettings(
      displayName: (json['displayName'] as String?) ?? '',
      textScale: ((json['textScale'] as num?) ?? 1.0).toDouble(),
      lowPowerPreferred: (json['lowPowerPreferred'] as bool?) ?? false,
      onboardingDone: (json['onboardingDone'] as bool?) ?? false,
      meshEnabled: (json['meshEnabled'] as bool?) ?? false,
      notificationLevel: level,
      relayMode: (json['relayMode'] as bool?) ?? false,
      chimeEnabled: (json['chimeEnabled'] as bool?) ?? true,
      lastSyncAt: json['lastSyncAt'] as int?,
      lastOpenedAt: json['lastOpenedAt'] as int?,
      developerMode: (json['developerMode'] as bool?) ?? false,
    );
  }
}

/// OS 側の操作（権限要求・OS 通知など）。トランスポートの契約には含まれないため
/// 別に注入する。null なら何もしない。
abstract class PlatformActions {
  Future<bool> requestPermissions();
  Future<bool> requestBatteryOptimizationExemption();
  Future<void> openAppSettings();

  /// OS の通知権限を要求する。許可済み・不要な環境では true。
  Future<bool> requestNotificationPermission();

  /// OS のローカル通知を出す。同じ [id] の通知は置き換える。
  Future<void> showNotice({
    required int id,
    required String title,
    required String body,
    required int groupCode,
    NoticeImportance importance = NoticeImportance.important,
    int? msgId,
  });

  /// 出した通知を消す。
  Future<void> cancelNotice(int id);

  /// 画面を消さない（C04 C07）。
  Future<void> setKeepScreenOn(bool on);

  /// 交換完了の短い音と振動（C04）。
  Future<void> playChime();

  /// 電池の状態。取れない環境では null（C06）。
  Future<BatteryInfo?> getBattery();

  /// OS 標準の音声合成で読み上げる（C19）。
  Future<void> speak(String text);

  /// 読み上げを止める。
  Future<void> stopSpeaking();

  /// 確認通知を [at] に予約する（C07。アプリを開くたびに予約し直す）。
  Future<void> scheduleMonthlyReminder({required DateTime at});

  /// 月 1 回の確認通知を取り消す。
  Future<void> cancelMonthlyReminder();
}

/// OS 操作が不要なトランスポート（ハブ・テスト）向けの何もしない実装。
class NoopPlatformActions implements PlatformActions {
  const NoopPlatformActions();

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<bool> requestBatteryOptimizationExemption() async => true;

  @override
  Future<void> openAppSettings() async {}

  @override
  Future<bool> requestNotificationPermission() async => true;

  @override
  Future<void> showNotice({
    required int id,
    required String title,
    required String body,
    required int groupCode,
    NoticeImportance importance = NoticeImportance.important,
    int? msgId,
  }) async {}

  @override
  Future<void> cancelNotice(int id) async {}

  @override
  Future<void> setKeepScreenOn(bool on) async {}

  @override
  Future<void> playChime() async {}

  @override
  Future<BatteryInfo?> getBattery() async => null;

  @override
  Future<void> speak(String text) async {}

  @override
  Future<void> stopSpeaking() async {}

  @override
  Future<void> scheduleMonthlyReminder({required DateTime at}) async {}

  @override
  Future<void> cancelMonthlyReminder() async {}
}

/// [BleTransport] の OS 操作を [PlatformActions] として渡すアダプタ。
class BleTransportActions implements PlatformActions {
  const BleTransportActions(this._ble);

  final BleTransport _ble;

  @override
  Future<bool> requestPermissions() => _ble.requestPermissions();

  @override
  Future<bool> requestBatteryOptimizationExemption() =>
      _ble.requestBatteryOptimizationExemption();

  @override
  Future<void> openAppSettings() => _ble.openAppSettings();

  @override
  Future<bool> requestNotificationPermission() =>
      _ble.requestNotificationPermission();

  @override
  Future<void> showNotice({
    required int id,
    required String title,
    required String body,
    required int groupCode,
    NoticeImportance importance = NoticeImportance.important,
    int? msgId,
  }) =>
      _ble.showNotice(
        id: id,
        title: title,
        body: body,
        groupCode: groupCode,
        importance: importance.name,
        msgId: msgId,
      );

  @override
  Future<void> cancelNotice(int id) => _ble.cancelNotice(id);

  @override
  Future<void> setKeepScreenOn(bool on) => _ble.setKeepScreenOn(on);

  @override
  Future<void> playChime() => _ble.playChime();

  @override
  Future<BatteryInfo?> getBattery() async {
    final b = await _ble.getBattery();
    return b == null ? null : BatteryInfo(level: b.level, charging: b.charging);
  }

  @override
  Future<void> speak(String text) => _ble.speak(text);

  @override
  Future<void> stopSpeaking() => _ble.stopSpeaking();

  @override
  Future<void> scheduleMonthlyReminder({required DateTime at}) =>
      _ble.scheduleMonthlyReminder(
        title: kMonthlyReminderTitle,
        body: kMonthlyReminderBody,
        at: at,
      );

  @override
  Future<void> cancelMonthlyReminder() => _ble.cancelMonthlyReminder();
}

/// shared_preferences を [KeyValueStore] に合わせる薄いアダプタ。
class SharedPrefsKeyValueStore implements KeyValueStore {
  SharedPrefsKeyValueStore([SharedPreferencesAsync? prefs])
      : _prefs = prefs ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _prefs;

  @override
  Future<String?> getString(String key) => _prefs.getString(key);

  @override
  Future<void> setString(String key, String value) =>
      _prefs.setString(key, value);

  @override
  Future<void> remove(String key) => _prefs.remove(key);
}

/// アプリ全体の司令塔。
class AppController extends ChangeNotifier {
  AppController({
    required this._transport,
    required StoreBackend storeBackend,
    required KeyValueStore kv,
    this._platform,
    int Function()? now,
    this._createTimer,
    Uint8List? nodeId,
    this._onMeshEnabledChanged,
    this._onReceived,
  })  : _kv = kv,
        _now = now ?? nowEpochSeconds,
        _presetNodeId = nodeId,
        _store = MessageStore(storeBackend),
        _groups = GroupManager(kv);

  /// 永続化キー。
  static const String settingsKey = 'settings.v1';
  static const String nodeIdKey = 'node.id';
  static const String handedKey = 'handed.v1';

  /// docs/03 §4: ネイティブ側と共有する「開始済み」フラグ。
  static const String meshEnabledKey = 'mesh.enabled';

  final Transport _transport;
  final KeyValueStore _kv;
  final PlatformActions? _platform;
  final int Function() _now;
  final TimerFactory? _createTimer;
  final Future<void> Function(bool enabled)? _onMeshEnabledChanged;

  /// お知らせを受け取るたびに呼ぶ（iOS の Live Activity 更新用）。null なら何もしない。
  final Future<void> Function(DateTime at)? _onReceived;
  final Uint8List? _presetNodeId;
  final MessageStore _store;
  final GroupManager _groups;

  AppSettings _settings = AppSettings();
  MeshNode? _node;
  HandedLog _handed = HandedLog();
  Uint8List? _nodeId;
  Timer? _purgeTimer;
  Timer? _keepScreenTimer;
  bool _initialized = false;

  /// [_onReceived] に最後に知らせた受信時刻（エポック秒）。
  int? _reportedReceivedAt;

  /// アプリが前面（AppLifecycleState.resumed）か。UI 層が [setForeground] で更新する。
  /// 既定は false（画面がまだ無い起動直後・バックグラウンド起動では通知を出す側に倒す）。
  bool _foreground = false;

  /// すでに見た（通知済み・表示済み・自分の投稿）お知らせの msg_id。
  /// init 時点でストアにあるものはすべて既知として扱い、以後増えた分だけ通知する。
  final Set<int> _knownNoticeIds = <int>{};

  /// バックグラウンドで届いて、まだ画面で見ていない新しいお知らせ（到着順）。
  /// 前面に戻ったら空にする。通知 ID は先頭の msg_id から作るので、
  /// 続けて届いた分は同じ通知を「N 件」に更新する形になる。
  final List<int> _pendingNoticeIds = <int>[];

  /// 前面で届いた緊急（公式の避難情報・注意喚起）の msg_id。画面が帯で示し、
  /// タップで [acknowledgeUrgent] する（C05）。
  final List<int> _foregroundUrgentIds = <int>[];

  /// urgent 通知を出した時刻（グループごと、直近 10 分の分だけ残す）。
  final Map<int, List<int>> _urgentSentAt = <int, List<int>>{};

  /// 連続受信をまとめるためのデバウンスタイマー。
  Timer? _noticeTimer;

  /// すでに見た知らせ（kind=help）と「受け取りました」（kind=ack）の msg_id。
  final Set<int> _knownReportIds = <int>{};

  /// 背面で届いて、まだ通知していない住民からの知らせ（SOS 以外、到着順）。
  final List<int> _pendingReportIds = <int>[];
  Timer? _reportTimer;

  BatteryInfo? _battery;
  bool _autoLowPower = false;
  int? _keepScreenOnUntil;

  /// 実機用: BleTransport + FileStoreBackend + SharedPreferences。
  static Future<AppController> createDefault() async {
    final dir = await getApplicationSupportDirectory();
    final backend = FileStoreBackend('${dir.path}/messages.bin');
    // 開発用: --dart-define=KAIRANBAN_HUB=host:port で TCP ハブ（模擬電波）を使う。
    // iOS シミュレータは BLE 非対応のため、この経路で UI と同期を確認する。
    const hubSpec = String.fromEnvironment('KAIRANBAN_HUB');
    if (hubSpec.isNotEmpty) {
      final parts = hubSpec.split(':');
      final host = parts.first;
      final port = parts.length > 1
          ? int.tryParse(parts[1]) ?? kHubDefaultPort
          : kHubDefaultPort;
      return AppController(
        transport: HubTransport(host, port),
        storeBackend: backend,
        kv: SharedPrefsKeyValueStore(),
        platform: const NoopPlatformActions(),
        onMeshEnabledChanged: _mirrorMeshEnabledForNative,
      );
    }
    final ble = BleTransport();
    return AppController(
      transport: ble,
      storeBackend: backend,
      kv: SharedPrefsKeyValueStore(),
      platform: BleTransportActions(ble),
      onMeshEnabledChanged: _mirrorMeshEnabledForNative,
      onReceived: ble.noteReceived,
    );
  }

  /// Android の BootReceiver が読む旧形式 SharedPreferences
  /// （"FlutterSharedPreferences" の "flutter.mesh.enabled"）にも保存する。
  static Future<void> _mirrorMeshEnabledForNative(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(meshEnabledKey, enabled);
    } catch (_) {
      // 失敗しても通信自体には影響しない。
    }
  }

  bool get isInitialized => _initialized;
  AppSettings get settings => _settings;
  MessageStore get store => _store;
  GroupManager get groups => _groups;

  MeshNode get node {
    final n = _node;
    if (n == null) {
      throw StateError('init() が呼ばれていません');
    }
    return n;
  }

  Uint8List get nodeId {
    final id = _nodeId;
    if (id == null) {
      throw StateError('init() が呼ばれていません');
    }
    return id;
  }

  /// 現在のエポック秒（テストでは差し替え可）。
  int get now => _now();

  /// 電池の状態（取れない環境では null）。
  BatteryInfo? get battery => _battery;

  /// 残量 20% 以下で自動的に「長持ち」に入っているか（C06）。
  bool get autoLowPower => _autoLowPower;

  /// 「画面を 点けたままにする」の期限（エポック秒）。していなければ null（C07）。
  int? get keepScreenOnUntil => _keepScreenOnUntil;

  /// 前面で届いた緊急のお知らせ（画面の帯用、C05）。
  List<int> get foregroundUrgentIds => List.unmodifiable(_foregroundUrgentIds);

  /// 近くの端末との時計の差（相手 − 自分、秒）。測定前は null（C12）。
  int? get clockOffsetSeconds => _node?.clockOffsetSeconds;

  /// この端末の時計が合っていなさそうか（2026 年より前、または近くの端末と
  /// 24 時間以上ずれている、C12）。
  bool get clockLooksWrong {
    if (_now() <= 0) {
      return true;
    }
    final offset = clockOffsetSeconds;
    return offset != null && offset.abs() > 24 * 3600;
  }

  /// 設定・グループ・ストアを読み込み、meshEnabled なら通信を開始する。
  Future<void> init() async {
    if (_initialized) {
      return;
    }
    await _loadSettings();
    await _loadNodeId();
    await _groups.load();
    await _store.load();
    await _loadHanded();
    _store.joinedGroupIds = _groups.codes;
    _store.officialGroupIds = _groups.officialCodes;
    // 起動時点で保存されていたものは「新着」ではない（通知しない）。
    _knownNoticeIds.addAll(_store.all.map((m) => m.msgId));
    _knownReportIds.addAll(_store.all.map((m) => m.msgId));

    final node = MeshNode(
      transport: _transport,
      store: _store,
      nodeId: nodeId,
      now: _now,
      createTimer: _createTimer,
      onSyncCompleted: _onSyncCompleted,
      onHanded: _onHanded,
    );
    node.setRelayMode(_settings.relayMode);
    _node = node;

    _store.addListener(_onStoreChanged);
    _groups.addListener(_onGroupsChanged);
    node.addListener(_onNodeChanged);

    _purgeTimer?.cancel();
    _purgeTimer = (_createTimer != null)
        ? _createTimer(kPurgeInterval, _onPurgeTick)
        : Timer.periodic(kPurgeInterval, (_) => _onPurgeTick());

    _initialized = true;
    await _store.purgeExpired(_now());
    _syncGroupInfoFromStore();
    unawaited(refreshBattery());
    unawaited(_applyReminderSetting());
    if (_settings.relayMode) {
      unawaited(_platform?.setKeepScreenOn(true));
    }

    if (_settings.meshEnabled) {
      await startMesh();
    }
    notifyListeners();
  }

  void _onPurgeTick() {
    unawaited(_store.purgeExpired(_now()).then((_) {
      if (_handed.prune(_store.contains)) {
        unawaited(_persistHanded());
      }
    }));
    unawaited(refreshBattery());
    if (_createTimer != null && _initialized) {
      _purgeTimer = _createTimer(kPurgeInterval, _onPurgeTick);
    }
  }

  @override
  void dispose() {
    _purgeTimer?.cancel();
    _purgeTimer = null;
    _noticeTimer?.cancel();
    _noticeTimer = null;
    _reportTimer?.cancel();
    _reportTimer = null;
    _keepScreenTimer?.cancel();
    _keepScreenTimer = null;
    _store.removeListener(_onStoreChanged);
    _groups.removeListener(_onGroupsChanged);
    _node?.removeListener(_onNodeChanged);
    _node?.dispose();
    super.dispose();
  }

  /// ノードの状態が変わった。新しくお知らせを受け取っていれば [_onReceived] に知らせる。
  void _onNodeChanged() {
    final t = _node?.lastReceivedAt;
    final report = _onReceived;
    if (t != null && t != _reportedReceivedAt) {
      _reportedReceivedAt = t;
      if (report != null) {
        unawaited(report(dateTimeFromEpoch(t)).catchError((Object e) {
          debugPrint('受信の通知に失敗: $e');
        }));
      }
    }
    notifyListeners();
  }

  void _onStoreChanged() {
    _syncGroupInfoFromStore();
    _checkNewNotices();
    _checkNewReports();
    notifyListeners();
  }

  void _onGroupsChanged() {
    _store.joinedGroupIds = _groups.codes;
    _store.officialGroupIds = _groups.officialCodes;
    // 参加した直後に見えるようになったお知らせは「新着」ではなく既知にする
    // （参加操作は前面でしか起きないので、ここでは通知にならない）。
    _checkNewNotices();
    _checkNewReports();
    notifyListeners();
  }

  /// 同期が完了した（C04 の交換完了音、C07 の最終同期時刻）。
  void _onSyncCompleted(int at, int sent, int received) {
    _settings.lastSyncAt = at;
    unawaited(_persistSettings());
    if (_settings.relayMode && _settings.chimeEnabled && (sent > 0 || received > 0)) {
      unawaited(_platform?.playChime());
    }
  }

  // ---------------------------------------------------------------------------
  // この端末から 渡した 台数（C18）
  // ---------------------------------------------------------------------------

  /// 台数を数えるお知らせか: 自分の投稿と、公式端末なら同じグループの公式投稿。
  bool _tracksHanded(StoredMessage m) {
    if (m.kind != MessageKind.notice) {
      return false;
    }
    if (m.isLocal) {
      return true;
    }
    return m.envelope.role == SenderRole.official &&
        (_groups.byCode(m.groupId)?.postRole ?? SenderRole.resident) ==
            SenderRole.official;
  }

  void _onHanded(String peerHex, List<int> sentIds, int at) {
    _handed.record(
      peerHex: peerHex,
      msgIds: sentIds,
      at: at,
      tracked: (id) {
        final m = _store.get(id);
        return m != null && _tracksHanded(m);
      },
    );
    unawaited(_persistHanded());
    notifyListeners();
  }

  /// [m] を この端末から 直接 渡した 台数。数える対象でなければ null。
  HandedInfo? handedOf(StoredMessage m) =>
      _tracksHanded(m) ? _handed.of(m.msgId) : null;

  /// これまでに この端末から 何かを 渡した 相手の 台数。
  int get handedDeviceCount => _handed.deviceCount;

  /// 最後に 渡した 時刻（エポック秒）と件数。まだなければ時刻は null。
  int? get lastHandedAt => _handed.lastAt;
  int get lastHandedCount => _handed.lastCount;

  Future<void> _loadHanded() async {
    final raw = await _kv.getString(handedKey);
    if (raw == null) {
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        _handed = HandedLog.fromJson(decoded);
      }
    } on Object catch (_) {
      // 壊れていたら数え直す。
    }
  }

  Future<void> _persistHanded() =>
      _kv.setString(handedKey, jsonEncode(_handed.toJson()));

  // ---------------------------------------------------------------------------
  // 新しいお知らせの OS 通知
  // ---------------------------------------------------------------------------

  /// アプリが前面かどうか。
  bool get inForeground => _foreground;

  /// UI 層（WidgetsBindingObserver）から前面／背面の切り替わりを知らせる。
  /// 前面に戻ったら、まとめ待ちの通知は出さない（画面の「新しい お知らせが N 件」に任せる）。
  void setForeground(bool inForeground) {
    if (_foreground == inForeground) {
      return;
    }
    _foreground = inForeground;
    if (inForeground) {
      _cancelPendingNotification();
      _settings.lastOpenedAt = _now();
      unawaited(_persistSettings());
      // 開くたびに確認通知を先送りする（14 日以上開かない端末にだけ届く、C07）。
      unawaited(_applyReminderSetting());
    } else if (_keepScreenOnUntil != null) {
      // 背面に行ったら「画面を 点けたままにする」は即解除する（C07）。
      unawaited(stopKeepScreenOn());
    }
  }

  void _cancelPendingNotification() {
    _noticeTimer?.cancel();
    _noticeTimer = null;
    _pendingNoticeIds.clear();
    _reportTimer?.cancel();
    _reportTimer = null;
    _pendingReportIds.clear();
  }

  /// 画面の帯で緊急のお知らせを見たことにする（C05）。
  void acknowledgeUrgent() {
    if (_foregroundUrgentIds.isEmpty) {
      return;
    }
    _foregroundUrgentIds.clear();
    notifyListeners();
  }

  /// このお知らせの通知の重要度（C05）。役割が公式・スタッフなら格上げする。
  NoticeImportance importanceOf(StoredMessage m, NoticeBody notice) {
    if (isTrainingTitle(notice.title)) {
      return NoticeImportance.normal;
    }
    final official = m.envelope.role != SenderRole.resident;
    final category = m.envelope.category;
    if (official && category.importance == NoticeImportance.urgent) {
      return NoticeImportance.urgent;
    }
    if (official || category.importance != NoticeImportance.normal) {
      return NoticeImportance.important;
    }
    return NoticeImportance.normal;
  }

  bool _shouldNotify(NoticeImportance importance) {
    switch (_settings.notificationLevel) {
      case NotificationLevel.off:
        return false;
      case NotificationLevel.all:
        return true;
      case NotificationLevel.important:
        return importance != NoticeImportance.normal;
    }
  }

  /// ストアの変化を見て、参加グループに新しく入った他人の未読 notice を集める。
  /// 前面のとき・通知オフのときも「見た」ことにして既知に加える（あとで通知しない）。
  void _checkNewNotices() {
    if (!_initialized) {
      return;
    }
    final visible = _store.visibleNotices(now: _now(), groupIds: _groups.codes);
    final fresh = <StoredMessage>[];
    for (final m in visible) {
      if (_knownNoticeIds.add(m.msgId) &&
          !m.isLocal &&
          !m.read &&
          !isTestEnvelope(m.envelope)) {
        fresh.add(m);
      }
    }
    // ストアから消えたものは忘れる（上限 3,000 件を超えて増えないように）。
    _knownNoticeIds.removeWhere((id) => !_store.contains(id));
    if (fresh.isEmpty) {
      return;
    }
    // 取り消された緊急通知を消す（C05）。
    _cancelRetractedUrgent();
    final urgent = <StoredMessage>[];
    final batched = <StoredMessage>[];
    for (final m in fresh) {
      final notice = m.envelope.notice;
      if (notice == null) {
        continue;
      }
      final importance = importanceOf(m, notice);
      if (importance == NoticeImportance.urgent) {
        urgent.add(m);
      } else if (_shouldNotify(importance)) {
        batched.add(m);
      }
    }
    if (urgent.isNotEmpty && _foreground) {
      _foregroundUrgentIds.addAll(urgent.map((m) => m.msgId));
    }
    if (_foreground || _platform == null) {
      return;
    }
    if (_settings.notificationLevel != NotificationLevel.off) {
      for (final m in urgent) {
        if (_urgentAllowed(m.groupId)) {
          _showUrgent(m);
        } else {
          batched.add(m);
        }
      }
    }
    if (batched.isEmpty) {
      return;
    }
    _pendingNoticeIds.addAll(batched.map((m) => m.msgId));
    // 続けて届く間は待ち、静かになってから 1 件の通知にまとめる。
    _noticeTimer?.cancel();
    _noticeTimer = (_createTimer ?? Timer.new)(
      kNoticeNotificationDebounce,
      _flushNoticeNotification,
    );
  }

  bool _urgentAllowed(int groupId) {
    final t = _now();
    final times = _urgentSentAt.putIfAbsent(groupId, () => <int>[]);
    times.removeWhere((s) => t - s > kUrgentWindowSeconds);
    if (times.length >= kUrgentPerGroupLimit) {
      return false;
    }
    times.add(t);
    return true;
  }

  static String _firstLine(String text, {int max = 30}) {
    final line = text.trim().split('\n').first.trim();
    if (line.runes.length <= max) {
      return line;
    }
    return '${String.fromCharCodes(line.runes.take(max))}…';
  }

  /// 通知の本文（場所と、種別によっては本文 1 行目、C05）。
  static String notificationBody(StoredMessage m, NoticeBody notice) {
    final parts = <String>[];
    if (notice.place.isNotEmpty) {
      parts.add('場所: ${notice.place}');
    }
    const withText = {
      NoticeCategory.evacuation,
      NoticeCategory.warning,
      NoticeCategory.shelter,
      NoticeCategory.water,
      NoticeCategory.food,
      NoticeCategory.supply,
    };
    if (withText.contains(m.envelope.category) && notice.text.trim().isNotEmpty) {
      parts.add(_firstLine(notice.text));
    }
    if (parts.isEmpty) {
      parts.add('${notice.senderName} から');
    }
    return parts.join(' ／ ');
  }

  void _showUrgent(StoredMessage m) {
    final platform = _platform;
    final notice = m.envelope.notice;
    if (platform == null || notice == null) {
      return;
    }
    final official = m.envelope.role == SenderRole.official;
    final prefix = !official
        ? ''
        : (m.envelope.category == NoticeCategory.evacuation ? '【避難】' : '【注意】');
    unawaited(
      platform
          .showNotice(
            id: m.msgId & 0x7FFFFFFF,
            title: '$prefix${notice.title}',
            body: notificationBody(m, notice),
            groupCode: m.groupId,
            importance: NoticeImportance.urgent,
            msgId: m.msgId,
          )
          .catchError((Object e) {
        debugPrint('通知を出せませんでした: $e');
      }),
    );
  }

  void _cancelRetractedUrgent() {
    final platform = _platform;
    if (platform == null) {
      return;
    }
    for (final m in _store.all) {
      if (m.kind == MessageKind.notice &&
          (m.retracted || m.supersededBy != null) &&
          m.envelope.role != SenderRole.resident &&
          m.envelope.category.importance == NoticeImportance.urgent &&
          _knownNoticeIds.contains(m.msgId) &&
          !_cancelledNoticeIds.contains(m.msgId)) {
        _cancelledNoticeIds.add(m.msgId);
        unawaited(platform.cancelNotice(m.msgId & 0x7FFFFFFF));
      }
    }
    _cancelledNoticeIds.removeWhere((id) => !_store.contains(id));
  }

  final Set<int> _cancelledNoticeIds = <int>{};

  /// まとめ待ちのお知らせを 1 件の OS 通知にして出す。
  void _flushNoticeNotification() {
    _noticeTimer = null;
    final platform = _platform;
    if (platform == null ||
        _foreground ||
        _settings.notificationLevel == NotificationLevel.off) {
      _pendingNoticeIds.clear();
      return;
    }
    final now = _now();
    final pending = <StoredMessage>[];
    for (final id in _pendingNoticeIds) {
      final m = _store.get(id);
      if (m != null &&
          !m.read &&
          _store.isDisplayable(m, now) &&
          _groups.codes.contains(m.groupId)) {
        pending.add(m);
      }
    }
    _pendingNoticeIds
      ..clear()
      ..addAll(pending.map((m) => m.msgId));
    if (pending.isEmpty) {
      return;
    }
    final newest = pending.last;
    final NoticeBody notice;
    try {
      notice = newest.envelope.notice!;
    } on Object catch (e) {
      debugPrint('通知の本文を読めません: $e');
      return;
    }
    final training = pending.where((m) {
      final n = m.envelope.notice;
      return n != null && isTrainingTitle(n.title);
    }).length;
    final String title;
    final String body;
    if (pending.length == 1) {
      title = notice.title;
      body = notificationBody(newest, notice);
    } else if (training == pending.length) {
      title = '$kTrainingPrefix新しい お知らせが ${pending.length}件';
      body = '${notice.title} ほか';
    } else if (training > 0) {
      title = '新しい お知らせが ${pending.length}件（うち 訓練 $training件）';
      body = '${notice.title} ほか';
    } else {
      title = '新しい お知らせが ${pending.length}件 あります';
      body = '${notice.title} ほか';
    }
    var importance = NoticeImportance.normal;
    for (final m in pending) {
      final n = m.envelope.notice;
      if (n == null) {
        continue;
      }
      final i = importanceOf(m, n);
      if (i.index > importance.index) {
        importance = i;
      }
    }
    if (importance == NoticeImportance.urgent) {
      // 10 分に 3 件を超えた分のまとめ通知は important で出す。
      importance = NoticeImportance.important;
    }
    // 通知 ID は最初に届いた msg_id の下位 31 ビット。続けて届いた分は同じ通知を更新する。
    final id = pending.first.msgId & 0x7FFFFFFF;
    unawaited(
      platform
          .showNotice(
            id: id,
            title: title,
            body: body,
            groupCode: newest.groupId,
            importance: importance,
            msgId: pending.length == 1 ? newest.msgId : null,
          )
          .catchError((Object e) {
        debugPrint('通知を出せませんでした: $e');
      }),
    );
  }

  // ---------------------------------------------------------------------------
  // 住民からの知らせ（SOS・安否・在宅避難・困りごと）の OS 通知
  // ---------------------------------------------------------------------------

  /// ストアの変化を見て、本部・スタッフとして見られる新しい知らせと、
  /// 自分の知らせへの「受け取りました」を通知する。前面のときは既知にするだけ
  /// （画面の帯と一覧に任せる）。
  void _checkNewReports() {
    if (!_initialized) {
      return;
    }
    final freshReports = <StoredMessage>[];
    final freshAcks = <StoredMessage>[];
    final now = _now();
    for (final m in _store.all) {
      if (m.kind != MessageKind.help && m.kind != MessageKind.ack) {
        continue;
      }
      if (_knownReportIds.contains(m.msgId)) {
        continue;
      }
      if (m.kind == MessageKind.help) {
        if (m.isLocal || !canSeeReports(m.groupId)) {
          // 見られない端末では保存・中継だけ。あとで本部になったら一覧には出る。
          continue;
        }
        _knownReportIds.add(m.msgId);
        if (_store.isDisplayable(m, now) &&
            !isTestEnvelope(m.envelope)) {
          freshReports.add(m);
        }
      } else {
        _knownReportIds.add(m.msgId);
        final target = m.envelope.supersedes;
        final t = target == null ? null : _store.get(target);
        if (!m.isLocal && t != null && t.isLocal && t.kind == MessageKind.help) {
          freshAcks.add(m);
        }
      }
    }
    _knownReportIds.removeWhere((id) => !_store.contains(id));
    if (freshReports.isEmpty && freshAcks.isEmpty) {
      return;
    }
    final platform = _platform;
    if (_foreground ||
        platform == null ||
        _settings.notificationLevel == NotificationLevel.off) {
      return;
    }
    for (final ack in freshAcks) {
      final report = _store.get(ack.envelope.supersedes!);
      final body = report?.envelope.help;
      unawaited(platform
          .showNotice(
            id: ack.msgId & 0x7FFFFFFF,
            title: '${ackSenderLabel(ack)}が 受け取りました',
            body: body?.title ?? '送った 知らせが 届きました',
            groupCode: ack.groupId,
            importance: NoticeImportance.important,
            msgId: report?.msgId,
          )
          .catchError((Object e) {
        debugPrint('通知を出せませんでした: $e');
      }));
    }
    final batched = <StoredMessage>[];
    for (final m in freshReports) {
      final entry = reportEntryOf(m);
      if (entry != null &&
          entry.info.type == ReportType.sos &&
          _urgentAllowed(m.groupId)) {
        unawaited(platform
            .showNotice(
              id: m.msgId & 0x7FFFFFFF,
              title: '住民から SOS が 届きました',
              body: reportNotificationBody(entry),
              groupCode: m.groupId,
              importance: NoticeImportance.urgent,
              msgId: m.msgId,
            )
            .catchError((Object e) {
          debugPrint('通知を出せませんでした: $e');
        }));
      } else {
        batched.add(m);
      }
    }
    if (batched.isEmpty) {
      return;
    }
    _pendingReportIds.addAll(batched.map((m) => m.msgId));
    _reportTimer?.cancel();
    _reportTimer = (_createTimer ?? Timer.new)(
      kNoticeNotificationDebounce,
      _flushReportNotification,
    );
  }

  /// 通知の本文（場所・人数・ひとこと）。
  static String reportNotificationBody(ReportEntry e) {
    final parts = <String>[];
    if (e.body.place.isNotEmpty) {
      parts.add('場所: ${e.body.place}');
    }
    final people = reportPeopleLabel(e.info.people);
    if (people.isNotEmpty) {
      parts.add(people);
    }
    if (e.body.text.trim().isNotEmpty) {
      parts.add(_firstLine(e.body.text));
    }
    if (parts.isEmpty) {
      parts.add(e.body.title);
    }
    return parts.join(' ／ ');
  }

  /// まとめ待ちの知らせを 1 件の OS 通知にして出す。
  void _flushReportNotification() {
    _reportTimer = null;
    final platform = _platform;
    if (platform == null ||
        _foreground ||
        _settings.notificationLevel == NotificationLevel.off) {
      _pendingReportIds.clear();
      return;
    }
    final now = _now();
    final entries = <ReportEntry>[];
    for (final id in _pendingReportIds) {
      final m = _store.get(id);
      if (m == null || !_store.isDisplayable(m, now)) {
        continue;
      }
      final e = reportEntryOf(m);
      if (e != null) {
        entries.add(e);
      }
    }
    final firstId = _pendingReportIds.isEmpty ? 0 : _pendingReportIds.first;
    _pendingReportIds.clear();
    if (entries.isEmpty) {
      return;
    }
    final newest = entries.last;
    final String title;
    final String body;
    if (entries.length == 1) {
      title = '住民から: ${newest.body.title}';
      body = reportNotificationBody(newest);
    } else {
      title = '住民からの 知らせが ${entries.length}件 届きました';
      body = ReportSummary.of(
              entries.map((e) => (info: e.info, acked: e.acked)))
          .line();
    }
    unawaited(platform
        .showNotice(
          id: firstId & 0x7FFFFFFF,
          title: title,
          body: body,
          groupCode: newest.groupId,
          importance: NoticeImportance.important,
          msgId: entries.length == 1 ? newest.msgId : null,
        )
        .catchError((Object e) {
      debugPrint('通知を出せませんでした: $e');
    }));
  }

  /// 参加グループの名前・ポリシー・拡張情報を、受け取った group_info から補完する。
  void _syncGroupInfoFromStore() {
    for (final g in _groups.groups) {
      if (g.isHost) {
        continue;
      }
      final latest = _store.latestGroupInfo(g.code);
      final info = latest?.envelope.groupInfo;
      if (info == null) {
        continue;
      }
      if (info.name.isNotEmpty && info.name != g.name) {
        unawaited(_groups.updateName(g.code, info.name));
      }
      final digest = info.codeDigest;
      final digestHex = digest != null ? hexOf(digest) : null;
      if (info.generation >= g.generation) {
        unawaited(_groups.updatePolicy(
          g.code,
          membersCanPost: info.membersCanPost,
          acceptsHelp: info.acceptsHelp,
          closed: info.closed,
          successor: info.successor,
          generation: info.generation,
          codeDigestHex: digestHex,
          description: info.description,
        ));
        if (digestHex != null) {
          unawaited(_groups.reverifyStaff(g.code));
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 設定
  // ---------------------------------------------------------------------------

  Future<void> _loadSettings() async {
    final raw = await _kv.getString(settingsKey);
    if (raw == null) {
      _settings = AppSettings();
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        _settings = AppSettings.fromJson(decoded);
        return;
      }
    } on FormatException {
      // 壊れていれば既定値。
    }
    _settings = AppSettings();
  }

  Future<void> _loadNodeId() async {
    final preset = _presetNodeId;
    if (preset != null) {
      _nodeId = Uint8List.fromList(preset);
      return;
    }
    final raw = await _kv.getString(nodeIdKey);
    if (raw != null) {
      try {
        final bytes = bytesFromHex(raw);
        if (bytes.length == kNodeIdLength) {
          _nodeId = bytes;
          return;
        }
      } on FormatException {
        // 作り直す。
      }
    }
    final id = generateNodeId();
    await _kv.setString(nodeIdKey, hexOf(id));
    _nodeId = id;
  }

  Future<void> _persistSettings() async {
    await _kv.setString(settingsKey, jsonEncode(_settings.toJson()));
    await _kv.setString(meshEnabledKey, _settings.meshEnabled.toString());
    final mirror = _onMeshEnabledChanged;
    if (mirror != null) {
      await mirror(_settings.meshEnabled);
    }
  }

  Future<void> saveSettings(AppSettings s) async {
    final previous = _settings;
    _settings = s.copy();
    if (_settings.notificationLevel == NotificationLevel.off) {
      _cancelPendingNotification();
    }
    await _persistSettings();
    final node = _node;
    if (node != null) {
      if (previous.relayMode != _settings.relayMode) {
        node.setRelayMode(_settings.relayMode);
        unawaited(_platform?.setKeepScreenOn(_settings.relayMode));
        if (_settings.relayMode) {
          _keepScreenTimer?.cancel();
          _keepScreenTimer = null;
          _keepScreenOnUntil = null;
        }
      }
      if (node.running) {
        final want = _effectiveLowPower;
        if (want != node.lowPower) {
          await node.setLowPower(want);
        }
      }
    }
    if (previous.notificationLevel != _settings.notificationLevel) {
      unawaited(_applyReminderSetting());
    }
    notifyListeners();
  }

  Future<void> _applyReminderSetting() async {
    final platform = _platform;
    if (platform == null) {
      return;
    }
    if (_settings.notificationLevel == NotificationLevel.off) {
      await platform.cancelMonthlyReminder();
    } else {
      await platform.scheduleMonthlyReminder(at: nextReminderAt(dateTimeFromEpoch(_now())));
    }
  }

  /// 次の確認通知の時刻: 今から 14 日以上あとの、最初の「1 日 午前 10 時」（C07）。
  static DateTime nextReminderAt(DateTime now) {
    final earliest = now.add(const Duration(days: 14));
    var year = earliest.year;
    var month = earliest.month;
    var candidate = DateTime(year, month, 1, 10);
    while (candidate.isBefore(earliest)) {
      month++;
      if (month > 12) {
        month = 1;
        year++;
      }
      candidate = DateTime(year, month, 1, 10);
    }
    return candidate;
  }

  // ---------------------------------------------------------------------------
  // 電池（C06）と画面点灯（C07）
  // ---------------------------------------------------------------------------

  /// 実際に適用する「長持ち」（中継役は常にふつう、充電中はふつう）。
  bool get _effectiveLowPower {
    if (_settings.relayMode) {
      return false;
    }
    return _settings.lowPowerPreferred || _autoLowPower;
  }

  /// 電池の状態を読み直し、R-25 の自動「長持ち」を判定する。
  Future<void> refreshBattery() async {
    final platform = _platform;
    if (platform == null) {
      return;
    }
    final BatteryInfo? info;
    try {
      info = await platform.getBattery();
    } on Object {
      return;
    }
    if (info == null) {
      return;
    }
    _battery = info;
    var auto = _autoLowPower;
    if (info.charging) {
      auto = false;
    } else if (info.level <= kLowBatteryPercent) {
      auto = true;
    } else if (info.level > kLowBatteryRecoverPercent) {
      auto = false;
    }
    if (auto != _autoLowPower) {
      _autoLowPower = auto;
      final node = _node;
      if (node != null && node.running) {
        final want = _effectiveLowPower;
        if (want != node.lowPower) {
          await node.setLowPower(want);
        }
      }
    }
    notifyListeners();
  }

  /// 30 分間、画面を消さない（C07）。
  Future<void> keepScreenOn() async {
    final platform = _platform;
    if (platform == null) {
      return;
    }
    await platform.setKeepScreenOn(true);
    _keepScreenOnUntil = _now() + kKeepScreenOnDuration.inSeconds;
    _keepScreenTimer?.cancel();
    _keepScreenTimer =
        (_createTimer ?? Timer.new)(kKeepScreenOnDuration, () {
      unawaited(stopKeepScreenOn());
    });
    notifyListeners();
  }

  /// 「画面を 点けたままにする」をやめる（中継役のときは画面点灯を続ける）。
  Future<void> stopKeepScreenOn() async {
    _keepScreenTimer?.cancel();
    _keepScreenTimer = null;
    if (_keepScreenOnUntil == null) {
      return;
    }
    _keepScreenOnUntil = null;
    if (!_settings.relayMode) {
      await _platform?.setKeepScreenOn(false);
    }
    notifyListeners();
  }

  /// 読み上げる（C19）。
  Future<void> speak(String text) async => _platform?.speak(text);

  Future<void> stopSpeaking() async => _platform?.stopSpeaking();

  // ---------------------------------------------------------------------------
  // 通信
  // ---------------------------------------------------------------------------

  Future<void> startMesh() async {
    _settings.meshEnabled = true;
    await _persistSettings();
    try {
      await node.start(lowPower: _effectiveLowPower);
    } on Object catch (e) {
      // 失敗しても設定は「開始したい」のまま残し、次回起動時に再試行する。
      debugPrint('通信の開始に失敗: $e');
    }
    notifyListeners();
  }

  Future<void> stopMesh() async {
    _settings.meshEnabled = false;
    await _persistSettings();
    await node.stop();
    notifyListeners();
  }

  Future<bool> requestPermissions() async =>
      await _platform?.requestPermissions() ?? true;

  Future<bool> requestBatteryExemption() async =>
      await _platform?.requestBatteryOptimizationExemption() ?? true;

  Future<void> openAppSettings() async => _platform?.openAppSettings();

  /// OS の通知権限を要求する。許可済み・不要な環境では true。
  Future<bool> requestNotificationPermission() async =>
      await _platform?.requestNotificationPermission() ?? true;

  // ---------------------------------------------------------------------------
  // 投稿
  // ---------------------------------------------------------------------------

  String get _displayName {
    final name = _settings.displayName.trim();
    return name.isEmpty ? kDefaultDisplayName : name;
  }

  /// [group] での発信元名（グループごとの名前 → 設定の表示名）。
  String senderNameFor(JoinedGroup group) {
    final own = group.senderName?.trim();
    if (own != null && own.isNotEmpty) {
      return own;
    }
    if (group.isHost) {
      final host = group.hostName?.trim();
      if (host != null && host.isNotEmpty) {
        return host;
      }
    }
    return _displayName;
  }

  /// お知らせを投稿する。投稿できないグループなら [StateError]。
  ///
  /// [supersedes] を渡すと「書きなおし」（元の msg_id を置き換える）。
  /// [training] なら見出しに「【訓練】」を付ける（公式・スタッフだけ、C23）。
  /// [asksReply] なら「返事の ボタン」（無事です・家に います・助けて）を付けた
  /// 安否確認にする（公式・スタッフだけ）。
  Future<Envelope> postNotice({
    required int groupCode,
    required NoticeCategory category,
    required String title,
    String place = '',
    String text = '',
    Duration? ttl,
    int? supersedes,
    bool training = false,
    bool asksReply = false,
  }) async {
    final group = _groups.byCode(groupCode);
    if (group == null) {
      throw StateError('参加していないグループです（$groupCode）');
    }
    if (!group.canPost) {
      throw StateError('このグループには投稿できません');
    }
    var cleanTitle = title.trim();
    if (cleanTitle.isEmpty) {
      throw ArgumentError.value(title, 'title', '見出しを入れてください');
    }
    if (training && group.postRole != SenderRole.resident &&
        !isTrainingTitle(cleanTitle)) {
      cleanTitle = '$kTrainingPrefix$cleanTitle';
    }
    final senderName = _truncateUtf8(senderNameFor(group), kMaxSenderNameBytes);
    final body = NoticeBody(
      senderName: senderName,
      title: cleanTitle,
      place: place.trim(),
      text: text,
      ext: asksReply && group.postRole != SenderRole.resident
          ? noticeExtAskingReply()
          : null,
    );
    var duration = ttl ?? category.defaultTtl;
    if (duration > kMaxNoticeTtl) {
      duration = kMaxNoticeTtl;
    }
    if (duration.inSeconds < 1) {
      duration = const Duration(seconds: 1);
    }
    final createdAt = _now();
    final expiresAt = _clampEpoch(createdAt + duration.inSeconds);
    final envelope = Envelope.create(
      kind: MessageKind.notice,
      groupId: groupCode,
      originId: nodeId,
      createdAt: createdAt,
      expiresAt: expiresAt,
      category: category,
      role: group.postRole,
      supersedes: supersedes,
      bodyPlain: body.encode(),
    );
    await node.publish(envelope);
    return envelope;
  }

  /// 自分のお知らせを書きなおす（supersedes 付きの notice を発信する、C01）。
  Future<Envelope> supersedeNotice(
    int msgId, {
    NoticeCategory? category,
    required String title,
    String place = '',
    String text = '',
    Duration? ttl,
  }) async {
    final target = _store.get(msgId);
    if (target == null) {
      throw StateError('お知らせが見つかりません');
    }
    if (!target.isLocal) {
      throw StateError('自分のお知らせだけ書きなおせます');
    }
    return postNotice(
      groupCode: target.groupId,
      category: category ?? target.envelope.category,
      title: title,
      place: place,
      text: text,
      ttl: ttl,
      supersedes: msgId,
      asksReply: noticeAsksReply(target.envelope.notice?.ext),
    );
  }

  /// 自分のお知らせを「終わりました」で置き換える（C01）。
  Future<Envelope> endNotice(int msgId) async {
    final target = _store.get(msgId);
    final notice = target?.envelope.notice;
    if (target == null || notice == null) {
      throw StateError('お知らせが見つかりません');
    }
    if (!target.isLocal) {
      throw StateError('自分のお知らせだけ終われます');
    }
    final category = target.envelope.category;
    final title = category.endTitle(
      place: notice.place,
      official: target.envelope.role == SenderRole.official,
    );
    final when = dateTimeFromEpoch(_now());
    final text = '（${_formatDateTime(when)}に 終わりました）';
    return postNotice(
      groupCode: target.groupId,
      category: category,
      title: _truncateUtf8(title, kMaxTitleBytes),
      place: notice.place,
      text: text,
      ttl: kEndNoticeTtl,
      supersedes: msgId,
    );
  }

  /// [msgId] を取り消せるか（本人、または同じグループの公式端末、C10）。
  bool canRetract(StoredMessage m) {
    if (m.isLocal) {
      return true;
    }
    final group = _groups.byCode(m.groupId);
    return group != null && group.postsAsOfficial;
  }

  /// お知らせを取り消す（tombstone を発信する）。本人か、同じグループの公式端末だけ。
  Future<void> retract(int msgId) async {
    final target = _store.get(msgId);
    if (target == null) {
      throw StateError('お知らせが見つかりません');
    }
    final group = _groups.byCode(target.groupId);
    if (!canRetract(target)) {
      throw StateError('自分のお知らせだけ取り消せます');
    }
    var role = group?.postRole ?? target.envelope.role;
    if (target.isLocal && target.envelope.role.code > role.code) {
      role = target.envelope.role;
    }
    final createdAt = _now();
    final expiresAt = _clampEpoch(
        _max(_store.localExpiresAt(target), createdAt) + kTombstoneGraceSeconds);
    final tombstone = Envelope.create(
      kind: MessageKind.tombstone,
      groupId: target.groupId,
      originId: nodeId,
      createdAt: createdAt,
      expiresAt: expiresAt,
      category: target.envelope.category,
      role: role,
      supersedes: msgId,
      bodyPlain: Uint8List(0),
    );
    await node.publish(tombstone);
  }

  /// 自分の訓練投稿（見出しが【訓練】で始まる）をすべて取り消す（C23）。
  /// 公式端末なら、そのグループの他人の訓練投稿も取り消す。
  Future<int> retractTraining(int groupCode) async {
    final group = _groups.byCode(groupCode);
    final official = group?.postsAsOfficial ?? false;
    final targets = _store
        .visibleNotices(now: _now(), groupIds: {groupCode})
        .where((m) {
      final n = m.envelope.notice;
      return n != null &&
          isTrainingTitle(n.title) &&
          (m.isLocal || official);
    }).toList();
    for (final m in targets) {
      await retract(m.msgId);
    }
    return targets.length;
  }

  // ---------------------------------------------------------------------------
  // 住民からの知らせ（SOS・無事です・在宅避難・困っています）
  // ---------------------------------------------------------------------------

  /// [groupCode] の知らせを見られるか（本部・スタッフの端末だけ、C21）。
  bool canSeeReports(int groupCode) {
    final g = _groups.byCode(groupCode);
    return g != null && (g.canManage || g.isStaff);
  }

  /// 知らせを見られるグループがあるか。
  bool get seesAnyReports => _groups.groups.any((g) => g.canManage || g.isStaff);

  /// ホームの「本部に 知らせる」から送れるグループ（「受け付ける」が オンで、
  /// 自分が本部・スタッフではないもの）。
  List<JoinedGroup> get reportGroups => _groups.groups
      .where((g) => g.acceptsHelp && !g.closed && !g.canManage && !g.isStaff)
      .toList();

  /// [m] が「返事を 求める」お知らせ（安否確認）か。
  static bool asksReply(StoredMessage m) =>
      noticeAsksReply(m.envelope.notice?.ext);

  /// [groupCode] に知らせを送れるか。[inReplyTo] が同じグループの安否確認なら、
  /// 「受け付ける」が オフでも送れる。
  bool canReportTo(int groupCode, {int? inReplyTo}) {
    final g = _groups.byCode(groupCode);
    if (g == null || g.closed) {
      return false;
    }
    if (g.acceptsHelp) {
      return true;
    }
    if (inReplyTo == null) {
      return false;
    }
    final request = _store.get(inReplyTo);
    return request != null &&
        request.groupId == groupCode &&
        asksReply(request) &&
        _store.isDisplayable(request, _now());
  }

  /// 知らせを送る（kind=help）。送れないグループなら [StateError]、
  /// 同じ種類を短い間に送り直そうとしたら [ReportTooSoonException]。
  Future<Envelope> sendReport({
    required int groupCode,
    required ReportType type,
    int people = 0,
    List<ReportNeed> needs = const <ReportNeed>[],
    bool injured = false,
    String place = '',
    String name = '',
    String note = '',
    int? inReplyTo,
  }) async {
    final group = _groups.byCode(groupCode);
    if (group == null) {
      throw StateError('参加していないグループです（$groupCode）');
    }
    if (!canReportTo(groupCode, inReplyTo: inReplyTo)) {
      throw StateError('この グループは 知らせを 受け付けて いません');
    }
    if (type.requiresNeeds && needs.isEmpty) {
      throw ArgumentError.value(needs, 'needs', '困っている ことを 選んでください');
    }
    final createdAt = _now();
    for (final m in _store.all) {
      if (!m.isLocal ||
          m.kind != MessageKind.help ||
          m.groupId != groupCode ||
          m.retracted) {
        continue;
      }
      final e = reportEntryOf(m);
      // 同じ種類・同じ返事先（別の安否確認への返事は別に数える）だけを止める。
      if (e == null || e.info.type != type || e.info.inReplyTo != inReplyTo) {
        continue;
      }
      if (createdAt - m.envelope.createdAt < type.resendInterval.inSeconds) {
        throw ReportTooSoonException(type, m.envelope.createdAt);
      }
    }
    final info = ReportInfo(
      type: type,
      people: people.clamp(0, kReportPeopleMax),
      needs: type.allowsNeeds ? needs : const <ReportNeed>[],
      injured: type.allowsInjured && injured,
      inReplyTo: inReplyTo,
    );
    final cleanName =
        type.allowsName ? truncateUtf8(name.trim(), kMaxSenderNameBytes) : '';
    final body = NoticeBody(
      senderName: cleanName,
      title: info.title(name: cleanName),
      place: truncateUtf8(place.trim(), kMaxPlaceBytes),
      text: truncateUtf8(note.trim(), 240),
      ext: info.encode(),
    );
    final envelope = Envelope.create(
      kind: MessageKind.help,
      groupId: groupCode,
      originId: nodeId,
      createdAt: createdAt,
      expiresAt: _clampEpoch(createdAt + type.ttl.inSeconds),
      category: NoticeCategory.request,
      role: group.postRole,
      bodyPlain: body.encode(),
    );
    await node.publish(envelope);
    return envelope;
  }

  /// 知らせ 1 件を画面用にまとめる。kind=help で読めなければ null。
  ReportEntry? reportEntryOf(StoredMessage m) {
    final body = m.envelope.help;
    if (body == null) {
      return null;
    }
    return ReportEntry(
      message: m,
      body: body,
      info: ReportInfo.decode(body.ext) ?? const ReportInfo(type: ReportType.need),
      ack: _store.ackFor(m.msgId),
    );
  }

  /// 本部・スタッフとして見られる知らせ（自分が送ったものは除く、新しい順）。
  /// [groupCode] でグループ、[inReplyTo] で安否確認への返事に絞る。
  List<ReportEntry> receivedReports({int? groupCode, int? inReplyTo}) {
    final ids = <int>{
      for (final g in _groups.groups)
        if ((g.canManage || g.isStaff) && (groupCode == null || g.code == groupCode))
          g.code,
    };
    if (ids.isEmpty) {
      return const [];
    }
    final out = <ReportEntry>[];
    for (final m in _store.visibleHelpRequests(now: _now(), groupIds: ids)) {
      if (m.isLocal) {
        continue;
      }
      final e = reportEntryOf(m);
      if (e == null) {
        continue;
      }
      if (inReplyTo != null && e.info.inReplyTo != inReplyTo) {
        continue;
      }
      out.add(e);
    }
    return out;
  }

  /// [entries] の集計。
  static ReportSummary summarize(Iterable<ReportEntry> entries) =>
      ReportSummary.of(entries.map((e) => (info: e.info, acked: e.acked)));

  /// まだ受け取りの返事をしていない SOS の件数（本部・スタッフの端末）。
  int get unackedSosCount => receivedReports()
      .where((e) => e.info.type == ReportType.sos && !e.acked)
      .length;

  /// 自分が送った知らせ（期限内・取り消していないもの、新しい順）。
  /// [inReplyTo] で安否確認への返事に絞る。
  List<ReportEntry> myReports({int? inReplyTo}) {
    final out = <ReportEntry>[];
    final now = _now();
    for (final m in _store.all) {
      if (!m.isLocal || m.kind != MessageKind.help || !_store.isDisplayable(m, now)) {
        continue;
      }
      final e = reportEntryOf(m);
      if (e == null) {
        continue;
      }
      if (inReplyTo != null && e.info.inReplyTo != inReplyTo) {
        continue;
      }
      out.add(e);
    }
    out.sort((a, b) => b.message.envelope.createdAt.compareTo(a.message.envelope.createdAt));
    return out;
  }

  /// 本部・スタッフが知らせに「受け取りました」を返す（kind=ack）。
  /// すでに返していれば何もしない（null を返す）。
  Future<Envelope?> acknowledgeReport(int msgId) async {
    final target = _store.get(msgId);
    if (target == null || target.kind != MessageKind.help) {
      throw StateError('知らせが 見つかりません');
    }
    final group = _groups.byCode(target.groupId);
    if (group == null || !(group.canManage || group.isStaff)) {
      throw StateError('本部・スタッフの 端末だけが 返事を できます');
    }
    if (_store.ackFor(msgId) != null) {
      return null;
    }
    final createdAt = _now();
    var expiresAt = _max(_store.localExpiresAt(target), createdAt) +
        kReportAckGrace.inSeconds;
    final cap = createdAt + kReportAckMaxTtl.inSeconds;
    if (expiresAt > cap) {
      expiresAt = cap;
    }
    final ack = Envelope.create(
      kind: MessageKind.ack,
      groupId: target.groupId,
      originId: nodeId,
      createdAt: createdAt,
      expiresAt: _clampEpoch(expiresAt),
      category: NoticeCategory.request,
      role: group.postRole,
      supersedes: msgId,
      bodyPlain: Uint8List(0),
    );
    await node.publish(ack);
    return ack;
  }

  /// まだ返事をしていない知らせに、まとめて「受け取りました」を返す。返した件数。
  Future<int> acknowledgeAll(Iterable<ReportEntry> entries) async {
    var n = 0;
    for (final e in entries) {
      if (e.acked) {
        continue;
      }
      if (await acknowledgeReport(e.msgId) != null) {
        n++;
      }
    }
    return n;
  }

  /// 「受け取りました」を出した人の呼び名（本部ならグループの発信者名、スタッフは「スタッフ」）。
  String ackSenderLabel(StoredMessage ack) {
    if (ack.envelope.role != SenderRole.official) {
      return ack.envelope.role == SenderRole.staff ? 'スタッフ' : '係の人';
    }
    final info = _store.latestGroupInfo(ack.groupId)?.envelope.groupInfo;
    final host = info?.hostName.trim() ?? '';
    if (host.isNotEmpty) {
      return host;
    }
    return '本部';
  }

  /// 知らせを文章にする（紙の台帳・無線で伝えるための写し）。
  String reportsAsText(List<ReportEntry> entries) {
    final lines = <String>[];
    for (final e in entries) {
      final t = dateTimeFromEpoch(e.message.receivedAt);
      final parts = <String>[
        _formatDateTime(t),
        e.body.title,
        if (e.body.place.isNotEmpty) '場所: ${e.body.place}',
        if (e.body.text.trim().isNotEmpty) e.body.text.trim(),
        e.acked ? '受け取り済み' : 'まだ 返事を していない',
        '番号 ${bulletinNumber(e.msgId)}',
      ];
      lines.add(parts.join(' ／ '));
    }
    return lines.join('\n');
  }

  // ---------------------------------------------------------------------------
  // グループ
  // ---------------------------------------------------------------------------

  /// グループを作り、group_info を発信する。
  Future<JoinedGroup> createGroup({
    required String name,
    required bool membersCanPost,
    String description = '',
    bool acceptsHelp = false,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(name, 'name', 'グループ名を入れてください');
    }
    final group = await _groups.create(
      name: _truncateUtf8(trimmed, kMaxGroupNameBytes),
      hostName: _truncateUtf8(_displayName, kMaxHostNameBytes),
      membersCanPost: membersCanPost,
      acceptsHelp: acceptsHelp,
      description: _truncateUtf8(description.trim(), kMaxDescriptionBytes),
    );
    _store.joinedGroupIds = _groups.codes;
    _store.officialGroupIds = _groups.officialCodes;
    await republishGroupInfo(group.code);
    return group;
  }

  /// 参加コードで参加する。近隣から受け取った group_info があれば名前を補完する。
  Future<JoinedGroup> joinGroup(int code) async {
    final info = _store.latestGroupInfo(code)?.envelope.groupInfo;
    final group = await _groups.join(code, name: info?.name);
    _store.joinedGroupIds = _groups.codes;
    if (info != null) {
      _syncGroupInfoFromStore();
    }
    notifyListeners();
    return group;
  }

  Future<void> leaveGroup(int code) async {
    await _groups.leave(code);
    _store.joinedGroupIds = _groups.codes;
    _store.officialGroupIds = _groups.officialCodes;
    notifyListeners();
  }

  /// 8 桁コードで昇格する（C09）。本部コードは受信済み group_info の
  /// code_digest と照合する。
  Future<ElevateResult> elevate(int code, String input) async {
    final info = _store.latestGroupInfo(code)?.envelope.groupInfo;
    final result =
        await _groups.elevate(code, input, knownDigest: info?.codeDigest);
    if (result == ElevateResult.hq || result == ElevateResult.staff) {
      _store.officialGroupIds = _groups.officialCodes;
      notifyListeners();
    }
    return result;
  }

  /// このグループでの発信元名（施設名・部署名）を設定する。
  Future<void> setGroupSenderName(int code, String name) =>
      _groups.setSenderName(code, name);

  /// 本部端末が「参加者も 投稿できる」を切り替えて group_info を再発信する。
  Future<void> setMembersCanPost(int code, bool v) async {
    final group = _groups.byCode(code);
    if (group == null || !group.canManage) {
      throw StateError('このグループの本部端末ではありません');
    }
    await _groups.updatePolicy(code, membersCanPost: v);
    await republishGroupInfo(code);
  }

  /// 本部端末が「困りごとを 受け付ける」を切り替えて group_info を再発信する（C21）。
  Future<void> setAcceptsHelp(int code, bool v) async {
    final group = _groups.byCode(code);
    if (group == null || !group.canManage) {
      throw StateError('このグループの本部端末ではありません');
    }
    await _groups.updatePolicy(code, acceptsHelp: v);
    await republishGroupInfo(code);
  }

  /// 本部端末が本部コード・スタッフコードを作り直し、group_info を再発信する（C24）。
  Future<JoinedGroup> regenerateCodes(int code) async {
    final group = await _groups.regenerateCodes(code);
    await republishGroupInfo(code);
    return group;
  }

  /// 本部端末が新しいグループを作って引っ越し、旧グループを閉鎖する（C24）。
  Future<JoinedGroup> moveGroup(int oldCode, {required String newName}) async {
    final old = _groups.byCode(oldCode);
    if (old == null || !old.canManage) {
      throw StateError('このグループの本部端末ではありません');
    }
    final fresh = await createGroup(
      name: newName,
      membersCanPost: old.membersCanPost,
      description: old.description,
      acceptsHelp: old.acceptsHelp,
    );
    await _groups.closeGroup(oldCode, successor: fresh.code);
    await republishGroupInfo(oldCode);
    return fresh;
  }

  /// ホスト・本部端末が group_info を再発信する（世代は現在値のまま）。
  Future<void> republishGroupInfo(int code) async {
    final group = _groups.byCode(code);
    if (group == null || !group.canManage) {
      throw StateError('このグループの本部端末ではありません');
    }
    Uint8List? digest;
    final hq = group.hqCode;
    final staff = group.staffCode;
    if (hq != null && staff != null) {
      digest = computeCodeDigest(hqCode: hq, staffCode: staff);
    } else {
      digest = group.codeDigest;
    }
    final body = GroupInfoBody(
      name: _truncateUtf8(group.name, kMaxGroupNameBytes),
      hostName: _truncateUtf8(
          group.isHost ? (group.hostName ?? _displayName) : group.name,
          kMaxHostNameBytes),
      membersCanPost: group.membersCanPost,
      description: _truncateUtf8(group.description, kMaxDescriptionBytes),
      closed: group.closed,
      acceptsHelp: group.acceptsHelp,
      codeDigest: digest,
      generation: group.generation,
      successor: group.successor,
    );
    final createdAt = _now();
    final envelope = Envelope.create(
      kind: MessageKind.groupInfo,
      groupId: code,
      originId: nodeId,
      createdAt: createdAt,
      expiresAt: _clampEpoch(createdAt + kGroupInfoTtl.inSeconds),
      category: NoticeCategory.general,
      role: SenderRole.official,
      bodyPlain: body.encode(),
    );
    await node.publish(envelope);
  }

  /// 近くで流れている（未参加の）グループ（C22）。
  List<StoredMessage> nearbyGroupInfos({int limit = 3}) =>
      _store.unjoinedGroupInfos(now: _now(), limit: limit);

  // ---------------------------------------------------------------------------
  // 表示
  // ---------------------------------------------------------------------------

  /// 参加グループのお知らせ（[groupCode] 指定でそのグループだけ）。
  /// 既定は届いた時刻の新しい順（C12）。
  List<StoredMessage> notices({int? groupCode, bool byReceived = true}) {
    final ids = groupCode != null ? {groupCode} : _groups.codes;
    return _store.visibleNotices(
        now: _now(), groupIds: ids, byReceived: byReceived);
  }

  /// いま出ている公式の避難情報・注意喚起（固定枠用、新しい順に最大 3 件、C03）。
  List<StoredMessage> pinnedAlerts({int? groupCode, int limit = 3}) {
    final list = notices(groupCode: groupCode, byReceived: false).where((m) {
      if (m.envelope.role != SenderRole.official) {
        return false;
      }
      if (m.envelope.category.importance != NoticeImportance.urgent) {
        return false;
      }
      final n = m.envelope.notice;
      return n != null && !isTrainingTitle(n.title);
    }).toList();
    return list.length > limit ? list.sublist(0, limit) : list;
  }

  int get unreadCount =>
      _store.unreadCount(now: _now(), groupIds: _groups.codes);

  /// 訓練投稿の未読件数（C23）。
  int get unreadTrainingCount => notices().where((m) {
        final n = m.envelope.notice;
        return !m.read && n != null && isTrainingTitle(n.title);
      }).length;

  Future<void> markRead(int msgId) => _store.markRead(msgId);

  /// 一覧に表示した未読をすべて既読にする（C03）。
  Future<void> markVisibleRead({int? groupCode}) async {
    final ids = notices(groupCode: groupCode)
        .where((m) => !m.read)
        .map((m) => m.msgId)
        .toSet();
    if (ids.isNotEmpty) {
      await _store.markAllRead(ids);
    }
  }

  /// 掲示番号（msg_id の下位 20 ビットを 10 進 6 桁、紙との突き合わせ用、C19）。
  static String bulletinNumber(int msgId) =>
      (msgId & 0xFFFFF).toString().padLeft(6, '0');

  // ---------------------------------------------------------------------------
  // 開発者メニュー（実機テスト用のデータ、#152）
  // ---------------------------------------------------------------------------

  /// 開発者メニューを出す／隠す。
  Future<void> setDeveloperMode(bool v) async {
    if (_settings.developerMode == v) {
      return;
    }
    _settings.developerMode = v;
    await _persistSettings();
    notifyListeners();
  }

  /// この端末にあるテスト用データ（発信元が "TEST"）の件数。
  int get testDataCount =>
      _store.all.where((m) => isTestEnvelope(m.envelope)).length;

  /// テスト用のお知らせを [count] 件入れる（TD1〜TD3）。受け取ったものとして
  /// 保存し（自分の投稿扱いにしない）、既読にする。入った件数を返す。
  Future<int> addTestNotices({
    required int groupCode,
    required int count,
    TestBody body = TestBody.plain,
  }) {
    final now = _now();
    return _addTestData(makeTestNotices(
      count: count,
      groupId: groupCode,
      now: now,
      random: Random(),
      body: body,
      startIndex: testDataCount + 1,
    ));
  }

  /// 保存の上限（3,000 件）まで、ばらばらの文字のお知らせで埋める（TD4）。
  Future<int> fillTestNotices({required int groupCode}) {
    final room = _store.maxMessages - _store.count;
    if (room <= 0) {
      return Future<int>.value(0);
    }
    return addTestNotices(
        groupCode: groupCode, count: room, body: TestBody.noise);
  }

  /// テスト用の住民からの知らせを [count] 件入れる（TD5 の「無事です 100 件」など）。
  Future<int> addTestReports({
    required int groupCode,
    required int count,
    ReportType type = ReportType.safe,
  }) {
    return _addTestData(makeTestReports(
      count: count,
      groupId: groupCode,
      now: _now(),
      random: Random(),
      type: type,
    ));
  }

  Future<int> _addTestData(List<Envelope> envelopes) async {
    final added = await _store.addAll(envelopes, now: _now());
    await _store.markAllRead({for (final e in envelopes) e.msgId});
    _node?.nudge();
    return added;
  }

  /// テスト用データをこの端末から消す（ほかの端末には残る）。消した件数を返す。
  Future<int> removeTestData() =>
      _store.removeWhere((m) => isTestEnvelope(m.envelope));

  // ---------------------------------------------------------------------------
  // 補助
  // ---------------------------------------------------------------------------

  static int _max(int a, int b) => a > b ? a : b;

  static int _clampEpoch(int v) =>
      v < 0 ? 0 : (v > kMaxEpochSeconds ? kMaxEpochSeconds : v);

  static String _formatDateTime(DateTime t) {
    final ampm = t.hour < 12 ? '午前' : '午後';
    final hour = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final minute = t.minute.toString().padLeft(2, '0');
    return '${t.month}月${t.day}日 $ampm$hour時$minute分';
  }

  /// UTF-8 で [maxBytes] 以内に収まるよう末尾を切り詰める（文字の途中では切らない）。
  static String _truncateUtf8(String s, int maxBytes) {
    if (utf8.encode(s).length <= maxBytes) {
      return s;
    }
    final out = StringBuffer();
    var bytes = 0;
    for (final rune in s.runes) {
      final n = utf8.encode(String.fromCharCode(rune)).length;
      if (bytes + n > maxBytes) {
        break;
      }
      out.writeCharCode(rune);
      bytes += n;
    }
    return out.toString();
  }
}
