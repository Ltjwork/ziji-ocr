import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../models/page_quad.dart';
import '../services/book_region_apply.dart';
import '../services/feature_matching.dart' show kMatchDefaults;
import '../services/image_probe.dart';
import '../services/feature_points.dart';
import '../services/ink_align.dart';
import '../services/python_service.dart';
import '../services/storage.dart';

/// 批量应用的目标统计：未保存页页号列表、未识别页页号列表，以及已
/// 确认页计数（弹窗里向用户交代范围用）。未识别页只在「改框并重识
/// 别」模式下纳入（新建标注并按新区识别）；「只改框」无从改起。
typedef BookApplyTargets = ({
  int confirmed,
  List<int> pages,
  List<int> unrecognizedPages,
});

/// 「指定页统一设置」的范围扫描结果（确认弹窗展示 + 应用循环的目标表，
/// 纯数据；扫描本体见 [BookOverlayPage.quickApplyTargetsFrom]）。
class OverlayQuickScan {
  const OverlayQuickScan({
    required this.pages,
    required this.freshPages,
    required this.proofreadSkip,
    required this.noMainSkip,
    required this.confirmedReset,
  });

  /// 可设置的页（0 基升序）：范围内剔除校对完成的页（整页绿框「确认并
  /// 保存」/玫红框「确认识别框」——校对成果不因批量改框被动）与「确认
  /// 无正文」的页（扉页/插图，人工已判无正文）；**无标注页在内**——统
  /// 一设置正是要给没设过的页补正文区。
  final List<int> pages;

  /// 目标页里无标注（将新建标注）的页数。
  final int freshPages;

  /// 校对完成跳过的页数。
  final int proofreadSkip;

  /// 「确认无正文」跳过的页数。
  final int noMainSkip;

  /// 原主区已确认（绿色"已确认"角标）的页数：应用后随批量写入一并退
  /// 回未确认（弹窗里向用户交代确认状态的变动）。
  final int confirmedReset;
}

/// 全书叠加模式（编辑器工具栏入口）：把窗口范围内的所有页半透明
/// 叠加成一张图，扫描偏移/尺寸不一在叠加中一眼可见；在其上拖出一个
/// 正文区矩形，一键应用到全书或页范围。
///
/// - 矩形以画布归一化坐标为准，应用时按每页实际像素尺寸换算（页大
///   小不一时自动按 contain 映射）。
/// - 两种应用模式：「只改框」全书秒级；「改框并重识别」逐页调后端
///   `/segment_lines_in_region`（409 忙时排队重试），合并规则与编辑器
///   主区级联同一份（BookRegionApply）。
/// - 页面图 200DPI，这里全部按 1200px 宽降采样合成一张图，源图合成
///   完立即释放；窗口上限 100 页。
///
/// 另有主区快设的「指定页叠加统一设置」模式（[BookOverlayPage.quickPages]）：
/// 同一套叠加画布，应用只写选定页表、只改框，且写了正文的页一律退回
/// 未确认，由用户逐页查看后自己确认。
class BookOverlayPage extends StatefulWidget {
  const BookOverlayPage({
    super.key,
    required this.project,
    this.quickPages,
    this.quickSavePage,
  });

  final Project project;

  /// 非 null = 主区快设「指定页叠加统一设置」模式（0 基、升序去重、
  /// **可离散**——网格里 Ctrl/Shift 多选的页直接进来，连续范围也走同一
  /// 份页表）：叠加窗口就是这份页表本身（无窗口滑杆），应用只把画出的
  /// **各类别**版面区（正文/页眉/页脚/页码…，顶栏切换、每类可多个）写
  /// 入其中——保护口径同「按参考页适配」（校对完成的页与「确认无正文」
  /// 的页恒跳过，无标注页新建标注）；**应用后写了正文的页一律退回未确
  /// 认**（含原主区已确认页——批量几何未经逐页核对），由用户回主区快
  /// 设逐页查看后自己确认。不提供重识别（识别统一留给主区快设「按主
  /// 区拆分」）。
  final List<int>? quickPages;

  /// 统一设置的逐页写入回调（主区快设网格实现：batch 保存 + 退回未确
  /// 认，网格内存态随写随同步，返回后无需重读）。[mainRects] 为 null =
  /// 不动该页正文区（只设置页眉/页脚等类别——统一设置不提供"删光各页
  /// 主区"的语义）；返回 false = 写盘失败。
  final Future<bool> Function(
    int index,
    List<Rect>? mainRects,
    Map<String, List<Rect>> extras,
  )?
  quickSavePage;

  /// 「指定页统一设置」的目标页扫描本体（供单测）：[pages] 为选定页表
  /// （0 基，任意顺序、可离散）；[annotations] 缺页（无标注）键缺省即可。
  static OverlayQuickScan quickApplyTargetsFrom({
    required Map<int, PageAnnotation?> annotations,
    required List<int> pages,
  }) {
    final targets = <int>[];
    var fresh = 0;
    var proofreadSkip = 0;
    var noMainSkip = 0;
    var confirmedReset = 0;
    for (final i in pages) {
      final ann = annotations[i];
      if (ann != null &&
          (ann.isFullyConfirmed || ann.boxesReviewed || ann.reviewed)) {
        proofreadSkip++;
        continue;
      }
      if (ann?.noMainTextConfirmed == true) {
        noMainSkip++;
        continue;
      }
      targets.add(i);
      if (ann == null) {
        fresh++;
      } else if (ann.mainRegions.any(
        (r) =>
            RegionLabel.normalize(r.label) == RegionLabel.mainText &&
            r.boxConfirmed,
      )) {
        confirmedReset++;
      }
    }
    return OverlayQuickScan(
      pages: targets,
      freshPages: fresh,
      proofreadSkip: proofreadSkip,
      noMainSkip: noMainSkip,
      confirmedReset: confirmedReset,
    );
  }

  /// 统一设置的草稿 → 逐页写入载荷（供单测，写入循环每页共用同一份）：
  /// 正文类有框时整组带入（目标页正文区收敛为这组，多主区页同样支
  /// 持）；只画了页眉/页脚等类别时正文传 **null = 不动主区**——统一设
  /// 置不提供"删光各页正文区"的语义（空列表在 [_saveRegion] 里是"本页
  /// 无正文区"）。退化框（画布坐标宽或高 <2，误触残留）丢弃；过滤后
  /// 变空的类别整类剔除。
  static (List<Rect>?, Map<String, List<Rect>>) quickApplyPayloadFrom(
    Map<String, List<Rect>> drafts,
  ) {
    Rect? usable(Rect r) => r.width >= 2 && r.height >= 2 ? r : null;
    final mains = [
      for (final r in drafts[RegionLabel.mainText] ?? const <Rect>[])
        if (usable(r) != null) r,
    ];
    final extras = <String, List<Rect>>{
      for (final e in drafts.entries)
        if (e.key != RegionLabel.mainText && e.value.isNotEmpty)
          e.key: [
            for (final r in e.value)
              if (usable(r) != null) r,
          ],
    }..removeWhere((_, v) => v.isEmpty);
    return (mains.isEmpty ? null : mains, extras);
  }

  @override
  State<BookOverlayPage> createState() => _BookOverlayPageState();
}

class _BookOverlayPageState extends State<BookOverlayPage> {
  static const double _canvasW = 1200;
  static const int _maxWindow = 100;
  static const double _composeDecodeWidth = 1200;

  ui.Image? _composite;
  double _canvasH = 0;
  Rect? _unionRect; // 窗口内各页现有主区的并集（画布坐标，虚线参考）
  // 窗口内实际画入合成图的页数（已确认识别框的页不参与，为 0 时画布
  // 只有底色，界面提示换窗口）。
  int _participating = 0;
  int _windowStart = 0;
  int _windowSize = 30;
  double _pageAlpha = 1 / 30;
  bool _composing = false;
  int _composeDone = 0;

  /// 墨迹对齐（默认开）：合成前把各参与页按墨迹投影互相配准（平移 +
  /// 小角度旋转，见 [InkAlignResult]），画页、并集虚线、写回框三处
  /// 共用同一套变换；置信度不足的页不偏移并计数提示。关闭或参与页
  /// <2 时退回旧的"各自 contain 居中"口径。
  bool _inkAlign = true;
  InkAlignResult? _inkAlignResult;

  /// 对齐方式：true = 特征点匹配 + RANSAC（新法，默认），false = 投
  /// 影互相关（旧法）。两者输出同一套 [InkAlignResult]，画页/写回/并
  /// 集虚线零差别；保留旧法作为效果对比与回退。
  bool _featureAlign = true;

  /// 页内对齐日志（弹窗查看/复制；与后端日志同文，见 [_logAlign]）。
  final List<String> _alignLogs = <String>[];

  /// 合成进度两阶段文案与总数（分析墨迹 + 合成叠加图）。
  String _composePhase = '合成叠加图';
  int _composeTotal = 0;

  /// 各类别草稿（label → 矩形列表，画布坐标）：统一设置模式每类可画
  /// 多个（左右页脚/多段页眉各框一块），当前类别 [_activeLabel] 的第
  /// [_activeIndex] 个为"当前框"（橙色，可拖动/调角，**-1 = 未选中**）；
  /// 全书叠加模式只有 main_text 一类且拖新框 = 整类替换（保持原单矩形
  /// 语义）。
  final Map<String, List<Rect>> _drafts = {};
  String _activeLabel = RegionLabel.mainText;
  int _activeIndex = 0;

  /// 开始画新框前当前类别的框数与选中态（统一设置模式的误触回滚用）。
  int? _preDrawCount;
  int? _preDrawActiveIndex;

  _DragMode _mode = _DragMode.none;
  Offset? _drawOrigin;

  /// 正文区当前草稿（全书叠加模式的单矩形口径：草稿整组只有一条）。
  Rect? get _draftRect {
    final list = _drafts[RegionLabel.mainText];
    return list != null && list.isNotEmpty ? list.first : null;
  }

  final TransformationController _transform = TransformationController();
  Offset? _panAnchor;
  Size? _viewportSize;

  // ── init / lifecycle ──

  /// 统一设置模式的选定页表（0 基升序去重， initState 从
  /// [BookOverlayPage.quickPages] 归一）：叠加合成、扫描、写入都以它为
  /// 准——可离散（网格 Ctrl/Shift 多选）。
  List<int>? _quickPages;

  /// 「指定页统一设置」模式（主区快设入口）：应用对话框/写入循环/界面
  /// 文案都按它分支，应用目标恒为 [_quickPages]。
  bool get _isQuick => _quickPages != null;

  /// 选定页表的人类描述：连续 → 「第 a~b 页」；离散 → 「第 a~b 页中的
  /// n 页（离散）」；单页 → 「第 a 页」。
  String get _quickPageDesc {
    final pages = _quickPages!;
    if (pages.length == 1) return '第 ${pages.first + 1} 页';
    final first = pages.first + 1;
    final last = pages.last + 1;
    if (last - first + 1 == pages.length) return '第 $first~$last 页';
    return '第 $first~$last 页中的 ${pages.length} 页（离散）';
  }

  /// 本次要合成的页表：统一设置模式 = 选定页表；全书叠加模式 = 当前窗
  /// 口范围。
  List<int> get _composePageList => _isQuick
      ? _quickPages!
      : [for (var i = _windowStart; i < _windowEnd; i++) i];

  @override
  void initState() {
    super.initState();
    final quick = widget.quickPages;
    if (quick != null) {
      _quickPages = [...quick]..sort();
      _pageAlpha = (1 / math.max(1, _quickPages!.length)).clamp(0.02, 1.0);
      // 进页即扫选定页状态（统一设置弹窗的统计与目标表），弹窗打开时
      // 计数已就绪不用等。
      _quickScanFuture = _scanQuickTargets();
    } else {
      _pageAlpha = (1 / _windowSize).clamp(0.02, 1.0);
    }
    // 进页即扫全书页状态（应用弹窗的范围统计），弹窗打开时计数已就绪
    // 不用等。应用成功后本页会关闭返回编辑器，不需要失效重建。
    _targetsFuture = _scanTargets();
    _recompose();
  }

  Future<BookApplyTargets> _targetsFuture = Future.value((
    confirmed: 0,
    pages: <int>[],
    unrecognizedPages: <int>[],
  ));

  /// 「统一设置」范围扫描（ [_scanQuickTargets] 的结果），进页即扫。
  Future<OverlayQuickScan>? _quickScanFuture;

  /// 盘上实扫选定页表的标注（确认弹窗统计与写入循环共用同一份快照；
  /// 写入循环里另有逐页防御性复查）。
  Future<OverlayQuickScan> _scanQuickTargets() async {
    final annotations = <int, PageAnnotation?>{};
    for (final i in _quickPages!) {
      annotations[i] = await ProjectStorage.loadAnnotation(
        widget.project.projectDir,
        widget.project.pageIdAt(i),
      );
    }
    return BookOverlayPage.quickApplyTargetsFrom(
      annotations: annotations,
      pages: _quickPages!,
    );
  }

  @override
  void dispose() {
    _composite?.dispose();
    _transform.dispose();
    super.dispose();
  }

  int get _pageCount => widget.project.imageFiles.length;

  int get _windowEnd =>
      math.min(_windowStart + _windowSize, _pageCount); // exclusive

  /// 叠加页数滑块上限：窗口上限与实际页数的较小值，至少 4（页数太少
  /// 的书滑块退化为不可调，窗口就是全书）。
  int get _windowSliderMax =>
      math.max(4, math.min(_maxWindow, math.max(_pageCount, 4)));

  // ── compositing ──

  Future<void> _recompose() async {
    final project = widget.project;
    final composePages = _composePageList;
    if (composePages.isEmpty) return;
    final alignOn = _inkAlign && composePages.length >= 2;
    setState(() {
      _composing = true;
      _composeDone = 0;
      _composePhase = alignOn ? '分析墨迹' : '合成叠加图';
      _composeTotal = composePages.length * (alignOn ? 2 : 1);
    });
    // 画布比例取首张页（通常全书一致；个别页比例不同则 contain 留边）。
    Size? firstSize;
    for (final i in composePages) {
      firstSize = await probeImageSize(project.imageFiles[i]);
      if (firstSize != null) break;
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
    // 墨迹对齐先行：小图分析 → 全组配准（与画页循环同一跳过口径）。
    // 中途失败/放弃返回 null，画页与写回一律退回恒等变换。
    _inkAlignResult = alignOn
        ? await _computeInkAlign(composePages, canvasSize)
        : null;
    if (!mounted) return;
    final base = _inkAlignResult != null ? composePages.length : 0;
    setState(() {
      _composePhase = '合成叠加图';
      _composeDone = base;
    });
    final center = Offset(canvasSize.width / 2, canvasSize.height / 2);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Offset.zero & canvasSize,
      Paint()..color = const Color(0xFF181818),
    );
    final alpha = _pageAlpha.clamp(0.02, 1.0);
    final paint = Paint()..filterQuality = FilterQuality.low;
    final regionRects = <Rect>[];
    var participating = 0;
    var composeDone = 0;
    for (final i in composePages) {
      composeDone++;
      final ann = await ProjectStorage.loadAnnotation(
        project.projectDir,
        project.pageIdAt(i),
      );
      if (ann != null && (ann.boxesReviewed || ann.reviewed)) {
        // 已「确认识别框」/「确认并保存」的页不参与叠加：不画入合成图、
        // 不计入并集参考，与批量应用的跳过口径一致。旧版数据可能只有
        // reviewed 没有 boxes_reviewed（"完全确认蕴含框确认"未回填），
        // 两个标记任一为真都算已确认。
        if (!mounted) {
          recorder.endRecording().dispose();
          return;
        }
        setState(() => _composeDone = base + composeDone);
        continue;
      }
      var pageSize = await probeImageSize(project.imageFiles[i]);
      final img = await _decode(
        project.imageFiles[i],
        _composeDecodeWidth.round(),
      );
      if (img != null) {
        participating++;
        pageSize ??= Size(img.width.toDouble(), img.height.toDouble());
        final fit = _fitRect(pageSize, canvasSize);
        paint.color = Color.fromRGBO(255, 255, 255, alpha);
        final tr = _pageTransform(i);
        if (tr.isIdentity) {
          canvas.drawImageRect(
            img,
            Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
            fit,
            paint,
          );
        } else {
          // 墨迹对齐的画页变换：绕画布中心旋转 + 平移 + 全局统一缩放
          //（矩阵由 [OverlayInkTransform] 与写回逆变换同一口径给出）。
          canvas.save();
          canvas.transform(tr.affineStorage(center));
          canvas.drawImageRect(
            img,
            Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
            fit,
            paint,
          );
          canvas.restore();
        }
        img.dispose(); // 已画入离屏画布，立即释放源图
      }
      if (ann != null && ann.mainRegions.isNotEmpty && pageSize != null) {
        final fit = _fitRect(pageSize, canvasSize);
        final tr = _pageTransform(i);
        for (final r in ann.mainRegions) {
          // 并集虚线与画页同一变换：对齐后各页现有主区在同一坐标系
          // 下取并集，用户看到的参考才是"配准后的并集"。
          regionRects.add(
            tr.mapRect(_pageRectToCanvas(r.rect, fit, pageSize), center),
          );
        }
      }
      if (!mounted) {
        recorder.endRecording().dispose();
        return;
      }
      setState(() => _composeDone = base + composeDone);
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
      _unionRect = regionRects.isEmpty
          ? null
          : regionRects.reduce((a, b) => a.expandToInclude(b));
      _participating = participating;
      _composing = false;
      // 没画过矩形时用并集参考自动摆一个草稿框：「批量修改」的预期是
      // 在现有主区基础上调整，而不是从零画框。用户可继续拖动微调。
      final union = _unionRect;
      if (_draftRect == null && union != null) {
        _drafts[RegionLabel.mainText] = [union];
      }
    });
  }

  /// 首次合成后把画布缩放到整页可见居中；用户已经缩放/平移过（矩阵
  /// 非 identity）则不动，避免每次调窗口都重置视图。
  void _fitInitialView(Size canvasSize) {
    if (!_transform.value.isIdentity()) return;
    final vp = _viewportSize;
    if (vp == null || vp.width <= 0 || vp.height <= 0) return;
    final scale =
        math.min(vp.width / canvasSize.width, vp.height / canvasSize.height) *
        0.95;
    final tx = (vp.width - canvasSize.width * scale) / 2;
    final ty = (vp.height - canvasSize.height * scale) / 2;
    _transform.value = Matrix4.translationValues(
      tx,
      ty,
      0,
    ).multiplied(Matrix4.identity()..scaleByDouble(scale, scale, 1, 1));
  }

  /// 解码到指定宽度；失败返回 null（缺页/坏文件按空处理，不中断叠加）。
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

  /// 墨迹对齐分析：逐页解码到工作宽度 → RGBA 分析（特征点或投影，
  /// [_featureAlign] 二选一）→ 全组配准（已确认页与画页循环同一口径
  /// 跳过）。任何一步失败/放弃返回 null，画页与写回退回恒等变换。
  Future<InkAlignResult?> _computeInkAlign(
    List<int> pages,
    Size canvasSize,
  ) async {
    final project = widget.project;
    final work = Size(
      kInkAlignDefaults.workWidth.toDouble(),
      kInkAlignDefaults.workWidth * canvasSize.height / canvasSize.width,
    );
    final profiles = <int, InkPageProfile>{}; // 投影法
    final feats = <int, InkPageFeatures>{}; // 特征法
    var done = 0;
    for (final i in pages) {
      final ann = await ProjectStorage.loadAnnotation(
        project.projectDir,
        project.pageIdAt(i),
      );
      if (ann != null && (ann.boxesReviewed || ann.reviewed)) {
        done++;
        if (mounted) setState(() => _composeDone = done);
        continue;
      }
      final img = await _decode(
        project.imageFiles[i],
        kInkAlignDefaults.workWidth,
      );
      if (img != null) {
        final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (data != null) {
          final rgba = data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
          final fit = _fitRect(
            Size(img.width.toDouble(), img.height.toDouble()),
            work,
          );
          if (_featureAlign) {
            feats[i] = extractFeaturePoints(
              rgba: rgba,
              imgW: img.width,
              imgH: img.height,
              fit: fit,
              workCanvas: work,
            );
          } else {
            profiles[i] = analyzeInkPage(
              rgba: rgba,
              imgW: img.width,
              imgH: img.height,
              fit: fit,
              workCanvas: work,
            );
          }
        }
        img.dispose();
      }
      done++;
      if (!mounted) return null;
      setState(() => _composeDone = done);
    }
    final sw = Stopwatch()..start();
    final result = _featureAlign
        ? computeInkAlignmentsFromFeatures(
            features: feats,
            canvasScale: _canvasW / work.width,
            overlayCanvas: canvasSize,
          )
        : computeInkAlignments(
            profiles: profiles,
            canvasScale: _canvasW / work.width,
            overlayCanvas: canvasSize,
          );
    sw.stop();
    final analyzed = _featureAlign ? feats.length : profiles.length;
    final ts = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    _logAlign(
      '─── ${two(ts.hour)}:${two(ts.minute)}:${two(ts.second)} '
      '${_isQuick ? '指定页叠加' : '全书叠加'} · '
      '${_featureAlign ? '特征点对齐' : '投影对齐'} · '
      '分析 $analyzed/${pages.length} 页 · ${sw.elapsedMilliseconds}ms · '
      '${_featureAlign ? 'ratio=${kMatchDefaults.ratioThreshold} '
          '内点阈=${kMatchDefaults.inlierThreshold}px '
          '门限=${kMatchDefaults.minMatches}/${kMatchDefaults.minInliers}/'
          '${kMatchDefaults.minInlierRatio}' : 'maxShift=${kInkAlignDefaults.maxShift} '
          '阈值=${kInkAlignDefaults.minConfidenceX}/${kInkAlignDefaults.minConfidenceY} '
          '高通=${kInkAlignDefaults.profileHighPassWindow}'}',
    );
    if (result.referencePage >= 0) {
      _logAlign(
        '参考第 ${result.referencePage + 1} 页，'
        '对齐 ${result.alignedCount} 页'
        '${result.lowConfidenceCount > 0
            ? '，低置信 ${result.lowConfidenceCount} 页未偏移' : ''}'
        '${result.globalScale < 1
            ? '，整体缩 ${(result.globalScale * 100).round()}%' : ''}',
      );
      // 逐页全量诊断（页内日志弹窗可一键复制给排查用）：对齐页带实际
      // 平移量与纸心差（先验），未对齐页带原因，不可分析页单独标注。
      // 特征法另带原生指标（匹配数/内点数，diagnostics）。
      final refPc = (_featureAlign
              ? feats[result.referencePage]?.paperCenter
              : profiles[result.referencePage]?.paperCenter) ??
          Offset.zero;
      for (final i in pages) {
        final v = result.byPage[i];
        if (v != null) {
          final pcReal =
              (_featureAlign ? feats[i]?.paperCenter : profiles[i]?.paperCenter) ??
                  Offset.zero;
          final priorDesc =
              '纸心差 (${(pcReal - refPc).dx.toStringAsFixed(0)}, ${(pcReal - refPc).dy.toStringAsFixed(0)})';
          final diag = result.diagnostics[i];
          if (v.aligned) {
            _logAlign(
              '第 ${i + 1} 页：旋转 ${(v.angle * 180 / math.pi).toStringAsFixed(2)}°，'
              '平移 (${v.shift.dx.toStringAsFixed(1)}, '
              '${v.shift.dy.toStringAsFixed(1)})px，'
              '$priorDesc，'
              '${diag == null ? '' : '$diag，'}'
              '置信 ${v.confidenceX.toStringAsFixed(2)}/'
              '${v.confidenceY.toStringAsFixed(2)}',
            );
          } else {
            _logAlign(
              '第 ${i + 1} 页未偏移：${v.reason}，'
              '$priorDesc，'
              '${diag == null ? '' : '$diag，'}'
              '置信 ${v.confidenceX.toStringAsFixed(2)}/'
              '${v.confidenceY.toStringAsFixed(2)}',
            );
          }
        } else if (_featureAlign ? feats.containsKey(i) : profiles.containsKey(i)) {
          _logAlign('第 ${i + 1} 页不可分析（墨迹不足/二值化失败），不参与对齐');
        }
      }
    } else {
      _logAlign('可分析页不足（$analyzed 页），未对齐');
    }
    return result;
  }

  /// 对齐日志双写：页内列表（弹窗查看/复制，上限 400 行滚动淘汰）+
  /// 后端应用日志，两处同一份文本，用户复制出来的与后台可直接对照。
  void _logAlign(String msg) {
    final line = '[叠加·墨迹对齐] $msg';
    _alignLogs.add(line);
    if (_alignLogs.length > 400) {
      _alignLogs.removeRange(0, _alignLogs.length - 400);
    }
    PythonService.addAppLog(line);
  }

  /// 日志弹窗：等宽全选复制（粘给排查用）+ 一键复制全部 + 清空。
  Future<void> _showAlignLogs() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('墨迹对齐日志'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: SelectableText(
                _alignLogs.isEmpty ? '暂无日志（先合成一次）' : _alignLogs.join('\n'),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: _alignLogs.isEmpty
                  ? null
                  : () => setDialogState(_alignLogs.clear),
              child: const Text('清空'),
            ),
            FilledButton.icon(
              onPressed: _alignLogs.isEmpty
                  ? null
                  : () {
                      Clipboard.setData(
                        ClipboardData(text: _alignLogs.join('\n')),
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('已复制 ${_alignLogs.length} 行对齐日志'),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    },
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('复制全部'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }

  /// 某页的画布变换：对齐结果里没有的页（未参与/分析失败）退化为
  /// "不转不移 + 全局缩放"，与画页口径一致。
  static const OverlayInkTransform _identityTransform =
      OverlayInkTransform.identity();

  OverlayInkTransform _pageTransform(int i) =>
      _inkAlignResult?.transformFor(i) ?? _identityTransform;

  // ── 坐标映射：页(像素) ↔ 画布(contain) ──

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

  static Rect _pageRectToCanvas(Rect r, Rect fit, Size pageSize) {
    final fw = math.max(fit.width, 0.001);
    final fh = math.max(fit.height, 0.001);
    return Rect.fromLTWH(
      fit.left + r.left / pageSize.width * fw,
      fit.top + r.top / pageSize.height * fh,
      r.width / pageSize.width * fw,
      r.height / pageSize.height * fh,
    );
  }

  /// 画布矩形 → 页面像素（写回）。[tr] 为该页的对齐变换（含全局缩
  /// 放），先逆变换回该页自己的 contain 画布坐标再线性映射——与画
  /// 页矩阵同一口径，画布上对齐后画的框换算到各页仍准确（旋转不为
  /// 零时取四角逆映射包围盒：宁可稍大不裁字）。
  static Rect _canvasRectToPage(
    Rect r,
    Rect fit,
    Size pageSize,
    Offset center, [
    OverlayInkTransform tr = _identityTransform,
  ]) {
    final un = tr.unmapRect(r, center);
    final fw = math.max(fit.width, 0.001);
    final fh = math.max(fit.height, 0.001);
    return Rect.fromLTWH(
      (un.left - fit.left) / fw * pageSize.width,
      (un.top - fit.top) / fh * pageSize.height,
      un.width / fw * pageSize.width,
      un.height / fh * pageSize.height,
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

  Offset _clampToCanvas(Offset p) => Offset(
    p.dx.clamp(0.0, _canvasW),
    p.dy.clamp(0.0, _canvasH == 0 ? 1600.0 : _canvasH),
  );

  // ── 类别草稿（统一设置模式与单页快设编辑器同一套语义）──

  /// 某类当前的框列表（无则空）。
  List<Rect> _rectsOf(String label) => _drafts[label] ?? const [];

  /// 当前框：当前类别第 [_activeIndex] 个（橙色边线 + 角点，可拖动/调
  /// 角，底色保持类别色）；**-1 = 未选中**。
  Rect? get _activeDraft {
    final list = _rectsOf(_activeLabel);
    return _activeIndex >= 0 && _activeIndex < list.length
        ? list[_activeIndex]
        : null;
  }

  /// 写回当前框几何（画/移动/缩放的手势更新路径；列表一定已存在——
  /// 画新框先经 _onPanStart 建列表）。
  set _activeDraft(Rect? value) {
    if (value == null) return;
    final list = _drafts[_activeLabel];
    if (list == null || _activeIndex < 0 || _activeIndex >= list.length) {
      return;
    }
    list[_activeIndex] = value;
  }

  /// 点击命中的（类别, 下标）：当前框优先，其余框——含同类非当前框与
  /// 其它类别——点框内即切换为当前框。
  ({String label, int index})? _hitDraft(Offset p) {
    final active = _activeDraft;
    if (active != null && active.contains(p)) {
      return (label: _activeLabel, index: _activeIndex);
    }
    for (final e in _drafts.entries) {
      for (var i = 0; i < e.value.length; i++) {
        if (e.value[i].contains(p)) return (label: e.key, index: i);
      }
    }
    return null;
  }

  /// 删除当前框（Del/「删除当前框」按钮，统一设置模式）：未选中时不
  /// 动任何框；同类还有别的框时当前框切到剩余的最后一条。
  void _removeActiveDraft() {
    if (_activeDraft == null) return;
    final list = _drafts[_activeLabel];
    if (list == null || list.isEmpty) return;
    list.removeAt(_activeIndex.clamp(0, list.length - 1));
    if (list.isEmpty) {
      _drafts.remove(_activeLabel);
      _activeIndex = 0;
    } else {
      _activeIndex = _activeIndex.clamp(0, list.length - 1);
    }
  }

  /// 误触（纯点击/过小拖动/指针被打断）回滚：截掉本次画框追加的部分，
  /// 恢复画前选中态。
  void _undoAccidentalDraw() {
    final list = _drafts[_activeLabel];
    final count = _preDrawCount;
    if (list != null && count != null && list.length > count) {
      list.removeRange(count, list.length);
    }
    if (list == null || list.isEmpty) {
      _drafts.remove(_activeLabel);
      _activeIndex = 0;
      return;
    }
    _activeIndex = (_preDrawActiveIndex ?? _activeIndex).clamp(
      0,
      list.length - 1,
    );
  }

  /// 画框结束/被打断的收尾：真正的框保留，误触回滚（统一设置模式按画
  /// 前快照截断；全书叠加模式过小的拖拽不留框）。
  void _finishDraw(DragEndDetails d) {
    if (_mode == _DragMode.draw) {
      final r = _activeDraft;
      if (r == null || r.width < 8 / _viewScale || r.height < 8 / _viewScale) {
        setState(() {
          if (_isQuick) {
            _undoAccidentalDraw();
          } else {
            _drafts.remove(RegionLabel.mainText);
          }
        });
      }
    }
    _mode = _DragMode.none;
    _drawOrigin = null;
    _preDrawCount = null;
    _preDrawActiveIndex = null;
  }

  void _onPanStart(DragStartDetails d) {
    final p = _clampToCanvas(d.localPosition);
    final rect = _activeDraft;
    final hitR = 14 / _viewScale;
    if (rect != null && rect.width > 0 && rect.height > 0) {
      if ((p - rect.topLeft).distance <= hitR) {
        _mode = _DragMode.resizeTL;
        return;
      }
      if ((p - rect.topRight).distance <= hitR) {
        _mode = _DragMode.resizeTR;
        return;
      }
      if ((p - rect.bottomLeft).distance <= hitR) {
        _mode = _DragMode.resizeBL;
        return;
      }
      if ((p - rect.bottomRight).distance <= hitR) {
        _mode = _DragMode.resizeBR;
        return;
      }
      if (rect.contains(p)) {
        _mode = _DragMode.move;
        return;
      }
    }
    // 点进其它框（其它类别或同类其它框）：切换为当前框并进入移动——
    // 不用回敲类别键也能调已有框（统一设置模式）。
    final hit = _isQuick ? _hitDraft(p) : null;
    if (hit != null) {
      setState(() {
        _activeLabel = hit.label;
        _activeIndex = hit.index;
      });
      _mode = _DragMode.move;
      return;
    }
    _mode = _DragMode.draw;
    _drawOrigin = p;
    setState(() {
      if (_isQuick) {
        // 统一设置：当前类别**追加**一条（同类可多个），并把当前框切
        // 到它；纯点击误触时靠 _preDrawCount 截断。
        final list = _drafts.putIfAbsent(_activeLabel, () => []);
        _preDrawCount = list.length;
        _preDrawActiveIndex = _activeIndex;
        _activeIndex = list.length;
        list.add(Rect.fromPoints(p, p));
      } else {
        // 全书叠加：拖出新框 = 正文区整框替换（原单矩形语义）。
        _drafts[RegionLabel.mainText] = [Rect.fromPoints(p, p)];
        _activeLabel = RegionLabel.mainText;
        _activeIndex = 0;
      }
    });
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final rect = _activeDraft;
    if (rect == null) return;
    setState(() {
      switch (_mode) {
        case _DragMode.none:
          break;
        case _DragMode.draw:
          _activeDraft = Rect.fromPoints(
            _drawOrigin!,
            _clampToCanvas(d.localPosition),
          );
        case _DragMode.move:
          final next = rect.shift(d.delta);
          // 移动不允许超出画布。
          final dx = next.left < 0
              ? -next.left
              : next.right > _canvasW
              ? _canvasW - next.right
              : 0.0;
          final dy = next.top < 0
              ? -next.top
              : next.bottom > _canvasH
              ? _canvasH - next.bottom
              : 0.0;
          _activeDraft = next.translate(dx, dy);
        case _DragMode.resizeTL:
          _activeDraft = Rect.fromPoints(
            rect.bottomRight,
            _clampToCanvas(d.localPosition),
          );
        case _DragMode.resizeTR:
          _activeDraft = Rect.fromPoints(
            rect.bottomLeft,
            _clampToCanvas(d.localPosition),
          );
        case _DragMode.resizeBL:
          _activeDraft = Rect.fromPoints(
            rect.topRight,
            _clampToCanvas(d.localPosition),
          );
        case _DragMode.resizeBR:
          _activeDraft = Rect.fromPoints(
            rect.topLeft,
            _clampToCanvas(d.localPosition),
          );
      }
    });
  }

  void _onPanEnd(DragEndDetails d) {
    _finishDraw(d);
  }

  // ── 应用 ──

  /// 统一设置确认弹窗：交代已画类别、范围页统计与"退回未确认"语义，
  /// 确认后进 [_runQuickApply]。范围页状态**先取回再构建对话框**——按
  /// 钮可用性与文案直接由数据驱动（若放进 FutureBuilder，其完成只重建
  /// 自己子树，外层 actions 读到的捕获变量永远是 null，按钮会恒灰）。
  Future<void> _showQuickApplyDialog() async {
    final totalRects = _drafts.values.fold<int>(0, (a, l) => a + l.length);
    if (totalRects == 0 || _canvasH <= 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('先在叠加图上拖出区域矩形（1~8 切类别）')));
      return;
    }
    final drawnDesc = [
      for (final label in RegionLabel.all)
        if (_rectsOf(label).isNotEmpty)
          '${RegionLabel.displayName(label)}×${_rectsOf(label).length}',
    ].join(' · ');
    // 进页即扫，此时通常早已完成；个别慢盘就等这一下（本地 JSON 读）。
    final scan = await _quickScanFuture!;
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('统一设置版面区（$_quickPageDesc）'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '已画：$drawnDesc',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '选定 ${_quickPages!.length} 页：'
                '可设 ${scan.pages.length} 页'
                '${scan.freshPages > 0 ? '（含无标注 ${scan.freshPages} 页，将新建标注）' : ''}'
                '${scan.proofreadSkip > 0 ? '，校对完成 ${scan.proofreadSkip} 页跳过' : ''}'
                '${scan.noMainSkip > 0 ? '，确认无正文 ${scan.noMainSkip} 页跳过' : ''}'
                '${scan.confirmedReset > 0 ? '；原主区已确认 ${scan.confirmedReset} 页' : ''}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 10),
              const Text(
                '各类别矩形按各页实际尺寸换算后整组替换：正文区替换'
                '该页正文区；页眉/页脚/页码等类别替换该类别（不做逐页'
                '判空，该页此位置无内容的框请翻页时删掉）。只写框、'
                '不识别；应用后写了正文的页一律退回未确认——请回主区'
                '快设逐页点开查看，核对无误后用「保存并下一页」自己确认。',
                style: TextStyle(fontSize: 13, height: 1.6),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: scan.pages.isEmpty
                ? null
                : () => Navigator.of(dialogContext).pop(true),
            child: Text(
              scan.pages.isEmpty
                  ? '范围内没有可设置的页'
                  : '开始统一设置 ${scan.pages.length} 页',
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _runQuickApply();
  }

  /// 统一设置写入循环：各类别草稿先收敛为逐页载荷（[quickApplyPayloadFrom]），
  /// 选定页逐页把画布矩形换算到页面像素，经 [BookOverlayPage.quickSavePage]
  /// （主区快设网格的 batch 保存 + 退回未确认）落盘；每页先防御性复查
  /// （扫描后标注可能刚被校对页级联 flush 改动）。完成弹出叠加页回到
  /// 网格逐页核对。
  Future<void> _runQuickApply() async {
    final (draftMains, draftExtras) = BookOverlayPage.quickApplyPayloadFrom(
      _drafts,
    );
    final scan = await _quickScanFuture!;
    if (!mounted) return;
    final payloadDesc = [
      if (draftMains != null) '正文×${draftMains.length}',
      for (final e in draftExtras.entries)
        '${RegionLabel.displayName(e.key)}×${e.value.length}',
    ].join('、');
    PythonService.addAppLog(
      '[主区快设·统一设置] 开始：$_quickPageDesc '
      '载荷（$payloadDesc）'
      '目标 ${scan.pages.length} 页'
      '${scan.proofreadSkip > 0 ? '，校对完成跳过 ${scan.proofreadSkip} 页' : ''}'
      '${scan.noMainSkip > 0 ? '，确认无正文跳过 ${scan.noMainSkip} 页' : ''}',
    );
    var cancel = false;
    var applied = 0;
    var confirmedReset = 0;
    var skipped = 0;
    final failed = <int>[];
    final total = scan.pages.length;
    StateSetter? setProgress;
    var done = 0;
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
              title: const Text('统一设置正文区'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(value: total == 0 ? 1 : done / total),
                  const SizedBox(height: 12),
                  Text(currentLabel),
                  const SizedBox(height: 4),
                  Text(
                    '已完成 $done / $total'
                    '${failed.isNotEmpty ? '，失败 ${failed.length}' : ''}',
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

    final project = widget.project;
    final canvasSize = Size(_canvasW, _canvasH);
    for (var k = 0; k < total && !cancel; k++) {
      final i = scan.pages[k];
      done = k;
      currentLabel = '第 ${i + 1} 页 …';
      setProgress?.call(() {});
      final imagePath = project.imageFiles[i];
      // 防御性复查（与按参考页适配同一保护口径）：扫描与应用之间正常
      // 无并发写入，校对页级联 flush 等例外时刻以盘为准——刚变成校对
      // 完成/确认无正文的页跳过，不被动改框。
      final existing = await ProjectStorage.loadAnnotation(
        project.projectDir,
        project.pageIdAt(i),
      );
      if (existing != null &&
          (existing.isFullyConfirmed ||
              existing.boxesReviewed ||
              existing.reviewed ||
              existing.noMainTextConfirmed)) {
        skipped++;
        continue;
      }
      final hadConfirmed =
          existing?.mainRegions.any(
            (r) =>
                RegionLabel.normalize(r.label) == RegionLabel.mainText &&
                r.boxConfirmed,
          ) ??
          false;
      final pageSize =
          await probeImageSize(imagePath) ??
          Size(_canvasW, _canvasH); // 拿不到尺寸按画布比例兜底
      final tr = _pageTransform(i);
      Rect mapRect(Rect r) => _canvasRectToPage(
            r,
            _fitRect(pageSize, canvasSize),
            pageSize,
            canvasSize.center(Offset.zero),
            tr,
          );
      final pageMains = draftMains == null
          ? null
          : [for (final r in draftMains) mapRect(r)];
      final pageExtras = <String, List<Rect>>{
        for (final e in draftExtras.entries)
          e.key: [for (final r in e.value) mapRect(r)],
      };
      if (await widget.quickSavePage!(i, pageMains, pageExtras)) {
        applied++;
        if (hadConfirmed) confirmedReset++;
      } else {
        failed.add(i);
      }
    }
    done = total;
    if (!cancel && mounted) {
      Navigator.of(context).pop();
    }
    await progressFuture;
    if (!mounted) return;
    PythonService.addAppLog(
      '[主区快设·统一设置] 结束${cancel ? '（用户停止）' : ''}：'
      '写入 $applied / $total 页'
      '（原已确认 $confirmedReset 页一并退回未确认）'
      '${skipped > 0 ? '，应用时跳过 $skipped 页' : ''}'
      '${failed.isNotEmpty ? '，失败 ${failed.length} 页（写入回调已记日志）' : ''}',
    );
    if (applied == 0) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('未写入任何页'),
          content: Text(
            total == 0
                ? '指定范围内没有可设置的页（都已校对完成或确认无正文）。'
                : cancel
                ? '已停止，未写入任何页。'
                : failed.length >= total
                ? '目标页全部写入失败，详见后台日志。'
                : '目标页在应用时都已变为校对完成/确认无正文，未改写。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${cancel ? '已停止：' : ''}统一设置完成：写入 $applied / $total 页'
          '${confirmedReset > 0 ? '（原已确认 $confirmedReset 页一并退回未确认）' : ''}'
          '${failed.isNotEmpty ? '，失败 ${failed.length} 页' : ''}'
          '——均为待确认候选，请逐页查看后自己确认',
        ),
      ),
    );
    // 回主区快设网格逐页核对（网格内存态已随写入同步，无需重读）。
    Navigator.of(context).pop(true);
  }

  Future<void> _showApplyDialog() async {
    final rect = _draftRect;
    if (rect == null || _canvasH <= 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('先在叠加图上拖出一个正文区矩形')));
      return;
    }
    var cascade = false;
    BookApplyTargets? targets;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('批量应用正文区（所有未保存页）'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FutureBuilder<BookApplyTargets>(
                  future: _targetsFuture,
                  builder: (context, snapshot) {
                    final t = snapshot.data;
                    if (t == null) {
                      return const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 10),
                          Text(
                            '正在统计全书页状态…',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        ],
                      );
                    }
                    targets = t;
                    final annotated = t.pages.length;
                    final unrecognized = t.unrecognizedPages.length;
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '本书共 $_pageCount 页：已确认 ${t.confirmed} 页、'
                          '未识别 $unrecognized 页、'
                          '未保存有标注 $annotated 页。',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 8),
                        RadioGroup<bool>(
                          groupValue: cascade,
                          onChanged: (v) =>
                              setDialogState(() => cascade = v ?? false),
                          child: Column(
                            children: [
                              RadioListTile<bool>(
                                value: false,
                                title: const Text('只改框（不重识别）'),
                                subtitle: Text(
                                  '秒级完成；只改 $annotated 页有标注的未保存页'
                                  '（行/段/字框原样保留），未识别页不动',
                                ),
                                dense: true,
                              ),
                              RadioListTile<bool>(
                                value: true,
                                title: const Text('改框并按新区重识别行/字'),
                                subtitle: Text(
                                  '逐页调后端（每页数秒到数十秒）；'
                                  '${annotated + unrecognized} 页全部应用，'
                                  '未识别 $unrecognized 页按新区识别建标注；'
                                  '手工/已确认行保留',
                                ),
                                dense: true,
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: targets == null
                  ? null
                  : () => Navigator.of(dialogContext).pop(true),
              child: const Text('开始应用'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || targets == null) return;
    await _runApply(rect: rect, cascade: cascade, targets: targets!);
  }

  /// 全书扫描统计批量应用范围：未保存页 = 有标注且未「确认识别框 /
  /// 确认并保存」（与叠加显示/跳过口径一致，旧版只带 reviewed 的页也算
  /// 已确认）。已确认与未识别页计入统计，未识别页号单独成表（级联
  /// 模式会纳入并按新区识别）。
  Future<BookApplyTargets> _scanTargets() async {
    var confirmed = 0;
    final pages = <int>[];
    final unrecognizedPages = <int>[];
    for (var i = 0; i < _pageCount; i++) {
      final ann = await ProjectStorage.loadAnnotation(
        widget.project.projectDir,
        widget.project.pageIdAt(i),
      );
      if (ann == null) {
        unrecognizedPages.add(i);
      } else if (ann.boxesReviewed || ann.reviewed) {
        confirmed++;
      } else {
        pages.add(i);
      }
    }
    return (
      confirmed: confirmed,
      pages: pages,
      unrecognizedPages: unrecognizedPages,
    );
  }

  Future<void> _runApply({
    required Rect rect,
    required bool cascade,
    required BookApplyTargets targets,
  }) async {
    // 级联模式把未识别页也纳入（新建标注 + 按新区识别）；只改框只能
    // 改有标注的页。
    final targetPages = cascade
        ? ([...targets.pages, ...targets.unrecognizedPages]..sort())
        : targets.pages;
    PythonService.addAppLog(
      '[全书叠加] 开始应用：模式=${cascade ? '改框并重识别' : '只改框'} '
      'rect=(${rect.left.toInt()},${rect.top.toInt()},'
      '${rect.width.toInt()},${rect.height.toInt()}) '
      '目标=${targetPages.length} 页'
      '（已确认 ${targets.confirmed} 页不参与'
      '${cascade ? '' : '，未识别 ${targets.unrecognizedPages.length} 页不参与'}）',
    );
    var cancel = false;
    var changed = 0;
    var freshPages = 0;
    final failed = <int>[];
    final total = targetPages.length;
    StateSetter? setProgress;
    var done = 0;
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
              title: Text(cascade ? '批量应用（重识别）' : '批量应用（只改框）'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(value: total == 0 ? 1 : done / total),
                  const SizedBox(height: 12),
                  Text(currentLabel),
                  const SizedBox(height: 4),
                  Text(
                    '已完成 $done / $total'
                    '${failed.isNotEmpty ? '，失败 ${failed.length}' : ''}',
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

    final project = widget.project;
    final canvasSize = Size(_canvasW, _canvasH);
    for (var k = 0; k < targetPages.length; k++) {
      if (cancel) break;
      final i = targetPages[k];
      done = k;
      currentLabel = '第 ${i + 1} 页 …';
      setProgress?.call(() {});
      final existing = await ProjectStorage.loadAnnotation(
        project.projectDir,
        project.pageIdAt(i),
      );
      final imagePath = project.imageFiles[i];
      // 与扫描口径一致的防御性复查：扫描与应用之间无并发写入，正常
      // 不会命中。未识别页只在级联模式下出现在目标列表里（新建标注）。
      PageAnnotation ann;
      if (existing == null) {
        if (!cascade) continue;
        ann = PageAnnotation(pageId: project.pageIdAt(i), imagePath: imagePath);
        freshPages++;
      } else if (existing.boxesReviewed || existing.reviewed) {
        continue;
      } else {
        ann = existing;
      }
      final pageSize =
          await probeImageSize(imagePath) ??
          Size(_canvasW, _canvasH); // 拿不到尺寸按画布比例兜底
      final pageRect = _canvasRectToPage(
        rect,
        _fitRect(pageSize, canvasSize),
        pageSize,
        canvasSize.center(Offset.zero),
        _pageTransform(i),
      );
      try {
        if (cascade) {
          var ok = false;
          // 后端识别全局锁：忙（409）时稍候重试，几轮仍拿不到锁按失败计。
          for (var attempt = 0; attempt < 6 && !ok && !cancel; attempt++) {
            try {
              await BookRegionApply.applyRegionWithCascade(
                ann: ann,
                imagePath: imagePath,
                rect: pageRect,
                settings: project.settingsAt(i),
              );
              ok = true;
            } on RecognitionBusyException {
              await Future<void>.delayed(const Duration(milliseconds: 700));
            }
          }
          if (!ok) throw StateError('识别服务忙，未完成');
        } else {
          BookRegionApply.applyRegionOnly(ann, pageRect);
        }
        ann.draftSaved = true;
        await ProjectStorage.saveAnnotation(project.projectDir, ann);
        changed++;
      } catch (error) {
        failed.add(i);
        PythonService.addAppLog(
          '[全书叠加] 第 ${i + 1} 页应用失败：$error',
          isError: true,
        );
      }
    }
    done = total;
    // 正常跑完由这里关进度框；用户点过「停止」则框已关闭，不能再 pop
    // （否则会把叠加页本身弹掉）。
    if (!cancel && mounted) {
      Navigator.of(context).pop();
    }
    await progressFuture;
    if (!mounted) return;
    PythonService.addAppLog(
      '[全书叠加] 应用结束${cancel ? '（用户停止）' : ''}：改写 $changed / $total 页'
      '${failed.isNotEmpty ? '，失败 ${failed.length} 页' : ''}',
    );
    if (changed > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${cancel ? '已停止：' : ''}批量应用完成：改写 $changed / $total 页'
            '${freshPages > 0 ? '（含新建标注 $freshPages 页）' : ''}'
            '${targets.confirmed > 0 ? '，已确认 ${targets.confirmed} 页不参与' : ''}'
            '${failed.isNotEmpty ? '，失败 ${failed.length} 页（见后台日志）' : ''}',
          ),
        ),
      );
      Navigator.of(context).pop(true);
      return;
    }
    // 一个字都没写进盘：不能只靠一闪而过的 SnackBar，明确告诉用户原因。
    final reason = total == 0
        ? '全书没有可应用的未保存页（都已确认或未识别）。'
        : failed.length >= total
        ? '目标页全部失败，详见后台日志。'
        : '目标页在应用时都已变为已确认状态，未改写。';
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('未改写任何页'),
        content: Text(reason),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  // ── build ──

  /// 快捷键 1~8 与小键盘 1~8：切换「当前类别」（与单页快设编辑器同一
  /// 词表，键数与 RegionLabel 词表长度对齐）；Del 删除当前框。
  static const List<LogicalKeyboardKey> _digitKeys = [
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
    LogicalKeyboardKey.digit9,
    LogicalKeyboardKey.numpad1,
    LogicalKeyboardKey.numpad2,
    LogicalKeyboardKey.numpad3,
    LogicalKeyboardKey.numpad4,
    LogicalKeyboardKey.numpad5,
    LogicalKeyboardKey.numpad6,
    LogicalKeyboardKey.numpad7,
    LogicalKeyboardKey.numpad8,
    LogicalKeyboardKey.numpad9,
  ];

  /// 统一设置模式的键盘绑定（全书叠加模式不绑，保持原交互零变化）。
  Widget _bindShortcuts(Widget child) {
    if (!_isQuick) return child;
    final bindings = <ShortcutActivator, VoidCallback>{};
    final digitCount = _digitKeys.length ~/ 2; // 每类两个键（主数字 + 小键盘）
    for (var i = 0; i < RegionLabel.all.length && i < digitCount; i++) {
      final label = RegionLabel.all[i];
      void select() => setState(() {
        _activeLabel = label;
        _activeIndex = 0; // 切类别回到该类第一个框
      });
      bindings[SingleActivator(_digitKeys[i])] = select;
      bindings[SingleActivator(_digitKeys[i + digitCount])] = select;
    }
    bindings[const SingleActivator(LogicalKeyboardKey.delete)] = () =>
        setState(_removeActiveDraft);
    return CallbackShortcuts(
      bindings: bindings,
      child: Focus(autofocus: true, child: child),
    );
  }

  /// 墨迹对齐开关与状态行（两种模式共用同一合成管线，故都显示）。
  /// 低置信页存在时状态转橙，提示叠加里混着未偏移的页。
  Widget _buildInkAlignRow() {
    final r = _inkAlignResult;
    String status;
    if (!_inkAlign) {
      status = '关：各页按原样 contain 叠加';
    } else if (_composing) {
      status = '分析中…';
    } else if (r == null || r.referencePage < 0) {
      status = '可分析页不足，未对齐';
    } else {
      status =
          '参考第 ${r.referencePage + 1} 页 · 对齐 ${r.alignedCount}/${r.byPage.length} 页'
          '${r.lowConfidenceCount > 0 ? ' · 低置信 ${r.lowConfidenceCount} 页未偏移' : ''}'
          '${r.globalScale < 1 ? ' · 整体缩 ${(r.globalScale * 100).round()}%' : ''}';
    }
    return Row(
      children: [
        const Text('墨迹对齐'),
        SizedBox(
          height: 30,
          child: Switch(
            value: _inkAlign,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: _composing
                ? null
                : (v) {
                    setState(() => _inkAlign = v);
                    _recompose();
                  },
          ),
        ),
        // 对齐方式切换：特征点匹配 + RANSAC（新法，默认）与投影互相关
        //（旧法）互为对比与回退，输出同一套变换。
        Padding(
          padding: const EdgeInsets.only(right: 6),
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                value: false,
                label: Text('投影', style: TextStyle(fontSize: 11)),
              ),
              ButtonSegment(
                value: true,
                label: Text('特征点', style: TextStyle(fontSize: 11)),
              ),
            ],
            selected: {_featureAlign},
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onSelectionChanged: _composing || !_inkAlign
                ? null
                : (selection) {
                    setState(() => _featureAlign = selection.first);
                    _recompose();
                  },
          ),
        ),
        Expanded(
          child: Text(
            status,
            style: TextStyle(
              fontSize: 12,
              color: (_inkAlign && r != null && r.lowConfidenceCount > 0)
                  ? Colors.orange
                  : Colors.grey,
            ),
          ),
        ),
        // 逐页对齐日志（旋转/平移/置信度/原因），弹窗内可全选或一键
        // 复制——排查"看着没对齐"直接把日志粘出来对照。
        IconButton(
          icon: const Icon(Icons.receipt_long),
          iconSize: 18,
          tooltip: '对齐日志（可复制）',
          visualDensity: VisualDensity.compact,
          onPressed: _showAlignLogs,
        ),
      ],
    );
  }

  /// 类别快切栏（单页快设编辑器同款：色点 + 名 + 数字键提示）——统一
  /// 设置模式画的不只正文区，页眉/页脚/页码等同样可框、整组写入。
  Widget _buildCategoryBar() {
    return SizedBox(
      height: 40,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < RegionLabel.all.length; i++)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Tooltip(
                  message: '切换到该类别：拖拽画框/调整都作用于它（快捷键 ${i + 1}）',
                  child: ChoiceChip(
                    avatar: Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: RegionLabel.color(RegionLabel.all[i]),
                        shape: BoxShape.circle,
                      ),
                    ),
                    label: Text(
                      '${RegionLabel.displayName(RegionLabel.all[i])} ${i + 1}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    selected: _activeLabel == RegionLabel.all[i],
                    visualDensity: VisualDensity.compact,
                    showCheckmark: false,
                    onSelected: (_) => setState(() {
                      _activeLabel = RegionLabel.all[i];
                      _activeIndex = 0; // 切类别回到该类第一个框
                    }),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _bindShortcuts(
      Scaffold(
        appBar: AppBar(
          title: Text(
            _isQuick
                ? '指定页叠加 · $_quickPageDesc · ${widget.project.name}'
                : '全书叠加 · ${widget.project.name}',
          ),
          bottom: PreferredSize(
            preferredSize: Size.fromHeight(_isQuick ? 170 : 126),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_isQuick) _buildCategoryBar(),
                  _buildInkAlignRow(),
                  if (_isQuick)
                    // 统一设置：页表是进画布前选定的（可离散），叠加窗口就
                    // 是这份页表（没有窗口滑杆），这里只交代范围与透明度。
                    Row(
                      children: [
                        Text(
                          '叠加 $_quickPageDesc · '
                          '参与 $_participating / ${_quickPages!.length} 页',
                        ),
                        const SizedBox(width: 16),
                        const Text('透明度'),
                        Expanded(
                          child: Slider(
                            value: _pageAlpha,
                            min: 0.02,
                            max: 1.0,
                            label: _pageAlpha.toStringAsFixed(2),
                            onChanged: _composing
                                ? null
                                : (v) => setState(
                                    () => _pageAlpha = v.toDouble(),
                                  ),
                            onChangeEnd: _composing
                                ? null
                                : (_) => _recompose(),
                          ),
                        ),
                      ],
                    )
                  else
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
                          onPressed: _composing || _windowStart >= _pageCount - 1
                              ? null
                              : () => _setWindowStart(_windowStart + 1),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Row(
                            children: [
                              Text(
                                '叠加 $_participating / '
                                '${math.max(0, _windowEnd - _windowStart)} 页',
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
                                      : (v) => setState(
                                          () => _pageAlpha = v.toDouble(),
                                        ),
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
                  Text(
                    _isQuick
                        ? '统一设置：应用只写入叠加范围 · '
                              '空白处拖拽画当前类别框（同类可多个）/ 抓角点调整 / '
                              '框内拖动移动 · 单击框选中、点空白取消 · 1~8 切类别 · '
                              'Del 删当前框 · 右键平移 · 滚轮缩放 · 只写框不识别，'
                              '写了正文的页设置后一律退回未确认，请逐页查看后自己确认'
                        : '左键拖动画框/移动/拖角点调整 · 右键拖动平移 · 滚轮缩放 · '
                              '虚线 = 参与页现有主区并集 · 已「确认识别框」的页不参与叠加',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),
        ),
        bottomNavigationBar: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              if (_isQuick) ...[
                // 统一设置：删除当前类别的当前框（Del 同一动作）。
                OutlinedButton(
                  onPressed: _activeDraft == null
                      ? null
                      : () => setState(_removeActiveDraft),
                  child: const Text('删除当前框'),
                ),
                const SizedBox(width: 8),
              ],
              OutlinedButton(
                onPressed: () => _transform.value = Matrix4.identity(),
                child: const Text('重置视图'),
              ),
              OutlinedButton(
                onPressed: _composing ? null : _recompose,
                child: const Text('重新合成'),
              ),
              const Spacer(),
              if (_composing)
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: Text(
                    '合成中 $_composeDone 页 …',
                    style: const TextStyle(color: Colors.grey),
                  ),
                ),
              FilledButton.icon(
                onPressed: _isQuick ? _showQuickApplyDialog : _showApplyDialog,
                icon: const Icon(Icons.done_all),
                label: Text(_isQuick ? '统一设置到指定页' : '应用到未保存页'),
              ),
            ],
          ),
        ),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 记录视口尺寸供首次合成后的整页适配缩放用（合成期间也要
        // 捕获，否则首帧拿不到）。
        _viewportSize = constraints.biggest;
        if (_composing && _composite == null) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 12),
                Text('正在$_composePhase $_composeDone / $_composeTotal 页 …'),
              ],
            ),
          );
        }
        final canvasH = _canvasH <= 0 ? _canvasW * 1.4 : _canvasH;
        return Stack(
          children: [
            Positioned.fill(
              child: Listener(
                // 右键拖动平移（编辑器同款习惯），左键留给画布上的矩形手势。
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
                  // 画布保持自身尺寸（1200×H）：constrained 默认 true 会把
                  // 子组件压成视口大小，画布比例被破坏表现为书页拉伸。
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
                    // 指针被系统打断（窗口失焦等）：画到一半的框不留，
                    // 统一设置模式按画前快照截断。
                    onPanCancel: () => _finishDraw(DragEndDetails()),
                    // 纯点击（无位移）不会触发 pan（识别器未过 slop 即在
                    // 竞技场出局）：单击空白 = 取消选择当前框，单击某个
                    // 框 = 选中它——拖拽调整照旧走 pan（统一设置模式）。
                    onTapUp: _isQuick
                        ? (d) {
                            final p = _clampToCanvas(d.localPosition);
                            final hit = _hitDraft(p);
                            setState(() {
                              if (hit == null) {
                                _activeIndex = -1;
                              } else {
                                _activeLabel = hit.label;
                                _activeIndex = hit.index;
                              }
                            });
                          }
                        : null,
                    child: SizedBox(
                      width: _canvasW,
                      height: canvasH,
                      child: CustomPaint(
                        painter: _OverlayPainter(
                          composite: _composite,
                          unionRect: _unionRect,
                          drafts: _drafts,
                          activeLabel: _activeLabel,
                          activeIndex: _activeIndex,
                          viewScale: _viewScale,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (!_composing && _participating == 0)
              Center(
                child: Card(
                  color: Colors.black87,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      '当前窗口内的书页都已确认（确认识别框/确认并保存），'
                      '不参与叠加修改。\n'
                      '换一个窗口，或先在编辑器「更多操作 → 本书重置为未确认」。',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  void _setWindowStart(int value) {
    // clamp 配 math.max 会把返回类型推成 num，显式 toInt 收敛。
    final clamped = value.clamp(0, math.max(0, _pageCount - 1)).toInt();
    setState(() => _windowStart = clamped);
    _recompose();
  }

  void _setWindowSize(int value) {
    final clamped = value.clamp(4, _windowSliderMax);
    setState(() {
      _windowSize = clamped;
      // 页数变化后按"每页均匀可见"重置透明度。
      _pageAlpha = (1 / clamped).clamp(0.02, 1.0);
    });
    _recompose();
  }
}

enum _DragMode { none, draw, move, resizeTL, resizeTR, resizeBL, resizeBR }

/// 叠加画画笔：合成底图 + 现有主区并集（虚线）+ 各类别草稿——当前框
/// 橙色（底色保持类别色，边线角点标橙），其余框（含同类非当前框与其
/// 它类别）按 [RegionLabel.color] 细线 + 类别名小标签（屏幕恒定大小）。
class _OverlayPainter extends CustomPainter {
  _OverlayPainter({
    required this.composite,
    required this.unionRect,
    required this.drafts,
    required this.activeLabel,
    required this.activeIndex,
    required this.viewScale,
  });

  final ui.Image? composite;
  final Rect? unionRect;

  /// 各类草稿（label → 矩形列表，画布坐标）。
  final Map<String, List<Rect>> drafts;

  /// 当前编辑类别与框下标：对应框画橙色边线带角点，其余画细线。
  final String activeLabel;
  final int activeIndex;
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
    // 线宽按屏幕视觉恒定：画布坐标除以当前缩放。
    final unit = 1.0 / math.max(viewScale, 0.001);
    final union = unionRect;
    if (union != null) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.tealAccent.withValues(alpha: 0.9)
        ..strokeWidth = 1.2 * unit;
      _dashRect(canvas, union, paint);
    }
    Rect? active;
    final activeList = drafts[activeLabel];
    if (activeList != null &&
        activeIndex >= 0 &&
        activeIndex < activeList.length) {
      active = activeList[activeIndex];
    }
    // 非当前框（含同类非当前框与其它类别）：细线 + 微填充 + 类别名标签。
    for (final e in drafts.entries) {
      final color = RegionLabel.color(e.key);
      for (var i = 0; i < e.value.length; i++) {
        final rect = e.value[i];
        if (e.key == activeLabel && i == activeIndex) continue;
        if (rect.width <= 0 || rect.height <= 0) continue;
        canvas.drawRect(rect, Paint()..color = color.withValues(alpha: 0.08));
        canvas.drawRect(
          rect,
          Paint()
            ..style = PaintingStyle.stroke
            ..color = color
            ..strokeWidth = 1.5 * unit,
        );
        _drawLabelTag(
          canvas,
          RegionLabel.displayName(e.key),
          rect.topLeft + Offset(3 * unit, 3 * unit),
          color,
          unit,
        );
      }
    }
    final draft = active;
    if (draft != null && draft.width > 0 && draft.height > 0) {
      canvas.drawRect(
        draft,
        Paint()
          ..style = PaintingStyle.fill
          ..color = RegionLabel.color(activeLabel).withValues(alpha: 0.10),
      );
      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.orange
        ..strokeWidth = 2.0 * unit;
      canvas.drawRect(draft, stroke);
      final handle = Paint()..color = Colors.orange;
      final rim = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 * unit
        ..color = Colors.white;
      for (final corner in [
        draft.topLeft,
        draft.topRight,
        draft.bottomLeft,
        draft.bottomRight,
      ]) {
        canvas.drawCircle(corner, 6 * unit, handle);
        canvas.drawCircle(corner, 6 * unit, rim);
      }
    }
  }

  /// 类别名小标签：底色圆角块 + 白字，字号随缩放反向补偿保持屏幕恒定。
  void _drawLabelTag(
    Canvas canvas,
    String text,
    Offset topLeft,
    Color color,
    double unit,
  ) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: Colors.white, fontSize: 11 * unit, height: 1.0),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final pad = 2.5 * unit;
    final rect = Rect.fromLTWH(
      topLeft.dx,
      topLeft.dy,
      tp.width + pad * 2,
      tp.height + pad * 2,
    );
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(3 * unit));
    canvas.drawRRect(rrect, Paint()..color = color.withValues(alpha: 0.85));
    tp.paint(canvas, Offset(rect.left + pad, rect.top + pad));
  }

  void _dashRect(Canvas canvas, Rect rect, Paint paint) {
    final path = Path()..addRect(rect);
    final metric = path.computeMetrics().first;
    final dashed = Path();
    const dash = 10.0, gap = 7.0;
    var dist = 0.0;
    while (dist < metric.length) {
      final next = math.min(dist + dash, metric.length);
      dashed.addPath(metric.extractPath(dist, next), Offset.zero);
      dist = next + gap;
    }
    canvas.drawPath(dashed, paint);
  }

  @override
  bool shouldRepaint(_OverlayPainter old) =>
      old.composite != composite ||
      old.unionRect != unionRect ||
      old.activeLabel != activeLabel ||
      old.activeIndex != activeIndex ||
      old.viewScale != viewScale ||
      !_draftsEquals(old.drafts, drafts);
}

bool _draftsEquals(Map<String, List<Rect>> a, Map<String, List<Rect>> b) {
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    final other = b[e.key];
    if (other == null || !listEquals(other, e.value)) return false;
  }
  return true;
}
