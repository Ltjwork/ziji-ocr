// 外挂插件仓库：zip 导入（含单层顶层目录剥离与路径穿越拒绝）、卸载、
// 启停持久化、升级保留插件存储。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/services/plugin_host/plugin_manifest.dart';
import 'package:gujichazi/services/plugin_host/plugin_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

const manifestJson = {
  'id': 'demo',
  'name': '演示插件',
  'version': '1.0.0',
  'entry': 'main.js',
  'api_version': 1,
};

File _zip(Directory dir, String name, Map<String, String> files) {
  final archive = Archive();
  files.forEach((k, v) => archive.add(ArchiveFile(k, v.length, utf8.encode(v))));
  final file = File('${dir.path}/$name');
  file.writeAsBytesSync(ZipEncoder().encode(archive));
  return file;
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('plugin_store_test');
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('安装 → 列表可见 → 卸载后消失', () async {
    final store = PluginStore(tmp.path + '\plugins');
    final zip = _zip(tmp, 'a.zjplugin', {
      'manifest.json': jsonEncode(manifestJson),
      'main.js': 'console.log(1)',
    });
    final outcome = await store.installFromZip(zip.path);
    expect(outcome.result, PluginInstallResult.ok);
    expect(outcome.id, 'demo');

    final installed = await store.listInstalled();
    expect(installed, hasLength(1));
    expect(installed.single.manifest.name, '演示插件');
    expect(
      File('${store.dirFor('demo')}/main.js').existsSync(),
      isTrue,
    );

    await store.uninstall('demo');
    expect(await store.listInstalled(), isEmpty);
    expect(Directory('${store.dirFor('demo')}').existsSync(), isFalse);
  });

  test('单层顶层目录自动剥离（GitHub zip 下载形态）', () async {
    final store = PluginStore(tmp.path + '\plugins');
    final zip = _zip(tmp, 'b.zjplugin', {
      'demo-1.0.0/manifest.json': jsonEncode(manifestJson),
      'demo-1.0.0/main.js': 'x',
    });
    final outcome = await store.installFromZip(zip.path);
    expect(outcome.result, PluginInstallResult.ok);
    final installed = await store.listInstalled();
    expect(installed.single.manifest.id, 'demo');
    expect(File('${store.dirFor('demo')}/manifest.json').existsSync(), isTrue);
  });

  test('路径穿越与坏包拒绝', () async {
    final store = PluginStore(tmp.path + '\plugins');
    final traversal = _zip(tmp, 'c.zip', {
      'manifest.json': jsonEncode(manifestJson),
      'main.js': 'x',
      '../evil.txt': 'x',
    });
    expect(
      (await store.installFromZip(traversal.path)).result,
      PluginInstallResult.badEntries,
    );

    final noManifest = _zip(tmp, 'd.zip', {'main.js': 'x'});
    expect(
      (await store.installFromZip(noManifest.path)).result,
      PluginInstallResult.badManifest,
    );

    final apiMismatch = _zip(tmp, 'e.zip', {
      'manifest.json': jsonEncode({...manifestJson, 'api_version': 99}),
      'main.js': 'x',
    });
    expect(
      (await store.installFromZip(apiMismatch.path)).result,
      PluginInstallResult.incompatibleApi,
    );

    final notZip = File('${tmp.path}/f.zip')..writeAsStringSync('not a zip');
    expect(
      (await store.installFromZip(notZip.path)).result,
      PluginInstallResult.badZip,
    );
  });

  test('升级覆盖：manifest 换新，插件存储 data/global.json 保留', () async {
    final store = PluginStore(tmp.path + '\plugins');
    final v1 = _zip(tmp, 'g.zip', {
      'manifest.json': jsonEncode(manifestJson),
      'main.js': 'v1',
    });
    await store.installFromZip(v1.path);
    // 模拟插件写过存储。
    final data = File('${store.dirFor('demo')}/data/global.json');
    await data.parent.create(recursive: true);
    await data.writeAsString('{"k":1}');

    final v2 = _zip(tmp, 'h.zip', {
      'manifest.json': jsonEncode({...manifestJson, 'version': '2.0.0'}),
      'main.js': 'v2',
    });
    final outcome = await store.installFromZip(v2.path);
    expect(outcome.result, PluginInstallResult.okUpgraded);
    expect(File('${store.dirFor('demo')}/main.js').readAsStringSync(), 'v2');
    expect(data.readAsStringSync(), '{"k":1}');
  });

  test('启停持久化：单 key JSON，卸载移除键', () async {
    final store = PluginStore(tmp.path + '\plugins');
    await store.setEnabledRaw('demo', true);
    await store.setEnabledRaw('other', false);
    expect(await store.loadEnabled(), {'demo': true, 'other': false});

    await store.setEnabledRaw('demo', null);
    expect(await store.loadEnabled(), {'other': false});

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('ziji.plugins.enabled');
    expect(raw, isNotNull); // 旧内置插件时代同 key，老开关无缝继承。
    expect((jsonDecode(raw!) as Map)['other'], false);
  });
}
