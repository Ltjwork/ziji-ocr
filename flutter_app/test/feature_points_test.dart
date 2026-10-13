import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/services/feature_points.dart';

/// 特征点提取回归测试：合成"竖排列 + 变尺寸字块"的假书页（确定性
/// 随机种子），验证连通域质心、面积过滤、页码带排除与描述子的平移
/// 不变性。合成图直接取工作画布尺寸、fit 取全幅，分析坐标即测试
/// 坐标（与 ink_align_test 同口径）。

const _work = Size(600, 840);

/// 变尺寸网格版式：8 列 × 14 行，每块宽 20-34 / 高 18-30（确定性随
/// 机）——尺寸不一才有互不相同的描述子（等大网格的块签名全同，
/// 匹配层的距离比测试会全数拒绝，测不出恢复能力）。
List<Rect> _variedGrid(math.Random rnd) {
  final rects = <Rect>[];
  for (var c = 0; c < 8; c++) {
    final x = 80.0 + c * 55;
    for (var k = 0; k < 14; k++) {
      if (rnd.nextDouble() > 0.25) {
        final w = 20.0 + rnd.nextDouble() * 14;
        final h = 18.0 + rnd.nextDouble() * 12;
        rects.add(Rect.fromLTWH(x + (28 - w) / 2, 80.0 + k * 40 + 2, w, h));
      }
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

/// 有格版式光栅：字块 + 界栏格线（9 竖 × 14 横，1.5px 宽）。
Uint8List _rasterLattice(math.Random rnd) {
  return _rasterRects([
    ..._variedGrid(rnd),
    for (var c = 0; c <= 8; c++) Rect.fromLTWH(78.0 + c * 55, 60, 1.5, 640),
    for (var k = 0; k <= 13; k++) Rect.fromLTWH(60, 78.0 + k * 40, 480, 1.5),
  ]);
}

Rect _fit() => Rect.fromLTWH(0, 0, 600, 840);

InkPageFeatures _extract(Uint8List rgba) => extractFeaturePoints(
      rgba: rgba,
      imgW: 600,
      imgH: 840,
      fit: _fit(),
      workCanvas: _work,
    );

void main() {
  test('单个 40×30 块：恰好一个特征点，质心在块中心', () {
    final rgba = _rasterRects([Rect.fromLTWH(280, 400, 40, 30)]);
    final f = _extract(rgba);
    expect(f.inkPoints, greaterThan(0));
    expect(f.points.length, 1);
    final p = f.points.single;
    expect(p.type, FeatureType.centroid);
    expect(p.response, closeTo(40 * 30, 1));
    // 质心 = 像素坐标均值：x ∈ [280,320) → 300 − 0.5；y → 414.5。
    expect(p.position.dx, closeTo(299.5, 0.01));
    expect(p.position.dy, closeTo(414.5, 0.01));
  });

  test('空白页：不可分析（inkPoints=0、无特征点）', () {
    final f = _extract(_rasterRects([]));
    expect(f.inkPoints, 0);
    expect(f.points, isEmpty);
  });

  test('变尺寸网格：字块 ~84 个 + 密度虚拟格点，质心落在各块内', () {
    final rects = _variedGrid(math.Random(7));
    final f = _extract(_rasterRects(rects));
    final blobs = f.points.where((p) => p.type == FeatureType.centroid);
    final junctions =
        f.points.where((p) => p.type == FeatureType.junction).length;
    expect(blobs.length, closeTo(rects.length, 4));
    expect(blobs.length, greaterThan(60));
    // 白文页的密度兜底：8 文字列 × 14 行 → 112 个虚拟格点（≥3 条
    // 带双向才启用，稀疏页不触发）。
    expect(junctions, greaterThan(100));
    // 每个字块特征点的质心必须落在生成它的块内。
    for (final p in blobs) {
      var best = rects.first;
      var bestD = double.infinity;
      for (final r in rects) {
        final d = (r.center - p.position).distance;
        if (d < bestD) {
          bestD = d;
          best = r;
        }
      }
      expect(best.contains(p.position), isTrue,
          reason: '质心 ${p.position} 不在最近块 $best 内');
      expect(bestD, lessThan(20));
    }
  });

  test('面积过滤：小于 200 的噪点滤除，大于 5000 的污片不出块特征', () {
    final rects = <Rect>[
      Rect.fromLTWH(80, 80, 10, 10), // 100px 噪点 → 滤除
      Rect.fromLTWH(200, 80, 80, 80), // 6400px 污片 → run 清除移除，无交叉点
      Rect.fromLTWH(400, 80, 40, 30), // 正常字块 → 保留
      Rect.fromLTWH(80, 200, 30, 30), // 900px 字块 → 保留
    ];
    final f = _extract(_rasterRects(rects));
    final blobs = f.points.where((p) => p.type == FeatureType.centroid);
    final junctions = f.points.where((p) => p.type == FeatureType.junction);
    // 块特征：只剩两个字块（污片被线移除消除、噪点被面积下限滤除）。
    expect(blobs.length, 2);
    final xs = blobs.map((p) => p.position.dx).toList()..sort();
    expect(xs.first, closeTo(94.5, 0.01)); // 80+30/2−0.5
    expect(xs.last, closeTo(419.5, 0.01)); // 400+40/2−0.5
    // 交叉点：80px 宽的实心块远超线带宽上限（12px），不判线——投影
    // 带检测把"宽矮的文字列包络"与"窄高的线"区分开的正是带宽。
    expect(junctions, isEmpty);
  });

  test('页码带排除：纸底 6% 带内的块不产生特征点', () {
    // bandY = 840 × 94% = 789.6；块放 y=800~830（整块在带内）。
    final rects = <Rect>[
      Rect.fromLTWH(280, 400, 40, 30), // 正文块
      Rect.fromLTWH(280, 100, 40, 30), // 正文块
      Rect.fromLTWH(280, 800, 40, 30), // 页码块 → 排除
    ];
    final f = _extract(_rasterRects(rects));
    expect(f.points.length, 2);
    for (final p in f.points) {
      expect(p.position.dy, lessThan(789.6));
    }
  });

  test('描述子平移不变：整页平移后各字块的描述子不变、位置随移', () {
    const dx = 37.0, dy = 23.0;
    final rects = _variedGrid(math.Random(11));
    final a = _extract(_rasterRects(rects));
    final b = _extract(
      _rasterRects([for (final r in rects) r.translate(dx, dy)]),
    );
    // 只核对字块特征：虚拟格点在边缘（首末列/行）会有少量增减，不
    // 参与逐点对照。
    final aPts = a.points
        .where((p) => p.type == FeatureType.centroid)
        .toList(growable: false);
    final bPts = b.points
        .where((p) => p.type == FeatureType.centroid)
        .toList(growable: false);
    expect(aPts.length, bPts.length);
    // 逐点核对：A 中每个点在 B 中找到位置差 ≈ (dx,dy) 的对应点，
    // 描述子欧氏距离 ≈ 0（整数平移下光栅逐位相同）。
    for (final pa in aPts) {
      InkFeaturePoint? match;
      for (final pb in bPts) {
        if ((pb.position - (pa.position + const Offset(dx, dy)))
                .distance <
            0.01) {
          match = pb;
          break;
        }
      }
      expect(match, isNotNull, reason: '找不到 ${pa.position} 的对应点');
      var dist = 0.0;
      for (var i = 0; i < 8; i++) {
        final d = pa.descriptor[i] - match!.descriptor[i];
        dist += d * d;
      }
      expect(math.sqrt(dist), lessThan(1e-9));
    }
  });

  test('描述子可区分：不同字块的描述子距离显著大于同块的重复距离', () {
    final rects = _variedGrid(math.Random(3));
    final f = _extract(_rasterRects(rects));
    // 只看字块特征（扇区描述子）；虚拟格点是位置描述子，语义不同。
    final pts = f.points
        .where((p) => p.type == FeatureType.centroid)
        .toList(growable: false);
    expect(pts.length, greaterThan(10));
    // 同页不同块两两距离：绝大多数应 > 0.05（尺寸/位置邻域不同），
    // 全零说明描述子退化（没吃到形状差异，匹配层无法工作）。
    var pairs = 0, distinguishable = 0;
    for (var i = 0; i < pts.length; i++) {
      for (var j = i + 1; j < pts.length; j++) {
        var dist = 0.0;
        for (var k = 0; k < 8; k++) {
          final d = pts[i].descriptor[k] - pts[j].descriptor[k];
          dist += d * d;
        }
        dist = math.sqrt(dist);
        pairs++;
        if (dist > 0.05) distinguishable++;
      }
    }
    expect(pairs, greaterThan(0));
    expect(distinguishable / pairs, greaterThan(0.9));
  });

  test('有格版式：界栏交叉点被提取，格线不吞字块', () {
    final f = extractFeaturePoints(
      rgba: _rasterLattice(math.Random(5)),
      imgW: 600,
      imgH: 840,
      fit: _fit(),
      workCanvas: _work,
    );
    final junctions =
        f.points.where((p) => p.type == FeatureType.junction).toList();
    final blobs = f.points.where((p) => p.type == FeatureType.centroid);
    // 9 竖 × 14 横 = 126 个格点全数检出（±1 容带漂移的微差）。
    expect(junctions.length, greaterThan(115));
    // 字块特征未被格网吞掉（无格时 ~84）。
    expect(blobs.length, greaterThan(60));
    // 交叉点位置应落在格线坐标族（x ∈ 78+c·55，y ∈ 78+k·40）上。
    for (final j in junctions.take(10)) {
      final nearX = (j.position.dx - 78) % 55;
      final nearY = (j.position.dy - 78) % 40;
      expect(math.min(nearX, 55 - nearX), lessThan(3));
      expect(math.min(nearY, 40 - nearY), lessThan(3));
    }
  });
}
