import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/ai_trace.dart';

/// 溯源条目渲染组件（编辑器「AI 溯源」面板与对比页「AI 过程」共用）：
/// 一个阶段 = AI 看到的图组（缩略图墙，点击放大）→ 完整 prompt → 思维链
/// → 原始返回 → 门槛逐项判定 → 写入 diff；修复阶段额外渲染触发、尾段
/// 矩形、前后质量分与重摆新框。
class AiTraceEntryView extends StatelessWidget {
  const AiTraceEntryView({
    super.key,
    required this.entry,
    required this.imageLoader,
    this.initiallyExpanded = false,
  });

  final AiTraceEntry entry;

  /// 图片字节加载器：编辑器面板从磁盘读（AiTraceRecorder.loadImage），
  /// 对比页从内存 recorder 读（imageBytesOf）。
  final Future<Uint8List?> Function(String file) imageLoader;

  /// 默认展开（true）或折叠（false，列表里多条目时省屏）。
  final bool initiallyExpanded;

  static final Map<String, String> _issueLabels = {
    'char_clipped': '切掉字形一部分',
    'char_merged': '一个框装了两个字',
    'char_extra_ink': '多包进旁边墨迹',
    'count_mismatch': 'AI 读出字数多于框数（疑似漏字）',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          title: Row(
            children: [
              _stageBadge(context),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  entry.outcome.isEmpty ? entry.stage.label : entry.outcome,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: entry.outcomePass
                        ? Colors.green.shade800
                        : (entry.error != null
                              ? Colors.red.shade700
                              : theme.colorScheme.onSurface),
                  ),
                ),
              ),
            ],
          ),
          subtitle: Text(
            '${entry.at.hour.toString().padLeft(2, '0')}:'
            '${entry.at.minute.toString().padLeft(2, '0')}:'
            '${entry.at.second.toString().padLeft(2, '0')} · '
            '${entry.elapsedMs > 0 ? '${entry.elapsedMs}ms · ' : ''}'
            '${entry.model.isEmpty ? '后端重摆' : entry.model}'
            '${entry.provider == 'external' ? '（外部 API）' : ''}',
            style: const TextStyle(fontSize: 11),
          ),
          children: [
            if (entry.error != null)
              _box(
                '失败原因',
                entry.error!,
                color: Colors.red.shade50,
                textColor: Colors.red.shade900,
              ),
            if (entry.images.isNotEmpty) ...[
              _heading('① AI 看到的图（${entry.images.length} 张，点击放大）'),
              _imageGallery(context),
            ],
            if (entry.prompt.isNotEmpty) ...[
              _heading('② 完整提示词'),
              _mono(entry.prompt),
            ],
            if (entry.thinking.isNotEmpty) ...[
              _heading('③ 思考过程'),
              _mono(entry.thinking, color: Colors.deepPurple.shade50),
            ],
            if (entry.rawContent.isNotEmpty) ...[
              _heading('④ 模型原始返回'),
              _mono(entry.rawContent, dark: true),
            ],
            if (entry.decisionJson.isNotEmpty) ...[
              _heading('⑤ 解析后的判定'),
              _mono(entry.decisionJson),
            ],
            if (entry.checks.isNotEmpty) ...[
              _heading('⑥ 门槛判定'),
              ...[
                for (final c in entry.checks)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          c.pass ? Icons.check_circle : Icons.cancel,
                          size: 15,
                          color: c.pass ? Colors.green : Colors.red,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '${c.name}${c.detail.isEmpty ? '' : '（${c.detail}）'}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
            if (entry.writes.isNotEmpty) ...[
              _heading('⑦ 写入内容（旧 → 新）'),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final w in entry.writes)
                    Tooltip(
                      message: w.aiApplied
                          ? (w.addedCandidates.isEmpty
                                ? '文字被 AI 覆盖'
                                : '文字被 AI 覆盖；新增候选：'
                                      '${w.addedCandidates.join(' ')}')
                          : (w.boxIssue != null
                                ? '标记切分问题：${_issueLabels[w.boxIssue] ?? w.boxIssue!}'
                                : '仅并入候选：${w.addedCandidates.join(' ')}'),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: w.aiApplied
                              ? Colors.green.shade50
                              : (w.boxIssue != null
                                    ? Colors.orange.shade50
                                    : Colors.blueGrey.shade50),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        child: Text(
                          '${w.order}: ${w.oldText.isEmpty ? '∅' : w.oldText}'
                          '${w.newText == w.oldText ? '' : ' → ${w.newText}'}'
                          '${w.boxIssue != null ? ' ⚠' : ''}',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                ],
              ),
            ],
            if (entry.repair != null) _repairSection(context, entry.repair!),
          ],
        ),
      ),
    );
  }

  Widget _stageBadge(BuildContext context) {
    final (color, icon) = switch (entry.stage) {
      AiTraceStage.assist => (Colors.blueGrey, Icons.visibility_outlined),
      AiTraceStage.repair => (Colors.deepOrange, Icons.build_outlined),
      AiTraceStage.reverify => (Colors.green, Icons.verified_outlined),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(
            entry.stage.label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.only(top: 10, bottom: 4),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: Colors.grey.shade700,
      ),
    ),
  );

  Widget _box(
    String title,
    String body, {
    Color? color,
    Color? textColor,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: textColor ?? Colors.grey.shade700,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color ?? Colors.grey.shade100,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(body, style: TextStyle(fontSize: 12, color: textColor)),
        ),
      ],
    ),
  );

  Widget _mono(String text, {bool dark = false, Color? color}) => Container(
    width: double.infinity,
    constraints: const BoxConstraints(maxHeight: 260),
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: dark ? Colors.grey.shade900 : (color ?? Colors.grey.shade100),
      borderRadius: BorderRadius.circular(6),
    ),
    child: SingleChildScrollView(
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontFamily: 'monospace',
          color: dark ? Colors.greenAccent.shade200 : Colors.black87,
          height: 1.35,
        ),
      ),
    ),
  );

  Widget _imageGallery(BuildContext context) {
    return SizedBox(
      height: 132,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: entry.images.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final im = entry.images[i];
          return FutureBuilder<Uint8List?>(
            future: imageLoader(im.file),
            builder: (context, snap) {
              final bytes = snap.data;
              return GestureDetector(
                onTap: bytes == null
                    ? null
                    : () => _zoomImage(context, bytes, im.label),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      height: 104,
                      width: 104,
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(6),
                        color: Colors.white,
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: bytes == null
                          ? const Center(
                              child: Icon(
                                Icons.broken_image_outlined,
                                size: 22,
                                color: Colors.grey,
                              ),
                            )
                          : Image.memory(bytes, fit: BoxFit.contain,
                              gaplessPlayback: true),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      im.label,
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _repairSection(BuildContext context, AiTraceRepair rep) {
    final children = <Widget>[
      _heading('⑧ YOLO 局部修复详情'),
      _kv('触发', rep.trigger),
      _kv(
        '重摆范围',
        rep.startOrder <= 0
            ? '整行（第 0 号框前无锚框）'
            : '第 ${rep.startOrder - 1} 号框起始边 → 行末尾',
      ),
      if (rep.tailRect.isNotEmpty)
        _kv(
          '尾段矩形',
          '(${rep.tailRect['x']}, ${rep.tailRect['y']}, '
          '${rep.tailRect['w']}×${rep.tailRect['h']})'
          '${rep.backendLines > 1 ? '（后端拆成 ${rep.backendLines} 行）' : ''}',
        ),
      _kv(
        '字框变化',
        '${rep.oldTailCount} → ${rep.newChars.length}'
        '${rep.newChars.length != rep.oldTailCount ? '' : '（数量不变）'}',
      ),
      _kv(
        '质量分',
        '${rep.beforeScore.toStringAsFixed(2)} → '
        '${rep.afterScore.toStringAsFixed(2)}',
      ),
      _kv(
        '裁决',
        rep.adopted ? '✅ 已采纳并合并回整行' : '⛔ 未采纳（${rep.reason}）',
        color: rep.adopted ? Colors.green.shade800 : Colors.orange.shade900,
      ),
    ];
    if (rep.newChars.isNotEmpty) {
      children.add(const SizedBox(height: 4));
      children.add(
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final c in rep.newChars)
              Tooltip(
                message:
                    '(${c['x']}, ${c['y']}, ${c['w']}×${c['h']}) '
                    'conf=${c['conf']}',
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.deepOrange.shade50,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.deepOrange.shade200),
                  ),
                  child: Text(
                    (c['text']?.toString() ?? '').isEmpty
                        ? '∅'
                        : c['text'].toString(),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
          ],
        ),
      );
    }
    if (rep.debugTrace.isNotEmpty) {
      children.add(const SizedBox(height: 6));
      children.add(_mono(rep.debugTrace.join('\n'), dark: true));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }

  Widget _kv(String k, String v, {Color? color}) => Padding(
    padding: const EdgeInsets.only(bottom: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 64,
          child: Text(
            k,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
        ),
        Expanded(
          child: Text(
            v,
            style: TextStyle(fontSize: 12, color: color, height: 1.3),
          ),
        ),
      ],
    ),
  );
}

/// 图片放大查看（可缩放拖动）。
Future<void> showAiTraceZoomImage(
  BuildContext context,
  Uint8List bytes,
  String label,
) {
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Expanded(
            child: InteractiveViewer(
              maxScale: 8,
              child: Center(
                child: Image.memory(bytes, fit: BoxFit.contain,
                    gaplessPlayback: true),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

void _zoomImage(BuildContext context, Uint8List bytes, String label) =>
    showAiTraceZoomImage(context, bytes, label);
