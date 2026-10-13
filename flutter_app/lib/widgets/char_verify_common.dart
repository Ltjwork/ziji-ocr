import 'dart:convert' show base64Decode;

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/python_service.dart';

/// 墨迹校验标记色（编辑器与调试页共用）：mismatch=识别文字与墨迹骨架
/// 拓扑/形状重叠不符（红），suspect=存疑（琥珀）。画布上以虚线框与
/// tall-box 的纯红实线区分；琥珀与两路识别 agree=conflict 同色系
/// （都是"人工看一眼"语义）。
const Color kVerifyMismatchRed = Color(0xFFFF1744);
const Color kVerifySuspectAmber = Color(0xFFFFB300);

/// 字块是否被墨迹校验标记（mismatch/suspect），画布/行卡片/调试页
/// 同口径。
Color? verifyFlagColor(CharBlock b) {
  if (b.verifyLevel == 'mismatch') return kVerifyMismatchRed;
  if (b.verifyLevel == 'suspect') return kVerifySuspectAmber;
  return null;
}

/// 「墨迹对照」对话框：识别文字的楷体字形骨架与原字墨迹骨架的叠加
/// 视图（蓝=墨迹、红=字形、绿=两者重叠）+ 三层分数 + 拓扑差异明细，
/// 附「重新校验」（改字后手动刷新）。onApplyResult 把结果写回调用方
/// （编辑器落字块；调试页可传空回调纯查看）。
class CharVerifyDialog extends StatefulWidget {
  final String imagePath;
  final CharBlock block;
  final void Function(String level, double? score) onApplyResult;

  const CharVerifyDialog({
    super.key,
    required this.imagePath,
    required this.block,
    required this.onApplyResult,
  });

  @override
  State<CharVerifyDialog> createState() => _CharVerifyDialogState();
}

class _CharVerifyDialogState extends State<CharVerifyDialog> {
  CharVerifyOutcome? _outcome;
  String? _error;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _rerun();
  }

  Future<void> _rerun() async {
    if (_running) return;
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final outcome = await PythonService.verifyChar(
        imagePath: widget.imagePath,
        block: widget.block,
        debug: true,
      );
      if (!mounted) return;
      setState(() => _outcome = outcome);
      widget.onApplyResult(outcome.level, outcome.score);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  static const _topoLabels = {
    'holes': '洞数',
    'endpoints': '端点',
    'junctions': '分叉',
    'crossings': '十字',
    'components': '连通块',
  };

  @override
  Widget build(BuildContext context) {
    final outcome = _outcome;
    final raw = outcome?.raw;
    final overlayB64 = raw?['debug_image_b64'] as String?;
    final topology = raw?['topology'] as Map?;
    final inkTopo = topology?['ink'] as Map?;
    final glyphTopo = topology?['glyph'] as Map?;
    final parts = raw?['parts'] as Map?;
    final peer = raw?['peer'] as Map?;
    final template = raw?['template'] as Map?;
    final flagged = outcome?.isFlagged ?? false;
    return AlertDialog(
      title: Row(
        children: [
          Text(
            '墨迹对照「${widget.block.text}」',
            style: const TextStyle(fontSize: 18),
          ),
          const Spacer(),
          if (flagged)
            Icon(
              outcome?.level == 'mismatch'
                  ? Icons.error_outline
                  : Icons.help_outline,
              color: outcome?.level == 'mismatch'
                  ? kVerifyMismatchRed
                  : kVerifySuspectAmber,
            ),
        ],
      ),
      content: SizedBox(
        width: 1064,
        child: _running
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: CircularProgressIndicator(),
                ),
              )
            : _error != null
            ? Text('校验失败：$_error', style: const TextStyle(fontSize: 13))
            : outcome == null
            ? Text('无结果', style: const TextStyle(fontSize: 13))
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (overlayB64 != null && overlayB64.isNotEmpty)
                      Center(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.memory(
                            base64Decode(overlayB64),
                            width: 1024,
                            height: 256,
                            fit: BoxFit.contain,
                          ),
                        ),
                      )
                    else
                      const Text(
                        '（该字未生成对照图：标点/缺字/空墨迹等跳过校验）',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    if (overlayB64 != null && overlayB64.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      const Center(
                        child: Text(
                          '① 原图裁字（识别时看到的字）　'
                          '② 墨迹侧（灰=二值墨迹，蓝=骨架）　'
                          '③ 印刷字侧（淡红=楷体字形，红=骨架）　'
                          '④ 整体重叠（绿=骨架重叠）',
                          style: TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                      ),
                      const Center(
                        child: Text(
                          '小圈=端点  大圈=分叉（蓝圈属墨迹、红圈属印刷字）',
                          style: TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    _summaryRow(outcome),
                    if (parts != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        '拓扑 ${(parts['topology'] as num?)?.toStringAsFixed(2) ?? '-'}'
                        '  位置 ${parts['match'] == null ? '—' : (parts['match'] as num).toStringAsFixed(2)}'
                        '  形状 ${(parts['shape'] as num?)?.toStringAsFixed(2) ?? '-'}'
                        '${parts['pair'] == null ? '' : '  比对 ${(parts['pair'] as num).toStringAsFixed(2)}'}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                    if (template != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        _templateLine(template),
                        style: TextStyle(
                          fontSize: 12,
                          color: _templateAdjusted(template) == null
                              ? Colors.grey
                              : kVerifySuspectAmber,
                        ),
                      ),
                    ],
                    if (peer != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        _peerLine(peer),
                        style: TextStyle(
                          fontSize: 12,
                          color: _peerAdjusted(peer) == null
                              ? Colors.grey
                              : kVerifySuspectAmber,
                        ),
                      ),
                    ],
                    if (inkTopo != null && glyphTopo != null) ...[
                      const SizedBox(height: 10),
                      const Text(
                        '拓扑差异（墨迹 vs 字形）',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      ..._topoLabels.entries.map(
                        (e) => _topoRow(
                          e.value,
                          inkTopo[e.key],
                          glyphTopo[e.key],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: _running ? null : _rerun,
          child: const Text('重新校验'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  static String? _peerAdjusted(Map peer) => peer['adjusted'] as String?;

  /// 跨页模板互证的展示行：本书已确认同字数 + 最像程度 + 调整说明。
  static String? _templateAdjusted(Map template) =>
      template['adjusted'] as String?;

  static String _templateLine(Map template) {
    final count = template['count'];
    final best = (template['best'] as num?)?.toStringAsFixed(2) ?? '-';
    const adjustedText = {
      'boosted_by_template': '与本书已确认的同字不像，判定不符',
      'downgraded_style': '与本书已确认的同字雷同，按风格差异降级',
    };
    final adjusted = _templateAdjusted(template);
    final suffix =
        adjusted == null ? '' : '（${adjustedText[adjusted] ?? adjusted}）';
    return '本书模板：已确认同字 $count 个，最像 $best$suffix';
  }

  /// 同字同伴互证的展示行：本页同字实例数 + 最像程度 + 调整说明。
  static String _peerLine(Map peer) {
    final group = peer['group'];
    final best = (peer['best'] as num?)?.toStringAsFixed(2) ?? '-';
    const adjustedText = {
      'boosted_minority': '与同字同伴不一致，已升级提示',
      'boosted_by_confirmed': '与已确认的同字不一致，判定不符',
      'downgraded_style': '与同字同伴一致，按风格差异降级',
    };
    final adjusted = _peerAdjusted(peer);
    final suffix = adjusted == null ? '' : '（${adjustedText[adjusted] ?? adjusted}）';
    return '同字同伴：本页同字 $group 个，与最像的同伴相似度 $best$suffix';
  }

  Widget _summaryRow(CharVerifyOutcome outcome) {
    if (outcome.level == 'skipped') {
      final reason = outcome.reason ?? '';
      return Text(
        '未校验（$reason）',
        style: const TextStyle(fontSize: 13, color: Colors.grey),
      );
    }
    final color = outcome.level == 'mismatch'
        ? kVerifyMismatchRed
        : outcome.level == 'suspect'
        ? kVerifySuspectAmber
        : Colors.green.shade700;
    final label = outcome.level == 'mismatch'
        ? '识别与墨迹结构不符'
        : outcome.level == 'suspect'
        ? '存疑，建议人工核对'
        : '匹配';
    return Text(
      '$label　${((outcome.score ?? 0) * 100).toStringAsFixed(0)} 分',
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: color,
      ),
    );
  }

  Widget _topoRow(String label, Object? ink, Object? glyph) {
    final diff = (int.tryParse('${ink ?? 0}') ?? 0) -
        (int.tryParse('${glyph ?? 0}') ?? 0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(label, style: const TextStyle(fontSize: 12)),
          ),
          Text(
            '$ink  vs  $glyph',
            style: TextStyle(
              fontSize: 12,
              color: diff == 0 ? Colors.grey : kVerifyMismatchRed,
              fontWeight: diff == 0 ? FontWeight.w400 : FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
