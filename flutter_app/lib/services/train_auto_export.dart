import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'python_service.dart';

/// 确认后自动增量导出：让训练数据统计随「确认并保存 / 确认识别框 /
/// 主区快设确认」即时增长，而不是等用户打开训练页才补导出。
///
/// 统计口径仍是 manifest（已导出数据），但确认动作现在会触发一次防抖
/// 的后台增量导出（/train/export 全书库扫描约 7~15 秒，防抖窗口内多次
/// 确认合并成一次；导出进行中再次确认则排一次收尾重跑）。失败只记
/// 日志——训练页打开时的自动导出仍是兜底，不因这里的失败丢数据。
///
/// 与 CharStatsService.syncPage 同一挂接模式：ProjectStorage.saveAnnotation
/// 是全部保存路径的咽喉点，在那里调用 [onAnnotationSaved]。
class TrainExportScheduler {
  TrainExportScheduler._();

  /// 防抖窗口：主区快设「确认并下一页」连续操作时合并成一次导出。
  static const _debounce = Duration(seconds: 10);

  static Timer? _timer;
  static bool _running = false;
  static String? _queuedDir;
  static final _doneController = StreamController<void>.broadcast();

  /// 每次增量导出完成（无论有无新增）发出一次；编辑器监听它刷新
  /// 训练数据就绪卡的全局累计数。
  static Stream<void> get onExportDone => _doneController.stream;

  /// 标注保存咽喉点调用：仅当本次保存可能贡献训练数据（页面级确认
  /// 或任一版面区已确认——主区快设只确认区域、不置页面级标记）时
  /// 安排导出；草稿/识别机写盘直接短路，不空转扫描。
  static void onAnnotationSaved(String projectDir, PageAnnotation ann) {
    if (!mayContributeTrainingData(ann)) return;
    schedule(projectDir);
  }

  /// 页面是否含有任何训练可用内容（检测层任一：完全确认、框确认、
  /// 已确认版面区——region_det 只看区域，与导出资格同口径）。
  static bool mayContributeTrainingData(PageAnnotation ann) =>
      ann.reviewed ||
      ann.boxesReviewed ||
      ann.mainRegions.any((r) => r.boxConfirmed);

  /// 测试短路：true 时 schedule 不排定时器。widget 测试的 FakeAsync 区
  /// 收尾校验无 pending Timer，保存过确认标注的用例都会因 10 秒防抖
  /// 定时器误报（tearDown 时机晚于该校验，清理来不及）。
  @visibleForTesting
  static bool debugDisabled = false;

  /// 安排一次防抖增量导出；导出中重复调用会排一次收尾重跑（把窗口
  /// 期内新确认的页补进去）。
  static void schedule(String projectDir) {
    if (debugDisabled) return;
    _queuedDir = projectDir;
    _timer?.cancel();
    _timer = Timer(_debounce, () => unawaited(_run()));
  }

  static Future<void> _run() async {
    final dir = _queuedDir;
    if (dir == null || _running) return;
    _queuedDir = null;
    _running = true;
    try {
      final report = await PythonService.exportTrainDatasets(projectDir: dir);
      var exported = 0;
      final layers = report['layers'] as Map?;
      if (layers != null) {
        for (final value in layers.values) {
          final layerReport = value as Map?;
          exported +=
              ((layerReport?['new_pages'] as num?)?.toInt() ?? 0) +
              ((layerReport?['updated_pages'] as num?)?.toInt() ?? 0);
        }
      }
      if (exported > 0) {
        PythonService.addAppLog('[训练数据] 确认后自动增量导出：$exported 页已入账');
      }
      _doneController.add(null);
    } catch (e) {
      PythonService.addAppLog('[训练数据] 自动增量导出失败（训练页打开时会重试）：$e', isError: true);
    } finally {
      _running = false;
      // 导出期间又有确认排进来了：补一次收尾（不再防抖等待）。
      if (_queuedDir != null) {
        _timer?.cancel();
        _timer = Timer(const Duration(seconds: 2), () => unawaited(_run()));
      }
    }
  }

  /// 测试专用：取消挂起的防抖/收尾定时器并复位调度态。widget 测试的
  /// FakeAsync 区在用例结束时校验无 pending Timer——保存过确认标注的
  /// 用例都会留下 10 秒防抖定时器（onAnnotationSaved → schedule），
  /// 不清理会整批误报"A Timer is still pending"。
  @visibleForTesting
  static void debugReset() {
    _timer?.cancel();
    _timer = null;
    _running = false;
    _queuedDir = null;
  }
}
