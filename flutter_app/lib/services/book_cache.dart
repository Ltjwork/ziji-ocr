import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../models/models.dart';
import 'page_state_markers.dart';
import 'python_service.dart';
import 'storage.dart';

/// 书目录级缓存（打开加速）。两个独立缓存，同一设计纪律：
/// - **按内容指纹失效**：只有真正影响结果的输入变化才重建；
/// - **损坏即重建**：缓存文件读不出来/版本不符就当没有，全量重算一次；
/// - 缓存文件是纯派生数据，删掉任何时候都安全。
///
/// ① 页状态缓存 [PageStateCache]：编辑器页状态标记（绿/玫红/橘黄/紫框）、
/// 首页校对计数、各层训练进度计数此前每次都逐页解析整本书的标注 JSON
/// （520 页 × ~120KB，且编辑器打开时标记与进度两条链路各扫一遍）；
/// 现按「标注文件 mtime+size + 对应图片路径」缓存每页派生状态与计数，
/// 未变化的页只 stat 不解析。同一书目录的在途加载共享（并发首载只
/// 解析一遍）。
///
/// ② 聚类缓存 [ClusterCache]：全书墨迹归类此前每次打开都重跑后端聚类
/// （520 页实测 142 秒）；现按「页范围 + 阈值 + 每页几何摘要」缓存分组
/// 结果——文字、确认状态、特殊字标记都不参与墨迹形态聚类，改字不
/// 失效；字块几何增删改或换图才失效。

// ─── ① 页状态缓存 ────────────────────────────────────────────────────────────

/// 单页派生计数（与编辑器书进度卡/训练统计同口径）。
class PageCounters {
  /// 已确认（或「确认识别框」）的正文区/段/行/字框检测样本数。
  final int regionDet;
  final int paragraphDet;
  final int lineDet;
  final int charDet;

  /// 分类样本数（完全确认的单字标签）与其字表（去重前的文字列表）。
  final int charCls;
  final List<String> charTexts;

  const PageCounters({
    required this.regionDet,
    required this.paragraphDet,
    required this.lineDet,
    required this.charDet,
    required this.charCls,
    required this.charTexts,
  });

  static const empty = PageCounters(
    regionDet: 0,
    paragraphDet: 0,
    lineDet: 0,
    charDet: 0,
    charCls: 0,
    charTexts: [],
  );

  /// 从标注直接计数（编辑器当前页以内存标注覆盖缓存时用）。
  factory PageCounters.of(PageAnnotation ann) {
    // 已确认排除类区（页眉/页脚/页码/图/表）内的框不计入内容层——与
    // 训练导出（train_datasets.page_labels/char_cls_page_items）同口径：
    // 页眉页脚只作 region_det 标注。region_det 本身照常计全部已确认区。
    final regionDet = ann.mainRegions
        .where((r) => r.status == AnnotationStatus.confirmed || r.boxConfirmed)
        .length;
    final paragraphDet = ann.paragraphs
        .where(
          (p) =>
              (p.status == AnnotationStatus.confirmed || p.boxConfirmed) &&
              !ann.centerInConfirmedExcluded(p.x, p.y, p.w, p.h),
        )
        .length;
    final lineDet = ann.lines
        .where(
          (l) =>
              (l.status == AnnotationStatus.confirmed || l.boxConfirmed) &&
              !ann.centerInConfirmedExcluded(l.x, l.y, l.w, l.h),
        )
        .length;
    final charDet = ann.blocks
        .where(
          (b) =>
              (b.status == AnnotationStatus.confirmed || b.boxConfirmed) &&
              b.type != 'ignore' &&
              !ann.centerInConfirmedExcluded(b.x, b.y, b.w, b.h),
        )
        .length;
    // 分类口径与训练导出一致：完全确认的单字标签，且父行也已确认。
    final chars = ann.lines
        .where(
          (l) =>
              l.status == AnnotationStatus.confirmed &&
              !ann.centerInConfirmedExcluded(l.x, l.y, l.w, l.h),
        )
        .expand((l) => l.chars)
        .where(
            (c) =>
                c.status == AnnotationStatus.confirmed &&
                c.type != 'ignore' &&
                c.text.trim().runes.length == 1)
        .toList();
    return PageCounters(
      regionDet: regionDet,
      paragraphDet: paragraphDet,
      lineDet: lineDet,
      charDet: charDet,
      charCls: chars.length,
      charTexts: [
        for (final t in chars.map((c) => c.text.trim()))
          if (t.isNotEmpty) t,
      ],
    );
  }
}

/// 全书一次加载的汇总：页状态标记 + 已确认页数 + 每页计数。
class PageStateSummary {
  final PageStateMarkers markers;
  final int reviewedCount;

  /// 页下标 → 计数（无标注/无条目的页不在表里）。
  final Map<int, PageCounters> countersByPage;

  const PageStateSummary({
    required this.markers,
    required this.reviewedCount,
    required this.countersByPage,
  });
}

/// 每页缓存条目：标注文件指纹（mtime/size）+ 图片路径 + 派生状态。
/// state: 0=无状态 / 1=已确认(saved) / 2=临时保存(draft) / 3=有框未确认 /
/// 4=确认识别框(boxes，文字未确认)。
class _PageEntry {
  final int mtimeMs;
  final int size;
  final String imagePath;
  final int state;
  final bool reviewed;
  final PageCounters counters;

  const _PageEntry({
    required this.mtimeMs,
    required this.size,
    required this.imagePath,
    required this.state,
    required this.reviewed,
    required this.counters,
  });

  Map<String, dynamic> toJson() => {
    'm': mtimeMs,
    's': size,
    'img': imagePath,
    'f': state,
    'r': reviewed,
    'rd': counters.regionDet,
    'pd': counters.paragraphDet,
    'ld': counters.lineDet,
    'cd': counters.charDet,
    'cc': counters.charCls,
    if (counters.charTexts.isNotEmpty) 't': counters.charTexts,
  };

  static _PageEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    final m = j['m'], s = j['s'];
    if (m is! int || s is! int) return null;
    int asInt(Object? v) => v is int ? v : 0;
    return _PageEntry(
      mtimeMs: m,
      size: s,
      imagePath: j['img']?.toString() ?? '',
      state: asInt(j['f']),
      reviewed: j['r'] == true,
      counters: PageCounters(
        regionDet: asInt(j['rd']),
        paragraphDet: asInt(j['pd']),
        lineDet: asInt(j['ld']),
        charDet: asInt(j['cd']),
        charCls: asInt(j['cc']),
        charTexts: [
          for (final t in (j['t'] as List? ?? const [])) t.toString(),
        ],
      ),
    );
  }
}

class PageStateCache {
  // v3：内容层计数排除已确认排除类区（页眉/页脚等）内的框（与训练
  // 导出同口径）——旧缓存的内容层计数口径不同，升版全部重算一次。
  static const _version = 3;
  static const _fileName = 'page_state_cache.json';

  /// 同一书目录的在途加载共享：编辑器打开时页状态标记与书进度两条
  /// 链路并发触发，首载只解析一遍（相差几百毫秒内的数据对两者都够新）。
  static final Map<String, Future<PageStateSummary>> _inFlight = {};

  static File _file(String projectDir) => File(p.join(projectDir, _fileName));

  static Future<PageStateSummary> load(Project project) {
    final key = project.projectDir;
    final existing = _inFlight[key];
    if (existing != null) return existing;
    // 回调必须用语句体：whenComplete 会等待回调返回的 Future，
    // 写成 `() => _inFlight.remove(key)` 会把存进去的 future 自己
    // 返回出去——等待自己完成，永久死锁。
    final future = _load(project).whenComplete(() {
      _inFlight.remove(key);
    });
    _inFlight[key] = future;
    return future;
  }

  /// 指纹命中的页只 stat 标注文件；指纹变化（保存/确认/迁移改名）或
  /// 首次见到的页才解析 JSON 并回写缓存。
  static Future<PageStateSummary> _load(Project project) async {
    final cached = await _read(project.projectDir);
    final markers = PageStateMarkers();
    final countersByPage = <int, PageCounters>{};
    var reviewedCount = 0;
    var changed = cached.isEmpty;
    final fresh = <String, _PageEntry>{};
    for (var i = 0; i < project.imageFiles.length; i++) {
      final pageId = project.pageIdAt(i);
      final imagePath = project.imageFiles[i];
      final annFile = File(
        p.join(project.projectDir, 'annotations', '$pageId.json'),
      );
      final FileStat stat;
      if (await annFile.exists()) {
        stat = await annFile.stat();
      } else {
        // 无标注文件：无状态（识别完成后文件出现即自然走解析路径）。
        if (cached.remove(pageId) != null) changed = true;
        continue;
      }
      final entry = cached[pageId];
      if (entry != null &&
          entry.mtimeMs == stat.modified.millisecondsSinceEpoch &&
          entry.size == stat.size &&
          entry.imagePath == imagePath) {
        fresh[pageId] = entry;
        _applyState(markers, i, entry.state);
        if (entry.reviewed) reviewedCount++;
        countersByPage[i] = entry.counters;
        continue;
      }
      // 指纹变化/首次：解析标注重新派生（expectedImagePath 错配丢弃
      // 口径与 PageStateMarkers.load 一致）。
      final ann = await ProjectStorage.loadAnnotation(
        project.projectDir,
        pageId,
        expectedImagePath: imagePath,
      );
      final state = _stateOf(ann);
      final reviewed = ann?.reviewed ?? false;
      final counters = ann == null
          ? PageCounters.empty
          : PageCounters.of(ann);
      fresh[pageId] = _PageEntry(
        mtimeMs: stat.modified.millisecondsSinceEpoch,
        size: stat.size,
        imagePath: imagePath,
        state: state,
        reviewed: reviewed,
        counters: counters,
      );
      _applyState(markers, i, state);
      if (reviewed) reviewedCount++;
      countersByPage[i] = counters;
      changed = true;
    }
    // 删页后残留的旧 pageId 条目不回写（fresh 只含现存页）。同步等写
    // 完成：异步 fire-and-forget 会与调用方随后的读取/删除（测试、
    // 书目录拷贝）竞态。
    if (changed || cached.length != fresh.length) {
      await _write(project.projectDir, fresh);
    }
    return PageStateSummary(
      markers: markers,
      reviewedCount: reviewedCount,
      countersByPage: countersByPage,
    );
  }

  static Future<Map<String, _PageEntry>> _read(String projectDir) async {
    try {
      final decoded = jsonDecode(await _file(projectDir).readAsString());
      if (decoded is Map && decoded['v'] == _version) {
        final pages = decoded['pages'];
        if (pages is Map) {
          final map = <String, _PageEntry>{};
          pages.forEach((k, v) {
            final e = _PageEntry.fromJson(v);
            if (e != null) map[k.toString()] = e;
          });
          return map;
        }
      }
    } catch (_) {
      // 损坏/不存在：全部重建。
    }
    return {};
  }

  static int _stateOf(PageAnnotation? ann) {
    if (ann == null) return 0;
    if (ann.isFullyConfirmed) return 1;
    // 框确认优先于临时保存：与 PageStateMarkers.borderColor 同口径，
    // 确认过框的页不再显示橘黄。
    if (ann.boxesReviewed) return 4;
    if (ann.draftSaved) return 2;
    if (ann.hasUnconfirmedBoxes) return 3;
    return 0;
  }

  static void _applyState(PageStateMarkers markers, int index, int state) {
    switch (state) {
      case 1:
        markers.savedPages.add(index);
      case 2:
        markers.draftPages.add(index);
      case 3:
        markers.boxedUnconfirmedPages.add(index);
      case 4:
        markers.boxesReviewedPages.add(index);
    }
  }

  static Future<void> _write(
    String projectDir,
    Map<String, _PageEntry> pages,
  ) async {
    // 临时文件名带时间戳：编辑器打开时两条链路并发加载都可能回写，
    // 共用固定 tmp 名会互相截断。
    try {
      final f = _file(projectDir);
      final tmp = File('${f.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
      await tmp.writeAsString(
        jsonEncode({
          'v': _version,
          'pages': {for (final e in pages.entries) e.key: e.value.toJson()},
        }),
      );
      await tmp.rename(f.path);
    } catch (_) {
      // 缓存写失败不影响主流程（下次重算一次）。
    }
  }
}

// ─── ② 全书聚类缓存 ─────────────────────────────────────────────────────────

/// 一条聚类缓存：某（范围、阈值、几何摘要）下的分组结果。
/// keys 为 '页号|块id'（与后端返回一致，载入时拆回活字块）。
class ClusterCacheEntry {
  final int rangeStart;
  final int rangeEnd;
  final double threshold;
  final String digest;
  final List<CharClusterGroup> clusters;
  final List<String> singletons;
  final List<String> skipped;
  final DateTime savedAt;

  const ClusterCacheEntry({
    required this.rangeStart,
    required this.rangeEnd,
    required this.threshold,
    required this.digest,
    required this.clusters,
    required this.singletons,
    required this.skipped,
    required this.savedAt,
  });

  CharClusterResult toResult() => CharClusterResult(
    clusters: clusters,
    singletons: singletons,
    skipped: skipped,
    elapsedMs: 0,
  );

  Map<String, dynamic> toJson() => {
    'start': rangeStart,
    'end': rangeEnd,
    'threshold': threshold,
    'digest': digest,
    'clusters': [
      for (final c in clusters) {'c': c.cohesion, 'k': c.blockIds},
    ],
    'singletons': singletons,
    'skipped': skipped,
    'at': savedAt.toIso8601String(),
  };

  static ClusterCacheEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    final start = j['start'], end = j['end'], digest = j['digest'];
    final threshold = (j['threshold'] as num?)?.toDouble();
    if (start is! int || end is! int || threshold == null || digest is! String) {
      return null;
    }
    return ClusterCacheEntry(
      rangeStart: start,
      rangeEnd: end,
      threshold: threshold,
      digest: digest,
      clusters: [
        for (final c in (j['clusters'] as List? ?? const []).whereType<Map>())
          CharClusterGroup(
            blockIds: [
              for (final k in (c['k'] as List? ?? const [])) k.toString(),
            ],
            cohesion: (c['c'] as num?)?.toDouble() ?? 0,
          ),
      ],
      singletons: [
        for (final k in (j['singletons'] as List? ?? const [])) k.toString(),
      ],
      skipped: [
        for (final k in (j['skipped'] as List? ?? const [])) k.toString(),
      ],
      savedAt: DateTime.tryParse(j['at']?.toString() ?? '') ?? DateTime.now(),
    );
  }
}

class ClusterCache {
  static const _version = 1;
  static const _fileName = 'cluster_cache.json';
  static const _maxEntries = 6;

  /// 每页输入摘要：图片指纹（mtime+size，摆正/换图即变）+ 正文字块的
  /// id 与几何（聚类的全部输入；文字/确认/标记不参与，改字不失效）。
  static Future<String> digestForPages(
    List<({String imagePath, List<CharBlock> blocks})> pages,
  ) async {
    final buf = StringBuffer();
    for (final page in pages) {
      buf
        ..write(page.imagePath)
        ..write('|');
      try {
        final st = await File(page.imagePath).stat();
        buf
          ..write(st.modified.millisecondsSinceEpoch)
          ..write('|')
          ..write(st.size);
      } catch (_) {
        buf.write('missing');
      }
      buf.write('||');
      for (final b in page.blocks) {
        buf.write('${b.id},${b.x},${b.y},${b.w},${b.h};');
      }
      buf.write('\n');
    }
    return md5.convert(utf8.encode(buf.toString())).toString();
  }

  /// 命中返回缓存条目；未命中返回 null（含摘要不符：几何变了，旧分组
  /// 已失效）。
  static Future<ClusterCacheEntry?> lookup(
    Project project,
    int rangeStart,
    int rangeEnd,
    double threshold,
    String digest,
  ) async {
    for (final e in await _readEntries(project)) {
      if (e.rangeStart == rangeStart &&
          e.rangeEnd == rangeEnd &&
          e.threshold == threshold &&
          e.digest == digest) {
        return e;
      }
    }
    return null;
  }

  /// 写入一条（同 key 覆盖，最多保留 [_maxEntries] 条——阈值来回调试
  /// 时新旧配置都能快速命中）。
  static Future<void> store(Project project, ClusterCacheEntry entry) async {
    final entries = await _readEntries(project);
    entries.removeWhere(
      (e) =>
          e.rangeStart == entry.rangeStart &&
          e.rangeEnd == entry.rangeEnd &&
          e.threshold == entry.threshold,
    );
    entries.insert(0, entry);
    if (entries.length > _maxEntries) {
      entries.removeRange(_maxEntries, entries.length);
    }
    final f = File(p.join(project.projectDir, _fileName));
    try {
      final tmp = File('${f.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
      await tmp.writeAsString(
        jsonEncode({
          'v': _version,
          'entries': [for (final e in entries) e.toJson()],
        }),
      );
      await tmp.rename(f.path);
    } catch (_) {
      // 缓存写失败不影响主流程。
    }
  }

  static Future<List<ClusterCacheEntry>> _readEntries(Project project) async {
    try {
      final decoded = jsonDecode(
        await File(p.join(project.projectDir, _fileName)).readAsString(),
      );
      if (decoded is Map && decoded['v'] == _version) {
        final list = <ClusterCacheEntry>[];
        for (final e in (decoded['entries'] as List? ?? const [])) {
          final entry = ClusterCacheEntry.fromJson(e);
          if (entry != null) list.add(entry);
        }
        return list;
      }
    } catch (_) {
      // 损坏/不存在：当没有缓存。
    }
    return [];
  }
}
