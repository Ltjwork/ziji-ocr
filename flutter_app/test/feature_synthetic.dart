/// 特征法测试共享的合成页生成器：600×840 工作画布、fit 全幅、
/// "交叉笔画字"版式（1 竖 + 1-3 横交叉，模拟汉字的方向性笔画结构）。
///
/// 方块/小镂空的扇区签名太各向同性——块间距离 ~0.075 与小角度旋转
/// 的扰动同量级，比值测试无从区分；交叉笔画的方向结构把块间距离
/// 拉到 0.3+，接近真实字形多样性。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect, Size;

import 'package:gujichazi/services/feature_points.dart';

const Size work = Size(600, 840);
const Offset center = Offset(300, 420);

/// 一页合成版式：墨块 + 镂空（洞为纸色；笔画字不需要镂空）。
class SynthPage {
  const SynthPage(this.ink, this.holes);
  final List<Rect> ink;
  final List<Rect> holes;
}

SynthPage variedGrid(math.Random rnd) {
  final ink = <Rect>[];
  for (var c = 0; c < 8; c++) {
    final cx = 80.0 + c * 55 + 14;
    for (var k = 0; k < 14; k++) {
      if (rnd.nextDouble() > 0.25) {
        final cy = 80.0 + k * 40 + 2;
        final cellW = 24.0 + rnd.nextDouble() * 8;
        final cellH = 22.0 + rnd.nextDouble() * 8;
        // 竖笔画：居中 ±2px（真实刻本的字居中写在格里，密度带中心
        // 才跨页稳定；随机散布会让带心晃 ±5px，虚拟格点失准）。
        final vw = 4.0 + rnd.nextDouble() * 4;
        ink.add(Rect.fromLTWH(
          cx - vw / 2 + (rnd.nextDouble() - 0.5) * 4,
          cy,
          vw,
          cellH * (0.8 + rnd.nextDouble() * 0.2),
        ));
        // 1-3 条横笔画：水平居中 ±2px、竖向在格内上下浮动（模拟字
        // 内部笔画的高度差异）。
        final nh = 1 + rnd.nextInt(3);
        for (var m = 0; m < nh; m++) {
          final hh = 3.5 + rnd.nextDouble() * 3.5;
          final hw = cellW * (0.45 + rnd.nextDouble() * 0.45);
          ink.add(Rect.fromLTWH(
            cx - hw / 2 + (rnd.nextDouble() - 0.5) * 4,
            cy + (cellH - hh) / 2 + (rnd.nextDouble() - 0.5) * 10,
            hw,
            hh,
          ));
        }
      }
    }
  }
  return SynthPage(ink, const []);
}

SynthPage translatePage(SynthPage p, double dx, double dy) => SynthPage(
      [for (final r in p.ink) r.translate(dx, dy)],
      [for (final r in p.holes) r.translate(dx, dy)],
    );

/// 有格版式：交叉笔画字 + 界栏格线（9 竖 × 14 横，1.5px 宽）。种子
/// 控制字形内容——同版式不同种子即"相邻两页"：文字不同、格线相同。
SynthPage gridWithLattice(math.Random rnd) {
  final base = variedGrid(rnd);
  final ink = [...base.ink];
  for (var c = 0; c <= 8; c++) {
    ink.add(Rect.fromLTWH(78.0 + c * 55, 60, 1.5, 640)); // 竖界栏
  }
  for (var k = 0; k <= 13; k++) {
    ink.add(Rect.fromLTWH(60, 78.0 + k * 40, 480, 1.5)); // 横行格
  }
  return SynthPage(ink, const []);
}

/// 整页旋转（按点集盖章）：rect 展开为像素中心点 → 绕画布心旋转 →
/// 1×1 盖章（四舍五入光栅化），与真实扫描的小角度偏转同形态。
SynthPage rotateAsStamps(SynthPage p, double psi) {
  final c = math.cos(psi), s = math.sin(psi);
  List<Rect> stamp(List<Rect> rects) => [
        for (final r in rects)
          for (var y = r.top.round(); y < r.bottom.round(); y++)
            for (var x = r.left.round(); x < r.right.round(); x++)
              Rect.fromLTWH(
                center.dx +
                    c * (x + 0.5 - center.dx) -
                    s * (y + 0.5 - center.dy) -
                    0.5,
                center.dy +
                    s * (x + 0.5 - center.dx) +
                    c * (y + 0.5 - center.dy) -
                    0.5,
                1,
                1,
              ),
      ];

  return SynthPage(stamp(p.ink), stamp(p.holes));
}

Uint8List raster(SynthPage p) {
  final buf = Uint8List(600 * 840 * 4);
  for (var i = 0; i < buf.length; i += 4) {
    buf[i] = 255;
    buf[i + 1] = 255;
    buf[i + 2] = 255;
    buf[i + 3] = 255;
  }
  void paint(List<Rect> rects, int v) {
    for (final r in rects) {
      for (var y = r.top.round(); y < r.bottom.round(); y++) {
        for (var x = r.left.round(); x < r.right.round(); x++) {
          if (x < 0 || x >= 600 || y < 0 || y >= 840) continue;
          final i = (y * 600 + x) * 4;
          buf[i] = v;
          buf[i + 1] = v;
          buf[i + 2] = v;
        }
      }
    }
  }

  paint(p.ink, 30);
  paint(p.holes, 255);
  return buf;
}

InkPageFeatures featuresOf(SynthPage p) => extractFeaturePoints(
      rgba: raster(p),
      imgW: 600,
      imgH: 840,
      fit: Rect.fromLTWH(0, 0, 600, 840),
      workCanvas: work,
    );
