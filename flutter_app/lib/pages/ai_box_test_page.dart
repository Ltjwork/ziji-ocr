import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../services/ai_char_boxes.dart';
import '../services/ollama_service.dart';
import '../services/python_service.dart';
import '../services/single_page_pipeline.dart';

/// 命中判定：图像像素坐标 [px]/[py] 落在哪个 AI 框内（先中先得，重叠时
/// 取面积更小者）。顶层纯函数便于单测。
int? hitTestAiBox(double px, double py, List<OllamaCharBox> boxes) {
  int? best;
  var bestArea = double.infinity;
  for (var i = 0; i < boxes.length; i++) {
    final b = boxes[i];
    if (px >= b.x1 && px <= b.x2 && py >= b.y1 && py <= b.y2) {
      final area = (b.x2 - b.x1) * (b.y2 - b.y1);
      if (area < bestArea) {
        bestArea = area;
        best = i;
      }
    }
  }
  return best;
}

/// AI 画框测试页（实验功能）：选一张图 → 后端生成带网格刻度的降采样
/// 素材图 → 视觉模型**直接输出每个字的坐标框** → 原样叠加到原图。
///
/// 与生产链路（"语义归模型，像素归几何"）刻意相反：这里不做任何几何
/// 精修、不写任何标注、不进训练数据——专门测「单纯让 AI 决定从哪个
/// 像素到哪个像素是一个字」的裸水平。整页几百个字的 JSON 输出量很大，
/// 截断是常态，能打捞多少画多少（横幅提示）。
class AiBoxTestPage extends StatefulWidget {
  /// 诊断钩子：环境变量 `OCR_AI_BOX_AUTOTEST=<图片>` 启动时注入的首图与
  /// 自动执行（无头复现/冒烟用，正常使用不传）；`OCR_AI_BOX_AUTOTEST_
  /// PIPELINE=1` 时 AI 画框跑完再自动跑一次管线（关 AI 裁决，不依赖
  /// 外部网关）。
  final String? initialImagePath;
  final bool autoRun;
  final bool autoRunPipeline;

  const AiBoxTestPage({
    super.key,
    this.initialImagePath,
    this.autoRun = false,
    this.autoRunPipeline = false,
  });

  @override
  State<AiBoxTestPage> createState() => _AiBoxTestPageState();
}

class _AiBoxTestPageState extends State<AiBoxTestPage> {
  static const _baseWidth = 860.0;
  static const _lastDirKey = 'ai_box_test_last_dir_v1';

  String? _imagePath;
  double? _imgW;
  double? _imgH;
  String? _imgError;

  OllamaSettings _settings = const OllamaSettings();
  AiBoxCoordMode _coordMode = AiBoxCoordMode.materialPixel;
  int _gridDiv = 16;

  bool _running = false;
  String? _error;
  AiCharBoxesResult? _result;
  bool _showBoxes = true;
  int? _selIndex;
  bool _rawExpanded = false;

  // ── YOLO+AI 管线对比 ──
  SinglePagePipelineResult? _pipeline;
  bool _pipelineRunning = false;
  String? _pipelineError;
  String _pipelineStage = '';

  /// 管线的 AI 整行裁决开关（生产同门控初始化：enableLineAssist + 已选
  /// 模型；跑动中锁定）。
  bool _useAiAssist = false;
  bool _showPipelineChars = true;
  bool _showPipelineLines = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialImagePath != null) {
      _imagePath = widget.initialImagePath;
      _loadImageSize();
    }
    _loadSettings().then((_) {
      if (!mounted || !widget.autoRun) return;
      _run().then((_) {
        if (mounted && widget.autoRunPipeline) {
          _runPipeline(overrideUseAiAssist: false);
        }
      });
    });
  }

  Future<void> _loadSettings() async {
    final s = await OllamaSettings.load();
    if (!mounted) return;
    setState(() {
      _settings = s;
      _useAiAssist =
          s.enableLineAssist &&
          (s.activeVisionModel.isNotEmpty || s.activeTextModel.isNotEmpty);
    });
  }

  Future<void> _pickImage() async {
    String? initialDir;
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getString(_lastDirKey);
      if (last != null && Directory(last).existsSync()) initialDir = last;
    } catch (_) {}
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        initialDirectory: initialDir,
        type: FileType.custom,
        allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp', 'bmp'],
      );
    } catch (_) {
      // initialDirectory 无效等场景：去掉初始目录再试一次
      result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        type: FileType.custom,
        allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp', 'bmp'],
      );
    }
    if (result == null || result.files.isEmpty) return;
    final f = result.files.first;
    if (f.path == null) return;
    final dir = File(f.path!).parent.path;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastDirKey, dir);
    } catch (_) {}
    setState(() {
      _imagePath = f.path;
      _imgW = null;
      _imgH = null;
      _imgError = null;
      _result = null;
      _error = null;
      _selIndex = null;
    });
    _loadImageSize();
  }

  Future<void> _loadImageSize() {
    final path = _imagePath;
    if (path == null) return Future.value();
    // 监听原图流拿自然尺寸（与展示层共用同一缓存条目，不二次解码）。
    final stream = FileImage(File(path)).resolve(const ImageConfiguration());
    final completer = Completer<(double, double)?>();
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!completer.isCompleted) {
          completer.complete(
            (info.image.width.toDouble(), info.image.height.toDouble()),
          );
        }
        stream.removeListener(listener);
      },
      onError: (Object error, StackTrace? stackTrace) {
        if (!completer.isCompleted) completer.complete(null);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    return completer.future.then((size) {
      if (!mounted) return;
      setState(() {
        if (size == null) {
          _imgError = '图片加载失败：$path';
        } else {
          _imgW = size.$1;
          _imgH = size.$2;
        }
      });
    });
  }

  Future<void> _run() async {
    final path = _imagePath;
    if (path == null || _running) return;
    if (_settings.activeVisionModel.isEmpty) {
      setState(() => _error = '未选择视觉模型——请先到「AI 辅助设置」中选择（首页 → 设置）');
      return;
    }
    setState(() {
      _running = true;
      _error = null;
      _result = null;
      _selIndex = null;
    });
    try {
      final result = await runAiCharBoxes(
        settings: _settings,
        imagePath: path,
        gridDiv: _gridDiv,
        coordMode: _coordMode,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        if (result.boxes.isEmpty) {
          _error = 'AI 没有输出任何有效字框（原始返回见下方 JSON）';
        }
      });
    } catch (e) {
      if (!mounted) return;
      PythonService.writeCrashLineSync('[AI画框] 失败（同步标记）：$e');
      PythonService.addAppLog('[AI画框] 失败：$e', isError: true);
      setState(() => _error = 'AI 画框失败：$e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  /// 跑一次当前生产管线（YOLO 切字 + Kraken 识别 +（可选）AI 整行裁决
  /// + 阅读顺序重排），与「让 AI 画框」同一张图对比耗时与框。
  Future<void> _runPipeline({bool? overrideUseAiAssist}) async {
    final path = _imagePath;
    if (path == null || _running || _pipelineRunning) return;
    final useAiAssist = overrideUseAiAssist ?? _useAiAssist;
    setState(() {
      _pipelineRunning = true;
      _pipelineError = null;
      _pipeline = null;
      _pipelineStage = '';
    });
    try {
      final r = await runSinglePagePipeline(
        imagePath: path,
        pageId: 'box_test',
        settings: ProjectSettings(
          layoutMode: 'all_text',
          orientation: 'vertical',
          horizontalDir: 'rtl',
          verticalDir: 'ttb',
        ),
        useAiAssist: useAiAssist,
        onProgress: (stage) {
          if (mounted) setState(() => _pipelineStage = stage);
        },
      );
      if (!mounted) return;
      setState(() => _pipeline = r);
    } catch (e) {
      if (!mounted) return;
      PythonService.writeCrashLineSync('[管线] 失败（同步标记）：$e');
      setState(() => _pipelineError = '管线运行失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _pipelineRunning = false;
          _pipelineStage = '';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 画框测试'),
        actions: [
          IconButton(
            tooltip: _showBoxes ? '隐藏 AI 字框' : '显示 AI 字框',
            icon: Icon(_showBoxes ? Icons.grid_on : Icons.grid_off, size: 20),
            onPressed: _result == null
                ? null
                : () => setState(() => _showBoxes = !_showBoxes),
          ),
          IconButton(
            tooltip: _showPipelineChars ? '隐藏管线字框' : '显示管线字框',
            icon: Icon(
              _showPipelineChars ? Icons.crop_square : Icons.crop_free,
              size: 20,
              color: _pipeline == null ? null : Colors.lightBlueAccent.shade400,
            ),
            onPressed: _pipeline == null
                ? null
                : () =>
                      setState(() => _showPipelineChars = !_showPipelineChars),
          ),
          IconButton(
            tooltip: _showPipelineLines ? '隐藏管线行框' : '显示管线行框',
            icon: Icon(
              _showPipelineLines ? Icons.crop_din : Icons.crop_16_9,
              size: 20,
              color: _pipeline == null ? null : Colors.deepPurple,
            ),
            onPressed: _pipeline == null
                ? null
                : () =>
                      setState(() => _showPipelineLines = !_showPipelineLines),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          _buildToolbar(),
          const Divider(height: 1),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 900;
                final viewer = _buildViewer();
                final panel = _buildPanel();
                if (wide) {
                  return Row(
                    children: [
                      Expanded(child: viewer),
                      SizedBox(width: 360, child: panel),
                    ],
                  );
                }
                return Column(
                  children: [
                    SizedBox(height: constraints.maxHeight * 0.55, child: viewer),
                    Expanded(child: panel),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    final modelReady = _settings.activeVisionModel.isNotEmpty;
    final fileName = _imagePath == null
        ? null
        : File(_imagePath!).uri.pathSegments.last;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          OutlinedButton.icon(
            onPressed: _running ? null : _pickImage,
            icon: const Icon(Icons.image_outlined, size: 18),
            label: Text(fileName ?? '选择图片', overflow: TextOverflow.ellipsis),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('坐标口径', style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(width: 6),
              SegmentedButton<AiBoxCoordMode>(
                segments: [
                  for (final m in AiBoxCoordMode.values)
                    ButtonSegment(value: m, label: Text(m.label)),
                ],
                selected: {_coordMode},
                onSelectionChanged: _running
                    ? null
                    : (s) => setState(() => _coordMode = s.first),
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('网格', style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(width: 6),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 8, label: Text('8 格')),
                  ButtonSegment(value: 16, label: Text('16 格')),
                ],
                selected: {_gridDiv},
                onSelectionChanged: _running
                    ? null
                    : (s) => setState(() => _gridDiv = s.first),
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ),
          FilledButton.icon(
            onPressed: _imagePath == null || _running ? null : _run,
            icon: _running
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome, size: 18),
            label: Text(_running ? 'AI 正在画框…' : '让 AI 画框'),
          ),
          OutlinedButton.icon(
            onPressed: _imagePath == null || _running || _pipelineRunning
                ? null
                : () => _runPipeline(),
            icon: _pipelineRunning
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.memory, size: 18),
            label: Text(_pipelineRunning ? '管线运行中…' : 'YOLO+AI 管线'),
          ),
          // 管线的 AI 整行裁决开关：默认按生产门控（enableLineAssist+已选
          // 模型）初始化，跑动中锁定。
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: Checkbox(
                  value: _useAiAssist,
                  onChanged: _running || _pipelineRunning
                      ? null
                      : (v) => setState(() => _useAiAssist = v ?? false),
                ),
              ),
              const SizedBox(width: 4),
              const Text(
                '含 AI 裁决',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
          if (_running)
            const Text(
              '整页几百字可能要数分钟，请耐心等待',
              style: TextStyle(fontSize: 11.5, color: Colors.grey),
            ),
          if (!modelReady && !_running)
            const Tooltip(
              message: '视觉模型未选择，点击「让 AI 画框」会提示去设置',
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.warning_amber_rounded, size: 15, color: Colors.orange),
                  SizedBox(width: 4),
                  Text(
                    '未选视觉模型',
                    style: TextStyle(fontSize: 11.5, color: Colors.orange),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildViewer() {
    if (_imagePath == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.image_search, size: 44, color: Colors.grey.shade400),
            const SizedBox(height: 10),
            const Text(
              '选择一张古籍图片，让 AI 判断从哪个像素到哪个像素是一个字',
              style: TextStyle(color: Colors.grey, fontSize: 12.5),
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: _pickImage,
              icon: const Icon(Icons.image_outlined, size: 18),
              label: const Text('选择图片'),
            ),
          ],
        ),
      );
    }
    if (_imgError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _imgError!,
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
              fontSize: 12.5,
            ),
          ),
        ),
      );
    }
    if (_imgW == null || _imgH == null || _imgW! <= 0 || _imgH! <= 0) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    final scale = _baseWidth / _imgW!;
    final viewH = _imgH! * scale;
    final boxes = _result?.boxes ?? const <OllamaCharBox>[];
    final pipelineLines = _pipeline?.orderedLines ?? const <LineBlock>[];
    final hasOverlay = boxes.isNotEmpty || pipelineLines.isNotEmpty;
    return Column(
      children: [
        Expanded(
          child: InteractiveViewer(
            maxScale: 12,
            minScale: 0.15,
            constrained: false,
            boundaryMargin: const EdgeInsets.all(1500),
            child: GestureDetector(
              onTapUp: (d) => _handleTap(d.localPosition.dx, d.localPosition.dy),
              child: Stack(
                children: [
                  SizedBox(
                    width: _baseWidth,
                    height: viewH,
                    child: Image.file(File(_imagePath!), fit: BoxFit.fill),
                  ),
                  if (hasOverlay)
                    CustomPaint(
                      size: Size(_baseWidth, viewH),
                      painter: _AiBoxesPainter(
                        boxes: _showBoxes ? boxes : const [],
                        pipelineLines: _showPipelineLines
                            ? pipelineLines
                            : const [],
                        showPipelineChars: _showPipelineChars,
                        scale: scale,
                        selIndex: _selIndex,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        _buildSelBar(),
      ],
    );
  }

  void _handleTap(double dx, double dy) {
    final boxes = _result?.boxes;
    if (boxes == null || boxes.isEmpty) return;
    final scale = _imgW == null || _imgW! <= 0 ? 1.0 : _baseWidth / _imgW!;
    setState(() => _selIndex = hitTestAiBox(dx / scale, dy / scale, boxes));
  }

  Widget _buildSelBar() {
    final boxes = _result?.boxes ?? const <OllamaCharBox>[];
    final pl = _pipeline;
    String hint;
    if (_pipelineRunning) {
      hint = _pipelineStage.isEmpty ? '管线识别中…' : _pipelineStage;
    } else if (_running) {
      hint = 'AI 正在逐字判断坐标…';
    } else if (boxes.isEmpty && pl == null) {
      hint = '滚轮缩放、拖动平移；跑「让 AI 画框」或「YOLO+AI 管线」后点击框查看坐标';
    } else if (_selIndex == null) {
      hint = pl == null
          ? '共 ${boxes.length} 框（编号即 AI 给出的阅读顺序）；点击框查看坐标'
          : 'AI ${boxes.length} 框 + 管线 ${pl.orderedLines.length} 行'
                '/${pl.annotation.blocks.length} 字；点击 AI 框查看坐标';
    } else {
      final b = boxes[_selIndex!];
      hint = '第 ${_selIndex! + 1} 框 · 原图像素 (${b.x1.round()},${b.y1.round()})–'
          '(${b.x2.round()},${b.y2.round()}) · ${b.x2.round() - b.x1.round()}×'
          '${b.y2.round() - b.y1.round()}';
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: Colors.black.withValues(alpha: _selIndex == null ? 0.05 : 0.07),
      child: Text(hint, style: const TextStyle(color: Colors.grey, fontSize: 11.5)),
    );
  }

  Widget _buildPanel() {
    final r = _result;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
      children: [
        if (_error != null)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              _error!,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
        if (_pipelineError != null)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              _pipelineError!,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
        if (r != null || _pipeline != null) ...[
          _compareCard(),
          const SizedBox(height: 10),
        ],
        if (r != null) ...[
          if (r.truncated)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.orange.shade200),
              ),
              child: Text(
                '响应被截断（整页字数超出输出上限），已打捞 ${r.boxes.length} 框——'
                '这本身是实验数据：该模型/口径下整页不可行，可换小图或更短口径测试。',
                style: TextStyle(fontSize: 12, color: Colors.orange.shade900),
              ),
            ),
          _statCard(r),
          const SizedBox(height: 10),
        ],
        _aboutCard(),
        if (r != null) ...[
          const SizedBox(height: 10),
          // 手动开关 + 条件构建：原始 JSON 可能几十 KB，绝不在结果一落地
          // 就构建 SelectableText（debug JIT 单帧过重的崩溃先例见 painter
          // 注释）；超长内容只显示前 2 万字符。
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                textStyle: const TextStyle(fontSize: 12.5),
              ),
              onPressed: () => setState(() => _rawExpanded = !_rawExpanded),
              icon: Icon(
                _rawExpanded ? Icons.expand_less : Icons.expand_more,
                size: 18,
              ),
              label: Text(
                '模型原始返回（JSON，${r.rawContent.length} 字符）'
                '${_rawExpanded ? '　点击收起' : ''}',
              ),
            ),
          ),
          if (_rawExpanded)
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 300),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(6),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  r.rawContent.length > 20000
                      ? '${r.rawContent.substring(0, 20000)}\n\n……（过长，仅显示前 2 万字符）'
                      : r.rawContent,
                  style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                ),
              ),
            ),
        ],
      ],
    );
  }

  /// 方案对比卡：纯 AI 画框 vs YOLO+AI 管线，同一张图各自"识别一页
  /// 所用的时间"与产出；两侧任一存在即显示，都有时给数量差。
  Widget _compareCard() {
    final ai = _result;
    final pl = _pipeline;
    String fmt(int ms) => '${(ms / 1000).toStringAsFixed(1)} 秒';
    Widget nameCell(String text, Color color) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                border: Border.all(color: color, width: 2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 5),
            Text(text, style: const TextStyle(fontSize: 12)),
          ],
        );
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '方案对比（同一张图）',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5),
          ),
          const SizedBox(height: 8),
          Table(
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            columnWidths: const {
              0: FlexColumnWidth(1.2),
              1: FlexColumnWidth(0.9),
              2: FlexColumnWidth(1.1),
            },
            children: [
              if (ai != null)
                TableRow(children: [
                  nameCell('纯 AI 画框', Colors.green),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Text(
                      fmt(ai.totalMs),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  Text('${ai.boxes.length} 框', style: const TextStyle(fontSize: 12)),
                ]),
              if (pl != null)
                TableRow(children: [
                  nameCell('YOLO+AI 管线', Colors.lightBlueAccent.shade400),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Text(
                      fmt(pl.totalMs),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  Text(
                    '${pl.orderedLines.length} 行 / ${pl.annotation.blocks.length} 字',
                    style: const TextStyle(fontSize: 12),
                  ),
                ]),
            ],
          ),
          const SizedBox(height: 4),
          // 分段耗时与管线元信息（小字）
          DefaultTextStyle(
            style: const TextStyle(fontSize: 11, color: Colors.grey, height: 1.5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (ai != null)
                  Text('纯 AI：素材图 ${fmt(ai.materialMs)} + 模型 ${fmt(ai.elapsedMs)}'),
                if (pl != null)
                  Text(
                    '管线：识别 ${fmt(pl.segmentMs)} + AI 裁决 ${fmt(pl.aiAssistMs)}'
                    '（${switch (pl.aiAssistStatus) {
                      'applied' => '模型 ${pl.aiAssistModel}',
                      'skipped-no-model' => '未选模型，跳过',
                      _ => '未开启',
                    }}）',
                  ),
                if (pl != null)
                  Text(
                    '引擎 ${pl.segmentMeta['engine'] ?? '—'}'
                    '${(pl.segmentMeta['fallback_reason']?.toString() ?? '').isEmpty ? '' : '（回退：${pl.segmentMeta['fallback_reason']}）'}'
                    ' · 阅读方向 竖排/右→左',
                  ),
                if (ai != null && pl != null)
                  Text(
                    '数量差：管线 ${pl.annotation.blocks.length} 字 − '
                    'AI ${ai.boxes.length} 框 = '
                    '${pl.annotation.blocks.length - ai.boxes.length >= 0 ? '+' : ''}'
                    '${pl.annotation.blocks.length - ai.boxes.length}',
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statCard(AiCharBoxesResult r) {
    Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              SizedBox(
                width: 76,
                child: Text(k, style: const TextStyle(fontSize: 11.5, color: Colors.grey)),
              ),
              Expanded(
                child: Text(v, style: const TextStyle(fontSize: 12.5)),
              ),
            ],
          ),
        );
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          row('字框数', '${r.boxes.length}'),
          row('AI 耗时', '${(r.elapsedMs / 1000).toStringAsFixed(1)} 秒'),
          row(
            '模型',
            _settings.activeVisionModel.isEmpty
                ? '—'
                : _settings.activeVisionModel,
          ),
          row('来源', _settings.provider.label),
          row('坐标口径', r.coordMode.label),
          row('素材图网格', '${r.gridDiv} 格'),
        ],
      ),
    );
  }

  Widget _aboutCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('这是什么实验', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5)),
          SizedBox(height: 6),
          Text(
            '把带网格刻度的降采样素材图发给视觉模型，让它直接输出每个字的'
            '坐标框，AI 给的坐标原样上画布——不做任何几何精修、不写任何标注、'
            '不进训练数据。生产链路里"像素归几何"的那一半在这里被刻意拿掉，'
            '专门测 VLM 裸定位的真实水平。\n'
            '· 「YOLO+AI 管线」按钮跑当前生产管线（YOLO 切字 + Kraken 识别 +'
            '可选 AI 整行裁决，阅读方向按古籍竖排右→左），两方案的耗时与'
            '产出在上方对比卡并排显示：绿=AI 框、蓝=管线字框、紫=管线行框\n'
            '· 坐标口径：像素=让模型直接报素材图像素；归一化=参考网格刻度 0~1\n'
            '· 框上编号即模型给出的阅读顺序\n'
            '· 素材图由后端生成（应用会自动拉起 Python 服务）',
            style: TextStyle(fontSize: 11.5, color: Colors.grey, height: 1.5),
          ),
        ],
      ),
    );
  }
}

/// AI 字框叠加层：绿框 + 阅读顺序编号，选中项红框高亮。
///
/// 单帧成本控制（本项目有"API ok 返回后应用无痕消失"的崩溃先例——
/// char_verify_debug_page：debug JIT 下单帧构建过重直接带走进程，Dart
/// 层零异常）：矩形绘制本身很便宜（几百次 canvas.drawRect 无压力），
/// 贵的是序号徽章的 TextPainter 逐框布局——超过 [_kBadgeMaxBoxes] 个框
/// 时只画矩形不画序号；paint 起止打日志，万一再消失，日志最后一行
/// 即可锁定是否死在渲染帧。
class _AiBoxesPainter extends CustomPainter {
  /// 超过此框数不再绘制序号徽章（TextPainter 布局是单帧主要成本）。
  static const _kBadgeMaxBoxes = 300;

  /// AI 画框方案的字框（绿 + 序号）。
  final List<OllamaCharBox> boxes;

  /// 管线方案的行列表（行框深紫、字框浅蓝，[showPipelineChars] 控制
  /// 字框显隐；行框由传入的列表是否为空控制）。
  final List<LineBlock> pipelineLines;
  final bool showPipelineChars;
  final double scale;
  final int? selIndex;

  _AiBoxesPainter({
    required this.boxes,
    required this.pipelineLines,
    required this.showPipelineChars,
    required this.scale,
    required this.selIndex,
  });

  final Paint _normal =
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.green
        ..strokeWidth = 1.2;
  final Paint _selected =
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.red
        ..strokeWidth = 2.5;
  final Paint _selectedFill =
      Paint()..color = Colors.red.withValues(alpha: 0.15);
  final Paint _badgeBg =
      Paint()..color = Colors.black87;
  final Paint _badgeBgSelected =
      Paint()..color = Colors.red.shade700;
  final Paint _pipelineChar =
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.lightBlueAccent.shade400
        ..strokeWidth = 1.0;
  final Paint _pipelineLine =
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.deepPurple
        ..strokeWidth = 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    // 同步落盘（渲染帧是崩溃 forensic 的最后窗口，异步日志会丢）
    PythonService.writeCrashLineSync(
      '[AI画框] paint 开始：AI ${boxes.length} 框 + '
      '管线 ${pipelineLines.length} 行',
    );
    // 管线框画在底层（AI 框与序号在上层）
    for (final l in pipelineLines) {
      canvas.drawRect(
        Rect.fromLTRB(l.x * scale, l.y * scale, (l.x + l.w) * scale,
            (l.y + l.h) * scale),
        _pipelineLine,
      );
      if (showPipelineChars) {
        for (final ch in l.chars) {
          canvas.drawRect(
            Rect.fromLTRB(ch.x * scale, ch.y * scale, (ch.x + ch.w) * scale,
                (ch.y + ch.h) * scale),
            _pipelineChar,
          );
        }
      }
    }
    final drawBadges = boxes.length <= _kBadgeMaxBoxes;
    for (var i = 0; i < boxes.length; i++) {
      final b = boxes[i];
      final rect = Rect.fromLTRB(
        b.x1 * scale,
        b.y1 * scale,
        b.x2 * scale,
        b.y2 * scale,
      );
      if (i == selIndex) {
        canvas.drawRect(rect, _selectedFill);
        canvas.drawRect(rect, _selected);
      } else {
        canvas.drawRect(rect, _normal);
      }
      if (drawBadges && rect.width >= 18) {
        _drawIndexBadge(canvas, rect, i);
      }
    }
    PythonService.writeCrashLineSync('[AI画框] paint 结束：AI ${boxes.length} 框');
  }

  void _drawIndexBadge(Canvas canvas, Rect rect, int index) {
    final tp = TextPainter(
      text: TextSpan(
        text: '${index + 1}',
        style: const TextStyle(
          fontSize: 10,
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final origin = rect.topLeft.translate(0, -tp.height - 3);
    final shifted = origin.dy < 0 ? rect.topLeft : origin;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        shifted & Size(tp.width + 5, tp.height + 2),
        const Radius.circular(3),
      ),
      index == selIndex ? _badgeBgSelected : _badgeBg,
    );
    tp.paint(canvas, shifted.translate(2.5, 1));
  }

  @override
  bool shouldRepaint(_AiBoxesPainter old) =>
      old.scale != scale ||
      old.selIndex != selIndex ||
      old.boxes != boxes ||
      old.pipelineLines != pipelineLines ||
      old.showPipelineChars != showPipelineChars;
}
