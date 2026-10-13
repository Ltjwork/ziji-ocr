// AI 框检查核心逻辑的守门员测试：可疑扫描规则与保护行跳过、行质量分、
// 重摆结果合理性、裁决 adopt/rollback 边界、视觉模型诊断解析。
import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/services/ai_box_review.dart';
import 'package:gujichazi/services/ollama_service.dart';
import 'package:gujichazi/services/python_service.dart';

CharBlock _c(
  int x,
  int y,
  int w,
  int h, {
  String text = '字',
  double? conf,
  String? agree,
  String? verifyLevel,
  bool confirmed = false,
  bool boxConfirmed = false,
  int order = 0,
}) => CharBlock(
  id: 'c$x-$y-$order',
  x: x,
  y: y,
  w: w,
  h: h,
  col: 0,
  order: order,
  text: text,
  conf: conf,
  agree: agree,
  verifyLevel: verifyLevel,
  confirmed: confirmed,
  boxConfirmed: boxConfirmed,
);

LineBlock _line(
  int x,
  int y,
  int w,
  int h,
  List<CharBlock> chars, {
  String id = 'l',
  bool manual = false,
  int lineNo = 0,
}) => LineBlock(
  id: id,
  x: x,
  y: y,
  w: w,
  h: h,
  lineNo: lineNo,
  chars: chars,
  manual: manual,
);

PageAnnotation _ann(List<LineBlock> lines) =>
    PageAnnotation(pageId: 'p1', imagePath: 'p1.png', lines: lines);

void main() {
  // 竖排行 x=0..40，8 个字沿 y 轴各占 50px，中位字高 50。
  List<CharBlock> normalChars({double conf = 0.9}) => [
    for (var i = 0; i < 8; i++)
      _c(0, i * 50, 40, 50, conf: conf, agree: 'both', order: i),
  ];

  group('scanSuspects 可疑扫描', () {
    test('正常行（高置信度、两路一致、几何正常、不重叠）不报可疑', () {
      final suspects = scanSuspects(
        _ann([_line(0, 0, 40, 400, normalChars())]),
      );
      expect(suspects, isEmpty);
    });

    test('行框重叠 → A 档，伴生行取非保护行', () {
      final a = _line(0, 0, 40, 400, normalChars(), id: 'a');
      final b = _line(0, 380, 40, 400, normalChars(), id: 'b'); // 与 a 重叠 20px
      final suspects = scanSuspects(_ann([a, b]));
      expect(suspects.length, 2); // 双方都报
      final sa = suspects.firstWhere((s) => s.line.id == 'a');
      expect(sa.tier, BoxSuspectTier.geometry);
      expect(sa.reasons.first, contains('重叠'));
      expect(sa.overlapPartner?.id, 'b');
      expect(sa.duplicatePartner, isNull); // 字数同但重叠率低（800/16000），不算重复
    });

    test('同列重复（高重叠+同字数）→ 检出 duplicatePartner 走删除动作', () {
      final a = _line(0, 0, 40, 400, normalChars(conf: 0.4), id: 'a');
      final b = _line(2, 0, 40, 400, normalChars(conf: 0.9), id: 'b');
      // 交/较小面 = 38x400/40x400 = 0.95，字数同为 8 → 重复。
      final suspects = scanSuspects(_ann([a, b]));
      final sa = suspects.firstWhere((s) => s.line.id == 'a');
      expect(sa.reasons.first, contains('重复'));
      expect(sa.duplicatePartner?.id, 'b');
      expect(sa.overlapPartner, isNull);
    });

    test('重叠伴生是保护行时不取并集（不洗掉用户成果）', () {
      final a = _line(0, 0, 40, 400, normalChars(), id: 'a');
      final b = _line(0, 380, 40, 400, normalChars(), id: 'b', manual: true);
      final suspects = scanSuspects(_ann([a, b]));
      final sa = suspects.firstWhere((s) => s.line.id == 'a');
      expect(sa.reasons.first, contains('重叠'));
      expect(sa.overlapPartner, isNull);
      // 保护行自身不进可疑列表。
      expect(suspects.any((s) => s.line.id == 'b'), isFalse);
    });

    test('异常高字框 → A 档并推算期望字数', () {
      final chars = normalChars();
      chars[3] = _c(0, 150, 40, 120, conf: 0.9, agree: 'both', order: 3);
      final suspects = scanSuspects(_ann([_line(0, 0, 40, 470, chars)]));
      expect(suspects.single.tier, BoxSuspectTier.geometry);
      expect(suspects.single.reasons.first, contains('异常高字框'));
      // 8 个常规字 + 1 个高框（约藏 2 字）→ 期望字数 9。
      expect(suspects.single.geometryExpectedCount, 9);
    });

    test('低置信度 → B 档语义', () {
      final chars = normalChars();
      chars[2] = _c(0, 100, 40, 50, conf: 0.3, agree: 'both', order: 2);
      final suspects = scanSuspects(_ann([_line(0, 0, 40, 400, chars)]));
      expect(suspects.single.tier, BoxSuspectTier.semantic);
      expect(suspects.single.reasons.first, contains('低置信度'));
    });

    test('两路分歧占比超 30% → B 档', () {
      final chars = [
        for (var i = 0; i < 8; i++)
          _c(
            0,
            i * 50,
            40,
            50,
            conf: 0.9,
            agree: i < 3 ? 'conflict' : 'both',
            order: i,
          ),
      ];
      final suspects = scanSuspects(_ann([_line(0, 0, 40, 400, chars)]));
      expect(suspects.single.tier, BoxSuspectTier.semantic);
      expect(suspects.single.reasons.first, contains('分歧'));
    });

    test('墨迹校验 mismatch → B 档', () {
      final chars = normalChars();
      chars[5] = _c(
        0,
        250,
        40,
        50,
        conf: 0.9,
        agree: 'both',
        verifyLevel: 'mismatch',
        order: 5,
      );
      final suspects = scanSuspects(_ann([_line(0, 0, 40, 400, chars)]));
      expect(suspects.single.tier, BoxSuspectTier.semantic);
      expect(suspects.single.reasons.first, contains('墨迹校验'));
    });

    test('保护行（manual/全部框确认/含确认字）一律跳过', () {
      final manualLine = _line(0, 0, 40, 400, normalChars(), manual: true);
      final boxConfirmed = [
        for (var i = 0; i < 8; i++)
          _c(
            0,
            i * 50,
            40,
            50,
            conf: 0.9,
            agree: 'both',
            boxConfirmed: true,
            order: i,
          ),
      ];
      final pinned = _line(40, 0, 40, 400, boxConfirmed);
      final hasConfirmedChar = normalChars();
      hasConfirmedChar[0] = _c(
        0,
        0,
        40,
        50,
        conf: 0.1,
        agree: 'conflict',
        confirmed: true,
        order: 0,
      );
      final semi = _line(80, 0, 40, 400, hasConfirmedChar);
      final suspects = scanSuspects(_ann([manualLine, pinned, semi]));
      expect(suspects, isEmpty);
    });

    test('无字的行跳过', () {
      final suspects = scanSuspects(_ann([_line(0, 0, 40, 400, [])]));
      expect(suspects, isEmpty);
    });

    test('窄行（厚度 < 0.65×页面中位）→ B 档，交 AI 确认是否拆列', () {
      // 4 条正常厚度 100 的行 + 1 条厚度 50 的窄行（互不重叠、字框正常）。
      final lines = <LineBlock>[
        for (var i = 0; i < 4; i++)
          _line(i * 150, 0, 100, 400, [
            for (var j = 0; j < 8; j++)
              _c(i * 150, j * 50, 100, 50, conf: 0.9, agree: 'both', order: j),
          ], id: 'n$i'),
        _line(600, 0, 50, 400, [
          for (var j = 0; j < 8; j++)
            _c(600, j * 50, 50, 50, conf: 0.9, agree: 'both', order: j),
        ], id: 'narrow'),
      ];
      final suspects = scanSuspects(_ann(lines));
      expect(suspects.length, 1);
      expect(suspects.single.line.id, 'narrow');
      expect(suspects.single.tier, BoxSuspectTier.semantic);
      expect(suspects.single.reasons.first, contains('异常窄'));
    });

    test('页面行数太少（<4）不做窄行判定，防中位数不稳误报', () {
      final lines = <LineBlock>[
        _line(0, 0, 120, 400, normalChars(), id: 'a'),
        _line(200, 0, 40, 400, normalChars(), id: 'b'),
        _line(300, 0, 120, 400, normalChars(), id: 'c'),
      ];
      expect(scanSuspects(_ann(lines)), isEmpty);
    });
  });

  group('scanSuspects 墨迹判空（/line_ink）', () {
    const blankInk = LineInkResult(
      charInkMedian: 0.012,
      blankChars: 8,
      charCount: 8,
    );
    const realInk = LineInkResult(
      charInkMedian: 0.31,
      blankChars: 0,
      charCount: 8,
    );

    test('空框（有字块但墨迹中位≈0）→ blankInk 可疑（删除动作）', () {
      // 幽灵窄条与真列重叠 5px——正是用户实测"空白列误检 + 与邻行叠压"。
      final ghost = _line(36, 0, 20, 400, normalChars(), id: 'ghost');
      final real = _line(0, 0, 40, 400, normalChars(), id: 'real');
      final suspects = scanSuspects(
        _ann([real, ghost]),
        inkByLineId: const {'ghost': blankInk, 'real': realInk},
      );
      final sg = suspects.firstWhere((s) => s.line.id == 'ghost');
      expect(sg.blankInk, isTrue);
      expect(sg.tier, BoxSuspectTier.geometry);
      expect(sg.reasons.single, contains('空框'));
      expect(sg.overlapPartner, isNull);
      // 幽灵行不作为真行的重叠伴生（删除它即消除重叠，真行无需重摆）。
      expect(suspects.any((s) => s.line.id == 'real'), isFalse);
    });

    test('无字块的行：墨迹判空 → 报空框；无墨迹数据 → 仍跳过', () {
      final empty = _line(36, 0, 20, 400, const [], id: 'empty');
      final real = _line(0, 0, 40, 400, normalChars(), id: 'real');
      final withInk = scanSuspects(
        _ann([real, empty]),
        inkByLineId: const {'empty': blankInk, 'real': realInk},
      );
      expect(withInk.single.line.id, 'empty');
      expect(withInk.single.blankInk, isTrue);
      expect(withInk.single.reasons.single, contains('无字块'));

      // 无墨迹数据的空行不报（可能是尚待识别的手工行——manual 已被
      // 保护判定拦下，其余不冒险删）。
      expect(
        scanSuspects(_ann([real, empty])).any((s) => s.line.id == 'empty'),
        isFalse,
      );
    });

    test('墨迹正常的行不受判空影响；manual 空框行受保护不删', () {
      final real = _line(0, 0, 40, 400, normalChars(), id: 'real');
      final manualGhost = _line(
        60,
        0,
        20,
        400,
        normalChars(),
        id: 'mg',
        manual: true,
      );
      final suspects = scanSuspects(
        _ann([real, manualGhost]),
        inkByLineId: const {'real': realInk, 'mg': blankInk},
      );
      expect(suspects, isEmpty);
    });

    test('过半字框无墨迹 → 几何可疑，期望字数与内容下限按非空字数下推', () {
      final chars = normalChars();
      final suspects = scanSuspects(
        _ann([_line(0, 0, 40, 400, chars)]),
        inkByLineId: const {
          'l': LineInkResult(charInkMedian: 0.3, blankChars: 5, charCount: 8),
        },
      );
      final s = suspects.single;
      expect(s.tier, BoxSuspectTier.geometry);
      expect(s.reasons.first, contains('5/8'));
      expect(s.geometryExpectedCount, 3); // 8 - 5 个空白
      expect(s.contentFloor, 2); // max(1, 3×0.7)
      expect(s.blankInk, isFalse);
    });

    test('空白字占比未过半 → 不报（零星空白框属正常）', () {
      final suspects = scanSuspects(
        _ann([_line(0, 0, 40, 400, normalChars())]),
        inkByLineId: const {
          'l': LineInkResult(charInkMedian: 0.3, blankChars: 3, charCount: 8),
        },
      );
      expect(suspects, isEmpty);
    });

    test('墨迹测量缺失（null）→ 退回纯几何/语义规则，不误报空框', () {
      final suspects = scanSuspects(
        _ann([_line(0, 0, 40, 400, normalChars(), id: 'a')]),
        inkByLineId: const {
          'a': LineInkResult(charInkMedian: 0, blankChars: 0, charCount: 0),
        },
      );
      // charCount=0 的退化测量（行框整体测量的异常形态）不触发过半规则。
      expect(suspects, isEmpty);
    });
  });

  group('lineScore 行质量分', () {
    test('高置信度+两路一致 > 低置信度+分歧', () {
      final good = normalChars();
      final bad = [
        for (var i = 0; i < 8; i++)
          _c(
            0,
            i * 50,
            40,
            50,
            conf: 0.3,
            agree: i < 4 ? 'conflict' : 'both',
            order: i,
          ),
      ];
      expect(
        lineScore(good, 'vertical'),
        greaterThan(lineScore(bad, 'vertical')),
      );
    });

    test('无 conf 数据按 0.5 中性计（不崩、不偏激）', () {
      final noConf = [
        for (var i = 0; i < 4; i++) _c(0, i * 50, 40, 50, order: i),
      ];
      final score = lineScore(noConf, 'vertical');
      expect(score, inInclusiveRange(0.3, 0.7));
    });
  });

  group('sanityOk 重摆结果合理性', () {
    test('正常单行通过', () {
      final ok = _line(0, 0, 40, 400, normalChars());
      expect(sanityOk([ok]), isTrue);
    });

    test('相邻行框有安全交集也通过（不为零重叠裁窄字形）', () {
      final a = _line(0, 0, 40, 400, normalChars());
      final b = _line(0, 380, 40, 400, normalChars());
      expect(sanityOk([a, b]), isTrue);
    });

    test('无字的行不通过', () {
      expect(sanityOk([_line(0, 0, 40, 400, [])]), isFalse);
    });

    test('字数超物理上限不通过', () {
      // 行长 100px 塞 40 个字（每个至少 6px）。
      final chars = [
        for (var i = 0; i < 40; i++) _c(0, i * 2, 40, 2, order: i),
      ];
      expect(sanityOk([_line(0, 0, 40, 100, chars)]), isFalse);
    });
  });

  group('shouldAdopt 裁决', () {
    test('分数提升 + 合理 + 分歧不劣化 → 采纳', () {
      final old = [
        for (var i = 0; i < 8; i++)
          _c(0, i * 50, 40, 50, conf: 0.4, agree: 'conflict', order: i),
      ];
      final fixed = normalChars(conf: 0.95);
      expect(shouldAdopt(old, fixed, 'vertical'), isTrue);
    });

    test('分数未过门槛（margin 0.03）→ 不采纳', () {
      final old = normalChars(conf: 0.9);
      final slightly = normalChars(conf: 0.92); // 提升不足 0.03
      expect(shouldAdopt(old, slightly, 'vertical'), isFalse);
    });

    test('分数提升但两路分歧恶化 → 仍采纳（分歧惩罚已计入分数）', () {
      final old = normalChars(conf: 0.5); // agree 全 both
      final worse = [
        for (var i = 0; i < 8; i++)
          _c(
            0,
            i * 50,
            40,
            50,
            conf: 0.95,
            agree: i < 6 ? 'conflict' : 'both',
            order: i,
          ),
      ];
      // 分歧率惩罚后仍大幅净提升 → 采纳（诚实重读常带更多 conflict
      // 标记，单设硬闸会把整体更好的结果也拒掉——实测教训）。
      expect(shouldAdopt(old, worse, 'vertical'), isTrue);
    });

    test('内容守恒闸：1 个字吞掉 20 字的行 → 不采纳', () async {
      final old = [
        for (var i = 0; i < 20; i++)
          _c(0, i * 40, 40, 40, conf: 0.6, agree: 'both', order: i),
      ];
      final degenerate = [_c(0, 0, 40, 800, conf: 0.99, agree: 'both')];
      expect(shouldAdopt(old, degenerate, 'vertical'), isFalse);
    });

    test('内容守恒闸：过度粉碎（8 字行拆出 25 字）→ 不采纳', () {
      final old = normalChars(conf: 0.6);
      final shredded = [
        for (var i = 0; i < 25; i++)
          _c(0, i * 16, 40, 16, conf: 0.99, agree: 'both', order: i),
      ];
      expect(shouldAdopt(old, shredded, 'vertical'), isFalse);
    });

    test('A 档容差：质量分持平的几何修复可采纳，B 档门槛下不采纳', () {
      final old = normalChars(conf: 0.8); // score ≈ 0.9
      final same = [
        for (var i = 0; i < 9; i++)
          _c(0, i * 45, 40, 45, conf: 0.78, agree: 'both', order: i),
      ]; // score ≈ 0.88
      expect(
        shouldAdopt(old, same, 'vertical', margin: kGeometryMargin),
        isTrue,
      );
      expect(shouldAdopt(old, same, 'vertical'), isFalse);
    });

    test('退化结果（字数失配）→ 不采纳', () {
      final old = normalChars(conf: 0.5);
      final degenerate = [
        for (var i = 0; i < 50; i++) _c(0, i * 2, 40, 2, conf: 0.99, order: i),
      ];
      expect(shouldAdopt(old, degenerate, 'vertical'), isFalse);
    });

    test('minNewCount 下推：诚实删空白框的修复不再被默认闸拒掉', () {
      final old = [
        for (var i = 0; i < 8; i++)
          _c(0, i * 50, 40, 50, conf: 0.35, agree: 'none', order: i),
      ];
      final honest = [
        for (var i = 0; i < 3; i++)
          _c(0, i * 50, 40, 50, conf: 0.95, agree: 'both', order: i),
      ];
      // 默认闸（旧 8 字的一半 = 4）拒掉 3 字结果。
      expect(
        shouldAdopt(old, honest, 'vertical', margin: kGeometryMargin),
        isFalse,
      );
      // 字框空白行下推内容下限后可采纳。
      expect(
        shouldAdopt(
          old,
          honest,
          'vertical',
          margin: kGeometryMargin,
          minNewCount: 2,
        ),
        isTrue,
      );
    });
  });

  group('AiBoxReviewer.reviewLine 单行闭环', () {
    test('A 档：重摆过裁决 → fixed，期望字数透传', () async {
      int? gotExpected;
      final oldChars = [
        for (var i = 0; i < 8; i++)
          _c(0, i * 50, 40, 50, conf: 0.4, agree: 'conflict', order: i),
      ];
      final suspect = BoxSuspect(
        line: _line(0, 0, 40, 400, oldChars),
        tier: BoxSuspectTier.geometry,
        reasons: const ['字数与行长不符'],
        geometryExpectedCount: 9,
      );
      final reviewer = AiBoxReviewer(
        fetchThumbnails: (items) async => [],
        resegment: (stub, {expectedCharCount}) async {
          gotExpected = expectedCharCount;
          return [
            _line(0, 0, 40, 450, [
              for (var i = 0; i < 9; i++)
                _c(0, i * 50, 40, 50, conf: 0.95, agree: 'both', order: i),
            ]),
          ];
        },
      );
      final r = await reviewer.reviewLine(suspect, imagePath: 'p.png');
      expect(gotExpected, 9);
      expect(r.status, BoxReviewStatus.fixed);
      expect(r.afterScore, greaterThan(r.beforeScore));
    });

    test('A 档：重摆未过裁决 → kept（不应用即回滚）', () async {
      final oldChars = normalChars(conf: 0.9);
      final suspect = BoxSuspect(
        line: _line(0, 0, 40, 400, oldChars),
        tier: BoxSuspectTier.geometry,
        reasons: const ['与相邻行框重叠'],
      );
      final reviewer = AiBoxReviewer(
        fetchThumbnails: (items) async => [],
        resegment: (stub, {expectedCharCount}) async => [
          // 重摆结果反而低分。
          _line(0, 0, 40, 400, [
            for (var i = 0; i < 8; i++)
              _c(0, i * 50, 40, 50, conf: 0.3, agree: 'conflict', order: i),
          ]),
        ],
      );
      final r = await reviewer.reviewLine(suspect, imagePath: 'p.png');
      expect(r.status, BoxReviewStatus.kept);
      expect(r.newLines, isEmpty);
    });

    test('空框（blankInk）→ 直接删除，不调后端不调视觉模型', () async {
      var resegmentCalls = 0;
      var diagnoseCalls = 0;
      final reviewer = AiBoxReviewer(
        fetchThumbnails: (items) async => ['<png>'],
        resegment: (stub, {expectedCharCount}) async {
          resegmentCalls++;
          return [];
        },
        diagnose: (img, line) async {
          diagnoseCalls++;
          return const OllamaBoxDiagnosis(lineOk: true, issues: []);
        },
      );
      final suspect = BoxSuspect(
        line: _line(36, 0, 20, 400, normalChars(conf: 0.95)),
        tier: BoxSuspectTier.semantic, // 即使误入语义档也优先走删除
        reasons: const ['空框（8 个字框内均无墨迹）'],
        blankInk: true,
      );
      final r = await reviewer.reviewLine(suspect, imagePath: 'p.png');
      expect(r.status, BoxReviewStatus.fixed);
      expect(r.newLines, isEmpty); // 空列表 = 编辑器只删不插
      expect(r.reason, contains('删除'));
      expect(resegmentCalls, 0);
      expect(diagnoseCalls, 0);
    });

    test('过半字框空白：内容下限下推后，删掉空白框的诚实修复可采纳', () async {
      // 旧行 8 字（5 个空白框 + 3 个低分），重摆诚实地只回 3 个高分字。
      final oldChars = [
        for (var i = 0; i < 8; i++)
          _c(0, i * 50, 40, 50, conf: 0.35, agree: 'none', order: i),
      ];
      final suspect = BoxSuspect(
        line: _line(0, 0, 40, 400, oldChars),
        tier: BoxSuspectTier.geometry,
        reasons: const ['5/8 个字框内无墨迹'],
        geometryExpectedCount: 3,
        contentFloor: 2,
      );
      final reviewer = AiBoxReviewer(
        fetchThumbnails: (items) async => [],
        resegment: (stub, {expectedCharCount}) async => [
          _line(0, 0, 40, 160, [
            for (var i = 0; i < 3; i++)
              _c(0, i * 50, 40, 50, conf: 0.95, agree: 'both', order: i),
          ]),
        ],
      );
      final r = await reviewer.reviewLine(suspect, imagePath: 'p.png');
      expect(r.status, BoxReviewStatus.fixed);
      // 默认内容闸（旧字数一半 = 4）会拒掉这个诚实修复。
    });

    test('B 档：VLM 判无问题 → vlmOk，不触发重摆', () async {
      var resegmentCalls = 0;
      final reviewer = AiBoxReviewer(
        fetchThumbnails: (items) async => ['<png>'],
        resegment: (stub, {expectedCharCount}) async {
          resegmentCalls++;
          return [];
        },
        diagnose: (img, line) async =>
            const OllamaBoxDiagnosis(lineOk: true, issues: []),
      );
      final suspect = BoxSuspect(
        line: _line(0, 0, 40, 400, normalChars(conf: 0.3)),
        tier: BoxSuspectTier.semantic,
        reasons: const ['1 个低置信度字'],
      );
      final r = await reviewer.reviewLine(suspect, imagePath: 'p.png');
      expect(r.status, BoxReviewStatus.vlmOk);
      expect(resegmentCalls, 0);
    });

    test('B 档：VLM 报两字同框 → 期望字数 = 现字数 + 1', () async {
      int? gotExpected;
      final reviewer = AiBoxReviewer(
        fetchThumbnails: (items) async => ['<png>'],
        resegment: (stub, {expectedCharCount}) async {
          gotExpected = expectedCharCount;
          return [
            _line(0, 0, 40, 400, [
              for (var i = 0; i < 9; i++)
                _c(0, i * 45, 40, 45, conf: 0.95, agree: 'both', order: i),
            ]),
          ];
        },
        diagnose: (img, line) async => const OllamaBoxDiagnosis(
          lineOk: false,
          issues: [
            OllamaBoxIssue(
              type: OllamaBoxIssueType.charMerged,
              pos: 3,
              note: '两字粘连',
            ),
          ],
        ),
      );
      final suspect = BoxSuspect(
        line: _line(0, 0, 40, 400, [
          for (var i = 0; i < 8; i++)
            _c(0, i * 50, 40, 50, conf: 0.4, agree: 'conflict', order: i),
        ]),
        tier: BoxSuspectTier.semantic,
        reasons: const ['低置信度'],
      );
      final r = await reviewer.reviewLine(suspect, imagePath: 'p.png');
      expect(gotExpected, 9);
      expect(r.status, BoxReviewStatus.fixed);
    });

    test('B 档：Ollama 不可用 → failed 且说明原因', () async {
      final reviewer = AiBoxReviewer(
        fetchThumbnails: (items) async => ['<png>'],
        resegment: (stub, {expectedCharCount}) async => [],
        diagnose: null,
      );
      final suspect = BoxSuspect(
        line: _line(0, 0, 40, 400, normalChars(conf: 0.3)),
        tier: BoxSuspectTier.semantic,
        reasons: const ['低置信度'],
      );
      final r = await reviewer.reviewLine(suspect, imagePath: 'p.png');
      expect(r.status, BoxReviewStatus.failed);
      expect(r.reason, contains('Ollama'));
    });

    test('A 档重复行：删除较差的一条，不调后端', () async {
      var resegmentCalls = 0;
      final reviewer = AiBoxReviewer(
        fetchThumbnails: (items) async => [],
        resegment: (stub, {expectedCharCount}) async {
          resegmentCalls++;
          return [];
        },
      );
      final bad = _line(0, 0, 40, 400, [
        for (var i = 0; i < 8; i++)
          _c(0, i * 50, 40, 50, conf: 0.4, agree: 'conflict', order: i),
      ], id: 'bad');
      final good = _line(2, 0, 40, 400, normalChars(conf: 0.95), id: 'good');
      final r = await reviewer.reviewLine(
        BoxSuspect(
          line: bad,
          tier: BoxSuspectTier.geometry,
          reasons: const ['与相邻行重复（同列重复检测）'],
          duplicatePartner: good,
        ),
        imagePath: 'p.png',
      );
      expect(resegmentCalls, 0);
      expect(r.status, BoxReviewStatus.fixed);
      expect(r.newLines.single.id, 'good'); // 保留质量好的一条
    });

    test('A 档原样复检：后端返回相同几何/字数/文本 → 保持原样，不算修复', () async {
      final oldLine = _line(0, 0, 40, 400, [
        for (var i = 0; i < 8; i++)
          _c(0, i * 50, 40, 50, text: '之', conf: 0.6, agree: 'both', order: i),
      ]);
      final reviewer = AiBoxReviewer(
        fetchThumbnails: (items) async => [],
        resegment: (stub, {expectedCharCount}) async => [
          _line(0, 0, 40, 400, [
            for (var i = 0; i < 8; i++)
              _c(
                0,
                i * 50,
                40,
                50,
                text: '之',
                conf: 0.6,
                agree: 'both',
                order: i,
              ),
          ]),
        ],
      );
      final r = await reviewer.reviewLine(
        BoxSuspect(
          line: oldLine,
          tier: BoxSuspectTier.geometry,
          reasons: const ['与相邻行框重叠'],
        ),
        imagePath: 'p.png',
      );
      expect(r.status, BoxReviewStatus.kept);
      expect(r.reason, contains('相同'));
      expect(r.newLines, isEmpty);
    });

    test('A 档重叠：重跑矩形取两行并集', () async {
      LineBlock? gotStub;
      final a = _line(0, 0, 40, 400, [
        for (var i = 0; i < 8; i++)
          _c(0, i * 50, 40, 50, conf: 0.4, agree: 'conflict', order: i),
      ], id: 'a');
      final b = _line(0, 380, 40, 400, normalChars(), id: 'b');
      final reviewer = AiBoxReviewer(
        fetchThumbnails: (items) async => [],
        resegment: (stub, {expectedCharCount}) async {
          gotStub = stub;
          return [
            _line(0, 0, 40, 780, [
              for (var i = 0; i < 16; i++)
                _c(0, i * 48, 40, 48, conf: 0.95, agree: 'both', order: i),
            ]),
          ];
        },
      );
      final suspect = BoxSuspect(
        line: a,
        tier: BoxSuspectTier.geometry,
        reasons: const ['与相邻行框重叠'],
        overlapPartner: b,
      );
      final r = await reviewer.reviewLine(suspect, imagePath: 'p.png');
      expect(gotStub, isNotNull);
      expect(gotStub!.y, 0);
      expect(gotStub!.h, 780); // 0..780 = 两行并集
      expect(r.status, BoxReviewStatus.fixed);
    });
  });

  group('保护与辅助', () {
    test('isProtectedLine 三种形态', () {
      expect(isProtectedLine(_line(0, 0, 40, 100, [], manual: true)), isTrue);
      expect(
        isProtectedLine(
          _line(0, 0, 40, 100, [_c(0, 0, 40, 50, boxConfirmed: true)]),
        ),
        isTrue,
      );
      expect(
        isProtectedLine(
          _line(0, 0, 40, 100, [_c(0, 0, 40, 50, confirmed: true)]),
        ),
        isTrue,
      );
      expect(
        isProtectedLine(_line(0, 0, 40, 100, [_c(0, 0, 40, 50)])),
        isFalse,
      );
    });

    test('diagnosisCharsOf 序号 1 基、relSize 以中位为 1', () {
      final chars = <CharBlock>[
        _c(0, 0, 40, 50, order: 0),
        _c(0, 50, 40, 50, order: 1),
        _c(0, 100, 40, 100, order: 2),
      ];
      final info = diagnosisCharsOf(_line(0, 0, 40, 200, chars));
      expect(info.map((e) => e.order).toList(), [1, 2, 3]);
      expect(info[0].relSize, closeTo(1.0, 1e-9));
      expect(info[2].relSize, closeTo(2.0, 1e-9));
    });

    test('diagnosisCharsOf 乱序 order 先按阅读序排序再连续重编号', () {
      // 手工编辑过的行 order 可能乱序：数组顺序与阅读序不一致时，
      // 编号必须跟 order（阅读序）走，才能与叠加框编号对上。
      final chars = <CharBlock>[
        _c(0, 100, 40, 50, text: '天', order: 2),
        _c(0, 0, 40, 50, text: '地', order: 0),
        _c(0, 50, 40, 50, text: '玄', order: 1),
      ];
      final info = diagnosisCharsOf(_line(0, 0, 40, 150, chars));
      expect(info.map((e) => e.order).toList(), [1, 2, 3]);
      expect(info.map((e) => e.text).toList(), ['地', '玄', '天']);
    });

    test('hasSignificantBoxOverlap：安全边距小交集不算，大面积互叠算', () {
      final a = _c(0, 0, 40, 50, order: 0);
      final b = _c(38, 0, 40, 50, order: 1); // 与 a 交集 2px 宽（5%）
      expect(hasSignificantBoxOverlap([a, b]), isFalse);
      final c = _c(10, 0, 40, 50, order: 2); // 与 a 交集 30px 宽（75%）
      expect(hasSignificantBoxOverlap([a, c]), isTrue);
    });

    test('shouldAdopt：新字框大面积互叠时拒绝（防叠框采纳）', () {
      // 质量分与数量都合格，但两个新框几乎同位（重摆区域选错的典型
      // 产出）——必须挡在采纳之外。
      final old = [
        _c(0, 0, 40, 50, text: '甲', conf: 0.4, order: 0),
        _c(0, 50, 40, 50, text: '乙', conf: 0.4, order: 1),
      ];
      final dup = [
        _c(0, 0, 40, 50, text: '甲', conf: 0.95, order: 0, agree: 'both'),
        _c(1, 1, 40, 50, text: '乙', conf: 0.95, order: 1, agree: 'both'),
      ];
      expect(shouldAdopt(old, dup, 'vertical'), isFalse);
    });
  });
}
