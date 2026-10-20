import 'dart:math' show max, min;
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
///
/// [orderBreakIds] 复用小注依附与方向逻辑做只读检查：行视图把"空间
/// 相邻行的序号不连续"标红，顺序错误一眼可见。它的列聚类口径比重排
/// 更严（x 区间重叠才算同列，见 [_breakSequence]）。
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

    final ordered = _geometricSequence(
      lines,
      paragraphs: annotation.paragraphs,
      orientation: orientation,
      horizontalDir: horizontalDir,
      verticalDir: verticalDir,
    );

    // ── Step 5: 写入 readingOrder；未被几何序列收录的行（孤立小注
    // 行）排在末尾 ──
    for (var i = 0; i < ordered.length; i++) {
      ordered[i].readingOrder = i;
    }
    var nextIdx = ordered.length;
    for (final line in lines) {
      if (line.readingOrder < 0) {
        line.readingOrder = nextIdx++;
        ordered.add(line);
      }
    }

    return ordered;
  }

  /// 行视图序号连续性检查（只读，不改任何字段）：按空间阅读序展开行
  /// 序列，相邻两行的当前序号（行在列表里的下标）应严格 +1；不满足
  /// 则两端行都算断点。返回断点行 id 集合——画布据此把行框/序号角标
  /// 标红，顺序错误所在一目了然。
  ///
  /// 空间序由 [_breakSequence] 给出：列聚类比 [reorder] 更严（x 区间
  /// 重叠才算同列），列距近、上下错位的栏不会被并成一列，连续栏不会
  /// 被误判断裂。
  static Set<String> orderBreakIds(
    List<LineBlock> lines, {
    List<Paragraph> paragraphs = const [],
    String orientation = 'vertical',
    String horizontalDir = 'rtl',
    String verticalDir = 'ttb',
  }) {
    if (lines.length < 2) return const {};
    final seq = orientation == 'horizontal'
        ? _horizontalSequence(lines, horizontalDir, verticalDir)
        : _breakSequence(
            lines,
            paragraphs: paragraphs,
            rtl: horizontalDir != 'ltr',
            ttb: verticalDir != 'btt',
          );
    // 孤立行（空间序列未收录）按列表原序补在末尾，与 reorder 同口径
    final inSeq = seq.map((l) => l.id).toSet();
    final full = [...seq, ...lines.where((l) => !inSeq.contains(l.id))];
    final badgeOf = <String, int>{
      for (var i = 0; i < lines.length; i++) lines[i].id: i,
    };
    final breaks = <String>{};
    for (var i = 0; i + 1 < full.length; i++) {
      final a = badgeOf[full[i].id];
      final b = badgeOf[full[i + 1].id];
      if (a == null || b == null) continue;
      if (b != a + 1) {
        breaks.add(full[i].id);
        breaks.add(full[i + 1].id);
      }
    }
    return breaks;
  }

  /// 断点检查专用的竖排空间序。列聚类与重排（[_geometricSequence] 的
  /// "中心距 ≤ 0.8×平均行宽"宽松口径，容忍检测抖动）刻意不同：两行
  /// x 区间重叠超过较窄行一半才算同列（与编辑器 lineSharesColumnBand
  /// 同口径）。宽松聚类在列距近、上下错位的页上会把相邻两栏并成一个
  /// 伪列，列内再按 y 排就与实际列序相反——重排只是给出一个可用顺序
  /// 无伤大雅，校验却会把连续栏误标红（用户实测页翻车）。校验要以
  /// 用户眼睛为准：肉眼看到的"下一列"就是 x 序里的下一列。
  static List<LineBlock> _breakSequence(
    List<LineBlock> lines, {
    required List<Paragraph> paragraphs,
    required bool rtl,
    required bool ttb,
  }) {
    bool sameBand(LineBlock a, LineBlock b) {
      final overlap = min(a.x + a.w, b.x + b.w) - max(a.x, b.x);
      final narrower = min(a.w, b.w);
      return narrower > 0 && overlap > narrower * 0.5;
    }

    final cols = <_Column>[];
    final sortedByX = List<LineBlock>.from(lines)
      ..sort(rtl ? (a, b) => b.x.compareTo(a.x) : (a, b) => a.x.compareTo(b.x));
    for (final line in sortedByX) {
      _Column? best;
      for (final col in cols) {
        if (col.lines.any((m) => sameBand(m, line))) {
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
    // 聚类会移动列中心，显式按中心 x 定列序（rtl=右→左）
    cols.sort(
      rtl ? (a, b) => b.centerX.compareTo(a.centerX)
          : (a, b) => a.centerX.compareTo(b.centerX),
    );
    for (final col in cols) {
      col.lines.sort(
        ttb ? (a, b) => a.y.compareTo(b.y) : (a, b) => b.y.compareTo(a.y),
      );
    }
    return _attachAnnotations(cols, lines, paragraphs, rtl);
  }

  /// 几何阅读序（重排/导出用，流程 1–4）：宽松中心距列聚类 + 列内 y
  /// 排 + 小注依附，返回有序列表（元素是原行对象引用，不改任何字段）。
  /// [reorder] 在此之上写 readingOrder。
  static List<LineBlock> _geometricSequence(
    List<LineBlock> lines, {
    required List<Paragraph> paragraphs,
    required String orientation,
    required String horizontalDir,
    required String verticalDir,
  }) {
    if (orientation == 'horizontal') {
      return _horizontalSequence(lines, horizontalDir, verticalDir);
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

    return _attachAnnotations(cols, lines, paragraphs, rtl);
  }

  /// 流程 3–4（[_geometricSequence] 与 [_breakSequence] 共用）：小注行
  /// （chars 全为 annotation）按"中心点落在 body 段内"依附到最近的正文
  /// 行，插在该正文行之后（侧序随 rtl：右注先读、左注先读）；其余行按
  /// 列序×列内序展开。不改任何字段。
  static List<LineBlock> _attachAnnotations(
    List<_Column> cols,
    List<LineBlock> lines,
    List<Paragraph> paragraphs,
    bool rtl,
  ) {
    // 小注行：其几何中心落在某个 paragraph（type == body）的矩形内
    // 且该行本身所属段类型为 annotation（或 chars 全为 annotation type）
    final bodyParagraphs =
        paragraphs.where((p) => p.type == 'body').toList();
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

    // 构建全局有序序列：正文行优先，插入依附于此正文行的小注行
    final ordered = <LineBlock>[];
    for (final col in cols) {
      for (final bodyLine in col.lines) {
        if (annotationLines.contains(bodyLine)) continue;
        ordered.add(bodyLine);
        final attached = annotationAttachments[bodyLine.id];
        if (attached != null && attached.isNotEmpty) {
          attached.sort(
            rtl ? (a, b) => b.x.compareTo(a.x) : (a, b) => a.x.compareTo(b.x),
          );
          ordered.addAll(attached);
        }
      }
    }
    return ordered;
  }

  /// 横排阅读顺序：行按 y 排（verticalDir 决定上下方向），y 相同时按
  /// x（horizontalDir 决定左右）。不做小注列依附。
  static List<LineBlock> _horizontalSequence(
    List<LineBlock> lines,
    String horizontalDir,
    String verticalDir,
  ) {
    final ttb = verticalDir != 'btt';
    final ltr = horizontalDir != 'rtl';
    return List<LineBlock>.from(lines)..sort((a, b) {
      final byY = ttb ? a.y.compareTo(b.y) : b.y.compareTo(a.y);
      if (byY != 0) return byY;
      return ltr ? a.x.compareTo(b.x) : b.x.compareTo(a.x);
    });
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
