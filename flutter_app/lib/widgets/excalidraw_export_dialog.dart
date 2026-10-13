// Excalidraw 导出工作台：框选区域后弹出的"预览 + 调参 + 校对"对话框。
//
// 左侧预览画布叠加渲染检测出的场景元素（底图可开关/调透明度），支持
// "画文字框"模式——在图上拖拽框出要按文字处理的区域（格内注释、旋转
// 文字等编辑器行数据没盖住的墨迹），后端对空框单独识别。右侧四个页签：
// 设置（全部导出参数）/ 文字（逐元素校对，带置信度）/ 识别过程（四阶段
// 过程图）/ 日志（本次生成的管线日志）。改参数自动防抖重新生成——注入
// 编辑器校对数据时后端不跑识别，迭代是秒级的。满意后保存 .excalidraw。
//
// 返回值：'repick'（要求重新框选区域）或 null。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../services/python_service.dart';

class ExcalidrawExportDialog extends StatefulWidget {
  const ExcalidrawExportDialog({
    super.key,
    required this.imagePath,
    required this.region,
    required this.annotation,
    required this.pageSettings,
  });

  final String imagePath;
  final Rect region; // 图像像素坐标
  final PageAnnotation annotation;
  final ProjectSettings pageSettings;

  static const String _prefsKey = 'excalidraw_export_options_v1';

  static Future<String?> show(
    BuildContext context, {
    required String imagePath,
    required Rect region,
    required PageAnnotation annotation,
    required ProjectSettings pageSettings,
  }) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ExcalidrawExportDialog(
        imagePath: imagePath,
        region: region,
        annotation: annotation,
        pageSettings: pageSettings,
      ),
    );
  }

  @override
  State<ExcalidrawExportDialog> createState() => _ExcalidrawExportDialogState();
}

class _ExcalidrawExportDialogState extends State<ExcalidrawExportDialog>
    with SingleTickerProviderStateMixin {
  ExcalidrawExportOptions _opts = ExcalidrawExportOptions();
  Map<String, dynamic>? _scene;
  Map? _stats;
  bool _busy = false;
  String? _error;
  bool _showScan = true;
  double _scanOpacity = 0.35;
  bool _debugColors = false;
  ui.Image? _scan;
  Timer? _debounce;
  int _seq = 0;

  late final TabController _tabC;
  final GlobalKey _canvasKey = GlobalKey();

  /// 手画文字识别框（图像坐标）与正在拖拽的预览（画布坐标）。
  final List<Rect> _textBoxes = [];
  bool _drawTextMode = false;
  Rect? _drawPreviewLocal;

  List<String> _trace = const [];
  List<Map<String, dynamic>> _debugImages = const [];
  bool _wantDebugImages = false;
  bool _onlyLowConf = false;

  final Map<int, TextEditingController> _textCtrls = {};

  @override
  void initState() {
    super.initState();
    _tabC = TabController(length: 4, vsync: this);
    _tabC.addListener(_onTabChanged);
    _loadPrefsThenRegenerate();
    _loadScan();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _tabC.removeListener(_onTabChanged);
    _tabC.dispose();
    for (final c in _textCtrls.values) {
      c.dispose();
    }
    _scan?.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabC.index == 2 && !_wantDebugImages && mounted) {
      // "识别过程"页签首次打开 → 附带过程图重新生成
      _wantDebugImages = true;
      _regenerate();
    }
  }

  Future<void> _loadPrefsThenRegenerate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(ExcalidrawExportDialog._prefsKey);
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          _opts = ExcalidrawExportOptions.fromJson(decoded);
        }
      }
    } catch (_) {}
    if (mounted) _regenerate();
  }

  Future<void> _persistOpts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        ExcalidrawExportDialog._prefsKey,
        jsonEncode(_opts.toPersist()),
      );
    } catch (_) {}
  }

  Future<void> _loadScan() async {
    try {
      final bytes = await File(widget.imagePath).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (mounted) setState(() => _scan = frame.image);
    } catch (_) {
      // 底图加载失败只影响预览，不阻断导出
    }
  }

  /// 编辑器当前校对数据 → 后端 ocr_lines（区域过滤，字心在选区内才保留）。
  List<Map<String, dynamic>> _buildOcrLines() {
    final r = widget.region;
    final out = <Map<String, dynamic>>[];
    for (final line in widget.annotation.lines) {
      final lineRect = Rect.fromLTWH(line.x.toDouble(), line.y.toDouble(),
          line.w.toDouble(), line.h.toDouble());
      if (!lineRect.overlaps(r)) continue;
      final chars = <Map<String, dynamic>>[];
      for (final c in line.chars) {
        final cx = c.x + c.w / 2;
        final cy = c.y + c.h / 2;
        if (cx < r.left - 2 || cx > r.right + 2) continue;
        if (cy < r.top - 2 || cy > r.bottom + 2) continue;
        chars.add({
          'x': c.x,
          'y': c.y,
          'w': c.w,
          'h': c.h,
          'text': c.text,
          if (c.conf != null) 'conf': c.conf,
        });
      }
      if (chars.isNotEmpty) {
        out.add({'orientation': line.orientation, 'chars': chars});
      }
    }
    return out;
  }

  List<Map<String, dynamic>>? _textBoxPayload() {
    if (_textBoxes.isEmpty) return null;
    return _textBoxes
        .map((r) => {
              'x': r.left.round(),
              'y': r.top.round(),
              'w': r.width.round(),
              'h': r.height.round(),
            })
        .toList();
  }

  Future<void> _regenerate() async {
    if (_busy) return;
    final seq = ++_seq;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final data = await PythonService.exportExcalidraw(
        imagePath: widget.imagePath,
        x: widget.region.left.toInt(),
        y: widget.region.top.toInt(),
        w: widget.region.width.toInt(),
        h: widget.region.height.toInt(),
        settings: widget.pageSettings,
        options: _opts,
        ocrLines: _opts.textSource == 'recognize'
            ? null
            : (_opts.textSource == 'none' ? [] : _buildOcrLines()),
        textBoxes: _textBoxPayload(),
        debugImages: _wantDebugImages,
      );
      if (!mounted || seq != _seq) return;
      final stats = data['stats'] as Map?;
      setState(() {
        _scene = data['scene'] as Map<String, dynamic>?;
        _stats = stats;
        _trace = (data['debug_trace'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const [];
        _debugImages =
            (stats?['debug_images'] as List?)?.cast<Map<String, dynamic>>() ??
                const [];
        for (final c in _textCtrls.values) {
          c.dispose();
        }
        _textCtrls.clear();
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted && seq == _seq) setState(() => _busy = false);
    }
  }

  void _update(Map<String, dynamic> changes, {bool immediate = false}) {
    setState(() {
      _opts = ExcalidrawExportOptions.fromJson({
        ..._opts.toPersist(),
        ...changes,
      });
    });
    _persistOpts();
    _debounce?.cancel();
    if (immediate) {
      _regenerate();
    } else {
      _debounce = Timer(const Duration(milliseconds: 600), _regenerate);
    }
  }

  /// 画布坐标（预览局部）→ 图像坐标。
  Rect? _localToImage(Rect local) {
    final box = _canvasKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    final size = box.size;
    if (size.width <= 0 || size.height <= 0) return null;
    final sx = widget.region.width / size.width;
    final sy = widget.region.height / size.height;
    return Rect.fromLTRB(
      widget.region.left + local.left * sx,
      widget.region.top + local.top * sy,
      widget.region.left + local.right * sx,
      widget.region.top + local.bottom * sy,
    );
  }

  void _finishTextDraw() {
    final local = _drawPreviewLocal;
    _drawPreviewLocal = null;
    if (local == null) return;
    final imgRect = _localToImage(local);
    if (imgRect == null || imgRect.width < 6 || imgRect.height < 6) {
      setState(() {});
      return;
    }
    _textBoxes.add(imgRect);
    setState(() {});
    _regenerate();
  }

  TextEditingController _ctrlFor(int index, String initial) {
    return _textCtrls.putIfAbsent(index, () => TextEditingController(text: initial));
  }

  /// 校对改动直接写进场景 text 元素（保存时原样落盘）。
  /// el 是场景 elements 里的原始 Map 引用，原地修改。
  void _applyTextEdit(dynamic el, String text) {
    final fs = ((el['fontSize'] as num?)?.toDouble() ?? 12.0);
    var units = 0.0;
    for (final r in text.runes) {
      units += r > 0x2E7F ? 1.0 : 0.6;
    }
    el['text'] = text;
    el['originalText'] = text;
    el['width'] = (fs * units).toStringAsFixed(2);
  }

  Future<void> _save() async {
    final scene = _scene;
    if (scene == null) return;
    final path = await FilePicker.platform.saveFile(
      dialogTitle: '保存 Excalidraw 文件',
      fileName: '${p.basenameWithoutExtension(widget.imagePath)}.excalidraw',
      type: FileType.custom,
      allowedExtensions: ['excalidraw'],
    );
    if (path == null) return;
    File(path).writeAsStringSync(jsonEncode(scene), flush: true);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导出 → ${p.basename(path)}')),
      );
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1240, maxHeight: 800),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  Icon(Icons.draw_outlined, size: 20, color: theme.primaryColor),
                  const SizedBox(width: 8),
                  Text('Excalidraw 导出工作台',
                      style: theme.textTheme.titleMedium),
                  const SizedBox(width: 12),
                  Text(
                    '区域 (${widget.region.left.toInt()}, ${widget.region.top.toInt()}, '
                    '${widget.region.width.toInt()}×${widget.region.height.toInt()})',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.hintColor),
                  ),
                  const Spacer(),
                  if (_busy)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  IconButton(
                    tooltip: '重新框选区域',
                    icon: const Icon(Icons.crop_free, size: 20),
                    onPressed: () => Navigator.of(context).pop('repick'),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _buildPreview(theme)),
                  VerticalDivider(width: 1, color: theme.dividerColor),
                  SizedBox(
                    width: 400,
                    child: Column(
                      children: [
                        TabBar(
                          controller: _tabC,
                          labelColor: theme.primaryColor,
                          tabs: const [
                            Tab(text: '设置'),
                            Tab(text: '文字'),
                            Tab(text: '识别过程'),
                            Tab(text: '日志'),
                          ],
                        ),
                        Expanded(
                          child: TabBarView(
                            controller: _tabC,
                            children: [
                              _buildSettings(theme),
                              _buildTextTab(theme),
                              _buildProcessTab(theme),
                              _buildLogTab(theme),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            _buildFooter(theme),
          ],
        ),
      ),
    );
  }

  // ── 预览区 ──

  Widget _buildPreview(ThemeData theme) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(
                    value: 0,
                    icon: Icon(Icons.pan_tool, size: 14),
                    label: Text('浏览', style: TextStyle(fontSize: 12)),
                  ),
                  ButtonSegment(
                    value: 1,
                    icon: Icon(Icons.text_fields, size: 14),
                    label: Text('画文字框', style: TextStyle(fontSize: 12)),
                  ),
                ],
                selected: {_drawTextMode ? 1 : 0},
                onSelectionChanged: (v) =>
                    setState(() => _drawTextMode = v.first == 1),
              ),
              const SizedBox(width: 8),
              if (_textBoxes.isNotEmpty) ...[
                Text('文字框 ×${_textBoxes.length}',
                    style: TextStyle(fontSize: 12, color: theme.hintColor)),
                TextButton(
                  onPressed: () {
                    _textBoxes.clear();
                    _regenerate();
                  },
                  child: const Text('清除', style: TextStyle(fontSize: 12)),
                ),
              ],
              const Spacer(),
              const Text('底图'),
              Switch(
                value: _showScan,
                onChanged: (v) => setState(() => _showScan = v),
              ),
              if (_showScan)
                SizedBox(
                  width: 110,
                  child: Slider(
                    value: _scanOpacity,
                    min: 0.05,
                    max: 1.0,
                    onChanged: (v) => setState(() => _scanOpacity = v),
                  ),
                ),
              const Text('调试着色'),
              Switch(
                value: _debugColors,
                onChanged: (v) => setState(() => _debugColors = v),
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            color: Colors.white,
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: ClipRect(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final elements =
                      (_scene?['elements'] as List?)?.cast<Map<String, dynamic>>() ??
                          const <Map<String, dynamic>>[];
                  final localBoxes = _textBoxes
                      .map((r) => Rect.fromLTRB(
                            r.left - widget.region.left,
                            r.top - widget.region.top,
                            r.right - widget.region.left,
                            r.bottom - widget.region.top,
                          ))
                      .toList();
                  return InteractiveViewer(
                    maxScale: 8,
                    panEnabled: !_drawTextMode,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: _drawTextMode
                          ? (d) => setState(
                                () => _drawPreviewLocal = Rect.fromPoints(
                                    d.localPosition, d.localPosition),
                              )
                          : null,
                      onPanUpdate: _drawTextMode
                          ? (d) => setState(() {
                                if (_drawPreviewLocal != null) {
                                  _drawPreviewLocal = Rect.fromPoints(
                                    _drawPreviewLocal!.topLeft,
                                    d.localPosition,
                                  );
                                }
                              })
                          : null,
                      onPanEnd: _drawTextMode ? (_) => _finishTextDraw() : null,
                      child: MouseRegion(
                        cursor: _drawTextMode
                            ? SystemMouseCursors.precise
                            : MouseCursor.defer,
                        child: CustomPaint(
                          key: _canvasKey,
                          painter: _ScenePainter(
                            scan: _scan,
                            region: widget.region,
                            elements: elements,
                            showScan: _showScan,
                            scanOpacity: _scanOpacity,
                            debugColors: _debugColors,
                            textBoxes: localBoxes,
                            drawPreview: _drawPreviewLocal,
                          ),
                          child: AspectRatio(
                            aspectRatio:
                                widget.region.width / widget.region.height,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Text(
              _error!,
              style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }

  // ── 设置页签 ──

  Widget _buildSettings(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      children: [
        _section(theme, '文字'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'editor',
                label: Text('校对结果', style: TextStyle(fontSize: 12)),
                tooltip: '注入编辑器已校对的行/字数据，秒级生成',
              ),
              ButtonSegment(
                value: 'recognize',
                label: Text('重识别', style: TextStyle(fontSize: 12)),
                tooltip: '后端对区域重新跑分割 + Kraken（较慢）',
              ),
              ButtonSegment(
                value: 'none',
                label: Text('纯图形', style: TextStyle(fontSize: 12)),
                tooltip: '不含任何文字（配合"画文字框"只导出指定文字）',
              ),
            ],
            selected: {_opts.textSource},
            onSelectionChanged: (v) =>
                _update({'textSource': v.first}, immediate: true),
          ),
        ),
        _sliderTile(
          title: '字置信度阈值（低于不出文字）',
          value: _opts.minCharConf,
          min: 0,
          max: 0.95,
          divisions: 19,
          format: (v) => v.toStringAsFixed(2),
          onChanged: (v) => _update({'minCharConf': v}),
        ),
        _section(theme, '图形检测'),
        _switchTile('矩形 / 宫格', _opts.detectRects,
            (v) => _update({'detectRects': v})),
        _switchTile('圆 / 椭圆', _opts.detectEllipses,
            (v) => _update({'detectEllipses': v})),
        _switchTile('直线', _opts.detectLines,
            (v) => _update({'detectLines': v})),
        _switchTile('曲线笔画', _opts.detectCurves,
            (v) => _update({'detectCurves': v})),
        _switchTile('箭头识别', _opts.detectArrows,
            (v) => _update({'detectArrows': v})),
        _switchTile('平行双线合并（双栏线→单线）', _opts.mergeDoubleLines,
            (v) => _update({'mergeDoubleLines': v})),
        _sliderTile(
          title: '最小图形尺寸 px（滤小墨点）',
          value: _opts.minShapeSize.toDouble(),
          min: 4,
          max: 40,
          divisions: 36,
          format: (v) => v.round().toString(),
          onChanged: (v) => _update({'minShapeSize': v.round()}),
        ),
        _sliderTile(
          title: '直线最短长度 px',
          value: _opts.lineMinLen.toDouble(),
          min: 8,
          max: 80,
          divisions: 36,
          format: (v) => v.round().toString(),
          onChanged: (v) => _update({'lineMinLen': v.round()}),
        ),
        _sliderTile(
          title: '曲线抽稀容差 px（小=细节多）',
          value: _opts.curveSimplify,
          min: 1,
          max: 6,
          divisions: 10,
          format: (v) => v.toStringAsFixed(1),
          onChanged: (v) => _update({'curveSimplify': v}),
        ),
        _sliderTile(
          title: '端点吸附 px（0=关，拐角对齐）',
          value: _opts.snapTolerance.toDouble(),
          min: 0,
          max: 16,
          divisions: 16,
          format: (v) => v.round().toString(),
          onChanged: (v) => _update({'snapTolerance': v.round()}),
        ),
        _section(theme, '样式'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('简洁', style: TextStyle(fontSize: 12))),
              ButtonSegment(value: 1, label: Text('手绘', style: TextStyle(fontSize: 12))),
              ButtonSegment(value: 2, label: Text('粗糙', style: TextStyle(fontSize: 12))),
            ],
            selected: {_opts.roughness},
            onSelectionChanged: (v) => _update({'roughness': v.first}),
          ),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('线宽自动', style: TextStyle(fontSize: 12))),
              ButtonSegment(value: 1, label: Text('1', style: TextStyle(fontSize: 12))),
              ButtonSegment(value: 2, label: Text('2', style: TextStyle(fontSize: 12))),
              ButtonSegment(value: 4, label: Text('4', style: TextStyle(fontSize: 12))),
            ],
            selected: {_opts.strokeWidth},
            onSelectionChanged: (v) => _update({'strokeWidth': v.first}),
          ),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'original', label: Text('保留原色', style: TextStyle(fontSize: 12))),
              ButtonSegment(value: 'mono', label: Text('纯黑', style: TextStyle(fontSize: 12))),
              ButtonSegment(value: 'custom', label: Text('自定义', style: TextStyle(fontSize: 12))),
            ],
            selected: {_opts.colorMode},
            onSelectionChanged: (v) => _update({'colorMode': v.first}),
          ),
        ),
        if (_opts.colorMode == 'custom')
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in const [
                  '#1e1e1e', '#e03131', '#2f9e44', '#1971c2',
                  '#9c36b5', '#e8590c',
                ])
                  GestureDetector(
                    onTap: () => _update({'customColor': c}),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: _parseHex(c),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _opts.customColor == c
                              ? Colors.black87
                              : Colors.black26,
                          width: _opts.customColor == c ? 3 : 1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        _sliderTile(
          title: '画布缩放（1=原图 1:1）',
          value: _opts.scale,
          min: 0.5,
          max: 2,
          divisions: 3,
          format: (v) => '${v.toStringAsFixed(1)}×',
          onChanged: (v) => _update({'scale': v}),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 3, label: Text('标准字体', style: TextStyle(fontSize: 12))),
              ButtonSegment(value: 1, label: Text('手写字体', style: TextStyle(fontSize: 12))),
            ],
            selected: {_opts.fontFamily},
            onSelectionChanged: (v) => _update({'fontFamily': v.first}),
          ),
        ),
        _section(theme, '输出'),
        _switchTile('嵌入扫描底图（锁定底层）', _opts.embedImage,
            (v) => _update({'embedImage': v})),
        if (_opts.embedImage)
          _sliderTile(
            title: '底图不透明度 %',
            value: _opts.embedOpacity.toDouble(),
            min: 10,
            max: 100,
            divisions: 9,
            format: (v) => v.round().toString(),
            onChanged: (v) => _update({'embedOpacity': v.round()}),
          ),
        _switchTile('按类型分组（图形/文字各一组）', _opts.groupElements,
            (v) => _update({'groupElements': v})),
        const SizedBox(height: 12),
      ],
    );
  }

  // ── 文字校对页签 ──

  Widget _buildTextTab(ThemeData theme) {
    final scene = _scene;
    if (scene == null) {
      return Center(
        child: Text('尚未生成场景', style: TextStyle(color: theme.hintColor)),
      );
    }
    final elements = (scene['elements'] as List?)
            ?.whereType<Map>()
            .where((e) => e['type'] == 'text')
            .toList() ??
        const [];
    final meta = (_stats?['text_meta'] as List?) ?? const [];
    final lowCount = meta.where((m) {
      final conf = (m is Map) ? m['conf'] : null;
      return conf != null && (conf as num) < 0.5;
    }).length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${elements.length} 个文字元素，改动直接写入导出文件'
                  '${lowCount > 0 ? '（$lowCount 个低置信）' : ''}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.hintColor),
                ),
              ),
              if (lowCount > 0)
                FilterChip(
                  label: const Text('仅看低置信', style: TextStyle(fontSize: 12)),
                  selected: _onlyLowConf,
                  onSelected: (v) => setState(() => _onlyLowConf = v),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: elements.isEmpty
              ? Center(
                  child: Text('无文字元素（纯图形模式或区域无文字）',
                      style: TextStyle(color: theme.hintColor)),
                )
              : ListView.builder(
                  itemCount: elements.length,
                  itemBuilder: (context, index) {
                    final el = Map<String, dynamic>.from(elements[index]);
                    final m = index < meta.length && meta[index] is Map
                        ? Map<String, dynamic>.from(meta[index])
                        : null;
                    final conf = (m?['conf'] as num?)?.toDouble();
                    final isLow = conf != null && conf < 0.5;
                    if (_onlyLowConf && !isLow) {
                      return const SizedBox.shrink();
                    }
                    final kindLabel = m?['kind'] == 'line' ? '整行' : '单字';
                    return ListTile(
                      dense: true,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 12),
                      leading: SizedBox(
                        width: 68,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(kindLabel,
                                style: const TextStyle(fontSize: 11)),
                            Text(
                              conf == null
                                  ? '—'
                                  : conf.toStringAsFixed(2),
                              style: TextStyle(
                                fontSize: 11,
                                color: isLow
                                    ? Colors.red.shade700
                                    : ((conf ?? 1.0) < 0.8
                                        ? Colors.orange.shade800
                                        : Colors.green.shade700),
                              ),
                            ),
                          ],
                        ),
                      ),
                      title: TextField(
                        controller: _ctrlFor(index, el['text'] as String? ?? ''),
                        style: TextStyle(
                          fontSize: 14,
                          color: isLow ? Colors.red.shade900 : null,
                        ),
                        decoration: const InputDecoration(
                          isDense: true,
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                              horizontal: 8, vertical: 6),
                        ),
                        onChanged: (v) => _applyTextEdit(elements[index], v),
                      ),
                      subtitle: Text(
                        '(${((el['x'] as num?)?.toDouble() ?? 0).round()},'
                        '${((el['y'] as num?)?.toDouble() ?? 0).round()})'
                        '${isLow ? ' · 低置信，建议核对' : ''}',
                        style: const TextStyle(fontSize: 10),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ── 识别过程页签 ──

  Widget _buildProcessTab(ThemeData theme) {
    if (!_wantDebugImages) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('生成过程图（墨迹掩膜 / 直线层 / 图形元素 / 叠加文字）',
                style: TextStyle(color: theme.hintColor, fontSize: 13)),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _busy ? null : () {
                _wantDebugImages = true;
                _regenerate();
              },
              child: const Text('生成过程图'),
            ),
          ],
        ),
      );
    }
    if (_debugImages.isEmpty) {
      return Center(
        child: _busy
            ? const CircularProgressIndicator(strokeWidth: 2)
            : Text('暂无过程图', style: TextStyle(color: theme.hintColor)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _debugImages.length,
      itemBuilder: (context, index) {
        final item = _debugImages[index];
        final dataUrl = item['data_url'] as String? ?? '';
        final name = item['name'] as String? ?? '';
        if (!dataUrl.startsWith('data:image/png;base64,')) {
          return const SizedBox.shrink();
        }
        final bytes = base64Decode(dataUrl.substring('data:image/png;base64,'.length));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Image.memory(bytes, gaplessPlayback: true),
            const SizedBox(height: 16),
          ],
        );
      },
    );
  }

  // ── 日志页签 ──

  Widget _buildLogTab(ThemeData theme) {
    if (_trace.isEmpty) {
      return Center(
        child: Text('暂无日志', style: TextStyle(color: theme.hintColor)),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '本次生成的管线日志（共 ${_trace.length} 条）',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.hintColor),
                ),
              ),
              IconButton(
                tooltip: '复制全部',
                icon: const Icon(Icons.copy, size: 16),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: _trace.join('\n')));
                },
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            itemCount: _trace.length,
            itemBuilder: (context, index) {
              final line = _trace[index];
              return Text(
                line,
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'Consolas, monospace',
                  color: line.contains('拒绝') || line.contains('失败')
                      ? Colors.orange.shade900
                      : null,
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // ── 底栏 ──

  Widget _buildFooter(ThemeData theme) {
    final stats = _stats;
    String label = '尚未生成';
    if (stats != null) {
      int g(Object key) => (stats[key] as num?)?.toInt() ?? 0;
      final coverage = ((stats['ink_coverage'] as num?)?.toDouble() ?? 0) * 100;
      label = '${g('rectangles')} 矩形 · ${g('ellipses')} 圆 · '
          '${g('lines')} 线 · ${g('curves')} 曲线 · ${g('arrows')} 箭头 · '
          '${g('chars')} 字 · 墨迹覆盖 ${coverage.toStringAsFixed(0)}%';
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.hintColor)),
          ),
          OutlinedButton.icon(
            onPressed: _busy ? null : _regenerate,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重新生成'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: (_scene == null || _busy) ? null : _save,
            icon: const Icon(Icons.save_outlined, size: 18),
            label: const Text('保存 .excalidraw'),
          ),
        ],
      ),
    );
  }

  Widget _section(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Text(
        title,
        style: theme.textTheme.labelMedium
            ?.copyWith(color: theme.primaryColor, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _switchTile(String title, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      title: Text(title, style: const TextStyle(fontSize: 13)),
      value: value,
      onChanged: onChanged,
    );
  }

  Widget _sliderTile({
    required String title,
    required double value,
    required double min,
    required double max,
    int? divisions,
    required String Function(double) format,
    required ValueChanged<double>? onChanged,
  }) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      title: Text(title, style: const TextStyle(fontSize: 13)),
      subtitle: Row(
        children: [
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              label: format(value),
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 34,
            child: Text(format(value),
                style: const TextStyle(fontSize: 12),
                textAlign: TextAlign.end),
          ),
        ],
      ),
    );
  }

  static Color _parseHex(String hex) {
    try {
      return Color(0xFF000000 | int.parse(hex.substring(1), radix: 16));
    } catch (_) {
      return const Color(0xFF1E1E1E);
    }
  }
}

/// 场景元素叠加预览绘制（近似渲染：不做手绘粗糙效果，几何/颜色/虚线忠实）。
class _ScenePainter extends CustomPainter {
  _ScenePainter({
    required this.scan,
    required this.region,
    required this.elements,
    required this.showScan,
    required this.scanOpacity,
    required this.debugColors,
    required this.textBoxes,
    required this.drawPreview,
  });

  final ui.Image? scan;
  final Rect region;
  final List<Map<String, dynamic>> elements;
  final bool showScan;
  final double scanOpacity;
  final bool debugColors;
  final List<Rect> textBoxes; // 区域坐标
  final Rect? drawPreview; // 画布坐标（拖拽中）

  static const _debugColorsByType = <String, Color>{
    'rectangle': Color(0xFF1971C2),
    'ellipse': Color(0xFF2F9E44),
    'line': Color(0xFFE8590C),
    'text': Color(0xFF9C36B5),
  };

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / region.width;
    canvas.save();
    canvas.clipRect(Offset.zero & size);

    if (showScan && scan != null) {
      final paint = Paint()
        ..color = Colors.white.withValues(alpha: scanOpacity);
      canvas.drawImageRect(
        scan!,
        region,
        Offset.zero & size,
        paint,
      );
    }

    for (final el in elements) {
      final type = el['type'] as String? ?? '';
      if (type == 'image') continue; // 底图元素在预览里由扫描图承担
      final color = debugColors
          ? (_debugColorsByType[type] ?? const Color(0xFFE03131))
          : _parseColor(el['strokeColor'] as String?);
      final strokeWidth = (el['strokeWidth'] as num?)?.toDouble() ?? 1.0;
      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = (strokeWidth * s).clamp(0.5, 6.0);
      if ((el['strokeStyle'] as String?) == 'dashed') {
        paint.strokeWidth = (paint.strokeWidth * 0.6).clamp(0.4, 4.0);
      }
      final bg = el['backgroundColor'] as String?;
      if (bg != null && bg != 'transparent') {
        final fill = Paint()..color = _parseColor(bg);
        _paintShape(canvas, el, s, fill, isFill: true);
      }
      _paintShape(canvas, el, s, paint);
      _paintText(canvas, el, s, color);
    }

    // 手画文字框（青）与拖拽预览
    final boxPaint = Paint()
      ..color = const Color(0xFF00E5E5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final b in textBoxes) {
      canvas.drawRect(
        Rect.fromLTRB(b.left * s, b.top * s, b.right * s, b.bottom * s),
        boxPaint,
      );
    }
    if (drawPreview != null) {
      canvas.drawRect(drawPreview!, boxPaint);
    }
    canvas.restore();
  }

  void _paintShape(Canvas canvas, Map<String, dynamic> el, double s, Paint paint,
      {bool isFill = false}) {
    if (isFill) paint.style = PaintingStyle.fill;
    final x = (el['x'] as num).toDouble() * s;
    final y = (el['y'] as num).toDouble() * s;
    final w = (el['width'] as num).toDouble() * s;
    final h = (el['height'] as num).toDouble() * s;
    final type = el['type'] as String? ?? '';
    if (type == 'rectangle') {
      canvas.drawRect(Rect.fromLTWH(x, y, w, h), paint);
    } else if (type == 'ellipse') {
      canvas.drawOval(Rect.fromLTWH(x, y, w, h), paint);
    } else if (type == 'line') {
      final points = (el['points'] as List)
          .map((pt) => Offset(
                x + ((pt as List)[0] as num).toDouble() * s,
                y + (pt[1] as num).toDouble() * s,
              ))
          .toList();
      if (points.length == 2) {
        canvas.drawLine(points.first, points.last, paint);
      } else if (points.length > 2) {
        final path = Path()..moveTo(points.first.dx, points.first.dy);
        for (final pt in points.skip(1)) {
          path.lineTo(pt.dx, pt.dy);
        }
        canvas.drawPath(path, paint);
      }
    }
  }

  void _paintText(Canvas canvas, Map<String, dynamic> el, double s, Color color) {
    if ((el['type'] as String?) != 'text') return;
    final text = el['text'] as String? ?? '';
    if (text.isEmpty) return;
    final fontSize = ((el['fontSize'] as num?)?.toDouble() ?? 12) * s;
    if (fontSize < 3) return; // 缩得太小不画，避免噪点
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: fontSize, color: color),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      Offset((el['x'] as num).toDouble() * s, (el['y'] as num).toDouble() * s),
    );
  }

  Color _parseColor(String? hex) {
    if (hex == null || hex.length != 7 || !hex.startsWith('#')) {
      return const Color(0xFF1E1E1E);
    }
    try {
      return Color(0xFF000000 | int.parse(hex.substring(1), radix: 16));
    } catch (_) {
      return const Color(0xFF1E1E1E);
    }
  }

  @override
  bool shouldRepaint(covariant _ScenePainter old) {
    return old.scan != scan ||
        old.elements != elements ||
        old.showScan != showScan ||
        old.scanOpacity != scanOpacity ||
        old.debugColors != debugColors ||
        old.region != region ||
        old.textBoxes != textBoxes ||
        old.drawPreview != drawPreview;
  }
}
