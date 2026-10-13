import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/models.dart';
import '../models/page_quad.dart';
import '../services/char_stats.dart';
import '../services/python_service.dart';
import '../services/recognition_queue.dart';
import '../services/storage.dart';
import 'straighten_page.dart';

export 'straighten_page.dart' show StraightenPageTarget;

/// 批量摆正（新建任务流水线步骤，也可从书籍卡片随时进入断点续作）：
/// 智能检测裁切点并拉平输出到 warped/（保留源图），结果网格里可
/// 预览每页矫正效果、点「修改」单页微调、按页选择使用矫正图或原图。
/// 多页按机器配置并行处理（后端 /deskew_sizing 按 CPU/内存决策并行数，
/// 纯 CPU OpenCV 端点可真并行），每页完成即刷新网格并落盘。
///
/// - **断点续作**：处理状态（裁切框/判定/增强设置/确认标记）持久化在
///   `straighten_state.json`，每页处理完即落盘；中途退出后再进入只补
///   剩余页，已处理页不动。
/// - **确认/删除**：网格卡片可「确认」该页（默认从列表隐藏，顶部开关
///   控制显示）与「删除该页」（永久删除图片/矫正图/标注，不可恢复）。
/// - 自动跳过：检测判定页面已贴满且平直（needs_warp=false）的页不重
///   采样，除非要求去透印/去色/锐化（此时产出≈原图的增强副本）。
/// - 「完成」把使用矫正图的选择落到 project.imageFiles；直接退出不
///   改动页面列表，选择保留在状态文件里下次继续。
class StraightenBatchPage extends StatefulWidget {
  const StraightenBatchPage({super.key, required this.project});

  final Project project;

  @override
  State<StraightenBatchPage> createState() => _StraightenBatchPageState();
}

enum _PageStatus { pending, running, done, skipped, failed }

/// 检测算法版本：算法行为变化时递增。状态里版本过期的页在下次进入时
/// 自动重新检测（旧版检测的框可能切边，断点续作不能永远沿用）。
const int _detectAlgoVersion = 3;

/// 批量页缩略图按路径 LRU（页面是 200DPI 大图，只降采样解码小容量缓存）。
final LinkedHashMap<String, ui.Image> _batchThumbCache = LinkedHashMap();
const int _batchThumbMax = 64;

class _PagePlan {
  _PagePlan({
    required this.index,
    required this.sourcePath,
    required this.outPath,
  });

  /// 本书页面列表中的位置（删页后会整体前移，故可变）。
  int index;

  /// 摆正处理的源图（永远指向未经摆正的原始页面文件）。
  final String sourcePath;

  /// 矫正结果输出路径（由源文件相对路径推导，与页序无关，删页不漂移）。
  final String outPath;

  PageQuad? quad;

  /// 检测判定该页是否需要拉平（≈整图的页 false）。
  bool? needsWarp;

  /// 产出该框时的检测算法版本（过期则重检，见 [_detectAlgoVersion]）。
  int detectAlgo = 0;

  _PageStatus status = _PageStatus.pending;
  bool useWarped = false;
  bool confirmed = false;

  /// 合成页（多页拼接产出）：矫正图是拼接结果而非源图拉平——后续
  /// 「修改」直接编辑矫正图（源图与 quad 不再对应），也不再参与
  /// 自动重做（增强设置变更不重拼，源图已不含全部内容）。
  bool merged = false;

  /// 该页矫正文件当前使用的增强设置（开关变更后据此找出需重做的页）。
  bool doneGrayscale = false;
  bool doneSharpen = false;
  bool doneDebleed = false;
  int doneDebleedStrength = 50;

  /// 输出文件的重写代数：手动修改会覆盖同一路径的 warped 文件，缩略图
  /// 缓存按路径命中、感知不到文件内容变化——stamp 变化让卡片以新 key
  /// 重建缩略图并重新解码（否则一直显示旧图，"调整了却没变化"）。
  int stamp = 0;

  bool get warpedReady => status == _PageStatus.done;

  Map<String, dynamic> toStateJson() => {
    'quad': quad?.cornersJson(),
    'needs_warp': needsWarp,
    'detect_algo': detectAlgo,
    'use_warped': useWarped,
    'confirmed': confirmed,
    'merged': merged,
    'done_gray': doneGrayscale,
    'done_sharp': doneSharpen,
    'done_debleed': doneDebleed,
    'done_debleed_strength': doneDebleedStrength,
    'out_path': outPath,
  };

  void applyStateJson(Map<String, dynamic> j) {
    final quadJson = j['quad'] as List?;
    if (quadJson != null && quadJson.length == 4) {
      quad = PageQuad.fromPoints(
        quadJson
            .map(
              (pt) => List<double>.from(
                (pt as List).map((e) => (e as num).toDouble()),
              ),
            )
            .toList(),
      );
    }
    needsWarp = j['needs_warp'] as bool?;
    detectAlgo = j['detect_algo'] as int? ?? 0;
    useWarped = j['use_warped'] as bool? ?? false;
    confirmed = j['confirmed'] as bool? ?? false;
    merged = j['merged'] as bool? ?? false;
    doneGrayscale = j['done_gray'] as bool? ?? false;
    doneSharpen = j['done_sharp'] as bool? ?? false;
    doneDebleed = j['done_debleed'] as bool? ?? false;
    doneDebleedStrength = j['done_debleed_strength'] as int? ?? 50;
  }
}

class _StraightenBatchPageState extends State<StraightenBatchPage> {
  final Map<String, _PagePlan> _plans = {};
  bool _grayscale = false;
  bool _sharpen = false;

  /// 去透印（把背面/下一页透出的浅色文字压成纸白）及强度 1..100。
  bool _debleed = false;
  int _debleedStrength = 50;
  bool _hideConfirmed = true;
  bool _running = false;
  bool _finishing = false;
  int _runDone = 0;
  int _runTotal = 0;

  /// 本趟并行 worker 数（后端按硬件决策，见 [_processPass]）。
  int _workers = 1;

  /// 正在处理中的页（进度行展示用；完成即移除）。
  final List<_PagePlan> _inflight = [];
  bool _cancelRequested = false;

  /// 并行 worker 共用的状态落盘队列：串行化写入（tmp→rename 的原子
  /// 替换要求同一时刻只有一笔写入，并发会互相覆盖 tmp 写坏状态）。
  Future<void> _saveQueue = Future.value();

  List<_PagePlan> get _ordered =>
      (_plans.values.toList()..sort((a, b) => a.index.compareTo(b.index)));

  /// 进度行上的"正在处理"摘要：前几页的页号 + 总在途数（并行时不止一页）。
  String get _inflightLabel {
    if (_inflight.isEmpty) return '';
    final shown = _inflight
        .take(3)
        .map((pl) => '第 ${pl.index + 1} 页')
        .join('、');
    return _inflight.length > 3 ? '$shown 等${_inflight.length}页' : shown;
  }

  File get _stateFile =>
      File(p.join(widget.project.projectDir, 'straighten_state.json'));

  @override
  void initState() {
    super.initState();
    _buildPlansFromImageFiles();
    // 状态恢复 + 断点续作要等首帧结束后再启动：_runAll 会 showDialog，
    // 其内部 debugCheckHasMaterialLocalizations 走 dependOnInheritedWidget
    // OfExactType（_LocalizationsScope），在 initState 完成前调用直接抛
    // FlutterError。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_bootstrap());
    });
  }

  /// 从当前页面列表建计划（outPath 由源文件相对路径推导，删页不漂移）；
  /// 源文件的真实指向在状态恢复时修正（页面文件可能已被「完成」换成
  /// warped/ 矫正图）。
  void _buildPlansFromImageFiles() {
    final project = widget.project;
    _plans.clear();
    for (var i = 0; i < project.imageFiles.length; i++) {
      final f = project.imageFiles[i];
      _plans[f] = _PagePlan(
        index: i,
        sourcePath: f,
        outPath: _warpedNameFor(f),
      );
    }
  }

  /// 源图 → 矫正图输出路径：warped/ 下按"源文件相对路径"命名（目录
  /// 分隔符换下划线），同源永远同名——删页/重排不影响映射。
  String _warpedNameFor(String source) {
    final project = widget.project;
    String rel;
    try {
      rel = p.relative(source, from: project.projectDir);
    } catch (_) {
      rel = p.basename(source);
    }
    final name = p.setExtension(rel, '.png').replaceAll(RegExp(r'[/\\]'), '_');
    return p.join(project.projectDir, 'warped', name);
  }

  /// 恢复持久化状态并把计划重指回真实源文件。
  Future<void> _restoreState() async {
    Map<String, dynamic> data;
    try {
      if (!await _stateFile.exists()) return;
      data =
          jsonDecode(await _stateFile.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return; // 状态文件损坏按无状态处理（各页重新检测）。
    }
    _grayscale = data['grayscale'] as bool? ?? false;
    _sharpen = data['sharpen'] as bool? ?? false;
    _debleed = data['debleed'] as bool? ?? false;
    _debleedStrength = data['debleed_strength'] as int? ?? 50;
    _hideConfirmed = data['hide_confirmed'] as bool? ?? true;
    final pages = data['pages'] as Map<String, dynamic>? ?? {};
    for (final plan in _plans.values.toList()) {
      dynamic entry = pages[plan.sourcePath];
      String sourceKey = plan.sourcePath;
      if (entry == null) {
        // 当前页面文件可能是「完成」时换上的矫正图：按 out_path 反查源。
        for (final e in pages.entries) {
          if ((e.value['out_path'] ?? '') == plan.sourcePath) {
            entry = e.value;
            sourceKey = e.key;
            break;
          }
        }
      }
      if (entry is! Map<String, dynamic>) continue;
      late final _PagePlan pl;
      if (sourceKey != plan.sourcePath) {
        // 重指回真实源文件（outPath 用状态里的稳定路径）。
        pl = _PagePlan(
          index: plan.index,
          sourcePath: sourceKey,
          outPath: entry['out_path'] as String? ?? plan.outPath,
        );
        _plans.remove(plan.sourcePath);
        _plans[sourceKey] = pl;
      } else {
        pl = plan;
      }
      pl.applyStateJson(entry);
      // 检测算法版本过期（旧版检测的框可能切边）：丢弃旧框，重新检测。
      if (pl.detectAlgo != _detectAlgoVersion) {
        pl.quad = null;
        pl.needsWarp = null;
      }
      pl.status = pl.merged
          ? _PageStatus.done // 合成页：拼接结果已在盘上
          : pl.quad == null
          ? _PageStatus.pending
          : (pl.needsWarp == false &&
                    !pl.doneGrayscale &&
                    !pl.doneSharpen &&
                    !pl.doneDebleed
                ? _PageStatus.skipped
                : _PageStatus.done);
    }
    if (mounted) setState(() {});
  }

  /// 该页在本书页面列表中的位置：「完成」之后列表里存的是矫正图路径，
  /// 按源路径找不到时要再按矫正图路径找（两处删除共用；找不到返回 -1）。
  int _imageFileIndexOf(_PagePlan plan) {
    final files = widget.project.imageFiles;
    var i = files.indexOf(plan.sourcePath);
    if (i < 0) i = files.indexOf(plan.outPath);
    return i;
  }

  /// 结构性变更（删页）后重建计划：状态已落盘，按当前页面列表重读。
  Future<void> _rebuildPlans() async {
    _buildPlansFromImageFiles();
    await _restoreState();
    if (mounted) setState(() {});
  }

  Future<void> _bootstrap() async {
    await _restoreState();
    if (!mounted) return;
    unawaited(_runAll());
  }

  /// 串行化的状态落盘：调用方直接 await；内部按到达顺序排队写入。
  Future<void> _saveState() {
    final task = _saveQueue.then((_) => _writeStateFile());
    // 队列链吞掉失败（失败已记日志），不让一笔失败堵死后续写入。
    _saveQueue = task.then((_) {}, onError: (_) {});
    return task;
  }

  Future<void> _writeStateFile() async {
    try {
      final data = {
        'grayscale': _grayscale,
        'sharpen': _sharpen,
        'debleed': _debleed,
        'debleed_strength': _debleedStrength,
        'hide_confirmed': _hideConfirmed,
        'pages': {
          for (final plan in _plans.values) plan.sourcePath: plan.toStateJson(),
        },
      };
      final tmp = File('${_stateFile.path}.tmp');
      await tmp.writeAsString(jsonEncode(data));
      await tmp.rename(_stateFile.path);
    } catch (e) {
      PythonService.addAppLog('[批量摆正] 状态保存失败：$e', isError: true);
    }
  }

  /// 该页是否需要（重）处理：未检测过，或增强设置与已产出文件不一致。
  /// 合成页（拼接产出）永远不需要——源图已不含全部内容，重做会覆盖
  /// 拼接结果；增强设置变更也跳过它。
  bool _needProcess(_PagePlan plan) =>
      !plan.merged &&
      (plan.quad == null ||
          plan.doneGrayscale != _grayscale ||
          plan.doneSharpen != _sharpen ||
          plan.doneDebleed != _debleed ||
          plan.doneDebleedStrength != _debleedStrength);

  // ── 自动批量处理（后台运行；断点续作：只处理需要处理的页）──
  //
  // 不弹模态进度框：处理在后台按 worker 池并行进行（并行数进趟时向
  // 后端 /deskew_sizing 要一次硬件决策：CPU 物理核/可用内存，环境变量
  // OCR_DEWARP_WORKERS 可覆盖），网格全程可操作（修改/预览/确认/删除
  // 并行）。顶部内嵌进度条 + 每张卡片的状态角标实时反映；「停止」
  // 不再派发新页、进行中的页处理完即停，进度已逐页落盘。

  Future<void> _runAll() async {
    if (_running) return;
    _running = true;
    _cancelRequested = false;
    try {
      // 多趟循环：一趟处理当前全部待办；趟内用户改了增强设置或新页
      // 进入编辑等情况，趟末还有待办就再来一趟，直到无待办或被取消。
      while (mounted && !_cancelRequested) {
        final todo = _ordered
            .where((x) => _needProcess(x) && x.status != _PageStatus.failed)
            .toList();
        if (todo.isEmpty) break;
        await _processPass(todo);
      }
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
            });
      }
    }
  }

  Future<void> _processPass(List<_PagePlan> todo) async {
    _runTotal = todo.length;
    _runDone = 0;
    _inflight.clear();
    // 并行度：每趟开始时问一次后端（本机硬件不变，一趟内复用；请求
    // 失败由 deskewSizing 内部保守回退，不会中断批量流程）。
    final sizing = await PythonService.deskewSizing();
    final workers = max(
      1,
      min((sizing['workers'] as num? ?? 1).toInt(), todo.length),
    );
    _workers = workers;
    PythonService.addAppLog(
      '[批量摆正] 后台处理 ${todo.length} 页 · 并行 $workers'
      '${_grayscale ? '（去色）' : ''}${_sharpen ? '（锐化）' : ''}'
      '${_debleed ? '（去透印$_debleedStrength）' : ''}'
      '（${sizing['reason']}）',
    );
    var failed = 0;
    // 共享取页游标：Dart 单 isolate，async 之间不会真正同时执行，
    // 普通变量即可，无需加锁。
    var next = 0;

    /// 单个 worker：循环从待办里取页处理，直到取完/取消/页面销毁。
    Future<void> workerLoop() async {
      while (mounted && !_cancelRequested) {
        if (next >= todo.length) break;
        final plan = todo[next++];
        // 页被删除/重建后计划已不在册：跳过（deleted 计划是悬空引用）。
        if (_plans[plan.sourcePath] != plan) continue;
        // 排队期间已被「修改」会话等路径解决的页：不再重做。
        if (!_needProcess(plan)) continue;
        final ok = await _processOne(plan);
        if (!ok) failed++;
      }
    }

    await Future.wait([
      for (var i = 0; i < workers; i++) workerLoop(),
    ]);
    _inflight.clear();

    final okCount = _ordered.where((x) => x.warpedReady).length;
    final skipCount = _ordered
        .where((x) => x.status == _PageStatus.skipped)
        .length;
    PythonService.addAppLog(
      '[批量摆正] 本趟结束：$okCount 页已矫正，$skipCount 页无需摆正，'
      '$failed 页需手动处理',
    );
    // 不弹「N 页自动摆正失败」消息条：失败卡片有红色「需手动」角标、
    // 详情在应用日志，底部消息条只会盖住最下排卡片的按钮（与删除
    // 消息条同批移除，用户反馈挡操作）。
  }

  /// 处理单页（检测 → 拉平/跳过 → 落盘）。返回是否成功；失败只标记
  /// 本页，不影响并行中的其他页。由 worker 池并发调用。
  Future<bool> _processOne(_PagePlan plan) async {
    _inflight.add(plan);
    if (mounted) setState(() => plan.status = _PageStatus.running);
    var ok = true;
    try {
      // 检测只做一次（重跑沿用已存的框与判定，换增强设置不重测）。
      if (plan.quad == null) {
        final detect = await PythonService.detectPageQuad(
          imagePath: plan.sourcePath,
        );
        final points = (detect['points'] as List)
            .map(
              (pt) => List<double>.from(
                (pt as List).map((e) => (e as num).toDouble()),
              ),
            )
            .toList();
        plan.quad = PageQuad.fromPoints(points);
        plan.needsWarp = detect['needs_warp'] != false;
        plan.detectAlgo = _detectAlgoVersion;
        // 每页一条检测日志：这页的智能边框是怎样判定的（进「修改」后
        // 底栏「检测日志」可看同一份数据的完整展示）。
        final trace = detect['trace'] as Map<String, dynamic>?;
        if (trace != null) {
          PythonService.addAppLog(
            '[批量摆正·检测] 第 ${plan.index + 1} 页：'
            '${StraightenPage.traceSummary(trace)}',
          );
        }
      }
      if (plan.needsWarp == false &&
          !_grayscale &&
          !_sharpen &&
          !_debleed) {
        // 页面平直贴满且无增强需求：用原图，不写 warped 文件。
        plan.status = _PageStatus.skipped;
        plan.useWarped = false;
      } else {
        // 需要拉平，或页边无信号但要求增强：产出增强副本
        //（无拉平需求时框≈整图，输出≈原图+增强）。
        await PythonService.dewarpPage(
          imagePath: plan.sourcePath,
          corners: plan.quad!.cornersJson(),
          grayscale: _grayscale,
          sharpen: _sharpen,
          debleed: _debleed,
          debleedStrength: _debleedStrength,
          outPath: plan.outPath,
        );
        FileImage(File(plan.outPath)).evict();
        plan.status = _PageStatus.done;
        plan.useWarped = true;
      }
      plan.doneGrayscale = _grayscale;
      plan.doneSharpen = _sharpen;
      plan.doneDebleed = _debleed;
      plan.doneDebleedStrength = _debleedStrength;
      await _saveState(); // 每页落盘：断点续作（串行化队列，见 _saveState）
    } catch (error) {
      ok = false;
      plan.status = _PageStatus.failed;
      PythonService.addAppLog(
        '[批量摆正] 第 ${plan.index + 1} 页'
        '（${p.basename(plan.sourcePath)}）失败：$error',
        isError: true,
      );
    }
    _inflight.remove(plan);
    _runDone++;
    if (mounted) setState(() {});
    return ok;
  }

  // ── 增强设置 / 单页修改 / 预览 ──

  /// 切换去色/锐化/去透印（含强度）：设置不一致的页自动用新设置重做
  /// （重跑沿用已存的裁切框，不重新检测）；缩略图缓存整体作废，重跑
  /// 完成后卡片刷新。
  Future<void> _toggleEnhancement({
    bool? grayscale,
    bool? sharpen,
    bool? debleed,
    int? debleedStrength,
  }) async {
    setState(() {
      if (grayscale != null) _grayscale = grayscale;
      if (sharpen != null) _sharpen = sharpen;
      if (debleed != null) _debleed = debleed;
      if (debleedStrength != null) _debleedStrength = debleedStrength;
      for (final plan in _plans.values) {
        if (_needProcess(plan)) plan.status = _PageStatus.pending;
      }
      _batchThumbCache.clear();
    });
    PythonService.addAppLog(
      '[批量摆正] 增强设置变更：去色=$_grayscale 锐化=$_sharpen'
      '${_debleed ? ' 去透印=$_debleedStrength' : ' 去透印=关'}，'
      '重做设置不一致的页面',
    );
    await _saveState();
    await _runAll();
  }

  Future<void> _editPage(_PagePlan plan) async {
    if (_finishing) return;
    if (plan.status == _PageStatus.running) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该页正在后台处理，请稍候再修改')),
      );
      return;
    }
    // 会话模式：确认并下一页 / 删除 / 拼接 都在本页内连续进行（host 记账）。
    // 合成页（拼接产出）直接编辑矫正图：源图与 quad 已不对应，编辑
    // 落盘就地覆写矫正图。
    final editMerged = plan.merged && plan.warpedReady;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => StraightenPage(
          imagePath: editMerged ? plan.outPath : plan.sourcePath,
          outPath: plan.outPath,
          initialQuad: editMerged ? null : plan.quad,
          initialGrayscale: _grayscale,
          initialSharpen: _sharpen,
          initialDebleed: _debleed,
          initialDebleedStrength: _debleedStrength,
          pageIndex: plan.index,
          initialConfirmed: plan.confirmed,
          host: _BatchStraightenHost(this),
        ),
      ),
    );
  }

  /// 源路径或矫正图路径定位计划（合成页编辑会话传的是矫正图路径）。
  _PagePlan? _planByAnyPath(String path) {
    final direct = _plans[path];
    if (direct != null) return direct;
    for (final plan in _plans.values) {
      if (plan.outPath == path) return plan;
    }
    return null;
  }

  /// 会话宿主记账：某页的矫正文件已写出（StraightenPage 内部完成写盘）。
  void _applyPlanResult(
    String sourcePath,
    PageQuad quad, {
    required bool grayscale,
    required bool sharpen,
    required bool debleed,
    required int debleedStrength,
    required bool confirmed,
  }) {
    final plan = _planByAnyPath(sourcePath);
    if (plan == null) return;
    plan.quad = quad;
    plan.detectAlgo = _detectAlgoVersion;
    plan.confirmed = confirmed;
    plan.doneGrayscale = grayscale;
    plan.doneSharpen = sharpen;
    plan.doneDebleed = debleed;
    plan.doneDebleedStrength = debleedStrength;
    plan.status = _PageStatus.done;
    plan.useWarped = true;
    plan.stamp++;
    _batchThumbCache.remove(plan.outPath);
    FileImage(File(plan.outPath)).evict();
    unawaited(_saveState());
    if (mounted) setState(() {});
  }

  /// 会话宿主删除：按源路径永久删除该页（文件/标注/列表）。
  Future<void> _deletePlanBySource(String sourcePath) async {
    final plan = _plans[sourcePath];
    if (plan == null) return;
    final project = widget.project;
    final i = _imageFileIndexOf(plan);
    if (i < 0) {
      await _rebuildPlans();
      return;
    }
    RecognitionQueue.instance.remove(project.id);
    final currentFile = project.imageFiles[i];
    // 标注页号以源文件 stem 为准（稳定标识；currentFile 换成矫正图后
    // stem 会变，按它推导会删错/漏删标注）。
    final pageId = pageIdForImage(plan.sourcePath, i);
    for (final f in {plan.sourcePath, plan.outPath, currentFile}) {
      try {
        final file = File(f);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
    FileImage(File(currentFile)).evict();
    FileImage(File(plan.outPath)).evict();
    for (final suffix in ['.json', '.json.bak']) {
      try {
        final f = File(
          p.join(project.projectDir, 'annotations', pageId + suffix),
        );
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    project.imageFiles.removeAt(i);
    if (project.recognizedPages > 0) project.recognizedPages -= 1;
    project.lastPageIndex = project.lastPageIndex.clamp(
      0,
      project.imageFiles.isEmpty ? 0 : project.imageFiles.length - 1,
    );
    await ProjectStorage.save(project);
    _plans.remove(plan.sourcePath);
    _batchThumbCache.remove(plan.outPath);
    await _saveState();
    await _rebuildPlans();
    PythonService.addAppLog(
      '[批量摆正] 已永久删除第 ${i + 1} 页（${p.basename(sourcePath)}），'
      '本书剩 ${project.imageFiles.length} 页',
    );
  }

  /// 会话宿主：下一页目标（书序中当前页之后的第一页）。
  StraightenPageTarget? _nextTargetAfter(String sourcePath) {
    final plans = _ordered;
    final pos = plans.indexWhere((x) => x.sourcePath == sourcePath);
    if (pos < 0 || pos + 1 >= plans.length) return null;
    final plan = plans[pos + 1];
    return StraightenPageTarget(
      imagePath: plan.sourcePath,
      outPath: plan.outPath,
      initialQuad: plan.quad,
      pageIndex: plan.index,
      confirmed: plan.confirmed,
    );
  }

  /// 会话宿主：拼入页候选（书序中除当前页外的全部页）。
  List<StraightenPageTarget> _stitchPartners(String sourcePath) {
    return [
      for (final plan in _ordered)
        if (plan.sourcePath != sourcePath)
          StraightenPageTarget(
            imagePath: plan.sourcePath,
            outPath: plan.outPath,
            initialQuad: plan.quad,
            pageIndex: plan.index,
            confirmed: plan.confirmed,
          ),
    ];
  }

  /// 会话宿主：拼接落账。[stitchedPath] 已由后端写盘（= 当前页 outPath
  /// 覆写）。当前页记为已确认的合成页，拼入页删除；返回继续编辑的
  /// 下一页目标。
  Future<StraightenPageTarget?> _mergePlanResult(
    String sourcePath,
    String partnerSourcePath,
    String stitchedPath,
  ) async {
    final plan = _planByAnyPath(sourcePath);
    final partner = _plans[partnerSourcePath];
    if (plan == null || partner == null) {
      throw StateError('页面状态已变化（页可能已被删除），请重新进入拼接');
    }
    if (partner.status == _PageStatus.running) {
      throw StateError('拼入页正在后台处理，请稍后再拼');
    }
    final partnerIndex = partner.index;
    // 当前页：合成页 = 矫正图（拼接结果已覆写完成）。
    plan.status = _PageStatus.done;
    plan.useWarped = true;
    plan.confirmed = true;
    plan.merged = true;
    plan.detectAlgo = _detectAlgoVersion;
    plan.stamp++;
    plan.doneGrayscale = _grayscale;
    plan.doneSharpen = _sharpen;
    plan.doneDebleed = _debleed;
    plan.doneDebleedStrength = _debleedStrength;
    _batchThumbCache.remove(plan.outPath);
    FileImage(File(plan.outPath)).evict();
    // 拼入页删除（文件/标注/页面列表/计划重建，复用会话删除链路）。
    await _deletePlanBySource(partnerSourcePath);
    if (!mounted) return null;
    PythonService.addAppLog(
      '[批量摆正·拼接] 第 ${partnerIndex + 1} 页已并入第 ${plan.index + 1} 页'
      '（${p.basename(stitchedPath)}），本书剩 '
      '${widget.project.imageFiles.length} 页',
    );
    return _nextTargetAfter(plan.sourcePath);
  }

  Future<void> _previewPage(_PagePlan plan) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => _PagePreviewDialog(plan: plan),
    );
  }

  // ── 确认 / 删除 ──

  /// 确认该页：标记本页摆正结果已检查通过（确认过的页默认从列表隐藏，
  /// 顶部开关控制显示）；再次点击取消确认。
  Future<void> _toggleConfirm(_PagePlan plan) async {
    setState(() => plan.confirmed = !plan.confirmed);
    await _saveState();
  }

  /// 永久删除该页：删除页面图片、矫正图与本页识别标注，从本书移除。
  /// 不可恢复（用户明确要求：删除就是删除）。网格卡片入口。
  Future<void> _deletePage(_PagePlan plan) async {
    if (_finishing) return;
    if (plan.status == _PageStatus.running) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该页正在后台处理，请稍候再删除')),
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('永久删除第 ${plan.index + 1} 页？'),
        content: Text(
          '将删除「${p.basename(plan.sourcePath)}」的页面图片、矫正图与本页'
          '识别标注，并从本书移除。此操作无法恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('永久删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final project = widget.project;
    // 用源路径/矫正图路径在页面列表中定位（plan.index 在「完成」换矫正
    // 图/多次删除后可能失效——曾因索引越界直接异常退出）。
    final i = _imageFileIndexOf(plan);
    if (i < 0) {
      // 该页已不在书中（并发删除等）：刷新计划后返回。
      await _rebuildPlans();
      return;
    }
    // 若本书还在识别队列里，先摘除防止并发写同一批文件（稍后可重新
    // 开始识别，已完成页自动跳过）。
    RecognitionQueue.instance.remove(project.id);
    final currentFile = project.imageFiles[i];
    // 标注页号以源文件 stem 为准（稳定标识；currentFile 换成矫正图后
    // stem 会变，按它推导会删错/漏删标注）。
    final pageId = pageIdForImage(plan.sourcePath, i);
    // ① 文件：源图、矫正图、当前页面文件（可能是二者之一）。
    for (final f in {plan.sourcePath, plan.outPath, currentFile}) {
      try {
        final file = File(f);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
    FileImage(File(currentFile)).evict();
    FileImage(File(plan.outPath)).evict();
    // ② 本页识别标注。
    for (final suffix in ['.json', '.json.bak']) {
      try {
        final f = File(
          p.join(project.projectDir, 'annotations', pageId + suffix),
        );
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    // 文字汇总账本：删页即撤账（该页已确认文字移出字频统计）。
    unawaited(CharStatsService.removePage(project.projectDir, pageId));
    // ③ 页面列表与计数。
    project.imageFiles.removeAt(i);
    if (project.recognizedPages > 0) project.recognizedPages -= 1;
    project.lastPageIndex = project.lastPageIndex.clamp(
      0,
      project.imageFiles.isEmpty ? 0 : project.imageFiles.length - 1,
    );
    await ProjectStorage.save(project);
    // ④ 状态与计划重建：移除条目，其余页按新列表重排（重建比手工改
    // 索引可靠——完成后页面文件是矫正图路径，按源路径键的映射需重算）。
    _plans.remove(plan.sourcePath);
    _batchThumbCache.remove(plan.outPath);
    await _saveState();
    await _rebuildPlans();
    PythonService.addAppLog(
      '[批量摆正] 已永久删除第 ${i + 1} 页（${p.basename(plan.sourcePath)}），'
      '本书剩 ${project.imageFiles.length} 页',
    );
    // 不再弹「已永久删除第 N 页」消息条：卡片从网格消失即是最直接
    // 的反馈，删除详情在应用日志里；底部消息条会盖住最下排卡片的
    // 删除/修改按钮（用户反馈连续删页时挡操作）。
  }

  // ── 完成 ──

  Future<void> _finish() async {
    if (_finishing) return;
    _cancelRequested = true; // 退出后后台循环在当前页处理完即停
    setState(() => _finishing = true);
    final project = widget.project;
    var swapped = 0;
    for (final plan in _ordered) {
      if (plan.index < project.imageFiles.length &&
          plan.sourcePath == project.imageFiles[plan.index] &&
          plan.useWarped &&
          plan.warpedReady) {
        project.imageFiles[plan.index] = plan.outPath;
        FileImage(File(plan.outPath)).evict();
        swapped++;
      }
    }
    await ProjectStorage.save(project);
    await _saveState();
    PythonService.addAppLog(
      '[批量摆正] 完成：$swapped / ${_plans.length} 页使用矫正图，其余保留原图',
    );
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  // ── build ──

  @override
  Widget build(BuildContext context) {
    final visible = _ordered
        .where((x) => !_hideConfirmed || !x.confirmed)
        .toList();
    final confirmedCount = _ordered.where((x) => x.confirmed).length;
    return Scaffold(
        appBar: AppBar(
          title: Text('批量摆正 · ${widget.project.name}'),
          actions: [
            TextButton(
              onPressed: (_finishing || _ordered.every((x) => !x.useWarped))
                  ? null
                  : () {
                      setState(() {
                        for (final plan in _ordered) {
                          plan.useWarped = false;
                        }
                      });
                      unawaited(_saveState());
                    },
              child: const Text('全部使用原图'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _finishing ? null : _finish,
              icon: _finishing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check, size: 18),
              label: const Text('完成'),
            ),
            const SizedBox(width: 12),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                children: [
                  FilterChip(
                    label: const Text('去色', style: TextStyle(fontSize: 12)),
                    selected: _grayscale,
                    onSelected: (v) => unawaited(_toggleEnhancement(grayscale: v)),
                  ),
                  const SizedBox(width: 8),
                  FilterChip(
                    label: const Text('锐化', style: TextStyle(fontSize: 12)),
                    selected: _sharpen,
                    onSelected: (v) => unawaited(_toggleEnhancement(sharpen: v)),
                  ),
                  const SizedBox(width: 8),
                  FilterChip(
                    label: const Text('去透印', style: TextStyle(fontSize: 12)),
                    selected: _debleed,
                    onSelected: (v) =>
                        unawaited(_toggleEnhancement(debleed: v)),
                  ),
                  if (_debleed) ...[
                    SizedBox(
                      width: 140,
                      height: 36,
                      child: Slider(
                        value: _debleedStrength.toDouble(),
                        min: 1,
                        max: 100,
                        divisions: 99,
                        label: '$_debleedStrength',
                        // 拖动只刷新数值，松手才按新强度重做（onChangeEnd）。
                        onChanged: (v) =>
                            setState(() => _debleedStrength = v.round()),
                        onChangeEnd: (v) => unawaited(
                          _toggleEnhancement(debleedStrength: v.round()),
                        ),
                      ),
                    ),
                    Text(
                      '强度$_debleedStrength',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                  const SizedBox(width: 8),
                  FilterChip(
                    label: Text(
                      '隐藏已确认${confirmedCount > 0 ? '（$confirmedCount）' : ''}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    selected: _hideConfirmed,
                    onSelected: (v) {
                      setState(() => _hideConfirmed = v);
                      unawaited(_saveState());
                    },
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      '确认过的页默认隐藏；切换去色/锐化/去透印自动重做全部页；'
                      '「删除」永久移除该页。进度自动保存，可随时退出续作。',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                ],
              ),
            ),
            // 后台处理进度条（内嵌不阻塞）：网格全程可操作。
            if (_running)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LinearProgressIndicator(
                    value: _runTotal > 0
                        ? _runDone.clamp(0, _runTotal) / _runTotal
                        : null,
                    minHeight: 3,
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '后台处理中 $_runDone/$_runTotal · '
                            '并行$_workers · $_inflightLabel'
                            '（可同时修改其他页）',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.grey,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton(
                          onPressed: () => setState(() => _cancelRequested = true),
                          child: const Text('停止', style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            const Divider(height: 1),
            Expanded(child: _buildGrid(visible)),
          ],
        ),
      );
  }

  Widget _buildGrid(List<_PagePlan> plans) {
    if (_ordered.isEmpty) {
      return const Center(child: Text('本书没有页面。'));
    }
    if (plans.isEmpty) {
      return const Center(
        child: Text(
          '全部页面已确认。\n（关闭顶部「隐藏已确认」可查看）',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 240,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 0.72,
      ),
      itemCount: plans.length,
      itemBuilder: (context, i) => _buildCard(plans[i]),
    );
  }

  Widget _buildCard(_PagePlan plan) {
    final (label, color) = switch (plan.status) {
      _PageStatus.done => ('已矫正', Colors.green),
      _PageStatus.skipped => ('无需摆正', Colors.blueGrey),
      _PageStatus.failed => ('需手动', Colors.red),
      _PageStatus.running => ('处理中…', Colors.orange),
      _PageStatus.pending => ('未处理', Colors.grey),
    };
    final thumbPath = plan.useWarped && plan.warpedReady
        ? plan.outPath
        : plan.sourcePath;
    // 后台模式下只有"正在处理的本页"禁改，其他页操作不受影响。
    final planBusy = _finishing || plan.status == _PageStatus.running;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: InkWell(
              onTap: plan.warpedReady ? () => unawaited(_previewPage(plan)) : null,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // key 含 stamp：文件被手动修改覆盖后强制重建缩略图 State
                  // 重新解码（LRU 缓存按路径命中，单靠路径感知不到新图）。
                  _ThumbImage(
                    key: ValueKey('$thumbPath#${plan.stamp}'),
                    path: thumbPath,
                  ),
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        label,
                        style: const TextStyle(fontSize: 11, color: Colors.white),
                      ),
                    ),
                  ),
                  if (plan.confirmed)
                    Positioned(
                      left: 6,
                      top: 30,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.teal.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.check, size: 11, color: Colors.white),
                            SizedBox(width: 2),
                            Text(
                              '已确认',
                              style: TextStyle(fontSize: 11, color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                    ),
                  Positioned(
                    right: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '第 ${plan.index + 1} 页',
                        style: const TextStyle(fontSize: 11, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 4, 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        plan.useWarped && plan.warpedReady ? '使用矫正图' : '使用原图',
                        style: TextStyle(
                          fontSize: 12,
                          color: plan.useWarped && plan.warpedReady
                              ? Theme.of(context).colorScheme.primary
                              : Colors.grey.shade700,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    Switch(
                      value: plan.useWarped && plan.warpedReady,
                      onChanged: (!plan.warpedReady || planBusy)
                          ? null
                          : (v) {
                              setState(() => plan.useWarped = v);
                              unawaited(_saveState());
                            },
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.tonalIcon(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          minimumSize: const Size(0, 30),
                        ),
                        onPressed: planBusy ? null : () => unawaited(_editPage(plan)),
                        icon: const Icon(Icons.tune, size: 14),
                        label: const Text('修改', style: TextStyle(fontSize: 11)),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          minimumSize: const Size(0, 30),
                        ),
                        onPressed: plan.warpedReady
                            ? () => unawaited(_previewPage(plan))
                            : null,
                        icon: const Icon(Icons.zoom_out_map, size: 14),
                        label: const Text('预览', style: TextStyle(fontSize: 11)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          minimumSize: const Size(0, 28),
                          foregroundColor: plan.confirmed
                              ? Colors.teal
                              : null,
                        ),
                        onPressed: planBusy ? null : () => unawaited(_toggleConfirm(plan)),
                        icon: Icon(
                          plan.confirmed ? Icons.undo : Icons.check_circle_outline,
                          size: 14,
                        ),
                        label: Text(
                          plan.confirmed ? '取消确认' : '确认',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          minimumSize: const Size(0, 28),
                          foregroundColor: Colors.red.shade700,
                        ),
                        onPressed: planBusy ? null : () => unawaited(_deletePage(plan)),
                        icon: const Icon(Icons.delete_outline, size: 14),
                        label: const Text('删除', style: TextStyle(fontSize: 11)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 降采样缩略图（按路径 LRU 缓存，避免大书整本进内存）。
class _ThumbImage extends StatefulWidget {
  const _ThumbImage({super.key, required this.path});

  final String path;

  @override
  State<_ThumbImage> createState() => _ThumbImageState();
}

class _ThumbImageState extends State<_ThumbImage> {
  Future<ui.Image?>? _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<ui.Image?> _load() async {
    final hit = _batchThumbCache.remove(widget.path);
    if (hit != null) {
      _batchThumbCache[widget.path] = hit;
      return hit;
    }
    try {
      final data = await File(widget.path).readAsBytes();
      final codec = await ui.instantiateImageCodec(data, targetWidth: 360);
      final frame = await codec.getNextFrame();
      _batchThumbCache[widget.path] = frame.image;
      while (_batchThumbCache.length > _batchThumbMax) {
        _batchThumbCache.remove(_batchThumbCache.keys.first);
      }
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  @override
  void didUpdateWidget(covariant _ThumbImage old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) {
      _future = _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ui.Image?>(
      future: _future,
      builder: (context, snap) {
        final img = snap.data;
        if (img == null) {
          return snap.hasError
              ? const Center(child: Icon(Icons.broken_image, color: Colors.grey))
              : Container(color: Colors.grey.shade200);
        }
        return FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            width: img.width.toDouble(),
            height: img.height.toDouble(),
            child: CustomPaint(
              painter: _RawImagePainter(img),
              size: Size(img.width.toDouble(), img.height.toDouble()),
            ),
          ),
        );
      },
    );
  }
}

class _RawImagePainter extends CustomPainter {
  _RawImagePainter(this.image);

  final ui.Image image;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(_RawImagePainter old) => old.image != image;
}

/// 页面预览对话框：原图 / 矫正图切换对比（缩放查看）。
class _PagePreviewDialog extends StatefulWidget {
  const _PagePreviewDialog({required this.plan});

  final _PagePlan plan;

  @override
  State<_PagePreviewDialog> createState() => _PagePreviewDialogState();
}

class _PagePreviewDialogState extends State<_PagePreviewDialog> {
  bool _showWarped = true;

  @override
  Widget build(BuildContext context) {
    final plan = widget.plan;
    final path = (_showWarped && plan.warpedReady) ? plan.outPath : plan.sourcePath;
    return AlertDialog(
      title: Row(
        children: [
          Text('第 ${plan.index + 1} 页预览'),
          const Spacer(),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('矫正图')),
              ButtonSegment(value: false, label: Text('原图')),
            ],
            selected: {_showWarped},
            onSelectionChanged: (s) => setState(() => _showWarped = s.first),
          ),
        ],
      ),
      content: SizedBox(
        width: 720,
        height: 640,
        child: InteractiveViewer(
          maxScale: 6,
          child: Image.file(
            File(path),
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const Center(
              child: Text('图片读取失败', style: TextStyle(color: Colors.grey)),
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}


/// 批量摆正页的会话宿主：把 StraightenPage 的确认/删除记账到批量状态。
class _BatchStraightenHost extends StraightenPageHost {
  _BatchStraightenHost(this._state);

  final _StraightenBatchPageState _state;

  @override
  void applyCurrent(
    StraightenPageTarget page,
    PageQuad quad, {
    required bool grayscale,
    required bool sharpen,
    required bool debleed,
    required int debleedStrength,
    required bool confirmed,
  }) {
    _state._applyPlanResult(
      page.imagePath,
      quad,
      grayscale: grayscale,
      sharpen: sharpen,
      debleed: debleed,
      debleedStrength: debleedStrength,
      confirmed: confirmed,
    );
  }

  @override
  Future<void> deleteCurrent(StraightenPageTarget page) {
    return _state._deletePlanBySource(page.imagePath);
  }

  @override
  StraightenPageTarget? nextPageAfter(StraightenPageTarget page) {
    return _state._nextTargetAfter(page.imagePath);
  }

  @override
  List<StraightenPageTarget> stitchPartners(StraightenPageTarget page) {
    return _state._stitchPartners(page.imagePath);
  }

  @override
  Future<StraightenPageTarget?> mergePages(
    StraightenPageTarget current,
    StraightenPageTarget partner, {
    required String stitchedPath,
  }) {
    return _state._mergePlanResult(
      current.imagePath,
      partner.imagePath,
      stitchedPath,
    );
  }
}
