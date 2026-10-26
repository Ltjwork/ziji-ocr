import 'dart:io';

import '../models/models.dart';
import 'ai_concurrency.dart';
import 'ai_line_repair.dart';
import 'ai_trace.dart';
import 'book_region_apply.dart';
import 'python_service.dart';
import 'storage.dart';
import 'ollama_service.dart';

/// Returns the annotation for [pageIndex], recognizing the page first when no
/// annotation exists yet ([force] re-runs recognition even if one exists).
///
/// The result is persisted before returning, so the presence of the annotation
/// file doubles as the "this page is done" marker for the batch queue and for
/// resuming an interrupted whole-book recognition. The save here is a machine
/// save and deliberately leaves [PageAnnotation.reviewed] untouched.
Future<PageAnnotation> ensurePageAnnotation(
  Project project,
  int pageIndex, {
  bool force = false,

  /// Explicit editor re-recognition uses the current AI settings even when
  /// the project was created before the project-level switch existed.
  bool useCurrentAiSettings = false,
  void Function(String stage)? onProgress,
}) async {
  // 页号以图片文件名为准（删除页后下标与文件名错位，见 pageIdForImage）。
  final pageId = pageIdForImage(project.imageFiles[pageIndex], pageIndex);
  // 识别方向支持按页覆盖（个别页与整书排版不同时）。
  final pageSettings = project.settingsAt(pageIndex);
  // 重识别（force）从现有标注取人工已确认的版面区作区域门控：已确认
  // 的页眉/页脚/页码在字检测前被抹除（页眉页脚只作版面标注），区域
  // 确认身份也随结果带回、不因重识别丢失。首次识别无标注可取。
  List<Map<String, dynamic>>? gateRegions;
  if (force) {
    final existing = await ProjectStorage.loadAnnotation(
      project.projectDir,
      pageId,
      expectedImagePath: project.imageFiles[pageIndex],
    );
    final confirmed = existing?.confirmedGateRegions ?? const [];
    if (confirmed.isNotEmpty) gateRegions = confirmed;
  }
  if (!force) {
    // 损坏或尚未写完的标注文件不能阻止识别；存储层会将其视为空标注并重新覆盖。
    final existing = await ProjectStorage.loadAnnotation(
      project.projectDir,
      pageId,
      expectedImagePath: project.imageFiles[pageIndex],
    );
    if (existing != null) return existing;
  }
  onProgress?.call('正在进行版面分割和 OCR 识别…');
  final ann = await PythonService.segmentWithSettings(
    imagePath: project.imageFiles[pageIndex],
    pageId: pageId,
    settings: pageSettings,
    modelOverrides: project.modelOverrides.isEmpty
        ? null
        : project.modelOverrides,
    gateRegions: gateRegions,
  );
  ann.inferHierarchy(
    orientation: pageSettings.orientation,
    horizontalDir: pageSettings.horizontalDir,
    verticalDir: pageSettings.verticalDir,
  );
  // 表格区域兜底清场：门控只带走已确认（boxConfirmed）的排除类区，未
  // 确认的表格区像素仍会被通用分割切成"单行/单字"混进结果——表格区
  // 域的内容以表格识别（TableAnnotation）为准，识别后统一把区内通用
  // 行删掉（首次识别无标注可清，此步为空操作）。
  var tablePurgedLines = 0;
  for (final region in ann.mainRegions) {
    if (region.status != AnnotationStatus.rejected &&
        RegionLabel.normalize(region.label) == RegionLabel.table) {
      tablePurgedLines += BookRegionApply.removeLinesInRect(ann, region.rect);
    }
  }
  if (tablePurgedLines > 0) {
    ann.rebuildParagraphs(
      orientation: pageSettings.orientation,
      horizontalDir: pageSettings.horizontalDir,
      verticalDir: pageSettings.verticalDir,
    );
    PythonService.addAppLog(
      '[表格清场] 重识别后清理表格区域内通用行 $tablePurgedLines 条'
      '（表格内容以表格识别为准）',
    );
  }
  // The project flag freezes whether this run may call AI, while the model
  // address/name remains a user setting.  Load the settings for both paths so
  // logs and the progress UI can tell an enabled run with no selected model
  // apart from a genuinely OCR-only run.
  final ollama = await OllamaSettings.load();
  final aiEnabled = useCurrentAiSettings
      // The page toolbar is an explicit re-recognition action.  Accept both
      // switches here: older projects and users who only enabled the manual
      // re-recognition option must still get the same line-level AI pass.
      ? (ollama.enableLineAssist || ollama.enableManualLineAssist)
      : project.aiRecognitionAssist;
  if (useCurrentAiSettings) {
    PythonService.addAppLog(
      '[AI整行裁决] 本页重识别设置：'
      'enableLineAssist=${ollama.enableLineAssist} '
      'enableManualLineAssist=${ollama.enableManualLineAssist} '
      'provider=${ollama.provider.wire} '
      'visionModel=${ollama.activeVisionModel} '
      'textModel=${ollama.activeTextModel}',
    );
  }
  if (aiEnabled) {
    PythonService.addAppLog(
      '[AI整行裁决] 已启用 source=${useCurrentAiSettings ? '当前全局设置' : '项目设置'} '
      'model=${ollama.activeVisionModel.isNotEmpty ? ollama.activeVisionModel : ollama.activeTextModel}',
    );
    onProgress?.call('正在进行 AI 整行裁决…');
    await applyAiLineAssistToLines(
      ann.lines,
      project.imageFiles[pageIndex],
      pageSettings,
      enabled: true,
      projectDir: project.projectDir,
      pageId: pageId,
      onProgress: (done, total) =>
          onProgress?.call('AI 整行裁决 $done/$total（低置信度自动保留 OCR）…'),
    );
  } else if (useCurrentAiSettings) {
    PythonService.addAppLog('[AI整行裁决] 当前全局设置未启用或未选择整行 AI，保留 OCR');
    onProgress?.call('整行 AI 未启用，保留 OCR 结果…');
  }
  // 局部修复会整段替换行内字块（新实例、新 id），重建扁平列表避免
  // ann.blocks 持有被替换掉的旧字块实例。
  ann.rebuildBlocks();
  // 书可能在识别期间被删除；不要为已删除的项目重建目录写入孤儿文件。
  if (!await Directory(project.projectDir).exists()) {
    throw FileSystemException('项目目录已不存在', project.projectDir);
  }
  // 机器写盘（识别结果落盘）：抑制确认后自动导出调度（内容层仍是
  // proposed，导出只会空转扫描）。
  await ProjectStorage.saveAnnotation(
    project.projectDir,
    ann,
    machineWrite: true,
  );
  return ann;
}

/// Runs optional AI 整行三步辅助（读行 → 逐字对应 → 切分诊断 + 局部修复
/// 闭环）after Kraken has produced stable boxes. This is shared by whole-page
/// recognition and explicit editor line re-recognition so both paths apply the
/// same fixed threshold and fallback rules. [projectDir]/[pageId] 提供时，
/// 全过程写进溯源记录并持久化（每页只保留最后一次运行）。
Future<void> applyAiLineAssistToLines(
  List<LineBlock> lines,
  String imagePath,
  ProjectSettings settings, {
  bool enabled = false,
  String? projectDir,
  String? pageId,
  void Function(int done, int total)? onProgress,
}) async {
  final ollama = await OllamaSettings.load();
  if (!enabled ||
      (ollama.activeVisionModel.isEmpty && ollama.activeTextModel.isEmpty)) {
    if (enabled) {
      PythonService.addAppLog('[AI整行裁决] 已开启但未选择视觉/文本模型，保留 OCR');
    }
    return;
  }
  var completed = 0;
  final total = lines.where((line) => line.chars.isNotEmpty).length;
  final model = ollama.activeVisionModel.isNotEmpty
      ? ollama.activeVisionModel
      : ollama.activeTextModel;
  PythonService.addAppLog(
    '[AI整行裁决] 开始逐行请求 total=$total model=$model '
    'provider=${ollama.provider.wire} thinking=${ollama.enableAiThinking}',
  );
  final recorder =
      projectDir != null &&
          projectDir.isNotEmpty &&
          pageId != null &&
          pageId.isNotEmpty
      ? AiTraceRecorder(
          projectDir: projectDir,
          pageId: pageId,
          imagePath: imagePath,
          model: model,
          provider: ollama.provider.wire,
        )
      : null;
  // 行级并发：按限流器的后台许可数开 worker 池（共享行号游标，事件
  // 循环单线程无竞态；请求真正并发由 AiRequestLimiter 的许可保证——
  // 池可略超订阅，多出来的在限流器里排队）。并行时邻行上下文可能读到
  // 中间态文字：上下文只是辅助提示，模型以图像为准，可接受。批量子
  // 走后台许可（interactive: false），编辑器手动单行重识别不受影响。
  final workers = await AiRequestLimiter.instance.backgroundPermitCount();
  PythonService.addAppLog('[AI整行裁决] 行级并发 workers=$workers');
  var cursor = 0;
  Future<void> worker() async {
    while (true) {
      final lineIndex = cursor++;
      if (lineIndex >= lines.length) return;
      final line = lines[lineIndex];
      if (line.chars.isEmpty) continue;
      await runLineAssist(
        line: line,
        lines: lines,
        lineIndex: lineIndex,
        imagePath: imagePath,
        settings: settings,
        ollama: ollama,
        recorder: recorder,
        log: PythonService.addAppLog,
        interactive: false,
      );
      completed++;
      onProgress?.call(completed, total);
    }
  }

  await Future.wait([for (var i = 0; i < workers; i++) worker()]);
  await recorder?.flush();
  if (recorder != null) {
    PythonService.addAppLog(
      '[AI溯源] 本页已保存 ${recorder.run.entries.length} 条阶段记录'
      '（ai_trace/$pageId.json，仅保留最后一次运行）',
    );
  }
}
