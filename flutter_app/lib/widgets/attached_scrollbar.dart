import 'package:flutter/material.dart';

/// Scrollbar + ScrollController 的防崩组合。
///
/// Scrollbar.paint 在 controller 未挂任何 ScrollPosition 时会抛
/// "The Scrollbar's ScrollController has no ScrollPosition attached"，
/// 直接崩掉整页——识别等后台任务运行时，日志面板随导航/重建把列表
/// 卸掉而 Scrollbar 还在树上绘制一帧，正好踩中这个窗口。
///
/// 这里利用 ScrollController 的 attach/detach 会触发 notifyListeners
/// 的特性：hasClients 为 false 时先裸渲染列表（不带滚动条），attach
/// 后自动带上。滚动期间 builder 虽每帧执行，但 child 是同一个 widget
/// 实例，Flutter 直接复用子树，无实际重建开销。
class AttachedScrollbar extends StatelessWidget {
  const AttachedScrollbar({
    super.key,
    required this.controller,
    required this.child,
    this.thumbVisibility,
    this.thickness,
    this.radius,
  });

  final ScrollController controller;
  final Widget child;

  /// 滑块常驻显示（不传走平台默认：桌面悬停才现身、平时隐形）。
  final bool? thumbVisibility;

  /// 滑块粗细。默认厚度在常驻场景偏细，建议显式给 8~12。
  final double? thickness;

  /// 滑块圆角半径。
  final Radius? radius;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      child: child,
      builder: (context, list) => controller.hasClients
          ? Scrollbar(
              controller: controller,
              thumbVisibility: thumbVisibility,
              thickness: thickness,
              radius: radius,
              child: list!,
            )
          : list!,
    );
  }
}
