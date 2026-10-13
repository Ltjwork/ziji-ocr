// -*- coding: utf-8 -*-
// 书籍导入的 PDF 转图编排：导入页与书卡片「继续导入」共用的链路。
//
// 导入三段式——复制源文件 → 先落盘书记录（import_pending=true，书立即
// 出现在书库）→ 后台转图（进度可查）。应用中途退出后书记录还在，从书
// 卡片「继续导入」重新发起转换（后端 skip_existing 跳过已转换页，从断
// 点续完），完成时回填 imageFiles 并清掉 import_pending。
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/models.dart';
import 'python_service.dart';
import 'storage.dart';

class BookImport {
  BookImport._();

  /// 找到书 sources/ 目录里的 PDF（导入续跑的转换输入；一本一个源）。
  static String? findSourcePdf(Project project) {
    final sources = Directory(p.join(project.projectDir, 'sources'));
    if (!sources.existsSync()) return null;
    for (final f in sources.listSync()) {
      if (f is File &&
          ['.pdf'].contains(p.extension(f.path).toLowerCase())) {
        return f.path;
      }
    }
    return null;
  }

  /// 转换 PDF 页图（断点续跑：skipExisting=true 跳过已转换页）并在完成
  /// 后收尾——imageFiles 按页序回填、import_pending 清除、落盘。转换期
  /// 间经 [onProgress] 回调 (已转页数, 总页数)。
  static Future<void> convertPdf(
    Project project, {
    bool skipExisting = true,
    void Function(int current, int total)? onProgress,
  }) async {
    final pdf = findSourcePdf(project);
    if (pdf == null) {
      throw Exception('书源里没有 PDF（sources/ 为空或已删除），无法继续导入');
    }
    final images = await PythonService.pdfToImages(
      pdf,
      project.projectDir,
      skipExisting: skipExisting,
      onProgress: onProgress,
    );
    project.imageFiles
      ..clear()
      ..addAll(images);
    project.importPending = false;
    await ProjectStorage.save(project);
  }
}
