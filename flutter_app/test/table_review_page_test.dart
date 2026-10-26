/// 表格校对页（左图右表对照）widget 冒烟测试：双栏布局渲染、点格出
/// 详情栏并联动高亮状态、光标前文字对齐不崩、确认按钮状态流转。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/models/table_block.dart';
import 'package:gujichazi/pages/table_review_page.dart';

TableAnnotation _table() {
  final t = TableAnnotation(
    id: 'tbl_001',
    x: 10,
    y: 10,
    w: 300,
    h: 200,
    rows: 2,
    cols: 2,
    hLines: const [10, 110, 210],
    vLines: const [10, 160, 310],
    lineWidth: 2,
  );
  final a = TableCellBlock(
    x: 12, y: 12, w: 146, h: 96, row: 0, col: 0,
    text: '天地', orientation: 'vertical',
  )..chars.addAll([
      TableCellChar(x: 12, y: 12, w: 40, h: 40, text: '天'),
      TableCellChar(x: 12, y: 52, w: 40, h: 40, text: '地'),
    ]);
  final b = TableCellBlock(
    x: 162, y: 12, w: 146, h: 96, row: 0, col: 1, text: '玄黄',
    orientation: 'horizontal',
  );
  final c = TableCellBlock(
    x: 12, y: 112, w: 296, h: 96, row: 1, col: 0, colSpan: 2, text: '合并',
    orientation: 'horizontal',
  );
  t.cells.addAll([a, b, c]);
  return t;
}

Future<void> _pump(
  WidgetTester tester,
  TableAnnotation t, {
  String imagePath = 'not_exists.png',
  ui.Image? image,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: TableReviewPage(
        imagePath: imagePath, // 缺省解码失败走占位路径，不阻塞布局
        table: t,
        settings: ProjectSettings(
          orientation: 'vertical',
          horizontalDir: 'rtl',
        ),
        debugImage: image,
      ),
    ),
  );
  await tester.pump(); // 让 _decodeImage 的异步结果落地
}

TableAnnotation _tallTable() {
  // 细长表：1 列 × 8 行（几何 60×800），旧行高布局会撑成 8×108 的巨幅
  final t = TableAnnotation(
    id: 'tbl_002',
    x: 0,
    y: 0,
    w: 60,
    h: 800,
    rows: 8,
    cols: 1,
    hLines: const [0, 100, 200, 300, 400, 500, 600, 700, 800],
    vLines: const [0, 60],
    lineWidth: 2,
  );
  for (var r = 0; r < 8; r++) {
    t.cells.add(TableCellBlock(
      x: 2,
      y: r * 100 + 2,
      w: 56,
      h: 96,
      row: r,
      col: 0,
      text: '行$r',
      orientation: 'horizontal',
    ));
  }
  return t;
}

void main() {
  testWidgets('左右双栏渲染：原图占位 + 电子化表格文字在场', (tester) async {
    await _pump(tester, _table());
    expect(find.text('原图加载中…'), findsOneWidget); // 左栏占位
    // 竖排格逐字渲染（Wrap 自上而下）：单字 Text 在场
    expect(find.text('天'), findsOneWidget);
    expect(find.text('地'), findsOneWidget);
    expect(find.text('合并'), findsOneWidget); // 合并格（横排缺省）
    expect(find.text('表格校对 2×2 · 0/3 已确认'), findsOneWidget);
  });

  testWidgets('点选格子：详情栏出现、光标置末高亮整格、确认按钮流转', (tester) async {
    final t = _table();
    await _pump(tester, t);
    // 详情栏未开
    expect(find.text('格内文字'), findsNothing);

    await tester.tap(find.text('天'));
    await tester.pump();
    expect(find.text('格内文字'), findsOneWidget);
    // 信息行含行列/方向/高亮说明
    expect(
      find.textContaining('第 1 行 · 第 1 列 · 竖排 · 左图高亮 = 光标前文字'),
      findsOneWidget,
    );

    // 未确认时可点，点击后整格 confirmed（角标变已确认）
    await tester.tap(find.text('确认本格'));
    await tester.pump();
    expect(find.text('已确认'), findsOneWidget);
    expect(t.cells.first.status, AnnotationStatus.confirmed);
  });

  testWidgets('编辑文字改回待确认，选中格信息随选中变化', (tester) async {
    final t = _table();
    await _pump(tester, t);
    // 先确认，再改字 → 退回 proposed
    await tester.tap(find.text('天'));
    await tester.pump();
    await tester.tap(find.text('确认本格'));
    await tester.pump();

    final field = find.byType(TextField);
    await tester.enterText(field, '天元地');
    await tester.pump();
    expect(t.cells.first.text, '天元地');
    expect(t.cells.first.status, AnnotationStatus.proposed);

    // 换选另一格：详情栏信息切换、输入框换内容
    await tester.tap(find.text('玄黄'));
    await tester.pump();
    expect(find.textContaining('第 1 行 · 第 2 列'), findsOneWidget);
  });

  testWidgets('整表按几何比例适配右栏：细长表不再撑成巨幅', (tester) async {
    await _pump(tester, _tallTable());
    final size = tester.getSize(find.byKey(const ValueKey('table_grid_box')));
    // 适配后面板内整表可见（≈面板高 ~520），远小于旧行高布局 8×108=864
    expect(size.height, lessThan(700));
    expect(size.height, greaterThan(300));
    // 纵横比保持原表几何比例（60:800），左右两栏观感一致
    expect(size.width / size.height, closeTo(60 / 800, 0.02));
  });

  testWidgets('识别日志：菜单打开对话框、内容可选中、一键复制到剪贴板', (tester) async {
    // widget 测试里平台剪贴板通道不会自动回包（await 永不完成，测试会
    // 挂到超时）——注册 mock 捕获 setData，断言复制内容。
    var copied = '';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map?)?['text'] as String? ?? '';
        } else if (call.method == 'Clipboard.getData') {
          return <String, Object?>{'text': copied};
        }
        return null;
      },
    );
    final t = _table();
    t.logLines = const [
      '引擎=paddle+PP-OCRv6_small_rec（模型 PP-OCRv6_small_rec） 方向=vertical/rtl/ttb',
      '格(0,0) 146×96 竖排 连通域=2 出格=0 细长滤=0 碎块滤=0 → 字框2',
      '格(0,0) 序列=「天地」(conf.0.91) 框内=「天地」 吻合2/2 → 取序列（语境）',
    ];
    await _pump(tester, t);

    // 打开右上菜单 → 识别日志
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('识别日志（查看/复制）'));
    await tester.pumpAndSettle();

    expect(find.text('识别日志 · tbl_001'), findsOneWidget);
    // 日志内容在场且可选中（SelectableText）
    expect(find.textContaining('引擎=paddle+PP-OCRv6_small_rec'), findsOneWidget);
    expect(find.textContaining('吻合2/2 → 取序列'), findsOneWidget);

    // 一键复制 → mock 捕获到完整日志
    await tester.tap(find.text('复制全部'));
    await tester.pump();
    expect(copied, startsWith('引擎=paddle+'));
    expect(copied, contains('吻合2/2 → 取序列（语境）'));

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('识别日志 · tbl_001'), findsNothing);
  });

  testWidgets('识别日志：无日志时给出提示（旧标注）', (tester) async {
    final t = _table(); // logLines 为空
    await _pump(tester, t);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('识别日志（查看/复制）'));
    await tester.pumpAndSettle();
    expect(find.textContaining('没有识别日志'), findsOneWidget);
    // 复制按钮禁用
    expect(
      tester.widget<TextButton>(find.widgetWithText(TextButton, '复制全部'))
          .enabled,
      isFalse,
    );
  });

  testWidgets('底图叠加默认开、可一键关闭；格内字号与原表字框对齐', (tester) async {
    // widget 测试的 fake-async 里 instantiateImageCodec 不完成，注入
    // 预解码图（Picture.toImage 在 runAsync 的软件渲染下可用）。
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder)
      ..drawRect(
        const Rect.fromLTWH(0, 0, 8, 8),
        Paint()..color = const Color(0xFFFFFFFF),
      );
    final img =
        await tester.runAsync(() => recorder.endRecording().toImage(8, 8));
    expect(img, isNotNull);

    final t = _table();
    // (0,0) 格有字框证据（h=40），(1,0) 合并格无字框 → 兜底字号
    await _pump(tester, t, image: img);
    // 底图画师在场（右侧网格 Stack 的底层）
    expect(find.byKey(const ValueKey('table_underlay')), findsOneWidget);

    // 字号与字框对齐：h=40 的字框在适配比例 s 下的显示高 × 0.9
    // （表 300×200，右栏适配 s = min(paneW/300, paneH/200)）
    final text = tester.widget<Text>(find.text('天'));
    expect(text.style?.fontSize, greaterThan(20));

    // AppBar 开关关闭底图
    await tester.tap(find.byIcon(Icons.layers));
    await tester.pump();
    expect(find.byKey(const ValueKey('table_underlay')), findsNothing);
    expect(find.byIcon(Icons.layers_clear), findsOneWidget);
    // 再开回来
    await tester.tap(find.byIcon(Icons.layers_clear));
    await tester.pump();
    expect(find.byKey(const ValueKey('table_underlay')), findsOneWidget);
  });
}
