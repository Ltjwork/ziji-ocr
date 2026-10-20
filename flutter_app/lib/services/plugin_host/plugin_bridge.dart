import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'plugin_manifest.dart';

/// 桥协议版本标记（消息 JSON 里的 `z` 字段）。
/// - JS → Dart：请求 `{z:1, id, cmd, payload}`；
/// - Dart → JS：回执 `{z:2, id, ok, data|error}` 或事件 `{z:3, event, payload}`。
const int _kMsgRequest = 1;
const int _kMsgReply = 2;
const int _kMsgEvent = 3;

/// 一个 HTTP 响应（桥 `http.*` 命令的统一回包；body 一律按 UTF-8 文本
/// 回传——插件面向 JSON 接口，二进制素材走 backend 缩略图的 base64）。
class PluginHttpResponse {
  const PluginHttpResponse({
    required this.status,
    required this.headers,
    required this.body,
  });

  final int status;
  final Map<String, String> headers;
  final String body;

  Map<String, dynamic> toJson() => {
    'status': status,
    'headers': headers,
    'body': body,
  };
}

/// 宿主能力注入面：桥分发器只依赖这个接口。生产实现由 PluginHost
/// 提供（真网络/真文件/真后端）；单测注入假实现即可全链路验证协议。
abstract class PluginHostServices {
  String get appVersion;

  /// 书库根目录（文档目录/GujiBT）。
  Future<String?> booksRoot();

  /// 本地后端 GET：path 以 `/` 开头（如 `/char_thumbnails`）。
  Future<Map<String, dynamic>> backendGet(
    String path,
    Map<String, String>? query,
  );

  /// 本地后端 POST（JSON 请求/响应）。
  Future<Map<String, dynamic>> backendPost(
    String path,
    Map<String, dynamic> body,
  );

  /// 书列表（按书名排序）：{dir, name, pageCount, lastPageIndex}。
  Future<List<Map<String, dynamic>>> listProjects();

  /// 页标注的紧凑投影（见实现注释；null = 无标注）。
  Future<Map<String, dynamic>?> readAnnotationCompact(
    String projectDir,
    String pageId,
  );

  /// 该书全部标注文件的 {pageId: mtimeMs}。
  Future<Map<String, int>> annotationMtimes(String projectDir);

  /// 计算识字数据包口径的 char_uid（源图 sha256 由宿主缓存）。
  /// 批量：一次一页（逐字往返太碎）。
  Future<List<String>> charUids({
    required String projectDir,
    required String pageId,
    required List<({int x, int y, int w, int h, int order})> chars,
  });

  /// 构建识字任务包（宿主导出器）：返回临时 zip 能力路径与任务字数。
  Future<({String zipPath, int taskCount})> exportCharPackage({
    required String projectDir,
    required Set<String> pageIds,
    required Set<String> onlyCharUids,
  });

  /// 释放能力路径（删除宿主临时产物）。
  Future<void> releaseCapability(String path);

  /// 按字块 id 写回文字并确认（confirmCharsById 级联 + 行文本重拼 +
  /// saveAnnotation，与「确认并保存」同口径）。返回 (改到的字块 id，
  /// 未匹配到的字块 id)。
  Future<(List<String>, List<String>)> applyCharConfirmations({
    required String projectDir,
    required String pageId,
    required List<({String id, String text})> chars,
  });

  /// 通用 HTTP（宿主代理，免 CORS）。
  Future<PluginHttpResponse> httpRequest({
    required String method,
    required String url,
    Map<String, String>? headers,
    String? body,
    int? timeoutMs,
  });

  /// multipart 上传一个能力路径文件。
  Future<PluginHttpResponse> httpUploadFile({
    required String url,
    required String filePath,
    Map<String, String>? fields,
    Map<String, String>? headers,
    int? timeoutMs,
  });

  void addLog(String text, {bool isError = false});
}

/// 连接种类：隐藏运行时（main.js 常驻）或一次打开的页面会话。
enum PluginBridgeKind { runtime, page }

/// 页面会话的打开上下文（入口从编辑器打开时携带书与页）。
class PluginPageContext {
  const PluginPageContext({
    this.projectDir,
    this.projectName,
    this.pageIndex = 0,
    this.entryId,
  });

  final String? projectDir;
  final String? projectName;
  final int pageIndex;
  final String? entryId;

  Map<String, dynamic> toJson() => {
    if (projectDir != null) 'projectDir': projectDir,
    if (projectName != null) 'projectName': projectName,
    'pageIndex': pageIndex,
    if (entryId != null) 'entryId': entryId,
  };
}

/// ui.* 命令回落到宿主 UI 层的钩子（注册入口 / 开页 / 关页 / 状态行）。
abstract class PluginUiHooks {
  /// 运行时注册功能入口（entrys 原样来自插件声明）。
  void registerEntries(String pluginId, List<Map<String, dynamic>> entries);

  /// 运行时主动开一个插件页面（入口之外的路径，如设置页自查跳转）。
  void openPluginPage(String pluginId, Map<String, dynamic> spec);

  /// 页面会话请求关闭（携带回执 result，可空）。
  void closePage(PluginBridgeConnection connection, Map<String, dynamic>? result);

  /// 插件状态行（识别监控悬浮窗展示：一行最近状态文本）。
  void setStatus(String pluginId, String text);

  /// 页面会话向本插件的运行时（main.js）转发事件（如「立即同步」）。
  void emitToRuntime(String pluginId, String event, Object? payload);
}

/// 一条 WebView 连接（运行时或页面会话）对应的桥端点：解析 JS 消息、
/// 校验权限、分发命令、回包。
class PluginBridgeConnection {
  PluginBridgeConnection({
    required this.services,
    required this.manifest,
    required this.pluginDir,
    required this.kind,
    this.pageContext,
    PluginUiHooks? uiHooks,
  }) : _uiHooks = uiHooks;

  final PluginHostServices services;
  final PluginManifest manifest;
  final String pluginDir;
  final PluginBridgeKind kind;
  final PluginPageContext? pageContext;
  final PluginUiHooks? _uiHooks;

  /// 发往 JS 的事件出口（由 WebView 层接线：postWebMessage）。
  void Function(String jsonText)? sendToJs;

  /// 存储写串行链（同插件并发 storage.set 不交叉写坏文件）。
  static final Map<String, Future<void>> _storageChains = {};

  /// 处理一条来自 JS 的消息（WebMessage 流的元素，字符串 JSON）。
  /// 非本协议消息直接忽略（返回 null）。
  Future<String?> handleMessage(dynamic raw) async {
    if (raw is! String) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final j = Map<String, dynamic>.from(decoded);
    if (j['z'] != _kMsgRequest) return null;
    final id = j['id'];
    final cmd = j['cmd']?.toString() ?? '';
    final payload = j['payload'];
    try {
      final data = await _dispatch(cmd, payload);
      return jsonEncode({'z': _kMsgReply, 'id': id, 'ok': true, 'data': data});
    } catch (error) {
      return jsonEncode({
        'z': _kMsgReply,
        'id': id,
        'ok': false,
        'error': error.toString(),
      });
    }
  }

  /// 向 JS 推事件。
  void emit(String event, Object? payload) {
    sendToJs?.call(
      jsonEncode({'z': _kMsgEvent, 'event': event, 'payload': payload}),
    );
  }

  Future<Object?> _dispatch(String cmd, Object? payload) async {
    // 权限闸门：命令 → manifest 申请。
    final required = PluginPermissions.byCommand[cmd];
    if (required != null && !manifest.permissions.contains(required)) {
      throw StateError('插件未申请权限「$required」，命令 $cmd 被拒绝');
    }
    final args = payload is Map
        ? Map<String, dynamic>.from(payload)
        : const <String, dynamic>{};
    switch (cmd) {
      case 'app.info':
        return {
          'appVersion': services.appVersion,
          'apiVersion': PluginHostApiVersion.current,
          'pluginId': manifest.id,
          'booksRoot': await services.booksRoot(),
        };
      case 'app.setStatus':
        _uiHooks?.setStatus(manifest.id, args['text']?.toString() ?? '');
        return null;
      case 'app.emit':
        _uiHooks?.emitToRuntime(
          manifest.id,
          args['event']?.toString() ?? '',
          args['payload'],
        );
        return null;
      case 'app.log':
        services.addLog(
          '[插件·${manifest.name}] ${args['text']?.toString() ?? ''}',
          isError: args['isError'] == true,
        );
        return null;
      case 'storage.get':
      case 'storage.set':
      case 'storage.remove':
      case 'storage.projectGet':
      case 'storage.projectSet':
      case 'storage.projectRemove':
        return _storage(cmd, args);
      case 'http.request':
        return _httpRequest(args);
      case 'http.uploadFile':
        return _httpUploadFile(args);
      case 'backend.get':
        final query = args['query'] is Map
            ? Map<String, String>.from(
                (args['query'] as Map).map(
                  (k, v) => MapEntry(k.toString(), v.toString()),
                ),
              )
            : null;
        return services.backendGet(
          args['path']?.toString() ?? '',
          query == null || query.isEmpty ? null : query,
        );
      case 'backend.post':
        final bodyRaw = args['body'];
        final body = bodyRaw is Map ? Map<String, dynamic>.from(bodyRaw) : const <String, dynamic>{};
        return services.backendPost(
          args['path']?.toString() ?? '',
          Map<String, dynamic>.from(body),
        );
      case 'projects.list':
        return services.listProjects();
      case 'projects.readAnnotation':
        return services.readAnnotationCompact(
          args['projectDir']?.toString() ?? '',
          args['pageId']?.toString() ?? '',
        );
      case 'projects.annotationMtimes':
        return services.annotationMtimes(args['projectDir']?.toString() ?? '');
      case 'projects.charUids':
        final chars = [
          for (final c in (args['chars'] as List? ?? const []))
            if (c is Map)
              (
                x: (c['x'] as num?)?.toInt() ?? 0,
                y: (c['y'] as num?)?.toInt() ?? 0,
                w: (c['w'] as num?)?.toInt() ?? 0,
                h: (c['h'] as num?)?.toInt() ?? 0,
                order: (c['order'] as num?)?.toInt() ?? 0,
              ),
        ];
        return services.charUids(
          projectDir: args['projectDir']?.toString() ?? '',
          pageId: args['pageId']?.toString() ?? '',
          chars: chars,
        );
      case 'projects.applyCharConfirmations':
        final chars = [
          for (final c in (args['chars'] as List? ?? const []))
            if (c is Map)
              (
                id: c['id']?.toString() ?? '',
                text: c['text']?.toString() ?? '',
              ),
        ];
        final (applied, unmatched) = await services.applyCharConfirmations(
          projectDir: args['projectDir']?.toString() ?? '',
          pageId: args['pageId']?.toString() ?? '',
          chars: chars,
        );
        return {'appliedIds': applied, 'unmatchedIds': unmatched};
      case 'export.charPackage':
        return services.exportCharPackage(
          projectDir: args['projectDir']?.toString() ?? '',
          pageIds: {
            for (final v in (args['pageIds'] as List? ?? const []))
              v.toString(),
          },
          onlyCharUids: {
            for (final v in (args['onlyCharUids'] as List? ?? const []))
              v.toString(),
          },
        ).then(
          (r) => {'filePath': r.zipPath, 'taskCount': r.taskCount},
        );
      case 'fs.release':
        await services.releaseCapability(args['path']?.toString() ?? '');
        return null;
      case 'ui.registerEntries':
        if (kind != PluginBridgeKind.runtime) {
          throw StateError('ui.registerEntries 只能在插件主脚本（main.js）里调用');
        }
        final entries = [
          for (final e in (args['entries'] as List? ?? const []))
            if (e is Map) Map<String, dynamic>.from(e),
        ];
        _uiHooks?.registerEntries(manifest.id, entries);
        return null;
      case 'ui.openPage':
        // 页面会话也允许开页（如回流校对页跳设置页），宿主叠加新路由。
        _uiHooks?.openPluginPage(manifest.id, args);
        return null;
      case 'ui.closePage':
        if (kind != PluginBridgeKind.page) {
          throw StateError('ui.closePage 只能在插件页面里调用');
        }
        _uiHooks?.closePage(
          this,
          args['result'] is Map
              ? Map<String, dynamic>.from(args['result'] as Map)
              : null,
        );
        return null;
      case 'ui.getContext':
        if (kind != PluginBridgeKind.page) {
          throw StateError('ui.getContext 只能在插件页面里调用');
        }
        return pageContext?.toJson() ?? const {};
      default:
        throw StateError('未知命令：$cmd');
    }
  }

  // ── 存储实现：全局 <插件目录>/data/global.json；按书
  // {书目录}/plugin_data/<插件id>.json。同文件读改写按链串行。 ──

  Future<Object?> _storage(String cmd, Map<String, dynamic> args) async {
    final key = args['key']?.toString();
    if (key == null || key.isEmpty) throw StateError('storage 命令缺 key');
    final projectDir = args['projectDir']?.toString();
    final file = projectDir == null || projectDir.isEmpty
        ? File(p.join(pluginDir, 'data', 'global.json'))
        : File(p.join(projectDir, 'plugin_data', '${manifest.id}.json'));

    Future<Object?> run() async {
      Map<String, dynamic> map = {};
      try {
        if (await file.exists()) {
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is Map) map = Map<String, dynamic>.from(decoded);
        }
      } catch (_) {
        // 损坏按空表处理（插件存储是自留地，重建即可）。
      }
      switch (cmd) {
        case 'storage.get':
        case 'storage.projectGet':
          return map[key];
        case 'storage.set':
        case 'storage.projectSet':
          map[key] = args['value'];
          await _writeStorage(file, map);
          return null;
        case 'storage.remove':
        case 'storage.projectRemove':
          map.remove(key);
          await _writeStorage(file, map);
          return null;
      }
      return null;
    }

    final previous = _storageChains[file.path] ?? Future<void>.value();
    final completer = Completer<void>();
    _storageChains[file.path] = completer.future;
    late final Object? result;
    try {
      await previous;
      result = await run();
    } finally {
      completer.complete();
      if (identical(_storageChains[file.path], completer.future)) {
        _storageChains.remove(file.path);
      }
    }
    return result;
  }

  Future<void> _writeStorage(File file, Map<String, dynamic> map) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(map),
      flush: true,
    );
  }

  static Map<String, String>? _stringMap(Object? value) {
    if (value is! Map) return null;
    return Map<String, String>.from(
      value.map((k, v) => MapEntry(k.toString(), v.toString())),
    );
  }

  Future<Object?> _httpRequest(Map<String, dynamic> args) async {
    final r = await services.httpRequest(
      method: args['method']?.toString() ?? 'GET',
      url: args['url']?.toString() ?? '',
      headers: _stringMap(args['headers']),
      body: args['body']?.toString(),
      timeoutMs: (args['timeoutMs'] as num?)?.toInt(),
    );
    return r.toJson();
  }

  Future<Object?> _httpUploadFile(Map<String, dynamic> args) async {
    final r = await services.httpUploadFile(
      url: args['url']?.toString() ?? '',
      filePath: args['filePath']?.toString() ?? '',
      fields: _stringMap(args['fields']),
      headers: _stringMap(args['headers']),
      timeoutMs: (args['timeoutMs'] as num?)?.toInt(),
    );
    return r.toJson();
  }
}

/// 注入 [PluginBridgeConnection.handleMessage] 的桥 JS 源（页面会话用
/// addScriptToExecuteOnDocumentCreated 在文档创建前注入，保证页面脚本
/// 跑起来时 window.ziji 已就绪；运行时用内嵌 <script> 同源注入）。
const String pluginBridgeJs = '''
(function () {
  var seq = 0;
  var pending = new Map();
  function post(m) {
    try { window.chrome.webview.postMessage(JSON.stringify(m)); } catch (e) {}
  }
  window.chrome.webview.addEventListener('message', function (e) {
    var m;
    try { m = typeof e.data === 'string' ? JSON.parse(e.data) : e.data; }
    catch (err) { return; }
    if (!m) return;
    if (m.z === 2) {
      var p = pending.get(m.id);
      if (p) {
        pending.delete(m.id);
        if (m.ok) p.resolve(m.data); else p.reject(new Error(m.error || 'error'));
      }
    } else if (m.z === 3) {
      window.dispatchEvent(new CustomEvent('ziji:' + m.event, { detail: m.payload }));
    }
  });
  window.ziji = {
    invoke: function (cmd, payload) {
      return new Promise(function (resolve, reject) {
        var id = ++seq;
        pending.set(id, { resolve: resolve, reject: reject });
        post({ z: 1, id: id, cmd: cmd, payload: payload === undefined ? null : payload });
      });
    },
    on: function (event, handler) {
      window.addEventListener('ziji:' + event, function (e) { handler(e.detail); });
    },
  };
})();
''';
