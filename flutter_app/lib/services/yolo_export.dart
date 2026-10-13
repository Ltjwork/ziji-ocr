import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;
import '../models/models.dart';
import '../services/reading_order.dart';
import '../services/storage.dart';

/// YOLO 4 层独立数据集导出器。
///
/// 输出目录结构：
/// ```
/// output/
/// ├─ yolo_main_region/   (class: main_text)
/// ├─ yolo_paragraph/     (class: paragraph)
/// ├─ yolo_line/          (class: line_normal, line_annotation)
/// ├─ yolo_char/          (class: char)
/// └─ reading_order.json
/// ```
///
/// 每个数据集：
/// ```
/// images/train/  images/val/
/// labels/train/  labels/val/
/// data.yaml
/// ```
class YoloExporter {
  final Project project;
  final String outputDir;
  final double trainRatio; // 0.0 ~ 1.0
  final int seed;
  final void Function(String msg)? onLog;

  YoloExporter({
    required this.project,
    required this.outputDir,
    this.trainRatio = 0.8,
    this.seed = 42,
    this.onLog,
  });

  void _log(String msg) => onLog?.call(msg);

  /// 导出全部 4 层数据集 + 阅读顺序 JSON。
  ///
  /// 只有「确认并保存」过的整页（isFullyConfirmed）会进入数据集；临时保存
  /// 的页整体跳过——检测数据集若只导出部分框，图内未标注的目标会成为
  /// 假负样本，因此按整页门槛过滤而不是逐框过滤。
  Future<void> exportAll({
    bool exportRegion = true,
    bool exportParagraph = true,
    bool exportLine = true,
    bool exportChar = true,
    bool exportReadingOrder = true,
  }) async {
    final random = Random(seed);
    final pages = <_PageData>[];
    var skippedUnconfirmed = 0;

    // ── 收集所有页面 ──
    final pageCount = project.imageFiles.length;
    for (var i = 0; i < pageCount; i++) {
      final pageId = project.pageIdAt(i);
      final ann = await ProjectStorage.loadAnnotation(
        project.projectDir,
        pageId,
      );
      if (ann == null) {
        _log('[$pageId] 无标注，跳过');
        continue;
      }
      if (!ann.isFullyConfirmed) {
        skippedUnconfirmed++;
        _log('[$pageId] 未确认（临时保存），跳过');
        continue;
      }
      // 推断层级（若空）+ 阅读顺序重排
      final pageOrientation = project.effectiveOrientationAt(i);
      ann.inferHierarchy(
        orientation: pageOrientation,
        horizontalDir: project.settings.horizontalDir,
        verticalDir: project.settings.verticalDir,
      );
      ReadingOrderCalculator.reorder(
        ann,
        orientation: pageOrientation,
        horizontalDir: project.settings.horizontalDir,
        verticalDir: project.settings.verticalDir,
      );

      pages.add(_PageData(
        pageId: pageId,
        annotation: ann,
        isTrain: random.nextDouble() < trainRatio,
      ));
      _log('[$pageId] 已加载');
    }

    if (pages.isEmpty) {
      _log(
        '无可导出页面'
        '${skippedUnconfirmed > 0 ? '（其中 $skippedUnconfirmed 页未确认被跳过，需在编辑器里「确认并保存」）' : ''}',
      );
      return;
    }
    if (skippedUnconfirmed > 0) {
      _log('注意：$skippedUnconfirmed 页未确认（临时保存），已跳过；'
          '在编辑器里「确认并保存」后才会进入训练数据。');
    }

    // ── 各层级独立导出 ──
    if (exportRegion) {
      // 多类 region_det：classId 按词表顺序映射（与后端
      // train_data.LAYER_INFO['region_det']['names'] 同序，main_text 恒为
      // 0；词表外/缺省 label 归 main_text，旧标注无 label 行为不变）。
      await _exportLayer(
        pages,
        datasetName: 'yolo_main_region',
        classNames: List<String>.of(RegionLabel.all),
        labelExtractor: (ann) => ann.mainRegions
            .map((r) => _YoloLabel(
                  classId: RegionLabel.all.indexOf(
                    RegionLabel.normalize(r.label),
                  ),
                  x: r.x.toDouble(),
                  y: r.y.toDouble(),
                  w: r.w.toDouble(),
                  h: r.h.toDouble(),
                ))
            .toList(),
      );
    }

    if (exportParagraph) {
      await _exportLayer(
        pages,
        datasetName: 'yolo_paragraph',
        classNames: ['paragraph'],
        labelExtractor: (ann) => ann.paragraphs
            .map((par) => _YoloLabel(
                  classId: 0,
                  x: par.x.toDouble(),
                  y: par.y.toDouble(),
                  w: par.w.toDouble(),
                  h: par.h.toDouble(),
                ))
            .toList(),
      );
    }

    if (exportLine) {
      await _exportLayer(
        pages,
        datasetName: 'yolo_line',
        classNames: ['line_normal', 'line_annotation'],
        labelExtractor: (ann) => ann.lines.map((line) {
          final isAnno = _isAnnotationLine(line);
          return _YoloLabel(
            classId: isAnno ? 1 : 0,
            x: line.x.toDouble(),
            y: line.y.toDouble(),
            w: line.w.toDouble(),
            h: line.h.toDouble(),
          );
        }).toList(),
      );
    }

    if (exportChar) {
      await _exportLayer(
        pages,
        datasetName: 'yolo_char',
        classNames: ['char'],
        labelExtractor: (ann) => ann.blocks
            .where((b) => b.type != 'ignore')
            .map((b) => _YoloLabel(
                  classId: 0,
                  x: b.x.toDouble(),
                  y: b.y.toDouble(),
                  w: b.w.toDouble(),
                  h: b.h.toDouble(),
                ))
            .toList(),
      );
    }

    if (exportReadingOrder) {
      await _exportReadingOrder(pages);
    }

    _log('\n导出完成！输出目录：$outputDir');
  }

  /// 导出单个层级的 YOLO 数据集。
  Future<void> _exportLayer(
    List<_PageData> pages, {
    required String datasetName,
    required List<String> classNames,
    required List<_YoloLabel> Function(PageAnnotation) labelExtractor,
  }) async {
    final datasetDir = p.join(outputDir, datasetName);
    final imgTrainDir = p.join(datasetDir, 'images', 'train');
    final imgValDir = p.join(datasetDir, 'images', 'val');
    final lblTrainDir = p.join(datasetDir, 'labels', 'train');
    final lblValDir = p.join(datasetDir, 'labels', 'val');

    for (final d in [imgTrainDir, imgValDir, lblTrainDir, lblValDir]) {
      await Directory(d).create(recursive: true);
    }

    var count = 0;
    for (final page in pages) {
      final labels = labelExtractor(page.annotation);
      if (labels.isEmpty) continue;

      // 获取图像尺寸用于归一化
      final imgFile = File(page.annotation.imagePath);
      final bytes = await imgFile.readAsBytes();
      // 简单方式：从已有数据中获取宽高，或解码
      final decoded = await _decodeImageSize(bytes);
      if (decoded == null) {
        _log('[${page.pageId}] 无法读取图像尺寸，跳过');
        continue;
      }
      final imgW = decoded.width.toDouble();
      final imgH = decoded.height.toDouble();

      // 拷贝图像
      final imgExt = p.extension(page.annotation.imagePath);
      final imgName = '${page.pageId}$imgExt';
      final targetImgDir = page.isTrain ? imgTrainDir : imgValDir;
      final targetLblDir = page.isTrain ? lblTrainDir : lblValDir;
      await imgFile.copy(p.join(targetImgDir, imgName));

      // 写标签文件
      final lblName = '${page.pageId}.txt';
      final lblBuf = StringBuffer();
      for (final label in labels) {
        final cx = (label.x + label.w / 2) / imgW;
        final cy = (label.y + label.h / 2) / imgH;
        final nw = label.w / imgW;
        final nh = label.h / imgH;
        lblBuf.writeln(
          '${label.classId} ${cx.toStringAsFixed(6)} '
          '${cy.toStringAsFixed(6)} ${nw.toStringAsFixed(6)} '
          '${nh.toStringAsFixed(6)}',
        );
      }
      await File(p.join(targetLblDir, lblName)).writeAsString(lblBuf.toString());
      count++;
    }

    // 写 data.yaml
    final absDatasetDir = p.absolute(datasetDir).replaceAll('\\', '/');
    final yamlContent = StringBuffer()
      ..writeln('path: $absDatasetDir')
      ..writeln('train: images/train')
      ..writeln('val: images/val')
      ..writeln('names:');
    for (var i = 0; i < classNames.length; i++) {
      yamlContent.writeln('  $i: ${classNames[i]}');
    }
    await File(p.join(datasetDir, 'data.yaml')).writeAsString(
      yamlContent.toString(),
    );

    _log('[$datasetName] 导出 $count 页，${classNames.length} 类');
  }

  /// 导出阅读顺序 JSON。
  Future<void> _exportReadingOrder(List<_PageData> pages) async {
    final result = <Map<String, dynamic>>[];
    for (final page in pages) {
      result.add({
        'page_id': page.pageId,
        'lines': ReadingOrderCalculator.toJson(
          page.annotation,
          orientation: project.effectiveOrientationFor(page.pageId),
          horizontalDir: project.settings.horizontalDir,
          verticalDir: project.settings.verticalDir,
        ),
      });
    }
    final jsonPath = p.join(outputDir, 'reading_order.json');
    await File(jsonPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(result),
    );
    _log('[reading_order] 导出 ${pages.length} 页 → reading_order.json');
  }

  /// 判定行是否为小注行
  static bool _isAnnotationLine(LineBlock line) {
    if (line.chars.isEmpty) return false;
    for (final c in line.chars) {
      if (c.type != 'annotation') return false;
    }
    return true;
  }

  /// 用 dart:ui 解码获取图像尺寸
  Future<_ImageSize?> _decodeImageSize(List<int> bytes) async {
    try {
      // 使用 Dart 内置 image 解码获取尺寸
      // 不依赖 dart:ui（避免在 isolate 外的复杂依赖），用简单 PNG/JPEG 头解析
      // JPEG: SOF0 标记；PNG: IHDR
      // 这里用通用方式：尝试 image 包或 dart:ui
      // 为避免额外依赖，使用文件路径方式由调用方保证。
      // 简化：从 PageAnnotation 已有的数据反推
      // 但我们只有 imagePath，这里用最小化 PNG/JPEG 头解析
      return _parseImageHeader(bytes);
    } catch (_) {
      return null;
    }
  }

  /// 从图像文件头解析宽高（支持 PNG / JPEG）。
  static _ImageSize? _parseImageHeader(List<int> bytes) {
    if (bytes.length < 8) return null;

    // PNG: \x89PNG\r\n\x1a\n
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      // IHDR 在 offset 16~23：width(4) + height(4)，大端
      if (bytes.length < 24) return null;
      final w = (bytes[16] << 24) |
          (bytes[17] << 16) |
          (bytes[18] << 8) |
          bytes[19];
      final h = (bytes[20] << 24) |
          (bytes[21] << 16) |
          (bytes[22] << 8) |
          bytes[23];
      return _ImageSize(w, h);
    }

    // JPEG: \xFF\xD8
    if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
      var i = 2;
      while (i < bytes.length - 9) {
        if (bytes[i] != 0xFF) {
          i++;
          continue;
        }
        final marker = bytes[i + 1];
        // SOF0~SOF15 (0xC0~0xCF, 排除 C4/C8/CC)
        if (marker >= 0xC0 && marker <= 0xCF &&
            marker != 0xC4 && marker != 0xC8 && marker != 0xCC) {
          final h = (bytes[i + 5] << 8) | bytes[i + 6];
          final w = (bytes[i + 7] << 8) | bytes[i + 8];
          return _ImageSize(w, h);
        }
        // 跳过此段
        final segLen = (bytes[i + 2] << 8) | bytes[i + 3];
        i += 2 + segLen;
      }
    }

    return null;
  }
}

/// YOLO 归一化前的原始标签
class _YoloLabel {
  final int classId;
  final double x, y, w, h;

  _YoloLabel({
    required this.classId,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });
}

/// 单页导出上下文
class _PageData {
  final String pageId;
  final PageAnnotation annotation;
  final bool isTrain;

  _PageData({
    required this.pageId,
    required this.annotation,
    required this.isTrain,
  });
}

/// 图像尺寸
class _ImageSize {
  final int width;
  final int height;
  _ImageSize(this.width, this.height);
}