import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/python_service.dart';
import '../widgets/line_chart.dart';

/// 训练曲线弹窗：一次训练 run 的逐 epoch 指标/损失折线 + 中间检查点清单。
///
/// 数据来自 GET /train/curve（runDir 支持进行中任务与注册表历史 run），
/// 训练进行中可自动轮询看曲线实时生长。检查点「启用」回调由宿主页提供：
/// YOLO 五层走 /models/activate（收任意 .pt 路径），墨迹比对走
/// /verify/train/activate（按 run 目录）。
class TrainingCurveDialog extends StatefulWidget {
  /// 可切换的训练 run（新→旧；第一个默认选中，通常是最近任务）。
  final List<({String dir, String label})> runs;

  final String title;

  /// 有任务训练中：弹窗打开期间每几秒拉一次曲线，实时看指标生长。
  final bool autoRefresh;

  /// 当前启用的模型路径（同路径的检查点行标记"当前启用"）。
  final String? activePath;

  /// 启用某个模型文件（宿主页决定路由到哪条激活接口）。
  final Future<void> Function(String modelPath) onActivate;

  /// 删除一个中间轮检查点（epoch{N}.pt，释放磁盘；宿主页按层路由到
  /// /models/delete_checkpoint）。null = 不显示删除入口（如墨迹比对，
  /// 没有中间轮检查点）。后端会拒绝 best/last 与当前启用来源。
  final Future<void> Function(String path)? onDeleteCheckpoint;

  const TrainingCurveDialog({
    super.key,
    required this.runs,
    required this.title,
    required this.onActivate,
    this.onDeleteCheckpoint,
    this.autoRefresh = false,
    this.activePath,
  });

  @override
  State<TrainingCurveDialog> createState() => _TrainingCurveDialogState();
}

class _TrainingCurveDialogState extends State<TrainingCurveDialog>
    with SingleTickerProviderStateMixin {
  static const _metricGroups = <String, List<(String, String)>>{
    // kind → [(results.csv 列名, 展示名)]，列不存在时自动略去
    'detect': [
      ('metrics/mAP50-95(B)', 'mAP50-95'),
      ('metrics/mAP50(B)', 'mAP50'),
      ('metrics/precision(B)', '精确率'),
      ('metrics/recall(B)', '召回'),
    ],
    'classify': [
      ('metrics/accuracy_top1', 'top1 准确率'),
      ('metrics/accuracy_top5', 'top5 准确率'),
    ],
    'siamese': [('val_auc', 'val AUC')],
    'unknown': [],
  };
  static const _trainLossGroups = <String, List<(String, String)>>{
    'detect': [
      ('train/box_loss', 'box'),
      ('train/cls_loss', 'cls'),
      ('train/dfl_loss', 'dfl'),
    ],
    'classify': [('train/loss', 'loss')],
    'siamese': [('train_loss', 'train')],
    'unknown': [],
  };
  static const _valLossGroups = <String, List<(String, String)>>{
    'detect': [
      ('val/box_loss', 'box'),
      ('val/cls_loss', 'cls'),
      ('val/dfl_loss', 'dfl'),
    ],
    'classify': [('val/loss', 'loss')],
    'siamese': [('val_loss', 'val')],
    'unknown': [],
  };

  /// 各 kind 的主指标列（过拟合提示与检查点行指标都用它）。
  static const _primaryMetric = <String, String>{
    'detect': 'metrics/mAP50-95(B)',
    'classify': 'metrics/accuracy_top1',
    'siamese': 'val_auc',
  };

  int _runIndex = 0;
  Map<String, dynamic>? _data;
  bool _loading = false;
  String? _error;
  int _tab = 0;
  final Set<String> _activating = {};
  final Set<String> _deleting = {};
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    if (widget.autoRefresh) {
      _timer = Timer.periodic(const Duration(seconds: 4), (_) => _load(silent: true));
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final data = await PythonService.trainCurve(widget.runs[_runIndex].dir);
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = _visibleGroups();
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.show_chart, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text('训练曲线 · ${widget.title}',
              style: const TextStyle(fontSize: 16))),
          if (widget.runs.length > 1)
            DropdownButton<int>(
              value: _runIndex,
              underline: const SizedBox.shrink(),
              items: [
                for (var i = 0; i < widget.runs.length; i++)
                  DropdownMenuItem(value: i, child: Text(widget.runs[i].label,
                      style: const TextStyle(fontSize: 12))),
              ],
              onChanged: (i) {
                if (i == null || i == _runIndex) return;
                setState(() {
                  _runIndex = i;
                  _tab = 0;
                  _data = null;
                });
                unawaited(_load());
              },
            ),
          IconButton(
            icon: _loading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh, size: 20),
            tooltip: '刷新',
            onPressed: _loading ? null : () => unawaited(_load()),
          ),
        ],
      ),
      content: SizedBox(
        width: 860,
        height: 620,
        child: _buildBody(groups),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
      ],
    );
  }

  Widget _buildBody(List<({String label, List<(String, String)> cols})> groups) {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('读取曲线失败：$_error',
                style: TextStyle(fontSize: 12, color: Colors.red.shade700)),
            const SizedBox(height: 8),
            TextButton(onPressed: () => unawaited(_load()), child: const Text('重试')),
          ],
        ),
      );
    }
    if (_loading && _data == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_data == null) return const SizedBox.shrink();
    final rows = _rows();
    if (rows.isEmpty) {
      return const Center(
        child: Text('还没有曲线数据（训练尚未写出第一个 epoch）',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
      );
    }
    final kind = (_data!['kind'] as String?) ?? 'unknown';
    final group = groups.isEmpty ? null : groups[_tab.clamp(0, groups.length - 1)];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (groups.length > 1)
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            dividerColor: Colors.transparent,
            labelStyle: const TextStyle(fontSize: 12.5),
            tabs: [for (final g in groups) Tab(text: g.label)],
            controller: _tabController(groups.length),
          ),
        if (groups.length > 1) const SizedBox(height: 8),
        if (group != null)
          TrainingLineChart(
            height: 230,
            series: [
              for (var i = 0; i < group.cols.length; i++)
                ChartSeries(
                  name: group.cols[i].$2,
                  color: TrainingLineChart.paletteColor(i),
                  points: [
                    for (final row in rows)
                      (
                        ((row['epoch'] as num?) ?? 0).toDouble(),
                        (row[group.cols[i].$1] as num?)?.toDouble(),
                      ),
                  ],
                ),
            ],
          ),
        const SizedBox(height: 6),
        _buildHint(rows, kind),
        const Divider(height: 20),
        _buildCheckpointHeader(kind),
        Expanded(child: _buildCheckpoints(rows, kind)),
      ],
    );
  }

  TabController? _tabController(int length) {
    _tabCtrl ??= TabController(length: length, vsync: this)
      ..addListener(() {
        if (!_tabCtrl!.indexIsChanging) setState(() => _tab = _tabCtrl!.index);
      });
    if (_tabCtrl!.length != length) {
      _tabCtrl!.dispose();
      _tabCtrl = TabController(length: length, vsync: this)
        ..addListener(() {
          if (!_tabCtrl!.indexIsChanging) setState(() => _tab = _tabCtrl!.index);
        });
      _tab = 0;
    }
    return _tabCtrl;
  }

  TabController? _tabCtrl;

  @override
  void didUpdateWidget(covariant TrainingCurveDialog old) {
    super.didUpdateWidget(old);
    // run 切换后分组数可能变化，让下次 build 重建 controller 并回到首个分组
    _tabCtrl?.dispose();
    _tabCtrl = null;
    _tab = 0;
  }

  List<Map<String, dynamic>> _rows() {
    final raw = (_data?['rows'] as List?) ?? const [];
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  /// 过滤掉当前 run 的 CSV 里不存在的列后的分组列表。
  List<({String label, List<(String, String)> cols})> _visibleGroups() {
    final kind = (_data?['kind'] as String?) ?? 'unknown';
    final cols = ((_data?['columns'] as List?) ?? const [])
        .map((e) => e.toString())
        .toSet();
    List<({String label, List<(String, String)> cols})> groups = [];
    for (final (label, defs) in [
      ('指标', _metricGroups[kind] ?? const []),
      ('训练损失', _trainLossGroups[kind] ?? const []),
      ('验证损失', _valLossGroups[kind] ?? const []),
    ]) {
      final present = defs.where((d) => cols.contains(d.$1)).toList();
      if (present.isEmpty) continue;
      groups.add((label: label, cols: present));
    }
    // 未知格式：把所有数值列（除 epoch/time/lr）摊进一个组
    if (groups.isEmpty && cols.isNotEmpty) {
      final fallback = cols
          .where((c) =>
              c != 'epoch' && c != 'time' && !c.startsWith('lr/'))
          .map((c) => (c, c))
          .toList();
      if (fallback.isNotEmpty) groups.add((label: '数值列', cols: fallback));
    }
    return groups;
  }

  /// 过拟合/收敛提示：主指标峰值轮 vs 最后一轮。
  Widget _buildHint(List<Map<String, dynamic>> rows, String kind) {
    final metric = _primaryMetric[kind];
    if (metric == null || rows.isEmpty) return const SizedBox.shrink();
    final points = <(int, double)>[
      for (final row in rows)
        if (row[metric] is num)
          (
            ((row['epoch'] as num?) ?? 0).round(),
            (row[metric] as num).toDouble(),
          ),
    ];
    if (points.length < 2) return const SizedBox.shrink();
    var best = points.first;
    for (final p in points) {
      if (p.$2 > best.$2) best = p;
    }
    final last = points.last;
    final style = TextStyle(fontSize: 11);
    if (last.$1 - best.$1 >= 8 && best.$2 > 0 &&
        (best.$2 - last.$2) / best.$2 > 0.03) {
      return Text(
        '疑似过拟合：${_metricLabel(metric)} 在第 ${best.$1} 轮达峰 ${best.$2.toStringAsFixed(4)}，'
        '之后 ${last.$1 - best.$1} 轮降到 ${last.$2.toStringAsFixed(4)}。'
        '可在下方检查点里选峰值附近的一版启用。',
        style: style.copyWith(color: Colors.orange.shade800),
      );
    }
    if (last.$1 - best.$1 >= 8) {
      return Text(
        '已收敛：${_metricLabel(metric)} 峰值出现在第 ${best.$1} 轮'
        '（${best.$2.toStringAsFixed(4)}），其后 ${last.$1 - best.$1} 轮无提升，'
        '继续加轮数收益有限。',
        style: style.copyWith(color: Colors.grey.shade600),
      );
    }
    return Text(
      '指标仍在提升（最新第 ${last.$1} 轮 ${last.$2.toStringAsFixed(4)}）。',
      style: style.copyWith(color: Colors.green.shade700),
    );
  }

  static String _metricLabel(String col) {
    for (final defs in _metricGroups.values) {
      for (final (c, name) in defs) {
        if (c == col) return name;
      }
    }
    return col;
  }

  Widget _buildCheckpointHeader(String kind) {
    final n = ((_data?['checkpoints'] as List?) ?? const []).length;
    return Row(
      children: [
        Text('中间检查点（$n）',
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            n == 0
                ? (kind == 'unknown'
                    ? '该 run 没有检查点文件'
                    : widget.autoRefresh
                        ? '训练中：检查点会按保存周期出现在这里（本次训练未开「中间存档」则始终为空）'
                        : '本次训练未保存中间检查点（训练前把「中间存档」设为每 N 轮即可）')
                : '按曲线挑一处「启用」——立即作为该层模型生效',
            style: const TextStyle(fontSize: 10.5, color: Colors.grey),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildCheckpoints(List<Map<String, dynamic>> rows, String kind) {
    final checkpoints =
        ((_data?['checkpoints'] as List?) ?? const []).toList();
    if (checkpoints.isEmpty) {
      return const SizedBox.shrink();
    }
    final byEpoch = <int, Map<String, dynamic>>{
      for (final row in rows)
        if (row['epoch'] is num) ((row['epoch'] as num).round()): row,
    };
    final metric = _primaryMetric[kind];
    return ListView.separated(
      itemCount: checkpoints.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final c = Map<String, dynamic>.from(checkpoints[i] as Map);
        final name = c['name']?.toString() ?? '';
        final epoch = (c['epoch'] as num?)?.toInt();
        final path = c['path']?.toString() ?? '';
        final isActive = widget.activePath != null &&
            _samePath(widget.activePath!, path);
        final label = epoch != null
            ? '第 $epoch 轮'
            : (name == 'best.pt' ? 'best（验证最优）' : 'last（最后一轮）');
        final details = <String>[];
        final row = epoch != null ? byEpoch[epoch] : null;
        if (row != null && metric != null && row[metric] is num) {
          details.add('${_metricLabel(metric)}=${(row[metric] as num).toStringAsFixed(4)}');
        }
        final sizeMb = ((c['size'] as num?)?.toDouble() ?? 0) / 1024 / 1024;
        if (sizeMb > 0) details.add('${sizeMb.toStringAsFixed(1)} MB');
        return ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          leading: Icon(
            epoch != null ? Icons.history : Icons.star,
            size: 17,
            color: epoch != null ? Colors.blueGrey : Colors.amber.shade700,
          ),
          title: Text(
            isActive ? '$label · 当前启用' : label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isActive ? Colors.green.shade700 : null,
            ),
          ),
          subtitle: details.isEmpty
              ? null
              : Text(details.join(' · '),
                  style: const TextStyle(fontSize: 10.5, color: Colors.grey)),
          trailing: _activating.contains(path) || _deleting.contains(path)
              ? const SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Row(mainAxisSize: MainAxisSize.min, children: [
                  if (widget.onDeleteCheckpoint != null)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: epoch != null
                          ? '删除此轮检查点，释放磁盘'
                          : '删除 $name（当前启用中的版本不可删）',
                      icon: Icon(Icons.delete_outline,
                          size: 17, color: Colors.red.shade300),
                      onPressed: () =>
                          unawaited(_deleteCheckpoint(path, label, sizeMb)),
                    ),
                  TextButton(
                    onPressed:
                        isActive ? null : () => unawaited(_activate(path)),
                    child: const Text('启用', style: TextStyle(fontSize: 12)),
                  ),
                ]),
        );
      },
    );
  }

  /// 删除中间轮检查点：确认框（体积提示）→ 宿主回调 → 刷新检查点清单。
  Future<void> _deleteCheckpoint(String path, String label, double sizeMb) async {
    final onDelete = widget.onDeleteCheckpoint;
    if (onDelete == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除模型文件'),
        content: Text(
            '$label（约 ${sizeMb.toStringAsFixed(0)} MB）删除后不可恢复。\n'
            '当前启用的模型是独立副本，不受影响（启用中的版本不可删）。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Colors.red.shade400),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _deleting.add(path));
    try {
      await onDelete(path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已删除：$label')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _deleting.remove(path));
      await _load(silent: true);
    }
  }

  Future<void> _activate(String path) async {
    setState(() => _activating.add(path));
    try {
      await widget.onActivate(path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已启用：${path.split(Platform.pathSeparator).last}')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('启用失败：$e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _activating.remove(path));
    }
  }

  static bool _samePath(String a, String b) {
    String norm(String p) =>
        p.replaceAll('/', Platform.pathSeparator).replaceAll('\\', Platform.pathSeparator).toUpperCase();
    return norm(a) == norm(b);
  }
}
