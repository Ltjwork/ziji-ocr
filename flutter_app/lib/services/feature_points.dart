/// 墨迹特征点提取：叠加对齐（见 ink_align.dart）的特征法数据源，从
/// 单页二值墨迹里提取可配准的离散空间特征——Phase 1 用"连通域质心
/// + 8 扇区密度描述子"的最简组合，特征匹配与 RANSAC 见
/// feature_matching.dart。
///
/// 管线（纸面定位与 Otsu 二值化复用 ink_align 的公开实现）：
/// 1. 纸面矩形 + 内缩（页缘阴影/装订暗边不算墨）→ 纸内 Otsu 阈值。
/// 2. 纸内墨迹像素映射到工作画布光栅（与 [analyzeInkPage] 同口径，
///    含底部页码带排除——页码每页文字不同，是配准噪声不是特征）。
/// 3. 连通域标记（迭代洪泛，8 连通）→ 按面积过滤出"文字块"级组件
///    （小如噪点/标点、大如整片污损的都不要）。
/// 4. 每块质心为特征点，周围窗口按 8 扇区统计墨迹密度 → L2 归一化
///    描述子。描述子只依赖墨迹的方位分布，对扫描亮度/对比度不敏感。
///
/// 与投影法的本质区别：特征点是分布在页面上的离散锚点（每块一个），
/// 不存在投影直方图的周期回声结构——列距错一格的"假峰"问题从源头
/// 消除；个别块缺失/污损只减少特征点数，不污染其余特征的坐标。
///
/// 坐标口径：与 [analyzeInkPage] 完全一致——[fit] 为图 contain 进工
/// 作画布的矩形，特征位置已是工作画布坐标（宽 [InkAlignSettings.
/// workWidth]），平移换算到叠加画布由消费方乘 canvasScale。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect, Size;

import 'ink_align.dart';

/// 特征点来源（Phase 1 仅质心；Harris 角点/界栏交叉点 Phase 2 引入）。
enum FeatureType { centroid, corner, junction }

/// 单个墨迹特征点（工作画布坐标）。
class InkFeaturePoint {
  const InkFeaturePoint({
    required this.position,
    required this.response,
    required this.descriptor,
    this.type = FeatureType.centroid,
  });

  /// 特征位置：连通域质心（像素重心，亚像素精度）。
  final Offset position;

  /// 特征强度：质心取连通域面积（面积大的块重心定位更稳，匹配时可
  /// 优先采信）。
  final double response;

  /// 8 扇区密度描述子（L2 归一化，长度 8，见
  /// [FeatureSettings.descriptorWindow]）。
  final Float64List descriptor;

  final FeatureType type;
}

/// 单页特征集（工作画布坐标），特征法对齐的输入单元——地位等价于
/// 投影法的 [InkPageProfile]。
class InkPageFeatures {
  const InkPageFeatures({
    required this.points,
    required this.paperCenter,
    required this.inkPoints,
    this.angle = 0,
  });

  /// 按面积降序的特征点（上限 [FeatureSettings.maxPoints]）。有格页
  /// 交叉点在前；位置已按 [angle] 去旋转（见 angle 注释）。
  final List<InkFeaturePoint> points;

  /// 纸面矩形中心（工作画布坐标）：与 [InkPageProfile.paperCenter]
  /// 同义，两页纸心差是真实平移的物理先验。
  final Offset paperCenter;

  /// 进入光栅的墨迹像素数（底部页码带已排除）。0 = 该页不可分析
  /// （近空白/墨迹占比异常/无法二值化），与投影法口径一致。
  final int inkPoints;

  /// 页面自身偏转角（弧度，工作画布坐标）：有格页由界栏线斜率估计
  ///（每条线上/下半段质心的横移即倾角），无格页 0（小角度由匹配
  /// 层的相似变换直接吸收）。语义与 [InkPageProfile.angle] 一致，
  /// [points] 已绕画布中心旋转 −angle 拉正——投影塌缩会把旋转熨平
  ///（旋转页的交叉点网格仍是正交网格），不先去旋转则角度信息只在
  /// 线斜率里、进不了匹配层。
  final double angle;
}

/// 特征提取可调参数（默认值按 600 宽工作画布标定，与
/// [kInkAlignDefaults] 的 workWidth 配套）。
class FeatureSettings {
  const FeatureSettings({
    this.minComponentArea = 200,
    this.maxComponentArea = 5000,
    this.descriptorWindow = 40,
    this.maxPoints = 800,
    this.lineMinRunRatio = 0.10,
    this.closingRadius = 0,
    this.lineMinCoverage = 0.35,
    this.lineBandMaxWidth = 12,
  });

  /// 连通域面积下限（工作像素）：滤掉噪点与小标点——它们的质心
  /// 位置不稳定（一点污损就漂移），进了匹配是纯噪声。
  final int minComponentArea;

  /// 连通域面积上限：整片污损/多字粘连的大块重心不代表任何稳定
  /// 结构，同样不配做锚点。
  final int maxComponentArea;

  /// 描述子窗口边长（工作像素，实际采样 41×41）：须大于单字尺度
  ///（吃到字的完整方位分布）、小于两倍列距（不吃到邻列）。古籍
  /// 600px 宽下列距约 50-60px、字高 26-40px，40 是安全中值。
  final int descriptorWindow;

  /// 单页特征点上限（超出的按面积弃小保大，控制匹配 O(k²) 开销）。
  final int maxPoints;

  /// 界栏直线移除阈值（占 min(宽,高) 比例）：纵横连续墨迹段长 ≥ 该
  /// 值按"格线"清除。刻本的界栏/边框/行格会把整列字符织成一个巨
  /// 型连通域（实测 13k+ 像素，远超 [maxComponentArea]），不移除则
  /// 无一字符能成为特征。字符笔画最长不过字高（≤1/10 画布），该比
  /// 例与笔画尺度之间有两个数量级的安全裕度。
  final double lineMinRunRatio;

  /// 闭运算半径（像素，默认 0=关）：膨胀+腐蚀桥接 ≤2r 的笔画裂缝。
  /// 真实刻本（600px 宽）列距常只有 3-5px，r=1 会把相邻字/整列焊成
  /// 超面积上限的大块（实测某刻本特征数 44 → 0），默认关闭，仅确知
  /// 版式稀疏时手动开启。
  final int closingRadius;

  /// 格线的最低投影覆盖率（占画布另一轴长度）：真界栏/边框至少纵贯
  /// 版心的大半，文字列的投影到不了这个高度——是"线 vs 文字列"的第
  /// 一道判据。
  final double lineMinCoverage;

  /// 格线检测的带宽上限（像素）：线在投影上是窄尖峰（含 ±1° 偏转的
  /// 漂移也就十来像素），文字列是宽包络（一个字宽 25px+）——带宽是
  /// "线 vs 文字列"的决定性判据。
  final int lineBandMaxWidth;
}

const FeatureSettings kFeatureDefaults = FeatureSettings();

/// RGBA（每像素 4 字节，直排）解码图的特征提取。参数语义与
/// [analyzeInkPage] 一致：[fit] 为该图 contain 进 [workCanvas] 的
/// 矩形。不可分析（空白/占比异常/二值化失败）返回 [InkPageFeatures]
/// 的空集（inkPoints = 0），不抛异常。
InkPageFeatures extractFeaturePoints({
  required Uint8List rgba,
  required int imgW,
  required int imgH,
  required Rect fit,
  required Size workCanvas,
  FeatureSettings settings = kFeatureDefaults,
  InkAlignSettings alignSettings = kInkAlignDefaults,
}) {
  final paper = paperBounds(rgba, imgW, imgH, alignSettings);
  final paperCenter = Offset(
    fit.left + paper.center.dx * (fit.width / math.max(imgW, 1)),
    fit.top + paper.center.dy * (fit.height / math.max(imgH, 1)),
  );
  InkPageFeatures unusable() => InkPageFeatures(
        points: const [],
        paperCenter: paperCenter,
        inkPoints: 0,
      );

  final threshold = otsuThreshold(rgba, imgW, imgH, paper);
  if (threshold <= 0) {
    return unusable();
  }
  // 工作画布光栅：纸内（内缩后）、页码带以上的墨迹置 1。坐标映射
  // 与 analyzeInkPage 同一公式，两法的"哪些像素算墨"完全重合。
  final w = math.max(1, workCanvas.width.round());
  final h = math.max(1, workCanvas.height.round());
  final bitmap = Uint8List(w * h);
  final kx = fit.width / math.max(imgW, 1);
  final ky = fit.height / math.max(imgH, 1);
  final bandY = fit.top +
      (paper.bottom - paper.height * alignSettings.pageNumberBandRatio) * ky;
  final x0 = (paper.left + paper.width * alignSettings.paperShrinkRatio).round();
  final x1 =
      (paper.right - paper.width * alignSettings.paperShrinkRatio).round();
  final y0 = (paper.top + paper.height * alignSettings.paperShrinkRatio).round();
  final y1 =
      (paper.bottom - paper.height * alignSettings.paperShrinkRatio).round();
  var ink = 0, total = 0;
  for (var y = math.max(0, y0); y < math.min(imgH, y1); y++) {
    for (var x = math.max(0, x0); x < math.min(imgW, x1); x++) {
      final i = (y * imgW + x) * 4;
      final lum = (rgba[i] * 77 + rgba[i + 1] * 150 + rgba[i + 2] * 29) >> 8;
      total++;
      // Otsu 语义：≤ 阈值属暗类（墨），与 analyzeInkPage 一致。
      if (lum <= threshold) {
        ink++;
        final wy = fit.top + y * ky;
        if (wy < bandY) {
          final wx = (fit.left + x * kx).round().clamp(0, w - 1);
          final wyi = wy.round().clamp(0, h - 1);
          bitmap[wyi * w + wx] = 1;
        }
      }
    }
  }
  // 与投影法同两道防线：墨迹太少（章首/扉页无结构可配准）、占比异常
  //（反向图/整页污损）都按不可分析退回。
  if (ink < alignSettings.minInkPoints || (total > 0 && ink / total > 0.45)) {
    return unusable();
  }

  // 界栏处理三步（顺序不可换）：
  // 1. 先在原始光栅上检测长直线（界栏/边框/行格）——真实古籍逐页
  //    文字不同，字形块跨页大多匹配不上；版式格线是刚体印刷，跨页
  //    稳定，其交叉点才是刻本类页面的主力特征（描述子 = 纸面归一
  //    化位置：同版式的同一格点两页同值，相邻格点差 ≥ 一个格距）。
  // 2. 再把线像素从光栅清除——格线会把整列字符织成巨型连通域（实
  //    测 13k+ 像素），不清除则无一字符能成为块特征。
  // 3. 字符块特征在清线后的光栅上提取（字形描述子），与交叉点特征
  //    互补：无格版式（白文/写本）全靠它。
  final minRun =
      math.max(60, (math.min(w, h) * settings.lineMinRunRatio).round());
  var vLines = _detectLines(
    bitmap, w, h, settings.lineMinCoverage, settings.lineBandMaxWidth, true);
  var hLines = _detectLines(
    bitmap, w, h, settings.lineMinCoverage, settings.lineBandMaxWidth, false);
  // 每条线的分段峰位置线性拟合（段内取线宽方向墨迹峰列 + 抛物线亚
  // 像素，抗字形笔画污染）。拟合一鱼两吃：斜率 → 页面自转角（诊断
  // 上报）；插值 → 交叉点的真实局部位置（塌缩均值位置与真交点差
  // ±1.5px，用对方向在交点高度/横坐标处的插值位置代替，交叉点由此
  // 自带正确的旋转几何，配准层无需再做角度复合）。
  var vFits = _fitLines(bitmap, w, h, vLines, true);
  var hFits = _fitLines(bitmap, w, h, hLines, false);
  // 纸面矩形映射到工作画布（交叉点描述子的归一化基准）。
  final paperFit = Rect.fromLTRB(
    fit.left + paper.left * kx,
    fit.top + paper.top * ky,
    fit.left + paper.right * kx,
    fit.top + paper.bottom * ky,
  );
  // 线清除两步：投影带清除（检测到的线整带擦除，±2px 容漂移）+
  // 长 run 清除（漏检的线段残臂）。都为把字符从格网上断开。
  _removeLineBands(bitmap, w, h, vLines, true);
  _removeLineBands(bitmap, w, h, hLines, false);
  _removeLongRuns(bitmap, w, h, minRun);
  // 白文兜底：无格线（或只剩单向）时，文字列/行的墨迹密度带就是
  // "虚拟格线"——投影法正是靠这个结构对齐白文页的（实测小字刻本
  // 逐页连通域全数 <200px、无任何格线，字块与界栏特征双双为零）。
  // 虚拟线与真界栏走同一套交点/插值机制。须在清线之后做（真界栏
  // 的残墨会伪造带），且双向各 ≥3 条带才启用——稀疏页（扉页/示意
  // 图）的孤立墨团不配当版式结构。
  if (vLines.length < 2 || hLines.length < 2) {
    if (vLines.length < 2) {
      final dv = _densityLines(bitmap, w, h, true);
      if (dv.lines.length >= 3) {
        vLines = dv.lines;
        vFits = dv.fits;
      }
    }
    if (hLines.length < 2) {
      final dh = _densityLines(bitmap, w, h, false);
      if (dh.lines.length >= 3) {
        hLines = dh.lines;
        hFits = dh.fits;
      }
    }
  }
  final junctions = <InkFeaturePoint>[];
  for (final v in vLines) {
    for (final hq in hLines) {
      if (hq.pos < v.lo || hq.pos > v.hi || v.pos < hq.lo || v.pos > hq.hi) {
        continue;
      }
      // 真交点估计：先取 v 线在 h 线塌缩高度处的 x，再用该 x 反代 h
      // 拟合取 y（一次迭代，修正量已是 ψ² 级）。
      final x1 = vFits[v]?.posAt(hq.pos) ?? v.pos;
      final y1 = hFits[hq]?.posAt(x1) ?? hq.pos;
      junctions.add(
          _junctionFeature(Offset(x1, y1), paperFit, v.weight + hq.weight));
    }
  }
  // 页面自转角（诊断口径上报，见 InkPageFeatures.angle 注释；配准几
  // 何已由插值交点自带，不参与变换复合）。
  final angle = junctions.isNotEmpty
      ? _rotationFromFits(vFits, hFits, vLines, hLines)
      : 0.0;
  var raster = bitmap;
  if (settings.closingRadius > 0) {
    raster = _closing(bitmap, w, h, settings.closingRadius);
  }

  final comps = _connectedComponents(raster, w, h);
  final kept = <_Component>[];
  for (final c in comps) {
    if (c.area >= settings.minComponentArea &&
        c.area <= settings.maxComponentArea) {
      kept.add(c);
    }
  }
  // 块特征按面积降序 + 上限裁剪（大块重心稳，优先保留）；交叉点在
  // 前（版式特征，跨页稳定优先采信），[maxPoints] 只裁块特征——格点
  // 数 = 版式自由度，全用。
  kept.sort((a, b) => b.area.compareTo(a.area));
  if (kept.length > settings.maxPoints) {
    kept.removeRange(settings.maxPoints, kept.length);
  }

  final points = <InkFeaturePoint>[
    ...junctions,
    for (final c in kept)
      InkFeaturePoint(
        position: Offset(c.sumX / c.area, c.sumY / c.area),
        response: c.area.toDouble(),
        descriptor: _sectorDescriptor(
          raster, w, h,
          Offset(c.sumX / c.area, c.sumY / c.area),
          settings.descriptorWindow,
        ),
      ),
  ];
  return InkPageFeatures(
    points: points,
    paperCenter: paperCenter,
    inkPoints: ink,
    angle: angle,
  );
}

// ── 内部 ──

/// 一条检测出的格线：[pos] 为横向坐标（竖线）或纵向坐标（横线），
/// [lo]/[hi] 为另一轴上的延伸范围，[weight] 为线上的墨迹像素量。
class _Line {
  _Line(this.pos, this.lo, this.hi, this.weight);
  final double pos;
  final int lo;
  final int hi;
  final double weight;
}

/// 投影带式格线检测（对 ±1° 偏转稳健——细线偏转后每列 run 只剩线
/// 宽，逐列 run 检测会漏，投影上仍是尖峰）：
/// 1. 沿检测方向的垂直轴求投影（每列/行墨迹计数）。
/// 2. 高于 max(全局峰×0.5, 轴长×[InkAlignSettings 侧的
///    lineMinCoverage]) 的列聚成候选带。
/// 3. 带宽 ≤ [lineBandMaxWidth] 才是线——文字列投影虽也高，但包络
///    有一个字宽（25px+）。线位置取带内按投影加权的均值（亚像素）。
List<_Line> _detectLines(
  Uint8List b,
  int w,
  int h,
  double minCoverage,
  int maxWidth,
  bool vertical,
) {
  final outer = vertical ? w : h;
  final inner = vertical ? h : w;
  final proj = List<double>.filled(outer, 0);
  for (var o = 0; o < outer; o++) {
    var sum = 0.0;
    for (var i = 0; i < inner; i++) {
      sum += b[vertical ? i * w + o : o * w + i];
    }
    proj[o] = sum;
  }
  var maxProj = 0.0;
  for (final v in proj) {
    if (v > maxProj) maxProj = v;
  }
  final cut = math.max(maxProj * 0.5, inner * minCoverage);
  if (cut <= 0) return const [];
  final lines = <_Line>[];
  var bandStart = -1;
  for (var o = 0; o <= outer; o++) {
    final on = o < outer && proj[o] >= cut;
    if (on && bandStart < 0) bandStart = o;
    if (!on && bandStart >= 0) {
      final bandEnd = o - 1;
      if (bandEnd - bandStart + 1 <= maxWidth) {
        // 线位置 = 带内投影加权均值；延伸 = 带内墨迹极值。
        var wsum = 0.0, psum = 0.0;
        var lo = inner, hi = 0;
        for (var p = bandStart; p <= bandEnd; p++) {
          wsum += proj[p];
          psum += p * proj[p];
          for (var i = 0; i < inner; i++) {
            if (b[vertical ? i * w + p : p * w + i] == 1) {
              if (i < lo) lo = i;
              if (i > hi) hi = i;
            }
          }
        }
        lines.add(_Line(psum / wsum, lo, hi, wsum));
      }
      bandStart = -1;
    }
  }
  return lines;
}

/// 密度带虚拟格线（白文兜底）：文字列/行在投影上是一串宽峰（列距
/// 为周期），把每段页面的投影峰链接成"虚拟线"——与真界栏同构
///（[_Line]），下游交点/插值全套复用。
///
/// 做法：把页面沿延伸轴分 3 段，每段独立求投影峰（平滑 5 + 高度阈
/// 值 + 间距 ≥15px），相邻段峰按就近（≤10px）链起来；链中心 = 各段
/// 峰的均值。**拟合直接由链上的段峰位置回归得出**——[_fitLines] 的
/// ±3px 带窗是为 1-2px 界栏线设计的，密度带 25px+ 宽且偏转下整带
/// 漂移十几像素，带窗会把斜率信号截掉（系统性欠旋转）。链跨 ≥2 段
/// 滤掉只在一处出现的偶然墨团。
({List<_Line> lines, Map<_Line, _LineFit> fits}) _densityLines(
  Uint8List b,
  int w,
  int h,
  bool vertical,
) {
  final outer = vertical ? w : h;
  final inner = vertical ? h : w;
  const tiles = 3;
  final tilePeaks = <List<double>>[];
  for (var t = 0; t < tiles; t++) {
    final i0 = (inner * t / tiles).floor();
    final i1 = (inner * (t + 1) / tiles).floor();
    final proj = List<double>.filled(outer, 0);
    for (var i = i0; i < i1; i++) {
      for (var o = 0; o < outer; o++) {
        if (b[vertical ? i * w + o : o * w + i] == 1) proj[o] += 1;
      }
    }
    // 平滑窗 5。
    final sm = List<double>.filled(outer, 0);
    for (var o = 0; o < outer; o++) {
      var sum = 0.0;
      var cnt = 0;
      for (var d = -2; d <= 2; d++) {
        final oo = o + d;
        if (oo < 0 || oo >= outer) continue;
        sum += proj[oo];
        cnt++;
      }
      sm[o] = sum / cnt;
    }
    var mx = 0.0;
    for (final v in sm) {
      if (v > mx) mx = v;
    }
    if (mx < 18) {
      tilePeaks.add(const []);
      continue; // 该段近乎空白
    }
    final cut = mx * 0.30;
    final peaks = <double>[];
    for (var o = 2; o < outer - 2; o++) {
      if (sm[o] < cut || sm[o] < sm[o - 1] || sm[o] < sm[o + 1]) continue;
      if (peaks.isNotEmpty && o - peaks.last < 15) {
        // 同一周期内的次峰：只留高者。
        if (sm[o] > sm[peaks.last.toInt()]) {
          peaks.removeLast();
        } else {
          continue;
        }
      }
      peaks.add(o.toDouble());
    }
    tilePeaks.add(peaks);
  }
  // 相邻段就近链接成链：每链是 (段号, 峰位置) 的扁平序列，段号随链
  // 携带（拟合需要段中心做自变量）。
  if (tilePeaks.first.isEmpty) {
    return (lines: const <_Line>[], fits: const <_Line, _LineFit>{});
  }
  final chains = <List<int>>[];
  for (final p in tilePeaks.first) {
    chains.add([0, p.toInt()]);
  }
  for (var t = 1; t < tiles; t++) {
    for (final chain in chains) {
      final lastPos = chain[chain.length - 1].toDouble();
      var best = -1.0;
      var bestD = 11.0;
      for (final q in tilePeaks[t]) {
        final d = (q - lastPos).abs();
        if (d < bestD) {
          bestD = d;
          best = q;
        }
      }
      if (best >= 0) {
        chain.addAll([t, best.toInt()]);
      }
    }
  }
  final lines = <_Line>[];
  final fits = <_Line, _LineFit>{};
  for (final chain in chains) {
    if (chain.length < 4) continue; // <2 段（每段占 2 个元素），偶然墨团
    final ys = <double>[], ps = <double>[];
    for (var k = 0; k < chain.length; k += 2) {
      ys.add((chain[k] + 0.5) * inner / tiles);
      ps.add(chain[k + 1].toDouble());
    }
    var my = 0.0, mp = 0.0;
    for (var k = 0; k < ys.length; k++) {
      my += ys[k];
      mp += ps[k];
    }
    my /= ys.length;
    mp /= ps.length;
    var cov = 0.0, varY = 0.0;
    for (var k = 0; k < ys.length; k++) {
      cov += (ys[k] - my) * (ps[k] - mp);
      varY += (ys[k] - my) * (ys[k] - my);
    }
    final slope = varY > 1e-9 ? cov / varY : 0.0;
    final line = _Line(mp, 0, inner - 1, ys.length * 30.0);
    lines.add(line);
    fits[line] = _LineFit(slope, mp - slope * my);
  }
  return (lines: lines, fits: fits);
}

/// 一条线的分段峰位置线性拟合：`p = slope·i + intercept`（p 为线宽
/// 方向位置，i 为延伸方向坐标）。
class _LineFit {
  const _LineFit(this.slope, this.intercept);
  final double slope;
  final double intercept;
  double posAt(double i) => slope * i + intercept;
}

/// 每条线的分段拟合：沿延伸轴分 6 段，段内取线宽方向的墨迹峰列
///（抛物线亚像素插值——均值会被带内混入的字形笔画拉偏，峰钉在
/// 线的窄尖峰上），最小二乘回归。对检测带两端的跨度截断免疫。
Map<_Line, _LineFit> _fitLines(
  Uint8List b,
  int w,
  int h,
  List<_Line> lines,
  bool vertical,
) {
  final outer = vertical ? w : h;
  final fits = <_Line, _LineFit>{};
  for (final ln in lines) {
    final span = ln.hi - ln.lo;
    if (span < 100) continue;
    const tiles = 6;
    final tileLen = span / tiles;
    if (tileLen < 30) continue;
    final cx = ln.pos.round();
    final bandLo = math.max(0, cx - 3);
    final bandHi = math.min(outer - 1, cx + 3);
    final bandW = bandHi - bandLo + 1;
    final ys = <double>[], ps = <double>[];
    final cols = List<double>.filled(bandW, 0);
    for (var t = 0; t < tiles; t++) {
      final i0 = (ln.lo + t * tileLen).ceil();
      final i1 = math.min(ln.hi, (ln.lo + (t + 1) * tileLen).floor());
      for (var k = 0; k < bandW; k++) {
        cols[k] = 0;
      }
      for (var i = i0; i <= i1; i++) {
        for (var p = bandLo; p <= bandHi; p++) {
          if (b[vertical ? i * w + p : p * w + i] == 1) {
            cols[p - bandLo] += 1;
          }
        }
      }
      var peak = 0;
      var total = 0.0;
      for (var k = 0; k < bandW; k++) {
        total += cols[k];
        if (cols[k] > cols[peak]) peak = k;
      }
      if (total < 30) continue; // 段内墨迹太少，峰不可信
      var sub = 0.0;
      if (peak > 0 && peak < bandW - 1) {
        final cl = cols[peak - 1], cc = cols[peak], cr = cols[peak + 1];
        final denom = cl - 2 * cc + cr;
        if (denom < -1e-9) sub = 0.5 * (cl - cr) / denom;
      }
      ys.add((i0 + i1) / 2.0);
      ps.add(bandLo + peak + sub);
    }
    if (ys.length < 3) continue;
    var my = 0.0, mp = 0.0;
    for (var k = 0; k < ys.length; k++) {
      my += ys[k];
      mp += ps[k];
    }
    my /= ys.length;
    mp /= ys.length;
    var cov = 0.0, varY = 0.0;
    for (var k = 0; k < ys.length; k++) {
      cov += (ys[k] - my) * (ps[k] - mp);
      varY += (ys[k] - my) * (ys[k] - my);
    }
    if (varY < 1e-9) continue;
    final slope = cov / varY;
    fits[ln] = _LineFit(slope, mp - slope * my);
  }
  return fits;
}

/// 页面偏转角（弧度，诊断口径）：竖线 dx/dy = −tanψ，横线 dy/dx =
/// tanψ（y 轴向下），全部线取中位数。
double _rotationFromFits(
  Map<_Line, _LineFit> vFits,
  Map<_Line, _LineFit> hFits,
  List<_Line> vLines,
  List<_Line> hLines,
) {
  final slopes = <double>[];
  for (final v in vLines) {
    final f = vFits[v];
    if (f != null) slopes.add(-math.atan(f.slope));
  }
  for (final hq in hLines) {
    final f = hFits[hq];
    if (f != null) slopes.add(math.atan(f.slope));
  }
  if (slopes.length < 2) return 0;
  slopes.sort();
  return slopes[slopes.length ~/ 2];
}

/// 界栏交叉点特征：描述子 = 纸面归一化位置（nx, ny 占描述子前两维，
/// 其余为 0）。同版式两页的同一格点 nx/ny 几乎相同（印刷刚性，残余
/// 差来自纸面定位误差，远小于一个格距），相邻格点差 ≥ 1/格数——比
/// 值测试可分。位置进描述子看似"用答案抄答案"，实则只是数据关联
/// 先验：RANSAC 仍以几何一致性独立裁决每个对应。
InkFeaturePoint _junctionFeature(
  Offset p,
  Rect paperFit,
  double weight,
) {
  final d = Float64List(8);
  d[0] = ((p.dx - paperFit.left) / math.max(paperFit.width, 1)).clamp(0.0, 1.0);
  d[1] = ((p.dy - paperFit.top) / math.max(paperFit.height, 1))
      .clamp(0.0, 1.0);
  return InkFeaturePoint(
    position: p,
    response: weight,
    descriptor: d,
    type: FeatureType.junction,
  );
}

/// 检测带的整带清除：线位置 ±2px、延伸范围内的墨迹清零——把字符
/// 与格网的连接处切断（8 连通经带内像素粘连是格网吞字的机理）。
void _removeLineBands(
  Uint8List b,
  int w,
  int h,
  List<_Line> lines,
  bool vertical,
) {
  final outer = vertical ? w : h;
  final inner = vertical ? h : w;
  for (final ln in lines) {
    final center = ln.pos.round();
    final lo = math.max(0, center - 2), hi = math.min(outer - 1, center + 2);
    final ilo = math.max(0, ln.lo), ihi = math.min(inner - 1, ln.hi);
    for (var o = lo; o <= hi; o++) {
      for (var i = ilo; i <= ihi; i++) {
        b[vertical ? i * w + o : o * w + i] = 0;
      }
    }
  }
}

/// 界栏直线移除：逐列/逐行找连续墨迹段，长度 ≥ [minRun] 的按格线
/// 清零。竖线（界栏/边框）与横线（行格/鱼尾底线）都吃这条规则；
/// 字符笔画的最长延伸是字高，远低于该阈值。
void _removeLongRuns(Uint8List b, int w, int h, int minRun) {
  for (var x = 0; x < w; x++) {
    var start = -1;
    for (var y = 0; y <= h; y++) {
      final on = y < h && b[y * w + x] == 1;
      if (on && start < 0) start = y;
      if (!on && start >= 0) {
        if (y - start >= minRun) {
          for (var yy = start; yy < y; yy++) {
            b[yy * w + x] = 0;
          }
        }
        start = -1;
      }
    }
  }
  for (var y = 0; y < h; y++) {
    var start = -1;
    for (var x = 0; x <= w; x++) {
      final on = x < w && b[y * w + x] == 1;
      if (on && start < 0) start = x;
      if (!on && start >= 0) {
        if (x - start >= minRun) {
          for (var xx = start; xx < x; xx++) {
            b[y * w + xx] = 0;
          }
        }
        start = -1;
      }
    }
  }
}

/// 闭运算（膨胀 → 腐蚀，方形结构元，水平/垂直分离两趟实现）：
/// 桥接 ≤2r 的笔画裂缝，不整体改变形状与面积量级。
Uint8List _closing(Uint8List src, int w, int h, int r) {
  final dilated = _dilate(_dilate(src, w, h, r, true), w, h, r, false);
  return _erode(_erode(dilated, w, h, r, true), w, h, r, false);
}

/// 膨胀一趟。[horizontal] 决定本趟沿 x（先横后纵等价于方形元）。
Uint8List _dilate(Uint8List src, int w, int h, int r, bool horizontal) {
  final out = Uint8List(src.length);
  if (horizontal) {
    for (var y = 0; y < h; y++) {
      final row = y * w;
      for (var x = 0; x < w; x++) {
        if (src[row + x] == 1) {
          final lo = math.max(0, x - r), hi = math.min(w - 1, x + r);
          for (var xx = lo; xx <= hi; xx++) {
            out[row + xx] = 1;
          }
        }
      }
    }
  } else {
    for (var x = 0; x < w; x++) {
      for (var y = 0; y < h; y++) {
        if (src[y * w + x] == 1) {
          final lo = math.max(0, y - r), hi = math.min(h - 1, y + r);
          for (var yy = lo; yy <= hi; yy++) {
            out[yy * w + x] = 1;
          }
        }
      }
    }
  }
  return out;
}

/// 腐蚀一趟（窗口内全为墨才保留），与 [_dilate] 同分离结构。
Uint8List _erode(Uint8List src, int w, int h, int r, bool horizontal) {
  final out = Uint8List(src.length);
  if (horizontal) {
    for (var y = 0; y < h; y++) {
      final row = y * w;
      for (var x = 0; x < w; x++) {
        var all = true;
        final lo = math.max(0, x - r), hi = math.min(w - 1, x + r);
        for (var xx = lo; xx <= hi; xx++) {
          if (src[row + xx] == 0) {
            all = false;
            break;
          }
        }
        out[row + x] = all ? 1 : 0;
      }
    }
  } else {
    for (var x = 0; x < w; x++) {
      for (var y = 0; y < h; y++) {
        var all = true;
        final lo = math.max(0, y - r), hi = math.min(h - 1, y + r);
        for (var yy = lo; yy <= hi; yy++) {
          if (src[yy * w + x] == 0) {
            all = false;
            break;
          }
        }
        out[y * w + x] = all ? 1 : 0;
      }
    }
  }
  return out;
}

/// 连通域统计：面积与坐标和（质心 = 坐标和 / 面积）。
class _Component {
  int area = 0;
  double sumX = 0;
  double sumY = 0;
}

/// 二值光栅的连通域标记（迭代洪泛，8 连通，显式栈避免深递归）。
/// 墨迹通常只占画布 10-20%，只访问墨迹像素比两遍全扫快且省一个
/// 标签并查集。
List<_Component> _connectedComponents(Uint8List bitmap, int w, int h) {
  final visited = Uint8List(bitmap.length);
  final comps = <_Component>[];
  final stack = <int>[];
  for (var start = 0; start < bitmap.length; start++) {
    if (bitmap[start] == 0 || visited[start] != 0) continue;
    final comp = _Component();
    stack.add(start);
    visited[start] = 1;
    while (stack.isNotEmpty) {
      final p = stack.removeLast();
      final px = p % w, py = p ~/ w;
      comp.area++;
      comp.sumX += px;
      comp.sumY += py;
      for (var dy = -1; dy <= 1; dy++) {
        final ny = py + dy;
        if (ny < 0 || ny >= h) continue;
        for (var dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = px + dx;
          if (nx < 0 || nx >= w) continue;
          final np = ny * w + nx;
          if (bitmap[np] == 1 && visited[np] == 0) {
            visited[np] = 1;
            stack.add(np);
          }
        }
      }
    }
    comps.add(comp);
  }
  return comps;
}

/// 8 扇区墨迹密度描述子：质心周围 windowSize×windowSize（实际
/// 41×41 含中心）窗口内，按方位角 45° 一扇统计墨迹像素数，L2 归一。
/// 方位分布是字符形状的粗签名——同版式页的同位置块签名相近，位置
/// 错位的块签名不同；纯密度统计对亮度/对比度天然免疫。小角度旋转
///（扫描偏转 ≤6°）只把扇区边界附近的小部分像素挪到相邻扇区，签名
/// 扰动有限，由匹配层的距离比测试吸收。
Float64List _sectorDescriptor(
  Uint8List bitmap,
  int w,
  int h,
  Offset center,
  int windowSize,
) {
  final half = math.max(1, windowSize ~/ 2);
  final counts = Float64List(8);
  final cx = center.dx, cy = center.dy;
  for (var dy = -half; dy <= half; dy++) {
    final y = (cy + dy).round();
    if (y < 0 || y >= h) continue;
    for (var dx = -half; dx <= half; dx++) {
      final x = (cx + dx).round();
      if (x < 0 || x >= w) continue;
      if (bitmap[y * w + x] == 0) continue;
      // atan2(dy, dx) ∈ (−π, π] → 平移到 [0, 2π) → 8 等分扇区。
      final sector =
          (((math.atan2(dy.toDouble(), dx.toDouble()) + math.pi) /
                  (2 * math.pi)) *
              8)
              .floor() %
          8;
      counts[sector] += 1;
    }
  }
  var norm = 0.0;
  for (final v in counts) {
    norm += v * v;
  }
  norm = math.sqrt(norm);
  if (norm > 1e-9) {
    for (var i = 0; i < 8; i++) {
      counts[i] /= norm;
    }
  }
  return counts;
}
