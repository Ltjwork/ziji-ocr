import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/services/annotation_hit_geometry.dart';

void main() {
  test('corner hit chooses nearest corner when low zoom targets overlap', () {
    final rect = const Rect.fromLTWH(100, 100, 80, 60);
    final handle = AnnotationHitGeometry.hitResizeHandle(
      rect,
      const Offset(176, 104),
      scale: 0.05,
      imageHitSize: 22,
      minimumScreen: 24,
    );
    expect(handle, AnnotationResizeHandle.topRight);
  });

  test('corner hit accepts the outside half of the visual handle', () {
    final handle = AnnotationHitGeometry.hitResizeHandle(
      const Rect.fromLTWH(100, 100, 80, 60),
      const Offset(92, 93),
      scale: 1,
      imageHitSize: 22,
      minimumScreen: 24,
    );
    expect(handle, AnnotationResizeHandle.topLeft);
  });

  test('hit target and visual target preserve minimum screen size', () {
    expect(
      AnnotationHitGeometry.imageSizeForScreenMinimum(
        12,
        0.5,
        minimumScreen: 10,
      ),
      20,
    );
    expect(
      AnnotationHitGeometry.imageSizeForScreenMinimum(12, 2, minimumScreen: 10),
      12,
    );
  });

  test('selection prefers containment and then closest expanded rectangle', () {
    final rects = <Rect>[
      const Rect.fromLTWH(0, 0, 10, 10),
      const Rect.fromLTWH(12, 0, 10, 10),
    ];
    expect(
      AnnotationHitGeometry.hitRectIndex(rects, const Offset(5, 5), scaleX: 1),
      0,
    );
    expect(
      AnnotationHitGeometry.hitRectIndex(
        rects,
        const Offset(11, 5),
        scaleX: 1,
        toleranceScreen: 3,
      ),
      1,
    );
  });

  test('resize keeps the click offset from the handle center', () {
    final resized = AnnotationHitGeometry.resizeRect(
      const Rect.fromLTWH(10, 20, 40, 30),
      const Offset(62, 54),
      AnnotationResizeHandle.bottomRight,
      pointerOffset: const Offset(2, 4),
      minSize: 10,
    );
    expect(resized, const Rect.fromLTWH(10, 20, 50, 30));
  });

  test(
    'resizing a left corner keeps the opposite edge fixed after rounding',
    () {
      const original = Rect.fromLTWH(10, 20, 40, 30);
      final first = AnnotationHitGeometry.resizeRect(
        original,
        const Offset(21.6, 31.6),
        AnnotationResizeHandle.topLeft,
        minSize: 10,
      );
      // Simulate the editor writing integer coordinates after this pointer move.
      final integerized = Rect.fromLTWH(
        first.left.toInt().toDouble(),
        first.top.toInt().toDouble(),
        first.width.toInt().toDouble(),
        first.height.toInt().toDouble(),
      );
      final second = AnnotationHitGeometry.resizeRect(
        integerized,
        const Offset(22.4, 32.4),
        AnnotationResizeHandle.topLeft,
        minSize: 10,
      );

      expect(first.right, original.right);
      expect(first.bottom, original.bottom);
      expect(integerized.right, original.right);
      expect(integerized.bottom, original.bottom);
      expect(second.right, original.right);
      expect(second.bottom, original.bottom);

      final bottomLeft = AnnotationHitGeometry.resizeRect(
        original,
        const Offset(22.4, 47.6),
        AnnotationResizeHandle.bottomLeft,
        minSize: 10,
      );
      expect(bottomLeft.right, original.right);
      expect(bottomLeft.top, original.top);
    },
  );

  test(
    'top-right resize keeps the anchored bottom fixed under half-pixel pointer streams',
    () {
      // 用户实测：显示比例把指针坐标映射到半整数时，旧实现里顶边/高度
      // 各自独立取整、两处同时进位，固定底边每个指针事件下移 1px（一次
      // 拖拽累计 487 -> 546）。固定边必须直接取整数原值。
      final original = const Rect.fromLTWH(611, 449, 34, 38); // 实测问题框
      var rect = original;
      for (var k = 0; k < 200; k++) {
        // 半整数指针流：顶边目标始终落在 .5 上（最坏情形）
        rect = AnnotationHitGeometry.resizeTopRightRect(
          rect,
          rect.right + 0.5,
          456.5,
        );
        // 模拟编辑器按整数坐标写回标注
        rect = Rect.fromLTWH(
          rect.left,
          rect.top,
          rect.width.toInt().toDouble(),
          rect.height.toInt().toDouble(),
        );
      }
      expect(rect.bottom, original.bottom); // 底边 487 钉死
      expect(rect.left, original.left); // 左边不动
      expect(rect.top, 457); // 半整数进位一次后稳定
      expect(rect.height, original.bottom - 457);
    },
  );

  test('top-right resize clamps top to min size and page top', () {
    const original = Rect.fromLTWH(611, 449, 34, 38);
    // 顶边越过底边-5 → 钳到最小高度
    final clamped = AnnotationHitGeometry.resizeTopRightRect(
      original,
      650,
      600,
    );
    expect(clamped.bottom, original.bottom);
    expect(clamped.height, 5);
    // 顶边出页面顶（abs y < 0）→ 钳到 0
    final topClamped = AnnotationHitGeometry.resizeTopRightRect(
      original,
      650,
      -30,
    );
    expect(topClamped.top, 0);
    expect(topClamped.bottom, original.bottom);
  });

  /// Ctrl 联动（linkedNeighborIndex / linkedNeighborRect）：行卡片按住
  /// Ctrl 拖字框手柄时相邻字框的贴合边跟随同样位移，保持两框原有间距。
  group('Ctrl 联动 linkedNeighbor', () {
    // 竖排行三字（用户场景：其 → 气 → 下一字），gap 均为 10
    final verticalRects = <Rect>[
      const Rect.fromLTWH(0, 100, 40, 60), // 其：100–160
      const Rect.fromLTWH(0, 170, 40, 40), // 气：170–210
      const Rect.fromLTWH(0, 220, 40, 40), // 第三字：220–260
    ];

    test('竖排拖底边 → 下方邻框顶边跟随同样位移，保持原间距', () {
      expect(
        AnnotationHitGeometry.linkedNeighborIndex(
          verticalRects,
          0,
          horizontal: false,
        ),
        1,
      );
      // 其底边 160 → 175（位移 +15）→ 气顶边 170 → 185，底边钉死
      final linked = AnnotationHitGeometry.linkedNeighborRect(
        horizontal: false,
        draggedOriginal: verticalRects[0],
        draggedUpdated: const Rect.fromLTWH(0, 100, 40, 75),
        neighborOriginal: verticalRects[1],
      );
      expect(linked, const Rect.fromLTWH(0, 185, 40, 25));
      // 间距保持：新气顶 185 - 新其底 175 = 原间距 10，而非对齐到 175
      expect(linked!.top - 175, 10);
    });

    test('竖排拖顶边 → 上方邻框底边跟随', () {
      expect(
        AnnotationHitGeometry.linkedNeighborIndex(
          verticalRects,
          1,
          horizontal: false,
          upward: true,
        ),
        0,
      );
      // 气顶边 170 → 165（位移 -5）→ 其底边 160 → 155，顶边钉死
      final linked = AnnotationHitGeometry.linkedNeighborRect(
        horizontal: false,
        upward: true,
        draggedOriginal: verticalRects[1],
        draggedUpdated: const Rect.fromLTWH(0, 165, 40, 45),
        neighborOriginal: verticalRects[0],
      );
      expect(linked, const Rect.fromLTWH(0, 100, 40, 55));
      expect(165 - linked!.bottom, 10); // 原间距 10 保持
    });

    test('横排拖右边 → 右侧邻框左边跟随（两柄同边，upward 不参与）', () {
      final rects = <Rect>[
        const Rect.fromLTWH(0, 0, 50, 40), // A：right 50
        const Rect.fromLTWH(58, 0, 50, 40), // B：left 58，间距 8
      ];
      expect(
        AnnotationHitGeometry.linkedNeighborIndex(
          rects,
          0,
          horizontal: true,
          upward: true,
        ),
        1,
      );
      final linked = AnnotationHitGeometry.linkedNeighborRect(
        horizontal: true,
        draggedOriginal: rects[0],
        draggedUpdated: const Rect.fromLTWH(0, 0, 55, 40),
        neighborOriginal: rects[1],
      );
      expect(linked, const Rect.fromLTWH(63, 0, 45, 40));
      expect(linked!.left - 55, 8); // 原间距 8 保持
    });

    test('跟随边钳制：不越过邻框对边-5、不出页面顶；无位移返回 null', () {
      // 位移 +300 → 气顶边 470 越过其底边 210-5 → 钳到 205（最小高度 5）
      final clamped = AnnotationHitGeometry.linkedNeighborRect(
        horizontal: false,
        draggedOriginal: verticalRects[0],
        draggedUpdated: const Rect.fromLTWH(0, 100, 40, 360),
        neighborOriginal: verticalRects[1],
      );
      expect(clamped, const Rect.fromLTWH(0, 205, 40, 5));
      // 位移取整后为 0 → null（无可预览/提交的变化）
      expect(
        AnnotationHitGeometry.linkedNeighborRect(
          horizontal: false,
          draggedOriginal: verticalRects[0],
          draggedUpdated: verticalRects[0],
          neighborOriginal: verticalRects[1],
        ),
        isNull,
      );
    });

    test('邻框选取：无同侧邻框返回 null；多个候选取贴合边最近者', () {
      // 竖排最后一个字向下无邻框；第一个字向上无邻框
      expect(
        AnnotationHitGeometry.linkedNeighborIndex(
          verticalRects,
          2,
          horizontal: false,
        ),
        isNull,
      );
      expect(
        AnnotationHitGeometry.linkedNeighborIndex(
          verticalRects,
          0,
          horizontal: false,
          upward: true,
        ),
        isNull,
      );
      // 拖第一个字底边：气（top 170）比第三字（top 220）更近 → 气
      expect(
        AnnotationHitGeometry.linkedNeighborIndex(
          verticalRects,
          0,
          horizontal: false,
        ),
        1,
      );
      // 框中心判定同侧：与被拖框中心重叠的远框不抢最近贴合边
      final overlapped = <Rect>[
        const Rect.fromLTWH(0, 100, 40, 60), // 被拖框中心 y=130
        const Rect.fromLTWH(0, 112, 40, 20), // 中心 y=122（上方侧）
        const Rect.fromLTWH(0, 170, 40, 40), // 下方最近
      ];
      expect(
        AnnotationHitGeometry.linkedNeighborIndex(
          overlapped,
          0,
          horizontal: false,
        ),
        2,
      );
    });

    test('Alt 切割：中点切线竖排上下，奇数长度和恒等于原长', () {
      // 气 (0,170,40,41)：中点切线 190.5 → 取整 191（四舍五入），
      // 前半 21、后半 20
      final halves = AnnotationHitGeometry.splitRectAt(
        const Rect.fromLTWH(0, 170, 40, 41),
        cut: 170 + 41 / 2,
        horizontal: false,
      );
      final (first, second) = halves!;
      expect(first.height + second.height, 41);
      // 前后半贴合无缝、左右边与原框一致
      expect(first.bottom, second.top);
      expect(first.left, 0);
      expect(second.right, 40);
    });

    test('Alt 切割：横排按切线左右；太薄返回 null', () {
      final halves = AnnotationHitGeometry.splitRectAt(
        const Rect.fromLTWH(10, 20, 50, 40),
        cut: 35,
        horizontal: true,
      );
      final (first, second) = halves!;
      expect(first, const Rect.fromLTRB(10, 20, 35, 60));
      expect(second, const Rect.fromLTRB(35, 20, 60, 60));
      // 轴向长度不足 2×5 → 拆不出两个最小框
      expect(
        AnnotationHitGeometry.splitRectAt(
          const Rect.fromLTWH(0, 170, 40, 9),
          cut: 175,
          horizontal: false,
        ),
        isNull,
      );
      expect(
        AnnotationHitGeometry.splitRectAt(
          const Rect.fromLTWH(0, 170, 9, 40),
          cut: 5,
          horizontal: true,
        ),
        isNull,
      );
    });
  });

  /// 新字按阅读序插入的落点（readingOrderInsertIndex）。
  group('splitRectAt（Alt 悬停虚线+点击切割）', () {
    test('按指定切线拆分：横排左右、竖排上下，两段之和恒等于原长', () {
      // 横排：cut=32 → 前半宽 22、后半宽 18
      final h = AnnotationHitGeometry.splitRectAt(
        const Rect.fromLTWH(10, 20, 40, 30),
        cut: 32,
        horizontal: true,
      )!;
      final (h1, h2) = h;
      expect(h1, const Rect.fromLTRB(10, 20, 32, 50));
      expect(h2, const Rect.fromLTRB(32, 20, 50, 50));
      expect(h1.width + h2.width, 40);
      expect(h1.right, h2.left);
      // 竖排：cut=100 → 前半高 30、后半高 10
      final v = AnnotationHitGeometry.splitRectAt(
        const Rect.fromLTWH(0, 70, 40, 40),
        cut: 100,
        horizontal: false,
      )!;
      final (v1, v2) = v;
      expect(v1, const Rect.fromLTRB(0, 70, 40, 100));
      expect(v2, const Rect.fromLTRB(0, 100, 40, 110));
      expect(v1.height + v2.height, 40);
      expect(v1.bottom, v2.top);
    });

    test('切线钳进两侧各留 5px 有效区并取整像素（所见即所切）', () {
      // 悬停贴近左缘（cut=12 < 10+5=15）→ 钳到 15，两半都 ≥ 最小框
      final clamped = AnnotationHitGeometry.splitRectAt(
        const Rect.fromLTWH(10, 20, 40, 30),
        cut: 12,
        horizontal: true,
      )!;
      final (first, second) = clamped;
      expect(first, const Rect.fromLTRB(10, 20, 15, 50));
      expect(second, const Rect.fromLTRB(15, 20, 50, 50));
      // 小数切线四舍五入到整数像素（坐标保持整数、和恒等于原长）
      final rounded = AnnotationHitGeometry.splitRectAt(
        const Rect.fromLTWH(0, 0, 40, 40),
        cut: 20.6,
        horizontal: false,
      )!;
      final (r1, r2) = rounded;
      expect(r1.bottom, 21);
      expect(r2.top, 21);
      expect(r1.height + r2.height, 40);
    });

    test('轴向不足 10px 返回 null（与平分同门槛）', () {
      expect(
        AnnotationHitGeometry.splitRectAt(
          const Rect.fromLTWH(0, 170, 40, 9),
          cut: 175,
          horizontal: false,
        ),
        isNull,
      );
      expect(
        AnnotationHitGeometry.splitRectAt(
          const Rect.fromLTWH(0, 170, 9, 40),
          cut: 5,
          horizontal: true,
        ),
        isNull,
      );
    });
  });

  group('nearestHandle（Alt+点击：选中框最近顶点）', () {
    const rect = Rect.fromLTWH(100, 100, 80, 60);

    test('画布远处点击取距离最近的角，命中半径无上限', () {
      expect(
        AnnotationHitGeometry.nearestHandle(rect, const Offset(500, 60)),
        AnnotationResizeHandle.topRight,
      );
      expect(
        AnnotationHitGeometry.nearestHandle(rect, const Offset(10, 400)),
        AnnotationResizeHandle.bottomLeft,
      );
    });

    test('框内点击同样取最近角', () {
      expect(
        AnnotationHitGeometry.nearestHandle(rect, const Offset(110, 115)),
        AnnotationResizeHandle.topLeft,
      );
      expect(
        AnnotationHitGeometry.nearestHandle(rect, const Offset(170, 150)),
        AnnotationResizeHandle.bottomRight,
      );
    });

    test('零偏移缩放把顶点精确移到点击处（对边钉死，四舍五入取整）', () {
      final moved = AnnotationHitGeometry.resizeRect(
        rect,
        const Offset(300.4, 20.6),
        AnnotationResizeHandle.topRight,
        minSize: 20,
      );
      expect(moved.right, 300);
      expect(moved.top, 21);
      expect(moved.left, 100);
      expect(moved.bottom, 160);
    });
  });

  group('readingOrderInsertIndex', () {
    test('横排 ltr：行尾/行中/行首新字各归其位', () {
      // 行内三字中心 X：10、50、90（ltr 阅读序）
      const axes = [10.0, 50.0, 90.0];
      // 行尾（右侧）新字 → 追加
      expect(readingOrderInsertIndex(axes, 130, rtl: false), 3);
      // 两字之间 → 插到后者前
      expect(readingOrderInsertIndex(axes, 70, rtl: false), 2);
      // 行首（左侧）之前 → 插到最前
      expect(readingOrderInsertIndex(axes, 5, rtl: false), 0);
    });

    test('横排 rtl：轴向递减阅读序下新字按从右到左归位', () {
      // 行内三字按 rtl 阅读序排列：中心 X 90、50、10（最先读最右）
      const axes = [90.0, 50.0, 10.0];
      // 更靠右的新字 → 排最前
      expect(readingOrderInsertIndex(axes, 130, rtl: true), 0);
      // 90 与 50 之间 → 插到下标 1
      expect(readingOrderInsertIndex(axes, 70, rtl: true), 1);
      // 最左 → 追加到行尾
      expect(readingOrderInsertIndex(axes, 5, rtl: true), 3);
    });

    test('本页覆盖 ltr 时不得按整书 rtl 判读（回归：新字全插到行首）', () {
      // 整书竖排列序 rtl、按页覆盖成横排 ltr 的页：行内字按 ltr 排列，
      // 行尾新画的字必须追加到行尾——修复前误用整书 rtl 判读会返回 0。
      const axes = [10.0, 50.0, 90.0];
      expect(readingOrderInsertIndex(axes, 130, rtl: false), 3);
      expect(readingOrderInsertIndex(axes, 70, rtl: false), 2);
    });
  });
}
