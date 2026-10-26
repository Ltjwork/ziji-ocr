import 'dart:io';

import 'package:path/path.dart' as p;

/// 定位 python_service 目录：从工作目录 / exe 目录 / 脚本目录向上逐级
/// 找含 main.py 的 `python_service` 子目录（主实例与训练器独立窗口共用）。
List<String> serviceDirCandidates() {
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final roots = <String>{
    Directory.current.path,
    exeDir,
    p.dirname(Platform.script.toFilePath(windows: Platform.isWindows)),
  };

  return roots
      .expand(ancestorDirectories)
      .map((root) => p.join(root, 'python_service'))
      .toSet()
      .toList();
}

Iterable<String> ancestorDirectories(String start) sync* {
  var current = p.canonicalize(start);
  while (true) {
    yield current;
    final parent = p.dirname(current);
    if (parent == current) break;
    current = parent;
  }
}

/// 第一个含 main.py 的候选目录；找不到返回 null（调用方给出引导界面）。
Future<String?> resolveServiceDir() async {
  for (final c in serviceDirCandidates()) {
    if (await File(p.join(c, 'main.py')).exists()) {
      return p.canonicalize(c);
    }
  }
  return null;
}
