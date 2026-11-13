/// 本部・スタッフの受信記録。中継キャッシュとは別の保存枠で保持する。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/envelope.dart';
import 'message_store.dart';
import 'store_file.dart';

const int kReportInboxMaxRecords = 10000;
const int kReportInboxMaxBytes = 64 * 1024 * 1024;
const int kReportInboxRetentionSeconds = 30 * 24 * 3600;

/// 報告と、その報告への最新の「受け取りました」を一緒に保管する。
class InboxRecord {
  const InboxRecord(this.message, {this.ack});

  final StoredMessage message;
  final StoredMessage? ack;

  int get msgId => message.msgId;
  int get retainUntil => message.receivedAt + kReportInboxRetentionSeconds;
}

class ReportInbox extends ChangeNotifier {
  ReportInbox(
    this._backend, {
    this.maxRecords = kReportInboxMaxRecords,
    this.maxBytes = kReportInboxMaxBytes,
  });

  final StoreBackend _backend;
  final int maxRecords;
  final int maxBytes;
  Map<int, InboxRecord> _records = {};
  Map<int, Uint8List> _encoded = {};
  Set<int> _ackIds = {};
  Future<void> _io = Future<void>.value();
  int _updates = 0;
  bool _needsRewrite = false;
  String? lastError;

  int get count => _records.length;
  Iterable<InboxRecord> get all => _records.values;
  InboxRecord? get(int id) => _records[id];
  bool containsMessageId(int id) =>
      _records.containsKey(id) || _ackIds.contains(id);

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final next = _io.then((_) => operation());
    _io = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<void> load({required int now}) => _serialized(() async {
    final loaded = <int, InboxRecord>{};
    for (final bytes in await _backend.readAll()) {
      final record = _decode(bytes);
      loaded[record.msgId] = record;
    }
    final retained = <int, InboxRecord>{
      for (final entry in loaded.entries)
        if (entry.value.retainUntil > now) entry.key: entry.value,
    };
    if (retained.length != loaded.length) {
      await _backend.rewrite(retained.values.map(_encode).toList());
    }
    _install(retained, {for (final r in retained.values) r.msgId: _encode(r)});
    lastError = null;
  });

  /// MessageStore の保存前フックから呼ぶ。ここが成功するまでは中継側も
  /// 受信成功にならない。報告を先に保存するので途中終了でも記録が残る。
  Future<void> capture(
    MessageStore staged,
    List<StoredMessage> additions,
    int now, {
    required bool Function(int groupId) canSee,
  }) => _serialized(() async {
    final next = Map<int, InboxRecord>.of(_records);
    next.removeWhere((_, r) => r.retainUntil <= now);
    final changed = <int>{};

    // 同じバッチ内の報告を先に入れる。あとから返信・取消を反映する。
    for (final added in additions) {
      if (added.kind != MessageKind.help ||
          added.isLocal ||
          added.isOpaque ||
          added.isStub ||
          !canSee(added.groupId) ||
          added.receivedAt + kReportInboxRetentionSeconds <= now) {
        continue;
      }
      final current = next[added.msgId];
      var message = (current?.message ?? added).copy();
      final finalMessage = staged.get(added.msgId) ?? added;
      if (finalMessage.retracted) {
        message.retracted = true;
      }
      if (finalMessage.isStub && !message.isStub) {
        message = StoredMessage(
          envelope: message.envelope.asStub(),
          receivedAt: message.receivedAt,
          retracted: true,
          retractedByOfficial: finalMessage.retractedByOfficial,
        );
      }
      final ack = current?.ack ?? staged.ackFor(added.msgId);
      final candidate = InboxRecord(
        message,
        ack: _validAck(ack, message) ? ack : null,
      );
      if (!_same(current, candidate)) {
        next[added.msgId] = candidate;
        changed.add(added.msgId);
      }
    }

    for (final control in additions) {
      final targetId = control.envelope.supersedes;
      if (targetId == null) continue;
      final old = next[targetId];
      if (old == null ||
          control.groupId != old.message.groupId ||
          !canSee(control.groupId)) {
        continue;
      }
      InboxRecord? replacement;
      if (control.kind == MessageKind.ack && _validAck(control, old.message)) {
        final previous = old.ack;
        if (previous == null || _newer(control, previous)) {
          replacement = InboxRecord(old.message, ack: control.copy());
        }
      } else if (control.kind == MessageKind.tombstone &&
          control.envelope.role.code >= old.message.envelope.role.code &&
          !old.message.retracted) {
        final source = old.message;
        final eraseBody = !staged.officialGroupIds.contains(source.groupId);
        final message = StoredMessage(
          envelope: eraseBody ? source.envelope.asStub() : source.envelope,
          receivedAt: source.receivedAt,
          isLocal: source.isLocal,
          read: source.read,
          retracted: true,
          retractedByOfficial: control.envelope.role == SenderRole.official,
        );
        replacement = InboxRecord(message, ack: old.ack);
      }
      if (replacement != null) {
        next[targetId] = replacement;
        changed.add(targetId);
      }
    }
    await _save(next, changed);
  });

  Future<void> purgeExpired(int now) =>
      removeWhere((r) => r.retainUntil <= now);

  Future<void> removeWhere(bool Function(InboxRecord) test) =>
      _serialized(() async {
        final next = Map<int, InboxRecord>.of(_records)
          ..removeWhere((_, r) => test(r));
        await _save(next, const {});
      });

  Future<void> _save(Map<int, InboxRecord> next, Set<int> changed) async {
    final removed = _records.keys.any((id) => !next.containsKey(id));
    if (!removed && changed.isEmpty && !_needsRewrite) return;
    // スタッフ端末の取消では旧ログに残った本文も同時に消す。
    final erasedBody = changed.any(
      (id) => next[id]!.message.isStub && _records[id]?.message.isStub != true,
    );
    final encoded = Map<int, Uint8List>.of(_encoded)
      ..removeWhere((id, _) => !next.containsKey(id));
    for (final id in changed) {
      encoded[id] = _encode(next[id]!);
    }
    try {
      final bytes = encoded.values.fold<int>(0, (sum, b) => sum + b.length + 4);
      if (next.length > maxRecords || bytes > maxBytes) {
        throw const StoreCapacityException(
          '本部の 記録が いっぱいです。記録を コピーして 保管し、係の人に 相談してください。新しい 記録は 保存できていません。',
        );
      }
      if (removed ||
          erasedBody ||
          _needsRewrite ||
          _updates + changed.length >= 500) {
        await _backend.rewrite(encoded.values.toList());
        _updates = 0;
      } else {
        await _backend.appendAll([for (final id in changed) encoded[id]!]);
        _updates += changed.length;
      }
      _needsRewrite = false;
      _install(next, encoded);
      lastError = null;
      notifyListeners();
    } catch (e) {
      // 途中まで追記された可能性があるので、次の成功書き込みでは既知の
      // 状態から全置換する。失敗した変更は公開しない。
      _needsRewrite = true;
      lastError = '$e';
      notifyListeners();
      rethrow;
    }
  }

  void _install(Map<int, InboxRecord> records, Map<int, Uint8List> encoded) {
    _records = records;
    _encoded = encoded;
    _ackIds = {
      for (final r in records.values)
        if (r.ack != null) r.ack!.msgId,
    };
  }

  static bool _validAck(StoredMessage? ack, StoredMessage target) =>
      ack != null &&
      ack.kind == MessageKind.ack &&
      ack.groupId == target.groupId &&
      ack.envelope.supersedes == target.msgId &&
      ack.envelope.role.code >= SenderRole.staff.code;

  static bool _newer(StoredMessage a, StoredMessage b) =>
      a.envelope.createdAt > b.envelope.createdAt ||
      (a.envelope.createdAt == b.envelope.createdAt && a.msgId < b.msgId);

  static bool _same(InboxRecord? a, InboxRecord b) =>
      a != null &&
      a.message.retracted == b.message.retracted &&
      a.message.isStub == b.message.isStub &&
      a.ack?.msgId == b.ack?.msgId;

  static Map<String, Object?> _messageJson(StoredMessage m) => {
    'wire': base64Encode(m.wireBytes),
    'at': m.receivedAt,
    'local': m.isLocal,
    'retracted': m.retracted,
    'stub': m.isStub,
    'officialRetraction': m.retractedByOfficial,
  };

  static StoredMessage _messageFromJson(Map<String, dynamic> json) {
    final wire = base64Decode(json['wire'] as String);
    return StoredMessage(
      envelope: json['stub'] == true
          ? Envelope.decodeStub(wire)
          : Envelope.decode(wire),
      receivedAt: json['at'] as int,
      isLocal: json['local'] == true,
      retracted: json['retracted'] == true,
      retractedByOfficial: json['officialRetraction'] == true,
    );
  }

  static Uint8List _encode(InboxRecord r) => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': 1,
        'message': _messageJson(r.message),
        if (r.ack != null) 'ack': _messageJson(r.ack!),
      }),
    ),
  );

  static InboxRecord _decode(Uint8List bytes) {
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    if (json['v'] != 1) throw const FormatException('本部の記録の版が不明です');
    final message = _messageFromJson(json['message'] as Map<String, dynamic>);
    final ack = json['ack'] == null
        ? null
        : _messageFromJson(json['ack'] as Map<String, dynamic>);
    if (message.kind != MessageKind.help ||
        message.isLocal ||
        (ack != null && !_validAck(ack, message))) {
      throw const FormatException('本部の記録の形式が不正です');
    }
    return InboxRecord(message, ack: ack);
  }
}
