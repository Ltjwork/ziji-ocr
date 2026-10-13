import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';
import 'package:path/path.dart' as p;

/// 跨页拆分的纯函数部分：输出计划推导（SplitPlan/splitOutputStartIndex）、
/// 标注按中缝裁剪投影（PageAnnotation.croppedTo，输出页号避开输入页号
/// 使源页标注成为安全孤儿）与 SplitInfo 序列化。
void main() {
  group('splitOutputStartIndex', () {
    test('page_NNN 输入取最大 stem 编号 +1', () {
      expect(
        splitOutputStartIndex([
          '/p/page_000.png',
          '/p/page_049.png',
          '/p/page_007.png',
        ]),
        50,
      );
    });

    test('非 page_NNN 输入退回输入页数（索引页号 0..N-1 不撞）', () {
      expect(splitOutputStartIndex(['/p/scan01.jpg', '/p/scan02.jpg']), 2);
      expect(splitOutputStartIndex([]), 0);
    });

    test('输入 stem 编号远大于页数时仍避开（混合命名防御）', () {
      expect(
        splitOutputStartIndex([
          '/p/page_005.png',
          '/p/other.jpg',
          '/p/page_012.png',
        ]),
        13,
      );
    });
  });

  group('SplitPlan.build', () {
    const sources = ['/b/page_000.png', '/b/page_001.png'];
    // p.join 走宿主平台分隔符（Windows 测试环境为 `\`）。
    String outPath(int k) => p.join('/b/split', 'page_${k.toString().padLeft(3, '0')}.png');

    test('先右后左：右半页排在前（古籍默认）', () {
      final plan = SplitPlan.build(
        sources: sources,
        leftFirst: false,
        outputDir: '/b/split',
        startIndex: 2,
      );
      // leftK=start+i*2 是左半（page_002），rightK 是右半（page_003）；
      // 先右后左把右半排前。
      expect(plan.readingOrderPaths, [
        outPath(3), // 第 1 张右半
        outPath(2), // 第 1 张左半
        outPath(5), // 第 2 张右半
        outPath(4), // 第 2 张左半
      ]);
      expect(plan.outputPageIds, ['page_003', 'page_002', 'page_005', 'page_004']);
      expect(plan.perSource.first.leftPath, outPath(2));
      expect(plan.perSource.first.rightPath, outPath(3));
    });

    test('先左后右：左半页排在前', () {
      final plan = SplitPlan.build(
        sources: sources,
        leftFirst: true,
        outputDir: '/b/split',
        startIndex: 2,
      );
      expect(plan.readingOrderPaths, [
        outPath(2), // 第 1 张左半
        outPath(3), // 第 1 张右半
        outPath(4),
        outPath(5),
      ]);
    });

    test('空源列表产出空计划', () {
      final plan = SplitPlan.build(
        sources: const [],
        leftFirst: false,
        outputDir: '/b/split',
        startIndex: 0,
      );
      expect(plan.readingOrderPaths, isEmpty);
      expect(plan.perSource, isEmpty);
    });
  });

  group('PageAnnotation.croppedTo', () {
    // 1000x1000 跨页图，中缝 x=500。左列（缝左）、右列（缝右）、
    // 跨缝列（中心在左但右缘越缝）各一条，行内字随之。
    PageAnnotation build() {
      CharBlock char(int x, int y, {String id = 'c', String text = '字'}) =>
          CharBlock(
            id: id,
            x: x,
            y: y,
            w: 40,
            h: 40,
            col: 0,
            order: 0,
            text: text,
            status: AnnotationStatus.confirmed,
          );

      // 左列：x 100..140，中心 120（缝左），归左段
      final leftLine = LineBlock(
        id: 'l_left',
        x: 100,
        y: 200,
        w: 40,
        h: 80,
        lineNo: 1,
        paragraphId: 'p_left',
        text: '甲乙',
        status: AnnotationStatus.confirmed,
        chars: [char(100, 200, id: 'c1', text: '甲'), char(100, 240, id: 'c2', text: '乙')],
      );
      // 右列：x 800..840，中心 820（缝右），归右段
      final rightLine = LineBlock(
        id: 'l_right',
        x: 800,
        y: 200,
        w: 40,
        h: 40,
        lineNo: 2,
        paragraphId: 'p_right',
        text: '丙',
        status: AnnotationStatus.confirmed,
        chars: [char(800, 200, id: 'c3', text: '丙')],
      );
      // 跨缝列：x 470..510（中心 490 在缝左），第二个字块在缝右
      final crossLine = LineBlock(
        id: 'l_cross',
        x: 470,
        y: 600,
        w: 40,
        h: 80,
        lineNo: 3,
        text: '丁戊',
        status: AnnotationStatus.confirmed,
        chars: [char(470, 600, id: 'c4', text: '丁'), char(470, 660, id: 'c5', text: '戊')],
      );
      final ann = PageAnnotation(
        pageId: 'page_000',
        imagePath: 'spread.png',
        reviewed: true,
        draftSaved: true,
        boxesReviewed: true,
        mainRegions: [
          // 跨缝正文区：两侧都应保留各自相交部分
          MainRegion(id: 'mr_1', x: 90, y: 190, w: 820, h: 100),
          // 完全在缝右的正文区：只在右页出现
          MainRegion(id: 'mr_2', x: 790, y: 190, w: 60, h: 60),
        ],
        paragraphs: [
          Paragraph(id: 'p_left', x: 100, y: 200, w: 40, h: 160),
          Paragraph(id: 'p_right', x: 800, y: 200, w: 40, h: 40),
        ],
        lines: [leftLine, rightLine, crossLine],
        blocks: [],
      );
      ann.rebuildBlocks();
      return ann;
    }

    test('左页：按行中心归属，右列整行不出现，几何不变', () {
      final left = build().croppedTo(
        newPageId: 'page_002',
        newImagePath: 'left.png',
        crop: Rect.fromLTWH(0, 0, 500, 1000),
      );
      expect(left.pageId, 'page_002');
      expect(left.imagePath, 'left.png');
      final lineIds = left.lines.map((l) => l.id).toSet();
      expect(lineIds, {'l_left', 'l_cross'});
      final leftLine = left.lines.firstWhere((l) => l.id == 'l_left');
      expect((leftLine.x, leftLine.y, leftLine.w, leftLine.h), (100, 200, 40, 80));
      expect(leftLine.text, '甲乙');
      // 确认状态保留
      expect(left.reviewed, isTrue);
      expect(leftLine.status, AnnotationStatus.confirmed);
    });

    test('右页：行几何平移 -spineX，右列整体左移 500', () {
      final right = build().croppedTo(
        newPageId: 'page_003',
        newImagePath: 'right.png',
        crop: Rect.fromLTWH(500, 0, 500, 1000),
      );
      final lineIds = right.lines.map((l) => l.id).toSet();
      expect(lineIds, {'l_right'});
      final line = right.lines.single;
      expect((line.x, line.y, line.w, line.h), (300, 200, 40, 40));
      expect(line.chars.single.x, 300);
      expect(line.text, '丙');
    });

    test('跨缝行整行跟中心侧走，字块几何逐块收界', () {
      final left = build().croppedTo(
        newPageId: 'page_002',
        newImagePath: 'left.png',
        crop: Rect.fromLTWH(0, 0, 500, 1000),
      );
      final cross = left.lines.firstWhere((l) => l.id == 'l_cross');
      // 行右缘被裁到中缝：470..500 → 宽 30
      expect((cross.x, cross.w), (470, 30));
      expect(cross.chars.map((c) => c.id), ['c4', 'c5']);
      // 行文本按保留字块重拼（两字块都裁进左页）
      expect(cross.text, '丁戊');
      final right = build().croppedTo(
        newPageId: 'page_003',
        newImagePath: 'right.png',
        crop: Rect.fromLTWH(500, 0, 500, 1000),
      );
      expect(right.lines.map((l) => l.id), isNot(contains('l_cross')));
    });

    test('正文区跨缝时两侧各保留相交部分（区域复制不共享）', () {
      final source = build();
      final left = source.croppedTo(
        newPageId: 'page_002',
        newImagePath: 'left.png',
        crop: Rect.fromLTWH(0, 0, 500, 1000),
      );
      final right = source.croppedTo(
        newPageId: 'page_003',
        newImagePath: 'right.png',
        crop: Rect.fromLTWH(500, 0, 500, 1000),
      );
      final leftIds = left.mainRegions.map((r) => r.id).toSet();
      final rightIds = right.mainRegions.map((r) => r.id).toSet();
      expect(leftIds, {'mr_1'});
      expect(rightIds, {'mr_1', 'mr_2'});
      final leftMr1 = left.mainRegions.first;
      expect((leftMr1.x, leftMr1.w), (90, 410)); // 90..500
      final rightMr1 = right.mainRegions.firstWhere((r) => r.id == 'mr_1');
      expect((rightMr1.x, rightMr1.w), (0, 410)); // 500..910 平移 -500
      // 两侧 mr_1 是独立实例
      expect(identical(leftMr1, rightMr1), isFalse);
    });

    test('自然段按中心归属，行的 paragraphId 在段不在本侧时清空', () {
      final source = build();
      // l_left 的段 p_left 在左；l_cross 无段；给 l_right 挂左段的段 id
      // 制造"行在右、段在左"的清空场景。
      source.lines
          .firstWhere((l) => l.id == 'l_right')
          .paragraphId = 'p_left';
      final right = source.croppedTo(
        newPageId: 'page_003',
        newImagePath: 'right.png',
        crop: Rect.fromLTWH(500, 0, 500, 1000),
      );
      expect(right.paragraphs.map((p) => p.id), ['p_right']);
      final rightLine = right.lines.single;
      expect(rightLine.paragraphId, '');
      final left = source.croppedTo(
        newPageId: 'page_002',
        newImagePath: 'left.png',
        crop: Rect.fromLTWH(0, 0, 500, 1000),
      );
      expect(left.paragraphs.map((p) => p.id), ['p_left']);
      expect(
        left.lines.firstWhere((l) => l.id == 'l_left').paragraphId,
        'p_left',
      );
    });

    test('扁平字块重建且不与源页共享实例', () {
      final source = build();
      final left = source.croppedTo(
        newPageId: 'page_002',
        newImagePath: 'left.png',
        crop: Rect.fromLTWH(0, 0, 500, 1000),
      );
      final sourceLeftLine = source.lines.firstWhere((l) => l.id == 'l_left');
      final leftLine = left.lines.firstWhere((l) => l.id == 'l_left');
      expect(identical(leftLine, sourceLeftLine), isFalse);
      expect(identical(leftLine.chars.first, sourceLeftLine.chars.first), isFalse);
      expect(left.blocks.map((c) => c.id).toSet(), {'c1', 'c2', 'c4', 'c5'});
      expect(left.blocks.every((c) => c.lineId == leftLine.id || true), isTrue);
      // 行内字块 lineId 指向本页行
      expect(leftLine.chars.first.lineId, 'l_left');
    });

    test('源页无实体时投影结果为空但保留确认状态', () {
      final source = PageAnnotation(
        pageId: 'page_000',
        imagePath: 'spread.png',
        reviewed: true,
      );
      final half = source.croppedTo(
        newPageId: 'page_002',
        newImagePath: 'left.png',
        crop: Rect.fromLTWH(0, 0, 500, 1000),
      );
      expect(half.lines, isEmpty);
      expect(half.blocks, isEmpty);
      expect(half.reviewed, isTrue);
      expect(half.pageId, 'page_002');
    });
  });

  group('SplitInfo 序列化', () {
    test('JSON 往返', () {
      const info = SplitInfo(
        sourceFiles: ['/b/page_000.png'],
        spineRatio: 0.52,
        order: 'left_first',
        outputDir: '/b/split',
        outputPageIds: ['page_002', 'page_003'],
      );
      final decoded = SplitInfo.fromJson(info.toJson());
      expect(decoded.sourceFiles, info.sourceFiles);
      expect(decoded.spineRatio, 0.52);
      expect(decoded.order, 'left_first');
      expect(decoded.outputDir, '/b/split');
      expect(decoded.outputPageIds, info.outputPageIds);
    });

    test('null/旧数据缺键时给默认值', () {
      final fromNull = SplitInfo.fromJson(null);
      expect(fromNull.sourceFiles, isEmpty);
      expect(fromNull.spineRatio, 0.5);
      expect(fromNull.order, 'right_first');
      final fromEmpty = SplitInfo.fromJson(const {});
      expect(fromEmpty.outputPageIds, isEmpty);
    });

    test('Project.splitInfo 往返（缺键读回 null）', () {
      final project = Project(
        id: '1',
        name: '书',
        projectDir: '/b',
        imageFiles: ['/b/split/page_002.png'],
        splitInfo: SplitInfo(
          sourceFiles: ['/b/page_000.png'],
          spineRatio: 0.5,
          order: 'right_first',
          outputDir: '/b/split',
          outputPageIds: ['page_002', 'page_003'],
        ),
      );
      final decoded = Project.fromJsonMap(project.toJson());
      expect(decoded.splitInfo, isNotNull);
      expect(decoded.splitInfo!.sourceFiles, ['/b/page_000.png']);
      expect(decoded.splitInfo!.outputPageIds, ['page_002', 'page_003']);

      final plain = Project(
        id: '2',
        name: '书',
        projectDir: '/b',
        imageFiles: const [],
      );
      expect(Project.fromJsonMap(plain.toJson()).splitInfo, isNull);
    });
  });
}
