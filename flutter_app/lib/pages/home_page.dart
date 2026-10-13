import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/models.dart';
import '../services/book_cache.dart';
import '../services/book_import.dart';
import '../services/char_stats.dart';
import '../services/python_service.dart';
import '../services/recognition_queue.dart';
import '../services/storage.dart';
import '../services/ollama_service.dart';
import '../widgets/floating_monitor_window.dart';
import 'ai_box_test_page.dart';
import 'char_stats_page.dart';
import 'dynasty_bench_page.dart';
import 'hub_page.dart';
import 'editor_page.dart';
import 'straighten_batch_page.dart';
import 'task_setup_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Project> _projects = [];
  String _rootDir = '';

  /// projectId -> 已在编辑器里「确认并保存」过的页数（reviewed 标记，
  /// 临时保存不计入），只为识别完成（可编辑）的书统计。
  final Map<String, int> _proofreadCounts = {};

  /// 每本书的正确识别率（char_stats 账本聚合），卡片展示用。
  final Map<String, BookAccuracy> _bookAccuracy = {};

  /// 上一次看到的队列成员集合，用来感知"有书完成/入队/移除"并重新读盘。
  Set<String> _lastQueuedIds = const {};

  /// _init 的代数：并发触发的重载只让最后一次的结果落地（见 _init）。
  int _initGeneration = 0;

  /// 导入续跑进行中的书（防重复点击）与逐页进度（卡片状态条实时显示
  /// "已转 N/M 页"）。仅本会话内有效——重启后书卡片仍显示"导入未完成"，
  /// 再点「继续导入」即可（后端跳过已转换页）。
  final Set<String> _importRunning = {};
  final Map<String, (int, int)> _importProgress = {};

  /// 识别服务进程树的资源占用（每 3 秒轮询一次）。
  ServiceStats? _stats;
  Timer? _statsTimer;

  @override
  void initState() {
    super.initState();
    RecognitionQueue.instance.addListener(_onQueueChanged);
    _init();
    unawaited(_fetchStats());
    _statsTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(_fetchStats()),
    );
  }

  @override
  void dispose() {
    RecognitionQueue.instance.removeListener(_onQueueChanged);
    _statsTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetchStats() async {
    final stats = await PythonService.fetchProcessStats();
    if (!mounted) return;
    // 首页被编辑器等页面覆盖时（路由不在栈顶）不刷新：识别期间的状态
    // 轮询继续累积会参与不可见 rebuild，回到首页时下个周期自然补上。
    if (ModalRoute.of(context)?.isCurrent != true) return;
    setState(() => _stats = stats);
  }

  Future<void> _init() async {
    // 代数守卫：删除项目等操作会触发并发重载，只允许最后一次 _init 的
    // 结果落地（先读盘的那次可能带着已删除的书，落盘会把"僵尸卡片"
    // 复活回列表）。
    final generation = ++_initGeneration;
    final docs = await getApplicationDocumentsDirectory();
    _rootDir = p.join(docs.path, 'GujiBT');
    final projects = await ProjectStorage.loadAll(_rootDir);
    projects.sort((a, b) => a.id.compareTo(b.id));
    // 导入中断留下的孤儿目录（有 sources 无 project.json）不进列表但
    // 永久占盘，书库加载时顺手清掉（1 小时内的目录不动，防误删进行中
    // 的导入）。
    unawaited(
      ProjectStorage.purgeOrphanProjectDirs(_rootDir).then((r) {
        if (r.removed > 0) {
          PythonService.addAppLog(
            '已清理 ${r.removed} 个导入中断留下的残留目录，'
            '释放 ${r.freedMb}MB',
          );
        }
      }),
    );
    // 一次性迁移：归位旧版删页逻辑造成的"文件名页号≠内容页号"错位
    // 标注（幂等，目录里有 .migrated_v1 标记即跳过）。
    for (final proj in projects) {
      await ProjectStorage.migrateMisalignedAnnotations(proj.projectDir);
    }
    if (!mounted || generation != _initGeneration) return;
    setState(() => _projects = projects);
    unawaited(_refreshProofreadCounts(projects));
    // 文字汇总账本的一次性存量回填：升级后把现有书籍全部已确认页
    // （reviewed）计入字频统计（.backfilled 标记防重跑，幂等）。
    unawaited(CharStatsService.backfillOnce(_rootDir, projects));
    // 不做启动自动续跑：识别只由用户手动开始/继续（上次中断的书在
    // 卡片上显示进度，点播放键即从断点续跑，已识别页自动跳过）。
  }

  /// 队列每识别完一页都会通知；只有队列成员集合变化（有书完成/入队/移除）
  /// 时才重新读盘，其余情况直接重建即可拿到最新进度。
  void _onQueueChanged() {
    if (!mounted) return;
    setState(() {});
    final ids = RecognitionQueue.instance.queuedIds;
    if (!setEquals(ids, _lastQueuedIds)) {
      _lastQueuedIds = ids;
      _init();
    }
  }

  Future<void> _refreshProofreadCounts(List<Project> projects) async {
    final counts = <String, int>{};
    // 迭代快照：本循环体内有 await（逐本书读标注计数，可达数秒），
    // 直接迭代 projects（与 _projects 同一列表对象）时，期间删除项目
    // 的 _projects.remove 会让 moveNext 抛 ConcurrentModificationError，
    // 且本函数是 unawaited 调用——异常无人接，桌面端直接退出。
    for (final proj in List<Project>.of(projects)) {
      if (!proj.recognitionCompleted) continue;
      // 页状态缓存计数：未变化的页只 stat 不解析 JSON（与编辑器页状态
      // 标记共用一份缓存），大书首页刷新不再整本解析。
      counts[proj.id] = (await PageStateCache.load(proj)).reviewedCount;
    }
    if (!mounted) return;
    setState(() {
      _proofreadCounts.clear();
      _proofreadCounts.addAll(counts);
    });
    unawaited(_refreshBookAccuracy(projects));
  }

  /// 从 char_stats 账本聚合每本书的正确识别率（识别产出后被确认的字
  /// 总数与其中被修改过的字数）。账目是小文件，逐本书扫描即可。
  Future<void> _refreshBookAccuracy(List<Project> projects) async {
    final dataRoot = projects.isEmpty
        ? null
        : p.dirname(projects.first.projectDir);
    if (dataRoot == null) return;
    final result = <String, BookAccuracy>{};
    for (final proj in List<Project>.of(projects)) {
      result[proj.id] = await CharStatsService.bookAccuracy(
        dataRoot,
        p.basename(proj.projectDir),
      );
    }
    if (!mounted) return;
    setState(() {
      _bookAccuracy.clear();
      _bookAccuracy.addAll(result);
    });
  }

  // ── 项目操作 ──

  Future<void> _newProject() async {
    if (!mounted || _rootDir.isEmpty) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TaskSetupPage(rootDir: _rootDir)),
    );
    _init();
  }

  /// 继续未完成的导入：从断点续转 PDF 页图（后端跳过已转换页），完成
  /// 后按创建时保存的 autoRecognize 决定是否入识别队列。摆正/拆分不在
  /// 续跑里自动跑，完成后可用卡片按钮手动进行。
  Future<void> _continueImport(Project project) async {
    if (_importRunning.contains(project.id)) return;
    setState(() => _importRunning.add(project.id));
    try {
      await BookImport.convertPdf(
        project,
        onProgress: (current, total) {
          if (!mounted) return;
          setState(() => _importProgress[project.id] = (current, total));
        },
      );
      if (!mounted) return;
      setState(() {
        _importRunning.remove(project.id);
        _importProgress.remove(project.id);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('「${project.name}」导入完成')),
      );
      if (project.autoRecognize) {
        RecognitionQueue.instance.enqueue(project);
      }
      unawaited(_init());
    } catch (e) {
      if (!mounted) return;
      setState(() => _importRunning.remove(project.id));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('继续导入失败：$e')),
      );
    }
  }

  void _openProject(Project project) {
    // 导入未完成的书没有页图：拦在门外，提示从卡片「继续导入」续跑。
    if (project.importPending) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '「${project.name}」还没导入完成（PDF 页图未转完），'
            '点卡片右侧的「继续导入」按钮续跑',
          ),
        ),
      );
      return;
    }
    // 只有正在整本识别的书拦在门外（标注正被后台逐页写盘，进出会互相
    // 踩）；未开始识别 / 识别失败的书都可以进去查看和编辑。
    final progress = RecognitionQueue.instance.progressFor(project.id);
    if (progress != null && progress.status != RecognitionProgress.failed) {
      final done = progress.recognizedPages;
      final total = progress.totalPages;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '「${project.name}」正在整本识别中（$done/$total 页），'
            '识别完成后才能进入编辑',
          ),
        ),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => EditorPage(project: project)),
    ).then((_) => _init());
  }

  Future<void> _deleteProject(Project project) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除项目'),
        content: Text('确定删除「${project.name}」？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    // 先从识别队列摘除（中止在途的页），再删目录，避免队列把目录写回来。
    RecognitionQueue.instance.remove(project.id);
    final dir = Directory(project.projectDir);
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      // 目录删不掉（文件被占用等）不该让应用带着未捕获异常退出：
      // 保留列表条目并提示，用户关闭占用程序后可重试删除。
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('删除失败（目录被占用？）：$e')));
      return;
    }
    setState(() => _projects.remove(project));
    PythonService.addAppLog('[删除项目] 已删除「${project.name}」（${project.id}）');
    // 队列摘除的通知已触发过一次并发 _init（那次可能赶在目录删除前读盘，
    // 会把这本书带回来）；这里删完后重读一次盘，靠 _init 的代数守卫让
    // 最终落地的是删除后的书库快照。
    unawaited(_init());
  }

  /// 卡片上的「批量摆正」入口：随时可进，处理进度自动持久化（断点续作）。
  /// 本书正在识别/排队时先确认暂停识别（摆正会改写页面文件，不能并行）。
  Future<void> _openStraightenBatch(Project proj) async {
    if (RecognitionQueue.instance.queuedIds.contains(proj.id)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('本书正在识别中'),
          content: const Text(
            '进入批量摆正会先暂停本书的识别（摆正要改写页面文件，不能与'
            '识别并行）。稍后可重新开始识别，已识别的页会自动跳过。继续？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('暂停识别并进入'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      // pause：当前页完成后停住并落"已暂停"快照（书状态回 pending），
      // 摆正完成后卡片上点播放键即可继续识别。
      RecognitionQueue.instance.pause(proj.id);
      PythonService.addAppLog('[批量摆正] 已暂停「${proj.name}」的识别（进入摆正，稍后可继续）');
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => StraightenBatchPage(project: proj)),
    );
    if (!mounted) return;
    await _init();
  }

  /// 卡片上的「开始整本识别」按钮（手动模式未开始的书 / 识别失败的书）：
  /// 无标注的页逐页识别，已有标注的页（人工校对过的页）自动跳过。
  Future<void> _startWholeBookRecognition(Project project) async {
    final ai = await OllamaSettings.load();
    if (!mounted) return;
    if (ai.enableLineAssist && !project.aiRecognitionAssist) {
      project.aiRecognitionAssist = true;
      await ProjectStorage.save(project);
      PythonService.addAppLog('[整本识别] 已将当前全局 AI 整行裁决设置写入项目');
    }
    if (!mounted) return;
    RecognitionQueue.instance.enqueue(project);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          project.aiRecognitionAssist
              ? '「${project.name}」已开始整本识别（含 AI 整行裁决）'
              : '「${project.name}」已开始整本识别（已有标注的页视为已识别，自动跳过）',
        ),
      ),
    );
  }

  /// 拆分任务暂停/失败后的「继续按主区拆分」：读断点文件，把剩余页
  /// 重新入队（已处理的页不在断点里，天然跳过）。
  Future<void> _resumeRegionSplit(Project project) async {
    final resume = await RecognitionQueue.loadRegionSplitResume(
      project.projectDir,
    );
    if (!mounted) return;
    if (resume == null || resume.pages.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('没有可继续的拆分断点（可能已全部完成）')));
      return;
    }
    RecognitionQueue.instance.enqueueRegionSplit(
      project,
      pages: resume.pages,
      aiEnabled: resume.aiEnabled,
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '「${project.name}」继续按主区拆分剩余 ${resume.pages.length} 页'
          '${resume.aiEnabled ? '（含 AI 整行裁决）' : ''}',
        ),
      ),
    );
  }

  /// 卡片上的「全书重新识别」按钮：整书重置回"新加入"状态再从头识别——
  /// 删除全部页标注（所有页未确认未保存、识别框重来、进编辑默认第一页），
  /// AI 整行裁决按设置照常参与；人工确认/校对成果会被覆盖，先强确认。
  /// 适合调整了摆正/识别参数后想整书重来的场景。
  Future<void> _reRecognizeWholeBook(Project project) async {
    final totalPages = project.imageFiles.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('全书重新识别？'),
        content: Text(
          '「${project.name}」共 $totalPages 页将整本重置为新书状态并从头识别：\n\n'
          '· 全部页的现有标注被删除——识别框、校对文字、确认状态全部重来'
          '（未确认未保存），不可恢复；\n'
          '· 识别队列从第一页跑完全部页（开启 AI 辅助校对则照常参与）；\n'
          '· 再次进入本书默认打开第一页。\n\n'
          '只想继续识别剩余页时，用「开始整本识别」（已有标注的页自动跳过）。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            style: FilledButton.styleFrom(foregroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('全书重新识别'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final ai = await OllamaSettings.load();
    if (!mounted) return;
    if (ai.enableLineAssist && !project.aiRecognitionAssist) {
      project.aiRecognitionAssist = true;
      await ProjectStorage.save(project);
    }
    await RecognitionQueue.instance.enqueueReRecognize(project);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '「${project.name}」已重置为新书状态，开始全书重新识别'
          '（全部 $totalPages 页）',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('字迹'),
        actions: [
          // 识别监控悬浮窗开关：常驻显示，任何页面可见，可拖动/折叠。
          ValueListenableBuilder<bool>(
            valueListenable: FloatingMonitorWindow.visible,
            builder: (context, monitorVisible, _) => IconButton(
              icon: Icon(
                monitorVisible
                    ? Icons.monitor_heart
                    : Icons.monitor_heart_outlined,
              ),
              tooltip: '识别监控悬浮窗（进度 / 队列 / 完成后关机 / 整机占用曲线）',
              onPressed: () =>
                  unawaited(FloatingMonitorWindow.setVisible(!monitorVisible)),
            ),
          ),
          // 功能入口（文字汇总 / 训练 / 设置 / 调试）：文字汇总统计所有
          // 校对确认过的书籍中每个字出现过的次数（删书不影响，页删除/
          // 重新识别撤账），其余各进一个按 tag 区分功能区的整合页。
          TextButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => CharStatsPage(
                  dataRoot: _rootDir,
                  bookNames: {for (final proj in _projects) proj.id: proj.name},
                ),
              ),
            ),
            icon: const Icon(Icons.text_fields, size: 18),
            label: const Text('文字汇总'),
          ),
          // 朝代基准测试：先秦→明清固定样张跑当前识别管线，出各时期
          // 识别率并与历史运行对比（回归测试口径）。
          TextButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DynastyBenchPage()),
            ),
            icon: const Icon(Icons.history_edu, size: 18),
            label: const Text('朝代基准'),
          ),
          // AI 画框测试（实验）：让视觉模型直接输出每字坐标框并原样叠加，
          // 不做几何精修、不写标注——测 VLM 裸定位水平。
          TextButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AiBoxTestPage()),
            ),
            icon: const Icon(Icons.draw, size: 18),
            label: const Text('AI 画框测试'),
          ),
          TextButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const TrainingHubPage()),
            ),
            icon: const Icon(Icons.model_training, size: 18),
            label: const Text('模型训练'),
          ),
          TextButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsHubPage()),
            ),
            icon: const Icon(Icons.settings_outlined, size: 18),
            label: const Text('设置'),
          ),
          TextButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DebugHubPage()),
            ),
            icon: const Icon(Icons.bug_report_outlined, size: 18),
            label: const Text('调试'),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '新建识别任务',
            onPressed: _newProject,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildStatsBar(),
          const _ShutdownBanner(),
          Expanded(child: _buildProjectList()),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newProject,
        icon: const Icon(Icons.add),
        label: const Text('新建任务'),
      ),
    );
  }

  // ── 资源占用 ──

  /// 识别服务（后端 + 常驻 Kraken 进程）的 CPU / 内存 / 显存占用。
  Widget _buildStatsBar() {
    final stats = _stats;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Theme.of(
            context,
          ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(
              Icons.monitor_heart_outlined,
              size: 15,
              color: Colors.grey.shade600,
            ),
            const SizedBox(width: 6),
            Text(
              '识别服务',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
            const SizedBox(width: 14),
            _statsItem(
              'CPU',
              stats == null ? null : '${stats.cpuPercent.toStringAsFixed(0)}%',
            ),
            const SizedBox(width: 14),
            _statsItem(
              '内存',
              stats == null ? null : _formatBytes(stats.memoryBytes),
            ),
            const SizedBox(width: 14),
            _statsItem(
              '显存',
              stats == null || stats.vramBytes == null
                  ? null
                  : _formatBytes(stats.vramBytes!),
            ),
            const SizedBox(width: 14),
            _statsItem(
              // Kraken 识别引擎的守护进程池（与设置里的 AI 并行度是两回事）
              '识别进程',
              stats == null || stats.workersTotal == null
                  ? null
                  : '${stats.workersReady ?? 0}/${stats.workersTotal} 路',
            ),
            const Spacer(),
            Text(
              stats == null
                  ? '暂未运行或统计不可用'
                  : RecognitionQueue.instance.isRunning
                  ? '识别中 · 已阻止系统自动待机'
                  : '每 3 秒刷新',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statsItem(String label, String? value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label ',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        Text(
          value ?? '—',
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  String _formatBytes(int bytes) {
    final mb = bytes / (1024 * 1024);
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
    return '${mb.round()} MB';
  }

  String _formatEta(int seconds) {
    if (seconds < 60) return '小于 1 分钟';
    final minutes = seconds ~/ 60;
    if (minutes < 60) return '约 $minutes 分钟';
    return '约 ${minutes ~/ 60} 小时 ${minutes % 60} 分钟';
  }

  String _etaClock(int seconds) {
    final t = DateTime.now().add(Duration(seconds: seconds));
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  // ── 项目列表 ──

  Widget _buildProjectList() {
    if (_projects.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('还没有项目', style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _newProject,
              icon: const Icon(Icons.add_photo_alternate),
              label: const Text('新建识别任务'),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _projects.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) => _buildProjectCard(_projects[i]),
    );
  }

  Widget _buildProjectCard(Project proj) {
    final layoutLabel = proj.settings.layoutMode == 'main_text_only'
        ? '只识别正文'
        : '识别全部';
    final progress = RecognitionQueue.instance.progressFor(proj.id);
    final totalPages = progress?.totalPages ?? proj.imageFiles.length;
    final importing = _importRunning.contains(proj.id);
    final importProgress = _importProgress[proj.id];

    String? statusText;
    String? etaText;
    Color? statusColor;
    double? barValue;
    // 导入未完成（PDF 页图未转完）：卡片状态与按钮整组切换为"继续导入"。
    if (proj.importPending) {
      final (cur, total) = importProgress ?? (0, 0);
      statusText = importing
          ? '正在转换 PDF 第 $cur/$total 页…（转图中途退出应用也没关系，'
                '重开后再点「继续导入」会从断点续跑）'
          : '导入未完成 · PDF 页图还没转完，点右侧「继续导入」'
                '（已转换的页自动跳过）';
      statusColor = importing ? Colors.blue.shade700 : Colors.orange.shade800;
      barValue = total > 0 ? cur / total : (importing ? null : 0);
    }
    // 拆分任务在队时卡片语义按拆分走（继续=续跑剩余页，不是整本识别）。
    final isSplitJob = progress?.kind == RecognitionProgress.kindRegionSplit;
    // 未完成且不在识别中的书（手动模式未开始 / 识别失败 / 用户停止）可
    // 在卡片上手动开始或继续整本识别（拆分任务不占用该按钮）。
    final canStart =
        !isSplitJob &&
        !proj.recognitionCompleted &&
        (progress == null ||
            progress.status == RecognitionProgress.failed ||
            progress.status == RecognitionProgress.paused);
    final isPaused = progress?.status == RecognitionProgress.paused;
    String? startTooltip;

    if (progress != null && progress.status == RecognitionProgress.paused) {
      statusText = isSplitJob
          ? '按主区拆分已停止 · 已处理 ${progress.recognizedPages}/$totalPages 页，'
                '点右侧按钮继续拆分（跳过已处理的页）'
          : '已暂停 · 已识别 ${progress.recognizedPages}/$totalPages 页，'
                '点右侧按钮继续识别（跳过已识别的页）';
      statusColor = Colors.orange.shade800;
      barValue = totalPages <= 0 ? 0 : progress.ratio;
      startTooltip = '继续识别（从上次停止处接着跑，已识别的页自动跳过）';
    } else if (progress != null &&
        progress.status == RecognitionProgress.stopping) {
      statusText =
          '正在停止 · 等当前页（第 ${progress.currentPage} 页）完成后停住，'
          '${isSplitJob ? '已处理' : '已识别'} ${progress.recognizedPages}/$totalPages 页保留';
      statusColor = Colors.orange.shade800;
      barValue = totalPages <= 0 ? 0 : progress.ratio;
    } else if (progress != null &&
        progress.status == RecognitionProgress.failed) {
      statusText = isSplitJob
          ? '按主区拆分有失败页 · 点右侧按钮继续重试剩余页'
          : '识别失败 · 点右侧按钮重新识别，或进入编辑查看已识别页';
      statusColor = Theme.of(context).colorScheme.error;
      barValue = totalPages <= 0 ? 1 : progress.ratio;
      startTooltip = '重新开始整本识别（跳过已有标注的页）';
    } else if (progress != null &&
        progress.status == RecognitionStatus.recognizing) {
      final done = progress.recognizedPages;
      final remaining = totalPages - done;
      final current = progress.currentPage > 0
          ? progress.currentPage
          : done + 1;
      statusText = isSplitJob
          ? '正在按主区拆分 第$current/共$totalPages 页 · '
                '剩余 $remaining 页（剩余 ${_percent(remaining, totalPages)}%）'
          : '正在识别 第$current/共$totalPages 页 · '
                '剩余 $remaining 页（剩余 ${_percent(remaining, totalPages)}%）';
      final eta = progress.etaSeconds;
      if (eta != null) {
        etaText = '预计还需 ${_formatEta(eta)} · 约 ${_etaClock(eta)} 完成';
      }
      barValue = progress.ratio;
    } else if (progress != null) {
      final position = progress.queuePosition;
      statusText = isSplitJob
          ? (position > 1 ? '排队等待按主区拆分（前面还有 ${position - 1} 个任务）' : '排队等待按主区拆分')
          : (position > 1 ? '排队等待识别（前面还有 ${position - 1} 本）' : '排队等待识别');
      barValue = progress.ratio;
    } else if (!proj.importPending && !proj.recognitionCompleted) {
      statusText = proj.autoRecognize ? '待识别' : '未开始识别 · 可先进入编辑整理，右侧按钮开始整本识别';
    } else if (proj.recognitionCompleted) {
      final proofread = _proofreadCounts[proj.id];
      if (proofread != null) {
        final remaining = totalPages - proofread;
        statusText =
            '已校对 $proofread/$totalPages 页 · '
            '剩余 $remaining 页（剩余 ${_percent(remaining, totalPages)}%）';
        statusColor = remaining == 0 ? Colors.green : null;
      }
    }

    return Card(
      child: ListTile(
        leading: Icon(
          proj.sourceFileType == 'pdf' ? Icons.picture_as_pdf : Icons.book,
        ),
        title: Text(proj.name),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$totalPages 页 · $layoutLabel',
              style: const TextStyle(fontSize: 12),
            ),
            if (progress != null && progress.error != null)
              Text(
                progress.error!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            if (statusText != null) ...[
              const SizedBox(height: 6),
              Text(
                statusText,
                style: TextStyle(fontSize: 12, color: statusColor),
              ),
              if (etaText != null) ...[
                const SizedBox(height: 2),
                Text(
                  etaText,
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
              ],
              const SizedBox(height: 6),
              if (barValue != null)
                LinearProgressIndicator(
                  value: barValue.clamp(0.0, 1.0),
                  minHeight: 4,
                ),
            ],
            // 正确识别率（账本聚合）：只统计"识别产出后被确认"的字，
            // 修正数 = 确认前文字与原始 OCR 不一致的字。有已确认页但
            // 一笔都没进统计（旧版确认的页没有基线）时给出灰字提示，
            // 而不是整行消失让用户以为功能不存在。
            if (_bookAccuracy[proj.id]
                case final acc?
                when acc.total > 0) ...[
              const SizedBox(height: 4),
              Tooltip(
                message: '口径：只统计识别产出后被「确认并保存」的字；'
                    '识别后文字被修改（人工/AI）再确认的计为修正。'
                    '人工新画字框与升级前已确认的旧页不计入。',
                child: Text(
                  '正确识别率 ${(acc.rate! * 100).toStringAsFixed(1)}% · '
                  '已确认识别 ${acc.total} 字，其中修正 ${acc.fixed} 字',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.teal.shade700,
                  ),
                ),
              ),
            ] else if ((_proofreadCounts[proj.id] ?? 0) > 0 &&
                (_bookAccuracy[proj.id]?.total ?? 0) == 0) ...[
              const SizedBox(height: 4),
              Tooltip(
                message: '统计需要每个字的"原始识别文字"基线（本版开始记录）。'
                    '升级前已确认的页没有这份记录：把页面重新识别并重新'
                    '「确认并保存」后，该书就开始累计正确识别率。',
                child: Text(
                  '正确识别率：暂无数据（升级前确认的页没有修改记录基线，'
                  '重新识别并确认后开始累计）',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                ),
              ),
            ],
            // 识别进行中/排队/失败待重试的卡片提供「完成后关机」开关：
            // 不放进新建任务页，识别过程中随时可以设置或取消。
            if (progress != null) ...[
              const SizedBox(height: 4),
              _buildShutdownToggle(),
            ],
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 导入未完成：只提供「继续导入」（断点续转页图）与删除——
            // 摆正/识别/重跑对没有页图的书都无意义。
            if (proj.importPending) ...[
              IconButton(
                icon: importing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_circle_fill),
                tooltip: importing
                    ? '正在转换 PDF 页图…'
                    : '继续导入：从断点续转 PDF 页图（已转换的页自动跳过）',
                onPressed: importing ? null : () => unawaited(_continueImport(proj)),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _deleteProject(proj),
              ),
            ] else ...[
            IconButton(
              icon: const Icon(Icons.crop_free),
              tooltip: '批量摆正（断点续作：智能裁切、去透印/去色/锐化、逐页确认）',
              onPressed: () => unawaited(_openStraightenBatch(proj)),
            ),
            // 拆分任务的暂停/失败：续跑按钮（读断点文件，只跑剩余页）。
            if (isSplitJob &&
                (progress!.status == RecognitionProgress.paused ||
                    progress.status == RecognitionProgress.failed))
              IconButton(
                icon: const Icon(Icons.play_circle_fill),
                tooltip: '继续按主区拆分（从断点续跑剩余页，已处理的页跳过）',
                onPressed: () => unawaited(_resumeRegionSplit(proj)),
              ),
            if (canStart)
              IconButton(
                icon: Icon(
                  isPaused
                      ? Icons.play_circle_fill
                      : progress?.status == RecognitionProgress.failed
                      ? Icons.replay
                      : Icons.play_arrow,
                ),
                tooltip: startTooltip ?? '开始整本识别（跳过已有标注的页）',
                onPressed: () => _startWholeBookRecognition(proj),
              ),
            // 识别中/排队中的书提供停止按钮：当前页完成后停住（排队书
            // 立即出队），已识别页保留为断点，之后可继续识别。正在停止
            // （stopping）时不再显示，等页边界退出即翻"已暂停"。
            if (progress != null &&
                (progress.status == RecognitionStatus.recognizing ||
                    progress.status == RecognitionStatus.pending))
              IconButton(
                icon: const Icon(Icons.stop_circle_outlined),
                tooltip: progress.status == RecognitionStatus.recognizing
                    ? '停止识别：当前页完成后停住，已识别的页保留，可随时继续'
                    : '取消排队（未开始识别）',
                onPressed: () {
                  RecognitionQueue.instance.pause(proj.id);
                  setState(() {});
                  if (progress.status == RecognitionStatus.recognizing) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('已请求停止：等当前页识别完成即停（一页可达分钟级），已识别的页全部保留'),
                      ),
                    );
                  }
                },
              ),
            // 空闲/已完成的书才提供全书重跑（识别中/排队/失败重试走播放键）。
            if (progress == null)
              IconButton(
                icon: const Icon(Icons.restart_alt),
                tooltip: '全书重新识别：全部页重跑并覆盖现有标注（含已确认页，需确认）',
                onPressed: () => unawaited(_reRecognizeWholeBook(proj)),
              ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _deleteProject(proj),
            ),
            ],
          ],
        ),
        onTap: () => _openProject(proj),
      ),
    );
  }

  // ── 识别完成后关机 ──

  /// 「识别完成后关机」开关行。关机是队列级选项，任意识别中的卡片上
  /// 设置都作用于整个队列；状态显示在所有相关卡片上保持一致。
  Widget _buildShutdownToggle() {
    final queue = RecognitionQueue.instance;
    final active = queue.shutdownWhenIdle || queue.shutdownPending;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _setShutdownAfterRecognition(!active),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 34,
            height: 20,
            child: Transform.scale(
              scale: 0.7,
              child: Switch(
                value: active,
                onChanged: _setShutdownAfterRecognition,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),
          const SizedBox(width: 2),
          const Text('识别完成后关机', style: TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  void _setShutdownAfterRecognition(bool value) {
    final queue = RecognitionQueue.instance;
    if (value) {
      queue.setShutdownWhenIdle(true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已设置：所有排队的书识别结束后自动关机，出现倒计时时可取消')),
      );
    } else {
      queue.setShutdownWhenIdle(false);
      if (queue.shutdownPending) {
        unawaited(queue.cancelScheduledShutdown());
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已取消自动关机')));
      }
    }
    setState(() {});
  }

  String _percent(int part, int total) {
    if (total <= 0) return '0';
    return '${(part / total * 100).round()}';
  }
}

/// 「识别完成后关机」倒计时横幅：识别队列跑完后出现，缓冲时间内可一键
/// 取消（shutdown /a）；关机命令执行失败时改显错误与「知道了」。
class _ShutdownBanner extends StatefulWidget {
  const _ShutdownBanner();

  @override
  State<_ShutdownBanner> createState() => _ShutdownBannerState();
}

class _ShutdownBannerState extends State<_ShutdownBanner> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    RecognitionQueue.instance.addListener(_onQueueChanged);
    if (RecognitionQueue.instance.shutdownPending) _startTicker();
  }

  void _onQueueChanged() {
    if (!mounted) return;
    setState(() {});
    if (RecognitionQueue.instance.shutdownPending) {
      _startTicker();
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  void _startTicker() {
    if (_ticker != null) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    RecognitionQueue.instance.removeListener(_onQueueChanged);
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final queue = RecognitionQueue.instance;
    final deadline = queue.shutdownAt;
    final error = queue.shutdownError;
    if (deadline == null && error == null) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    late final String message;
    late final Widget action;
    if (deadline != null) {
      final failedCount = queue.progress.values
          .where((p) => p.status == RecognitionProgress.failed)
          .length;
      final remaining = deadline.difference(DateTime.now()).inSeconds;
      message =
          '所有书籍识别已结束'
          '${failedCount > 0 ? '（$failedCount 本识别失败）' : ''}'
          '，电脑将在 ${remaining.clamp(0, 999)} 秒后关机';
      action = TextButton(
        onPressed: () =>
            unawaited(RecognitionQueue.instance.cancelScheduledShutdown()),
        child: const Text('取消关机'),
      );
    } else {
      message = '自动关机执行失败：$error';
      action = TextButton(
        onPressed: queue.clearShutdownError,
        child: const Text('知道了'),
      );
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            Icons.power_settings_new,
            size: 16,
            color: scheme.onSecondaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 13,
                color: scheme.onSecondaryContainer,
              ),
            ),
          ),
          action,
        ],
      ),
    );
  }
}
