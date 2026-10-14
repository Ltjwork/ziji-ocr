import 'dart:convert' show base64Encode;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../services/direct_text_store.dart';
import '../services/ollama_service.dart';
import '../services/python_service.dart';
import 'char_rainbow.dart';

/// 编辑器「文本」视图：**左右分栏**——左侧书页栏（与标注视图同款的
/// 书页展示：解码位图 + 缩放平移；不画任何识别框，可选叠加"行文对照"
/// ——把每行识别文本按竖排逐字画在列旁），右侧文本栏（整页直读文本：
/// 可编辑 / AI 校对 / 保存 / 复制）。
///
/// 整页直读（PaddleOCR det+rec 全管线 / Kraken blla 分行 + CHAT 读字）
/// 不走主区/段落/单行/单字标注管线；直读文本落盘在书目录 direct_text/
/// 子目录（与标注 JSON 解耦，不进训练数据）。面板按 pageId 作 key，
/// 翻页即换内容；引擎用本书设置，方向用本页有效方向。
class DirectTextPanel extends StatefulWidget {
  const DirectTextPanel({
    super.key,
    required this.project,
    required this.pageId,
    required this.imagePath,
    required this.settings,
    this.onSnackBar,
    this.onReadComplete,
  });

  final Project project;
  final String pageId;
  final String imagePath;
  final ProjectSettings settings;

  /// 宿主编辑器的 SnackBar 回调（无则用本面板自己的 ScaffoldMessenger）。
  final void Function(String message, {bool error})? onSnackBar;

  /// 整页直读完成且文本/行记录已落盘后回调（宿主编辑器用它刷新标注里
  /// 的整页对照标记——紫色无框字片/橙色不一致标记随新直读文本更新）。
  final void Function()? onReadComplete;

  @override
  State<DirectTextPanel> createState() => _DirectTextPanelState();
}

/// 一行直读结果：行框（原图坐标）+ 当前行文本（随文本栏编辑同步）+
/// 逐字框（kraken cuts 重建，有则行文对照逐字对齐到书页字形；无则按
/// 列高均分对齐）。
class _LineRecord {
  _LineRecord({required this.box, required this.text, this.charBoxes});

  final Rect box;
  String text;
  final List<Rect>? charBoxes;
}

class _DirectTextPanelState extends State<DirectTextPanel> {
  final TextEditingController _controller = TextEditingController();
  bool _recognizing = false;
  bool _aiRunning = false;
  bool _dirty = false;

  /// 最近一次直读的元信息（状态行展示：引擎/行数/耗时）。
  Map<String, dynamic>? _lastRead;

  /// 当前文本的实际产出元数据（引擎/模型/耗时），落盘侧车
  /// `<pageId>.meta.json`——本书引擎/模型改过之后旧文本不会自动重读，
  /// 状态栏靠它区分"本书配置的模型"和"看到的文本是谁读的"。
  Map<String, dynamic>? _readMeta;

  // ── 左侧书页栏 ──
  ui.Image? _pageImage;
  Size _pageSize = Size.zero;
  final TransformationController _pageTransform = TransformationController();
  final GlobalKey _pageViewportKey = GlobalKey();

  /// 「行文对照」开关：书页每行旁叠加显示该行识别文本。
  bool _showLineOverlay = true;

  /// 行框 + 行文本（识别时重建；文本栏编辑按行号同步 text）。
  List<_LineRecord> _lineRecords = const [];

  /// 叠加层重画信号（编辑同步时只重画叠加层，不重建整个面板）。
  final ValueNotifier<int> _overlayRepaint = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _controller.addListener(_syncOverlayWithText);
    _loadSaved();
    _loadPageImage();
  }

  @override
  void dispose() {
    _controller.removeListener(_syncOverlayWithText);
    _controller.dispose();
    _overlayRepaint.dispose();
    _pageTransform.dispose();
    _pageImage?.dispose();
    super.dispose();
  }

  void _snack(String message, {bool error = false}) {
    final cb = widget.onSnackBar;
    if (cb != null) {
      cb(message, error: error);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _loadSaved() async {
    final saved = await DirectTextStore.load(widget.project, widget.pageId);
    final meta = await DirectTextStore.loadMeta(widget.project, widget.pageId);
    if (!mounted) return;
    setState(() {
      _controller.text = saved ?? '';
      _readMeta = meta;
      _dirty = false;
    });
  }

  /// 书页位图：与标注画布同款解码（instantiateImageCodec → ui.Image，
  /// 换页/退出释放纹理）。
  Future<void> _loadPageImage() async {
    final path = widget.imagePath;
    try {
      final bytes = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      if (!mounted || path != widget.imagePath) {
        img.dispose();
        return;
      }
      setState(() {
        _pageImage?.dispose();
        _pageImage = img;
        _pageSize = Size(img.width.toDouble(), img.height.toDouble());
      });
      _fitPageToViewport();
    } catch (e) {
      if (mounted) _snack('书页图读取失败：$e', error: true);
    }
  }

  /// 首帧按视口适配整页（居中、留 4% 边距）。postFrame 拿视口尺寸。
  void _fitPageToViewport() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _pageViewportKey.currentContext;
      final box = context?.findRenderObject() as RenderBox?;
      if (box == null || !mounted || _pageSize.isEmpty) return;
      final size = box.size;
      final scale = math.min(
            size.width / _pageSize.width,
            size.height / _pageSize.height,
          ) *
          0.96;
      final dx = (size.width - _pageSize.width * scale) / 2;
      final dy = (size.height - _pageSize.height * scale) / 2;
      _pageTransform.value = Matrix4.identity()
        ..translateByDouble(dx, dy, 0, 1)
        ..scaleByDouble(scale, scale, 1, 1);
    });
  }

  String get _engineLabel {
    if (widget.settings.engine == 'paddle') {
      return 'PaddleOCR（${widget.settings.paddleModel}）';
    }
    return 'Kraken';
  }

  /// 当前文本的实际产出标签（元数据侧车里记的引擎/模型），无记录 null。
  String? get _producedLabel {
    final meta = _readMeta;
    if (meta == null) return null;
    final engine = (meta['engine'] ?? '').toString();
    final ocr = (meta['ocr'] ?? '').toString();
    final model = ocr.contains('+') ? ocr.split('+').skip(1).join('+') : '';
    if (engine == 'paddle') {
      return 'PaddleOCR（${model.isEmpty ? widget.settings.paddleModel : model}）';
    }
    if (engine == 'kraken') return 'Kraken';
    return engine.isEmpty ? null : engine;
  }

  /// 实际产出与本书当前选择是否不一致——不一致说明界面上的文本还是
  /// 旧模型读的（改引擎/模型不会自动重读），状态栏要提醒用户重新识别。
  bool get _readStale {
    final meta = _readMeta;
    if (meta == null) return false;
    final engine = (meta['engine'] ?? '').toString();
    if (engine != widget.settings.engine) return true;
    if (engine == 'paddle') {
      final ocr = (meta['ocr'] ?? '').toString();
      final model = ocr.contains('+') ? ocr.split('+').skip(1).join('+') : '';
      return model.isNotEmpty && model != widget.settings.paddleModel;
    }
    return false;
  }

  /// 文本栏编辑 → 行文对照按行号同步（行数一致时逐行更新叠加文本；
  /// 增删过行则保持识别时的原文，不做错位同步）。
  void _syncOverlayWithText() {
    if (!_dirty) setState(() => _dirty = true);
    if (_lineRecords.isEmpty) return;
    final lines = _controller.text.split('\n');
    if (lines.length != _lineRecords.length) return;
    for (var i = 0; i < lines.length; i++) {
      _lineRecords[i].text = lines[i];
    }
    // 仅重画叠加层：文本框每次按键都触发，不重 Build 整个面板。
    _overlayRepaint.value++;
  }

  Future<void> _recognize() async {
    if (_recognizing) return;
    setState(() => _recognizing = true);
    try {
      final result = await PythonService.readPageText(
        imagePath: widget.imagePath,
        settings: widget.settings,
      );
      if (!mounted) return;
      final text = (result['text'] as String?) ?? '';
      final rawLines = (result['lines'] as List? ?? const []);
      List<Rect>? parseCharBoxes(Map l) {
        final raw = l['chars'] as List?;
        if (raw == null || raw.isEmpty) return null;
        return [
          for (final c in raw)
            if (c is Map && (c['w'] as num?) != null && (c['w'] as num) > 0)
              Rect.fromLTWH(
                (c['x'] as num?)?.toDouble() ?? 0,
                (c['y'] as num?)?.toDouble() ?? 0,
                (c['w'] as num).toDouble(),
                (c['h'] as num?)?.toDouble() ?? 0,
              ),
        ];
      }

      final records = <_LineRecord>[
        for (final l in rawLines)
          if (l is Map)
            _LineRecord(
              box: Rect.fromLTWH(
                (l['x'] as num?)?.toDouble() ?? 0,
                (l['y'] as num?)?.toDouble() ?? 0,
                (l['w'] as num?)?.toDouble() ?? 0,
                (l['h'] as num?)?.toDouble() ?? 0,
              ),
              text: (l['text'] as String?) ?? '',
              charBoxes: parseCharBoxes(l),
            ),
      ];
      setState(() {
        _controller.text = text;
        _lastRead = result;
        _lineRecords = records;
        _dirty = false;
      });
      // 识别结果即时落盘：翻页/退出不丢，之后的编辑由用户手动保存。
      // 元数据侧车记下"这份文本是哪个引擎/模型读的"，状态栏好如实回答；
      // line_records 是逐行框+文本——默认识别流程的全文对照（无框字符
      // 紫片/不一致字橙标）以此为整页参照（后端零推理读侧车）。
      final readMeta = <String, dynamic>{
        'engine': result['engine']?.toString() ?? '',
        'ocr': result['ocr']?.toString() ?? '',
        'elapsed_s': result['elapsed_s']?.toString() ?? '',
        'lines': records.length,
        'line_records': [
          for (final r in records)
            {
              'x': r.box.left.round(),
              'y': r.box.top.round(),
              'w': r.box.width.round(),
              'h': r.box.height.round(),
              'text': r.text,
            },
        ],
        'read_at': DateTime.now().toIso8601String(),
      };
      await DirectTextStore.save(widget.project, widget.pageId, text);
      await DirectTextStore.saveMeta(widget.project, widget.pageId, readMeta);
      if (mounted) setState(() => _readMeta = readMeta);
      widget.onReadComplete?.call();
      _snack(
        '整页直读完成：${records.length} 行、${text.length} 字'
        '（${result['elapsed_s']}s，$_engineLabel）',
      );
    } catch (e) {
      if (mounted) _snack('整页直读失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _recognizing = false);
    }
  }

  Future<void> _save() async {
    try {
      await DirectTextStore.save(
        widget.project,
        widget.pageId,
        _controller.text,
      );
      if (!mounted) return;
      setState(() => _dirty = false);
      _snack('直读文本已保存（direct_text/${widget.pageId}.txt）');
    } catch (e) {
      if (mounted) _snack('保存失败：$e', error: true);
    }
  }

  Future<void> _aiProofread() async {
    if (_aiRunning) return;
    if (_controller.text.trim().isEmpty) {
      _snack('先「识别本页」得到直读文本，再做 AI 校对');
      return;
    }
    setState(() => _aiRunning = true);
    try {
      final ai = await OllamaSettings.load();
      String? imageBase64;
      if (ai.activeVisionModel.isNotEmpty) {
        try {
          final bytes = await File(widget.imagePath).readAsBytes();
          imageBase64 = base64Encode(bytes);
        } catch (_) {
          imageBase64 = null; // 页图读不出：退化为纯文本校对
        }
      }
      final corrected = await OllamaService.proofreadPageText(
        settings: ai,
        pageText: _controller.text,
        pageImageBase64: imageBase64,
        orientation: widget.settings.orientation,
        horizontalDir: widget.settings.horizontalDir,
        verticalDir: widget.settings.verticalDir,
      );
      if (!mounted) return;
      await _showProofreadResult(corrected);
    } catch (e) {
      if (mounted) _snack('AI 校对失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _aiRunning = false);
    }
  }

  /// 校对结果预览：展示校对后全文（可选中复制），「采用」替换文本框。
  Future<void> _showProofreadResult(String corrected) async {
    final same = corrected.trim() == _controller.text.trim();
    final apply = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('AI 校对结果'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  same ? 'AI 未发现需要修改的地方' : '校对后全文（可选中复制）：',
                  style: const TextStyle(fontSize: 12.5, color: Colors.grey),
                ),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: Container(
                  constraints: const BoxConstraints(maxHeight: 420),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      corrected,
                      style: const TextStyle(
                        fontSize: 14,
                        height: 1.5,
                        fontFamily: 'serif',
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: same ? null : () => Navigator.pop(ctx, true),
            child: const Text('采用（替换文本框）'),
          ),
        ],
      ),
    );
    if (apply != true || !mounted) return;
    setState(() {
      _controller.text = corrected;
      _dirty = true;
    });
    _snack('已采用 AI 校对结果，记得「保存」落盘');
  }

  // ── 左侧书页栏 ──

  Widget _buildPagePanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 顶部小工具条：行文对照开关 + 状态提示
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
          child: Row(
            children: [
              const Text('书页', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _lineRecords.isEmpty
                      ? '未识别（无行文对照数据）'
                      : '${_lineRecords.length} 行'
                          '${_dirty ? ' · 文本栏有未保存修改' : ''}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
              const Text('行文对照', style: TextStyle(fontSize: 12)),
              Switch(
                value: _showLineOverlay,
                onChanged: (v) => setState(() => _showLineOverlay = v),
              ),
            ],
          ),
        ),
        Expanded(
          child: _pageImage == null
              ? const Center(child: CircularProgressIndicator())
              : InteractiveViewer(
                  key: _pageViewportKey,
                  transformationController: _pageTransform,
                  constrained: false,
                  boundaryMargin: const EdgeInsets.all(double.infinity),
                  minScale: 0.05,
                  maxScale: 8,
                  child: SizedBox(
                    width: _pageSize.width,
                    height: _pageSize.height,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        RawImage(
                          image: _pageImage,
                          width: _pageSize.width,
                          height: _pageSize.height,
                          fit: BoxFit.fill,
                        ),
                        if (_showLineOverlay && _lineRecords.isNotEmpty)
                          ValueListenableBuilder<int>(
                            valueListenable: _overlayRepaint,
                            builder: (context, _, __) => CustomPaint(
                              size: _pageSize,
                              painter: _LineTextOverlayPainter(
                                records: _lineRecords,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  // ── 右侧文本栏 ──

  Widget _buildTextPanel() {
    final text = _controller.text;
    final lineCount = text.isEmpty ? 0 : '\n'.allMatches(text).length + 1;
    final meta = _lastRead;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: _recognizing ? null : _recognize,
                icon: _recognizing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.document_scanner, size: 18),
                label: Text(
                  text.isEmpty && !_dirty ? '识别本页' : '重新识别',
                ),
              ),
              OutlinedButton.icon(
                onPressed: _aiRunning ? null : _aiProofread,
                icon: _aiRunning
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_fix_high, size: 18),
                label: const Text('AI 校对'),
              ),
              OutlinedButton.icon(
                onPressed: _dirty ? _save : null,
                icon: const Icon(Icons.save_outlined, size: 18),
                label: Text(_dirty ? '保存' : '已保存'),
              ),
              OutlinedButton.icon(
                onPressed: text.isEmpty
                    ? null
                    : () async {
                        await Clipboard.setData(ClipboardData(text: text));
                        _snack('已复制整页文本');
                      },
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('复制'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text.rich(
            TextSpan(
              style: const TextStyle(fontSize: 11.5, color: Colors.grey),
              children: [
                // 状态栏如实区分"文本是谁读的"与"本书现在选的"：有产出
                // 记录显示"文本由 X 识别"；与当前选择不一致（改了引擎/
                // 模型还没重读）时橙字提醒，避免用户误以为已经在用新模型。
                TextSpan(
                  text: _producedLabel != null
                      ? '文本由 $_producedLabel 识别'
                      : '引擎 $_engineLabel',
                ),
                TextSpan(
                  text:
                      ' · $lineCount 行 · ${text.characters.length} 字'
                      '${meta != null ? ' · 上次直读 ${meta['elapsed_s']}s/${(meta['lines'] as List?)?.length ?? 0} 行' : ''}'
                      '${_dirty ? ' · 有未保存修改' : ''}',
                ),
                if (_readStale)
                  TextSpan(
                    text: '　⚠ 本书已选 $_engineLabel，点「重新识别」用新模型重读',
                    style: TextStyle(
                      color: Colors.orange.shade800,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                const TextSpan(text: '　本视图不产生标注框，精校请回标注视图'),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: TextField(
              controller: _controller,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(fontSize: 15, height: 1.6),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '点「识别本页」用所选引擎整页直读（不拆主区/段落/'
                    '单行/单字），结果填入此处，可编辑、可 AI 校对、可保存；'
                    '左侧书页可开「行文对照」逐行比对',
                hintStyle: TextStyle(fontSize: 12.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 左：书页栏（现有书页展示方案，无识别框；可叠加行文对照）
        Expanded(child: _buildPagePanel()),
        const VerticalDivider(width: 1),
        // 右：文本栏
        Expanded(child: _buildTextPanel()),
      ],
    );
  }
}

/// 行文对照叠加层：把每行识别文本以**小字**画在书页对应行的旁边，逐字
/// 与书页文字对齐、不遮正文与邻列。
///
/// 竖排行（框高 ≥ 框宽）：字号约 0.45 列宽（远小于列宽，不再盖住邻列），
/// 字片右缘贴列框左缘（只占列间空隙）；**逐字对齐**——行带逐字框
/// （kraken cuts）时每个字片中心对准对应字框中心，无字框（paddle）时
/// 按列高均分对齐。页面最左列左缘越界时收紧贴边（不向右侵入正文）。
/// 横排行：小字整行画在行框下方。每字/整行带半透明白底圆角片。
///
/// 字片文字用高亮色而非黑色：按行序循环取彩虹色板（与编辑器单字框
/// 同一套 kCharRainbow 语义），同一行同色、相邻行异色，黑白书页上
/// 一眼可辨且不会与正文墨迹混淆。
class _LineTextOverlayPainter extends CustomPainter {
  _LineTextOverlayPainter({required this.records});

  final List<_LineRecord> records;

  /// 字位过小（碎片行在当前行高里排不下可读字号）不画，避免糊成噪点。
  static const double _minChip = 6.0;

  TextPainter _tp(String text, double fontPx, Color color) => TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(fontSize: fontPx, height: 1.0, color: color),
    ),
    textDirection: TextDirection.ltr,
  );

  void _paintChip(
    Canvas canvas,
    Rect chip,
    TextPainter tp,
    double fontPx,
    Color color,
  ) {
    final rrect = RRect.fromRectAndRadius(
      chip,
      Radius.circular(fontPx * 0.2),
    );
    canvas.drawRRect(rrect, Paint()..color = Colors.white.withValues(alpha: 0.8));
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(0.4, fontPx * 0.05)
        ..color = color.withValues(alpha: 0.45),
    );
    tp.layout();
    // 文本居进片内：显式算半偏移（Size 运算符重载链上 OffsetBase 无 `/`）
    tp.paint(
      canvas,
      chip.topLeft +
          Offset((chip.width - tp.width) / 2, (chip.height - tp.height) / 2),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (var ri = 0; ri < records.length; ri++) {
      final rec = records[ri];
      // 行级高亮色：同一行所有字片同色，相邻行从彩虹色板轮换。
      final color = charRainbowColor(ri);
      final text = rec.text.trim();
      if (text.isEmpty || rec.box.isEmpty) continue;
      final vertical = rec.box.height >= rec.box.width;
      if (vertical) {
        final chars = text.characters.toList();
        // 小字对照：约 0.45 列宽（再大就盖到邻列文字）；受"均分列高也
        // 挤不下"约束（对齐优先于字号，超长读法缩字）。
        final fontPx = math.min(
          rec.box.width * 0.45,
          rec.box.height / chars.length,
        );
        if (fontPx < _minChip) continue;
        final chipW = fontPx * 1.2;
        final boxes = rec.charBoxes;
        final step = rec.box.height / chars.length;
        for (var i = 0; i < chars.length; i++) {
          // 字位（原图 y 系）：有逐字框按字框对齐，否则均分列高。
          final charBox = (boxes != null && i < boxes.length) ? boxes[i] : null;
          final cy = charBox != null
              ? charBox.center.dy
              : rec.box.top + step * (i + 0.5);
          final chipH = math.min(
            charBox != null ? charBox.height : step,
            fontPx * 1.3,
          );
          // 右缘贴列框左缘（只占列间空隙）；页面左缘越界收紧贴边，
          // 不向右侵入本列正文。
          final x = math.max(0.0, rec.box.left - chipW - 1);
          _paintChip(
            canvas,
            Rect.fromLTWH(x, cy - chipH / 2, chipW, chipH),
            _tp(chars[i], fontPx, color),
            fontPx,
            color,
          );
        }
      } else {
        // 横排：小字整行画在行框下方（左对齐），字号约 0.55 行高。
        final fontPx = (rec.box.height * 0.55).clamp(9.0, 26.0).toDouble();
        final tp = _tp(text, fontPx, color)..layout();
        _paintChip(
          canvas,
          Rect.fromLTWH(
            rec.box.left,
            rec.box.bottom + fontPx * 0.1,
            tp.width + fontPx * 0.24,
            fontPx * 1.15,
          ),
          tp,
          fontPx,
          color,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_LineTextOverlayPainter old) => true;

  /// records 的 text 会被文本栏编辑就地更新（同一 list 实例、内容已变），
  /// 引用比较判不出差异——本 painter 只随 _overlayRepaint 重建，恒重画
  /// 开销可忽略（每页几十个字片）。
}
