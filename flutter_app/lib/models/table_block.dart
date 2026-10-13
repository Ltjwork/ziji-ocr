/// 表格标注模型（+83 表格识别）。
///
/// TableAnnotation 挂在 PageAnnotation.tables 上：一次「识别表格」的
/// 结果（格线网格 + 每格文字），由 python_service /recognize_table 产
/// 出、人工在表格校对页修正后落盘。几何坐标为全图绝对像素 x/y/w/h
/// （与其余标注层同口径）；h_lines/v_lines 是分割线中心坐标（含边框，
/// 长度 = rows+1 / cols+1），供校对页画网格背景。
///
/// 行列语义在页面旋转时转置（见 [transform]），与
/// PageAnnotation.transformGeometry 的像素映射逐点一致。
library;

import 'models.dart';

/// 单元格内的识别证据（一个字框 + 逐字读法与置信度）。
class TableCellChar {
  int x, y, w, h;
  String text;
  double conf;

  TableCellChar({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.text,
    this.conf = 0,
  });

  factory TableCellChar.fromJson(Map<String, dynamic> j) => TableCellChar(
        x: j['x'] as int,
        y: j['y'] as int,
        w: j['w'] as int,
        h: j['h'] as int,
        text: j['text'] as String? ?? '',
        conf: (j['conf'] as num?)?.toDouble() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'x': x,
        'y': y,
        'w': w,
        'h': h,
        'text': text,
        'conf': conf,
      };
}

/// 逻辑单元格（合并格是 row_span×col_span 的块，row/col 为块左上单元）。
class TableCellBlock {
  int x, y, w, h;
  int row, col, rowSpan, colSpan;
  String text;

  /// 格内文字方向（竖排/横排，识别时按格几何自动判定，校对页据此
  /// 决定文字横排/竖排显示）。
  String orientation;
  List<TableCellChar> chars;
  String status;
  String uid;

  TableCellBlock({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.row,
    required this.col,
    this.rowSpan = 1,
    this.colSpan = 1,
    this.text = '',
    this.orientation = 'vertical',
    List<TableCellChar>? chars,
    this.status = AnnotationStatus.proposed,
    this.uid = '',
  }) : chars = chars ?? [];

  factory TableCellBlock.fromJson(Map<String, dynamic> j) => TableCellBlock(
        x: j['x'] as int,
        y: j['y'] as int,
        w: j['w'] as int,
        h: j['h'] as int,
        row: j['row'] as int,
        col: j['col'] as int,
        rowSpan: (j['row_span'] as num?)?.toInt() ?? 1,
        colSpan: (j['col_span'] as num?)?.toInt() ?? 1,
        text: j['text'] as String? ?? '',
        orientation: j['orientation'] as String? ?? 'vertical',
        chars: (j['chars'] as List?)
                ?.map((c) => TableCellChar.fromJson(c as Map<String, dynamic>))
                .toList() ??
            const [],
        status: AnnotationStatus.normalize(j['status'] as String?),
        uid: j['uid'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'x': x,
        'y': y,
        'w': w,
        'h': h,
        'row': row,
        'col': col,
        'row_span': rowSpan,
        'col_span': colSpan,
        'text': text,
        'orientation': orientation,
        if (chars.isNotEmpty) 'chars': chars.map((c) => c.toJson()).toList(),
        'status': status,
        if (uid.isNotEmpty) 'uid': uid,
      };
}

/// 一次表格识别的结果（外框 + 网格线 + 单元格列表）。
class TableAnnotation {
  final String id;
  int x, y, w, h;
  int rows, cols;
  List<int> hLines; // 行分割线 y 坐标（含上下边框，长度 rows+1）
  List<int> vLines; // 列分割线 x 坐标（含左右边框，长度 cols+1）
  int lineWidth;
  List<TableCellBlock> cells;

  /// 来源主区 uid（从哪个 table 类版面区发起识别；调框后不再回写，
  /// 仅作溯源）。
  String regionUid;
  String status;
  String uid;

  TableAnnotation({
    required this.id,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.rows,
    required this.cols,
    List<int>? hLines,
    List<int>? vLines,
    this.lineWidth = 2,
    List<TableCellBlock>? cells,
    this.regionUid = '',
    this.status = AnnotationStatus.proposed,
    this.uid = '',
  })  : hLines = hLines ?? const [],
        vLines = vLines ?? const [],
        cells = cells ?? [];

  factory TableAnnotation.fromJson(Map<String, dynamic> j) => TableAnnotation(
        id: j['id'] as String,
        x: j['x'] as int,
        y: j['y'] as int,
        w: j['w'] as int,
        h: j['h'] as int,
        rows: j['rows'] as int,
        cols: j['cols'] as int,
        hLines: (j['h_lines'] as List?)?.cast<int>() ?? const [],
        vLines: (j['v_lines'] as List?)?.cast<int>() ?? const [],
        lineWidth: (j['line_width'] as num?)?.toInt() ?? 2,
        cells: (j['cells'] as List?)
                ?.map((c) => TableCellBlock.fromJson(c as Map<String, dynamic>))
                .toList() ??
            const [],
        regionUid: j['region_uid'] as String? ?? '',
        status: AnnotationStatus.normalize(j['status'] as String?),
        uid: j['uid'] as String? ?? '',
      );

  /// /recognize_table 响应 → TableAnnotation。
  factory TableAnnotation.fromRecognition(
    Map<String, dynamic> j, {
    String id = 'tbl_000',
    String regionUid = '',
  }) =>
      TableAnnotation(
        id: id,
        x: j['x'] as int,
        y: j['y'] as int,
        w: j['w'] as int,
        h: j['h'] as int,
        rows: j['rows'] as int,
        cols: j['cols'] as int,
        hLines: (j['h_lines'] as List?)?.cast<int>() ?? const [],
        vLines: (j['v_lines'] as List?)?.cast<int>() ?? const [],
        lineWidth: (j['line_width'] as num?)?.toInt() ?? 2,
        cells: (j['cells'] as List?)
                ?.map((c) => TableCellBlock.fromJson(c as Map<String, dynamic>))
                .toList() ??
            const [],
        regionUid: regionUid,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'x': x,
        'y': y,
        'w': w,
        'h': h,
        'rows': rows,
        'cols': cols,
        'h_lines': hLines,
        'v_lines': vLines,
        'line_width': lineWidth,
        'cells': cells.map((c) => c.toJson()).toList(),
        'region_uid': regionUid,
        'status': status,
        if (uid.isNotEmpty) 'uid': uid,
      };

  /// 页面旋转/镜像的几何同步（与 PageAnnotation.transformGeometry 同一
  /// 逐点映射）。90° 旋转时表格行列转置：rotate_cw 后原第一行变成最后
  /// 一列，cell 的 (row, col, span) 相应换算；h_lines ↔ v_lines 互换并
  /// 重排（映射后天然有序性可能被浮点/取整打破，统一排序）。
  void transform(String op, int newW, int newH) {
    (int, int, int, int) map(int x, int y, int w, int h) {
      switch (op) {
        case 'rotate_cw':
          return (newW - (y + h), x, h, w);
        case 'rotate_ccw':
          return (y, newH - (x + w), h, w);
        case 'flip_h':
          return (newW - (x + w), y, w, h);
        case 'flip_v':
          return (x, newH - (y + h), w, h);
      }
      return (x, y, w, h);
    }

    final (nx, ny, nw, nh) = map(x, y, w, h);
    x = nx;
    y = ny;
    w = nw;
    h = nh;
    for (final c in cells) {
      final (cx, cy, cw, ch) = map(c.x, c.y, c.w, c.h);
      c.x = cx;
      c.y = cy;
      c.w = cw;
      c.h = ch;
      if (op == 'rotate_cw' || op == 'rotate_ccw') {
        c.orientation = c.orientation == 'horizontal'
            ? 'vertical'
            : 'horizontal';
      }
      for (final ch2 in c.chars) {
        final (px, py, pw, ph) = map(ch2.x, ch2.y, ch2.w, ch2.h);
        ch2.x = px;
        ch2.y = py;
        ch2.w = pw;
        ch2.h = ph;
      }
    }
    final oldHLines = List<int>.of(hLines);
    final oldVLines = List<int>.of(vLines);
    switch (op) {
      case 'rotate_cw':
        // 原 h_line(y) → 新 v_line x = newW - y；原 v_line(x) → 新 h_line y = x
        vLines = oldHLines.map((v) => newW - v).toList()..sort();
        hLines = List<int>.of(oldVLines)..sort();
        for (final c in cells) {
          final (row, col, rs, cs) =
              (c.col, rows - 1 - c.row, c.colSpan, c.rowSpan);
          c
            ..row = row
            ..col = col
            ..rowSpan = rs
            ..colSpan = cs;
        }
      case 'rotate_ccw':
        // 原 h_line(y) → 新 v_line x = y；原 v_line(x) → 新 h_line y = newH - x
        vLines = List<int>.of(oldHLines)..sort();
        hLines = oldVLines.map((v) => newH - v).toList()..sort();
        for (final c in cells) {
          final (row, col, rs, cs) =
              (cols - 1 - c.col, c.row, c.colSpan, c.rowSpan);
          c
            ..row = row
            ..col = col
            ..rowSpan = rs
            ..colSpan = cs;
        }
      case 'flip_h':
        vLines = oldVLines.map((v) => newW - v).toList()..sort();
        for (final c in cells) {
          c.col = cols - 1 - (c.col + c.colSpan - 1);
        }
      case 'flip_v':
        hLines = oldHLines.map((v) => newH - v).toList()..sort();
        for (final c in cells) {
          c.row = rows - 1 - (c.row + c.rowSpan - 1);
        }
    }
    if (op == 'rotate_cw' || op == 'rotate_ccw') {
      final t = rows;
      rows = cols;
      cols = t;
    }
  }
}
