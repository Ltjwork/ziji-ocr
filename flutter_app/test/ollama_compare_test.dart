// 「AI 模型对比」核心逻辑守门测试：上下文组装（与编辑器/整行裁决同
// 口径）、标点样字判定、抽样上限、编辑距离/差异率/命中排名、批量
// 聚合排名，以及运行器的注入 fake 端到端（不碰真实 HTTP）。
import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/services/ollama_compare.dart';
import 'package:gujichazi/services/ollama_service.dart';

CharBlock _c(
  int x,
  int y,
  int w,
  int h, {
  String id = '',
  String text = '字',
  double? conf,
  int order = 0,
  bool confirmed = false,
}) => CharBlock(
  id: id.isEmpty ? 'c$order-$x-$y' : id,
  x: x,
  y: y,
  w: w,
  h: h,
  col: 0,
  order: order,
  text: text,
  conf: conf,
  confirmed: confirmed,
);

LineBlock _line(
  int x,
  int y,
  int w,
  int h,
  List<CharBlock> chars, {
  String id = 'l',
  String text = '',
  String orientation = 'vertical',
  String status = AnnotationStatus.proposed,
}) => LineBlock(
  id: id,
  x: x,
  y: y,
  w: w,
  h: h,
  lineNo: 0,
  orientation: orientation,
  text: text.isEmpty ? chars.map((c) => c.text).join() : text,
  chars: chars,
  status: status,
);

CompareBatchPage _page(List<LineBlock> lines) => CompareBatchPage(
  imagePath: 'img.png',
  pageLabel: '第 1 页',
  lines: lines,
);

void main() {
  group('charWindowContext 行内 12 字窗口', () {
    test('目标字前后各取 12 字，目标本身不出现', () {
      final chars = [
        for (var i = 0; i < 30; i++)
          _c(0, i * 50, 40, 50, text: String.fromCharCode(0x4E00 + i), order: i),
      ];
      final line = _line(0, 0, 40, 1500, chars);
      final (before, after) = charWindowContext(line, chars[15]);
      expect(before.length, 12);
      expect(after.length, 12);
      expect(before, contains(String.fromCharCode(0x4E00 + 14)));
      expect(before, isNot(contains(String.fromCharCode(0x4E00 + 15))));
      expect(after, contains(String.fromCharCode(0x4E00 + 16)));
    });

    test('行首/行尾目标的一侧为空', () {
      final chars = [
        _c(0, 0, 40, 50, text: '甲', order: 0),
        _c(0, 50, 40, 50, text: '乙', order: 1),
      ];
      final line = _line(0, 0, 40, 100, chars);
      expect(charWindowContext(line, chars[0]), ('', '乙'));
      expect(charWindowContext(line, chars[1]), ('甲', ''));
    });

    test('目标不在行内返回空上下文', () {
      final line = _line(0, 0, 40, 100, [
        _c(0, 0, 40, 50, text: '甲', order: 0),
      ]);
      final stranger = _c(9, 9, 40, 50, text: '？', order: 0);
      expect(charWindowContext(line, stranger), ('', ''));
    });
  });

  group('isPunctLikeChar 标点样判定', () {
    test('文本为标点 → 标点样', () {
      final line = _line(0, 0, 40, 100, [
        _c(0, 0, 40, 50, text: '甲', order: 0),
      ]);
      final punct = _c(0, 50, 40, 20, text: '。', order: 1);
      expect(isPunctLikeChar(line, punct), isTrue);
    });

    test('竖排行内跨度 < 中位 0.65 → 标点样（与编辑器同口径）', () {
      // 中位字高 50，跨度 30 < 32.5。
      final chars = [
        _c(0, 0, 40, 50, text: '', order: 0),
        _c(0, 50, 40, 50, text: '', order: 1),
        _c(0, 100, 40, 30, text: '', order: 2),
      ];
      final line = _line(0, 0, 40, 130, chars);
      expect(isPunctLikeChar(line, chars[2]), isTrue);
      expect(isPunctLikeChar(line, chars[0]), isFalse);
    });

    test('横排行按宽度算跨度', () {
      final chars = [
        _c(0, 0, 50, 40, text: '', order: 0),
        _c(50, 0, 30, 40, text: '', order: 1),
      ];
      final line = _line(0, 0, 80, 40, chars, orientation: 'horizontal');
      expect(isPunctLikeChar(line, chars[1]), isTrue);
    });
  });

  group('lineDecisionContextOf 整行上下文', () {
    test('current 序号归一化、邻行 ±32 字、顺序正确', () {
      final lineA = _line(0, 0, 40, 400, [
        for (var i = 0; i < 20; i++)
          _c(0, i * 20, 40, 20, text: '前$i', order: i),
      ], id: 'a');
      final lineB = _line(40, 0, 40, 300, [
        for (var i = 0; i < 5; i++)
          _c(40, i * 60, 40, 60, text: '目$i', order: i),
      ], id: 'b');
      final lineC = _line(80, 0, 40, 400, [
        for (var i = 0; i < 40; i++)
          _c(80, i * 10, 40, 10, text: '后$i', order: i),
      ], id: 'c');
      final ctx = lineDecisionContextOf([lineA, lineB, lineC], 1);
      final current = ctx.where((e) => e.scope == 'current').toList();
      expect(
        current.map((e) => e.order).toList(),
        [0, 1, 2, 3, 4],
      );
      expect(current.map((e) => e.text).toList(), ['目0', '目1', '目2', '目3', '目4']);
      // 前文恰好 20 字（上一行全部），后文截到 32 字。
      expect(ctx.where((e) => e.scope == 'before').length, 20);
      expect(ctx.where((e) => e.scope == 'after').length, 32);
      // before 的 order 为负且按原行顺序排（前文的第一个字最靠前）。
      final before = ctx.where((e) => e.scope == 'before').toList();
      expect(before.first.order, lessThan(before.last.order));
      expect(before.first.text, '前0');
    });
  });

  group('抽样', () {
    test('低置信字抽样：仅 conf<0.80 且有单字文本，按阅读序限量', () {
      final chars = [
        _c(0, 0, 40, 50, text: '甲', conf: 0.95, order: 0),
        _c(0, 50, 40, 50, text: '乙', conf: 0.42, order: 1),
        _c(0, 100, 40, 50, text: '', conf: 0.30, order: 2), // 空文本不入样
        _c(0, 150, 40, 50, text: '丁', order: 3), // 无 conf 视为 1.0
        _c(0, 200, 40, 50, text: '戊', conf: 0.60, order: 4),
      ];
      final sample = sampleLowConfChars([_line(0, 0, 40, 250, chars)],
          limit: 10);
      expect(sample.map((e) => e.$2.text).toList(), ['乙', '戊']);
      expect(sampleLowConfChars([_line(0, 0, 40, 250, chars)], limit: 1)
          .map((e) => e.$2.text), ['乙']);
    });

    test('标点样字抽样限量', () {
      final chars = [
        for (var i = 0; i < 20; i++)
          _c(0, i * 50, 40, i.isEven ? 50 : 20,
              text: i.isEven ? '字' : '。', order: i),
      ];
      final sample = samplePunctChars([_line(0, 0, 40, 1000, chars)], limit: 5);
      expect(sample.length, 5);
      expect(sample.every((e) => isPunctLikeChar(e.$1, e.$2)), isTrue);
    });

    test('诊断行抽样：行数超过上限时均匀铺开', () {
      final lines = [
        for (var i = 0; i < 20; i++)
          _line(i * 40, 0, 40, 400, [_c(0, 0, 40, 50, order: 0)], id: 'l$i'),
      ];
      final sample = sampleLinesForDiagnosis(lines, limit: 5);
      expect(sample.length, 5);
      // 均匀取样应覆盖首尾。
      expect(sample.first.id, 'l0');
      expect(sample.last.id, 'l19');
      // 行数不超过上限时全取；空行不入样。
      expect(
        sampleLinesForDiagnosis([
          _line(0, 0, 40, 400, [], id: 'empty'),
          ...lines.take(3),
        ]).length,
        3,
      );
    });
  });

  group('指标', () {
    test('levenshtein 基本性质', () {
      expect(levenshtein('', ''), 0);
      expect(levenshtein('abc', ''), 3);
      expect(levenshtein('abc', 'abc'), 0);
      expect(levenshtein('kitten', 'sitting'), 3);
      expect(levenshtein('府相同祿', '府相同祿'), 0);
      expect(levenshtein('府相同祿', '府相同祿'.replaceFirst('祿', '福')), 1);
    });

    test('charDiffRate：一致为 0、空输出为 1、单字差为分数', () {
      expect(charDiffRate('一二三', '一二三'), 0);
      expect(charDiffRate('一二三', ''), 1);
      expect(charDiffRate('', ''), 0);
      expect(charDiffRate('一二三', '一二四'), closeTo(1 / 3, 1e-9));
    });

    test('hitRankOf：top1/top3 命中与未命中', () {
      OllamaSuggestion s(String t) => OllamaSuggestion(text: t, score: 0.9);
      expect(hitRankOf('祿', [s('祿'), s('录'), s('彔')]), 1);
      expect(hitRankOf('彔', [s('祿'), s('录'), s('彔')]), 3);
      expect(hitRankOf('福', [s('祿'), s('录')]), isNull);
      expect(hitRankOf('', [s('祿')]), isNull); // 空基准不判
    });
  });

  group('lineDiffCells 整行逐字对照', () {
    AiLineDecision decision(
      String lineText, {
      List<(int, String, String)> items = const [],
      double conf = 0.9,
    }) => AiLineDecision(
      lineText: lineText,
      confidence: conf,
      items: [
        for (final (order, text, reason) in items)
          AiLineItem(order: order, text: text, confidence: 0.9, reason: reason),
      ],
    );

    test('items 与基准等长且序号连续 → 按位对照并带出理由', () {
      final cells = lineDiffCells(
        '府相同來',
        decision(
          '府相同来',
          items: [(0, '府', ''), (1, '相', ''), (2, '同', ''), (3, '来', '简体惯用')],
        ),
      );
      expect(cells.length, 4);
      expect(cells[3].changed, isTrue);
      expect(cells[3].original, '來');
      expect(cells[3].text, '来');
      expect(cells[3].reason, '简体惯用');
      expect(cells.take(3).every((c) => !c.changed), isTrue);
      expect(changedCountOf(cells), 1);
    });

    test('items 序号不连续 → 退化为编辑距离对齐', () {
      final cells = lineDiffCells(
        '府相同來',
        decision('府相同來', items: [(5, '府', '')]), // 序号不连续
      );
      expect(cells.length, 4);
      expect(changedCountOf(cells), 0);
    });

    test('对齐路径：替换/新增/删除均可表达', () {
      // 替换：末字不同。
      var cells = lineDiffCells('一二三', decision('一二人'));
      expect(changedCountOf(cells), 1);
      expect(cells.last.changed && cells.last.original == '三', isTrue);
      expect(cells.last.text, '人');
      // 新增：模型多出一个字。
      cells = lineDiffCells('一二', decision('一二三'));
      expect(changedCountOf(cells), 1);
      expect(cells.last.inserted, isTrue);
      expect(cells.last.original, isEmpty);
      expect(cells.last.text, '三');
      // 删除：模型漏了一个字。
      cells = lineDiffCells('一二三', decision('一二'));
      expect(changedCountOf(cells), 1);
      expect(cells.last.deleted, isTrue);
      expect(cells.last.original, '三');
      expect(cells.last.text, isEmpty);
      // 完全一致。
      cells = lineDiffCells('一二三', decision('一二三'));
      expect(changedCountOf(cells), 0);
    });
  });

  group('noMultimodal 签名（纯文本模型拒图的 400）', () {
    test('识别用户实测报文（含上游再包一层 JSON 的情况）', () {
      const raw =
          '{"error":"{\\"error\\":\\"code\\":400,\\"message\\":\\"Multimodal data provided, '
          'but model does not support multimodal requests.\\",\\"type\\":\\"invalid_request_error\\"}"}';
      expect(OllamaService.noMultimodalForTest(raw), isTrue);
      expect(
        OllamaService.noMultimodalForTest('does not support multimodal'),
        isTrue,
      );
    });

    test('普通错误不误判', () {
      expect(OllamaService.noMultimodalForTest('model not found'), isFalse);
      expect(OllamaService.noMultimodalForTest(''), isFalse);
      expect(OllamaService.noMultimodalForTest('Ollama 返回 500 running the model'),
          isFalse);
    });
  });

  group('summarizeByTask 聚合排名', () {
    CompareRunResult result(
      CompareTask task,
      String model,
      String reference,
      List<OllamaSuggestion> sugs, {
      int elapsedMs = 100,
    }) => CompareRunResult(
      task: task,
      model: model,
      provider: AiProvider.localOllama,
      pageLabel: '第 1 页',
      lineId: 'l1',
      reference: reference,
      referenceConfirmed: false,
      elapsedMs: elapsedMs,
      trace: OllamaTrace(),
      suggestions: sugs,
    );

    test('候选任务按 top3 命中率排名，同分看平均耗时', () {
      OllamaSuggestion s(String t) => OllamaSuggestion(text: t, score: 0.9);
      final results = [
        // A：2/3 命中；B：1/3 命中但更快；C：全 miss。
        result(CompareTask.charAssist, 'A', '甲', [s('甲'), s('乙')]),
        result(CompareTask.charAssist, 'A', '乙', [s('乙')]),
        result(CompareTask.charAssist, 'A', '丙', [s('错')]),
        result(CompareTask.charAssist, 'B', '甲', [s('甲')], elapsedMs: 50),
        result(CompareTask.charAssist, 'B', '乙', [s('错')]),
        result(CompareTask.charAssist, 'B', '丙', [s('错')]),
        result(CompareTask.charAssist, 'C', '甲', [s('错')]),
      ];
      final summaries = summarizeByTask(results);
      expect(summaries.length, 1);
      final rows = summaries.first.rows;
      expect(rows.map((r) => r.model).toList(), ['A', 'B', 'C']);
      expect(rows[0].top1Rate, closeTo(2 / 3, 1e-9));
      expect(rows[0].top3Rate, closeTo(2 / 3, 1e-9));
      expect(rows[0].scored, 3);
      // 空基准样本不计入 scored。
      expect(rows[2].scored, 1);
    });

    test('整行任务聚合差异率与可采纳率', () {
      CompareRunResult lineResult(
        String model,
        String out,
        double conf, {
        int elapsedMs = 100,
      }) => CompareRunResult(
        task: CompareTask.lineDecision,
        model: model,
        provider: AiProvider.localOllama,
        pageLabel: '第 1 页',
        lineId: 'l1',
        reference: '府相同來',
        referenceConfirmed: true,
        elapsedMs: elapsedMs,
        trace: OllamaTrace(),
        lineDecision: AiLineDecision(
          lineText: out,
          confidence: conf,
          items: const [],
        ),
      );
      final summaries = summarizeByTask([
        lineResult('A', '府相同來', 0.95),
        lineResult('A', '府相來', 0.70),
        lineResult('B', '府相同祿', 0.99),
      ]);
      final rows = summaries.single.rows;
      expect(rows[0].model, 'B'); // eligible 率更高（1.0 > 0.5）
      expect(rows[1].eligibleRate, 0.5);
      expect(rows[1].avgDiffRate, closeTo((0 + 1 / 4) / 2, 1e-9));
    });

    test('失败样本计入错误率并拉低诊断主指标', () {
      CompareRunResult diag(String model, {String? error}) =>
          CompareRunResult(
            task: CompareTask.boxDiagnosis,
            model: model,
            provider: AiProvider.localOllama,
            pageLabel: '第 1 页',
            lineId: 'l1',
            reference: '',
            referenceConfirmed: false,
            elapsedMs: 100,
            trace: OllamaTrace(),
            error: error,
            boxDiagnosis: error == null
                ? const OllamaBoxDiagnosis(lineOk: true, issues: [])
                : null,
          );
      final summaries = summarizeByTask([
        diag('A'),
        diag('A'),
        diag('B', error: '模型不存在'),
      ]);
      final rows = summaries.single.rows;
      expect(rows.first.model, 'A');
      expect(rows.first.primaryMetric, 1.0);
      expect(rows.last.errorRate, 1.0);
    });
  });

  group('OllamaCompareRunner（注入 fake + 不可达端口，不依赖真实 Ollama）', () {
    // 端口 1 无服务：连接被立即拒绝，错误路径可离线确定性复现。
    const offline = OllamaSettings(
      baseUrl: 'http://127.0.0.1:1',
      visionModel: '原始视觉',
      textModel: '原始文本',
    );

    test('runTask 单字辅助：裁图失败退化为纯上下文（编辑器同款降级）',
        () async {
      final runner = OllamaCompareRunner(
        settings: offline,
        fetchLineThumb: (request, {maxSide = 640}) async => null,
      );
      final chars = [
        _c(0, 0, 40, 50, text: '甲', conf: 0.5, order: 0),
        _c(0, 50, 40, 50, text: '乙', conf: 0.4, order: 1),
      ];
      final line = _line(0, 0, 40, 100, chars, id: 'l1');
      final r = await runner.runTask(
        task: CompareTask.charAssist,
        model: (provider: AiProvider.localOllama, extPid: kNoExtProvider, name: '被测模型'),
        page: _page([line]),
        lineIndex: 0,
        target: chars[1],
      );
      // 行条裁图失败（fake 返回 null）→ 纯上下文口径；服务不可达 →
      // 错误结果而非异常上抛。
      expect(r.ok, isFalse);
      expect(r.model, '被测模型');
      expect(r.reference, '乙');
      expect(r.trace.imageBase64, isNull); // 纯上下文，未附图
      expect(r.trace.prompt, isNotEmpty); // prompt 在请求前已填
      expect(r.trace.prompt, contains('没有图像')); // 纯上下文的降级提示
      expect(r.elapsedMs, greaterThanOrEqualTo(0));
    });

    test('runTask 整行裁决/框诊断：裁图失败返回明确错误（不请求 Ollama）',
        () async {
      final runner = OllamaCompareRunner(
        settings: offline,
        fetchLineThumb: (request, {maxSide = 640}) async => null,
      );
      final line = _line(0, 0, 40, 100, [
        _c(0, 0, 40, 50, text: '甲', order: 0),
      ], id: 'l1');
      final page = _page([line]);
      final lineR = await runner.runTask(
        task: CompareTask.lineDecision,
        model: (provider: AiProvider.localOllama, extPid: kNoExtProvider, name: 'm'),
        page: page,
        lineIndex: 0,
      );
      final boxR = await runner.runTask(
        task: CompareTask.boxDiagnosis,
        model: (provider: AiProvider.localOllama, extPid: kNoExtProvider, name: 'm'),
        page: page,
        lineIndex: 0,
      );
      expect(lineR.ok, isFalse);
      expect(lineR.error, contains('行条裁图失败'));
      expect(boxR.ok, isFalse);
      expect(boxR.error, contains('行条裁图失败'));
    });

    test('人工基准：整行以手填内容为参考，单字按位取字', () async {
      final runner = OllamaCompareRunner(
        settings: offline,
        fetchLineThumb: (request, {maxSide = 640}) async => null,
      );
      final chars = [
        _c(0, 0, 40, 50, text: '甲', conf: 0.5, order: 0),
        _c(0, 50, 40, 50, text: '乙', conf: 0.4, order: 1),
      ];
      final line = _line(0, 0, 40, 100, chars, id: 'l1', text: '甲乙');
      final page = _page([line]);
      // 整行裁决：基准 = 手填内容。
      final lineR = await runner.runTask(
        task: CompareTask.lineDecision,
        model: (provider: AiProvider.localOllama, extPid: kNoExtProvider, name: 'm'),
        page: page,
        lineIndex: 0,
        manualLineRef: '甲丙',
      );
      expect(lineR.reference, '甲丙');
      expect(lineR.manualReference, isTrue);
      expect(lineR.referenceConfirmed, isTrue);
      // 框诊断不受人工基准影响（无文字基准）。
      final boxR = await runner.runTask(
        task: CompareTask.boxDiagnosis,
        model: (provider: AiProvider.localOllama, extPid: kNoExtProvider, name: 'm'),
        page: page,
        lineIndex: 0,
        manualLineRef: '甲丙',
      );
      expect(boxR.manualReference, isFalse);
      // 单字辅助：乙（下标 1）的人工基准字 = 丙。
      final charR = await runner.runTask(
        task: CompareTask.charAssist,
        model: (provider: AiProvider.localOllama, extPid: kNoExtProvider, name: 'm'),
        page: page,
        lineIndex: 0,
        target: chars[1],
        manualLineRef: '甲丙',
      );
      expect(charR.reference, '丙');
      expect(charR.manualReference, isTrue);
      // 手填内容比行短：越界位回落到字块当前文本。
      final shortR = await runner.runTask(
        task: CompareTask.punctAssist,
        model: (provider: AiProvider.localOllama, extPid: kNoExtProvider, name: 'm'),
        page: page,
        lineIndex: 0,
        target: chars[1],
        manualLineRef: '甲',
      );
      expect(shortR.reference, '乙');
    });

    test('runBatch：图像/文本组各跑各的任务、同模型连续、取消立即生效',
        () async {
      final lines = [
        _line(0, 0, 40, 300, [
          _c(0, 0, 40, 50, text: '甲', conf: 0.3, order: 0),
          _c(0, 50, 40, 20, text: '。', conf: 0.9, order: 1),
        ], id: 'l1'),
        _line(40, 0, 40, 300, [
          _c(40, 0, 40, 50, text: '乙', conf: 0.95, order: 0),
        ], id: 'l2'),
      ];
      final runner = OllamaCompareRunner(
        settings: offline,
        fetchLineThumb: (request, {maxSide = 640}) async => null,
      );
      final results = <CompareRunResult>[];
      var lastProgress = '';
      await runner.runBatch(
        pages: [_page(lines)],
        visionModels: const [
          (provider: AiProvider.localOllama, extPid: kNoExtProvider, name: 'v1'),
          (provider: AiProvider.localOllama, extPid: kNoExtProvider, name: 'v2'),
        ],
        textModels: const [(provider: AiProvider.localOllama, extPid: kNoExtProvider, name: 't1')],
        tasks: {
            CompareTask.charAssist, CompareTask.punctAssist,
            CompareTask.lineDecision, CompareTask.boxDiagnosis,
        },
        onProgress: (p) => lastProgress = p.description,
        onResult: results.add,
      );
      // 样本：低置信字 1（甲）+ 标点样 1（。）+ 整行 2 + 诊断 2。
      // 图像组（v1、v2）跑 整行 2 + 诊断 2 = 4/模型；文本组（t1）跑
      // 单字 1 + 标点 1 = 2 → 共 4+4+2 = 10 次；全部错误但不中断。
      expect(results.length, 10);
      expect(results.every((r) => !r.ok), isTrue);
      expect(lastProgress, contains('完成'));
      // 分组任务：图像任务只由图像模型跑，文本任务只由文本模型跑。
      expect(
        results
            .where((r) => r.task.needsVisionModel)
            .map((r) => r.model)
            .toSet(),
        {'v1', 'v2'},
      );
      expect(
        results
            .where((r) => !r.task.needsVisionModel)
            .map((r) => r.model)
            .toSet(),
        {'t1'},
      );
      // 同模型连续：v1 的全部结果在 v2 之前（串行换载顺序）。
      final firstV2 = results.indexWhere((r) => r.model == 'v2');
      expect(
        results.sublist(0, firstV2).every((r) => r.model == 'v1'),
        isTrue,
      );

      // 取消：开头即取消 → 0 结果。
      final cancelled = <CompareRunResult>[];
      await runner.runBatch(
        pages: [_page(lines)],
        visionModels: const [(provider: AiProvider.localOllama, extPid: kNoExtProvider, name: 'v1')],
        textModels: const [(provider: AiProvider.localOllama, extPid: kNoExtProvider, name: 't1')],
        tasks: {CompareTask.charAssist},
        onResult: cancelled.add,
        cancelled: () => true,
      );
      expect(cancelled, isEmpty);

      // 某组没勾模型时该组任务整体跳过（不产生样本）。
      final visionOnly = <CompareRunResult>[];
      await runner.runBatch(
        pages: [_page(lines)],
        visionModels: const [],
        textModels: const [(provider: AiProvider.localOllama, extPid: kNoExtProvider, name: 't1')],
        tasks: {
            CompareTask.charAssist, CompareTask.punctAssist,
            CompareTask.lineDecision, CompareTask.boxDiagnosis,
        },
        onResult: visionOnly.add,
      );
      expect(
        visionOnly.every((r) => !r.task.needsVisionModel),
        isTrue,
      );
    });
  });

  group('verdictFor 程序判断', () {
    CompareRunResult lineR(
      String model,
      String out,
      double conf, {
      String ref = '一二三',
    }) => CompareRunResult(
      task: CompareTask.lineDecision,
      model: model,
      provider: AiProvider.localOllama,
      pageLabel: 'p',
      lineId: 'l',
      reference: ref,
      referenceConfirmed: false,
      elapsedMs: 100,
      trace: OllamaTrace(),
      lineDecision: AiLineDecision(
        lineText: out,
        confidence: conf,
        items: const [],
      ),
    );

    test('整行裁决：可采纳且差异最小者为最优', () {
      final v = verdictFor([
        lineR('A', '一二三', 0.95), // 差异 0
        lineR('B', '一二四', 0.99), // 差异 1/3
        lineR('C', '一二三', 0.70), // 差异 0 但不可采纳
      ]);
      expect(v.summary, contains('A 最优'));
      expect(v.summary, contains('与当前文本差异最小'));
      expect(v.badges['local|A'], contains('最优'));
      expect(v.badges['local|B'], contains('差异'));
      expect(v.badges['local|C'], contains('不采纳'));
    });

    test('整行裁决：人工基准时措辞与差异率都以人工内容为准', () {
      CompareRunResult manualR(String model, String out) =>
          CompareRunResult(
            task: CompareTask.lineDecision,
            model: model,
            provider: AiProvider.localOllama,
            pageLabel: 'p',
            lineId: 'l',
            reference: '甲乙丙', // 人工基准
            referenceConfirmed: true,
            manualReference: true,
            elapsedMs: 100,
            trace: OllamaTrace(),
            lineDecision: AiLineDecision(
              lineText: out,
              confidence: 0.95,
              items: const [],
            ),
          );
      final v = verdictFor([manualR('A', '甲乙丙'), manualR('B', '甲乙丁')]);
      expect(v.summary, contains('A 最优'));
      expect(v.summary, contains('与人工基准差异最小'));
      expect(v.summary, isNot(contains('基准已人工确认'))); // 人工基准时不再重复注
      expect(v.badges['local|B'], contains('差异 33%'));
    });

    test('整行裁决：全部不可采纳时无最优', () {
      final v = verdictFor([lineR('A', '一二三', 0.5)]);
      expect(v.summary, contains('无可采纳'));
      expect(v.badges['local|A'], isNot(contains('最优')));
    });

    test('候选类：第 1 命中者为最优；无命中时说明最好排名', () {
      CompareRunResult charR(String model, List<String> texts) =>
          CompareRunResult(
            task: CompareTask.charAssist,
            model: model,
            provider: AiProvider.localOllama,
            pageLabel: 'p',
            lineId: 'l',
            reference: '祿',
            referenceConfirmed: false,
            elapsedMs: 100,
            trace: OllamaTrace(),
            suggestions: [
              for (final t in texts) OllamaSuggestion(text: t, score: 0.9),
            ],
          );
      final v = verdictFor([charR('A', ['祿', '录']), charR('B', ['彔', '祿'])]);
      expect(v.summary, contains('A 最优'));
      expect(v.badges['local|B'], '✓ 第 2');
      // 无第 1 命中但有名次 → 说明最好排名；全员未命中 → 明确说未列入。
      final ranked = verdictFor([charR('A', ['甲']), charR('B', ['甲', '乙', '祿'])]);
      expect(ranked.summary, contains('最好排名'));
      final miss = verdictFor([charR('A', ['甲']), charR('B', ['乙'])]);
      expect(miss.summary, contains('均未'));
    });

    test('框诊断：多数一致获 ✓，少数标意见；无多数时明示人工判断', () {
      CompareRunResult diagR(String model, {bool lineOk = true, int? pos}) =>
          CompareRunResult(
            task: CompareTask.boxDiagnosis,
            model: model,
            provider: AiProvider.localOllama,
            pageLabel: 'p',
            lineId: 'l',
            reference: '',
            referenceConfirmed: false,
            elapsedMs: 100,
            trace: OllamaTrace(),
            boxDiagnosis: OllamaBoxDiagnosis(
              lineOk: lineOk,
              issues: lineOk
                  ? const []
                  : [
                      OllamaBoxIssue(
                        type: OllamaBoxIssueType.charClipped,
                        pos: pos ?? 1,
                        note: '',
                      ),
                    ],
            ),
          );
      final agree = verdictFor([
        diagR('A', lineOk: false, pos: 3),
        diagR('B', lineOk: false, pos: 3),
        diagR('C'),
      ]);
      expect(agree.summary, contains('一致'));
      expect(agree.badges['local|A'], '✓ 与多数一致');
      expect(agree.badges['local|B'], '✓ 与多数一致');
      expect(agree.badges['local|C'], '少数意见');
      final noMajority = verdictFor([diagR('A'), diagR('B', lineOk: false)]);
      expect(noMajority.summary, contains('人工判断'));
      expect(noMajority.badges['local|A'], '无多数可对照');
    });
  });
  group('runTask 单字辅助带行图（与编辑器同口径）', () {
    test('裁图成功：整行条图 + 橙框标目标字的 prompt，图随请求发送',
        () async {
      // fake 裁图返回 base64 → suggestChar 走带图口径；离线端口 1 让
      // 请求失败，但 trace 在请求前已定格，可离线断言输入形态。
      final runner = OllamaCompareRunner(
        settings: const OllamaSettings(baseUrl: 'http://127.0.0.1:1'),
        fetchLineThumb: (request, {maxSide = 640}) async => 'QUJD',
      );
      final chars = [
        _c(0, 0, 40, 50, text: '甲', conf: 0.5, order: 0),
        _c(0, 50, 40, 50, text: '乙', conf: 0.4, order: 1),
      ];
      final line = _line(0, 0, 40, 100, chars, id: 'l1');
      final r = await runner.runTask(
        task: CompareTask.charAssist,
        model: (provider: AiProvider.localOllama, extPid: kNoExtProvider, name: 'vl'),
        page: _page([line]),
        lineIndex: 0,
        target: chars[1],
      );
      expect(r.ok, isFalse); // 离线端口，识别失败
      expect(r.trace.imageBase64, 'QUJD');
      expect(r.trace.imageDropped, isFalse);
      expect(r.trace.prompt, contains('整行'));
      expect(r.trace.prompt, contains('橙色方框'));
      expect(r.trace.prompt, contains('甲')); // 行内上下文仍在
    });
  });

  group('本地与外部模型混跑（ModelRef）', () {
    test('modelLabel/modelKey 带来源，同名不同来源互不相等', () {
      const local = (provider: AiProvider.localOllama, extPid: kNoExtProvider, name: 'gpt-4o-mini');
      const ext = (provider: AiProvider.externalApi, extPid: kNoExtProvider, name: 'gpt-4o-mini');
      expect(local == ext, isFalse);
      expect(modelRefLabel(local), '本地·gpt-4o-mini');
      expect(modelRefLabel(ext), '外部·gpt-4o-mini');
      expect(modelKeyOf(local) == modelKeyOf(ext), isFalse);
    });

    test('runTask 外部来源走外部传输层：未配置地址返回可读错误且 provider 落账',
        () async {
      // 外部未配置供应商 → 不发网络请求直接抛可读的配置引导错误。
      final runner = OllamaCompareRunner(
        settings: const OllamaSettings(provider: AiProvider.externalApi),
        fetchLineThumb: (request, {maxSide = 640}) async => null,
      );
      final chars = [
        _c(0, 0, 40, 50, text: '甲', conf: 0.5, order: 0),
        _c(0, 50, 40, 50, text: '乙', conf: 0.4, order: 1),
      ];
      final line = _line(0, 0, 40, 100, chars, id: 'l1');
      final r = await runner.runTask(
        task: CompareTask.charAssist,
        model: (provider: AiProvider.externalApi, extPid: kNoExtProvider, name: 'glm-4.5v'),
        page: _page([line]),
        lineIndex: 0,
        target: chars[1],
      );
      expect(r.ok, isFalse);
      expect(r.error, contains('外部模型 API 未配置完整'));
      expect(r.provider, AiProvider.externalApi);
      expect(r.model, 'glm-4.5v');
      expect(r.modelLabel, '外部·glm-4.5v');
    });

    test('runTask 本地来源不受外部空配置影响（仍走本地地址）', () async {
      // 同一个 runner（外部未配置），本地 ModelRef 应走本地 baseUrl=端口 1
      // 的连接失败路径，而不是「未填写外部 API 地址」。
      final runner = OllamaCompareRunner(
        settings: const OllamaSettings(
          provider: AiProvider.externalApi,
          baseUrl: 'http://127.0.0.1:1',
        ),
        fetchLineThumb: (request, {maxSide = 640}) async => null,
      );
      final chars = [_c(0, 0, 40, 50, text: '甲', conf: 0.5, order: 0)];
      final line = _line(0, 0, 40, 50, chars, id: 'l1');
      final r = await runner.runTask(
        task: CompareTask.charAssist,
        model: (provider: AiProvider.localOllama, extPid: kNoExtProvider, name: 'qwen3.5:4b'),
        page: _page([line]),
        lineIndex: 0,
        target: chars[0],
      );
      expect(r.ok, isFalse);
      expect(r.error, isNot(contains('未填写外部 API 地址')));
      expect(r.provider, AiProvider.localOllama);
    });

    test('summarizeByTask：同名模型分属两来源时不混在一个聚合行', () {
      OllamaSuggestion s(String t) => OllamaSuggestion(text: t, score: 0.9);
      CompareRunResult r(
        AiProvider provider,
        String reference,
        List<OllamaSuggestion> sugs,
      ) => CompareRunResult(
        task: CompareTask.charAssist,
        model: 'same-name',
        provider: provider,
        pageLabel: '第 1 页',
        lineId: 'l1',
        reference: reference,
        referenceConfirmed: false,
        elapsedMs: 100,
        trace: OllamaTrace(),
        suggestions: sugs,
      );

      final summaries = summarizeByTask([
        r(AiProvider.localOllama, '甲', [s('甲')]),
        r(AiProvider.externalApi, '乙', [s('错')]),
      ]);
      final rows = summaries.single.rows..sort((a, b) => a.modelKey.compareTo(b.modelKey));
      expect(rows.length, 2); // 撞名不合并
      expect(rows.map((row) => row.provider).toSet().length, 2);
      expect(rows.every((row) => row.model == 'same-name'), isTrue);
      expect(rows.map((row) => row.modelLabel).toSet().length, 2);
    });

    test('runBatch 混跑：同来源模型的调用连续（本地先、外部后）', () async {
      final runner = OllamaCompareRunner(
        settings: const OllamaSettings(baseUrl: 'http://127.0.0.1:1'),
        fetchLineThumb: (request, {maxSide = 640}) async => null,
      );
      final chars = [_c(0, 0, 40, 50, text: '甲', conf: 0.5, order: 0)];
      final line = _line(0, 0, 40, 50, chars, id: 'l1');
      final results = <CompareRunResult>[];
      await runner.runBatch(
        pages: [_page([line])],
        // 传入顺序故意交错，执行应按传入顺序逐模型跑完各自样本
        visionModels: const [
          (provider: AiProvider.externalApi, extPid: kNoExtProvider, name: 'e-vl'),
          (provider: AiProvider.localOllama, extPid: kNoExtProvider, name: 'l-vl'),
        ],
        textModels: const [],
        tasks: {CompareTask.lineDecision},
        onResult: results.add,
      );
      // 每模型 1 样本：先 e-vl 后 l-vl（顺序保持传入顺序）
      expect(results.map((r) => r.modelLabel).toList(),
          ['外部·e-vl', '本地·l-vl']);
    });
  });
}
