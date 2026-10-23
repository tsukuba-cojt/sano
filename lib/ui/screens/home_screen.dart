/// お知らせ一覧（ホーム）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kairanban/app/app_controller.dart';
import 'package:kairanban/core/categories.dart';
import 'package:kairanban/core/envelope.dart';
import 'package:kairanban/core/epoch.dart';
import 'package:kairanban/core/report.dart';
import 'package:kairanban/mesh/message_store.dart';

import '../../app/theme.dart';
import '../format.dart';
import '../routes.dart';
import '../widgets/big_button.dart';
import '../widgets/dialogs.dart';
import '../widgets/kairan_app_bar.dart';
import '../widgets/notice_card.dart';
import '../widgets/section.dart';
import '../widgets/status_bar.dart';

/// 30 日以上無交換の警告（C07）。
const int _kNoSyncWarnSeconds = 30 * 24 * 3600;

/// 近くに端末が 0 台のまま注意を出すまでの秒数（C07）。
const int _kNoPeerWarnSeconds = 30 * 60;

/// 最後の同期から新着がないと注意を出すまでの秒数（C07）。
const int _kStaleWarnSeconds = 6 * 3600;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// セグメントの「すべて」を表す値（参加コードは 100000 以上）。
  static const int _allGroups = 0;

  int _groupFilter = _allGroups;
  late final Listenable _listenable;
  int _urgentSeen = 0;

  AppController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _listenable = Listenable.merge([_c, _c.store, _c.node, _c.groups]);
  }

  Future<void> _refresh() async {
    try {
      await _c.store.purgeExpired(_c.now);
      await _c.markVisibleRead();
    } catch (_) {
      // 期限切れの掃除に失敗しても一覧の再描画は行う。
    }
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _resume() async {
    try {
      await _c.startMesh();
    } catch (e) {
      if (!mounted) {
        return;
      }
      await showMessageDialog(
        context,
        title: '再開できませんでした',
        message: describeError(e),
      );
    }
  }

  Future<void> _keepScreenOn() async {
    final battery = _c.battery;
    if (battery != null && !battery.charging && battery.level < 20) {
      final ok = await showConfirmDialog(
        context,
        title: '電池が 少ないです',
        message: '画面を 点けたままにすると 電池を 使います。続けますか？',
        confirmLabel: '続ける',
      );
      if (!ok || !mounted) {
        return;
      }
    }
    await _c.keepScreenOn();
  }

  /// 注意行（C07 の優先順で 1 行だけ）。
  String? _noticeLine() {
    final node = _c.node;
    final now = _c.now;
    final lastSync = _lastSyncAt();
    if (lastSync != null && now - lastSync >= _kNoSyncWarnSeconds) {
      return '30日以上 だれとも 交換していません。人の 集まる 場所で アプリを 開いてください。人が 少ない 地域では ふつうです';
    }
    if (node.running && node.nearbyCount == 0) {
      final since = node.lastPeerSeenAt ?? node.startedAt;
      if (since != null && now - since >= _kNoPeerWarnSeconds) {
        return defaultTargetPlatform == TargetPlatform.iOS
            ? 'iPhone どうしは 画面が 消えていると 見つけられません。画面を 点けて 1分 待ってみてください'
            : '近くに 端末が 見つかりません。人の 集まる 場所で 画面を 点けて 待ってみてください';
      }
    }
    if (lastSync != null &&
        now - lastSync >= _kStaleWarnSeconds &&
        _c.groups.groups.isNotEmpty) {
      return '6時間 以上 新しい お知らせが 届いていません。外に 出るときは 画面を 点けて 手に 持つと 届きやすく なります';
    }
    if (node.lowPower) {
      return '電池を 長持ち させるため、ゆっくり 交換しています';
    }
    return null;
  }

  int? _lastSyncAt() {
    final a = _c.settings.lastSyncAt;
    final b = _c.node.lastSyncAt;
    if (a == null) {
      return b;
    }
    if (b == null) {
      return a;
    }
    return a > b ? a : b;
  }

  void _triggerUrgentHaptics(int count) {
    if (count <= _urgentSeen) {
      _urgentSeen = count;
      return;
    }
    _urgentSeen = count;
    for (var i = 0; i < 3; i++) {
      Timer(Duration(milliseconds: 300 * i), () {
        HapticFeedback.heavyImpact();
      });
    }
  }

  int _sosSeen = 0;

  /// 返事をしていない SOS が増えたら 3 回振動する（本部・スタッフの端末）。
  void _triggerSosHaptics(int count) {
    if (count > _sosSeen) {
      for (var i = 0; i < 3; i++) {
        Timer(Duration(milliseconds: 300 * i), () {
          HapticFeedback.heavyImpact();
        });
      }
    }
    _sosSeen = count;
  }

  Future<void> _openUrgent() async {
    final ids = _c.foregroundUrgentIds;
    if (ids.isEmpty) {
      return;
    }
    final first = ids.first;
    _c.acknowledgeUrgent();
    await openNoticeDetail(context, _c, first);
  }

  Future<void> _showLarge() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _LargeStatusScreen(controller: _c),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const KairanAppBar(title: 'お知らせ'),
      body: ListenableBuilder(
        listenable: _listenable,
        builder: (context, _) {
          final node = _c.node;
          final settings = _c.settings;
          final groups = _c.groups.groups;
          final nowTime = dateTimeFromEpoch(_c.now);
          final lastSync = _lastSyncAt();
          final lastReceived = node.lastReceivedAt;
          final lastSent = node.lastSentAt;
          final keepUntil = _c.keepScreenOnUntil;
          final urgentIds = _c.foregroundUrgentIds;
          _triggerUrgentHaptics(urgentIds.length);
          String groupSummary = '';
          if (groups.isNotEmpty) {
            final g = groups.first;
            final n = _c.store
                .visibleNotices(now: _c.now, groupIds: {g.code})
                .length;
            groupSummary = '${displayGroupName(g.name)} ${formatCountJa(n, '件')}';
          }
          final statusBar = MeshStatusBar(
            running: node.running,
            nearbyCount: node.nearbyCount,
            lastSyncAt: lastSync == null ? null : dateTimeFromEpoch(lastSync),
            lastReceivedAt:
                lastReceived == null ? null : dateTimeFromEpoch(lastReceived),
            now: nowTime,
            poweredOn: node.poweredOn,
            permissionDenied: node.permission == 'denied',
            onResume: _resume,
            notice: settings.relayMode ? null : _noticeLine(),
            keepScreenOnUntil:
                keepUntil == null ? null : dateTimeFromEpoch(keepUntil),
            onKeepScreenOn:
                !settings.relayMode && node.running ? _keepScreenOn : null,
            onStopKeepScreenOn: _c.stopKeepScreenOn,
            relayMode: settings.relayMode,
            lastSentAt: lastSent == null ? null : dateTimeFromEpoch(lastSent),
            storeCount: _c.store.count,
            groupSummary: groupSummary,
            inForeground: _c.inForeground,
            alertLine: settings.relayMode && urgentIds.isNotEmpty
                ? '避難の お知らせが 届きました'
                : null,
            onShowLarge: settings.relayMode ? _showLarge : null,
          );
          if (groups.isEmpty) {
            return Column(
              children: [
                statusBar,
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(KairanSizes.pagePadding),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'グループに 参加すると お知らせが 届きます',
                            style: KairanTextStyles.noticeTitle,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            node.running
                                ? '今は 近くの スマホの お知らせを 運ぶだけ しています（近くの端末 ${formatCountJa(node.nearbyCount, '台')}）'
                                : '通信は 止まっています。',
                            style: KairanTextStyles.meta,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 24),
                          PrimaryButton(
                            label: 'グループに 参加する',
                            onPressed: () => openJoinScreen(context, _c),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          }

          final filter =
              _groupFilter != _allGroups && _c.groups.byCode(_groupFilter) == null
                  ? _allGroups
                  : _groupFilter;
          final groupCode = filter == _allGroups ? null : filter;
          final notices = _c.notices(groupCode: groupCode);
          final pinned = _c.pinnedAlerts(groupCode: groupCode);
          final unread = groupCode == null
              ? _c.unreadCount
              : _c.store.unreadCount(now: _c.now, groupIds: {groupCode});
          final training = _c.unreadTrainingCount;
          final canPost = groups.any((g) => g.canPost);
          final canReport = _c.reportGroups.isNotEmpty;
          final seesReports = _c.seesAnyReports;
          final reports = seesReports ? _c.receivedReports() : const <ReportEntry>[];
          final reportSummary = AppController.summarize(reports);
          _triggerSosHaptics(reportSummary.unackedSos);

          return Column(
            children: [
              statusBar,
              if (!settings.relayMode && urgentIds.isNotEmpty)
                _UrgentBand(
                  count: urgentIds.length,
                  onTap: _openUrgent,
                ),
              if (seesReports)
                _ReportsBand(
                  summary: reportSummary,
                  onTap: () => openReportsScreen(context, _c),
                ),
              if (groups.length > 1)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    KairanSizes.pagePadding,
                    12,
                    KairanSizes.pagePadding,
                    0,
                  ),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SegmentedButton<int>(
                      showSelectedIcon: false,
                      segments: [
                        const ButtonSegment(
                          value: _allGroups,
                          label: Text('すべて'),
                        ),
                        for (final g in groups)
                          ButtonSegment(value: g.code, label: Text(displayGroupName(g.name))),
                      ],
                      selected: {filter},
                      onSelectionChanged: (selection) {
                        setState(() => _groupFilter = selection.first);
                      },
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  KairanSizes.pagePadding,
                  8,
                  KairanSizes.pagePadding,
                  0,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        unread > 0
                            ? '新しい お知らせが ${formatCountJa(unread, '件')} あります'
                            : (notices.isEmpty
                                ? 'お知らせは まだ ありません'
                                : '新しい お知らせは ありません'),
                        style: unread > 0
                            ? KairanTextStyles.sectionTitle.copyWith(
                                color: KairanColors.primary,
                              )
                            : KairanTextStyles.meta,
                      ),
                    ),
                    const SizedBox(width: KairanSizes.gap),
                    TextButton(
                      onPressed: _refresh,
                      child: const Text('更新'),
                    ),
                  ],
                ),
              ),
              if (training > 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    KairanSizes.pagePadding,
                    4,
                    KairanSizes.pagePadding,
                    0,
                  ),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    color: KairanColors.band,
                    child: Text(
                      '訓練の お知らせが ${formatCountJa(training, '件')} あります。本物の 災害では ありません',
                      style: KairanTextStyles.meta,
                    ),
                  ),
                ),
              Expanded(
                child: notices.isEmpty && pinned.isEmpty
                    ? const _EmptyNotices()
                    : RefreshIndicator(
                        onRefresh: _refresh,
                        child: _NoticeList(
                          controller: _c,
                          notices: notices,
                          pinned: pinned,
                          now: _c.now,
                          onTap: (msgId) => openNoticeDetail(context, _c, msgId),
                        ),
                      ),
              ),
              if (canPost || canReport)
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      KairanSizes.pagePadding,
                      8,
                      KairanSizes.pagePadding,
                      12,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (canPost)
                          PrimaryButton(
                            label: 'お知らせを 書く',
                            icon: Icons.edit_outlined,
                            onPressed: () => openComposeScreen(context, _c),
                          ),
                        if (canPost && canReport)
                          const SizedBox(height: KairanSizes.gap),
                        if (canReport)
                          SecondaryButton(
                            label: '本部に 知らせる（SOS・安否）',
                            icon: Icons.campaign_outlined,
                            onPressed: () => openReportScreen(context, _c),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// 前面で届いた緊急のお知らせの帯（赤地白文字、C05）。
class _UrgentBand extends StatelessWidget {
  const _UrgentBand({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = count == 1 ? '避難情報が 届きました ▶ 見る' : '避難情報が $count件 届きました ▶ 見る';
    return Semantics(
      button: true,
      label: label,
      onTap: onTap,
      child: ExcludeSemantics(
        child: Material(
          color: KairanColors.danger,
          child: InkWell(
            onTap: onTap,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: KairanSizes.pagePadding,
                vertical: 12,
              ),
              child: Text(
                label,
                style: KairanTextStyles.sectionTitle.copyWith(color: KairanColors.card),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 本部・スタッフの端末の「住民からの 知らせ」帯。返事をしていない SOS があれば赤地。
class _ReportsBand extends StatelessWidget {
  const _ReportsBand({required this.summary, required this.onTap});

  final ReportSummary summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final sos = summary.unackedSos > 0;
    final String label;
    if (sos) {
      label = 'SOS が ${summary.unackedSos}件 あります（まだ 返事を していません） ▶ 見る';
    } else if (summary.total == 0) {
      label = '住民からの 知らせ: まだ ありません ▶ 見る';
    } else {
      label = '住民からの 知らせ: ${summary.line()}'
          '${summary.unacked > 0 ? '（未返事 ${summary.unacked}件）' : ''} ▶ 見る';
    }
    final fg = sos ? KairanColors.card : KairanColors.text;
    return Semantics(
      button: true,
      label: label,
      onTap: onTap,
      child: ExcludeSemantics(
        child: Material(
          color: sos ? KairanColors.danger : KairanColors.selectedFill,
          child: InkWell(
            onTap: onTap,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: KairanSizes.pagePadding,
                vertical: 10,
              ),
              child: Text(
                label,
                style: (sos ? KairanTextStyles.sectionTitle : KairanTextStyles.meta)
                    .copyWith(color: fg),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 本文の 1 行目（全角 30 文字まで）。
String firstLineOf(String text, {int max = 30}) {
  final line = text.trim().split('\n').first.trim();
  if (line.isEmpty) {
    return '';
  }
  if (line.runes.length <= max) {
    return line;
  }
  return '${String.fromCharCodes(line.runes.take(max))}…';
}

/// 固定枠・日付見出し付きのお知らせ一覧。
class _NoticeList extends StatelessWidget {
  const _NoticeList({
    required this.controller,
    required this.notices,
    required this.pinned,
    required this.now,
    required this.onTap,
  });

  final AppController controller;
  final List<StoredMessage> notices;
  final List<StoredMessage> pinned;

  /// 現在のエポック秒。
  final int now;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final nowTime = dateTimeFromEpoch(now);
    final items = <Widget>[];
    if (pinned.isNotEmpty) {
      items.add(_PinnedBox(controller: controller, alerts: pinned, onTap: onTap));
    }
    String? lastHeader;
    for (final m in notices) {
      final env = m.envelope;
      final body = env.notice;
      final created = dateTimeFromEpoch(env.createdAt);
      final received = dateTimeFromEpoch(m.receivedAt);
      final header = receivedHeaderJa(received, now: nowTime);
      if (header != lastHeader) {
        items.add(_DateHeader(header));
        lastHeader = header;
      }
      final title = body?.title ?? '';
      final training = isTrainingTitle(title);
      final ended = env.supersedes != null && looksLikeEndTitle(title);
      final localExpiry = controller.store.localExpiresAt(m);
      final clockSuspicious = !m.isLocal &&
          (env.createdAt > m.receivedAt + 3600 ||
              env.createdAt < m.receivedAt - 24 * 3600);
      items.add(
        Padding(
          padding: const EdgeInsets.only(bottom: KairanSizes.gap),
          child: NoticeCard(
            category: env.category,
            role: env.role,
            title: title,
            place: body?.place ?? '',
            textPreview: firstLineOf(body?.text ?? ''),
            senderName: body?.senderName ?? '',
            createdAt: created,
            isNew: !m.read,
            retracted: m.retracted,
            retractedByOfficial: m.retractedByOfficial,
            superseded: m.supersededBy != null,
            isLocal: m.isLocal,
            rewrite: env.supersedes != null && !ended,
            ended: ended,
            training: training,
            alert: env.role == SenderRole.official &&
                env.category.importance == NoticeImportance.urgent &&
                !training,
            endsAt: env.category.showsEndTime && !ended
                ? dateTimeFromEpoch(env.expiresAt)
                : null,
            endingSoon: !ended && localExpiry - now <= 3600,
            clockSuspicious: clockSuspicious,
            asksReply: AppController.asksReply(m),
            onTap: () => onTap(m.msgId),
          ),
        ),
      );
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        KairanSizes.pagePadding,
        0,
        KairanSizes.pagePadding,
        16,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) => items[index],
    );
  }
}

/// 「いま 出ている 避難の お知らせ」の固定枠（C03）。
class _PinnedBox extends StatelessWidget {
  const _PinnedBox({
    required this.controller,
    required this.alerts,
    required this.onTap,
  });

  final AppController controller;
  final List<StoredMessage> alerts;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: KairanColors.card,
          border: Border.all(color: KairanColors.danger, width: 2),
          borderRadius: const BorderRadius.all(Radius.circular(KairanSizes.radius)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              color: KairanColors.danger,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(
                'いま 出ている 避難の お知らせ',
                style: KairanTextStyles.sectionTitle.copyWith(color: KairanColors.card),
              ),
            ),
            for (final m in alerts)
              InkWell(
                onTap: () => onTap(m.msgId),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        m.envelope.notice?.title ?? '',
                        style: KairanTextStyles.noticeTitle,
                      ),
                      Text(
                        '${m.envelope.notice?.senderName ?? ''} ・ ${displayGroupName(controller.groups.byCode(m.groupId)?.name ?? '')}',
                        style: KairanTextStyles.meta,
                      ),
                    ],
                  ),
                ),
              ),
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(
                '防災無線・テレビ・市の ホームページでも 確かめてください',
                style: KairanTextStyles.metaSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DateHeader extends StatelessWidget {
  const _DateHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 8),
        child: Text(text, style: KairanTextStyles.sectionTitle),
      ),
    );
  }
}

class _EmptyNotices extends StatelessWidget {
  const _EmptyNotices();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(KairanSizes.pagePadding),
        child: Text(
          'まだ お知らせは ありません。\n近くの人と すれ違うと 届きます。',
          style: KairanTextStyles.body,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

/// 中継役の「大きく 表示する」全画面（白地黒文字、どこをタップしても戻る、C04）。
class _LargeStatusScreen extends StatelessWidget {
  const _LargeStatusScreen({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    const big = TextStyle(
      fontSize: 32,
      fontWeight: FontWeight.bold,
      height: 1.5,
      color: KairanColors.text,
    );
    return Scaffold(
      backgroundColor: KairanColors.card,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).pop(),
        child: ListenableBuilder(
          listenable: Listenable.merge([controller, controller.node, controller.store]),
          builder: (context, _) {
            final node = controller.node;
            final nowTime = dateTimeFromEpoch(controller.now);
            final received = node.lastReceivedAt;
            final sent = node.lastSentAt;
            final urgent = controller.foregroundUrgentIds.isNotEmpty;
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '中継役として 動いています ・ 近くの端末 ${formatCountJa(node.nearbyCount, '台')}',
                      style: big,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      received == null
                          ? 'まだ 受け取っていません'
                          : '最後に 受け取ったのは ${MeshStatusBar.describeTime(dateTimeFromEpoch(received), nowTime)}',
                      style: big,
                    ),
                    Text(
                      sent == null
                          ? 'まだ 渡していません'
                          : '最後に 渡したのは ${MeshStatusBar.describeTime(dateTimeFromEpoch(sent), nowTime)}',
                      style: big,
                    ),
                    const SizedBox(height: 16),
                    Text('保存 ${formatCountJa(controller.store.count, '件')}', style: big),
                    if (urgent) ...[
                      const SizedBox(height: 16),
                      Text(
                        '避難の お知らせが 届きました',
                        style: big.copyWith(color: KairanColors.dangerText),
                      ),
                    ],
                    const Spacer(),
                    const Text('どこかを タップすると 戻ります', style: KairanTextStyles.meta),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 画面内の案内枠（他画面と共通の InfoBox をここでも使うための再エクスポート）。
typedef HomeInfoBox = InfoBox;
