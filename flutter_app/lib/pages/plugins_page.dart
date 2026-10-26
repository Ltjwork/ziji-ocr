import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/plugin_host/plugin_icons.dart';
import '../services/plugin_host/plugin_manifest.dart';
import '../services/plugin_host/plugin_runtime.dart';
import '../services/plugin_host/plugin_store.dart';

/// 「设置 → 插件」管理页：外挂插件的导入、启停、设置与卸载。
///
/// 插件是运行时导入的独立功能包（.zjplugin，zip 格式），不随软件内置
/// ——从别处拿到插件文件后在这里导入安装。启用插件的入口出现在编辑
/// 器等聚合处，后台任务随开关启停；卸载只删插件本体，书籍数据不受
/// 影响（各书里的插件数据目录自然遗留，无害）。
class PluginsPage extends StatefulWidget {
  const PluginsPage({super.key});

  @override
  State<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends State<PluginsPage> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(PluginHost.instance.load());
    PluginHost.instance.addListener(_onHostChanged);
  }

  @override
  void dispose() {
    PluginHost.instance.removeListener(_onHostChanged);
    super.dispose();
  }

  void _onHostChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _importPlugin() async {
    if (_busy) return;
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: '选择插件包（.zjplugin / .zip）',
      type: FileType.custom,
      allowedExtensions: ['zjplugin', 'zip'],
    );
    final path = picked?.files.single.path;
    if (path == null) return;
    setState(() => _busy = true);
    final outcome = await PluginHost.instance.installFromZip(path);
    if (!mounted) return;
    setState(() => _busy = false);
    final message = switch (outcome.result) {
      PluginInstallResult.ok => '插件安装成功',
      PluginInstallResult.okUpgraded => '插件已升级到新版本',
      PluginInstallResult.badZip => '无法读取插件包（不是有效的 zip 文件）',
      PluginInstallResult.badManifest =>
        '插件清单无效（缺少 manifest.json 或字段不完整）',
      PluginInstallResult.incompatibleApi =>
        '插件与本版本软件不兼容（插件 API 版本不同），请更新软件或插件',
      PluginInstallResult.badEntries => '插件包内含不安全的路径，已拒绝安装',
      PluginInstallResult.ioError => '插件解包失败（详见应用日志）',
    };
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _reloadPlugin(InstalledPlugin plugin) async {
    if (_busy) return;
    setState(() => _busy = true);
    final reloaded = await PluginHost.instance.reloadPlugin(plugin.id);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          reloaded == null
              ? '插件「${plugin.manifest.name}」的安装目录已不存在，'
                    '视同已卸载'
              : '已重新加载「${reloaded.manifest.name}」'
                    '（v${reloaded.manifest.version}），'
                    '插件页面请重新打开',
        ),
      ),
    );
  }

  Future<void> _confirmUninstall(InstalledPlugin plugin) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('卸载插件「${plugin.manifest.name}」？'),
        content: const Text(
          '卸载会删除插件本体与它的全局配置。书籍数据不受影响；'
          '之后可以随时重新导入安装。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('卸载'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await PluginHost.instance.uninstall(plugin.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final plugins = PluginHost.instance.installed;
    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Text(
              '插件是独立的功能扩展包（.zjplugin 文件），在这里导入安装、'
              '按需启停。启用中插件的入口会出现在编辑器「全书操作」菜单里，'
              '后台任务随开关运行；插件的详细配置在各自的设置页里。'
              '插件文件被直接覆盖更新后，点该插件的「重新加载」即取最新版，'
              '无需重启应用（已打开的插件页面会自动关闭，重新打开即是新版）。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: _busy ? null : _importPlugin,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.upload_file),
              label: Text(_busy ? '正在安装…' : '导入插件（.zjplugin）'),
            ),
            const SizedBox(height: 12),
            if (plugins.isEmpty)
              _EmptyCard(scheme: scheme)
            else
              for (final plugin in plugins)
                _PluginCard(
                  plugin: plugin,
                  enabled: PluginHost.instance.isEnabled(plugin.id),
                  running: PluginHost.instance.runtimes.any(
                    (r) => r.plugin.id == plugin.id,
                  ),
                  onReload: () => _reloadPlugin(plugin),
                  onUninstall: () => _confirmUninstall(plugin),
                ),
          ],
        ),
      ],
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(
              Icons.extension_outlined,
              size: 40,
              color: scheme.onSurface.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 8),
            Text('还没有安装插件', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              '从插件作者处获取 .zjplugin 文件，点上方「导入插件」安装。'
              '插件开发说明见项目仓库 docs/插件开发.md。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PluginCard extends StatelessWidget {
  const _PluginCard({
    required this.plugin,
    required this.enabled,
    required this.running,
    required this.onReload,
    required this.onUninstall,
  });

  final InstalledPlugin plugin;
  final bool enabled;
  final bool running;
  final Future<void> Function() onReload;
  final Future<void> Function() onUninstall;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final manifest = plugin.manifest;
    final hasSettings =
        manifest.settings != null && manifest.settings!.isNotEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: Icon(
                pluginIconOf(manifest.icon),
                color: scheme.primary,
              ),
              title: Text(manifest.name),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  manifest.description.isEmpty
                      ? 'v${manifest.version}'
                      : '${manifest.description}\nv${manifest.version}'
                          '${manifest.author.isEmpty ? '' : ' · ${manifest.author}'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              isThreeLine: manifest.description.isNotEmpty,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasSettings)
                    IconButton(
                      tooltip: '插件设置',
                      icon: const Icon(Icons.settings_outlined),
                      onPressed: () => unawaited(
                        PluginHost.instance.openSettings(context, plugin),
                      ),
                    ),
                  IconButton(
                    tooltip: '重新加载（读取磁盘上的最新插件文件）',
                    icon: const Icon(Icons.refresh),
                    onPressed: () => unawaited(onReload()),
                  ),
                  IconButton(
                    tooltip: '卸载插件',
                    icon: Icon(
                      Icons.delete_outline,
                      color: scheme.error.withValues(alpha: 0.8),
                    ),
                    onPressed: () => unawaited(onUninstall()),
                  ),
                  _PluginSwitch(pluginId: plugin.id, enabled: enabled),
                ],
              ),
            ),
            if (manifest.permissions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final perm in _permissionLabels(manifest.permissions))
                      Chip(
                        label: Text(perm),
                        labelStyle: Theme.of(context).textTheme.bodySmall,
                        visualDensity: VisualDensity.compact,
                        backgroundColor: scheme.surfaceContainerHighest
                            .withValues(alpha: 0.5),
                      ),
                  ],
                ),
              )
            else if (enabled && !running)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Text(
                  '已启用但运行时未启动（WebView2 不可用？详见应用日志）',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static List<String> _permissionLabels(Set<String> permissions) {
    // 顺序按声明习惯排列，未知权限原样显示。
    const order = [
      PluginPermissions.http,
      PluginPermissions.storage,
      PluginPermissions.projectsRead,
      PluginPermissions.projectsWrite,
      PluginPermissions.backend,
      PluginPermissions.export,
    ];
    final known = [
      for (final p in order)
        if (permissions.contains(p)) _permissionLabel(p),
    ];
    final unknown = permissions.difference(order.toSet()).toList()..sort();
    return [...known, ...unknown];
  }

  static String _permissionLabel(String perm) => switch (perm) {
    PluginPermissions.http => '访问网络',
    PluginPermissions.storage => '本地存储',
    PluginPermissions.projectsRead => '读取书库',
    PluginPermissions.projectsWrite => '写回标注',
    PluginPermissions.backend => '调用后端',
    PluginPermissions.export => '导出任务包',
    _ => perm,
  };
}

class _PluginSwitch extends StatefulWidget {
  const _PluginSwitch({required this.pluginId, required this.enabled});

  final String pluginId;
  final bool enabled;

  @override
  State<_PluginSwitch> createState() => _PluginSwitchState();
}

class _PluginSwitchState extends State<_PluginSwitch> {
  bool? _busy;

  @override
  Widget build(BuildContext context) {
    return Switch(
      value: widget.enabled,
      onChanged: _busy == true
          ? null
          : (v) async {
              setState(() => _busy = true);
              try {
                await PluginHost.instance.setEnabled(widget.pluginId, v);
              } finally {
                if (mounted) setState(() => _busy = null);
              }
            },
    );
  }
}
