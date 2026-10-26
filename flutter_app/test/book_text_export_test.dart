import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/services/book_text_export.dart';

/// 导出全文（BookTextExporter）单元测试：按自然段分块、非正文行排除、
/// txt/md 段间空行拼接、docx 最小 OOXML 结构与 XML 转义、全书遍历统计。
void main() {
  // 占位段（inferHierarchy 只在段列表为空时才自动聚类填充，提供非空段
  // 列表让用例直接控制行的 paragraph_id，与线上已识别页的落盘形态一致）。
  Map<String, dynamic> dummyPara(String id) => {
        'id': id,
        'x': 0,
        'y': 0,
        'w': 10,
        'h': 10,
        'line_ids': const <String>[],
      };

  PageAnnotation ann(
    String pageId,
    String imagePath,
    List<Map<String, dynamic>> lines, {
    List<Map<String, dynamic>> paragraphs = const [],
  }) =>
      PageAnnotation.fromJson({
        'page_id': pageId,
        'image_path': imagePath,
        'schema_version': 2,
        'lines': lines,
        'paragraphs': paragraphs,
      });

  Map<String, dynamic> line(
    String id,
    String text, {
    String paragraphId = '',
    String regionLabel = '',
    int x = 0,
    int y = 0,
  }) =>
      {
        'id': id,
        'x': x,
        'y': y,
        'w': 20,
        'h': 40,
        'line_no': 0,
        'text': text,
        if (paragraphId.isNotEmpty) 'paragraph_id': paragraphId,
        if (regionLabel.isNotEmpty) 'region_label': regionLabel,
      };

  group('blocksForPage 分块', () {
    test('自然段内合并、散行合并、段间断行（横排）', () {
      final a = ann('page_001', 'img.png', [
        line('l1', '床前明月光，', paragraphId: 'p1', y: 0),
        line('l2', '疑是地上霜。', paragraphId: 'p1', y: 50),
        line('l3', '批注散行甲', y: 100),
        line('l4', '批注散行乙', y: 150),
        line('l5', '举头望明月，', paragraphId: 'p2', y: 200),
      ], paragraphs: [dummyPara('p1'), dummyPara('p2')]);

      final blocks = BookTextExporter.blocksForPage(
        a,
        orientation: 'horizontal',
        horizontalDir: 'ltr',
        verticalDir: 'ttb',
      );
      expect(blocks.map((b) => b.text).toList(), [
        '床前明月光，疑是地上霜。',
        '批注散行甲批注散行乙',
        '举头望明月，',
      ]);
      expect(blocks.map((b) => b.paragraphId).toList(), ['p1', '', 'p2']);
    });

    test('页眉/页码等非正文行不导出，空文本行不断段', () {
      final a = ann('page_001', 'img.png', [
        line('h1', '卷之首', regionLabel: 'header', y: -50),
        line('l1', '第一段甲', paragraphId: 'p1', y: 0),
        line('le', '', paragraphId: 'p1', y: 25),
        line('l2', '第一段乙', paragraphId: 'p1', y: 50),
        line('pn', '三', regionLabel: 'page_number', y: 100),
      ], paragraphs: [dummyPara('p1')]);

      final blocks = BookTextExporter.blocksForPage(
        a,
        orientation: 'horizontal',
        horizontalDir: 'ltr',
        verticalDir: 'ttb',
      );
      expect(blocks.map((b) => b.text).toList(), ['第一段甲第一段乙']);
    });

    test('竖排右起跨列同段合并（rtl + ttb）', () {
      final a = ann('page_001', 'img.png', [
        line('l1', '右列甲', paragraphId: 'p1', x: 200, y: 0),
        line('l2', '右列乙', paragraphId: 'p1', x: 200, y: 100),
        line('l3', '左列甲', paragraphId: 'p1', x: 100, y: 0),
        line('l4', '左列乙', paragraphId: 'p2', x: 100, y: 100),
      ], paragraphs: [dummyPara('p1'), dummyPara('p2')]);

      final blocks = BookTextExporter.blocksForPage(
        a,
        orientation: 'vertical',
        horizontalDir: 'rtl',
        verticalDir: 'ttb',
      );
      expect(blocks.map((b) => b.text).toList(), [
        '右列甲右列乙左列甲',
        '左列乙',
      ]);
    });

    test('同段被散行隔开时拆成两块（游程分块）', () {
      final a = ann('page_001', 'img.png', [
        line('l1', '段前半', paragraphId: 'p1', y: 0),
        line('l2', '夹缝散行', y: 50),
        line('l3', '段后半', paragraphId: 'p1', y: 100),
      ], paragraphs: [dummyPara('p1')]);

      final blocks = BookTextExporter.blocksForPage(
        a,
        orientation: 'horizontal',
        horizontalDir: 'ltr',
        verticalDir: 'ttb',
      );
      expect(blocks.map((b) => b.text).toList(), ['段前半', '夹缝散行', '段后半']);
    });
  });

  group('toPlainText 段间空行', () {
    final blocks = [
      const TextBlock(pageId: 'a', paragraphId: 'p1', text: '甲段'),
      const TextBlock(pageId: 'a', paragraphId: 'p2', text: '乙段'),
    ];

    test('默认空一行：段间两个换行，末尾一个换行', () {
      expect(
        BookTextExporter.toPlainText(blocks, blankLineBetween: true),
        '甲段\n\n乙段\n',
      );
    });

    test('关闭空行：段间单个换行', () {
      expect(
        BookTextExporter.toPlainText(blocks, blankLineBetween: false),
        '甲段\n乙段\n',
      );
    });

    test('空块列表输出空串', () {
      expect(BookTextExporter.toPlainText(const [], blankLineBetween: true), '');
    });
  });

  group('toDocx 最小 OOXML', () {
    // archive 4.x：Archive 是 Iterable<ArchiveFile>，按名取条目内容。
    String zipEntry(Archive archive, String name) => utf8
        .decode(archive.files.firstWhere((f) => f.name == name).content);

    test('zip 条目齐全、文本转义、段落数与空段数正确', () {
      final blocks = [
        const TextBlock(pageId: 'a', paragraphId: 'p1', text: '甲段&<续>'),
        const TextBlock(pageId: 'a', paragraphId: 'p2', text: '乙段'),
      ];
      final archive = ZipDecoder().decodeBytes(
        BookTextExporter.toDocx(blocks, blankLineBetween: true),
      );
      expect(
        archive.files.map((f) => f.name).toSet(),
        containsAll([
          '[Content_Types].xml',
          '_rels/.rels',
          'word/document.xml',
          'word/_rels/document.xml.rels',
          'word/styles.xml',
        ]),
      );
      final doc = zipEntry(archive, 'word/document.xml');
      expect(doc, contains('甲段&amp;&lt;续&gt;'));
      expect(doc, isNot(contains('甲段&<')));
      expect('<w:p><w:r>'.allMatches(doc).length, 2); // 每段一个段落
      expect('<w:p/>'.allMatches(doc).length, 1); // 2 段间 1 个空段
      // styles：宋体 eastAsia 与段后间距 0（空一行由空段表达，开关三格式一致）
      final styles = zipEntry(archive, 'word/styles.xml');
      expect(styles, contains('w:eastAsia="宋体"'));
      expect(styles, contains('w:after="0"'));
    });

    test('关闭空行时无空段', () {
      final blocks = [
        const TextBlock(pageId: 'a', paragraphId: 'p1', text: '甲'),
        const TextBlock(pageId: 'a', paragraphId: 'p2', text: '乙'),
      ];
      final doc = zipEntry(
        ZipDecoder()
            .decodeBytes(BookTextExporter.toDocx(blocks, blankLineBetween: false)),
        'word/document.xml',
      );
      expect('<w:p/>'.allMatches(doc).length, 0);
      expect('<w:p><w:r>'.allMatches(doc).length, 2);
    });
  });

  test('safeFileName 清洗 Windows 非法字符', () {
    expect(BookTextExporter.safeFileName('史记/卷一:列传*?'), '史记_卷一_列传__');
    expect(BookTextExporter.safeFileName('  '), '导出全文');
    expect(BookTextExporter.safeFileName('正常书名'), '正常书名');
  });

  test('build 遍历全书并跳过无标注页', () async {
    final dir = await Directory.systemTemp.createTemp('book_text_export');
    addTearDown(() async => dir.delete(recursive: true));
    final img1 = p.join(dir.path, 'page_001.png');
    final img2 = p.join(dir.path, 'page_002.png');
    final project = Project(
      id: 'b1',
      name: '测试/书',
      projectDir: dir.path,
      imageFiles: [img1, img2],
      settings: ProjectSettings(
        orientation: 'horizontal',
        horizontalDir: 'ltr',
        verticalDir: 'ttb',
      ),
    );
    Directory(p.join(dir.path, 'annotations')).createSync(recursive: true);
    final a = ann('page_001', img1, [
      line('l1', '甲', paragraphId: 'p1', y: 0),
      line('l2', '乙', paragraphId: 'p1', y: 50),
    ], paragraphs: [dummyPara('p1')]);
    await File(p.join(dir.path, 'annotations', 'page_001.json'))
        .writeAsString(jsonEncode(a.toJson()));

    final result = await BookTextExporter(project).build();
    expect(result.exportedPages, 1);
    expect(result.skippedPages, 1);
    expect(result.blocks.map((b) => b.text).toList(), ['甲乙']);
    expect(result.blocks.first.pageId, 'page_001');
  });

  group('表格块进全文导出（保留原表布局电子化）', () {
    // 2×3 表：首行三格，次行 (1,0) 起跨 2 列合并格 + (1,2)。
    Map<String, dynamic> tableJson({
      required int x,
      required int y,
      String id = 'tbl_001',
    }) =>
        {
          'id': id,
          'x': x,
          'y': y,
          'w': 300,
          'h': 200,
          'rows': 2,
          'cols': 3,
          'h_lines': [y, y + 100, y + 200],
          'v_lines': [x, x + 100, x + 200, x + 300],
          'line_width': 2,
          'cells': [
            {
              'x': x + 2, 'y': y + 2, 'w': 96, 'h': 96,
              'row': 0, 'col': 0, 'text': '甲',
            },
            {
              'x': x + 102, 'y': y + 2, 'w': 96, 'h': 96,
              'row': 0, 'col': 1, 'text': '乙',
            },
            {
              'x': x + 202, 'y': y + 2, 'w': 96, 'h': 96,
              'row': 0, 'col': 2, 'text': '丙',
            },
            {
              'x': x + 2, 'y': y + 102, 'w': 196, 'h': 96,
              'row': 1, 'col': 0, 'row_span': 1, 'col_span': 2,
              'text': '合并',
            },
            {
              'x': x + 202, 'y': y + 102, 'w': 96, 'h': 96,
              'row': 1, 'col': 2, 'text': '戊',
            },
          ],
        };

    PageAnnotation annWithTable({
      required Map<String, dynamic> table,
      List<Map<String, dynamic>> lines = const [],
    }) =>
        PageAnnotation.fromJson({
          'page_id': 'page_001',
          'image_path': 'img.png',
          'schema_version': 2,
          'lines': lines,
          'tables': [table],
        });

    test('竖排 rtl：表右侧列的行先导出，表格插在阅读序位置', () {
      // rtl：右列（x=500）先读，表在中间（x=100..400），左列（x=0）后读。
      final a = annWithTable(
        table: tableJson(x: 100, y: 50),
        lines: [
          line('l_right', '右列文字', x: 500, y: 0),
          line('l_left', '左列文字', x: 0, y: 0),
        ],
      );
      final blocks = BookTextExporter.blocksForPage(
        a,
        orientation: 'vertical',
        horizontalDir: 'rtl',
        verticalDir: 'ttb',
      );
      expect(blocks.length, 3);
      expect(blocks[0].text, '右列文字');
      expect(blocks[1].table, isNotNull);
      expect(blocks[2].text, '左列文字');
      // rtl 列显示序：丙乙甲（右往左）
      expect(blocks[1].text, contains('丙\t乙\t甲'));
    });

    test('整页只有表格：表格单独成块，不再算"无正文跳过"', () {
      final a = annWithTable(table: tableJson(x: 100, y: 50));
      final blocks = BookTextExporter.blocksForPage(
        a,
        orientation: 'vertical',
        horizontalDir: 'rtl',
        verticalDir: 'ttb',
      );
      expect(blocks.length, 1);
      expect(blocks.single.table, isNotNull);
    });

    test('rejected 表格不导出', () {
      final t = tableJson(x: 100, y: 50)..['status'] = 'rejected';
      final a = annWithTable(table: t);
      expect(
        BookTextExporter.blocksForPage(
          a,
          orientation: 'vertical',
          horizontalDir: 'rtl',
        ),
        isEmpty,
      );
    });

    test('toPlainText：md 渲染表格语法、txt 制表符分隔', () {
      final a = annWithTable(table: tableJson(x: 100, y: 50));
      final blocks = BookTextExporter.blocksForPage(
        a,
        orientation: 'vertical',
        horizontalDir: 'rtl',
      );
      final md = BookTextExporter.toPlainText(
        blocks,
        blankLineBetween: true,
        format: TextExportFormat.md,
      );
      expect(md, startsWith('| 丙 | 乙 | 甲 |'));
      expect(md, contains('| --- | --- | --- |'));
      final txt = BookTextExporter.toPlainText(
        blocks,
        blankLineBetween: true,
        format: TextExportFormat.txt,
      );
      expect(txt, contains('丙\t乙\t甲'));
    });

    test('toDocx：真实表格结构（gridSpan/vMerge/几何列宽/竖排方向）', () {
      final a = annWithTable(table: tableJson(x: 100, y: 50));
      for (final cell in a.tables.first.cells) {
        cell.orientation = 'vertical';
      }
      final blocks = BookTextExporter.blocksForPage(
        a,
        orientation: 'vertical',
        horizontalDir: 'rtl',
      );
      final bytes = BookTextExporter.toDocx(blocks, blankLineBetween: true);
      final archive = ZipDecoder().decodeBytes(bytes);
      final doc = utf8.decode(
        archive.firstWhere((f) => f.name == 'word/document.xml').content,
      );
      expect(doc, contains('<w:tbl>'));
      // 合并格：gridSpan=2；列宽按 vLines 几何等比（每列 100/300 版心）
      expect(doc, contains('<w:gridSpan w:val="2"/>'));
      expect(doc, contains('w:w="3009"')); // 100/300 × 9026 ≈ 3009
      // 竖排格文字方向
      expect(doc, contains('<w:textDirection w:val="tbRlVCenter"/>'));
      // 格内文字在场
      expect(doc, contains('甲'));
      expect(doc, contains('合并'));
    });
  });
}
