import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' show ClientException;

import '../models/models.dart';
import 'book_region_apply.dart';
import 'page_recognition.dart';
import 'python_service.dart';
import 'storage.dart';
import 'system_awake.dart';

/// Live progress of one book inside the batch recognition queue. Purely a
/// UI snapshot; the persisted state lives on [Project] plus the annotation
/// files on disk.
@immutable
class RecognitionProgress {
  static const String failed = 'failed'; // snapshot-only state, never persisted
  static const String paused = 'paused'; // 用户手动停止，快照态；点继续即续跑

  /// 用户已请求停止、当前页（后端一页识别可达分钟级）还没跑完的瞬态——
  /// 界面立即显示"正在停止"，页边界退出后翻成 [paused]。
  static const String stopping = 'stopping';

  /// 任务类型：整本识别。
  static const String kindRecognize = 'recognize';

  /// 任务类型：按主区拆分（主区快设启动的后台批量拆分识别）。
  static const String kindRegionSplit = 'region_split';

  final String projectId;

  /// [RecognitionStatus.pending] while waiting, [.recognizing] while its
  /// pages run, [failed] after a page kept failing.
  final String status;

  /// 任务类型：整本识别（[kindRecognize]）或按主区拆分（[kindRegionSplit]）。
  /// 监控悬浮窗与首页卡片据此区分文案。
  final String kind;
  final int recognizedPages;
  final int totalPages;

  /// 1-based position in the queue (the running book is 1); 0 when queued out.
  final int queuePosition;

  /// 1-based page currently being recognized; 0 while waiting/not started.
  final int currentPage;

  /// 拆分任务的全部目标页（下标）；识别任务为空。主区快设据此锁定格子。
  final List<int> jobPages;

  /// 拆分任务尚未处理完的页（排队+在途之外）；识别任务为空。主区快设
  /// 据此标"已处理"角标、断点续跑。
  final List<int> remainingPages;

  /// 最近几页的平均单页耗时（秒）；本轮还没有识别完任何页时为 null。
  final double? avgPageSeconds;

  /// 按最近几页速度估算的剩余时间（秒）；无法估算时为 null。
  final int? etaSeconds;
  final String? error;

  const RecognitionProgress({
    required this.projectId,
    required this.status,
    required this.recognizedPages,
    required this.totalPages,
    this.kind = kindRecognize,
    this.queuePosition = 0,
    this.currentPage = 0,
    this.jobPages = const [],
    this.remainingPages = const [],
    this.avgPageSeconds,
    this.etaSeconds,
    this.error,
  });

  double get ratio =>
      totalPages <= 0 ? 1 : (recognizedPages / totalPages).clamp(0.0, 1.0);

  RecognitionProgress copyWith({
    String? status,
    int? recognizedPages,
    int? totalPages,
    int? queuePosition,
    int? currentPage,
    double? avgPageSeconds,
    int? etaSeconds,
    String? error,
    List<int>? remainingPages,
  }) => RecognitionProgress(
    projectId: projectId,
    status: status ?? this.status,
    recognizedPages: recognizedPages ?? this.recognizedPages,
    totalPages: totalPages ?? this.totalPages,
    kind: kind,
    queuePosition: queuePosition ?? this.queuePosition,
    currentPage: currentPage ?? this.currentPage,
    jobPages: jobPages,
    remainingPages: remainingPages ?? this.remainingPages,
    avgPageSeconds: avgPageSeconds ?? this.avgPageSeconds,
    etaSeconds: etaSeconds ?? this.etaSeconds,
    error: error ?? this.error,
  );
}

/// 队列里的一个任务：整本识别或按主区拆分（一本书同时最多一个任务）。
@immutable
class _QueueJob {
  const _QueueJob(
    this.project,
    this.kind, {
    this.pages = const [],
    this.aiEnabled = false,
  });

  final Project project;
  final String kind; // RecognitionProgress.kindRecognize | .kindRegionSplit
  final List<int> pages; // 拆分任务的目标页（下标升序）
  final bool aiEnabled; // 拆分任务是否启用 AI 整行裁决
}

/// 按主区拆分的断点（停止/失败/退出应用后可续跑），落盘在
/// `region_split_progress.json`。文件随任务生命周期实时维护：启动写
/// 全集、每完成一页收窄、全部完成时清除——任何时点退出应用，盘上都是
/// 「尚未完成的页」。主区快设读取它显示「继续拆分剩余 N 页」。
@immutable
class RegionSplitResume {
  const RegionSplitResume({required this.pages, required this.aiEnabled});

  final List<int> pages;
  final bool aiEnabled;
}

/// App-wide FIFO queue that recognizes every page of every newly added book,
/// one book after another. Within a book, pages run through a 2-page sliding
/// window (page N's recognition overlaps page N+1's layout detection); the
/// backend's recognition gate allows at most 2 concurrent requests and rejects
/// a 3rd with 409 (busy-waited below).
///
/// 「按主区拆分」（主区快设启动的批量拆分识别）作为第二种任务类型共用
/// 本队列：同一套监控悬浮窗/首页卡片、停止/删除控制、keepAwake 与
/// 「识别完成后关机」。一本书同时只允许一个任务在队。
///
/// A page's annotation file doubles as the "this page is done" marker, so
/// closing the app mid-run loses at most the pages in flight and the next
/// launch resumes from the first page without a file.
class RecognitionQueue extends ChangeNotifier {
  RecognitionQueue._();
  static final RecognitionQueue instance = RecognitionQueue._();

  final List<_QueueJob> _queue = [];
  final Map<String, RecognitionProgress> _progress = {};

  /// Books removed while queued or mid-flight; aborts their processing loop.
  final Set<String> _aborted = <String>{};
  bool _draining = false;

  /// 「识别完成后关机」开关（首页识别中卡片的进度条下方可勾选，不放在
  /// 新建任务页）。内存态、一次性：队列跑完触发一次后自动复位，App 重启
  /// 后不保留——避免第二天开机后误把再次识别当成还想要关机。
  bool _shutdownWhenIdle = false;

  /// 队列跑完后已计划系统关机的截止时刻（横幅倒计时用）；null = 无倒计时。
  DateTime? _shutdownAt;

  /// 系统关机命令执行失败的原因（横幅展示用）。
  String? _shutdownError;

  /// 计划关机前留给用户反悔的缓冲秒数（系统层面 shutdown /a 也可撤销）。
  static const int _shutdownDelaySeconds = 60;

  /// 忙闲时请求/释放系统保持唤醒的钩子（识别期间阻止自动待机）。生产
  /// 实现为 [SystemAwake.setRequired]，测试可替换为观察函数。成对调用：
  /// 队列开始处理时传 true，跑空后传 false。
  static void Function(bool required) keepAwakeHook = SystemAwake.setRequired;

  /// Busy-wait budget when the backend reports 409 (someone else is
  /// recognizing, e.g. a manual action in the editor): 60 × 5 s = 5 min,
  /// matching the backend's own recognition timeouts.
  ///
  /// 后端不可达（连接被拒/断开：后端正在启动、崩溃后重启、控制台窗口被
  /// 关闭）的等待预算：36 × 5 s = 3 分钟，远长于后端冷启动（conda + import
  /// + 模型预热约 20-40s）。旧版把这类连接级失败与真实页失败共用 2 次预算
  /// ——后端一断 6 秒就把整本书判失败，书卡上只留一句英文 SocketException
  ///（2026-09-29 实测：应用重启替换后端的窗口期识别即失败）。
  ///
  /// 三者与 [retryDelay] 都是实例无关的注入点：测试可改小加速（同
  /// [keepAwakeHook] 的缝）。
  static int busyRetryLimit = 60;
  static int unreachableRetryLimit = 36;
  static int pageRetryLimit = 2;
  static Duration retryDelay = const Duration(seconds: 5);

  Map<String, RecognitionProgress> get progress => Map.unmodifiable(_progress);

  Set<String> get queuedIds =>
      Set.unmodifiable(_queue.map((job) => job.project.id));

  /// 队列里的书（队首 = 正在识别/即将识别）。识别监控悬浮窗展示书名与
  /// 等待数用；暂停/失败的书已出队，不在此列。
  List<Project> get queuedProjects =>
      List.unmodifiable(_queue.map((job) => job.project));

  /// 队列任务视图（书 + 任务类型），识别悬浮窗的任务列表用。
  List<(Project, String)> get queuedJobs =>
      List.unmodifiable(_queue.map((job) => (job.project, job.kind)));

  RecognitionProgress? progressFor(String projectId) => _progress[projectId];

  /// 该书的「按主区拆分」任务是否进行中（排队/运行/正在停止）。
  /// 主区快设的返回导航（任务中直接退回书库）与校对编辑器的 dispose
  /// 落盘（跳过，避免旧内存标注覆盖后台刚写的页）据此避让后台写盘。
  bool isRegionSplitActive(String projectId) {
    final s = _progress[projectId];
    return s != null &&
        s.kind == RecognitionProgress.kindRegionSplit &&
        (s.status == RecognitionStatus.pending ||
            s.status == RecognitionStatus.recognizing ||
            s.status == RecognitionProgress.stopping);
  }

  // ── 识别完成后自动关机 ──

  /// 是否已勾选「识别完成后关机」（等当前队列跑完时生效）。
  bool get shutdownWhenIdle => _shutdownWhenIdle;

  /// 队列跑完后是否已进入关机倒计时。
  bool get shutdownPending => _shutdownAt != null;

  /// 关机倒计时的截止时刻；无倒计时时为 null。
  DateTime? get shutdownAt => _shutdownAt;

  /// 关机命令执行失败的原因；无失败时为 null。
  String? get shutdownError => _shutdownError;

  void setShutdownWhenIdle(bool value) {
    if (_shutdownWhenIdle == value) return;
    _shutdownWhenIdle = value;
    notifyListeners();
  }

  /// 清掉关机失败提示（横幅上的「知道了」）。
  void clearShutdownError() {
    if (_shutdownError == null) return;
    _shutdownError = null;
    notifyListeners();
  }

  /// 取消已计划的系统关机（执行 shutdown /a）并清掉倒计时横幅。
  Future<void> cancelScheduledShutdown() async {
    final hadSchedule = _shutdownAt != null;
    _shutdownAt = null;
    _shutdownError = null;
    notifyListeners();
    if (!hadSchedule || !Platform.isWindows) return;
    try {
      await Process.run('shutdown', ['/a']);
    } catch (_) {
      // 系统层已没有待执行的关机时会失败，忽略。
    }
  }

  /// 队列清空后的收尾：若勾选了「识别完成后关机」，调用系统 shutdown 安排
  /// 一次带缓冲的关机；倒计时期间用户可在首页横幅上取消（shutdown /a）。
  Future<void> _scheduleShutdownIfArmed() async {
    if (!_shutdownWhenIdle) return;
    _shutdownWhenIdle = false;
    _shutdownError = null;
    _shutdownAt = DateTime.now().add(
      const Duration(seconds: _shutdownDelaySeconds),
    );
    notifyListeners();
    if (!Platform.isWindows) {
      _shutdownError = '自动关机仅支持 Windows 系统';
      notifyListeners();
      return;
    }
    try {
      final result = await Process.run('shutdown', [
        '/s',
        '/t',
        '$_shutdownDelaySeconds',
        '/c',
        '字迹：整本书识别结束，稍后自动关机',
      ]);
      if (result.exitCode != 0) {
        final message = '${result.stderr}'.trim();
        _shutdownError = message.isEmpty
            ? '关机命令执行失败（退出码 ${result.exitCode}）'
            : '关机命令执行失败：$message';
      }
    } catch (e) {
      _shutdownError = '关机命令执行失败：$e';
    }
    notifyListeners();
  }

  // 启动自动续跑（原 resumePending）已按需求移除：进入软件不自动开始
  // 识别，中断的书由用户在卡片上点「开始/继续识别」手动续跑（enqueue
  // 按"已有标注跳过"从断点继续）。

  /// Enqueue one book. No-op for completed books or books already queued.
  /// 导入未完成（import_pending，页图没转完）的书拒绝入队：空页书进队
  /// 会被 _processBook 直接标成识别完成，静默吞掉一本书。
  void enqueue(Project project) {
    if (project.importPending) return;
    if (project.recognitionCompleted) return;
    if (_queue.any((job) => job.project.id == project.id)) return;
    // 关机倒计时期间又排了新活（例如点「重试」）：自动撤销已计划的关机。
    if (_shutdownAt != null) {
      unawaited(cancelScheduledShutdown());
    }
    // 「手动开始识别」的书一旦开始识别（手动开始、拆分后自动识别等任何
    // 入口），此后断点续跑照旧；落盘由 _processBook 开始时的保存完成。
    project.autoRecognize = true;
    _aborted.remove(project.id);
    _queue.add(_QueueJob(project, RecognitionProgress.kindRecognize));
    _progress[project.id] = RecognitionProgress(
      projectId: project.id,
      status: RecognitionStatus.pending,
      recognizedPages: project.recognizedPages,
      totalPages: project.imageFiles.length,
    );
    _refreshPositions();
    notifyListeners();
    _drain();
  }

  /// 入队「按主区拆分」任务（主区快设启动）：对 [pages] 逐页按主区级联
  /// 拆分识别（双页滑动窗口），[aiEnabled] 决定是否跑 AI 整行裁决。
  /// 同一本书已有任务在队时 no-op。任务在后台执行，启动界面可自由离开
  /// （书库会拦编辑入口），停止/删除走 pause/remove，关机走本队列开关。
  void enqueueRegionSplit(
    Project project, {
    required List<int> pages,
    required bool aiEnabled,
  }) {
    if (pages.isEmpty) return;
    if (_queue.any((job) => job.project.id == project.id)) return;
    if (_shutdownAt != null) {
      unawaited(cancelScheduledShutdown());
    }
    _aborted.remove(project.id);
    final sorted = [...pages]..sort();
    _queue.add(
      _QueueJob(
        project,
        RecognitionProgress.kindRegionSplit,
        pages: sorted,
        aiEnabled: aiEnabled,
      ),
    );
    _progress[project.id] = RecognitionProgress(
      projectId: project.id,
      kind: RecognitionProgress.kindRegionSplit,
      status: RecognitionStatus.pending,
      recognizedPages: 0,
      totalPages: sorted.length,
      jobPages: List.unmodifiable(sorted),
      remainingPages: List.unmodifiable(sorted),
    );
    _refreshPositions();
    notifyListeners();
    _drain();
  }

  // ── 按主区拆分断点（region_split_progress.json）──

  File _resumeFile(String projectDir) =>
      File('$projectDir${Platform.pathSeparator}region_split_progress.json');

  /// 读取拆分断点（无/损坏返回 null）。主区快设据此显示「继续拆分」。
  static Future<RegionSplitResume?> loadRegionSplitResume(
    String projectDir,
  ) async {
    final f = File(
      '$projectDir${Platform.pathSeparator}region_split_progress.json',
    );
    if (!await f.exists()) return null;
    try {
      final j = jsonDecode(await f.readAsString());
      if (j is! Map) return null;
      final rawPages = j['pages'];
      if (rawPages is! List) return null;
      return RegionSplitResume(
        pages: [
          for (final v in rawPages)
            if (v is int) v,
        ],
        aiEnabled: j['ai_enabled'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveRegionSplitResume(
    String projectDir,
    List<int> pages,
    bool aiEnabled,
  ) async {
    if (!await Directory(projectDir).exists()) return;
    await ProjectStorage.writeJsonAtomicQuiet(_resumeFile(projectDir), {
      'pages': pages,
      'ai_enabled': aiEnabled,
      'saved_at': DateTime.now().toIso8601String(),
    });
  }

  Future<void> _clearRegionSplitResume(String projectDir) async {
    try {
      final f = _resumeFile(projectDir);
      if (await f.exists()) await f.delete();
    } catch (_) {
      // 断点清理失败不影响主流程（下次全量跑完会再清）。
    }
  }

  /// 「全书重新识别」：把书整本重置回"新加入"状态再从头识别——删除
  /// 全部页标注文件（所有页未确认未保存、识别框重来）、计数清零、
  /// 进入编辑回到第一页；AI 整行裁决按项目设置照常参与。断点机制
  /// 天然从头跑（无标注可跳），崩溃重启续跑也是全量。调用方负责让
  /// 用户确认（人工确认/校对成果会被覆盖且不可恢复）。
  Future<void> enqueueReRecognize(Project project) async {
    if (_queue.any((job) => job.project.id == project.id)) return;
    await ProjectStorage.clearAllAnnotations(project.projectDir);
    project.recognitionStatus = RecognitionStatus.pending;
    project.recognizedPages = 0;
    project.lastPageIndex = 0;
    PythonService.addAppLog(
      '[全书重新识别] 「${project.name}」已清空全部页标注，'
      '整书重置为新书状态从头识别',
    );
    enqueue(project);
  }

  /// 用户手动停止一本书的识别，之后可随时点「继续识别」接着跑（enqueue
  /// 按"已有标注即跳过"从断点续跑）。正在识别的书在当前页（含在途预取
  /// 页）完成后停住；还在排队的书立即出队。已识别页即断点，不丢进度。
  void pause(String projectId) {
    final idx = _queue.indexWhere((job) => job.project.id == projectId);
    if (idx < 0) return;
    final job = _queue[idx];
    final project = job.project;
    // 停掉的是队列里最后一本书时，"识别完成后关机"失去了意义——用户
    // 主动停下工作，不该被计划中的关机打断。
    if (_queue.length == 1) {
      _shutdownWhenIdle = false;
      if (_shutdownAt != null) unawaited(cancelScheduledShutdown());
    }
    if (idx == 0) {
      // 正在识别：标记中止并立即把快照翻成 stopping（一页识别可达分钟
      // 级，先给"正在停止"反馈）；_processBook 在页边界退出并落 paused。
      _aborted.add(projectId);
      final current = _progress[projectId];
      if (current != null) {
        _progress[projectId] = current.copyWith(
          status: RecognitionProgress.stopping,
        );
      }
      PythonService.addAppLog(
        '[整本识别] 用户停止「${project.name}」：当前页完成后停住，'
        '已识别页保留为断点，可随时继续',
      );
      notifyListeners();
      return;
    }
    // 还在排队：立即出队，直接给 paused 快照。
    _queue.removeAt(idx);
    _refreshPositions();
    _progress[project.id] = RecognitionProgress(
      projectId: project.id,
      kind: job.kind,
      status: RecognitionProgress.paused,
      recognizedPages: job.kind == RecognitionProgress.kindRegionSplit
          ? 0
          : project.recognizedPages,
      totalPages: job.kind == RecognitionProgress.kindRegionSplit
          ? job.pages.length
          : project.imageFiles.length,
      jobPages: job.pages,
      remainingPages: job.pages,
    );
    PythonService.addAppLog('[整本识别] 已取消「${project.name}」的排队（未开始识别）');
    notifyListeners();
  }

  /// Stop tracking a book (it was deleted); aborts in-flight pages.
  void remove(String projectId) {
    _aborted.add(projectId);
    _queue.removeWhere((job) => job.project.id == projectId);
    _progress.remove(projectId);
    _refreshPositions();
    notifyListeners();
  }

  void _refreshPositions() {
    for (var i = 0; i < _queue.length; i++) {
      final current = _progress[_queue[i].project.id];
      if (current != null) {
        _progress[_queue[i].project.id] = current.copyWith(
          queuePosition: i + 1,
        );
      }
    }
  }

  /// 是否正在跑识别队列（含 409 忙等与页间落盘的间隙）。
  bool get isRunning => _draining;

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    // 整批识别期间请求系统保持唤醒（显示器仍可熄灭），防止电源计划的
    // 空闲睡眠把挂机任务中断；跑空后立即恢复，与「识别完成后关机」
    // 衔接：干活时不睡，干完关机。
    keepAwakeHook(true);
    try {
      while (_queue.isNotEmpty) {
        final job = _queue.first;
        if (job.kind == RecognitionProgress.kindRegionSplit) {
          await _processRegionSplit(job);
        } else {
          await _processBook(job.project);
        }
        _queue.remove(job);
        _refreshPositions();
        // 失败/手动暂停的书保留快照，首页才能显示"识别失败 · 点击重试"
        // 或"已暂停 · 点击继续"；完成/被移除的书清掉快照，回落到磁盘上
        // 的持久化状态。
        final finalStatus = _progress[job.project.id]?.status;
        if (finalStatus != RecognitionProgress.failed &&
            finalStatus != RecognitionProgress.paused) {
          _progress.remove(job.project.id);
        }
        // Book finished (or gave up): the home page reloads so the entry
        // switches to its persisted state.
        notifyListeners();
      }
      // 队列彻底跑完：若勾选了「识别完成后关机」，此时安排系统关机。
      await _scheduleShutdownIfArmed();
    } finally {
      keepAwakeHook(false);
      _draining = false;
    }
  }

  Future<void> _processBook(Project project) async {
    final totalPages = project.imageFiles.length;
    if (totalPages == 0) {
      project.recognitionStatus = RecognitionStatus.completed;
      await _saveQuietly(project);
      return;
    }

    project.recognitionStatus = RecognitionStatus.recognizing;
    PythonService.addAppLog(
      '[整本识别] 开始：项目 AI 整行裁决='
      '${project.aiRecognitionAssist ? '开启' : '关闭'}，'
      '页面将按项目快照执行（自动框修复开关不影响文字 AI）',
    );
    _progress[project.id] = RecognitionProgress(
      projectId: project.id,
      status: RecognitionStatus.recognizing,
      recognizedPages: project.recognizedPages,
      totalPages: totalPages,
      queuePosition: 1,
    );
    notifyListeners();
    await _saveQuietly(project);

    // Heal the page counter from disk so a restart continues from the first
    // page without an annotation file.
    final done = await ProjectStorage.savedAnnotationIndices(
      project.projectDir,
      totalPages,
      imageFiles: project.imageFiles,
    );
    project.recognizedPages = done.length;

    // 每页实际耗时（只统计本轮真正跑过识别的页），用最近 5 页的平均速度
    // 估算剩余时间：GPU 忙闲波动大，全书平均会滞后于当前速度。
    final pageTimes = <double>[];

    void updateEta() {
      final current = _progress[project.id];
      if (current == null || pageTimes.isEmpty) return;
      final window = pageTimes.length > 5
          ? pageTimes.sublist(pageTimes.length - 5)
          : pageTimes;
      final avg = window.reduce((a, b) => a + b) / window.length;
      _progress[project.id] = current.copyWith(
        avgPageSeconds: avg,
        etaSeconds: ((totalPages - done.length) * avg).round(),
      );
    }

    // 滑动窗口页间流水线：页 N 识别期间预发页 N+1 的识别请求，最多两页
    // 在途（与后端识别门的双槽对应）——页 N 的 Kraken 识别与页 N+1 的
    // 版面检测在服务端重叠。结果严格按页序处理：进度推进、失败中止、
    // 断点落盘的语义与逐页串行完全一致。页 i+1 先完成时其标注文件已写
    // 盘（它就是"该页已完成"的断点标记），计数与 ETA 仍等到它成为最早
    // 在途页时才推进。
    const pipelineWindow = 2;
    final pending = <int>[
      for (var i = 0; i < totalPages; i++)
        if (!done.contains(i)) i,
    ];
    final inFlight = <int, Future<Object?>>{};
    var cursor = 0;
    while (true) {
      if (_aborted.contains(project.id)) {
        await _abortExit(project, totalPages);
        return;
      }
      while (inFlight.length < pipelineWindow && cursor < pending.length) {
        final i = pending[cursor++];
        final current = _progress[project.id];
        if (current != null) {
          _progress[project.id] = current.copyWith(currentPage: i + 1);
          notifyListeners();
        }
        inFlight[i] = _recognizePageWithRetry(project, i);
      }
      if (inFlight.isEmpty) break;
      final earliest = inFlight.keys.reduce((a, b) => a < b ? a : b);
      final sw = Stopwatch()..start();
      final failure = await inFlight.remove(earliest)!;
      sw.stop();
      if (_aborted.contains(project.id)) {
        await _abortExit(project, totalPages);
        return;
      }
      if (failure != null) {
        // Give up on this book for now. It stays resumable on disk (status
        // pending) and the home screen offers tap-to-retry. 另一页在途请求
        // 不再等它完成：其标注文件若已写盘就是有效断点标记，下次续跑
        // 自然跳过（_recognizePageWithRetry 不抛异常，遗留 Future 安全）。
        project.recognitionStatus = RecognitionStatus.pending;
        await _saveQuietly(project);
        _progress[project.id] = RecognitionProgress(
          projectId: project.id,
          status: RecognitionProgress.failed,
          recognizedPages: project.recognizedPages,
          totalPages: totalPages,
          queuePosition: 1,
          error: failure.toString(),
        );
        notifyListeners();
        return;
      }

      done.add(earliest);
      project.recognizedPages = done.length;
      pageTimes.add(sw.elapsedMilliseconds / 1000);
      _progress[project.id] = _progress[project.id]!.copyWith(
        recognizedPages: done.length,
      );
      updateEta();
      notifyListeners();
      await _saveQuietly(project);
    }

    project.recognitionStatus = RecognitionStatus.completed;
    project.recognizedPages = totalPages;
    await _saveQuietly(project);
  }

  /// 「按主区拆分」任务主体：双页滑动窗口（与整本识别同一设计），每页
  /// 按**全部** main_text 主区逐块级联拆分识别（未裁开的书一页可框左右
  /// 两块），[job.aiEnabled] 时跑 AI 整行裁决。结果严格按页序收账；页
  /// 失败不中断（计入失败页，可断点重试）。断点文件实时维护（启动写
  /// 全集、逐页收窄、完成清除），停止/失败/运行中退出应用都可续跑。
  Future<void> _processRegionSplit(_QueueJob job) async {
    final project = job.project;
    final total = job.pages.length;
    final projectId = project.id;
    _progress[projectId] = RecognitionProgress(
      projectId: projectId,
      kind: RecognitionProgress.kindRegionSplit,
      status: RecognitionStatus.recognizing,
      recognizedPages: 0,
      totalPages: total,
      queuePosition: 1,
      jobPages: job.pages,
      remainingPages: job.pages,
    );
    notifyListeners();

    // 断点实时维护①：启动即写本次全集，覆盖上一轮遗留的旧断点——否则
    // 运行中退出应用后，主区快设/首页还显示旧页数的「继续拆分剩余 N 页」。
    await _saveRegionSplitResume(
      project.projectDir,
      job.pages,
      job.aiEnabled,
    );

    PythonService.addAppLog(
      '[按主区拆分] 开始「${project.name}」：$total 页'
      '${job.aiEnabled ? ' · AI 整行裁决开启' : ''}',
    );

    var processed = 0;
    var changed = 0;
    final failedPages = <int>[];
    final pageTimes = <double>[];

    void updateProgress(List<int> remaining, {int? currentPage}) {
      final current = _progress[projectId];
      if (current == null) return;
      if (pageTimes.isNotEmpty) {
        final window = pageTimes.length > 5
            ? pageTimes.sublist(pageTimes.length - 5)
            : pageTimes;
        final avg = window.reduce((a, b) => a + b) / window.length;
        _progress[projectId] = current.copyWith(
          recognizedPages: processed,
          currentPage: currentPage ?? current.currentPage,
          remainingPages: List.unmodifiable(remaining),
          avgPageSeconds: avg,
          etaSeconds: (remaining.length * avg).round(),
        );
      } else {
        _progress[projectId] = current.copyWith(
          recognizedPages: processed,
          currentPage: currentPage ?? current.currentPage,
          remainingPages: List.unmodifiable(remaining),
        );
      }
      notifyListeners();
    }

    /// 单页拆分：识别 + 可选 AI + 落盘。返回是否成功（无正文主区视为
    /// 成功跳过）。409 忙等预算 30×2s：双页在途时后端识别门双槽被本
    /// 任务占满，409 只剩编辑器手动识别等外部占用（一页可达数十秒）。
    Future<bool> splitOne(int i) async {
      final pageId = project.pageIdAt(i);
      final existing = await ProjectStorage.loadAnnotation(
        project.projectDir,
        pageId,
      );
      final ann =
          existing ??
          PageAnnotation(pageId: pageId, imagePath: project.imageFiles[i]);
      final bodyRegions = ann.mainRegions
          .where((r) => RegionLabel.normalize(r.label) == RegionLabel.mainText)
          .toList();
      if (bodyRegions.isEmpty) {
        PythonService.addAppLog('[按主区拆分] 第 ${i + 1} 页无正文主区，跳过');
        return true;
      }
      // 防御：断点/目标页在此期间被整页「确认并保存」或「确认识别框」
      // 过（页面级确认成果），跳过不重拆——与主区快设的目标口径一致。
      if (ann.isFullyConfirmed || ann.boxesReviewed) {
        PythonService.addAppLog('[按主区拆分] 第 ${i + 1} 页已页面级确认，跳过');
        return true;
      }
      final pageSettings = project.settingsAt(i);
      // 一页多主区（未裁开的双页）：逐块级联。cascadeRegion 不改区域
      // 几何——每块只识别合并自己的行，不会把别的主区/区域洗掉。
      for (final region in bodyRegions) {
        var ok = false;
        for (var attempt = 0; attempt < 30 && !ok; attempt++) {
          if (_aborted.contains(projectId)) {
            throw StateError('已停止');
          }
          try {
            await BookRegionApply.cascadeRegion(
              ann: ann,
              imagePath: project.imageFiles[i],
              rect: region.rect,
              settings: pageSettings,
            );
            ok = true;
          } on RecognitionBusyException {
            await Future<void>.delayed(const Duration(seconds: 2));
          }
        }
        if (!ok) throw StateError('识别服务忙，未完成');
      }
      if (job.aiEnabled) {
        await applyAiLineAssistToLines(
          ann.lines,
          project.imageFiles[i],
          pageSettings,
          enabled: true,
          projectDir: project.projectDir,
          pageId: pageId,
        );
        ann.rebuildBlocks();
      }
      ann.draftSaved = true;
      // 机器写盘：抑制确认后自动导出调度（拆分只落草稿行，导出空转）。
      await ProjectStorage.saveAnnotation(
        project.projectDir,
        ann,
        machineWrite: true,
      );
      changed++;
      return true;
    }

    // 窗口宽度随 AI 开关自适应：无 AI 时 4 页在途（后端识别门已升为
    // 四槽，BACKEND_BUILD v108）——多页的 YOLO 版面检测与 Kraken 识别
    // 跨页重叠，GPU 实际并发由 Kraken daemon 池成员数自然约束；开 AI
    // 时保持 2 页——Ollama 行级并发（AI 并行度限流）已在填 GPU，窗口
    // 再大反而与 OCR 互相挤。
    final pipelineWindow = job.aiEnabled ? 2 : 4;
    final pending = List<int>.from(job.pages);
    final inFlight = <int, Future<bool>>{};
    while (true) {
      if (!_aborted.contains(projectId)) {
        while (inFlight.length < pipelineWindow && pending.isNotEmpty) {
          final i = pending.removeAt(0);
          inFlight[i] = splitOne(i);
          updateProgress(
            [...inFlight.keys, ...pending]..sort(),
            currentPage: i + 1,
          );
        }
      }
      if (inFlight.isEmpty) break;
      final earliest = inFlight.keys.reduce((a, b) => a < b ? a : b);
      final sw = Stopwatch()..start();
      bool ok;
      try {
        ok = await inFlight.remove(earliest)!;
      } catch (error) {
        ok = false;
        failedPages.add(earliest);
        PythonService.addAppLog(
          '[按主区拆分] 第 ${earliest + 1} 页拆分失败：$error',
          isError: true,
        );
      }
      sw.stop();
      processed++;
      if (ok) pageTimes.add(sw.elapsedMilliseconds / 1000);
      updateProgress([...inFlight.keys, ...pending]..sort());
      // 断点实时维护②：每收账一页就把断点收窄为「失败页∪在途∪未派发」
      // （失败页最后还会由收尾再写一次）。逐页串行 await，避免并发写盘
      // 乱序导致旧内容覆盖新内容。
      await _saveRegionSplitResume(
        project.projectDir,
        [...failedPages, ...inFlight.keys, ...pending]..sort(),
        job.aiEnabled,
      );
    }

    final aborted = _aborted.contains(projectId);
    final remaining = <int>[...failedPages, ...pending]..sort();
    if (aborted || remaining.isNotEmpty) {
      // 断点实时维护③（停止/失败收尾）：剩余页写断点，快照翻
      // paused/failed 供续跑。
      await _saveRegionSplitResume(
        project.projectDir,
        remaining,
        job.aiEnabled,
      );
      _progress[projectId] = RecognitionProgress(
        projectId: projectId,
        kind: RecognitionProgress.kindRegionSplit,
        status: aborted
            ? RecognitionProgress.paused
            : RecognitionProgress.failed,
        recognizedPages: processed - failedPages.length,
        totalPages: total,
        jobPages: job.pages,
        remainingPages: List.unmodifiable(remaining),
        error: failedPages.isEmpty
            ? null
            : '${failedPages.length} 页拆分失败，可在主区快设继续重试',
      );
      PythonService.addAppLog(
        '[按主区拆分] 「${project.name}」'
        '${aborted ? '已停止' : '结束（含失败页）'}：'
        '完成 ${processed - failedPages.length} / $total 页，'
        '剩余 ${remaining.length} 页已存断点',
      );
    } else {
      await _clearRegionSplitResume(project.projectDir);
      PythonService.addAppLog(
        '[按主区拆分] 「${project.name}」完成：$changed / $total 页已按主区拆出',
      );
      // 正常完成：快照由 _drain 清掉，回落书库卡片持久化状态。
    }
    notifyListeners();
  }

  /// 中止退出（用户停止 / 书被删除）前把状态落盘回 pending（重启后不
  /// 会卡在 recognizing）。用户停止且快照仍在（remove 删除流程会先清快
  /// 照）时留 paused 快照，首页显示"已暂停 · 点击继续识别"。
  /// 同时翻回 autoRecognize=false：用户主动停下的书，重启后不被
  /// resumePending 自动续跑——点「继续识别」（enqueue）会翻回 true。
  Future<void> _abortExit(Project project, int totalPages) async {
    project.recognitionStatus = RecognitionStatus.pending;
    project.autoRecognize = false;
    await _saveQuietly(project);
    if (_progress.containsKey(project.id)) {
      _progress[project.id] = RecognitionProgress(
        projectId: project.id,
        status: RecognitionProgress.paused,
        recognizedPages: project.recognizedPages,
        totalPages: totalPages,
      );
      notifyListeners();
    }
  }

  /// Recognize one page, waiting out backend-busy 409s and retrying real
  /// failures once. Returns null on success, the error otherwise.
  Future<Object?> _recognizePageWithRetry(Project project, int index) async {
    Object? failure;
    var attempts = 0;
    var busyWaits = 0;
    var unreachableWaits = 0;
    while (true) {
      if (_aborted.contains(project.id)) return null;
      try {
        await ensurePageAnnotation(project, index);
        return null;
      } on RecognitionBusyException catch (e) {
        failure = e;
        busyWaits++;
        if (busyWaits >= busyRetryLimit) return failure;
        await Future<void>.delayed(retryDelay);
      } on ClientException catch (e) {
        // 连接级失败＝后端不在（未就绪/崩溃重启/控制台窗口被关），与 409
        // 忙同级：长等待其恢复，而不是几秒判死整本书。超预算后给一句能
        // 指导行动的中文，替代裸的英文 SocketException。
        failure = e;
        unreachableWaits++;
        if (unreachableWaits >= unreachableRetryLimit) {
          return Exception(
            '后端服务不可达，已连续 $unreachableWaits 次连接失败'
            '（共等待 ${unreachableWaits * retryDelay.inSeconds} 秒）：'
            '请检查后端控制台窗口是否被关闭；重启应用会自动拉起后端，'
            '再点「重新识别」即从断点续跑',
          );
        }
        await Future<void>.delayed(retryDelay);
      } catch (e) {
        failure = e;
        attempts++;
        if (attempts >= pageRetryLimit) return failure;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  }

  Future<void> _saveQuietly(Project project) async {
    // 项目可能已在识别期间被删除；绝不为其重建目录（否则已删的书会复活）。
    if (!await Directory(project.projectDir).exists()) return;
    try {
      await ProjectStorage.save(project);
    } catch (_) {
      // A lost progress write is harmless — resume heals it from disk.
    }
  }
}
