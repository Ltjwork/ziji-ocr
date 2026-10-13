// 后端失联守卫测试：后端进程退出后，交互请求（实测场景即摆正页预览
// dewarp_page，2026-10-06：凌晨后端控制台被关，应用未重启，预览只剩
// 一句英文 ClientException errno=1225）应抛出中文的
// BackendUnavailableException，且仍是 http.ClientException——识别队列
// 按 ClientException 识别「后端不可达」的长等待分支（见
// backend_unreachable_retry_test.dart）零改动继续生效。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:gujichazi/services/python_service.dart';

void main() {
  test('连接被拒转为中文异常，且保持 ClientException 类型兼容', () async {
    // 一个已关闭的端口：连接立即被拒（与后端未启动/被关闭同型）。
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = server.port;
    await server.close();

    debugSetServiceBase('http://127.0.0.1:$deadPort');
    addTearDown(() => debugSetServiceBase('http://127.0.0.1:1288'));

    // 测试 isolate 从未 start()：失联守卫只转异常，不会真拉后端进程
    //（_scheduleBackendRevive 对 _logServiceDir==null 直接返回）。
    final future = PythonService.dewarpPage(
      imagePath: 'backend_down_guard_test.png',
      corners: const [
        [0.0, 0.0],
        [100.0, 0.0],
        [100.0, 100.0],
        [0.0, 100.0],
      ],
    );
    await expectLater(
      future,
      throwsA(
        isA<BackendUnavailableException>()
            .having(
              (e) => e.toString(),
              '中文指引',
              allOf(contains('后端服务不可达'), isNot(contains('SocketException'))),
            )
            .having(
              (e) => e.toString(),
              '指引重启动作',
              anyOf(contains('自动重启'), contains('重启应用')),
            ),
      ),
    );
    // 队列兼容：必须是 http.ClientException 的子类型（不可达长等待分支
    // 按此类型捕获）。
    expect(BackendUnavailableException('x'), isA<http.ClientException>());
  });
}
