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
  test('真实 /segment 整页响应（paddle+VL 回退+全文对照）完整解析不抛', () {
    final f = File('${Directory.systemTemp.path}/segment_resp2.json');
    final data =
        jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final rawLines = data['lines'] as List?;
    final rawBlocks = data['blocks'] as List;
    final lines = rawLines!
        .map((l) => LineBlock.fromJson(l as Map<String, dynamic>))
        .toList();
    final rawRegions = (data['main_regions'] as List?)
        ?.whereType<Map>()
        .map((r) => MainRegion.fromJson(Map<String, dynamic>.from(r)))
        .toList();
    final rawParagraphs = (data['paragraphs'] as List?)
        ?.whereType<Map>()
        .map((p) => Paragraph.fromJson(Map<String, dynamic>.from(p)))
        .toList();
    final blocks = rawBlocks
        .map((b) => CharBlock.fromJson(b as Map<String, dynamic>))
        .toList();
    final ann = PageAnnotation(
      pageId: 'page_005',
      imagePath: 'x.png',
      mainRegions: rawRegions ?? [],
      paragraphs: rawParagraphs ?? [],
      lines: lines,
      blocks: blocks,
    );
    expect(lines, hasLength(19));
    // 全文对照字段在行/字上正确落位（部分行可能因对照失败无字段）
    final withFullText = ann.lines
        .where((l) => l.fullText != null && l.fullText!.isNotEmpty)
        .length;
    expect(withFullText, greaterThanOrEqualTo(15));
    final diffChars =
        ann.blocks.where((c) => c.fullDiff == true).length;
    expect(diffChars, greaterThan(0));
  }, skip: _fixtureMissing);
}
