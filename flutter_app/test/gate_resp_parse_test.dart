import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';

void main() {
  test('带 gate_regions 的真实响应：main_regions 带回退 id 解析通过', () {
    final f = File('${Directory.systemTemp.path}/segment_gate.json');
    if (!f.existsSync()) markTestSkipped('响应文件不存在');
    final data = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final mr = (data['main_regions'] as List? ?? [])
        .map((r) => MainRegion.fromJson(Map<String, dynamic>.from(r as Map)))
        .toList();
    // ignore: avoid_print
    print('main_regions: ${mr.length}, ids: ${mr.map((r) => r.id).toList()}');
    expect(mr, hasLength(2));
    // 后端补的 mr_gate_NNN id 或客户端回退 id，都不为空
    for (final r in mr) {
      expect(r.id, isNotEmpty);
    }
  });
}
