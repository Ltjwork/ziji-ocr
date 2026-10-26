import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/pages/editor_page.dart' show AnnotationCanvas;

/// 区/段/行视图 Alt 顶点抓取回归：按住 Alt 悬停显示引导线，Alt+单击把
/// 选中框离点击最近的顶点贴到点击处、拖动继续跟随，松开提交（用户实测
/// 报告该功能失效，排查确认画布手势链本身完好，此测试锁住该行为）。
/// 直接驱动真实画布手势链（Listener.onPointerDown → _tryAltVertexGrab
/// → onUpdateLine）。
late Directory _tempDir;
late String _imagePath;
var _imageReady = false;

/// 生成 200×200 白图 PNG（画布经真实文件 IO 解码，需 runAsync 让真实
/// 时间流动；onImageReady 回调置位后画布才退出加载占位）。
Future<void> _ensureImage(WidgetTester tester) async {
  if (_imageReady) return;
  _tempDir = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('alt_vertex_test'),
  ))!;
  _imagePath = '${_tempDir.path}${Platform.pathSeparator}page.png';
  final image = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 200, 200),
      Paint()..color = Colors.white,
    );
    return recorder.endRecording().toImage(200, 200);
  });
  final data = await tester.runAsync(
    () => image!.toByteData(format: ui.ImageByteFormat.png),
  );
  await tester.runAsync(
    () => File(_imagePath).writeAsBytes(data!.buffer.asUint8List()),
  );
  image!.dispose();
  _imageReady = true;
}

LineBlock _line() => LineBlock(
  id: 'L1',
  x: 50,
  y: 60,
  w: 80,
  h: 30,
  lineNo: 0,
  orientation: 'vertical',
  chars: const [],
);

/// 泵入画布并等待真实图片解码完成。不用 pumpAndSettle：图片加载前的
/// 占位转圈会无限排帧导致 settle 超时，全程用 pump。
Future<void> _pumpCanvas(
  WidgetTester tester,
  LineBlock sel,
  void Function(LineBlock, LineBlock) onUpdateLine,
) async {
  var ready = false;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 200,
            height: 200,
            child: AnnotationCanvas(
              imagePath: _imagePath,
              lines: [sel],
              blocks: const [],
              selected: null,
              selectedLine: sel,
              viewMode: 'line',
              showIndex: false,
              showCharBox: false,
              onSelect: (_) {},
              onAdd: (_) {},
              onAddLine: (_) {},
              onSelectLine: (_) {},
              onReorderLine: (_) {},
              onReorderParagraph: (_) {},
              onUpdate: (_, __) {},
              onUpdateLine: onUpdateLine,
              onImageReady: (_) => ready = true,
            ),
          ),
        ),
      ),
    ),
  );
  for (var i = 0; i < 40 && !ready; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  expect(ready, isTrue, reason: '画布图片应完成解码（onImageReady）');
  await tester.pump();
}

void main() {
  tearDownAll(() async {
    if (_imageReady && _tempDir.existsSync()) {
      await _tempDir.delete(recursive: true);
    }
  });

  testWidgets(
    '行视图：按住 Alt 单击，选中框最近顶点贴到点击处并跟随拖动',
    (tester) async {
      await _ensureImage(tester);
      final sel = _line();
      final updates = <(LineBlock, LineBlock)>[];

      await _pumpCanvas(tester, sel, (o, n) => updates.add((o, n)));

      // 悬停到画布中部，再按住 Alt（引导线依赖悬停位置与 isAltPressed）。
      await tester.sendEventToBinding(
        PointerHoverEvent(position: const Offset(100, 100)),
      );
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();

      // Alt+单击 (30,70)：选中框 (50,60,80,30) 的四角里 (50,60) 最近
      // → topLeft 抓取后左上顶点应为 (30,70)，对角 (130,90) 钉死。
      final gesture = await tester.startGesture(
        const Offset(30, 70),
        kind: PointerDeviceKind.mouse,
        buttons: kPrimaryMouseButton,
      );
      await tester.pump();
      await gesture.moveBy(const Offset(5, 3));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(updates, isNotEmpty, reason: 'Alt+单击应触发行框更新（顶点贴指针）');
      final (old, neu) = updates.first;
      expect(identical(old, sel), isTrue);
      // 首帧 = 点击吸附：左上顶点直接贴到点击处 (30,70)。
      expect(neu.x, 30);
      expect(neu.y, 70);
      expect(neu.w, 100); // 对角 (130,90) 钉死：w=130-30=100、h=90-70=20
      expect(neu.h, 20);
      // 末帧 = 拖动跟随：moveBy(5,3) 后左上顶点 x 到 35（y 顶边受
      // 对角钉死钳制保持 70）。
      expect(updates.last.$2.x, 35);

      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  testWidgets(
    '行视图：不按 Alt 单击不接管手势（走原有选择/画框逻辑）',
    (tester) async {
      await _ensureImage(tester);
      final sel = _line();
      final updates = <(LineBlock, LineBlock)>[];

      await _pumpCanvas(tester, sel, (o, n) => updates.add((o, n)));

      final gesture = await tester.startGesture(
        const Offset(30, 70),
        kind: PointerDeviceKind.mouse,
        buttons: kPrimaryMouseButton,
      );
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(updates, isEmpty, reason: '不按 Alt 时普通单击不应移动顶点');
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
