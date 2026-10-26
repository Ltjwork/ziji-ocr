/// 插件宿主服务（ZijiPluginHostServices）端到端测试：真实读盘 + 权限
/// 路径守卫。重点锁 `projects.readAnnotation` 的 `regions` 投影——卦图
/// 插件按 label=hexagram 取用户画的主区，字段丢了插件就"看不到"画好
/// 的卦图区（协议：宿主↔插件 JSON 字段只追加不改名）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/services/plugin_host/plugin_host_services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// 真实实现的默认通道（tearDown 恢复用；MethodChannel 未初始化时按
/// 缺平台处理，测试内不会真的调到）。
class _DefaultPathProviderPlatform extends PathProviderPlatform {}

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.documentsPath);
  final String documentsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;

  @override
  Future<String?> getApplicationSupportPath() async =>
      p.join(documentsPath, 'support');
}

void main() {
  late Directory tmpRoot;
  late String bookDir;

  setUp(() async {
    tmpRoot = await Directory.systemTemp.createTemp('ziji_host_test');
    bookDir = p.join(tmpRoot.path, 'GujiBT', 'book_a');
    await Directory(p.join(bookDir, 'annotations')).create(recursive: true);
    PathProviderPlatform.instance = _FakePathProviderPlatform(tmpRoot.path);
  });

  tearDown(() async {
    PathProviderPlatform.instance = _DefaultPathProviderPlatform();
    await tmpRoot.delete(recursive: true);
  });

  Future<void> writeAnnotation(Map<String, dynamic> ann) async {
    await File(p.join(bookDir, 'annotations', 'page_046.json')).writeAsString(
      const JsonEncoder.withIndent('  ').convert(ann),
    );
  }

  Map<String, dynamic> baseAnnotation() => {
    'page_id': 'page_046',
    'image_path': p.join(bookDir, 'page_046.png'),
    'draft_saved': true,
    'main_regions': [
      {
        'id': 'mr_body',
        'x': 100,
        'y': 200,
        'w': 300,
        'h': 400,
        'label': 'main_text',
        'status': 'confirmed',
      },
      {
        'id': 'mr_hex',
        'x': 728,
        'y': 1588,
        'w': 385,
        'h': 834,
        'label': 'hexagram',
        'status': 'proposed',
      },
    ],
    'lines': [],
  };

  test('readAnnotation 回包带 regions，hexagram 区字段完整透出', () async {
    await writeAnnotation(baseAnnotation());
    final services = ZijiPluginHostServices(appVersion: 'test');
    final result = await services.readAnnotationCompact(bookDir, 'page_046');
    expect(result, isNotNull);
    expect(result!['imagePath'], isNotEmpty);
    expect(result['mainRegionCount'], 2);
    final regions = result['regions'] as List;
    expect(regions, hasLength(2));
    final hex = regions.firstWhere((r) => r['label'] == 'hexagram');
    expect(hex['id'], 'mr_hex');
    expect(hex['x'], 728);
    expect(hex['y'], 1588);
    expect(hex['w'], 385);
    expect(hex['h'], 834);
    expect(hex['status'], 'proposed');
  });

  test('projectDir 越出书库即拒绝（不静默返回旧数据）', () async {
    await writeAnnotation(baseAnnotation());
    final services = ZijiPluginHostServices(appVersion: 'test');
    await expectLater(
      services.readAnnotationCompact(tmpRoot.path, 'page_046'),
      throwsStateError,
    );
  });

  test('projects.list 下发 pageIds＝图片文件名 stem（删过页的书下标≠页号）',
      () async {
    // 模拟删过页的书：3 张图但文件名是 page_050/051/052——下标 0 对应
    // 页号 page_050。插件若拿"下标拼 page_NNN"就会读错页的标注。
    await File(p.join(bookDir, 'project.json')).writeAsString(jsonEncode({
      'id': 'book_a',
      'name': '测试书',
      'project_dir': bookDir,
      'image_files': [
        p.join(bookDir, 'page_050.png'),
        p.join(bookDir, 'page_051.png'),
        p.join(bookDir, 'page_052.png'),
      ],
    }));
    final services = ZijiPluginHostServices(appVersion: 'test');
    final list = await services.listProjects();
    expect(list, hasLength(1));
    expect(list.first['pageCount'], 3);
    expect(
      list.first['pageIds'],
      ['page_050', 'page_051', 'page_052'],
    );
  });
}
