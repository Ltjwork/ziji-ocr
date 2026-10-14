import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';

void main() {
  test('main_regions 条目缺 id（旧后端门控区回显）不抛并生成回退 id', () {
    final region = MainRegion.fromJson({
      'x': 905, 'y': 1591, 'w': 240, 'h': 2554,
      'label': 'footer', 'status': 'confirmed',
      // 故意不带 id / box_confirmed
    });
    expect(region.id, 'mr_gate_905_1591');
    final withId = MainRegion.fromJson({
      'id': 'mr_model_000', 'x': 1, 'y': 2, 'w': 3, 'h': 4,
    });
    expect(withId.id, 'mr_model_000');
    final nullId = MainRegion.fromJson(
      {'x': 5, 'y': 6, 'w': 7, 'h': 8, 'id': null},
    );
    expect(nullId.id, 'mr_gate_5_6');
  });

  test('paragraph 条目缺 id 同样兼容', () {
    final para = Paragraph.fromJson({
      'x': 1, 'y': 2, 'w': 3, 'h': 4, 'main_region_id': null,
      'line_ids': [null, 'l_1'],
    });
    expect(para.id, 'mp_gate_1_2');
    expect(para.lineIds, ['l_1']); // null 元素被过滤
  });
}
