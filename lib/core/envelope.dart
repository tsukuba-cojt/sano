/// メッセージ封筒（Envelope）のエンコード・デコード・検証。
///
/// バイト配置は docs/02_protocol.md §2 に従う（リトルエンディアン）。
/// v2 では受信側の検証を「中継できる条件」と「表示できる条件」の 2 段に分け、
/// 未知の version / kind / flags の封筒も生バイトのまま保存・中継できる
/// （不透明メッセージ、docs/08 C13）。ヘッダ offset 0〜27 の位置と意味は
/// 将来版でも変えない。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

import 'categories.dart';
import 'compression.dart';

/// 封筒の先頭バイト（'K'）。
const int kEnvelopeMagic = 0x4B;

/// プロトコルバージョン。
const int kProtocolVersion = 1;

/// 固定ヘッダ長（supersedes なし）。
const int kEnvelopeHeaderLength = 28;

/// supersedes フィールドの長さ。
const int kSupersedesLength = 8;

/// msg_id の長さ。
const int kMsgIdLength = 8;

/// 発信元ノード ID の長さ。
const int kOriginIdLength = 8;

/// group_id の上限（6 桁の参加コード）。
const int kMaxGroupId = 999999;

/// hop の上限（uint8）。
const int kMaxHopValue = 255;

/// flags bit0: body が deflate + 辞書で圧縮されている。
const int kFlagCompressed = 0x01;

/// flags bit1: supersedes フィールドあり。
const int kFlagSupersedes = 0x02;

/// flags の予約ビット（立っていれば不透明メッセージとして扱う）。
const int kFlagsReservedMask = 0xFC;

/// 有効期間（expires_at − created_at）の上限（30 日）。超過は受信側で破棄する（C12）。
const int kMaxTtlSeconds = 30 * 24 * 60 * 60;

/// notice body の各フィールド長上限（UTF-8 バイト）。
const int kMaxSenderNameBytes = 48;
const int kMaxTitleBytes = 120;
const int kMaxPlaceBytes = 120;
const int kMaxTextBytes = 3000;

/// group_info body の各フィールド長上限（UTF-8 バイト）。
const int kMaxGroupNameBytes = 60;
const int kMaxHostNameBytes = 48;
const int kMaxDescriptionBytes = 300;

/// group_info の policy バイト bit0: 参加者も投稿可。
const int kPolicyMembersCanPost = 0x01;

/// group_info の policy バイト bit1: 閉鎖（引っ越し済み、C24）。
const int kPolicyClosed = 0x02;

/// group_info の policy バイト bit2: 困りごとを受け付ける（C21）。
const int kPolicyAcceptsHelp = 0x04;

/// group_info ext の code_digest 長（本部コード 4 B ‖ スタッフコード 4 B）。
const int kCodeDigestLength = 8;

/// group_info ext の内容長（digest 8 ‖ generation u16 ‖ successor uint24）。
const int kGroupInfoExtLength = kCodeDigestLength + 2 + 3;

/// メッセージの種類。[code] がワイヤ上の値。
enum MessageKind {
  /// お知らせ
  notice(0),

  /// グループ情報
  groupInfo(1),

  /// 取り消し
  tombstone(2),

  /// 困りごと（住民 → 運営、C21）
  help(3),

  /// 受け取りました（運営 → 住民、C21）
  ack(4),

  /// 未知の種類（不透明メッセージ。ワイヤには載せない）
  unknown(0xFF);

  const MessageKind(this.code);

  /// ワイヤ上のコード。
  final int code;

  /// コードから種類を得る。未知なら null。
  static MessageKind? fromCode(int code) {
    for (final k in values) {
      if (k != unknown && k.code == code) {
        return k;
      }
    }
    return null;
  }
}

/// 発信者の役割。宣言順がワイヤ上のコード。
enum SenderRole {
  /// 住民
  resident('住民'),

  /// スタッフ
  staff('スタッフ'),

  /// 公式（発信者）
  official('公式');

  const SenderRole(this.label);

  /// 画面に表示する日本語ラベル。
  final String label;

  /// ワイヤ上のコード（0..2）。
  int get code => index;

  /// コードから役割を得る。範囲外は null。
  static SenderRole? fromCode(int code) {
    if (code < 0 || code >= values.length) {
      return null;
    }
    return values[code];
  }
}

/// 封筒・body の形式が不正なときに投げる例外。
class EnvelopeFormatException implements Exception {
  const EnvelopeFormatException(this.message);

  final String message;

  @override
  String toString() => 'EnvelopeFormatException: $message';
}

// ---------------------------------------------------------------------------
// u16 len + バイト列 の連結形式（notice / group_info の body）
// ---------------------------------------------------------------------------

/// `u16 len + bytes` フィールドを順に書き出す。
class _FieldWriter {
  final BytesBuilder _out = BytesBuilder(copy: false);

  void addString(String value, {required int maxBytes, required String name}) {
    addBytes(
      Uint8List.fromList(utf8.encode(value)),
      maxBytes: maxBytes,
      name: name,
    );
  }

  void addBytes(Uint8List value, {required int maxBytes, required String name}) {
    if (value.length > maxBytes) {
      throw EnvelopeFormatException(
        '$name が長すぎます（${value.length} バイト、上限 $maxBytes バイト）',
      );
    }
    final len = Uint8List(2);
    ByteData.sublistView(len).setUint16(0, value.length, Endian.little);
    _out
      ..add(len)
      ..add(value);
  }

  Uint8List takeBytes() => _out.takeBytes();
}

/// `u16 len + bytes` フィールドを順に読み取る。入力は信用しない。
/// 末尾の余分なフィールドは将来の拡張として無視する（C13）。
class _FieldReader {
  _FieldReader(this._bytes);

  final Uint8List _bytes;
  int _offset = 0;

  /// 次のフィールドがあるか。
  bool get hasMore => _bytes.length - _offset >= 2;

  Uint8List readBytes({required int maxBytes, required String name}) {
    if (_bytes.length - _offset < 2) {
      throw EnvelopeFormatException('$name の長さフィールドがありません');
    }
    final len = _bytes[_offset] | (_bytes[_offset + 1] << 8);
    _offset += 2;
    if (len > maxBytes) {
      throw EnvelopeFormatException(
        '$name が長すぎます（$len バイト、上限 $maxBytes バイト）',
      );
    }
    if (_bytes.length - _offset < len) {
      throw EnvelopeFormatException('$name の内容が途中で切れています');
    }
    final value = Uint8List.sublistView(_bytes, _offset, _offset + len);
    _offset += len;
    return value;
  }

  String readString({required int maxBytes, required String name}) {
    final raw = readBytes(maxBytes: maxBytes, name: name);
    try {
      return utf8.decode(raw);
    } on FormatException {
      throw EnvelopeFormatException('$name が UTF-8 として不正です');
    }
  }
}

/// お知らせ（kind=notice / help）の body。
class NoticeBody {
  const NoticeBody({
    required this.senderName,
    required this.title,
    this.place = '',
    this.text = '',
  });

  /// 発信元表示名（≤ 48 バイト）。
  final String senderName;

  /// 見出し（≤ 120 バイト）。
  final String title;

  /// 場所（≤ 120 バイト）。
  final String place;

  /// 本文（≤ 3,000 バイト）。
  final String text;

  /// `u16 len + UTF-8` × 4 に直列化する。長さ超過は [EnvelopeFormatException]。
  Uint8List encode() {
    final w = _FieldWriter()
      ..addString(senderName, maxBytes: kMaxSenderNameBytes, name: 'sender_name')
      ..addString(title, maxBytes: kMaxTitleBytes, name: 'title')
      ..addString(place, maxBytes: kMaxPlaceBytes, name: 'place')
      ..addString(text, maxBytes: kMaxTextBytes, name: 'text');
    return w.takeBytes();
  }

  /// 直列化された body を復元する。長さ超過・不正は [EnvelopeFormatException]。
  /// 5 番目以降のフィールド（将来の定型見出しなど）は無視する。
  static NoticeBody decode(Uint8List bytes) {
    final r = _FieldReader(bytes);
    final senderName =
        r.readString(maxBytes: kMaxSenderNameBytes, name: 'sender_name');
    final title = r.readString(maxBytes: kMaxTitleBytes, name: 'title');
    final place = r.readString(maxBytes: kMaxPlaceBytes, name: 'place');
    final text = r.readString(maxBytes: kMaxTextBytes, name: 'text');
    return NoticeBody(
      senderName: senderName,
      title: title,
      place: place,
      text: text,
    );
  }

  @override
  String toString() =>
      'NoticeBody(senderName: $senderName, title: $title, place: $place, '
      'text: ${text.length} 文字)';
}

/// グループ情報（kind=group_info）の body。
///
/// 4 フィールド（name / host_name / policy / description）に加え、v2 では
/// 5 番目の ext（code_digest 8 B ‖ generation u16 ‖ successor uint24）を
/// 省略可能なフィールドとして持つ（C24）。
class GroupInfoBody {
  const GroupInfoBody({
    required this.name,
    required this.hostName,
    this.membersCanPost = true,
    this.description = '',
    this.closed = false,
    this.acceptsHelp = false,
    this.codeDigest,
    this.generation = 0,
    this.successor = 0,
  });

  /// グループ名（≤ 60 バイト）。
  final String name;

  /// ホストの表示名（≤ 48 バイト）。
  final String hostName;

  /// 参加者も投稿できるか（policy bit0）。
  final bool membersCanPost;

  /// 説明・問い合わせ先（≤ 300 バイト）。
  final String description;

  /// 閉鎖済み（引っ越し済み、policy bit1）。
  final bool closed;

  /// 困りごとを受け付けるか（policy bit2）。
  final bool acceptsHelp;

  /// 本部コード・スタッフコードのダイジェスト（8 バイト）。なければ null。
  final Uint8List? codeDigest;

  /// 世代。コードの作り直し・引っ越しごとに +1（受信側は世代 → created_at の順で採用）。
  final int generation;

  /// 後継の参加コード（0 = なし）。
  final int successor;

  /// ext フィールドを載せるか。
  bool get hasExt => codeDigest != null || generation != 0 || successor != 0;

  /// `u16 len + bytes` × 4（+ ext）。
  Uint8List encode() {
    final policy = Uint8List(1);
    policy[0] = (membersCanPost ? kPolicyMembersCanPost : 0) |
        (closed ? kPolicyClosed : 0) |
        (acceptsHelp ? kPolicyAcceptsHelp : 0);
    final w = _FieldWriter()
      ..addString(name, maxBytes: kMaxGroupNameBytes, name: 'name')
      ..addString(hostName, maxBytes: kMaxHostNameBytes, name: 'host_name')
      ..addBytes(policy, maxBytes: 1, name: 'policy')
      ..addString(description,
          maxBytes: kMaxDescriptionBytes, name: 'description');
    if (hasExt) {
      final digest = codeDigest;
      if (digest != null && digest.length != kCodeDigestLength) {
        throw EnvelopeFormatException(
            'code_digest は $kCodeDigestLength バイトでなければなりません');
      }
      if (generation < 0 || generation > 0xFFFF) {
        throw EnvelopeFormatException('generation が範囲外です（$generation）');
      }
      if (successor < 0 || successor > kMaxGroupId) {
        throw EnvelopeFormatException('successor が範囲外です（$successor）');
      }
      final ext = Uint8List(kGroupInfoExtLength);
      if (digest != null) {
        ext.setRange(0, kCodeDigestLength, digest);
      }
      final view = ByteData.sublistView(ext);
      view.setUint16(kCodeDigestLength, generation, Endian.little);
      ext[kCodeDigestLength + 2] = successor & 0xFF;
      ext[kCodeDigestLength + 3] = (successor >> 8) & 0xFF;
      ext[kCodeDigestLength + 4] = (successor >> 16) & 0xFF;
      w.addBytes(ext, maxBytes: kGroupInfoExtLength, name: 'ext');
    }
    return w.takeBytes();
  }

  /// 直列化された body を復元する。不正は [EnvelopeFormatException]。
  /// ext（5 番目）は省略可。6 番目以降は無視する。
  static GroupInfoBody decode(Uint8List bytes) {
    final r = _FieldReader(bytes);
    final name = r.readString(maxBytes: kMaxGroupNameBytes, name: 'name');
    final hostName = r.readString(maxBytes: kMaxHostNameBytes, name: 'host_name');
    final policy = r.readBytes(maxBytes: 1, name: 'policy');
    if (policy.length != 1) {
      throw const EnvelopeFormatException('policy は 1 バイトでなければなりません');
    }
    final description =
        r.readString(maxBytes: kMaxDescriptionBytes, name: 'description');
    Uint8List? digest;
    var generation = 0;
    var successor = 0;
    if (r.hasMore) {
      // 将来 ext が伸びても先頭の 13 バイトだけ読む。壊れていれば ext なしとして扱う。
      Uint8List ext;
      try {
        ext = r.readBytes(maxBytes: 0xFFFF, name: 'ext');
      } on EnvelopeFormatException {
        ext = Uint8List(0);
      }
      if (ext.length >= kGroupInfoExtLength) {
        final d = Uint8List.fromList(ext.sublist(0, kCodeDigestLength));
        if (d.any((b) => b != 0)) {
          digest = d;
        }
        generation = ByteData.sublistView(ext)
            .getUint16(kCodeDigestLength, Endian.little);
        successor = ext[kCodeDigestLength + 2] |
            (ext[kCodeDigestLength + 3] << 8) |
            (ext[kCodeDigestLength + 4] << 16);
        if (successor > kMaxGroupId) {
          successor = 0;
        }
      }
    }
    return GroupInfoBody(
      name: name,
      hostName: hostName,
      membersCanPost: (policy[0] & kPolicyMembersCanPost) != 0,
      description: description,
      closed: (policy[0] & kPolicyClosed) != 0,
      acceptsHelp: (policy[0] & kPolicyAcceptsHelp) != 0,
      codeDigest: digest,
      generation: generation,
      successor: successor,
    );
  }

  @override
  String toString() =>
      'GroupInfoBody(name: $name, hostName: $hostName, '
      'membersCanPost: $membersCanPost, closed: $closed, '
      'generation: $generation, successor: $successor)';
}

// ---------------------------------------------------------------------------
// Envelope
// ---------------------------------------------------------------------------

/// メッセージ封筒。
///
/// [msgId] / [supersedes] は 64 ビット符号付き int として保持する
/// （ワイヤ上の uint64 とビット列は同一。`u64ToBytes` で相互変換できる）。
///
/// 3 つの形がある。
/// - 通常: body を解釈済み（表示できる）。
/// - 不透明（[isOpaque]）: 未知の version / kind / flags / body。生バイト
///   [opaqueBytes] を保持し、hop と expires_at だけ書き換えて中継する。
/// - 空殻（[isStub]）: 取り消しで本文を消した notice。ヘッダだけ残し、
///   目録には載せるが MESSAGE では送らない（C20）。
class Envelope {
  Envelope({
    required this.kind,
    required this.groupId,
    required this.msgId,
    required this.createdAt,
    required this.expiresAt,
    this.hop = 0,
    this.category = NoticeCategory.general,
    this.role = SenderRole.resident,
    this.supersedes,
    required this.bodyPlain,
    this.version = kProtocolVersion,
    this.opaqueBytes,
    this.isStub = false,
  }) {
    if (groupId < 0 || groupId > kMaxGroupId) {
      throw ArgumentError.value(groupId, 'groupId', '0..$kMaxGroupId');
    }
    if (createdAt < 0 || createdAt > 0xFFFFFFFF) {
      throw ArgumentError.value(createdAt, 'createdAt', 'uint32 の範囲外');
    }
    if (expiresAt < 0 || expiresAt > 0xFFFFFFFF) {
      throw ArgumentError.value(expiresAt, 'expiresAt', 'uint32 の範囲外');
    }
    if (expiresAt < createdAt) {
      throw ArgumentError.value(
          expiresAt, 'expiresAt', 'createdAt より前にはできません');
    }
    if (hop < 0 || hop > kMaxHopValue) {
      throw ArgumentError.value(hop, 'hop', '0..$kMaxHopValue');
    }
    if (bodyPlain.length > kMaxBodyPlainBytes) {
      throw ArgumentError.value(
          bodyPlain.length, 'bodyPlain', '$kMaxBodyPlainBytes バイトを超えています');
    }
    final opaque = opaqueBytes;
    if (opaque != null) {
      if (opaque.length < kEnvelopeHeaderLength) {
        throw ArgumentError.value(
            opaque.length, 'opaqueBytes', 'ヘッダより短い');
      }
      if (kind != MessageKind.unknown) {
        throw ArgumentError.value(kind, 'kind', '不透明メッセージの kind は unknown');
      }
      return;
    }
    if (kind == MessageKind.unknown) {
      throw ArgumentError.value(kind, 'kind', 'unknown は不透明メッセージ専用');
    }
    if (isStub) {
      if (bodyPlain.isNotEmpty) {
        throw ArgumentError.value(
            bodyPlain.length, 'bodyPlain', '空殻の body は空です');
      }
      return;
    }
    if (kind == MessageKind.tombstone || kind == MessageKind.ack) {
      if (supersedes == null) {
        throw ArgumentError.value(
            supersedes, 'supersedes', '${kind.name} には supersedes が必要です');
      }
      if (bodyPlain.isNotEmpty) {
        throw ArgumentError.value(
            bodyPlain.length, 'bodyPlain', '${kind.name} の body は空です');
      }
    }
  }

  final MessageKind kind;

  /// グループ ID（0..999999）。
  final int groupId;

  /// メッセージ ID（64 ビット）。
  final int msgId;

  /// 発信時刻（エポック秒）。
  final int createdAt;

  /// 有効期限（エポック秒）。中継時は残り時間に合わせて書き換える（C12）。
  final int expiresAt;

  /// 中継回数。発信時 0。
  final int hop;

  final NoticeCategory category;
  final SenderRole role;

  /// 上書き / 取り消し対象の msg_id。
  final int? supersedes;

  /// 平文の body（不透明・空殻では空）。
  final Uint8List bodyPlain;

  /// ワイヤ上の version。
  final int version;

  /// 不透明メッセージの生バイト（ヘッダを含む封筒全体）。通常は null。
  final Uint8List? opaqueBytes;

  /// 本文を消した空殻か。
  final bool isStub;

  /// 未知の形式を生バイトのまま持つ不透明メッセージか。
  bool get isOpaque => opaqueBytes != null;

  /// 表示に使えるか（通常の形）。
  bool get isDisplayable => !isOpaque && !isStub;

  /// 有効期間（秒）。
  int get ttlSeconds => expiresAt - createdAt;

  /// 発信用。[originId]（8 バイトのノード ID）から [msgId] を計算して生成する。
  factory Envelope.create({
    required MessageKind kind,
    required int groupId,
    required Uint8List originId,
    required int createdAt,
    required int expiresAt,
    required NoticeCategory category,
    required SenderRole role,
    int? supersedes,
    required Uint8List bodyPlain,
  }) {
    final msgId = computeMsgId(
      groupId: groupId,
      kind: kind,
      originId: originId,
      createdAt: createdAt,
      bodyPlain: bodyPlain,
      supersedes: supersedes,
    );
    return Envelope(
      kind: kind,
      groupId: groupId,
      msgId: msgId,
      createdAt: createdAt,
      expiresAt: expiresAt,
      category: category,
      role: role,
      supersedes: supersedes,
      bodyPlain: bodyPlain,
    );
  }

  /// msg_id = SHA-256(group_id(3 LE) ‖ kind(1) ‖ origin_id(8) ‖ created_at(4 LE)
  /// ‖ body_plain ‖ [supersedes(8 LE)]) の先頭 8 バイト（リトルエンディアンで int 化）。
  ///
  /// hop / role / category / expires_at は含まない。supersedes は（あれば）含める。
  /// 同じ端末が同じ秒に複数の取り消しを出しても ID が衝突しないようにするため
  /// （v2。受信側は origin_id を知らず再計算しないので互換性に影響しない）。
  static int computeMsgId({
    required int groupId,
    required MessageKind kind,
    required Uint8List originId,
    required int createdAt,
    required Uint8List bodyPlain,
    int? supersedes,
  }) {
    if (originId.length != kOriginIdLength) {
      throw ArgumentError.value(
          originId.length, 'originId', '$kOriginIdLength バイトが必要です');
    }
    if (groupId < 0 || groupId > kMaxGroupId) {
      throw ArgumentError.value(groupId, 'groupId', '0..$kMaxGroupId');
    }
    if (createdAt < 0 || createdAt > 0xFFFFFFFF) {
      throw ArgumentError.value(createdAt, 'createdAt', 'uint32 の範囲外');
    }
    final tail = supersedes != null ? kSupersedesLength : 0;
    final input =
        Uint8List(3 + 1 + kOriginIdLength + 4 + bodyPlain.length + tail);
    input[0] = groupId & 0xFF;
    input[1] = (groupId >> 8) & 0xFF;
    input[2] = (groupId >> 16) & 0xFF;
    input[3] = kind.code;
    input.setRange(4, 4 + kOriginIdLength, originId);
    final view = ByteData.sublistView(input);
    view.setUint32(4 + kOriginIdLength, createdAt, Endian.little);
    final bodyOffset = 4 + kOriginIdLength + 4;
    input.setRange(bodyOffset, bodyOffset + bodyPlain.length, bodyPlain);
    if (supersedes != null) {
      view.setInt64(bodyOffset + bodyPlain.length, supersedes, Endian.little);
    }
    final digest = Uint8List.fromList(sha256.convert(input).bytes);
    return ByteData.sublistView(digest).getInt64(0, Endian.little);
  }

  /// ワイヤ形式に直列化する。[compress] が true でも、圧縮して縮むときだけ
  /// flags bit0 を立てて圧縮 body を載せる。
  ///
  /// 不透明メッセージは生バイトの hop（offset 23）と expires_at（offset 19）だけ
  /// 書き換えて返す。空殻は body_len 0 のヘッダだけになる（送信には使わない）。
  Uint8List encode({bool compress = true}) {
    final opaque = opaqueBytes;
    if (opaque != null) {
      final out = Uint8List.fromList(opaque);
      final view = ByteData.sublistView(out);
      view.setUint32(19, expiresAt, Endian.little);
      out[23] = hop;
      return out;
    }
    var body = bodyPlain;
    var flags = 0;
    if (compress && bodyPlain.isNotEmpty) {
      final compressed = compressBody(bodyPlain);
      if (compressed.length < bodyPlain.length) {
        body = compressed;
        flags |= kFlagCompressed;
      }
    }
    final supersedes = this.supersedes;
    if (supersedes != null) {
      flags |= kFlagSupersedes;
    }
    final headerLength = kEnvelopeHeaderLength +
        (supersedes != null ? kSupersedesLength : 0);
    final out = Uint8List(headerLength + body.length);
    final view = ByteData.sublistView(out);
    out[0] = kEnvelopeMagic;
    out[1] = kProtocolVersion;
    out[2] = kind.code;
    out[3] = flags;
    out[4] = groupId & 0xFF;
    out[5] = (groupId >> 8) & 0xFF;
    out[6] = (groupId >> 16) & 0xFF;
    view.setInt64(7, msgId, Endian.little);
    view.setUint32(15, createdAt, Endian.little);
    view.setUint32(19, expiresAt, Endian.little);
    out[23] = hop;
    out[24] = category.code;
    out[25] = role.code;
    view.setUint16(26, body.length, Endian.little);
    if (supersedes != null) {
      view.setInt64(kEnvelopeHeaderLength, supersedes, Endian.little);
    }
    out.setRange(headerLength, out.length, body);
    return out;
  }

  /// ワイヤ形式から復元し、検証する。
  ///
  /// 「中継できる条件」（magic、ヘッダ 28 B 以上、body_len と実長の一致、
  /// body_len ≤ 4,096、expires_at ≥ created_at、group_id の範囲）を満たさない
  /// ものは [EnvelopeFormatException]。
  ///
  /// 「表示できる条件」（version 1、既知の kind、予約 flags が 0、既知の role、
  /// 伸長と body の形式が正しい、tombstone / ack の supersedes 必須・body 空）を
  /// 満たさないものは、[strict] なら例外、そうでなければ不透明メッセージとして
  /// 返す（生バイトのまま保存・目録・中継できる。表示はしない）。
  ///
  /// origin_id はワイヤに載らないため msg_id の再計算はできない
  /// （期限切れ判定は受信時刻を知る呼び出し側が行う）。
  static Envelope decode(Uint8List bytes, {bool strict = false}) {
    if (bytes.length < kEnvelopeHeaderLength) {
      throw EnvelopeFormatException(
          'ヘッダが短すぎます（${bytes.length} バイト）');
    }
    if (bytes[0] != kEnvelopeMagic) {
      throw const EnvelopeFormatException('magic が不正です');
    }
    final version = bytes[1];
    final kindCode = bytes[2];
    final kind = MessageKind.fromCode(kindCode);
    final flags = bytes[3];
    final groupId = bytes[4] | (bytes[5] << 8) | (bytes[6] << 16);
    if (groupId > kMaxGroupId) {
      throw EnvelopeFormatException('group_id が範囲外です（$groupId）');
    }
    final view = ByteData.sublistView(bytes);
    final msgId = view.getInt64(7, Endian.little);
    final createdAt = view.getUint32(15, Endian.little);
    final expiresAt = view.getUint32(19, Endian.little);
    if (expiresAt < createdAt) {
      throw const EnvelopeFormatException('expires_at が created_at より前です');
    }
    final hop = bytes[23];
    final category = NoticeCategory.fromCode(bytes[24]);
    final role = SenderRole.fromCode(bytes[25]);
    final bodyLen = view.getUint16(26, Endian.little);
    if (bodyLen > kMaxBodyPlainBytes) {
      throw EnvelopeFormatException('body_len が大きすぎます（$bodyLen）');
    }

    var offset = kEnvelopeHeaderLength;
    int? supersedes;
    final hasSupersedes = (flags & kFlagSupersedes) != 0;
    if (hasSupersedes) {
      if (bytes.length < offset + kSupersedesLength) {
        throw const EnvelopeFormatException('supersedes が途中で切れています');
      }
      supersedes = view.getInt64(offset, Endian.little);
      offset += kSupersedesLength;
    }
    if (bytes.length - offset != bodyLen) {
      throw EnvelopeFormatException(
        'body_len（$bodyLen）と実際の長さ（${bytes.length - offset}）が一致しません',
      );
    }

    Envelope opaque(String reason) {
      if (strict) {
        throw EnvelopeFormatException(reason);
      }
      return Envelope(
        kind: MessageKind.unknown,
        groupId: groupId,
        msgId: msgId,
        createdAt: createdAt,
        expiresAt: expiresAt,
        hop: hop,
        category: category,
        role: role ?? SenderRole.resident,
        bodyPlain: Uint8List(0),
        version: version,
        opaqueBytes: Uint8List.fromList(bytes),
      );
    }

    if (version != kProtocolVersion) {
      return opaque('未対応のバージョンです（$version）');
    }
    if (kind == null) {
      return opaque('不明な kind です（$kindCode）');
    }
    if ((flags & kFlagsReservedMask) != 0) {
      return opaque('予約 flags が立っています（$flags）');
    }
    if (role == null) {
      return opaque('不明な role です（${bytes[25]}）');
    }

    final body = Uint8List.sublistView(bytes, offset, offset + bodyLen);
    final Uint8List bodyPlain;
    if ((flags & kFlagCompressed) != 0) {
      if (bodyLen == 0) {
        return opaque('圧縮 body が空です');
      }
      try {
        bodyPlain = decompressBody(body);
      } on Object catch (e) {
        return opaque('伸長に失敗しました: $e');
      }
    } else {
      bodyPlain = Uint8List.fromList(body);
    }

    try {
      switch (kind) {
        case MessageKind.notice:
        case MessageKind.help:
          NoticeBody.decode(bodyPlain);
        case MessageKind.groupInfo:
          GroupInfoBody.decode(bodyPlain);
        case MessageKind.tombstone:
        case MessageKind.ack:
          if (supersedes == null) {
            throw EnvelopeFormatException('${kind.name} に supersedes がありません');
          }
          if (bodyPlain.isNotEmpty) {
            throw EnvelopeFormatException('${kind.name} の body が空ではありません');
          }
        case MessageKind.unknown:
          throw const EnvelopeFormatException('不明な kind です');
      }
    } on EnvelopeFormatException catch (e) {
      return opaque(e.message);
    }

    return Envelope(
      kind: kind,
      groupId: groupId,
      msgId: msgId,
      createdAt: createdAt,
      expiresAt: expiresAt,
      hop: hop,
      category: category,
      role: role,
      supersedes: supersedes,
      bodyPlain: bodyPlain,
      version: version,
    );
  }

  /// 空殻（body_len 0 のヘッダだけ）を復元する（保存ファイルの読み込み用）。
  static Envelope decodeStub(Uint8List bytes) {
    if (bytes.length < kEnvelopeHeaderLength || bytes[0] != kEnvelopeMagic) {
      throw const EnvelopeFormatException('空殻のヘッダが不正です');
    }
    final kind = MessageKind.fromCode(bytes[2]) ?? MessageKind.notice;
    final flags = bytes[3];
    final groupId = bytes[4] | (bytes[5] << 8) | (bytes[6] << 16);
    final view = ByteData.sublistView(bytes);
    int? supersedes;
    if ((flags & kFlagSupersedes) != 0 &&
        bytes.length >= kEnvelopeHeaderLength + kSupersedesLength) {
      supersedes = view.getInt64(kEnvelopeHeaderLength, Endian.little);
    }
    return Envelope(
      kind: kind,
      groupId: groupId,
      msgId: view.getInt64(7, Endian.little),
      createdAt: view.getUint32(15, Endian.little),
      expiresAt: view.getUint32(19, Endian.little),
      hop: bytes[23],
      category: NoticeCategory.fromCode(bytes[24]),
      role: SenderRole.fromCode(bytes[25]) ?? SenderRole.resident,
      supersedes: supersedes,
      bodyPlain: Uint8List(0),
      isStub: true,
    );
  }

  /// hop / expires_at を変えた複製を返す（中継時の +1、残り時間の書き換え用）。
  Envelope copyWith({int? hop, int? expiresAt}) {
    return Envelope(
      kind: kind,
      groupId: groupId,
      msgId: msgId,
      createdAt: createdAt,
      expiresAt: expiresAt ?? this.expiresAt,
      hop: hop ?? this.hop,
      category: category,
      role: role,
      supersedes: supersedes,
      bodyPlain: bodyPlain,
      version: version,
      opaqueBytes: opaqueBytes,
      isStub: isStub,
    );
  }

  /// 本文を消した空殻にする（取り消し時、C20）。
  Envelope asStub() {
    return Envelope(
      kind: kind == MessageKind.unknown ? MessageKind.notice : kind,
      groupId: groupId,
      msgId: msgId,
      createdAt: createdAt,
      expiresAt: expiresAt,
      hop: hop,
      category: category,
      role: role,
      supersedes: supersedes,
      bodyPlain: Uint8List(0),
      version: version,
      isStub: true,
    );
  }

  /// kind == notice のときの body。それ以外（不透明・空殻を含む）は null。
  NoticeBody? get notice => kind == MessageKind.notice && isDisplayable
      ? NoticeBody.decode(bodyPlain)
      : null;

  /// kind == help のときの body。それ以外は null。
  NoticeBody? get help =>
      kind == MessageKind.help && isDisplayable ? NoticeBody.decode(bodyPlain) : null;

  /// kind == groupInfo のときの body。それ以外は null。
  GroupInfoBody? get groupInfo => kind == MessageKind.groupInfo && isDisplayable
      ? GroupInfoBody.decode(bodyPlain)
      : null;

  /// [epochSeconds]（受信時刻などの判定時刻）の時点で期限切れか。
  /// expires_at ちょうどはまだ有効とみなす。
  bool isExpiredAt(int epochSeconds) => expiresAt < epochSeconds;

  @override
  String toString() =>
      'Envelope(kind: ${kind.name}, groupId: $groupId, '
      'msgId: 0x${msgId.toRadixString(16)}, createdAt: $createdAt, '
      'expiresAt: $expiresAt, hop: $hop, category: ${category.name}, '
      'role: ${role.name}, supersedes: $supersedes, '
      'body: ${bodyPlain.length} バイト'
      '${isOpaque ? ', opaque v$version' : ''}${isStub ? ', stub' : ''})';
}
