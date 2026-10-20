import 'dart:math' as math;
import 'dart:ui';

import '../models/models.dart';

enum AnnotationResizeHandle { topLeft, topRight, bottomLeft, bottomRight }

/// Geometry shared by the page editor and the compact line preview. All
/// returned points and dimensions are in image coordinates; target sizes are
/// specified in logical screen pixels so zoom does not make them unclickable.
class AnnotationHitGeometry {
  const AnnotationHitGeometry._();

  static double imageSizeForScreenMinimum(
    double imageSize,
    double scale, {
    required double minimumScreen,
  }) => math.max(imageSize, minimumScreen / math.max(scale.abs(), 0.01));

  static Offset handleCenter(Rect rect, AnnotationResizeHandle handle) =>
      switch (handle) {
        AnnotationResizeHandle.topLeft => rect.topLeft,
        AnnotationResizeHandle.topRight => rect.topRight,
        AnnotationResizeHandle.bottomLeft => rect.bottomLeft,
        AnnotationResizeHandle.bottomRight => rect.bottomRight,
      };

  /// Return the nearest eligible corner. At low zoom several minimum-size hit
  /// targets may overlap, so enum/list order must not determine the result.
  static AnnotationResizeHandle? hitResizeHandle(
    Rect rect,
    Offset imagePoint, {
    required double scale,
    double imageHitSize = 22,
    double minimumScreen = 24,
  }) {
    final size = imageSizeForScreenMinimum(
      imageHitSize,
      scale,
      minimumScreen: minimumScreen,
    );
    AnnotationResizeHandle? nearest;
    var nearestDistance = double.infinity;
    for (final handle in AnnotationResizeHandle.values) {
      final center = handleCenter(rect, handle);
      if (!Rect.fromCenter(
        center: center,
        width: size,
        height: size,
      ).contains(imagePoint)) {
        continue;
      }
      final distance = (center - imagePoint).distanceSquared;
      if (distance < nearestDistance) {
        nearest = handle;
        nearestDistance = distance;
      }
    }
    return nearest;
  }

  /// 无命中半径上限的最近角（Alt+点击把选中框最近顶点移到点击处的
  /// 纯逻辑）：点击可落在画布任意位置，只按距离取四角最近者。
  static AnnotationResizeHandle nearestHandle(Rect rect, Offset imagePoint) {
    AnnotationResizeHandle nearest = AnnotationResizeHandle.values.first;
    var nearestDistance = double.infinity;
    for (final handle in AnnotationResizeHandle.values) {
      final distance =
          (handleCenter(rect, handle) - imagePoint).distanceSquared;
      if (distance < nearestDistance) {
        nearest = handle;
        nearestDistance = distance;
      }
    }
    return nearest;
  }

  /// Prefer actual containment over nearby expanded targets. Last rectangles
  /// are painted on top; otherwise the closest center in screen space wins.
  static int? hitRectIndex(
    List<Rect> rects,
    Offset imagePoint, {
    required double scaleX,
    double? scaleY,
    double toleranceScreen = 7,
  }) {
    final sx = math.max(scaleX.abs(), 0.01);
    final sy = math.max((scaleY ?? scaleX).abs(), 0.01);
    int? nearest;
    var nearestDistance = double.infinity;
    for (var i = rects.length - 1; i >= 0; i--) {
      final rect = rects[i];
      if (rect.contains(imagePoint)) return i;
      final expanded = Rect.fromLTRB(
        rect.left - toleranceScreen / sx,
        rect.top - toleranceScreen / sy,
        rect.right + toleranceScreen / sx,
        rect.bottom + toleranceScreen / sy,
      );
      if (!expanded.contains(imagePoint)) continue;
      final delta = rect.center - imagePoint;
      final distance = math.pow(delta.dx * sx, 2) + math.pow(delta.dy * sy, 2);
      if (distance < nearestDistance) {
        nearest = i;
        nearestDistance = distance.toDouble();
      }
    }
    return nearest;
  }

  /// 右上角缩放：左边与底边固定，顶边/右边跟随指针。
  ///
  /// 固定边（left/bottom）直接沿用 original 的原值，拖动边各做一次
  /// 取整。顶边与高度若各自独立取整，显示比例把指针坐标映射到半整数
  /// 时两处会同时进位，固定底边随每个指针事件下移 1px（实测一次拖拽
  /// 累计 +59px）——即"拖右上角、其他顶点跟着偏移、框越调越大"的
  /// 根因。
  static Rect resizeTopRightRect(
    Rect original,
    double targetRight,
    double targetTop, {
    double minSize = 5,
  }) {
    final bottom = original.bottom;
    var top = targetTop.round();
    if (top < 0) top = 0;
    final maxTop = (bottom - minSize).floor();
    if (top > maxTop) top = maxTop;
    final minRight = original.left + minSize;
    var right = targetRight.round().toDouble();
    if (right < minRight) right = minRight;
    return Rect.fromLTRB(original.left, top.toDouble(), right, bottom);
  }

  /// 行卡片字框缩放的 Ctrl 联动——选取邻框（纯逻辑）。
  ///
  /// 沿阅读轴找与被拖框贴合边最近的邻框：竖排拖底边→下方邻框、拖顶边
  /// （[upward]）→上方邻框；横排 topRight/bottomRight 两柄都动右边→
  /// 右侧邻框。按中心坐标判定同侧（框轻微交叠不误选），再取贴合边最
  /// 近者；[draggedIndex] 为被拖框在 [charRects] 中的下标，无同侧邻框
  /// （行首/行尾字）返回 null。
  static int? linkedNeighborIndex(
    List<Rect> charRects,
    int draggedIndex, {
    required bool horizontal,
    bool upward = false,
  }) {
    if (draggedIndex < 0 || draggedIndex >= charRects.length) return null;
    final dragged = charRects[draggedIndex];
    double axis(Rect r) => horizontal ? r.center.dx : r.center.dy;
    final draggedAxis = axis(dragged);
    final wantBefore = !horizontal && upward;
    int? nearest;
    double? nearestEdge;
    for (var i = 0; i < charRects.length; i++) {
      if (i == draggedIndex) continue;
      final r = charRects[i];
      final before = axis(r) < draggedAxis;
      if (before != wantBefore) continue;
      // 贴合边：前方（阅读轴正向）邻框取 top/left，后方取 bottom/right。
      final edge = wantBefore
          ? (horizontal ? r.right : r.bottom)
          : (horizontal ? r.left : r.top);
      if (nearestEdge == null ||
          (wantBefore ? edge > nearestEdge : edge < nearestEdge)) {
        nearest = i;
        nearestEdge = edge;
      }
    }
    return nearest;
  }

  /// Ctrl 联动——邻框贴合边跟随被拖边同样的位移（纯逻辑）。
  ///
  /// 保持两框原有间距（偏移距离），**不对齐到同一位置**。邻框只动贴合
  /// 边、对边钉死；位移相对按下快照（[draggedOriginal]）取值且只取整一
  /// 次（防漂移，纪律同 [resizeTopRightRect] 的固定边）。钳制后贴合边
  /// 无位移返回 null。
  static Rect? linkedNeighborRect({
    required bool horizontal,
    bool upward = false,
    required Rect draggedOriginal,
    required Rect draggedUpdated,
    required Rect neighborOriginal,
    double minSize = 5,
  }) {
    if (!horizontal && upward) {
      // 竖排拖顶边：上方邻框的底边跟随。
      final delta = (draggedUpdated.top - draggedOriginal.top).round();
      var bottom = neighborOriginal.bottom + delta;
      final minBottom = neighborOriginal.top + minSize;
      if (bottom < minBottom) bottom = minBottom;
      if (bottom == neighborOriginal.bottom) return null;
      return Rect.fromLTRB(
        neighborOriginal.left,
        neighborOriginal.top,
        neighborOriginal.right,
        bottom,
      );
    }
    // 竖排拖底边：下方邻框的顶边跟随；横排拖右边：右侧邻框的左边跟随。
    final draggedEdge = horizontal
        ? draggedOriginal.right
        : draggedOriginal.bottom;
    final updatedEdge = horizontal
        ? draggedUpdated.right
        : draggedUpdated.bottom;
    final delta = (updatedEdge - draggedEdge).round();
    final pinnedFar = horizontal
        ? neighborOriginal.right
        : neighborOriginal.bottom;
    var near =
        (horizontal ? neighborOriginal.left : neighborOriginal.top) + delta;
    if (near < 0) near = 0;
    final maxNear = pinnedFar - minSize;
    if (near > maxNear) near = maxNear;
    if (near == (horizontal ? neighborOriginal.left : neighborOriginal.top)) {
      return null;
    }
    return horizontal
        ? Rect.fromLTRB(
            near,
            neighborOriginal.top,
            pinnedFar,
            neighborOriginal.bottom,
          )
        : Rect.fromLTRB(
            neighborOriginal.left,
            near,
            neighborOriginal.right,
            pinnedFar,
          );
  }

  /// 沿阅读轴按指定切线拆分（Alt 悬停虚线+点击切割，纯逻辑）：竖排
  /// 上下拆（[cut] 为绝对 Y）、横排左右拆（[cut] 为绝对 X）。切线取整
  /// 像素并钳进两侧各留 [minSize] 的有效区（悬停虚线用同一钳制显示，
  /// 所见即所切）；轴向长度不足 2×[minSize] 返回 null（切不出两个最小
  /// 框）。返回 (前半, 后半)，坐标保持整数、两段之和恒等于原长。
  static (Rect, Rect)? splitRectAt(
    Rect rect, {
    required double cut,
    required bool horizontal,
    double minSize = 5,
  }) {
    if (horizontal) {
      if (rect.width < minSize * 2) return null;
      final x = cut.roundToDouble().clamp(
        rect.left + minSize,
        rect.right - minSize,
      );
      return (
        Rect.fromLTRB(rect.left, rect.top, x, rect.bottom),
        Rect.fromLTRB(x, rect.top, rect.right, rect.bottom),
      );
    }
    if (rect.height < minSize * 2) return null;
    final y = cut.roundToDouble().clamp(
      rect.top + minSize,
      rect.bottom - minSize,
    );
    return (
      Rect.fromLTRB(rect.left, rect.top, rect.right, y),
      Rect.fromLTRB(rect.left, y, rect.right, rect.bottom),
    );
  }

  static Rect resizeRect(
    Rect original,
    Offset imagePointer,
    AnnotationResizeHandle handle, {
    Offset pointerOffset = Offset.zero,
    required double minSize,
  }) {
    final target = imagePointer - pointerOffset;
    var left = original.left;
    var top = original.top;
    var right = original.right;
    var bottom = original.bottom;
    switch (handle) {
      case AnnotationResizeHandle.topLeft:
        // Snap only the edge being dragged.  The opposite edges deliberately
        // remain the exact values from `original`; callers update integer
        // annotations on every pointer event, so rounding both edges would
        // make the supposedly fixed side drift by a pixel on each event.
        left = math.min(target.dx.roundToDouble(), original.right - minSize);
        top = math.min(target.dy.roundToDouble(), original.bottom - minSize);
      case AnnotationResizeHandle.topRight:
        right = math.max(target.dx.roundToDouble(), original.left + minSize);
        top = math.min(target.dy.roundToDouble(), original.bottom - minSize);
      case AnnotationResizeHandle.bottomLeft:
        left = math.min(target.dx.roundToDouble(), original.right - minSize);
        bottom = math.max(target.dy.roundToDouble(), original.top + minSize);
      case AnnotationResizeHandle.bottomRight:
        right = math.max(target.dx.roundToDouble(), original.left + minSize);
        bottom = math.max(target.dy.roundToDouble(), original.top + minSize);
    }
    return Rect.fromLTRB(math.max(0, left), math.max(0, top), right, bottom);
  }
}

/// 新字按几何阅读序插入行内的落点下标（编辑器 _insertCharInReadingOrder
/// 的纯逻辑）：竖排按中心 Y（上→下）、横排按中心 X（ltr 左→右 /
/// rtl 右→左）。[axes] 为行内各字沿阅读轴的中心坐标（行内顺序），
/// [newAxis] 为新字的中心坐标，[rtl] 为本页生效的阅读方向。
///
/// 返回首个"排在新字之后"的字的下标（插到它前面）；没有则追加到行尾。
/// 阅读方向必须取本页生效设置（按页覆盖优先于整书）——整书列序 rtl
/// 的竖排书里按页覆盖成横排 ltr 的页若按整书 rtl 判读，行尾（右侧）
/// 新画的字会被插到行首（横排新字全跑到前面的根因）。
int readingOrderInsertIndex(
  List<double> axes,
  double newAxis, {
  required bool rtl,
}) {
  for (var i = 0; i < axes.length; i++) {
    final comesAfter = rtl ? axes[i] < newAxis : axes[i] > newAxis;
    if (comesAfter) return i;
  }
  return axes.length;
}

/// 把同一行内的两个字框合并为一个（多选合并快捷键的纯逻辑，可单测）：
/// 矩形取两框并集，文字按阅读轴拼接（与 [readingOrderInsertIndex] 同
/// 口径——横排按中心 X、rtl 右→左；竖排按中心 Y 上→下）。返回的新块
/// 沿用 [a] 的 id 与确认/标记等元数据，origText 清空（人工合并产物不
/// 再是识别输出的原始读法基线，不参与正确率统计）；是否触发重识别由
/// 调用方决定。
CharBlock mergeCharBoxes(
  CharBlock a,
  CharBlock b, {
  required bool horizontal,
  required bool rtl,
}) {
  double axisOf(CharBlock c) => horizontal ? c.x + c.w / 2 : c.y + c.h / 2;
  final (first, second) = (rtl ? axisOf(a) > axisOf(b) : axisOf(a) <= axisOf(b))
      ? (a, b)
      : (b, a);
  final left = math.min(a.x, b.x);
  final top = math.min(a.y, b.y);
  final right = math.max(a.x + a.w, b.x + b.w);
  final bottom = math.max(a.y + a.h, b.y + b.h);
  return first.copyWith(
    x: left,
    y: top,
    w: right - left,
    h: bottom - top,
    text: '${first.text}${second.text}',
    origText: '',
  );
}
