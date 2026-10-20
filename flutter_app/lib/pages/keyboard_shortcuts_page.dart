import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/editor_shortcut_settings.dart';

/// 键盘快捷键设置页（设置整合页的"快捷键"标签，embedded 模式；照
/// GestureSettingsPage 模板：无保存按钮，改动即时落盘）。当前管辖
/// 校对界面的两个动作：合并所选识别框、删除所选识别框。点「修改」
/// 进入录制态，直接按新键即改（Esc 取消录制）；与另一动作冲突时
/// 拒绝保存并提示。
class KeyboardShortcutsPage extends StatefulWidget {
  const KeyboardShortcutsPage({super.key, this.embedded = false});

  /// true = 由设置整合页提供标题与脚手架，本页只出内容。
  final bool embedded;

  @override
  State<KeyboardShortcutsPage> createState() => _KeyboardShortcutsPageState();
}

class _KeyboardShortcutsPageState extends State<KeyboardShortcutsPage> {
  EditorShortcutSettings _settings = const EditorShortcutSettings();

  /// 正在录制的动作（'mergeChars' / 'deleteChars'），null = 非录制态。
  String? _recording;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  Future<void> _init() async {
    final s = await EditorShortcutSettings.load();
    if (!mounted) return;
    setState(() => _settings = s);
  }

  void _startRecording(String action) {
    setState(() => _recording = action);
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  void _stopRecording() {
    if (_recording == null) return;
    setState(() => _recording = null);
    HardwareKeyboard.instance.removeHandler(_onKey);
  }

  /// 全窗口按键旁听（录制态）：修饰键单独按忽略；Esc 取消；其余键
  /// 即录即存，冲突时提示不保存。返回 true 吞掉事件（避免录入的键
  /// 同时触发页面其它快捷键）。
  bool _onKey(KeyEvent event) {
    final action = _recording;
    if (action == null || event is! KeyDownEvent) return false;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _stopRecording();
      return true;
    }
    if (_modifierOnly(key)) return false;
    final shortcut = ShortcutKey.fromLogicalKey(key);
    if (_settings.conflictsWith(shortcut, forAction: action)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('按键 ${shortcut.label} 已被其它动作使用，请换一个键'),
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 2),
        ),
      );
      _stopRecording();
      return true;
    }
    setState(() {
      _settings = _withKey(action, shortcut);
      _recording = null;
    });
    unawaited(_settings.save());
    return true;
  }

  EditorShortcutSettings _withKey(String action, ShortcutKey key) =>
      switch (action) {
        'mergeChars' => EditorShortcutSettings(
          mergeChars: key,
          deleteChars: _settings.deleteChars,
        ),
        _ => EditorShortcutSettings(
          mergeChars: _settings.mergeChars,
          deleteChars: key,
        ),
      };

  static bool _modifierOnly(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.shiftLeft ||
      key == LogicalKeyboardKey.shiftRight ||
      key == LogicalKeyboardKey.controlLeft ||
      key == LogicalKeyboardKey.controlRight ||
      key == LogicalKeyboardKey.altLeft ||
      key == LogicalKeyboardKey.altRight ||
      key == LogicalKeyboardKey.metaLeft ||
      key == LogicalKeyboardKey.metaRight;

  @override
  Widget build(BuildContext context) {
    final body = ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          '校对界面（单字校对行卡片与行内重切页）的键盘快捷键。'
          '操作方式：单击选中识别框，Shift+单击把识别框加入/移出多选'
          '（紫色虚线高亮），然后按快捷键合并或删除。',
          style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
        ),
        const SizedBox(height: 12),
        _actionCard(
          title: '合并所选识别框',
          subtitle: '恰好多选同一行的两个字框时，并为一框（矩形取并集、'
              '文字按阅读序拼接）并自动重新识别。',
          key0: _settings.mergeChars,
          action: 'mergeChars',
        ),
        _actionCard(
          title: '删除所选识别框',
          subtitle: '删除当前选中的识别框；有多选时整组删除（与 Delete 键'
              '删除单个选中框并存，此键可连删多个）。',
          key0: _settings.deleteChars,
          action: 'deleteChars',
        ),
        const SizedBox(height: 8),
        Text(
          '点「修改」后直接按新键即改（Esc 取消）。快捷键只在页面获得'
          '键盘焦点时生效，文本输入框打字不受影响。',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
        ),
      ],
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(title: const Text('快捷键')),
      body: body,
    );
  }

  Widget _actionCard({
    required String title,
    required String subtitle,
    required ShortcutKey key0,
    required String action,
  }) {
    final recording = _recording == action;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        title: Text(title),
        subtitle: Text(subtitle),
        isThreeLine: true,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: recording
                    ? Colors.orange.shade50
                    : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: recording ? Colors.orange : Colors.grey.shade400,
                ),
              ),
              child: Text(
                recording ? '按新键…' : key0.label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: recording ? Colors.orange.shade900 : null,
                ),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () =>
                  recording ? _stopRecording() : _startRecording(action),
              child: Text(recording ? '取消' : '修改'),
            ),
          ],
        ),
      ),
    );
  }
}
