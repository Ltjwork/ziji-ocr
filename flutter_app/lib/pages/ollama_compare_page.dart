import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import '../services/ai_trace.dart';
import '../services/ollama_compare.dart';
import '../services/ollama_service.dart';
import '../services/python_service.dart';
import '../services/storage.dart';
import '../widgets/ai_trace_entry_view.dart';
import '../widgets/attached_scrollbar.dart';
import '../widgets/backend_console_panel.dart';

/// 「AI 模型对比」工作台：左栏像编辑器一样浏览书籍任意页（主区/段落/
/// 行/单字四级视图、多页勾选），右栏选模型 × 选任务对真实数据做并排
/// 对比与批量统计，展示每次调用的 prompt / 原始返回 / 耗时，并用管线
/// 协作图 + 整页切分调试图 + 后端控制台说明 OpenCV / 自训 YOLO / Kraken
/// / Ollama 各自在哪一步工作。入口在「AI 辅助设置」（与 YOLO 自训模型
/// 的「模型对比测试」页相互独立）。
class OllamaComparePage extends StatefulWidget {
  const OllamaComparePage({super.key});

  @override
  State<OllamaComparePage> createState() => _OllamaComparePageState();
}

/// 视图层级（与编辑器同语义：主区 → 段落 → 行 → 单字）。
enum _ViewLevel { region, paragraph, line, char }

extension on _ViewLevel {
  String get label => switch (this) {
    _ViewLevel.region => '主区',
    _ViewLevel.paragraph => '段落',
    _ViewLevel.line => '行',
    _ViewLevel.char => '单字',
  };
}

class _OllamaComparePageState extends State<OllamaComparePage> {
  // ── 左栏：书籍浏览 ──
  List<Project> _projects = [];
  Project? _project;
  int _currentPage = 0;
  Set<int> _selectedPages = {};
  _ViewLevel _level = _ViewLevel.line;
  PageAnnotation? _ann;
  int _imgW = 0;
  int _imgH = 0;
  ImageStream? _imgStream;
  ImageStreamListener? _imgListener;
  final TransformationController _xform = TransformationController();

  // 选中对象（跨层级联动：选中字会同时记录其行）。
  String? _selRegionId;
  String? _selParaId;
  String? _selLineId;
  String? _selCharId;

  // ── 右栏：模型与任务 ──
  OllamaSettings _ollama = const OllamaSettings();

  /// 两个来源各自拉到的模型列表（本地 Ollama + 外部 API 全部供应商，可
  /// 同时勾选混跑对比；一边失败/未配置不影响另一边；外部条目带供应商 id）。
  List<ModelRef> _localRefs = const [];
  List<ModelRef> _extRefs = const [];
  String? _localModelsError;
  String? _extModelsError;

  /// 按组勾选：图像模型跑整行裁决/框诊断（必须看图），文本模型跑单字/
  /// 标点校对（单字辅助与编辑器同口径带整行行图，纯文本模型自动去图
  /// 按上下文作答；标点辅助纯上下文）。
  Set<ModelRef> _checkedVision = {};
  Set<ModelRef> _checkedText = {};
  bool _loadingModels = false;
  final Set<CompareTask> _tasks = {...CompareTask.values};

  /// 「记录思考过程」：请求模型思维链（trace.thinking）。推理型模型
  /// 显著变慢、token 消耗变大，默认关；结果面板的「AI 过程」对话框
  /// 无论开关都能看输入图 / prompt / 原始返回。
  bool _wantThinking = false;

  /// 左栏处于「对比视图」（跑完单对象对比后自动进入，图形化并排展示）。
  bool _compareMode = false;

  /// 用户手填的整行正确文字（人工基准）：填了以后程序判断/差异率以它
  /// 为参考，而不是行内当前识别文本。
  final TextEditingController _manualRefCtrl = TextEditingController();

  // ── 运行状态 ──
  bool _running = false;
  CompareProgress? _progress;
  bool _cancelRequested = false;
  List<CompareRunResult> _singleResults = const [];
  String _singleTargetLabel = '';

  /// 单对象运行时目标行的字快照（诊断问题序号 → 字文本映射用）。
  List<CharBlock> _singleLineChars = const [];

  /// 行条输入图（各模型相同，解码一次供所有对比面板复用，避免逐 build
  /// 重复 base64 解码）与自然尺寸（面板里"图左文右"同高布局的依据）。
  Uint8List? _lineThumbBytes;
  int _lineThumbW = 0;
  int _lineThumbH = 0;
  ImageStream? _thumbStream;
  ImageStreamListener? _thumbListener;
  List<CompareRunResult> _batchResults = const [];

  // ── 管线调试图 ──
  bool _debugLoading = false;
  String? _debugImage;
  String? _maskImage;
  String? _debugError;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _imgStream?.removeListener(_imgListener!);
    _thumbStream?.removeListener(_thumbListener!);
    _manualRefCtrl.dispose();
    _xform.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    _fireAndForget(_loadProjects());
    _fireAndForget(_loadOllama());
  }

  /// 页面自加载类的后台动作：内部已自行兜底异常，这里只防未处理异步
  /// 错误冒泡（与 _loadProjects 的 try/catch 口径一致）。
  void _fireAndForget(Future<void> f) => f.then((_) {}, onError: (Object e) {});

  Future<void> _loadProjects() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final root = p.join(docs.path, 'GujiBT');
      final projects = await ProjectStorage.loadAll(root);
      projects.sort((a, b) => a.id.compareTo(b.id));
      if (!mounted) return;
      setState(() {
        _projects = projects;
        if (projects.isNotEmpty) _setProject(projects.last);
      });
    } catch (_) {}
  }

  Future<void> _loadOllama() async {
    final s = await OllamaSettings.load();
    if (!mounted) return;
    setState(() => _ollama = s);
    await _refreshModels();
  }

  /// 单来源拉取：失败/未配置返回空列表 + 错误信息，不阻塞另一来源。
  /// 外部来源逐个供应商拉取（各家并行、各自容错），返回带供应商 id 的
  /// [ModelRef]；本地来源 extPid 恒为空串。
  Future<({List<ModelRef> refs, String? error})>
      _fetchModels(AiProvider provider) async {
    if (provider == AiProvider.localOllama) {
      try {
        final models = await OllamaService.listModelsFor(
          _ollama.copyWith(provider: provider),
        );
        return (
          refs: [
            for (final m in models)
              (
                provider: AiProvider.localOllama,
                extPid: kNoExtProvider,
                name: m.name,
              ),
          ],
          error: null,
        );
      } on OllamaException catch (e) {
        return (refs: const <ModelRef>[], error: e.message);
      } catch (e) {
        return (refs: const <ModelRef>[], error: e.toString());
      }
    }
    // 外部：多供应商并行拉取，一家失败不拖累别家。
    final providers = _ollama.extProviders
        .where((p) => p.baseUrl.trim().isNotEmpty)
        .toList();
    if (providers.isEmpty) {
      // 未配置任何外部供应商：不算错误，模型组里给配置引导。
      return (refs: const <ModelRef>[], error: null);
    }
    final results = await Future.wait([
      for (final p in providers)
        OllamaService.listModelsOfProvider(p)
            .then(
              (ms) => (
                p: p,
                models: ms,
                error: null as String?,
              ),
            )
            .onError((e, _) => (
              p: p,
              models: const <OllamaInstalledModel>[],
              error: e is OllamaException ? e.message : e.toString(),
            )),
    ]);
    final refs = <ModelRef>[];
    final errors = <String>[];
    for (final r in results) {
      if (r.error != null) {
        errors.add('${r.p.name}：${r.error}');
        continue;
      }
      for (final m in r.models) {
        refs.add((provider: AiProvider.externalApi, extPid: r.p.id, name: m.name));
      }
    }
    return (refs: refs, error: errors.isEmpty ? null : errors.join('\n'));
  }

  Future<void> _refreshModels() async {
    setState(() {
      _loadingModels = true;
      _localModelsError = null;
      _extModelsError = null;
    });
    // 两来源并行拉取：一边连不上不影响另一边（混比各自可用即可）。
    final results = await Future.wait([
      _fetchModels(AiProvider.localOllama),
      _fetchModels(AiProvider.externalApi),
    ]);
    if (!mounted) return;
    final local = results[0];
    final ext = results[1];
    setState(() {
      _localRefs = local.refs;
      _extRefs = ext.refs;
      _localModelsError = local.error;
      _extModelsError = ext.error;
      _loadingModels = false;
      // 勾选保留：模型还在其来源/供应商的列表里才留下（record 相等性按
      // 来源+供应商+模型名整体比对，同名不同出处互不挤掉）。
      final available = <ModelRef>{...local.refs, ...ext.refs};
      _checkedVision = _checkedVision.where(available.contains).toSet();
      _checkedText = _checkedText.where(available.contains).toSet();
      // 默认勾选两来源各自的当前视觉/文本模型（开箱即"本地 vs 外部"）。
      void checkDefault(ModelRef? ref, Set<ModelRef> group) {
        if (ref == null) return;
        if (available.contains(ref)) group.add(ref);
      }

      checkDefault(
        _ollama.visionModel.isEmpty
            ? null
            : (
                provider: AiProvider.localOllama,
                extPid: kNoExtProvider,
                name: _ollama.visionModel,
              ),
        _checkedVision,
      );
      checkDefault(
        _ollama.textModel.isEmpty
            ? null
            : (
                provider: AiProvider.localOllama,
                extPid: kNoExtProvider,
                name: _ollama.textModel,
              ),
        _checkedText,
      );
      checkDefault(_externalSlotRef(_ollama.extVisionModel,
          _ollama.effectiveVisionProviderId), _checkedVision);
      checkDefault(_externalSlotRef(_ollama.extTextModel,
          _ollama.effectiveTextProviderId), _checkedText);
      if (_checkedVision.isEmpty && _checkedText.isEmpty && available.isNotEmpty) {
        _checkedVision.add(_sortedRefs(available).first);
      }
    });
  }

  /// 外部槽位（模型名 + 生效供应商 id）对应的 ModelRef；模型名为空或
  /// 无生效供应商为 null（未配置不默认勾选）。
  ModelRef? _externalSlotRef(String model, String? providerId) {
    if (model.isEmpty || providerId == null || providerId.isEmpty) return null;
    return (provider: AiProvider.externalApi, extPid: providerId, name: model);
  }

  /// 供应商显示名（勾选行与结果徽章用；找不到返回空串）。
  String _extProviderName(String extPid) =>
      _ollama.extProviderOf(extPid)?.name ?? '';

  /// 勾选模型的稳定排序：同来源聚在一起（本地在前），外部按供应商 id、
  /// 来源内按模型名。同来源同供应商连续跑可减少本地 Ollama 反复换载模型。
  List<ModelRef> _sortedRefs(Set<ModelRef> refs) => refs.toList()
    ..sort((a, b) {
      final byProvider = a.provider.index.compareTo(b.provider.index);
      if (byProvider != 0) return byProvider;
      final byExt = a.extPid.compareTo(b.extPid);
      if (byExt != 0) return byExt;
      return a.name.compareTo(b.name);
    });

  // ── 项目/页/标注 ──

  void _setProject(Project project) {
    _project = project;
    _currentPage = project.lastPageIndex.clamp(
      0,
      math.max(0, project.imageFiles.length - 1),
    );
    _selectedPages = {_currentPage};
    _clearSelection();
    _debugImage = null;
    _maskImage = null;
    _debugError = null;
    _fireAndForget(_loadAnnotation());
  }

  void _setCurrentPage(int index) {
    if (_project == null ||
        index < 0 ||
        index >= _project!.imageFiles.length ||
        index == _currentPage) {
      return;
    }
    setState(() {
      _currentPage = index;
      _selectedPages.add(index);
      _clearSelection();
    });
    _fireAndForget(_loadAnnotation());
  }

  void _toggleBatchPage(int index) {
    setState(() {
      if (!_selectedPages.remove(index)) _selectedPages.add(index);
    });
  }

  void _clearSelection() {
    _selRegionId = null;
    _selParaId = null;
    _selLineId = null;
    _selCharId = null;
  }

  String? get _currentImagePath =>
      _project == null || _project!.imageFiles.isEmpty
      ? null
      : _project!.imageFiles[_currentPage];

  Future<void> _loadAnnotation() async {
    final project = _project;
    final path = _currentImagePath;
    if (project == null || path == null) return;
    final ann = await ProjectStorage.loadAnnotation(
      project.projectDir,
      project.pageIdAt(_currentPage),
      expectedImagePath: path,
    );
    // 异步回来时项目/页可能已切换：核对仍是要的那页再落地。
    if (!mounted || _project != project) return;
    if (path != _currentImagePath) return;
    setState(() => _ann = ann);
    _resolveImageSize(path);
  }

  void _resolveImageSize(String path) {
    final old = _imgStream;
    final oldListener = _imgListener;
    if (old != null && oldListener != null) old.removeListener(oldListener);
    final provider = FileImage(File(path));
    final stream = provider.resolve(const ImageConfiguration());
    final listener = ImageStreamListener((info, _) {
      if (!mounted) return;
      if (_imgW != info.image.width || _imgH != info.image.height) {
        setState(() {
          _imgW = info.image.width;
          _imgH = info.image.height;
        });
      }
    });
    _imgStream = stream;
    _imgListener = listener;
    stream.addListener(listener);
  }

  // ── 选中对象查找 ──

  MainRegion? get _selRegion {
    final ann = _ann;
    final id = _selRegionId;
    if (ann == null || id == null) return null;
    for (final r in ann.mainRegions) {
      if (r.id == id) return r;
    }
    return null;
  }

  Paragraph? get _selPara {
    final ann = _ann;
    final id = _selParaId;
    if (ann == null || id == null) return null;
    for (final r in ann.paragraphs) {
      if (r.id == id) return r;
    }
    return null;
  }

  LineBlock? get _selLine {
    final ann = _ann;
    final id = _selLineId;
    if (ann == null || id == null) return null;
    for (final l in ann.lines) {
      if (l.id == id) return l;
    }
    return null;
  }

  CharBlock? get _selChar {
    final line = _selLine;
    final id = _selCharId;
    if (line == null || id == null) return null;
    for (final c in line.chars) {
      if (c.id == id) return c;
    }
    return null;
  }

  // ── 画布 ──

  /// 图片在视口内的 contain 适配参数（画框与点击命中共用同一套换算）。
  (double, double, double) _fit(Size viewport) {
    if (_imgW <= 0 || _imgH <= 0 || viewport.isEmpty) return (1.0, 0.0, 0.0);
    final scale = math.min(
      viewport.width / _imgW,
      viewport.height / _imgH,
    );
    return (
      scale,
      (viewport.width - _imgW * scale) / 2,
      (viewport.height - _imgH * scale) / 2,
    );
  }

  void _handleTap(Offset local, Size viewport) {
    final ann = _ann;
    if (ann == null) return;
    final (scale, dx, dy) = _fit(viewport);
    final ix = (local.dx - dx) / scale;
    final iy = (local.dy - dy) / scale;
    bool contains(dynamic b) =>
        ix >= b.x && iy >= b.y && ix <= b.x + b.w && iy <= b.y + b.h;
    switch (_level) {
      case _ViewLevel.region:
        setState(() {
          _selRegionId = ann.mainRegions.any(contains)
              ? ann.mainRegions.firstWhere(contains).id
              : null;
        });
      case _ViewLevel.paragraph:
        setState(() {
          _selParaId = ann.paragraphs.any(contains)
              ? ann.paragraphs.firstWhere(contains).id
              : null;
        });
      case _ViewLevel.line:
        setState(() {
          _selLineId = ann.lines.any(contains)
              ? ann.lines.firstWhere(contains).id
              : null;
          _selCharId = null;
        });
      case _ViewLevel.char:
        LineBlock? hostLine;
        CharBlock? hit;
        var hitArea = double.infinity;
        for (final line in ann.lines) {
          for (final c in line.chars) {
            if (contains(c)) {
              final area = (c.w * c.h).toDouble();
              if (area < hitArea) {
                hitArea = area;
                hit = c;
                hostLine = line;
              }
            }
          }
        }
        setState(() {
          if (hit != null && hostLine != null) {
            _selLineId = hostLine.id;
            _selCharId = hit.id;
          } else {
            _selCharId = null;
          }
        });
    }
  }

  // ── 运行 ──

  /// 单对象目标解析：行级任务用选中行（或选中字所在行）；字级任务用
  /// 选中字，未选字时取选中行里置信度最低的字（AI 辅助的目标场景）。
  (int, CharBlock?)? _resolveTarget(List<LineBlock> lines, CompareTask task) {
    final line = _selLine;
    if (line == null || line.chars.isEmpty) return null;
    final idx = lines.indexOf(line);
    if (idx < 0) return null;
    switch (task) {
      case CompareTask.charAssist:
      case CompareTask.punctAssist:
        final c = _selChar;
        if (c != null && line.chars.contains(c)) return (idx, c);
        CharBlock? worst;
        var worstConf = 1.1;
        for (final ch in line.chars) {
          final conf = ch.conf ?? 1.0;
          if (conf < worstConf) {
            worstConf = conf;
            worst = ch;
          }
        }
        return worst == null ? null : (idx, worst);
      case CompareTask.lineDecision:
      case CompareTask.boxDiagnosis:
        return (idx, null);
    }
  }

  bool get _canRun => !_running &&
      _tasks.isNotEmpty &&
      _ann != null &&
      _ann!.lines.isNotEmpty &&
      _tasks.every((t) =>
          (t.needsVisionModel ? _checkedVision : _checkedText).isNotEmpty);

  Future<void> _runSingle() async {
    if (!_canRun) return;
    final ann = _ann!;
    final lines = ann.lines;
    final targets = <CompareTask, (int, CharBlock?)>{};
    for (final task in _tasks) {
      final t = _resolveTarget(lines, task);
      if (t != null) targets[task] = t;
    }
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先在左侧图上点选一个行或字')),
      );
      return;
    }
    final page = CompareBatchPage(
      imagePath: _currentImagePath!,
      pageLabel: '第 ${_currentPage + 1} 页',
      lines: lines,
      settings: _project?.settingsAt(_currentPage),
    );
    // 目标描述在开跑前定格：运行期间用户仍可点选画布换目标。
    final targetLabel = _singleTargetDescription(targets);
    final lineChars = List<CharBlock>.from(lines[targets.values.first.$1].chars);
    // 执行计划：图像任务 × 图像模型，文本任务 × 文本模型；同来源同模型
    // 的调用连续跑（减少 Ollama 反复换载）。本地与外部模型可混跑。
    final plan = <(ModelRef, CompareTask)>[
      for (final model in _sortedRefs(_checkedVision))
        for (final task in CompareTask.values)
          if (targets.containsKey(task) && task.needsVisionModel) (model, task),
      for (final model in _sortedRefs(_checkedText))
        for (final task in CompareTask.values)
          if (targets.containsKey(task) && !task.needsVisionModel) (model, task),
    ];
    final runner = OllamaCompareRunner(
      settings: _ollama,
      wantThinking: _wantThinking,
    );
    final results = <CompareRunResult>[];
    final total = plan.length;
    var done = 0;
    setState(() {
      _running = true;
      _cancelRequested = false;
      _progress = null;
      _singleTargetLabel = targetLabel;
      _singleLineChars = lineChars;
      _compareMode = false; // 重跑先回到浏览态，跑完再切新目标的对照视图
    });
    for (final (model, task) in plan) {
      if (_cancelRequested) break;
      final target = targets[task]!;
      setState(() {
        _progress = CompareProgress(
          description:
              '${modelRefLabel(model, extProviderName: _extProviderName)} · '
              '${task.label}（$done/$total）',
          done: done,
          total: total,
        );
      });
      final r = await runner.runTask(
        task: task,
        model: model,
        page: page,
        lineIndex: target.$1,
        target: task == CompareTask.charAssist ||
                task == CompareTask.punctAssist
            ? target.$2
            : null,
        manualLineRef: _manualRefCtrl.text,
      );
      done++;
      results.add(r);
      if (mounted) setState(() => _singleResults = List.of(results));
    }
    if (mounted) {
      setState(() {
        _running = false;
        _progress = null;
        _singleResults = results;
        _compareMode = true; // 跑完切到左栏图形化对比视图
      });
      // 行条图统一拉一次（仅所选那一竖行，无橙框——与校对卡片的行图同
      // 观感），所有任务的面板共用；拉取失败回退用 trace 里的图。
      String? b64;
      try {
        final targetLine = lines[targets.values.first.$1];
        final thumbs = await PythonService.fetchLineThumbnails(
          items: [
            LineThumbRequest(
              imagePath: page.imagePath,
              x: targetLine.x,
              y: targetLine.y,
              w: targetLine.w,
              h: targetLine.h,
              orientation: targetLine.orientation,
            ),
          ],
          maxSide: 1024,
        );
        b64 = thumbs.isEmpty ? null : thumbs.first;
      } catch (_) {}
      if (b64 == null || b64.isEmpty) {
        for (final r in results) {
          final t = r.trace.imageBase64;
          if (t != null && t.isNotEmpty) {
            b64 = t;
            break;
          }
        }
      }
      _prepareLineThumb(b64);
    }
  }

  /// 解码行条输入图并探测自然尺寸（对比面板"图左文右同高"布局依据）。
  void _prepareLineThumb(String? b64) {
    if (b64 == null || b64.isEmpty) {
      _lineThumbBytes = null;
      _lineThumbW = 0;
      _lineThumbH = 0;
      return;
    }
    final bytes = base64Decode(b64);
    _lineThumbBytes = bytes;
    final old = _thumbStream;
    final oldListener = _thumbListener;
    if (old != null && oldListener != null) old.removeListener(oldListener);
    final stream = MemoryImage(bytes).resolve(const ImageConfiguration());
    final listener = ImageStreamListener((info, _) {
      if (!mounted) return;
      if (_lineThumbW != info.image.width || _lineThumbH != info.image.height) {
        setState(() {
          _lineThumbW = info.image.width;
          _lineThumbH = info.image.height;
        });
      }
    });
    _thumbStream = stream;
    _thumbListener = listener;
    stream.addListener(listener);
  }

  String _singleTargetDescription(Map<CompareTask, (int, CharBlock?)> targets) {
    final line = _selLine;
    if (line == null) return '';
    final buf = StringBuffer('第 ${_currentPage + 1} 页 · 行 ${targets.values.first.$1 + 1}');
    final charTask = targets[CompareTask.charAssist] ??
        targets[CompareTask.punctAssist];
    if (charTask?.$2 != null) {
      buf.write(' · 第 ${charTask!.$2!.order + 1} 字「${charTask.$2!.text}」');
    }
    return buf.toString();
  }

  Future<void> _runBatch() async {
    if (!_canRun) return;
    final project = _project!;
    // 批量范围：左栏选中了主区/段落 → 只跑当前页该范围内的行；
    // 否则跑全部勾选页。每页现载标注，空标注页跳过并提示。
    final pages = <CompareBatchPage>[];
    final skipped = <String>[];
    if (_level == _ViewLevel.region && _selRegion != null ||
        _level == _ViewLevel.paragraph && _selPara != null) {
      final lines = _linesInSelection(_ann!);
      if (lines.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('选中的主区/段落里没有识别行')),
          );
        }
        return;
      }
      pages.add(
        CompareBatchPage(
          imagePath: _currentImagePath!,
          pageLabel: '第 ${_currentPage + 1} 页（选中范围）',
          lines: lines,
          settings: _project?.settingsAt(_currentPage),
        ),
      );
    } else {
      for (final index in _selectedPages.toList()..sort()) {
        if (index < 0 || index >= project.imageFiles.length) continue;
        final ann = await ProjectStorage.loadAnnotation(
          project.projectDir,
          project.pageIdAt(index),
          expectedImagePath: project.imageFiles[index],
        );
        if (ann == null || ann.lines.isEmpty) {
          skipped.add('第 ${index + 1} 页');
          continue;
        }
        pages.add(
          CompareBatchPage(
            imagePath: project.imageFiles[index],
            pageLabel: '第 ${index + 1} 页',
            lines: ann.lines,
            settings: project.settingsAt(index),
          ),
        );
      }
    }
    if (pages.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              skipped.isEmpty ? '没有可对比的页（勾选的页均未识别）' : '已跳过未识别页：${skipped.join('、')}',
            ),
          ),
        );
      }
      return;
    }
    final runner = OllamaCompareRunner(
      settings: _ollama,
      wantThinking: _wantThinking,
    );
    final visionModels = _sortedRefs(_checkedVision);
    final textModels = _sortedRefs(_checkedText);
    final results = <CompareRunResult>[];
    setState(() {
      _running = true;
      _cancelRequested = false;
      _progress = null;
      _batchResults = const [];
    });
    await runner.runBatch(
      pages: pages,
      visionModels: visionModels,
      textModels: textModels,
      tasks: _tasks,
      onProgress: (prog) {
        if (mounted) setState(() => _progress = prog);
      },
      onResult: (r) {
        results.add(r);
        if (mounted) setState(() => _batchResults = List.of(results));
      },
      cancelled: () => _cancelRequested,
    );
    if (mounted) {
      setState(() {
        _running = false;
        _progress = null;
      });
      if (skipped.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已跳过未识别页：${skipped.join('、')}')),
        );
      }
    }
  }

  /// 选中主区/段落范围内的行（段落按 lineIds/paragraphId，主区按其段落
  /// 汇总；旧标注缺归属时退回中心点包含）。
  List<LineBlock> _linesInSelection(PageAnnotation ann) {
    final para = _selPara;
    if (para != null) {
      return ann.lines
          .where(
            (l) =>
                l.paragraphId == para.id ||
                para.lineIds.contains(l.id) ||
                para.rect.contains(l.rect.center),
          )
          .toList();
    }
    final region = _selRegion;
    if (region != null) {
      final paraIds = ann.paragraphs
          .where((pr) => pr.mainRegionId == region.id)
          .map((pr) => pr.id)
          .toSet();
      return ann.lines
          .where(
            (l) =>
                paraIds.contains(l.paragraphId) ||
                region.rect.contains(l.rect.center),
          )
          .toList();
    }
    return const [];
  }

  // ── 管线调试图 ──

  Future<void> _generateDebugImages() async {
    final project = _project;
    final path = _currentImagePath;
    if (project == null || path == null || _debugLoading) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('生成整页切分调试图'),
        content: const Text(
          '会对当前页重新跑一遍完整分割（YOLO/投影出框 + Kraken 识别），'
          '需要几十秒到几分钟；生成绿行框/蓝字框叠加图与二值化 mask 图，'
          '用于查看管线 ①② 阶段的实际输出。',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('开始')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _debugLoading = true;
      _debugError = null;
    });
    try {
      final r = await PythonService.segmentDebug(
        imagePath: path,
        settings: project.settingsAt(_currentPage),
      );
      if (!mounted) return;
      setState(() {
        _debugLoading = false;
        _debugImage = r.debugImagePath;
        _maskImage = r.maskImagePath;
        if (r.debugImagePath == null) {
          _debugError = '后端未返回调试图（engine=${r.engine}）';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _debugLoading = false;
        _debugError = e.toString();
      });
    }
  }

  // ── 布局 ──

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 模型对比（Ollama）'),
        actions: [
          IconButton(
            tooltip: '刷新模型列表',
            onPressed: _loadingModels ? null : _refreshModels,
            icon: _loadingModels
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 11, child: _leftPanel()),
          const VerticalDivider(width: 1),
          Expanded(flex: 9, child: _rightPanel()),
        ],
      ),
    );
  }

  // ── 左栏 ──

  Widget _leftPanel() {
    if (_compareMode) return _compareView();
    final project = _project;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              const Text('书籍', style: TextStyle(fontSize: 13)),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<Project>(
                  // 项目列表异步加载后 initialValue 才有值；该字段只在
                  // 首次 build 生效，用 Key 随项目切换强制重建。
                  key: ValueKey(project?.id),
                  initialValue: project,
                  isExpanded: true,
                  decoration: const InputDecoration(isDense: true),
                  items: [
                    for (final pr in _projects)
                      DropdownMenuItem(value: pr, child: Text(pr.name)),
                  ],
                  onChanged: project == null
                      ? null
                      : (pr) {
                          if (pr != null) {
                            setState(() => _setProject(pr));
                          }
                        },
                ),
              ),
            ],
          ),
        ),
        if (project != null && project.imageFiles.isNotEmpty)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (var i = 0; i < project.imageFiles.length; i++)
                  _pageChip(project, i),
                IconButton(
                  tooltip: '全选页（批量范围）',
                  icon: const Icon(Icons.select_all, size: 18),
                  onPressed: _running
                      ? null
                      : () => setState(() {
                          _selectedPages = {
                            for (var i = 0; i < project.imageFiles.length; i++)
                              i,
                          };
                        }),
                ),
                IconButton(
                  tooltip: '清空批量范围（仅保留当前页）',
                  icon: const Icon(Icons.filter_alt_off, size: 18),
                  onPressed: _running
                      ? null
                      : () => setState(
                          () => _selectedPages = {_currentPage},
                        ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: SegmentedButton<_ViewLevel>(
            segments: [
              for (final lv in _ViewLevel.values)
                ButtonSegment(value: lv, label: Text(lv.label)),
            ],
            selected: {_level},
            onSelectionChanged: _running
                ? null
                : (s) => setState(() {
                    _level = s.first;
                    _clearSelection();
                  }),
          ),
        ),
        Expanded(child: _canvasArea()),
        _selectionBar(),
      ],
    );
  }

  // ── 左栏：图形化对比视图（跑完单对象对比自动进入）──

  Widget _compareView() {
    final byTask = <CompareTask, List<CompareRunResult>>{};
    for (final r in _singleResults) {
      byTask.putIfAbsent(r.task, () => []).add(r);
    }
    // 版向随目标行：竖排书 → 各模型为并排竖栏，面板内"行图在左、
    // 竖排对照文字在右"（同编辑器单字模式卡片）；横排书 → 面板堆叠，
    // 面板内"行图在上、横排文字在下"。
    final lineOrientation =
        _selLine?.orientation ??
        (_project == null || _project!.imageFiles.isEmpty
            ? 'vertical'
            : _project!.settingsAt(_currentPage).orientation);
    final vertical = lineOrientation != 'horizontal';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            TextButton.icon(
              onPressed: () => setState(() => _compareMode = false),
              icon: const Icon(Icons.arrow_back, size: 18),
              label: const Text('返回浏览'),
            ),
            Expanded(
              child: Text(
                _singleTargetLabel,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
            ),
            if (_manualRefCtrl.text.trim().isNotEmpty)
              Tooltip(
                message: '人工基准：${_manualRefCtrl.text.trim()}',
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '人工基准',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: Colors.green.shade700,
                    ),
                  ),
                ),
              ),
            const SizedBox(width: 8),
            Text(
              vertical ? '竖版 · 竖栏对照（图左文右）' : '横版 · 横栏对照（图上文下）',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
            ),
            const SizedBox(width: 12),
          ],
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final task in CompareTask.values)
                  if (byTask.containsKey(task))
                    _compareTaskSection(task, byTask[task]!, vertical),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 一个任务的对照区：程序判断横幅 + 各模型面板（竖版并排/横版堆叠）。
  Widget _compareTaskSection(
    CompareTask task,
    List<CompareRunResult> results,
    bool vertical,
  ) {
    final verdict = verdictFor(results);
    final panelList = [
      for (final r in results)
        _comparePanel(r, verdict.badges[r.modelKey] ?? '', vertical),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 10, bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.deepPurple.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Text(
                task.label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '程序判断：${verdict.summary}',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.deepPurple.shade900,
                  ),
                ),
              ),
            ],
          ),
        ),
        // 竖版：窄竖卡并排（与校对单字卡片同宽级），超出横向滚动；
        // 横版：面板整行堆叠。
        if (vertical)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final p in panelList)
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: SizedBox(width: 132, child: p),
                  ),
              ],
            ),
          )
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: panelList,
          ),
      ],
    );
  }

  /// 一个模型的对照面板（窄竖卡）：模型名 + 程序判断徽章 + 行图 +
  /// 对照正文 + 耗时。程序判为最优的面板绿框高亮。
  Widget _comparePanel(CompareRunResult r, String badge, bool vertical) {
    final isWinner = badge.contains('最优') || badge.contains('第 1 命中');
    return Container(
      padding: const EdgeInsets.all(8),
      margin: vertical
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(
          color: isWinner ? Colors.green.shade600 : Colors.grey.shade300,
          width: isWinner ? 1.6 : 1,
        ),
        borderRadius: BorderRadius.circular(8),
        color: isWinner ? Colors.green.withValues(alpha: 0.05) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            r.modelLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            badge.isEmpty ? '—' : badge,
            style: TextStyle(
              fontSize: 10,
              color: isWinner ? Colors.green.shade700 : Colors.grey.shade600,
              fontWeight: isWinner ? FontWeight.w600 : null,
            ),
          ),
          const Divider(height: 10),
          _panelBody(r, vertical),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${_fmtMs(r.elapsedMs)}'
                  '${r.trace.imageDropped ? ' · 无图' : ''}',
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                ),
              ),
              SizedBox(
                height: 24,
                child: TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: Size.zero,
                    textStyle: const TextStyle(fontSize: 10),
                  ),
                  onPressed: () => _showAiProcess(r),
                  child: const Text('AI 过程'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _panelBody(CompareRunResult r, bool vertical) {
    if (!r.ok) {
      return Text(
        _truncate(r.error ?? '', 80),
        style: TextStyle(fontSize: 11, color: Colors.red.shade700),
      );
    }
    switch (r.task) {
      case CompareTask.lineDecision:
        final cells = lineDiffCells(r.reference, r.lineDecision!);
        return _panelWithImage(
          vertical: vertical,
          content: vertical
              ? _cellColumn([for (final c in cells) _diffCellWidget(c)])
              : Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [for (final c in cells) _diffCellWidget(c)],
                ),
          caption:
              '${changedCountOf(cells)} 处改动 · '
              'conf ${r.lineDecision!.confidence.toStringAsFixed(2)}'
              '${r.lineDecision!.eligible ? '' : ' · 不采纳'}',
        );
      case CompareTask.boxDiagnosis:
        final diag = r.boxDiagnosis!;
        final flagged = <int, OllamaBoxIssue>{};
        for (final i in diag.issues) {
          if (i.pos > 0) flagged.putIfAbsent(i.pos, () => i);
        }
        if (_singleLineChars.isEmpty) {
          return const Text('（无行字快照）', style: TextStyle(fontSize: 11));
        }
        final cells = [
          for (var i = 0; i < _singleLineChars.length; i++)
            _diagCellWidget(_singleLineChars[i].text, flagged[i + 1]),
        ];
        return _panelWithImage(
          vertical: vertical,
          content: vertical
              ? _cellColumn(cells)
              : Wrap(spacing: 4, runSpacing: 4, children: cells),
          caption: diag.lineOk
              ? 'line_ok（未发现问题）'
              : '红框 = 问题位 · '
                    '${diag.issues.map((i) => '${issueTypeLabel(i.type)}@${_diagPosLabel(i.pos)}').join('、')}',
        );
      case CompareTask.charAssist:
      case CompareTask.punctAssist:
        final sugs = r.suggestions!;
        if (sugs.isEmpty) {
          return const Text('（无候选）', style: TextStyle(fontSize: 11));
        }
        return _panelWithImage(
          vertical: vertical,
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < sugs.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    '${i + 1}. ${sugs[i].text}'
                    '${sugs[i].reason.isEmpty ? '' : '（${_truncate(sugs[i].reason, 8)}）'}',
                    style: TextStyle(
                      fontSize: 12,
                      color: sugs[i].text.trim() == r.reference.trim() &&
                              r.reference.trim().isNotEmpty
                          ? Colors.green.shade700
                          : Colors.grey.shade700,
                    ),
                  ),
                ),
            ],
          ),
        );
    }
  }

  /// 竖排对照字格的单列（所有字一列从上往下，不换列）。
  Widget _cellColumn(List<Widget> cells) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final c in cells)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: c,
          ),
      ],
    );
  }

  /// 面板正文统一布局：竖排行 = 行图（窄高竖条，仅所选那一竖行）在左 +
  /// 对照内容在右；横排行 = 行图（宽矮条）在上 + 内容在下。
  Widget _panelWithImage({
    required bool vertical,
    required Widget content,
    String? caption,
  }) {
    final hasImage = _lineThumbBytes != null && _lineThumbW > 0;
    final Widget body;
    if (vertical) {
      const imgW = 56.0;
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasImage)
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.memory(
                _lineThumbBytes!,
                width: imgW,
                gaplessPlayback: true,
              ),
            ),
          const SizedBox(width: 6),
          Expanded(child: content),
        ],
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasImage)
            SizedBox(
              height: 44,
              width: double.infinity,
              child: Image.memory(
                _lineThumbBytes!,
                fit: BoxFit.contain,
                gaplessPlayback: true,
              ),
            ),
          const SizedBox(height: 6),
          content,
        ],
      );
    }
    if (caption == null) return body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        body,
        const SizedBox(height: 4),
        Text(
          caption,
          style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
        ),
      ],
    );
  }

  /// 整行对照的一个字格（固定 26×32，竖排列与横排行通用）：改动字橙
  /// 底、角标小字为原字（悬停看模型理由）。
  Widget _diffCellWidget(LineDiffCell c) {
    return Tooltip(
      message: c.reason.isNotEmpty
          ? '模型理由：${c.reason}'
          : c.changed
          ? '原「${c.original}」→「${c.text}」'
          : '',
      child: SizedBox(
        width: 26,
        height: 32,
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 1),
          decoration: BoxDecoration(
            color: c.changed
                ? Colors.orange.withValues(alpha: 0.28)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            border: c.changed
                ? Border.all(color: Colors.orange.shade700, width: 0.8)
                : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 11,
                child: c.inserted
                    ? Text(
                        '＋',
                        style: TextStyle(
                          fontSize: 8,
                          height: 1.1,
                          color: Colors.orange.shade800,
                        ),
                      )
                    : c.changed && c.original.isNotEmpty
                    ? Text(
                        c.original,
                        style: TextStyle(
                          fontSize: 8,
                          height: 1.1,
                          color: Colors.grey.shade600,
                          decoration: TextDecoration.lineThrough,
                          decorationColor: Colors.grey.shade500,
                        ),
                      )
                    : null,
              ),
              Text(
                c.deleted ? '∅' : c.text,
                style: TextStyle(
                  fontSize: 15,
                  height: 1.1,
                  color: c.changed ? Colors.orange.shade900 : null,
                  fontWeight: c.changed ? FontWeight.w600 : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 框诊断面板的一个字格（固定 26×30）：该模型报了问题的位置红框标
  /// 出（悬停看类型）。
  Widget _diagCellWidget(String text, OllamaBoxIssue? issue) {
    final flagged = issue != null;
    return Tooltip(
      message: flagged ? '${issueTypeLabel(issue.type)}：${issue.note}' : '',
      child: SizedBox(
        width: 26,
        height: 30,
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: flagged
                ? Colors.red.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: flagged ? Colors.red.shade400 : Colors.grey.shade300,
              width: flagged ? 1.2 : 0.6,
            ),
          ),
          child: Text(
            text.isEmpty ? '·' : text,
            style: TextStyle(
              fontSize: 13,
              color: flagged ? Colors.red.shade900 : null,
            ),
          ),
        ),
      ),
    );
  }

  Widget _pageChip(Project project, int index) {
    final isCurrent = index == _currentPage;
    final checked = _selectedPages.contains(index);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: InputChip(
        label: Text('${index + 1}'),
        labelStyle: TextStyle(
          fontSize: 12,
          color: checked || isCurrent ? Colors.indigo.shade900 : null,
        ),
        backgroundColor: isCurrent
            ? Colors.indigo.withValues(alpha: 0.28)
            : checked
            ? Colors.indigo.withValues(alpha: 0.18)
            : null,
        visualDensity: VisualDensity.compact,
        onPressed: () => _setCurrentPage(index),
        onDeleted: _running ? null : () => _toggleBatchPage(index),
        deleteIcon: Icon(
          checked ? Icons.check_box : Icons.check_box_outline_blank,
          size: 16,
          color: checked ? Colors.indigo : Colors.grey.shade500,
        ),
        tooltip: '第 ${index + 1} 页 · 点击浏览；右侧勾选框控制批量范围',
      ),
    );
  }

  Widget _canvasArea() {
    final path = _currentImagePath;
    return Stack(
      children: [
        Positioned.fill(
          child: InteractiveViewer(
            transformationController: _xform,
            minScale: 0.4,
            maxScale: 16,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = constraints.biggest;
                return GestureDetector(
                  onTapUp: (d) => _handleTap(d.localPosition, size),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (path != null)
                        Image.file(
                          File(path),
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                          filterQuality: FilterQuality.medium,
                        )
                      else
                        ColoredBox(
                          color: Colors.grey.shade200,
                          child: Center(
                            child: Text(
                              '选择一本书开始',
                              style: TextStyle(color: Colors.grey.shade600),
                            ),
                          ),
                        ),
                      CustomPaint(
                        painter: _BoxesPainter(
                          ann: _ann,
                          level: _level,
                          fit: (viewport) => _fit(viewport),
                          selRegionId: _selRegionId,
                          selParaId: _selParaId,
                          selLineId: _selLineId,
                          selCharId: _selCharId,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
        if (_ann == null && path != null)
          Positioned(
            left: 12,
            bottom: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.orange.shade100,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '本页尚未识别（无标注）：请在编辑器里先完成识别',
                style: TextStyle(fontSize: 12, color: Colors.orange.shade900),
              ),
            ),
          ),
      ],
    );
  }

  Widget _selectionBar() {
    final ann = _ann;
    String text;
    if (ann == null) {
      text = '本页无标注';
    } else {
      switch (_level) {
        case _ViewLevel.region:
          final r = _selRegion;
          text = r == null
              ? '点击图上的主区框'
              : '主区 ${ann.mainRegions.indexOf(r) + 1}/${ann.mainRegions.length}'
                    ' · 批量时只跑该主区内的行';
        case _ViewLevel.paragraph:
          final pr = _selPara;
          text = pr == null
              ? '点击图上的段落框'
              : '段 ${ann.paragraphs.indexOf(pr) + 1}/${ann.paragraphs.length}'
                    ' · ${pr.lineIds.length} 行 · 批量时只跑该段';
        case _ViewLevel.line:
          final l = _selLine;
          text = l == null
              ? '点击图上的行框'
              : '行 ${ann.lines.indexOf(l) + 1}/${ann.lines.length} · '
                    '${l.chars.length} 字 · 「${_truncate(l.text, 14)}」';
        case _ViewLevel.char:
          final l = _selLine;
          final c = _selChar;
          text = l == null
              ? '点击图上的字框'
              : c == null
              ? '行 ${ann.lines.indexOf(l) + 1} 已选中，点击行内的字框'
              : '行 ${ann.lines.indexOf(l) + 1} · 第 ${l.chars.indexOf(c) + 1} 字'
                    ' 「${c.text.isEmpty ? '（空）' : c.text}」'
                    ' · conf ${((c.conf ?? 0.5)).toStringAsFixed(2)}'
                    '${c.confirmed ? ' · 已确认' : ''}';
      }
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      ),
      child: Text(text, style: const TextStyle(fontSize: 12)),
    );
  }

  // ── 右栏 ──

  Widget _rightPanel() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _modelsCard(),
        const SizedBox(height: 12),
        _tasksCard(),
        const SizedBox(height: 12),
        if (_singleResults.isNotEmpty) ...[
          _singleResultsCard(),
          const SizedBox(height: 12),
        ],
        if (_batchResults.isNotEmpty) ...[
          _batchSummaryCard(),
          const SizedBox(height: 12),
        ],
        _pipelineCard(),
      ],
    );
  }

  Widget _modelsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.smart_toy_outlined, size: 20),
                SizedBox(width: 8),
                Text('对比模型', style: TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
            if (_localModelsError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '本地 Ollama 列表获取失败：$_localModelsError',
                  style: TextStyle(fontSize: 12, color: Colors.orange.shade800),
                ),
              ),
            if (_extModelsError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '外部 API 列表获取失败：$_extModelsError',
                  style: TextStyle(fontSize: 12, color: Colors.orange.shade800),
                ),
              ),
            if (_extRefs.isEmpty &&
                _extModelsError == null &&
                _ollama.extProviders.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '外部模型 API 尚未配置：到「AI 辅助设置」新增供应商（地址与'
                  '密钥）并添加模型后，外部模型即可加入同场对比。',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ),
            if (_localRefs.isEmpty &&
                _extRefs.isEmpty &&
                !_loadingModels &&
                _localModelsError == null &&
                _extModelsError == null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '两边都还没有模型——本地到「AI 辅助设置 → 模型安装」下载；'
                  '外部在「AI 辅助设置」配置供应商与模型后加入。',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ),
            _modelGroupLabel(
              '图像模型（整行裁决 · 识别框诊断，看图）',
              Icons.image_outlined,
            ),
            for (final ref in _localRefs)
              _modelGroupCheckbox(ref, group: _checkedVision),
            for (final ref in _extRefs)
              _modelGroupCheckbox(ref, group: _checkedVision),
            const SizedBox(height: 6),
            _modelGroupLabel(
              '文本模型（单字辅助 · 标点辅助，文字任务）',
              Icons.notes_outlined,
            ),
            for (final ref in _localRefs)
              _modelGroupCheckbox(ref, group: _checkedText),
            for (final ref in _extRefs)
              _modelGroupCheckbox(ref, group: _checkedText),
            const SizedBox(height: 4),
            Text(
              '两组各勾选要比的模型（同一模型可同时进两组）；本地（蓝标）与'
              '外部（青标）模型可同时勾选混跑，外部多供应商时各自走各家的'
              '地址与密钥。整行裁决/框诊断必须视觉模型；'
              '单字辅助与编辑器同口径带整行行图（纯文本模型自动去图按上下文'
              '作答），标点辅助纯上下文。串行执行，同来源同供应商的调用连续跑'
              '以减少反复换载。',
              style: TextStyle(fontSize: 11, height: 1.5, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modelGroupLabel(String label, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Row(
        children: [
          Icon(icon, size: 14, color: Colors.grey.shade600),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        ],
      ),
    );
  }

  Widget _modelGroupCheckbox(ModelRef ref, {required Set<ModelRef> group}) {
    final providerName = ref.provider == AiProvider.localOllama
        ? ''
        : _extProviderName(ref.extPid);
    return InkWell(
      onTap: _running
          ? null
          : () => setState(() {
              if (!group.remove(ref)) group.add(ref);
            }),
      child: Row(
        children: [
          Checkbox(
            visualDensity: VisualDensity.compact,
            value: group.contains(ref),
            onChanged: _running
                ? null
                : (v) => setState(() {
                    if (v == true) {
                      group.add(ref);
                    } else {
                      group.remove(ref);
                    }
                  }),
          ),
          _providerTag(ref.provider),
          const SizedBox(width: 6),
          Expanded(
            child: Text(ref.name, style: const TextStyle(fontSize: 13)),
          ),
          // 外部多供应商：模型名可能撞名，补灰字供应商名帮助区分。
          if (providerName.isNotEmpty)
            Text(
              providerName,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
            ),
          const SizedBox(width: 6),
          Text(
            _modelRoleHint(ref),
            style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }

  /// 来源小标签：本地（蓝）/ 外部（青），混比时一眼区分模型出处。
  Widget _providerTag(AiProvider provider) {
    final local = provider == AiProvider.localOllama;
    final color = local ? Colors.blue.shade700 : Colors.teal.shade700;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        local ? '本地' : '外部',
        style: TextStyle(fontSize: 10, color: color),
      ),
    );
  }

  String _modelRoleHint(ModelRef ref) {
    final hints = <String>[];
    if (ref.provider == AiProvider.localOllama) {
      if (ref.name == _ollama.visionModel) hints.add('当前视觉');
      if (ref.name == _ollama.textModel) hints.add('当前文本');
      return hints.join(' · ');
    }
    // 外部：模型名与槽位绑定的供应商都一致才算“当前”。
    if (ref.extPid == _ollama.effectiveVisionProviderId &&
        ref.name == _ollama.extVisionModel) {
      hints.add('当前视觉');
    }
    if (ref.extPid == _ollama.effectiveTextProviderId &&
        ref.name == _ollama.extTextModel) {
      hints.add('当前文本');
    }
    return hints.join(' · ');
  }

  Widget _tasksCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.checklist, size: 20),
                SizedBox(width: 8),
                Text('对比任务', style: TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
            for (final task in CompareTask.values)
              InkWell(
                onTap: _running
                    ? null
                    : () => setState(() {
                        if (!_tasks.remove(task)) _tasks.add(task);
                      }),
                child: Row(
                  children: [
                    Checkbox(
                      visualDensity: VisualDensity.compact,
                      value: _tasks.contains(task),
                      onChanged: _running
                          ? null
                          : (v) => setState(() {
                              if (v == true) {
                                _tasks.add(task);
                              } else {
                                _tasks.remove(task);
                              }
                            }),
                    ),
                    Expanded(
                      child: Text(
                        '${task.label}（${task.slotLabel}）',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('记录模型思考过程', style: TextStyle(fontSize: 13)),
              subtitle: const Text(
                '请求推理型模型输出思维链（结果面板「AI 过程」里展示）。注意：'
                '正式书籍识别不带思维链，此开关仅用于对比时观察模型思路，'
                '开启后推理型模型明显变慢、更耗 token，评测成绩仍与正式同口径',
                style: TextStyle(fontSize: 11),
              ),
              value: _wantThinking,
              onChanged: _running
                  ? null
                  : (v) => setState(() => _wantThinking = v),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '人工基准（可选）——程序判断以此为参考',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 4),
            TextField(
              controller: _manualRefCtrl,
              enabled: !_running,
              decoration: const InputDecoration(
                hintText: '输入这一行的正确文字；留空 = 用当前识别文本做参考',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 8),
            if (_progress != null) ...[
              LinearProgressIndicator(value: _progress!.fraction),
              const SizedBox(height: 4),
              Text(
                _progress!.description,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _canRun ? _runSingle : null,
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('对比选中对象'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _canRun ? _runBatch : null,
                    icon: const Icon(Icons.layers, size: 18),
                    label: Text(
                      _level == _ViewLevel.region && _selRegion != null ||
                              _level == _ViewLevel.paragraph && _selPara != null
                          ? '批量：选中范围'
                          : '批量：${_selectedPages.length} 页',
                    ),
                  ),
                ),
                if (_running) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () => setState(() => _cancelRequested = true),
                    child: const Text('取消'),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '单对象：左栏点选行/字后运行，左侧自动切为图形化对照视图'
              '（竖版书竖栏并排、横版书横栏堆叠，含原行图、逐字对照与程序'
              '判断），右栏保留每次调用的 prompt 与原始返回。\n'
              '批量：整行裁决跑勾选页全部行；单字辅助抽低置信字（≤12/页）、'
              '标点抽标点样字（≤12/页）、框诊断抽行（≤8/页），汇总排名。\n'
              '基准 = 行内当前文本（OCR + 人工校对现状），人工确认过的样本'
              '单独打 ✓；命中/一致不代表绝对正确。',
              style: TextStyle(fontSize: 11, height: 1.5, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  // ── 单对象结果 ──

  Widget _singleResultsCard() {
    final byTask = <CompareTask, List<CompareRunResult>>{};
    for (final r in _singleResults) {
      byTask.putIfAbsent(r.task, () => []).add(r);
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.compare_arrows, size: 20),
                const SizedBox(width: 8),
                const Text('对比结果', style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                if (_singleTargetLabel.isNotEmpty)
                  Text(
                    _singleTargetLabel,
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            for (final task in CompareTask.values)
              if (byTask.containsKey(task))
                _singleTaskSection(task, byTask[task]!),
          ],
        ),
      ),
    );
  }

  Widget _singleTaskSection(CompareTask task, List<CompareRunResult> results) {
    // 输入图（各模型相同，展示一次）：候选类取字图，行级取行条图，诊断
    // 取带橙框的行条。行级任务的主体信息在下方每模型的逐字对照/问题
    // 列表里，输入图只作小图佐证，不再按模型重复。
    String? image;
    for (final r in results) {
      if (r.trace.imageBase64 != null && r.trace.imageBase64!.isNotEmpty) {
        image = r.trace.imageBase64;
        break;
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Row(
          children: [
            Text(
              task.label,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 8),
            if (task == CompareTask.lineDecision)
              Text(
                '橙底 = 该模型校对过的字（角标小字为原字，悬停看理由）',
                style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
              ),
          ],
        ),
        if (image != null) ...[
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(6),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.memory(
                base64Decode(image),
                height: task == CompareTask.charAssist ? 64 : 56,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            task == CompareTask.boxDiagnosis
                ? '↑ 发给模型的诊断图（橙框 = 当前切字框，由后端叠加）'
                : task == CompareTask.charAssist
                ? '↑ 统一预览行图（无标注）；实际发给模型的是带橙框标目标字的行图，见「AI 过程」'
                : '↑ 发给模型的行条图（本行裁条，非整页）',
            style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
          ),
        ],
        const SizedBox(height: 6),
        for (final r in results) _singleResultRow(r),
      ],
    );
  }

  /// 整行裁决的逐字对照条（右栏明细用）：改动字橙底、角标显示原字，
  /// items 按位对照时鼠标悬停可看模型给的理由。
  Widget _lineDiffView(CompareRunResult r) {
    final cells = lineDiffCells(r.reference, r.lineDecision!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 3,
          runSpacing: 4,
          children: [for (final c in cells) _diffCellWidget(c)],
        ),
        const SizedBox(height: 3),
        Text(
          '${changedCountOf(cells)} 处改动 · '
          'conf ${(r.lineDecision!.confidence).toStringAsFixed(2)}'
          '${r.lineDecision!.eligible ? ' · 可采纳' : ' · 低于 0.80 不采纳'}'
          '${r.trace.imageDropped ? ' · 模型不支持图像，未看图' : ''}',
          style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
        ),
      ],
    );
  }

  Widget _singleResultRow(CompareRunResult r) {
    return ExpansionTile(
      visualDensity: VisualDensity.compact,
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      title: Row(
        children: [
          Expanded(child: Text(r.modelLabel, style: const TextStyle(fontSize: 13))),
          if (r.ok && r.trace.imageDropped) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '无图',
                style: TextStyle(fontSize: 10, color: Colors.grey.shade700),
              ),
            ),
            const SizedBox(width: 6),
          ],
          _metricChip(r),
          const SizedBox(width: 8),
          Text(
            _fmtMs(r.elapsedMs),
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
          ),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: r.ok && r.task == CompareTask.lineDecision
            ? _lineDiffView(r)
            : _resultSummary(r),
      ),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                textStyle: const TextStyle(fontSize: 12),
              ),
              onPressed: () => _showAiProcess(r),
              icon: const Icon(Icons.visibility, size: 15),
              label: const Text('AI 过程（输入图 · 提示词 · 思考 · 返回）'),
            ),
          ),
        ),
        if (r.trace.prompt.isNotEmpty || r.trace.rawContent.isNotEmpty)
          _tracePanel(r),
        if (!r.ok)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '错误：${r.error}',
              style: TextStyle(fontSize: 12, color: Colors.red.shade700),
            ),
          ),
      ],
    );
  }

  Widget _metricChip(CompareRunResult r) {
    (Color, String) spec;
    if (!r.ok) {
      spec = (Colors.red.shade700, '失败');
    } else {
      switch (r.task) {
        case CompareTask.charAssist:
        case CompareTask.punctAssist:
          final hit = r.hitRank;
          spec = hit == null
              ? (Colors.grey.shade600, r.reference.trim().isEmpty ? '无基准' : '未命中')
              : hit == 1
              ? (Colors.green.shade700, '✓ 第 1')
              : (Colors.teal.shade700, '✓ 第 $hit');
        case CompareTask.lineDecision:
          final d = r.diffRate ?? 1.0;
          spec = ((r.lineDecision?.eligible ?? false)
                  ? Colors.green.shade700
                  : Colors.orange.shade800, '差异 ${(d * 100).toStringAsFixed(0)}%');
        case CompareTask.boxDiagnosis:
          final diag = r.boxDiagnosis!;
          spec = diag.lineOk
              ? (Colors.green.shade700, '无问题')
              : (Colors.orange.shade800, '${diag.issues.length} 个问题');
      }
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: spec.$1.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(spec.$2, style: TextStyle(fontSize: 11, color: spec.$1)),
    );
  }

  /// 诊断问题序号（1 基）对应的目标行字文本；越界/无快照时只给序号。
  String _diagPosLabel(int pos) {
    if (pos <= 0 || pos > _singleLineChars.length) return '$pos';
    final text = _singleLineChars[pos - 1].text.trim();
    return text.isEmpty ? '$pos' : '$pos「$text」';
  }

  Widget _resultSummary(CompareRunResult r) {
    if (!r.ok) {
      return Text(
        _truncate(r.error ?? '', 60),
        style: TextStyle(fontSize: 11, color: Colors.red.shade700),
      );
    }
    switch (r.task) {
      case CompareTask.charAssist:
      case CompareTask.punctAssist:
        final sugs = r.suggestions!;
        if (sugs.isEmpty) return const Text('（无候选）', style: TextStyle(fontSize: 11));
        return Wrap(
          spacing: 6,
          runSpacing: 2,
          children: [
            for (var i = 0; i < sugs.length; i++)
              Text(
                '${sugs[i].text}'
                '${sugs[i].reason.isEmpty ? '' : '（${_truncate(sugs[i].reason, 8)}）'}',
                style: TextStyle(
                  fontSize: 11,
                  color: sugs[i].text.trim() == r.reference.trim() &&
                          r.reference.trim().isNotEmpty
                      ? Colors.green.shade700
                      : Colors.grey.shade700,
                ),
              ),
            if (r.trace.imageDropped)
              Text(
                '· 模型不支持图像，仅按上下文',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              ),
          ],
        );
      case CompareTask.lineDecision:
        final d = r.lineDecision!;
        return Text(
          '「${_truncate(d.lineText, 24)}」 conf ${d.confidence.toStringAsFixed(2)}'
          '${d.eligible ? ' · 可采纳' : ' · 低于 0.80 不采纳'}'
          '${r.referenceConfirmed ? ' · 基准已人工确认 ✓' : ''}',
          style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
        );
      case CompareTask.boxDiagnosis:
        final diag = r.boxDiagnosis!;
        if (diag.lineOk) {
          return Text(
            'line_ok · conf ${diag.confidence.toStringAsFixed(2)}',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
          );
        }
        return Text(
          diag.issues
              .map((i) => '${issueTypeLabel(i.type)}@${_diagPosLabel(i.pos)}'
                  '${i.note.isEmpty ? '' : '（${_truncate(i.note, 8)}）'}')
              .join(' · '),
          style: TextStyle(fontSize: 11, color: Colors.orange.shade900),
        );
    }
  }

  /// 「AI 过程」对话框：一次调用的完整输入与输出——模型看到的图像、
  /// 读到的提示词、思考过程（开启开关时）、原始返回、解析后的决定。
  /// 整行三步闭环任务带阶段溯源（分析/修复/复核逐阶段渲染图组与判定）。
  Future<void> _showAiProcess(CompareRunResult r) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 780, maxHeight: 680),
          child: r.stages.isNotEmpty
              ? _AiStagesDialog(result: r)
              : _AiProcessDialog(result: r),
        ),
      ),
    );
  }

  Widget _tracePanel(CompareRunResult r) {
    final lines = <String>[
      '── 模型：${r.trace.model} · 耗时 ${_fmtMs(r.trace.elapsedMs)} ──',
      '── Prompt（发给模型的完整文字）──',
      r.trace.prompt,
      if (r.trace.imageBase64 != null) '（本次附图像，点「AI 过程」可看大图）',
      '── 模型思考过程 ──',
      r.trace.thinking.isEmpty ? '（未开启「记录思考过程」或该模型未输出思维链）' : r.trace.thinking,
      '── 模型原始返回 ──',
      r.trace.rawContent.isEmpty ? '（调用失败，无返回）' : r.trace.rawContent,
    ];
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF101418),
        borderRadius: BorderRadius.circular(8),
      ),
      constraints: const BoxConstraints(maxHeight: 260),
      // 裸 Scrollbar 没有 ScrollPosition 时 paint 直接崩整页（结果行
      // 展开瞬间就触发）——改用项目防崩组件 AttachedScrollbar。
      child: _TracePanelView(
        child: SelectableText(
          lines.join('\n'),
          style: const TextStyle(
            fontSize: 11,
            height: 1.5,
            fontFamily: 'monospace',
            color: Color(0xFFC9D4DC),
          ),
        ),
      ),
    );
  }

  // ── 批量统计 ──

  Widget _batchSummaryCard() {
    final summaries = summarizeByTask(_batchResults);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.leaderboard, size: 20),
                const SizedBox(width: 8),
                const Text('批量统计', style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                Text(
                  '${_batchResults.length} 次调用',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '首个调用含模型冷加载耗时；排名按主指标（同分看平均耗时）。',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
            for (final s in summaries) ...[
              const SizedBox(height: 10),
              Text(
                '${s.task.label}（${s.results.length} 次）',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              for (var i = 0; i < s.rows.length; i++) _rankRow(i, s.rows[i]),
              ExpansionTile(
                visualDensity: VisualDensity.compact,
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('逐条明细', style: TextStyle(fontSize: 12)),
                children: [
                  for (final r in s.results)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${r.modelLabel} · ${r.pageLabel} 行${r.charOrder >= 0 ? '第 ${r.charOrder + 1} 字' : ''}'
                                  ' ${r.referenceConfirmed ? '✓' : ''}「${_truncate(r.reference, 8)}」'
                                  '${r.ok ? ' → ${_batchOutcome(r)}' : ' → 失败：${_truncate(r.error ?? '', 30)}'}',
                              style: TextStyle(
                                fontSize: 11,
                                color: r.ok ? Colors.grey.shade700 : Colors.red.shade700,
                              ),
                            ),
                          ),
                          SizedBox(
                            height: 22,
                            child: TextButton(
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 4),
                                minimumSize: Size.zero,
                                textStyle: const TextStyle(fontSize: 10),
                              ),
                              onPressed: () => _showAiProcess(r),
                              child: const Text('过程'),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _batchOutcome(CompareRunResult r) {
    switch (r.task) {
      case CompareTask.charAssist:
      case CompareTask.punctAssist:
        final hit = r.hitRank;
        return hit == null ? '未命中' : '✓第$hit';
      case CompareTask.lineDecision:
        return '「${_truncate(r.lineDecision!.lineText, 12)}」'
            ' 差异${((r.diffRate ?? 1) * 100).toStringAsFixed(0)}%';
      case CompareTask.boxDiagnosis:
        final diag = r.boxDiagnosis!;
        return diag.lineOk ? 'line_ok' : '问题×${diag.issues.length}';
    }
  }

  Widget _rankRow(int rank, CompareModelRow row) {
    final color = rank == 0 ? Colors.amber.shade800 : Colors.grey.shade600;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(
            rank == 0 ? Icons.star : Icons.circle_outlined,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 6),
          Expanded(
            flex: 4,
            child: Text(
              row.modelLabel,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: rank == 0 ? color : null),
            ),
          ),
          Expanded(
            flex: 6,
            child: Text(
              '${row.primaryMetricLabel} ${row.primaryMetricText} · 均 ${_fmtMs(row.avgElapsedMs.round())}'
              ' · ${row.samples} 样本${row.errors > 0 ? ' · ${row.errors} 失败' : ''}',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
            ),
          ),
        ],
      ),
    );
  }

  // ── 管线协作 ──

  Widget _pipelineCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.account_tree_outlined, size: 20),
                SizedBox(width: 8),
                Text('识别管线：AI 怎样配合 YOLO / OpenCV', style: TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 8),
            for (final s in _pipelineStages) _stageRow(s),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed: _debugLoading || _project == null
                      ? null
                      : _generateDebugImages,
                  icon: _debugLoading
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.image_search, size: 18),
                  label: const Text('生成整页切分调试图'),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '对当前页重跑 /segment（较慢）：绿框=行、蓝框=字，'
                    '即 ② 阶段 YOLO/投影的输出；mask 图即 ① 阶段二值化结果。',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                ),
              ],
            ),
            if (_debugError != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _debugError!,
                  style: TextStyle(fontSize: 12, color: Colors.red.shade700),
                ),
              ),
            if (_debugImage != null || _maskImage != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (_debugImage != null)
                      _debugImageTile(_debugImage!, '切分叠加图（绿行框/蓝字框）'),
                    if (_maskImage != null)
                      _debugImageTile(_maskImage!, '二值化墨迹 mask'),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            ExpansionTile(
              visualDensity: VisualDensity.compact,
              tilePadding: EdgeInsets.zero,
              title: const Text('后端控制台（实时日志：[diag:yolo] / [line-rec] 等）',
                  style: TextStyle(fontSize: 12)),
              children: const [
                SizedBox(height: 220, child: BackendConsolePanel()),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _debugImageTile(String path, String label) {
    final file = File(path);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
            child: Image.file(
              file,
              height: 140,
              errorBuilder: (_, error, stackTrace) => Container(
                height: 140,
                width: 200,
                color: Colors.grey.shade200,
                alignment: Alignment.center,
                child: Text('图片不存在', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              ),
            ),
        ),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
      ],
    );
  }

  Widget _stageRow((IconData, Color, String, String, String) stage) {
    final (icon, color, engine, title, desc) = stage;
    final isAi = engine == 'Ollama';
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: isAi
            ? Colors.deepPurple.withValues(alpha: 0.08)
            : Colors.grey.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
        border: isAi ? Border.all(color: Colors.deepPurple.withValues(alpha: 0.4)) : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        engine,
                        style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (isAi) ...[
                      const SizedBox(width: 6),
                      Text(
                        '← 本页对比在这里发生',
                        style: TextStyle(fontSize: 10, color: Colors.deepPurple.shade700),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  desc,
                  style: TextStyle(fontSize: 11, height: 1.5, color: Colors.grey.shade700),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 五阶段管线卡内容：(图标, 徽章色, 引擎名, 标题, 说明)。
const List<(IconData, Color, String, String, String)> _pipelineStages = [
  (
    Icons.crop_free,
    Color(0xFF1565C0),
    'OpenCV',
    '① 页面预处理',
    '拉平/去透印/锐化（PyMuPDF + OpenCV），产出二值化墨迹 mask——'
    '后面所有切分都基于这份 mask。',
  ),
  (
    Icons.grid_on,
    Color(0xFF2E7D32),
    'YOLO + OpenCV',
    '② 版面与字框检测',
    '自训 YOLO char_det 检测单字框并聚成行，region_det/paragraph_det '
    '补主区/段落层级；检测不可用时 OpenCV 投影切分兜底。',
  ),
  (
    Icons.text_fields,
    Color(0xFF8D6E63),
    'Kraken',
    '③ 文字识别',
    'CHAT 识别模型（独立 conda 常驻池）整行序列 + 逐字框双路融合，'
    '逐字置信度（conf）在这一步产生。',
  ),
  (
    Icons.auto_awesome,
    Color(0xFF6A1B9A),
    'Ollama',
    '④ AI 辅助',
    '单字辅助识别 / 整行裁决 / 识别框诊断 / 标点辅助——本页对比的四个'
    '任务都在这一步：AI 拿到的是 ①②③ 的产物（字图、行条图、OCR 文本'
    '与置信度），输出只作候选/裁决建议。',
  ),
  (
    Icons.edit_note,
    Color(0xFF546E7A),
    '编辑器',
    '⑤ 人工校对',
    '确认/改字/墨迹校验；确认后的文本成为下一轮对比的基准（结果里 '
    '带 ✓ 的样本）。',
  ),
];

/// 框诊断问题类型的中文短名。
/// trace 面板的滚动容器：Scrollbar 必须挂到真实 ScrollPosition 才能
/// paint（裸用会抛 "no ScrollPosition attached" 崩整页），这里持有
/// controller 并交给防崩组件 AttachedScrollbar（未挂载帧裸渲染列表）。
class _TracePanelView extends StatefulWidget {
  final Widget child;

  const _TracePanelView({required this.child});

  @override
  State<_TracePanelView> createState() => _TracePanelViewState();
}

class _TracePanelViewState extends State<_TracePanelView> {
  final ScrollController _ctrl = ScrollController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AttachedScrollbar(
      controller: _ctrl,
      child: SingleChildScrollView(
        controller: _ctrl,
        child: widget.child,
      ),
    );
  }
}

/// 「AI 过程」对话框内容：模型看到的图 → 读到的文字 → 思考 → 原始
/// 返回 → 解析后的决定，逐段完整呈现一次 AI 调用的全过程。
class _AiProcessDialog extends StatelessWidget {
  final CompareRunResult r;

  const _AiProcessDialog({required CompareRunResult result}) : r = result;

  @override
  Widget build(BuildContext context) {
    Uint8List? imgBytes;
    final b64 = r.trace.imageBase64;
    if (b64 != null && b64.isNotEmpty) {
      try {
        imgBytes = base64Decode(b64);
      } catch (_) {}
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${r.task.label} · ${r.modelLabel}'
                  ' · ${_fmtMs(r.elapsedMs)}'
                  '${r.trace.imageDropped ? ' · 未看图' : ''}',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _section(
                  '① 模型看到的图像',
                  Icons.image_outlined,
                  _imageSection(context, imgBytes),
                ),
                _section(
                  '② 模型读到的文字（提示词全文）',
                  Icons.notes_outlined,
                  _monoBox(r.trace.prompt.isEmpty ? '（空）' : r.trace.prompt),
                ),
                _section(
                  '③ 模型思考过程',
                  Icons.psychology_outlined,
                  r.trace.thinking.isEmpty
                      ? _hintBox('（未开启「记录思考过程」，或该模型没有输出思维链——'
                          '非推理型模型没有思考过程；结构化的理由见下方"解析后的决定"）')
                      : _monoBox(r.trace.thinking, color: Colors.deepPurple),
                ),
                _section(
                  '④ 模型原始返回',
                  Icons.terminal_outlined,
                  _monoBox(
                    r.trace.rawContent.isEmpty ? '（调用失败，无返回）' : r.trace.rawContent,
                    dark: true,
                  ),
                ),
                _section('⑤ 解析后的决定', Icons.gavel_outlined, _decisionSection()),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _section(String title, IconData icon, Widget child) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: Colors.grey.shade700),
              const SizedBox(width: 5),
              Text(
                title,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }

  /// 输入图预览：点击放大；imageDropped 时说明模型实际没看图。
  Widget _imageSection(BuildContext context, Uint8List? imgBytes) {
    if (imgBytes == null) {
      return _hintBox(
        '本次调用未附图像——标点辅助是纯上下文任务；单字辅助/整行裁决/'
        '识别框诊断未附图则说明行条裁图失败，已退化为纯上下文作答。',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (r.trace.imageDropped)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _hintBox(
              '该模型不支持图像输入：带图请求被拒后已自动去图、只按上下文'
              '作答——下面是你准备发给它的图，模型实际没有看到。',
              color: Colors.orange,
            ),
          ),
        GestureDetector(
          onTap: () => _showZoomImage(context, imgBytes),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Container(
              constraints: const BoxConstraints(maxHeight: 300),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Image.memory(
                imgBytes,
                fit: BoxFit.contain,
                gaplessPlayback: true,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '（点图放大）',
          style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
        ),
      ],
    );
  }

  void _showZoomImage(BuildContext context, Uint8List bytes) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: InteractiveViewer(
          maxScale: 8,
          child: Image.memory(bytes, gaplessPlayback: true),
        ),
      ),
    );
  }

  Widget _monoBox(String text, {Color? color, bool dark = false}) {    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 240),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: dark
            ? const Color(0xFF101418)
            : (color ?? Colors.grey).withValues(alpha: dark ? 1 : 0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: SingleChildScrollView(
        child: SelectableText(
          text,
          style: TextStyle(
            fontSize: 11.5,
            height: 1.55,
            color: dark ? const Color(0xFFC9D4DC) : Colors.grey.shade900,
          ),
        ),
      ),
    );
  }

  Widget _hintBox(String text, {Color? color}) {
    final c = color ?? Colors.grey;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11.5, height: 1.5, color: c.withValues(alpha: 0.9)),
      ),
    );
  }

  /// 解析后的决定：按任务展示结构化结论与模型给的理由。
  Widget _decisionSection() {
    if (!r.ok) {
      return _hintBox('调用失败：${r.error ?? ''}', color: Colors.red);
    }
    switch (r.task) {
      case CompareTask.charAssist:
      case CompareTask.punctAssist:
        final sugs = r.suggestions ?? const <OllamaSuggestion>[];
        final ref = r.reference.trim();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '基准（应识别出的字）：'
              '${ref.isEmpty ? '（空，无基准）' : '「$ref」'}'
              '${r.referenceConfirmed ? '（已人工确认）' : ''}',
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 6),
            for (var i = 0; i < sugs.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(
                  children: [
                    SizedBox(
                      width: 22,
                      child: Text('${i + 1}.', style: const TextStyle(fontSize: 12)),
                    ),
                    Text(
                      sugs[i].text,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: ref.isNotEmpty && sugs[i].text.trim() == ref
                            ? Colors.green.shade700
                            : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '分数 ${sugs[i].score.toStringAsFixed(2)}'
                      '${sugs[i].reason.isEmpty ? '' : ' · 理由：${sugs[i].reason}'}',
                      style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700),
                    ),
                  ],
                ),
              ),
          ],
        );
      case CompareTask.lineDecision:
        final d = r.lineDecision!;
        final rate = r.diffRate ?? 1.0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '整行输出：「${d.lineText}」',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              '置信度 ${d.confidence.toStringAsFixed(2)} · 与基准差异 '
              '${(rate * 100).toStringAsFixed(1)}%'
              '${d.eligible ? ' · 达到采纳阈值（≥0.80）' : ' · 低于采纳阈值，不采纳'}',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
            if (d.items.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                '逐字判断（模型给的理由）：',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
              for (final it in d.items)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '第 ${it.order + 1} 字「${it.text}」conf '
                    '${it.confidence.toStringAsFixed(2)}'
                    '${it.reason.isEmpty ? '' : ' · ${it.reason}'}'
                    '${it.punctuation ? ' · 标点' : ''}',
                    style: const TextStyle(fontSize: 11.5),
                  ),
                ),
            ],
          ],
        );
      case CompareTask.boxDiagnosis:
        final diag = r.boxDiagnosis!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              diag.lineOk ? 'line_ok：模型认为本行切字框没有问题' : '发现 ${diag.issues.length} 个问题：',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: diag.lineOk ? Colors.green.shade700 : Colors.orange.shade800,
              ),
            ),
            for (final i in diag.issues)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  '· ${issueTypeLabel(i.type)} @ ${i.pos == 0 ? '整行' : '第 ${i.pos} 框'}'
                  '${i.note.isEmpty ? '' : '（${i.note}）'}',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
          ],
        );
    }
  }
}

String issueTypeLabel(OllamaBoxIssueType t) => switch (t) {
  OllamaBoxIssueType.mergeTwoLines => '应拆双列',
  OllamaBoxIssueType.charMerged => '一字粘两字',
  OllamaBoxIssueType.charClipped => '切字不全',
  OllamaBoxIssueType.charExtraInk => '多包墨迹',
  OllamaBoxIssueType.missingChars => '漏字',
};

/// 整行三步闭环的「AI 过程」对话框：逐阶段渲染三步分析 → YOLO 局部
/// 修复 → AI 复核的全部记录（图组、prompt、思维链、原始返回、门槛
/// 判定、写入 diff、修复前后），与正式识别完全同口径。
class _AiStagesDialog extends StatelessWidget {
  final CompareRunResult r;

  const _AiStagesDialog({required CompareRunResult result}) : r = result;

  @override
  Widget build(BuildContext context) {
    final assistCount = r.stages.where(
      (e) => e.stage == AiTraceStage.assist || e.stage == AiTraceStage.reverify,
    ).length;
    final repairCount = r.stages
        .where((e) => e.stage == AiTraceStage.repair && e.repair != null)
        .length;
    final repaired = r.stages.any(
      (e) => e.stage == AiTraceStage.repair && e.repair != null && e.repair!.adopted,
    );
    final repairSummary = repairCount > 0
        ? '｜修复 $repairCount 次${repaired ? '（已采纳）' : '（未采纳）'}'
        : '';
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${r.task.label} · ${r.modelLabel} · ${_fmtMs(r.elapsedMs)}'
                  '｜分析/复核 $assistCount 次$repairSummary',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final entry in r.stages)
                  AiTraceEntryView(
                    entry: entry,
                    imageLoader: (file) async =>
                        r.stageStore?.imageBytesOf(file),
                    initiallyExpanded: true,
                  ),
                if (r.stages.isEmpty) const Text('（无阶段记录）'),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ── 画布画框 ──

class _BoxesPainter extends CustomPainter {
  _BoxesPainter({
    required this.ann,
    required this.level,
    required this.fit,
    required this.selRegionId,
    required this.selParaId,
    required this.selLineId,
    required this.selCharId,
  });

  final PageAnnotation? ann;
  final _ViewLevel level;
  final (double, double, double) Function(Size viewport) fit;
  final String? selRegionId;
  final String? selParaId;
  final String? selLineId;
  final String? selCharId;

  @override
  void paint(Canvas canvas, Size size) {
    final ann = this.ann;
    if (ann == null) return;
    final (scale, dx, dy) = fit(size);

    void drawBox(int x, int y, int w, int h, bool selected, Color color,
        {String? label}) {
      final rect = Rect.fromLTWH(
        x * scale + dx,
        y * scale + dy,
        w * scale,
        h * scale,
      );
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = selected ? 3 : 1.4
        ..color = selected ? Colors.red : color;
      if (selected) {
        canvas.drawRect(
          rect,
          Paint()
            ..style = PaintingStyle.fill
            ..color = Colors.red.withValues(alpha: 0.15),
        );
      }
      canvas.drawRect(rect, paint);
      if (label != null) {
        final tp = TextPainter(
          text: TextSpan(
            text: label,
            style: TextStyle(
              fontSize: math.max(9, 10 * math.min(1, scale * 2)),
              color: selected ? Colors.red : color,
              fontWeight: FontWeight.w600,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, rect.topLeft.translate(1, -tp.height - 1));
      }
    }

    switch (level) {
      case _ViewLevel.region:
        for (var i = 0; i < ann.mainRegions.length; i++) {
          final r = ann.mainRegions[i];
          drawBox(r.x, r.y, r.w, r.h, r.id == selRegionId, Colors.amber.shade800,
              label: '主区 ${i + 1}');
        }
      case _ViewLevel.paragraph:
        for (var i = 0; i < ann.paragraphs.length; i++) {
          final r = ann.paragraphs[i];
          drawBox(r.x, r.y, r.w, r.h, r.id == selParaId, Colors.blue.shade700,
              label: '段 ${i + 1}');
        }
      case _ViewLevel.line:
        for (var i = 0; i < ann.lines.length; i++) {
          final l = ann.lines[i];
          drawBox(l.x, l.y, l.w, l.h, l.id == selLineId, Colors.green.shade700,
              label: '${i + 1}');
        }
      case _ViewLevel.char:
        for (final line in ann.lines) {
          for (final c in line.chars) {
            drawBox(c.x, c.y, c.w, c.h, c.id == selCharId, Colors.deepPurple);
          }
        }
    }
  }

  @override
  bool shouldRepaint(_BoxesPainter old) =>
      old.ann != ann ||
      old.level != level ||
      old.selRegionId != selRegionId ||
      old.selParaId != selParaId ||
      old.selLineId != selLineId ||
      old.selCharId != selCharId ||
      old.fit != fit;
}

// ── 小工具 ──

String _fmtMs(int ms) =>
    ms >= 1000 ? '${(ms / 1000).toStringAsFixed(1)}s' : '$ms ms';

String _truncate(String s, int max) {
  final t = s.trim();
  if (t.runes.length <= max) return t;
  return '${String.fromCharCodes(t.runes.take(max))}…';
}
