// 阅读顺序重排器（ReadingOrderCalculator）方向参数测试：
// 竖排列序随 horizontalDir（rtl=右→左 / ltr=左→右）、列内随 verticalDir
// （ttb=上→下 / btt=下→上）、小注侧序随 horizontalDir；横排分支既有行为
// （verticalDir 决定行序、horizontalDir 决定同行内左右）不受影响。
import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/services/reading_order.dart';

PageAnnotation _ann(List<LineBlock> lines) => PageAnnotation(
      pageId: 'p',
      imagePath: 'unused',
      lines: lines,
    );

LineBlock _line(
  String id,
  int x,
  int y, {
  int w = 80,
  int h = 400,
  String layoutRole = 'body',
}) => LineBlock(
      id: id,
      x: x,
      y: y,
      w: w,
      h: h,
      lineNo: 0,
      layoutRole: layoutRole,
    );

void main() {
  // 三列：C(x=400) A(x=240) B(x=80)；A 列内两行（上/下）。
  final lines = [
    _line('a1', 240, 100, h: 150),
    _line('a2', 240, 300, h: 150),
    _line('b1', 80, 100, h: 150),
    _line('c1', 400, 100, h: 150),
  ];

  test('竖排 rtl/ttb（默认）：列右→左，列内上→下', () {
    final ordered = ReadingOrderCalculator.reorder(_ann(lines));
    expect(ordered.map((l) => l.id).toList(), ['c1', 'a1', 'a2', 'b1']);
  });

  test('竖排 ltr：列左→右', () {
    final ordered = ReadingOrderCalculator.reorder(
      _ann(lines),
      horizontalDir: 'ltr',
    );
    expect(ordered.map((l) => l.id).toList(), ['b1', 'a1', 'a2', 'c1']);
  });

  test('竖排 btt：列内下→上（列序仍随 horizontalDir）', () {
    final ordered = ReadingOrderCalculator.reorder(
      _ann(lines),
      verticalDir: 'btt',
    );
    expect(ordered.map((l) => l.id).toList(), ['c1', 'a2', 'a1', 'b1']);
  });

  test('readingOrder 序号与输出顺序一致', () {
    final ordered = ReadingOrderCalculator.reorder(_ann(lines));
    for (var i = 0; i < ordered.length; i++) {
      expect(ordered[i].readingOrder, i);
    }
  });

  test('小注行侧序随 horizontalDir（rtl 右注先读，ltr 左注先读）', () {
    // 正文行 a1（x=240）挂两条小注：右注 r（x=285）、左注 l（x=195）。
    // 小注判定看行内 chars 全为 annotation 类型（_isAnnotationLine）。
    CharBlock annoChar(String id, int x) => CharBlock(
          id: id,
          x: x,
          y: 100,
          w: 30,
          h: 30,
          col: 0,
          order: 0,
          type: 'annotation',
        );
    final body = _line('a1', 240, 100, h: 400);
    final right = _line('r', 285, 100, w: 40, h: 400)
      ..chars = [annoChar('rc', 285)];
    final left = _line('l', 195, 100, w: 40, h: 400)
      ..chars = [annoChar('lc', 195)];
    final ann = _ann([body, right, left]);
    final rtlOrder = ReadingOrderCalculator.reorder(ann);
    final rtlIds = rtlOrder.map((l) => l.id).toList();
    expect(rtlIds.indexOf('r') < rtlIds.indexOf('l'), isTrue,
        reason: 'rtl 应右注先读');
    final ltrOrder = ReadingOrderCalculator.reorder(ann, horizontalDir: 'ltr');
    final ltrIds = ltrOrder.map((l) => l.id).toList();
    expect(ltrIds.indexOf('l') < ltrIds.indexOf('r'), isTrue,
        reason: 'ltr 应左注先读');
  });

  test('横排分支不回归：ttb+ltr 与 btt+rtl', () {
    final hLines = [
      _line('h1', 100, 100, w: 400, h: 60),
      _line('h2', 100, 200, w: 400, h: 60),
    ];
    final ann = _ann(hLines);
    expect(
      ReadingOrderCalculator.reorder(
        ann,
        orientation: 'horizontal',
      ).map((l) => l.id).toList(),
      ['h1', 'h2'],
    );
    expect(
      ReadingOrderCalculator.reorder(
        ann,
        orientation: 'horizontal',
        verticalDir: 'btt',
      ).map((l) => l.id).toList(),
      ['h2', 'h1'],
    );
  });
}
