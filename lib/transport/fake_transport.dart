/// テスト用のインメモリ・決定論トランスポート。
///
/// [FakeRadio] が「電波」を模擬し、複数の [FakeTransport] を結ぶ。
/// 配送はすべて 1 本の FIFO キューで順に処理するため、テストは
/// `await radio.settle()` で静止状態まで進められる。時間は [FakeClock]
/// （仮想時計）で進め、実時間は一切使わない。
library;

import 'dart:async';
import 'dart:typed_data';

import '../mesh/transport.dart';

/// 仮想時計。`now()` とタイマー生成関数を提供し、[elapse] で進める。
class FakeClock {
  FakeClock({int startEpochSeconds = 0})
      : _nowMillis = startEpochSeconds * 1000;

  int _nowMillis;
  int _sequence = 0;
  final List<_FakeTimer> _timers = <_FakeTimer>[];

  /// 現在のエポック秒。
  int now() => _nowMillis ~/ 1000;

  /// 現在のミリ秒。
  int get nowMillis => _nowMillis;

  /// 待機中のタイマー数。
  int get pendingTimers => _timers.where((t) => t.isActive).length;

  /// タイマーを作る（[Timer] 互換）。
  Timer createTimer(Duration duration, void Function() callback) {
    final timer = _FakeTimer(
      this,
      dueMillis: _nowMillis + duration.inMilliseconds,
      sequence: _sequence++,
      callback: callback,
    );
    _timers.add(timer);
    return timer;
  }

  /// 時刻を [duration] だけ進め、期限の来たタイマーを順に発火させる。
  /// 各発火の前後で [settle] を呼んで非同期処理を静止させる。
  Future<void> elapse(Duration duration,
      {Future<void> Function()? settle}) async {
    final target = _nowMillis + duration.inMilliseconds;
    while (true) {
      await settle?.call();
      _FakeTimer? next;
      for (final t in _timers) {
        if (!t.isActive || t.dueMillis > target) {
          continue;
        }
        if (next == null ||
            t.dueMillis < next.dueMillis ||
            (t.dueMillis == next.dueMillis && t.sequence < next.sequence)) {
          next = t;
        }
      }
      if (next == null) {
        break;
      }
      if (next.dueMillis > _nowMillis) {
        _nowMillis = next.dueMillis;
      }
      next._fire();
    }
    _nowMillis = target;
    _timers.removeWhere((t) => !t.isActive);
    await settle?.call();
  }

  void _remove(_FakeTimer timer) {
    _timers.remove(timer);
  }
}

class _FakeTimer implements Timer {
  _FakeTimer(
    this._clock, {
    required this.dueMillis,
    required this.sequence,
    required this._callback,
  });

  final FakeClock _clock;
  final int dueMillis;
  final int sequence;
  final void Function() _callback;
  bool _active = true;
  int _tick = 0;

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;

  @override
  void cancel() {
    _active = false;
    _clock._remove(this);
  }

  void _fire() {
    if (!_active) {
      return;
    }
    _active = false;
    _tick = 1;
    _clock._remove(this);
    _callback();
  }
}

class _LinkEnd {
  _LinkEnd({
    required this.owner,
    required this.linkId,
    required this.maxChunk,
  });

  final FakeTransport owner;
  final int linkId;
  final int maxChunk;
  late _LinkEnd peer;

  /// close() が呼ばれた（以後の送信は失敗する）。
  bool closing = false;

  /// LinkClosed を配送済み。
  bool closed = false;
}

/// 複数の [FakeTransport] を結ぶ模擬電波。
class FakeRadio {
  FakeRadio({FakeClock? clock, this.defaultMaxChunk = 244})
      : clock = clock ?? FakeClock();

  /// 仮想時計。[FakeTransport] を使うノードの `now` / `createTimer` に渡す。
  final FakeClock clock;

  /// 新しいリンクの maxChunk 既定値。
  final int defaultMaxChunk;

  /// 接続可否のフック。null なら常に許可。
  bool Function(FakeTransport from, FakeTransport to)? allowConnect;

  /// 到達不能として扱う peerId（接続失敗を模擬する）。
  final Set<String> unreachable = <String>{};

  /// 接続を指定の理由で断る peerId（ネイティブ側の「busy」などを模擬する）。
  final Map<String, String> failWith = <String, String>{};

  final Map<String, FakeTransport> _transports = <String, FakeTransport>{};
  final List<void Function()> _queue = <void Function()>[];
  bool _draining = false;
  int _nextLinkId = 1;

  /// 送ったチャンクの総バイト数（全リンク）。
  int bytesSent = 0;

  /// 送ったチャンク数。
  int chunksSent = 0;

  /// 開いたリンク数。
  int linksOpened = 0;

  /// 動作ログ（デバッグ用）。
  final List<String> log = <String>[];

  /// 登録済みトランスポート。
  Map<String, FakeTransport> get transports => Map.unmodifiable(_transports);

  /// [peerId] の [FakeTransport] を作って登録する。
  FakeTransport createTransport(String peerId) {
    if (_transports.containsKey(peerId)) {
      throw ArgumentError.value(peerId, 'peerId', '登録済みです');
    }
    return FakeTransport(this, peerId);
  }

  void _register(FakeTransport t) {
    _transports[t.peerId] = t;
  }

  /// [a] と [b] を互いに発見させる（両方に PeerDiscovered を配送する）。
  /// 登録されていない peerId が含まれていれば、登録済みの側だけに届く
  /// （サービスを持たない端末の模擬に使える）。
  void bringNear(String a, String b, {bool viaApple = false, int rssi = -60}) {
    discover(a, b, viaApple: viaApple, rssi: rssi);
    discover(b, a, viaApple: viaApple, rssi: rssi);
  }

  /// [observer] に [peerId] の PeerDiscovered を配送する（片方向）。
  void discover(String observer, String peerId,
      {bool viaApple = false, int rssi = -60}) {
    final t = _transports[observer];
    if (t == null) {
      return;
    }
    _schedule(() {
      if (!t.running) {
        return;
      }
      t._emit(PeerDiscovered(peerId: peerId, rssi: rssi, viaApple: viaApple));
    });
  }

  /// キューが空になるまで待つ（非同期処理の静止）。
  Future<void> settle() async {
    do {
      await Future<void>.delayed(Duration.zero);
    } while (_queue.isNotEmpty || _draining);
  }

  /// 仮想時計を進め、途中のタイマー発火ごとに [settle] する。
  Future<void> elapse(Duration duration) => clock.elapse(duration, settle: settle);

  void _schedule(void Function() action) {
    _queue.add(action);
    if (!_draining) {
      _draining = true;
      scheduleMicrotask(_drain);
    }
  }

  void _drain() {
    try {
      while (_queue.isNotEmpty) {
        final action = _queue.removeAt(0);
        action();
      }
    } finally {
      _draining = false;
      if (_queue.isNotEmpty) {
        _draining = true;
        scheduleMicrotask(_drain);
      }
    }
  }

  void _connect(FakeTransport from, String targetId) {
    _schedule(() {
      final target = _transports[targetId];
      if (!from.running) {
        return;
      }
      String? failure = failWith[targetId];
      if (failure != null) {
        // そのまま下で linkClosed にする。
      } else if (target == null) {
        failure = 'service_not_found';
      } else if (!target.running || unreachable.contains(targetId)) {
        failure = 'timeout';
      } else if (allowConnect != null && !allowConnect!(from, target)) {
        failure = 'refused';
      }
      if (failure != null) {
        log.add('connect ${from.peerId} -> $targetId failed: $failure');
        from._emit(LinkClosed(linkId: -1, peerId: targetId, reason: failure));
        return;
      }
      final a = _LinkEnd(
          owner: from, linkId: _nextLinkId++, maxChunk: defaultMaxChunk);
      final b = _LinkEnd(
          owner: target!, linkId: _nextLinkId++, maxChunk: defaultMaxChunk);
      a.peer = b;
      b.peer = a;
      from._links[a.linkId] = a;
      target._links[b.linkId] = b;
      linksOpened++;
      log.add('link ${from.peerId}#${a.linkId} <-> $targetId#${b.linkId}');
      from._emit(LinkOpened(
          linkId: a.linkId,
          peerId: targetId,
          maxChunk: a.maxChunk,
          initiator: true));
      target._emit(LinkOpened(
          linkId: b.linkId,
          peerId: from.peerId,
          maxChunk: b.maxChunk,
          initiator: false));
    });
  }

  void _send(_LinkEnd from, Uint8List data) {
    final copy = Uint8List.fromList(data);
    bytesSent += copy.length;
    chunksSent++;
    _schedule(() {
      final to = from.peer;
      if (to.closed || from.closed) {
        return;
      }
      to.owner._emit(LinkData(linkId: to.linkId, data: copy));
    });
  }

  void _close(_LinkEnd end, String reason) {
    if (end.closing) {
      return;
    }
    end.closing = true;
    end.peer.closing = true;
    _schedule(() {
      for (final e in [end, end.peer]) {
        if (e.closed) {
          continue;
        }
        e.closed = true;
        e.owner._links.remove(e.linkId);
        e.owner._emit(LinkClosed(
            linkId: e.linkId, peerId: e.peer.owner.peerId, reason: reason));
      }
      log.add('closed ${end.owner.peerId}#${end.linkId} ($reason)');
    });
  }
}

/// [FakeRadio] 上の 1 端末分のトランスポート。
class FakeTransport implements Transport {
  FakeTransport(this.radio, this.peerId) {
    radio._register(this);
  }

  final FakeRadio radio;

  /// 他の端末から見た自分の peerId。
  final String peerId;

  final StreamController<TransportEvent> _events =
      StreamController<TransportEvent>.broadcast(sync: true);
  final Map<int, _LinkEnd> _links = <int, _LinkEnd>{};

  bool _running = false;
  bool _lowPower = false;
  TransportConfig? _config;

  bool get running => _running;
  bool get lowPower => _lowPower;
  TransportConfig? get config => _config;

  /// 開いているリンク ID。
  List<int> get openLinkIds => List.unmodifiable(_links.keys);

  @override
  Stream<TransportEvent> get events => _events.stream;

  void _emit(TransportEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  @override
  Future<void> start(TransportConfig config) async {
    _config = config;
    _lowPower = config.lowPower;
    _running = true;
    radio._schedule(() {
      _emit(TransportState(
        poweredOn: true,
        scanning: true,
        advertising: true,
        permission: 'granted',
      ));
    });
  }

  @override
  Future<void> stop() async {
    _running = false;
    for (final end in _links.values.toList()) {
      radio._close(end, 'stopped');
    }
    radio._schedule(() {
      _emit(const TransportState(
        poweredOn: true,
        scanning: false,
        advertising: false,
        permission: 'granted',
      ));
    });
  }

  @override
  Future<void> setLowPower(bool lowPower) async {
    _lowPower = lowPower;
  }

  @override
  Future<void> connect(String peerId) async {
    if (!_running) {
      throw StateError('トランスポートが開始されていません');
    }
    radio._connect(this, peerId);
  }

  @override
  Future<void> send(int linkId, Uint8List data) async {
    final end = _links[linkId];
    if (end == null || end.closing) {
      throw StateError('リンク $linkId は閉じています');
    }
    if (data.length > end.maxChunk) {
      throw ArgumentError.value(
          data.length, 'data', 'maxChunk ${end.maxChunk} を超えています');
    }
    radio._send(end, data);
  }

  @override
  Future<void> close(int linkId) async {
    final end = _links[linkId];
    if (end == null) {
      return;
    }
    radio._close(end, 'closed');
  }

  /// テスト用: 相手側に不正なバイト列を直接流す（自分の送信としては数えない）。
  void injectRaw(int linkId, Uint8List data) {
    final end = _links[linkId];
    if (end == null) {
      throw StateError('リンク $linkId は閉じています');
    }
    radio._send(end, data);
  }

  /// ストリームを閉じる（テスト後片付け用）。
  Future<void> dispose() async {
    await _events.close();
  }
}
