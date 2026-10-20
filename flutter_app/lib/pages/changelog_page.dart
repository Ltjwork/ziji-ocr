import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/changelog_service.dart';
import '../widgets/release_markdown.dart';

/// 在线查看 GitHub Releases，保留发布说明原文供选择和复制。
class ChangelogPage extends StatefulWidget {
  const ChangelogPage({super.key, this.service});

  final ChangelogService? service;

  @override
  State<ChangelogPage> createState() => _ChangelogPageState();
}

class _ChangelogPageState extends State<ChangelogPage> {
  late final ChangelogService _service;
  final List<ChangelogEntry> _entries = [];
  bool _loading = false;
  String? _error;
  int? _nextPage = 1;
  bool _retryRefresh = true;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? ChangelogService();
    _load(refresh: true);
  }

  @override
  void dispose() {
    if (widget.service == null) _service.dispose();
    super.dispose();
  }

  Future<void> _load({bool refresh = false}) async {
    if (_loading || (!refresh && _nextPage == null)) return;
    setState(() {
      _loading = true;
      _error = null;
      _retryRefresh = refresh;
    });
    try {
      final result = await _service.load(page: refresh ? 1 : _nextPage!);
      if (!mounted) return;
      setState(() {
        if (refresh) _entries.clear();
        final ids = _entries.map((e) => e.id).toSet();
        for (final entry in result.entries) {
          if (ids.add(entry.id)) _entries.add(entry);
        }
        _nextPage = result.nextPage;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '读取 GitHub 更新日志失败：$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _copy(String markdown) async {
    await Clipboard.setData(ClipboardData(text: markdown));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已复制发布说明')));
  }

  String _markdown(ChangelogEntry entry) =>
      '## ${entry.version}\n\n${entry.markdown}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('GitHub 更新日志'),
        actions: [
          if (_entries.isNotEmpty)
            IconButton(
              tooltip: '复制已加载日志',
              onPressed: () => _copy(_entries.map(_markdown).join('\n\n')),
              icon: const Icon(Icons.copy_all),
            ),
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : () => _load(refresh: true),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          for (var index = 0; index < _entries.length; index++)
            _entryCard(_entries[index], index),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => _load(refresh: _retryRefresh),
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试'),
                  ),
                ],
              ),
            )
          else ...[
            if (_entries.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('GitHub 暂无正式版本发布记录')),
              ),
            if (_nextPage != null)
              Center(
                child: TextButton.icon(
                  onPressed: _load,
                  icon: const Icon(Icons.expand_more),
                  label: const Text('加载更多'),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _entryCard(ChangelogEntry entry, int index) {
    final date = entry.publishedAt
        ?.toLocal()
        .toIso8601String()
        .split('T')
        .first;
    return Card(
      child: ExpansionTile(
        key: ValueKey(entry.id),
        initiallyExpanded: index == 0,
        title: Text(
          entry.title,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text([entry.version, if (date != null) date].join(' · ')),
        trailing: IconButton(
          tooltip: '复制发布说明',
          icon: const Icon(Icons.copy, size: 18),
          onPressed: () => _copy(_markdown(entry)),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: ReleaseMarkdown(data: entry.markdown),
            ),
          ),
        ],
      ),
    );
  }
}
