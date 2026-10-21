/// 参加グループと発信者権限の管理。
///
/// v2（docs/08 C09 / C24）: 8 桁コードは「本部コード（先頭 1）」と
/// 「スタッフコード（先頭 2）」の 2 本。本部コードで昇格した端末は公式
/// （ホストと同等）、スタッフコードで昇格した端末はスタッフ（投稿権のみ）。
/// 本部昇格は group_info の code_digest と一致したときだけ受理する。
///
/// 永続化は [KeyValueStore] の 1 キー（JSON）にまとめる。
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/envelope.dart' show SenderRole;
import '../core/ids.dart';

/// 文字列のキー・バリュー保存（shared_preferences の薄い抽象）。
abstract class KeyValueStore {
  Future<String?> getString(String key);
  Future<void> setString(String key, String value);
  Future<void> remove(String key);
}

/// テスト用のインメモリ実装。
class MemoryKeyValueStore implements KeyValueStore {
  final Map<String, String> _map = <String, String>{};

  /// 現在の内容（複製）。
  Map<String, String> get snapshot => Map.unmodifiable(_map);

  @override
  Future<String?> getString(String key) async => _map[key];

  @override
  Future<void> setString(String key, String value) async {
    _map[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    _map.remove(key);
  }
}

/// 8 桁コードによる昇格の結果。
enum ElevateResult {
  /// 本部コードが一致し、公式（本部端末）になった。
  hq,

  /// スタッフコードを受理し、スタッフになった。
  staff,

  /// 番号がちがう。
  mismatch,

  /// 本部コードの検証に必要な group_info がまだ届いていない。
  notReady,

  /// 8 桁の数字でない、または先頭桁が 1 / 2 でない。
  invalid,

  /// そのグループに参加していない。
  notJoined,
}

/// 参加しているグループ 1 つ。
class JoinedGroup {
  JoinedGroup({
    required this.code,
    required this.name,
    required this.isHost,
    this.isOfficial = false,
    this.isStaff = false,
    this.membersCanPost = true,
    this.hqCode,
    this.staffCode,
    this.hostName,
    this.senderName,
    this.acceptsHelp = false,
    this.closed = false,
    this.successor = 0,
    this.generation = 0,
    this.codeDigestHex,
    this.description = '',
  });

  /// 説明・問い合わせ先（group_info の description、≤ 300 バイト）。
  String description;

  /// 6 桁の参加コード（= group_id）。
  final int code;

  /// グループ名（近隣から group_info を受け取ると補完される）。
  String name;

  /// この端末が作成したグループか。
  final bool isHost;

  /// 本部コードで公式（本部端末）に昇格済みか。
  bool isOfficial;

  /// スタッフコードでスタッフに昇格済みか。
  bool isStaff;

  /// 参加者も投稿できるか（group_info の policy bit0）。
  bool membersCanPost;

  /// 本部コード（8 桁、先頭 1）。ホストと本部端末が持つ。
  String? hqCode;

  /// スタッフコード（8 桁、先頭 2）。ホストが配布用に持つ。
  /// スタッフ端末では昇格時に入力した値。
  String? staffCode;

  /// ホストの表示名（ホスト端末のみ。group_info の再発信に使う）。
  String? hostName;

  /// このグループでの発信元名（施設名・部署名）。null なら設定の表示名。
  String? senderName;

  /// 困りごとを受け付けるか（policy bit2、C21）。
  bool acceptsHelp;

  /// 閉鎖済み（引っ越し済み、policy bit1、C24）。
  bool closed;

  /// 後継の参加コード（0 = なし、C24）。
  int successor;

  /// group_info の世代（C24）。
  int generation;

  /// 受け取った code_digest（16 進）。本部昇格の検証に使う。
  String? codeDigestHex;

  /// このグループに投稿できるか。
  bool get canPost => isHost || isOfficial || isStaff || membersCanPost;

  /// 旧名。本部コード。
  String? get officialCode => hqCode;

  /// 投稿時の役割が公式か（ホストまたは本部コードで昇格済み）。
  bool get postsAsOfficial => isHost || isOfficial;

  /// グループの設定（再発信・投稿方針・コード作り直し）を扱えるか。
  bool get canManage => isHost || isOfficial;

  /// 投稿時の役割。
  SenderRole get postRole {
    if (postsAsOfficial) {
      return SenderRole.official;
    }
    if (isStaff) {
      return SenderRole.staff;
    }
    return SenderRole.resident;
  }

  /// 受け取った code_digest（バイト列）。なければ null。
  Uint8List? get codeDigest {
    final hex = codeDigestHex;
    if (hex == null) {
      return null;
    }
    try {
      final bytes = bytesFromHex(hex);
      return bytes.length == 8 ? bytes : null;
    } on FormatException {
      return null;
    }
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'code': code,
        'name': name,
        'isHost': isHost,
        'isOfficial': isOfficial,
        'isStaff': isStaff,
        'membersCanPost': membersCanPost,
        'hqCode': hqCode,
        'staffCode': staffCode,
        'hostName': hostName,
        'senderName': senderName,
        'acceptsHelp': acceptsHelp,
        'closed': closed,
        'successor': successor,
        'generation': generation,
        'codeDigestHex': codeDigestHex,
        'description': description,
      };

  static JoinedGroup fromJson(Map<String, Object?> json) {
    final code = json['code'];
    if (code is! int || code < 0 || code > 999999) {
      throw const FormatException('code が不正です');
    }
    return JoinedGroup(
      code: code,
      name: (json['name'] as String?) ?? '',
      isHost: (json['isHost'] as bool?) ?? false,
      isOfficial: (json['isOfficial'] as bool?) ?? false,
      isStaff: (json['isStaff'] as bool?) ?? false,
      membersCanPost: (json['membersCanPost'] as bool?) ?? true,
      // v1 の officialCode は本部コードとして引き継ぐ。
      hqCode: (json['hqCode'] as String?) ?? (json['officialCode'] as String?),
      staffCode: json['staffCode'] as String?,
      hostName: json['hostName'] as String?,
      senderName: json['senderName'] as String?,
      acceptsHelp: (json['acceptsHelp'] as bool?) ?? false,
      closed: (json['closed'] as bool?) ?? false,
      successor: (json['successor'] as int?) ?? 0,
      generation: (json['generation'] as int?) ?? 0,
      codeDigestHex: json['codeDigestHex'] as String?,
      description: (json['description'] as String?) ?? '',
    );
  }

  @override
  String toString() =>
      'JoinedGroup(code: $code, name: $name, isHost: $isHost, '
      'isOfficial: $isOfficial, isStaff: $isStaff, '
      'membersCanPost: $membersCanPost, generation: $generation)';
}

/// 参加グループの管理。
class GroupManager extends ChangeNotifier {
  GroupManager(this._kv, {this._random});

  /// 永続化キー。
  static const String storageKey = 'groups.v1';

  final KeyValueStore _kv;
  final Random? _random;
  final List<JoinedGroup> _groups = <JoinedGroup>[];
  bool _loaded = false;

  bool get isLoaded => _loaded;

  /// 参加中のグループ（参加順）。
  List<JoinedGroup> get groups => List.unmodifiable(_groups);

  /// 参加中のグループ ID の集合。
  Set<int> get codes => {for (final g in _groups) g.code};

  /// この端末が公式（ホストまたは本部端末）であるグループ ID の集合。
  Set<int> get officialCodes =>
      {for (final g in _groups) if (g.postsAsOfficial) g.code};

  JoinedGroup? byCode(int code) {
    for (final g in _groups) {
      if (g.code == code) {
        return g;
      }
    }
    return null;
  }

  Future<void> load() async {
    _groups.clear();
    final raw = await _kv.getString(storageKey);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, Object?>) {
          final list = decoded['groups'];
          if (list is List) {
            for (final item in list) {
              if (item is Map<String, Object?>) {
                try {
                  final g = JoinedGroup.fromJson(item);
                  if (byCode(g.code) == null) {
                    _groups.add(g);
                  }
                } on FormatException {
                  // 壊れた項目は読み飛ばす。
                }
              }
            }
          }
        }
      } on FormatException {
        // JSON 全体が壊れている場合は空から始める。
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _save() async {
    final json = jsonEncode(<String, Object?>{
      'groups': [for (final g in _groups) g.toJson()],
    });
    await _kv.setString(storageKey, json);
    notifyListeners();
  }

  /// グループを作る。6 桁の参加コードと、本部コード・スタッフコード（8 桁）を発行する。
  Future<JoinedGroup> create({
    required String name,
    required String hostName,
    required bool membersCanPost,
    bool acceptsHelp = false,
    String description = '',
  }) async {
    var code = generateGroupCode(_random);
    while (byCode(code) != null) {
      code = generateGroupCode(_random);
    }
    final group = JoinedGroup(
      code: code,
      name: name,
      isHost: true,
      isOfficial: true,
      membersCanPost: membersCanPost,
      acceptsHelp: acceptsHelp,
      hqCode: generateHqCode(_random),
      staffCode: generateStaffCode(_random),
      hostName: hostName,
      senderName: name,
      description: description,
    );
    _groups.add(group);
    await _save();
    return group;
  }

  /// 参加コードでグループに参加する。既に参加済みならそれを返す
  /// （[name] が与えられ、未設定なら補完する）。
  Future<JoinedGroup> join(int code, {String? name}) async {
    if (code < 0 || code > 999999) {
      throw ArgumentError.value(code, 'code', '参加コードは 6 桁の数字です');
    }
    final existing = byCode(code);
    if (existing != null) {
      if (name != null && name.isNotEmpty && existing.name.isEmpty) {
        existing.name = name;
        await _save();
      }
      return existing;
    }
    final group = JoinedGroup(
      code: code,
      name: name ?? '',
      isHost: false,
    );
    _groups.add(group);
    await _save();
    return group;
  }

  Future<void> leave(int code) async {
    final before = _groups.length;
    _groups.removeWhere((g) => g.code == code);
    if (_groups.length != before) {
      await _save();
    }
  }

  /// 8 桁コードで昇格する。
  ///
  /// - 先頭 1（本部コード）: ホスト端末は自分のコードと比較する。参加者端末は
  ///   受信済み group_info の code_digest（[knownDigest]、なければグループに
  ///   保存済みのもの）と一致したときだけ公式にする。未受信なら [ElevateResult.notReady]。
  /// - 先頭 2（スタッフコード）: ダイジェストがあれば照合し、なければ受理する
  ///   （role=1 と投稿権だけなので、後で group_info が届いたら再検証する）。
  Future<ElevateResult> elevate(int code, String input,
      {Uint8List? knownDigest}) async {
    final group = byCode(code);
    if (group == null) {
      return ElevateResult.notJoined;
    }
    final normalized = normalizeEightDigitCode(input);
    if (normalized == null) {
      return ElevateResult.invalid;
    }
    final digest = knownDigest ?? group.codeDigest;
    final hq = isHqCode(normalized);
    if (hq == null) {
      // v1 のコード（先頭桁が任意）はホスト端末の本部コードとだけ照合する。
      if (group.hqCode != null && group.hqCode == normalized) {
        return _promote(group, hq: true, code: normalized);
      }
      return ElevateResult.invalid;
    }
    if (hq) {
      final own = group.hqCode;
      if (own != null) {
        if (own != normalized) {
          return ElevateResult.mismatch;
        }
        return _promote(group, hq: true, code: normalized);
      }
      if (digest == null) {
        return ElevateResult.notReady;
      }
      if (!codeMatchesDigest(normalized, digest, hq: true)) {
        return ElevateResult.mismatch;
      }
      return _promote(group, hq: true, code: normalized);
    }
    final ownStaff = group.staffCode;
    if (ownStaff != null && group.isHost && ownStaff != normalized) {
      return ElevateResult.mismatch;
    }
    if (digest != null && !codeMatchesDigest(normalized, digest, hq: false)) {
      return ElevateResult.mismatch;
    }
    return _promote(group, hq: false, code: normalized);
  }

  Future<ElevateResult> _promote(JoinedGroup group,
      {required bool hq, required String code}) async {
    if (hq) {
      group.isOfficial = true;
      group.hqCode ??= code;
    } else {
      group.isStaff = true;
      group.staffCode ??= code;
    }
    await _save();
    return hq ? ElevateResult.hq : ElevateResult.staff;
  }

  /// 受信した group_info の code_digest でスタッフ昇格を再検証する。
  /// 一致しなければスタッフ権限を外す。
  Future<void> reverifyStaff(int code) async {
    final group = byCode(code);
    final digest = group?.codeDigest;
    final staff = group?.staffCode;
    if (group == null || digest == null || staff == null || !group.isStaff) {
      return;
    }
    if (!codeMatchesDigest(staff, digest, hq: false)) {
      group.isStaff = false;
      await _save();
    }
  }

  /// このグループでの発信元名を設定する。
  Future<void> setSenderName(int code, String name) async {
    final group = byCode(code);
    if (group == null) {
      return;
    }
    final trimmed = name.trim();
    final value = trimmed.isEmpty ? null : trimmed;
    if (group.senderName == value) {
      return;
    }
    group.senderName = value;
    await _save();
  }

  Future<void> updateName(int code, String name) async {
    final group = byCode(code);
    if (group == null || group.name == name) {
      return;
    }
    group.name = name;
    await _save();
  }

  /// group_info から得た投稿ポリシー・拡張情報を反映する。
  Future<void> updatePolicy(
    int code, {
    bool? membersCanPost,
    bool? acceptsHelp,
    bool? closed,
    int? successor,
    int? generation,
    String? codeDigestHex,
    String? description,
  }) async {
    final group = byCode(code);
    if (group == null) {
      return;
    }
    var changed = false;
    if (description != null && group.description != description) {
      group.description = description;
      changed = true;
    }
    if (membersCanPost != null && group.membersCanPost != membersCanPost) {
      group.membersCanPost = membersCanPost;
      changed = true;
    }
    if (acceptsHelp != null && group.acceptsHelp != acceptsHelp) {
      group.acceptsHelp = acceptsHelp;
      changed = true;
    }
    if (closed != null && group.closed != closed) {
      group.closed = closed;
      changed = true;
    }
    if (successor != null && group.successor != successor) {
      group.successor = successor;
      changed = true;
    }
    if (generation != null && group.generation != generation) {
      group.generation = generation;
      changed = true;
    }
    if (codeDigestHex != null && group.codeDigestHex != codeDigestHex) {
      group.codeDigestHex = codeDigestHex;
      changed = true;
    }
    if (changed) {
      await _save();
    }
  }

  /// 本部端末が本部コード・スタッフコードを作り直す（世代 +1）。
  /// 以後の新規昇格にだけ効き、既に昇格した端末は残る。
  Future<JoinedGroup> regenerateCodes(int code) async {
    final group = byCode(code);
    if (group == null || !group.canManage) {
      throw StateError('このグループの本部端末ではありません');
    }
    group
      ..hqCode = generateHqCode(_random)
      ..staffCode = generateStaffCode(_random)
      ..generation = (group.generation + 1).clamp(0, 0xFFFF);
    await _save();
    return group;
  }

  /// 本部端末がグループを閉鎖し、後継の参加コードを示す（世代 +1）。
  Future<void> closeGroup(int code, {required int successor}) async {
    final group = byCode(code);
    if (group == null || !group.canManage) {
      throw StateError('このグループの本部端末ではありません');
    }
    group
      ..closed = true
      ..successor = successor
      ..generation = (group.generation + 1).clamp(0, 0xFFFF);
    await _save();
  }
}
