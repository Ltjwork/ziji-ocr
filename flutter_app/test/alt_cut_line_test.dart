import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/pages/editor_page.dart' show InteractiveLineCrop;

/// 单字校对 Alt 切割：悬停时识别框内显示跟随鼠标的切割虚线，点击按
/// 切线位置切割（不再是平分）。竖排行 = 水平线上下切；切线钳进两侧
/// 各留最小框 5px 的有效区（悬停显示与点击切割同一钳制，所见即所切）。
void main() {
  testWidgets('Alt 悬停显示切割虚线，点击按鼠标位置切割（非平分）', (tester) async {
    final image = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 100, 100),
        Paint()..color = Colors.white,
      );
      return recorder.endRecording().toImage(100, 100);
    });

    // 竖排行：字框 abs(20,30,30,20)，行原点 (10,20)，画布 1:1 显示。
    final line = LineBlock(
      id: 'L1',
      x: 10,
      y: 20,
      w: 60,
      h: 40,
      lineNo: 0,
      orientation: 'vertical',
      chars: [
        CharBlock(
          id: 'c1',
          x: 20,
          y: 30,
          w: 30,
          h: 20,
          col: 0,
          order: 0,
          lineId: 'L1',
        ),
      ],
    );

    CharBlock? updated;
    CharBlock? added;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: InteractiveLineCrop(
              image: image!,
              srcRect: const Rect.fromLTWH(0, 0, 100, 100),
              line: line,
              displayWidth: 100,
              displayHeight: 100,
              selected: null,
              flashCharId: null,
              onCharUpdated: (old, neu) => updated = neu,
              onCharAdded: (c) => added = c,
              onCharSelected: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // Alt 悬停在 display (25,15) → 行内相对 y=15 → abs y=35（框中点
    // 是 abs 40，刻意偏上证明按鼠标位置切）。框 y 30..50、有效区
    // [35,45]，35 恰在钳制下界。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendEventToBinding(
      PointerHoverEvent(position: const Offset(25, 15)),
    );
    await tester.pump();

    final cp = tester.widget<CustomPaint>(
      find
          .descendant(
            of: find.byType(InteractiveLineCrop),
            matching: find.byType(CustomPaint),
          )
          .first,
    );
    final altCut = (cp.painter as dynamic).altCutLine as (Rect, bool, double)?;
    expect(altCut, isNotNull, reason: '按住 Alt 悬停字框 → 显示切割虚线');
    expect(
      altCut!.$1,
      const Rect.fromLTWH(10, 10, 30, 20),
      reason: '命中的字框（行内相对）',
    );
    expect(altCut.$2, isFalse, reason: '竖排行 = 水平切割线（上下切）');
    expect(altCut.$3, 15.0, reason: '切线 abs 35 − line.y 20 = 行内相对 15');

    // Alt+点击同位置：按切线切割（原框改写为前半，后半为新框），
    // 而不是平分（平分切在 abs 40）。
    await tester.sendEventToBinding(
      PointerDownEvent(
        buttons: kPrimaryMouseButton,
        position: const Offset(25, 15),
      ),
    );
    await tester.pump();

    expect(updated, isNotNull, reason: '原框就地改成前半');
    expect(updated!.x, 20);
    expect(updated!.y, 30);
    expect(updated!.w, 30);
    expect(updated!.h, 5, reason: '前半 = 30..35（按切线，非平分的 30..40）');
    expect(added, isNotNull, reason: '后半作为新字框加入');
    expect(added!.x, 20);
    expect(added!.y, 35);
    expect(added!.w, 30);
    expect(added!.h, 15);
    expect(added!.lineId, 'L1');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  });

  testWidgets('不按 Alt 或悬停在框外：无切割虚线；Alt 松开即清', (tester) async {
    final image = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 100, 100),
        Paint()..color = Colors.white,
      );
      return recorder.endRecording().toImage(100, 100);
    });

    final line = LineBlock(
      id: 'L1',
      x: 10,
      y: 20,
      w: 60,
      h: 40,
      lineNo: 0,
      orientation: 'vertical',
      chars: [
        CharBlock(
          id: 'c1',
          x: 20,
          y: 30,
          w: 30,
          h: 20,
          col: 0,
          order: 0,
          lineId: 'L1',
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: InteractiveLineCrop(
              image: image!,
              srcRect: const Rect.fromLTWH(0, 0, 100, 100),
              line: line,
              displayWidth: 100,
              displayHeight: 100,
              selected: null,
              flashCharId: null,
              onCharUpdated: (_, _) {},
              onCharAdded: (_) {},
              onCharSelected: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    ui.Image? noChange = image;
    expect(noChange, isNotNull);

    // 不按 Alt 悬停框内：无虚线。
    await tester.sendEventToBinding(
      PointerHoverEvent(position: const Offset(25, 15)),
    );
    await tester.pump();
    var cp = tester.widget<CustomPaint>(
      find
          .descendant(
            of: find.byType(InteractiveLineCrop),
            matching: find.byType(CustomPaint),
          )
          .first,
    );
    expect((cp.painter as dynamic).altCutLine as (Rect, bool, double)?, isNull);

    // 按住 Alt 悬停框外空白：同样无虚线。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendEventToBinding(
      PointerHoverEvent(position: const Offset(80, 80)),
    );
    await tester.pump();
    cp = tester.widget<CustomPaint>(
      find
          .descendant(
            of: find.byType(InteractiveLineCrop),
            matching: find.byType(CustomPaint),
          )
          .first,
    );
    expect((cp.painter as dynamic).altCutLine as (Rect, bool, double)?, isNull);

    // 悬停框内出虚线 → 松开 Alt 即清（鼠标不动也生效）。
    await tester.sendEventToBinding(
      PointerHoverEvent(position: const Offset(25, 15)),
    );
    await tester.pump();
    cp = tester.widget<CustomPaint>(
      find
          .descendant(
            of: find.byType(InteractiveLineCrop),
            matching: find.byType(CustomPaint),
          )
          .first,
    );
    expect(
      (cp.painter as dynamic).altCutLine as (Rect, bool, double)?,
      isNotNull,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    cp = tester.widget<CustomPaint>(
      find
          .descendant(
            of: find.byType(InteractiveLineCrop),
            matching: find.byType(CustomPaint),
          )
          .first,
    );
    expect(
      (cp.painter as dynamic).altCutLine as (Rect, bool, double)?,
      isNull,
      reason: 'Alt 松开即清虚线',
    );
  });
}
