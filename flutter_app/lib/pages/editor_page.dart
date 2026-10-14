import 'dart:async';
import 'dart:convert' show jsonEncode;
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lpinyin/lpinyin.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';
import '../models/page_quad.dart';
import '../models/table_block.dart';
import '../services/char_stats.dart';
import '../services/page_recognition.dart';
import '../services/python_service.dart';
import '../services/recognition_queue.dart';
import '../services/storage.dart';
import '../services/annotation_hit_geometry.dart';
import '../services/ai_box_review.dart';
import '../services/ai_line_repair.dart';
import '../services/ai_page_prelabel.dart';
import '../services/ai_trace.dart';
import '../services/book_cache.dart';
import '../services/book_region_apply.dart';
import '../services/train_auto_export.dart';
import '../services/mouse_gesture.dart';
import '../services/page_state_markers.dart';
import '../services/ollama_service.dart';
import '../widgets/attached_scrollbar.dart';
import '../widgets/backend_console_panel.dart';
import '../widgets/char_rainbow.dart';
import '../widgets/char_verify_common.dart';
import '../widgets/direct_text_panel.dart';
import '../widgets/engine_settings_section.dart';
import '../widgets/excalidraw_export_dialog.dart';
import 'ai_trace_panel.dart';
import 'book_grid_page.dart';
import 'book_overlay_page.dart';
import 'book_region_grid_page.dart';
import 'book_split_page.dart';
import 'export_page.dart';
import 'straighten_page.dart';
import 'similar_chars_book_page.dart';
import 'similar_chars_page.dart';
import 'table_review_page.dart';

class EditorPage extends StatefulWidget {
  final Project project;
  const EditorPage({super.key, required this.project});

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  int _pageIndex = 0;

  /// 页面图像的就地改写版本（旋转/镜像后 +1）：路径不变，画布/行卡片
  /// 靠它感知需要重新解码图像。
  int _imageRevision = 0;
  int _viewIndex = 0; // 0=editor, 1=backend console
  PageAnnotation? _annotation;
  bool _loading = false;

  /// 表格识别进行中（+83）：主区面板按钮重入保护。
  bool _tableBusy = false;
  String _loadingLabel = '正在识别…';
  String? _error;
  CharBlock? _selected;
  LineBlock? _selectedLine;
  MainRegion? _selectedRegion;
  Paragraph? _selectedParagraph;
  bool _lineProcessing = false;
  String? _processingLineId;

  /// 执行中的行级动作（'rerecognize'/'resplit'/'ai-check'）：行卡片
  /// 头部的转圈显示在对应动作按钮上（此前只有行级布尔，重新切割本列
  /// 的转圈会错位显示在"重新识别本行单字"图标上）。
  String? _processingLineAction;

  /// 直发路径（不走级联队列的行级任务，如 AI 检查本行）占用的行 id：
  /// 队列刷新不得清掉它，结束时由直发路径自己清理。
  String? _directProcessingLineId;
  String? _directProcessingLineAction;

  /// 「按 AI 标记修复」进行中（尾段重摆 + AI 复核，耗时较长）。
  bool _aiRepairing = false;

  /// 画布当前页图像的像素尺寸（画布解码完成后回填）：层级推断把主区
  /// 钳回图片范围、越界修复都以此为准。
  Size _canvasImageSize = Size.zero;
  // Draft edits are persisted continuously (临时保存), but become training
  // eligible only after the user explicitly runs 确认并保存 on the page.
  bool _dirty = false;
  // Confirmed annotation counts for the whole book.  The editor used to feed
  // the progress cards from the current page only, which made the progress
  // appear to reset whenever the user turned a page.
  Map<String, int> _bookProgress = <String, int>{};
  int _progressGeneration = 0;
  // 全书页状态标记（已确认/确认识别框/临时保存/识别未确认四态集合 +
  // 边框色），与全书网格总览共用；保存/确认流程就地增删集合元素。
  final PageStateMarkers _markers = PageStateMarkers();
  // 左侧缩略图列表「隐藏已确认页」开关：校对后期绿框页占大头，过滤后
  // 只剩待校对的页便于逐页点选。当前页恒显示——「确认并保存」后本页
  // 立即变绿也不会从列表消失，滚动定位不失锚。状态持久化（下次进入
  // 保持上次的选择，与主区快设网格的同名开关各自独立）。
  bool _hideConfirmedPages = false;
  static const String _prefHideConfirmedPages = 'editor_hide_confirmed_pages';

  void _setHideConfirmedPages(bool value) {
    setState(() => _hideConfirmedPages = value);
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setBool(_prefHideConfirmedPages, value),
    );
  }

  // 训练服务的各层数据就绪状态（layer -> readiness）：提供每个模型档位的
  // 下一轮目标（已训档位按轮数进阶）与下一个里程碑，进度卡按档位分条显示。
  Map<String, Map<String, dynamic>> _trainReadiness = {};

  /// /models 各层激活状态（侧边栏"本页拆分"信息卡显示用）。空=尚未取到。
  Map<String, Map<String, dynamic>> _modelsInfo = {};
  // 主区/段级联重识别进行中（调后端分行+拆字）
  bool _areaProcessing = false;
  String _areaProcessingLabel = '';
  // 手势期间主区/段/行几何是否被改动（拖动/缩放），手势结束后触发级联识别
  bool _regionGeomDirty = false;
  bool _paraGeomDirty = false;
  bool _lineGeomDirty = false;
  // 单字框几何被改动（拖动/缩放）：手势结束后用 Kraken 重识别该字框
  bool _charGeomDirty = false;
  String? _charGeomDirtyId;
  // 正在快速识别的单字框 id（画新框/调整框后）：面板显示"识别中"
  final Set<String> _recognizingChars = {};
  // 每次切页递增，避免较早的异步加载结果覆盖当前页面状态。
  int _loadGeneration = 0;
  final _focusNode = FocusNode();

  /// 左侧缩略图列表的滚动控制器：翻页/进入书籍时把当前页滚到可见位置。
  final ScrollController _thumbScroll = ScrollController();

  // ── toolbar state ──
  bool _showIndex = true;
  bool _showCharBox = true;
  bool _reorderMode = false; // 点击排序模式：临时记录点击顺序，点满后提交
  String _reorderTarget = 'line'; // line | paragraph
  final Map<String, int> _pendingLineOrder = {};
  final Map<String, int> _pendingParagraphOrder = {};
  String _viewMode = 'line'; // 'region' | 'paragraph' | 'line' | 'char' | 'text'（整页直读）

  /// 详细视图要滚动定位到的行 id（墨迹归类页「定位」设置）；
  /// 每次定位递增序号，保证定位到同一行的不同字时也会触发滚动。
  String? _detailFocusLineId;
  int _detailFocusSeq = 0;

  /// 「定位」后呼吸闪烁高亮的字块 id（行图/字chip/字轨三处同时闪），
  /// 10 秒后或下次定位时自动切换/熄灭。
  String? _flashCharId;
  Timer? _flashTimer;

  /// 确认后自动增量导出完成 → 刷新训练就绪卡的全局累计数。
  StreamSubscription<void>? _trainExportSub;

  /// 底部编号条「定位」：点编号选中框并让画布把该框平移到视口中心。
  /// focusSeq 每次定位递增（同框重复点击也触发）。
  Rect? _canvasFocusRect;
  int _canvasFocusSeq = 0;

  // ── 详细视图卡片缩放 ──
  static const double kDetailCardBaseWidth = 460;
  static const double kDetailCardMinWidth = 300;
  static const double kDetailCardMaxWidth = 900;
  static const double kDetailCardZoomStep = 60;
  double _detailCardWidth = kDetailCardBaseWidth;
  double get _detailCardScale => _detailCardWidth / kDetailCardBaseWidth;

  // ── 详细视图字号（独立于卡片尺寸，每次增减 1pt） ──
  static const double kDetailFontBase = 40;
  static const double kDetailFontMin = 8;
  static const double kDetailFontMax = 72;
  double _detailFontSize = kDetailFontBase;
  double get _detailFontScale => _detailFontSize / kDetailFontBase;

  void _zoomInDetail() => setState(() {
    _detailCardWidth = (_detailCardWidth + kDetailCardZoomStep).clamp(
      kDetailCardMinWidth,
      kDetailCardMaxWidth,
    );
  });

  void _zoomOutDetail() => setState(() {
    _detailCardWidth = (_detailCardWidth - kDetailCardZoomStep).clamp(
      kDetailCardMinWidth,
      kDetailCardMaxWidth,
    );
  });

  void _resetDetailZoom() => setState(() {
    _detailCardWidth = kDetailCardBaseWidth;
  });

  void _fontScaleUp() => setState(() {
    _detailFontSize = (_detailFontSize + 1).clamp(
      kDetailFontMin,
      kDetailFontMax,
    );
  });

  void _fontScaleDown() => setState(() {
    _detailFontSize = (_detailFontSize - 1).clamp(
      kDetailFontMin,
      kDetailFontMax,
    );
  });

  void _resetFontScale() => setState(() {
    _detailFontSize = kDetailFontBase;
  });

  String get _imagePath => widget.project.imageFiles[_pageIndex];

  /// 本页页号以图片文件名为准（删除页后下标与文件名错位，见
  /// pageIdForImage）；imageFiles 为空时退回下标。
  String get _pageId => _pageIndex < widget.project.imageFiles.length
      ? widget.project.pageIdAt(_pageIndex)
      : 'page_${_pageIndex.toString().padLeft(3, '0')}';

  /// 本页有效识别方向：按页覆盖优先于整书设置（个别页横竖排不同）。
  String get _pageOrientation =>
      widget.project.effectiveOrientationAt(_pageIndex);

  /// Excalidraw 框选导出：true 时画布拖拽只框选区域不建框，松手后打开
  /// 导出工作台（预览 + 调参）生成 .excalidraw 场景。
  bool _excalidrawPicking = false;

  /// 本页识别用设置（方向已按页覆盖，其余与整书一致）。
  ProjectSettings get _pageSettings => widget.project.settingsAt(_pageIndex);

  @override
  void initState() {
    super.initState();
    // Restore the last page opened for this book. Clamp in case the source
    // images were replaced and the old index is now out of range.
    if (widget.project.imageFiles.isNotEmpty) {
      _pageIndex = widget.project.lastPageIndex.clamp(
        0,
        widget.project.imageFiles.length - 1,
      );
    }
    _loadPage();
    _loadPageStateMarkers();
    unawaited(_refreshBookProgress());
    unawaited(_loadTrainReadiness());
    // 确认后的自动增量导出完成时刷新就绪卡的全局累计数（统计随确认
    // 增长——导出刚入账的页要等这次刷新才出现在"全部书籍累计"里）。
    _trainExportSub = TrainExportScheduler.onExportDone.listen((_) {
      if (mounted) unawaited(_loadTrainReadiness());
    });
    unawaited(_loadCharDetModelInfo());
    // 「隐藏已确认页」开关的持久化状态（上次退出时的选择）。
    SharedPreferences.getInstance().then((prefs) {
      final v = prefs.getBool(_prefHideConfirmedPages);
      if (v != null && mounted && v != _hideConfirmedPages) {
        setState(() => _hideConfirmedPages = v);
      }
    });
    // 鼠标中键手势配置：进页加载一次缓存，松手判定时直接查内存。
    GestureSettings.load().then((s) {
      if (mounted) _gestureSettings = s;
    });
    // 进入书籍时把当前页的缩略图滚动到可见位置。
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollThumbsToCurrent(),
    );
  }

  // ── 鼠标中键手势（按住中键拖出方向序列，松手匹配触发；整窗口感应，
  // 画布/面板/缩略图上拖动均识别——画布对中键本来就丢弃，无冲突）──
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
    final action = _gestureSettings.editor[seq];
    if (action != null) _runEditorGestureAction(action);
  }

  /// 手势动作分发（动作 id 见 [GestureCatalog.editorActions]）。
  void _runEditorGestureAction(String id) {
    switch (id) {
      case 'saveAll':
        unawaited(_saveCurrentPage());
      case 'saveDraft':
        unawaited(_saveDraftPage());
      case 'confirmBoxes':
        unawaited(_saveBoxesOnlyPage());
      case 'prevPage':
        if (_pageIndex > 0) unawaited(_switchPage(_pageIndex - 1));
      case 'nextPage':
        if (_pageIndex < widget.project.imageFiles.length - 1) {
          unawaited(_switchPage(_pageIndex + 1));
        }
    }
  }

  /// 缩略图列表在「隐藏已确认页」开关下的可见页号；开关关闭时返回
  /// null（不过滤，直接按原页序显示，大书不白白复制一份列表）。
  List<int>? _visibleThumbPages(int pageCount) {
    if (!_hideConfirmedPages) return null;
    return [
      for (var i = 0; i < pageCount; i++)
        if (i == _pageIndex || !_markers.savedPages.contains(i)) i,
    ];
  }

  /// 把左侧缩略图列表滚动到当前页（尽量居中）。开关过滤后列表行号与
  /// 页号错位，先换算成当前页在可见列表里的行号。
  void _scrollThumbsToCurrent() {
    if (!_thumbScroll.hasClients) return;
    const itemExtent = 106.0;
    final visible = _visibleThumbPages(widget.project.imageFiles.length);
    final visibleRow = visible?.indexOf(_pageIndex) ?? -1;
    final row = visible == null
        ? _pageIndex
        : (visibleRow < 0 ? 0 : visibleRow);
    final viewport = _thumbScroll.position.viewportDimension;
    final target = (row * itemExtent - viewport / 2 + itemExtent / 2).clamp(
      0.0,
      _thumbScroll.position.maxScrollExtent,
    );
    _thumbScroll.jumpTo(target);
  }

  @override
  void dispose() {
    // Persist the location even when the user leaves via the system/back
    // button instead of selecting another thumbnail first. Pending debounced
    // edits must reach the disk even though dispose cannot await.
    _cancelPendingSave();
    // 主区拆分任务进行中跳过 dispose 落盘：当前页标注在进入快设页前
    // 已 flush（任务期间编辑器不可再进入，内容不会变），而任务可能刚
    // 写完这页的更新版——再写旧内存态会覆盖它（快设页"任务中返回"
    // 连同本页一起退栈回书库时走到这里）。
    if (!RecognitionQueue.instance.isRegionSplitActive(widget.project.id)) {
      unawaited(_flushSave());
    }
    _persistLastPageIndex();
    _trainExportSub?.cancel();
    _flashTimer?.cancel();
    _focusNode.dispose();
    _thumbScroll.dispose();
    super.dispose();
  }

  // ── data load / save ──

  Future<void> _loadPageStateMarkers() async {
    // 页状态走书目录缓存：指纹（mtime+size+图片路径）未变的页只 stat
    // 不解析 JSON——大书整本标注逐页解析可达数秒，是打开慢的主因之一。
    final markers = (await PageStateCache.load(widget.project)).markers;
    if (!mounted) return;
    setState(() {
      _markers.savedPages.addAll(markers.savedPages);
      _markers.boxesReviewedPages.addAll(markers.boxesReviewedPages);
      _markers.draftPages.addAll(markers.draftPages);
      _markers.boxedUnconfirmedPages.addAll(markers.boxedUnconfirmedPages);
    });
  }

  Future<void> _loadPage({bool forceSegment = false}) async {
    final requestedIndex = _pageIndex;
    // 防抖期内的编辑必须在内存标注被磁盘版替换前落盘——此前只取消
    // 定时器不冲刷，800ms 内的修改随切页直接丢失（"调完框一翻页就
    // 回到原样"的一个来源）。复用串行写链，不与在途写盘交错。
    if (_saveDebounce != null && _annotation != null) {
      final leavingAnn = _annotation!;
      _cancelPendingSave();
      if (_annotationWorthPersisting(leavingAnn)) {
        leavingAnn.draftSaved = true;
        _flushChain = _flushChain
            .then(
              (_) => ProjectStorage.saveAnnotation(
                widget.project.projectDir,
                leavingAnn,
              ),
            )
            .then<void>(
              (_) {},
              onError: (Object error) {
                PythonService.addAppLog(
                  '[保存诊断] ⚠ 切页冲刷写盘失败：$error',
                  isError: true,
                );
              },
            );
        unawaited(_flushChain);
        PythonService.addAppLog(
          '[保存诊断] 切页前冲刷未落盘编辑 ${leavingAnn.pageId} '
          '${_annDebugSnapshot(leavingAnn)}',
        );
      }
    }
    // 页号以图片文件名为准：删除页后 imageFiles 下标与文件名编号错位，
    // 按下标读会读到别的页的旧标注（保存写 page_037.json、读取读
    // page_009.json 的读写分裂）。
    final requestedPageId = requestedIndex < widget.project.imageFiles.length
        ? widget.project.pageIdAt(requestedIndex)
        : 'page_${requestedIndex.toString().padLeft(3, '0')}';
    final loadGeneration = ++_loadGeneration;
    setState(() {
      _loading = true;
      _loadingLabel = forceSegment ? '正在重新识别本页…' : '正在识别本页…';
      _error = null;
      _selected = null;
      _selectedLine = null;
      _reorderMode = false;
      _pendingLineOrder.clear();
      _pendingParagraphOrder.clear();
      _areaProcessing = false;
      _regionGeomDirty = false;
      _paraGeomDirty = false;
      _lineGeomDirty = false;
      _charGeomDirty = false;
      _charGeomDirtyId = null;
      // 新页图像未解码，画布尺寸必须归零等 onImageReady 回填真值：
      // 否则载入已有标注分支的 _applyAnnotationClamp 会拿上一页（或
      // 摆正前同页）的尺寸钳制本页主区并落盘——摆正过的页尺寸必变，
      // 快设里画好的主区一到校对界面就被改小（且无法复原）。
      _canvasImageSize = Size.zero;
      // 「定位」的目标行与闪烁字块只属于设置它的那一页，换页即失效。
      // 残留的行 id 会在新页行卡片树的多轮拆建期间触发对已停用元素的
      // 祖先查找（Scrollable.ensureVisible），导致翻页崩溃。
      _detailFocusLineId = null;
      _flashCharId = null;
      // 重新识别会用全新标注覆盖，绿框/玫红框/橘黄框/紫框随之失效。
      if (forceSegment) {
        _markers.savedPages.remove(requestedIndex);
        _markers.boxesReviewedPages.remove(requestedIndex);
        _markers.draftPages.remove(requestedIndex);
        _markers.boxedUnconfirmedPages.remove(requestedIndex);
      }
    });
    try {
      if (forceSegment) {
        // Make the two independent AI switches visible in the progress text.
        // "自动应用识别框修复" only affects the box-review button; it does
        // not turn on line-text arbitration for an explicit page rerun.
        final ai = await OllamaSettings.load();
        final lineAi = ai.enableLineAssist || ai.enableManualLineAssist;
        PythonService.addAppLog(
          '[载入诊断] 本页重识别 AI=${lineAi ? '开启' : '关闭'} '
          '（全本=${ai.enableLineAssist} 本页/本行=${ai.enableManualLineAssist}）',
        );
        if (mounted && loadGeneration == _loadGeneration) {
          setState(() {
            _loadingLabel = lineAi
                ? '正在重新识别本页（AI 整行裁决）…'
                : '正在重新识别本页（当前为 OCR；需开启“本页或本行重新识别时启用 AI”）…';
          });
        }
      }
      if (!forceSegment) {
        // 损坏或尚未写完的标注文件不能阻止切页；存储层会将其视为空标注，
        // 随后重新执行识别并覆盖该文件。
        final existing = await ProjectStorage.loadAnnotation(
          widget.project.projectDir,
          requestedPageId,
          debugLog: true,
          expectedImagePath: widget.project.imageFiles[requestedIndex],
        );
        if (!mounted || loadGeneration != _loadGeneration) return;
        if (existing != null) {
          PythonService.addAppLog('[载入诊断] 磁盘读取 ${_annDebugSnapshot(existing)}');
          setState(() {
            _annotation = existing;
            _loading = false;
            _loadingLabel = '';
            _dirty = false;
            if (existing.isFullyConfirmed) {
              _markers.savedPages.add(requestedIndex);
              _markers.boxesReviewedPages.remove(requestedIndex);
              _markers.draftPages.remove(requestedIndex);
              _markers.boxedUnconfirmedPages.remove(requestedIndex);
            } else if (existing.boxesReviewed) {
              _markers.boxesReviewedPages.add(requestedIndex);
              _markers.draftPages.remove(requestedIndex);
              _markers.boxedUnconfirmedPages.remove(requestedIndex);
            } else if (existing.draftSaved) {
              _markers.draftPages.add(requestedIndex);
              _markers.boxesReviewedPages.remove(requestedIndex);
              _markers.boxedUnconfirmedPages.remove(requestedIndex);
            } else if (existing.hasUnconfirmedBoxes) {
              _markers.boxedUnconfirmedPages.add(requestedIndex);
              _markers.savedPages.remove(requestedIndex);
              _markers.boxesReviewedPages.remove(requestedIndex);
              _markers.draftPages.remove(requestedIndex);
            } else {
              _markers.boxedUnconfirmedPages.remove(requestedIndex);
              _markers.boxesReviewedPages.remove(requestedIndex);
              _markers.draftPages.remove(requestedIndex);
            }
          });
          unawaited(_refreshBookProgress());
          _applyAnnotationClamp();
          return;
        }
      }
      // 「创建后手动开始识别」的书：无标注的页不自动跑识别，以空标注
      // 进入编辑（看原图、旋转/删页/跨页拆分/手画框都可用），整本识别
      // 由用户手动开始。空标注不落盘（见 _flushSave 的守卫），不会让
      // 整本识别把这页当成已完成而跳过。
      if (!widget.project.autoRecognize && !forceSegment) {
        if (!mounted || loadGeneration != _loadGeneration) return;
        setState(() {
          _annotation = PageAnnotation(
            pageId: requestedPageId,
            imagePath: widget.project.imageFiles[requestedIndex],
          );
          _loading = false;
          _loadingLabel = '';
          _dirty = false;
        });
        unawaited(_refreshBookProgress());
        return;
      }
      // forceSegment（"重新识别当前页"）时跳过已有标注直接重跑；
      // 首次打开无标注的页也走识别。保存由共享函数完成。
      PythonService.addAppLog(
        '[载入诊断] $requestedPageId 磁盘无标注（或解析失败）→整页重新识别',
        isError: true,
      );
      final ann = await ensurePageAnnotation(
        widget.project,
        requestedIndex,
        force: true,
        useCurrentAiSettings: forceSegment,
        onProgress: (stage) {
          if (!mounted || loadGeneration != _loadGeneration) return;
          setState(() => _loadingLabel = stage);
        },
      );
      if (!mounted || loadGeneration != _loadGeneration) return;
      setState(() {
        _annotation = ann;
        _loading = false;
        _loadingLabel = '';
        _dirty = false;
        // 重新识别产出的是全新未确认标注：有识别框即转紫框提示，
        // 此前的绿/青/橘黄状态一并失效。
        _markers.savedPages.remove(requestedIndex);
        _markers.boxesReviewedPages.remove(requestedIndex);
        _markers.draftPages.remove(requestedIndex);
        if (ann.hasUnconfirmedBoxes) {
          _markers.boxedUnconfirmedPages.add(requestedIndex);
        }
      });
      unawaited(_refreshBookProgress());
    } catch (e, st) {
      // 页面识别/载入异常把完整堆栈落进应用日志（后台控制台可见）：
      // type cast 类错误只有一行 e.toString() 时无从定位（"type 'Null'
      // is not a subtype of type 'String'" 反复出现而响应解析链逐段
      // 实测均干净，需要堆栈锁定真正抛点）。
      PythonService.addAppLog(
        '[载入诊断] 页面识别/载入异常：$e\n$st',
        isError: true,
      );
      if (!mounted || loadGeneration != _loadGeneration) return;
      setState(() {
        _error = e is RecognitionBusyException
            ? '后台正在批量识别其他书籍，请等队列完成后再试'
            : e.toString();
        _loading = false;
        _loadingLabel = '';
      });
    }
  }

  /// Recompute confirmed training data across every page in this book.
  ///
  /// 书进度走页状态缓存（指纹未变的页只 stat 不解析 JSON）；当前页以
  /// 内存标注覆盖缓存读数（防抖未落盘的修改立即反映在进度卡上）。
  /// A generation token prevents a slow read from an older page switch
  /// overwriting newer totals.
  Future<void> _refreshBookProgress() async {
    final generation = ++_progressGeneration;
    final pageIndex = _pageIndex;
    final current = _annotation;
    final summary = await PageStateCache.load(widget.project);
    final counts = <String, int>{
      'region_det': 0,
      'paragraph_det': 0,
      'line_det': 0,
      'char_det': 0,
      'char_cls': 0,
      'char_classes': 0,
    };
    final classes = <String>{};
    void accumulate(PageCounters c) {
      counts['region_det'] = counts['region_det']! + c.regionDet;
      counts['paragraph_det'] = counts['paragraph_det']! + c.paragraphDet;
      counts['line_det'] = counts['line_det']! + c.lineDet;
      counts['char_det'] = counts['char_det']! + c.charDet;
      counts['char_cls'] = counts['char_cls']! + c.charCls;
      classes.addAll(c.charTexts);
    }

    summary.countersByPage.forEach((i, c) {
      // 当前页：磁盘读数可能落后于内存（防抖保存/行内编辑），以内存
      // 标注现算覆盖。
      if (i == pageIndex && current != null) {
        accumulate(PageCounters.of(current));
        return;
      }
      accumulate(c);
    });
    // 当前页还没有标注文件（识别未落盘）时缓存表里没有条目，内存
    // 标注的计数此前也会计入——保持该口径。
    if (current != null && !summary.countersByPage.containsKey(pageIndex)) {
      accumulate(PageCounters.of(current));
    }
    counts['char_classes'] = classes.length;
    if (!mounted || generation != _progressGeneration) return;
    setState(() => _bookProgress = counts);
  }

  int _progressValue(String layer, int fallback) =>
      _bookProgress.containsKey(layer) ? _bookProgress[layer]! : fallback;

  /// 拉取训练服务的各层数据就绪状态（每档位轮数目标）。失败静默降级：
  /// 进度卡回退到本地静态目标表的单条进度条。
  Future<void> _loadTrainReadiness() async {
    try {
      final stats = await PythonService.trainStats(widget.project.projectDir);
      if (!mounted) return;
      final layers = (stats['layers'] as Map?) ?? const {};
      setState(() {
        _trainReadiness = {
          for (final entry in layers.entries)
            if (entry.value is Map && (entry.value as Map)['readiness'] is Map)
              entry.key.toString(): Map<String, dynamic>.from(
                (entry.value as Map)['readiness'] as Map,
              ),
        };
      });
    } catch (_) {
      // 服务未运行/超时：保留空表，进度卡走静态目标兜底。
    }
  }

  int get _bookCharClasses => _bookProgress['char_classes'] ?? 0;

  /// 拉取各层当前激活的模型信息（是否自训、训练指标）。
  /// 失败静默降级：信息卡只显示拆分方式、模型栏显示"—"。
  Future<void> _loadCharDetModelInfo() async {
    try {
      final layers = await PythonService.listModels();
      if (!mounted) return;
      setState(() => _modelsInfo = layers);
    } catch (_) {
      // 服务未运行/超时：保持空表，信息卡走兜底文案。
    }
  }

  /// 右侧面板底部的"本页拆分"信息：逐层如实分列（行划分方式 + 五个识别
  /// 层各自的实际状态与模型名），避免把某一层启用误读成全部启用。
  Widget _buildSegmentInfoFooter() {
    final modelVersion = _annotation?.modelVersion ?? '';
    final (methodLabel, methodColor) = switch (modelVersion) {
      'hier' => ('投影划行·先划行后切字', Colors.teal.shade700),
      'paddle-det' => ('PP-OCR 检测定行', Colors.blue.shade700),
      'yolo-char' => ('单字检测成行（旧）', Colors.teal.shade700),
      'opencv' => ('OpenCV投影兜底', Colors.orange.shade800),
      '' => ('未识别', Colors.grey),
      _ => (modelVersion, Colors.grey),
    };

    String modelBase(String path) => path.replaceAll('\\', '/').split('/').last;

    String layerStatus(String key) {
      final info = _modelsInfo[key];
      if (info == null) return '—';
      final active = info['active']?.toString();
      final activeExists = info['active_exists'] == true;
      if (active != null && active.isNotEmpty && activeExists) {
        final started = (info['active_started'] as num?)?.toInt();
        final date = started == null
            ? ''
            : DateTime.fromMillisecondsSinceEpoch(
                started * 1000,
              ).toString().substring(5, 10).replaceAll('-', '/');
        final metrics = (info['metrics'] as Map?) ?? const {};
        final recall = metrics['metrics/recall(B)'];
        final buf = StringBuffer('自训 ${modelBase(active)}');
        if (date.isNotEmpty) buf.write(' · $date');
        if (recall is num) {
          buf.write(' · R${(recall * 100).toStringAsFixed(1)}%');
        }
        return buf.toString();
      }
      if (active != null && active.isNotEmpty) return '自训模型已失效';
      final def = info['default']?.toString();
      if (def != null && def.isNotEmpty) return '内置 ${modelBase(def)}';
      return '未启用（规则+手工）';
    }

    String krakenStatus() {
      final info = _modelsInfo['kraken_rec'];
      if (info == null) return '—';
      if (info['active_exists'] != true) return '未安装';
      final name = modelBase(info['active']?.toString() ?? 'chat_rec.mlmodel');
      return info['finetuned'] == true
          ? 'Kraken $name·微调版'
          : 'Kraken $name·官方版';
    }

    Widget row(String label, String value, Color? color) => Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: const TextStyle(fontSize: 10, color: Colors.grey),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: color ?? Colors.black87,
                height: 1.25,
              ),
            ),
          ),
        ],
      ),
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        border: Border(top: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            '本页拆分',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: Colors.grey,
            ),
          ),
          row('行划分', methodLabel, methodColor),
          row('正文区检测', layerStatus('region_det'), null),
          row('段落检测', layerStatus('paragraph_det'), null),
          row('单行检测', layerStatus('line_det'), null),
          row('单字检测', layerStatus('char_det'), null),
          row('单字识别', krakenStatus(), null),
        ],
      ),
    );
  }

  // 拖拽/几何编辑会逐帧调用 _save()；立即落盘 + 全书进度刷新会淹掉磁盘，
  // 普通保存只标脏并合并为一次延迟临时写盘，翻页/显式保存/退出时立即 flush。
  Timer? _saveDebounce;
  Future<void> _flushChain = Future.value();

  Future<void> _save({bool confirmAll = false}) async {
    final ann = _annotation;
    if (ann == null) return;
    if (confirmAll) {
      _cancelPendingSave();
      PythonService.addAppLog('[保存诊断] 确认并保存（保存前内存快照）${_annDebugSnapshot(ann)}');
      ann.markAllConfirmed();
      ann.rebuildBlocks();
      ann.reviewed = true; // 确认并保存过 → 计入书列表的校对进度
      if (mounted) {
        setState(() {
          _dirty = false;
          _markers.savedPages.add(_pageIndex);
          _markers.boxesReviewedPages.remove(_pageIndex);
          _markers.draftPages.remove(_pageIndex);
          _markers.boxedUnconfirmedPages.remove(_pageIndex);
        });
      } else {
        _dirty = false;
        _markers.savedPages.add(_pageIndex);
        _markers.boxesReviewedPages.remove(_pageIndex);
        _markers.draftPages.remove(_pageIndex);
        _markers.boxedUnconfirmedPages.remove(_pageIndex);
      }
      await ProjectStorage.saveAnnotation(widget.project.projectDir, ann);
      // 已确认页的墨迹模板增量入库（跨页同伴互证的参照，失败静默）
      unawaited(
        PythonService.verifyTemplatesUpdate(
          projectDir: widget.project.projectDir,
          imagePath: _imagePath,
          blocks: ann.blocks
              .where((b) => b.type == 'main_text' && b.text.trim().isNotEmpty)
              .toList(),
        ),
      );
      unawaited(_refreshBookProgress());
      // 确认保存触发防抖增量导出（storage 咽喉点 → TrainExportScheduler），
      // 统计入账后由订阅再刷一次；这里先拉缓存数字保持卡片即时。
      unawaited(_loadTrainReadiness());
      return;
    }
    if (mounted) {
      setState(() => _dirty = true);
    } else {
      _dirty = true;
    }
    _saveDebounce ??= Timer(const Duration(milliseconds: 800), () {
      _saveDebounce = null;
      unawaited(_flushSave());
    });
  }

  /// 取消未触发的防抖定时器（数据仍完整保留在内存标注对象中）。
  void _cancelPendingSave() {
    _saveDebounce?.cancel();
    _saveDebounce = null;
  }

  /// 该标注是否值得落盘：有内容、确认过、或此前已落盘过（draftSaved）。
  /// 「创建后手动开始识别」的书里只翻看过的页是空标注且从未落盘——
  /// 标注文件的存在是整本识别「该页已完成」的标记，空文件落盘会让
  /// 整本识别跳过这页，所以什么都不写。
  bool _annotationWorthPersisting(PageAnnotation ann) =>
      ann.hasAnyContent || ann.reviewed || ann.boxesReviewed || ann.draftSaved;

  /// 立即把当前标注写盘；写操作串行链接，避免大书上多次 flush 交错。
  ///
  /// 临时保存通道（防抖编辑、翻页、退出）：只落盘当前修改，不改动任何
  /// 确认状态、不置 reviewed——未确认的页不会计入训练数据或校对进度。
  /// 落盘同时置 draftSaved；无更具体状态的页缩略图转橘黄（框已确认的
  /// 玫红框页、已确认的绿框页保持原色，不因草稿写盘降级）。
  Future<void> _flushSave() {
    final ann = _annotation;
    if (ann == null) return Future.value();
    if (!_annotationWorthPersisting(ann)) return Future.value();
    PythonService.addAppLog('[保存诊断] 防抖临时写盘 ${_annDebugSnapshot(ann)}');
    ann.draftSaved = true;
    if (!_markers.savedPages.contains(_pageIndex) &&
        !_markers.boxesReviewedPages.contains(_pageIndex)) {
      // 框已确认（玫红框）的页不降级回橘黄：临时写盘只表示"又有草稿"。
      _markers.draftPages.add(_pageIndex);
      _markers.boxedUnconfirmedPages.remove(_pageIndex);
    }
    // catchError 吸收单次写盘失败（Windows 上防病毒/索引器瞬时锁住
    // .bak 或 rename 冲突并不罕见）：一旦失败沿着链传播，后续排队的
    // 所有写盘都会被静默跳过——表现为"日志说写盘了、切回来还是旧的"。
    // 吸收后链保持可用，下一次写盘照常执行；失败红字可见。
    _flushChain = _flushChain
        .then(
          (_) => ProjectStorage.saveAnnotation(widget.project.projectDir, ann),
        )
        .then<void>(
          (_) {},
          onError: (Object error) {
            PythonService.addAppLog(
              '[保存诊断] ⚠ 防抖写盘失败（已忽略，链保持可用）：$error',
              isError: true,
            );
          },
        );
    return _flushChain;
  }

  Future<void> _persistLastPageIndex() async {
    if (widget.project.imageFiles.isEmpty) return;
    final index = _pageIndex.clamp(0, widget.project.imageFiles.length - 1);
    if (widget.project.lastPageIndex == index) return;
    widget.project.lastPageIndex = index;
    try {
      await ProjectStorage.save(widget.project);
    } catch (_) {
      // Page position is auxiliary metadata; a transient write failure must
      // never prevent leaving the editor.
    }
  }

  /// 确认并保存：本页全部识别框与识别文字标记为已确认，写入训练数据
  /// （训练服务只读取 confirmed 状态的标注），同时计入书列表校对进度。
  Future<void> _saveCurrentPage() async {
    if (_annotation == null) return;
    await _save(confirmAll: true);
    if (mounted) {
      setState(() {});
      _snack('本页已确认并保存：识别框与文字计入训练数据');
    }
  }

  /// 确认识别框并保存：只把本页字框几何标记为已确认（char.boxConfirmed
  /// /page.boxesReviewed），检测训练（char_det）可读这些框；单字文字与
  /// 候选保持待确认——分类训练（char_cls）、校对进度、绿框门槛仍按
  /// 「确认并保存」的完全确认口径，不受影响。适合"框都校完了、字还
  /// 没逐个过候选"的中间状态：先固化切分成果，文字后续再校。
  Future<void> _saveBoxesOnlyPage() async {
    final ann = _annotation;
    if (ann == null) return;
    _cancelPendingSave();
    PythonService.addAppLog('[保存诊断] 确认识别框（保存前内存快照）${_annDebugSnapshot(ann)}');
    ann.markBoxesConfirmed();
    ann.rebuildBlocks();
    if (mounted) {
      setState(() => _dirty = false);
    } else {
      _dirty = false;
    }
    try {
      await ProjectStorage.saveAnnotation(widget.project.projectDir, ann);
    } catch (error) {
      // 确认保存失败必须可见：静默失败 = 用户以为确认了、磁盘还是旧的。
      PythonService.addAppLog('[保存诊断] ⚠ 确认识别框写盘失败：$error', isError: true);
      if (mounted) {
        _snack('保存失败：$error（修改仍在内存，可重试保存）', error: true);
      }
      return;
    }
    // 识别框已确认：非绿框页转玫红框（与磁盘分类同口径），移出紫框/橘黄。
    if (mounted) {
      setState(() {
        if (!_markers.savedPages.contains(_pageIndex)) {
          _markers.boxesReviewedPages.add(_pageIndex);
          _markers.draftPages.remove(_pageIndex);
        }
        _markers.boxedUnconfirmedPages.remove(_pageIndex);
      });
    } else {
      if (!_markers.savedPages.contains(_pageIndex)) {
        _markers.boxesReviewedPages.add(_pageIndex);
        _markers.draftPages.remove(_pageIndex);
      }
      _markers.boxedUnconfirmedPages.remove(_pageIndex);
    }
    unawaited(_refreshBookProgress());
    // 框确认同样增长检测层训练数据：等自动增量导出完成后由订阅刷新，
    // 这里先拉一次（缓存数字，导出入账后再跳一次）。
    unawaited(_loadTrainReadiness());
    if (mounted) {
      _snack(
        '本页识别框已确认并保存：正文区/段落/行/字框计入检测训练；'
        '文字候选待确认，不计入分类训练与校对进度',
      );
    }
  }

  /// 全书「确认并保存」改回未保存（单字校对视图的全书级操作，用户需
  /// 求：批量确认过头了要能整本退回）。逐页读盘：reviewed 的页
  /// [PageAnnotation.resetToProposed]（识别框/文字/几何全保留，只清确认
  /// 标记），落盘后重建状态标记；当前页内存态同步重置。训练统计同步
  /// 回退：这些页不再产出任何样本，循环后主动触发一次增量导出，后端
  /// 会把它们的样本从数据集删掉并回退 manifest 记账（自动调度器对
  /// "全无确认标记"的页不会触发，必须显式导出）。
  bool _revertAllBusy = false;

  Future<void> _revertAllReviewedPages() async {
    if (_pageBatchBusy || _revertAllBusy) return;
    final project = widget.project;
    var reviewedCount = _markers.savedPages.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('全书「确认并保存」改回未保存'),
        content: Text(
          '本书绿框（确认并保存）页 $reviewedCount 个。'
          '这些页的确认标记将全部清除（识别框、文字与几何都保留，'
          '回到未确认状态可重新校对）；已计入训练数据的样本会自动'
          '清除并回退统计。此操作不可撤销，确定继续吗？',
          style: const TextStyle(fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('改回未保存'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    // 当前页未保存的编辑先落盘（撤确认以盘上最新态为基）。
    await _flushSave();
    if (!mounted) return;

    setState(() => _revertAllBusy = true);
    var touched = 0;
    var failed = 0;
    var cancel = false;
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
              title: const Text('全书改回未保存'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(
                    value: project.imageFiles.isEmpty
                        ? 1
                        : done / project.imageFiles.length,
                  ),
                  const SizedBox(height: 12),
                  Text('已完成 $done / ${project.imageFiles.length} · 改回 $touched 页'),
                  const SizedBox(height: 4),
                  const Text(
                    '确认标记清除中；识别框与文字保留',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
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

    for (var i = 0; i < project.imageFiles.length && !cancel; i++) {
      done = i;
      setProgress?.call(() {});
      final ann = await ProjectStorage.loadAnnotation(
        project.projectDir,
        project.pageIdAt(i),
        expectedImagePath: project.imageFiles[i],
      );
      if (ann == null || !ann.reviewed) continue;
      ann.resetToProposed();
      try {
        // machineWrite：逐页导出调度没有意义（页已全无确认标记会被跳
        // 过），循环结束统一导出一次完成清理与统计回退。
        await ProjectStorage.saveAnnotation(
          project.projectDir,
          ann,
          machineWrite: true,
        );
        touched++;
        if (i == _pageIndex) {
          // 当前页内存态同步：编辑器里的就是刚落盘的这份。
          setState(() {
            _annotation = ann;
            _dirty = false;
          });
        }
      } catch (error) {
        failed++;
        PythonService.addAppLog(
          '[保存诊断] ⚠ 第 ${i + 1} 页改回未保存写盘失败：$error',
          isError: true,
        );
      }
    }
    done = project.imageFiles.length;
    if (!cancel && mounted) {
      Navigator.of(context).pop();
    }
    await progressFuture;
    if (!mounted) return;
    // 状态标记按盘上最新态重建（绿框消失 → 紫框/橘黄按内容重新归档）。
    _markers
      ..savedPages.clear()
      ..boxesReviewedPages.clear()
      ..draftPages.clear()
      ..boxedUnconfirmedPages.clear();
    final markers = await PageStateMarkers.load(project);
    if (!mounted) return;
    setState(() {
      _markers
        ..savedPages.addAll(markers.savedPages)
        ..boxesReviewedPages.addAll(markers.boxesReviewedPages)
        ..draftPages.addAll(markers.draftPages)
        ..boxedUnconfirmedPages.addAll(markers.boxedUnconfirmedPages);
      _revertAllBusy = false;
    });
    unawaited(_refreshBookProgress());
    unawaited(_loadTrainReadiness());
    PythonService.addAppLog(
      '[编辑器] 全书改回未保存${cancel ? '（用户停止）' : ''}：'
      '$touched 页绿框清除${failed > 0 ? '，写盘失败 $failed 页' : ''}',
    );
    if (touched > 0 || failed > 0) {
      unawaited(
        PythonService.exportTrainDatasets(
          projectDir: project.projectDir,
        ).catchError((Object e) {
          PythonService.addAppLog('[编辑器] 改回未保存后的训练数据清理失败：$e', isError: true);
          return <String, dynamic>{};
        }),
      );
    }
    _snack(
      cancel
          ? '已停止：改回 $touched 页'
          : touched > 0
                ? '已把 $touched 页改回未保存（识别框与文字保留，训练统计已回退）'
                : '本书没有「确认并保存」过的页',
    );
  }

  /// 页面图像旋转/镜像（后端就地改写 PNG + 标注几何同步变换）。
  /// 方向变化后建议重新识别本页；此前已校对的文字与框仍与图像对齐。
  Future<void> _transformCurrentPage(String op) async {
    final ann = _annotation;
    if (_loading || ann == null) return;
    setState(() => _loading = true);
    try {
      final imagePath = _imagePath;
      final dims = await PythonService.transformPage(
        imagePath: imagePath,
        op: op,
      );
      final newW = (dims['new_w'] as num).toInt();
      final newH = (dims['new_h'] as num).toInt();
      ann.transformGeometry(op, newW, newH);
      _cancelPendingSave();
      // 从未落盘的空标注（手动模式里只打开过的页）变换后也不落盘：
      // 标注文件的存在是整本识别「该页已完成」的标记；变换后的图像
      // 由未来的整本识别直接识别。
      final persist = _annotationWorthPersisting(ann);
      if (persist) {
        ann.draftSaved = true;
        await ProjectStorage.saveAnnotation(widget.project.projectDir, ann);
      }
      // 路径不变：缩略图缓存失效 + 画布/行卡片按版本号重新解码
      FileImage(File(imagePath)).evict();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _dirty = false;
        _selected = null;
        _selectedLine = null;
        _selectedRegion = null;
        _selectedParagraph = null;
        _imageRevision++;
      });
      if (persist &&
          !_markers.savedPages.contains(_pageIndex) &&
          !_markers.boxesReviewedPages.contains(_pageIndex)) {
        _markers.draftPages.add(_pageIndex);
        _markers.boxedUnconfirmedPages.remove(_pageIndex);
      }
      unawaited(_refreshBookProgress());
      _snack(
        persist ? '页面已变换：标注几何已同步；若页面方向变化请重新识别本页' : '页面已变换（本页还未识别，无标注需要同步）',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('页面变换失败：$e');
    }
  }

  /// 删除当前书页：确认后删除图片（仅项目目录内的，连同诊断图）与
  /// 整页标注，其后各页标注索引前移（注解按页序号命名，页列表存于
  /// project.json）。不可撤销。
  Future<void> _confirmDeletePage() async {
    final project = widget.project;
    final index = _pageIndex;
    final fileName = p.basename(project.imageFiles[index]);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除第 ${index + 1} 页（$fileName）？'),
        content: const Text(
          '将删除该页图片（位于项目目录内时）与整页标注（含确认状态），'
          '其后各页编号前移。此操作不可撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    _cancelPendingSave();
    final imagePath = project.imageFiles[index];
    // ① 图片：项目目录内的就地删除（连同本页诊断图）；外部引用只移出列表
    if (p.isWithin(project.projectDir, imagePath)) {
      final file = File(imagePath);
      if (await file.exists()) await file.delete();
      final prefix = '${p.withoutExtension(imagePath)}_dbg_';
      final dir = Directory(p.dirname(imagePath));
      if (await dir.exists()) {
        await for (final entry in dir.list()) {
          if (entry is File && entry.path.startsWith(prefix)) {
            await entry.delete();
          }
        }
      }
    }
    FileImage(File(imagePath)).evict();
    // ② 标注：按本页图片的页号删除标注文件。页号以图片文件名为准
    // （稳定标识），图片删了标注即成孤儿、无需也不应把后续文件按下标
    // 前移重命名——旧逻辑曾因此造成"文件名页号 ≠ 内容 page_id"的错位
    // 文件，保存与读取各走一个文件、修改永远读不回来。
    final pageId = pageIdForImage(imagePath, index);
    final annDir = p.join(project.projectDir, 'annotations');
    for (final suffix in ['.json', '.json.bak']) {
      final f = File(p.join(annDir, pageId + suffix));
      if (await f.exists()) await f.delete();
    }
    // 文字汇总账本：删页即撤账（该页已确认文字移出字频统计）。
    unawaited(CharStatsService.removePage(project.projectDir, pageId));
    // ③ 项目页列表与进度计数
    project.imageFiles.removeAt(index);
    if (project.recognizedPages > 0) project.recognizedPages -= 1;
    project.lastPageIndex = project.imageFiles.isEmpty
        ? 0
        : project.lastPageIndex.clamp(0, project.imageFiles.length - 1);
    await ProjectStorage.save(project);
    // ④ 编辑器状态：索引集合平移、停在原位置（现在是原下一页）
    if (!mounted) return;
    if (project.imageFiles.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    final saved = {
      for (final v in _markers.savedPages)
        if (v != index) v > index ? v - 1 : v,
    };
    final boxesReviewed = {
      for (final v in _markers.boxesReviewedPages)
        if (v != index) v > index ? v - 1 : v,
    };
    final draft = {
      for (final v in _markers.draftPages)
        if (v != index) v > index ? v - 1 : v,
    };
    final boxed = {
      for (final v in _markers.boxedUnconfirmedPages)
        if (v != index) v > index ? v - 1 : v,
    };
    setState(() {
      _markers.savedPages
        ..clear()
        ..addAll(saved);
      _markers.boxesReviewedPages
        ..clear()
        ..addAll(boxesReviewed);
      _markers.draftPages
        ..clear()
        ..addAll(draft);
      _markers.boxedUnconfirmedPages
        ..clear()
        ..addAll(boxed);
      _pageIndex = index < project.imageFiles.length
          ? index
          : project.imageFiles.length - 1;
      _selected = null;
      _selectedLine = null;
    });
    await _loadPage();
    unawaited(_refreshBookProgress());
    _snack('已删除第 ${index + 1} 页（$fileName）');
  }

  /// 临时保存：把当前（可能未完成甚至没有任何）修改写盘，不确认任何
  /// 识别框和文字——不计入训练数据，也不计入书列表校对进度。适合
  /// 翻到本页看了看、只改了一部分还没校完的场景。
  Future<void> _saveDraftPage() async {
    if (_annotation == null) return;
    _cancelPendingSave();
    await _flushSave();
    if (!mounted) return;
    setState(() => _dirty = false);
    _snack('已临时保存：修改已写盘，未确认、不计入训练数据');
  }

  /// 本页识别方向设置：排版方向 + 横排/竖排阅读方向，均可按页覆盖整书
  /// 设置（个别页与整书不同时）。
  ///
  /// 方向决定行切分、阅读序与读法，因此保存后强制重新识别本页才生效
  /// ——现有标注会被新识别结果替换（与本页「重新识别」按钮同一路径）。
  Future<void> _showPageOrientationDialog() async {
    final project = widget.project;
    final pageId = _pageId;
    final current = project.pageDirectionOverrides[pageId];

    final choice = await showDialog<PageDirectionOverride>(
      context: context,
      builder: (ctx) => _PageDirectionDialog(
        bookSettings: project.settings,
        current: current,
      ),
    );
    if (!mounted || choice == null) return;
    if (_sameOverride(choice, current)) return; // 未变化

    final before = _describeDirection(
      project.effectiveOrientationFor(pageId),
      project.effectiveHorizontalDirFor(pageId),
      project.effectiveVerticalDirFor(pageId),
    );
    if (choice.isEmpty) {
      project.pageDirectionOverrides.remove(pageId);
    } else {
      project.pageDirectionOverrides[pageId] = choice;
    }
    await ProjectStorage.save(project);
    final after = _describeDirection(
      project.effectiveOrientationFor(pageId),
      project.effectiveHorizontalDirFor(pageId),
      project.effectiveVerticalDirFor(pageId),
    );
    PythonService.addAppLog(
      '[方向] ${project.name} $pageId 识别方向：$before → $after，重新识别本页',
    );
    await _loadPage(forceSegment: true);
  }

  static bool _sameOverride(
    PageDirectionOverride a,
    PageDirectionOverride? b,
  ) =>
      a.orientation == b?.orientation &&
      a.horizontalDir == b?.horizontalDir &&
      a.verticalDir == b?.verticalDir;

  static String _describeDirection(
    String orientation,
    String horizontalDir,
    String verticalDir,
  ) {
    final orientLabel = orientation == 'horizontal' ? '横排' : '竖排';
    if (orientation == 'horizontal') {
      return '$orientLabel（${horizontalDir == 'rtl' ? '从右到左' : '从左到右'}）';
    }
    return '$orientLabel（列序${horizontalDir == 'rtl' ? '从右到左' : '从左到右'}、'
        '${verticalDir == 'btt' ? '从下到上' : '从上到下'}）';
  }

  /// 识别引擎设置（书级）：Kraken / PaddleOCR 切换 + Paddle 模型档位。
  /// 写入 project.settings 并落盘，下次识别（本页/本行/整本）生效——
  /// 引擎只换"读字"的实现，版面/行/字框仍由自训模型给出，已确认的
  /// 标注不受影响（重识别才用新引擎读字）。
  Future<void> _showEngineSettingsDialog() async {
    final project = widget.project;
    final choice = await showDialog<(String, String, ProjectSettings)>(
      context: context,
      builder: (ctx) => _EngineSettingsDialog(
        engine: project.settings.engine,
        paddleModel: project.settings.paddleModel,
        vlSettings: project.settings,
      ),
    );
    if (!mounted || choice == null) return;
    final (engine, paddleModel, vlSettings) = choice;
    if (engine == project.settings.engine &&
        paddleModel == project.settings.paddleModel &&
        !_vlSettingsChanged(project.settings, vlSettings)) {
      return; // 未变化
    }
    final before = project.settings.engine == 'paddle' ? 'PaddleOCR' : 'Kraken';
    project.settings = vlSettings.copyWith(
      engine: engine,
      paddleModel: paddleModel,
    );
    await ProjectStorage.save(project);
    final after = engine == 'paddle' ? 'PaddleOCR' : 'Kraken';
    PythonService.addAppLog(
      '[引擎] ${project.name} 识别引擎：$before → $after'
      '${engine == 'paddle' ? '（模型 $paddleModel）' : ''}，下次识别生效',
    );
    setState(() {});
    _snack('识别引擎已切换为 $after，下次识别生效');
  }

  /// 「开始整本识别」（更多操作菜单）：手动模式的书整理完页面后从这里
  /// 开始整本识别。启动后退出编辑器回到书库看进度——识别进行中书库会
  /// 拦截再次进入，避免后台逐页写盘与页内编辑互相踩。
  Future<void> _startWholeBookRecognition() async {
    final project = widget.project;
    if (project.recognitionCompleted) {
      _snack('全书页面都已有识别结果，没有需要识别的页');
      return;
    }
    // Existing projects predate the project-level AI flag.  When the user
    // explicitly starts their book after enabling the global whole-book AI
    // switch, adopt that setting once and persist it; later settings changes
    // cannot affect this run.
    final ai = await OllamaSettings.load();
    if (!mounted) return;
    if (ai.enableLineAssist && !project.aiRecognitionAssist) {
      project.aiRecognitionAssist = true;
      await ProjectStorage.save(project);
      PythonService.addAppLog('[整本识别] 已将当前全局 AI 整行裁决设置写入项目');
    }
    if (!mounted) return;
    RecognitionQueue.instance.enqueue(project);
    _snack(
      project.aiRecognitionAssist
          ? '已开始整本识别（含 AI 整行裁决）：后台逐页识别无标注的页'
          : '已开始整本识别：后台逐页识别无标注的页（已有标注的页跳过）',
    );
    Navigator.of(context).pop();
  }

  Future<void> _switchPage(int index) async {
    if (index == _pageIndex) return;
    _cancelPendingSave();
    // 翻页只做临时保存：把本页已有的修改（可能没改完、甚至没改过）写盘
    // 防丢失，但不确认任何标注——翻看过的页不会进入训练数据。只有
    // 「确认并保存」才把整页识别框与文字固化为训练标注（绿框）。
    if (_annotation != null) {
      await _flushSave();
      _dirty = false;
    }
    if (!mounted) return;
    setState(() => _pageIndex = index);
    // 翻页后让当前页缩略图滚动到可见位置。
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollThumbsToCurrent(),
    );
    await _persistLastPageIndex();
    await _loadPage();
  }

  // ── block operations ──

  void _selectBlock(CharBlock? b) => setState(() => _selected = b);

  void _selectLine(LineBlock? l) => setState(() {
    _selectedLine = l;
    if (l != null) {
      _selected = null;
      _selectedRegion = null;
      _selectedParagraph = null;
    }
  });

  void _selectRegion(MainRegion? r) => setState(() {
    _selectedRegion = r;
    if (r != null) {
      _selected = null;
      _selectedLine = null;
      _selectedParagraph = null;
    }
  });

  void _selectParagraph(Paragraph? p) => setState(() {
    _selectedParagraph = p;
    if (p != null) {
      _selected = null;
      _selectedLine = null;
      _selectedRegion = null;
    }
  });

  // ── region/paragraph operations (region/paragraph view) ──

  /// region 视图「新框类别」：拖拽画的新主区框带这个 label。
  String _newRegionLabel = RegionLabel.mainText;
  bool _regionPrelabeling = false;
  bool _aiPrelabeling = false;

  /// 规则 + 跨页一致性预标注（后端只读）：建议落为 proposed 区域，
  /// 与已有区域重叠的跳过（只填空）；永不自动确认，人工核对后进训练集。
  Future<void> _runRegionPrelabel() async {
    final ann = _annotation;
    if (ann == null || _regionPrelabeling) return;
    setState(() => _regionPrelabeling = true);
    try {
      final result = await PythonService.regionPrelabel(
        projectDir: widget.project.projectDir,
        pageId: _pageId,
      );
      var added = 0;
      final stamp = DateTime.now().millisecondsSinceEpoch;
      if (result.suggestions.isNotEmpty) {
        final newRegions = <MainRegion>[];
        for (final s in result.suggestions) {
          final rect = Rect.fromLTWH(
            s.x.toDouble(),
            s.y.toDouble(),
            s.w.toDouble(),
            s.h.toDouble(),
          );
          // 只填空：与任何已有区域有实质重叠（交集占建议框 >5%）就跳过
          final clash = ann.mainRegions.any((r) {
            final inter = r.rect.intersect(rect);
            return !inter.isEmpty &&
                inter.width * inter.height > rect.width * rect.height * 0.05;
          });
          if (clash) continue;
          newRegions.add(
            MainRegion(
              id: 'mr_pre_${stamp}_${newRegions.length}',
              x: s.x,
              y: s.y,
              w: s.w,
              h: s.h,
              label: RegionLabel.normalize(s.label),
              status: AnnotationStatus.proposed,
            ),
          );
        }
        if (newRegions.isNotEmpty) {
          if (mounted) {
            setState(() => ann.mainRegions.addAll(newRegions));
            _save();
            added = newRegions.length;
          }
        }
      }
      _snack(
        added > 0
            ? '预标注新增 $added 个候选区（proposed，请核对类别与边界后确认）'
            : '未发现可新增的页眉/页脚/页码/眉批候选（或已有区域覆盖）',
      );
    } catch (e) {
      _snack('预标注失败：$e');
    } finally {
      if (mounted) setState(() => _regionPrelabeling = false);
    }
  }

  /// AI 整页预标注：素材图（网格+已有区域底色）→ VLM 判定五类版面区 →
  /// 后端几何精修 → proposed 区域。结果待人工确认，与已有区域重叠的跳过。
  Future<void> _runAiPagePrelabel() async {
    final ann = _annotation;
    if (ann == null || _aiPrelabeling || _regionPrelabeling) return;
    final ollama = await OllamaSettings.load();
    if (!ollama.enablePagePrelabel) {
      _snack('「AI 整页预标注」未开启：请在 AI 辅助设置（机器人图标）中打开', error: true);
      return;
    }
    final width = ann.sourceImageWidth > 0
        ? ann.sourceImageWidth
        : _canvasImageSize.width.round();
    final height = ann.sourceImageHeight > 0
        ? ann.sourceImageHeight
        : _canvasImageSize.height.round();
    if (!mounted) return; // 读设置的 await 期间用户可能已退出编辑器
    setState(() => _aiPrelabeling = true);
    try {
      final result = await runPagePrelabel(
        settings: ollama,
        imagePath: _imagePath,
        imageWidth: width,
        imageHeight: height,
        existingRegions: [
          for (final r in ann.mainRegions)
            {'x': r.x, 'y': r.y, 'w': r.w, 'h': r.h, 'label': r.label},
        ],
        wantThinking: ollama.enableAiThinking,
      );
      var added = 0;
      final newRegions = <MainRegion>[];
      if (result.regions.isNotEmpty) {
        for (final region in result.regions) {
          final clash = ann.mainRegions.any((r) {
            final inter = r.rect.intersect(region.rect);
            return !inter.isEmpty &&
                inter.width * inter.height > region.w * region.h * 0.05;
          });
          if (clash) continue;
          newRegions.add(region);
          added++;
        }
        if (newRegions.isNotEmpty) {
          if (mounted) {
            setState(() => ann.mainRegions.addAll(newRegions));
            _save();
          }
        }
      }
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('AI 整页预标注 · 结果'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '模型输出 ${result.vlmRegionCount} 个区域，'
                    '几何精修后保留 ${result.regions.length} 个，'
                    '新增 $added 个（其余与已有区域重叠被跳过）。\n'
                    '新增区域均为 proposed 状态，请在主区视图中核对类别与'
                    '边界后确认。',
                  ),
                  if (result.droppedReasons.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    const Text(
                      '精修阶段丢弃：',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    for (final reason in result.droppedReasons)
                      Text(
                        '· $reason',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    '模型：${result.trace.model}，'
                    '耗时 ${result.trace.elapsedMs} ms',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    } catch (e) {
      _snack('AI 预标注失败：$e');
    } finally {
      if (mounted) setState(() => _aiPrelabeling = false);
    }
  }

  void _updateRegionLabel(String label) {
    final ann = _annotation;
    final region = _selectedRegion;
    if (ann == null || region == null) return;
    final idx = ann.mainRegions.indexOf(region);
    if (idx < 0) return;
    setState(() {
      ann.mainRegions[idx] = MainRegion(
        id: region.id,
        x: region.x,
        y: region.y,
        w: region.w,
        h: region.h,
        label: label,
        status: region.status,
        boxConfirmed: region.boxConfirmed,
        uid: region.uid,
      );
      _selectedRegion = ann.mainRegions[idx];
    });
    _save();
  }

  // ─── 表格识别（+83） ─────────────────────────────────────────────────

  /// 选中 table 类主区对应的已识别表格：regionUid 精确匹配优先，uid
  /// 对不上（如调框后 uid 失效）按几何归属（表格中心落在主区内）。
  TableAnnotation? _tableForRegion(MainRegion region) {
    final ann = _annotation;
    if (ann == null) return null;
    if (region.uid.isNotEmpty) {
      for (final t in ann.tables) {
        if (t.regionUid == region.uid) return t;
      }
    }
    final cx = region.x + region.w / 2;
    final cy = region.y + region.h / 2;
    for (final t in ann.tables) {
      if (t.x <= cx && cx <= t.x + t.w && t.y <= cy && cy <= t.y + t.h) {
        return t;
      }
    }
    return null;
  }

  Future<void> _openOrRecognizeTable() async {
    final ann = _annotation;
    final region = _selectedRegion;
    if (ann == null || region == null || _tableBusy) return;
    final existing = _tableForRegion(region);
    if (existing != null) {
      await _pushTableReview(existing);
      return;
    }
    setState(() => _tableBusy = true);
    try {
      final table = await PythonService.recognizeTable(
        imagePath: ann.imagePath,
        x: region.x,
        y: region.y,
        w: region.w,
        h: region.h,
        settings: _pageSettings,
        id: 'tbl_${DateTime.now().millisecondsSinceEpoch % 1000000}',
        regionUid: region.uid,
      );
      if (!mounted) return;
      ann.tables.add(table);
      await _pushTableReview(table);
    } on TableGridNotFoundException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('表格识别失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _tableBusy = false);
    }
  }

  Future<void> _pushTableReview(TableAnnotation table) async {
    final ann = _annotation;
    if (ann == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TableReviewPage(
          imagePath: ann.imagePath,
          table: table,
          orientation: _pageSettings.orientation,
          horizontalDir: _pageSettings.horizontalDir,
          verticalDir: _pageSettings.verticalDir,
        ),
      ),
    );
    // 校对页直接改 table 实例；回来后刷新并临时保存。
    if (mounted) {
      setState(() {});
      _save();
    }
  }

  void _addRegion(MainRegion r) {
    final ann = _annotation;
    if (ann == null) return;
    setState(() {
      if (r.id.isEmpty) {
        r = MainRegion(
          id: 'mr_${DateTime.now().millisecondsSinceEpoch}',
          x: r.x,
          y: r.y,
          w: r.w,
          h: r.h,
          label: r.label.isEmpty ? _newRegionLabel : r.label,
        );
      }
      ann.mainRegions.add(r);
      _selectedRegion = r;
    });
    _save();
  }

  void _updateRegion(MainRegion old, MainRegion updated) {
    final ann = _annotation;
    if (ann == null) return;
    final idx = ann.mainRegions.indexOf(old);
    if (idx >= 0) {
      setState(() {
        ann.mainRegions[idx] = updated;
        if (_selectedRegion == old) _selectedRegion = updated;
        // 主区几何变化 → 手势结束后级联重识别段/行/字，
        // 区外旧行由 _rerecognizeRegion 统一清理（≤2px 微调不级联）
        if (_significantGeomChange(
          old.x,
          old.y,
          old.w,
          old.h,
          updated.x,
          updated.y,
          updated.w,
          updated.h,
        )) {
          _regionGeomDirty = true;
          _diagLogThrottled(
            'region:${updated.id}',
            '[编辑诊断] 主区几何 id=${updated.id} '
                '(${old.x},${old.y},${old.w},${old.h})→'
                '(${updated.x},${updated.y},${updated.w},${updated.h})',
          );
        }
      });
      _save();
    }
  }

  void _deleteSelectedRegion() {
    final ann = _annotation;
    if (ann == null || _selectedRegion == null) return;
    setState(() {
      ann.mainRegions.remove(_selectedRegion);
      _selectedRegion = null;
    });
    _save();
  }

  /// 清除本页全部正文区及其下游识别结果。保留页面和其它页数据。
  void _clearAllRegions() {
    final ann = _annotation;
    if (ann == null) return;
    setState(() {
      ann.mainRegions.clear();
      ann.paragraphs.clear();
      ann.lines.clear();
      _selectedRegion = null;
      _selectedParagraph = null;
      _selectedLine = null;
      _selected = null;
      ann.rebuildBlocks();
    });
    _save();
    _snack('已清除本页正文区、段、行和单字识别框');
  }

  void _addParagraph(Paragraph p) {
    final ann = _annotation;
    if (ann == null) return;
    final pageId = _pageId;
    Paragraph np = p;
    setState(() {
      if (p.id.isEmpty) {
        np = Paragraph(
          id: 'p_${DateTime.now().millisecondsSinceEpoch}',
          x: p.x,
          y: p.y,
          w: p.w,
          h: p.h,
          mainRegionId: p.mainRegionId,
          lineIds: p.lineIds,
          type: p.type,
          manual: true, // 用户手动画的段 → 级联重建时保留
        );
      }
      // 按中心点认领行、清被本次认领掏空的旧段（本来就空的新段不动，
      // 否则连画两个新段、前一个会被后一个顶替）——见模型方法注释。
      ann.addParagraphClaiming(np);
      _selectedParagraph = np;
    });
    // 新建段不能只认领当前已有的行：新段可能是用户刚刚框出的区域，
    // 其中还没有任何行框。保存初稿后立即调用段级识别，让后端重新分行并
    // 拆字；_rerecognizeParagraph 会将返回的行归属到这个段。
    _save().then((_) {
      if (!mounted ||
          _annotation != ann ||
          _pageId != pageId ||
          !ann.paragraphs.contains(np)) {
        return;
      }
      _queueParagraphCascade(np);
    });
  }

  void _updateParagraph(Paragraph old, Paragraph updated) {
    final ann = _annotation;
    if (ann == null) return;
    final idx = ann.paragraphs.indexOf(old);
    if (idx >= 0) {
      setState(() {
        ann.paragraphs[idx] = updated;
        if (_selectedParagraph == old) _selectedParagraph = updated;
        // 段几何变化 → 手势结束后级联重识别行/字
        if (_significantGeomChange(
          old.x,
          old.y,
          old.w,
          old.h,
          updated.x,
          updated.y,
          updated.w,
          updated.h,
        )) {
          _paraGeomDirty = true;
          _diagLogThrottled(
            'para:${updated.id}',
            '[编辑诊断] 段框几何 id=${updated.id} '
                '(${old.x},${old.y},${old.w},${old.h})→'
                '(${updated.x},${updated.y},${updated.w},${updated.h})',
          );
        }
      });
      _save();
    }
  }

  void _deleteSelectedParagraph() {
    final ann = _annotation;
    if (ann == null || _selectedParagraph == null) return;
    final target = _selectedParagraph!;
    late final int removedLines;
    setState(() {
      // 删段连带删除成员行与行内单字（与「清除本页段落」同口径），
      // 成员判定与其它段的死引用清理见 PageAnnotation.removeParagraphWithLines。
      removedLines = ann.removeParagraphWithLines(target);
      // 选中的行/字若随段被删，清掉选择（按"是否仍在行列表"判定，
      // 不依赖成员集合——lineIds 滞后时双保险）。
      if (_selectedLine != null &&
          !ann.lines.any((l) => l.id == _selectedLine!.id)) {
        _selectedLine = null;
      }
      if (_selected != null &&
          !ann.lines.any((l) => l.id == _selected!.lineId)) {
        _selected = null;
      }
      ann.rebuildBlocks();
      PythonService.addAppLog(
        '[删除] 段 ${target.id} 连带 $removedLines 行及其单字'
        '（剩余 ${ann.paragraphs.length} 段 ${ann.lines.length} 行）',
      );
    });
    _save();
  }

  /// 清除本页全部段落及其下游行、单字，正文区保持不变。
  void _clearAllParagraphs() {
    final ann = _annotation;
    if (ann == null) return;
    setState(() {
      ann.paragraphs.clear();
      ann.lines.clear();
      _selectedParagraph = null;
      _selectedLine = null;
      _selected = null;
      ann.rebuildBlocks();
    });
    _save();
    _snack('已清除本页段落、行和单字识别框');
  }

  /// 清除本页全部行框，同时清除行下级单字；正文区和段落保持不变。
  void _clearAllLines() {
    final ann = _annotation;
    if (ann == null) return;
    setState(() {
      ann.lines.clear();
      for (final p in ann.paragraphs) {
        p.lineIds.clear();
      }
      _selectedLine = null;
      _selected = null;
      ann.rebuildBlocks();
    });
    _save();
    _snack('已清除本页行和单字识别框');
  }

  /// 清除本页全部单字框，保留行及以上层级。
  void _clearAllChars() {
    final ann = _annotation;
    if (ann == null) return;
    setState(() {
      for (final line in ann.lines) {
        line.chars.clear();
        line.text = '';
      }
      _selected = null;
      ann.rebuildBlocks();
    });
    _save();
    _snack('已清除本页单字识别框');
  }

  // ── line operations (line view) ──

  /// 用户在行视图画了一个新框 → 创建占位 LineBlock，入队后台拆字 + OCR
  void _addLine(LineBlock stub) {
    if (_annotation == null) return;
    setState(() {
      // 画布新建的行没有 orientation（默认竖排）——按本页生效方向补上，
      // 横排页上新字按阅读序插入、行卡片布局立刻就是对的，不等识别回包。
      stub.orientation = _pageOrientation;
      // 手画的行框属于用户成果（manual）：本行的拆字识别在队列里排队
      // 期间，若有正在执行的主区/段级联先回包合并，manual 行会被
      // spliceRegionLines 钉住保留，不会被"删旧插新"洗掉。
      stub.manual = true;
      stub.lineNo = _annotation!.lines.length;
      _annotation!.lines.add(stub);
      _selectedLine = stub;
    });
    _queueNewLineCascade(stub);
  }

  /// 行被重识别整体替换（行 id 变化）后同步段落成员表：把旧行 id 换成
  /// 新行 id。不换的话 paragraph.lineIds 会指向已删除的行，段落合并/
  /// 导出读到孤儿 id（rebuildParagraphs 只在下一次区域级联时才自愈）。
  void _swapLineIdInParagraphs(
    PageAnnotation ann,
    String oldId,
    List<String> newIds,
  ) {
    for (final p in ann.paragraphs) {
      final i = p.lineIds.indexOf(oldId);
      if (i >= 0) {
        p.lineIds
          ..removeAt(i)
          ..insertAll(i, newIds);
      }
    }
  }

  /// 调后端对新行框做拆字 + OCR，用返回结果替换占位行
  /// （行内含并排双列时后端返回多行，逐行插入占位行位置）
  Future<void> _processNewLine(
    LineBlock stub, {
    bool Function() isStale = _neverStale,
  }) async {
    try {
      final lines = await PythonService.segmentRegion(
        imagePath: _imagePath,
        lineStub: stub,
        settings: _pageSettings,
        // 新画的框若与既有行共享列带（如在已分段的小字注列上补画一段），
        // 不外扩：识别范围即所画框。
        expand: !_sharesColumnBand(stub),
      );
      if (!mounted) return;
      if (isStale()) return; // 该行已重新入队：结果作废
      final ann = _annotation;
      if (ann == null) return;
      setState(() {
        // 识别期间占位行可能被拖动过（纯移动不触发重新入队，列表里已是
        // 同 id 的新实例）：按 id 重定位当前实例，结果落到最新位置/归属
        // 上，而不是因 indexOf 找不到而整包丢弃。
        var idx = ann.lines.indexOf(stub);
        if (idx < 0) idx = ann.lines.indexWhere((l) => l.id == stub.id);
        if (idx >= 0) {
          final host = ann.lines[idx];
          ann.lines.removeAt(idx);
          for (var k = 0; k < lines.length; k++) {
            final line = lines[k];
            line.lineNo = idx + k;
            // 段落归属随行走：识别期间段级联回包可能已把占位行认领进段。
            line.paragraphId = host.paragraphId;
            for (final c in line.chars) {
              c.col = idx + k;
              c.lineId = line.id;
            }
            ann.lines.insert(idx + k, line);
          }
          _swapLineIdInParagraphs(ann, host.id, [for (final l in lines) l.id]);
          // 识别期间用户改选了其它行时不抢占选择
          if ((_selectedLine == null || _selectedLine!.id == host.id) &&
              ann.lines.isNotEmpty) {
            _selectedLine = ann.lines[idx.clamp(0, ann.lines.length - 1)];
          }
        }
        ann.rebuildBlocks();
      });
      await _save();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '行识别失败: $e');
    }
  }

  /// 更新行几何（拖拽 / 缩放），同步移动内部 char 的相对偏移
  void _updateLine(LineBlock old, LineBlock updated) {
    final ann = _annotation;
    if (ann == null) return;
    var idx = ann.lines.indexOf(old);
    if (idx < 0) {
      // 手势进行中行对象可能刚被后台重识别替换成同 id 的新实例：
      // 按 id 重新定位让本次拖拽/缩放继续生效，手势结束时再以最新
      // 几何重新入队识别。
      idx = ann.lines.indexWhere((l) => l.id == old.id);
    }
    if (idx < 0) return;

    // 行移动/缩放时字框跟随行做相同变换：纯移动即平移；缩放时按比例同步
    // 缩放。否则行框调大后旧字框仍挤在原尺寸区域，重识别回填（数量一致
    // 时保留字框几何）会把过小的字框一直保留下去。
    final sx = old.w == 0 ? 1.0 : updated.w / old.w;
    final sy = old.h == 0 ? 1.0 : updated.h / old.h;

    setState(() {
      ann.lines[idx] = updated;
      // 用户手工改过本行几何：区域/段级联重建时保留本行，不被识别器
      // 输出洗回原样。
      updated.manual = true;
      if (old.x != updated.x ||
          old.y != updated.y ||
          old.w != updated.w ||
          old.h != updated.h) {
        _diagLogThrottled(
          'line:${updated.id}',
          '[编辑诊断] 行框几何 id=${updated.id} '
              '(${old.x},${old.y},${old.w},${old.h})→'
              '(${updated.x},${updated.y},${updated.w},${updated.h}) manual=true',
        );
      }
      for (final c in updated.chars) {
        c.x = (updated.x + (c.x - old.x) * sx).round();
        c.y = (updated.y + (c.y - old.y) * sy).round();
        c.w = max(1, (c.w * sx).round());
        c.h = max(1, (c.h * sy).round());
      }
      ann.rebuildBlocks();
      if (_selectedLine != null && _selectedLine!.id == updated.id) {
        _selectedLine = updated;
      }
      // 行尺寸变化 → 手势结束后推倒重拆（_handleGeometryEditEnd →
      // _queueResplitLine，与「重新切割本列」同链路）；上面的按比例拉伸
      // 只是手势期间的临时显示，重拆结果回来即被整体替换。纯移动时字框
      // 已跟随，无需重识别（尺寸 ≤2px 的微动同样只保存不触发）。
      if ((old.w - updated.w).abs() > 2 || (old.h - updated.h).abs() > 2) {
        _lineGeomDirty = true;
      }
    });
    _save();
  }

  // ── 级联重识别：改主区 → 重识别段/行/字；改段 → 重识别行/字；改行 → 重识别字 ──

  static bool _neverStale() => false;

  // ── 级联识别任务队列 ──
  // 改主区/段/行/单字框后的重识别一律入队后台执行，编辑操作不被阻塞：
  // · 同一目标再次修改 → 替换队列中等待的旧任务（以最新几何为准）；
  //   正在执行的旧任务结果会被丢弃（isStale），新任务随后立即接替——
  //   等效"停止旧分析，用新框尺寸重新分析"；
  // · 不同目标的任务按提交顺序排队执行；
  // · 后端忙碌（409）自动重试（最多 10 次，每次隔 2 秒）。
  final Map<String, int> _cascadeGen = {};
  final List<_CascadeTask> _cascadeQueue = [];
  bool _cascadeRunning = false;

  /// 正在执行的任务（null=队列空闲）。入队/出队/结束都刷新指示器，
  /// 指示器据此保住执行中行卡片的转圈——此前入队刷新不带活动任务，
  /// 会对第二行点"重新识别本行"时把第一行正在转的圈清掉。
  _CascadeTask? _cascadeActive;

  void _enqueueCascade(
    String key,
    String label,
    Future<void> Function(bool Function() isStale) run, {
    String? lineId,
    String? lineAction,
    bool silent = false,
  }) {
    // AI 检查识别框进行中不接受新的重识别任务：两者都改行数据，并发
    // 会互相覆盖合回结果。
    if (_boxReviewing) {
      _snack('AI 检查识别框进行中，请稍后再修改识别框');
      return;
    }
    final gen = (_cascadeGen[key] ?? 0) + 1;
    _cascadeGen[key] = gen;
    _cascadeQueue.removeWhere((t) => t.key == key);
    _cascadeQueue.add(
      _CascadeTask(
        key: key,
        label: label,
        gen: gen,
        run: run,
        lineId: lineId,
        lineAction: lineAction,
        silent: silent,
      ),
    );
    _refreshCascadeIndicator();
    unawaited(_pumpCascade());
  }

  Future<void> _pumpCascade() async {
    if (_cascadeRunning) return;
    _cascadeRunning = true;
    try {
      while (_cascadeQueue.isNotEmpty) {
        final task = _cascadeQueue.removeAt(0);
        _cascadeActive = task;
        _refreshCascadeIndicator();
        try {
          await task.run(() => _cascadeGen[task.key] != task.gen);
        } catch (e) {
          if (e is RecognitionBusyException && task.retries < 10) {
            task.retries++;
            _cascadeQueue.insert(0, task);
            await Future.delayed(const Duration(seconds: 2));
            continue;
          }
          _snack('${task.label}失败：$e', error: true);
        }
      }
    } finally {
      _cascadeRunning = false;
      _cascadeActive = null;
      _refreshCascadeIndicator();
    }
  }

  /// 画布上方悬浮状态胶囊与行卡片转圈由队列统一驱动：显示执行中任务
  /// 与排队长度。静默任务（单字识别）不参与：单字识别秒级完成且字块级
  /// 已有"识别中…"指示，状态条纯属噪声；排队数也只统计非静默任务。
  /// 行级任务执行中同样显示排队数胶囊——连点几行的"重新识别本行/重新
  /// 切割本列"时只有当前行转圈，排队几项必须可见。
  void _refreshCascadeIndicator() {
    if (!mounted) return;
    setState(() {
      _areaProcessing = false;
      _areaProcessingLabel = '';
      _lineProcessing = false;
      final task = _cascadeActive;
      final pending = _cascadeQueue.where((t) => !t.silent).length;
      String? lineId;
      String? lineAction;
      if (task != null && !task.silent) {
        if (task.lineId != null) {
          _lineProcessing = true;
          lineId = task.lineId;
          lineAction = task.lineAction;
        } else {
          _areaProcessingLabel = pending == 0
              ? task.label
              : '${task.label}（后排队列 $pending）';
        }
      }
      if (pending > 0 && _areaProcessingLabel.isEmpty) {
        _areaProcessingLabel = '识别排队中（$pending 项）';
      }
      if (_areaProcessingLabel.isNotEmpty) {
        _areaProcessing = true;
      }
      // 行级转圈：队列活动行优先，队列没有行级任务时保留直发路径
      // （AI 检查本行）设置的值。
      _processingLineId = lineId ?? _directProcessingLineId;
      _processingLineAction = lineId != null
          ? lineAction
          : _directProcessingLineAction;
    });
  }

  /// 直发路径开始/结束占用行级指示（不走级联队列的任务）。
  void _beginDirectLineProcessing(String lineId, String action) {
    _directProcessingLineId = lineId;
    _directProcessingLineAction = action;
    _refreshCascadeIndicator();
  }

  void _endDirectLineProcessing(String lineId) {
    if (_directProcessingLineId != lineId) return;
    _directProcessingLineId = null;
    _directProcessingLineAction = null;
    _refreshCascadeIndicator();
  }

  static bool _centerInRect(int x, int y, int w, int h, Rect outer) =>
      BookRegionApply.centerInRect(x, y, w, h, outer);

  static double _charAxis(CharBlock c, String orientation) =>
      orientation == 'horizontal' ? c.x + c.w / 2 : c.y + c.h / 2;

  /// 主区/段/行的几何编辑是否大到值得级联重识别：任一边变化 >2px 才
  /// 触发。拖角点时的 1px 误触（鼠标微动）也会发起 20 秒级联并把
  /// "中心点落到缩小后区域外"的行删掉——代价远超 1px 的校正收益，
  /// 这种微调只保存几何，不重建下游。
  static bool _significantGeomChange(
    int ax,
    int ay,
    int aw,
    int ah,
    int bx,
    int by,
    int bw,
    int bh,
  ) =>
      (ax - bx).abs() > 2 ||
      (ay - by).abs() > 2 ||
      (aw - bw).abs() > 2 ||
      (ah - bh).abs() > 2;

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: error ? Colors.red.shade700 : null,
          duration: Duration(seconds: error ? 4 : 2),
        ),
      );
    } catch (_) {
      // 元素处于停用窗口（mounted 仍为 true 但不能查祖先）：放弃提示。
    }
  }

  /// 整页直读完成且行记录落盘后，刷新标注行的整页对照标记
  /// （/refresh_full_text_check，纯 CPU 不重识别）：紫色无框字片
  /// （full_extras）与橙色不一致标记（full_diff）随最新直读行文本
  /// 更新——对照标记只在识别时写入标注，直读更新后不刷新会让标记
  /// 停在旧参照上（用户所见"看不到紫色字片"的时序坑）。增强路：
  /// 无标注/无字行/请求失败全部静默跳过，不影响直读结果。
  Future<void> _refreshFullTextMarks() async {
    final ann = _annotation;
    if (ann == null || ann.lines.isEmpty) return;
    final withChars =
        ann.lines.where((l) => l.chars.isNotEmpty).toList(growable: false);
    if (withChars.isEmpty) return;
    try {
      final updates = await PythonService.refreshFullTextCheck(
        imagePath: _imagePath,
        lines: [
          for (final l in withChars)
            {
              'id': l.id,
              'x': l.x,
              'y': l.y,
              'w': l.w,
              'h': l.h,
              'char_texts': [for (final c in l.chars) c.text],
            },
        ],
      );
      if (!mounted || updates.isEmpty) return;
      final byId = <String, Map<String, dynamic>>{
        for (final u in updates) u['id'].toString(): u,
      };
      var changed = 0;
      setState(() {
        for (final line in withChars) {
          final u = byId[line.id];
          if (u == null) continue;
          final text = (u['full_text'] as String?) ?? '';
          line.fullText = text.isEmpty ? null : text;
          line.fullExtras = [
            for (final e in (u['full_extras'] as List? ?? const []))
              e.toString(),
          ];
          final diffIdx = <int>{
            for (final e in (u['diff_indices'] as List? ?? const []))
              if (e is num) e.toInt(),
          };
          for (var i = 0; i < line.chars.length; i++) {
            line.chars[i].fullDiff = diffIdx.contains(i);
          }
          changed++;
        }
      });
      if (changed > 0) {
        await _save();
        _snack('整页对照已按最新直读刷新：$changed 行');
      }
    } catch (e) {
      // 静默：对照是增强路，刷新失败不惊扰直读流程
      debugPrint('刷新整页对照标记失败: $e');
    }
  }

  // ── Excalidraw 框选导出 ──

  void _toggleExcalidrawPick() {
    setState(() {
      _excalidrawPicking = !_excalidrawPicking;
      if (_excalidrawPicking && _viewMode == 'char') {
        _viewMode = 'line'; // 单字视图没有画布，切到行视图框选
      }
    });
    if (_excalidrawPicking) {
      _snack('在页面画布空白处拖拽，框选要导出为图形的区域');
    }
  }

  /// 画布框选完成（图像坐标）：打开导出工作台（预览 + 调参 + 保存）。
  /// 返回 'repick' 表示用户要求重新框选。
  Future<void> _onExcalidrawRegionPicked(Rect rect) async {
    setState(() => _excalidrawPicking = false);
    if (_annotation == null) return;
    final result = await ExcalidrawExportDialog.show(
      context,
      imagePath: _imagePath,
      region: rect,
      annotation: _annotation!,
      pageSettings: _pageSettings,
    );
    if (result == 'repick' && mounted) {
      _toggleExcalidrawPick();
    }
  }

  Widget _excalidrawPickBanner() {
    return Material(
      color: Colors.deepPurple.shade50,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            const Icon(Icons.draw_outlined, size: 18),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Excalidraw 导出：在画布空白处拖拽框选区域（含图形与文字），松手后在工作台调参导出',
                style: TextStyle(fontSize: 12),
              ),
            ),
            TextButton(
              onPressed: () => setState(() => _excalidrawPicking = false),
              child: const Text('取消'),
            ),
          ],
        ),
      ),
    );
  }

  // ── 画布区悬浮状态条 ──────────────────────────────────────────────────
  // 主区/段/行/字的重识别与 AI 检查都在后台进行，"正在识别中"提示条此前
  // 作为 Column 的条件子项插在画布上方：出现/收回的瞬间画布高度变化，
  // 下方书页跟着上下跳动。改为浮在画布上的状态胶囊（Stack 悬浮，不占
  // 布局空间），出现/消失不再影响书页显示。

  Widget _canvasStatusOverlay({required Widget child}) {
    // 结构恒定：child 永远是第一个子项（fit: expand 撑满），状态胶囊只是
    // 追加/移除后面的 Positioned 叶子。此前胶囊为空时直接返回 child、
    // 非空时才包 Stack——级联任务开始/结束会把整个画布子树（含
    // _AnnotationCanvas 的 State：图像、变换矩阵、拖拽手势）dispose 掉
    // 全量重建，识别期间反复入队时画布状态反复被清零。
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        if (_boxReviewing || _areaProcessing)
          Positioned(
            // 排序模式横幅是条件子项（固定高度约 36px），同时存在时下移避开
            top: _reorderMode ? 46 : 8,
            left: 16,
            right: 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_boxReviewing)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: _boxReviewChip(),
                  ),
                if (_areaProcessing) _cascadeChip(),
              ],
            ),
          ),
      ],
    );
  }

  /// AI 检查识别框：带"取消剩余"按钮，胶囊本体可点击。
  Widget _boxReviewChip() {
    return Center(
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        decoration: BoxDecoration(
          color: Colors.deepPurple.shade50.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.deepPurple.shade200),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                'AI 检查识别框：$_boxReviewDone/$_boxReviewTotal 行'
                '（逐行诊断+重摆，可能需要几分钟）',
                style: const TextStyle(fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              onPressed: () => _boxReviewCancelRequested = true,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 30),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('取消剩余'),
            ),
          ],
        ),
      ),
    );
  }

  /// 级联识别进行中/排队中：纯展示胶囊，IgnorePointer 不挡画布手势。
  Widget _cascadeChip() {
    return Center(
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.blue.shade50.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.blue.shade200),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '$_areaProcessingLabel（后台进行，可继续编辑）',
                  style: const TextStyle(fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 保存/载入诊断日志 ─────────────────────────────────────────────────
  // 诊断"修改后切页回来变回原样"：编辑提交、写盘、读盘、级联重建四段
  // 全部打点到后台日志（[保存诊断]/[载入诊断]/[级联诊断]/[编辑诊断]），
  // 快照含 manual 行数与首字框几何，前后对比即知断点在哪一段。

  String _annDebugSnapshot(PageAnnotation ann) {
    final first = ann.blocks.isEmpty ? null : ann.blocks.first;
    return '${ann.pageId} 行=${ann.lines.length} 字=${ann.blocks.length} '
        'manual行=${ann.lines.where((l) => l.manual).length} '
        '首字=${first == null ? "无" : "(${first.x},${first.y},${first.w},${first.h})"} '
        'boxesReviewed=${ann.boxesReviewed} reviewed=${ann.reviewed}';
  }

  final Map<String, DateTime> _diagLogAt = {};

  /// 同 key 每秒最多一条（拖拽期间逐帧提交的几何更新靠它防刷屏）。
  void _diagLogThrottled(String key, String message) {
    final now = DateTime.now();
    final last = _diagLogAt[key];
    if (last != null && now.difference(last).inMilliseconds < 1000) return;
    _diagLogAt[key] = now;
    PythonService.addAppLog(message);
  }

  /// 画布手势（拖动/缩放主区、段、行）结束后，按修改对象分发级联识别
  /// （全部入队后台执行，不阻塞继续编辑；同目标重复修改自动以最新几何为准）
  /// 画布图像解码完成：记录图片尺寸（层级推断钳制用），并把当前标注
  /// 的全部几何（主区/段落/行/字）钳回图片范围。修复盘上旧数据的越界
  /// 框（实测主区 0,0,1342,2157 超出 1298×2074 页面，编辑器紫框画出
  /// 页面外）；有实际修改时静默落盘。
  void _onCanvasImageReady(Size size) {
    _canvasImageSize = size;
    _applyAnnotationClamp();
  }

  /// 按已知的画布图像尺寸钳制当前标注（图像与标注谁先就绪都会执行；
  /// 无改动时零开销）。
  void _applyAnnotationClamp() {
    if (_canvasImageSize == Size.zero) return;
    final ann = _annotation;
    if (ann == null) return;
    // 只做页面边界钳制，不做包含关系扩容：载入时的"主区扩到含段"
    //（只扩不缩）与主区快设/全书叠加的"只改框"语义正面冲突——用户
    // 缩小主区后行/段按设计原样保留、等按主区拆分时清理（spliceRegion
    // Lines 的 pruneOutsideRegions），载入即扩容等于悄悄把用户刚改的
    // 主区撑回全页。包含关系修复只在识别/级联重建之后执行（行重识别
    // /AI 修复/重切等处），那时行框确实是新几何、容器滞后。
    final clamped = ann.clampAllToImage(
      _canvasImageSize.width.round(),
      _canvasImageSize.height.round(),
    );
    if (!clamped) {
      return;
    }
    PythonService.addAppLog(
      '[几何修复] 行/段/主区已钳回页面边界'
      '（${_canvasImageSize.width.round()}x'
      '${_canvasImageSize.height.round()}）',
    );
    setState(() => ann.rebuildBlocks());
    unawaited(_save());
  }

  void _handleGeometryEditEnd() {
    // 单字框几何调整（拖动/缩放）→ 只重识别这一个字框
    if (_charGeomDirty) {
      _charGeomDirty = false;
      final id = _charGeomDirtyId;
      _charGeomDirtyId = null;
      if (id != null && _annotation != null) {
        for (final line in _annotation!.lines) {
          for (final c in line.chars) {
            if (c.id == id) {
              _queueCharCascade(c, preserveUserText: false);
              return;
            }
          }
        }
      }
      return;
    }
    if (_regionGeomDirty && _selectedRegion != null) {
      _regionGeomDirty = false;
      _queueRegionCascade(_selectedRegion!);
    } else if (_paraGeomDirty && _selectedParagraph != null) {
      _paraGeomDirty = false;
      _queueParagraphCascade(_selectedParagraph!);
    } else if (_lineGeomDirty && _selectedLine != null) {
      _lineGeomDirty = false;
      // 行框尺寸变化 → 推倒重拆（与「重新切割本列」同链路），不是保留
      // 框几何的重填：旧行框里的字框已被 _updateLine 按比例拉伸，与新版
      // 心墨迹错位，行框放大盖住更多字时更是一个字都对不上——拿着错位
      // 的框逐框读字，裁切差、文字也差，还得手动再点一次重识别。手势给
      // 出的新框就是识别范围（不再外扩），重切结果也不被行框外扩覆盖。
      _queueResplitLine(_selectedLine!, expand: false);
    } else {
      _regionGeomDirty = false;
      _paraGeomDirty = false;
      _lineGeomDirty = false;
    }
  }

  /// 对矩形区域内旧线框做替换式重建：调后端分行+拆字+OCR，
  /// 删除中心点落在 rect 内的旧行，插入新行，并重排全页行号。
  /// [pruneOutsideRegions]：主区重识别时，中心点不在任何主区内的旧行
  /// 一并删除（主区即正文边界，区外旧线属于历史残留，如已缩小的主区）。
  /// [ownerDeleted]：识别期间目标主区/段被用户删除时返回 true——此时
  /// 结果整包作废（主区级联还会清理"区外残留"，按旧矩形合并会把全页
  /// 行洗掉）。
  /// 返回 (移除的旧行 ID, 新行列表, 区域外删除数)。调用方需在 await 后校验 ann 仍为当前页。
  Future<
    ({List<String> removedIds, List<LineBlock> newLines, int removedOutside})?
  >
  _replaceLinesInRect(
    PageAnnotation ann,
    Rect rect,
    String processingLabel, {
    bool pruneOutsideRegions = false,
    bool Function() isStale = _neverStale,
    bool Function()? ownerDeleted,
  }) async {
    final newLines = await PythonService.segmentLinesInRegion(
      imagePath: _imagePath,
      x: rect.left.toInt(),
      y: rect.top.toInt(),
      w: rect.width.toInt(),
      h: rect.height.toInt(),
      settings: _pageSettings,
    );
    if (!mounted || ann != _annotation) {
      return null;
    }
    if (isStale()) {
      // 该目标已重新入队（用了更新的几何）：本次结果作废，新任务即将接替。
      return null;
    }
    if (ownerDeleted != null && ownerDeleted()) {
      return null;
    }
    // 分类与合并（用户成果行保护、区外残留删除、去重插入、行号重排）
    // 委托共享服务，与全书叠加批量应用保持同一份规则。
    final stats = BookRegionApply.spliceRegionLines(
      ann,
      newLines: newLines,
      rect: rect,
      pruneOutsideRegions: pruneOutsideRegions,
    );
    if (!mounted || ann != _annotation) {
      return null;
    }
    setState(() {
      _selected = null;
      // 识别期间允许编辑：选中行若不在本次被替换范围内则保留选择，
      // 正在进行的行拖拽/缩放才能在手势结束后正常触发级联重识别。
      if (_selectedLine != null &&
          stats.removedIds.contains(_selectedLine!.id)) {
        _selectedLine = null;
      }
    });
    PythonService.addAppLog(
      '[级联诊断] rect=(${rect.left.toInt()},${rect.top.toInt()},'
      '${rect.width.toInt()},${rect.height.toInt()}) '
      '识别返回${newLines.length}行 → 删除旧行${stats.removedIds.length} '
      '保留用户成果行${stats.pinnedCount}（含manual/全确认） '
      '去重后插入${stats.newLines.length}行'
      '${stats.removedOutside > 0 ? ' 区外删除${stats.removedOutside}行' : ''}',
    );
    return (
      removedIds: stats.removedIds,
      newLines: stats.newLines,
      removedOutside: stats.removedOutside,
    );
  }

  /// 主区几何被修改后：重新识别该区内的段、行、单字，
  /// 并删除不属于任何主区的旧行（及其所属段落）
  Future<void> _rerecognizeRegion(
    MainRegion region, {
    bool Function() isStale = _neverStale,
  }) async {
    final ann = _annotation;
    if (ann == null) return;
    final result = await _replaceLinesInRect(
      ann,
      region.rect,
      '主区重识别（段/行/字）',
      pruneOutsideRegions: true,
      isStale: isStale,
      // 识别期间主区被删除：结果作废，不按旧矩形合并/清理
      ownerDeleted: () => !ann.mainRegions.any((r) => r.id == region.id),
    );
    if (result == null) return;
    if (!mounted || ann != _annotation) return;
    setState(() {
      // 段级联：手动段落按矩形认领行，其余行按竖排规则重新分段
      ann.rebuildParagraphs(
        orientation: _pageOrientation,
        horizontalDir: _pageSettings.horizontalDir,
        verticalDir: _pageSettings.verticalDir,
      );
      ann.rebuildBlocks();
      // 识别期间用户可能已改选其它目标（不抢占当前选择）；恢复选中时按
      // id 取当前列表里的对象——识别期间该区可能已被再次编辑替换。
      if (_selectedRegion == null) {
        for (final r in ann.mainRegions) {
          if (r.id == region.id) {
            _selectedRegion = r;
            break;
          }
        }
      }
    });
    await _save();
    _snack(
      result.removedOutside > 0
          ? '主区重识别完成：${result.newLines.length} 行，'
                '移除区域外 ${result.removedOutside} 行'
          : '主区重识别完成：${result.newLines.length} 行',
    );
  }

  /// 段几何被修改后：重新识别该段内的行、单字（段落本身保留，不重新分段）
  Future<void> _rerecognizeParagraph(
    Paragraph paragraph, {
    bool Function() isStale = _neverStale,
  }) async {
    final ann = _annotation;
    if (ann == null) return;
    final paraRect = paragraph.rect;
    final result = await _replaceLinesInRect(
      ann,
      paraRect,
      '段重识别（行/字）',
      isStale: isStale,
      // 识别期间该段被删除：结果作废，不给死段落重新认领行
      ownerDeleted: () => !ann.paragraphs.any((p) => p.id == paragraph.id),
    );
    if (result == null) return;
    if (!mounted || ann != _annotation) return;
    // 被替换的旧行可能原本属于其它段；清理这些段的旧 lineIds，避免
    // 新行已归属当前段后，旧段仍保留指向不存在行的历史引用。
    final removedIds = result.removedIds.toSet();
    if (removedIds.isNotEmpty) {
      for (final p in ann.paragraphs) {
        if (p.id != paragraph.id) {
          p.lineIds.removeWhere(removedIds.contains);
        }
      }
      // 只清被本次替换掏空的自动段：手动段（含刚画、行还没识别回来的
      // 空段）钉住保留，否则并发识别期间新画的段框会被这行洗掉。
      ann.paragraphs.removeWhere(
        (p) => p.id != paragraph.id && !p.manual && p.lineIds.isEmpty,
      );
    }
    // 按新段框重新归属：中心点落在段内的行都归入该段
    final memberIds = <String>{};
    for (final l in ann.lines) {
      if (_centerInRect(l.x, l.y, l.w, l.h, paraRect)) {
        memberIds.add(l.id);
      } else if (l.paragraphId == paragraph.id) {
        l.paragraphId = '';
      }
    }
    setState(() {
      for (final l in ann.lines) {
        if (memberIds.contains(l.id)) l.paragraphId = paragraph.id;
      }
      paragraph.lineIds
        ..clear()
        ..addAll(memberIds);
      ann.rebuildBlocks();
      // 识别期间用户可能已改选其它目标（不抢占当前选择）；恢复选中时按
      // id 取当前列表里的对象——识别期间该段可能已被再次编辑替换。
      if (_selectedParagraph == null) {
        for (final p in ann.paragraphs) {
          if (p.id == paragraph.id) {
            _selectedParagraph = p;
            break;
          }
        }
      }
    });
    await _save();
    _snack('段重识别完成：${memberIds.length} 行');
  }

  /// 行几何被修改后：对该行框重新拆字 + OCR，替换行内单字
  Future<void> _rerecognizeLineChars(
    LineBlock line, {
    bool Function() isStale = _neverStale,
  }) async {
    final ann = _annotation;
    if (ann == null) return;
    // 任务出队时才选中该行；用户正在编辑/已改选其它目标时不抢占选择。
    if (_selectedLine == null) {
      setState(() => _selectedLine = line);
    }
    try {
      // 把该行当前的字框（含手画/调整过的框）传给后端：仅对这些框重新
      // OCR 填字并严格保留框几何（字框数与整行读法不一致也不弃用重切
      // ——框是人工校对成果）；行内没有字框时后端退回自动拆字。
      final freshLines = await PythonService.segmentRegion(
        imagePath: _imagePath,
        lineStub: line,
        settings: _pageSettings,
        charBoxes: [
          for (final c in line.chars) {'x': c.x, 'y': c.y, 'w': c.w, 'h': c.h},
        ],
        strictCharBoxes: true,
        // 共享列带的小字注分段：整行序列读法也限定在段框内，否则整列
        // 读法与分段框在融合层互相污染。
        expand: !_sharesColumnBand(line),
      );
      final aiSettings = await OllamaSettings.load();
      if (aiSettings.enableManualLineAssist) {
        await applyAiLineAssistToLines(
          freshLines,
          _imagePath,
          _pageSettings,
          enabled: true,
          projectDir: widget.project.projectDir,
          pageId: _pageId,
        );
      }
      if (!mounted || ann != _annotation) {
        return;
      }
      if (isStale()) {
        // 该行已重新入队（更新几何）：本次结果作废，新任务即将接替。
        return;
      }
      setState(() {
        // 识别期间行对象可能被拖拽替换成同 id 新实例（纯移动不触发重新
        // 入队）：按 id 重定位当前实例，结果落到最新几何/归属上。
        var idx = ann.lines.indexOf(line);
        if (idx < 0) idx = ann.lines.indexWhere((l) => l.id == line.id);
        if (idx >= 0) {
          final cur = ann.lines[idx];
          final stamp = DateTime.now().microsecondsSinceEpoch;
          ann.lines.removeAt(idx);
          for (var k = 0; k < freshLines.length; k++) {
            final fresh = freshLines[k];
            for (var j = 0; j < fresh.chars.length; j++) {
              final c = fresh.chars[j];
              c.id = 'c_${stamp}_${k}_$j';
              c.col = idx + k;
              c.order = j;
              c.lineId = fresh.id;
            }
            fresh.paragraphId = cur.paragraphId;
            fresh.readingOrder = cur.readingOrder;
            // 用户手工调过的行框几何权威：后端"沿阅读轴向连续墨迹外扩"
            // 会覆盖手动收窄的宽度/高度（高度调低触发重识别后宽度被自动
            // 撑宽、改不小），manual 行保留用户框，仅采纳重识别的字框。
            // 并排双列拆分（多行返回）时旧框对应的是拆前的整条，逐行保
            // 留会把拆分行全部撑回整条几何——此时采纳后端子行框、视为
            // 非手工行。
            if (cur.manual && freshLines.length == 1) {
              fresh.x = cur.x;
              fresh.y = cur.y;
              fresh.w = cur.w;
              fresh.h = cur.h;
            }
            fresh.manual = cur.manual && freshLines.length == 1;
            ann.lines.insert(idx + k, fresh);
          }
          _swapLineIdInParagraphs(ann, cur.id, [
            for (final f in freshLines) f.id,
          ]);
          if (_selectedLine != null &&
              _selectedLine!.id == cur.id &&
              ann.lines.isNotEmpty) {
            _selectedLine = ann.lines[idx.clamp(0, ann.lines.length - 1)];
          }
        }
        // 重识别后的行框可能超出所属段/主区旧几何：扩容器（只扩不缩）
        ann.ensureHierarchyContainment();
        ann.rebuildBlocks();
      });
      PythonService.addAppLog(
        '[行重识别] id=${line.id} '
        '框(${line.x},${line.y},${line.w},${line.h})→'
        '${freshLines.length}行 字${line.chars.length}→'
        '${freshLines.fold<int>(0, (n, l) => n + l.chars.length)}'
        '（保留传入框几何'
        '${line.manual && freshLines.length == 1 ? '·手工行框不被外扩覆盖' : ''}'
        '${freshLines.length > 1 ? '·并排双列已拆分' : ''}）',
      );
      await _save();
      _snack(
        freshLines.length > 1
            ? '行重识别完成：检出并排双列，已拆为 ${freshLines.length} 行'
            : '行重识别完成：${freshLines.first.chars.length} 字',
      );
    } catch (e) {
      if (!mounted) return;
      _snack('行重识别失败：$e', error: true);
    }
  }

  /// 按 AI 标记局部修复一行（快捷面板/溯源入口手动触发）：从首个带
  /// aiBoxIssue 标记的字框的前一框起始边裁到行末尾，后端重识别该尾段
  /// 并合并回整行（前段框原样保留），质量分裁决采纳，采纳后 AI 复核。
  /// 全程追加进本页溯源时间线（不清除上一次识别运行的记录）。
  Future<void> _repairLineFromAiMarks(LineBlock line) async {
    final ann = _annotation;
    if (ann == null || _aiRepairing) return;
    final sorted = List<CharBlock>.from(line.chars)
      ..sort((a, b) => a.order.compareTo(b.order));
    final idx = sorted.indexWhere((c) => (c.aiBoxIssue ?? '').isNotEmpty);
    if (idx < 0) {
      _snack('该行没有 AI 切分问题标记（先跑一次整行 AI 辅助）');
      return;
    }
    setState(() => _aiRepairing = true);
    try {
      final ollama = await OllamaSettings.load();
      final model = ollama.activeVisionModel.isNotEmpty
          ? ollama.activeVisionModel
          : ollama.activeTextModel;
      final recorder = await AiTraceRecorder.continueRun(
        widget.project.projectDir,
        _pageId,
        model: model,
        provider: ollama.provider.wire,
      );
      final outcome = await runTailRepair(
        line: line,
        lines: ann.lines,
        lineIndex: ann.lines.indexOf(line),
        imagePath: _imagePath,
        settings: _pageSettings,
        ollama: ollama,
        recorder: recorder,
        startOrder: idx,
        issueType: sorted[idx].aiBoxIssue ?? 'char_clipped',
        note: sorted[idx].aiBoxNote ?? '',
        log: PythonService.addAppLog,
      );
      await recorder?.flush();
      if (!mounted || ann != _annotation) return;
      if (outcome.adopted) {
        setState(() {
          ann.ensureHierarchyContainment();
          ann.rebuildBlocks();
        });
        await _save();
        _snack(
          'AI 局部修复已采纳：保留前 ${outcome.prefixLength} 字框，'
          '重摆后整行 ${outcome.mergedCount} 字（已 AI 复核）',
        );
      } else {
        _snack('AI 局部修复未采纳：${outcome.error ?? outcome.reason}');
      }
    } catch (e) {
      if (!mounted) return;
      _snack('AI 局部修复失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _aiRepairing = false);
    }
  }

  /// 该行是否与其它行共享列带（竖排=横向范围重叠、横排=纵向范围重叠）：
  /// 小字注释列被拆成多段单行时的分段行。共享列带的行重识别/重切时
  /// 不做"行框外扩到整列墨迹"——外扩会顺着小注列的连续墨迹把两字段
  /// 吞成整列，切出的全部字框叠在两字段图上。
  bool _sharesColumnBand(LineBlock line) {
    final ann = _annotation;
    if (ann == null) return false;
    return lineSharesColumnBand(line, ann.lines);
  }

  /// 重新切割该列：丢弃现有字框几何与文字，对该行做全新拆字 + OCR
  /// （含连通域/网格切分、标点拆分与合并等全部后检）。与"重新识别
  /// 本行"（保留既有字框、只重新填字）相对，用于整列切分错乱后的推
  /// 倒重切。由级联队列调度（[_queueResplitLine]），不再自行设置行级
  /// 转圈。
  Future<void> _resplitLineChars(
    LineBlock line, {
    bool Function() isStale = _neverStale,
    bool? expand,
  }) async {
    final ann = _annotation;
    if (ann == null) return;
    if (_selectedLine == null) {
      setState(() => _selectedLine = line);
    }
    try {
      // 不传 charBoxes：后端不做"保留框几何"，走完整自动拆字链路。
      // 与其它行共享列带（小字注分段）时禁止行框外扩：识别范围即本
      // 段行框，否则两字段被外扩成整列、整列字框叠到段图上。
      final freshLines = await PythonService.segmentRegion(
        imagePath: _imagePath,
        lineStub: line,
        settings: _pageSettings,
        expand: expand ?? !_sharesColumnBand(line),
      );
      final aiSettings = await OllamaSettings.load();
      if (aiSettings.enableManualLineAssist) {
        await applyAiLineAssistToLines(
          freshLines,
          _imagePath,
          _pageSettings,
          enabled: true,
          projectDir: widget.project.projectDir,
          pageId: _pageId,
        );
      }
      if (!mounted || ann != _annotation) return;
      if (isStale()) return; // 该行已重新入队（更新意图）：本次结果作废
      setState(() {
        // 识别期间行对象可能被拖拽替换成同 id 新实例：按 id 重定位当前
        // 实例，重切结果落到最新几何/归属上。
        var idx = ann.lines.indexOf(line);
        if (idx < 0) idx = ann.lines.indexWhere((l) => l.id == line.id);
        if (idx >= 0) {
          final cur = ann.lines[idx];
          final stamp = DateTime.now().microsecondsSinceEpoch;
          ann.lines.removeAt(idx);
          for (var k = 0; k < freshLines.length; k++) {
            final fresh = freshLines[k];
            for (var j = 0; j < fresh.chars.length; j++) {
              final c = fresh.chars[j];
              c.id = 'c_${stamp}_${k}_$j';
              c.col = idx + k;
              c.order = j;
              c.lineId = fresh.id;
            }
            fresh.paragraphId = cur.paragraphId;
            fresh.readingOrder = cur.readingOrder;
            // 推倒重切同样尊重手工行框（外扩框会覆盖手动收窄的几何）。
            // 并排双列拆分（多行返回）时旧框是拆前整条，保留会把拆分行
            // 全部撑回整条几何——此时采纳后端子行框。
            if (cur.manual && freshLines.length == 1) {
              fresh.x = cur.x;
              fresh.y = cur.y;
              fresh.w = cur.w;
              fresh.h = cur.h;
            }
            fresh.manual = cur.manual && freshLines.length == 1;
            ann.lines.insert(idx + k, fresh);
          }
          _swapLineIdInParagraphs(ann, cur.id, [
            for (final f in freshLines) f.id,
          ]);
          if (_selectedLine != null &&
              _selectedLine!.id == cur.id &&
              ann.lines.isNotEmpty) {
            _selectedLine = ann.lines[idx.clamp(0, ann.lines.length - 1)];
          }
        }
        // 重切后的行框可能超出所属段/主区旧几何：扩容器（只扩不缩）
        ann.ensureHierarchyContainment();
        ann.rebuildBlocks();
      });
      PythonService.addAppLog(
        '[重切诊断] id=${line.id} '
        '框(${line.x},${line.y},${line.w},${line.h})→'
        '${freshLines.length}行 '
        '字${line.chars.length}→'
        '${freshLines.fold<int>(0, (n, l) => n + l.chars.length)}'
        '（推倒重切，旧框丢弃'
        '${line.manual && freshLines.length == 1 ? '·手工行框保留' : ''}'
        '${freshLines.length > 1 ? '·并排双列已拆分' : ''}）',
      );
      await _save();
      _snack(
        freshLines.length > 1
            ? '重新切割完成：检出并排双列，已拆为 ${freshLines.length} 行'
            : '重新切割完成：${freshLines.first.chars.length} 字',
      );
    } catch (e) {
      if (!mounted) return;
      _snack('重新切割失败：$e', error: true);
    }
  }

  /// 详细视图列2字块长按拖拽后：调整该行内字序并同步拼接文本
  void _reorderLineChars(LineBlock line, int oldIndex, int newIndex) {
    final ann = _annotation;
    if (ann == null) return;
    if (oldIndex < 0 || oldIndex >= line.chars.length) return;
    final to = newIndex.clamp(0, line.chars.length - 1);
    if (oldIndex == to) return;
    PythonService.addAppLog(
      '[改序] 行=${line.id} 字序 $oldIndex → $to（${line.chars.length} 字）',
    );
    setState(() {
      final c = line.chars.removeAt(oldIndex);
      line.chars.insert(to, c);
      for (var i = 0; i < line.chars.length; i++) {
        line.chars[i].order = i;
      }
      line.text = line.chars.map((c) => c.text).join();
      ann.rebuildBlocks();
    });
    _save();
  }

  /// 删除选中的行（含其下所有 char）
  void _deleteSelectedLine() {
    if (_selectedLine == null || _annotation == null) return;
    final target = _selectedLine!;
    setState(() {
      // 与字框删除同口径：实例被级联重建替换后按 id 兜底。
      final line = _annotation!.lines.any((l) => identical(l, target))
          ? target
          : _annotation!.lines.firstWhere(
              (l) => l.id == target.id,
              orElse: () => target,
            );
      _annotation!.lines.remove(line);
      _annotation!.rebuildBlocks();
      _selectedLine = null;
      PythonService.addAppLog(
        '[删除] 行框 ${line.id}（剩余 ${_annotation!.lines.length} 行）',
      );
    });
    _save();
  }

  void _deleteSelected() {
    if (_selected == null || _annotation == null) return;
    _deleteBlockById(_selected!);
  }

  /// 按 id 删除字框（键盘 Delete / 快捷候选浮层的"删除识别框"共用）。
  /// 实例同一性优先；行卡片/级联重建可能替换过实例（调用方持有旧实例
  /// 已不在树里，remove 会静默无效），按 id 兜底定位在树实例。
  void _deleteBlockById(CharBlock target) {
    final ann = _annotation;
    if (ann == null) return;
    setState(() {
      final block = ann.blocks.any((b) => identical(b, target))
          ? target
          : ann.blocks.firstWhere(
              (b) => b.id == target.id,
              orElse: () => target,
            );
      var removedBlocks = ann.blocks.remove(block) ? 1 : 0;
      var removedInLines = 0;
      for (final line in ann.lines) {
        if (line.chars.remove(block)) {
          removedInLines++;
        } else {
          line.chars.removeWhere((c) => c.id == target.id);
        }
        line.text = line.chars.map((c) => c.text).join();
      }
      if (identical(_selected, target) || _selected?.id == target.id) {
        _selected = null;
      }
      PythonService.addAppLog(
        '[删除] 字框 ${block.id} blocks移除=$removedBlocks 行内移除=$removedInLines'
        '（剩余 ${ann.blocks.length} 字）',
      );
    });
    _save();
  }

  void _updateType(String type) {
    if (_selected == null) return;
    final updated = _selected!.copyWith(
      type: type,
      status: type == 'ignore' ? 'rejected' : _selected!.status,
      confirmed: type == 'ignore' ? false : _selected!.confirmed,
    );
    _updateBlock(_selected!, updated);
  }

  void _addBlock(CharBlock b) {
    // find containing line by center point, else create new
    LineBlock? host;
    final center = Offset(b.x + b.w / 2, b.y + b.h / 2);
    for (final line in _annotation!.lines) {
      final r = Rect.fromLTWH(
        line.x.toDouble(),
        line.y.toDouble(),
        line.w.toDouble(),
        line.h.toDouble(),
      );
      if (r.contains(center)) {
        host = line;
        break;
      }
    }
    setState(() {
      if (host != null) {
        b.lineId = host.id;
        _insertCharInReadingOrder(host, b);
      } else {
        final newLine = LineBlock(
          id: 'manual_${DateTime.now().millisecondsSinceEpoch}',
          x: b.x,
          y: b.y,
          w: b.w,
          h: b.h,
          lineNo: _annotation!.lines.length,
          orientation: _pageOrientation,
          chars: [b],
        );
        b.lineId = newLine.id;
        _annotation!.lines.add(newLine);
      }
      _annotation!.blocks.add(b);
    });
    _save();
    _recognizeNewChar(b);
  }

  /// 把新画的字框按几何阅读序插入行内：竖排按中心 Y（上→下）、横排按
  /// 中心 X（ltr 左→右 / rtl 右→左），插入后重排 order 与行文字。此前
  /// 一律追加到行尾——单字模式列2（几何对位）显示正常，但列3（按行内
  /// 顺序排列的字轨）会把新字排到行末而不是它的实际位置。
  void _insertCharInReadingOrder(LineBlock line, CharBlock newChar) {
    final horizontal = line.orientation == 'horizontal';
    // 阅读方向取本页生效设置（按页覆盖优先于整书）：整书列序 rtl 的
    // 竖排书里按页覆盖成横排 ltr 的页，若按整书 rtl 判读，行尾（右侧）
    // 新画的字会被当成"排在所有字之前"而插到行首——横排模式下新字
    // 全跑到前面的根因。
    final rtl = horizontal && _pageSettings.horizontalDir == 'rtl';
    double axisOf(CharBlock c) => horizontal ? c.x + c.w / 2 : c.y + c.h / 2;
    final index = readingOrderInsertIndex(
      [for (final c in line.chars) axisOf(c)],
      axisOf(newChar),
      rtl: rtl,
    );
    line.chars.insert(index, newChar);
    for (var i = 0; i < line.chars.length; i++) {
      line.chars[i].order = i;
    }
    line.text = line.chars.map((c) => c.text).join();
  }

  /// 新画的单字框立即用 Kraken 识别填字并挂候选，而不是默认显示"?"。
  void _recognizeNewChar(CharBlock b) {
    _queueCharCascade(b, preserveUserText: true);
  }

  // ── 队列入口：所有重识别触发点都走这里，编辑操作不因识别被阻塞 ──

  void _queueRegionCascade(MainRegion region) {
    _enqueueCascade(
      'region:${region.id}',
      '主区重识别（段/行/字）',
      (isStale) => _rerecognizeRegion(region, isStale: isStale),
    );
  }

  void _queueParagraphCascade(Paragraph paragraph) {
    _enqueueCascade(
      'para:${paragraph.id}',
      '段重识别（行/字）',
      (isStale) => _rerecognizeParagraph(paragraph, isStale: isStale),
    );
  }

  Future<void> _queueLineCascade(LineBlock line) async {
    _enqueueCascade(
      'line:${line.id}',
      '行重识别（字）',
      (isStale) => _rerecognizeLineChars(line, isStale: isStale),
      lineId: line.id,
      lineAction: 'rerecognize',
    );
  }

  /// 重新切割本列入队（与行重识别同队列：连点多行时顺序执行、后端
  /// 忙碌自动重试、排队数在胶囊可见；同键替换让"重识别→改切"只保留
  /// 最新意图）。[expand] 覆盖外扩判定：行框缩放手势触发的重拆传
  /// false——手势给出的新框就是识别范围的权威意图，不再外扩。
  Future<void> _queueResplitLine(LineBlock line, {bool? expand}) async {
    _enqueueCascade(
      'line:${line.id}',
      '重新切割本列（拆字+识别）',
      (isStale) => _resplitLineChars(line, isStale: isStale, expand: expand),
      lineId: line.id,
      lineAction: 'resplit',
    );
  }

  // ── 全页级批量重识别（字视图右栏入口，逐行走既有级联队列）──

  /// 批量入口可用性：队列空闲才接受（重复点击会把每行入队两遍——
  /// 同键只替换"还没开始跑"的那份，已经开始的会全部各跑一次）。
  bool get _pageBatchBusy =>
      _cascadeQueue.isNotEmpty || _cascadeActive != null;

  /// 全页重新切割：每行推倒重拆字框+识别（与单行「重新切割本列」同
  /// 链路）。用户成果行（手工行框/字框已全部确认，区域级联同款
  /// isUserPinnedLine 口径）跳过——整页批量不能悄悄洗掉校对成果。
  Future<void> _resplitAllLines() async {
    final ann = _annotation;
    if (ann == null || ann.lines.isEmpty || _pageBatchBusy) return;
    if (_boxReviewing) {
      _snack('AI 检查识别框进行中，请稍后再批量重切');
      return;
    }
    final targets = ann.lines
        .where((l) => !BookRegionApply.isUserPinnedLine(l))
        .toList();
    final skipped = ann.lines.length - targets.length;
    if (targets.isEmpty) {
      _snack('本页全是用户成果行（手工框/已确认），没有可重切的行');
      return;
    }
    final goAhead = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('全页重新切割'),
        content: Text(
          '将对本页 ${targets.length} 行推倒重拆字框并重新识别'
          '${skipped > 0 ? '（跳过 $skipped 行用户成果行：手工框/已确认行）' : ''}。\n'
          '行内现有字框与文字会被替换，共享列带的小字注分段不会外扩。\n'
          '任务在后台队列逐行执行，期间可继续编辑。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('开始重切'),
          ),
        ],
      ),
    );
    if (goAhead != true || !mounted) return;
    for (final line in targets) {
      await _queueResplitLine(line);
    }
    _snack(
      '全页重新切割已入队：${targets.length} 行'
      '${skipped > 0 ? '（跳过 $skipped 行用户成果行）' : ''}',
    );
  }

  /// 全页重新识别单字：每行保留字框几何、只重读框内文字（与单行
  /// 「重新识别本行单字」同链路）。没有字框的行跳过。
  Future<void> _rerecognizeAllLineChars() async {
    final ann = _annotation;
    if (ann == null || _pageBatchBusy) return;
    if (_boxReviewing) {
      _snack('AI 检查识别框进行中，请稍后再批量重读');
      return;
    }
    final targets = ann.lines.where((l) => l.chars.isNotEmpty).toList();
    if (targets.isEmpty) {
      _snack('本页没有带字框的行');
      return;
    }
    for (final line in targets) {
      await _queueLineCascade(line);
    }
    _snack('全页重新识别单字已入队：${targets.length} 行');
  }

  void _queueCharCascade(CharBlock c, {required bool preserveUserText}) {
    _enqueueCascade(
      'char:${c.id}',
      '单字识别',
      (isStale) => _recognizeCharBlock(
        c,
        preserveUserText: preserveUserText,
        isStale: isStale,
      ),
      // 静默：不弹顶部横幅（秒级任务 + 属性面板已有"识别中…"指示，
      // 横幅插入/收起会让整个界面跳动）。
      silent: true,
    );
  }

  Future<void> _queueNewLineCascade(LineBlock stub) async {
    _enqueueCascade(
      'line:${stub.id}',
      '新行拆字识别',
      (isStale) => _processNewLine(stub, isStale: isStale),
      lineId: stub.id,
    );
  }

  /// 单字框识别：Kraken 框内读法为正文，char_cls 候选追加在其后。
  ///
  /// [preserveUserText] 为 true（新画框）时，识别期间用户已手动输入过
  /// 文字则不覆盖；为 false（调整框几何后的重识别）时框内内容已变，
  /// 直接采用新读法，旧文字若不同则进候选，可一键改回。
  /// 识别期间用户可能删除该框或翻页，返回后按 id 重新定位再更新。
  Future<void> _recognizeCharBlock(
    CharBlock b, {
    required bool preserveUserText,
    bool Function() isStale = _neverStale,
  }) async {
    final oldText = b.text.trim();
    setState(() => _recognizingChars.add(b.id));
    Map<String, dynamic>? result;
    try {
      result = await PythonService.recognizeChar(
        imagePath: _imagePath,
        x: b.x,
        y: b.y,
        w: b.w,
        h: b.h,
        orientation: _pageOrientation,
        horizontalDir: _pageSettings.horizontalDir,
        engine: widget.project.settings.engine,
        paddleModel: widget.project.settings.paddleModel,
      );
    } catch (e) {
      // 识别失败：新框保持"?"，调整过的框保留旧文字。用户主动触发
      // 的操作失败要可见（忙碌/服务异常各有提示），不能静默。
      if (mounted) {
        _snack('单字识别失败：$e', error: true);
      }
      return;
    } finally {
      if (mounted) {
        setState(() => _recognizingChars.remove(b.id));
      }
    }
    if (!mounted) return;
    if (isStale()) return; // 该框已重新入队：本次读法作废
    final ann = _annotation;
    if (ann == null) return;
    CharBlock? current;
    outer:
    for (final line in ann.lines) {
      for (final c in line.chars) {
        if (c.id == b.id) {
          current = c;
          break outer;
        }
      }
    }
    if (current == null) return; // 框已被删除
    if (preserveUserText &&
        current.text.trim().isNotEmpty &&
        current.text.trim() != oldText) {
      return; // 用户已手动改字，机器读法不再覆盖
    }
    final text = (result['text']?.toString() ?? '').trim();
    if (text.runes.length != 1) return; // 读不出（空/多字）保持现状
    final rawCandidates = (result['candidates'] as List?) ?? const [];
    final candidates = <CharCandidate>[
      for (final item in rawCandidates)
        if (item is Map && (item['text']?.toString() ?? '').trim().isNotEmpty)
          CharCandidate(
            text: item['text'].toString(),
            score: (item['score'] as num?)?.toDouble() ?? 0,
          ),
    ];
    if (oldText.isNotEmpty &&
        oldText != text &&
        oldText.runes.length == 1 &&
        !candidates.any((c) => c.text == oldText)) {
      candidates.add(CharCandidate(text: oldText, score: 1.0));
    }
    // 单字重识别的读法是新的机器基线：origText 同步重置（此后再人工
    // 改字才算"识别后被修改"；新画字框首次识别同样由此获得基线）。
    _updateBlock(
      current,
      current.copyWith(text: text, candidates: candidates, origText: text),
    );
    // 识别落字后自动墨迹校验（异步、失败静默）：识别写回即时完成，
    // 校验结果稍后补上——新识别的字自动带校验结论，mismatch 的字在
    // 画布/行卡片上标红并转待复核。
    unawaited(_autoVerifyBlock(b.id, text));
  }

  CharBlock? _findBlockById(String blockId) {
    final ann = _annotation;
    if (ann == null) return null;
    for (final block in ann.blocks) {
      if (block.id == blockId) return block;
    }
    return null;
  }

  /// 单字识别后的自动墨迹校验：/verify_char 比对识别文字的楷体字形
  /// 骨架与墨迹骨架。校验期间用户可能已改字，写回前按 id 重取最新实
  /// 例并确认文字未变；任何失败静默（增强信号，不打扰识别主流程）。
  Future<void> _autoVerifyBlock(String blockId, String text) async {
    if (text.runes.length != 1) return;
    try {
      final block = _findBlockById(blockId);
      if (block == null || block.text != text) return;
      final outcome = await PythonService.verifyChar(
        imagePath: _imagePath,
        block: block,
      );
      if (!mounted) return;
      final latest = _findBlockById(blockId);
      if (latest == null || latest.text != text) return;
      var updated = latest.copyWith(
        verifyLevel: outcome.level,
        verifyScore: outcome.score,
      );
      if (outcome.level == 'mismatch' &&
          latest.status == AnnotationStatus.proposed) {
        updated = updated.copyWith(status: AnnotationStatus.needsReview);
      }
      _updateBlock(latest, updated);
    } catch (_) {
      // 自动校验失败静默：需要结果时可用「校验本页」或属性面板重试。
    }
  }

  /// 属性面板「墨迹对照」：叠加图（墨迹骨架蓝/识别字楷体字形骨架红/
  /// 重叠绿）+ 拓扑差异明细 + 重新校验。对话框组件与调试页共用
  /// （widgets/char_verify_common.dart），重校验结果通过回调写回
  /// （与批量校验同规则）。
  void _showVerifyDialog() {
    final block = _selected;
    if (block == null) return;
    showDialog(
      context: context,
      builder: (_) => CharVerifyDialog(
        imagePath: _imagePath,
        block: block,
        onApplyResult: (level, score) {
          final latest = _findBlockById(block.id);
          if (latest == null) return;
          var updated = latest.copyWith(verifyLevel: level, verifyScore: score);
          if (level == 'mismatch' &&
              latest.status == AnnotationStatus.proposed) {
            updated = updated.copyWith(status: AnnotationStatus.needsReview);
          }
          _updateBlock(latest, updated);
        },
      ),
    );
  }

  /// 打开「全书总览」网格页：返回被点击的页索引，直接翻到该页。
  /// 网格页只读标注，不动任何数据；跳页走常规 _switchPage（含当前页
  /// 临时保存落盘）。
  Future<void> _openBookGrid() async {
    final index = await Navigator.of(context).push<int>(
      MaterialPageRoute(
        builder: (_) =>
            BookGridPage(project: widget.project, currentPageIndex: _pageIndex),
      ),
    );
    if (!mounted || index == null) return;
    await _switchPage(index);
  }

  /// 打开「全书叠加」页：批量调整正文区并应用到全书/页范围。叠加页
  /// 直接读写各页标注文件，进页前先把当前页未落盘的修改临时保存
  /// （否则批量应用会基于旧数据、回来后内存旧态还会盖掉新写入）。
  /// 应用返回 true 时当前内存态已过期，需重扫状态标记并重载当前页。
  Future<void> _openBookOverlay() async {
    _cancelPendingSave();
    if (_annotation != null) {
      await _flushSave();
      _dirty = false;
    }
    if (!mounted) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => BookOverlayPage(project: widget.project),
      ),
    );
    if (!mounted || changed != true) return;
    await _loadPageStateMarkers();
    await _loadPage();
  }

  /// 打开「主区快设」网格页：逐页快速框正文区（只保存主区几何，不触发
  /// 识别），全部改完后在网格页一键按主区批量拆分行/字/段。进页前先把
  /// 当前页未落盘的修改临时保存（快设页直接读写各页标注文件）；返回
  /// true 时有页面数据被改写，需重扫状态标记并重载当前页。
  Future<void> _openBookRegionGrid() async {
    _cancelPendingSave();
    if (_annotation != null) {
      await _flushSave();
      _dirty = false;
    }
    if (!mounted) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => BookRegionGridPage(project: widget.project),
      ),
    );
    if (!mounted || changed != true) return;
    await _loadPageStateMarkers();
    await _loadPage();
  }

  /// 打开「跨页拆分」页：把左右两页合扫的跨页图按全书叠加图上选定的
  /// 中缝拆成两个书页。进页前先把当前页未落盘的修改临时保存（拆分要
  /// 读各页标注）；返回 true 时全书页面列表已重建（恢复拆分前会变少，
  /// 当前页下标可能越界），先夹回范围再重扫状态标记并重载当前页。
  Future<void> _openBookSplit() async {
    _cancelPendingSave();
    if (_annotation != null) {
      await _flushSave();
      _dirty = false;
    }
    if (!mounted) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => BookSplitPage(project: widget.project)),
    );
    if (!mounted || changed != true) return;
    if (widget.project.imageFiles.isEmpty) {
      // 理论不可达（拆分/恢复都保留至少一页），防御性兜底。
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _imageRevision++;
      _pageIndex = _pageIndex.clamp(0, widget.project.imageFiles.length - 1);
    });
    await _loadPageStateMarkers();
    await _loadPage();
  }

  /// 打开「校对摆正」页（仿白描）：8 个可拖拽裁切点 + 透视/弯边拉平 +
  /// 去色/锐化。结果写入 warped/ 新文件并替换当前页（sources 原图保留，
  /// 已是 warped 输出时原地覆盖）。透视拉平后旧标注无法可靠投影：确认
  /// 后清空本页标注并提示重新识别。
  Future<void> _openStraighten() async {
    _cancelPendingSave();
    final project = widget.project;
    final index = _pageIndex;
    final currentPath = project.imageFiles[index];
    final annDir = p.join(project.projectDir, 'annotations');
    final pageId = pageIdForImage(currentPath, index);
    final hadAnnotation = await File(p.join(annDir, '$pageId.json')).exists();
    if (!mounted) return;

    if (hadAnnotation) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('校对摆正该页？'),
          content: const Text(
            '该页已有识别结果：透视拉平后字框坐标会失真，摆正后将清空本页'
            '标注，需要在完成后重新识别该页。\n原始图片会保留，摆正结果'
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
    // 摆正页确认后返回实际应用的 PageQuad（取消返回 null）。
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

    // ① 清掉本页标注：拉平后几何已失真，靠重新识别重建。
    for (final suffix in ['.json', '.json.bak']) {
      final f = File(p.join(annDir, pageId + suffix));
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {
        // 清理失败不阻断换页；旧标注随后会被重新识别覆盖或成孤儿。
      }
    }
    // ② 换页文件并落盘。
    project.imageFiles[index] = outPath;
    if (hadAnnotation && project.recognizedPages > 0) {
      project.recognizedPages -= 1;
    }
    await ProjectStorage.save(project);
    FileImage(File(currentPath)).evict();
    FileImage(File(outPath)).evict();
    if (mounted) setState(() => _imageRevision++);
    await _loadPageStateMarkers();
    await _loadPage();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(hadAnnotation ? '该页已摆正，原识别结果已清空，请重新识别' : '该页已摆正')),
    );
  }

  /// 打开「墨迹归类」页：本页字块按墨迹形态聚类，统一/单独改字。
  /// 修改通过 _updateBlock 走与单字快改完全相同的通道（重拼行文本、
  /// 防抖保存）；组级确认经 _confirmBlocksFromSimilarChars 即时保存。
  /// 返回值非空表示期间经全书版修改过页（含当前页），重载受影响数据
  /// /执行其中的「定位到所在页」请求。
  Future<void> _openSimilarChars() async {
    final ann = _annotation;
    if (ann == null) return;
    final result = await Navigator.of(context).push<BookClassifyResult>(
      MaterialPageRoute(
        builder: (_) => SimilarCharsPage(
          annotation: ann,
          imagePath: widget.project.imageFiles[_pageIndex],
          pageIndex: _pageIndex,
          onBlockTextUpdated: _updateBlockTextById,
          onBlocksConfirmed: _confirmBlocksFromSimilarChars,
          onBlocksMarkUpdated: _updateBlocksMarkById,
          onLocateChar: _locateCharFromSimilarChars,
          onOpenBook: _openSimilarCharsBook,
        ),
      ),
    );
    await _handleBookClassifyResult(result);
  }

  /// 打开「墨迹归类·全书版」：指定页范围或整本书跨页聚类批量校正。
  /// 进页前先把当前页未落盘的修改临时保存（全书版直接读写各页标注
  /// 文件）；返回被修改的页号集合（含可选的「定位到所在页」请求），
  /// 当前页在集合中时从盘重载。
  Future<BookClassifyResult?> _openSimilarCharsBook() async {
    _cancelPendingSave();
    if (_annotation != null) {
      await _flushSave();
      _dirty = false;
    }
    if (!mounted) return null;
    final result = await Navigator.of(context).push<BookClassifyResult>(
      MaterialPageRoute(
        builder: (_) => SimilarCharsBookPage(
          project: widget.project,
          currentPageIndex: _pageIndex,
        ),
      ),
    );
    await _handleBookClassifyResult(result);
    return result;
  }

  /// 全书版归类返回后的统一处理：刷新全书状态标记与进度；带「定位」
  /// 请求时跳到目标页并选中闪烁该字；否则当前页被修改过时从盘重载
  /// （全书版直接写盘，编辑器内存标注已过期）。
  Future<void> _handleBookClassifyResult(BookClassifyResult? result) async {
    if (!mounted) return;
    await _loadPageStateMarkers();
    unawaited(_refreshBookProgress());
    final modified = result?.modifiedPages;
    final locatePage = result?.locatePage;
    final locateBlockId = result?.locateBlockId;
    if (locatePage != null && locateBlockId != null) {
      final target = locatePage.clamp(0, widget.project.imageFiles.length - 1);
      if (target != _pageIndex) {
        await _switchPage(target);
      } else if (modified != null && modified.contains(_pageIndex)) {
        // 定位目标就是当前页、且全书版改过它：编辑器内存标注已过期，
        // 先从盘重载再定位（字块 id 稳定，重载不影响按 id 找字）。
        await _loadPage();
      }
      if (!mounted) return;
      _focusCharInDetail(locateBlockId);
      return;
    }
    if (modified == null || modified.isEmpty) {
      if (mounted) setState(() {});
      return;
    }
    if (modified.contains(_pageIndex)) {
      await _loadPage();
    } else if (mounted) {
      setState(() {});
    }
  }

  /// 墨迹归类页的组级确认回调：把组内字块置为已确认（与「确认并
  /// 保存」同口径的级联：行→段→正文区，整页全部确认时置 reviewed
  /// 转绿框）并立即落盘。此前的防抖文本编辑随同一次写盘生效。
  Future<void> _confirmBlocksFromSimilarChars(List<String> blockIds) async {
    final ann = _annotation;
    if (ann == null) return;
    _cancelPendingSave();
    final changed = ann.confirmCharsById(blockIds.toSet());
    if (!changed) return;
    final fullyConfirmed = ann.isFullyConfirmed;
    if (!fullyConfirmed) ann.draftSaved = true;
    if (mounted) setState(() => _dirty = false);
    try {
      await ProjectStorage.saveAnnotation(widget.project.projectDir, ann);
    } catch (e) {
      PythonService.addAppLog('[保存诊断] ⚠ 墨迹归类组确认写盘失败：$e', isError: true);
      if (mounted) _snack('确认保存失败：$e（修改仍在内存，可重试）', error: true);
      return;
    }
    if (!mounted) return;
    setState(() {
      if (fullyConfirmed) {
        _markers.savedPages.add(_pageIndex);
        _markers.boxesReviewedPages.remove(_pageIndex);
        _markers.draftPages.remove(_pageIndex);
        _markers.boxedUnconfirmedPages.remove(_pageIndex);
      } else if (!_markers.savedPages.contains(_pageIndex) &&
          !_markers.boxesReviewedPages.contains(_pageIndex)) {
        // 部分确认：框已确认的玫红框页保持玫红框，其余转橘黄待校。
        _markers.draftPages.add(_pageIndex);
        _markers.boxedUnconfirmedPages.remove(_pageIndex);
      }
    });
    unawaited(_refreshBookProgress());
  }

  /// 墨迹归类页的「定位」入口：返回编辑器，切到详细（单字识别）视图，
  /// 选中该字并把所在行卡片滚动到视口上部（行图/字 chip/属性面板
  /// 三处高亮联动），方便结合上下文核对。
  void _locateCharFromSimilarChars(String blockId) {
    Navigator.of(context).pop();
    _focusCharInDetail(blockId);
  }

  /// 在详细（单字识别）视图选中并闪烁指定字块：单页版「定位」与
  /// 全书版「定位到所在页」共用（后者先跳页再调用）。
  void _focusCharInDetail(String blockId) {
    final ann = _annotation;
    if (ann == null) return;
    for (final line in ann.lines) {
      for (final c in line.chars) {
        if (c.id == blockId) {
          setState(() {
            _viewIndex = 0;
            _viewMode = 'char';
            _reorderMode = false;
            _pendingLineOrder.clear();
            _pendingParagraphOrder.clear();
            _selected = c;
            _selectedLine = null;
            _selectedRegion = null;
            _selectedParagraph = null;
            _detailFocusLineId = line.id;
            _detailFocusSeq++;
            _flashCharId = blockId;
          });
          _flashTimer?.cancel();
          _flashTimer = Timer(const Duration(seconds: 10), () {
            if (mounted) setState(() => _flashCharId = null);
          });
          return;
        }
      }
    }
  }

  void _updateBlockTextById(String blockId, String newText) {
    final ann = _annotation;
    if (ann == null) return;
    for (final block in ann.blocks) {
      if (block.id == blockId) {
        if (block.text != newText) {
          _updateBlock(block, block.copyWith(text: newText));
        }
        return;
      }
    }
  }

  /// 详细视图行卡片的手势提交（拖动/缩放字框）：更新后按几何变化触发
  /// 该字框重识别——与主画布 _handleGeometryEditEnd 同口径（与新画框
  /// 的自动识别同体验）。此前详细视图只更新不重识别，改完框要手动
  /// 点「重新识别本行」；_updateBlock 已设 _charGeomDirty，这里直接
  /// 消费掉并按 id 入队，避免下次画布手势结束误触发二次识别。
  void _updateBlockFromLineCard(CharBlock old, CharBlock updated) {
    final geomChanged =
        old.x != updated.x ||
        old.y != updated.y ||
        old.w != updated.w ||
        old.h != updated.h;
    _updateBlock(old, updated);
    if (geomChanged) {
      _charGeomDirty = false;
      _charGeomDirtyId = null;
      _queueCharCascade(updated, preserveUserText: false);
    }
  }

  /// 特殊字标记/取消标记（墨迹归类页回调）：只翻转 marked 标志，
  /// 不触碰文字/几何/确认状态；批量替换实例后走统一的防抖保存。
  void _updateBlocksMarkById(List<String> blockIds, bool marked) {
    final ann = _annotation;
    if (ann == null) return;
    final idSet = blockIds.toSet();
    var changed = false;
    for (var i = 0; i < ann.blocks.length; i++) {
      final b = ann.blocks[i];
      if (!idSet.contains(b.id) || b.marked == marked) continue;
      final updated = b.copyWith(marked: marked);
      ann.blocks[i] = updated;
      for (final line in ann.lines) {
        final idx = line.chars.indexOf(b);
        if (idx >= 0) line.chars[idx] = updated;
      }
      if (_selected == b) _selected = updated;
      changed = true;
    }
    if (changed) {
      setState(() {});
      _save();
    }
  }

  bool _verifyingPage = false;

  /// 「校验本页」：本页全部正文有字块送后端做墨迹重叠校验（识别文字
  /// 的楷体字形骨架 vs 墨迹骨架的拓扑+形状比对），结果写回字块并落
  /// 盘；mismatch 且仍为 proposed 的字自动转待复核（confirmed/rejected
  /// 不动，不覆盖人工结论）。纯 CPU 不占 GPU 识别门；请求失败静默提
  /// 示，不影响既有数据。
  Future<void> _verifyPageChars() async {
    final ann = _annotation;
    if (ann == null || _verifyingPage) return;
    final targets = ann.blocks
        .where((b) => b.type == 'main_text' && b.text.trim().isNotEmpty)
        .toList();
    if (targets.isEmpty) {
      _snack('本页没有可校验的文字');
      return;
    }
    setState(() => _verifyingPage = true);
    try {
      final result = await PythonService.verifyCharsBatch(
        imagePath: _imagePath,
        blocks: targets,
        projectDir: widget.project.projectDir,
      );
      if (!mounted) return;
      var mismatches = 0, suspects = 0, toReview = 0;
      setState(() {
        for (var i = 0; i < ann.blocks.length; i++) {
          final b = ann.blocks[i];
          final r = result.results[b.id];
          if (r == null) continue;
          var updated = b.copyWith(verifyLevel: r.level, verifyScore: r.score);
          if (r.level == 'mismatch') {
            mismatches++;
            if (b.status == AnnotationStatus.proposed) {
              updated = updated.copyWith(status: AnnotationStatus.needsReview);
              toReview++;
            }
          } else if (r.level == 'suspect') {
            suspects++;
          }
          ann.blocks[i] = updated;
          for (final line in ann.lines) {
            final idx = line.chars.indexOf(b);
            if (idx >= 0) line.chars[idx] = updated;
          }
          if (_selected == b) _selected = updated;
        }
      });
      _save();
      final parts = [
        '$mismatches 个不匹配（已标红${toReview > 0 ? '、$toReview 个转待复核' : ''}）',
        if (suspects > 0) '$suspects 个存疑',
      ];
      _snack('墨迹校验完成：${parts.join('，')}');
    } catch (e) {
      _snack('墨迹校验失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _verifyingPage = false);
    }
  }

  DateTime? _blockMissLogAt;
  String? _blockMissLogId;

  // ── AI 检查识别框（两档修复：几何直修免 VLM / 视觉模型诊断）──

  bool _boxReviewing = false;
  int _boxReviewDone = 0;
  int _boxReviewTotal = 0;
  bool _boxReviewCancelRequested = false;

  /// 本次应用生命周期内被 AI 修复过的行（卡片徽章用，不落盘）。
  final Set<String> _aiAdjustedLineIds = {};

  /// 版面分析自动修复前的整页快照；检查报告可一次恢复。
  List<LineBlock>? _layoutUndoSnapshot;
  List<Paragraph>? _layoutUndoParagraphSnapshot;
  List<MainRegion>? _layoutUndoRegionSnapshot;

  /// 单次扫描里视觉模型诊断的行数上限（每次 2~10 秒，防整页几十行时
  /// 检查失控；超出的行在报告里列为跳过）。
  static const int _kBoxReviewVlmCap = 12;

  /// 顶栏「AI 检查识别框」：扫全页可疑行 → 两档修复 → 置信度裁决 →
  /// 报告（可整体撤销）。与整本识别队列互斥。
  Future<void> _runBoxReviewPage() async {
    final ann = _annotation;
    if (ann == null || _loading || _boxReviewing) return;
    if (RecognitionQueue.instance.isRunning) {
      _snack('整本识别进行中，暂不能执行 AI 检查识别框');
      return;
    }
    final ollama = await OllamaSettings.load();
    if (!ollama.enableBoxAssist) {
      _snack('「识别框检查」未开启：请在 AI 辅助设置（机器人图标）中打开', error: true);
      return;
    }
    final ollamaReady = ollama.activeVisionModel.isNotEmpty;
    var layoutChanged = false;
    final layoutLinesNeedingRecognition = <LineBlock>[];
    // 先跑 CPU 版面分析：它比 VLM 更适合判空、收紧/扩展边界和去重。
    // 只对未保护行应用高可信建议，保留整页快照供报告一键撤销。
    try {
      final analysis = await PythonService.analyzeLayout(
        imagePath: _imagePath,
        settings: _pageSettings,
        lines: [
          for (final l in ann.lines)
            if (!isProtectedLine(l)) l,
        ],
      );
      final proposals = analysis.repairs
          .where((p) => p.confidence >= 0.80)
          .toList();
      if (proposals.isNotEmpty && ollama.autoApplyBoxRepairs) {
        _layoutUndoSnapshot = [
          for (final l in ann.lines) LineBlock.fromJson(l.toJson()),
        ];
        _layoutUndoParagraphSnapshot = [
          for (final p in ann.paragraphs) Paragraph.fromJson(p.toJson()),
        ];
        _layoutUndoRegionSnapshot = [
          for (final r in ann.mainRegions) MainRegion.fromJson(r.toJson()),
        ];
        var changed = false;
        setState(() {
          for (final proposal in proposals) {
            final line = ann.lines.cast<LineBlock?>().firstWhere(
              (l) => l?.id == proposal.targetId,
              orElse: () => null,
            );
            if (line == null || isProtectedLine(line)) continue;
            if (proposal.action == 'remove_blank') {
              ann.lines.remove(line);
              for (final paragraph in ann.paragraphs) {
                paragraph.lineIds.remove(line.id);
              }
              _aiAdjustedLineIds.remove(line.id);
              changed = true;
              continue;
            }
            // The CPU layout pass can identify a coincident/near-coincident
            // detector result even when it is not an empty line.  Treat this
            // as a structural delete, just like remove_blank.  Previously
            // `dedupe` was reported by /analyze_layout but silently ignored,
            // leaving the extra narrow column in the editor and allowing a
            // later double-column split to preserve it.
            if (proposal.action == 'dedupe') {
              ann.lines.remove(line);
              for (final paragraph in ann.paragraphs) {
                paragraph.lineIds.remove(line.id);
              }
              _aiAdjustedLineIds.remove(line.id);
              changed = true;
              continue;
            }
            if ((proposal.action == 'tighten' || proposal.action == 'expand') &&
                proposal.rects.isNotEmpty &&
                proposal.rects.first.length >= 4) {
              final r = proposal.rects.first;
              if (line.x != r[0] ||
                  line.y != r[1] ||
                  line.w != r[2] ||
                  line.h != r[3]) {
                line.x = r[0];
                line.y = r[1];
                line.w = r[2];
                line.h = r[3];
                line.manual = false;
                _aiAdjustedLineIds.add(line.id);
                changed = true;
              }
            }
            if (proposal.action == 'split_double_column' &&
                proposal.rects.length > 1) {
              final at = ann.lines.indexOf(line);
              if (at >= 0) {
                ann.lines.removeAt(at);
                final childRects = [
                  for (final raw in proposal.rects)
                    if (raw.length >= 4)
                      Rect.fromLTWH(
                        raw[0].toDouble(),
                        raw[1].toDouble(),
                        raw[2].toDouble(),
                        raw[3].toDouble(),
                      ),
                ];
                final assigned = <List<CharBlock>>[
                  for (var i = 0; i < childRects.length; i++) <CharBlock>[],
                ];
                // A character can straddle the split gap. Prefer the child
                // with the greatest overlap, falling back to the nearest
                // centre so no existing OCR box is silently discarded.
                for (final char in line.chars) {
                  final charRect = Rect.fromLTWH(
                    char.x.toDouble(),
                    char.y.toDouble(),
                    char.w.toDouble(),
                    char.h.toDouble(),
                  );
                  var best = -1;
                  var bestArea = 0.0;
                  var bestDistance = double.infinity;
                  for (var i = 0; i < childRects.length; i++) {
                    final childRect = childRects[i];
                    final intersection = charRect.intersect(childRect);
                    final area =
                        intersection.width > 0 && intersection.height > 0
                        ? intersection.width * intersection.height
                        : 0.0;
                    final dx = charRect.center.dx - childRect.center.dx;
                    final dy = charRect.center.dy - childRect.center.dy;
                    final distance = dx * dx + dy * dy;
                    if (area > bestArea ||
                        (area == bestArea && distance < bestDistance)) {
                      best = i;
                      bestArea = area;
                      bestDistance = distance;
                    }
                  }
                  if (best >= 0) assigned[best].add(char);
                }
                final children = <LineBlock>[];
                for (var i = 0; i < childRects.length; i++) {
                  final chars = assigned[i];
                  final rect = childRects[i];
                  final child = LineBlock(
                    id: '${line.id}_dc$i',
                    x: rect.left.round(),
                    y: rect.top.round(),
                    w: rect.width.round(),
                    h: rect.height.round(),
                    lineNo: line.lineNo + children.length,
                    orientation: line.orientation,
                    text: '',
                    chars: chars,
                    readingOrder: line.readingOrder < 0
                        ? line.readingOrder
                        : line.readingOrder + children.length,
                    paragraphId: line.paragraphId,
                    status: line.status,
                    boxConfirmed: line.boxConfirmed,
                    manual: false,
                    layoutRole: i == 0 || i == childRects.length - 1
                        ? 'body'
                        : 'annotation',
                    columnGroup: 'dc_${line.id}',
                    parentLineId: line.id,
                    layoutConfidence: proposal.confidence,
                    regionLabel: line.regionLabel,
                  );
                  chars.sort(
                    (a, b) => _charAxis(
                      a,
                      line.orientation,
                    ).compareTo(_charAxis(b, line.orientation)),
                  );
                  for (var j = 0; j < chars.length; j++) {
                    chars[j]
                      ..lineId = child.id
                      ..col = at + children.length
                      ..order = j;
                  }
                  child.text = chars.map((c) => c.text).join();
                  children.add(child);
                  if (child.chars.isEmpty) {
                    layoutLinesNeedingRecognition.add(child);
                  }
                  _aiAdjustedLineIds.add(child.id);
                }
                // Keep paragraph membership coherent when the parent line is
                // replaced by its concrete body/annotation children.
                for (final paragraph in ann.paragraphs) {
                  final index = paragraph.lineIds.indexOf(line.id);
                  if (index < 0) continue;
                  paragraph.lineIds
                    ..removeAt(index)
                    ..insertAll(index, [
                      for (final child in children) child.id,
                    ]);
                }
                ann.lines.insertAll(at, children);
                for (var i = 0; i < ann.lines.length; i++) {
                  ann.lines[i].lineNo = i;
                  for (var j = 0; j < ann.lines[i].chars.length; j++) {
                    ann.lines[i].chars[j]
                      ..col = i
                      ..order = j
                      ..lineId = ann.lines[i].id;
                  }
                }
                changed = children.isNotEmpty;
              }
            }
          }
          if (changed) {
            ann.ensureHierarchyContainment();
            ann.rebuildBlocks();
          }
        });
        if (changed) {
          layoutChanged = true;
          for (final child in layoutLinesNeedingRecognition) {
            unawaited(_queueLineCascade(child));
          }
          PythonService.addAppLog(
            '[AI框检查] 版面自动修复 ${proposals.length} 条建议，'
            '空框/边界/去重已应用；双排结构交由行级重识别确认',
          );
        }
      }
    } catch (e) {
      PythonService.addAppLog('[AI框检查] 版面分析失败，退回原扫描：$e');
    }
    // 扫描前批量测量墨迹（/line_ink 一次调用）：空框（框内无文字墨迹
    // 的幽灵行）只有这个信号能可靠判出——几何规则会被"读到的噪声字"
    // 骗过，视觉模型对空白条的判断不可靠。测量失败的行退回纯几何扫描。
    final inkByLineId = <String, LineInkResult>{};
    final inkTargets = [
      for (final l in ann.lines)
        if (!isProtectedLine(l)) l,
    ];
    if (inkTargets.isNotEmpty) {
      try {
        final inks = await PythonService.measureLineInk(
          items: [
            for (final l in inkTargets)
              LineThumbRequest(
                imagePath: _imagePath,
                x: l.x,
                y: l.y,
                w: l.w,
                h: l.h,
                orientation: l.orientation,
                boxes: [for (final c in l.chars) (c.x, c.y, c.w, c.h)],
              ),
          ],
        );
        for (var i = 0; i < inkTargets.length && i < inks.length; i++) {
          final r = inks[i];
          if (r != null) inkByLineId[inkTargets[i].id] = r;
        }
      } catch (e) {
        PythonService.addAppLog('[AI框检查] 行墨迹测量失败（退回纯几何扫描）：$e');
      }
    }
    final suspects = scanSuspects(ann, inkByLineId: inkByLineId);
    if (suspects.isEmpty) {
      if (layoutChanged) {
        await _save();
        if (mounted) {
          await _showBoxReviewReport(const [], const [], 0);
        }
      } else {
        _snack('未发现可疑识别框');
      }
      return;
    }
    final geometryCount = suspects
        .where((s) => s.tier == BoxSuspectTier.geometry)
        .length;
    final semanticCount = suspects.length - geometryCount;
    final semanticRun = ollamaReady ? min(semanticCount, _kBoxReviewVlmCap) : 0;
    final skipped = suspects.length - geometryCount - semanticRun;
    if (!mounted) return;
    // 框检查按设置自动执行：扫描完成后直接按固定阈值应用几何修复，
    // 视觉诊断只处理语义档，最终报告提供整体撤销。
    final toRun = <BoxSuspect>[
      ...suspects.where((s) => s.tier == BoxSuspectTier.geometry),
      ...suspects
          .where((s) => s.tier == BoxSuspectTier.semantic)
          .take(_kBoxReviewVlmCap),
    ];
    setState(() {
      _boxReviewing = true;
      _boxReviewDone = 0;
      _boxReviewTotal = toRun.length;
      _boxReviewCancelRequested = false;
    });
    final reviewer = _buildBoxReviewer(ollama, ollamaReady);
    final results = <LineReviewResult>[];
    final applied = <LineReviewResult>[];
    for (final s in toRun) {
      if (_boxReviewCancelRequested) break;
      // 检查期间用户可能改页/改行；行已不在当前页（或已被上一条重叠
      // 修复替换）就记一条 stale，不再静默消失。伴生行（重叠/重复对象）
      // 被先行删除时同样 stale——例如空框删除先落地，与它重叠的行的
      // 修复就没了对象（重叠已随之解决）。
      if (ann != _annotation || !ann.lines.contains(s.line)) {
        results.add(
          LineReviewResult(
            status: BoxReviewStatus.stale,
            reason: '检查期间该行已被更新，跳过',
            oldLine: s.line,
          ),
        );
        continue;
      }
      final partner = s.overlapPartner ?? s.duplicatePartner;
      if (partner != null && !ann.lines.contains(partner)) {
        results.add(
          LineReviewResult(
            status: BoxReviewStatus.stale,
            reason: '检查期间重叠/重复的对方行已被处理，跳过',
            oldLine: s.line,
          ),
        );
        continue;
      }
      setState(() => _boxReviewDone++);
      final r = await reviewer.reviewLine(s, imagePath: _imagePath);
      if (!mounted || ann != _annotation) break;
      results.add(r);
      if (r.status == BoxReviewStatus.fixed && _applyBoxReviewResult(s, r)) {
        applied.add(r);
      }
    }
    if (mounted) {
      setState(() => _boxReviewing = false);
    }
    PythonService.addAppLog(
      '[AI框检查] 可疑 ${suspects.length} 行：修复 ${applied.length}，'
      '其余 ${results.length - applied.length} 行保持/无问题/失败'
      '${_boxReviewCancelRequested ? '（用户取消）' : ''}',
    );
    await _save();
    if (mounted) {
      _showBoxReviewReport(results, applied, skipped);
    }
  }

  /// 行卡片「AI 检查本行」：显式指定一行走视觉模型诊断（不经可疑扫描，
  /// 用户点名的行即便扫描不报也可查）。
  Future<void> _runBoxReviewSingleLine(LineBlock line) async {
    if (_boxReviewing || _loading) return;
    final ann = _annotation;
    if (ann == null || !ann.lines.contains(line)) return;
    if (RecognitionQueue.instance.isRunning) {
      _snack('整本识别进行中，暂不能执行 AI 检查识别框');
      return;
    }
    final ollama = await OllamaSettings.load();
    if (!ollama.enableBoxAssist) {
      _snack('「识别框检查」未开启：请在 AI 辅助设置（机器人图标）中打开', error: true);
      return;
    }
    if (ollama.activeVisionModel.isEmpty) {
      _snack('AI 诊断需要视觉模型：请在「AI 辅助设置」中拉取并选择', error: true);
      return;
    }
    if (isProtectedLine(line)) {
      if (!mounted) return;
      final goAhead = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('该行已人工校对'),
          content: const Text(
            '这行是手工调过框或已确认文字的行。AI 重摆会重置行内确认状态，'
            '确定要检查吗？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('继续检查'),
            ),
          ],
        ),
      );
      if (goAhead != true || !mounted) return;
    }
    _beginDirectLineProcessing(line.id, 'ai-check');
    try {
      // 墨迹预检：用户点名的行若是空框（框内无文字墨迹），直接走删除动作
      // ——视觉模型对空白条的判断不可靠（实测会说"没问题"）。
      LineInkResult? ink;
      try {
        final inks = await PythonService.measureLineInk(
          items: [
            LineThumbRequest(
              imagePath: _imagePath,
              x: line.x,
              y: line.y,
              w: line.w,
              h: line.h,
              orientation: line.orientation,
              boxes: [for (final c in line.chars) (c.x, c.y, c.w, c.h)],
            ),
          ],
        );
        ink = inks.isEmpty ? null : inks.first;
      } catch (_) {
        ink = null;
      }
      if (!mounted || ann != _annotation) return;
      final blank = ink != null && ink.charInkMedian < kBlankLineInk;
      final reviewer = _buildBoxReviewer(ollama, true);
      final suspect = BoxSuspect(
        line: line,
        tier: BoxSuspectTier.semantic,
        reasons: const ['手动指定'],
        blankInk: blank,
      );
      final r = await reviewer.reviewLine(suspect, imagePath: _imagePath);
      if (!mounted || ann != _annotation) return;
      if (r.status == BoxReviewStatus.fixed) {
        if (_applyBoxReviewResult(suspect, r)) {
          await _save();
          _snack(
            blank
                ? 'AI 检查完成：${r.reason}'
                : 'AI 检查完成：已重摆并通过裁决'
                  '（${r.beforeScore.toStringAsFixed(2)} → ${r.afterScore.toStringAsFixed(2)}）',
          );
          return;
        }
      }
      _snack('AI 检查本行：${r.reason}');
    } finally {
      _endDirectLineProcessing(line.id);
    }
  }

  AiBoxReviewer _buildBoxReviewer(OllamaSettings ollama, bool ollamaReady) {
    return AiBoxReviewer(
      fetchThumbnails: (items) =>
          PythonService.fetchLineThumbnails(items: items, maxSide: 768),
      resegment: (stub, {expectedCharCount}) =>
          _resegmentWithRetry(stub, expectedCharCount: expectedCharCount),
      diagnose: ollamaReady
          ? (imageBase64, line) => OllamaService.diagnoseLineBox(
              settings: ollama,
              imageBase64: imageBase64,
              chars: diagnosisCharsOf(line),
              horizontal: line.orientation == 'horizontal',
              horizontalDir: _pageSettings.horizontalDir,
              verticalDir: _pageSettings.verticalDir,
            )
          : null,
    );
  }

  /// 行级重摆（带 409 忙等重试，与级联队列同策略）。
  Future<List<LineBlock>> _resegmentWithRetry(
    LineBlock stub, {
    int? expectedCharCount,
  }) async {
    var busyWaits = 0;
    while (true) {
      try {
        return await PythonService.segmentRegion(
          imagePath: _imagePath,
          lineStub: stub,
          settings: _pageSettings,
          expectedCharCount: expectedCharCount,
        );
      } catch (e) {
        if (e is RecognitionBusyException ||
            (e is Exception && e.toString().contains('409'))) {
          busyWaits++;
          if (busyWaits >= 10) rethrow;
          await Future<void>.delayed(const Duration(seconds: 2));
          continue;
        }
        rethrow;
      }
    }
  }

  /// 把通过裁决的重摆结果合回标注（与行重识别同一条合回路径：原位替换
  /// + 字 reid + 保留段落归属/阅读序；重叠行的伴生行一并被替换）。
  /// 返回是否真正应用。
  bool _applyBoxReviewResult(BoxSuspect suspect, LineReviewResult r) {
    final ann = _annotation;
    if (ann == null) return false;
    final line = r.oldLine;
    // 重叠伴生行（并集重跑替换）或重复伴生行（删除动作）都要一并移除。
    final partner = suspect.overlapPartner ?? suspect.duplicatePartner;
    final removeIds = <String>{line.id, if (partner != null) partner.id};
    var insertAt = -1;
    for (var i = 0; i < ann.lines.length; i++) {
      if (removeIds.contains(ann.lines[i].id)) {
        insertAt = i;
        break;
      }
    }
    if (insertAt < 0) return false;
    setState(() {
      ann.lines.removeWhere((l) => removeIds.contains(l.id));
      final stamp = DateTime.now().microsecondsSinceEpoch;
      for (var k = 0; k < r.newLines.length; k++) {
        final fresh = r.newLines[k];
        for (var j = 0; j < fresh.chars.length; j++) {
          final c = fresh.chars[j];
          c.id = 'c_${stamp}_${k}_$j';
          c.col = insertAt + k;
          c.order = j;
          c.lineId = fresh.id;
        }
        fresh.paragraphId = line.paragraphId;
        fresh.readingOrder = line.readingOrder;
        ann.lines.insert(insertAt + k, fresh);
        _aiAdjustedLineIds.add(fresh.id);
      }
      _aiAdjustedLineIds.removeAll(removeIds);
      if (_selectedLine != null && removeIds.contains(_selectedLine!.id)) {
        _selectedLine = ann.lines.isEmpty
            ? null
            : ann.lines[insertAt.clamp(0, ann.lines.length - 1)];
      }
      // AI 修出的行不标 manual：仍可被区域级联重建，用户确认后自然进
      // 训练集（AI 调整 → 人工确认 → 训练反哺）。
      ann.ensureHierarchyContainment();
      ann.rebuildBlocks();
    });
    return true;
  }

  /// 检查报告：逐行明细 + 一键撤销本次全部修改（持有旧行快照，撤销把
  /// 修复行换回原行；对话框关闭后修复生效走正常确认流程）。
  Future<void> _showBoxReviewReport(
    List<LineReviewResult> results,
    List<LineReviewResult> applied, [
    int skipped = 0,
  ]) async {
    if (!mounted) return;
    var fixed = 0, kept = 0, vlmOk = 0, failed = 0, protected = 0, stale = 0;
    for (final r in results) {
      switch (r.status) {
        case BoxReviewStatus.fixed:
          fixed++;
        case BoxReviewStatus.kept:
          kept++;
        case BoxReviewStatus.vlmOk:
          vlmOk++;
        case BoxReviewStatus.failed:
          failed++;
        case BoxReviewStatus.protected:
          protected++;
        case BoxReviewStatus.stale:
          stale++;
      }
    }
    final undoable = applied.isNotEmpty || _layoutUndoSnapshot != null;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('AI 检查识别框 · 结果'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '修复 $fixed · 保持原样 $kept · AI 认为无问题 $vlmOk'
                '· 失败 $failed'
                '${protected > 0 ? ' · 受保护跳过 $protected' : ''}'
                '${stale > 0 ? ' · 已更新跳过 $stale' : ''}'
                '${skipped > 0 ? ' · 超上限跳过 $skipped' : ''}'
                '${_boxReviewCancelRequested ? '（已取消）' : ''}',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              if (results.isEmpty)
                const Text('（没有执行任何行）')
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final r in results)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                switch (r.status) {
                                  BoxReviewStatus.fixed => Icons.build_circle,
                                  BoxReviewStatus.kept =>
                                    Icons.do_not_disturb_on,
                                  BoxReviewStatus.vlmOk => Icons.verified,
                                  BoxReviewStatus.failed => Icons.error_outline,
                                  BoxReviewStatus.protected => Icons.lock,
                                  BoxReviewStatus.stale => Icons.update,
                                },
                                size: 16,
                                color: switch (r.status) {
                                  BoxReviewStatus.fixed =>
                                    Colors.green.shade700,
                                  BoxReviewStatus.kept => Colors.grey.shade600,
                                  BoxReviewStatus.vlmOk => Colors.teal.shade700,
                                  BoxReviewStatus.stale => Colors.grey.shade500,
                                  BoxReviewStatus.failed ||
                                  BoxReviewStatus.protected =>
                                    Colors.orange.shade800,
                                },
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  '行 ${r.oldLine.lineNo + 1}（${r.oldLine.chars.length} 字）'
                                  '${r.status == BoxReviewStatus.fixed ? '→ ${r.newLines.length} 行 ${r.newLines.fold<int>(0, (n, l) => n + l.chars.length)} 字' : ''}'
                                  '：${r.reason}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              if (undoable) ...[
                const SizedBox(height: 8),
                Text(
                  '修复行按识别置信度裁决采纳（新行待确认，卡片带「AI」徽章）；'
                  '关闭前可整体撤销本次修改。',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (undoable)
            TextButton(
              onPressed: () {
                _undoBoxReview(applied);
                Navigator.pop(ctx);
              },
              child: const Text('撤销全部修改'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  /// 撤销一次检查的全部修复：按应用时的逆序把修复行换回原行。
  void _undoBoxReview(List<LineReviewResult> applied) {
    final ann = _annotation;
    if (ann == null) return;
    setState(() {
      for (final r in applied.reversed) {
        final ids = r.newLines.map((l) => l.id).toSet();
        if (ids.isEmpty) {
          // 纯删除型修复（空框删除）：没有新行可定位，按行号序把原行
          // 插回（行号与阅读序一致；恢复到末尾兜底）。
          var at = ann.lines.length;
          for (var i = 0; i < ann.lines.length; i++) {
            if (ann.lines[i].lineNo > r.oldLine.lineNo) {
              at = i;
              break;
            }
          }
          ann.lines.insert(at, r.oldLine);
          continue;
        }
        var first = -1;
        for (var i = 0; i < ann.lines.length; i++) {
          if (ids.contains(ann.lines[i].id)) {
            first = i;
            break;
          }
        }
        if (first < 0) continue;
        ann.lines.removeWhere((l) => ids.contains(l.id));
        ann.lines.insert(first, r.oldLine);
        _aiAdjustedLineIds.removeAll(ids);
      }
      ann.rebuildBlocks();
      final snapshot = _layoutUndoSnapshot;
      if (snapshot != null) {
        ann.lines
          ..clear()
          ..addAll([for (final l in snapshot) LineBlock.fromJson(l.toJson())]);
        final paragraphSnapshot = _layoutUndoParagraphSnapshot;
        if (paragraphSnapshot != null) {
          ann.paragraphs
            ..clear()
            ..addAll([
              for (final p in paragraphSnapshot) Paragraph.fromJson(p.toJson()),
            ]);
        }
        final regionSnapshot = _layoutUndoRegionSnapshot;
        if (regionSnapshot != null) {
          ann.mainRegions
            ..clear()
            ..addAll([
              for (final r in regionSnapshot) MainRegion.fromJson(r.toJson()),
            ]);
        }
        ann.rebuildBlocks();
        _layoutUndoSnapshot = null;
        _layoutUndoParagraphSnapshot = null;
        _layoutUndoRegionSnapshot = null;
      }
    });
    _snack('已撤销本次 AI 检查的全部修改');
    unawaited(_save());
  }

  void _updateBlock(CharBlock old, CharBlock updated) {
    final idxB = _annotation!.blocks.indexOf(old);
    var inBlocks = idxB >= 0;
    if (idxB >= 0) _annotation!.blocks[idxB] = updated;
    var inLine = false;
    for (final line in _annotation!.lines) {
      final idx = line.chars.indexOf(old);
      if (idx >= 0) {
        line.chars[idx] = updated;
        line.text = line.chars.map((c) => c.text).join();
        inLine = true;
        // 字框几何被手工调整：所属行标记 manual，区域/段级联重建时
        // 保留整行（字框手工成果与行框同等保护）。
        if (old.x != updated.x ||
            old.y != updated.y ||
            old.w != updated.w ||
            old.h != updated.h) {
          line.manual = true;
        }
        break;
      }
    }
    if (!inBlocks || !inLine) {
      // 字块实例与标注列表脱节（重识别替换/重建后画布仍持有旧实例）：
      // 更新被静默丢弃，表现为"这个字框拖不动/尺寸调不了"。按 id 节流
      // 打点（拖拽期间每帧都会走到这里）。
      final now = DateTime.now();
      if (updated.id != _blockMissLogId ||
          _blockMissLogAt == null ||
          now.difference(_blockMissLogAt!).inMilliseconds > 1000) {
        _blockMissLogId = updated.id;
        _blockMissLogAt = now;
        PythonService.addAppLog(
          '字块更新未完全命中：id=${updated.id} '
          'blocks命中=$inBlocks 行内命中=$inLine lineId=${updated.lineId} '
          'rect=(${updated.x},${updated.y},${updated.w},${updated.h})——'
          '画布持有的字块实例已被替换（重识别/重建残留），本次改动被丢弃',
          isError: true,
        );
      }
    }
    // 几何（位置/尺寸）变化 → 手势结束后用 Kraken 重识别该字框；
    // 纯文字/类型修改不触发（拖拽期间每帧都会调用本方法）。
    if (old.x != updated.x ||
        old.y != updated.y ||
        old.w != updated.w ||
        old.h != updated.h) {
      // 字框被手工移动/缩放后，AI 的切分问题标记即过期（框已不是 AI
      // 看到的那个框），立即清除。
      if ((updated.aiBoxIssue ?? '').isNotEmpty) {
        updated
          ..aiBoxIssue = null
          ..aiBoxNote = null;
      }
      _charGeomDirty = true;
      _charGeomDirtyId = updated.id;
      _diagLogThrottled(
        'geom:${updated.id}',
        '[编辑诊断] 字框几何 id=${updated.id} '
            '(${old.x},${old.y},${old.w},${old.h})→'
            '(${updated.x},${updated.y},${updated.w},${updated.h})',
      );
    }
    setState(() {
      if (_selected == old) _selected = updated;
    });
    _save();
  }

  // ── reorder mode ──

  void _enterReorderMode() {
    final ann = _annotation;
    if (ann == null) return;
    final target = _viewMode == 'paragraph' ? 'paragraph' : 'line';
    if (target == 'paragraph' ? ann.paragraphs.isEmpty : ann.lines.isEmpty) {
      return;
    }

    setState(() {
      _reorderMode = true;
      _reorderTarget = target;
      _viewMode = target;
      _selected = null;
      _selectedLine = null;
      _selectedParagraph = null;
      _pendingLineOrder.clear();
      _pendingParagraphOrder.clear();
    });
  }

  void _cancelReorderMode() {
    if (!_reorderMode) return;
    setState(() {
      _reorderMode = false;
      _pendingLineOrder.clear();
      _pendingParagraphOrder.clear();
    });
  }

  void _recordLineOrder(LineBlock line) {
    final ann = _annotation;
    if (ann == null || !_reorderMode || _reorderTarget != 'line') return;
    if (_pendingLineOrder.containsKey(line.id)) return;

    setState(() {
      _pendingLineOrder[line.id] = _pendingLineOrder.length;
    });

    if (_pendingLineOrder.length == ann.lines.length) {
      _commitReorderMode();
    }
  }

  void _recordParagraphOrder(Paragraph paragraph) {
    final ann = _annotation;
    if (ann == null || !_reorderMode || _reorderTarget != 'paragraph') return;
    if (_pendingParagraphOrder.containsKey(paragraph.id)) return;
    setState(() {
      _pendingParagraphOrder[paragraph.id] = _pendingParagraphOrder.length;
    });
    if (_pendingParagraphOrder.length == ann.paragraphs.length) {
      _commitReorderMode();
    }
  }

  void _commitReorderMode() {
    final ann = _annotation;
    if (ann == null || !_reorderMode) return;
    if (_reorderTarget == 'paragraph') {
      if (_pendingParagraphOrder.length != ann.paragraphs.length) return;
      ann.paragraphs.sort(
        (a, b) => _pendingParagraphOrder[a.id]!.compareTo(
          _pendingParagraphOrder[b.id]!,
        ),
      );
    } else {
      if (_pendingLineOrder.length != ann.lines.length) return;

      ann.lines.sort(
        (a, b) => _pendingLineOrder[a.id]!.compareTo(_pendingLineOrder[b.id]!),
      );
      for (var lineIndex = 0; lineIndex < ann.lines.length; lineIndex++) {
        final line = ann.lines[lineIndex];
        line.lineNo = lineIndex;
        for (var charIndex = 0; charIndex < line.chars.length; charIndex++) {
          final c = line.chars[charIndex];
          c.col = lineIndex;
          c.order = charIndex;
          c.lineId = line.id;
        }
      }
      ann.rebuildBlocks();
    }

    setState(() {
      _reorderMode = false;
      _pendingLineOrder.clear();
      _pendingParagraphOrder.clear();
      _selectedLine = null;
      _selected = null;
    });
    _save();
  }

  // ── build ──

  /// 缩略图边框颜色（与左侧图例一一对应）：蓝=当前页、绿=已确认、
  /// 玫红=确认识别框（文字未确认）、橘黄=临时保存、紫=有识别框未确认、
  /// 灰=无标注。
  Color _pageBorderColor(int i) =>
      _markers.borderColor(i, currentIndex: _pageIndex);

  Widget _buildEditorBody(int pageCount) {
    return Row(
      children: [
        // page thumbnails
        SizedBox(
          width: 100,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                child: Wrap(
                  spacing: 4,
                  runSpacing: 2,
                  children: [
                    _PageStateLegend(color: Colors.blue, label: '当前'),
                    _PageStateLegend(
                      color: Colors.green.shade600,
                      label: '已确认',
                    ),
                    _PageStateLegend(
                      color: PageStateMarkers.boxesReviewedColor,
                      label: '框已确认',
                    ),
                    _PageStateLegend(
                      color: Colors.orange.shade700,
                      label: '临时保存',
                    ),
                    _PageStateLegend(color: Colors.purple, label: '识别未确认'),
                  ],
                ),
              ),
              // 隐藏已确认页：校对后期绿框页占大头，过滤后只剩待校对的页。
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 0, 6, 4),
                child: Tooltip(
                  message:
                      '把「确认并保存」过的绿框页从列表隐去，只列待校'
                      '对的页；当前页始终显示。翻页仍按真实页序逐页走。',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () {
                      _setHideConfirmedPages(!_hideConfirmedPages);
                      // 开关切换后可见列表长度变化，把当前页滚回可见位置。
                      WidgetsBinding.instance.addPostFrameCallback(
                        (_) => _scrollThumbsToCurrent(),
                      );
                    },
                    child: Container(
                      height: 24,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: _hideConfirmedPages
                              ? Colors.blue
                              : Colors.grey.shade400,
                        ),
                        color: _hideConfirmedPages
                            ? Colors.blue.withValues(alpha: 0.12)
                            : null,
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _hideConfirmedPages
                                ? Icons.visibility_off
                                : Icons.visibility,
                            size: 13,
                            color: _hideConfirmedPages
                                ? Colors.blue
                                : Colors.grey,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            '隐藏已确认',
                            style: TextStyle(
                              fontSize: 11,
                              color: _hideConfirmedPages
                                  ? Colors.blue
                                  : Colors.black54,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Builder(
                  builder: (context) {
                    final visible = _visibleThumbPages(pageCount);
                    // 常驻粗滑块：默认桌面滚动条悬停才现、且偏细，几百页
                    // 的书靠它定位太费劲；列表右侧留 12px 滑道（纵向列表
                    // 的横向 padding 不影响滚动范围与 _scrollThumbsToCurrent
                    // 的行高定位），滑块不压缩略图。
                    return AttachedScrollbar(
                      controller: _thumbScroll,
                      thumbVisibility: true,
                      thickness: 10,
                      radius: const Radius.circular(5),
                      child: ListView.builder(
                        controller: _thumbScroll,
                        padding: const EdgeInsets.only(right: 12),
                        itemExtent: 106,
                        itemCount: visible?.length ?? pageCount,
                        itemBuilder: (_, row) {
                          final i = visible == null ? row : visible[row];
                          return GestureDetector(
                            onTap: () => _switchPage(i),
                            child: Container(
                              margin: const EdgeInsets.all(4),
                              clipBehavior: Clip.hardEdge,
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: _pageBorderColor(i),
                                  width: i == _pageIndex || _markers.isMarked(i)
                                      ? 2
                                      : 1,
                                ),
                              ),
                              child: Column(
                                children: [
                                  Image.file(
                                    File(widget.project.imageFiles[i]),
                                    height: 80,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) =>
                                        const SizedBox(
                                          height: 80,
                                          child: Icon(Icons.image),
                                        ),
                                  ),
                                  Text(
                                    '${i + 1}',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      height: 1.0,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        // canvas area
        Expanded(
          child: _canvasStatusOverlay(
            child: Column(
              children: [
                if (_reorderMode)
                  Container(
                    width: double.infinity,
                    color: Colors.orange.shade100,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.sort, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${_reorderTarget == 'paragraph' ? '点击段框' : '点击行框'}设置新顺序：'
                            '${_reorderTarget == 'paragraph' ? _pendingParagraphOrder.length : _pendingLineOrder.length}/'
                            '${_reorderTarget == 'paragraph' ? (_annotation?.paragraphs.length ?? 0) : (_annotation?.lines.length ?? 0)}。'
                            '已点击的${_reorderTarget == 'paragraph' ? '段' : '行'}会在中心显示新序号并变色；全部点击后自动保存并退出。'
                            '再次点击「点击排序」或按 ESC 会取消本次排序。',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: _loading
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(),
                              const SizedBox(height: 12),
                              Text(_loadingLabel),
                            ],
                          ),
                        )
                      : _error != null
                      ? Center(
                          child: Text(
                            '错误：$_error',
                            style: const TextStyle(color: Colors.red),
                          ),
                        )
                      : _viewMode == 'text'
                      ? DirectTextPanel(
                          // 翻页即换内容（key 变 → state 重建重载该页文本）
                          key: ValueKey('direct-text-$_pageId'),
                          project: widget.project,
                          pageId: _pageId,
                          imagePath: _imagePath,
                          settings: _pageSettings,
                          onSnackBar: _snack,
                          // 直读落盘后刷新标注里的整页对照标记（见
                          // _refreshFullTextMarks）。
                          onReadComplete: _refreshFullTextMarks,
                        )
                      : _annotation == null
                      ? const SizedBox()
                      : (_viewMode == 'char' && !_reorderMode)
                      ? _DetailCardList(
                          imagePath: _imagePath,
                          imageRevision: _imageRevision,
                          annotation: _annotation!,
                          settings: _pageSettings,
                          cardWidth: _detailCardWidth,
                          fontSize: _detailFontSize,
                          selected: _selected,
                          processingLineId: _processingLineId,
                          processingLineAction: _processingLineAction,
                          focusLineId: _detailFocusLineId,
                          focusSeq: _detailFocusSeq,
                          flashCharId: _flashCharId,
                          onCharUpdated: _updateBlockFromLineCard,
                          onCharAdded: _addBlock,
                          onCharSelected: _selectBlock,
                          onRerecognizeLine: _queueLineCascade,
                          onResplitLine: _queueResplitLine,
                          onAiCheckLine: _runBoxReviewSingleLine,
                          onAiRepairLine: _repairLineFromAiMarks,
                          aiAdjustedLineIds: _aiAdjustedLineIds,
                          onCharsReordered: _reorderLineChars,
                          onCharDeleted: _deleteBlockById,
                        )
                      : Column(
                          children: [
                            if (_excalidrawPicking) _excalidrawPickBanner(),
                            Expanded(
                              child: _AnnotationCanvas(
                                imagePath: _imagePath,
                                imageRevision: _imageRevision,
                                lines: _annotation!.lines,
                                blocks: _annotation!.blocks,
                                selected: _selected,
                                selectedLine: _selectedLine,
                                selectedRegion: _selectedRegion,
                                selectedParagraph: _selectedParagraph,
                                viewMode: _viewMode,
                                showIndex: _showIndex,
                                showCharBox: _showCharBox,
                                reorderMode: _reorderMode,
                                pendingLineOrder: _pendingLineOrder,
                                pendingParagraphOrder: _pendingParagraphOrder,
                                mainRegions: _annotation!.mainRegions,
                                paragraphs: _annotation!.paragraphs,
                                onSelect: _selectBlock,
                                onSelectLine: _selectLine,
                                onReorderLine: _recordLineOrder,
                                onReorderParagraph: _recordParagraphOrder,
                                onAdd: _addBlock,
                                onAddLine: _addLine,
                                onUpdate: _updateBlock,
                                onAddRegion: _addRegion,
                                newRegionLabel: _newRegionLabel,
                                regionConflictedIds: {
                                  for (final c
                                      in _annotation?.regionConflicts ??
                                          const <Map<String, dynamic>>[]) ...[
                                    if (c['main_region_id'] is String)
                                      c['main_region_id'] as String,
                                    if (c['other_region_id'] is String)
                                      c['other_region_id'] as String,
                                  ],
                                },
                                onSelectRegion: _selectRegion,
                                onUpdateRegion: _updateRegion,
                                onAddParagraph: _addParagraph,
                                onSelectParagraph: _selectParagraph,
                                onUpdateParagraph: _updateParagraph,
                                onUpdateLine: _updateLine,
                                onGeometryEditEnd: _handleGeometryEditEnd,
                                onImageReady: _onCanvasImageReady,
                                pickRegion: _excalidrawPicking,
                                onPickRegion: _onExcalidrawRegionPicked,
                                focusRect: _canvasFocusRect,
                                focusSeq: _canvasFocusSeq,
                              ),
                            ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
        // right panel: toolbar + optional block properties
        SizedBox(
          width: 240,
          child: Column(
            children: [
              _EditorToolbar(
                viewMode: _viewMode,
                showIndex: _showIndex,
                showCharBox: _showCharBox,
                reorderMode: _reorderMode,
                blockCount: _annotation?.blocks.length ?? 0,
                lineCount: _annotation?.lines.length ?? 0,
                regionCount: _annotation?.mainRegions.length ?? 0,
                paragraphCount: _annotation?.paragraphs.length ?? 0,
                settings: _pageSettings,
                onViewModeChanged: (v) => setState(() {
                  if (_reorderMode) return; // 排序时锁定当前分区
                  _viewMode = v;
                }),
                onShowIndexChanged: (v) => setState(() => _showIndex = v),
                onShowCharBoxChanged: (v) => setState(() => _showCharBox = v),
                onReorderToggled: () {
                  if (_reorderMode) {
                    _cancelReorderMode();
                  } else {
                    _enterReorderMode();
                  }
                },
                onInferHierarchy: () {
                  final ann = _annotation;
                  if (ann == null) return;
                  setState(
                    () => ann.inferHierarchy(
                      orientation: _pageOrientation,
                      horizontalDir: _pageSettings.horizontalDir,
                      verticalDir: _pageSettings.verticalDir,
                      force: true,
                      // 画布已解码图像：主区（行外接矩形+2%边距）钳回图片范围
                      imageWidth: _canvasImageSize.width.round(),
                      imageHeight: _canvasImageSize.height.round(),
                    ),
                  );
                  _save();
                },
              ),
              const Divider(height: 1),
              if (_viewMode == 'char') ...[
                _DetailZoomControls(
                  cardWidth: _detailCardWidth,
                  scale: _detailCardScale,
                  fontScale: _detailFontScale,
                  fontSize: _detailFontSize,
                  onZoomIn: _zoomInDetail,
                  onZoomOut: _zoomOutDetail,
                  onReset: _resetDetailZoom,
                  onFontScaleUp: _fontScaleUp,
                  onFontScaleDown: _fontScaleDown,
                  onResetFontScale: _resetFontScale,
                ),
                // 全页级批量重识别：逐行走既有级联队列（排队数胶囊可见、
                // 409 自动重试），行卡片转圈按行逐一显示。
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        '全页操作',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      OutlinedButton.icon(
                        onPressed: _pageBatchBusy ? null : _resplitAllLines,
                        icon: const Icon(Icons.content_cut, size: 17),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.deepOrange,
                        ),
                        label: const Text(
                          '全页重新切割',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                      const SizedBox(height: 4),
                      OutlinedButton.icon(
                        onPressed: _pageBatchBusy
                            ? null
                            : _rerecognizeAllLineChars,
                        icon: const Icon(Icons.text_fields, size: 17),
                        label: const Text(
                          '全页重新识别单字',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                      const SizedBox(height: 4),
                      // 全书「确认并保存」改回未保存（用户需求：批量确认
                      // 过头要能整本退回；训练统计同步回退）。
                      OutlinedButton.icon(
                        onPressed: _pageBatchBusy || _revertAllBusy
                            ? null
                            : _revertAllReviewedPages,
                        icon: const Icon(Icons.history, size: 17),
                        label: const Text(
                          '全书改回未保存',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              // region 视图：预标注入口（「新框类别」已上移到标题栏下方
              // 工具栏，与快捷键 1~7 同一状态）
              if (_viewMode == 'region')
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _regionPrelabeling || _aiPrelabeling
                            ? null
                            : _runRegionPrelabel,
                        icon: _regionPrelabeling
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.auto_awesome),
                        label: const Text('预标注版面区'),
                      ),
                      const SizedBox(height: 6),
                      OutlinedButton.icon(
                        onPressed: _aiPrelabeling || _regionPrelabeling
                            ? null
                            : _runAiPagePrelabel,
                        icon: _aiPrelabeling
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.visibility),
                        label: const Text('AI 整页预标注'),
                      ),
                    ],
                  ),
                ),
              // 训练进度固定钉在此处：选中属性面板出现/消失时位置不动，
              // 面板区域不再整体跳动。
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: _progressForViewMode(),
              ),
              const SizedBox(height: 8),
              // 清除功能长驻：无需先选中识别框，按当前视图层级清空本页
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
                child: _buildClearBar(),
              ),
              const SizedBox(height: 8),
              // 属性面板可滚动：内容高过窗口时不再被裁掉
              Expanded(
                child: _selected != null && _viewMode == 'char'
                    ? SingleChildScrollView(
                        child: _BlockPanel(
                          block: _selected!,
                          onDelete: _deleteSelected,
                          onTypeChange: _updateType,
                          onClearAll: _clearAllChars,
                          recognizing: _recognizingChars.contains(
                            _selected!.id,
                          ),
                          progress: const SizedBox.shrink(),
                          onShowVerify:
                              _selected!.type == 'main_text' &&
                                  _selected!.text.runes.length == 1
                              ? _showVerifyDialog
                              : null,
                          onMarkToggle: (v) =>
                              _updateBlocksMarkById([_selected!.id], v),
                        ),
                      )
                    : _selectedLine != null && _viewMode == 'line'
                    ? SingleChildScrollView(
                        child: _LinePanel(
                          line: _selectedLine!,
                          processing: _lineProcessing,
                          onDelete: _deleteSelectedLine,
                          onClearAll: _clearAllLines,
                          progress: const SizedBox.shrink(),
                        ),
                      )
                    : _selectedRegion != null && _viewMode == 'region'
                    ? SingleChildScrollView(
                        child: _RegionPanel(
                          region: _selectedRegion!,
                          onLabelChanged: _updateRegionLabel,
                          conflicted: (_annotation?.regionConflicts ?? const [])
                              .any(
                                (c) =>
                                    c['main_region_id'] ==
                                        _selectedRegion!.id ||
                                    c['other_region_id'] == _selectedRegion!.id,
                              ),
                          onOpenTable: _openOrRecognizeTable,
                          hasTableResult:
                              _tableForRegion(_selectedRegion!) != null,
                          onDelete: _deleteSelectedRegion,
                          onClearAll: _clearAllRegions,
                          progress: const SizedBox.shrink(),
                        ),
                      )
                    : _selectedParagraph != null && _viewMode == 'paragraph'
                    ? SingleChildScrollView(
                        child: _ParagraphPanel(
                          paragraph: _selectedParagraph!,
                          onDelete: _deleteSelectedParagraph,
                          onClearAll: _clearAllParagraphs,
                          progress: const SizedBox.shrink(),
                        ),
                      )
                    : Container(
                        color: Colors.grey.shade50,
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: Center(
                                child: Text(
                                  () {
                                    switch (_viewMode) {
                                      case 'region':
                                        return '主区视图\n拖拽空白处画新主区框（类别用顶部工具栏或快捷键 1~7 切换）\n点击主区框选中';
                                      case 'paragraph':
                                        return '段视图\n拖拽空白处画新段框\n点击段框选中\n可使用「自动推断层级」';
                                      case 'char':
                                        return '点击字框查看属性';
                                      default:
                                        return '行视图\n拖拽空白处画新行框\n点击行框选中\n拖拽行框移动，拖右下角调整尺寸';
                                    }
                                  }(),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade500,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
              const Divider(height: 1),
              // 右侧面板底部：当前页拆分方式与所用模型
              _buildSegmentInfoFooter(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _progressForViewMode() {
    final ann = _annotation;
    if (ann == null) return const SizedBox.shrink();
    // 内容层当前页计数排除已确认排除类区（页眉/页脚/页码/图/表）内的
    // 框——与 PageCounters/训练导出同口径（页眉页脚只作 region_det 标注）。
    bool notExcluded(int x, int y, int w, int h) =>
        !ann.centerInConfirmedExcluded(x, y, w, h);
    switch (_viewMode) {
      case 'region':
        return _LayerProgress(
          layer: 'region_det',
          instances: _progressValue(
            'region_det',
            ann.mainRegions
                .where(
                  (r) =>
                      r.status == AnnotationStatus.confirmed || r.boxConfirmed,
                )
                .length,
          ),
          readiness: _trainReadiness['region_det'],
        );
      case 'paragraph':
        return _LayerProgress(
          layer: 'paragraph_det',
          instances: _progressValue(
            'paragraph_det',
            ann.paragraphs
                .where(
                  (p) =>
                      (p.status == AnnotationStatus.confirmed ||
                          p.boxConfirmed) &&
                      notExcluded(p.x, p.y, p.w, p.h),
                )
                .length,
          ),
          readiness: _trainReadiness['paragraph_det'],
        );
      case 'line':
        return _LayerProgress(
          layer: 'line_det',
          instances: _progressValue(
            'line_det',
            ann.lines
                .where(
                  (l) =>
                      (l.status == AnnotationStatus.confirmed ||
                          l.boxConfirmed) &&
                      notExcluded(l.x, l.y, l.w, l.h),
                )
                .length,
          ),
          readiness: _trainReadiness['line_det'],
        );
      case 'char':
        final allChars = ann.lines
            .where((l) => notExcluded(l.x, l.y, l.w, l.h))
            .expand((l) => l.chars)
            .toList();
        // char_det：完全确认或只确认字框（「确认识别框」）都计入检测
        // 训练；char_cls：只认完全确认的单字标签（与训练导出同口径）。
        final detCount = allChars
            .where(
              (c) =>
                  (c.status == AnnotationStatus.confirmed || c.boxConfirmed) &&
                  c.type != 'ignore',
            )
            .length;
        final clsChars = allChars
            .where((c) => c.status == AnnotationStatus.confirmed)
            .toList();
        // 单字区域同时显示两层进度：char_det（单字识别/检测）与
        // char_cls（单字候选分类，按去重字类数）。
        return Column(
          children: [
            _LayerProgress(
              layer: 'char_det',
              instances: _progressValue('char_det', detCount),
              readiness: _trainReadiness['char_det'],
            ),
            const SizedBox(height: 8),
            _LayerProgress(
              layer: 'char_cls',
              instances: _progressValue('char_cls', clsChars.length),
              classes: _bookProgress.isNotEmpty
                  ? _bookCharClasses
                  : clsChars
                        .where((c) => c.text.isNotEmpty)
                        .map((c) => c.text)
                        .toSet()
                        .length,
              readiness: _trainReadiness['char_cls'],
            ),
          ],
        );
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    final pageCount = widget.project.imageFiles.length;
    return Stack(
      children: [
        Positioned.fill(
          child: Listener(
            // 任意点击（画布/缩略图/面板/按钮）后把键盘焦点收回页面：
            // KeyboardListener 只有持有焦点才收得到 Delete/Esc；焦点一旦被
            // 按钮或编辑浮层带走，快捷键会静默失灵。
            // 中键按下进入手势采集（整窗口感应，见 _onGestureDown）。
            onPointerDown: (e) {
              if (e.buttons == kMiddleMouseButton) _onGestureDown(e);
              _focusNode.requestFocus();
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
            child: KeyboardListener(
              focusNode: _focusNode,
              autofocus: true,
              onKeyEvent: (e) {
                if (e is KeyDownEvent) {
                  if (e.logicalKey == LogicalKeyboardKey.delete) {
                    // 诊断：能打出这条说明焦点在页面（Delete 已送达）；删除
                    // 仍无效则看 [删除] 日志的移除计数。
                    PythonService.addAppLog(
                      '[快捷键] Delete 送达 viewMode=$_viewMode '
                      '字选中=${_selected?.id ?? '无'} '
                      '行选中=${_selectedLine?.id ?? '无'}',
                    );
                    if (_viewMode == 'region' && _selectedRegion != null) {
                      _deleteSelectedRegion();
                    } else if (_viewMode == 'paragraph' &&
                        _selectedParagraph != null) {
                      _deleteSelectedParagraph();
                    } else if (_viewMode == 'line' && _selectedLine != null) {
                      _deleteSelectedLine();
                    } else {
                      _deleteSelected();
                    }
                  } else if (e.logicalKey == LogicalKeyboardKey.escape) {
                    if (_reorderMode) {
                      _cancelReorderMode();
                    } else if (_selected != null) {
                      setState(() => _selected = null);
                    } else if (_selectedLine != null) {
                      setState(() => _selectedLine = null);
                    } else if (_selectedRegion != null) {
                      setState(() => _selectedRegion = null);
                    } else if (_selectedParagraph != null) {
                      setState(() => _selectedParagraph = null);
                    }
                  } else if (_viewMode == 'region' &&
                      _viewIndex == 0 &&
                      !_reorderMode) {
                    // 快捷键 1~7：切换「新框类别」（主数字与小键盘都认，键数
                    // 与 RegionLabel 词表长度对齐）。只在主区视图生效——其他
                    // 视图数字另有语义空间，不抢；排序模式锁定。文本输入框聚
                    // 焦时事件到不了这里，不会误吞数字输入。
                    const digitKeys = [
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
                    final digitCount =
                        digitKeys.length ~/ 2; // 每类两个键（主数字 + 小键盘）
                    final found = digitKeys.indexOf(e.logicalKey);
                    if (found >= 0 &&
                        found % digitCount < RegionLabel.all.length) {
                      final idx = found % digitCount;
                      if (_newRegionLabel != RegionLabel.all[idx]) {
                        setState(() => _newRegionLabel = RegionLabel.all[idx]);
                      }
                    }
                  }
                }
              },
              child: Scaffold(
                appBar: AppBar(
                  // 标题中间区域：书名 + 高频的「校对摆正」直达 + 低频页面操作
                  // 收进「页面」菜单；两侧 Spacer 让操作组在标题栏内居中。
                  title: Row(
                    children: [
                      Flexible(
                        child: Text(
                          widget.project.name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.crop_free),
                        tooltip: '校对摆正：智能检测裁切点，透视拉平书页（可去色/锐化）',
                        onPressed: _loading
                            ? null
                            : () => unawaited(_openStraighten()),
                      ),
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.rotate_90_degrees_ccw),
                        tooltip: '页面操作：旋转 / 镜像 / 识别方向 / 框选导出 / 删除页',
                        onSelected: (value) {
                          if (_loading || _annotation == null) return;
                          switch (value) {
                            case 'rotate_cw':
                              unawaited(_transformCurrentPage('rotate_cw'));
                            case 'rotate_ccw':
                              unawaited(_transformCurrentPage('rotate_ccw'));
                            case 'flip_h':
                              unawaited(_transformCurrentPage('flip_h'));
                            case 'flip_v':
                              unawaited(_transformCurrentPage('flip_v'));
                            case 'page_orientation':
                              unawaited(_showPageOrientationDialog());
                            case 'engine_settings':
                              unawaited(_showEngineSettingsDialog());
                            case 'excalidraw_pick':
                              _toggleExcalidrawPick();
                            case 'delete_page':
                              unawaited(_confirmDeletePage());
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'rotate_cw',
                            child: ListTile(
                              leading: Icon(Icons.rotate_right),
                              title: Text('顺时针旋转 90°'),
                              subtitle: Text('标注几何同步变换'),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                          PopupMenuItem(
                            value: 'rotate_ccw',
                            child: ListTile(
                              leading: Icon(Icons.rotate_left),
                              title: Text('逆时针旋转 90°'),
                              subtitle: Text('标注几何同步变换'),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                          PopupMenuItem(
                            value: 'flip_h',
                            child: ListTile(
                              leading: Icon(Icons.swap_horiz),
                              title: Text('左右镜像'),
                              subtitle: Text('标注几何同步变换'),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                          PopupMenuItem(
                            value: 'flip_v',
                            child: ListTile(
                              leading: Icon(Icons.swap_vert),
                              title: Text('上下镜像'),
                              subtitle: Text('标注几何同步变换'),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                          PopupMenuItem(
                            value: 'page_orientation',
                            child: ListTile(
                              leading: Icon(Icons.swap_horiz),
                              title: Text('本页识别方向'),
                              subtitle: Text('排版方向与阅读方向可按页单独设置'),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                          PopupMenuItem(
                            value: 'engine_settings',
                            child: ListTile(
                              leading: Icon(Icons.auto_awesome_outlined),
                              title: Text('识别引擎（本书）'),
                              subtitle: Text('Kraken / PaddleOCR 切换与 Paddle 模型档位'),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                          PopupMenuItem(
                            value: 'excalidraw_pick',
                            child: ListTile(
                              leading: Icon(Icons.draw_outlined),
                              title: Text('框选导出 Excalidraw'),
                              subtitle: Text('框选区域，在工作台预览调参后导出可编辑图形'),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                          PopupMenuItem(
                            value: 'delete_page',
                            child: ListTile(
                              leading: Icon(
                                Icons.delete_outline,
                                color: Colors.red,
                              ),
                              title: Text(
                                '删除该页',
                                style: TextStyle(color: Colors.red),
                              ),
                              subtitle: Text('删除图片与本页标注，后页编号前移'),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                    ],
                  ),
                  actions: [
                    SegmentedButton<int>(
                      segments: const [
                        ButtonSegment(
                          value: 0,
                          icon: Icon(Icons.edit_note),
                          label: Text('标注'),
                        ),
                        ButtonSegment(
                          value: 1,
                          icon: Icon(Icons.terminal),
                          label: Text('后台'),
                        ),
                      ],
                      selected: {_viewIndex},
                      onSelectionChanged: (value) =>
                          setState(() => _viewIndex = value.first),
                    ),
                    const SizedBox(width: 8),
                    PopupMenuButton<String>(
                      icon: const Icon(Icons.auto_stories),
                      tooltip: '全书操作：总览 / 叠加 / 主区快设 / 拆分 / 墨迹归类 / 整本识别',
                      onSelected: (value) {
                        if (_loading) return;
                        switch (value) {
                          case 'book_grid':
                            _openBookGrid();
                          case 'book_overlay':
                            _openBookOverlay();
                          case 'region_grid':
                            _openBookRegionGrid();
                          case 'book_split':
                            unawaited(_openBookSplit());
                          case 'similar_book':
                            unawaited(_openSimilarCharsBook());
                          case 'recognize_book':
                            _startWholeBookRecognition();
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'book_grid',
                          child: ListTile(
                            leading: Icon(Icons.grid_view),
                            title: Text('全书总览'),
                            subtitle: Text('网格浏览所有页（可切主区/段/行/字层），点击跳页'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        PopupMenuItem(
                          value: 'book_overlay',
                          child: ListTile(
                            leading: Icon(Icons.layers),
                            title: Text('全书叠加'),
                            subtitle: Text('所有页半透明叠加，批量调整并应用正文区'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        PopupMenuItem(
                          value: 'region_grid',
                          child: ListTile(
                            leading: Icon(Icons.filter_center_focus),
                            title: Text('主区快设'),
                            subtitle: Text('网格逐页快速框正文区，改完统一按主区拆行/字/段'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        PopupMenuItem(
                          value: 'book_split',
                          child: ListTile(
                            leading: Icon(Icons.splitscreen),
                            title: Text('跨页拆分（左右页拆开）'),
                            subtitle: Text('左右两页合扫的书按中缝拆成两页'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        PopupMenuItem(
                          value: 'similar_book',
                          child: ListTile(
                            leading: Icon(Icons.auto_stories),
                            title: Text('墨迹归类（全书版）'),
                            subtitle: Text('指定页范围或整本书跨页聚类批量校正'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        PopupMenuItem(
                          value: 'recognize_book',
                          child: ListTile(
                            leading: Icon(Icons.play_circle_outline),
                            title: Text('开始整本识别'),
                            subtitle: Text('后台逐页识别无标注的页，完成后回到书库看进度'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.hub_outlined),
                      tooltip:
                          '墨迹归类：本页相似字块分组批量校正，'
                          '组可确认；页内可进全书版',
                      onPressed: _loading || _annotation == null
                          ? null
                          : _openSimilarChars,
                    ),
                    IconButton(
                      icon: _verifyingPage
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.fact_check_outlined),
                      tooltip:
                          '墨迹校验：识别文字与原字墨迹重叠比对，'
                          '不匹配的标红并转待复核',
                      onPressed:
                          _loading || _annotation == null || _verifyingPage
                          ? null
                          : () => unawaited(_verifyPageChars()),
                    ),
                    IconButton(
                      icon: _boxReviewing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.auto_fix_high),
                      tooltip:
                          'AI 检查识别框：扫描可疑行（重叠/高框/低置信度/两路分歧/'
                          '墨迹存疑），重摆后按识别置信度裁决，提升才采纳；'
                          '需在 AI 辅助设置中开启',
                      onPressed:
                          _loading ||
                              _annotation == null ||
                              _boxReviewing ||
                              _verifyingPage
                          ? null
                          : () => unawaited(_runBoxReviewPage()),
                    ),
                    IconButton(
                      icon: const Icon(Icons.manage_history),
                      tooltip:
                          'AI 溯源：回看本页最后一次识别的完整 AI 辅助过程——'
                          '每行 AI 看到的图、提示词、思考过程、判定依据、写入内容'
                          '与 YOLO 局部修复前后（仅保留最后一次运行）',
                      onPressed: _loading || _annotation == null
                          ? null
                          : () => unawaited(
                              showAiTracePanel(
                                context,
                                projectDir: widget.project.projectDir,
                                pageId: _pageId,
                                pageLabel: '第 ${_pageIndex + 1} 页',
                              ),
                            ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: '重新识别当前页',
                      onPressed: _loading
                          ? null
                          : () => _loadPage(forceSegment: true),
                    ),
                    IconButton(
                      icon: Icon(_dirty ? Icons.save : Icons.save_outlined),
                      tooltip:
                          '临时保存：保存当前修改（未完成也可存），'
                          '不确认、不计入训练数据',
                      onPressed: _loading || _annotation == null
                          ? null
                          : _saveDraftPage,
                    ),
                    IconButton(
                      icon: const Icon(Icons.done_all_outlined),
                      tooltip:
                          '确认识别框：确认本页全部识别框几何（正文区/段落/行/字框，'
                          '计入检测训练），单字文字候选保持待确认',
                      onPressed: _loading || _annotation == null
                          ? null
                          : _saveBoxesOnlyPage,
                    ),
                    IconButton(
                      icon: const Icon(Icons.task_alt),
                      tooltip: '确认并保存：确认本页全部识别框与文字，计入训练数据',
                      onPressed: _loading || _annotation == null
                          ? null
                          : _saveCurrentPage,
                    ),
                    IconButton(
                      icon: const Icon(Icons.file_download),
                      tooltip: '导出',
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ExportPage(project: widget.project),
                        ),
                      ),
                    ),
                  ],
                ),
                body: Column(
                  children: [
                    _buildEditorToolbar(),
                    Expanded(
                      child: IndexedStack(
                        index: _viewIndex,
                        children: [
                          _buildEditorBody(pageCount),
                          // active：仅当控制台是当前视图时才刷新 UI。识别洪流期间
                          // 隐藏面板若逐条 setState+滚动动画，UI 线程被 build 风暴
                          // 压死、引擎任务在 Win32 消息队列积压打满，表现为
                          // "Failed to post message to main thread" 刷屏。
                          BackendConsolePanel(active: _viewIndex == 1),
                        ],
                      ),
                    ),
                  ],
                ),
                bottomNavigationBar: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [_buildBoxIndexBar(), _buildPageNavBar(pageCount)],
                ),
              ),
            ),
          ),
        ),
        // 中键手势拖动轨迹（松手即消失）：全局坐标直画（页面 Stack 占
        // 满窗口），IgnorePointer 不挡任何交互。
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
  }

  // ── 底部翻页栏 ──

  /// 标题栏下方工具栏（仅标注视图）：高频页面操作（旋转/镜像）横排直达
  /// ——原「页面」菜单里翻两级才能点到；主区视图再挂「新框类别」七类
  /// 快切（快捷键 1~7，与画布新框、右侧面板类别下拉同一状态）。低频/
  /// 危险操作（识别方向/框选导出/删除页）仍留在标题栏「页面」菜单。
  Widget _buildEditorToolbar() {
    if (_viewIndex != 0) return const SizedBox.shrink();
    final pageBusy = _loading || _annotation == null;
    Widget pageOp(IconData icon, String tooltip, String action) => IconButton(
      icon: Icon(icon, size: 20),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
      padding: const EdgeInsets.symmetric(horizontal: 5),
      onPressed: pageBusy
          ? null
          : () => unawaited(_transformCurrentPage(action)),
    );
    final children = <Widget>[
      pageOp(Icons.rotate_right, '顺时针旋转 90°（标注几何同步变换）', 'rotate_cw'),
      pageOp(Icons.rotate_left, '逆时针旋转 90°（标注几何同步变换）', 'rotate_ccw'),
      pageOp(Icons.swap_horiz, '左右镜像（标注几何同步变换）', 'flip_h'),
      pageOp(Icons.swap_vert, '上下镜像（标注几何同步变换）', 'flip_v'),
    ];
    if (_viewMode == 'region') {
      children.add(
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          width: 1,
          color: Colors.black12,
        ),
      );
      for (var i = 0; i < RegionLabel.all.length; i++) {
        final label = RegionLabel.all[i];
        children.add(
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Tooltip(
              message: '新画主区框用此类别（快捷键 ${i + 1}，仅主区视图生效）',
              child: ChoiceChip(
                avatar: Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: RegionLabel.color(label),
                    shape: BoxShape.circle,
                  ),
                ),
                label: Text(
                  '${RegionLabel.displayName(label)} ${i + 1}',
                  style: const TextStyle(fontSize: 12),
                ),
                selected: _newRegionLabel == label,
                visualDensity: VisualDensity.compact,
                showCheckmark: false,
                onSelected: (_) => setState(() => _newRegionLabel = label),
              ),
            ),
          ),
        );
      }
    }
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.black12)),
      ),
      height: 42,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: children,
        ),
      ),
    );
  }

  /// 翻页栏上方的识别框编号条：按当前视图层级列出本页全部框的编号
  /// （与画布 showIndex 标注同序同号），点编号选中该框并把画布平移到
  /// 框中心。单字视图没有编号标注，不显示本条；后台控制台视图同样
  /// 不显示。
  Widget _buildBoxIndexBar() {
    if (_viewIndex != 0 || _viewMode == 'char') return const SizedBox.shrink();
    final ann = _annotation;
    if (ann == null) return const SizedBox.shrink();
    final List<({int no, Rect rect, bool selected})> items;
    switch (_viewMode) {
      case 'region':
        items = [
          for (var i = 0; i < ann.mainRegions.length; i++)
            (
              no: i + 1,
              rect: ann.mainRegions[i].rect,
              selected: ann.mainRegions[i] == _selectedRegion,
            ),
        ];
      case 'paragraph':
        items = [
          for (var i = 0; i < ann.paragraphs.length; i++)
            (
              no: i + 1,
              rect: ann.paragraphs[i].rect,
              selected: ann.paragraphs[i] == _selectedParagraph,
            ),
        ];
      case 'line':
        items = [
          for (var i = 0; i < ann.lines.length; i++)
            (
              no: i + 1,
              rect: ann.lines[i].rect,
              selected: ann.lines[i] == _selectedLine,
            ),
        ];
      default:
        return const SizedBox.shrink();
    }
    if (items.isEmpty) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        border: Border(top: BorderSide(color: Colors.grey.shade300)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 5, 12, 5),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              // 编号在条内水平居中；总宽超出条宽时自然变为横向滚动
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final item in items)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: InkWell(
                        onTap: () => _focusBoxItem(item.no - 1),
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: item.selected
                                ? Colors.orange.shade700
                                : Colors.white,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: item.selected
                                  ? Colors.orange.shade900
                                  : Colors.grey.shade400,
                            ),
                          ),
                          child: Text(
                            '${item.no}',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              fontFeatures: [FontFeature.tabularFigures()],
                              color: item.selected
                                  ? Colors.white
                                  : Colors.grey.shade800,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 点编号条：按编号（1 基，与画布 showIndex 标注同序）选中对应层级
  /// 的框（其余层级选中清空），并让画布把该框平移到视口中心（保持
  /// 当前缩放比例）。
  void _focusBoxItem(int index) {
    final ann = _annotation;
    if (ann == null) return;
    setState(() {
      _selected = null;
      _selectedLine = null;
      _selectedRegion = null;
      _selectedParagraph = null;
      switch (_viewMode) {
        case 'region':
          if (index < ann.mainRegions.length) {
            _selectedRegion = ann.mainRegions[index];
            _canvasFocusRect = ann.mainRegions[index].rect;
          }
        case 'paragraph':
          if (index < ann.paragraphs.length) {
            _selectedParagraph = ann.paragraphs[index];
            _canvasFocusRect = ann.paragraphs[index].rect;
          }
        case 'line':
          if (index < ann.lines.length) {
            _selectedLine = ann.lines[index];
            _canvasFocusRect = ann.lines[index].rect;
          }
      }
      _canvasFocusSeq++;
    });
  }

  /// 长驻清除栏：按当前视图层级提供"清空本页"按钮，不需要先选中某个
  /// 识别框（原先清除按钮只在选中后的属性面板里才出现）。
  Widget _buildClearBar() {
    final (String label, VoidCallback onClear) = switch (_viewMode) {
      'region' => ('正文区', _clearAllRegions),
      'paragraph' => ('段落', _clearAllParagraphs),
      'line' => ('行框', _clearAllLines),
      _ => ('单字框', _clearAllChars),
    };
    return OutlinedButton.icon(
      onPressed: _loading ? null : onClear,
      icon: Icon(Icons.layers_clear, size: 16, color: Colors.red.shade700),
      label: Text('清除本页全部$label'),
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.red.shade700,
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  /// 整个编辑器界面下方的上一页/下一页翻页栏，标注/后台两种视图都固定显示。
  Widget _buildPageNavBar(int pageCount) {
    final canPrev = _pageIndex > 0;
    final canNext = _pageIndex < pageCount - 1;
    // 右下角校对进度：还有多少页没确认 + 已确认占比。savedPages 在
    // 确认/重识别流程中随 setState 增删，翻页/确认即实时刷新；删除页
    // 后旧页号可能残留，按页数钳界只统计现存页。
    final confirmed = _markers.savedPages.where((i) => i < pageCount).length;
    final confirmedPercent = pageCount == 0
        ? 0
        : (confirmed * 100 / pageCount).round();
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        border: Border(top: BorderSide(color: Colors.grey.shade300)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          const Spacer(),
          OutlinedButton.icon(
            onPressed: canPrev ? () => _switchPage(_pageIndex - 1) : null,
            icon: const Icon(Icons.navigate_before, size: 18),
            label: const Text('上一页'),
          ),
          const SizedBox(width: 16),
          Text(
            '第 ${_pageIndex + 1} / $pageCount 页',
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 16),
          OutlinedButton.icon(
            onPressed: canNext ? () => _switchPage(_pageIndex + 1) : null,
            icon: const Icon(Icons.navigate_next, size: 18),
            label: const Text('下一页'),
          ),
          const Spacer(),
          Text(
            '未确认 ${pageCount - confirmed} 页 · '
            '已确认 $confirmed/$pageCount（$confirmedPercent%）',
            style: TextStyle(
              fontSize: 12.5,
              color: confirmed == pageCount && pageCount > 0
                  ? Colors.green.shade700
                  : Theme.of(context).colorScheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── 右侧工具栏 ──────────────────────────────────────────────────────────────

class _PageStateLegend extends StatelessWidget {
  final Color color;
  final String label;

  const _PageStateLegend({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            border: Border.all(color: color, width: 2),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 2),
        Text(label, style: const TextStyle(fontSize: 9)),
      ],
    );
  }
}

class _EditorToolbar extends StatelessWidget {
  final String viewMode;
  final bool showIndex;
  final bool showCharBox;
  final bool reorderMode;
  final int blockCount;
  final int lineCount;
  final int regionCount;
  final int paragraphCount;
  final ProjectSettings settings;
  final ValueChanged<String> onViewModeChanged;
  final ValueChanged<bool> onShowIndexChanged;
  final ValueChanged<bool> onShowCharBoxChanged;
  final VoidCallback onReorderToggled;
  final VoidCallback? onInferHierarchy;

  const _EditorToolbar({
    required this.viewMode,
    required this.showIndex,
    required this.showCharBox,
    required this.reorderMode,
    required this.blockCount,
    required this.lineCount,
    this.regionCount = 0,
    this.paragraphCount = 0,
    required this.settings,
    required this.onViewModeChanged,
    required this.onShowIndexChanged,
    required this.onShowCharBoxChanged,
    required this.onReorderToggled,
    this.onInferHierarchy,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // view mode toggle
          const Text(
            '视图',
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          // 视图切换：四个标注视图走分段按钮；「文本」视图单列整宽按钮
          // （五个分段挤不进工具栏宽度——实测 RenderFlex 右溢 11px）。
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'region', label: Text('主区')),
              ButtonSegment(value: 'paragraph', label: Text('段')),
              ButtonSegment(value: 'line', label: Text('行')),
              ButtonSegment(value: 'char', label: Text('详细')),
            ],
            selected: viewMode == 'text' ? const <String>{} : {viewMode},
            // 文本视图无对应分段：允许空选中（否则断言崩溃
            // 'selected.length > 0 || emptySelectionAllowed'）
            emptySelectionAllowed: true,
            onSelectionChanged: (s) {
              if (s.isNotEmpty) onViewModeChanged(s.first);
            },
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: viewMode == 'text'
                ? FilledButton.icon(
                    onPressed: () => onViewModeChanged('line'),
                    icon: const Icon(Icons.notes, size: 16),
                    label: const Text('退出文本视图'),
                  )
                : OutlinedButton.icon(
                    onPressed: () => onViewModeChanged('text'),
                    icon: const Icon(Icons.notes, size: 16),
                    label: const Text('整页文本（直读）'),
                  ),
          ),
          const SizedBox(height: 12),

          // toggles
          _ToggleRow(
            label: '显示序号',
            value: showIndex,
            onChanged: onShowIndexChanged,
          ),
          const SizedBox(height: 4),
          _ToggleRow(
            label: '显示字框',
            value: showCharBox,
            onChanged: onShowCharBoxChanged,
          ),
          const SizedBox(height: 12),

          // reorder button
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onReorderToggled,
              icon: Icon(reorderMode ? Icons.close : Icons.touch_app),
              label: Text(
                reorderMode
                    ? '取消排序'
                    : viewMode == 'region' || viewMode == 'char'
                    ? '行排序'
                    : '点击排序',
              ),
              style: reorderMode
                  ? FilledButton.styleFrom(backgroundColor: Colors.green)
                  : null,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '方向：${settings.horizontalDir == 'rtl' ? '右→左' : '左→右'}'
            ' / ${settings.verticalDir == 'btt' ? '下→上' : '上→下'}',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),

          const SizedBox(height: 8),
          const Divider(height: 1),
          const SizedBox(height: 4),
          Text(
            '$regionCount 主区 · $paragraphCount 段\n$lineCount 行 · $blockCount 字',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          if (onInferHierarchy != null) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onInferHierarchy,
                icon: const Icon(Icons.auto_fix_high, size: 16),
                label: const Text('自动推断层级'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ToggleRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
        SizedBox(
          height: 28,
          child: Switch(value: value, onChanged: onChanged),
        ),
      ],
    );
  }
}

// ─── 标注 Canvas ──────────────────────────────────────────────────────────────

class _AnnotationCanvas extends StatefulWidget {
  final String imagePath;
  final List<MainRegion> mainRegions;
  final List<Paragraph> paragraphs;
  final List<LineBlock> lines;
  final List<CharBlock> blocks;
  final CharBlock? selected;
  final LineBlock? selectedLine;
  final MainRegion? selectedRegion;
  final Paragraph? selectedParagraph;
  final String viewMode; // 'region' | 'paragraph' | 'line' | 'char'
  final bool showIndex;
  final bool showCharBox;
  final bool reorderMode;
  final Map<String, int> pendingLineOrder;
  final Map<String, int> pendingParagraphOrder;
  final ValueChanged<CharBlock?> onSelect;
  final ValueChanged<CharBlock> onAdd;
  final ValueChanged<LineBlock> onAddLine;
  final ValueChanged<LineBlock?> onSelectLine;
  final ValueChanged<LineBlock> onReorderLine;
  final ValueChanged<Paragraph> onReorderParagraph;
  final void Function(CharBlock old, CharBlock updated) onUpdate;
  final ValueChanged<MainRegion> onAddRegion;
  final ValueChanged<MainRegion?> onSelectRegion;
  final void Function(MainRegion old, MainRegion updated) onUpdateRegion;

  /// region 视图拖拽新画的主区框带的类别（父层「新框类别」选择）。
  final String newRegionLabel;

  /// 参与多类互证冲突的区域 id（编辑器层从 annotation.regionConflicts
  /// 算出，画布只管画红色警示描边）。
  final Set<String> regionConflictedIds;
  final ValueChanged<Paragraph> onAddParagraph;
  final ValueChanged<Paragraph?> onSelectParagraph;
  final void Function(Paragraph old, Paragraph updated) onUpdateParagraph;
  final void Function(LineBlock old, LineBlock updated) onUpdateLine;
  final VoidCallback? onGeometryEditEnd;

  /// 图像解码完成（换页/重解码后触发）：父层用于把标注几何钳回图片
  /// 范围（修复旧数据越界的主区框等）。
  final ValueChanged<Size>? onImageReady;

  /// 框选导出模式（Excalidraw）：拖拽不建框，松手把选区（图像坐标）
  /// 回调给调用方。优先级高于各视图的"画新框"分发。
  final bool pickRegion;
  final ValueChanged<Rect>? onPickRegion;

  /// 编号条「定位」：非空时画布按当前缩放把该框平移到视口中心
  /// （[focusSeq] 变化触发，同框重复点击也生效）。
  final Rect? focusRect;
  final int focusSeq;

  /// 图像就地改写版本（旋转/镜像后变化触发重新解码，路径不变）。
  final int imageRevision;

  const _AnnotationCanvas({
    required this.imagePath,
    this.imageRevision = 0,
    required this.lines,
    required this.blocks,
    required this.selected,
    required this.selectedLine,
    required this.viewMode,
    required this.showIndex,
    required this.showCharBox,
    required this.onSelect,
    required this.onAdd,
    required this.onAddLine,
    required this.onSelectLine,
    required this.onReorderLine,
    required this.onReorderParagraph,
    required this.onUpdate,
    this.reorderMode = false,
    this.pendingLineOrder = const {},
    this.pendingParagraphOrder = const {},
    this.mainRegions = const [],
    this.paragraphs = const [],
    this.selectedRegion,
    this.selectedParagraph,
    this.onAddRegion = _noopAddRegion,
    this.onSelectRegion = _noopSelectRegion,
    this.onUpdateRegion = _noopUpdateRegion,
    this.newRegionLabel = RegionLabel.mainText,
    this.regionConflictedIds = const {},
    this.onAddParagraph = _noopAddParagraph,
    this.onSelectParagraph = _noopSelectParagraph,
    this.onUpdateParagraph = _noopUpdateParagraph,
    this.onUpdateLine = _noopUpdateLine,
    this.onGeometryEditEnd,
    this.onImageReady,
    this.pickRegion = false,
    this.onPickRegion,
    this.focusRect,
    this.focusSeq = 0,
  });

  static void _noopAddRegion(MainRegion r) {}
  static void _noopSelectRegion(MainRegion? r) {}
  static void _noopUpdateRegion(MainRegion a, MainRegion b) {}
  static void _noopAddParagraph(Paragraph p) {}
  static void _noopSelectParagraph(Paragraph? p) {}
  static void _noopUpdateParagraph(Paragraph a, Paragraph b) {}
  static void _noopUpdateLine(LineBlock a, LineBlock b) {}

  @override
  State<_AnnotationCanvas> createState() => _AnnotationCanvasState();
}

class _AnnotationCanvasState extends State<_AnnotationCanvas> {
  final TransformationController _transform = TransformationController();

  /// 编号条「定位」待处理框：focusSeq 变化时记录，build 里按当前缩放
  /// 平移把该框居中呈现（不改缩放比例，尊重"翻页保留缩放"）。
  Rect? _pendingFocusRect;

  /// 换图（翻页/旋转/镜像）前抓下来的缩放比例：新图按同一比例居中呈现，
  /// 不再打回整页适配——逐页放大校对时翻页保留缩放（用户反馈）。
  /// null = 没有可沿用的缩放（首次进入，走适配）。平移位置不保留：
  /// 新页总是从居中开始。
  double? _carriedScale;

  Offset? _dragStart;
  Offset? _dragCurrent;

  CharBlock? _dragging;
  Offset? _dragOffset;

  CharBlock? _resizing;
  AnnotationResizeHandle? _resizeHandle;
  // Pointer offset from the visual handle center.  Keeping this offset while
  // dragging prevents the rectangle corner from jumping when the user clicks
  // anywhere inside the (larger) hit target rather than its exact center.
  Offset? _resizePointerOffset;
  // Snapshot taken on pointer-down.  Resize calculations must always use the
  // same opposite edges; using the object updated on the previous pointer
  // event makes the anchored side drift after repeated integer rounding.
  Rect? _resizeOriginalRect;

  // region/paragraph dragging
  MainRegion? _draggingRegion;
  Offset? _dragRegionOffset;
  MainRegion? _resizingRegion;
  AnnotationResizeHandle? _regionResizeHandle;

  Paragraph? _draggingParagraph;
  Offset? _dragParaOffset;
  Paragraph? _resizingParagraph;
  AnnotationResizeHandle? _paragraphResizeHandle;

  // line dragging (line view: move / resize existing line boxes)
  LineBlock? _draggingLine;
  Offset? _dragLineOffset;
  LineBlock? _resizingLine;
  AnnotationResizeHandle? _lineResizeHandle;

  bool _panning = false;
  Offset? _panLast;

  Size _imageSize = Size.zero;
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    _loadImageSize();
  }

  @override
  void dispose() {
    // 页面退出/画布子树被移除时释放变换控制器与页面图像的 native 纹理
    // （此前两者都随 State 一起泄漏）。
    _transform.dispose();
    _image?.dispose();
    _image = null;
    super.dispose();
  }

  @override
  void didUpdateWidget(_AnnotationCanvas old) {
    super.didUpdateWidget(old);
    if (widget.focusSeq != old.focusSeq && widget.focusRect != null) {
      _pendingFocusRect = widget.focusRect;
    }
    if (old.imagePath != widget.imagePath ||
        old.imageRevision != widget.imageRevision) {
      // 重置前先抓当前缩放比例。恒等矩阵（上一次换图后还没首帧渲染）
      // 不覆盖已抓的值：连续翻页快于图像解码时，沿用的仍是上一页比例。
      if (!_transform.value.isIdentity()) {
        _carriedScale = matrixXyScale(_transform.value);
      }
      setState(() {
        _image?.dispose(); // 旧页纹理随之释放，翻百页不累积 native 内存
        _image = null;
        _imageSize = Size.zero;
        _transform.value = Matrix4.identity();
      });
      _loadImageSize();
    }
  }

  Future<void> _loadImageSize() async {
    final path = widget.imagePath;
    final bytes = await File(path).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final img = frame.image;
    // 解码期间又翻了页：晚到的旧图尺寸不能回调出去——上层会拿它钳制
    // 当前页标注的几何并落盘（快速翻页时把主区改小的另一个入口）。
    if (!mounted || path != widget.imagePath) {
      img.dispose();
      return;
    }
    setState(() {
      _image = img;
      _imageSize = Size(img.width.toDouble(), img.height.toDouble());
    });
    widget.onImageReady?.call(_imageSize);
  }

  Offset _toImage(Offset screenPos) {
    final inv = Matrix4.inverted(_transform.value);
    return MatrixUtils.transformPoint(inv, screenPos);
  }

  /// 把图像坐标矩形钳回图片范围（识别框不得画出/拖出页面图片）。
  Rect _clampRectToImage(Rect r) {
    final w = _imageSize.width;
    final h = _imageSize.height;
    if (w <= 0 || h <= 0) return r;
    final left = r.left.clamp(0.0, w);
    final top = r.top.clamp(0.0, h);
    final right = r.right.clamp(left, w);
    final bottom = r.bottom.clamp(top, h);
    return Rect.fromLTRB(left, top, right, bottom);
  }

  /// "中心跟随指针"的移动限制在图片内（保持宽高，钳左上角；框比图片
  /// 还宽时钳到 0）。
  Offset _clampMovePos(Offset pos, int w, int h) {
    final imgW = _imageSize.width;
    final imgH = _imageSize.height;
    if (imgW <= 0 || imgH <= 0) return pos;
    final maxX = max(0.0, imgW - w);
    final maxY = max(0.0, imgH - h);
    return Offset(pos.dx.clamp(0.0, maxX), pos.dy.clamp(0.0, maxY));
  }

  /// Convert a screen-space minimum target to image pixels.  The image is
  /// commonly zoomed out to fit the editor, so a 22px image target can become
  /// only a few physical pixels and is effectively impossible to click.
  // getMaxScaleOnAxis 会把恒为 1 的 z 轴当最大值永远返回 1.0（缩放矩阵
  // 只缩 x/y），必须取 x/y 轴——否则"屏幕像素目标 → 图像像素"的换算
  // 恒按 1:1，缩小视图里命中目标过小。
  double get _screenScale =>
      matrixXyScale(_transform.value).clamp(0.01, double.infinity).toDouble();

  CharBlock? _hitTestBlock(Offset imgPos) {
    final blocks = widget.blocks.toList(growable: false);
    final rects = blocks
        .map(
          (b) => Rect.fromLTWH(
            b.x.toDouble(),
            b.y.toDouble(),
            b.w.toDouble(),
            b.h.toDouble(),
          ),
        )
        .toList(growable: false);
    final index = AnnotationHitGeometry.hitRectIndex(
      rects,
      imgPos,
      scaleX: _screenScale,
    );
    return index == null ? null : blocks[index];
  }

  LineBlock? _hitTestLine(Offset imgPos) {
    for (final l in widget.lines) {
      final r = Rect.fromLTWH(
        l.x.toDouble(),
        l.y.toDouble(),
        l.w.toDouble(),
        l.h.toDouble(),
      );
      if (r.contains(imgPos)) return l;
    }
    return null;
  }

  MainRegion? _hitTestRegion(Offset imgPos) {
    for (final r in widget.mainRegions.reversed) {
      final rect = Rect.fromLTWH(
        r.x.toDouble(),
        r.y.toDouble(),
        r.w.toDouble(),
        r.h.toDouble(),
      );
      if (rect.contains(imgPos)) return r;
    }
    return null;
  }

  Paragraph? _hitTestParagraph(Offset imgPos) {
    for (final p in widget.paragraphs.reversed) {
      final rect = Rect.fromLTWH(
        p.x.toDouble(),
        p.y.toDouble(),
        p.w.toDouble(),
        p.h.toDouble(),
      );
      if (rect.contains(imgPos)) return p;
    }
    return null;
  }

  Rect _objectRect({
    required int x,
    required int y,
    required int w,
    required int h,
  }) => Rect.fromLTWH(x.toDouble(), y.toDouble(), w.toDouble(), h.toDouble());

  AnnotationResizeHandle? _resizeHandleAt(
    Rect rect,
    Offset imgPos,
    double size,
  ) => AnnotationHitGeometry.hitResizeHandle(
    rect,
    imgPos,
    scale: _screenScale,
    imageHitSize: size,
  );

  Offset _resizeHandleCenter(Rect rect, AnnotationResizeHandle handle) =>
      AnnotationHitGeometry.handleCenter(rect, handle);

  Rect _resizeRectFromHandle(
    Rect original,
    Offset imgPos,
    AnnotationResizeHandle handle, {
    required double minSize,
  }) {
    return AnnotationHitGeometry.resizeRect(
      original,
      imgPos,
      handle,
      pointerOffset: _resizePointerOffset ?? Offset.zero,
      minSize: minSize,
    );
  }

  AnnotationResizeHandle? _blockResizeHandle(CharBlock b, Offset imgPos) =>
      _resizeHandleAt(_objectRect(x: b.x, y: b.y, w: b.w, h: b.h), imgPos, 22);

  AnnotationResizeHandle? _regionResizeHandleAt(MainRegion r, Offset imgPos) =>
      _resizeHandleAt(_objectRect(x: r.x, y: r.y, w: r.w, h: r.h), imgPos, 28);

  AnnotationResizeHandle? _paragraphResizeHandleAt(
    Paragraph p,
    Offset imgPos,
  ) => _resizeHandleAt(_objectRect(x: p.x, y: p.y, w: p.w, h: p.h), imgPos, 28);

  AnnotationResizeHandle? _lineResizeHandleAt(LineBlock l, Offset imgPos) =>
      _resizeHandleAt(_objectRect(x: l.x, y: l.y, w: l.w, h: l.h), imgPos, 28);

  void _zoomAt(Offset focalPoint, double scaleDelta) {
    final current = _transform.value.clone();
    // 同上：必须取 x/y 轴缩放，否则 currentScale 恒 1.0，滚轮缩放的
    // 增量被当成绝对缩放（每档直接跳到 scaleDelta 倍）。
    final currentScale = matrixXyScale(current);
    final targetScale = (currentScale * scaleDelta).clamp(0.05, 8.0);
    final effectiveDelta = targetScale / currentScale;
    final scenePoint = _toImage(focalPoint);
    setState(() {
      _transform.value = current
        ..translateByDouble(scenePoint.dx, scenePoint.dy, 0, 1)
        ..scaleByDouble(effectiveDelta, effectiveDelta, 1, 1)
        ..translateByDouble(-scenePoint.dx, -scenePoint.dy, 0, 1);
    });
  }

  void _panBy(Offset delta) {
    setState(() {
      _transform.value = _transform.value.clone()
        ..translateByDouble(delta.dx, delta.dy, 0, 1);
    });
  }

  void _clearPointerState() {
    _dragStart = null;
    _dragCurrent = null;
    _dragging = null;
    _dragOffset = null;
    _resizing = null;
    _resizeHandle = null;
    _resizePointerOffset = null;
    _resizeOriginalRect = null;
    _draggingRegion = null;
    _dragRegionOffset = null;
    _resizingRegion = null;
    _regionResizeHandle = null;
    _draggingParagraph = null;
    _dragParaOffset = null;
    _resizingParagraph = null;
    _paragraphResizeHandle = null;
    _draggingLine = null;
    _dragLineOffset = null;
    _resizingLine = null;
    _lineResizeHandle = null;
    _panning = false;
    _panLast = null;
  }

  /// true when the user is allowed to edit individual char blocks
  bool get _canEditChars => !widget.reorderMode && widget.viewMode == 'char';

  /// true when the user is allowed to draw new line boxes in line view
  /// （重识别在后台队列进行，不禁止画框：新框识别会入队依次执行）
  bool get _canDrawNewLine => !widget.reorderMode && widget.viewMode == 'line';

  /// 主区/段落编辑不再被重识别阻塞：识别在后台队列进行，改动会以最新
  /// 几何重新入队（同目标替换、结果作废旧任务）。
  bool get _canEditRegion => !widget.reorderMode && widget.viewMode == 'region';

  bool get _canEditParagraph =>
      !widget.reorderMode && widget.viewMode == 'paragraph';

  @override
  Widget build(BuildContext context) {
    if (_imageSize == Size.zero) {
      return const Center(child: CircularProgressIndicator());
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (_transform.value.isIdentity()) {
          // 无沿用比例（首次进入）→ 整页适配；有 → 上一页的缩放比例。
          _transform.value = canvasInitialMatrix(
            viewportWidth: constraints.maxWidth,
            viewportHeight: constraints.maxHeight,
            imageWidth: _imageSize.width,
            imageHeight: _imageSize.height,
            carriedScale: _carriedScale,
          );
        }
        // 编号条定位：按当前缩放把目标框平移到视口中心（不改缩放）。
        final focus = _pendingFocusRect;
        if (focus != null) {
          _pendingFocusRect = null;
          final scale = matrixXyScale(_transform.value);
          _transform.value = Matrix4.identity()
            ..translateByDouble(
              constraints.maxWidth / 2 - focus.center.dx * scale,
              constraints.maxHeight / 2 - focus.center.dy * scale,
              0,
              1,
            )
            ..scaleByDouble(scale, scale, 1, 1);
        }

        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerSignal: (signal) {
            if (signal is PointerScrollEvent) {
              _zoomAt(
                signal.localPosition,
                signal.scrollDelta.dy > 0 ? 0.9 : 1.1,
              );
            }
          },
          onPointerDown: (e) {
            // right-button: always pan
            if (e.buttons == kSecondaryMouseButton) {
              setState(() {
                _clearPointerState();
                _panning = true;
                _panLast = e.localPosition;
              });
              return;
            }
            if (e.buttons != kPrimaryMouseButton) return;

            final imgPos = _toImage(e.localPosition);

            // line view + reorder mode: click lines to assign temporary order
            if (widget.viewMode == 'line' && widget.reorderMode) {
              final hit = _hitTestLine(imgPos);
              if (hit != null) widget.onReorderLine(hit);
              return;
            }
            if (widget.viewMode == 'paragraph' && widget.reorderMode) {
              final hit = _hitTestParagraph(imgPos);
              if (hit != null) widget.onReorderParagraph(hit);
              return;
            }

            // line view: click to select / drag / resize line, or draw a new line.
            // 重识别期间不禁止编辑：改动按最新几何重新入队并作废旧任务
            // （见 _enqueueCascade），正在识别的行被再次调整时结果会被丢弃。
            if (widget.viewMode == 'line') {
              // Handle targets extend beyond the box edge.  Check the
              // selected object's handles before the regular box hit test so
              // clicking the outside half of a corner still resizes it.
              final selectedLine = widget.selectedLine;
              final hit =
                  (selectedLine != null &&
                      _lineResizeHandleAt(selectedLine, imgPos) != null)
                  ? selectedLine
                  : _hitTestLine(imgPos);
              if (hit != null) {
                widget.onSelectLine(hit);
                final handle = _lineResizeHandleAt(hit, imgPos);
                if (handle != null) {
                  setState(() {
                    _resizingLine = hit;
                    _lineResizeHandle = handle;
                    final rect = _objectRect(
                      x: hit.x,
                      y: hit.y,
                      w: hit.w,
                      h: hit.h,
                    );
                    _resizeOriginalRect = rect;
                    _resizePointerOffset =
                        imgPos - _resizeHandleCenter(rect, handle);
                  });
                } else {
                  setState(() {
                    _draggingLine = hit;
                    _dragLineOffset =
                        imgPos - Offset(hit.x.toDouble(), hit.y.toDouble());
                  });
                }
              } else {
                widget.onSelectLine(null);
                setState(() {
                  _dragStart = imgPos;
                  _dragCurrent = imgPos;
                });
              }
              return;
            }

            // region view: click to select / drag / resize region（重识别期间可继续编辑）
            if (widget.viewMode == 'region') {
              final selectedRegion = widget.selectedRegion;
              final hit =
                  (selectedRegion != null &&
                      _regionResizeHandleAt(selectedRegion, imgPos) != null)
                  ? selectedRegion
                  : _hitTestRegion(imgPos);
              if (hit != null) {
                widget.onSelectRegion(hit);
                final handle = _regionResizeHandleAt(hit, imgPos);
                if (handle != null) {
                  setState(() {
                    _resizingRegion = hit;
                    _regionResizeHandle = handle;
                    final rect = _objectRect(
                      x: hit.x,
                      y: hit.y,
                      w: hit.w,
                      h: hit.h,
                    );
                    _resizeOriginalRect = rect;
                    _resizePointerOffset =
                        imgPos - _resizeHandleCenter(rect, handle);
                  });
                } else {
                  setState(() {
                    _draggingRegion = hit;
                    _dragRegionOffset =
                        imgPos - Offset(hit.x.toDouble(), hit.y.toDouble());
                  });
                }
              } else {
                widget.onSelectRegion(null);
                setState(() {
                  _dragStart = imgPos;
                  _dragCurrent = imgPos;
                });
              }
              return;
            }

            // paragraph view: click to select / drag / resize paragraph（重识别期间可继续编辑）
            if (widget.viewMode == 'paragraph') {
              final selectedParagraph = widget.selectedParagraph;
              final hit =
                  (selectedParagraph != null &&
                      _paragraphResizeHandleAt(selectedParagraph, imgPos) !=
                          null)
                  ? selectedParagraph
                  : _hitTestParagraph(imgPos);
              if (hit != null) {
                widget.onSelectParagraph(hit);
                final handle = _paragraphResizeHandleAt(hit, imgPos);
                if (handle != null) {
                  setState(() {
                    _resizingParagraph = hit;
                    _paragraphResizeHandle = handle;
                    final rect = _objectRect(
                      x: hit.x,
                      y: hit.y,
                      w: hit.w,
                      h: hit.h,
                    );
                    _resizeOriginalRect = rect;
                    _resizePointerOffset =
                        imgPos - _resizeHandleCenter(rect, handle);
                  });
                } else {
                  setState(() {
                    _draggingParagraph = hit;
                    _dragParaOffset =
                        imgPos - Offset(hit.x.toDouble(), hit.y.toDouble());
                  });
                }
              } else {
                widget.onSelectParagraph(null);
                setState(() {
                  _dragStart = imgPos;
                  _dragCurrent = imgPos;
                });
              }
              return;
            }

            // char view: select / drag / resize
            final selectedBlock = widget.selected;
            final hit =
                (selectedBlock != null &&
                    _blockResizeHandle(selectedBlock, imgPos) != null)
                ? selectedBlock
                : _hitTestBlock(imgPos);
            if (hit != null) {
              final handle = _blockResizeHandle(hit, imgPos);
              if (handle != null) {
                PythonService.addAppLog(
                  '[手势] 页面画布字框缩放开始 char=${hit.id} '
                  'lineId=${hit.lineId} handle=$handle '
                  'rect=(${hit.x},${hit.y},${hit.w},${hit.h})',
                );
                setState(() {
                  _resizing = hit;
                  _resizeHandle = handle;
                  final rect = _objectRect(
                    x: hit.x,
                    y: hit.y,
                    w: hit.w,
                    h: hit.h,
                  );
                  _resizeOriginalRect = rect;
                  _resizePointerOffset =
                      imgPos - _resizeHandleCenter(rect, handle);
                });
              } else {
                setState(() {
                  _dragging = hit;
                  _dragOffset =
                      imgPos - Offset(hit.x.toDouble(), hit.y.toDouble());
                });
              }
              widget.onSelect(hit);
            } else {
              setState(() {
                _dragStart = imgPos;
                _dragCurrent = imgPos;
              });
              widget.onSelect(null);
            }
          },
          onPointerMove: (e) {
            if (_panning && _panLast != null) {
              _panBy(e.localPosition - _panLast!);
              _panLast = e.localPosition;
              return;
            }
            if (e.buttons != kPrimaryMouseButton) return;

            if (!_canEditChars &&
                !_canDrawNewLine &&
                !_canEditRegion &&
                !_canEditParagraph) {
              return;
            }

            final imgPos = _toImage(e.localPosition);
            if (_resizing != null && _resizeHandle != null) {
              final b = _resizing!;
              final resized = _clampRectToImage(
                _resizeRectFromHandle(
                  _resizeOriginalRect ??
                      _objectRect(x: b.x, y: b.y, w: b.w, h: b.h),
                  imgPos,
                  _resizeHandle!,
                  minSize: 10,
                ),
              );
              final updated = b.copyWith(
                x: resized.left.toInt(),
                y: resized.top.toInt(),
                w: resized.width.toInt(),
                h: resized.height.toInt(),
              );
              widget.onUpdate(b, updated);
              setState(() => _resizing = updated);
            } else if (_dragging != null && _dragOffset != null) {
              final b = _dragging!;
              final clampedPos = _clampMovePos(
                Offset(
                  imgPos.dx - _dragOffset!.dx,
                  imgPos.dy - _dragOffset!.dy,
                ),
                b.w,
                b.h,
              );
              final newX = clampedPos.dx.toInt();
              final newY = clampedPos.dy.toInt();
              final updated = b.copyWith(x: newX, y: newY);
              widget.onUpdate(b, updated);
              setState(() => _dragging = updated);
            } else if (_resizingRegion != null && _regionResizeHandle != null) {
              final r = _resizingRegion!;
              final resized = _clampRectToImage(
                _resizeRectFromHandle(
                  _resizeOriginalRect ??
                      _objectRect(x: r.x, y: r.y, w: r.w, h: r.h),
                  imgPos,
                  _regionResizeHandle!,
                  minSize: 20,
                ),
              );
              final updated = MainRegion(
                id: r.id,
                x: resized.left.toInt(),
                y: resized.top.toInt(),
                w: resized.width.toInt(),
                h: resized.height.toInt(),
                label: r.label,
                status: r.status,
                boxConfirmed: r.boxConfirmed,
                uid: r.uid,
              );
              widget.onUpdateRegion(r, updated);
              setState(() => _resizingRegion = updated);
            } else if (_draggingRegion != null && _dragRegionOffset != null) {
              final r = _draggingRegion!;
              final clampedPos = _clampMovePos(
                Offset(
                  imgPos.dx - _dragRegionOffset!.dx,
                  imgPos.dy - _dragRegionOffset!.dy,
                ),
                r.w,
                r.h,
              );
              final newX = clampedPos.dx.toInt();
              final newY = clampedPos.dy.toInt();
              final updated = MainRegion(
                id: r.id,
                x: newX,
                y: newY,
                w: r.w,
                h: r.h,
                label: r.label,
                status: r.status,
                boxConfirmed: r.boxConfirmed,
                uid: r.uid,
              );
              widget.onUpdateRegion(r, updated);
              setState(() => _draggingRegion = updated);
            } else if (_resizingParagraph != null &&
                _paragraphResizeHandle != null) {
              final p = _resizingParagraph!;
              final resized = _clampRectToImage(
                _resizeRectFromHandle(
                  _resizeOriginalRect ??
                      _objectRect(x: p.x, y: p.y, w: p.w, h: p.h),
                  imgPos,
                  _paragraphResizeHandle!,
                  minSize: 20,
                ),
              );
              final updated = Paragraph(
                id: p.id,
                x: resized.left.toInt(),
                y: resized.top.toInt(),
                w: resized.width.toInt(),
                h: resized.height.toInt(),
                mainRegionId: p.mainRegionId,
                lineIds: p.lineIds,
                type: p.type,
                manual: true,
                status: p.status,
                boxConfirmed: p.boxConfirmed,
                uid: p.uid,
              );
              widget.onUpdateParagraph(p, updated);
              setState(() => _resizingParagraph = updated);
            } else if (_draggingParagraph != null && _dragParaOffset != null) {
              final p = _draggingParagraph!;
              final clampedPos = _clampMovePos(
                Offset(
                  imgPos.dx - _dragParaOffset!.dx,
                  imgPos.dy - _dragParaOffset!.dy,
                ),
                p.w,
                p.h,
              );
              final newX = clampedPos.dx.toInt();
              final newY = clampedPos.dy.toInt();
              final updated = Paragraph(
                id: p.id,
                x: newX,
                y: newY,
                w: p.w,
                h: p.h,
                mainRegionId: p.mainRegionId,
                lineIds: p.lineIds,
                type: p.type,
                manual: true,
                status: p.status,
                boxConfirmed: p.boxConfirmed,
                uid: p.uid,
              );
              widget.onUpdateParagraph(p, updated);
              setState(() => _draggingParagraph = updated);
            } else if (_resizingLine != null && _lineResizeHandle != null) {
              final l = _resizingLine!;
              final resized = _clampRectToImage(
                _resizeRectFromHandle(
                  _resizeOriginalRect ??
                      _objectRect(x: l.x, y: l.y, w: l.w, h: l.h),
                  imgPos,
                  _lineResizeHandle!,
                  minSize: 20,
                ),
              );
              final updated = l.copyWith(
                x: resized.left.toInt(),
                y: resized.top.toInt(),
                w: resized.width.toInt(),
                h: resized.height.toInt(),
              );
              widget.onUpdateLine(l, updated);
              setState(() => _resizingLine = updated);
            } else if (_draggingLine != null && _dragLineOffset != null) {
              final l = _draggingLine!;
              final clampedPos = _clampMovePos(
                Offset(
                  imgPos.dx - _dragLineOffset!.dx,
                  imgPos.dy - _dragLineOffset!.dy,
                ),
                l.w,
                l.h,
              );
              final newX = clampedPos.dx.toInt();
              final newY = clampedPos.dy.toInt();
              final updated = l.copyWith(x: newX, y: newY);
              widget.onUpdateLine(l, updated);
              setState(() => _draggingLine = updated);
            } else if (_dragStart != null) {
              setState(() {
                _dragCurrent = Offset(
                  imgPos.dx.clamp(0.0, _imageSize.width),
                  imgPos.dy.clamp(0.0, _imageSize.height),
                );
              });
            }
          },
          onPointerUp: (e) {
            // 区/段/行/单字的拖动或缩放手势结束 → 通知页面触发级联/重识别
            final geometryEdited =
                _dragging != null ||
                _resizing != null ||
                _draggingRegion != null ||
                _resizingRegion != null ||
                _draggingParagraph != null ||
                _resizingParagraph != null ||
                _draggingLine != null ||
                _resizingLine != null;
            if (_resizing != null) {
              final o = _resizeOriginalRect;
              PythonService.addAppLog(
                '[手势] 页面画布字框缩放结束 ${_resizing!.id} '
                '原=(${o?.left.toStringAsFixed(0)},${o?.top.toStringAsFixed(0)},'
                '${o?.width.toStringAsFixed(0)},${o?.height.toStringAsFixed(0)}) '
                '终=(${_resizing!.x},${_resizing!.y},${_resizing!.w},${_resizing!.h})',
              );
            }
            if (_dragStart != null && _dragCurrent != null) {
              // 识别框不得画出页面图片：钳回图片范围
              final r = _clampRectToImage(
                Rect.fromPoints(_dragStart!, _dragCurrent!),
              );
              if (r.width > 8 && r.height > 8) {
                if (widget.pickRegion && widget.onPickRegion != null) {
                  // 框选导出模式：选区交给调用方（Excalidraw 导出），
                  // 不建任何框。
                  widget.onPickRegion!(r);
                } else if (_canEditChars) {
                  final id = 'u_${DateTime.now().millisecondsSinceEpoch}';
                  widget.onAdd(
                    CharBlock(
                      id: id,
                      x: r.left.toInt(),
                      y: r.top.toInt(),
                      w: r.width.toInt(),
                      h: r.height.toInt(),
                      col: 0,
                      order: 0,
                    ),
                  );
                } else if (_canDrawNewLine) {
                  final id = 'manual_${DateTime.now().millisecondsSinceEpoch}';
                  widget.onAddLine(
                    LineBlock(
                      id: id,
                      x: r.left.toInt(),
                      y: r.top.toInt(),
                      w: r.width.toInt(),
                      h: r.height.toInt(),
                      lineNo: 0,
                    ),
                  );
                } else if (_canEditRegion) {
                  widget.onAddRegion(
                    MainRegion(
                      id: '',
                      x: r.left.toInt(),
                      y: r.top.toInt(),
                      w: r.width.toInt(),
                      h: r.height.toInt(),
                      label: widget.newRegionLabel,
                    ),
                  );
                } else if (_canEditParagraph) {
                  widget.onAddParagraph(
                    Paragraph(
                      id: '',
                      x: r.left.toInt(),
                      y: r.top.toInt(),
                      w: r.width.toInt(),
                      h: r.height.toInt(),
                    ),
                  );
                }
              }
            }
            setState(_clearPointerState);
            if (geometryEdited) widget.onGeometryEditEnd?.call();
          },
          onPointerCancel: (e) {
            // 手势被系统中断时几何可能已被改动，同样结束级联，避免脏标记残留
            final geometryEdited =
                _dragging != null ||
                _resizing != null ||
                _draggingRegion != null ||
                _resizingRegion != null ||
                _draggingParagraph != null ||
                _resizingParagraph != null ||
                _draggingLine != null ||
                _resizingLine != null;
            setState(_clearPointerState);
            if (geometryEdited) widget.onGeometryEditEnd?.call();
          },
          child: ClipRect(
            child: SizedBox.expand(
              child: OverflowBox(
                alignment: Alignment.topLeft,
                minWidth: _imageSize.width,
                maxWidth: _imageSize.width,
                minHeight: _imageSize.height,
                maxHeight: _imageSize.height,
                child: Transform(
                  transform: _transform.value,
                  child: SizedBox(
                    width: _imageSize.width,
                    height: _imageSize.height,
                    child: Stack(
                      children: [
                        RawImage(
                          image: _image,
                          width: _imageSize.width,
                          height: _imageSize.height,
                          fit: BoxFit.fill,
                        ),
                        SizedBox(
                          width: _imageSize.width,
                          height: _imageSize.height,
                          child: CustomPaint(
                            painter: _BlockPainter(
                              lines: widget.lines,
                              blocks: widget.blocks,
                              selected: widget.selected,
                              selectedLine: widget.selectedLine,
                              selectedRegion: widget.selectedRegion,
                              selectedParagraph: widget.selectedParagraph,
                              mainRegions: widget.mainRegions,
                              paragraphs: widget.paragraphs,
                              regionConflictedIds: widget.regionConflictedIds,
                              pendingLineOrder: widget.pendingLineOrder,
                              pendingParagraphOrder:
                                  widget.pendingParagraphOrder,
                              viewMode: widget.viewMode,
                              showIndex: widget.showIndex,
                              showCharBox: widget.showCharBox,
                              screenScale: _screenScale,
                              dragRect:
                                  _dragStart != null && _dragCurrent != null
                                  ? Rect.fromPoints(_dragStart!, _dragCurrent!)
                                  : null,
                            ),
                          ),
                        ),
                      ],
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
}

// ─── Painter：行视图 / 字视图 ──────────────────────────────────────────────────

// 行内单字彩虹色板（kCharRainbow/charRainbowColor）已抽出至
// widgets/char_rainbow.dart 共享（直读对照字片复用同一套颜色语义）。

/// [line] 是否与 [lines] 中其它行共享列带（竖排=横向范围重叠、横排=
/// 纵向范围重叠，重叠超过两者中较窄者的 50%）。小字注释列被拆成多段
/// 单行时各段互为共享行：它们的重识别/重切必须禁止"行框外扩到整列
/// 墨迹"，否则两字小注段被外扩吞成整列、整列字框叠到段图上。
bool lineSharesColumnBand(LineBlock line, List<LineBlock> lines) {
  final vertical = line.orientation == 'vertical';
  for (final other in lines) {
    if (identical(other, line) || other.id == line.id) continue;
    if (other.orientation != line.orientation) continue;
    final (a1, a2, b1, b2) = vertical
        ? (line.x, line.x + line.w, other.x, other.x + other.w)
        : (line.y, line.y + line.h, other.y, other.y + other.h);
    final overlap = min(a2, b2) - max(a1, b1);
    final narrower = min(a2 - a1, b2 - b1);
    if (narrower > 0 && overlap > narrower * 0.5) return true;
  }
  return false;
}

/// 行内异常高字框的标记色：比彩虹红更醒目的纯红——"字+标点同框/
/// 两字粘连/单字部件未并"这类高框需要人工复查（对应后端标点拆分
/// 的复查阈值），画布与行卡片统一用它描边。
const Color kTallBoxRed = Color(0xFFFF1744);

/// 同行（竖排列）中位字高；字框少于 3 个时不判定（中位数不稳）。
double? lineMedianCharHeight(List<CharBlock> chars) {
  if (chars.length < 3) return null;
  final heights = chars.map((c) => c.h).toList()..sort();
  return heights[heights.length ~/ 2].toDouble();
}

/// 高度超过本行中位字高 18% 且至少高出 5px（与后端
/// _PUNCT_SPLIT_TALL_RATIO/_PUNCT_SPLIT_MIN_MARGIN 同口径）判为异常高。
bool isTallCharBox(CharBlock char, double? medianH) =>
    medianH != null && char.h > medianH * 1.18 && char.h - medianH > 5;

class _BlockPainter extends CustomPainter {
  final List<MainRegion> mainRegions;
  final List<Paragraph> paragraphs;
  final List<LineBlock> lines;
  final List<CharBlock> blocks;
  final CharBlock? selected;
  final LineBlock? selectedLine;
  final MainRegion? selectedRegion;
  final Paragraph? selectedParagraph;
  final Map<String, int> pendingLineOrder;
  final Map<String, int> pendingParagraphOrder;
  final String viewMode;
  final bool showIndex;
  final bool showCharBox;
  final double screenScale;
  final Rect? dragRect;

  /// 参与多类互证冲突的区域 id（region_conflicts）：region 视图画红色
  /// 警示描边，提示正文区与页眉/页脚/页码区重叠。
  final Set<String> regionConflictedIds;

  _BlockPainter({
    required this.lines,
    required this.blocks,
    required this.selected,
    required this.selectedLine,
    required this.pendingLineOrder,
    required this.pendingParagraphOrder,
    required this.viewMode,
    required this.showIndex,
    required this.showCharBox,
    this.screenScale = 1.0,
    required this.dragRect,
    this.mainRegions = const [],
    this.paragraphs = const [],
    this.selectedRegion,
    this.selectedParagraph,
    this.regionConflictedIds = const {},
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (viewMode == 'region') {
      _paintRegionView(canvas);
    } else if (viewMode == 'paragraph') {
      _paintParagraphView(canvas);
    } else if (viewMode == 'line') {
      _paintLineView(canvas);
    } else if (showCharBox) {
      _paintCharView(canvas);
    }

    _drawDragRect(canvas);
  }

  // ── region view ──

  void _paintRegionView(Canvas canvas) {
    final regionRects = <Rect>[];
    for (var i = 0; i < mainRegions.length; i++) {
      final r = mainRegions[i];
      regionRects.add(
        Rect.fromLTWH(
          r.x.toDouble(),
          r.y.toDouble(),
          r.w.toDouble(),
          r.h.toDouble(),
        ),
      );
    }
    // faint line boxes first（白衬底淡灰线，配色彩页上也能看到参照）
    for (final line in lines) {
      _drawHaloStroke(
        canvas,
        Rect.fromLTWH(
          line.x.toDouble(),
          line.y.toDouble(),
          line.w.toDouble(),
          line.h.toDouble(),
        ),
        Colors.grey.withValues(alpha: 0.35),
        1.0,
        minimumScreen: 1.0,
        haloExtra: 0.75,
        haloAlpha: 0.3,
      );
    }

    for (var i = 0; i < mainRegions.length; i++) {
      final rect = regionRects[i];
      final region = mainRegions[i];
      final isSel = region == selectedRegion;
      // 按类别分色（词表/配色见 RegionLabel）；选中态保持橙色高亮
      final baseColor = RegionLabel.color(RegionLabel.normalize(region.label));
      final color = isSel ? Colors.orange : baseColor;
      // 半透明色块叠加：整个框在书页上呈现明显的同色覆盖层
      canvas.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.fill
          ..color = color.withValues(alpha: isSel ? 0.20 : 0.12),
      );
      _drawHaloStroke(canvas, rect, color, isSel ? 3.5 : 3.0);
      if (showIndex) {
        _drawLabel(
          canvas,
          '${i + 1}',
          rect.topLeft,
          isSel ? Colors.orange : baseColor,
        );
      }
      if (isSel) {
        _drawResizeHandles(canvas, rect, Colors.orange, 22);
      }
      if (regionConflictedIds.contains(region.id)) {
        // 多类互证冲突：红色警示描边（正文区与排除类区重叠）
        _drawHaloStroke(canvas, rect, Colors.red, 2.0);
        _drawLabel(
          canvas,
          '!',
          rect.topRight + const Offset(-20, 2),
          Colors.red,
        );
      }
    }
    _drawOverlapTints(canvas, regionRects);
  }

  // ── paragraph view ──

  void _paintParagraphView(Canvas canvas) {
    // faint line boxes first（白衬底淡灰线，配色彩页上也能看到参照）
    for (final line in lines) {
      _drawHaloStroke(
        canvas,
        Rect.fromLTWH(
          line.x.toDouble(),
          line.y.toDouble(),
          line.w.toDouble(),
          line.h.toDouble(),
        ),
        Colors.grey.withValues(alpha: 0.35),
        1.0,
        minimumScreen: 1.0,
        haloExtra: 0.75,
        haloAlpha: 0.3,
      );
    }

    for (var i = 0; i < paragraphs.length; i++) {
      final p = paragraphs[i];
      final rect = Rect.fromLTWH(
        p.x.toDouble(),
        p.y.toDouble(),
        p.w.toDouble(),
        p.h.toDouble(),
      );
      final isSel = p == selectedParagraph;
      final isAnno = p.type == 'annotation';
      final pendingOrder = pendingParagraphOrder[p.id];
      final hasPendingOrder = pendingOrder != null;
      final emphasized = isSel || hasPendingOrder;
      final color = hasPendingOrder
          ? Colors.indigo
          : (isAnno ? Colors.cyan : Colors.teal);

      // 半透明色块叠加：整个框在书页上呈现明显的同色覆盖层
      canvas.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.fill
          ..color = color.withValues(alpha: emphasized ? 0.22 : 0.12),
      );
      _drawHaloStroke(canvas, rect, color, emphasized ? 3.5 : 2.5);
      if (showIndex && !hasPendingOrder) {
        _drawLabel(
          canvas,
          '${i + 1}',
          rect.topLeft,
          isSel ? Colors.orange : color,
        );
      }
      if (hasPendingOrder) {
        _drawCenterBadge(canvas, '${pendingOrder + 1}', rect.center, color);
      }
      if (isSel && !hasPendingOrder) {
        _drawResizeHandles(canvas, rect, Colors.orange, 22);
      }
    }
    _drawOverlapTints(canvas, [
      for (final p in paragraphs)
        Rect.fromLTWH(
          p.x.toDouble(),
          p.y.toDouble(),
          p.w.toDouble(),
          p.h.toDouble(),
        ),
    ]);
  }

  // ── line view ──

  void _paintLineView(Canvas canvas) {
    // faint char boxes first（白衬底淡灰线，配色彩页上也能看到参照）
    if (showCharBox) {
      for (final line in lines) {
        for (final c in line.chars) {
          _drawHaloStroke(
            canvas,
            Rect.fromLTWH(
              c.x.toDouble(),
              c.y.toDouble(),
              c.w.toDouble(),
              c.h.toDouble(),
            ),
            Colors.grey.withValues(alpha: 0.35),
            0.8,
            minimumScreen: 0.8,
            haloExtra: 0.6,
            haloAlpha: 0.28,
          );
        }
      }
    }

    // line boxes
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final r = Rect.fromLTWH(
        line.x.toDouble(),
        line.y.toDouble(),
        line.w.toDouble(),
        line.h.toDouble(),
      );
      final isSel = line == selectedLine;
      final pendingOrder = pendingLineOrder[line.id];
      final hasPendingOrder = pendingOrder != null;
      final emphasized = isSel || hasPendingOrder;
      // 版面类型行（det 定行打的页眉/页脚/页码/眉批）：按类型配色并
      // 标注类型名（与区域视图同一套 RegionLabel 配色），不再混作正文。
      final typedLabel = line.regionLabel.isEmpty
          ? null
          : RegionLabel.normalize(line.regionLabel);
      final typed = typedLabel != null && typedLabel != RegionLabel.mainText;
      final baseColor = typed ? RegionLabel.color(typedLabel) : Colors.indigo;
      final color = hasPendingOrder
          ? Colors.teal
          : (isSel ? Colors.orange : baseColor);
      // 半透明色块叠加：整个框在书页上呈现明显的同色覆盖层
      canvas.drawRect(
        r,
        Paint()
          ..style = PaintingStyle.fill
          ..color = color.withValues(alpha: emphasized ? 0.22 : 0.12),
      );
      _drawHaloStroke(canvas, r, color, emphasized ? 3.0 : 2.5);
      if (showIndex && !hasPendingOrder) {
        _drawLabel(
          canvas,
          '${i + 1}',
          r.topLeft,
          isSel ? Colors.orange : baseColor,
        );
      }
      if (typed && !hasPendingOrder && !isSel) {
        _drawLabel(
          canvas,
          RegionLabel.displayName(typedLabel),
          r.bottomLeft + const Offset(0, -24),
          baseColor,
        );
      }
      if (hasPendingOrder) {
        _drawCenterBadge(canvas, '${pendingOrder + 1}', r.center, Colors.teal);
      }
      if (isSel && !hasPendingOrder) {
        _drawResizeHandles(canvas, r, Colors.orange, 22);
      }
    }
    _drawOverlapTints(canvas, [
      for (final line in lines)
        Rect.fromLTWH(
          line.x.toDouble(),
          line.y.toDouble(),
          line.w.toDouble(),
          line.h.toDouble(),
        ),
    ]);
  }

  // ── char view ──

  void _paintCharView(Canvas canvas) {
    final selectedPaint = Paint()
      ..style = PaintingStyle.stroke
      ..color = Colors.orange
      ..strokeWidth = 2.5;
    final selectedFill = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.orange.withValues(alpha: 0.15);
    // 已确认状态：原绿描边让位给行内彩虹对应色，改用右上角绿点标记。
    final confirmedDotSize = AnnotationHitGeometry.imageSizeForScreenMinimum(
      8,
      screenScale,
      minimumScreen: 4,
    );
    // 行内异常高字框（字+标点同框/两字粘连等）按 lineId 分组取中位字高，
    // 画布上用醒目红描边提示复查（与行卡片同一判定口径）。
    final charsByLine = <String, List<CharBlock>>{};
    for (final b in blocks) {
      if (b.lineId.isNotEmpty) {
        charsByLine.putIfAbsent(b.lineId, () => []).add(b);
      }
    }
    final medianByLine = <String, double?>{};
    charsByLine.forEach(
      (id, chars) => medianByLine[id] = lineMedianCharHeight(chars),
    );

    for (final b in blocks) {
      final r = Rect.fromLTWH(
        b.x.toDouble(),
        b.y.toDouble(),
        b.w.toDouble(),
        b.h.toDouble(),
      );
      final isSelected = b == selected;
      if (isSelected) {
        canvas.drawRect(r, selectedFill);
        canvas.drawRect(r, selectedPaint);
        _drawResizeHandles(canvas, r, Colors.orange, 12);
        continue;
      }
      final tall = isTallCharBox(b, medianByLine[b.lineId]);
      final verifyColor = verifyFlagColor(b);
      final color = tall ? kTallBoxRed : charRainbowColor(b.order);
      canvas.drawRect(
        r,
        Paint()
          ..style = PaintingStyle.fill
          ..color = color.withValues(alpha: tall ? 0.10 : 0.12),
      );
      if (verifyColor != null) {
        // 墨迹校验标记：虚线框叠加在彩虹框之上（mismatch 红/suspect
        // 琥珀），左上角小圆点强化提示，不与右上角 confirmed 绿点冲突
        _drawDashedRect(
          canvas,
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..color = verifyColor
            ..strokeWidth = 2.5,
        );
        final dot = AnnotationHitGeometry.imageSizeForScreenMinimum(
          7,
          screenScale,
          minimumScreen: 4,
        );
        canvas.drawCircle(
          Offset(r.left + dot / 2 + 2, r.top + dot / 2 + 2),
          dot / 2,
          Paint()..color = verifyColor,
        );
      } else {
        canvas.drawRect(
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..color = color.withValues(alpha: tall ? 1.0 : 0.85)
            ..strokeWidth = tall ? 3.0 : 1.5,
        );
      }
      if (b.confirmed) {
        canvas.drawCircle(
          Offset(r.right - confirmedDotSize / 2, r.top + confirmedDotSize / 2),
          confirmedDotSize / 2,
          Paint()..color = Colors.green.shade600,
        );
      }
      if (b.aiBoxIssue != null && b.aiBoxIssue!.isNotEmpty) {
        // AI 三步分析标记的切分问题（切半/粘字/多墨）：右下角深橙三角
        // 提示复查——不与左上校验点、右上 confirmed 绿点冲突；详情与
        // 「按 AI 标记修复」入口见该字的快捷面板。
        final t = AnnotationHitGeometry.imageSizeForScreenMinimum(
          11,
          screenScale,
          minimumScreen: 6,
        );
        final path = Path()
          ..moveTo(r.right, r.bottom - t)
          ..lineTo(r.right, r.bottom)
          ..lineTo(r.right - t, r.bottom)
          ..close();
        canvas.drawPath(
          path,
          Paint()..color = Colors.deepOrange.withValues(alpha: 0.92),
        );
      }
    }
  }

  // ── helpers ──

  /// 框与框重叠区域的醒目填充（叠加检测）：同层识别框按设计互不重叠，
  /// 主区/段落/行视图里出现红色叠加块即说明有框互相叠加（切分错误或
  /// 手工拖拽越界），便于一眼发现。两两求交 O(n²)——每页框数几十到
  /// 上百，代价可忽略；相交不足 1px（贴边/取整噪声）不算叠加。
  void _drawOverlapTints(Canvas canvas, List<Rect> rects) {
    if (rects.length < 2) return;
    final paint = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.red.withValues(alpha: 0.38);
    for (var i = 0; i < rects.length; i++) {
      for (var j = i + 1; j < rects.length; j++) {
        final inter = rects[i].intersect(rects[j]);
        if (inter.width < 1 || inter.height < 1) continue;
        canvas.drawRect(inter, paint);
      }
    }
  }

  /// 高对比框线：先铺一圈半透明白衬底、再叠全彩实线。彩色细线在深色
  /// 或近似色（如泛黄、青灰）的书页上会融进背景，白衬底在任何底色上
  /// 都形成清晰分界；线宽带屏幕像素下限——此前固定图像像素宽度在整页
  /// 适配的缩小视图里会细成亚像素发丝线，是"看不清"的主因之一。
  /// [strokeWidth] 为 scale=1 时的图像像素宽度。
  void _drawHaloStroke(
    Canvas canvas,
    Rect rect,
    Color color,
    double strokeWidth, {
    double minimumScreen = 2.0,
    double haloExtra = 1.0,
    double haloAlpha = 0.85,
  }) {
    final width = AnnotationHitGeometry.imageSizeForScreenMinimum(
      strokeWidth,
      screenScale,
      minimumScreen: minimumScreen,
    );
    final haloWidth =
        width +
        2 *
            AnnotationHitGeometry.imageSizeForScreenMinimum(
              haloExtra,
              screenScale,
              minimumScreen: 0.75,
            );
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.white.withValues(alpha: haloAlpha)
        ..strokeWidth = haloWidth,
    );
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = color
        ..strokeWidth = width,
    );
  }

  /// 虚线描边矩形（墨迹校验标记用，与 tall-box 实线红框区分）。
  void _drawDashedRect(Canvas canvas, Rect r, Paint paint) {
    final path = Path()..addRect(r);
    for (final metric in path.computeMetrics()) {
      double dist = 0;
      var draw = true;
      while (dist < metric.length) {
        final seg = draw ? 6.0 : 4.0;
        if (draw) {
          canvas.drawPath(metric.extractPath(dist, dist + seg), paint);
        }
        dist += seg;
        draw = !draw;
      }
    }
  }

  void _drawResizeHandles(Canvas canvas, Rect rect, Color color, double size) {
    final paint = Paint()..color = color;
    final visualSize = AnnotationHitGeometry.imageSizeForScreenMinimum(
      size,
      screenScale,
      minimumScreen: 10,
    );
    final centers = [
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
    ];
    for (final center in centers) {
      canvas.drawRect(
        Rect.fromCenter(center: center, width: visualSize, height: visualSize),
        paint,
      );
    }
  }

  void _drawLabel(Canvas canvas, String text, Offset topLeft, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 17,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    const pad = EdgeInsets.symmetric(horizontal: 4, vertical: 2);
    final bgRect = Rect.fromLTWH(
      topLeft.dx,
      topLeft.dy,
      tp.width + pad.horizontal,
      tp.height + pad.vertical,
    );
    // 不透明圆角底 + 白描边：画布缩小或底图文字密集时，编号也保持
    // 高对比可读（此前 13px 半透明底在密集页面上易看不清）。
    final bgRRect = RRect.fromRectAndRadius(bgRect, const Radius.circular(3));
    canvas.drawRRect(
      bgRRect,
      Paint()
        ..style = PaintingStyle.fill
        ..color = color.withValues(alpha: 0.95),
    );
    canvas.drawRRect(
      bgRRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white.withValues(alpha: 0.9),
    );
    tp.paint(canvas, Offset(topLeft.dx + pad.left, topLeft.dy + pad.top));
  }

  void _drawCenterBadge(
    Canvas canvas,
    String text,
    Offset center,
    Color color,
  ) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final radius = max(14.0, max(tp.width, tp.height) / 2 + 6);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.fill
        ..color = color.withValues(alpha: 0.92),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white.withValues(alpha: 0.9),
    );
    tp.paint(
      canvas,
      Offset(center.dx - tp.width / 2, center.dy - tp.height / 2),
    );
  }

  void _drawDragRect(Canvas canvas) {
    if (dragRect != null) {
      canvas.drawRect(
        dragRect!,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = Colors.red
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BlockPainter old) => true;
}

// ─── 右侧属性面板 ─────────────────────────────────────────────────────────────

/// 分区内显示该层已确认数据及模型规模对应的准备进度。
/// 有训练服务的就绪数据时按档位分条显示（n/s/m/l 各一条，已训档位的
/// 目标按轮数进阶，下一个里程碑高亮）；数据不可用时回退到本地静态
/// 目标表的单条进度条。训练数据全局共享：进度条与档位数字用全部书籍
/// 的累计口径（后端 /train/stats 按整个书库聚合，任何书里看到的一致）；
/// 标题下的"本书 N"是本地实时计数，确认后立即变化。
class _LayerProgress extends StatelessWidget {
  final String layer;
  final int instances;
  final int classes;

  /// 训练服务 /train/stats 返回的该层 readiness（可为空）。
  final Map<String, dynamic>? readiness;

  const _LayerProgress({
    required this.layer,
    required this.instances,
    this.classes = 0,
    this.readiness,
  });

  static const _targets = <String, List<int>>{
    'region_det': [30, 90, 180],
    'paragraph_det': [60, 180, 360],
    'line_det': [120, 360, 720],
    'char_det': [300, 900, 1800],
    'char_cls': [500, 1500, 3000],
  };

  static const _tierLabels = <String, String>{
    'yolov8n': 'n',
    'yolov8s': 's',
    'yolov8m': 'm',
    'yolov8l': 'l',
  };

  @override
  Widget build(BuildContext context) {
    final title = switch (layer) {
      'region_det' => '正文区训练数据',
      'paragraph_det' => '自然段训练数据',
      'line_det' => '单行训练数据',
      'char_det' => '单字识别训练数据',
      'char_cls' => '单字候选分类训练数据',
      _ => '训练数据',
    };
    final reqs = readiness?['requirements'] as Map<String, dynamic>?;
    final milestone =
        (readiness?['next_milestone'] as Map<String, dynamic>?)?['model']
            as String?;
    // 训练数据全局共享：readiness 的 instances/classes 由后端按整个书库
    // 聚合（全部书籍累计），进度条与档位数字用它——在任何书里看到的
    // 数量一致；本地实时计数保留为"本书"参考（确认后立即变化）。
    final globalInstances = (readiness?['instances'] as num?)?.toInt();
    final globalClasses = (readiness?['classes'] as num?)?.toInt();
    final hasGlobal = globalInstances != null;
    final barInstances = hasGlobal ? globalInstances : instances;
    final barClasses = hasGlobal ? (globalClasses ?? classes) : classes;
    final tiers = reqs == null
        ? const <String>[]
        : [
            for (final t in _tierLabels.keys)
              if (reqs.containsKey(t)) t,
          ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.indigo.shade50,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            hasGlobal
                ? '全部书籍累计 $barInstances · 本书 $instances'
                : '本书 $instances（训练服务未连接）',
            style: const TextStyle(fontSize: 9.5, color: Colors.grey),
          ),
          const SizedBox(height: 4),
          if (tiers.isEmpty)
            _legacyBody()
          else ...[
            for (final tier in tiers)
              _tierRow(
                tier: tier,
                req: reqs![tier] as Map<String, dynamic>,
                barInstances: barInstances,
                barClasses: barClasses,
                isMilestone: milestone == tier,
              ),
          ],
        ],
      ),
    );
  }

  /// 单档位一行：档位标 · 进度条 · "实例/目标（第 k 轮）"。
  Widget _tierRow({
    required String tier,
    required Map<String, dynamic> req,
    required int barInstances,
    required int barClasses,
    required bool isMilestone,
  }) {
    final round = (req['rounds'] as num?)?.toInt() ?? 1;
    final target = (req['target_instances'] as num?)?.toInt() ?? 0;
    final classTarget = (req['target_classes'] as num?)?.toInt() ?? 0;
    final progress = target > 0 ? (barInstances / target).clamp(0.0, 1.0) : 1.0;
    final classProgress = classTarget > 0
        ? (barClasses / classTarget).clamp(0.0, 1.0)
        : 1.0;
    final ready = min(progress, classProgress) >= 1.0;
    final barColor = ready
        ? Colors.green
        : (isMilestone ? Colors.indigo : Colors.indigo.shade200);
    final label = StringBuffer(
      '$barInstances/$target${round > 1 ? '（第 $round 轮）' : ''}',
    );
    if (classTarget > 0) label.write(' · 字类 $barClasses/$classTarget');
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            child: Text(
              _tierLabels[tier] ?? tier,
              style: TextStyle(
                fontSize: 10.5,
                height: 1.0,
                fontWeight: isMilestone ? FontWeight.w700 : FontWeight.w400,
                color: isMilestone
                    ? Colors.indigo.shade700
                    : Colors.grey.shade600,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: LinearProgressIndicator(
              value: min(progress, classProgress),
              minHeight: 5,
              color: barColor,
              backgroundColor: Colors.indigo.shade100,
            ),
          ),
          const SizedBox(width: 6),
          if (ready)
            Icon(Icons.check_circle, size: 11, color: Colors.green.shade700)
          else if (isMilestone)
            Icon(Icons.flag, size: 11, color: Colors.indigo.shade700),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label.toString(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 9.5,
                height: 1.0,
                color: ready
                    ? Colors.green.shade700
                    : (isMilestone ? Colors.grey.shade800 : Colors.grey),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 训练服务数据不可用时的兜底：单条进度条 + 静态目标（旧版样式）。
  Widget _legacyBody() {
    final t = _targets[layer] ?? const [100, 300, 600];
    final instanceProgress = (instances / t[0]).clamp(0.0, 1.0);
    final classProgress = layer == 'char_cls'
        ? (classes / 50).clamp(0.0, 1.0)
        : 1.0;
    final progress = min(instanceProgress, classProgress);
    final suffix = layer == 'char_cls' ? ' · 字类 $classes/50 · 120 · 240' : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(value: progress),
        const SizedBox(height: 3),
        Text(
          '本书 $instances/${t[0]}（基础模型）$suffix  ·  大模型目标 ${t[1]}/${t[2]}',
          style: const TextStyle(fontSize: 10, color: Colors.grey),
        ),
      ],
    );
  }
}

class _LinePanel extends StatelessWidget {
  final LineBlock line;
  final bool processing;
  final VoidCallback onDelete;
  final VoidCallback onClearAll;
  final Widget progress;

  const _LinePanel({
    required this.line,
    required this.processing,
    required this.onDelete,
    required this.onClearAll,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey.shade50,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            line.id,
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 4),
          Text(
            '行号 ${line.lineNo + 1} · ${line.orientation == "vertical" ? "竖排" : "横排"}',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          const Text(
            '整行文本',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: Colors.grey.shade300),
              borderRadius: BorderRadius.circular(6),
            ),
            child: processing
                ? const Row(
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 8),
                      Text(
                        '拆字识别中…',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  )
                : SelectableText(
                    line.text.isEmpty ? '无识别文本' : line.text,
                    style: TextStyle(
                      fontSize: 14,
                      color: line.text.isEmpty ? Colors.grey : Colors.black87,
                    ),
                  ),
          ),
          const SizedBox(height: 8),
          _row('X', '${line.x}'),
          _row('Y', '${line.y}'),
          _row('W', '${line.w}'),
          _row('H', '${line.h}'),
          _row('字数', '${line.chars.length}'),
          const SizedBox(height: 8),
          progress,
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: processing ? null : onDelete,
            style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除该行 (Del)'),
          ),
          const SizedBox(height: 6),
          OutlinedButton.icon(
            onPressed: processing ? null : onClearAll,
            icon: const Icon(Icons.clear_all),
            label: const Text('清除本页全部行框及单字'),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        SizedBox(
          width: 40,
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
        Text(value, style: const TextStyle(fontSize: 12)),
      ],
    ),
  );
}

// ─── 主区属性面板 ──────────────────────────────────────────────────────────────

class _RegionPanel extends StatelessWidget {
  final MainRegion region;
  final ValueChanged<String> onLabelChanged;
  final VoidCallback onDelete;
  final VoidCallback onClearAll;
  final Widget progress;

  /// 该区域是否参与多类互证冲突（正文区与排除类区重叠）。
  final bool conflicted;

  /// table 类主区打开「识别表格/表格校对」入口（+83）；null = 隐藏。
  final VoidCallback? onOpenTable;

  /// 已有识别结果时按钮文案切到「打开表格校对」。
  final bool hasTableResult;

  const _RegionPanel({
    required this.region,
    required this.onLabelChanged,
    required this.onDelete,
    required this.onClearAll,
    required this.progress,
    this.conflicted = false,
    this.onOpenTable,
    this.hasTableResult = false,
  });

  @override
  Widget build(BuildContext context) {
    final label = RegionLabel.normalize(region.label);
    final color = RegionLabel.color(label);
    return Container(
      color: Colors.grey.shade50,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            region.id,
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 4),
          if (conflicted)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(6),
              color: Colors.red.shade50,
              child: const Text(
                '⚠ 与正文/页眉/页脚/页码区重叠冲突\n建议修正边界或重新预标注',
                style: TextStyle(fontSize: 11, color: Colors.red),
              ),
            ),
          if (conflicted) const SizedBox(height: 6),
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              const Text(
                '类别',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
          DropdownButton<String>(
            value: label,
            isExpanded: true,
            items: [
              for (final l in RegionLabel.all)
                DropdownMenuItem(
                  value: l,
                  child: Text(
                    RegionLabel.displayName(l),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
            ],
            onChanged: (v) {
              if (v != null && v != label) onLabelChanged(v);
            },
          ),
          const SizedBox(height: 8),
          _infoRow('X', '${region.x}'),
          _infoRow('Y', '${region.y}'),
          _infoRow('W', '${region.w}'),
          _infoRow('H', '${region.h}'),
          if (label == RegionLabel.table && onOpenTable != null) ...[
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: onOpenTable,
              icon: const Icon(Icons.grid_on, size: 18),
              label: Text(hasTableResult ? '打开表格校对' : '识别表格'),
            ),
          ],
          const SizedBox(height: 8),
          progress,
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: onDelete,
            style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除该主区 (Del)'),
          ),
          const SizedBox(height: 6),
          OutlinedButton.icon(
            onPressed: onClearAll,
            icon: const Icon(Icons.clear_all),
            label: const Text('清除本页全部正文识别框'),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        SizedBox(
          width: 40,
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
        Text(value, style: const TextStyle(fontSize: 12)),
      ],
    ),
  );
}

// ─── 自然段属性面板 ────────────────────────────────────────────────────────────

class _ParagraphPanel extends StatelessWidget {
  final Paragraph paragraph;
  final VoidCallback onDelete;
  final VoidCallback onClearAll;
  final Widget progress;

  const _ParagraphPanel({
    required this.paragraph,
    required this.onDelete,
    required this.onClearAll,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey.shade50,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            paragraph.id,
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 4),
          Text(
            '类型：${paragraph.type == "annotation" ? "小注段" : "正文段"}',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 4),
          Text(
            '包含 ${paragraph.lineIds.length} 行',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          _infoRow('X', '${paragraph.x}'),
          _infoRow('Y', '${paragraph.y}'),
          _infoRow('W', '${paragraph.w}'),
          _infoRow('H', '${paragraph.h}'),
          const SizedBox(height: 8),
          progress,
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: onDelete,
            style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除该段 (Del)'),
          ),
          const SizedBox(height: 6),
          OutlinedButton.icon(
            onPressed: onClearAll,
            icon: const Icon(Icons.clear_all),
            label: const Text('清除本页全部段、行及单字'),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        SizedBox(
          width: 40,
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
        Text(value, style: const TextStyle(fontSize: 12)),
      ],
    ),
  );
}

// ─── 详细模式：行卡片列表 ──────────────────────────────────────────────────────

class _DetailCardList extends StatefulWidget {
  final String imagePath;

  /// 图像就地改写版本（旋转/镜像后变化触发重新解码，路径不变）。
  final int imageRevision;
  final PageAnnotation annotation;
  final ProjectSettings settings;
  final double cardWidth;
  final double fontSize;
  final CharBlock? selected;
  final String? processingLineId;

  /// 执行中的行级动作（'rerecognize'/'resplit'/'ai-check'）：行卡片
  /// 头部的转圈显示在对应动作按钮上。
  final String? processingLineAction;

  /// 需要滚动定位到的行 id（墨迹归类页"定位"入口设置）；变化或首次
  /// 构建后自动把该行卡片滚到视口上部。focusSeq 每次定位递增，
  /// 定位同一行的不同字时也能触发滚动。
  final String? focusLineId;
  final int focusSeq;

  /// 「定位」后呼吸闪烁的字块 id（行图/字chip/字轨三处同时高亮）。
  final String? flashCharId;
  final void Function(CharBlock old, CharBlock updated) onCharUpdated;
  final ValueChanged<CharBlock> onCharAdded;
  final ValueChanged<CharBlock?> onCharSelected;
  final Future<void> Function(LineBlock line) onRerecognizeLine;

  /// 重新切割该列：丢弃现有字框，对该行做全新拆字 + OCR。
  final Future<void> Function(LineBlock line) onResplitLine;

  /// AI 检查本行（视觉模型诊断 + 重摆 + 置信度裁决）。
  final Future<void> Function(LineBlock line) onAiCheckLine;

  /// 按 AI 切分标记局部修复本行（尾段重摆 + 合并 + AI 复核）。
  final Future<void> Function(LineBlock line) onAiRepairLine;

  /// 被 AI 修复过的行 id（卡片徽章）。
  final Set<String> aiAdjustedLineIds;

  final void Function(LineBlock line, int oldIndex, int newIndex)
  onCharsReordered;

  /// 删除识别框（快捷候选浮层）。
  final void Function(CharBlock c) onCharDeleted;

  const _DetailCardList({
    required this.imagePath,
    this.imageRevision = 0,
    required this.annotation,
    required this.settings,
    required this.cardWidth,
    required this.fontSize,
    required this.selected,
    required this.processingLineId,
    required this.processingLineAction,
    required this.focusLineId,
    required this.focusSeq,
    required this.flashCharId,
    required this.onCharUpdated,
    required this.onCharAdded,
    required this.onCharSelected,
    required this.onRerecognizeLine,
    required this.onResplitLine,
    required this.onAiCheckLine,
    required this.onAiRepairLine,
    required this.aiAdjustedLineIds,
    required this.onCharsReordered,
    required this.onCharDeleted,
  });

  @override
  State<_DetailCardList> createState() => _DetailCardListState();
}

class _DetailCardListState extends State<_DetailCardList> {
  ui.Image? _image;
  Size _imageSize = Size.zero;
  final Map<String, GlobalKey> _lineKeys = {};

  @override
  void initState() {
    super.initState();
    _loadImage();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToFocusLine());
  }

  @override
  void didUpdateWidget(_DetailCardList old) {
    super.didUpdateWidget(old);
    if (old.imagePath != widget.imagePath ||
        old.imageRevision != widget.imageRevision) {
      _image?.dispose(); // 旧页纹理随之释放
      _image = null;
      _imageSize = Size.zero;
      _lineKeys.clear();
      _loadImage();
    }
    if (widget.focusLineId != null && old.focusSeq != widget.focusSeq) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToFocusLine());
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    _image = null;
    super.dispose();
  }

  /// 把 focusLineId 对应的行卡片滚到视口上部（图片加载完成前卡片
  /// 还没 build，_loadImage 成功后再补滚一次）。
  ///
  /// 自动滚动只是辅助交互，绝不能让它崩溃应用：翻页/换标注会让行卡片
  /// 树反复拆建，GlobalKey 拿到的 context 可能恰在停用窗口里（mounted
  /// 仍为 true 但不能查祖先），此时放弃本次滚动即可。
  void _scrollToFocusLine() {
    if (!mounted || widget.focusLineId == null) return;
    final ctx = _lineKeys[widget.focusLineId]?.currentContext;
    if (ctx == null || !ctx.mounted) return;
    try {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
        alignment: 0.12,
      );
    } catch (_) {
      // 行卡片元素处于停用窗口：跳过本次定位滚动。
    }
  }

  Future<void> _loadImage() async {
    final bytes = await File(widget.imagePath).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    if (!mounted) return;
    setState(() {
      _image = frame.image;
      _imageSize = Size(
        frame.image.width.toDouble(),
        frame.image.height.toDouble(),
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToFocusLine());
  }

  @override
  Widget build(BuildContext context) {
    if (_image == null) {
      return const Center(child: CircularProgressIndicator());
    }
    // 横排行卡片单列铺满可用宽度：横排行字数多，多列 Wrap 会把每张卡
    // 压到 1/5 窗口宽、校对文字过小。竖排卡片窄高，保持多列 Wrap。
    // 卡片缩放控制在横排下作为宽度比例使用（放大封顶 100% 防横向溢出）。
    final horizontalLayout = widget.settings.orientation == 'horizontal';
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        final cardW = horizontalLayout && maxW.isFinite && maxW > 0
            ? maxW *
                  (widget.cardWidth / _EditorPageState.kDetailCardBaseWidth)
                      .clamp(0.65, 1.0)
            : widget.cardWidth;
        return SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: horizontalLayout
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (
                      var index = 0;
                      index < widget.annotation.lines.length;
                      index++
                    )
                      Padding(
                        padding: EdgeInsets.only(
                          bottom: index == widget.annotation.lines.length - 1
                              ? 0
                              : 10,
                        ),
                        child: KeyedSubtree(
                          key: _lineKeys.putIfAbsent(
                            widget.annotation.lines[index].id,
                            () => GlobalKey(),
                          ),
                          child: _buildCard(index, cardW),
                        ),
                      ),
                  ],
                )
              : Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (
                      var index = 0;
                      index < widget.annotation.lines.length;
                      index++
                    )
                      KeyedSubtree(
                        key: _lineKeys.putIfAbsent(
                          widget.annotation.lines[index].id,
                          () => GlobalKey(),
                        ),
                        child: _buildCard(index, cardW),
                      ),
                  ],
                ),
        );
      },
    );
  }

  Widget _buildCard(int index, double cardW) {
    final line = widget.annotation.lines[index];
    return _LineCard(
      line: line,
      lineIndex: index,
      image: _image!,
      imageSize: _imageSize,
      imagePath: widget.imagePath,
      cardWidth: cardW,
      fontSize: widget.fontSize,
      selected: widget.selected,
      processingLineId: widget.processingLineId,
      processingLineAction: widget.processingLineAction,
      flashCharId: widget.flashCharId,
      onCharUpdated: widget.onCharUpdated,
      onCharAdded: widget.onCharAdded,
      onCharSelected: widget.onCharSelected,
      onRerecognizeLine: widget.onRerecognizeLine,
      onResplitLine: widget.onResplitLine,
      onAiCheckLine: widget.onAiCheckLine,
      onAiRepairLine: widget.onAiRepairLine,
      aiAdjusted: widget.aiAdjustedLineIds.contains(line.id),
      onCharsReordered: widget.onCharsReordered,
      onCharDeleted: widget.onCharDeleted,
    );
  }
}

// ─── 级联识别任务（编辑页后台队列用） ─────────────────────────────────────────

class _CascadeTask {
  /// 目标键：`region:<id>` / `para:<id>` / `line:<id>` / `char:<id>`。
  /// 同键新任务会替换队列中等待的旧任务；执行中任务靠 gen 判定作废。
  final String key;

  /// 展示用标签（横幅/错误提示）。
  final String label;

  /// 提交代数：与 _cascadeGen[key] 不一致即已过期（结果应丢弃）。
  final int gen;

  /// 行任务携带行 id，行卡片转圈指示用。
  final String? lineId;

  /// 行任务的动作（'rerecognize'/'resplit'/null=通用）：转圈显示在行
  /// 卡片头部对应的动作按钮上。
  final String? lineAction;

  /// 静默任务（单字识别）：不弹顶部横幅——横幅条件插入会把整个界面
  /// 顶下去产生跳动，且单字识别快（秒级）、字块级已有"识别中…"指示。
  final bool silent;

  final Future<void> Function(bool Function() isStale) run;

  /// 后端忙碌（409）时的重试计数。
  int retries = 0;

  _CascadeTask({
    required this.key,
    required this.label,
    required this.gen,
    required this.run,
    this.lineId,
    this.lineAction,
    this.silent = false,
  });
}

// ─── 竖排几何对齐：右侧两列文字与行图中的字框逐字同位 ──────────────────────────

/// 字号控制值相对基准字号的比例，作为几何对齐单元内的"填充系数"：
/// 调字号只改字在单元内的填充比例，不移动单元位置，对齐不会被破坏。
double _verticalAlignFill(double fontPx) =>
    (fontPx / _EditorPageState.kDetailFontBase).clamp(0.3, 1.8);

/// 标准字单元高：全部字框高度的中位数（正文典型字高），大字/小注只占
/// 少数不会拉偏。行高基准、字号、列宽、高度上下限都参照它。
double _verticalStdCell(LineBlock line, double displayHeight) {
  final cells = [for (final c in line.chars) c.h * displayHeight / line.h]
    ..sort();
  if (cells.isEmpty) return displayHeight;
  final mid = cells.length ~/ 2;
  return cells.length.isOdd ? cells[mid] : (cells[mid - 1] + cells[mid]) / 2;
}

/// 竖排字符 c 的显示单元 (top, height)：单元中心锚定在字框真实中心（与
/// 行图逐字对齐），高度限制在 [0.55, 1.15] × 标准单元——极小字框（标点/
/// 残框）抬到下限保证可读可点，异常大字压到上限避免撑爆整列。
(double, double) _verticalCharCell(
  CharBlock c,
  LineBlock line,
  double displayHeight,
  double stdCell,
) {
  final pxPerY = displayHeight / line.h;
  // 单元高不超过列高本身（单字行等退化情形），clamp 下界不超过上界。
  final hi = min(stdCell * 1.15, displayHeight);
  final lo = min(stdCell * 0.55, hi);
  final cellH = (c.h * pxPerY).clamp(lo, hi);
  final center = (c.y + c.h / 2 - line.y) * pxPerY;
  final top = (center - cellH / 2)
      .clamp(0.0, max(0.0, displayHeight - cellH))
      .toDouble();
  return (top, cellH);
}

/// 竖排两列文字的统一列宽：约一个字位（标准单元高）宽，跟随字号放大
/// 但不超过 1.4 倍标准单元，避免出现大片留白。
double _verticalColumnWidth(double stdCell, double fill) {
  final w = stdCell * 0.8 * fill * 1.3;
  final cap = stdCell * 1.4;
  if (w > cap) return cap;
  return w < 28 ? 28 : w;
}

/// 几何对齐列的拖拽落点：指针位置之上覆盖的字中心数（不含被拖字），
/// 与 onReorder 的"移除后插入到目标下标"语义一致。
int _verticalDropIndexFromLocalY(
  LineBlock line,
  double displayHeight,
  double localY,
  int? dragIndex,
) {
  final chars = line.chars;
  if (chars.isEmpty) return 0;
  final pxPerY = displayHeight / line.h;
  var idx = 0;
  for (var j = 0; j < chars.length; j++) {
    if (j == dragIndex) continue;
    final centerY = (chars[j].y + chars[j].h / 2 - line.y) * pxPerY;
    if (localY > centerY) idx++;
  }
  return idx.clamp(0, chars.length - 1);
}

// ─── 横排几何对齐：行卡片改为三条横行（行图 → 字卡行 → 整行文字）───
// 宽度对齐、字卡与行图中的字框逐字同位（竖排三列并排的横向版）。

/// 标准字单元宽：全部字框宽度的中位数（显示坐标）。
double _horizontalStdCell(LineBlock line, double displayWidth) {
  final cells = [for (final c in line.chars) c.w * displayWidth / line.w]
    ..sort();
  if (cells.isEmpty) return displayWidth;
  final mid = cells.length ~/ 2;
  return cells.length.isOdd ? cells[mid] : (cells[mid - 1] + cells[mid]) / 2;
}

/// 横排字符 c 的显示单元 (left, width)：单元中心锚定在字框真实中心
/// （与行图逐字对齐），宽度限制在 [0.55, 1.15] × 标准单元。
(double, double) _horizontalCharCell(
  CharBlock c,
  LineBlock line,
  double displayWidth,
  double stdCell,
) {
  final pxPerX = displayWidth / line.w;
  final hi = min(stdCell * 1.15, displayWidth);
  final lo = min(stdCell * 0.55, hi);
  final cellW = (c.w * pxPerX).clamp(lo, hi);
  final center = (c.x + c.w / 2 - line.x) * pxPerX;
  final left = (center - cellW / 2)
      .clamp(0.0, max(0.0, displayWidth - cellW))
      .toDouble();
  return (left, cellW);
}

/// 横排几何对齐行的拖拽落点：指针位置左侧覆盖的字中心数（不含被拖字）。
int _horizontalDropIndexFromLocalX(
  LineBlock line,
  double displayWidth,
  double localX,
  int? dragIndex,
) {
  final chars = line.chars;
  if (chars.isEmpty) return 0;
  final pxPerX = displayWidth / line.w;
  var idx = 0;
  for (var j = 0; j < chars.length; j++) {
    if (j == dragIndex) continue;
    final centerX = (chars[j].x + chars[j].w / 2 - line.x) * pxPerX;
    if (localX > centerX) idx++;
  }
  return idx.clamp(0, chars.length - 1);
}

// ─── 单行卡片：图像裁切 + 可编辑字列表 + 拼接文本 ───────────────────────────────

/// 「定位」闪烁高亮：包住目标字所在的小部件，激活时以红↔橙交替的
/// 呼吸边框+发光标出，持续到编辑器熄灭（约 10 秒）。竖排行卡片三处
/// （行图字框、字 chip、整行文字字轨）同时套用，扫一眼即可锁定。
class _LocateFlash extends StatefulWidget {
  final bool active;
  final Widget child;

  const _LocateFlash({required this.active, required this.child});

  @override
  State<_LocateFlash> createState() => _LocateFlashState();
}

class _LocateFlashState extends State<_LocateFlash>
    with SingleTickerProviderStateMixin {
  // 必须在 initState 里立即创建，不能写成 late final：从未闪烁过的字块
  // chip 在 build/initState 里不会触碰 late 字段，翻页拆树时 dispose() 里的
  // _controller.dispose() 反而成了第一次访问、当场构造 AnimationController
  // (vsync: this)，其内部经 TickerMode.getNotifier(context) 查祖先——此时
  // 元素已在 unmount（defunct），即抛 "Looking up a deactivated widget's
  // ancestor is unsafe"，每页数百个 chip 翻页时批量触发崩溃。
  AnimationController? _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );
    if (widget.active) _controller!.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_LocateFlash old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      _controller!.repeat(reverse: true);
    } else if (!widget.active && old.active) {
      _controller!.stop();
      _controller!.value = 0;
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return widget.child;
    return AnimatedBuilder(
      animation: _controller!,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_controller!.value);
        final color = Color.lerp(Colors.red, Colors.amber, t)!;
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: color, width: 2.5 + 2.0 * t),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.45 + 0.35 * t),
                blurRadius: 5 + 9 * t,
                spreadRadius: 1 + 2 * t,
              ),
            ],
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

class _LineCard extends StatelessWidget {
  final LineBlock line;
  final int lineIndex;
  final ui.Image image;
  final Size imageSize;
  final String imagePath;
  final double cardWidth;
  final double fontSize;
  final CharBlock? selected;
  final String? processingLineId;

  /// 执行中的行级动作（'rerecognize'/'resplit'/'ai-check'）：转圈显示
  /// 在对应动作按钮上。
  final String? processingLineAction;

  /// 「定位」后呼吸闪烁的字块 id：行图/字chip/字轨三处同时高亮。
  final String? flashCharId;
  final void Function(CharBlock old, CharBlock updated) onCharUpdated;
  final ValueChanged<CharBlock> onCharAdded;
  final ValueChanged<CharBlock?> onCharSelected;
  final Future<void> Function(LineBlock line) onRerecognizeLine;

  /// 重新切割该列：丢弃现有字框，对该行做全新拆字 + OCR。
  final Future<void> Function(LineBlock line) onResplitLine;

  /// AI 检查本行（视觉模型诊断 + 重摆 + 置信度裁决）。
  final Future<void> Function(LineBlock line) onAiCheckLine;

  /// 按 AI 切分标记局部修复本行（尾段重摆 + 合并 + AI 复核）。
  final Future<void> Function(LineBlock line) onAiRepairLine;

  /// 该行被 AI 修复过（标题旁「AI」徽章）。
  final bool aiAdjusted;

  final void Function(LineBlock line, int oldIndex, int newIndex)
  onCharsReordered;

  /// 删除识别框（快捷候选浮层的"删除识别框"按钮）。
  final void Function(CharBlock c) onCharDeleted;

  const _LineCard({
    required this.line,
    required this.lineIndex,
    required this.image,
    required this.imageSize,
    required this.imagePath,
    required this.cardWidth,
    required this.fontSize,
    required this.selected,
    required this.processingLineId,
    required this.processingLineAction,
    required this.flashCharId,
    required this.onCharUpdated,
    required this.onCharAdded,
    required this.onCharSelected,
    required this.onRerecognizeLine,
    required this.onResplitLine,
    required this.onAiCheckLine,
    required this.onAiRepairLine,
    required this.aiAdjusted,
    required this.onCharsReordered,
    required this.onCharDeleted,
  });

  @override
  Widget build(BuildContext context) {
    final isVertical = line.orientation == 'vertical';
    final srcRect = Rect.fromLTWH(
      line.x.toDouble(),
      line.y.toDouble(),
      line.w.toDouble(),
      line.h.toDouble(),
    );
    final aspectRatio = line.w / line.h;

    // 与默认 460 宽度相比的整体缩放比
    final scale = (cardWidth / 460).clamp(0.65, 2.0);

    // 第二、三列文字的统一字号（由独立按钮控制，每次增减 1pt）
    final fontPx = fontSize;

    // 仅本行处于重识别时，本行卡片按钮显示转圈
    final isProcessing = processingLineId == line.id;

    // 行图基准尺寸按整体缩放
    final imgW = (isVertical ? 60.0 : 160.0) * scale;
    final imgH = imgW / aspectRatio;

    // 竖排几何对齐：列2 chips 与行图同高、逐字按字框真实位置定位（校对
    // 用对位面）；列3 改为按行内顺序排列的等高字轨（阅读用，可拖拽改序）。
    // 字号控制退化为单元内填充系数。行框退化（宽或高为 0）时回退旧的
    // 等高堆叠布局。
    final geoAlign = isVertical && line.w > 0 && line.h > 0 && imgH.isFinite;
    final fontFill = _verticalAlignFill(fontPx);
    final stdCell = geoAlign ? _verticalStdCell(line, imgH) : 0.0;
    final textColW = geoAlign ? _verticalColumnWidth(stdCell, fontFill) : 0.0;

    if (!isVertical) {
      // 横排：三条横行上下排列（行图 → 字卡行 → 整行文字），宽度对齐、
      // 字卡与行图字框逐字同位（竖排三列并排的横向版）。行图按"高约一
      // 个标准字、不超卡片宽"取尺寸——横排行纵横比大（w/h 常 >20），
      // 沿用竖排"以宽定尺寸"会把行图压成几像素高的细线。行框退化
      // （宽/高为 0 → 纵横比 NaN/∞）时用固定兜底尺寸，NaN/0 进入
      // 布局会触发 BoxConstraints 抛错。
      final availW = max(120.0, cardWidth - 20 * scale);
      var hImgH = 28.0 * scale;
      var hImgW = min(availW, 220.0 * scale);
      final hGeo =
          line.w > 0 &&
          line.h > 0 &&
          aspectRatio.isFinite &&
          aspectRatio > 0.01;
      if (hGeo) {
        // 宽度封顶 availW（SizedBox 超宽会被父级压回，显示尺寸与换算
        // 尺寸分裂成两套，命中与手柄错开二百多像素）；高度下限 20 防
        // 超宽行扁到十几像素没法点——下限内底图纵向轻微拉伸，X/Y 各自
        // 独立换算，框/手柄/命中仍逐点对位。
        hImgW = min(60.0 * scale * aspectRatio, availW);
        hImgH = max(20.0, hImgW / aspectRatio);
      }
      final hStdCell = hGeo ? _horizontalStdCell(line, hImgW) : 0.0;
      final chipRowH = hGeo ? (hStdCell * 1.15).clamp(28.0, 64.0) : 0.0;

      return Card(
        elevation: 2,
        child: Padding(
          padding: EdgeInsets.all(10 * scale),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _headerRow(
                context,
                scale,
                isProcessing,
                isVertical,
                processingLineAction,
              ),
              SizedBox(height: 6 * scale),
              // ── 条1：行图（宽矮裁剪 + 可交互字框） ──
              InteractiveLineCrop(
                image: image,
                srcRect: srcRect,
                line: line,
                displayWidth: hImgW,
                displayHeight: hImgH,
                selected: selected,
                flashCharId: flashCharId,
                onCharUpdated: onCharUpdated,
                onCharAdded: onCharAdded,
                onCharSelected: onCharSelected,
                onCharDeleted: onCharDeleted,
              ),
              SizedBox(height: 8 * scale),
              // ── 条2：字卡行（与行图同宽，逐字按字框 x 同位） ──
              _CharChipRow(
                line: line,
                fontPx: fontPx,
                displayWidth: hGeo ? hImgW : 0,
                stdCell: hStdCell,
                rowHeight: chipRowH,
                selected: selected,
                flashCharId: flashCharId,
                onCharSelected: onCharSelected,
                onEditChar: (c, anchor) => _quickEditChar(context, c, anchor),
                onReorder: (oldIndex, newIndex) =>
                    onCharsReordered(line, oldIndex, newIndex),
              ),
              SizedBox(height: 8 * scale),
              // ── 条3：整行文字（横排字轨，轻点选中，左右拖拽改序） ──
              Container(
                padding: EdgeInsets.symmetric(
                  vertical: 4 * scale,
                  horizontal: 6 * scale,
                ),
                decoration: BoxDecoration(
                  color: Colors.indigo.shade50,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.indigo.shade100),
                ),
                child: hGeo
                    ? _HorizontalTextRow(
                        line: line,
                        stdCell: hStdCell,
                        fontFill: fontFill,
                        selected: selected,
                        flashCharId: flashCharId,
                        onCharSelected: onCharSelected,
                        onReorder: (oldIndex, newIndex) =>
                            onCharsReordered(line, oldIndex, newIndex),
                      )
                    : _horizontalFallbackText(fontPx),
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      elevation: 2,
      child: Padding(
        padding: EdgeInsets.all(10 * scale),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _headerRow(
              context,
              scale,
              isProcessing,
              isVertical,
              processingLineAction,
            ),
            SizedBox(height: 6 * scale),
            // ── 三列横向排列，上边界对齐 ──
            IntrinsicHeight(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── 列1：行图 + 可交互 char 框 ──
                  InteractiveLineCrop(
                    image: image,
                    srcRect: srcRect,
                    line: line,
                    displayWidth: imgW,
                    displayHeight: imgH,
                    selected: selected,
                    flashCharId: flashCharId,
                    onCharUpdated: onCharUpdated,
                    onCharAdded: onCharAdded,
                    onCharSelected: onCharSelected,
                    onCharDeleted: onCharDeleted,
                  ),
                  SizedBox(width: 8 * scale),
                  // ── 列2：字符 chips 纵向（轻点下方浮出候选条，长按拖拽改变字序） ──
                  _CharChipColumn(
                    line: line,
                    fontPx: fontPx,
                    displayHeight: geoAlign ? imgH : 0,
                    stdCell: stdCell,
                    columnWidth: textColW,
                    selected: selected,
                    flashCharId: flashCharId,
                    onCharSelected: onCharSelected,
                    onEditChar: (c, anchor) =>
                        _quickEditChar(context, c, anchor),
                    onReorder: (oldIndex, newIndex) =>
                        onCharsReordered(line, oldIndex, newIndex),
                  ),
                  SizedBox(width: 8 * scale),
                  // ── 列3：整行文字竖向 ──
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 6 * scale),
                    decoration: BoxDecoration(
                      color: Colors.indigo.shade50,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.indigo.shade100),
                    ),
                    child: geoAlign
                        // 按行内顺序排成等高字轨（与参考样式一致）：
                        // 轻点选中联动高亮，上下拖拽改变字序（吸附预览）。
                        ? _VerticalTextColumn(
                            line: line,
                            stdCell: stdCell,
                            columnWidth: textColW,
                            fontFill: fontFill,
                            selected: selected,
                            flashCharId: flashCharId,
                            onCharSelected: onCharSelected,
                            onReorder: (oldIndex, newIndex) =>
                                onCharsReordered(line, oldIndex, newIndex),
                          )
                        // 行框退化时的回退布局：固定行高堆叠
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            children: line.chars
                                .map(
                                  (c) => SizedBox(
                                    height: fontPx,
                                    child: Container(
                                      alignment: Alignment.center,
                                      decoration: selected?.id == c.id
                                          ? BoxDecoration(
                                              color: Colors.orange.withValues(
                                                alpha: 0.28,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(3),
                                            )
                                          : null,
                                      child: Text(
                                        c.text.isEmpty ? '?' : c.text,
                                        strutStyle: StrutStyle(
                                          fontSize: fontPx,
                                          height: 1,
                                          leading: 0,
                                        ),
                                        style: TextStyle(
                                          fontSize: fontPx,
                                          height: 1.0,
                                          leadingDistribution:
                                              TextLeadingDistribution.even,
                                        ),
                                      ),
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 横排行框退化时的整行文字回退：普通横排富文本（选中字橙色底）。
  Widget _horizontalFallbackText(double fontPx) {
    return RichText(
      text: TextSpan(
        children: [
          for (final c in line.chars)
            TextSpan(
              text: c.text.isEmpty ? '?' : c.text,
              style: TextStyle(
                fontSize: fontPx,
                height: 1.0,
                color: Colors.black87,
                backgroundColor: selected?.id == c.id
                    ? Colors.orange.withValues(alpha: 0.28)
                    : null,
              ),
            ),
        ],
        style: TextStyle(fontSize: fontPx, height: 1.0, color: Colors.black87),
      ),
    );
  }

  /// 卡片标题行：行号/方向标签 + 重识别 / 重切割 / 切字诊断按钮。
  Widget _headerRow(
    BuildContext context,
    double scale,
    bool isProcessing,
    bool isVertical,
    String? processingAction,
  ) {
    // 转圈只落在执行中的那个动作按钮上（action 为 null 的旧路径/未知
    // 动作保持旧行为：显示在"重新识别本行单字"上）。此前只有行级布尔，
    // 点"重新切割本列"的转圈会错位显示在重新识别图标上。
    final spinning = isProcessing && processingAction == null;
    final spinningResplit = isProcessing && processingAction == 'resplit';
    final spinningAiCheck = isProcessing && processingAction == 'ai-check';
    Widget actionIcon(IconData icon, bool spin, Color? color) => spin
        ? const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(icon, size: 17, color: color);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '第 ${lineIndex + 1} 行  ${isVertical ? '竖排' : '横排'}',
          style: TextStyle(
            fontSize: 10 * scale,
            color: Colors.grey,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (aiAdjusted) ...[
          const SizedBox(width: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: Colors.deepPurple.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              'AI',
              style: TextStyle(
                fontSize: 9 * scale,
                color: Colors.deepPurple.shade700,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
        const SizedBox(width: 4),
        IconButton(
          onPressed: isProcessing ? null : () => onRerecognizeLine(line),
          tooltip: '重新识别本行单字',
          icon: actionIcon(Icons.refresh, spinning, null),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          visualDensity: VisualDensity.compact,
        ),
        IconButton(
          onPressed: isProcessing ? null : () => onResplitLine(line),
          tooltip:
              '重新切割本列（丢弃现有字框，重新拆字+识别；'
              '行框会外扩到整列墨迹）',
          icon: actionIcon(
            Icons.content_cut,
            spinningResplit,
            Colors.deepOrange,
          ),
          color: Colors.deepOrange,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          visualDensity: VisualDensity.compact,
        ),
        IconButton(
          onPressed: () => _showSplitDebug(context),
          tooltip: '切字过程诊断（二值化墨迹/连通域/字框）',
          icon: const Icon(Icons.troubleshoot, size: 17),
          color: Colors.teal,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          visualDensity: VisualDensity.compact,
        ),
        IconButton(
          onPressed: isProcessing ? null : () => onAiCheckLine(line),
          tooltip: 'AI 检查本行（视觉模型诊断切字框，重摆后按识别置信度裁决）',
          icon: actionIcon(
            Icons.auto_fix_high,
            spinningAiCheck,
            Colors.deepPurple,
          ),
          color: Colors.deepPurple,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          visualDensity: VisualDensity.compact,
        ),
        if (line.chars.any((c) => (c.aiBoxIssue ?? '').isNotEmpty))
          IconButton(
            onPressed: isProcessing ? null : () => onAiRepairLine(line),
            tooltip:
                '按 AI 标记局部修复本行：从首个标记框的前一框裁到行尾重识别，'
                '合并回整行（前段不动），质量分提升才采纳，采纳后 AI 复核',
            icon: const Icon(Icons.healing, size: 17),
            color: Colors.deepOrange,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }

  /// 切字过程诊断：生成并展示本行的二值化墨迹图与切分过程图（连通域
  /// 块/被丢弃的墨点/最终字框），帮助分析字框是如何判定的。
  Future<void> _showSplitDebug(BuildContext context) async {
    Map<String, dynamic>? data;
    String? error;
    try {
      data = await PythonService.debugCharSplit(
        imagePath: imagePath,
        orientation: line.orientation,
        lines: [
          {
            'x': line.x,
            'y': line.y,
            'w': line.w,
            'h': line.h,
            'expected_count': line.chars.length,
          },
        ],
      );
    } catch (e) {
      error = e.toString();
    }
    if (!context.mounted) return;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('第 ${lineIndex + 1} 行 · 切字过程'),
        content: error != null
            ? Text('诊断失败：$error', style: const TextStyle(color: Colors.red))
            : _SplitDebugView(data: data!),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 轻点字 chip：在字框正下方浮出快捷候选条，点候选文字立即应用。
  /// 同时带上 AI 辅助需要的行内上下文（前后文字、是否标点小框）。
  void _quickEditChar(BuildContext context, CharBlock c, Rect anchor) {
    final chars = line.chars;
    final idx = chars.indexOf(c);
    var contextBefore = '';
    var contextAfter = '';
    if (idx >= 0) {
      final beforeBuf = StringBuffer();
      for (var i = idx - 1; i >= 0 && beforeBuf.length < 12; i--) {
        beforeBuf.write(chars[i].text);
      }
      contextBefore = beforeBuf.toString();
      final afterBuf = StringBuffer();
      for (var i = idx + 1; i < chars.length && afterBuf.length < 12; i++) {
        afterBuf.write(chars[i].text);
      }
      contextAfter = afterBuf.toString();
    }
    // 标点小框：文本本身是标点，或字框跨度明显小于本行中位字（与后端
    // 标点判定同口径——刻本标点不到半个字高）。
    final vertical = line.orientation == 'vertical';
    final spans = chars.map((ch) => vertical ? ch.h : ch.w).toList()..sort();
    final median = spans.isEmpty ? 0 : spans[spans.length ~/ 2];
    final span = vertical ? c.h : c.w;
    final isPunctLike =
        isPunctuationText(c.text) || (median > 0 && span < median * 0.65);
    _showCharQuickCandidates(
      context,
      char: c,
      line: line,
      anchor: anchor,
      imagePath: imagePath,
      contextBefore: contextBefore,
      contextAfter: contextAfter,
      isPunctLike: isPunctLike,
      onCharUpdated: onCharUpdated,
      onCharDeleted: () => onCharDeleted(c),
    );
  }
}

// ─── 切字过程诊断弹窗内容 ─────────────────────────────────────────────────────

class _SplitDebugView extends StatelessWidget {
  final Map<String, dynamic> data;

  const _SplitDebugView({required this.data});

  static String _methodLabel(String? method) {
    switch (method) {
      case 'components':
        return '连通域切分（正常路径）';
      case null:
        return '未知';
    }
    if (method.startsWith('layout-grid')) return '数量不符 → 网格均分兜底';
    if (method.startsWith('equal-division')) {
      return '等分兜底（${method.split('(').last})';
    }
    return method;
  }

  static String _fileSummary(String path) {
    final f = File(path);
    return f.existsSync() ? '${(f.lengthSync() / 1024).round()} KB' : '未生成';
  }

  @override
  Widget build(BuildContext context) {
    final lines =
        (data['lines'] as List?)?.cast<Map<String, dynamic>>() ??
        const <Map<String, dynamic>>[];
    final maskImage = data['mask_image']?.toString();
    final polarity = (data['mask_polarity'] as Map?)?.cast<String, dynamic>();
    final polarityFlipped = polarity?['flipped'] == true;
    final inkFraction = (polarity?['ink_fraction_before'] as num?)?.toDouble();
    final traceLines =
        (data['trace'] as List?)?.map((e) => e.toString()).toList() ??
        const <String>[];
    final traceFile = data['trace_file']?.toString();
    return SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '切分链路：整页二值化墨迹（极性自检）→ 行框外扩到本行连续墨迹 → '
              '水平膨胀合并笔画 → 连通域分块 → 面积过滤丢墨点 → 粘连投影细切 → '
              '数量校验（优先在纯白区间下刀）→ 超高字框"字+标点"拆分。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 6),
            Text(
              polarity == null
                  ? '二值化极性：未知（mask 未生成诊断信息）'
                  : polarityFlipped
                  ? '二值化极性：已翻转（白字黑底页，转为识别白色文字；'
                        '翻转前墨占比 ${(inkFraction! * 100).toStringAsFixed(0)}%）'
                  : '二值化极性：正常（墨=深色字，墨占比 '
                        '${((inkFraction ?? 0) * 100).toStringAsFixed(0)}%）',
              style: TextStyle(
                fontSize: 12,
                color: polarityFlipped ? Colors.deepOrange : Colors.black87,
              ),
            ),
            const SizedBox(height: 8),
            for (final l in lines) ...[
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.teal.shade50,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '方法：${_methodLabel(l['method']?.toString())}',
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '连通域块 ${l['component_count']} 个 · 丢弃墨点 '
                      '${l['dropped_count']} 个 · 粘连投影 ${l['stuck_fallback']} 处 · '
                      '字框 ${((l['boxes'] as List?) ?? const []).length} 个'
                      '${(l['expected_count'] as num? ?? 0) > 0 ? '（期望 ${(l['expected_count'] as num).toInt()}）' : ''}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.black87,
                      ),
                    ),
                    if (l['rect_expanded'] == true) ...[
                      const SizedBox(height: 2),
                      Text(
                        '行框外扩：传入行框偏短（绿细线），已沿阅读轴扩到本行'
                        '连续墨迹（绿粗线，白色区间 >0.85 字高即停）——识别与'
                        '切分都用扩后框。',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.teal.shade700,
                        ),
                      ),
                    ],
                    if ((l['punct_split_count'] as num? ?? 0) > 0) ...[
                      const SizedBox(height: 2),
                      Text(
                        '标点拆分：${(l['punct_split_count'] as num).toInt()} 个'
                        '"字+标点"同框被拆开（紫线=拆分前的同框框）。',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.deepPurple,
                        ),
                      ),
                    ],
                    if ((l['tighten_sim_count'] as num? ?? 0) > 0) ...[
                      const SizedBox(height: 2),
                      Text(
                        '识别框模拟：该行走兜底切分，识别链路会弃用槽位框、改用 '
                        'kraken 条带框（宽恒=行宽）再逐格收紧——黄框即收紧后'
                        '的识别框；某字框偏宽的成因看日志 [diag:wide-box] 与 '
                        '[tighten] 各行。',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.amber.shade800,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '图例：绿粗=外扩后行框　绿细=传入行框　橙=连通域块　红=被丢弃的'
                '墨点　紫=被拆分的同框框　蓝=最终字框（含序号）　黄=识别框模拟'
                '（兜底行的 cuts 条带收紧后）',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
              const SizedBox(height: 4),
              if (l['image'] != null)
                _DebugImage(path: l['image'].toString(), title: '切分过程'),
              const SizedBox(height: 8),
            ],
            if (maskImage != null) ...[
              const Text(
                '整页二值化墨迹（切分器"眼中"的图，黑=墨迹）：',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 4),
              _DebugImage(path: maskImage, title: '二值化墨迹'),
            ],
            if (traceLines.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '切分日志（逐行决策与原因'
                      '${traceFile != null && traceFile.isNotEmpty ? '，已保存：$traceFile' : ''}）：',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                  IconButton(
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(text: traceLines.join('\n')),
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('切分日志已复制到剪贴板'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                    tooltip: '复制全部日志',
                    icon: const Icon(Icons.copy, size: 16),
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 240),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey.shade900,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final t in traceLines)
                        SelectableText(
                          t,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontFamily: 'monospace',
                            color: _traceColor(t),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 日志行着色：警告（未拆/兜底/数量不符/保留条带/宽框）橙色、成功
  /// （拆分/外扩/横画收紧）绿色、其余灰白——弹窗里一眼定位"为什么没拆/
  /// 为什么走了兜底/这个字的框为什么宽"。
  static Color _traceColor(String line) {
    if (line.contains('未拆') ||
        line.contains('fallback') ||
        line.contains('mismatch') ||
        line.contains('failed') ||
        line.contains('error') ||
        line.contains('保留条带') ||
        line.contains('wide-box') ||
        line.contains('弃用兜底')) {
      return Colors.orangeAccent.shade200;
    }
    if (line.contains('[diag:punct-split] pass=') ||
        line.contains('[diag:line-expand]') ||
        line.contains('[diag:region-extend]') ||
        line.contains('polarity flipped') ||
        line.contains('横画收紧') ||
        line.contains('采用像素切分框')) {
      return Colors.greenAccent.shade200;
    }
    return Colors.white70;
  }
}

class _DebugImage extends StatelessWidget {
  final String path;
  final String title;

  const _DebugImage({required this.path, required this.title});

  @override
  Widget build(BuildContext context) {
    final file = File(path);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '$title（${_SplitDebugView._fileSummary(path)}）',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              onPressed: file.existsSync()
                  ? () => Process.run('cmd', ['/c', 'start', '', path])
                  : null,
              tooltip: '用系统看图工具打开（可缩放）',
              icon: const Icon(Icons.open_in_new, size: 16),
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Container(
            constraints: const BoxConstraints(maxHeight: 420),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: file.existsSync()
                ? Image.file(file, fit: BoxFit.contain)
                : const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('图片未生成', style: TextStyle(color: Colors.red)),
                  ),
          ),
        ),
      ],
    );
  }
}

// ─── 列3整行文字（竖排）：按行内顺序排成等高字轨，轻点选中，拖拽改序 ──────────

class _VerticalTextColumn extends StatefulWidget {
  final LineBlock line;

  /// 标准字单元高（全部字框高度的中位数）。
  final double stdCell;

  /// 统一列宽。
  final double columnWidth;

  /// 字号填充系数（"字号"控制）。
  final double fontFill;

  final CharBlock? selected;
  final ValueChanged<CharBlock?> onCharSelected;
  final void Function(int oldIndex, int newIndex) onReorder;

  /// 「定位」后呼吸闪烁的字块 id。
  final String? flashCharId;

  const _VerticalTextColumn({
    required this.line,
    required this.stdCell,
    required this.columnWidth,
    required this.fontFill,
    required this.selected,
    required this.flashCharId,
    required this.onCharSelected,
    required this.onReorder,
  });

  @override
  State<_VerticalTextColumn> createState() => _VerticalTextColumnState();
}

class _VerticalTextColumnState extends State<_VerticalTextColumn> {
  final GlobalKey _columnKey = GlobalKey();
  int? _dragIndex;
  int? _dropIndex;

  /// 拖拽中的预览序列：被拖字已吸附到落点槽位，改序效果即时可见。
  List<CharBlock> get _displayChars {
    final chars = widget.line.chars;
    final drag = _dragIndex;
    final drop = _dropIndex;
    if (drag == null || drop == null || drag == drop) return chars;
    final list = chars.toList();
    final c = list.removeAt(drag);
    list.insert(drop.clamp(0, list.length), c);
    return list;
  }

  /// 槽位高：标准单元随字号系数缩放（字号控制即整条字轨的大小）。
  double get _slotH => widget.stdCell * widget.fontFill.clamp(0.55, 1.4);

  void _cancelDrag() => setState(() {
    _dragIndex = null;
    _dropIndex = null;
  });

  void _commitDrag() {
    final from = _dragIndex;
    final to = _dropIndex;
    _cancelDrag();
    if (from != null && to != null && from != to) {
      widget.onReorder(from, to);
    }
  }

  int? _dropIndexFromPointer(Offset globalPosition) {
    final box = _columnKey.currentContext?.findRenderObject();
    if (box is! RenderBox) return null;
    final localY = box.globalToLocal(globalPosition).dy;
    return (localY / _slotH).floor().clamp(0, widget.line.chars.length - 1);
  }

  @override
  Widget build(BuildContext context) {
    final font = widget.stdCell * 0.8 * widget.fontFill;
    final display = _displayChars;
    final draggingChar = _dragIndex != null
        ? widget.line.chars[_dragIndex!]
        : null;
    return SizedBox(
      key: _columnKey,
      width: widget.columnWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < display.length; i++)
            _cell(display[i], draggingChar?.id == display[i].id, font),
        ],
      ),
    );
  }

  Widget _cell(CharBlock c, bool dragging, double font) {
    final highlighted = dragging || widget.selected?.id == c.id;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 轻点选中（与列1行图/列2 chips 联动高亮）；改字在列2 chip 上轻点。
      onTap: () => widget.onCharSelected(c),
      // 上下拖动改序：被拖字实时吸附到落点槽位预览，松手提交。拖动由
      // 内层识别器赢得手势竞技，拖动期间外层列表不滚动（与列2 相同）。
      onVerticalDragStart: (d) {
        final j = widget.line.chars.indexOf(c);
        if (j < 0) return;
        setState(() {
          _dragIndex = j;
          _dropIndex = j;
        });
      },
      onVerticalDragUpdate: (d) {
        if (_dragIndex == null) return;
        final to = _dropIndexFromPointer(d.globalPosition);
        if (to != null && to != _dropIndex) {
          setState(() => _dropIndex = to);
        }
      },
      onVerticalDragEnd: (_) => _commitDrag(),
      onVerticalDragCancel: _cancelDrag,
      // 按住不动约半秒后再拖同样进入改序（鼠标慢速拖拽的兜底路径）
      onLongPressStart: (d) {
        final j = widget.line.chars.indexOf(c);
        if (j < 0) return;
        setState(() {
          _dragIndex = j;
          _dropIndex = j;
        });
      },
      onLongPressMoveUpdate: (d) {
        if (_dragIndex == null) return;
        final to = _dropIndexFromPointer(d.globalPosition);
        if (to != null && to != _dropIndex) {
          setState(() => _dropIndex = to);
        }
      },
      onLongPressEnd: (_) => _commitDrag(),
      onLongPressCancel: _cancelDrag,
      child: _LocateFlash(
        active: c.id == widget.flashCharId,
        child: SizedBox(
          height: _slotH,
          child: Container(
            alignment: Alignment.center,
            decoration: highlighted
                ? BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.28),
                    borderRadius: BorderRadius.circular(3),
                    border: dragging
                        ? Border.all(color: Colors.orange.shade700, width: 1.5)
                        : null,
                    boxShadow: dragging
                        ? const [
                            BoxShadow(
                              color: Colors.black26,
                              blurRadius: 6,
                              offset: Offset(0, 2),
                            ),
                          ]
                        : null,
                  )
                : c.agree == 'conflict'
                // 两路分歧标记：与列2 chip 的琥珀角标对应，选中高亮时让位。
                ? BoxDecoration(
                    border: Border(
                      left: BorderSide(
                        color: Colors.amber.shade700,
                        width: 2.5,
                      ),
                    ),
                  )
                : null,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                c.text.isEmpty ? '?' : c.text,
                style: TextStyle(fontSize: font),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── 条3整行文字（横排）：按行内顺序排成等宽字轨，轻点选中，左右拖拽改序 ──

class _HorizontalTextRow extends StatefulWidget {
  final LineBlock line;

  /// 标准字单元宽（全部字框宽度的中位数，显示坐标）。
  final double stdCell;

  /// 字号填充系数（"字号"控制）。
  final double fontFill;

  final CharBlock? selected;
  final ValueChanged<CharBlock?> onCharSelected;
  final void Function(int oldIndex, int newIndex) onReorder;

  /// 「定位」后呼吸闪烁的字块 id。
  final String? flashCharId;

  const _HorizontalTextRow({
    required this.line,
    required this.stdCell,
    required this.fontFill,
    required this.selected,
    required this.flashCharId,
    required this.onCharSelected,
    required this.onReorder,
  });

  @override
  State<_HorizontalTextRow> createState() => _HorizontalTextRowState();
}

class _HorizontalTextRowState extends State<_HorizontalTextRow> {
  final GlobalKey _rowKey = GlobalKey();
  int? _dragIndex;
  int? _dropIndex;

  /// 拖拽中的预览序列：被拖字已吸附到落点槽位，改序效果即时可见。
  List<CharBlock> get _displayChars {
    final chars = widget.line.chars;
    final drag = _dragIndex;
    final drop = _dropIndex;
    if (drag == null || drop == null || drag == drop) return chars;
    final list = chars.toList();
    final c = list.removeAt(drag);
    list.insert(drop.clamp(0, list.length), c);
    return list;
  }

  /// 槽位宽：标准单元随字号系数缩放（字号控制即整条字轨的大小）。
  double get _slotW => widget.stdCell * widget.fontFill.clamp(0.55, 1.4);

  void _cancelDrag() => setState(() {
    _dragIndex = null;
    _dropIndex = null;
  });

  void _commitDrag() {
    final from = _dragIndex;
    final to = _dropIndex;
    _cancelDrag();
    PythonService.addAppLog(
      '[拖拽]  from=$from to=$to'
      '${from != null && to != null && from != to ? '' : '（无位移，不提交）'}',
    );
    if (from != null && to != null && from != to) {
      widget.onReorder(from, to);
    }
  }

  int? _dropIndexFromPointer(Offset globalPosition) {
    final box = _rowKey.currentContext?.findRenderObject();
    if (box is! RenderBox) return null;
    final localX = box.globalToLocal(globalPosition).dx;
    return (localX / _slotW).floor().clamp(0, widget.line.chars.length - 1);
  }

  @override
  Widget build(BuildContext context) {
    final font = widget.stdCell * 0.8 * widget.fontFill;
    final display = _displayChars;
    final draggingChar = _dragIndex != null
        ? widget.line.chars[_dragIndex!]
        : null;
    return SizedBox(
      key: _rowKey,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        // 不能用 stretch：Row 的交叉轴是高度，垂直滚动列表里高度无界，
        // stretch 会把 h=Infinity 强制传给 children（BoxConstraints 抛
        // "forces an infinite height" 崩溃）。槽位等高由每个 cell 的
        // SizedBox(width/height: _slotW) 保证。
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (var i = 0; i < display.length; i++)
            _cell(display[i], draggingChar?.id == display[i].id, font),
        ],
      ),
    );
  }

  Widget _cell(CharBlock c, bool dragging, double font) {
    final highlighted = dragging || widget.selected?.id == c.id;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 轻点选中（与条1行图/条2 chips 联动高亮）；改字在条2 chip 上轻点。
      onTap: () => widget.onCharSelected(c),
      // 任意方向拖动改序（竖排字轨拖动的横向版）：被拖字实时吸附到落
      // 点槽位预览，松手提交。Pan 而非仅水平——斜向拖动时仅水平识别器
      // 会被外层列表的垂直滚动抢走手势；Pan 靠内层优先稳赢。
      onPanStart: (d) {
        final j = widget.line.chars.indexOf(c);
        if (j < 0) return;
        setState(() {
          _dragIndex = j;
          _dropIndex = j;
        });
      },
      onPanUpdate: (d) {
        if (_dragIndex == null) return;
        final to = _dropIndexFromPointer(d.globalPosition);
        if (to != null && to != _dropIndex) {
          setState(() => _dropIndex = to);
        }
      },
      onPanEnd: (_) => _commitDrag(),
      onPanCancel: _cancelDrag,
      // 按住不动约半秒后再拖同样进入改序（鼠标慢速拖拽的兜底路径）
      onLongPressStart: (d) {
        final j = widget.line.chars.indexOf(c);
        if (j < 0) return;
        setState(() {
          _dragIndex = j;
          _dropIndex = j;
        });
      },
      onLongPressMoveUpdate: (d) {
        if (_dragIndex == null) return;
        final to = _dropIndexFromPointer(d.globalPosition);
        if (to != null && to != _dropIndex) {
          setState(() => _dropIndex = to);
        }
      },
      onLongPressEnd: (_) => _commitDrag(),
      onLongPressCancel: _cancelDrag,
      child: _LocateFlash(
        active: c.id == widget.flashCharId,
        child: SizedBox(
          // 等宽且等高的方槽（对应竖排字轨的等高槽），文字在槽内居中。
          width: _slotW,
          height: _slotW,
          child: Container(
            alignment: Alignment.center,
            decoration: highlighted
                ? BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.28),
                    borderRadius: BorderRadius.circular(3),
                    border: dragging
                        ? Border.all(color: Colors.orange.shade700, width: 1.5)
                        : null,
                    boxShadow: dragging
                        ? const [
                            BoxShadow(
                              color: Colors.black26,
                              blurRadius: 6,
                              offset: Offset(0, 2),
                            ),
                          ]
                        : null,
                  )
                : c.agree == 'conflict'
                // 两路分歧标记：横排用顶边线（竖排字轨是左边线），与
                // 条2 chip 的琥珀角标对应，选中高亮时让位。
                ? BoxDecoration(
                    border: Border(
                      top: BorderSide(color: Colors.amber.shade700, width: 2.5),
                    ),
                  )
                : null,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                c.text.isEmpty ? '?' : c.text,
                style: TextStyle(fontSize: font),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── 单字就地编辑：字框变输入框 + 下方快捷候选条 ─────────────────────────────

/// 候选合并规则（快捷候选条使用）：静态候选（识别时保存的另一
/// 读法，如整行序列字）先入列，接口返回的同名候选覆盖它，当前文字兜底
/// 入列；单个 ASCII 字母是识别模型的退化猜测，视为噪音剔除。
/// 服务异常时静默降级为"静态候选 + 当前文字"，仍可快速选字/确认。
Future<List<Map<String, dynamic>>> loadMergedCharCandidates({
  required String imagePath,
  required CharBlock char,
}) async {
  final merged = <String, Map<String, dynamic>>{
    for (final c in char.candidates)
      if (c.text.trim().isNotEmpty && !_isLatinLetterNoise(c.text))
        c.text: {
          'text': c.text,
          'score': c.score,
          // 整行三步分析并入的 AI 候选带紫色角标（与手动点「AI 辅助
          // 识别」的结果同口径）。
          if (c.ai) 'ai': true,
        },
  };
  try {
    final result = await PythonService.getCharCandidates(
      imagePath: imagePath,
      x: char.x,
      y: char.y,
      w: char.w,
      h: char.h,
      topK: 10,
    );
    for (final item in result) {
      if ((item['text']?.toString() ?? '').trim().isNotEmpty &&
          !_isLatinLetterNoise(item['text'].toString())) {
        merged[item['text'].toString()] = item;
      }
    }
  } catch (_) {
    // 网络/服务异常：走下方当前文字兜底，不让候选区为空。
  }
  final recognized = char.text.trim();
  if (recognized.isNotEmpty && !_isLatinLetterNoise(recognized)) {
    merged.putIfAbsent(
      recognized,
      () => <String, dynamic>{'text': recognized, 'score': 1.0},
    );
  }
  return merged.values.toList()..sort(
    (a, b) => ((b['score'] as num?)?.toDouble() ?? 0).compareTo(
      (a['score'] as num?)?.toDouble() ?? 0,
    ),
  );
}

/// 单个纯 ASCII 字母（识别模型对古汉字的退化猜测）不进入候选列表。
bool _isLatinLetterNoise(String text) {
  final t = text.trim();
  if (t.length != 1) return false;
  final c = t.codeUnitAt(0);
  return (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a);
}

/// 在 [anchor]（被点字框的全局矩形）处插入全屏覆盖层：字框位置就地变成
/// 可输入的文字框，正下方浮出快捷候选条（点候选立即应用）。输入过程只
/// 停留在输入框内、不实时写回字块——中文输入法的组合中间态（拼音字母）
/// 不是最终文字；点空白处、按回车或点候选时一次性提交最终文字。
/// [line] 为该字所在的行（AI 辅助识别据此裁整行条图，橙框标出目标字）；
/// [contextBefore]/[contextAfter] 为该字在行内阅读顺序上的前后文字，
/// 供 Ollama AI 辅助参考；[isPunctLike] 为 true 时 AI 走标点分支
/// （按上下文推荐句读），否则走整行图像识别。
void _showCharQuickCandidates(
  BuildContext context, {
  required CharBlock char,
  required LineBlock line,
  required Rect anchor,
  required String imagePath,
  required String contextBefore,
  required String contextAfter,
  required bool isPunctLike,
  required void Function(CharBlock old, CharBlock updated) onCharUpdated,
  required VoidCallback onCharDeleted,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  // 浮层输入框会抢走键盘焦点；关闭时若不归还，页面级 KeyboardListener
  // （Delete 删除选中框 / Esc 取消）将静默失灵——表现为"按 Del 没反应"。
  final previousFocus = FocusManager.instance.primaryFocus;
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _CharQuickEditor(
      char: char,
      line: line,
      anchor: anchor,
      imagePath: imagePath,
      contextBefore: contextBefore,
      contextAfter: contextAfter,
      isPunctLike: isPunctLike,
      onCharUpdated: onCharUpdated,
      onCharDeleted: onCharDeleted,
      onDismiss: () {
        if (entry.mounted) entry.remove();
        // 把焦点还给浮层打开前的持有者（通常是页面的快捷键焦点节点）。
        if (previousFocus != null &&
            previousFocus.context != null &&
            FocusManager.instance.primaryFocus == null) {
          previousFocus.requestFocus();
        }
      },
    ),
  );
  overlay.insert(entry);
}

/// 就地编辑浮层的整体：遮罩 + 字框位置上的输入框 + 下方候选条。
/// 控制器和候选加载都放在这一层，关闭时统一提交。
/// 候选条底部提供「AI 辅助识别/AI 标点辅助」（Ollama，见
/// OllamaSettingsPage），AI 候选合并进候选列表并以紫色角标区分；
/// 「标记特殊字」切换与文字一样关闭浮层时统一提交。
class _CharQuickEditor extends StatefulWidget {
  final CharBlock char;

  /// 该字所在的行：AI 辅助识别裁整行条图（橙框标出目标字）用。
  final LineBlock line;
  final Rect anchor;
  final String imagePath;

  /// 行内阅读顺序上该字之前/之后的文字（AI 辅助上下文）。
  final String contextBefore;
  final String contextAfter;

  /// 标点小框：AI 走"按上下文推荐标点"分支。
  final bool isPunctLike;
  final void Function(CharBlock old, CharBlock updated) onCharUpdated;

  /// 删除这个识别框（候选条上的删除识别框按钮）。
  final VoidCallback onCharDeleted;
  final VoidCallback onDismiss;

  const _CharQuickEditor({
    required this.char,
    required this.line,
    required this.anchor,
    required this.imagePath,
    required this.contextBefore,
    required this.contextAfter,
    required this.isPunctLike,
    required this.onCharDeleted,
    required this.onCharUpdated,
    required this.onDismiss,
  });

  @override
  State<_CharQuickEditor> createState() => _CharQuickEditorState();
}

class _CharQuickEditorState extends State<_CharQuickEditor> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.char.text,
  );

  /// 获得焦点时全选现有文字：直接输入即可整体替换，不用先手动删除。
  late final FocusNode _fieldFocus = FocusNode()
    ..addListener(() {
      if (_fieldFocus.hasFocus) {
        _controller.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _controller.text.length,
        );
      }
    });

  /// null = 候选加载中。
  List<Map<String, dynamic>>? _candidates;
  bool _closed = false;

  /// 特殊字标记的本地镜像：打开时取自字块，面板里点按钮只翻转本地
  /// 状态，关闭浮层时与文字一起经 onCharUpdated 一次性提交（与输入
  /// 过程不实时写回同一契约；也避免标记先提交换实例后文字提交抓着
  /// 旧实例落空）。
  late bool _marked = widget.char.marked;

  // ── AI 辅助（Ollama）状态 ──
  bool _aiLoading = false;
  String? _aiError;
  String? _aiModelLabel;

  @override
  void initState() {
    super.initState();
    // 打开即全选现有文字：随初始 value 一起被输入框采纳。
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _controller.text.length,
    );
    // 焦点修复：点字的指针按下会先被页面级 Listener 抢给页面的
    // KeyboardListener（Delete/Esc 快捷键依赖），此后整个作用域链已有
    // focusedChild；浮层在指针抬起时才插入，TextField 的 autofocus 在
    // 这种情况下会被框架直接丢弃（autofocus 仅在 scope.focusedChild
    // == null 时生效），输入框从未获得焦点——桌面端无焦点输入框不绘制
    // 选中高亮，点击后又折叠为光标，表现为"没有自动全选"。首帧完成后
    // 显式 requestFocus（显式请求没有该限制），全选由焦点监听器设置。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _fieldFocus.requestFocus();
    });
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final result = await loadMergedCharCandidates(
      imagePath: widget.imagePath,
      char: widget.char,
    );
    if (!mounted) return;
    setState(() => _candidates = result);
  }

  // ── AI 辅助（Ollama）──

  /// 点「AI 辅助识别 / AI 标点辅助」：标点小框走上下文推荐（文本模型），
  /// 普通字走单字图像识别（视觉模型 + 字框缩略图）。结果以紫色 AI 角标
  /// 合并进候选列表，点选行为与普通候选完全一致。
  Future<void> _requestAiAssist() async {
    if (_aiLoading) return;
    setState(() {
      _aiLoading = true;
      _aiError = null;
    });
    try {
      final settings = await OllamaSettings.load();
      if (!mounted) return;
      if (!settings.configured) {
        setState(() {
          _aiLoading = false;
          _aiError = '尚未配置 AI 服务：请在首页「AI 辅助设置」中连接本地 Ollama 或外部模型 API 并选择模型';
        });
        return;
      }
      final List<OllamaSuggestion> suggestions;
      if (widget.isPunctLike) {
        if (!settings.enablePunctAssist) {
          setState(() {
            _aiLoading = false;
            _aiError = '标点辅助识别已在设置中关闭';
          });
          return;
        }
        if (mounted) {
          setState(() => _aiModelLabel = settings.activeTextModel);
        }
        suggestions = await OllamaService.suggestPunctuation(
          settings: settings,
          contextBefore: widget.contextBefore,
          contextAfter: widget.contextAfter,
          currentText: widget.char.text,
        );
      } else {
        if (!settings.enableCharAssist) {
          setState(() {
            _aiLoading = false;
            _aiError = '单字辅助识别已在设置中关闭';
          });
          return;
        }
        if (mounted) {
          setState(() => _aiModelLabel = settings.activeVisionModel);
        }
        // 整行条图（橙框标出目标字）交给视觉模型：模型能同时看到目标
        // 字形与整行版式；后端不可用时退化为纯上下文猜测。
        String? image;
        try {
          final thumbs = await PythonService.fetchLineThumbnails(
            items: [
              LineThumbRequest(
                imagePath: widget.imagePath,
                x: widget.line.x,
                y: widget.line.y,
                w: widget.line.w,
                h: widget.line.h,
                orientation: widget.line.orientation,
                boxes: [
                  (widget.char.x, widget.char.y, widget.char.w, widget.char.h),
                ],
              ),
            ],
            // 长边 1536：竖排长行一列几十字，768 时单字只剩 ~38px 明显
            // 发糊；1536 给单字 ~76px+（后端上限 2048）。
            maxSide: 1536,
          );
          image = thumbs.isNotEmpty ? (thumbs.first) : null;
        } catch (_) {
          image = null;
        }
        suggestions = await OllamaService.suggestChar(
          settings: settings,
          imageBase64: image,
          contextBefore: widget.contextBefore,
          contextAfter: widget.contextAfter,
          currentText: widget.char.text,
        );
      }
      if (!mounted || _closed) return;
      _applyAiSuggestions(suggestions);
    } on OllamaException catch (e) {
      if (!mounted || _closed) return;
      setState(() {
        _aiLoading = false;
        _aiError = e.message;
      });
    } catch (e) {
      if (!mounted || _closed) return;
      setState(() {
        _aiLoading = false;
        _aiError = 'AI 辅助失败：$e';
      });
    }
  }

  /// AI 候选并进候选列表：置顶 + 按 AI 给分排序，与现有候选去重
  /// （AI 与 OCR 给出同一个字时保留 OCR 那条，不重复占位）。
  void _applyAiSuggestions(List<OllamaSuggestion> suggestions) {
    final existingTexts = <String>{
      for (final c in _candidates ?? const <Map<String, dynamic>>[])
        (c['text']?.toString() ?? '').trim(),
    };
    final aiEntries = <Map<String, dynamic>>[];
    for (final s in suggestions) {
      if (existingTexts.contains(s.text)) continue;
      aiEntries.add({
        'text': s.text,
        'score': s.score > 0 ? s.score : 0.99,
        if (s.reason.isNotEmpty) 'reason': s.reason,
        'ai': true,
      });
    }
    setState(() {
      _aiLoading = false;
      _aiError = null;
      _candidates = [...aiEntries, ...?_candidates];
    });
  }

  /// 候选条底部的 AI 辅助行：入口按钮 / 进行中 / 失败原因 + 重试。
  /// AI 三步分析标记的切分问题提示（橙色横幅）：说明该字框可能切半/
  /// 粘字/多墨，修复入口在本行卡片的「按 AI 标记局部修复」按钮。
  Widget _buildBoxIssueBanner() {
    final issue = widget.char.aiBoxIssue ?? '';
    final label = switch (issue) {
      'char_clipped' => '字形被框切掉一部分（可能只显示半个字）',
      'char_merged' => '一个框里装了两个字',
      'char_extra_ink' => '框多包进了旁边的墨迹',
      _ => 'AI 认为该字框裁切有问题',
    };
    final note = widget.char.aiBoxNote ?? '';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.deepOrange.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.deepOrange.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            size: 14,
            color: Colors.deepOrange,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              note.isEmpty ? 'AI 标记：$label' : 'AI 标记：$label（$note）',
              style: const TextStyle(fontSize: 11.5, color: Colors.deepOrange),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAiRow() {
    Widget content;
    if (_aiLoading) {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text(
            'AI 分析中（首次加载模型可能较慢）…',
            style: TextStyle(fontSize: 12, color: Colors.deepPurple.shade700),
          ),
        ],
      );
    } else if (_aiError != null) {
      content = Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _aiError!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: Colors.red.shade700),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _requestAiAssist,
                icon: const Icon(Icons.refresh, size: 14),
                label: const Text('重试', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 0,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          ],
        ),
      );
    } else {
      final punct = widget.isPunctLike;
      final model = _aiModelLabel;
      content = TextButton.icon(
        onPressed: _requestAiAssist,
        icon: Icon(
          Icons.auto_awesome,
          size: 15,
          color: Colors.deepPurple.shade700,
        ),
        label: Text(
          punct
              ? 'AI 标点辅助（按上下文）'
              : 'AI 辅助识别${model == null ? '' : ' · $model'}',
          style: TextStyle(fontSize: 12, color: Colors.deepPurple.shade700),
        ),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: Colors.deepPurple.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(children: [content]),
    );
  }

  /// 关闭浮层并提交：[commitText] 显式给定（点候选）时优先，否则提交
  /// 输入框的当前内容；提交为空文字即清空该字。特殊字标记的本地翻转
  /// 也在此一并提交（只翻转标记不改文字时同样要写回）。
  void _close({String? commitText}) {
    if (_closed) return;
    _closed = true;
    FocusManager.instance.primaryFocus?.unfocus();
    widget.onDismiss();
    final text = (commitText ?? _controller.text).trim();
    if (text != widget.char.text || _marked != widget.char.marked) {
      widget.onCharUpdated(
        widget.char,
        widget.char.copyWith(text: text, marked: _marked),
      );
    }
  }

  /// 删除本识别框：只关闭浮层（不提交输入框里的半成品文字）再回调删除。
  void _deleteBox() {
    if (_closed) return;
    _closed = true;
    FocusManager.instance.primaryFocus?.unfocus();
    widget.onDismiss();
    widget.onCharDeleted();
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);

    // ── 就地输入框：精确盖在被点字 chip 的位置上 ──
    final fontSize = max(widget.anchor.height, 20.0);
    final fieldWidth = max(fontSize + 16, 56.0);
    final double fieldLeft = (widget.anchor.center.dx - fieldWidth / 2)
        .clamp(4.0, max(4.0, screen.width - fieldWidth - 4))
        .toDouble();
    final fieldTop = max(
      4.0,
      widget.anchor.center.dy - widget.anchor.height / 2,
    );

    // ── 候选条：正下方，放不下时翻到上方 ──
    const popupWidth = 336.0;
    const estimatedHeight = 168.0;
    final double panelLeft = (widget.anchor.center.dx - popupWidth / 2)
        .clamp(8.0, max(8.0, screen.width - popupWidth - 8))
        .toDouble();
    final below = widget.anchor.bottom + 6;
    final panelTop = below + estimatedHeight <= screen.height
        ? below
        : max(8.0, widget.anchor.top - estimatedHeight - 6);

    return Stack(
      children: [
        // 全屏透明屏障：点空白处 = 提交输入框内容并关闭
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => _close(),
          ),
        ),
        Positioned(
          left: fieldLeft,
          top: fieldTop,
          child: SizedBox(
            width: fieldWidth,
            height: widget.anchor.height,
            child: Material(
              type: MaterialType.transparency,
              child: Center(
                child: TextField(
                  controller: _controller,
                  focusNode: _fieldFocus,
                  autofocus: true,
                  textAlign: TextAlign.center,
                  textAlignVertical: TextAlignVertical.center,
                  strutStyle: StrutStyle(
                    fontSize: fontSize,
                    height: 1,
                    leading: 0,
                  ),
                  style: TextStyle(
                    fontSize: fontSize,
                    height: 1.0,
                    leadingDistribution: TextLeadingDistribution.even,
                  ),
                  cursorColor: Colors.orange.shade700,
                  decoration: InputDecoration(
                    isCollapsed: true,
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide(
                        color: Colors.orange.shade700,
                        width: 2,
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide(
                        color: Colors.orange.shade700,
                        width: 2,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide(
                        color: Colors.orange.shade700,
                        width: 2,
                      ),
                    ),
                  ),
                  onSubmitted: (_) => _close(),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: panelLeft,
          top: panelTop,
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(10),
            color: Colors.white,
            child: Container(
              width: popupWidth,
              padding: const EdgeInsets.all(10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Builder(
                    builder: (_) {
                      final candidates = _candidates;
                      if (candidates == null) {
                        return const SizedBox(
                          height: 44,
                          child: Center(
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        );
                      }
                      if (candidates.isEmpty) {
                        return SizedBox(
                          height: 44,
                          child: Center(
                            child: Text(
                              '无候选',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade500,
                              ),
                            ),
                          ),
                        );
                      }
                      return Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final cand in candidates)
                            _QuickCandidateCell(
                              text: (cand['text']?.toString() ?? '?').isEmpty
                                  ? '?'
                                  : (cand['text']?.toString() ?? '?').substring(
                                      0,
                                      1,
                                    ),
                              score: (cand['score'] as num?)?.toDouble() ?? 0,
                              isCurrent:
                                  cand['text']?.toString() == widget.char.text,
                              isAi: cand['ai'] == true,
                              reason: cand['reason']?.toString() ?? '',
                              onTap: () => _close(
                                commitText: cand['text']?.toString() ?? '',
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 6),
                  if ((widget.char.aiBoxIssue ?? '').isNotEmpty)
                    _buildBoxIssueBanner(),
                  _buildAiRow(),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Tooltip(
                        message: _marked
                            ? '取消特殊字标记（关闭浮层时生效）'
                            : '标记为特殊字：可能裁分有问题或暂无法识别，'
                                  '等全书识别完成后在墨迹归类里集中校对'
                                  '（关闭浮层时生效）',
                        child: TextButton.icon(
                          onPressed: () => setState(() => _marked = !_marked),
                          icon: Icon(
                            _marked ? Icons.flag : Icons.flag_outlined,
                            size: 15,
                            color: _marked
                                ? Colors.deepOrange.shade700
                                : Colors.blueGrey.shade700,
                          ),
                          label: Text(
                            _marked ? '取消标记' : '标记特殊字',
                            style: TextStyle(
                              fontSize: 12,
                              color: _marked
                                  ? Colors.deepOrange.shade700
                                  : Colors.blueGrey.shade700,
                            ),
                          ),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: _deleteBox,
                        icon: Icon(
                          Icons.delete_outline,
                          size: 15,
                          color: Colors.red.shade700,
                        ),
                        label: Text(
                          '删除识别框',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.red.shade700,
                          ),
                        ),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 单字读音（带声调拼音，取最常见读法）；生僻字/异体字/非汉字查不到
/// 返回空串，候选格不显示读音行。查不到时库会原样返回原字符，一并
/// 视为无读音。
String charPinyin(String ch) {
  if (ch.length != 1) return '';
  final py = PinyinHelper.getPinyinE(
    ch,
    defPinyin: '',
    format: PinyinFormat.WITH_TONE_MARK,
  ).trim();
  if (py.isEmpty || py == ch) return '';
  return py;
}

class _QuickCandidateCell extends StatelessWidget {
  final String text;
  final double score;
  final bool isCurrent;

  /// Ollama AI 给出的候选：紫色描边 + 右上角 AI 角标区分来源。
  final bool isAi;

  /// AI 给出的简短理由，悬停 tooltip 展示。
  final String reason;
  final VoidCallback onTap;

  const _QuickCandidateCell({
    required this.text,
    required this.score,
    required this.isCurrent,
    this.isAi = false,
    this.reason = '',
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pinyin = charPinyin(text);
    Widget cell = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isCurrent
            ? Colors.orange.withValues(alpha: 0.15)
            : isAi
            ? Colors.deepPurple.withValues(alpha: 0.08)
            : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isCurrent
              ? Colors.orange.shade300
              : isAi
              ? Colors.deepPurple.shade300
              : Colors.grey.shade300,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Text(text, style: const TextStyle(fontSize: 26, height: 1.1)),
              if (isAi)
                Positioned(
                  top: -7,
                  right: -13,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 3,
                      vertical: 0,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.deepPurple.shade600,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'AI',
                      style: TextStyle(
                        fontSize: 8,
                        height: 1.4,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (pinyin.isNotEmpty)
            Text(
              pinyin,
              style: TextStyle(
                fontSize: 9,
                height: 1.2,
                color: Colors.blue.shade600,
              ),
            ),
          Text(
            isAi
                ? (score > 0 ? '${(score * 100).toStringAsFixed(0)}%' : 'AI')
                : '${(score * 100).toStringAsFixed(0)}%',
            style: TextStyle(
              fontSize: 9,
              color: isAi ? Colors.deepPurple.shade600 : Colors.grey.shade600,
            ),
          ),
        ],
      ),
    );
    if (reason.isNotEmpty) {
      cell = Tooltip(message: reason, child: cell);
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: cell,
    );
  }
}

// ─── 行裁切图像 Painter ──────────────────────────────────────────────────────

class _LineCropPainter extends CustomPainter {
  final ui.Image image;
  final Rect srcRect;
  final List<Rect> charRects;

  /// 与 charRects 平行的行内彩虹色（null 时回退蓝色）。
  final List<Color?> charColors;

  /// 与 charRects 平行的"异常高字框"标记（true 时描边用 kTallBoxRed）。
  final List<bool> tallFlags;

  /// 与 charRects 平行的墨迹校验标记色（mismatch 红/suspect 琥珀，
  /// null 未标记）：优先于彩虹色描边，与画布虚线框同口径。
  final List<Color?> verifyColors;
  final Rect? selectedRect;
  final Rect? dragRect;

  _LineCropPainter({
    required this.image,
    required this.srcRect,
    this.charRects = const [],
    this.charColors = const [],
    this.tallFlags = const [],
    this.verifyColors = const [],
    this.selectedRect,
    this.dragRect,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 行框退化（宽/高为 0 → srcRect 空或 NaN）时只画字框层：空 src 进
    // drawImageRect、Infinity 进 drawRect 都会触发引擎断言崩溃。
    final srcOk =
        srcRect.width > 0 &&
        srcRect.height > 0 &&
        srcRect.left.isFinite &&
        srcRect.top.isFinite;
    if (srcOk && size.width > 0 && size.height > 0) {
      // 整页大图取样到 60px 级别的小图，low 档采样质量足够且每帧开销最小。
      canvas.drawImageRect(
        image,
        srcRect,
        Offset.zero & size,
        Paint()..filterQuality = FilterQuality.low,
      );
    }

    final scaleX = srcOk ? size.width / srcRect.width : 1.0;
    final scaleY = srcOk ? size.height / srcRect.height : 1.0;

    final selectedPaint = Paint()
      ..style = PaintingStyle.stroke
      ..color = Colors.orange
      ..strokeWidth = 2.0;
    final selectedFill = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.orange.withValues(alpha: 0.15);

    for (var i = 0; i < charRects.length; i++) {
      final r = charRects[i];
      final dr = Rect.fromLTWH(
        r.left * scaleX,
        r.top * scaleY,
        r.width * scaleX,
        r.height * scaleY,
      );
      final color = i < charColors.length && charColors[i] != null
          ? charColors[i]!
          : Colors.blue;
      final tall = i < tallFlags.length && tallFlags[i];
      final verify = i < verifyColors.length ? verifyColors[i] : null;
      canvas.drawRect(
        dr,
        Paint()
          ..style = PaintingStyle.fill
          ..color = (tall ? kTallBoxRed : color).withValues(alpha: 0.22),
      );
      if (verify != null) {
        // 墨迹校验标记：小图上的迷你虚线（段长随图缩放）
        final path = Path()..addRect(dr);
        final dash = Paint()
          ..style = PaintingStyle.stroke
          ..color = verify
          ..strokeWidth = 2.0;
        for (final metric in path.computeMetrics()) {
          double dist = 0;
          var draw = true;
          while (dist < metric.length) {
            final seg = draw ? 5.0 : 3.0;
            if (draw) {
              canvas.drawPath(metric.extractPath(dist, dist + seg), dash);
            }
            dist += seg;
            draw = !draw;
          }
        }
      } else {
        canvas.drawRect(
          dr,
          Paint()
            ..style = PaintingStyle.stroke
            ..color = tall ? kTallBoxRed : color.withValues(alpha: 0.9)
            ..strokeWidth = tall ? 2.4 : 1.2,
        );
      }
    }

    if (selectedRect != null) {
      final dr = Rect.fromLTWH(
        selectedRect!.left * scaleX,
        selectedRect!.top * scaleY,
        selectedRect!.width * scaleX,
        selectedRect!.height * scaleY,
      );
      canvas.drawRect(dr, selectedFill);
      canvas.drawRect(dr, selectedPaint);
      // resize handle：以角点为中心的 8×8，中心与命中区同心（角点先
      // clamp 进画布内缩 5px——框角贴边时会被外层圆角/边框裁掉一角，
      // 视觉中心偏内、与命中错位；横排扁行图上最严重）。
      // 右下=拉宽高；右上=拉顶边与右边（竖排行压首字上沿常用）。
      const handleInset = 5.0;
      for (final corner in [dr.topRight, dr.bottomRight]) {
        final double cx = corner.dx
            .clamp(handleInset, max(handleInset, size.width - handleInset))
            .toDouble();
        final double cy = corner.dy
            .clamp(handleInset, max(handleInset, size.height - handleInset))
            .toDouble();
        final handleRect = Rect.fromCenter(
          center: Offset(cx, cy),
          width: 8,
          height: 8,
        );
        canvas.drawRect(handleRect, Paint()..color = Colors.orange);
        canvas.drawRect(
          handleRect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = Colors.white,
        );
      }
    }

    if (dragRect != null) {
      final dr = Rect.fromLTWH(
        dragRect!.left * scaleX,
        dragRect!.top * scaleY,
        dragRect!.width * scaleX,
        dragRect!.height * scaleY,
      );
      canvas.drawRect(
        dr,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = Colors.teal.withValues(alpha: 0.8)
          ..strokeWidth = 1.5,
      );
      canvas.drawRect(
        dr,
        Paint()
          ..style = PaintingStyle.fill
          ..color = Colors.teal.withValues(alpha: 0.1),
      );
    }

    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.black.withValues(alpha: 0.1)
        ..strokeWidth = 0.5,
    );
  }

  @override
  bool shouldRepaint(covariant _LineCropPainter old) =>
      image != old.image ||
      srcRect != old.srcRect ||
      charRects != old.charRects ||
      charColors != old.charColors ||
      tallFlags != old.tallFlags ||
      selectedRect != old.selectedRect ||
      dragRect != old.dragRect;
}

// ─── 可交互行裁切画布：绘制/拖拽/调整字框 ──────────────────────────────────────

/// 行图内单字框的缩放角点：右下拉宽高，右上拉顶边与右边。
enum _CropResizeHandle { topRight, bottomRight }

/// 行图裁切 + 行内单字框交互层（点选/拖动移动/拖角缩放/空白处画新框）。
/// 编辑器详细视图行卡片与「行内重切」页（全书墨迹归类页双击字格进入）
/// 共用：line 传任意行块实例，其几何与 chars 坐标在同一空间（相对 image
/// 的像素坐标）即可，改动经三个回调交还调用方。
class InteractiveLineCrop extends StatefulWidget {
  final ui.Image image;
  final Rect srcRect;
  final LineBlock line;
  final double displayWidth;
  final double displayHeight;
  final CharBlock? selected;

  /// 「定位」后呼吸闪烁的字块 id：在行图上该字框位置叠加闪烁框。
  final String? flashCharId;
  final void Function(CharBlock old, CharBlock updated) onCharUpdated;
  final ValueChanged<CharBlock> onCharAdded;
  final ValueChanged<CharBlock?> onCharSelected;

  /// Shift 单击字框＝删除（可选：编辑器行卡片与行内重切页都接了；
  /// 未接的调用方该操作无动作）。
  final ValueChanged<CharBlock>? onCharDeleted;

  const InteractiveLineCrop({
    super.key,
    required this.image,
    required this.srcRect,
    required this.line,
    required this.displayWidth,
    required this.displayHeight,
    required this.selected,
    required this.flashCharId,
    required this.onCharUpdated,
    required this.onCharAdded,
    required this.onCharSelected,
    this.onCharDeleted,
  });

  @override
  State<InteractiveLineCrop> createState() => _InteractiveLineCropState();
}

class _InteractiveLineCropState extends State<InteractiveLineCrop> {
  Offset? _dragStart;
  Offset? _dragCurrent;
  CharBlock? _dragging;
  CharBlock? _gestureOriginal;
  Offset? _dragOffset;
  CharBlock? _resizing;
  _CropResizeHandle? _resizeHandle;
  Offset? _resizePointerOffset;

  /// Ctrl 联动邻框的实时预览：按住 Ctrl 拖字框手柄时，沿阅读轴相邻
  /// 字框的贴合边跟随同样的位移（保持两框原有间距，不对齐到同一位置）。
  /// 与被拖框一样本地预览、松手时一并提交。
  CharBlock? _linkedNeighbor;

  /// 按下时命中的容差候选框（按下点在框外 3px 内）：点击＝选中它，
  /// 拖动＝画新框（候选作废）。拖拽只允许从框内开始，保证画框起点
  /// 精确落在鼠标按下位置。
  CharBlock? _pressCandidate;

  final GlobalKey _canvasKey = GlobalKey();

  /// 画布实际渲染尺寸（painter 的 size 同源）。命中换算一律用实际
  /// 尺寸而不是布局参数：SizedBox 请求的宽高一旦被父级约束压缩
  /// （如横排行图超宽被压回卡片宽），参数与实际就是两套数字——
  /// 绘制按实际、命中按参数，手柄与鼠标错开二百多像素。
  Size get _canvasSize {
    final ro = _canvasKey.currentContext?.findRenderObject();
    return ro is RenderBox && ro.hasSize
        ? ro.size
        : Size(widget.displayWidth, widget.displayHeight);
  }

  double get _scaleX => _canvasSize.width / widget.srcRect.width;
  double get _scaleY => _canvasSize.height / widget.srcRect.height;

  /// 命中/手柄的显示坐标系宽度上限（clamp 边界与实际画布一致）。
  double get _displayW => _canvasSize.width;
  double get _displayH => _canvasSize.height;

  /// 显示坐标 → 行内相对坐标（相对 line.x / line.y）
  Offset _displayToLineRel(Offset displayPos) =>
      Offset(displayPos.dx / _scaleX, displayPos.dy / _scaleY);

  /// 行内相对坐标 → 原图绝对坐标
  int _toAbsX(double rel) => (rel + widget.line.x).round();
  int _toAbsY(double rel) => (rel + widget.line.y).round();

  CharBlock? _hitTestChar(Offset displayPos, {double toleranceScreen = 3}) {
    final rel = _displayToLineRel(displayPos);
    final chars = widget.line.chars.toList(growable: false);
    final rects = chars
        .map(
          (c) => Rect.fromLTWH(
            (c.x - widget.line.x).toDouble(),
            (c.y - widget.line.y).toDouble(),
            c.w.toDouble(),
            c.h.toDouble(),
          ),
        )
        .toList(growable: false);
    final index = AnnotationHitGeometry.hitRectIndex(
      rects,
      rel,
      scaleX: _scaleX,
      scaleY: _scaleY,
      // 命中范围必须与画出的框一致：大容差会把字框间隙整个盖住，
      // 想在空白处画新框时会先"命中"邻框变成拖动它。
      toleranceScreen: toleranceScreen,
    );
    return index == null ? null : chars[index];
  }

  Offset _handleCenterRel(CharBlock c, _CropResizeHandle handle) =>
      switch (handle) {
        _CropResizeHandle.topRight => Offset(
          (c.x - widget.line.x + c.w).toDouble(),
          (c.y - widget.line.y).toDouble(),
        ),
        _CropResizeHandle.bottomRight => Offset(
          (c.x - widget.line.x + c.w).toDouble(),
          (c.y - widget.line.y + c.h).toDouble(),
        ),
      };

  /// 手柄中心（显示坐标）：框角 clamp 进显示区内缩 5px。
  ///
  /// 框角恰在显示区最角落，外层 ClipRRect 的 4px 圆角与 1px 边框会把
  /// 画在框角上的手柄裁掉一角——看见的手柄残缺、视觉中心偏内，而命
  /// 中区仍以真框角为中心，鼠标与顶点错位（横排行图高仅十几像素时
  /// 被裁近 1/3，错位最严重）。命中/绘制/拖动锚点共用本公式保证同心。
  Offset _handleCenterDisplay(CharBlock c, _CropResizeHandle handle) {
    final rel = _handleCenterRel(c, handle);
    const inset = 5.0;
    final maxX = max(inset, _displayW - inset);
    final maxY = max(inset, _displayH - inset);
    return Offset(
      (rel.dx * _scaleX).clamp(inset, maxX),
      (rel.dy * _scaleY).clamp(inset, maxY),
    );
  }

  _CropResizeHandle? _hitResizeHandle(CharBlock c, Offset displayPos) {
    // 角点居中的 16×16 屏幕像素命中区（角内外各 8px），中心用收进显示
    // 区后的手柄位置（与绘制同心）。命中区外半边在字框命中测试范围之
    // 外，必须在 onPointerDown 里优先判定手柄，否则角点外侧永远点不到
    // （与全图画布的处理方式一致）。两角命中区重叠（屏幕上框很矮）时
    // 取更近的角。
    _CropResizeHandle? nearest;
    var nearestDistance = double.infinity;
    for (final handle in _CropResizeHandle.values) {
      final center = _handleCenterDisplay(c, handle);
      if (!Rect.fromCenter(
        center: center,
        width: 16,
        height: 16,
      ).contains(displayPos)) {
        continue;
      }
      final distance = (center - displayPos).distanceSquared;
      if (distance < nearestDistance) {
        nearest = handle;
        nearestDistance = distance;
      }
    }
    return nearest;
  }

  void _beginResize(CharBlock c, Offset displayPos, _CropResizeHandle handle) {
    final rel = _displayToLineRel(displayPos);
    // 拖动锚点 = 抓住的手柄中心（显示坐标转回行内图像坐标），保证
    // "抓住哪里、哪里跟随指针"。
    final centerDisplay = _handleCenterDisplay(c, handle);
    final anchorRel = Offset(
      centerDisplay.dx / _scaleX,
      centerDisplay.dy / _scaleY,
    );
    // 手势诊断：lineId 不匹配/字框越出行框的"个别字框"问题定位依据。
    PythonService.addAppLog(
      '[手势] 行卡片缩放开始 line=${widget.line.id} '
      'lineRect=(${widget.line.x},${widget.line.y},${widget.line.w},${widget.line.h}) '
      'char=${c.id}#${c.order} lineId=${c.lineId} '
      'lineId匹配=${c.lineId == widget.line.id} '
      'charRect=(${c.x},${c.y},${c.w},${c.h}) handle=$handle',
      isError: c.lineId != widget.line.id,
    );
    setState(() {
      _resizing = c;
      _gestureOriginal = c;
      _resizeHandle = handle;
      _resizePointerOffset = rel - anchorRel;
    });
  }

  /// 缩放实时预览：被拖框跟随指针，同时（按住 Ctrl 时）联动邻框。
  void _commitResizePreview(CharBlock updated) {
    setState(() {
      _resizing = updated;
      _linkedNeighbor = _linkedNeighborAfterResize(updated);
    });
  }

  /// Ctrl 联动：按住 Ctrl 拖字框手柄 → 阅读轴上相邻字框的贴合边跟随
  /// 同样的位移，保持两框原有间距（不对齐到同一位置）。邻框选取与位移
  /// 每次都基于按下快照（手势期间 line.chars 未提交，即原框）计算，
  /// 反复取整不累计漂移。未按 Ctrl / 无邻框 / 位移取整后为 0 返回 null。
  CharBlock? _linkedNeighborAfterResize(CharBlock updated) {
    if (!HardwareKeyboard.instance.isControlPressed) return null;
    final original = _gestureOriginal;
    if (original == null) return null;
    final horizontal = widget.line.orientation == 'horizontal';
    final upward = !horizontal && _resizeHandle == _CropResizeHandle.topRight;
    Rect rectOf(CharBlock c) => Rect.fromLTWH(
      c.x.toDouble(),
      c.y.toDouble(),
      c.w.toDouble(),
      c.h.toDouble(),
    );
    final chars = widget.line.chars;
    final rects = [for (final c in chars) rectOf(c)];
    final draggedIndex = chars.indexWhere((c) => c.id == original.id);
    final neighborIndex = AnnotationHitGeometry.linkedNeighborIndex(
      rects,
      draggedIndex,
      horizontal: horizontal,
      upward: upward,
    );
    if (neighborIndex == null) return null;
    final newRect = AnnotationHitGeometry.linkedNeighborRect(
      horizontal: horizontal,
      upward: upward,
      draggedOriginal: rectOf(original),
      draggedUpdated: rectOf(updated),
      neighborOriginal: rects[neighborIndex],
    );
    if (newRect == null) return null;
    return chars[neighborIndex].copyWith(
      x: newRect.left.toInt(),
      y: newRect.top.toInt(),
      w: newRect.width.toInt(),
      h: newRect.height.toInt(),
    );
  }

  /// Alt 单击字框：沿阅读轴拆成两半——竖排上下、横排左右（原框就地改
  /// 成前半，走 onCharUpdated 触发重识别；后半作为新字框走 onCharAdded，
  /// 编辑器按阅读序插到原框之后、行内重切页应用时按几何重排）。轴向
  /// 太薄（拆完不足最小框 5px）不拆，仅选中提示。
  void _splitChar(CharBlock c) {
    final horizontal = widget.line.orientation == 'horizontal';
    final halves = AnnotationHitGeometry.splitRectHalf(
      Rect.fromLTWH(
        c.x.toDouble(),
        c.y.toDouble(),
        c.w.toDouble(),
        c.h.toDouble(),
      ),
      horizontal: horizontal,
    );
    if (halves == null) {
      widget.onCharSelected(c);
      PythonService.addAppLog(
        '[手势] 行卡片 Alt 拆分跳过：框太薄 char=${c.id} '
        '轴向长度=${horizontal ? c.w : c.h}（拆完不足最小框 5px）',
      );
      return;
    }
    final (firstRect, secondRect) = halves;
    final first = c.copyWith(
      x: firstRect.left.toInt(),
      y: firstRect.top.toInt(),
      w: firstRect.width.toInt(),
      h: firstRect.height.toInt(),
    );
    final secondId = 'u_${DateTime.now().millisecondsSinceEpoch}';
    final second = CharBlock(
      id: secondId,
      x: secondRect.left.toInt(),
      y: secondRect.top.toInt(),
      w: secondRect.width.toInt(),
      h: secondRect.height.toInt(),
      col: widget.line.lineNo,
      order: widget.line.chars.length,
      lineId: widget.line.id,
    );
    PythonService.addAppLog(
      '[手势] 行卡片 Alt 拆分 char=${c.id} '
      '(${c.x},${c.y},${c.w},${c.h}) -> '
      '前半(${first.x},${first.y},${first.w},${first.h}) + '
      '新框 $secondId(${second.x},${second.y},${second.w},${second.h})',
    );
    widget.onCharUpdated(c, first);
    widget.onCharAdded(second);
  }

  void _clearState() {
    _dragStart = null;
    _dragCurrent = null;
    _dragging = null;
    _gestureOriginal = null;
    _dragOffset = null;
    _resizing = null;
    _resizeHandle = null;
    _resizePointerOffset = null;
    _linkedNeighbor = null;
    _pressCandidate = null;
  }

  @override
  Widget build(BuildContext context) {
    // Draw the in-progress move/resize locally. Committing on pointer-up
    // avoids rebuilding the whole detail list for every mouse-move event.
    final previewChars = widget.line.chars.map((c) {
      if (_dragging != null && c.id == _dragging!.id) return _dragging!;
      if (_resizing != null && c.id == _resizing!.id) return _resizing!;
      if (_linkedNeighbor != null && c.id == _linkedNeighbor!.id) {
        return _linkedNeighbor!;
      }
      return c;
    });
    final charRects = previewChars
        .map(
          (c) => Rect.fromLTWH(
            (c.x - widget.line.x).toDouble(),
            (c.y - widget.line.y).toDouble(),
            c.w.toDouble(),
            c.h.toDouble(),
          ),
        )
        .toList();
    // 行内彩虹色与字列表/整行文字严格按 order 对应
    final charColors = previewChars
        .map((c) => charRainbowColor(c.order))
        .toList();
    // 行内异常高字框（字+标点同框/两字粘连等）红色提示，与画布同口径
    final medianH = lineMedianCharHeight(widget.line.chars);
    final tallFlags = previewChars
        .map((c) => isTallCharBox(c, medianH))
        .toList();
    // 墨迹校验标记色（mismatch 红/suspect 琥珀），与画布虚线框同口径
    final verifyColors = previewChars.map(verifyFlagColor).toList();

    // 选中框/缩放手柄同样用实时预览（_resizing/_dragging 替换）：字框
    // 彩虹矩形跟随指针而手柄钉在旧位置的错位，正是"拖右上角顶点、其他
    // 顶点不跟手"的来源——提交只在松手时发生，绘制不能等提交。
    var selBlock = widget.selected;
    if (selBlock != null && selBlock.lineId == widget.line.id) {
      if (_resizing != null && _resizing!.id == selBlock.id) {
        selBlock = _resizing;
      } else if (_dragging != null && _dragging!.id == selBlock.id) {
        selBlock = _dragging;
      }
    }
    final selectedRel = selBlock != null && selBlock.lineId == widget.line.id
        ? Rect.fromLTWH(
            (selBlock.x - widget.line.x).toDouble(),
            (selBlock.y - widget.line.y).toDouble(),
            selBlock.w.toDouble(),
            selBlock.h.toDouble(),
          )
        : null;

    final dragRel = (_dragStart != null && _dragCurrent != null)
        ? Rect.fromPoints(
            _displayToLineRel(_dragStart!),
            _displayToLineRel(_dragCurrent!),
          )
        : null;

    // 「定位」闪烁字框（屏幕坐标）：命中换算同 selectedRel，只换比例
    Rect? flashRel;
    final flashId = widget.flashCharId;
    if (flashId != null) {
      for (final c in widget.line.chars) {
        if (c.id == flashId) {
          flashRel = Rect.fromLTWH(
            (c.x - widget.line.x) * _scaleX,
            (c.y - widget.line.y) * _scaleY,
            c.w * _scaleX,
            c.h * _scaleY,
          );
          break;
        }
      }
    }

    return Container(
      // 不给外层 Container 显式宽高：decoration 的 1px 边框会把 child 内缩
      // （BoxDecoration.padding = border.dimensions），画布实际尺寸会比
      // displayWidth/Height 小 2px，命中换算与绘制换算随之出现随位置增大
      // 的偏差。精确尺寸由内部 SizedBox 保证，容器随内容自适应。
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(4),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) {
            if (e.buttons != kPrimaryMouseButton) return;
            final pos = e.localPosition;

            // 修饰键单击（速校对操作，命中字框才消费，点空白照常画框）：
            // Shift＝删除字框、Alt＝沿阅读轴拆成两半（竖排上下/横排左右）。
            final kb = HardwareKeyboard.instance;
            if (kb.isShiftPressed || kb.isAltPressed) {
              final hitMod = _hitTestChar(pos, toleranceScreen: 0);
              if (hitMod != null) {
                if (kb.isShiftPressed) {
                  widget.onCharDeleted?.call(hitMod);
                } else {
                  _splitChar(hitMod);
                }
                return;
              }
            }

            // 选中字框的缩放手柄优先判定：手柄命中区有半个在框外，
            // 且角点可能被相邻字框盖住，先于普通命中测试判断才能点到。
            final sel = widget.selected;
            if (sel != null && sel.lineId == widget.line.id) {
              final selHandle = _hitResizeHandle(sel, pos);
              if (selHandle != null) {
                widget.onCharSelected(sel);
                _beginResize(sel, pos, selHandle);
                return;
              }
            }

            // 只有真正按在框内才拖动；框附近的容差命中只作为"点击选中"
            // 候选，拖动一律从按下位置开始画新框——否则在字框间隙画框
            // 会先抓到邻框，框的角点带着抓取偏移跟随光标（看似画框偏移）。
            final hit = _hitTestChar(pos);
            final hitExact = _hitTestChar(pos, toleranceScreen: 0);
            if (hitExact != null) {
              widget.onCharSelected(hitExact);
              final hitHandle = _hitResizeHandle(hitExact, pos);
              if (hitHandle != null) {
                _beginResize(hitExact, pos, hitHandle);
              } else {
                final rel = _displayToLineRel(pos);
                setState(() {
                  _dragging = hitExact;
                  _gestureOriginal = hitExact;
                  _dragOffset =
                      rel -
                      Offset(
                        (hitExact.x - widget.line.x).toDouble(),
                        (hitExact.y - widget.line.y).toDouble(),
                      );
                });
              }
            } else {
              setState(() {
                _pressCandidate = hit;
                _dragStart = pos;
                _dragCurrent = pos;
              });
              // 容差候选立即高亮（等效于点击选中）；随后拖动则转为画框
              widget.onCharSelected(hit);
            }
          },
          onPointerMove: (e) {
            if (e.buttons != kPrimaryMouseButton) return;
            final pos = e.localPosition;

            if (_resizing != null) {
              final b = _resizing!;
              final rel = _displayToLineRel(pos);
              final resizeRel = rel - (_resizePointerOffset ?? Offset.zero);
              if (_resizeHandle == _CropResizeHandle.topRight) {
                // 右上角：底边与左边固定，顶边/右边跟随指针（压首字
                // 上沿常用）；顶边不越过底边-5、不出页面顶（abs y ≥ 0）。
                // 固定边必须直接取整数原值、拖动边只做一次取整：顶边/
                // 高度各自独立取整时，显示比例把指针映射到半整数会让
                // 两处同时进位，固定底边每个事件下移 1px（实测一次拖拽
                // 累计 +59px）——"其他顶点跟着偏移"的根因。
                final resizedRect = AnnotationHitGeometry.resizeTopRightRect(
                  Rect.fromLTWH(
                    b.x.toDouble(),
                    b.y.toDouble(),
                    b.w.toDouble(),
                    b.h.toDouble(),
                  ),
                  widget.line.x + resizeRel.dx,
                  widget.line.y + resizeRel.dy,
                );
                final updated = b.copyWith(
                  x: resizedRect.left.toInt(),
                  y: resizedRect.top.toInt(),
                  w: resizedRect.width.round(),
                  h: resizedRect.height.round(),
                );
                _commitResizePreview(updated);
              } else {
                final newW = max(
                  5,
                  resizeRel.dx - (b.x - widget.line.x),
                ).toInt();
                final newH = max(
                  5,
                  resizeRel.dy - (b.y - widget.line.y),
                ).toInt();
                final updated = b.copyWith(w: newW, h: newH);
                _commitResizePreview(updated);
              }
            } else if (_dragging != null && _dragOffset != null) {
              final b = _dragging!;
              final rel = _displayToLineRel(pos);
              final newRelX = max(0.0, rel.dx - _dragOffset!.dx);
              final newRelY = max(0.0, rel.dy - _dragOffset!.dy);
              final updated = b.copyWith(
                x: _toAbsX(newRelX),
                y: _toAbsY(newRelY),
              );
              setState(() => _dragging = updated);
            } else if (_dragStart != null) {
              // 开始拖动即确认是画框手势：容差候选作废，取消其选中
              if (_pressCandidate != null) {
                _pressCandidate = null;
                widget.onCharSelected(null);
              }
              setState(() => _dragCurrent = pos);
            }
          },
          onPointerUp: (e) {
            if (_gestureOriginal != null) {
              final current = _resizing ?? _dragging;
              if (current != null &&
                  (current.x != _gestureOriginal!.x ||
                      current.y != _gestureOriginal!.y ||
                      current.w != _gestureOriginal!.w ||
                      current.h != _gestureOriginal!.h)) {
                PythonService.addAppLog(
                  '[手势] 行卡片手势提交 ${_gestureOriginal!.id} '
                  '(${_gestureOriginal!.x},${_gestureOriginal!.y},'
                  '${_gestureOriginal!.w},${_gestureOriginal!.h}) -> '
                  '(${current.x},${current.y},${current.w},${current.h})',
                );
                widget.onCharUpdated(_gestureOriginal!, current);
              } else if (current != null) {
                PythonService.addAppLog(
                  '[手势] 行卡片手势无几何变化 ${current.id}（点击或未拖出变化）',
                );
              }
            }
            // Ctrl 联动邻框随被拖框一起提交（两框几何都变 → 各自重识别）
            final linked = _linkedNeighbor;
            if (linked != null) {
              CharBlock? neighborOriginal;
              for (final c in widget.line.chars) {
                if (c.id == linked.id) neighborOriginal = c;
              }
              if (neighborOriginal != null &&
                  (linked.x != neighborOriginal.x ||
                      linked.y != neighborOriginal.y ||
                      linked.w != neighborOriginal.w ||
                      linked.h != neighborOriginal.h)) {
                PythonService.addAppLog(
                  '[手势] 行卡片 Ctrl 联动提交 ${neighborOriginal.id} '
                  '(${neighborOriginal.x},${neighborOriginal.y},'
                  '${neighborOriginal.w},${neighborOriginal.h}) -> '
                  '(${linked.x},${linked.y},${linked.w},${linked.h})',
                );
                widget.onCharUpdated(neighborOriginal, linked);
              }
            }
            if (_dragStart != null && _dragCurrent != null) {
              final rel = Rect.fromPoints(
                _displayToLineRel(_dragStart!),
                _displayToLineRel(_dragCurrent!),
              );
              if (rel.width > 4 && rel.height > 4) {
                final id = 'u_${DateTime.now().millisecondsSinceEpoch}';
                widget.onCharAdded(
                  CharBlock(
                    id: id,
                    x: _toAbsX(rel.left),
                    y: _toAbsY(rel.top),
                    w: rel.width.round(),
                    h: rel.height.round(),
                    col: widget.line.lineNo,
                    order: widget.line.chars.length,
                    lineId: widget.line.id,
                  ),
                );
              }
            }
            setState(_clearState);
          },
          onPointerCancel: (_) => setState(_clearState),
          // GestureDetector 声明拖拽手势抢占仲裁（回调全是空实现）：外层
          // SingleChildScrollView 否则会把画框/拖框/缩放的拖拽同时识别成
          // 滚动，列表边滚动画框起点边相对鼠标漂移，画出的框尺寸也随之
          // 错乱。本区域赢得仲裁后拖拽期间列表不滚动；滚轮滚动不受影响。
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) {},
            onPanUpdate: (_) {},
            onPanEnd: (_) {},
            onPanCancel: () {},
            // RepaintBoundary：拖动字框时只重绘本行裁切图，避免整个详细视图
            // （每张卡片都从整页大图取样）每帧重新栅格化。
            child: RepaintBoundary(
              child: SizedBox(
                key: _canvasKey,
                // 行框退化（宽/高为 0 → 上游算出 NaN/∞/0 尺寸）时退回
                // 最小占位尺寸：NaN 进入 BoxConstraints 会直接抛错崩页。
                width: widget.displayWidth.isFinite && widget.displayWidth > 0
                    ? widget.displayWidth
                    : 60,
                height:
                    widget.displayHeight.isFinite && widget.displayHeight > 0
                    ? widget.displayHeight
                    : 20,
                child: flashRel == null
                    ? CustomPaint(
                        painter: _LineCropPainter(
                          image: widget.image,
                          srcRect: widget.srcRect,
                          charRects: charRects,
                          charColors: charColors,
                          tallFlags: tallFlags,
                          verifyColors: verifyColors,
                          selectedRect: selectedRel,
                          dragRect: dragRel,
                        ),
                      )
                    : Stack(
                        children: [
                          Positioned.fill(
                            child: CustomPaint(
                              painter: _LineCropPainter(
                                image: widget.image,
                                srcRect: widget.srcRect,
                                charRects: charRects,
                                charColors: charColors,
                                tallFlags: tallFlags,
                                verifyColors: verifyColors,
                                selectedRect: selectedRel,
                                dragRect: dragRel,
                              ),
                            ),
                          ),
                          // 定位闪烁框叠在字框上方；IgnorePointer 保证
                          // 不遮挡行图的拖框/缩放交互。
                          Positioned.fromRect(
                            rect: flashRel,
                            child: IgnorePointer(
                              child: _LocateFlash(
                                active: true,
                                child: const SizedBox.expand(),
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── 详细视图缩放控件 ─────────────────────────────────────────────────────────

class _DetailZoomControls extends StatelessWidget {
  final double cardWidth;
  final double scale;
  final double fontScale;
  final double fontSize;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onReset;
  final VoidCallback onFontScaleUp;
  final VoidCallback onFontScaleDown;
  final VoidCallback onResetFontScale;

  const _DetailZoomControls({
    required this.cardWidth,
    required this.scale,
    required this.fontScale,
    required this.fontSize,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onReset,
    required this.onFontScaleUp,
    required this.onFontScaleDown,
    required this.onResetFontScale,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '卡片缩放',
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              IconButton(
                onPressed: onZoomOut,
                icon: const Icon(Icons.zoom_out),
                tooltip: '缩小卡片',
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                padding: EdgeInsets.zero,
              ),
              IconButton(
                onPressed: onReset,
                icon: const Icon(Icons.restart_alt),
                tooltip: '重置卡片',
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                padding: EdgeInsets.zero,
              ),
              IconButton(
                onPressed: onZoomIn,
                icon: const Icon(Icons.zoom_in),
                tooltip: '放大卡片',
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                padding: EdgeInsets.zero,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '${cardWidth.round()}px\n×${scale.toStringAsFixed(2)}',
                  textAlign: TextAlign.end,
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            '字号',
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              IconButton(
                onPressed: onFontScaleDown,
                icon: const Icon(Icons.text_decrease),
                tooltip: '缩小字号',
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                padding: EdgeInsets.zero,
              ),
              IconButton(
                onPressed: onResetFontScale,
                icon: const Icon(Icons.restart_alt),
                tooltip: '重置字号',
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                padding: EdgeInsets.zero,
              ),
              IconButton(
                onPressed: onFontScaleUp,
                icon: const Icon(Icons.text_increase),
                tooltip: '放大字号',
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                padding: EdgeInsets.zero,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '${fontSize.toStringAsFixed(1)}pt\n×${fontScale.toStringAsFixed(2)}',
                  textAlign: TextAlign.end,
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
            ],
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }
}

// ─── 字符 Chip 纵列：轻点编辑，长按拖拽改变字在行内的位置 ────────────────────────

class _CharChipColumn extends StatefulWidget {
  final LineBlock line;
  final double fontPx;

  /// 竖排几何对齐模式：列高与列1行图一致（每字按字框真实位置定位）。
  /// 0 表示禁用，用旧的等高堆叠布局（横排/行框退化时）。
  final double displayHeight;

  /// 几何对齐模式下的标准字单元高（全部字框高度的中位数）。
  final double stdCell;

  /// 几何对齐模式下的统一列宽。
  final double columnWidth;

  final CharBlock? selected;
  final ValueChanged<CharBlock?> onCharSelected;

  /// 「定位」后呼吸闪烁的字块 id。
  final String? flashCharId;

  /// 轻点字 chip：anchor 为该 chip 的全局矩形，供快捷候选条定位。
  final void Function(CharBlock c, Rect anchor) onEditChar;
  final void Function(int oldIndex, int newIndex) onReorder;

  const _CharChipColumn({
    required this.line,
    required this.fontPx,
    this.displayHeight = 0,
    this.stdCell = 0,
    this.columnWidth = 0,
    required this.selected,
    required this.flashCharId,
    required this.onCharSelected,
    required this.onEditChar,
    required this.onReorder,
  });

  @override
  State<_CharChipColumn> createState() => _CharChipColumnState();
}

class _CharChipColumnState extends State<_CharChipColumn> {
  final GlobalKey _columnKey = GlobalKey();
  int? _dragIndex;
  int? _dropIndex;

  /// 拖拽指针在本列内的 Y 坐标（几何锁定布局下 chip 不随拖动移动，
  /// 用它画插入位置指示线）。
  double? _dragLocalY;

  /// 竖排几何对齐模式：chips 与列1行图同高、每字按字框真实位置定位。
  bool get _geoAligned =>
      widget.line.orientation == 'vertical' &&
      widget.line.h > 0 &&
      widget.displayHeight > 0;

  /// 拖拽中的预览序列：被拖字块已移动到落点槽位（吸附式预览）。
  List<CharBlock> get _displayChars {
    final chars = widget.line.chars;
    final drag = _dragIndex;
    final drop = _dropIndex;
    if (drag == null || drop == null || drag == drop) return chars;
    final list = chars.toList();
    final c = list.removeAt(drag);
    list.insert(drop.clamp(0, list.length), c);
    return list;
  }

  double? _columnLocalY(Offset globalPosition) {
    final box = _columnKey.currentContext?.findRenderObject();
    if (box is! RenderBox) return null;
    return box.globalToLocal(globalPosition).dy;
  }

  void _beginDrag(int charIndex, Offset globalPosition) {
    setState(() {
      _dragIndex = charIndex;
      _dropIndex = charIndex;
      final localY = _columnLocalY(globalPosition);
      _dragLocalY = _geoAligned && localY != null
          ? localY.clamp(0.0, widget.displayHeight).toDouble()
          : null;
    });
  }

  void _updateDragFromPointer(Offset globalPosition) {
    if (_dragIndex == null) return;
    final localY = _columnLocalY(globalPosition);
    if (localY == null) return;
    final chars = widget.line.chars;
    final int to;
    if (_geoAligned) {
      to = _verticalDropIndexFromLocalY(
        widget.line,
        widget.displayHeight,
        localY,
        _dragIndex,
      );
    } else {
      to = (localY / widget.fontPx).floor().clamp(0, chars.length - 1);
    }
    setState(() {
      _dropIndex = to;
      if (_geoAligned) {
        _dragLocalY = localY.clamp(0.0, widget.displayHeight).toDouble();
      }
    });
  }

  void _cancelDrag() => setState(() {
    _dragIndex = null;
    _dropIndex = null;
    _dragLocalY = null;
  });

  @override
  Widget build(BuildContext context) {
    final chars = widget.line.chars;
    if (chars.isEmpty) {
      return Text('无字符', style: TextStyle(fontSize: 11, color: Colors.grey));
    }
    final display = _displayChars;
    final medianH = lineMedianCharHeight(chars);
    final draggingChar = _dragIndex != null ? chars[_dragIndex!] : null;
    final geo = _geoAligned;
    final fill = _verticalAlignFill(widget.fontPx);

    // 单个字 chip（含手势）：两种布局共用。
    Widget tile(int i) {
      final c = display[i];
      double fontSize = widget.fontPx;
      double? cellHeight;
      if (geo) {
        // 字号全列统一（标准字号），极小字框的 chip 由最小高度下限
        // （_verticalCharCell 内 0.55×标准）保证可读可点。
        final chipH = _verticalCharCell(
          c,
          widget.line,
          widget.displayHeight,
          widget.stdCell,
        ).$2;
        fontSize = widget.stdCell * 0.8 * fill;
        cellHeight = chipH;
      }
      return Builder(
        builder: (itemContext) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            widget.onCharSelected(display[i]);
            Rect anchor = Rect.zero;
            final ro = itemContext.findRenderObject();
            if (ro is RenderBox && ro.hasSize) {
              anchor = ro.localToGlobal(Offset.zero) & ro.size;
            }
            widget.onEditChar(display[i], anchor);
          },
          // 直接按住上下拖动即可改序：垂直拖拽由内层识别器在手势竞技
          // 中胜出（不会滚动页面）；轻点不动仍是打开编辑弹窗。
          onVerticalDragStart: (d) {
            final j = chars.indexOf(display[i]);
            if (j < 0) return;
            _beginDrag(j, d.globalPosition);
          },
          onVerticalDragUpdate: (d) => _updateDragFromPointer(d.globalPosition),
          onVerticalDragEnd: (_) {
            final from = _dragIndex;
            final to = _dropIndex;
            _cancelDrag();
            if (from != null && to != null && from != to) {
              widget.onReorder(from, to);
            }
          },
          onVerticalDragCancel: _cancelDrag,
          // 按住不动约半秒后再拖同样进入改序（鼠标慢速拖拽的兜底路径）
          onLongPressStart: (d) {
            final j = chars.indexOf(display[i]);
            if (j < 0) return;
            _beginDrag(j, d.globalPosition);
          },
          onLongPressMoveUpdate: (d) =>
              _updateDragFromPointer(d.globalPosition),
          onLongPressEnd: (_) {
            final from = _dragIndex;
            final to = _dropIndex;
            _cancelDrag();
            if (from != null && to != null && from != to) {
              widget.onReorder(from, to);
            }
          },
          onLongPressCancel: _cancelDrag,
          child: _LocateFlash(
            active: display[i].id == widget.flashCharId,
            child: _CharChip(
              char: display[i],
              selected: widget.selected?.id == display[i].id,
              dragging:
                  draggingChar != null && display[i].id == draggingChar.id,
              fontSize: fontSize,
              cellHeight: cellHeight,
              color: charRainbowColor(display[i].order),
              isTall: isTallCharBox(display[i], medianH),
              fullDiff: display[i].fullDiff == true,
            ),
          ),
        ),
      );
    }

    if (geo) {
      // 几何对齐列：与列1行图同高，每字 chip 与图中字框同位（中心对齐）。
      return SizedBox(
        key: _columnKey,
        width: widget.columnWidth,
        height: widget.displayHeight,
        child: Stack(
          children: [
            for (var i = 0; i < display.length; i++)
              _positionGeo(display[i], tile(i)),
            // 全文对照多出的无框字符（标点等）：按标准字单元接在最后
            // 一个字之后（越出列高的部分不画）。
            ..._extraChipsGeo(display),
            // 拖拽插入位置指示线：几何锁定下 chip 不随拖动移动，
            // 用横线跟随指针显示落点。
            if (_dragIndex != null && _dragLocalY != null)
              Positioned(
                left: 0,
                width: widget.columnWidth,
                top: _dragLocalY!.clamp(
                  0.0,
                  max(0.0, widget.displayHeight - 2),
                ),
                height: 2,
                child: Container(color: Colors.orange.shade700),
              ),
          ],
        ),
      );
    }
    return Container(
      key: _columnKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (var i = 0; i < display.length; i++) tile(i),
          // 全文对照多出的无框字符（标点等）：接在字片序列尾部展示。
          for (final extra in widget.line.fullExtras)
            _FullExtraChip(ch: extra, fontSize: widget.fontPx),
        ],
      ),
    );
  }

  /// 几何对齐布局下的全文对照无框字符：接在最后一个字之后、按标准
  /// 字单元高顺序排（越出列高的不画——列高即行图高，溢出会糊到邻行）。
  List<Widget> _extraChipsGeo(List<CharBlock> display) {
    final extras = widget.line.fullExtras;
    if (extras.isEmpty || display.isEmpty) return const [];
    final (lastTop, lastH) = _verticalCharCell(
      display.last,
      widget.line,
      widget.displayHeight,
      widget.stdCell,
    );
    final step = widget.stdCell > 0 ? widget.stdCell : lastH;
    if (step <= 0) return const [];
    final out = <Widget>[];
    for (var k = 0; k < extras.length; k++) {
      final top = lastTop + lastH + k * step;
      if (top + step > widget.displayHeight) break;
      out.add(
        Positioned(
          top: top,
          left: 0,
          width: widget.columnWidth,
          height: step,
          child: _FullExtraChip(ch: extras[k], fontSize: widget.fontPx),
        ),
      );
    }
    return out;
  }

  /// 几何对齐模式的 chip 定位：与行图字框中心同位（_verticalCharCell
  /// 已保证高度下限），仅保留 18px 绝对最小高度兜底退化数据。
  /// 几何对齐模式的 chip 定位：与行图字框中心同位（_verticalCharCell
  /// 已保证高度下限），仅保留 18px 绝对最小高度兜底退化数据。
  Widget _positionGeo(CharBlock c, Widget child) {
    final (top, cellH) = _verticalCharCell(
      c,
      widget.line,
      widget.displayHeight,
      widget.stdCell,
    );
    var chipH = cellH;
    var chipTop = top;
    if (chipH < 18) {
      chipH = 18;
      chipTop = (top + cellH / 2 - chipH / 2)
          .clamp(0.0, max(0.0, widget.displayHeight - chipH))
          .toDouble();
    }
    return Positioned(
      top: chipTop,
      left: 0,
      width: widget.columnWidth,
      height: chipH,
      child: child,
    );
  }
}

// ─── 字符 Chip 横行（横排行卡片条2）：轻点编辑，左右拖拽改变字序 ──────────────

class _CharChipRow extends StatefulWidget {
  final LineBlock line;
  final double fontPx;

  /// 横排几何对齐模式：行宽与条1行图一致（每字按字框真实 x 定位）。
  /// 0 表示禁用，用普通横向堆叠布局（行框退化时）。
  final double displayWidth;

  /// 几何对齐模式下的标准字单元宽（全部字框宽度的中位数）。
  final double stdCell;

  /// 几何对齐模式下的统一行高。
  final double rowHeight;

  final CharBlock? selected;
  final ValueChanged<CharBlock?> onCharSelected;

  /// 「定位」后呼吸闪烁的字块 id。
  final String? flashCharId;

  /// 轻点字 chip：anchor 为该 chip 的全局矩形，供快捷候选条定位。
  final void Function(CharBlock c, Rect anchor) onEditChar;
  final void Function(int oldIndex, int newIndex) onReorder;

  const _CharChipRow({
    required this.line,
    required this.fontPx,
    this.displayWidth = 0,
    this.stdCell = 0,
    this.rowHeight = 0,
    required this.selected,
    required this.flashCharId,
    required this.onCharSelected,
    required this.onEditChar,
    required this.onReorder,
  });

  @override
  State<_CharChipRow> createState() => _CharChipRowState();
}

class _CharChipRowState extends State<_CharChipRow> {
  final GlobalKey _rowKey = GlobalKey();
  int? _dragIndex;
  int? _dropIndex;

  /// 拖拽指针在本行内的 X 坐标（几何锁定布局下 chip 不随拖动移动，
  /// 用它画插入位置指示线）。
  double? _dragLocalX;

  /// 横排几何对齐模式：chips 与条1行图同宽、每字按字框真实 x 定位。
  bool get _geoAligned =>
      widget.line.orientation == 'horizontal' &&
      widget.line.w > 0 &&
      widget.displayWidth > 0;

  /// 拖拽中的预览序列：被拖字块已移动到落点槽位（吸附式预览）。
  List<CharBlock> get _displayChars {
    final chars = widget.line.chars;
    final drag = _dragIndex;
    final drop = _dropIndex;
    if (drag == null || drop == null || drag == drop) return chars;
    final list = chars.toList();
    final c = list.removeAt(drag);
    list.insert(drop.clamp(0, list.length), c);
    return list;
  }

  double? _rowLocalX(Offset globalPosition) {
    final box = _rowKey.currentContext?.findRenderObject();
    if (box is! RenderBox) return null;
    return box.globalToLocal(globalPosition).dx;
  }

  void _beginDrag(int charIndex, Offset globalPosition) {
    PythonService.addAppLog('[拖拽] 横排字卡改序开始 idx=$charIndex');
    setState(() {
      _dragIndex = charIndex;
      _dropIndex = charIndex;
      final localX = _rowLocalX(globalPosition);
      _dragLocalX = _geoAligned && localX != null
          ? localX.clamp(0.0, widget.displayWidth).toDouble()
          : null;
    });
  }

  void _updateDragFromPointer(Offset globalPosition) {
    if (_dragIndex == null) return;
    final localX = _rowLocalX(globalPosition);
    if (localX == null) return;
    final chars = widget.line.chars;
    final int to;
    if (_geoAligned) {
      to = _horizontalDropIndexFromLocalX(
        widget.line,
        widget.displayWidth,
        localX,
        _dragIndex,
      );
    } else {
      to = (localX / max(28.0, widget.fontPx)).floor().clamp(
        0,
        chars.length - 1,
      );
    }
    setState(() {
      _dropIndex = to;
      if (_geoAligned) {
        _dragLocalX = localX.clamp(0.0, widget.displayWidth).toDouble();
      }
    });
  }

  void _cancelDrag() => setState(() {
    _dragIndex = null;
    _dropIndex = null;
    _dragLocalX = null;
  });

  void _commitDrag() {
    final from = _dragIndex;
    final to = _dropIndex;
    _cancelDrag();
    PythonService.addAppLog(
      '[拖拽]  from=$from to=$to'
      '${from != null && to != null && from != to ? '' : '（无位移，不提交）'}',
    );
    if (from != null && to != null && from != to) {
      widget.onReorder(from, to);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chars = widget.line.chars;
    if (chars.isEmpty) {
      return Text('无字符', style: TextStyle(fontSize: 11, color: Colors.grey));
    }
    final display = _displayChars;
    final medianH = lineMedianCharHeight(chars);
    final draggingChar = _dragIndex != null ? chars[_dragIndex!] : null;
    final geo = _geoAligned;
    final fill = _verticalAlignFill(widget.fontPx);

    // 单个字 chip（含手势）：两种布局共用。
    Widget tile(int i) {
      double fontSize = widget.fontPx;
      double? cellHeight;
      if (geo) {
        // 字号全行统一（标准字号），极小字框的 chip 由最小宽度下限
        // （_horizontalCharCell 内 0.55×标准）保证可读可点。
        fontSize = widget.stdCell * 0.8 * fill;
        cellHeight = widget.rowHeight;
      }
      return Builder(
        builder: (itemContext) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            widget.onCharSelected(display[i]);
            Rect anchor = Rect.zero;
            final ro = itemContext.findRenderObject();
            if (ro is RenderBox && ro.hasSize) {
              anchor = ro.localToGlobal(Offset.zero) & ro.size;
            }
            widget.onEditChar(display[i], anchor);
          },
          // 按住任意方向拖动即可改序：用 Pan（任意方向）而不是仅水平
          // ——水平拖拽在斜向移动时会被外层列表的垂直滚动先超阈值抢走
          // 手势（列表滚一下、改序没启动），Pan 与竖排列一样靠内层优先
          // 稳赢；轻点不动仍是打开编辑弹窗，桌面列表滚动走滚轮不受影响。
          onPanStart: (d) {
            final j = chars.indexOf(display[i]);
            if (j < 0) return;
            _beginDrag(j, d.globalPosition);
          },
          onPanUpdate: (d) => _updateDragFromPointer(d.globalPosition),
          onPanEnd: (_) => _commitDrag(),
          onPanCancel: _cancelDrag,
          // 按住不动约半秒后再拖同样进入改序（鼠标慢速拖拽的兜底路径）
          onLongPressStart: (d) {
            final j = chars.indexOf(display[i]);
            if (j < 0) return;
            _beginDrag(j, d.globalPosition);
          },
          onLongPressMoveUpdate: (d) =>
              _updateDragFromPointer(d.globalPosition),
          onLongPressEnd: (_) => _commitDrag(),
          onLongPressCancel: _cancelDrag,
          child: _LocateFlash(
            active: display[i].id == widget.flashCharId,
            child: _CharChip(
              char: display[i],
              selected: widget.selected?.id == display[i].id,
              dragging:
                  draggingChar != null && display[i].id == draggingChar.id,
              fontSize: fontSize,
              cellHeight: cellHeight,
              color: charRainbowColor(display[i].order),
              isTall: isTallCharBox(display[i], medianH),
              fullDiff: display[i].fullDiff == true,
            ),
          ),
        ),
      );
    }

    if (geo) {
      // 几何对齐行：与条1行图同宽。槽位 = 字框几何单元按 x 排序的序列，
      // 第 i 个字落在第 i 个槽——未改序时与行图逐字对位；拖拽改序（含
      // 预览）后字卡立即按新顺序落座（此前按各自字框几何定位，改序后
      // 视觉纹丝不动，与条3 字轨的预览相互矛盾）。
      final slots = <(double, double)>[
        for (final c in chars)
          _horizontalCharCell(
            c,
            widget.line,
            widget.displayWidth,
            widget.stdCell,
          ),
      ]..sort((a, b) => a.$1.compareTo(b.$1));
      // 有效槽位：先做 18px 最小宽度兜底（退化数据），再强制相邻槽位
      // 至少留 2px 间隙——字框几何本身重叠时（历史标注/异常切分），按
      // 几何直接定位会两卡互压只露一条边，后面的槽顺次右推并收进显示
      // 宽度内。
      final effSlots = <(double, double)>[];
      for (final (left, cellW) in slots) {
        var chipW = cellW;
        var chipLeft = left;
        if (chipW < 18) {
          chipW = 18;
          chipLeft = (left + cellW / 2 - chipW / 2)
              .clamp(0.0, max(0.0, widget.displayWidth - chipW))
              .toDouble();
        }
        if (effSlots.isNotEmpty) {
          final minLeft = effSlots.last.$1 + effSlots.last.$2 + 2;
          if (chipLeft < minLeft) {
            chipLeft = minLeft
                .clamp(0.0, max(0.0, widget.displayWidth - chipW))
                .toDouble();
          }
        }
        effSlots.add((chipLeft, chipW));
      }
      Widget positionBySlot(int i, Widget child) {
        final (chipLeft, chipW) = effSlots[i.clamp(0, effSlots.length - 1)];
        return Positioned(
          top: 0,
          left: chipLeft,
          width: chipW,
          height: widget.rowHeight,
          child: Center(child: child),
        );
      }

      // 全文对照多出的无框字符（标点等）：按标准槽宽接在最后一个字
      // 之后（越出行宽的不画）。
      final extras = widget.line.fullExtras;
      final extraWidgets = <Widget>[];
      if (extras.isNotEmpty && effSlots.isNotEmpty) {
        var left = effSlots.last.$1 + effSlots.last.$2 + 2;
        for (final extra in extras) {
          if (left + effSlots.last.$2 > widget.displayWidth) break;
          extraWidgets.add(
            Positioned(
              top: 0,
              left: left,
              width: effSlots.last.$2,
              height: widget.rowHeight,
              child: Center(
                child: _FullExtraChip(ch: extra, fontSize: widget.fontPx),
              ),
            ),
          );
          left += effSlots.last.$2 + 2;
        }
      }
      return SizedBox(
        key: _rowKey,
        width: widget.displayWidth,
        height: widget.rowHeight,
        child: Stack(
          children: [
            for (var i = 0; i < display.length; i++) positionBySlot(i, tile(i)),
            ...extraWidgets,
            // 拖拽插入位置指示线：几何锁定下 chip 不随拖动移动，
            // 用竖线跟随指针显示落点。
            if (_dragIndex != null && _dragLocalX != null)
              Positioned(
                top: 0,
                bottom: 0,
                left: _dragLocalX!.clamp(
                  0.0,
                  max(0.0, widget.displayWidth - 2),
                ),
                width: 2,
                child: Container(color: Colors.orange.shade700),
              ),
          ],
        ),
      );
    }
    return Container(
      key: _rowKey,
      child: Wrap(
        spacing: 2,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (var i = 0; i < display.length; i++) tile(i),
          for (final extra in widget.line.fullExtras)
            _FullExtraChip(ch: extra, fontSize: widget.fontPx),
        ],
      ),
    );
  }

  /// 几何对齐模式的 chip 定位：与行图字框中心同位（_horizontalCharCell
  /// 已保证宽度下限），仅保留 18px 绝对最小宽度兜底退化数据。
}

// ─── 字符 Chip ───────────────────────────────────────────────────────────────

/// 两路识别合作状态的显示名（详见 CharBlock.agree 注释）。
String _charAgreeLabel(String agree) {
  switch (agree) {
    case 'both':
      return '两路一致';
    case 'conflict':
      return '两路分歧';
    case 'seq':
      return '仅整行读出';
    case 'box':
      return '仅单字读出';
    case 'box_multi':
      return '单字读出多字';
    case 'none':
      return '两路皆空';
    default:
      return agree;
  }
}

/// 全文对照标记色（默认识别流程附加路）：fullDiff=与整行全文直读
/// 不一致的字（深橙）；fullExtras=全文多出的无框字符（通常是标点，
/// 紫）。与墨迹校验红/琥珀、行内彩虹色互相区分。
const Color kFullDiffColor = Color(0xFFE65100);
const Color kFullExtraColor = Color(0xFF8E24AA);

/// 全文对照多出的无框字符 chip（识别栏展示，无字框、无手势）：紫字 +
/// 淡紫底 + 紫描边虚线感（短划边框用 dotted 模拟）。
class _FullExtraChip extends StatelessWidget {
  final String ch;
  final double fontSize;
  const _FullExtraChip({required this.ch, required this.fontSize});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: fontSize,
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: kFullExtraColor.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: kFullExtraColor.withValues(alpha: 0.55),
            width: 1,
            strokeAlign: BorderSide.strokeAlignInside,
          ),
        ),
        child: Text(
          ch,
          style: TextStyle(
            fontSize: fontSize * 0.82,
            height: 1.0,
            color: kFullExtraColor,
          ),
        ),
      ),
    );
  }
}

class _CharChip extends StatelessWidget {
  final CharBlock char;
  final bool selected;
  final bool dragging;
  final double fontSize;

  /// 几何对齐模式的固定单元高（字号独立计算，可能超出单元由 FittedBox
  /// 缩回）；null 时沿用"单元高=字号"的旧等高堆叠布局。
  final double? cellHeight;

  /// 行内彩虹色：与字框、整行文字同色对应；null 时回退状态色。
  final Color? color;

  /// 行内异常高字框（与画布 kTallBoxRed 同口径）：边框用醒目红提示
  /// 复查（字+标点同框/两字粘连等）。
  final bool isTall;

  /// 全文对照：与整行全文直读的对位字符不一致（kFullDiffColor 标记）。
  final bool fullDiff;

  const _CharChip({
    required this.char,
    this.selected = false,
    this.dragging = false,
    this.fontSize = 40,
    this.cellHeight,
    this.color,
    this.isTall = false,
    this.fullDiff = false,
  });

  @override
  Widget build(BuildContext context) {
    final isEmpty = char.text.isEmpty;
    final isConfirmed = char.confirmed;
    // 墨迹校验标记优先于行内彩虹装饰色：mismatch 文字标红、suspect
    // 文字琥珀（与画布虚线框同口径），人工复核优先看这些字。
    final verifyColor = verifyFlagColor(char);
    final baseBgColor = isEmpty
        ? Colors.red.shade50
        : isConfirmed
        ? Colors.green.shade50
        : Colors.blue.shade50;
    final baseBorderColor = isEmpty
        ? Colors.red.shade200
        : isConfirmed
        ? Colors.green.shade200
        : Colors.blue.shade200;
    final fullDiffColor = fullDiff && verifyColor == null
        ? kFullDiffColor
        : null;
    final borderColor = isTall && !selected
        ? kTallBoxRed
        : selected
        ? Colors.orange.shade700
        : verifyColor ?? fullDiffColor ?? baseBorderColor;
    final textColor =
        verifyColor ??
        fullDiffColor ??
        color ??
        (isEmpty
            ? Colors.red
            : isConfirmed
            ? Colors.green.shade800
            : Colors.blue.shade800);
    final cell = cellHeight;

    // 固定行高单元格：与第三列整行文字严格逐行对齐；
    // 选中加粗边框只影响绘制，不改变行高。
    return SizedBox(
      height: cell ?? fontSize,
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? Colors.orange.withValues(alpha: 0.28) : baseBgColor,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: borderColor,
            width: selected || isTall || verifyColor != null ? 2 : 1,
          ),
          boxShadow: dragging
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            if (cell == null)
              Text(
                isEmpty ? '?' : char.text,
                strutStyle: StrutStyle(
                  fontSize: fontSize,
                  height: 1,
                  leading: 0,
                ),
                style: TextStyle(
                  fontSize: fontSize,
                  color: textColor,
                  height: 1,
                  leadingDistribution: TextLeadingDistribution.even,
                ),
              )
            else
              FittedBox(
                // 几何对齐单元：字号按单元高度计算，scaleDown 兜底防溢出。
                fit: BoxFit.scaleDown,
                child: Text(
                  isEmpty ? '?' : char.text,
                  style: TextStyle(fontSize: fontSize, color: textColor),
                ),
              ),
            // 特殊字标记（墨迹归类打的"裁分存疑/暂无法识别"）：
            // 左上角深橙小旗点，与右上角 amber 分歧点区分。
            if (char.marked)
              Positioned(
                top: 1,
                left: 2,
                child: Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.deepOrange.shade400,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            // 两路分歧标记：整行序列与单字框内读法不一致（另一路读法在
            // 候选里），人工校对时优先看这些位置。
            if (char.agree == 'conflict')
              Positioned(
                top: 1,
                right: 2,
                child: Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.amber.shade700,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _BlockPanel extends StatelessWidget {
  final CharBlock block;
  final VoidCallback onDelete;
  final ValueChanged<String> onTypeChange;
  final VoidCallback onClearAll;
  final Widget progress;

  /// 该字框正在快速识别（画新框/调整框后）：OCR 内容区显示进行中状态。
  final bool recognizing;

  /// 打开「墨迹对照」对话框（识别字字形骨架 vs 墨迹骨架叠加图+拓扑
  /// 差异+重新校验）；null（非正文/空字块）时按钮隐藏。
  final VoidCallback? onShowVerify;

  /// 特殊字标记开关（墨迹归类打的"裁分存疑/暂无法识别"标记）；
  /// null（非字块视图）时整行隐藏。
  final ValueChanged<bool>? onMarkToggle;

  const _BlockPanel({
    required this.block,
    required this.onDelete,
    required this.onTypeChange,
    required this.onClearAll,
    required this.progress,
    this.recognizing = false,
    this.onShowVerify,
    this.onMarkToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey.shade50,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            block.id,
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          if (block.source.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              block.source,
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              const Text(
                'OCR 内容',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              if (recognizing) ...[
                const SizedBox(width: 6),
                const SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                ),
                const SizedBox(width: 3),
                Text(
                  '识别中…',
                  style: TextStyle(fontSize: 11, color: Colors.blue.shade700),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: Colors.grey.shade300),
              borderRadius: BorderRadius.circular(6),
            ),
            child: SelectableText(
              block.text.isEmpty ? '无识别文本' : block.text,
              style: TextStyle(
                fontSize: 13,
                color: block.text.isEmpty ? Colors.grey : Colors.black87,
              ),
            ),
          ),
          const SizedBox(height: 12),
          _row('X', '${block.x}'),
          _row('Y', '${block.y}'),
          _row('W', '${block.w}'),
          _row('H', '${block.h}'),
          _row('Col', '${block.col}'),
          _row('Order', '${block.order}'),
          if (block.agree != null && block.agree!.isNotEmpty)
            _row('两路', _charAgreeLabel(block.agree!)),
          if (block.conf != null)
            _row('置信', '${(block.conf! * 100).toStringAsFixed(0)}%'),
          if (block.verifyLevel != null && block.verifyLevel!.isNotEmpty)
            () {
              // 墨迹重叠校验结果：mismatch 红/suspect 琥珀与画布、行
              // 卡片同口径，人眼看属性面板时能对上标记来源。
              final color = verifyFlagColor(block);
              final label = switch (block.verifyLevel) {
                'ok' => '通过',
                'suspect' => '存疑',
                'mismatch' => '不匹配',
                _ => '未校验',
              };
              final score = block.verifyScore;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 40,
                      child: Text(
                        '校验',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ),
                    Icon(
                      block.verifyLevel == 'mismatch'
                          ? Icons.error_outline
                          : block.verifyLevel == 'suspect'
                          ? Icons.help_outline
                          : Icons.check_circle_outline,
                      size: 13,
                      color: color ?? Colors.green.shade700,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      score == null
                          ? label
                          : '$label（${(score * 100).toStringAsFixed(0)}分）',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: color ?? Colors.green.shade700,
                      ),
                    ),
                  ],
                ),
              );
            }(),
          const SizedBox(height: 8),
          if (onMarkToggle != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Icon(
                    block.marked ? Icons.flag : Icons.flag_outlined,
                    size: 14,
                    color: block.marked
                        ? Colors.deepOrange.shade700
                        : Colors.grey.shade600,
                  ),
                  const SizedBox(width: 4),
                  const Expanded(
                    child: Text(
                      '特殊字标记（裁分存疑/暂无法识别）',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  Switch(value: block.marked, onChanged: onMarkToggle),
                ],
              ),
            ),
          if (onShowVerify != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: OutlinedButton.icon(
                onPressed: onShowVerify,
                icon: const Icon(Icons.compare, size: 16),
                label: const Text('墨迹对照', style: TextStyle(fontSize: 12)),
              ),
            ),
          progress,
          const SizedBox(height: 12),
          const Text('类型', style: TextStyle(fontSize: 12)),
          DropdownButton<String>(
            value: block.type,
            isExpanded: true,
            items: const [
              DropdownMenuItem(value: 'main_text', child: Text('正文')),
              DropdownMenuItem(value: 'annotation', child: Text('小注')),
              DropdownMenuItem(value: 'ignore', child: Text('忽略')),
            ],
            onChanged: (v) {
              if (v != null) onTypeChange(v);
            },
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: onDelete,
            style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除 (Del)'),
          ),
          const SizedBox(height: 6),
          OutlinedButton.icon(
            onPressed: onClearAll,
            icon: const Icon(Icons.clear_all),
            label: const Text('清除本页全部单字框'),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        SizedBox(
          width: 40,
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
        Text(value, style: const TextStyle(fontSize: 12)),
      ],
    ),
  );
}

/// 本页识别方向设置对话框：排版方向 + 横排/竖排阅读方向，每项都可
/// 「跟随整书」或按页单独指定。保存后由调用方重新识别本页。
///
/// 横排方向在横排下是文字阅读顺序（从左到右/从右到左）；竖排下是列的
/// 阅读顺序（传统古籍从右到左）。竖排方向是列内文字顺序（从上到下/
/// 从下到上），与整书设置界面（task_setup_page）同一套字段与文案。
class _PageDirectionDialog extends StatefulWidget {
  const _PageDirectionDialog({required this.bookSettings, this.current});

  final ProjectSettings bookSettings;
  final PageDirectionOverride? current;

  @override
  State<_PageDirectionDialog> createState() => _PageDirectionDialogState();
}

class _PageDirectionDialogState extends State<_PageDirectionDialog> {
  String? _orientation;
  String? _horizontalDir;
  String? _verticalDir;

  @override
  void initState() {
    super.initState();
    _orientation = widget.current?.orientation;
    _horizontalDir = widget.current?.horizontalDir;
    _verticalDir = widget.current?.verticalDir;
  }

  String get _bookOrientationLabel =>
      widget.bookSettings.orientation == 'horizontal' ? '横排' : '竖排';

  String get _bookHorizontalDirLabel =>
      widget.bookSettings.horizontalDir == 'rtl' ? '从右到左' : '从左到右';

  String get _bookVerticalDirLabel =>
      widget.bookSettings.verticalDir == 'btt' ? '从下到上' : '从上到下';

  bool get _changed =>
      _orientation != widget.current?.orientation ||
      _horizontalDir != widget.current?.horizontalDir ||
      _verticalDir != widget.current?.verticalDir;

  Widget _sectionHeader(String text) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 4),
    child: Text(
      text,
      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
    ),
  );

  Widget _optionRow({
    required bool selected,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_off,
        color: selected ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text(title),
      subtitle: subtitle == null
          ? null
          : Text(subtitle, style: const TextStyle(fontSize: 12)),
      dense: true,
      onTap: onTap,
    );
  }

  /// 一组单选行：跟随整书（副标题带整书当前值）+ 两个具体选项。
  /// 不用 RadioListTile——其 groupValue/onChanged 在当前 Flutter 已废弃。
  List<Widget> _options({
    required String? value,
    required List<(String?, String, String?)> choices,
    required ValueChanged<String?> onChanged,
  }) {
    return [
      for (final (v, title, subtitle) in choices)
        _optionRow(
          selected: value == v,
          title: title,
          subtitle: subtitle,
          onTap: () => onChanged(v),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('本页识别方向'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '方向决定行切分、阅读序与读法，保存后本页会重新识别，'
                '现有标注被替换。',
                style: TextStyle(fontSize: 12.5, color: Colors.grey),
              ),
              _sectionHeader('排版方向'),
              ..._options(
                value: _orientation,
                choices: [
                  (null, '跟随整书', '整书为 $_bookOrientationLabel；清除本页单独设置'),
                  ('horizontal', '横排识别', '按水平行切分与读法（现代排印常见）'),
                  ('vertical', '竖排识别', '按竖列切分与读法（古籍常见）'),
                ],
                onChanged: (v) => setState(() => _orientation = v),
              ),
              _sectionHeader('横排方向（横排时为文字阅读顺序）'),
              ..._options(
                value: _horizontalDir,
                choices: [
                  (null, '跟随整书', '整书为 $_bookHorizontalDirLabel'),
                  ('ltr', '从左到右', null),
                  ('rtl', '从右到左', null),
                ],
                onChanged: (v) => setState(() => _horizontalDir = v),
              ),
              _sectionHeader('竖排方向（竖排时为列内文字顺序）'),
              ..._options(
                value: _verticalDir,
                choices: [
                  (null, '跟随整书', '整书为 $_bookVerticalDirLabel'),
                  ('ttb', '从上到下', null),
                  ('btt', '从下到上', null),
                ],
                onChanged: (v) => setState(() => _verticalDir = v),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _changed
              ? () => Navigator.pop(
                  context,
                  PageDirectionOverride(
                    orientation: _orientation,
                    horizontalDir: _horizontalDir,
                    verticalDir: _verticalDir,
                  ),
                )
              : null,
          child: const Text('保存并重新识别'),
        ),
      ],
    );
  }
}

/// VL 全量设置（构造器开关 + predict 参数）是否有变化（对话框"保存"
/// 按钮的判据）：比较 vlConfig/vlPredict 两个请求体视图的 JSON。
bool _vlSettingsChanged(ProjectSettings a, ProjectSettings b) =>
    jsonEncode(a.vlConfig) != jsonEncode(b.vlConfig) ||
    jsonEncode(a.vlPredict) != jsonEncode(b.vlPredict);

/// 识别引擎设置对话框（书级）：复用 EngineSettingsSection（与任务创建
/// 页同一套选项与文案），确认后由调用方写 project.settings 并落盘。
class _EngineSettingsDialog extends StatefulWidget {
  const _EngineSettingsDialog({
    required this.engine,
    required this.paddleModel,
    this.vlSettings,
  });

  final String engine;
  final String paddleModel;

  /// VL 设置初始值（书级，承载全部构造器开关与 predict 参数）；
  /// null = 不展示 VL 配置面板（任务创建页）。
  final ProjectSettings? vlSettings;

  @override
  State<_EngineSettingsDialog> createState() => _EngineSettingsDialogState();
}

class _EngineSettingsDialogState extends State<_EngineSettingsDialog> {
  late String _engine;
  late String _paddleModel;
  ProjectSettings? _vlSettings;

  @override
  void initState() {
    super.initState();
    _engine = widget.engine;
    _paddleModel = widget.paddleModel;
    _vlSettings = widget.vlSettings?.copyWith();
  }

  bool get _changed =>
      _engine != widget.engine ||
      _paddleModel != widget.paddleModel ||
      (_vlSettings != null &&
          _vlSettingsChanged(widget.vlSettings!, _vlSettings!));

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('识别引擎（本书）'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '引擎决定"读字"的实现（版面/行/字框始终由自训模型给出）。'
                '保存后本书后续识别（本页/本行/整本）使用新引擎；已确认的'
                '标注不受影响。',
                style: TextStyle(fontSize: 12.5, color: Colors.grey),
              ),
              EngineSettingsSection(
                engine: _engine,
                paddleModel: _paddleModel,
                onEngineChanged: (v) => setState(() => _engine = v),
                onPaddleModelChanged: (v) => setState(() => _paddleModel = v),
                vlSettings: _vlSettings,
                onVlSettingsChanged: _vlSettings == null
                    ? null
                    : (s) => setState(() => _vlSettings = s),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _changed
              ? () => Navigator.pop(
                  context,
                  (
                    _engine,
                    _paddleModel,
                    // VL 面板未动时沿用原设置对象（copyWith 已复制）。
                    _vlSettings ?? (widget.vlSettings!.copyWith()),
                  ),
                )
              : null,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
