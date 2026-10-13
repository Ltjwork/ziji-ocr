import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// 朝代基准测试的目录解析：样张 + gt/*.json 基准释文所在目录。
///
/// 仓库默认位置是 `ocr/test_images/periods`（后端 DEFAULT_BENCH_DIR 的
/// 同一相对口径）；开发运行与打包运行的可执行文件层级不同，所以从
/// 可执行文件与工作目录向上逐级探测；探测不到时由用户手选并记住。
class DynastyBenchStore {
  static const _prefsKey = 'dynasty_bench_dir_v1';

  /// 解析基准目录：记住的手选路径优先，其次自动探测；都没有返回 null。
  static Future<String?> resolve() async {
    final prefs = await SharedPreferences.getInstance();
    final remembered = prefs.getString(_prefsKey);
    if (remembered != null && await _isBenchDir(remembered)) {
      return remembered;
    }
    for (final candidate in _candidates()) {
      if (await _isBenchDir(candidate)) return candidate;
    }
    return null;
  }

  /// 用户手选目录（记住；不是合法基准目录时返回 false 不落盘）。
  static Future<bool> choose(String dir) async {
    if (!await _isBenchDir(dir)) return false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, dir);
    return true;
  }

  static Future<bool> _isBenchDir(String dir) =>
      File('$dir${Platform.pathSeparator}gt${Platform.pathSeparator}01_xianqin.json')
          .exists();

  static List<String> _candidates() {
    final marker = ['test_images', 'periods'];
    final starts = <String>[
      Directory.current.path,
      if (Platform.resolvedExecutable.isNotEmpty)
        File(Platform.resolvedExecutable).parent.path,
    ];
    final out = <String>[];
    for (final start in starts) {
      var dir = Directory(start).absolute;
      for (var i = 0; i < 8; i++) {
        out.add('${dir.path}${Platform.pathSeparator}${marker.join(Platform.pathSeparator)}');
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
    }
    return out;
  }
}
