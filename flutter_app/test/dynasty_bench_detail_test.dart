// 详情页命中判定（hitTestChar）纯函数测试：图像像素坐标 → 字框索引。
// 重叠取小框、边界含入、缺字段跳过。
import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/pages/dynasty_bench_detail_page.dart';

void main() {
  final lines = <Map<String, dynamic>>[
    {
      'x': 0, 'y': 0, 'w': 100, 'h': 400, 'text': '行一',
      'chars': [
        {'x': 10, 'y': 10, 'w': 80, 'h': 90, 'text': '上', 'conf': 0.9},
        {'x': 10, 'y': 110, 'w': 80, 'h': 90, 'text': '德'},
      ],
    },
    {
      'x': 120, 'y': 0, 'w': 100, 'h': 400, 'text': '行二',
      'chars': [
        // 与行一第 1 字部分重叠的更大框（应命中更小的那个）。
        {'x': 60, 'y': 30, 'w': 100, 'h': 120, 'text': '大'},
      ],
    },
    {
      'x': 240, 'y': 0, 'w': 100, 'h': 400, 'text': '行三',
      'chars': <dynamic>[
        // 非法框（零宽）与缺字段框都应被跳过，不抛异常。
        {'x': 0, 'y': 0, 'w': 0, 'h': 50, 'text': '坏'},
        'not-a-map',
      ],
    },
  ];

  test('命中行一第 1 字（含边界）', () {
    final hit = hitTestChar(50, 55, lines);
    expect(hit, {'lineIndex': 0, 'charIndex': 0});
    // 边界像素也算命中。
    expect(hitTestChar(90, 100, lines), {'lineIndex': 0, 'charIndex': 0});
  });

  test('命中行一第 2 字', () {
    expect(hitTestChar(50, 150, lines), {'lineIndex': 0, 'charIndex': 1});
  });

  test('重叠区域取面积更小的字框', () {
    // (70,60) 同时落在行一第 1 字 (80×90) 与行二大框 (100×120) 内。
    expect(hitTestChar(70, 60, lines), {'lineIndex': 0, 'charIndex': 0});
    // 只落在行二大框内的点命中行二。
    expect(hitTestChar(140, 120, lines), {'lineIndex': 1, 'charIndex': 0});
  });

  test('空白处与非法框返回 null / 不抛异常', () {
    expect(hitTestChar(500, 500, lines), isNull);
    expect(hitTestChar(5, 5, lines), isNull);
    // 行三只有零宽框与非 Map 项。
    expect(hitTestChar(250, 50, lines), isNull);
  });
}
