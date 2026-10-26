import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/models.dart';

/// 训练页「存档轮测试页识别」的结果弹窗：用第 N 轮检查点识别测试页后，
/// 左侧画该层检测框、右侧列识别文字，直观对比不同轮数的模型长进。
///
/// 框只画被测层（与模型对比页同口径：五个层级的框全叠会淹没该层差异）。
class TrainingProbeDialog extends StatefulWidget {
  final String layer;
  final String layerTitle;
  final int epoch;
  final String imagePath;
  final PageAnnotation annotation;
  final int elapsedMs;
  final String modelPath;

  const TrainingProbeDialog({
    super.key,
    required this.layer,
    required this.layerTitle,
    required this.epoch,
    required this.imagePath,
    required this.annotation,
    required this.elapsedMs,
    required this.modelPath,
  });

  @override
  State<TrainingProbeDialog> createState() => _TrainingProbeDialogState();
}

class _TrainingProbeDialogState extends State<TrainingProbeDialog> {
  ui.Image? _image;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    try {
      final bytes = await File(widget.imagePath).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (mounted) setState(() => _image = frame.image);
    } catch (e) {
      if (mounted) setState(() => _error = '读取测试页图片失败：$e');
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ann = widget.annotation;
    final text = ann.lines.map((l) => l.text).join('\n');
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1080, maxHeight: 760),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${widget.layerTitle} · 第 ${widget.epoch} 轮检查点识别结果',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              Text(
                '测试页：${p.basename(widget.imagePath)} · '
                '字框 ${ann.blocks.length} · 行 ${ann.lines.length} · '
                '段 ${ann.paragraphs.length} · 正文区 ${ann.mainRegions.length} · '
                '耗时 ${(widget.elapsedMs / 1000).toStringAsFixed(1)}s\n'
                '检查点：${widget.modelPath}',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: _error != null
                    ? Center(
                        child: Text(
                          _error!,
                          style: TextStyle(color: Theme.of(context).colorScheme.error),
                        ),
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: Container(
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey.shade300),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: _image == null
                                  ? const Center(
                                      child: SizedBox(
                                        width: 22,
                                        height: 22,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      ),
                                    )
                                  : InteractiveViewer(
                                      maxScale: 8,
                                      child: AspectRatio(
                                        aspectRatio:
                                            _image!.width / _image!.height,
                                        child: CustomPaint(
                                          painter: _ProbeBoxesPainter(
                                            image: _image!,
                                            annotation: ann,
                                            levels: _probeBoxLevels(widget.layer),
                                          ),
                                        ),
                                      ),
                                    ),
                            ),
                          ),
                          const VerticalDivider(width: 12),
                          SizedBox(
                            width: 300,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '识别文字（按行）',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.grey.shade800,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Expanded(
                                  child: Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: Colors.black87,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: SingleChildScrollView(
                                      child: SelectableText(
                                        text.isEmpty ? '（无识别文字）' : text,
                                        style: const TextStyle(
                                          color: Color(0xFF4DD080),
                                          fontSize: 12,
                                          height: 1.6,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 与模型对比页同口径：只画被测层级的框。
Set<String> _probeBoxLevels(String layer) {
  switch (layer) {
    case 'region_det':
      return const {'region'};
    case 'paragraph_det':
      return const {'paragraph'};
    case 'line_det':
      return const {'line'};
    case 'char_det':
    case 'char_cls':
      return const {'char'};
    default:
      return const {'region', 'paragraph', 'line', 'char'};
  }
}

class _ProbeBoxesPainter extends CustomPainter {
  final ui.Image image;
  final PageAnnotation annotation;
  final Set<String> levels;

  _ProbeBoxesPainter({
    required this.image,
    required this.annotation,
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

    void drawRects(Iterable<Rect> rects, Color color, double width) {
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

    Rect boxOf(num x, num y, num w, num h) => Rect.fromLTWH(
          x.toDouble(),
          y.toDouble(),
          w.toDouble(),
          h.toDouble(),
        );

    if (levels.contains('region')) {
      drawRects(
        annotation.mainRegions.map((r) => boxOf(r.x, r.y, r.w, r.h)),
        Colors.deepPurple,
        2,
      );
    }
    if (levels.contains('paragraph')) {
      drawRects(
        annotation.paragraphs.map((pp) => boxOf(pp.x, pp.y, pp.w, pp.h)),
        Colors.purple,
        1.5,
      );
    }
    if (levels.contains('line')) {
      drawRects(
        annotation.lines.map((l) => boxOf(l.x, l.y, l.w, l.h)),
        Colors.orange,
        1.5,
      );
    }
    if (levels.contains('char')) {
      drawRects(
        annotation.blocks.map((b) => boxOf(b.x, b.y, b.w, b.h)),
        Colors.green,
        1,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ProbeBoxesPainter old) =>
      old.image != image ||
      old.annotation != annotation ||
      old.levels.length != levels.length ||
      !old.levels.containsAll(levels);
}
