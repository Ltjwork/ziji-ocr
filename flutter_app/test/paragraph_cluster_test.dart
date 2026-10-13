import 'dart:ui';

import 'package:gujichazi/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 竖排分段：短列断段 + 列间距断段。
/// 数据取自真实古籍页（紫云论斗数曜赋性 第一册）12 列坐标，
/// 行 id 为数组索引（l_0 = 最右列 x1330，rtl 阅读序从它开始）。
void main() {
  // (x, y, w, h)：索引 0/4/9/11 为短列（段落末列）
  final cols = [
    (1330, 287, 74, 1026), // 短（段末）
    (1158, 286, 90, 2076),
    (1071, 285, 94, 2077),
    (989, 286, 91, 2077),
    (907, 289, 70, 463), // 短（段末）
    (736, 287, 91, 2077),
    (653, 290, 89, 2074),
    (568, 300, 90, 2066),
    (482, 288, 92, 2076),
    (401, 290, 78, 1079), // 短（段末）
    (229, 290, 92, 2077),
    (147, 292, 68, 420), // 短（段末）
  ];

  PageAnnotation buildAnn() {
    final lines = <LineBlock>[];
    for (var i = 0; i < cols.length; i++) {
      final (x, y, w, h) = cols[i];
      lines.add(LineBlock(
        id: 'l_$i',
        x: x,
        y: y,
        w: w,
        h: h,
        lineNo: i,
        orientation: 'vertical',
      ));
    }
    return PageAnnotation(pageId: 'page_000', imagePath: 'x.png', lines: lines);
  }

  test('竖排自动分段按短列断段，不再拆成单行', () {
    final ann = buildAnn();
    ann.inferHierarchy(orientation: 'vertical', horizontalDir: 'rtl');
    expect(ann.paragraphs.length, 4);
    // rtl 阅读序：[l_0] | [l_1,l_2,l_3,l_4] | [l_5..l_9] | [l_10,l_11]
    expect(ann.paragraphs[0].lineIds, ['l_0']);
    expect(ann.paragraphs[1].lineIds, ['l_1', 'l_2', 'l_3', 'l_4']);
    expect(ann.paragraphs[2].lineIds, ['l_5', 'l_6', 'l_7', 'l_8', 'l_9']);
    expect(ann.paragraphs[3].lineIds, ['l_10', 'l_11']);
    expect(ann.paragraphs.every((p) => !p.manual), isTrue);
    for (final p in ann.paragraphs) {
      for (final id in p.lineIds) {
        expect(ann.lines.firstWhere((l) => l.id == id).paragraphId, p.id);
      }
    }
  });

  test('rebuildParagraphs 保留手动段并按矩形认领，其余行重新分段', () {
    final ann = buildAnn();
    ann.inferHierarchy(orientation: 'vertical', horizontalDir: 'rtl');

    // 用户手动画一个段框，盖住最右两列（索引 0/1）
    final manual = Paragraph(
      id: 'p_manual',
      x: 1140,
      y: 270,
      w: 280,
      h: 2100,
      manual: true,
      lineIds: [],
    );
    ann.paragraphs.add(manual);

    ann.rebuildParagraphs(orientation: 'vertical', horizontalDir: 'rtl');

    // 手动段认领了中心点在框内的 l_0 / l_1
    expect(manual.lineIds, ['l_0', 'l_1']);
    for (final id in manual.lineIds) {
      expect(ann.lines.firstWhere((l) => l.id == id).paragraphId, 'p_manual');
    }
    // 手动段保留；其余行重新聚为 3 个自动段，短列索引 4/9/11 仍是段末
    expect(ann.paragraphs.where((p) => p.manual).length, 1);
    expect(ann.paragraphs.where((p) => !p.manual).length, 3);
    final autoParas = ann.paragraphs.where((p) => !p.manual).toList();
    expect(autoParas.any((p) => p.lineIds.last == 'l_4'), isTrue);
    expect(autoParas.any((p) => p.lineIds.last == 'l_9'), isTrue);
    expect(autoParas.any((p) => p.lineIds.last == 'l_11'), isTrue);
  });

  test('认领后为空的手动段保留（新段等待级联补行，不被并发识别回包洗掉）', () {
    // 用户在还没有行框的区域新画一个段：保存后段级联才去识别补行，
    // 这期间任何并发识别的回包合并（区域级联走 rebuildParagraphs）
    // 都不得把这个空段移除——此前"空手动段即移除"让它直接消失。
    final ann = buildAnn();
    final manual = Paragraph(
      id: 'p_empty',
      x: 0,
      y: 0,
      w: 10,
      h: 10, // 不覆盖任何行
      manual: true,
    );
    ann.paragraphs.add(manual);
    ann.rebuildParagraphs(orientation: 'vertical', horizontalDir: 'rtl');
    expect(ann.paragraphs.any((p) => p.id == 'p_empty'), isTrue);
    expect(ann.paragraphs.firstWhere((p) => p.id == 'p_empty').lineIds,
        isEmpty);
    // 自动段照常按行重建
    expect(ann.paragraphs.where((p) => !p.manual).length, 4);
  });

  test('页面无行时手动段保留、自动段清空', () {
    // 空页上新画的段（整页还没有任何行）：rebuildParagraphs 不得连它
    // 一起清掉。
    final ann = buildAnn();
    ann.paragraphs.add(
      Paragraph(id: 'p_new', x: 100, y: 100, w: 90, h: 400, manual: true),
    );
    ann.lines.clear();
    ann.rebuildParagraphs(orientation: 'vertical', horizontalDir: 'rtl');
    expect(
      ann.paragraphs.map((p) => p.id).toList(),
      ['p_new'],
    );
  });

  test('removeParagraphWithLines 删段连带成员行与行内单字', () {
    // 双段页：删其中一段，其成员行（lineIds 与 paragraphId 双口径）及
    // 行内单字一并删除，另一段与其行/字不受影响，死引用同步清理。
    LineBlock mkLine(String id, String paraId, int x) {
      final chars = [
        CharBlock(
          id: 'c_${id}_0',
          x: x,
          y: 300,
          w: 60,
          h: 90,
          col: 0,
          order: 0,
          text: '甲',
          lineId: id,
        ),
        CharBlock(
          id: 'c_${id}_1',
          x: x,
          y: 400,
          w: 60,
          h: 90,
          col: 0,
          order: 1,
          text: '乙',
          lineId: id,
        ),
      ];
      return LineBlock(
        id: id,
        x: x,
        y: 300,
        w: 70,
        h: 200,
        lineNo: 0,
        orientation: 'vertical',
        paragraphId: paraId,
        chars: chars,
      );
    }

    final keepA = mkLine('l_a', 'p_keep', 1300);
    final keepB = mkLine('l_b', 'p_keep', 1200);
    // l_c 的 paragraphId 指向待删段，但未登记在段的 lineIds 里（lineIds
    // 滞后于行归属的实际状态）——双口径判定也要删掉它。
    final orphan = mkLine('l_c', 'p_del', 1100);
    final del = mkLine('l_d', 'p_del', 1000);
    final ann = PageAnnotation(
      pageId: 'page_000',
      imagePath: 'x.png',
      lines: [keepA, keepB, orphan, del],
    );
    final pKeep = Paragraph(
      id: 'p_keep',
      x: 1150,
      y: 250,
      w: 250,
      h: 400,
      lineIds: ['l_a', 'l_b', 'l_d'], // l_d 是历史死引用，应被清理
    );
    final pDel = Paragraph(
      id: 'p_del',
      x: 950,
      y: 250,
      w: 250,
      h: 400,
      lineIds: ['l_d'],
    );
    ann.paragraphs.addAll([pKeep, pDel]);
    ann.rebuildBlocks();

    final removed = ann.removeParagraphWithLines(pDel);

    expect(removed, 2); // l_c（paragraphId 口径）+ l_d（lineIds 口径）
    expect(ann.lines.map((l) => l.id).toList(), ['l_a', 'l_b']);
    expect(ann.paragraphs.map((p) => p.id).toList(), ['p_keep']);
    expect(pKeep.lineIds, ['l_a', 'l_b']); // 指向死行 l_d 的引用已清理
    ann.rebuildBlocks();
    expect(
      ann.blocks.map((c) => c.id).toList(),
      ['c_l_a_0', 'c_l_a_1', 'c_l_b_0', 'c_l_b_1'],
    );
  });

  test('连画两个新段不顶替：空段（等级联补行）不被认领清理删掉', () {
    // 用户先画一个段（区内还没有行框，保存后段级联识别进行中，
    // lineIds 为空），期间再画第二个段——认领清理不得把第一个顺带
    // 删掉（此前 removeWhere(lineIds.isEmpty) 对本来就空的段也成立，
    // 新段被"顶替"消失）。
    final ann = buildAnn();
    final first = Paragraph(
      id: 'p_first',
      x: 100,
      y: 2400,
      w: 1300,
      h: 300, // 页面下方空白区，不覆盖任何行
      manual: true,
    );
    ann.addParagraphClaiming(first);
    expect(first.lineIds, isEmpty);

    final second = Paragraph(
      id: 'p_second',
      x: 1140,
      y: 270,
      w: 280,
      h: 2100, // 盖住最右两列
      manual: true,
    );
    ann.addParagraphClaiming(second);

    expect(ann.paragraphs.any((p) => p.id == 'p_first'), isTrue);
    expect(ann.paragraphs.any((p) => p.id == 'p_second'), isTrue);
    expect(second.lineIds, ['l_0', 'l_1']);
  });

  test('新段抢走旧段全部行 → 旧段移除（最后修改者胜）；部分抢行则保留', () {
    final ann = buildAnn();
    final old = Paragraph(
      id: 'p_old',
      x: 1140,
      y: 270,
      w: 280,
      h: 2100,
      lineIds: ['l_0', 'l_1'],
    );
    ann.paragraphs.add(old);
    for (final l in ann.lines) {
      if (old.lineIds.contains(l.id)) l.paragraphId = old.id;
    }

    // 全覆盖抢行：old 被掏空 → 移除
    final cover = Paragraph(
      id: 'p_cover',
      x: 1140,
      y: 270,
      w: 280,
      h: 2100,
      manual: true,
    );
    final removed = ann.addParagraphClaiming(cover);
    expect(removed, ['p_old']);
    expect(ann.paragraphs.any((p) => p.id == 'p_old'), isFalse);
    expect(cover.lineIds, ['l_0', 'l_1']);
    expect(
      ann.lines.firstWhere((l) => l.id == 'l_0').paragraphId,
      'p_cover',
    );

    // 部分抢行：只盖住 l_0，cover 保留 l_1，不被移除
    final half = Paragraph(
      id: 'p_half',
      x: 1328,
      y: 270,
      w: 80,
      h: 2100,
      manual: true,
    );
    final removed2 = ann.addParagraphClaiming(half);
    expect(removed2, isEmpty);
    expect(ann.paragraphs.any((p) => p.id == 'p_cover'), isTrue);
    expect(cover.lineIds, ['l_1']);
    expect(half.lineIds, ['l_0']);
  });

  test('Paragraph.manual 序列化往返', () {
    final j = Paragraph(id: 'p1', x: 1, y: 2, w: 3, h: 4, manual: true).toJson();
    expect(Paragraph.fromJson(j).manual, isTrue);
    expect(
      Paragraph.fromJson({'id': 'p2', 'x': 1, 'y': 2, 'w': 3, 'h': 4}).manual,
      isFalse,
    );
  });

  test('用户实际数据：9 行部分页（含已删列）force 重建为 3 个正确段落', () {
    // 取自用户 page_000.json 实际状态（右侧 3 列已被删除）
    final cols = [
      (1072, 285, 92, 2077), // 满
      (990, 285, 90, 2078), // 满
      (908, 289, 69, 462), // 短（段末 "枯興衰的命理之學。"）
      (737, 287, 90, 2076), // 满
      (651, 289, 92, 2075), // 满
      (570, 330, 86, 2034), // 满
      (483, 287, 92, 2077), // 满
      (401, 289, 79, 1080), // 短（段末 "都不可得"）
      (148, 293, 65, 418), // 短（段末 "可能學好星曜賦性"）
    ];
    final lines = <LineBlock>[];
    for (var i = 0; i < cols.length; i++) {
      final (x, y, w, h) = cols[i];
      lines.add(LineBlock(id: 'l_$i', x: x, y: y, w: w, h: h, lineNo: i));
    }
    final ann = PageAnnotation(
      pageId: 'page_000',
      imagePath: 'x.png',
      lines: lines,
    );
    // 存量旧数据：单行段落（非手动）
    for (var i = 0; i < 6; i++) {
      final (x, y, w, h) = cols[i];
      ann.paragraphs.add(Paragraph(
        id: 'p_old_$i',
        x: x,
        y: y,
        w: w,
        h: h,
        lineIds: ['l_$i'],
      ));
    }

    ann.inferHierarchy(
      orientation: 'vertical',
      horizontalDir: 'rtl',
      force: true,
    );

    expect(ann.paragraphs.length, 3);
    expect(ann.paragraphs[0].lineIds, ['l_0', 'l_1', 'l_2']);
    expect(ann.paragraphs[1].lineIds, ['l_3', 'l_4', 'l_5', 'l_6', 'l_7']);
    expect(ann.paragraphs[2].lineIds, ['l_8']);
    // 每行都归属到段
    for (final l in ann.lines) {
      expect(l.paragraphId, isNotEmpty);
    }
  });

  test('段首空两格：上一列写满时靠缩进起始边断段', () {
    // 行带字框（charH≈2076/36≈57.7），B1 段首空两格（top 比基准低 115px≈2字）
    LineBlock col(int i, int x, int y, int h) => LineBlock(
          id: 'l_$i',
          x: x,
          y: y,
          w: 90,
          h: h,
          lineNo: i,
          chars: List.generate(
            36,
            (j) => CharBlock(
              id: 'c_${i}_$j',
              x: x,
              y: y + j * (h ~/ 36),
              w: 90,
              h: h ~/ 36,
              col: i,
              order: j,
            ),
          ),
        );
    // rtl 阅读序：A1(900) A2(810) 段A；B1(720, top+115 空两格) B2(630, 短列收尾) 段B
    final lines = [
      col(0, 900, 285, 2076), // A1 满
      col(1, 810, 285, 2076), // A2 满（段A末列写满，无短列信号）
      col(2, 720, 400, 1861), // B1 段首空两格（bottom 与满列齐）
      col(3, 630, 285, 1076), // B2 短列（段B末）
    ];
    final ann = PageAnnotation(
      pageId: 'page_000',
      imagePath: 'x.png',
      lines: lines,
    );
    ann.inferHierarchy(orientation: 'vertical', horizontalDir: 'rtl');
    expect(ann.paragraphs.length, 2);
    expect(ann.paragraphs[0].lineIds, ['l_0', 'l_1']);
    expect(ann.paragraphs[1].lineIds, ['l_2', 'l_3']);
  });

  test('行框抖动（top 偏移小于 1.2 字高）不误断段', () {
    // 依据用户真实数据：某列 top 比基准低 45px（≈0.73 字高），属检测框抖动
    LineBlock col(int i, int x, int y, int h, int n) => LineBlock(
          id: 'l_$i',
          x: x,
          y: y,
          w: 90,
          h: h,
          lineNo: i,
          chars: List.generate(
            n,
            (j) => CharBlock(
              id: 'c_${i}_$j',
              x: x,
              y: y + j,
              w: 90,
              h: h ~/ n,
              col: i,
              order: j,
            ),
          ),
        );
    final lines = [
      col(0, 737, 287, 2076, 36),
      col(1, 651, 289, 2075, 37),
      col(2, 570, 330, 2034, 36), // top+45 抖动，仍属同一段
      col(3, 483, 287, 2077, 37),
    ];
    final ann = PageAnnotation(
      pageId: 'page_000',
      imagePath: 'x.png',
      lines: lines,
    );
    ann.inferHierarchy(orientation: 'vertical', horizontalDir: 'rtl');
    expect(ann.paragraphs.length, 1);
    expect(ann.paragraphs[0].lineIds, ['l_0', 'l_1', 'l_2', 'l_3']);
  });

  // ── 层级包含：行框 ⊆ 段落框 ⊆ 主区框 ────────────────────────────

  test('段落框钳进主区，伸出主区的行框随之钳进段落', () {
    final ann = PageAnnotation(pageId: 'page_000', imagePath: 'x.png');
    ann.mainRegions.add(
      MainRegion(id: 'mr_001', x: 100, y: 100, w: 400, h: 800),
    );
    // l_2 底部伸出主区 40px（标点墨迹外扩情景），两列同段
    ann.lines.addAll([
      LineBlock(
        id: 'l_1',
        x: 200,
        y: 120,
        w: 80,
        h: 700,
        lineNo: 0,
        orientation: 'vertical',
      ),
      LineBlock(
        id: 'l_2',
        x: 300,
        y: 120,
        w: 80,
        h: 820,
        lineNo: 1,
        orientation: 'vertical',
      ),
    ]);
    ann.inferHierarchy(orientation: 'vertical', horizontalDir: 'rtl');
    expect(ann.paragraphs.length, 1);
    final p = ann.paragraphs.first;
    // 段落框（行外接矩形 y 120..940）钳进主区（底边收到 900）
    expect(p.x, 200);
    expect(p.y, 120);
    expect(p.w, 180);
    expect(p.h, 780);
    expect(p.mainRegionId, 'mr_001');
    // 越界行框钳进段落；界内行框原样不动
    final l2 = ann.lines.firstWhere((l) => l.id == 'l_2');
    expect(l2.h, 780);
    final l1 = ann.lines.firstWhere((l) => l.id == 'l_1');
    expect(l1.h, 700);
    // 三层嵌套成立
    expect(hostContains(p.rect, l1.rect), isTrue);
    expect(hostContains(p.rect, l2.rect), isTrue);
    expect(hostContains(ann.mainRegions.first.rect, p.rect), isTrue);
  });

  test('段落中心在主区外（版面边缘小字段）不钳制', () {
    final ann = PageAnnotation(pageId: 'page_000', imagePath: 'x.png');
    ann.mainRegions.add(
      MainRegion(id: 'mr_001', x: 100, y: 100, w: 400, h: 800),
    );
    ann.lines.add(
      LineBlock(
        id: 'l_1',
        x: 600,
        y: 200,
        w: 60,
        h: 300,
        lineNo: 0,
        orientation: 'vertical',
      ),
    );
    ann.inferHierarchy(orientation: 'vertical', horizontalDir: 'rtl');
    expect(ann.paragraphs.length, 1);
    final p = ann.paragraphs.first;
    expect(p.x, 600);
    expect(p.y, 200);
    expect(p.w, 60);
    expect(p.h, 300);
    expect(ann.lines.first.h, 300);
    expect(hostContains(ann.mainRegions.first.rect, p.rect), isFalse);
  });
}

/// host 完全包含 inner（允许 1px 取整误差）。
bool hostContains(Rect host, Rect inner) {
  bool ge(double a, double b) => a >= b - 1.0;
  bool le(double a, double b) => a <= b + 1.0;
  return ge(inner.left, host.left) &&
      ge(inner.top, host.top) &&
      le(inner.right, host.right) &&
      le(inner.bottom, host.bottom);
}
