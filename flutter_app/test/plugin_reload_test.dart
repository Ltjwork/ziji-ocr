/// 插件重新加载（PluginHost.reloadPlugin）测试：插件文件被直接覆盖
/// 进安装目录后，重载要取到新清单（版本号等身份信息以磁盘为准）；
/// 目录被删则视同已卸载。运行时启停依赖 WebView2，测试环境不覆盖
/// （启用状态下的重启路径与导入升级共用 _startRuntime）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/services/plugin_host/plugin_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _DefaultPathProviderPlatform extends PathProviderPlatform {}

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.rootPath);
  final String rootPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;

  @override
  Future<String?> getApplicationSupportPath() async =>
      p.join(rootPath, 'support');
}

void main() {
  late Directory tmpRoot;
  late String pluginDir;

  setUp(() async {
    tmpRoot = await Directory.systemTemp.createTemp('ziji_reload_test');
    pluginDir = p.join(tmpRoot.path, 'support', 'plugins', 'demo_plugin');
    await Directory(pluginDir).create(recursive: true);
    await File(p.join(pluginDir, 'main.js')).writeAsString('// demo entry');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tmpRoot.path);
  });

  tearDown(() async {
    PathProviderPlatform.instance = _DefaultPathProviderPlatform();
    await tmpRoot.delete(recursive: true);
  });

  String manifestJson(String version) => const JsonEncoder.withIndent('  ')
      .convert({
        'id': 'demo_plugin',
        'name': '演示插件',
        'version': version,
        'description': '重载测试用',
        'api_version': 1,
        'entry': 'main.js',
      });

  test('重新加载重读磁盘最新清单，目录被删则视同卸载', () async {
    final host = PluginHost.instance;
    await File(p.join(pluginDir, 'manifest.json'))
        .writeAsString(manifestJson('1.0.0'));
    await host.load();
    expect(host.byId('demo_plugin')?.manifest.version, '1.0.0');

    // 开发迭代：直接覆盖插件目录里的文件 → 重载取到新版本号。
    await File(p.join(pluginDir, 'manifest.json'))
        .writeAsString(manifestJson('2.0.0'));
    final reloaded = await host.reloadPlugin('demo_plugin');
    expect(reloaded?.manifest.version, '2.0.0');
    expect(host.byId('demo_plugin')?.manifest.version, '2.0.0');

    // 目录整个被删 → 重载返回 null、列表里消失。
    await Directory(pluginDir).delete(recursive: true);
    expect(await host.reloadPlugin('demo_plugin'), isNull);
    expect(host.installed, isEmpty);
  });
}
