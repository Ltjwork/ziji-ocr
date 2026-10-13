/// 特征点匹配 + RANSAC 相似变换估计：把两页的 [InkPageFeatures] 配
/// 准成一条"参考页坐标 → 本页坐标"的相似变换，供叠加对齐的特征法
/// 路线（ink_align.dart 的 computeInkAlignmentsFromFeatures）逐页调
/// 用。
///
/// 流程：
/// 1. [matchFeatures]——描述子暴力最近邻 + Lowe 距离比测试（0.75）
///    双向做，交叉一致才保留：ref→page 与 page→ref 各自比值过滤后
///    取交集，单向可对的双胞胎块（两页各有一对形状相近的字）被剔
///    除，只剩互为唯一近邻的强匹配。
/// 2. [ransacSimilarity]——随机采 2 对点解相似变换（最小样本），
///    统计残差 < 5px 的内点，迭代取内点最多者。误匹配（版式巧合、
///    重复出现的字形的错位配对）在几何一致性投票里被自然出局，
///    这正是特征法对投影法周期回声问题的根治点。
/// 3. [FeatureAlignOutcome]——内点集最小二乘重拟合（4×4 正规方
///    程一次消元），给出终版变换与诊断（匹配数/内点数/内点比）。
///
/// 变换模型选相似而非一般仿射：扫描页的物理形变是"刚性旋转 + DPI
/// 缩放 + 平移"，没有剪切；绘制端 OverlayInkTransform 也只能表达
/// 旋转+平移+均匀缩放。自由度 4（vs 仿射 6），RANSAC 最小样本 2 对
///（vs 3 对），更抗外点。
library;

import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'feature_points.dart';

/// 一对特征的匹配：ref 第 [refIndex] 点 ↔ page 第 [pageIndex] 点。
class FeatureMatch {
  const FeatureMatch(this.refIndex, this.pageIndex, this.distance);

  final int refIndex;
  final int pageIndex;
  final double distance;
}

/// 匹配与 RANSAC 可调参数（工作画布 600px 宽口径标定）。
class MatchSettings {
  const MatchSettings({
    this.ratioThreshold = 0.75,
    this.maxIterations = 1000,
    this.inlierThreshold = 5.0,
    this.minMatches = 15,
    this.minInliers = 10,
    this.minInlierRatio = 0.30,
    this.minSampleDistance = 20.0,
    this.maxScaleDeviation = 0.05,
    this.minFeaturePoints = 20,
  });

  /// Lowe 距离比阈值：最近/次近 < 该值才保留。0.7 高精度、0.85 高
  /// 召回，0.75 为 SIFT 论文推荐中值。
  final double ratioThreshold;

  /// RANSAC 最大迭代次数：内点率 ≥30% 时 1000 次足够以 >99% 概率
  /// 采到一次纯内点样本。
  final int maxIterations;

  /// 内点判定残差（工作像素）：600px 宽下字块质心定位误差 <1px，
  /// 5px 容忍小角度旋转下的描述子错配残留。
  final double inlierThreshold;

  /// 进入 RANSAC 的最少匹配数：少于它连采样的余量都没有。
  final int minMatches;

  /// 对齐成立的最少内点数。
  final int minInliers;

  /// 对齐成立的最低内点比例（内点/匹配数）。
  final double minInlierRatio;

  /// RANSAC 采样两点间的最小参考页距离：太近的点对解出的旋转极不
  /// 稳定（微小噪声被放大成大角度）。
  final double minSampleDistance;

  /// 相似变换缩放对 1 的最大偏离：同书同扫仪 |s−1| 应 <5%，超出说
  /// 明解到了错误尺度（多为错配主导）。
  final double maxScaleDeviation;

  /// 参与组配准的单页特征点数下限：少于它的页（近空白/版式异常）
  /// 不进匹配（组级门控，见 computeInkAlignmentsFromFeatures）。
  final int minFeaturePoints;
}

const MatchSettings kMatchDefaults = MatchSettings();

/// 相似变换 `p ↦ s·R(θ)·p + t` 的线性参数化：
/// `x' = a·x − b·y + tx`，`y' = b·x + a·y + ty`（a = s·cosθ，b = s·sinθ）。
class SimilarityTransform {
  const SimilarityTransform(this.a, this.b, this.tx, this.ty);

  const SimilarityTransform.identity()
      : a = 1,
        b = 0,
        tx = 0,
        ty = 0;

  final double a;
  final double b;
  final double tx;
  final double ty;

  /// 旋转角（弧度，参考页坐标 → 本页坐标方向）。
  double get angle => math.atan2(b, a);

  /// 均匀缩放。
  double get scale => math.sqrt(a * a + b * b);

  Offset apply(Offset p) =>
      Offset(a * p.dx - b * p.dy + tx, b * p.dx + a * p.dy + ty);
}

/// 两页特征集配准的完整结论（成功带变换与诊断，失败带原因）。
class FeatureAlignOutcome {
  const FeatureAlignOutcome({
    this.transform,
    required this.refPoints,
    required this.pagePoints,
    required this.totalMatches,
    required this.inliers,
    required this.reason,
  });

  /// 成功时非 null：参考页坐标 → 本页坐标的相似变换。
  final SimilarityTransform? transform;

  final int refPoints;
  final int pagePoints;

  /// 交叉验证后的匹配总数。
  final int totalMatches;

  /// RANSAC 内点数（失败时 0）。
  final int inliers;

  /// 失败原因（成功为空），状态行/日志用。
  final String reason;

  bool get aligned => transform != null;

  double get inlierRatio =>
      totalMatches > 0 ? inliers / totalMatches : 0.0;
}

/// 描述子暴力匹配：双向 Lowe 比值过滤 + 交叉一致。
///
/// **分类型匹配**：交叉点（版式特征，位置型描述子）与字符块（字形
/// 特征，扇区描述子）的描述子语义不同，跨类型距离无意义——按
/// [InkFeaturePoint.type] 分桶后各配各的，匹配表取并集（RANSAC 只看
/// 几何，不关心来源）。每方向对每点找最近/次近两个描述子，最近/次
/// 近 < [ratio] 才算候选（次近存在性由比值分母保证——桶内只有单个
/// 点时无次近，该点不产生匹配，避免孤点强行配对）；两个方向的候选
/// 取交集（ref i 的最近是 page j，且 page j 的最近恰是 ref i）。
List<FeatureMatch> matchFeatures(
  List<InkFeaturePoint> ref,
  List<InkFeaturePoint> page, {
  double ratio = 0.75, // kMatchDefaults.ratioThreshold 同值
}) {
  final out = <FeatureMatch>[];
  for (final type in FeatureType.values) {
    final ri = <int>[
      for (var i = 0; i < ref.length; i++)
        if (ref[i].type == type) i,
    ];
    final pi = <int>[
      for (var j = 0; j < page.length; j++)
        if (page[j].type == type) j,
    ];
    if (ri.length < 2 || pi.length < 2) continue; // 无次近可言，跳过
    // 正向：ref → page。
    final forward = <int, int>{};
    for (final i in ri) {
      var d1 = double.infinity, d2 = double.infinity, best = -1;
      for (final j in pi) {
        final d = _descriptorDistance(ref[i], page[j]);
        if (d < d1) {
          d2 = d1;
          d1 = d;
          best = j;
        } else if (d < d2) {
          d2 = d;
        }
      }
      if (d2 < double.infinity && d1 < ratio * d2) {
        forward[i] = best;
      }
    }
    // 反向：page → ref，然后交叉一致。
    for (final j in pi) {
      var d1 = double.infinity, d2 = double.infinity, best = -1;
      for (final i in ri) {
        final d = _descriptorDistance(page[j], ref[i]);
        if (d < d1) {
          d2 = d1;
          d1 = d;
          best = i;
        } else if (d < d2) {
          d2 = d;
        }
      }
      if (d2 < double.infinity && d1 < ratio * d2) {
        final fwd = forward[best];
        if (fwd != null && fwd == j) {
          out.add(FeatureMatch(best, j, d1));
        }
      }
    }
  }
  return out;
}

/// 两页配准主入口：匹配 → RANSAC → 内点最小二乘精修。
///
/// [random] 供测试注入固定种子；生产留空用系统随机。
FeatureAlignOutcome alignWithFeatures({
  required InkPageFeatures ref,
  required InkPageFeatures page,
  MatchSettings settings = kMatchDefaults,
  math.Random? random,
}) {
  String fail(String reason) => reason;
  if (ref.points.length < 3 || page.points.length < 3) {
    return FeatureAlignOutcome(
      transform: null,
      refPoints: ref.points.length,
      pagePoints: page.points.length,
      totalMatches: 0,
      inliers: 0,
      reason: fail('特征点不足'),
    );
  }
  final matches = matchFeatures(ref.points, page.points,
      ratio: settings.ratioThreshold);
  if (matches.length < settings.minMatches) {
    return FeatureAlignOutcome(
      transform: null,
      refPoints: ref.points.length,
      pagePoints: page.points.length,
      totalMatches: matches.length,
      inliers: 0,
      reason: fail('匹配数不足'),
    );
  }
  final best = _ransacSimilarity(
    matches, ref.points, page.points, settings, random,
  );
  if (best == null || best.inlierCount < settings.minInliers) {
    return FeatureAlignOutcome(
      transform: null,
      refPoints: ref.points.length,
      pagePoints: page.points.length,
      totalMatches: matches.length,
      inliers: best?.inlierCount ?? 0,
      reason: fail(best == null ? '无有效几何解' : '内点不足'),
    );
  }
  // 内点集最小二乘精修：RANSAC 的 2 点解只定骨架，全部内点重拟合
  // 把变换参数摊到亚像素精度。
  final refined = _leastSquaresSimilarity(best.pairs);
  final t = refined ?? best.transform;
  final ratio = best.inlierCount / matches.length;
  String? reason;
  if ((t.scale - 1).abs() > settings.maxScaleDeviation) {
    reason = '尺度异常';
  } else if (ratio < settings.minInlierRatio) {
    reason = '内点比例过低';
  }
  return FeatureAlignOutcome(
    transform: reason == null ? t : null,
    refPoints: ref.points.length,
    pagePoints: page.points.length,
    totalMatches: matches.length,
    inliers: best.inlierCount,
    reason: reason ?? '',
  );
}

// ── 内部 ──

double _descriptorDistance(InkFeaturePoint a, InkFeaturePoint b) {
  final da = a.descriptor, db = b.descriptor;
  var sum = 0.0;
  for (var i = 0; i < da.length; i++) {
    final d = da[i] - db[i];
    sum += d * d;
  }
  return math.sqrt(sum);
}

class _RansacBest {
  const _RansacBest(this.transform, this.pairs, this.inlierCount);
  final SimilarityTransform transform;

  /// 内点对应的（ref, page）坐标对，供精修直接用。
  final List<(Offset, Offset)> pairs;
  final int inlierCount;
}

/// RANSAC 主循环：采 2 对点解相似变换，内点最多者胜出。
_RansacBest? _ransacSimilarity(
  List<FeatureMatch> matches,
  List<InkFeaturePoint> refPts,
  List<InkFeaturePoint> pagePts,
  MatchSettings s,
  math.Random? random,
) {
  final rng = random ?? math.Random();
  _RansacBest? best;
  for (var iter = 0; iter < s.maxIterations; iter++) {
    // 采两对不同的匹配，且参考页两点不能太近（旋转解不稳）。
    final m1 = matches[rng.nextInt(matches.length)];
    var m2 = m1;
    var tries = 0;
    while ((m2.refIndex == m1.refIndex ||
            (refPts[m2.refIndex].position -
                    refPts[m1.refIndex].position)
                .distance <
                s.minSampleDistance) &&
        tries++ < 20) {
      m2 = matches[rng.nextInt(matches.length)];
    }
    if (m2.refIndex == m1.refIndex) continue;
    final r1 = refPts[m1.refIndex].position;
    final p1 = pagePts[m1.pageIndex].position;
    final r2 = refPts[m2.refIndex].position;
    final p2 = pagePts[m2.pageIndex].position;
    final t = _similarityFrom2Pairs(r1, p1, r2, p2);
    if (t == null) continue;

    final pairs = <(Offset, Offset)>[];
    for (final m in matches) {
      final predicted =
          t.apply(refPts[m.refIndex].position);
      if ((predicted - pagePts[m.pageIndex].position).distance <
          s.inlierThreshold) {
        pairs.add((refPts[m.refIndex].position,
            pagePts[m.pageIndex].position));
      }
    }
    if (best == null || pairs.length > best.inlierCount) {
      best = _RansacBest(t, pairs, pairs.length);
    }
    // 内点率超 7 成后再采几乎不可能更好，提前收工。
    if (pairs.length > matches.length * 0.7) break;
  }
  return best;
}

/// 2 对点解析解相似变换：
/// `dx = r2−r1`，`ex = p2−p1` ⇒ `a = (ex·dx + ey·dy)/|dx|²`，
/// `b = (ey·dx − ex·dy)/|dx|²`；平移由第一对点回代。
SimilarityTransform? _similarityFrom2Pairs(Offset r1, Offset p1, Offset r2, Offset p2) {
  final dx = r2.dx - r1.dx, dy = r2.dy - r1.dy;
  final den = dx * dx + dy * dy;
  if (den < 1e-6) return null; // 两点重合，旋转/缩放欠定
  final ex = p2.dx - p1.dx, ey = p2.dy - p1.dy;
  final a = (ex * dx + ey * dy) / den;
  final b = (ey * dx - ex * dy) / den;
  return SimilarityTransform(
    a, b,
    p1.dx - a * r1.dx + b * r1.dy,
    p1.dy - b * r1.dx - a * r1.dy,
  );
}

/// 内点集最小二乘拟合相似变换。设计矩阵每对点两行：
/// x 行 `[x, −y, 1, 0] = x'`，y 行 `[y, x, 0, 1] = y'`——法方程矩阵
/// 是对称正定的 4×4（见各求和项），高斯消元带列主元一次解出。
SimilarityTransform? _leastSquaresSimilarity(List<(Offset, Offset)> pairs) {
  final n = pairs.length;
  if (n < 2) return null;
  var p = 0.0, sx = 0.0, sy = 0.0, q1 = 0.0, q2 = 0.0, sxp = 0.0, syp = 0.0;
  for (final (r, q) in pairs) {
    final x = r.dx, y = r.dy, xp = q.dx, yp = q.dy;
    p += x * x + y * y;
    sx += x;
    sy += y;
    q1 += x * xp + y * yp;
    q2 += x * yp - y * xp;
    sxp += xp;
    syp += yp;
  }
  // 法方程（推导见上）：
  // [p  0  sx  sy][a ]   [q1 ]
  // [0  p −sy  sx][b ]   [q2 ]
  // [sx −sy n  0 ][tx] = [sxp]
  // [sy  sx 0  n ][ty]   [syp]
  final m = [
    p, 0.0, sx, sy, q1,
    0.0, p, -sy, sx, q2,
    sx, -sy, n.toDouble(), 0.0, sxp,
    sy, sx, 0.0, n.toDouble(), syp,
  ];
  final sol = _solve4x5(m);
  if (sol == null) return null;
  return SimilarityTransform(sol[0], sol[1], sol[2], sol[3]);
}

/// 4×4 线性系统 + 右端项（增广 4×5，行主序）高斯消元，列主元。
List<double>? _solve4x5(List<double> m) {
  const n = 4;
  for (var k = 0; k < n; k++) {
    var pivot = k;
    for (var i = k + 1; i < n; i++) {
      if (m[i * (n + 1) + k].abs() > m[pivot * (n + 1) + k].abs()) {
        pivot = i;
      }
    }
    if (m[pivot * (n + 1) + k].abs() < 1e-12) return null; // 奇异
    if (pivot != k) {
      for (var j = k; j <= n; j++) {
        final t = m[k * (n + 1) + j];
        m[k * (n + 1) + j] = m[pivot * (n + 1) + j];
        m[pivot * (n + 1) + j] = t;
      }
    }
    for (var i = k + 1; i < n; i++) {
      final f = m[i * (n + 1) + k] / m[k * (n + 1) + k];
      if (f == 0) continue;
      for (var j = k; j <= n; j++) {
        m[i * (n + 1) + j] -= f * m[k * (n + 1) + j];
      }
    }
  }
  final x = List<double>.filled(n, 0);
  for (var i = n - 1; i >= 0; i--) {
    var sum = m[i * (n + 1) + n];
    for (var j = i + 1; j < n; j++) {
      sum -= m[i * (n + 1) + j] * x[j];
    }
    x[i] = sum / m[i * (n + 1) + i];
  }
  return x;
}
