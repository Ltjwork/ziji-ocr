// 「按主区拆分」断点文件（region_split_progress.json）的实时维护：
// 任务启动即写全集（覆盖上一轮旧断点）、每完成一页收窄、全部完成清除。
// 复现用户反馈的回归：拆分任务入队运行后退出应用再回来，主区快设仍显示
// 旧页数的「继续拆分剩余 N 页」——旧实现只在停止/失败时写断点，运行中
// 退出后盘上还是上一轮的页集，已拆分的页被重复计入。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/services/python_service.dart';
import 'package:gujichazi/services/recognition_queue.dart';
import 'package:gujichazi/services/storage.dart';

/// 假识别后端：按 image_path 分流——[hangPaths] 的请求挂起直到
/// [release]（[failOnRelease] 为真时放行为 500 让该页失败，否则 200），
/// 其余请求立即 200 返回 `{"lines": []}`（空行集 = 该页级联成功落盘）。
/// 收到任何请求即完成 [sawAnyRequest]。
class _FakeBackend {
  _FakeBackend(this.hangPaths, {this.failOnRelease = false});

  final Set<String> hangPaths;
  final bool failOnRelease;
  final _sawAny = Completer<void>();
  final _gate = Completer<void>();
  HttpServer? _server;

  Future<void> get sawAnyRequest => _sawAny.future;

  /// 放行全部挂起的请求。
  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = _server!.port;
    debugSetServiceBase('http://127.0.0.1:$port');
    _server!.listen((req) async {
      if (!_sawAny.isCompleted) _sawAny.complete();
      final body = await req.map(utf8.decode).join();
      String imagePath = '';
      try {
        imagePath = (jsonDecode(body) as Map)['image_path'] as String? ?? '';
      } catch (_) {}
      var status = 200;
      if (hangPaths.any(imagePath.endsWith)) {
        await _gate.future;
        if (failOnRelease) status = 500;
      }
      req.response.statusCode = status;
      if (status == 200) req.response.write('{"lines": []}');
      await req.response.close();
    });
  }

  Future<void> dispose() async {
    release();
    await _server?.close(force: true);
    debugSetServiceBase('http://127.0.0.1:1288');
  }
}

Project _project(String id, String dir, List<String> imageFiles) => Project(
  id: id,
  name: '拆分断点测试$id',
  projectDir: dir,
  imageFiles: imageFiles,
  recognitionStatus: RecognitionStatus.pending,
);

/// 带一个已确认正文主区的页标注（拆分队列目标页的形态）。
Future<void> _writeBodyRegionAnnotation(
  Project project,
  int index,
  String regionId,
) async {
  await ProjectStorage.saveAnnotation(
    project.projectDir,
    PageAnnotation(
      pageId: project.pageIdAt(index),
      imagePath: project.imageFiles[index],
      mainRegions: [
        MainRegion(
          id: regionId,
          x: 10,
          y: 10,
          w: 100,
          h: 200,
          boxConfirmed: true,
        ),
      ],
    ),
  );
}

Future<RegionSplitResume?> _readResume(String dir) =>
    RecognitionQueue.loadRegionSplitResume(dir);

Future<void> _untilQueueIdle(RecognitionQueue queue) async {
  for (var i = 0; i < 1000 && queue.isRunning; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(queue.isRunning, isFalse, reason: '队列未在时限内跑空');
}

void main() {
  test('运行中断点逐页收窄：一页完成后断点只剩剩余页，失败页留在断点里',
      () async {
    final tmp = Directory.systemTemp.createTempSync('gjrs_resume');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final backend = _FakeBackend({'p1.png'}, failOnRelease: true);
    await backend.start();
    final originalHook = RecognitionQueue.keepAwakeHook;
    RecognitionQueue.keepAwakeHook = (_) {};
    addTearDown(() async {
      await backend.dispose();
      RecognitionQueue.keepAwakeHook = originalHook;
    });

    final sep = Platform.pathSeparator;
    final project = _project('region_split_resume_mid', tmp.path, [
      '${tmp.path}${sep}p0.png',
      '${tmp.path}${sep}p1.png',
    ]);
    // 两页都是拆分目标（有正文主区）；p0 秒成功、p1 挂起待放行为 500。
    await _writeBodyRegionAnnotation(project, 0, 'mr0');
    await _writeBodyRegionAnnotation(project, 1, 'mr1');

    final queue = RecognitionQueue.instance;
    queue.enqueueRegionSplit(project, pages: const [0, 1], aiEnabled: false);

    // p0 收账后（p1 仍在途挂起，任务仍在跑）：断点已收窄为 [1]。旧实现
    // 此刻盘上没有断点文件（只在停止/失败时写），必红。
    RegionSplitResume? mid;
    for (var i = 0; i < 1000; i++) {
      mid = await _readResume(tmp.path);
      if (mid != null && mid.pages.length == 1) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(queue.isRunning, isTrue, reason: '断言点必须仍在任务运行中');
    expect(mid!.pages, const [1]);
    expect(mid.aiEnabled, isFalse);

    // 放行 p1 → 500 → 该页失败收账：断点保留失败页供续跑，快照翻 failed。
    backend.release();
    await _untilQueueIdle(queue);
    final settled = await _readResume(tmp.path);
    expect(settled!.pages, const [1], reason: '失败页应留在断点里供续跑');
    expect(
      queue.progressFor(project.id)?.status,
      RecognitionProgress.failed,
    );
  });

  test('启动即覆盖旧断点：任务开始后断点=本次全集；全部完成后断点清除',
      () async {
    final tmp = Directory.systemTemp.createTempSync('gjrs_start');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final backend = _FakeBackend({'p0.png'});
    await backend.start();
    final originalHook = RecognitionQueue.keepAwakeHook;
    RecognitionQueue.keepAwakeHook = (_) {};
    addTearDown(() async {
      await backend.dispose();
      RecognitionQueue.keepAwakeHook = originalHook;
    });

    final sep = Platform.pathSeparator;
    final project = _project('region_split_resume_start', tmp.path, [
      '${tmp.path}${sep}p0.png',
    ]);
    await _writeBodyRegionAnnotation(project, 0, 'mr0');

    // 预埋上一轮的旧断点（页号都不在本书里）：不被覆盖的话主区快设会拿
    // 它显示「继续拆分剩余 2 页」。
    File(
      '${tmp.path}${sep}region_split_progress.json',
    ).writeAsStringSync('{"pages": [7, 8], "ai_enabled": true}');

    final queue = RecognitionQueue.instance;
    queue.enqueueRegionSplit(project, pages: const [0], aiEnabled: false);

    // 首个请求已到假后端（任务已开跑、p0 在途挂起）：断点必须已是本次
    // 全集且 AI 开关为本次值。旧实现盘上还是 [7,8]，必红。
    await backend.sawAnyRequest;
    final started = await _readResume(tmp.path);
    expect(started!.pages, const [0]);
    expect(started.aiEnabled, isFalse);

    // 放行 → p0 成功 → 任务全部完成：断点清除、快照回落。
    backend.release();
    await _untilQueueIdle(queue);
    expect(
      File('${tmp.path}${sep}region_split_progress.json').existsSync(),
      isFalse,
      reason: '全部完成后断点应清除',
    );
    expect(queue.progressFor(project.id), isNull);
  });
}
