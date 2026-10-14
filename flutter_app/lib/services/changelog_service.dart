import 'dart:io';

import 'package:path/path.dart' as p;

import 'python_service.dart';

/// 更新日志条目：一个 `## 版本号` 小节（markdown 原文，GitHub 发布说明
/// 直接可用）。
class ChangelogEntry {
  const ChangelogEntry({required this.version, required this.markdown});

  final String version;
  final String markdown;
}

/// 读取项目根的 CHANGELOG.md 并解析成按版本的分节。
///
/// 用途：应用内「更新日志」页展示本版本更新内容；上传 GitHub 时一键
/// 复制某版本（或全部）的 markdown 作为 Release 发布说明。路径按优先级
/// 探测：python_service 的上级（开发运行 = 仓库根；安装版 = 安装目录，
/// 打包脚本会把 CHANGELOG.md 放到那）→ exe 同级 → exe 上级。
class ChangelogService {
  /// 解析 CHANGELOG.md 文本（纯函数，测试用）。`## ` 开头的行是版本分节
  /// 标题；首个非 `# ` 一级标题前的内容忽略。返回按文件顺序（最新在前，
  /// 项目约定 CHANGELOG 倒序维护，第一条即当前版本）。
  static List<ChangelogEntry> parse(String content) {
    final entries = <ChangelogEntry>[];
    final lines = content.replaceAll('\r\n', '\n').split('\n');
    String? version;
    final body = <String>[];
    for (final line in lines) {
      if (line.startsWith('## ')) {
        if (version != null) {
          entries.add(ChangelogEntry(version: version, markdown: _trim(body)));
        }
        version = line.substring(3).trim();
        body.clear();
      } else if (version != null) {
        body.add(line);
      }
    }
    if (version != null) {
      entries.add(ChangelogEntry(version: version, markdown: _trim(body)));
    }
    return entries;
  }

  static String _trim(List<String> body) {
    var text = body.join('\n');
    // 去掉小节首尾的空行，保留内部结构与空行（markdown 语义）。
    while (text.startsWith('\n')) {
      text = text.substring(1);
    }
    while (text.endsWith('\n')) {
      text = text.substring(0, text.length - 1);
    }
    return text;
  }

  /// 读 CHANGELOG.md；找不到/读不了返回空列表（页面降级提示）。
  static Future<List<ChangelogEntry>> load() async {
    for (final path in candidatePaths()) {
      try {
        final file = File(path);
        if (!await file.exists()) continue;
        final content = await file.readAsString();
        final entries = parse(content);
        if (entries.isNotEmpty) return entries;
      } catch (_) {
        // 换下一个候选路径
      }
    }
    return const [];
  }

  /// CHANGELOG.md 候选路径（去重、保序）。
  static List<String> candidatePaths() {
    final out = <String>[];
    void add(String path) {
      final normalized = p.normalize(path);
      if (!out.contains(normalized)) out.add(normalized);
    }

    final serviceDir = PythonService.logServiceDir;
    if (serviceDir != null && serviceDir.isNotEmpty) {
      add(p.join(serviceDir, '..', 'CHANGELOG.md'));
    }
    final exeDir = p.dirname(Platform.resolvedExecutable);
    add(p.join(exeDir, 'CHANGELOG.md'));
    add(p.join(exeDir, '..', 'CHANGELOG.md'));
    return out;
  }
}
