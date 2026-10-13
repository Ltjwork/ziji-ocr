import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../models/models.dart';
import 'python_service.dart';
import 'storage.dart';

/// 文字汇总账本的一次聚合结果。
class CharStatsSummary {
  /// 字符 -> 全库总出现次数。
  final Map<String, int> charCounts;

  /// 账本条目数 = 曾经计入统计的已确认页数（含已删除书籍的页）。
  final int pageCount;

  /// 贡献过统计的项目 id（含已删除书籍）。
  final Set<String> bookIds;

  const CharStatsSummary({
    required this.charCounts,
    required this.pageCount,
    required this.bookIds,
  });

  int get totalChars =>
      charCounts.values.fold(0, (sum, n) => sum + n);

  bool get isEmpty => pageCount == 0;
}

/// 一本书的正确识别率聚合（账本 accuracy 字段求和）。
class BookAccuracy {
  const BookAccuracy({required this.total, required this.fixed});

  /// 已确认且来自识别（origText 非空）的字数——正确率分母。
  final int total;

  /// 其中识别后被修改过的字数（text != origText）。
  final int fixed;

  /// 正确识别率（0~1）；total 为 0 时为 null（尚无统计口径内的页）。
  double? get rate => total <= 0 ? null : (total - fixed) / total;
}

/// 全局字频账本「char_stats」：统计所有校对确认过的页面里出现过的字
/// 与次数。账本放在书籍数据根目录下的独立目录（`<数据根>/char_stats/`），
/// **不在任何项目目录里**——删除整本书（删项目目录）不影响统计；账目
/// 按"项目 × 页"一页一记，汇总时聚合求和，账本即唯一真相。
///
/// 记账/撤账规则（挂钩点见 storage.saveAnnotation / clearAllAnnotations
/// 与各删页/拆分入口）：
/// - 任何 reviewed=true 的标注保存（确认并保存、墨迹归类组确认、众包
///   回填……）→ 建立/覆盖该页账目；重复确认幂等不重复计数；
/// - 页面重新识别（新标注 reviewed=false 覆盖写）、单页删除、全书
///   重新识别 → 撤销该页（或该书全部）账目；
/// - 页面集合变化（跨页拆分落定/失败/恢复拆分前）→ reconcileProject
///   按当前 imageFiles 对账，不在册页号的账目删除。
///
/// 账目还带一份正确识别率口径（`accuracy` 字段）：已确认字里来自识别
/// 的总数（total）与识别后被修改过的字数（fixed），按书聚合见
/// [bookAccuracy]。口径：分母只计 origText 非空的字（识别产出后被
/// 确认）；人工新画字框与旧版数据的字没有基线，不计入。
class CharStatsService {
  /// 「最近一次写入的账目」内存缓存（账本文件路径 -> 字频+正确率）：
  /// 防抖保存流里大量保存不改变内容（纯几何编辑），比对后跳过写盘。
  static final Map<String, ({Map<String, int> counts, int total, int fixed})>
      _lastCounts = {};

  /// 每条账目（账本文件路径）的在途记账任务链：saveAnnotation 尾部
  /// fire-and-forget 触发，removePage 需要等它落定再删——否则「确认
  /// 保存 → 立刻删页」里删除先执行（此时记账写甚至还没入队），在途
  /// 写随后把刚删的账目写回复活。
  static final Map<String, Future<void>> _syncInFlight = {};

  static Directory ledgerRoot(String dataRoot) =>
      Directory(p.join(dataRoot, 'char_stats'));

  static String _dataRootOf(String projectDir) => p.dirname(projectDir);

  static String _projectIdOf(String projectDir) => p.basename(projectDir);

  static File _entryFile(String dataRoot, String projectId, String pageId) =>
      File(p.join(dataRoot, 'char_stats', '${projectId}__$pageId.json'));

  /// 统计一页的已确认文字：正文与批注都计入（口径与墨迹模板的仅正文
  /// 不同，为本功能有意选择），排除 ignore 块与空文字；确认判定兼容
  /// status/confirmed 两种标记；多字 text 逐字符计数。
  static Map<String, int> countConfirmedChars(PageAnnotation ann) {
    final counts = <String, int>{};
    // 以 lines 为准（blocks 是派生扁平表，重切割后可能短暂滞后）；
    // 旧数据无 lines 时回退 blocks（fromJson 已推断过 lines，仅防御）。
    final chars = ann.lines.isNotEmpty
        ? ann.lines.expand((l) => l.chars)
        : ann.blocks;
    for (final block in chars) {
      if (block.type == 'ignore') continue;
      if (!(block.confirmed || block.status == AnnotationStatus.confirmed)) {
        continue;
      }
      final text = block.text.trim();
      if (text.isEmpty) continue;
      for (final rune in text.runes) {
        final ch = String.fromCharCode(rune);
        counts[ch] = (counts[ch] ?? 0) + 1;
      }
    }
    return counts;
  }

  /// 正确识别率口径的一页统计：total=已确认且来自识别（origText 非空）
  /// 的字数，fixed=其中识别后被修改过的字数（trim 后 text != origText）。
  /// 人工新画字框与旧版数据的字没有基线（origText 空），不计入分母。
  static ({int total, int fixed}) countAccuracy(PageAnnotation ann) {
    var total = 0;
    var fixed = 0;
    final chars = ann.lines.isNotEmpty
        ? ann.lines.expand((l) => l.chars)
        : ann.blocks;
    for (final block in chars) {
      if (block.type == 'ignore') continue;
      if (!(block.confirmed || block.status == AnnotationStatus.confirmed)) {
        continue;
      }
      if (block.origText.isEmpty) continue;
      total++;
      if (block.text.trim() != block.origText.trim()) fixed++;
    }
    return (total: total, fixed: fixed);
  }

  /// 保存咽喉点挂钩（storage.saveAnnotation 尾部调用，fire-and-forget）：
  /// reviewed 页记账（字频无变化则跳过写盘），非 reviewed 保存（重新识别
  /// 覆盖写）撤账。同一账目串行（在途任务链），任何失败只记应用日志，
  /// 不影响标注保存主流程。
  static Future<void> syncPage(String projectDir, PageAnnotation ann) {
    final key = _entryFile(
      _dataRootOf(projectDir),
      _projectIdOf(projectDir),
      ann.pageId,
    ).path;
    final previous = _syncInFlight[key];
    // 链式执行且把错误吞在链内（内部已记日志），保证后续任务不因前者
    // 失败而中断。清理必须在 task 声明完成后再挂接：whenComplete 若写
    // 在初始化表达式里会自引用（referenced_before_declaration，Dart 禁
    // 止局部变量在自身初始化式中被闭包引用）。
    final task = (previous ?? Future<void>.value())
        .then((_) => _syncPageNow(projectDir, ann))
        .then<void>((_) {}, onError: (_, __) {});
    _syncInFlight[key] = task;
    task.whenComplete(() {
      if (identical(_syncInFlight[key], task)) _syncInFlight.remove(key);
    });
    return task;
  }

  static Future<void> _syncPageNow(String projectDir, PageAnnotation ann) async {
    try {
      final counts = ann.reviewed
          ? countConfirmedChars(ann)
          : const <String, int>{};
      final accuracy = ann.reviewed
          ? countAccuracy(ann)
          : const (total: 0, fixed: 0);
      if (counts.isEmpty) {
        await _removePageNow(projectDir, ann.pageId);
        return;
      }
      final dataRoot = _dataRootOf(projectDir);
      final file = _entryFile(dataRoot, _projectIdOf(projectDir), ann.pageId);
      final cached = _lastCounts[file.path];
      if (cached != null &&
          _sameCounts(cached.counts, counts) &&
          cached.total == accuracy.total &&
          cached.fixed == accuracy.fixed) {
        return;
      }
      final dir = Directory(p.dirname(file.path));
      if (!await dir.exists()) await dir.create(recursive: true);
      final payload = <String, dynamic>{
        'project': _projectIdOf(projectDir),
        'page': ann.pageId,
        'chars': counts,
        if (accuracy.total > 0)
          'accuracy': {'total': accuracy.total, 'fixed': accuracy.fixed},
        'updated': DateTime.now().toIso8601String(),
      };
      // Windows 上杀毒/索引器会瞬时锁住刚写出的文件（rename 报 errno 32，
      // 见编辑器写链同类注释），短暂退避重试，避免账目停留在旧值。
      Object? lastError;
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          await ProjectStorage.writeJsonAtomicQuiet(file, payload);
          lastError = null;
          break;
        } catch (error) {
          lastError = error;
          if (attempt < 2) {
            await Future<void>.delayed(const Duration(milliseconds: 60));
          }
        }
      }
      if (lastError != null) throw lastError;
      _lastCounts[file.path] = (
        counts: counts,
        total: accuracy.total,
        fixed: accuracy.fixed,
      );
    } catch (error) {
      PythonService.addAppLog(
        '[文字汇总] ⚠ 账本写入失败（${ann.pageId}）：$error',
        isError: true,
      );
    }
  }

  /// 撤销一页账目（单页删除 / 页面重新识别的覆盖保存）：先等该条目
  /// 在途的记账任务与其排队中的原子写落定，再删——否则「确认保存 →
  /// 立刻删页/重识别」里删除先执行，在途写随后把账目写回复活。
  static Future<void> removePage(String projectDir, String pageId) async {
    try {
      final file = _entryFile(
        _dataRootOf(projectDir),
        _projectIdOf(projectDir),
        pageId,
      );
      _lastCounts.remove(file.path);
      final inFlight = _syncInFlight[file.path];
      if (inFlight != null) await inFlight; // 链内已吞错，不会抛
      await ProjectStorage.awaitPendingWrite(file);
      await _removePageNow(projectDir, pageId);
    } catch (error) {
      PythonService.addAppLog(
        '[文字汇总] ⚠ 账目删除失败（$pageId）：$error',
        isError: true,
      );
    }
  }

  /// 条目删除本体（调用方已与在途任务/写串行；记账链内部撤账走这里
  /// ——若走公共 removePage 会等待自己所在的链，死锁）。
  static Future<void> _removePageNow(String projectDir, String pageId) async {
    final file = _entryFile(
      _dataRootOf(projectDir),
      _projectIdOf(projectDir),
      pageId,
    );
    // 原子写的伴生 .bak/.tmp 一并清理，不留可恢复读取的残留。
    for (final suffix in ['', '.bak', '.tmp']) {
      final f = File('${file.path}$suffix');
      if (await f.exists()) await f.delete();
    }
  }

  /// 等当前全部在途记账任务落定（快照等待）。全书级撤账/对账前调用。
  static Future<void> _awaitAllSyncInFlight() async {
    final pending = [for (final f in _syncInFlight.values) f];
    for (final f in pending) {
      await f; // 链内已吞错
    }
  }

  /// 撤销一本书的全部账目（全书重新识别：所有页的确认成果重来）。
  /// 删除整本书**不**走这里——项目目录删除即结束，账目按需求保留。
  static Future<void> removeProject(String projectDir) async {
    try {
      // 先等在途记账任务与账目写落定再扫描删除，避免删后又被写回复活。
      await _awaitAllSyncInFlight();
      await ProjectStorage.drainPendingWrites();
      final prefix = '${_projectIdOf(projectDir)}__';
      final root = ledgerRoot(_dataRootOf(projectDir));
      if (!await root.exists()) return;
      await for (final entry in root.list()) {
        if (entry is! File) continue;
        if (!p.basename(entry.path).startsWith(prefix)) continue;
        _lastCounts.remove(entry.path);
        try {
          await entry.delete();
        } catch (_) {
          // 单个文件被占用删不掉不阻断其余账目。
        }
      }
    } catch (error) {
      PythonService.addAppLog(
        '[文字汇总] ⚠ 项目账目清空失败（${p.basename(projectDir)}）：$error',
        isError: true,
      );
    }
  }

  /// 页面集合对账：账本中不属于当前 imageFiles 推导页号的条目删除。
  /// 调用方：跨页拆分落定（源跨页被半页取代）、拆分失败/取消（本轮已
  /// 写出的半页成孤儿）、恢复拆分前（输出页退场）。
  static Future<void> reconcileProject(
    String projectDir,
    List<String> imageFiles,
  ) async {
    try {
      // 先等在途记账任务与账目写落定再对账（拆分循环里 saveAnnotation
      // 钩子的记账写可能还在链上）。
      await _awaitAllSyncInFlight();
      await ProjectStorage.drainPendingWrites();
      final prefix = '${_projectIdOf(projectDir)}__';
      final root = ledgerRoot(_dataRootOf(projectDir));
      if (!await root.exists()) return;
      final live = <String>{
        for (var i = 0; i < imageFiles.length; i++)
          pageIdForImage(imageFiles[i], i),
      };
      await for (final entry in root.list()) {
        if (entry is! File) continue;
        final name = p.basename(entry.path);
        if (!name.startsWith(prefix)) continue;
        var stem = name.substring(prefix.length);
        for (final suffix in ['.json.bak', '.json.tmp', '.json']) {
          if (stem.endsWith(suffix)) {
            stem = stem.substring(0, stem.length - suffix.length);
            break;
          }
        }
        if (live.contains(stem)) continue;
        _lastCounts.remove(entry.path);
        try {
          await entry.delete();
        } catch (_) {}
      }
    } catch (error) {
      PythonService.addAppLog(
        '[文字汇总] ⚠ 页面集合对账失败（${p.basename(projectDir)}）：$error',
        isError: true,
      );
    }
  }

  /// 按盘上标注文件重建一页账目（恢复拆分前的源页重入账、存量回填共用）：
  /// 带图片匹配守卫读取，读到 reviewed 页则记账，否则撤账。
  static Future<void> syncPageFromDisk(
    String projectDir,
    String imagePath,
    int index,
  ) async {
    final pageId = pageIdForImage(imagePath, index);
    final ann = await ProjectStorage.loadAnnotation(
      projectDir,
      pageId,
      expectedImagePath: imagePath,
    );
    if (ann == null) {
      await removePage(projectDir, pageId);
      return;
    }
    await syncPage(projectDir, ann);
  }

  /// 升级后的一次性存量回填：把现有书籍里全部 reviewed 页计入账本
  /// （.backfilled 标记防重跑，仿 .migrated_v1 模式）。只认 imageFiles
  /// 中现存的页（带图片守卫），拆分源页等孤儿标注文件不计入。中途
  /// 失败不写标记，下次启动重试。
  static Future<void> backfillOnce(String dataRoot, List<Project> projects) async {
    try {
      final root = ledgerRoot(dataRoot);
      final marker = File(p.join(root.path, '.backfilled'));
      if (await marker.exists()) return;
      if (!await root.exists()) await root.create(recursive: true);
      var pages = 0;
      for (final proj in projects) {
        for (var i = 0; i < proj.imageFiles.length; i++) {
          final pageId = pageIdForImage(proj.imageFiles[i], i);
          final ann = await ProjectStorage.loadAnnotation(
            proj.projectDir,
            pageId,
            expectedImagePath: proj.imageFiles[i],
          );
          if (ann == null || !ann.reviewed) continue;
          if (countConfirmedChars(ann).isEmpty) continue;
          await syncPage(proj.projectDir, ann);
          pages++;
        }
      }
      await marker.writeAsString(DateTime.now().toIso8601String());
      if (pages > 0) {
        PythonService.addAppLog(
          '[文字汇总] 存量回填完成：$pages 个已确认页计入字频账本',
        );
      }
    } catch (error) {
      PythonService.addAppLog(
        '[文字汇总] ⚠ 存量回填失败（下次启动重试）：$error',
        isError: true,
      );
    }
  }

  /// 聚合全账本：字频表 + 收录页数 + 贡献书籍集合。统计页打开/刷新时
  /// 调用；账本条目为小文件，聚合即求和，无冗余总计文件可失步。
  static Future<CharStatsSummary> summary(String dataRoot) async {
    final counts = <String, int>{};
    final books = <String>{};
    var pages = 0;
    final root = ledgerRoot(dataRoot);
    if (!await root.exists()) {
      return CharStatsSummary(charCounts: counts, pageCount: 0, bookIds: books);
    }
    await for (final entry in root.list()) {
      if (entry is! File) continue;
      final name = p.basename(entry.path);
      if (!name.endsWith('.json') || name.startsWith('.')) continue;
      try {
        final decoded = jsonDecode(await entry.readAsString());
        if (decoded is! Map) continue;
        final project = decoded['project']?.toString();
        if (project != null && project.isNotEmpty) books.add(project);
        final chars = decoded['chars'];
        if (chars is! Map) continue;
        var hasChars = false;
        for (final e in chars.entries) {
          final ch = e.key.toString();
          final n = e.value is num ? (e.value as num).toInt() : 0;
          if (ch.isEmpty || n <= 0) continue;
          counts[ch] = (counts[ch] ?? 0) + n;
          hasChars = true;
        }
        // 半写损坏条目（chars 缺失）不计页数。
        if (hasChars) pages++;
      } catch (_) {
        // 单个损坏条目跳过，聚合不被中断。
      }
    }
    return CharStatsSummary(charCounts: counts, pageCount: pages, bookIds: books);
  }

  /// 按书聚合正确识别率（账本 accuracy 字段求和）。total 为 0 表示该书
  /// 还没有统计口径内的确认页（未确认过，或全部是旧版数据/人工字）。
  static Future<BookAccuracy> bookAccuracy(
    String dataRoot,
    String projectId,
  ) async {
    var total = 0;
    var fixed = 0;
    final root = ledgerRoot(dataRoot);
    final prefix = '${projectId}__';
    if (!await root.exists()) {
      return BookAccuracy(total: total, fixed: fixed);
    }
    await for (final entry in root.list()) {
      if (entry is! File) continue;
      final name = p.basename(entry.path);
      if (!name.startsWith(prefix) || !name.endsWith('.json')) continue;
      if (name.startsWith('.')) continue;
      try {
        final decoded = jsonDecode(await entry.readAsString());
        if (decoded is! Map) continue;
        final acc = decoded['accuracy'];
        if (acc is! Map) continue;
        total += (acc['total'] as num?)?.toInt() ?? 0;
        fixed += (acc['fixed'] as num?)?.toInt() ?? 0;
      } catch (_) {
        // 单个损坏条目跳过，聚合不被中断。
      }
    }
    return BookAccuracy(total: total, fixed: fixed);
  }

  static bool _sameCounts(Map<String, int> a, Map<String, int> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }
}
