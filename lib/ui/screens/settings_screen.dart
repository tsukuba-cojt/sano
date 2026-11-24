/// 設定画面（docs/08 C04 C05 C06 C11）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:kairanban/app/app_controller.dart';

import '../../app/theme.dart';
import '../routes.dart';
import '../widgets/big_button.dart';
import '../widgets/dialogs.dart';
import '../widgets/kairan_app_bar.dart';
import '../widgets/section.dart';

/// アプリのバージョン表示（pubspec.yaml と合わせる）。
const String kAppVersionLabel = '2.0.0';

/// 「知っておいて ほしいこと」（はじめに・設定・利用規約で一字一句揃える、C11）。
const List<String> kThingsToKnow = [
  '電波に 乗るのは アプリの 目印（番号）だけです。名前・電話番号・場所は 乗りません。',
  'お知らせは 暗号化していません。近くの スマホを 通って 広がります。',
  '電池を 使います。',
  'iPhone どうしは 両方の 画面が 消えていると 見つけられません。画面が 点いていれば（ロック中でも）見つけられます。Android が 近くに 1 台 あれば 橋渡しされます。',
  '届く 距離は 10〜30 メートル くらいです。すれ違う 時間が 短いと、全部は 届かないことが あります。住民の 投稿は 届かない・消えることが あります。',
  '避難の 呼びかけは 防災無線・テレビ・ラジオが 正しい 情報です。このアプリは 届くまで 時間が かかります。',
  'お知らせには 有効期限が あります。期限が 切れると 自動で 消えます。',
];

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _nameCtl;
  late final Listenable _listenable;
  bool _busy = false;
  int _versionTaps = 0;

  AppController get _c => widget.controller;

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;
  bool get _isIos => defaultTargetPlatform == TargetPlatform.iOS;

  @override
  void initState() {
    super.initState();
    _nameCtl = TextEditingController(text: _c.settings.displayName);
    _listenable = Listenable.merge([_c, _c.node]);
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    super.dispose();
  }

  /// バージョンを 7 回 押すと開発者メニューを出す（実機テスト用、#152）。
  void _onVersionTap() {
    if (_c.settings.developerMode) {
      return;
    }
    _versionTaps++;
    if (_versionTaps < 7) {
      return;
    }
    _versionTaps = 0;
    unawaited(_c.setDeveloperMode(true));
    showSnack(context, '開発者メニューを 出しました（通信の状態の 下）');
  }

  Future<void> _run(Future<void> Function() action, {String? done}) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) {
        return;
      }
      if (done != null) {
        showSnack(context, done);
      }
    } catch (e) {
      if (!mounted) {
        return;
      }
      await showMessageDialog(
        context,
        title: 'できませんでした',
        message: describeError(e),
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _setTextScale(double scale) {
    return _run(() async {
      final s = _c.settings;
      s.textScale = scale;
      await _c.saveSettings(s);
    });
  }

  Future<void> _saveName() {
    return _run(() async {
      final s = _c.settings;
      final name = _nameCtl.text.trim();
      s.displayName = name.isEmpty ? '名前なし' : name;
      _nameCtl.text = s.displayName;
      await _c.saveSettings(s);
    }, done: '名前を 保存しました。');
  }

  Future<void> _setLowPower(bool lowPower) {
    return _run(() async {
      final s = _c.settings;
      s.lowPowerPreferred = lowPower;
      // 通信中なら saveSettings が node.setLowPower まで行う。
      await _c.saveSettings(s);
    });
  }

  Future<void> _startMesh() => _run(_c.startMesh, done: '通信を 始めました。');

  Future<void> _stopMesh() async {
    if (_c.settings.relayMode) {
      await showMessageDialog(
        context,
        title: '先に 中継役を やめてください',
        message: '中継役として 動いている あいだは 通信を 止められません。',
      );
      return;
    }
    final ok = await showConfirmDialog(
      context,
      title: '通信を 止めますか？',
      message: '止めると、お知らせが 届かなく なります。あとから また 始められます。',
      confirmLabel: '止める',
      danger: true,
    );
    if (!ok || !mounted) {
      return;
    }
    await _run(_c.stopMesh, done: '通信を 止めました。');
  }

  Future<void> _setRelayMode(bool v) async {
    if (v) {
      if (_isAndroid) {
        await _requestBatteryExemption();
        if (!mounted) {
          return;
        }
      }
      await showMessageDialog(
        context,
        title: '中継役として 使います',
        message: '電池を たくさん 使います。充電しながら 使ってください。'
            '${_isIos ? 'iPhone は 画面を 消すと 交換できません。' : ''}',
      );
      if (!mounted) {
        return;
      }
    } else {
      final ok = await showConfirmDialog(
        context,
        title: '中継役を やめますか？',
        message: '画面は ふつうに 消えるように なり、通知も ふつうに 戻ります。',
        confirmLabel: 'やめる',
      );
      if (!ok || !mounted) {
        return;
      }
    }
    await _run(() async {
      final s = _c.settings;
      s.relayMode = v;
      await _c.saveSettings(s);
      if (v && !_c.node.running) {
        await _c.startMesh();
      }
    });
  }

  Future<void> _setChime(bool v) {
    return _run(() async {
      final s = _c.settings;
      s.chimeEnabled = v;
      await _c.saveSettings(s);
    });
  }

  Future<void> _requestPermissions() {
    return _run(() async {
      final granted = await _c.requestPermissions();
      if (!mounted) {
        return;
      }
      showSnack(
        context,
        granted ? 'Bluetooth が 許可されました。' : '許可されませんでした。設定から 許可できます。',
      );
    });
  }

  Future<void> _setNotificationLevel(NotificationLevel level) {
    return _run(() async {
      final s = _c.settings;
      s.notificationLevel = level;
      await _c.saveSettings(s);
    });
  }

  Future<void> _requestNotificationPermission() {
    return _run(() async {
      final granted = await _c.requestNotificationPermission();
      if (!mounted) {
        return;
      }
      showSnack(
        context,
        granted ? '通知が 許可されました。' : '許可されませんでした。設定から 許可できます。',
      );
    });
  }

  Future<void> _enableBackgroundWake() {
    return _run(() async {
      final status = await _c.enableBackgroundWake();
      if (!mounted) {
        return;
      }
      showSnack(
        context,
        status == BackgroundWake.on
            ? 'アプリを 閉じても 受け取れるように なりました。'
            : '位置情報を「常に」に すると 使えます。スマホの 設定で 変えられます。',
      );
    });
  }

  Future<void> _requestBatteryExemption() {
    return _run(() async {
      final ok = await _c.requestBatteryExemption();
      if (!mounted) {
        return;
      }
      showSnack(
        context,
        ok ? '電池の 最適化から 除外されました。' : '除外されませんでした。設定から 変えられます。',
      );
    });
  }

  Future<void> _openAppSettings() => _run(_c.openAppSettings);

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

  String _batteryLine(AppSettings settings) {
    final b = _c.battery;
    final mode = settings.relayMode
        ? '中継役なので ふつう'
        : (_c.node.lowPower ? '長持ち' : 'ふつう');
    if (b == null) {
      return '今は $mode です。';
    }
    return '今の 残量 ${b.level}%${b.charging ? '（充電中）' : ''} ・ 今は $mode です。';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const KairanAppBar(title: '設定'),
      body: ListenableBuilder(
        listenable: _listenable,
        builder: (context, _) {
          final settings = _c.settings;
          final node = _c.node;
          final scale = KairanTextScale.normalize(settings.textScale);
          return PageBody(
            children: [
              // ---- 文字の大きさ ----
              const SectionTitle('文字の大きさ'),
              ChoiceGrid(
                columns: 1,
                children: [
                  for (final choice in const [
                    (KairanTextScale.standard, '標準'),
                    (KairanTextScale.large, '大きい'),
                    (KairanTextScale.extraLarge, 'とても大きい'),
                  ])
                    ChoiceButton(
                      label: choice.$2,
                      selected: scale == choice.$1,
                      onPressed: _busy ? null : () => _setTextScale(choice.$1),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                'スマホ本体の 文字の 大きさの 設定にも 合わせます。',
                style: KairanTextStyles.metaSecondary,
              ),

              // ---- 表示名 ----
              const SectionTitle('表示名'),
              const Text(
                'お知らせを 出すときに 表示される 名前です。本名で なくて かまいません。役割が 分かる 名前を おすすめします（例: 3班 佐藤、〇〇小学校 受付）。',
                style: KairanTextStyles.meta,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _nameCtl,
                maxLength: 16,
                textInputAction: TextInputAction.done,
                style: KairanTextStyles.body,
                decoration: const InputDecoration(
                  labelText: '名前',
                  hintText: '名前なし',
                ),
                onSubmitted: (_) => _saveName(),
              ),
              const SizedBox(height: 4),
              SecondaryButton(
                label: '名前を 保存する',
                onPressed: _busy ? null : _saveName,
              ),

              // ---- 電池 ----
              const SectionTitle('電池'),
              ChoiceGrid(
                children: [
                  ChoiceButton(
                    label: 'ふつう',
                    selected: !settings.lowPowerPreferred,
                    onPressed: _busy || settings.relayMode ? null : () => _setLowPower(false),
                  ),
                  ChoiceButton(
                    label: '長持ち',
                    selected: settings.lowPowerPreferred,
                    onPressed: _busy || settings.relayMode ? null : () => _setLowPower(true),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(_batteryLine(settings), style: KairanTextStyles.meta),
              Text(
                settings.lowPowerPreferred
                    ? '「長持ち」では 交換が ゆっくりに なります。'
                    : '電池が 20% より 少なくなると 自動で「長持ち」に なり、充電するか 50% を 超えると 戻ります。',
                style: KairanTextStyles.metaSecondary,
              ),

              // ---- 通知 ----
              const SectionTitle('通知'),
              ChoiceGrid(
                columns: 1,
                children: [
                  ChoiceButton(
                    label: 'ぜんぶ 知らせる',
                    selected: settings.notificationLevel == NotificationLevel.all,
                    onPressed: _busy
                        ? null
                        : () => _setNotificationLevel(NotificationLevel.all),
                  ),
                  ChoiceButton(
                    label: '公式と 大事なものだけ 知らせる',
                    selected:
                        settings.notificationLevel == NotificationLevel.important,
                    onPressed: _busy
                        ? null
                        : () => _setNotificationLevel(NotificationLevel.important),
                  ),
                  ChoiceButton(
                    label: '知らせない',
                    selected: settings.notificationLevel == NotificationLevel.off,
                    onPressed: _busy
                        ? null
                        : () => _setNotificationLevel(NotificationLevel.off),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                switch (settings.notificationLevel) {
                  NotificationLevel.all =>
                    '新しい お知らせが 届くたびに、アプリを 閉じていても スマホの 通知で 知らせます。',
                  NotificationLevel.important =>
                    '公式・スタッフの お知らせと、避難・給水・物資・炊き出し・医療などの 大事なものだけ 知らせます。避難・注意喚起は 夜でも すぐに 知らせます。',
                  NotificationLevel.off =>
                    '通知は 出しません。新しい お知らせは アプリを 開いて 確かめてください。',
                },
                style: KairanTextStyles.metaSecondary,
              ),
              const SizedBox(height: 4),
              const Text(
                '耳が 聞こえにくい方は、スマホの 設定で ライトの 点滅（LED フラッシュ）を オンに すると 分かりやすく なります。',
                style: KairanTextStyles.metaSecondary,
              ),
              if (settings.notificationsEnabled) ...[
                const SizedBox(height: 8),
                SecondaryButton(
                  label: '通知を 許可する',
                  onPressed: _busy ? null : _requestNotificationPermission,
                ),
              ],

              // ---- 通信 ----
              const SectionTitle('通信'),
              CardBox(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      node.running
                          ? (settings.relayMode ? '状態: 中継役として 交換中' : '状態: 近くの人と 交換中')
                          : '状態: 止まっています',
                      style: KairanTextStyles.body.copyWith(
                        fontWeight: FontWeight.bold,
                        color: node.running
                            ? KairanColors.success
                            : KairanColors.dangerText,
                      ),
                    ),
                    Text(
                      'Bluetooth: ${node.poweredOn ? 'オン' : 'オフ'}',
                      style: KairanTextStyles.meta,
                    ),
                    Text(
                      '許可: ${_permissionLabel(node.permission)}',
                      style: KairanTextStyles.meta,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              if (node.running)
                SecondaryButton(
                  label: '通信を 止める',
                  danger: true,
                  onPressed: _busy ? null : _stopMesh,
                )
              else
                PrimaryButton(
                  label: '通信を 始める',
                  onPressed: _busy ? null : _startMesh,
                ),
              if (node.permission != 'granted') ...[
                const SizedBox(height: KairanSizes.gap),
                SecondaryButton(
                  label: 'Bluetooth を 許可する',
                  onPressed: _busy ? null : _requestPermissions,
                ),
                const SizedBox(height: KairanSizes.gap),
                SecondaryButton(
                  label: 'スマホの 設定を 開く',
                  onPressed: _busy ? null : _openAppSettings,
                ),
              ],
              if (_c.backgroundWake != BackgroundWake.unavailable) ...[
                const SizedBox(height: 12),
                _BackgroundWakeBox(
                  status: _c.backgroundWake,
                  busy: _busy,
                  onEnable: _enableBackgroundWake,
                  onOpenSettings: _openAppSettings,
                ),
              ],
              if (_isAndroid) ...[
                const SizedBox(height: 12),
                const Text(
                  '機種によっては、省電力の 設定で 通信が 止まることが あります。下の ボタンで 除外してください。',
                  style: KairanTextStyles.meta,
                ),
                const SizedBox(height: 8),
                SecondaryButton(
                  label: '電池の 最適化から 除外する',
                  onPressed: _busy ? null : _requestBatteryExemption,
                ),
              ],
              const SizedBox(height: 12),
              const InfoBox(
                'アプリを 上に スワイプして 終了しないでください。Bluetooth を 切らないでください。',
                title: 'お願い',
                kind: InfoKind.caution,
              ),

              // ---- 中継役 ----
              const SectionTitle('中継役として 使う'),
              const Text(
                '受付・集会所・運び役の 端末で オンにします。画面を 消さず、電池は「ふつう」のまま、通知を 出さずに 交換を 続けます。中継役の 端末は 参加している グループの 名前を 近くの 端末に 知らせます。',
                style: KairanTextStyles.meta,
              ),
              const SizedBox(height: 8),
              ChoiceGrid(
                children: [
                  ChoiceButton(
                    label: '使わない',
                    selected: !settings.relayMode,
                    onPressed: _busy || !settings.relayMode ? null : () => _setRelayMode(false),
                  ),
                  ChoiceButton(
                    label: '中継役として 使う',
                    selected: settings.relayMode,
                    onPressed: _busy || settings.relayMode ? null : () => _setRelayMode(true),
                  ),
                ],
              ),
              if (settings.relayMode) ...[
                const SizedBox(height: 8),
                ChoiceGrid(
                  children: [
                    ChoiceButton(
                      label: '交換の 音: 鳴らす',
                      selected: settings.chimeEnabled,
                      onPressed: _busy ? null : () => _setChime(true),
                    ),
                    ChoiceButton(
                      label: '鳴らさない',
                      selected: !settings.chimeEnabled,
                      onPressed: _busy ? null : () => _setChime(false),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  '交換が 終わるたびに 短い 音と 振動で 知らせます。',
                  style: KairanTextStyles.metaSecondary,
                ),
              ],

              // ---- 通信の状態 ----
              const SectionTitle('通信の状態'),
              const Text(
                '近くの 端末の 数、最近の 交換の 記録、保存件数などを 見られます。',
                style: KairanTextStyles.meta,
              ),
              const SizedBox(height: 8),
              SecondaryButton(
                label: '通信の 状態を 見る',
                onPressed: () => openDiagnostics(context, _c),
              ),

              if (settings.developerMode) ...[
                const SizedBox(height: 8),
                SecondaryButton(
                  label: '開発者メニュー',
                  onPressed: () => openDeveloperMenu(context, _c),
                ),
              ],

              // ---- このアプリについて ----
              const SectionTitle('このアプリについて'),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _onVersionTap,
                child: const Text(
                  '回覧板 バージョン $kAppVersionLabel',
                  style: KairanTextStyles.body,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                '近くの スマホと Bluetooth で お知らせを 交換します。インターネットは 使いません。',
                style: KairanTextStyles.meta,
              ),
              const SizedBox(height: 12),
              const Text('知っておいて ほしいこと', style: KairanTextStyles.sectionTitle),
              const SizedBox(height: 4),
              for (final line in kThingsToKnow) _Bullet(line),
              const _Bullet(
                'Android では「近くの人と 情報を 交換しています」という 通知が 出ます。消さないでください。',
              ),
              const _Bullet(
                '「公式」の 表示は 参加コードと 本部コード・スタッフコードの 運用で 守ります。',
              ),
              const SizedBox(height: 16),
            ],
          );
        },
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('・', style: KairanTextStyles.body),
          Expanded(child: Text(text, style: KairanTextStyles.body)),
        ],
      ),
    );
  }
}

/// iPhone の「アプリを 閉じても 受け取る」（iBeacon の領域監視）。
class _BackgroundWakeBox extends StatelessWidget {
  const _BackgroundWakeBox({
    required this.status,
    required this.busy,
    required this.onEnable,
    required this.onOpenSettings,
  });

  final BackgroundWake status;
  final bool busy;
  final VoidCallback onEnable;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final on = status == BackgroundWake.on;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          on ? 'アプリを 閉じても 受け取る: オン' : 'アプリを 閉じても 受け取る: オフ',
          style: KairanTextStyles.sectionTitle,
        ),
        const SizedBox(height: 4),
        const Text(
          'アプリを 上に スワイプして 閉じても、近くに Android の 回覧板が 来ると 起きて 受け取ります。'
          '位置情報を「常に」に する 必要が あります。場所は 記録も 送信も しません。',
          style: KairanTextStyles.meta,
        ),
        if (!on) ...[
          const SizedBox(height: 8),
          if (status == BackgroundWake.notAsked)
            SecondaryButton(
              label: 'アプリを 閉じても 受け取る',
              onPressed: busy ? null : onEnable,
            )
          else ...[
            const Text(
              'スマホの 設定 →「回覧板」→「位置情報」で「常に」を 選んでください。',
              style: KairanTextStyles.meta,
            ),
            const SizedBox(height: 8),
            SecondaryButton(
              label: 'スマホの 設定を 開く',
              onPressed: busy ? null : onOpenSettings,
            ),
          ],
        ],
      ],
    );
  }
}
