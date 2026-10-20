import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/python_service.dart';
import '../services/update_service.dart';
import '../widgets/release_markdown.dart';
import 'changelog_page.dart';

class AboutUpdatePage extends StatefulWidget {
  const AboutUpdatePage({super.key, this.embedded = false, this.updates});

  final bool embedded;
  final UpdateService? updates;

  @override
  State<AboutUpdatePage> createState() => _AboutUpdatePageState();
}

class _AboutUpdatePageState extends State<AboutUpdatePage> {
  late final UpdateService _updates = widget.updates ?? UpdateService.instance;
  bool _launching = false;

  @override
  void initState() {
    super.initState();
    _updates.addListener(_onUpdateChanged);
    if (_updates.status == UpdateStatus.idle) _updates.initializeAndCheck();
  }

  @override
  void dispose() {
    _updates.removeListener(_onUpdateChanged);
    super.dispose();
  }

  void _onUpdateChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _install() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('运行更新安装程序'),
        content: const Text('请先保存并关闭正在编辑的内容。应用将停止 OCR 后端并退出，然后启动安装程序。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.install_desktop),
            label: const Text('继续更新'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _launching = true);
    try {
      final stopped = await PythonService.stopAndWait();
      if (!stopped) {
        throw StateError('未能确认 OCR 后端已停止。请关闭独立后端控制台后重试更新。');
      }
      await _updates.launchInstaller();
      exit(0);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('启动更新失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _launching = false);
    }
  }

  Future<void> _openRelease() async {
    final uri = _updates.release?.url;
    if (uri == null || !Platform.isWindows) return;
    try {
      await Process.run('explorer.exe', [uri.toString()]);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('无法打开 GitHub Release：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _updates.status;
    final release = _updates.release;
    final content = ListView(
      padding: const EdgeInsets.all(20),
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.document_scanner_outlined, size: 32),
          title: const Text('字迹'),
          subtitle: Text('当前版本 ${_updates.currentVersion ?? '读取中…'}'),
        ),
        const Divider(),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('GitHub 更新'),
          subtitle: Text(_statusText(status, release)),
          trailing: IconButton(
            tooltip: '检查更新',
            onPressed: status == UpdateStatus.checking
                ? null
                : _updates.checkForUpdates,
            icon: status == UpdateStatus.checking
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ),
        if (status == UpdateStatus.error && _updates.error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _updates.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (release != null) ...[
          Text(release.name, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ReleaseMarkdown(data: release.notes),
          const SizedBox(height: 12),
        ],
        if (release != null && _updates.updateAvailable) ...[
          if (status == UpdateStatus.downloading) ...[
            LinearProgressIndicator(value: _updates.downloadProgress),
            const SizedBox(height: 6),
            Text(
              '${_formatBytes(_updates.downloadedBytes)} / '
              '${_updates.totalBytes > 0 ? _formatBytes(_updates.totalBytes) : '未知'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _updates.cancelDownload,
                icon: const Icon(Icons.close),
                label: const Text('取消下载'),
              ),
            ),
          ] else if (status == UpdateStatus.downloaded)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _updates.checksumAvailable
                      ? '安装包 SHA-256 已校验'
                      : '此 Release 未提供 SHA-256 校验值',
                ),
                Text(p.basename(_updates.installerPath ?? '')),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed: _launching ? null : _install,
                    icon: _launching
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.install_desktop),
                    label: const Text('运行安装程序并退出应用'),
                  ),
                ),
              ],
            )
          else
            Wrap(
              spacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: status == UpdateStatus.downloading
                      ? null
                      : _updates.downloadUpdate,
                  icon: const Icon(Icons.download),
                  label: Text(
                    '下载 Windows 安装包（${_formatBytes(release.asset.size)}）',
                  ),
                ),
                TextButton.icon(
                  onPressed: _openRelease,
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('GitHub Release'),
                ),
              ],
            ),
        ],
        if (_updates.error != null && status == UpdateStatus.error)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: release == null
                  ? _updates.checkForUpdates
                  : _updates.downloadUpdate,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ),
        const Divider(height: 28),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ChangelogPage()),
            ),
            icon: const Icon(Icons.history_edu),
            label: const Text('GitHub 更新日志'),
          ),
        ),
      ],
    );
    if (widget.embedded) return content;
    return Scaffold(
      appBar: AppBar(title: const Text('关于 / 更新')),
      body: content,
    );
  }

  String _statusText(UpdateStatus status, GitHubRelease? release) {
    switch (status) {
      case UpdateStatus.idle:
        return '尚未检查';
      case UpdateStatus.checking:
        return '正在查询 GitHub Releases…';
      case UpdateStatus.current:
        return '已是最新版本';
      case UpdateStatus.available:
      case UpdateStatus.downloading:
      case UpdateStatus.downloaded:
        return '发现新版本 ${release?.version}';
      case UpdateStatus.error:
        return '检查或下载失败';
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
