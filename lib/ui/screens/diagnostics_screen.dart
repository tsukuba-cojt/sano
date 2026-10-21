/// 通信の状態（診断）画面。
library;

import 'package:flutter/material.dart';
import 'package:kairanban/app/app_controller.dart';
import 'package:kairanban/core/envelope.dart';
import 'package:kairanban/core/epoch.dart';
import 'package:kairanban/core/ids.dart';

import '../../app/theme.dart';
import '../format.dart';
import '../widgets/big_button.dart';
import '../widgets/kairan_app_bar.dart';
import '../widgets/section.dart';

class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  late final Listenable _listenable;

  AppController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _listenable = Listenable.merge([_c.node, _c.store, _c.groups]);
  }

  static String _yesNo(bool v, String yes, String no) => v ? yes : no;

  static String _permissionLabel(String permission) {
    switch (permission) {
      case 'granted':
        return '許可されています';
      case 'denied':
        return '許可されていません';
      default:
        return 'まだ わかりません';
    }
  }

  static String _clockLabel(int? offset) {
    if (offset == null) {
      return 'まだ わかりません';
    }
    final abs = offset.abs();
    if (abs < 60) {
      return 'ほぼ 同じ';
    }
    final String amount;
    if (abs >= 86400) {
      amount = '${abs ~/ 86400}日';
    } else if (abs >= 3600) {
      amount = '${abs ~/ 3600}時間';
    } else {
      amount = '${abs ~/ 60}分';
    }
    return offset > 0 ? 'この端末が $amount 遅れています' : 'この端末が $amount 進んでいます';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const KairanAppBar(title: '通信の状態', showBack: true),
      body: ListenableBuilder(
        listenable: _listenable,
        builder: (context, _) {
          final node = _c.node;
          final store = _c.store;
          final now = _c.now;
          final lastReceived = node.lastReceivedAt;
          final lastSync = node.lastSyncAt;
          final log = node.recentLog.reversed.toList();
          final groups = _c.groups.groups;
          var relayOnly = 0;
          var tombstones = 0;
          for (final m in store.all) {
            if (m.kind == MessageKind.tombstone) {
              tombstones++;
            } else if (m.kind == MessageKind.notice &&
                !_c.groups.codes.contains(m.groupId)) {
              relayOnly++;
            }
          }
          return PageBody(
            children: [
              SecondaryButton(
                label: '更新',
                icon: Icons.refresh,
                onPressed: () => setState(() {}),
              ),
              const SectionTitle('今の 状態'),
              CardBox(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LabelValueRow(
                      '通信',
                      _yesNo(node.running, '動いています', '止まっています'),
                    ),
                    if (node.relayMode) const LabelValueRow('中継役', '動いています'),
                    LabelValueRow(
                      'Bluetooth',
                      _yesNo(node.poweredOn, 'オン', 'オフ'),
                    ),
                    LabelValueRow(
                      '探す（スキャン）',
                      _yesNo(node.scanning, 'しています', 'していません'),
                    ),
                    LabelValueRow(
                      '知らせる（広告）',
                      _yesNo(node.advertising, 'しています', 'していません'),
                    ),
                    LabelValueRow('許可', _permissionLabel(node.permission)),
                    LabelValueRow('近くの端末', formatCountJa(node.nearbyCount, '台')),
                    LabelValueRow('交換中', formatCountJa(node.activeSessions, '件')),
                    LabelValueRow(
                      '交換した回数',
                      formatCountJa(node.totalSessions, '回'),
                    ),
                    LabelValueRow(
                      '受け取った件数',
                      formatCountJa(node.totalMessagesReceived, '件'),
                    ),
                    LabelValueRow(
                      '送った件数',
                      formatCountJa(node.totalMessagesSent, '件'),
                    ),
                    LabelValueRow(
                      '最後に受け取った',
                      lastReceived == null
                          ? 'まだ ありません'
                          : formatDateTimeJa(dateTimeFromEpoch(lastReceived)),
                    ),
                    LabelValueRow(
                      '最後に交換した',
                      lastSync == null
                          ? 'まだ ありません'
                          : formatDateTimeJa(dateTimeFromEpoch(lastSync)),
                    ),
                    LabelValueRow(
                      '近くの端末との 時計の差',
                      _clockLabel(node.clockOffsetSeconds),
                    ),
                  ],
                ),
              ),
              const SectionTitle('保存'),
              CardBox(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LabelValueRow('保存件数', formatCountJa(store.count, '件')),
                    for (final g in groups)
                      LabelValueRow(
                        displayGroupName(g.name),
                        formatCountJa(
                          store.visibleNotices(now: now, groupIds: {g.code}).length,
                          '件',
                        ),
                      ),
                    LabelValueRow(
                      'ほかのグループ（中継のみ）',
                      formatCountJa(relayOnly, '件'),
                    ),
                    LabelValueRow('取り消し', formatCountJa(tombstones, '件')),
                    LabelValueRow(
                      '表示できない お知らせ',
                      '${formatCountJa(store.opaqueCount, '件')}（新しい 版）',
                    ),
                    LabelValueRow('ノード ID', hexOf(_c.nodeId), selectable: true),
                    LabelValueRow(
                      '今の時刻',
                      formatDateTimeJa(dateTimeFromEpoch(now)),
                    ),
                  ],
                ),
              ),
              const SectionTitle('最近の 交換の 記録'),
              if (log.isEmpty)
                const Text('まだ 記録は ありません。', style: KairanTextStyles.metaSecondary)
              else
                CardBox(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final line in log)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(line, style: KairanTextStyles.meta),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 16),
            ],
          );
        },
      ),
    );
  }
}
