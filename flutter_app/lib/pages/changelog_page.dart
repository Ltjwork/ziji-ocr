import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/changelog_service.dart';

/// 更新日志页：按版本分节展示 CHANGELOG.md（第一条即当前版本），支持
/// 一键复制某版本 / 全部 markdown——上传 GitHub 时直接贴进 Release
/// 发布说明。
class ChangelogPage extends StatefulWidget {
  const ChangelogPage({super.key});

  @override
  State<ChangelogPage> createState() => _ChangelogPageState();
}

class _ChangelogPageState extends State<ChangelogPage> {
  List<ChangelogEntry> _entries = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await ChangelogService.load();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  Future<void> _copy(String title, String markdown) async {
    await Clipboard.setData(ClipboardData(text: markdown));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制$title 的更新日志（GitHub 发布说明可直接粘贴）')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('更新日志'),
        actions: [
          if (_entries.isNotEmpty)
            TextButton.icon(
              onPressed: () => _copy(
                '本版本（${_entries.first.version}）',
                '## ${_entries.first.version}\n\n${_entries.first.markdown}',
              ),
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('复制本版本'),
            ),
          if (_entries.length > 1)
            TextButton.icon(
              onPressed: () => _copy(
                '全部',
                _entries
                    .map((e) => '## ${e.version}\n\n${e.markdown}')
                    .join('\n\n'),
              ),
              icon: const Icon(Icons.copy_all, size: 18),
              label: const Text('全部'),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _entries.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.search_off, size: 40, color: Colors.grey),
                      const SizedBox(height: 12),
                      const Text('未找到 CHANGELOG.md'),
                      const SizedBox(height: 4),
                      Text(
                        '开发运行时它位于项目根目录（python_service 上级）；'
                        '安装版随安装目录携带',
                        style: const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _entries.length,
                  itemBuilder: (context, index) {
                    final entry = _entries[index];
                    return Card(
                      child: Theme(
                        // 去掉 ExpansionTile 默认的 3px 顶部间距
                        data: Theme.of(context)
                            .copyWith(dividerColor: Colors.transparent),
                        child: ExpansionTile(
                          initiallyExpanded: index == 0,
                          title: Row(
                            children: [
                              Text(
                                entry.version,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (index == 0) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary
                                        .withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    '本版本',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          trailing: IconButton(
                            tooltip: '复制此版本（GitHub 发布说明用）',
                            icon: const Icon(Icons.copy, size: 18),
                            onPressed: () => _copy(
                              entry.version,
                              '## ${entry.version}\n\n${entry.markdown}',
                            ),
                          ),
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: SelectableText(
                                  entry.markdown,
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    height: 1.55,
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
}
