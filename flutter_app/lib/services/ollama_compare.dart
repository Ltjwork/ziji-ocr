import 'dart:convert';
import 'dart:math' as math;

import '../models/models.dart';
import 'ai_box_review.dart' show diagnosisCharsOf;
import 'ai_line_repair.dart';
import 'ai_trace.dart';
import 'ollama_service.dart';
import 'python_service.dart' show LineThumbRequest, PythonService;

/// 「AI 模型对比」的四个对比任务（对应「功能开关」卡里的 AI 功能）。
/// 任务固定归属两个模型组（对比页按组选模型）：图像模型跑必须看图的
/// 任务（整行裁决、识别框诊断），文本模型跑文字任务（单字辅助、标点
/// 辅助）。单字辅助与编辑器同口径也带整行行图（橙框标目标字）——
/// 纯文本模型收到图会由服务层自动去图按上下文作答（trace 留痕）。
enum CompareTask {
  /// 单字辅助识别（文本模型组）：整行行图（橙框标目标字）+ 行内上下文
  /// → 候选字（与编辑器「AI 辅助识别」完全同口径；裁图失败退化为纯
  /// 上下文）。
  charAssist('单字辅助识别', '文本模型'),

  /// 标点辅助识别（文本模型组）：前后文 → 句读候选。
  punctAssist('标点辅助识别', '文本模型'),

  /// 整行裁决（图像模型组）：行条图 + 逐字信息 → 整行文字。
  lineDecision('整行裁决', '图像模型'),

  /// 识别框诊断（图像模型组）：橙框叠加行条图 → 框问题列表。
  boxDiagnosis('识别框诊断', '图像模型');

  const CompareTask(this.label, this.slotLabel);

  final String label;
  final String slotLabel;

  /// 该任务由哪个模型组执行（对比页勾选与批量编排依据）。
  bool get needsVisionModel =>
      this == CompareTask.lineDecision || this == CompareTask.boxDiagnosis;
}

/// 批量抽样上限（每页）：框诊断/单字辅助逐条都要几秒级推理，抽样
/// 控制一轮批量的总时长；整行裁决是主战场，全量跑。
const int kBatchCharSampleLimit = 12;
const int kBatchPunctSampleLimit = 12;
const int kBatchDiagnosisSampleLimit = 8;
const double kLowConfThreshold = 0.80;

// ── 上下文组装（与编辑器/整行裁决路径同口径的纯函数）──

/// 单字/标点辅助的行内上下文：该字前后各 12 字（按行内 chars 顺序，
/// 与编辑器轻点字块的口径一致）。返回 (前文, 后文)。
(String, String) charWindowContext(LineBlock line, CharBlock c) {
  final chars = line.chars;
  final idx = chars.indexOf(c);
  if (idx < 0) return ('', '');
  final before = StringBuffer();
  for (var i = idx - 1; i >= 0 && before.length < 12; i--) {
    before.write(chars[i].text);
  }
  final after = StringBuffer();
  for (var i = idx + 1; i < chars.length && after.length < 12; i++) {
    after.write(chars[i].text);
  }
  return (before.toString(), after.toString());
}

/// 该字框是否标点样（与编辑器同口径）：文本为标点，或沿阅读轴跨度
/// 小于行内中位字的 0.65 倍（刻本句读点不到半个字高）。
bool isPunctLikeChar(LineBlock line, CharBlock c) {
  final vertical = line.orientation == 'vertical';
  final spans = line.chars.map((ch) => vertical ? ch.h : ch.w).toList()..sort();
  final median = spans.isEmpty ? 0 : spans[spans.length ~/ 2];
  final span = vertical ? c.h : c.w;
  return isPunctuationText(c.text) || (median > 0 && span < median * 0.65);
}

/// 整行裁决的上下文：目标行逐字（序号归一化从 0 连续递增）+ 邻行
/// 前后各 32 字（与 applyAiLineAssistToLines 同口径）。
List<AiContextItem> lineDecisionContextOf(List<LineBlock> lines, int lineIndex) {
  final line = lines[lineIndex];
  final targetChars = List<CharBlock>.from(line.chars)
    ..sort((a, b) => a.order.compareTo(b.order));
  final current = [
    for (var i = 0; i < targetChars.length; i++)
      AiContextItem(
        order: i,
        text: targetChars[i].text,
        confidence: targetChars[i].conf ?? 0.5,
        agree: targetChars[i].agree ?? '',
        punctuation: isPunctuationText(targetChars[i].text),
        scope: 'current',
      ),
  ];
  final previous = <AiContextItem>[];
  var previousCount = 0;
  for (var i = lineIndex - 1; i >= 0 && previousCount < 32; i--) {
    final chars = lines[i].chars;
    for (var j = chars.length - 1; j >= 0 && previousCount < 32; j--) {
      final c = chars[j];
      previous.add(
        AiContextItem(
          order: -(previousCount + 1),
          text: c.text,
          confidence: c.conf ?? 0.5,
          agree: c.agree ?? '',
          punctuation: isPunctuationText(c.text),
          scope: 'before',
        ),
      );
      previousCount++;
    }
  }
  previous.sort((a, b) => a.order.compareTo(b.order));
  final following = <AiContextItem>[];
  var followingCount = 0;
  for (var i = lineIndex + 1; i < lines.length && followingCount < 32; i++) {
    for (final c in lines[i].chars) {
      if (followingCount >= 32) break;
      following.add(
        AiContextItem(
          order: line.chars.length + followingCount,
          text: c.text,
          confidence: c.conf ?? 0.5,
          agree: c.agree ?? '',
          punctuation: isPunctuationText(c.text),
          scope: 'after',
        ),
      );
      followingCount++;
    }
  }
  return [...previous, ...current, ...following];
}

// ── 抽样（纯函数）──

/// 批量单字辅助样本：低置信字（conf<0.80，无 conf 视为 1）按阅读序
/// 取前 [limit] 个。低置信正是 AI 辅助的目标场景。
List<(LineBlock, CharBlock)> sampleLowConfChars(
  List<LineBlock> lines, {
  int limit = kBatchCharSampleLimit,
}) {
  final out = <(LineBlock, CharBlock)>[];
  for (final line in lines) {
    final chars = List<CharBlock>.from(line.chars)
      ..sort((a, b) => a.order.compareTo(b.order));
    for (final c in chars) {
      if (out.length >= limit) return out;
      final conf = c.conf ?? 1.0;
      if (conf < kLowConfThreshold && c.text.runes.length == 1) {
        out.add((line, c));
      }
    }
  }
  return out;
}

/// 批量标点辅助样本：标点样字（文本是标点，或标点样小框），按阅读序。
List<(LineBlock, CharBlock)> samplePunctChars(
  List<LineBlock> lines, {
  int limit = kBatchPunctSampleLimit,
}) {
  final out = <(LineBlock, CharBlock)>[];
  for (final line in lines) {
    final chars = List<CharBlock>.from(line.chars)
      ..sort((a, b) => a.order.compareTo(b.order));
    for (final c in chars) {
      if (out.length >= limit) return out;
      if (isPunctLikeChar(line, c)) out.add((line, c));
    }
  }
  return out;
}

/// 批量框诊断样本行：均匀铺开取 [limit] 行（含首尾；行数少时全取）。
List<LineBlock> sampleLinesForDiagnosis(
  List<LineBlock> lines, {
  int limit = kBatchDiagnosisSampleLimit,
}) {
  final candidates = lines.where((l) => l.chars.isNotEmpty).toList();
  if (candidates.length <= limit) return candidates;
  if (limit <= 0) return const [];
  if (limit == 1) return [candidates.first];
  final step = (candidates.length - 1) / (limit - 1);
  return [
    for (var i = 0; i < limit; i++) candidates[(i * step).round()],
  ];
}

// ── 指标（纯函数）──

/// 编辑距离（字符级）。
int levenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.runes.length;
  if (b.isEmpty) return a.runes.length;
  final ar = a.runes.toList();
  final br = b.runes.toList();
  var prev = List<int>.generate(br.length + 1, (j) => j);
  var curr = List<int>.filled(br.length + 1, 0);
  for (var i = 1; i <= ar.length; i++) {
    curr[0] = i;
    for (var j = 1; j <= br.length; j++) {
      final cost = ar[i - 1] == br[j - 1] ? 0 : 1;
      curr[j] = math.min(
        math.min(curr[j - 1] + 1, prev[j] + 1),
        prev[j - 1] + cost,
      );
    }
    final swap = prev;
    prev = curr;
    curr = swap;
  }
  return prev[br.length];
}

/// 整行输出与基准文本的字符差异率（0=完全一致，1=完全不同/为空）。
double charDiffRate(String reference, String output) {
  final ref = reference.trim();
  final out = output.trim();
  if (ref.isEmpty && out.isEmpty) return 0;
  final denom = math.max(ref.runes.length, out.runes.length);
  if (denom == 0) return 0;
  return levenshtein(ref, out) / denom;
}

/// 基准文本在候选里的排名（1 起；null=未命中或基准为空）。
int? hitRankOf(String reference, List<OllamaSuggestion> suggestions) {
  final ref = reference.trim();
  if (ref.isEmpty) return null;
  for (var i = 0; i < suggestions.length; i++) {
    if (suggestions[i].text.trim() == ref) return i + 1;
  }
  return null;
}

// ── 整行逐字对照（对比页的校对视图）──

/// 整行裁决逐字对照的一个位置：模型输出侧的一个字 + 它相对基准的
/// 动作（保持 / 修改 / 新增 / 删除）。
class LineDiffCell {
  const LineDiffCell({
    required this.text,
    required this.original,
    required this.changed,
    required this.inserted,
    required this.deleted,
    this.reason = '',
  });

  /// 模型输出的字；deleted 时为空。
  final String text;

  /// 基准里被改/删的字；inserted 时为空。
  final String original;

  /// 相对基准有改动（replace/insert/delete）。
  final bool changed;
  final bool inserted;
  final bool deleted;

  /// 模型给的逐字理由（仅 items 按位对照路径有值）。
  final String reason;
}

/// 基准 vs 模型整行输出的逐字对照。decision.items 与基准等长且序号
/// 从 0 连续时按位对照（可带出模型的逐字理由），否则退化为编辑距离
/// 对齐（模型输出串 vs 基准串）。
List<LineDiffCell> lineDiffCells(String reference, AiLineDecision decision) {
  final ref = reference.trim();
  final refRunes = ref.runes.toList();
  final items = List<AiLineItem>.from(decision.items)
    ..sort((a, b) => a.order.compareTo(b.order));
  var contiguous = items.isNotEmpty && items.length == refRunes.length;
  for (var i = 0; contiguous && i < items.length; i++) {
    if (items[i].order != i) contiguous = false;
  }
  if (contiguous) {
    LineDiffCell at(int i) {
      final original = String.fromCharCode(refRunes[i]);
      return LineDiffCell(
        text: items[i].text,
        original: original,
        changed: items[i].text != original,
        inserted: false,
        deleted: items[i].text.isEmpty,
        reason: items[i].reason,
      );
    }

    return [for (var i = 0; i < items.length; i++) at(i)];
  }
  return _alignCells(refRunes, decision.lineText.trim().runes.toList());
}

/// 编辑距离对齐（DP 回溯，偏好 匹配 > 修改 > 新增 > 删除）。
List<LineDiffCell> _alignCells(List<int> a, List<int> b) {
  final n = a.length;
  final m = b.length;
  if (n == 0 && m == 0) return const [];
  final d = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = 0; i <= n; i++) {
    d[i][0] = i;
  }
  for (var j = 0; j <= m; j++) {
    d[0][j] = j;
  }
  for (var i = 1; i <= n; i++) {
    for (var j = 1; j <= m; j++) {
      d[i][j] = a[i - 1] == b[j - 1]
          ? d[i - 1][j - 1]
          : 1 +
                math.min(d[i - 1][j - 1], math.min(d[i - 1][j], d[i][j - 1]));
    }
  }
  final cells = <LineDiffCell>[];
  var i = n;
  var j = m;
  String chr(int rune) => String.fromCharCode(rune);
  while (i > 0 || j > 0) {
    if (i > 0 && j > 0 && a[i - 1] == b[j - 1]) {
      cells.add(
        LineDiffCell(
          text: chr(b[j - 1]),
          original: chr(a[i - 1]),
          changed: false,
          inserted: false,
          deleted: false,
        ),
      );
      i--;
      j--;
    } else if (i > 0 && j > 0 && d[i][j] == d[i - 1][j - 1] + 1) {
      cells.add(
        LineDiffCell(
          text: chr(b[j - 1]),
          original: chr(a[i - 1]),
          changed: true,
          inserted: false,
          deleted: false,
        ),
      );
      i--;
      j--;
    } else if (j > 0 && (i == 0 || d[i][j] == d[i][j - 1] + 1)) {
      cells.add(
        LineDiffCell(
          text: chr(b[j - 1]),
          original: '',
          changed: true,
          inserted: true,
          deleted: false,
        ),
      );
      j--;
    } else {
      cells.add(
        LineDiffCell(
          text: '',
          original: chr(a[i - 1]),
          changed: true,
          inserted: false,
          deleted: true,
        ),
      );
      i--;
    }
  }
  return cells.reversed.toList();
}

/// 对照条里的改动数（修改+新增+删除）。
int changedCountOf(List<LineDiffCell> cells) =>
    cells.where((c) => c.changed).length;

// ── 运行结果 ──

/// 对比参与方的模型标识：来源（本地 Ollama / 外部模型 API）+ 外部供应商
/// id（本地恒为空串）+ 模型名。两来源、多供应商可同时勾选混跑，模型名
/// 不再全局唯一——凡勾选、聚合、徽章都以本标识为键（record 结构相等，
/// 可直接进 Set/Map）。
typedef ModelRef = ({AiProvider provider, String extPid, String name});

/// 本地模型的空供应商 id（record 字面量用）。
const String kNoExtProvider = '';

/// 展示名：「本地·qwen3.5:4b」「外部·glm-4.5v」；外部多供应商时带供应商
/// 名「外部·智谱 GLM·glm-4.5v」（[extProviderName] 解析不到时省略）。
String modelRefLabel(
  ModelRef ref, {
  String Function(String extPid)? extProviderName,
}) {
  if (ref.provider == AiProvider.localOllama) return '本地·${ref.name}';
  final pn = extProviderName?.call(ref.extPid) ?? '';
  return pn.isEmpty ? '外部·${ref.name}' : '外部·$pn·${ref.name}';
}

/// 字符串键（两来源、多供应商可能撞名，键必须带来源与供应商；本地
/// 无供应商，键保持「来源|模型名」的旧格式）。
String modelKeyOf(ModelRef ref) => ref.extPid.isEmpty
    ? '${ref.provider.wire}|${ref.name}'
    : '${ref.provider.wire}|${ref.extPid}|${ref.name}';

/// 一次「模型 × 任务 × 对象」的对比结果。基准 = 行内当前文本
/// （OCR + 人工校对的现状）；referenceConfirmed 时该基准经人工确认，
/// 命中/一致更有参考性。
class CompareRunResult {
  CompareRunResult({
    required this.task,
    required this.model,
    required this.provider,
    this.extPid = kNoExtProvider,
    required this.pageLabel,
    required this.lineId,
    required this.reference,
    required this.referenceConfirmed,
    required this.elapsedMs,
    required this.trace,
    this.charOrder = -1,
    this.manualReference = false,
    this.error,
    this.suggestions,
    this.lineDecision,
    this.boxDiagnosis,
    this.stages = const [],
    this.stageStore,
  });

  final CompareTask task;
  final String model;

  /// 该模型所属来源（本地 Ollama / 外部模型 API）——混跑时同名模型
  /// 靠它区分，聚合与徽章用 [modelKey]。
  final AiProvider provider;

  /// 外部供应商 id（本地恒为空串）：外部多供应商下同名模型靠它区分。
  final String extPid;
  final String pageLabel;
  final String lineId;

  ModelRef get ref => (provider: provider, extPid: extPid, name: model);
  String get modelLabel => modelRefLabel(ref);
  String get modelKey => modelKeyOf(ref);

  /// 单字/标点目标的字序号；行级任务为 -1。
  final int charOrder;
  final String reference;
  final bool referenceConfirmed;

  /// 基准来自用户手动填写的内容（比当前识别文本更可信，程序判断据此
  /// 比较各模型）。
  final bool manualReference;
  final int elapsedMs;
  final OllamaTrace trace;
  final String? error;
  final List<OllamaSuggestion>? suggestions;
  final AiLineDecision? lineDecision;
  final OllamaBoxDiagnosis? boxDiagnosis;

  /// 整行三步闭环的逐阶段溯源（三步分析/局部修复/AI 复核），对比页
  /// 展开渲染图组、prompt、思维链、判定与修复前后；仅 lineDecision。
  final List<AiTraceEntry> stages;

  /// stages 图片的字节来源（内存模式 recorder）；仅 lineDecision。
  final AiTraceRecorder? stageStore;

  bool get ok => error == null;

  /// 基准在候选中的排名（仅候选类任务）。
  int? get hitRank => suggestions == null
      ? null
      : hitRankOf(reference, suggestions!);

  /// 整行输出与基准的差异率（仅整行裁决）。
  double? get diffRate => lineDecision == null
      ? null
      : charDiffRate(reference, lineDecision!.lineText);
}

// ── 运行器 ──

/// 行条裁图注入点（测试用 fake 替换；默认走 Python 后端）。
typedef FetchLineThumb = Future<String?> Function(
  LineThumbRequest request, {
  int maxSide,
});

/// 批量的一页：图片路径 + 该页已加载的行标注（对比页自载副本，三步
/// 闭环的就地写回不会污染编辑器）。
class CompareBatchPage {
  CompareBatchPage({required this.imagePath, required this.pageLabel,
    required this.lines, this.settings});

  final String imagePath;
  final String pageLabel;
  final List<LineBlock> lines;

  /// 页识别方向等（局部修复重摆 /segment_region 需要）；null 按全局
  /// 默认（竖排）处理。
  final ProjectSettings? settings;
}

/// 批量进度（UI 直接展示 description）。
class CompareProgress {
  CompareProgress({
    required this.description,
    required this.done,
    required this.total,
  });

  final String description;
  final int done;
  final int total;

  double get fraction => total <= 0 ? 0 : done / total;
}

/// 单对象/批量对比执行器。混跑时每个被测模型各回各的来源（本地 Ollama
/// / 外部模型 API）——[ModelRef] 决定走哪个传输层与写哪个槽位；同来源
/// 的调用连续跑（减少 Ollama 反复换载模型）。每次调用串行，取消在调用
/// 间隙生效，已完成的结果保留。行条裁图经可注入 lambda，单测无需真实服务。
class OllamaCompareRunner {
  OllamaCompareRunner({
    required this.settings,
    this.wantThinking = false,
    FetchLineThumb? fetchLineThumb,
  }) : _fetchLineThumb = fetchLineThumb ?? _defaultFetchLineThumb;

  final OllamaSettings settings;

  /// 请求模型思维链进 trace（对比页「记录思考过程」开关）：推理型模型
  /// 会显著变慢、token 消耗变大，默认关。
  final bool wantThinking;
  final FetchLineThumb _fetchLineThumb;

  static Future<String?> _defaultFetchLineThumb(
    LineThumbRequest request, {
    int maxSide = 640,
  }) async {
    final thumbs = await PythonService.fetchLineThumbnails(
      items: [request],
      maxSide: maxSide,
    );
    return thumbs.isEmpty ? null : thumbs.first;
  }

  /// 被测模型所属来源的设置快照：切到该来源、绑定供应商（外部多供应商
  /// 时各回各家）并把模型写进对应槽位。
  OllamaSettings _settingsForVision(ModelRef model) => settings
      .copyWith(provider: model.provider)
      .withVisionModel(model.name, extProviderId: model.extPid);

  OllamaSettings _settingsForText(ModelRef model) => settings
      .copyWith(provider: model.provider)
      .withTextModel(model.name, extProviderId: model.extPid);

  /// 对一个目标（行或行内的字）跑单个任务×单模型。
  ///
  /// [pageLines] 为该页全部行（按行序），[lineIndex] 为目标行下标，
  /// 整行裁决用它组邻行上下文；[target] 为单字/标点任务的目标字。
  /// [manualLineRef] 为用户手填的整行正确文字（可选）：提供后整行裁决
  /// 以它为基准，单字/标点取同位字的字符为基准——程序判断据此比较。
  Future<CompareRunResult> runTask({
    required CompareTask task,
    required ModelRef model,
    required CompareBatchPage page,
    required int lineIndex,
    CharBlock? target,
    String? manualLineRef,
  }) async {
    final line = page.lines[lineIndex];
    final manual = (manualLineRef ?? '').trim();
    // 框诊断没有文字基准，人工内容对它无意义。
    final manualActive = manual.isNotEmpty && task != CompareTask.boxDiagnosis;
    String reference;
    bool confirmed;
    if (task == CompareTask.lineDecision) {
      reference = manualActive ? manual : line.text;
      confirmed = manualActive || line.status == AnnotationStatus.confirmed;
    } else if (target != null) {
      var ref = target.text;
      if (manualActive) {
        final idx = line.chars.indexOf(target);
        final runes = manual.runes.toList();
        if (idx >= 0 && idx < runes.length) {
          ref = String.fromCharCode(runes[idx]);
        }
      }
      reference = ref;
      confirmed = manualActive || target.confirmed;
    } else {
      reference = '';
      confirmed = false;
    }
    final trace = OllamaTrace();
    final sw = Stopwatch()..start();
    CompareRunResult build({
      String? error,
      List<OllamaSuggestion>? suggestions,
      AiLineDecision? lineDecision,
      OllamaBoxDiagnosis? boxDiagnosis,
      List<AiTraceEntry> stages = const [],
      AiTraceRecorder? stageStore,
    }) => CompareRunResult(
      task: task,
      model: model.name,
      provider: model.provider,
      extPid: model.extPid,
      pageLabel: page.pageLabel,
      lineId: line.id,
      reference: reference,
      referenceConfirmed: confirmed,
      manualReference: manualActive,
      elapsedMs: sw.elapsedMilliseconds,
      trace: trace,
      charOrder: target?.order ?? -1,
      error: error,
      suggestions: suggestions,
      lineDecision: lineDecision,
      boxDiagnosis: boxDiagnosis,
      stages: stages,
      stageStore: stageStore,
    );

    try {
      switch (task) {
        case CompareTask.charAssist:
          // 与编辑器「AI 辅助识别」完全同口径：整行条图（橙框只标出
          // 目标字）+ 行内上下文 + 当前 OCR 读法。裁图失败退化为纯上
          // 下文（编辑器同款降级）；纯文本模型收到图由服务层自动去图
          // 重试（trace.imageDropped 留痕），评测结论对齐真实功能。
          final c = target!;
          final (before, after) = charWindowContext(line, c);
          String? image;
          try {
            image = await _fetchLineThumb(
              LineThumbRequest(
                imagePath: page.imagePath,
                x: line.x,
                y: line.y,
                w: line.w,
                h: line.h,
                orientation: line.orientation,
                boxes: [(c.x, c.y, c.w, c.h)],
              ),
              // 与编辑器同口径：长边 1536（后端上限 2048）。
              maxSide: 1536,
            );
          } catch (_) {
            image = null;
          }
          final suggestions = await OllamaService.suggestChar(
            settings: _settingsForVision(model),
            imageBase64: image,
            contextBefore: before,
            contextAfter: after,
            currentText: c.text,
            wantThinking: wantThinking,
            trace: trace,
          );
          return build(suggestions: suggestions);
        case CompareTask.punctAssist:
          final c = target!;
          final (before, after) = charWindowContext(line, c);
          final suggestions = await OllamaService.suggestPunctuation(
            settings: _settingsForText(model),
            contextBefore: before,
            contextAfter: after,
            currentText: c.text,
            wantThinking: wantThinking,
            trace: trace,
          );
          return build(suggestions: suggestions);
        case CompareTask.lineDecision:
          // 与正式识别（applyAiLineAssistToLines → runLineAssist）完全同
          // 口径：干净整行裁图 + 单字裁图 → 三步分析 →（AI 标记切分问题
          // 时）尾段局部重摆 → 质量分裁决 → AI 复核。对比页的行标注是
          // 自载副本，闭环的就地写回不会污染编辑器；指标口径取闭环结束
          // 后的最终整行文字（端到端真实产出）。全程阶段记录随结果返回
          // 供详情页渲染（图组/prompt/思维链/判定/修复前后）。
          final store = AiTraceRecorder.memory(
            model: model.name,
            provider: model.provider.wire,
          );
          final before = _settingsForVision(model);
          await runLineAssist(
            line: line,
            lines: page.lines,
            lineIndex: lineIndex,
            imagePath: page.imagePath,
            settings: page.settings ?? ProjectSettings(),
            ollama: before.copyWith(enableAiThinking: wantThinking),
            recorder: store,
            log: null,
            lineThumbOverride: (l) => _fetchLineThumb(
              LineThumbRequest(
                imagePath: page.imagePath,
                x: l.x,
                y: l.y,
                w: l.w,
                h: l.h,
                orientation: l.orientation,
              ),
              maxSide: kAiLineThumbMaxSide,
            ),
          );
          final entries = store.run.entries;
          final assist = entries.isEmpty ? null : entries.first;
          if (assist == null || assist.decisionJson.isEmpty) {
            return build(
              error: assist == null
                  ? '三步分析未执行'
                  : (assist.error ?? assist.outcome),
              stages: entries,
              stageStore: store,
            );
          }
          // 首次三步分析的整行置信度（后续修复/复核不重算它）。
          var confidence = 0.0;
          try {
            final d = jsonDecode(assist.decisionJson);
            if (d is Map) {
              confidence = ((d['confidence'] as num?)?.toDouble() ?? 0)
                  .clamp(0.0, 1.0);
            }
          } catch (_) {}
          return build(
            lineDecision: AiLineDecision(
              lineText: line.text,
              confidence: confidence,
              items: const [],
            ),
            stages: entries,
            stageStore: store,
          );
        case CompareTask.boxDiagnosis:
          // 与正式「AI 检查识别框」（AiBoxReviewer）完全同口径：行条图
          // 带全部字框叠加、长边 640（该路径用 fetchLineThumbnails 默认值）、
          // 叠加框按阅读序排序（与 diagnosisCharsOf 的 1 基连续编号同序）。
          final sortedDiagChars = List<CharBlock>.from(line.chars)
            ..sort((a, b) => a.order.compareTo(b.order));
          final image = await _fetchLineThumb(
            LineThumbRequest(
              imagePath: page.imagePath,
              x: line.x,
              y: line.y,
              w: line.w,
              h: line.h,
              orientation: line.orientation,
              boxes: [
                for (final c in sortedDiagChars) (c.x, c.y, c.w, c.h),
              ],
            ),
            maxSide: 640,
          );
          if (image == null || image.isEmpty) {
            return build(error: '行条裁图失败（后端不可用或行框无效）');
          }
          final diagnosis = await OllamaService.diagnoseLineBox(
            settings: _settingsForVision(model),
            imageBase64: image,
            chars: diagnosisCharsOf(line),
            horizontal: line.orientation == 'horizontal',
            horizontalDir: page.settings?.horizontalDir ?? 'ltr',
            verticalDir: page.settings?.verticalDir ?? 'ttb',
            wantThinking: wantThinking,
            trace: trace,
          );
          return build(boxDiagnosis: diagnosis);
      }
    } on OllamaException catch (e) {
      return build(error: e.message);
    } catch (e) {
      return build(error: e.toString());
    }
  }

  /// 批量：对每页抽样样本 × 每任务 × 该任务模型组的模型串行执行（图像
  /// 任务用 [visionModels]，文本任务用 [textModels]；本地与外部模型可
  /// 混选，每个模型各回各的来源）。结果经 [onResult] 增量回传（取消后
  /// 已完成的保留），进度经 [onProgress] 报告；[cancelled] 返回 true 时
  /// 在下一个调用间隙停止。
  Future<void> runBatch({
    required List<CompareBatchPage> pages,
    required List<ModelRef> visionModels,
    required List<ModelRef> textModels,
    required Set<CompareTask> tasks,
    void Function(CompareProgress progress)? onProgress,
    void Function(CompareRunResult result)? onResult,
    bool Function()? cancelled,
  }) async {
    // 预抽样：每页每任务的样本固定，模型间样本完全一致（可比性）。
    final samples = <CompareTask, List<(CompareBatchPage, int, CharBlock?)>>{};
    for (final task in CompareTask.values) {
      if (!tasks.contains(task)) continue;
      if ((task.needsVisionModel ? visionModels : textModels).isEmpty) {
        continue;
      }
      final list = <(CompareBatchPage, int, CharBlock?)>[];
      for (final page in pages) {
        switch (task) {
          case CompareTask.charAssist:
            for (final (line, c) in sampleLowConfChars(page.lines)) {
              list.add((page, page.lines.indexOf(line), c));
            }
          case CompareTask.punctAssist:
            for (final (line, c) in samplePunctChars(page.lines)) {
              list.add((page, page.lines.indexOf(line), c));
            }
          case CompareTask.lineDecision:
            for (var i = 0; i < page.lines.length; i++) {
              if (page.lines[i].chars.isNotEmpty) list.add((page, i, null));
            }
          case CompareTask.boxDiagnosis:
            for (final line in sampleLinesForDiagnosis(page.lines)) {
              list.add((page, page.lines.indexOf(line), null));
            }
        }
      }
      samples[task] = list;
    }
    // 执行顺序：先图像模型（各自跑完其全部图像任务样本），再文本模型。
    // 模型按传入顺序跑：调用方把同来源的模型排在一起，减少来回切换。
    final plan = <(ModelRef, CompareTask)>[
      for (final model in visionModels)
        for (final task in CompareTask.values)
          if (samples.containsKey(task) && task.needsVisionModel) (model, task),
      for (final model in textModels)
        for (final task in CompareTask.values)
          if (samples.containsKey(task) && !task.needsVisionModel) (model, task),
    ];
    final total = plan
        .map((e) => samples[e.$2]!.length)
        .fold<int>(0, (a, b) => a + b);
    var done = 0;
    void report(String description) =>
        onProgress?.call(CompareProgress(description: description,
          done: done, total: total));
    ModelRef? lastModel;
    for (final (model, task) in plan) {
      if (lastModel != null && model != lastModel && cancelled?.call() != true) {
        report('${modelRefLabel(lastModel)} 完成（$done/$total），切换下一个模型…');
      }
      lastModel = model;
      for (final (page, lineIndex, target) in samples[task]!) {
        if (cancelled?.call() ?? false) {
          report('已取消（完成 $done/$total）');
          return;
        }
        report(
          '${modelRefLabel(model)} · ${task.label} · ${page.pageLabel} '
          '${target == null ? '行 ${lineIndex + 1}' : '第 ${target.order + 1} 字'}'
          '（$done/$total）',
        );
        final result = await runTask(
          task: task,
          model: model,
          page: page,
          lineIndex: lineIndex,
          target: target,
        );
        done++;
        onResult?.call(result);
      }
    }
    report('批量完成（$done/$total）');
  }
}

// ── 聚合 ──

/// 一个模型在一个任务上的批量汇总。主指标按任务取用：候选类 top1/top3
/// 命中率、整行 eligible 率与平均差异率、诊断 line_ok 率与问题分布。
/// 一个来源×模型在单个任务上的聚合行（排名用）。
class CompareModelRow {
  CompareModelRow({
    required this.task,
    required this.provider,
    this.extPid = kNoExtProvider,
    required this.model,
  });

  final CompareTask task;

  /// 该模型所属来源（本地 Ollama / 外部模型 API）。
  final AiProvider provider;

  /// 外部供应商 id（本地恒为空串）：外部多供应商下同名模型靠它区分。
  final String extPid;
  final String model;

  ModelRef get ref => (provider: provider, extPid: extPid, name: model);
  String get modelLabel => modelRefLabel(ref);
  String get modelKey => modelKeyOf(ref);
  int samples = 0;
  int errors = 0;
  final List<int> elapsed = [];

  // 候选类（单字/标点）
  int top1Hits = 0;
  int top3Hits = 0;
  int scored = 0; // 有非空基准可判定的样本数

  // 整行裁决
  double diffSum = 0;
  int diffCount = 0;
  int eligible = 0;

  // 框诊断
  int lineOk = 0;
  final Map<OllamaBoxIssueType, int> issueCounts = {};

  void add(CompareRunResult r) {
    samples++;
    elapsed.add(r.elapsedMs);
    if (!r.ok) {
      errors++;
      return;
    }
    switch (r.task) {
      case CompareTask.charAssist:
      case CompareTask.punctAssist:
        if (r.reference.trim().isNotEmpty) {
          scored++;
          final rank = r.hitRank;
          if (rank != null) {
            top3Hits++;
            if (rank == 1) top1Hits++;
          }
        }
      case CompareTask.lineDecision:
        final d = r.lineDecision!;
        final rate = r.diffRate ?? 1.0;
        diffSum += rate;
        diffCount++;
        if (d.eligible) eligible++;
      case CompareTask.boxDiagnosis:
        final diag = r.boxDiagnosis!;
        if (diag.lineOk) lineOk++;
        for (final issue in diag.issues) {
          issueCounts[issue.type] = (issueCounts[issue.type] ?? 0) + 1;
        }
    }
  }

  double get avgElapsedMs => elapsed.isEmpty
      ? 0
      : elapsed.reduce((a, b) => a + b) / elapsed.length;

  double get errorRate => samples == 0 ? 0 : errors / samples;
  double get top1Rate => scored == 0 ? 0 : top1Hits / scored;
  double get top3Rate => scored == 0 ? 0 : top3Hits / scored;
  double get eligibleRate => samples - errors == 0
      ? 0
      : eligible / (samples - errors);
  double get avgDiffRate => diffCount == 0 ? 0 : diffSum / diffCount;
  double get lineOkRate => samples - errors == 0
      ? 0
      : lineOk / (samples - errors);

  /// 排名主指标（越大越好）：候选类=top3 命中率，整行=eligible 率，
  /// 诊断=完成率（诊断对错无基准，完成率低=模型跑不动或输出不合格）。
  double get primaryMetric => switch (task) {
    CompareTask.charAssist || CompareTask.punctAssist => top3Rate,
    CompareTask.lineDecision => eligibleRate,
    CompareTask.boxDiagnosis => 1 - errorRate,
  };

  /// 主指标的中文描述（统计卡展示）。
  String get primaryMetricLabel => switch (task) {
    CompareTask.charAssist || CompareTask.punctAssist => 'top3 命中',
    CompareTask.lineDecision => '可采纳率',
    CompareTask.boxDiagnosis => '完成率',
  };

  String get primaryMetricText => switch (task) {
    CompareTask.charAssist || CompareTask.punctAssist =>
      '${(top3Rate * 100).toStringAsFixed(0)}%'
      '（top1 ${(top1Rate * 100).toStringAsFixed(0)}% · $scored 字有基准）',
    CompareTask.lineDecision =>
      '${(eligibleRate * 100).toStringAsFixed(0)}%'
      '（平均差异 ${(avgDiffRate * 100).toStringAsFixed(1)}%）',
    CompareTask.boxDiagnosis =>
      '${((1 - errorRate) * 100).toStringAsFixed(0)}%'
      '（line_ok ${(lineOkRate * 100).toStringAsFixed(0)}%）',
  };
}

/// 汇总一批结果：每任务一张表，模型行按主指标降序（同分按平均耗时升序）。
List<CompareTaskSummary> summarizeByTask(List<CompareRunResult> results) {
  final byTask = <CompareTask, List<CompareRunResult>>{};
  for (final r in results) {
    byTask.putIfAbsent(r.task, () => []).add(r);
  }
  final out = <CompareTaskSummary>[];
  for (final task in CompareTask.values) {
    final list = byTask[task];
    if (list == null || list.isEmpty) continue;
    // 两来源、多供应商的模型名可能撞名：聚合键必须带来源与供应商
    // （modelKey）。
    final rows = <String, CompareModelRow>{};
    for (final r in list) {
      rows.putIfAbsent(r.modelKey, () => CompareModelRow(task: task,
        provider: r.provider, extPid: r.extPid, model: r.model)).add(r);
    }
    final sorted = rows.values.toList()
      ..sort((a, b) {
        final byMetric = b.primaryMetric.compareTo(a.primaryMetric);
        if (byMetric != 0) return byMetric;
        return a.avgElapsedMs.compareTo(b.avgElapsedMs);
      });
    out.add(CompareTaskSummary(task: task, rows: sorted, results: list));
  }
  return out;
}

/// 一个任务的完整汇总（排名行 + 原始结果，明细展开用）。
class CompareTaskSummary {
  CompareTaskSummary({required this.task, required this.rows,
    required this.results});

  final CompareTask task;
  final List<CompareModelRow> rows;
  final List<CompareRunResult> results;
}

// ── 程序判断（单对象对比视图的"哪个模型更好"）──

/// 一个任务在单对象上的程序判断：结论一句话 + 每模型的短评徽章。
/// 基准口径与指标一致：以行内当前文本为基准（人工确认过的更可信），
/// 判断只比较"模型间相对表现"，不声明绝对正确。
class CompareVerdict {
  const CompareVerdict({required this.summary, required this.badges});

  final String summary;
  final Map<String, String> badges;
}

/// 对同一任务的一组单对象结果做程序判断。
CompareVerdict verdictFor(List<CompareRunResult> results) {
  if (results.isEmpty) {
    return const CompareVerdict(summary: '无结果', badges: {});
  }
  final task = results.first.task;
  final badges = <String, String>{};
  switch (task) {
    case CompareTask.lineDecision:
      // 可采纳（conf≥0.80 且非空）里与基准差异最小者为最优。
      final basis = results.first.manualReference ? '人工基准' : '当前文本';
      final ok = results.where((r) => r.ok).toList()
        ..sort((a, b) =>
            (a.diffRate ?? 1).compareTo(b.diffRate ?? 1));
      final eligible = ok.where((r) => r.lineDecision!.eligible).toList();
      final winner = eligible.isNotEmpty ? eligible.first : null;
      for (final r in results) {
        if (!r.ok) {
          badges[r.modelKey] = '失败';
        } else if (r == winner) {
          badges[r.modelKey] = '⭐ 最优';
        } else {
          badges[r.modelKey] =
              '差异 ${((r.diffRate ?? 1) * 100).toStringAsFixed(0)}%'
              '${r.lineDecision!.eligible ? '' : ' · 不采纳'}';
        }
      }
      final confirmedNote = results.first.referenceConfirmed &&
              !results.first.manualReference
          ? '（基准已人工确认）'
          : '';
      return CompareVerdict(
        summary: winner == null
            ? '无可采纳结果：全部模型的置信度低于 0.80 或失败'
            : '${winner.modelLabel} 最优：与$basis差异最小且可采纳$confirmedNote',
        badges: badges,
      );
    case CompareTask.charAssist:
    case CompareTask.punctAssist:
      final refEmpty = results.first.reference.trim().isEmpty;
      CompareRunResult? winner;
      for (final r in results) {
        if (r.ok && r.hitRank == 1) {
          winner = r;
          break;
        }
      }
      for (final r in results) {
        if (!r.ok) {
          badges[r.modelKey] = '失败';
        } else if (refEmpty) {
          badges[r.modelKey] = '无基准';
        } else if (r == winner) {
          badges[r.modelKey] = '⭐ 第 1 命中';
        } else {
          final rank = r.hitRank;
          badges[r.modelKey] = rank == null ? '未命中' : '✓ 第 $rank';
        }
      }
      return CompareVerdict(
        summary: refEmpty
            ? '该字当前为空，无基准可判：看候选合理性人工挑'
            : winner == null
            ? (() {
                var bestRank = 0;
                for (final r in results) {
                  final rank = r.hitRank;
                  if (rank != null && (bestRank == 0 || rank < bestRank)) {
                    bestRank = rank;
                  }
                }
                return bestRank == 0
                    ? '各模型均未把基准字「${results.first.reference.trim()}」列入候选'
                    : '无模型第 1 命中，最好排名 第 $bestRank';
              })()
            : '${winner.modelLabel} 最优：基准字「${results.first.reference.trim()}」在其候选第 1 位',
        badges: badges,
      );
    case CompareTask.boxDiagnosis:
      // 无基准：按"与多数模型结论一致"判断（问题签名 = 类型@位置 集合）。
      String signatureOf(CompareRunResult r) {
        final diag = r.boxDiagnosis!;
        if (diag.lineOk) return '无问题';
        final parts = diag.issues
            .map((i) => '${i.type.wire}@${i.pos}')
            .toSet()
            .toList();
        parts.sort();
        return parts.join(',');
      }

      final sigs = <String, int>{};
      for (final r in results.where((r) => r.ok)) {
        final sig = signatureOf(r);
        sigs[sig] = (sigs[sig] ?? 0) + 1;
      }
      String? majoritySig;
      var majorityCount = 0;
      sigs.forEach((sig, count) {
        if (count > majorityCount) {
          majorityCount = count;
          majoritySig = sig;
        }
      });
      final agreeable = majorityCount >= 2;
      for (final r in results) {
        if (!r.ok) {
          badges[r.modelKey] = '失败';
        } else if (agreeable && signatureOf(r) == majoritySig) {
          badges[r.modelKey] = '✓ 与多数一致';
        } else if (agreeable) {
          badges[r.modelKey] = '少数意见';
        } else {
          badges[r.modelKey] = '无多数可对照';
        }
      }
      final summary = results.any((r) => !r.ok)
          ? '部分模型失败，无法多数对照'
          : agreeable
          ? '$majorityCount 个模型结论一致：'
                '${majoritySig == '无问题' ? '本行框无问题' : majoritySig}'
          : '各模型结论不同且无多数，请结合行图人工判断';
      return CompareVerdict(summary: summary, badges: badges);
  }
}
