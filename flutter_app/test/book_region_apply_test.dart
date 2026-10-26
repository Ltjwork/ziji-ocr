import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/services/book_region_apply.dart';

LineBlock _line(
  String id,
  int x,
  int y, {
  bool manual = false,
  List<CharBlock>? chars,
}) => LineBlock(
  id: id,
  x: x,
  y: y,
  w: 40,
  h: 300,
  lineNo: 0,
  manual: manual,
  chars: chars,
);

PageAnnotation _ann() => PageAnnotation(
  pageId: 'page_001',
  imagePath: 'page_001.png',
  mainRegions: [
    MainRegion(
      id: 'mr_001',
      x: 100,
      y: 100,
      w: 400,
      h: 800,
      uid: 'uid_r1',
      status: AnnotationStatus.confirmed,
      boxConfirmed: true,
    ),
  ],
  paragraphs: [
    Paragraph(
      id: 'p_1',
      x: 100,
      y: 100,
      w: 400,
      h: 800,
      mainRegionId: 'mr_001',
      lineIds: ['l_in_normal', 'l_in_manual'],
    ),
  ],
  lines: [
    _line('l_in_normal', 120, 120),
    _line('l_in_manual', 200, 120, manual: true),
    _line('l_out_normal', 20, 120),
    _line('l_out_manual', 20, 500, manual: true),
  ],
);

void main() {
  group('removeLinesInRect（表格区清场）', () {
    test('删掉中心落在区内的行（含钉住行）、段引用与行号同步、区外不动', () {
      final ann = _ann();
      final removed = BookRegionApply.removeLinesInRect(
        ann,
        const Rect.fromLTWH(100, 100, 400, 800),
      );
      // 区内两条（普通 + manual 钉住）都清——表格区内容以表格标注为准。
      expect(removed, 2);
      expect(
        ann.lines.map((l) => l.id).toList(),
        ['l_out_normal', 'l_out_manual'],
      );
      // 段成员引用被同步清空（两条区内行都在 p_1 里）
      expect(ann.paragraphs.single.lineIds, isEmpty);
      // 行号重排
      expect(ann.lines.first.lineNo, 0);
      expect(ann.lines.last.lineNo, 1);
    });

    test('区内无行时是空操作', () {
      final ann = _ann();
      final removed = BookRegionApply.removeLinesInRect(
        ann,
        const Rect.fromLTWH(0, 0, 10, 10),
      );
      expect(removed, 0);
      expect(ann.lines, hasLength(4));
    });
  });

  group('applyRegionOnly', () {
    test('替换主区几何并保留 id/uid/status/label，不动行/段/字', () {
      final ann = _ann();
      BookRegionApply.applyRegionOnly(
        ann,
        const Rect.fromLTWH(80, 60, 500, 900),
      );
      expect(ann.mainRegions, hasLength(1));
      final r = ann.mainRegions.single;
      expect(r.id, 'mr_001');
      expect(r.uid, 'uid_r1');
      expect(r.status, AnnotationStatus.confirmed);
      expect(r.boxConfirmed, isTrue);
      expect(r.label, 'main_text');
      expect([r.x, r.y, r.w, r.h], [80, 60, 500, 900]);
      // 行/段原样保留：只改框模式不做任何重建。
      expect(ann.lines.map((l) => l.id).toList(), [
        'l_in_normal',
        'l_in_manual',
        'l_out_normal',
        'l_out_manual',
      ]);
      expect(ann.paragraphs, hasLength(1));
    });

    test('无主区时新建 proposed 主区', () {
      final ann = _ann()..mainRegions.clear();
      BookRegionApply.applyRegionOnly(
        ann,
        const Rect.fromLTWH(0, 0, 100, 100),
      );
      final r = ann.mainRegions.single;
      expect(r.id, 'mr_001');
      expect(r.status, AnnotationStatus.proposed);
      expect(r.uid, isEmpty);
    });

    test('只替换正文主区：页眉/页脚等其它版面区原样保留', () {
      final ann = _ann();
      ann.mainRegions.addAll([
        MainRegion(
          id: 'mr_header',
          x: 100,
          y: 0,
          w: 400,
          h: 60,
          label: RegionLabel.header,
        ),
        MainRegion(
          id: 'mr_footer',
          x: 100,
          y: 950,
          w: 400,
          h: 50,
          label: RegionLabel.footer,
        ),
      ]);
      BookRegionApply.applyRegionOnly(
        ann,
        const Rect.fromLTWH(80, 60, 500, 900),
      );
      // 主区替换为一条（身份保留），页眉/页脚不动。
      expect(ann.mainRegions, hasLength(3));
      expect(ann.mainRegions.first.id, 'mr_001');
      expect(ann.mainRegions.first.rect, const Rect.fromLTWH(80, 60, 500, 900));
      expect(
        ann.mainRegions.map((r) => r.id),
        containsAll(['mr_header', 'mr_footer']),
      );
      expect(ann.mainRegions.first.uid, 'uid_r1');
    });

    test('无正文主区但有页眉时：新建主区插到最前，页眉保留', () {
      final ann = _ann()
        ..mainRegions.clear()
        ..mainRegions.add(
          MainRegion(id: 'mr_h', x: 0, y: 0, w: 99, h: 99, label: 'header'),
        );
      BookRegionApply.applyRegionOnly(ann, const Rect.fromLTWH(0, 0, 10, 10));
      expect(ann.mainRegions, hasLength(2));
      expect(ann.mainRegions.first.label, RegionLabel.mainText);
      expect(ann.mainRegions.last.id, 'mr_h');
    });
  });

  group('replaceLabeledRegions / removeLabeledRegions（快设每类多条）', () {
    test('整组替换同类框：逐条保身份、多余删除、无框新建 proposed', () {
      final ann = _ann();
      ann.mainRegions.addAll([
        MainRegion(
          id: 'mr_h1',
          x: 100,
          y: 0,
          w: 400,
          h: 60,
          label: RegionLabel.header,
          uid: 'uid_h1',
          status: AnnotationStatus.confirmed,
        ),
        MainRegion(id: 'mr_h2', x: 0, y: 0, w: 50, h: 20, label: 'header'),
      ]);
      final changed = BookRegionApply.replaceLabeledRegions(
        ann,
        RegionLabel.header,
        [const Rect.fromLTWH(90, 5, 420, 55)],
      );
      expect(changed, isTrue);
      final headers = ann.mainRegions
          .where((r) => RegionLabel.normalize(r.label) == RegionLabel.header)
          .toList();
      expect(headers, hasLength(1)); // 多余同类框删除
      expect(headers.single.id, 'mr_h1'); // 身份保留
      expect(headers.single.uid, 'uid_h1');
      expect(headers.single.status, AnnotationStatus.confirmed);
      expect(headers.single.rect, const Rect.fromLTWH(90, 5, 420, 55));
      // 正文主区不受影响。
      expect(
        ann.mainRegions
            .where((r) => r.id == 'mr_001')
            .single
            .rect,
        const Rect.fromLTWH(100, 100, 400, 800),
      );
    });

    test('无同类框时新建 proposed，几何相同再存不报变化', () {
      final ann = _ann();
      var changed = BookRegionApply.replaceLabeledRegions(
        ann,
        RegionLabel.pageNumber,
        [const Rect.fromLTWH(600, 1030, 40, 40)],
      );
      expect(changed, isTrue);
      final pn = ann.mainRegions
          .where((r) => r.label == RegionLabel.pageNumber)
          .single;
      expect(pn.status, AnnotationStatus.proposed);
      expect(pn.uid, isEmpty);
      changed = BookRegionApply.replaceLabeledRegions(
        ann,
        RegionLabel.pageNumber,
        [pn.rect],
      );
      expect(changed, isFalse); // 未改动
    });

    test('左右双页脚各框一条：两条都保留、新增第三条插在该类末尾', () {
      final ann = _ann();
      ann.mainRegions.addAll([
        MainRegion(
          id: 'mr_f1',
          x: 0,
          y: 990,
          w: 90,
          h: 30,
          label: 'footer',
          uid: 'uid_f1',
        ),
        MainRegion(id: 'mr_h', x: 0, y: 0, w: 400, h: 40, label: 'header'),
        MainRegion(id: 'mr_f2', x: 500, y: 990, w: 90, h: 30, label: 'footer'),
      ]);
      final changed = BookRegionApply.replaceLabeledRegions(ann, 'footer', [
        const Rect.fromLTWH(0, 992, 90, 30), // 左页脚（微调 2px）
        const Rect.fromLTWH(500, 990, 90, 30), // 右页脚（原样）
        const Rect.fromLTWH(250, 995, 60, 25), // 中缝多出一条
      ]);
      expect(changed, isTrue);
      final footers = ann.mainRegions
          .where((r) => r.label == 'footer')
          .toList();
      expect(footers, hasLength(3));
      // 前两条按位保留身份（含确认状态/uid），第三条新建 proposed。
      expect(footers[0].id, 'mr_f1');
      expect(footers[0].uid, 'uid_f1');
      expect(footers[0].rect, const Rect.fromLTWH(0, 992, 90, 30));
      expect(footers[1].id, 'mr_f2');
      expect(footers[2].status, AnnotationStatus.proposed);
      expect(footers[2].rect, const Rect.fromLTWH(250, 995, 60, 25));
      // 新框插在该类最后一条存活框之后、页眉之前（同类相邻成组）。
      expect(ann.mainRegions.indexOf(footers[2]),
          ann.mainRegions.indexOf(footers[1]) + 1);
      expect(
        ann.mainRegions.any((r) => r.id == 'mr_h' && r.label == 'header'),
        isTrue,
      );
      // 幂等：同组再存不报变化。
      expect(
        BookRegionApply.replaceLabeledRegions(
          ann,
          'footer',
          [for (final f in footers) f.rect],
        ),
        isFalse,
      );
    });

    test('空列表删除该类全部框', () {
      final ann = _ann();
      ann.mainRegions.addAll([
        MainRegion(id: 'mr_f1', x: 0, y: 990, w: 90, h: 30, label: 'footer'),
        MainRegion(id: 'mr_f2', x: 0, y: 1020, w: 90, h: 30, label: 'footer'),
      ]);
      final changed = BookRegionApply.replaceLabeledRegions(
        ann,
        RegionLabel.footer,
        const [],
      );
      expect(changed, isTrue);
      expect(
        ann.mainRegions.where((r) => r.label == RegionLabel.footer),
        isEmpty,
      );
      expect(ann.mainRegions, hasLength(1)); // 主区保留
      expect(
        BookRegionApply.replaceLabeledRegions(ann, RegionLabel.footer, const []),
        isFalse,
      );
    });

    test('removeLabeledRegions 删除该类全部框', () {
      final ann = _ann();
      ann.mainRegions.addAll([
        MainRegion(id: 'mr_f1', x: 0, y: 990, w: 90, h: 30, label: 'footer'),
        MainRegion(id: 'mr_f2', x: 0, y: 1020, w: 90, h: 30, label: 'footer'),
      ]);
      final changed = BookRegionApply.removeLabeledRegions(
        ann,
        RegionLabel.footer,
      );
      expect(changed, isTrue);
      expect(
        ann.mainRegions.where((r) => r.label == RegionLabel.footer),
        isEmpty,
      );
      expect(ann.mainRegions, hasLength(1)); // 主区保留
      expect(
        BookRegionApply.removeLabeledRegions(ann, RegionLabel.footer),
        isFalse,
      );
    });
  });

  group('applyRegionsOnly（多主区整组替换：未裁开双页）', () {
    test('两条主区各自保身份替换、补第三条 proposed、多余删除', () {
      final ann = _ann();
      ann.mainRegions.addAll([
        MainRegion(
          id: 'mr_002',
          x: 600,
          y: 100,
          w: 300,
          h: 800,
          uid: 'uid_r2',
          status: AnnotationStatus.confirmed,
          boxConfirmed: true,
        ),
        MainRegion(id: 'mr_h', x: 0, y: 0, w: 400, h: 40, label: 'header'),
      ]);
      final changed = BookRegionApply.applyRegionsOnly(ann, [
        const Rect.fromLTWH(80, 60, 400, 900),
        const Rect.fromLTWH(560, 60, 320, 900),
        const Rect.fromLTWH(920, 60, 100, 900),
      ]);
      expect(changed, isTrue);
      final mains = ann.mainRegions
          .where((r) => RegionLabel.normalize(r.label) == RegionLabel.mainText)
          .toList();
      expect(mains, hasLength(3));
      expect(mains[0].id, 'mr_001');
      expect(mains[0].uid, 'uid_r1');
      expect(mains[0].boxConfirmed, isTrue);
      expect(mains[0].rect, const Rect.fromLTWH(80, 60, 400, 900));
      expect(mains[1].id, 'mr_002');
      expect(mains[1].rect, const Rect.fromLTWH(560, 60, 320, 900));
      expect(mains[2].status, AnnotationStatus.proposed);
      expect(mains[2].boxConfirmed, isFalse);
      // 页眉原样保留；幂等再存不报变化。
      expect(
        ann.mainRegions.any((r) => r.id == 'mr_h' && r.label == 'header'),
        isTrue,
      );
      expect(
        BookRegionApply.applyRegionsOnly(ann, [
          for (final m in mains) m.rect,
        ]),
        isFalse,
      );
      // 收敛回一条：多余主区删除、身份保留。
      expect(
        BookRegionApply.applyRegionsOnly(ann, [
          const Rect.fromLTWH(80, 60, 400, 900),
        ]),
        isTrue,
      );
      expect(
        ann.mainRegions.where((r) => r.label == RegionLabel.mainText),
        hasLength(1),
      );
      expect(
        ann.mainRegions
            .where((r) => r.label == RegionLabel.mainText)
            .single
            .id,
        'mr_001',
      );
    });

    test('无主区时整组插到最前，首条用历史缺省 id', () {
      final ann = _ann()..mainRegions.clear();
      ann.mainRegions.add(
        MainRegion(id: 'mr_h', x: 0, y: 0, w: 99, h: 20, label: 'header'),
      );
      final changed = BookRegionApply.applyRegionsOnly(ann, [
        const Rect.fromLTWH(0, 0, 10, 10),
        const Rect.fromLTWH(20, 0, 10, 10),
      ]);
      expect(changed, isTrue);
      final mains = ann.mainRegions
          .where((r) => r.label == RegionLabel.mainText)
          .toList();
      expect(mains, hasLength(2));
      expect(mains[0].id, 'mr_001');
      expect(ann.mainRegions.indexOf(mains[0]), 0);
      expect(ann.mainRegions.indexOf(mains[1]), 1);
      expect(ann.mainRegions.last.id, 'mr_h');
    });

    test('多主区几何变化触发页面级降级，各主区确认身份按位继承', () {
      final ann = _ann()
        ..reviewed = true
        ..mainRegions.add(
          MainRegion(
            id: 'mr_002',
            x: 600,
            y: 100,
            w: 300,
            h: 800,
            boxConfirmed: false,
          ),
        );
      BookRegionApply.applyRegionsOnly(ann, [
        ann.mainRegions[0].rect, // 第一条原样
        const Rect.fromLTWH(560, 60, 320, 900), // 第二条变化
      ]);
      expect(ann.reviewed, isFalse);
      final mains = ann.mainRegions
          .where((r) => r.label == RegionLabel.mainText)
          .toList();
      // 第一条确认身份继承；第二条本来就没确认过，保持 false。
      expect(mains[0].boxConfirmed, isTrue);
      expect(mains[1].boxConfirmed, isFalse);
      // 多主区全部原样（幂等）不降级。
      ann.reviewed = true;
      BookRegionApply.applyRegionsOnly(ann, [
        for (final m in mains) m.rect,
      ]);
      expect(ann.reviewed, isTrue);
    });
  });

  group('spliceRegionLines', () {
    test('区内普通行替换、手工行保留、区外残留删除、区外手工行保留、'
        '新行与保留行去重', () {
      final ann = _ann();
      final rect = ann.mainRegions.single.rect;
      // 后端返回两条：一条中心与手工保留行重叠（应被去重丢弃），
      // 一条全新位置（应 reid 后插入）。
      final fromBackend = [
        _line('yolo_l_000', 200, 120, chars: [
          CharBlock(id: 'p_b0001', x: 205, y: 130, w: 30, h: 30, col: 0, order: 0),
        ]),
        _line('yolo_l_001', 300, 300, chars: [
          CharBlock(id: 'p_b0002', x: 305, y: 310, w: 30, h: 30, col: 0, order: 0),
        ]),
      ];
      final stats = BookRegionApply.spliceRegionLines(
        ann,
        newLines: fromBackend,
        rect: rect,
        pruneOutsideRegions: true,
      );

      // 分类：区内普通行 + 区外普通行被删；两条手工行保留。
      expect(stats.removedIds, containsAll(['l_in_normal', 'l_out_normal']));
      expect(stats.removedIds, hasLength(2));
      expect(stats.pinnedCount, 2);
      // 区外计数含被手工保护的行（沿用编辑器原语义：区外遇到的行都
      // 计数，其中手工行保留但仍计入）。
      expect(stats.removedOutside, 2);

      final ids = ann.lines.map((l) => l.id).toList();
      expect(ids, containsAll(['l_in_manual', 'l_out_manual']));
      // 与保留行重叠的后端行被丢弃，只插入全新的一条。
      expect(stats.newLines, hasLength(1));
      expect(ids, contains(stats.newLines.single.id));
      expect(ids, isNot(contains('yolo_l_000')));

      // 新行 reid：后端 id 不残留，行内字 id/lineId 同步改写。
      final inserted = stats.newLines.single;
      expect(inserted.id, isNot('yolo_l_001'));
      expect(inserted.chars.single.id, isNot('p_b0002'));
      expect(inserted.chars.single.lineId, inserted.id);

      // 行号重排 = 列表下标。
      for (var i = 0; i < ann.lines.length; i++) {
        expect(ann.lines[i].lineNo, i);
      }
      // 被删行从段落成员中清理，无孤立 lineIds。
      final p = ann.paragraphs.single;
      expect(p.lineIds, everyElement(isNot(contains('l_in_normal'))));
      expect(p.lineIds.where((id) => id == 'l_in_normal'), isEmpty);
    });

    test('pruneOutsideRegions=false 时区外行不动', () {
      final ann = _ann();
      final stats = BookRegionApply.spliceRegionLines(
        ann,
        newLines: const [],
        rect: ann.mainRegions.single.rect,
      );
      expect(stats.removedIds, ['l_in_normal']);
      expect(stats.removedOutside, 0);
      expect(ann.lines.map((l) => l.id), containsAll(['l_out_normal']));
    });

    test('字框全部 boxConfirmed 的行同样视为用户成果保留', () {
      final ann = _ann();
      final confirmed = _line('l_box_confirmed', 350, 120, chars: [
        CharBlock(
          id: 'c_confirmed',
          x: 355,
          y: 130,
          w: 30,
          h: 30,
          col: 0,
          order: 0,
          boxConfirmed: true,
        ),
      ]);
      ann.lines.add(confirmed);
      final stats = BookRegionApply.spliceRegionLines(
        ann,
        newLines: const [],
        rect: ann.mainRegions.single.rect,
        pruneOutsideRegions: true,
      );
      expect(stats.removedIds, isNot(contains('l_box_confirmed')));
      expect(ann.lines.map((l) => l.id), contains('l_box_confirmed'));
    });

    test('多主区逐块级联：跨区域边界行不被后一个区域重复插入（+130）', () {
      // 未裁开双页：左区 mr_L(0..400)、右区 mr_R(400..800)。后端区域过滤
      // 按"行中心或任一字中心在区内"整行保留——中心在左区、框跨过中缝
      // (370..410) 的边界行会被右区批次再次带回。
      final ann = PageAnnotation(
        pageId: 'p',
        imagePath: 'p.png',
        mainRegions: [
          MainRegion(id: 'mr_L', x: 0, y: 0, w: 400, h: 800),
          MainRegion(id: 'mr_R', x: 400, y: 0, w: 400, h: 800),
        ],
      );
      final leftRect = ann.mainRegions[0].rect;
      final rightRect = ann.mainRegions[1].rect;

      // 左区批次：区内一条 + 跨中缝边界行一条。
      BookRegionApply.spliceRegionLines(
        ann,
        newLines: [_line('a1', 50, 100), _line('a2', 370, 100)],
        rect: leftRect,
        pruneOutsideRegions: true,
      );
      expect(ann.lines, hasLength(2));

      // 右区批次：右区自己的行 + 同位置的边界行 a2 再带回一次。
      final stats = BookRegionApply.spliceRegionLines(
        ann,
        newLines: [_line('b1', 500, 100), _line('a2_dup', 370, 100)],
        rect: rightRect,
        pruneOutsideRegions: true,
      );
      // 右区自己的行正常插入；边界行与已保留行同位置，去重不插第二条。
      expect(stats.newLines, hasLength(1));
      expect(ann.lines, hasLength(3));
      // 边界行只剩一份（中心在左区 390 的那份）。
      final boundary = ann.lines
          .where((l) => l.x == 370 && l.y == 100)
          .toList();
      expect(boundary, hasLength(1));
      // 已保留的左区行 a1 不受右区批次影响。
      expect(ann.lines.any((l) => l.x == 50), isTrue);
    });
  });

  group('applyRegionOnly 页面级确认状态降级（主区调整后只确认主区）', () {
    test('确认并保存（reviewed）的页主区变化 → 降级为只确认主区', () {
      final ann = _ann()..reviewed = true;
      ann.lines.first.status = AnnotationStatus.confirmed;
      BookRegionApply.applyRegionOnly(
        ann,
        const Rect.fromLTWH(80, 60, 500, 900),
      );
      expect(ann.reviewed, isFalse);
      expect(ann.boxesReviewed, isFalse);
      // 主区确认身份保留：网格仍显示"已确认"角标、仍满足拆分目标口径。
      final body = ann.mainRegions.single;
      expect(body.boxConfirmed, isTrue);
      expect(body.status, AnnotationStatus.proposed);
      // 行的确认状态一并回退——旧主区上的成果不再作数。
      expect(ann.lines.first.status, AnnotationStatus.proposed);
    });

    test('框已确认（boxesReviewed）的页主区变化 → 同样降级', () {
      final ann = _ann()..boxesReviewed = true;
      BookRegionApply.applyRegionOnly(
        ann,
        const Rect.fromLTWH(80, 60, 500, 900),
      );
      expect(ann.boxesReviewed, isFalse);
      expect(ann.reviewed, isFalse);
      expect(ann.mainRegions.single.boxConfirmed, isTrue);
    });

    test('几何未变（幂等保存）不降级', () {
      final ann = _ann()..reviewed = true;
      BookRegionApply.applyRegionOnly(ann, ann.mainRegions.single.rect);
      expect(ann.reviewed, isTrue, reason: '主区没动不丢页面确认状态');
    });

    test('未确认页改主区不走降级路径（status 原样保留）', () {
      final ann = _ann();
      BookRegionApply.applyRegionOnly(
        ann,
        const Rect.fromLTWH(0, 0, 10, 10),
      );
      expect(ann.mainRegions.single.status, AnnotationStatus.confirmed);
    });
  });

  group('clearMainRegionConfirmed（统一设置后退回未确认）', () {
    test('只清正文主区的确认，页眉等其它类别保留，返回清掉条数', () {
      final ann = PageAnnotation(
        pageId: 'p1',
        imagePath: 'p1.png',
        mainRegions: [
          MainRegion(
            id: 'mr_1',
            x: 10,
            y: 10,
            w: 300,
            h: 400,
            label: RegionLabel.mainText,
            boxConfirmed: true,
          ),
          MainRegion(
            id: 'mr_2',
            x: 10,
            y: 500,
            w: 300,
            h: 50,
            label: RegionLabel.header,
            boxConfirmed: true,
          ),
          MainRegion(
            id: 'mr_3',
            x: 10,
            y: 560,
            w: 300,
            h: 400,
            // 词表外 label 归一为正文——确认也要清。
            label: 'legacy_main',
            boxConfirmed: true,
          ),
        ],
      );
      expect(BookRegionApply.clearMainRegionConfirmed(ann), 2);
      expect(ann.mainRegions[0].boxConfirmed, isFalse);
      expect(ann.mainRegions[1].boxConfirmed, isTrue, reason: '页眉没动，确认保留');
      expect(ann.mainRegions[2].boxConfirmed, isFalse);
    });

    test('幂等：已全部未确认时再清返回 0；无主区页返回 0', () {
      final ann = _ann();
      expect(BookRegionApply.clearMainRegionConfirmed(ann), 1);
      expect(BookRegionApply.clearMainRegionConfirmed(ann), 0);
      expect(
        BookRegionApply.clearMainRegionConfirmed(
          PageAnnotation(pageId: 'p2', imagePath: 'p2.png'),
        ),
        0,
      );
    });

    test('统一设置链路：applyRegionsOnly 保留的确认随后被清干净', () {
      final ann = _ann()..reviewed = true;
      // 统一设置写主区：页面状态降级后主区按位继承确认身份，再经
      // clearMainRegionConfirmed 全部退回未确认（不自动确认）。
      BookRegionApply.applyRegionOnly(
        ann,
        const Rect.fromLTWH(80, 60, 500, 900),
      );
      expect(ann.mainRegions.single.boxConfirmed, isTrue);
      expect(BookRegionApply.clearMainRegionConfirmed(ann), 1);
      expect(ann.mainRegions.single.boxConfirmed, isFalse);
    });
  });
}
