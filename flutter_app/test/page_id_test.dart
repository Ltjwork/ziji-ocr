import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/services/storage.dart';

/// 页号（pageId）规则回归：任意图片文件名 stem 直接作页号。
///
/// 历史缺陷：非 page_NNN 文件名（如跨页拆分/摆正输出的
/// warped/split_page_273.png）曾回退按 imageFiles 下标命名标注文件；
/// 删页后下标漂移，全书标注与当前页错配，被 loadAnnotation 的
/// expectedImagePath 守卫整书丢弃——表现为「全书识别丢失」。
/// 存量错位数据由 python_service/tool_realign_annotations.py 归位。
void main() {
  group('pageIdForImage', () {
    test('任意文件名 stem 直接作页号（不再回退下标）', () {
      expect(
          pageIdForImage(r'C:\b\warped\split_page_273.png', 0), 'split_page_273');
      expect(pageIdForImage('/tmp/x/IMG_2410_scan.png', 7), 'IMG_2410_scan');
      // 中文/空格 stem 原样可用作标注文件名。
      expect(pageIdForImage(r'C:\b\sources_第一册_Extract_1.png', 0),
          'sources_第一册_Extract_1');
    });

    test('page_NNN 文件名行为不变', () {
      expect(pageIdForImage(r'C:\b\page_007.png', 7), 'page_007');
      expect(pageIdForImage(r'C:\b\page_1234.png', 0), 'page_1234');
    });

    test('页号与下标解耦：删页/插页后同图页号不变', () {
      const img = r'C:\b\warped\split_page_369.png';
      expect(pageIdForImage(img, 100), pageIdForImage(img, 97));
      expect(pageIdForImage(img, 0), 'split_page_369');
    });

    test('空 stem 兜底回下标页号', () {
      expect(pageIdForImage(r'C:\b\.png', 3), 'page_003');
    });
  });

  group('删页后页号不漂移（全书识别丢失事故回归）', () {
    test('Project.pageIdAt 删页后各页仍指向自己的标注', () {
      final project = Project(
        id: 'p',
        name: 'b',
        projectDir: 'x',
        imageFiles: [
          r'C:\b\warped\split_page_266.png',
          r'C:\b\warped\split_page_269.png',
          r'C:\b\warped\split_page_270.png',
          r'C:\b\warped\split_page_273.png',
        ],
      );
      final before = [
        for (var i = 0; i < project.imageFiles.length; i++) project.pageIdAt(i),
      ];
      project.imageFiles.removeAt(2); // 删除 split_page_270
      expect(project.pageIdAt(0), before[0]);
      expect(project.pageIdAt(1), before[1]);
      // 273 的下标从 3 前移到 2，页号不变、标注仍找得回。
      expect(project.pageIdAt(2), before[3]);
    });
  });

  group('stem 页号标注存取往返', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('page_id_test');
    });

    tearDown(() async {
      // saveAnnotation 的字频账本钩子是 fire-and-forget，Windows 上偶发
      // 与删除枚举竞态；重试删除，临时目录由 OS 兜底清理。
      for (var i = 0; i < 3; i++) {
        try {
          await tmp.delete(recursive: true);
          return;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    });

    test('save → load（带 expectedImagePath 守卫）往返命中', () async {
      final image = '${tmp.path}\\warped\\split_page_369.png';
      final pageId = pageIdForImage(image, 5);
      await ProjectStorage.saveAnnotation(
        tmp.path,
        PageAnnotation(pageId: pageId, imagePath: image, draftSaved: true),
      );
      expect(File('${tmp.path}/annotations/$pageId.json').existsSync(), isTrue);
      final loaded = await ProjectStorage.loadAnnotation(
        tmp.path,
        pageId,
        expectedImagePath: image,
      );
      expect(loaded?.pageId, pageId);
      expect(loaded?.imagePath, image);
    });

    test('守卫仍拒绝属于别的图片的错配标注', () async {
      final imageA = '${tmp.path}\\warped\\split_page_369.png';
      final imageB = '${tmp.path}\\warped\\split_page_370.png';
      await ProjectStorage.saveAnnotation(
        tmp.path,
        PageAnnotation(
            pageId: pageIdForImage(imageA, 5), imagePath: imageA),
      );
      // 369 的标注文件冒充 370：守卫必须丢弃，防止串页。
      expect(
        await ProjectStorage.loadAnnotation(
          tmp.path,
          pageIdForImage(imageA, 6),
          expectedImagePath: imageB,
        ),
        isNull,
      );
    });
  });
}
