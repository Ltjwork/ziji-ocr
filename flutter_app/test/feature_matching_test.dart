import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/services/feature_matching.dart';
import 'package:gujichazi/services/feature_points.dart';

import 'feature_synthetic.dart';

/// 特征匹配 + RANSAC 回归测试：
/// - 真图管线（提取 → 匹配 → RANSAC）：平移恢复、小角度旋转恢复；
/// - 手工特征点（绕过提取）：50% 误匹配下的鲁棒性、不同版式不强对齐。
///
/// 合成版式见 feature_synthetic.dart（交叉笔画字，600×840、fit 全幅）。

/// 手工特征点构造（绕过图像提取，专测匹配/RANSAC 数学层）。
InkPageFeatures _synthetic(List<Offset> positions, List<Float64List> descs) {
  assert(positions.length == descs.length);
  return InkPageFeatures(
    points: [
      for (var i = 0; i < positions.length; i++)
        InkFeaturePoint(
          position: positions[i],
          response: 500,
          descriptor: descs[i],
        ),
    ],
    paperCenter: Offset.zero,
    inkPoints: 100000,
  );
}

Float64List _randomUnit(math.Random rnd) {
  final v = Float64List(8);
  var norm = 0.0;
  for (var i = 0; i < 8; i++) {
    v[i] = rnd.nextDouble();
    norm += v[i] * v[i];
  }
  norm = math.sqrt(norm);
  for (var i = 0; i < 8; i++) {
    v[i] /= norm;
  }
  return v;
}

Float64List _perturb(Float64List d, math.Random rnd, {double eps = 0.02}) {
  final v = Float64List(8);
  var norm = 0.0;
  for (var i = 0; i < 8; i++) {
    v[i] = d[i] + (rnd.nextDouble() - 0.5) * 2 * eps;
    norm += v[i] * v[i];
  }
  norm = math.sqrt(norm);
  for (var i = 0; i < 8; i++) {
    v[i] /= norm;
  }
  return v;
}

void main() {
  test('同版式平移 (10,−5)：全流程恢复，残差 < 0.5px', () {
    final page1 = variedGrid(math.Random(21));
    final ref = featuresOf(page1);
    final page = featuresOf(translatePage(page1, 10, -5));
    final out = alignWithFeatures(ref: ref, page: page, random: math.Random(5));
    expect(out.aligned, isTrue, reason: out.reason);
    expect(out.totalMatches, greaterThan(60));
    expect(out.inlierRatio, greaterThan(0.8));
    final t = out.transform!;
    expect(t.angle.abs(), lessThan(0.3 * math.pi / 180.0));
    expect(t.scale, closeTo(1.0, 0.01));
    // 变换方向：ref 坐标 → page 坐标，即 T(r) ≈ r + (10,−5)。
    for (final p in ref.points) {
      final err =
          (t.apply(p.position) - (p.position + const Offset(10, -5))).distance;
      expect(err, lessThan(0.5));
    }
  });

  test('同版式旋转 1.2°：角度恢复误差 < 0.3°，尺度 ≈ 1', () {
    // 1.2° 已是真实扫描（≤0.5°）的 ~3 倍压力；更高偏转下密度带在
    // 投影上互相糊并，虚拟格点共识会把角度拉低（已知边界）。
    const psi = 1.2 * math.pi / 180.0;
    final page1 = variedGrid(math.Random(33));
    final ref = featuresOf(page1);
    final page = featuresOf(rotateAsStamps(page1, psi));
    expect(ref.points.length, greaterThan(50));
    expect(page.points.length, greaterThan(50));
    final out = alignWithFeatures(ref: ref, page: page, random: math.Random(6));
    expect(out.aligned, isTrue, reason: out.reason);
    expect(out.totalMatches, greaterThan(40));
    final t = out.transform!;
    expect(t.angle, closeTo(psi, 0.3 * math.pi / 180.0));
    expect(t.scale, closeTo(1.0, 0.02));
    // 旋转是绕画布中心的：T(p) ≈ C + R(ψ)(p − C)。格点在偏转下有
    // ~1px 级共识误差。
    final c = math.cos(psi), s = math.sin(psi);
    for (final p in ref.points) {
      final dx = p.position.dx - center.dx, dy = p.position.dy - center.dy;
      final expected = Offset(
        center.dx + c * dx - s * dy,
        center.dy + s * dx + c * dy,
      );
      expect((t.apply(p.position) - expected).distance, lessThan(1.5));
    }
  });

  test('50% 误匹配：RANSAC 仍恢复正确平移（内点几何一致性投票）', () {
    final rnd = math.Random(42);
    const n = 60;
    const half = 30;
    const delta = Offset(8, -4);
    final descs = [for (var i = 0; i < n; i++) _randomUnit(rnd)];
    final refPos = <Offset>[
      for (var i = 0; i < n; i++)
        Offset(
          60.0 + (i % 8) * 55 + rnd.nextDouble() * 10,
          80.0 + (i ~/ 8) * 40 + rnd.nextDouble() * 10,
        ),
    ];
    // page 侧：前一半放真点（位置 +Δ），后一半放"说谎点"——描述子
    // 干净唯一（能通过比值测试与交叉验证），位置却随机错位 ≥60px。
    // 匹配表因此一半几何一致、一半纯属巧合，RANSAC 必须靠内点投票
    // 把真变换捞出来。
    final pagePos = <Offset>[];
    final pageDesc = <Float64List>[];
    for (var i = 0; i < n; i++) {
      if (i < half) {
        pagePos.add(refPos[i] + delta);
      } else {
        final ang = rnd.nextDouble() * 2 * math.pi;
        final dist = 60.0 + rnd.nextDouble() * 200;
        pagePos.add(Offset(
          (refPos[i].dx + math.cos(ang) * dist).clamp(20.0, 580.0),
          (refPos[i].dy + math.sin(ang) * dist).clamp(20.0, 820.0),
        ));
      }
      pageDesc.add(_perturb(descs[i], rnd));
    }
    final out = alignWithFeatures(
      ref: _synthetic(refPos, descs),
      page: _synthetic(pagePos, pageDesc),
      random: math.Random(9),
    );
    expect(out.aligned, isTrue, reason: out.reason);
    // 说谎点约贡献一半匹配，内点比显著低于干净情形但门限以上。
    expect(out.inlierRatio, inExclusiveRange(0.3, 0.75));
    final t = out.transform!;
    expect(t.scale, closeTo(1.0, 0.02));
    for (final p in refPos) {
      expect((t.apply(p) - (p + delta)).distance, lessThan(0.5));
    }
  });

  test('同版式不同文字·白文无格线（绝学3 场景）：密度虚拟格点完成配准', () {
    // 白文小字页：无界栏、逐页文字不同、字块特征近乎为零——投影法
    // 靠文字列/行密度对齐它，特征法靠密度带虚拟格点。
    final ref = featuresOf(variedGrid(math.Random(41)));
    final page = featuresOf(translatePage(variedGrid(math.Random(42)), 11, 7));
    final out = alignWithFeatures(ref: ref, page: page, random: math.Random(5));
    expect(out.aligned, isTrue, reason: out.reason);
    final t = out.transform!;
    expect(t.angle.abs(), lessThan(0.3 * math.pi / 180.0));
    // 用参考页的虚拟格点验证恢复：T(r) ≈ r + (11,7)。密度带中心随
    // 页面文字内容微晃（带心是墨迹加权的，异文页个别格点 ±3px），
    // 按分位数断言：典型（中位）< 1.5px，最差 < 5px。
    final residuals = <double>[];
    for (final p in ref.points.where((p) => p.type == FeatureType.junction)) {
      residuals.add(
          (t.apply(p.position) - (p.position + const Offset(11, 7))).distance);
    }
    residuals.sort();
    expect(residuals.length, greaterThan(10));
    expect(residuals[residuals.length ~/ 2], lessThan(1.5));
    expect(residuals.last, lessThan(5.0));
  });

  test('不同版式（列距行距不同）：匹配稀少/几何不一致，不强对齐', () {
    final ref = featuresOf(variedGrid(math.Random(100)));
    // 真正的版式差异：7 列 × 列距 62、11 行 × 行距 50——虚拟格点与
    // 参考页的网格错位，不应配准（同网格不同文字则理应对齐，见上）。
    final other = variedGrid(math.Random(200));
    final rects = <Rect>[];
    for (final r in other.ink) {
      // 把原 55px 列距重排到 62px、40px 行距到 50px。
      final c = ((r.left - 78) / 55).round();
      final k = ((r.top - 82) / 40).round();
      rects.add(r.translate(62.0 * c - 55.0 * c, 50.0 * k - 40.0 * k));
    }
    final page = featuresOf(SynthPage(rects, const []));
    final out = alignWithFeatures(ref: ref, page: page, random: math.Random(7));
    if (out.aligned) {
      expect(out.inlierRatio, lessThan(0.5));
    } else {
      expect(out.reason, isNotEmpty);
    }
  });

  test('同版式不同文字（真实逐页场景）：仅靠界栏交叉点完成配准', () {
    // 相邻页：格线版式相同（刚体印刷），文字内容不同——字形块特征
    // 跨页基本匹配不上（不同字），配准由交叉点特征承担。
    final ref = featuresOf(gridWithLattice(math.Random(11)));
    final page =
        featuresOf(translatePage(gridWithLattice(math.Random(22)), 10, 6));
    final out = alignWithFeatures(ref: ref, page: page, random: math.Random(3));
    expect(out.aligned, isTrue, reason: out.reason);
    final t = out.transform!;
    expect(t.angle.abs(), lessThan(0.3 * math.pi / 180.0));
    expect(t.scale, closeTo(1.0, 0.01));
    // 用参考页的交叉点验证恢复：T(r) ≈ r + (10,6)。
    var checked = 0;
    for (final p in ref.points
        .where((p) => p.type == FeatureType.junction)
        .take(20)) {
      expect((t.apply(p.position) - (p.position + const Offset(10, 6))).distance,
          lessThan(0.5));
      checked++;
    }
    expect(checked, greaterThan(10));
  });

  test('同版式不同文字 + 偏转 0.4°（真实扫描形态）', () {
    const psi = 0.4 * math.pi / 180.0;
    final ref = featuresOf(gridWithLattice(math.Random(31)));
    final page = featuresOf(
      translatePage(rotateAsStamps(gridWithLattice(math.Random(32)), psi), 9, 5),
    );
    final out = alignWithFeatures(ref: ref, page: page, random: math.Random(4));
    expect(out.aligned, isTrue, reason: out.reason);
    final t = out.transform!;
    expect(t.angle, closeTo(psi, 0.2 * math.pi / 180.0));
    // T(r) = C + R(ψ)(r − C) + (9,5)，用交叉点验证。
    final c = math.cos(psi), s = math.sin(psi);
    var checked = 0;
    for (final p in ref.points
        .where((p) => p.type == FeatureType.junction)
        .take(20)) {
      final dx = p.position.dx - center.dx, dy = p.position.dy - center.dy;
      final expected = Offset(
        center.dx + c * dx - s * dy + 9,
        center.dy + s * dx + c * dy + 5,
      );
      expect((t.apply(p.position) - expected).distance, lessThan(1.0));
      checked++;
    }
    expect(checked, greaterThan(10));
  });

  test('特征点过少（<3）：直接判不可配准', () {
    final f1 = _synthetic(
      [const Offset(100, 100)],
      [_randomUnit(math.Random(1))],
    );
    final f2 = _synthetic(
      [const Offset(120, 90), const Offset(300, 300)],
      [_randomUnit(math.Random(2)), _randomUnit(math.Random(3))],
    );
    final out = alignWithFeatures(ref: f1, page: f2, random: math.Random(8));
    expect(out.aligned, isFalse);
    expect(out.reason, '特征点不足');
  });
}
