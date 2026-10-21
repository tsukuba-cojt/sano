/// グループを作る画面。
library;

import 'package:flutter/material.dart';
import 'package:kairanban/app/app_controller.dart';

import '../../app/theme.dart';
import '../widgets/big_button.dart';
import '../widgets/dialogs.dart';
import '../widgets/kairan_app_bar.dart';
import '../widgets/section.dart';
import 'group_created_screen.dart';

class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final _nameCtl = TextEditingController();
  final _descriptionCtl = TextEditingController();
  bool _membersCanPost = true;
  bool _creating = false;

  @override
  void dispose() {
    _nameCtl.dispose();
    _descriptionCtl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _nameCtl.text.trim();
    if (name.isEmpty || _creating) {
      return;
    }
    setState(() => _creating = true);
    try {
      final group = await widget.controller.createGroup(
        name: name,
        membersCanPost: _membersCanPost,
        description: _descriptionCtl.text.trim(),
      );
      if (!mounted) {
        return;
      }
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => GroupCreatedScreen(
            name: group.name,
            code: group.code,
            hqCode: group.hqCode,
            staffCode: group.staffCode,
            membersCanPost: group.membersCanPost,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() => _creating = false);
      await showMessageDialog(
        context,
        title: '作れませんでした',
        message: describeError(e),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final canCreate = !_creating && _nameCtl.text.trim().isNotEmpty;
    return Scaffold(
      appBar: const KairanAppBar(title: 'グループを 作る', showBack: true),
      body: PageBody(
        bottom: PrimaryButton(
          label: _creating ? '作っています…' : '作る',
          onPressed: canCreate ? _create : null,
        ),
        children: [
          const Text(
            'グループを 作ると、6桁の 参加コードが できます。参加コードを 伝えた人に お知らせが 届きます。',
            style: KairanTextStyles.body,
          ),
          const SectionTitle('グループの 名前'),
          TextField(
            controller: _nameCtl,
            maxLength: 20,
            textInputAction: TextInputAction.next,
            style: KairanTextStyles.body,
            decoration: const InputDecoration(hintText: '例: 〇〇市 防災課'),
            onChanged: (_) => setState(() {}),
          ),
          const SectionTitle('問い合わせ先・ひとこと（なくても よい）'),
          TextField(
            controller: _descriptionCtl,
            maxLength: 100,
            maxLines: 2,
            minLines: 1,
            textInputAction: TextInputAction.done,
            style: KairanTextStyles.body,
            decoration: const InputDecoration(hintText: '例: 〇〇市役所 防災課 窓口'),
          ),
          const SectionTitle('投稿の 決まり'),
          // ListTile は最寄りの Material に描くので、装飾した Container ではなく
          // Material で枠を付ける。
          Material(
            color: KairanColors.card,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(
                Radius.circular(KairanSizes.radius),
              ),
              side: BorderSide(color: KairanColors.borderDecorative),
            ),
            clipBehavior: Clip.antiAlias,
            child: SwitchListTile(
              value: _membersCanPost,
              onChanged: _creating
                  ? null
                  : (v) => setState(() => _membersCanPost = v),
              title: const Text('参加者も 投稿できる'),
              subtitle: Text(
                _membersCanPost
                    ? 'オン: 参加した人は だれでも お知らせを 出せます。'
                    : 'オフ: 本部コード・スタッフコードを 持つ人だけが お知らせを 出せます。',
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 4,
              ),
            ),
          ),
          const SizedBox(height: 16),
          const InfoBox(
            '作ると、あなたが 公式（本部）に なります。本部用と スタッフ用の 8桁の 番号も できます。',
          ),
        ],
      ),
    );
  }
}
