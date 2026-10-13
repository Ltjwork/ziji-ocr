import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../services/book_cache.dart';
import '../services/python_service.dart';
import '../services/storage.dart';
import '../widgets/band_select_surface.dart';
import 'editor_page.dart' show charPinyin;
import 'line_reseg_page.dart';

/// 全书版退栈返回给编辑器的结果：被修改的页集合 + 可选的「定位」
/// 请求（字格/单字对话框的「定位到所在页」——编辑器跳到该页并在
/// 详细视图选中闪烁该字）。
class BookClassifyResult {
  final Set<int> modifiedPages;
  final int? locatePage;
  final String? locateBlockId;

  const BookClassifyResult({
    required this.modifiedPages,
    this.locatePage,
    this.locateBlockId,
  });
}

/// 墨迹归类·全书版（全屏）：把指定页范围（或整本书）的正文字块按
/// 墨迹形态跨页聚类，逐组展示字图缩略图，支持点选/框选组内文字后
/// 统一改字、单字单独改字，以及「确认所选」——只把选中的非空文字
/// 置为已确认并立即落盘，效果与编辑器「确认并保存」一致（组内文字
/// 转绿；某页所有字都被确认过时整页升级为绿框、计入校对进度与训练
/// 数据）。已确认的字默认从组里隐藏，工具栏「显示已确认」开关回显。
///
/// 与单页版的差别：
/// - 后端 /char_clusters_batch 逐页提特征后跨页合并（块 id 由本页加
///   「页号|」前缀保证全局唯一）；
/// - 字图缩略图按需经 /char_thumbnails 拉取（不整页解码大图，大书不
///   会撑爆内存），按组滚动到可见时批量加载；
/// - 标注按页持有并直接落盘（返回编辑器时刷新受影响页）；
/// - 字格带「定位到所在页」（回到编辑器跳页选中闪烁该字）。
class SimilarCharsBookPage extends StatefulWidget {
  final Project project;
  final int currentPageIndex;

  const SimilarCharsBookPage({
    super.key,
    required this.project,
    required this.currentPageIndex,
  });

  @override
  State<SimilarCharsBookPage> createState() => _SimilarCharsBookPageState();
}

/// 组成员引用：页号 + 该页标注里的活字块（文本/状态直接读写，改动
/// 随组确认或防抖保存落盘）。
class _MemberRef {
  final int page;
  final CharBlock block;
  const _MemberRef(this.page, this.block);
}

class _BookGroup {
  /// 稳定 id（聚类结果内递增）：卡片 key 用它，组成员被确认隐藏后
  /// State 不重建（选区、输入框、展开态保留）。
  final String id;
  final List<_MemberRef> members;
  final double cohesion;
  _BookGroup(this.id, this.members, this.cohesion);
}

class _SimilarCharsBookPageState extends State<SimilarCharsBookPage> {
  final TextEditingController _startCtrl = TextEditingController();
  final TextEditingController _endCtrl = TextEditingController();

  double _threshold = 0.15;
  bool _onlyPending = true;

  /// 已确认的字默认从组里隐藏；开关打开时回显（绿色态）。
  bool _showConfirmed = false;

  /// 特殊字标记筛选：隐藏标记（正常归类不受存疑字干扰）与只看标记
  /// （全书识别完成后的标记字集中校对）互斥，同开等于什么都没有。
  bool _hideMarked = false;
  bool _onlyMarked = false;

  /// 阶段：设置范围 → 载入标注 → 聚类 → 展示（错误时回到设置可重试）。
  _Stage _stage = _Stage.setup;
  double _loadProgress = 0;
  String? _error;

  int _rangeStart = 0; // 0 基，含
  int _rangeEnd = 0; // 0 基，含
  final Map<int, PageAnnotation> _annotations = {};
  final Map<int, Map<String, CharBlock>> _blocksByPage = {};
  int _noAnnotationCount = 0;

  CharClusterResult? _result;
  List<_BookGroup> _groups = [];
  List<_MemberRef> _singletons = [];

  /// 缩略图缓存：'页号|块id' -> base64 PNG（'' 表示后端裁切失败）。
  final Map<String, String> _thumbs = {};
  final Set<String> _thumbInFlight = {};

  final Set<int> _dirtyPages = {};
  final Set<int> _modifiedPages = {};
  Timer? _saveDebounce;
  bool _confirmingGroup = false;

  int get _pageCount => widget.project.imageFiles.length;

  @override
  void initState() {
    super.initState();
    _startCtrl.text = '1';
    _endCtrl.text = '$_pageCount';
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    // 未确认的文本编辑直接落盘（写盘按文件串行，编辑器返回后重读会
    // 等待在途写完成，无读写竞态）。
    unawaited(_flushDirtyNow());
    _startCtrl.dispose();
    _endCtrl.dispose();
    super.dispose();
  }

  // ── 范围与数据载入 ──

  void _applyQuickRange(int start, int end) {
    setState(() {
      _startCtrl.text = '${start + 1}';
      _endCtrl.text = '${end + 1}';
    });
  }

  (int, int) _parseRange() {
    int? parse(String s) => int.tryParse(s.trim());
    var start = parse(_startCtrl.text) ?? 1;
    var end = parse(_endCtrl.text) ?? _pageCount;
    if (start > end) {
      final t = start;
      start = end;
      end = t;
    }
    start = start.clamp(1, _pageCount);
    end = end.clamp(1, _pageCount);
    return (start - 1, end - 1);
  }

  Future<void> _start() async {
    final (start, end) = _parseRange();
    setState(() {
      _stage = _Stage.loading;
      _loadProgress = 0;
      _error = null;
      _rangeStart = start;
      _rangeEnd = end;
      _annotations.clear();
      _blocksByPage.clear();
      _noAnnotationCount = 0;
    });
    final project = widget.project;
    final total = end - start + 1;
    var loaded = 0;
    for (var i = start; i <= end; i++) {
      final ann = await ProjectStorage.loadAnnotation(
        project.projectDir,
        project.pageIdAt(i),
      );
      if (ann == null) {
        _noAnnotationCount++;
      } else {
        final main = ann.blocks
            .where((b) => b.type == 'main_text')
            .toList(growable: false);
        if (main.isNotEmpty) {
          _annotations[i] = ann;
          _blocksByPage[i] = {for (final b in main) b.id: b};
        }
      }
      loaded++;
      if (!mounted) return;
      if (loaded % 8 == 0 || loaded == total) {
        setState(() => _loadProgress = loaded / total);
      }
    }
    if (_blocksByPage.isEmpty) {
      setState(() {
        _stage = _Stage.setup;
        _error = '范围内没有带正文字块的页'
            '${_noAnnotationCount > 0 ? '（$_noAnnotationCount 页无标注/未识别）' : ''}，'
            '先整本识别或调整页数范围。';
      });
      return;
    }
    await _runCluster();
  }

  /// 重新聚类（阈值变化或手动刷新）：先查书目录聚类缓存（页范围+阈值+
  /// 每页几何摘要命中即免后端分钟级重算），未命中再跑后端并把结果写回
  /// 缓存。文字/确认/标记变化不改变摘要——改字后重开无需重新聚类。
  Future<void> _runCluster() async {
    setState(() {
      _stage = _Stage.clustering;
      _error = null;
    });
    try {
      final digest = await ClusterCache.digestForPages([
        for (final e in _blocksByPage.entries)
          (
            imagePath: widget.project.imageFiles[e.key],
            blocks: e.value.values.toList(),
          ),
      ]);
      final cached = await ClusterCache.lookup(
        widget.project,
        _rangeStart,
        _rangeEnd,
        _threshold,
        digest,
      );
      if (cached != null) {
        final result = cached.toResult();
        if (!mounted) return;
        setState(() {
          _result = result;
          _groups = _parseGroups(result);
          _singletons = _parseSingletons(result);
          _stage = _Stage.done;
        });
        PythonService.addAppLog(
          '[聚类缓存] 命中：${_groups.length} 组 / 未归组 ${_singletons.length}'
          '（范围 ${_rangeStart + 1}–${_rangeEnd + 1} 页，阈值 $_threshold，'
          '字块几何未变，跳过后端重算）',
        );
        return;
      }
      final pages = [
        for (final e in _blocksByPage.entries)
          CharClusterBatchPage(
            imagePath: widget.project.imageFiles[e.key],
            blocks: [
              // 块 id 加页前缀保证跨页唯一（p_b0001 每页都有），
              // 聚类返回后拆回页号+块 id。
              for (final b in e.value.values)
                CharBlock(
                  id: '${e.key}|${b.id}',
                  x: b.x,
                  y: b.y,
                  w: b.w,
                  h: b.h,
                  col: b.col,
                  order: b.order,
                ),
            ],
          ),
      ];
      final result = await PythonService.clusterCharsBatch(
        pages: pages,
        threshold: _threshold,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _groups = _parseGroups(result);
        _singletons = _parseSingletons(result);
        _stage = _Stage.done;
      });
      // 有失败页的结果不缓存（重跑可能补上失败的页）；keys 就是后端
      // 返回的 '页号|块id'，下次打开直接拆回活字块。
      if (result.failedPages.isEmpty) {
        unawaited(
          ClusterCache.store(
            widget.project,
            ClusterCacheEntry(
              rangeStart: _rangeStart,
              rangeEnd: _rangeEnd,
              threshold: _threshold,
              digest: digest,
              clusters: result.clusters,
              singletons: result.singletons,
              skipped: result.skipped,
              savedAt: DateTime.now(),
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.done;
        _error = e.toString().replaceFirst(RegExp('^Exception:\\s*'), '');
        _result = null;
        _groups = [];
        _singletons = [];
      });
    }
  }

  List<_BookGroup> _parseGroups(CharClusterResult result) {
    final groups = <_BookGroup>[];
    var seq = 0;
    for (final c in result.clusters) {
      final members = <_MemberRef>[];
      for (final id in c.blockIds) {
        final ref = _memberFromKey(id);
        if (ref != null) members.add(ref);
      }
      if (members.length >= 2) {
        members.sort((a, b) {
          final byPage = a.page.compareTo(b.page);
          if (byPage != 0) return byPage;
          final byCol = a.block.col.compareTo(b.block.col);
          return byCol != 0 ? byCol : a.block.order.compareTo(b.block.order);
        });
        groups.add(_BookGroup('g${seq++}', members, c.cohesion));
      }
    }
    return groups;
  }

  List<_MemberRef> _parseSingletons(CharClusterResult result) {
    final list = <_MemberRef>[];
    for (final id in result.singletons) {
      final ref = _memberFromKey(id);
      if (ref != null) list.add(ref);
    }
    list.sort((a, b) {
      final byPage = a.page.compareTo(b.page);
      if (byPage != 0) return byPage;
      final byCol = a.block.col.compareTo(b.block.col);
      return byCol != 0 ? byCol : a.block.order.compareTo(b.block.order);
    });
    return list;
  }

  _MemberRef? _memberFromKey(String key) {
    final sep = key.indexOf('|');
    if (sep <= 0) return null;
    final page = int.tryParse(key.substring(0, sep));
    final block = _blocksByPage[page]?[key.substring(sep + 1)];
    if (page == null || block == null) return null;
    return _MemberRef(page, block);
  }

  // ── 编辑与保存 ──

  void _updateBlockText(_MemberRef m, String newText) {
    m.block.text = newText;
    final ann = _annotations[m.page];
    if (ann != null) {
      for (final line in ann.lines) {
        if (line.chars.contains(m.block)) {
          line.text = line.chars.map((c) => c.text).join();
          break;
        }
      }
    }
    _markDirty(m.page);
    setState(() {});
  }

  void _applyText(List<_MemberRef> members, String text) {
    for (final m in members) {
      if (m.block.text != text) {
        _updateBlockText(m, text);
      }
    }
  }

  /// 点缩略图弹单字修改框（组内成员与未归组单字共用）；
  /// 对话框里的「行内重切」按钮进入行内识别区重划分，
  /// 「特殊字标记」开关随文字一起返回。
  Future<void> _editMember(_MemberRef m) async {
    final result = await showDialog<({String text, bool marked})>(
      context: context,
      builder: (_) => _SingleCharDialog(
        block: m.block,
        currentText: m.block.text,
        initialMarked: m.block.marked,
        onLineReseg: () => unawaited(_openLineReseg(m)),
        onLocate: () => _locateMember(m),
      ),
    );
    if (result == null) return;
    if (result.text.trim().isNotEmpty && result.text.trim() != m.block.text) {
      _updateBlockText(m, result.text.trim());
    }
    if (result.marked != m.block.marked) {
      _setMarked([m], result.marked);
    }
  }

  /// 双击字格 / 单字对话框「行内重切」：打开该字所在行的行内重切页。
  /// 应用改动后剪掉分组里被替换/删除的旧字块并刷新该页标注。
  Future<void> _openLineReseg(_MemberRef m) async {
    final ann = _annotations[m.page];
    if (ann == null) return;
    LineBlock? line;
    var lineIndex = -1;
    for (var i = 0; i < ann.lines.length; i++) {
      if (ann.lines[i].chars.contains(m.block)) {
        line = ann.lines[i];
        lineIndex = i;
        break;
      }
    }
    // 实例脱节兜底：分组持有的字块实例可能已被替换（标注重建/其他
    // 路径 copyWith 换代），按块 id 找行——uid 稳定，id 即身份。
    if (line == null) {
      outer:
      for (var i = 0; i < ann.lines.length; i++) {
        for (final c in ann.lines[i].chars) {
          if (c.id == m.block.id) {
            line = ann.lines[i];
            lineIndex = i;
            break outer;
          }
        }
      }
    }
    if (line == null) {
      _snack('找不到该字所在的行（标注可能已变化），请重新归类后再试');
      return;
    }
    final target = line;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => LineResegPage(
          project: widget.project,
          line: target,
          lineIndex: lineIndex,
          pageIndex: m.page,
          pageLines: ann.lines,
        ),
      ),
    );
    if (changed != true) return;
    _afterLineEdited(m.page);
  }

  /// 行内重切应用后的刷新：重建扁平字块与页内索引，把分组/单字里
  /// 已失效（被替换或删除）的成员剪掉；改动过的字确认状态已由重切
  /// 页重置，重新「确认所选」或「重新归类」后恢复分组。
  void _afterLineEdited(int page) {
    final ann = _annotations[page];
    if (ann != null) {
      ann.rebuildBlocks();
      _blocksByPage[page] = {
        for (final b in ann.blocks)
          if (b.type == 'main_text') b.id: b,
      };
    }
    bool live(_MemberRef m) =>
        identical(_blocksByPage[m.page]?[m.block.id], m.block);
    _groups = [
      for (final g in _groups)
        if (g.members.where(live).length >= 2)
          _BookGroup(g.id, g.members.where(live).toList(), g.cohesion),
    ];
    _singletons = _singletons.where(live).toList();
    _markDirty(page);
    setState(() {});
    _snack('行内识别区已更新：改动过的字已重置为待确认；点「重新归类」刷新分组');
  }

  void _markDirty(int page) {
    _dirtyPages.add(page);
    _modifiedPages.add(page);
    _saveDebounce ??= Timer(const Duration(seconds: 2), () {
      _saveDebounce = null;
      unawaited(_flushDirtyNow());
    });
  }

  Future<void> _flushDirtyNow() async {
    final pages = _dirtyPages.toList();
    _dirtyPages.clear();
    for (final idx in pages) {
      final ann = _annotations[idx];
      if (ann == null) continue;
      if (!ann.isFullyConfirmed) ann.draftSaved = true;
      try {
        await ProjectStorage.saveAnnotation(widget.project.projectDir, ann);
      } catch (_) {
        // 单页写失败不阻断其余页；确认按钮路径会再提示。
      }
    }
  }

  /// 确认所选（组卡片传入的选中字）：空文字与已确认的跳过（确认空
  /// 字会污染训练数据），其余置为已确认并立即落盘（每页一次）。
  Future<void> _confirmSelected(Set<String> selectedKeys) async {
    if (_confirmingGroup) return;
    final byPage = <int, Set<String>>{};
    var skipped = 0;
    for (final key in selectedKeys) {
      final m = _memberFromKey(key);
      if (m == null) continue;
      if (m.block.text.trim().isEmpty ||
          m.block.status == AnnotationStatus.confirmed) {
        skipped++;
        continue;
      }
      byPage.putIfAbsent(m.page, () => {}).add(m.block.id);
    }
    if (byPage.isEmpty) {
      _snack('选中的字没有可确认的非空文字');
      return;
    }
    setState(() => _confirmingGroup = true);
    try {
      await _flushDirtyNow(); // 组内此前的文本编辑先落盘，同文件不交错
      var confirmedCount = 0;
      var confirmedPages = 0;
      for (final e in byPage.entries) {
        final ann = _annotations[e.key];
        if (ann == null) continue;
        if (ann.confirmCharsById(e.value)) confirmedPages++;
        confirmedCount += e.value.length;
        _dirtyPages.remove(e.key);
        _modifiedPages.add(e.key);
        await ProjectStorage.saveAnnotation(widget.project.projectDir, ann);
      }
      if (!mounted) return;
      setState(() {});
      final pageNote = confirmedPages > 0
          ? '，涉及 $confirmedPages 页已保存'
          : '，已保存';
      _snack(
        '已确认 $confirmedCount 字$pageNote'
        '${skipped > 0 ? '；$skipped 个空字/已确认未重复处理' : ''}',
      );
    } catch (e) {
      if (mounted) _snack('确认失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _confirmingGroup = false);
    }
  }

  // ── 缩略图按需加载 ──

  static String _thumbKey(_MemberRef m) => '${m.page}|${m.block.id}';

  /// 为一组可见成员批量拉取缺失缩略图（滚动到可见时由卡片触发）。
  Future<void> _ensureThumbs(List<_MemberRef> members) async {
    final missing = <_MemberRef>[];
    for (final m in members) {
      final key = _thumbKey(m);
      if (_thumbs.containsKey(key) || _thumbInFlight.contains(key)) continue;
      missing.add(m);
    }
    if (missing.isEmpty) return;
    for (final m in missing) {
      _thumbInFlight.add(_thumbKey(m));
    }
    try {
      const backendBatchLimit = 2000;
      for (var i = 0; i < missing.length; i += backendBatchLimit) {
        final chunk = missing.skip(i).take(backendBatchLimit).toList();
        final items = chunk
            .map(
              (m) => (
                imagePath: widget.project.imageFiles[m.page],
                x: m.block.x,
                y: m.block.y,
                w: m.block.w,
                h: m.block.h,
              ),
            )
            .toList();
        final thumbs = await PythonService.fetchCharThumbnails(items: items);
        for (var j = 0; j < chunk.length && j < thumbs.length; j++) {
          _thumbs[_thumbKey(chunk[j])] = thumbs[j] ?? '';
        }
      }
      if (mounted) setState(() {});
    } catch (_) {
      // 拉取失败不缓存：下次触发重试；已有缩略图的字块不受影响。
    } finally {
      for (final m in missing) {
        _thumbInFlight.remove(_thumbKey(m));
      }
    }
  }

  // ── 筛选 ──

  bool _memberNeedsAttention(_MemberRef m) =>
      m.block.text.isEmpty || m.block.status != AnnotationStatus.confirmed;

  bool _groupNeedsAttention(_BookGroup g) =>
      g.members.any(_memberNeedsAttention);

  bool _memberConfirmed(_MemberRef m) =>
      m.block.text.isNotEmpty && m.block.status == AnnotationStatus.confirmed;

  /// 已确认的字默认从组里隐藏，「显示已确认」开关打开时回显；
  /// 「隐藏标记/只看标记」对特殊字做反向筛选（两者互斥）。
  bool _memberVisible(_MemberRef m) {
    if (_hideMarked && m.block.marked) return false;
    if (_onlyMarked && !m.block.marked) return false;
    return _showConfirmed || !_memberConfirmed(m);
  }

  /// 特殊字标记/取消标记：直接写活字块并按页防抖落盘（与文本编辑
  /// 同通道），全书记成一处稍后校对的清单。
  void _setMarked(List<_MemberRef> members, bool marked) {
    var changed = 0;
    for (final m in members) {
      if (m.block.marked == marked) continue;
      m.block.marked = marked;
      _markDirty(m.page);
      changed++;
    }
    if (changed > 0) setState(() {});
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 3),
        backgroundColor: error ? Colors.red.shade700 : null,
      ),
    );
  }

  /// 保存未落盘编辑并退栈（返回被修改的页号集合给编辑器刷新）。
  /// 冲刷期间 canPop 尚未翻正，连点返回/完成会重复进入——_popping 挡住。
  bool _popping = false;

  void _flushAndPop() {
    if (_popping) return;
    _popping = true;
    _saveDebounce?.cancel();
    _saveDebounce = null;
    final nav = Navigator.of(context);
    unawaited(
      _flushDirtyNow().then((_) {
        if (mounted) {
          nav.pop(BookClassifyResult(modifiedPages: _modifiedPages));
        }
      }),
    );
  }

  /// 「定位到所在页」：冲刷未落盘编辑后带着定位请求退栈——编辑器
  /// 跳到该页并在详细视图选中闪烁该字（与单页版定位同一体验）。
  void _locateMember(_MemberRef m) {
    if (_popping) return;
    _popping = true;
    _saveDebounce?.cancel();
    _saveDebounce = null;
    final nav = Navigator.of(context);
    unawaited(
      _flushDirtyNow().then((_) {
        if (mounted) {
          nav.pop(
            BookClassifyResult(
              modifiedPages: _modifiedPages,
              locatePage: m.page,
              locateBlockId: m.block.id,
            ),
          );
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 有未落盘编辑时先冲刷再返回（写盘层虽按文件串行等待，仍显式
      // 冲刷一次再退栈，避免返回后的编辑器读到旧盘文件）。
      canPop: _dirtyPages.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _flushAndPop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('墨迹归类 · 全书 · ${widget.project.name}'),
          actions: [
            if (_stage == _Stage.done && _result != null)
              IconButton(
                tooltip: '重新归类（当前范围与阈值）',
                icon: const Icon(Icons.refresh),
                onPressed: () => unawaited(_runCluster()),
              ),
            TextButton(
              onPressed: _dirtyPages.isEmpty
                  ? () => Navigator.of(context).pop(
                      BookClassifyResult(modifiedPages: _modifiedPages),
                    )
                  : _flushAndPop,
              child: Text(
                _dirtyPages.isEmpty ? '完成' : '保存并完成',
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
        body: switch (_stage) {
          _Stage.setup => _buildSetup(),
          _Stage.loading => _buildLoading(),
          _Stage.clustering => _buildClustering(),
          _Stage.done => _buildResult(),
        },
      ),
    );
  }

  // ── 各阶段视图 ──

  Widget _buildSetup() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.auto_stories, size: 44, color: Colors.grey),
              const SizedBox(height: 12),
              const Text(
                '全书墨迹归类',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              const Text(
                '把指定页范围（或整本书）的正文字块按墨迹形态跨页聚类：'
                '同一字形在全书各页的实例会聚成一组，可点选/框选后整组'
                '统一改字，或点「确认所选」把选中的文字直接置为已确认'
                '并保存（与编辑器「确认并保存」等效）。遇到切字边框'
                '有问题的字，双击它可打开所在行的行内重切。大书耗时'
                '可达分钟级，可先小范围试跑。',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  _pageField('起始页', _startCtrl),
                  const SizedBox(width: 12),
                  _pageField('结束页', _endCtrl),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  ActionChip(
                    label: const Text('整本书'),
                    onPressed: () => _applyQuickRange(0, _pageCount - 1),
                  ),
                  ActionChip(
                    label: const Text('从当前页到末页'),
                    onPressed: () =>
                        _applyQuickRange(widget.currentPageIndex, _pageCount - 1),
                  ),
                  ActionChip(
                    label: const Text('当前页前后 10 页'),
                    onPressed: () => _applyQuickRange(
                      (widget.currentPageIndex - 10).clamp(0, _pageCount - 1),
                      (widget.currentPageIndex + 10).clamp(0, _pageCount - 1),
                    ),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: TextStyle(color: Colors.red.shade700, fontSize: 13),
                ),
              ],
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () => unawaited(_start()),
                icon: const Icon(Icons.play_arrow),
                label: const Text('开始归类'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pageField(String label, TextEditingController ctrl) {
    return Expanded(
      child: TextField(
        controller: ctrl,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
          suffixText: '/ $_pageCount',
        ),
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(6),
        ],
      ),
    );
  }

  Widget _buildLoading() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(value: _loadProgress),
          const SizedBox(height: 12),
          Text(
            '正在载入第 ${_rangeStart + 1}–${_rangeEnd + 1} 页标注'
            '（${(_loadProgress * 100).toStringAsFixed(0)}%）'
            '${_noAnnotationCount > 0 ? '，$_noAnnotationCount 页无标注' : ''}',
          ),
        ],
      ),
    );
  }

  Widget _buildClustering() {
    final totalChars = _blocksByPage.values.fold<int>(
      0,
      (s, m) => s + m.length,
    );
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 12),
          Text(
            '正在按墨迹形态聚类 ${_blocksByPage.length} 页 / $totalChars 字…'
            '（大书可达分钟级，请耐心等待）',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildResult() {
    if (_error != null) {
      return _HintView(
        icon: Icons.error_outline,
        text: '归类失败：$_error',
        action: FilledButton.icon(
          onPressed: () => unawaited(_runCluster()),
          icon: const Icon(Icons.refresh),
          label: const Text('重试'),
        ),
      );
    }
    final result = _result;
    if (result == null || (_groups.isEmpty && _singletons.isEmpty)) {
      return const _HintView(
        icon: Icons.category_outlined,
        text: '没有聚出相似字组（阈值可能太严格），试试调宽松一些。',
      );
    }
    final groups = _groups
        .where((g) => g.members.any(_memberVisible))
        .where((g) => !_onlyPending || _groupNeedsAttention(g))
        .toList();
    final singletons = _singletons
        .where(_memberVisible)
        .where((m) => !_onlyPending || _memberNeedsAttention(m))
        .toList();
    if (groups.isEmpty && singletons.isEmpty) {
      if (_onlyMarked) {
        final markedCount = _markedCount();
        return _HintView(
          icon: Icons.flag_outlined,
          text: markedCount > 0
              ? '范围内有 $markedCount 个标记字，但都不满足当前筛选'
                  '（「只看待处理组」或「显示已确认」把它们滤掉了），'
                  '试试关闭其他筛选。'
              : '范围内没有标记的特殊字。归类时点选/框选存疑的字后用「标记」'
                    '按钮打标，等全书识别完成后切回「只看标记」集中校对。',
        );
      }
      final allHidden =
          _groups.isNotEmpty && _groups.every((g) => !g.members.any(_memberVisible));
      return _HintView(
        icon: Icons.verified_outlined,
        text: _onlyPending || allHidden
            ? '待处理字都已完成：已确认的字默认隐藏，打开「显示已确认」可查看。'
            : '没有聚出相似字组（阈值可能太严格），试试调宽松一些。',
      );
    }
    return Column(
      children: [
        _buildToolbar(result, groups.length),
        if (result.failedPages.isNotEmpty)
          Container(
            width: double.infinity,
            color: Colors.orange.shade50,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Text(
              '${result.failedPages.length} 页聚类失败被跳过：'
              '${result.failedPages.map((e) => e.key).join('、')}',
              style: TextStyle(fontSize: 11, color: Colors.orange.shade900),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        Expanded(child: _buildGroupList(groups, singletons)),
      ],
    );
  }

  /// 范围内特殊字标记总数（含已确认的，供统计行与提示文案）。
  int _markedCount() => _blocksByPage.values.fold<int>(
    0,
    (s, m) => s + m.values.where((b) => b.marked).length,
  );

  Widget _buildToolbar(CharClusterResult result, int visibleGroups) {
    final totalChars = _blocksByPage.values.fold<int>(
      0,
      (s, m) => s + m.length,
    );
    final markedCount = _markedCount();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.grey.shade50,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '第 ${_rangeStart + 1}–${_rangeEnd + 1} 页 · $totalChars 字 → '
                  '${_groups.length} 组（显示 $visibleGroups）'
                  '· 未归组 ${_singletons.length}'
                  '${markedCount > 0 ? ' · 特殊字 $markedCount' : ''}'
                  '${_noAnnotationCount > 0 ? ' · $_noAnnotationCount 页无标注' : ''}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
              const Text('只看待处理组', style: TextStyle(fontSize: 12)),
              Switch(
                value: _onlyPending,
                onChanged: (v) => setState(() => _onlyPending = v),
              ),
              const SizedBox(width: 8),
              const Text('显示已确认', style: TextStyle(fontSize: 12)),
              Switch(
                value: _showConfirmed,
                onChanged: (v) => setState(() => _showConfirmed = v),
              ),
            ],
          ),
          Row(
            children: [
              FilterChip(
                label: const Text('隐藏标记', style: TextStyle(fontSize: 12)),
                tooltip: '隐藏已标记的特殊字，正常归类不受存疑字干扰',
                selected: _hideMarked,
                onSelected: (v) => setState(() {
                  _hideMarked = v;
                  if (v) _onlyMarked = false;
                }),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              const SizedBox(width: 6),
              FilterChip(
                label: const Text('只看标记', style: TextStyle(fontSize: 12)),
                tooltip: '只显示已标记的特殊字——全书识别完成后集中校对',
                selected: _onlyMarked,
                onSelected: (v) => setState(() {
                  _onlyMarked = v;
                  if (v) _hideMarked = false;
                }),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              const SizedBox(width: 12),
              const Text(
                '严格',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
              Expanded(
                child: Slider(
                  value: _threshold,
                  min: 0.05,
                  max: 0.35,
                  divisions: 30,
                  label: _threshold.toStringAsFixed(2),
                  onChanged: (v) => setState(() => _threshold = v),
                  onChangeEnd: (_) => unawaited(_runCluster()),
                ),
              ),
              const Text(
                '宽松',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
              SizedBox(
                width: 44,
                child: Text(
                  _threshold.toStringAsFixed(2),
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGroupList(List<_BookGroup> groups, List<_MemberRef> singletons) {
    final hasSingletons = singletons.isNotEmpty;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: groups.length + (hasSingletons ? 1 : 0),
      itemBuilder: (context, index) {
        if (index < groups.length) {
          final group = groups[index];
          return _BookClusterCard(
            key: ValueKey('bcluster-${group.id}'),
            index: index + 1,
            group: group,
            project: widget.project,
            thumbs: _thumbs,
            showConfirmed: _showConfirmed,
            hideMarked: _hideMarked,
            onlyMarked: _onlyMarked,
            confirmable: !_confirmingGroup,
            onApplyText: _applyText,
            onConfirmSelected: _confirmSelected,
            onSetMarked: _setMarked,
            onEditMember: _editMember,
            onOpenLineReseg: _openLineReseg,
            onLocateMember: _locateMember,
            onEnsureThumbs: (members) => unawaited(_ensureThumbs(members)),
          );
        }
        return _BookSingletonsCard(
          key: const ValueKey('bsingletons'),
          singletons: singletons,
          skippedCount: _result?.skipped.length ?? 0,
          project: widget.project,
          thumbs: _thumbs,
          onEditMember: _editMember,
          onLocateMember: _locateMember,
          onEnsureThumbs: (members) => unawaited(_ensureThumbs(members)),
        );
      },
    );
  }
}

enum _Stage { setup, loading, clustering, done }

/// 单个跨页相似组的卡片：字图缩略图 + 点选/框选 + 统一改字 / 单独改字 /
/// 确认所选（选中的非空文字置为已确认并保存，转绿色确认态）与
/// 标记所选（特殊字标记/取消标记）。已确认的字默认从组里隐藏
/// （「显示已确认」开关回显）；标记字受「隐藏标记/只看标记」筛选。
class _BookClusterCard extends StatefulWidget {
  final int index;
  final _BookGroup group; // 完整分组（含已确认成员）
  final Project project;
  final Map<String, String> thumbs;
  final bool showConfirmed;
  final bool hideMarked;
  final bool onlyMarked;
  final bool confirmable;
  final void Function(List<_MemberRef> members, String text) onApplyText;
  final Future<void> Function(Set<String> selectedKeys) onConfirmSelected;
  final void Function(List<_MemberRef> members, bool marked) onSetMarked;
  final Future<void> Function(_MemberRef member) onEditMember;

  /// 双击字格：打开该字所在行的行内重切（切字边框问题入口）。
  final void Function(_MemberRef member) onOpenLineReseg;

  /// 字格下方的定位按钮：回到编辑器跳到该字所在页并选中闪烁。
  final void Function(_MemberRef member) onLocateMember;
  final void Function(List<_MemberRef> members) onEnsureThumbs;

  const _BookClusterCard({
    super.key,
    required this.index,
    required this.group,
    required this.project,
    required this.thumbs,
    required this.showConfirmed,
    required this.hideMarked,
    required this.onlyMarked,
    required this.confirmable,
    required this.onApplyText,
    required this.onConfirmSelected,
    required this.onSetMarked,
    required this.onEditMember,
    required this.onOpenLineReseg,
    required this.onLocateMember,
    required this.onEnsureThumbs,
  });

  @override
  State<_BookClusterCard> createState() => _BookClusterCardState();
}

class _BookClusterCardState extends State<_BookClusterCard> {
  late final TextEditingController _input;

  /// 选中集合（'页号|块id'，点选/框选累积）：套用与确认只作用于选中的字。
  final Set<String> _selected = {};
  bool _expanded = false;

  /// 折叠态显示的成员上限（大组首屏只拉一批缩略图，展开再看全部）。
  static const _collapsedLimit = 60;

  /// 命中测试用 key：图块容器（点选/框选）与角标按钮（点选路由）。
  late final Map<String, GlobalKey> _cellKeys = {
    for (final m in widget.group.members) _keyOf(m): GlobalKey(),
  };
  late final Map<String, GlobalKey> _editKeys = {
    for (final m in widget.group.members) _keyOf(m): GlobalKey(),
  };
  late final Map<String, GlobalKey> _locateKeys = {
    for (final m in widget.group.members) _keyOf(m): GlobalKey(),
  };

  /// 框选进行中的预览：null=无框选；加选=选中∪命中，减选=选中−命中。
  bool? _bandAdd;
  Set<String> _bandHits = const {};

  static String _keyOf(_MemberRef m) => '${m.page}|${m.block.id}';

  @override
  void initState() {
    super.initState();
    _input = TextEditingController(text: _majorityText());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onEnsureThumbs(_displayedMembers());
    });
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_BookClusterCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 成员被确认后默认隐藏，选区同步剪掉隐藏成员，计数保持准确。
    final visible = {for (final m in _visibleMembers) _keyOf(m)};
    _selected.retainWhere(visible.contains);
  }

  bool _isConfirmed(_MemberRef m) =>
      m.block.text.isNotEmpty && m.block.status == AnnotationStatus.confirmed;

  bool _isMarked(_MemberRef m) => m.block.marked;

  /// 与页面级 _memberVisible 同口径：已确认默认隐藏 + 标记筛选。
  bool _isVisible(_MemberRef m) {
    if (widget.hideMarked && _isMarked(m)) return false;
    if (widget.onlyMarked && !_isMarked(m)) return false;
    return widget.showConfirmed || !_isConfirmed(m);
  }

  /// 组内可见（参与点选/框选/计数）的成员：已确认的默认隐藏。
  List<_MemberRef> get _visibleMembers =>
      widget.group.members.where(_isVisible).toList();

  bool _isSelected(String key) {
    final base = _selected.contains(key);
    if (_bandAdd == null) return base;
    final inBand = _bandHits.contains(key);
    return _bandAdd! ? base || inBand : base && !inBand;
  }

  // ── 点选 / 框选（由 BandSelectSurface 路由）──

  /// 双击检测：400ms 内连点同一字格 → 打开该字所在行的行内重切
  /// （切字边框有问题时的入口）；第一次点击的选中态保持不变。
  String? _lastTapKey;
  DateTime? _lastTapAt;

  void _onTapCell(String key) {
    final now = DateTime.now();
    if (_lastTapKey == key &&
        _lastTapAt != null &&
        now.difference(_lastTapAt!) < const Duration(milliseconds: 400)) {
      _lastTapKey = null;
      _lastTapAt = null;
      for (final m in widget.group.members) {
        if (_keyOf(m) == key) {
          widget.onOpenLineReseg(m);
          return;
        }
      }
      return;
    }
    _lastTapKey = key;
    _lastTapAt = now;
    setState(() {
      if (!_selected.remove(key)) _selected.add(key);
    });
  }

  void _onTapAction(String actionId) {
    // actionId 形如 'edit:<页号|块id>' / 'locate:<页号|块id>'。
    if (actionId.startsWith('edit:')) {
      final target = actionId.substring(5);
      for (final m in widget.group.members) {
        if (_keyOf(m) == target) {
          widget.onEditMember(m);
          return;
        }
      }
    } else if (actionId.startsWith('locate:')) {
      final target = actionId.substring(7);
      for (final m in widget.group.members) {
        if (_keyOf(m) == target) {
          widget.onLocateMember(m);
          return;
        }
      }
    }
  }

  void _onBandStart(bool addMode) => setState(() {
    _bandAdd = addMode;
    _bandHits = const {};
  });

  void _onBandUpdate(Set<String> hits, bool addMode) => setState(() {
    _bandAdd = addMode;
    _bandHits = hits;
  });

  void _onBandEnd() {
    if (_bandAdd == true) _selected.addAll(_bandHits);
    if (_bandAdd == false) _selected.removeAll(_bandHits);
    setState(() {
      _bandAdd = null;
      _bandHits = const {};
    });
  }

  void _onBandCancel() => setState(() {
    _bandAdd = null;
    _bandHits = const {};
  });

  void _selectAll() => setState(() {
    _selected.addAll({for (final m in _visibleMembers) _keyOf(m)});
  });

  void _clearSelection() => setState(() {
    _selected.removeAll({for (final m in _visibleMembers) _keyOf(m)});
  });

  /// 反选：可见成员里选中的去掉、没选中的全加（不可见成员不参与，
  /// 与全选/取消选择的口径一致）。
  void _invertSelection() => setState(() {
    final previous = _selected.toSet();
    _selected
      ..clear()
      ..addAll({
        for (final m in _visibleMembers)
          if (!previous.contains(_keyOf(m))) _keyOf(m),
      });
  });

  /// 标记所选：选中的字全部已标记 → 取消标记，否则统一打标记。
  void _toggleMarkSelected() {
    final members = _visibleMembers
        .where((m) => _selected.contains(_keyOf(m)))
        .toList();
    if (members.isEmpty) return;
    final allMarked = members.every(_isMarked);
    widget.onSetMarked(members, !allMarked);
  }

  /// 折叠态显示的可见成员（大组首屏只拉一批缩略图，展开再看全部）。
  List<_MemberRef> _displayedMembers() {
    final members = _visibleMembers;
    return _expanded || members.length <= _collapsedLimit
        ? members
        : members.take(_collapsedLimit).toList();
  }

  /// 可见成员的多数文字（预填统一改字输入框）。
  String _majorityText() {
    final counter = <String, int>{};
    for (final m in _visibleMembers) {
      final t = m.block.text;
      counter[t] = (counter[t] ?? 0) + 1;
    }
    if (counter.isEmpty) return '';
    final entries = counter.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.first.key;
  }

  /// 组内多数文字（按可见成员统计，空字不计入）；头部文字分布与
  /// 缩略图下方的"少数派"高亮基于它。
  String _groupMajorityText() {
    final counter = <String, int>{};
    for (final m in _visibleMembers) {
      if (m.block.text.isEmpty) continue;
      counter[m.block.text] = (counter[m.block.text] ?? 0) + 1;
    }
    if (counter.isEmpty) return '';
    final entries = counter.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.first.key;
  }

  List<CharCandidate> _mergedCandidates() {
    final scores = <String, double>{};
    for (final m in _visibleMembers) {
      for (final c in m.block.candidates) {
        if (c.text.isEmpty || c.text.length != 1) continue;
        scores[c.text] = (scores[c.text] ?? 0) + c.score;
      }
    }
    final list = scores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final maxScore = list.isEmpty ? 1.0 : list.first.value;
    return list
        .take(5)
        .map((e) => CharCandidate(text: e.key, score: e.value / maxScore))
        .toList();
  }

  void _applyToSelected([String? override]) {
    final text = override ?? _input.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('先输入要统一的文字，或点候选快选'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    final members = _visibleMembers
        .where((m) => _selected.contains(_keyOf(m)))
        .toList();
    if (members.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('没有选中的字：点选或框选后再套用'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    widget.onApplyText(members, text);
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visibleMembers;
    if (visible.isEmpty) return const SizedBox.shrink();
    final majority = _groupMajorityText();
    final distribution = <String, int>{};
    for (final m in visible) {
      final key = m.block.text.isEmpty ? '（空）' : m.block.text;
      distribution[key] = (distribution[key] ?? 0) + 1;
    }
    final distEntries = distribution.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final candidates = _mergedCandidates();
    final pages = widget.group.members.map((m) => m.page).toSet().length;
    final displayed = _displayedMembers();
    final selectedKeys = {
      for (final m in visible)
        if (_selected.contains(_keyOf(m))) _keyOf(m),
    };
    final confirmableKeys = {
      for (final m in visible)
        if (_selected.contains(_keyOf(m)) &&
            m.block.text.trim().isNotEmpty &&
            !_isConfirmed(m))
          _keyOf(m),
    };
    final hiddenCount = widget.group.members.length - visible.length;
    final markedCount = widget.group.members.where(_isMarked).length;
    final allConfirmed = widget.group.members.every(
      (m) => m.block.text.isEmpty || _isConfirmed(m),
    );
    final selectedMarkedAll = selectedKeys.isNotEmpty &&
        visible
            .where((m) => selectedKeys.contains(_keyOf(m)))
            .every(_isMarked);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '组 ${widget.index} · ${visible.length}/'
                  '${widget.group.members.length} 字 · $pages 页',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (hiddenCount > 0) ...[
                  const SizedBox(width: 8),
                  Tooltip(
                    message: '已确认的字默认隐藏，打开「显示已确认」可查看',
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.green.shade50,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.green.shade200),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.check,
                            size: 10,
                            color: Colors.green.shade700,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            '$hiddenCount',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.green.shade700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 8),
                if (markedCount > 0) ...[
                  Tooltip(
                    message: '特殊字标记 $markedCount 个（可能裁分有问题或'
                        '暂无法识别），「只看标记」可筛出集中校对',
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.deepOrange.shade50,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.deepOrange.shade200),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.flag,
                            size: 10,
                            color: Colors.deepOrange.shade700,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            '$markedCount',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.deepOrange.shade700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Tooltip(
                  message: '组内平均中心距离（越小越像）',
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      widget.group.cohesion.toStringAsFixed(3),
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.blue.shade700,
                      ),
                    ),
                  ),
                ),
                const Spacer(),
                Flexible(
                  child: Text(
                    distEntries
                        .map((e) => e.value > 1 ? '${e.key}×${e.value}' : e.key)
                        .join('  '),
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: '选择全组（当前显示的字）',
                  icon: const Icon(Icons.select_all, size: 18),
                  visualDensity: VisualDensity.compact,
                  onPressed: _selectAll,
                ),
                IconButton(
                  tooltip: '反选本组（当前显示的字）',
                  icon: const Icon(Icons.flip, size: 18),
                  visualDensity: VisualDensity.compact,
                  onPressed: visible.isEmpty ? null : _invertSelection,
                ),
                IconButton(
                  tooltip: '取消选择',
                  icon: const Icon(Icons.deselect, size: 18),
                  visualDensity: VisualDensity.compact,
                  onPressed: selectedKeys.isEmpty ? null : _clearSelection,
                ),
              ],
            ),
            const SizedBox(height: 8),
            BandSelectSurface(
              cellKeys: {
                for (final m in visible) _keyOf(m): _cellKeys[_keyOf(m)]!,
              },
              actionKeys: {
                for (final m in visible) 'edit:${_keyOf(m)}': _editKeys[_keyOf(m)]!,
                for (final m in visible)
                  'locate:${_keyOf(m)}': _locateKeys[_keyOf(m)]!,
              },
              selectedIds: _selected,
              onTapCell: _onTapCell,
              onTapAction: _onTapAction,
              onBandStart: _onBandStart,
              onBandUpdate: _onBandUpdate,
              onBandEnd: _onBandEnd,
              onBandCancel: _onBandCancel,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final m in displayed)
                    _BookCharCell(
                      member: m,
                      thumb: widget.thumbs[_keyOf(m)],
                      selected: _isSelected(_keyOf(m)),
                      isMinority:
                          majority.isNotEmpty &&
                          m.block.text.isNotEmpty &&
                          m.block.text != majority,
                      isConfirmed: _isConfirmed(m),
                      isMarked: _isMarked(m),
                      routed: true,
                      cellKey: _cellKeys[_keyOf(m)],
                      editKey: _editKeys[_keyOf(m)],
                      locateKey: _locateKeys[_keyOf(m)],
                    ),
                ],
              ),
            ),
            if (!_expanded && visible.length > _collapsedLimit)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () {
                      setState(() => _expanded = true);
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) widget.onEnsureThumbs(visible);
                      });
                    },
                    icon: const Icon(Icons.unfold_more, size: 16),
                    label: Text(
                      '展开全部 ${visible.length} 字'
                      '（还有 ${visible.length - _collapsedLimit} 个）',
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: '统一设置为…',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                    ),
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: selectedMarkedAll
                      ? '取消选中字的特殊字标记'
                      : '把选中的字标记为特殊字（可能裁分有问题或暂无法识别，'
                            '等全书识别完成后再校对）',
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.deepOrange.shade700,
                      side: BorderSide(color: Colors.deepOrange.shade300),
                    ),
                    onPressed: selectedKeys.isEmpty
                        ? null
                        : _toggleMarkSelected,
                    icon: Icon(
                      selectedMarkedAll ? Icons.flag : Icons.flag_outlined,
                      size: 16,
                    ),
                    label: Text(
                      selectedMarkedAll
                          ? '取消标记（${selectedKeys.length}）'
                          : '标记（${selectedKeys.length}）',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: selectedKeys.isEmpty
                      ? null
                      : () => _applyToSelected(),
                  icon: const Icon(Icons.done_all, size: 16),
                  label: Text('套用（${selectedKeys.length}）'),
                ),
                const SizedBox(width: 8),
                _buildConfirmButton(allConfirmed, confirmableKeys),
              ],
            ),
            if (candidates.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final c in candidates)
                    _CandidateChip(
                      text: c.text,
                      score: c.score,
                      onTap: () {
                        _input.text = c.text;
                        _applyToSelected(c.text);
                      },
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 确认按钮：只确认选中的非空文字；组内全部确认后变绿色「已确认」
  /// 徽标（此时组默认整体隐藏，开关打开才可见）。
  Widget _buildConfirmButton(bool allConfirmed, Set<String> confirmableKeys) {
    if (allConfirmed) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.green.shade50,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.green.shade200),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle, size: 14, color: Colors.green.shade700),
            const SizedBox(width: 4),
            Text(
              '已确认',
              style: TextStyle(
                fontSize: 12,
                color: Colors.green.shade800,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }
    return Tooltip(
      message: '只确认选中的非空文字并保存（空文字不参与）',
      child: FilledButton.tonalIcon(
        style: FilledButton.styleFrom(
          backgroundColor: Colors.green.shade50,
          foregroundColor: Colors.green.shade800,
        ),
        onPressed:
            widget.confirmable && confirmableKeys.isNotEmpty
            ? () => widget.onConfirmSelected(confirmableKeys)
            : null,
        icon: const Icon(Icons.task_alt, size: 16),
        label: Text(
          confirmableKeys.isEmpty
              ? '确认所选'
              : '确认所选（${confirmableKeys.length}）',
        ),
      ),
    );
  }
}

/// 未归组单字（全书只出现一次的字形）：默认折叠，展开也只出前几百个，
/// 避免大书数千单字一次拉爆缩略图与布局。
class _BookSingletonsCard extends StatefulWidget {
  final List<_MemberRef> singletons;
  final int skippedCount;
  final Project project;
  final Map<String, String> thumbs;
  final Future<void> Function(_MemberRef member) onEditMember;

  /// 字格页号旁的定位按钮：回到编辑器跳到该字所在页并选中闪烁。
  final void Function(_MemberRef member) onLocateMember;
  final void Function(List<_MemberRef> members) onEnsureThumbs;

  const _BookSingletonsCard({
    super.key,
    required this.singletons,
    required this.skippedCount,
    required this.project,
    required this.thumbs,
    required this.onEditMember,
    required this.onLocateMember,
    required this.onEnsureThumbs,
  });

  @override
  State<_BookSingletonsCard> createState() => _BookSingletonsCardState();
}

class _BookSingletonsCardState extends State<_BookSingletonsCard> {
  bool _expanded = false;
  static const _displayLimit = 300;

  void _expand() {
    setState(() => _expanded = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onEnsureThumbs(widget.singletons.take(_displayLimit).toList());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: Colors.grey.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  '未归组单字',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 8),
                Text(
                  '${widget.singletons.length} 字'
                  '${widget.skippedCount > 0 ? ' · ${widget.skippedCount} 个字块无法提墨迹' : ''}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _expanded ? null : _expand,
                  icon: Icon(
                    _expanded ? Icons.visibility_off : Icons.visibility,
                    size: 16,
                  ),
                  label: Text(_expanded ? '已展开' : '展开查看'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '这些字形在归类范围内只出现一次，批量校正没有杠杆，'
              '建议在编辑器里逐页校对。${_expanded && widget.singletons.length > _displayLimit ? '仅显示前 $_displayLimit 个。' : ''}',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
            if (_expanded)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final m in widget.singletons.take(_displayLimit))
                      _BookCharCell(
                        member: m,
                        thumb: widget.thumbs['${m.page}|${m.block.id}'],
                        selected: false,
                        isMinority: false,
                        isConfirmed:
                            m.block.text.isNotEmpty &&
                            m.block.status == AnnotationStatus.confirmed,
                        isMarked: m.block.marked,
                        routed: false,
                        onTap: () => widget.onEditMember(m),
                        onLocate: () => widget.onLocateMember(m),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 跨页版单字缩略格：后端裁切的缩略图 + 当前文字 + 页号。
/// 组内格子（routed=true）：点选与角标改字的点击由 BandSelectSurface
/// 路由（InkWell 的 onTap 不会触发，仅保留悬停光标）；未归组单字
/// （routed=false）：点图直接弹修改框。isConfirmed：绿色确认态；
/// isMarked：特殊字标记 → 左上角深橙小旗角标。
class _BookCharCell extends StatelessWidget {
  final _MemberRef member;
  final String? thumb; // base64 PNG；null=未加载，''=裁切失败
  final bool selected; // 点选/框选选中 → 蓝色加粗边框
  final bool isMinority;
  final bool isConfirmed;
  final bool isMarked; // 特殊字标记 → 左上角小旗角标
  final bool routed; // true=点击由 BandSelectSurface 路由
  final Key? cellKey; // 图块容器 key（surface 点选/框选命中目标）
  final Key? editKey; // 右上角改字按钮 key（surface 路由目标）
  final Key? locateKey; // 页号旁定位按钮 key（surface 路由目标）
  final VoidCallback? onTap; // routed=false 时的点击回调
  final VoidCallback? onLocate; // routed=false 时的定位回调

  const _BookCharCell({
    required this.member,
    required this.thumb,
    required this.selected,
    required this.isMinority,
    required this.isConfirmed,
    this.isMarked = false,
    required this.routed,
    this.cellKey,
    this.editKey,
    this.locateKey,
    this.onTap,
    this.onLocate,
  });

  @override
  Widget build(BuildContext context) {
    const cell = 64.0;
    final showEdit = routed && editKey != null;
    final text = member.block.text;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          children: [
            InkWell(
              onTap: routed ? null : onTap,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Container(
                  key: cellKey,
                  width: cell,
                  height: cell,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: selected
                          ? Colors.blue
                          : isConfirmed
                          ? Colors.green.shade400
                          : Colors.grey.shade300,
                      width: selected || isConfirmed ? 2 : 1,
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: _buildThumb(),
                  ),
                ),
              ),
            ),
            if (showEdit)
              Positioned(
                top: 0,
                right: 0,
                child: Tooltip(
                  message: '修改此字',
                  child: SizedBox(
                    key: editKey,
                    width: 22,
                    height: 22,
                    child: Material(
                      color: Colors.white70,
                      borderRadius: const BorderRadius.only(
                        bottomLeft: Radius.circular(4),
                      ),
                      child: InkWell(
                        // 点击由 BandSelectSurface 路由，这里只做悬停光标
                        onTap: null,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: Icon(
                            Icons.edit,
                            size: 13,
                            color: Colors.blueGrey.shade700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (isMarked)
              Positioned(
                top: 0,
                left: 0,
                child: Tooltip(
                  message: '特殊字标记：可能裁分有问题或暂无法识别，'
                      '待全书识别完成后校对',
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: Colors.deepOrange.shade400,
                      borderRadius: const BorderRadius.only(
                        bottomRight: Radius.circular(4),
                      ),
                    ),
                    child: const Icon(
                      Icons.flag,
                      size: 11,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 2),
        SizedBox(
          width: cell,
          child: Text(
            text.isEmpty ? '（空）' : text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              height: 1.2,
              fontWeight: isMinority || isConfirmed ? FontWeight.w600 : null,
              color: text.isEmpty
                  ? Colors.red.shade400
                  : isConfirmed
                  ? Colors.green.shade800
                  : (isMinority ? Colors.orange.shade700 : Colors.black87),
            ),
          ),
        ),
        SizedBox(
          width: cell,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (locateKey != null || onLocate != null)
                Tooltip(
                  message: '定位到所在页：回到编辑器跳到该页并选中此字',
                  child: SizedBox(
                    key: locateKey,
                    child: InkWell(
                      // 组内格子点击由 BandSelectSurface 路由
                      onTap: routed ? null : onLocate,
                      borderRadius: BorderRadius.circular(4),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 1,
                            vertical: 2,
                          ),
                          child: Icon(
                            Icons.my_location,
                            size: 12,
                            color: Colors.blueGrey.shade400,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              Flexible(
                child: Text(
                  '第 ${member.page + 1} 页',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 9.5,
                    color: Colors.blueGrey.shade400,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildThumb() {
    if (thumb == null) {
      return Container(
        color: Colors.grey.shade100,
        alignment: Alignment.center,
        child: SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Colors.grey.shade300,
          ),
        ),
      );
    }
    if (thumb!.isEmpty) {
      return Container(color: Colors.grey.shade100);
    }
    try {
      return Image.memory(
        base64Decode(thumb!),
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => Container(color: Colors.grey.shade100),
      );
    } catch (_) {
      return Container(color: Colors.grey.shade100);
    }
  }
}

/// 候选字快选格：字 + 拼音 + 汇总分，点击即整组套用。
class _CandidateChip extends StatelessWidget {
  final String text;
  final double score;
  final VoidCallback onTap;

  const _CandidateChip({
    required this.text,
    required this.score,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pinyin = charPinyin(text);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text, style: const TextStyle(fontSize: 20, height: 1.1)),
            if (pinyin.isNotEmpty)
              Text(pinyin, style: TextStyle(fontSize: 9, color: Colors.blue.shade600)),
            Text(
              '${(score * 100).toStringAsFixed(0)}%',
              style: TextStyle(fontSize: 9, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单字修改对话框（与单页版同交互：输入框 + 该字块候选 + 行内重切入口
/// + 特殊字标记开关，确定时以 record 返回文字与标记状态）。
class _SingleCharDialog extends StatefulWidget {
  final CharBlock block;
  final String currentText;

  /// 打开对话框时的特殊字标记状态。
  final bool initialMarked;

  /// 非空时显示「行内重切」按钮：关闭本对话框并打开该字所在行的
  /// 行内重切页（切字边框有问题的另一个入口）。
  final VoidCallback? onLineReseg;

  /// 非空时显示「定位到所在页」按钮：关闭本对话框并回到编辑器
  /// 跳到该字所在页选中闪烁（看上下文的入口）。
  final VoidCallback? onLocate;

  const _SingleCharDialog({
    required this.block,
    required this.currentText,
    this.initialMarked = false,
    this.onLineReseg,
    this.onLocate,
  });

  @override
  State<_SingleCharDialog> createState() => _SingleCharDialogState();
}

class _SingleCharDialogState extends State<_SingleCharDialog> {
  late final TextEditingController _input;
  late bool _marked = widget.initialMarked;

  @override
  void initState() {
    super.initState();
    _input = TextEditingController(text: widget.currentText);
    _input.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _input.text.length,
    );
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _commit(String text) =>
      Navigator.of(context).pop((text: text, marked: _marked));

  @override
  Widget build(BuildContext context) {
    final candidates = [...widget.block.candidates]
      ..sort((a, b) => b.score.compareTo(a.score));
    if (widget.currentText.isNotEmpty &&
        !candidates.any((c) => c.text == widget.currentText)) {
      candidates.insert(0, CharCandidate(text: widget.currentText, score: 1));
    }
    return AlertDialog(
      title: const Text('修改单字', style: TextStyle(fontSize: 18)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _input,
              autofocus: true,
              maxLength: 2,
              maxLengthEnforcement: MaxLengthEnforcement
                  .truncateAfterCompositionEnds,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                counterText: '',
              ),
              style: const TextStyle(fontSize: 22),
              onSubmitted: (v) => _commit(v.trim()),
            ),
            const SizedBox(height: 12),
            Tooltip(
              message: '标记后该字在归类里带小旗角标，可「隐藏标记」先跳过，'
                  '等全书识别完成后用「只看标记」筛回来集中校对',
              child: InkWell(
                onTap: () => setState(() => _marked = !_marked),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: _marked
                        ? Colors.deepOrange.shade50
                        : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: _marked
                          ? Colors.deepOrange.shade300
                          : Colors.grey.shade300,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _marked ? Icons.flag : Icons.flag_outlined,
                        size: 16,
                        color: _marked
                            ? Colors.deepOrange.shade700
                            : Colors.blueGrey.shade600,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _marked ? '已标记特殊字（点击取消）' : '标记为特殊字',
                          style: TextStyle(
                            fontSize: 12,
                            color: _marked
                                ? Colors.deepOrange.shade700
                                : Colors.blueGrey.shade700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (candidates.isNotEmpty) ...[
              const Text('候选', style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 6),
              Flexible(
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final c in candidates.take(12))
                        _CandidateChip(
                          text: c.text,
                          score: c.score,
                          onTap: () => _commit(c.text),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (widget.onLocate != null)
          TextButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              widget.onLocate!();
            },
            icon: const Icon(Icons.my_location, size: 16),
            label: const Text('定位到所在页'),
          ),
        if (widget.onLineReseg != null)
          TextButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              widget.onLineReseg!();
            },
            icon: const Icon(Icons.crop_free, size: 16),
            label: const Text('行内重切'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => _commit(_input.text.trim()),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

class _HintView extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;

  const _HintView({required this.icon, required this.text, this.action});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: Colors.grey.shade400),
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
