import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'ollama_service.dart';

/// 拉取任务的生命周期阶段。
enum OllamaPullPhase {
  /// 排队等待（并发额度被占满，或恢复后等待用户确认）。
  queued,

  /// 下载进行中。状态在全局管理器里，离开设置页下载继续。
  pulling,

  /// 应用重启后从持久化记录恢复出的未完成任务，等用户点「继续下载」
  /// 或「忽略」。
  interrupted,

  /// 下载成功（页面据此刷新模型列表/自动选型，之后可被 dismiss）。
  succeeded,

  /// 下载失败（保留持久化记录，可重试；重启后按中断处理可续传）。
  failed,

  /// 用户主动取消（清除持久化记录；已下载的层留在 Ollama 缓存里，
  /// 下次拉取同一模型自动续传）。
  cancelled,
}

/// 一个模型的下载任务状态（由 [OllamaPullManager] 持有并驱动，页面只读
/// 渲染）。速度采用约 0.8s 一次采样的指数平滑。
class OllamaPullTask {
  OllamaPullTask({required this.model, required this.baseUrl});

  final String model;
  final String baseUrl;
  OllamaPullPhase phase = OllamaPullPhase.queued;
  double? progress;
  int completedBytes = 0;
  int totalBytes = 0;
  double speedBytesPerSec = 0;
  String status = '排队中…';
  String? error;

  bool get isActive =>
      phase == OllamaPullPhase.queued || phase == OllamaPullPhase.pulling;

  /// 行内进度条下的文字：百分比 + 速度（如 "61.3% · 42.1 MB/s"）。
  String get progressText {
    final buf = StringBuffer();
    if (progress != null) buf.write('${(progress! * 100).toStringAsFixed(1)}%');
    if (speedBytesPerSec > 0) {
      if (buf.isNotEmpty) buf.write(' · ');
      buf.write('${OllamaPullManager.formatBytes(speedBytesPerSec.round())}/s');
    }
    return buf.toString();
  }
}

/// Ollama 模型拉取的全局管理器（单例 ChangeNotifier）：**多任务队列**，
/// 支持「一次选多个模型下载 + 同时下载数设置（1~4）」。
///
/// 拉取状态独立于页面生命周期：离开设置页下载继续，返回即见进度与
/// 日志（页面只订阅渲染）。排队/下载中的任务持久化到
/// SharedPreferences（v2 列表格式，兼容读取 v1 单任务记录），应用重启后
/// [restore] 恢复为 [OllamaPullPhase.interrupted]，设置页给「继续下载」
/// ——Ollama 服务端对已下载的层/半截 blob 原生断点续传，重新发起
/// /api/pull 即从已下载字节继续，无需本管理器记字节进度。
class OllamaPullManager extends ChangeNotifier {
  OllamaPullManager._();

  static final OllamaPullManager instance = OllamaPullManager._();

  static const String _prefsKeyV2 = 'ollama_active_pulls_v2';
  static const String _prefsKeyV1 = 'ollama_active_pull_v1';
  static const String _concurrencyKey = 'ollama_pull_concurrency';
  static const int _maxConcurrency = 4;
  static const int _maxLogLines = 400;

  /// 拉取流的执行入口（测试注入点，生产即 OllamaService.pullModel）。
  @visibleForTesting
  static Stream<OllamaPullEvent> Function(
    String baseUrl,
    String model, {
    required http.Client client,
  }) pullRunner = OllamaService.pullModel;

  final List<OllamaPullTask> _tasks = <OllamaPullTask>[];
  final Map<String, Completer<void>> _finishers = {};
  final Map<String, http.Client> _clients = {};
  final Set<String> _cancelRequested = {};
  int _concurrency = 1;
  String? _lastSucceededModel;
  bool _restored = false;
  bool _concurrencyLoaded = false;
  final List<String> _log = [];

  // ── 只读状态（页面渲染用）──

  /// 全部任务（含排队/下载/已结束未清理的），按入队顺序。
  UnmodifiableListView<OllamaPullTask> get tasks =>
      UnmodifiableListView(_tasks);

  OllamaPullTask? taskOf(String model) {
    for (final t in _tasks) {
      if (t.model == model) return t;
    }
    return null;
  }

  /// 该模型正在排队或下载中（安装按钮防重复、删除互斥用）。
  bool isModelActive(String model) => taskOf(model)?.isActive ?? false;

  bool get isPulling =>
      _tasks.any((t) => t.phase == OllamaPullPhase.pulling);

  int get pullingCount =>
      _tasks.where((t) => t.phase == OllamaPullPhase.pulling).length;

  int get queuedCount =>
      _tasks.where((t) => t.phase == OllamaPullPhase.queued).length;

  /// 同时下载数（1~4）：并发调整会立刻放行排队任务。
  int get concurrency => _concurrency;

  Future<void> setConcurrency(int value) async {
    final v = value.clamp(1, _maxConcurrency);
    if (_concurrency == v) return;
    _concurrency = v;
    _appendLog('[ui] 同时下载数调整为 $v');
    notifyListeners();
    _pump();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_concurrencyKey, v);
    } catch (_) {}
  }

  String? get lastSucceededModel => _lastSucceededModel;

  /// 拉取日志（最近 400 行）。
  UnmodifiableListView<String> get log => UnmodifiableListView(_log);

  /// 字节数可读化（GB/MB/KB），设置页的磁盘占用显示也复用。
  static String formatBytes(num bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${bytes.round()} B';
  }

  /// 应用启动（或设置页首次打开）时恢复上次未完成的任务记录（排队/
  /// 下载/失败中的都算）。只在第一次调用生效，之后是空操作。
  Future<void> restore() async {
    if (_restored) return;
    _restored = true;
    if (!_concurrencyLoaded) {
      _concurrencyLoaded = true;
      try {
        final prefs = await SharedPreferences.getInstance();
        final saved = prefs.getInt(_concurrencyKey);
        if (saved != null) _concurrency = saved.clamp(1, _maxConcurrency);
      } catch (_) {}
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final entries = <Map<String, dynamic>>[];
      final rawV2 = prefs.getString(_prefsKeyV2);
      if (rawV2 != null && rawV2.isNotEmpty) {
        final j = Map<String, dynamic>.from(jsonDecode(rawV2) as Map);
        for (final e in (j['models'] as List? ?? const [])) {
          entries.add(Map<String, dynamic>.from(e as Map));
        }
      } else {
        // 兼容 v1 单任务记录。
        final rawV1 = prefs.getString(_prefsKeyV1);
        if (rawV1 != null && rawV1.isNotEmpty) {
          entries.add(Map<String, dynamic>.from(jsonDecode(rawV1) as Map));
        }
      }
      if (entries.isEmpty) return;
      for (final e in entries) {
        final model = e['model']?.toString() ?? '';
        if (model.isEmpty || taskOf(model) != null) continue;
        final task = OllamaPullTask(
          model: model,
          baseUrl: e['base_url']?.toString() ?? '',
        );
        task.phase = OllamaPullPhase.interrupted;
        task.status = '上次未完成';
        _tasks.add(task);
        _appendLog('[ui] 发现未完成的下载：$model（继续下载会从已下载部分续传）');
      }
      if (_tasks.isNotEmpty) notifyListeners();
    } catch (_) {
      // 记录损坏就当没有。
    }
  }

  /// 开始（或续传）一个模型下载：并发额度被占满时自动排队。同一模型
  /// 已在队列/下载中则忽略。返回的 Future 在该任务到达终态时完成。
  Future<void> start({required String baseUrl, required String model}) {
    _enqueue(baseUrl: baseUrl, model: model);
    return _finishers.putIfAbsent(model, () => Completer<void>()).future;
  }

  /// 一次入队多个模型（推荐列表多选用）。
  void startAll({required String baseUrl, required List<String> models}) {
    for (final m in models) {
      _enqueue(baseUrl: baseUrl, model: m);
    }
    notifyListeners();
  }

  void _enqueue({required String baseUrl, required String model}) {
    final existing = taskOf(model);
    if (existing != null && existing.isActive) return;
    if (existing != null) {
      // 上次已结束的同名任务：重入队前先移除旧记录（保留日志）。
      _tasks.remove(existing);
    }
    final task = OllamaPullTask(model: model, baseUrl: baseUrl);
    _tasks.add(task);
    _appendLog('[ui] ollama pull $model');
    _finishers.putIfAbsent(model, () => Completer<void>());
    _pump();
    notifyListeners();
  }

  /// 取消一个模型：下载中关闭连接（服务端保留缓存），排队中直接移除。
  void cancel(String model) {
    final task = taskOf(model);
    if (task == null) return;
    if (task.phase == OllamaPullPhase.pulling) {
      _cancelRequested.add(model);
      _clients[model]?.close();
      return;
    }
    if (task.phase == OllamaPullPhase.queued) {
      _tasks.remove(task);
      _appendLog('[ui] 已取消排队：$model');
      unawaited(_persistActive());
      _complete(model);
      notifyListeners();
    }
  }

  /// 取消全部（下载中与排队中的）。
  void cancelAll() {
    for (final t in List.of(_tasks)) {
      if (t.isActive) cancel(t.model);
    }
  }

  /// 清理一个已结束/中断的任务记录（提示条「忽略」）。
  void dismiss(String model) {
    final task = taskOf(model);
    if (task == null || task.isActive) return;
    _tasks.remove(task);
    notifyListeners();
    unawaited(_persistActive());
  }

  /// 清理全部已结束/中断的任务（日志一并清空）。
  void dismissAll() {
    _tasks.removeWhere((t) => !t.isActive);
    _log.clear();
    notifyListeners();
    unawaited(_persistActive());
  }

  // ── 调度 ──

  /// 放行排队任务直到填满并发额度。
  void _pump() {
    while (pullingCount < _concurrency) {
      final next = _tasks
          .where((t) => t.phase == OllamaPullPhase.queued)
          .toList()
          .firstOrNull;
      if (next == null) break;
      unawaited(_runTask(next));
    }
  }

  Future<void> _runTask(OllamaPullTask task) async {
    final model = task.model;
    final client = http.Client();
    _clients[model] = client;
    task.phase = OllamaPullPhase.pulling;
    task.progress = null;
    task.completedBytes = 0;
    task.totalBytes = 0;
    task.speedBytesPerSec = 0;
    task.status = '正在连接 Ollama…';
    task.error = null;
    var lastSpeedAt = DateTime.now();
    var lastSpeedBytes = 0;
    var nextProgressLogAt = DateTime.now();
    unawaited(_persistActive());
    notifyListeners();
    try {
      await for (final ev in pullRunner(task.baseUrl, model, client: client)) {
        final now = DateTime.now();
        // 速度：约 0.8s 采一次样做指数平滑，避免逐事件抖动。
        final dt = now.difference(lastSpeedAt).inMicroseconds / 1e6;
        if (dt >= 0.8) {
          final delta = ev.completedBytes - lastSpeedBytes;
          if (delta >= 0) {
            final instant = delta / dt;
            task.speedBytesPerSec = task.speedBytesPerSec <= 0
                ? instant
                : task.speedBytesPerSec * 0.6 + instant * 0.4;
          }
          lastSpeedAt = now;
          lastSpeedBytes = ev.completedBytes;
        }
        if (ev.error.isNotEmpty) task.error = ev.error;
        task.completedBytes = ev.completedBytes;
        task.totalBytes = ev.totalBytes;
        task.progress = ev.progress;
        task.status = _describeEvent(ev, task);
        // 日志：状态行直接记；逐层进度行每秒最多一条防刷屏。多任务
        // 并行时每行带模型名前缀，单任务保持原有格式。
        final tag = _activeTagCount() > 1 ? '[$model] ' : '';
        if (ev.error.isNotEmpty || ev.done) {
          _appendLog('$tag[pull] ${ev.error.isNotEmpty ? ev.error : ev.status}');
        } else if (ev.status.isNotEmpty && !_isLayerProgress(ev.status)) {
          _appendLog('$tag[pull] ${ev.status}');
        } else if (ev.status.isNotEmpty && !now.isBefore(nextProgressLogAt)) {
          _appendLog('$tag[pull] ${task.progressText} ${ev.status}');
          nextProgressLogAt = now.add(const Duration(seconds: 1));
        }
        notifyListeners();
      }
    } on OllamaException catch (e) {
      task.error = e.message;
      _appendLog('[$model] [error] ${e.message}');
    } catch (e) {
      // 主动取消（关闭 client）触发的中断走这里，不当错误。
      if (!_cancelRequested.contains(model)) {
        task.error = '下载中断：$e';
        _appendLog('[$model] [error] 下载中断：$e');
      }
    } finally {
      _clients.remove(model);
    }
    if (_cancelRequested.remove(model)) {
      task.phase = OllamaPullPhase.cancelled;
      task.status = '已取消';
      _appendLog('[$model] [ui] 已取消下载（已下载的层保留为缓存，下次拉取续传）');
    } else if (task.error != null) {
      task.phase = OllamaPullPhase.failed;
      _appendLog('[$model] [ui] 安装失败（可重试，已下载部分会续传）');
      // 失败保留持久化记录：重启后按「未完成」提示续传。
    } else {
      task.phase = OllamaPullPhase.succeeded;
      task.status = '完成';
      _lastSucceededModel = model;
      _appendLog('[$model] [ui] 安装完成');
    }
    _complete(model);
    unawaited(_persistActive());
    notifyListeners();
    // 腾出的额度立刻放行下一个排队任务。
    _pump();
  }

  int _activeTagCount() =>
      _tasks.where((t) => t.isActive).length;

  void _complete(String model) {
    final f = _finishers.remove(model);
    if (f != null && !f.isCompleted) f.complete();
  }

  String _describeEvent(OllamaPullEvent ev, OllamaPullTask task) {
    if (ev.error.isNotEmpty) return ev.error;
    if (ev.done) return '完成';
    final s = ev.status;
    if (s.contains('verifying')) return '校验完整性…';
    if (s.contains('writing manifest')) return '写入清单…';
    if (s.contains('manifest')) return '正在获取模型清单…';
    if (task.progress != null) {
      return '${formatBytes(task.completedBytes)} / ${formatBytes(task.totalBytes)} · '
          '${(task.progress! * 100).toStringAsFixed(1)}%';
    }
    return '下载中…';
  }

  /// 逐层下载进度行形如 "pulling sha256:abc…"（清单行是 "pulling
  /// manifest"，已由 contains('manifest') 先行拦截）。
  static bool _isLayerProgress(String status) =>
      status.startsWith('pulling sha256:');

  void _appendLog(String line) {
    _log.add(line);
    if (_log.length > _maxLogLines) {
      _log.removeRange(0, _log.length - _maxLogLines);
    }
  }

  /// 持久化排队/下载/失败中的任务（成功与取消的不记）。
  Future<void> _persistActive() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final active = [
        for (final t in _tasks)
          if (t.phase == OllamaPullPhase.queued ||
              t.phase == OllamaPullPhase.pulling ||
              t.phase == OllamaPullPhase.failed)
            {'model': t.model, 'base_url': t.baseUrl},
      ];
      if (active.isEmpty) {
        await prefs.remove(_prefsKeyV2);
        await prefs.remove(_prefsKeyV1);
      } else {
        await prefs.setString(_prefsKeyV2, jsonEncode({'models': active}));
        await prefs.remove(_prefsKeyV1);
      }
    } catch (_) {
      // 持久化失败只影响重启后的续传提示，不阻塞下载。
    }
  }

  /// 测试复位：清空全部内存状态（持久化由用例自行 setMockInitialValues）。
  @visibleForTesting
  void resetForTest() {
    for (final c in _clients.values) {
      c.close();
    }
    _tasks.clear();
    _clients.clear();
    _cancelRequested.clear();
    for (final f in _finishers.values) {
      if (!f.isCompleted) f.complete();
    }
    _finishers.clear();
    _concurrency = 1;
    _lastSucceededModel = null;
    _restored = false;
    _concurrencyLoaded = false;
    _log.clear();
  }
}
