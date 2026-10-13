import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/image_probe.dart';
import '../services/page_state_markers.dart';
import '../services/storage.dart';
import '../widgets/page_thumb_cache.dart';

/// 叠加层选择：原图 = 只显示页面缩略图，其余四档在缩略图上勾出
/// 对应识别层（单选切换，便于快速扫全书找某层的问题页）。
enum _GridLayer { image, region, paragraph, line, char }

/// 全书网格总览（编辑器工具栏入口）：所有页按网格排列，缩略图上
/// 叠加所选识别层（正文区/自然段/行/字），边框色沿用编辑器五态
/// （蓝=当前页、绿=已确认、玫红=确认识别框、橘黄=临时保存、紫=识别
/// 未确认、灰=无标注）。点击任意页返回其索引，由编辑器
/// `_switchPage` 跳转。
///
/// 页面图是 200DPI PNG（一本可达数百页、上 GB），这里只做降采样
/// 解码 + 小容量 LRU，绝不整图进内存。
class BookGridPage extends StatefulWidget {
  const BookGridPage({super.key, required this.project, this.currentPageIndex});

  final Project project;
  final int? currentPageIndex;

  @override
  State<BookGridPage> createState() => _BookGridPageState();
}

class _BookGridPageState extends State<BookGridPage> {
  /// 格大小档位对应的目标格宽（逻辑像素）。
  static const List<double> _tierWidths = [160, 240, 360, 520];
  static const List<String> _tierLabels = ['小', '中', '大', '特大'];

  final Map<int, PageAnnotation> _annotations = {};

  /// 各页原始像素尺寸（框线从页面像素映射到格子用），探测失败缺项。
  final Map<int, Size> _pageSizes = {};
  final PageThumbCache _thumbCache = PageThumbCache();
  PageStateMarkers _markers = PageStateMarkers();
  _GridLayer _layer = _GridLayer.region;
  int _sizeTier = 1;
  int _loadedCount = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  @override
  void dispose() {
    _thumbCache.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    final project = widget.project;
    for (var i = 0; i < project.imageFiles.length; i++) {
      final ann = await ProjectStorage.loadAnnotation(
        project.projectDir,
        project.pageIdAt(i),
      );
      if (ann != null) _annotations[i] = ann;
      // 框线映射需要原始页面尺寸（PNG 读头，很快）。
      final pageSize = await probeImageSize(project.imageFiles[i]);
      if (pageSize != null) _pageSizes[i] = pageSize;
      // 大书（数百页）逐文件解析需要几秒，节流刷新进度。
      if (!mounted) return;
      if (i % 16 == 0 || i == project.imageFiles.length - 1) {
        setState(() => _loadedCount = i + 1);
      }
    }
    if (!mounted) return;
    setState(() {
      _markers = PageStateMarkers.fromAnnotations(_annotations);
      _loading = false;
    });
  }

  /// 解码宽度跟格宽联动（2 倍格宽兼顾清晰度与内存），封顶 720。
  int get _decodeWidth =>
      (_tierWidths[_sizeTier] * 2).clamp(320.0, 720.0).round();

  @override
  Widget build(BuildContext context) {
    final pageCount = widget.project.imageFiles.length;
    return Scaffold(
      appBar: AppBar(
        title: Text('全书总览 · ${widget.project.name}'),
        actions: [
          SegmentedButton<_GridLayer>(
            segments: const [
              ButtonSegment(
                value: _GridLayer.image,
                icon: Icon(Icons.image_outlined),
                label: Text('原图'),
              ),
              ButtonSegment(
                value: _GridLayer.region,
                icon: Icon(Icons.crop_free),
                label: Text('主区'),
              ),
              ButtonSegment(
                value: _GridLayer.paragraph,
                icon: Icon(Icons.format_align_right),
                label: Text('段'),
              ),
              ButtonSegment(
                value: _GridLayer.line,
                icon: Icon(Icons.subject),
                label: Text('行'),
              ),
              ButtonSegment(
                value: _GridLayer.char,
                icon: Icon(Icons.grid_on),
                label: Text('字'),
              ),
            ],
            selected: {_layer},
            onSelectionChanged: (value) =>
                setState(() => _layer = value.first),
          ),
          const SizedBox(width: 8),
          PopupMenuButton<int>(
            tooltip: '书页大小',
            icon: const Icon(Icons.photo_size_select_large),
            initialValue: _sizeTier,
            onSelected: (value) => setState(() => _sizeTier = value),
            itemBuilder: (_) => [
              for (var i = 0; i < _tierLabels.length; i++)
                PopupMenuItem(
                  value: i,
                  child: Row(
                    children: [
                      if (_sizeTier == i)
                        const Icon(Icons.check, size: 18)
                      else
                        const SizedBox(width: 18),
                      const SizedBox(width: 8),
                      Text('书页大小：${_tierLabels[i]}'),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: _loading ? _buildLoading(pageCount) : _buildGrid(pageCount),
    );
  }

  Widget _buildLoading(int pageCount) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('正在扫描全书标注 $_loadedCount / $pageCount …'),
          const SizedBox(height: 12),
          SizedBox(
            width: 320,
            child: LinearProgressIndicator(
              value: pageCount == 0 ? 1 : _loadedCount / pageCount,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGrid(int pageCount) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Wrap(
            spacing: 12,
            children: [
              _legend(Colors.blue, '当前页'),
              _legend(Colors.green.shade600, '已确认'),
              _legend(PageStateMarkers.boxesReviewedColor, '框已确认'),
              _legend(Colors.orange.shade700, '临时保存'),
              _legend(Colors.purple, '识别未确认'),
              _legend(Colors.grey.shade500, '无标注'),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(8),
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: _tierWidths[_sizeTier],
              // 古籍页以竖版为主；横竖不一的页按 contain 居中画。
              childAspectRatio: 0.72,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: pageCount,
            itemBuilder: (_, index) => _GridCell(
              index: index,
              imagePath: widget.project.imageFiles[index],
              annotation: _annotations[index],
              pageSize: _pageSizes[index],
              layer: _layer,
              borderColor: _markers.borderColor(
                index,
                currentIndex: widget.currentPageIndex,
              ),
              emphasized:
                  index == widget.currentPageIndex || _markers.isMarked(index),
              decodeWidth: _decodeWidth,
              cache: _thumbCache,
              onTap: () => Navigator.of(context).pop(index),
            ),
          ),
        ),
      ],
    );
  }

  Widget _legend(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            border: Border.all(color: color, width: 2),
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}

/// 单个书页格子：降采样缩略图 + 所选层框线 + 状态边框 + 页号角标。
class _GridCell extends StatefulWidget {
  const _GridCell({
    required this.index,
    required this.imagePath,
    required this.annotation,
    required this.pageSize,
    required this.layer,
    required this.borderColor,
    required this.emphasized,
    required this.decodeWidth,
    required this.cache,
    required this.onTap,
  });

  final int index;
  final String imagePath;
  final PageAnnotation? annotation;

  /// 页面原始像素尺寸（框线映射基准），null = 探测失败只画图不画框。
  final Size? pageSize;
  final _GridLayer layer;
  final Color borderColor;
  final bool emphasized;
  final int decodeWidth;
  final PageThumbCache cache;
  final VoidCallback onTap;

  @override
  State<_GridCell> createState() => _GridCellState();
}

class _GridCellState extends State<_GridCell> {
  ui.Image? _thumb;
  int _requestedIndex = -1;
  int _requestedWidth = 0;

  void _ensureThumb() {
    // GridView 会把 State 复用给不同页号的格子，index 与解码宽度都要
    // 纳入"已请求"判断，否则滚动时显示成上一页的缩略图。
    if (_requestedIndex == widget.index &&
        _requestedWidth == widget.decodeWidth) {
      return;
    }
    _requestedIndex = widget.index;
    _requestedWidth = widget.decodeWidth;
    widget.cache
        .get(widget.index, widget.imagePath, widget.decodeWidth)
        .then((image) {
          // 返回时格宽/页号可能已变化，只接受仍匹配的解码结果。
          if (!mounted ||
              _requestedIndex != widget.index ||
              _requestedWidth != widget.decodeWidth) {
            return;
          }
          setState(() => _thumb = image);
        });
  }

  @override
  Widget build(BuildContext context) {
    _ensureThumb();
    final ann = widget.annotation;
    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        clipBehavior: Clip.hardEdge,
        decoration: BoxDecoration(
          border: Border.all(
            color: widget.borderColor,
            width: widget.emphasized ? 2.5 : 1,
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              child: CustomPaint(
                painter: _GridCellPainter(
                  image: _thumb,
                  annotation: ann,
                  pageSize: widget.pageSize,
                  layer: widget.layer,
                ),
              ),
            ),
            Positioned(
              left: 4,
              top: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                color: Colors.black.withValues(alpha: 0.55),
                child: Text(
                  '${widget.index + 1}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    height: 1.1,
                  ),
                ),
              ),
            ),
            if (ann == null)
              const Center(
                child: Text(
                  '未识别',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 格子画笔：深色底 + contain 居中的缩略图 + 所选层框线。
/// 框线颜色沿用编辑器画布约定：主区 deepPurple、段 teal、行 indigo、
/// 字绿（缩略图尺度下不按字序彩虹着色，保持可读）。
class _GridCellPainter extends CustomPainter {
  _GridCellPainter({
    required this.image,
    required this.annotation,
    required this.pageSize,
    required this.layer,
  });

  final ui.Image? image;
  final PageAnnotation? annotation;

  /// 页面原始像素尺寸：框线坐标的基准。
  final Size? pageSize;
  final _GridLayer layer;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF1E1E1E),
    );
    final img = image;
    if (img == null) return;
    // contain 布局：有页面原始尺寸时以它为基准（框线映射与之一致），
    // 否则退回缩略图自身尺寸（只画图不画框）。
    final page = pageSize;
    final layoutW = page != null && !page.isEmpty
        ? page.width
        : img.width.toDouble();
    final layoutH = page != null && !page.isEmpty
        ? page.height
        : img.height.toDouble();
    final scale = size.width / layoutW < size.height / layoutH
        ? size.width / layoutW
        : size.height / layoutH;
    final dst = Rect.fromLTWH(
      (size.width - layoutW * scale) / 2,
      (size.height - layoutH * scale) / 2,
      layoutW * scale,
      layoutH * scale,
    );
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      dst,
      Paint()..filterQuality = FilterQuality.low,
    );
    final ann = annotation;
    if (ann == null || layer == _GridLayer.image || page == null || page.isEmpty) {
      return;
    }

    // 框线坐标是页面原始像素，必须按 dst 实际占比归一：缩略图是降采样
    // 解码，直接乘"缩略图像素→格子"的缩放会把框放大数倍并偏移。
    final sx = dst.width / page.width;
    final sy = dst.height / page.height;
    final paint = Paint()..style = PaintingStyle.stroke;
    void drawBox(int x, int y, int w, int h, Color color, double strokeWidth) {
      paint
        ..color = color
        ..strokeWidth = strokeWidth;
      canvas.drawRect(
        Rect.fromLTWH(
          dst.left + x * sx,
          dst.top + y * sy,
          w * sx,
          h * sy,
        ),
        paint,
      );
    }

    switch (layer) {
      case _GridLayer.image:
        break;
      case _GridLayer.region:
        for (final r in ann.mainRegions) {
          drawBox(r.x, r.y, r.w, r.h, Colors.deepPurple, 2.0);
        }
      case _GridLayer.paragraph:
        for (final p in ann.paragraphs) {
          drawBox(p.x, p.y, p.w, p.h, Colors.teal, 1.6);
        }
      case _GridLayer.line:
        for (final l in ann.lines) {
          drawBox(l.x, l.y, l.w, l.h, Colors.indigo, 1.2);
        }
      case _GridLayer.char:
        for (final c in ann.blocks) {
          drawBox(c.x, c.y, c.w, c.h, const Color(0xFF66BB6A), 0.8);
        }
    }
  }

  @override
  bool shouldRepaint(_GridCellPainter old) =>
      old.image != image ||
      old.annotation != annotation ||
      old.pageSize != pageSize ||
      old.layer != layer;
}
