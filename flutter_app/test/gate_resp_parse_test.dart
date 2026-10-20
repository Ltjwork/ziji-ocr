import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';

// 真实响应 fixture（%TEMP% 里由录制会话生成）不在本机时跳过：
// markTestSkipped 在同步回调里不会真正跳过（实测会直接落到下一行
// 抛 PathNotFoundException），用 test 的 skip: 参数才可靠。
final _fixtureMissing = File('${Directory.systemTemp.path}/segment_gate.json')
        .existsSync()
    ? false
    : '响应文件不存在（本机无录制 fixture）';

void main() {
  test('带 gate_regions 的真实响应：main_regions 带回退 id 解析通过', () {
    final f = File('${Directory.systemTemp.path}/segment_gate.json');
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
  }, skip: _fixtureMissing);
}
