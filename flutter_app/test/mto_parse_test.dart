import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';

void main() {
  test('main_text_only 真实响应完整解析链（v146）', () {
    final f = File('${Directory.systemTemp.path}/segment_mto.json');
    if (!f.existsSync()) markTestSkipped('响应文件不存在');
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
    final roundTrip = PageAnnotation.fromJson(
      jsonDecode(jsonEncode(ann.toJson())) as Map<String, dynamic>,
    );
    expect(roundTrip.lines, hasLength(lines.length));
  });
}
