/// AI 画框测试编排（实验功能，仿 ai_page_prelabel.dart 先例）：
/// 素材图（/page_prelabel_image，带网格刻度）→ 视觉模型直接输出每个字的
/// 坐标框 → 换算回原图像素。与生产链路的差别是刻意的：**不做任何几何
/// 精修、不进任何标注**，AI 坐标原样返回，测的就是 VLM 裸定位水平
///（消费方：ai_box_test_page.dart）。
library;

import 'ollama_service.dart';
import 'python_service.dart';

class AiCharBoxesResult {
  const AiCharBoxesResult({
    required this.boxes,
    required this.elapsedMs,
    required this.materialMs,
    required this.truncated,
    required this.rawContent,
    required this.trace,
    required this.coordMode,
    required this.gridDiv,
  });

  /// 原图像素坐标的字框（x1/y1/x2/y2），顺序即模型给出的阅读顺序。
  final List<OllamaCharBox> boxes;

  /// VLM 调用耗时（毫秒，不含素材图请求）。
  final int elapsedMs;

  /// 素材图生成耗时（/page_prelabel_image，毫秒）。
  final int materialMs;

  /// 全程耗时 = 素材图 + VLM——与管线对比时的公平口径。
  int get totalMs => materialMs + elapsedMs;

  /// 输出被 num_predict/超时截断（已打捞出不完整的一批）。
  final bool truncated;

  final String rawContent;

  final OllamaTrace trace;

  final AiBoxCoordMode coordMode;

  final int gridDiv;
}

/// 跑一次 AI 画框测试。[gridDiv] 为素材图网格密度（字框级建议 16），
/// [coordMode] 决定让模型输出哪种坐标（素材图像素 / 归一化 0~1）。
/// 全程打 [app] 阶段日志（素材图→请求发出→完成/失败）——外部网关整页
/// 任务易超时/截断，应用侧历史上有"API 返回后无痕消失"的崩溃模式，
/// 日志的最后一行即死亡时刻所处的阶段。
Future<AiCharBoxesResult> runAiCharBoxes({
  required OllamaSettings settings,
  required String imagePath,
  required int gridDiv,
  AiBoxCoordMode coordMode = AiBoxCoordMode.materialPixel,
}) async {
  PythonService.addAppLog(
    '[AI画框] 开始：图=$imagePath 口径=${coordMode.label} 网格=$gridDiv 格'
    ' 来源=${settings.provider.label} 模型=${settings.activeVisionModel}',
  );
  final materialSw = Stopwatch()..start();
  final material = await PythonService.pagePrelabelImage(
    imagePath: imagePath,
    maxSide: 1536,
    regions: const [],
    gridDiv: gridDiv,
  );
  final materialMs = materialSw.elapsedMilliseconds;
  PythonService.addAppLog(
    '[AI画框] 素材图就绪 ${material.width}x${material.height}'
    '（b64 ${material.base64.length} 字符，scale=${material.scale}），发出 AI 请求…',
  );
  final trace = OllamaTrace();
  final result = await OllamaService.charBoxesFromImage(
    settings: settings,
    imageBase64: material.base64,
    imageWidth: material.width,
    imageHeight: material.height,
    gridDiv: gridDiv,
    coordMode: coordMode,
    trace: trace,
  );
  PythonService.addAppLog(
    '[AI画框] AI 返回：${result.boxes.length} 框'
    '${result.truncated ? '（响应被截断，已打捞）' : ''}，'
    '耗时 ${(trace.elapsedMs / 1000).toStringAsFixed(1)} 秒，'
    '原始返回 ${result.rawContent.length} 字符',
  );
  // 同步落盘：异步日志链在进程死亡时会丢最后一行——"返回后、渲染前"
  // 正是历史无痕消失的高发窗口，这里必须是崩溃 forensic 级别的写入。
  PythonService.writeCrashLineSync(
    '[AI画框] AI 返回（同步标记）：${result.boxes.length} 框，'
    '即将换算坐标并回页面渲染',
  );
  // 素材图像素 ÷ scale = 原图像素；归一化 × 原图尺寸 = 原图像素
  final invScale = material.scale > 0 ? 1.0 / material.scale : 1.0;
  final boxes = <OllamaCharBox>[
    for (final b in result.boxes)
      OllamaCharBox(
        x1: switch (coordMode) {
          AiBoxCoordMode.materialPixel => b.x1 * invScale,
          AiBoxCoordMode.normalized => b.x1 * material.origWidth,
        },
        y1: switch (coordMode) {
          AiBoxCoordMode.materialPixel => b.y1 * invScale,
          AiBoxCoordMode.normalized => b.y1 * material.origHeight,
        },
        x2: switch (coordMode) {
          AiBoxCoordMode.materialPixel => b.x2 * invScale,
          AiBoxCoordMode.normalized => b.x2 * material.origWidth,
        },
        y2: switch (coordMode) {
          AiBoxCoordMode.materialPixel => b.y2 * invScale,
          AiBoxCoordMode.normalized => b.y2 * material.origHeight,
        },
      ),
  ];
  return AiCharBoxesResult(
    boxes: boxes,
    elapsedMs: trace.elapsedMs,
    materialMs: materialMs,
    truncated: result.truncated,
    rawContent: result.rawContent,
    trace: trace,
    coordMode: coordMode,
    gridDiv: gridDiv,
  );
}
