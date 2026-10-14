import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/services/page_recognition.dart';
import 'package:gujichazi/services/python_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _AllowHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (_, __, ___) => true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _AllowHttpOverrides();

  test('ensurePageAnnotation 全流程（真实 main_text_only 响应 + 假后端）', () async {
    final respFile = File('${Directory.systemTemp.path}/segment_mto.json');
    if (!respFile.existsSync()) markTestSkipped('响应文件不存在');
    final respBody = respFile.readAsStringSync();

    SharedPreferences.setMockInitialValues({});
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((req) async {
      await utf8.decoder.bind(req).drain();
      final resp = req.response;
      resp.statusCode = 200;
      resp.headers.contentType = ContentType.json;
      resp.write(respBody);
      await resp.close();
    });
    addTearDown(() => server.close(force: true));
    debugSetServiceBase('http://127.0.0.1:${server.port}');

    final tmp = await Directory.systemTemp.createTemp('ocr_e2e_');
    addTearDown(() => tmp.delete(recursive: true));
    final project = Project(
      id: 'p1',
      name: '测试书',
      projectDir: tmp.path,
      imageFiles: [
        Platform.environment['ZIJI_E2E_PAGE'] ?? '${Directory.systemTemp.path}/page_005.png',
      ],
      settings: ProjectSettings(
        layoutMode: 'main_text_only',
        orientation: 'vertical',
        horizontalDir: 'rtl',
        verticalDir: 'ttb',
        engine: 'paddle',
        paddleModel: 'PaddleOCR-VL-1.6',
      ),
    );

    final ann = await ensurePageAnnotation(
      project,
      0,
      force: true,
      useCurrentAiSettings: true,
    );
    expect(ann.lines, isNotEmpty);
    expect(ann.blocks, isNotEmpty);
    // 机器落盘真的发生了（saveAnnotation 在返回前执行）。
    final saved = File('${tmp.path}${Platform.pathSeparator}annotations'
        '${Platform.pathSeparator}page_005.json');
    expect(saved.existsSync(), isTrue);
  });
}
