import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/pages/editor_page.dart' show AnnotationCanvas;

/// 段/行视图跨类画版面框（用户需求：切换「新框类别」的快捷键 1~8 在段/
/// 行视图也要生效，选了页眉/页脚等非正文类别时空白拖拽直接画该版面框，
/// 点框可选中拖动，不用切回主区视图）。本测试直接驱动真实画布手势链，
/// 验证画框分发与版面类型框的段/行视图点选拖动。
///
/// 手势与等待沿用 alt_vertex_grab_test 的范式：startGesture（mouse 主键）
/// 逐步 move/up、图片解码用 runAsync+pump 有界循环等完。注意 widget 测试
/// 区里的**一切真实 IO await 都要包 tester.runAsync**（File 写盘不包会
/// 在部分环境下永远等不到完成事件，整条用例挂死——alt_vertex 曾踩同款）。
late Directory _tempDir;
late String _imagePath;
var _imageReady = false;

Future<void> _ensureImage(WidgetTester tester) async {
  if (_imageReady) return;
  _tempDir = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('typed_region_draw_test'),
  ))!;
  _imagePath = '${_tempDir.path}${Platform.pathSeparator}page.png';
  final image = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
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

/// 等画布整页图解码完成（与 multibox 测试同一口径：runAsync 真延时 +
/// pump 交替，图片加载转圈消失后画布才可交互）。
Future<void> _waitForImage(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
  }
}

MainRegion _headerRegion() => MainRegion(
  id: 'mr_h1',
  x: 10,
  y: 10,
  w: 100,
  h: 25,
  label: RegionLabel.header,
);

Widget _canvas({
  required String viewMode,
  String newRegionLabel = RegionLabel.mainText,
  List<MainRegion> mainRegions = const [],
  void Function(MainRegion)? onAddRegion,
  void Function(MainRegion?)? onSelectRegion,
  void Function(MainRegion, MainRegion)? onUpdateRegion,
  void Function(Paragraph)? onAddParagraph,
  void Function(LineBlock)? onAddLine,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 200,
          height: 200,
          child: AnnotationCanvas(
            imagePath: _imagePath,
            lines: const [],
            blocks: const [],
            selected: null,
            selectedLine: null,
            viewMode: viewMode,
            showIndex: false,
            showCharBox: false,
            onSelect: (_) {},
            onAdd: (_) {},
            onAddLine: onAddLine ?? (_) {},
            onSelectLine: (_) {},
            onReorderLine: (_) {},
            onReorderParagraph: (_) {},
            onUpdate: (_, __) {},
            onUpdateLine: (_, __) {},
            mainRegions: mainRegions,
            newRegionLabel: newRegionLabel,
            onAddRegion: onAddRegion ?? (_) {},
            onSelectRegion: onSelectRegion ?? (_) {},
            onUpdateRegion: onUpdateRegion ?? (_, __) {},
            onAddParagraph: onAddParagraph ?? (_) {},
          ),
        ),
      ),
    ),
  );
}

/// 空白处从 [start] 拖到 [end]（mouse 主键，逐步 move，与真实手况同链）。
Future<void> _dragBlank(
  WidgetTester tester,
  Offset start,
  Offset end,
) async {
  final gesture = await tester.startGesture(
    start,
    kind: PointerDeviceKind.mouse,
    buttons: kPrimaryMouseButton,
  );
  await tester.pump();
  final half = Offset(
    (end.dx - start.dx) / 2,
    (end.dy - start.dy) / 2,
  );
  await gesture.moveBy(half);
  await tester.pump();
  await gesture.moveBy(end - start - half);
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

void main() {
  tearDownAll(() async {
    // 图像解码器可能仍持有文件句柄，删不掉就留着（系统临时目录）。
    try {
      if (_imageReady && _tempDir.existsSync()) {
        await _tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  testWidgets('段视图选页眉类别：空白拖拽画页眉版面框，不画段框', (tester) async {
    await _ensureImage(tester);
    final added = <MainRegion>[];
    var paragraphsAdded = 0;

    await tester.pumpWidget(
      _canvas(
        viewMode: 'paragraph',
        newRegionLabel: RegionLabel.header,
        onAddRegion: added.add,
        onAddParagraph: (_) => paragraphsAdded++,
      ),
    );
    await _waitForImage(tester);

    await _dragBlank(tester, const Offset(60, 80), const Offset(120, 140));
    await tester.pump();

    expect(added, hasLength(1));
    expect(added.single.label, RegionLabel.header);
    expect(added.single.x, 60);
    expect(added.single.y, 80);
    expect(added.single.w, 60);
    expect(added.single.h, 60);
    expect(paragraphsAdded, 0);
  });

  testWidgets('段视图正文类别：拖拽照旧画段框（回归）', (tester) async {
    await _ensureImage(tester);
    final added = <MainRegion>[];
    final paragraphs = <Paragraph>[];

    await tester.pumpWidget(
      _canvas(
        viewMode: 'paragraph',
        onAddRegion: added.add,
        onAddParagraph: paragraphs.add,
      ),
    );
    await _waitForImage(tester);

    await _dragBlank(tester, const Offset(60, 80), const Offset(120, 140));
    await tester.pump();

    expect(added, isEmpty);
    expect(paragraphs, hasLength(1));
  });

  testWidgets('行视图选页码类别：空白拖拽画页码版面框，不画行框', (tester) async {
    await _ensureImage(tester);
    final added = <MainRegion>[];
    var linesAdded = 0;

    await tester.pumpWidget(
      _canvas(
        viewMode: 'line',
        newRegionLabel: RegionLabel.pageNumber,
        onAddRegion: added.add,
        onAddLine: (_) => linesAdded++,
      ),
    );
    await _waitForImage(tester);

    await _dragBlank(tester, const Offset(40, 100), const Offset(140, 70));
    await tester.pump();

    expect(added, hasLength(1));
    expect(added.single.label, RegionLabel.pageNumber);
    expect(linesAdded, 0);
  });

  testWidgets('段视图点页眉框：选中并可整体拖动', (tester) async {
    await _ensureImage(tester);
    final header = _headerRegion();
    MainRegion? selected;
    final updates = <(MainRegion, MainRegion)>[];

    await tester.pumpWidget(
      _canvas(
        viewMode: 'paragraph',
        mainRegions: [header],
        onSelectRegion: (r) => selected = r,
        onUpdateRegion: (o, n) => updates.add((o, n)),
      ),
    );
    await _waitForImage(tester);

    // 页眉框内部 (50,20) 按下拖动 (20,30) → 选中 + 整体移动
    // （x +20 / y +30，宽高不变）。单次 moveBy（连发会被并成同一事件），
    // 框留窄些避开 _clampMovePos 的图片边界钳制。
    final gesture = await tester.startGesture(
      const Offset(50, 20),
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await tester.pump();
    await gesture.moveBy(const Offset(20, 30));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(selected?.id, 'mr_h1');
    expect(updates, hasLength(1));
    expect(identical(updates.single.$1, header), isTrue);
    final neu = updates.single.$2;
    expect(neu.id, 'mr_h1');
    expect(neu.x, 30);
    expect(neu.y, 40);
    expect(neu.w, 100);
    expect(neu.h, 25);
  });
}
