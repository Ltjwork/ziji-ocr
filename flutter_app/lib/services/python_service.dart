import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show Rect;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import '../models/models.dart';
import '../models/table_block.dart';
import 'isolate_codec.dart';
import 'ollama_service.dart' show OllamaSettings;

/// 服务基准地址：默认 1288；服务端在 1288 被 Windows 端口保留区
/// （winnat/Hyper-V/WSL 随机保留段，bind 报 Errno 13）占用时会自动
/// 避让到 8766-8790 并把实际端口写入 service_port.txt，本类随后跟随。
const int _kBasePort = 1288;
const String _kPortFileName = 'service_port.txt';
String _base = 'http://127.0.0.1:$_kBasePort';
// Keep the client gate in lock-step with the backend build string: accepting
// an older build silently leaves the app talking to an older segmenter (and
// makes the new layout/ink rules appear to have no effect).
const _expectedBackendBuild = 'model-manage-epochs-2026-10-15-v156';

/// 测试专用：把服务基地址指到别处（如一个已关闭的本地端口，模拟
/// 「后端未启动/被关闭」时的连接被拒）。不落盘、不写端口文件；调用方
/// 自行在 tearDown 恢复。测试 isolate 里从未 start() 过时
/// [_logServiceDir] 为 null，失联守卫只转中文异常、不会真拉后端进程。
@visibleForTesting
void debugSetServiceBase(String url) => _base = url;

/// 最近一段 stderr 输出（启动失败时附到异常信息里，避免"转圈半天后
/// 只看到与真实原因无关的通用提示"）。
final List<String> _recentStderr = [];

/// 后端识别门最多允许 2 个识别请求在途（页间流水线）；队列 2 页在途时
/// 再发起的第三个识别请求会收到 409。
class RecognitionBusyException implements Exception {
  final String body;
  RecognitionBusyException(this.body);

  @override
  String toString() => '识别服务忙：$body';
}

/// 表格识别 422：区域内格线不足（外框 + 至少一条内部横/竖线才算
/// 表格；无线表格暂不支持）。message 是后端 reason，直接提示用户。
class TableGridNotFoundException implements Exception {
  final String message;
  TableGridNotFoundException(this.message);

  @override
  String toString() => message;
}

/// 后端进程不在（连接被拒/连接中断）：后端中途退出（控制台窗口被关、
/// 系统休眠/重启、进程崩溃）后第一个撞上死端口的请求抛出，message 是
/// 可指导行动的中文。继承 http.ClientException——识别队列等既有按
/// ClientException 识别「后端不可达」的捕获分支（长等待预算）零改动
/// 继续生效。
class BackendUnavailableException extends http.ClientException {
  BackendUnavailableException(super.message);

  @override
  String toString() => message; // UI 直接展示时只有中文指引，不带英文原文
}

/// 从 FastAPI 错误响应体 `{"detail": "..."}` 中提取可读信息；解析失败时
/// 原样返回，保证调用方总能拿到一段文本。
String _detailOf(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map && decoded['detail'] != null) {
      return decoded['detail'].toString();
    }
  } catch (_) {}
  return body;
}

/// 整机资源占用快照（任务管理器口径），供识别监控悬浮窗画曲线。与
/// [ServiceStats]（识别服务进程树口径）区分。跨语言格式基准：字段以
/// python_service/api_base.py 的 `_system_stats` 为准，本类镜像解析；
/// 只追加字段不改名。
class SystemStats {
  final double cpuPercent;
  final int memoryUsedBytes;
  final int memoryTotalBytes;

  /// 整卡 GPU 利用率/显存（nvidia-smi 第 0 卡）；无 N 卡或查询失败为
  /// null（悬浮窗显存行显示"不可用"）。
  final double? gpuUtilPercent;
  final int? vramUsedBytes;
  final int? vramTotalBytes;

  const SystemStats({
    required this.cpuPercent,
    required this.memoryUsedBytes,
    required this.memoryTotalBytes,
    this.gpuUtilPercent,
    this.vramUsedBytes,
    this.vramTotalBytes,
  });

  double get memoryRatio =>
      memoryTotalBytes <= 0 ? 0 : memoryUsedBytes / memoryTotalBytes;

  double? get vramRatio => vramTotalBytes == null || vramTotalBytes! <= 0
      ? null
      : vramUsedBytes! / vramTotalBytes!;

  factory SystemStats.fromJson(Map<String, dynamic> j) => SystemStats(
    cpuPercent: (j['cpu_percent'] as num?)?.toDouble() ?? 0,
    memoryUsedBytes: (j['memory_used_bytes'] as num?)?.toInt() ?? 0,
    memoryTotalBytes: (j['memory_total_bytes'] as num?)?.toInt() ?? 0,
    gpuUtilPercent: (j['gpu_util_percent'] as num?)?.toDouble(),
    vramUsedBytes: (j['vram_used_bytes'] as num?)?.toInt(),
    vramTotalBytes: (j['vram_total_bytes'] as num?)?.toInt(),
  );
}

/// 识别服务进程树（服务 + 常驻 Kraken daemon）的资源占用快照。
class ServiceStats {
  final double cpuPercent;
  final int memoryBytes;
  final int? vramBytes;

  /// Kraken daemon 池规模：计划并行数 / 已就绪数；服务旧版本或未建池时
  /// 为 null（首页不展示"并行"项）。
  final int? workersTotal;
  final int? workersReady;

  /// 整机口径占用（CPU/内存/整卡 GPU），悬浮窗曲线用；服务旧版本时为
  /// null（悬浮窗系统区显示"不可用"）。
  final SystemStats? system;

  const ServiceStats({
    required this.cpuPercent,
    required this.memoryBytes,
    this.vramBytes,
    this.workersTotal,
    this.workersReady,
    this.system,
  });

  factory ServiceStats.fromJson(Map<String, dynamic> j) {
    final workers = j['workers'];
    final workersMap = workers is Map ? workers : null;
    final system = j['system'];
    return ServiceStats(
      cpuPercent: (j['cpu_percent'] as num?)?.toDouble() ?? 0,
      memoryBytes: (j['memory_bytes'] as num?)?.toInt() ?? 0,
      vramBytes: (j['vram_bytes'] as num?)?.toInt(),
      workersTotal: (workersMap?['total'] as num?)?.toInt(),
      workersReady: (workersMap?['ready'] as num?)?.toInt(),
      system: system is Map
          ? SystemStats.fromJson(Map<String, dynamic>.from(system))
          : null,
    );
  }
}

/// /segment debug=true 的返回结果。
class DebugSegmentResult {
  final String? debugImagePath;
  final String? maskImagePath;
  final int linesCount;
  final int blocksCount;
  final String engine;
  final Map<String, dynamic> raw;

  const DebugSegmentResult({
    required this.debugImagePath,
    required this.maskImagePath,
    required this.linesCount,
    required this.blocksCount,
    required this.engine,
    required this.raw,
  });
}

/// /char_clusters 的返回结果：一页字块按墨迹形态的分组。
class CharClusterGroup {
  final List<String> blockIds;
  final double cohesion; // 组内平均两两距离，越小越像

  const CharClusterGroup({required this.blockIds, required this.cohesion});

  int get size => blockIds.length;
}

class CharClusterResult {
  final List<CharClusterGroup> clusters; // 按组大小降序，size >= 2
  final List<String> singletons; // 有效但落单的字块 id
  final List<String> skipped; // 无法提特征（空框/无墨迹）的字块 id
  final double elapsedMs;

  /// 仅批量接口：聚类失败被跳过的页（image_path -> 错误信息）。
  final List<MapEntry<String, String>> failedPages;

  const CharClusterResult({
    required this.clusters,
    required this.singletons,
    required this.skipped,
    required this.elapsedMs,
    this.failedPages = const [],
  });
}

/// /char_clusters_batch 的一页输入：页面图 + 参与聚类的正文字块。
class CharClusterBatchPage {
  final String imagePath;
  final List<CharBlock> blocks;

  const CharClusterBatchPage({required this.imagePath, required this.blocks});
}

/// 单字墨迹校验结果（/verify_char*）。
class CharVerifyOutcome {
  /// ok=通过 / suspect=存疑 / mismatch=识别与墨迹结构不符 /
  /// skipped=未校验（标点、缺字、空墨迹等）。
  final String level;

  /// 综合分（0~1，拓扑计数+特征点位置+骨架形状三层加权）。
  final double? score;

  /// skipped 的原因码（empty_text / punct_or_symbol / glyph_missing 等）。
  final String? reason;

  /// 完整后端返回（parts/topology/debug_image_b64 等），属性面板展示
  /// 拓扑差异明细与叠加图时用。
  final Map<String, dynamic> raw;

  const CharVerifyOutcome({
    required this.level,
    required this.raw,
    this.score,
    this.reason,
  });

  factory CharVerifyOutcome.fromJson(Map<String, dynamic> j) =>
      CharVerifyOutcome(
        level: j['level']?.toString() ?? 'skipped',
        score: (j['score'] as num?)?.toDouble(),
        reason: j['reason'] as String?,
        raw: j,
      );

  bool get isFlagged => level == 'mismatch' || level == 'suspect';
}

class CharVerifyBatchResult {
  final Map<String, CharVerifyOutcome> results; // 字块 id -> 校验结果
  final Map<String, String> errors; // 单字异常（不中断整批）
  final double elapsedMs;

  const CharVerifyBatchResult({
    required this.results,
    required this.errors,
    required this.elapsedMs,
  });
}

class BackendLogEntry {
  final DateTime time;
  final String source;
  final String message;
  final bool isError;

  const BackendLogEntry({
    required this.time,
    required this.source,
    required this.message,
    this.isError = false,
  });

  String get timeLabel {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    final s = time.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}

/// 一张行条裁图请求（AI 框检查的诊断素材）：行框 + 可选叠加的当前
/// 字框（boxes 为 (x,y,w,h) 四元组列表，按阅读序）。
class LineThumbRequest {
  final String imagePath;
  final int x;
  final int y;
  final int w;
  final int h;
  final String orientation;
  final List<(int, int, int, int)>? boxes;

  const LineThumbRequest({
    required this.imagePath,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    this.orientation = 'vertical',
    this.boxes,
  });
}

/// 一行的墨迹测量结果（/line_ink）：charInkMedian 为逐字框核心区结构
/// 性墨迹占比的中位数（实测校准：真文字行 ≈0.23~0.47，空白带的幽灵
/// 行 ≈0）；blankChars 为核心墨迹 <0.05 的字框数。
class LineInkResult {
  final double charInkMedian;
  final int blankChars;
  final int charCount;

  const LineInkResult({
    required this.charInkMedian,
    required this.blankChars,
    required this.charCount,
  });

  factory LineInkResult.fromJson(Map<String, dynamic> j) => LineInkResult(
    charInkMedian: (j['char_ink_median'] as num?)?.toDouble() ?? 0,
    blankChars: (j['blank_chars'] as num?)?.toInt() ?? 0,
    charCount: (j['char_count'] as num?)?.toInt() ?? 0,
  );
}

class LayoutRepairProposal {
  const LayoutRepairProposal({
    required this.targetId,
    required this.action,
    required this.rects,
    required this.confidence,
    required this.reason,
  });

  final String targetId;
  final String action;
  final List<List<int>> rects;
  final double confidence;
  final String reason;

  factory LayoutRepairProposal.fromJson(Map<String, dynamic> j) =>
      LayoutRepairProposal(
        targetId: j['target_id']?.toString() ?? '',
        action: j['action']?.toString() ?? '',
        rects: (j['rects'] as List? ?? const [])
            .whereType<List>()
            .map((r) => r.map((v) => (v as num).toInt()).toList())
            .toList(),
        confidence: (j['confidence'] as num?)?.toDouble() ?? 0,
        reason: j['reason']?.toString() ?? '',
      );
}

class LayoutAnalysis {
  const LayoutAnalysis({
    required this.lines,
    required this.repairs,
    required this.diagnostics,
  });

  final List<Map<String, dynamic>> lines;
  final List<LayoutRepairProposal> repairs;
  final Map<String, dynamic> diagnostics;

  factory LayoutAnalysis.fromJson(Map<String, dynamic> j) => LayoutAnalysis(
    lines: (j['lines'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(),
    repairs: (j['repairs'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => LayoutRepairProposal.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
    diagnostics: j['diagnostics'] is Map
        ? Map<String, dynamic>.from(j['diagnostics'] as Map)
        : const {},
  );
}

/// 版面区预标注建议（/region_prelabel）：一条 proposed 候选区。
class RegionPrelabelSuggestion {
  const RegionPrelabelSuggestion({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.label,
    required this.confidence,
    required this.reason,
  });

  final int x, y, w, h;
  final String label;
  final double confidence;
  final String reason;

  factory RegionPrelabelSuggestion.fromJson(Map<String, dynamic> j) =>
      RegionPrelabelSuggestion(
        x: (j['x'] as num).toInt(),
        y: (j['y'] as num).toInt(),
        w: (j['w'] as num).toInt(),
        h: (j['h'] as num).toInt(),
        label: j['label']?.toString() ?? RegionLabel.mainText,
        confidence: (j['confidence'] as num?)?.toDouble() ?? 0,
        reason: j['reason']?.toString() ?? '',
      );

  Map<String, dynamic> toRequest() => {
    'x': x,
    'y': y,
    'w': w,
    'h': h,
    'label': label,
    if (confidence > 0) 'confidence': confidence,
  };
}

class RegionPrelabelResult {
  const RegionPrelabelResult({
    required this.suggestions,
    required this.neighborsChecked,
  });

  final List<RegionPrelabelSuggestion> suggestions;
  final int neighborsChecked;

  factory RegionPrelabelResult.fromJson(Map<String, dynamic> j) =>
      RegionPrelabelResult(
        suggestions: (j['suggestions'] as List? ?? const [])
            .whereType<Map>()
            .map(
              (e) => RegionPrelabelSuggestion.fromJson(
                Map<String, dynamic>.from(e),
              ),
            )
            .toList(),
        neighborsChecked: (j['neighbors_checked'] as num?)?.toInt() ?? 0,
      );
}

/// 几何精修结果（/region_refine）：通过项 + 各项丢弃原因（VLM 坐标安全层）。
class RegionRefineResult {
  const RegionRefineResult({required this.regions, required this.dropped});

  final List<RegionPrelabelSuggestion> regions;
  final List<Map<String, dynamic>> dropped;

  factory RegionRefineResult.fromJson(Map<String, dynamic> j) =>
      RegionRefineResult(
        regions: (j['regions'] as List? ?? const [])
            .whereType<Map>()
            .map(
              (e) => RegionPrelabelSuggestion.fromJson(
                Map<String, dynamic>.from(e),
              ),
            )
            .toList(),
        dropped: (j['dropped'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList(),
      );
}

/// VLM 素材图（/page_prelabel_image）：base64 PNG + 画布/原图几何元数据。
class PagePrelabelMaterial {
  const PagePrelabelMaterial({
    required this.base64,
    required this.width,
    required this.height,
    required this.origWidth,
    required this.origHeight,
    required this.scale,
  });

  final String base64;

  /// 素材图画布尺寸（VLM 看到的像素坐标口径）。
  final int width, height;

  /// 原图尺寸。
  final int origWidth, origHeight;

  /// 素材图 ÷ 原图的比例（只缩不放，≤1）。
  final double scale;

  factory PagePrelabelMaterial.fromJson(Map<String, dynamic> j) =>
      PagePrelabelMaterial(
        base64: j['image_base64'] as String,
        width: (j['width'] as num).toInt(),
        height: (j['height'] as num).toInt(),
        origWidth: (j['orig_width'] as num).toInt(),
        origHeight: (j['orig_height'] as num).toInt(),
        scale: (j['scale'] as num).toDouble(),
      );
}

class PythonService {
  static Process? _process;

  /// 启动流程进行中（应用启动或自动重启）：期间失联守卫不再拉第二个
  /// 后端进程。
  static bool _starting = false;
  static const int _maxLogEntries = 5000;
  static final List<BackendLogEntry> _logs = <BackendLogEntry>[];
  static final StreamController<BackendLogEntry> _logController =
      StreamController<BackendLogEntry>.broadcast();

  static Stream<BackendLogEntry> get logs => _logController.stream;
  static List<BackendLogEntry> get logSnapshot => List.unmodifiable(_logs);

  /// 启动后端全流程（端口文件跟随/旧版清理/拉进程/健康等待）。应用启动
  /// 与失联自动重启（[_reviveBackend]）都走这里；[_starting] 标记进行中，
  /// 防止两条路径并发拉起两个后端。
  static Future<void> start(
    String pythonServiceDir, {
    String startupLabel = '应用启动',
  }) {
    _starting = true;
    return _startBackend(
      pythonServiceDir,
      startupLabel,
    ).whenComplete(() => _starting = false);
  }

  static Future<void> _startBackend(
    String pythonServiceDir,
    String startupLabel,
  ) async {
    // 先登记日志目录：随后的启动日志（端口检测/复用/启动步骤）全部落
    // 盘 app_console.log，独立 CMD 日志窗口从这里就能看到启动过程。
    _logServiceDir = pythonServiceDir;
    await _ensureConsoleLogFiles(pythonServiceDir);
    _addLog(
      'app',
      '===== $startupLabel ${DateTime.now().toString().split('.').first} =====',
    );
    // 跟随服务端口文件：服务端 1288 被系统保留时会避让到后续空闲端口
    // （最多探测 500 个），每次启动先按文件里的端口做复用/旧版检测。
    final portFromFile = _readPortFromFile(pythonServiceDir);
    if (portFromFile != null) {
      _base = 'http://127.0.0.1:$portFromFile';
    }
    final portLabel = _activePort;
    final health = await _readHealth();
    if (health != null) {
      final build = health['build']?.toString();
      _addLog(
        'app',
        '检测到 $portLabel 端口已有 Python 后端：build=${build ?? 'missing'}。',
      );
      if (build == _expectedBackendBuild) {
        _addLog('app', 'Python 后端已就绪，复用当前服务。');
        return;
      }
      _addLog(
        'app',
        '检测到旧版 Python 后端，当前端口 $portLabel 正在运行 build=${build ?? 'missing'}，期望 build=$_expectedBackendBuild。准备自动关闭旧后端并重新启动。',
        isError: true,
      );
      final stopped = await _stopBackendOnPort();
      if (!stopped) {
        throw Exception(
          'Stale Python backend is already running on port $portLabel, but it could not be stopped automatically.',
        );
      }
      final released = await _waitUntilPortReleased();
      if (!released) {
        throw Exception(
          'Stale Python backend was stopped, but port $portLabel is still not released.',
        );
      }
      _addLog('app', '旧版 Python 后端已关闭，开始启动当前版本。');
    } else if (await _isPortOccupied()) {
      // 服务无响应但端口被占（旧后端卡在模型加载/识别中，健康检查 1s
      // 超时）：直接启动会在 bind 时报 10048 退出，先关闭占用者。
      _addLog('app', '$portLabel 端口被占用但后端无响应，先关闭占用进程再启动。', isError: true);
      final stopped = await _stopBackendOnPort();
      if (!stopped) {
        throw Exception(
          'Port $portLabel is occupied by an unresponsive process that could not be stopped.',
        );
      }
      final released = await _waitUntilPortReleased();
      if (!released) {
        throw Exception(
          'Port $portLabel is still not released after stopping the unresponsive process.',
        );
      }
      _addLog('app', '占用端口的进程已关闭，开始启动当前版本。');
    }
    final useConsoleWindow = autoOpenLogConsole(serviceDir: pythonServiceDir);
    // 识别进程数设置（Kraken daemon 池）：非空时经环境变量覆盖后端的
    // 自动硬件决策；null/未配置则不传，后端自行按显存与 CPU 决策。
    String? krakenWorkersEnv;
    try {
      final settings = await OllamaSettings.load();
      final n = settings.krakenWorkers;
      if (n != null && n > 0) krakenWorkersEnv = n.toString();
    } catch (_) {}
    // 仅在窗口模式实际成功拉起后端后才置 true（stop() 据此决定按端口
    // 清理；服务从未启动时不能动端口，否则测试环境的 Process.run 会留
    // 下挂起 Timer）。
    _consoleWindowMode = false;
    if (useConsoleWindow) {
      // ComfyUI 式：后端进程直接跑在独立控制台窗口里，从进程诞生起
      // 原生打印全部输出（conda 启动/端口选择/模型加载/识别全程），
      // 崩溃后窗口保留现场（cmd /k）。应用侧没有进程句柄，停止用按
      // 端口 taskkill；后端输出去 service_console.log 跟随器拿回来。
      _addLog(
        'app',
        '正在启动 Python 后端（独立控制台窗口）：conda run -n paddle python main.py',
      );
      _addLog('app', '工作目录：$pythonServiceDir');
      try {
        // 复合命令（set && conda run）不能直接作为 start 的参数：Dart 对
        // 含空格参数自动加引号，cmd 的引号剥离规则遇到 &&/> 等元字符会
        // 失效，整串被当文件名执行——窗口开了命令却立刻失败（实测根
        // 因）。启动逻辑放 run_backend_console.cmd，start 只调裸文件名
        // （已实测：exitCode=0 且批处理正常执行）。标题也不用 start 传
        // （无空格的标题不加引号会被当命令），批处理内 title 设置。
        final launched = await Process.run(
          'cmd',
          ['/c', 'start', '/D', pythonServiceDir, 'run_backend_console.cmd'],
          environment: {
            ...Platform.environment,
            if (krakenWorkersEnv != null)
              'OCR_KRAKEN_WORKERS': krakenWorkersEnv,
          },
        );
        if (launched.exitCode != 0) {
          _addLog(
            'app',
            '独立控制台启动失败（exitCode=${launched.exitCode}），回退无窗口模式。'
                '${launched.stderr.toString().trim()}',
            isError: true,
          );
          _consoleWindowMode = false;
        } else {
          _consoleWindowMode = true;
          _addLog(
            'app',
            '后端已在独立控制台窗口中启动（关闭窗口即停止后端；'
                '输出同时记录到 logs/service_console.log）。',
          );
          _startServiceLogFollower();
        }
      } catch (e) {
        _addLog('app', '独立控制台启动异常：$e，回退无窗口模式。', isError: true);
        _consoleWindowMode = false;
      }
    }
    if (!_consoleWindowMode) {
      _addLog(
        'app',
        '正在启动 Python 后端：conda run --no-capture-output -n paddle python main.py',
      );
      _addLog('app', '工作目录：$pythonServiceDir');
      debugPrint('[py] starting backend with conda environment: paddle');
      final process = await Process.start(
        'conda',
        [
          'run',
          // conda run 默认捕获子进程 stdout 直到退出才整体吐出（实测
          // LINE-A 与 3 秒后的 LINE-B 同刻到达）——服务日志（含 worker
          // 透传的 mark stats 标点诊断）全部被扣在缓冲里，控制台一条
          // 服务行都看不到。--no-capture-output 让子进程直连管道，
          // 逐行实时到达（实测 A 立刻、B 3 秒后）。
          '--no-capture-output',
          '-n',
          'paddle',
          'python',
          'main.py',
        ],
        workingDirectory: pythonServiceDir,
        runInShell: true,
        environment: {
          ...Platform.environment,
          // 强制 Python（含 conda run 转发链）全链路按 UTF-8 输出，
          // 避免中文 Windows 下 GBK/UTF-8 混解导致日志乱码。
          'PYTHONUTF8': '1',
          'PYTHONIOENCODING': 'utf-8',
          if (krakenWorkersEnv != null) 'OCR_KRAKEN_WORKERS': krakenWorkersEnv,
        },
      );
      _process = process;
      _addLog('app', '后端进程已启动，PID=${process.pid}，等待 /health 响应。');
      process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((s) => _addLog('stdout', s));
      process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((s) {
            _addLog('stderr', s, isError: true);
            _recentStderr.add(s);
            if (_recentStderr.length > 15) {
              _recentStderr.removeAt(0);
            }
          });
      process.exitCode.then((code) {
        _addLog('app', '后端进程已退出，exitCode=$code。', isError: code != 0);
        if (identical(_process, process)) _process = null;
      });
    }
    for (var i = 0; i < 60; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      // 服务端避让端口后会更新 service_port.txt，跟随实际端口。
      final port = _readPortFromFile(pythonServiceDir);
      if (port != null && port != _activePort) {
        _base = 'http://127.0.0.1:$port';
        _addLog('app', '服务使用备用端口 $port（1288 可能被系统保留），已跟随。');
      }
      final health = await _readHealth();
      if (health != null) {
        final build = health['build']?.toString();
        _addLog('app', 'Python 后端健康检查通过：build=${build ?? 'missing'}。');
        if (build != _expectedBackendBuild) {
          _addLog(
            'app',
            '新启动的 Python 后端版本不匹配，期望 build=$_expectedBackendBuild，实际 build=${build ?? 'missing'}。',
            isError: true,
          );
          throw Exception(
            'Python backend build mismatch: ${build ?? 'missing'}',
          );
        }
        _addLog('app', 'OCR 服务可用。');
        return;
      }
    }
    _addLog('app', 'Python 后端启动超时，未等到 /health 响应。', isError: true);
    var stderrTail = _recentStderr.join('\n').trim();
    if (stderrTail.isEmpty) {
      // 窗口模式没有管道：后端输出在 service_console.log（tee 落盘），
      // 直接取末尾几行作为失败诊断。
      stderrTail = _tailServiceConsole(maxLines: 15) ?? '';
    }
    final bindBlocked =
        stderrTail.contains('error while attempting to bind') ||
        stderrTail.contains('Errno 13') ||
        stderrTail.contains('10013');
    throw Exception(
      'Python 服务启动失败。'
      '${stderrTail.isEmpty ? '' : '\n后端错误输出（末 15 行）：\n$stderrTail\n'}'
      '${bindBlocked ? '\n端口绑定被拒（Errno 13）：多半落入了 Windows 端口保留区'
                '（Hyper-V/WSL/Docker 的 winnat 保留段，可用命令查看：netsh interface ipv4 show '
                'excludedportrange protocol=tcp）。服务会自动避让到空闲端口并由应用跟随；'
                '若仍失败，请以管理员身份运行 "net stop winnat"，启动本应用后再 "net start winnat"。' : ''}'
      '\n若与端口无关，请运行 python_service\\install.bat 并确认 conda 在 PATH 中。',
    );
  }

  /// 当前服务端口（从 [_base] 解析）。
  static int get _activePort {
    final port = Uri.tryParse(_base)?.port;
    return (port == null || port <= 0) ? _kBasePort : port;
  }

  /// 读取服务写入的 service_port.txt（端口避让后的实际端口）。
  static int? _readPortFromFile(String pythonServiceDir) {
    try {
      final file = File(
        '$pythonServiceDir${Platform.pathSeparator}$_kPortFileName',
      );
      if (!file.existsSync()) return null;
      final port = int.tryParse(file.readAsStringSync().trim());
      if (port == null || port < 1024 || port > 65535) return null;
      return port;
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> _readHealth() async {
    try {
      final r = await http
          .get(Uri.parse('$_base/health'))
          .timeout(const Duration(seconds: 1));
      if (r.statusCode != 200) return null;
      final data = jsonDecode(r.body);
      if (data is Map<String, dynamic>) return data;
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _waitUntilPortReleased() async {
    for (var i = 0; i < 20; i++) {
      await Future.delayed(const Duration(milliseconds: 250));
      if (!await _isPortOccupied()) return true;
    }
    return false;
  }

  /// 服务端口是否被任意进程监听（能建立 TCP 连接即视为占用）。
  static Future<bool> _isPortOccupied() async {
    try {
      final socket = await Socket.connect(
        '127.0.0.1',
        _activePort,
        timeout: const Duration(milliseconds: 800),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _stopBackendOnPort() async {
    if (!Platform.isWindows) {
      _addLog('app', '当前系统暂不支持自动关闭旧后端，请手动释放 $_activePort 端口。', isError: true);
      return false;
    }

    final port = _activePort;
    final pids = await _findWindowsPidsOnPort(port);
    if (pids.isEmpty) {
      _addLog('app', '未找到占用 $port 端口的进程，准备直接重试启动。');
      return true;
    }

    var allStopped = true;
    for (final pid in pids) {
      final result = await Process.run('taskkill', [
        '/PID',
        pid.toString(),
        '/T', // 连同子进程树一起结束，避免常驻 kraken worker 变孤儿
        '/F',
      ], runInShell: true);
      final output = '${result.stdout}${result.stderr}'.trim();
      if (result.exitCode == 0) {
        _addLog('app', '已关闭占用 $port 端口的旧后端进程：PID=$pid。');
      } else {
        allStopped = false;
        _addLog(
          'app',
          '关闭旧后端进程失败：PID=$pid exitCode=${result.exitCode} $output',
          isError: true,
        );
      }
    }
    return allStopped;
  }

  static Future<Set<int>> _findWindowsPidsOnPort(int port) async {
    final result = await Process.run('netstat', ['-ano'], runInShell: true);
    if (result.exitCode != 0) {
      _addLog(
        'app',
        '查询端口占用失败：exitCode=${result.exitCode} ${'${result.stderr}'.trim()}',
        isError: true,
      );
      return <int>{};
    }

    final pids = <int>{};
    final lines = '${result.stdout}'.split(RegExp(r'\r?\n'));
    for (final line in lines) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 5) continue;
      final localAddress = parts[1];
      final state = parts.length >= 5 ? parts[3] : '';
      final pidText = parts.last;
      final isTargetPort =
          localAddress.endsWith(':$port') ||
          localAddress.endsWith('.$port') ||
          localAddress == '[::]:$port';
      if (!isTargetPort) continue;
      if (state != 'LISTENING') continue;
      final pid = int.tryParse(pidText);
      if (pid != null && pid > 0) pids.add(pid);
    }
    return pids;
  }

  static void stop() {
    // 保留同步入口供应用 dispose 使用；需要确认退出完成的调用方使用
    // stopAndWait，避免安装器启动时仍有 DLL/后端文件被占用。
    unawaited(stopAndWait());
  }

  /// 停止后端并等待直接进程及其监听端口释放。
  static Future<bool> stopAndWait() async {
    _addLog('app', '正在停止 Python 后端。');
    _stopServiceLogFollower();
    final process = _process;
    _process = null;
    // 本会话从未启动过后端（无直接子进程、未走过独立控制台模式）：
    // 没有本应用可停的进程，端口若被占用也是外部实例的事——直接返回，
    // 不做 20×250ms 的端口等待（此前无条件等待让应用退出路径白等、
    // widget 冒烟测试销毁时留下挂起计时器而必挂）。
    if (process == null && !_consoleWindowMode) return true;
    if (process != null) {
      try {
        process.kill();
        await process.exitCode.timeout(const Duration(seconds: 5));
      } catch (_) {
        // 进程已退出或无法读取 exitCode，继续用端口状态确认。
      }
    }
    // conda run 会再派生 Python 子进程；Windows 上仅 kill 直接句柄
    // 可能留下子进程，所以统一按服务端口结束整棵进程树。
    if (Platform.isWindows && (_consoleWindowMode || process != null)) {
      _consoleWindowMode = false;
      final stopped = await _stopBackendOnPort();
      if (!stopped) return false;
    }
    return _waitUntilPortReleased();
  }

  // ── 后端失联自动恢复 ─────────────────────────────────────────────────
  // 后端进程中途退出（控制台窗口被关、系统休眠/重启、崩溃）后，应用侧
  // 不会再次拉起（start 只在应用启动时调用），此后所有请求只剩裸的英文
  // 连接被拒（2026-10-06 实测：摆正页预览「预览失败: ClientException …
  // errno = 1225」，此时后端 1754 端口已无监听、系统里没有 Python 进程）。
  // 第一个撞上死端口的交互请求触发一次自动重启（复用 start 全流程），
  // 其余并发请求快速失败为中文提示；2 分钟冷却防止后端反复崩时被无限
  // 拉起。轮询类接口（/health、/process_stats 等）不触发——用户有意
  // 关掉后端时不应被后台轮询反复拉活，等下一次真正的交互操作再说。
  static Future<void>? _reviveTask;
  static DateTime? _lastReviveAt;
  static const Duration _reviveCooldown = Duration(minutes: 2);

  static void _scheduleBackendRevive() {
    final dir = _logServiceDir;
    // 测试环境（debugSetServiceBase 指向死端口、从未 start()）不拉进程。
    if (dir == null) return;
    if (_starting || _reviveTask != null) return;
    final last = _lastReviveAt;
    if (last != null && DateTime.now().difference(last) < _reviveCooldown) {
      return;
    }
    _lastReviveAt = DateTime.now();
    _reviveTask = _reviveBackend(dir).whenComplete(() => _reviveTask = null);
  }

  static Future<void> _reviveBackend(String dir) async {
    _addLog('app', '后端连接失败，自动重启后端（约需半分钟）…', isError: true);
    try {
      await start(dir, startupLabel: '后端自动重启');
      _addLog('app', '后端自动重启成功，服务已恢复。');
    } catch (e) {
      _addLog('app', '后端自动重启失败：$e。2 分钟冷却后才会再试；也可重启应用手动拉起。', isError: true);
    }
  }

  /// 失联时给用户的中文指引（按自动重启所处阶段选词）。
  static String _backendDownMessage() => _reviveTask != null
      ? '后端服务不可达（后端进程已退出，例如控制台窗口被关闭或系统重启过）。'
            '正在自动重启后端（约需半分钟），完成后请重试本操作'
      : '后端服务不可达，且自动重启未成功或仍在冷却（详见后台日志）。'
            '请检查后端控制台窗口，或重启应用';

  /// 测试注入的 HTTP 客户端（null = 真实网络）。widget 测试的 FakeAsync
  /// 区里真实 socket 永不完成（测试框架还会把 HttpClient 全局拦截成
  /// 400）；注入 MockClient 同步回放响应，整条链路确定性走完（IO 类
  /// 仍需 tester.runAsync 放行，见各测试的 drain 助手）。
  @visibleForTesting
  static http.Client? debugHttpClient;

  /// 交互请求的统一出口：连接级失败（后端未启动/中途退出，连接被拒或
  /// 中断）转为中文的 [BackendUnavailableException] 并触发一次自动重启；
  /// HTTP 状态码错误与超时不在此层，各调用方原有处理不变。轮询/探测类
  /// 接口（/health、/process_stats、/kraken/data、/train/log、
  /// /train/preflight、/recognition_eval/set）不走这里。
  static Future<http.Response> _post(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
  }) {
    return _guardConnect(uri, () {
      final client = debugHttpClient;
      if (client != null) {
        return client.post(uri, headers: headers, body: body);
      }
      return http.post(uri, headers: headers, body: body);
    });
  }

  static Future<http.Response> _get(Uri uri, {Map<String, String>? headers}) {
    return _guardConnect(uri, () {
      final client = debugHttpClient;
      if (client != null) return client.get(uri, headers: headers);
      return http.get(uri, headers: headers);
    });
  }

  /// 插件桥的后端代理出口（外挂插件页面经宿主调本地后端：缩略图等）。
  /// 只暴露 JSON GET/POST，复用交互请求的统一守卫（连接级失败转中文
  /// 提示并触发自动重启）；非 200 按异常抛出（带响应体摘要）。路径
  /// 变化时由插件 API 版本（manifest api_version）背书，不走
  /// BACKEND_BUILD 握手。
  static Future<Map<String, dynamic>> pluginBackendGet(
    String path,
    Map<String, String>? query,
  ) async {
    final uri = Uri.parse('$_base${path.startsWith('/') ? path : '/$path'}')
        .replace(queryParameters: query);
    final r = await _get(uri).timeout(const Duration(seconds: 60));
    return _decodePluginBackendJson(r, uri);
  }

  static Future<Map<String, dynamic>> pluginBackendPost(
    String path,
    Map<String, dynamic> body,
  ) async {
    final uri = Uri.parse('$_base${path.startsWith('/') ? path : '/$path'}');
    final r = await _post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    ).timeout(const Duration(minutes: 3));
    return _decodePluginBackendJson(r, uri);
  }

  static Map<String, dynamic> _decodePluginBackendJson(
    http.Response r,
    Uri uri,
  ) {
    if (r.statusCode != 200) {
      final detail = r.body.length > 300 ? '${r.body.substring(0, 300)}…' : r.body;
      throw Exception('后端 $uri 失败（HTTP ${r.statusCode}）：$detail');
    }
    final decoded = jsonDecode(r.body);
    if (decoded is! Map) {
      throw Exception('后端 $uri 响应不是 JSON 对象');
    }
    return Map<String, dynamic>.from(decoded);
  }

  /// 识别产出统一打"原始 OCR 文字"基线（正确识别率统计用）：后端识别
  /// 响应解析出的行在这里把每个字的 [CharBlock.origText] 设为当前 text
  /// ——此后人工改字/AI 改写都不再碰它，text != origText 即"识别后被
  /// 修改过"。盘上标注加载不经这里（fromJson 直接读 orig_text）。
  static void _markOcrBaseline(Iterable<LineBlock> lines) {
    for (final line in lines) {
      for (final c in line.chars) {
        if (c.origText.isEmpty) c.origText = c.text;
      }
    }
  }

  static Future<T> _guardConnect<T>(Uri uri, Future<T> Function() call) async {
    try {
      return await call();
    } on http.ClientException catch (e) {
      _addLog('http', '${uri.path} 连接失败（后端不可达）：$e', isError: true);
      _scheduleBackendRevive();
      throw BackendUnavailableException(_backendDownMessage());
    }
  }

  /// 书页图像旋转/镜像（就地改写），返回 {old_w, old_h, new_w, new_h}。
  /// op: rotate_cw | rotate_ccw | flip_h | flip_v；标注几何由调用方按
  /// 同一映射同步变换。
  static Future<Map<String, dynamic>> transformPage({
    required String imagePath,
    required String op,
  }) async {
    _addLog('http', 'POST /transform_page op=$op path=$imagePath');
    final r = await _post(
      Uri.parse('$_base/transform_page'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'image_path': imagePath, 'op': op}),
    ).timeout(const Duration(seconds: 120));
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /transform_page failed status=${r.statusCode} body=${r.body}',
      );
      throw Exception('transform_page failed: ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// 跨页拆分的图像步骤：把一张左右跨页扫描图按中缝切成两页 PNG。
  /// [spineRatio] 为中缝相对页宽的比例（0~1，页面尺寸不一时各页按同一
  /// 比例下刀）；某侧路径传 null 表示不输出该侧。返回切分信息
  /// {w, h, spine_x, left_w, right_w}（标注几何换算用，均为源图像素）。
  static Future<Map<String, dynamic>> splitPage({
    required String imagePath,
    required double spineRatio,
    String? leftPath,
    String? rightPath,
  }) async {
    _addLog('http', 'POST /split_page path=$imagePath ratio=$spineRatio');
    final r = await _post(
      Uri.parse('$_base/split_page'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'image_path': imagePath,
        'spine_ratio': spineRatio,
        if (leftPath != null) 'left_path': leftPath,
        if (rightPath != null) 'right_path': rightPath,
      }),
    ).timeout(const Duration(seconds: 120));
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /split_page failed status=${r.statusCode} body=${r.body}',
        isError: true,
      );
      throw Exception('split_page failed: ${_detailOf(r.body)}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// 智能检测书页四角裁切点（校对摆正的自动分析步骤）。
  /// 返回 {w, h, points: [[x,y]×4] (TL,TR,BR,BL), method, needs_warp}；
  /// method=contour|projection|default 表示检测置信度，needs_warp=false
  /// 表示页面已贴满全图（批量模式可跳过）。
  static Future<Map<String, dynamic>> detectPageQuad({
    required String imagePath,
  }) async {
    _addLog('http', 'POST /detect_page_quad path=$imagePath');
    final r = await _post(
      Uri.parse('$_base/detect_page_quad'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'image_path': imagePath}),
    ).timeout(const Duration(seconds: 120));
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /detect_page_quad failed status=${r.statusCode} body=${r.body}',
        isError: true,
      );
      throw Exception('detect_page_quad failed: ${_detailOf(r.body)}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// 按裁切点把书页拉平摆正（直边单应/弯边 Coons），可叠加去透印、
  /// 去色与锐化。[corners] 为 TL,TR,BR,BL 原图像素坐标；[edgeMids] 键
  /// top/right/bottom/left 为边中点实际坐标（缺省的边视为直边）。
  /// [debleed] 去透印：把背面/下一页透出的浅色文字压成纸白，
  /// [debleedStrength] 1..100 越大压得越狠。preview=true 时
  /// 不写盘，返回 {image_b64, w, h}；否则写入 [outPath]（null=就地改写
  /// image_path），返回 {w, h, out_path}。
  static Future<Map<String, dynamic>> dewarpPage({
    required String imagePath,
    required List<List<double>> corners,
    Map<String, List<double>>? edgeMids,
    bool grayscale = false,
    bool sharpen = false,
    bool debleed = false,
    int debleedStrength = 50,
    bool preview = false,
    int previewMaxPx = 1000,
    String? outPath,
  }) async {
    _addLog(
      'http',
      'POST /dewarp_page path=$imagePath preview=$preview '
          'gray=$grayscale sharpen=$sharpen '
          'debleed=$debleed@$debleedStrength',
    );
    final sw = Stopwatch()..start();
    final heartbeat = Timer.periodic(const Duration(seconds: 15), (_) {
      _addLog('http', 'POST /dewarp_page running ${sw.elapsed} …');
    });
    try {
      final r = await _post(
        Uri.parse('$_base/dewarp_page'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'image_path': imagePath,
          'corners': corners,
          if (edgeMids != null)
            'edge_mids': edgeMids.map((k, v) => MapEntry(k, v)),
          'grayscale': grayscale,
          'sharpen': sharpen,
          'debleed': debleed,
          'debleed_strength': debleedStrength,
          'preview': preview,
          'preview_max_px': previewMaxPx,
          if (outPath != null) 'out_path': outPath,
        }),
      ).timeout(const Duration(seconds: 300));
      if (r.statusCode != 200) {
        _addLog(
          'http',
          'POST /dewarp_page failed status=${r.statusCode} body=${r.body}',
          isError: true,
        );
        throw Exception('dewarp_page failed: ${_detailOf(r.body)}');
      }
      return jsonDecode(r.body) as Map<String, dynamic>;
    } finally {
      heartbeat.cancel();
    }
  }

  /// 批量摆正的并行页数：后端按 CPU 物理核与可用内存决策（环境变量
  /// OCR_DEWARP_WORKERS 可覆盖），reason 为可读决策依据（进应用日志）。
  /// 后端不可达时按本机逻辑核保守回退，保证批量流程不因它中断。
  static Future<Map<String, dynamic>> deskewSizing() async {
    try {
      final r = await _get(
        Uri.parse('$_base/deskew_sizing'),
      ).timeout(const Duration(seconds: 10));
      if (r.statusCode == 200) {
        return jsonDecode(r.body) as Map<String, dynamic>;
      }
      _addLog('http', 'GET /deskew_sizing failed status=${r.statusCode}');
    } catch (e) {
      _addLog('http', 'GET /deskew_sizing failed: $e');
    }
    final cores = Platform.numberOfProcessors;
    return {
      'workers': max(1, min(3, cores ~/ 2)),
      'reason': '后端决策不可用，按本机 $cores 逻辑核保守回退',
    };
  }

  /// 两页智能拼接（/stitch_pages）：裁接缝空白 → 墨迹投影相关对齐错位/
  /// 重复扫描重叠 → 重叠带线性羽化。[direction] 'v'=上下拼（A 上 B 下）
  /// / 'h'=左右拼（A 左 B 右）；[overlap]/[offset] 手动微调（null=自动，
  /// 正错位 = B 沿坐标轴正向平移）。preview=true 返回 {image_b64, trace}；
  /// 否则写 [outPath] 返回 {out_path, trace}。trace 含裁切量/错位/重叠
  /// 的自动判定与置信度（拼接面板展示用）。
  static Future<Map<String, dynamic>> stitchPages({
    required String imageA,
    required String imageB,
    String direction = 'v',
    bool autoTrim = true,
    bool autoAlign = true,
    int? overlap,
    int? offset,
    int seamFade = 24,
    bool preview = false,
    int previewMaxPx = 1400,
    String? outPath,
  }) async {
    _addLog(
      'http',
      'POST /stitch_pages a=$imageA b=$imageB dir=$direction '
          'preview=$preview overlap=${overlap ?? 'auto'} offset=${offset ?? 'auto'}',
    );
    final r = await _post(
      Uri.parse('$_base/stitch_pages'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'image_a': imageA,
        'image_b': imageB,
        'direction': direction,
        'auto_trim': autoTrim,
        'auto_align': autoAlign,
        if (overlap != null) 'overlap': overlap,
        if (offset != null) 'offset': offset,
        'seam_fade': seamFade,
        'preview': preview,
        'preview_max_px': previewMaxPx,
        if (outPath != null) 'out_path': outPath,
      }),
    ).timeout(const Duration(seconds: 120));
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /stitch_pages failed status=${r.statusCode} body=${r.body}',
        isError: true,
      );
      throw Exception('stitch_pages failed: ${_detailOf(r.body)}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// PDF 转页图（任务化）：发起后端后台转换并轮询到完成，返回页图路径
  /// 列表（按页序）。需要逐页进度时用 [pdfToImagesStart] + [pdfToImagesStatus]
  /// 自行轮询。
  static Future<List<String>> pdfToImages(
    String pdfPath,
    String outputDir, {
    bool skipExisting = true,
    void Function(int current, int total)? onProgress,
  }) async {
    final started = await pdfToImagesStart(
      pdfPath,
      outputDir,
      skipExisting: skipExisting,
    );
    final taskId = started['task_id'] as String;
    final total = (started['total'] as num?)?.toInt() ?? 0;
    // 大 PDF 转换可持续数分钟：每 2 秒轮询一次任务状态（与训练页轮询
    // 同节奏），后端每页渲染日志落 service_console.log 可对齐。
    while (true) {
      final status = await pdfToImagesStatus(taskId);
      final state = status['status'] as String? ?? 'running';
      if (onProgress != null) {
        onProgress(
          (status['current'] as num?)?.toInt() ?? 0,
          (status['total'] as num?)?.toInt() ?? total,
        );
      }
      if (state == 'done') {
        return List<String>.from(status['images'] as List);
      }
      if (state == 'failed') {
        throw Exception(status['error']?.toString() ?? 'PDF 转图失败');
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  /// 发起 PDF 转图任务（后端立即返回 {task_id, total}，后台逐页渲染）。
  /// [skipExisting]=true 跳过输出目录已完成的页——应用退出后的断点续跑。
  static Future<Map<String, dynamic>> pdfToImagesStart(
    String pdfPath,
    String outputDir, {
    bool skipExisting = true,
  }) async {
    _addLog(
      'http',
      'POST /pdf_to_images pdf_path=$pdfPath output_dir=$outputDir '
          'skip_existing=$skipExisting',
    );
    final r = await _post(
      Uri.parse('$_base/pdf_to_images'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'pdf_path': pdfPath,
        'output_dir': outputDir,
        'dpi': 200,
        'skip_existing': skipExisting,
      }),
    ).timeout(const Duration(seconds: 60));
    if (r.statusCode != 200) {
      throw Exception('pdf_to_images failed: ${_detailOf(r.body)}');
    }
    if (r.body.trim().isEmpty) {
      throw Exception('pdf_to_images returned an empty response');
    }
    return Map<String, dynamic>.from(jsonDecode(r.body) as Map);
  }

  /// 查询转图任务进度：{status: running|done|failed, current, total,
  /// images, error}。任务不存在（后端重启过）抛异常。
  static Future<Map<String, dynamic>> pdfToImagesStatus(String taskId) async {
    final r = await _get(
      Uri.parse('$_base/pdf_to_images/status?task_id=$taskId'),
    ).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      throw Exception('pdf status failed: ${_detailOf(r.body)}');
    }
    return Map<String, dynamic>.from(jsonDecode(r.body) as Map);
  }

  /// 单字候选分类模型对比评测（/char_cls/evaluate）：以该页已确认的
  /// 单字文字为标准答案，统计候选命中率。[useModels]=false 为基线。
  /// 失败时抛出带原因的异常（例如识别服务是旧版本没有该接口）。
  static Future<Map<String, dynamic>> evaluateCharCls({
    required String projectDir,
    required String imagePath,
    bool useModels = true,
    String? testModelPath,
    int limit = 100,
    List<Map<String, dynamic>>? chars, // 显式参考单字 [{text,x,y,w,h}]
  }) async {
    final r = await _post(
      Uri.parse('$_base/char_cls/evaluate'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'project_dir': projectDir,
        'image_path': imagePath,
        'use_models': useModels,
        'test_model_path': testModelPath,
        'limit': limit,
        if (chars != null) 'chars': chars,
      }),
    ).timeout(const Duration(minutes: 5));
    if (r.statusCode != 200) {
      throw Exception(_detailOf(r.body));
    }
    final decoded = jsonDecode(r.body);
    if (decoded is! Map) {
      throw Exception('评测返回格式异常');
    }
    return Map<String, dynamic>.from(decoded);
  }

  /// 识别消融评测（/recognition_eval）：冻结评测集（人工确认行）上跑
  /// A 裸模型整行读法 / B 像素切分+逐框读法 / C 全链路 三档，量出识别
  /// 准确率里模型与链路代码各自的贡献。[rebuild]=true 时重新抽样评测集。
  static Future<Map<String, dynamic>> recognitionEval({
    required String projectDir,
    int limit = 100,
    bool rebuild = false,
  }) async {
    _addLog(
      'http',
      'POST /recognition_eval project_dir=$projectDir limit=$limit '
          'rebuild=$rebuild',
    );
    // 三档 = 每行 2~3 次模型读法，100 行可达数分钟：心跳照常报等待时长。
    final heartbeatStart = DateTime.now();
    final heartbeat = Timer.periodic(const Duration(seconds: 15), (_) {
      final s = DateTime.now().difference(heartbeatStart).inSeconds;
      _addLog('http', 'POST /recognition_eval 进行中，已等待 ${s}s …');
    });
    final http.Response r;
    try {
      r =
          await _post(
            Uri.parse('$_base/recognition_eval'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'project_dir': projectDir,
              'limit': limit,
              'rebuild': rebuild,
            }),
          ).timeout(
            const Duration(minutes: 20),
            onTimeout: () {
              throw TimeoutException('识别消融评测超时（20 分钟）——可减少评测行数后重试');
            },
          );
    } finally {
      heartbeat.cancel();
    }
    if (r.statusCode == 404) {
      throw Exception(
        '当前识别服务是旧版本（没有识别消融评测接口）。'
        '请完全关闭应用后重新打开，让识别服务更新到最新版本再试。',
      );
    }
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /recognition_eval failed status=${r.statusCode} '
            'body=${r.body}',
        isError: true,
      );
      throw Exception(_detailOf(r.body));
    }
    final decoded = jsonDecode(r.body);
    if (decoded is! Map) {
      throw Exception('识别消融评测返回格式异常');
    }
    _addLog('http', 'POST /recognition_eval ok');
    return Map<String, dynamic>.from(decoded);
  }

  /// 识别消融评测的当前状态（冻结评测集 + 上次运行摘要）；服务不可用或
  /// 是旧版本时返回 null（页面按"还没有评测集"处理）。
  static Future<Map<String, dynamic>?> recognitionEvalSet() async {
    try {
      final r = await http
          .get(Uri.parse('$_base/recognition_eval/set'))
          .timeout(const Duration(seconds: 30));
      if (r.statusCode != 200) return null;
      final decoded = jsonDecode(r.body);
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  /// 朝代基准评测（/bench/dynasty/*）：先秦→明清固定古籍样张 × 当前
  /// 识别管线。识别执行在本端（segmentWithSettings，与整本识别同链路，
  /// 阅读顺序复用 ReadingOrderCalculator）；后端只做对齐评测与历史落盘
  /// （指标口径与消融评测同源，见 python_service/dynasty_bench.py）。
  static Future<List<Map<String, dynamic>>> benchDynastyCases({
    required String benchDir,
  }) async {
    final uri = Uri.parse(
      '$_base/bench/dynasty/cases?bench_dir=${Uri.encodeComponent(benchDir)}',
    );
    final r = await _get(uri).timeout(const Duration(seconds: 30));
    if (r.statusCode == 404) {
      throw Exception('基准目录不可用：$benchDir（需要样张图片 + gt/*.json 基准释文）');
    }
    if (r.statusCode != 200) {
      throw Exception('bench cases failed: ${r.body}');
    }
    final decoded = jsonDecode(r.body);
    final cases = decoded is Map ? decoded['cases'] : null;
    if (cases is! List) throw Exception('基准样张返回格式异常');
    return [for (final c in cases) Map<String, dynamic>.from(c as Map)];
  }

  /// 提交一次朝代基准评测（preds 每项含 id/pred_text/line_count/
  /// duration_ms/error），返回完整运行记录（后端已同时落盘 runs/）。
  static Future<Map<String, dynamic>> benchDynastyEval({
    required String benchDir,
    required List<Map<String, dynamic>> preds,
  }) async {
    final r = await _post(
      Uri.parse('$_base/bench/dynasty/eval'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'bench_dir': benchDir, 'preds': preds}),
    ).timeout(const Duration(seconds: 60));
    if (r.statusCode == 404) {
      throw Exception(
        '当前识别服务是旧版本（没有朝代基准评测接口）。'
        '请完全关闭应用后重新打开，让识别服务更新到最新版本再试。',
      );
    }
    if (r.statusCode != 200) {
      throw Exception(_detailOf(r.body));
    }
    final decoded = jsonDecode(r.body);
    if (decoded is! Map) throw Exception('朝代基准评测返回格式异常');
    return Map<String, dynamic>.from(decoded);
  }

  /// 历史运行摘要（新→旧），供两次运行的对比选择。
  static Future<List<Map<String, dynamic>>> benchDynastyRuns({
    required String benchDir,
    int limit = 50,
  }) async {
    final uri = Uri.parse(
      '$_base/bench/dynasty/runs?bench_dir=${Uri.encodeComponent(benchDir)}'
      '&limit=$limit',
    );
    final r = await _get(uri).timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) return const [];
    final decoded = jsonDecode(r.body);
    final runs = decoded is Map ? decoded['runs'] : null;
    if (runs is! List) return const [];
    return [for (final run in runs) Map<String, dynamic>.from(run as Map)];
  }

  /// Kraken 识别模型微调：导出数据并启动训练（后台任务）。
  static Future<Map<String, dynamic>> krakenTrainStart({
    required String projectDir,
    int epochs = 30,
    int maxLines = 2000,
  }) async {
    final r = await _post(
      Uri.parse('$_base/kraken/train/start'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'project_dir': projectDir,
        'epochs': epochs,
        'max_lines': maxLines,
      }),
    ).timeout(const Duration(seconds: 120));
    if (r.statusCode == 404) {
      throw Exception(
        '当前识别服务是旧版本（没有 Kraken 微调接口）。'
        '请完全关闭应用后重新打开，让识别服务更新到最新版本再试。',
      );
    }
    if (r.statusCode != 200) {
      throw Exception(_detailOf(r.body));
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Kraken 微调的数据就绪状态：确认行数 vs 当前代数需求
  ///（每多一代微调，需求自动 +100 行）。
  static Future<Map<String, dynamic>?> krakenDataStatus(
    String projectDir,
  ) async {
    try {
      final uri = Uri.parse(
        '$_base/kraken/data?project_dir=${Uri.encodeComponent(projectDir)}',
      );
      final r = await http.get(uri).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return null;
      final decoded = jsonDecode(r.body);
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  /// Kraken 微调任务状态列表。
  static Future<List<Map<String, dynamic>>> krakenStatus() async {
    final r = await _get(
      Uri.parse('$_base/kraken/status'),
    ).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      throw Exception('kraken/status failed: ${r.body}');
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    return (data['tasks'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  static Future<void> krakenStop(String taskId) async {
    final r = await _post(
      Uri.parse('$_base/kraken/train/stop'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'task_id': taskId}),
    ).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      throw Exception('kraken/stop failed: ${r.body}');
    }
  }

  /// 查询识别服务进程树的 CPU / 内存 / 显存占用；服务未运行或查询失败
  /// 时返回 null（首页轮询按"暂不可用"展示，不报错打扰）。
  static Future<ServiceStats?> fetchProcessStats() async {
    try {
      final r = await http
          .get(Uri.parse('$_base/process_stats'))
          .timeout(const Duration(seconds: 5));
      if (r.statusCode != 200) return null;
      final decoded = jsonDecode(r.body);
      if (decoded is! Map || decoded['available'] != true) return null;
      return ServiceStats.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }

  /// 重建识别进程池（设置页"识别进程数"立即生效）。[workers] null=清除
  /// 覆盖回硬件自动决策。识别进行中后端 409；重建要逐个加载模型，耗时可
  /// 达数分钟，HTTP 超时放宽到 5 分钟。返回 {size, planned, why}。
  static Future<Map<String, dynamic>> resizeKrakenPool(int? workers) async {
    final r = await http
        .post(
          Uri.parse('$_base/kraken/pool/resize'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'workers': workers}),
        )
        .timeout(const Duration(minutes: 5));
    final decoded = jsonDecode(r.body);
    if (r.statusCode != 200) {
      throw Exception(
        (decoded is Map ? decoded['detail'] : null)?.toString() ??
            '重建进程池失败（HTTP ${r.statusCode}）',
      );
    }
    return Map<String, dynamic>.from(decoded as Map);
  }

  /// 对识别进程池发一次单行识别（进程数压力测试探针）。imagePath 为空时
  /// 后端从书库自选样本。返回 {elapsed_s, pool_size, text_len}。
  static Future<Map<String, dynamic>> krakenProbe({String? imagePath}) async {
    final r = await http
        .post(
          Uri.parse('$_base/kraken/probe'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'image_path': imagePath}),
        )
        .timeout(const Duration(minutes: 3));
    final decoded = jsonDecode(r.body);
    if (r.statusCode != 200) {
      throw Exception(
        (decoded is Map ? decoded['detail'] : null)?.toString() ??
            '识别进程探针失败（HTTP ${r.statusCode}）',
      );
    }
    return Map<String, dynamic>.from(decoded as Map);
  }

  /// PaddleOCR 环境与进程池状态（/paddle/status）。服务未就绪等异常
  /// 返回 installed=false + error 文案，调用方据此引导安装。
  static Future<Map<String, dynamic>> paddleStatus() async {
    final r = await http
        .get(Uri.parse('$_base/paddle/status'))
        .timeout(const Duration(seconds: 20));
    final decoded = jsonDecode(r.body);
    if (r.statusCode != 200) {
      throw Exception(
        (decoded is Map ? decoded['detail'] : null)?.toString() ??
            '获取 PaddleOCR 状态失败（HTTP ${r.statusCode}）',
      );
    }
    return Map<String, dynamic>.from(decoded as Map);
  }

  /// 探测/预下载 PaddleOCR 识别模型（/paddle/probe，即"下载并测试"按钮）：
  /// 建立绑定该模型的进程池并 ping 就绪——首载会从官方源自动下载模型
  /// （small 20.4MB / medium 73.3MB，视网速数分钟），超时放宽到 15 分钟。
  /// 返回 {ok, model, device, elapsed_s, pool_size}。
  static Future<Map<String, dynamic>> paddleProbe(String? model) async {
    final r = await http
        .post(
          Uri.parse('$_base/paddle/probe'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'model': model}),
        )
        .timeout(const Duration(minutes: 15));
    final decoded = jsonDecode(r.body);
    if (r.statusCode != 200) {
      throw Exception(
        (decoded is Map ? decoded['detail'] : null)?.toString() ??
            'PaddleOCR 探测失败（HTTP ${r.statusCode}）',
      );
    }
    return Map<String, dynamic>.from(decoded as Map);
  }

  /// PaddleOCR-VL 视觉语言模型（仅整页直读可用）的判断：超时等差异化
  /// 处理用。
  static bool _isVlModel(ProjectSettings settings) =>
      settings.engine == 'paddle' &&
      settings.paddleModel.startsWith('PaddleOCR-VL');

  /// 刷新整页对照标记（/refresh_full_text_check）：用文本视图整页直读
  /// 落盘的行记录（direct_text 侧车）对已有标注行重算全文对照——纯
  /// CPU（不跑模型、不重识别），返回逐行
  /// {id, full_text, full_extras, diff_indices}。直读完成后编辑器调用，
  /// 让紫色无框字片/橙色不一致标记跟最新直读文本同步。
  static Future<List<Map<String, dynamic>>> refreshFullTextCheck({
    required String imagePath,
    required List<Map<String, dynamic>> lines,
  }) async {
    _addLog('http', 'POST /refresh_full_text_check lines=${lines.length}');
    final r =
        await _post(
          Uri.parse('$_base/refresh_full_text_check'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'image_path': imagePath, 'lines': lines}),
        ).timeout(
          const Duration(seconds: 60),
          onTimeout: () => throw TimeoutException('刷新整页对照超时（1 分钟）'),
        );
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /refresh_full_text_check failed status=${r.statusCode} body=${r.body}',
        isError: true,
      );
      throw Exception('refresh_full_text_check failed: ${r.body}');
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    final raw = data['updates'];
    if (raw is! List) return [];
    return [
      for (final u in raw)
        if (u is Map) Map<String, dynamic>.from(u.cast<String, dynamic>()),
    ];
  }

  /// 整页直读（/read_page_text）：引擎自己分行读字（PaddleOCR det+rec
  /// 全管线 / Kraken blla 分行 + rpred），返回按阅读序拼接的整页文本
  /// ——不走主区/段落/单行/单字标注管线，供「文本」视图快速通读与
  /// AI 校对。返回 {text, lines, engine, ocr, elapsed_s}。
  static Future<Map<String, dynamic>> readPageText({
    required String imagePath,
    required ProjectSettings settings,
  }) async {
    _addLog(
      'http',
      'POST /read_page_text image_path=$imagePath '
          'orientation=${settings.orientation} engine=${settings.engine}',
    );
    final r =
        await _post(
          Uri.parse('$_base/read_page_text'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'image_path': imagePath,
            'orientation': settings.orientation,
            'horizontal_dir': settings.horizontalDir,
            'vertical_dir': settings.verticalDir,
            'engine': settings.engine,
            if (settings.engine == 'paddle')
              'paddle_model': settings.paddleModel,
            // VL 解析配置（官网演示同款开关；后端对非 VL 模型忽略）。
            if (settings.engine == 'paddle' &&
                settings.paddleModel.startsWith('PaddleOCR-VL'))
              'vl_config': settings.vlConfig,
            // VL predict 级参数（Prompt 类型/生成参数/辅助内容；不换池）。
            if (settings.engine == 'paddle' &&
                settings.paddleModel.startsWith('PaddleOCR-VL'))
              'vl_predict': settings.vlPredict,
          }),
        ).timeout(
          // VL 0.9B 首次推理含权重编译、且常与 kraken 池共享显存（被挤时
          // 退 CPU 会到分钟级）——后端单请求超时已放宽到 15 分钟，客户端
          // 必须不短于它，否则先被这里掐断报超时。
          Duration(minutes: _isVlModel(settings) ? 15 : 10),
          onTimeout: () {
            throw TimeoutException(
              '整页直读超时——首次使用会先下载模型，显存紧张时 VL 首读可达'
              '数分钟，请稍后重试',
            );
          },
        );
    // 错误体先于 JSON 解析检查：后端未捕获异常时 uvicorn 返回纯文本
    // "Internal Server Error"（非 JSON）——先 jsonDecode 会抛
    // FormatException 把真实状态/响应体盖掉（实测踩坑）。
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /read_page_text failed status=${r.statusCode} body=${r.body}',
        isError: true,
      );
      final detail = r.body.startsWith('{')
          ? (() {
              try {
                return (jsonDecode(r.body) as Map)['detail']?.toString();
              } catch (_) {
                return null;
              }
            })()
          : null;
      throw Exception(
        detail ??
            (r.body.trim().isEmpty
                ? '整页直读失败（HTTP ${r.statusCode}）'
                : '整页直读失败（HTTP ${r.statusCode}）：${r.body.trim()}'),
      );
    }
    final decoded = jsonDecode(r.body);
    final data = Map<String, dynamic>.from(decoded as Map);
    _addLog(
      'http',
      'POST /read_page_text ok engine=${data['engine']} '
          'lines=${(data['lines'] as List?)?.length ?? 0} '
          'chars=${(data['text'] as String?)?.length ?? 0} '
          'in ${data['elapsed_s']}s',
    );
    return data;
  }

  /// 下载/校验 PaddleOCR 指定识别模型（/paddle/download，设置页逐档下载
  /// 按钮）：一次性临时进程加载该模型（首载自动从官方源下载），完成后
  /// 进程即关，不影响正在使用的进程池。缺档时含下载（视网速数分钟），
  /// 超时放宽到 15 分钟。返回 {ok, model, device, was_cached, elapsed_s}。
  static Future<Map<String, dynamic>> paddleDownload(String? model) async {
    final r = await http
        .post(
          Uri.parse('$_base/paddle/download'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'model': model}),
        )
        .timeout(const Duration(minutes: 15));
    final decoded = jsonDecode(r.body);
    if (r.statusCode != 200) {
      throw Exception(
        (decoded is Map ? decoded['detail'] : null)?.toString() ??
            'PaddleOCR 模型下载失败（HTTP ${r.statusCode}）',
      );
    }
    return Map<String, dynamic>.from(decoded as Map);
  }

  /// 获取某个训练任务的完整日志（/train/log，status 接口只带最后 30 行）；
  /// 不传 taskId 时取最近启动的任务。失败返回 null。
  static Future<Map<String, String>?> fetchTrainingLog({String? taskId}) async {
    try {
      final uri = Uri.parse(
        '$_base/train/log${taskId == null ? '' : '?task_id=$taskId'}',
      );
      final r = await http.get(uri).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return null;
      final decoded = jsonDecode(r.body);
      if (decoded is! Map) return null;
      return {
        'task_id': decoded['task_id']?.toString() ?? '',
        'layer': decoded['layer']?.toString() ?? '',
        'run_dir': decoded['run_dir']?.toString() ?? '',
        'log': decoded['log']?.toString() ?? '',
      };
    } catch (_) {
      return null;
    }
  }

  /// 训练前体检（/train/preflight）：环境 + 各层数据集完整性逐项检查。
  /// 返回 {name, ok, detail} 列表；服务未运行或请求失败返回 null。
  static Future<List<Map<String, dynamic>>?> trainPreflight(
    String projectDir,
  ) async {
    try {
      final uri = Uri.parse(
        '$_base/train/preflight?project_dir=${Uri.encodeComponent(projectDir)}',
      );
      final r = await http.get(uri).timeout(const Duration(seconds: 120));
      if (r.statusCode != 200) return null;
      final decoded = jsonDecode(r.body);
      if (decoded is! Map || decoded['checks'] is! List) return null;
      return (decoded['checks'] as List)
          .map((c) => Map<String, dynamic>.from(c as Map))
          .toList();
    } catch (_) {
      return null;
    }
  }

  static Future<PageAnnotation> segmentWithSettings({
    required String imagePath,
    required String pageId,
    required ProjectSettings settings,
    bool useModels = true, // false = 禁用自训模型走基线管线（模型对比测试）
    String? testLayer, // 模型对比：该层临时套用指定模型
    String? testModelPath,
    Map<String, String>? modelOverrides, // 按项目配置的多层模型覆写
    // 重识别时带入的人工已确认版面区（区域门控输入 + 结果 main_regions
    // 原样带回，确认身份不因重识别丢失）；null/空 = 走后端 region_det
    // 模型预检。
    List<Map<String, dynamic>>? gateRegions,
    // 识别后回传管线元信息（engine/ocr/converter/fallback_reason/yolo
    // 诊断）——只写日志不留数据的调用方用不上，朝代基准等需要把
    // "实际用了哪条管线"存进运行记录的调用方使用。
    void Function(Map<String, dynamic> meta)? onSegmentMeta,
  }) async {
    _addLog(
      'http',
      'POST /segment image_path=$imagePath layout=${settings.layoutMode} '
          'orientation=${settings.orientation} '
          'h_dir=${settings.horizontalDir} v_dir=${settings.verticalDir} '
          'engine=${settings.engine} use_models=$useModels '
          'test_layer=$testLayer test_model_path=$testModelPath '
          'overrides=${modelOverrides ?? const {}}',
    );
    // 等待心跳：识别期间每 15s 向后台日志报一次已等待时长，
    // 避免"转圈但不知道卡在哪"（日志面板可见应用仍在等待响应）。
    final heartbeatStart = DateTime.now();
    final heartbeat = Timer.periodic(const Duration(seconds: 15), (_) {
      final s = DateTime.now().difference(heartbeatStart).inSeconds;
      _addLog('http', 'POST /segment 进行中，已等待 ${s}s …');
    });
    final http.Response r;
    try {
      r =
          await _post(
            Uri.parse('$_base/segment'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'image_path': imagePath,
              'layout_mode': settings.layoutMode,
              'orientation': settings.orientation,
              'horizontal_dir': settings.horizontalDir,
              'vertical_dir': settings.verticalDir,
              'use_models': useModels,
              'test_layer': testLayer,
              'test_model_path': testModelPath,
              // 识别引擎按书选择（project.json 的 settings.engine）；
              // paddle 引擎同时下发模型档位。缺省 kraken 与历史行为一致。
              'engine': settings.engine,
              if (settings.engine == 'paddle')
                'paddle_model': settings.paddleModel,
              if (modelOverrides != null) 'model_overrides': modelOverrides,
              if (gateRegions != null && gateRegions.isNotEmpty)
                'gate_regions': gateRegions,
            }),
          ).timeout(
            const Duration(minutes: 10),
            onTimeout: () {
              throw TimeoutException(
                '整页识别超时（10 分钟）——GPU 被其他程序占用时识别会显著变慢，请稍后重试',
              );
            },
          );
    } on http.ClientException catch (e) {
      // 连接级失败（后端未就绪/被关闭/正在重启）没有 HTTP 状态码，此前
      // 静默上抛——应用日志零痕迹，书卡上只有一句英文 SocketException，
      // 事后无法定位发生在哪个会话。记一条再抛：队列层按「后端不可达」
      // 长等待（RecognitionQueue._recognizePageWithRetry）。
      _addLog('http', 'POST /segment 连接失败（后端未就绪或中断）：$e', isError: true);
      rethrow;
    } finally {
      heartbeat.cancel();
    }
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /segment failed status=${r.statusCode} body=${r.body}',
        isError: true,
      );
      // 后端识别全程持有一把全局锁，另一本书正在批量识别时这里会拿到 409。
      if (r.statusCode == 409) {
        throw RecognitionBusyException(r.body);
      }
      throw Exception('segment failed: ${r.body}');
    }
    if (r.body.trim().isEmpty) {
      throw Exception('segment returned an empty response');
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;

    final debugTrace = data['debug_trace'];
    if (debugTrace is List) {
      for (final item in debugTrace) {
        final message = item.toString();
        _addLog(
          'trace',
          message,
          isError:
              message.contains(' failed') ||
              message.contains('Traceback') ||
              message.contains('unavailable'),
        );
      }
    }

    final engine = data['engine'];
    final ocr = data['ocr'];
    final converter = data['converter'];
    final rawLines = data['lines'] as List?;
    final rawBlocks = data['blocks'] as List;
    final fallbackReason = data['fallback_reason'];
    if (onSegmentMeta != null) {
      onSegmentMeta({
        'engine': engine,
        'ocr': ocr,
        'converter': converter,
        'fallback_reason': fallbackReason,
        if (data['yolo'] is Map)
          'yolo': Map<String, dynamic>.from(data['yolo'] as Map),
      });
    }

    final summary = [
      'engine=$engine',
      'ocr=$ocr',
      'converter=$converter',
      'lines=${rawLines?.length ?? 0}',
      'blocks=${rawBlocks.length}',
      if (fallbackReason != null) 'fallback_reason=$fallbackReason',
    ].join(' ');
    _addLog('http', 'POST /segment ok $summary');

    if (rawLines != null && rawLines.isNotEmpty) {
      final lines = rawLines
          .map((l) => LineBlock.fromJson(l as Map<String, dynamic>))
          .toList();
      _markOcrBaseline(lines);
      final blocks = <CharBlock>[];
      for (final line in lines) {
        for (final c in line.chars) {
          c.lineId = line.id;
          blocks.add(c);
        }
      }
      // 自训段/区模型反哺：后端返回 main_regions / paragraphs 时直接采用
      final rawRegions = (data['main_regions'] as List?)
          ?.whereType<Map>()
          .map((r) => MainRegion.fromJson(Map<String, dynamic>.from(r)))
          .toList();
      final rawParagraphs = (data['paragraphs'] as List?)
          ?.whereType<Map>()
          .map((p) => Paragraph.fromJson(Map<String, dynamic>.from(p)))
          .toList();
      if (rawParagraphs != null && rawParagraphs.isNotEmpty) {
        final byId = {for (final l in lines) l.id: l};
        for (final p in rawParagraphs) {
          for (final id in p.lineIds) {
            byId[id]?.paragraphId = p.id;
          }
        }
      }
      if ((rawRegions != null && rawRegions.isNotEmpty) ||
          (rawParagraphs != null && rawParagraphs.isNotEmpty)) {
        _addLog(
          'http',
          'POST /segment 使用自训模型层级: '
              'regions=${rawRegions?.length ?? 0} paragraphs=${rawParagraphs?.length ?? 0}',
        );
      }
      // 多类互证冲突（运行时诊断，不落盘）：main_text 区与排除类区重叠
      final regionConflicts = (data['region_conflicts'] as List?)
          ?.whereType<Map>()
          .map((c) => Map<String, dynamic>.from(c))
          .toList();
      if (regionConflicts != null && regionConflicts.isNotEmpty) {
        _addLog(
          'http',
          'POST /segment 区域冲突 ${regionConflicts.length} 处'
              '（正文区与页眉/页脚/页码区重叠，建议预标注或人工修正）',
          isError: true,
        );
      }
      return PageAnnotation(
        pageId: pageId,
        imagePath: imagePath,
        schemaVersion: (data['schema_version'] as num?)?.toInt() ?? 1,
        ocrRevision: data['ocr_revision'] as String? ?? '',
        modelVersion: data['model_version'] as String? ?? '',
        sourceSha256: data['source_sha256'] as String? ?? '',
        // 书页图片尺寸随响应带回：层级推断（主区=行外接矩形+2%边距）
        // 依赖它把主区钳回图片范围。
        sourceImageWidth: (data['image_width'] as num?)?.toInt() ?? 0,
        sourceImageHeight: (data['image_height'] as num?)?.toInt() ?? 0,
        mainRegions: rawRegions ?? [],
        paragraphs: rawParagraphs ?? [],
        lines: lines,
        blocks: blocks,
        regionConflicts: regionConflicts ?? const [],
      );
    }

    final blocks = rawBlocks
        .map((b) => CharBlock.fromJson(b as Map<String, dynamic>))
        .toList();
    for (final b in blocks) {
      if (b.origText.isEmpty) b.origText = b.text;
    }
    return PageAnnotation(
      pageId: pageId,
      imagePath: imagePath,
      schemaVersion: (data['schema_version'] as num?)?.toInt() ?? 1,
      ocrRevision: data['ocr_revision'] as String? ?? '',
      modelVersion: data['model_version'] as String? ?? '',
      sourceSha256: data['source_sha256'] as String? ?? '',
      sourceImageWidth: (data['image_width'] as num?)?.toInt() ?? 0,
      sourceImageHeight: (data['image_height'] as num?)?.toInt() ?? 0,
      blocks: blocks,
    );
  }

  /// 单行识别（行框级）。后端检出并排子列（夹注/旁注）结构时会拆成
  /// 多行识别，因此返回行列表（无该结构时列表长度为 1，与旧行为一致）。
  static Future<List<LineBlock>> segmentRegion({
    required String imagePath,
    required LineBlock lineStub,
    required ProjectSettings settings,
    List<Map<String, int>>? charBoxes,
    int? expectedCharCount,

    /// 严格保留传入字框：字框数与整行读法不一致时也不弃用用户框重新
    /// 切分（「重新识别本行」「识别填字」的语义——只重填文字，框几何
    /// 是人工校对成果）。缺省 false 保持全页识别等链路的旧行为。
    bool strictCharBoxes = false,

    /// false 时后端不把行框沿阅读轴外扩到整列墨迹，识别/切分范围即
    /// 传入行框。该行与其它行共享列带（小字注释列被拆成的分段单行）
    /// 时必须传 false：外扩会把两字小注段吞成整列，切出的全部字框叠
    /// 在段图上。缺省 true 保持旧行为（整页识别等链路）。
    bool expand = true,
  }) async {
    _addLog(
      'http',
      'POST /segment_region line=${lineStub.id} '
          'rect=(${lineStub.x},${lineStub.y},${lineStub.w},${lineStub.h})'
          '${charBoxes != null ? ' charBoxes=${charBoxes.length}' : ''}'
          '${strictCharBoxes && charBoxes != null && charBoxes.isNotEmpty ? ' strict' : ''}'
          '${expectedCharCount != null ? ' expectedCharCount=$expectedCharCount' : ''}'
          '${!expand ? ' no-expand' : ''}',
    );
    final r =
        await _post(
          Uri.parse('$_base/segment_region'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'image_path': imagePath,
            'x': lineStub.x,
            'y': lineStub.y,
            'w': lineStub.w,
            'h': lineStub.h,
            'line_id': lineStub.id,
            'line_no': lineStub.lineNo,
            'orientation': settings.orientation,
            'horizontal_dir': settings.horizontalDir,
            'vertical_dir': settings.verticalDir,
            'engine': settings.engine,
            if (settings.engine == 'paddle')
              'paddle_model': settings.paddleModel,
            // 行的版面类型（det 定行的页眉/页脚/页码标签）：重识别回包
            // 沿用——行类型是页级识别成果，重识别只换文字不该丢。
            if (lineStub.regionLabel.isNotEmpty)
              'region_label': lineStub.regionLabel,
            if (charBoxes != null && charBoxes.isNotEmpty) ...{
              'char_boxes': [
                for (final b in charBoxes)
                  {'x': b['x'], 'y': b['y'], 'w': b['w'], 'h': b['h']},
              ],
              if (strictCharBoxes) 'strict_char_boxes': true,
            },
            if (charBoxes == null || charBoxes.isEmpty)
              if (expectedCharCount != null && expectedCharCount > 0)
                'expected_char_count': expectedCharCount,
            // 仅在关闭时下发：老服务未知字段虽被忽略，显式下发 false
            // 才能与新服务的缺省 true 区分开。
            if (!expand) 'expand': false,
          }),
        ).timeout(
          const Duration(minutes: 5),
          onTimeout: () {
            throw TimeoutException('单行识别超时（5 分钟）——GPU 被其他程序占用时识别会显著变慢，请稍后重试');
          },
        );
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /segment_region failed status=${r.statusCode} body=${r.body}',
        isError: true,
      );
      throw Exception('segment_region failed: ${r.body}');
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    final debugTrace = data['debug_trace'];
    if (debugTrace is List) {
      for (final item in debugTrace) {
        final message = item.toString();
        _addLog(
          'trace',
          message,
          isError:
              message.contains(' failed') ||
              message.contains('Traceback') ||
              message.contains('unavailable'),
        );
      }
    }
    // 新响应带 lines 列表；旧服务只回 line 单对象，两者都兼容。
    final lines = <LineBlock>[];
    final rawLines = data['lines'];
    if (rawLines is List) {
      for (final item in rawLines) {
        if (item is Map) {
          lines.add(LineBlock.fromJson(item.cast<String, dynamic>()));
        }
      }
    }
    if (lines.isEmpty) {
      final lineJson = data['line'];
      if (lineJson is Map) {
        lines.add(LineBlock.fromJson(lineJson.cast<String, dynamic>()));
      }
    }
    if (lines.isEmpty) {
      throw Exception('segment_region returned no lines');
    }
    _markOcrBaseline(lines);
    _addLog(
      'http',
      'POST /segment_region ok lines=${lines.length} '
          'chars=${lines.fold<int>(0, (n, l) => n + l.chars.length)}',
    );
    return lines;
  }

  /// CPU-only layout diagnostics. The endpoint never mutates source images or
  /// annotations; callers decide whether to apply returned proposals.
  static Future<LayoutAnalysis> analyzeLayout({
    required String imagePath,
    required ProjectSettings settings,
    required List<LineBlock> lines,
  }) async {
    _addLog('http', 'POST /analyze_layout lines=${lines.length}');
    final r = await _post(
      Uri.parse('$_base/analyze_layout'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'image_path': imagePath,
        'orientation': settings.orientation,
        'horizontal_dir': settings.horizontalDir,
        'vertical_dir': settings.verticalDir,
        'lines': [
          for (final l in lines)
            {
              'id': l.id,
              'x': l.x,
              'y': l.y,
              'w': l.w,
              'h': l.h,
              'chars': [
                for (final c in l.chars)
                  {
                    'id': c.id,
                    'x': c.x,
                    'y': c.y,
                    'w': c.w,
                    'h': c.h,
                    'text': c.text,
                    'type': c.type,
                    'col': c.col,
                    'order': c.order,
                  },
              ],
            },
        ],
      }),
    ).timeout(const Duration(minutes: 2));
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /analyze_layout failed status=${r.statusCode} body=${r.body}',
        isError: true,
      );
      throw Exception('analyze_layout failed: ${_detailOf(r.body)}');
    }
    final decoded = jsonDecode(r.body);
    if (decoded is! Map) {
      throw Exception('analyze_layout returned invalid JSON');
    }
    return LayoutAnalysis.fromJson(Map<String, dynamic>.from(decoded));
  }

  /// 规则 + 跨页一致性版面区预标注（/region_prelabel，后端只读）：返回
  /// header/footer/page_number/margin_note 的 proposed 候选区，由调用方
  /// 落进标注并人工确认（永不自动确认、不覆盖已有区域）。
  static Future<RegionPrelabelResult> regionPrelabel({
    required String projectDir,
    required String pageId,
  }) async {
    _addLog('http', 'POST /region_prelabel page=$pageId');
    final r = await _post(
      Uri.parse('$_base/region_prelabel'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'project_dir': projectDir, 'page_id': pageId}),
    ).timeout(const Duration(minutes: 2));
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /region_prelabel failed status=${r.statusCode} body=${r.body}',
        isError: true,
      );
      throw Exception('region_prelabel failed: ${_detailOf(r.body)}');
    }
    final decoded = jsonDecode(r.body);
    if (decoded is! Map) {
      throw Exception('region_prelabel returned invalid JSON');
    }
    final result = RegionPrelabelResult.fromJson(
      Map<String, dynamic>.from(decoded),
    );
    _addLog(
      'http',
      'POST /region_prelabel ok suggestions=${result.suggestions.length}',
    );
    return result;
  }

  /// 粗框几何精修（/region_refine）：钳图内、词表校验、墨迹收紧、近重复
  /// 去除——VLM/规则粗框的坐标安全层（语义归模型，像素归几何）。
  static Future<RegionRefineResult> regionRefine({
    required String imagePath,
    required List<RegionPrelabelSuggestion> regions,
  }) async {
    _addLog('http', 'POST /region_refine regions=${regions.length}');
    final r = await _post(
      Uri.parse('$_base/region_refine'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'image_path': imagePath,
        'regions': [for (final s in regions) s.toRequest()],
      }),
    ).timeout(const Duration(minutes: 2));
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /region_refine failed status=${r.statusCode} body=${r.body}',
        isError: true,
      );
      throw Exception('region_refine failed: ${_detailOf(r.body)}');
    }
    final decoded = jsonDecode(r.body);
    if (decoded is! Map) {
      throw Exception('region_refine returned invalid JSON');
    }
    return RegionRefineResult.fromJson(Map<String, dynamic>.from(decoded));
  }

  /// /page_prelabel_image 的素材图与几何元数据。坐标换算口径：素材图
  /// 坐标 ÷ [scale] = 原图像素（scale 与后端一致，只缩不放时为 1.0）。
  /// 跨语言字段基准声明在 python_service/region_prelabel.py 的
  /// prelabel_page_image 返回值，两处只追加不改名。
  static Future<PagePrelabelMaterial> pagePrelabelImage({
    required String imagePath,
    int maxSide = 1536,
    List<Map<String, dynamic>> regions = const [],
    int gridDiv = 8,
  }) async {
    _addLog('http', 'POST /page_prelabel_image maxSide=$maxSide');
    final r = await _post(
      Uri.parse('$_base/page_prelabel_image'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'image_path': imagePath,
        'max_side': maxSide,
        'regions': regions,
        'grid_div': gridDiv,
      }),
    ).timeout(const Duration(minutes: 2));
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /page_prelabel_image failed status=${r.statusCode} body=${r.body}',
        isError: true,
      );
      throw Exception('page_prelabel_image failed: ${_detailOf(r.body)}');
    }
    final decoded = jsonDecode(r.body);
    if (decoded is! Map || decoded['image_base64'] is! String) {
      throw Exception('page_prelabel_image returned invalid JSON');
    }
    return PagePrelabelMaterial.fromJson(Map<String, dynamic>.from(decoded));
  }

  /// 对主区/段矩形重跑分行 + 拆字 + OCR，返回坐标为全图绝对坐标的行列表。
  /// [gateRegions]：本页人工已确认版面区（与 /segment 同款区域门控输入，
  /// 保持两条链路同一识别批次的一致性）。
  static Future<List<LineBlock>> segmentLinesInRegion({
    required String imagePath,
    required int x,
    required int y,
    required int w,
    required int h,
    required ProjectSettings settings,
    List<Map<String, dynamic>>? gateRegions,
  }) async {
    _addLog(
      'http',
      'POST /segment_lines_in_region rect=($x,$y,$w,$h) '
          'orientation=${settings.orientation}',
    );
    final r =
        await _post(
          Uri.parse('$_base/segment_lines_in_region'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'image_path': imagePath,
            'x': x,
            'y': y,
            'w': w,
            'h': h,
            'layout_mode': settings.layoutMode,
            'orientation': settings.orientation,
            'horizontal_dir': settings.horizontalDir,
            'vertical_dir': settings.verticalDir,
            'engine': settings.engine,
            if (settings.engine == 'paddle')
              'paddle_model': settings.paddleModel,
            if (gateRegions != null && gateRegions.isNotEmpty)
              'gate_regions': gateRegions,
          }),
        ).timeout(
          const Duration(minutes: 10),
          onTimeout: () {
            throw TimeoutException('区域识别超时（10 分钟）——GPU 被其他程序占用时识别会显著变慢，请稍后重试');
          },
        );
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /segment_lines_in_region failed status=${r.statusCode} body=${r.body}',
        isError: true,
      );
      throw Exception('segment_lines_in_region failed: ${r.body}');
    }
    if (r.body.trim().isEmpty) {
      throw Exception('segment_lines_in_region returned an empty response');
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    final debugTrace = data['debug_trace'];
    if (debugTrace is List) {
      for (final item in debugTrace) {
        final message = item.toString();
        _addLog(
          'trace',
          message,
          isError:
              message.contains(' failed') ||
              message.contains('Traceback') ||
              message.contains('unavailable'),
        );
      }
    }
    final rawLines = (data['lines'] as List?) ?? const [];
    final lines = <LineBlock>[];
    for (final item in rawLines) {
      final line = LineBlock.fromJson(item as Map<String, dynamic>);
      for (final c in line.chars) {
        c.lineId = line.id;
      }
      lines.add(line);
    }
    _markOcrBaseline(lines);
    _addLog(
      'http',
      'POST /segment_lines_in_region ok engine=${data['engine']} '
          'lines=${lines.length} chars=${lines.fold<int>(0, (n, l) => n + l.chars.length)}',
    );
    return lines;
  }

  /// 整页表格候选检测（+83）：格线网格结构（rows≥2 且 cols≥2，界行/
  /// 版框已挡），供预标注落 table 类 proposed 候选区。
  static Future<List<Map<String, dynamic>>> detectTables({
    required String imagePath,
  }) async {
    _addLog('http', 'POST /detect_tables');
    final r = await _post(
      Uri.parse('$_base/detect_tables'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'image_path': imagePath}),
    ).timeout(const Duration(seconds: 120));
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /detect_tables failed ${r.statusCode} ${r.body}',
        isError: true,
      );
      throw Exception('detect_tables failed: ${_detailOf(r.body)}');
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    final tables = ((data['tables'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .toList();
    _addLog('http', 'POST /detect_tables ok tables=${tables.length}');
    return tables;
  }

  /// 表格识别（+83）：手动标记区域 → 格线网格 + 每格文字（格内方向
  /// 自动判定，横竖版同一路径）。422 = 区域内格线不足（reason 在
  /// detail 里），调用方提示用户调整框。
  static Future<TableAnnotation> recognizeTable({
    required String imagePath,
    required int x,
    required int y,
    required int w,
    required int h,
    required ProjectSettings settings,
    String id = 'tbl_000',
    String regionUid = '',
  }) async {
    _addLog(
      'http',
      'POST /recognize_table rect=($x,$y,$w,$h) '
          'orientation=${settings.orientation}',
    );
    final r =
        await _post(
          Uri.parse('$_base/recognize_table'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'image_path': imagePath,
            'x': x,
            'y': y,
            'w': w,
            'h': h,
            'orientation': settings.orientation,
            'horizontal_dir': settings.horizontalDir,
            'vertical_dir': settings.verticalDir,
          }),
        ).timeout(
          const Duration(minutes: 10),
          onTimeout: () => throw TimeoutException('表格识别超时（10 分钟）'),
        );
    if (r.statusCode == 422) {
      throw TableGridNotFoundException(_detailOf(r.body));
    }
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /recognize_table failed ${r.statusCode} ${r.body}',
        isError: true,
      );
      throw Exception('recognize_table failed: ${_detailOf(r.body)}');
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    final table = TableAnnotation.fromRecognition(
      data,
      id: id,
      regionUid: regionUid,
    );
    _addLog(
      'http',
      'POST /recognize_table ok ${table.rows}x${table.cols} '
          'cells=${table.cells.length} ocr=${data['ocr']}',
    );
    return table;
  }

  /// 区域（w/h 为 0 = 整页）→ Excalidraw 场景：区域内图形检测 + 文字，
  /// 返回 {scene, stats, debug_trace}。scene 为标准 .excalidraw JSON，
  /// 存盘后 Obsidian Excalidraw 插件与 excalidraw.com 均可直接打开编辑。
  ///
  /// ocrLines：编辑器当前校对数据（null = 后端区域重识别；空列表 =
  /// 纯图形导出，不含任何文字）。注入时后端不占 GPU 门，工作台调参
  /// 重生成即时。textBoxes：手画文字识别框（全图坐标，框内无既有字时
  /// 后端按框单独识别）。debugImages：附带管线过程图（stats 里）。
  static Future<Map<String, dynamic>> exportExcalidraw({
    required String imagePath,
    required int x,
    required int y,
    required int w,
    required int h,
    required ProjectSettings settings,
    ExcalidrawExportOptions? options,
    List<Map<String, dynamic>>? ocrLines,
    List<Map<String, dynamic>>? textBoxes,
    bool debugImages = false,
  }) async {
    final opts = options ?? ExcalidrawExportOptions();
    final timeout = ocrLines == null
        ? const Duration(minutes: 10)
        : const Duration(seconds: 60);
    _addLog(
      'http',
      'POST /export_excalidraw rect=($x,$y,$w,$h) '
          'orientation=${settings.orientation} '
          'text=${opts.textSource} roughness=${opts.roughness}'
          '${textBoxes != null && textBoxes.isNotEmpty ? ' 文字框×${textBoxes.length}' : ''}',
    );
    final r =
        await _post(
          Uri.parse('$_base/export_excalidraw'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'image_path': imagePath,
            'x': x,
            'y': y,
            'w': w,
            'h': h,
            'orientation': settings.orientation,
            'horizontal_dir': settings.horizontalDir,
            'vertical_dir': settings.verticalDir,
            'layout_mode': settings.layoutMode,
            ...opts.toJson(),
            if (ocrLines != null) 'ocr_lines': ocrLines,
            if (textBoxes != null && textBoxes.isNotEmpty)
              'text_boxes': textBoxes,
            'debug_images': debugImages,
          }),
        ).timeout(
          timeout,
          onTimeout: () {
            throw TimeoutException(
              ocrLines == null
                  ? 'Excalidraw 导出超时（10 分钟）——识别链路较重，GPU 繁忙时请稍后重试'
                  : 'Excalidraw 导出超时（区域较大或图像读取慢），请重试',
            );
          },
        );
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /export_excalidraw failed status=${r.statusCode} body=${r.body}',
        isError: true,
      );
      throw Exception('export_excalidraw failed: ${r.body}');
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    final debugTrace = data['debug_trace'];
    if (debugTrace is List) {
      for (final item in debugTrace) {
        _addLog('trace', item.toString());
      }
    }
    _addLog('http', 'POST /export_excalidraw ok stats=${data['stats']}');
    return data;
  }

  /// 切字过程可视化（诊断）：对给定行框生成二值化墨迹图与切分过程图
  /// （连通域块/丢弃墨点/最终字框），返回 {mask_image, lines:[...]}。
  static Future<Map<String, dynamic>> debugCharSplit({
    required String imagePath,
    List<Map<String, dynamic>> lines = const [],
    String orientation = 'vertical',
  }) async {
    _addLog(
      'http',
      'POST /debug_char_split lines=${lines.length} '
          '(rect=${lines.isNotEmpty ? '(${lines.first['x']},${lines.first['y']},${lines.first['w']},${lines.first['h']})' : 'auto'})',
    );
    final r = await _post(
      Uri.parse('$_base/debug_char_split'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'image_path': imagePath,
        'orientation': orientation,
        'lines': lines
            .map(
              (l) => {
                'x': l['x'],
                'y': l['y'],
                'w': l['w'],
                'h': l['h'],
                'expected_count': l['expected_count'] ?? 0,
              },
            )
            .toList(),
      }),
    ).timeout(const Duration(seconds: 120));
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /debug_char_split failed status=${r.statusCode} body=${r.body}',
        isError: true,
      );
      throw Exception('debug_char_split failed: ${r.body}');
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    _addLog(
      'http',
      'POST /debug_char_split ok lines=${(data['lines'] as List?)?.length ?? 0}',
    );
    return data;
  }

  static Future<List<Map<String, dynamic>>> getCharCandidates({
    required String imagePath,
    required int x,
    required int y,
    required int w,
    required int h,
    int topK = 10,
  }) async {
    _addLog('http', 'POST /char_candidates rect=($x,$y,$w,$h) top_k=$topK');
    final r = await _post(
      Uri.parse('$_base/char_candidates'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'image_path': imagePath,
        'x': x,
        'y': y,
        'w': w,
        'h': h,
        'top_k': topK.clamp(1, 10),
      }),
    );
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /char_candidates failed status=${r.statusCode} body=${r.body}',
        isError: true,
      );
      throw Exception('char_candidates failed: ${r.body}');
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    final debugTrace = data['debug_trace'];
    if (debugTrace is List) {
      for (final item in debugTrace) {
        final message = item.toString();
        _addLog(
          'trace',
          message,
          isError:
              message.contains(' failed') ||
              message.contains('Traceback') ||
              message.contains('unavailable'),
        );
      }
    }
    final candidates = (data['candidates'] as List)
        .cast<Map<String, dynamic>>();
    _addLog('http', 'POST /char_candidates ok k=${candidates.length}');
    return candidates;
  }

  /// 单字框识别（画新框/调整框后调用）：所选引擎（kraken 默认 / paddle
  /// 可选）框内识别出正文，自训 char_cls 分类器补充候选，返回
  /// {text, conf, candidates}。
  static Future<Map<String, dynamic>> recognizeChar({
    required String imagePath,
    required int x,
    required int y,
    required int w,
    required int h,
    String orientation = 'vertical',
    String horizontalDir = 'ltr',
    int topK = 10,
    String engine = 'kraken',
    String? paddleModel,
  }) async {
    _addLog('http', 'POST /recognize_char rect=($x,$y,$w,$h)');
    final r = await _post(
      Uri.parse('$_base/recognize_char'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'image_path': imagePath,
        'x': x,
        'y': y,
        'w': w,
        'h': h,
        'orientation': orientation,
        'horizontal_dir': horizontalDir,
        'top_k': topK.clamp(1, 10),
        'engine': engine,
        if (engine == 'paddle') 'paddle_model': paddleModel,
      }),
    ).timeout(const Duration(seconds: 120));
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /recognize_char failed status=${r.statusCode} body=${r.body}',
        isError: true,
      );
      throw Exception('recognize_char failed: ${r.body}');
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    _addLog(
      'http',
      'POST /recognize_char ok text=${data['text']} '
          'candidates=${(data['candidates'] as List?)?.length ?? 0}',
    );
    return data;
  }

  static Future<Map<String, List<Map<String, dynamic>>>>
  getCharCandidatesBatch({
    required String imagePath,
    required List<CharBlock> blocks,
    int topK = 10,
  }) async {
    final r = await _post(
      Uri.parse('$_base/char_candidates_batch'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'image_path': imagePath,
        'blocks': blocks.map((b) => b.toJson()).toList(),
        'top_k': topK.clamp(1, 10),
      }),
    );
    if (r.statusCode != 200) {
      throw Exception('char_candidates_batch failed: ${r.body}');
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    final raw = data['candidates'] as Map? ?? const {};
    return raw.map(
      (key, value) => MapEntry(
        key.toString(),
        (value as List?)
                ?.whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList() ??
            <Map<String, dynamic>>[],
      ),
    );
  }

  /// 单字墨迹聚类（编辑器「墨迹归类」页）：按笔画形态把本页字块分组，
  /// 分组与识别文字无关。返回按组大小降序的组列表。
  static Future<CharClusterResult> clusterChars({
    required String imagePath,
    required List<CharBlock> blocks,
    double threshold = 0.15,
  }) async {
    _addLog(
      'http',
      'POST /char_clusters blocks=${blocks.length} threshold=$threshold',
    );
    final r =
        await _post(
          Uri.parse('$_base/char_clusters'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'image_path': imagePath,
            'blocks': blocks.map((b) => b.toJson()).toList(),
            'threshold': threshold,
          }),
        ).timeout(
          const Duration(seconds: 60),
          onTimeout: () {
            throw TimeoutException('墨迹归类超时，请稍后重试');
          },
        );
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /char_clusters failed status=${r.statusCode} body=${r.body}',
        isError: true,
      );
      throw Exception('char_clusters failed: ${r.body}');
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    final clusters = ((data['clusters'] as List?) ?? const [])
        .whereType<Map>()
        .map(
          (e) => CharClusterGroup(
            blockIds: ((e['block_ids'] as List?) ?? const [])
                .map((id) => id.toString())
                .toList(),
            cohesion: (e['cohesion'] as num?)?.toDouble() ?? 0,
          ),
        )
        .toList();
    final singletons = ((data['singletons'] as List?) ?? const [])
        .map((id) => id.toString())
        .toList();
    final skipped = ((data['skipped'] as List?) ?? const [])
        .map((id) => id.toString())
        .toList();
    final elapsed = (data['elapsed_ms'] as num?)?.toDouble() ?? 0;
    _addLog(
      'http',
      'POST /char_clusters ok clusters=${clusters.length} '
          'singletons=${singletons.length} elapsed=${elapsed.toStringAsFixed(0)}ms',
    );
    return CharClusterResult(
      clusters: clusters,
      singletons: singletons,
      skipped: skipped,
      elapsedMs: elapsed,
    );
  }

  /// 全书墨迹聚类（「墨迹归类·全书版」页）：多页字块按墨迹形态聚成
  /// 跨页分组。块 id 必须全局唯一——调用方负责加页前缀（"页号|块id"），
  /// 返回的组 id 同样带前缀，由调用方拆回。大书同步执行耗时可达分钟
  /// 级，超时给到 15 分钟；某页失败由后端跳过并在 failedPages 里报告。
  static Future<CharClusterResult> clusterCharsBatch({
    required List<CharClusterBatchPage> pages,
    double threshold = 0.15,
  }) async {
    _addLog(
      'http',
      'POST /char_clusters_batch pages=${pages.length} '
          'chars=${pages.fold<int>(0, (s, p) => s + p.blocks.length)} '
          'threshold=$threshold',
    );
    final r =
        await _post(
          Uri.parse('$_base/char_clusters_batch'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            // 只送几何必需字段：全书可达十几万字块，候选/文字等大字段裁掉。
            'pages': pages
                .map(
                  (p) => {
                    'image_path': p.imagePath,
                    'blocks': p.blocks
                        .map(
                          (b) => {
                            'id': b.id,
                            'x': b.x,
                            'y': b.y,
                            'w': b.w,
                            'h': b.h,
                            'col': b.col,
                            'order': b.order,
                            'type': b.type,
                            'confirmed': b.confirmed,
                          },
                        )
                        .toList(),
                  },
                )
                .toList(),
            'threshold': threshold,
          }),
        ).timeout(
          const Duration(minutes: 15),
          onTimeout: () {
            throw TimeoutException('全书墨迹归类超时（页数过多时可缩小范围分批进行）');
          },
        );
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /char_clusters_batch failed status=${r.statusCode} '
            'body=${r.body}',
        isError: true,
      );
      throw Exception('char_clusters_batch failed: ${r.body}');
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    final clusters = ((data['clusters'] as List?) ?? const [])
        .whereType<Map>()
        .map(
          (e) => CharClusterGroup(
            blockIds: ((e['block_ids'] as List?) ?? const [])
                .map((id) => id.toString())
                .toList(),
            cohesion: (e['cohesion'] as num?)?.toDouble() ?? 0,
          ),
        )
        .toList();
    final singletons = ((data['singletons'] as List?) ?? const [])
        .map((id) => id.toString())
        .toList();
    final skipped = ((data['skipped'] as List?) ?? const [])
        .map((id) => id.toString())
        .toList();
    final failedPages = ((data['failed_pages'] as List?) ?? const [])
        .whereType<Map>()
        .map(
          (e) => MapEntry(
            e['image_path']?.toString() ?? '',
            e['error']?.toString() ?? '',
          ),
        )
        .toList();
    final elapsed = (data['elapsed_ms'] as num?)?.toDouble() ?? 0;
    _addLog(
      'http',
      'POST /char_clusters_batch ok clusters=${clusters.length} '
          'singletons=${singletons.length} failed=${failedPages.length} '
          'elapsed=${elapsed.toStringAsFixed(0)}ms',
    );
    return CharClusterResult(
      clusters: clusters,
      singletons: singletons,
      skipped: skipped,
      elapsedMs: elapsed,
      failedPages: failedPages,
    );
  }

  /// 批量字块缩略图（全书墨迹归类页）：按字框裁切 + 白底 letterbox
  /// 正方形缩放。返回与 [items] 顺序对齐的 base64 PNG 列表，裁切失败
  /// 的项为 null（调用方显示占位）。
  static Future<List<String?>> fetchCharThumbnails({
    required List<({String imagePath, int x, int y, int w, int h})> items,
    int size = 96,
  }) async {
    if (items.isEmpty) return const [];
    _addLog('http', 'POST /char_thumbnails items=${items.length} size=$size');
    final r =
        await _post(
          Uri.parse('$_base/char_thumbnails'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'items': items
                .map(
                  (e) => {
                    'image_path': e.imagePath,
                    'x': e.x,
                    'y': e.y,
                    'w': e.w,
                    'h': e.h,
                  },
                )
                .toList(),
            'size': size,
          }),
        ).timeout(
          const Duration(minutes: 3),
          onTimeout: () {
            throw TimeoutException('字块缩略图获取超时');
          },
        );
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /char_thumbnails failed status=${r.statusCode} body=${r.body}',
        isError: true,
      );
      throw Exception('char_thumbnails failed: ${r.body}');
    }
    // 响应是 40 张 224px PNG 的 base64（MB 级）：解码搬后台 isolate。
    final data = await decodeJsonInIsolate(r.body) as Map<String, dynamic>;
    return ((data['thumbs'] as List?) ?? const [])
        .map((e) => e?.toString())
        .toList();
  }

  /// 批量行条裁图（AI 框检查的诊断素材）：按行框裁切 + 上下文外扩 +
  /// 保持纵横比 + 长边缩放，可选叠加当前字框（橙框+序号）。返回与
  /// [items] 顺序对齐的 base64 PNG 列表，裁切失败的项为 null。
  static Future<List<String?>> fetchLineThumbnails({
    required List<LineThumbRequest> items,
    int maxSide = 640,
  }) async {
    if (items.isEmpty) return const [];
    _addLog(
      'http',
      'POST /line_thumbnails items=${items.length} maxSide=$maxSide',
    );
    final r =
        await _post(
          Uri.parse('$_base/line_thumbnails'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'items': [
              for (final e in items)
                {
                  'image_path': e.imagePath,
                  'x': e.x,
                  'y': e.y,
                  'w': e.w,
                  'h': e.h,
                  'orientation': e.orientation,
                  if (e.boxes != null)
                    'boxes': [
                      for (final b in e.boxes!)
                        {'x': b.$1, 'y': b.$2, 'w': b.$3, 'h': b.$4},
                    ],
                },
            ],
            'max_side': maxSide,
          }),
        ).timeout(
          const Duration(minutes: 3),
          onTimeout: () {
            throw TimeoutException('行条裁图获取超时');
          },
        );
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /line_thumbnails failed status=${r.statusCode} body=${r.body}',
        isError: true,
      );
      throw Exception('line_thumbnails failed: ${r.body}');
    }
    // 响应含 1536px 行图 base64（MB 级）：解码搬后台 isolate。
    final data = await decodeJsonInIsolate(r.body) as Map<String, dynamic>;
    return ((data['thumbs'] as List?) ?? const [])
        .map((e) => e?.toString())
        .toList();
  }

  /// 批量行墨迹测量（AI 框检查的判空依据）：逐字框核心区的结构性墨迹
  /// 占比中位数 + 空字数。与 [items] 顺序对齐；测量失败的项为 null。
  /// chars 为空的行按行框整体测（charCount=1）。
  static Future<List<LineInkResult?>> measureLineInk({
    required List<LineThumbRequest> items,
  }) async {
    if (items.isEmpty) return const [];
    _addLog('http', 'POST /line_ink items=${items.length}');
    final r =
        await _post(
          Uri.parse('$_base/line_ink'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'items': [
              for (final e in items)
                {
                  'image_path': e.imagePath,
                  'x': e.x,
                  'y': e.y,
                  'w': e.w,
                  'h': e.h,
                  'chars': [
                    for (final b in (e.boxes ?? const <(int, int, int, int)>[]))
                      {'x': b.$1, 'y': b.$2, 'w': b.$3, 'h': b.$4},
                  ],
                },
            ],
          }),
        ).timeout(
          const Duration(minutes: 2),
          onTimeout: () {
            throw TimeoutException('行墨迹测量超时');
          },
        );
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /line_ink failed status=${r.statusCode} body=${r.body}',
        isError: true,
      );
      throw Exception('line_ink failed: ${r.body}');
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    final raw = (data['results'] as List?) ?? const [];
    return [
      for (var i = 0; i < items.length; i++)
        if (i < raw.length && raw[i] is Map<String, dynamic>)
          LineInkResult.fromJson(raw[i] as Map<String, dynamic>)
        else
          null,
    ];
  }

  /// 页面矩形批量墨迹检测（主区快设「按参考页适配」的判空依据）：
  /// [rects] 为参考页映射到该页的非正文类框（页眉/页脚/页码…），逐框
  /// 返回核心区结构性墨迹占比；**null = 检测失败（坏图/后端不可达），
  /// 调用方保守保留框**。低于 [regionInkEmptyThreshold] 的框视为该页
  /// 没有这个页眉/页脚，不落框。
  static const double regionInkEmptyThreshold = 0.02;

  static Future<List<double?>> measureRegionInk(
    String imagePath,
    List<Rect> rects,
  ) async {
    if (rects.isEmpty) return const [];
    _addLog('http', 'POST /region_ink rects=${rects.length}');
    final r =
        await _post(
          Uri.parse('$_base/region_ink'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'image_path': imagePath,
            'rects': [
              for (final rect in rects)
                {
                  'x': rect.left.round(),
                  'y': rect.top.round(),
                  'w': rect.width.round(),
                  'h': rect.height.round(),
                },
            ],
          }),
        ).timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            throw TimeoutException('版面区墨迹检测超时');
          },
        );
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /region_ink failed status=${r.statusCode} body=${r.body}',
        isError: true,
      );
      throw Exception('region_ink failed: ${r.body}');
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    final raw = (data['results'] as List?) ?? const [];
    return [
      for (var i = 0; i < rects.length; i++)
        if (i < raw.length &&
            raw[i] is Map<String, dynamic> &&
            (raw[i] as Map<String, dynamic>)['ok'] == true)
          ((raw[i] as Map<String, dynamic>)['ink'] as num?)?.toDouble() ?? 0.0
        else
          null,
    ];
  }

  /// 当前文字在识别候选里的 1 基排名（墨迹校验的 char_cls 融合信号）：
  /// 候选为空返回 null（无信号）；不在候选里返回 0。
  static int? _clsRankOf(CharBlock block) {
    final cands = block.candidates;
    if (cands.isEmpty) return null;
    final text = block.text.trim();
    if (text.runes.length != 1) return null;
    for (var i = 0; i < cands.length; i++) {
      if (cands[i].text == text) return i + 1;
    }
    return 0;
  }

  /// 单字墨迹校验：识别文字的楷体字形骨架与墨迹骨架做拓扑+形状重叠
  /// 比对。level ∈ {ok, suspect, mismatch, skipped}；mismatch 供编辑器
  /// 标红并转待复核。debug=true 时 raw 里带叠加图 base64。
  static Future<CharVerifyOutcome> verifyChar({
    required String imagePath,
    required CharBlock block,
    bool debug = false,
  }) async {
    _addLog('http', 'POST /verify_char id=${block.id} text=${block.text}');
    final r =
        await _post(
          Uri.parse('$_base/verify_char'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'image_path': imagePath,
            'x': block.x,
            'y': block.y,
            'w': block.w,
            'h': block.h,
            'text': block.text,
            'conf': block.conf,
            'cls_rank': _clsRankOf(block),
            'debug': debug,
          }),
        ).timeout(
          const Duration(seconds: 60),
          onTimeout: () {
            throw TimeoutException('单字墨迹校验超时');
          },
        );
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /verify_char failed status=${r.statusCode} body=${r.body}',
        isError: true,
      );
      throw Exception('verify_char failed: ${r.body}');
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    final outcome = CharVerifyOutcome.fromJson(data);
    _addLog(
      'http',
      'POST /verify_char ok level=${outcome.level} '
          'score=${outcome.score?.toStringAsFixed(3)}',
    );
    return outcome;
  }

  /// 整页字块批量墨迹校验（编辑器「校验本页」）：纯 CPU，与识别任务
  /// 不互斥；单字失败进 errors 不中断整批。
  static Future<CharVerifyBatchResult> verifyCharsBatch({
    required String imagePath,
    required List<CharBlock> blocks,
    String? projectDir,
  }) async {
    _addLog('http', 'POST /verify_chars_batch blocks=${blocks.length}');
    final r =
        await _post(
          Uri.parse('$_base/verify_chars_batch'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'image_path': imagePath,
            'project_dir': projectDir,
            'blocks': blocks
                .map(
                  (b) => {
                    'id': b.id,
                    'x': b.x,
                    'y': b.y,
                    'w': b.w,
                    'h': b.h,
                    'text': b.text,
                    'conf': b.conf,
                    'status': b.status,
                  },
                )
                .toList(),
          }),
        ).timeout(
          const Duration(minutes: 5),
          onTimeout: () {
            throw TimeoutException('整页墨迹校验超时，请稍后重试');
          },
        );
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /verify_chars_batch failed status=${r.statusCode} '
            'body=${r.body}',
        isError: true,
      );
      throw Exception('verify_chars_batch failed: ${r.body}');
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    final rawResults = data['results'] as Map? ?? const {};
    final results = rawResults.map(
      (key, value) => MapEntry(
        key.toString(),
        CharVerifyOutcome.fromJson(Map<String, dynamic>.from(value as Map)),
      ),
    );
    final errors = (data['errors'] as Map? ?? const {}).map(
      (key, value) => MapEntry(key.toString(), value.toString()),
    );
    final mismatch = results.values.where((e) => e.level == 'mismatch').length;
    final suspect = results.values.where((e) => e.level == 'suspect').length;
    _addLog(
      'http',
      'POST /verify_chars_batch ok blocks=${results.length} '
          'mismatch=$mismatch suspect=$suspect errors=${errors.length}',
    );
    return CharVerifyBatchResult(
      results: results,
      errors: errors,
      elapsedMs: (data['elapsed_ms'] as num?)?.toDouble() ?? 0,
    );
  }

  // --- 墨迹比对模型（siamese）训练 + 跨页模板库 ----------------------------

  /// 比对模型数据概况：确认单字数（正样本）/改过首选（硬负）/就绪门槛。
  static Future<Map<String, dynamic>> verifyTrainData(String projectDir) async {
    return _postJson('/verify/train/data', {'project_dir': projectDir});
  }

  /// 导出图对数据集（墨迹/字形 128 画布 + 正/硬负样本 + 易混挖掘）。
  static Future<Map<String, dynamic>> verifyTrainExport(
    String projectDir, {
    bool force = false,
  }) async {
    return _postJson('/verify/train/export', {
      'project_dir': projectDir,
      'force': force,
    });
  }

  /// 启动比对模型训练（子进程）；进度走 [verifyTrainStatus]。
  static Future<Map<String, dynamic>> verifyTrainStart(
    String projectDir, {
    int epochs = 60,
    String device = 'auto',
  }) async {
    return _postJson('/verify/train/start', {
      'project_dir': projectDir,
      'epochs': epochs,
      'device': device,
    });
  }

  /// 比对模型训练任务列表与已训模型（含激活状态）。
  static Future<Map<String, dynamic>> verifyTrainStatus() async {
    final r = await _get(
      Uri.parse('$_base/verify/train/status'),
    ).timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) {
      throw Exception('verify/train/status failed: ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> verifyTrainStop(String taskId) async {
    return _postJson('/verify/train/stop', {'task_id': taskId});
  }

  static Future<Map<String, dynamic>> verifyTrainActivate({
    String? runDir,
  }) async {
    return _postJson('/verify/train/activate', {'run_dir': runDir});
  }

  static Future<Map<String, dynamic>> verifyTrainDeactivate() async {
    return _postJson('/verify/train/deactivate', const {});
  }

  /// 增量合并一页已确认字的墨迹模板（「确认并保存」后调用，失败静默）。
  static Future<void> verifyTemplatesUpdate({
    required String projectDir,
    required String imagePath,
    required List<CharBlock> blocks,
  }) async {
    try {
      await _postJson('/verify/templates/update', {
        'project_dir': projectDir,
        'image_path': imagePath,
        'blocks': blocks
            .map(
              (b) => {
                'id': b.id,
                'x': b.x,
                'y': b.y,
                'w': b.w,
                'h': b.h,
                'text': b.text,
                'status': b.status,
              },
            )
            .toList(),
      }).timeout(const Duration(seconds: 60));
    } catch (e) {
      _addLog('http', 'POST /verify/templates/update skipped: $e');
    }
  }

  static Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    _addLog('http', 'POST $path');
    final r = await _post(
      Uri.parse('$_base$path'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    ).timeout(const Duration(minutes: 5));
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST $path failed status=${r.statusCode} '
            'body=${r.body}',
        isError: true,
      );
      throw Exception('$path failed: ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// 调试用：调用 /segment 并传 debug=true，后端会生成 `<base>_debug.png`。
  /// 返回 (debugImagePath, linesCount, blocksCount, engine)。
  static Future<DebugSegmentResult> segmentDebug({
    required String imagePath,
    required ProjectSettings settings,
  }) async {
    _addLog(
      'http',
      'POST /segment (debug) image_path=$imagePath '
          'layout=${settings.layoutMode} orientation=${settings.orientation} '
          'h_dir=${settings.horizontalDir} v_dir=${settings.verticalDir}',
    );
    final r =
        await _post(
          Uri.parse('$_base/segment'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'image_path': imagePath,
            'layout_mode': settings.layoutMode,
            'orientation': settings.orientation,
            'horizontal_dir': settings.horizontalDir,
            'vertical_dir': settings.verticalDir,
            'debug': true,
          }),
        ).timeout(
          const Duration(minutes: 10),
          onTimeout: () {
            throw TimeoutException('整页识别超时（10 分钟）——GPU 被其他程序占用时识别会显著变慢，请稍后重试');
          },
        );
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /segment (debug) failed status=${r.statusCode} body=${r.body}',
        isError: true,
      );
      throw Exception('segment debug failed: ${r.body}');
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    final debugTrace = data['debug_trace'];
    if (debugTrace is List && debugTrace.isNotEmpty) {
      final messages = debugTrace.map((item) => item.toString()).toList();
      _addLogBatch(
        'trace',
        messages,
        isError: messages.any(
          (message) =>
              message.contains(' failed') ||
              message.contains('Traceback') ||
              message.contains('unavailable'),
        ),
      );
    }
    final debugPath = data['debug_image_path'] as String?;
    final maskPath = data['mask_image_path'] as String?;
    final linesCount = (data['lines'] as List?)?.length ?? 0;
    final blocksCount = (data['blocks'] as List?)?.length ?? 0;
    final engine = data['engine']?.toString() ?? '';
    _addLog(
      'http',
      'POST /segment (debug) ok engine=$engine lines=$linesCount blocks=$blocksCount debug_image=${debugPath ?? "null"} mask_image=${maskPath ?? "null"}',
    );
    return DebugSegmentResult(
      debugImagePath: debugPath,
      maskImagePath: maskPath,
      linesCount: linesCount,
      blocksCount: blocksCount,
      engine: engine,
      raw: data,
    );
  }

  static Future<int> crop(
    String imagePath,
    String outputDir,
    List<CharBlock> blocks,
  ) async {
    _addLog('http', 'POST /crop blocks=${blocks.length} output_dir=$outputDir');
    final r = await _post(
      Uri.parse('$_base/crop'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'image_path': imagePath,
        'output_dir': outputDir,
        'blocks': blocks.map((b) => b.toJson()).toList(),
      }),
    );
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /crop failed status=${r.statusCode} body=${r.body}',
        isError: true,
      );
      throw Exception('crop failed: ${r.body}');
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    final count = data['count'] as int;
    _addLog('http', 'POST /crop ok count=$count');
    return count;
  }

  /// CRNN 序列导出：对每个行做 crop → 逆时针旋转 90° → 高度归一化 → 写 jpg + labels.txt。
  static Future<int> exportCrnn({
    required String imagePath,
    required List<LineBlock> lines,
    required String outputDir,
    int targetHeight = 32,
    int paddingColor = 255,
  }) async {
    _addLog(
      'http',
      'POST /export_crnn lines=${lines.length} output_dir=$outputDir '
          'target_height=$targetHeight',
    );
    final r = await _post(
      Uri.parse('$_base/export_crnn'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'image_path': imagePath,
        'lines': lines
            .map(
              (l) => {
                'line_id': l.id,
                'x': l.x,
                'y': l.y,
                'w': l.w,
                'h': l.h,
                'orientation': l.orientation,
                'text': l.text,
              },
            )
            .toList(),
        'output_dir': outputDir,
        'target_height': targetHeight,
        'padding_color': paddingColor,
      }),
    );
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /export_crnn failed status=${r.statusCode} body=${r.body}',
        isError: true,
      );
      throw Exception('export_crnn failed: ${r.body}');
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    final count = data['count'] as int;
    _addLog('http', 'POST /export_crnn ok count=$count');
    return count;
  }

  /// LMDB 打包：读取 crnn_output_dir 下的 labels.txt 和图像，序列化写入 lmdb_path。
  static Future<int> packLmdb({
    required String crnnOutputDir,
    required String lmdbPath,
    int mapSize = 1073741824,
  }) async {
    _addLog(
      'http',
      'POST /pack_lmdb crnn_output_dir=$crnnOutputDir lmdb_path=$lmdbPath',
    );
    final r = await _post(
      Uri.parse('$_base/pack_lmdb'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'crnn_output_dir': crnnOutputDir,
        'lmdb_path': lmdbPath,
        'map_size': mapSize,
      }),
    );
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /pack_lmdb failed status=${r.statusCode} body=${r.body}',
        isError: true,
      );
      throw Exception('pack_lmdb failed: ${r.body}');
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    final count = data['count'] as int;
    _addLog('http', 'POST /pack_lmdb ok count=$count');
    return count;
  }

  static void clearLogs() {
    _logs.clear();
    _addLog('app', '后台控制台已清空。');
  }

  // ── 训练与模型管理 ──

  /// 各层可用标注统计（不生成数据集）。
  ///
  /// 后端统计是全库扫描，忙于检查/训练时一次扫描可能远超平时，
  /// 超时放宽到 120s（与训练前检测一致），配合训练页失败降级。
  static Future<Map<String, dynamic>> trainStats(String projectDir) async {
    final r = await _get(
      Uri.parse(
        '$_base/train/stats?project_dir=${Uri.encodeComponent(projectDir)}',
      ),
    ).timeout(const Duration(seconds: 120));
    if (r.statusCode != 200) {
      throw Exception('train/stats failed: ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// 生成指定层（空=全部）训练数据集，返回各层统计。
  static Future<Map<String, dynamic>> generateTrainDatasets({
    required String projectDir,
    List<String> layers = const [],
    bool force = false,
  }) async {
    _addLog('http', 'POST /train/datasets layers=$layers force=$force');
    final r = await _post(
      Uri.parse('$_base/train/datasets'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'project_dir': projectDir,
        'layers': layers,
        'force': force,
      }),
    ).timeout(const Duration(minutes: 10));
    if (r.statusCode != 200) {
      throw Exception('train/datasets failed: ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// 页级增量导出：只写新增/变化的页到统一数据集目录；manifest 记账
  /// （与数据同住、可跨机迁移）；删书不影响已导出数据与统计。
  /// [force]=true 重写书库内全部有效页（书库外的书仍不动）。
  static Future<Map<String, dynamic>> exportTrainDatasets({
    required String projectDir,
    List<String> layers = const [],
    bool force = false,
  }) async {
    _addLog('http', 'POST /train/export layers=$layers force=$force');
    final r = await _post(
      Uri.parse('$_base/train/export'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'project_dir': projectDir,
        'layers': layers,
        'force': force,
      }),
    ).timeout(const Duration(minutes: 10));
    if (r.statusCode != 200) {
      throw Exception('train/export failed: ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// 数据集/训练模型根目录配置（train_paths.json，机器本地）。
  static Future<Map<String, dynamic>> trainPathsGet() async {
    final r = await _get(
      Uri.parse('$_base/train/paths'),
    ).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      throw Exception('train/paths failed: ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// 更新路径配置（空字符串 = 不改该字段；热生效不重启）。
  static Future<Map<String, dynamic>> trainPathsSet({
    String datasetRoot = '',
    String trainedRoot = '',
  }) async {
    _addLog(
      'http',
      'POST /train/paths datasetRoot=$datasetRoot trainedRoot=$trainedRoot',
    );
    final r = await _post(
      Uri.parse('$_base/train/paths'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'dataset_root': datasetRoot,
        'trained_root': trainedRoot,
      }),
    ).timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) {
      throw Exception('train/paths set failed: ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// 删除一次训练的 run（目录+注册表条目；启用中的先自动停用）。
  static Future<Map<String, dynamic>> deleteModelRun({
    required String layer,
    required String runDir,
  }) async {
    _addLog('http', 'POST /models/delete_run layer=$layer run=$runDir');
    final r = await _post(
      Uri.parse('$_base/models/delete_run'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'layer': layer, 'run_dir': runDir}),
    ).timeout(const Duration(seconds: 120));
    if (r.statusCode != 200) {
      throw Exception('models/delete_run failed: ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// 删除一个中间轮检查点（epoch{N}.pt）释放磁盘。后端拒绝 best/last
  /// 与当前启用来源检查点；返回 {path, size, sizeMbFreed}。
  static Future<Map<String, dynamic>> deleteModelCheckpoint({
    required String layer,
    required String path,
  }) async {
    _addLog('http', 'POST /models/delete_checkpoint layer=$layer');
    final r = await _post(
      Uri.parse('$_base/models/delete_checkpoint'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'layer': layer, 'path': path}),
    ).timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) {
      throw Exception('models/delete_checkpoint failed: ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// 导入外部 .pt 模型为该层的一个 run（复制进训练根并登记）。
  static Future<Map<String, dynamic>> importModel({
    required String layer,
    required String path,
  }) async {
    _addLog('http', 'POST /models/import layer=$layer');
    final r = await _post(
      Uri.parse('$_base/models/import'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'layer': layer, 'path': path}),
    ).timeout(const Duration(seconds: 300));
    if (r.statusCode != 200) {
      throw Exception('models/import failed: ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// 训练模型根目录扫描：每个 run 的占用与状态（清理中心数据源）。
  /// {root, totalMb, runs: [{layer, runDir, name, registered, finished,
  ///  trained, epochsCount, epochsMb, bestMb, sizeMb}]}
  static Future<Map<String, dynamic>> modelCleanupScan() async {
    final r = await _get(
      Uri.parse('$_base/models/cleanup_scan'),
    ).timeout(const Duration(seconds: 60));
    if (r.statusCode != 200) {
      throw Exception('models/cleanup_scan failed: ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// 清理一个 run：action='epochs' 删全部中间轮（保留 best/last 与启用
  /// 来源）；action='dir' 整删未登记残目录。返回 {deleted, skippedActive,
  /// freedMb}。
  static Future<Map<String, dynamic>> modelCleanupRun({
    required String layer,
    required String runDir,
    required String action,
  }) async {
    _addLog('http', 'POST /models/cleanup layer=$layer action=$action');
    final r = await _post(
      Uri.parse('$_base/models/cleanup'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'layer': layer, 'run_dir': runDir, 'action': action}),
    ).timeout(const Duration(seconds: 300));
    if (r.statusCode != 200) {
      throw Exception('models/cleanup failed: ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// run 目录磁盘占用（删除确认框展示用）。
  static Future<double> modelRunSize(String runDir) async {
    final r = await _get(
      Uri.parse(
        '$_base/models/run_size?run_dir=${Uri.encodeQueryComponent(runDir)}',
      ),
    ).timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) {
      throw Exception('models/run_size failed: ${r.body}');
    }
    final data = jsonDecode(r.body);
    return (data is Map && data['size_mb'] is num)
        ? (data['size_mb'] as num).toDouble()
        : 0;
  }

  /// 启动一层模型的训练（后台任务）。
  static Future<Map<String, dynamic>> startTraining({
    required String projectDir,
    required String layer,
    String baseModel = 'yolov8s.pt',
    int epochs = 150,
    int imgsz = 1280,
    int batch = -1,
    String device = 'auto', // auto | cpu | cuda
    int savePeriod = 0, // 每 N 轮存一次中间检查点（0=不存）
  }) async {
    _addLog(
      'http',
      'POST /train/start layer=$layer base=$baseModel epochs=$epochs '
          'imgsz=$imgsz device=$device savePeriod=$savePeriod',
    );
    final r = await _post(
      Uri.parse('$_base/train/start'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'project_dir': projectDir,
        'layer': layer,
        'base_model': baseModel,
        'epochs': epochs,
        'imgsz': imgsz,
        'batch': batch,
        'device': device,
        'save_period': savePeriod,
      }),
    ).timeout(const Duration(seconds: 60));
    if (r.statusCode != 200) {
      throw Exception('train/start failed: ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// 训练任务状态列表（含进度与日志尾）。
  static Future<List<Map<String, dynamic>>> trainStatus() async {
    final r = await _get(
      Uri.parse('$_base/train/status'),
    ).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      throw Exception('train/status failed: ${r.body}');
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    return (data['tasks'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  static Future<void> stopTraining(String taskId) async {
    final r = await _post(
      Uri.parse('$_base/train/stop'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'task_id': taskId}),
    ).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      throw Exception('train/stop failed: ${r.body}');
    }
  }

  /// 训练曲线（/train/curve）：逐 epoch 指标/损失（results.csv）+ 已存
  /// 中间检查点清单。runDir 支持进行中任务与注册表历史 run。
  static Future<Map<String, dynamic>> trainCurve(String runDir) async {
    final r = await _get(
      Uri.parse('$_base/train/curve?run_dir=${Uri.encodeComponent(runDir)}'),
    ).timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) {
      throw Exception('train/curve failed: ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// 模型注册表：每层当前启用模型与历史 run。
  static Future<Map<String, Map<String, dynamic>>> listModels() async {
    final r = await _get(
      Uri.parse('$_base/models'),
    ).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      throw Exception('models failed: ${r.body}');
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    return (data['layers'] as Map).map(
      (k, v) => MapEntry(k.toString(), Map<String, dynamic>.from(v as Map)),
    );
  }

  static Future<void> activateModel(String layer, {String? modelPath}) async {
    final r = await _post(
      Uri.parse('$_base/models/activate'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'layer': layer, 'model_path': modelPath}),
    ).timeout(const Duration(seconds: 60));
    if (r.statusCode != 200) {
      throw Exception('models/activate failed: ${r.body}');
    }
  }

  static Future<void> deactivateModel(String layer) async {
    final r = await _post(
      Uri.parse('$_base/models/deactivate'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'layer': layer}),
    ).timeout(const Duration(seconds: 60));
    if (r.statusCode != 200) {
      throw Exception('models/deactivate failed: ${r.body}');
    }
  }

  /// 手动发版打包（POST /models/pack）：把当前激活的各层 YOLO + Kraken
  /// 识别模型打成 Ed25519 签名的 models_release.zjpack（随安装包分发，
  /// 用户机散文件缺失时自动回落此包）。返回 manifest：entries/layers
  /// （来源溯源）/size_bytes/sha256，供发版清单展示与 CHANGELOG 粘贴。
  /// 跨语言格式基准：响应字段以 python_service/api_pack.py 为准。
  static Future<Map<String, dynamic>> packModels({String? packVersion}) async {
    _addLog('http', 'POST /models/pack');
    final r = await _post(
      Uri.parse('$_base/models/pack'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'pack_version': packVersion ?? ''}),
    ).timeout(const Duration(minutes: 10));
    if (r.statusCode != 200) {
      _addLog(
        'http',
        'POST /models/pack failed status=${r.statusCode} body=${r.body}',
        isError: true,
      );
      throw Exception(_detailOf(r.body));
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  static void _addLogBatch(
    String source,
    List<String> messages, {
    bool isError = false,
  }) {
    if (messages.isEmpty) return;
    final now = DateTime.now();
    for (final message in messages) {
      _logs.add(
        BackendLogEntry(
          time: now,
          source: source,
          message: message,
          isError: isError,
        ),
      );
    }
    if (_logs.length > _maxLogEntries) {
      _logs.removeRange(0, _logs.length - _maxLogEntries);
    }
    if (!_logController.isClosed) {
      _logController.add(
        BackendLogEntry(
          time: now,
          source: source,
          message: '已接收 ${messages.length} 行 $source 日志',
          isError: isError,
        ),
      );
    }
    debugPrint('[py:$source] received ${messages.length} lines');
  }

  /// 编辑器手势/交互诊断日志：走后台控制台的 [app] 通道，与后端日志
  /// 同一界面可查（字框拖拽/缩放的起止与提交命中情况等）。
  static void addAppLog(String message, {bool isError = false}) =>
      _addLog('app', message, isError: isError);

  static void _addLog(
    String source,
    String message, {
    bool isError = false,
    bool toConsoleLog = true,
    DateTime? at,
  }) {
    final entry = BackendLogEntry(
      time: at ?? DateTime.now(),
      source: source,
      message: message,
      isError: isError,
    );
    _logs.add(entry);
    if (_logs.length > _maxLogEntries) {
      _logs.removeRange(0, _logs.length - _maxLogEntries);
    }
    if (!_logController.isClosed) _logController.add(entry);
    debugPrint('[py:$source] $message');
    if (toConsoleLog) _appendConsoleLogFile(entry);
  }

  // ── 诊断产物清理（崩溃转储 / 日志）──────────────────────────────────

  /// 后端服务目录（清理页的兜底路径用：后端起不来时 Dart 直删转储）。
  static String? get logServiceDir => _logServiceDir;

  /// 清理面板数据（/cleanup/status）：转储/日志清单、字节量、自动策略。
  /// 服务未运行或查询失败返回 null（调用方走本地兜底）。
  static Future<Map<String, dynamic>?> cleanupStatus() async {
    try {
      final r = await _get(
        Uri.parse('$_base/cleanup/status'),
      ).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return null;
      final decoded = jsonDecode(r.body);
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  /// 手动清理（/cleanup/run）。删除大转储在 NTFS 上是元数据操作，秒级。
  static Future<Map<String, dynamic>> cleanupRun({
    Set<String> targets = const {},
    int keepLastDump = 0,
  }) async {
    final r = await _post(
      Uri.parse('$_base/cleanup/run'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'targets': targets.toList(),
        'keep_last_dump': keepLastDump,
      }),
    ).timeout(const Duration(minutes: 5));
    if (r.statusCode != 200) {
      throw Exception('cleanup/run failed: ${r.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(r.body) as Map);
  }

  /// 本地兜底：后端未运行时直接删崩溃转储（磁盘被几十 GB 转储撑满时
  /// 后端恰恰起不来，这条路径正是那时的救命绳）。返回释放字节数。
  static Future<int> localDumpCleanup({int keepLast = 0}) async {
    final dir = _logServiceDir;
    if (dir == null) return 0;
    final dumpsDir = Directory(p.normalize('$dir/../crash_dumps'));
    if (!await dumpsDir.exists()) return 0;
    final files = <File>[];
    await for (final e in dumpsDir.list()) {
      if (e is File && e.path.toLowerCase().endsWith('.dmp')) files.add(e);
    }
    files.sort(
      (a, b) => (a.lastModifiedSync()).compareTo(b.lastModifiedSync()),
    );
    final doomed = keepLast > 0
        ? files.sublist(0, files.length - keepLast)
        : files;
    var freed = 0;
    for (final f in doomed) {
      try {
        final len = await f.length();
        await f.delete();
        freed += len;
      } catch (_) {}
    }
    return freed;
  }

  // ── 独立 CMD 后台日志窗口 ─────────────────────────────────────────────
  // Flutter 侧日志（[app] 启动过程 / [http] 请求步骤 / [trace] 诊断 / 手势
  // 日志）落盘 app_console.log，后端 tee 到 service_console.log，独立
  // CMD 窗口用 PowerShell Get-Content -Wait 同时实时滚动两个文件——
  // 软件进不去 OCR（后端起不来）时也能看到完整启动过程与端口信息。
  static String? _logServiceDir;
  static bool? _autoOpenLogConsoleCache;
  static const String _kUiSettingsFile = 'app_ui_settings.json';
  static Future<void> _logFileQueue = Future.value();

  static void _appendConsoleLogFile(BackendLogEntry entry) {
    final dir = _logServiceDir;
    if (dir == null) return;
    final file = File('$dir/logs/app_console.log');
    final h = entry.time.hour.toString().padLeft(2, '0');
    final m = entry.time.minute.toString().padLeft(2, '0');
    final s = entry.time.second.toString().padLeft(2, '0');
    final line = '[$h:$m:$s] [${entry.source}] ${entry.message}\n';
    // 顺序追加（future 链），失败静默——日志落盘不能影响主流程。
    _logFileQueue = _logFileQueue.then((_) async {
      try {
        await file.parent.create(recursive: true);
        final raf = await file.open(mode: FileMode.append);
        await raf.writeString(line);
        await raf.close();
      } catch (_) {}
    });
  }

  /// 崩溃时刻的关键日志**同步**落盘：未捕获异常的完整栈必须在进程
  /// 死亡前写进 app_console.log——常规日志走异步 future 链，进程直接
  /// 退出时尾部日志全部丢失（排障因此拿不到崩溃栈）。只在异常处理器
  /// 里调用：同步 IO 阻塞 UI 线程，正常日志禁用。
  static void writeCrashLineSync(String message) {
    final now = DateTime.now();
    final h = now.hour.toString().padLeft(2, '0');
    final m = now.minute.toString().padLeft(2, '0');
    final s = now.second.toString().padLeft(2, '0');
    final line = '[$h:$m:$s] [crash] $message\n';
    final dir = _logServiceDir;
    if (dir == null) {
      debugPrint('[crash] $message'); // 启动早期崩溃：至少控制台可见
      return;
    }
    try {
      final file = File('$dir/logs/app_console.log');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(line, mode: FileMode.append, flush: true);
    } catch (_) {
      debugPrint('[crash] $message');
    }
  }

  static Future<void> _ensureConsoleLogFiles(String serviceDir) async {
    try {
      for (final name in ['app_console.log', 'service_console.log']) {
        final f = File('$serviceDir/logs/$name');
        if (!await f.exists()) await f.create(recursive: true);
      }
    } catch (_) {}
  }

  /// 后端是否在独立控制台窗口中运行（ComfyUI 式，默认开，可关，落盘于
  /// python_service/app_ui_settings.json；关闭后回到无窗口管道模式，
  /// 重启应用生效）。
  static bool autoOpenLogConsole({String? serviceDir}) {
    final cached = _autoOpenLogConsoleCache;
    if (cached != null) return cached;
    var value = true;
    try {
      final dir = serviceDir ?? _logServiceDir;
      if (dir != null) {
        final f = File('$dir/$_kUiSettingsFile');
        if (f.existsSync()) {
          final data = jsonDecode(f.readAsStringSync());
          if (data is Map && data['openLogConsole'] is bool) {
            value = data['openLogConsole'] as bool;
          }
        }
      }
    } catch (_) {}
    _autoOpenLogConsoleCache = value;
    return value;
  }

  static Future<void> setAutoOpenLogConsole(
    bool value, {
    String? serviceDir,
  }) async {
    _autoOpenLogConsoleCache = value;
    final dir = serviceDir ?? _logServiceDir;
    if (dir == null) return;
    _logServiceDir = dir;
    try {
      final f = File('$dir/$_kUiSettingsFile');
      var data = <String, dynamic>{};
      if (f.existsSync()) {
        final parsed = jsonDecode(f.readAsStringSync());
        if (parsed is Map) data = Map<String, dynamic>.from(parsed);
      }
      data['openLogConsole'] = value;
      await f.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    } catch (_) {}
  }

  /// 打开独立 CMD 后台日志窗口（只读查看，跟随 app+后端两个日志文件）。
  /// 后端默认已运行在自己的控制台窗口里（ComfyUI 式），此窗口供无窗口
  /// 模式或额外查看用。同样经批处理拉起（open_console_viewer.cmd），避
  /// 开 Dart/cmd 的引号陷阱。
  static Future<void> openStandaloneConsole({String? serviceDir}) async {
    final dir = serviceDir ?? _logServiceDir;
    if (dir == null) return;
    _logServiceDir = dir;
    await _ensureConsoleLogFiles(dir);
    try {
      await Process.run('cmd', [
        '/c',
        'start',
        '/D',
        dir,
        'open_console_viewer.cmd',
      ]);
    } catch (e) {
      _addLog('app', '打开后台日志窗口失败：$e', isError: true);
    }
  }

  // ── service_console.log 跟随器（窗口模式的后端输出来源）─────────────
  // 后端 tee 到该文件（stderr 行带 "[stderr] " 前缀）；跟随器增量读取，
  // 新行推入内置日志流（面板/模型对比页照常消费），stderr 喂启动失败
  // 诊断。不写回 app_console.log（后端行已在 service_console.log 里，
  // 重复写入会让只读窗口看到两份）。
  static bool _consoleWindowMode = false;
  static Timer? _svcLogTimer;
  static int _svcLogOffset = 0;
  static final List<int> _svcLogTailBuf = [];
  // 跟随器缓冲上限：极端洪峰下处理跟不上时兜底丢弃，防止无界增长。
  static const int _svcLogMaxTailBytes = 8 << 20;

  static void _startServiceLogFollower() {
    _stopServiceLogFollower();
    final dir = _logServiceDir;
    if (dir == null) return;
    final file = File('$dir/logs/service_console.log');
    try {
      // 只跟随新增内容：跳到当前末尾，历史会话不灌进日志面板。
      _svcLogOffset = file.existsSync() ? file.lengthSync() : 0;
    } catch (_) {
      _svcLogOffset = 0;
    }
    _svcLogTimer = Timer.periodic(const Duration(milliseconds: 300), (_) async {
      try {
        if (!await file.exists()) return;
        final len = await file.length();
        if (len < _svcLogOffset) _svcLogOffset = 0; // 文件被清/轮转
        if (len == _svcLogOffset) return;
        final raf = await file.open();
        try {
          await raf.setPosition(_svcLogOffset);
          final data = await raf.read(len - _svcLogOffset);
          _svcLogOffset = len;
          _svcLogTailBuf.addAll(data);
          _drainServiceLogLines();
        } finally {
          await raf.close();
        }
      } catch (_) {}
    });
  }

  static void _drainServiceLogLines() {
    // 洪峰保护：识别期后端可能每秒喷数百行（实测 page_002 出现 627 行/秒
    // 的 [diag:split] 洪峰，伴随应用无任何日志地消失）。旧实现逐行
    // indexOf+removeRange(0,·)，对整段缓冲是 O(n²)，洪峰时 UI isolate 被
    // memmove 与 GC 压死。改为：定位最后一个换行 → 整段一次解码 + 一次
    // split → 单次 removeRange，总代价 O(n)；缓冲超限兜底丢弃（完整日志
    // 已落盘 service_console.log，丢弃只影响应用内实时回显）。
    final n = _svcLogTailBuf.length;
    if (n == 0) return;
    var end = -1; // 最后一个完整换行的下标（尾部半行留在缓冲）
    for (var i = n - 1; i >= 0; i--) {
      if (_svcLogTailBuf[i] == 10) {
        end = i;
        break;
      }
    }
    if (end < 0) {
      if (n > _svcLogMaxTailBytes) _svcLogTailBuf.clear();
      return;
    }
    final text = utf8.decode(
      _svcLogTailBuf.sublist(0, end),
      allowMalformed: true,
    );
    _svcLogTailBuf.removeRange(0, end + 1);
    for (final raw in text.split('\n')) {
      final line = raw.trimRight();
      if (line.isNotEmpty) _emitServiceLogLine(line);
    }
    if (_svcLogTailBuf.length > _svcLogMaxTailBytes) {
      final dropped = _svcLogTailBuf.length;
      _svcLogTailBuf.clear();
      _addLog(
        'stdout',
        '[follower] 日志洪峰超过实时处理能力，丢弃 $dropped 字节缓冲'
            '（完整内容见 logs/service_console.log）',
        toConsoleLog: false,
      );
    }
  }

  /// service_console.log 行格式：`[YYYY-MM-DD HH:MM:SS] [stderr] 文本` /
  /// `[YYYY-MM-DD HH:MM:SS] 文本`（时间戳由后端 _Tee 落盘时统一添加；
  /// 旧版后端无时间戳的行原样兼容）。时间戳直接作为日志条目时间，前后
  /// 端日志时间可精确对齐。
  static final RegExp _svcLogTsRe = RegExp(
    r'^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] (.*)$',
  );

  static void _emitServiceLogLine(String line) {
    var text = line;
    var at = DateTime.now();
    final tsMatch = _svcLogTsRe.firstMatch(text);
    if (tsMatch != null) {
      final parsed = DateTime.tryParse(tsMatch.group(1)!);
      if (parsed != null) {
        at = parsed;
        text = tsMatch.group(2)!;
      }
    }
    if (text.startsWith('[stderr] ')) {
      final body = text.substring('[stderr] '.length);
      _addLog('stderr', body, isError: true, toConsoleLog: false, at: at);
      _recentStderr.add(body);
      if (_recentStderr.length > 15) {
        _recentStderr.removeAt(0);
      }
    } else {
      _addLog('stdout', text, toConsoleLog: false, at: at);
    }
  }

  static void _stopServiceLogFollower() {
    _svcLogTimer?.cancel();
    _svcLogTimer = null;
    _svcLogTailBuf.clear();
  }

  /// 读取 service_console.log 的末尾若干行（启动失败诊断用）。
  static String? _tailServiceConsole({int maxLines = 15}) {
    final dir = _logServiceDir;
    if (dir == null) return null;
    try {
      final f = File('$dir/logs/service_console.log');
      if (!f.existsSync()) return null;
      final lines = f
          .readAsLinesSync()
          .where((l) => l.trim().isNotEmpty)
          .toList(growable: false);
      if (lines.isEmpty) return null;
      return lines.length <= maxLines
          ? lines.join('\n')
          : lines.sublist(lines.length - maxLines).join('\n');
    } catch (_) {
      return null;
    }
  }
}

/// Excalidraw 导出工作台的全部设置项（与后端 _DEFAULT_SETTINGS 一一对应）。
///
/// 改动任意项后 [exportExcalidraw] 重新生成场景即可在预览里看到效果；
/// 注入编辑器校对数据（ocrLines）时后端不跑识别，迭代是秒级的。
class ExcalidrawExportOptions {
  ExcalidrawExportOptions({
    this.textSource = 'editor', // editor=当前校对结果 | recognize=区域重识别
    this.detectRects = true,
    this.detectEllipses = true,
    this.detectLines = true,
    this.detectCurves = true,
    this.detectArrows = true,
    this.minShapeSize = 10,
    this.lineMinLen = 24,
    this.curveSimplify = 2.0,
    this.snapTolerance = 8,
    this.mergeDoubleLines = true,
    this.minCharConf = 0.0,
    this.scale = 1.0,
    this.roughness = 0,
    this.strokeWidth = 0, // 0=按实测笔画厚度
    this.colorMode = 'original', // original | mono | custom
    this.customColor = '#1e1e1e',
    this.fontFamily = 3, // 3=Normal / 1=Virgil 手写
    this.embedImage = false,
    this.embedOpacity = 100,
    this.groupElements = true,
  });

  final String textSource;
  final bool detectRects;
  final bool detectEllipses;
  final bool detectLines;
  final bool detectCurves;
  final bool detectArrows;
  final int minShapeSize;
  final int lineMinLen;
  final double curveSimplify;
  final int snapTolerance;
  final bool mergeDoubleLines;
  final double minCharConf;
  final double scale;
  final int roughness;
  final int strokeWidth;
  final String colorMode;
  final String customColor;
  final int fontFamily;
  final bool embedImage;
  final int embedOpacity;
  final bool groupElements;

  Map<String, dynamic> toJson() => {
    'detect_rects': detectRects,
    'detect_ellipses': detectEllipses,
    'detect_lines': detectLines,
    'detect_curves': detectCurves,
    'detect_arrows': detectArrows,
    'min_shape_size': minShapeSize,
    'line_min_len': lineMinLen,
    'curve_simplify': curveSimplify,
    'snap_tolerance': snapTolerance,
    'merge_double_lines': mergeDoubleLines,
    'min_char_conf': minCharConf,
    'scale': scale,
    'roughness': roughness,
    'stroke_width': strokeWidth,
    'color_mode': colorMode,
    'custom_color': customColor,
    'font_family': fontFamily,
    'embed_image': embedImage,
    'embed_opacity': embedOpacity,
    'group_elements': groupElements,
  };

  factory ExcalidrawExportOptions.fromJson(Map<String, dynamic> j) =>
      ExcalidrawExportOptions(
        textSource: j['textSource'] as String? ?? 'editor',
        detectRects: j['detectRects'] as bool? ?? true,
        detectEllipses: j['detectEllipses'] as bool? ?? true,
        detectLines: j['detectLines'] as bool? ?? true,
        detectCurves: j['detectCurves'] as bool? ?? true,
        detectArrows: j['detectArrows'] as bool? ?? true,
        minShapeSize: (j['minShapeSize'] as num?)?.toInt() ?? 10,
        lineMinLen: (j['lineMinLen'] as num?)?.toInt() ?? 24,
        curveSimplify: (j['curveSimplify'] as num?)?.toDouble() ?? 2.0,
        snapTolerance: (j['snapTolerance'] as num?)?.toInt() ?? 8,
        mergeDoubleLines: j['mergeDoubleLines'] as bool? ?? true,
        minCharConf: (j['minCharConf'] as num?)?.toDouble() ?? 0.0,
        scale: (j['scale'] as num?)?.toDouble() ?? 1.0,
        roughness: (j['roughness'] as num?)?.toInt() ?? 0,
        strokeWidth: (j['strokeWidth'] as num?)?.toInt() ?? 0,
        colorMode: j['colorMode'] as String? ?? 'original',
        customColor: j['customColor'] as String? ?? '#1e1e1e',
        fontFamily: (j['fontFamily'] as num?)?.toInt() ?? 3,
        embedImage: j['embedImage'] as bool? ?? false,
        embedOpacity: (j['embedOpacity'] as num?)?.toInt() ?? 100,
        groupElements: j['groupElements'] as bool? ?? true,
      );

  Map<String, dynamic> toPersist() => {
    'textSource': textSource,
    'detectRects': detectRects,
    'detectEllipses': detectEllipses,
    'detectLines': detectLines,
    'detectCurves': detectCurves,
    'detectArrows': detectArrows,
    'minShapeSize': minShapeSize,
    'lineMinLen': lineMinLen,
    'curveSimplify': curveSimplify,
    'snapTolerance': snapTolerance,
    'mergeDoubleLines': mergeDoubleLines,
    'minCharConf': minCharConf,
    'scale': scale,
    'roughness': roughness,
    'strokeWidth': strokeWidth,
    'colorMode': colorMode,
    'customColor': customColor,
    'fontFamily': fontFamily,
    'embedImage': embedImage,
    'embedOpacity': embedOpacity,
    'groupElements': groupElements,
  };
}
