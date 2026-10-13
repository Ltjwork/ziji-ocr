// 「按主区拆分」任务进行中的状态判定（RecognitionQueue.isRegionSplitActive）：
// 主区快设的任务中返回（连校对页一起退回书库）与校对编辑器的 dispose
// 落盘避让都依赖它——只有拆分任务的排队/运行/正在停止算"进行中"，
// 暂停/失败/无任务/整本识别任务都不算。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/services/python_service.dart';
import 'package:gujichazi/services/recognition_queue.dart';

void main() {
  test('isRegionSplitActive：仅拆分任务的排队/运行/停止中算进行中', () async {
    // 一个已关闭的端口：入队后后台 drain 对它的请求立即连接被拒，
    // 重试预算压缩到亚秒内放弃，不在测试里留下长时间挂起的任务。
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = server.port;
    await server.close();
    debugSetServiceBase('http://127.0.0.1:$deadPort');
    final originalDelay = RecognitionQueue.retryDelay;
    RecognitionQueue.retryDelay = const Duration(milliseconds: 1);
    addTearDown(() {
      debugSetServiceBase('http://127.0.0.1:1288');
      RecognitionQueue.retryDelay = originalDelay;
    });

    final queue = RecognitionQueue.instance;
    const id = 'region_split_active_test';
    final project = Project(
      id: id,
      name: '拆分状态测试书',
      // 临时目录下合法但从不创建的路径：任务对该书第 0 页的请求只会
      // 撞上死端口，不会碰真实文件。
      projectDir:
          '${Directory.systemTemp.path}'
          '${Platform.pathSeparator}gujichazi_region_split_active_never_created',
      imageFiles: const [],
      recognitionStatus: RecognitionStatus.pending,
    );

    // 无任务：不算
    expect(queue.isRegionSplitActive(id), isFalse);

    // 拆分任务入队后（_drain 首步即 await，同步窗口内为 pending）：算
    queue.enqueueRegionSplit(project, pages: const [0], aiEnabled: false);
    expect(queue.isRegionSplitActive(id), isTrue);

    // 出队移除后：不算（失败/暂停的残留快照同样不算）
    queue.remove(id);
    expect(queue.isRegionSplitActive(id), isFalse);

    // 整本识别任务（kind=recognize）不算拆分进行中
    queue.enqueue(project);
    expect(queue.isRegionSplitActive(id), isFalse);
    queue.remove(id);
    expect(queue.isRegionSplitActive(id), isFalse);

    // 等后台排空，不把在途任务泄漏给后续测试
    for (var i = 0; i < 500 && queue.isRunning; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(queue.isRunning, isFalse);
  });
}
