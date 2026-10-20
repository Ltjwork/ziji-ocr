import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 校对界面卡片列表的 Ctrl+滚轮缩放感知层（以鼠标位置为锚点缩放）。
///
/// 用法：包在可滚动列表的内容（或列表项）外层——必须在滚动视图子树内、
/// 比滚动视图的手势层更深。按住 Ctrl 滚动滚轮时，本层比外层滚动视图先
/// 收到指针信号，通过 [PointerSignalResolver] 抢先注册空回调把事件从
/// 滚动视图手里拿走（resolver 只回调最先注册者，列表不会被普通滚动），
/// 滚轮位移按 [kCtrlWheelZoomPerPx] 折算成缩放系数驱动 [onZoom]（上滚
/// 放大，一格滚轮约 ±6%，触控板小步平滑，与校对摆正页 Ctrl+滚轮同款
/// 系数）；不按 Ctrl 时本层不注册，滚轮照常滚动列表。
///
/// **指针锚定**：[onZoom] 触发缩放 rebuild 后，本层把滚动位置预调到
/// `offset + content·(f−1)`（content 为指针在内容坐标系里的位置，等比
/// 缩放下与坐标同乘 f），使指针下的内容点缩放前后都停在指针处。列表
/// 布局不严格等比（卡片头部/工具行固定高等）时是近似锚定，仍远好于
/// 不锚定；缩放被上限钳住（内容尺寸不变，maxScrollExtent 不变）时本趟
/// 不跳，避免"没放大却平移"。
///
/// [HitTestBehavior.opaque] 让卡片之间的空隙与列表项边距也响应缩放
/// （悬停点落在内容外时默认 deferToChild 会漏掉指针信号）；本层只旁听
/// 事件不进手势竞技场，点按/拖拽交互不受影响。
class CtrlScrollZoomSurface extends StatelessWidget {
  const CtrlScrollZoomSurface({
    super.key,
    required this.child,
    required this.onZoom,
  });

  final Widget child;

  /// factor > 1 放大、< 1 缩小（连续系数，上限钳制由调用方负责）。
  final ValueChanged<double> onZoom;

  /// 每像素滚轮位移的缩放底数：一格滚轮（±120px）≈ ±6%。
  static const double kCtrlWheelZoomPerPx = 1.0005;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerSignal: (event) => _handleSignal(context, event),
      child: child,
    );
  }

  void _handleSignal(BuildContext context, PointerSignalEvent event) {
    if (event is! PointerScrollEvent || event.scrollDelta.dy == 0) return;
    if (!HardwareKeyboard.instance.isControlPressed) return;
    // 空回调先注册：外层滚动视图随后注册会被 resolver 丢弃。
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {});
    final factor = math
        .pow(kCtrlWheelZoomPerPx, -event.scrollDelta.dy)
        .toDouble();
    _anchorScroll(context, event, factor);
    onZoom(factor);
  }

  /// 指针锚定：缩放 rebuild 完成后跳到锚定偏移（见类注释）。
  void _anchorScroll(
    BuildContext context,
    PointerScrollEvent event,
    double factor,
  ) {
    if (factor == 1) return;
    final scrollable = Scrollable.maybeOf(context);
    if (scrollable == null) return;
    final position = scrollable.position;
    if (!position.hasPixels || !position.hasContentDimensions) return;
    final viewportBox = scrollable.context.findRenderObject();
    if (viewportBox is! RenderBox || !viewportBox.hasSize) return;
    final local = viewportBox.globalToLocal(event.position);
    final pointerCoord = scrollable.widget.axis == Axis.vertical
        ? local.dy
        : local.dx;
    final contentCoord = position.pixels + pointerCoord;
    final oldMax = position.maxScrollExtent;
    final target = position.pixels + contentCoord * (factor - 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!scrollable.mounted) return;
      if (!position.hasPixels || !position.hasContentDimensions) return;
      // 内容尺寸没变＝缩放被钳制没生效：不跳，避免纯平移。
      if ((position.maxScrollExtent - oldMax).abs() < 0.5) return;
      position.jumpTo(target.clamp(0.0, position.maxScrollExtent));
    });
  }
}
