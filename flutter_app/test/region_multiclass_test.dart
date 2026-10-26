/// region_det 多类化测试：词表语义（RegionLabel）、AI 整页预标注解析、
/// 正文边界按类别（级联修剪 / 段落认领宿主）。
library;

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/services/book_region_apply.dart';
import 'package:gujichazi/services/ollama_service.dart';

void main() {
  group('RegionLabel 词表（Dart/Python 跨语言协议）', () {
    test('词表顺序 = 训练类别 id，main_text 恒为 0', () {
      expect(RegionLabel.all.first, RegionLabel.mainText);
      // 与 python_service/train_data.py LAYER_INFO['region_det']['names'] 同序
      expect(
        RegionLabel.all,
        equals([
          'main_text',
          'header',
          'footer',
          'page_number',
          'margin_note',
          'figure',
          'table',
          'hexagram',
        ]),
      );
      for (final (i, label) in RegionLabel.all.indexed) {
        expect(RegionLabel.all.indexOf(label), i);
      }
    });

    test('词表外与空 label 归 main_text（旧标注兼容）', () {
      expect(RegionLabel.normalize(null), RegionLabel.mainText);
      expect(RegionLabel.normalize(''), RegionLabel.mainText);
      expect(RegionLabel.normalize('weird'), RegionLabel.mainText);
      expect(RegionLabel.normalize('header'), 'header');
    });

    test('正文宿主类与排除类互斥且覆盖全部非正文类', () {
      expect(RegionLabel.isBody('main_text'), isTrue);
      expect(RegionLabel.isBody('margin_note'), isTrue);
      expect(RegionLabel.isExcluded('header'), isTrue);
      expect(RegionLabel.isExcluded('footer'), isTrue);
      expect(RegionLabel.isExcluded('page_number'), isTrue);
      expect(RegionLabel.isExcluded('hexagram'), isTrue);
      for (final l in RegionLabel.all) {
        expect(RegionLabel.isBody(l) || RegionLabel.isExcluded(l), isTrue,
            reason: '$l 必须明确归属宿主或排除');
      }
    });
  });

  group('AI 整页预标注解析（_parsePagePrelabel）', () {
    test('容忍围栏与废话，解析归一化坐标', () {
      const content = '''
好的，以下是分析结果：
```json
{"regions": [
  {"label": "header", "x": 0.1, "y": 0.02, "w": 0.3, "h": 0.05},
  {"label": "page_number", "x": "0.45", "y": "0.95", "w": "0.1", "h": "0.03"}
]}
```''';
      final result = OllamaService.parsePagePrelabelForTest(content);
      expect(result.regions.length, 2);
      expect(result.regions[0].label, 'header');
      expect(result.regions[0].x, closeTo(0.1, 1e-9));
      // 字符串数字也能解析
      expect(result.regions[1].label, 'page_number');
      expect(result.regions[1].w, closeTo(0.1, 1e-9));
    });

    test('坐标钳回 0~1、退化框与词表外 label 处理', () {
      const content =
          '{"regions": ['
          '{"label": "header", "x": -0.2, "y": 0.9, "w": 0.5, "h": 0.5},'
          '{"label": "footer", "x": 0.1, "y": 0.1, "w": 0.002, "h": 0.5},'
          '{"label": "??", "x": 0.1, "y": 0.1, "w": 0.2, "h": 0.2}]}';
      final result = OllamaService.parsePagePrelabelForTest(content);
      // 越界坐标钳回（y+h 从 1.4 收到 1.0）；退化框丢弃；未知 label 归 main_text
      expect(result.regions.length, 2);
      final header = result.regions[0];
      expect(header.x, 0.0);
      expect(header.y + header.h, lessThanOrEqualTo(1.0 + 1e-9));
      expect(result.regions[1].label, RegionLabel.mainText);
    });

    test('答非所问时返回空区域而不是崩溃', () {
      final result = OllamaService.parsePagePrelabelForTest('这不是 JSON');
      expect(result.regions, isEmpty);
    });
  });

  group('正文边界按类别（级联修剪）', () {
    test('header 区不保护其中的机器行', () {
      final ann = PageAnnotation(
        pageId: 'p1',
        imagePath: 'p1.png',
        mainRegions: [
          MainRegion(id: 'mr_body', x: 100, y: 100, w: 400, h: 800),
          MainRegion(id: 'mr_head', x: 100, y: 0, w: 400, h: 80,
              label: RegionLabel.header),
        ],
        lines: [
          // 页眉区内的机器识别行：不该被 header 区保住
          LineBlock(id: 'l_head', x: 110, y: 20, w: 40, h: 30, lineNo: 0),
        ],
        paragraphs: [],
      );
      final stats = BookRegionApply.spliceRegionLines(
        ann,
        newLines: const [],
        rect: const Rect.fromLTWH(0, 500, 2000, 10),
        pruneOutsideRegions: true,
      );
      expect(stats.removedIds, contains('l_head'));
      expect(ann.lines, isEmpty);
    });

    test('margin_note 区保护其中的行（眉批内容有价值）', () {
      final ann = PageAnnotation(
        pageId: 'p1',
        imagePath: 'p1.png',
        mainRegions: [
          MainRegion(id: 'mr_body', x: 100, y: 100, w: 400, h: 800),
          MainRegion(id: 'mr_note', x: 100, y: 0, w: 400, h: 80,
              label: RegionLabel.marginNote),
        ],
        lines: [
          LineBlock(id: 'l_note', x: 110, y: 20, w: 40, h: 30, lineNo: 0),
        ],
        paragraphs: [],
      );
      BookRegionApply.spliceRegionLines(
        ann,
        newLines: const [],
        rect: const Rect.fromLTWH(0, 500, 2000, 10),
        pruneOutsideRegions: true,
      );
      expect(ann.lines.map((l) => l.id), contains('l_note'));
    });
  });

  group('段落认领宿主只认 main_text（ensureHierarchyContainment）', () {
    test('段落不被页眉区收容/撑大', () {
      final ann = PageAnnotation(
        pageId: 'p1',
        imagePath: 'p1.png',
        mainRegions: [
          // 唯一区域是 header：无 main_text 宿主 → 段落不动，不被钳进页眉
          MainRegion(id: 'mr_head', x: 0, y: 0, w: 1000, h: 100,
              label: RegionLabel.header),
        ],
        lines: [
          LineBlock(id: 'l1', x: 200, y: 300, w: 40, h: 300, lineNo: 0),
        ],
        paragraphs: [
          Paragraph(
            id: 'p1',
            x: 200,
            y: 300,
            w: 40,
            h: 300,
            lineIds: const ['l1'],
          ),
        ],
      );
      expect(ann.ensureHierarchyContainment(), isFalse);
      expect(ann.mainRegions.first.h, 100); // 页眉区没被段落撑大
      expect(ann.paragraphs.first.h, 300); // 段落也没被钳进页眉
    });
  });
}
