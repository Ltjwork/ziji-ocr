import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/dynasty_bench_store.dart';
import '../services/python_service.dart';
import '../services/single_page_pipeline.dart';
import 'dynasty_bench_detail_page.dart';

/// 朝代基准测试页：先秦→明清五张固定古籍样张（test_images/periods），
/// 每张附基准释文（应识别出的文字），一键用当前识别管线（与整本识别
/// 完全同链路：/segment 版面+Kraken + 阅读顺序重排）逐张识别，与基准
/// 对齐出各时期字准确率/CER；每次运行落盘 runs/，历史任选两次对比。
///
/// 指标与落盘在后端（dynasty_bench.py，与消融评测同口径）；本页只负责
/// 执行识别、拼预测文本（ReadingOrderCalculator 与编辑器同源）与展示。
class DynastyBenchPage extends StatefulWidget {
  const DynastyBenchPage({super.key});

  @override
  State<DynastyBenchPage> createState() => _DynastyBenchPageState();
}

class _DynastyBenchPageState extends State<DynastyBenchPage> {
  String? _benchDir;
  String? _loadError;
  List<Map<String, dynamic>> _cases = const [];
  bool _running = false;
  String _progress = '';
  Map<String, dynamic>? _lastRecord;
  // 与整本识别同款的 AI 整行裁决是否纳入测试（仍受全局 AI 设置与所选
  // 模型约束；跳过原因会记进运行记录）。
  bool _useAiAssist = true;
  // 展开基准释文的样张 id（默认全收起，释文较长）。
  final Set<String> _expandedGt = {};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    final dir = await DynastyBenchStore.resolve();
    if (dir == null) {
      // 目录都没有：切换到"选择基准目录"引导页（_benchDir 置空）。
      setState(() => _benchDir = null);
      return;
    }
    setState(() => _benchDir = dir);
    try {
      final cases = await PythonService.benchDynastyCases(benchDir: dir);
      setState(() => _cases = cases);
      unawaited(_restoreLastRun());
    } catch (e) {
      // 目录在但样张清单没拿到（多半是识别服务未就绪）：保留目录展示，
      // 页内报错可重试，不要误导向"未找到基准目录"。
      setState(() => _loadError = '$e');
    }
  }

  /// 打开页面时恢复最近一次运行的记录（含指标与字框明细），重开应用
  /// 也能直接人工查看上次效果；失败静默（下次运行会覆盖）。
  Future<void> _restoreLastRun() async {
    try {
      final runs = await PythonService.benchDynastyRuns(benchDir: _benchDir!);
      final path = runs.isEmpty ? null : runs.first['path'] as String?;
      if (path == null) return;
      final file = File(path);
      if (!await file.exists()) return;
      final rec = jsonDecode(await file.readAsString());
      if (rec is Map) {
        setState(() => _lastRecord = Map<String, dynamic>.from(rec));
      }
    } catch (_) {
      // 后端未就绪或记录损坏：跳过恢复，不影响主流程。
    }
  }

  Future<void> _pickDir() async {
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择朝代基准目录（含样张图片与 gt/*.json）',
    );
    if (dir == null) return;
    if (!await DynastyBenchStore.choose(dir)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('所选目录不是基准目录：缺少 gt/01_xianqin.json')),
      );
      return;
    }
    await _load();
  }

  Future<void> _runBench() async {
    if (_running || _cases.isEmpty) return;
    final cases = List<Map<String, dynamic>>.from(_cases);
    setState(() {
      _running = true;
      _progress = '准备运行…';
      _lastRecord = null;
    });
    final preds = <Map<String, dynamic>>[];
    try {
      for (var i = 0; i < cases.length; i++) {
        final c = cases[i];
        final label = '${c['era']} · ${c['book']}';
        setState(() => _progress = '识别中 ${i + 1}/${cases.length}：$label');
        preds.add(await _recognizeCase(c));
      }
      setState(() => _progress = '对齐评测并保存运行记录…');
      final record = await PythonService.benchDynastyEval(
        benchDir: _benchDir!,
        preds: preds,
      );
      setState(() => _lastRecord = record);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('基准测试中断：$e')),
        );
      }
    } finally {
      setState(() {
        _running = false;
        _progress = '';
      });
    }
  }

  /// 单张样张走**正常书籍识别管线**（与整本识别 ensurePageAnnotation 同
  /// 步序）。编排已提取到 single_page_pipeline.dart（与「AI 画框测试」
  /// 对比页共用），这里只拼评测 payload——管线元信息（版面引擎/回退
  /// 原因/YOLO 诊断/AI 状态）随提交项存进运行记录。
  Future<Map<String, dynamic>> _recognizeCase(Map<String, dynamic> c) async {
    final id = c['id'] as String;
    final imagePath = c['image_path'] as String;
    final ro = (c['reading_order'] as Map?)?.cast<String, dynamic>() ?? const {};
    final settings = ProjectSettings(
      layoutMode: 'all_text',
      orientation: ro['orientation'] as String? ?? 'vertical',
      horizontalDir: ro['horizontal_dir'] as String? ?? 'rtl',
      verticalDir: ro['vertical_dir'] as String? ?? 'ttb',
    );
    final sw = Stopwatch()..start();
    try {
      final r = await runSinglePagePipeline(
        imagePath: imagePath,
        pageId: id,
        settings: settings,
        useAiAssist: _useAiAssist,
        onProgress: (stage) => setState(() => _progress = stage),
      );
      final text = r.orderedLines
          .map((l) => l.chars.map((ch) => ch.text).join())
          .join();
      // 字框明细（人工查看用）：行框 + 字框 + 逐字置信度/类型，随运行
      // 记录原样存档（格式基准声明见 dynasty_bench.py _case_report）。
      final linesPayload = [
        for (final l in r.orderedLines)
          {
            'x': l.x,
            'y': l.y,
            'w': l.w,
            'h': l.h,
            'text': l.chars.map((ch) => ch.text).join(),
            'chars': [
              for (final ch in l.chars)
                {
                  'x': ch.x,
                  'y': ch.y,
                  'w': ch.w,
                  'h': ch.h,
                  'text': ch.text,
                  'conf': ch.conf,
                  'type': ch.type,
                },
            ],
          },
      ];
      return {
        'id': id,
        'pred_text': text,
        'line_count': r.orderedLines.length,
        'duration_ms': r.totalMs,
        'lines': linesPayload,
        // 管线元信息：engine=hier（自训 YOLO 层级）/ opencv（回退），
        // fallback_reason 空 = 自训模型全程生效；ai_assist 见上。
        'engine': r.segmentMeta['engine'],
        'fallback_reason': r.segmentMeta['fallback_reason'],
        'converter': r.segmentMeta['converter'],
        'yolo': r.segmentMeta['yolo'],
        'ai_assist': {
          'status': r.aiAssistStatus,
          if (r.aiAssistStatus == 'applied') 'model': r.aiAssistModel,
        },
      };
    } catch (e) {
      return {'id': id, 'error': '$e', 'duration_ms': sw.elapsedMilliseconds};
    }
  }

  Future<void> _showCompare() async {
    if (_benchDir == null) return;
    try {
      final runs = await PythonService.benchDynastyRuns(benchDir: _benchDir!);
      if (!mounted) return;
      if (runs.length < 2) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('历史运行不足两次（当前 ${runs.length} 次），先多跑几轮再对比')),
        );
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (_) => _BenchCompareDialog(runs: runs, eraOf: _eraOf),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('读取历史失败：$e')));
      }
    }
  }

  String _eraOf(String id) {
    for (final c in _cases) {
      if (c['id'] == id) return c['era'] as String? ?? id;
    }
    return id;
  }

  /// 打开样张详情页：原图缩放 + 字框叠加 + 基准/识别文字对照（人工查看）。
  void _openDetail(Map<String, dynamic> c, Map<String, dynamic>? report) {
    final linesRaw = report?['lines'];
    final lines = linesRaw is List
        ? [for (final l in linesRaw) Map<String, dynamic>.from(l as Map)]
        : null;
    final units = (c['units'] as List? ?? const [])
        .map((u) => Map<String, dynamic>.from(u as Map))
        .toList();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DynastyBenchDetailPage(
          title: '${c['era']} · ${c['book']}',
          imagePath: c['image_path'] as String? ?? '',
          gtUnits: units,
          lines: lines,
          report: report,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final aggregate = _lastRecord?['aggregate'];
    final cases = _lastRecord?['cases'];
    final reportOf = <String, Map<String, dynamic>>{};
    if (cases is List) {
      for (final c in cases) {
        if (c is Map) reportOf[c['id'] as String] = Map<String, dynamic>.from(c);
      }
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('朝代基准测试'),
        actions: [
          TextButton.icon(
            onPressed: _running ? null : _showCompare,
            icon: const Icon(Icons.compare_arrows, size: 18),
            label: const Text('历史对比'),
          ),
          TextButton.icon(
            onPressed: _running ? null : _pickDir,
            icon: const Icon(Icons.folder_open_outlined, size: 18),
            label: const Text('选择目录'),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _buildBody(context, aggregate, reportOf),
    );
  }

  Widget _buildBody(
    BuildContext context,
    dynamic aggregate,
    Map<String, Map<String, dynamic>> reportOf,
  ) {
    if (_benchDir == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '未找到朝代基准目录（样张图片 + gt/*.json 基准释文）。\n'
                '默认位置：ocr/test_images/periods',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey, fontSize: 12.5, height: 1.6),
              ),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: _pickDir,
                icon: const Icon(Icons.folder_open_outlined, size: 18),
                label: const Text('选择基准目录'),
              ),
              if (_loadError != null) ...[
                const SizedBox(height: 12),
                Text(
                  _loadError!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        if (_running)
          Material(
            color: Theme.of(context).colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _progress,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (aggregate is Map)
          _AggregateBar(aggregate: Map<String, dynamic>.from(aggregate)),
        if (_loadError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '样张清单加载失败：$_loadError',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 11.5,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: _running ? null : _load,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('重试'),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '基准目录：$_benchDir',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.grey, fontSize: 11.5),
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: '等价于整本识别的项目级「AI 辅助识别」开关（读行→逐字对应→诊断修复）；'
                    '未选视觉/文本模型时自动跳过并把原因记进运行记录',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: _useAiAssist,
                      onChanged: _running
                          ? null
                          : (v) => setState(() => _useAiAssist = v ?? false),
                    ),
                    const Text('AI 整行裁决', style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _running || _cases.isEmpty ? null : _runBench,
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('运行测试'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            itemCount: _cases.length,
            itemBuilder: (_, i) =>
                _CaseCard(
                  caseData: _cases[i],
                  report: reportOf[_cases[i]['id']],
                  expanded: _expandedGt.contains(_cases[i]['id']),
                  onToggleGt: () => setState(() {
                    final id = _cases[i]['id'] as String;
                    if (!_expandedGt.remove(id)) _expandedGt.add(id);
                  }),
                  onOpenDetail: () =>
                      _openDetail(_cases[i], reportOf[_cases[i]['id']]),
                ),
          ),
        ),
      ],
    );
  }
}

/// 顶部聚合指标条：整体（按字数加权）与跨时期平均水位。
class _AggregateBar extends StatelessWidget {
  final Map<String, dynamic> aggregate;

  const _AggregateBar({required this.aggregate});

  @override
  Widget build(BuildContext context) {
    final acc = aggregate['accuracy'] as num?;
    final macro = aggregate['macro_accuracy'] as num?;
    final failed = (aggregate['cases_failed'] as num?) ?? 0;
    final gtLen = aggregate['gt_len'] as num? ?? 0;
    final secs = ((aggregate['duration_ms'] as num?) ?? 0) / 1000.0;
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: cs.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Wrap(
        spacing: 18,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '整体字准确率 ${acc == null ? '—' : '${(acc * 100).toStringAsFixed(1)}%'}'
            '（CER ${acc == null ? '—' : '${((1 - acc) * 100).toStringAsFixed(1)}%'}）',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
          Text(
            '跨时期平均 ${macro == null ? '—' : '${(macro * 100).toStringAsFixed(1)}%'}',
            style: const TextStyle(fontSize: 12.5),
          ),
          Text(
            '基准字数 $gtLen · 用时 ${secs.toStringAsFixed(0)}s'
            '${failed > 0 ? ' · 识别失败 $failed 张' : ''}',
            style: const TextStyle(color: Colors.grey, fontSize: 11.5),
          ),
        ],
      ),
    );
  }
}

/// 单个时期的样张卡：书影缩略图 + 书目信息 + 基准释文（可展开）+
/// 最近一次运行的指标（准确率/替换/漏/多/耗时/识别失败原因）。
class _CaseCard extends StatelessWidget {
  final Map<String, dynamic> caseData;
  final Map<String, dynamic>? report;
  final bool expanded;
  final VoidCallback onToggleGt;
  final VoidCallback onOpenDetail;

  const _CaseCard({
    required this.caseData,
    required this.report,
    required this.expanded,
    required this.onToggleGt,
    required this.onOpenDetail,
  });

  Color _accuracyColor(double accuracy) {
    if (accuracy >= 0.9) return Colors.green.shade700;
    if (accuracy >= 0.7) return Colors.deepOrange.shade600;
    return Colors.red.shade600;
  }

  String _unitsText() {
    final units = caseData['units'];
    if (units is! List) return '';
    return units
        .map((u) => u is Map ? (u['text'] ?? '') as String : '')
        .join('　');
  }

  @override
  Widget build(BuildContext context) {
    final imagePath = caseData['image_path'] as String? ?? '';
    final acc = report?['accuracy'] as num?;
    final error = report?['error'] as String?;
    final confLabel = switch (caseData['gt_confidence'] as String?) {
      'high' => '基准置信度高',
      'medium' => '基准置信度中',
      'low' => '基准置信度低',
      _ => null,
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 86,
              height: 116,
              child: Tooltip(
                message: '点击放大查看（缩放 / 字框 / 基准对照）',
                child: InkWell(
                  onTap: onOpenDetail,
                  borderRadius: BorderRadius.circular(6),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.file(
                          File(imagePath),
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const ColoredBox(
                            color: Colors.black12,
                            child: Center(
                              child: Icon(Icons.broken_image_outlined, size: 26),
                            ),
                          ),
                        ),
                        // 悬停提示可点击（桌面端）。
                        Positioned.fill(
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: ColoredBox(
                              color: Colors.transparent,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          '${caseData['era']} · ${caseData['book']}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      if (acc != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Text(
                            '${(acc * 100).toStringAsFixed(1)}%',
                            style: TextStyle(
                              color: _accuracyColor(acc.toDouble()),
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  if (report != null) _reportLines(report!),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '识别失败：$error',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 11.5,
                        ),
                      ),
                    ),
                  const SizedBox(height: 6),
                  InkWell(
                    onTap: onToggleGt,
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            expanded
                                ? Icons.expand_less
                                : Icons.expand_more,
                            size: 16,
                            color: Colors.grey.shade700,
                          ),
                          Text(
                            '基准释文（应识别内容${confLabel != null ? ' · $confLabel' : ''}）',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: Colors.grey.shade700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (expanded) ...[
                    const SizedBox(height: 4),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      constraints: const BoxConstraints(maxHeight: 180),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          _unitsText(),
                          style: const TextStyle(
                            fontSize: 12.5,
                            height: 1.7,
                          ),
                        ),
                      ),
                    ),
                    if ((caseData['gt_notes'] as String? ?? '').isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          caseData['gt_notes'] as String,
                          maxLines: expanded ? 6 : 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 11,
                            height: 1.5,
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _reportLines(Map<String, dynamic> r) {
    final secs = ((r['duration_ms'] as num?) ?? 0) / 1000.0;
    final lines = (r['line_count'] as num?) ?? 0;
    final predLen = r['pred_len'] as num? ?? 0;
    final gtLen = r['gt_len'] as num? ?? 0;
    final confusions = r['top_confusions'];
    String confusionLine = '';
    if (confusions is List && confusions.isNotEmpty) {
      confusionLine = '　错字TOP：';
      confusionLine += confusions
          .take(6)
          .map((c) {
            if (c is List && c.length >= 3) {
              return '${c[0]}→${c[1]}×${c[2]}';
            }
            return '';
          })
          .where((s) => s.isNotEmpty)
          .join('、');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '识别 $lines 行 $predLen 字 / 基准 $gtLen 字 · '
          '替换 ${r['sub']} 漏 ${r['del']} 多 ${r['ins']} · '
          '用时 ${secs.toStringAsFixed(1)}s$confusionLine',
          style: const TextStyle(color: Colors.grey, fontSize: 11.5, height: 1.5),
        ),
        Text(
          _pipelineLine(r),
          style: const TextStyle(color: Colors.grey, fontSize: 11.5, height: 1.5),
        ),
      ],
    );
  }

  /// 管线信息行：版面引擎（hier=自训 YOLO 层级 / opencv=回退+原因）、
  /// YOLO 字模是否加载、AI 整行裁决状态。旧记录无这些字段时整行隐藏。
  String _pipelineLine(Map<String, dynamic> r) {
    final engine = r['engine'] as String?;
    if (engine == null) return '';
    final fallback = r['fallback_reason'] as String?;
    final yolo = r['yolo'];
    final yoloInit = yolo is Map ? (yolo['initialized'] as bool? ?? false) : null;
    final ai = r['ai_assist'];
    String aiLabel = 'AI 未记录';
    if (ai is Map) {
      final model = ai['model'] as String?;
      aiLabel = switch (ai['status'] as String?) {
        'applied' => 'AI 已应用${model == null ? '' : '（$model）'}',
        'skipped-no-model' => 'AI 未选模型',
        'skipped-toggle' => 'AI 已关闭（本页开关）',
        _ => 'AI ${ai['status']}',
      };
    }
    final engineLabel = engine == 'hier'
        ? (fallback == null ? '版面 hier（自训 YOLO）' : '版面 hier（部分回退：$fallback）')
        : '版面 opencv（回退${fallback == null ? '' : '：$fallback'}）';
    return '$engineLabel'
        '${yoloInit == null ? '' : ' · YOLO 字模${yoloInit ? '已加载' : '未加载'}'}'
        ' · $aiLabel';
  }
}

/// 历史对比对话框：任选两次运行，逐时期准确率对照 + 差值。
class _BenchCompareDialog extends StatefulWidget {
  final List<Map<String, dynamic>> runs;
  final String Function(String id) eraOf;

  const _BenchCompareDialog({required this.runs, required this.eraOf});

  @override
  State<_BenchCompareDialog> createState() => _BenchCompareDialogState();
}

class _BenchCompareDialogState extends State<_BenchCompareDialog> {
  late String _a;
  late String _b;

  @override
  void initState() {
    super.initState();
    _a = widget.runs.first['run_id'] as String;
    _b = widget.runs.length > 1
        ? widget.runs[1]['run_id'] as String
        : _a;
  }

  Map<String, dynamic>? _run(String id) {
    for (final r in widget.runs) {
      if (r['run_id'] == id) return r;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final runA = _run(_a);
    final runB = _run(_b);
    final perA = (runA?['per_case'] as Map?)?.cast<String, dynamic>() ?? {};
    final perB = (runB?['per_case'] as Map?)?.cast<String, dynamic>() ?? {};
    final ids = {...perA.keys, ...perB.keys}.toList()..sort();
    return AlertDialog(
      title: const Text('历史运行对比'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: _runDropdown('运行 A', _a, (v) => setState(() => _a = v))),
                const SizedBox(width: 12),
                Expanded(child: _runDropdown('运行 B', _b, (v) => setState(() => _b = v))),
              ],
            ),
            const SizedBox(height: 12),
            Table(
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              columnWidths: const {
                0: FlexColumnWidth(2.2),
                1: FlexColumnWidth(1),
                2: FlexColumnWidth(1),
                3: FlexColumnWidth(1),
              },
              children: [
                const TableRow(
                  children: [
                    Text('时期', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                    Text('A 准确率', textAlign: TextAlign.end, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                    Text('B 准确率', textAlign: TextAlign.end, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                    Text('Δ(A−B)', textAlign: TextAlign.end, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                  ],
                ),
                for (final id in ids)
                  TableRow(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.03),
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Text(widget.eraOf(id), style: const TextStyle(fontSize: 12)),
                      ),
                      _accCell(_accOf(perA[id])),
                      _accCell(_accOf(perB[id])),
                      _deltaCell(_accOf(perA[id]), _accOf(perB[id])),
                    ],
                  ),
                TableRow(
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        '整体（字数加权）',
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        _fmt((runA?['accuracy'] as num?)?.toDouble()),
                        textAlign: TextAlign.end,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        _fmt((runB?['accuracy'] as num?)?.toDouble()),
                        textAlign: TextAlign.end,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        _deltaText(
                          (runA?['accuracy'] as num?)?.toDouble(),
                          (runB?['accuracy'] as num?)?.toDouble(),
                        ),
                        textAlign: TextAlign.end,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'A：${_runLabel(runA)}\nB：${_runLabel(runB)}',
              style: const TextStyle(color: Colors.grey, fontSize: 11, height: 1.6),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('关闭')),
      ],
    );
  }

  String _runLabel(Map<String, dynamic>? r) =>
      r == null ? '—' : '${r['ts']} · ${r['backend_build']}';

  /// 该次运行里此样张的准确率；NaN 表示该次识别失败（与 0 分区分）。
  double? _accOf(dynamic v) {
    if (v is Map) {
      final acc = v['accuracy'];
      if (acc is num) return acc.toDouble();
      if (v['error'] is String && (v['error'] as String).isNotEmpty) {
        return double.nan;
      }
    }
    return null;
  }

  String _fmt(double? v) => v == null
      ? '—'
      : v.isNaN
          ? '失败'
          : '${(v * 100).toStringAsFixed(1)}%';

  Widget _runDropdown(String label, String value, ValueChanged<String> onChanged) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      decoration: InputDecoration(labelText: label, isDense: true),
      isExpanded: true,
      items: [
        for (final r in widget.runs)
          DropdownMenuItem(
            value: r['run_id'] as String,
            child: Text(
              '${r['ts']}（${_fmt((r['accuracy'] as num?)?.toDouble())}）',
              style: const TextStyle(fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }

  Widget _accCell(double? v) {
    return Text(
      _fmt(v),
      textAlign: TextAlign.end,
      style: const TextStyle(fontSize: 12),
    );
  }

  Widget _deltaCell(double? a, double? b) {
    final text = _deltaText(a, b);
    final color = a == null || b == null || a.isNaN || b.isNaN
        ? Colors.grey
        : a >= b
            ? Colors.green.shade700
            : Colors.red.shade600;
    return Text(
      text,
      textAlign: TextAlign.end,
      style: TextStyle(fontSize: 12, color: color),
    );
  }

  String _deltaText(double? a, double? b) {
    if (a == null || b == null || a.isNaN || b.isNaN) return '—';
    final d = (a - b) * 100;
    return '${d >= 0 ? '+' : ''}${d.toStringAsFixed(1)}pp';
  }
}
