import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/models.dart';
import '../services/python_service.dart';
import '../widgets/backend_console_panel.dart';
import '../widgets/char_verify_common.dart';

/// 墨迹校验调试页：上传一张页面图片 → 整页识别（切字+读字）→ 批量
/// 墨迹重叠校验 → 标红效果可视化。不建项目、不落盘标注，适合拿任
/// 意书页快速试验校验效果（对照 DebugPage 的切分调试）。
class CharVerifyDebugPage extends StatefulWidget {
  /// 作为整合页（HubPage）标签嵌入时不包自己的 Scaffold。
  final bool embedded;

  const CharVerifyDebugPage({super.key, this.embedded = false});

  @override
  State<CharVerifyDebugPage> createState() => _CharVerifyDebugPageState();
}

class _CharVerifyDebugPageState extends State<CharVerifyDebugPage> {
  String? _imagePath;
  String _layoutMode = 'all_text';
  String _horizontalDir = 'ltr';
  String _verticalDir = 'ttb';

  bool _running = false;
  String? _error;
  ui.Image? _pageImage; // 页面原图（画布叠加层用）
  PageAnnotation? _annotation;
  Map<String, CharVerifyOutcome> _results = const {};
  int _tabIndex = 0; // 0=校验结果, 1=后台日志

  /// 字块网格的首次渲染上限：488 字的 Wrap 一次性构建在 debug 模式
  /// （JIT 无优化）下与叠加图重建挤在同一帧，是崩溃高发点（实测
  /// /verify_chars_batch ok 返回后应用即消失）。先渲染前 120 个，
  /// 其余点「显示全部」展开。
  int _gridLimit = 120;

  Future<void> _pickImage() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp', 'bmp'],
    );
    if (result == null || result.files.isEmpty) return;
    final f = result.files.first;
    if (f.path == null) return;
    setState(() {
      _imagePath = f.path;
      _error = null;
      _annotation = null;
      _results = const {};
    });
    _loadPageImage(f.path!);
  }

  /// 叠加层页面图的解码上限（最长边）：桌面 PDF 提取页常见 4000×6000
  /// （全尺寸 RGBA 位图约 96MB），调试页反复换图测试，全尺寸解码且不
  /// 释放会线性吃满内存导致引擎无痕崩溃（实测 15:03 应用消失、Dart
  /// 层零异常、后端存活）。取 2200：GPU 纹理约 29MB（3000 时 54MB，
  /// 与 8 路识别池同时满载显存时叠加冲突面更小），叠加框线显示与缩
  /// 放查看足够。
  static const int _pageImageMaxSide = 2200;

  Future<void> _loadPageImage(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final w = descriptor.width, h = descriptor.height;
      final scale = math.min(
          1.0, _pageImageMaxSide / math.max(w, h).toDouble());
      final codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (w * scale).round()),
        targetHeight: math.max(1, (h * scale).round()),
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
      setState(() => _pageImage = frame.image);
      // 旧图在脱离渲染树后释放（不能在 setState 前释放： painter 可能
      // 仍在用旧帧）
      old?.dispose();
    } catch (_) {
      // 原图解码失败只影响叠加预览，识别与校验照常
      if (mounted) setState(() => _pageImage = null);
    }
  }

  @override
  void dispose() {
    _pageImage?.dispose();
    super.dispose();
  }

  /// 识别 → 校验全流程。识别走整页 /segment（GPU 识别门，整页一次），
  /// 校验走 /verify_chars_batch（纯 CPU），两段日志都进后台日志页。
  Future<void> _run() async {
    final imagePath = _imagePath;
    if (imagePath == null) {
      setState(() => _error = '请先选择图片');
      return;
    }
    setState(() {
      _running = true;
      _error = null;
      _annotation = null;
      _results = const {};
    });
    try {
      final annotation = await PythonService.segmentWithSettings(
        imagePath: imagePath,
        pageId: 'debug_verify',
        settings: ProjectSettings(
          layoutMode: _layoutMode,
          horizontalDir: _horizontalDir,
          verticalDir: _verticalDir,
        ),
      );
      if (!mounted) return;
      setState(() => _annotation = annotation);
      final targets = annotation.blocks
          .where((b) => b.type == 'main_text' && b.text.trim().isNotEmpty)
          .toList();
      if (targets.isEmpty) {
        setState(() => _error = '识别完成但没有可校验的文字');
        return;
      }
      final result = await PythonService.verifyCharsBatch(
        imagePath: imagePath,
        blocks: targets,
      );
      if (!mounted) return;
      // 死点打点：上次应用在此后渲染结果时无痕退出，分阶段记录到
      // app 日志（崩在哪个打点之后一目了然）
      PythonService.addAppLog(
        '墨迹校验结果已接收（${result.results.length} 字），写入状态');
      setState(() {
        _gridLimit = 120;
        _results = result.results;
      });
      PythonService.addAppLog('墨迹校验结果已渲染');
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Widget _buildSegment({
    required String title,
    required String value,
    required List<({String value, String label})> options,
    required ValueChanged<String> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(
              title,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
          Expanded(
            child: SegmentedButton<String>(
              segments: options
                  .map(
                    (o) => ButtonSegment<String>(
                      value: o.value,
                      label: Text(o.label, style: const TextStyle(fontSize: 12)),
                    ),
                  )
                  .toList(),
              selected: {value},
              onSelectionChanged: (s) => onChanged(s.first),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabSwitch = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 0, label: Text('校验结果')),
            ButtonSegment(value: 1, label: Text('后台日志')),
          ],
          selected: {_tabIndex},
          onSelectionChanged: (s) => setState(() => _tabIndex = s.first),
        ),
      ),
    );
    final body = Column(
      children: [
        // 嵌入整合页时页内切换条搬到正文顶部（独立打开时挂在 AppBar 下）。
        if (widget.embedded) tabSwitch,
        Expanded(
          child: IndexedStack(
            index: _tabIndex,
            children: [
          SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 980),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.amber.shade50,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.amber.shade200),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.info_outline,
                            size: 18,
                            color: Colors.amber.shade800,
                          ),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              '上传一张页面图片（不建项目、不落盘），自动切字识别后逐字做墨迹重叠校验：\n'
                              '红框/红字 = 识别与墨迹结构不符，琥珀 = 存疑，绿 = 匹配，灰 = 跳过（标点/缺字）。\n'
                              '点击缩略图上的字框或下方文字块可看墨迹对照叠加图。',
                              style: TextStyle(fontSize: 12, height: 1.6),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Text(
                                  '选择图片',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const Spacer(),
                                FilledButton.tonalIcon(
                                  onPressed: _running ? null : _pickImage,
                                  icon: const Icon(Icons.image),
                                  label: const Text('选择图片'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            if (_imagePath == null)
                              const Text(
                                '支持 jpg / png / webp / bmp',
                                style: TextStyle(
                                  color: Colors.grey,
                                  fontSize: 12,
                                ),
                              )
                            else
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.blue.shade50,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  p.basename(_imagePath!),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.blue.shade700,
                                  ),
                                ),
                              ),
                            const SizedBox(height: 8),
                            _buildSegment(
                              title: '识别范围',
                              value: _layoutMode,
                              options: const [
                                (value: 'main_text_only', label: '只识别正文'),
                                (value: 'all_text', label: '识别全部'),
                              ],
                              onChanged: (v) =>
                                  setState(() => _layoutMode = v),
                            ),
                            _buildSegment(
                              title: '横排方向',
                              value: _horizontalDir,
                              options: const [
                                (value: 'ltr', label: '从左到右'),
                                (value: 'rtl', label: '从右到左'),
                              ],
                              onChanged: (v) =>
                                  setState(() => _horizontalDir = v),
                            ),
                            _buildSegment(
                              title: '竖排方向',
                              value: _verticalDir,
                              options: const [
                                (value: 'ttb', label: '从上到下'),
                                (value: 'btt', label: '从下到上'),
                              ],
                              onChanged: (v) =>
                                  setState(() => _verticalDir = v),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (_error != null)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _error!,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.red.shade700,
                          ),
                        ),
                      ),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: (_running || _imagePath == null)
                            ? null
                            : _run,
                        icon: _running
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.play_arrow),
                        label: Text(
                          _running
                              ? '正在识别并校验…'
                              : '开始识别并校验（整页）',
                        ),
                      ),
                    ),
                    if (_annotation != null) ...[
                      const SizedBox(height: 24),
                      _buildStats(),
                      const SizedBox(height: 12),
                      if (_pageImage != null) ...[
                        const Text(
                          '标红效果（缩放查看）',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        // AspectRatio 锁定原图宽高比：CustomPaint 直接声明
                        // 页面像素尺寸时会被父级宽度约束水平压缩（高度不
                        // 变），图被压扁、字框坐标系与显示尺寸不一致而错
                        // 位。由 AspectRatio 给出与原图同比例的显示框，
                        // painter 内部再做页面坐标 → 显示坐标换算。
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: AspectRatio(
                            aspectRatio:
                                _pageImage!.width / _pageImage!.height,
                            // RepaintBoundary：缩放/平移时只重绘叠加层，
                            // 不把整页每帧栅格化（大图 GPU 内存压力）
                            child: RepaintBoundary(
                              child: InteractiveViewer(
                                maxScale: 8,
                                minScale: 1,
                                boundaryMargin: const EdgeInsets.all(
                                  double.infinity,
                                ),
                                child: CustomPaint(
                                  painter: _VerifyOverlayPainter(
                                    image: _pageImage!,
                                    blocks: _annotation!.blocks,
                                    results: _results,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      _buildCharGrid(),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const BackendConsolePanel(),
            ],
          ),
        ),
      ],
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(
        title: const Text('墨迹校验调试'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: tabSwitch,
        ),
      ),
      body: body,
    );
  }

  Widget _buildStats() {
    final levels = <String, int>{};
    for (final r in _results.values) {
      levels[r.level] = (levels[r.level] ?? 0) + 1;
    }
    int count(String k) => levels[k] ?? 0;
    final total = _results.length;
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        _statChip('校验字数: $total', Colors.blueGrey),
        _statChip('不匹配: ${count('mismatch')}', kVerifyMismatchRed),
        _statChip('存疑: ${count('suspect')}', kVerifySuspectAmber),
        _statChip('匹配: ${count('ok')}', Colors.green.shade700),
        _statChip('跳过: ${count('skipped')}', Colors.grey),
      ],
    );
  }

  Widget _statChip(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: color.withValues(alpha: 0.5)),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 12, color: color),
    ),
  );

  /// 字块网格：文字按等级着色（与编辑器行卡片同口径），点击弹墨迹对照。
  /// 首次只渲染 [_gridLimit] 个（见其注释），其余点「显示全部」。
  Widget _buildCharGrid() {
    final blocks = _annotation!.blocks
        .where((b) => b.type == 'main_text' && b.text.trim().isNotEmpty)
        .toList();
    final shown = blocks.take(_gridLimit).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '逐字结果（点击查看墨迹对照）',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final b in shown) _buildCharChip(b, _results[b.id]),
          ],
        ),
        if (blocks.length > shown.length)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton(
              onPressed: () => setState(() => _gridLimit = blocks.length),
              child: Text(
                '显示全部 ${blocks.length} 个字'
                '（已显示 ${shown.length} 个）',
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildCharChip(CharBlock block, CharVerifyOutcome? outcome) {
    final color = switch (outcome?.level) {
      'mismatch' => kVerifyMismatchRed,
      'suspect' => kVerifySuspectAmber,
      'ok' => Colors.green.shade600,
      _ => Colors.grey,
    };
    final score = outcome?.score;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => _showDialog(block),
      child: Container(
        width: 46,
        height: 46,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: color,
            width: outcome?.level == 'mismatch' ? 2 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              block.text,
              style: TextStyle(fontSize: 17, color: color),
            ),
            if (score != null)
              Text(
                (score * 100).toStringAsFixed(0),
                style: TextStyle(fontSize: 8, color: color),
              ),
          ],
        ),
      ),
    );
  }

  void _showDialog(CharBlock block) {
    final imagePath = _imagePath;
    if (imagePath == null) return;
    showDialog(
      context: context,
      builder: (_) => CharVerifyDialog(
        imagePath: imagePath,
        block: block,
        onApplyResult: (level, score) {
          // 调试页无标注数据可写，仅同步刷新网格显示
          if (!mounted) return;
          setState(() {
            _results = {
              ..._results,
              block.id: CharVerifyOutcome(
                level: level,
                score: score,
                raw: const {},
              ),
            };
          });
        },
      ),
    );
  }
}

/// 页面图 + 按校验等级着色的字框叠加层（红=不匹配、琥珀=存疑、
/// 绿=匹配、灰=跳过/未校验）。
///
/// 字框坐标是页面像素坐标，画布 size 是显示尺寸（AspectRatio 锁定
/// 原图比例后的显示框），绘制时按 scaleX/scaleY 换算——与编辑器行图
/// _LineCropPainter 同一模式。
class _VerifyOverlayPainter extends CustomPainter {
  final ui.Image image;
  final List<CharBlock> blocks;
  final Map<String, CharVerifyOutcome> results;

  _VerifyOverlayPainter({
    required this.image,
    required this.blocks,
    required this.results,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 显示尺寸退化（AspectRatio 首帧约束为 0）时跳过绘制
    if (size.width <= 0 || size.height <= 0) return;
    final scaleX = size.width / image.width;
    final scaleY = size.height / image.height;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.low,
    );
    for (final b in blocks) {
      if (b.type != 'main_text') continue;
      final dr = Rect.fromLTWH(
        b.x * scaleX,
        b.y * scaleY,
        b.w * scaleX,
        b.h * scaleY,
      );
      final level = results[b.id]?.level;
      final (color, width) = switch (level) {
        'mismatch' => (kVerifyMismatchRed, 5.0),
        'suspect' => (kVerifySuspectAmber, 4.0),
        'ok' => (Colors.green.shade600, 3.0),
        _ => (Colors.blueGrey.shade300, 3.0),
      };
      canvas.drawRect(
        dr,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = color
          ..strokeWidth = width,
      );
    }
  }

  @override
  bool shouldRepaint(_VerifyOverlayPainter old) =>
      old.results != results || old.blocks != blocks || old.image != image;
}
