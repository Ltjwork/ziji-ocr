/// 表格标注模型测试（+83）：JSON 往返兼容、旋转行列转置、导出格式。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/models/table_block.dart';

TableAnnotation _sampleTable() {
  final t = TableAnnotation(
    id: 'tbl_001',
    x: 100,
    y: 50,
    w: 300,
    h: 200,
    rows: 2,
    cols: 3,
    hLines: const [50, 150, 250],
    vLines: const [100, 200, 300, 400],
    lineWidth: 2,
    regionUid: 'region_abc',
  );
  t.cells.addAll([
    TableCellBlock(
        x: 102, y: 52, w: 96, h: 96, row: 0, col: 0, text: '甲'),
    TableCellBlock(
        x: 202, y: 52, w: 96, h: 96, row: 0, col: 1, text: '乙'),
    TableCellBlock(
        x: 302, y: 52, w: 96, h: 96, row: 0, col: 2, text: '丙'),
    // 合并格：(1,0) 起 2×1
    TableCellBlock(
        x: 102, y: 152, w: 196, h: 96, row: 1, col: 0,
        rowSpan: 1, colSpan: 2, text: '合并'),
    TableCellBlock(
        x: 302, y: 152, w: 96, h: 96, row: 1, col: 2, text: '戊'),
  ]);
  return t;
}

void main() {
  group('TableAnnotation JSON 往返', () {
    test('toJson → fromJson 字段保持（含合并格与字框证据）', () {
      final t = _sampleTable();
      t.cells.first.chars.add(TableCellChar(
        x: 105, y: 55, w: 30, h: 30, text: '甲', conf: 0.97,
      ));
      t.cells.first.status = AnnotationStatus.confirmed;
      final restored = TableAnnotation.fromJson(t.toJson());
      expect(restored.rows, 2);
      expect(restored.cols, 3);
      expect(restored.hLines, [50, 150, 250]);
      expect(restored.vLines, [100, 200, 300, 400]);
      expect(restored.regionUid, 'region_abc');
      expect(restored.cells.length, 5);
      final merged =
          restored.cells.firstWhere((c) => c.colSpan == 2);
      expect((merged.row, merged.col), (1, 0));
      expect(restored.cells.first.text, '甲');
      expect(restored.cells.first.status, AnnotationStatus.confirmed);
      expect(restored.cells.first.chars.single.conf, 0.97);
    });

    test('识别日志 log 字段解析、落盘往返与旧标注兼容', () {
      final t = TableAnnotation.fromRecognition({
        'id': 'tbl_x',
        'x': 1, 'y': 2, 'w': 3, 'h': 4,
        'rows': 2, 'cols': 2,
        'h_lines': [2, 4, 6],
        'v_lines': [1, 3, 5, 7],
        'line_width': 3,
        'cells': [
          {'x': 2, 'y': 3, 'w': 4, 'h': 5, 'row': 0, 'col': 0, 'text': '甲'},
        ],
        'log': [
          '引擎=paddle+PP-OCRv6_small_rec（模型 PP-OCRv6_small_rec）',
          '格(0,0) 序列=「甲」(conf.0.91) 框内=「甲」 吻合1/1 → 取序列（语境）',
        ],
      });
      expect(t.logLines, hasLength(2));
      expect(t.logLines.first, contains('引擎=paddle'));
      // 落盘往返保留（.toJson 带 log，fromJson 读回）
      final restored = TableAnnotation.fromJson(t.toJson());
      expect(restored.logLines, t.logLines);
      // 旧标注无 log 字段 → 空列表不抛
      expect(TableAnnotation.fromJson(_sampleTable().toJson()).logLines,
          isEmpty);
    });

    test('fromRecognition 解析后端响应（snake_case 字段）', () {
      final t = TableAnnotation.fromRecognition({
        'x': 10, 'y': 20, 'w': 100, 'h': 80,
        'rows': 2, 'cols': 2,
        'h_lines': [20, 60, 100],
        'v_lines': [10, 60, 110],
        'line_width': 3,
        'cells': [
          {'x': 12, 'y': 22, 'w': 46, 'h': 36, 'row': 0, 'col': 0,
           'row_span': 1, 'col_span': 1, 'text': '元',
           'orientation': 'vertical',
           'chars': [
             {'x': 12, 'y': 22, 'w': 20, 'h': 20, 'text': '元', 'conf': 0.9},
           ]},
          {'x': 62, 'y': 22, 'w': 46, 'h': 36, 'row': 0, 'col': 1},
          {'x': 12, 'y': 62, 'w': 46, 'h': 36, 'row': 1, 'col': 0},
          {'x': 62, 'y': 62, 'w': 46, 'h': 36, 'row': 1, 'col': 1},
        ],
      }, id: 'tbl_9', regionUid: 'region_x');
      expect(t.id, 'tbl_9');
      expect(t.cells.first.orientation, 'vertical');
      expect(t.cells.first.chars.single.text, '元');
      expect(t.lineWidth, 3);
    });

    test('PageAnnotation 无 tables 字段时读侧缺省空（旧标注兼容）', () {
      final ann = PageAnnotation.fromJson({
        'page_id': 'p1',
        'image_path': 'x.png',
        'main_regions': [
          {'id': 'mr1', 'x': 0, 'y': 0, 'w': 10, 'h': 10},
        ],
        'paragraphs': [],
        'lines': [],
      });
      expect(ann.tables, isEmpty);
      // 回写：无表格时不产生 tables 键
      expect(ann.toJson().containsKey('tables'), isFalse);
    });
  });

  group('旋转几何同步（与 transformGeometry 同映射）', () {
    test('rotate_cw：行列转置、合并格 span 互换、h/v lines 互换', () {
      final t = _sampleTable();
      // 页面 400×300 顺时针转 90° → 300×400
      t.transform('rotate_cw', 300, 400);
      expect(t.rows, 3);
      expect(t.cols, 2);
      // 原 (1,0) 合并格 colSpan=2 → 新格 rowSpan=2
      final merged = t.cells.firstWhere((c) => c.text == '合并');
      expect(merged.rowSpan, 2);
      expect(merged.colSpan, 1);
      // 原 h_lines [50,150,250] → 新 v_lines = 300-y 再升序（线表按
      // 从左到右的自然序存，index i ↔ 第 i 列边界）
      expect(t.vLines, [50, 150, 250]);
      expect(t.hLines, [100, 200, 300, 400]);
      // 原 (0,0) 甲 → 新 (row=0, col=rows-1-0=1)
      final jia = t.cells.firstWhere((c) => c.text == '甲');
      expect((jia.row, jia.col), (0, 1));
    });

    test('flip_h：列镜像，行不变', () {
      final t = _sampleTable();
      t.transform('flip_h', 400, 300);
      expect(t.rows, 2);
      expect(t.cols, 3);
      final jia = t.cells.firstWhere((c) => c.text == '甲');
      // 原 (0,0) → 镜像后 (0, cols-1) = (0,2)
      expect((jia.row, jia.col), (0, 2));
    });
  });

  group('表格文本导出', () {
    test('Markdown：首行表头 + 合并格只写起点', () {
      final md = TableExport.toMarkdown(_sampleTable(), rtlCols: false);
      final lines = md.trim().split('\n');
      expect(lines.first, startsWith('| 行 |'));
      expect(md, contains('甲'));
      expect(md, contains('合并'));
      // 首数据行充当表头（Markdown 表必须有表头，古籍表格首行常是
      // 表头）：表头 + 分隔 + 1 数据行 = 3 行
      expect(lines.length, 3);
    });

    test('TSV：rtl 列序反转', () {
      final t = TableExport.toTSV(_sampleTable(), rtlCols: false);
      final rtl = TableExport.toTSV(_sampleTable(), rtlCols: true);
      final normalCols = t.split('\n').first.split('\t').skip(1).toList();
      final rtlColsList = rtl.split('\n').first.split('\t').skip(1).toList();
      expect(rtlColsList, normalCols.reversed.toList());
    });

    test('rowNumbers=false：全书导出矩阵不带行号列（原表结构）', () {
      final md = TableExport.toMarkdown(
        _sampleTable(),
        rtlCols: false,
        rowNumbers: false,
      );
      final first = md.trim().split('\n').first;
      expect(first, startsWith('| 甲 |'));
      final tsv = TableExport.toTSV(
        _sampleTable(),
        rtlCols: false,
        rowNumbers: false,
      );
      // 每行单元数 = cols（无行号列），合并格被覆盖格留空
      for (final row in tsv.split('\n')) {
        expect(row.split('\t').length, 3);
      }
    });
  });

  group('charsBeforeCursor（对照校对：光标前文字↔字框对齐）', () {
    List<TableCellChar> boxes(List<String> texts) => [
          for (var i = 0; i < texts.length; i++)
            TableCellChar(
              x: i * 10, y: 0, w: 10, h: 10, text: texts[i],
            ),
        ];

    test('文本未改动：光标在第 k 字 → 前 k 个字框', () {
      final chars = boxes(['天', '地', '玄', '黄']);
      final out = charsBeforeCursor('天地玄黄', 3, chars);
      expect(out.map((c) => c.text).toList(), ['天', '地', '玄']);
      // 光标在末尾 → 全部
      expect(charsBeforeCursor('天地玄黄', 4, chars).length, 4);
      // 光标在开头 → 无高亮
      expect(charsBeforeCursor('天地玄黄', 0, chars), isEmpty);
    });

    test('删过一字：跳过被删的框就近对齐', () {
      final chars = boxes(['天', '地', '玄', '黄']);
      // 文本删掉了「地」：光标在「玄」后（第 2 字后）
      final out = charsBeforeCursor('天玄黄', 2, chars);
      expect(out.map((c) => c.text).toList(), ['天', '玄']);
    });

    test('插入过字：插入字符不占框，后续仍对齐', () {
      final chars = boxes(['天', '地', '玄', '黄']);
      // 在「天」「地」之间插入了「元」
      final out = charsBeforeCursor('天元地玄黄', 3, chars);
      expect(out.map((c) => c.text).toList(), ['天', '地']);
    });

    test('边界：空字框/越界光标安全', () {
      expect(charsBeforeCursor('天地', 2, const []), isEmpty);
      expect(charsBeforeCursor('天地', 99, boxes(['天', '地'])).length, 2);
      expect(charsBeforeCursor('', 0, boxes(['天'])), isEmpty);
    });
  });
}
