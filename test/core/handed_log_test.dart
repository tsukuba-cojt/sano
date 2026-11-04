import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/app/handed_log.dart';

void main() {
  test('相手ごとに 1 台と数え、上限で打ち切り、JSON で戻せる', () {
    final log = HandedLog();
    for (var i = 0; i < 70; i++) {
      final hex = '${i.toRadixString(16).padLeft(4, '0')}aabbccddeeff';
      log.record(peerHex: hex, msgIds: [1, 2], at: 100 + i, tracked: (id) => id == 1);
    }
    log.record(peerHex: '0000aabbccddeeff', msgIds: [1], at: 500, tracked: (_) => true);
    expect(log.of(1).devices, kHandedPeersPerMessage);
    expect(log.of(1).lastAt, 500);
    expect(log.of(2).devices, 0); // 数える対象ではない
    expect(log.deviceCount, 70);
    expect(log.lastCount, 1);

    final back = HandedLog.fromJson(log.toJson());
    expect(back.of(1).devices, kHandedPeersPerMessage);
    expect(back.deviceCount, 70);
    expect(back.lastAt, 500);

    expect(back.prune((id) => id != 1), isTrue);
    expect(back.of(1).devices, 0);
  });

  test('覚えるお知らせが上限を超えたら、最後に渡したのが古いものから忘れる', () {
    final log = HandedLog();
    for (var i = 0; i < kHandedMessages + 5; i++) {
      log.record(peerHex: '1234aabbccddeeff', msgIds: [i], at: i, tracked: (_) => true);
    }
    expect(log.of(0).devices, 0);
    expect(log.of(4).devices, 0);
    expect(log.of(5).devices, 1);
    expect(log.of(kHandedMessages + 4).devices, 1);
  });
}
