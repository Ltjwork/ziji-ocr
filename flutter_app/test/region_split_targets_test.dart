import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/pages/book_region_grid_page.dart';

/// 主区快设「按主区拆分」目标页计算的回归测试（+111 改为"主区已确认
/// 且非整页绿框"口径）。历史演变：最初只拆会话内存态的"本次已改"，
/// +107 加"从未识别"回退队列，+110 改为未确认页（isFullyConfirmed 为
/// 假）——但用户口径是按网格视觉状态：右上角绿色"已确认"角标（主区
/// boxConfirmed）的页要能重拆，整圈绿框（「确认并保存」过的校对成果）
/// 的页不动，主区没确认过的页（只画未确认）也不拆。
void main() {
  PageAnnotation ann(
    String pageId, {
    String? label,
    bool withLines = false,
    bool regionConfirmed = false, // 主区 boxConfirmed（绿色"已确认"角标）
    bool pageConfirmed = false, // status=confirmed（整页绿框的构成条件）
    bool boxesReviewed = false, // 「确认识别框」过（玫红框）
  }) => PageAnnotation(
    pageId: pageId,
    imagePath: '$pageId.png',
    boxesReviewed: boxesReviewed,
    mainRegions: [
      MainRegion(
        id: 'mr_$pageId',
        x: 1,
        y: 2,
        w: 300,
        h: 400,
        label: label ?? RegionLabel.mainText,
        status: pageConfirmed
            ? AnnotationStatus.confirmed
            : AnnotationStatus.proposed,
        boxConfirmed: regionConfirmed,
      ),
    ],
    lines: withLines
        ? [
            // isFullyConfirmed 要求行 status 也是 confirmed（空字框列表
            // 的 every 恒真，符合口径）。
            LineBlock(
              id: 'l1',
              x: 1,
              y: 2,
              w: 300,
              h: 20,
              lineNo: 0,
              status: pageConfirmed
                  ? AnnotationStatus.confirmed
                  : AnnotationStatus.proposed,
            ),
          ]
        : const [],
  );

  test('主区已确认且非页面级确认（绿框/玫红框）的页入队（含已拆分过的）', () {
    final annotations = <int, PageAnnotation>{
      0: ann('p0', regionConfirmed: true), // 主区已确认、从未识别 → 入队
      1: ann('p1', regionConfirmed: true, withLines: true), // 已拆分过 → 入队
      2: ann(
        'p2',
        regionConfirmed: true,
        pageConfirmed: true,
      ), // 整页绿框（也有角标）→ 不入队
      3: ann('p3'), // 主区只画未确认 → 不入队
      4: ann(
        'p4',
        label: RegionLabel.header,
        regionConfirmed: true,
      ), // 只有页眉 → 不入队
      5: ann(
        'p5',
        regionConfirmed: true,
        boxesReviewed: true,
      ), // 玫红框（确认识别框）→ 不入队
      // 6: 无标注文件 → 不入队
    };
    expect(
      BookRegionGridPage.splitTargetsFrom(
        loading: false,
        annotations: annotations,
        pageCount: 7,
      ),
      [0, 1],
    );
  });

  test('加载中不给出目标（全书标注尚未读完，避免半截队列）', () {
    expect(
      BookRegionGridPage.splitTargetsFrom(
        loading: true,
        annotations: {0: ann('p0', regionConfirmed: true)},
        pageCount: 1,
      ),
      isEmpty,
    );
  });

  test('全书页面级确认（绿框/玫红框）→ 空队列（按钮置灰）', () {
    final annotations = <int, PageAnnotation>{
      0: ann('p0', regionConfirmed: true, pageConfirmed: true),
      1: ann('p1', regionConfirmed: true, pageConfirmed: true, withLines: true),
      2: ann('p2', regionConfirmed: true, boxesReviewed: true),
    };
    expect(
      BookRegionGridPage.splitTargetsFrom(
        loading: false,
        annotations: annotations,
        pageCount: 3,
      ),
      isEmpty,
    );
  });

  test('多主区页（未裁开双页）：全部主区确认过才入队', () {
    PageAnnotation twoMains(String pageId, {required bool secondConfirmed}) {
      final a = ann(pageId, regionConfirmed: true);
      a.mainRegions.add(
        MainRegion(
          id: 'mr2_$pageId',
          x: 400,
          y: 2,
          w: 300,
          h: 400,
          boxConfirmed: secondConfirmed,
        ),
      );
      return a;
    }

    final annotations = <int, PageAnnotation>{
      0: twoMains('p0', secondConfirmed: true), // 两条都确认 → 入队
      1: twoMains('p1', secondConfirmed: false), // 第二条没确认 → 不入队
    };
    expect(
      BookRegionGridPage.splitTargetsFrom(
        loading: false,
        annotations: annotations,
        pageCount: 2,
      ),
      [0],
    );
  });

  group('自动加页眉/页脚候选框目标页（范围选项）', () {
    test('仅未确认页：跳过已确认（主区确认/确认无正文），保留未确认与无标注页', () {
      final noMain = ann('p3', regionConfirmed: true)
        ..mainRegions.clear()
        ..noMainTextConfirmed = true; // 扉页确认无正文 → 已确认
      final annotations = <int, PageAnnotation>{
        0: ann('p0', regionConfirmed: true), // 绿色角标 → 跳过
        1: ann('p1'), // 只画未确认 → 加
        2: noMain, // 确认无正文 → 跳过
        // 3: 无标注文件 → 视为未确认 → 加
      };
      expect(
        BookRegionGridPage.prelabelTargetsFrom(
          loading: false,
          annotations: annotations,
          pageCount: 4,
          unconfirmedOnly: true,
        ),
        [1, 3],
      );
    });

    test('全部页面：不管确认状态，全部下标入队', () {
      expect(
        BookRegionGridPage.prelabelTargetsFrom(
          loading: false,
          annotations: {0: ann('p0', regionConfirmed: true)},
          pageCount: 3,
          unconfirmedOnly: false,
        ),
        [0, 1, 2],
      );
    });

    test('加载中不给出目标（避免按半截标注判"已确认"漏页）', () {
      expect(
        BookRegionGridPage.prelabelTargetsFrom(
          loading: true,
          annotations: {0: ann('p0')},
          pageCount: 1,
          unconfirmedOnly: true,
        ),
        isEmpty,
      );
      expect(
        BookRegionGridPage.prelabelTargetsFrom(
          loading: true,
          annotations: {0: ann('p0')},
          pageCount: 1,
          unconfirmedOnly: false,
        ),
        isEmpty,
      );
    });
  });
}
