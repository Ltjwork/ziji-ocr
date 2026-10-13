import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/pages/book_region_grid_page.dart';
import 'package:gujichazi/services/storage.dart';
import 'package:gujichazi/services/train_auto_export.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// 主区快设编辑器"每类多条框"的真实链路测试（+128 引入）：网格点格子
/// 进编辑器 → 同类拖出两个框（不再互相覆盖）→ 切页眉类再拖一个 →
/// 「确认并返回」落盘，标注 JSON 里 2 条正文 + 1 条页眉全部带
/// box_confirmed。另一条用例验证「删除当前框」只删当前类别的当前框。
void main() {
  late Directory tempDir;
  late Directory projectDir;
  late Project project;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('quick_editor_multibox');
    projectDir = Directory(p.join(tempDir.path, 'proj'));
    await projectDir.create(recursive: true);
    final file = File(p.join(projectDir.path, 'page_000.png'));
    await file.writeAsBytes(_pngBytes(100, 80));
    project = Project(
      id: 't1',
      name: '书',
      projectDir: projectDir.path,
      imageFiles: [p.join(projectDir.path, 'page_000.png')],
    );
  });

  setUp(() async {
    // 每条用例独立：清掉上一条用例落盘的标注（含 .bak）。
    final annDir = Directory(p.join(projectDir.path, 'annotations'));
    if (await annDir.exists()) {
      await annDir.delete(recursive: true);
    }
    // 确认保存会经 TrainExportScheduler 排一个 10 秒防抖导出定时器，
    // FakeAsync 的用例收尾校验 pending Timer 会整批误报（ tearDown
    // 晚于该校验，清理来不及）——测试内直接短路调度。
    TrainExportScheduler.debugDisabled = true;
  });

  tearDownAll(() async {
    // 图像解码器可能仍持有文件句柄，删不掉就留着（系统临时目录）。
    try {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  /// 泵网格 → 等缩略图/标注加载 → 点格子进编辑器 → 等整页图加载完成
  /// （加载转圈消失、标题到位即画布就绪；页上已有框时没有"拖拽"提示，
  /// 不能拿它当就绪标记）。
  Future<void> openEditor(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: BookRegionGridPage(project: project)));
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    // 网格格子 = _RegionCellPainter 所在的 CustomPaint。
    final cell = find.byWidgetPredicate(
      (w) => w is CustomPaint && '${w.painter.runtimeType}' == '_RegionCellPainter',
    );
    expect(cell, findsOneWidget);
    // 格子中心的命中检测会撞上上层角标（warning 无害：格子手势层是
    // opaque，点击照常到达 onTap）。
    await tester.tap(cell, warnIfMissed: false);
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
      final editorReady =
          find.textContaining('主区快设 · 第 1 / 1 页').evaluate().isNotEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty;
      if (editorReady) break;
    }
    await tester.pumpAndSettle();
    expect(find.textContaining('主区快设 · 第 1 / 1 页'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  }

  /// 「确认并返回」保存（真实异步 IO）并等待落盘完成。
  Future<Map<String, dynamic>> confirmAndRead(WidgetTester tester) async {
    await tester.tap(find.text('确认并返回'));
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    final f = File(p.join(projectDir.path, 'annotations', 'page_000.json'));
    expect(f.existsSync(), isTrue, reason: '保存应写入标注文件');
    return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  }

  testWidgets('同类拖出两个框 + 页眉一个框，确认后全部落盘', (tester) async {
    await openEditor(tester);

    // 整页适配后 100x80 的页约占 x 44..755 / y 15..585（fit 0.95）。
    // 两次拖拽互不重叠、互不在角点吸附圈（100 屏幕像素 ÷ 缩放 7.125 ≈
    // 14 页面像素）内——各画一个正文框。
    await tester.dragFrom(const Offset(100, 100), const Offset(120, 240));
    await tester.pump();
    await tester.dragFrom(const Offset(420, 100), const Offset(200, 240));
    await tester.pump();

    // 切到页眉（快捷键 2 的 ChoiceChip）再画一个矮框。
    await tester.tap(find.text('页眉 2'));
    await tester.pump();
    await tester.dragFrom(const Offset(150, 430), const Offset(200, 60));
    await tester.pump();

    final saved = await confirmAndRead(tester);
    final regions = (saved['main_regions'] as List).cast<Map<String, dynamic>>();
    final mains = regions
        .where((r) => r['label'] == RegionLabel.mainText)
        .toList();
    final headers = regions.where((r) => r['label'] == 'header').toList();
    expect(mains, hasLength(2), reason: '两个正文框都应落盘，不再互相覆盖');
    expect(headers, hasLength(1));
    for (final r in mains.followedBy(headers)) {
      expect(r['box_confirmed'], isTrue, reason: '确认并返回应打上确认标记');
    }
    // 两个正文框几何不同（第一次拖与第二次拖各成一块）。
    final rects = mains
        .map((r) => [r['x'], r['y'], r['w'], r['h']].join(','))
        .toSet();
    expect(rects, hasLength(2));
  });

  testWidgets('「删除当前框」只删当前类别里最后画的那个框', (tester) async {
    await openEditor(tester);

    await tester.dragFrom(const Offset(100, 100), const Offset(120, 240));
    await tester.pump();
    await tester.dragFrom(const Offset(420, 100), const Offset(200, 240));
    await tester.pump();

    // 当前框 = 最后画的第二个框；删除后应只剩第一个框。
    await tester.tap(find.text('删除当前框'));
    await tester.pump();

    final saved = await confirmAndRead(tester);
    final regions = (saved['main_regions'] as List).cast<Map<String, dynamic>>();
    final mains = regions
        .where((r) => r['label'] == RegionLabel.mainText)
        .toList();
    expect(mains, hasLength(1));
    // 剩下的是第一个框（左上角靠左）。
    expect(mains.single['x'], lessThan(50));
  });

  testWidgets('滚轮缩放双向生效且保留初始适配缩放（+128 回归）', (tester) async {
    await openEditor(tester);

    // 编辑器画布的 Transform（页面 CustomPaint 的祖先）：读它的 x/y 轴
    // 缩放。100x80 的页在 800x600 视口整页适配（×0.95）≈ 7.125。
    double canvasScale() {
      final pagePaint = find.byWidgetPredicate(
        (w) =>
            w is CustomPaint &&
            '${w.painter.runtimeType}' == '_RegionEditorPainter',
      );
      final transform = tester.widget<Transform>(
        find.ancestor(of: pagePaint, matching: find.byType(Transform)).first,
      );
      final s = transform.transform.storage;
      return math.sqrt(s[0] * s[0] + s[1] * s[1] + s[2] * s[2]);
    }

    final fit = canvasScale();
    // 整页适配缩放（视口扣掉 AppBar/类别栏/底栏后约 4.93，不写死数值，
    // 回归点在下面的比例关系）。
    expect(fit, allOf(greaterThan(0.05), lessThan(8.0)));

    // 向下滚两档：每档 ×0.9，缩放连续下降（旧 bug：矩阵被从恒等式
    // 整体重建，滚一次就跳成 0.9/1.1 本身且再也回不到适配缩放）。
    for (var i = 0; i < 2; i++) {
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: const Offset(400, 300),
          scrollDelta: const Offset(0, 53),
        ),
      );
      await tester.pump();
    }
    expect(canvasScale(), closeTo(fit * 0.81, 0.01));

    // 向上滚三档：×1.1，超过适配并连续放大。
    for (var i = 0; i < 3; i++) {
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: const Offset(400, 300),
          scrollDelta: const Offset(0, -53),
        ),
      );
      await tester.pump();
    }
    final zoomed = canvasScale();
    expect(zoomed, closeTo(fit * 0.81 * 1.331, 0.01));
    expect(zoomed, greaterThan(fit));
  });

  testWidgets('右侧统计面板与底部选框 bar 实时反映各类框数（+133）', (tester) async {
    await openEditor(tester);

    // 两个正文框 + 一个页眉框。
    await tester.dragFrom(const Offset(100, 100), const Offset(120, 240));
    await tester.pump();
    await tester.dragFrom(const Offset(420, 100), const Offset(200, 240));
    await tester.pump();
    await tester.tap(find.text('页眉 2'));
    await tester.pump();
    await tester.dragFrom(const Offset(150, 430), const Offset(200, 60));
    await tester.pump();

    // 右侧统计面板：各类计数（类名与 ×N 是同行两个 Text）。
    expect(find.text('本页区域'), findsOneWidget);
    expect(find.text('正文'), findsOneWidget);
    expect(find.text('×2'), findsOneWidget);
    expect(find.text('页眉'), findsOneWidget);
    expect(find.text('×1'), findsOneWidget);
    // 底部选框 bar：每框一颗 chip（带圈序号与类别栏的快捷键数字区分）。
    expect(find.text('正文 ①'), findsOneWidget);
    expect(find.text('正文 ②'), findsOneWidget);
    expect(find.text('页眉 ①'), findsOneWidget);

    // 当前类别还在页眉（画完页眉后）：先点 chip 选回第二个正文框再删。
    await tester.tap(find.text('正文 ②'));
    await tester.pump();
    await tester.tap(find.text('删除当前框'));
    await tester.pump();
    expect(find.text('×1'), findsNWidgets(2)); // 正文与页眉各剩 1
    expect(find.text('正文 ②'), findsNothing);
  });

  testWidgets('底部 bar 点 chip 选中指定框（+133）', (tester) async {
    await openEditor(tester);

    await tester.dragFrom(const Offset(100, 100), const Offset(120, 240));
    await tester.pump();
    await tester.dragFrom(const Offset(420, 100), const Offset(200, 240));
    await tester.pump();

    // 当前框本是最后画的第二个（靠右）；点 chip 选回第一个（靠左，
    // 被钳在页左缘 x≈0）再删——剩下的一定是靠右那个。
    await tester.tap(find.text('正文 ①'));
    await tester.pump();
    await tester.tap(find.text('删除当前框'));
    await tester.pump();

    final saved = await confirmAndRead(tester);
    final mains = (saved['main_regions'] as List)
        .cast<Map<String, dynamic>>()
        .where((r) => r['label'] == RegionLabel.mainText)
        .toList();
    expect(mains, hasLength(1));
    expect(mains.single['x'] as int, greaterThan(20), reason: '删掉的应是 chip 选中的靠左第一个框');
  });

  testWidgets('点击画布空白取消选择，删除按钮随之失效（+133）', (tester) async {
    await openEditor(tester);

    await tester.dragFrom(const Offset(100, 100), const Offset(120, 240));
    await tester.pump();
    await tester.dragFrom(const Offset(420, 100), const Offset(200, 240));
    await tester.pump();

    // 两框之间的空白处轻点（不在角点吸附圈/边线带内）：取消选择。
    await tester.tapAt(const Offset(320, 300));
    await tester.pump();

    // 未选中时「删除当前框」是空操作——两个框都应保留落盘。
    final deleteBtn = find.text('删除当前框');
    expect(tester.widget<OutlinedButton>(
      find.ancestor(of: deleteBtn, matching: find.byType(OutlinedButton)).first,
    ).onPressed, isNull);
    await tester.tap(deleteBtn, warnIfMissed: false);
    await tester.pump();

    final saved = await confirmAndRead(tester);
    final mains = (saved['main_regions'] as List)
        .cast<Map<String, dynamic>>()
        .where((r) => r['label'] == RegionLabel.mainText)
        .toList();
    expect(mains, hasLength(2), reason: '点空白取消选择后删除不应生效');
  });

  testWidgets('拖右侧/下部边中点手柄原地跟随扩展，不跳向对边（+137）', (tester) async {
    await openEditor(tester);

    // 画一个约 200×250 屏幕像素的框（画完即当前框，边中点手柄可拖）。
    await tester.dragFrom(const Offset(250, 150), const Offset(200, 250));
    await tester.pump();

    // 右边中点手柄向右拖 40：右边应原地跟随右移（旧 bug：锚点按"相对
    // 框左上"折算，首帧右边跳到 left+20 与左边重叠，框塌成 ~20px 宽）。
    await tester.dragFrom(const Offset(450, 275), const Offset(40, 0));
    await tester.pump();
    // 下边中点手柄向下拖 40：同理。
    await tester.dragFrom(const Offset(350, 400), const Offset(0, 40));
    await tester.pump();

    final saved = await confirmAndRead(tester);
    final main = (saved['main_regions'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((r) => r['label'] == RegionLabel.mainText);
    // 原框约 44×55 图像像素；拖边后只增不减。塌边 bug 下 w/h 都会被
    // 钳到 ~20。
    expect(main['w'] as int, greaterThan(40),
        reason: '右边手柄应向右扩展而不是跳去与左边重叠');
    expect(main['h'] as int, greaterThan(45),
        reason: '下边手柄应向下扩展而不是跳去与上边重叠');
  });

  testWidgets('当前框底色保持类别色，橙色只在边线与手柄（+140）', (tester) async {
    await openEditor(tester);

    // 画一个正文框——画完即当前框。
    await tester.dragFrom(const Offset(100, 100), const Offset(120, 240));
    await tester.pump();

    // 从树里取出快设画笔实例（私有类按 runtimeType 定位），用录制型
    // 画布重放一次绘制，按颜色断言。
    final editorPaintFinder = find.byWidgetPredicate(
      (w) =>
          w is CustomPaint &&
          '${w.painter.runtimeType}' == '_RegionEditorPainter',
    );
    final painter = tester.widget<CustomPaint>(editorPaintFinder).painter!;
    final canvas = _RecordingCanvas();
    painter.paint(canvas, const Size(100, 80));

    // Paint 内部按 float32 存颜色分量（0.08 读回 0.07999998…），Color 的
    // 精确 == 不可靠，一律按 toARGB32() 比较。
    final expectedFillArgb = RegionLabel.color(
      RegionLabel.mainText,
    ).withValues(alpha: 0.08).toARGB32();
    final orangeArgb = Colors.orange.toARGB32();
    // 当前框底色 = 一次类别色填充（旧实现当前框底色是 orange.alpha(0.10)，
    // 此处计 0，必红）。
    final boxFills = canvas.rects.where(
      (e) =>
          e.paint.style == PaintingStyle.fill &&
          e.paint.color.toARGB32() == expectedFillArgb,
    );
    expect(boxFills, hasLength(1), reason: '当前框底色应保持自身类别色，不是橙色');

    // 选中态的橙色只出现在：1 条边线描边 + 8 个手柄方块（4 角点 + 4 边
    // 中点；手柄在图像坐标里本就是 26/16px 的方块）。
    expect(
      canvas.rects.where(
        (e) =>
            e.paint.style == PaintingStyle.fill &&
            e.paint.color.toARGB32() == orangeArgb,
      ),
      hasLength(8),
      reason: '橙色填充应只有 4 个角点 + 4 个边中点手柄',
    );
    expect(
      canvas.rects.where(
        (e) =>
            e.paint.style == PaintingStyle.stroke &&
            e.paint.color.toARGB32() == orangeArgb,
      ),
      hasLength(1),
      reason: '当前框边线应保持橙色',
    );
  });

  testWidgets('确认并下一页跳到下一个未确认页，身后全确认时确认并返回（+140）',
      (tester) async {
    // 独立的三页书：第 2 页（下标 1）预置"主区已确认"标注。注意：测试
    // 体跑在 FakeAsync 区里，真实异步 IO（createTemp/writeAsBytes）永远
    // 不完成——文件准备一律用同步 API，标注写入包 runAsync。
    final dir = Directory.systemTemp.createTempSync(
      'quick_editor_next_unconfirmed',
    );
    addTearDown(() {
      // 图像解码器可能仍持有文件句柄，删不掉就留给系统临时目录。
      try {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final images = <String>[];
    for (var i = 0; i < 3; i++) {
      final f = File(p.join(dir.path, 'page_00$i.png'));
      f.writeAsBytesSync(_pngBytes(100, 80));
      images.add(f.path);
    }
    final book = Project(
      id: 'multi',
      name: '多页书',
      projectDir: dir.path,
      imageFiles: images,
    );
    await tester.runAsync(() async {
      await ProjectStorage.saveAnnotation(
        dir.path,
        PageAnnotation(
          pageId: book.pageIdAt(1),
          imagePath: images[1],
          mainRegions: [
            MainRegion(id: 'mr1', x: 5, y: 5, w: 80, h: 60, boxConfirmed: true),
          ],
        ),
      );
    });

    await tester.pumpWidget(MaterialApp(home: BookRegionGridPage(project: book)));
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    final cells = find.byWidgetPredicate(
      (w) =>
          w is CustomPaint && '${w.painter.runtimeType}' == '_RegionCellPainter',
    );
    expect(cells, findsNWidgets(3));
    await tester.tap(cells.first, warnIfMissed: false);
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
      final ready =
          find.textContaining('主区快设 · 第 1 / 3 页').evaluate().isNotEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty;
      if (ready) break;
    }
    await tester.pumpAndSettle();
    expect(find.textContaining('主区快设 · 第 1 / 3 页'), findsOneWidget);
    // 身后有未确认的第 3 页：按钮是「确认并下一页」。
    expect(find.text('确认并下一页'), findsOneWidget);

    // 第 1 页画框并确认：应跳过已确认的第 2 页直达第 3 页（旧实现顺序
    // 翻到第 2 页，必红）。
    await tester.dragFrom(const Offset(100, 100), const Offset(120, 240));
    await tester.pump();
    await tester.tap(find.text('确认并下一页'));
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
      final ready =
          find.textContaining('主区快设 · 第 3 / 3 页').evaluate().isNotEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty;
      if (ready) break;
    }
    await tester.pumpAndSettle();
    expect(find.textContaining('主区快设 · 第 3 / 3 页'), findsOneWidget);
    expect(find.textContaining('第 2 / 3 页'), findsNothing,
        reason: '已确认的第 2 页应被跳过');

    // 第 3 页身后没有未确认页：按钮变「确认并返回」，确认后退出回网格。
    expect(find.text('确认并返回'), findsOneWidget);
    await tester.dragFrom(const Offset(100, 100), const Offset(120, 240));
    await tester.pump();
    await tester.tap(find.text('确认并返回'));
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
      if (find.text('主区快设 · 多页书').evaluate().isNotEmpty) break;
    }
    await tester.pumpAndSettle();
    expect(find.text('主区快设 · 多页书'), findsOneWidget);
    // 第 1、3 页确认成果已落盘。
    for (final pageId in ['page_000', 'page_002']) {
      final f = File(p.join(dir.path, 'annotations', '$pageId.json'));
      expect(f.existsSync(), isTrue, reason: '$pageId 应已保存标注');
    }
  });

  /// 直接向盘上写一版 page_000 标注——模拟网格快照建立**之后**落盘的
  /// 外部修改（校对页改主区形状后的级联 flush 就是这个时序：flush 在
  /// 网格 push 时未必已发生，多在网格打开后才落盘）。同步 API：真实
  /// 异步 IO 在 testWidgets 的 FakeAsync 区里永不完成（+141 已踩过）。
  void writeDiskAnnotation(Map<String, dynamic> ann) {
    final f = File(p.join(projectDir.path, 'annotations', 'page_000.json'));
    f.createSync(recursive: true);
    f.writeAsStringSync(jsonEncode(ann), flush: true);
    // 同目录残留的 .bak 是旧内容，删掉防恢复读取混入。
    final bak = File('${f.path}.bak');
    if (bak.existsSync()) bak.deleteSync();
  }

  Map<String, dynamic> regionAnn(
    List<List<int>> mainRects, {
    List<Map<String, dynamic>> lines = const [],
  }) => {
        'page_id': 'page_000',
        'image_path': p.join(projectDir.path, 'page_000.png'),
        'main_regions': [
          for (final r in mainRects)
            {
              'id': 'mr_${r.join('_')}',
              'x': r[0],
              'y': r[1],
              'w': r[2],
              'h': r[3],
              'label': RegionLabel.mainText,
              'status': 'proposed',
            },
        ],
        'lines': lines,
        'paragraphs': [],
        'blocks': [],
      };

  testWidgets('网格会话期间外部改的主区形状，进编辑器确认后不被旧快照回写（+145）', (tester) async {
    // 网格加载时的盘态：旧形状。
    writeDiskAnnotation(regionAnn([
      [5, 5, 90, 70],
    ]));
    await tester.pumpWidget(
      MaterialApp(home: BookRegionGridPage(project: project)),
    );
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    // 网格快照已建立（旧形状）；此刻盘上被外部改成新形状（模拟校对页
    // 改框后的级联 flush 落盘）。
    writeDiskAnnotation(regionAnn([
      [12, 10, 40, 30],
    ]));

    final cell = find.byWidgetPredicate(
      (w) =>
          w is CustomPaint && '${w.painter.runtimeType}' == '_RegionCellPainter',
    );
    await tester.tap(cell, warnIfMissed: false);
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
      final ready =
          find.textContaining('主区快设 · 第 1 / 1 页').evaluate().isNotEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty;
      if (ready) break;
    }
    await tester.pumpAndSettle();

    // 不动任何框直接确认：草稿基线是盘上新形状，确认后盘上仍应是新
    // 形状（旧实现吃网格旧快照，确认会把旧形状连确认标记一起写回盘）。
    final saved = await confirmAndRead(tester);
    final mains = (saved['main_regions'] as List)
        .cast<Map<String, dynamic>>()
        .where((r) => r['label'] == RegionLabel.mainText)
        .toList();
    expect(mains, hasLength(1));
    expect(
      [mains.single['x'], mains.single['y'], mains.single['w'], mains.single['h']],
      [12, 10, 40, 30],
      reason: '校对页改出的新形状应原样保留，不被网格旧快照替代',
    );
    expect(mains.single['box_confirmed'], isTrue);
  });

  testWidgets('快设保存不覆盖网格打开后写进盘的行数据（合并基线 = 盘上最新，+145）', (tester) async {
    writeDiskAnnotation(regionAnn([
      [5, 5, 90, 70],
    ]));
    await tester.pumpWidget(
      MaterialApp(home: BookRegionGridPage(project: project)),
    );
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    // 外部写盘：新形状 + 一行识别成果（级联 flush 同时带回行数据）。
    writeDiskAnnotation(regionAnn(
      [
        [12, 10, 40, 30],
      ],
      lines: [
        {
          'id': 'l1',
          'x': 15,
          'y': 12,
          'w': 20,
          'h': 25,
          'lineNo': 0,
          'status': 'proposed',
          'chars': [],
        },
      ],
    ));

    final cell = find.byWidgetPredicate(
      (w) =>
          w is CustomPaint && '${w.painter.runtimeType}' == '_RegionCellPainter',
    );
    await tester.tap(cell, warnIfMissed: false);
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
      final ready =
          find.textContaining('主区快设 · 第 1 / 1 页').evaluate().isNotEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty;
      if (ready) break;
    }
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认并返回'));
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    final saved = jsonDecode(
      File(p.join(projectDir.path, 'annotations', 'page_000.json'))
          .readAsStringSync(),
    ) as Map<String, dynamic>;
    final mains = (saved['main_regions'] as List)
        .cast<Map<String, dynamic>>()
        .where((r) => r['label'] == RegionLabel.mainText)
        .toList();
    expect(
      [mains.single['x'], mains.single['y'], mains.single['w'], mains.single['h']],
      [12, 10, 40, 30],
    );
    // 级联带回的行不被整文件旧快照落盘洗掉（旧实现以网格快照为基线
    // 写整文件，行全丢——必红）。
    expect((saved['lines'] as List), hasLength(1),
        reason: '外部写进盘的行数据应保留');
  });
}

/// 录制型画布：只记 drawRect 的（矩形，画笔），其余调用全部忽略——供
/// 画笔颜色断言用（当前框底色类别色、橙色只出现在边线与小手柄）。
class _RecordingCanvas implements Canvas {
  final rects = <({Rect rect, Paint paint})>[];

  @override
  void drawRect(Rect rect, Paint paint) =>
      rects.add((rect: rect, paint: paint));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 生成一张有效的 PNG（w×h 纯色 RGB）：手工组 PNG 结构
/// （签名 + IHDR + zlib store 的 IDAT + IEND），不引入编码依赖。
List<int> _pngBytes(int w, int h) {
  final bytes = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

  List<int> u32(int v) => [
    (v >> 24) & 0xFF,
    (v >> 16) & 0xFF,
    (v >> 8) & 0xFF,
    v & 0xFF,
  ];

  List<int> chunk(String type, List<int> data) {
    final out = [...u32(data.length), ...type.codeUnits, ...data];
    final crc = _crc32([...type.codeUnits, ...data]);
    return [...out, ...u32(crc)];
  }

  // IHDR: width, height, bit depth 8, color type 2 (RGB)
  final ihdr = [...u32(w), ...u32(h), 8, 2, 0, 0, 0];
  final raw = <int>[];
  for (var y = 0; y < h; y++) {
    raw.add(0);
    for (var x = 0; x < w; x++) {
      raw.addAll([0x77, 0x66, 0x55]);
    }
  }
  final adler = _adler32(raw);
  final stored = <int>[
    0x78, 0x01,
    0x01,
    raw.length & 0xFF,
    (raw.length >> 8) & 0xFF,
    (~raw.length) & 0xFF,
    ((~raw.length) >> 8) & 0xFF,
    ...raw,
    ...u32(adler),
  ];
  bytes.addAll(chunk('IHDR', ihdr));
  bytes.addAll(chunk('IDAT', stored));
  bytes.addAll(chunk('IEND', const []));
  return bytes;
}

int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final b in data) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc >> 1) ^ (0xEDB88320 & (-(crc & 1)));
    }
  }
  return crc ^ 0xFFFFFFFF;
}

int _adler32(List<int> data) {
  var a = 1, b = 0;
  for (final byte in data) {
    a = (a + byte) % 65521;
    b = (b + a) % 65521;
  }
  return (b << 16) | a;
}
