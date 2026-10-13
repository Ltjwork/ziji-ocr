// 整行三步辅助引擎的守门员测试：修复触发判定、尾段矩形、写回门禁
// （advisory 候选/标记不受文本门槛限制）、溯源记录的持久化往返。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/services/ai_line_repair.dart';
import 'package:gujichazi/services/ai_trace.dart';
import 'package:gujichazi/services/ollama_service.dart';

CharBlock _c(
  int x,
  int y,
  int w,
  int h, {
  String text = '',
  double? conf,
  int order = 0,
  String? agree,
}) => CharBlock(
  id: 'c$order',
  x: x,
  y: y,
  w: w,
  h: h,
  col: 0,
  order: order,
  text: text,
  conf: conf,
  agree: agree,
);

LineBlock _line(
  int x,
  int y,
  int w,
  int h,
  List<CharBlock> chars, {
  String orientation = 'vertical',
  String id = 'l1',
}) {
  final l = LineBlock(
    id: id,
    x: x,
    y: y,
    w: w,
    h: h,
    lineNo: 1,
    orientation: orientation,
  );
  l.chars = chars;
  l.text = chars.map((c) => c.text).join();
  return l;
}

void main() {
  group('repairTriggerOf 修复触发判定', () {
    test('显式裁切标记优先，返回首个标记的 order', () {
      final chars = [_c(0, 0, 40, 50, order: 0), _c(0, 50, 40, 50, order: 1)];
      final t = repairTriggerOf(
        chars,
        AiLineDecision(
          lineText: '天地',
          confidence: 0.9,
          items: [
            AiLineItem(order: 0, text: '天', confidence: 0.9),
            AiLineItem(
              order: 1,
              text: '地',
              confidence: 0.9,
              cropIssue: 'char_clipped',
              cropNote: '下半切掉',
            ),
          ],
        ),
      );
      expect(t, isNotNull);
      expect(t!.start, 1);
      expect(t.type, 'char_clipped');
      expect(t.note, '下半切掉');
    });

    test('AI 读出字数多于框数且 eligible → 分歧位置前一框', () {
      // 框：天地黃（3 框）；AI 读出：天地玄黃（4 字）→ 分歧于第 2 字。
      final chars = [
        _c(0, 0, 40, 50, text: '天', order: 0),
        _c(0, 50, 40, 50, text: '地', order: 1),
        _c(0, 100, 40, 50, text: '黃', order: 2),
      ];
      final t = repairTriggerOf(
        chars,
        AiLineDecision(lineText: '天地玄黃', confidence: 0.9, items: const []),
      );
      expect(t, isNotNull);
      expect(t!.start, 1); // 分歧于第 2 字 → 从第 1 框（index 1）起重摆
      expect(t.type, 'count_mismatch');
    });

    test('字数多于框数但低于置信度门槛 → 不触发', () {
      final chars = [_c(0, 0, 40, 50, order: 0)];
      expect(
        repairTriggerOf(
          chars,
          AiLineDecision(lineText: '天地', confidence: 0.5, items: const []),
        ),
        isNull,
      );
    });

    test('无标记且字数一致 → 不触发', () {
      final chars = [_c(0, 0, 40, 50, text: '天', order: 0)];
      expect(
        repairTriggerOf(
          chars,
          AiLineDecision(
            lineText: '天',
            confidence: 0.95,
            items: const [AiLineItem(order: 0, text: '天', confidence: 0.95)],
          ),
        ),
        isNull,
      );
    });
  });

  group('tailRectOf 尾段矩形', () {
    test('竖排行 k>0：从 k-1 框顶边到行底', () {
      final chars = [
        _c(0, 0, 40, 50, order: 0),
        _c(0, 50, 40, 50, order: 1),
        _c(0, 100, 40, 60, order: 2),
      ];
      final line = _line(0, 0, 40, 170, chars);
      final r = tailRectOf(line, chars, 2);
      expect(r.x, 0);
      expect(r.y, 50);
      expect(r.w, 40);
      expect(r.h, 170 - 50);
    });

    test('竖排行 k=0：整行矩形', () {
      final chars = [_c(0, 0, 40, 50, order: 0)];
      final line = _line(0, 0, 40, 100, chars);
      final r = tailRectOf(line, chars, 0);
      expect(r.y, 0);
      expect(r.h, 100);
    });

    test('横排行 k>0：从 k-1 框左边到行右', () {
      final chars = [
        _c(0, 0, 50, 40, order: 0),
        _c(50, 0, 50, 40, order: 1),
      ];
      final line = _line(0, 0, 170, 40, chars, orientation: 'horizontal');
      final r = tailRectOf(line, chars, 1);
      expect(r.x, 0);
      expect(r.w, 170);
      expect(r.y, 0);
      expect(r.h, 40);
    });

    test('横排 rtl：行末尾在左边，尾段 = 行左边缘 → anchor 右边缘', () {
      // 从右到左阅读：order 0 在最右，order 2 在最左。
      final chars = [
        _c(100, 0, 50, 40, order: 0),
        _c(50, 0, 50, 40, order: 1),
        _c(0, 0, 50, 40, order: 2),
      ];
      final line = _line(0, 0, 150, 40, chars, orientation: 'horizontal');
      // 问题框 order 2 → anchor = order 1 的框（x=50..100）。
      final r = tailRectOf(line, chars, 2, horizontalDir: 'rtl');
      expect(r.x, 0);
      expect(r.w, 100); // 行左边缘 0 → anchor 右边缘 100。
      expect(r.y, 0);
      expect(r.h, 40);
    });

    test('竖排 btt：行末尾在上边，尾段 = 行上边缘 → anchor 底边缘', () {
      // 从下到上阅读：order 0 在最下，order 1 在最上。
      final chars = [
        _c(0, 100, 40, 50, order: 0),
        _c(0, 50, 40, 50, order: 1),
      ];
      final line = _line(0, 0, 40, 150, chars);
      // 问题框 order 1 → anchor = order 0 的框（y=100..150）。
      final r = tailRectOf(line, chars, 1, verticalDir: 'btt');
      expect(r.y, 0);
      expect(r.h, 150); // 行上边缘 0 → anchor 底边缘 150。
      expect(r.x, 0);
      expect(r.w, 40);
    });
  });

  group('applyDecisionToLine 写回门禁', () {
    test('全部通过：文字写回 + AI 候选并入 + 原文保底 + 切分标记', () {
      final chars = [
        _c(0, 0, 40, 50, text: '天', conf: 0.4, order: 0),
        _c(0, 50, 40, 50, text: '夫', conf: 0.3, order: 1),
      ];
      final line = _line(0, 0, 40, 100, chars);
      final r = applyDecisionToLine(
        line,
        chars,
        AiLineDecision(
          lineText: '天地',
          confidence: 0.92,
          items: [
            AiLineItem(
              order: 0,
              text: '天',
              confidence: 0.95,
              candidates: const [OllamaSuggestion(text: '天', score: 0.95)],
            ),
            AiLineItem(
              order: 1,
              text: '地',
              confidence: 0.9,
              candidates: const [
                OllamaSuggestion(text: '地', score: 0.9),
                OllamaSuggestion(text: '墬', score: 0.3),
              ],
              cropIssue: 'char_clipped',
              cropNote: '下半贴边',
            ),
          ],
        ),
      );
      expect(r.textApplied, isTrue);
      expect(r.path, 'items');
      expect(chars[0].text, '天'); // 原字一致
      expect(chars[1].text, '地'); // AI 改字
      expect(chars[1].aiUsed, isTrue);
      expect(chars[1].source, 'kraken+ai-line');
      // AI 候选带 ai 标记并入，原 OCR 文本保底。
      expect(
        chars[1].candidates.map((c) => '${c.text}${c.ai ? '*' : ''}').toList(),
        containsAll(['地*', '墬*', '夫']),
      );
      // 切分标记写入。
      expect(chars[1].aiBoxIssue, 'char_clipped');
      expect(chars[1].aiBoxNote, '下半贴边');
      expect(chars[0].aiBoxIssue, isNull);
      expect(line.text, '天地');
      expect(
        r.checks.firstWhere((c) => c.name.contains('整行置信度')).pass,
        isTrue,
      );
    });

    test('低于 0.80：不写文字，但候选与切分标记照写（advisory）', () {
      final chars = [
        _c(0, 0, 40, 50, text: '天', order: 0),
        _c(0, 50, 40, 50, text: '夫', order: 1),
      ];
      final line = _line(0, 0, 40, 100, chars);
      final r = applyDecisionToLine(
        line,
        chars,
        AiLineDecision(
          lineText: '天地',
          confidence: 0.6,
          items: [
            const AiLineItem(order: 0, text: '天', confidence: 0.9),
            AiLineItem(
              order: 1,
              text: '地',
              confidence: 0.9,
              cropIssue: 'char_merged',
            ),
          ],
        ),
      );
      expect(r.textApplied, isFalse);
      expect(chars[1].text, '夫'); // 文字保留 OCR
      expect(chars[1].aiUsed, isFalse);
      expect(chars[1].aiBoxIssue, 'char_merged'); // 标记照写
      expect(line.text, '天夫');
      expect(r.writes.length, 2); // 两条 advisory 写入
    });

    test('items 不完整但 line_text 一一对应 → rune 回退', () {
      final chars = [
        _c(0, 0, 40, 50, text: '天', order: 0),
        _c(0, 50, 40, 50, text: '夫', order: 1),
      ];
      final line = _line(0, 0, 40, 100, chars);
      final r = applyDecisionToLine(
        line,
        chars,
        AiLineDecision(lineText: '天地', confidence: 0.88, items: const []),
      );
      expect(r.textApplied, isTrue);
      expect(r.path, 'runes');
      expect(chars[1].text, '地');
      expect(line.text, '天地');
    });

    test('line_text 含非法字符 → 不写回', () {
      final chars = [_c(0, 0, 40, 50, text: '天', order: 0)];
      final line = _line(0, 0, 40, 50, chars);
      final r = applyDecisionToLine(
        line,
        chars,
        AiLineDecision(lineText: 'AB', confidence: 0.95, items: const []),
      );
      expect(r.textApplied, isFalse);
      expect(chars[0].text, '天');
    });

    test('回归：候选列表不可变（旧对象 const []）也能并入候选不崩溃', () {
      final char = CharBlock.fromJson({
            'id': 'c0',
            'x': 0,
            'y': 0,
            'w': 40,
            'h': 50,
            'col': 0,
            'order': 0,
            'text': '夫',
          })
          // 模拟任何来源的不可变候选列表（旧版本反序列化的 const []）。
          ..candidates = const [];
      final line = _line(0, 0, 40, 50, [char]);
      final r = applyDecisionToLine(
        line,
        [char],
        AiLineDecision(
          lineText: '天',
          confidence: 0.92,
          items: [
            AiLineItem(
              order: 0,
              text: '天',
              confidence: 0.95,
              candidates: const [
                OllamaSuggestion(text: '天', score: 0.95),
                OllamaSuggestion(text: '矢', score: 0.3),
              ],
            ),
          ],
        ),
      );
      expect(r.textApplied, isTrue);
      expect(char.text, '天');
      expect(
        char.candidates.map((c) => c.text).toList(),
        containsAll(['天', '矢', '夫']),
      );
    });
  });

  group('tailMateriallySame / flattenSegmentedChars', () {
    test('同框同字视为实质相同（2px 容差）', () {
      final old = [
        _c(0, 50, 40, 50, text: '地', order: 1),
        _c(0, 100, 40, 50, text: '玄', order: 2),
      ];
      final same = [
        _c(0, 51, 40, 50, text: '地', order: 0),
        _c(1, 100, 40, 50, text: '玄', order: 1),
      ];
      expect(tailMateriallySame(old, 1, same), isTrue);
      final diff = [
        _c(0, 50, 40, 50, text: '地', order: 0),
        _c(0, 100, 40, 50, text: '黃', order: 1),
      ];
      expect(tailMateriallySame(old, 1, diff), isFalse);
    });

    test('多行返回按行序摊平', () {
      final a = _line(0, 0, 40, 50, [
        _c(0, 0, 40, 50, text: '甲', order: 0),
      ], id: 'a');
      final b = _line(0, 50, 40, 50, [
        _c(0, 50, 40, 50, text: '乙', order: 0),
      ], id: 'b');
      final flat = flattenSegmentedChars([a, b]);
      expect(flat.map((c) => c.text).toList(), ['甲', '乙']);
    });
  });

  group('AiTraceRecorder 持久化往返', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('ai_trace_test');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    AiTraceEntry entryOf(String lineId, {String? error}) => AiTraceEntry(
      lineId: lineId,
      stage: AiTraceStage.assist,
      at: DateTime(2026, 1, 1, 10),
      model: 'm',
      provider: 'local',
      images: const [AiTraceImage(file: 'img_000.png', label: '整行图')],
      prompt: 'p',
      thinking: 't',
      rawContent: 'r',
      decisionJson: '{"line_text":"天地"}',
      checks: const [AiTraceCheck(name: '整行置信度 ≥ 0.80', pass: true)],
      outcome: '已采纳',
      outcomePass: true,
      writes: const [AiTraceCharWrite(order: 0, oldText: '天', newText: '天')],
      error: error,
      repair: null,
    );

    test('flush 覆盖写 + load 往返（每页只留最后一次）', () async {
      final rec = AiTraceRecorder(
        projectDir: tmp.path,
        pageId: 'p1',
        imagePath: 'x.png',
        model: 'glm',
        provider: 'external',
      );
      rec.add(entryOf('l1'));
      await rec.flush();
      // 第二次运行覆盖第一次。
      final rec2 = AiTraceRecorder(
        projectDir: tmp.path,
        pageId: 'p1',
        imagePath: 'x.png',
        model: 'qwen',
        provider: 'local',
      );
      rec2.add(entryOf('l2', error: '失败'));
      rec2.add(
        AiTraceEntry(
          lineId: 'l2',
          stage: AiTraceStage.repair,
          at: DateTime(2026, 1, 1, 11),
          model: 'qwen',
          provider: 'local',
          outcome: '已采纳',
          outcomePass: true,
          repair: const AiTraceRepair(
            trigger: '2 号字框 char_clipped：贴边',
            issueType: 'char_clipped',
            startOrder: 2,
            tailRect: {'x': 0, 'y': 50, 'w': 40, 'h': 120},
            oldTailCount: 3,
            newChars: [
              {'x': 0, 'y': 50, 'w': 40, 'h': 50, 'text': '地'},
            ],
            beforeScore: 0.5,
            afterScore: 0.7,
            adopted: true,
            reason: '质量分提升',
          ),
        ),
      );
      await rec2.flush();
      final loaded = await AiTraceRecorder.load(tmp.path, 'p1');
      expect(loaded, isNotNull);
      expect(loaded!.model, 'qwen');
      expect(loaded.entries.length, 2);
      expect(loaded.entries.first.error, '失败');
      final repair = loaded.entries[1].repair!;
      expect(repair.adopted, isTrue);
      expect(repair.tailRect['y'], 50);
      expect(repair.newChars.first['text'], '地');
    });

    test('continueRun 续写不清旧条目，图片序号接续', () async {
      final rec = AiTraceRecorder(
        projectDir: tmp.path,
        pageId: 'p1',
        imagePath: 'x.png',
        model: 'glm',
        provider: 'local',
      );
      rec.add(entryOf('l1'));
      await rec.flush();
      final cont = await AiTraceRecorder.continueRun(
        tmp.path,
        'p1',
        model: 'glm',
        provider: 'local',
      );
      expect(cont, isNotNull);
      expect(cont!.run.entries.length, 1);
      expect(cont.imageSeqForTest, 1); // img_000 已被引用 → 下一张 img_001
      cont.add(
        AiTraceEntry(
          lineId: 'l1',
          stage: AiTraceStage.repair,
          at: DateTime.now(),
          model: 'glm',
          provider: 'local',
          outcome: 'ok',
          outcomePass: true,
        ),
      );
      await cont.flush();
      final loaded = await AiTraceRecorder.load(tmp.path, 'p1');
      expect(loaded!.entries.length, 2);
    });

    test('内存模式：图片留内存、flush 不落盘', () async {
      final rec = AiTraceRecorder.memory(model: 'm', provider: 'local');
      final f = await rec.saveImage('aGVsbG8=', '整行图');
      expect(f, isNotNull);
      expect(rec.imageBytesOf(f!), isNotNull);
      await rec.flush();
      expect(File('${tmp.path}/ai_trace').existsSync(), isFalse);
    });
  });
}
