/// 6 桁の参加コード入力（1 桁 48 幅の枠 × 6、数字キーパッド、自動で次へ）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';

/// 6 桁の数字入力。
///
/// - 各枠は幅 48 以上・高さ 56 の [TextField]。数字キーパッドを自動で出す。
/// - 1 桁入れると次の枠へ進む。6 桁そろうと [onCompleted] を呼ぶ。
/// - 貼り付けなど複数桁が入ったときは、その枠から順に振り分ける。
/// - 空の枠で削除キーを押すと前の枠に戻る。
class SixDigitInput extends StatefulWidget {
  const SixDigitInput({
    super.key,
    this.onChanged,
    this.onCompleted,
    this.autofocus = true,
    this.enabled = true,
    this.initialValue = '',
  });

  /// 桁数。
  static const int length = 6;

  /// 入力が変わるたびに、そろっている桁をつなげた文字列（0〜6 桁）で呼ぶ。
  final ValueChanged<String>? onChanged;

  /// 6 桁そろったときに呼ぶ。
  final ValueChanged<String>? onCompleted;
  final bool autofocus;
  final bool enabled;

  /// 初期値（数字のみ、6 桁まで）。
  final String initialValue;

  @override
  State<SixDigitInput> createState() => _SixDigitInputState();
}

class _SixDigitInputState extends State<SixDigitInput> {
  late final List<TextEditingController> _controllers;
  late final List<FocusNode> _focusNodes;

  /// 振り分け中に [TextField.onChanged] が再帰的に呼ばれるのを防ぐ。
  bool _distributing = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialValue.replaceAll(RegExp(r'[^0-9]'), '');
    _controllers = List.generate(SixDigitInput.length, (i) {
      final text = i < initial.length ? initial[i] : '';
      return TextEditingController(text: text);
    });
    _focusNodes = List.generate(SixDigitInput.length, (i) {
      final node = FocusNode(
        debugLabel: 'digit$i',
        onKeyEvent: (node, event) => _handleKey(i, event),
      );
      node.addListener(() => _onFocusChanged(i));
      return node;
    });
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    for (final f in _focusNodes) {
      f.dispose();
    }
    super.dispose();
  }

  /// 現在そろっている桁をつなげた文字列。
  String get value => _controllers.map((c) => c.text).join();

  void _onFocusChanged(int index) {
    final node = _focusNodes[index];
    final controller = _controllers[index];
    if (node.hasFocus && controller.text.isNotEmpty) {
      // 入力済みの枠に戻ったときは、打ち直しで置き換わるよう全選択する。
      controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: controller.text.length,
      );
    }
  }

  KeyEventResult _handleKey(int index, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace &&
        _controllers[index].text.isEmpty &&
        index > 0) {
      // 空の枠で削除 → 前の枠を消して戻る。
      _controllers[index - 1].clear();
      _focusNodes[index - 1].requestFocus();
      _notify();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onChanged(int index, String text) {
    if (_distributing) {
      return;
    }
    final digits = text.replaceAll(RegExp(r'[^0-9]'), '');
    _distributing = true;
    try {
      if (digits.isEmpty) {
        _controllers[index].clear();
      } else {
        // この枠から順に 1 桁ずつ振り分ける（貼り付け・連続入力に対応）。
        var cursor = index;
        for (var i = 0; i < digits.length && cursor < SixDigitInput.length; i++) {
          _controllers[cursor].text = digits[i];
          cursor++;
        }
        final next = cursor < SixDigitInput.length
            ? cursor
            : SixDigitInput.length - 1;
        _focusNodes[next].requestFocus();
        if (cursor >= SixDigitInput.length) {
          // 最後の枠は末尾にカーソルを置く。
          final last = _controllers[SixDigitInput.length - 1];
          last.selection = TextSelection.collapsed(offset: last.text.length);
        }
      }
    } finally {
      _distributing = false;
    }
    _notify();
  }

  void _notify() {
    final v = value;
    widget.onChanged?.call(v);
    if (v.length == SixDigitInput.length) {
      widget.onCompleted?.call(v);
    }
  }

  @override
  Widget build(BuildContext context) {
    final boxes = <Widget>[];
    for (var i = 0; i < SixDigitInput.length; i++) {
      if (i > 0) {
        boxes.add(SizedBox(width: i == 3 ? 16 : KairanSizes.gap));
      }
      boxes.add(
        Flexible(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: KairanSizes.minTapTarget,
              maxWidth: 64,
              minHeight: KairanSizes.buttonHeight,
            ),
            child: Semantics(
              label: '${i + 1}桁目',
              child: TextField(
                controller: _controllers[i],
                focusNode: _focusNodes[i],
                enabled: widget.enabled,
                autofocus: widget.autofocus && i == 0,
                keyboardType: TextInputType.number,
                textInputAction: i == SixDigitInput.length - 1
                    ? TextInputAction.done
                    : TextInputAction.next,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                textAlign: TextAlign.center,
                enableSuggestions: false,
                autocorrect: false,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: KairanColors.text,
                ),
                decoration: const InputDecoration(
                  counterText: '',
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 12,
                  ),
                ),
                onChanged: (text) => _onChanged(i, text),
              ),
            ),
          ),
        ),
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: boxes,
    );
  }
}
