import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/pages/book_region_reference_apply.dart';

/// 主区快设「按参考页适配」纯逻辑的回归测试：
/// - [ReferenceApply.targetsFor]：目标页保护口径——参考页本身、校对完成
///   的页（整页绿框/玫红框/旧版 reviewed）、「确认无正文」的页恒跳过；
///   「仅未确认」再剔除主区已确认（绿色角标）的页。
/// - [ReferenceApply.mapRect]：参考页矩形按两页宽高各自比例线性映射，
///   尺寸一致/未知时恒等。
void main() {
  PageAnnotation ann(
    String pageId, {
    bool regionConfirmed = false, // 主区 boxConfirmed（绿色"已确认"角标）
    bool pageConfirmed = false, // status=confirmed（整页绿框的构成条件）
    bool boxesReviewed = false, // 「确认识别框」过（玫红框）
    bool reviewed = false, // 旧版「确认并保存」
    bool noMainText = false, // 「确认无正文」（扉页/插图）
  }) =>
      PageAnnotation(
        pageId: pageId,
        imagePath: '$pageId.png',
        boxesReviewed: boxesReviewed,
        reviewed: reviewed,
        noMainTextConfirmed: noMainText,
        mainRegions: [
          MainRegion(
            id: 'mr_$pageId',
            x: 1,
            y: 2,
            w: 300,
            h: 400,
            status: pageConfirmed
                ? AnnotationStatus.confirmed
                : AnnotationStatus.proposed,
            boxConfirmed: regionConfirmed,
          ),
        ],
      );

  test('「仅未确认」：跳过参考页/主区已确认/校对完成/确认无正文，含无标注页', () {
    final annotations = <int, PageAnnotation>{
      0: ann('p0', regionConfirmed: true), // 参考页（主区已确认）
      1: ann('p1'), // 只画未确认 → 目标
      2: ann('p2', regionConfirmed: true), // 绿色角标 → 剔除
      3: ann('p3', pageConfirmed: true), // 整页绿框 → 校对成果跳过
      4: ann('p4', boxesReviewed: true), // 玫红框 → 校对成果跳过
      5: ann('p5', reviewed: true), // 旧版确认 → 校对成果跳过
      6: ann('p6', noMainText: true), // 确认无正文 → 跳过
      // 第 7 页无标注（无正文的书首说明页等）→ 目标
    };
    final (targets, proofreadSkip) = ReferenceApply.targetsFor(
      annotations,
      8,
      0,
      true,
    );
    expect(targets, [1, 7]);
    expect(proofreadSkip, 3); // 3/4/5 三页校对成果
  });

  test('「全部页面」：主区已确认页纳入，校对完成/确认无正文仍跳过', () {
    final annotations = <int, PageAnnotation>{
      0: ann('p0', regionConfirmed: true), // 参考页
      1: ann('p1'),
      2: ann('p2', regionConfirmed: true), // 全部模式下可被覆盖对齐
      3: ann('p3', pageConfirmed: true),
      4: ann('p4', noMainText: true),
    };
    final (targets, proofreadSkip) = ReferenceApply.targetsFor(
      annotations,
      5,
      0,
      false,
    );
    expect(targets, [1, 2]);
    expect(proofreadSkip, 1); // 整页绿框 3
  });

  test('参考页无需已确认：只画过框的页照样当参考', () {
    final annotations = <int, PageAnnotation>{0: ann('p0'), 1: ann('p1')};
    final (targets, _) = ReferenceApply.targetsFor(annotations, 2, 0, true);
    expect(targets, [1]);
  });

  test('指定范围：只取范围内页，保护口径照常生效', () {
    final annotations = <int, PageAnnotation>{
      0: ann('p0', regionConfirmed: true), // 参考页
      1: ann('p1'), // 范围外 → 不取
      2: ann('p2'), // 范围内、未确认 → 取
      3: ann('p3', regionConfirmed: true), // 范围内、已确认 → "全部"口径下取
      4: ann('p4', pageConfirmed: true), // 范围内、校对成果 → 恒跳过
      5: ann('p5', noMainText: true), // 范围外 + 确认无正文
    };
    final (targets, proofreadSkip) = ReferenceApply.targetsFor(
      annotations,
      6,
      0,
      false, // 范围模式按"全部"确认口径（范围本身就是用户显式挑的）
      rangeFirst: 2,
      rangeLast: 4,
    );
    expect(targets, [2, 3]); // 1 在范围外；4 校对成果恒跳过
    expect(proofreadSkip, 1);
  });

  test('mapRect：两页宽高按各自比例线性映射（分辨率不一）', () {
    final mapped = ReferenceApply.mapRect(
      const Rect.fromLTWH(100, 200, 300, 400),
      const Size(1000, 2000),
      const Size(500, 1000),
    );
    expect(mapped, const Rect.fromLTWH(50, 100, 150, 200));
  });

  test('mapRect：宽高比例不同（摆正后裁边）也各轴独立缩放', () {
    final mapped = ReferenceApply.mapRect(
      const Rect.fromLTWH(100, 100, 200, 200),
      const Size(1000, 1000),
      const Size(2000, 1000),
    );
    expect(mapped, const Rect.fromLTWH(200, 100, 400, 200));
  });

  test('mapRect：尺寸一致或未知时恒等', () {
    const rect = Rect.fromLTWH(11, 22, 333, 444);
    expect(
      ReferenceApply.mapRect(rect, const Size(1000, 2000), const Size(1000, 2000)),
      rect,
    );
    expect(ReferenceApply.mapRect(rect, null, const Size(1000, 2000)), rect);
    expect(ReferenceApply.mapRect(rect, const Size(1000, 2000), null), rect);
  });
}
