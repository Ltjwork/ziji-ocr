import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import '../services/python_service.dart';
import '../services/storage.dart';
import 'recog_eval_panel.dart';

/// 模型对比测试：同一页图片识别两次——左侧（模型 A）套用指定层级的
/// 模型，右侧为基线管线（不使用任何自训模型）或另一模型（模型 B，
/// 同层互比，比较两次训练/不同检查点的真实识别差异）。模型A/B 除选
/// 哪次训练（run）外，还可进一步选该 run 的第几轮检查点（best/last/
/// 第 N 轮，来自 /train/curve 的检查点清单）。支持「左右对比」
/// 与「滑动叠加（拖中间竖线）」两种查看方式；单字候选分类模式为候选
/// 命中率评测；识别消融模式在冻结评测集上跑 A/B/C 三档（裸模型整行 /
/// 切分+逐框 / 全链路），量出识别准确率里模型与链路代码各自的贡献。
class ModelComparePage extends StatefulWidget {
  /// 从首页进入时可为空：页内下拉选择要测试的书籍。
  final Project? project;

  /// 作为整合页（HubPage）标签嵌入时不包自己的 Scaffold。
  final bool embedded;
  const ModelComparePage({super.key, this.project, this.embedded = false});

  @override
  State<ModelComparePage> createState() => _ModelComparePageState();
}

class _CompareLayer {
  final String key;
  final String label;
  const _CompareLayer(this.key, this.label);
}

const _compareLayers = [
  _CompareLayer('char_det', '单字检测（切字框）'),
  _CompareLayer('char_cls', '单字候选分类（文字/候选）'),
  _CompareLayer('line_det', '行检测'),
  _CompareLayer('paragraph_det', '段落检测'),
  _CompareLayer('region_det', '正文区检测'),
  _CompareLayer('recog_eval', '识别消融（行文字 A/B/C）'),
];

/// 两侧识别结果的相似度统计。
class _SimilarityStats {
  final int modelChars;
  final int baselineChars;
  final int matched; // IoU >= 0.5 的匹配字框对数
  final double matchedRatio;
  final double avgIou;
  final double textSim;

  const _SimilarityStats({
    required this.modelChars,
    required this.baselineChars,
    required this.matched, // IoU >= 0.5 的匹配字框对数
    required this.matchedRatio,
    required this.avgIou,
    required this.textSim,
  });
}

/// 一次训练 run 的可选检查点（/train/curve）：检查点文件清单 + 逐轮
/// 主指标（轮数下拉项里显示"第 N 轮 · 指标值"）。
class _RunCheckpoints {
  final List<Map<String, dynamic>> items; // {name, epoch, path, size}
  final String? metricLabel; // 主指标展示名（如 mAP50-95）
  final Map<int, double> metricByEpoch; // epoch → 主指标值

  const _RunCheckpoints(this.items, this.metricLabel, this.metricByEpoch);
}

class _ModelComparePageState extends State<ModelComparePage> {
  /// curve kind → (主指标列名, 展示名)，与训练曲线弹窗同口径。
  static const _primaryMetric = <String, (String, String)>{
    'detect': ('metrics/mAP50-95(B)', 'mAP50-95'),
    'classify': ('metrics/accuracy_top1', 'top1'),
    'siamese': ('val_auc', 'AUC'),
  };

  final List<Project> _allProjects = [];
  Project? _chosenProject;

  Project? get _effectiveProject => widget.project ?? _chosenProject;

  late int _pageIndex = _initialPageIndex();

  int _initialPageIndex() {
    final project = _effectiveProject;
    if (project == null || project.imageFiles.isEmpty) return 0;
    return project.lastPageIndex.clamp(0, project.imageFiles.length - 1);
  }

  String _layer = 'char_det';
  String? _modelPath;

  /// 模型 B（对比对象）：'baseline' 与基线（不用自训模型）互比，
  /// 'model' 与同层另一模型互比。
  String _sideB = 'baseline';
  String? _modelPathB;
  Map<String, List<Map<String, dynamic>>> _runsByLayer = {};
  Map<String, String?> _activeByLayer = {};

  /// 模型A/B 选中的检查点路径（默认=所选 run 的 best.pt，也可选中间轮）。
  String? _ckptA;
  String? _ckptB;

  /// 各 run 的检查点清单（/train/curve 拉取一次后缓存，键为 run_dir）；
  /// 拉取失败缓存空清单——轮数下拉隐藏，测试仍用 run 的 best。
  final Map<String, _RunCheckpoints> _ckptsByRun = {};

  /// 对比方式：'side' 左右并排 | 'slider' 滑动叠加。
  String _mode = 'side';

  /// 滑动叠加模式中竖线的位置（占宽度比例 0.03~0.97）。
  double _divider = 0.5;

  bool _running = false;
  String? _phase;
  String? _error;
  ui.Image? _image;

  PageAnnotation? _withModel;
  PageAnnotation? _withoutModel;
  int _withMs = 0;
  int _withoutMs = 0;

  /// char_cls（单字候选分类）模式的评测结果：模型侧 / 基线侧。
  Map<String, dynamic>? _clsWith;
  Map<String, dynamic>? _clsWithout;

  /// 评测标准答案的来源说明（人工确认文字 / 机器识别文字）。
  String? _referenceSource;

  /// 识别消融评测（recog_eval）模式的状态：三档结果、冻结评测集摘要、
  /// 评测行数与是否重建评测集。
  Map<String, dynamic>? _evalResult;
  Map<String, dynamic>? _evalSetInfo;
  int _evalLimit = 100;
  bool _evalRebuild = false;

  /// 识别过程日志：从识别服务 stdout 中筛出切分/模型相关的关键行。
  final List<String> _procLogs = [];
  final ScrollController _logScroll = ScrollController();
  StreamSubscription<BackendLogEntry>? _logSub;
  static const _logKeywords = [
    '[segment]',
    '[diag:yolo]',
    '[custom-model]',
    '[model-test]',
    '[model-use]',
  ];

  @override
  void initState() {
    super.initState();
    _loadRuns();
    _loadEvalSetInfo();
    if (widget.project == null) {
      _loadProjects();
    }
    _logSub = PythonService.logs.listen((entry) {
      final text = entry.message;
      if (!_logKeywords.any(text.contains)) return;
      if (!mounted) return;
      setState(() {
        _procLogs.add('${entry.timeLabel} $text');
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_logScroll.hasClients) {
          _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
        }
      });
    });
  }

  @override
  void dispose() {
    _logSub?.cancel();
    _logScroll.dispose();
    super.dispose();
  }

  Future<void> _loadProjects() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final root = p.join(docs.path, 'GujiBT');
      final projects = await ProjectStorage.loadAll(root);
      projects.sort((a, b) => a.id.compareTo(b.id));
      if (!mounted) return;
      setState(() {
        _allProjects
          ..clear()
          ..addAll(projects);
        _chosenProject = projects.isNotEmpty ? projects.last : null;
        _pageIndex = _initialPageIndex();
      });
    } catch (_) {}
  }

  Future<void> _loadRuns() async {
    try {
      final models = await PythonService.listModels();
      if (!mounted) return;
      setState(() {
        _runsByLayer = models.map((layer, entry) {
          // 同一 run_dir 只留最后一条（注册表曾有 reconcile 占位 + 完成
          // 登记的双条，同 best 路径的重复项会让 DropdownButton 的
          // "value 唯一匹配"断言直接崩溃）；完成后端修复后通常单条，
          // 这里是对旧注册表数据的防崩兜底。
          final byDir = <String, Map<String, dynamic>>{};
          for (final r in (entry['runs'] as List?) ?? const []) {
            final run = Map<String, dynamic>.from(r as Map);
            if ((run['best'] as String?)?.isNotEmpty != true) continue;
            final dir = run['run_dir']?.toString() ?? '';
            byDir[dir.isEmpty ? run['best'].toString() : _normDir(dir)] = run;
          }
          return MapEntry(layer, byDir.values.toList());
        });
        _activeByLayer = models.map(
          (layer, entry) =>
              MapEntry(layer, (entry['active_source'] ?? entry['active'])
                  ?.toString()),
        );
        _modelPath = _latestRunPath(_layer);
        _modelPathB = _secondRunPath(_layer, _modelPath);
        _ckptA = _modelPath;
        _ckptB = _modelPathB;
      });
      _syncCkpts();
    } catch (_) {
      // 注册表读取失败不阻塞页面：模型下拉为空，仍可跑基线对比。
    }
  }

  String? _latestRunPath(String layer) {
    final runs = _runsByLayer[layer];
    if (runs == null || runs.isEmpty) return null;
    return runs.last['best'] as String?;
  }

  /// 模型 B 的默认选择：与模型 A 不同的最近一次 run（没有第二个则空）。
  String? _secondRunPath(String layer, String? modelA) {
    final runs = _runsByLayer[layer];
    if (runs == null) return null;
    for (final run in runs.reversed) {
      final best = run['best'] as String?;
      if (best != null && best != modelA) return best;
    }
    return null;
  }

  /// 面板标题里的短名：run 目录名 + 检查点（如 20260930_1530·第130轮；
  /// best 与旧展示一致不加后缀）。
  String _shortRunLabel(String? modelPath) {
    if (modelPath == null || modelPath.isEmpty) return '（未选择）';
    final run = p
        .basename(p.dirname(p.dirname(p.dirname(modelPath))))
        .replaceFirst(RegExp(r'^run_'), '');
    final name = p.basename(modelPath);
    final epoch = RegExp(r'^epoch(\d+)\.pt$').firstMatch(name);
    if (epoch != null) return '$run·第${epoch.group(1)}轮';
    if (name == 'last.pt') return '$run·last';
    return run;
  }

  /// 实际传给后端测试的模型路径（轮数选择优先，未选时为 run 的 best）。
  String? get _testPathA => _ckptA ?? _modelPath;
  String? get _testPathB => _ckptB ?? _modelPathB;

  /// 所选 run 的检查点清单（未拉取到前为空，轮数下拉随之隐藏）。
  List<Map<String, dynamic>> get _ckptItemsA =>
      _ckptsByRun[_runDirOf(_modelPath)]?.items ?? const [];
  List<Map<String, dynamic>> get _ckptItemsB =>
      _ckptsByRun[_runDirOf(_modelPathB)]?.items ?? const [];

  String? _runDirOf(String? bestPath) {
    if (bestPath == null) return null;
    for (final run in _runsByLayer[_layer] ?? const []) {
      if (run['best'] == bestPath) return run['run_dir']?.toString();
    }
    return null;
  }

  /// 目录名归一化（统一分隔符 + 小写）作去重键，兼容大小写/斜杠混写。
  static String _normDir(String dir) =>
      p.normalize(dir).replaceAll('/', '\\').toLowerCase();

  /// 拉取并缓存一次 run 的检查点清单与逐轮主指标（/train/curve）。
  Future<void> _ensureCkpts(String? runDir) async {
    if (runDir == null || runDir.isEmpty || _ckptsByRun.containsKey(runDir)) {
      return;
    }
    try {
      final data = await PythonService.trainCurve(runDir);
      if (!mounted) return;
      final kind = data['kind']?.toString() ?? 'unknown';
      final metric = _primaryMetric[kind];
      final metricByEpoch = <int, double>{};
      if (metric != null) {
        for (final row in (data['rows'] as List? ?? const []).whereType<Map>()) {
          final epoch = (row['epoch'] as num?)?.toInt();
          final value = row[metric.$1] as num?;
          if (epoch != null && value != null) {
            metricByEpoch[epoch] = value.toDouble();
          }
        }
      }
      final items = ((data['checkpoints'] as List?) ?? const [])
          .map((c) => Map<String, dynamic>.from(c as Map))
          .toList();
      setState(() {
        _ckptsByRun[runDir] = _RunCheckpoints(items, metric?.$2, metricByEpoch);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() =>
          _ckptsByRun[runDir] = const _RunCheckpoints([], null, {}));
    }
  }

  void _syncCkpts() {
    unawaited(_ensureCkpts(_runDirOf(_modelPath)));
    unawaited(_ensureCkpts(_runDirOf(_modelPathB)));
  }

  /// 轮数下拉项文案：第 N 轮 / best / last + 该轮主指标 + 大文件提示。
  String _ckptLabel(String runDir, Map<String, dynamic> c) {
    final epoch = (c['epoch'] as num?)?.toInt();
    final name = c['name']?.toString() ?? '';
    final buf = StringBuffer(
      epoch != null
          ? '第 $epoch 轮'
          : (name == 'best.pt' ? 'best（验证最优）' : 'last（最后一轮）'),
    );
    if (epoch != null) {
      final ck = _ckptsByRun[runDir];
      if (ck != null) {
        final value = ck.metricByEpoch[epoch];
        final label = ck.metricLabel;
        if (value != null && label != null) {
          buf.write(' · $label ${value.toStringAsFixed(4)}');
        }
      }
      // 中间轮检查点含优化器状态（数百 MB，加载慢），标注体积提醒。
      final sizeMb = ((c['size'] as num?) ?? 0) / 1024 / 1024;
      if (sizeMb >= 100) buf.write(' · ${sizeMb.toStringAsFixed(0)}MB');
    }
    return buf.toString();
  }

  bool get _useModelB => _sideB == 'model' && _layer != 'recog_eval';

  /// 右侧名称（相似度统计/面板标题/角标用）。
  String get _sideBName => _useModelB ? '模型B' : '基线';

  String _runLabel(String layer, String bestPath) {
    final dirName = p
        .basename(p.dirname(p.dirname(p.dirname(bestPath))))
        .replaceFirst(RegExp(r'^run_'), '');
    final runs = _runsByLayer[layer] ?? const [];
    final run = runs.firstWhere(
      (r) => r['best'] == bestPath,
      orElse: () => const {},
    );
    final epochs = run['epochs'];
    final active = _activeByLayer[layer] == bestPath;
    final metrics = run['metrics'] as Map<String, dynamic>?;
    final map50 = metrics?['metrics/mAP50(B)'];
    final buf = StringBuffer(dirName);
    if (epochs is int) buf.write(' · $epochs 轮');
    if (map50 is num) buf.write(' · mAP50 ${map50.toStringAsFixed(2)}');
    if (active) buf.write(' · 当前启用');
    return buf.toString();
  }

  Future<void> _run() async {
    if (_running) return;
    final project = _effectiveProject;
    if (project == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先在顶部选择要测试的书籍')),
      );
      return;
    }
    if (_layer == 'recog_eval') {
      await _runRecogEval();
      return;
    }
    if (_layer == 'char_cls') {
      await _runClsCompare();
      return;
    }
    setState(() {
      _running = true;
      _error = null;
      _withModel = null;
      _withoutModel = null;
      _phase = '正在载入页面图片…';
    });
    try {
      final bytes = await File(project.imageFiles[_pageIndex]).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      _image = frame.image;

      _setPhase('正在识别（$_layerLabel · 所选模型）…');
      final sw = Stopwatch()..start();
      final withModel = await PythonService.segmentWithSettings(
        imagePath: project.imageFiles[_pageIndex],
        pageId: project.pageIdAt(_pageIndex),
        settings: project.settings,
        testLayer: _layer,
        testModelPath: _testPathA,
      );
      _withMs = sw.elapsedMilliseconds;
      if (!mounted) return;
      setState(() => _withModel = withModel);

      if (_useModelB) {
        if (_modelPathB == null) {
          throw Exception('模型B 还没有选择——可在「模型B」里选与模型A相同的'
              ' run、再用轮数A/B 选不同轮互比，或切回「与基线对比」');
        }
        _setPhase('正在识别（$_layerLabel · 模型B ${_shortRunLabel(_testPathB)}）…');
        sw.reset();
        final modelB = await PythonService.segmentWithSettings(
          imagePath: project.imageFiles[_pageIndex],
          pageId: project.pageIdAt(_pageIndex),
          settings: project.settings,
          testLayer: _layer,
          testModelPath: _testPathB,
        );
        _withoutMs = sw.elapsedMilliseconds;
        if (!mounted) return;
        setState(() {
          _withoutModel = modelB;
          _phase = null;
        });
        return _finishRun();
      }
      _setPhase('正在识别（基线：不使用自训模型）…');
      sw.reset();
      final withoutModel = await PythonService.segmentWithSettings(
        imagePath: project.imageFiles[_pageIndex],
        pageId: project.pageIdAt(_pageIndex),
        settings: project.settings,
        useModels: false,
      );
      _withoutMs = sw.elapsedMilliseconds;
      if (!mounted) return;
      setState(() => _withoutModel = withoutModel);
      _finishRun();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _phase = null;
        });
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  void _finishRun() {
    if (!mounted) return;
    setState(() => _phase = null);
  }

  void _setPhase(String phase) {
    if (mounted) setState(() => _phase = phase);
  }

  /// 单字候选分类评测：优先用本页人工确认过的单字作标准答案；若本页
  /// 还没有确认过的单字，则自动先用识别管线（含启用的单字模型）切字
  /// 识别一遍，以识别出的文字为参考答案，再评测候选命中率。
  Future<void> _runClsCompare() async {
    final project = _effectiveProject;
    if (project == null) return;
    setState(() {
      _running = true;
      _error = null;
      _clsWith = null;
      _clsWithout = null;
      _referenceSource = null;
      _phase = '正在准备标准答案（检查本页已确认单字）…';
    });
    try {
      final pageId = project.pageIdAt(_pageIndex);
      final existing = await ProjectStorage.loadAnnotation(
        project.projectDir,
        pageId,
      );
      var refChars = <Map<String, dynamic>>[];
      var refSource = '人工确认的文字';
      if (existing != null) {
        for (final line in existing.lines) {
          if (line.status != AnnotationStatus.confirmed) continue;
          for (final c in line.chars) {
            if (c.status != AnnotationStatus.confirmed) continue;
            final t = c.text.trim();
            if (t.length == 1 && c.type != 'ignore') {
              refChars.add({
                'text': t,
                'x': c.x,
                'y': c.y,
                'w': c.w,
                'h': c.h,
              });
            }
          }
        }
      }
      if (refChars.isEmpty) {
        // 没有人工确认的单字：自动先用识别管线切字识别，
        // 以识别出的文字作为参考答案（结果中会注明来源）。
        _setPhase('本页没有人工确认的单字，正在自动识别生成本页单字…');
        final ann = await PythonService.segmentWithSettings(
          imagePath: project.imageFiles[_pageIndex],
          pageId: pageId,
          settings: project.settings,
        );
        for (final b in ann.blocks) {
          final t = b.text.trim();
          if (t.length == 1 && b.type != 'ignore') {
            refChars.add({
              'text': t,
              'x': b.x,
              'y': b.y,
              'w': b.w,
              'h': b.h,
            });
          }
        }
        refSource = '机器识别文字（本页无人工确认单字，仅供参考）';
      }
      // 超过 100 字时均匀抽样，控制评测时长
      if (refChars.length > 100) {
        final step = refChars.length / 100;
        refChars = [
          for (var i = 0; i < 100; i++) refChars[(i * step).floor()],
        ];
      }
      if (refChars.isEmpty) {
        throw Exception('自动识别没有得到可用的单字，无法评测');
      }
      if (!mounted) return;
      setState(() => _referenceSource = refSource);

      _setPhase('正在评测（使用所选模型）…');
      final withModel = await PythonService.evaluateCharCls(
        projectDir: project.projectDir,
        imagePath: project.imageFiles[_pageIndex],
        useModels: true,
        testModelPath: _testPathA,
        chars: refChars,
      );
      if (!mounted) return;
      setState(() => _clsWith = withModel);
      if (_useModelB) {
        if (_modelPathB == null) {
          throw Exception('模型B 还没有选择——可在「模型B」里选与模型A相同的'
              ' run、再用轮数A/B 选不同轮互比，或切回「与基线对比」');
        }
        _setPhase('正在评测（模型B ${_shortRunLabel(_testPathB)}）…');
        final modelB = await PythonService.evaluateCharCls(
          projectDir: project.projectDir,
          imagePath: project.imageFiles[_pageIndex],
          useModels: true,
          testModelPath: _testPathB,
          chars: refChars,
        );
        if (!mounted) return;
        setState(() {
          _clsWithout = modelB;
          _phase = null;
        });
        return;
      }
      _setPhase('正在评测（基线：不使用自训模型）…');
      final withoutModel = await PythonService.evaluateCharCls(
        projectDir: project.projectDir,
        imagePath: project.imageFiles[_pageIndex],
        useModels: false,
        chars: refChars,
      );
      if (!mounted) return;
      setState(() {
        _clsWithout = withoutModel;
        _phase = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '评测失败：$e（若提示接口不存在，请完全关闭应用后重新打开，'
              '让识别服务更新到当前版本）';
          _phase = null;
        });
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  String get _layerLabel =>
      _compareLayers.firstWhere((l) => l.key == _layer).label;

  /// 识别消融评测：书库「人工完全确认」的行冻结抽样后跑 A/B/C 三档
  /// （A 裸模型整行读法 / B 切分+逐框读法 / C 全链路）。Kraken 是全局
  /// 引擎，取数口径与训练一致——传入任一本书目录即汇总整库。
  Future<void> _runRecogEval() async {
    final project = _effectiveProject;
    if (project == null) return;
    setState(() {
      _running = true;
      _error = null;
      _evalResult = null;
      _phase = '正在准备冻结评测集 / 跑三档消融（行数 $_evalLimit）…';
    });
    try {
      final result = await PythonService.recognitionEval(
        projectDir: project.projectDir,
        limit: _evalLimit,
        rebuild: _evalRebuild,
      );
      if (!mounted) return;
      setState(() {
        _evalResult = result;
        _phase = null;
      });
      _loadEvalSetInfo();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '评测失败：$e（若提示接口不存在，请完全关闭应用后重新打开，'
              '让识别服务更新到当前版本）';
          _phase = null;
        });
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _loadEvalSetInfo() async {
    final info = await PythonService.recognitionEvalSet();
    if (!mounted) return;
    setState(() => _evalSetInfo = info);
  }

  _SimilarityStats? get _similarity {
    final a = _withModel;
    final b = _withoutModel;
    if (a == null || b == null) return null;

    Rect rectOf(CharBlock c) => Rect.fromLTWH(
      c.x.toDouble(),
      c.y.toDouble(),
      c.w.toDouble(),
      c.h.toDouble(),
    );
    final modelRects = a.blocks.map(rectOf).toList();
    final baseRects = b.blocks.map(rectOf).toList();

    // 贪心匹配：所有 IoU>0 的框对按 IoU 从高到低依次配对（一对只配一次）。
    final pairs = <(int, int, double)>[];
    for (var i = 0; i < modelRects.length; i++) {
      for (var j = 0; j < baseRects.length; j++) {
        final inter = modelRects[i].intersect(baseRects[j]);
        final interArea = max(0.0, inter.width) * max(0.0, inter.height);
        if (interArea <= 0) continue;
        final union =
            modelRects[i].width * modelRects[i].height +
            baseRects[j].width * baseRects[j].height -
            interArea;
        if (union > 0) pairs.add((i, j, interArea / union));
      }
    }
    pairs.sort((x, y) => y.$3.compareTo(x.$3));
    final usedA = <int>{}, usedB = <int>{};
    var matched = 0;
    var iouSum = 0.0;
    for (final (i, j, iou) in pairs) {
      if (usedA.contains(i) || usedB.contains(j)) continue;
      usedA.add(i);
      usedB.add(j);
      iouSum += iou;
      if (iou >= 0.5) matched++;
    }
    final matchedPairs = usedA.length;

    final textA = a.lines.map((l) => l.text).join();
    final textB = b.lines.map((l) => l.text).join();

    return _SimilarityStats(
      modelChars: modelRects.length,
      baselineChars: baseRects.length,
      matched: matched,
      matchedRatio: modelRects.isEmpty ? 0 : matched / modelRects.length,
      avgIou: matchedPairs == 0 ? 0 : iouSum / matchedPairs,
      textSim: _textSimilarity(textA, textB),
    );
  }

  String get _similarityText {
    final sim = _similarity;
    if (sim == null) return '';
    return '相似度统计 — 字框：模型A ${sim.modelChars} · $_sideBName ${sim.baselineChars}'
        ' · 匹配（IoU≥0.5）${sim.matched} 对'
        '（${(sim.matchedRatio * 100).toStringAsFixed(1)}%）'
        ' · 平均 IoU ${sim.avgIou.toStringAsFixed(3)}'
        ' · 文字相似度 ${(sim.textSim * 100).toStringAsFixed(1)}%';
  }

  @override
  Widget build(BuildContext context) {
    final project = _effectiveProject;
    final pageCount = project?.imageFiles.length ?? 0;
    final runs = _runsByLayer[_layer] ?? const [];
    final bestPaths = runs.map((r) => r['best'] as String).toList();
    final ckptRunDirA = _runDirOf(_modelPath) ?? '';
    final ckptRunDirB = _runDirOf(_modelPathB) ?? '';
    final both = _withModel != null && _withoutModel != null;
    final showImageCompare = _layer != 'char_cls' && _layer != 'recog_eval';
    final isEvalMode = _layer == 'recog_eval';
    final body = Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              runSpacing: 6,
              children: [
                const Text('测试书籍：', style: TextStyle(fontSize: 13)),
                DropdownButton<Project>(
                  value: _chosenProject,
                  items: [
                    for (final pr in _allProjects)
                      DropdownMenuItem(
                        value: pr,
                        child: Text(pr.name, style: const TextStyle(fontSize: 12)),
                      ),
                  ],
                  onChanged: _running
                      ? null
                      : (v) => setState(() {
                            _chosenProject = v;
                            _pageIndex = _initialPageIndex();
                          }),
                ),
                const SizedBox(width: 6),
                if (!isEvalMode) ...[
                  const Text('测试页面：', style: TextStyle(fontSize: 13)),
                  DropdownButton<int>(
                    value: _pageIndex,
                    items: [
                      for (var i = 0; i < pageCount; i++)
                        DropdownMenuItem(value: i, child: Text('第 ${i + 1} 页')),
                    ],
                    onChanged: _running
                        ? null
                        : (v) => setState(() => _pageIndex = v ?? 0),
                  ),
                  const SizedBox(width: 6),
                ],
                const Text('测试模式：', style: TextStyle(fontSize: 13)),
                DropdownButton<String>(
                  value: _layer,
                  items: [
                    for (final layer in _compareLayers)
                      DropdownMenuItem(value: layer.key, child: Text(layer.label)),
                  ],
                onChanged: _running
                    ? null
                    : (v) => setState(() {
                            _layer = v ?? 'char_det';
                            _modelPath = _latestRunPath(_layer);
                            _modelPathB = _secondRunPath(_layer, _modelPath);
                            _ckptA = _modelPath;
                            _ckptB = _modelPathB;
                            _syncCkpts();
                          }),
                ),
                const SizedBox(width: 6),
                if (!isEvalMode) ...[
                  const Text('模型A：', style: TextStyle(fontSize: 13)),
                  DropdownButton<String>(
                    value: (_modelPath != null && bestPaths.contains(_modelPath))
                        ? _modelPath
                        : null,
                    hint: const Text('（无已训练模型）', style: TextStyle(fontSize: 12)),
                    items: [
                      for (final best in bestPaths)
                        DropdownMenuItem(
                          value: best,
                          child: Text(
                            _runLabel(_layer, best),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                    ],
                    onChanged: _running
                        ? null
                        : (v) => setState(() {
                            _modelPath = v;
                            _ckptA = v;
                            if (_modelPathB == v) {
                              _modelPathB = _secondRunPath(_layer, v);
                              _ckptB = _modelPathB;
                            }
                            _syncCkpts();
                          }),
                  ),
                  if (_ckptItemsA.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    const Text('轮数A：', style: TextStyle(fontSize: 13)),
                    DropdownButton<String>(
                      value: _ckptItemsA.any((c) => c['path'] == _ckptA)
                          ? _ckptA
                          : null,
                      hint: const Text('best', style: TextStyle(fontSize: 12)),
                      items: [
                        for (final c in _ckptItemsA)
                          DropdownMenuItem(
                            value: c['path'] as String,
                            child: Text(
                              _ckptLabel(ckptRunDirA, c),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                      ],
                      onChanged: _running
                          ? null
                          : (v) {
                              if (v != null) setState(() => _ckptA = v);
                            },
                    ),
                  ],
                  const SizedBox(width: 6),
                  const Text('对比：', style: TextStyle(fontSize: 13)),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'baseline',
                        label: Text('与基线', style: TextStyle(fontSize: 11)),
                      ),
                      ButtonSegment(
                        value: 'model',
                        label: Text('与另一模型', style: TextStyle(fontSize: 11)),
                      ),
                    ],
                    selected: {_sideB},
                    onSelectionChanged: _running
                        ? null
                        : (sel) => setState(() => _sideB = sel.first),
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  if (_sideB == 'model') ...[
                    const SizedBox(width: 6),
                    const Text('模型B：', style: TextStyle(fontSize: 13)),
                    DropdownButton<String>(
                      value: (_modelPathB != null && bestPaths.contains(_modelPathB))
                          ? _modelPathB
                          : null,
                      hint: const Text('（可选与模型A相同的 run，换轮数互比）',
                          style: TextStyle(fontSize: 12)),
                      items: [
                        for (final best in bestPaths)
                          DropdownMenuItem(
                            value: best,
                            child: Text(
                              _runLabel(_layer, best),
                              style: TextStyle(
                                fontSize: 12,
                                color: best == _modelPath
                                    ? Colors.grey
                                    : null,
                              ),
                            ),
                          ),
                      ],
                      onChanged: _running
                          ? null
                          : (v) => setState(() {
                              _modelPathB = v;
                              _ckptB = v;
                              _syncCkpts();
                            }),
                    ),
                    if (_ckptItemsB.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      const Text('轮数B：', style: TextStyle(fontSize: 13)),
                      DropdownButton<String>(
                        value: _ckptItemsB.any((c) => c['path'] == _ckptB)
                            ? _ckptB
                            : null,
                        hint: const Text('best', style: TextStyle(fontSize: 12)),
                        items: [
                          for (final c in _ckptItemsB)
                            DropdownMenuItem(
                              value: c['path'] as String,
                              child: Text(
                                _ckptLabel(ckptRunDirB, c),
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                        ],
                        onChanged: _running
                            ? null
                            : (v) {
                                if (v != null) setState(() => _ckptB = v);
                              },
                      ),
                    ],
                    const SizedBox(width: 6),
                  ],
                ],
                FilledButton.icon(
                  onPressed: _running ? null : _run,
                  icon: _running
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow, size: 18),
                  label: const Text('开始对比'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Row(
              children: [
                if (showImageCompare) ...[
                  const Text('查看方式：', style: TextStyle(fontSize: 12)),
                  const SizedBox(width: 6),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'side',
                        icon: Icon(Icons.splitscreen, size: 15),
                        label: Text('左右对比', style: TextStyle(fontSize: 11)),
                      ),
                      ButtonSegment(
                        value: 'slider',
                        icon: Icon(Icons.swap_horiz, size: 15),
                        label: Text('滑动叠加', style: TextStyle(fontSize: 11)),
                      ),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (s) => setState(() => _mode = s.first),
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                if (isEvalMode) ...[
                  const Text('评测行数：', style: TextStyle(fontSize: 12)),
                  DropdownButton<int>(
                    value: _evalLimit,
                    items: [
                      for (final n in const [50, 100, 200, 300])
                        DropdownMenuItem(value: n, child: Text('$n 行')),
                    ],
                    onChanged: _running
                        ? null
                        : (v) => setState(() => _evalLimit = v ?? 100),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: '勾选后下次评测会重新从书库确认行均匀抽样并覆盖已冻结的'
                        '评测集（书库新增校对数据后想扩大评测范围时使用）；'
                        '不勾选则复用上次冻结的评测集，跨训练轮次可比',
                    child: InkWell(
                      onTap: _running
                          ? null
                          : () => setState(() => _evalRebuild = !_evalRebuild),
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Checkbox(
                              value: _evalRebuild,
                              onChanged: _running
                                  ? null
                                  : (v) =>
                                      setState(() => _evalRebuild = v ?? false),
                              visualDensity: VisualDensity.compact,
                            ),
                            const Text('重建评测集', style: TextStyle(fontSize: 12)),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Text(
                    _phase ??
                        _error ??
                        (_layer == 'recog_eval'
                            ? '三档消融：A 裸模型·整行读法 / B 切分+逐框读法 / C 全链路——'
                                'A−B = 切分+逐框喂法的贡献，B−C = 修正代码的贡献'
                            : _layer == 'char_cls'
                            ? '以本页单字文字为标准答案，统计候选命中率（模型 vs 基线）'
                            : _useModelB
                                ? '模型互比：绿框侧为模型A（${_shortRunLabel(_testPathA)}），'
                                      '蓝框侧为模型B（${_shortRunLabel(_testPathB)}）——同层两次训练/检查点的真实差异'
                                : '滑动叠加模式：按住鼠标左右拖动竖线，绿框侧为所选模型，蓝框侧为基线'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: _error != null
                          ? Theme.of(context).colorScheme.error
                          : Colors.grey.shade700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (both && showImageCompare)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.amber.shade50,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.amber.shade200),
              ),
              child: Text(
                _similarityText,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          if (both &&
              showImageCompare &&
              _similarity != null &&
              _similarity!.textSim >= 0.999)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.blue.shade200),
              ),
              child: Text(
                _useModelB
                    ? '两侧结果完全一致：两个模型在这一页没有得到不同的结果。'
                        '可能原因：① 两侧模型预测都未通过置信度阈值，识别回退到了同一条管线；'
                        '② 两个模型对该页的预测恰好相同；'
                        '③ 该页对模型来说过于简单。可换其他页面再试。'
                    : '两侧结果完全一致：说明所选模型在这一页没有产生变化。'
                        '可能原因：① 该层模型预测未通过置信度阈值，识别回退到了基线切分；'
                        '② 候选分类模型只影响候选排序，不改主文字；'
                        '③ 该页对模型来说过于简单。可换其他页面或其他模型再试。',
                style: const TextStyle(fontSize: 11.5),
              ),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: _layer == 'char_cls'
                ? _buildClsCompare()
                : _layer == 'recog_eval'
                ? RecogEvalPanel(
                    result: _evalResult,
                    evalSetInfo: _evalSetInfo,
                    error: _error,
                  )
                : _mode == 'slider'
                ? _buildSliderView()
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _ComparePanel(
                          title: '$_layerLabel · 模型A（${_shortRunLabel(_testPathA)}）',
                          color: Colors.green,
                          image: _image,
                          annotation: _withModel,
                          elapsedMs: _withMs,
                          levels: _shownBoxLevels(_layer),
                        ),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(
                        child: _ComparePanel(
                          title: _useModelB
                              ? '$_layerLabel · 模型B（${_shortRunLabel(_testPathB)}）'
                              : '基线（未使用自训模型）',
                          color: Colors.blue,
                          image: _image,
                          annotation: _withoutModel,
                          elapsedMs: _withoutMs,
                          levels: _shownBoxLevels(_layer),
                        ),
                      ),
                    ],
                  ),
          ),
          const Divider(height: 1),
          _buildProcLogPanel(),
        ],
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(title: const Text('模型对比测试')),
      body: body,
    );
  }

  /// 滑动叠加视图：同一张图，竖线左侧画所选模型的框、右侧画基线的框，
  /// 拖动竖线即可逐区域比对。
  Widget _buildSliderView() {
    final img = _image;
    if (img == null) {
      return const Center(
        child: Text('尚未识别', style: TextStyle(color: Colors.grey)),
      );
    }
    return LayoutBuilder(
      builder: (context, cons) {
        final ratio = img.width / img.height;
        var w = cons.maxWidth;
        var h = w / ratio;
        if (h > cons.maxHeight) {
          h = cons.maxHeight;
          w = h * ratio;
        }
        return Center(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => setState(
              () => _divider = (d.localPosition.dx / w).clamp(0.03, 0.97),
            ),
            onHorizontalDragUpdate: (d) => setState(
              () => _divider = (d.localPosition.dx / w).clamp(0.03, 0.97),
            ),
            child: SizedBox(
              width: w,
              height: h,
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: CustomPaint(
                  painter: _SliderComparePainter(
                    image: img,
                    withAnn: _withModel,
                    withoutAnn: _withoutModel,
                    fraction: _divider,
                    levels: _shownBoxLevels(_layer),
                    leftLabel: _useModelB
                        ? '模型A·${_shortRunLabel(_testPathA)}'
                        : '模型',
                    rightLabel: _useModelB
                        ? '模型B·${_shortRunLabel(_testPathB)}'
                        : '基线',
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 单字候选分类的命中率对比：以页面单字文字为标准答案，
  /// 对比「使用所选模型」与「基线（无自训模型）」的候选命中情况。
  Widget _buildClsCompare() {
    final withR = _clsWith;
    final withoutR = _clsWithout;
    if (withR == null && withoutR == null) {
      return Center(
        child: Text(
          _error ?? '点「开始对比」后，将以本页单字文字为标准答案，\n'
              '分别评测「模型A${_useModelB ? '' : '（使用自训模型）'}」和'
              '「${_useModelB ? '模型B（${_shortRunLabel(_testPathB)}）' : '基线（无自训模型）'}」的候选命中率。',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _error != null
                ? Theme.of(context).colorScheme.error
                : Colors.grey,
            fontSize: 12.5,
          ),
        ),
      );
    }
    String? metric(Map<String, dynamic>? r, String key) => r?[key]?.toString();

    String fmtPct(Map<String, dynamic>? r, String key) {
      final v = (r?[key] as num?)?.toDouble();
      return v == null ? '—' : '$v%';
    }

    String fmtRank(Map<String, dynamic>? r) {
      final v = (r?['avg_rank'] as num?)?.toDouble();
      return v == null ? '—' : v.toString();
    }

    Widget row(String label, String withV, String baseV, {bool better = true}) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            SizedBox(
              width: 150,
              child: Text(label, style: const TextStyle(fontSize: 12.5)),
            ),
            Expanded(
              child: Text(
                withV,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: better ? Colors.green.shade700 : null,
                ),
              ),
            ),
            Expanded(
              child: Text(
                baseV,
                style: TextStyle(fontSize: 12.5, color: Colors.grey.shade800),
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_referenceSource != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '标准答案来源：$_referenceSource',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
            ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.blue.shade200),
            ),
            child: Row(
              children: [
                Text(
                  '指标（以单字文字为标准答案）',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Text(
                  _useModelB
                      ? '模型A·${_shortRunLabel(_testPathA)}'
                      : '使用所选模型',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.green,
                  ),
                ),
                const SizedBox(width: 24),
                Text(
                  _useModelB
                      ? '模型B·${_shortRunLabel(_testPathB)}'
                      : '基线（无自训模型）',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          row('测试字数', metric(withR, 'total') ?? '—', metric(withoutR, 'total') ?? '—'),
          row('Top1 命中（排第一）', fmtPct(withR, 'top1_pct'), fmtPct(withoutR, 'top1_pct')),
          row('Top3 命中', fmtPct(withR, 'top3_pct'), fmtPct(withoutR, 'top3_pct')),
          row('Top5 命中', fmtPct(withR, 'top5_pct'), fmtPct(withoutR, 'top5_pct')),
          row('Top10 命中', fmtPct(withR, 'top10_pct'), fmtPct(withoutR, 'top10_pct')),
          row('未进前 10', metric(withR, 'not_in_top10') ?? '—', metric(withoutR, 'not_in_top10') ?? '—'),
          row('平均排名', fmtRank(withR), fmtRank(withoutR)),
          const SizedBox(height: 10),
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(6),
              ),
              child: _buildClsDetailList(),
            ),
          ),
        ],
      ),
    );
  }

  /// 逐字明细（前 60 个）：每个字在两侧候选中的排名。
  Widget _buildClsDetailList() {
    final details =
        (_clsWith?['details'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    final baseDetails =
        (_clsWithout?['details'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    String rankOf(List<Map<String, dynamic>> rows, int index) {
      for (final d in rows) {
        if ((d['index'] as int?) == index) {
          final rank = d['rank'] as int?;
          return rank == null ? '未进前10' : '第 ${rank + 1} 位';
        }
      }
      return '—';
    }

    return ListView.builder(
      itemCount: min(details.length, 60),
      itemBuilder: (_, i) {
        final d = details[i];
        final correct = d['rank'] == 0;
        return ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          leading: Text(
            d['text']?.toString() ?? '?',
            style: const TextStyle(fontSize: 18),
          ),
          title: Text(
            '模型A排名：${rankOf(details, i)}'
            '　·　$_sideBName排名：${rankOf(baseDetails, i)}',
            style: const TextStyle(fontSize: 11.5),
          ),
          subtitle: Text(
            '${_useModelB ? '模型A' : '模型'}候选前3：${((d['candidates'] as List?) ?? const []).join(' ')}',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
          ),
          trailing: Icon(
            correct ? Icons.check : Icons.close,
            size: 16,
            color: correct ? Colors.green : Colors.red.shade400,
          ),
        );
      },
    );
  }

  /// 识别过程日志面板：实时显示后端切分/模型加载的关键日志行，
  /// 例如 "[model-use] char_det: 使用自训模型 ..."、
  /// "[segment] engine selected: yolo-char"，可直接据此确认模型是否被使用。
  Widget _buildProcLogPanel() {
    return Container(
      height: 150,
      color: Colors.black87,
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '识别过程日志（关键行）',
                  style: TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ),
              InkWell(
                onTap: () async {
                  if (_procLogs.isEmpty) return;
                  await Clipboard.setData(
                    ClipboardData(text: _procLogs.join('\n')),
                  );
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已复制识别过程日志')),
                  );
                },
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: Text(
                    '复制',
                    style: TextStyle(color: Colors.lightBlueAccent, fontSize: 11),
                  ),
                ),
              ),
              InkWell(
                onTap: () => setState(_procLogs.clear),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: Text(
                    '清空',
                    style: TextStyle(color: Colors.lightBlueAccent, fontSize: 11),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: _procLogs.isEmpty
                ? const Text(
                    '（暂无日志，点「开始对比」后显示识别过程）',
                    style: TextStyle(color: Colors.white38, fontSize: 11),
                  )
                : SingleChildScrollView(
                    controller: _logScroll,
                    child: SelectableText(
                      _procLogs.join('\n'),
                      style: const TextStyle(
                        color: Color(0xFF4DD080),
                        fontSize: 10.5,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// 对比测试画布只画被测层的框：五个层级的框全叠在一起会淹没真正要比
/// 的差异（如正文区检测对比时，行/字框把区域框的差异盖住了）。layer
/// 为空/未知时全画兜底。
Set<String> _shownBoxLevels(String? layer) {
  switch (layer) {
    case 'region_det':
      return const {'region'};
    case 'paragraph_det':
      return const {'paragraph'};
    case 'line_det':
      return const {'line'};
    case 'char_det':
      return const {'char'};
    default:
      return const {'region', 'paragraph', 'line', 'char'};
  }
}

/// 左右对比模式的面板：页面图上叠加正文区/段落/行/字框与统计。
class _ComparePanel extends StatelessWidget {
  final String title;
  final Color color;
  final ui.Image? image;
  final PageAnnotation? annotation;
  final int elapsedMs;

  /// 画哪些层级的框（按被测层过滤，见 [_shownBoxLevels]）。
  final Set<String> levels;

  const _ComparePanel({
    required this.title,
    required this.color,
    required this.image,
    required this.annotation,
    required this.elapsedMs,
    required this.levels,
  });

  @override
  Widget build(BuildContext context) {
    final img = image;
    final ann = annotation;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(width: 10, height: 10, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (ann != null)
            Text(
              '字框 ${ann.blocks.length} · 行 ${ann.lines.length}'
              ' · 段 ${ann.paragraphs.length} · 正文区 ${ann.mainRegions.length}'
              ' · 耗时 ${(elapsedMs / 1000).toStringAsFixed(1)}s',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
            ),
          const SizedBox(height: 6),
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(6),
              ),
              child: img == null
                  ? const Center(
                      child: Text('尚未识别', style: TextStyle(color: Colors.grey)),
                    )
                  : InteractiveViewer(
                      maxScale: 6,
                      child: AspectRatio(
                        aspectRatio: img.width / img.height,
                        child: CustomPaint(
                          painter: _CompareBoxesPainter(
                            image: img,
                            annotation: ann,
                            charColor: color,
                            levels: levels,
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CompareBoxesPainter extends CustomPainter {
  final ui.Image image;
  final PageAnnotation? annotation;
  final Color charColor;

  /// 画哪些层级的框（按被测层过滤，见 [_shownBoxLevels]）。
  final Set<String> levels;

  _CompareBoxesPainter({
    required this.image,
    required this.annotation,
    required this.charColor,
    required this.levels,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / image.width;
    final scaleY = size.height / image.height;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.low,
    );
    final ann = annotation;
    if (ann == null) return;

    void drawRects(List<Rect> rects, Color color, double width) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..color = color;
      for (final r in rects) {
        canvas.drawRect(
          Rect.fromLTWH(
            r.left * scaleX,
            r.top * scaleY,
            r.width * scaleX,
            r.height * scaleY,
          ),
          paint,
        );
      }
    }

    if (levels.contains('region')) {
      drawRects(ann.mainRegions.map((r) => Rect.fromLTWH(r.x.toDouble(), r.y.toDouble(), r.w.toDouble(), r.h.toDouble())).toList(), Colors.deepPurple, 2);
    }
    if (levels.contains('paragraph')) {
      drawRects(ann.paragraphs.map((pp) => Rect.fromLTWH(pp.x.toDouble(), pp.y.toDouble(), pp.w.toDouble(), pp.h.toDouble())).toList(), Colors.purple, 1.5);
    }
    if (levels.contains('line')) {
      drawRects(ann.lines.map((l) => Rect.fromLTWH(l.x.toDouble(), l.y.toDouble(), l.w.toDouble(), l.h.toDouble())).toList(), Colors.orange, 1.5);
    }
    if (levels.contains('char')) {
      drawRects(ann.blocks.map((b) => Rect.fromLTWH(b.x.toDouble(), b.y.toDouble(), b.w.toDouble(), b.h.toDouble())).toList(), charColor, 1);
    }
  }

  @override
  bool shouldRepaint(covariant _CompareBoxesPainter old) =>
      old.image != image ||
      old.annotation != annotation ||
      old.charColor != charColor ||
      old.levels.length != levels.length ||
      !old.levels.containsAll(levels);
}

double _textSimilarity(String a, String b) {
  if (a.isEmpty && b.isEmpty) return 1;
  if (a.isEmpty || b.isEmpty) return 0;
  const cap = 4000;
  final s = a.length > cap ? a.substring(0, cap) : a;
  final t = b.length > cap ? b.substring(0, cap) : b;
  var prev = List<int>.filled(t.length + 1, 0);
  var cur = List<int>.filled(t.length + 1, 0);
  for (var i = 1; i <= s.length; i++) {
    for (var j = 1; j <= t.length; j++) {
      cur[j] = s.codeUnitAt(i - 1) == t.codeUnitAt(j - 1)
          ? prev[j - 1] + 1
          : max(prev[j], cur[j - 1]);
    }
    final swap = prev;
    prev = cur;
    cur = swap;
  }
  final lcs = prev[t.length];
  return (2 * lcs) / (s.length + t.length);
}

/// 滑动叠加画笔：整图打底，竖线左侧裁剪绘制模型结果（绿字框），
/// 右侧裁剪绘制基线结果（蓝字框），中间画可拖动竖线与两侧角标。
class _SliderComparePainter extends CustomPainter {
  final ui.Image image;
  final PageAnnotation? withAnn;
  final PageAnnotation? withoutAnn;
  final double fraction;

  /// 画哪些层级的框（按被测层过滤，见 [_shownBoxLevels]）。
  final Set<String> levels;

  /// 左/右两侧角标文字（绿侧/蓝侧）：模型 vs 基线，或模型A vs 模型B。
  final String leftLabel;
  final String rightLabel;

  _SliderComparePainter({
    required this.image,
    required this.withAnn,
    required this.withoutAnn,
    required this.fraction,
    required this.levels,
    required this.leftLabel,
    required this.rightLabel,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.low,
    );

    final dx = size.width * fraction;
    _drawSide(canvas, size, withAnn, Colors.green, Rect.fromLTWH(0, 0, dx, size.height));
    _drawSide(canvas, size, withoutAnn, Colors.blue, Rect.fromLTWH(dx, 0, size.width - dx, size.height));

    canvas.drawLine(
      Offset(dx, 0),
      Offset(dx, size.height),
      Paint()
        ..color = Colors.white
        ..strokeWidth = 2,
    );
    canvas.drawCircle(
      Offset(dx, size.height / 2),
      11,
      Paint()..color = Colors.white.withValues(alpha: 0.92),
    );
    canvas.drawCircle(
      Offset(dx, size.height / 2),
      11,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.grey.shade700,
    );
    _tag(canvas, leftLabel, const Offset(8, 8), Colors.green.shade700);
    final rightW = rightLabel.length * 13.0 + 8;
    _tag(
      canvas,
      rightLabel,
      Offset(size.width - rightW, 8),
      Colors.blue.shade700,
    );
  }

  void _drawSide(
    Canvas canvas,
    Size size,
    PageAnnotation? ann,
    Color charColor,
    Rect clip,
  ) {
    if (ann == null) return;
    canvas.save();
    canvas.clipRect(clip);
    final scaleX = size.width / image.width;
    final scaleY = size.height / image.height;

    void drawRects(List<Rect> rects, Color color, double width) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..color = color;
      for (final r in rects) {
        canvas.drawRect(
          Rect.fromLTWH(
            r.left * scaleX,
            r.top * scaleY,
            r.width * scaleX,
            r.height * scaleY,
          ),
          paint,
        );
      }
    }

    if (levels.contains('region')) {
      drawRects(ann.mainRegions.map((r) => Rect.fromLTWH(r.x.toDouble(), r.y.toDouble(), r.w.toDouble(), r.h.toDouble())).toList(), Colors.deepPurple, 2);
    }
    if (levels.contains('paragraph')) {
      drawRects(ann.paragraphs.map((pp) => Rect.fromLTWH(pp.x.toDouble(), pp.y.toDouble(), pp.w.toDouble(), pp.h.toDouble())).toList(), Colors.purple, 1.5);
    }
    if (levels.contains('line')) {
      drawRects(ann.lines.map((l) => Rect.fromLTWH(l.x.toDouble(), l.y.toDouble(), l.w.toDouble(), l.h.toDouble())).toList(), Colors.orange, 1.5);
    }
    if (levels.contains('char')) {
      drawRects(ann.blocks.map((b) => Rect.fromLTWH(b.x.toDouble(), b.y.toDouble(), b.w.toDouble(), b.h.toDouble())).toList(), charColor, 1);
    }
    canvas.restore();
  }

  void _tag(Canvas canvas, String text, Offset pos, Color bg) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final rect = Rect.fromLTWH(
      pos.dx - 3,
      pos.dy - 2,
      tp.width + 6,
      tp.height + 4,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(4)),
      Paint()..color = bg,
    );
    tp.paint(canvas, pos);
  }

  @override
  bool shouldRepaint(covariant _SliderComparePainter old) =>
      old.image != image ||
      old.withAnn != withAnn ||
      old.withoutAnn != withoutAnn ||
      old.fraction != fraction ||
      old.leftLabel != leftLabel ||
      old.rightLabel != rightLabel ||
      old.levels.length != levels.length ||
      !old.levels.containsAll(levels);
}
