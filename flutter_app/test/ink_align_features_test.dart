import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/services/feature_points.dart';
import 'package:gujichazi/services/ink_align.dart';

import 'feature_synthetic.dart';

/// 特征法组配准路由（computeInkAlignmentsFromFeatures）回归测试：
/// 验证"相似变换 → 绘制分量"的换算约定（shift 的推导见函数注释）。
///
/// 核心恒等式（参考页选择与中位归零均免疫）：同一物理特征点在非参
/// 考页变换下的落点 == 在参考页自己变换下的落点——画页/写回框共用
/// 变换的正确性根基。两页特征数相等时参考页可能落在任一侧（中位
/// 数取上侧），测试不得假设它是哪页。
///
/// 叠加画布 1200×1680（canvasScale = 2，与 ink_align_test 同口径）。

const _overlay = Size(1200, 1680);
const _overlayCenter = Offset(600, 840);

Offset _x2(Offset p) => Offset(p.dx * 2, p.dy * 2);

void main() {
  test('两页平移 (12,7)：全对齐、|角度|≈0、同特征点两页落点重合', () {
    final page1 = variedGrid(math.Random(51));
    final feats = <int, InkPageFeatures>{
      0: featuresOf(page1),
      1: featuresOf(translatePage(page1, 12, 7)),
    };
    final result = computeInkAlignmentsFromFeatures(
      features: feats,
      canvasScale: 2,
      overlayCanvas: _overlay,
    );
    expect(result.referencePage, greaterThanOrEqualTo(0));
    expect(result.alignedCount, 2, reason: '两页应全部对齐');
    expect(result.globalScale, 1.0); // 无旋转不缩
    final other = 1 - result.referencePage;
    final a = result.byPage[other]!;
    expect(a.aligned, isTrue);
    expect(a.angle.abs(), lessThan(0.3 * math.pi / 180.0));
    // 两页 shift 之差 = 相对平移 −(12,7)·2（中位归零会把系综整体挪，
    // 单页的 shift 不代表物理平移，差值才是）。
    final diff = a.shift - result.byPage[result.referencePage]!.shift;
    expect(diff.distance, closeTo(Offset(24, 14).distance, 1.0));

    // 落点恒等式：other 页的特征 p 与参考页对应特征（p 从 other 页
    // 坐标换回参考页坐标：other=0 时参考页平移了 +(12,7)，反之 −）
    // 在各自变换下画到叠加画布的落点必须一致。
    final trOther = result.transformFor(other);
    final trRef = result.transformFor(result.referencePage);
    final refPts = feats[result.referencePage]!.points;
    final pagePts = feats[other]!.points;
    final back = other == 0 ? const Offset(12, 7) : const Offset(-12, -7);
    var checked = 0;
    for (final p in pagePts) {
      final counterpart = p.position + back;
      final hasRef = refPts.any((r) => (r.position - counterpart).distance < 1);
      if (!hasRef) continue;
      final dOther = trOther.forward(_x2(p.position), _overlayCenter);
      final dRef = trRef.forward(_x2(counterpart), _overlayCenter);
      expect((dOther - dRef).distance, lessThan(1.5));
      checked++;
    }
    expect(checked, greaterThan(40));
  });

  test('两页旋转 1.2°：|角度|≈1.2°、整体缩放生效、两页落点重合', () {
    // 1.2° 已是真实扫描（≤0.5°）的 ~3 倍压力；更高偏转下虚拟格点
    // 共识角被拉低（已知边界，见 feature_matching_test 注释）。
    const psi = 1.2 * math.pi / 180.0;
    final page1 = variedGrid(math.Random(63));
    final feats = <int, InkPageFeatures>{
      0: featuresOf(page1),
      1: featuresOf(rotateAsStamps(page1, psi)),
    };
    final result = computeInkAlignmentsFromFeatures(
      features: feats,
      canvasScale: 2,
      overlayCanvas: _overlay,
    );
    expect(result.alignedCount, 2, reason: '两页应全部对齐');
    final other = 1 - result.referencePage;
    final a = result.byPage[other]!;
    expect(a.aligned, isTrue);
    expect(a.angle.abs(), closeTo(psi, 0.3 * math.pi / 180.0));
    // 旋转触发整体收缩：所有页（含参考页）统一按 S 缩。
    expect(result.globalScale, lessThan(1.0));

    final trOther = result.transformFor(other);
    final trRef = result.transformFor(result.referencePage);
    final refPts = feats[result.referencePage]!.points;
    final pagePts = feats[other]!.points;
    // 非参考页特征 p 在参考页坐标的对应位置：T⁻¹(p)。
    // T = R(∓ψ) 绕画布心 C（方向取决于谁是参考页），逆 = R(±ψ)。
    final rev = other == 0 ? psi : -psi;
    final c = math.cos(rev), s = math.sin(rev);
    // 落点差按分位数断言：角度分量粗 ~0.4° + 带心随内容微晃——
    // 中位 < 2.5px，最差（页角 + 异文晃动）< 7px。
    final gaps = <double>[];
    for (final p in pagePts) {
      final dx = p.position.dx - center.dx, dy = p.position.dy - center.dy;
      final counterpart = Offset(
        center.dx + c * dx - s * dy,
        center.dy + s * dx + c * dy,
      );
      final hasRef = refPts.any((r) => (r.position - counterpart).distance < 1.2);
      if (!hasRef) continue;
      final dOther = trOther.forward(_x2(p.position), _overlayCenter);
      final dRef = trRef.forward(_x2(counterpart), _overlayCenter);
      gaps.add((dOther - dRef).distance);
    }
    gaps.sort();
    expect(gaps.length, greaterThan(30));
    expect(gaps[gaps.length ~/ 2], lessThan(2.5));
    expect(gaps.last, lessThan(7.0));
  });
}
