import 'package:flutter/material.dart';

import '../services/ai_trace.dart';
import '../widgets/ai_trace_entry_view.dart';

/// 编辑器「AI 溯源」面板：回看本页**最后一次识别运行**的完整 AI 辅助
/// 过程——按行分组的阶段时间线（三步分析 → YOLO 局部修复 → AI 复核），
/// 每条阶段展开可见：AI 看到的所有图、完整 prompt、思维链、原始返回、
/// 解析判定、门槛逐项 pass/fail、写入 diff、修复前后对比。
class AiTracePanel extends StatefulWidget {
  const AiTracePanel({
    super.key,
    required this.projectDir,
    required this.pageId,
    required this.pageLabel,
  });

  final String projectDir;
  final String pageId;
  final String pageLabel;

  @override
  State<AiTracePanel> createState() => _AiTracePanelState();
}

class _AiTracePanelState extends State<AiTracePanel> {
  AiTraceRun? _run;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final run = await AiTraceRecorder.load(widget.projectDir, widget.pageId);
    if (!mounted) return;
    setState(() {
      _run = run;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final run = _run;
    final body = _loading
        ? const Center(child: Text('读取溯源记录…'))
        : (run == null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.manage_history,
                        size: 40,
                        color: Colors.grey.shade400,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '本页还没有 AI 溯源记录。\n'
                        '开启整行 AI 辅助完成一次识别后，这里能看到每行'
                        '「AI 看到的图 / 提示词 / 思考过程 / 判定 / 写入 / '
                        'YOLO 修复」的全过程（仅保留最后一次运行）。',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.7,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                )
              : _runView(context, run));
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        title: Text('AI 溯源 · ${widget.pageLabel}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '重新读取',
            onPressed: _loading ? null : _load,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: body,
    );
  }

  Widget _runView(BuildContext context, AiTraceRun run) {
    // 按行分组，保持记录顺序（行内阶段天然按 assist→repair→reverify 排列）。
    final lineOrder = <String>[];
    final byLine = <String, List<AiTraceEntry>>{};
    for (final e in run.entries) {
      byLine.putIfAbsent(e.lineId, () {
        lineOrder.add(e.lineId);
        return <AiTraceEntry>[];
      }).add(e);
    }
    final assistN = run.entries
        .where((e) => e.stage == AiTraceStage.assist)
        .length;
    final repairN = run.entries
        .where((e) => e.stage == AiTraceStage.repair)
        .length;
    final adoptedN = run.entries
        .where((e) => e.stage == AiTraceStage.repair && e.repair?.adopted == true)
        .length;
    final appliedN = run.entries
        .where((e) => e.stage != AiTraceStage.repair && e.outcomePass)
        .length;
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.45,
          ),
          child: Text(
            '运行于 ${run.startedAt.toLocal()} · ${run.model.isEmpty ? '未记录模型' : run.model}'
            '${run.provider == 'external' ? '（外部 API）' : '（本地 Ollama）'}\n'
            '共 ${run.entries.length} 条阶段记录：三步分析 $assistN（采纳文字 $appliedN）'
            '· 局部修复 $repairN（采纳 $adoptedN）。仅保留本页最后一次识别运行。',
            style: const TextStyle(fontSize: 12, height: 1.6),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(10),
            itemCount: lineOrder.length,
            itemBuilder: (context, i) {
              final lineId = lineOrder[i];
              final entries = byLine[lineId]!;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 2),
                    child: Text(
                      '行 $lineId（${entries.length} 个阶段）',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.blueGrey.shade700,
                      ),
                    ),
                  ),
                  for (final e in entries)
                    AiTraceEntryView(
                      entry: e,
                      imageLoader: (file) => AiTraceRecorder.loadImage(
                        widget.projectDir,
                        widget.pageId,
                        file,
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 编辑器入口：以对话框形式打开溯源面板（宽屏）。
Future<void> showAiTracePanel(
  BuildContext context, {
  required String projectDir,
  required String pageId,
  required String pageLabel,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860, maxHeight: 720),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: AiTracePanel(
            projectDir: projectDir,
            pageId: pageId,
            pageLabel: pageLabel,
          ),
        ),
      ),
    ),
  );
}
