import 'package:flutter_test/flutter_test.dart';

import 'package:gujichazi/models/models.dart';

/// ProjectSettings 的识别引擎字段（1.0.0+180 恢复真实读写并新增
/// paddleModel）：默认 kraken、旧数据兼容、project.json 往返。
void main() {
  group('ProjectSettings.engine/paddleModel', () {
    test('默认为 kraken + small 蒸馏档', () {
      final s = ProjectSettings();
      expect(s.engine, 'kraken');
      expect(s.paddleModel, 'PP-OCRv6_small_rec');
    });

    test('fromJson 读回 paddle 选择（含模型档位）', () {
      final s = ProjectSettings.fromJson(const {
        'orientation': 'vertical',
        'engine': 'paddle',
        'paddle_model': 'PP-OCRv6_medium_rec',
      });
      expect(s.engine, 'paddle');
      expect(s.paddleModel, 'PP-OCRv6_medium_rec');
    });

    test('未知/历史脏值引擎归一为 kraken，不丢其他字段', () {
      // 旧版单引擎时代 project.json 里可能残留任意 engine 值。
      final s = ProjectSettings.fromJson(const {
        'engine': 'baidu',
        'horizontal_dir': 'rtl',
      });
      expect(s.engine, 'kraken');
      expect(s.horizontalDir, 'rtl');
    });

    test('缺省字段回落：老 project.json（无 engine/paddle_model）', () {
      final s = ProjectSettings.fromJson(const {'orientation': 'horizontal'});
      expect(s.engine, 'kraken');
      expect(s.paddleModel, 'PP-OCRv6_small_rec');
      expect(s.orientation, 'horizontal');
    });

    test('toJson 往返保留引擎选择（project.json 字段名 snake_case）', () {
      final s = ProjectSettings(
        engine: 'paddle',
        paddleModel: 'PP-OCRv6_tiny_rec',
      );
      final j = s.toJson();
      expect(j['engine'], 'paddle');
      expect(j['paddle_model'], 'PP-OCRv6_tiny_rec');
      final back = ProjectSettings.fromJson(j);
      expect(back.engine, 'paddle');
      expect(back.paddleModel, 'PP-OCRv6_tiny_rec');
    });

    test('copyWith 只改引擎不动模型，反之亦然', () {
      final s = ProjectSettings();
      expect(s.copyWith(engine: 'paddle').paddleModel, 'PP-OCRv6_small_rec');
      expect(
        s.copyWith(paddleModel: 'PP-OCRv6_medium_rec').engine,
        'kraken',
      );
    });
  });
}
