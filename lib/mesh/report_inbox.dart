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

// 現存する記録に対して古い追記が 1/4 たまったらまとめる。小さい記録でも
// 毎回の全置換にはせず、大きい記録では余分なログを 4 MiB 程度に抑える。
const int _minCompactionSlackBytes = 256 * 1024;
const int _maxCompactionSlackBytes = 4 * 1024 * 1024;
const int _loadYieldRecords = 256;

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
  int _liveBytes = 0;
  int _journalBytes = 0;
  int? _nextExpiry;
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
    try {
      final loaded = <int, InboxRecord>{};
      final encoded = <int, Uint8List>{};
      var journalBytes = 0;
      var decoded = 0;
      for (final bytes in await _backend.readAll()) {
        final record = _decode(bytes);
        loaded[record.msgId] = record;
        // 最新レコードの元の符号化を再利用し、全件の再圧縮・JSON 化を避ける。
        encoded[record.msgId] = bytes;
        journalBytes += _framedSize(bytes);
        if (++decoded % _loadYieldRecords == 0) {
          // 大きい履歴の復元中も画面・通信のイベントを進める。
          await Future<void>.delayed(Duration.zero);
        }
      }
      final expired = <int>[
        for (final entry in loaded.entries)
          if (entry.value.retainUntil <= now) entry.key,
      ];
      for (final id in expired) {
        loaded.remove(id);
        encoded.remove(id);
      }
      final liveBytes = encoded.values.fold<int>(
        0,
        (sum, bytes) => sum + _framedSize(bytes),
      );
      _checkCapacity(loaded.length, liveBytes);
      if (expired.isNotEmpty || _shouldCompact(journalBytes, liveBytes)) {
        await _backend.rewrite(encoded.values.toList());
        journalBytes = liveBytes;
      }
      _records = loaded;
      _encoded = encoded;
      _ackIds = {
        for (final r in loaded.values)
          if (r.ack != null) r.ack!.msgId,
      };
      _liveBytes = liveBytes;
      _journalBytes = journalBytes;
      _updateNextExpiry();
      _needsRewrite = false;
      lastError = null;
    } catch (e) {
      lastError = '$e';
      notifyListeners();
      rethrow;
    }
  });

  /// MessageStore の保存前フックから呼ぶ。ここが成功するまでは中継側も
  /// 受信成功にならない。報告を先に保存するので途中終了でも記録が残る。
  Future<void> capture(
    MessageStore staged,
    List<StoredMessage> additions,
    int now, {
    required bool Function(int groupId) canSee,
  }) => _serialized(() async {
    final removed = _expiredIds(now);
    final changed = <int, InboxRecord>{};
    InboxRecord? currentRecord(int id) =>
        changed[id] ?? (removed.contains(id) ? null : _records[id]);

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
      final current = currentRecord(added.msgId);
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
        changed[added.msgId] = candidate;
      }
    }

    for (final control in additions) {
      final targetId = control.envelope.supersedes;
      if (targetId == null) continue;
      final old = currentRecord(targetId);
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
        changed[targetId] = replacement;
      }
    }
    await _save(changed, removed);
  });

  Future<void> purgeExpired(int now) =>
      _serialized(() => _save(const {}, _expiredIds(now)));

  Future<void> removeWhere(bool Function(InboxRecord) test) =>
      _serialized(() async {
        await _save(const {}, {
          for (final entry in _records.entries)
            if (test(entry.value)) entry.key,
        });
      });

  Set<int> _expiredIds(int now) {
    if (_nextExpiry == null || _nextExpiry! > now) return const {};
    return {
      for (final entry in _records.entries)
        if (entry.value.retainUntil <= now) entry.key,
    };
  }

  Future<void> _save(Map<int, InboxRecord> changed, Set<int> removed) async {
    if (removed.isEmpty && changed.isEmpty && !_needsRewrite) return;
    // スタッフ端末の取消では旧ログに残った本文も同時に消す。
    final erasedBody = changed.entries.any(
      (entry) =>
          entry.value.message.isStub &&
          _records[entry.key]?.message.isStub != true,
    );
    final encoded = <int, Uint8List>{};
    var nextCount = _records.length - removed.length;
    var liveBytes = _liveBytes;
    var appendedBytes = 0;
    var writeStarted = false;
    try {
      for (final id in removed) {
        liveBytes -= _framedSize(_encoded[id]!);
      }
      for (final entry in changed.entries) {
        final bytes = _encode(entry.value);
        encoded[entry.key] = bytes;
        final previous = removed.contains(entry.key)
            ? null
            : _encoded[entry.key];
        if (previous == null) {
          nextCount++;
        } else {
          liveBytes -= _framedSize(previous);
        }
        liveBytes += _framedSize(bytes);
        appendedBytes += _framedSize(bytes);
      }
      _checkCapacity(nextCount, liveBytes);
      final rewrite =
          removed.isNotEmpty ||
          erasedBody ||
          _needsRewrite ||
          _shouldCompact(_journalBytes + appendedBytes, liveBytes);
      writeStarted = true;
      if (rewrite) {
        await _backend.rewrite([
          for (final entry in _encoded.entries)
            if (!removed.contains(entry.key) && !encoded.containsKey(entry.key))
              entry.value,
          ...encoded.values,
        ]);
      } else {
        await _backend.appendAll(encoded.values.toList());
      }

      // ファイルの保存に成功してから差分を公開する。全件の複製や索引の
      // 再構築を避け、単件の返信ではその報告と返信 ID だけを書き換える。
      final earliestRemoved = removed.any(
        (id) => _records[id]?.retainUntil == _nextExpiry,
      );
      for (final id in removed) {
        _ackIds.remove(_records.remove(id)?.ack?.msgId);
        _encoded.remove(id);
      }
      for (final entry in changed.entries) {
        _ackIds.remove(_records[entry.key]?.ack?.msgId);
        _records[entry.key] = entry.value;
        final ack = entry.value.ack;
        if (ack != null) _ackIds.add(ack.msgId);
        if (_nextExpiry == null || entry.value.retainUntil < _nextExpiry!) {
          _nextExpiry = entry.value.retainUntil;
        }
      }
      _encoded.addAll(encoded);
      if (earliestRemoved) _updateNextExpiry();
      _liveBytes = liveBytes;
      _journalBytes = rewrite ? liveBytes : _journalBytes + appendedBytes;
      _needsRewrite = false;
      lastError = null;
      notifyListeners();
    } catch (e) {
      // 途中まで追記された可能性があるので、次の成功書き込みでは既知の
      // 状態から全置換する。失敗した変更は公開しない。
      if (writeStarted) _needsRewrite = true;
      lastError = '$e';
      notifyListeners();
      rethrow;
    }
  }

  void _updateNextExpiry() {
    _nextExpiry = null;
    for (final record in _records.values) {
      if (_nextExpiry == null || record.retainUntil < _nextExpiry!) {
        _nextExpiry = record.retainUntil;
      }
    }
  }

  void _checkCapacity(int records, int bytes) {
    if (records > maxRecords || bytes > maxBytes) {
      throw const StoreCapacityException(
        '本部の 記録が いっぱいです。記録を コピーして 保管し、係の人に 相談してください。新しい 記録は 保存できていません。',
      );
    }
  }

  static int _framedSize(Uint8List bytes) => bytes.length + 4;

  static bool _shouldCompact(int journalBytes, int liveBytes) {
    final slack = (liveBytes ~/ 4).clamp(
      _minCompactionSlackBytes,
      _maxCompactionSlackBytes,
    );
    return journalBytes - liveBytes >= slack;
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
