import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

/// 校对摆正的裁切四边形：4 个角点 + 直边（无曲线）。
///
/// - 角点顺序固定 TL,TR,BR,BL（图像像素坐标，y 向下）。
/// - 交互模型（用户指定）：**角点**自由拖动改变框形状；**边中点**拖动
///   时该条边两个角上的顶点共同平移（整条边跟随移动）。
/// - 边索引：0=top(TL-TR) 1=right(TR-BR) 2=bottom(BL-BR) 3=left(TL-BL)。
class PageQuad {
  PageQuad({required this.corners})
    : assert(corners.length == 4, 'corners 必须是 TL,TR,BR,BL 四点');

  /// TL,TR,BR,BL 四角的图像像素坐标。
  final List<Offset> corners;

  static const int edgeTop = 0, edgeRight = 1, edgeBottom = 2, edgeLeft = 3;

  Offset get tl => corners[0];
  Offset get tr => corners[1];
  Offset get br => corners[2];
  Offset get bl => corners[3];

  /// 边的两个端点角（与 corners 下标对应）。
  static const List<List<int>> _edgeCornerIndices = [
    [0, 1], // top:    TL-TR
    [1, 2], // right:  TR-BR
    [3, 2], // bottom: BL-BR
    [0, 3], // left:   TL-BL
  ];

  factory PageQuad.defaultInset(Size imageSize, {double fraction = 0.02}) {
    final mx = imageSize.width * fraction;
    final my = imageSize.height * fraction;
    return PageQuad(corners: [
      Offset(mx, my),
      Offset(imageSize.width - 1 - mx, my),
      Offset(imageSize.width - 1 - mx, imageSize.height - 1 - my),
      Offset(mx, imageSize.height - 1 - my),
    ]);
  }

  /// 从后端 /detect_page_quad 的 points（TL,TR,BR,BL）构造。
  factory PageQuad.fromPoints(List<List<double>> points) {
    return PageQuad(
      corners: points.take(4).map((pt) => Offset(pt[0], pt[1])).toList(),
    );
  }

  /// 边的两个角点。
  List<Offset> edgeCorners(int edge) {
    final pair = _edgeCornerIndices[edge];
    return [corners[pair[0]], corners[pair[1]]];
  }

  /// 边中点（边中点拖拽手柄的位置）。
  Offset edgeMid(int edge) {
    final pair = _edgeCornerIndices[edge];
    return (corners[pair[0]] + corners[pair[1]]) / 2;
  }

  /// 拖动角点：该角移到 [pos]。
  PageQuad withCorner(int index, Offset pos) {
    final next = List<Offset>.of(corners);
    next[index] = pos;
    return PageQuad(corners: next);
  }

  /// 拖动边中点：该边的两个角点按指针位移**共同平移**（整条边跟随）。
  /// [from] 为按下时的指针位置，[to] 为当前位置；角点初值取按下瞬间
  /// 快照（由调用方保存并经 [withCorners] 传入），保证拖动无跳变。
  /// [lockToNormal]（按住 Shift）：位移投影到该边的法线方向，整条边
  /// 只沿垂直于自身的方向平移（保持与原边平行地"上下"移动）；法线取
  /// 自按下快照的边，拖动期间约束方向不随边移动漂移。
  PageQuad withEdgeDrag(
    int edge,
    Offset from,
    Offset to,
    List<Offset> startCorners, {
    bool lockToNormal = false,
  }) {
    var delta = to - from;
    final pair = _edgeCornerIndices[edge];
    if (lockToNormal) {
      final edgeVec = startCorners[pair[1]] - startCorners[pair[0]];
      final len = edgeVec.distance;
      if (len > 0) {
        final normal = Offset(-edgeVec.dy, edgeVec.dx) / len;
        delta = normal * (delta.dx * normal.dx + delta.dy * normal.dy);
      }
    }
    final next = List<Offset>.of(corners);
    next[pair[0]] = startCorners[pair[0]] + delta;
    next[pair[1]] = startCorners[pair[1]] + delta;
    return PageQuad(corners: next);
  }

  /// 直接替换全部角点（拖动期间的快照回写用）。
  PageQuad withCorners(List<Offset> next) => PageQuad(corners: next);

  /// 四角质心（缩放/旋转等整体变换的不动点）。
  Offset get centroid => (tl + tr + br + bl) / 4;

  /// 以 [center]（缺省质心）为中心把四角同乘 [factor]——形状不变的整体
  /// 放大/缩小（Ctrl+滚轮缩框用）。不负责边界钳制与退化保护，由调用方
  /// 限制 factor。
  PageQuad scaled(double factor, {Offset? center}) {
    final c = center ?? centroid;
    return PageQuad(
      corners: [for (final o in corners) c + (o - c) * factor],
    );
  }

  /// 四边形 Path（直边），画布/遮罩绘制用。
  Path toPath() {
    return Path()
      ..moveTo(tl.dx, tl.dy)
      ..lineTo(tr.dx, tr.dy)
      ..lineTo(br.dx, br.dy)
      ..lineTo(bl.dx, bl.dy)
      ..close();
  }

  /// 双线性取点：参数 (u,v)∈[0,1]² 映射到四边形内一点（直边场景与
  /// 后端单应一致），供网格参考线用。
  Offset pointAt(double u, double v) {
    Offset lerpEdge(Offset a, Offset b, double t) => a + (b - a) * t;
    final top = lerpEdge(tl, tr, u);
    final bottom = lerpEdge(bl, br, u);
    return lerpEdge(top, bottom, v);
  }

  /// 四边形是否自交/退化（按弦线段判断对边相交）：自交时确认按钮
  /// 应禁用并红色警示。
  bool isSimple() {
    bool segmentsIntersect(Offset a1, Offset a2, Offset b1, Offset b2) {
      double cross(Offset o, Offset a, Offset b) =>
          (a.dx - o.dx) * (b.dy - o.dy) - (a.dy - o.dy) * (b.dx - o.dx);
      final d1 = cross(b1, b2, a1);
      final d2 = cross(b1, b2, a2);
      final d3 = cross(a1, a2, b1);
      final d4 = cross(a1, a2, b2);
      return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
          ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0));
    }

    if (segmentsIntersect(tl, tr, bl, br)) return false;
    if (segmentsIntersect(tr, br, tl, bl)) return false;
    for (var i = 0; i < 4; i++) {
      for (var j = i + 1; j < 4; j++) {
        if ((corners[i] - corners[j]).distance < 1) return false;
      }
    }
    return true;
  }

  /// 顺时针旋转 90° 后的裁切四边形（配合 /transform_page rotate_cw 就地
  /// 旋转原图后同步换算点位，无需重新检测）。旧 left→新 top、旧 top→新
  /// right、旧 right→新 bottom、旧 bottom→新 left。
  PageQuad rotatedCW(int oldW, int oldH) {
    Offset rot(Offset o) => Offset(oldH - 1 - o.dy, o.dx);
    return PageQuad(corners: [rot(bl), rot(tl), rot(tr), rot(br)]);
  }

  /// 逆时针旋转 90° 后的裁切四边形。旧 right→新 top、旧 bottom→新
  /// right、旧 left→新 bottom、旧 top→新 left。
  PageQuad rotatedCCW(int oldW, int oldH) {
    Offset rot(Offset o) => Offset(o.dy, oldW - 1 - o.dx);
    return PageQuad(corners: [rot(tr), rot(br), rot(bl), rot(tl)]);
  }

  /// 角点序列化（后端 corners 字段，TL,TR,BR,BL）。全部直边，不再传
  /// edge_mids（后端走精确单应）。
  List<List<double>> cornersJson() =>
      corners.map((c) => [c.dx, c.dy]).toList();

  Map<String, dynamic> toJson() => {'corners': cornersJson()};

  factory PageQuad.fromJson(Map<String, dynamic> json) {
    final corners = (json['corners'] as List)
        .map((c) => Offset((c as List)[0] as double, c[1] as double))
        .toList();
    return PageQuad(corners: corners);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PageQuad && _listEquals(corners, other.corners);

  @override
  int get hashCode => Object.hashAll(corners);

  static bool _listEquals<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// 按屏幕最小命中尺寸换算图像像素命中半径：缩放越小命中区按比例放大，
/// 保证缩小视图里也点得到（与 AnnotationHitGeometry 同思路）。
double quadHitRadiusImage(double viewScale, {double screenPx = 30}) {
  return screenPx / math.max(viewScale, 0.001);
}

/// 视图矩阵的 x/y 缩放（画布像素 → 逻辑屏幕像素）。
///
/// 本应用的适配/缩放矩阵只缩 x、y（`scaleByDouble(s, s, 1, 1)`，z 恒为
/// 1），**不能用 `getMaxScaleOnAxis()`**——它取三轴缩放的最大值，z 轴的
/// 1 恒为最大，永远返回 1.0：控制点/框线的屏幕尺寸补偿与按屏幕像素的
/// 命中换算全部失效，页面分辨率越高（适配缩放越小）拖拽点越小。取
/// x/y 两轴列向量长度的较大者（矩阵带旋转时仍正确）。
double matrixXyScale(Matrix4 m) {
  final s = m.storage;
  final sx = math.sqrt(s[0] * s[0] + s[1] * s[1] + s[2] * s[2]);
  final sy = math.sqrt(s[4] * s[4] + s[5] * s[5] + s[6] * s[6]);
  return math.max(sx, sy);
}

/// 画布换图时的初始视图矩阵：把图像按 [carriedScale]（无则整页适配）
/// 缩放并在 [viewportWidth]×[viewportHeight] 内居中。
///
/// 适配比例上限 1.0（小图不放大超过 1:1）；沿用比例的上下限与滚轮
/// 缩放一致（0.05~8.0，超限钳制）。比例超过适配后画面大于视口，
/// translate 按 max(0, …) 收敛为 0，自然落在左上角锚定；小于适配时
/// 居中。编辑器翻页沿用上一页的缩放比例即由此生成（不再打回适配档）。
Matrix4 canvasInitialMatrix({
  required double viewportWidth,
  required double viewportHeight,
  required double imageWidth,
  required double imageHeight,
  double? carriedScale,
}) {
  final fitScale =
      math
          .min(
            viewportWidth / math.max(imageWidth, 1),
            viewportHeight / math.max(imageHeight, 1),
          )
          .clamp(0.05, 1.0)
          .toDouble();
  final scale = (carriedScale ?? fitScale).clamp(0.05, 8.0).toDouble();
  final dx = math.max(0.0, (viewportWidth - imageWidth * scale) / 2);
  final dy = math.max(0.0, (viewportHeight - imageHeight * scale) / 2);
  return Matrix4.identity()
    ..translateByDouble(dx, dy, 0, 1)
    ..scaleByDouble(scale, scale, 1, 1);
}

/// 单页校对摆正的输出路径（编辑器与主区快设共用，规则只允许存在这一
/// 份实现）：当前文件已是 warped/ 输出则原地覆盖（批量输出
/// page_NNN.png 页号须与本页下标一致才安全回写，否则走带后缀命名防止
/// 覆盖他页）；否则 warped/<源文件名>_st.png，重名依次加数字后缀。
String straightenOutPath({
  required String projectDir,
  required int index,
  required String currentPath,
}) {
  final warpedDir = p.join(projectDir, 'warped');
  final base = p.basename(currentPath);
  final stem = p.withoutExtension(base);
  if (p.isWithin(warpedDir, currentPath)) {
    final m = RegExp(r'^page_(\d+)$').firstMatch(stem);
    if (m == null || int.parse(m.group(1)!) == index) {
      return currentPath; // <stem>_st.png 或页号对得上的批量输出：回写自身
    }
  }
  var out = p.join(warpedDir, '${stem}_st.png');
  var n = 2;
  while (File(out).existsSync()) {
    out = p.join(warpedDir, '${stem}_st${n++}.png');
  }
  return out;
}
