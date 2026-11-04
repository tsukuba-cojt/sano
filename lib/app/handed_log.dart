/// 「この端末から 渡した 台数」の記録（docs/08 C18）。
///
/// 自分の投稿（公式端末なら同じグループの公式投稿も）について、直接渡した相手を
/// ノード ID の先頭 2 バイトで覚える。封筒には載せず、中継もしない（端末の中だけ）。
/// サーバがないので、その先に広がった数は分からない（下限だけを見せる）。
library;

/// 1 件のお知らせについて覚える相手の上限。
const int kHandedPeersPerMessage = 64;

/// 覚えるお知らせの上限。超えたら最後に渡したのが古いものから忘れる。
const int kHandedMessages = 1000;

/// 「渡した 相手」（全体）として覚える台数の上限。
const int kHandedPeersTotal = 1000;

/// 1 件のお知らせを渡した台数と、最後に渡した時刻。
class HandedInfo {
  const HandedInfo(this.devices, this.lastAt);

  final int devices;

  /// 最後に渡した時刻（エポック秒）。まだ渡していなければ null。
  final int? lastAt;
}

class HandedLog {
  final Map<int, ({Set<int> peers, int lastAt})> _entries =
      <int, ({Set<int> peers, int lastAt})>{};
  final Set<int> _allPeers = <int>{};
  int? _lastAt;
  int _lastCount = 0;

  /// これまでに何かを渡した相手の台数（上限 [kHandedPeersTotal]）。
  int get deviceCount => _allPeers.length;

  /// 最後に渡した時刻（エポック秒）。
  int? get lastAt => _lastAt;

  /// 最後の交換で渡した件数。
  int get lastCount => _lastCount;

  /// ノード ID（16 進）を 2 バイトに縮める。
  static int shortOf(String nodeHex) =>
      int.parse(nodeHex.substring(0, 4), radix: 16);

  /// [peerHex] に [msgIds] を渡した。[tracked] が真のものだけ台数を数える。
  void record({
    required String peerHex,
    required List<int> msgIds,
    required int at,
    required bool Function(int msgId) tracked,
  }) {
    if (msgIds.isEmpty) {
      return;
    }
    final peer = shortOf(peerHex);
    _lastAt = at;
    _lastCount = msgIds.length;
    if (_allPeers.length < kHandedPeersTotal) {
      _allPeers.add(peer);
    }
    for (final id in msgIds) {
      if (!tracked(id)) {
        continue;
      }
      final e = _entries[id];
      final peers = e?.peers ?? <int>{};
      if (peers.length < kHandedPeersPerMessage) {
        peers.add(peer);
      }
      _entries[id] = (peers: peers, lastAt: at);
    }
    if (_entries.length > kHandedMessages) {
      final oldest = _entries.entries.toList()
        ..sort((a, b) => a.value.lastAt.compareTo(b.value.lastAt));
      for (final e in oldest.take(_entries.length - kHandedMessages)) {
        _entries.remove(e.key);
      }
    }
  }

  /// [msgId] を渡した台数。まだなら 0 台。
  HandedInfo of(int msgId) {
    final e = _entries[msgId];
    return e == null
        ? const HandedInfo(0, null)
        : HandedInfo(e.peers.length, e.lastAt);
  }

  /// [keep] が偽のもの（保存から消えたお知らせ）を忘れる。忘れたら true。
  bool prune(bool Function(int msgId) keep) {
    final before = _entries.length;
    _entries.removeWhere((id, _) => !keep(id));
    return _entries.length != before;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'messages': [
          for (final e in _entries.entries)
            {
              'id': e.key.toRadixString(16),
              'peers': e.value.peers.toList(),
              'at': e.value.lastAt,
            },
        ],
        'peers': _allPeers.toList(),
        'lastAt': _lastAt,
        'lastCount': _lastCount,
      };

  static HandedLog fromJson(Map<String, Object?> json) {
    final log = HandedLog();
    for (final raw in (json['messages'] as List?) ?? const []) {
      final m = raw as Map<String, Object?>;
      final id = int.tryParse(m['id'] as String? ?? '', radix: 16);
      final at = m['at'] as int?;
      if (id == null || at == null) {
        continue;
      }
      log._entries[id] = (
        peers: {for (final p in (m['peers'] as List?) ?? const []) p as int},
        lastAt: at,
      );
    }
    for (final p in (json['peers'] as List?) ?? const []) {
      log._allPeers.add(p as int);
    }
    log._lastAt = json['lastAt'] as int?;
    log._lastCount = (json['lastCount'] as int?) ?? 0;
    return log;
  }
}
