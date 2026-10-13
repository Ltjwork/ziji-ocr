// 「识别完成后关机」开关的状态语义。刻意不测「勾选后队列跑空 → 安排
// 关机」的触发路径——那会真的调用系统 shutdown 命令，不能在测试里执行；
// 该路径由 60 秒缓冲、首页横幅取消（shutdown /a）兜底。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/services/recognition_queue.dart';

void main() {
  test('「识别完成后关机」默认关闭，设置与复位正常', () {
    final queue = RecognitionQueue.instance;
    addTearDown(() => queue.setShutdownWhenIdle(false));
    expect(queue.shutdownWhenIdle, isFalse);
    expect(queue.shutdownPending, isFalse);

    queue.setShutdownWhenIdle(true);
    expect(queue.shutdownWhenIdle, isTrue);
    queue.setShutdownWhenIdle(true); // 重复设置幂等
    expect(queue.shutdownWhenIdle, isTrue);

    queue.setShutdownWhenIdle(false);
    expect(queue.shutdownWhenIdle, isFalse);
    expect(queue.shutdownError, isNull);
  });

  test('未勾选关机时，空书队列跑完不进入关机倒计时', () async {
    final queue = RecognitionQueue.instance;
    addTearDown(() => queue.setShutdownWhenIdle(false));
    expect(queue.shutdownWhenIdle, isFalse);

    final project = Project(
      id: 'shutdown_idle_test',
      name: '关机测试书',
      // 临时目录下合法但从不创建的路径：_processBook 对 0 页书直接标记
      // 完成，_saveQuietly 只对已存在的目录落盘，不会凭空建出该目录。
      projectDir:
          '${Directory.systemTemp.path}'
          '${Platform.pathSeparator}gujichazi_shutdown_test_never_created',
      imageFiles: const [],
      recognitionStatus: RecognitionStatus.pending,
    );
    queue.enqueue(project);
    // 0 页的书立即跑完出队；未勾选关机，不应有任何关机倒计时。
    for (var i = 0; i < 100 && queue.queuedIds.isNotEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(queue.queuedIds, isEmpty);
    expect(queue.shutdownPending, isFalse);
    expect(queue.shutdownError, isNull);
  });

  test('识别期间请求系统保持唤醒，跑完后恢复', () async {
    final queue = RecognitionQueue.instance;
    final calls = <bool>[];
    final original = RecognitionQueue.keepAwakeHook;
    RecognitionQueue.keepAwakeHook = calls.add;
    addTearDown(() {
      RecognitionQueue.keepAwakeHook = original;
      queue.setShutdownWhenIdle(false);
    });

    final project = Project(
      id: 'keep_awake_test',
      name: '保持唤醒测试书',
      projectDir:
          '${Directory.systemTemp.path}'
          '${Platform.pathSeparator}gujichazi_keep_awake_test_never_created',
      imageFiles: const [],
      recognitionStatus: RecognitionStatus.pending,
    );
    queue.enqueue(project);
    for (var i = 0; i < 100 && queue.queuedIds.isNotEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(queue.queuedIds, isEmpty);
    // 队列开始处理时请求保持唤醒，跑空后成对释放。
    expect(calls, [true, false]);
    expect(queue.isRunning, isFalse);
  });
}
