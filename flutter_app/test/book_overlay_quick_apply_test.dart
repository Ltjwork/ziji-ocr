import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/pages/book_overlay_page.dart';

/// 全书叠加「指定页统一设置」（主区快设入口）目标页扫描的回归测试：
/// - 选定页表（可离散）内校对完成的页（整页绿框/玫红框/旧版 reviewed）
///   与「确认无正文」的页恒跳过（保护口径与「按参考页适配」一致）；
/// - 无标注页入目标（统一设置正是要给没设过的页补版面区）并单独计数；
/// - 原主区已确认（绿色角标）的页入目标并计入"应用后退回未确认"统计；
/// - 页表外的页完全不看（离散多选只作用于勾选的页）。
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

  test('校对完成/确认无正文跳过，无标注页入目标并计数', () {
    final scan = BookOverlayPage.quickApplyTargetsFrom(
      annotations: {
        0: ann('p0'),
        1: ann('p1', pageConfirmed: true), // 整页绿框 → 跳过
        2: ann('p2', boxesReviewed: true), // 玫红框 → 跳过
        3: ann('p3', reviewed: true), // 旧版确认 → 跳过
        4: ann('p4', noMainText: true), // 确认无正文 → 跳过
        // 第 5 页无标注（没设过的页）→ 目标，新建标注
      },
      pages: [0, 1, 2, 3, 4, 5],
    );
    expect(scan.pages, [0, 5]);
    expect(scan.freshPages, 1);
    expect(scan.proofreadSkip, 3);
    expect(scan.noMainSkip, 1);
    expect(scan.confirmedReset, 0);
  });

  test('原主区已确认页入目标并计入退回未确认统计', () {
    final scan = BookOverlayPage.quickApplyTargetsFrom(
      annotations: {
        0: ann('p0', regionConfirmed: true), // 绿色角标 → 目标，应用后退回
        1: ann('p1'), // 只画未确认 → 目标
        2: ann('p2', regionConfirmed: true, noMainText: true), // 无正文优先跳过
      },
      pages: [0, 1, 2],
    );
    expect(scan.pages, [0, 1]);
    expect(scan.confirmedReset, 1);
    expect(scan.noMainSkip, 1);
  });

  test('只扫页表内的页，表外页不看（离散多选口径）', () {
    final scan = BookOverlayPage.quickApplyTargetsFrom(
      annotations: {
        1: ann('p1'),
        2: ann('p2', pageConfirmed: true), // 表外：即使校对完成也不计入统计
        3: ann('p3'),
        4: ann('p4'), // 表外
      },
      pages: [1, 3],
    );
    expect(scan.pages, [1, 3]);
    expect(scan.proofreadSkip, 0);
  });

  test('页表全部不可设时目标为空（弹窗按钮据此置灰）', () {
    final scan = BookOverlayPage.quickApplyTargetsFrom(
      annotations: {
        0: ann('p0', pageConfirmed: true),
        1: ann('p1', noMainText: true),
      },
      pages: [0, 1],
    );
    expect(scan.pages, isEmpty);
    expect(scan.proofreadSkip, 1);
    expect(scan.noMainSkip, 1);
  });

  group('quickApplyPayloadFrom（草稿 → 逐页载荷）', () {
    test('正文+页眉：正文整组带入，页眉进 extras', () {
      final (mains, extras) = BookOverlayPage.quickApplyPayloadFrom({
        RegionLabel.mainText: [const Rect.fromLTWH(10, 20, 300, 400)],
        RegionLabel.header: [const Rect.fromLTWH(10, 0, 300, 15)],
      });
      expect(mains, [const Rect.fromLTWH(10, 20, 300, 400)]);
      expect(extras, {
        RegionLabel.header: [const Rect.fromLTWH(10, 0, 300, 15)],
      });
    });

    test('只画页眉/页脚：正文 null = 不动主区（确认保留）', () {
      final (mains, extras) = BookOverlayPage.quickApplyPayloadFrom({
        RegionLabel.header: [const Rect.fromLTWH(10, 0, 300, 15)],
        RegionLabel.footer: [
          const Rect.fromLTWH(10, 580, 300, 15),
          const Rect.fromLTWH(320, 580, 300, 15),
        ],
      });
      expect(mains, isNull);
      expect(extras[RegionLabel.footer], hasLength(2));
    });

    test('退化框（<2 画布像素）丢弃；过滤后为空的类别整类剔除', () {
      final (mains, extras) = BookOverlayPage.quickApplyPayloadFrom({
        // 正文只剩误触残留（宽 1）→ 不落，且不删各页主区（null 语义）。
        RegionLabel.mainText: [const Rect.fromLTWH(1, 1, 1, 400)],
        RegionLabel.pageNumber: [const Rect.fromLTWH(0, 0, 1, 1)],
      });
      expect(mains, isNull);
      expect(extras, isEmpty);
    });
  });
}
