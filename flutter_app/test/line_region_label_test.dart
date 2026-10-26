// det 定行的版面类型（region_label）：页眉/页脚/页码行在客户端的
// 解析、落盘往返与配色语义。
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';

Map<String, dynamic> _lineJson(Map<String, dynamic> extra) => {
      'id': 'det_l_000',
      'x': 10,
      'y': 20,
      'w': 30,
      'h': 40,
      'line_no': 0,
      ...extra,
    };

void main() {
  group('LineBlock.regionLabel', () {
    test('det 回包带类型 → 解析落位，缺省正文行为空', () {
      final typed = LineBlock.fromJson(_lineJson({
        'region_label': 'page_number',
        'layout_role': 'annotation',
      }));
      expect(typed.regionLabel, 'page_number');
      expect(typed.layoutRole, 'annotation');

      final plain = LineBlock.fromJson(_lineJson({}));
      expect(plain.regionLabel, '');
      expect(plain.layoutRole, 'body');
    });

    test('落盘往返保留类型（空类型不写入 JSON）', () {
      final typed = LineBlock.fromJson(_lineJson({'region_label': 'footer'}));
      final out = typed.toJson();
      expect(out['region_label'], 'footer');
      final back = LineBlock.fromJson(out);
      expect(back.regionLabel, 'footer');

      final plain = LineBlock.fromJson(_lineJson({}));
      expect(plain.toJson().containsKey('region_label'), isFalse);
    });

    test('类型行配色与区域视图同源（词表外归正文）', () {
      // 行视图按 RegionLabel 配色画类型框：页眉蓝、页脚蓝灰、页码绿、
      // 眉批黄棕；正文/未知类型不参与类型配色（保持 indigo）。
      // 页眉曾为青色（0xFF0097A7），与段视图段落框 teal 几乎同色，改蓝。
      expect(RegionLabel.color(RegionLabel.normalize('header')),
          const Color(0xFF1976D2));
      expect(RegionLabel.color(RegionLabel.normalize('page_number')),
          const Color(0xFF2E7D32));
      expect(RegionLabel.normalize('nonsense'), RegionLabel.mainText);
      expect(RegionLabel.displayName('footer'), '页脚');
    });
  });
}
