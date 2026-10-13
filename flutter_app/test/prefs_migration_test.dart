import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/services/prefs_migration.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// +103 品牌更名把 SharedPreferences 存储目录从 com.example\flutter_app
/// 换到 com.example\字迹，旧设置被留在旧目录（用户实测"鼠标手势设置完
/// 没有被保存"）。这里验证一次性迁移：缺失键补入、已存在键不覆盖、
/// 迁移（或确认无旧文件）后置标志不再扫。
void main() {
  late Directory appData;

  setUp(() async {
    appData = await Directory.systemTemp.createTemp('prefs_migration_test');
  });

  tearDown(() async {
    await appData.delete(recursive: true);
  });

  File writeLegacyFile(Map<String, Object> legacy) {
    final dir = Directory(p.join(appData.path, 'com.example', 'flutter_app'))
      ..createSync(recursive: true);
    final file = File(p.join(dir.path, 'shared_preferences.json'));
    file.writeAsStringSync(jsonEncode(legacy));
    return file;
  }

  test('旧目录缺失键被迁入（含类型与前缀剥离），已存在键不覆盖', () async {
    SharedPreferences.setMockInitialValues({
      // 新目录里更名后已重新产生过的值：必须保留，不能被旧值盖掉。
      'monitorWindow.collapsed': false,
    });
    writeLegacyFile({
      'flutter.mouse_gesture_settings_v1':
          '{"enabled":true,"quick":{"DR":"confirmNext"}}',
      'flutter.ollama_settings_v1': '{"base_url":"http://localhost:11434"}',
      'flutter.monitorWindow.collapsed': true,
      'flutter.monitorWindow.offsetDx': 2212.5,
      'not_flutter_key': 'skip me',
    });

    await migrateLegacyPrefs(appDataDir: appData.path);

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('mouse_gesture_settings_v1'),
      '{"enabled":true,"quick":{"DR":"confirmNext"}}',
    );
    expect(
      prefs.getString('ollama_settings_v1'),
      '{"base_url":"http://localhost:11434"}',
    );
    expect(prefs.getDouble('monitorWindow.offsetDx'), 2212.5);
    // 已存在键不覆盖 + 非 flutter. 前缀键不迁。
    expect(prefs.getBool('monitorWindow.collapsed'), isFalse);
    expect(prefs.getKeys(), isNot(contains('not_flutter_key')));
    expect(prefs.getBool(kLegacyPrefsMigratedFlag), isTrue);
  });

  test('迁移只跑一次：标志置位后旧文件再有内容也不迁', () async {
    SharedPreferences.setMockInitialValues({});
    final legacy = writeLegacyFile({
      'flutter.mouse_gesture_settings_v1': 'first',
    });
    await migrateLegacyPrefs(appDataDir: appData.path);

    // 旧文件后来又变了（例如用户回退旧版本改过设置）。
    legacy.writeAsStringSync(
      jsonEncode({'flutter.mouse_gesture_settings_v1': 'second'}),
    );
    await migrateLegacyPrefs(appDataDir: appData.path);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('mouse_gesture_settings_v1'), 'first');
  });

  test('无旧文件：不抛异常，置标志避免每次启动扫盘', () async {
    SharedPreferences.setMockInitialValues({});
    await migrateLegacyPrefs(appDataDir: appData.path);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kLegacyPrefsMigratedFlag), isTrue);
    expect(prefs.getKeys(), contains(kLegacyPrefsMigratedFlag));
  });

  test('旧文件损坏（非 JSON）：置标志、不迁任何键、不抛异常', () async {
    SharedPreferences.setMockInitialValues({});
    final dir = Directory(p.join(appData.path, 'com.example', 'flutter_app'))
      ..createSync(recursive: true);
    File(p.join(dir.path, 'shared_preferences.json'))
        .writeAsStringSync('{broken json');
    await migrateLegacyPrefs(appDataDir: appData.path);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kLegacyPrefsMigratedFlag), isTrue);
    expect(prefs.getKeys().length, 1); // 只有标志键
  });
}
