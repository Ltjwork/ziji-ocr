import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'plugin_manifest.dart';

/// 一个已安装插件：清单 + 安装目录。
class InstalledPlugin {
  const InstalledPlugin({required this.manifest, required this.dir});

  final PluginManifest manifest;
  final String dir;

  String get id => manifest.id;
}

/// 安装/卸载 .zjplugin（zip）的结果。
enum PluginInstallResult {
  ok,
  okUpgraded,
  badZip,
  badManifest,
  incompatibleApi,
  badEntries,
  ioError,
}

/// 一次安装/升级的结果：状态 + 解析出的插件 id（失败时 id 为空）。
class PluginInstallOutcome {
  const PluginInstallOutcome(this.result, this.id);

  final PluginInstallResult result;
  final String? id;

  bool get ok =>
      result == PluginInstallResult.ok || result == PluginInstallResult.okUpgraded;
}

/// 插件仓库：插件落盘位置（应用支持目录 plugins/）、zip 导入、卸载、
/// 启停持久化。目录结构：
///
/// ```
/// <应用支持目录>/plugins/
///   <插件id>/            ← 包体解压根（manifest.json + main.js + 页面）
///     data/global.json   ← 插件全局存储（storage.* 命令读写）
///   ```
///
/// 每书的插件数据不放这里（跟着书走）：`{书目录}/plugin_data/<插件id>.json`。
class PluginStore {
  PluginStore(this.root);

  /// 插件安装根目录（应用支持目录/plugins）。
  final String root;

  static const _prefsKey = 'ziji.plugins.enabled';

  String dirFor(String id) => p.join(root, id);

  Future<void> ensureRoot() async {
    await Directory(root).create(recursive: true);
  }

  /// 扫描已安装插件（目录里 manifest.json 解析失败即跳过——半装的
  /// 插件不出现在列表，重装可修复）。
  Future<List<InstalledPlugin>> listInstalled() async {
    final result = <InstalledPlugin>[];
    final rootDir = Directory(root);
    if (!await rootDir.exists()) return result;
    await for (final entry in rootDir.list()) {
      if (entry is! Directory) continue;
      if (p.basename(entry.path).startsWith('_')) continue;
      final manifestFile = File(p.join(entry.path, 'manifest.json'));
      if (!await manifestFile.exists()) continue;
      final manifest = PluginManifest.tryParse(
        await manifestFile.readAsString(),
      );
      if (manifest == null) continue;
      result.add(InstalledPlugin(manifest: manifest, dir: entry.path));
    }
    result.sort((a, b) => a.manifest.name.compareTo(b.manifest.name));
    return result;
  }

  /// 从 zip 安装/升级插件。返回结果与解析出的插件 id。
  Future<PluginInstallOutcome> installFromZip(
    String zipPath, {
    int expectedApiVersion = PluginHostApiVersion.current,
    void Function(String message)? onLog,
    bool Function(String id)? isRunning,
    Future<void> Function(String id)? onStopBeforeReplace,
  }) async {
    late final Archive archive;
    try {
      final bytes = await File(zipPath).readAsBytes();
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      return const PluginInstallOutcome(PluginInstallResult.badZip, null);
    }

    // zip 条目规整：统一用 `/` 分隔（PowerShell Compress-Archive 用 `\`），
    // 拒绝路径穿越（绝对路径/..）；允许「单层顶层目录包住全部内容」的
    // 打包习惯（GitHub zip 下载即如此），解包时剥掉。
    var entries = <(String, List<int>)>[];
    for (final f in archive) {
      final name = f.name.replaceAll('\\', '/');
      if (name.endsWith('/')) continue;
      if (p.isAbsolute(name) ||
          p.isAbsolute(f.name) ||
          name.split('/').contains('..')) {
        return const PluginInstallOutcome(PluginInstallResult.badEntries, null);
      }
      entries.add((name, f.content as List<int>));
    }
    if (entries.isEmpty) {
      return const PluginInstallOutcome(PluginInstallResult.badZip, null);
    }
    final topSegments = entries.map((f) => f.$1.split('/').first).toSet();
    // 单层顶层目录剥离只在「每个条目都真的在该目录之下」时进行——
    // 单文件包（只有 main.js）没有目录层，不能把文件名当目录剥。
    final root = topSegments.singleOrNull;
    if (root != null &&
        root != 'manifest.json' &&
        entries.every((f) => f.$1.startsWith('$root/'))) {
      final prefix = '$root/';
      entries = [
        for (final f in entries) (f.$1.substring(prefix.length), f.$2),
      ];
    }

    final manifestEntry = entries.where((f) => f.$1 == 'manifest.json');
    if (manifestEntry.isEmpty) {
      return const PluginInstallOutcome(PluginInstallResult.badManifest, null);
    }
    final manifest = PluginManifest.tryParse(
      utf8.decode(manifestEntry.single.$2),
    );
    if (manifest == null) {
      return const PluginInstallOutcome(PluginInstallResult.badManifest, null);
    }
    if (manifest.apiVersion != expectedApiVersion) {
      return PluginInstallOutcome(PluginInstallResult.incompatibleApi, manifest.id);
    }
    if (!entries.any((f) => f.$1 == manifest.entry)) {
      return PluginInstallOutcome(PluginInstallResult.badManifest, manifest.id);
    }

    final targetDir = dirFor(manifest.id);
    final wasInstalled = await File(
      p.join(targetDir, 'manifest.json'),
    ).exists();
    try {
      // 覆盖安装先停运行时并整目录换新（data/ 存储在换新前抢救回来）。
      final dataFile = File(p.join(targetDir, 'data', 'global.json'));
      List<int>? preservedData;
      if (await dataFile.exists()) {
        try {
          preservedData = await dataFile.readAsBytes();
        } catch (_) {}
      }
      if (isRunning?.call(manifest.id) == true) {
        await onStopBeforeReplace?.call(manifest.id);
      }
      final dir = Directory(targetDir);
      if (await dir.exists()) await dir.delete(recursive: true);
      await dir.create(recursive: true);
      for (final f in entries) {
        final dest = p.join(targetDir, f.$1);
        await Directory(p.dirname(dest)).create(recursive: true);
        await File(dest).writeAsBytes(f.$2);
      }
      if (preservedData != null) {
        final restored = File(p.join(targetDir, 'data', 'global.json'));
        await restored.parent.create(recursive: true);
        await restored.writeAsBytes(preservedData);
      }
    } catch (e) {
      onLog?.call('插件解包失败：$e');
      return PluginInstallOutcome(PluginInstallResult.ioError, manifest.id);
    }
    return PluginInstallOutcome(
      wasInstalled ? PluginInstallResult.okUpgraded : PluginInstallResult.ok,
      manifest.id,
    );
  }

  /// 卸载：删安装目录（含插件存储 data/）。书目录里的 plugin_data 由
  /// 各书自然遗留，不跨书清理。
  Future<void> uninstall(String id) async {
    final dir = Directory(dirFor(id));
    if (await dir.exists()) await dir.delete(recursive: true);
    await setEnabledRaw(id, null);
  }

  // ── 启停持久化（SharedPreferences 单 key JSON，沿用内置时代的
  // 「ziji.plugins.enabled」键——老用户的开关状态无缝继承） ──

  Future<Map<String, bool>> loadEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final e in decoded.entries) e.key.toString(): e.value == true,
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> saveEnabled(Map<String, bool> enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(enabled));
    } catch (_) {
      // 落盘失败不影响本次进程内的启停。
    }
  }

  /// 值为 null 时移除键（卸载用）。
  Future<void> setEnabledRaw(String id, bool? value) async {
    final enabled = await loadEnabled();
    if (value == null) {
      enabled.remove(id);
    } else {
      enabled[id] = value;
    }
    await saveEnabled(enabled);
  }
}
