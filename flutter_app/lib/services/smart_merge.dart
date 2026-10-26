import 'dart:ui' show Rect;

import '../models/models.dart';
import 'annotation_hit_geometry.dart';

/// 智能合并（全书同类墨迹批量合并）——数据模型与纯逻辑。
///
/// 场景：同一符号（如「；」）在全书被识别器拆成两个框。用户在编辑器
/// 手工合并一处后，以合并前的两框为模板调后端 `/smart_merge_scan`
/// （几何构型 + HOG 墨迹特征双门槛，见后端 smart_merge.py）在全书找
/// 同类拆分对；命中项经用户确认后由 [applySmartMergeMatches] 按与手工
/// 合并完全相同的口径批量合并。已确认/已保存的内容（页 reviewed/
/// boxesReviewed/完全确认，框 confirmed/boxConfirmed）恒不参与。
///
/// 本文件只放纯逻辑（可单测），HTTP 调用在 PythonService.smartMergeScan。

/// 一次匹配对（后端返回项）：[pageId] 页里 [firstId]/[secondId] 两个
/// 阅读序相邻字框与模板同类，[score] 为两框墨迹距离的较大者（越小越像）。
class SmartMergeScanMatch {
  const SmartMergeScanMatch({
    required this.pageId,
    required this.firstId,
    required this.secondId,
    required this.score,
  });

  final String pageId;
  final String firstId;
  final String secondId;
  final double score;

  factory SmartMergeScanMatch.fromMap(Map<String, dynamic> j) =>
      SmartMergeScanMatch(
        pageId: j['page_id']?.toString() ?? '',
        firstId: j['first_id']?.toString() ?? '',
        secondId: j['second_id']?.toString() ?? '',
        score: (j['score'] as num?)?.toDouble() ?? 1,
      );
}

/// 一页的扫描结果汇总（由 PythonService.smartMergeScan 聚合返回）。
class SmartMergeScanResult {
  const SmartMergeScanResult({
    required this.matches,
    required this.scannedPages,
    required this.failedPageIds,
    required this.elapsedMs,
  });

  final List<SmartMergeScanMatch> matches;
  final int scannedPages;
  final List<String> failedPageIds;
  final double elapsedMs;
}

/// 智能分割的一次匹配（后端 /smart_split_scan 返回项）：[pageId] 页的
/// [blockId] 字框与模板框（手工 Alt 拆分前的原框）墨迹同类。
class SmartSplitScanMatch {
  const SmartSplitScanMatch({
    required this.pageId,
    required this.blockId,
    required this.score,
  });

  final String pageId;
  final String blockId;
  final double score;

  factory SmartSplitScanMatch.fromMap(Map<String, dynamic> j) =>
      SmartSplitScanMatch(
        pageId: j['page_id']?.toString() ?? '',
        blockId: j['block_id']?.toString() ?? '',
        score: (j['score'] as num?)?.toDouble() ?? 1,
      );
}

/// 一页的分割扫描结果汇总（由 PythonService.smartSplitScan 聚合返回）。
class SmartSplitScanResult {
  const SmartSplitScanResult({
    required this.matches,
    required this.scannedPages,
    required this.failedPageIds,
    required this.elapsedMs,
  });

  final List<SmartSplitScanMatch> matches;
  final int scannedPages;
  final List<String> failedPageIds;
  final double elapsedMs;
}

/// 扫描请求的一页载荷：行按存储阅读序给块（含已确认块——相邻关系
/// 必须完整，后端只对"两框都未确认"的相邻对做匹配）。
class SmartMergeScanPage {
  const SmartMergeScanPage({
    required this.pageId,
    required this.imagePath,
    required this.lines,
  });

  final String pageId;
  final String imagePath;
  final List<SmartMergeScanLine> lines;

  Map<String, dynamic> toMap() => {
    'page_id': pageId,
    'image_path': imagePath,
    'lines': [for (final line in lines) line.toMap()],
  };
}

class SmartMergeScanLine {
  const SmartMergeScanLine({required this.dir, required this.blocks});

  /// 行内阅读方向：ttb | btt | ltr | rtl（[smartMergeLineDir] 计算）。
  final String dir;
  final List<SmartMergeScanBlock> blocks;

  Map<String, dynamic> toMap() => {
    'dir': dir,
    'blocks': [for (final b in blocks) b.toMap()],
  };
}

class SmartMergeScanBlock {
  const SmartMergeScanBlock({
    required this.id,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.confirmed,
    required this.boxConfirmed,
  });

  final String id;
  final int x, y, w, h;
  final bool confirmed;
  final bool boxConfirmed;

  Map<String, dynamic> toMap() => {
    'id': id,
    'x': x,
    'y': y,
    'w': w,
    'h': h,
    'confirmed': confirmed,
    'box_confirmed': boxConfirmed,
  };
}

/// 行内阅读方向（行方向 × 本页生效设置：按页覆盖优先于整书）。
String smartMergeLineDir(LineBlock line, ProjectSettings settings) =>
    line.orientation == 'horizontal'
        ? (settings.horizontalDir == 'rtl' ? 'rtl' : 'ltr')
        : (settings.verticalDir == 'btt' ? 'btt' : 'ttb');

/// 把一页标注转成扫描载荷：每条 ≥2 字的行一个 [SmartMergeScanLine]，
/// 块按行内存储顺序（阅读序）。整页没有可配对的行（无行/行内不足两
/// 字）返回 null，调用方跳过该页。
SmartMergeScanPage? buildSmartMergeScanPage({
  required String pageId,
  required String imagePath,
  required PageAnnotation ann,
  required ProjectSettings settings,
}) {
  final lines = <SmartMergeScanLine>[];
  for (final line in ann.lines) {
    if (line.chars.length < 2) continue;
    lines.add(
      SmartMergeScanLine(
        dir: smartMergeLineDir(line, settings),
        blocks: [
          for (final c in line.chars)
            SmartMergeScanBlock(
              id: c.id,
              x: c.x,
              y: c.y,
              w: c.w,
              h: c.h,
              confirmed:
                  c.confirmed || c.status == AnnotationStatus.confirmed,
              boxConfirmed: c.boxConfirmed,
            ),
        ],
      ),
    );
  }
  if (lines.isEmpty) return null;
  return SmartMergeScanPage(
    pageId: pageId,
    imagePath: imagePath,
    lines: lines,
  );
}

bool _isProtected(CharBlock b) =>
    b.confirmed || b.boxConfirmed || b.status == AnnotationStatus.confirmed;

/// 把匹配对应用到页标注（纯逻辑，可单测）：与编辑器手工合并同口径
/// （[mergeCharBoxes]：并集矩形 + 文字按阅读轴拼接 + 沿用阅读序在前
/// 框的 id 与元数据），宿主行标记 manual（级联重识别保护）、清除 AI
/// 切分标记、行文本与 order 重建。
///
/// [matches] 须已按页过滤（只含本页）。跳过：任一框已确认（双保险，
/// 后端已过滤）、两框不在同一行、id 已被本次应用中更早的合并消费。
/// 返回实际合并的 (合并块, 宿主行) 列表；文字刷新与落盘由调用方负责。
List<(CharBlock, LineBlock)> applySmartMergeMatches(
  PageAnnotation ann,
  List<SmartMergeScanMatch> matches, {
  required ProjectSettings settings,
}) {
  // score 升序（最像的先合，后端已排序，这里防御性再排）。
  final ordered = [...matches]..sort((a, b) => a.score.compareTo(b.score));
  final consumed = <String>{};
  final results = <(CharBlock, LineBlock)>[];
  for (final m in ordered) {
    if (consumed.contains(m.firstId) || consumed.contains(m.secondId)) {
      continue;
    }
    CharBlock? first;
    CharBlock? second;
    for (final b in ann.blocks) {
      if (b.id == m.firstId) first = b;
      if (b.id == m.secondId) second = b;
    }
    if (first == null || second == null) continue;
    if (_isProtected(first) || _isProtected(second)) continue;
    LineBlock? host;
    for (final line in ann.lines) {
      final ids = line.chars.map((c) => c.id).toSet();
      if (ids.contains(first.id) && ids.contains(second.id)) {
        host = line;
        break;
      }
    }
    if (host == null) continue;
    final horizontal = host.orientation == 'horizontal';
    final merged = mergeCharBoxes(
      first,
      second,
      horizontal: horizontal,
      rtl: horizontal && settings.horizontalDir == 'rtl',
    );
    host.chars.removeWhere(
      (c) => c.id == first!.id || c.id == second!.id,
    );
    insertCharInLine(host, merged, settings: settings);
    ann.blocks.removeWhere(
      (b) => b.id == first!.id || b.id == second!.id,
    );
    ann.blocks.add(merged);
    host.manual = true;
    merged
      ..aiBoxIssue = null
      ..aiBoxNote = null;
    consumed
      ..add(first.id)
      ..add(second.id);
    results.add((merged, host));
  }
  return results;
}

/// 新字按几何阅读序插入行内并重建 order/行文本（编辑器
/// _insertCharInReadingOrder 的纯逻辑版，阅读方向取本页生效设置）。
void insertCharInLine(
  LineBlock line,
  CharBlock newChar, {
  required ProjectSettings settings,
}) {
  final horizontal = line.orientation == 'horizontal';
  final rtl = horizontal && settings.horizontalDir == 'rtl';
  double axisOf(CharBlock c) => horizontal ? c.x + c.w / 2 : c.y + c.h / 2;
  final index = readingOrderInsertIndex(
    [for (final c in line.chars) axisOf(c)],
    axisOf(newChar),
    rtl: rtl,
  );
  line.chars.insert(index, newChar);
  for (var i = 0; i < line.chars.length; i++) {
    line.chars[i].order = i;
  }
  line.text = line.chars.map((c) => c.text).join();
}

/// 文字刷新后重建行文本（行内字序未变，只重拼）。
void rebuildSmartMergeLineText(LineBlock line) {
  line.text = line.chars.map((c) => c.text).join();
}

/// 按模板比例把匹配字框沿阅读轴一分为二（纯逻辑，可单测）——与编辑
/// 器 Alt 拆分同口径：[ratio] 为前半占原框阅读轴长度的比例（模板拆分
/// 的有效切线比例），切线经 [AnnotationHitGeometry.splitRectAt] 同款钳
/// 制（两侧各留最小框 5px，轴向太薄返回 null 跳过）；原框就地改成前
/// 半（宿主行 manual 保护、AI 切分标记清除），后半作为新字框插到原框
/// 之后（阅读序上紧随），order 与行文本重建。
///
/// [matches] 须已按页过滤。跳过：已确认框（双保险）、id 不在或不在任
/// 何行内、框太薄切不开。返回 (前半, 后半, 宿主行) 列表；两半的文字
/// 刷新与落盘由调用方负责。
List<(CharBlock, CharBlock, LineBlock)> applySmartSplits(
  PageAnnotation ann,
  List<SmartSplitScanMatch> matches, {
  required double ratio,
  required ProjectSettings settings,
}) {
  final ordered = [...matches]..sort((a, b) => a.score.compareTo(b.score));
  final results = <(CharBlock, CharBlock, LineBlock)>[];
  final stamp = DateTime.now().millisecondsSinceEpoch;
  for (final m in ordered) {
    CharBlock? block;
    for (final b in ann.blocks) {
      if (b.id == m.blockId) {
        block = b;
        break;
      }
    }
    if (block == null || _isProtected(block)) continue;
    LineBlock? host;
    for (final line in ann.lines) {
      if (line.chars.any((c) => c.id == block!.id)) {
        host = line;
        break;
      }
    }
    if (host == null) continue;
    final horizontal = host.orientation == 'horizontal';
    final rect = Rect.fromLTWH(
      block.x.toDouble(),
      block.y.toDouble(),
      block.w.toDouble(),
      block.h.toDouble(),
    );
    final axisStart = horizontal ? rect.left : rect.top;
    final axisLen = horizontal ? rect.width : rect.height;
    final halves = AnnotationHitGeometry.splitRectAt(
      rect,
      cut: axisStart + ratio * axisLen,
      horizontal: horizontal,
    );
    if (halves == null) continue; // 轴向太薄，切不出两个最小框
    final (firstRect, secondRect) = halves;
    // 原框就地改前半（几何变化 → 行 manual，与编辑器 _updateBlock 同口径）
    if (horizontal) {
      block.w = firstRect.width.toInt();
    } else {
      block.h = firstRect.height.toInt();
    }
    block
      ..aiBoxIssue = null
      ..aiBoxNote = null;
    // 后半新框（编辑器 Alt 拆分同构：新 id、行归属、待确认候选）
    final second = CharBlock(
      id: 'u_${stamp}_${results.length}',
      x: secondRect.left.toInt(),
      y: secondRect.top.toInt(),
      w: secondRect.width.toInt(),
      h: secondRect.height.toInt(),
      col: host.lineNo,
      order: 0,
      type: block.type,
      lineId: host.id,
    );
    final idx = host.chars.indexWhere((c) => c.id == block!.id);
    host.chars.insert(idx + 1, second);
    for (var i = 0; i < host.chars.length; i++) {
      host.chars[i].order = i;
    }
    host
      ..manual = true
      ..text = host.chars.map((c) => c.text).join();
    ann.blocks.add(second);
    results.add((block, second, host));
  }
  return results;
}
