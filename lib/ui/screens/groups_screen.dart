/// 参加中のグループ一覧。
library;

import 'package:flutter/material.dart';
import 'package:kairanban/app/app_controller.dart';
import 'package:kairanban/mesh/groups.dart';

import '../../app/theme.dart';
import '../format.dart';
import '../routes.dart';
import '../widgets/big_button.dart';
import '../widgets/kairan_app_bar.dart';
import '../widgets/section.dart';
import '../widgets/tags.dart';

class GroupsScreen extends StatelessWidget {
  const GroupsScreen({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const KairanAppBar(title: 'グループ'),
      body: ListenableBuilder(
        listenable: controller.groups,
        builder: (context, _) {
          final groups = controller.groups.groups;
          return PageBody(
            children: [
              if (groups.isEmpty)
                const InfoBox(
                  'まだ グループに 参加していません。参加コードを 入れると、その グループの お知らせが 届きます。',
                )
              else ...[
                const Text('参加中の グループ', style: KairanTextStyles.sectionTitle),
                const SizedBox(height: 8),
                for (final g in groups)
                  Padding(
                    padding: const EdgeInsets.only(bottom: KairanSizes.gap),
                    child: GroupTile(
                      name: displayGroupName(g.name),
                      code: g.code,
                      roleLabel: roleLabelOf(g),
                      isSender: g.isHost || g.isOfficial,
                      closed: g.closed,
                      onTap: () => openGroupDetail(context, controller, g.code),
                    ),
                  ),
              ],
              const SizedBox(height: 16),
              SecondaryButton(
                label: 'グループに 参加する',
                onPressed: () => openJoinScreen(context, controller),
              ),
              const SizedBox(height: KairanSizes.gap),
              SecondaryButton(
                label: 'グループを 作る',
                onPressed: () => openCreateGroupScreen(context, controller),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 役割の表示名（本部 / スタッフ / 参加者）。
String roleLabelOf(JoinedGroup g) {
  if (g.isHost) {
    return '本部（作った人）';
  }
  if (g.isOfficial) {
    return '本部端末';
  }
  if (g.isStaff) {
    return 'スタッフ';
  }
  return '参加者';
}

/// グループ 1 件（全体がタップ領域、高さ 72 以上）。
class GroupTile extends StatelessWidget {
  const GroupTile({
    super.key,
    required this.name,
    required this.code,
    required this.roleLabel,
    required this.isSender,
    this.closed = false,
    required this.onTap,
  });

  final String name;
  final int code;
  final String roleLabel;
  final bool isSender;

  /// 引っ越し済み（終了）。
  final bool closed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '$name、参加コード ${formatGroupCode(code)}、$roleLabel${closed ? '、終了' : ''}',
      // 内側の InkWell の意味情報は除外するので、タップ操作をここに付ける。
      onTap: onTap,
      child: ExcludeSemantics(
        child: Material(
          color: KairanColors.card,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(
              Radius.circular(KairanSizes.radius),
            ),
            side: BorderSide(color: KairanColors.borderDecorative),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: KairanSizes.cardMinHeight,
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(name, style: KairanTextStyles.noticeTitle),
                        ),
                        const SizedBox(width: KairanSizes.gap),
                        PlainTag(roleLabel, emphasis: isSender),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '参加コード: ${formatGroupCode(code)}${closed ? ' ・ 終了' : ''}',
                      style: KairanTextStyles.meta,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
