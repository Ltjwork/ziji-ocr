import 'dart:convert';

/// 字迹外挂插件清单（.zjplugin 包内的 manifest.json）。
///
/// 插件是运行时导入的独立功能模块（Obsidian 式）：包体是一个 zip，
/// 根层（或单层子目录里）必须有 manifest.json 与入口 JS。清单描述
/// 插件身份、API 版本与申请的权限，宿主据此安装、校验与调度。
class PluginManifest {
  /// 稳定标识（安装目录名、虚拟域名、存储键前缀）。
  /// 只允许小写字母开头的小写字母/数字/下划线，2~31 字符。
  final String id;

  /// 显示名。
  final String name;

  /// 插件自身版本（语义化版本文本，仅展示与覆盖安装提示用）。
  final String version;

  /// 一句话功能说明。
  final String description;

  /// 作者（展示用，可空）。
  final String author;

  /// 插件所基于的字迹插件 API 大版本。与 [PluginHostApiVersion.current]
  /// 不一致时拒绝安装（大版本不兼容）。
  final int apiVersion;

  /// 最低应用版本（可空：低于该版本拒绝安装）。
  final String? minAppVersion;

  /// 入口脚本（相对插件根目录的路径，推荐 main.js）。
  final String entry;

  /// 设置页 HTML（相对路径；可空 = 插件没有设置页）。
  final String? settings;

  /// 列表图标名（宿主图标白名单里的名字；缺省 extension）。
  final String icon;

  /// 申请的权限集合（见 [PluginPermissions]）。
  final Set<String> permissions;

  const PluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.description,
    required this.author,
    required this.apiVersion,
    required this.entry,
    required this.icon,
    required this.permissions,
    this.minAppVersion,
    this.settings,
  });

  static PluginManifest? tryParse(String jsonText) {
    Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final j = Map<String, dynamic>.from(decoded);
    final id = j['id']?.toString() ?? '';
    final name = j['name']?.toString() ?? '';
    final version = j['version']?.toString() ?? '';
    final entry = j['entry']?.toString() ?? '';
    final apiVersion = (j['api_version'] as num?)?.toInt() ?? 0;
    final permissions = <String>{
      for (final v in (j['permissions'] as List? ?? const []))
        v.toString(),
    };
    if (!isValidId(id)) return null;
    if (name.trim().isEmpty) return null;
    if (version.trim().isEmpty) return null;
    if (entry.trim().isEmpty) return null;
    if (apiVersion <= 0) return null;
    final unknown = permissions.difference(PluginPermissions.all);
    if (unknown.isNotEmpty) return null;
    return PluginManifest(
      id: id,
      name: name.trim(),
      version: version.trim(),
      description: j['description']?.toString() ?? '',
      author: j['author']?.toString() ?? '',
      apiVersion: apiVersion,
      minAppVersion: j['min_app_version']?.toString(),
      entry: entry.trim(),
      settings: j['settings']?.toString().trim(),
      icon: j['icon']?.toString() ?? '',
      permissions: permissions,
    );
  }

  /// id 规则：小写字母开头，只含小写字母/数字/下划线，2~31 字符。
  static bool isValidId(String id) =>
      RegExp(r'^[a-z][a-z0-9_]{1,30}$').hasMatch(id);

  /// 虚拟主机名（WebView2 虚拟域名映射用；下划线不是合法域名字符）。
  String get virtualHost => '${id.replaceAll('_', '-')}.plugin.ziji';
}

/// 字迹插件 API 大版本。大版本变化 = 桥命令面不兼容；插件在 manifest
/// 里声明自己基于的版本，宿主只接受同大版本。
class PluginHostApiVersion {
  static const current = 1;
}

/// 权限常量与命令 → 所需权限的映射。
///
/// 权限在 manifest 里申请、安装时展示；桥分发器按命令逐一校验——未
/// 申请权限的命令返回错误，插件缺权限即功能缺失而不是静默放行。
class PluginPermissions {
  /// 自由访问任意网络（经宿主 HTTP 代理，免 CORS）。
  static const http = 'http';

  /// 插件私有存储（全局 + 按书两级）。
  static const storage = 'storage';

  /// 读书库与页标注。
  static const projectsRead = 'projects:read';

  /// 写回页标注（确认字块，宿主口径收口）。
  static const projectsWrite = 'projects:write';

  /// 调本地后端接口（缩略图等）。
  static const backend = 'backend';

  /// 构建识字任务包（宿主导出器代劳，返回临时 zip 能力路径）。
  static const export = 'export';

  static const all = {
    http,
    storage,
    projectsRead,
    projectsWrite,
    backend,
    export,
  };

  /// 桥命令 → 所需权限。未列出的命令（ui.*、app.info 等宿主自身
  /// 服务）不需要权限。
  static const Map<String, String> byCommand = {
    'http.request': http,
    'http.uploadFile': http,
    'storage.get': storage,
    'storage.set': storage,
    'storage.remove': storage,
    'storage.projectGet': storage,
    'storage.projectSet': storage,
    'storage.projectRemove': storage,
    'projects.list': projectsRead,
    'projects.readAnnotation': projectsRead,
    'projects.annotationMtimes': projectsRead,
    'projects.charUids': projectsRead,
    'projects.applyCharConfirmations': projectsWrite,
    'export.charPackage': export,
    'backend.get': backend,
    'backend.post': backend,
  };
}
