import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/models/table_block.dart';

/// PageAnnotation / Paragraph 反序列化的**可变性**回归：JSON 缺键时列
/// 表字段必须是可增长列表——统一设置/批量清框/段级联会就地改写这些字
/// 段，const 空列表一改就抛 UnsupportedError（+173「清除未确认页框」
/// 闪退的根因：缺 main_regions 键的页 mainRegions 是 const []）。
void main() {
  Map<String, dynamic> lineJson(String id) => {
    'id': id,
    'x': 1,
    'y': 2,
    'w': 30,
    'h': 300,
    'line_no': 0,
    'chars': [],
  };

  test('fromJson（lines 分支）缺 main_regions/paragraphs/tables 键 → 可增长', () {
    final ann = PageAnnotation.fromJson({
      'page_id': 'p1',
      'image_path': 'p1.png',
      'lines': [lineJson('l1')],
    });
    expect(ann.lines, hasLength(1));
    expect(() {
      ann.mainRegions.add(
        MainRegion(id: 'mr1', x: 0, y: 0, w: 10, h: 10),
      );
      ann.paragraphs.add(
        Paragraph(id: 'pa', x: 0, y: 0, w: 10, h: 10),
      );
      ann.tables.add(
        TableAnnotation(
          id: 't1',
          x: 0,
          y: 0,
          w: 10,
          h: 10,
          rows: 1,
          cols: 1,
        ),
      );
    }, returnsNormally);
  });

  test('fromJson（旧版 blocks-only 分支）同样可增长', () {
    final ann = PageAnnotation.fromJson({
      'page_id': 'p2',
      'image_path': 'p2.png',
    });
    expect(() {
      ann.mainRegions.add(
        MainRegion(id: 'mr1', x: 0, y: 0, w: 10, h: 10),
      );
      ann.paragraphs.add(
        Paragraph(id: 'pa', x: 0, y: 0, w: 10, h: 10),
      );
      ann.tables.add(
        TableAnnotation(
          id: 't1',
          x: 0,
          y: 0,
          w: 10,
          h: 10,
          rows: 1,
          cols: 1,
        ),
      );
    }, returnsNormally);
  });

  test('Paragraph 缺 line_ids 键 → 可增长（级联 removeWhere 不抛）', () {
    final p = Paragraph.fromJson({
      'id': 'pa',
      'x': 0,
      'y': 0,
      'w': 10,
      'h': 10,
    });
    expect(() => p.lineIds.removeWhere((_) => true), returnsNormally);
    expect(() => p.lineIds.add('l1'), returnsNormally);
  });
}
