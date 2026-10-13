import 'dart:ui' show Offset, Rect;
import '../models/models.dart';

/// 阅读顺序重排器：竖排按列排、列内按行排，方向由参数决定（rtl=右→左
/// 列、ttb=上→下行，反转值各自翻转），小注行依附正文段。
///
/// 核心流程：
/// 1. 按 line.x 聚类成列（列间距 > 平均行宽 → 新列），列间按
///    horizontalDir 决定的方向排（rtl=右→左，ltr=左→右）
/// 2. 列内按 y 排序（verticalDir：ttb=升序，btt=降序）
/// 3. 小注行：中心点落在某正文段框内 → 依附该段
/// 4. 段内排序：正文行优先，同一段内小注行插在紧邻的正文行之后
///    （小注侧序随 horizontalDir：rtl 右注先读，ltr 左注先读）
/// 5. 输出全局序号写入每个 LineBlock.readingOrder
class ReadingOrderCalculator {
  /// 对单页所有行做重排，返回排序后的行列表副本，并原地写入 readingOrder。
  ///
  /// [orientation] 决定行序几何：竖排按列（horizontalDir 决定列序、
  /// verticalDir 决定列内行序）+ 小注列依附；横排直接按 y 排行
  /// （verticalDir 决定上下方向、horizontalDir 决定同行内左右），
  /// 无小注依附——横排的行就是完整阅读单元。
  static List<LineBlock> reorder(
    PageAnnotation annotation, {
    String orientation = 'vertical',
    String horizontalDir = 'rtl',
    String verticalDir = 'ttb',
  }) {
    final lines = annotation.lines;
    if (lines.isEmpty) return [];

    if (orientation == 'horizontal') {
      return _reorderHorizontal(lines, horizontalDir, verticalDir);
    }

    final avgW = lines.map((l) => l.w).reduce((a, b) => a + b) / lines.length;
    final colThreshold = (avgW * 0.8).clamp(20.0, 120.0);

    // ── Step 1: 按列聚类（列序随 horizontalDir：rtl=右→左）──
    final rtl = horizontalDir != 'ltr';
    final cols = <_Column>[];
    final sortedByX = List<LineBlock>.from(lines)
      ..sort(rtl ? (a, b) => b.x.compareTo(a.x) : (a, b) => a.x.compareTo(b.x));

    for (final line in sortedByX) {
      _Column? best;
      for (final col in cols) {
        if ((col.centerX - line.x - line.w / 2).abs() <= colThreshold) {
          best = col;
          break;
        }
      }
      if (best != null) {
        best.lines.add(line);
        best._recalcCenter();
      } else {
        cols.add(_Column(line));
      }
    }

    // ── Step 2: 列内按 y 排序（verticalDir：ttb=上→下，btt=下→上）──
    final ttb = verticalDir != 'btt';
    for (final col in cols) {
      col.lines.sort(
        ttb ? (a, b) => a.y.compareTo(b.y) : (a, b) => b.y.compareTo(a.y),
      );
    }

    // ── Step 3: 识别小注行并关联到正文行 ──
    // 小注行：其几何中心落在某个 paragraph（type == body）的矩形内
    // 且该行本身所属段类型为 annotation（或 chars 全为 annotation type）
    final bodyParagraphs =
        annotation.paragraphs.where((p) => p.type == 'body').toList();
    final annotationLines = <LineBlock>{};
    for (final line in lines) {
      if (_isAnnotationLine(line)) {
        annotationLines.add(line);
      }
    }

    // 构建正文行 → 依附的小注行列表 的映射
    final annotationAttachments = <String, List<LineBlock>>{};
    for (final annoLine in annotationLines) {
      final center = Offset(
        annoLine.x + annoLine.w / 2,
        annoLine.y + annoLine.h / 2,
      );
      // 找到最近的正文行（同列中 y 最接近且中心在正文段内）
      String? bestHostId;
      double bestDist = double.infinity;
      for (final col in cols) {
        for (final bodyLine in col.lines) {
          if (annotationLines.contains(bodyLine)) continue;
          // 检查该正文行是否属于某个 body paragraph，且小注中心在该段内
          bool inBodyPara = bodyParagraphs.isEmpty;
          for (final para in bodyParagraphs) {
            final pRect = Rect.fromLTWH(
              para.x.toDouble(),
              para.y.toDouble(),
              para.w.toDouble(),
              para.h.toDouble(),
            );
            if (pRect.contains(center)) {
              inBodyPara = true;
              break;
            }
          }
          if (!inBodyPara) continue;
          final dist = (bodyLine.y + bodyLine.h / 2 - center.dy).abs();
          if (dist < bestDist) {
            bestDist = dist;
            bestHostId = bodyLine.id;
          }
        }
      }
      if (bestHostId != null) {
        annotationAttachments
            .putIfAbsent(bestHostId, () => [])
            .add(annoLine);
      }
    }

    // ── Step 4: 构建全局有序序列 ──
    final ordered = <LineBlock>[];
    for (final col in cols) {
      for (final bodyLine in col.lines) {
        if (annotationLines.contains(bodyLine)) continue;
        ordered.add(bodyLine);
        // 插入依附于此正文行的小注行，侧序随 horizontalDir（rtl 右注先读）
        final attached = annotationAttachments[bodyLine.id];
        if (attached != null && attached.isNotEmpty) {
          attached.sort(
            rtl ? (a, b) => b.x.compareTo(a.x) : (a, b) => a.x.compareTo(b.x),
          );
          ordered.addAll(attached);
        }
      }
    }

    // ── Step 5: 写入 readingOrder ──
    for (var i = 0; i < ordered.length; i++) {
      ordered[i].readingOrder = i;
    }
    // 未被收录的行（孤立小注行）也要给一个序号，排在末尾
    var nextIdx = ordered.length;
    for (final line in lines) {
      if (line.readingOrder < 0) {
        line.readingOrder = nextIdx++;
        ordered.add(line);
      }
    }

    return ordered;
  }

  /// 横排阅读顺序：行按 y 排（verticalDir 决定上下方向），y 相同时按
  /// x（horizontalDir 决定左右）。不做小注列依附。
  static List<LineBlock> _reorderHorizontal(
    List<LineBlock> lines,
    String horizontalDir,
    String verticalDir,
  ) {
    final ttb = verticalDir != 'btt';
    final ltr = horizontalDir != 'rtl';
    final ordered = List<LineBlock>.from(lines)
      ..sort((a, b) {
        final byY = ttb ? a.y.compareTo(b.y) : b.y.compareTo(a.y);
        if (byY != 0) return byY;
        return ltr ? a.x.compareTo(b.x) : b.x.compareTo(a.x);
      });
    for (var i = 0; i < ordered.length; i++) {
      ordered[i].readingOrder = i;
    }
    return ordered;
  }

  /// 判定某行是否为小注行：该行所有 chars 的 type 均为 annotation
  static bool _isAnnotationLine(LineBlock line) {
    if (line.chars.isEmpty) return false;
    for (final c in line.chars) {
      if (c.type != 'annotation') return false;
    }
    return true;
  }

  /// 生成阅读顺序 JSON 结构（供导出用）
  static List<Map<String, dynamic>> toJson(
    PageAnnotation annotation, {
    String orientation = 'vertical',
    String horizontalDir = 'rtl',
    String verticalDir = 'ttb',
  }) {
    final ordered = reorder(
      annotation,
      orientation: orientation,
      horizontalDir: horizontalDir,
      verticalDir: verticalDir,
    );
    return ordered.map((line) {
      return {
        'line_id': line.id,
        'order': line.readingOrder,
        'text': line.text,
        'paragraph_id': line.paragraphId,
        'main_region_id': _findMainRegionId(annotation, line),
        'x': line.x,
        'y': line.y,
        'w': line.w,
        'h': line.h,
        'orientation': line.orientation,
      };
    }).toList();
  }

  static String _findMainRegionId(PageAnnotation annotation, LineBlock line) {
    final center = Offset(
      line.x + line.w / 2,
      line.y + line.h / 2,
    );
    for (final region in annotation.mainRegions) {
      final r = Rect.fromLTWH(
        region.x.toDouble(),
        region.y.toDouble(),
        region.w.toDouble(),
        region.h.toDouble(),
      );
      if (r.contains(center)) return region.id;
    }
    return '';
  }
}

/// 一个逻辑列（竖排列）
class _Column {
  final List<LineBlock> lines;
  double centerX;

  _Column(LineBlock first)
      : lines = [first],
        centerX = first.x + first.w / 2;

  void _recalcCenter() {
    if (lines.isEmpty) return;
    centerX = lines.map((l) => l.x + l.w / 2).reduce((a, b) => a + b) /
        lines.length;
  }
}