// 识别框一律不超出书页图片本身：
// - clampAllToImage 修复盘上旧数据的越界框（实测主区 0,0,1342,2157
//   超出 1298×2074 页面）；
// - inferHierarchy 的主区 = 行外接矩形 + 2% 边距，边距会把框推出图片
//   边界（h=2074+2%×2=2157），必须钳回图片范围。
import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';

void main() {
  group('clampAllToImage', () {
    test('越界主区钳回图片范围（page_076 实测数据回归）', () {
      final ann = PageAnnotation(
        pageId: 'p',
        imagePath: 'x.png',
        mainRegions: [
          MainRegion(id: 'mr_001', x: 0, y: 0, w: 1342, h: 2157),
        ],
      );
      expect(ann.clampAllToImage(1298, 2074), isTrue);
      final r = ann.mainRegions.first;
      expect((r.x, r.y, r.w, r.h), (0, 0, 1298, 2074));
    });

    test('部分越界的行与字框裁到边界，框内数据不再越界', () {
      final line = LineBlock(id: 'l1', x: 1200, y: 10, w: 200, h: 500, lineNo: 0)
        ..chars = [
          CharBlock(id: 'c1', x: 1290, y: 20, w: 30, h: 40, col: 0, order: 0),
          CharBlock(id: 'c2', x: 100, y: 2000, w: 20, h: 200, col: 0, order: 1),
        ];
      final ann = PageAnnotation(pageId: 'p', imagePath: 'x.png')
        ..lines.add(line);
      expect(ann.clampAllToImage(1298, 2074), isTrue);
      expect((line.x, line.w), (1200, 98));
      expect((line.chars[0].x, line.chars[0].w), (1290, 8));
      expect((line.chars[1].y, line.chars[1].h), (2000, 74));
    });

    test('全部在界内返回 false 且不改写', () {
      final ann = PageAnnotation(pageId: 'p', imagePath: 'x.png')
        ..mainRegions.add(MainRegion(id: 'mr', x: 5, y: 5, w: 90, h: 90));
      expect(ann.clampAllToImage(100, 100), isFalse);
      final r = ann.mainRegions.first;
      expect((r.x, r.y, r.w, r.h), (5, 5, 90, 90));
    });
  });


  group('ensureHierarchyContainment 容器只扩不缩', () {
    test('段落扩到包含成员行、主区扩到包含段落，行框不被裁', () {
      final line = LineBlock(id: 'l1', x: 10, y: 10, w: 60, h: 800, lineNo: 0);
      final ann = PageAnnotation(pageId: 'p', imagePath: 'x.png')
        ..mainRegions.add(MainRegion(id: 'mr', x: 20, y: 20, w: 50, h: 700))
        ..paragraphs.add(Paragraph(id: 'p1', x: 15, y: 15, w: 40, h: 600)
          ..lineIds.add('l1'))
        ..lines.add(line);
      expect(ann.ensureHierarchyContainment(), isTrue);
      final para = ann.paragraphs.first;
      // 段扩到含行（只扩：右/下边界抬到行边界）
      expect((para.x, para.y, para.w, para.h), (10, 10, 60, 800));
      final region = ann.mainRegions.first;
      expect((region.x, region.y, region.w, region.h), (10, 10, 60, 800));
      // 行框原样
      expect((line.x, line.y, line.w, line.h), (10, 10, 60, 800));
    });

    test('已包含时零改动', () {
      final ann = PageAnnotation(pageId: 'p', imagePath: 'x.png')
        ..mainRegions.add(MainRegion(id: 'mr', x: 0, y: 0, w: 100, h: 100))
        ..paragraphs.add(Paragraph(id: 'p1', x: 10, y: 10, w: 80, h: 80)
          ..lineIds.add('l1'))
        ..lines.add(LineBlock(id: 'l1', x: 20, y: 20, w: 50, h: 50, lineNo: 0));
      expect(ann.ensureHierarchyContainment(), isFalse);
    });
  });

  group('inferHierarchy 主区钳制', () {
    test('行外接矩形 + 2% 边距钳回图片范围（h=2157 回归）', () {
      final ann = PageAnnotation(pageId: 'p', imagePath: 'x.png')
        ..lines.addAll([
          LineBlock(id: 'l1', x: 0, y: 0, w: 1298, h: 2074, lineNo: 0),
          LineBlock(id: 'l2', x: 6, y: 100, w: 100, h: 1974, lineNo: 1),
        ]);
      ann.inferHierarchy(imageWidth: 1298, imageHeight: 2074);
      final r = ann.mainRegions.first;
      expect(r.x, greaterThanOrEqualTo(0));
      expect(r.y, greaterThanOrEqualTo(0));
      expect(r.x + r.w, lessThanOrEqualTo(1298));
      // 不钳制时 = 2074 + 2%×2074 ≈ 2157（越界 83px 的实测来源）
      expect(r.y + r.h, lessThanOrEqualTo(2074));
    });

    test('无图片尺寸时回退识别响应携带的 sourceImageWidth/Height', () {
      final ann = PageAnnotation(pageId: 'p', imagePath: 'x.png')
        ..sourceImageWidth = 100
        ..sourceImageHeight = 100
        ..lines.add(LineBlock(id: 'l1', x: 0, y: 0, w: 100, h: 100, lineNo: 0));
      ann.inferHierarchy();
      final r = ann.mainRegions.first;
      expect(r.x + r.w, lessThanOrEqualTo(100));
      expect(r.y + r.h, lessThanOrEqualTo(100));
    });
  });
}
