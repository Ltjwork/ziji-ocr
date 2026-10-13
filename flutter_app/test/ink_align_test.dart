import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/services/ink_align.dart';

/// 墨迹对齐纯函数回归测试。合成"竖排列 + 字块"的假书页（确定性随
/// 机种子），验证角度估计、平移互相关、页码带屏蔽与画布变换往返。
///
/// 工作画布 600×840（叠加画布 1200×1680，canvasScale = 2）：合成图
/// 尺寸取工作画布、fit 取全幅 → 分析坐标即测试坐标，省一层换算。

const _work = Size(600, 840);
const _overlay = Size(1200, 1680);
const _center = Offset(300, 420);

List<Rect> _textColumns(math.Random rnd) {
  final rects = <Rect>[];
  for (var c = 0; c < 8; c++) {
    final x = 80.0 + c * 55;
    var y = 80.0 + rnd.nextDouble() * 20;
    while (y < 640) {
      final h = 22.0 + rnd.nextDouble() * 10;
      if (rnd.nextDouble() > 0.15) {
        rects.add(Rect.fromLTWH(x, y, 28, h));
      }
      y += h + 8 + rnd.nextDouble() * 8;
    }
  }
  return rects;
}

Uint8List _rasterRects(List<Rect> rects) {
  final buf = Uint8List(600 * 840 * 4);
  for (var i = 0; i < buf.length; i += 4) {
    buf[i] = 255;
    buf[i + 1] = 255;
    buf[i + 2] = 255;
    buf[i + 3] = 255;
  }
  for (final r in rects) {
    for (var y = r.top.round(); y < r.bottom.round(); y++) {
      for (var x = r.left.round(); x < r.right.round(); x++) {
        if (x < 0 || x >= 600 || y < 0 || y >= 840) continue;
        final i = (y * 600 + x) * 4;
        buf[i] = 30;
        buf[i + 1] = 30;
        buf[i + 2] = 30;
      }
    }
  }
  return buf;
}

List<Offset> _inkPixelsOf(Uint8List rgba) {
  final pts = <Offset>[];
  for (var y = 0; y < 840; y++) {
    for (var x = 0; x < 600; x++) {
      final i = (y * 600 + x) * 4;
      if (rgba[i] < 128) pts.add(Offset(x + 0.5, y + 0.5));
    }
  }
  return pts;
}

/// 点集光栅化（单像素盖章：投影按点计数，孔洞无碍；2×2 会把占比
/// 顶过防污损保护的 45% 上限）。
Uint8List _rasterPoints(List<Offset> pts) {
  return _rasterRects([
    for (final p in pts) Rect.fromLTWH(p.dx - 0.5, p.dy - 0.5, 1, 1),
  ]);
}

/// 行格版式（真实古籍形态）：全页统一行格、列位固定，页与页只是每
/// 格是否着墨不同——y 投影的细结构（行距）页间一致，配准精确。
List<Rect> _gridColumns(math.Random rnd) {
  final rects = <Rect>[];
  for (var c = 0; c < 8; c++) {
    final x = 80.0 + c * 55;
    for (var k = 0; k < 14; k++) {
      if (rnd.nextDouble() > 0.25) {
        rects.add(Rect.fromLTWH(x, 80.0 + k * 40 + 2, 28, 26));
      }
    }
  }
  return rects;
}

List<Offset> _rotatePts(List<Offset> pts, double psi) {
  final c = math.cos(psi), s = math.sin(psi);
  return [
    for (final p in pts)
      Offset(
        _center.dx + c * (p.dx - _center.dx) - s * (p.dy - _center.dy),
        _center.dy + s * (p.dx - _center.dx) + c * (p.dy - _center.dy),
      ),
  ];
}

/// 紧凑竖排列（配合小纸面用）：5 列，列宽 26、列距 48。
List<Rect> _compactColumns(math.Random rnd) {
  final rects = <Rect>[];
  for (var c = 0; c < 5; c++) {
    final x = 170.0 + c * 48;
    var y = 250.0 + rnd.nextDouble() * 16;
    while (y < 560) {
      final h = 20.0 + rnd.nextDouble() * 9;
      if (rnd.nextDouble() > 0.15) rects.add(Rect.fromLTWH(x, y, 26, h));
      y += h + 7 + rnd.nextDouble() * 7;
    }
  }
  return rects;
}

/// 带扫描背景的整页：中灰背景 + 白纸矩形 + 纸内墨迹。背景贴着画面
/// 边框每页同位——不过滤纸面时它会支配投影、把互相关锚死在零偏移
/// （正是"旋转对齐、平移不动"的假对齐来源）。
Uint8List _rasterOnPaper(Rect paper, List<Rect> content) {
  final buf = Uint8List(600 * 840 * 4);
  void fill(Rect r, int v) {
    for (var y = r.top.round(); y < r.bottom.round(); y++) {
      for (var x = r.left.round(); x < r.right.round(); x++) {
        if (x < 0 || x >= 600 || y < 0 || y >= 840) continue;
        final i = (y * 600 + x) * 4;
        buf[i] = v;
        buf[i + 1] = v;
        buf[i + 2] = v;
        buf[i + 3] = 255;
      }
    }
  }

  fill(Rect.fromLTWH(0, 0, 600, 840), 128); // 扫描背景
  fill(paper, 235); // 纸
  for (final r in content) {
    fill(r, 30); // 墨
  }
  return buf;
}

InkPageProfile _analyze(Uint8List rgba) => analyzeInkPage(
      rgba: rgba,
      imgW: 600,
      imgH: 840,
      fit: Rect.fromLTWH(0, 0, 600, 840),
      workCanvas: _work,
    );

InkAlignResult _alignTwo(InkPageProfile a, InkPageProfile b) =>
    computeInkAlignments(
      profiles: {0: a, 1: b},
      canvasScale: 2,
      overlayCanvas: _overlay,
    );

void main() {
  test('端正页面的拉正角 ≈ 0', () {
    final rgba = _rasterRects(_textColumns(math.Random(7)));
    final p = _analyze(rgba);
    expect(p.inkPoints, greaterThan(800));
    expect(p.angle.abs(), lessThan(0.0015)); // ≈0.08°
  });

  test('整体旋转 2° 的页面拉正角 ≈ −2°', () {
    final ink = _inkPixelsOf(_rasterRects(_textColumns(math.Random(7))));
    final psi = 2.0 * math.pi / 180.0;
    final p = _analyze(_rasterPoints(_rotatePts(ink, psi)));
    expect((p.angle + psi).abs(), lessThan(0.002)); // ≈0.11°
  });

  test('互相关找回已知平移（相对差，中位归零不破坏配准）', () {
    final ink = _inkPixelsOf(_rasterRects(_textColumns(math.Random(7))));
    final a = _analyze(_rasterPoints(ink));
    final b = _analyze(_rasterPoints([
      for (final p in ink) p + const Offset(12, -7),
    ]));
    final r = _alignTwo(a, b);
    expect(r.byPage[1]!.aligned, isTrue);
    expect(r.byPage[0]!.aligned, isTrue);
    final diff = r.byPage[1]!.shift - r.byPage[0]!.shift;
    expect(diff.dx, closeTo(-24, 1.5)); // 12 工作px × canvasScale 2
    expect(diff.dy, closeTo(14, 1.5));
  });

  test('旋转 + 平移组合：角度与平移同时找回', () {
    final ink = _inkPixelsOf(_rasterRects(_textColumns(math.Random(7))));
    final psi = 1.2 * math.pi / 180.0;
    final a = _analyze(_rasterPoints(ink));
    final b = _analyze(_rasterPoints(
      _rotatePts([for (final p in ink) p + const Offset(9, 6)], psi),
    ));
    final r = _alignTwo(a, b);
    expect(r.byPage[1]!.aligned, isTrue);
    expect(
      (r.byPage[1]!.angle - r.byPage[0]!.angle + psi).abs(),
      lessThan(0.0025),
    );
    final diff = r.byPage[1]!.shift - r.byPage[0]!.shift;
    expect(diff.dx, closeTo(-18, 2.5));
    expect(diff.dy, closeTo(-12, 2.5));
  });

  test('扫描背景不把配准锚死在零偏移（纸面门控）', () {
    final content = _compactColumns(math.Random(11));
    final a = _analyze(
      _rasterOnPaper(Rect.fromLTWH(150, 220, 300, 400), content),
    );
    final b = _analyze(_rasterOnPaper(
      Rect.fromLTWH(162, 213, 300, 400),
      [for (final r in content) r.translate(12, -7)],
    ));
    final r = _alignTwo(a, b);
    expect(r.byPage[1]!.aligned, isTrue);
    expect(r.byPage[0]!.aligned, isTrue);
    // 纸面连同文字整体挪了 (12,−7)：互相关必须找回这个平移而不是被
    // 每页同位的画面边框背景锁在 0。
    final diff = r.byPage[1]!.shift - r.byPage[0]!.shift;
    expect(diff.dx, closeTo(-24, 2.5));
    expect(diff.dy, closeTo(14, 2.5));
  });

  test('同版式不同内容的页仍可对齐（相邻页场景）', () {
    // 真实书页：行格/列位相同、每格文字不同——互相关靠细结构（列
    // 位 + 行距）匹配。这同时是 x/y 置信度阈值的标定用例（实测行格
    // 版式 cx≈0.99 / cy≈0.99；无行格的随机行相位页 cy 也有 0.26，
    // 阈值 0.22 放它过，版式无关页落在 0.1 以下）。
    final inkA = _inkPixelsOf(_rasterRects(_gridColumns(math.Random(7))));
    final inkB = _inkPixelsOf(_rasterRects(_gridColumns(math.Random(99))));
    final a = _analyze(_rasterPoints(inkA));
    final b = _analyze(_rasterPoints([
      for (final p in inkB) p + const Offset(10, -5),
    ]));
    final r = _alignTwo(a, b);
    expect(r.byPage[1]!.aligned, isTrue);
    expect(r.byPage[0]!.aligned, isTrue);
    final diff = r.byPage[1]!.shift - r.byPage[0]!.shift;
    expect(diff.dx, closeTo(-20, 3));
    expect(diff.dy, closeTo(10, 3));
  });

  test('列距回声峰反超真峰时不锁整列（纸心先验锚定）', () {
    // 手工构造剖面，确定复现真实病灶形态：同版式周期列、内容（列高）
    // 恰好让"错开一列"的相关峰高于真实对齐峰。真值 d=0；旧代码纯
    // argmax 会选 d=+55（回声）把页挪错一整列，先验锚定后必须取
    // 先验（纸心差 0）窗口内的真峰。
    Uint32List columns(List<int> heights) {
      final p = Uint32List(600);
      for (var i = 0; i < heights.length; i++) {
        final x0 = 100 + i * 55;
        for (var x = x0; x < x0 + 24; x++) {
          p[x] = heights[i];
        }
      }
      return p;
    }

    final refH = [500, 120, 420, 90, 380, 150, 460, 110];
    // page 的第 i 列高度 = ref 第 i−1 列 → d=+55 处高度完美吻合（回声
    // 峰必然反超 d=0 的真峰）。
    final pageH = [300, ...refH.sublist(0, 7)];
    Uint32List lines() {
      final p = Uint32List(840);
      for (var k = 0; k < 16; k++) {
        for (var y = 120 + k * 36; y < 120 + k * 36 + 22; y++) {
          p[y] = 320;
        }
      }
      return p;
    }

    final a = InkPageProfile(
      angle: 0,
      profileX: columns(refH),
      profileY: lines(),
      inkPoints: 4000,
      paperCenter: const Offset(300, 420),
    );
    final b = InkPageProfile(
      angle: 0,
      profileX: columns(pageH),
      profileY: lines(),
      inkPoints: 4000,
      paperCenter: const Offset(300, 420),
    );
    final r = _alignTwo(a, b);
    expect(r.byPage[1]!.aligned, isTrue);
    // 真值是两页本就同位（d=0）：平移必须近 0，绝不能是回声的 −110。
    expect(r.byPage[1]!.shift.dx, closeTo(0, 3));
    expect(r.byPage[1]!.shift.dy, closeTo(0, 3));
  });

  test('底部页码带墨迹不干扰配准', () {
    final ink = _inkPixelsOf(_rasterRects(_textColumns(math.Random(7))));
    final shifted = [for (final p in ink) p + const Offset(12, -7)];
    // 页码：底部中央的一小块墨迹（带内，y ≥ 781 = 840×0.93），只在
    // 其中一页出现——页码文字每页不同，必须被屏蔽而不是被对齐。
    final pageNumber = Rect.fromLTWH(280, 800, 44, 14);
    final withNumber = [...shifted, ..._inkPixelsOf(_rasterRects([pageNumber]))];
    final a = _analyze(_rasterPoints(ink));
    final b = _analyze(_rasterPoints(withNumber));
    final r = _alignTwo(a, b);
    expect(r.byPage[1]!.aligned, isTrue);
    final diff = r.byPage[1]!.shift - r.byPage[0]!.shift;
    expect(diff.dx, closeTo(-24, 1.5));
    expect(diff.dy, closeTo(14, 1.5));
  });

  test('空白页不可分析，两页缺一不配准', () {
    final blank = Uint8List(600 * 840 * 4);
    for (var i = 0; i < blank.length; i += 4) {
      blank[i] = blank[i + 1] = blank[i + 2] = blank[i + 3] = 255;
    }
    final a = _analyze(_rasterRects(_textColumns(math.Random(7))));
    final b = _analyze(blank);
    expect(b.inkPoints, 0);
    final r = _alignTwo(a, b);
    expect(r.byPage, isEmpty);
    expect(r.referencePage, -1);
  });

  test('无结构噪声页不强行对齐', () {
    final rnd = math.Random(3);
    final noise = [
      for (var i = 0; i < 9000; i++)
        Offset(80 + rnd.nextDouble() * 440, 80 + rnd.nextDouble() * 560),
    ];
    final a = _analyze(_rasterRects(_textColumns(math.Random(7))));
    final b = _analyze(_rasterPoints(noise));
    final r = _alignTwo(a, b);
    final unaligned = [r.byPage[0]!, r.byPage[1]!].firstWhere((e) => !e.aligned);
    expect(unaligned.angle, 0);
    expect(unaligned.shift, Offset.zero);
    expect(unaligned.reason, isNotEmpty);
    // 另一页（结构页自身）仍应判为可对齐。
    expect(
      [r.byPage[0]!, r.byPage[1]!].any((e) => e.aligned),
      isTrue,
    );
  });

  test('OverlayInkTransform 正逆往返与矩阵一致', () {
    const tr = OverlayInkTransform(
      angle: 0.03,
      shift: Offset(12, -5),
      globalScale: 0.93,
    );
    const rect = Rect.fromLTWH(100, 200, 300, 400);
    for (final p in [
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
    ]) {
      final back = tr.inverse(tr.forward(p, _center), _center);
      expect(back.dx, closeTo(p.dx, 1e-6));
      expect(back.dy, closeTo(p.dy, 1e-6));
    }
    // affineStorage 与 forward 数值一致（列主序手动乘）。
    final m = tr.affineStorage(_center);
    Offset viaMatrix(Offset p) => Offset(
          m[0] * p.dx + m[4] * p.dy + m[12],
          m[1] * p.dx + m[5] * p.dy + m[13],
        );
    for (final p in [rect.topLeft, rect.bottomRight, _center]) {
      final f = tr.forward(p, _center);
      final g = viaMatrix(p);
      expect(f.dx, closeTo(g.dx, 1e-4));
      expect(f.dy, closeTo(g.dy, 1e-4));
    }
    // AABB 外扩后逆映射必须包含原框（写回宁可稍大不裁字）。
    final unmapped = tr.unmapRect(tr.mapRect(rect, _center), _center);
    for (final c in [rect.topLeft, rect.topRight, rect.bottomLeft, rect.bottomRight]) {
      expect(unmapped.contains(c), isTrue);
    }
  });
}
