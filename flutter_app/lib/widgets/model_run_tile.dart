import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// 模型管理页的可展开 run 行：收起 = run 概要 + 训练曲线/删整个 run；
/// 展开 = 该 run 的全部检查点（best / last / 第 N 轮，带主指标与体积），
/// 每个检查点可直接「启用」为全局模型、「本项目使用」（项目模式）、
/// 中间轮可「删除」释放磁盘。检查点数据来自 /models 的
/// run.checkpoints（list_models 一次带回，无需再拉 /train/curve）。
class ModelRunTile extends StatefulWidget {
  final Map<String, dynamic> run;
  final String metricLabel; // 如 mAP50-95 / top1

  /// 当前全局启用来源（注册表 active_source，.pt 绝对路径）。
  final String? activeSource;

  /// 项目模式下该层的覆写路径（null=跟随全局；''=强制基线）。
  final bool projectMode;
  final String? projectOverride;

  final Future<void> Function(String path) onActivate;
  final Future<void> Function(String path) onProjectUse;
  final Future<void> Function(String path) onDeleteCheckpoint;
  final VoidCallback onShowCurve;
  final Future<void> Function() onDeleteRun;

  const ModelRunTile({
    super.key,
    required this.run,
    required this.metricLabel,
    required this.activeSource,
    required this.projectMode,
    required this.projectOverride,
    required this.onActivate,
    required this.onProjectUse,
    required this.onDeleteCheckpoint,
    required this.onShowCurve,
    required this.onDeleteRun,
  });

  /// 目录/路径归一化（统一分隔符 + 小写）作比较键。
  static String normPath(String path) =>
      p.normalize(path).replaceAll('/', '\\').toLowerCase();

  @override
  State<ModelRunTile> createState() => _ModelRunTileState();
}

class _ModelRunTileState extends State<ModelRunTile> {
  bool _expanded = false;
  final Set<String> _busy = {}; // 检查点路径操作中

  @override
  void initState() {
    super.initState();
    // 当前启用的 run 默认展开——打开页面即见正在用的轮数。
    final src = widget.activeSource;
    final dir = widget.run['run_dir']?.toString();
    _expanded = src != null &&
        dir != null &&
        ModelRunTile.normPath(src).startsWith(
            '${ModelRunTile.normPath(dir)}\\');
  }

  Future<void> _guarded(String path, Future<void> Function() op) async {
    setState(() => _busy.add(path));
    try {
      await op();
    } finally {
      if (mounted) setState(() => _busy.remove(path));
    }
  }

  Widget _checkpointRow(Map<String, dynamic> c) {
    final path = c['path']?.toString() ?? '';
    final name = c['name']?.toString() ?? '';
    final epoch = (c['epoch'] as num?)?.toInt();
    final metric = c['metric'] as num?;
    final sizeMb = ((c['size'] as num?) ?? 0) / 1024 / 1024;
    final isActive = widget.activeSource != null &&
        ModelRunTile.normPath(widget.activeSource!) ==
            ModelRunTile.normPath(path);
    final isOverride = widget.projectMode &&
        widget.projectOverride != null &&
        widget.projectOverride!.isNotEmpty &&
        ModelRunTile.normPath(widget.projectOverride!) ==
            ModelRunTile.normPath(path);

    final label = epoch != null
        ? '第 $epoch 轮'
        : (name == 'best.pt' ? 'best（验证最优）' : 'last（最后一轮）');
    final details = <String>[
      if (metric != null)
        '${widget.metricLabel} ${metric.toStringAsFixed(4)}',
      if (sizeMb > 0) '${sizeMb.toStringAsFixed(0)} MB',
    ].join(' · ');

    final busy = _busy.contains(path);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          const SizedBox(width: 14),
          Icon(
            epoch != null ? Icons.history : Icons.star,
            size: 14,
            color: epoch != null ? Colors.blueGrey : Colors.amber.shade700,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isActive ? '$label · 当前启用' : label,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: isActive ? Colors.green.shade700 : null,
                  ),
                ),
                if (details.isNotEmpty)
                  Text(details,
                      style: TextStyle(
                          fontSize: 10, color: Colors.grey.shade600)),
              ],
            ),
          ),
          if (busy)
            const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2))
          else ...[
            if (widget.projectMode && !isActive)
              TextButton(
                onPressed: isOverride
                    ? null
                    : () => unawaited(_guarded(
                        path, () => widget.onProjectUse(path))),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  foregroundColor: isOverride
                      ? Colors.green.shade700
                      : Colors.blue.shade700,
                ),
                child: Text(isOverride ? '本项目使用中' : '本项目使用',
                    style: const TextStyle(fontSize: 11)),
              ),
            TextButton(
              onPressed: isActive
                  ? null
                  : () =>
                      unawaited(_guarded(path, () => widget.onActivate(path))),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                foregroundColor:
                    isActive ? Colors.green.shade700 : null,
              ),
              child: Text(isActive ? '使用中' : '启用',
                  style: const TextStyle(fontSize: 11)),
            ),
            // 每个版本都可单独删除（唯一硬保护=当前启用来源，后端拒绝）
            IconButton(
              icon: Icon(Icons.delete_outline,
                  size: 15, color: Colors.red.shade300),
              tooltip: epoch != null
                  ? '删除此轮检查点，释放磁盘'
                  : (name == 'best.pt'
                      ? '删除 best（该 run 将失去 best 标记，'
                          '剩余轮数与训练曲线保留）'
                      : '删除 last'),
              visualDensity: VisualDensity.compact,
              onPressed: () => unawaited(
                  _guarded(path, () => widget.onDeleteCheckpoint(path))),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final run = widget.run;
    final runName = p
        .basename(run['run_dir']?.toString() ?? '')
        .replaceFirst(RegExp(r'^run_'), '');
    final mAP = run['metrics'] is Map
        ? (run['metrics'] as Map)['metrics/mAP50(B)']
        : null;
    final checkpoints = ((run['checkpoints'] as List?) ?? const [])
        .map((c) => Map<String, dynamic>.from(c as Map))
        .toList();
    final epochCount =
        checkpoints.where((c) => c['epoch'] != null).length;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      _expanded
                          ? Icons.expand_less
                          : Icons.expand_more,
                      size: 18,
                      color: Colors.blueGrey,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '$runName · ${run['epochs'] ?? '?'} 轮'
                        '${mAP is num ? ' · mAP50 ${mAP.toStringAsFixed(2)}' : ''}'
                        '${epochCount > 0 ? ' · $epochCount 个中间轮' : ''}',
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w500),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.show_chart, size: 15),
                      tooltip: '训练曲线',
                      visualDensity: VisualDensity.compact,
                      onPressed: widget.onShowCurve,
                    ),
                    IconButton(
                      icon: Icon(Icons.delete_outline,
                          size: 15, color: Colors.red.shade400),
                      tooltip: '删除整个 run（目录+注册表；启用中先自动停用）',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => unawaited(widget.onDeleteRun()),
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded)
              Padding(
                padding: const EdgeInsets.only(
                    left: 4, right: 8, bottom: 6),
                child: Column(
                  children: [
                    if (checkpoints.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 14, bottom: 4),
                        child: Text(
                          '没有检查点（训练未完成或 best/last 已清理）',
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey.shade600),
                        ),
                      )
                    else
                      for (final c in checkpoints) _checkpointRow(c),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
