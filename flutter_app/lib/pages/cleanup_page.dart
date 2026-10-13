import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/python_service.dart';

/// 诊断清理页：崩溃转储（crash_dumps/*.dmp，WER 全量转储单份 7-8GB）
/// 与运行日志（logs/*.log）的占用展示与手动清理；自动策略说明同屏。
///
/// 只清理"可再生的诊断产物"，不碰数据集/模型/标注等用户数据。后端
/// 未运行时降级为 Dart 直删崩溃转储——磁盘被几十 GB 转储撑满时后端
/// 恰恰起不来，本地兜底正是那时的救命绳。
class CleanupPage extends StatefulWidget {
  const CleanupPage({super.key, this.embedded = false});

  /// 作为整合页（HubPage）标签嵌入：不包自己的 Scaffold/AppBar。
  final bool embedded;

  @override
  State<CleanupPage> createState() => _CleanupPageState();
}

class _CleanupPageState extends State<CleanupPage> {
  Map<String, dynamic>? _status;
  bool _loading = true;
  bool _running = false;
  String? _error;

  // 本地兜底视图的数据（后端未运行时）。
  List<File> _localDumps = const [];
  int _localDumpsBytes = 0;

  bool _keepLastDump = true;
  bool _cleanOldLogs = true;
  bool _cleanActiveLogs = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final status = await PythonService.cleanupStatus();
      if (!mounted) return;
      setState(() {
        _status = status;
        _error = null;
        _loading = false;
      });
      if (status == null) await _loadLocalFallback();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
      await _loadLocalFallback();
    }
  }

  /// 后端不可用：直接扫本地转储目录，至少让"删转储救命"这条路可用。
  Future<void> _loadLocalFallback() async {
    final dir = PythonService.logServiceDir;
    if (dir == null) return;
    final dumpsDir = Directory(p.normalize('$dir/../crash_dumps'));
    if (!await dumpsDir.exists()) return;
    final files = <File>[];
    var bytes = 0;
    await for (final e in dumpsDir.list()) {
      if (e is File && e.path.toLowerCase().endsWith('.dmp')) {
        files.add(e);
        bytes += await e.length();
      }
    }
    files.sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
    if (!mounted) return;
    setState(() {
      _localDumps = files;
      _localDumpsBytes = bytes;
    });
  }

  String _fmt(num bytes) {
    if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(2)} GB';
    if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
    if (bytes >= 1 << 10) return '${(bytes / (1 << 10)).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  int get _dumpBytes {
    final s = _status;
    if (s != null) return ((s['dumps'] as Map?)?['bytes'] as num?)?.toInt() ?? 0;
    return _localDumpsBytes;
  }

  int get _dumpCount {
    final s = _status;
    if (s != null) return ((s['dumps'] as Map?)?['count'] as num?)?.toInt() ?? 0;
    return _localDumps.length;
  }

  int get _logBytes =>
      ((_status?['logs'] as Map?)?['bytes'] as num?)?.toInt() ?? 0;

  int get _oldLogBytes =>
      ((_status?['old_logs'] as Map?)?['bytes'] as num?)?.toInt() ?? 0;

  /// 勾选目标合计可回收量（用于按钮副标题与确认弹窗）。
  int get _selectedBytes {
    var total = 0;
    if (_dumpCount > 0) {
      final keep = _keepLastDump ? 1 : 0;
      if (_status != null) {
        // 后端口径：按文件逐一算（保留最新 1 份）。
        final files = (( _status!['dumps'] as Map)['files'] as List)
            .cast<Map>();
        final keepNames = keep > 0 && files.isNotEmpty
            ? <String>{files.last['name'].toString()}
            : <String>{};
        for (final f in files) {
          if (!keepNames.contains(f['name'].toString())) {
            total += (f['bytes'] as num).toInt();
          }
        }
      } else if (_localDumps.isNotEmpty) {
        final doomed = keep > 0
            ? _localDumps.sublist(0, _localDumps.length - keep)
            : _localDumps;
        for (final f in doomed) {
          total += f.lengthSync();
        }
      }
    }
    if (_cleanOldLogs) total += _oldLogBytes;
    if (_cleanActiveLogs) total += _logBytes - _oldLogBytes;
    return total;
  }

  Future<void> _runCleanup() async {
    final toFree = _selectedBytes;
    if (toFree <= 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认清理'),
        content: Text(
          '将释放约 ${_fmt(toFree)} 磁盘空间。\n'
          '崩溃转储删除后不可恢复（WER 只在崩溃时生成新转储）；'
          '日志清空只影响排查历史，不影响识别数据。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _running = true);
    try {
      if (_status != null) {
        final targets = <String>{
          if (_dumpCount > 0) 'crash_dumps',
          if (_cleanOldLogs) 'old_logs',
          if (_cleanActiveLogs) 'active_logs',
        };
        final r = await PythonService.cleanupRun(
          targets: targets,
          keepLastDump: _keepLastDump ? 1 : 0,
        );
        if (mounted) {
          final freed = (r['freed_bytes'] as num?)?.toInt() ?? 0;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('清理完成：释放 ${_fmt(freed)}')),
          );
        }
      } else {
        // 本地兜底：只能删转储。
        final freed = await PythonService.localDumpCleanup(
          keepLast: _keepLastDump ? 1 : 0,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已删除崩溃转储：释放 ${_fmt(freed)}')),
          );
        }
      }
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('清理失败：$e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                if (_status == null) _backendDownBanner(),
                _autoPolicyCard(),
                _dumpsCard(),
                _logsCard(),
                const SizedBox(height: 12),
                _actionButton(),
                const SizedBox(height: 24),
              ],
            ),
          );
    return widget.embedded
        ? body
        : Scaffold(
            appBar: AppBar(title: const Text('诊断清理')),
            body: body,
          );
  }

  Widget _backendDownBanner() {
    return Card(
      color: Colors.orange.shade50,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange.shade800),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '识别服务未运行${_error == null ? '' : '（$_error）'}：日志清理'
                '需要后端在线；崩溃转储可直接本地删除（下方勾选后点'
                '"立即清理"）。',
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _autoPolicyCard() {
    final policy = (_status?['policy'] as Map?) ?? const {};
    final rotateMb = (policy['rotate_size_mb'] as num?) ?? 50;
    final trimMb = (policy['trim_size_mb'] as num?) ?? 200;
    final dumpAge = (policy['dump_max_age_days'] as num?) ?? 14;
    final dumpTotalGb = (policy['dump_max_total_gb'] as num?) ?? 10;
    final keepN = (policy['dump_keep_when_over'] as num?) ?? 2;
    final oldAge = (policy['old_log_max_age_days'] as num?) ?? 14;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.auto_mode, size: 18),
                SizedBox(width: 6),
                Text('自动清理（服务启动时 + 每 6 小时巡检）',
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '· 当前日志超过 $rotateMb MB 时轮转为 .old，从新文件续写\n'
              '· 崩溃转储超过 $dumpAge 天清理；总量超过 $dumpTotalGb GB 时'
              '只保留最新 $keepN 份\n'
              '· 运行期日志超过 $trimMb MB 时保尾截断；.old 超过 $oldAge 天'
              '删除',
              style: TextStyle(
                  fontSize: 11.5, color: Theme.of(context).hintColor),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dumpsCard() {
    final files = ((_status?['dumps'] as Map?)?['files'] as List?) ??
        const [];
    final dir = (_status?['dumps_dir'] as String?) ??
        (PythonService.logServiceDir != null
            ? p.normalize('${PythonService.logServiceDir}/../crash_dumps')
            : '');
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: Text(
              '崩溃转储（$_dumpCount 份 · ${_fmt(_dumpBytes)}）',
              style: const TextStyle(fontSize: 13),
            ),
            subtitle: Text(dir, style: const TextStyle(fontSize: 10.5)),
            trailing: _dumpCount > 0
                ? Tooltip(
                    message: '清理时删除（可保留最新一份）',
                    child: Icon(Icons.delete_outline,
                        size: 20, color: Theme.of(context).hintColor),
                  )
                : const Icon(Icons.check, size: 20),
          ),
          if (files.isNotEmpty) ..._dumpFileTiles(files),
          if (_dumpCount > 0)
            CheckboxListTile(
              dense: true,
              value: _keepLastDump,
              onChanged: (v) =>
                  setState(() => _keepLastDump = v ?? _keepLastDump),
              title: const Text('保留最新一份（排查进行中留现场）',
                  style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }

  List<Widget> _dumpFileTiles(List<dynamic> files) {
    final rows = files.cast<Map>().toList().reversed.toList(); // 新→旧
    return rows.take(6).map((f) {
      final mtime = DateTime.fromMillisecondsSinceEpoch(
          ((f['mtime'] as num?) ?? 0).toInt() * 1000);
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                f['name'].toString(),
                style: const TextStyle(fontSize: 11.5),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _fmt((f['bytes'] as num).toInt()),
              style: TextStyle(
                  fontSize: 11.5, color: Theme.of(context).hintColor),
            ),
            const SizedBox(width: 12),
            Text(
              '${mtime.month.toString().padLeft(2, '0')}-'
              '${mtime.day.toString().padLeft(2, '0')}',
              style: TextStyle(
                  fontSize: 11, color: Theme.of(context).hintColor),
            ),
          ],
        ),
      );
    }).toList();
  }

  Widget _logsCard() {
    final logs = ((_status?['logs'] as Map?)?['files'] as List?) ?? const [];
    final dir = (_status?['logs_dir'] as String?) ?? '';
    return Card(
      margin: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            value: _cleanOldLogs,
            onChanged: _oldLogBytes > 0
                ? (v) => setState(() => _cleanOldLogs = v)
                : null,
            secondary: const Icon(Icons.history),
            title: Text(
              '历史日志（.old · ${_fmt(_oldLogBytes)}）',
              style: const TextStyle(fontSize: 13),
            ),
          ),
          SwitchListTile(
            value: _cleanActiveLogs,
            onChanged: _status == null
                ? null
                : (v) => setState(() => _cleanActiveLogs = v),
            secondary: const Icon(Icons.receipt_long_outlined),
            title: Text(
              '清空当前日志内容（${_fmt(_logBytes - _oldLogBytes)}）',
              style: const TextStyle(fontSize: 13),
            ),
            subtitle: Text(
              _status == null ? '需要识别服务在线' : dir,
              style: const TextStyle(fontSize: 10.5),
            ),
          ),
          if (logs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Column(
                children: logs.cast<Map>().map((f) {
                  return Row(
                    children: [
                      Expanded(
                        child: Text(
                          f['name'].toString(),
                          style: const TextStyle(fontSize: 11.5),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        _fmt((f['bytes'] as num?)?.toInt() ?? 0),
                        style: TextStyle(
                            fontSize: 11.5,
                            color: Theme.of(context).hintColor),
                      ),
                    ],
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _actionButton() {
    final toFree = _selectedBytes;
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: (_running || toFree <= 0) ? null : _runCleanup,
        icon: _running
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.cleaning_services),
        label: Text(
          _running
              ? '清理中…'
              : toFree > 0
                  ? '立即清理（释放约 ${_fmt(toFree)}）'
                  : '没有可清理的内容',
        ),
      ),
    );
  }
}
