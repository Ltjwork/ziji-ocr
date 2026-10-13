import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/page_quad.dart';
import 'package:gujichazi/pages/straighten_page.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// 校对摆正页渲染冒烟：真实 PNG 上完成解码 → RawImage 底图 + 画笔覆盖层
/// → 截屏像素采样，锁死"进页全黑"一类回归（底图没画出来 / 解码失败渲染
/// 黑画布 / 布局塌缩）。不触碰识别服务（用 initialQuad 跳过网络检测）。
void main() {
  // 进页 initState 加载中键手势配置，测试环境用内存 mock。
  SharedPreferences.setMockInitialValues({});
  late Directory tempDir;
  late String sourcePath; // 有效整页图（1654x2339，仿 200DPI PDF 页）
  late String largePath; // 大页图（2400x3400，远超 _decodeWidth=1600）
  late String dotSmallPath; // 小页图（827x1170，拖拽点尺寸对照用）
  late String smallPath; // 有效小图（150x110）
  late String brokenPath; // 头部有效但数据损坏（解码必失败）

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('straighten_page_test');
    sourcePath = p.join(tempDir.path, 'page_full.png');
    await File(sourcePath).writeAsBytes(
      _pngBytes(1654, 2339, const [0xEE, 0xE8, 0xDC]),
    );
    largePath = p.join(tempDir.path, 'page_large.png');
    await File(largePath).writeAsBytes(
      _pngBytes(2400, 3400, const [0xEE, 0xE8, 0xDC]),
    );
    dotSmallPath = p.join(tempDir.path, 'page_dot_small.png');
    await File(dotSmallPath).writeAsBytes(
      _pngBytes(827, 1170, const [0xEE, 0xE8, 0xDC]),
    );
    smallPath = p.join(tempDir.path, 'page_small.png');
    await File(smallPath).writeAsBytes(
      _pngBytes(150, 110, const [0x77, 0x66, 0x55]),
    );
    // raw 数据 11.6MB 按多块存储编码本身合法；这里用截断文件造坏图。
    brokenPath = p.join(tempDir.path, 'broken.png');
    final broken = _pngBytes(1654, 2339, const [0xEE, 0xE8, 0xDC]);
    await File(brokenPath).writeAsBytes(broken.sublist(0, broken.length ~/ 3));
  });

  tearDownAll(() async {
    try {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> settle(WidgetTester tester) async {
    // 解码是真实异步 IO：testWidgets 的假时间不走真实 IO，用 runAsync
    // 分批等待真实完成，再泵帧让 setState 落地。
    for (var i = 0; i < 90 && _loadingVisible(tester); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<ui.Image> capture(WidgetTester tester, Key key) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(key).first,
    );
    return (await tester.runAsync(() async => boundary.toImage()))!;
  }

  List<int> pixelOf(ui.Image shot, ByteData rgba, int x, int y) {
    final px = rgba.buffer.asUint8List();
    final i = (y * shot.width + x) * 4;
    return [px[i], px[i + 1], px[i + 2]];
  }

  testWidgets('真实尺寸整页在真实窗口大小下完整渲染（全屏采样）', (tester) async {
    tester.view.physicalSize = const Size(1900, 1054);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('surface'),
        child: MaterialApp(
          home: StraightenPage(
            imagePath: sourcePath,
            outPath: p.join(tempDir.path, 'out.png'),
            initialQuad: PageQuad.defaultInset(const Size(1654, 2339)),
            title: '整页渲染冒烟',
          ),
        ),
      ),
    );
    await settle(tester);
    expect(find.textContaining('无法读取图片'), findsNothing);

    // Scaffold 结构完整：标题栏与底部工具栏都在（防"布局塌缩只剩工具栏"）。
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.text('确认摆正'), findsOneWidget);

    // 全屏采样：视口中心应落在适配后的页面图内部，且是纸面亮色
    // （0xEE 级别）——黑屏（0x1C/0x10 深底）直接失败。
    final surface = await capture(tester, const Key('surface'));
    final rgba = (await tester.runAsync(
      () async => surface.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!;
    final center = pixelOf(surface, rgba, surface.width ~/ 2, surface.height ~/ 2);
    // 中心在裁切框内、遮罩外：本色 0xEE（遮罩只盖框外）。
    expect(center[0], greaterThan(180), reason: '视口中心像素应为纸面亮色，'
        '实际 $center（暗色说明底图未渲染或布局塌缩）');

    // 画布自身采样（局部坐标 1654x2339）：中心同样亮色。
    final canvas = await capture(tester, const Key('straighten-canvas'));
    expect(canvas.width, 1654);
    expect(canvas.height, 2339);
    final canvasRgba = (await tester.runAsync(
      () async => canvas.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!;
    final cCenter = pixelOf(
      canvas,
      canvasRgba,
      canvas.width ~/ 2,
      canvas.height ~/ 2,
    );
    expect(cCenter[0], greaterThan(180), reason: '画布中心像素应为纸面亮色，实际 $cCenter');

    // TL 角点（2% 内缩 ≈ (33,47)）附近存在橙色框线（R 高 B 低的暖色）。
    // viewScale 修复后圆点屏幕尺寸恒定 → 画布坐标里半径随适配缩放变大
    //（此页 0.369 → 半径 ~35px，中心是白色内芯），窗口须够大够到圆环。
    expect(_scanWarmNear(canvasRgba.buffer.asUint8List(), canvas.width,
        canvas.height, 33, 47, radius: 40), isTrue,
        reason: 'TL 角点附近应能采到橙色裁切框像素');
  });

  testWidgets('大页（>解码宽）整幅铺满显示，不缩成小图+黑边（回归）', (
    tester,
  ) async {
    // 页面文件远大于 _decodeWidth=1600 时，RawImage 底图若不带
    // fit=fill 会按 scaleDown 以原尺寸居中：显示成"小页+一圈黑边"
    // （裁切坐标仍按全尺寸算，故只有显示缩水）。此测试锁死该回归：
    // 画布边缘（缩样图自然尺寸之外的区域）必须是纸面亮色。
    tester.view.physicalSize = const Size(1900, 1054);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('surface'),
        child: MaterialApp(
          home: StraightenPage(
            imagePath: largePath,
            outPath: p.join(tempDir.path, 'out.png'),
            initialQuad: PageQuad.defaultInset(const Size(2400, 3400)),
            title: '大页渲染冒烟',
          ),
        ),
      ),
    );
    await settle(tester);
    expect(find.textContaining('无法读取图片'), findsNothing);

    // 结构断言：底图 RawImage 必须显式铺满（缺 fit = scaleDown 缩水）。
    final raw = tester.widget<RawImage>(find.byType(RawImage).first);
    expect(raw.fit, BoxFit.fill);

    final canvas = await capture(tester, const Key('straighten-canvas'));
    expect(canvas.width, 2400);
    expect(canvas.height, 3400);
    final rgba = (await tester.runAsync(
      () async => canvas.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!;
    // 解码缩样按原尺寸居中时占 (400..2000, 567..2833)：其外的画布边缘
    // 在回归版会是未绘制的透明/深色。四边各采一点，必须全是纸面亮色。
    final points = [
      (200, 1700), // 左缘
      (2200, 1700), // 右缘
      (1200, 280), // 上缘
      (1200, 3120), // 下缘
      (1200, 1700), // 中心（回归版也是亮的，作对照）
    ];
    final px = rgba.buffer.asUint8List();
    for (final (x, y) in points) {
      final c = pixelOf(canvas, rgba, x, y);
      expect(
        c[0],
        greaterThan(180),
        reason: '画布 ($x,$y) 应为纸面亮色，实际 $c'
            '（暗色 = 底图未铺满整幅，缩成小图+黑边回归）',
      );
      // 透明像素（未绘制区域）的 RGB 同样不是纸面色，上断言已覆盖；
      // 此处再显式确认 alpha，防"透明也算亮色"的采样假阳性。
      final i = (y * canvas.width + x) * 4;
      expect(px[i + 3], 255, reason: '画布 ($x,$y) 应不透明（底图铺满）');
    }
  });

  /// 画面最上方橙色元素（TL 圆点）在顶部下方 5px 处的水平橙色游程
  /// （≈圆点可见直径，屏幕像素）。用于锁死"拖拽点随页面分辨率缩小"。
  int topDotChord(ui.Image shot, ByteData rgba) {
    final px = rgba.buffer.asUint8List();
    final w = shot.width, h = shot.height;
    bool isOrange(int x, int y) {
      final i = (y * w + x) * 4;
      final r = px[i], g = px[i + 1], b = px[i + 2], a = px[i + 3];
      return a > 200 && r > 180 && g > 100 && g < 190 && b < 110;
    }

    var yTop = -1;
    for (var y = 0; y < h && yTop < 0; y++) {
      for (var x = 0; x < w; x++) {
        if (isOrange(x, y)) {
          yTop = y;
          break;
        }
      }
    }
    expect(yTop, greaterThanOrEqualTo(0), reason: '画面里应有橙色控制点');
    var best = 0, run = 0;
    for (var y = yTop; y <= (yTop + 5).clamp(0, h - 1); y++) {
      run = 0;
      for (var x = 0; x < w; x++) {
        if (isOrange(x, y)) {
          run++;
          if (run > best) best = run;
        } else {
          run = 0;
        }
      }
    }
    return best;
  }

  testWidgets('控制点屏幕尺寸不随页面分辨率缩小（viewScale 回归）', (tester) async {
    // 根因：视图矩阵只缩 x/y（z 恒 1），getMaxScaleOnAxis 永远返回 1.0，
    // 画笔的屏幕尺寸补偿（unit=1/viewScale）从未生效——页面越大（适配
    // 缩放越小）拖拽点越小，高分辨率书页上直接缩没。修复后控制点应为
    // 屏幕恒定尺寸：小页（适配 0.74）与大页（适配 0.28）的圆点游程
    // 都要 ≥10px 且基本一致。
    tester.view.physicalSize = const Size(1900, 1054);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    int? smallDot, largeDot;
    for (final (path, size, into) in [
      (dotSmallPath, const Size(827, 1170), 1),
      (largePath, const Size(2400, 3400), 2),
    ]) {
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('surface'),
          child: MaterialApp(
            home: StraightenPage(
              imagePath: path,
              outPath: p.join(tempDir.path, 'out.png'),
              initialQuad: PageQuad.defaultInset(size),
              title: '控制点尺寸',
            ),
          ),
        ),
      );
      await settle(tester);
      final shot = await capture(tester, const Key('surface'));
      final rgba = (await tester.runAsync(
        () async => shot.toByteData(format: ui.ImageByteFormat.rawRgba),
      ))!;
      final chord = topDotChord(shot, rgba);
      if (into == 1) {
        smallDot = chord;
      } else {
        largeDot = chord;
      }
    }
    debugPrint('控制点游程：小页 $smallDot px，大页 $largeDot px');
    expect(smallDot!, greaterThanOrEqualTo(10),
        reason: '小页（适配 0.74）控制点游程应 ≥10px，实际 $smallDot');
    expect(largeDot!, greaterThanOrEqualTo(10),
        reason: '大页（适配 0.28）控制点游程应 ≥10px——小于此说明'
            '屏幕尺寸补偿失效（getMaxScaleOnAxis 回归），点随分辨率缩小');
    expect(largeDot, greaterThanOrEqualTo(smallDot * 0.6),
        reason: '大小页的控制点尺寸应基本一致（屏幕恒定），'
            '实际 小页 $smallDot / 大页 $largeDot');
  });

  testWidgets('小图渲染出底图与裁切框（像素采样）', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: StraightenPage(
          imagePath: smallPath,
          outPath: p.join(tempDir.path, 'out.png'),
          initialQuad: PageQuad.defaultInset(const Size(150, 110)),
          title: '渲染冒烟',
        ),
      ),
    );
    await settle(tester);
    expect(find.textContaining('无法读取图片'), findsNothing);

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('straighten-canvas')).first,
    );
    expect(boundary.size.width, 150);
    expect(boundary.size.height, 110);

    final shot = await capture(tester, const Key('straighten-canvas'));
    final rgba = (await tester.runAsync(
      () async => shot.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!;
    final pixels = rgba.buffer.asUint8List();
    final idx = ((shot.height ~/ 2) * shot.width + (shot.width ~/ 2)) * 4;
    expect(pixels[idx], 0x77, reason: '中心像素 R 通道应为图片本色，'
        '实际 ${pixels[idx]},${pixels[idx + 1]},${pixels[idx + 2]}（全黑说明底图未渲染）');
    expect(pixels[idx + 1], 0x66);
    expect(pixels[idx + 2], 0x55);

    expect(_scanWarmNear(pixels, shot.width, shot.height, 3, 2), isTrue,
        reason: 'TL 角点附近应能采到橙色裁切框像素');
  });

  testWidgets('解码失败显式报错，不渲染黑画布', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: StraightenPage(
          imagePath: brokenPath,
          outPath: p.join(tempDir.path, 'out.png'),
          // 即便有初始裁切框，位图缺失也必须报错而非黑画布。
          initialQuad: PageQuad.defaultInset(const Size(1654, 2339)),
          title: '坏图冒烟',
        ),
      ),
    );
    await settle(tester);
    expect(find.textContaining('无法读取图片'), findsOneWidget);
    expect(find.byKey(const Key('straighten-canvas')), findsNothing);
  });

  // ── 旋转显示位图（rotateImageMemory）──
  // 回归：逆时针分支曾把已转向的内容放进未换轴的 (w,h) 光栅——内容被
  // 裁 + 空白带，再被 RawImage BoxFit.fill 拉伸，即"多旋转几次页面被
  // 拉伸"。锁死：两方向输出都宽高互换、角点像素落位正确、往返复原。
  test('旋转显示位图：两方向输出宽高互换且角点落位正确（回归：逆时针拉伸）', () async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    await binding.runAsync(() async {
      const red = 0xFF0000, green = 0xFF00, blue = 0xFF;
      const yellow = 0xFFFF00;
      // 四象限异色图（TL 红 / TR 绿 / BR 蓝 / BL 黄），角点落位一眼可判。
      Future<ui.Image> quadImage(int w, int h) async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        final q = Rect.fromLTWH(0, 0, w / 2, h / 2);
        canvas.drawRect(q, Paint()..color = const Color(0xFFFF0000));
        canvas.drawRect(
          q.translate(w / 2, 0),
          Paint()..color = const Color(0xFF00FF00),
        );
        canvas.drawRect(
          q.translate(w / 2, h / 2),
          Paint()..color = const Color(0xFF0000FF),
        );
        canvas.drawRect(
          q.translate(0, h / 2),
          Paint()..color = const Color(0xFFFFFF00),
        );
        final picture = recorder.endRecording();
        final img = await picture.toImage(w, h);
        picture.dispose();
        return img;
      }

      Future<int> pixel(ui.Image img, int x, int y) async {
        final data = (await img.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final b = data.buffer.asUint8List();
        final i = (y * img.width + x) * 4;
        return (b[i] << 16) | (b[i + 1] << 8) | b[i + 2];
      }

      // 采样四象限中心（避开边界半像素）。
      Future<List<int>> quadrantColors(ui.Image img) async {
        final w = img.width, h = img.height;
        return [
          await pixel(img, w ~/ 4, h ~/ 4),
          await pixel(img, 3 * w ~/ 4, h ~/ 4),
          await pixel(img, 3 * w ~/ 4, 3 * h ~/ 4),
          await pixel(img, w ~/ 4, 3 * h ~/ 4),
        ];
      }

      final src = await quadImage(100, 60); // 横幅
      expect(await quadrantColors(src), [red, green, blue, yellow]);

      // 顺时针：100×60 → 60×100；旧 BL→新 TL、旧 TL→新 TR、
      // 旧 TR→新 BR、旧 BR→新 BL。
      final cw = await rotateImageMemory(src, true);
      expect(cw.width, 60, reason: '顺时针输出宽高必须互换');
      expect(cw.height, 100, reason: '顺时针输出宽高必须互换');
      expect(await quadrantColors(cw), [yellow, red, green, blue]);

      // 逆时针：100×60 → 60×100（此前这里输出 100×60 = 拉伸根源）；
      // 旧 TR→新 TL、旧 BR→新 TR、旧 BL→新 BR、旧 TL→新 BL。
      final ccw = await rotateImageMemory(src, false);
      expect(ccw.width, 60, reason: '逆时针输出宽高必须互换（回归：曾未互换）');
      expect(ccw.height, 100, reason: '逆时针输出宽高必须互换（回归：曾未互换）');
      expect(await quadrantColors(ccw), [green, blue, yellow, red]);

      // 竖幅源同样成立（旧 bug 在竖幅上裁切方向相反）。
      final srcTall = await quadImage(60, 100);
      final ccwTall = await rotateImageMemory(srcTall, false);
      expect(ccwTall.width, 100);
      expect(ccwTall.height, 60);
      expect(await quadrantColors(ccwTall), [green, blue, yellow, red]);

      // 往返复原：连续 CW×4 与 CW→CCW 混转（用户找方向的实际操作序列）
      // 都必须回到原尺寸原象限——任何一步光栅尺寸错都会累积成拉伸。
      var img = src;
      for (var i = 0; i < 4; i++) {
        img = await rotateImageMemory(img, true);
      }
      expect(img.width, 100);
      expect(img.height, 60);
      expect(await quadrantColors(img), [red, green, blue, yellow]);

      img = await rotateImageMemory(await rotateImageMemory(src, true), false);
      expect(img.width, 100);
      expect(img.height, 60);
      expect(await quadrantColors(img), [red, green, blue, yellow]);

      src.dispose();
      srcTall.dispose();
      cw.dispose();
      ccw.dispose();
      ccwTall.dispose();
      img.dispose();
    });
  });
  group('滚轮：Ctrl 缩放裁切框 / 普通缩放视图', () {
    /// 从画布 CustomPaint 的私有画笔实例里取 quad / viewScale（动态访问，
    /// 不依赖私有类型）。
    PageQuad quadOf(WidgetTester tester) {
      final cp = tester.widget<CustomPaint>(
        find
            .descendant(
              of: find.byKey(const Key('straighten-canvas')),
              matching: find.byType(CustomPaint),
            )
            .first,
      );
      return ((cp.painter as dynamic).quad) as PageQuad;
    }

    double viewScaleOf(WidgetTester tester) {
      final cp = tester.widget<CustomPaint>(
        find
            .descendant(
              of: find.byKey(const Key('straighten-canvas')),
              matching: find.byType(CustomPaint),
            )
            .first,
      );
      return ((cp.painter as dynamic).viewScale) as double;
    }

    /// 30%..70% 内缩框：Ctrl 放大到 +15% 仍在图内（不触发边界钳制），
    /// 断言可以精确到理论系数。
    PageQuad insetQuad() => PageQuad.fromPoints(const [
          [496, 702],
          [1157, 702],
          [1157, 1637],
          [496, 1637],
        ]);

    Future<void> pumpWithQuad(WidgetTester tester, PageQuad quad) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: StraightenPage(
            imagePath: sourcePath,
            outPath: p.join(tempDir.path, 'wheel_out.png'),
            initialQuad: quad,
            title: '滚轮测试',
          ),
        ),
      );
      await settle(tester);
    }

    testWidgets('Ctrl+滚轮：裁切框绕质心等比放大，视图不动', (tester) async {
      await pumpWithQuad(tester, insetQuad());
      final before = quadOf(tester);
      final beforeScale = viewScaleOf(tester);
      final c = before.centroid;

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendEventToBinding(
        PointerScrollEvent(
          device: 7,
          kind: PointerDeviceKind.mouse,
          position: tester.getCenter(
            find.byKey(const Key('straighten-canvas')),
          ),
          scrollDelta: const Offset(0, -120), // 向上滚 = 放大
        ),
      );
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      final after = quadOf(tester);
      // 质心不动，各角距质心 ×1.0005^120 ≈ 1.0618（等比、形状不变）。
      expect(after.centroid.dx, closeTo(c.dx, 0.5));
      expect(after.centroid.dy, closeTo(c.dy, 0.5));
      const factor = 1.0618;
      for (var i = 0; i < 4; i++) {
        expect(
          (after.corners[i] - after.centroid).distance,
          closeTo((before.corners[i] - c).distance * factor, 1.0),
        );
      }
      // 视图没被缩放（IV 内置滚轮已关，普通滚轮路径不因 Ctrl 触发）。
      expect(viewScaleOf(tester), closeTo(beforeScale, 1e-9));
    });

    testWidgets('Ctrl+滚轮向下：整体缩小；连续放大到边界被钳制', (tester) async {
      await pumpWithQuad(tester, insetQuad());
      // 缩小 1 档：×1/1.0618（微调档：一格 ≈6%）。
      var before = quadOf(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendEventToBinding(
        PointerScrollEvent(
          device: 7,
          kind: PointerDeviceKind.mouse,
          position: tester.getCenter(
            find.byKey(const Key('straighten-canvas')),
          ),
          scrollDelta: const Offset(0, 120),
        ),
      );
      await tester.pump();
      var after = quadOf(tester);
      final shrink = (after.corners[0] - after.centroid).distance /
          (before.corners[0] - before.centroid).distance;
      expect(shrink, closeTo(1 / 1.0618, 0.01));

      // 连续放大 20 档：30%..70% 内缩框的角点到质心 x 向 331px，放大
      // 到 827/331 ≈ 2.50 倍被图像边界钳制（形状仍严格等比），之后的
      // 滚动不再变化。
      for (var i = 0; i < 20; i++) {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            device: 7,
            kind: PointerDeviceKind.mouse,
            position: tester.getCenter(
              find.byKey(const Key('straighten-canvas')),
            ),
            scrollDelta: const Offset(0, -120),
          ),
        );
        await tester.pump();
      }
      after = quadOf(tester);
      final grow = (after.corners[0] - after.centroid).distance /
          (before.corners[0] - before.centroid).distance;
      expect(grow, allOf(greaterThan(2.2), lessThan(2.6)),
          reason: '累计放大被边界钳到 ≈2.50×');
      for (final o in after.corners) {
        expect(o.dx, inInclusiveRange(0, 1654));
        expect(o.dy, inInclusiveRange(0, 2339));
      }
      // 钳制确实生效：左右角点贴到图像左右缘（±2px 内）。
      final dxs = after.corners.map((o) => o.dx).toList();
      expect(
        dxs.any((x) => x <= 2 || x >= 1651),
        isTrue,
        reason: '放大到边后角点应贴住图像边缘',
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    });

    testWidgets('普通滚轮：仍缩放视图（指针锚点），裁切框不动', (tester) async {
      await pumpWithQuad(tester, insetQuad());
      final before = quadOf(tester);
      final beforeScale = viewScaleOf(tester);

      await tester.sendEventToBinding(
        PointerScrollEvent(
          device: 7,
          kind: PointerDeviceKind.mouse,
          position: tester.getCenter(
            find.byKey(const Key('straighten-canvas')),
          ),
          scrollDelta: const Offset(0, 120), // 向下滚 = 缩小
        ),
      );
      await tester.pump();

      // IV 默认 scaleFactor=200：×exp(-120/200) ≈ 0.5488。
      expect(viewScaleOf(tester), closeTo(beforeScale * 0.5488, 0.02));
      final after = quadOf(tester);
      for (var i = 0; i < 4; i++) {
        expect(after.corners[i], before.corners[i]);
      }
    });
  });
}

bool _loadingVisible(WidgetTester tester) =>
    find.textContaining('正在载入').evaluate().isNotEmpty;

/// 在 (x,y) 附近 ±6px 范围扫暖色像素（框线可能落在采样格旁）。
bool _scanWarmNear(List<int> px, int w, int h, int x, int y,
    {int radius = 6}) {
  for (var dy = -radius; dy <= radius; dy++) {
    for (var dx = -radius; dx <= radius; dx++) {
      final sx = x + dx, sy = y + dy;
      if (sx < 0 || sy < 0 || sx >= w || sy >= h) continue;
      final i = (sy * w + sx) * 4;
      if (px[i] > 180 && px[i + 2] < 140) return true;
    }
  }
  return false;
}

/// 生成一张有效的 PNG（w×h 纯色 RGB）：手工组 PNG 结构
/// （签名 + IHDR + 多块 zlib store 的 IDAT + IEND），不引入编码依赖。
/// 大图 raw 数据按 ≤65535 字节分块（单 zlib 存储块上限）。
List<int> _pngBytes(int w, int h, List<int> rgb) {
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

  final ihdr = [...u32(w), ...u32(h), 8, 2, 0, 0, 0];
  // raw 行：filter 0 + 像素。大图直接写 Uint8List（百万级数据）。
  final stride = 1 + w * 3;
  final raw = Uint8List(h * stride);
  for (var y = 0; y < h; y++) {
    final base = y * stride;
    raw[base] = 0;
    for (var x = 0; x < w; x++) {
      final i = base + 1 + x * 3;
      raw[i] = rgb[0];
      raw[i + 1] = rgb[1];
      raw[i + 2] = rgb[2];
    }
  }
  bytes.addAll(chunk('IHDR', ihdr));
  bytes.addAll(chunk('IDAT', _zlibStore(raw)));
  bytes.addAll(chunk('IEND', const []));
  return bytes;
}

/// zlib 存储编码（BTYPE=00 非压缩块，≤65535 字节/块）。
List<int> _zlibStore(Uint8List raw) {
  final out = <int>[0x78, 0x01];
  var offset = 0;
  while (offset < raw.length) {
    final n = math.min(65535, raw.length - offset);
    final isLast = offset + n >= raw.length;
    out.add(isLast ? 0x01 : 0x00);
    out.add(n & 0xFF);
    out.add((n >> 8) & 0xFF);
    out.add(~n & 0xFF);
    out.add((~n >> 8) & 0xFF);
    out.addAll(raw.sublist(offset, offset + n));
    offset += n;
  }
  final adler = _adler32(raw);
  out.addAll([
    (adler >> 24) & 0xFF,
    (adler >> 16) & 0xFF,
    (adler >> 8) & 0xFF,
    adler & 0xFF,
  ]);
  return out;
}

int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final b in data) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc >> 1) ^ (0xEDB88320 & (-(crc & 1)));
    }
  }
  return (~crc) & 0xFFFFFFFF;
}

int _adler32(Uint8List data) {
  var a = 1, b = 0;
  for (final byte in data) {
    a = (a + byte) % 65521;
    b = (b + a) % 65521;
  }
  return (b << 16) | a;

}

