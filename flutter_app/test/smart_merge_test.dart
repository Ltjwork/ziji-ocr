import 'package:flutter_test/flutter_test.dart';

import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/services/smart_merge.dart';

PageAnnotation _ann({List<LineBlock> lines = const [], List<CharBlock> blocks = const []}) =>
    PageAnnotation(
      pageId: 'p1',
      imagePath: 'p1.png',
      lines: lines,
      blocks: blocks,
    );

LineBlock _line(
  String id,
  List<CharBlock> chars, {
  String orientation = 'vertical',
}) =>
    LineBlock(
      id: id,
      x: 0,
      y: 0,
      w: 100,
      h: 100,
      lineNo: 0,
      orientation: orientation,
      chars: chars,
    );

CharBlock _box(
  String id,
  int x,
  int y,
  int w,
  int h, {
  String text = '',
  bool confirmed = false,
  bool boxConfirmed = false,
  String status = AnnotationStatus.proposed,
  String? aiBoxIssue,
}) => CharBlock(
  id: id,
  x: x,
  y: y,
  w: w,
  h: h,
  col: 0,
  order: 0,
  text: text,
  confirmed: confirmed,
  boxConfirmed: boxConfirmed,
  status: status,
  aiBoxIssue: aiBoxIssue,
);

final _settings = ProjectSettings();

void main() {
  group('smartMergeLineDir 行内阅读方向', () {
    test('竖排默认 ttb，按页覆盖 btt 生效；横排看 horizontalDir', () {
      final v = _line('l', [], orientation: 'vertical');
      final h = _line('l', [], orientation: 'horizontal');
      expect(smartMergeLineDir(v, _settings), 'ttb');
      expect(
        smartMergeLineDir(
          v,
          ProjectSettings(verticalDir: 'btt'),
        ),
        'btt',
      );
      expect(smartMergeLineDir(h, _settings), 'ltr');
      expect(
        smartMergeLineDir(h, ProjectSettings(horizontalDir: 'rtl')),
        'rtl',
      );
    });
  });

  group('buildSmartMergeScanPage 载荷构建', () {
    test('行按阅读序给块，含已确认标记；不足两字的行跳过；空页返回 null', () {
      final a = _box('a', 0, 0, 20, 30, text: 'A');
      final b = _box('b', 0, 34, 20, 30, text: 'B');
      final c = _box('c', 0, 200, 20, 30, confirmed: true);
      final d = _box('d', 0, 234, 20, 30);
      final ann = _ann(
        lines: [
          _line('l1', [a, b]),
          _line('l2', [c, d]),
          _line('l3', [_box('e', 0, 400, 20, 30)]), // 单字行不参与
        ],
        blocks: [a, b, c, d],
      );
      final page = buildSmartMergeScanPage(
        pageId: 'p1',
        imagePath: 'p1.png',
        ann: ann,
        settings: _settings,
      )!;
      expect(page.lines, hasLength(2));
      expect(page.lines[0].dir, 'ttb');
      expect(page.lines[0].blocks.map((e) => e.id), ['a', 'b']);
      expect(page.lines[1].blocks[0].confirmed, true);
      expect(page.toMap()['lines'], isA<List<dynamic>>());

      final empty = buildSmartMergeScanPage(
        pageId: 'p1',
        imagePath: 'p1.png',
        ann: _ann(lines: [_line('l3', [_box('e', 0, 400, 20, 30)])]),
        settings: _settings,
      );
      expect(empty, isNull);
    });
  });

  group('applySmartMergeMatches 应用合并', () {
    test('竖排行合并：并集矩形、拼接文字、行 manual、块表替换、行文本重建', () {
      final a = _box('a', 10, 0, 20, 30, text: '木', aiBoxIssue: 'char_merged');
      final b = _box('b', 12, 30, 16, 30, text: '子');
      final line = _line('l1', [a, b]);
      final ann = _ann(lines: [line], blocks: [a, b]);
      final results = applySmartMergeMatches(ann, [
        const SmartMergeScanMatch(
          pageId: 'p1',
          firstId: 'a',
          secondId: 'b',
          score: 0.1,
        ),
      ], settings: _settings);
      expect(results, hasLength(1));
      final (merged, host) = results.single;
      expect(merged.id, 'a'); // 阅读序在前的框 id 保留
      expect(merged.x, 10);
      expect(merged.y, 0);
      expect(merged.w, 20);
      expect(merged.h, 60);
      expect(merged.text, '木子');
      expect(merged.aiBoxIssue, isNull); // AI 切分标记清除
      expect(host.manual, true); // 级联重识别保护
      expect(host.chars, hasLength(1));
      expect(host.text, '木子'); // 行文本重建
      expect(host.chars.first.order, 0);
      expect(ann.blocks, hasLength(1));
      expect(ann.blocks.single.id, 'a');
    });

    test('已确认（confirmed / box_confirmed / status）的框恒不合并', () {
      for (final protected in [
        (true, false, AnnotationStatus.proposed),
        (false, true, AnnotationStatus.proposed),
        (false, false, AnnotationStatus.confirmed),
      ]) {
        final a = _box(
          'a',
          10,
          0,
          20,
          30,
          confirmed: protected.$1,
          boxConfirmed: protected.$2,
          status: protected.$3,
        );
        final b = _box('b', 10, 30, 20, 30);
        final ann = _ann(
          lines: [_line('l1', [a, b])],
          blocks: [a, b],
        );
        final results = applySmartMergeMatches(ann, [
          const SmartMergeScanMatch(
            pageId: 'p1',
            firstId: 'a',
            secondId: 'b',
            score: 0.05,
          ),
        ], settings: _settings);
        expect(results, isEmpty, reason: '$protected 应被保护跳过');
        expect(ann.blocks, hasLength(2));
      }
    });

    test('两框不在同一行 / id 不存在：跳过不改', () {
      final a = _box('a', 10, 0, 20, 30);
      final b = _box('b', 10, 300, 20, 30); // 另一行
      final ann = _ann(
        lines: [_line('l1', [a]), _line('l2', [b])],
        blocks: [a, b],
      );
      final results = applySmartMergeMatches(ann, [
        const SmartMergeScanMatch(
          pageId: 'p1',
          firstId: 'a',
          secondId: 'b',
          score: 0.05,
        ),
        const SmartMergeScanMatch(
          pageId: 'p1',
          firstId: 'a',
          secondId: 'ghost',
          score: 0.05,
        ),
      ], settings: _settings);
      expect(results, isEmpty);
      expect(ann.blocks, hasLength(2));
    });

    test('链式重叠匹配：一个框只被消费一次（b 已用时 (b,c) 跳过）', () {
      final a = _box('a', 0, 0, 20, 30, text: '一');
      final b = _box('b', 0, 30, 20, 30, text: '二');
      final c = _box('c', 0, 60, 20, 30, text: '三');
      final line = _line('l1', [a, b, c]);
      final ann = _ann(lines: [line], blocks: [a, b, c]);
      final results = applySmartMergeMatches(ann, [
        const SmartMergeScanMatch(
          pageId: 'p1',
          firstId: 'b',
          secondId: 'c',
          score: 0.2, // 分数更差，后应用
        ),
        const SmartMergeScanMatch(
          pageId: 'p1',
          firstId: 'a',
          secondId: 'b',
          score: 0.1, // 分数更好，先应用（消费 b）
        ),
      ], settings: _settings);
      expect(results, hasLength(1));
      expect(results.single.$1.text, '一二');
      expect(line.chars.map((e) => e.id), ['a', 'c']);
      expect(ann.blocks, hasLength(2));
    });

    test('横排 rtl：文字按右→左阅读轴拼接', () {
      final left = _box('a', 100, 0, 20, 30, text: '前');
      final right = _box('b', 130, 0, 20, 30, text: '后');
      final line = _line('l1', [right, left], orientation: 'horizontal');
      final ann = _ann(lines: [line], blocks: [right, left]);
      final results = applySmartMergeMatches(ann, [
        const SmartMergeScanMatch(
          pageId: 'p1',
          firstId: 'a',
          secondId: 'b',
          score: 0.1,
        ),
      ], settings: ProjectSettings(horizontalDir: 'rtl'));
      // rtl：右框（b，中心 140）在前 → 「后」+「前」
      expect(results.single.$1.text, '后前');
    });
  });

  group('applySmartSplits 应用分割', () {
    test('竖排行按比例一分为二：原框改前半、新框紧随其后、行重建', () {
      final a = _box('a', 10, 0, 20, 60, text: '舊', aiBoxIssue: 'char_merged');
      final c = _box('c', 10, 60, 20, 30, text: '下');
      final line = _line('l1', [a, c]);
      final ann = _ann(lines: [line], blocks: [a, c]);
      final results = applySmartSplits(ann, [
        const SmartSplitScanMatch(pageId: 'p1', blockId: 'a', score: 0.1),
      ], ratio: 0.5, settings: _settings);
      expect(results, hasLength(1));
      final (first, second, host) = results.single;
      expect(first.id, 'a'); // 原框就地改前半
      expect((first.x, first.y, first.w, first.h), (10, 0, 20, 30));
      expect(first.aiBoxIssue, isNull);
      expect((second.x, second.y, second.w, second.h), (10, 30, 20, 30));
      expect(second.lineId, 'l1');
      expect(second.text, ''); // 新框文字待刷新
      expect(host.manual, true); // 几何手工变化 → 行保护
      expect(host.chars.map((e) => e.id), ['a', second.id, 'c']);
      expect(host.chars.map((e) => e.order), [0, 1, 2]);
      expect(host.text, '舊下'); // 前半保留原文字 + 后半空 + 后续字
      expect(ann.blocks, hasLength(3));
      expect(ann.blocks.any((b) => b.id == second.id), isTrue);
    });

    test('横排行：沿 X 轴分割（ltr）', () {
      final a = _box('a', 0, 10, 60, 20, text: 'AB');
      final line = _line('l1', [a], orientation: 'horizontal');
      final ann = _ann(lines: [line], blocks: [a]);
      final results = applySmartSplits(ann, [
        const SmartSplitScanMatch(pageId: 'p1', blockId: 'a', score: 0.05),
      ], ratio: 0.5, settings: _settings);
      final (first, second, _) = results.single;
      expect((first.w, second.x), (30, 30));
      expect((first.h, second.h), (20, 20)); // 高度不变
    });

    test('已确认框与幽灵 id 跳过；太薄的框切不开跳过', () {
      final confirmed = _box('a', 10, 0, 20, 60, confirmed: true);
      final thin = _box('t', 50, 0, 20, 8); // 轴向 8px < 2×5px 最小框
      final line = _line('l1', [confirmed, thin]);
      final ann = _ann(lines: [line], blocks: [confirmed, thin]);
      final results = applySmartSplits(ann, [
        const SmartSplitScanMatch(pageId: 'p1', blockId: 'a', score: 0.05),
        const SmartSplitScanMatch(pageId: 'p1', blockId: 't', score: 0.05),
        const SmartSplitScanMatch(pageId: 'p1', blockId: 'ghost', score: 0.05),
      ], ratio: 0.5, settings: _settings);
      expect(results, isEmpty);
      expect(ann.blocks, hasLength(2));
      expect(line.chars, hasLength(2));
    });

    test('极端比例被钳进两侧各留 5px 的有效区', () {
      final a = _box('a', 10, 0, 20, 60);
      final line = _line('l1', [a]);
      final ann = _ann(lines: [line], blocks: [a]);
      final results = applySmartSplits(ann, [
        const SmartSplitScanMatch(pageId: 'p1', blockId: 'a', score: 0.05),
      ], ratio: 0.0, settings: _settings);
      final (first, second, _) = results.single;
      expect(first.h, 5); // 钳到 top+5
      expect(second.h, 55); // 两段之和恒等于原长
    });
  });
}
