/// 下部タブ 3 つ（お知らせ / グループ / 設定）の外枠。
library;

import 'package:flutter/material.dart';
import 'package:kairanban/app/app_controller.dart';

import 'groups_screen.dart';
import 'home_screen.dart';
import 'settings_screen.dart';

class ShellScreen extends StatefulWidget {
  const ShellScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen> {
  int _index = 0;
  late final Listenable _listenable;

  @override
  void initState() {
    super.initState();
    _listenable = Listenable.merge([
      widget.controller,
      widget.controller.store,
      widget.controller.groups,
    ]);
  }

  void _select(int i) {
    if (i == _index) {
      return;
    }
    if (_index == 0) {
      // 一覧を離れた時点で、表示していた未読を既読にする（C03）。
      widget.controller.markVisibleRead().ignore();
    }
    setState(() => _index = i);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          HomeScreen(controller: c),
          GroupsScreen(controller: c),
          SettingsScreen(controller: c),
        ],
      ),
      bottomNavigationBar: ListenableBuilder(
        listenable: _listenable,
        builder: (context, _) {
          final unread = c.unreadCount;
          return NavigationBar(
            selectedIndex: _index,
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            onDestinationSelected: _select,
            destinations: [
              NavigationDestination(
                icon: _withBadge(const Icon(Icons.campaign_outlined), unread),
                selectedIcon: _withBadge(const Icon(Icons.campaign), unread),
                label: 'お知らせ',
                tooltip: '',
              ),
              const NavigationDestination(
                icon: Icon(Icons.groups_outlined),
                selectedIcon: Icon(Icons.groups),
                label: 'グループ',
                tooltip: '',
              ),
              const NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: '設定',
                tooltip: '',
              ),
            ],
          );
        },
      ),
    );
  }

  static Widget _withBadge(Widget icon, int count) {
    if (count <= 0) {
      return icon;
    }
    return Badge.count(count: count, child: icon);
  }
}
