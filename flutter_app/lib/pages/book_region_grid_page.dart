import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../models/page_quad.dart';
import '../services/annotation_hit_geometry.dart';
import '../services/book_region_apply.dart';
import '../services/image_probe.dart';
import '../services/mouse_gesture.dart';
import '../services/ollama_service.dart';
import '../services/page_state_markers.dart';
import '../services/python_service.dart';
import '../services/recognition_queue.dart';
import '../services/storage.dart';
import '../widgets/floating_monitor_window.dart';
import '../widgets/page_thumb_cache.dart';
import 'book_overlay_page.dart';
import 'book_region_reference_apply.dart';
import 'straighten_page.dart';

/// 主区快设网格（编辑器工具栏入口）：与「全书总览」同一套缩略图网格。
/// 缩略图上左键拖拽即可直接画出该页正文区（松手保存，只写主区几何，
/// 不触发识别解析），单击打开单页大图精修（框内拖动移动、拖角点调整
/// 适合精确绘制）。改完后点「拆分主区已确认的 N 页」：对全书**主区已
/// 确认**（绿色"已确认"角标）且**非整页绿框**（没做过「确认并保存」）
/// 的页逐页调后端重识别——主区内分行/拆字 + OCR，再按版式方向重建自
/// 然段（合并规则与编辑器主区级联同一份 [BookRegionApply]，手工调整
/// 过/已确认的行不会被覆盖）；整页绿框的校对成果不动。
///
/// 与「全书叠加」的分工：叠加适合"全书共用一个矩形"的批量场景；这里
/// 逐页独立成框，适合逐页版心不一、需要快速过一遍全书的场景。反过来，
/// 一段页面（几十页）版式一致又不想逐页画时，用底部「指定页叠加」：
/// 范围页叠成一张图统一设一个正文区（只写框不识别、**设置后一律退回
/// 未确认**，逐页查看后自己确认）。批量写框试错后用「清除未确认页框」
/// 一键清空重来——只清无绿色角标（主区未确认）的页，已认可/校对完成
/// 的框不碰。
class BookRegionGridPage extends StatefulWidget {
  const BookRegionGridPage({super.key, required this.project});

  final Project project;

  /// 「按主区拆分」目标页的纯函数本体（供单测）：加载中返回空；全书
  /// 扫描——**主区已确认**（全部 main_text 区 boxConfirmed——多主区页
  /// 如未裁开的双页一条没确认过就不算，即网格绿色"已确认"角标）且
  /// **非页面级确认**（既没「确认并保存」过
  /// [isFullyConfirmed，整页绿框]、也没「确认识别框」过
  /// [boxesReviewed，玫红框]）的页入队。主区未确认（只画没确认）的页
  /// 不拆——主区还没被认可；无正文主区的页（扉页/插图）恒不入队。
  static List<int> splitTargetsFrom({
    required bool loading,
    required Map<int, PageAnnotation> annotations,
    required int pageCount,
  }) {
    if (loading) return const [];
    final targets = <int>[];
    for (var i = 0; i < pageCount; i++) {
      final ann = annotations[i];
      if (ann == null) continue;
      // 整页绿框（确认并保存）或玫红框（确认识别框）：页面级确认
      // 成果保护，不重拆。
      if (ann.isFullyConfirmed || ann.boxesReviewed) continue;
      // 主区已确认 = 有正文主区且**全部** boxConfirmed：多主区页（未
      // 裁开的双页）一条没确认过就不整页算确认。
      var hasBody = false;
      var allConfirmed = true;
      for (final r in ann.mainRegions) {
        if (RegionLabel.normalize(r.label) == RegionLabel.mainText) {
          hasBody = true;
          if (!r.boxConfirmed) allConfirmed = false;
        }
      }
      if (!hasBody || !allConfirmed) continue;
      targets.add(i);
    }
    return targets;
  }

  /// 页面"已确认"判定本体（网格绿色角标 / 「隐藏已确认」同一口径）：
  /// [_regionConfirmedAt] 与 [prelabelTargetsFrom] 共用，供单测。
  static bool pageRegionConfirmed(PageAnnotation? ann) {
    if (ann == null) return false;
    var hasBody = false;
    var allConfirmed = true;
    for (final r in ann.mainRegions) {
      if (RegionLabel.normalize(r.label) == RegionLabel.mainText) {
        hasBody = true;
        if (!r.boxConfirmed) allConfirmed = false;
      }
    }
    if (hasBody) return allConfirmed;
    return ann.noMainTextConfirmed;
  }

  /// 「自动加页眉/页脚候选框」的目标页（供单测）：加载中返回空；范围选
  /// 「全部页面」返回全部下标，「仅未确认页面」剔除绿色"已确认"角标的
  /// 页（无标注的页视为未确认，照加）。
  static List<int> prelabelTargetsFrom({
    required bool loading,
    required Map<int, PageAnnotation> annotations,
    required int pageCount,
    required bool unconfirmedOnly,
  }) {
    if (loading) return const [];
    if (!unconfirmedOnly) {
      return List<int>.generate(pageCount, (i) => i);
    }
    return [
      for (var i = 0; i < pageCount; i++)
        if (!pageRegionConfirmed(annotations[i])) i,
    ];
  }

  /// 「清除未确认页框」的判定本体（供单测）：有框（版面区/行/字/段落/
  /// 表格任一非空）、**无绿色"已确认"角标**（主区未确认；「确认无正文」
  /// 的页同样算已认可）且**非校对完成**（整页绿框/玫红框/旧版 reviewed）
  /// 的页才清——人工认可过的框不被批量清除。页级口径：主区未确认的页
  /// 即使个别页眉框被确认过也整页清（用户要求的"所有识别框"粒度）。
  static bool shouldClearUnconfirmedBoxes(PageAnnotation? ann) {
    if (ann == null) return false;
    if (ann.isFullyConfirmed || ann.boxesReviewed || ann.reviewed) {
      return false;
    }
    if (pageRegionConfirmed(ann)) return false;
    return ann.mainRegions.isNotEmpty ||
        ann.lines.isNotEmpty ||
        ann.paragraphs.isNotEmpty ||
        ann.blocks.isNotEmpty ||
        ann.tables.isNotEmpty;
  }

  @override
  State<BookRegionGridPage> createState() => _BookRegionGridPageState();
}

class _BookRegionGridPageState extends State<BookRegionGridPage> {
  /// 格大小档位对应的目标格宽（逻辑像素），与全书总览一致。
  static const List<double> _tierWidths = [160, 240, 360, 520];
  static const List<String> _tierLabels = ['小', '中', '大', '特大'];

  final Map<int, PageAnnotation> _annotations = {};

  /// 各页原始像素尺寸（主区映射与缩略图画框的坐标基准）。
  final Map<int, Size> _pageSizes = {};
  final PageThumbCache _thumbCache = PageThumbCache();
  final Map<int, int> _regionRevisions = {};
  PageStateMarkers _markers = PageStateMarkers();

  /// 本次快设中改过主区的页（保存即记），拆分成功后清空，失败页保留
  /// 以便重试。
  final Set<int> _modified = {};

  /// 本页任何落盘动作（改框保存/预标注/后台拆分完成/摆正）都置位：返回
  /// 时作为路由返回值传给校对编辑器，编辑器据此重读盘。
  bool _diskTouched = false;

  /// 后台拆分任务观察态：上一帧的剩余页集合（diff 出"刚处理完的页"）
  /// 与"上一帧是否有拆分任务在队"（任务结束时整体刷新）。
  Set<int>? _lastJobRemaining;
  bool _wasJobLive = false;

  /// 跨会话断点（region_split_progress.json）：无任务在队时提供
  /// 「继续拆分剩余 N 页」。
  RegionSplitResume? _resumeInfo;

  int _sizeTier = 1;
  int _loadedCount = 0;
  bool _loading = true;

  /// 本书当前的后台拆分任务快照（识别任务的快照不归本页管，返回 null）。
  RecognitionProgress? get _splitJob {
    final s = RecognitionQueue.instance.progressFor(widget.project.id);
    return s != null && s.kind == RecognitionProgress.kindRegionSplit
        ? s
        : null;
  }

  /// 拆分任务进行中（排队/运行/正在停止）：页面相关编辑全部锁定。
  /// 判定收敛在 RecognitionQueue.isRegionSplitActive（校对编辑器的
  /// dispose 落盘避让也用同一份语义）。
  bool get _splitJobActive =>
      RecognitionQueue.instance.isRegionSplitActive(widget.project.id);

  /// 拆分任务已停/有失败页：可从断点继续。
  bool get _splitJobResumable {
    final s = _splitJob;
    return s != null &&
        (s.status == RecognitionProgress.paused ||
            s.status == RecognitionProgress.failed);
  }

  /// 被后台任务锁定（禁止编辑/进单页编辑器）的页。
  Set<int> get _lockedPages =>
      _splitJobActive ? {...?_splitJob?.jobPages} : const <int>{};

  @override
  void initState() {
    super.initState();
    _loadAll();
    _loadResumeInfo();
    RecognitionQueue.instance.addListener(_onQueueChanged);
    // 「隐藏已确认」开关与「自动加候选框」范围选择的持久化状态（上次
    // 退出时的选择）。
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      final hide = prefs.getBool(_prefHideConfirmed);
      final scope = prefs.getBool(_prefPrelabelUnconfirmedOnly);
      if (hide == null && scope == null) return;
      setState(() {
        if (hide != null) _hideConfirmed = hide;
        if (scope != null) _prelabelUnconfirmedOnly = scope;
      });
    });
  }

  @override
  void dispose() {
    RecognitionQueue.instance.removeListener(_onQueueChanged);
    _thumbCache.dispose();
    super.dispose();
  }

  Future<void> _loadResumeInfo() async {
    final info = await RecognitionQueue.loadRegionSplitResume(
      widget.project.projectDir,
    );
    if (!mounted) return;
    setState(() => _resumeInfo = info);
  }

  /// 后台任务进度变化：diff 剩余页集合，刚处理完的页立即重读标注刷新
  /// 格子；任务结束时整体刷新状态标记。全部走盘上事实。
  void _onQueueChanged() {
    if (!mounted) return;
    final job = _splitJob;
    final live = job != null;
    final remaining = live && _splitJobActive
        ? job.remainingPages.toSet()
        : null;
    final justDone = <int>[];
    if (_lastJobRemaining != null && remaining != null) {
      justDone.addAll(_lastJobRemaining!.difference(remaining));
    }
    if (remaining == null && _lastJobRemaining != null) {
      // 任务结束：剩余页里还没处理完的（停止场景）也整体重读。
      justDone.addAll(_lastJobRemaining!);
    }
    _lastJobRemaining = remaining;
    final wasLive = _wasJobLive;
    _wasJobLive = live;
    if (justDone.isNotEmpty) {
      _diskTouched = true;
      unawaited(_reloadPages(justDone));
    } else if (live != wasLive) {
      setState(() {});
    }
    // 任务彻底结束（快照消失或翻成 paused/failed）时重读断点文件，
    // 供「继续拆分」显示最新剩余页。
    if (wasLive && !_splitJobActive) {
      unawaited(_loadResumeInfo());
    }
  }

  /// 从盘重读这些页的标注并刷新格子/状态标记。
  Future<void> _reloadPages(List<int> pages) async {
    for (final i in pages) {
      final ann = await ProjectStorage.loadAnnotation(
        widget.project.projectDir,
        widget.project.pageIdAt(i),
      );
      if (!mounted) return;
      setState(() {
        if (ann != null) {
          _annotations[i] = ann;
        } else {
          _annotations.remove(i);
        }
        _regionRevisions[i] = (_regionRevisions[i] ?? 0) + 1;
        _modified.remove(i); // 后台已按当前框识别，"已改"语义完成
      });
    }
    if (!mounted) return;
    setState(() => _markers = PageStateMarkers.fromAnnotations(_annotations));
  }

  Future<void> _loadAll() async {
    final project = widget.project;
    for (var i = 0; i < project.imageFiles.length; i++) {
      final ann = await ProjectStorage.loadAnnotation(
        project.projectDir,
        project.pageIdAt(i),
      );
      if (ann != null) _annotations[i] = ann;
      // 主区框映射到格子需要原始页面尺寸（PNG 读头，很快）。
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

  int get _pageCount => widget.project.imageFiles.length;

  /// 解码宽度跟格宽联动（2 倍格宽兼顾清晰度与内存），封顶 720。
  int get _decodeWidth =>
      (_tierWidths[_sizeTier] * 2).clamp(320.0, 720.0).round();

  // ── 单页快设 ──

  /// 打开单页快设编辑器：**进页前重读该页盘上标注**（网格快照可能落后
  /// 于盘——校对页改主区形状后的级联 flush、后台任务都可能在快照建立
  /// 之后写盘），编辑器内保存直接落盘、返回后网格内存态已是最新
  /// （[_saveRegion] 以盘为基合并后同步内存）。编辑器里摆正过的页（返
  /// 回值）需要清掉内存里的旧标注/失效缩略缓存/重探页面尺寸——图片文
  /// 件已换。
  Future<void> _editPage(int index) async {
    if (_splitJobActive) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('后台拆分任务进行中，页面已锁定；请先停止任务（底部按钮或识别监控悬浮窗）')),
      );
      return;
    }
    final fresh = await ProjectStorage.loadAnnotation(
      widget.project.projectDir,
      widget.project.pageIdAt(index),
    );
    if (!mounted) return;
    if (fresh != null) {
      setState(() {
        _annotations[index] = fresh;
        _regionRevisions[index] = (_regionRevisions[index] ?? 0) + 1;
      });
    }
    final straightened = await Navigator.of(context).push<Set<int>>(
      MaterialPageRoute(
        builder: (_) => _RegionQuickEditorPage(
          project: widget.project,
          initialIndex: index,
          regionConfirmedFor: _regionConfirmedAt,
          onSave: _saveRegion,
        ),
      ),
    );
    if (!mounted || straightened == null || straightened.isEmpty) return;
    _diskTouched = true; // 摆正删/写了标注文件并改了书页清单
    setState(() {
      for (final i in straightened) {
        _annotations.remove(i);
        _pageSizes.remove(i);
        _regionRevisions[i] = (_regionRevisions[i] ?? 0) + 1;
        _thumbCache.evict(i);
      }
    });
    // 摆正会删掉旧标注文件、图片换新：按盘上现状回填内存态。摆正后
    // 重新画过正文主区的页必须留在「按主区拆分」的"已改"队列里——
    // 摆正前单页编辑器里的保存已把它们入队，此前这里无条件出队会把
    // 全书摆正重框后的队列清空、拆分按钮永远置灰。未重画（无正文
    // 主区）的页出队。
    for (final i in straightened) {
      final ann = await ProjectStorage.loadAnnotation(
        widget.project.projectDir,
        widget.project.pageIdAt(i),
      );
      if (!mounted) return;
      setState(() {
        if (ann != null) _annotations[i] = ann;
        if (ann != null &&
            ann.mainRegions.any(
              (r) => RegionLabel.normalize(r.label) == RegionLabel.mainText,
            )) {
          _modified.add(i);
        } else {
          _modified.remove(i);
        }
      });
    }
    setState(() => _markers = PageStateMarkers.fromAnnotations(_annotations));
    // 摆正后页面宽高可能变化：重探尺寸回填（格子画框的坐标基准）。
    for (final i in straightened) {
      final size = await probeImageSize(widget.project.imageFiles[i]);
      if (!mounted) return;
      if (size != null) setState(() => _pageSizes[i] = size);
    }
  }

  /// 快设保存：把主区整组替换为 [mainRects] 并临时保存（与全书叠加
  /// "只改框"同一语义，[BookRegionApply.applyRegionsOnly] 逐条保留主区
  /// id/uid/确认状态），页眉/页脚等其它类别按 label 同一规则整组落盘
  /// （[BookRegionApply.replaceLabeledRegions]，每类可多条），[removedLabels]
  /// 里的类别删除已有框。[mainRects] 传 **null = 完全不动主区**（「按
  /// 参考页适配」只复制页眉/页脚等类别时用）；**空列表仍是"本页无正文
  /// 区"**——删除已有正文主区。
  /// [confirmRegions]（单页编辑器「保存并下一页」）把主区与本次设置的
  /// 类别框打上 boxConfirmed——网格显示绿色"已确认"角标、可隐藏。
  /// [unconfirmRegions]（「指定页叠加统一设置」逐页调用）相反：本次写入
  /// 了正文区（[mainRects] 非 null）时，正文主区全部退回未确认
  /// （[BookRegionApply.clearMainRegionConfirmed]）——批量写入的几何未
  /// 经逐页核对，即使沿用了旧主区的确认身份也不算数，由用户分页查看后
  /// 自己确认；只设页眉/页脚等类别时（mainRects null）正文确认保留，
  /// 其它类别确认一律原样保留。
  /// [batch]（「按参考页适配」/「统一设置」逐页调用）＝成功不写逐页日
  /// 志、失败不弹 SnackBar，由批量循环汇总。返回 false = 写盘失败。
  /// 应用操作在"无变化"时幂等（同矩形组替换/无框删除为空操作），据此
  /// 判断"全无变化（含早已确认）则不写盘不标记已改"——原"未改动不落
  /// 盘"判断从编辑器移到这里：boxConfirmed 现状只有数据侧知道。
  /// 绝不触发识别；识别统一留给「按主区拆分」。缩略图画框与单页精编
  /// 都走这里。
  Future<bool> _saveRegion(
    int index,
    List<Rect>? mainRects,
    Map<String, List<Rect>> extras,
    List<String> removedLabels, {
    bool confirmRegions = false,
    bool unconfirmRegions = false,
    bool batch = false,
  }) async {
    // 合并基线读盘（不是网格快照）：整文件落盘用旧快照会把快照建立后
    // 写进盘的行/字/表格等全部盖掉（校对页改框后的级联 flush 就在窗口
    // 期里）。「最后修改者胜」——本次保存是用户的最新动作，落盘 = 新
    // 盘态 ⊕ 本次改框。
    var ann = await ProjectStorage.loadAnnotation(
      widget.project.projectDir,
      widget.project.pageIdAt(index),
    );
    ann ??= PageAnnotation(
      pageId: widget.project.pageIdAt(index),
      imagePath: widget.project.imageFiles[index],
    );
    _annotations[index] = ann;
    var changed = false;
    if (mainRects != null && mainRects.isNotEmpty) {
      changed |= BookRegionApply.applyRegionsOnly(ann, mainRects);
      // 从"无正文确认"回到有正文时清掉该标记。
      if (ann.noMainTextConfirmed) {
        ann.noMainTextConfirmed = false;
        changed = true;
      }
    } else if (mainRects != null) {
      // 无正文页（扉页/插图/空白）：删除已有正文主区。
      if (ann.mainRegions.any(
        (r) => RegionLabel.normalize(r.label) == RegionLabel.mainText,
      )) {
        changed = true;
      }
      ann.mainRegions.removeWhere(
        (r) => RegionLabel.normalize(r.label) == RegionLabel.mainText,
      );
    }
    for (final label in removedLabels) {
      changed |= BookRegionApply.removeLabeledRegions(ann, label);
    }
    final extraLabels = <String>{
      for (final label in extras.keys) RegionLabel.normalize(label),
    };
    for (final entry in extras.entries) {
      changed |= BookRegionApply.replaceLabeledRegions(
        ann,
        entry.key,
        entry.value,
      );
    }
    var confirmChanged = false;
    if (confirmRegions) {
      if (mainRects != null && mainRects.isEmpty) {
        if (!ann.noMainTextConfirmed) {
          ann.noMainTextConfirmed = true;
          confirmChanged = true;
        }
      } else {
        // 主区 + 本次设置的类别框打确认；其它类别（如预标注候选）不强
        // 行代确认。主区未动（null）时只确认本次复制的类别。
        final touched = <String>{
          if (mainRects != null) RegionLabel.mainText,
          ...extraLabels,
        };
        for (final r in ann.mainRegions) {
          if (touched.contains(RegionLabel.normalize(r.label)) &&
              !r.boxConfirmed) {
            r.boxConfirmed = true;
            confirmChanged = true;
          }
        }
      }
    } else if (unconfirmRegions && mainRects != null) {
      // 统一设置后退回未确认：本次**写了正文区**（mainRects null = 只设
      // 页眉/页脚等类别、主区没动，正文确认保留）才清正文主区的确认——
      // 含位置继承来的旧确认，退回待确认候选；确认标记变化也要落盘。
      confirmChanged = BookRegionApply.clearMainRegionConfirmed(ann) > 0;
    }
    if (!changed && !confirmChanged) return true; // 全无变化：不写盘不标已改
    ann.draftSaved = true;
    try {
      await ProjectStorage.saveAnnotation(widget.project.projectDir, ann);
    } catch (e) {
      PythonService.addAppLog('[主区快设] 第 ${index + 1} 页保存失败：$e', isError: true);
      if (mounted && !batch) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('第 ${index + 1} 页保存失败：$e')));
      }
      return false;
    }
    if (!mounted) return true;
    setState(() {
      // 就地改写不换对象，用版本号让格子重画主区框。无正文页没有可拆分
      // 的主区，不进「按主区拆分」的"已改"队列。
      _regionRevisions[index] = (_regionRevisions[index] ?? 0) + 1;
      if (mainRects != null && mainRects.isNotEmpty) _modified.add(index);
      _diskTouched = true;
      _markers = PageStateMarkers.fromAnnotations(_annotations);
    });
    if (batch) return true;
    if (mainRects == null) return true;
    if (mainRects.isEmpty) {
      PythonService.addAppLog('[主区快设] 第 ${index + 1} 页已保存（无正文区），未识别');
      return true;
    }
    final extraCount = extraLabels.difference({RegionLabel.mainText}).length;
    final mainDesc = mainRects.length == 1
        ? '${mainRects.single.left.round()},${mainRects.single.top.round()},'
              '${mainRects.single.width.round()},${mainRects.single.height.round()}'
        : '${mainRects.length} 处（${[for (final r in mainRects) '${r.left.round()},${r.top.round()},'
                '${r.width.round()},${r.height.round()}'].join('；')}）';
    PythonService.addAppLog(
      '[主区快设] 第 ${index + 1} 页已保存'
      '（主区 $mainDesc'
      '${extraCount > 0 ? '，另设 $extraCount 类版面区' : ''}'
      '${confirmRegions ? '，已确认' : ''}），未识别',
    );
    return true;
  }

  /// 该页是否已确认（「保存并下一页」或编辑器「确认识别框」）：有正文
  /// 主区时须**全部**主区框 boxConfirmed（多主区页一条没确认过就不算）；
  /// 无正文页（扉页/插图/空白）看页面级 noMainTextConfirmed（「确认无
  /// 正文」）。
  bool _regionConfirmedAt(int index) =>
      BookRegionGridPage.pageRegionConfirmed(_annotations[index]);

  // ── 批量拆分 ──

  bool _prelabeling = false;

  /// 网格「隐藏已确认」开关：开启后主区已确认（boxConfirmed）的页从
  /// 网格隐去，只剩待设页便于逐页过。状态持久化（用户要求：下次进来
  /// 还是上次的状态）。
  bool _hideConfirmed = false;
  static const String _prefHideConfirmed = 'region_grid_hide_confirmed';

  void _setHideConfirmed(bool value) {
    setState(() => _hideConfirmed = value);
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setBool(_prefHideConfirmed, value),
    );
  }

  /// 「自动加页眉/页脚候选框」的范围选择（true=仅未确认页，默认）：
  /// 已确认页的版面区已被人工认可，候选框多半是噪声。与「隐藏已确认」
  /// 开关一样持久化，下次进来保持上次的选择。
  bool _prelabelUnconfirmedOnly = true;
  static const String _prefPrelabelUnconfirmedOnly =
      'region_grid_prelabel_unconfirmed_only';

  /// 自动加页眉/页脚候选框（全书批量，原「规则预标注」）：逐页调
  /// /region_prelabel，把页眉/页脚/页码/眉批候选落为 proposed 区域
  /// （只填空：与已有区域重叠的建议跳过）。不触发识别，与「按主区拆分」
  /// 完全解耦——预标注只改标注文件。开跑前先选范围：仅未确认页（默认，
  /// 跳过绿色"已确认"角标的页）或全部页面，选择持久化。
  Future<void> _runBatchPrelabel() async {
    final project = widget.project;
    final total = project.imageFiles.length;
    if (total == 0 || _prelabeling) return;
    var unconfirmedCount = 0;
    for (var i = 0; i < total; i++) {
      if (!BookRegionGridPage.pageRegionConfirmed(_annotations[i])) {
        unconfirmedCount++;
      }
    }
    var scopeUnconfirmed = _prelabelUnconfirmedOnly;
    final start = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('自动加页眉/页脚候选框'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '按规则给页眉/页脚/页码/眉批/表格生成候选框，'
                '不覆盖已有框，结果需逐页确认',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              RadioGroup<bool>(
                groupValue: scopeUnconfirmed,
                onChanged: (v) =>
                    setDialogState(() => scopeUnconfirmed = v ?? true),
                child: Column(
                  children: [
                    RadioListTile<bool>(
                      value: true,
                      title: const Text('仅未确认的页面'),
                      subtitle: Text('跳过已确认的页（$unconfirmedCount 页）'),
                      dense: true,
                    ),
                    RadioListTile<bool>(
                      value: false,
                      title: const Text('全部页面'),
                      subtitle: Text('包含已确认的页（$total 页）'),
                      dense: true,
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('开始'),
            ),
          ],
        ),
      ),
    );
    if (start != true || !mounted) return;
    _prelabelUnconfirmedOnly = scopeUnconfirmed;
    unawaited(
      SharedPreferences.getInstance().then(
        (prefs) =>
            prefs.setBool(_prefPrelabelUnconfirmedOnly, scopeUnconfirmed),
      ),
    );
    final scopeLabel = scopeUnconfirmed ? '仅未确认页' : '全部页面';
    final targets = BookRegionGridPage.prelabelTargetsFrom(
      loading: _loading,
      annotations: _annotations,
      pageCount: total,
      unconfirmedOnly: scopeUnconfirmed,
    );
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_loading ? '页面标注还在加载，稍后再试' : '没有可加候选框的页面')),
      );
      return;
    }
    final totalTargets = targets.length;
    setState(() => _prelabeling = true);
    var cancel = false;
    var pagesTouched = 0;
    var regionsAdded = 0;
    var failed = 0;
    var done = 0;
    StateSetter? setProgress;

    final progressFuture = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: StatefulBuilder(
          builder: (dialogContext, setStateInDialog) {
            setProgress = setStateInDialog;
            return AlertDialog(
              title: const Text('自动加页眉/页脚候选框'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '按规则给页眉/页脚/页码/眉批/表格生成候选框，'
                    '不覆盖已有框，结果需逐页确认',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: totalTargets == 0 ? 1 : done / totalTargets,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '第 ${done + 1 > totalTargets ? totalTargets : done + 1} / $totalTargets 页 …'
                    '（$scopeLabel）',
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '已加 $regionsAdded 个候选区（$pagesTouched 页）'
                    '${failed > 0 ? '，失败 $failed 页' : ''}',
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

    for (var di = 0; di < totalTargets && !cancel; di++) {
      final i = targets[di];
      done = di;
      setProgress?.call(() {});
      try {
        final pageId = project.pageIdAt(i);
        final result = await PythonService.regionPrelabel(
          projectDir: project.projectDir,
          pageId: pageId,
        );
        if (result.suggestions.isEmpty) continue;
        final existing = await ProjectStorage.loadAnnotation(
          project.projectDir,
          pageId,
        );
        final ann =
            existing ??
            PageAnnotation(pageId: pageId, imagePath: project.imageFiles[i]);
        var addedHere = 0;
        final stamp = DateTime.now().millisecondsSinceEpoch;
        for (final s in result.suggestions) {
          final rect = Rect.fromLTWH(
            s.x.toDouble(),
            s.y.toDouble(),
            s.w.toDouble(),
            s.h.toDouble(),
          );
          // 只填空：与任何已有区域有实质重叠（交集占建议框 >5%）跳过
          final clash = ann.mainRegions.any((r) {
            final inter = r.rect.intersect(rect);
            return !inter.isEmpty &&
                inter.width * inter.height > rect.width * rect.height * 0.05;
          });
          if (clash) continue;
          ann.mainRegions.add(
            MainRegion(
              id: 'mr_pre_${stamp}_${i}_$addedHere',
              x: s.x,
              y: s.y,
              w: s.w,
              h: s.h,
              label: RegionLabel.normalize(s.label),
              status: AnnotationStatus.proposed,
            ),
          );
          addedHere++;
        }
        if (addedHere > 0) {
          ann.draftSaved = true;
          await ProjectStorage.saveAnnotation(project.projectDir, ann);
          _annotations[i] = ann;
          _regionRevisions[i] = (_regionRevisions[i] ?? 0) + 1;
          pagesTouched++;
          regionsAdded += addedHere;
          _diskTouched = true;
        }
      } catch (error) {
        failed++;
        PythonService.addAppLog(
          '[主区快设] 第 ${i + 1} 页自动加候选框失败：$error',
          isError: true,
        );
      }
    }
    if (!cancel && mounted) {
      Navigator.of(context).pop();
    }
    await progressFuture;
    if (!mounted) return;
    setState(() {
      _markers = PageStateMarkers.fromAnnotations(_annotations);
      _prelabeling = false;
    });
    PythonService.addAppLog(
      '[主区快设] 自动加候选框结束（$scopeLabel）'
      '${cancel ? '（用户停止）' : ''}：'
      '$regionsAdded 个候选区 / $pagesTouched 页'
      '${failed > 0 ? '，失败 $failed 页' : ''}',
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          cancel
              ? '自动加候选框已停止：$regionsAdded 个候选区（$pagesTouched 页）'
              : '自动加候选框完成：新增 $regionsAdded 个候选区'
                    '（$pagesTouched 页，均为待确认候选）',
        ),
      ),
    );
  }

  /// 「按参考页适配」进行中（与预标注/拆分任务互斥的批量标记）。
  bool _referenceApplying = false;

  /// 按参考页适配（用户需求：同一本书逐页重复画正文/页眉/页脚/页码太
  /// 累）：选一页设定完的页做参考，把各类版面区框按页面尺寸比例复制到
  /// 其他页（页眉/页脚/页码逐页墨迹判空，无内容的不落框）。对话框与
  /// 循环见 [showReferenceApplyAndRun]；逐页保存复用 [_saveRegion]
  /// （batch 模式：不逐页记日志、失败不弹条，这里汇总；不自动确认）。
  Future<void> _runReferenceApply() async {
    if (_referenceApplying || _prelabeling) return;
    if (_loading) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('页面标注还在加载，稍后再试')));
      return;
    }
    setState(() => _referenceApplying = true);
    ReferenceApplyStats? stats;
    try {
      stats = await showReferenceApplyAndRun(
        context: context,
        project: widget.project,
        annotations: _annotations,
        pageSizes: _pageSizes,
        savePage: (index, mainRects, extras) =>
            _saveRegion(index, mainRects, extras, const [], batch: true),
      );
    } finally {
      if (mounted) setState(() => _referenceApplying = false);
    }
    if (stats == null || !mounted) return; // 无参考页/取消（已各自提示）
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          stats.cancelled
              ? '按参考页适配已停止：已适配 ${stats.applied} 页'
              : '按参考页适配完成：${stats.applied} 页（${stats.scopeDesc}，均为待确认候选）'
                    '${stats.emptySkipped > 0 ? '，判空跳过 ${stats.emptySkipped} 个空框' : ''}'
                    '${stats.inkFailures > 0 ? '，${stats.inkFailures} 页判空失败（框已保留）' : ''}'
                    '${stats.failed > 0 ? '，写盘失败 ${stats.failed} 页（见日志）' : ''}',
        ),
      ),
    );
  }

  /// 「取消确认」进行中（与预标注/适配/拆分互斥的批量标记）。
  bool _unconfirming = false;

  /// 指定页范围取消「主区已确认」（用户需求：适配/确认做过头了要能整段
  /// 退回去重来）。范围内每页清掉全部版面区框的 boxConfirmed 与「确认
  /// 无正文」标记——绿角标消失、回到待确认；校对类页面状态（reviewed/
  /// boxesReviewed，整页绿框/玫红框）不动，那是编辑器「改回未保存」的
  /// 职责。region_det 训练数据随之失效：循环结束后主动触发一次增量导
  /// 出，后端会把不再产样本的页从数据集删掉并回退统计。
  Future<void> _runUnconfirmRange() async {
    if (_unconfirming || _prelabeling || _referenceApplying) return;
    if (_loading) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('页面标注还在加载，稍后再试')));
      return;
    }
    if (_splitJobActive) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('后台拆分任务进行中，请先停止任务再取消确认')));
      return;
    }
    final total = _pageCount;
    var confirmedCount = 0;
    for (var i = 0; i < total; i++) {
      if (_regionConfirmedAt(i)) confirmedCount++;
    }
    final fromCtrl = TextEditingController(text: '1');
    final toCtrl = TextEditingController(text: '$total');
    bool? ok;
    try {
      ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            int? parse(TextEditingController c) => int.tryParse(c.text.trim());
            final from = parse(fromCtrl), to = parse(toCtrl);
            final valid = from != null && to != null;
            final first = valid ? math.min(from, to) : 1;
            final last = valid ? math.max(from, to) : total;
            return AlertDialog(
              title: const Text('取消确认（改回未确认）'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '当前本书主区已确认 $confirmedCount / $total 页。'
                      '范围内每页的版面区框确认标记全部清除（绿角标消失、'
                      '退出「按主区拆分」队列），框本身保留；校对完成的页'
                      '（整页绿框/玫红框）的页面状态不动。',
                      style: const TextStyle(fontSize: 12, height: 1.6),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Text('页范围：第'),
                        SizedBox(
                          width: 70,
                          height: 36,
                          child: TextField(
                            controller: fromCtrl,
                            decoration: const InputDecoration(isDense: true),
                            style: const TextStyle(fontSize: 13),
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            onChanged: (_) => setDialogState(() {}),
                          ),
                        ),
                        const Text(' ～ '),
                        SizedBox(
                          width: 70,
                          height: 36,
                          child: TextField(
                            controller: toCtrl,
                            decoration: const InputDecoration(isDense: true),
                            style: const TextStyle(fontSize: 13),
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            onChanged: (_) => setDialogState(() {}),
                          ),
                        ),
                        const Text(' 页'),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      valid ? '第 $first~$last 页（自动钳制在 1~$total 内）' : '请输入页号',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      '已导出的 region_det 训练样本会在随后自动清除并回退统计。',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: valid
                      ? () => Navigator.of(dialogContext).pop(true)
                      : null,
                  child: const Text('清除确认标记'),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      fromCtrl.dispose();
      toCtrl.dispose();
    }
    if (ok != true || !mounted) return;
    // dispose 后 text 仍可读（控制器只是解绑）；钳回 1~total，大小写自动
    // 归位（输入反了不阻拦）。
    final from = (int.tryParse(fromCtrl.text) ?? 1).clamp(1, total);
    final to = (int.tryParse(toCtrl.text) ?? total).clamp(1, total);
    final first = math.min(from, to);
    final last = math.max(from, to);
    setState(() => _unconfirming = true);
    var touched = 0;
    var failed = 0;
    try {
      for (var i = first - 1; i <= last - 1; i++) {
        final ann = await ProjectStorage.loadAnnotation(
          widget.project.projectDir,
          widget.project.pageIdAt(i),
        );
        if (ann == null) continue;
        var hit = ann.noMainTextConfirmed;
        for (final r in ann.mainRegions) {
          if (r.boxConfirmed) hit = true;
        }
        if (!hit) continue;
        for (final r in ann.mainRegions) {
          r.boxConfirmed = false;
        }
        ann.noMainTextConfirmed = false;
        ann.draftSaved = true;
        try {
          await ProjectStorage.saveAnnotation(widget.project.projectDir, ann);
        } catch (e) {
          failed++;
          PythonService.addAppLog(
            '[主区快设] 第 ${i + 1} 页取消确认写盘失败：$e',
            isError: true,
          );
          continue;
        }
        touched++;
        if (!mounted) return;
        setState(() {
          _annotations[i] = ann;
          _regionRevisions[i] = (_regionRevisions[i] ?? 0) + 1;
          _diskTouched = true;
          _markers = PageStateMarkers.fromAnnotations(_annotations);
        });
      }
    } finally {
      if (mounted) setState(() => _unconfirming = false);
    }
    PythonService.addAppLog(
      '[主区快设] 取消确认：第 $first~$last 页中清除 $touched 页'
      '${failed > 0 ? '，写盘失败 $failed 页' : ''}',
    );
    if (touched > 0) {
      // 撤账：region_det 里这些页的样本已不再合法，主动导出一次让后端
      // 清理文件并回退统计（自动调度器对"全无确认标记"的页不会触发）。
      unawaited(
        PythonService.exportTrainDatasets(
          projectDir: widget.project.projectDir,
        ).catchError((Object e) {
          PythonService.addAppLog('[主区快设] 取消确认后的训练数据清理失败：$e', isError: true);
          return <String, dynamic>{};
        }),
      );
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          touched > 0
              ? '已把第 $first~$last 页中的 $touched 页改回未确认（框保留）'
                    '${failed > 0 ? '，失败 $failed 页（见日志）' : ''}'
              : '第 $first~$last 页没有已确认的页',
        ),
      ),
    );
  }

  /// 「指定页叠加设置」进行中（与预标注/适配/取消确认互斥的批量标记）。
  bool _overlayApplying = false;

  /// 指定页叠加统一设置（用户需求：一段页面版式一致时不想逐页画框——
  /// 选一个页范围，范围内页面叠成一张图统一画版面区，一键写入范围各
  /// 页）。**各类别**（正文/页眉/页脚/页码…，顶栏切换、每类可多个）整
  /// 组替换写入，只写框、不识别、**不自动确认**：写了正文的页一律退回
  /// 未确认（含原已确认页），由用户分页查看后自己确认（「保存并下一
  /// 页」）。页表两个来源：网格里 **Ctrl/Shift 多选的页直接进画布**
  /// （可离散，跳过范围对话框）；未选页时弹范围对话框（起止页展开成
  /// 连续页表）。叠加画布与应用复用全书叠加页（统一设置模式），逐页
  /// 保存复用 [_saveRegion]（batch + unconfirmRegions，网格内存态随写
  /// 随同步，返回后无需重读）。
  Future<void> _runOverlayApply() async {
    if (_overlayApplying ||
        _prelabeling ||
        _referenceApplying ||
        _unconfirming ||
        _clearingBoxes) {
      return;
    }
    if (_loading) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('页面标注还在加载，稍后再试')));
      return;
    }
    if (_splitJobActive) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('后台拆分任务进行中，请先停止任务再统一设置')));
      return;
    }
    // 多选路径：Ctrl/Shift 选中的页直接进叠加（页表可离散）。
    if (_selectedPages.isNotEmpty) {
      await _pushOverlayApply(_selectedPages.toList()..sort());
      return;
    }
    final total = _pageCount;
    if (total == 0) return;
    final fromCtrl = TextEditingController(text: '1');
    final toCtrl = TextEditingController(text: '$total');
    bool? ok;
    try {
      ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            int? parse(TextEditingController c) => int.tryParse(c.text.trim());
            final from = parse(fromCtrl), to = parse(toCtrl);
            final valid = from != null && to != null;
            final first = valid ? math.min(from, to) : 1;
            final last = valid ? math.max(from, to) : total;
            return AlertDialog(
              title: const Text('指定页叠加统一设置'),
              content: SizedBox(
                width: 440,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '把选定范围的页面半透明叠成一张图，画各类版面区'
                      '（正文/页眉/页脚/页码…，进画布后顶栏切换）统一写入'
                      '范围各页（无标注页会新建标注）。只写框、'
                      '不识别，不触发「按主区拆分」。\n'
                      '写了正文的页设置后一律退回未确认（含原已确认页）'
                      '——校对完成的页（绿框/玫红框）与「确认无正文」的页'
                      '恒跳过。请设置完逐页查看，核对后自己确认。',
                      style: const TextStyle(fontSize: 12, height: 1.6),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Text('页范围：第'),
                        SizedBox(
                          width: 70,
                          height: 36,
                          child: TextField(
                            controller: fromCtrl,
                            decoration: const InputDecoration(isDense: true),
                            style: const TextStyle(fontSize: 13),
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            onChanged: (_) => setDialogState(() {}),
                          ),
                        ),
                        const Text(' ～ '),
                        SizedBox(
                          width: 70,
                          height: 36,
                          child: TextField(
                            controller: toCtrl,
                            decoration: const InputDecoration(isDense: true),
                            style: const TextStyle(fontSize: 13),
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            onChanged: (_) => setDialogState(() {}),
                          ),
                        ),
                        const Text(' 页'),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      valid ? '第 $first~$last 页（自动钳制在 1~$total 内）' : '请输入页号',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'),
                ),
                FilledButton.icon(
                  onPressed: valid
                      ? () => Navigator.of(dialogContext).pop(true)
                      : null,
                  icon: const Icon(Icons.layers),
                  label: const Text('去叠加画布'),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      fromCtrl.dispose();
      toCtrl.dispose();
    }
    if (ok != true || !mounted) return;
    // dispose 后 text 仍可读（控制器只是解绑）；钳回 1~total，大小写自
    // 动归位（输入反了不阻拦）。
    final from = (int.tryParse(fromCtrl.text) ?? 1).clamp(1, total);
    final to = (int.tryParse(toCtrl.text) ?? total).clamp(1, total);
    final first = math.min(from, to);
    final last = math.max(from, to);
    await _pushOverlayApply([
      for (var i = first - 1; i <= last - 1; i++) i,
    ]);
  }

  /// 进统一设置叠加画布（[pages] 0 基升序，可离散——网格 Ctrl/Shift 多
  /// 选的页表或范围对话框展开的连续页表共用这一步），返回后视写入结果
  /// 提醒逐页查看确认。
  Future<void> _pushOverlayApply(List<int> pages) async {
    if (pages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有可设置的页')),
      );
      return;
    }
    setState(() => _overlayApplying = true);
    var changed = false;
    try {
      changed =
          await Navigator.of(context).push<bool>(
            MaterialPageRoute(
              builder: (_) => BookOverlayPage(
                project: widget.project,
                quickPages: pages,
                quickSavePage: (index, mainRects, extras) => _saveRegion(
                  index,
                  mainRects,
                  extras,
                  const [],
                  batch: true,
                  unconfirmRegions: true,
                ),
              ),
            ),
          ) ??
          false;
    } finally {
      if (mounted) setState(() => _overlayApplying = false);
    }
    // 叠加完成返回：这批多选已消费，自动清空选择（用户要求）；中途停
    // 止/一笔未写（changed=false）则保留，便于原样重试。
    if (changed && mounted && _selectedPages.isNotEmpty) {
      setState(() {
        _selectedPages.clear();
        _selectionAnchor = null;
      });
    }
    if (!changed || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          '正文区已统一设置并退回未确认：请逐页点开查看，'
          '核对无误后用「保存并下一页」确认（或先「按主区拆分」出稿再校对）',
        ),
      ),
    );
  }

  /// 「清除未确认页框」进行中（与预标注/适配/叠加/取消确认互斥的批量
  /// 标记）。
  bool _clearingBoxes = false;

  /// 清除全书**未确认页**的全部识别框（用户需求：适配/统一设置批量写
  /// 框试错后，一键清空重来）。目标页判定见
  /// [BookRegionGridPage.shouldClearUnconfirmedBoxes]：主区已确认（绿色
  /// 角标）、校对完成的页（绿框/玫红框/旧版 reviewed）与「确认无正文」
  /// 的页一律不碰——人工认可过的框不被批量清除；这些页也从未进过
  /// region_det 训练集，清完无需回账导出。逐页盘上防御性复查后清空
  /// 版面区/行/字/段落/表格框并落盘，网格内存态同步刷新；不可撤销，
  /// 弹窗先交代将被清空的页数。
  Future<void> _runClearUnconfirmedBoxes() async {
    if (_clearingBoxes ||
        _prelabeling ||
        _referenceApplying ||
        _unconfirming ||
        _overlayApplying) {
      return;
    }
    if (_loading) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('页面标注还在加载，稍后再试')),
      );
      return;
    }
    if (_splitJobActive) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('后台拆分任务进行中，请先停止任务再清除')),
      );
      return;
    }
    final total = _pageCount;
    var targets = 0;
    for (var i = 0; i < total; i++) {
      if (BookRegionGridPage.shouldClearUnconfirmedBoxes(_annotations[i])) {
        targets++;
      }
    }
    if (targets == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有可清除的页（未确认的页都还没有框）')),
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清除未确认页识别框'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '全书 $total 页中，$targets 页未确认且有框，将清空这些页的'
                '全部版面区框/行/字框/表格——页回到待框状态，需要重新画'
                '框或拆分识别。\n'
                '主区已确认（绿色角标）、校对完成（绿框/玫红框）与「确认'
                '无正文」的页不动。',
                style: const TextStyle(fontSize: 12, height: 1.6),
              ),
              const SizedBox(height: 8),
              Text(
                '此操作不可撤销。',
                style: TextStyle(fontSize: 12, color: Colors.red.shade700),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.delete_sweep),
            label: Text('清空 $targets 页'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _clearingBoxes = true);
    var cleared = 0;
    var failed = 0;
    try {
      for (var i = 0; i < total; i++) {
        // 盘上防御性复查（与其它批量同一纪律）：快照建立后该页可能刚
        // 被人工确认或校对落盘——以盘为准，不该清的页跳过。
        final fresh = await ProjectStorage.loadAnnotation(
          widget.project.projectDir,
          widget.project.pageIdAt(i),
        );
        if (fresh == null) continue;
        if (!BookRegionGridPage.shouldClearUnconfirmedBoxes(fresh)) continue;
        // 换新列表而非 .clear()：加载路径可能给出不可变列表（const /
        // Unmodifiable），clear() 会抛 UnsupportedError 闪退；赋值对任
        // 何来源免疫。
        fresh
          ..mainRegions = []
          ..paragraphs = []
          ..lines = []
          ..blocks = []
          ..tables = [];
        // 框已不在，"临时保存过"的草稿标记一并归零——页回到与从未设
        // 置过的页同状态。
        fresh.draftSaved = false;
        try {
          await ProjectStorage.saveAnnotation(widget.project.projectDir, fresh);
        } catch (e) {
          failed++;
          PythonService.addAppLog(
            '[主区快设] 第 ${i + 1} 页清空识别框写盘失败：$e',
            isError: true,
          );
          continue;
        }
        cleared++;
        if (!mounted) return;
        setState(() {
          _annotations[i] = fresh;
          _regionRevisions[i] = (_regionRevisions[i] ?? 0) + 1;
          _diskTouched = true;
          _markers = PageStateMarkers.fromAnnotations(_annotations);
        });
      }
    } finally {
      if (mounted) setState(() => _clearingBoxes = false);
    }
    PythonService.addAppLog(
      '[主区快设] 清除未确认页识别框结束：清空 $cleared 页'
      '${failed > 0 ? '，写盘失败 $failed 页' : ''}',
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          failed > 0
              ? '已清空 $cleared 页识别框，写盘失败 $failed 页（见日志）'
              : '已清空 $cleared 页的全部识别框',
        ),
      ),
    );
  }

  /// 「按主区拆分」的目标页（计算本体见 [BookRegionGridPage.splitTargetsFrom]）。
  List<int> _splitTargets() => BookRegionGridPage.splitTargetsFrom(
    loading: _loading,
    annotations: _annotations,
    pageCount: _pageCount,
  );

  /// 启动（或继续）后台按主区拆分：确认后入 RecognitionQueue，本页留守
  /// 观察（格子锁定/实时刷新），可自由离开——书库会拦编辑入口，悬浮窗
  /// 可停止/删除。AI 口径与整本识别一致：AI 辅助设置的"全书整行裁决"
  /// 开关（enableLineAssist）开着才逐行调模型；断点续跑沿用断点里记的
  /// 开关状态。
  Future<void> _startBatchSplit(List<int> pages, {bool? aiFromResume}) async {
    if (_splitJobActive || pages.isEmpty) return;
    final ollama = await OllamaSettings.load();
    final aiOn = aiFromResume ?? ollama.enableLineAssist;
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text('按主区拆分 ${pages.length} 页'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '对 ${pages.length} 个主区已确认页（${_pageRangeLabel(pages)}）'
                  '按各自主区统一执行：',
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 8),
                const Text(
                  '· 后台任务：启动后本页锁定这些页，可自由离开；'
                  '识别监控悬浮窗/首页卡片可停止、删除\n'
                  '· 多页流水线调后端识别主区内的行与单字（每页数秒到数十秒）\n'
                  '· 按版式方向把行重建成自然段；整页绿框（「确认并保存」）\n'
                  '  或玫红框（「确认识别框」）的页不动，手工调整过的行\n'
                  '  不会被覆盖\n'
                  '· 停止/失败后剩余页存断点，下次从这里继续',
                  style: TextStyle(fontSize: 12, height: 1.6),
                ),
                const SizedBox(height: 6),
                Text(
                  '· 整行 AI 裁决：${aiOn ? '开启（按 AI 辅助设置逐行调用模型，每页耗时明显增加）' : '关闭（AI 辅助设置未开启全书整行裁决）'}',
                  style: const TextStyle(fontSize: 12, height: 1.6),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: RecognitionQueue.instance.shutdownWhenIdle,
                  onChanged: (v) {
                    if (v == null) return;
                    setDialogState(() {});
                    RecognitionQueue.instance.setShutdownWhenIdle(v);
                  },
                  title: const Text(
                    '全部任务完成后关机（与整本识别同一开关，60 秒倒计时可取消）',
                    style: TextStyle(fontSize: 13),
                  ),
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
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('开始拆分'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    RecognitionQueue.instance.enqueueRegionSplit(
      widget.project,
      pages: pages,
      aiEnabled: aiOn,
    );
    if (!mounted) return;
    setState(() => _resumeInfo = null);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          '已加入后台队列：可留在本页观察（处理过的页会标"已处理"），'
          '也可自由离开；识别监控悬浮窗可随时停止/删除',
        ),
      ),
    );
  }

  String _pageRangeLabel(List<int> pages) {
    if (pages.length <= 6) {
      return pages.map((i) => '第 ${i + 1} 页').join('、');
    }
    return '第 ${pages.first + 1}～${pages.last + 1} 页中的 ${pages.length} 页';
  }

  // ── build ──

  @override
  Widget build(BuildContext context) {
    final pageCount = _pageCount;
    // 返回键统一带出"是否动过盘"：校对编辑器据此重读当前页与状态标记。
    // 后台拆分任务进行中时不回校对页（编辑器内存标注会与后台写盘互相
    // 覆盖），连同校对页一起退回书库：任务继续在后台跑，书库卡片可见
    // 进度；编辑器 dispose 落盘由其自身按"任务进行中跳过"避让。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_splitJobActive) {
          Navigator.of(context).popUntil((route) => route.isFirst);
          return;
        }
        Navigator.of(context).pop(_diskTouched);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('主区快设 · ${widget.project.name}'),
          actions: [
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
        bottomNavigationBar: _buildBottomBar(),
      ),
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

  // ── 多选（Ctrl/Shift + 单击格子）──

  /// 选中的页（0 基）：「叠加已选 N 页」据此进统一设置画布（页表可离
  /// 散，适配/取消确认等其它批量功能不读它）。普通单击仍是打开单页编
  /// 辑器，不清空已有选择。
  final Set<int> _selectedPages = {};

  /// Shift 连选的锚点（最后一次 Ctrl/普通选中的页）。
  int? _selectionAnchor;

  /// 格子单击分发：无修饰键 = 打开单页快设编辑器（原行为）；Ctrl =
  /// 选中/取消该页；Shift = 从锚点连选到该页（沿当前可见页表铺开，
  /// 「隐藏已确认」过滤掉的页不进选区）。
  void _handleCellTap(int index, {required bool ctrl, required bool shift}) {
    if (!ctrl && !shift) {
      _editPage(index);
      return;
    }
    setState(() {
      if (ctrl) {
        _selectionAnchor = index;
        if (!_selectedPages.remove(index)) _selectedPages.add(index);
        return;
      }
      final anchor = _selectionAnchor ?? index;
      _selectionAnchor = anchor;
      final visible = _visibleIndexes();
      final ai = visible.indexOf(anchor);
      final ci = visible.indexOf(index);
      if (ai < 0 || ci < 0) {
        // 锚点被过滤掉了（罕见）：退化为单选该页。
        _selectedPages.add(index);
        return;
      }
      for (
        var k = math.min(ai, ci);
        k <= math.max(ai, ci);
        k++
      ) {
        _selectedPages.add(visible[k]);
      }
    });
  }

  /// 当前可见页表（0 基升序）：「隐藏已确认」开着的场合剔除主区已确认
  /// 的页。多选的 Shift 连选沿它铺开——被过滤掉的页不进选区。
  List<int> _visibleIndexes() => [
    for (var i = 0; i < _pageCount; i++)
      if (!(_hideConfirmed && _regionConfirmedAt(i))) i,
  ];

  Widget _buildGrid(int pageCount) {
    // 隐藏已确认：过滤后按下标映射回真实页号（与编辑器左侧缩略图同
    // 思路——校对后期确认页占大头，过滤后只剩待设页便于逐页点选）。
    final visible = _visibleIndexes();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _legend(Colors.green.shade600, '页已确认（校对）'),
              _legend(PageStateMarkers.boxesReviewedColor, '框已确认'),
              _legend(Colors.orange.shade700, '临时保存'),
              _legend(Colors.purple, '识别未确认'),
              _legend(Colors.grey.shade500, '无标注'),
              _legend(Colors.green.shade700, '角标：主区已确认'),
              _modifiedChip(null),
              FilterChip(
                avatar: Icon(
                  _hideConfirmed ? Icons.visibility_off : Icons.visibility,
                  size: 14,
                  color: _hideConfirmed
                      ? Colors.green.shade700
                      : Colors.grey.shade600,
                ),
                label: const Text('隐藏已确认', style: TextStyle(fontSize: 12)),
                selected: _hideConfirmed,
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                onSelected: _setHideConfirmed,
              ),
              if (_selectedPages.isNotEmpty)
                ActionChip(
                  avatar: Icon(
                    Icons.check_box,
                    size: 14,
                    color: Colors.blue.shade700,
                  ),
                  label: Text(
                    '已选 ${_selectedPages.length} 页 · 点击清除',
                    style: const TextStyle(fontSize: 12),
                  ),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() {
                    _selectedPages.clear();
                    _selectionAnchor = null;
                  }),
                ),
              Text(
                '缩略图上左键拖拽直接画主区（保存只记主区，不识别），'
                '点击打开大图精修；Ctrl+单击 多选/取消、Shift+单击 连选，'
                '选完点「叠加已选 N 页」；「保存并下一页」= 确认该页框；'
                '改完后点「按主区拆分」',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
            ],
          ),
        ),
        Expanded(
          child: visible.isEmpty
              ? Center(
                  child: Text(
                    _hideConfirmed && pageCount > 0
                        ? '全部 $pageCount 页的主区都已确认\n'
                              '（关闭「隐藏已确认」可查看全部页）'
                        : '本书没有页面',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                  ),
                )
              : Builder(
                  builder: (context) {
                    final jobActive = _splitJobActive;
                    final jobRemaining =
                        _splitJob?.remainingPages.toSet() ?? const <int>{};
                    return GridView.builder(
                      padding: const EdgeInsets.all(8),
                      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: _tierWidths[_sizeTier],
                        // 古籍页以竖版为主；横竖不一的页按 contain 居中画。
                        childAspectRatio: 0.72,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                      ),
                      itemCount: visible.length,
                      itemBuilder: (_, row) {
                        final index = visible[row];
                        final locked = _lockedPages.contains(index);
                        return _RegionCell(
                          index: index,
                          imagePath: widget.project.imageFiles[index],
                          annotation: _annotations[index],
                          pageSize: _pageSizes[index],
                          canEdit: !locked,
                          modified: _modified.contains(index),
                          regionConfirmed: _regionConfirmedAt(index),
                          selected: _selectedPages.contains(index),
                          jobDone:
                              jobActive &&
                              locked &&
                              !jobRemaining.contains(index),
                          jobQueued: jobActive && jobRemaining.contains(index),
                          revision: _regionRevisions[index] ?? 0,
                          borderColor: _markers.borderColor(index),
                          emphasized: _markers.isMarked(index),
                          decodeWidth: _decodeWidth,
                          cache: _thumbCache,
                          onTap: _handleCellTap,
                          // 网格上直接拖拽只画主区（拖一个框 = 该页主区
                          // 整组收敛为这一条；左右双页等多个主区进单页
                          // 编辑器设置，不经人工核对，不确认）。
                          onCommitRegion: (rect) =>
                              _saveRegion(index, [rect], const {}, const []),
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildBottomBar() {
    final queue = RecognitionQueue.instance;
    final job = _splitJob;
    final targets = _splitTargets();
    final targetSet = targets.toSet();
    // 断点续跑候选：优先用队列 paused/failed 快照的剩余页，其次用盘上
    // 断点文件；都按当前口径（主区已确认且非整页绿框）过滤一遍。
    var resumePages = const <int>[];
    bool? resumeAi;
    if (_splitJobResumable && job != null) {
      resumePages = job.remainingPages.where(targetSet.contains).toList();
    } else if (_resumeInfo != null) {
      resumePages = _resumeInfo!.pages.where(targetSet.contains).toList();
      resumeAi = _resumeInfo!.aiEnabled;
    }
    final active = _splitJobActive;
    final eta = job?.etaSeconds;

    return Padding(
      padding: const EdgeInsets.all(10),
      // 两行结构：状态一行，批量按钮一行。批量入口多（适配/叠加/取消
      // 确认/预标注/拆分），单行 Row 在窄窗口（800 逻辑宽）会溢出——
      // 按钮行横向可滚，宽窗口下行为不变。
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  active
                      ? '后台拆分中 ${job!.recognizedPages}/${job.totalPages}'
                            '${eta == null ? '' : ' · 预计还需 ${_shortEta(eta)}'}'
                      : resumePages.isNotEmpty
                      ? '上次拆分剩余 ${resumePages.length} 页未完成，可继续'
                      : targets.isNotEmpty
                      ? (_modified.isNotEmpty
                            ? '本次已改 ${_modified.length} 页 · 主区已确认可拆 ${targets.length} 页'
                            : '${targets.length} 页主区已确认，可拆分识别')
                      : '没有主区已确认的待拆分页',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                // 按参考页适配：把参考页各类版面区框按页面尺寸比例复制到其他
                // 页（只写框不识别、不自动确认，页眉/页脚/页码逐页判空）；批量
                // 任务写盘期间禁用。
                OutlinedButton.icon(
                  onPressed:
                      active ||
                          _prelabeling ||
                          _referenceApplying ||
                          _overlayApplying ||
                          _clearingBoxes
                      ? null
                      : _runReferenceApply,
                  icon: const Icon(Icons.copy_all),
                  label: const Text('按参考页适配'),
                ),
                const SizedBox(width: 8),
                // 指定页叠加统一设置：网格 Ctrl/Shift 多选的页（或范围对
                // 话框）叠成一张图统一画版面区，一键写入；只写框不识别，
                // 写了正文的页退回未确认（逐页查看后自己确认）；批量任务
                // 写盘期间禁用。
                OutlinedButton.icon(
                  onPressed:
                      active ||
                          _prelabeling ||
                          _referenceApplying ||
                          _unconfirming ||
                          _overlayApplying ||
                          _clearingBoxes
                      ? null
                      : _runOverlayApply,
                  icon: const Icon(Icons.layers),
                  label: Text(
                    _selectedPages.isEmpty
                        ? '指定页叠加'
                        : '叠加已选 ${_selectedPages.length} 页',
                  ),
                ),
                const SizedBox(width: 8),
                // 取消确认：指定页范围整段退回未确认（用户需求：适配/确认做
                // 过头了能重来）。
                OutlinedButton.icon(
                  onPressed:
                      active ||
                          _prelabeling ||
                          _referenceApplying ||
                          _unconfirming ||
                          _overlayApplying ||
                          _clearingBoxes
                      ? null
                      : _runUnconfirmRange,
                  icon: const Icon(Icons.remove_done),
                  label: const Text('取消确认'),
                ),
                const SizedBox(width: 8),
                // 自动加页眉/页脚候选框（规则预标注）：页眉/页脚/页码/眉批
                // 候选批量落为 proposed 区；后台任务写盘期间禁用。
                OutlinedButton.icon(
                  onPressed:
                      active ||
                          _prelabeling ||
                          _referenceApplying ||
                          _unconfirming ||
                          _overlayApplying ||
                          _clearingBoxes
                      ? null
                      : _runBatchPrelabel,
                  icon: const Icon(Icons.auto_awesome),
                  label: const Text('自动加页眉/页脚候选框'),
                ),
                const SizedBox(width: 8),
                // 清除未确认页识别框：适配/统一设置批量写框试错后一键清
                // 空重来；主区已确认（绿色角标）/校对完成/确认无正文的页
                // 不碰；破坏性操作，弹窗确认后执行。
                OutlinedButton.icon(
                  onPressed:
                      active ||
                          _prelabeling ||
                          _referenceApplying ||
                          _unconfirming ||
                          _overlayApplying ||
                          _clearingBoxes
                      ? null
                      : _runClearUnconfirmedBoxes,
                  icon: const Icon(Icons.delete_sweep),
                  label: const Text('清除未确认页框'),
                ),
                const SizedBox(width: 8),
                if (active) ...[
                  TextButton.icon(
                    onPressed: () => FloatingMonitorWindow.setVisible(true),
                    icon: const Icon(Icons.monitor_heart, size: 18),
                    label: const Text('悬浮窗'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () => queue.pause(widget.project.id),
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('停止任务'),
                  ),
                ] else if (resumePages.isNotEmpty) ...[
                  // 断点续跑优先；全量入口保留（重拆所有满足口径的页）。
                  FilledButton.icon(
                    onPressed: () =>
                        _startBatchSplit(resumePages, aiFromResume: resumeAi),
                    icon: const Icon(Icons.play_circle_fill),
                    label: Text('继续拆分剩余 ${resumePages.length} 页'),
                  ),
                  if (targets.length > resumePages.length) ...[
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: () => _startBatchSplit(targets),
                      icon: const Icon(Icons.done_all),
                      label: Text('全部重拆 ${targets.length} 页'),
                    ),
                  ],
                ] else ...[
                  // 目标＝主区已确认（绿色"已确认"角标）且非整页绿框（确认并
                  // 保存过）的全部页；主区未确认的页不拆。
                  FilledButton.icon(
                    onPressed: targets.isEmpty
                        ? null
                        : () => _startBatchSplit(targets),
                    icon: const Icon(Icons.done_all),
                    label: Text(
                      targets.isEmpty
                          ? '按主区拆分'
                          : '拆分主区已确认的 ${targets.length} 页',
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _shortEta(int seconds) {
    if (seconds < 90) return '$seconds 秒';
    final m = (seconds / 60).round();
    if (m < 90) return '$m 分钟';
    return '${(m / 60).toStringAsFixed(1)} 小时';
  }

  Widget _legend(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(border: Border.all(color: color, width: 2)),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  /// 「本次已改」标记的图例；传入页号时渲染成格子右下角的角标。
  Widget _modifiedChip(int? index) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: index == null ? 6 : 5,
        vertical: index == null ? 2 : 1,
      ),
      decoration: BoxDecoration(
        color: Colors.blue.shade700,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        index == null ? '本次已改' : '已改',
        style: TextStyle(
          color: Colors.white,
          fontSize: index == null ? 12 : 10,
          height: 1.2,
        ),
      ),
    );
  }
}

/// 单个书页格子：降采样缩略图 + 主区框线 + 状态边框 + 页号角标 +
/// 「已改」角标。左键拖拽直接在缩略图上画主区（松手保存，覆盖旧框），
/// 单击打开单页大图精编。
class _RegionCell extends StatefulWidget {
  const _RegionCell({
    required this.index,
    required this.imagePath,
    required this.annotation,
    required this.pageSize,
    required this.canEdit,
    required this.modified,
    required this.revision,
    required this.borderColor,
    required this.emphasized,
    required this.regionConfirmed,
    required this.selected,
    required this.jobDone,
    required this.jobQueued,
    required this.decodeWidth,
    required this.cache,
    required this.onTap,
    required this.onCommitRegion,
  });

  final int index;
  final String imagePath;
  final PageAnnotation? annotation;

  /// 页面原始像素尺寸：框线映射与缩略图画框的坐标基准，
  /// null/零 = 探测失败（只画图不画框、不可画）。
  final Size? pageSize;

  /// false（后台拆分任务锁定该页）时禁止在缩略图上画框。
  final bool canEdit;

  /// 本次快设中改过主区（右下角标）。
  final bool modified;

  /// 后台拆分任务里该页已处理完（左上角绿色"已处理"角标）。
  final bool jobDone;

  /// 后台拆分任务里该页排队/处理中（左上角灰色"队列中"角标）。
  final bool jobQueued;

  /// 主区就地改写的版本号，进画笔触发重画。
  final int revision;
  final Color borderColor;
  final bool emphasized;

  /// 主区框已确认（「保存并下一页」）：右上角绿色角标，可与右下
  /// 「已改」并存（改了几何等待拆分 vs 框已人工核对过）。
  final bool regionConfirmed;

  /// 多选选中（Ctrl/Shift + 单击）：蓝色边框 + 左下角"已选"角标。
  final bool selected;
  final int decodeWidth;
  final PageThumbCache cache;

  /// 格子单击（带修饰键快照）：无修饰键 = 打开单页编辑器；Ctrl/Shift =
  /// 多选。由网格页 [_BookRegionGridPageState._handleCellTap] 分发。
  final void Function(int index, {required bool ctrl, required bool shift})
  onTap;

  /// 缩略图上画框松手后的提交回调（页面像素坐标矩形）。
  final Future<void> Function(Rect pageRect) onCommitRegion;

  @override
  State<_RegionCell> createState() => _RegionCellState();
}

class _RegionCellState extends State<_RegionCell> {
  /// 误触最小框（屏幕像素）：小于它的拖拽视为误触丢弃。
  static const double _minDragScreen = 8;

  ui.Image? _thumb;
  int _requestedIndex = -1;
  int _requestedWidth = 0;

  /// 拖拽中的草稿框与起点（页面像素坐标，与主区存储同一坐标系）。
  Rect? _draft;
  Offset? _drawOrigin;

  @override
  void didUpdateWidget(_RegionCell old) {
    super.didUpdateWidget(old);
    // GridView 会把 State 复用给不同页号的格子，换页时清掉上一页
    // 遗留的草稿。
    if (old.index != widget.index) {
      _draft = null;
      _drawOrigin = null;
    }
  }

  void _ensureThumb() {
    // GridView 会把 State 复用给不同页号的格子，index 与解码宽度都要
    // 纳入"已请求"判断，否则滚动时显示成上一页的缩略图。
    if (_requestedIndex == widget.index &&
        _requestedWidth == widget.decodeWidth) {
      return;
    }
    _requestedIndex = widget.index;
    _requestedWidth = widget.decodeWidth;
    widget.cache.get(widget.index, widget.imagePath, widget.decodeWidth).then((
      image,
    ) {
      // 返回时格宽/页号可能已变化，只接受仍匹配的解码结果。
      if (!mounted ||
          _requestedIndex != widget.index ||
          _requestedWidth != widget.decodeWidth) {
        return;
      }
      setState(() => _thumb = image);
    });
  }

  // ── 缩略图画框：页面像素 ↔ 格子坐标 ──

  /// 格子 contain 布局（与 [_RegionCellPainter] 同一份算法）：
  /// dst = 缩略图在格子内的位置，sx/sy = 页面像素→屏幕的缩放。
  ({Rect dst, double sx, double sy})? _layout() {
    final page = widget.pageSize;
    if (page == null || page.isEmpty) return null;
    final cell = context.size;
    if (cell == null || cell.isEmpty) return null;
    final scale = math.min(cell.width / page.width, cell.height / page.height);
    final dst = Rect.fromLTWH(
      (cell.width - page.width * scale) / 2,
      (cell.height - page.height * scale) / 2,
      page.width * scale,
      page.height * scale,
    );
    return (dst: dst, sx: dst.width / page.width, sy: dst.height / page.height);
  }

  Offset _toPage(Offset local) {
    final lay = _layout()!;
    final page = widget.pageSize!;
    return Offset(
      ((local.dx - lay.dst.left) / lay.sx).clamp(0.0, page.width),
      ((local.dy - lay.dst.top) / lay.sy).clamp(0.0, page.height),
    );
  }

  void _onPanStart(DragStartDetails d) {
    if (!widget.canEdit || _layout() == null) return;
    // Ctrl/Shift 按住时的拖拽是多选手势的一部分，不画主区。
    if (HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isShiftPressed) {
      return;
    }
    final p = _toPage(d.localPosition);
    setState(() {
      _drawOrigin = p;
      _draft = Rect.fromPoints(p, p);
    });
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (_draft == null || _layout() == null) return;
    setState(
      () => _draft = Rect.fromPoints(_drawOrigin!, _toPage(d.localPosition)),
    );
  }

  Future<void> _onPanEnd(DragEndDetails d) async {
    final draft = _draft;
    _drawOrigin = null;
    if (draft == null) return;
    final lay = _layout();
    // 误触（纯点击/过小的框）丢弃，不影响已有主区。
    if (lay == null ||
        draft.width < 2 ||
        draft.height < 2 ||
        draft.width * lay.sx < _minDragScreen ||
        draft.height * lay.sy < _minDragScreen) {
      setState(() => _draft = null);
      return;
    }
    try {
      await widget.onCommitRegion(draft);
    } catch (_) {
      // 落盘失败由网格页记录日志并提示；这里只负责清掉预览。
    }
    if (mounted) setState(() => _draft = null);
  }

  @override
  Widget build(BuildContext context) {
    _ensureThumb();
    final ann = widget.annotation;
    final hasRegion = ann != null && ann.mainRegions.isNotEmpty;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 单击带出修饰键快照：无修饰键 = 打开单页编辑器，Ctrl/Shift = 多选。
      onTap: () => widget.onTap(
        widget.index,
        ctrl: HardwareKeyboard.instance.isControlPressed,
        shift: HardwareKeyboard.instance.isShiftPressed,
      ),
      onPanStart: _onPanStart,
      onPanUpdate: _onPanUpdate,
      onPanEnd: _onPanEnd,
      child: Container(
        clipBehavior: Clip.hardEdge,
        decoration: BoxDecoration(
          border: Border.all(
            color: widget.selected ? Colors.blue : widget.borderColor,
            width: widget.selected || widget.emphasized ? 2.5 : 1,
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              child: CustomPaint(
                painter: _RegionCellPainter(
                  image: _thumb,
                  annotation: ann,
                  pageSize: widget.pageSize,
                  draft: _draft,
                  revision: widget.revision,
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
            if (widget.selected)
              Positioned(left: 4, bottom: 4, child: _selectedBadge()),
            if (widget.regionConfirmed)
              Positioned(right: 4, top: 4, child: _regionConfirmedBadge()),
            if (widget.jobDone)
              Positioned(left: 4, top: 4, child: _jobBadge(true)),
            if (widget.jobQueued)
              Positioned(left: 4, top: 4, child: _jobBadge(false)),
            if (widget.modified)
              Positioned(right: 4, bottom: 4, child: _modifiedBadge()),
            if (ann == null)
              const Center(
                child: Text(
                  '未识别',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
              )
            else if (!hasRegion)
              const Center(
                child: Text(
                  '无主区',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 多选选中角标（左下角，蓝色，与右下「已改」/右上「已确认」错开）。
  Widget _selectedBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.blue.shade700,
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        '✓ 已选',
        style: TextStyle(color: Colors.white, fontSize: 10, height: 1.2),
      ),
    );
  }

  Widget _modifiedBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.blue.shade700,
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        '已改',
        style: TextStyle(color: Colors.white, fontSize: 10, height: 1.2),
      ),
    );
  }

  /// 后台拆分任务角标：已处理（绿）/队列中（灰），左上角。
  Widget _jobBadge(bool done) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: done ? Colors.teal.shade700 : Colors.blueGrey,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        done ? '已处理' : '队列中',
        style: const TextStyle(color: Colors.white, fontSize: 10, height: 1.2),
      ),
    );
  }

  /// 主区框已确认角标（「保存并下一页」）：绿色，与右下「已改」错开。
  Widget _regionConfirmedBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.green.shade700,
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        '已确认',
        style: TextStyle(color: Colors.white, fontSize: 10, height: 1.2),
      ),
    );
  }
}

/// 格子画笔：深色底 + contain 居中的缩略图 + 主区框线（deepPurple，
/// 与编辑器画布约定一致）+ 拖拽草稿（橙）。主区就地改写靠 [revision]
/// 触发重画。
class _RegionCellPainter extends CustomPainter {
  _RegionCellPainter({
    required this.image,
    required this.annotation,
    required this.pageSize,
    required this.draft,
    required this.revision,
  });

  final ui.Image? image;
  final PageAnnotation? annotation;

  /// 页面原始像素尺寸：框线坐标的基准。
  final Size? pageSize;

  /// 拖拽中的草稿框（页面像素坐标）。
  final Rect? draft;
  final int revision;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF1E1E1E),
    );
    final img = image;
    if (img == null) return;
    // contain 布局：有页面原始尺寸时以它为基准（框线映射与手势同一
    // 坐标系），否则退回缩略图自身尺寸（只画图不画框）。
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
    if (page == null || page.isEmpty) return;

    // 框线坐标是页面原始像素，必须按 dst 实际占比归一：缩略图是降采样
    // 解码，直接乘"缩略图像素→格子"的缩放会把框放大数倍并偏移。
    final sx = dst.width / page.width;
    final sy = dst.height / page.height;
    Rect map(Rect r) => Rect.fromLTWH(
      dst.left + r.left * sx,
      dst.top + r.top * sy,
      r.width * sx,
      r.height * sy,
    );
    final ann = annotation;
    if (ann != null) {
      // 主区 deepPurple 粗线（与编辑器画布约定一致）；页眉/页脚等非正文
      // 区按类别配色细线——快设补设的版面区在网格上一眼可见。
      final mainPaint = Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.deepPurple
        ..strokeWidth = 2.0;
      final extraPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      for (final r in ann.mainRegions) {
        final label = RegionLabel.normalize(r.label);
        if (label == RegionLabel.mainText) {
          canvas.drawRect(map(r.rect), mainPaint);
        } else {
          canvas.drawRect(
            map(r.rect),
            extraPaint..color = RegionLabel.color(label),
          );
        }
      }
    }
    final d = draft;
    if (d != null && d.width > 0 && d.height > 0) {
      canvas.drawRect(
        map(d),
        Paint()..color = Colors.orange.withValues(alpha: 0.12),
      );
      canvas.drawRect(
        map(d),
        Paint()
          ..style = PaintingStyle.stroke
          ..color = Colors.orange
          ..strokeWidth = 2.0,
      );
    }
  }

  @override
  bool shouldRepaint(_RegionCellPainter old) =>
      old.image != image ||
      old.annotation != annotation ||
      old.pageSize != pageSize ||
      old.draft != draft ||
      old.revision != revision;
}

/// 单页主区快设编辑器：左键拖拽画框 / 框内拖动移动 / 拖角点调整（全书
/// 叠加同款手势），右键拖动平移，滚轮缩放。**每类可画多个框**（未裁开
/// 的书左右两页正文、左右页脚、多张图片各框一块）：空白处拖出新框即
/// 新增一条，点任意框切换为当前框，Del 删当前框。「保存并下一页」把
/// 各类整组落盘并立即翻页，不触发任何识别——识别统一留给网格页的
/// 「按主区拆分」。Enter 保存并下一页，←/→ 翻页，Esc 返回网格。
class _RegionQuickEditorPage extends StatefulWidget {
  const _RegionQuickEditorPage({
    required this.project,
    required this.initialIndex,
    required this.regionConfirmedFor,
    required this.onSave,
  });

  final Project project;
  final int initialIndex;

  /// 某页主区框是否已确认（网格角标同一口径）：编辑器标题显示当前页
  /// 确认状态，「确认并下一页」后即时点亮；翻页找"下一个未确认页"也
  /// 用它（网格快照口径，导航用途可容忍时差）。**当前页的草稿与确认
  /// 状态不经过它**——进页/翻页时直接读盘（编辑器改框后的级联 flush
  /// 可能在网格快照之后落盘，动作时刻以盘为准）。
  final bool Function(int index) regionConfirmedFor;

  /// 保存回调：落盘主区（[mainRects]，**空 = 本页无正文区**，删除已有
  /// 正文主区并置"无正文确认"标记）与其它类别（[extras]，label → 该类
  /// 全部矩形）；[removedLabels] 为本次清空的类别（删除已有框）。
  /// [confirmRegions] = 「确认并下一页」的确认语义：主区与本次设置的
  /// 类别框打上 boxConfirmed（网格显示"已确认"，可隐藏）。由网格页实现。
  final Future<void> Function(
    int index,
    List<Rect> mainRects,
    Map<String, List<Rect>> extras,
    List<String> removedLabels, {
    bool confirmRegions,
  })
  onSave;

  @override
  State<_RegionQuickEditorPage> createState() => _RegionQuickEditorPageState();
}

class _RegionQuickEditorPageState extends State<_RegionQuickEditorPage> {
  static const double _fitMargin = 0.95;
  static const double _minDrawSize = 8; // 误触最小框（屏幕像素）

  late int _index;
  int _loadToken = 0;

  /// 本页主区框是否已确认（标题显示用；「确认并下一页」后点亮）。
  bool _confirmed = false;

  ui.Image? _image;
  Size _imgSize = Size.zero;
  bool _loadingImage = true;

  /// 本页各类草稿（label → 矩形列表，含 main_text）：一页同类可画多个
  /// 框（页面像素坐标，画布与原图 1:1）。
  final Map<String, List<Rect>> _drafts = {};

  // ── 页眉/页脚等非正文类别（快捷键 1~8 与编辑器主区视图同一词表）──
  // 当前编辑类别 _activeLabel 里的第 _activeIndex 个框为"当前框"（橙色 +
  // 角点），其余框（含其它类别）细线显示、点框内即切换为当前框；
  // **-1 = 未选中**（点击空白取消选择，只有类别色细线、没有橙色框）。
  String _activeLabel = RegionLabel.mainText;
  int _activeIndex = 0;

  /// 进入本页时的各类快照（未改动不落盘 + 「恢复原区」）。
  Map<String, List<Rect>> _initialDrafts = const {};

  final TransformationController _transform = TransformationController();
  Offset? _panAnchor;
  Size? _viewportSize;

  _DragMode _mode = _DragMode.none;
  Offset? _drawOrigin;

  /// 开始画新框前当前类别的框数与选中态（可能为 null）：空白/页面外
  /// **纯点击**会走 draw 分支并立刻追加一个空框，松手时的误触判定靠它
  /// 截断——否则点一下空白就多出一个点框（用户要求：点击页外不动已画
  /// 的框）。
  int? _preDrawCount;
  int? _preDrawActiveIndex;

  /// 角点拖动锚点（与编辑器画布同一套体验，见 [AnnotationHitGeometry]）：
  /// 按下点相对角点圆心的偏移。拖动期间角点 = 指针 - 偏移——点击命中
  /// 区内任意点开始拖，圆心与鼠标保持对齐不跳动。
  Offset? _resizePointerOffset;

  /// 按下时的矩形快照：拖动只动被抓的边，对边沿用快照原值（防连续
  /// 事件的取整漂移），见 [AnnotationHitGeometry.resizeRect]。
  Rect? _resizeOriginalRect;

  // ── 鼠标中键手势（按住中键拖出方向序列，松手匹配触发）──
  final MouseGestureTracker _gestureTracker = MouseGestureTracker();
  GestureSettings _gestureSettings = const GestureSettings();
  bool _gestureActive = false;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _loadPage();
    // 鼠标中键手势配置：进页加载一次缓存，松手判定时直接查内存。
    GestureSettings.load().then((s) {
      if (mounted) setState(() => _gestureSettings = s);
    });
    // "本书不再显示无正文提醒"的按书记忆。
    SharedPreferences.getInstance().then((prefs) {
      final v = prefs.getBool(_noMainPromptPrefKey);
      if (v != null && mounted && v) _noMainPromptSuppressed = true;
    });
  }

  @override
  void dispose() {
    _image?.dispose();
    _transform.dispose();
    super.dispose();
  }

  int get _pageCount => widget.project.imageFiles.length;

  Future<void> _loadPage() async {
    final token = ++_loadToken;
    final path = widget.project.imageFiles[_index];
    // 草稿基线读盘（不是网格快照）：校对页改主区形状后的级联 flush 可
    // 能在网格快照建立之后才落盘——动作时刻以盘为准，「最后修改者胜」。
    final diskAnn = await ProjectStorage.loadAnnotation(
      widget.project.projectDir,
      pageIdForImage(path, _index),
    );
    if (!mounted || token != _loadToken) return;
    final rects = <Rect>[
      for (final r in diskAnn?.mainRegions ?? const <MainRegion>[])
        if (RegionLabel.normalize(r.label) == RegionLabel.mainText) r.rect,
    ];
    final extras = <String, List<Rect>>{};
    for (final r in diskAnn?.mainRegions ?? const <MainRegion>[]) {
      final label = RegionLabel.normalize(r.label);
      if (label == RegionLabel.mainText) continue;
      (extras[label] ??= []).add(r.rect);
    }
    // 旧图等本帧结束后再释放：本帧可能还有最后一次绘制引用它。
    final stale = _image;
    setState(() {
      _image = null;
      _imgSize = Size.zero;
      _drafts
        ..clear()
        // 现有框全部作为初始草稿（每类多条：左右页、多张图都保得住）。
        ..addAll({
          if (rects.isNotEmpty) RegionLabel.mainText: List.of(rects),
          for (final e in extras.entries)
            if (e.value.isNotEmpty) e.key: List.of(e.value),
        });
      _initialDrafts = {
        for (final e in _drafts.entries) e.key: List.of(e.value),
      };
      _confirmed = BookRegionGridPage.pageRegionConfirmed(diskAnn);
      // 翻页后回到正文类别的第一个框：主区是快设的主线，页眉/页脚等
      // 是顺手补设。
      _activeLabel = RegionLabel.mainText;
      _activeIndex = 0;
      _loadingImage = true;
    });
    if (stale != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => stale.dispose());
    }
    try {
      final data = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(data);
      final frame = await codec.getNextFrame();
      if (!mounted || token != _loadToken) {
        frame.image.dispose();
        return;
      }
      setState(() {
        _image = frame.image;
        _imgSize = Size(
          frame.image.width.toDouble(),
          frame.image.height.toDouble(),
        );
        _loadingImage = false;
      });
      _fitInitialView();
    } catch (_) {
      if (!mounted || token != _loadToken) return;
      setState(() => _loadingImage = false);
    }
  }

  /// 翻页后把画布缩放到整页可见居中。
  void _fitInitialView() {
    if (_imgSize.isEmpty) return;
    final vp = _viewportSize;
    if (vp == null || vp.width <= 0 || vp.height <= 0) return;
    final scale =
        math.min(vp.width / _imgSize.width, vp.height / _imgSize.height) *
        _fitMargin;
    final tx = (vp.width - _imgSize.width * scale) / 2;
    final ty = (vp.height - _imgSize.height * scale) / 2;
    _transform.value = Matrix4.translationValues(
      tx,
      ty,
      0,
    ).multiplied(Matrix4.identity()..scaleByDouble(scale, scale, 1, 1));
  }

  // ── 翻页 / 保存 ──

  void _goTo(int index) {
    final next = index.clamp(0, _pageCount - 1).toInt();
    if (next == _index && _image != null) return;
    setState(() => _index = next);
    _loadPage();
  }

  void _goNext() {
    if (_index + 1 < _pageCount) {
      _goTo(_index + 1);
    } else {
      _popEditor();
    }
  }

  /// 当前页之后是否还有未确认的页（「确认并下一页」按钮文案用：身后
  /// 全确认过时按钮显示「确认并返回」）。
  bool get _hasUnconfirmedAhead {
    for (var i = _index + 1; i < _pageCount; i++) {
      if (!widget.regionConfirmedFor(i)) return true;
    }
    return false;
  }

  /// 「确认并下一页」的落点：当前页之后第一个**尚未确认**的页——已确认
  /// 的页直接跳过（逐页过全书不在已确认的页上反复停留）；身后没有未确认
  /// 页时退出编辑器。「跳过此页」按钮与 nextPage 手势仍是顺序翻页。
  void _goNextUnconfirmed() {
    for (var i = _index + 1; i < _pageCount; i++) {
      if (!widget.regionConfirmedFor(i)) {
        _goTo(i);
        return;
      }
    }
    _popEditor();
  }

  void _popEditor() => Navigator.of(context).pop(_straightenedPages);

  /// 本次进入编辑器后摆正过的页（pop 时带回网格页：清标注内存态、
  /// 失效缩略缓存、重探页面尺寸）。
  final Set<int> _straightenedPages = {};

  // ── 无正文页确认提示的按书记忆（勾选"本书不再显示"后直接保存）──
  static const String _prefNoMainPromptOffPrefix =
      'region_grid_no_main_prompt_off_';
  bool _noMainPromptSuppressed = false;

  String get _noMainPromptPrefKey =>
      _prefNoMainPromptOffPrefix + widget.project.projectDir;

  /// 打开「校对摆正」页（与编辑器同一套链路，规则见
  /// [straightenOutPath]）：透视拉平后旧框几何失真，确认后清空本页
  /// 标注；原始图片保留，摆正结果写入 warped/ 并替换本页文件。
  Future<void> _openStraighten() async {
    final project = widget.project;
    final index = _index;
    final currentPath = project.imageFiles[index];
    final pageId = pageIdForImage(currentPath, index);
    final annDir = p.join(project.projectDir, 'annotations');
    final hadAnnotation = await File(p.join(annDir, '$pageId.json')).exists();
    if (!mounted) return;

    if (hadAnnotation) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('校对摆正该页？'),
          content: const Text(
            '该页已有识别框：透视拉平后框坐标会失真，摆正后将清空本页'
            '已画的框，需要在完成后重新框。\n原始图片会保留，摆正结果'
            '写入 warped/ 新文件。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.crop_free),
              label: const Text('开始摆正'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }

    final outPath = straightenOutPath(
      projectDir: project.projectDir,
      index: index,
      currentPath: currentPath,
    );
    final applied = await Navigator.of(context).push<PageQuad>(
      MaterialPageRoute(
        builder: (_) => StraightenPage(
          imagePath: currentPath,
          outPath: outPath,
          title: '校对摆正 · 第 ${index + 1} 页',
        ),
      ),
    );
    if (!mounted || applied == null) return;

    for (final suffix in ['.json', '.json.bak']) {
      final f = File(p.join(annDir, pageId + suffix));
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {
        // 清理失败不阻断换页；旧标注随后会被重新框覆盖或成孤儿。
      }
    }
    project.imageFiles[index] = outPath;
    if (hadAnnotation && project.recognizedPages > 0) {
      project.recognizedPages -= 1;
    }
    await ProjectStorage.save(project);
    FileImage(File(currentPath)).evict();
    FileImage(File(outPath)).evict();
    _straightenedPages.add(index);
    PythonService.addAppLog(
      '[主区快设] 第 ${index + 1} 页已摆正'
      '（$currentPath → $outPath），本页框已清空待重框',
    );
    // 摆正后当前页图片与尺寸都变了：重载草稿与视图。
    await _loadPage();
    _fitInitialView();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(hadAnnotation ? '该页已摆正，原框已清空，请重新框' : '该页已摆正')),
    );
  }

  Future<void> _saveAndNext() async {
    // 过小的框（<2px）不落盘——视为误触残留而非正文。
    final mainRects = [
      for (final r in _rectsOf(RegionLabel.mainText))
        if (r.width >= 2 && r.height >= 2) r,
    ];
    if (mainRects.isEmpty && !_noMainPromptSuppressed) {
      // 无正文区页（扉页/插图/空白页）：确认后按"本页无正文"保存——
      // 弹一次确认防误触（比如忘了画或没切对类别）；可勾选"本书不再
      // 显示"，此后本书内无正文页直接确认。
      var suppress = false;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('本页没有正文区'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '按"无正文页"保存并翻到下一页？\n'
                  '（扉页/插图/空白页等没有正文区的页面直接确认即可；'
                  '页眉/页脚等已画的框仍会保存）',
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: suppress,
                  title: const Text(
                    '本书不再显示此提醒（无正文页直接确认）',
                    style: TextStyle(fontSize: 13),
                  ),
                  onChanged: (v) => setDialogState(() => suppress = v ?? false),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('确认无正文'),
              ),
            ],
          ),
        ),
      );
      if (ok != true || !mounted) return;
      if (suppress) {
        _noMainPromptSuppressed = true;
        SharedPreferences.getInstance().then(
          (prefs) => prefs.setBool(_noMainPromptPrefKey, true),
        );
        PythonService.addAppLog(
          '[主区快设] 已按书关闭"无正文页"确认提醒（${widget.project.name}）',
        );
      }
    }
    // 其它类别：本类还有框的全部落盘；初始有、现在清空的类别落盘删除。
    final extras = <String, List<Rect>>{
      for (final e in _drafts.entries)
        if (e.key != RegionLabel.mainText && e.value.isNotEmpty)
          e.key: List.of(e.value),
    };
    final removedLabels = [
      for (final label in _initialDrafts.keys)
        if (label != RegionLabel.mainText && _rectsOf(label).isEmpty) label,
    ];
    // 「保存并下一页」= 人工核过本页框，恒走保存（确认标记本身也是
    // 状态：几何未变但尚未确认的页要点一下才转"已确认"）。是否真的
    // 需要写盘由网格端比对（那里才有 boxConfirmed 的现状）。
    await widget.onSave(
      _index,
      mainRects,
      extras,
      removedLabels,
      confirmRegions: true,
    );
    if (!mounted) return;
    setState(() => _confirmed = true);
    _goNextUnconfirmed();
  }

  // ── 画布交互（与全书叠加页同一套手势）──

  /// 某类当前的框列表（无则空）。
  List<Rect> _rectsOf(String label) => _drafts[label] ?? const [];

  /// 当前框：当前类别第 [_activeIndex] 个（橙色边线 + 角点，可拖动/调角
  /// ，底色保持类别色）。手势与绘制只认它，点其它框（或切类别）即换操作
  /// 对象；**-1 = 未选中**（点空白取消选择后的状态）。
  Rect? get _activeDraft {
    final list = _rectsOf(_activeLabel);
    return _activeIndex >= 0 && _activeIndex < list.length
        ? list[_activeIndex]
        : null;
  }

  /// 写回当前框几何（画/移动/缩放的手势更新路径；列表一定已存在——
  /// 画新框先经 _beginDrawAt 建列表）。
  set _activeDraft(Rect? value) {
    if (value == null) return;
    final list = _drafts[_activeLabel];
    if (list == null || _activeIndex < 0 || _activeIndex >= list.length) {
      return;
    }
    list[_activeIndex] = value;
  }

  /// 画新框：当前类别**追加**一条（同类可画多个），并把当前框切到它。
  void _beginDrawAt(Offset p) {
    final list = _drafts.putIfAbsent(_activeLabel, () => []);
    _preDrawCount = list.length;
    _preDrawActiveIndex = _activeIndex;
    _activeIndex = list.length;
    list.add(Rect.fromPoints(p, p));
  }

  /// 误触（纯点击/过小拖动）回滚：截掉本次画框追加的部分。[deselect]
  /// = 松手判定为"点击空白"——回滚外**取消选择**（用户要求：点空白
  /// 取消选中当前框）；指针被系统打断（onPanCancel）只回滚、恢复画前
  /// 的选中态。
  void _undoAccidentalDraw({bool deselect = false}) {
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
    _activeIndex = deselect
        ? -1
        : (_preDrawActiveIndex ?? _activeIndex).clamp(0, list.length - 1);
  }

  /// 删除当前框（Del/「删除当前框」按钮）：未选中时不动任何框；同类
  /// 还有别的框时当前框切到剩余的最后一条。
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

  /// 点击命中的（类别, 下标）：当前框优先（可拖动/调角），其余框——
  /// 含同类非当前框与其它类别——点框内即切换为当前框。
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

  // getMaxScaleOnAxis 会把恒为 1 的 z 轴当最大值永远返回 1.0，必须取 x/y 轴。
  double get _viewScale => matrixXyScale(_transform.value);

  /// 视口（屏幕）坐标 → 页面像素坐标。手势层覆盖整个视口（页面外空白
  /// 也能画框），回调给的是视口坐标，一律先经当前变换的逆矩阵映射。
  Offset _toImage(Offset screenPos) =>
      MatrixUtils.transformPoint(Matrix4.inverted(_transform.value), screenPos);

  void _panBy(Offset screenDelta) {
    final m = _transform.value;
    _transform.value = Matrix4.translationValues(
      screenDelta.dx,
      screenDelta.dy,
      0,
    ).multiplied(m);
  }

  /// 以屏幕坐标 [focalScreen] 为焦点的滚轮缩放（替代 InteractiveViewer
  /// 的内置缩放，方向一致：向下滚 0.9 缩小、向上滚 1.1 放大）：光标
  /// 指向的页面点在缩放前后保持不动。
  ///
  /// 增量必须**复合在旧矩阵上**（在页面坐标系里绕焦点缩放后仍走旧
  /// 变换）：首版用 T(focal)·S(δ)·T(−scene) 从恒等式整体重建，旧缩放
  /// 被丢掉——滚一次矩阵缩放就变成 0.9/1.1 本身，大图（适配缩放
  /// 0.1~0.3）一滚就跳到约 1 倍且再也缩不回去（怎么滚都"最大"）。
  /// 与编辑器页 `_zoomAt` 同一套右乘写法。
  void _zoomAt(Offset focalScreen, double factor) {
    final currentScale = _viewScale;
    final targetScale = (currentScale * factor).clamp(0.05, 8.0);
    final delta = targetScale / currentScale;
    final scenePoint = _toImage(focalScreen);
    _transform.value = _transform.value.clone()
      ..translateByDouble(scenePoint.dx, scenePoint.dy, 0, 1)
      ..scaleByDouble(delta, delta, 1, 1)
      ..translateByDouble(-scenePoint.dx, -scenePoint.dy, 0, 1);
  }

  Offset _clampToCanvas(Offset p) => Offset(
    p.dx.clamp(0.0, math.max(_imgSize.width, 0.0)),
    p.dy.clamp(0.0, math.max(_imgSize.height, 0.0)),
  );

  /// 角点/边线命中（只对**当前类别**的框生效——页面上的页眉/页脚等
  /// 其它框不参与吸附，点它们的框内仍是"切换类别+移动"）。参考摆正
  /// 页面的吸附方案：角点命中半径刻意远大于视觉手柄（摆正页角点视觉
  /// 13px、命中 100px，"抓取不需要精确对点"），另加边线抓取（落在边
  /// 线附近即拖整条边）。小框保护：吸附范围不超过框短边的四成——
  /// 页眉/页码这类矮框的吸附圈不越过框中心，点框内仍然是移动。
  _DragMode? _dragModeAt(Rect rect, Offset p) {
    // ① 角点：100 屏幕像素（随缩放反向放大），取最近的角。
    var radius = 100 / _viewScale;
    final shortSide = math.min(rect.width, rect.height);
    final cap = shortSide * 0.4;
    final floor = 12 / _viewScale;
    if (cap > 0 && radius > cap) radius = math.max(cap, floor);
    final corners = <_DragMode>[
      _DragMode.resizeTL,
      _DragMode.resizeTR,
      _DragMode.resizeBL,
      _DragMode.resizeBR,
    ];
    final cornerPoints = [
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
    ];
    var bestMode = -1;
    var bestDist = double.infinity;
    for (var i = 0; i < cornerPoints.length; i++) {
      final d = (cornerPoints[i] - p).distance;
      if (d <= radius && d < bestDist) {
        bestMode = i;
        bestDist = d;
      }
    }
    if (bestMode >= 0) return corners[bestMode];

    // ② 边线：±28 屏幕像素（同摆正页），深度同样受短边 35% 限制。
    final depth = math.min(28 / _viewScale, shortSide * 0.35);
    if (depth > 0) {
      final withinY = p.dy >= rect.top - depth && p.dy <= rect.bottom + depth;
      final withinX = p.dx >= rect.left - depth && p.dx <= rect.right + depth;
      final distL = (p.dx - rect.left).abs();
      final distR = (p.dx - rect.right).abs();
      final distT = (p.dy - rect.top).abs();
      final distB = (p.dy - rect.bottom).abs();
      if (withinY && withinX) {
        // 四边都够近时取最近的一条，避免角落斜向区误判。
        final nearest = <(_DragMode, double)>[
          (_DragMode.edgeL, distL),
          (_DragMode.edgeR, distR),
          (_DragMode.edgeT, distT),
          (_DragMode.edgeB, distB),
        ]..sort((a, b) => a.$2.compareTo(b.$2));
        if (nearest.first.$2 <= depth) return nearest.first.$1;
      }
    }
    return null;
  }

  static final List<AnnotationResizeHandle> _resizeHandles = [
    // 与 _DragMode.resizeTL..resizeBR 声明顺序一致（index 映射用）。
    AnnotationResizeHandle.topLeft,
    AnnotationResizeHandle.topRight,
    AnnotationResizeHandle.bottomLeft,
    AnnotationResizeHandle.bottomRight,
  ];

  void _onPanStart(DragStartDetails d) {
    // 视口坐标 → 页面坐标后钳回页面：页面外按下时起点贴到最近的页面
    // 边缘，画出的框始终限制在页面范围内。
    final p = _clampToCanvas(_toImage(d.localPosition));
    final rect = _activeDraft;
    if (rect != null && rect.width > 0 && rect.height > 0) {
      final mode = _dragModeAt(rect, p);
      if (mode != null) {
        _mode = mode;
        _resizeOriginalRect = rect;
        // 锚点 = 按下点相对抓取位置的偏移：角点用"相对角心"；拖边用
        // "相对被拖那条边"的对应轴分量（见 _edgeAnchor），拖动全程不
        // 突跳。
        _resizePointerOffset = _isEdgeMode(mode)
            ? _edgeAnchor(rect, mode, p)
            : p - _anchorCorner(rect, mode);
        return;
      }
      if (rect.contains(p)) {
        _mode = _DragMode.move;
        return;
      }
    }
    // 点进其它框（其它类别或同类其它框）：切换为当前框并进入移动——
    // 不用回敲数字键也能调已有框（非当前框不做角点吸附，见 _dragModeAt）。
    final hit = _hitDraft(p);
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
    setState(() => _beginDrawAt(p)); // 纯点击误触时靠 _preDrawCount 截断
  }

  static bool _isEdgeMode(_DragMode m) =>
      m == _DragMode.edgeL ||
      m == _DragMode.edgeT ||
      m == _DragMode.edgeR ||
      m == _DragMode.edgeB;

  /// 拖边锚点：按下点相对**被拖那条边**的偏移（只取该边的轴分量）。
  /// update 里"新边坐标 = 指针 − 锚点"，锚点原点必须与边坐标同一原点：
  /// 右边相对 right、下边相对 bottom——统一按"相对左上"折算的话，右/
  /// 下边首帧会瞬间跳到对边（left+20 / top+20）重叠，得重新点按才能
  /// 拖（用户实测：拖右侧/下部中点手柄整条边先跳走）。
  Offset _edgeAnchor(Rect rect, _DragMode mode, Offset p) => switch (mode) {
    _DragMode.edgeL => Offset(p.dx - rect.left, 0),
    _DragMode.edgeR => Offset(p.dx - rect.right, 0),
    _DragMode.edgeT => Offset(0, p.dy - rect.top),
    _DragMode.edgeB => Offset(0, p.dy - rect.bottom),
    _ => Offset.zero,
  };

  /// 角点拖动模式下被抓的角心（与 _resizeHandles 同一顺序语义）。
  Offset _anchorCorner(Rect rect, _DragMode mode) => switch (mode) {
    _DragMode.resizeTL => rect.topLeft,
    _DragMode.resizeTR => rect.topRight,
    _DragMode.resizeBL => rect.bottomLeft,
    _DragMode.resizeBR => rect.bottomRight,
    _ => rect.topLeft,
  };

  void _onPanUpdate(DragUpdateDetails d) {
    final rect = _activeDraft;
    if (rect == null) return;
    // 手势层在 InteractiveViewer 外，localPosition/delta 都是视口（屏幕）
    // 坐标：位置经 _toImage 逆变换，位移按当前缩放折算成页面像素。
    final pagePos = _toImage(d.localPosition);
    Rect next;
    switch (_mode) {
      case _DragMode.none:
        return;
      case _DragMode.draw:
        next = Rect.fromPoints(_drawOrigin!, _clampToCanvas(pagePos));
      case _DragMode.move:
        final shifted = rect.shift(d.delta / _viewScale);
        // 移动不允许超出页面。
        final dx = shifted.left < 0
            ? -shifted.left
            : shifted.right > _imgSize.width
            ? _imgSize.width - shifted.right
            : 0.0;
        final dy = shifted.top < 0
            ? -shifted.top
            : shifted.bottom > _imgSize.height
            ? _imgSize.height - shifted.bottom
            : 0.0;
        next = shifted.translate(dx, dy);
      case _DragMode.resizeTL:
      case _DragMode.resizeTR:
      case _DragMode.resizeBL:
      case _DragMode.resizeBR:
        // 与编辑器同一套角点拖动几何：指针减按下偏移（圆心对齐鼠标）、
        // 对边沿用按下快照（防漂移）、最小尺寸限制、再钳回页面范围。
        final handle = _resizeHandles[_mode.index - _DragMode.resizeTL.index];
        next = AnnotationHitGeometry.resizeRect(
          _resizeOriginalRect ?? rect,
          _clampToCanvas(pagePos),
          handle,
          pointerOffset: _resizePointerOffset ?? Offset.zero,
          minSize: 20,
        );
        final pageW = math.max(_imgSize.width, 0.0);
        final pageH = math.max(_imgSize.height, 0.0);
        next = Rect.fromLTRB(
          next.left.clamp(0.0, pageW),
          next.top.clamp(0.0, pageH),
          next.right.clamp(0.0, pageW),
          next.bottom.clamp(0.0, pageH),
        );
      case _DragMode.edgeL:
      case _DragMode.edgeR:
      case _DragMode.edgeT:
      case _DragMode.edgeB:
        // 拖整条边：该边跟随指针（减按下锚点），对边沿用按下快照，
        // 单边可推进的最深位置受 minSize 限制，再钳回页面范围。
        final snap = _resizeOriginalRect ?? rect;
        final anchor = _resizePointerOffset ?? Offset.zero;
        final target = pagePos - anchor;
        final pageW = math.max(_imgSize.width, 0.0);
        final pageH = math.max(_imgSize.height, 0.0);
        switch (_mode) {
          case _DragMode.edgeL:
            final left = target.dx.clamp(0.0, snap.right - 20);
            next = Rect.fromLTRB(left, rect.top, snap.right, rect.bottom);
          case _DragMode.edgeR:
            final right = target.dx.clamp(snap.left + 20, pageW);
            next = Rect.fromLTRB(snap.left, rect.top, right, rect.bottom);
          case _DragMode.edgeT:
            final top = target.dy.clamp(0.0, snap.bottom - 20);
            next = Rect.fromLTRB(rect.left, top, rect.right, snap.bottom);
          case _DragMode.edgeB:
            final bottom = target.dy.clamp(snap.top + 20, pageH);
            next = Rect.fromLTRB(rect.left, snap.top, rect.right, bottom);
          default:
            return;
        }
        next = Rect.fromLTRB(
          next.left.clamp(0.0, pageW),
          next.top.clamp(0.0, pageH),
          next.right.clamp(0.0, pageW),
          next.bottom.clamp(0.0, pageH),
        );
    }
    setState(() => _activeDraft = next);
  }

  void _onPanEnd(DragEndDetails d) {
    if (_mode == _DragMode.draw) {
      final r = _activeDraft;
      // 纯点击/过小的拖动（含点在页面外空白被钳到边缘的）：不留下
      // 新框——截掉本次追加的部分并取消选择（点击空白 = 取消选中
      // 当前框）。只有真正拖出一个足够大的框才保留。
      if (r == null ||
          r.width < _minDrawSize / _viewScale ||
          r.height < _minDrawSize / _viewScale) {
        setState(() => _undoAccidentalDraw(deselect: true));
      }
    }
    _mode = _DragMode.none;
    _resizePointerOffset = null;
    _resizeOriginalRect = null;
    _preDrawCount = null;
    _preDrawActiveIndex = null;
  }

  // ── build ──

  /// 快捷键 1~8 与小键盘 1~8：切换「当前类别」（与编辑器主区视图同
  /// 一词表，键数与 RegionLabel 词表长度对齐）。
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

  Widget _bindDigitShortcuts(Map<ShortcutActivator, VoidCallback> bindings) {
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
    return CallbackShortcuts(
      bindings: bindings,
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            title: Text(
              _confirmed
                  ? '主区快设 · 第 ${_index + 1} / $_pageCount 页 · 已确认'
                  : '主区快设 · 第 ${_index + 1} / $_pageCount 页',
            ),
            bottom: _buildLabelBar(),
            actions: [
              IconButton(
                icon: const Icon(Icons.crop_free),
                tooltip:
                    '校对摆正：智能检测裁切点，透视拉平书页（可去色/锐化）；'
                    '摆正后本页框会清空待重框',
                onPressed: _loadingImage
                    ? null
                    : () => unawaited(_openStraighten()),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_left),
                tooltip: '上一页（不保存）',
                onPressed: _index > 0 ? () => _goTo(_index - 1) : null,
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                tooltip: '下一页（不保存）',
                onPressed: _index < _pageCount - 1
                    ? () => _goTo(_index + 1)
                    : null,
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: _buildBody(),
          bottomNavigationBar: _buildBottomBar(_isLast),
        ),
      ),
    );
  }

  bool get _isLast => _index >= _pageCount - 1;

  /// 当前类别快切栏（编辑器主区视图同款：色点 + 名 + 数字键提示）。
  PreferredSizeWidget _buildLabelBar() {
    return PreferredSize(
      preferredSize: const Size.fromHeight(42),
      child: Container(
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Colors.black12)),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
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
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _bindDigitShortcuts({
      const SingleActivator(LogicalKeyboardKey.enter): () =>
          unawaited(_saveAndNext()),
      const SingleActivator(LogicalKeyboardKey.numpadEnter): () =>
          unawaited(_saveAndNext()),
      const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
        if (_index > 0) _goTo(_index - 1);
      },
      const SingleActivator(LogicalKeyboardKey.arrowRight): () {
        if (_index < _pageCount - 1) _goTo(_index + 1);
      },
      // Del：删除当前框（与「删除当前框」按钮、手势同一动作）。
      const SingleActivator(LogicalKeyboardKey.delete): () =>
          setState(() => _removeActiveDraft()),
      const SingleActivator(LogicalKeyboardKey.escape): _popEditor,
    });
  }

  Widget _buildBody() {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 记录视口尺寸供翻页后的整页适配缩放用（加载期间也要捕获，
        // 否则首帧拿不到）。
        _viewportSize = constraints.biggest;
        final img = _image;
        if (_loadingImage || img == null || _imgSize.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        return Stack(
          children: [
            Positioned.fill(
              child: Listener(
                // 右键拖动平移（编辑器同款习惯），左键留给矩形手势，
                // 中键拖动画手势（方向序列见 mouse_gesture.dart）。
                onPointerDown: (e) {
                  if (e.buttons == kMiddleMouseButton) {
                    _onGestureDown(e);
                  } else if (e.buttons == kSecondaryButton) {
                    _panAnchor = e.position;
                  }
                },
                onPointerMove: (e) {
                  if (_gestureActive && e.buttons == kMiddleMouseButton) {
                    _onGestureMove(e);
                  } else if (e.buttons == kSecondaryButton &&
                      _panAnchor != null) {
                    _panBy(e.position - _panAnchor!);
                    _panAnchor = e.position;
                  }
                },
                onPointerUp: (e) {
                  _panAnchor = null;
                  if (_gestureActive) _onGestureUp();
                },
                onPointerCancel: (e) {
                  _panAnchor = null;
                  if (_gestureActive) {
                    _gestureTracker.cancel();
                    setState(() => _gestureActive = false);
                  }
                },
                // 手势层覆盖整个视口（不是只有页面）：缩放后页面四周的
                // 空白处也能按下画框/拖角——起点落在页面外时由
                // _clampToCanvas 钳到页面边缘，框的范围始终限制在页面内。
                //
                // 不用 InteractiveViewer：即使 panEnabled/scaleEnabled 全
                // 关，它内部的 scale 识别器仍在手势竞技场里（更深处先入
                // 场，默认裁决获胜），外层画框手势一条都收不到（widget
                // 测试实测复现）。这里只需要"矩阵变换展示 + 滚轮缩放"，
                // Transform + 自实现缩放即可，画框手势独享竞技场。
                //
                // 尺寸结构：SizedBox.expand 让手势层铺满视口（GestureDetector
                // 的命中范围随 child 尺寸；Transform 的渲染尺寸=页面尺寸，
                // 不撑开的话手势层缩成页面大小，页外空白收不到事件）；
                // OverflowBox（左上对齐、无界）让页面子树保持 1:1 自身
                // 尺寸，不被视口约束拉伸——即 InteractiveViewer
                // constrained:false 的等价物。
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: _onPanStart,
                  onPanUpdate: _onPanUpdate,
                  onPanEnd: _onPanEnd,
                  // 纯点击（无位移）不会触发 pan（识别器未过 slop 即在
                  // 竞技场出局）：单击空白 = 取消选择当前框，单击某个框 =
                  // 选中它——拖拽调整照旧走 pan。
                  onTapUp: (d) {
                    final p = _clampToCanvas(_toImage(d.localPosition));
                    final hit = _hitDraft(p);
                    if (hit == null) {
                      if (_activeIndex != -1) {
                        setState(() => _activeIndex = -1);
                      }
                    } else {
                      setState(() {
                        _activeLabel = hit.label;
                        _activeIndex = hit.index;
                      });
                    }
                  },
                  // 指针被系统打断（窗口失焦等）：画到一半的框不留，
                  // 截掉本次追加的部分（保持画前选中态，不算"点击空白"）。
                  onPanCancel: () {
                    if (_mode == _DragMode.draw) {
                      setState(() => _undoAccidentalDraw());
                    }
                    _mode = _DragMode.none;
                    _resizePointerOffset = null;
                    _resizeOriginalRect = null;
                    _preDrawCount = null;
                    _preDrawActiveIndex = null;
                  },
                  child: Listener(
                    // 滚轮缩放（以光标为焦点，方向与 InteractiveViewer
                    // 默认一致：向下滚缩小）。opaque：Listener 默认
                    // deferToChild，页面子树只覆盖页面本身——页外空白
                    // 处滚轮会失灵。
                    behavior: HitTestBehavior.opaque,
                    onPointerSignal: (signal) {
                      if (signal is PointerScrollEvent) {
                        _zoomAt(
                          signal.localPosition,
                          signal.scrollDelta.dy > 0 ? 0.9 : 1.1,
                        );
                      }
                    },
                    child: SizedBox.expand(
                      child: ClipRect(
                        child: OverflowBox(
                          // InteractiveViewer constrained:false 的等价物
                          //（四个边界参数缺一不可：全 null 的 OverflowBox
                          // 不改变约束，页面子树会被视口 tight 约束拉成
                          // 视口大小，整页图被拉伸绘制）。
                          alignment: Alignment.topLeft,
                          minWidth: 0.0,
                          minHeight: 0.0,
                          maxWidth: double.infinity,
                          maxHeight: double.infinity,
                          child: AnimatedBuilder(
                            animation: _transform,
                            builder: (context, _) => Transform(
                              transform: _transform.value,
                              child: SizedBox(
                                width: _imgSize.width,
                                height: _imgSize.height,
                                child: CustomPaint(
                                  painter: _RegionEditorPainter(
                                    image: img,
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
                    ),
                  ),
                ),
              ),
            ),
            // 右侧统计面板：当前页各类区域的数量一览（只列已画的类）。
            // IgnorePointer：纯展示，不挡底下的画框/拖拽手势。
            Positioned(
              top: 8,
              right: 8,
              child: IgnorePointer(child: _buildCountsPanel()),
            ),
            // 中键手势拖动轨迹（松手即消失）：IgnorePointer 不挡任何交互。
            if (_gestureActive)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: GestureTrailPainter(points: _gestureTracker.trail),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  // ── 鼠标中键手势 ──

  void _onGestureDown(PointerEvent e) {
    if (!_gestureSettings.enabled) return;
    _gestureTracker.start(e.localPosition);
    setState(() => _gestureActive = true);
  }

  void _onGestureMove(PointerEvent e) {
    _gestureTracker.extend(e.localPosition);
    setState(() {}); // 只重画轨迹层（painter 按 trail 变化重绘）
  }

  void _onGestureUp() {
    final seq = _gestureTracker.finish();
    setState(() => _gestureActive = false);
    if (seq == null) return; // 位移太小：视为中键点击，不触发
    final action = _gestureSettings.quick[seq];
    if (action != null) _runQuickGestureAction(action);
  }

  /// 手势动作分发（动作 id 见 [GestureCatalog.quickActions]）。
  void _runQuickGestureAction(String id) {
    switch (id) {
      case 'confirmNext':
        unawaited(_saveAndNext());
      case 'prevPage':
        if (_index > 0) _goTo(_index - 1);
      case 'nextPage':
        _goNext();
      case 'restore':
        _restoreInitialRegions();
      case 'clearActive':
        setState(() => _removeActiveDraft());
    }
  }

  /// 恢复进入本页时的各类框（「恢复原区」按钮与手势共用）。
  void _restoreInitialRegions() {
    setState(() {
      _drafts
        ..clear()
        ..addAll({
          for (final e in _initialDrafts.entries) e.key: List.of(e.value),
        });
      _activeLabel = RegionLabel.mainText;
      _activeIndex = 0;
    });
  }

  /// 右侧统计面板：当前页各类区域数量一览（正文几块、页眉/页脚几条、
  /// 图片/表格几张……）。只列已画的类；当前类别的计数标橙，与画布上
  /// "当前框橙色"同一语义。纯展示（外层 IgnorePointer）。
  Widget _buildCountsPanel() {
    final rows = <Widget>[];
    for (final label in RegionLabel.all) {
      final count = _rectsOf(label).length;
      if (count == 0) continue;
      final isActiveLabel = label == _activeLabel;
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: RegionLabel.color(label),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                RegionLabel.displayName(label),
                style: TextStyle(
                  fontSize: 12,
                  color: isActiveLabel ? Colors.orange : Colors.white70,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '×$count',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: isActiveLabel ? Colors.orange : Colors.white,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Card(
      color: Colors.black87,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '本页区域',
              style: TextStyle(fontSize: 11, color: Colors.white38),
            ),
            if (rows.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  '暂无区域框',
                  style: TextStyle(fontSize: 12, color: Colors.white54),
                ),
              )
            else
              ...rows,
          ],
        ),
      ),
    );
  }

  /// 底部快速选框 bar：把本页已画的每个框列成一颗 chip（类别色点 +
  /// 类别名 + 带圈序号），点击即选中为当前框（橙色边线 + 角点）——多框
  /// 页不用在画布上来回找。未选中态（点空白取消选择后）没有高亮 chip。
  /// 序号用 ①②③ 与顶部类别栏的"正文 1"（快捷键提示）区分。
  Widget _buildBoxChipBar() {
    if (_drafts.isEmpty) {
      return const SizedBox(
        height: 34,
        child: Center(
          child: Text(
            '本页还没有区域框：空白处拖拽画出第一个（右侧面板统计各类数量）',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
      );
    }
    String circled(int n) =>
        n <= 20 ? String.fromCharCode(0x2460 + n - 1) : '$n';
    return SizedBox(
      height: 34,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var li = 0; li < RegionLabel.all.length; li++)
              for (var i = 0; i < _rectsOf(RegionLabel.all[li]).length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Tooltip(
                    message: '选中该框（橙色边线可拖动/调角；点击画布空白取消选择）',
                    child: ChoiceChip(
                      avatar: Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: RegionLabel.color(RegionLabel.all[li]),
                          shape: BoxShape.circle,
                        ),
                      ),
                      label: Text(
                        '${RegionLabel.displayName(RegionLabel.all[li])} ${circled(i + 1)}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      selected:
                          _activeLabel == RegionLabel.all[li] &&
                          _activeIndex == i,
                      visualDensity: VisualDensity.compact,
                      showCheckmark: false,
                      onSelected: (_) => setState(() {
                        _activeLabel = RegionLabel.all[li];
                        _activeIndex = i;
                      }),
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(bool isLast) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '当前类别：${RegionLabel.displayName(_activeLabel)} · '
            '空白处拖拽新增框（同类可多个）/ 抓角点或边线调整（只吸附当前框）'
            '/ 框内拖动移动 · 单击框选中、点空白取消选择 · Del 删当前框 · '
            '右键平移 · 滚轮缩放 · 1~8 切类别 · Enter 确认并下一页 · '
            '←/→ 翻页 · 中键画手势（设置可配）· Esc 返回',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          _buildBoxChipBar(),
          const SizedBox(height: 6),
          Row(
            children: [
              OutlinedButton(
                onPressed: _initialDrafts.isEmpty
                    ? null
                    : _restoreInitialRegions,
                child: const Text('恢复原区'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _activeDraft == null
                    ? null
                    : () => setState(() => _removeActiveDraft()),
                child: const Text('删除当前框'),
              ),
              const Spacer(),
              TextButton(
                onPressed: _goNext,
                child: Text(isLast ? '跳过（返回网格）' : '跳过此页'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () => unawaited(_saveAndNext()),
                icon: const Icon(Icons.save_outlined),
                // 文案随真实落点联动：身后还有未确认页才叫「下一页」，
                // 全确认过（或已是最后一页）则是「返回」。
                label: Text(_hasUnconfirmedAhead ? '确认并下一页' : '确认并返回'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

enum _DragMode {
  none,
  draw,
  move,
  resizeTL,
  resizeTR,
  resizeBL,
  resizeBR,
  // 拖整条边（该边两角一起动）：单边平移调边界，页眉/页脚最常用。
  edgeL,
  edgeT,
  edgeR,
  edgeB,
}

/// 快设画笔画笔：原图（画布 1:1）+ 各类别草稿（每类可多条）——当前框
/// 底色仍是自身类别色，仅边线与角点/边中点手柄标橙（沿用快设"进行中"
/// 的草稿视觉），其余框（含同类非当前框）按 [RegionLabel.color] 细线 +
/// 类别名小标签（屏幕恒定大小），一眼分清哪些类别已设、当前在调哪一个。
class _RegionEditorPainter extends CustomPainter {
  _RegionEditorPainter({
    required this.image,
    required this.drafts,
    required this.activeLabel,
    required this.activeIndex,
    required this.viewScale,
  });

  final ui.Image image;

  /// 各类草稿（label → 矩形列表，含 main_text）。
  final Map<String, List<Rect>> drafts;

  /// 当前编辑类别与框下标：对应框画橙色边线带角点（底色保持类别色），
  /// 其余画细线。
  final String activeLabel;
  final int activeIndex;
  final double viewScale;

  @override
  void paint(Canvas canvas, Size size) {
    final iw = image.width.toDouble();
    final ih = image.height.toDouble();
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, iw, ih),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.low,
    );
    // 线宽/角点按屏幕视觉恒定：页面坐标除以当前缩放。
    final unit = 1.0 / math.max(viewScale, 0.001);

    Rect? active;
    final activeList = drafts[activeLabel];
    if (activeList != null &&
        activeIndex >= 0 &&
        activeIndex < activeList.length) {
      active = activeList[activeIndex];
    }
    // 非当前框（含同类非当前框与其它类别）：细线 + 半透明填充 + 类别
    // 名标签。
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

    final rect = active;
    if (rect == null || rect.width <= 0 || rect.height <= 0) return;
    // 当前框底色保持自身类别色（与非当前框同一份填充，选中不换底色），
    // 选中态只由橙色边线 + 角点/边中点手柄表达。
    canvas.drawRect(
      rect,
      Paint()..color = RegionLabel.color(activeLabel).withValues(alpha: 0.08),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.orange
        ..strokeWidth = 2.0 * unit,
    );
    // 角点手柄：与编辑器画布同款方块（随缩放反向放大）——命中吸附圈
    // （摆正页同款 100 屏幕像素半径）以它为圆心，"点到的地方就是能拖
    // 的地方"。
    final handlePaint = Paint()..color = Colors.orange;
    final handleSize = AnnotationHitGeometry.imageSizeForScreenMinimum(
      26,
      viewScale,
      minimumScreen: 12,
    );
    final midSize = AnnotationHitGeometry.imageSizeForScreenMinimum(
      16,
      viewScale,
      minimumScreen: 8,
    );
    for (final corner in [
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
    ]) {
      canvas.drawRect(
        Rect.fromCenter(center: corner, width: handleSize, height: handleSize),
        handlePaint,
      );
    }
    // 边中点小块：提示整条边可拖（边线 ±28 屏幕像素都是命中区）。
    for (final mid in [
      rect.centerLeft,
      rect.centerRight,
      rect.topCenter,
      rect.bottomCenter,
    ]) {
      canvas.drawRect(
        Rect.fromCenter(center: mid, width: midSize, height: midSize),
        handlePaint,
      );
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

  @override
  bool shouldRepaint(_RegionEditorPainter old) =>
      old.image != image ||
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
