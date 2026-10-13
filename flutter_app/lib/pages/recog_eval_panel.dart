import 'package:flutter/material.dart';

/// 识别消融评测结果面板（模型对比测试页"识别消融"模式）。
///
/// 展示 A 裸模型·整行读法 / B 像素切分+逐框读法 / C 全链路 三档的
/// 字准确率、CER、标点错误与耗时；A−B = 切分+逐框喂法的贡献，
/// B−C = 修正代码的贡献（负数 = 代码在帮倒忙）；附错字 TOP 与逐行明细。
class RecogEvalPanel extends StatelessWidget {
  final Map<String, dynamic>? result;
  final Map<String, dynamic>? evalSetInfo;
  final String? error;

  const RecogEvalPanel({
    super.key,
    this.result,
    this.evalSetInfo,
    this.error,
  });

  Map<String, dynamic> _map(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

  List<Map<String, dynamic>> _list(dynamic v) => v is List
      ? v.map((e) => Map<String, dynamic>.from(e as Map)).toList()
      : const [];

  Color _accuracyColor(double accuracy) {
    if (accuracy >= 0.9) return Colors.green.shade700;
    if (accuracy >= 0.7) return Colors.deepOrange.shade600;
    return Colors.red.shade600;
  }

  String _evalSetLine() {
    final es = _map(evalSetInfo?['eval_set']);
    if (es.isEmpty) {
      return '还没有冻结评测集：首次运行会从书库「人工完全确认」的行里均匀抽样'
          '并冻结，之后跨训练轮次可比（勾选"重建评测集"可重新抽样）。';
    }
    final books = _list(es['books']).map((b) => b.toString()).join('、');
    return '冻结评测集：${es['size']} 行 · 来自 ${books.isEmpty ? '—' : books}'
        '（书库确认行共 ${es['total_confirmed']}）· 冻结于 ${es['built_at']}';
  }

  @override
  Widget build(BuildContext context) {
    final r = result;
    if (r == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                error ?? '点「开始对比」运行三档消融评测：\n'
                    'A 裸模型·整行读法（不过任何切分/修正代码）\n'
                    'B 像素切分+逐框读法（无标点拆分/错位修复/融合）\n'
                    'C 全链路（现状）\n\n'
                    'A−B = 切分+逐框喂法的贡献；B−C = 修正代码的贡献。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: error != null
                      ? Theme.of(context).colorScheme.error
                      : Colors.grey,
                  fontSize: 12.5,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                _evalSetLine(),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey, fontSize: 11.5),
              ),
            ],
          ),
        ),
      );
    }
    final tiers = _map(r['tiers']);
    final deltas = _map(r['deltas']);
    final details = _list(r['details']);
    final evalSet = _map(r['eval_set']);
    final skipped = (r['skipped'] as num?)?.toInt() ?? 0;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '评测集：${evalSet['size']} 行 · 书库确认行共 ${evalSet['total_confirmed']}'
            ' · 冻结于 ${evalSet['built_at']}'
            ' · 总耗时 ${(r['elapsed_s'] as num?)?.toStringAsFixed(0) ?? '—'}s'
            '${skipped > 0 ? ' · 跳过 $skipped 行（缺图/空文本）' : ''}',
            style: const TextStyle(fontSize: 11.5, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final tier in const ['a', 'b', 'c'])
                _TierCard(
                  label: (tiers[tier]?['label'] ?? tier).toString(),
                  tier: _map(tiers[tier]),
                  accuracyColor: _accuracyColor,
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final entry in deltas.entries)
                _DeltaChip(key: ValueKey(entry.key), delta: _map(entry.value)),
            ],
          ),
          const SizedBox(height: 8),
          _ConfusionsBlock(
            confusions: _list(_map(_map(r['tiers'])['c'])['confusions']),
            title: '错字 TOP（C 档全链路，gt→pred）',
          ),
          const SizedBox(height: 8),
          ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 8),
            childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            title: Text(
              '逐行明细（${details.length} 行）',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            subtitle: const Text(
              'GT 与三档读文对照，CER 着色（绿好红差）',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
            children: [
              for (final d in details)
                _DetailCard(detail: d, map: _map, list: _list),
            ],
          ),
        ],
      ),
    );
  }
}

class _TierCard extends StatelessWidget {
  final String label;
  final Map<String, dynamic> tier;
  final Color Function(double) accuracyColor;

  const _TierCard({
    required this.label,
    required this.tier,
    required this.accuracyColor,
  });

  @override
  Widget build(BuildContext context) {
    final accuracy = (tier['accuracy'] as num?)?.toDouble();
    return Container(
      width: 240,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            accuracy == null ? '—' : '${(accuracy * 100).toStringAsFixed(2)}%',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: accuracy == null ? Colors.grey : accuracyColor(accuracy),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '字准确率 · CER ${tier['cer']}',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 4),
          Text(
            '替换 ${tier['sub']} · 漏 ${tier['del']} · 多 ${tier['ins']}'
            ' · 标点错 ${tier['punct_errors']}',
            style: const TextStyle(fontSize: 11.5),
          ),
          Text(
            '${tier['lines']} 行 / ${tier['chars']} 字 · 耗时 ${tier['elapsed_s']}s',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}

class _DeltaChip extends StatelessWidget {
  final Map<String, dynamic> delta;

  const _DeltaChip({super.key, required this.delta});

  @override
  Widget build(BuildContext context) {
    final gain = (delta['accuracy_gain'] as num?)?.toDouble() ?? 0.0;
    final color = gain > 0
        ? Colors.green.shade700
        : gain < 0
        ? Colors.red.shade600
        : Colors.grey.shade700;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        '${delta['name']}：准确率 ${gain >= 0 ? '+' : ''}${(gain * 100).toStringAsFixed(1)}pt'
        '（CER ${delta['cer_before']} → ${delta['cer_after']}）',
        style: TextStyle(fontSize: 12, color: color),
      ),
    );
  }
}

class _ConfusionsBlock extends StatelessWidget {
  final List<Map<String, dynamic>> confusions;
  final String title;

  const _ConfusionsBlock({required this.confusions, required this.title});

  @override
  Widget build(BuildContext context) {
    if (confusions.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final c in confusions)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Text(
                  '${c['gt']}→${c['pred']} ×${c['count']}',
                  style: TextStyle(fontSize: 11.5, color: Colors.red.shade700),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _DetailCard extends StatelessWidget {
  final Map<String, dynamic> detail;
  final Map<String, dynamic> Function(dynamic) map;
  final List<Map<String, dynamic>> Function(dynamic) list;

  const _DetailCard({required this.detail, required this.map, required this.list});

  Color _cerColor(double? cer) {
    if (cer == null) return Colors.grey;
    if (cer <= 0.001) return Colors.green.shade700;
    if (cer < 0.2) return Colors.deepOrange.shade600;
    return Colors.red.shade600;
  }

  @override
  Widget build(BuildContext context) {
    final preds = map(detail['preds']);
    final cers = map(detail['cer']);
    final gt = (detail['gt'] ?? '').toString();
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '#${(detail['index'] as num?)?.toInt() ?? 0} · GT（${detail['char_count']} 字）：$gt',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          for (final tier in const ['a', 'b', 'c'])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 26,
                    child: Text(
                      tier.toUpperCase(),
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Colors.grey,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      ((preds[tier] ?? '') as String).isEmpty
                          ? '（空）'
                          : preds[tier].toString(),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  Text(
                    cers[tier] == null ? '—' : 'CER ${(cers[tier] as num).toStringAsFixed(2)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: _cerColor((cers[tier] as num?)?.toDouble()),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
