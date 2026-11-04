/// サブ画面への遷移（[AppController] との結線はここに集める）。
library;

import 'package:flutter/material.dart';
import 'package:kairanban/app/app_controller.dart';
import 'package:kairanban/core/epoch.dart';
import 'package:kairanban/core/report.dart';

import 'screens/compose_screen.dart';
import 'screens/create_group_screen.dart';
import 'screens/developer_screen.dart';
import 'screens/diagnostics_screen.dart';
import 'screens/group_detail_screen.dart';
import 'screens/join_screen.dart';
import 'screens/notice_detail_screen.dart';
import 'screens/report_detail_screen.dart';
import 'screens/report_screen.dart';
import 'screens/reports_screen.dart';

Future<T?> _push<T>(BuildContext context, Widget screen) {
  return Navigator.of(context).push<T>(
    MaterialPageRoute<T>(builder: (_) => screen),
  );
}

/// グループに参加する画面。参加したら true を返す。
Future<bool?> openJoinScreen(BuildContext context, AppController controller) {
  return _push<bool>(
    context,
    JoinScreen(
      lookupName: (code) =>
          controller.store.latestGroupInfo(code)?.envelope.groupInfo?.name,
      isJoined: (code) => controller.groups.byCode(code) != null,
      onJoin: (code) async {
        await controller.joinGroup(code);
      },
      nearbyGroups: () => [
        for (final m in controller.nearbyGroupInfos())
          if (m.envelope.groupInfo != null)
            NearbyGroup(
              code: m.groupId,
              name: m.envelope.groupInfo!.name,
              hostName: m.envelope.groupInfo!.hostName,
              description: m.envelope.groupInfo!.description,
              receivedAt: dateTimeFromEpoch(m.receivedAt),
            ),
      ],
      listenable: controller.store,
    ),
  );
}

/// お知らせを書く画面。[rewriteOf] で書きなおし、[prefill] で初期値。
Future<void> openComposeScreen(
  BuildContext context,
  AppController controller, {
  int? rewriteOf,
  ComposePrefill? prefill,
}) {
  return _push<void>(
    context,
    ComposeScreen(
      controller: controller,
      rewriteOf: rewriteOf,
      prefill: prefill,
    ),
  );
}

/// お知らせ詳細。開いたときに既読にする。
Future<void> openNoticeDetail(
  BuildContext context,
  AppController controller,
  int msgId,
) {
  // 既読化は失敗しても画面遷移を妨げない。
  controller.markRead(msgId).ignore();
  return _push<void>(
    context,
    NoticeDetailScreen(controller: controller, msgId: msgId),
  );
}

/// グループを作る画面。
Future<void> openCreateGroupScreen(
  BuildContext context,
  AppController controller,
) {
  return _push<void>(context, CreateGroupScreen(controller: controller));
}

/// グループ詳細。
Future<void> openGroupDetail(
  BuildContext context,
  AppController controller,
  int code,
) {
  return _push<void>(
    context,
    GroupDetailScreen(controller: controller, code: code),
  );
}

/// 通信の状態（診断）。
Future<void> openDiagnostics(BuildContext context, AppController controller) {
  return _push<void>(context, DiagnosticsScreen(controller: controller));
}

/// 開発者メニュー（実機テスト用のデータ、#152）。
Future<void> openDeveloperMenu(BuildContext context, AppController controller) {
  return _push<void>(context, DeveloperScreen(controller: controller));
}

/// 「本部に 知らせる」画面（SOS・無事です・在宅避難・困っています）。
/// 安否確認の返事ボタンからは [type] と [inReplyTo] を渡す。
Future<void> openReportScreen(
  BuildContext context,
  AppController controller, {
  ReportType? type,
  int? inReplyTo,
  int? groupCode,
}) {
  return _push<void>(
    context,
    ReportScreen(
      controller: controller,
      initialType: type,
      inReplyTo: inReplyTo,
      groupCode: groupCode,
    ),
  );
}

/// 本部・スタッフの「住民からの 知らせ」一覧。
Future<void> openReportsScreen(
  BuildContext context,
  AppController controller, {
  int? groupCode,
  int? inReplyTo,
}) {
  return _push<void>(
    context,
    ReportsScreen(
      controller: controller,
      groupCode: groupCode,
      inReplyTo: inReplyTo,
    ),
  );
}

/// 知らせ 1 件の詳細。
Future<void> openReportDetail(
  BuildContext context,
  AppController controller,
  int msgId,
) {
  return _push<void>(
    context,
    ReportDetailScreen(controller: controller, msgId: msgId),
  );
}
