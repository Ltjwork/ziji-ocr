import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/models.dart';
import '../models/page_quad.dart';
import '../services/char_stats.dart';
import '../services/python_service.dart';
import '../services/recognition_queue.dart';
import '../services/storage.dart';

/// 跨页拆分（编辑器「更多操作」入口）：左右两个书页合扫成一张图的 PDF/
/// 图片，按全书叠加图上选定的中缝位置把每张跨页拆成两个书页。
///
/// - 叠加：窗口内的页面半透明合成一张图（与「全书叠加」同一套客户端
///   合成），扫描偏移与贯穿全书的黑色中缝竖带一目了然，据此拖动中缝线。
/// - 顺序：先左后右（现代图书）/ 先右后左（古籍竖排），决定拆出的两页
///   在全书页列表中的先后。
/// - 应用：逐张调后端 `/split_page` 切图，已识别页的标注按中缝裁剪投影
///   到两个新页（几何平移收界、确认状态与 uid 保留）；源页的图片与标注
///   文件原地保留成孤儿——「恢复拆分前」因此无需备份即可还原。
/// - 拆分后无标注的页自动排队整本识别（有标注的页视为已识别跳过）。
/// - 重拆：拆分记录存在时，叠加与拆分重新基于拆分前的原始页面，输出
///   页号同序推导故原位覆盖。
class BookSplitPage extends StatefulWidget {
  const BookSplitPage({
    super.key,
    required this.project,
    this.enqueueRecognitionAfter = true,
  });

  final Project project;

  /// 应用拆分后是否自动入队整本识别。编辑器单独进入时 true（原行为）；
  /// 新建任务流水线传 false——拆分后还有批量摆正，识别由流水线末尾
  /// 统一入队（手动模式则等用户手动开始）。
  final bool enqueueRecognitionAfter;

  @override
  State<BookSplitPage> createState() => _BookSplitPageState();
}

class _BookSplitPageState extends State<BookSplitPage> {
  static const double _canvasW = 1200;
  static const int _maxWindow = 100;
  static const double _composeDecodeWidth = 1200;

  ui.Image? _composite;
  double _canvasH = 0;

  /// 窗口首个可读页在画布上的 contain 位置：中缝比例与画布坐标互转、
  /// 微调步长换算的基准（同比例书的页 contain 位置一致）。
  Rect? _pageFit;
  Size? _refPageSize;

  int _windowStart = 0;
  int _windowSize = 30;
  double _pageAlpha = 1 / 30;
  bool _composing = false;
  int _composeDone = 0;

  // ── 拆分设置 ──
  String _order = 'right_first'; // 'left_first' | 'right_first'
  double _spineRatio = 0.5;

  // ── 画布交互 ──
  bool _spineDragging = false;
  final TransformationController _transform = TransformationController();
  Offset? _panAnchor;
  Size? _viewportSize;

  // ── 应用状态 ──
  bool _applying = false;

  /// 拆分输入源：拆分过 → 拆分前原始页面；未拆分 → 当前页面。
  late List<String> _sources;

  /// 重拆模式下源文件有缺失（被手动清理过）：禁用应用并提示。
  bool _missingSources = false;

  @override
  void initState() {
    super.initState();
    final info = widget.project.splitInfo;
    if (info != null && info.sourceFiles.isNotEmpty) {
      _sources = List.of(info.sourceFiles);
      _spineRatio = info.spineRatio.clamp(0.02, 0.98);
      _order = info.order == 'left_first' ? 'left_first' : 'right_first';
      _windowSize = math.min(_maxWindow, math.max(4, _sources.length));
    } else {
      _sources = List.of(widget.project.imageFiles);
      _windowSize = math.min(_maxWindow, math.max(4, _sources.length));
    }
    _pageAlpha = (1 / _windowSize).clamp(0.02, 1.0);
    unawaited(_checkSources());
    _recompose();
  }

  @override
  void dispose() {
    _composite?.dispose();
    _transform.dispose();
    super.dispose();
  }

  int get _sourceCount => _sources.length;

  int get _windowEnd => math.min(_windowStart + _windowSize, _sourceCount);

  int get _windowSliderMax =>
      math.max(4, math.min(_maxWindow, math.max(_sourceCount, 4)));

  bool get _isResplit => widget.project.splitInfo != null;

  double get _spineCanvasX {
    final fit = _pageFit;
    if (fit == null) return _canvasW * _spineRatio;
    return fit.left + _spineRatio * fit.width;
  }

  /// 重拆模式下源文件是否都在盘上（拆分依赖原始页面文件）。
  Future<void> _checkSources() async {
    var missing = 0;
    for (final path in _sources) {
      if (!await File(path).exists()) missing++;
    }
    if (!mounted) return;
    setState(() => _missingSources = missing > 0);
  }

  // ── 合成 ──

  Future<void> _recompose() async {
    if (_sourceCount == 0 || _applying) return;
    if (_windowStart >= _sourceCount) _windowStart = 0;
    setState(() {
      _composing = true;
      _composeDone = 0;
    });
    // 画布比例取窗口首个可读页（拆分场景全书同版式；个别页比例不同
    // 则 contain 留边）。
    var firstIndex = _windowStart;
    Size? firstSize;
    while (firstSize == null && firstIndex < _windowEnd) {
      firstSize = await _readImageSize(_sources[firstIndex]);
      firstIndex++;
    }
    if (!mounted) return;
    if (firstSize == null) {
      setState(() => _composing = false);
      return;
    }
    final canvasSize = Size(
      _canvasW,
      _canvasW * firstSize.height / firstSize.width,
    );
    final pageFit = _fitRect(firstSize, canvasSize);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Offset.zero & canvasSize,
      Paint()..color = const Color(0xFF181818),
    );
    final alpha = _pageAlpha.clamp(0.02, 1.0);
    final paint = Paint()..filterQuality = FilterQuality.low;
    for (var i = _windowStart; i < _windowEnd; i++) {
      final img = await _decode(_sources[i], _composeDecodeWidth.round());
      if (img != null) {
        // 每页按自身尺寸 contain（与全书叠加一致）；同比例书与 pageFit 重合。
        final fit = _fitRect(
          Size(img.width.toDouble(), img.height.toDouble()),
          canvasSize,
        );
        paint.color = Color.fromRGBO(255, 255, 255, alpha);
        canvas.drawImageRect(
          img,
          Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
          fit,
          paint,
        );
        img.dispose(); // 已画入离屏画布，立即释放源图
      }
      if (!mounted) {
        recorder.endRecording().dispose();
        return;
      }
      setState(() => _composeDone = i - _windowStart + 1);
    }
    final picture = recorder.endRecording();
    final composite = await picture.toImage(
      canvasSize.width.round(),
      canvasSize.height.round(),
    );
    picture.dispose();
    if (!mounted) {
      composite.dispose();
      return;
    }
    _fitInitialView(canvasSize);
    setState(() {
      _composite?.dispose();
      _composite = composite;
      _canvasH = canvasSize.height;
      _pageFit = pageFit;
      _refPageSize = firstSize;
      _composing = false;
    });
  }

  /// 首次合成后把画布缩放到整页可见居中；用户已缩放/平移过则不动。
  void _fitInitialView(Size canvasSize) {
    if (!_transform.value.isIdentity()) return;
    final vp = _viewportSize;
    if (vp == null || vp.width <= 0 || vp.height <= 0) return;
    final scale =
        math.min(vp.width / canvasSize.width, vp.height / canvasSize.height) *
        0.95;
    final tx = (vp.width - canvasSize.width * scale) / 2;
    final ty = (vp.height - canvasSize.height * scale) / 2;
    _transform.value = Matrix4.translationValues(tx, ty, 0).multiplied(
      Matrix4.identity()..scaleByDouble(scale, scale, 1, 1),
    );
  }

  Future<ui.Image?> _decode(String path, int targetWidth) async {
    try {
      final data = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(
        data,
        targetWidth: targetWidth,
      );
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  /// 只读文件头取图像尺寸（PNG IHDR / JPEG SOF，兜底走整图解码）。
  Future<Size?> _readImageSize(String path) async {
    RandomAccessFile? raf;
    try {
      raf = File(path).openSync(mode: FileMode.read);
      final head = raf.readSync(24);
      if (head.length >= 24 &&
          head[0] == 0x89 &&
          head[1] == 0x50 &&
          head[2] == 0x4E &&
          head[3] == 0x47) {
        final w =
            (head[16] << 24) | (head[17] << 16) | (head[18] << 8) | head[19];
        final h =
            (head[20] << 24) | (head[21] << 16) | (head[22] << 8) | head[23];
        if (w > 0 && h > 0) return Size(w.toDouble(), h.toDouble());
      }
    } catch (_) {
      // 走下面的整图解码兜底。
    } finally {
      raf?.closeSync();
    }
    try {
      final img = await _decode(path, 64);
      if (img == null) return null;
      final size = Size(img.width.toDouble(), img.height.toDouble());
      img.dispose();
      return size;
    } catch (_) {
      return null;
    }
  }

  static Rect _fitRect(Size page, Size canvas) {
    final scale = math.min(
      canvas.width / page.width,
      canvas.height / page.height,
    );
    return Rect.fromLTWH(
      (canvas.width - page.width * scale) / 2,
      (canvas.height - page.height * scale) / 2,
      page.width * scale,
      page.height * scale,
    );
  }

  // ── 画布交互 ──

  // getMaxScaleOnAxis 会把恒为 1 的 z 轴当最大值永远返回 1.0，必须取 x/y 轴。
  double get _viewScale => matrixXyScale(_transform.value);

  void _panBy(Offset screenDelta) {
    final m = _transform.value;
    _transform.value = Matrix4.translationValues(
      screenDelta.dx,
      screenDelta.dy,
      0,
    ).multiplied(m);
  }

  /// 把画布 x 换算成中缝比例并夹进页面范围。
  void _setSpineFromCanvasX(double x) {
    final fit = _pageFit;
    if (fit == null || fit.width <= 0) return;
    setState(() {
      _spineRatio = ((x - fit.left) / fit.width).clamp(0.02, 0.98);
    });
  }

  void _nudgeSpine(int pagePixels) {
    final pageWidth = _refPageSize?.width;
    if (pageWidth == null || pageWidth <= 0) return;
    setState(() {
      _spineRatio = (_spineRatio + pagePixels / pageWidth).clamp(0.02, 0.98);
    });
  }

  void _onPanStart(DragStartDetails d) {
    final x = d.localPosition.dx.clamp(0.0, _canvasW);
    final hitR = 14 / _viewScale;
    if ((x - _spineCanvasX).abs() <= hitR) {
      setState(() => _spineDragging = true);
      return;
    }
    // 点击远处直接把中缝跳到该处并继续拖动。
    _setSpineFromCanvasX(x);
    setState(() => _spineDragging = true);
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (!_spineDragging) return;
    _setSpineFromCanvasX(d.localPosition.dx.clamp(0.0, _canvasW));
  }

  void _onPanEnd(DragEndDetails d) {
    setState(() => _spineDragging = false);
  }

  // ── 应用 ──

  Future<void> _showApplyDialog() async {
    if (_sourceCount == 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('本书没有页面可拆分')));
      return;
    }
    final isResplit = _isResplit;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('确认拆分'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '将把 $_sourceCount 张跨页扫描拆成 ${_sourceCount * 2} 页：\n'
                '中缝位置：页宽 ${(_spineRatio * 100).toStringAsFixed(1)}%；'
                '页序：${_order == 'left_first' ? '先左后右（左半页在前）' : '先右后左（右半页在前）'}。',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 10),
              const Text(
                '已识别页的标注会按中缝拆分到两个新页（几何平移收界，'
                '确认状态保留）；无标注的页拆分后自动排队整本识别。'
                '拆分前的原始页面保留在盘上，可随时回来恢复或重拆。',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              if (isResplit) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '本书已拆分过：本次基于拆分前的原始页面重拆，'
                    '输出页号不变、现有拆分页上的识别与校对修改会被覆盖。',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.orange.shade900,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.splitscreen),
            label: const Text('开始拆分'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _runSplit();
  }

  Future<void> _runSplit() async {
    if (_applying || _missingSources) return;
    final project = widget.project;
    final sources = List.of(_sources);
    final leftFirst = _order == 'left_first';
    final spineRatio = _spineRatio;
    final outputDir = p.join(project.projectDir, 'split');
    final plan = SplitPlan.build(
      sources: sources,
      leftFirst: leftFirst,
      outputDir: outputDir,
      startIndex: splitOutputStartIndex(sources),
    );

    setState(() => _applying = true);
    PythonService.addAppLog(
      '[跨页拆分] 开始：${sources.length} 张跨页 → ${sources.length * 2} 页，'
      '中缝 ${(spineRatio * 100).toStringAsFixed(1)}%，'
      '顺序 ${leftFirst ? '先左后右' : '先右后左'}',
    );
    // 本书若还在整本识别队列里（拆分期间队列在跑旧页面列表），先摘除
    // 防止队列并发改写同一批标注文件；拆分落定后重新入队补识别缺口。
    RecognitionQueue.instance.remove(project.id);

    var cancel = false;
    var done = 0;
    var failed = 0;
    Object? firstError;
    String? firstErrorName;
    StateSetter? setProgress;
    var currentLabel = '';

    final progressFuture = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: StatefulBuilder(
          builder: (dialogContext, setStateInDialog) {
            setProgress = setStateInDialog;
            return AlertDialog(
              title: const Text('正在拆分'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(
                    value: sources.isEmpty
                        ? 1
                        : done / sources.length,
                  ),
                  const SizedBox(height: 12),
                  Text(currentLabel),
                  const SizedBox(height: 4),
                  Text(
                    '已完成 $done / ${sources.length}'
                    '${failed > 0 ? '，失败 $failed' : ''}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    cancel = true;
                    Navigator.of(dialogContext).pop();
                  },
                  child: const Text('停止'),
                ),
              ],
            );
          },
        ),
      ),
    );

    // 重拆时先清掉上一轮输出页的标注文件：源页有标注的会被新投影覆盖，
    // 源页无标注的页不能残留上一轮的旧识别结果（会被当成"已识别"跳过）。
    final previousInfo = project.splitInfo;
    if (previousInfo != null && previousInfo.outputPageIds.isNotEmpty) {
      final annDir = p.join(project.projectDir, 'annotations');
      for (final pageId in previousInfo.outputPageIds) {
        for (final suffix in ['.json', '.json.bak']) {
          final f = File(p.join(annDir, pageId + suffix));
          try {
            if (await f.exists()) await f.delete();
          } catch (_) {
            // 单个清理失败不阻断；旧文件随后会被同名新输出覆盖或成为孤儿。
          }
        }
      }
    }

    for (var i = 0; i < sources.length; i++) {
      if (cancel) break;
      currentLabel = '第 ${i + 1}/${sources.length} 张 …';
      setProgress?.call(() {});
      try {
        final dims = await PythonService.splitPage(
          imagePath: sources[i],
          spineRatio: spineRatio,
          leftPath: plan.perSource[i].leftPath,
          rightPath: plan.perSource[i].rightPath,
        );
        final w = (dims['w'] as num).toInt();
        final h = (dims['h'] as num).toInt();
        final spineX = (dims['spine_x'] as num).toInt();
        // 源页标注按中缝裁剪投影到两个新页；源页标注文件原地保留成孤儿。
        final srcAnn = await ProjectStorage.loadAnnotation(
          project.projectDir,
          pageIdForImage(sources[i], i),
        );
        if (srcAnn != null) {
          final leftAnn = srcAnn.croppedTo(
            newPageId: plan.perSource[i].leftPageId,
            newImagePath: plan.perSource[i].leftPath,
            crop: Rect.fromLTWH(0, 0, spineX.toDouble(), h.toDouble()),
          );
          final rightAnn = srcAnn.croppedTo(
            newPageId: plan.perSource[i].rightPageId,
            newImagePath: plan.perSource[i].rightPath,
            crop: Rect.fromLTWH(
              spineX.toDouble(),
              0,
              (w - spineX).toDouble(),
              h.toDouble(),
            ),
          );
          await ProjectStorage.saveAnnotation(project.projectDir, leftAnn);
          await ProjectStorage.saveAnnotation(project.projectDir, rightAnn);
        }
      } catch (error) {
        failed++;
        firstError ??= error;
        firstErrorName ??= p.basename(sources[i]);
        PythonService.addAppLog(
          '[跨页拆分] 第 ${i + 1} 张（${p.basename(sources[i])}）拆分失败：$error',
          isError: true,
        );
      }
      done++;
      setProgress?.call(() {});
    }

    if (cancel || failed > 0) {
      // 项目状态只在全部成功后改写：中途失败/停止时页面列表保持原样，
      // 已写出的半页文件是无害孤儿（重试时同页号覆盖）。
      // 文字汇总账本对账：本轮已写出的半页账目随孤儿撤账（页面列表未
      // 改动，源页账目保留）。
      unawaited(
        CharStatsService.reconcileProject(project.projectDir, project.imageFiles),
      );
      if (!cancel && mounted) {
        Navigator.of(context).pop(); // 关进度框
      }
      await progressFuture;
      if (!mounted) return;
      setState(() => _applying = false);
      unawaited(
        showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(cancel ? '已停止' : '拆分失败'),
            content: Text(
              cancel
                  ? '拆分已停止，全书页面列表未改动。'
                  : '「$firstErrorName」拆分失败：$firstError\n'
                  '全书页面列表未改动，可排查后重试（已生成的半页文件会在'
                  '重试时覆盖）。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('知道了'),
              ),
            ],
          ),
        ),
      );
      return;
    }

    // ── 落定项目状态 ──
    for (final path in plan.readingOrderPaths) {
      FileImage(File(path)).evict(); // 输出路径不变的重拆需要清掉旧图缓存
    }
    project.imageFiles = List.of(plan.readingOrderPaths);
    // 文字汇总账本对账：源跨页被两个半页取代（源页标注原地成孤儿），
    // 源页账目撤账；半页账目由拆分循环里的 saveAnnotation 钩子自动建立。
    unawaited(
      CharStatsService.reconcileProject(project.projectDir, project.imageFiles),
    );
    project.splitInfo = SplitInfo(
      sourceFiles: sources,
      spineRatio: spineRatio,
      order: _order,
      outputDir: outputDir,
      outputPageIds: List.of(plan.outputPageIds),
    );
    project.lastPageIndex = project.lastPageIndex.clamp(
      0,
      math.max(0, project.imageFiles.length - 1),
    );
    // 有标注的输出页视为已识别，其余排队整本识别（队列按盘上标注文件跳过）。
    final recognized = await ProjectStorage.savedAnnotationIndices(
      project.projectDir,
      project.imageFiles.length,
      imageFiles: project.imageFiles,
    );
    project.recognizedPages = recognized.length;
    project.recognitionStatus = RecognitionStatus.pending;
    await ProjectStorage.save(project);
    // 流水线模式（enqueueRecognitionAfter=false）不入队：拆分后还有批量
    // 摆正，识别由流水线末尾统一入队（手动模式等用户手动开始）。
    if (widget.enqueueRecognitionAfter) {
      RecognitionQueue.instance.enqueue(project);
    }

    if (!mounted) return;
    Navigator.of(context).pop(); // 关进度框
    await progressFuture;
    PythonService.addAppLog(
      '[跨页拆分] 完成：${sources.length} 张 → ${project.imageFiles.length} 页，'
      '其中 ${recognized.length} 页沿用拆分标注，'
      '${widget.enqueueRecognitionAfter ? '${project.imageFiles.length - recognized.length} 页已排队识别' : '识别待流水线后续步骤'}',
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '拆分完成：${sources.length} 张跨页 → ${project.imageFiles.length} 页，'
          '无标注页已在后台排队识别',
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _applying = false);
    Navigator.of(context).pop(true);
  }

  /// 恢复拆分前：源页图片与标注从未被拆分改写，还原页面列表即回到拆分
  /// 前状态；拆分输出页的图片与标注随之清理。
  Future<void> _restoreSplit() async {
    final project = widget.project;
    final info = project.splitInfo;
    if (info == null || _applying) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('恢复拆分前页面'),
        content: Text(
          '将恢复拆分前的 ${info.sourceFiles.length} 张跨页页面'
          '（其标注从未被拆分改写，原样恢复），并删除拆分产生的 '
          '${info.outputPageIds.length} 页及其识别/校对修改。此操作不可撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _applying = true);
    try {
      // 先把本书从识别队列摘除（中止在途页的识别写盘），再删文件。
      RecognitionQueue.instance.remove(project.id);
      final annDir = p.join(project.projectDir, 'annotations');
      for (final pageId in info.outputPageIds) {
        for (final suffix in ['.json', '.json.bak']) {
          final f = File(p.join(annDir, pageId + suffix));
          try {
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
      }
      if (info.outputDir.isNotEmpty &&
          p.isWithin(project.projectDir, info.outputDir)) {
        final dir = Directory(info.outputDir);
        if (await dir.exists()) await dir.delete(recursive: true);
      }
      for (final pageId in info.outputPageIds) {
        FileImage(
          File(
            p.join(info.outputDir, '$pageId.png'),
          ),
        ).evict();
      }
      project.imageFiles = List.of(info.sourceFiles);
      project.splitInfo = null;
      project.lastPageIndex = project.lastPageIndex.clamp(
        0,
        math.max(0, project.imageFiles.length - 1),
      );
      // 文字汇总账本对账：输出页账目撤账（页面与标注已删）；源页标注
      // 文件拆分期间未被触碰，按盘上标注重建源页账目（拆分落定时撤过）。
      await CharStatsService.reconcileProject(
        project.projectDir,
        project.imageFiles,
      );
      for (var i = 0; i < project.imageFiles.length; i++) {
        await CharStatsService.syncPageFromDisk(
          project.projectDir,
          project.imageFiles[i],
          i,
        );
      }
      final recognized = await ProjectStorage.savedAnnotationIndices(
        project.projectDir,
        project.imageFiles.length,
        imageFiles: project.imageFiles,
      );
      project.recognizedPages = recognized.length;
      project.recognitionStatus = RecognitionStatus.completed;
      await ProjectStorage.save(project);
      PythonService.addAppLog(
        '[跨页拆分] 已恢复拆分前：${project.imageFiles.length} 张跨页页面',
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('恢复失败：$error')),
      );
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  // ── build ──

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('跨页拆分 · ${widget.project.name}'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(96),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Text('窗口起始页'),
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline),
                      tooltip: '前一页',
                      onPressed: _composing || _windowStart <= 0
                          ? null
                          : () => _setWindowStart(_windowStart - 1),
                    ),
                    Text('${_windowStart + 1}'),
                    IconButton(
                      icon: const Icon(Icons.add_circle_outline),
                      tooltip: '后一页',
                      onPressed: _composing || _windowStart >= _sourceCount - 1
                          ? null
                          : () => _setWindowStart(_windowStart + 1),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Row(
                        children: [
                          Text(
                            '叠加 ${math.max(0, _windowEnd - _windowStart)} / '
                            '$_sourceCount 页',
                          ),
                          Expanded(
                            child: Slider(
                              value: _windowSize
                                  .clamp(4, _windowSliderMax)
                                  .toDouble(),
                              min: 4,
                              max: _windowSliderMax.toDouble(),
                              divisions: _windowSliderMax > 4
                                  ? _windowSliderMax - 4
                                  : null,
                              label: '$_windowSize',
                              onChanged: _composing
                                  ? null
                                  : (v) => setState(
                                      () => _windowSize = v.round().clamp(
                                        4,
                                        _windowSliderMax,
                                      ),
                                    ),
                              onChangeEnd: _composing
                                  ? null
                                  : (_) => _setWindowSize(_windowSize),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Row(
                        children: [
                          const Text('透明度'),
                          Expanded(
                            child: Slider(
                              value: _pageAlpha,
                              min: 0.02,
                              max: 1.0,
                              label: _pageAlpha.toStringAsFixed(2),
                              onChanged: _composing
                                  ? null
                                  : (v) =>
                                      setState(() => _pageAlpha = v.toDouble()),
                              onChangeEnd: _composing
                                  ? null
                                  : (_) => _recompose(),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const Text(
                  '拖动橙色中缝线（点击画布任意位置也可跳线）· 右键拖动平移 · '
                  '滚轮缩放 · 各页半透明叠加，贯穿全书的黑色竖带即中缝',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
        ),
      ),
      body: _buildBody(),
      bottomNavigationBar: _buildBottomBar(),
    );
  }

  Widget _buildBody() {
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewportSize = constraints.biggest;
        if (_composing && _composite == null) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 12),
                Text('正在合成叠加图 $_composeDone / $_windowSize 页 …'),
              ],
            ),
          );
        }
        final canvasH = _canvasH <= 0 ? _canvasW * 1.4 : _canvasH;
        return Stack(
          children: [
            Positioned.fill(
              child: Listener(
                // 右键拖动平移（编辑器同款习惯），左键留给中缝线。
                onPointerDown: (e) {
                  if (e.buttons == kSecondaryButton) _panAnchor = e.position;
                },
                onPointerMove: (e) {
                  if (e.buttons == kSecondaryButton && _panAnchor != null) {
                    _panBy(e.position - _panAnchor!);
                    _panAnchor = e.position;
                  }
                },
                onPointerUp: (_) => _panAnchor = null,
                onPointerCancel: (_) => _panAnchor = null,
                child: InteractiveViewer(
                  transformationController: _transform,
                  constrained: false,
                  panEnabled: false,
                  minScale: 0.05,
                  maxScale: 8,
                  boundaryMargin: const EdgeInsets.all(double.infinity),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: _onPanStart,
                    onPanUpdate: _onPanUpdate,
                    onPanEnd: _onPanEnd,
                    child: SizedBox(
                      width: _canvasW,
                      height: canvasH,
                      child: CustomPaint(
                        painter: _SplitPainter(
                          composite: _composite,
                          pageFit: _pageFit,
                          spineX: _spineCanvasX,
                          order: _order,
                          viewScale: _viewScale,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (!_composing && _sourceCount == 0)
              const Center(
                child: Card(
                  color: Colors.black87,
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: Text(
                      '本书没有页面，无法拆分。',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildBottomBar() {
    final isResplit = _isResplit;
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isResplit)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '本书已拆分过：叠加与拆分基于拆分前的原始页面'
                      '（重拆覆盖现有拆分页上的修改）。',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.orange.shade900,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _applying ? null : _restoreSplit,
                    icon: const Icon(Icons.undo, size: 16),
                    label: const Text('恢复拆分前'),
                  ),
                ],
              ),
            ),
          if (_missingSources)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _isResplit
                    ? '拆分前的原始页面文件有缺失（可能被手动清理），'
                        '无法叠加与重拆；请恢复文件或重新导入本书。'
                    : '部分页面图片文件缺失（可能被移动或删除），无法拆分。',
                style: TextStyle(fontSize: 12, color: Colors.red.shade700),
              ),
            ),
          Row(
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'left_first',
                    label: Text('先左后右'),
                    tooltip: '每张跨页左半页排在前（现代图书）',
                  ),
                  ButtonSegment(
                    value: 'right_first',
                    label: Text('先右后左'),
                    tooltip: '每张跨页右半页排在前（古籍竖排从右往左读）',
                  ),
                ],
                selected: {_order},
                onSelectionChanged: _applying
                    ? null
                    : (s) => setState(() => _order = s.first),
              ),
              const SizedBox(width: 12),
              Text(
                '中缝 ${(_spineRatio * 100).toStringAsFixed(1)}%',
                style: const TextStyle(
                  fontSize: 13,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.keyboard_double_arrow_left, size: 18),
                tooltip: '左移 10px',
                onPressed: _applying ? null : () => _nudgeSpine(-10),
              ),
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_left, size: 18),
                tooltip: '左移 1px',
                onPressed: _applying ? null : () => _nudgeSpine(-1),
              ),
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_right, size: 18),
                tooltip: '右移 1px',
                onPressed: _applying ? null : () => _nudgeSpine(1),
              ),
              IconButton(
                icon: const Icon(Icons.keyboard_double_arrow_right, size: 18),
                tooltip: '右移 10px',
                onPressed: _applying ? null : () => _nudgeSpine(10),
              ),
              const Spacer(),
              OutlinedButton(
                onPressed: _composing ? null : _recompose,
                child: const Text('重新合成'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: (_applying ||
                    _composing ||
                    _sourceCount == 0 ||
                    _missingSources)
                    ? null
                    : _showApplyDialog,
                icon: const Icon(Icons.splitscreen),
                label: const Text('拆分并应用'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _setWindowStart(int value) {
    final clamped = value
        .clamp(0, math.max(0, _sourceCount - 1))
        .toInt();
    setState(() => _windowStart = clamped);
    _recompose();
  }

  void _setWindowSize(int value) {
    final clamped = value.clamp(4, _windowSliderMax);
    setState(() {
      _windowSize = clamped;
      _pageAlpha = (1 / clamped).clamp(0.02, 1.0);
    });
    _recompose();
  }
}

/// 拆分画布画笔：合成底图 + 中缝线（含拖动握把与两侧页序标注）。
class _SplitPainter extends CustomPainter {
  _SplitPainter({
    required this.composite,
    required this.pageFit,
    required this.spineX,
    required this.order,
    required this.viewScale,
  });

  final ui.Image? composite;
  final Rect? pageFit;
  final double spineX;
  final String order;
  final double viewScale;

  @override
  void paint(Canvas canvas, Size size) {
    final img = composite;
    if (img != null) {
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        Offset.zero & size,
        Paint()..filterQuality = FilterQuality.low,
      );
    } else {
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = const Color(0xFF181818),
      );
    }
    final unit = 1.0 / math.max(viewScale, 0.001);

    // 中缝线（全高）+ 握把。
    final linePaint = Paint()
      ..color = Colors.orange
      ..strokeWidth = 2 * unit;
    canvas.drawLine(Offset(spineX, 0), Offset(spineX, size.height), linePaint);
    final grip = Offset(spineX, size.height / 2);
    canvas.drawCircle(grip, 12 * unit, Paint()..color = Colors.orange);
    canvas.drawCircle(
      grip,
      12 * unit,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 * unit
        ..color = Colors.white,
    );
    final arrow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * unit
      ..color = Colors.white;
    canvas.drawLine(
      grip.translate(-6 * unit, 0),
      grip.translate(-2 * unit, 0),
      arrow,
    );
    canvas.drawLine(
      grip.translate(2 * unit, 0),
      grip.translate(6 * unit, 0),
      arrow,
    );

    // 两侧页序标注：第 1 页在先读的一侧。
    final fit = pageFit;
    if (fit == null || fit.width <= 0) return;
    final firstLeft = order == 'left_first';
    _drawSideLabel(
      canvas,
      '第 1 页（${firstLeft ? "左" : "右"}）',
      firstLeft ? fit.left : fit.right,
      fit.top,
      firstLeft,
      unit,
      size.width,
    );
    _drawSideLabel(
      canvas,
      '第 2 页（${firstLeft ? "右" : "左"}）',
      firstLeft ? fit.right : fit.left,
      fit.top + 34 * unit,
      !firstLeft,
      unit,
      size.width,
    );
  }

  void _drawSideLabel(
    Canvas canvas,
    String text,
    double edgeX,
    double topY,
    bool alignRight,
    double unit,
    double canvasWidth,
  ) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: 13 * unit, color: Colors.white),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final left =
        (alignRight ? edgeX - tp.width - 10 * unit : edgeX + 10 * unit).clamp(
          0.0,
          math.max(0.0, canvasWidth - tp.width - 12 * unit),
        ).toDouble();
    final rect = Rect.fromLTWH(
      left,
      topY,
      tp.width + 12 * unit,
      tp.height + 6 * unit,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(4 * unit)),
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );
    tp.paint(canvas, Offset(left + 6 * unit, topY + 3 * unit));
  }

  @override
  bool shouldRepaint(_SplitPainter old) =>
      old.composite != composite ||
      old.pageFit != pageFit ||
      old.spineX != spineX ||
      old.order != order ||
      old.viewScale != viewScale;
}
