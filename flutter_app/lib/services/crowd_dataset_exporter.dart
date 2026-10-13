import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../models/models.dart';
import 'python_service.dart';
import 'storage.dart';

class CrowdDatasetExportResult {
  final String outputDir;
  final String? zipPath;
  final int pageCount;
  final int lineCount;
  final int charCount;
  final int taskCount;
  final List<String> errors;

  const CrowdDatasetExportResult({
    required this.outputDir,
    required this.zipPath,
    required this.pageCount,
    required this.lineCount,
    required this.charCount,
    this.taskCount = 0,
    required this.errors,
  });
}

/// 导出供人工识字任务使用的、可追溯的正文数据包。
///
/// 两种模式（[export] 的 [unconfirmedOnly]）：
/// - 已确认模式（默认，crowd_dataset）：只导已确认的字，作为训练快照/阅读包；
/// - 未确认任务模式（crowd_tasks）：blocks 保留行内全部正文字（含已确认），
///   但只为「未确认且未拒绝」的字生成字图与候选（for_task=true），
///   供命迹众包分发；共识导回后仍需在编辑器复核。
class CrowdDatasetExporter {
  CrowdDatasetExporter({required this.project, this.onLog});

  final Project project;
  final void Function(String message)? onLog;

  Future<CrowdDatasetExportResult> export({
    required String outputDir,
    bool createZip = true,
    bool unconfirmedOnly = false,
    int? pageStart,
    int? pageEnd,
  }) async {
    final root = Directory(outputDir);
    await root.create(recursive: true);
    // 任务包只用字图，不拷贝整页图/行图，也就不建这两个目录
    final pagesDir = Directory(p.join(outputDir, 'pages'));
    final linesDir = Directory(p.join(outputDir, 'lines'));
    if (!unconfirmedOnly) {
      pagesDir.createSync(recursive: true);
      linesDir.createSync(recursive: true);
    }
    final charsDir = Directory(p.join(outputDir, 'chars'))
      ..createSync(recursive: true);
    final logDir = Directory(p.join(outputDir, 'logs'))
      ..createSync(recursive: true);
    final errors = <String>[];
    final log = StringBuffer();
    void writeLog(String message) {
      log.writeln(message);
      onLog?.call(message);
    }

    void errorLog(String message) {
      errors.add(message);
      writeLog('[error] $message');
    }

    final pageRecords = <Map<String, dynamic>>[];
    final blockPages = <Map<String, dynamic>>[];
    var lineCount = 0;
    var charCount = 0;
    var taskCount = 0;

    // 页码范围（1 基、闭区间）：用于只导出部分页（测试/分批分发）
    final firstPage = (pageStart != null && pageStart > 0) ? pageStart : 1;
    final lastPage = (pageEnd != null && pageEnd > 0)
        ? pageEnd
        : project.imageFiles.length;
    if (lastPage < firstPage) {
      errorLog('页码范围无效：起始页 $firstPage 大于结束页 $lastPage');
    }

    for (
      var pageIndex = firstPage - 1;
      pageIndex < project.imageFiles.length && pageIndex < lastPage;
      pageIndex++
    ) {
      final pageId = project.pageIdAt(pageIndex);
      PageAnnotation? annotation = await ProjectStorage.loadAnnotation(
        project.projectDir,
        pageId,
      );
      final sourcePath = pageIndex < project.imageFiles.length
          ? project.imageFiles[pageIndex]
          : '';
      if (annotation == null &&
          sourcePath.isNotEmpty &&
          await File(sourcePath).exists()) {
        try {
          annotation = await PythonService.segmentWithSettings(
            imagePath: sourcePath,
            pageId: pageId,
            settings: project.settings.copyWith(layoutMode: 'main_text_only'),
          );
          await ProjectStorage.saveAnnotation(project.projectDir, annotation);
          writeLog('[$pageId] 自动完成正文分区、分行和切字');
        } catch (e) {
          errorLog('[$pageId] 自动识别失败：$e');
          continue;
        }
      }
      if (annotation == null) {
        errorLog('[$pageId] 找不到源图片或标注数据');
        continue;
      }
      // 已确认包只接受已确认的正文主区；未确认任务包只要求划定过主区
      //（几何尚待校对也可以先众包认字，写回仍按字块 UID 匹配）。
      final hasMainRegion = annotation.mainRegions.isNotEmpty;
      final hasConfirmedMainRegion = annotation.mainRegions.any(
        (region) => region.status == AnnotationStatus.confirmed,
      );
      if (!(unconfirmedOnly ? hasMainRegion : hasConfirmedMainRegion)) {
        errorLog(
          unconfirmedOnly
              ? '[$pageId] 未划定正文主区域，跳过'
              : '[$pageId] 未确认正文主区域，跳过正式导出',
        );
        continue;
      }

      final sourceFile = File(annotation.imagePath);
      if (!await sourceFile.exists()) {
        errorLog('[$pageId] 源图片不存在：${annotation.imagePath}');
        continue;
      }
      final pageFileName =
          '$pageId${p.extension(sourceFile.path).isEmpty ? '.png' : p.extension(sourceFile.path)}';
      // 任务包不需要整页图（服务器只用字图），省去整书大图拷贝
      if (!unconfirmedOnly) {
        final pageOut = File(p.join(pagesDir.path, pageFileName));
        await sourceFile.copy(pageOut.path);
      }
      final sourceBytes = await sourceFile.readAsBytes();
      final digest = sha256.convert(sourceBytes).toString();
      final annotationJson = annotation.toJson();
      final ocrRevision = sha256
          .convert(utf8.encode(const JsonEncoder().convert(annotationJson)))
          .toString()
          .substring(0, 16);
      final modelVersion =
          annotationJson['model_version']?.toString() ?? 'unknown';
      final size = _imageSize(sourceBytes);
      final imageWidth = size?.$1 ?? 1;
      final imageHeight = size?.$2 ?? 1;

      // 任务字判定：未确认模式取「未确认且未拒绝」的正文字作为众包任务；
      // 已确认模式维持原口径（全部导出字都是已确认字）。
      bool isTaskChar(CharBlock char) => unconfirmedOnly
          ? (char.type == 'main_text' &&
              !_isConfirmed(char) &&
              char.status != AnnotationStatus.rejected)
          : (char.type == 'main_text' && _isConfirmed(char));
      final mainLines = annotation.lines
          .where((line) => line.chars.any(isTaskChar))
          .toList();
      if (unconfirmedOnly && mainLines.isEmpty) {
        writeLog('[$pageId] 无待识别的未确认字，跳过');
        continue;
      }
      final pageLineRecords = <Map<String, dynamic>>[];
      final lineCropBlocks = <CharBlock>[];
      final charCropBlocks = <CharBlock>[];
      final exportCharEntries = <String, Map<String, dynamic>>{};
      var pageTaskCount = 0;

      for (var lineIndex = 0; lineIndex < mainLines.length; lineIndex++) {
        final line = mainLines[lineIndex];
        final lineUid = _stableUid(
          digest,
          'line',
          line.x,
          line.y,
          line.w,
          line.h,
          lineIndex,
        );
        if (!unconfirmedOnly) {
          Directory(p.join(linesDir.path, pageId)).createSync(recursive: true);
          // 任务包不出行图（服务器只用字图），已确认包保持原样
          lineCropBlocks.add(
            CharBlock(
              id: lineUid,
              x: line.x,
              y: line.y,
              w: line.w,
              h: line.h,
              col: line.lineNo,
              order: line.readingOrder < 0 ? lineIndex : line.readingOrder,
              type: 'main_text',
              lineId: line.id,
            ),
          );
        }

        // 任务包保留行内全部正文字（含已确认/拒绝），保证整书文本可重建；
        // 已确认包维持原样（只含已确认字）。
        final chars = line.chars.where((char) {
          if (unconfirmedOnly) return char.type == 'main_text';
          return char.type == 'main_text' && _isConfirmed(char);
        }).toList();
        final charEntries = <Map<String, dynamic>>[];
        for (var charIndex = 0; charIndex < chars.length; charIndex++) {
          final char = chars[charIndex];
          final isTask = unconfirmedOnly
              ? (!_isConfirmed(char) &&
                  char.status != AnnotationStatus.rejected)
              : true;
          final charUid = _stableUid(
            digest,
            'char',
            char.x,
            char.y,
            char.w,
            char.h,
            charIndex,
          );
          final cropBlock = char.copyWith(
            id: charUid,
            lineId: line.id,
            order: charIndex,
          );
          if (isTask) charCropBlocks.add(cropBlock);
          final entry = <String, dynamic>{
            'char_uid': charUid,
            'stable_uid': charUid,
            'legacy_id': char.id,
            'page_id': pageId,
            'line_id': line.id,
            'char_index': charIndex,
            'x': char.x,
            'y': char.y,
            'w': char.w,
            'h': char.h,
            'bbox': [
              char.x / imageWidth,
              char.y / imageHeight,
              char.w / imageWidth,
              char.h / imageHeight,
            ],
            'crop_path':
                isTask ? 'chars/$pageId/$charUid.png' : '',
            'text': char.text,
            'source': char.source,
            'status': char.status,
            'for_task': isTask,
            'ocr_revision': ocrRevision,
            'model_version': modelVersion,
            'candidates': char.candidates.map((e) => e.toJson()).toList(),
          };
          exportCharEntries[charUid] = entry;
          charEntries.add(entry);
          if (isTask) pageTaskCount++;
        }
        pageLineRecords.add({
          'line_id': line.id,
          'line_uid': lineUid,
          'line_no': line.lineNo,
          'reading_order': line.readingOrder < 0
              ? lineIndex
              : line.readingOrder,
          'orientation': line.orientation,
          'x': line.x,
          'y': line.y,
          'w': line.w,
          'h': line.h,
          'bbox': [
            line.x / imageWidth,
            line.y / imageHeight,
            line.w / imageWidth,
            line.h / imageHeight,
          ],
          'text': chars.map((e) => e.text).join(),
          'crop_path': 'lines/$pageId/$lineUid.png',
          'chars': charEntries,
        });
      }

      if (lineCropBlocks.isNotEmpty) {
        try {
          await PythonService.crop(
            annotation.imagePath,
            p.join(linesDir.path, pageId),
            lineCropBlocks,
          );
        } catch (e) {
          errorLog('[$pageId] 行图片导出失败：$e');
        }
      }
      if (charCropBlocks.isNotEmpty) {
        try {
          await PythonService.crop(
            annotation.imagePath,
            p.join(charsDir.path, pageId),
            charCropBlocks,
          );
        } catch (e) {
          errorLog('[$pageId] 字图片导出失败：$e');
        }
        try {
          final candidates = await PythonService.getCharCandidatesBatch(
            imagePath: annotation.imagePath,
            blocks: charCropBlocks,
            topK: 10,
          );
          for (final block in charCropBlocks) {
            final values =
                candidates[block.id] ?? const <Map<String, dynamic>>[];
            final fresh = values
                .where(
                  (item) => (item['text']?.toString().runes.length ?? 0) == 1,
                )
                .map(
                  (item) => CharCandidate(
                    text: item['text'].toString(),
                    score: (item['score'] as num?)?.toDouble() ?? 0,
                  ),
                )
                .toList();
            final entry = exportCharEntries[block.id];
            if (entry == null) continue;
            // 合并识别时保存的候选与现场 char_cls 候选（覆盖会把保存的
            // 候选抹掉）；任务包模式下排除与当前文本相同的项（那是机器
            // 猜测即参考答案，作为选项会锚定答题用户）。
            final saved = ((entry['candidates'] as List?) ?? const [])
                .whereType<Map>()
                .map((m) => CharCandidate.fromJson(Map<String, dynamic>.from(m)))
                .toList();
            final merged = mergeCharCandidates(
              saved: saved,
              fresh: fresh,
              ensureText: unconfirmedOnly ? entry['text']?.toString() : null,
            );
            entry['candidates'] = merged.map((e) => e.toJson()).toList();
            entry['status'] = merged.isEmpty
                ? AnnotationStatus.needsReview
                : AnnotationStatus.proposed;
            if ((entry['text'] as String).isEmpty && merged.isNotEmpty) {
              entry['text'] = merged.first.text;
            }
          }
        } catch (e) {
          errorLog('[$pageId] 候选字批量识别失败：$e');
          // 批量接口不可用时逐字兜底，保证部分候选仍可导出。
          for (final block in charCropBlocks) {
            try {
              final values = await PythonService.getCharCandidates(
                imagePath: annotation.imagePath,
                x: block.x,
                y: block.y,
                w: block.w,
                h: block.h,
                topK: 10,
              );
              final entry = exportCharEntries[block.id];
              if (entry != null) {
                final fresh = values
                    .whereType<Map>()
                    .where(
                      (item) =>
                          (item['text']?.toString().runes.length ?? 0) == 1,
                    )
                    .map(
                      (item) => CharCandidate(
                        text: item['text'].toString(),
                        score: (item['score'] as num?)?.toDouble() ?? 0,
                      ),
                    )
                    .toList();
                final saved = ((entry['candidates'] as List?) ?? const [])
                    .whereType<Map>()
                    .map((m) =>
                        CharCandidate.fromJson(Map<String, dynamic>.from(m)))
                    .toList();
                final merged = mergeCharCandidates(
                  saved: saved,
                  fresh: fresh,
                  ensureText:
                      unconfirmedOnly ? entry['text']?.toString() : null,
                );
                entry['candidates'] = merged.map((e) => e.toJson()).toList();
                entry['status'] = merged.isEmpty
                    ? AnnotationStatus.needsReview
                    : AnnotationStatus.proposed;
                if ((entry['text'] as String).isEmpty && merged.isNotEmpty) {
                  entry['text'] = merged.first.text;
                }
              }
            } catch (fallbackError) {
              errorLog('[$pageId/${block.id}] 候选字兜底失败：$fallbackError');
            }
          }
        }
      }

      pageRecords.add({
        'page_id': pageId,
        'source_file': unconfirmedOnly ? '' : 'pages/$pageFileName',
        'source_sha256': digest,
        'ocr_revision': ocrRevision,
        'model_version': modelVersion,
        'width': imageWidth,
        'height': imageHeight,
        'line_count': pageLineRecords.length,
        'char_count': exportCharEntries.length,
        'task_count': pageTaskCount,
      });
      blockPages.add({
        'page_id': pageId,
        'image': unconfirmedOnly ? '' : 'pages/$pageFileName',
        'lines': pageLineRecords,
      });
      lineCount += pageLineRecords.length;
      charCount += exportCharEntries.length;
      taskCount += pageTaskCount;
      writeLog(
        '[$pageId] 导出 ${pageLineRecords.length} 行、${exportCharEntries.length} 字'
        '${unconfirmedOnly ? '（任务 $pageTaskCount）' : ''}',
      );
    }

    final manifest = {
      'schema_version': 2,
      'task_mode': unconfirmedOnly ? 'unconfirmed' : 'confirmed',
      'project_id': project.id,
      'project_name': project.name,
      'book': project.bookMetadata.toJson(),
      'settings': {
        'layout_mode': 'main_text_only',
        'orientation': project.settings.orientation,
        'horizontal_dir': project.settings.horizontalDir,
        'vertical_dir': project.settings.verticalDir,
      },
      'generator': {
        'candidate_top_k': 10,
        'segment_engine': 'yolo-char-first/opencv',
      },
      'pages': pageRecords,
    };
    await File(
      p.join(outputDir, 'manifest.json'),
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(manifest));
    await File(p.join(outputDir, 'blocks.json')).writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'schema_version': 2,
        'ocr_revision': sha256
            .convert(utf8.encode(const JsonEncoder().convert(pageRecords)))
            .toString()
            .substring(0, 16),
        'project_id': project.id,
        'pages': blockPages,
      }),
    );
    await File(p.join(logDir.path, 'export.log')).writeAsString(log.toString());

    String? zipPath;
    if (createZip) {
      zipPath = '${outputDir.replaceAll(RegExp(r'[\\/]$'), '')}.zip';
      await _zipDirectory(outputDir, zipPath);
      writeLog('ZIP 打包完成：$zipPath');
    }
    return CrowdDatasetExportResult(
      outputDir: outputDir,
      zipPath: zipPath,
      pageCount: pageRecords.length,
      lineCount: lineCount,
      charCount: charCount,
      taskCount: taskCount,
      errors: errors,
    );
  }

  Future<void> _zipDirectory(String directory, String zipPath) async {
    final archive = Archive();
    final root = Directory(directory);
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relative = p
          .relative(entity.path, from: directory)
          .replaceAll('\\', '/');
      final bytes = await entity.readAsBytes();
      archive.addFile(ArchiveFile(relative, bytes.length, bytes));
    }
    final encoded = ZipEncoder().encode(archive);
    await File(zipPath).writeAsBytes(encoded);
  }

  static bool _isConfirmed(CharBlock char) =>
      char.confirmed || char.status.toLowerCase() == 'confirmed';

  /// 合并识别时保存的候选与现场识别候选：按文本去重（现场结果优先）、
  /// 过滤单个 ASCII 字母噪声（识别模型对古汉字的退化猜测）、按分数降序。
  /// [ensureText]（任务包 B 方案）：机器当前读法兜底——候选不足 [topK]
  /// 时补在末位，保证每题至少有一个可选字符；char_cls 候选优先。
  static List<CharCandidate> mergeCharCandidates({
    required List<CharCandidate> saved,
    required List<CharCandidate> fresh,
    String? ensureText,
    int topK = 10,
  }) {
    String? cleanKey(String text) {
      final t = text.trim();
      if (t.isEmpty || t.runes.length != 1) return null;
      final r = t.runes.first;
      final isAsciiLetter =
          (r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A);
      if (isAsciiLetter) return null;
      return t;
    }

    final merged = <String, CharCandidate>{};
    for (final c in fresh) {
      final key = cleanKey(c.text);
      if (key != null) merged[key] = c;
    }
    for (final c in saved) {
      final key = cleanKey(c.text);
      if (key != null) merged.putIfAbsent(key, () => c);
    }
    final list = merged.values.toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    final ensure = ensureText?.trim() ?? '';
    if (ensure.isNotEmpty &&
        ensure.runes.length == 1 &&
        !merged.containsKey(ensure)) {
      list.add(CharCandidate(text: ensure, score: 1.0));
    }
    return list.length > topK ? list.sublist(0, topK) : list;
  }

  /// 注意：与 Python 端 metadata.stable_uid 格式不同（那边 payload 是
  /// JSON 且带 kind_ 前缀）；本格式（"sha|kind|x,y,w,h|order" → 无前缀
  /// 24 位十六进制）是识字数据包与共识写回链路的 char_uid 基准，勿与
  /// 识别结果 uid 混用（见 ocr/README.md「标注与训练规则」）。
  static String _stableUid(
    String sourceSha256,
    String kind,
    int x,
    int y,
    int w,
    int h,
    int order,
  ) {
    final raw = '$sourceSha256|$kind|$x,$y,$w,$h|$order';
    return sha256.convert(utf8.encode(raw)).toString().substring(0, 24);
  }

  static (int, int)? _imageSize(List<int> bytes) {
    if (bytes.length >= 24 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47) {
      return (
        (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19],
        (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23],
      );
    }
    if (bytes.length >= 10 && bytes[0] == 0xff && bytes[1] == 0xd8) {
      var i = 2;
      while (i + 9 < bytes.length) {
        if (bytes[i] != 0xff) {
          i++;
          continue;
        }
        final marker = bytes[i + 1];
        final length = (bytes[i + 2] << 8) | bytes[i + 3];
        if (marker >= 0xc0 && marker <= 0xc3 && i + 8 < bytes.length) {
          return (
            (bytes[i + 7] << 8) | bytes[i + 8],
            (bytes[i + 5] << 8) | bytes[i + 6],
          );
        }
        if (length < 2) break;
        i += 2 + length;
      }
    }
    return null;
  }
}
