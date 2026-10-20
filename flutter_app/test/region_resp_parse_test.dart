import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';

// 真实响应 fixture（%TEMP% 里由录制会话生成）不在本机时跳过：
// markTestSkipped 在同步回调里不会真正跳过（实测会直接落到下一行
// 抛 PathNotFoundException），用 test 的 skip: 参数才可靠。
final _fixtureMissing = File('${Directory.systemTemp.path}/region_resp.json')
        .existsSync()
    ? false
    : '响应文件不存在（本机无录制 fixture）';

void main() {
  test('真实 /segment_region 响应过 LineBlock.fromJson 不抛', () {
    final f = File('${Directory.systemTemp.path}/region_resp.json');
    final data = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final lines = (data['lines'] as List)
        .map((l) => LineBlock.fromJson(Map<String, dynamic>.from(l as Map)))
        .toList();
    expect(lines, isNotEmpty);
    // 全文对照字段往返
    expect(lines.first.fullText, isNull);
    // 模拟带对照字段的响应
    final withFull = Map<String, dynamic>.from(data['lines'].first);
    withFull['full_text'] = '全文文本，带标点。';
    withFull['full_extras'] = ['，', '。'];
    final line2 = LineBlock.fromJson(withFull);
    expect(line2.fullText, '全文文本，带标点。');
    expect(line2.fullExtras, ['，', '。']);
    // null 值显式出现也不抛
    withFull['full_text'] = null;
    withFull['full_extras'] = null;
    withFull['full_diff'] = null;
    final line3 = LineBlock.fromJson(withFull);
    expect(line3.fullText, isNull);
    final charJson = Map<String, dynamic>.from(
      (withFull['chars'] as List).first as Map,
    );
    charJson['full_diff'] = null;
    final char3 = CharBlock.fromJson(charJson);
    expect(char3.fullDiff, isFalse);
  }, skip: _fixtureMissing);
}
