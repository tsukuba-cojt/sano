/// ホーム上部の状態帯（1 行＋必要なときだけ注意 1 行、docs/08 C07）。
library;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../format.dart';

/// 「近くの人と 交換中 ・ 近くの端末 2台 ・ 最後に 交換したのは 10月1日 午後3時（14日前）」。
///
/// 停止中は赤文字「交換が 止まっています」と「再開する」ボタン。
/// [notice] があれば 2 行目に注意を出し、右に「画面を 点けたままにする（30分）」を置く。
/// 中継役（[relayMode]）のときは 24pt の 3 行に置き換える（C04）。
class MeshStatusBar extends StatelessWidget {
  const MeshStatusBar({
    super.key,
    required this.running,
    required this.nearbyCount,
    this.lastSyncAt,
    this.lastReceivedAt,
    this.now,
    required this.onResume,
    this.poweredOn = true,
    this.permissionDenied = false,
    this.notice,
    this.keepScreenOnUntil,
    this.onKeepScreenOn,
    this.onStopKeepScreenOn,
    this.relayMode = false,
    this.lastSentAt,
    this.lastSentCount = 0,
    this.storeCount = 0,
    this.groupSummary = '',
    this.inForeground = true,
    this.alertLine,
    this.onShowLarge,
  });

  final bool running;
  final int nearbyCount;

  /// 最後に同期が完了した時刻。
  final DateTime? lastSyncAt;

  /// 最後にお知らせを受け取った時刻。
  final DateTime? lastReceivedAt;

  /// 現在時刻（相対表示用。省略時は DateTime.now()）。
  final DateTime? now;
  final VoidCallback? onResume;

  /// Bluetooth がオンか（[running] でもオフなら注意を出す）。
  final bool poweredOn;

  /// 権限が拒否されているか。
  final bool permissionDenied;

  /// 注意行（null なら出さない）。
  final String? notice;

  /// 「画面を 点けたままにする」の期限。していなければ null。
  final DateTime? keepScreenOnUntil;
  final VoidCallback? onKeepScreenOn;
  final VoidCallback? onStopKeepScreenOn;

  /// 中継役の大きな表示。
  final bool relayMode;
  final DateTime? lastSentAt;

  /// 最後の交換で渡した件数（C18）。0 なら出さない。
  final int lastSentCount;
  final int storeCount;
  final String groupSummary;
  final bool inForeground;

  /// 中継役表示に足す「避難の お知らせが 届きました」。
  final String? alertLine;
  final VoidCallback? onShowLarge;

  static const TextStyle _danger = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.bold,
    height: 1.5,
    color: KairanColors.dangerText,
  );

  /// 「10月1日 午後3時（14日前）」。当日は時刻だけ。
  static String describeTime(DateTime t, DateTime now) {
    final sameDay = t.year == now.year && t.month == now.month && t.day == now.day;
    if (sameDay) {
      return formatTimeJa(t);
    }
    final days = now.difference(t).inDays;
    final suffix = days >= 1 ? '（$days日前）' : '';
    return '${formatShortDateTimeJa(t)}$suffix';
  }

  @override
  Widget build(BuildContext context) {
    final nowTime = now ?? DateTime.now();
    final Widget content;
    if (!running) {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('交換が 止まっています', style: _danger),
          if (onResume != null) ...[
            const SizedBox(height: KairanSizes.gap),
            SizedBox(
              height: KairanSizes.minTapTarget,
              child: OutlinedButton(
                onPressed: onResume,
                style: const ButtonStyle(
                  minimumSize: WidgetStatePropertyAll(Size(48, 48)),
                  padding: WidgetStatePropertyAll(
                    EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  ),
                ),
                child: const Text('再開する'),
              ),
            ),
          ],
        ],
      );
    } else if (permissionDenied) {
      content = const Text(
        'Bluetooth の 許可が ありません。設定で 許可してください。',
        style: _danger,
      );
    } else if (!poweredOn) {
      content = const Text(
        'Bluetooth が 切れています。Bluetooth を 入れてください。',
        style: _danger,
      );
    } else if (relayMode) {
      content = _relayContent(nowTime);
    } else {
      final last = lastSyncAt;
      final lastText = last == null
          ? 'まだ だれとも 交換していません'
          : '最後に 交換したのは ${describeTime(last, nowTime)}';
      final noticeText = notice;
      final keepUntil = keepScreenOnUntil;
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '近くの人と 交換中 ・ 近くの端末 ${formatCountJa(nearbyCount, '台')} ・ $lastText',
            style: KairanTextStyles.meta,
          ),
          if (keepUntil != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '画面を 点けたままです（残り ${_remainingMinutes(keepUntil, nowTime)}分）',
                    style: KairanTextStyles.meta,
                  ),
                ),
                TextButton(
                  onPressed: onStopKeepScreenOn,
                  child: const Text('やめる'),
                ),
              ],
            ),
          ] else if (noticeText != null) ...[
            const SizedBox(height: 4),
            Text(noticeText, style: KairanTextStyles.meta),
            if (onKeepScreenOn != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: onKeepScreenOn,
                  child: const Text('画面を 点けたままにする（30分）'),
                ),
              ),
          ],
        ],
      );
    }
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        width: double.infinity,
        color: KairanColors.band,
        padding: const EdgeInsets.symmetric(
          horizontal: KairanSizes.pagePadding,
          vertical: 8,
        ),
        child: content,
      ),
    );
  }

  static int _remainingMinutes(DateTime until, DateTime now) {
    final m = until.difference(now).inMinutes;
    return m < 0 ? 0 : m;
  }

  Widget _relayContent(DateTime nowTime) {
    const big = TextStyle(
      fontSize: 24,
      fontWeight: FontWeight.bold,
      height: 1.4,
      color: KairanColors.text,
    );
    final received = lastReceivedAt;
    final sent = lastSentAt;
    final line2 = StringBuffer()
      ..write(received == null
          ? 'まだ 受け取っていません'
          : '最後に 受け取ったのは ${describeTime(received, nowTime)}')
      ..write(' ・ ')
      ..write(sent == null
          ? 'まだ 渡していません'
          : '最後に 渡したのは ${describeTime(sent, nowTime)}'
              '${lastSentCount > 0 ? '（${formatCountJa(lastSentCount, '件')}）' : ''}');
    final alert = alertLine;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          inForeground
              ? '中継役として 動いています ・ 近くの端末 ${formatCountJa(nearbyCount, '台')}'
              : 'アプリを 開いてください',
          style: big,
        ),
        Text(line2.toString(), style: big),
        Text(
          '保存 ${formatCountJa(storeCount, '件')}${groupSummary.isEmpty ? '' : '（$groupSummary）'}',
          style: big,
        ),
        if (alert != null) Text(alert, style: big.copyWith(color: KairanColors.dangerText)),
        if (onShowLarge != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: onShowLarge,
              child: const Text('大きく 表示する'),
            ),
          ),
      ],
    );
  }
}
