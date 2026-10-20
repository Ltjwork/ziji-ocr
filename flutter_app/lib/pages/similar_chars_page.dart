import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../services/python_service.dart';
import '../widgets/band_select_surface.dart';
import '../widgets/ctrl_scroll_zoom.dart';
import 'editor_page.dart' show charPinyin;
import 'similar_chars_book_page.dart' show BookClassifyResult;

/// 墨迹归类页（全屏）：把本页正文字块按墨迹形态聚类分组，
/// 逐组展示字图缩略图，支持点选/框选组内文字后统一改字（套用到
/// 所选）或点角标单独改字，以及「确认所选」——只把选中的非空文字
/// 置为已确认并保存（onBlocksConfirmed），显示与编辑器一致的绿色
/// 确认态。已确认的字默认从列表隐藏，工具栏「显示已确认」开关回显。
/// 「标记所选」给选中的字打/撤特殊字标记（裁分存疑或暂无法识别，
/// 等全书识别完成后用「只看标记」筛选回来校对）；「隐藏标记」开关
/// 把已标记的字从组里隐去不干扰正常归类。
class SimilarCharsPage extends StatefulWidget {
  final PageAnnotation annotation;
  final String imagePath;
  final int pageIndex;
  final void Function(String blockId, String newText) onBlockTextUpdated;

  /// 组级确认：把组内字块置为已确认并立即保存（编辑器实现）。
  final Future<void> Function(List<String> blockIds) onBlocksConfirmed;

  /// 特殊字标记/取消标记（编辑器实现，走防抖保存通道）。
  final void Function(List<String> blockIds, bool marked) onBlocksMarkUpdated;

  /// 点缩略格下方的定位按钮：返回编辑器并定位到该字所在的
  /// 行卡片（详细视图选中高亮 + 滚动到可见）。
  final void Function(String blockId) onLocateChar;

  /// 打开全书版（返回结果时本页带着它退回编辑器：重载受影响页或
  /// 执行其中的「定位到所在页」请求）。
  final Future<BookClassifyResult?> Function() onOpenBook;

  const SimilarCharsPage({
    super.key,
    required this.annotation,
    required this.imagePath,
    required this.pageIndex,
    required this.onBlockTextUpdated,
    required this.onBlocksConfirmed,
    required this.onBlocksMarkUpdated,
    required this.onLocateChar,
    required this.onOpenBook,
  });

  @override
  State<SimilarCharsPage> createState() => _SimilarCharsPageState();
}

// ── Ctrl+滚轮格子缩放（与编辑器详细视图同款交互） ──
const double kInkCellSize = 64.0;
const double kInkCellMinZoom = 0.5;
const double kInkCellMaxZoom = 3.0;

class _SimilarCharsPageState extends State<SimilarCharsPage> {
  ui.Image? _image;

  /// 字块快照（几何在本页内不会变，仅用于裁切与候选/状态展示）。
  late final Map<String, CharBlock> _blocksById;
  late final List<CharBlock> _mainTextBlocks;

  /// 本地文字镜像：多次修改后编辑器里的 CharBlock 实例会替换，
  /// 这里按 id 维护展示用的最新文字，避免持有过期引用。
  final Map<String, String> _texts = {};

  /// 已确认字块 id 集合（与文字镜像同理，不依赖可能被替换的实例）。
  final Set<String> _confirmedIds = {};

  /// 特殊字标记镜像（与文字镜像同理；编辑器侧持久化到标注 JSON）。
  final Set<String> _markedIds = {};

  double _threshold = 0.15;
  bool _onlyPending = true;

  /// 已确认的字默认从组里隐藏；开关打开时回显（绿色态）。
  bool _showConfirmed = false;

  /// 特殊字标记筛选：隐藏标记（正常归类不受存疑字干扰）与只看标记
  /// （全书识别完成后的标记字集中校对）互斥，同开等于什么都没有。
  bool _hideMarked = false;
  bool _onlyMarked = false;

  bool _loading = true;
  String? _error;
  CharClusterResult? _result;
  bool _confirmingGroup = false;

  double _cellZoom = 1.0;

  void _zoomCells(double factor) => setState(() {
    _cellZoom = (_cellZoom * factor).clamp(kInkCellMinZoom, kInkCellMaxZoom);
  });

  @override
  void initState() {
    super.initState();
    _mainTextBlocks = widget.annotation.blocks
        .where((b) => b.type == 'main_text')
        .toList(growable: false);
    _blocksById = {for (final b in _mainTextBlocks) b.id: b};
    for (final b in _mainTextBlocks) {
      _texts[b.id] = b.text;
      if (b.status == AnnotationStatus.confirmed) {
        _confirmedIds.add(b.id);
      }
      if (b.marked) _markedIds.add(b.id);
    }
    _loadImage();
    _runCluster();
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _loadImage() async {
    try {
      final bytes = await File(widget.imagePath).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() => _image = frame.image);
    } catch (_) {
      // 图片加载失败时缩略图区域显示占位，不阻塞聚类流程
    }
  }

  Future<void> _runCluster() async {
    if (_mainTextBlocks.isEmpty) {
      setState(() {
        _loading = false;
        _error = null;
        _result = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await PythonService.clusterChars(
        imagePath: widget.imagePath,
        blocks: _mainTextBlocks,
        threshold: _threshold,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst(RegExp('^Exception:\\s*'), '');
        _loading = false;
      });
    }
  }

  void _applyText(List<String> blockIds, String text) {
    final changed = <String>[];
    for (final id in blockIds) {
      if ((_texts[id] ?? '') != text) {
        changed.add(id);
      }
    }
    if (changed.isEmpty) return;
    for (final id in changed) {
      _texts[id] = text;
    }
    setState(() {});
    for (final id in changed) {
      widget.onBlockTextUpdated(id, text);
    }
  }

  /// 单字是否已确认（非空文字 + confirmed）——展示与隐藏的判定口径。
  bool _blockConfirmed(String id) =>
      (_texts[id] ?? '').isNotEmpty && _confirmedIds.contains(id);

  /// 已确认的字默认从列表隐藏，「显示已确认」开关打开时回显；
  /// 「隐藏标记/只看标记」对特殊字做反向筛选（两者互斥）。
  bool _blockVisible(String id) {
    final marked = _markedIds.contains(id);
    if (_hideMarked && marked) return false;
    if (_onlyMarked && !marked) return false;
    return _showConfirmed || !_blockConfirmed(id);
  }

  /// 特殊字标记/取消标记：本地镜像 + 编辑器写回（随防抖保存落盘）。
  void _setMarked(List<String> blockIds, bool marked) {
    final changed = [
      for (final id in blockIds)
        if (_markedIds.contains(id) != marked) id,
    ];
    if (changed.isEmpty) return;
    setState(() {
      if (marked) {
        _markedIds.addAll(changed);
      } else {
        _markedIds.removeAll(changed);
      }
    });
    widget.onBlocksMarkUpdated(changed, marked);
  }

  /// 单字是否存在待处理状态（空字或未确认）——用于「只看待处理」筛选。
  bool _blockNeedsAttention(String id) {
    if ((_texts[id] ?? '').isEmpty) return true;
    return !_confirmedIds.contains(id);
  }

  /// 组内是否存在待处理字（空字或未确认）——用于「只看待处理组」筛选。
  bool _groupNeedsAttention(List<String> blockIds) {
    return blockIds.any(_blockNeedsAttention);
  }

  /// 确认所选：只处理组卡片选中的字；空文字与已确认的字跳过
  /// （确认空字会污染训练数据），其余置为已确认并保存。
  Future<void> _confirmSelected(List<String> selectedIds) async {
    if (_confirmingGroup) return;
    final nonEmpty = selectedIds
        .where(
          (id) =>
              (_texts[id] ?? '').trim().isNotEmpty &&
              !_confirmedIds.contains(id),
        )
        .toList();
    final skipped = selectedIds.length - nonEmpty.length;
    if (nonEmpty.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('选中的字没有可确认的非空文字'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    setState(() => _confirmingGroup = true);
    try {
      await widget.onBlocksConfirmed(nonEmpty);
      if (!mounted) return;
      setState(() => _confirmedIds.addAll(nonEmpty));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已确认 ${nonEmpty.length} 字并保存'
            '${skipped > 0 ? '；$skipped 个空字/已确认未重复处理' : ''}',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    } finally {
      if (mounted) setState(() => _confirmingGroup = false);
    }
  }

  /// 打开全书版：带着结果（若有）退回编辑器——重载受影响页或执行
  /// 其中的「定位到所在页」请求。
  Future<void> _openBookVersion() async {
    final result = await widget.onOpenBook();
    if (!mounted) return;
    if (result != null) {
      Navigator.of(context).pop(result);
    }
  }

  /// 点单个缩略图：弹出单字修改框（该字自己的候选 + 输入框 +
  /// 特殊字标记开关）。
  Future<void> _editSingle(String blockId) async {
    final block = _blocksById[blockId];
    if (block == null) return;
    final result = await showDialog<({String text, bool marked})>(
      context: context,
      builder: (_) => _SingleCharDialog(
        block: block,
        currentText: _texts[blockId] ?? block.text,
        initialMarked: _markedIds.contains(blockId),
      ),
    );
    if (result == null) return;
    if (result.text.trim().isNotEmpty) {
      _applyText([blockId], result.text.trim());
    }
    if (result.marked != _markedIds.contains(blockId)) {
      _setMarked([blockId], result.marked);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('墨迹归类 · 第 ${widget.pageIndex + 1} 页'),
        actions: [
          IconButton(
            tooltip: '全书墨迹归类：指定页范围/整本书跨页聚类批量校正',
            icon: const Icon(Icons.auto_stories),
            onPressed: _loading ? null : _openBookVersion,
          ),
          IconButton(
            tooltip: '重新归类',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _runCluster,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_mainTextBlocks.isEmpty) {
      return const _HintView(
        icon: Icons.grain,
        text: '本页没有正文字块，先识别或手动补框后再来归类。',
      );
    }
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('正在按墨迹形态聚类本页字块…'),
          ],
        ),
      );
    }
    if (_error != null) {
      return _HintView(
        icon: Icons.error_outline,
        text: '归类失败：$_error',
        action: FilledButton.icon(
          onPressed: _runCluster,
          icon: const Icon(Icons.refresh),
          label: const Text('重试'),
        ),
      );
    }
    final result = _result;
    if (result == null) {
      return const _HintView(
        icon: Icons.category_outlined,
        text: '本页没有聚出相似字组（阈值可能太严格），试试调宽松一些。',
      );
    }
    final groups = result.clusters
        .where((g) => g.blockIds.any(_blockVisible))
        .where((g) => !_onlyPending || _groupNeedsAttention(g.blockIds))
        .toList();
    final singleIds = result.singletons
        .where(_blockVisible)
        .where((id) => !_onlyPending || _blockNeedsAttention(id))
        .toList();
    if (groups.isEmpty && singleIds.isEmpty) {
      if (_onlyMarked) {
        return const _HintView(
          icon: Icons.flag_outlined,
          text:
              '本页没有标记的特殊字。归类时点选/框选存疑的字后用「标记」按钮'
              '打标，等全书识别完成后切回「只看标记」集中校对。',
        );
      }
      final allHidden =
          result.clusters.isNotEmpty &&
          result.clusters.every((g) => !g.blockIds.any(_blockVisible));
      return _HintView(
        icon: Icons.verified_outlined,
        text: _onlyPending || allHidden
            ? '待处理字都已完成：已确认的字默认隐藏，打开「显示已确认」可查看。'
            : '本页没有聚出相似字组（阈值可能太严格），试试调宽松一些。',
      );
    }
    return Column(
      children: [
        _buildToolbar(result, groups.length, singleIds.length),
        Expanded(child: _buildGroupList(groups, singleIds)),
      ],
    );
  }

  Widget _buildToolbar(
    CharClusterResult result,
    int visibleGroups,
    int visibleSingles,
  ) {
    final singlesLabel = _onlyPending
        ? '$visibleSingles/${result.singletons.length}'
        : '${result.singletons.length}';
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
                  '${_mainTextBlocks.length} 字块 → ${result.clusters.length} 组'
                  '（显示 $visibleGroups）· 未归组单字 $singlesLabel'
                  '${_markedIds.isNotEmpty ? ' · 特殊字 ${_markedIds.length}' : ''}',
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
                  onChanged: _loading
                      ? null
                      : (v) => setState(() => _threshold = v),
                  onChangeEnd: _loading ? null : (_) => _runCluster(),
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

  Widget _buildGroupList(
    List<CharClusterGroup> groups,
    List<String> singleIds,
  ) {
    final hasSingles = singleIds.isNotEmpty;
    // 缩放感知层逐卡片包裹：列表项在滚动视图子树内，Ctrl+滚轮在这里
    // 比外层滚动视图先拿到信号（整层包 ListView 外面会轮不到）。
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: groups.length + (hasSingles ? 1 : 0),
      itemBuilder: (context, index) {
        if (index < groups.length) {
          final group = groups[index];
          return CtrlScrollZoomSurface(
            onZoom: _zoomCells,
            child: _ClusterCard(
              key: ValueKey('cluster-${group.blockIds.first}-$index'),
              index: index + 1,
              group: group,
              image: _image,
              blocksById: _blocksById,
              texts: _texts,
              confirmedIds: _confirmedIds,
              markedIds: _markedIds,
              showConfirmed: _showConfirmed,
              hideMarked: _hideMarked,
              onlyMarked: _onlyMarked,
              confirmable: !_confirmingGroup,
              cellSize: kInkCellSize * _cellZoom,
              onApplyText: _applyText,
              onConfirmSelected: _confirmSelected,
              onSetMarked: _setMarked,
              onEditSingle: _editSingle,
              onLocateChar: widget.onLocateChar,
            ),
          );
        }
        return CtrlScrollZoomSurface(
          onZoom: _zoomCells,
          child: _SingletonsCard(
            key: const ValueKey('singletons'),
            blockIds: singleIds,
            image: _image,
            blocksById: _blocksById,
            texts: _texts,
            confirmedIds: _confirmedIds,
            markedIds: _markedIds,
            skippedCount: _result?.skipped.length ?? 0,
            noGroupsAtAll: groups.isEmpty,
            cellSize: kInkCellSize * _cellZoom,
            onEditSingle: _editSingle,
            onLocateChar: widget.onLocateChar,
          ),
        );
      },
    );
  }
}

/// 单个相似组的卡片：字图缩略图 + 点选/框选 + 统一改字 / 单独改字 /
/// 确认所选（选中的非空文字置为已确认并保存，转绿色确认态）与
/// 标记所选（特殊字标记/取消标记）。已确认的字默认从组里隐藏
/// （「显示已确认」开关回显）；标记字受「隐藏标记/只看标记」筛选。
class _ClusterCard extends StatefulWidget {
  final int index;
  final CharClusterGroup group; // 完整分组（含已确认成员）
  final ui.Image? image;
  final Map<String, CharBlock> blocksById;
  final Map<String, String> texts;
  final Set<String> confirmedIds;
  final Set<String> markedIds; // 特殊字标记镜像
  final bool showConfirmed;
  final bool hideMarked;
  final bool onlyMarked;
  final bool confirmable;

  /// 字格边长（Ctrl+滚轮缩放由页面状态折算传入）。
  final double cellSize;
  final void Function(List<String> blockIds, String text) onApplyText;
  final Future<void> Function(List<String> blockIds) onConfirmSelected;
  final void Function(List<String> blockIds, bool marked) onSetMarked;
  final void Function(String blockId) onEditSingle;
  final void Function(String blockId) onLocateChar;

  const _ClusterCard({
    super.key,
    required this.index,
    required this.group,
    required this.image,
    required this.blocksById,
    required this.texts,
    required this.confirmedIds,
    required this.markedIds,
    required this.showConfirmed,
    required this.hideMarked,
    required this.onlyMarked,
    required this.confirmable,
    this.cellSize = kInkCellSize,
    required this.onApplyText,
    required this.onConfirmSelected,
    required this.onSetMarked,
    required this.onEditSingle,
    required this.onLocateChar,
  });

  @override
  State<_ClusterCard> createState() => _ClusterCardState();
}

class _ClusterCardState extends State<_ClusterCard> {
  late final TextEditingController _input;

  /// 选中集合（点选/框选累积）：套用与确认只作用于选中的字。
  final Set<String> _selected = {};

  /// 命中测试用 key：图块容器（点选/框选）与角标/定位按钮（点选路由）。
  late final Map<String, GlobalKey> _cellKeys = {
    for (final id in widget.group.blockIds) id: GlobalKey(),
  };
  late final Map<String, GlobalKey> _editKeys = {
    for (final id in widget.group.blockIds) id: GlobalKey(),
  };
  late final Map<String, GlobalKey> _locateKeys = {
    for (final id in widget.group.blockIds) id: GlobalKey(),
  };

  /// 框选进行中的预览：null=无框选；加选=选中∪命中，减选=选中−命中。
  bool? _bandAdd;
  Set<String> _bandHits = const {};

  @override
  void initState() {
    super.initState();
    _input = TextEditingController(text: _majorityText());
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_ClusterCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 成员被确认后默认隐藏，选区同步剪掉隐藏成员，计数保持准确。
    _selected.retainWhere(_isVisible);
  }

  bool _isConfirmed(String id) =>
      (widget.texts[id] ?? '').isNotEmpty && widget.confirmedIds.contains(id);

  bool _isMarked(String id) => widget.markedIds.contains(id);

  /// 与页面级 _blockVisible 同口径：已确认默认隐藏 + 标记筛选。
  bool _isVisible(String id) {
    if (widget.hideMarked && _isMarked(id)) return false;
    if (widget.onlyMarked && !_isMarked(id)) return false;
    return widget.showConfirmed || !_isConfirmed(id);
  }

  /// 组内可见（参与点选/框选/计数）的成员：已确认的默认隐藏。
  List<String> get _visibleIds =>
      widget.group.blockIds.where(_isVisible).toList();

  bool _isSelected(String id) {
    final base = _selected.contains(id);
    if (_bandAdd == null) return base;
    final inBand = _bandHits.contains(id);
    return _bandAdd! ? base || inBand : base && !inBand;
  }

  // ── 点选 / 框选（由 BandSelectSurface 路由）──

  void _onTapCell(String id) => setState(() {
    if (!_selected.remove(id)) _selected.add(id);
  });

  void _onTapAction(String actionId) {
    if (actionId.startsWith('edit:')) {
      widget.onEditSingle(actionId.substring(5));
    } else if (actionId.startsWith('locate:')) {
      widget.onLocateChar(actionId.substring(7));
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

  void _selectAll() => setState(() => _selected.addAll(_visibleIds));

  void _clearSelection() => setState(() => _selected.removeAll(_visibleIds));

  /// 反选：可见成员里选中的去掉、没选中的全加（不可见成员不参与，
  /// 与全选/取消选择的口径一致）。
  void _invertSelection() => setState(() {
    final previous = _selected.toSet();
    _selected
      ..clear()
      ..addAll(_visibleIds.where((id) => !previous.contains(id)));
  });

  /// 标记所选：选中的字全部已标记 → 取消标记，否则统一打标记。
  void _toggleMarkSelected() {
    final ids = _visibleIds.where(_selected.contains).toList();
    if (ids.isEmpty) return;
    final allMarked = ids.every(_isMarked);
    widget.onSetMarked(ids, !allMarked);
  }

  /// 可见成员的多数文字（预填统一改字输入框）；并列取候选汇总分更高者。
  String _majorityText() {
    final counter = <String, int>{};
    for (final id in _visibleIds) {
      final t = widget.texts[id] ?? '';
      counter[t] = (counter[t] ?? 0) + 1;
    }
    if (counter.isEmpty) return '';
    final entries = counter.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.first.key;
  }

  /// 可见成员候选按字汇总（分数求和），供整组一键套用。
  List<CharCandidate> _mergedCandidates() {
    final scores = <String, double>{};
    for (final id in _visibleIds) {
      final block = widget.blocksById[id];
      if (block == null) continue;
      for (final c in block.candidates) {
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
    final ids = _visibleIds.where(_selected.contains).toList();
    if (ids.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('没有选中的字：点选或框选后再套用'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    widget.onApplyText(ids, text);
  }

  /// 组内多数文字（按可见成员统计，空字不计入）；组头部的文字分布
  /// 提示与缩略图下方的"少数派"高亮都基于它。
  String _groupMajorityText() {
    final counter = <String, int>{};
    for (final id in _visibleIds) {
      final t = widget.texts[id] ?? '';
      if (t.isEmpty) continue;
      counter[t] = (counter[t] ?? 0) + 1;
    }
    if (counter.isEmpty) return '';
    final entries = counter.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.first.key;
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visibleIds;
    if (visible.isEmpty) return const SizedBox.shrink();
    final majority = _groupMajorityText();
    final distribution = <String, int>{};
    for (final id in visible) {
      final t = widget.texts[id] ?? '';
      final key = t.isEmpty ? '（空）' : t;
      distribution[key] = (distribution[key] ?? 0) + 1;
    }
    final distEntries = distribution.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final candidates = _mergedCandidates();
    final selectedIds = visible.where(_selected.contains).toList();
    final confirmableIds = selectedIds
        .where((id) => (widget.texts[id] ?? '').trim().isNotEmpty)
        .where((id) => !widget.confirmedIds.contains(id))
        .toList();
    final hiddenCount = widget.group.size - visible.length;
    final markedCount = widget.group.blockIds.where(_isMarked).length;
    final allConfirmed = widget.group.blockIds.every(
      (id) =>
          (widget.texts[id] ?? '').isEmpty || widget.confirmedIds.contains(id),
    );
    final selectedMarkedAll =
        selectedIds.isNotEmpty && selectedIds.every(_isMarked);

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
                  '组 ${widget.index} · ${visible.length}/${widget.group.size} 字',
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
                    message:
                        '特殊字标记 $markedCount 个（可能裁分有问题或'
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
                  message: '组内平均相似距离（越小越像）',
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
                  onPressed: selectedIds.isEmpty ? null : _clearSelection,
                ),
              ],
            ),
            const SizedBox(height: 8),
            BandSelectSurface(
              cellKeys: {for (final id in visible) id: _cellKeys[id]!},
              actionKeys: {
                for (final id in visible) 'edit:$id': _editKeys[id]!,
                for (final id in visible) 'locate:$id': _locateKeys[id]!,
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
                  for (final id in visible)
                    _CharCell(
                      block: widget.blocksById[id],
                      image: widget.image,
                      text: widget.texts[id] ?? '',
                      selected: _isSelected(id),
                      isMinority:
                          majority.isNotEmpty &&
                          (widget.texts[id] ?? '').isNotEmpty &&
                          (widget.texts[id] ?? '') != majority,
                      isConfirmed: _isConfirmed(id),
                      isMarked: _isMarked(id),
                      routed: true,
                      cellSize: widget.cellSize,
                      cellKey: _cellKeys[id],
                      editKey: _editKeys[id],
                      locateKey: _locateKeys[id],
                    ),
                ],
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
                    onPressed: selectedIds.isEmpty ? null : _toggleMarkSelected,
                    icon: Icon(
                      selectedMarkedAll ? Icons.flag : Icons.flag_outlined,
                      size: 16,
                    ),
                    label: Text(
                      selectedMarkedAll
                          ? '取消标记（${selectedIds.length}）'
                          : '标记（${selectedIds.length}）',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: selectedIds.isEmpty
                      ? null
                      : () => _applyToSelected(),
                  icon: const Icon(Icons.done_all, size: 16),
                  label: Text('套用（${selectedIds.length}）'),
                ),
                const SizedBox(width: 8),
                _buildConfirmButton(allConfirmed, confirmableIds),
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
  Widget _buildConfirmButton(bool allConfirmed, List<String> confirmableIds) {
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
        onPressed: widget.confirmable && confirmableIds.isNotEmpty
            ? () => widget.onConfirmSelected(confirmableIds)
            : null,
        icon: const Icon(Icons.task_alt, size: 16),
        label: Text(
          confirmableIds.isEmpty ? '确认所选' : '确认所选（${confirmableIds.length}）',
        ),
      ),
    );
  }
}

/// 未归组单字卡片：本页没有相似墨迹的字也展示出来，点缩略图单独改字
/// （修改框里可顺手打/撤特殊字标记，标记角标随格显示）。
class _SingletonsCard extends StatelessWidget {
  final List<String> blockIds;
  final ui.Image? image;
  final Map<String, CharBlock> blocksById;
  final Map<String, String> texts;
  final Set<String> confirmedIds;
  final Set<String> markedIds;
  final int skippedCount;
  final bool noGroupsAtAll;

  /// 字格边长（Ctrl+滚轮缩放由页面状态折算传入）。
  final double cellSize;
  final void Function(String blockId) onEditSingle;
  final void Function(String blockId) onLocateChar;

  const _SingletonsCard({
    super.key,
    required this.blockIds,
    required this.image,
    required this.blocksById,
    required this.texts,
    required this.confirmedIds,
    required this.markedIds,
    required this.skippedCount,
    required this.noGroupsAtAll,
    this.cellSize = kInkCellSize,
    required this.onEditSingle,
    required this.onLocateChar,
  });

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
                  '${blockIds.length} 字',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              noGroupsAtAll
                  ? '本页没有聚出相似字组（阈值可能太严格），以下单字都没有墨迹相近的同伴，试试调宽松一些。'
                  : '这些字在本页没有墨迹相近的同伴，点击缩略图可单独修改。'
                        '${skippedCount > 0 ? '另有 $skippedCount 个字块无法提取墨迹（空框/无墨迹），未参与归类。' : ''}',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final id in blockIds)
                  _CharCell(
                    block: blocksById[id],
                    image: image,
                    text: texts[id] ?? '',
                    selected: false,
                    isMinority: false,
                    isConfirmed:
                        (texts[id] ?? '').isNotEmpty &&
                        confirmedIds.contains(id),
                    isMarked: markedIds.contains(id),
                    routed: false,
                    cellSize: cellSize,
                    onTap: () => onEditSingle(id),
                    onLocate: () => onLocateChar(id),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 组内单个字的缩略格：整页图按字框坐标裁切 + 当前文字。
/// 组内格子（routed=true）：点选、角标改字、定位的点击都由
/// BandSelectSurface 路由（InkWell 的 onTap 不会触发，仅保留悬停
/// 光标）；未归组单字（routed=false）：点图直接弹修改框。
/// isConfirmed：已确认文字转绿（与编辑器行内确认态同口径）；
/// isMarked：特殊字标记 → 左上角深橙小旗角标。
class _CharCell extends StatelessWidget {
  final CharBlock? block;
  final ui.Image? image;
  final String text;
  final bool selected; // 点选/框选选中 → 蓝色加粗边框
  final bool isMinority; // 组内与多数文字不同 → 橙色加粗高亮
  final bool isConfirmed; // 已确认 → 绿色加粗
  final bool isMarked; // 特殊字标记 → 左上角小旗角标
  final bool routed; // true=点击由 BandSelectSurface 路由
  final Key? cellKey; // 图块容器 key（surface 点选/框选命中目标）
  final Key? editKey; // 右上角改字按钮 key（surface 路由目标）
  final Key? locateKey; // 下方定位按钮 key（surface 路由目标）
  final VoidCallback? onTap; // routed=false 时的点击回调
  final VoidCallback? onLocate; // routed=false 时的定位回调

  /// 字格边长（Ctrl+滚轮缩放）。
  final double cellSize;

  const _CharCell({
    required this.block,
    required this.image,
    required this.text,
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
    this.cellSize = kInkCellSize,
  });

  @override
  Widget build(BuildContext context) {
    final cell = cellSize;
    final block = this.block;
    final showEdit = routed && editKey != null;
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
                    child: block == null || image == null
                        ? Container(color: Colors.grey.shade100)
                        : CustomPaint(
                            size: Size(cell, cell),
                            painter: _CharCropPainter(
                              image: image!,
                              srcRect: Rect.fromLTWH(
                                block.x.toDouble(),
                                block.y.toDouble(),
                                block.w.toDouble(),
                                block.h.toDouble(),
                              ),
                            ),
                          ),
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
                  message:
                      '特殊字标记：可能裁分有问题或暂无法识别，'
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
          child: Tooltip(
            message: '在单字识别页中定位',
            child: SizedBox(
              key: locateKey,
              child: InkWell(
                onTap: routed ? null : onLocate,
                borderRadius: BorderRadius.circular(4),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Icon(
                      Icons.my_location,
                      size: 14,
                      color: (routed || onLocate != null)
                          ? Colors.blueGrey.shade400
                          : Colors.blueGrey.shade100,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
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
    // 整页大图取样到 64px 小图，low 档采样质量足够且开销最小
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
              Text(
                pinyin,
                style: TextStyle(fontSize: 9, color: Colors.blue.shade600),
              ),
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

/// 单字修改对话框：输入框 + 该字块自己的候选（点候选直接采纳）+
/// 特殊字标记开关（打开即标记，确定时随文字一起返回）。
class _SingleCharDialog extends StatefulWidget {
  final CharBlock block;
  final String currentText;

  /// 打开对话框时的特殊字标记状态（页面的镜像集合判定）。
  final bool initialMarked;

  const _SingleCharDialog({
    required this.block,
    required this.currentText,
    this.initialMarked = false,
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
    // 打开时全选现有文字：直接输入即可整体替换，不用先手动删除。
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

  void _commit(String text) {
    Navigator.of(context).pop((text: text, marked: _marked));
  }

  @override
  Widget build(BuildContext context) {
    // 候选 = 字块已有候选（按分数） + 当前文字兜底
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
              // Windows 上 maxLength 默认立刻截断输入法的拼音组合串，
              // 打两个字母就被打断；改为选字完成后再截断到上限。
              maxLengthEnforcement:
                  MaxLengthEnforcement.truncateAfterCompositionEnds,
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
              message:
                  '标记后该字在归类里带小旗角标，可「隐藏标记」先跳过，'
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
              const Text(
                '候选',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
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
