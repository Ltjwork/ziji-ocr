import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import '../services/python_service.dart';
import '../services/storage.dart';
import 'training_curve_dialog.dart';

/// 模型训练页：从项目标注生成数据集并训练 5 类模型，训练后可启用反哺识别。
///
/// 训练数据全局共享：所有书籍的样本累计进同一份数据集，从任何书进入
/// 看到的都是同一份累计数据；提取来源只决定重新生成哪些书的样本。
///
/// 5 层：char_det 单字检测 / line_det 行检测 / paragraph_det 自然段检测 /
/// region_det 正文区检测 / char_cls 单字候选分类。
class TrainingPage extends StatefulWidget {
  /// 从首页进入时可为空：页内下拉选择要训练的书籍。
  final Project? project;

  /// 作为整合页（HubPage）的一个标签嵌入：不包自己的 Scaffold/AppBar，
  /// 标题由标签承担。
  final bool embedded;
  const TrainingPage({super.key, this.project, this.embedded = false});

  @override
  State<TrainingPage> createState() => _TrainingPageState();
}

class _TrainingPageState extends State<TrainingPage> {
  static const _layerOrder = [
    'char_det',
    'char_cls',
    'line_det',
    'paragraph_det',
    'region_det',
  ];

  static const _layerMeta = {
    'char_det': (
      '单字检测',
      '检测每个字的框。启用后整页识别优先使用该模型切字，'
          '行结构由字框自动聚类。',
    ),
    'char_cls': (
      '单字候选分类',
          '用你校正过的字文本训练"这个字可能是什么字"分类器，'
          '启用后候选字优先由它给出。',
    ),
    'line_det': (
      '行检测',
      '检测行框（区分正文行/小注行）。启用后行框由模型输出，'
          '字框按中心点归行。',
    ),
    'paragraph_det': (
      '自然段检测',
      '检测段落框。启用后整页识别直接返回模型分段，'
          '替代"短列断段"规则推断。',
    ),
    'region_det': ('正文区检测', '检测正文主区框。启用后整页识别直接返回模型主区。'),
  };

  Map<String, dynamic>? _stats; // /train/stats

  /// 已生成的数据集目录（layer -> 路径），供"打开数据集文件夹"使用。
  final Map<String, String> _datasetDirs = {};
  Map<String, Map<String, dynamic>> _models = {}; // /models
  List<Map<String, dynamic>> _tasks = [];
  List<Map<String, dynamic>> _krakenTasks = []; // /kraken/status

  /// Kraken 微调设置与数据就绪状态。
  int _krakenEpochs = 30;
  Map<String, dynamic>? _krakenData;

  /// 墨迹比对模型（siamese）训练：任务/数据就绪/已训模型。
  List<Map<String, dynamic>> _verifyTasks = [];
  Map<String, dynamic>? _verifyData;
  Map<String, dynamic>? _verifyModels;
  int _verifyEpochs = 60;
  Timer? _pollTimer;
  bool _refreshing = false;
  bool _preflightBusy = false;

  /// 训练设备：auto（有 GPU 自动用）| cuda | cpu。
  String _deviceChoice = 'auto';
  String? _error;

  /// 从首页进入且未带项目时：在页内选择训练数据来源。
  final List<({String dir, String name})> _sourceChoices = [];
  String? _chosenDir;
  String _rootDir = '';

  /// 实际使用的训练数据目录（单本书目录或库根目录=全部书籍汇总）。
  String get _projectDir {
    if (widget.project != null) return widget.project!.projectDir;
    if (_chosenDir != null) return _chosenDir!;
    return _rootDir;
  }

  String get _sourceName {
    if (widget.project != null) return widget.project!.name;
    for (final c in _sourceChoices) {
      if (c.dir == _projectDir) return c.name;
    }
    return _projectDir;
  }

  final Map<String, String> _baseChoice = {}; // layer -> yolov8n|s|m
  final Map<String, int> _epochsChoice = {}; // layer -> epochs

  /// layer -> 中间检查点保存周期（每 N 轮存一个 epoch{N}.pt，0=不存）。
  /// 默认每 10 轮：训练曲线弹窗里可以按曲线挑中间版本启用、判断过拟合。
  final Map<String, int> _savePeriodChoice = {};
  final Set<String> _busy = {};
  final Set<String> _exporting = {};
  bool _autoExporting = false;
  bool _autoExportDone = false;

  bool get _hasRunningTask =>
      _tasks.any((t) => t['status'] == 'starting' || t['status'] == 'training') ||
      _krakenTasks.any((t) => t['status'] == 'starting' || t['status'] == 'training') ||
      _verifyTasks.any((t) => t['status'] == 'starting' || t['status'] == 'training');

  @override
  void initState() {
    super.initState();
    if (widget.project != null) {
      _refresh().then((_) => unawaited(_autoExportPending()));
    } else {
      _loadProjects();
    }
  }

  /// 打开训练页自动增量导出：stats 带 pending（书库中已确认但未导出的
  /// 页数），>0 时后台导出新增并提示。每次进入页面只做一次。
  Future<void> _autoExportPending() async {
    if (_autoExporting || _autoExportDone) return;
    final projectDir = _projectDir;
    if (projectDir.isEmpty) return;
    final layers = _stats?['layers'] as Map<String, dynamic>?;
    if (layers == null) return;
    var pendingPages = 0;
    for (final value in layers.values) {
      final pending = value is Map ? value['pending'] as Map? : null;
      pendingPages += (pending?['pages'] as num?)?.toInt() ?? 0;
    }
    if (pendingPages <= 0) {
      _autoExportDone = true;
      return;
    }
    _autoExporting = true;
    try {
      final result = await PythonService.exportTrainDatasets(
        projectDir: projectDir,
      );
      if (!mounted) return;
      var exported = 0;
      final resultLayers = result['layers'] as Map?;
      if (resultLayers != null) {
        for (final value in resultLayers.values) {
          final layerReport = value as Map?;
          exported +=
              ((layerReport?['new_pages'] as num?)?.toInt() ?? 0) +
              ((layerReport?['updated_pages'] as num?)?.toInt() ?? 0);
        }
      }
      await _refresh();
      if (!mounted) return;
      if (exported > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已自动导入新增数据：$exported 页（增量，不影响旧数据）')),
        );
      }
    } catch (e) {
      PythonService.addAppLog('[训练] 自动增量导出失败：$e', isError: true);
    } finally {
      _autoExporting = false;
      _autoExportDone = true;
    }
  }

  Future<void> _loadProjects() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final root = p.join(docs.path, 'GujiBT');
      final projects = await ProjectStorage.loadAll(root);
      projects.sort((a, b) => a.id.compareTo(b.id));
      if (!mounted) return;
      setState(() {
        _rootDir = root;
        _sourceChoices
          ..clear()
          ..add((dir: root, name: '全部书籍（汇总）'));
        for (final pr in projects) {
          _sourceChoices.add((dir: pr.projectDir, name: pr.name));
        }
        _chosenDir ??=
            _sourceChoices.isNotEmpty ? _sourceChoices.first.dir : null;
      });
      if (_chosenDir != null) {
        unawaited(
          _refresh().then((_) => unawaited(_autoExportPending())),
        );
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final projectDir = _projectDir;
    if (projectDir.isEmpty) return;
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      final results = await Future.wait([
        PythonService.trainStats(projectDir),
        PythonService.listModels(),
        PythonService.trainStatus(),
        PythonService.krakenStatus().catchError((_) => <Map<String, dynamic>>[]),
        PythonService.krakenDataStatus(projectDir)
            .catchError((_) => null),
        PythonService.verifyTrainStatus()
            .catchError((_) => <String, dynamic>{}),
        PythonService.verifyTrainData(projectDir)
            .catchError((_) => <String, dynamic>{}),
      ]);
      final stats = results[0] as Map<String, dynamic>;
      final dirs = <String, String>{};
      for (final entry in ((stats['layers'] as Map?) ?? const {}).entries) {
        final value = entry.value as Map?;
        if (value?['dataset_dir_exists'] == true &&
            value?['dataset_dir'] is String) {
          dirs[entry.key.toString()] = value!['dataset_dir'] as String;
        }
      }
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _datasetDirs
          ..clear()
          ..addAll(dirs);
        _models = results[1] as Map<String, Map<String, dynamic>>;
        _tasks = results[2] as List<Map<String, dynamic>>;
        _krakenTasks = results[3] as List<Map<String, dynamic>>;
        _krakenData = results[4] as Map<String, dynamic>?;
        final verifyStatus = results[5] as Map<String, dynamic>?;
        _verifyTasks = (verifyStatus?['tasks'] as List?)
                ?.map((e) => Map<String, dynamic>.from(e as Map))
                .toList() ??
            <Map<String, dynamic>>[];
        _verifyModels = verifyStatus?['models'] as Map<String, dynamic>?;
        _verifyData = results[6] as Map<String, dynamic>?;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      // 刷新失败不清已有数据（成功才整体替换），只提示并等下轮轮询恢复；
      // 超时翻成中文——多发生在后端正忙于训练前检测/训练时。
      setState(() {
        _error = e is TimeoutException
            ? '训练统计请求超时：后端正忙于检查或训练，稍后自动重试'
            : e.toString();
      });
    } finally {
      if (mounted) setState(() => _refreshing = false);
      _schedulePoll();
    }
  }

  /// 用资源管理器打开本地文件夹（explorer 的退出码不可靠，忽略结果）。
  Future<void> _openFolder(String path) async {
    try {
      await Process.run('explorer.exe', [path]);
    } catch (_) {}
  }

  void _schedulePoll() {
    _pollTimer?.cancel();
    if (_hasRunningTask && mounted) {
      _pollTimer = Timer(const Duration(seconds: 2), _refresh);
    }
  }

  Map<String, dynamic>? _taskFor(String layer) {
    final matches = _tasks.where((t) => t['layer'] == layer).toList();
    if (matches.isEmpty) return null;
    matches.sort((a, b) {
      final ra = (a['started'] as num?)?.toDouble() ?? 0;
      final rb = (b['started'] as num?)?.toDouble() ?? 0;
      return rb.compareTo(ra);
    });
    return matches.first;
  }

  /// 该层当前生效的基础档位：用户手动选过用手选值；否则跟随系统算出的
  /// 下一个里程碑（某档训练过一轮后自动指向下一轮或更高档位）。
  String _effectiveBase(String layer) {
    final explicit = _baseChoice[layer];
    if (explicit != null) return explicit;
    final readiness =
        _stats?['layers']?[layer]?['readiness'] as Map<String, dynamic>?;
    final milestone = readiness?['next_milestone'] as Map<String, dynamic>?;
    final model = milestone?['model'] as String?;
    if (model != null) return model;
    return layer == 'char_cls' ? 'yolov8n' : 'yolov8s';
  }

  /// 生成数据集（增量导出，独立于训练按钮）。[force]=true 重写书库内
  /// 全部有效页；书库外的书（已删任务）的样本永不被动。
  Future<void> _exportDatasets(String layer, {bool force = false}) async {
    if (_busy.contains(layer) || _exporting.contains(layer)) return;
    if (_projectDir.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择要提取的书籍')),
      );
      return;
    }
    setState(() => _exporting.add(layer));
    try {
      final result = await PythonService.exportTrainDatasets(
        projectDir: _projectDir,
        layers: [layer],
        force: force,
      );
      final report = result['layers']?[layer] as Map<String, dynamic>?;
      final newPages = (report?['new_pages'] as num?)?.toInt() ?? 0;
      final updatedPages = (report?['updated_pages'] as num?)?.toInt() ?? 0;
      final manifest = report?['manifest'] as Map<String, dynamic>?;
      final instances = (manifest?['instances'] as num?)?.toInt() ?? 0;
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            force
                ? '已重导 $updatedPages 页；累计 $instances 个样本'
                : (newPages + updatedPages) > 0
                ? '新增 $newPages 页、更新 $updatedPages 页；累计 $instances 个样本'
                : '没有新增数据（已导出 $instances 个样本，全部最新）',
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('生成数据集失败：$e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting.remove(layer));
    }
  }

  /// 强制重导确认（会重写书库内全部有效页，样本文件被覆盖更新）。
  Future<void> _confirmForceExport(String layer) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('强制重导该层？'),
        content: const Text(
          '将按当前书库标注重写全部已导出页（同页覆盖、缺页保留）。'
          '已从书库删除的书不受影响。一般用「生成数据集」（只导新增）即可。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('重导'),
          ),
        ],
      ),
    );
    if (ok == true) unawaited(_exportDatasets(layer, force: true));
  }

  Future<void> _startTraining(String layer) async {
    if (_busy.contains(layer)) return;
    if (_projectDir.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择要训练的书籍')),
      );
      return;
    }
    final layerStats = _stats?['layers']?[layer] as Map<String, dynamic>?;
    final instances = (layerStats?['instances'] as num?)?.toInt() ?? 0;
    if (instances <= 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
        '$layer 还没有已导出的样本：请先在编辑器确认标注，再点「生成数据集」导出。'
        '${layer == 'region_det' ? '（版面区：主区快设/编辑器确认过的主区、页眉、页脚等框全部计入，无需整本识别完成）' : ''}',
      ),
            backgroundColor: Colors.orange.shade800,
          ),
        );
      }
      return;
    }
    final readiness = layerStats?['readiness'] as Map<String, dynamic>?;
    final requirements = readiness?['requirements'] as Map<String, dynamic>?;
    final modelKey = _effectiveBase(layer);
    final requirement = requirements?[modelKey] as Map<String, dynamic>?;
    if (requirement != null && requirement['ready'] != true) {
      final missing = (requirement['missing_instances'] as num?)?.toInt() ?? 0;
      final missingClasses =
          (requirement['missing_classes'] as num?)?.toInt() ?? 0;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '暂不能训练 $modelKey：还需保存确认 $missing 个样本'
              '${missingClasses > 0 ? '，补齐 $missingClasses 个字类' : ''}。',
            ),
            backgroundColor: Colors.orange.shade800,
          ),
        );
      }
      return;
    }
    setState(() => _busy.add(layer));
    try {
      // 训练直接用已导出的数据集（数据集目录缺失时后端自动增量导出）
      await PythonService.startTraining(
        projectDir: _projectDir,
        layer: layer,
        baseModel: '$modelKey${layer == 'char_cls' ? '-cls' : ''}.pt',
        epochs: _epochsChoice[layer] ?? 150,
        imgsz: layer == 'char_cls' ? 64 : 1280,
        device: _deviceChoice,
        savePeriod: _savePeriodChoice[layer] ?? 10,
      );
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('启动训练失败：$e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove(layer));
    }
  }

  Future<void> _stopTask(String taskId) async {
    try {
      await PythonService.stopTraining(taskId);
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('停止失败：$e')));
      }
    }
  }

  Future<void> _toggleModel(String layer, bool activate) async {
    setState(() => _busy.add(layer));
    try {
      if (activate) {
        await PythonService.activateModel(layer);
      } else {
        await PythonService.deactivateModel(layer);
      }
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${activate ? '启用' : '停用'}失败：$e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove(layer));
    }
  }

  /// 曲线弹窗的 run 下拉列表：进行中/最近任务优先，注册表历史 run 补后
  /// （按 run_dir 去重、新→旧）。
  List<({String dir, String label})> _curveRunChoices({
    Map<String, dynamic>? task,
    List<dynamic> registryRuns = const [],
  }) {
    final running = task != null &&
        (task['status'] == 'starting' || task['status'] == 'training');
    final runs = <({String dir, String label})>[];
    // 去重按小写路径：注册表实测混存 e:\ 与 E:\ 同一路径的条目
    final seen = <String>{};
    void add(String? dir, String prefix) {
      if (dir == null || dir.isEmpty) return;
      if (!seen.add(dir.toLowerCase())) return;
      runs.add((dir: dir, label: '$prefix${p.basename(dir)}'));
    }

    add(task?['run_dir'] as String?, running ? '当前任务 · ' : '最近任务 · ');
    final entries = registryRuns
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList()
      ..sort((a, b) => ((b['started'] as num?) ?? 0)
          .compareTo(((a['started'] as num?) ?? 0)));
    for (final r in entries) {
      add(r['run_dir'] as String?, '');
    }
    return runs;
  }

  /// 某层的训练曲线（YOLO detect/classify）：看指标/损失随轮数变化，
  /// 判过拟合，并把中间检查点直接启用为该层模型。
  Future<void> _showCurve(String layer) async {
    final task = _taskFor(layer);
    final runs = _curveRunChoices(
      task: task,
      registryRuns:
          (_models[layer]?['runs'] as List?) ?? const [],
    );
    if (runs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('还没有可看的训练 run（训练完成后即可看曲线）')),
      );
      return;
    }
    final running =
        task?['status'] == 'starting' || task?['status'] == 'training';
    await showDialog<void>(
      context: context,
      builder: (ctx) => TrainingCurveDialog(
        title: _layerMeta[layer]!.$1,
        runs: runs,
        autoRefresh: running,
        // 优先溯源路径（来自哪个 run 的哪个 .pt）：与检查点行同路径，
        // "当前启用"标记才亮；旧注册表无 active_source 时退回稳定副本。
        activePath: (_models[layer]?['active_source'] as String?) ??
            (_models[layer]?['active'] as String?),
        onActivate: (modelPath) async {
          await PythonService.activateModel(layer, modelPath: modelPath);
          await _refresh();
        },
      ),
    );
  }

  /// 墨迹比对模型（siamese）的训练曲线：val AUC / 损失随轮数变化。
  Future<void> _showVerifyCurve() async {
    final task = _verifyTask;
    final runs = _curveRunChoices(
      task: task,
      registryRuns: (_verifyModels?['runs'] as List?) ?? const [],
    );
    if (runs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('还没有训练产物（先完成一次训练）')),
      );
      return;
    }
    final running =
        task?['status'] == 'starting' || task?['status'] == 'training';
    await showDialog<void>(
      context: context,
      builder: (ctx) => TrainingCurveDialog(
        title: '墨迹比对模型',
        runs: runs,
        autoRefresh: running,
        onActivate: (modelPath) async {
          // siamese 按 run 目录激活（best.pt 所在目录）
          await PythonService.verifyTrainActivate(runDir: p.dirname(modelPath));
          await _refresh();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_projectDir.isEmpty) {
      const emptyHint = Center(
        child: Text(
          '还没有书籍项目：请先回到首页新建识别任务，再进入模型训练。',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
      );
      if (widget.embedded) return emptyHint;
      return Scaffold(
        appBar: AppBar(title: const Text('模型训练')),
        body: emptyHint,
      );
    }
    final body = Column(
      children: [
        _buildHeader(),
        if (_error != null)
          Container(
            width: double.infinity,
            color: Colors.red.shade100,
            padding: const EdgeInsets.all(8),
            child: Text('错误：$_error', style: const TextStyle(fontSize: 12)),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              for (final layer in _layerOrder)
                _LayerCard(
                  layer: layer,
                  meta: _layerMeta[layer]!,
                  stats: _stats?['layers']?[layer] as Map<String, dynamic>?,
                  model: _models[layer],
                  task: _taskFor(layer),
                  busy: _busy.contains(layer),
                      datasetDir: _datasetDirs[layer],
                      onOpenFolder: _openFolder,
                      baseChoice: _effectiveBase(layer),
                      epochsChoice: _epochsChoice[layer] ?? 150,
                      savePeriodChoice: _savePeriodChoice[layer] ?? 10,
                  onBaseChanged: (v) =>
                      setState(() => _baseChoice[layer] = v),
                  onEpochsChanged: (v) =>
                      setState(() => _epochsChoice[layer] = v),
                  onSavePeriodChanged: (v) =>
                      setState(() => _savePeriodChoice[layer] = v),
                  onTrain: () => _startTraining(layer),
                  onStop: () =>
                      _stopTask(_taskFor(layer)?['id'] as String? ?? ''),
                  onToggleModel: (activate) => _toggleModel(layer, activate),
                  onShowCurve: () => _showCurve(layer),
                  onExport: () => unawaited(_exportDatasets(layer)),
                  onForceExport: () => unawaited(_confirmForceExport(layer)),
                  exporting: _exporting.contains(layer),
                  pendingPages:
                      (((_stats?['layers']?[layer]
                              as Map<String, dynamic>?)?['pending']
                          as Map<String, dynamic>?)?['pages'] as num?)
                          ?.toInt() ??
                      0,
                ),
              _buildKrakenCard(),
              _buildVerifyCard(),
              const SizedBox(height: 12),
              _buildConsole(),
            ],
          ),
        ),
      ],
    );
    if (widget.embedded) return body;
    return Scaffold(appBar: AppBar(title: const Text('模型训练')), body: body);
  }

  Widget _buildHeader() {
    final pages = _stats?['pages'] ?? 0;
    final layers = (_stats?['layers'] as Map?)?.cast<String, dynamic>() ?? {};
    final confirmedSummary = layers.entries
        .map(
          (entry) => '${entry.key}:${(entry.value as Map?)?['instances'] ?? 0}',
        )
        .join('  ');
    return Container(
      width: double.infinity,
      color: Colors.blue.shade50,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.school, size: 18),
          const SizedBox(width: 8),
          if (widget.project == null) ...[
            const Text('提取来源：', style: TextStyle(fontSize: 12)),
            DropdownButton<String>(
              value: _chosenDir,
              items: [
                for (final choice in _sourceChoices)
                  DropdownMenuItem(
                    value: choice.dir,
                    child: Text(choice.name, style: const TextStyle(fontSize: 12)),
                  ),
              ],
              onChanged: (dir) {
                setState(() => _chosenDir = dir);
                unawaited(_refresh());
              },
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(
              '训练数据全局共享 · 全部书籍累计 $pages 页标注'
              '${widget.project == null ? '' : '（当前书：$_sourceName）'}\n'
              '累计已确认实例：$confirmedSummary\n'
              '训练占用 GPU（期间识别会变慢）；关闭应用会中断训练。'
              '标注越多 → 模型越准 → 识别越省人工。',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          IconButton(
            icon: _preflightBusy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.fact_check_outlined),
            tooltip: '训练前检测（环境 + 数据集完整性）',
            onPressed: (_preflightBusy || _projectDir.isEmpty) ? null : _runPreflight,
          ),
          Tooltip(
            message: '训练设备：自动 = 有 GPU 用 GPU；'
                '选 GPU/CPU 则强制指定（需环境支持）',
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'auto', label: Text('自动', style: TextStyle(fontSize: 11))),
                ButtonSegment(value: 'cuda', label: Text('GPU', style: TextStyle(fontSize: 11))),
                ButtonSegment(value: 'cpu', label: Text('CPU', style: TextStyle(fontSize: 11))),
              ],
              selected: {_deviceChoice},
              onSelectionChanged: (s) =>
                  setState(() => _deviceChoice = s.first),
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            icon: _refreshing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            onPressed: _refreshing ? null : _refresh,
          ),
        ],
      ),
    );
  }

  Map<String, dynamic>? get _krakenTask {
    final matches = _krakenTasks
        .where((t) =>
            t['layer'] == 'kraken_rec' ||
            (t['id'] as String? ?? '').startsWith('kraken_'))
        .toList();
    if (matches.isEmpty) return null;
    matches.sort((a, b) => ((b['started'] as num?) ?? 0).compareTo((a['started'] as num?) ?? 0));
    return matches.first;
  }

  Future<void> _startKraken() async {
    if (_projectDir.isEmpty) return;
    setState(() => _busy.add('kraken'));
    try {
      await PythonService.krakenTrainStart(
        projectDir: _projectDir,
        epochs: _krakenEpochs,
      );
      await _refresh();
    } catch (e) {
      if (mounted) {
        final msg = e.toString();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              msg.contains('已有')
                  ? '上一次 Kraken 微调尚未结束：点 Kraken 卡片上的「停止」清理后再试'
                  : '启动 Kraken 微调失败：$msg',
            ),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove('kraken'));
    }
  }

  Future<void> _stopKraken() async {
    final task = _krakenTask;
    if (task != null) {
      try {
        await PythonService.krakenStop(task['id'] as String);
      } catch (_) {}
    }
    await _refresh();
  }

  /// Kraken 识别模型微调卡片：整行识别引擎的文字来自 Kraken，
  /// 用已确认的"行图 + 行文字"微调官方模型，提升主识别文字准确率。
  Widget _buildKrakenCard() {
    final task = _krakenTask;
    final status = task?['status'] as String?;
    final running = status == 'starting' || status == 'training';
    final logTail = (task?['log_tail'] as List?)?.cast<String>() ?? const [];
    return Card(
      margin: const EdgeInsets.only(bottom: 10, top: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.translate, size: 18, color: Colors.indigo),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Kraken 识别模型微调（主文字引擎）',
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                  ),
                ),
                if (running)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              '用你确认过的"行图 + 行文字"微调 Kraken 官方识别模型，'
              '直接提升整行识别的文字准确率。数据越多提升越大。',
              style: TextStyle(fontSize: 11.5, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            if (_krakenData != null) ...[
              Row(
                children: [
                  Expanded(
                    child: LinearProgressIndicator(
                      value: ((_krakenData!['confirmed'] as num?) ?? 0) /
                              max(1, ((_krakenData!['required'] as num?) ?? 1))
                          .clamp(0.0, 1.0),
                      minHeight: 7,
                      color: _krakenData!['ready'] == true
                          ? Colors.green
                          : Colors.orange,
                      backgroundColor: Colors.blue.shade50,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '全部书籍确认行 ${_krakenData!['confirmed']}/${_krakenData!['required']} 行'
                    '（第 ${_krakenData!['generation']} 代微调）',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: _krakenData!['ready'] == true
                          ? Colors.green.shade700
                          : Colors.orange.shade800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                _krakenData!['ready'] == true
                    ? '训练数据已满足第 ${_krakenData!['generation']} 代需求，可微调'
                    : '达到第 ${_krakenData!['generation']} 代数据需求还需 '
                          '${_krakenData!['missing']} 行确认行（每多微调一代，需求自动 +100 行）',
                style: TextStyle(
                  fontSize: 11,
                  color: _krakenData!['ready'] == true
                      ? Colors.green.shade700
                      : Colors.orange.shade800,
                ),
              ),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                if (running) ...[
                  Text(
                    task?['status'] == 'training' ? '微调进行中' : '正在启动',
                    style: const TextStyle(fontSize: 12, color: Colors.blue),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: LinearProgressIndicator(
                      value: (task?['progress'] as num?)?.toDouble(),
                      minHeight: 6,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: () => _stopKraken(),
                    icon: const Icon(Icons.stop, size: 16),
                    label: const Text('停止'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red.shade700,
                    ),
                  ),
                ] else ...[
                  FilledButton.icon(
                    onPressed: _projectDir.isEmpty
                        ? null
                        : () => _startKraken(),
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: Text('导出数据并微调（$_krakenEpochs 轮）'),
                  ),
                  const SizedBox(width: 8),
                  PopupMenuButton<int>(
                    initialValue: _krakenEpochs,
                    onSelected: (v) => setState(() => _krakenEpochs = v),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 10, child: Text('10 轮')),
                      PopupMenuItem(value: 20, child: Text('20 轮')),
                      PopupMenuItem(value: 30, child: Text('30 轮')),
                      PopupMenuItem(value: 50, child: Text('50 轮')),
                      PopupMenuItem(value: 100, child: Text('100 轮')),
                    ],
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '$_krakenEpochs 轮',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                if (task?['run_dir'] != null)
                  TextButton.icon(
                    onPressed: () => _openFolder(task!['run_dir'] as String),
                    icon: const Icon(Icons.folder_open, size: 15),
                    label: const Text('打开模型目录', style: TextStyle(fontSize: 11.5)),
                  ),
                if (task != null ||
                    ((_verifyModels?['runs'] as List?)?.isNotEmpty ?? false))
                  TextButton.icon(
                    onPressed: _showVerifyCurve,
                    icon: const Icon(Icons.show_chart, size: 15),
                    label: const Text('训练曲线', style: TextStyle(fontSize: 11.5)),
                  ),
              ],
            ),
            if (logTail.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  (logTail.length > 6
                          ? logTail.sublist(logTail.length - 6)
                          : logTail)
                      .join(),
                  maxLines: 8,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF4DD080),
                    fontSize: 10,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 训练前检测：逐项检查训练环境（torch/ultralytics）和各层数据集
  /// 完整性（用 ultralytics 官方校验，即训练启动时的同一道检查），
  /// 结果弹窗展示，✗ 项给出具体原因——先看清能不能练，再点训练。
  Future<void> _runPreflight() async {
    setState(() => _preflightBusy = true);
    final projectDir = _projectDir;
    if (projectDir.isEmpty) return;
    final checks = await PythonService.trainPreflight(projectDir);
    if (!mounted) return;
    setState(() => _preflightBusy = false);
    if (checks == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('检测失败：识别服务未运行或请求超时')),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('训练前检测'),
        content: SizedBox(
          width: 560,
          height: 420,
          child: ListView.separated(
            itemCount: checks.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final check = checks[i];
              final ok = check['ok'] == true;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    ok ? Icons.check_circle : Icons.cancel,
                    size: 17,
                    color: ok ? Colors.green : Colors.red.shade700,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          check['name']?.toString() ?? '',
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          check['detail']?.toString() ?? '',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: ok
                                ? Colors.grey.shade700
                                : Colors.red.shade700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  // --- 墨迹比对模型（siamese）卡片：数据就绪 → 导出并训练 → 激活 -------

  Map<String, dynamic>? get _verifyTask {
    if (_verifyTasks.isEmpty) return null;
    final sorted = [..._verifyTasks]..sort(
        (a, b) => ((b['started'] as num?) ?? 0).compareTo((a['started'] as num?) ?? 0));
    return sorted.first;
  }

  Future<void> _startVerifyTrain() async {
    if (_projectDir.isEmpty) return;
    setState(() => _busy.add('verify_pair'));
    try {
      await PythonService.verifyTrainExport(_projectDir, force: true);
      await PythonService.verifyTrainStart(
        _projectDir,
        epochs: _verifyEpochs,
        device: _deviceChoice,
      );
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('启动墨迹比对模型训练失败：$e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove('verify_pair'));
    }
  }

  Future<void> _stopVerifyTrain() async {
    final task = _verifyTask;
    if (task == null) return;
    try {
      await PythonService.verifyTrainStop(task['id'] as String);
    } catch (_) {}
    await _refresh();
  }

  Future<void> _toggleVerifyModel(bool activate) async {
    try {
      if (activate) {
        await PythonService.verifyTrainActivate();
      } else {
        await PythonService.verifyTrainDeactivate();
      }
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(activate ? '没有可激活的模型（先完成一次训练）：$e' : '停用失败：$e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    }
  }

  Widget _buildVerifyCard() {
    final task = _verifyTask;
    final status = task?['status'] as String?;
    final running = status == 'starting' || status == 'training';
    final data = _verifyData;
    final models = _verifyModels;
    final active = models?['active_exists'] == true;
    final metrics = (models?['active_metrics'] as Map?) ?? const {};
    final ready = data?['ready'] == true;
    final positives = (data?['positives'] as num?) ?? 0;
    final minPos = (data?['min_positives'] as num?) ?? 1;
    final logTail = (task?['log_tail'] as List?)?.cast<String>() ?? const [];
    return Card(
      margin: const EdgeInsets.only(bottom: 10, top: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.compare, size: 18, color: Colors.teal),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '墨迹比对模型（校验第四层）',
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                  ),
                ),
                if (active)
                  Tooltip(
                    message: '已激活：墨迹校验自动带上比对分',
                    child: Icon(Icons.check_circle,
                        size: 16, color: Colors.green.shade700),
                  ),
                if (running)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              '用你确认过的字训练"墨迹↔字形"比对网络，学出刻本风格与楷体'
              '字模的差异哪些是书写性的、哪些是读错了——作为墨迹校验的'
              '第四层分数；也驱动全书同字模板库的相似度。',
              style: TextStyle(fontSize: 11.5, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            if (data != null) ...[
              Row(
                children: [
                  Expanded(
                    child: LinearProgressIndicator(
                      value: (positives / max(1, minPos)).clamp(0.0, 1.0),
                      minHeight: 7,
                      color: ready ? Colors.green : Colors.orange,
                      backgroundColor: Colors.blue.shade50,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '确认字 $positives/${minPos.round()}（硬负样本 '
                    '${(data['rejected_first'] as num?) ?? 0}）',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: ready ? Colors.green.shade700 : Colors.orange.shade800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            if (metrics.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '当前模型：验证集区分度(AUC) '
                  '${metrics['val_auc'] ?? '-'}',
                  style: TextStyle(fontSize: 11, color: Colors.green.shade700),
                ),
              ),
            Row(
              children: [
                if (running) ...[
                  Text(
                    status == 'training' ? '训练中' : '正在启动',
                    style: const TextStyle(fontSize: 12, color: Colors.blue),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: LinearProgressIndicator(
                      value: (task?['progress'] as num?)?.toDouble(),
                      minHeight: 6,
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: _stopVerifyTrain,
                    icon: const Icon(Icons.stop, size: 16),
                    label: const Text('停止'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red.shade700,
                    ),
                  ),
                ] else ...[
                  FilledButton.icon(
                    onPressed: (_projectDir.isEmpty || !ready)
                        ? null
                        : _startVerifyTrain,
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: Text('导出数据并训练（$_verifyEpochs 轮）'),
                  ),
                  const SizedBox(width: 8),
                  PopupMenuButton<int>(
                    tooltip: '训练轮数',
                    initialValue: _verifyEpochs,
                    onSelected: (v) => setState(() => _verifyEpochs = v),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 30, child: Text('30 轮')),
                      PopupMenuItem(value: 60, child: Text('60 轮')),
                      PopupMenuItem(value: 100, child: Text('100 轮')),
                    ],
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6),
                      child: Text('轮数', style: TextStyle(fontSize: 12)),
                    ),
                  ),
                  Switch(
                    value: active,
                    onChanged: models?['runs'] == null ||
                            (models!['runs'] as List).isEmpty
                        ? null
                        : _toggleVerifyModel,
                  ),
                ],
              ],
            ),
            if (!running && logTail.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  logTail.last,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10.5, color: Colors.grey),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildConsole() {
    final running = _tasks
        .where((t) => t['status'] == 'starting' || t['status'] == 'training')
        .toList();
    Map<String, dynamic>? task;
    if (running.isNotEmpty) {
      running.sort(
        (a, b) => ((b['started'] as num?) ?? 0).compareTo(
          (a['started'] as num?) ?? 0,
        ),
      );
      task = running.first;
    } else if (_tasks.isNotEmpty) {
      _tasks.sort(
        (a, b) => ((b['started'] as num?) ?? 0).compareTo(
          (a['started'] as num?) ?? 0,
        ),
      );
      task = _tasks.first;
    }
    final lines = (task?['log_tail'] as List?)?.cast<String>() ?? const [];
    final tail = lines.isEmpty ? '（暂无）' : lines.join();
    return Container(
      height: 180,
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  task == null
                      ? '训练日志'
                      : '训练日志 · ${task['layer']}（${task['status']}）',
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _consoleAction('复制', () async {
                await Clipboard.setData(ClipboardData(text: tail));
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已复制当前日志到剪贴板')),
                );
              }),
              _consoleAction('完整日志', _showFullLog),
            ],
          ),
          const SizedBox(height: 4),
          // SelectableText：日志可直接用鼠标选中复制
          Expanded(
            child: SingleChildScrollView(
              child: SelectableText(
                tail,
                style: const TextStyle(
                  color: Color(0xFF4DD080),
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _consoleAction(String label, VoidCallback onTap) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(4),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Text(
        label,
        style: const TextStyle(color: Colors.lightBlueAccent, fontSize: 11),
      ),
    ),
  );

  /// 拉取 run_dir/train_log.txt 的完整日志（status 接口只带最后 30 行），
  /// 弹窗展示：内容可选中复制，另有一键复制全部。
  Future<void> _showFullLog() async {
    final data = await PythonService.fetchTrainingLog();
    if (!mounted) return;
    if (data == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('获取完整日志失败（服务未运行或没有训练任务）')),
      );
      return;
    }
    final log = data['log'] ?? '';
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('训练日志 · ${data['layer']}'),
        content: SizedBox(
          width: 860,
          height: 560,
          child: Container(
            color: Colors.black87,
            padding: const EdgeInsets.all(8),
            child: SingleChildScrollView(
              child: SelectableText(
                log.isEmpty ? '（日志为空）' : log,
                style: const TextStyle(
                  color: Color(0xFF4DD080),
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: log));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已复制完整日志到剪贴板')),
              );
            },
            child: const Text('复制全部'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}

class _LayerCard extends StatelessWidget {
  final String layer;
  final (String, String) meta;
  final Map<String, dynamic>? stats;
  final Map<String, dynamic>? model;
  final Map<String, dynamic>? task;
  final bool busy;

  /// 已生成的数据集目录；null 表示还没生成过，"打开数据集文件夹"置灰。
  final String? datasetDir;
  final void Function(String path) onOpenFolder;
  final String baseChoice;
  final int epochsChoice;

  /// 中间检查点保存周期（每 N 轮存 epoch{N}.pt，0=不存）。
  final int savePeriodChoice;
  final ValueChanged<String> onBaseChanged;
  final ValueChanged<int> onEpochsChanged;
  final ValueChanged<int> onSavePeriodChanged;
  final VoidCallback onTrain;
  final VoidCallback onStop;
  final ValueChanged<bool> onToggleModel;

  /// 生成数据集（增量导出）与强制重导；与「开始训练」分离。
  final VoidCallback onExport;
  final VoidCallback onForceExport;
  final bool exporting;

  /// 书库中已确认但未导出的页数（生成按钮徽标）。
  final int pendingPages;

  /// 打开训练曲线弹窗（进行中任务或历史 run 都可看）。
  final VoidCallback onShowCurve;

  const _LayerCard({
    required this.layer,
    required this.meta,
    required this.stats,
    required this.model,
    required this.task,
    required this.busy,
    required this.datasetDir,
    required this.onOpenFolder,
    required this.baseChoice,
    required this.epochsChoice,
    required this.savePeriodChoice,
    required this.onBaseChanged,
    required this.onEpochsChanged,
    required this.onSavePeriodChanged,
    required this.onTrain,
    required this.onStop,
    required this.onToggleModel,
    required this.onShowCurve,
    required this.onExport,
    required this.onForceExport,
    this.exporting = false,
    this.pendingPages = 0,
  });

  bool get _isCls => layer == 'char_cls';

  String get _lastRunDir {
    final taskDir = task?['run_dir'] as String?;
    if (taskDir != null && taskDir.isNotEmpty) return taskDir;
    final runsList = (model?['runs'] as List?) ?? const [];
    for (final r in runsList.reversed) {
      final dir = (r as Map?)?['run_dir'] as String?;
      if (dir != null && dir.isNotEmpty) return dir;
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final (title, desc) = meta;
    final status = task?['status'] as String?;
    final running = status == 'starting' || status == 'training';
    final active =
        (model?['active'] as String?)?.isNotEmpty == true &&
        (model?['active_exists'] as bool? ?? false);
    final instances = stats?['instances'] as int? ?? 0;
    final classes = stats?['classes'] as int?;
    final runs = (model?['runs'] as List?)?.length ?? 0;
    final metrics = model?['metrics'] as Map<String, dynamic>?;
    final progress = (task?['progress'] as num?)?.toDouble() ?? 0.0;
    final readiness = stats?['readiness'] as Map<String, dynamic>?;
    final requirements = readiness?['requirements'] as Map<String, dynamic>?;
    final milestone = readiness?['next_milestone'] as Map<String, dynamic>?;
    final milestoneModel = milestone?['model'] as String?;
    final readinessModel = baseChoice;
    final selectedReq = requirements?[readinessModel] as Map<String, dynamic>?;
    final dataProgress = (selectedReq?['progress'] as num?)?.toDouble() ?? 0;
    final nextRound = (selectedReq?['rounds'] as num?)?.toInt() ?? 1;
    final targetInstances =
        (selectedReq?['target_instances'] as num?)?.toInt() ?? 0;
    final missingInstances =
        (selectedReq?['missing_instances'] as num?)?.toInt() ?? 0;
    final targetClasses =
        (selectedReq?['target_classes'] as num?)?.toInt() ?? 0;
    final missingClasses =
        (selectedReq?['missing_classes'] as num?)?.toInt() ?? 0;
    final dataReady = selectedReq?['ready'] == true;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _isCls ? Icons.spellcheck : Icons.crop_free,
                  size: 18,
                  color: active ? Colors.green : Colors.grey,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  active ? '已启用' : '未启用',
                  style: TextStyle(
                    fontSize: 12,
                    color: active ? Colors.green : Colors.grey,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              desc,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
            const SizedBox(height: 8),
            Text(
              classes != null
                  ? '累计实例 $instances · $classes 个字类'
                  : '累计实例 $instances${runs > 0 ? ' · 已训 $runs 次' : ''}',
              style: const TextStyle(fontSize: 12),
            ),
            if (selectedReq != null) ...[
              const SizedBox(height: 7),
              Row(
                children: [
                  Expanded(
                    child: LinearProgressIndicator(
                      value: dataProgress.clamp(0, 1),
                      minHeight: 7,
                      color: dataReady ? Colors.green : Colors.blue,
                      backgroundColor: Colors.blue.shade50,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${(dataProgress * 100).round()}%',
                    style: TextStyle(
                      fontSize: 11,
                      color: dataReady
                          ? Colors.green.shade700
                          : Colors.grey.shade700,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Builder(builder: (_) {
                final head = dataReady
                    ? (nextRound > 1
                          ? '已达到第 $nextRound 轮训练 $readinessModel 的建议数据量，可开始训练'
                          : '已达到 $readinessModel 模型建议数据量，可开始训练')
                    : (nextRound > 1
                          ? '第 $nextRound 轮训练 $readinessModel 还需 $missingInstances 个确认样本'
                          : '达到 $readinessModel 建议量还需 $missingInstances 个确认样本');
                final tail = ''
                    '${!dataReady && targetInstances > 0 ? '（目标 $targetInstances）' : ''}'
                    '${targetClasses > 0 && missingClasses > 0 ? '，还需 $missingClasses 个字类' : ''}';
                return Text(
                  '$head$tail',
                  style: TextStyle(
                    fontSize: 11,
                    color: dataReady
                        ? Colors.green.shade700
                        : Colors.orange.shade800,
                  ),
                );
              }),
              // 手选档位偏离系统里程碑时提示下一个建议目标
              if (!dataReady &&
                  milestoneModel != null &&
                  milestoneModel != readinessModel) ...[
                const SizedBox(height: 2),
                Text(
                  '下一个建议目标：$milestoneModel'
                  '${((requirements?[milestoneModel]?['rounds'] as num?)?.toInt() ?? 1) > 1 ? '（第 ${requirements?[milestoneModel]?['rounds']} 轮）' : ''}',
                  style: TextStyle(fontSize: 10.5, color: Colors.blue.shade700),
                ),
              ],
            ],
            if (metrics != null && metrics.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '上次指标：${metrics.entries.map((e) => '${e.key.split('/').last}=${e.value}').join('  ')}',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
            ],
            if (running) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: progress.clamp(0, 1)),
              const SizedBox(height: 4),
              Text(
                status == 'starting'
                    ? '正在启动训练（下载数据/初始化）…'
                    : '训练中 epoch ${(progress * (task?['epochs'] as int? ?? 100)).round()}/${task?['epochs']}',
                style: const TextStyle(fontSize: 11),
              ),
            ],
            if (status == 'failed') ...[
              const SizedBox(height: 6),
              Text(
                '上次训练失败，详见日志',
                style: TextStyle(fontSize: 11, color: Colors.red.shade700),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                if (!running)
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'yolov8n',
                        label: Text('n', style: TextStyle(fontSize: 11)),
                      ),
                      ButtonSegment(
                        value: 'yolov8s',
                        label: Text('s', style: TextStyle(fontSize: 11)),
                      ),
                      ButtonSegment(
                        value: 'yolov8m',
                        label: Text('m', style: TextStyle(fontSize: 11)),
                      ),
                      ButtonSegment(
                        value: 'yolov8l',
                        label: Text('l', style: TextStyle(fontSize: 11)),
                      ),
                    ],
                    selected: {baseChoice},
                    onSelectionChanged: running
                        ? null
                        : (s) => onBaseChanged(s.first),
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                if (!running) const SizedBox(width: 8),
                if (!running)
                  PopupMenuButton<int>(
                    initialValue: epochsChoice,
                    onSelected: running ? null : onEpochsChanged,
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 30, child: Text('30 epochs')),
                      PopupMenuItem(value: 50, child: Text('50 epochs')),
                      PopupMenuItem(value: 100, child: Text('100 epochs')),
                      PopupMenuItem(value: 150, child: Text('150 epochs')),
                      PopupMenuItem(value: 300, child: Text('300 epochs')),
                    ],
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '$epochsChoice epochs',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ),
                if (!running) const SizedBox(width: 6),
                // 中间存档：每 N 轮存一个检查点，训练后按曲线挑版本启用
                if (!running)
                  Tooltip(
                    message: '每 N 轮保存一次检查点（epoch{N}.pt），'
                        '训练后在「训练曲线」里按曲线挑一版启用',
                    child: PopupMenuButton<int>(
                      initialValue: savePeriodChoice,
                      onSelected: running ? null : onSavePeriodChanged,
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 0, child: Text('不存中间检查点')),
                        PopupMenuItem(value: 5, child: Text('每 5 轮存档')),
                        PopupMenuItem(value: 10, child: Text('每 10 轮存档')),
                        PopupMenuItem(value: 20, child: Text('每 20 轮存档')),
                        PopupMenuItem(value: 30, child: Text('每 30 轮存档')),
                      ],
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          savePeriodChoice > 0
                              ? '每$savePeriodChoice轮存档'
                              : '不存档',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ),
                  ),
                const Spacer(),
                if (running)
                  OutlinedButton.icon(
                    onPressed: busy ? null : onStop,
                    icon: const Icon(Icons.stop, size: 16),
                    label: const Text('停止'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red.shade700,
                    ),
                  )
                else ...[
                  OutlinedButton.icon(
                    onPressed: busy || exporting ? null : onExport,
                    icon: exporting
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download, size: 16),
                    label: Text(
                      pendingPages > 0
                          ? '生成数据集（$pendingPages 页待导）'
                          : '生成数据集',
                    ),
                  ),
                  Tooltip(
                    message: '强制重导：按当前书库标注重写全部已导出页',
                    child: InkWell(
                      onTap: busy || exporting ? null : onForceExport,
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Icon(
                          Icons.restart_alt,
                          size: 16,
                          color: (busy || exporting)
                              ? Colors.grey
                              : Colors.orange.shade800,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: busy ? null : onTrain,
                    icon: busy
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.play_arrow, size: 18),
                    label: const Text('开始训练'),
                  ),
                  const SizedBox(width: 8),
                  if (runs > 0)
                    active
                        ? OutlinedButton(
                            onPressed: busy ? null : () => onToggleModel(false),
                            child: const Text('停用'),
                          )
                        : FilledButton.tonal(
                            onPressed: busy ? null : () => onToggleModel(true),
                            child: const Text('启用'),
                          ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            // 文件夹快捷入口：数据集目录（生成过就有）、模型目录（训练成功后）
            Row(
              children: [
                TextButton.icon(
                  onPressed: datasetDir == null
                      ? null
                      : () => onOpenFolder(datasetDir!),
                  icon: const Icon(Icons.folder_open, size: 15),
                  label: const Text(
                    '打开数据集文件夹',
                    style: TextStyle(fontSize: 11),
                  ),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                  ),
                ),
                const SizedBox(width: 8),
                // 最近一次 run 的目录：任务还在（含 done/failed）用任务
                // run_dir，否则用注册表最新 run——历史 run 也能直接打开
                if (_lastRunDir.isNotEmpty)
                  TextButton.icon(
                    onPressed: () => onOpenFolder(_lastRunDir),
                    icon: const Icon(Icons.folder_special, size: 15),
                    label: const Text(
                      '打开模型目录',
                      style: TextStyle(fontSize: 11),
                    ),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                    ),
                  ),
                if (task != null || runs > 0) ...[
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: onShowCurve,
                    icon: const Icon(Icons.show_chart, size: 15),
                    label: const Text(
                      '训练曲线',
                      style: TextStyle(fontSize: 11),
                    ),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
