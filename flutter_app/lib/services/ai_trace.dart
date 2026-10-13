import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'isolate_codec.dart';

/// AI 辅助全流程溯源：识别运行中每行每阶段（三步分析 / 局部修复 /
/// 复核）的完整记录——AI 看到的所有图、完整 prompt、思维链、原始
/// 返回、解析判定、门槛逐项 pass/fail、写入 diff、修复前后对比。
///
/// 持久化约定：每页只保留**最后一次**识别运行的记录。JSON 存
/// `{projectDir}/ai_trace/{pageId}.json`，图片存 `{projectDir}/ai_trace/
/// {pageId}/img_XXX.png`；每次运行首次落图时清空旧图目录，flush 时覆盖
/// 写 JSON。独立于 `annotations/` 目录，不会污染标注文件遍历。

/// 溯源条目对应的流程阶段。
enum AiTraceStage {
  /// 三步分析（读行 → 逐字对应 → 切分诊断）。
  assist('assist'),

  /// 局部重摆修复（AI 标记 → 尾段重识别 → 合并 → 裁决）。
  repair('repair'),

  /// 修复采纳后的 AI 复核（再看一次修复后的行）。
  reverify('reverify');

  const AiTraceStage(this.wire);

  /// 持久化标识。
  final String wire;

  static AiTraceStage fromWire(String? s) => AiTraceStage.values.firstWhere(
    (v) => v.wire == s,
    orElse: () => AiTraceStage.assist,
  );

  /// 面板显示名。
  String get label => switch (this) {
    AiTraceStage.assist => '三步分析',
    AiTraceStage.repair => '局部修复',
    AiTraceStage.reverify => 'AI 复核',
  };
}

/// 一张随 prompt 发送的图（文件名 + 说明标签）。
class AiTraceImage {
  const AiTraceImage({required this.file, required this.label});

  /// 图片目录内的文件名（img_000.png）。
  final String file;

  /// 说明（整行图 / 0号字框 / …）。
  final String label;

  Map<String, dynamic> toJson() => {'file': file, 'label': label};

  static AiTraceImage fromJson(Map<String, dynamic> j) => AiTraceImage(
    file: j['file']?.toString() ?? '',
    label: j['label']?.toString() ?? '',
  );
}

/// 一条门槛检查（面板逐项显示 ✓/✗）。
class AiTraceCheck {
  const AiTraceCheck({required this.name, required this.pass, this.detail = ''});

  /// 检查名（如「整行置信度 ≥ 0.80」）。
  final String name;
  final bool pass;

  /// 实际值说明（如「0.92」）。
  final String detail;

  Map<String, dynamic> toJson() => {'name': name, 'pass': pass, 'detail': detail};

  static AiTraceCheck fromJson(Map<String, dynamic> j) => AiTraceCheck(
    name: j['name']?.toString() ?? '',
    pass: j['pass'] == true,
    detail: j['detail']?.toString() ?? '',
  );
}

/// 逐字写入 diff 的一条记录。
class AiTraceCharWrite {
  const AiTraceCharWrite({
    required this.order,
    required this.oldText,
    required this.newText,
    this.addedCandidates = const [],
    this.boxIssue,
    this.aiApplied = false,
  });

  final int order;

  /// 写入前文字（空 = 原本无字）。
  final String oldText;

  /// 写入后文字；仅标记（文本未采纳）时与 oldText 相同。
  final String newText;

  /// 本次并入的 AI 候选（文字列表）。
  final List<String> addedCandidates;

  /// 标记的切分问题（char_clipped 等）；null = 未标记。
  final String? boxIssue;

  /// 文字是否真正被 AI 结果覆盖（false = 只并入了候选/标记）。
  final bool aiApplied;

  Map<String, dynamic> toJson() => {
    'order': order,
    'old': oldText,
    'new': newText,
    if (addedCandidates.isNotEmpty) 'added': addedCandidates,
    if (boxIssue != null) 'box_issue': boxIssue,
    if (aiApplied) 'ai_applied': true,
  };

  static AiTraceCharWrite fromJson(Map<String, dynamic> j) => AiTraceCharWrite(
    order: (j['order'] as num?)?.toInt() ?? 0,
    oldText: j['old']?.toString() ?? '',
    newText: j['new']?.toString() ?? '',
    addedCandidates: [
      for (final v in (j['added'] as List? ?? const [])) v.toString(),
    ],
    boxIssue: j['box_issue'] as String?,
    aiApplied: j['ai_applied'] == true,
  );
}

/// 一次页面识别运行的完整溯源（内存累积，[AiTraceRecorder.flush] 落盘）。
class AiTraceRun {
  AiTraceRun({
    required this.pageId,
    required this.imagePath,
    required this.model,
    required this.provider,
    DateTime? startedAt,
    List<AiTraceEntry>? entries,
  }) : startedAt = startedAt ?? DateTime.now(),
       entries = entries ?? [];

  final String pageId;
  final String imagePath;

  /// 本次运行实际使用的模型与推理来源（local / external）。
  final String model;
  final String provider;
  DateTime startedAt;
  final List<AiTraceEntry> entries;

  Map<String, dynamic> toJson() => {
    'page_id': pageId,
    'image_path': imagePath,
    'model': model,
    'provider': provider,
    'started_at': startedAt.toIso8601String(),
    'entries': entries.map((e) => e.toJson()).toList(),
  };

  static AiTraceRun? fromJson(Map<String, dynamic> j) {
    final pageId = j['page_id']?.toString() ?? '';
    if (pageId.isEmpty) return null;
    final rawEntries = j['entries'];
    return AiTraceRun(
      pageId: pageId,
      imagePath: j['image_path']?.toString() ?? '',
      model: j['model']?.toString() ?? '',
      provider: j['provider']?.toString() ?? '',
      startedAt: DateTime.tryParse(j['started_at']?.toString() ?? ''),
      entries: [
        if (rawEntries is List)
          for (final e in rawEntries)
            if (e is Map) AiTraceEntry.fromJson(Map<String, dynamic>.from(e)),
      ],
    );
  }
}

/// 一个行级阶段记录（一次 AI 调用或一次修复动作）。
class AiTraceEntry {
  AiTraceEntry({
    required this.lineId,
    required this.stage,
    required this.at,
    required this.model,
    required this.provider,
    this.elapsedMs = 0,
    this.images = const [],
    this.prompt = '',
    this.thinking = '',
    this.rawContent = '',
    this.decisionJson = '',
    this.checks = const [],
    this.outcome = '',
    this.outcomePass = false,
    this.writes = const [],
    this.error,
    this.repair,
  });

  final String lineId;
  final AiTraceStage stage;
  final DateTime at;
  final String model;
  final String provider;
  final int elapsedMs;

  /// AI 看到的图（文件引用 + 标签）；修复阶段为尾段相关图。
  final List<AiTraceImage> images;

  /// 完整 prompt / 思维链 / 原始返回。
  final String prompt;
  final String thinking;
  final String rawContent;

  /// 解析后的决策（line_text / confidence / items 含候选与切分判断），
  /// 已序列化为 JSON 字符串；无 AI 调用的阶段为空。
  final String decisionJson;

  /// 门槛逐项判定。
  final List<AiTraceCheck> checks;

  /// 阶段结论（人话），outcomePass = 该阶段是否达成目的。
  final String outcome;
  final bool outcomePass;

  /// 写入 diff。
  final List<AiTraceCharWrite> writes;

  /// 阶段失败的异常信息（无失败为 null）。
  final String? error;

  /// repair 阶段专属详情；其他阶段为 null。
  final AiTraceRepair? repair;

  Map<String, dynamic> toJson() => {
    'line_id': lineId,
    'stage': stage.wire,
    'at': at.toIso8601String(),
    'model': model,
    'provider': provider,
    'elapsed_ms': elapsedMs,
    if (images.isNotEmpty) 'images': images.map((e) => e.toJson()).toList(),
    if (prompt.isNotEmpty) 'prompt': prompt,
    if (thinking.isNotEmpty) 'thinking': thinking,
    if (rawContent.isNotEmpty) 'raw': rawContent,
    if (decisionJson.isNotEmpty) 'decision': decisionJson,
    if (checks.isNotEmpty) 'checks': checks.map((e) => e.toJson()).toList(),
    'outcome': outcome,
    'outcome_pass': outcomePass,
    if (writes.isNotEmpty) 'writes': writes.map((e) => e.toJson()).toList(),
    if (error != null) 'error': error,
    if (repair != null) 'repair': repair!.toJson(),
  };

  static AiTraceEntry fromJson(Map<String, dynamic> j) => AiTraceEntry(
    lineId: j['line_id']?.toString() ?? '',
    stage: AiTraceStage.fromWire(j['stage']?.toString()),
    at: DateTime.tryParse(j['at']?.toString() ?? '') ?? DateTime.now(),
    model: j['model']?.toString() ?? '',
    provider: j['provider']?.toString() ?? '',
    elapsedMs: (j['elapsed_ms'] as num?)?.toInt() ?? 0,
    images: [
      if (j['images'] is List)
        for (final e in j['images'] as List)
          if (e is Map) AiTraceImage.fromJson(Map<String, dynamic>.from(e)),
    ],
    prompt: j['prompt']?.toString() ?? '',
    thinking: j['thinking']?.toString() ?? '',
    rawContent: j['raw']?.toString() ?? '',
    decisionJson: j['decision']?.toString() ?? '',
    checks: [
      if (j['checks'] is List)
        for (final e in j['checks'] as List)
          if (e is Map) AiTraceCheck.fromJson(Map<String, dynamic>.from(e)),
    ],
    outcome: j['outcome']?.toString() ?? '',
    outcomePass: j['outcome_pass'] == true,
    writes: [
      if (j['writes'] is List)
        for (final e in j['writes'] as List)
          if (e is Map) AiTraceCharWrite.fromJson(Map<String, dynamic>.from(e)),
    ],
    error: j['error'] as String?,
    repair: j['repair'] is Map
        ? AiTraceRepair.fromJson(Map<String, dynamic>.from(j['repair'] as Map))
        : null,
  );
}

/// 局部修复阶段的详情：触发、尾段矩形、后端重摆结果、裁决与合并。
class AiTraceRepair {
  const AiTraceRepair({
    required this.trigger,
    required this.issueType,
    required this.startOrder,
    required this.tailRect,
    required this.oldTailCount,
    required this.newChars,
    required this.beforeScore,
    required this.afterScore,
    required this.adopted,
    required this.reason,
    this.backendLines = 0,
    this.debugTrace = const [],
  });

  /// 触发来源（如「3 号字框 char_clipped：墨迹贴边」）。
  final String trigger;

  /// 问题类型（char_clipped / char_merged / char_extra_ink / count_mismatch）。
  final String issueType;

  /// 尾段起始字框序号（从该框起重摆；0 = 整行重摆）。
  final int startOrder;

  /// 尾段矩形（页面绝对坐标）。
  final Map<String, int> tailRect;

  /// 尾段旧字框数 / 重摆后新字框数。
  final int oldTailCount;

  /// 重摆返回的新字框（绝对坐标 + 识别文字），面板画前后对比。
  final List<Map<String, dynamic>> newChars;

  /// 整行前后质量分（lineScore 口径）。
  final double beforeScore;
  final double afterScore;

  /// 是否采纳（合并回行）。
  final bool adopted;

  /// 裁决结论（人话）。
  final String reason;

  /// 后端返回的行数（>1 = 尾段被拆成了多行/子列）。
  final int backendLines;

  /// 后端 debug_trace 摘录。
  final List<String> debugTrace;

  Map<String, dynamic> toJson() => {
    'trigger': trigger,
    'issue_type': issueType,
    'start_order': startOrder,
    'tail_rect': tailRect,
    'old_tail_count': oldTailCount,
    'new_chars': newChars,
    'before_score': beforeScore,
    'after_score': afterScore,
    'adopted': adopted,
    'reason': reason,
    'backend_lines': backendLines,
    if (debugTrace.isNotEmpty) 'debug_trace': debugTrace,
  };

  static AiTraceRepair fromJson(Map<String, dynamic> j) {
    final tr = j['tail_rect'];
    int trVal(String key) =>
        (tr is Map ? (tr[key] as num?) : null)?.toInt() ?? 0;
    return AiTraceRepair(
      trigger: j['trigger']?.toString() ?? '',
      issueType: j['issue_type']?.toString() ?? '',
      startOrder: (j['start_order'] as num?)?.toInt() ?? 0,
      tailRect: {
        'x': trVal('x'),
        'y': trVal('y'),
        'w': trVal('w'),
        'h': trVal('h'),
      },
      oldTailCount: (j['old_tail_count'] as num?)?.toInt() ?? 0,
      newChars: [
        if (j['new_chars'] is List)
          for (final e in j['new_chars'] as List)
            if (e is Map) Map<String, dynamic>.from(e),
      ],
      beforeScore: (j['before_score'] as num?)?.toDouble() ?? 0,
      afterScore: (j['after_score'] as num?)?.toDouble() ?? 0,
      adopted: j['adopted'] == true,
      reason: j['reason']?.toString() ?? '',
      backendLines: (j['backend_lines'] as num?)?.toInt() ?? 0,
      debugTrace: [
        if (j['debug_trace'] is List)
          for (final e in j['debug_trace'] as List) e.toString(),
      ],
    );
  }
}

/// 一次识别运行的溯源记录器：累积条目、落盘图片、flush 覆盖写 JSON。
/// [projectDir] 为 null 时是**内存模式**（对比页用）：图片不落盘，存
/// 在内存映射里供结果页直接渲染，flush 为空操作。
class AiTraceRecorder {
  AiTraceRecorder({
    String? projectDir,
    required this.pageId,
    required this.imagePath,
    required String model,
    required String provider,
  }) : projectDir = (projectDir == null || projectDir.isEmpty) ? null : projectDir,
       run = AiTraceRun(
         pageId: pageId,
         imagePath: imagePath,
         model: model,
         provider: provider,
       );

  /// 内存模式（对比页）：图片留在内存，不写项目目录。
  AiTraceRecorder.memory({required String model, required String provider})
    : projectDir = null,
      pageId = '',
      imagePath = '',
      run = AiTraceRun(pageId: '', imagePath: '', model: model, provider: provider);

  /// 项目目录；null = 内存模式。
  final String? projectDir;
  final String pageId;
  final String imagePath;
  final AiTraceRun run;

  final Map<String, String> _memoryImages = {};
  bool _imagesCleared = false;
  int _imageSeq = 0;

  static String _traceDirOf(String projectDir) =>
      p.join(projectDir, 'ai_trace');

  static String _traceFileOf(String projectDir, String pageId) =>
      p.join(projectDir, 'ai_trace', '$pageId.json');

  static String imageDirOf(String projectDir, String pageId) =>
      p.join(projectDir, 'ai_trace', pageId);

  /// 落盘一张图，返回可被 [AiTraceImage.file] 引用的文件名。
  ///
  /// 解码与写盘（含 fsync）整个搬进后台 isolate（见 isolate_codec）：
  /// 批量拆分时每行落 40+ 张字图，逐张 base64Decode + fsync 在 UI
  /// isolate 上背靠背执行会把 Windows 消息泵饿死（AppHang 强杀）。
  /// 目录只在首次创建（原先每张图都 create 一次）。
  Future<String?> saveImage(String base64Png, String label) async {
    if (base64Png.isEmpty) return null;
    if (projectDir == null) {
      // 内存模式：文件名只作引用键，字节留内存（对比页渲染用）。
      final name = 'img_${_imageSeq.toString().padLeft(3, '0')}.png';
      _imageSeq++;
      _memoryImages[name] = base64Png;
      return name;
    }
    try {
      final dir = Directory(imageDirOf(projectDir!, pageId));
      if (!_imagesCleared) {
        // 只保留最后一次运行：首次落图前清掉旧运行的图。
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
        _imagesCleared = true;
      }
      if (!_imageDirReady) {
        await dir.create(recursive: true);
        _imageDirReady = true;
      }
      final name = 'img_${_imageSeq.toString().padLeft(3, '0')}.png';
      _imageSeq++;
      // flush=false：诊断图不需要单文件持久性（进程中断最多丢当页的
      // 图，溯源查看器容忍缺图）；批量时每行 40+ 张逐张 fsync 会让
      // 533 页的落盘开销以小时计，交给 OS 批量回写。
      await writeBase64FileInIsolate(
        base64Png,
        p.join(dir.path, name),
        flush: false,
      );
      return name;
    } catch (_) {
      // 图片落盘失败只影响溯源回看，不阻断识别主流程。
      return null;
    }
  }

  bool _imageDirReady = false;

  /// 内存模式的图片字节（磁盘模式恒为 null——编辑器面板走 [loadImage]）。
  Uint8List? imageBytesOf(String file) {
    if (projectDir != null || file.isEmpty) return null;
    final b64 = _memoryImages[file];
    return b64 == null ? null : base64Decode(b64);
  }

  /// 测试入口：下一个图片序号（continueRun 接续校验用）。
  @visibleForTesting
  int get imageSeqForTest => _imageSeq;

  /// 追加一条阶段记录（内存累积；flush 才落盘）。
  void add(AiTraceEntry entry) => run.entries.add(entry);

  /// 覆盖写本次运行的 JSON（每页只保留最后一次）；内存模式为空操作。
  /// 缩进序列化在后台 isolate 里做（一页 90-180 条 entry 达 MB 级，
  /// 同步转换在 UI isolate 上是数百毫秒的连续 CPU 段）。
  Future<void> flush() async {
    if (projectDir == null) return;
    try {
      final dir = Directory(_traceDirOf(projectDir!));
      await dir.create(recursive: true);
      final f = File(_traceFileOf(projectDir!, pageId));
      // 同名临时文件 + rename，避免写一半崩溃留下坏 JSON。
      final tmp = File('${f.path}.tmp');
      await writeJsonFileInIsolate(run.toJson(), tmp.path);
      if (await f.exists()) {
        await f.delete();
      }
      await tmp.rename(f.path);
    } catch (_) {
      // 溯源持久化失败不影响识别结果本身。
    }
  }

  /// 读取某页最后一次运行的溯源记录（无记录返回 null）。
  static Future<AiTraceRun?> load(String projectDir, String pageId) async {
    try {
      final f = File(_traceFileOf(projectDir, pageId));
      if (!await f.exists()) return null;
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return null;
      return AiTraceRun.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      return null;
    }
  }

  /// 续写某页已有的溯源记录（编辑器手动修复/复核追加进同一条时间线，
  /// 不清旧图、图片序号接续避免覆盖）。无已有记录返回 null。
  static Future<AiTraceRecorder?> continueRun(
    String projectDir,
    String pageId, {
    required String model,
    required String provider,
  }) async {
    final run = await load(projectDir, pageId);
    if (run == null) return null;
    final rec = AiTraceRecorder(
      projectDir: projectDir,
      pageId: pageId,
      imagePath: run.imagePath,
      model: model,
      provider: provider,
    );
    rec.run.startedAt = run.startedAt;
    rec.run.entries.addAll(run.entries);
    rec._imagesCleared = true;
    var maxSeq = -1;
    final pattern = RegExp(r'img_(\d+)\.png');
    for (final e in run.entries) {
      for (final im in e.images) {
        final m = pattern.firstMatch(im.file);
        final n = m == null ? -1 : (int.tryParse(m.group(1)!) ?? -1);
        if (n > maxSeq) maxSeq = n;
      }
    }
    rec._imageSeq = maxSeq + 1;
    return rec;
  }

  /// 读取溯源图片文件 bytes（面板渲染缩略图）。
  static Future<Uint8List?> loadImage(
    String projectDir,
    String pageId,
    String file,
  ) async {
    if (file.isEmpty) return null;
    try {
      final f = File(p.join(imageDirOf(projectDir, pageId), file));
      if (!await f.exists()) return null;
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }
}
