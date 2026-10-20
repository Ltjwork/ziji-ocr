import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/widgets/ctrl_scroll_zoom.dart';

/// CtrlScrollZoomSurface：校对界面 Ctrl+滚轮缩放卡片的感知层。
///
/// 关键回归：
/// - 感知层长在滚动视图子树内，必须先于外层滚动视图在
///   PointerSignalResolver 注册（resolver 只回调最先注册者），把 Ctrl+滚轮
///   从滚动视图手里拿走——列表不被普通滚动，缩放生效；
/// - **以鼠标位置为锚点**：缩放 rebuild 后滚动位置跳到
///   `offset + content·(f−1)`，等比缩放的列表里指针下的内容点不动；
/// - 缩放被钳制没生效（内容尺寸不变）时不跳，避免"没放大却平移"；
/// - 不按 Ctrl 时感知层不注册，滚轮照常滚动列表、缩放回调零触发；
/// - 命中覆盖卡片间空隙（HitTestBehavior.opaque）。
void main() {
  const itemCount = 60;
  const itemHeight = 40.0;
  const viewportHeight = 600.0;

  Future<void> pumpList(
    WidgetTester tester,
    ScrollController controller,
    List<double> zoomLog, {
    bool scaleFrozen = false,
    EdgeInsets padding = EdgeInsets.zero,
  }) async {
    tester.view.physicalSize = const Size(800, viewportHeight);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _ScalingList(
            controller: controller,
            zoomLog: zoomLog,
            scaleFrozen: scaleFrozen,
            itemCount: itemCount,
            itemHeight: itemHeight,
            padding: padding,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> ctrlWheel(
    WidgetTester tester,
    Offset position,
    double dy,
  ) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        device: 7,
        kind: PointerDeviceKind.mouse,
        position: position,
        scrollDelta: Offset(0, dy),
      ),
    );
    await tester.pump(); // 缩放 rebuild + 布局，postFrame 锚定 jumpTo 落地
    await tester.pump(); // jumpTo 引发的重排落地
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  double factorFor(double dy) =>
      math.pow(CtrlScrollZoomSurface.kCtrlWheelZoomPerPx, -dy).toDouble();

  testWidgets('Ctrl+滚轮上滚：以鼠标位置为锚点缩放，指针下内容点不动', (tester) async {
    final controller = ScrollController();
    final zoomLog = <double>[];
    await pumpList(tester, controller, zoomLog);
    controller.jumpTo(400);
    await tester.pump();

    // 指针在视口 y=300 → 内容坐标 700，落在第 17 格（700/40=17.5）。
    const pointer = Offset(200, 300);
    await ctrlWheel(tester, pointer, -120);
    final f = factorFor(-120);

    expect(zoomLog, hasLength(1));
    expect(zoomLog.single, closeTo(f, 1e-9));
    final expected = 400 + (400 + pointer.dy) * (f - 1);
    expect(controller.offset, closeTo(expected, 0.5));
    // 指针下的内容坐标随缩放同乘 f：分数格位不变（仍在第 17 格同位置）。
    final anchorBefore = (400 + pointer.dy) / itemHeight;
    final anchorAfter = (controller.offset + pointer.dy) / (itemHeight * f);
    expect(anchorAfter, closeTo(anchorBefore, 0.01));
  });

  testWidgets('Ctrl+滚轮下滚落在边距空隙：opaque 命中并按同一公式锚定', (tester) async {
    final controller = ScrollController();
    final zoomLog = <double>[];
    await pumpList(
      tester,
      controller,
      zoomLog,
      padding: const EdgeInsets.all(24),
    );
    controller.jumpTo(400);
    await tester.pump();

    // 悬停点取内边距区（感知层 opaque 覆盖，不在任何卡片上）。
    const pointer = Offset(5, 5);
    await ctrlWheel(tester, pointer, 120);
    final f = factorFor(120);

    expect(zoomLog, hasLength(1));
    expect(zoomLog.single, closeTo(f, 1e-9));
    final expected = 400 + (400 + pointer.dy) * (f - 1);
    expect(controller.offset, closeTo(expected, 0.5));
  });

  testWidgets('缩放被钳制没生效（内容尺寸不变）：不跳偏移', (tester) async {
    final controller = ScrollController();
    final zoomLog = <double>[];
    await pumpList(tester, controller, zoomLog, scaleFrozen: true);
    controller.jumpTo(400);
    await tester.pump();

    await ctrlWheel(tester, const Offset(200, 300), -120);

    expect(zoomLog, hasLength(1), reason: '缩放回调照常触发');
    expect(controller.offset, 400.0, reason: '内容尺寸没变，锚定不跳');
  });

  testWidgets('普通滚轮：照常滚动列表，缩放回调零触发', (tester) async {
    final controller = ScrollController();
    final zoomLog = <double>[];
    await pumpList(tester, controller, zoomLog);

    await tester.sendEventToBinding(
      PointerScrollEvent(
        device: 7,
        kind: PointerDeviceKind.mouse,
        position: const Offset(200, 300),
        scrollDelta: const Offset(0, 120),
      ),
    );
    await tester.pump();

    expect(zoomLog, isEmpty);
    expect(controller.offset, closeTo(120.0, 1e-6));
  });
}

/// 测试体：等比缩放的字格列表——格子高 40×scale（宽固定 400），列表
/// 高度随 scale 严格等比，锚定公式可精确断言。scaleFrozen 模拟缩放被
/// 上限钳住（回调照常、内容不变）。
class _ScalingList extends StatefulWidget {
  const _ScalingList({
    required this.controller,
    required this.zoomLog,
    required this.scaleFrozen,
    required this.itemCount,
    required this.itemHeight,
    required this.padding,
  });

  final ScrollController controller;
  final List<double> zoomLog;
  final bool scaleFrozen;
  final int itemCount;
  final double itemHeight;
  final EdgeInsets padding;

  @override
  State<_ScalingList> createState() => _ScalingListState();
}

class _ScalingListState extends State<_ScalingList> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: widget.controller,
      child: CtrlScrollZoomSurface(
        onZoom: (f) {
          widget.zoomLog.add(f);
          if (widget.scaleFrozen) return;
          setState(() {
            _scale = (_scale * f).clamp(0.5, 3.0);
          });
        },
        child: Padding(
          padding: widget.padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < widget.itemCount; i++)
                Container(
                  height: widget.itemHeight * _scale,
                  width: 400,
                  color: Colors.blueGrey.shade100,
                  alignment: Alignment.center,
                  child: Text('item $i'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
