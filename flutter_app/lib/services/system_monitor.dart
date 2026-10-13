import 'dart:async';

import 'package:flutter/foundation.dart';

import 'python_service.dart';

/// 整机资源监控（识别监控悬浮窗的曲线数据源）：周期轮询 /process_stats，
/// 维护 CPU% / 内存% / 显存% 的滚动历史。单例 ChangeNotifier，与
/// [RecognitionQueue] 同一模式：跨页面存活，UI addListener 订阅。
///
/// 与首页统计条是两个数据通道：首页自己 3 秒轮询进程树口径（不改），
/// 本类 2 秒轮询整机口径；后端 /process_stats 的 1.5s TTL 缓存天然把
/// 两路请求去重成至多每 1.5s 一次真实采样。
class SystemMonitor extends ChangeNotifier {
  SystemMonitor._();
  static final SystemMonitor instance = SystemMonitor._();

  /// 轮询间隔。略大于后端 1.5s TTL 缓存，保证每次轮询都触发新采样
  /// （曲线不出现平台期）。
  static const Duration pollInterval = Duration(seconds: 2);

  /// 历史上限：2s × 90 ≈ 3 分钟滚动窗口，超出裁掉最旧的。
  static const int maxHistory = 90;

  /// 数据源注入缝（同 RecognitionQueue.keepAwakeHook 的静态缝）：
  /// 测试替换为假实现，不碰真实 HTTP。
  static Future<ServiceStats?> Function() fetch = PythonService.fetchProcessStats;

  final List<double> _cpuHistory = [];
  final List<double> _memHistory = [];
  final List<double> _vramHistory = [];
  final List<double> _gpuHistory = [];

  Timer? _timer;
  bool _polling = false;

  /// 最近一次成功拿到的完整快照（含进程树与整机两块）；后端不可达时
  /// 保留上一次的值，曲线与数值停留在断连时刻。
  ServiceStats? latest;

  /// 连续取数失败的轮询次数；>0 时 UI 提示"连接后端失败"。
  int missStreak = 0;

  bool get isRunning => _timer != null;

  List<double> get cpuHistory => List.unmodifiable(_cpuHistory);

  List<double> get memHistory => List.unmodifiable(_memHistory);

  List<double> get vramHistory => List.unmodifiable(_vramHistory);

  /// GPU 核心利用率历史（整卡，nvidia-smi）；无 N 卡时为空。
  List<double> get gpuHistory => List.unmodifiable(_gpuHistory);

  /// 开始轮询（悬浮窗可见时调用）；已在跑则幂等返回。立即先采一次，
  /// 窗口打开即刻有数据而不是等一个周期。
  void start() {
    if (_timer != null) return;
    unawaited(poll());
    _timer = Timer.periodic(pollInterval, (_) => unawaited(poll()));
  }

  /// 停止轮询（悬浮窗隐藏时调用）。历史保留，重开后继续追加。
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// 采一次数据。Timer 驱动，测试也可直接调用（不必 start）；真实采样
  /// 在后端线程池里要 0.25s+，用 [_polling] 防重入串行化。stop() 之后
  /// 迟到的一次结果照常落地——更新的是没人看的内存快照，无害。
  Future<void> poll() async {
    if (_polling) return;
    _polling = true;
    ServiceStats? stats;
    try {
      stats = await fetch();
    } catch (_) {
      stats = null; // fetch 内部已把网络异常折成 null，这里兜底防抛出
    }
    _polling = false;
    if (stats == null) {
      missStreak++;
      notifyListeners();
      return;
    }
    missStreak = 0;
    latest = stats;
    final sys = stats.system;
    if (sys != null) {
      _append(_cpuHistory, sys.cpuPercent);
      _append(_memHistory, sys.memoryRatio * 100);
      // 无 N 卡（或该次 GPU 查询失败）时显存/GPU 曲线断点式跳过：不补
      // 0，空曲线 = "不可用"，与 0% 占用区分。
      final vramRatio = sys.vramRatio;
      if (vramRatio != null) _append(_vramHistory, vramRatio * 100);
      final gpuUtil = sys.gpuUtilPercent;
      if (gpuUtil != null) _append(_gpuHistory, gpuUtil);
    }
    notifyListeners();
  }

  void _append(List<double> history, double value) {
    history.add(value.clamp(0.0, 100.0));
    if (history.length > maxHistory) {
      history.removeRange(0, history.length - maxHistory);
    }
  }

  /// 清空全部状态（测试隔离用；生产代码不调用）。
  @visibleForTesting
  void debugReset() {
    stop();
    _cpuHistory.clear();
    _memHistory.clear();
    _vramHistory.clear();
    _gpuHistory.clear();
    latest = null;
    missStreak = 0;
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
