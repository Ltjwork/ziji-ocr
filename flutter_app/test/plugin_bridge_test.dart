// 插件桥：协议回包、权限闸门、存储读写、ui.* 钩子与宿主服务代理的
// 分发（FakeServices 注入，WebView 层不在单测范围内）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/services/plugin_host/plugin_bridge.dart';
import 'package:gujichazi/services/plugin_host/plugin_manifest.dart';

class FakeServices implements PluginHostServices {
  FakeServices({
    this.projects = const [],
    this.annotations = const {},
    this.httpResponse = const PluginHttpResponse(
      status: 200,
      headers: {},
      body: '{"success":true}',
    ),
  });

  final List<Map<String, dynamic>> projects;
  final Map<String, Map<String, dynamic>?> annotations;
  PluginHttpResponse httpResponse;
  String? lastUploadPath;
  List<String> logs = [];

  @override
  String appVersion = '1.0.2';

  @override
  Future<String?> booksRoot() async => 'Z:/books';

  @override
  Future<Map<String, dynamic>> backendGet(path, query) async => {'ok': true};

  @override
  Future<Map<String, dynamic>> backendPost(path, body) async => {'echo': body};

  @override
  Future<List<Map<String, dynamic>>> listProjects() async => projects;

  @override
  Future<Map<String, dynamic>?> readAnnotationCompact(
    String projectDir,
    String pageId,
  ) async => annotations['$projectDir/$pageId'];

  @override
  Future<Map<String, int>> annotationMtimes(String projectDir) async => {};

  @override
  Future<List<String>> charUids({
    required String projectDir,
    required String pageId,
    required List<({int x, int y, int w, int h, int order})> chars,
  }) async => [for (var i = 0; i < chars.length; i++) 'uid-$i'];

  @override
  Future<({String zipPath, int taskCount})> exportCharPackage({
    required String projectDir,
    required Set<String> pageIds,
    required Set<String> onlyCharUids,
  }) async => (zipPath: 'C:/tmp/pkg.zip', taskCount: onlyCharUids.length);

  @override
  Future<void> releaseCapability(String path) async {}

  @override
  Future<(List<String>, List<String>)> applyCharConfirmations({
    required String projectDir,
    required String pageId,
    required List<({String id, String text})> chars,
  }) async => ([for (final c in chars) c.id], <String>[]);

  @override
  Future<PluginHttpResponse> httpRequest({
    required String method,
    required String url,
    Map<String, String>? headers,
    String? body,
    int? timeoutMs,
  }) async => httpResponse;

  @override
  Future<PluginHttpResponse> httpUploadFile({
    required String url,
    required String filePath,
    Map<String, String>? fields,
    Map<String, String>? headers,
    int? timeoutMs,
  }) async {
    lastUploadPath = filePath;
    return httpResponse;
  }

  @override
  void addLog(String text, {bool isError = false}) => logs.add(text);
}

class FakeHooks implements PluginUiHooks {
  final List<(String, List<Map<String, dynamic>>)> registered = [];
  final List<(String, Map<String, dynamic>)> opened = [];
  final List<(PluginBridgeConnection, Map<String, dynamic>?)> closed = [];
  final List<(String, String)> statuses = [];
  final List<(String, String, Object?)> emitted = [];

  @override
  void registerEntries(String pluginId, List<Map<String, dynamic>> entries) =>
      registered.add((pluginId, entries));

  @override
  void openPluginPage(String pluginId, Map<String, dynamic> spec) =>
      opened.add((pluginId, spec));

  @override
  void closePage(
    PluginBridgeConnection connection,
    Map<String, dynamic>? result,
  ) => closed.add((connection, result));

  @override
  void setStatus(String pluginId, String text) => statuses.add((pluginId, text));

  @override
  void emitToRuntime(String pluginId, String event, Object? payload) =>
      emitted.add((pluginId, event, payload));
}

PluginManifest _manifest({Set<String> permissions = const {}}) =>
    PluginManifest.tryParse(jsonEncode({
      'id': 'demo',
      'name': '演示',
      'version': '1.0.0',
      'entry': 'main.js',
      'api_version': 1,
      'permissions': permissions.toList(),
    }))!;

Future<Map<String, dynamic>> roundTrip(
  PluginBridgeConnection conn,
  int id,
  String cmd,
  Object? payload,
) async {
  final reply = await conn.handleMessage(
    jsonEncode({'z': 1, 'id': id, 'cmd': cmd, 'payload': payload}),
  );
  return Map<String, dynamic>.from(jsonDecode(reply!));
}

void main() {
  late Directory tmp;
  late FakeServices services;
  late FakeHooks hooks;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('plugin_bridge_test');
    services = FakeServices();
    hooks = FakeHooks();
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  PluginBridgeConnection conn({
    Set<String> permissions = const {},
    PluginBridgeKind kind = PluginBridgeKind.runtime,
    PluginPageContext? pageContext,
  }) => PluginBridgeConnection(
    services: services,
    manifest: _manifest(permissions: permissions),
    pluginDir: '${tmp.path}/demo',
    kind: kind,
    pageContext: pageContext,
    uiHooks: hooks,
  );

  test('协议：非桥消息忽略，合法请求回包 id 对应', () async {
    final c = conn();
    expect(await c.handleMessage('hello'), isNull);
    expect(await c.handleMessage('42'), isNull);
    final ok = await roundTrip(c, 7, 'app.info', null);
    expect(ok['id'], 7);
    expect(ok['ok'], true);
    expect(ok['data']['appVersion'], '1.0.2');
    expect(ok['data']['booksRoot'], 'Z:/books');
  });

  test('未知命令回错误，不抛出', () async {
    final c = conn();
    final r = await roundTrip(c, 1, 'nope.cmd', null);
    expect(r['ok'], false);
    expect(r['error'], contains('未知命令'));
  });

  test('权限闸门：未申请 http 时 http.request 被拒', () async {
    final c = conn();
    final denied = await roundTrip(c, 1, 'http.request', {
      'method': 'GET',
      'url': 'https://example.com',
    });
    expect(denied['ok'], false);
    expect(denied['error'], contains('权限'));

    final allowed = conn(permissions: {PluginPermissions.http});
    final ok = await roundTrip(allowed, 1, 'http.request', {
      'method': 'GET',
      'url': 'https://example.com',
      'headers': {'X-Test': '1'},
    });
    expect(ok['ok'], true);
    expect(ok['data']['status'], 200);
    expect(ok['data']['body'], contains('success'));
  });

  test('存储：全局与按书两级读写往返（真实临时目录）', () async {
    final c = conn(permissions: {PluginPermissions.storage});
    await roundTrip(c, 1, 'storage.set', {'key': 'k', 'value': [1, 2]});
    final got = await roundTrip(c, 2, 'storage.get', {'key': 'k'});
    expect(got['data'], [1, 2]);

    final bookDir = '${tmp.path}/books/b1';
    await roundTrip(c, 3, 'storage.projectSet', {
      'projectDir': bookDir,
      'key': 'enabled',
      'value': true,
    });
    final pg = await roundTrip(c, 4, 'storage.projectGet', {
      'projectDir': bookDir,
      'key': 'enabled',
    });
    expect(pg['data'], true);

    // 落盘位置与格式。
    final global = File('${tmp.path}/demo/data/global.json');
    expect(jsonDecode(global.readAsStringSync()), {
      'k': [1, 2],
    });
    final perBook = File('$bookDir/plugin_data/demo.json');
    expect(perBook.existsSync(), isTrue);

    await roundTrip(c, 5, 'storage.remove', {'key': 'k'});
    final removed = await roundTrip(c, 6, 'storage.get', {'key': 'k'});
    expect(removed['data'], isNull);
  });

  test('ui.registerEntries 只在运行时连接可用', () async {
    final runtime = conn();
    final r = await roundTrip(runtime, 1, 'ui.registerEntries', {
      'entries': [
        {'id': 'review', 'title': '回流', 'page': 'review.html'},
      ],
    });
    expect(r['ok'], true);
    expect(hooks.registered.single.$1, 'demo');

    final page = conn(kind: PluginBridgeKind.page);
    final denied = await roundTrip(page, 1, 'ui.registerEntries', {
      'entries': [],
    });
    expect(denied['ok'], false);
  });

  test('页面会话：ui.getContext 回打开上下文，ui.closePage 携带回执', () async {
    final page = conn(
      kind: PluginBridgeKind.page,
      pageContext: const PluginPageContext(
        projectDir: 'Z:/books/b1',
        projectName: '测试书',
        pageIndex: 3,
        entryId: 'demo.review',
      ),
    );
    final ctxReply = await roundTrip(page, 1, 'ui.getContext', null);
    expect(ctxReply['data'], {
      'projectDir': 'Z:/books/b1',
      'projectName': '测试书',
      'pageIndex': 3,
      'entryId': 'demo.review',
    });

    final close = await roundTrip(page, 2, 'ui.closePage', {
      'result': {'modifiedPages': [2, 5]},
    });
    expect(close['ok'], true);
    expect(hooks.closed.single.$2, {'modifiedPages': [2, 5]});
  });

  test('app.setStatus / app.emit / app.log 落到钩子与日志', () async {
    final c = conn();
    await roundTrip(c, 1, 'app.setStatus', {'text': '同步中'});
    expect(hooks.statuses.single, ('demo', '同步中'));

    await roundTrip(c, 2, 'app.emit', {
      'event': 'syncNow',
      'payload': {'projectDir': 'Z:/books/b1'},
    });
    expect(hooks.emitted.single.$1, 'demo');
    expect(hooks.emitted.single.$2, 'syncNow');
    expect(hooks.emitted.single.$3, {'projectDir': 'Z:/books/b1'});

    await roundTrip(c, 3, 'app.log', {'text': '一条日志'});
    expect(services.logs.single, contains('演示'));
  });

  test('export.charPackage → http.uploadFile：能力路径直传', () async {
    final c = conn(permissions: {
      PluginPermissions.export,
      PluginPermissions.http,
    });
    final exported = await roundTrip(c, 1, 'export.charPackage', {
      'projectDir': 'Z:/books/b1',
      'pageIds': ['page_001'],
      'onlyCharUids': ['uid-0', 'uid-1'],
    });
    expect(exported['data']['filePath'], 'C:/tmp/pkg.zip');
    expect(exported['data']['taskCount'], 2);

    final uploaded = await roundTrip(c, 2, 'http.uploadFile', {
      'url': 'https://srv/api/admin/crowd/import',
      'filePath': 'C:/tmp/pkg.zip',
      'fields': {'name': '书·识字同步', 'batch_id': '7'},
    });
    expect(uploaded['ok'], true);
    expect(services.lastUploadPath, 'C:/tmp/pkg.zip');
  });

  test('projects.applyCharConfirmations 代理写回', () async {
    final c = conn(permissions: {PluginPermissions.projectsWrite});
    final r = await roundTrip(c, 1, 'projects.applyCharConfirmations', {
      'projectDir': 'Z:/books/b1',
      'pageId': 'page_001',
      'chars': [
        {'id': 'b1', 'text': '之'},
      ],
    });
    expect(r['data'], {
      'appliedIds': ['b1'],
      'unmatchedIds': [],
    });
  });
}
