/// 表格校对页（+83 表格识别）。
///
/// 网格视图逐格校对：每格 = 原图缩略（含格线示意）+ 识别文字，点击
/// 选中后底部详情栏放大校对、确认本格。布局按 rows×cols 真实表格摆
/// （合并格 span 展开）；竖排版面默认「按阅读序排列」——列从右往左
/// （古籍表头在右），可开关切回几何序（从左往右）。修改直接落在传入
/// 的 TableAnnotation 实例上，返回后由编辑器临时保存。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../models/models.dart';
import '../models/table_block.dart';
import '../services/python_service.dart';

class TableReviewPage extends StatefulWidget {
  final String imagePath;
  final TableAnnotation table;

  /// 阅读方向（决定默认列序与重新识别的参数）。
  final String orientation;
  final String horizontalDir;
  final String verticalDir;

  const TableReviewPage({
    super.key,
    required this.imagePath,
    required this.table,
    this.orientation = 'vertical',
    this.horizontalDir = 'ltr',
    this.verticalDir = 'ttb',
  });

  @override
  State<TableReviewPage> createState() => _TableReviewPageState();
}

class _TableReviewPageState extends State<TableReviewPage> {
  ui.Image? _image;
  TableCellBlock? _selected;

  /// 竖排 rtl 页面默认按阅读序（列从右到左）。
  late bool _readingOrder;
  bool _showThumb = true;
  bool _busy = false;
  final _textController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _readingOrder =
        widget.orientation == 'vertical' && widget.horizontalDir == 'rtl';
    _decodeImage();
  }

  @override
  void dispose() {
    _textController.dispose();
    _image?.dispose();
    super.dispose();
  }

  Future<void> _decodeImage() async {
    try {
      final data = await File(widget.imagePath).readAsBytes();
      final codec = await ui.instantiateImageCodec(data);
      final frame = await codec.getNextFrame();
      if (mounted) setState(() => _image = frame.image);
    } catch (_) {
      // 缩略图解码失败不阻塞文字校对（详情栏显示占位提示）
    }
  }

  void _selectCell(TableCellBlock? cell) {
    setState(() {
      _selected = cell;
      _textController.text = cell?.text ?? '';
    });
  }

  Future<void> _rerecognize() async {
    if (_busy) return;
    final t = widget.table;
    setState(() => _busy = true);
    try {
      final fresh = await PythonService.recognizeTable(
        imagePath: widget.imagePath,
        x: t.x,
        y: t.y,
        w: t.w,
        h: t.h,
        settings: ProjectSettings(
          orientation: widget.orientation,
          horizontalDir: widget.horizontalDir,
          verticalDir: widget.verticalDir,
        ),
        id: t.id,
        regionUid: t.regionUid,
      );
      if (!mounted) return;
      setState(() {
        t
          ..x = fresh.x
          ..y = fresh.y
          ..w = fresh.w
          ..h = fresh.h
          ..rows = fresh.rows
          ..cols = fresh.cols
          ..hLines = fresh.hLines
          ..vLines = fresh.vLines
          ..lineWidth = fresh.lineWidth;
        t.cells
          ..clear()
          ..addAll(fresh.cells);
        _selected = null;
      });
    } on TableGridNotFoundException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('重新识别失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _confirmAll() {
    setState(() {
      for (final c in widget.table.cells) {
        c.status = AnnotationStatus.confirmed;
      }
      widget.table.status = AnnotationStatus.confirmed;
    });
  }

  Future<void> _export(String format) async {
    final t = widget.table;
    final rtlCols = widget.orientation == 'vertical' &&
        widget.horizontalDir == 'rtl' &&
        _readingOrder;
    final content = format == 'md'
        ? TableExport.toMarkdown(t, rtlCols: rtlCols)
        : TableExport.toTSV(t, rtlCols: rtlCols);
    await Clipboard.setData(ClipboardData(text: content));
    final path = await FilePicker.platform.saveFile(
      dialogTitle: '导出表格（已复制到剪贴板）',
      fileName:
          '${p.basenameWithoutExtension(widget.imagePath)}_${t.id}.${format == 'md' ? 'md' : 'txt'}',
      type: FileType.custom,
      allowedExtensions: [format == 'md' ? 'md' : 'txt'],
    );
    if (path == null) return;
    File(path).writeAsStringSync(content, flush: true);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导出 → ${p.basename(path)}（剪贴板同步）')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.table;
    final confirmedCount =
        t.cells.where((c) => c.status == AnnotationStatus.confirmed).length;
    return Scaffold(
      appBar: AppBar(
        title: Text(
            '表格校对 ${t.rows}×${t.cols} · $confirmedCount/${t.cells.length} 已确认'),
        actions: [
          IconButton(
            tooltip: _showThumb ? '隐藏格缩略图' : '显示格缩略图',
            icon: Icon(_showThumb ? Icons.image : Icons.image_not_supported),
            onPressed: () => setState(() => _showThumb = !_showThumb),
          ),
          IconButton(
            tooltip: _readingOrder ? '切换为几何序（列从左到右）' : '切换为阅读序（列从右到左）',
            icon: Icon(_readingOrder
                ? Icons.format_align_right
                : Icons.format_align_left),
            onPressed: () => setState(() => _readingOrder = !_readingOrder),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'rerecognize':
                  unawaited(_rerecognize());
                case 'confirm_all':
                  _confirmAll();
                case 'export_md':
                  unawaited(_export('md'));
                case 'export_tsv':
                  unawaited(_export('tsv'));
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'rerecognize',
                child: Text('重新识别（覆盖当前文字）'),
              ),
              PopupMenuItem(value: 'confirm_all', child: Text('全部确认')),
              PopupMenuItem(value: 'export_md', child: Text('导出 Markdown（复制+存文件）')),
              PopupMenuItem(value: 'export_tsv', child: Text('导出 TSV（复制+存文件）')),
            ],
          ),
        ],
      ),
      body: _busy
          ? const Center(child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text('表格识别中…'),
              ],
            ))
          : Column(
              children: [
                Expanded(child: _buildGrid()),
                if (_selected != null) _buildDetailBar(),
              ],
            ),
    );
  }

  Widget _buildGrid() {
    final t = widget.table;
    // 列宽 flex = 几何列宽（vLines 距离）；显示序与几何序经
    // displayIndexOf 映射，rtl 时列从右往左摆。
    final totalW = t.vLines.length >= 2
        ? (t.vLines.last - t.vLines.first).toDouble()
        : t.w.toDouble();
    double colFlex(int c) {
      if (t.vLines.length == t.cols + 1 && totalW > 0 && c < t.cols) {
        return (t.vLines[c + 1] - t.vLines[c]) / totalW;
      }
      return 1.0;
    }

    const rowH = 108.0;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: LayoutBuilder(
        builder: (context, cons) {
          final width = cons.maxWidth;
          // 每列显示区 [left, right]
          final colBounds = <int, (double, double)>{};
          var acc = 0.0;
          final flexSum = List<double>.generate(t.cols, (i) => colFlex(i))
                  .fold<double>(0, (a, b) => a + b) *
              1.0;
          for (var dc = 0; dc < t.cols; dc++) {
            final geoCol = _readingOrder &&
                    widget.orientation == 'vertical' &&
                    widget.horizontalDir == 'rtl'
                ? t.cols - 1 - dc
                : dc;
            final f = colFlex(geoCol);
            final left = (acc / (flexSum > 0 ? flexSum : 1)) * width;
            acc += f;
            final right = (acc / (flexSum > 0 ? flexSum : 1)) * width;
            colBounds[geoCol] = (left, right);
          }
          final blocks = <Widget>[];
          for (final block in t.cells) {
            final (l0, _) = colBounds[block.col] ?? (0.0, 0.0);
            final (_, r1) =
                colBounds[block.col + block.colSpan - 1] ?? (0.0, 0.0);
            blocks.add(Positioned(
              left: l0,
              top: block.row * rowH,
              width: (r1 - l0).clamp(20.0, width),
              height: block.rowSpan * rowH,
              child: _CellTile(
                cell: block,
                image: _image,
                showThumb: _showThumb,
                table: t,
                selected: identical(_selected, block),
                onTap: () => _selectCell(block),
              ),
            ));
          }
          return SizedBox(
            width: width,
            height: t.rows * rowH,
            child: Stack(children: blocks),
          );
        },
      ),
    );
  }

  Widget _buildDetailBar() {
    final cell = _selected!;
    final confirmed = cell.status == AnnotationStatus.confirmed;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Colors.pink.shade100, width: 2)),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_showThumb)
            Container(
              width: 160,
              height: 120,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.pink.shade200),
              ),
              child: _CellThumb(
                image: _image,
                cell: cell,
                table: widget.table,
              ),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '第 ${cell.row + 1} 行 · 第 ${cell.col + 1} 列'
                  '${cell.rowSpan > 1 || cell.colSpan > 1 ? '（合并 ${cell.rowSpan}×${cell.colSpan}）' : ''}'
                  ' · ${cell.orientation == 'vertical' ? '竖排' : '横排'}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _textController,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: '格内文字',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() {
                    cell.text = v;
                    if (cell.status == AnnotationStatus.confirmed) {
                      cell.status = AnnotationStatus.proposed;
                    }
                  }),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              FilledButton.icon(
                onPressed: confirmed
                    ? null
                    : () => setState(() {
                          cell.status = AnnotationStatus.confirmed;
                        }),
                icon: const Icon(Icons.check, size: 18),
                label: Text(confirmed ? '已确认' : '确认本格'),
              ),
              TextButton(
                onPressed: () => _selectCell(null),
                child: const Text('关闭'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 单元格瓦片：缩略图 + 文字 + 确认角标。
class _CellTile extends StatelessWidget {
  final TableCellBlock cell;
  final ui.Image? image;
  final bool showThumb;
  final TableAnnotation table;
  final bool selected;
  final VoidCallback onTap;

  const _CellTile({
    required this.cell,
    required this.image,
    required this.showThumb,
    required this.table,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final confirmed = cell.status == AnnotationStatus.confirmed;
    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: selected
              ? Colors.orange.shade50
              : confirmed
                  ? Colors.green.shade50
                  : null,
          border: selected ? Border.all(color: Colors.orange, width: 2) : null,
        ),
        padding: const EdgeInsets.all(4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showThumb)
              SizedBox(
                height: 72,
                child: _CellThumb(image: image, cell: cell, table: table),
              ),
            const SizedBox(height: 4),
            Text(
              cell.text.isEmpty ? '（空）' : cell.text,
              style: TextStyle(
                fontSize: 13,
                color: cell.text.isEmpty ? Colors.grey : null,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// 单元格原图缩略（含格线示意线，帮助对齐判断）。
class _CellThumb extends StatelessWidget {
  final ui.Image? image;
  final TableCellBlock cell;
  final TableAnnotation table;

  const _CellThumb({
    required this.image,
    required this.cell,
    required this.table,
  });

  @override
  Widget build(BuildContext context) {
    final img = image;
    if (img == null) {
      return const Center(
        child: Text('…', style: TextStyle(color: Colors.grey)),
      );
    }
    return CustomPaint(
      size: Size.infinite,
      painter: _CellThumbPainter(img, cell, table),
    );
  }
}

class _CellThumbPainter extends CustomPainter {
  final ui.Image image;
  final TableCellBlock cell;
  final TableAnnotation table;

  _CellThumbPainter(this.image, this.cell, this.table);

  @override
  void paint(Canvas canvas, Size size) {
    final src = Rect.fromLTWH(
      cell.x.toDouble(),
      cell.y.toDouble(),
      cell.w.toDouble(),
      cell.h.toDouble(),
    );
    // 等比放入（letterbox 居中）
    final scale = math.min(
      size.width / src.width,
      size.height / src.height,
    );
    final dstW = src.width * scale;
    final dstH = src.height * scale;
    final offX = (size.width - dstW) / 2;
    final offY = (size.height - dstH) / 2;
    final dst = Rect.fromLTWH(offX, offY, dstW, dstH);
    final paint = Paint()..filterQuality = FilterQuality.medium;
    canvas.drawImageRect(image, src, dst, paint);
    // 格线示意（合并格内部无格线，边界线示意帮助判断 span 正确性）
    final linePaint = Paint()
      ..color = Colors.pink.withValues(alpha: 0.45)
      ..strokeWidth = 1;
    for (final y in table.hLines) {
      if (y > src.top && y < src.bottom) {
        final dy = offY + (y - src.top) * scale;
        canvas.drawLine(Offset(offX, dy), Offset(offX + dstW, dy), linePaint);
      }
    }
    for (final x in table.vLines) {
      if (x > src.left && x < src.right) {
        final dx = offX + (x - src.left) * scale;
        canvas.drawLine(Offset(dx, offY), Offset(dx, offY + dstH), linePaint);
      }
    }
  }

  @override
  bool shouldRepaint(_CellThumbPainter old) =>
      !identical(old.cell, cell) || !identical(old.table, table);
}

/// 表格文本导出（Markdown / TSV）。合并格：内容只写起点格，被覆盖格
/// 留空（Markdown/TSV 均不支持 colspan）。
class TableExport {
  /// 返回 rows×(cols+1) 的单元矩阵（首列行号），按列显示序重排。
  static List<List<String>> _matrix(
    TableAnnotation t, {
    required bool rtlCols,
  }) {
    final blocks = <(int, int), TableCellBlock>{
      for (final c in t.cells) (c.row, c.col): c,
    };
    var colOrder = List<int>.generate(t.cols, (i) => i);
    if (rtlCols) {
      colOrder = colOrder.reversed.toList();
    }
    final rows = <List<String>>[];
    for (var r = 0; r < t.rows; r++) {
      final row = <String>['${r + 1}'];
      for (final c in colOrder) {
        row.add(blocks[(r, c)]?.text ?? '');
      }
      rows.add(row);
    }
    return rows;
  }

  static String toMarkdown(TableAnnotation t, {required bool rtlCols}) {
    final m = _matrix(t, rtlCols: rtlCols);
    if (m.isEmpty) return '';
    final buf = StringBuffer();
    final head = m.first;
    buf.writeln('| 行 | ${head.skip(1).map((c) => c.isEmpty ? ' ' : c).join(' | ')} |');
    buf.writeln(
        '| --- | ${head.skip(1).map((_) => '---').join(' | ')} |');
    for (final row in m.skip(1)) {
      buf.writeln(
          '| ${row.first} | ${row.skip(1).map((c) => c.isEmpty ? ' ' : c).join(' | ')} |');
    }
    return buf.toString();
  }

  static String toTSV(TableAnnotation t, {required bool rtlCols}) {
    final m = _matrix(t, rtlCols: rtlCols);
    return m.map((r) => r.join('\t')).join('\n');
  }
}
