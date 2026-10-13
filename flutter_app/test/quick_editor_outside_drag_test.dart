import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 主区快设编辑器画布结构的回归测试（+91 引入、+92 修正）。两个历史
/// 坑：① InteractiveViewer 即使 panEnabled/scaleEnabled 全关，其内部
/// scale 识别器仍在手势竞技场（更深处先入场、默认裁决获胜），外层
/// 画框手势一条都收不到——页面内外都画不了框；② GestureDetector 的
/// 命中范围随 child 尺寸，Transform 的渲染尺寸=页面尺寸，不铺开的话
/// 手势层缩成页面大小，页外空白收不到事件。修正后的结构：
/// Listener（右键平移）→ GestureDetector（画框）→ Listener（滚轮）→
/// SizedBox.expand（手势层铺满视口）→ ClipRect → OverflowBox（页面
/// 子树保持 1:1）→ Transform → 页面尺寸 SizedBox。
void main() {
  Matrix4 transformValue = Matrix4.identity();

  Widget buildCanvas(void Function(String) onEvent) {
    final transform = TransformationController();
    transformValue = transform.value;
    return MaterialApp(
      home: Scaffold(
        body: Listener(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (d) => onEvent('start'),
            onPanUpdate: (d) => onEvent('update'),
            onPanEnd: (d) => onEvent('end'),
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerSignal: (signal) {
                if (signal is PointerScrollEvent) onEvent('scroll');
              },
              child: SizedBox.expand(
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.topLeft,
                    minWidth: 0.0,
                    minHeight: 0.0,
                    maxWidth: double.infinity,
                    maxHeight: double.infinity,
                    child: AnimatedBuilder(
                      animation: transform,
                      builder: (context, _) => Transform(
                        transform: transform.value,
                        child: const SizedBox(
                          width: 200,
                          height: 400,
                          child: ColoredBox(color: Colors.red),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('页面外空白处按下拖动也能收到 pan 手势', (tester) async {
    final events = <String>[];
    await tester.pumpWidget(buildCanvas(events.add));

    // 默认测试视口 800x600；页面 200x400，(700, 300) 在页面外空白。
    await tester.dragFrom(const Offset(700, 300), const Offset(-40, 0));
    await tester.pump();

    expect(events, contains('start'));
    expect(events, contains('update'));
    expect(events, contains('end'));
  });

  testWidgets('页面内按下拖动手势同样正常（不回归）', (tester) async {
    final events = <String>[];
    await tester.pumpWidget(buildCanvas(events.add));

    await tester.dragFrom(const Offset(100, 200), const Offset(30, 30));
    await tester.pump();
    expect(events, contains('start'));
    expect(events, contains('end'));
  });

  testWidgets('滚轮缩放事件到达且不与画框手势冲突', (tester) async {
    final events = <String>[];
    await tester.pumpWidget(buildCanvas(events.add));

    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: const Offset(400, 300),
        scrollDelta: const Offset(0, 53),
      ),
    );
    await tester.pump();
    expect(events, contains('scroll'));
    expect(transformValue, isNotNull);
  });

  testWidgets('页面子树保持 1:1 自身尺寸，不被视口约束拉伸（+94 回归）',
      (tester) async {
    final events = <String>[];
    await tester.pumpWidget(buildCanvas(events.add));

    // 视口 800x600，页面 200x400：OverflowBox 少了四个边界参数时是空
    // 操作，页面 SizedBox 会被视口 tight 约束拉成 800x600，整页图像被
    // 拉伸绘制（用户实测截图的错乱根因）。
    final pageRect = tester.getRect(
      find.byWidgetPredicate(
        (w) => w is SizedBox && w.width == 200 && w.height == 400,
      ),
    );
    expect(pageRect.size, const Size(200, 400));
    // 手势层（SizedBox.expand）铺满视口。
    expect(
      tester.getRect(
        find.byWidgetPredicate(
          (w) => w is SizedBox && w.width == double.infinity,
        ),
      ).size,
      const Size(800, 600),
    );
  });
}
