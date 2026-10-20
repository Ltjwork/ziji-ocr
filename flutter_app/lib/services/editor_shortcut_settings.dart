import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一个可配置快捷键的按键值：持久化 keyId（事件匹配用）+ keyLabel
///（设置页展示用）。只存 keyId 反查不出文字（按 keyId 构造的
/// LogicalKeyboardKey 没有 debugName/keyLabel），所以展示文字随保存
/// 一起落盘。
class ShortcutKey {
  const ShortcutKey({required this.keyId, required this.label});

  final int keyId;
  final String label;

  ShortcutKey.fromLogicalKey(LogicalKeyboardKey key)
    : this(keyId: key.keyId, label: key.keyLabel);

  LogicalKeyboardKey get key => LogicalKeyboardKey(keyId);

  /// 原生层取回的 Win32 虚拟键码是否对应本按键（输入法接管时的兜底匹配）。
  /// 字母键的 VK 为大写 ASCII（'M' = 0x4D），keyId 为小写（'m' = 0x6D）。
  bool matchesVirtualKey(int vk) {
    final isLowerLetter = keyId >= 0x61 && keyId <= 0x7A;
    return vk == (isLowerLetter ? keyId - 0x20 : keyId);
  }

  static const ShortcutKey defaultMerge = ShortcutKey(keyId: 0x6D, label: 'M');
  static const ShortcutKey defaultDelete = ShortcutKey(keyId: 0x78, label: 'X');

  Map<String, dynamic> toJson() => {'keyId': keyId, 'label': label};

  factory ShortcutKey.fromJson(Map<String, dynamic> j) => ShortcutKey(
    keyId: (j['keyId'] as num).toInt(),
    label: (j['label'] as String?) ?? '',
  );

  @override
  bool operator ==(Object other) =>
      other is ShortcutKey && other.keyId == keyId;

  @override
  int get hashCode => keyId;
}

/// 校对界面键盘快捷键配置（设置 → 快捷键 可改键，改动即时落盘）。
/// 当前管辖两个动作：合并所选识别框（默认 M）、删除所选识别框
///（默认 X，取代原先的 Shift+单击删除）。
class EditorShortcutSettings {
  const EditorShortcutSettings({
    this.mergeChars = ShortcutKey.defaultMerge,
    this.deleteChars = ShortcutKey.defaultDelete,
  });

  /// 合并所选的两个识别框为一个（单字校对行卡片内，两框须同行）。
  final ShortcutKey mergeChars;

  /// 删除所选识别框（多选时全部删除）。
  final ShortcutKey deleteChars;

  static const String _prefsKey = 'editor_shortcut_settings_v1';

  factory EditorShortcutSettings.fromJson(Map<String, dynamic> j) {
    ShortcutKey parse(String name, ShortcutKey fallback) {
      final raw = j[name];
      if (raw is! Map) return fallback;
      try {
        return ShortcutKey.fromJson(Map<String, dynamic>.from(raw));
      } catch (_) {
        return fallback;
      }
    }

    return EditorShortcutSettings(
      mergeChars: parse('mergeChars', ShortcutKey.defaultMerge),
      deleteChars: parse('deleteChars', ShortcutKey.defaultDelete),
    );
  }

  Map<String, dynamic> toJson() => {
    'mergeChars': mergeChars.toJson(),
    'deleteChars': deleteChars.toJson(),
  };

  static Future<EditorShortcutSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return const EditorShortcutSettings();
    try {
      return EditorShortcutSettings.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      return const EditorShortcutSettings();
    }
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(toJson()));
  }

  /// 按键是否与其它动作冲突（同一按键只能触发一个动作）。
  /// [forAction] 为当前正在改键的动作：'mergeChars' / 'deleteChars'。
  bool conflictsWith(ShortcutKey key, {required String forAction}) {
    final others = [
      if (forAction != 'mergeChars') mergeChars,
      if (forAction != 'deleteChars') deleteChars,
    ];
    return others.contains(key);
  }
}
