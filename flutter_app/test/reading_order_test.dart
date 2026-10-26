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

Paragraph _para(
  String id,
  int x,
  int y,
  int w,
  int h, {
  bool manual = true,
}) =>
    Paragraph(id: id, x: x, y: y, w: w, h: h, manual: manual);

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

  group('orderBreakIds（行视图序号断点检查）', () {
    // 两列：c1(x=400) c2(x=240)，竖排默认 rtl → 几何序 [c1, c2]。
    test('列表序与几何序一致 → 无断点', () {
      final lines = [_line('c1', 400, 100, h: 150), _line('c2', 240, 100, h: 150)];
      expect(ReadingOrderCalculator.orderBreakIds(lines), isEmpty);
    });

    test('列表序颠倒 → 两端行都算断点', () {
      final lines = [_line('c2', 240, 100, h: 150), _line('c1', 400, 100, h: 150)];
      expect(
        ReadingOrderCalculator.orderBreakIds(lines),
        {'c1', 'c2'},
      );
    });

    test('方向感知：同一列表在 ltr 下连续、默认 rtl 下断裂', () {
      final lines = [_line('l1', 80, 100, h: 150), _line('r1', 400, 100, h: 150)];
      expect(ReadingOrderCalculator.orderBreakIds(lines, horizontalDir: 'ltr'),
          isEmpty);
      expect(ReadingOrderCalculator.orderBreakIds(lines), {'l1', 'r1'});
    });

    test('横排：列表序与 y 序一致 → 无断点；颠倒 → 断点', () {
      final hLines = [
        _line('h1', 100, 100, w: 400, h: 60),
        _line('h2', 100, 200, w: 400, h: 60),
      ];
      expect(
        ReadingOrderCalculator.orderBreakIds(hLines, orientation: 'horizontal'),
        isEmpty,
      );
      expect(
        ReadingOrderCalculator.orderBreakIds(
          hLines.reversed.toList(),
          orientation: 'horizontal',
        ),
        {'h1', 'h2'},
      );
    });

    test('多行只有一处断口：只标记断口两侧行', () {
      // 几何序应为 [c1, c2, c3]；列表里 c3 被挪到最前（badge 0）→
      // 序号沿空间读作 1,2,0，唯一断口在 c2→c3（2 之后跟 0）；
      // c1→c2 是 1→2 恰好 +1，不算断点。
      final lines = [
        _line('c3', 80, 100, h: 150),
        _line('c1', 400, 100, h: 150),
        _line('c2', 240, 100, h: 150),
      ];
      expect(
        ReadingOrderCalculator.orderBreakIds(lines),
        {'c2', 'c3'},
      );
    });

    test('只读不写：不改动行的 readingOrder', () {
      final lines = [_line('c2', 240, 100, h: 150), _line('c1', 400, 100, h: 150)];
      ReadingOrderCalculator.orderBreakIds(lines);
      expect(lines.every((l) => l.readingOrder == -1), isTrue);
    });

    test('少于 2 行 → 空集', () {
      expect(ReadingOrderCalculator.orderBreakIds([_line('c1', 400, 100)]),
          isEmpty);
      expect(ReadingOrderCalculator.orderBreakIds(const []), isEmpty);
    });

    test('错位近距列不误报（用户实测页回归）：列距小于重排的中心距阈值、'
        '起点高低交错，列表序正确 → 无断点', () {
      // 两列中心相距 120（= 旧 0.8×平均行宽阈值上限），旧聚类会并成
      // 一个伪列、列内按 y 排（左列起点更高）翻成 [c2, c1] → 正确页
      // 被误标红。x 区间重叠只有 30 < 150×0.5，按重叠口径是两列。
      final c1 = _line('c1', 320, 150, w: 150); // 右列，起点低
      final c2 = _line('c2', 200, 55, w: 150); // 左列，起点高
      expect(ReadingOrderCalculator.orderBreakIds([c1, c2]), isEmpty);
      // 同页真实乱序（列表颠倒）仍要检出
      expect(
        ReadingOrderCalculator.orderBreakIds([c2, c1]),
        {'c1', 'c2'},
      );
    });

    test('同列上下两段（x 区间重叠）仍按一列处理：列内乱序检出', () {
      final top = _line('top', 240, 100, h: 200);
      final bottom = _line('bottom', 240, 300, h: 200);
      expect(ReadingOrderCalculator.orderBreakIds([top, bottom]), isEmpty);
      expect(
        ReadingOrderCalculator.orderBreakIds([bottom, top]),
        {'top', 'bottom'},
      );
    });
  });

  group('insertIndexForNewLine（手工补画缺列落位）', () {
    // 竖排 rtl 四列（x=400/320/160/80，w=80 互不重叠），识别漏了 x=240
    // 一列；列表已是几何序（序号校验空集）。用户实测回归：紫微斗数全书
    // split_page_380 中间漏两列，补画后被 add 到列表末尾编成 15/16 号，
    // 校验把补列前后整片标红——补对了反而挨报警。
    final base = [
      _line('l400', 400, 100),
      _line('l320', 320, 100),
      _line('l160', 160, 100),
      _line('l80', 80, 100),
    ];
    final missing = _line('miss', 240, 100);

    test('中间缺列返回几何落位下标；插入后序号校验不误报', () {
      final idx = ReadingOrderCalculator.insertIndexForNewLine(base, missing);
      expect(idx, 2);
      final merged = [...base]..insert(idx, missing);
      expect(ReadingOrderCalculator.orderBreakIds(merged), isEmpty);
    });

    test('旧实现（追加到末尾）在同一页面上必被检出——锁住回归语义', () {
      final appended = [...base, missing];
      expect(ReadingOrderCalculator.orderBreakIds(appended), isNotEmpty);
    });

    test('横排按 y 落位', () {
      final hBase = [
        _line('h1', 100, 100, w: 400, h: 40),
        _line('h3', 100, 500, w: 400, h: 40),
      ];
      final idx = ReadingOrderCalculator.insertIndexForNewLine(
        hBase,
        _line('h2', 100, 300, w: 400, h: 40),
        orientation: 'horizontal',
      );
      expect(idx, 1);
    });

    test('空列表 → 0', () {
      expect(
        ReadingOrderCalculator.insertIndexForNewLine(const [], missing),
        0,
      );
    });
  });

  group('段落主序（手动段落）', () {
    // 田字格四段（竖排 rtl）：段1=右上、段2=左上、段3=右下、段4=左下，
    // 段序与纯列序不同（纯几何会把右列上下两段连在一起读）。
    final p1 = _para('p1', 300, 0, 80, 200); // 右上
    final p2 = _para('p2', 100, 0, 80, 200); // 左上
    final p3 = _para('p3', 300, 200, 80, 200); // 右下
    final p4 = _para('p4', 100, 200, 80, 200); // 左下
    LineBlock inPara(String id, String paragraphId, int x, int y) {
      final l = _line(id, x, y, w: 80, h: 180);
      l.paragraphId = paragraphId;
      return l;
    }

    test('行序跟随段落在列表中的顺序（段序优先于纯列序）', () {
      final lines = [
        inPara('a', 'p3', 300, 210),
        inPara('b', 'p1', 300, 10),
        inPara('c', 'p4', 100, 210),
        inPara('d', 'p2', 100, 10),
      ];
      final ordered = ReadingOrderCalculator.readingSequence(
        lines,
        paragraphs: [p1, p2, p3, p4],
      );
      expect(ordered.map((l) => l.id).toList(), ['b', 'd', 'a', 'c']);
    });

    test('未归属段落的行（页眉等）排在全部段落之后', () {
      final lines = [
        _line('header', 100, 300, w: 80, h: 60),
        inPara('a', 'p1', 300, 10),
      ];
      final ordered = ReadingOrderCalculator.readingSequence(
        lines,
        paragraphs: [p1, p2, p3, p4],
      );
      expect(ordered.map((l) => l.id).toList(), ['a', 'header']);
    });

    test('列表序与段序一致 → 校验无断点；纯列序列表序 → 全页标红消除', () {
      // 段序阅读序 [b, d, a, c]；列表按段序排 → 无断点
      final inOrder = [
        inPara('b', 'p1', 300, 10),
        inPara('d', 'p2', 100, 10),
        inPara('a', 'p3', 300, 210),
        inPara('c', 'p4', 100, 210),
      ];
      expect(
        ReadingOrderCalculator.orderBreakIds(
          inOrder,
          paragraphs: [p1, p2, p3, p4],
        ),
        isEmpty,
      );
      // 纯几何列序 [b, a, d, c]（右列上下连读）在段序页面 = 真实乱序，
      // 仍要检出（用户以段序为准）
      final geometric = [
        inPara('b', 'p1', 300, 10),
        inPara('a', 'p3', 300, 210),
        inPara('d', 'p2', 100, 10),
        inPara('c', 'p4', 100, 210),
      ];
      expect(
        ReadingOrderCalculator.orderBreakIds(
          geometric,
          paragraphs: [p1, p2, p3, p4],
        ),
        isNotEmpty,
      );
    });

    test('纯自动分段（manual=false）不启用段序：保持纯几何序', () {
      final auto1 = _para('a1', 300, 0, 80, 400, manual: false);
      final auto2 = _para('a2', 100, 0, 80, 400, manual: false);
      final lines = [
        inPara('x', 'a1', 300, 10),
        inPara('y', 'a2', 100, 10),
      ];
      // 几何序（rtl）：右列先 → [x, y]，与段列表序相同；关键是
      // 手动段缺失时不走段主序路径（行为与旧版一致）
      final ordered = ReadingOrderCalculator.readingSequence(
        lines,
        paragraphs: [auto2, auto1], // 故意把列表序放反
      );
      expect(ordered.map((l) => l.id).toList(), ['x', 'y']);
    });

    test('sortLinesInPlace 原地重排为段序', () {
      final lines = [
        inPara('a', 'p3', 300, 210),
        inPara('b', 'p1', 300, 10),
        inPara('c', 'p4', 100, 210),
        inPara('d', 'p2', 100, 10),
      ];
      final ann = PageAnnotation(
        pageId: 'p',
        imagePath: 'unused',
        lines: lines,
        paragraphs: [p1, p2, p3, p4],
      );
      ReadingOrderCalculator.sortLinesInPlace(ann);
      expect(ann.lines.map((l) => l.id).toList(), ['b', 'd', 'a', 'c']);
    });
  });
}
