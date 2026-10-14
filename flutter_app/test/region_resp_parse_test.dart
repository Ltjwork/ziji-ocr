import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';

void main() {
  test('真实 /segment_region 响应过 LineBlock.fromJson 不抛', () {
    final f = File('${Directory.systemTemp.path}/region_resp.json');
    if (!f.existsSync()) {
      markTestSkipped('region_resp.json 不存在（复现脚本未跑）');
    }
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
  });
}
