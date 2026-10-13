import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

/// 命中判定：图像像素坐标 [px]/[py] 落在哪个字框内，返回
/// {lineIndex, charIndex}；顶层纯函数便于单测。字框互不重叠时先中先得，
/// 重叠时取面积更小者（更精确的那一个）。
Map<String, int>? hitTestChar(
  double px,
  double py,
  List<Map<String, dynamic>> lines,
) {
  Map<String, int>? best;
  double bestArea = double.infinity;
  for (var li = 0; li < lines.length; li++) {
    final chars = lines[li]['chars'];
    if (chars is! List) continue;
    for (var ci = 0; ci < chars.length; ci++) {
      final c = chars[ci];
      if (c is! Map) continue;
      final x = (c['x'] as num?)?.toDouble() ?? 0;
      final y = (c['y'] as num?)?.toDouble() ?? 0;
      final w = (c['w'] as num?)?.toDouble() ?? 0;
      final h = (c['h'] as num?)?.toDouble() ?? 0;
      if (w <= 0 || h <= 0) continue;
      if (px >= x && px <= x + w && py >= y && py <= y + h) {
        final area = w * h;
        if (area < bestArea) {
          bestArea = area;
          best = {'lineIndex': li, 'charIndex': ci};
        }
      }
    }
  }
  return best;
}

/// 朝代基准样张详情页（人工查看效果）：原图缩放平移 + 行/字框叠加 +
/// 点选单字看文字与置信度；右侧对照「基准释文（应识别）」与
/// 「识别文字（按行）」。[lines] 为 null 表示该记录没有字框数据
/// （旧版记录或尚未运行），只展示图片与基准释文。
class DynastyBenchDetailPage extends StatefulWidget {
  final String title;
  final String imagePath;
  final List<Map<String, dynamic>> gtUnits;
  final List<Map<String, dynamic>>? lines;
  final Map<String, dynamic>? report;

  const DynastyBenchDetailPage({
    super.key,
    required this.title,
    required this.imagePath,
    required this.gtUnits,
    required this.lines,
    this.report,
  });

  @override
  State<DynastyBenchDetailPage> createState() => _DynastyBenchDetailPageState();
}

class _DynastyBenchDetailPageState extends State<DynastyBenchDetailPage> {
  // 展示基宽（逻辑像素）：按原图纵横比定高，叠加层与命中换算共用同一
  // 缩放系数 _scale = 基宽 / 原图宽。
  static const _baseWidth = 860.0;

  double? _imgW;
  double? _imgH;
  String? _imgError;
  bool _showChars = true;
  bool _showLines = false;
  bool _showOrder = true;
  int? _selLine;
  int? _selChar;

  @override
  void initState() {
    super.initState();
    _loadImageSize();
  }

  Future<void> _loadImageSize() async {
    // 直接监听原图流拿自然尺寸：展示层本来就要全图解码（可缩放查看），
    // 这里复用同一缓存条目，不产生第二次解码。
    final stream = FileImage(File(widget.imagePath)).resolve(
      const ImageConfiguration(),
    );
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
    final size = await completer.future;
    if (!mounted) return;
    setState(() {
      if (size == null) {
        _imgError = '图片加载失败：${widget.imagePath}';
      } else {
        _imgW = size.$1;
        _imgH = size.$2;
      }
    });
  }

  List<Map<String, dynamic>> get _lines => widget.lines ?? const [];

  @override
  Widget build(BuildContext context) {
    final acc = widget.report?['accuracy'] as num?;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (acc != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(
                child: Text(
                  '准确率 ${(acc * 100).toStringAsFixed(1)}%',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ),
          IconButton(
            tooltip: _showChars ? '隐藏字框' : '显示字框',
            icon: Icon(
              _showChars ? Icons.grid_on : Icons.grid_off,
              size: 20,
            ),
            onPressed: _lines.isEmpty
                ? null
                : () => setState(() => _showChars = !_showChars),
          ),
          IconButton(
            tooltip: _showLines ? '隐藏行框' : '显示行框',
            icon: Icon(
              _showLines ? Icons.crop_din : Icons.crop_free,
              size: 20,
            ),
            onPressed: _lines.isEmpty
                ? null
                : () => setState(() => _showLines = !_showLines),
          ),
          IconButton(
            tooltip: _showOrder ? '隐藏阅读顺序' : '显示阅读顺序（行号=拼文顺序）',
            icon: Icon(
              _showOrder ? Icons.format_list_numbered : Icons.format_list_numbered_rtl,
              size: 20,
            ),
            onPressed: _lines.isEmpty
                ? null
                : () => setState(() => _showOrder = !_showOrder),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 900;
          final viewer = _buildViewer();
          final panel = _buildPanel();
          if (wide) {
            return Row(
              children: [
                Expanded(child: viewer),
                SizedBox(width: 380, child: panel),
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
    );
  }

  Widget _buildViewer() {
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
                    child: Image.file(File(widget.imagePath), fit: BoxFit.fill),
                  ),
                  CustomPaint(
                    size: Size(_baseWidth, viewH),
                    painter: _BoxesPainter(
                      lines: _lines,
                      scale: scale,
                      showChars: _showChars,
                      showLines: _showLines,
                      showOrder: _showOrder,
                      selLine: _selLine,
                      selChar: _selChar,
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
    final scale = _imgW == null || _imgW! <= 0 ? 1.0 : _baseWidth / _imgW!;
    final hit = hitTestChar(dx / scale, dy / scale, _lines);
    setState(() {
      if (hit == null) {
        _selLine = null;
        _selChar = null;
      } else {
        _selLine = hit['lineIndex'];
        _selChar = hit['charIndex'];
      }
    });
  }

  Widget _buildSelBar() {
    if (_selLine == null || _selChar == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        color: Colors.black.withValues(alpha: 0.05),
        child: _lines.isEmpty
            ? const Text(
                '本条运行记录没有字框数据（旧版记录），仅展示图片与基准释文',
                style: TextStyle(color: Colors.grey, fontSize: 11.5),
              )
            : const Text(
                '点击图中的字框查看单字识别详情；滚轮缩放、拖动平移',
                style: TextStyle(color: Colors.grey, fontSize: 11.5),
              ),
      );
    }
    final line = _lines[_selLine!];
    final char = (line['chars'] as List)[_selChar!];
    final conf = char['conf'] as num?;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: Colors.black.withValues(alpha: 0.07),
      child: Wrap(
        spacing: 14,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            (char['text'] as String?)?.isEmpty == true ? '（空）' : '${char['text']}',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          Text(
            '置信度 ${conf == null ? '—' : conf.toStringAsFixed(3)}'
            ' · 类型 ${char['type'] ?? '—'}'
            ' · 第 ${_selLine! + 1} 行第 ${_selChar! + 1} 字'
            ' · 框 (${char['x']},${char['y']},${char['w']}×${char['h']})',
            style: const TextStyle(color: Colors.grey, fontSize: 11.5),
          ),
        ],
      ),
    );
  }

  Widget _buildPanel() {
    return Column(
      children: [
        if (_lines.isNotEmpty) _legend(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
            children: [
              if (_lines.isNotEmpty) ..._recognisedSection(),
              const Divider(height: 24),
              ..._gtSection(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _legend() {
    Widget dot(Color c) => Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            border: Border.all(color: c, width: 2),
            borderRadius: BorderRadius.circular(2),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Wrap(
        spacing: 14,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            dot(Colors.lightBlueAccent),
            const SizedBox(width: 4),
            const Text('正文', style: TextStyle(fontSize: 11, color: Colors.grey)),
          ]),
          Row(mainAxisSize: MainAxisSize.min, children: [
            dot(Colors.orangeAccent),
            const SizedBox(width: 4),
            const Text('批注', style: TextStyle(fontSize: 11, color: Colors.grey)),
          ]),
          Row(mainAxisSize: MainAxisSize.min, children: [
            dot(Colors.grey),
            const SizedBox(width: 4),
            const Text('忽略', style: TextStyle(fontSize: 11, color: Colors.grey)),
          ]),
          Row(mainAxisSize: MainAxisSize.min, children: [
            dot(Colors.red),
            const SizedBox(width: 4),
            const Text('选中', style: TextStyle(fontSize: 11, color: Colors.grey)),
          ]),
        ],
      ),
    );
  }

  List<Widget> _recognisedSection() {
    return [
      Text(
        '识别文字（${_lines.length} 行，编号即阅读顺序，点行可高亮图中字框）',
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5),
      ),
      const SizedBox(height: 4),
      for (var i = 0; i < _lines.length; i++)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          selected: _selLine == i,
          selectedTileColor: Colors.red.withValues(alpha: 0.08),
          leading: SizedBox(
            width: 30,
            child: Text(
              '${i + 1}',
              textAlign: TextAlign.end,
              style: const TextStyle(color: Colors.grey, fontSize: 11),
            ),
          ),
          title: Text(
            (_lines[i]['text'] as String?) ?? '',
            style: const TextStyle(fontSize: 13, height: 1.4),
          ),
          subtitle: Text(
            '${((_lines[i]['chars'] as List).length)} 字',
            style: const TextStyle(fontSize: 10.5, color: Colors.grey),
          ),
          onTap: () => setState(() {
            _selLine = i;
            _selChar = null;
          }),
        ),
    ];
  }

  List<Widget> _gtSection() {
    return [
      const Text(
        '基准释文（应识别内容，按列/简）',
        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5),
      ),
      const SizedBox(height: 4),
      for (final u in widget.gtUnits)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 38,
                child: Text(
                  (u['label'] as String?) ?? '',
                  style: const TextStyle(color: Colors.grey, fontSize: 11),
                ),
              ),
              Expanded(
                child: SelectableText(
                  (u['text'] as String?) ?? '',
                  style: const TextStyle(fontSize: 13, height: 1.5),
                ),
              ),
            ],
          ),
        ),
    ];
  }
}

/// 字框/行框叠加层：字框按类型着色，选中项红框高亮；放大到字框显示
/// 宽 ≥15px 时在框顶绘制识别文字，便于人工核对。
class _BoxesPainter extends CustomPainter {
  final List<Map<String, dynamic>> lines;
  final double scale;
  final bool showChars;
  final bool showLines;
  final bool showOrder;
  final int? selLine;
  final int? selChar;

  _BoxesPainter({
    required this.lines,
    required this.scale,
    required this.showChars,
    required this.showLines,
    required this.showOrder,
    required this.selLine,
    required this.selChar,
  });

  Paint _stroke(Color color, double width) => Paint()
    ..style = PaintingStyle.stroke
    ..color = color
    ..strokeWidth = width;

  @override
  void paint(Canvas canvas, Size size) {
    if (showLines) {
      final p = _stroke(Colors.deepPurple, 1.5);
      for (var li = 0; li < lines.length; li++) {
        _drawRect(canvas, lines[li], p, selLine == li ? Colors.red : null);
      }
    }
    if (showOrder) {
      // 行号徽标 = 拼文阅读顺序（与右侧「识别文字」列表编号一致）：
      // 行框左上角深底白字圆角标，选中行红色。
      for (var li = 0; li < lines.length; li++) {
        _drawOrderBadge(canvas, lines[li], li);
      }
    }
    if (showChars) {
      for (var li = 0; li < lines.length; li++) {
        final chars = lines[li]['chars'];
        if (chars is! List) continue;
        for (var ci = 0; ci < chars.length; ci++) {
          final c = chars[ci];
          if (c is! Map) continue;
          final selected = selLine == li && selChar == ci;
          final color = switch (c['type'] as String?) {
            'annotation' => Colors.orangeAccent,
            'ignore' => Colors.grey,
            _ => Colors.lightBlueAccent,
          };
          final rect = _rectOf(c);
          if (selected) {
            canvas.drawRect(rect, Paint()..color = Colors.red.withValues(alpha: 0.15));
            canvas.drawRect(rect, _stroke(Colors.red, 2.5));
          } else {
            canvas.drawRect(rect, _stroke(color, 1.2));
          }
          final boxW = c['w'] as num?;
          if (boxW != null && boxW * scale >= 15) {
            final tp = TextPainter(
              text: TextSpan(
                text: (c['text'] as String?) ?? '',
                style: TextStyle(
                  fontSize: (boxW * scale * 0.6).clamp(9.0, 26.0),
                  color: Colors.red,
                  fontWeight: FontWeight.w600,
                ),
              ),
              textDirection: TextDirection.ltr,
            )..layout();
            // 字框顶端左侧标注识别字；向上越出画布时移到框内顶部。
            final anchor = rect.topLeft.translate(0, -tp.height - 2);
            tp.paint(canvas, anchor.dy < 0 ? rect.topLeft : anchor);
          }
        }
      }
    }
  }

  Rect _rectOf(Map c) => Rect.fromLTWH(
        ((c['x'] as num?) ?? 0) * scale,
        ((c['y'] as num?) ?? 0) * scale,
        ((c['w'] as num?) ?? 0) * scale,
        ((c['h'] as num?) ?? 0) * scale,
      );

  void _drawRect(Canvas canvas, Map line, Paint p, Color? selected) {
    final rect = _rectOf(line);
    canvas.drawRect(rect, selected != null ? _stroke(selected, 2.5) : p);
  }

  void _drawOrderBadge(Canvas canvas, Map line, int index) {
    final rect = _rectOf(line);
    final fontSize = (rect.height * 0.045).clamp(11.0, 22.0);
    final tp = TextPainter(
      text: TextSpan(
        text: '${index + 1}',
        style: TextStyle(
          fontSize: fontSize,
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final pad = fontSize * 0.3;
    final badgeSize = Size(tp.width + pad * 2, tp.height + pad * 1.2);
    // 行框左上角，越出图像顶部时移到框内。
    var origin = rect.topLeft.translate(-2, -badgeSize.height - 2);
    if (origin.dy < 0) origin = rect.topLeft.translate(2, 2);
    final rrect = RRect.fromRectAndRadius(
      origin & badgeSize,
      Radius.circular(badgeSize.height * 0.35),
    );
    canvas.drawRRect(
      rrect,
      Paint()..color = selLine == index ? Colors.red.shade700 : Colors.black87,
    );
    tp.paint(canvas, origin.translate(pad, pad * 0.6));
  }

  @override
  bool shouldRepaint(_BoxesPainter old) =>
      old.scale != scale ||
      old.showChars != showChars ||
      old.showLines != showLines ||
      old.showOrder != showOrder ||
      old.selLine != selLine ||
      old.selChar != selChar ||
      old.lines != lines;
}
