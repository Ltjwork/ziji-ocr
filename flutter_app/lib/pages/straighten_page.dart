import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../models/page_quad.dart';
import '../services/image_probe.dart';
import '../services/mouse_gesture.dart';
import '../services/python_service.dart';
import 'stitch_dialog.dart';

/// 校对摆正（仿白描）：大图上 8 个可拖拽裁切点（4 角 + 4 边中点），
/// 深色遮罩 + 白色裁切框 + 网格参考线 + 拖拽放大镜；边中点沿边法线
/// 拖动使该边弯曲，用于摊平装订弯曲的书页。
///
/// - 进入时自动调后端 /detect_page_quad 智能检测初始裁切点；
/// - 旋转按钮就地旋转源图（/transform_page）并同步换算点位，取消时
///   自动转回，保证取消零副作用；
/// - 去透印/去色/锐化为输出选项（后端处理），「预览」以 preview 模式回传
///   base64 小图先看效果；
/// - 确认调 /dewarp_page 写入 [outPath]（保留原图），pop(实际应用的
///   PageQuad)；取消 pop(null)；
/// - 滚轮缩放视图（指针为锚点），Ctrl+滚轮按当前形状整体缩放裁切框；
/// - 中键手势（映射可在手势设置页配置）：画整圈旋转页面（圈向即旋向），
///   L 形（←↓）确认并下一页；
/// - 会话模式（[host] 非 null）可多页拼接：与书内另一页智能拼成一页
///   （[StitchDialog]），拼接结果覆写本页矫正图、拼入页删除。
/// 会话模式下某一页的编辑目标（批量摆正宿主提供）。
class StraightenPageTarget {
  final String imagePath;
  final String outPath;
  final PageQuad? initialQuad;
  final int pageIndex; // 显示用（第 N 页）
  final bool confirmed;

  const StraightenPageTarget({
    required this.imagePath,
    required this.outPath,
    this.initialQuad,
    required this.pageIndex,
    this.confirmed = false,
  });
}

/// 会话宿主：批量摆正页实现。提供确认/删除的记账与下一页目标，
/// StraightenPage 据此支持"确认后自动翻到下一页"的连续编辑。
abstract class StraightenPageHost {
  /// 当前页的矫正文件已写出（[quad] 为实际应用的框）：宿主记账
  /// （确认标记、状态持久化、缩略图作废）。
  void applyCurrent(
    StraightenPageTarget page,
    PageQuad quad, {
    required bool grayscale,
    required bool sharpen,
    required bool debleed,
    required int debleedStrength,
    required bool confirmed,
  });

  /// 永久删除当前页（宿主删除图片/矫正图/标注并更新页面列表）。
  Future<void> deleteCurrent(StraightenPageTarget page);

  /// 下一页的编辑目标（没有下一页返回 null，编辑器随后关闭）。
  StraightenPageTarget? nextPageAfter(StraightenPageTarget page);

  /// 多页拼接入口：拼入页候选（书序中除当前页外的页，供拼接面板选择；
  /// 空列表 = 本书只有一页，不可拼）。
  List<StraightenPageTarget> stitchPartners(StraightenPageTarget page);

  /// 拼接落账：[stitchedPath]（= 当前页矫正图路径）已由后端写盘覆写，
  /// 宿主把当前页记为"已确认的合成页"（后续修改直接编辑合成图）并删除
  /// 拼入页，返回继续编辑的下一页目标（没有则 null，编辑器随后关闭）。
  /// 拼入页正在后台处理等不可拼状态抛 [StateError]（调用方提示用户）。
  Future<StraightenPageTarget?> mergePages(
    StraightenPageTarget current,
    StraightenPageTarget partner, {
    required String stitchedPath,
  });
}

class StraightenPage extends StatefulWidget {
  const StraightenPage({
    super.key,
    required this.imagePath,
    required this.outPath,
    this.initialQuad,
    this.initialGrayscale = false,
    this.initialSharpen = false,
    this.initialDebleed = false,
    this.initialDebleedStrength = 50,
    this.title,
    this.pageIndex = 0,
    this.initialConfirmed = false,
    this.host,
  });

  /// 要摆正的源图路径（批量重做时为 sources 里的原图）。
  final String imagePath;

  /// 摆正结果输出路径（warped/ 下；保留原图不改写）。
  final String outPath;

  /// 检测日志的一行摘要（应用日志用；批量页与单页共用）。
  static String traceSummary(Map<String, dynamic> trace) {
    final ink = trace['ink'] as Map<String, dynamic>?;
    final residual = trace['residual_after_paper_deg'];
    final decision = trace['decision'] as String? ?? '';
    final dark = trace['source_dark_region'] as Map<String, dynamic>?;
    final bits = <String>[
      if (ink != null && ink['available'] == true)
        '墨迹覆盖 ${(((ink['coverage'] as num?) ?? 0) * 100).toStringAsFixed(1)}%'
            '·${ink['orientation'] == 'columns' ? '竖排' : '横排'}'
            '·主方向 ${(ink['align_angle_deg'] as num?) ?? 0}°',
      if (residual != null) '纸边拉正残余 ${(residual as num).abs()}°',
      if (dark != null)
        '暗块占 ${(((dark['share'] as num?) ?? 0) * 100).toStringAsFixed(0)}%',
    ];
    return '${bits.join('，')} → $decision';
  }

  /// 初始裁切四边形（源图坐标系）；null = 进入后自动检测。
  final PageQuad? initialQuad;

  final bool initialGrayscale;
  final bool initialSharpen;

  /// 去透印（把背面/下一页透出的浅色文字压成纸白）及强度 1..100。
  final bool initialDebleed;
  final int initialDebleedStrength;
  final String? title;

  /// 显示用页号（第 N 页）。
  final int pageIndex;

  /// 该页是否已确认（会话模式显示用）。
  final bool initialConfirmed;

  /// 会话宿主（批量摆正页）：非 null 时启用确认/删除/自动翻页与右侧
  /// 常驻预览；null 为独立模式（编辑器入口，行为不变）。
  final StraightenPageHost? host;

  @override
  State<StraightenPage> createState() => _StraightenPageState();
}

class _StraightenPageState extends State<StraightenPage> {
  static const int _decodeWidth = 1600;

  ui.Image? _image; // 降采样解码并随旋转预旋转的显示图
  double _imgScale = 1; // 显示图宽 / 当前文件宽
  int _fullW = 0; // 当前文件（=编辑视图）全分辨率宽高
  int _fullH = 0;
  PageQuad? _quad; // 裁切四边形（视图坐标系 = 当前文件坐标系）
  String _detectMethod = '';
  bool _needsWarp = true;

  /// 检测决策诊断（后端 trace）：智能边框怎样确定的，供「检测日志」
  /// 弹窗展示，帮助判断该页是否需要手动调整。
  Map<String, dynamic>? _detectTrace;

  bool _loadingImage = true;
  bool _detecting = false;
  bool _applying = false;
  bool _rotatingBusy = false;
  String? _error;

  // 当前编辑页（会话模式下随"确认并下一页/删除"切换）
  late String _path;
  late String _outPath;
  late String _title;
  late int _pageIndex;
  bool _confirmed = false;
  PageQuad? _pendingInitialQuad;

  // 右侧常驻预览面板
  Uint8List? _previewBytes; // 非空 = 显示"按当前框刷新"的预览
  bool _previewLoading = false;
  bool _previewShowOriginal = false;
  Timer? _previewDebounce; // 预览自动刷新防抖（拖拽停止后自动出图）
  int _previewSeq = 0; // 预览请求代数（丢弃过期响应）
  double _previewWidth = 380; // 预览面板宽度（分隔条可拖）

  // 交互状态
  int _dragHandle = -1; // 0..3 角点 TL,TR,BR,BL；4..7 边中点 top,right,bottom,left
  Offset? _dragStartPointer; // 按下瞬间指针位置（边拖=整体平移的基准）
  List<Offset>? _dragStartCorners; // 按下瞬间的四角快照（边拖的位移基准）
  bool _showGrid = true;
  bool _grayscale = false;
  bool _sharpen = false;
  bool _debleed = false;
  int _debleedStrength = 50;
  int _netTurns = 0; // 会话期间就地旋转的净 90° 步数（CW 正，0..3）

  final TransformationController _transform = TransformationController();
  Offset? _panAnchor;
  Size? _viewportSize;
  bool _fitScheduled = false; // 本帧已排入 fit（防重复排）

  bool get _busy =>
      _loadingImage || _detecting || _applying || _rotatingBusy;

  Size get _viewSize => Size(_fullW.toDouble(), _fullH.toDouble());

  @override
  void initState() {
    super.initState();
    _path = widget.imagePath;
    _outPath = widget.outPath;
    _pageIndex = widget.pageIndex;
    _confirmed = widget.initialConfirmed;
    _pendingInitialQuad = widget.initialQuad;
    _title = widget.title ?? '校对摆正 · ${p.basename(widget.imagePath)}';
    _grayscale = widget.initialGrayscale;
    _sharpen = widget.initialSharpen;
    _debleed = widget.initialDebleed;
    _debleedStrength = widget.initialDebleedStrength;
    // 鼠标中键手势配置：进页加载一次缓存，松手判定时直接查内存。
    GestureSettings.load().then((s) {
      if (mounted) _gestureSettings = s;
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _previewDebounce?.cancel();
    _image?.dispose();
    _transform.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loadingImage = true);
    Object? decodeError;
    final size = await probeImageSize(_path);
    final img = await _decode(_path, _decodeWidth, onError: (e) => decodeError = e);
    if (!mounted) {
      img?.dispose();
      return;
    }
    if (img == null || size == null) {
      img?.dispose(); // 错误路径不持有位图（_image 未赋值，防泄漏）
      setState(() {
        _loadingImage = false;
        _error =
            '无法读取图片：$_path'
            '${decodeError ?? (size == null ? '（尺寸探测失败）' : '')}';
      });
      return;
    }
    _image = img;
    _fullW = size.width.round();
    _fullH = size.height.round();
    _imgScale = img.width / _fullW;
    PythonService.addAppLog(
      '[校对摆正] 已载入 ${p.basename(_path)} '
      '全图 ${_fullW}x$_fullH（显示 ${img.width}x${img.height}）',
    );
    // 图片就位后的视图适配由 body 的 LayoutBuilder 帧末统一处理。
    if (_pendingInitialQuad != null) {
      _quad = _pendingInitialQuad;
      setState(() => _loadingImage = false);
      return;
    }
    setState(() => _loadingImage = false);
    _schedulePreviewRefresh();
    unawaited(_detect());
  }

  Future<ui.Image?> _decode(
    String path,
    int targetWidth, {
    void Function(Object error)? onError,
  }) async {
    try {
      final data = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(
        data,
        targetWidth: targetWidth,
      );
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (e) {
      onError?.call(e);
      return null;
    }
  }

  // ── 智能检测 ──

  Future<void> _detect() async {
    if (_detecting) return;
    setState(() {
      _detecting = true;
      _error = null;
    });
    try {
      final r = await PythonService.detectPageQuad(imagePath: _path);
      if (!mounted) return;
      final points = (r['points'] as List)
          .map(
            (pt) => List<double>.from(
              (pt as List).map((e) => (e as num).toDouble()),
            ),
          )
          .toList();
      setState(() {
        // 检测结果就是当前文件坐标（旋转已就地落到盘上），直接使用。
        _quad = PageQuad.fromPoints(points);
        _detectMethod = (r['method'] as String?) ?? '';
        _needsWarp = r['needs_warp'] != false;
        _detectTrace = r['trace'] as Map<String, dynamic>?;
      });
      _schedulePreviewRefresh();
      // 每页一条检测日志落应用日志：这页的智能边框是怎样判定的。
      final trace = r['trace'] as Map<String, dynamic>?;
      if (trace != null) {
        PythonService.addAppLog(
          '[校对摆正·检测] ${p.basename(_path)}：'
          '${StraightenPage.traceSummary(trace)}',
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _detectMethod = 'default';
        _quad ??= PageQuad.defaultInset(_viewSize);
        _error = '自动检测失败：$e（已用全图框，可手动调整）';
      });
    } finally {
      if (mounted) setState(() => _detecting = false);
    }
  }

  /// 「检测日志」弹窗：展示本页智能边框的判定依据。文本可划选复制，
  /// 也提供一键复制全文（发日志调参用）。
  Future<void> _showDetectTrace() async {
    final trace = _detectTrace;
    if (trace == null) return;
    final rows = <(String, String)>[
      (
        '检测方式',
        switch (_detectMethod) {
          'ink' => '按墨迹行列对齐',
          'contour' => '按纸边轮廓',
          _ => '无有效信号（内缩全图）',
        },
      ),
      ..._traceRows(trace),
    ];
    final plainText = [
      '检测日志 · ${p.basename(_path)}',
      for (final (label, value) in rows) '$label：$value',
    ].join('\n');
    var copied = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('检测日志'),
          content: SizedBox(
            width: 520,
            // SelectionArea：鼠标划选任意段落复制。
            child: SelectionArea(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final (label, value) in rows)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 120,
                              child: Text(
                                label,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                value,
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ),
                    const Divider(height: 20),
                    Text(
                      '判定依据不足或结果不理想时，可拖动橙框角点/边中点手动修正'
                      '（拖边时按住 Shift 可沿垂直于该边的方向平移），'
                      '或点「重新智能检测」再试一次。',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: plainText));
                setDialogState(() => copied = true);
              },
              icon: const Icon(Icons.copy, size: 16),
              label: Text(copied ? '已复制' : '复制全部'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }

  /// trace dict → 展示行（标签, 值）。
  static List<(String, String)> _traceRows(Map<String, dynamic> trace) {
    final ink = trace['ink'] as Map<String, dynamic>?;
    final paper = trace['paper'] as Map<String, dynamic>?;
    final residual = trace['residual_after_paper_deg'] as num?;
    final threshold = trace['threshold_deg'] as num? ?? 1.2;
    final dark = trace['source_dark_region'] as Map<String, dynamic>?;
    final bbox = dark?['bbox'] is List
        ? (dark!['bbox'] as List).map((e) => (e as num).toInt()).toList()
        : null;
    return [
      if (ink != null && ink['available'] == true) ...[
        (
          '墨迹覆盖率',
          '${(((ink['coverage'] as num?) ?? 0) * 100).toStringAsFixed(1)}%',
        ),
        (
          '文字方向',
          (ink['orientation'] == 'columns' ? '竖排（列）' : '横排（行）'),
        ),
        (
          '墨迹主方向角',
          '${(ink['align_angle_deg'] as num?) ?? 0}°',
        ),
        (
          '倾斜置信比',
          '${(ink['confidence'] as num?) ?? 1}（≈1 说明本来就把得正）',
        ),
        (
          '墨迹框面积占比',
          '${(((ink['quad_area_ratio'] as num?) ?? 0) * 100).toStringAsFixed(1)}%',
        ),
        if (ink['deep_expanded'] == true)
          (
            '深墨扩展',
            '是——框外有深色结构（书缘/边框），已并入裁切框',
          ),
        if (ink['mask_stats'] is Map) ...[
          (
            '墨迹保留率',
            '${(((ink['mask_stats']['retention'] as num?) ?? 1) * 100).toStringAsFixed(0)}%'
                '（有效/敏感墨迹）',
          ),
          (
            '剔除渍块',
            '${ink['mask_stats']['stains_dropped'] ?? 0} 块'
                '（${ink['mask_stats']['stain_px_dropped'] ?? 0} px，大而实心无论深浅）',
          ),
          if (ink['mask_stats']['fallback_sensitive'] == true)
            ('整页淡墨', '强墨过少，已回退敏感档定框（不丢内容）'),
        ],
      ] else
        ('墨迹分析', '无有效墨迹信号（空页/插图页/反差不足）'),
      if (paper != null && paper['available'] == true) ...[
        (
          '纸边面积占比',
          '${(((paper['area_ratio'] as num?) ?? 0) * 100).toStringAsFixed(1)}%',
        ),
        (
          '纸边填充率',
          '${(((paper['fill_ratio'] as num?) ?? 0) * 100).toStringAsFixed(1)}%'
              '（枝杈状色块会被过滤）',
        ),
        (
          '纸边倾角',
          '${(paper['quad_tilt_deg'] as num?) ?? 0}°',
        ),
        if (paper['full_frame'] == true)
          ('纸边信号', '≈整图四角：页边与背景无反差（贴满全图）'),
      ] else
        ('纸边分析', '未检测到纸边信号'),
      if (dark != null) ...[
        (
          '源图暗色块',
          '占图幅 ${(((dark['share'] as num?) ?? 0) * 100).toStringAsFixed(1)}%'
              '（均亮 ${(dark['luma'] as num? ?? 0).toStringAsFixed(0)}）'
              '——若 PDF/原稿没有黑边黑底，请检查导入来源',
        ),
        if (bbox != null)
          (
            '暗色块位置',
            'x=${bbox[0]}, y=${bbox[1]}，宽 ${bbox[2]} × 高 ${bbox[3]}（源图像素）',
          ),
      ],
      (
        '一致性判据',
        residual == null
            ? '墨迹不足，未校验'
            : '按纸边拉正后墨迹残余 ${residual.abs()}°'
                '（阈值 $threshold°，超过则改按墨迹对齐）',
      ),
      ('扫描参数', '±${trace['scan_range_deg']}°，步进 ${trace['scan_step_deg']}°'),
      ('判定', trace['decision'] as String? ?? ''),
    ];
  }

  // ── 旋转（就地 + 点位换算，取消时回退） ──

  Future<void> _rotate(bool cw) async {
    if (_rotatingBusy || _image == null) return;
    final quad = _quad;
    setState(() => _rotatingBusy = true);
    try {
      // 与编辑器旋转按钮同一后端：就地改写文件，返回新尺寸。盘已转向后
      // 立即记账 _netTurns 并失效文件缓存——后续显示步骤若失败，取消
      // 回退仍与盘一致（少记一步 = 取消后文件留在旋转方向）。
      await PythonService.transformPage(
        imagePath: _path,
        op: cw ? 'rotate_cw' : 'rotate_ccw',
      );
      _netTurns = (_netTurns + (cw ? 1 : 3)) % 4;
      FileImage(File(_path)).evict(); // 「原图」页签立即反映新方向
      final rotated = await rotateImageMemory(_image!, cw);
      if (!mounted) {
        rotated.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = rotated;
        if (quad != null) {
          // 点位随像素同步旋转（先记录旧宽高）。
          final oldW = _fullW, oldH = _fullH;
          _quad = cw
              ? quad.rotatedCW(oldW, oldH)
              : quad.rotatedCCW(oldW, oldH);
        }
        // 90° 旋转两个方向都宽高互换（后端 cv2.rotate 同口径）。
        final t = _fullW;
        _fullW = _fullH;
        _fullH = t;
        _fitView();
      });
      _schedulePreviewRefresh(); // 框已随旋转换算，右侧预览同步跟进
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('旋转失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _rotatingBusy = false);
    }
  }

  /// 取消时把会话内旋转转回去：文件与显示都回到进入前的方向。
  Future<void> _undoTurns() async {
    while (_netTurns != 0) {
      final cw = _netTurns == 3; // 净 270°CW = 转 90°CCW 回退最快
      await PythonService.transformPage(
        imagePath: _path,
        op: cw ? 'rotate_cw' : 'rotate_ccw',
      );
      _netTurns = (_netTurns + (cw ? 1 : 3)) % 4;
    }
    FileImage(File(_path)).evict();
  }

  // ── 鼠标中键手势（整窗口感应，画布/预览面板/底栏上拖动均识别——
  // Flutter 拖动识别器只认左键，中键不会误触发裁切点拖拽/分隔条）──
  final MouseGestureTracker _gestureTracker = MouseGestureTracker();
  GestureSettings _gestureSettings = const GestureSettings();
  bool _gestureActive = false;

  void _onGestureDown(PointerEvent e) {
    if (!_gestureSettings.enabled) return;
    _gestureTracker.start(e.position); // 全局坐标 = 页面顶层 Stack 原点
    setState(() => _gestureActive = true);
  }

  void _onGestureMove(PointerEvent e) {
    _gestureTracker.extend(e.position);
    setState(() {}); // 只重画轨迹层
  }

  void _onGestureUp() {
    final seq = _gestureTracker.finish();
    setState(() => _gestureActive = false);
    if (seq == null) return; // 位移太小：视为中键点击，不触发
    final action = _gestureSettings.straighten[seq];
    if (action != null) _runStraightenGestureAction(action);
  }

  /// 手势动作分发（动作 id 见 [GestureCatalog.straightenActions]）。
  /// 各动作自带忙态守卫（_rotate 查 _rotatingBusy，_confirm 查 _busy
  /// 与裁切框合法性），载页/应用中乱画不会触发半成品操作。
  void _runStraightenGestureAction(String id) {
    switch (id) {
      case 'rotateCw':
        unawaited(_rotate(true));
      case 'rotateCcw':
        unawaited(_rotate(false));
      case 'confirmNext':
        // 独立模式没有"下一页"：确认即退出，与底栏「确认摆正」同链路。
        unawaited(_confirmAndNext());
    }
  }

  // ── 画布交互 ──

  /// 画布 → 逻辑屏幕的缩放。必须取 x/y 轴（matrixXyScale）：
  /// getMaxScaleOnAxis 会把恒为 1 的 z 轴当最大值，永远返回 1.0，
  /// 屏幕尺寸补偿与命中换算全部失效（高分辨率页面上拖拽点缩没）。
  double get _viewScale => matrixXyScale(_transform.value);

  /// 视图缩放上下限（与画布 InteractiveViewer 的 minScale/maxScale 同值；
  /// 滚轮缩放由本页自实现，见 [_onPointerSignal]）。
  static const double _minViewScale = 0.05;
  static const double _maxViewScale = 8;

  /// 滚轮事件分流：普通滚轮缩放视图（指针为锚点），Ctrl+滚轮按当前
  /// 形状整体缩放裁切框（绕质心等比，方向：上=放大）。
  ///
  /// InteractiveViewer 的滚轮处理在监听器里直接改矩阵、不进仲裁器，
  /// 外层无法拦截——因此画布 IV 关闭内置缩放手势（scaleEnabled:false），
  /// 滚轮全部由本页处理；普通滚轮复刻 IV 的"指针下场景点不动"缩放，
  /// 行为与之前一致（exp(-dy/200)，即 IV 默认 scaleFactor）。
  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent || e.scrollDelta.dy == 0) return;
    if (HardwareKeyboard.instance.isControlPressed) {
      // 每像素位移 0.05%：一格滚轮（±120）≈ ±6%——刻意压到微调档
      //（用户反馈 15.5%/格 太猛），要大幅缩放多滚几格；触控板小步平滑。
      _scaleQuadBy(math.pow(1.0005, -e.scrollDelta.dy).toDouble());
    } else {
      _zoomViewAt(e.localPosition, math.exp(-e.scrollDelta.dy / 200));
    }
  }

  /// 以 [viewportPos]（画布视口坐标）为锚点缩放视图：缩放前后指针指向
  /// 同一场景点，超限（0.05~8）钳到边界。
  void _zoomViewAt(Offset viewportPos, double factor) {
    final m = _transform.value;
    final s = matrixXyScale(m);
    final f = (s * factor).clamp(_minViewScale, _maxViewScale) / s;
    if ((f - 1.0).abs() < 1e-9) return;
    final t = m.getTranslation();
    // 场景点（图像坐标）在缩放后应仍落在指针处：矩阵是 T·S 形式，
    // scale 后平移分量不变、场景坐标 ×f，补一笔屏幕系平移把指针拉回。
    final mapped = Offset(
      f * (viewportPos.dx - t.x) + t.x,
      f * (viewportPos.dy - t.y) + t.y,
    );
    final correction = viewportPos - mapped;
    _transform.value = Matrix4.translationValues(
      correction.dx,
      correction.dy,
      0,
    ).multiplied(Matrix4.copy(m)..scaleByDouble(f, f, 1, 1));
  }

  /// 整体缩放裁切框（Ctrl+滚轮）：绕质心等比缩放，形状严格不变。
  /// 放大受图像边界约束（按各角点方向算出本趟允许的最大系数，到边即止，
  /// 不做破坏形状的逐点钳制）；缩小保底角点距质心 ≥12px（防缩成一点）。
  void _scaleQuadBy(double factor) {
    final quad = _quad;
    if (quad == null || _loadingImage) return;
    final c = quad.centroid;
    var f = factor;
    if (f > 1) {
      for (final o in quad.corners) {
        final d = o - c;
        if (d.dx > 0) {
          f = math.min(f, (_fullW - 1 - c.dx) / d.dx);
        } else if (d.dx < 0) {
          f = math.min(f, -c.dx / d.dx);
        }
        if (d.dy > 0) {
          f = math.min(f, (_fullH - 1 - c.dy) / d.dy);
        } else if (d.dy < 0) {
          f = math.min(f, -c.dy / d.dy);
        }
      }
      f = math.max(1.0, f); // 本趟到边：不再放大（也不缩小）
    } else {
      var minDist = double.infinity;
      for (final o in quad.corners) {
        minDist = math.min(minDist, (o - c).distance);
      }
      if (minDist <= 12) return; // 已缩到最小：不再缩
      f = math.max(factor, 12 / minDist);
    }
    if ((f - 1.0).abs() < 1e-6) return;
    setState(() => _quad = quad.scaled(f));
    _schedulePreviewRefresh();
  }

  void _panBy(Offset screenDelta) {
    final m = _transform.value;
    _transform.value = Matrix4.translationValues(
      screenDelta.dx,
      screenDelta.dy,
      0,
    ).multiplied(m);
  }

  void _fitView() {
    final vp = _viewportSize;
    // 退化视口（高/宽 0，历史底栏 bug 的场景）不算适配，留给有效帧补。
    if (vp == null || vp.width <= 0 || vp.height <= 0 || _fullW <= 0) return;
    final scale =
        math.min(vp.width / _fullW, vp.height / _fullH) * 0.92;
    final tx = (vp.width - _fullW * scale) / 2;
    final ty = (vp.height - _fullH * scale) / 2;
    final m = Matrix4.translationValues(tx, ty, 0).multiplied(
      Matrix4.identity()..scaleByDouble(scale, scale, 1, 1),
    );
    _transform.value = m;
    PythonService.addAppLog(
      '[校对摆正] 视图适配：视口 ${vp.width.round()}x${vp.height.round()}，'
      'scale=${scale.toStringAsFixed(3)}',
    );
  }

  int _hitHandle(Offset canvasPos) {
    final quad = _quad;
    if (quad == null) return -1;
    // 命中优先级：角点 > 边中点 > 边线本体。半径按屏幕像素换算，缩放
    // 越小命中区（图像坐标）越大；半径刻意远大于视觉圆点（角点视觉
    // 半径 13px，命中 52px），抓取不需要精确对点。
    final cornerR = quadHitRadiusImage(_viewScale, screenPx: 100);
    var best = -1;
    var bestDist = double.infinity;
    for (var handle = 0; handle < 4; handle++) {
      final d = (canvasPos - quad.corners[handle]).distance;
      if (d <= cornerR && d < bestDist) {
        best = handle;
        bestDist = d;
      }
    }
    if (best >= 0) return best;
    final midR = quadHitRadiusImage(_viewScale, screenPx: 80);
    for (var edge = 0; edge < 4; edge++) {
      final d = (canvasPos - quad.edgeMid(edge)).distance;
      if (d <= midR && d < bestDist) {
        best = 4 + edge;
        bestDist = d;
      }
    }
    if (best >= 0) return best;
    // 边线抓取：鼠标落在任意边的线体附近（±14px 屏幕）即视为拖该边
    //（两个角一起动），不必精确点到边中点圆点。
    final lineR = quadHitRadiusImage(_viewScale, screenPx: 28);
    for (var edge = 0; edge < 4; edge++) {
      final pair = quad.edgeCorners(edge);
      if (_distanceToSegment(canvasPos, pair[0], pair[1]) <= lineR) {
        return 4 + edge;
      }
    }
    return best;
  }

  /// 点到线段的最短距离。
  double _distanceToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    if (len2 <= 0) return (p - a).distance;
    final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2)
        .clamp(0.0, 1.0);
    return (p - Offset(a.dx + ab.dx * t, a.dy + ab.dy * t)).distance;
  }

  void _onPanStart(DragStartDetails d) {
    var handle = _hitHandle(d.localPosition);
    if (handle < 0) {
      // 空白处按下也吸附到最近的控制点（左上角等难以命中的兜底）：
      // 4 个角里挑最近的，配合 100px 命中半径，画布上任意按下都能拖。
      final quad = _quad;
      if (quad == null) return;
      var best = -1;
      var bestDist = double.infinity;
      for (var i = 0; i < 4; i++) {
        final dd = (d.localPosition - quad.corners[i]).distance;
        if (dd < bestDist) {
          best = i;
          bestDist = dd;
        }
      }
      handle = best;
    }
    setState(() {
      _dragHandle = handle;
      _dragStartPointer = d.localPosition;
      _dragStartCorners = List<Offset>.of(_quad?.corners ?? const []);
    });
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final handle = _dragHandle;
    final quad = _quad;
    final startCorners = _dragStartCorners;
    if (handle < 0 || quad == null || startCorners == null) return;
    // 指针位置夹进图像范围（允许贴边，不允许拖出图外）。
    final clamped = Offset(
      d.localPosition.dx.clamp(0.0, _fullW.toDouble()),
      d.localPosition.dy.clamp(0.0, _fullH.toDouble()),
    );
    setState(() {
      if (handle < 4) {
        // 角点：自由移动，改变框形状。
        _quad = quad.withCorner(handle, clamped);
      } else {
        // 边中点：该边两个角点按位移共同平移（整条边跟随移动）；
        // 按住 Shift 时位移锁到该边法线方向（边只垂直于自身平移），
        // 拖动中途按/放 Shift 即时切换约束。
        _quad = quad.withEdgeDrag(
          handle - 4,
          _dragStartPointer ?? clamped,
          clamped,
          startCorners,
          lockToNormal: HardwareKeyboard.instance.isShiftPressed,
        );
      }
    });
    _schedulePreviewRefresh(); // 拖拽停止后自动刷新右侧预览
  }

  void _onPanEnd(DragEndDetails d) {
    if (_dragHandle >= 0) {
      setState(() {
        _dragHandle = -1;
        _dragStartPointer = null;
        _dragStartCorners = null;
      });
    }
  }

  // ── 预览 / 确认 / 取消 ──

  /// 预览自动刷新调度：框/增强设置任一变化后防抖触发（拖拽停止
  /// 约 0.5s 后自动出图，不用手动点刷新）。
  void _schedulePreviewRefresh() {
    if (_quad == null) return;
    _previewDebounce?.cancel();
    _previewDebounce = Timer(const Duration(milliseconds: 500), () {
      if (mounted) unawaited(_refreshPreview());
    });
  }

  /// 右侧常驻预览：按当前框与增强设置回传矫正效果图。
  /// 并发时按请求代数丢弃过期响应（拖拽连续触发只显示最新）。
  Future<void> _refreshPreview() async {
    final quad = _quad;
    if (quad == null) return;
    final gen = ++_previewSeq;
    setState(() => _previewLoading = true);
    try {
      final r = await PythonService.dewarpPage(
        imagePath: _path,
        corners: quad.cornersJson(),
        grayscale: _grayscale,
        sharpen: _sharpen,
        debleed: _debleed,
        debleedStrength: _debleedStrength,
        preview: true,
        previewMaxPx: 1200,
      );
      if (!mounted || gen != _previewSeq) return;
      final b64 = r['image_b64'] as String?;
      if (b64 == null) throw Exception('后端未返回预览图');
      setState(() {
        _previewBytes = base64Decode(b64);
        _previewShowOriginal = false;
      });
    } catch (e) {
      if (mounted && gen == _previewSeq) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('预览失败：$e')));
      }
    } finally {
      if (mounted && gen == _previewSeq) {
        setState(() => _previewLoading = false);
      }
    }
  }

  /// 画布与预览面板之间的拖拽分隔条：横向拖动调整预览窗占比。
  Widget _buildPreviewDivider() {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) {
          setState(() {
            _previewWidth = (_previewWidth - d.delta.dx).clamp(240.0, 720.0);
          });
        },
        child: Container(
          width: 8,
          color: const Color(0xFF262628),
          child: Center(
            child: Container(width: 2, color: const Color(0xFF48484A)),
          ),
        ),
      ),
    );
  }

  /// 右侧常驻预览面板：矫正图（按当前框刷新）与原图切换。
  Widget _buildPreviewPanel() {
    final hasApplied = File(_outPath).existsSync();
    final showOriginal = _previewShowOriginal;
    return Container(
      width: _previewWidth,
      color: const Color(0xFF1C1C1E),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
            child: Row(
              children: [
                const Text(
                  '矫正预览',
                  style: TextStyle(fontSize: 13, color: Colors.white70),
                ),
                const Spacer(),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(
                      value: false,
                      label: Text('矫正', style: TextStyle(fontSize: 11)),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text('原图', style: TextStyle(fontSize: 11)),
                    ),
                  ],
                  selected: {showOriginal},
                  onSelectionChanged: (s) =>
                      setState(() => _previewShowOriginal = s.first),
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  showSelectedIcon: false,
                ),
                const SizedBox(width: 6),
                IconButton(
                  icon: _previewLoading
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 18),
                  tooltip: '按当前裁切框刷新预览',
                  color: Colors.white70,
                  onPressed: _busy ? null : _refreshPreview,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: showOriginal
                ? InteractiveViewer(
                    maxScale: 6,
                    child: Image.file(File(_path), fit: BoxFit.contain),
                  )
                : _previewBytes != null
                    ? InteractiveViewer(
                        maxScale: 6,
                        child: Image.memory(
                          _previewBytes!,
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => const Center(
                            child: Text(
                              '预览图解码失败',
                              style: TextStyle(color: Colors.grey),
                            ),
                          ),
                        ),
                      )
                    : hasApplied
                        ? InteractiveViewer(
                            maxScale: 6,
                            child: Image.file(
                              File(_outPath),
                              fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) => const Center(
                                child: Text(
                                  '读取失败',
                                  style: TextStyle(color: Colors.grey),
                                ),
                              ),
                            ),
                          )
                        : const Center(
                            child: Text(
                              '调整裁切框后点 ↻ 查看矫正效果',
                              style: TextStyle(color: Colors.grey),
                              textAlign: TextAlign.center,
                            ),
                          ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              '预览为按当前框计算的缩略效果；确认后写出全分辨率矫正图。',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ),
        ],
      ),
    );
  }

  /// 应用当前框（写出矫正文件）。[advance] 为会话模式：写出后记账并
  /// 自动载入下一页（没有下一页则关闭编辑器）。
  Future<void> _confirm({bool advance = false}) async {
    final quad = _quad;
    if (quad == null || _busy || !quad.isSimple()) return;
    setState(() {
      _applying = true;
      _error = null;
    });
    try {
      await PythonService.dewarpPage(
        imagePath: _path,
        corners: quad.cornersJson(),
        grayscale: _grayscale,
        sharpen: _sharpen,
        debleed: _debleed,
        debleedStrength: _debleedStrength,
        outPath: _outPath,
      );
      FileImage(File(_outPath)).evict();
      FileImage(File(_path)).evict();
      PythonService.addAppLog(
        '[校对摆正] ${p.basename(_path)} → '
        '${p.basename(_outPath)}'
        '${_grayscale ? '（去色）' : ''}${_sharpen ? '（锐化）' : ''}'
        '${_debleed ? '（去透印$_debleedStrength）' : ''}',
      );
      if (!mounted) return;
      final host = widget.host;
      if (host != null && advance) {
        // 会话模式：记账（确认标记等）并翻到下一页。
        final current = StraightenPageTarget(
          imagePath: _path,
          outPath: _outPath,
          pageIndex: _pageIndex,
          confirmed: true,
        );
        host.applyCurrent(
          current,
          quad,
          grayscale: _grayscale,
          sharpen: _sharpen,
          debleed: _debleed,
          debleedStrength: _debleedStrength,
          confirmed: true,
        );
        final next = host.nextPageAfter(current);
        _previewBytes = null;
        if (next != null) {
          await _loadTarget(next);
          return;
        }
        // 没有下一页：关闭编辑器回网格。
        Navigator.of(context).pop(true);
        return;
      }
      // 独立模式：返回实际应用的框（调用方存为该页当前框）。
      Navigator.of(context).pop(quad);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '摆正失败：$e');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('摆正失败：$e')));
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  /// 会话模式：确认当前页并自动载入下一页。
  Future<void> _confirmAndNext() async {
    await _confirm(advance: true);
  }

  /// 会话模式：永久删除当前页（宿主删文件并更新页面列表），然后翻到
  /// 下一页（没有则关闭编辑器）。
  Future<void> _deleteCurrent() async {
    final host = widget.host;
    if (host == null || _busy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('永久删除本页？'),
        content: const Text(
          '将删除本页的页面图片、矫正图与识别标注，并从本书移除。'
          '此操作无法恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('永久删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final current = StraightenPageTarget(
      imagePath: _path,
      outPath: _outPath,
      pageIndex: _pageIndex,
      confirmed: _confirmed,
    );
    await host.deleteCurrent(current);
    if (!mounted) return;
    final next = host.nextPageAfter(current);
    _previewBytes = null;
    if (next != null) {
      await _loadTarget(next);
      return;
    }
    Navigator.of(context).pop(false);
  }

  /// 会话模式：多页拼接面板（[StitchDialog]）。确认后拼接结果覆写本页
  /// 矫正图、拼入页由宿主删除，编辑器翻到下一页（没有则关闭）。
  Future<void> _openStitch() async {
    final host = widget.host;
    if (host == null || _busy) return;
    final current = StraightenPageTarget(
      imagePath: _path,
      outPath: _outPath,
      pageIndex: _pageIndex,
      confirmed: _confirmed,
    );
    final partners = host.stitchPartners(current);
    if (partners.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('本书没有其它页可拼')),
      );
      return;
    }
    final result = await showDialog<StitchDialogResult>(
      context: context,
      builder: (_) => StitchDialog(
        currentImage: _path,
        currentOutPath: _outPath,
        currentIndex: _pageIndex,
        currentLabel: '第 ${_pageIndex + 1} 页',
        partners: partners,
        preferredPartnerIndex: _pageIndex + 1,
      ),
    );
    if (result == null || !mounted) return;
    try {
      final next = await host.mergePages(
        current,
        result.partner,
        stitchedPath: _outPath,
      );
      if (!mounted) return;
      FileImage(File(_outPath)).evict();
      _previewBytes = null;
      if (next != null) {
        await _loadTarget(next);
        return;
      }
      Navigator.of(context).pop(true);
    } on StateError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('拼接未完成：${e.message}')));
      }
    }
  }

  /// 会话模式：载入下一页目标（清当前页状态，重走载入链路）。
  Future<void> _loadTarget(StraightenPageTarget t) async {
    _image?.dispose();
    _image = null;
    setState(() {
      _path = t.imagePath;
      _outPath = t.outPath;
      _pageIndex = t.pageIndex;
      _confirmed = t.confirmed;
      _title = '校对摆正 · 第 ${t.pageIndex + 1} 页';
      _pendingInitialQuad = t.initialQuad;
      _quad = null;
      _detectMethod = '';
      _detectTrace = null;
      _needsWarp = true;
      _error = null;
      _netTurns = 0;
      _previewBytes = null;
      _previewShowOriginal = false;
      _loadingImage = true;
      _dragHandle = -1;
      _dragStartPointer = null;
      _dragStartCorners = null;
      _transform.value = Matrix4.identity();
    });
    await _load();
  }

  Future<void> _cancel() async {
    if (_busy) return;
    setState(() => _applying = true);
    try {
      await _undoTurns();
    } catch (_) {
      // 回退旋转失败不影响退出；文件方向不一致的概率极低（连续写盘失败）。
    }
    if (!mounted) return;
    Navigator.of(context).pop(null);
  }

  // ── build ──

  @override
  Widget build(BuildContext context) {
    final quad = _quad;
    final simple = quad?.isSimple() ?? false;
    return PopScope(
      canPop: !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_cancel());
      },
      // 顶层 Stack：Scaffold 之上叠手势轨迹层（页面 Stack 占满窗口，
      // 全局坐标与轨迹层原点一致，见 _onGestureDown）。
      child: Stack(
        children: [
          Positioned.fill(
            child: Listener(
              // 中键按下进入手势采集（整窗口感应，见 _onGestureDown）；
              // 右键平移、左键拖裁切点、滚轮缩放不受影响。
              onPointerDown: (e) {
                if (e.buttons == kMiddleMouseButton) _onGestureDown(e);
              },
              onPointerMove: (e) {
                if (_gestureActive && e.buttons == kMiddleMouseButton) {
                  _onGestureMove(e);
                }
              },
              onPointerUp: (e) {
                if (_gestureActive) _onGestureUp();
              },
              onPointerCancel: (e) {
                if (_gestureActive) {
                  _gestureTracker.cancel();
                  setState(() => _gestureActive = false);
                }
              },
              child: Scaffold(
                backgroundColor: const Color(0xFF101010),
                appBar: AppBar(
                  backgroundColor: const Color(0xFF1C1C1E),
                  foregroundColor: Colors.white,
                  title: Text(
                    _title,
                    style: const TextStyle(fontSize: 15),
                  ),
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: '取消（不修改）',
                      onPressed: _busy ? null : () => unawaited(_cancel()),
                    ),
                  ],
                ),
                body: Row(
                  children: [
                    Expanded(child: _buildBody()),
                    _buildPreviewDivider(),
                    _buildPreviewPanel(),
                  ],
                ),
                bottomNavigationBar: _buildBottomBar(simple),
              ),
            ),
          ),
          // 中键手势拖动轨迹（松手即消失）：全局坐标直画，IgnorePointer
          // 不挡任何交互。
          if (_gestureActive)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: GestureTrailPainter(points: _gestureTracker.trail),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loadingImage) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.white70),
            SizedBox(height: 12),
            Text('正在载入页面 …', style: TextStyle(color: Colors.white70)),
          ],
        ),
      );
    }
    // 位图缺失（任何解码失败）一律显式报错：绝不渲染只有深色底 +
    // 遮罩的"全黑画布"（位图没画出来时框和遮罩也没有意义）。
    if (_image == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            _error ?? '无法读取图片：$_path',
            style: TextStyle(color: Colors.red.shade300),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewportSize = constraints.biggest;
        // 视口有效且用户尚未缩放/平移过 → 帧末自动适配整页可见。
        // （首帧可能撞上退化视口——如底栏把高度吃光的历史 bug——此时
        // fit 会按 0 高度算出 0 缩放，必须等有效帧再补。）
        if (!_fitScheduled &&
            constraints.biggest.height > 0 &&
            _transform.value.isIdentity()) {
          _fitScheduled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _fitScheduled = false;
            if (mounted && _transform.value.isIdentity()) _fitView();
          });
        }
        return Stack(
          children: [
            Positioned.fill(
              child: Listener(
                // 右键拖动平移（编辑器/拆分页同款习惯），左键留给控制点；
                // 滚轮在此分流（普通=缩放视图，Ctrl=整体缩放裁切框）——
                // IV 的内置滚轮缩放已关（见 _onPointerSignal 说明）。
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
                onPointerSignal: _onPointerSignal,
                child: InteractiveViewer(
                  transformationController: _transform,
                  constrained: false,
                  panEnabled: false,
                  // 缩放手势关闭（滚轮缩放由本页 _onPointerSignal 实现）：
                  // IV 的滚轮处理不走仲裁器、外层拦不住，开着会双重缩放。
                  scaleEnabled: false,
                  minScale: _minViewScale,
                  maxScale: _maxViewScale,
                  boundaryMargin: const EdgeInsets.all(double.infinity),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: _onPanStart,
                    onPanUpdate: _onPanUpdate,
                    onPanEnd: _onPanEnd,
                    child: SizedBox(
                      width: _fullW.toDouble(),
                      height: _fullH.toDouble(),
                      // RepaintBoundary：拖拽/缩放只重绘本层（这台机器
                      // 有 GPU 大纹理冲突史，编辑器同款防线），测试也
                      // 借此截屏采样验证渲染。
                      child: RepaintBoundary(
                        key: const Key('straighten-canvas'),
                        child: Stack(
                          children: [
                            // 底图用 RawImage（合成器直传，编辑器同款
                            // 渲染路径）——不走画布 drawImageRect：大图
                            // 纹理在画布路径上在本机曾画不出来（黑屏）。
                            // fit 必须显式给 fill：不传时 paintImage 走
                            // BoxFit.scaleDown——位图（按 _decodeWidth 降
                            // 采样解码）小于全尺寸盒时按原尺寸居中、不放大，
                            // 其余区域没画=透出深底，页面上就是"小页+一圈
                            // 黑边"（裁切坐标仍按全尺寸算，故裁出来的图
                            // 正常，只有显示缩水）。位图与文件同源同比例，
                            // fill 恰好铺满。
                            Positioned.fill(
                              child: RawImage(
                                image: _image,
                                width: _fullW.toDouble(),
                                height: _fullH.toDouble(),
                                fit: BoxFit.fill,
                              ),
                            ),
                            Positioned.fill(
                              // transform 变化（fit/缩放/平移）必须让画笔
                              // 拿到实时 viewScale：controller 是 Listenable
                              // 但不会触发本 State rebuild，painter 若只在
                              // setState 时重建，unit=1/viewScale 的屏幕尺寸
                              // 补偿会一直用 fit 前的旧值——控制点/框线随
                              // 页面分辨率缩水（高分辨率书页上拖拽点小到
                              // 看不见）。AnimatedBuilder 挂上监听。
                              child: AnimatedBuilder(
                                animation: _transform,
                                builder: (context, _) {
                                  return CustomPaint(
                                    painter: _StraightenPainter(
                                      image: _image,
                                      imgScale: _imgScale,
                                      quad: _quad,
                                      draggingHandle: _dragHandle,
                                      showGrid: _showGrid,
                                      viewScale: _viewScale,
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // 检测状态角标
            if (_detectMethod.isNotEmpty)
              Positioned(
                left: 12,
                top: 8,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_detecting)
                          const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white70,
                            ),
                          )
                        else
                          Icon(
                            _detectMethod == 'ink'
                                ? Icons.auto_awesome
                                : _detectMethod == 'contour'
                                    ? Icons.crop_free
                                    : Icons.info_outline,
                            size: 14,
                            color: Colors.white70,
                          ),
                        const SizedBox(width: 6),
                        Text(
                          _detecting
                              ? '正在智能分析裁切点 …'
                              : switch (_detectMethod) {
                                  'ink' => _needsWarp
                                      ? '已按墨迹行列对齐检测'
                                      : '页面平直贴满，通常无需摆正',
                                  'contour' => _needsWarp
                                      ? '已按页面轮廓自动检测'
                                      : '页面平直贴满，通常无需摆正',
                                  _ => '未检测到页面边界，请手动调整',
                                },
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (_error != null && _quad != null)
              Positioned(
                left: 12,
                bottom: 8,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.red.shade900.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      _error!,
                      style: const TextStyle(fontSize: 12, color: Colors.white),
                    ),
                  ),
                ),
              ),
            if (_detecting)
              const Positioned.fill(
                child: ColoredBox(color: Color(0x33000000)),
              ),
          ],
        );
      },
    );
  }

  Widget _buildBottomBar(bool simple) {
    // 底栏必须定高：Scaffold 用无高度约束量底栏、按量得高度给 body 分
    // 配剩余空间——不定高时该 Row 在本页的约束组合下会把整窗高吃掉
    //（实测 1054 全被底栏占走，body 高 0，画布不再适配 → "全黑"）。
    //
    // 布局分两簇：左簇（工具按钮/增强开关/状态徽标/提示）在窄窗口下
    // （右侧预览面板挤占后可能只剩六七百 px）允许横向滚动；右簇（拼接/
    // 删除/确认等动作按钮）保持常显不滚——滚动区域里不能用 Spacer/
    // Flexible（无界宽度），右簇天然当右锚。
    final host = widget.host;
    return Container(
      key: const Key('straighten-bottom-bar'),
      color: const Color(0xFF1C1C1E),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.rotate_left),
                      tooltip: '逆时针旋转 90°',
                      color: Colors.white70,
                      onPressed: _busy ? null : () => unawaited(_rotate(false)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.rotate_right),
                      tooltip: '顺时针旋转 90°',
                      color: Colors.white70,
                      onPressed: _busy ? null : () => unawaited(_rotate(true)),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: const Icon(Icons.auto_awesome),
                      tooltip: '重新智能检测裁切点',
                      color: Colors.white70,
                      onPressed: _busy ? null : _detect,
                    ),
                    IconButton(
                      icon: const Icon(Icons.receipt_long),
                      tooltip: '检测日志：本页智能边框是怎样判定的',
                      color: Colors.white70,
                      onPressed: _detectTrace == null ? null : _showDetectTrace,
                    ),
                    IconButton(
                      icon: const Icon(Icons.crop_free),
                      tooltip: '重置为全图',
                      color: Colors.white70,
                      onPressed: _busy || _quad == null
                          ? null
                          : () {
                              setState(
                                () => _quad = PageQuad.defaultInset(_viewSize),
                              );
                              _schedulePreviewRefresh();
                            },
                    ),
                    IconButton(
                      icon: Icon(_showGrid ? Icons.grid_on : Icons.grid_off),
                      tooltip: '网格参考线开关',
                      color: Colors.white70,
                      onPressed: _busy ? null : () => setState(() => _showGrid = !_showGrid),
                    ),
                    const VerticalDivider(width: 20, indent: 8, endIndent: 8),
                    _ToggleChip(
                      label: '去色',
                      icon: Icons.gradient,
                      selected: _grayscale,
                      onPressed: _busy
                          ? null
                          : () {
                              setState(() => _grayscale = !_grayscale);
                              _schedulePreviewRefresh();
                            },
                    ),
                    const SizedBox(width: 8),
                    _ToggleChip(
                      label: '锐化',
                      icon: Icons.deblur,
                      selected: _sharpen,
                      onPressed: _busy
                          ? null
                          : () {
                              setState(() => _sharpen = !_sharpen);
                              _schedulePreviewRefresh();
                            },
                    ),
                    const SizedBox(width: 8),
                    _ToggleChip(
                      label: '去透印',
                      icon: Icons.layers_clear,
                      selected: _debleed,
                      onPressed: _busy
                          ? null
                          : () {
                              setState(() => _debleed = !_debleed);
                              _schedulePreviewRefresh();
                            },
                    ),
                    if (_debleed)
                      SizedBox(
                        width: 130,
                        height: 44,
                        child: Slider(
                          value: _debleedStrength.toDouble(),
                          min: 1,
                          max: 100,
                          divisions: 99,
                          label: '去透印强度 $_debleedStrength',
                          // 拖动即排防抖预览（500ms 后自动出图），不手动刷新。
                          onChanged: _busy
                              ? null
                              : (v) {
                                  setState(() => _debleedStrength = v.round());
                                  _schedulePreviewRefresh();
                                },
                        ),
                      ),
                    if (_confirmed)
                      const Padding(
                        padding: EdgeInsets.only(left: 12),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.check_circle, size: 15, color: Colors.teal),
                            SizedBox(width: 4),
                            Text('已确认', style: TextStyle(fontSize: 12, color: Colors.teal)),
                          ],
                        ),
                      ),
                    const Padding(
                      padding: EdgeInsets.only(left: 12),
                      child: Text(
                        'Ctrl+滚轮 整体缩放裁切框',
                        style: TextStyle(fontSize: 11, color: Colors.white38),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // 会话模式：拼接 / 删除 / 确认并自动翻下一页；独立模式：确认摆正。
            if (host != null) ...[
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.amber.shade200,
                  side: BorderSide(
                    color: Colors.amber.shade200.withValues(alpha: 0.5),
                  ),
                ),
                onPressed: _busy ? null : _openStitch,
                icon: const Icon(Icons.call_merge, size: 17),
                label: const Text('拼接'),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red.shade300,
                  side: BorderSide(color: Colors.red.shade300.withValues(alpha: 0.5)),
                ),
                onPressed: _busy ? null : _deleteCurrent,
                icon: const Icon(Icons.delete_outline, size: 17),
                label: const Text('删除'),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Colors.teal),
                onPressed: (_busy || !simple) ? null : _confirmAndNext,
                icon: _applying
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.check, size: 18),
                label: const Text('确认并下一页'),
              ),
            ] else
              FilledButton.icon(
                onPressed: (_busy || !simple) ? null : () => unawaited(_confirm()),
                icon: _applying
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.check, size: 18),
                label: Text(simple ? '确认摆正' : '裁切框自交，请调整'),
              ),
          ],
        ),
      ),
    );
  }
}

/// 就地旋转显示位图 90°（[cw] 为顺时针），供校对摆正旋转按钮在内存中
/// 同步转向显示图（盘上文件由 /transform_page 负责）。
///
/// 输出光栅**恒为宽高互换的 h×w**——内容的落位由 translate/rotate 完成，
/// 两个方向的 90° 旋转输出尺寸相同；若按方向取 (w,h)，逆时针会把已转向
/// 的横内容放进竖光栅：内容被裁、旁生空白带，再被 RawImage 以
/// BoxFit.fill 拉进已换轴的画布盒——页面上即"旋转几次后图片拉伸"。
Future<ui.Image> rotateImageMemory(ui.Image src, bool cw) async {
  final w = src.width, h = src.height;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.translate(cw ? h.toDouble() : 0, cw ? 0 : w.toDouble());
  canvas.rotate(cw ? math.pi / 2 : -math.pi / 2);
  canvas.drawImage(
    src,
    Offset.zero,
    Paint()..filterQuality = FilterQuality.medium,
  );
  final picture = recorder.endRecording();
  final out = await picture.toImage(h, w);
  picture.dispose();
  return out;
}

/// 深色工具栏里的开关 chip（去色/锐化/去透印）。
class _ToggleChip extends StatelessWidget {
  const _ToggleChip({
    required this.label,
    required this.icon,
    required this.selected,
    this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? Colors.indigoAccent : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? Colors.indigoAccent : Colors.white24,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 15,
              color: selected ? Colors.white : Colors.white70,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: selected ? Colors.white : Colors.white70,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 摆正画布画笔：遮罩 + 弯边裁切框 + 网格 + 8 控制点 + 放大镜。
/// 底图不在这里画——RawImage 组件走合成器路径（本机画布 drawImageRect
/// 画大图曾渲染不出），image 只供放大镜取局部。
class _StraightenPainter extends CustomPainter {
  _StraightenPainter({
    required this.image,
    required this.imgScale,
    required this.quad,
    required this.draggingHandle,
    required this.showGrid,
    required this.viewScale,
  });

  final ui.Image? image;
  final double imgScale; // 显示图 / 全图 比例
  final PageQuad? quad;
  final int draggingHandle;
  final bool showGrid;
  final double viewScale;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = 1.0 / math.max(viewScale, 0.001);

    final q = quad;
    if (q == null) return;
    final quadPath = q.toPath();

    // 四边形外深色遮罩：全画布挖掉四边形。
    final mask = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      quadPath,
    );
    canvas.drawPath(mask, Paint()..color = Colors.black.withValues(alpha: 0.55));

    // 内部网格参考线（Coons 插值曲线，u/v 取 1/3、2/3）。线画在页面
    // 区域内、多为白纸，用深色才看得见。
    if (showGrid) {
      final gridPaint = Paint()
        ..color = Colors.black.withValues(alpha: 0.30)
        ..strokeWidth = unit
        ..style = PaintingStyle.stroke;
      for (final t in const [1 / 3, 2 / 3]) {
        _drawParamLine(canvas, q, gridPaint, fixedU: t);
        _drawParamLine(canvas, q, gridPaint, fixedV: t);
      }
    }

    // 裁切框：深色衬底 + 橙色实线双层描边。不能用白色——书页本身就是
    // 白纸，白框会直接隐身；深衬底保证在亮背景、橙线保证在暗背景都有
    // 对比。自交时衬底红色警示（确认按钮同步禁用）。
    final simple = q.isSimple();
    canvas.drawPath(
      quadPath,
      Paint()
        ..color = simple
            ? Colors.black.withValues(alpha: 0.45)
            : Colors.black.withValues(alpha: 0.7)
        ..strokeWidth = 5.5 * unit
        ..style = PaintingStyle.stroke,
    );
    canvas.drawPath(
      quadPath,
      Paint()
        ..color = simple ? Colors.orange : Colors.red.shade400
        ..strokeWidth = 2.5 * unit
        ..style = PaintingStyle.stroke,
    );

    // 8 个控制点：角点大圆（改形状）+ 边中点小圆（拖动整条边），
    // 拖拽中的高亮放大。点要够大够好抓（用户反馈原版太小）。
    for (var handle = 0; handle < 8; handle++) {
      final isCorner = handle < 4;
      final isDragging = handle == draggingHandle;
      final pos = isCorner ? q.corners[handle] : q.edgeMid(handle - 4);
      final accent = isDragging ? Colors.deepOrange : Colors.orange;
      final outerR = (isCorner ? 13.0 : 10.0) * unit;
      if (isDragging) {
        // 拖拽光环
        canvas.drawCircle(
          pos,
          outerR + 7 * unit,
          Paint()..color = accent.withValues(alpha: 0.35),
        );
      }
      canvas.drawCircle(pos, outerR, Paint()..color = accent);
      canvas.drawCircle(
        pos,
        outerR,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5 * unit
          ..color = Colors.white,
      );
      canvas.drawCircle(
        pos,
        outerR,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1 * unit
          ..color = Colors.black.withValues(alpha: 0.4),
      );
      canvas.drawCircle(
        pos,
        (isCorner ? 4.5 : 3.5) * unit,
        Paint()..color = Colors.white,
      );
    }

    // 放大镜：拖拽中在控制点上方显示 4× 局部放大 + 十字准星。
    if (draggingHandle >= 0) {
      final pos = draggingHandle < 4
          ? q.corners[draggingHandle]
          : q.edgeMid(draggingHandle - 4);
      _drawLoupe(canvas, size, pos, unit);
    }
  }

  void _drawParamLine(
    Canvas canvas,
    PageQuad q,
    Paint paint, {
    double? fixedU,
    double? fixedV,
  }) {
    final path = Path();
    final steps = 24;
    for (var i = 0; i <= steps; i++) {
      final t = i / steps;
      final pt = fixedU != null ? q.pointAt(fixedU, t) : q.pointAt(t, fixedV!);
      if (i == 0) {
        path.moveTo(pt.dx, pt.dy);
      } else {
        path.lineTo(pt.dx, pt.dy);
      }
    }
    canvas.drawPath(path, paint);
  }

  void _drawLoupe(Canvas canvas, Size size, Offset pos, double unit) {
    final img = image;
    if (img == null) return;
    const zoom = 4.0;
    final radius = 62 * unit;
    // 放大镜固定出现在控制点右上方向，夹回画布内避免看不到。
    var center = pos + Offset(radius + 26 * unit, -(radius + 26 * unit));
    center = Offset(
      center.dx.clamp(radius, math.max(radius, size.width - radius)),
      center.dy.clamp(radius, math.max(radius, size.height - radius)),
    );

    canvas.save();
    canvas.clipPath(
      Path()..addOval(Rect.fromCircle(center: center, radius: radius)),
    );
    canvas.drawRect(
      Rect.fromCircle(center: center, radius: radius),
      Paint()..color = const Color(0xFF202020),
    );
    // 源区域：控制点周围的显示图像素（显示图坐标 = 全图坐标 × imgScale），
    // 宽度取 dst 的 1/zoom，放大镜内即 4× 视觉放大。
    final srcHalf = radius / zoom * imgScale;
    final srcCenter = pos * imgScale;
    canvas.drawImageRect(
      img,
      Rect.fromCircle(center: srcCenter, radius: srcHalf),
      Rect.fromCircle(center: center, radius: radius),
      Paint()
        ..filterQuality = FilterQuality.medium
        ..isAntiAlias = true,
    );
    // 十字准星指向控制点在放大镜中的位置（= 圆心）。
    final cross = Paint()
      ..color = Colors.orange
      ..strokeWidth = unit;
    canvas.drawLine(
      center.translate(-8 * unit, 0),
      center.translate(8 * unit, 0),
      cross,
    );
    canvas.drawLine(
      center.translate(0, -8 * unit),
      center.translate(0, 8 * unit),
      cross,
    );
    canvas.restore();
    // 白色边圈加深色衬底（放大镜内多半是白纸，单白圈会隐身）+ 指向
    // 控制点的连接线。
    canvas.drawCircle(
      center,
      radius + unit,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * unit
        ..color = Colors.black.withValues(alpha: 0.5),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * unit
        ..color = Colors.white,
    );
    canvas.drawLine(
      pos,
      _circleEdgeToward(center, radius, pos),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.75)
        ..strokeWidth = unit,
    );
  }

  /// 圆周上朝向 target 的一点（连接线端点用）。
  Offset _circleEdgeToward(Offset center, double radius, Offset target) {
    final d = target - center;
    final len = d.distance;
    if (len <= 0) return center;
    return center + d / len * radius;
  }

  @override
  bool shouldRepaint(_StraightenPainter old) =>
      old.image != image ||
      old.quad != quad ||
      old.draggingHandle != draggingHandle ||
      old.showGrid != showGrid ||
      old.viewScale != viewScale;
}
