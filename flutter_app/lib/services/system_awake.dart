import 'dart:ffi';
import 'dart:io';

/// 识别期间阻止 Windows 自动进入待机/睡眠（传统 S3 与现代待机均适用）。
///
/// 通过 kernel32 的 SetThreadExecutionState(ES_CONTINUOUS |
/// ES_SYSTEM_REQUIRED) 实现：只要求「系统保持唤醒」，不锁定显示器——挂机
/// 识别时屏幕照常按电源计划熄灭省电；用户手动点「睡眠」也仍然生效，
/// 被阻止的只是空闲计时器触发的自动待机。
class SystemAwake {
  SystemAwake._();

  static const int _esContinuous = 0x80000000;
  static const int _esSystemRequired = 0x00000001;

  static bool _acquired = false;

  static final int Function(int)? _setThreadExecutionState = _load();

  static int Function(int)? _load() {
    if (!Platform.isWindows) return null;
    try {
      return DynamicLibrary.open('kernel32.dll')
          .lookupFunction<Uint32 Function(Uint32), int Function(int)>(
            'SetThreadExecutionState',
          );
    } catch (_) {
      return null;
    }
  }

  /// [required] 为 true 时请求系统保持唤醒；false 时交还电源计划管理。
  /// 幂等：重复请求/释放只真正调用一次。
  static void setRequired(bool required) {
    final fn = _setThreadExecutionState;
    if (fn == null) return;
    if (required && !_acquired) {
      // 返回值是先前的执行状态，0 表示调用失败（此时不置 _acquired，
      // 之后的释放调用也就不会发出多余的复位）。
      _acquired = fn(_esContinuous | _esSystemRequired) != 0;
    } else if (!required && _acquired) {
      fn(_esContinuous);
      _acquired = false;
    }
  }
}
