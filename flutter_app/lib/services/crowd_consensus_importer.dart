import 'dart:convert';
import 'dart:io';

import '../models/models.dart';
import 'storage.dart';

/// 命迹识字共识快照（管理后台导出）解析与写回。
///
/// 快照结构（见服务器 crowd_admin.go AdminExportCrowdBatch）：
/// {
///   "kind": "mingji_crowd_consensus_snapshot",
///   "batch": {"project_id": "...", "book_title": "..."},
///   "entries": [{"char_uid", "legacy_id", "page_id", "line_id", "char_index",
///                "ocr_text", "confirmed_text", "answer_count", "top_share",
///                "ocr_revision"}]
/// }
class CrowdConsensusSnapshot {
  final String projectId;
  final String bookTitle;
  final String batchName;
  final Map<String, List<Map<String, dynamic>>> entriesByPage;

  const CrowdConsensusSnapshot({
    required this.projectId,
    required this.bookTitle,
    required this.batchName,
    required this.entriesByPage,
  });

  int get entryCount =>
      entriesByPage.values.fold(0, (sum, list) => sum + list.length);

  /// 页级 OCR 修订号（取该页第一条记录；同页共享一个修订号）
  String revisionFor(String pageId) {
    final list = entriesByPage[pageId];
    if (list == null || list.isEmpty) return '';
    return list.first['ocr_revision']?.toString() ?? '';
  }
}

class CrowdConsensusImportResult {
  final Project project;
  final int entryCount;
  final int appliedCount;
  final int changedCount;
  final int skippedConfirmed;
  final int missingBlocks;
  final int missingPages;
  final int revisionMismatches;
  final List<String> logs;

  const CrowdConsensusImportResult({
    required this.project,
    required this.entryCount,
    required this.appliedCount,
    required this.changedCount,
    required this.skippedConfirmed,
    required this.missingBlocks,
    required this.missingPages,
    required this.revisionMismatches,
    required this.logs,
  });
}

/// 解析共识快照文件。校验 kind 标记，按 page_id 分组条目。
CrowdConsensusSnapshot parseCrowdConsensusSnapshot(File file) {
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map) {
    throw const FormatException('快照不是 JSON 对象');
  }
  final map = Map<String, dynamic>.from(decoded);
  final kind = map['kind']?.toString() ?? '';
  if (kind != 'mingji_crowd_consensus_snapshot') {
    throw const FormatException('不是命迹识字共识快照文件（kind 不匹配）');
  }
  final batch = Map<String, dynamic>.from(map['batch'] as Map? ?? {});
  final entries = (map['entries'] as List? ?? [])
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();
  final byPage = <String, List<Map<String, dynamic>>>{};
  for (final entry in entries) {
    final pageId = entry['page_id']?.toString() ?? '';
    if (pageId.isEmpty) continue;
    byPage.putIfAbsent(pageId, () => []).add(entry);
  }
  return CrowdConsensusSnapshot(
    projectId: batch['project_id']?.toString() ?? '',
    bookTitle: batch['book_title']?.toString() ?? '',
    batchName: batch['name']?.toString() ?? '',
    entriesByPage: byPage,
  );
}

/// 把共识快照写回项目标注：按 char_uid（稳定几何哈希）匹配字块，
/// 找不到再按 legacy_id（导出时的 CharBlock.id）兜底；命中后更新文字
/// 并标记为已确认（几何与 box_confirmed 不动）。写回走原子写。
Future<CrowdConsensusImportResult> importCrowdConsensusSnapshot({
  required CrowdConsensusSnapshot snapshot,
  required Project project,
  void Function(String message)? onLog,
}) async {
  final logs = <String>[];
  void log(String message) {
    logs.add(message);
    onLog?.call(message);
  }

  var applied = 0;
  var changed = 0;
  var skippedConfirmed = 0;
  var missingBlocks = 0;
  var missingPages = 0;
  var revisionMismatches = 0;

  final pageIds = snapshot.entriesByPage.keys.toList()..sort();
  for (final pageId in pageIds) {
    final entries = snapshot.entriesByPage[pageId]!;
    final annotation = await ProjectStorage.loadAnnotation(
      project.projectDir,
      pageId,
    );
    if (annotation == null) {
      missingPages++;
      log('[$pageId] 找不到页标注文件，跳过 ${entries.length} 条');
      continue;
    }

    final snapshotRevision = snapshot.revisionFor(pageId);
    if (snapshotRevision.isNotEmpty &&
        annotation.ocrRevision.isNotEmpty &&
        snapshotRevision != annotation.ocrRevision) {
      revisionMismatches++;
      String shorten(String value) =>
          value.length <= 8 ? value : value.substring(0, 8);
      log('[$pageId] ⚠ 页标注修订号与导出时不一致'
          '（导出 ${shorten(snapshotRevision)}…'
          ' / 当前 ${shorten(annotation.ocrRevision)}…），'
          '仍按字块 UID 匹配写回');
    }

    // 行内字块与扁平镜像都建立索引（同一对象会自然去重，旧数据可能是两份副本）
    final byUid = <String, CharBlock>{};
    final byLegacy = <String, CharBlock>{};
    void index(CharBlock block) {
      if (block.uid.isNotEmpty) byUid.putIfAbsent(block.uid, () => block);
      if (block.id.isNotEmpty) byLegacy.putIfAbsent(block.id, () => block);
    }

    for (final line in annotation.lines) {
      for (final char in line.chars) {
        index(char);
      }
    }
    for (final block in annotation.blocks) {
      index(block);
    }

    final touchedLineIds = <String>{};
    var pageHits = 0;
    var pageMissing = 0;
    for (final entry in entries) {
      final charUid = entry['char_uid']?.toString() ?? '';
      final legacyId = entry['legacy_id']?.toString() ?? '';
      final confirmedText = entry['confirmed_text']?.toString() ?? '';
      final block = (charUid.isNotEmpty ? byUid[charUid] : null) ??
          (legacyId.isNotEmpty ? byLegacy[legacyId] : null);
      if (block == null) {
        missingBlocks++;
        pageMissing++;
        continue;
      }
      if (confirmedText.runes.length != 1) {
        missingBlocks++;
        pageMissing++;
        log('[$pageId] 条目终字异常（"${confirmedText.length > 20 ? confirmedText.substring(0, 20) : confirmedText}"），跳过');
        continue;
      }
      if (block.confirmed || block.status == AnnotationStatus.confirmed) {
        // 导出后该字已在编辑器人工确认：共识不再覆盖，跳过
        skippedConfirmed++;
        continue;
      }
      if (block.text != confirmedText) {
        block.text = confirmedText;
        changed++;
      }
      // 共识只作为校对建议写回：标记 needs_review 供编辑器复核，
      // 确认仍由人工「确认并保存」完成（几何与识别框状态不动）。
      block.status = AnnotationStatus.needsReview;
      applied++;
      pageHits++;
      if (block.lineId.isNotEmpty) touchedLineIds.add(block.lineId);
    }

    // 行文本与字块保持一致（导出与阅读顺序都以行为单位拼接）
    if (touchedLineIds.isNotEmpty) {
      for (final line in annotation.lines) {
        if (touchedLineIds.contains(line.id)) {
          line.text = line.chars.map((c) => c.text).join();
        }
      }
    }

    await ProjectStorage.saveAnnotation(project.projectDir, annotation);
    log('[$pageId] 写回 ${entries.length} 条（命中 $pageHits，未匹配 $pageMissing）');
  }

  log('导入完成：共 ${snapshot.entryCount} 条，写回 $applied 字（与原文不同 $changed），'
      '已确认跳过 $skippedConfirmed，未匹配 $missingBlocks，缺页 $missingPages。'
      '写回字标记为待复核，请在编辑器中复核后确认');

  return CrowdConsensusImportResult(
    project: project,
    entryCount: snapshot.entryCount,
    appliedCount: applied,
    changedCount: changed,
    skippedConfirmed: skippedConfirmed,
    missingBlocks: missingBlocks,
    missingPages: missingPages,
    revisionMismatches: revisionMismatches,
    logs: logs,
  );
}
