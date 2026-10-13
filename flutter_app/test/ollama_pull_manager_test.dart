// 全局拉取管理器（多任务队列版）的状态机与持久化守门员测试：
// 单任务成功/失败/持久化、restore 恢复（v2 列表与 v1 单任务兼容）、
// 并发额度与排队放行、按模型取消、多选批量入队。
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/services/ollama_pull_manager.dart';
import 'package:gujichazi/services/ollama_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const prefsKeyV2 = 'ollama_active_pulls_v2';
  const prefsKeyV1 = 'ollama_active_pull_v1';

  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    OllamaPullManager.instance.resetForTest();
    addTearDown(OllamaPullManager.instance.resetForTest);
  });

  OllamaPullTask? taskOf(String model) =>
      OllamaPullManager.instance.taskOf(model);

  test('start 成功：进度聚进任务、持久化记录清除、phase=succeeded', () async {
    OllamaPullManager.pullRunner = (baseUrl, model, {required client}) async* {
      yield const OllamaPullEvent(
        model: 'm:1b',
        completedBytes: 5,
        totalBytes: 10,
        status: 'pulling sha256:a',
      );
      yield const OllamaPullEvent(
        model: 'm:1b',
        completedBytes: 10,
        totalBytes: 10,
        status: 'success',
        done: true,
      );
    };
    final mgr = OllamaPullManager.instance;
    await mgr.start(baseUrl: 'http://x:11434', model: 'm:1b');
    final task = taskOf('m:1b')!;
    expect(task.phase, OllamaPullPhase.succeeded);
    expect(mgr.lastSucceededModel, 'm:1b');
    expect(task.completedBytes, 10);
    expect(task.progress, 1.0);
    expect(
      mgr.log.where((l) => l.contains('[ui] ollama pull m:1b')),
      isNotEmpty,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(prefsKeyV2), isNull);
    expect(prefs.getString(prefsKeyV1), isNull);
  });

  test('start 失败：phase=failed 且保留持久化记录（重启后可续传）', () async {
    OllamaPullManager.pullRunner = (baseUrl, model, {required client}) {
      return Stream.error(
        OllamaException('pull model manifest: file does not exist'),
      );
    };
    final mgr = OllamaPullManager.instance;
    await mgr.start(baseUrl: 'http://x', model: 'no:such');
    expect(taskOf('no:such')!.phase, OllamaPullPhase.failed);
    expect(taskOf('no:such')!.error, contains('file does not exist'));
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(prefsKeyV2);
    expect(raw, isNotNull);
    final models = (jsonDecode(raw!) as Map)['models'] as List;
    expect(models.single['model'], 'no:such');
  });

  test('restore：v2 列表恢复多个 interrupted；v1 单任务兼容；二次调用空操作',
      () async {
    SharedPreferences.setMockInitialValues({
      prefsKeyV2: jsonEncode({
        'models': [
          {'model': 'a:1b', 'base_url': 'http://l'},
          {'model': 'b:4b', 'base_url': 'http://l'},
        ],
      }),
    });
    var mgr = OllamaPullManager.instance;
    await mgr.restore();
    expect(taskOf('a:1b')!.phase, OllamaPullPhase.interrupted);
    expect(taskOf('b:4b')!.phase, OllamaPullPhase.interrupted);
    await mgr.restore();
    expect(mgr.tasks.length, 2);

    // v1 兼容。
    OllamaPullManager.instance.resetForTest();
    SharedPreferences.setMockInitialValues({
      prefsKeyV1: jsonEncode({
        'model': 'qwen3.5:4b',
        'base_url': 'http://localhost:11434',
      }),
    });
    mgr = OllamaPullManager.instance;
    await mgr.restore();
    final task = taskOf('qwen3.5:4b')!;
    expect(task.phase, OllamaPullPhase.interrupted);
    expect(task.baseUrl, 'http://localhost:11434');
  });

  test('dismiss：清理指定中断任务；dismissAll 清理全部', () async {
    SharedPreferences.setMockInitialValues({
      prefsKeyV2: jsonEncode({
        'models': [
          {'model': 'a:1b', 'base_url': ''},
          {'model': 'b:4b', 'base_url': ''},
        ],
      }),
    });
    final mgr = OllamaPullManager.instance;
    await mgr.restore();
    mgr.dismiss('a:1b');
    expect(taskOf('a:1b'), isNull);
    expect(taskOf('b:4b'), isNotNull);
    mgr.dismissAll();
    expect(mgr.tasks, isEmpty);
    expect(mgr.log, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(prefsKeyV2), isNull);
  });

  test('并发额度：concurrency=2 同时拉 2 个、第 3 个排队，完成后放行',
      () async {
    final controllers = <String, StreamController<OllamaPullEvent>>{};
    Stream<OllamaPullEvent> runner(String baseUrl, String model,
        {required client}) {
      return (controllers[model] ??= StreamController<OllamaPullEvent>(
        onListen: () {},
      )).stream;
    }

    addTearDown(() async {
      for (final c in controllers.values) {
        await c.close();
      }
    });
    OllamaPullManager.pullRunner = runner;
    final mgr = OllamaPullManager.instance;
    await mgr.setConcurrency(2);
    expect(mgr.concurrency, 2);

    final f1 = mgr.start(baseUrl: 'http://x', model: 'a:1b');
    final f2 = mgr.start(baseUrl: 'http://x', model: 'b:4b');
    final f3 = mgr.start(baseUrl: 'http://x', model: 'c:9b');
    await Future<void>.delayed(Duration.zero);
    expect(taskOf('a:1b')!.phase, OllamaPullPhase.pulling);
    expect(taskOf('b:4b')!.phase, OllamaPullPhase.pulling);
    expect(taskOf('c:9b')!.phase, OllamaPullPhase.queued);
    expect(mgr.pullingCount, 2);

    // a 完成后排队任务立刻放行。
    await controllers['a:1b']!.close();
    await f1;
    await Future<void>.delayed(Duration.zero);
    expect(taskOf('a:1b')!.phase, OllamaPullPhase.succeeded);
    expect(taskOf('c:9b')!.phase, OllamaPullPhase.pulling);

    // 运行中调高并发：排队任务立即被放行。
    final f4 = mgr.start(baseUrl: 'http://x', model: 'd:27b');
    await Future<void>.delayed(Duration.zero);
    expect(taskOf('d:27b')!.phase, OllamaPullPhase.queued);
    await mgr.setConcurrency(3);
    await Future<void>.delayed(Duration.zero);
    expect(taskOf('d:27b')!.phase, OllamaPullPhase.pulling);

    await controllers['b:4b']!.close();
    await controllers['c:9b']!.close();
    await controllers['d:27b']!.close();
    await Future.wait([f2, f3, f4]);
    expect(mgr.tasks.every((t) => t.phase == OllamaPullPhase.succeeded),
        isTrue);
  });

  test('并发额度钳制到 1..4 并持久化；restore 时读回', () async {
    final mgr = OllamaPullManager.instance;
    await mgr.setConcurrency(9);
    expect(mgr.concurrency, 4);
    await mgr.setConcurrency(0);
    expect(mgr.concurrency, 1);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('ollama_pull_concurrency'), 1);

    OllamaPullManager.instance.resetForTest();
    await SharedPreferences.getInstance().then(
      (p) => p.setInt('ollama_pull_concurrency', 3),
    );
    await OllamaPullManager.instance.restore();
    expect(OllamaPullManager.instance.concurrency, 3);
  });

  test('按模型取消：下载中置 cancelled；排队中直接移除', () async {
    final controller = StreamController<OllamaPullEvent>();
    addTearDown(controller.close);
    OllamaPullManager.pullRunner =
        (baseUrl, model, {required client}) => controller.stream;
    final mgr = OllamaPullManager.instance;
    final f1 = mgr.start(baseUrl: 'http://x', model: 'a:1b');
    final f2 = mgr.start(baseUrl: 'http://x', model: 'b:4b'); // 排队
    await Future<void>.delayed(Duration.zero);
    mgr.cancel('b:4b');
    expect(taskOf('b:4b'), isNull);
    await f2; // 排队取消也完成其 Future，不悬挂

    mgr.cancel('a:1b');
    // 关闭流模拟真实世界里"client.close() 掐断 HTTP 流"。
    await controller.close();
    await f1;
    expect(taskOf('a:1b')!.phase, OllamaPullPhase.cancelled);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(prefsKeyV2), isNull);
  });

  test('重复入队同一模型被忽略；已结束任务可重新入队', () async {
    OllamaPullManager.pullRunner = (baseUrl, model, {required client}) async* {
      yield const OllamaPullEvent(
        model: 'm:1b',
        completedBytes: 1,
        totalBytes: 1,
        status: 'success',
        done: true,
      );
    };
    final mgr = OllamaPullManager.instance;
    await mgr.start(baseUrl: 'http://x', model: 'm:1b');
    expect(taskOf('m:1b')!.phase, OllamaPullPhase.succeeded);
    // 重新入队：旧记录被替换，任务重跑。
    await mgr.start(baseUrl: 'http://x', model: 'm:1b');
    expect(taskOf('m:1b')!.phase, OllamaPullPhase.succeeded);
    expect(mgr.tasks.where((t) => t.model == 'm:1b').length, 1);
  });

  test('startAll：多选批量入队，超出并发的排队且持久化包含全部', () async {
    final controllers = <String, StreamController<OllamaPullEvent>>{};
    OllamaPullManager.pullRunner = (baseUrl, model, {required client}) {
      return (controllers[model] ??= StreamController<OllamaPullEvent>(
        onListen: () {},
      )).stream;
    };
    addTearDown(() async {
      for (final c in controllers.values) {
        await c.close();
      }
    });
    final mgr = OllamaPullManager.instance;
    mgr.startAll(baseUrl: 'http://x', models: const ['a:1b', 'b:4b', 'c:9b']);
    await Future<void>.delayed(Duration.zero);
    expect(mgr.pullingCount, 1); // 默认并发 1
    expect(mgr.queuedCount, 2);
    final prefs = await SharedPreferences.getInstance();
    final models =
        (jsonDecode(prefs.getString(prefsKeyV2)!) as Map)['models'] as List;
    expect(models.length, 3);
    await controllers['a:1b']!.close();
    await Future<void>.delayed(Duration.zero);
    await controllers['b:4b']!.close();
    await Future<void>.delayed(Duration.zero);
    await controllers['c:9b']!.close();
  });
}
