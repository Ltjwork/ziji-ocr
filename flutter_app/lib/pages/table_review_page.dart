/// 表格校对页（+83 表格识别；左图右表对照校对）。
///
/// 左右对照：左侧是表格**原图裁剪**（含真实格线外观，Ctrl+滚轮缩放、
/// 拖拽平移，叠加淡粉格线示意可核对切分）；右侧是**电子化后的表格**——
/// 整表按原表几何比例适配面板（行高/列宽取真实格线距离，与原图同纵横
/// 比同相对行高，细长表在右侧也是细长的整表；Ctrl+滚轮在此比例上放大
/// 细看，超宽超高可双向滚动），合并格真跨行列。点选格子后底部详情栏
/// 编辑文字——**光标前的文字**在左图中对应的字框高亮（按字顺次对齐，
/// 删/插过字就近匹配），选中格同步淡描边，边看原书面貌边校对。竖排版
/// 面默认「按阅读序排列」——列从右往左（古籍表头在右），可开关切回几
/// 何序（从左往右）。修改直接落在传入的 TableAnnotation 实例上，返回
/// 后由编辑器临时保存。
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
import '../widgets/ctrl_scroll_zoom.dart';

class TableReviewPage extends StatefulWidget {
  final String imagePath;
  final TableAnnotation table;

  /// 页面有效设置（ProjectSettings，随书）：方向之外**引擎也在这里**——
  /// 「重新识别」必须带着书内引擎（选了 PaddleOCR 的书表格重识别同样
  /// 用 Paddle），此前只传方向三件套、engine 回落默认 Kraken 是实际
  /// bug（识别日志首行显示 kraken+chat_rec 的根因之一）。
  final ProjectSettings settings;

  /// 测试注入已解码图（widget 测试的 fake-async 环境里
  /// instantiateImageCodec 不完成，文件路径注不进图片；生产恒 null）。
  @visibleForTesting
  final ui.Image? debugImage;

  const TableReviewPage({
    super.key,
    required this.imagePath,
    required this.table,
    required this.settings,
    this.debugImage,
  });

  @override
  State<TableReviewPage> createState() => _TableReviewPageState();
}

class _TableReviewPageState extends State<TableReviewPage> {
  ui.Image? _image;
  TableCellBlock? _selected;
  late bool _readingOrder;
  bool _busy = false;
  final _textController = TextEditingController();
  final _textFieldFocus = FocusNode();
  final _imgCtrl = TransformationController();
  final _imgViewerKey = GlobalKey();

  // ── Ctrl+滚轮缩放（右侧整表比例 / 左侧原图倍数，与其他校对界面同款交互） ──
  static const double kGridMinZoom = 0.5;
  static const double kGridMaxZoom = 3.0;
  /// 字号缩放锚：适配后平均行高达到此值时用基准 13 号字。
  static const double kGridRowHeight = 108.0;
  double _rowZoom = 1.0;
  static const double kImgMinZoom = 1.0;
  static const double kImgMaxZoom = 8.0;

  /// 右侧电子表格下方叠加原表底图（默认开）：文字与原书字形直接对照。
  bool _showUnderlay = true;

  void _zoomRows(double factor) => setState(() {
        _rowZoom = (_rowZoom * factor).clamp(kGridMinZoom, kGridMaxZoom);
      });

  /// 左图缩放：以视口中心为锚（倍数 = 适配面板的基础尺寸 × 此值）。
  void _zoomImage(double factor) {
    final box = _imgViewerKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final old = _imgCtrl.value.getMaxScaleOnAxis();
    final next = (old * factor).clamp(kImgMinZoom, kImgMaxZoom);
    if ((next - old).abs() < 1e-9) return;
    final v = box.size;
    _imgCtrl.value = Matrix4.identity()
      ..translate(v.width / 2, v.height / 2)
      ..scale(next)
      ..translate(-v.width / 2, -v.height / 2);
  }

  @override
  void initState() {
    super.initState();
    // 默认按阅读序摆表（竖排 rtl 列从右往左）；几何序仅作切换项。
    _readingOrder = true;
    _textController.addListener(_onTextStateChanged);
    if (widget.debugImage != null) {
      _image = widget.debugImage;
    } else {
      _decodeImage();
    }
  }

  @override
  void dispose() {
    _textController
      ..removeListener(_onTextStateChanged)
      ..dispose();
    _textFieldFocus.dispose();
    _imgCtrl.dispose();
    _image?.dispose();
    super.dispose();
  }

  /// 光标/文本变化 → 重算左图高亮（低成本重绘）。
  void _onTextStateChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _decodeImage() async {
    try {
      final data = await File(widget.imagePath).readAsBytes();
      final codec = await ui.instantiateImageCodec(data);
      final frame = await codec.getNextFrame();
      if (mounted) setState(() => _image = frame.image);
    } catch (_) {
      // 原图解码失败不阻塞文字校对（左图区显示占位提示）
    }
  }

  void _selectCell(TableCellBlock? cell) {
    setState(() => _selected = cell);
    final text = cell?.text ?? '';
    // 光标置末：选中即高亮整格文字（光标前 = 全部），编辑/移动光标后
    // 高亮跟着光标走。
    _textController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    if (cell != null) {
      // 点格即进入编辑：焦点直达详情栏输入框，免去二次点击。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _textFieldFocus.requestFocus();
      });
    }
  }

  /// 光标前文字对应的字框（左图高亮区）。
  List<TableCellChar> _charsBeforeCursor() {
    final cell = _selected;
    if (cell == null || cell.chars.isEmpty) return const [];
    var offset = _textController.selection.extentOffset;
    if (offset < 0) offset = _textController.text.length;
    return charsBeforeCursor(_textController.text, offset, cell.chars);
  }

  /// 左图裁剪区：表格外框向外放一点（完整包含外框格线）。
  Rect _tableCropRect(ui.Image img) {
    final t = widget.table;
    final pad = (t.lineWidth * 2 + 6).toDouble();
    final left = math.max(0.0, t.x - pad);
    final top = math.max(0.0, t.y - pad);
    final right = math.min(img.width.toDouble(), t.x + t.w + pad);
    final bottom = math.min(img.height.toDouble(), t.y + t.h + pad);
    if (right - left < 1 || bottom - top < 1) {
      return Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());
    }
    return Rect.fromLTWH(left, top, right - left, bottom - top);
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
        settings: widget.settings,
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
          ..lineWidth = fresh.lineWidth
          ..logLines = fresh.logLines;
        t.cells
          ..clear()
          ..addAll(fresh.cells);
        _selected = null;
      });
    } on TableGridNotFoundException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('重新识别失败：$e')),
        );
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
    final rtlCols =
        widget.settings.orientation == 'vertical' &&
        widget.settings.horizontalDir == 'rtl' &&
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

  /// 识别日志对话框：引擎/模型、每格连通域统计、逐字读/序列读与融合
  /// 决策、耗时——识别效果与官网 Demo 不一致时逐行对照定位差异环节。
  /// 日志可选中复制，也可一键复制全部。
  Future<void> _showLogDialog() async {
    final lines = widget.table.logLines;
    final content = lines.isEmpty ? null : lines.join('\n');
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('识别日志 · ${widget.table.id}'),
        content: SizedBox(
          width: 680,
          child: content == null
              ? const Text(
                  '本表格没有识别日志（识别时未记录，或来自旧版本标注）。'
                  '菜单「重新识别」后即可生成最新日志。',
                )
              : SingleChildScrollView(
                  child: SelectableText(
                    content,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: content == null
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: content));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('识别日志已复制到剪贴板')),
                    );
                  },
            child: const Text('复制全部'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.table;
    final confirmedCount = t.cells
        .where((c) => c.status == AnnotationStatus.confirmed)
        .length;
    // 阅读序切换只在竖排 rtl 有意义（其余版面阅读序 = 几何序）
    final rtlPage = widget.settings.orientation == 'vertical' &&
        widget.settings.horizontalDir == 'rtl';
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '表格校对 ${t.rows}×${t.cols} · $confirmedCount/${t.cells.length} 已确认',
        ),
        actions: [
          IconButton(
            tooltip: _showUnderlay ? '关闭表格底图叠加' : '表格下方叠加原图底图',
            icon: Icon(
              _showUnderlay ? Icons.layers : Icons.layers_clear,
            ),
            onPressed: () => setState(() => _showUnderlay = !_showUnderlay),
          ),
          if (rtlPage)
            IconButton(
              tooltip: _readingOrder
                  ? '切换为几何序（列从左到右）'
                  : '切换为阅读序（列从右到左）',
              icon: Icon(
                _readingOrder
                    ? Icons.format_align_right
                    : Icons.format_align_left,
              ),
              onPressed: () =>
                  setState(() => _readingOrder = !_readingOrder),
            ),
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'show_log':
                  unawaited(_showLogDialog());
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
                value: 'show_log',
                child: Text('识别日志（查看/复制）'),
              ),
              PopupMenuItem(value: 'rerecognize', child: Text('重新识别（覆盖当前文字）')),
              PopupMenuItem(value: 'confirm_all', child: Text('全部确认')),
              PopupMenuItem(
                value: 'export_md',
                child: Text('导出 Markdown（复制+存文件）'),
              ),
              PopupMenuItem(value: 'export_tsv', child: Text('导出 TSV（复制+存文件）')),
            ],
          ),
        ],
      ),
      body: _busy
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('表格识别中…'),
                ],
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      // 左：表格原图（外观样貌 + 光标联动高亮）
                      Expanded(flex: 5, child: _buildImagePane()),
                      Container(width: 1, color: Colors.pink.shade100),
                      // 右：电子化后的表格（真实网格布局）
                      Expanded(flex: 6, child: _buildGrid()),
                    ],
                  ),
                ),
                if (_selected != null) _buildDetailBar(),
              ],
            ),
    );
  }

  // ── 左侧：表格原图 ────────────────────────────────────────────────

  Widget _buildImagePane() {
    final img = _image;
    if (img == null) {
      return const Center(
        child: Text('原图加载中…', style: TextStyle(color: Colors.grey)),
      );
    }
    final cell = _selected;
    return InteractiveViewer(
      key: _imgViewerKey,
      transformationController: _imgCtrl,
      minScale: kImgMinZoom,
      maxScale: kImgMaxZoom,
      boundaryMargin: const EdgeInsets.all(double.infinity),
      child: CtrlScrollZoomSurface(
        onZoom: _zoomImage,
        child: CustomPaint(
          size: Size.infinite,
          painter: _TableImagePainter(
            image: img,
            hLines: widget.table.hLines,
            vLines: widget.table.vLines,
            cropRect: _tableCropRect(img),
            selectedRect: cell == null
                ? null
                : Rect.fromLTWH(
                    cell.x.toDouble(),
                    cell.y.toDouble(),
                    cell.w.toDouble(),
                    cell.h.toDouble(),
                  ),
            highlightRects: [
              for (final c in _charsBeforeCursor())
                Rect.fromLTWH(
                  c.x.toDouble(),
                  c.y.toDouble(),
                  c.w.toDouble(),
                  c.h.toDouble(),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 右侧：电子化表格 ──────────────────────────────────────────────

  Widget _buildGrid() {
    final t = widget.table;
    if (t.rows <= 0 || t.cols <= 0) return const SizedBox.shrink();
    // 整表按几何比例适配右栏（与左图同款 letterbox 观感）：行高/列宽
    // 都取真实格线距离，电子表格与原图同纵横比、同相对行高——原图里
    // 细长的表在右侧也是细长的整表，不再被固定行高撑成巨幅。Ctrl+滚轮
    // 在适配比例基础上继续放大细看。
    final hasVL = t.vLines.length == t.cols + 1 && t.vLines.last > t.vLines.first;
    final hasHL = t.hLines.length == t.rows + 1 && t.hLines.last > t.hLines.first;
    final gridW = hasVL
        ? (t.vLines.last - t.vLines.first).toDouble()
        : (t.w > 0 ? t.w.toDouble() : 1.0);
    final gridH = hasHL
        ? (t.hLines.last - t.hLines.first).toDouble()
        : (t.h > 0 ? t.h.toDouble() : 1.0);
    // 几何坐标 → 网格内偏移（缺格线数据时按均分兜底）
    double geoX(int c) => hasVL
        ? (t.vLines[c] - t.vLines.first).toDouble()
        : c * gridW / t.cols;
    double geoY(int r) => hasHL
        ? (t.hLines[r] - t.hLines.first).toDouble()
        : r * gridH / t.rows;
    final rtlDisplay = _readingOrder &&
        widget.settings.orientation == 'vertical' &&
        widget.settings.horizontalDir == 'rtl';

    return LayoutBuilder(
      builder: (context, cons) {
        const pad = 12.0;
        final paneW = math.max(1.0, cons.maxWidth - pad * 2);
        final paneH = math.max(1.0, cons.maxHeight - pad * 2);
        final fit = math.min(paneW / gridW, paneH / gridH);
        final s = fit * _rowZoom;
        final dispW = gridW * s;
        final dispH = gridH * s;
        // 兜底字号（无字框证据的空格）：随适配比例缩放。
        final fallbackFontSize =
            (15.0 * (gridH * s / t.rows) / kGridRowHeight).clamp(9.0, 30.0);
        // 全表字框中位高（对单格的碎片框/粘字框免疫）：给每格字号定
        // 上下界——碎片框不会把字缩得特别小、粘字框不会撑得特别大。
        final allCharH = [
          for (final b in t.cells)
            for (final c in b.chars)
              if (c.h > 0) c.h,
        ]..sort();
        final tableMedH = allCharH.isEmpty
            ? 0.0
            : allCharH[allCharH.length ~/ 2].toDouble();
        final baseMed = tableMedH * s * 0.92;
        // 每格字号与**原表字形**对齐：取格内**最小**字框的显示尺寸
        // （≈单个字形），夹在全表中位的 [0.75, 1.6] 倍之间，并按格子
        // 的显示宽高封顶——竖排按"每列字数"封顶（所有字排一列也放得
        // 下），横排按格高封顶。放大细看时 s 同步放大，字与底图一起
        // 变大。
        double cellFontSize(TableCellBlock b, double dispCW, double dispCH) {
          if (b.chars.isEmpty) return fallbackFontSize;
          var minH = b.chars.first.h.toDouble();
          var minW = b.chars.first.w.toDouble();
          for (final c in b.chars) {
            if (c.h > 0 && c.h < minH) minH = c.h.toDouble();
            if (c.w > 0 && c.w < minW) minW = c.w.toDouble();
          }
          if (minH <= 0) return fallbackFontSize;
          var f = minH * s * 0.92;
          if (baseMed > 0) {
            f = f.clamp(baseMed * 0.75, baseMed * 1.6);
          }
          final n = b.text.runes.length;
          if (n > 0) {
            if (b.orientation == 'vertical') {
              // 竖排：按格宽估列数（列宽 ≈ 最小字框宽），每列字数封顶
              final nCols = math.max(1, (dispCW / (minW * s)).floor());
              f = math.min(f, dispCH / (n / nCols).ceil());
            } else {
              f = math.min(f, dispCH * 1.05);
            }
          }
          return f.clamp(8.0, 40.0);
        }

        // 几何列 → 显示列：rtl 阅读序时水平镜像（列从右往左摆）
        double dispLeft(int c) => rtlDisplay
            ? dispW - geoX(c + 1) * s
            : geoX(c) * s;

        // 底图叠加：原表裁剪按网格同一比例铺在电子表格下方（淡显），
        // 文字与原书字形直接对照（与官网 Demo 同款观感）。
        final originX = hasVL ? t.vLines.first.toDouble() : t.x.toDouble();
        final originY = hasHL ? t.hLines.first.toDouble() : t.y.toDouble();

        final blocks = <Widget>[
          if (_showUnderlay && _image != null)
            Positioned.fill(
              child: ClipRect(
                child: CustomPaint(
                  key: const ValueKey('table_underlay'),
                  size: Size.infinite,
                  painter: _GridUnderlayPainter(
                    image: _image!,
                    cropRect: _tableCropRect(_image!),
                    origin: Offset(originX, originY),
                    scale: s,
                  ),
                ),
              ),
            ),
        ];
        for (final block in t.cells) {
          final left = dispLeft(block.col);
          final width = (geoX(block.col + block.colSpan) - geoX(block.col)) * s;
          final top = geoY(block.row) * s;
          final height =
              (geoY(block.row + block.rowSpan) - geoY(block.row)) * s;
          blocks.add(
            Positioned(
              left: left,
              top: top,
              width: width.clamp(12.0, dispW),
              height: height.clamp(8.0, dispH),
              child: _CellTile(
                cell: block,
                selected: identical(_selected, block),
                fontSize: cellFontSize(block, width, height),
                onTap: () => _selectCell(block),
              ),
            ),
          );
        }
        // 内容列至少占满面板（不足时表格在面板里居中，与左图 letterbox
        // 观感一致）；放大超宽/超高时双向滚动。
        final columnWidth = math.max(dispW + pad * 2, cons.maxWidth);
        final columnHeight = math.max(dispH + pad * 2, cons.maxHeight);
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: columnWidth,
            child: SingleChildScrollView(
              child: SizedBox(
                width: columnWidth,
                height: columnHeight,
                child: CtrlScrollZoomSurface(
                  onZoom: _zoomRows,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(pad),
                      child: SizedBox(
                        key: const ValueKey('table_grid_box'),
                        width: dispW,
                        height: dispH,
                        child: Stack(children: blocks),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
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
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '第 ${cell.row + 1} 行 · 第 ${cell.col + 1} 列'
                  '${cell.rowSpan > 1 || cell.colSpan > 1 ? '（合并 ${cell.rowSpan}×${cell.colSpan}）' : ''}'
                  ' · ${cell.orientation == 'vertical' ? '竖排' : '横排'}'
                  ' · 左图高亮 = 光标前文字',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _textController,
                  focusNode: _textFieldFocus,
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

/// 单元格瓦片：电子化文字 + 网格边框 + 确认/选中状态。竖排格按字符
/// 自上而下、次列向左排（贴近原书面貌）；外观对照看左侧原图。
class _CellTile extends StatelessWidget {
  final TableCellBlock cell;
  final bool selected;

  /// 字号随整表适配比例缩放（表格很大时缩小、放大细看时同步放大）。
  final double fontSize;
  final VoidCallback onTap;

  const _CellTile({
    required this.cell,
    required this.selected,
    required this.fontSize,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final confirmed = cell.status == AnnotationStatus.confirmed;
    final style = TextStyle(
      fontSize: fontSize,
      height: 1.1,
      color: cell.text.isEmpty ? Colors.grey : null,
    );
    return InkWell(
      onTap: onTap,
      child: Container(
        clipBehavior: Clip.hardEdge,
        decoration: BoxDecoration(
          color: selected
              ? Colors.orange.shade50
              : confirmed
              ? Colors.green.shade50
              : null,
          // 网格边框：相邻格边线相邻呈现，整块读起来就是一张表；合并格
          // 是整块描边，span 正误一眼可辨。
          border: Border.all(
            color: selected ? Colors.orange : Colors.pink.shade100,
            width: selected ? 2 : 1,
          ),
        ),
        padding: const EdgeInsets.all(4),
        // 文字在格内居中（贴近古籍表格"字居格中"的排式）
        alignment: Alignment.center,
        child: cell.text.isEmpty
            ? Text('（空）', style: style)
            : cell.orientation == 'vertical'
                ? Wrap(
                    direction: Axis.vertical,
                    textDirection: TextDirection.rtl,
                    alignment: WrapAlignment.center,
                    children: [
                      for (final r in cell.text.runes)
                        Text(String.fromCharCode(r), style: style),
                    ],
                  )
                : Text(
                    cell.text,
                    style: style,
                    textAlign: TextAlign.center,
                  ),
      ),
    );
  }
}

/// 右侧电子表格的**原表底图叠加**：表格裁剪图按网格同一比例淡显在
/// 文字下方（官网 Demo 同款观感）——网格 Stack 的 (0,0) 对应原图格线
/// 原点 [origin]，图像坐标 = (原图坐标 − origin) × scale，与格子摆位
/// 同一映射，字与原书字形天然对齐；再罩一层半透明白压暗，保证上方
/// 文字可读。
class _GridUnderlayPainter extends CustomPainter {
  final ui.Image image;
  final Rect cropRect;

  /// 网格原点（vLines.first / hLines.first，原图绝对坐标）。
  final Offset origin;

  /// 网格几何 → 显示坐标的比例（与 _buildGrid 的 s 同值）。
  final double scale;

  _GridUnderlayPainter({
    required this.image,
    required this.cropRect,
    required this.origin,
    required this.scale,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final dst = Rect.fromLTWH(
      (cropRect.left - origin.dx) * scale,
      (cropRect.top - origin.dy) * scale,
      cropRect.width * scale,
      cropRect.height * scale,
    );
    canvas.drawImageRect(
      image,
      cropRect,
      dst,
      Paint()..filterQuality = FilterQuality.medium,
    );
    // 压暗罩：底图淡显（图像强度 ~30%），上方文字保持可读。
    canvas.drawRect(
      dst.intersect(Offset.zero & size),
      Paint()..color = Colors.white.withValues(alpha: 0.7),
    );
  }

  @override
  bool shouldRepaint(_GridUnderlayPainter old) =>
      !identical(old.image, image) ||
      old.cropRect != cropRect ||
      old.origin != origin ||
      old.scale != scale;
}

/// 左侧原图绘制：表格裁剪居中 + 检出格线示意 + 选中格描边 + 光标前
/// 文字字框高亮。全部按同一 scale 映射，缩放/平移由外层
/// InteractiveViewer 统一变换。格线以列表实例传入（重新识别会整体换
/// 新列表，identity 比较即可触发重绘——TableAnnotation 是原地改的）。
class _TableImagePainter extends CustomPainter {
  final ui.Image image;
  final List<int> hLines;
  final List<int> vLines;
  final Rect cropRect;

  /// 选中格外框（原图绝对坐标），null = 无选中。
  final Rect? selectedRect;

  /// 光标前文字的字框（原图绝对坐标）。
  final List<Rect> highlightRects;

  _TableImagePainter({
    required this.image,
    required this.hLines,
    required this.vLines,
    required this.cropRect,
    this.selectedRect,
    required this.highlightRects,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 等比放入（letterbox 居中）
    final scale = math.min(
      size.width / cropRect.width,
      size.height / cropRect.height,
    );
    final dstW = cropRect.width * scale;
    final dstH = cropRect.height * scale;
    final offX = (size.width - dstW) / 2;
    final offY = (size.height - dstH) / 2;
    final dst = Rect.fromLTWH(offX, offY, dstW, dstH);
    canvas.drawImageRect(
      image,
      cropRect,
      dst,
      Paint()..filterQuality = FilterQuality.medium,
    );

    Rect map(Rect r) => Rect.fromLTWH(
          offX + (r.left - cropRect.left) * scale,
          offY + (r.top - cropRect.top) * scale,
          r.width * scale,
          r.height * scale,
        );

    // 检出格线示意（淡粉）：与原图真实格线叠着看，切分对不对一眼可辨
    final linePaint = Paint()
      ..color = Colors.pink.withValues(alpha: 0.45)
      ..strokeWidth = 1;
    for (final y in hLines) {
      if (y > cropRect.top && y < cropRect.bottom) {
        final dy = offY + (y - cropRect.top) * scale;
        canvas.drawLine(Offset(offX, dy), Offset(offX + dstW, dy), linePaint);
      }
    }
    for (final x in vLines) {
      if (x > cropRect.left && x < cropRect.right) {
        final dx = offX + (x - cropRect.left) * scale;
        canvas.drawLine(Offset(dx, offY), Offset(dx, offY + dstH), linePaint);
      }
    }

    // 选中格描边（橙色细框）
    final sel = selectedRect;
    if (sel != null) {
      canvas.drawRect(
        map(sel),
        Paint()
          ..color = Colors.orange
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }

    // 光标前文字字框高亮（半透明橙填充）
    final hl = Paint()..color = Colors.orange.withValues(alpha: 0.38);
    for (final r in highlightRects) {
      canvas.drawRect(map(r), hl);
    }
  }

  @override
  bool shouldRepaint(_TableImagePainter old) =>
      !identical(old.image, image) ||
      !identical(old.hLines, hLines) ||
      !identical(old.vLines, vLines) ||
      old.cropRect != cropRect ||
      old.selectedRect != selectedRect ||
      !_sameRects(old.highlightRects, highlightRects);

  static bool _sameRects(List<Rect> a, List<Rect> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
