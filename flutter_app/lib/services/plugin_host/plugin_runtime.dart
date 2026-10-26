import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:webview_windows/webview_windows.dart';

import '../../pages/plugin_page_host.dart';
import 'plugin_bridge.dart';
import 'plugin_host_services.dart';
import 'plugin_icons.dart';
import 'plugin_store.dart';

/// 插件声明的功能入口描述符（ui.registerEntries 的宿主侧投影）。
///
/// 聚合处（编辑器「全书操作」菜单）只消费这个纯数据类：图标名经宿主
/// 白名单映射、打开动作走 [PluginHost.openEntry]——入口与聚合处彻底
/// 解耦，插件停用/卸载后注册表自然清空。
class PluginEntryDescriptor {
  const PluginEntryDescriptor({
    required this.pluginId,
    required this.entryKey,
    required this.title,
    required this.page,
    this.subtitle,
    this.icon = 'extension',
    this.requiresProject = false,
  });

  /// 插件 id（demo 等）。
  final String pluginId;

  /// 入口自身声明的 id（不带插件前缀）。
  final String entryKey;

  /// 全局稳定标识：`插件id.入口id`。
  String get id => '$pluginId.$entryKey';

  final String title;
  final String? subtitle;

  /// 打开时加载的页面（相对插件根目录的路径）。
  final String page;

  /// 图标名（宿主白名单）。
  final String icon;

  /// 需要书上下文（无书时不出现）。
  final bool requiresProject;

  IconData get iconData => pluginIconOf(icon);
}

/// 一次打开的插件页面会话（一个可见 WebView + 桥连接 + 回执道）。
class PluginPageSession {
  PluginPageSession({
    required this.plugin,
    required this.controller,
    required this.connection,
    required this.pageContext,
  });

  final InstalledPlugin plugin;
  final WebviewController controller;
  final PluginBridgeConnection connection;
  final PluginPageContext pageContext;

  /// 页面经 ui.closePage 提交的回执（pop 时由宿主读取）。
  Map<String, dynamic>? pendingResult;

  /// 页面组件注册的「请求关闭」回调（ui.closePage 触发 Navigator.pop）。
  void Function(Map<String, dynamic>? result)? requestClose;

  bool closed = false;
}

/// 一个启用插件的常驻运行时（隐藏 WebView，main.js 活动处所）。
class PluginRuntimeController {
  PluginRuntimeController({required this.plugin, required this.controller});

  final InstalledPlugin plugin;
  final WebviewController controller;
  bool disposed = false;
}

/// 插件状态行（识别监控悬浮窗展示）。
class PluginStatusLine {
  const PluginStatusLine({required this.text, required this.at});
  final String text;
  final DateTime at;
}

/// 插件宿主（单例 ChangeNotifier）：安装目录管理、运行时启停、入口
/// 注册表、页面会话、状态行。
///
/// 生命周期：应用启动（MaterialApp 就绪后）[load] 一次；启用插件的
/// main.js 在隐藏 WebView 里常驻，注册入口、跑后台任务；用户点入口
/// 时开一个可见 WebView 页面会话，页面用 ui.closePage 携带回执关闭。
class PluginHost extends ChangeNotifier implements PluginUiHooks {
  PluginHost._();

  static final PluginHost instance = PluginHost._();

  PluginStore? _store;
  ZijiPluginHostServices? _services;
  String? _pluginsRoot;

  final List<InstalledPlugin> _installed = [];
  final Map<String, bool> _enabled = {};
  final Map<String, PluginRuntimeController> _runtimes = {};

  /// 插件 id → 入口声明（ui.registerEntries 原样；停用/卸载即清）。
  final Map<String, List<Map<String, dynamic>>> _entriesByPlugin = {};

  /// 活动页面会话（桥连接 → 会话）。
  final Map<PluginBridgeConnection, PluginPageSession> _pageSessions = {};

  /// 各插件运行时的桥连接（页面 → 运行时事件转发用）。
  final Map<String, PluginBridgeConnection> _runtimeConnections = {};

  /// 悬浮窗状态行（插件 id → 最近状态）。
  final Map<String, PluginStatusLine> _statusLines = {};

  /// 运行时主动开页用的全局 Navigator（main.dart 接线）。
  GlobalKey<NavigatorState>? navigatorKey;

  bool _loaded = false;
  bool get loaded => _loaded;

  List<InstalledPlugin> get installed => List.unmodifiable(_installed);
  bool isEnabled(String id) => _enabled[id] ?? false;
  PluginStore? get store => _store;
  ZijiPluginHostServices? get services => _services;
  Map<String, PluginStatusLine> get statusLines =>
      Map.unmodifiable(_statusLines);

  /// 隐藏运行时表（运行时层渲染隐藏 WebView 用）。
  Iterable<PluginRuntimeController> get runtimes => _runtimes.values;

  InstalledPlugin? byId(String id) {
    for (final plugin in _installed) {
      if (plugin.id == id) return plugin;
    }
    return null;
  }

  /// 启动加载：解析目录、扫描已安装插件、按持久化开关启动运行时。
  /// 幂等；目录解析失败（测试环境无平台通道等）静默空载，不阻断启动。
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final support = await getApplicationSupportDirectory();
      _pluginsRoot = p.join(support.path, 'plugins');
    } catch (_) {
      _pluginsRoot = null;
    }
    if (_pluginsRoot == null) return;
    var appVersion = '';
    try {
      appVersion = (await PackageInfo.fromPlatform()).version;
    } catch (_) {}
    _services = ZijiPluginHostServices(appVersion: appVersion);
    _store = PluginStore(_pluginsRoot!);
    await _store!.ensureRoot();
    await _reloadInstalled();
    _enabled.addAll(await _store!.loadEnabled());
    // 只启动「已安装且启用」的插件；启停表里残留的已卸载项不管。
    for (final plugin in _installed) {
      if (_enabled[plugin.id] == true) {
        unawaited(_startRuntime(plugin));
      }
    }
    notifyListeners();
  }

  Future<void> _reloadInstalled() async {
    _installed
      ..clear()
      ..addAll(await _store!.listInstalled());
  }

  // ── 安装 / 卸载 ──

  Future<PluginInstallOutcome> installFromZip(String zipPath) async {
    final store = _store;
    if (store == null) {
      return const PluginInstallOutcome(PluginInstallResult.ioError, null);
    }
    final outcome = await store.installFromZip(
      zipPath,
      isRunning: (id) => _runtimes.containsKey(id),
      onStopBeforeReplace: _stopRuntime,
      onLog: (m) => _services?.addLog('[插件] $m', isError: true),
    );
    await _reloadInstalled();
    if (outcome.ok && outcome.id != null && _enabled[outcome.id] == true) {
      // 升级覆盖：文件已换新，重启运行时让新代码生效。
      final plugin = byId(outcome.id!);
      if (plugin != null) unawaited(_startRuntime(plugin));
    }
    notifyListeners();
    return outcome;
  }

  Future<void> uninstall(String id) async {
    await _stopRuntime(id);
    _entriesByPlugin.remove(id);
    _statusLines.remove(id);
    await _store?.uninstall(id);
    _enabled.remove(id);
    await _reloadInstalled();
    notifyListeners();
  }

  /// 重新加载一个插件：重读安装目录（插件文件被直接覆盖时取到新版
  /// 清单），停掉旧运行时与该插件已打开的页面，再按启停状态用新文件
  /// 重启运行时。开发迭代改完插件、把新文件覆盖进插件安装目录后点
  /// 这里的重载即可生效，无需重启应用。返回重读到的插件（目录已不
  /// 存在则返回 null，视同已卸载）。
  Future<InstalledPlugin?> reloadPlugin(String id) async {
    // 该插件已打开的页面跑的是旧代码，先按无回执关闭，避免新旧混跑。
    for (final session in _pageSessions.values.toList()) {
      if (session.plugin.id == id) {
        session.requestClose?.call(null);
      }
    }
    await _stopRuntime(id);
    _entriesByPlugin.remove(id);
    _statusLines.remove(id);
    await _reloadInstalled();
    final plugin = byId(id);
    if (plugin != null && _enabled[id] == true) {
      unawaited(_startRuntime(plugin));
    }
    notifyListeners();
    return plugin;
  }

  // ── 启停 ──

  Future<void> setEnabled(String id, bool value) async {
    _enabled[id] = value;
    await _store?.setEnabledRaw(id, value);
    if (value) {
      final plugin = byId(id);
      if (plugin != null) unawaited(_startRuntime(plugin));
    } else {
      await _stopRuntime(id);
      _entriesByPlugin.remove(id);
      _statusLines.remove(id);
    }
    notifyListeners();
  }

  Future<void> _startRuntime(InstalledPlugin plugin) async {
    if (_runtimes.containsKey(plugin.id)) return;
    final services = _services;
    if (services == null) return;
    final controller = WebviewController();
    try {
      await controller.initialize();
      await controller.setPopupWindowPolicy(
        WebviewPopupWindowPolicy.deny,
      );
      await controller.addVirtualHostNameMapping(
        plugin.manifest.virtualHost,
        plugin.dir,
        WebviewHostResourceAccessKind.allow,
      );
    } catch (e) {
      services.addLog(
        '[插件] ${plugin.manifest.name} 运行时启动失败（WebView2 不可用？）：$e',
        isError: true,
      );
      await controller.dispose();
      return;
    }
    final connection = PluginBridgeConnection(
      services: services,
      manifest: plugin.manifest,
      pluginDir: plugin.dir,
      kind: PluginBridgeKind.runtime,
      uiHooks: this,
    );
    connection.sendToJs = (text) {
      if (!_runtimes.containsKey(plugin.id)) return;
      unawaited(controller.postWebMessage(text));
    };
    controller.webMessage.listen((message) {
      unawaited(
        connection.handleMessage(message).then((reply) {
          if (reply != null) unawaited(controller.postWebMessage(reply));
        }).catchError((Object e) {
          services.addLog(
            '[插件] ${plugin.manifest.name} 桥回包失败：$e',
            isError: true,
          );
        }),
      );
    });
    _runtimes[plugin.id] = PluginRuntimeController(
      plugin: plugin,
      controller: controller,
    );
    _runtimeConnections[plugin.id] = connection;
    notifyListeners();
    // 引导页：桥 JS 内嵌 + 入口脚本从虚拟域名加载（https 源，本地文件
    // 不经网络）。
    final entry = _htmlEscapeAttr(plugin.manifest.entry);
    unawaited(
      controller.loadStringContent(
        '<!doctype html><html><head><meta charset="utf-8">'
        '<script>$pluginBridgeJs</script>'
        '</head><body>'
        '<script src="https://${plugin.manifest.virtualHost}/$entry"></script>'
        '</body></html>',
      ),
    );
  }

  Future<void> _stopRuntime(String id) async {
    final runtime = _runtimes.remove(id);
    _runtimeConnections.remove(id);
    if (runtime == null) return;
    runtime.disposed = true;
    try {
      await runtime.controller.dispose();
    } catch (_) {}
    notifyListeners();
  }

  static String _htmlEscapeAttr(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('"', '&quot;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  // ── 入口聚合（聚合处消费的面） ──

  /// 启用中插件声明的入口（requiresProject 且无书上下文时省略）。
  /// 只看运行时活着的插件——入口由 main.js 注册，运行时不在=没入口。
  List<PluginEntryDescriptor> enabledEntries({String? projectDir}) {
    final entries = <PluginEntryDescriptor>[];
    _entriesByPlugin.forEach((pluginId, list) {
      if (!_runtimes.containsKey(pluginId)) return;
      for (final e in list) {
        final requiresProject = e['requiresProject'] == true;
        if (requiresProject && (projectDir == null || projectDir.isEmpty)) {
          continue;
        }
        entries.add(
          PluginEntryDescriptor(
            pluginId: pluginId,
            entryKey: e['id']?.toString() ?? '',
            title: e['title']?.toString() ?? '',
            subtitle: e['subtitle']?.toString(),
            page: e['page']?.toString() ?? '',
            icon: e['icon']?.toString() ?? 'extension',
            requiresProject: requiresProject,
          ),
        );
      }
    });
    return entries;
  }

  // ── 页面会话 ──

  /// 打开一个插件页面（入口/设置页/运行时主动开页共用）。
  Future<Map<String, dynamic>?> openPage({
    required InstalledPlugin plugin,
    required String page,
    required PluginPageContext pageContext,
    String? title,
  }) async {
    final services = _services;
    final navigator = navigatorKey?.currentState;
    if (services == null || navigator == null) return null;
    final controller = WebviewController();
    try {
      await controller.initialize();
      await controller.setPopupWindowPolicy(
        WebviewPopupWindowPolicy.deny,
      );
      await controller.addVirtualHostNameMapping(
        plugin.manifest.virtualHost,
        plugin.dir,
        WebviewHostResourceAccessKind.allow,
      );
      // 桥 JS 必须在页面任何脚本之前就位（文档创建时注入）。
      await controller.addScriptToExecuteOnDocumentCreated(pluginBridgeJs);
    } catch (e) {
      services.addLog(
        '[插件] ${plugin.manifest.name} 页面启动失败（WebView2 不可用？）：$e',
        isError: true,
      );
      await controller.dispose();
      return null;
    }
    final connection = PluginBridgeConnection(
      services: services,
      manifest: plugin.manifest,
      pluginDir: plugin.dir,
      kind: PluginBridgeKind.page,
      pageContext: pageContext,
      uiHooks: this,
    );
    final session = PluginPageSession(
      plugin: plugin,
      controller: controller,
      connection: connection,
      pageContext: pageContext,
    );
    connection.sendToJs = (text) {
      if (session.closed) return;
      unawaited(controller.postWebMessage(text));
    };
    _pageSessions[connection] = session;
    controller.webMessage.listen((message) {
      unawaited(
        connection.handleMessage(message).then((reply) {
          if (reply != null && !session.closed) {
            unawaited(controller.postWebMessage(reply));
          }
        }).catchError((Object e) {
          services.addLog(
            '[插件] ${plugin.manifest.name} 页面桥回包失败：$e',
            isError: true,
          );
        }),
      );
    });
    unawaited(
      controller.loadUrl(
        'https://${plugin.manifest.virtualHost}/${_htmlEscapeAttr(page)}',
      ),
    );
    final result = await navigator.push(
      MaterialPageRoute<Map<String, dynamic>?>(
        builder: (_) => PluginPageHostWidget(session: session, title: title),
      ),
    );
    await _disposePageSession(session);
    return result;
  }

  Future<void> _disposePageSession(PluginPageSession session) async {
    if (session.closed) return;
    session.closed = true;
    _pageSessions.remove(session.connection);
    try {
      await session.controller.dispose();
    } catch (_) {}
  }

  /// 入口打开（编辑器等聚合处调用）：返回回执里的 modifiedPages（0 基
  /// 页序集合；无回执 = null）。
  Future<Set<int>?> openEntry(
    PluginEntryDescriptor entry, {
    String? projectDir,
    String? projectName,
    int pageIndex = 0,
    String? pageId,
  }) async {
    final plugin = byId(entry.pluginId);
    if (plugin == null || entry.page.isEmpty) return null;
    final result = await openPage(
      plugin: plugin,
      page: entry.page,
      pageContext: PluginPageContext(
        projectDir: projectDir,
        projectName: projectName,
        pageIndex: pageIndex,
        pageId: pageId,
        entryId: entry.id,
      ),
      title: entry.title,
    );
    final pages = result?['modifiedPages'];
    if (pages is List) {
      return {
        for (final v in pages)
          if (v is num) v.toInt(),
      };
    }
    return null;
  }

  /// 插件设置页（manifest.settings 声明的 HTML）。
  Future<void> openSettings(
    BuildContext context,
    InstalledPlugin plugin,
  ) async {
    final settings = plugin.manifest.settings;
    if (settings == null || settings.isEmpty) return;
    await openPage(
      plugin: plugin,
      page: settings,
      pageContext: const PluginPageContext(),
      title: '${plugin.manifest.name} · 设置',
    );
  }

  // ── PluginUiHooks（桥 ui.* 命令的落点） ──

  @override
  void registerEntries(String pluginId, List<Map<String, dynamic>> entries) {
    _entriesByPlugin[pluginId] = entries;
    notifyListeners();
  }

  @override
  void openPluginPage(String pluginId, Map<String, dynamic> spec) {
    final plugin = byId(pluginId);
    final page = spec['page']?.toString();
    if (plugin == null || page == null || page.isEmpty) return;
    unawaited(
      openPage(
        plugin: plugin,
        page: page,
        pageContext: const PluginPageContext(),
        title: spec['title']?.toString(),
      ),
    );
  }

  @override
  void closePage(
    PluginBridgeConnection connection,
    Map<String, dynamic>? result,
  ) {
    final session = _pageSessions[connection];
    if (session == null || session.closed) return;
    session.pendingResult = result;
    session.requestClose?.call(result);
  }

  @override
  void setStatus(String pluginId, String text) {
    if (text.isEmpty) {
      _statusLines.remove(pluginId);
    } else {
      _statusLines[pluginId] = PluginStatusLine(
        text: text,
        at: DateTime.now(),
      );
    }
    notifyListeners();
  }

  @override
  void emitToRuntime(String pluginId, String event, Object? payload) {
    _runtimeConnections[pluginId]?.emit(event, payload);
  }
}

/// 隐藏运行时层：挂在全局 Stack 里的零面积不可见区域，承载启用插件
/// 的常驻 WebView（main.js 的活动处所）。透明度 0 + 1×1 尺寸保留布局
/// 与合成路径（WebView2 纹理需要真实表面），IgnorePointer 挡输入。
class PluginRuntimeLayer extends StatelessWidget {
  const PluginRuntimeLayer({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: PluginHost.instance,
      builder: (context, _) {
        final runtimes = PluginHost.instance.runtimes.toList();
        if (runtimes.isEmpty) return const SizedBox.shrink();
        return IgnorePointer(
          child: Opacity(
            opacity: 0,
            child: SizedBox(
              width: 1,
              height: 1,
              child: Stack(
                children: [
                  for (final runtime in runtimes)
                    Webview(runtime.controller),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
