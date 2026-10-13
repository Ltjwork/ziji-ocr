import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/services/storage.dart';

/// loadAll 书库枚举回归：下划线开头的书库内部目录（_realign_backups
/// 备份等）即使带 project.json 副本也不得当成书——曾把每本书在首页
/// 显示成两张卡片。
void main() {
  test('loadAll 跳过下划线开头的内部目录', () async {
    final root = await Directory.systemTemp.createTemp('load_all_test');
    addTearDown(() async {
      for (var i = 0; i < 3; i++) {
        try {
          await root.delete(recursive: true);
          return;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    });
    final book = Directory('${root.path}/1780000000000')..createSync();
    final projectJson = jsonEncode({
      'id': '1780000000000',
      'name': '真书',
      'project_dir': book.path,
      'image_files': <String>[],
    });
    File('${book.path}/project.json').writeAsStringSync(projectJson);
    // 内部目录：带 project.json 副本，必须被忽略。
    final backups = Directory('${root.path}/_realign_backups')
      ..createSync()
      ..createSync();
    File('${backups.path}/project.json').writeAsStringSync(projectJson);

    final projects = await ProjectStorage.loadAll(root.path);
    expect(projects.length, 1);
    expect(projects.single.name, '真书');
  });

  test('purgeOrphanProjectDirs 只删无 project.json 的数字目录', () async {
    final root = await Directory.systemTemp.createTemp('purge_orphan_test');
    addTearDown(() async {
      for (var i = 0; i < 3; i++) {
        try {
          await root.delete(recursive: true);
          return;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    });
    // 孤儿：数字名 + 无 project.json
    final orphan = Directory('${root.path}/1791471805234')..createSync();
    File('${orphan.path}/page.png').writeAsBytesSync(List.filled(1024, 0));
    // 真书：数字名 + 有 project.json——绝不能删
    final book = Directory('${root.path}/1780000000000')..createSync();
    File('${book.path}/project.json').writeAsStringSync('{"id": "x"}');
    // 书库内部目录：下划线开头、无 project.json——不能删
    final internal = Directory('${root.path}/char_stats')..createSync();
    // 刚创建的孤儿（导入进行中）：1 小时阈值保护——不能删
    final fresh = Directory('${root.path}/1791471982844')..createSync();

    // cutoff 放到当前时刻之后：所有孤儿都算"过期"，验证删除边界
    final r = await ProjectStorage.purgeOrphanProjectDirs(
      root.path,
      cutoff: DateTime.now().add(const Duration(hours: 1)),
    );
    expect(r.removed, 2);
    expect(r.freedMb, greaterThanOrEqualTo(0));
    expect(orphan.existsSync(), isFalse);
    expect(fresh.existsSync(), isFalse);
    expect(book.existsSync(), isTrue);
    expect(internal.existsSync(), isTrue);

    // 默认 cutoff（1 小时前）：刚重建的孤儿受阈值保护不被删
    final fresh2 = Directory('${root.path}/1791471982844')..createSync();
    final r2 = await ProjectStorage.purgeOrphanProjectDirs(root.path);
    expect(r2.removed, 0);
    expect(fresh2.existsSync(), isTrue);
  });
}
