import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import '../models/models.dart';
import '../services/python_service.dart';
import '../services/reading_order.dart';
import '../services/storage.dart';
import '../services/yolo_export.dart';
import '../services/crowd_dataset_exporter.dart';

/// 导出类型 bitmask
enum ExportFlag {
  yoloRegion('YOLO 主内容区', 'yolo_region'),
  yoloParagraph('YOLO 自然段', 'yolo_paragraph'),
  yoloLine('YOLO 行', 'yolo_line'),
  yoloChar('YOLO 字', 'yolo_char'),
  crnn('CRNN 行序列', 'crnn'),
  lmdb('LMDB 打包', 'lmdb'),
  readingOrder('阅读顺序 JSON', 'reading_order'),
  crowdDataset('正文识字数据包（含字图/候选）', 'crowd_dataset'),
  crowdTasks('识字任务包（未确认字，供命迹众包）', 'crowd_tasks');

  final String label;
  final String key;
  const ExportFlag(this.label, this.key);
}

class ExportPage extends StatefulWidget {
  final Project project;
  const ExportPage({super.key, required this.project});

  @override
  State<ExportPage> createState() => _ExportPageState();
}

class _ExportPageState extends State<ExportPage> {
  String? _outputDir;
  final Set<ExportFlag> _selected = {ExportFlag.yoloChar};
  bool _running = false;
  final StringBuffer _logBuf = StringBuffer();
  final ScrollController _logScroll = ScrollController();

  // 参数
  double _trainRatio = 0.8;
  int _seed = 42;
  int _targetHeight = 32;
  int _paddingColor = 255;
  int _pageStart = 1;
  int _pageEnd = 0; // 0 = 全部页

  void _append(String msg) {
    setState(() => _logBuf.writeln(msg));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _pickDir() async {
    final dir = await FilePicker.platform.getDirectoryPath(dialogTitle: '选择输出目录');
    if (dir != null) setState(() => _outputDir = dir);
  }

  void _toggleFlag(ExportFlag flag, bool? checked) {
    setState(() {
      if (checked == true) {
        _selected.add(flag);
      } else {
        _selected.remove(flag);
      }
    });
  }

  Future<void> _run() async {
    if (_outputDir == null || _selected.isEmpty) return;
    setState(() {
      _running = true;
      _logBuf.clear();
    });

    try {
      await _runExport();
    } catch (e) {
      _append('导出失败：$e');
    } finally {
      _append('\n全部流程结束。');
      setState(() => _running = false);
    }
  }

  Future<void> _runExport() async {
    final flags = Set<ExportFlag>.from(_selected);

    // ── 1. YOLO 四层 ──
    final needsYolo = flags.any((f) => const {
          ExportFlag.yoloRegion,
          ExportFlag.yoloParagraph,
          ExportFlag.yoloLine,
          ExportFlag.yoloChar,
        }.contains(f));

    if (needsYolo) {
      _append('═══ YOLO 数据集导出 ═══');
      final exporter = YoloExporter(
        project: widget.project,
        outputDir: _outputDir!,
        trainRatio: _trainRatio,
        seed: _seed,
        onLog: _append,
      );
      await exporter.exportAll(
        exportRegion: flags.contains(ExportFlag.yoloRegion),
        exportParagraph: flags.contains(ExportFlag.yoloParagraph),
        exportLine: flags.contains(ExportFlag.yoloLine),
        exportChar: flags.contains(ExportFlag.yoloChar),
        exportReadingOrder: false,
      );
    }

    // ── 2. 正文识字数据包 ──
    if (flags.contains(ExportFlag.crowdDataset)) {
      _append('\n═══ 正文识字数据包导出 ═══');
      final exporter = CrowdDatasetExporter(
        project: widget.project,
        onLog: _append,
      );
      final result = await exporter.export(
        outputDir: p.join(_outputDir!, 'crowd_dataset'),
        createZip: true,
        pageStart: _pageStart > 0 ? _pageStart : 1,
        pageEnd: _pageEnd > 0 ? _pageEnd : null,
      );
      _append('完成：${result.pageCount} 页、${result.lineCount} 行、${result.charCount} 字');
      if (result.errors.isNotEmpty) {
        _append('警告：${result.errors.length} 项未完全导出，详见 logs/export.log');
      }
    }

    // ── 2b. 识字任务包（未确认字，供命迹众包）──
    if (flags.contains(ExportFlag.crowdTasks)) {
      _append('\n═══ 识字任务包导出（未确认字） ═══');
      final exporter = CrowdDatasetExporter(
        project: widget.project,
        onLog: _append,
      );
      final result = await exporter.export(
        outputDir: p.join(_outputDir!, 'crowd_tasks'),
        createZip: true,
        unconfirmedOnly: true,
        pageStart: _pageStart > 0 ? _pageStart : 1,
        pageEnd: _pageEnd > 0 ? _pageEnd : null,
      );
      _append('完成：${result.pageCount} 页、${result.taskCount} 个待识别字'
          '（行结构含已确认字 ${result.charCount} 字，供整书文本重建）');
      _append('请将 crowd_tasks.zip 上传命迹管理后台「识字任务批次 → 导入数据包」。');
      if (result.errors.isNotEmpty) {
        _append('警告：${result.errors.length} 项未完全导出，详见 logs/export.log');
      }
    }

    // ── 3. 阅读顺序 JSON ──
    if (flags.contains(ExportFlag.readingOrder)) {
      _append('\n═══ 阅读顺序 JSON 导出 ═══');
      await _exportReadingOrderJson();
    }

    // ── 4. CRNN 行序列（+ LMDB 打包）──
    if (flags.contains(ExportFlag.crnn) || flags.contains(ExportFlag.lmdb)) {
      _append('\n═══ CRNN 行序列导出 ═══');
      final crnnCount = await _exportCrnnAllPages();
      if (crnnCount == 0) {
        _append('CRNN 导出 0 行，跳过 LMDB');
        return;
      }
      if (flags.contains(ExportFlag.lmdb)) {
        _append('\n═══ LMDB 打包 ═══');
        final crnnDir = p.join(_outputDir!, 'crnn_lines');
        final lmdbPath = p.join(_outputDir!, 'crnn.lmdb');
        try {
          final count = await PythonService.packLmdb(
            crnnOutputDir: crnnDir,
            lmdbPath: lmdbPath,
          );
          _append('LMDB 打包完成：$count 条 → $lmdbPath');
        } catch (e) {
          _append('LMDB 打包失败：$e');
        }
      }
    }
  }

  /// CRNN 导出：逐页调用后端 /export_crnn，所有行图写入 crnn_lines/pageId/ 子目录。
  Future<int> _exportCrnnAllPages() async {
    final crnnDir = p.join(_outputDir!, 'crnn_lines');
    await Directory(crnnDir).create(recursive: true);

    final pageCount = widget.project.imageFiles.length;
    var total = 0;
    for (var i = 0; i < pageCount; i++) {
      final pageId = widget.project.pageIdAt(i);
      final ann = await ProjectStorage.loadAnnotation(
        widget.project.projectDir,
        pageId,
      );
      if (ann == null) {
        _append('[$pageId] 无标注，跳过');
        continue;
      }
      if (ann.lines.isEmpty) {
        _append('[$pageId] 无行数据，跳过');
        continue;
      }
      // CRNN 训练序列只收已确认的行：每条样本是"行裁剪图+文本"，自包含、
      // 逐行过滤即可（与 YOLO 检测导出的整页门槛不同，不会产生图内漏标）。
      final confirmedLines = ann.lines
          .where((l) => l.status == AnnotationStatus.confirmed)
          .toList();
      if (confirmedLines.isEmpty) {
        _append('[$pageId] 无已确认行（临时保存），跳过');
        continue;
      }
      final skippedLines = ann.lines.length - confirmedLines.length;
      if (skippedLines > 0) {
        _append('[$pageId] 跳过 $skippedLines 行未确认（临时保存）');
      }
      final pageOutDir = p.join(crnnDir, pageId);
      try {
        final count = await PythonService.exportCrnn(
          imagePath: ann.imagePath,
          lines: confirmedLines,
          outputDir: pageOutDir,
          targetHeight: _targetHeight,
          paddingColor: _paddingColor,
        );
        total += count;
        _append('[$pageId] 导出 $count 行');
      } catch (e) {
        _append('[$pageId] CRNN 导出错误：$e');
      }
    }
    _append('CRNN 共导出 $total 行 → $crnnDir');
    await _mergeCrnnLabels(crnnDir);
    return total;
  }

  /// 合并 crnn_lines/page_*/labels.txt → crnn_lines/labels.txt（文件名加 page 前缀）。
  Future<void> _mergeCrnnLabels(String crnnDir) async {
    final mergedPath = p.join(crnnDir, 'labels.txt');
    final merged = <String>[];
    final pageDirs = <Directory>[];
    await for (final entry in Directory(crnnDir).list()) {
      if (entry is Directory) pageDirs.add(entry);
    }
    pageDirs.sort((a, b) => a.path.compareTo(b.path));
    for (final pageDir in pageDirs) {
      final labelsFile = File(p.join(pageDir.path, 'labels.txt'));
      if (!await labelsFile.exists()) continue;
      final pageId = p.basename(pageDir.path);
      final lines = await labelsFile.readAsLines();
      for (final line in lines) {
        if (line.isEmpty) continue;
        final tab = line.indexOf('\t');
        final space = line.indexOf(' ');
        final sep = tab >= 0 ? tab : space;
        if (sep <= 0) continue;
        final filename = line.substring(0, sep);
        final label = line.substring(sep + 1);
        merged.add('$pageId/$filename\t$label');
      }
    }
    await File(mergedPath).writeAsString(
      merged.isEmpty ? '' : '${merged.join('\n')}\n',
    );
    _append('合并 labels.txt → ${merged.length} 行');
  }

  /// 单独导出阅读顺序 JSON。
  Future<void> _exportReadingOrderJson() async {
    final pageCount = widget.project.imageFiles.length;
    final result = <Map<String, dynamic>>[];
    for (var i = 0; i < pageCount; i++) {
      final pageId = widget.project.pageIdAt(i);
      final ann = await ProjectStorage.loadAnnotation(
        widget.project.projectDir,
        pageId,
      );
      if (ann == null) {
        _append('[$pageId] 无标注，跳过');
        continue;
      }
      ann.inferHierarchy(
        orientation: widget.project.effectiveOrientationAt(i),
        horizontalDir: widget.project.settings.horizontalDir,
        verticalDir: widget.project.settings.verticalDir,
      );
      result.add({
        'page_id': pageId,
        'image_path': ann.imagePath,
        'lines': ReadingOrderCalculator.toJson(
          ann,
          orientation: widget.project.effectiveOrientationAt(i),
          horizontalDir: widget.project.settings.horizontalDir,
          verticalDir: widget.project.settings.verticalDir,
        ),
      });
    }
    final jsonPath = p.join(_outputDir!, 'reading_order.json');
    await File(jsonPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(result),
    );
    _append('阅读顺序 JSON → $jsonPath（${result.length} 页）');
  }

  @override
  void dispose() {
    _logScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('导出数据集')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _outputDir ?? '未选择输出目录',
                    style: const TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: _running ? null : _pickDir,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('选择目录'),
                ),
              ],
            ),
            const SizedBox(height: 20),

            const Text('导出类型', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: ExportFlag.values.map((flag) {
                return SizedBox(
                  width: 180,
                  child: CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _selected.contains(flag),
                    onChanged: _running ? null : (v) => _toggleFlag(flag, v),
                    title: Text(flag.label, style: const TextStyle(fontSize: 14)),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),

            // 页码范围（识字类导出可选：只导部分页，便于测试/分批分发）
            if (_selected.any((f) => const {
                  ExportFlag.crowdDataset,
                  ExportFlag.crowdTasks,
                }.contains(f))) ...[
              Row(
                children: [
                  const Text('页码范围（1 起，含首尾）：',
                      style: TextStyle(fontSize: 13)),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 90,
                    child: _ParamField(
                      label: '起始页',
                      value: _pageStart.toString(),
                      enabled: !_running,
                      onChanged: (v) => setState(
                          () => _pageStart = int.tryParse(v) ?? _pageStart),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 90,
                    child: _ParamField(
                      label: '结束页',
                      value: _pageEnd.toString(),
                      enabled: !_running,
                      onChanged: (v) => setState(
                          () => _pageEnd = int.tryParse(v) ?? _pageEnd),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '共 ${widget.project.imageFiles.length} 页；当前导出第 $_pageStart~'
                    '${_pageEnd.clamp(1, widget.project.imageFiles.length)} 页',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],

            ExpansionTile(
              title: const Text('高级参数', style: TextStyle(fontSize: 14)),
              tilePadding: EdgeInsets.zero,
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 200,
                      child: Text(
                        '训练集比例：${(_trainRatio * 100).toStringAsFixed(0)}%',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    Expanded(
                      child: Slider(
                        min: 0.5,
                        max: 0.95,
                        divisions: 9,
                        value: _trainRatio,
                        onChanged: _running
                            ? null
                            : (v) => setState(() => _trainRatio = v),
                      ),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 24,
                  children: [
                    _ParamField(
                      label: '随机种子',
                      value: _seed.toString(),
                      enabled: !_running,
                      onChanged: (v) => _seed = int.tryParse(v) ?? _seed,
                    ),
                    _ParamField(
                      label: 'CRNN 行高',
                      value: _targetHeight.toString(),
                      enabled: !_running,
                      onChanged: (v) =>
                          _targetHeight = int.tryParse(v) ?? _targetHeight,
                    ),
                    _ParamField(
                      label: 'Padding 色 (0-255)',
                      value: _paddingColor.toString(),
                      enabled: !_running,
                      onChanged: (v) => _paddingColor =
                          (int.tryParse(v) ?? _paddingColor).clamp(0, 255),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ),
            const SizedBox(height: 12),

            FilledButton.icon(
              onPressed: (_running || _outputDir == null || _selected.isEmpty)
                  ? null
                  : _run,
              icon: const Icon(Icons.file_download),
              label: const Text('开始导出'),
            ),

            if (_logBuf.isNotEmpty) ...[
              const SizedBox(height: 16),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  color: Colors.black87,
                  width: double.infinity,
                  child: SingleChildScrollView(
                    controller: _logScroll,
                    child: Text(
                      _logBuf.toString(),
                      style: const TextStyle(
                        color: Colors.greenAccent,
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 参数输入字段（避免每次 build 创建新 TextEditingController 导致光标跳动）。
class _ParamField extends StatefulWidget {
  final String label;
  final String value;
  final bool enabled;
  final ValueChanged<String> onChanged;

  const _ParamField({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  @override
  State<_ParamField> createState() => _ParamFieldState();
}

class _ParamFieldState extends State<_ParamField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
  }

  @override
  void didUpdateWidget(_ParamField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value && _controller.text != widget.value) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 140,
      child: TextField(
        decoration: InputDecoration(
          labelText: widget.label,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        keyboardType: TextInputType.number,
        controller: _controller,
        enabled: widget.enabled,
        onChanged: widget.onChanged,
      ),
    );
  }
}
