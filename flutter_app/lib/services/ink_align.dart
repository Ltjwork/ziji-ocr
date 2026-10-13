/// 叠加合成的墨迹对齐：把参与叠加的各页按"墨迹投影"互相配准，吸收
/// 扫描平移与小角度偏转，让同一版式的页文字在叠加画布上重合。
///
/// 管线（全部纯 Dart，无后端参与）：
/// 1. [analyzeInkPage]——解码图（RGBA）→ 纸面定位（亮度分位定纸白，
///    行/列近纸白占比围成纸面矩形；扫描背景贴画面边框每页同位，不
///    过滤会把互相关锚死在零偏移）→ 纸内 Otsu 二值墨迹 → 像素映射
///    到工作画布（叠加画布的 1/2）→ 旋转扫描估计页面自身的偏转角
///    （行/列投影"锐度"最大的角度 = 文本轴拉正角）→ 在该角度下重建
///    去旋转的 x/y 投影直方图。纸底条带（页码区）不进投影：页码每
///    页文字不同，是配准噪声不是特征。
/// 2. [computeInkAlignments]——取墨迹量中位数的页当参考，逐页与参考
///    页做投影互相关（Pearson，含亚像素抛物线插值）求平移；相关峰
///    显著性即置信度，不足的页退回不偏移。全部对齐后平移取中位归零
///    （合成整体居中不漂）。
/// 3. [OverlayInkTransform]——把"绕画布中心旋转 α + 平移 t + 全局统一
///    缩放 S"封装成可逆变换，画页（正向）与写回框（逆向）共用同一
///    套矩阵，保证画布上看着对齐的框换算回各页像素仍然准确。
///
/// 坐标口径：分析在工作画布（宽 [InkAlignSettings.workWidth]），绘制
/// 与写回在叠加画布（宽 = 工作宽 × canvasScale）。角度在两套口径下相
/// 同（均匀缩放不改变角度），平移按 canvasScale 放大。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect, Size;

import 'feature_matching.dart';
import 'feature_points.dart';

/// 可调参数集中地（默认值按 1200 宽叠加画布 / 600 宽工作画布标定）。
class InkAlignSettings {
  const InkAlignSettings({
    this.workWidth = 600,
    this.maxShift = 80,
    this.maxAngleRad = 6.0 * math.pi / 180.0,
    this.minInkPoints = 800,
    this.minConfidenceX = 0.30,
    this.minConfidenceY = 0.22,
    this.profileHighPassWindow = 21,
    this.maxAnglePoints = 50000,
    this.pageNumberBandRatio = 0.06,
    this.paperBrightSlack = 25,
    this.paperRowBrightRatio = 0.35,
    this.paperShrinkRatio = 0.015,
    this.priorRadius = 40,
    this.escapeFloor = 0.15,
    this.escapeMin = 0.45,
  });

  /// 分析用工作画布宽（叠加画布的一半）：角度/平移的估计精度对叠加
  /// 显示足够，解码与扫描的开销只有整幅的 1/4。
  final int workWidth;

  /// 互相关平移搜索半径（工作像素）：超出视为不可信（真实版式差或
  /// 估计发散），按低置信度退回不偏移。
  final int maxShift;

  /// 与参考页偏转角之差超过该值视为版式不同，不参与对齐。
  final double maxAngleRad;

  /// 墨迹点数下限：近乎空白的页（章首/扉页）投影没有可配准的结构。
  final int minInkPoints;

  /// x/y 投影互相关峰值下限（高通 + √ 加权后的 Pearson r，clamp
  /// 0~1；y 略宽：竖排书的行投影靠列内相位叠加，结构弱于列投影）。
  /// 投影先高通（见 [profileHighPassWindow]）去掉文字带包络——包络
  /// 让任何两页"正文都在同区域"就有 0.4+ 的假相关；高通后同版式页
  /// 的列位/行距细结构强相关，版式无关页 r 落回 0 附近。
  final double minConfidenceX;
  final double minConfidenceY;

  /// 投影高通窗口（工作像素，奇数）：profile 减去该宽度的滑动均
  /// 值。必须小于列距/行距（保住周期细结构）、大于单条界栏线宽
  /// （包络作为低频被压掉）。
  final int profileHighPassWindow;

  /// 角度扫描的墨迹采样上限（超出按步长抽样，控制耗时）。
  final int maxAnglePoints;

  /// 纸面底部页码带高度占比（相对纸高）：该带内墨迹不进投影（页码
  /// 每页文字不同，是配准噪声）。
  final double pageNumberBandRatio;

  /// 纸面定位：亮度 ≥（纸白 − 该余量）算"纸"，行/列纸占比 ≥
  /// [paperRowBrightRatio] 的首末行/列围成纸面矩形，墨迹只在纸内
  /// 提取。扫描周边的深色背景贴着画面边框每页同位，不过滤会让互
  /// 相关锚在画面边框上（角度照常、平移恒 0 的假对齐）。
  final int paperBrightSlack;
  final double paperRowBrightRatio;

  /// 纸面矩形内缩占比（页缘阴影/装订暗边不算墨）。
  final double paperShrinkRatio;

  /// 纸心先验窗口半径（工作像素）：互相关只在"两页纸面中心差值"附
  /// 近该半径内取峰。列距回声峰（错开整列的相关峰）与真峰分差极小
  /// 甚至反超（实测整列错位病灶），纯 argmax 不可靠；文字相对纸面
  /// 刚性印刷，真峰总在纸心差附近，半径须小于典型列距。窗口内一塌
  /// 糟涂而全局峰足够强时逃逸（[escapeFloor]/[escapeMin]），兜住纸
  /// 面定位失效时的真实大偏移。
  final int priorRadius;

  /// 逃逸判定：先验窗口内最优峰低于该值、且全局峰 ≥ [escapeMin]。
  final double escapeFloor;
  final double escapeMin;
}

const InkAlignSettings kInkAlignDefaults = InkAlignSettings();

/// 单页墨迹分析结果（工作画布坐标）。
class InkPageProfile {
  const InkPageProfile({
    required this.angle,
    required this.profileX,
    required this.profileY,
    required this.inkPoints,
    required this.paperCenter,
  });

  /// 文本轴拉正角（弧度，工作画布坐标系）：把页面墨迹旋转 `angle` 后
  /// 行/列与画布轴平行。正值/负值与 [OverlayInkTransform.angleRad]
  /// 同一约定（绘制时直接用本值）。
  final double angle;

  /// 去旋转后的列投影（每列墨迹点数，长 = 工作画布宽）。
  final Uint32List profileX;

  /// 去旋转后的行投影（每行墨迹点数，长 = 工作画布高）。
  final Uint32List profileY;

  /// 进入投影的墨迹点数（底部页码带已排除）。0 = 该页不可分析
  /// （近空白/墨迹占比异常/无法二值化）。
  final int inkPoints;

  /// 纸面矩形中心（工作画布坐标）：文字相对纸面刚性印刷，两页纸心
  /// 差即真实平移的物理先验（纸面定位失败时退化为 contain 中心，
  /// 先验趋近 0 仍然成立）。配准用它锚定互相关取峰，见
  /// [InkAlignSettings.priorRadius]。
  final Offset paperCenter;
}

/// 单页配准结论（叠加画布坐标）。
class InkPageAlign {
  const InkPageAlign({
    required this.angle,
    required this.shift,
    required this.aligned,
    required this.confidenceX,
    required this.confidenceY,
    this.reason = '',
  });

  /// 绘制变换的旋转分量（弧度，绕叠加画布中心）。未对齐时为 0。
  final double angle;

  /// 绘制变换的平移分量（叠加画布像素，已含中位归零与 canvasScale
  /// 换算，未含全局缩放——缩放在 [OverlayInkTransform] 内统一施加）。
  /// 未对齐时为 Offset.zero。
  final Offset shift;

  /// 是否成功配准；false = 该页按原始 contain 摆放（与旧版行为一致）。
  final bool aligned;

  final double confidenceX;
  final double confidenceY;

  /// 未对齐原因（状态行/日志用），对齐成功为空。
  final String reason;
}

/// 一次合成的完整对齐结果。
class InkAlignResult {
  const InkAlignResult({
    required this.byPage,
    required this.referencePage,
    required this.globalScale,
    required this.alignedCount,
    required this.lowConfidenceCount,
    required this.analyzedCount,
    this.diagnostics = const {},
  });

  /// 参与分析的每页结论（含未对齐页：angle=0/shift=0，绘制仍走全局
  /// 缩放口径）。未进分析（缺图/已确认跳过）的页不在表里，取变换时
  /// 退化为 identity+全局缩放。
  final Map<int, InkPageAlign> byPage;

  /// 参考页（0 基页号）；无有效参考时为 -1。
  final int referencePage;

  /// 全局统一缩放（≤1）：把各页自身偏转角下旋转后的包围盒收回画布
  /// 内，所有页一致施加，配准关系不受影响。无旋转需要时为 1。
  final double globalScale;

  final int alignedCount;
  final int lowConfidenceCount;

  /// 实际完成分析的页数（合成进度/状态行用）。
  final int analyzedCount;

  /// 特征法路线的按页诊断文本（页号 → 匹配数/内点数等原生指标），
  /// 投影法路线恒为空。仅日志/排查用，不参与绘制与写回。
  final Map<int, String> diagnostics;

  /// 某页的绘制/写回变换（含全局缩放；未知页 = 不转不移 + 全局缩放）。
  OverlayInkTransform transformFor(int page) {
    final a = byPage[page];
    return OverlayInkTransform(
      angle: a?.angle ?? 0,
      shift: a?.shift ?? Offset.zero,
      globalScale: globalScale,
    );
  }
}

/// 叠加画布上的单页可逆变换：
/// `x ↦ O + S·(R(α)·(x − O) + t)`，O = 画布中心（画布尺寸由消费方
/// 的 contain-fit 口径决定，与本变换解耦——本类只做"绕给定中心转
/// + 移 + 均匀缩放"的仿射部分）。S 为所有页共享的全局缩放，均值平
/// 移 t 也随之缩放，故对任意两页变换之差恒为 `S·(R(α₁)−R(α₂))` 型
/// 一致缩放，配准不被破坏。
class OverlayInkTransform {
  const OverlayInkTransform({
    this.angle = 0,
    this.shift = Offset.zero,
    this.globalScale = 1,
  });

  /// 恒等变换（角度 0、无平移、无缩放）。
  const OverlayInkTransform.identity()
      : angle = 0,
        shift = Offset.zero,
        globalScale = 1;

  final double angle;
  final Offset shift;
  final double globalScale;

  bool get isIdentity =>
      angle == 0 && shift == Offset.zero && globalScale == 1;

  /// 正向：本页画布坐标（contain-fit 后）→ 对齐后叠加画布坐标。
  Offset forward(Offset p, Offset center) {
    final s = globalScale;
    if (isIdentity) return p;
    final dx = p.dx - center.dx;
    final dy = p.dy - center.dy;
    final c = math.cos(angle), sn = math.sin(angle);
    return Offset(
      center.dx + s * (c * dx - sn * dy) + s * shift.dx,
      center.dy + s * (sn * dx + c * dy) + s * shift.dy,
    );
  }

  /// 逆向：叠加画布坐标 → 本页画布坐标（写回框用）。
  Offset inverse(Offset q, Offset center) {
    final s = globalScale;
    if (isIdentity) return q;
    final ex = (q.dx - center.dx) / s - shift.dx;
    final ey = (q.dy - center.dy) / s - shift.dy;
    final c = math.cos(-angle), sn = math.sin(-angle);
    return Offset(
      center.dx + c * ex - sn * ey,
      center.dy + sn * ex + c * ey,
    );
  }

  /// 正向矩形 = 四角映射的轴对齐包围盒（旋转不为零时是外扩近似，
  /// 对"并集参考/写回覆盖"语义正好：宁可稍大不裁字）。
  Rect mapRect(Rect r, Offset center) {
    final a = forward(r.topLeft, center);
    final b = forward(r.topRight, center);
    final c = forward(r.bottomLeft, center);
    final d = forward(r.bottomRight, center);
    return Rect.fromLTRB(
      math.min(math.min(a.dx, b.dx), math.min(c.dx, d.dx)),
      math.min(math.min(a.dy, b.dy), math.min(c.dy, d.dy)),
      math.max(math.max(a.dx, b.dx), math.max(c.dx, d.dx)),
      math.max(math.max(a.dy, b.dy), math.max(c.dy, d.dy)),
    );
  }

  /// 逆向矩形（写回）：叠加画布上画的框换算回本页坐标，同样取四角
  /// 逆映射的包围盒——页带小角度偏转时该框完整覆盖其真实（斜置）
  /// 文本块，识别区稍大于文本，不会裁字。
  Rect unmapRect(Rect r, Offset center) {
    final a = inverse(r.topLeft, center);
    final b = inverse(r.topRight, center);
    final c = inverse(r.bottomLeft, center);
    final d = inverse(r.bottomRight, center);
    return Rect.fromLTRB(
      math.min(math.min(a.dx, b.dx), math.min(c.dx, d.dx)),
      math.min(math.min(a.dy, b.dy), math.min(c.dy, d.dy)),
      math.max(math.max(a.dx, b.dx), math.max(c.dx, d.dx)),
      math.max(math.max(a.dy, b.dy), math.max(c.dy, d.dy)),
    );
  }

  /// 列主序 4×4（Canvas.transform 可直接吃）。中心由消费方平移进/出
  /// （画布中心固定，调用处 save/transform/restore 更直观）。
  Float64List affineStorage(Offset center) {
    final s = globalScale;
    final c = math.cos(angle), sn = math.sin(angle);
    final a = s * c, b = s * sn, cc = -s * sn, d = s * c;
    final tx = center.dx - a * center.dx - cc * center.dy + s * shift.dx;
    final ty = center.dy - b * center.dx - d * center.dy + s * shift.dy;
    final m = Float64List(16);
    m[0] = a;
    m[1] = b;
    m[4] = cc;
    m[5] = d;
    m[10] = 1;
    m[12] = tx;
    m[13] = ty;
    m[15] = 1;
    return m;
  }
}

/// RGBA（每像素 4 字节，直排）解码图的墨迹分析。
///
/// [fit] 为该图 contain 进工作画布 [workCanvas] 的矩形（均匀缩放），
/// 墨迹像素据此映射到工作画布坐标再估计角度/投影。墨迹提取限制在
/// 纸面矩形内（见 [InkAlignSettings.paperBrightSlack]）：画面边框处
/// 的扫描背景每页同位，进了投影会把互相关锚死在零偏移上。
InkPageProfile analyzeInkPage({
  required Uint8List rgba,
  required int imgW,
  required int imgH,
  required Rect fit,
  required Size workCanvas,
  InkAlignSettings settings = kInkAlignDefaults,
}) {
  final paper = paperBounds(rgba, imgW, imgH, settings);
  // 纸心（工作画布坐标）：真实平移的物理先验，见 [InkPageProfile.paperCenter]。
  final paperCenter = Offset(
    fit.left + paper.center.dx * (fit.width / math.max(imgW, 1)),
    fit.top + paper.center.dy * (fit.height / math.max(imgH, 1)),
  );
  InkPageProfile unusable() => InkPageProfile(
        angle: 0,
        profileX: Uint32List(workCanvas.width.round()),
        profileY: Uint32List(workCanvas.height.round()),
        inkPoints: 0,
        paperCenter: paperCenter,
      );

  final threshold = otsuThreshold(rgba, imgW, imgH, paper);
  if (threshold <= 0) {
    return unusable();
  }
  final k = fit.width / math.max(imgW, 1);
  // 页码带按纸面底部计（纸底 6% 的带内墨迹不进统计）：contain 留边
  // 时"画布底部 7%"会切不到真实页码区/误切正文，纸面相对位置才是
  // 页码的真实所在。
  final bandY = fit.top +
      (paper.bottom - paper.height * settings.pageNumberBandRatio) *
          (fit.height / math.max(imgH, 1));
  // 纸面内缩：页缘阴影/装订暗边不算墨。
  final x0 = (paper.left + paper.width * settings.paperShrinkRatio).round();
  final x1 = (paper.right - paper.width * settings.paperShrinkRatio).round();
  final y0 = (paper.top + paper.height * settings.paperShrinkRatio).round();
  final y1 = (paper.bottom - paper.height * settings.paperShrinkRatio).round();
  final xs = <double>[];
  final ys = <double>[];
  var ink = 0, total = 0;
  for (var y = math.max(0, y0); y < math.min(imgH, y1); y++) {
    // 全像素扫描（不做行内步长抽样）：棋盘式抽样与旋转后的整数光栅
    // 会在 0° 产生莫尔纹假峰，毁掉角度扫描；600px 全扫仅几毫秒。
    for (var x = math.max(0, x0); x < math.min(imgW, x1); x++) {
      final i = (y * imgW + x) * 4;
      final lum = (rgba[i] * 77 + rgba[i + 1] * 150 + rgba[i + 2] * 29) >> 8;
      total++;
      // Otsu 语义：≤ 阈值属暗类（墨）。双峰恰好贴着灰度档时阈值会
      // 正好落在墨迹档上，用 < 会把整页墨迹排除。
      if (lum <= threshold) {
        ink++;
        final wx = fit.left + x * k;
        final wy = fit.top + y * (fit.height / math.max(imgH, 1));
        // 底部页码带不进任何统计（页码每页文字不同，是配准噪声）。
        if (wy < bandY) {
          xs.add(wx);
          ys.add(wy);
        }
      }
    }
  }
  // 墨迹占比异常（反向图/整页污损）：投影结构不可信，按不可分析退回。
  if (xs.length < settings.minInkPoints ||
      (total > 0 && ink / total > 0.45)) {
    return unusable();
  }

  final center = Offset(workCanvas.width / 2, workCanvas.height / 2);
  // 角度扫描抽样：控制扫描耗时而保角度精度（分层均匀抽样）。
  var sx = xs, sy = ys;
  if (xs.length > settings.maxAnglePoints) {
    final step = xs.length / settings.maxAnglePoints;
    final nx = <double>[], ny = <double>[];
    for (var t = 0.0; t < xs.length; t += step) {
      final j = t.toInt();
      nx.add(xs[j]);
      ny.add(ys[j]);
    }
    sx = nx;
    sy = ny;
  }

  var bestAngle = 0.0;
  var bestScore = -1.0;
  double sweep(double from, double to, int steps) {
    var localBest = bestAngle, localScore = bestScore;
    for (var s = 0; s <= steps; s++) {
      final a = from + (to - from) * s / steps;
      final score = _projectionSharpness(sx, sy, a, center, workCanvas);
      if (score > localScore) {
        localScore = score;
        localBest = a;
      }
    }
    bestAngle = localBest;
    bestScore = localScore;
    return localScore;
  }

  const coarse = 5.0 * math.pi / 180.0;
  sweep(-coarse, coarse, 20); // 粗扫 ±5° 步 0.5°
  sweep(bestAngle - 0.4 * math.pi / 180.0,
      bestAngle + 0.4 * math.pi / 180.0, 20); // 细扫 ±0.4° 步 0.04°

  final profileX = Uint32List(workCanvas.width.round());
  final profileY = Uint32List(workCanvas.height.round());
  final c = math.cos(bestAngle), sn = math.sin(bestAngle);
  var used = 0;
  for (var j = 0; j < xs.length; j++) {
    final dx = xs[j] - center.dx, dy = ys[j] - center.dy;
    final u = center.dx + c * dx - sn * dy;
    final v = center.dy + sn * dx + c * dy;
    final ix = u.round();
    final iy = v.round();
    // 旋转后落出画布的点丢弃（页边留白被旋出时不参与投影）。
    if (ix < 0 || ix >= profileX.length || iy < 0 || iy >= profileY.length) {
      continue;
    }
    profileX[ix]++;
    profileY[iy]++;
    used++;
  }
  return InkPageProfile(
    angle: bestAngle,
    profileX: profileX,
    profileY: profileY,
    inkPoints: used,
    paperCenter: paperCenter,
  );
}

/// 全部参与页 → 每页配准结论（对参考页帧）。纯函数。
InkAlignResult computeInkAlignments({
  required Map<int, InkPageProfile> profiles,
  required double canvasScale,
  required Size overlayCanvas,
  InkAlignSettings settings = kInkAlignDefaults,
}) {
  final valid = <int, InkPageProfile>{
    for (final e in profiles.entries)
      if (e.value.inkPoints >= settings.minInkPoints) e.key: e.value,
  };
  if (valid.length < 2) {
    return InkAlignResult(
      byPage: const {},
      referencePage: -1,
      globalScale: 1,
      alignedCount: 0,
      lowConfidenceCount: 0,
      analyzedCount: profiles.length,
    );
  }
  // 参考页取墨迹量中位数：避开正文特少的章首/缺字页。
  final sorted = valid.values.toList()
    ..sort((a, b) => a.inkPoints.compareTo(b.inkPoints));
  final ref = sorted[sorted.length ~/ 2];
  final refPage = valid.entries
      .firstWhere((e) => identical(e.value, ref))
      .key;

  final byPage = <int, InkPageAlign>{};
  var aligned = 0;
  var low = 0;
  for (final e in valid.entries) {
    final p = e.value;
    final isRef = e.key == refPage;
    final mx = _ShiftMatch(
        shift: 0, subpixel: 0, peak: 1, confidence: 1, atEdge: false);
    // 纸心先验：两页纸面中心差（工作像素），真峰总在它附近。
    final prior = p.paperCenter - ref.paperCenter;
    final matchX = isRef
        ? mx
        : _bestShift(p.profileX, ref.profileX, settings,
            expectedD: prior.dx);
    final matchY = isRef
        ? mx
        : _bestShift(p.profileY, ref.profileY, settings,
            expectedD: prior.dy);
    final angleDiff = (p.angle - ref.angle).abs();
    String reason = '';
    var ok = true;
    if (!isRef) {
      if (angleDiff > settings.maxAngleRad) {
        ok = false;
        reason = '偏转角差超限';
      } else if (matchX.atEdge || matchY.atEdge) {
        ok = false;
        reason = '平移超出搜索范围';
      } else if (matchX.confidence < settings.minConfidenceX ||
          matchY.confidence < settings.minConfidenceY) {
        ok = false;
        reason = '相关峰不显著';
      }
    }
    if (ok) {
      aligned++;
      byPage[e.key] = InkPageAlign(
        angle: p.angle,
        // 峰值 d = 页内容相对参考的偏移，对齐要往回挪 −d；工作画布 →
        // 叠加画布再乘 canvasScale。
        shift: Offset(
          -matchX.subpixel * canvasScale,
          -matchY.subpixel * canvasScale,
        ),
        aligned: true,
        confidenceX: matchX.confidence,
        confidenceY: matchY.confidence,
      );
    } else {
      low++;
      byPage[e.key] = InkPageAlign(
        angle: 0,
        shift: Offset.zero,
        aligned: false,
        confidenceX: matchX.confidence,
        confidenceY: matchY.confidence,
        reason: reason,
      );
    }
  }

  // 平移中位归零 + 全局缩放：两条对齐路线（投影/特征）共用的收尾。
  _medianCenterShifts(byPage);
  final scale = _globalScaleFor(byPage, overlayCanvas);

  return InkAlignResult(
    byPage: byPage,
    referencePage: refPage,
    globalScale: scale,
    alignedCount: aligned,
    lowConfidenceCount: low,
    analyzedCount: profiles.length,
  );
}

/// 全部参与页 → 每页配准结论（特征法路线，对参考页帧）。纯函数。
///
/// 与 [computeInkAlignments]（投影法）同一套输出契约（[InkAlignResult]，
/// 画页/写回/并集虚线零改动），配准内核换成特征点匹配 + RANSAC：
/// 逐页与参考页做 [alignWithFeatures]，得到"参考页坐标 → 本页坐标"
/// 的相似变换 T = s·R(θ) + τ（工作画布口径），再换算成绘制变换——
/// 本页要贴到参考页帧上，即绘制 T 的逆：
/// - 旋转分量 `α = −θ`；
/// - 平移分量 `t = (R(α) − I)·O − R(α)·(τ·canvasScale)`，O 为叠加画
///   布中心。纯平移时退化为 `−τ·canvasScale`（与投影法的 shift 同约
///   定）；纯旋转时正是"绕画布中心转"所需的补偿平移。推导：要求
///   forward(p) = O + S·(R(α)(p−O) + t) 与参考页同缩放的逆映射落点
///   相等，解 t 即得。
/// - 尺度分量 s≈1（|s−1|>5% 已在 [alignWithFeatures] 判废），并入全
///   局缩放的容差内不单独绘制。
InkAlignResult computeInkAlignmentsFromFeatures({
  required Map<int, InkPageFeatures> features,
  required double canvasScale,
  required Size overlayCanvas,
  MatchSettings matchSettings = kMatchDefaults,
}) {
  // 与投影法同两道门控：墨迹量（空页/污损页）+ 特征点数（特征法
  // 特有：少于它连匹配的样本都没有）。
  final valid = <int, InkPageFeatures>{
    for (final e in features.entries)
      if (e.value.inkPoints >= kInkAlignDefaults.minInkPoints &&
          e.value.points.length >= matchSettings.minFeaturePoints)
        e.key: e.value,
  };
  if (valid.length < 2) {
    return InkAlignResult(
      byPage: const {},
      referencePage: -1,
      globalScale: 1,
      alignedCount: 0,
      lowConfidenceCount: 0,
      analyzedCount: features.length,
    );
  }
  // 参考页取特征点数中位数（对齐投影法的"墨迹量中位数"口径）。
  final sorted = valid.values.toList()
    ..sort((a, b) => a.points.length.compareTo(b.points.length));
  final ref = sorted[sorted.length ~/ 2];
  final refPage =
      valid.entries.firstWhere((e) => identical(e.value, ref)).key;

  final byPage = <int, InkPageAlign>{};
  final diags = <int, String>{};
  final o = Offset(overlayCanvas.width / 2, overlayCanvas.height / 2);
  var aligned = 0;
  var low = 0;
  for (final e in valid.entries) {
    if (e.key == refPage) {
      aligned++;
      byPage[e.key] = const InkPageAlign(
        angle: 0,
        shift: Offset.zero,
        aligned: true,
        confidenceX: 1,
        confidenceY: 1,
      );
      diags[e.key] = '参考页';
      continue;
    }
    final out =
        alignWithFeatures(ref: ref, page: e.value, settings: matchSettings);
    diags[e.key] =
        '特征 ${out.refPoints}×${out.pagePoints} · 匹配 ${out.totalMatches}'
        ' · 内点 ${out.inliers}（${(out.inlierRatio * 100).round()}%）';
    if (!out.aligned) {
      low++;
      byPage[e.key] = InkPageAlign(
        angle: 0,
        shift: Offset.zero,
        aligned: false,
        confidenceX: out.inlierRatio,
        confidenceY: (out.inliers / 25).clamp(0.0, 1.0),
        reason: out.reason,
      );
      continue;
    }
    final t = out.transform!;
    // ψ 复合已在 alignWithFeatures 内完成（成对结果即原始页面坐标系
    // 下的相似变换），这里直接消费。
    final theta = t.angle;
    if (theta.abs() > kInkAlignDefaults.maxAngleRad) {
      low++;
      byPage[e.key] = InkPageAlign(
        angle: 0,
        shift: Offset.zero,
        aligned: false,
        confidenceX: out.inlierRatio,
        confidenceY: (out.inliers / 25).clamp(0.0, 1.0),
        reason: '偏转角差超限',
      );
      continue;
    }
    // 逆变换换算成绘制分量（见函数注释的推导）。
    final alpha = -theta;
    final c = math.cos(alpha), sn = math.sin(alpha);
    final tauX = t.tx * canvasScale;
    final tauY = t.ty * canvasScale;
    final shift = Offset(
      (c - 1) * o.dx - sn * o.dy - (c * tauX - sn * tauY),
      sn * o.dx + (c - 1) * o.dy - (sn * tauX + c * tauY),
    );
    aligned++;
    byPage[e.key] = InkPageAlign(
      angle: alpha,
      shift: shift,
      aligned: true,
      // 特征法的置信度是信息性的（门限已在 alignWithFeatures 内把
      // 关）：X = 内点比，Y = 内点绝对量（25 个记满分）。
      confidenceX: out.inlierRatio,
      confidenceY: (out.inliers / 25).clamp(0.0, 1.0),
    );
  }

  _medianCenterShifts(byPage);
  final scale = _globalScaleFor(byPage, overlayCanvas);

  return InkAlignResult(
    byPage: byPage,
    referencePage: refPage,
    globalScale: scale,
    alignedCount: aligned,
    lowConfidenceCount: low,
    analyzedCount: features.length,
    diagnostics: diags,
  );
}

// ── 内部 ──

/// 平移中位归零（两条路线共用）：合成整体不因参考页选择而漂移；
/// 未对齐页不动。
void _medianCenterShifts(Map<int, InkPageAlign> byPage) {
  final shifts = [
    for (final e in byPage.entries)
      if (e.value.aligned) e.value.shift,
  ];
  double medianOf(List<double> v) {
    final s = v..sort();
    return s.isEmpty ? 0 : s[s.length ~/ 2];
  }
  final medX = medianOf([for (final s in shifts) s.dx]);
  final medY = medianOf([for (final s in shifts) s.dy]);
  if (medX != 0 || medY != 0) {
    byPage.updateAll((k, v) => v.aligned
        ? InkPageAlign(
            angle: v.angle,
            shift: v.shift - Offset(medX, medY),
            aligned: true,
            confidenceX: v.confidenceX,
            confidenceY: v.confidenceY,
          )
        : v);
  }
}

/// 全局统一缩放（两条路线共用）：最大偏转角下旋转后的页面包围盒收
/// 回画布内。所有页一致施加（含未对齐页），配准关系不受影响。
double _globalScaleFor(Map<int, InkPageAlign> byPage, Size overlayCanvas) {
  var maxAngle = 0.0;
  for (final v in byPage.values) {
    if (v.aligned) maxAngle = math.max(maxAngle, v.angle.abs());
  }
  if (maxAngle <= 0.5 * math.pi / 180.0) return 1.0;
  final c = math.cos(maxAngle), sn = math.sin(maxAngle);
  final r = overlayCanvas.height / math.max(overlayCanvas.width, 1);
  return (1 / (c + r * sn)).clamp(0.85, 1.0);
}

int _lumOf(Uint8List rgba, int pixelIndex) {
  final j = pixelIndex * 4;
  return (rgba[j] * 77 + rgba[j + 1] * 150 + rgba[j + 2] * 29) >> 8;
}

/// 纸面矩形：亮度 92 分位视为纸白，行/列"近纸白占比"达标的首末
/// 行/列围成矩形（采样估计）。定位失败/覆盖面过小（<30%）按整幅
/// 兜底——全幅白底扫描本就无需门控。特征点提取（feature_points.dart）
/// 复用同一口径，保证两种对齐方法的墨迹范围一致。
Rect paperBounds(Uint8List rgba, int w, int h, InkAlignSettings s) {
  final step = math.max(1, (w * h) ~/ 40000);
  final hist = Uint32List(256);
  final rowTot = Uint32List(h), rowBright = Uint32List(h);
  final colTot = Uint32List(w), colBright = Uint32List(w);
  var n = 0;
  for (var i = 0; i * 4 + 2 < rgba.length; i += step) {
    final x = i % w, y = i ~/ w;
    hist[_lumOf(rgba, i)]++;
    rowTot[y]++;
    colTot[x]++;
    n++;
  }
  if (n == 0) return Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
  // 从亮端累计 8% 定纸白（纸占大多数时稳定落在纸的亮度档）。
  var acc = 0;
  var paperWhite = 255;
  for (var t = 255; t >= 0; t--) {
    acc += hist[t];
    if (acc >= n * 0.08) {
      paperWhite = t;
      break;
    }
  }
  final brightCut = math.max(0, paperWhite - s.paperBrightSlack);
  for (var i = 0; i * 4 + 2 < rgba.length; i += step) {
    final x = i % w, y = i ~/ w;
    if (_lumOf(rgba, i) >= brightCut) {
      rowBright[y]++;
      colBright[x]++;
    }
  }

  int firstBright(Uint32List bright, Uint32List tot) {
    for (var i = 0; i < bright.length; i++) {
      if (tot[i] > 0 && bright[i] >= tot[i] * s.paperRowBrightRatio) return i;
    }
    return 0;
  }

  int lastBright(Uint32List bright, Uint32List tot) {
    for (var i = bright.length - 1; i >= 0; i--) {
      if (tot[i] > 0 && bright[i] >= tot[i] * s.paperRowBrightRatio) return i;
    }
    return bright.length - 1;
  }

  final top = firstBright(rowBright, rowTot);
  final bottom = lastBright(rowBright, rowTot);
  final left = firstBright(colBright, colTot);
  final right = lastBright(colBright, colTot);
  if (bottom - top < h * 0.3 || right - left < w * 0.3) {
    return Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
  }
  return Rect.fromLTRB(
    left.toDouble(),
    top.toDouble(),
    right.toDouble(),
    bottom.toDouble(),
  );
}

/// [bounds] 内的 Otsu 阈值（类间方差最大，纸内提取时是干净的纸/墨
/// 双峰）。近单峰（空白/全黑）返回 0 = 不可二值化。
int otsuThreshold(Uint8List rgba, int w, int h, Rect bounds) {
  final hist = Uint32List(256);
  final x0 = math.max(0, bounds.left.round());
  final x1 = math.min(w, bounds.right.round());
  final y0 = math.max(0, bounds.top.round());
  final y1 = math.min(h, bounds.bottom.round());
  if (x1 <= x0 || y1 <= y0) return 0;
  final step = math.max(1, ((x1 - x0) * (y1 - y0)) ~/ 60000); // 采样建直方图即可
  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x += step) {
      hist[_lumOf(rgba, y * w + x)]++;
    }
  }
  var total = 0;
  for (final v in hist) {
    total += v;
  }
  if (total == 0) return 0;
  var sum = 0;
  for (var t = 0; t < 256; t++) {
    sum += t * hist[t];
  }
  var sumB = 0, wB = 0, best = 0.0, threshold = 0;
  for (var t = 0; t < 256; t++) {
    wB += hist[t];
    if (wB == 0) continue;
    final wF = total - wB;
    if (wF == 0) break;
    sumB += t * hist[t];
    final mB = sumB / wB;
    final mF = (sum - sumB) / wF;
    final between = wB * wF * (mB - mF) * (mB - mF) * 1.0;
    if (between > best) {
      best = between;
      threshold = t;
    }
  }
  // 近单峰判定：暗侧几乎无像素说明整页近空白，无法稳定二值化。
  var dark = 0;
  for (var t = 0; t <= threshold; t++) {
    dark += hist[t];
  }
  if (dark < total * 0.002 || threshold < 30) return 0;
  return threshold;
}

/// 行/列投影锐度（归一化 Σh²/T²）：文本轴与画布轴平行时列隔/行界
/// 让投影出现尖峰，锐度最大；偏转则抹平。两轴锐度之和做扫描目标
/// （拉正时 x/y 投影同时变锐）。
double _projectionSharpness(
  List<double> xs,
  List<double> ys,
  double angle,
  Offset center,
  Size workCanvas,
) {
  final w = workCanvas.width.round(), h = workCanvas.height.round();
  final hx = Uint32List(w), hy = Uint32List(h);
  final c = math.cos(angle), sn = math.sin(angle);
  var total = 0;
  for (var i = 0; i < xs.length; i++) {
    final dx = xs[i] - center.dx, dy = ys[i] - center.dy;
    final u = center.dx + c * dx - sn * dy;
    final v = center.dy + sn * dx + c * dy;
    final ix = u.round(), iy = v.round();
    if (ix < 0 || ix >= w || iy < 0 || iy >= h) continue;
    hx[ix]++;
    hy[iy]++;
    total++;
  }
  if (total == 0) return -1;
  var sx = 0, sy = 0;
  for (final v in hx) {
    sx += v * v;
  }
  for (final v in hy) {
    sy += v * v;
  }
  final t = total * total;
  return sx / t + sy / t;
}

class _ShiftMatch {
  const _ShiftMatch({
    required this.shift,
    required this.subpixel,
    required this.peak,
    required this.confidence,
    required this.atEdge,
  });
  final int shift;
  final double subpixel;
  final double peak;
  final double confidence;
  final bool atEdge;
}

/// 单轴投影互相关：page 相对 ref 平移多少后两者最像。
///
/// 约定 score(d) = corr(page[i+d], ref[i])——d>0 表示 page 的特征整体
/// 在 ref 右/下方 d 格。峰值处抛物线插值出亚像素 [subpixel]；
/// [confidence] 直接取峰值相关系数（高通 + √ 加权 Pearson r，clamp
/// 0~1）。**不用**主峰对次峰的显著性：竖排文字列/行是强周期结构，
/// ±一个列距处必然出现接近主峰的次峰，显著性指标会把大量可对齐页
/// 误判为低置信、整页退回不偏移（实测"旋转生效、平移不动"病灶）。
/// 也不直接用原始投影：文字带包络让任何两页都有 0.4+ 的假相关（噪
/// 声页也能过阈），先高通杀包络再相关。
///
/// [expectedD] 为纸心先验（两页纸面中心差值，本轴分量）。周期列距
/// 的回声峰与真峰分差极小甚至反超（实测整列错位病灶），纯 argmax
/// 不可靠；文字相对纸面刚性印刷，真峰总在先验附近——全局峰落在先
/// 验窗口外时默认不采信，改取窗口内最优峰；仅当窗口内低于
/// [InkAlignSettings.escapeFloor] 而全局峰 ≥ [InkAlignSettings.
/// escapeMin]（纸面定位失效的真实大偏移）才逃逸采信全局峰。
_ShiftMatch _bestShift(
  Uint32List page,
  Uint32List ref,
  InkAlignSettings settings, {
  double expectedD = 0,
}) {
  final n = math.min(page.length, ref.length);
  final maxS = settings.maxShift;
  final hp = _highPassProfile(page, settings.profileHighPassWindow);
  final hr = _highPassProfile(ref, settings.profileHighPassWindow);
  final scores = List<double>.filled(2 * maxS + 1, 0);
  var best = 0;
  var bestScore = -2.0;
  for (var d = -maxS; d <= maxS; d++) {
    // 重叠区 [lo, hi)：page[i+d] 对 ref[i]。
    final lo = math.max(0, -d);
    final hi = math.min(n, n - d);
    if (hi - lo < n * 0.55) {
      scores[d + maxS] = -2.0;
      continue;
    }
    var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0;
    var cnt = 0;
    for (var i = lo; i < hi; i++) {
      final a = hp[i + d];
      final b = hr[i];
      sa += a;
      sb += b;
      saa += a * a;
      sbb += b * b;
      sab += a * b;
      cnt++;
    }
    final cov = sab - sa * sb / cnt;
    final va = saa - sa * sa / cnt;
    final vb = sbb - sb * sb / cnt;
    final r = (va > 0 && vb > 0)
        ? cov / math.sqrt(va * vb)
        : -2.0;
    scores[d + maxS] = r;
    if (r > bestScore) {
      bestScore = r;
      best = d;
    }
  }
  var chosen = best;
  var chosenScore = bestScore;
  // 纸心先验锚定：全局峰在先验窗外时默认不采信（周期回声），窗口
  // 内塌方 + 全局峰够强才逃逸（纸面定位失效的真实大偏移）。
  final nearLo = (expectedD - settings.priorRadius).ceil().clamp(-maxS, maxS);
  final nearHi = (expectedD + settings.priorRadius).floor().clamp(-maxS, maxS);
  if ((best - expectedD).abs() > settings.priorRadius &&
      nearHi >= nearLo) {
    var nearBest = nearLo;
    var nearScore = -2.0;
    for (var d = nearLo; d <= nearHi; d++) {
      if (scores[d + maxS] > nearScore) {
        nearScore = scores[d + maxS];
        nearBest = d;
      }
    }
    final escape =
        nearScore < settings.escapeFloor && bestScore >= settings.escapeMin;
    if (!escape) {
      chosen = nearBest;
      chosenScore = nearScore;
    }
  }
  // 亚像素：所选峰邻域三点抛物线（邻值是无重叠哨兵时退整数）。
  var sub = chosen.toDouble();
  if (chosen > -maxS &&
      chosen < maxS &&
      scores[chosen - 1 + maxS] > -1.5 &&
      scores[chosen + 1 + maxS] > -1.5) {
    final l = scores[chosen - 1 + maxS],
        c = scores[chosen + maxS], r = scores[chosen + 1 + maxS];
    final denom = l - 2 * c + r;
    if (denom < -1e-12) {
      sub = chosen + 0.5 * (l - r) / denom;
    }
  }
  return _ShiftMatch(
    shift: chosen,
    subpixel: sub,
    peak: chosenScore,
    confidence: chosenScore.clamp(0.0, 1.0),
    atEdge: chosen.abs() >= maxS - 2,
  );
}

/// 投影高通：√(计数) − √(滑动均值)。√ 压缩版框长线/边栏这类巨峰的
/// 动态范围（否则它们支配相关），减滑动均值压掉文字带包络（低频），
/// 留下列位/行距细结构。可为负，正好供 Pearson 用。
Float64List _highPassProfile(Uint32List p, int window) {
  final n = p.length;
  final out = Float64List(n);
  final prefix = Float64List(n + 1);
  for (var i = 0; i < n; i++) {
    prefix[i + 1] = prefix[i] + p[i];
  }
  final half = math.max(1, window ~/ 2);
  for (var i = 0; i < n; i++) {
    final lo = math.max(0, i - half);
    final hi = math.min(n, i + half + 1);
    final mean = (prefix[hi] - prefix[lo]) / (hi - lo);
    out[i] = math.sqrt(p[i].toDouble()) - math.sqrt(mean);
  }
  return out;
}
