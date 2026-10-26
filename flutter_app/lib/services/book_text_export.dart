import 'dart:convert';

import 'package:archive/archive.dart';

import '../models/models.dart';
import '../models/table_block.dart';
import 'reading_order.dart';
import 'storage.dart';

/// 全文导出格式（编辑器「导出 → 导出全文」）。
enum TextExportFormat {
  md('Markdown', 'md'),
  txt('纯文本', 'txt'),
  docx('Word 文档', 'docx');

  final String label;
  final String ext;
  const TextExportFormat(this.label, this.ext);
}

/// 导出全文中的一个段落块：自然段内的行合并成连续文本；未归属段落的
/// 连续散行合并成一个散行块（paragraphId 为空）；表格块（table 非空）
/// 按原表结构电子化——txt/md 用 TableExport 的表格文本渲染，docx 输出
/// 真实表格（含合并格与几何列宽），text 恒为纯文本渲染兜底。
class TextBlock {
  final String pageId;
  final String paragraphId;
  final String text;

  /// 表格块时非空：原表标注（行列/合并格/格内文字）。
  final TableAnnotation? table;

  /// 表格块的列显示序（竖排 rtl 页面按阅读序列从右往左摆）。
  final bool rtlCols;

  const TextBlock({
    required this.pageId,
    required this.paragraphId,
    required this.text,
    this.table,
    this.rtlCols = false,
  });
}

/// 整本书全文构建结果与统计。
class BookTextResult {
  final List<TextBlock> blocks;
  final int exportedPages; // 有正文进入导出的页数
  final int skippedPages; // 无标注/标注错配/无正文行的页数
  const BookTextResult({
    required this.blocks,
    required this.exportedPages,
    required this.skippedPages,
  });

  bool get isEmpty => blocks.isEmpty;
}

/// 整本书全文导出：按页序把校对标注拼成「按自然段断行」的全文，
/// 输出 Markdown / 纯文本 / Word 三种格式。
///
/// 断行规则：同一自然段内的行直接拼接（不断行）；未归属段落的连续
/// 散行合并成一个散行块；段与段之间换行（可选空一行）。
/// regionLabel 非空的行（页眉/页脚/页码/边注等非正文行）不导出。
class BookTextExporter {
  final Project project;
  BookTextExporter(this.project);

  /// 按页序遍历整本书，构建全部文本块。标注缺失/错配（expectedImagePath
  /// 守卫丢弃）或无正文行的页跳过并计入 [BookTextResult.skippedPages]，
  /// 不要求「确认并保存」——校对到一半也能导出当前成果。
  Future<BookTextResult> build() async {
    final blocks = <TextBlock>[];
    var exportedPages = 0;
    var skippedPages = 0;
    for (var i = 0; i < project.imageFiles.length; i++) {
      final pageId = project.pageIdAt(i);
      final ann = await ProjectStorage.loadAnnotation(
        project.projectDir,
        pageId,
        expectedImagePath: project.imageFiles[i],
      );
      final pageBlocks = ann == null
          ? const <TextBlock>[]
          : blocksForPage(
              ann,
              orientation: project.effectiveOrientationAt(i),
              horizontalDir: project.settings.horizontalDir,
              verticalDir: project.settings.verticalDir,
            );
      if (pageBlocks.isEmpty) {
        skippedPages++;
      } else {
        exportedPages++;
        blocks.addAll(pageBlocks);
      }
    }
    return BookTextResult(
      blocks: blocks,
      exportedPages: exportedPages,
      skippedPages: skippedPages,
    );
  }

  /// 单页分块。与 YoloExporter 同款兜底：先推断层级（仅列表为空时填充，
  /// 补上旧标注缺失的段落划分），再取阅读序列（只读，不改动标注），
  /// 然后按 paragraphId 做连续游程分块。空文本行跳过但不断开所在段。
  ///
  /// 表格块按几何阅读位插入：表格作为一个整体阅读单元，排在阅读方向
  /// 上先于它的行之后、晚于它的行之前（竖排列序 + 列内行序，横排行序
  /// + 行内列序，方向跟随页面设置）——与正文一起按原版面顺序电子化。
  static List<TextBlock> blocksForPage(
    PageAnnotation ann, {
    String orientation = 'vertical',
    String horizontalDir = 'ltr',
    String verticalDir = 'ttb',
  }) {
    ann.inferHierarchy(
      orientation: orientation,
      horizontalDir: horizontalDir,
      verticalDir: verticalDir,
    );
    final ordered = ReadingOrderCalculator.readingSequence(
      ann.lines,
      paragraphs: ann.paragraphs,
      orientation: orientation,
      horizontalDir: horizontalDir,
      verticalDir: verticalDir,
    );
    final rtlCols =
        orientation == 'vertical' && horizontalDir == 'rtl';
    final tables = [
      for (final t in ann.tables)
        if (t.status != AnnotationStatus.rejected && t.cells.isNotEmpty) t,
    ];
    // 同页多表先按阅读序自排（标注里的表序是创建序，不是版面序）。
    tables.sort((a, b) {
      if (_rectBefore(a.x, a.y, a.w, a.h, b.x, b.y, b.w, b.h,
          orientation, horizontalDir, verticalDir)) {
        return -1;
      }
      if (_rectBefore(b.x, b.y, b.w, b.h, a.x, a.y, a.w, a.h,
          orientation, horizontalDir, verticalDir)) {
        return 1;
      }
      return 0;
    });
    final blocks = <TextBlock>[];
    String? currentPara;
    final buf = StringBuffer();
    void flush() {
      if (buf.isNotEmpty) {
        blocks.add(TextBlock(
          pageId: ann.pageId,
          paragraphId: currentPara ?? '',
          text: buf.toString(),
        ));
        buf.clear();
      }
    }

    var tableIdx = 0;
    for (final line in ordered) {
      // 表格插入点：还没摆的表格里，第一张在阅读序上先于当前行的，
      // 连同此前所有先于它的表格一起落到当前行前面。
      while (tableIdx < tables.length &&
          _tableBeforeLine(
            tables[tableIdx], line,
            orientation: orientation,
            horizontalDir: horizontalDir,
            verticalDir: verticalDir,
          )) {
        flush();
        final t = tables[tableIdx++];
        blocks.add(TextBlock(
          pageId: ann.pageId,
          paragraphId: '',
          text: TableExport.toTSV(t, rtlCols: rtlCols, rowNumbers: false),
          table: t,
          rtlCols: rtlCols,
        ));
      }
      if (line.regionLabel.isNotEmpty) continue; // 页眉/页脚/页码/边注
      if (line.text.trim().isEmpty) continue;
      final para = line.paragraphId;
      if (currentPara == null) {
        currentPara = para;
      } else if (para != currentPara) {
        flush();
        currentPara = para;
      }
      buf.write(line.text);
    }
    flush();
    // 阅读序上晚于所有行的表格（页尾表格 / 整页只有表格）接在末尾。
    for (; tableIdx < tables.length; tableIdx++) {
      final t = tables[tableIdx];
      blocks.add(TextBlock(
        pageId: ann.pageId,
        paragraphId: '',
        text: TableExport.toTSV(t, rtlCols: rtlCols, rowNumbers: false),
        table: t,
        rtlCols: rtlCols,
      ));
    }
    return blocks;
  }

  /// 表格 [t] 是否在阅读序上先于 [line]：与阅读序计算同向的几何判定——
  /// 竖排按列序（horizontalDir）为主、列内按行序（verticalDir）；横排
  /// 按行序为主、行内按列序。跨在表格列带上的行按另一轴上下（左右）
  /// 分先后。
  static bool _tableBeforeLine(
    TableAnnotation t,
    LineBlock line, {
    required String orientation,
    required String horizontalDir,
    required String verticalDir,
  }) =>
      _rectBefore(
        t.x, t.y, t.w, t.h,
        line.x, line.y, line.w, line.h,
        orientation, horizontalDir, verticalDir,
      );

  /// 矩形 a 是否在阅读序上先于矩形 b（表格插入点/表序共用的几何判定）。
  static bool _rectBefore(
    int ax, int ay, int aw, int ah,
    int bx, int by, int bw, int bh,
    String orientation,
    String horizontalDir,
    String verticalDir,
  ) {
    final acx = ax + aw / 2;
    final acy = ay + ah / 2;
    bool colAxis() {
      final rtl = horizontalDir == 'rtl';
      // 阅读方向上整列先于另一框（竖排 rtl：a 中心列在 b 右侧）
      if (rtl ? acx > bx + bw : acx < bx) return true;
      if (rtl ? acx < bx : acx > bx + bw) return false;
      // 同列带（x 跨距重叠）：按列内行序分先后
      return verticalDir == 'ttb' ? acy < by : acy > by + bh;
    }

    bool rowAxis() {
      final btt = verticalDir == 'btt';
      if (btt ? acy > by + bh : acy < by) return true;
      if (btt ? acy < by : acy > by + bh) return false;
      return horizontalDir == 'rtl' ? acx > bx + bw : acx < bx;
    }

    return orientation == 'horizontal' ? rowAxis() : colAxis();
  }

  /// 段块 → 纯文本（txt 与 Markdown 同构）：段间空一行（[blankLineBetween]）
  /// 或直接换行，文件末尾补一个换行。表格块按 [format] 渲染：txt 为
  /// 行内制表符分隔（可直接粘贴进表格软件），Markdown 为表格语法。
  static String toPlainText(
    List<TextBlock> blocks, {
    required bool blankLineBetween,
    TextExportFormat format = TextExportFormat.txt,
  }) {
    if (blocks.isEmpty) return '';
    final sep = blankLineBetween ? '\n\n' : '\n';
    String render(TextBlock b) {
      final t = b.table;
      if (t == null) return b.text;
      return format == TextExportFormat.md
          ? TableExport.toMarkdown(t, rtlCols: b.rtlCols, rowNumbers: false)
          : b.text;
    }

    return '${blocks.map(render).join(sep)}\n';
  }

  /// 段块 → .docx 字节（最小 OOXML：无样式依赖，中文字体宋体、五号、
  /// 段后间距 0，段间空一行用空段落表达——空行开关在三种格式里行为一致）。
  /// 表格块输出真实 Word 表格：单元矩阵 + 合并格（gridSpan/vMerge）、
  /// 列宽按原表几何比例、竖排格文字竖排——原表布局在电子文档里保形。
  static List<int> toDocx(
    List<TextBlock> blocks, {
    required bool blankLineBetween,
  }) {
    final body = StringBuffer();
    for (var i = 0; i < blocks.length; i++) {
      if (i > 0 && blankLineBetween) body.write('<w:p/>');
      final t = blocks[i].table;
      if (t != null) {
        body.write(_docxTable(t, blocks[i].rtlCols));
        // 表格后补一个空段落：Word 里表格紧贴下一内容会被并进末格。
        body.write('<w:p/>');
      } else {
        body.write('<w:p><w:r><w:t xml:space="preserve">'
            '${_xmlEscape(blocks[i].text)}</w:t></w:r></w:p>');
      }
    }
    final document =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<w:document '
        'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        '<w:body>'
        '$body'
        '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
        '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/>'
        '</w:sectPr>'
        '</w:body></w:document>';

    void add(Archive archive, String name, String content) {
      final bytes = utf8.encode(content);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    final archive = Archive();
    add(archive, '[Content_Types].xml',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" '
        'ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/word/document.xml" ContentType='
        '"application/vnd.openxmlformats-officedocument.'
        'wordprocessingml.document.main+xml"/>'
        '<Override PartName="/word/styles.xml" ContentType='
        '"application/vnd.openxmlformats-officedocument.'
        'wordprocessingml.styles+xml"/>'
        '</Types>');
    add(archive, '_rels/.rels',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<Relationships xmlns='
        '"http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/'
        'officeDocument/2006/relationships/officeDocument" '
        'Target="word/document.xml"/>'
        '</Relationships>');
    add(archive, 'word/_rels/document.xml.rels',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<Relationships xmlns='
        '"http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/'
        'officeDocument/2006/relationships/styles" Target="styles.xml"/>'
        '</Relationships>');
    add(archive, 'word/styles.xml',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<w:styles xmlns:w='
        '"http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        '<w:docDefaults>'
        '<w:rPrDefault><w:rPr>'
        '<w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" '
        'w:eastAsia="宋体"/>'
        '<w:sz w:val="21"/><w:szCs w:val="21"/>'
        '</w:rPr></w:rPrDefault>'
        '<w:pPrDefault><w:pPr>'
        '<w:spacing w:before="0" w:after="0" w:line="240" w:lineRule="auto"/>'
        '</w:pPr></w:pPrDefault>'
        '</w:docDefaults>'
        '<w:style w:type="paragraph" w:default="1" w:styleId="Normal">'
        '<w:name w:val="Normal"/></w:style>'
        '</w:styles>');
    add(archive, 'word/document.xml', document);
    return ZipEncoder().encode(archive);
  }

  /// 书名 → 合法文件名（Windows 非法字符替换为下划线）。
  static String safeFileName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return cleaned.isEmpty ? '导出全文' : cleaned;
  }

  static String _xmlEscape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  /// 表格 → OOXML `<w:tbl>`：按 rows×cols 单元矩阵输出，合并格用
  /// gridSpan（跨列）+ vMerge（跨行：起点 restart、被覆盖格 continue）
  /// 表达；列宽取原表 vLines 距离按版心宽等比缩放（无格线数据时等宽），
  /// [rtlCols] 时列按阅读序重排（宽度跟着走）；竖排格设 tbRlVCenter
  /// 竖排文字方向——原表布局在 Word 里保形。
  static String _docxTable(TableAnnotation t, bool rtlCols) {
    if (t.rows <= 0 || t.cols <= 0) return '';
    const contentWidth = 9026; // 版心宽（dxa）：11906 − 页边距 1440×2
    final geoCols = List<int>.generate(t.cols, (i) => i);
    final colOrder = rtlCols ? geoCols.reversed.toList() : geoCols;
    double unitW(int c) => t.vLines.length == t.cols + 1 &&
            t.vLines.last > t.vLines.first
        ? (t.vLines[c + 1] - t.vLines[c]).toDouble()
        : 1.0;
    final totalGeo = geoCols.fold<double>(0, (a, c) => a + unitW(c));
    final colWidths = [
      for (final c in colOrder)
          (unitW(c) / (totalGeo > 0 ? totalGeo : 1) * contentWidth)
              .round()
              .clamp(1, contentWidth),
    ];
    TableCellBlock? cover(int r, int c) {
      for (final b in t.cells) {
        if (r >= b.row && r < b.row + b.rowSpan &&
            c >= b.col && c < b.col + b.colSpan) {
          return b;
        }
      }
      return null;
    }

    String cellXml(TableCellBlock? block, int r, int c) {
      final isOrigin = block != null && r == block.row && c == block.col;
      var width = 0;
      if (block != null && isOrigin) {
        // 起点格宽度 = 跨到的各显示列宽之和（rtl 重排后跟着显示列走）。
        final start = colOrder.indexOf(block.col);
        for (var k = 0; k < block.colSpan; k++) {
          width += colWidths[(start + k).clamp(0, colWidths.length - 1)];
        }
      }
      final pr = StringBuffer();
      if (width > 0) pr.write('<w:tcW w:w="$width" w:type="dxa"/>');
      // 跨列合并：起点与纵向续格都要带 gridSpan（各消耗同样数量的栅格列）。
      if (block != null && block.colSpan > 1) {
        pr.write('<w:gridSpan w:val="${block.colSpan}"/>');
      }
      if (block != null && block.rowSpan > 1) {
        pr.write(
            isOrigin ? '<w:vMerge w:val="restart"/>' : '<w:vMerge/>');
      }
      if (isOrigin && block.orientation == 'vertical') {
        pr.write('<w:textDirection w:val="tbRlVCenter"/>');
      }
      final text = isOrigin ? _xmlEscape(block.text) : '';
      return '<w:tc><w:tcPr>$pr</w:tcPr>'
          '<w:p>${text.isEmpty ? '' : '<w:r><w:t xml:space="preserve">$text</w:t></w:r>'}</w:p></w:tc>';
    }

    final buf = StringBuffer();
    const border =
        '<w:top w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
        '<w:left w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
        '<w:bottom w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
        '<w:right w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
        '<w:insideH w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
        '<w:insideV w:val="single" w:sz="4" w:space="0" w:color="auto"/>';
    buf.write(
      '<w:tbl><w:tblPr><w:tblW w:w="$contentWidth" w:type="dxa"/>'
      '<w:tblBorders>$border</w:tblBorders></w:tblPr>'
      '<w:tblGrid>${colWidths.map((w) => '<w:gridCol w:w="$w"/>').join()}</w:tblGrid>',
    );
    for (var r = 0; r < t.rows; r++) {
      buf.write('<w:tr>');
      for (final c in colOrder) {
        final block = cover(r, c);
        // 跨列合并中被起点格 gridSpan 吞掉的单元不单独输出 <w:tc>，
        // 否则该行会多出栅格列；纵向续格（r > block.row）仍要输出
        // vMerge continue 空格。
        if (block != null && c != block.col) continue;
        buf.write(cellXml(block, r, c));
      }
      buf.write('</w:tr>');
    }
    buf.write('</w:tbl>');
    return buf.toString();
  }
}
