import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/pages/straighten_batch_page.dart';
import 'package:gujichazi/services/python_service.dart';

/// 批量摆正页的回归冒烟：自动处理（含 showDialog）必须等首帧之后启动，
/// 否则 initState 内触发 dependOnInheritedWidgetOfExactType
/// （_LocalizationsScope）直接抛 FlutterError 崩掉新建任务流程。
void main() {
  // 会话编辑（StraightenPage）进页 initState 加载中键手势配置，测试
  // 环境用内存 mock。
  SharedPreferences.setMockInitialValues({});
  testWidgets('空书进入批量摆正页不崩（initState 不同步 showDialog）', (
    tester,
  ) async {
    final project = Project(
      id: 'straighten_smoke',
      name: '测试书',
      projectDir: 'X:/straighten_smoke_nodisk', // 空书不触达磁盘
      imageFiles: const [],
    );
    await tester.pumpWidget(
      MaterialApp(home: StraightenBatchPage(project: project)),
    );
    // 首帧结束后的 postFrameCallback 才启动 _runAll（含进度对话框）。
    await tester.pump();
    await tester.pumpAndSettle();
    // 进度框自动跑完关闭，页面停在空书态（修复前这里根本走不到——
    // initState 内 showDialog 直接抛 FlutterError）。
    expect(find.text('本书没有页面。'), findsOneWidget);
  });

  testWidgets('多页拼接落账：当前页变合成页、拼入页删除、编辑器自动关闭', (
    tester,
  ) async {
    // ── 场景：两页书，批量自动处理完成后进第 1 页「修改」，拼接面板
    // 确认（拼入第 2 页）→ 第 1 页标记 merged/confirmed/useWarped、
    // 第 2 页文件与列表删除、编辑器无下一页自动退出。
    final tmp = Directory.systemTemp.createTempSync('straighten_stitch');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final p1 = p.join(tmp.path, 'page_0.png');
    final p2 = p.join(tmp.path, 'page_1.png');
    File(p1).writeAsBytesSync(Uint8List.fromList(_pngBytes(200, 300)));
    File(p2).writeAsBytesSync(Uint8List.fromList(_pngBytes(200, 300)));

    // ── 假后端（MockClient，不走真实 socket——testWidgets 的 FakeAsync
    // 区里 HttpClient 被测试框架整体拦截）：记录请求体；detect/dewarp
    // 秒回，stitch preview 回 1×1 PNG、写盘回 out_path。
    final requests = <Map<String, dynamic>>[];
    PythonService.debugHttpClient = MockClient((request) async {
      final path = request.url.path;
      Map<String, dynamic> body = const {};
      if (request.body.isNotEmpty) {
        try {
          body = jsonDecode(request.body) as Map<String, dynamic>;
        } catch (_) {}
      }
      requests.add(body);
      String resp = '{}';
      switch (path) {
        case '/deskew_sizing':
          resp = '{"workers":1,"reason":"test"}';
        case '/detect_page_quad':
          resp = jsonEncode({
            'points': [
              [10, 10],
              [180, 10],
              [180, 290],
              [10, 290],
            ],
            'needs_warp': true,
            'method': 'ink',
          });
        case '/dewarp_page':
          resp = jsonEncode({'w': 100, 'h': 200, 'out_path': ''});
        case '/stitch_pages':
          const trace = {
            'direction': 'v',
            'trim_a': 10,
            'trim_b': 10,
            'offset': 0,
            'offset_auto': true,
            'overlap': 0,
            'overlap_auto': true,
            'align_confidence': 0.9,
            'out_w': 200,
            'out_h': 580,
          };
          if (body['preview'] == true) {
            resp = jsonEncode({'image_b64': _kTinyPngB64, 'trace': trace});
          } else {
            resp = jsonEncode({'out_path': body['out_path'], 'trace': trace});
          }
      }
      return http.Response(resp, 200);
    });
    addTearDown(() => PythonService.debugHttpClient = null);

    /// 真实异步 IO（HTTP/解码/写盘）在 FakeAsync 区不会自己走：真实
    /// 事件循环里等一小段，再泵帧让 setState 落地。
    Future<void> drain(int ms) async {
      await tester.runAsync(
        () => Future<void>.delayed(Duration(milliseconds: ms)),
      );
      // 带时长泵帧：路由动画（对话框开合/编辑器退出）靠时钟推进，
      // pump() 不带时长不前进动画。
      await tester.pump(const Duration(milliseconds: 30));
    }

    final project = Project(
      id: 'stitch_book',
      name: '拼接测试',
      projectDir: tmp.path,
      imageFiles: [p1, p2],
      recognitionStatus: RecognitionStatus.pending,
    );
    await tester.pumpWidget(
      MaterialApp(home: StraightenBatchPage(project: project)),
    );

    // 后台自动处理（detect+dewarp×2 + 状态落盘）跑完：两张卡「已矫正」。
    for (var i = 0; i < 60; i++) {
      await drain(50);
      if (find.text('已矫正').evaluate().length >= 2) break;
    }
    expect(find.text('已矫正').evaluate().length, 2, reason: '自动处理未完成');

    // 进第 1 页「修改」：编辑器载入真实 PNG（解码为真实异步），等载入
    // 完成（拼接按钮可点）再操作。
    await tester.tap(find.text('修改').first);
    for (var i = 0; i < 80; i++) {
      await drain(50);
      if (find.text('拼接').evaluate().isNotEmpty &&
          find.textContaining('正在载入').evaluate().isEmpty) {
        break;
      }
    }
    expect(find.text('拼接'), findsOneWidget);
    expect(find.textContaining('正在载入'), findsNothing);
    await drain(50);

    // 打开拼接面板：默认拼入第 2 页（书序在后 → 本页作前段）、上下拼；
    // 确认前预览请求已发出。
    await tester.tap(find.text('拼接'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // 路由动画
    expect(find.text('多页拼接'), findsOneWidget);
    // 顺序控制：默认「本页在上」，可切换为「拼入页在上」。
    expect(find.text('本页在上'), findsOneWidget);
    expect(find.text('拼入页在上'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600)); // 预览防抖
    await drain(300);
    final previewReq = requests
        .where((r) => r.isNotEmpty && r['image_a'] == p1)
        .last;
    expect(previewReq['preview'], isTrue);
    expect(previewReq['direction'], 'v');
    expect(previewReq['image_b'], p2); // 第 2 页无矫正图 → 原图
    expect(previewReq.containsKey('overlap'), isFalse); // 自动（不传）

    // 确认拼接：写盘请求带 out_path（第 1 页的 warped 路径）。
    await tester.tap(find.text('确认拼接'));
    for (var i = 0; i < 60; i++) {
      await drain(50);
      if (find.text('多页拼接').evaluate().isEmpty) break;
    }
    // 宿主落账 + 编辑器退出（拼掉第 2 页后没有下一页）回到批量网格。
    for (var i = 0; i < 60; i++) {
      await drain(50);
      if (find.text('批量摆正 · 拼接测试').evaluate().isNotEmpty &&
          find.text('确认并下一页').evaluate().isEmpty) {
        break;
      }
    }
    expect(find.text('多页拼接'), findsNothing);
    final writeReq = requests
        .where(
          (r) =>
              r.isNotEmpty &&
              r['image_a'] == p1 &&
              r['preview'] != true,
        )
        .last;
    expect(writeReq['out_path'], p.join(tmp.path, 'warped', 'page_0.png'));

    // ── 落账断言：列表剩 1 页、第 2 页文件删除、状态文件记 merged。
    expect(project.imageFiles.length, 1);
    expect(project.imageFiles.first, p1);
    expect(File(p2).existsSync(), isFalse, reason: '拼入页源图应被删除');
    final stateFile = File(p.join(tmp.path, 'straighten_state.json'));
    expect(stateFile.existsSync(), isTrue);
    final state =
        jsonDecode(stateFile.readAsStringSync()) as Map<String, dynamic>;
    final pages = state['pages'] as Map<String, dynamic>;
    final page1 = pages[p1] as Map<String, dynamic>;
    expect(page1['merged'], isTrue);
    expect(page1['confirmed'], isTrue);
    expect(page1['use_warped'], isTrue);
    expect(pages.containsKey(p2), isFalse);
  });
}

// ── 最小 PNG 构造（与 straighten_page_test 同款：zlib 存储编码）──

const _kTinyPngB64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
    'AAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

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

  final ihdr = [...u32(w), ...u32(h), 8, 2, 0, 0, 0];
  final stride = 1 + w * 3;
  final raw = Uint8List(h * stride);
  for (var y = 0; y < h; y++) {
    final base = y * stride;
    raw[base] = 0;
    for (var x = 0; x < w; x++) {
      final i = base + 1 + x * 3;
      raw[i] = 0xEE;
      raw[i + 1] = 0xE8;
      raw[i + 2] = 0xDC;
    }
  }
  bytes.addAll(chunk('IHDR', ihdr));
  bytes.addAll(chunk('IDAT', _zlibStore(raw)));
  bytes.addAll(chunk('IEND', const []));
  return bytes;
}

List<int> _zlibStore(Uint8List raw) {
  final out = <int>[0x78, 0x01];
  var offset = 0;
  while (offset < raw.length) {
    final n = math.min(65535, raw.length - offset);
    final isLast = offset + n >= raw.length;
    out.add(isLast ? 0x01 : 0x00);
    out.add(n & 0xFF);
    out.add((n >> 8) & 0xFF);
    out.add(~n & 0xFF);
    out.add((~n >> 8) & 0xFF);
    out.addAll(raw.sublist(offset, offset + n));
    offset += n;
  }
  final adler = _adler32(raw);
  out.addAll([
    (adler >> 24) & 0xFF,
    (adler >> 16) & 0xFF,
    (adler >> 8) & 0xFF,
    adler & 0xFF,
  ]);
  return out;
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

int _adler32(Uint8List data) {
  var a = 1, b = 0;
  for (final byte in data) {
    a = (a + byte) % 65521;
    b = (b + a) % 65521;
  }
  return (b << 16) | a;
}
