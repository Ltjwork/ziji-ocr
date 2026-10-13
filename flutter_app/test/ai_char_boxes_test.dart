/// AI 画框测试解析与命中判定：像素/归一化两种口径、围栏容忍、截断
/// 打捞、角点颠倒互换、越界钳制、退化框丢弃；画布点选命中。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/pages/ai_box_test_page.dart';
import 'package:gujichazi/services/ollama_service.dart';

void main() {
  const pixelMode = AiBoxCoordMode.materialPixel;
  const normMode = AiBoxCoordMode.normalized;
  // 素材图 1152×1536（3000×4000 原图经 maxSide=1536 降采样的典型值）
  const w = 1152, h = 1536;

  group('parseCharBoxes（像素口径）', () {
    test('正常 JSON：按序解析、数值兼容字符串', () {
      final r = OllamaService.parseCharBoxesForTest(
        '{"chars": [{"x1": 100, "y1": 200, "x2": 140, "y2": 240},'
        '{"x1": "150", "y1": "200", "x2": "190", "y2": "240"}]}',
        mode: pixelMode,
        imageWidth: w,
        imageHeight: h,
      );
      expect(r.truncated, isFalse);
      expect(r.boxes, hasLength(2));
      expect(r.boxes[0].x1, 100);
      expect(r.boxes[1].x2, 190);
    });

    test('围栏与废话容忍', () {
      final r = OllamaService.parseCharBoxesForTest(
        '好的，以下是结果：\n```json\n{"chars": [{"x1": 1, "y1": 2, '
        '"x2": 30, "y2": 40}]}\n```',
        mode: pixelMode,
        imageWidth: w,
        imageHeight: h,
      );
      expect(r.boxes, hasLength(1));
      expect(r.truncated, isFalse);
    });

    test('截断打捞：残尾对象丢弃、已闭合的保留、标记截断', () {
      final r = OllamaService.parseCharBoxesForTest(
        '{"chars": [{"x1": 10, "y1": 20, "x2": 50, "y2": 60},'
        '{"x1": 60, "y1": 20, "x2": 100, "y2": 60},'
        '{"x1": 110, "y1": 2',
        mode: pixelMode,
        imageWidth: w,
        imageHeight: h,
      );
      expect(r.truncated, isTrue);
      expect(r.boxes, hasLength(2));
      expect(r.boxes[1].x1, 60);
    });

    test('角点颠倒互换 + 越界钳回图内', () {
      final r = OllamaService.parseCharBoxesForTest(
        '{"chars": [{"x1": 50, "y1": 60, "x2": 10, "y2": 20},'
        '{"x1": -30, "y1": 5, "x2": 9999, "y2": 60}]}',
        mode: pixelMode,
        imageWidth: w,
        imageHeight: h,
      );
      expect(r.boxes[0].x1, 10);
      expect(r.boxes[0].x2, 50);
      expect(r.boxes[1].x1, 0);
      expect(r.boxes[1].x2, w);
    });

    test('退化框（<2px）与非对象条目丢弃', () {
      final r = OllamaService.parseCharBoxesForTest(
        '{"chars": [{"x1": 10, "y1": 10, "x2": 11, "y2": 40},'
        '"oops", {"x1": 10, "y1": 10, "x2": 40, "y2": 40}]}',
        mode: pixelMode,
        imageWidth: w,
        imageHeight: h,
      );
      expect(r.boxes, hasLength(1));
    });

    test('字符串里带花括号/引号的截断残尾不误判闭合', () {
      final r = OllamaService.parseCharBoxesForTest(
        '{"chars": [{"x1": 10, "y1": 10, "x2": 40, "y2": 40},'
        '{"x1": 10, "y1": 10, "x2": 40, "y2": 40, "note": "a\\"b{c"},'
        '{"x1": 5',
        mode: pixelMode,
        imageWidth: w,
        imageHeight: h,
      );
      expect(r.truncated, isTrue);
      expect(r.boxes, hasLength(2));
    });
  });

  group('parseCharBoxes（归一化口径）', () {
    test('xywh 解析 + 钳回 0~1', () {
      final r = OllamaService.parseCharBoxesForTest(
        '{"chars": [{"x": 0.72, "y": 0.05, "w": 0.02, "h": 0.02},'
        '{"x": -0.1, "y": 0.9, "w": 0.5, "h": 0.5}]}',
        mode: normMode,
        imageWidth: w,
        imageHeight: h,
      );
      expect(r.boxes, hasLength(2));
      expect(r.boxes[0].x2, closeTo(0.74, 1e-9));
      expect(r.boxes[1].x1, 0);
      expect(r.boxes[1].y2, closeTo(1.0, 1e-9));
    });

    test('退化框（<0.2% 图）丢弃', () {
      final r = OllamaService.parseCharBoxesForTest(
        '{"chars": [{"x": 0.5, "y": 0.5, "w": 0.001, "h": 0.02}]}',
        mode: normMode,
        imageWidth: w,
        imageHeight: h,
      );
      expect(r.boxes, isEmpty);
    });
  });

  group('hitTestAiBox（画布点选）', () {
    final boxes = [
      const OllamaCharBox(x1: 10, y1: 10, x2: 60, y2: 60),
      const OllamaCharBox(x1: 20, y1: 20, x2: 40, y2: 40), // 与 0 重叠更小
    ];
    test('命中重叠区取面积更小者', () {
      expect(hitTestAiBox(25, 25, boxes), 1);
      expect(hitTestAiBox(12, 12, boxes), 0);
    });
    test('未命中返回 null', () {
      expect(hitTestAiBox(5, 5, boxes), isNull);
      expect(hitTestAiBox(100, 100, boxes), isNull);
    });
  });
}
