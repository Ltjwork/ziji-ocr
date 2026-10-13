// 后端不可达（连接被拒）的守门员测试：连接级失败必须走独立的长等待
// 预算，而不是与真实页失败共用 2 次预算把整本书秒判失败——2026-09-29
// 实测：应用重启替换后端的窗口期，队列 6 秒就把书标成识别失败，书卡上
// 只留一句英文 SocketException。这里对一个「已关闭的本地端口」发真实
// 请求，与后端未启动/被关闭时的失败同型（http.ClientException）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/services/python_service.dart';
import 'package:gujichazi/services/recognition_queue.dart';

void main() {
  test('连接被拒按独立预算长等待重试，超预算后给中文指引而非裸异常', () async {
    // 一个已关闭的端口：连接立即被拒（与后端未启动/被关闭同型）。
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = server.port;
    await server.close();

    debugSetServiceBase('http://127.0.0.1:$deadPort');
    final originalDelay = RecognitionQueue.retryDelay;
    final originalUnreachable = RecognitionQueue.unreachableRetryLimit;
    final originalBusy = RecognitionQueue.busyRetryLimit;
    final originalPage = RecognitionQueue.pageRetryLimit;
    final awakeCalls = <bool>[];
    final originalAwake = RecognitionQueue.keepAwakeHook;
    RecognitionQueue.keepAwakeHook = awakeCalls.add;
    addTearDown(() {
      debugSetServiceBase('http://127.0.0.1:1288');
      RecognitionQueue.retryDelay = originalDelay;
      RecognitionQueue.unreachableRetryLimit = originalUnreachable;
      RecognitionQueue.busyRetryLimit = originalBusy;
      RecognitionQueue.pageRetryLimit = originalPage;
      RecognitionQueue.keepAwakeHook = originalAwake;
    });
    // 预算压缩到 3 次、间隔近零：测试能在亚秒内跑完整个重试链路。
    RecognitionQueue.retryDelay = const Duration(milliseconds: 1);
    RecognitionQueue.unreachableRetryLimit = 3;

    final queue = RecognitionQueue.instance;
    final project = Project(
      id: 'unreachable_test',
      name: '后端不可达测试书',
      // 临时目录下合法但从不创建的路径：标注读取对缺失目录返回空，
      // 失败后的 _saveQuietly 也只对已存在的目录落盘。
      projectDir:
          '${Directory.systemTemp.path}'
          '${Platform.pathSeparator}gujichazi_unreachable_test_never_created',
      imageFiles: const ['split_page_000.png'],
      recognitionStatus: RecognitionStatus.pending,
    );
    queue.enqueue(project);
    for (var i = 0; i < 5000 && queue.queuedIds.isNotEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(queue.queuedIds, isEmpty);

    final progress = queue.progressFor('unreachable_test');
    expect(progress, isNotNull);
    expect(progress!.status, RecognitionProgress.failed);
    // 失败信息是可指导行动的中文，而不是裸的英文 SocketException。
    expect(progress.error, contains('后端服务不可达'));
    expect(progress.error, contains('3 次连接失败'));
    expect(progress.error, isNot(contains('ClientException')));
    // 走的是不可达路径（独立计数），不消耗通用失败/409 预算语义。
    expect(progress.error, isNot(contains('识别服务忙')));
    // 队列开始/跑空时保持唤醒钩子照常成对调用。
    expect(awakeCalls, [true, false]);
  });
}
