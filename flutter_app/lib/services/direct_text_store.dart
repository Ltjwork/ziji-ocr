import 'dart:convert' show jsonDecode, jsonEncode, utf8;
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/models.dart';

/// 整页直读文本的落盘（编辑器「文本」视图）：每页一个纯文本文件
/// `<projectDir>/direct_text/<pageId>.txt`，外加元数据侧车
/// `<pageId>.meta.json`（哪个引擎/模型产出了这份文本）。
///
/// 与页标注 JSON（page_xxx.json）完全解耦：重识别/标注保存不会动它，
/// 它也不进训练数据/导出——直读模式是"快速通读 + AI 校对"的便签层，
/// 精校仍走标注管线。写盘走临时文件 + rename 原子替换（与注册表/
/// project.json 的写法同口径），避免半截文件。
class DirectTextStore {
  static Directory _dirFor(Project project) =>
      Directory(p.join(project.projectDir, 'direct_text'));

  static File _fileFor(Project project, String pageId) =>
      File(p.join(_dirFor(project).path, '$pageId.txt'));

  static File _metaFileFor(Project project, String pageId) =>
      File(p.join(_dirFor(project).path, '$pageId.meta.json'));

  /// 读某页直读文本；未识别过返回 null。
  static Future<String?> load(Project project, String pageId) async {
    try {
      final file = _fileFor(project, pageId);
      if (!await file.exists()) return null;
      return await file.readAsString(encoding: utf8);
    } catch (_) {
      return null;
    }
  }

  /// 保存某页直读文本（空文本也落盘，代表"直读过、结果为空"）。
  static Future<void> save(Project project, String pageId, String text) async {
    final dir = _dirFor(project);
    await dir.create(recursive: true);
    final file = _fileFor(project, pageId);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(text, encoding: utf8);
    await tmp.rename(file.path);
  }

  /// 保存直读元数据（哪个引擎/模型产出了这份文本、耗时/行数）。
  /// 状态栏用它回答"我看到的文本到底是谁读的"：本书引擎/模型改过之后
  /// 旧文本不会自动重读，没有这份记录用户分不清界面上显示的模型是
  /// "本书配置"还是"实际产出"。失败静默——元数据缺了只是少个提示，
  /// 不该影响识别主流程。
  static Future<void> saveMeta(
    Project project,
    String pageId,
    Map<String, dynamic> meta,
  ) async {
    try {
      final dir = _dirFor(project);
      await dir.create(recursive: true);
      final file = _metaFileFor(project, pageId);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(meta), encoding: utf8);
      await tmp.rename(file.path);
    } catch (_) {}
  }

  /// 读直读元数据；无文件/解析失败返回 null。
  static Future<Map<String, dynamic>?> loadMeta(
    Project project,
    String pageId,
  ) async {
    try {
      final file = _metaFileFor(project, pageId);
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString(encoding: utf8));
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  /// 最近保存时间（状态行显示用）；无文件返回 null。
  static DateTime? savedAt(Project project, String pageId) {
    try {
      final f = _fileFor(project, pageId);
      return f.existsSync() ? f.lastModifiedSync() : null;
    } catch (_) {
      return null;
    }
  }
}
