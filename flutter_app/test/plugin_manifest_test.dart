// 外挂插件清单（manifest.json）解析与校验规则。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/services/plugin_host/plugin_manifest.dart';

PluginManifest? parse(Object j) =>
    PluginManifest.tryParse(jsonEncode(j)) ;

const valid = {
  'id': 'demo_plugin',
  'name': '识字任务同步',
  'version': '1.0.0',
  'entry': 'main.js',
  'api_version': 1,
};

void main() {
  test('合法清单解析', () {
    final m = parse(valid)!;
    expect(m.id, 'demo_plugin');
    expect(m.name, '识字任务同步');
    expect(m.apiVersion, 1);
    expect(m.entry, 'main.js');
    expect(m.settings, isNull);
    expect(m.permissions, isEmpty);
    expect(m.virtualHost, 'demo-plugin.plugin.ziji');
  });

  test('id 规则：大写/数字开头/横线/过长都拒绝', () {
    for (final id in ['Crowd_sync', '1abc', 'crowd-sync', 'a', '']) {
      expect(parse({...valid, 'id': id}), isNull, reason: id);
    }
    expect(parse({...valid, 'id': 'a' * 32}), isNull);
    expect(parse({...valid, 'id': 'a' * 31}), isNotNull);
  });

  test('缺必备字段拒绝', () {
    expect(parse({...valid}..remove('name')), isNull);
    expect(parse({...valid}..remove('version')), isNull);
    expect(parse({...valid}..remove('entry')), isNull);
    expect(parse({...valid}..remove('api_version')), isNull);
    expect(parse('not json'), isNull);
  });

  test('未知权限拒绝（防拼错静默放行）', () {
    expect(parse({...valid, 'permissions': ['http', 'network']}), isNull);
    expect(
      parse({
        ...valid,
        'permissions': ['http', 'storage', 'projects:read'],
      }),
      isNotNull,
    );
  });

  test('settings/icon/min_app_version 可选字段', () {
    final m = parse({
      ...valid,
      'settings': 'settings.html',
      'icon': 'cloud_sync',
      'min_app_version': '1.0.2',
      'author': 'ziji',
      'description': '说明',
    })!;
    expect(m.settings, 'settings.html');
    expect(m.icon, 'cloud_sync');
    expect(m.minAppVersion, '1.0.2');
  });

  test('权限 → 命令映射完整：分发器里用到的每个命令都有权限语义', () {
    // 命令面与权限映射的一致性由桥测试覆盖；这里锁「权限全集」。
    expect(
      PluginPermissions.all,
      containsAll(PluginPermissions.byCommand.values.toSet()),
    );
  });
}
