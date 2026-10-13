import 'dart:convert';
import 'dart:math' as math;

import '../models/models.dart';
import 'ai_box_review.dart'
    show
        hasSignificantBoxOverlap,
        isProtectedLine,
        kAdoptMargin,
        lineScore,
        shouldAdopt;
import 'ai_trace.dart';
import 'ollama_service.dart';
import 'python_service.dart';

/// AI 整行三步辅助引擎（读行 → 逐字对应 → 切分诊断）+ 局部修复闭环。
///
/// 一次「三步分析」= 干净整行裁图 + 逐字裁图一起发给视觉模型，模型先
/// 读出整行文字再逐字给候选与裁切判断；文本写回沿用固定 0.80 阈值与
/// 字框数量校验。发现裁切问题/漏字时触发**尾段局部重摆**：从问题字框
/// 的前一个框起始边裁到行末尾，交给后端 /segment_region 重识别，新框
/// 合并回整行（前段框原样保留），质量分裁决采纳，采纳后 AI 复核一次
/// （不再二次修复）。全部过程写进 [AiTraceRecorder] 供溯源面板回看。
/// 供整页识别（page_recognition）、编辑器手动触发、对比页共用。

/// 三步分析发送的单字图上限：超出部分不发送（模型仍可按整行图逐字
/// 输出 line_text，长行只是少了逐字裁切诊断）。对齐诊断菜单的 60 上
/// 限再收紧到一行的常见长度。
const int kAiCharImageCap = 40;

/// 单字裁图边长（白底 letterbox 正方形，px）。后端钳制 32~256。
const int kAiCharThumbSize = 224;

/// 整行裁图长边（后端上限 2048）：竖排长行给单字留 ~76px 以上。
const int kAiLineThumbMaxSide = 1536;

/// 上下文窗口：前后行各取多少字。
const int kAiContextWindow = 32;

/// AI 读出的整行/单字字符集（汉字 + 古籍句读标点），与旧整行裁决同集。
bool isAiLineChar(String ch) {
  final rune = ch.runes.isEmpty ? 0 : ch.runes.first;
  final cjk =
      (rune >= 0x3400 && rune <= 0x9FFF) || (rune >= 0xF900 && rune <= 0xFAFF);
  return cjk || isPunctuationText(ch);
}

/// 构建某行的前后行上下文（各 [kAiContextWindow] 字，仅 before/after
/// 两域——三步分析不给当前行 OCR 文本，模型必须自己从图里读）。
List<AiContextItem> buildLineContext(List<LineBlock> lines, int lineIndex) {
  final line = lines[lineIndex];
  final previous = <AiContextItem>[];
  var previousCount = 0;
  for (var i = lineIndex - 1; i >= 0 && previousCount < kAiContextWindow; i--) {
    final chars = lines[i].chars;
    for (
      var j = chars.length - 1;
      j >= 0 && previousCount < kAiContextWindow;
      j--
    ) {
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
  for (
    var i = lineIndex + 1;
    i < lines.length && followingCount < kAiContextWindow;
    i++
  ) {
    for (final c in lines[i].chars) {
      if (followingCount >= kAiContextWindow) break;
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
  return [...previous, ...following];
}

/// 取干净整行裁图（无字框叠加）。失败返回 null（调用方跳过该行）。
Future<String?> fetchCleanLineThumb(String imagePath, LineBlock line) async {
  final thumbs = await PythonService.fetchLineThumbnails(
    items: [
      LineThumbRequest(
        imagePath: imagePath,
        x: line.x,
        y: line.y,
        w: line.w,
        h: line.h,
        orientation: line.orientation,
      ),
    ],
    maxSide: kAiLineThumbMaxSide,
  );
  final t = thumbs.isEmpty ? null : thumbs.first;
  return (t == null || t.isEmpty) ? null : t;
}

/// 取按阅读序排列的单字裁图（白底 letterbox）。**全有或全无**：任何一
/// 张裁切失败都返回空列表——图片序号与字框序号必须一一对应，混入
/// null 会让模型的"第 k 张图 = k-1 号字框"映射错位；此时退化为仅整行
/// 图模式（模型仍可输出 line_text，只是没有逐字裁切诊断）。
Future<List<String>> fetchCharThumbImages(
  String imagePath,
  List<CharBlock> sortedChars,
) async {
  final targets = sortedChars.take(kAiCharImageCap).toList();
  if (targets.isEmpty) return const [];
  try {
    final thumbs = await PythonService.fetchCharThumbnails(
      items: [
        for (final c in targets)
          (imagePath: imagePath, x: c.x, y: c.y, w: c.w, h: c.h),
      ],
      size: kAiCharThumbSize,
    );
    if (thumbs.length != targets.length ||
        thumbs.any((t) => t == null || t.isEmpty)) {
      return const [];
    }
    return [for (final t in thumbs) t!];
  } catch (_) {
    return const [];
  }
}

/// 写回结果：门槛逐项判定 + 逐字 diff + 是否写回文字。
class AiApplyResult {
  const AiApplyResult({
    required this.textApplied,
    required this.path,
    required this.checks,
    required this.writes,
    required this.outcome,
  });

  /// AI 文字是否覆盖了整行（items 逐字或 line_text rune 回退）。
  final bool textApplied;

  /// items / runes / none。
  final String path;
  final List<AiTraceCheck> checks;
  final List<AiTraceCharWrite> writes;
  final String outcome;
}

/// 把三步分析结果写回一行（就地修改字块）。
///
/// 文本门禁与旧整行裁决完全一致：整行 confidence ≥ 0.80 且字框数量、
/// 序号连续性、line_text == items 拼接全部通过才逐字写回；items 不完整
/// 但 line_text 与字框一一对应时按 rune 回退。**候选并入与切分标记属于
/// advisory：只要 order 落在字框范围内就写，不受文本门禁限制。**
AiApplyResult applyDecisionToLine(
  LineBlock line,
  List<CharBlock> targetChars,
  AiLineDecision decision,
) {
  final ordered = List<AiLineItem>.from(decision.items)
    ..sort((a, b) => a.order.compareTo(b.order));
  final n = targetChars.length;

  var contiguous = ordered.length == n;
  if (contiguous) {
    for (var i = 0; i < ordered.length; i++) {
      if (ordered[i].order != i) {
        contiguous = false;
        break;
      }
    }
  }
  final joined = ordered.map((e) => e.text).join();
  final itemsPath =
      decision.eligible &&
      contiguous &&
      ordered.isNotEmpty &&
      ordered.every((item) => item.confidence >= 0.80) &&
      decision.lineText == joined;

  final runes = decision.lineText.runes.toList();
  final runesPath =
      !itemsPath &&
      decision.eligible &&
      runes.length == n &&
      runes.every((rune) => isAiLineChar(String.fromCharCode(rune)));

  final checks = <AiTraceCheck>[
    AiTraceCheck(
      name: '整行置信度 ≥ 0.80',
      pass: decision.confidence >= 0.80 && decision.lineText.isNotEmpty,
      detail: '置信度 ${decision.confidence.toStringAsFixed(2)}',
    ),
    AiTraceCheck(
      name: 'items 数量 = 字框数',
      pass: ordered.length == n,
      detail: 'items ${ordered.length} / 框 $n',
    ),
    AiTraceCheck(
      name: '序号从 0 连续递增',
      pass: contiguous,
      detail: contiguous ? '连续' : '存在跳号/乱序',
    ),
    AiTraceCheck(
      name: '逐字置信度全部 ≥ 0.80',
      pass: ordered.isNotEmpty && ordered.every((i) => i.confidence >= 0.80),
      detail: ordered.isEmpty
          ? '无 items'
          : '最低 ${ordered.map((i) => i.confidence).reduce(math.min).toStringAsFixed(2)}',
    ),
    AiTraceCheck(
      name: 'line_text = items 拼接',
      pass: ordered.isNotEmpty && decision.lineText == joined,
      detail: decision.lineText == joined ? '一致' : '不一致',
    ),
    AiTraceCheck(
      name: 'line_text 与字框一一对应（rune 回退）',
      pass: runesPath,
      detail: '${runes.length} 字 vs $n 框',
    ),
  ];

  final byOrder = <int, AiLineItem>{
    for (final item in ordered) item.order: item,
  };
  final writes = <AiTraceCharWrite>[];
  for (var i = 0; i < n; i++) {
    final char = targetChars[i];
    final oldText = char.text;
    final item = byOrder[i];
    final added = <String>[];
    String? boxIssue;
    var newText = oldText;
    var aiApplied = false;

    // advisory 写入：候选并入 + 切分标记（不受文本门禁限制）。
    if (item != null) {
      final existing = char.candidates.map((c) => c.text).toSet();
      final additions = <CharCandidate>[];
      for (final cand in item.candidates) {
        if (existing.contains(cand.text)) continue;
        additions.add(
          CharCandidate(text: cand.text, score: cand.score, ai: true),
        );
        existing.add(cand.text);
        added.add(cand.text);
      }
      if (additions.isNotEmpty) {
        // 整列表替换而非原地 add：字块的 candidates 可能是不可变列表
        // （旧对象/测试夹具的 const []），原地加会抛
        // "Cannot add to an unmodifiable list"。
        char.candidates = [...char.candidates, ...additions];
      }
      char
        ..aiText = item.text
        ..aiConfidence = item.confidence
        ..aiReason = item.reason
        ..aiUsed = false
        ..aiBoxIssue = item.cropIssue
        ..aiBoxNote = item.cropIssue == null ? null : item.cropNote;
      boxIssue = item.cropIssue;
    }

    if (itemsPath) {
      char
        ..aiUsed = true
        ..text = item!.text
        ..source = 'kraken+ai-line';
      newText = item.text;
      aiApplied = true;
    } else if (runesPath) {
      final t = String.fromCharCode(runes[i]);
      char
        ..aiUsed = true
        ..aiText = t
        ..aiConfidence = decision.confidence
        ..aiReason = '整行读出（逐字项不完整，按整行置信度采用）'
        ..text = t
        ..source = 'kraken+ai-line';
      newText = t;
      aiApplied = true;
    }
    if (aiApplied &&
        oldText.isNotEmpty &&
        oldText != newText &&
        !char.candidates.any((c) => c.text == oldText)) {
      // 原 OCR 文本保底进候选（用户可一键换回）；同样用替换而非 add。
      char.candidates = [
        ...char.candidates,
        CharCandidate(text: oldText, score: char.conf ?? 0),
      ];
    }
    if (item != null || aiApplied) {
      writes.add(
        AiTraceCharWrite(
          order: i,
          oldText: oldText,
          newText: newText,
          addedCandidates: added,
          boxIssue: boxIssue,
          aiApplied: aiApplied,
        ),
      );
    }
  }
  if (itemsPath || runesPath) {
    line.text = targetChars.map((c) => c.text).join();
  }

  final outcome = itemsPath
      ? '已采纳 AI 文字（逐字项通过全部校验）'
      : runesPath
      ? '已采纳 AI 文字（line_text 逐字回退）'
      : '文本未达采纳门槛，仅并入候选与切分标记（保留 OCR）';
  return AiApplyResult(
    textApplied: itemsPath || runesPath,
    path: itemsPath ? 'items' : (runesPath ? 'runes' : 'none'),
    checks: checks,
    writes: writes,
    outcome: outcome,
  );
}

/// 修复触发判定：首个显式裁切标记优先；否则 eligible 且 AI 读出字数
/// 多于字框（漏字信号）时，取首个文字分歧位置的前一框。
({int start, String type, String note})? repairTriggerOf(
  List<CharBlock> sortedChars,
  AiLineDecision decision,
) {
  final ordered = List<AiLineItem>.from(decision.items)
    ..sort((a, b) => a.order.compareTo(b.order));
  for (final item in ordered) {
    if (item.cropIssue != null &&
        item.order >= 0 &&
        item.order < sortedChars.length) {
      return (
        start: item.order,
        type: item.cropIssue!,
        note: item.cropNote.isEmpty ? 'AI 标记裁切问题' : item.cropNote,
      );
    }
  }
  if (decision.eligible) {
    final runes = decision.lineText.runes.toList();
    if (runes.length > sortedChars.length) {
      var d = 0;
      while (d < sortedChars.length &&
          sortedChars[d].text == String.fromCharCode(runes[d])) {
        d++;
      }
      return (
        start: math.max(0, d - 1),
        type: 'count_mismatch',
        note:
            'AI 读出 ${runes.length} 字 > 框数 ${sortedChars.length}'
            '（分歧于第 $d 字，疑似漏字）',
      );
    }
  }
  return null;
}

/// 决策的溯源快照（decisionJson 用）。
String decisionSnapshotJson(AiLineDecision d) => jsonEncode({
  'line_text': d.lineText,
  'confidence': d.confidence,
  'items': [
    for (final it in d.items)
      {
        'order': it.order,
        'text': it.text,
        'confidence': it.confidence,
        'punctuation': it.punctuation,
        if (it.candidates.isNotEmpty)
          'candidates': [
            for (final c in it.candidates) {'text': c.text, 'score': c.score},
          ],
        if (it.cropIssue != null) 'crop_issue': it.cropIssue,
        if (it.cropNote.isNotEmpty) 'note': it.cropNote,
      },
  ],
});

/// 尾段矩形：按行内阅读方向取「anchor 字框 → 行末尾」。默认竖排从上
/// 到下 / 横排从左到右；[horizontalDir]='rtl' 时横排行末尾在**左边**、
/// [verticalDir]='btt' 时竖排列末尾在**上边**——方向反了会裁到行首/邻
/// 列，合并回来的框与保留段大面积重叠（实测"重复出现大量重叠的单行
/// 识别框"的根源）。k=0（或 anchor 缺失）时为整行矩形。
({int x, int y, int w, int h}) tailRectOf(
  LineBlock line,
  List<CharBlock> sorted,
  int k, {
  String horizontalDir = 'ltr',
  String verticalDir = 'ttb',
}) {
  final anchor = k > 0 && k - 1 < sorted.length ? sorted[k - 1] : null;
  if (line.orientation == 'horizontal') {
    if (horizontalDir == 'rtl') {
      // 从右到左：行末尾在左边，区域 = 行左边缘 → anchor 右边缘
      // （anchor 本身及其后阅读方向上的所有字框）。
      final x1 = anchor == null ? line.x : anchor.x + anchor.w;
      final w = x1 - line.x;
      return (x: line.x, y: line.y, w: w < 0 ? 0 : w, h: line.h);
    }
    final x0 = anchor?.x ?? line.x;
    return (x: x0, y: line.y, w: line.x + line.w - x0, h: line.h);
  }
  if (verticalDir == 'btt') {
    // 从下到上：行末尾在上边，区域 = 行上边缘 → anchor 底边缘。
    final y1 = anchor == null ? line.y : anchor.y + anchor.h;
    final h = y1 - line.y;
    return (x: line.x, y: line.y, w: line.w, h: h < 0 ? 0 : h);
  }
  final y0 = anchor?.y ?? line.y;
  return (x: line.x, y: y0, w: line.w, h: line.y + line.h - y0);
}

/// 重摆尾段是否与原尾段实质相同（框逐个差 ≤2px 且文字一致）。
bool tailMateriallySame(
  List<CharBlock> oldSorted,
  int k,
  List<CharBlock> newTail,
) {
  final oldTail = k > 0 ? oldSorted.sublist(k - 1) : oldSorted;
  if (oldTail.length != newTail.length) return false;
  for (var i = 0; i < oldTail.length; i++) {
    final a = oldTail[i], b = newTail[i];
    if ((a.x - b.x).abs() > 2 ||
        (a.y - b.y).abs() > 2 ||
        (a.w - b.w).abs() > 2 ||
        (a.h - b.h).abs() > 2) {
      return false;
    }
    if (a.text != b.text) return false;
  }
  return true;
}

/// 尾段重摆返回的新字块按阅读序摊平（后端可能把尾段拆成多行/子列）。
List<CharBlock> flattenSegmentedChars(List<LineBlock> newLines) {
  final out = <CharBlock>[];
  for (final l in newLines) {
    final chars = List<CharBlock>.from(l.chars)
      ..sort((a, b) => a.order.compareTo(b.order));
    out.addAll(chars);
  }
  return out;
}

/// 一次三步分析 + 写回 +（可选）修复触发的完整流程。
///
/// [stage] 为 assist（首次分析）或 reverify（修复后的复核，不再修复）。
/// 永不抛异常：失败记进溯源与日志后返回，识别主流程继续下一行。
/// [lineThumbOverride] 为行条裁图注入点（对比页/测试替换用），默认走
/// Python 后端干净裁图。
Future<void> runLineAssist({
  required LineBlock line,
  required List<LineBlock> lines,
  required int lineIndex,
  required String imagePath,
  required ProjectSettings settings,
  required OllamaSettings ollama,
  AiTraceRecorder? recorder,
  AiTraceStage stage = AiTraceStage.assist,
  bool allowRepair = true,
  void Function(String message)? log,
  Future<String?> Function(LineBlock line)? lineThumbOverride,

  /// false = 批量链路（整行裁决的行请求走后台许可，编辑器手动操作优
  /// 先）；编辑器手动单行重识别保持默认 true。
  bool interactive = true,
}) async {
  final sorted = List<CharBlock>.from(line.chars)
    ..sort((a, b) => a.order.compareTo(b.order));
  if (sorted.isEmpty) return;
  final model = ollama.activeVisionModel.isNotEmpty
      ? ollama.activeVisionModel
      : ollama.activeTextModel;
  void fail(String error) {
    recorder?.add(
      AiTraceEntry(
        lineId: line.id,
        stage: stage,
        at: DateTime.now(),
        model: model,
        provider: ollama.provider.wire,
        outcome: '阶段失败',
        outcomePass: false,
        error: error,
      ),
    );
  }

  try {
    final lineThumb = lineThumbOverride != null
        ? await lineThumbOverride(line)
        : await fetchCleanLineThumb(imagePath, line);
    if (lineThumb == null) {
      log?.call('${_stageTag(stage)} ${line.id} 行条裁图失败，跳过');
      fail('行条裁图失败（后端不可用或行框无效）');
      return;
    }
    final charThumbs = await fetchCharThumbImages(imagePath, sorted);
    final trace = OllamaTrace();
    final context = buildLineContext(lines, lineIndex);
    final decision = await OllamaService.analyzeLine(
      settings: ollama,
      lineImageBase64: lineThumb,
      charImages: charThumbs,
      context: context,
      orientation: line.orientation,
      horizontalDir: settings.horizontalDir,
      verticalDir: settings.verticalDir,
      layoutRole: line.layoutRole,
      wantThinking: ollama.enableAiThinking,
      trace: trace,
      interactive: interactive,
    );
    final apply = applyDecisionToLine(line, sorted, decision);
    // 落盘 AI 看到的所有图（行图 + 逐字图），写进溯源条目。
    final images = <AiTraceImage>[];
    if (recorder != null) {
      final lineFile = await recorder.saveImage(lineThumb, '整行图');
      if (lineFile != null) {
        images.add(AiTraceImage(file: lineFile, label: '整行图（无叠加）'));
      }
      for (var i = 0; i < charThumbs.length; i++) {
        final f = await recorder.saveImage(charThumbs[i], '$i 号字框');
        if (f != null) {
          images.add(AiTraceImage(file: f, label: '$i 号字框裁图'));
        }
      }
    }
    recorder?.add(
      AiTraceEntry(
        lineId: line.id,
        stage: stage,
        at: DateTime.now(),
        model: trace.model,
        provider: ollama.provider.wire,
        elapsedMs: trace.elapsedMs,
        images: images,
        prompt: trace.prompt,
        thinking: trace.thinking,
        rawContent: trace.rawContent,
        decisionJson: decisionSnapshotJson(decision),
        checks: apply.checks,
        outcome: apply.outcome,
        outcomePass: apply.textApplied,
        writes: apply.writes,
      ),
    );
    log?.call(
      '${_stageTag(stage)} ${line.id} '
      '${apply.textApplied ? "已采纳 AI（${apply.path}）" : "保留 OCR：${apply.outcome}"}',
    );
    if (allowRepair) {
      final trigger = repairTriggerOf(sorted, decision);
      if (trigger != null) {
        await runTailRepair(
          line: line,
          lines: lines,
          lineIndex: lineIndex,
          imagePath: imagePath,
          settings: settings,
          ollama: ollama,
          recorder: recorder,
          startOrder: trigger.start,
          issueType: trigger.type,
          note: trigger.note,
          log: log,
        );
      }
    }
  } on OllamaException catch (e) {
    log?.call('${_stageTag(stage)} ${line.id} 失败：${e.message}');
    fail(e.message);
  } catch (e) {
    log?.call('${_stageTag(stage)} ${line.id} 失败：$e');
    fail(e.toString());
  }
}

String _stageTag(AiTraceStage stage) => switch (stage) {
  AiTraceStage.assist => '[AI整行三步]',
  AiTraceStage.reverify => '[AI复核]',
  AiTraceStage.repair => '[AI局部修复]',
};

/// 尾段局部重摆修复的结果摘要（编辑器手动触发时给提示用）。
class AiRepairOutcome {
  const AiRepairOutcome({
    required this.attempted,
    required this.adopted,
    required this.prefixLength,
    required this.mergedCount,
    this.reason = '',
    this.error,
  });

  final bool attempted;
  final bool adopted;

  /// 保留未动的前段字数 / 采纳后的整行字数。
  final int prefixLength;
  final int mergedCount;
  final String reason;
  final String? error;
}

/// 尾段局部重摆修复：问题框前一框起始边 → 行末尾，交给后端重识别，
/// 合并回整行，质量分裁决，采纳后 AI 复核一次。就地更新 [line]（仅采
/// 纳时）。永不抛异常。
Future<AiRepairOutcome> runTailRepair({
  required LineBlock line,
  required List<LineBlock> lines,
  required int lineIndex,
  required String imagePath,
  required ProjectSettings settings,
  required OllamaSettings ollama,
  AiTraceRecorder? recorder,
  required int startOrder,
  required String issueType,
  required String note,
  bool allowReverify = true,
  void Function(String message)? log,
}) async {
  final sorted = List<CharBlock>.from(line.chars)
    ..sort((a, b) => a.order.compareTo(b.order));
  if (sorted.isEmpty) {
    return const AiRepairOutcome(
      attempted: false,
      adopted: false,
      prefixLength: 0,
      mergedCount: 0,
      reason: '行内没有字框，无可修复',
    );
  }
  // 保护行（用户手工调过框/已确认）不自动重摆——与「AI 检查识别框」同规。
  if (isProtectedLine(line)) {
    log?.call('[AI局部修复] ${line.id} 用户已校对的行，跳过修复');
    recorder?.add(
      AiTraceEntry(
        lineId: line.id,
        stage: AiTraceStage.repair,
        at: DateTime.now(),
        model: '',
        provider: ollama.provider.wire,
        outcome: '用户已校对的行，跳过修复',
        outcomePass: false,
        repair: AiTraceRepair(
          trigger: note,
          issueType: issueType,
          startOrder: startOrder,
          tailRect: const {},
          oldTailCount: 0,
          newChars: const [],
          beforeScore: 0,
          afterScore: 0,
          adopted: false,
          reason: '保护行（手工调整/已确认），不允许自动重摆',
        ),
      ),
    );
    return const AiRepairOutcome(
      attempted: false,
      adopted: false,
      prefixLength: 0,
      mergedCount: 0,
      reason: '用户已校对的行，不允许自动重摆',
    );
  }
  final k = startOrder.clamp(0, sorted.length - 1);
  final rect = tailRectOf(
    line,
    sorted,
    k,
    horizontalDir: settings.horizontalDir,
    verticalDir: settings.verticalDir,
  );
  final prefixLen = k > 0 ? k - 1 : 0;
  final oldTailCount = sorted.length - prefixLen;
  final expectExtra =
      issueType == 'char_merged' || issueType == 'count_mismatch' ? 1 : 0;
  final expected = oldTailCount + expectExtra;
  final stub = LineBlock(
    id: line.id,
    x: rect.x,
    y: rect.y,
    w: rect.w,
    h: rect.h,
    lineNo: line.lineNo,
    orientation: line.orientation,
  );
  final model = ollama.activeVisionModel.isNotEmpty
      ? ollama.activeVisionModel
      : ollama.activeTextModel;
  final sw = Stopwatch()..start();
  try {
    final newLines = await PythonService.segmentRegion(
      imagePath: imagePath,
      lineStub: stub,
      settings: settings,
      expectedCharCount: expected,
    );
    final newTailChars = flattenSegmentedChars(newLines);
    final merged = <CharBlock>[
      ...sorted.sublist(0, prefixLen),
      ...newTailChars,
    ];
    for (var i = 0; i < merged.length; i++) {
      merged[i]
        ..order = i
        ..lineId = line.id
        ..aiBoxIssue = null
        ..aiBoxNote = null;
    }
    final before = lineScore(sorted, line.orientation);
    final after = lineScore(merged, line.orientation);
    final same = tailMateriallySame(sorted, k, newTailChars);
    // 结构守卫：尾段被后端拆成多行（疑似含并排子列/邻列——尾段理应只
    // 有一行的结构），或新旧框大面积互叠（重摆区域选错的典型信号），
    // 都不允许自动合并——强行摊平进一行就是"大量重叠的单行识别框"。
    final multiLine = newLines.length > 1;
    final overlapped = hasSignificantBoxOverlap(merged);
    final adopt =
        !same &&
        !multiLine &&
        !overlapped &&
        shouldAdopt(sorted, merged, line.orientation, margin: kAdoptMargin);
    if (adopt) {
      // 重摆新字块换唯一 id（沿用编辑器 c_时间戳 序号 约定），避免与
      // 原页面上后端批量生成的同名字块冲突。
      final stamp = DateTime.now().microsecondsSinceEpoch;
      for (var i = prefixLen; i < merged.length; i++) {
        merged[i].id = 'c_${stamp}_$i';
      }
      line
        ..chars = merged
        ..text = merged.map((c) => c.text).join();
    }
    final reason = same
        ? '重摆复检结果与原框相同，保持原样'
        : multiLine
        ? '后端把尾段拆成了 ${newLines.length} 行（疑似并排子列/邻列），放弃自动合并'
        : overlapped
        ? '重摆框与保留框大面积重叠（重摆区域可能选错），保持原样'
        : adopt
        ? '质量分提升（${before.toStringAsFixed(2)} → ${after.toStringAsFixed(2)}），已采纳'
        : '质量分未提升（${before.toStringAsFixed(2)} → ${after.toStringAsFixed(2)}），保持原样';
    log?.call('[AI局部修复] ${line.id} $reason');
    recorder?.add(
      AiTraceEntry(
        lineId: line.id,
        stage: AiTraceStage.repair,
        at: DateTime.now(),
        model: model,
        provider: ollama.provider.wire,
        elapsedMs: sw.elapsedMilliseconds,
        outcome: reason,
        outcomePass: adopt,
        repair: AiTraceRepair(
          trigger: '$k 号字框 $issueType：$note',
          issueType: issueType,
          startOrder: k,
          tailRect: {'x': rect.x, 'y': rect.y, 'w': rect.w, 'h': rect.h},
          oldTailCount: oldTailCount,
          newChars: [
            for (final c in newTailChars)
              {
                'x': c.x,
                'y': c.y,
                'w': c.w,
                'h': c.h,
                'text': c.text,
                'conf': c.conf,
              },
          ],
          beforeScore: before,
          afterScore: after,
          adopted: adopt,
          reason: reason,
          backendLines: newLines.length,
        ),
      ),
    );
    if (adopt && allowReverify && line.chars.isNotEmpty) {
      // 复核：对修复后的行再跑一次三步分析（stage=reverify，不再修复）。
      await runLineAssist(
        line: line,
        lines: lines,
        lineIndex: lineIndex,
        imagePath: imagePath,
        settings: settings,
        ollama: ollama,
        recorder: recorder,
        stage: AiTraceStage.reverify,
        allowRepair: false,
        log: log,
      );
    }
    return AiRepairOutcome(
      attempted: true,
      adopted: adopt,
      prefixLength: prefixLen,
      mergedCount: merged.length,
      reason: reason,
    );
  } catch (e) {
    log?.call('[AI局部修复] ${line.id} 失败：$e');
    recorder?.add(
      AiTraceEntry(
        lineId: line.id,
        stage: AiTraceStage.repair,
        at: DateTime.now(),
        model: model,
        provider: ollama.provider.wire,
        elapsedMs: sw.elapsedMilliseconds,
        outcome: '修复失败',
        outcomePass: false,
        error: e.toString(),
        repair: AiTraceRepair(
          trigger: '$k 号字框 $issueType：$note',
          issueType: issueType,
          startOrder: k,
          tailRect: {'x': rect.x, 'y': rect.y, 'w': rect.w, 'h': rect.h},
          oldTailCount: oldTailCount,
          newChars: const [],
          beforeScore: 0,
          afterScore: 0,
          adopted: false,
          reason: '后端重摆失败',
        ),
      ),
    );
    return AiRepairOutcome(
      attempted: true,
      adopted: false,
      prefixLength: prefixLen,
      mergedCount: sorted.length,
      reason: '后端重摆失败',
      error: e.toString(),
    );
  } finally {
    sw.stop();
  }
}
