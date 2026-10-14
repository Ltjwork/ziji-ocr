import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/services/changelog_service.dart';
import 'package:gujichazi/services/direct_text_store.dart';

/// 更新日志解析（ChangelogService.parse）与整页直读文本落盘
/// （DirectTextStore）的单元测试。
void main() {
  group('ChangelogService.parse', () {
    test('按 ## 分节，第一条即最新版本', () {
      const content = '# 更新日志\n\n## 1.0.0+182\n\n- 功能甲\n\n## 1.0.0+181\n\n- 功能乙\n';
      final entries = ChangelogService.parse(content);
      expect(entries.length, 2);
      expect(entries.first.version, '1.0.0+182');
      expect(entries.first.markdown, '- 功能甲');
      expect(entries.last.version, '1.0.0+181');
      expect(entries.last.markdown, '- 功能乙');
    });

    test('CRLF 与首尾空行兼容，节内空行保留', () {
      const content = '# 更新日志\r\n\r\n## v1\r\n\r\n- 第一行\r\n\r\n- 第二行\r\n\r\n\r\n## v0\r\n- 旧\n';
      final entries = ChangelogService.parse(content);
      expect(entries.length, 2);
      expect(entries.first.markdown, '- 第一行\n\n- 第二行');
    });

    test('无分节标题返回空列表', () {
      expect(ChangelogService.parse('# 更新日志\n只有标题'), isEmpty);
      expect(ChangelogService.parse(''), isEmpty);
    });

    test('GitHub 发布说明格式 = ## 版本 + 正文', () {
      const content = '## 1.0.0+182\n\n- 功能甲\n';
      final e = ChangelogService.parse(content).first;
      // 分节正文裁掉首尾空行（粘贴到 Release 更干净），重组格式如下
      expect('## ${e.version}\n\n${e.markdown}', '## 1.0.0+182\n\n- 功能甲');
    });
  });

  group('DirectTextStore', () {
    late Directory tmp;
    late Project project;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('direct_text_test');
      project = Project(
        id: 'p1',
        name: '书',
        projectDir: tmp.path,
        imageFiles: const ['page_000.png'],
      );
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('未识别过返回 null；保存后可读回，覆盖保存生效', () async {
      expect(await DirectTextStore.load(project, 'page_000'), isNull);

      await DirectTextStore.save(project, 'page_000', '天地玄黃\n宇宙洪荒');
      expect(await DirectTextStore.load(project, 'page_000'), '天地玄黃\n宇宙洪荒');

      await DirectTextStore.save(project, 'page_000', '改过');
      expect(await DirectTextStore.load(project, 'page_000'), '改过');

      // 落在 direct_text/ 子目录，不与标注 JSON 混放
      expect(
        File(p.join(tmp.path, 'direct_text', 'page_000.txt')).existsSync(),
        isTrue,
      );
      expect(DirectTextStore.savedAt(project, 'page_000'), isNotNull);
    });

    test('空文本也落盘（代表"直读过、结果为空"）', () async {
      await DirectTextStore.save(project, 'page_001', '');
      expect(await DirectTextStore.load(project, 'page_001'), '');
      expect(DirectTextStore.savedAt(project, 'page_001'), isNotNull);
    });

    test('各页互不干扰', () async {
      await DirectTextStore.save(project, 'page_000', '甲');
      await DirectTextStore.save(project, 'page_001', '乙');
      expect(await DirectTextStore.load(project, 'page_000'), '甲');
      expect(await DirectTextStore.load(project, 'page_001'), '乙');
    });
  });
}
