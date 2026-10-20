import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Windows 中文输入法接管字母键时，Win32 把按下消息的虚拟键码换成
/// VK_PROCESSKEY，Flutter 会整个丢弃该次按键，页面 KeyboardListener 收不到。
/// 原生层（windows/runner/flutter_window.cpp）用 ImmGetVirtualKey 取回真实
/// 虚拟键码，经本通道以 `virtualKey` 方法投递到这里。
///
/// 另一半是输入法开关：没有文本框聚焦时关闭本窗口的输入法关联，字母键不再
/// 进入拼音缓冲，直接作为快捷键送达；文本框聚焦时恢复。
class ImeVirtualKeyBridge {
  ImeVirtualKeyBridge._();

  static const MethodChannel _channel = MethodChannel('ocr/ime_virtual_key');
  static final List<void Function(int vk)> _listeners = [];
  static bool _attached = false;
  static bool _imeSyncAttached = false;

  static void addListener(void Function(int vk) listener) {
    if (!_attached) {
      _attached = true;
      _channel.setMethodCallHandler(_onCall);
    }
    _attachImeSync();
    _listeners.add(listener);
  }

  static void removeListener(void Function(int vk) listener) {
    _listeners.remove(listener);
  }

  static void _attachImeSync() {
    if (_imeSyncAttached || !Platform.isWindows) return;
    _imeSyncAttached = true;
    FocusManager.instance.addListener(_scheduleImeSync);
    _scheduleImeSync();
  }

  // 焦点变化时文本框的连接（setClient）可能还没建立，等这一帧结束再判断。
  static void _scheduleImeSync() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncIme());
  }

  static void _syncIme() {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    final editing =
        focusContext?.findAncestorStateOfType<EditableTextState>() != null;
    _channel.invokeMethod<void>('setImeEnabled', editing).catchError((_) {});
  }

  static Future<dynamic> _onCall(MethodCall call) async {
    if (call.method == 'virtualKey' && call.arguments is int) {
      final vk = call.arguments as int;
      for (final listener in List.of(_listeners)) {
        listener(vk);
      }
    }
  }
}
