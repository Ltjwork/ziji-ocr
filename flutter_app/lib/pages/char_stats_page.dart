import 'dart:async';
import 'package:flutter/material.dart';
import 'package:lpinyin/lpinyin.dart';
import '../services/char_stats.dart';

/// 文字汇总：统计所有校对确认过的页面里每个字出现过的次数。
///
/// 数据来自全局字频账本 char_stats（书籍目录的兄弟目录）——删除整本
/// 书不影响统计（校对成果历史累计保留），删除单页 / 页面重新识别 /
/// 全书重新识别则撤销对应页面的账目。打开本页时全量聚合账本，可按
/// 字或拼音搜索、按次数/拼音/Unicode 排序。
class CharStatsPage extends StatefulWidget {
  const CharStatsPage({
    super.key,
    required this.dataRoot,
    required this.bookNames,
  });

  /// 书籍数据根目录（账本在其下的 char_stats/）。
  final String dataRoot;

  /// projectId -> 书名（现存的书籍；账本中出现但不在其中的 id 为已
  /// 删除书籍，汇总卡按「已删除」计数展示）。
  final Map<String, String> bookNames;

  @override
  State<CharStatsPage> createState() => _CharStatsPageState();
}

enum _CharSortMode { count, pinyin, unicode }

class _CharStatsPageState extends State<CharStatsPage> {
  CharStatsSummary? _summary;
  Object? _error;
  bool _loading = true;

  String _query = '';
  _CharSortMode _sortMode = _CharSortMode.count;

  /// 网格/列表双视图，默认网格（字频表以扫读为主，网格密度高）。
  bool _gridMode = true;

  /// 单字无声调拼音缓存（搜索/排序用，懒加载）。
  final Map<String, String> _pinyinCache = {};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final summary = await CharStatsService.summary(widget.dataRoot);
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  String _pinyinOf(String ch) => _pinyinCache[ch] ??= PinyinHelper.getPinyinE(
    ch,
    defPinyin: '',
    format: PinyinFormat.WITHOUT_TONE,
  ).trim().toLowerCase();

  List<MapEntry<String, int>> get _visibleEntries {
    final summary = _summary;
    if (summary == null) return const [];
    var entries = summary.charCounts.entries.toList();
    final raw = _query.trim();
    if (raw.isNotEmpty) {
      final q = raw.toLowerCase();
      entries = entries
          .where((e) => e.key.contains(raw) || _pinyinOf(e.key).contains(q))
          .toList();
    }
    switch (_sortMode) {
      case _CharSortMode.count:
        entries.sort((a, b) {
          final byCount = b.value.compareTo(a.value);
          return byCount != 0 ? byCount : a.key.compareTo(b.key);
        });
      case _CharSortMode.pinyin:
        entries.sort((a, b) {
          final pa = _pinyinOf(a.key);
          final pb = _pinyinOf(b.key);
          if (pa.isEmpty != pb.isEmpty) return pa.isEmpty ? 1 : -1;
          final byPy = pa.compareTo(pb);
          return byPy != 0 ? byPy : a.key.compareTo(b.key);
        });
      case _CharSortMode.unicode:
        entries.sort((a, b) => a.key.compareTo(b.key));
    }
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('文字汇总'),
        actions: [
          IconButton(
            icon: Icon(
              _gridMode ? Icons.view_list_outlined : Icons.grid_view_outlined,
            ),
            tooltip: _gridMode ? '切换为列表视图' : '切换为网格视图',
            onPressed: () => setState(() => _gridMode = !_gridMode),
          ),
          _buildSortMenu(),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '重新汇总账本',
            onPressed: _loading ? null : () => unawaited(_load()),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildSortMenu() {
    const labels = {
      _CharSortMode.count: '次数降序',
      _CharSortMode.pinyin: '拼音升序',
      _CharSortMode.unicode: 'Unicode 升序',
    };
    return PopupMenuButton<_CharSortMode>(
      tooltip: '排序方式',
      icon: const Icon(Icons.sort),
      initialValue: _sortMode,
      onSelected: (mode) => setState(() => _sortMode = mode),
      itemBuilder: (_) => [
        for (final mode in _CharSortMode.values)
          PopupMenuItem(
            value: mode,
            child: Row(
              children: [
                if (mode == _sortMode)
                  const Icon(Icons.check, size: 16)
                else
                  const SizedBox(width: 16),
                const SizedBox(width: 8),
                Text(labels[mode]!),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('汇总失败：$_error', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: () => unawaited(_load()), child: const Text('重试')),
          ],
        ),
      );
    }
    final summary = _summary;
    if (summary == null || summary.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.text_fields, size: 40, color: Colors.grey),
            SizedBox(height: 12),
            Text('还没有已确认的页面', style: TextStyle(color: Colors.grey)),
            SizedBox(height: 6),
            Text(
              '在编辑器里「确认并保存」过的页面，其中的文字会计入这里',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      );
    }
    final entries = _visibleEntries;
    return Column(
      children: [
        _buildMetricsCard(summary),
        _buildSearchField(),
        Expanded(
          child: _gridMode ? _buildCharGrid(entries) : _buildCharList(entries),
        ),
      ],
    );
  }

  Widget _buildMetricsCard(CharStatsSummary summary) {
    final deleted = summary.bookIds
        .where((id) => !widget.bookNames.containsKey(id))
        .length;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _metric('收录书籍', '${summary.bookIds.length}'),
                _metric(
                  '已确认页',
                  '${summary.pageCount}',
                ),
                _metric('字种', '${summary.charCounts.length}'),
                _metric('总字次', '${summary.totalChars}'),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              deleted > 0
                  ? '统计范围：全部「确认并保存」过的页面，其中 $deleted 本已删除（校对成果保留计入）'
                  : '统计范围：全部「确认并保存」过的页面；删除整本书不影响统计，'
                        '删除单页 / 重新识别会移出该页文字',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metric(String label, String value) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: TextField(
        onChanged: (v) => setState(() => _query = v),
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: const Icon(Icons.search, size: 20),
          hintText: '按字或拼音筛选（如「大」或「da」）',
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: '清除筛选',
                  onPressed: () => setState(() => _query = ''),
                ),
        ),
      ),
    );
  }

  Widget _buildEmptyEntries() {
    return Center(
      child: Text(
        _query.isEmpty ? '暂无数据' : '没有匹配「$_query」的字',
        style: const TextStyle(color: Colors.grey),
      ),
    );
  }

  /// 网格视图（默认）：一格一字——字大居中、次数小字在下，悬停提示
  /// 拼音与完整次数。与列表一样不包 Scrollbar（桌面端默认 ScrollBehavior
  /// 自动加滚动条）。
  Widget _buildCharGrid(List<MapEntry<String, int>> entries) {
    if (entries.isEmpty) return _buildEmptyEntries();
    final scheme = Theme.of(context).colorScheme;
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: entries.length,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 92,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
        childAspectRatio: 1,
      ),
      itemBuilder: (_, i) {
        final ch = entries[i].key;
        final count = entries[i].value;
        final py = _pinyinOf(ch);
        return Tooltip(
          message: py.isEmpty ? '$count 次' : '$py · $count 次',
          waitDuration: const Duration(milliseconds: 400),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  ch,
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCharList(List<MapEntry<String, int>> entries) {
    if (entries.isEmpty) {
      return _buildEmptyEntries();
    }
    final maxCount = _summary?.charCounts.values.fold(
          0,
          (max, n) => n > max ? n : max,
        ) ?? 0;
    // 不包 Scrollbar：Windows 桌面端默认 ScrollBehavior 会给滚动列表自动
    // 加滚动条；显式包裹而不传 controller 时，Scrollbar 会去拿没有任何
    // ScrollPosition 挂载的 PrimaryScrollController（桌面端 ListView 不
    // 自动挂载），首帧绘制即抛 "has no ScrollPosition attached" 退出。
    return ListView.separated(
      padding: const EdgeInsets.only(top: 4, bottom: 16),
      itemCount: entries.length,
      separatorBuilder: (_, __) => const SizedBox(height: 2),
      itemBuilder: (_, i) => _buildCharRow(
        entries[i].key,
        entries[i].value,
        maxCount,
      ),
    );
  }

  Widget _buildCharRow(String ch, int count, int maxCount) {
    final scheme = Theme.of(context).colorScheme;
    final py = _pinyinOf(ch);
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          ch,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
        ),
      ),
      title: Row(
        children: [
          SizedBox(
            width: 56,
            child: Text(
              py.isEmpty ? '—' : py,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: maxCount <= 0 ? 0 : count / maxCount,
                minHeight: 5,
              ),
            ),
          ),
        ],
      ),
      trailing: SizedBox(
        width: 64,
        child: Text(
          '$count 次',
          textAlign: TextAlign.right,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}
