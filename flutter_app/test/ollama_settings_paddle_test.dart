import 'package:flutter_test/flutter_test.dart';

import 'package:gujichazi/services/ollama_service.dart';

/// OllamaSettings 的 PaddleOCR 默认模型档（1.0.0+180：设置页
/// 「PaddleOCR 模型」卡的选择落点，新建任务取此快照）。
void main() {
  group('OllamaSettings.paddleModel', () {
    test('默认为 small 蒸馏档', () {
      expect(const OllamaSettings().paddleModel, 'PP-OCRv6_small_rec');
    });

    test('fromJson 读回所选档，未知值归一默认', () {
      final s = OllamaSettings.fromJson(const {
        'paddle_model': 'PP-OCRv6_medium_rec',
      });
      expect(s.paddleModel, 'PP-OCRv6_medium_rec');

      final bad = OllamaSettings.fromJson(const {'paddle_model': 'v9'});
      expect(bad.paddleModel, 'PP-OCRv6_small_rec');

      final legacy = OllamaSettings.fromJson(const {});
      expect(legacy.paddleModel, 'PP-OCRv6_small_rec');
    });

    test('toJson 往返保留所选档', () {
      final s = const OllamaSettings().copyWith(
        paddleModel: 'PP-OCRv6_tiny_rec',
      );
      expect(s.toJson()['paddle_model'], 'PP-OCRv6_tiny_rec');
      final back = OllamaSettings.fromJson(s.toJson());
      expect(back.paddleModel, 'PP-OCRv6_tiny_rec');
    });

    test('copyWith 不传时保持原值，传入未知值归一默认', () {
      final s = const OllamaSettings().copyWith(paddleModel: 'PP-OCRv6_medium_rec');
      expect(s.copyWith().paddleModel, 'PP-OCRv6_medium_rec');
      expect(
        s.copyWith(paddleModel: 'garbage').paddleModel,
        'PP-OCRv6_small_rec',
      );
    });
  });
}
