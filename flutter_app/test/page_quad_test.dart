import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:gujichazi/models/page_quad.dart';

void main() {
  group('PageQuad 构造与默认值', () {
    test('defaultInset 按比例内缩', () {
      final q = PageQuad.defaultInset(const Size(1000, 2000));
      expect(q.tl, const Offset(20, 40));
      expect(q.tr.dx, closeTo(979, 1));
      expect(q.br.dy, closeTo(1959, 1));
    });

    test('fromPoints 保持 TL,TR,BR,BL 顺序', () {
      final q = PageQuad.fromPoints([
        [10, 20],
        [90, 20],
        [90, 180],
        [10, 180],
      ]);
      expect(q.tl, const Offset(10, 20));
      expect(q.br, const Offset(90, 180));
    });
  });

  group('角点与边中点拖拽', () {
    final rect = PageQuad(
      corners: const [
        Offset(0, 100),
        Offset(100, 100),
        Offset(100, 200),
        Offset(0, 200),
      ],
    );

    test('角点拖动只改该角', () {
      final q2 = rect.withCorner(1, const Offset(120, 90));
      expect(q2.tr, const Offset(120, 90));
      expect(q2.tl, const Offset(0, 100)); // 其他角不动
      expect(q2.br, const Offset(100, 200));
      expect(q2.bl, const Offset(0, 200));
    });

    test('拖边中点：该边两个角共同平移，对边不动', () {
      // 拖 top 边（TL-TR）向下 30px：TL、TR 一起动，BL、BR 不动。
      final q2 = rect.withEdgeDrag(
        PageQuad.edgeTop,
        const Offset(50, 80), // 按下时指针位置
        const Offset(60, 110), // 拖到（位移 +10,+30）
        List.of(rect.corners),
      );
      expect(q2.tl, const Offset(10, 130));
      expect(q2.tr, const Offset(110, 130));
      expect(q2.bl, const Offset(0, 200));
      expect(q2.br, const Offset(100, 200));
      // 整条边保持原方向与长度（纯平移）。
      expect(q2.tr - q2.tl, rect.tr - rect.tl);
    });

    test('拖 right 边只动 TR、BR', () {
      final q2 = rect.withEdgeDrag(
        PageQuad.edgeRight,
        const Offset(100, 150),
        const Offset(130, 150),
        List.of(rect.corners),
      );
      expect(q2.tr, const Offset(130, 100));
      expect(q2.br, const Offset(130, 200));
      expect(q2.tl, const Offset(0, 100));
      expect(q2.bl, const Offset(0, 200));
    });

    test('edgeMid 位于两端点正中', () {
      expect(rect.edgeMid(PageQuad.edgeTop), const Offset(50, 100));
      expect(rect.edgeMid(PageQuad.edgeBottom), const Offset(50, 200));
      expect(rect.edgeMid(PageQuad.edgeRight), const Offset(100, 150));
      expect(rect.edgeMid(PageQuad.edgeLeft), const Offset(0, 150));
    });

    test('edgeCorners 返回该边两端角点', () {
      expect(
        rect.edgeCorners(PageQuad.edgeBottom),
        [const Offset(0, 200), const Offset(100, 200)],
      );
    });
  });

  group('边中点拖拽 Shift 法线锁定（lockToNormal）', () {
    final rect = PageQuad(
      corners: const [
        Offset(0, 100),
        Offset(100, 100),
        Offset(100, 200),
        Offset(0, 200),
      ],
    );

    test('水平边：位移只保留垂直分量，平行分量被丢弃', () {
      // 拖 top 边位移 (+10,+30)：法线为 (0,1)，投影后只剩 (0,+30)，
      // 沿边方向的 +10 被丢掉。
      final q2 = rect.withEdgeDrag(
        PageQuad.edgeTop,
        const Offset(50, 80),
        const Offset(60, 110),
        List.of(rect.corners),
        lockToNormal: true,
      );
      expect(q2.tl, const Offset(0, 130));
      expect(q2.tr, const Offset(100, 130));
      expect(q2.bl, const Offset(0, 200));
      expect(q2.br, const Offset(100, 200));
    });

    test('斜边：位移投影到该边法线，整条边保持与原边平行', () {
      // top 边 TL(0,0)→TR(50,50)，边向量 (50,50)、法线 (-1/√2, 1/√2)；
      // 指针位移 (+10,0) 投影后 = (5,-5)（与边垂直、沿法线）。
      final slant = PageQuad(
        corners: const [
          Offset(0, 0),
          Offset(50, 50),
          Offset(100, 150),
          Offset(0, 100),
        ],
      );
      final q2 = slant.withEdgeDrag(
        PageQuad.edgeTop,
        const Offset(25, 25),
        const Offset(35, 25),
        List.of(slant.corners),
        lockToNormal: true,
      );
      expect(q2.tl.dx, closeTo(5, 1e-9));
      expect(q2.tl.dy, closeTo(-5, 1e-9));
      expect(q2.tr.dx, closeTo(55, 1e-9));
      expect(q2.tr.dy, closeTo(45, 1e-9));
      // 边向量不变（平行移动），且位移向量与边垂直。
      expect(q2.tr - q2.tl, slant.tr - slant.tl);
      final move = q2.tl - slant.tl;
      expect(
        move.dx * 50 + move.dy * 50, // 与边向量 (50,50) 点积应为 0
        closeTo(0, 1e-9),
      );
    });

    test('退化边（两角重合）退回自由平移，不抛异常', () {
      final degenerate = PageQuad(
        corners: const [
          Offset(50, 50),
          Offset(50, 50),
          Offset(100, 200),
          Offset(0, 200),
        ],
      );
      final q2 = degenerate.withEdgeDrag(
        PageQuad.edgeTop,
        const Offset(50, 50),
        const Offset(70, 80),
        List.of(degenerate.corners),
        lockToNormal: true,
      );
      expect(q2.tl, const Offset(70, 80));
      expect(q2.tr, const Offset(70, 80));
    });
  });

  group('旋转换算', () {
    final q = PageQuad(
      corners: const [
        Offset(10, 20),
        Offset(110, 25),
        Offset(105, 220),
        Offset(15, 210),
      ],
    );

    test('CW 四次回到原位', () {
      var cur = q;
      var w = 120, h = 240;
      for (var i = 0; i < 4; i++) {
        cur = cur.rotatedCW(w, h);
        final t = w;
        w = h;
        h = t;
      }
      for (var i = 0; i < 4; i++) {
        expect(cur.corners[i].dx, closeTo(q.corners[i].dx, 0.5));
        expect(cur.corners[i].dy, closeTo(q.corners[i].dy, 0.5));
      }
    });

    test('CW+CCW 互逆', () {
      final cw = q.rotatedCW(120, 240);
      final back = cw.rotatedCCW(240, 120);
      for (var i = 0; i < 4; i++) {
        expect(back.corners[i].dx, closeTo(q.corners[i].dx, 0.5));
        expect(back.corners[i].dy, closeTo(q.corners[i].dy, 0.5));
      }
    });

    test('CW 角点映射正确（旧 BL → 新 TL）', () {
      final cw = q.rotatedCW(120, 240);
      expect(cw.tl.dx, closeTo(240 - 1 - 210, 0.5)); // 旧 BL (15,210)
      expect(cw.tl.dy, closeTo(15, 0.5));
    });
  });

  group('自交检测', () {
    test('正常四边形 isSimple', () {
      final q = PageQuad(
        corners: const [
          Offset(0, 0),
          Offset(100, 0),
          Offset(100, 200),
          Offset(0, 200),
        ],
      );
      expect(q.isSimple(), isTrue);
    });

    test('蝴蝶形（TL/BR 对调）判自交', () {
      final q = PageQuad(
        corners: const [
          Offset(100, 0),
          Offset(0, 0),
          Offset(100, 200),
          Offset(0, 200),
        ],
      );
      expect(q.isSimple(), isFalse);
    });

    test('角点重合判为退化', () {
      final q = PageQuad(
        corners: const [
          Offset(0, 0),
          Offset(0, 0),
          Offset(100, 200),
          Offset(0, 200),
        ],
      );
      expect(q.isSimple(), isFalse);
    });
  });

  group('直边几何', () {
    test('toPath 为直边闭合路径（包围盒=角点范围）', () {
      final q = PageQuad.defaultInset(const Size(500, 800));
      final bounds = q.toPath().getBounds();
      expect(bounds.width, greaterThan(400));
      expect(bounds.height, greaterThan(700));
    });

    test('pointAt 双线性取点', () {
      final q = PageQuad(
        corners: const [
          Offset(0, 0),
          Offset(100, 0),
          Offset(100, 200),
          Offset(0, 200),
        ],
      );
      expect(q.pointAt(0, 0), const Offset(0, 0));
      expect(q.pointAt(1, 1), const Offset(100, 200));
      expect(q.pointAt(0.5, 0.5), const Offset(50, 100));
      expect(q.pointAt(0.25, 0.75), const Offset(25, 150));
    });
  });

  group('JSON 往返', () {
    test('toJson/fromJson 对称（仅角点，直边）', () {
      final q = PageQuad(
        corners: const [
          Offset(1.5, 2.5),
          Offset(300, 4),
          Offset(299, 400),
          Offset(2, 398),
        ],
      );
      final back = PageQuad.fromJson(q.toJson());
      for (var i = 0; i < 4; i++) {
        expect(back.corners[i], q.corners[i]);
      }
      // 序列化不含弯边字段（后端走直边单应）。
      expect(q.cornersJson().length, 4);
      expect(q.toJson().containsKey('edge_mids'), isFalse);
    });
  });

  group('canvasInitialMatrix 换图初始矩阵（编辑器翻页缩放沿用）', () {
    test('无沿用比例 → 整页适配并居中', () {
      final m = canvasInitialMatrix(
        viewportWidth: 800,
        viewportHeight: 600,
        imageWidth: 1600,
        imageHeight: 1200,
      );
      expect(matrixXyScale(m), closeTo(0.5, 1e-9));
      expect(m.storage[12], 0.0); // dx：适配后恰好铺满，无居中偏移
      expect(m.storage[13], 0.0);
    });

    test('小图不放大超过 1:1，居中呈现', () {
      final m = canvasInitialMatrix(
        viewportWidth: 800,
        viewportHeight: 600,
        imageWidth: 400,
        imageHeight: 300,
      );
      expect(matrixXyScale(m), 1.0);
      expect(m.storage[12], 200.0);
      expect(m.storage[13], 150.0);
    });

    test('沿用比例：上一页放大的比例原样保留（翻页不打回适配）', () {
      final m = canvasInitialMatrix(
        viewportWidth: 800,
        viewportHeight: 600,
        imageWidth: 1600,
        imageHeight: 1200,
        carriedScale: 2.0,
      );
      expect(matrixXyScale(m), 2.0);
      // 画面大于视口：左上角锚定
      expect(m.storage[12], 0.0);
      expect(m.storage[13], 0.0);
    });

    test('沿用比例小于适配：仍按该比例居中（用户主动缩小）', () {
      final m = canvasInitialMatrix(
        viewportWidth: 800,
        viewportHeight: 600,
        imageWidth: 1600,
        imageHeight: 1200,
        carriedScale: 0.2,
      );
      expect(matrixXyScale(m), 0.2);
      expect(m.storage[12], (800 - 1600 * 0.2) / 2);
      expect(m.storage[13], (600 - 1200 * 0.2) / 2);
    });

    test('沿用比例超限被钳制到滚轮缩放上限 8.0', () {
      final m = canvasInitialMatrix(
        viewportWidth: 800,
        viewportHeight: 600,
        imageWidth: 1600,
        imageHeight: 1200,
        carriedScale: 100.0,
      );
      expect(matrixXyScale(m), 8.0);
    });

    test('新页与上一页尺寸不同：比例不变，居中公式按新尺寸计算', () {
      // 上一页竖版沿用 0.5，本页横版（旋转后）：0.5 保持，居中按横版算
      final m = canvasInitialMatrix(
        viewportWidth: 800,
        viewportHeight: 600,
        imageWidth: 1200,
        imageHeight: 1600,
        carriedScale: 0.5,
      );
      expect(matrixXyScale(m), 0.5);
      expect(m.storage[12], (800 - 1200 * 0.5) / 2);
      expect(m.storage[13], 0.0); // 600 - 1600*0.5 < 0 → 收敛 0
    });
  });

  group('整体缩放 scaled（Ctrl+滚轮缩框）', () {
    final quad = PageQuad(corners: const [
      Offset(100, 100),
      Offset(300, 100),
      Offset(300, 260),
      Offset(100, 260),
    ]);

    test('绕质心等比缩放：质心不动，角点距质心同比、方向不变', () {
      final c = quad.centroid; // (200, 180)
      final grown = quad.scaled(1.25);
      expect(grown.centroid, c);
      for (var i = 0; i < 4; i++) {
        final d0 = quad.corners[i] - c;
        final d1 = grown.corners[i] - c;
        expect(d1.distance, closeTo(d0.distance * 1.25, 1e-9));
        // 方向（单位向量）不变：形状严格保持。
        expect(d1.dx / d1.distance, closeTo(d0.dx / d0.distance, 1e-9));
        expect(d1.dy / d1.distance, closeTo(d0.dy / d0.distance, 1e-9));
      }
    });

    test('显式中心：绕指定点缩放（质心平移语义）', () {
      final atOrigin = quad.scaled(2.0, center: Offset.zero);
      expect(atOrigin.tl, const Offset(200, 200));
      expect(atOrigin.br, const Offset(600, 520));
    });

    test('缩放是相似变换：自交性/退化判定不变', () {
      expect(quad.scaled(0.5).isSimple(), quad.isSimple());
      expect(quad.scaled(3.0).isSimple(), quad.isSimple());
    });
  });
}
