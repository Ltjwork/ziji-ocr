import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';

/// 页面旋转/镜像的标注几何同步变换（与后端 /transform_page 的像素映射
/// 逐点一致；Python 侧同名映射测试见 test_segmenter.py）。
void main() {
  PageAnnotation build() {
    final char = CharBlock(
      id: 'c1',
      x: 30,
      y: 40,
      w: 20,
      h: 10,
      col: 0,
      order: 0,
    );
    final line = LineBlock(
      id: 'l1',
      x: 30,
      y: 40,
      w: 20,
      h: 10,
      lineNo: 0,
      chars: [char],
    );
    final region = MainRegion(id: 'mr_1', x: 30, y: 40, w: 20, h: 10);
    final paragraph = Paragraph(id: 'mp_1', x: 30, y: 40, w: 20, h: 10);
    return PageAnnotation(
      pageId: 'page_000',
      imagePath: 'fake.png',
      mainRegions: [region],
      paragraphs: [paragraph],
      lines: [line],
      blocks: [char],
    );
  }

  test('rotate_cw 交换宽高并互换行方向', () {
    final ann = build();
    ann.transformGeometry('rotate_cw', 80, 120); // 旧 120x80 → 新 80x120
    final line = ann.lines.first;
    expect((line.x, line.y, line.w, line.h), (80 - 50, 30, 10, 20));
    expect(line.orientation, 'horizontal');
    expect((ann.blocks.first.x, ann.blocks.first.y), (80 - 50, 30));
    expect(
      (ann.mainRegions.first.x, ann.mainRegions.first.w),
      (80 - 50, 10),
    );
    expect((ann.paragraphs.first.y, ann.paragraphs.first.h), (30, 20));
  });

  test('rotate_ccw 交换宽高并互换行方向', () {
    final ann = build();
    ann.transformGeometry('rotate_ccw', 80, 120);
    final line = ann.lines.first;
    expect((line.x, line.y, line.w, line.h), (40, 120 - 50, 10, 20));
    expect(line.orientation, 'horizontal');
  });

  test('flip_h 左右镜像', () {
    final ann = build();
    ann.transformGeometry('flip_h', 120, 80);
    final line = ann.lines.first;
    expect((line.x, line.y, line.w, line.h), (120 - 50, 40, 20, 10));
    expect(line.orientation, 'vertical'); // 镜像不改方向
  });

  test('flip_v 上下镜像', () {
    final ann = build();
    ann.transformGeometry('flip_v', 120, 80);
    final line = ann.lines.first;
    expect((line.x, line.y, line.w, line.h), (30, 80 - 50, 20, 10));
  });

  test('连续四次顺时针旋转回到原位', () {
    final ann = build();
    // 120x80 --cw--> 80x120 --cw--> 120x80 --cw--> 80x120 --cw--> 120x80
    ann.transformGeometry('rotate_cw', 80, 120);
    ann.transformGeometry('rotate_cw', 120, 80);
    ann.transformGeometry('rotate_cw', 80, 120);
    ann.transformGeometry('rotate_cw', 120, 80);
    final line = ann.lines.first;
    expect((line.x, line.y, line.w, line.h), (30, 40, 20, 10));
    expect(line.orientation, 'vertical');
  });
}
