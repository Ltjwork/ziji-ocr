/// AI 整页版面区预标注编排（仿 ai_line_repair.dart 先例）：
/// 素材图（/page_prelabel_image，带网格刻度与已有区域底色）→ 视觉模型
/// 判定五类版面区（归一化粗框）→ 后端几何精修（/region_refine：钳图内、
/// 墨迹收紧、近重复去除）→ proposed 状态的 MainRegion。
///
/// 安全边界：结果永远 proposed 待人工确认；已有区域只作为素材图底色
/// 提示模型"别重标"，落地前再按重叠过滤一次（只填空）。
library;

import '../models/models.dart';
import 'ollama_service.dart';
import 'python_service.dart';

class PagePrelabelResult {
  const PagePrelabelResult({
    required this.regions,
    required this.droppedReasons,
    required this.vlmRegionCount,
    required this.trace,
  });

  /// 可直接插入标注的 proposed 区域。
  final List<MainRegion> regions;

  /// 精修阶段被丢弃项的原因（空框/词表外/近重复）。
  final List<String> droppedReasons;

  /// 模型原始输出区域数（regions + 被 refine 丢弃的部分）。
  final int vlmRegionCount;

  /// 本次 VLM 调用的溯源（模型/prompt/原始返回/耗时）。
  final OllamaTrace trace;
}

/// 跑一次整页 AI 预标注。[imageWidth]/[imageHeight] 为原图像素尺寸
///（归一化坐标还原用）；[existingRegions] 为当前标注的区域列表
///（画进素材图防重标，w/h/x/y 为像素 int）。
Future<PagePrelabelResult> runPagePrelabel({
  required OllamaSettings settings,
  required String imagePath,
  required int imageWidth,
  required int imageHeight,
  List<Map<String, dynamic>> existingRegions = const [],
  bool wantThinking = false,
}) async {
  if (imageWidth <= 0 || imageHeight <= 0) {
    throw StateError('页面尺寸未知，无法换算坐标');
  }
  final material = await PythonService.pagePrelabelImage(
    imagePath: imagePath,
    maxSide: 1536,
    regions: existingRegions,
  );
  final trace = OllamaTrace();
  final prelabel = await OllamaService.prelabelPageLayout(
    settings: settings,
    imageBase64: material.base64,
    wantThinking: wantThinking,
    trace: trace,
  );
  if (prelabel.regions.isEmpty) {
    return PagePrelabelResult(
      regions: const [],
      droppedReasons: const [],
      vlmRegionCount: 0,
      trace: trace,
    );
  }
  // 归一化 → 像素，交给后端几何精修（墨迹收紧/钳制/去重）
  final pixelRegions = <RegionPrelabelSuggestion>[
    for (final r in prelabel.regions)
      RegionPrelabelSuggestion(
        x: (r.x * imageWidth).round(),
        y: (r.y * imageHeight).round(),
        w: (r.w * imageWidth).round().clamp(1, imageWidth),
        h: (r.h * imageHeight).round().clamp(1, imageHeight),
        label: r.label,
        confidence: 0,
        reason: 'AI 整页预标注',
      ),
  ];
  final refined = await PythonService.regionRefine(
    imagePath: imagePath,
    regions: pixelRegions,
  );
  final stamp = DateTime.now().millisecondsSinceEpoch;
  final regions = <MainRegion>[
    for (var i = 0; i < refined.regions.length; i++)
      MainRegion(
        id: 'mr_ai_${stamp}_$i',
        x: refined.regions[i].x,
        y: refined.regions[i].y,
        w: refined.regions[i].w,
        h: refined.regions[i].h,
        label: RegionLabel.normalize(refined.regions[i].label),
        status: AnnotationStatus.proposed,
      ),
  ];
  return PagePrelabelResult(
    regions: regions,
    droppedReasons: [
      for (final d in refined.dropped)
        '${d['label'] ?? ''}（${d['x'] ?? 0},${d['y'] ?? 0}）：${d['reason'] ?? ''}',
    ],
    vlmRegionCount: prelabel.regions.length,
    trace: trace,
  );
}
