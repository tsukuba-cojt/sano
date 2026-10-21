/// グループ作成の結果画面（参加コード・QR・本部コード・スタッフコード）。
library;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../format.dart';
import '../widgets/big_button.dart';
import '../widgets/group_qr.dart';
import '../widgets/kairan_app_bar.dart';
import '../widgets/section.dart';

class GroupCreatedScreen extends StatelessWidget {
  const GroupCreatedScreen({
    super.key,
    required this.name,
    required this.code,
    required this.membersCanPost,
    this.hqCode,
    this.staffCode,
    @Deprecated('hqCode を使う') String? officialCode,
  }) : _legacyCode = officialCode;

  final String name;
  final int code;

  /// 8 桁の本部コード（先頭 1）。
  final String? hqCode;

  /// 8 桁のスタッフコード（先頭 2）。
  final String? staffCode;
  final String? _legacyCode;
  final bool membersCanPost;

  @override
  Widget build(BuildContext context) {
    final hq = hqCode ?? _legacyCode;
    final staff = staffCode;
    return Scaffold(
      appBar: const KairanAppBar(title: '作りました', showBack: true),
      body: PageBody(
        bottom: PrimaryButton(
          label: 'とじる',
          onPressed: () => Navigator.of(context).pop(),
        ),
        children: [
          const InfoBox('グループを 作りました。', kind: InfoKind.success),
          const SectionTitle('グループ名'),
          Text(name, style: KairanTextStyles.noticeTitle),
          const SizedBox(height: 4),
          Text(
            membersCanPost ? '参加者も お知らせを 出せます。' : '本部・スタッフだけが お知らせを 出せます。',
            style: KairanTextStyles.meta,
          ),
          const SectionTitle('参加コード（6桁）'),
          BigCodeText(
            formatGroupCode(code),
            semanticsLabel: '参加コード ${formatGroupCode(code)}',
          ),
          const SizedBox(height: 12),
          GroupQrCode(code),
          const SizedBox(height: 8),
          const Text(
            'この 番号を 住民に 伝えてください。番号を 入れると 参加できます。近くの スマホには グループ名も 自動で 届きます。',
            style: KairanTextStyles.body,
          ),
          if (hq != null) ...[
            const SectionTitle('本部コード（8桁）'),
            BigCodeText(
              formatOfficialCode(hq),
              semanticsLabel: '本部コード ${formatOfficialCode(hq)}',
            ),
            const SizedBox(height: 8),
            const Text(
              '本部コードは 防災課の 端末だけに 教えてください。入れた端末は 公式として お知らせを 出し、他の人の お知らせを 取り消せます。',
              style: KairanTextStyles.body,
            ),
          ],
          if (staff != null) ...[
            const SectionTitle('スタッフコード（8桁）'),
            BigCodeText(
              formatOfficialCode(staff),
              semanticsLabel: 'スタッフコード ${formatOfficialCode(staff)}',
            ),
            const SizedBox(height: 8),
            const Text(
              'スタッフコードは 避難所や 病院・薬局・電力・バスの 担当者に 教えてください。入れた端末は「スタッフ」として お知らせを 出せます。',
              style: KairanTextStyles.body,
            ),
          ],
          if (hq != null || staff != null) ...[
            const SizedBox(height: 12),
            const InfoBox(
              'この 8桁は 紙に 書いて 2人以上で 保管してください。端末を 替えたときに 使います。住民には 教えないでください。あとから グループの 画面でも 見られます。',
              title: '紙に 書いて 保管',
              kind: InfoKind.caution,
            ),
          ],
        ],
      ),
    );
  }
}
