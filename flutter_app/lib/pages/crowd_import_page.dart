import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/crowd_consensus_importer.dart';
import '../services/storage.dart';

/// 导入命迹识字共识快照：选择后台导出的 JSON → 匹配本项目 →
/// 按字块 UID 写回共识文字并标记已确认。
class CrowdImportPage extends StatefulWidget {
  const CrowdImportPage({super.key, required this.rootDir, this.embedded = false});

  final String rootDir;

  /// 作为整合页（HubPage）标签嵌入时不包自己的 Scaffold。
  final bool embedded;

  @override
  State<CrowdImportPage> createState() => _CrowdImportPageState();
}

class _CrowdImportPageState extends State<CrowdImportPage> {
  CrowdConsensusSnapshot? _snapshot;
  String? _snapshotPath;
  String? _parseError;
  List<Project> _projects = [];
  Project? _selectedProject;
  bool _autoMatched = false;
  bool _importing = false;
  CrowdConsensusImportResult? _result;
  final _logs = <String>[];

  @override
  void initState() {
    super.initState();
    _loadProjects();
  }

  Future<void> _loadProjects() async {
    final projects = await ProjectStorage.loadAll(widget.rootDir);
    if (!mounted) return;
    setState(() => _projects = projects);
    _tryAutoMatch();
  }

  void _tryAutoMatch() {
    final snapshot = _snapshot;
    if (snapshot == null || snapshot.projectId.isEmpty) return;
    for (final project in _projects) {
      if (project.id == snapshot.projectId) {
        setState(() {
          _selectedProject = project;
          _autoMatched = true;
        });
        return;
      }
    }
  }

  Future<void> _pickSnapshot() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      dialogTitle: '选择命迹识字共识快照（crowd_snapshot_*.json）',
    );
    if (picked == null || picked.files.isEmpty) return;
    final path = picked.files.single.path;
    if (path == null) return;
    try {
      final snapshot = parseCrowdConsensusSnapshot(File(path));
      setState(() {
        _snapshotPath = path;
        _snapshot = snapshot;
        _parseError = null;
        _result = null;
        _logs.clear();
        _autoMatched = false;
        _selectedProject = null;
      });
      _tryAutoMatch();
    } catch (e) {
      setState(() => _parseError = '快照解析失败：$e');
    }
  }

  Future<void> _runImport() async {
    final snapshot = _snapshot;
    final project = _selectedProject;
    if (snapshot == null || project == null || _importing) return;
    setState(() {
      _importing = true;
      _logs.clear();
      _result = null;
    });
    try {
      final result = await importCrowdConsensusSnapshot(
        snapshot: snapshot,
        project: project,
        onLog: (message) {
          if (mounted) setState(() => _logs.add(message));
        },
      );
      if (mounted) {
        setState(() => _result = result);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _parseError = '导入失败：$e');
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final body = _projects.isEmpty && _snapshot == null
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildPickCard(context),
              if (_parseError != null)
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(_parseError!),
                  ),
                ),
              if (snapshot != null) ...[
                const SizedBox(height: 12),
                _buildSnapshotCard(context, snapshot),
                const SizedBox(height: 12),
                _buildProjectCard(context),
                const SizedBox(height: 12),
                _buildRunCard(context),
              ],
            ],
          );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(title: const Text('导入识字共识')),
      body: body,
    );
  }

  Widget _buildPickCard(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.upload_file),
        title: Text(
          _snapshotPath == null ? '选择共识快照文件' : '重新选择快照',
        ),
        subtitle: Text(
          _snapshotPath ?? '管理后台「识字任务批次 → 共识快照」导出的 JSON 文件',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: _pickSnapshot,
      ),
    );
  }

  Widget _buildSnapshotCard(BuildContext context, snapshot) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('快照信息', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('书籍：${snapshot.bookTitle.isEmpty ? "（未命名）" : snapshot.bookTitle}'),
            Text('批次：${snapshot.batchName.isEmpty ? "-" : snapshot.batchName}'),
            Text('OCR 项目 ID：${snapshot.projectId.isEmpty ? "-" : snapshot.projectId}'),
            Text('共识条目：${snapshot.entryCount} 字（${snapshot.entriesByPage.length} 页）'),
          ],
        ),
      ),
    );
  }

  Widget _buildProjectCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('写回项目', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (_autoMatched && _selectedProject != null)
              Row(
                children: [
                  const Icon(Icons.check_circle, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '已按项目 ID 自动匹配：「${_selectedProject!.name}」',
                    ),
                  ),
                ],
              )
            else
              Text(
                '快照未自动匹配到项目（项目 ID 不符），请手动选择：',
              ),
            if (!_autoMatched)
              ..._projects.map(
                (project) => ListTile(
                  title: Text(project.name),
                  subtitle: Text('ID ${project.id}'),
                  trailing: _selectedProject == project
                      ? const Icon(Icons.check_circle)
                      : null,
                  onTap: () => setState(() => _selectedProject = project),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRunCard(BuildContext context) {
    final result = _result;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (result == null) ...[
              FilledButton.icon(
                onPressed: _selectedProject == null || _importing
                    ? null
                    : _runImport,
                icon: _importing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download),
                label: Text(_importing ? '导入中…' : '开始写回'),
              ),
              const SizedBox(height: 8),
              const Text(
                '写回规则：按字块 UID 匹配（找不到按导出时的块 ID 兜底），'
                '用共识文字替换后标记为「待复核」；导出后才人工确认过的字不会被覆盖。'
                '请在编辑器中复核这些字，照常「确认并保存」后即成为训练数据。',
                style: TextStyle(fontSize: 12),
              ),
            ] else ...[
              Text('导入完成', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              _reportRow('共识条目', '${result.entryCount}'),
              _reportRow('写回命中', '${result.appliedCount}'),
              _reportRow('与原文不同', '${result.changedCount}'),
              _reportRow('已确认跳过', '${result.skippedConfirmed}'),
              _reportRow('未匹配字块', '${result.missingBlocks}'),
              _reportRow('缺失页', '${result.missingPages}'),
              _reportRow('修订号不一致', '${result.revisionMismatches}'),
            ],
            if (_logs.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 240),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final line in _logs)
                      Text(
                        line,
                        style: const TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _reportRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(label, style: const TextStyle(fontSize: 13)),
          ),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
