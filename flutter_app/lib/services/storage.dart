import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../models/models.dart';
import 'char_stats.dart';
import 'isolate_codec.dart';
import 'python_service.dart';
import 'train_auto_export.dart';

/// Page id convention shared by the editor, the storage layer and the batch
/// queue: zero-padded page index, e.g. page 7 -> `page_007`.
String pageIdForIndex(int index) => 'page_${index.toString().padLeft(3, '0')}';

class ProjectStorage {
  static final Map<String, Future<void>> _pendingWrites = {};

  /// Writes a JSON document through a sibling temporary file.  Annotation
  /// files are updated frequently while the editor is open; writing directly
  /// to the destination can leave an empty/truncated file when the process is
  /// interrupted.  Keeping the previous file as `.bak` also lets readers
  /// recover from an interrupted replacement.
  static Future<void> _writeJsonAtomicNow(
    File target,
    Object value, {
    bool quiet = false,
  }) async {
    final temp = File('${target.path}.tmp');
    final backup = File('${target.path}.bak');
    // 批量拆分时标注（几百字块 × 双份序列化）达数百 KB/次、每页多次：
    // 编码搬后台 isolate，UI isolate 只做文件轮换。
    final encoded = await encodeJsonInIsolate(value);

    // Flush the complete JSON before touching the current file.
    final sink = temp.openWrite();
    try {
      sink.write(encoded);
      await sink.flush();
    } finally {
      await sink.close();
    }

    var movedCurrent = false;
    try {
      if (await backup.exists()) await backup.delete();
      if (await target.exists()) {
        await _renameWithRetry(target, backup.path);
        movedCurrent = true;
      }
      await _renameWithRetry(temp, target.path);
      // 落盘指纹（字节数 + 内容哈希）：与读取侧快照对比，可确凿判定
      // "日志说写了、读回来却是旧的"到底写没写进这个文件。
      if (!quiet) {
        PythonService.addAppLog(
          '[保存诊断] 落盘 ${p.basename(target.path)} '
          'bytes=${encoded.length} fp=0x${encoded.hashCode.toRadixString(16)}',
        );
      }
    } catch (error) {
      PythonService.addAppLog(
        '[保存诊断] ⚠ ${p.basename(target.path)} 原子写失败：$error',
        isError: true,
      );
      // If replacement failed after moving the old document, put it back so
      // callers still have a readable file on the next launch.
      if (movedCurrent && !await target.exists() && await backup.exists()) {
        try {
          await backup.rename(target.path);
        } catch (_) {
          // Preserve the original exception; the backup remains available.
        }
      }
      rethrow;
    }
  }

  /// Windows 改名竞态短重试：并发读者（如批量断点的 10ms 轮询读、
  /// 恢复快照读取）短暂持有目标句柄时 rename 报 PathAccessException
  ///——读方 open/close 只占微秒级，等待重试即可收敛；超过
  /// [attempts]×5ms 仍失败按原异常上抛（走原子写的回滚路径）。
  static Future<void> _renameWithRetry(
    File src,
    String dest, {
    int attempts = 40,
  }) async {
    for (var i = 0;; i++) {
      try {
        await src.rename(dest);
        return;
      } on FileSystemException {
        if (i >= attempts) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }
  }

  /// Editor saves are intentionally fire-and-forget. Serialize writes per
  /// file so two pointer events cannot race over the shared target/temp file.
  static Future<void> _writeJsonAtomic(
    File target,
    Object value, {
    bool quiet = false,
  }) {
    final path = target.path;
    final previous = _pendingWrites[path];
    final ready = previous == null
        ? Future<void>.value()
        : previous.then<void>((_) {}, onError: (_, __) {});
    final next = ready.then((_) => _writeJsonAtomicNow(target, value, quiet: quiet));
    _pendingWrites[path] = next;
    void cleanup() {
      if (identical(_pendingWrites[path], next)) _pendingWrites.remove(path);
    }

    next.then<void>((_) => cleanup(), onError: (_, __) => cleanup());
    return next;
  }

  /// 通用静默原子写：供书籍目录外的小型全局账本（文字汇总 char_stats）
  /// 复用同一套 tmp→bak→rename 落盘与按文件串行化，省去逐写诊断日志
  /// （防抖保存流会大量触发，刷屏应用日志）。
  static Future<void> writeJsonAtomicQuiet(File target, Object value) =>
      _writeJsonAtomic(target, value, quiet: true);

  /// 等待 [target] 当前在途的原子写落定（无在途写立即完成；写失败不
  /// 抛——等待方只关心"没有悬空的写"）。删除方（账本撤账等）调用，
  /// 避免删除先于在途写的 rename 执行、刚删的文件又被写回。
  static Future<void> awaitPendingWrite(File target) {
    final pending = _pendingWrites[target.path];
    if (pending == null) return Future<void>.value();
    return pending.then<void>((_) {}, onError: (_, __) {});
  }

  /// 等待当前全部在途原子写落定（快照等待：等待期间新入队的写不追）。
  /// 全书级删除/对账前调用。
  static Future<void> drainPendingWrites() async {
    final pending = [for (final f in _pendingWrites.values) f];
    for (final f in pending) {
      await f.then<void>((_) {}, onError: (_, __) {});
    }
  }

  static Future<dynamic> _readJsonWithRecovery(
    File target, {
    bool debugLog = false,
  }) async {
    final pending = _pendingWrites[target.path];
    if (pending != null) {
      await pending.then<void>((_) {}, onError: (_, __) {});
    }
    final candidates = <File>[
      target,
      File('${target.path}.bak'),
      File('${target.path}.tmp'),
    ];
    Object? lastError;
    for (final file in candidates) {
      if (!await file.exists()) continue;
      try {
        final text = await file.readAsString();
        if (text.trim().isEmpty) {
          throw const FormatException('Empty JSON document');
        }
        if (!identical(file, target)) {
          // 主文件读取失败、从备份恢复：内容是上一次成功保存的版本，
          // 恰好撞上写盘的 rename 窗口时表现为"刚保存的修改消失了"。
          PythonService.addAppLog(
            '[保存诊断] ⚠ ${p.basename(target.path)} 主文件不可读'
            '（$lastError），回退${p.basename(file.path)}旧版本',
            isError: true,
          );
        }
        if (debugLog) {
          // 读取指纹 + 三个候选文件的现场快照：与写入侧 fp 对不上时，
          // 可确凿定位"读到旧版"到底来自哪个文件（或文件在读取时刻
          // 就已经是旧内容——指向外部程序改写）。
          final sizes = <String>[];
          for (final probe in candidates) {
            try {
              sizes.add(
                '${probe == target ? "主" : p.basename(probe.path).split(".").last}'
                '${await probe.exists() ? "=${(await probe.length())}" : "=无"}',
              );
            } catch (_) {
              sizes.add('?');
            }
          }
          PythonService.addAppLog(
            '[保存诊断] 读取 ${p.basename(target.path)} '
            '来源=${identical(file, target) ? "主文件" : p.basename(file.path)} '
            'bytes=${text.length} fp=0x${text.hashCode.toRadixString(16)} '
            '候选[$sizes.join(" ")]',
          );
        }
        return jsonDecode(text);
      } catch (error) {
        lastError = error;
      }
    }
    if (lastError != null) throw lastError;
    throw const FileSystemException('JSON file does not exist');
  }

  static Future<void> save(Project project) async {
    final dir = Directory(project.projectDir);
    if (!await dir.exists()) await dir.create(recursive: true);
    final f = File(p.join(project.projectDir, 'project.json'));
    await _writeJsonAtomic(f, project.toJson());
  }

  static Future<void> saveAnnotation(
    String projectDir,
    PageAnnotation ann, {
    /// 机器写盘（整本识别/按主区拆分逐页落盘）：训练数据内容层从未确认
    /// 变确认，抑制自动增量导出调度——批量任务数秒一页连跑数小时，不
    /// 抑制会让后台反复全库扫描空转。人工确认路径（编辑器/主区快设/
    /// 众包导入等）不传，照常"确认即入账"。
    bool machineWrite = false,
  }) async {
    final dir = Directory(p.join(projectDir, 'annotations'));
    if (!await dir.exists()) await dir.create(recursive: true);
    final f = File(p.join(projectDir, 'annotations', '${ann.pageId}.json'));
    await _writeJsonAtomic(f, ann.toJson());
    // 文字汇总账本咽喉点：全部确认保存 / 重识别覆盖写（任何页面入口）
    // 都经过这里——reviewed 记账，非 reviewed 撤账。失败只记日志。
    unawaited(CharStatsService.syncPage(projectDir, ann));
    // 训练数据统计咽喉点：确认类保存（含主区快设的区域确认）触发防抖
    // 增量导出，统计随确认增长（见 TrainExportScheduler）。
    if (!machineWrite) {
      TrainExportScheduler.onAnnotationSaved(projectDir, ann);
    }
  }

  static Future<PageAnnotation?> loadAnnotation(
    String projectDir,
    String pageId, {
    bool debugLog = false,

    /// When supplied, an annotation is valid only if it belongs to this
    /// exact source image.  Page ids are derived from filenames and can be
    /// reused after split/delete operations; without this guard a stale
    /// annotation for another image is silently shown for the current page.
    String? expectedImagePath,
  }) async {
    final f = File(p.join(projectDir, 'annotations', '$pageId.json'));
    try {
      final decoded = await _readJsonWithRecovery(f, debugLog: debugLog);
      if (decoded is! Map) return null;
      final raw = Map<String, dynamic>.from(decoded);
      if (expectedImagePath != null &&
          !_sameImagePath(raw['image_path']?.toString(), expectedImagePath)) {
        PythonService.addAppLog(
          '[载入诊断] 丢弃错配标注 $pageId：'
          '标注=${raw['image_path'] ?? '<空>'} 当前=$expectedImagePath',
          isError: true,
        );
        return null;
      }
      return PageAnnotation.fromJson(raw);
    } catch (_) {
      // A half-written or manually edited annotation must not terminate page
      // navigation.  The caller can recreate the page annotation instead.
      return null;
    }
  }

  /// Windows paths are case-insensitive and may use either slash style.
  /// Comparing normalized absolute strings is sufficient here; the backend
  /// source hash is intentionally not recomputed during page-list scans.
  static bool _sameImagePath(String? stored, String expected) {
    if (stored == null || stored.trim().isEmpty) return false;
    String normalize(String value) =>
        File(value).absolute.path.replaceAll('/', '\\').toLowerCase();
    return normalize(stored) == normalize(expected);
  }

  /// Indices of pages whose annotation file exists on disk. File presence is
  /// the "page has been recognized" marker used by the batch queue to resume
  /// an interrupted whole-book run; no JSON parsing involved.
  static Future<Set<int>> savedAnnotationIndices(
    String projectDir,
    int pageCount, {
    List<String>? imageFiles,
  }) async {
    final done = <int>{};
    final dir = Directory(p.join(projectDir, 'annotations'));
    if (!await dir.exists()) return done;
    for (var i = 0; i < pageCount; i++) {
      final pageId = imageFiles != null && i < imageFiles.length
          ? pageIdForImage(imageFiles[i], i)
          : pageIdForIndex(i);
      final f = File(p.join(dir.path, '$pageId.json'));
      if (!await f.exists()) continue;
      // File presence alone is not a safe resume marker after pages have been
      // split, deleted, or reordered.  Read the small JSON header and only
      // count it when it belongs to the image currently at this index.
      if (imageFiles != null && i < imageFiles.length) {
        try {
          final raw = await _readJsonWithRecovery(f);
          if (raw is! Map ||
              !_sameImagePath(raw['image_path']?.toString(), imageFiles[i])) {
            PythonService.addAppLog(
              '[识别队列] 跳过错配断点 $pageId：'
              '标注=${raw is Map ? raw['image_path'] : '<无效 JSON>'} '
              '当前=${imageFiles[i]}',
              isError: true,
            );
            continue;
          }
        } catch (_) {
          continue;
        }
      }
      done.add(i);
    }
    return done;
  }

  /// 「全书重新识别」：删除全部页标注文件——书回到"新加入"状态（所有页
  /// 未确认未保存、无识别框），识别队列按断点逻辑自然从头跑全部页。
  /// 目录不存在时为空操作。
  static Future<void> clearAllAnnotations(String projectDir) async {
    final dir = Directory(p.join(projectDir, 'annotations'));
    if (!await dir.exists()) return;
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // 单个文件被占用删不掉时兜底逐个删（保证队列不会因此跳页）。
      await for (final e in dir.list()) {
        if (e is File) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    }
    // 全书重新识别：本书全部已确认页从文字汇总账本撤账（所有页的
    // 确认成果重来）。删除整本书不走这里，账目按需求保留。
    unawaited(CharStatsService.removeProject(projectDir));
  }

  /// 一次性迁移：把"删除页"造成的错位标注文件归位。
  ///
  /// 旧版删页逻辑把标注文件按 imageFiles 下标前移重命名，但文件内容
  /// 的 page_id 与图片文件名未动——文件名页号 ≠ 内容页号的文件由此产
  /// 生（保存按内容页号写新文件、读取按下标读旧文件，读写分裂）。以
  /// 内容 page_id 为准归位：目标名已有文件（用户更新的新版）则把错位
  /// 文件改名为 .legacy 保留，否则直接改名。
  static Future<void> migrateMisalignedAnnotations(String projectDir) async {
    final dir = Directory(p.join(projectDir, 'annotations'));
    final marker = File(p.join(dir.path, '.migrated_v1'));
    if (!await dir.exists() || await marker.exists()) return;
    await for (final entry in dir.list()) {
      if (entry is! File) continue;
      final name = p.basename(entry.path);
      if (!name.endsWith('.json')) continue;
      final stem = name.substring(0, name.length - 5);
      if (!RegExp(r'^page_\d{3,}$').hasMatch(stem)) continue;
      try {
        final decoded = jsonDecode(await entry.readAsString());
        if (decoded is! Map) continue;
        final contentId = decoded['page_id']?.toString() ?? '';
        if (contentId.isEmpty ||
            !RegExp(r'^page_\d{3,}$').hasMatch(contentId) ||
            contentId == stem) {
          continue;
        }
        final target = File(p.join(dir.path, '$contentId.json'));
        final legacy = File('${entry.path}.legacy');
        if (await target.exists()) {
          // 目标文件已存在（用户编辑保存的新版）：错位旧版改名保留。
          await entry.rename(legacy.path);
        } else {
          await entry.rename(target.path);
        }
        PythonService.addAppLog(
          '[保存诊断] 迁移错位标注：$name → $contentId.json'
          '${await legacy.exists() ? '（目标已存在，旧版存为 .legacy）' : ''}',
        );
      } catch (_) {
        // 单个文件损坏不阻断迁移。
      }
    }
    await marker.writeAsString(DateTime.now().toIso8601String());
  }

  static Future<List<Project>> loadAll(String rootDir) async {
    final dir = Directory(rootDir);
    if (!await dir.exists()) return [];
    final projects = <Project>[];
    await for (final entry in dir.list()) {
      if (entry is Directory) {
        // 下划线开头的是书库内部目录（_realign_backups 备份等），里面
        // 可能带 project.json 副本——不是书，跳过，否则首页会把每本书
        // 显示成两张卡片。
        if (p.basename(entry.path).startsWith('_')) continue;
        final f = File(p.join(entry.path, 'project.json'));
        final hasRecoveryFile =
            await f.exists() ||
            await File('${f.path}.bak').exists() ||
            await File('${f.path}.tmp').exists();
        if (hasRecoveryFile) {
          try {
            final decoded = await _readJsonWithRecovery(f);
            if (decoded is Map) {
              projects.add(
                Project.fromJsonMap(Map<String, dynamic>.from(decoded)),
              );
            }
          } catch (_) {
            // Ignore an incomplete project and keep loading the remaining
            // projects.  This can happen if the app was closed during save.
          }
        }
      }
    }
    return projects;
  }

  /// 清理"导入中断"留下的孤儿项目目录：导入在复制/转图阶段应用退出时，
  /// 目录已建但 project.json 还没写——这些目录不出现在书列表里，却永久
  /// 占着磁盘（实测一次大 PDF 导入可留 1~3GB，书库曾累积约 11GB）。
  ///
  /// 安全边界：只删目录名为纯数字（项目 ID 是毫秒时间戳）且无
  /// project.json、且 [cutoff]（默认 1 小时前）之前无修改的目录——进行
  /// 中的导入（先建目录后写 project.json）与书库内部目录（char_stats、
  /// _realign_backups 等非数字名）都不会误伤。返回 (删除数, 释放 MB)。
  static Future<({int removed, int freedMb})> purgeOrphanProjectDirs(
    String root, {
    DateTime? cutoff,
  }) async {
    var removed = 0;
    var freedBytes = 0;
    try {
      final dir = Directory(root);
      if (!await dir.exists()) return (removed: 0, freedMb: 0);
      final effectiveCutoff =
          cutoff ?? DateTime.now().subtract(const Duration(hours: 1));
      final orphans = <Directory>[];
      await for (final entry in dir.list()) {
        if (entry is! Directory) continue;
        if (!RegExp(r'^\d+$').hasMatch(p.basename(entry.path))) continue;
        if (await File(p.join(entry.path, 'project.json')).exists()) continue;
        final stat = await entry.stat();
        if (stat.modified.isAfter(effectiveCutoff)) continue;
        orphans.add(entry);
      }
      for (final orphan in orphans) {
        try {
          await for (final f in orphan.list(
            recursive: true,
            followLinks: false,
          )) {
            if (f is File) {
              try {
                freedBytes += await f.length();
              } catch (_) {}
            }
          }
          await orphan.delete(recursive: true);
          removed++;
        } catch (_) {
          // 单个目录删除失败（文件被占用等）不影响其余清理。
        }
      }
    } catch (_) {
      // 清理是尽力而为：任何失败都不影响书库加载。
    }
    return (removed: removed, freedMb: freedBytes ~/ (1 << 20));
  }
}
