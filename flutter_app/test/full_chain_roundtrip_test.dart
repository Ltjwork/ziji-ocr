import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';

// 真实响应 fixture（%TEMP% 里由录制会话生成）不在本机时跳过：
// markTestSkipped 在同步回调里不会真正跳过（实测会直接落到下一行
// 抛 PathNotFoundException），用 test 的 skip: 参数才可靠。
final _fixtureMissing = File('${Directory.systemTemp.path}/segment_resp2.json')
        .existsSync()
    ? false
    : '响应文件不存在（本机无录制 fixture）';

void main() {
  test('真实响应 → PageAnnotation → inferHierarchy → rebuildBlocks → 存取往返', () {
    final f = File('${Directory.systemTemp.path}/segment_resp2.json');
    final data = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final lines = (data['lines'] as List)
        .map((l) => LineBlock.fromJson(Map<String, dynamic>.from(l as Map)))
        .toList();
    final blocks = (data['blocks'] as List)
        .map((b) => CharBlock.fromJson(b as Map<String, dynamic>))
        .toList();
    final regions = ((data['main_regions'] as List?) ?? [])
        .map((r) => MainRegion.fromJson(Map<String, dynamic>.from(r as Map)))
        .toList();
    final paragraphs = ((data['paragraphs'] as List?) ?? [])
        .map((p) => Paragraph.fromJson(Map<String, dynamic>.from(p as Map)))
        .toList();
    final ann = PageAnnotation(
      pageId: 'page_005',
      imagePath: 'x.png',
      mainRegions: regions,
      paragraphs: paragraphs,
      lines: lines,
      blocks: blocks,
      sourceImageWidth: data['image_width'] as int? ?? 0,
      sourceImageHeight: data['image_height'] as int? ?? 0,
    );
    ann.inferHierarchy(
      orientation: 'vertical',
      horizontalDir: 'rtl',
      verticalDir: 'ttb',
    );
    ann.rebuildBlocks();
    // 存取往返（识别完成即机器落盘）
    final json2 = jsonEncode(ann.toJson());
    final ann2 = PageAnnotation.fromJson(
      jsonDecode(json2) as Map<String, dynamic>,
    );
    expect(ann2.lines, hasLength(lines.length));
    // 对照字段往返保留
    final diffCount = ann2.blocks.where((c) => c.fullDiff == true).length;
    expect(diffCount, 18);
  }, skip: _fixtureMissing);
}
