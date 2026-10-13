import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/models/table_block.dart';
import 'package:gujichazi/pages/book_region_grid_page.dart';

/// 主区快设「清除未确认页框」判定本体的回归测试：
/// - 未确认（无绿色角标）且有框（版面区/行/字/段落/表格任一）→ 清；
/// - 主区已确认（绿色角标）、校对完成（整页绿框/玫红框/旧版 reviewed）
///   与「确认无正文」的页 → 人工认可的框，不清；
/// - 无标注/无框的页无可清 → 不清。
void main() {
  PageAnnotation ann(
    String pageId, {
    bool regionConfirmed = false, // 主区 boxConfirmed（绿色"已确认"角标）
    bool pageConfirmed = false, // status=confirmed（整页绿框的构成条件）
    bool boxesReviewed = false, // 「确认识别框」过（玫红框）
    bool reviewed = false, // 旧版「确认并保存」
    bool noMainText = false, // 「确认无正文」（扉页/插图）
    bool withRegion = true, // 带一个版面区框
    bool withLines = false, // 带行/字框（识别输出）
    bool withTables = false, // 带表格识别结果
  }) =>
      PageAnnotation(
        pageId: pageId,
        imagePath: '$pageId.png',
        boxesReviewed: boxesReviewed,
        reviewed: reviewed,
        noMainTextConfirmed: noMainText,
        lines: withLines
            ? [
                LineBlock(id: 'l1', x: 1, y: 2, w: 30, h: 300, lineNo: 0),
              ]
            : const [],
        tables: withTables
            ? [
                TableAnnotation(
                  id: 't1',
                  x: 10,
                  y: 10,
                  w: 200,
                  h: 200,
                  rows: 2,
                  cols: 2,
                ),
              ]
            : const [],
        mainRegions: withRegion
            ? [
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
              ]
            : const [],
      );

  test('未确认且有版面区框 → 清', () {
    expect(BookRegionGridPage.shouldClearUnconfirmedBoxes(ann('p0')), isTrue);
  });

  test('只有行/字框（拆分产物）或表格、没画过版面区 → 也清', () {
    expect(
      BookRegionGridPage.shouldClearUnconfirmedBoxes(
        ann('p1', withRegion: false, withLines: true),
      ),
      isTrue,
    );
    expect(
      BookRegionGridPage.shouldClearUnconfirmedBoxes(
        ann('p2', withRegion: false, withTables: true),
      ),
      isTrue,
    );
  });

  test('主区已确认（绿色角标）→ 人工认可的框不清', () {
    expect(
      BookRegionGridPage.shouldClearUnconfirmedBoxes(ann('p3', regionConfirmed: true)),
      isFalse,
    );
  });

  test('校对完成（整页绿框/玫红框/旧版 reviewed）→ 不清', () {
    expect(
      BookRegionGridPage.shouldClearUnconfirmedBoxes(ann('p4', pageConfirmed: true)),
      isFalse,
    );
    expect(
      BookRegionGridPage.shouldClearUnconfirmedBoxes(ann('p5', boxesReviewed: true)),
      isFalse,
    );
    expect(
      BookRegionGridPage.shouldClearUnconfirmedBoxes(ann('p6', reviewed: true)),
      isFalse,
    );
  });

  test('「确认无正文」的页 → 已认可，不清', () {
    expect(
      BookRegionGridPage.shouldClearUnconfirmedBoxes(
        ann('p7', noMainText: true, withRegion: false),
      ),
      isFalse,
    );
  });

  test('无标注/无框的页无可清', () {
    expect(BookRegionGridPage.shouldClearUnconfirmedBoxes(null), isFalse);
    expect(
      BookRegionGridPage.shouldClearUnconfirmedBoxes(
        ann('p8', withRegion: false),
      ),
      isFalse,
    );
  });
}
