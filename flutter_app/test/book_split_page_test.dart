import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/pages/book_split_page.dart';
import 'package:path/path.dart' as p;

/// 跨页拆分设置页冒烟测试：真实小图上完成叠加合成与控件交互
/// （中缝比例显示、页序切换、微调按钮），不触碰识别服务。
void main() {
  late Directory tempDir;
  late Directory projectDir;
  late Project project;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('split_page_test');
    projectDir = Directory(p.join(tempDir.path, 'proj'));
    await projectDir.create(recursive: true);
    // 两张 100x80 的跨页图，走真实解码/合成链路。
    for (var i = 0; i < 2; i++) {
      final file = File(p.join(projectDir.path, 'page_00$i.png'));
      await file.writeAsBytes(_pngBytes(100, 80));
    }
    project = Project(
      id: 't1',
      name: '书',
      projectDir: projectDir.path,
      imageFiles: [
        p.join(projectDir.path, 'page_000.png'),
        p.join(projectDir.path, 'page_001.png'),
      ],
    );
  });

  tearDownAll(() async {
    // 图像解码器可能仍持有文件句柄，删不掉就留着（系统临时目录）。
    try {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  testWidgets('叠加合成后显示中缝比例，切换页序/微调正常', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: BookSplitPage(project: project)),
    );
    // 合成是真实异步 IO（文件读取 + 解码）：testWidgets 的假时间不走
    // 真实 IO，用 runAsync 分批等待真实完成，再泵帧让 setState 落地。
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    // 底栏显示默认中缝 50.0% 与页序分段控件；顶栏叠加了全部 2 页。
    expect(find.textContaining('中缝 50.0%'), findsOneWidget);
    expect(find.text('先左后右'), findsOneWidget);
    expect(find.text('先右后左'), findsOneWidget);
    expect(find.text('拆分并应用'), findsOneWidget);
    expect(find.textContaining('叠加 2 / 2 页'), findsOneWidget);

    // 切换页序（先左后右）：状态切换不抛异常，中缝显示仍在。
    await tester.tap(find.text('先左后右'));
    await tester.pump();
    expect(find.textContaining('中缝 50.0%'), findsOneWidget);

    // 微调按钮按页宽像素挪动中缝并同步显示（页宽 100px）。
    await tester.tap(find.byTooltip('右移 10px'));
    await tester.pump();
    expect(find.textContaining('中缝 60.0%'), findsOneWidget);
    await tester.tap(find.byTooltip('左移 1px'));
    await tester.pump();
    expect(find.textContaining('中缝 59.0%'), findsOneWidget);
  });
}

/// 生成一张有效的 PNG（w×h 纯色 RGB）：手工组 PNG 结构
/// （签名 + IHDR + zlib store 的 IDAT + IEND），不引入编码依赖。
List<int> _pngBytes(int w, int h) {
  final bytes = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

  List<int> u32(int v) => [
    (v >> 24) & 0xFF,
    (v >> 16) & 0xFF,
    (v >> 8) & 0xFF,
    v & 0xFF,
  ];

  List<int> chunk(String type, List<int> data) {
    final out = [...u32(data.length), ...type.codeUnits, ...data];
    final crc = _crc32([...type.codeUnits, ...data]);
    return [...out, ...u32(crc)];
  }

  // IHDR: width, height, bit depth 8, color type 2 (RGB)
  final ihdr = [...u32(w), ...u32(h), 8, 2, 0, 0, 0];
  // IDAT: 每行 filter 0 + RGB 像素，zlib store 块（无压缩）
  final raw = <int>[];
  for (var y = 0; y < h; y++) {
    raw.add(0);
    for (var x = 0; x < w; x++) {
      raw.addAll([0x77, 0x66, 0x55]);
    }
  }
  final adler = _adler32(raw);
  final stored = <int>[
    0x78, 0x01, // zlib header
    0x01, // final store block
    raw.length & 0xFF,
    (raw.length >> 8) & 0xFF,
    (~raw.length) & 0xFF,
    ((~raw.length) >> 8) & 0xFF,
    ...raw,
    ...u32(adler),
  ];
  bytes.addAll(chunk('IHDR', ihdr));
  bytes.addAll(chunk('IDAT', stored));
  bytes.addAll(chunk('IEND', const []));
  return bytes;
}

int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final b in data) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc >> 1) ^ (0xEDB88320 & (-(crc & 1)));
    }
  }
  return (~crc) & 0xFFFFFFFF;
}

int _adler32(List<int> data) {
  var a = 1, b = 0;
  for (final byte in data) {
    a = (a + byte) % 65521;
    b = (b + a) % 65521;
  }
  return (b << 16) | a;
}
