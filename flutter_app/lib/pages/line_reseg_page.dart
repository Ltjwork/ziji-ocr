import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/python_service.dart';
import '../services/ollama_service.dart';
import '../services/page_recognition.dart';
import 'editor_page.dart'
    show InteractiveLineCrop, charRainbowColor, lineSharesColumnBand;

/// 行内重切（全屏，从全书墨迹归类页双击字格进入）：展示该字所在行的
/// 行图与行内单字识别区，可重新划分——
/// - 行图上拖角调整字框大小、拖动字框移动、空白处拖动画新框
///   （与编辑器行卡片同一交互层 InteractiveLineCrop）；
/// - 点字框或下方字卡选中后可删除；
/// - 「重新切分」对该行做全新拆字 + OCR，「识别填字」保留当前框几何
///   只重新填字（与编辑器"重新切割该列 / 重新识别本行"同链路）。
///
/// 确认状态规则（本页专属口径）：凡是几何被改动过的字（调整/移动/
/// 新画/重切/重填），一律重置为待确认（proposed）——此前「确认所选」
/// 固化的字因选取已变化必须重新确认；几何未动的字保持原状态。整行
/// 有改动时行状态同步回退为待确认并标记 manual（级联重建保留）。
///
/// 页面图按最长边 2200 降采样解码（与墨迹校验调试页同口径，单次解码
/// 用完即释放）；草稿坐标全部工作在解码图像空间，应用时按解码比例
/// 换算回页面像素，未被改动过的字直接沿用原字块实例（零漂移）。
class LineResegPage extends StatefulWidget {
  final Project project;
  final LineBlock line;

  /// 该行在页面标注 lines 列表中的下标（新字块的 col 用）。
  final int lineIndex;
  final int pageIndex;

  /// 页面标注的行列表（可选）。重新切分检出并排双列时，后端会返回多
  /// 行：第一行照常写回 [line]，其余行在应用时插入该列表中本行之后；
  /// 不传则拆分的多余行被丢弃（单行页保持单行契约）。
  final List<LineBlock>? pageLines;

  const LineResegPage({
    super.key,
    required this.project,
    required this.line,
    required this.lineIndex,
    required this.pageIndex,
    this.pageLines,
  });

  @override
  State<LineResegPage> createState() => _LineResegPageState();
}

class _LineResegPageState extends State<LineResegPage> {
  /// 页面图解码上限（最长边）：与墨迹校验调试页同一取值理由。
  static const int _pageImageMaxSide = 2200;

  /// 行图裁切的页边距：行框外扩一点，方便在边缘画新框。
  static const int _cropPad = 8;

  /// 当前权威行（页面像素坐标）。初始为 widget.line 的浅拷贝（chars
  /// 沿用原实例引用）；重切/重填后替换为后端结果。应用时写回
  /// widget.line（书页持有的同一实例）。
  late LineBlock _pageLine;

  /// 草稿行（解码图像坐标）：交互与显示都在这个空间进行。
  LineBlock? _draft;

  ui.Image? _pageImage;
  double _sx = 1; // 解码图像 / 页面像素 的 X 比例
  double _sy = 1;
  bool _loadingImage = true;
  String? _error;

  String? _selectedId;
  bool _dirty = false;
  bool _processing = false;

  /// 几何被改动过的草稿字 id：应用时这些字按草稿换算回页面坐标生成
  /// 新字块（确认状态已随编辑重置）；未在集合里的字直接沿用原实例。
  final Set<String> _touchedIds = {};

  /// 重新切分检出并排双列时，除本行外的其余拆分行（应用时插入页面
  /// 行列表；取消/放弃则丢弃）。
  List<LineBlock> _extraSplitLines = [];

  @override
  void initState() {
    super.initState();
    final line = widget.line;
    _pageLine = LineBlock(
      id: line.id,
      x: line.x,
      y: line.y,
      w: line.w,
      h: line.h,
      lineNo: line.lineNo,
      orientation: line.orientation,
      text: line.text,
      readingOrder: line.readingOrder,
      paragraphId: line.paragraphId,
      status: line.status,
      manual: line.manual,
    );
    _pageLine.chars = [...line.chars];
    _loadCropImage();
  }

  @override
  void dispose() {
    _pageImage?.dispose();
    super.dispose();
  }

  // ── 页面图解码与草稿构建 ──

  Future<void> _loadCropImage() async {
    setState(() {
      _loadingImage = true;
      _error = null;
    });
    try {
      final bytes = await File(
        widget.project.imageFiles[widget.pageIndex],
      ).readAsBytes();
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final pageW = descriptor.width, pageH = descriptor.height;
      final scale =
          _pageImageMaxSide / (pageW > pageH ? pageW : pageH).toDouble();
      final codec = await descriptor.instantiateCodec(
        targetWidth: (pageW * scale).round().clamp(1, pageW),
        targetHeight: (pageH * scale).round().clamp(1, pageH),
      );
      descriptor.dispose();
      buffer.dispose();
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      final old = _pageImage;
      setState(() {
        _pageImage = frame.image;
        _sx = frame.image.width / pageW;
        _sy = frame.image.height / pageH;
        _rebuildDraft();
        _loadingImage = false;
      });
      old?.dispose();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingImage = false;
        _error = '页面图加载失败：$e';
      });
    }
  }

  /// 由 [_pageLine]（页面坐标）重建草稿行（解码图像坐标）。
  void _rebuildDraft() {
    final line = _pageLine;
    int mx(int v) => (v * _sx).round();
    int my(int v) => (v * _sy).round();
    final draft = LineBlock(
      id: line.id,
      x: mx(line.x),
      y: my(line.y),
      w: mx(line.x + line.w) - mx(line.x),
      h: my(line.y + line.h) - my(line.y),
      lineNo: line.lineNo,
      orientation: line.orientation,
      text: line.text,
      readingOrder: line.readingOrder,
      paragraphId: line.paragraphId,
      status: line.status,
      manual: line.manual,
    );
    for (final c in line.chars) {
      final cx = mx(c.x);
      final cy = my(c.y);
      draft.chars.add(
        c.copyWith(x: cx, y: cy, w: mx(c.x + c.w) - cx, h: my(c.y + c.h) - cy),
      );
    }
    _draft = draft;
  }

  // ── 行图交互回调（草稿坐标）──

  void _onCharUpdated(CharBlock old, CharBlock updated) {
    final idx = _draft?.chars.indexOf(old);
    if (idx == null || idx < 0) return;
    var next = updated;
    // 几何被改动过的已确认字 → 重置为待确认（须重新确认）
    if (next.status == AnnotationStatus.confirmed) {
      next = next.copyWith(status: AnnotationStatus.proposed, confirmed: false);
    }
    setState(() {
      _draft!.chars[idx] = next;
      _touchedIds.add(next.id);
      _dirty = true;
    });
  }

  void _onCharAdded(CharBlock c) {
    setState(() {
      _draft!.chars.add(c);
      _touchedIds.add(c.id);
      _selectedId = c.id;
      _dirty = true;
    });
  }

  void _onCharSelected(CharBlock? c) => setState(() => _selectedId = c?.id);

  /// 删除草稿字框（行图 Shift 单击与「删除」按钮共用：按 id 移除，
  /// 删的是当前选中字时同步清选中）。
  void _deleteCharById(String id) {
    if (id.isEmpty || _draft == null) return;
    setState(() {
      _draft!.chars.removeWhere((c) => c.id == id);
      if (_selectedId == id) _selectedId = null;
      _dirty = true;
    });
  }

  void _deleteSelected() => _deleteCharById(_selectedId ?? '');

  // ── 重新切分 / 识别填字（后端 segment_region，GPU 识别门）──

  Future<void> _runBackend({required bool keepBoxes}) async {
    if (_processing) return;
    setState(() => _processing = true);
    try {
      final line = _pageLine;
      final stub = LineBlock(
        id: line.id,
        x: line.x,
        y: line.y,
        w: line.w,
        h: line.h,
        lineNo: line.lineNo,
        orientation: line.orientation,
        manual: line.manual,
      );
      final freshLines = await PythonService.segmentRegion(
        imagePath: widget.project.imageFiles[widget.pageIndex],
        lineStub: stub,
        settings: widget.project.settingsAt(widget.pageIndex),
        charBoxes: keepBoxes
            ? [
                for (final d in _draft!.chars)
                  {
                    'x': (d.x / _sx).round(),
                    'y': (d.y / _sy).round(),
                    'w': (d.w / _sx).round(),
                    'h': (d.h / _sy).round(),
                  },
              ]
            : null,
        // 识别填字（保留当前框）：严格保留草稿框几何——框数与整行读法
        // 不一致时也不弃用重切，否则用户刚调好的框会被自动切分替换。
        strictCharBoxes: keepBoxes,
        // 与页面其它行共享列带（小字注分段）时不外扩：识别范围即本行框
        // （未传页面行列表的单行上下文保持旧行为）。
        expand:
            widget.pageLines == null ||
            !lineSharesColumnBand(_pageLine, widget.pageLines!),
      );
      final aiSettings = await OllamaSettings.load();
      if (aiSettings.enableManualLineAssist) {
        await applyAiLineAssistToLines(
          freshLines,
          widget.project.imageFiles[widget.pageIndex],
          widget.project.settingsAt(widget.pageIndex),
          enabled: true,
          projectDir: widget.project.projectDir,
          pageId: widget.project.pageIdAt(widget.pageIndex),
        );
      }
      if (!mounted) return;
      // 并排双列拆分：首行照常进本行编辑区，其余行应用时插入页面行表。
      _extraSplitLines = freshLines.length > 1
          ? freshLines.sublist(1)
          : const <LineBlock>[];
      final fresh = freshLines.first;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final chars = <CharBlock>[];
      for (var j = 0; j < fresh.chars.length; j++) {
        final c = fresh.chars[j]
          ..id = 'c_${stamp}_$j'
          ..col = widget.lineIndex
          ..order = j
          ..lineId = line.id
          // 重切/重填产出的字一律待确认（即使框几何与原字相同——
          // 文字是重新识别的，须重新确认）
          ..status = AnnotationStatus.proposed
          ..confirmed = false
          ..boxConfirmed = false;
        chars.add(c);
      }
      final adopted = LineBlock(
        id: line.id,
        x: fresh.x,
        y: fresh.y,
        w: fresh.w,
        h: fresh.h,
        lineNo: line.lineNo,
        orientation: fresh.orientation,
        text: fresh.text,
        readingOrder: line.readingOrder,
        paragraphId: line.paragraphId,
        status: AnnotationStatus.proposed,
        manual: line.manual,
      );
      adopted.chars = chars;
      // 手工行框不被外扩覆盖（与编辑器行重识别同口径）。并排双列拆分
      // （多行返回）时旧框是拆前整条，保留会把首行撑回整条几何。
      if (line.manual && _extraSplitLines.isEmpty) {
        adopted.x = line.x;
        adopted.y = line.y;
        adopted.w = line.w;
        adopted.h = line.h;
      }
      setState(() {
        _pageLine = adopted;
        _dirty = true;
        _selectedId = null;
      });
      if (_extraSplitLines.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '该行内检出并排双列：应用后将拆为 '
              '${_extraSplitLines.length + 1} 行（本页编辑首行）',
            ),
          ),
        );
      }
      await _loadCropImage(); // 行框几何可能变化 → 重建裁图与草稿
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('识别失败：$e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  // ── 应用：草稿写回行实例 ──

  void _apply() {
    if (!_dirty || _draft == null) {
      Navigator.of(context).pop(false);
      return;
    }
    final line = widget.line;
    final origById = {for (final c in line.chars) c.id: c};
    final newChars = <CharBlock>[];
    for (final d in _draft!.chars) {
      final orig = origById[d.id];
      if (orig == null) {
        // 新画的框（或重切/重填产出的新字块）：换算回页面像素
        final px = (d.x / _sx).round();
        final py = (d.y / _sy).round();
        newChars.add(
          d.copyWith(
            x: px,
            y: py,
            w: ((d.x + d.w) / _sx).round() - px,
            h: ((d.y + d.h) / _sy).round() - py,
          ),
        );
        continue;
      }
      if (!_touchedIds.contains(d.id)) {
        // 几何未被改动：原字块实例原样保留（确认状态、候选、uid 零漂移）
        newChars.add(orig);
        continue;
      }
      // 调整/移动过的字：直接改写原实例（保持实例同一性，分组与
      // 索引无需换代）；确认状态已在编辑时重置为待确认
      orig.x = (d.x / _sx).round();
      orig.y = (d.y / _sy).round();
      orig.w = ((d.x + d.w) / _sx).round() - orig.x;
      orig.h = ((d.y + d.h) / _sy).round() - orig.y;
      orig.text = d.text;
      orig.status = d.status;
      orig.confirmed = d.status == AnnotationStatus.confirmed;
      orig.candidates = d.candidates;
      newChars.add(orig);
    }
    // 按阅读方向几何排序并回填 order/col/lineId
    final settings = widget.project.settingsAt(widget.pageIndex);
    final vertical = line.orientation == 'vertical';
    final verticalAsc = settings.verticalDir != 'btt';
    final horizontalAsc = settings.horizontalDir != 'rtl';
    newChars.sort((a, b) {
      if (vertical) {
        final ay = a.y + a.h / 2, by = b.y + b.h / 2;
        return verticalAsc ? ay.compareTo(by) : by.compareTo(ay);
      }
      final ax = a.x + a.w / 2, bx = b.x + b.w / 2;
      return horizontalAsc ? ax.compareTo(bx) : bx.compareTo(ax);
    });
    for (var i = 0; i < newChars.length; i++) {
      newChars[i]
        ..order = i
        ..col = widget.lineIndex
        ..lineId = line.id;
    }
    line.x = _pageLine.x;
    line.y = _pageLine.y;
    line.w = _pageLine.w;
    line.h = _pageLine.h;
    line.orientation = _pageLine.orientation;
    line.chars = newChars;
    line.text = newChars.map((c) => c.text).join();
    line.manual = true;
    if (line.status == AnnotationStatus.confirmed) {
      line.status = AnnotationStatus.proposed;
    }
    // 并排双列拆分写回：其余拆分行插到本行之后（col/lineNo 顺延），
    // 字块全部待确认；未传页面行列表时保持单行契约、多余行丢弃。
    if (_extraSplitLines.isNotEmpty) {
      final host = widget.pageLines;
      if (host != null) {
        final idx = host.indexOf(line);
        final baseIdx = idx >= 0 ? idx : widget.lineIndex;
        final stamp = DateTime.now().microsecondsSinceEpoch;
        for (var k = 0; k < _extraSplitLines.length; k++) {
          final extra = _extraSplitLines[k];
          for (var j = 0; j < extra.chars.length; j++) {
            extra.chars[j]
              ..id = 'c_${stamp}_${k + 1}_$j'
              ..col = baseIdx + k + 1
              ..order = j
              ..lineId = extra.id
              ..status = AnnotationStatus.proposed
              ..confirmed = false
              ..boxConfirmed = false;
          }
          extra.paragraphId = line.paragraphId;
          extra.readingOrder = line.readingOrder;
          extra.lineNo = baseIdx + k + 1;
          extra.status = AnnotationStatus.proposed;
          extra.manual = false;
          if (idx >= 0) {
            host.insert(idx + 1 + k, extra);
          }
        }
      }
      _extraSplitLines = [];
    }
    Navigator.of(context).pop(true);
  }

  // ── 布局 ──

  @override
  Widget build(BuildContext context) {
    final selected = _selectedId == null
        ? null
        : _draft?.chars.where((c) => c.id == _selectedId).firstOrNull;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _confirmDiscard();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            '行内重切 · 第 ${widget.pageIndex + 1} 页 · '
            '行 ${widget.lineIndex + 1}',
          ),
        ),
        body: _buildBody(selected),
      ),
    );
  }

  void _confirmDiscard() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('放弃修改？'),
        content: const Text('行内的识别区改动尚未应用，放弃后将回到全书归类页。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('继续编辑'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).pop(false);
            },
            child: const Text('放弃'),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(CharBlock? selected) {
    if (_error != null) {
      return _CenterHint(
        icon: Icons.error_outline,
        text: _error!,
        action: FilledButton.icon(
          onPressed: _loadCropImage,
          icon: const Icon(Icons.refresh),
          label: const Text('重试'),
        ),
      );
    }
    final draft = _draft;
    if (_loadingImage || draft == null) {
      return const _CenterHint(icon: Icons.hourglass_top, text: '正在载入行图…');
    }
    final isVertical = draft.orientation == 'vertical';
    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildToolbar(selected),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: _buildCard(draft, selected, isVertical),
              ),
            ),
            _buildBottomBar(),
          ],
        ),
        if (_processing)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.35),
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text(
                      '正在识别该行…（GPU 识别门，整书识别进行中时会被拒绝）',
                      style: TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildToolbar(CharBlock? selected) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilledButton.tonalIcon(
            onPressed: _processing ? null : () => _runBackend(keepBoxes: false),
            icon: const Icon(Icons.content_cut, size: 16),
            label: const Text('重新切分（推倒重拆+识别）'),
          ),
          OutlinedButton.icon(
            onPressed: _processing ? null : () => _runBackend(keepBoxes: true),
            icon: const Icon(Icons.text_fields, size: 16),
            label: const Text('识别填字（保留当前框）'),
          ),
          OutlinedButton.icon(
            onPressed: selected == null || _processing ? null : _deleteSelected,
            icon: Icon(
              Icons.delete_outline,
              size: 16,
              color: Colors.red.shade700,
            ),
            label: Text('删除所选框', style: TextStyle(color: Colors.red.shade700)),
          ),
          Text(
            '行图上：拖角调整大小 · 拖动移动 · 空白处拖动画新框；'
            '改动过的字会重置为待确认',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(LineBlock draft, CharBlock? selected, bool isVertical) {
    // 展示区域在行框四周外扩几像素（夹回图像边界）：贴边的字框也能
    // 画新框/拖角。InteractiveLineCrop 的命中与绘制以 line 几何为基准，
    // srcRect 放大只是多显示周边图像，坐标映射不受影响。
    final pad = _cropPad.toDouble();
    final imgW = _pageImage!.width.toDouble();
    final imgH = _pageImage!.height.toDouble();
    final raw = Rect.fromLTRB(
      (draft.x - pad).clamp(0.0, imgW),
      (draft.y - pad).clamp(0.0, imgH),
      (draft.x + draft.w + pad).clamp(0.0, imgW),
      (draft.y + draft.h + pad).clamp(0.0, imgH),
    );
    // 退化行框（宽/高为 0，如行框贴齐图像边缘被钳平）防护：裁切区
    // 至少 1×1，避免 InteractiveLineCrop 的坐标换算除以 0 产生 NaN。
    final srcRight = raw.right > raw.left
        ? raw.right
        : (raw.left + 1).clamp(0.0, imgW).toDouble();
    final srcBottom = raw.bottom > raw.top
        ? raw.bottom
        : (raw.top + 1).clamp(0.0, imgH).toDouble();
    final src = Rect.fromLTRB(raw.left, raw.top, srcRight, srcBottom);
    final aspect = src.height > 0 && src.width > 0
        ? src.width / src.height
        : 1.0;
    double displayW;
    double displayH;
    if (isVertical) {
      // 竖排行：以高度定尺寸（整列可见），宽度随纵横比，夹在可画框范围
      displayH = 560;
      displayW = displayH * aspect;
      if (displayW < 44) {
        displayW = 44;
      } else if (displayW > 150) {
        displayW = 150;
      }
      displayH = displayW / aspect;
    } else {
      // 横排行：以宽度定尺寸（整行可见），高度下限防扁到无法点按
      displayW = 860;
      displayH = displayW / aspect;
      if (displayH > 320) {
        displayH = 320;
        displayW = displayH * aspect;
      }
      if (displayH < 24) {
        displayH = 24;
        displayW = displayH * aspect;
      }
    }
    final crop = InteractiveLineCrop(
      image: _pageImage!,
      srcRect: src,
      line: draft,
      displayWidth: displayW,
      displayHeight: displayH,
      selected: selected,
      flashCharId: null,
      onCharUpdated: _onCharUpdated,
      onCharAdded: _onCharAdded,
      onCharSelected: _onCharSelected,
      onCharDeleted: (c) => _deleteCharById(c.id),
    );
    final chips = _buildChips(draft, isVertical);
    if (isVertical) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          crop,
          const SizedBox(width: 10),
          SizedBox(width: 96, height: displayH, child: chips),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        crop,
        const SizedBox(height: 8),
        SizedBox(height: 108, child: chips),
      ],
    );
  }

  /// 字卡（与编辑器单字识别行卡片同风格：裁切图 + 文字 + 状态色边框，
  /// 竖排行纵向排列、横排行横向排列），点击选中。
  Widget _buildChips(LineBlock draft, bool isVertical) {
    final chips = [
      for (final c in draft.chars)
        _ResegChip(
          char: c,
          image: _pageImage!,
          selected: c.id == _selectedId,
          onTap: () => _onCharSelected(c),
        ),
    ];
    if (chips.isEmpty) {
      return Center(
        child: Text(
          '行内没有字框：在行图空白处拖动画出新框',
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
        ),
      );
    }
    if (isVertical) {
      return ListView(
        children: [
          for (final c in chips)
            Padding(padding: const EdgeInsets.only(bottom: 4), child: c),
        ],
      );
    }
    return ListView(
      scrollDirection: Axis.horizontal,
      children: [
        for (final c in chips)
          Padding(padding: const EdgeInsets.only(right: 4), child: c),
      ],
    );
  }

  Widget _buildBottomBar() {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        border: Border(top: BorderSide(color: Colors.grey.shade300)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '应用后：几何被改动过的字重置为待确认，整行状态回退；'
              '分组中的旧字块将被移除（「重新归类」后重新聚组）',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton(
            onPressed: () =>
                _dirty ? _confirmDiscard() : Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _dirty ? _apply : null,
            icon: const Icon(Icons.task_alt, size: 16),
            label: const Text('应用修改'),
          ),
        ],
      ),
    );
  }
}

/// 字卡：裁切图（解码图像按草稿字框裁切）+ 当前文字 + 状态着色。
class _ResegChip extends StatelessWidget {
  final CharBlock char;
  final ui.Image image;
  final bool selected;
  final VoidCallback onTap;

  const _ResegChip({
    required this.char,
    required this.image,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const cell = 60.0;
    final confirmed = char.status == AnnotationStatus.confirmed;
    final empty = char.text.isEmpty;
    final borderColor = selected
        ? Colors.orange.shade700
        : confirmed
        ? Colors.green.shade400
        : empty
        ? Colors.red.shade300
        : charRainbowColor(char.order);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: cell,
            height: cell,
            decoration: BoxDecoration(
              border: Border.all(color: borderColor, width: selected ? 2 : 1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: CustomPaint(
                size: const Size(cell, cell),
                painter: _CharCropPainter(
                  image: image,
                  srcRect: Rect.fromLTWH(
                    char.x.toDouble(),
                    char.y.toDouble(),
                    char.w.toDouble(),
                    char.h.toDouble(),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 2),
          SizedBox(
            width: cell,
            child: Text(
              empty ? '（空）' : char.text,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15,
                height: 1.2,
                color: empty
                    ? Colors.red.shade400
                    : confirmed
                    ? Colors.green.shade800
                    : Colors.black87,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CharCropPainter extends CustomPainter {
  final ui.Image image;
  final Rect srcRect;

  const _CharCropPainter({required this.image, required this.srcRect});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    canvas.drawImageRect(
      image,
      srcRect,
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(covariant _CharCropPainter oldDelegate) {
    return oldDelegate.image != image || oldDelegate.srcRect != srcRect;
  }
}

class _CenterHint extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;

  const _CenterHint({required this.icon, required this.text, this.action});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600),
            ),
          ),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    );
  }
}
