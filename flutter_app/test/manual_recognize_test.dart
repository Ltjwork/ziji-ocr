// 「创建后手动开始识别」：项目标记的持久化兼容、重启不自动续跑、
// 一旦开始识别标记翻回自动，以及空标注的内容判定。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/services/recognition_queue.dart';

Project _project({
  required String id,
  required bool autoRecognize,
  String? dir,
}) {
  return Project(
    id: id,
    name: '手动识别测试$id',
    // 临时目录下合法但从不创建的路径：0 页书跑完即可，_saveQuietly 只对
    // 已存在的目录落盘，不会凭空建出该目录。
    projectDir:
        dir ??
        '${Directory.systemTemp.path}'
        '${Platform.pathSeparator}gujichazi_manual_recognize_test_never_created',
    imageFiles: const [],
    recognitionStatus: RecognitionStatus.pending,
    autoRecognize: autoRecognize,
  );
}

void main() {
  test('autoRecognize 默认 true，序列化往返与旧数据兼容', () {
    // 旧数据（project.json 无 auto_recognize 键）读回 true。
    final legacy = Project.fromJson({
      'id': 'legacy1',
      'name': '旧数据书',
      'project_dir': 'unused',
      'image_files': <String>[],
    });
    expect(legacy.autoRecognize, isTrue);

    // false 显式序列化并读回。
    final manual = _project(id: 'm1', autoRecognize: false);
    final restored = Project.fromJson(manual.toJson());
    expect(restored.autoRecognize, isFalse);

    final auto = _project(id: 'a1', autoRecognize: true);
    expect(Project.fromJson(auto.toJson()).autoRecognize, isTrue);
  });

  test('项目级 AI 识别开关序列化往返，旧数据默认关闭', () {
    final legacy = Project.fromJson({
      'id': 'legacy-ai',
      'name': '旧数据',
      'project_dir': 'unused',
      'image_files': <String>[],
    });
    expect(legacy.aiRecognitionAssist, isFalse);
    final p = _project(id: 'ai', autoRecognize: true)
      ..aiRecognitionAssist = true;
    final restored = Project.fromJson(p.toJson());
    expect(restored.aiRecognitionAssist, isTrue);
  });

  test('PageAnnotation.hasAnyContent 区分空标注与有内容标注', () {
    final empty = PageAnnotation(pageId: 'page_000', imagePath: 'x.png');
    expect(empty.hasAnyContent, isFalse);

    final withLine = PageAnnotation(
      pageId: 'page_000',
      imagePath: 'x.png',
      lines: [
        LineBlock(id: 'l1', x: 1, y: 2, w: 3, h: 4, lineNo: 0),
      ],
    );
    expect(withLine.hasAnyContent, isTrue);
  });

  test('启动不自动续跑已移除：enqueue 只入队指定书并翻回自动标记', () async {
    final queue = RecognitionQueue.instance;
    final originalHook = RecognitionQueue.keepAwakeHook;
    RecognitionQueue.keepAwakeHook = (_) {}; // 测试里不做真实的系统保持唤醒
    addTearDown(() {
      RecognitionQueue.keepAwakeHook = originalHook;
    });

    // 两本未完成的书（一本手动、一本中断待续）都不因存在而被排队；
    // enqueue（首页按钮/编辑器菜单等用户入口）才入队并翻回自动标记。
    final manual = _project(id: 'manual1', autoRecognize: false);
    final auto = _project(id: 'auto1', autoRecognize: true);
    expect(queue.queuedIds, isEmpty);

    queue.enqueue(manual);
    expect(manual.autoRecognize, isTrue);
    expect(queue.queuedIds, contains('manual1'));
    // 0 页书立即跑完出队。
    for (var i = 0; i < 100 && queue.queuedIds.isNotEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(queue.queuedIds, isEmpty);
    expect(auto.autoRecognize, isTrue); // 另一本书未被波及
  });

  test('enqueueReRecognize：清空标注、重置状态计数与上次页号，像新书一样入队',
      () async {
    final queue = RecognitionQueue.instance;
    final originalHook = RecognitionQueue.keepAwakeHook;
    RecognitionQueue.keepAwakeHook = (_) {};
    addTearDown(() {
      RecognitionQueue.keepAwakeHook = originalHook;
    });

    // 临时书目录里放两个标注文件，验证清空逻辑。
    final tmp = Directory.systemTemp.createTempSync('gjrr');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final annDir = Directory('${tmp.path}${Platform.pathSeparator}annotations')
      ..createSync();
    File('${annDir.path}${Platform.pathSeparator}page_000.json')
        .writeAsStringSync('{}');
    File('${annDir.path}${Platform.pathSeparator}page_001.json')
        .writeAsStringSync('{}');

    final done = _project(id: 'redone1', autoRecognize: true, dir: tmp.path)
      ..recognitionStatus = 'completed'
      ..recognizedPages = 7
      ..lastPageIndex = 6;
    expect(done.recognitionCompleted, isTrue);

    await queue.enqueueReRecognize(done);
    // 整书重置：标注目录整个移除、计数/上次页号归零、状态翻回待识别。
    expect(annDir.existsSync(), isFalse);
    expect(done.recognizedPages, 0);
    expect(done.lastPageIndex, 0);
    expect(done.autoRecognize, isTrue);
    for (var i = 0; i < 100 && queue.queuedIds.isNotEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(queue.queuedIds, isEmpty);
    // 已完成守卫不残留：跑完后（0 页书立即完成）普通 enqueue 不再入队。
    done.recognitionStatus = 'completed';
    queue.enqueue(done);
    expect(queue.queuedIds, isNot(contains('redone1')));
  });
}
