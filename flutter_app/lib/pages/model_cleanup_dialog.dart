import 'dart:async';

import 'package:flutter/material.dart';

import '../services/python_service.dart';

/// 训练模型目录清理中心：扫描 trained_root 下每个 run 的磁盘占用与
/// 状态，按 run 提供「清理中间轮（保留 best/last 与启用来源）」与
/// 「整删未登记残目录」两个动作；已登记 run 的删除走模型管理页的
/// 删除按钮（会同步停用与注册表），这里不重复。
class ModelCleanupDialog extends StatefulWidget {
  const ModelCleanupDialog({super.key});

  @override
  State<ModelCleanupDialog> createState() => _ModelCleanupDialogState();
}

class _ModelCleanupDialogState extends State<ModelCleanupDialog> {
  Map<String, dynamic>? _scan;
  bool _loading = true;
  String? _error;
  final Set<String> _busy = {}; // run_dir 正在清理

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      final scan = await PythonService.modelCleanupScan();
      if (!mounted) return;
      setState(() {
        _scan = scan;
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

  Future<void> _runAction(Map<String, dynamic> run, String action) async {
    final runDir = run['run_dir']?.toString() ?? '';
    final layer = run['layer']?.toString() ?? '';
    if (runDir.isEmpty || layer.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(action == 'dir' ? '删除残目录' : '清理中间轮'),
        content: Text(action == 'dir'
            ? '${run['name']} 是未登记的残目录（训练未完成/手动中断），'
                '整个目录删除后不可恢复。'
            : '删除 ${run['name']} 的全部中间轮检查点'
                '（${run['epochs_count']} 个 · 约 ${run['epochs_mb']} MB），'
                '保留 best / last 与当前启用中的那一轮。删除后不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Colors.red.shade400),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action == 'dir' ? '删除' : '清理'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy.add(runDir));
    try {
      final result =
          await PythonService.modelCleanupRun(layer: layer, runDir: runDir, action: action);
      if (!mounted) return;
      final freed = (result['freed_mb'] as num?)?.toDouble() ?? 0;
      final skipped = (result['skipped_active'] as num?)?.toInt() ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('已清理 ${freed.toStringAsFixed(1)} MB'
            '${skipped > 0 ? '（跳过启用中 $skipped 个）' : ''}'),
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('清理失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove(runDir));
      await _reload();
    }
  }

  String _statusChips(Map<String, dynamic> run) {
    final chips = <String>[];
    if (run['registered'] == true) {
      chips.add(run['finished'] == true ? '已登记·完成' : '已登记');
    } else if (run['trained'] == true) {
      chips.add('未登记（可在管理页刷新登记）');
    } else {
      chips.add('残目录（未完成）');
    }
    if (run['epochs_count'] == 0) chips.add('无中间轮');
    return chips.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final totalMb = (_scan?['total_mb'] as num?)?.toDouble();
    final runs = ((_scan?['runs'] as List?) ?? const [])
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();
    // 按层分组，保持扫描顺序（层名字母序）
    final byLayer = <String, List<Map<String, dynamic>>>{};
    for (final r in runs) {
      byLayer.putIfAbsent(r['layer'].toString(), () => []).add(r);
    }
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.cleaning_services,
                    size: 18, color: Colors.blueGrey),
                const SizedBox(width: 8),
                const Text('清理训练模型目录',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const Spacer(),
                if (totalMb != null)
                  Text('共 ${totalMb.toStringAsFixed(1)} MB',
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade700)),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 18),
                  tooltip: '重新扫描',
                  onPressed: _loading ? null : _reload,
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => Navigator.pop(context),
                ),
              ]),
              const SizedBox(height: 4),
              Text(
                'root：${_scan?['root'] ?? '…'}',
                style: TextStyle(fontSize: 10.5, color: Colors.grey.shade600),
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              if (_loading)
                const Expanded(
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_error != null)
                Expanded(
                  child: Center(
                    child: Text('扫描失败：$_error',
                        style:
                            const TextStyle(fontSize: 12, color: Colors.red)),
                  ),
                )
              else if (runs.isEmpty)
                const Expanded(
                  child: Center(
                    child: Text('训练目录是空的', style: TextStyle(fontSize: 12.5)),
                  ),
                )
              else
                Expanded(
                  child: ListView(
                    children: [
                      for (final entry in byLayer.entries) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 2),
                          child: Text(
                            '${entry.key} · ${entry.value.length} 个 run · '
                            '${entry.value.fold<double>(0, (s, r) => s + (r['size_mb'] as num).toDouble()).toStringAsFixed(1)} MB',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Colors.blueGrey.shade700),
                          ),
                        ),
                        for (final run in entry.value)
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${run['name']} · ${run['size_mb']} MB',
                                      style: const TextStyle(fontSize: 12),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      '${_statusChips(run)}'
                                      '${run['epochs_count'] > 0 ? ' · 中间轮 ${run['epochs_count']} 个 ${run['epochs_mb']} MB' : ''}'
                                      '${run['best_mb'] > 0 ? ' · best/last ${run['best_mb']} MB' : ''}',
                                      style: TextStyle(
                                          fontSize: 10.5,
                                          color: (run['registered'] != true &&
                                                  run['trained'] != true)
                                              ? Colors.orange.shade800
                                              : Colors.grey.shade600),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                              if (_busy.contains(run['run_dir']))
                                const SizedBox(
                                    width: 15,
                                    height: 15,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))
                              else ...[
                                if (run['epochs_count'] > 0)
                                  TextButton(
                                    onPressed: () =>
                                        unawaited(_runAction(run, 'epochs')),
                                    style: TextButton.styleFrom(
                                      visualDensity: VisualDensity.compact,
                                      padding: const EdgeInsets
                                          .symmetric(horizontal: 6),
                                    ),
                                    child: const Text('清理中间轮',
                                        style: TextStyle(fontSize: 11.5)),
                                  ),
                                if (run['registered'] != true)
                                  TextButton(
                                    onPressed: () =>
                                        unawaited(_runAction(run, 'dir')),
                                    style: TextButton.styleFrom(
                                      foregroundColor: Colors.red.shade700,
                                      visualDensity: VisualDensity.compact,
                                      padding: const EdgeInsets
                                          .symmetric(horizontal: 6),
                                    ),
                                    child: const Text('删残目录',
                                        style: TextStyle(fontSize: 11.5)),
                                  ),
                              ],
                            ],
                          ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
