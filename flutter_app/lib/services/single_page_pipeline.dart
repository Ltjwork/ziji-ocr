/// 单页生产管线运行器（从朝代基准页 _recognizeCase 提取，两页共用）：
/// /segment（版面 + YOLO 切字 + Kraken 识别）→ inferHierarchy →（可选）
/// AI 整行裁决 → rebuildBlocks → 阅读顺序重排。不落盘标注、不写
/// ai_trace——朝代基准拼评测 payload，「AI 画框测试」页做纯 AI 画框
/// 对比，都是"看完即弃"的单页运行。
library;

import 'package:http/http.dart' as http;

import '../models/models.dart';
import 'ollama_service.dart';
import 'page_recognition.dart';
import 'python_service.dart';
import 'reading_order.dart';

class SinglePagePipelineResult {
  const SinglePagePipelineResult({
    required this.annotation,
    required this.orderedLines,
    required this.totalMs,
    required this.segmentMs,
    required this.aiAssistMs,
    required this.segmentMeta,
    required this.aiAssistStatus,
    required this.aiAssistModel,
  });

  final PageAnnotation annotation;

  /// 阅读顺序重排后的行（行上 readingOrder 已写入）。
  final List<LineBlock> orderedLines;

  /// 全程耗时（含忙等待；= 用户体验到的"识别一页所用时间"）。
  final int totalMs;

  /// /segment 阶段耗时（版面 + 切字 + Kraken 识别，含忙等待）。
  final int segmentMs;

  /// AI 整行裁决阶段耗时（未启用为 0）。
  final int aiAssistMs;

  /// 管线元信息：engine（hier=自训 YOLO 层级 / opencv=回退）/
  /// fallback_reason / converter /（可选）yolo。
  final Map<String, dynamic> segmentMeta;

  /// 'applied' / 'skipped-toggle'（未开）/ 'skipped-no-model'。
  final String aiAssistStatus;

  /// applied 时实际使用的模型名（视觉优先、文本兜底），否则空串。
  final String aiAssistModel;
}

/// 单张图走**正常书籍识别管线**（与整本识别 ensurePageAnnotation 同步
/// 序）。忙等待语义与整本识别队列 _recognizePageWithRetry 同款：409 忙/
/// 后端失联长等待（别的识别在跑不打断本次），真实失败重试一次。
/// [onProgress] 报告人类可读的阶段文案（忙等待计数、AI 裁决进度）。
Future<SinglePagePipelineResult> runSinglePagePipeline({
  required String imagePath,
  required String pageId,
  required ProjectSettings settings,
  bool useAiAssist = false,
  void Function(String stage)? onProgress,
}) async {
  final sw = Stopwatch()..start();
  PythonService.addAppLog(
    '[管线] 开始：图=$imagePath 阅读方向=${settings.orientation}/'
    '${settings.horizontalDir} AI裁决=${useAiAssist ? '开' : '关'}',
  );
  Map<String, dynamic> segmentMeta = const {};
  final segmentSw = Stopwatch()..start();
  PageAnnotation ann;
  // 409 忙/后端失联长等待；真实失败重试一次。
  var busyWaits = 0;
  var unreachableWaits = 0;
  var attempts = 0;
  while (true) {
    try {
      ann = await PythonService.segmentWithSettings(
        imagePath: imagePath,
        pageId: pageId,
        settings: settings,
        onSegmentMeta: (m) => segmentMeta = m,
      );
      break;
    } on RecognitionBusyException {
      busyWaits++;
      if (busyWaits >= 60) rethrow;
      onProgress?.call('$pageId：识别服务忙（$busyWaits/60），等待重试…');
      await Future<void>.delayed(const Duration(seconds: 5));
    } on http.ClientException {
      unreachableWaits++;
      if (unreachableWaits >= 36) rethrow;
      onProgress?.call('$pageId：后端未就绪（$unreachableWaits/36），等待重试…');
      await Future<void>.delayed(const Duration(seconds: 5));
    } catch (e) {
      attempts++;
      if (attempts >= 2) rethrow;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }
  final segmentMs = segmentSw.elapsedMilliseconds;
  PythonService.addAppLog(
    '[管线] /segment 完成：engine=${segmentMeta['engine']} '
    '${segmentMeta['fallback_reason'] == null || segmentMeta['fallback_reason'].toString().isEmpty ? '' : '（回退：${segmentMeta['fallback_reason']}）'}'
    ' 耗时 ${(segmentMs / 1000).toStringAsFixed(1)} 秒',
  );

  ann.inferHierarchy(
    orientation: settings.orientation,
    horizontalDir: settings.horizontalDir,
    verticalDir: settings.verticalDir,
  );

  var aiAssistStatus = useAiAssist ? 'skipped-no-model' : 'skipped-toggle';
  var aiAssistModel = '';
  var aiAssistMs = 0;
  if (useAiAssist) {
    // 与整本识别同门控：仅按"已选模型"判定，applyAiLineAssistToLines
    // 内部仅在模型为空时静默保留 OCR。
    final ollama = await OllamaSettings.load();
    final model = ollama.activeVisionModel.isNotEmpty
        ? ollama.activeVisionModel
        : ollama.activeTextModel;
    if (model.isEmpty) {
      aiAssistStatus = 'skipped-no-model';
    } else {
      aiAssistStatus = 'applied';
      aiAssistModel = model;
      final assistSw = Stopwatch()..start();
      await applyAiLineAssistToLines(
        ann.lines,
        imagePath,
        settings,
        enabled: true,
        onProgress: (done, total) => onProgress?.call(
          '$pageId：AI 整行裁决 $done/$total（低置信度自动保留 OCR）…',
        ),
      );
      aiAssistMs = assistSw.elapsedMilliseconds;
      PythonService.addAppLog(
        '[管线] AI 整行裁决完成：$aiAssistModel '
        '耗时 ${(aiAssistMs / 1000).toStringAsFixed(1)} 秒',
      );
    }
  }

  ann.rebuildBlocks();
  final ordered = ReadingOrderCalculator.reorder(
    ann,
    orientation: settings.orientation,
    horizontalDir: settings.horizontalDir,
    verticalDir: settings.verticalDir,
  );
  final result = SinglePagePipelineResult(
    annotation: ann,
    orderedLines: ordered,
    totalMs: sw.elapsedMilliseconds,
    segmentMs: segmentMs,
    aiAssistMs: aiAssistMs,
    segmentMeta: segmentMeta,
    aiAssistStatus: aiAssistStatus,
    aiAssistModel: aiAssistModel,
  );
  // 同步落盘：该链路消费方（AI 画框测试页）有"应用无痕消失"排查史，
  // 关键节点不能走异步日志链（进程死亡会丢最后一行）。
  PythonService.writeCrashLineSync(
    '[管线] 完成（同步标记）：${ordered.length} 行，'
    '总耗时 ${(result.totalMs / 1000).toStringAsFixed(1)} 秒'
    '（识别 ${(segmentMs / 1000).toStringAsFixed(1)} + '
    'AI 裁决 ${(aiAssistMs / 1000).toStringAsFixed(1)}）',
  );
  return result;
}
