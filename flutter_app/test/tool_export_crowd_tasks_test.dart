// ignore_for_file: avoid_print
// 无头识字任务包导出（开发/联调工具）：
//   flutter test test/tool_export_crowd_tasks_test.dart --timeout 30m
// 从书库取「识字测试副本」，把指定页范围的未确认字导出为 crowd_tasks.zip，
// 与导出页「识字任务包」走完全相同的服务与导出器代码路径。
import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/services/crowd_dataset_exporter.dart';
import 'package:gujichazi/services/python_service.dart';
import 'package:gujichazi/services/storage.dart';

void main() {
  // 注意：不初始化 TestWidgetsFlutterBinding——它会 mock 掉全部 HTTP
  //（后端健康检查会拿到 400），本工具需要真实网络与子进程。

  test(
    'export crowd tasks headless',
    () async {
      const rootDir = r'C:\Users\LLLL\Documents\GujiBT';
      const pythonServiceDir = r'E:\Work\Flutter\ocr\python_service';
      const outputDir = r'E:\Work\Flutter\识字';

      final projects = await ProjectStorage.loadAll(rootDir);
      final project = projects.firstWhere(
        (p) => p.id == 'crowdtest1',
        orElse: () => throw StateError('找不到测试项目 crowdtest1'),
      );
      print('project: ${project.name} (${project.imageFiles.length} 页)');

      await PythonService.start(pythonServiceDir);
      // 后端就绪即可（内部端口跟随 service_port.txt）
      print('python backend ready');

      final exporter = CrowdDatasetExporter(
        project: project,
        onLog: (m) => print(m),
      );
      final result = await exporter.export(
        outputDir: '$outputDir\\crowd_tasks',
        createZip: true,
        unconfirmedOnly: true,
        pageStart: 1,
        pageEnd: 10,
      );
      print(
        'RESULT: pages=${result.pageCount} lines=${result.lineCount} '
        'chars=${result.charCount} tasks=${result.taskCount} '
        'errors=${result.errors.length}',
      );
      for (final e in result.errors) {
        print('[error] $e');
      }
      expect(result.pageCount, greaterThan(0));
      expect(result.taskCount, greaterThan(0));
      expect(result.zipPath, isNotNull);
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
