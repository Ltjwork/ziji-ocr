import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/python_service.dart';
import 'straighten_page.dart';

/// 拼接面板确认结果：拼入哪一页（调用方据此落账删除）。
class StitchDialogResult {
  const StitchDialogResult({required this.partner});

  final StraightenPageTarget partner;
}

/// 多页拼接面板（校对摆正 · 会话模式入口）：把当前页与书内另一页智能
/// 拼成一页——不是整图首尾相接，而是后端裁掉接缝空白、按墨迹投影对齐
/// 错位/重复重叠（连续表格/图片跨缝连续），重叠带内线性羽化。
///
/// 全屏布局（用户反馈预览窗太小看不清接缝）：**左侧大预览**（占满主要
/// 画面，可缩放细看接缝），右侧固定宽度控制面板。任一参数变化 500ms
/// 防抖自动刷新预览；「确认拼接」写出全分辨率结果（覆写当前页矫正图）
/// 并返回拼入页，由宿主落账（当前页记合成页、拼入页删除）。
///
/// 拼接顺序（谁上谁下/谁左谁右）：默认按书序智能推断——拼入页在书序上
/// 靠前时拼入页作前段（读序自然）；手动切换后记住选择（换拼入页不再
/// 重置）。
class StitchDialog extends StatefulWidget {
  const StitchDialog({
    super.key,
    required this.currentImage,
    required this.currentOutPath,
    required this.currentIndex,
    required this.currentLabel,
    required this.partners,
    this.preferredPartnerIndex,
  });

  /// 当前页参与拼接的画面（编辑器当前文件，含本会话内的就地旋转）。
  final String currentImage;

  /// 拼接结果写出路径（= 当前页矫正图路径，覆写）。
  final String currentOutPath;

  /// 当前页页号（0 基；拼接顺序默认按书序推断用）。
  final int currentIndex;

  /// 当前页显示名（如「第 3 页」）。
  final String currentLabel;

  /// 拼入页候选（宿主按书序提供，已排除当前页）。
  final List<StraightenPageTarget> partners;

  /// 默认选中的拼入页页号（通常是当前页 +1）。
  final int? preferredPartnerIndex;

  @override
  State<StitchDialog> createState() => _StitchDialogState();
}

class _StitchDialogState extends State<StitchDialog> {
  late StraightenPageTarget _partner;
  String _direction = 'v'; // 'v' 上下拼 / 'h' 左右拼
  bool _partnerFirst = false; // 拼入页作前段（上/左）
  bool _orderTouched = false; // 用户手动切过顺序：换拼入页不再重置
  bool _autoTrim = true;
  bool _autoAlign = true;
  bool _manualOverlap = false;
  int _overlap = 0;
  bool _manualOffset = false;
  int _offset = 0;
  int _seamFade = 24;

  Uint8List? _previewBytes;
  bool _loading = false;
  bool _applying = false;
  Map<String, dynamic>? _trace;
  String? _error;
  Timer? _debounce;
  int _seq = 0; // 预览请求代数（丢弃过期响应）

  @override
  void initState() {
    super.initState();
    _partner = _preferredPartner() ?? widget.partners.first;
    _partnerFirst = _partner.pageIndex < widget.currentIndex;
    _schedulePreview();
  }

  StraightenPageTarget? _preferredPartner() {
    final want = widget.preferredPartnerIndex;
    if (want == null) return null;
    for (final t in widget.partners) {
      if (t.pageIndex == want) return t;
    }
    return null;
  }

  /// 拼入页参与拼接的画面：有矫正图用矫正图（摆正过的边缘干净），
  /// 否则原图（面板提示用户可先处理该页）。
  String get _partnerImage {
    final t = _partner;
    return File(t.outPath).existsSync() ? t.outPath : t.imagePath;
  }

  bool get _partnerUsesWarped => File(_partner.outPath).existsSync();

  /// 前段/后段输入（后端 image_a 恒为前段=上/左）：按拼接顺序取当前页
  /// 与拼入页。
  ({String a, String b}) get _orderedInputs => _partnerFirst
      ? (a: _partnerImage, b: widget.currentImage)
      : (a: widget.currentImage, b: _partnerImage);

  void _schedulePreview() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      if (mounted) unawaited(_refreshPreview());
    });
  }

  Future<void> _refreshPreview() async {
    if (_applying) return;
    final gen = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final input = _orderedInputs;
      final r = await PythonService.stitchPages(
        imageA: input.a,
        imageB: input.b,
        direction: _direction,
        autoTrim: _autoTrim,
        autoAlign: _autoAlign,
        overlap: _manualOverlap ? _overlap : null,
        offset: _manualOffset ? _offset : null,
        seamFade: _seamFade,
        preview: true,
        previewMaxPx: 2600, // 大预览：留足分辨率，缩放细看接缝不糊
      );
      if (!mounted || gen != _seq) return;
      final b64 = r['image_b64'] as String?;
      if (b64 == null) throw Exception('后端未返回预览图');
      setState(() {
        _previewBytes = base64Decode(b64);
        _trace = r['trace'] as Map<String, dynamic>?;
      });
    } catch (e) {
      if (mounted && gen == _seq) {
        setState(() => _error = '预览失败：$e');
      }
    } finally {
      if (mounted && gen == _seq) setState(() => _loading = false);
    }
  }

  Future<void> _confirm() async {
    if (_applying) return;
    setState(() {
      _applying = true;
      _error = null;
    });
    try {
      final input = _orderedInputs;
      await PythonService.stitchPages(
        imageA: input.a,
        imageB: input.b,
        direction: _direction,
        autoTrim: _autoTrim,
        autoAlign: _autoAlign,
        overlap: _manualOverlap ? _overlap : null,
        offset: _manualOffset ? _offset : null,
        seamFade: _seamFade,
        outPath: widget.currentOutPath,
      );
      FileImage(File(widget.currentOutPath)).evict();
      if (!mounted) return;
      Navigator.of(context).pop(StitchDialogResult(partner: _partner));
    } catch (e) {
      if (mounted) {
        setState(() {
          _applying = false;
          _error = '拼接失败：$e';
        });
      }
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // showDialog 的 builder 直接返回 Scaffold 即占满整窗（全屏面板），
    // 结果仍走 Navigator.pop(result)。
    return Scaffold(
      backgroundColor: const Color(0xFF121214),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _buildPreviewArea()),
          Container(
            width: 400,
            decoration: const BoxDecoration(
              color: Color(0xFF1C1C1E),
              border: Border(left: BorderSide(color: Color(0xFF3A3A3E))),
            ),
            child: _buildPanel(),
          ),
        ],
      ),
    );
  }

  /// 左侧大预览：占满剩余画面，可缩放细看接缝（用户反馈嵌在对话框里
  /// 的窄预览看不清）。
  Widget _buildPreviewArea() {
    final bytes = _previewBytes;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (bytes != null)
          InteractiveViewer(
            maxScale: 8,
            minScale: 0.05,
            child: Center(
              child: Image.memory(
                bytes,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Center(
                  child: Text('预览图解码失败', style: TextStyle(color: Colors.grey)),
                ),
              ),
            ),
          )
        else
          const Center(
            child: Text(
              '正在计算拼接预览 …\n（调整右侧参数后自动刷新）',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 14),
            ),
          ),
        if (_loading)
          const Positioned(
            left: 14,
            top: 12,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 8),
                Text('计算中 …', style: TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
          child: Row(
            children: [
              Icon(Icons.call_merge, size: 20, color: Colors.amber.shade200),
              const SizedBox(width: 8),
              const Text(
                '多页拼接',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: '取消拼接',
                onPressed: _applying ? null : () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Text(
            '${widget.currentLabel}（${_partnerFirst ? '后段' : '前段'}） × '
            '拼入 第 ${_partner.pageIndex + 1} 页'
            '（${_partnerFirst ? '前段' : '后段'}，'
            '${_partnerUsesWarped ? '矫正图' : '原图·未摆正'}）',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: _buildControls(),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: _buildTraceBlock(),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
            child: Text(
              _error!,
              style: TextStyle(fontSize: 12, color: Colors.red.shade300),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
          child: Text(
            '确认后：拼接结果覆写${widget.currentLabel}的矫正图，'
            '拼入页（第 ${_partner.pageIndex + 1} 页）将从本书永久删除。',
            style: TextStyle(fontSize: 12, color: Colors.orange.shade300),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
          child: Row(
            children: [
              OutlinedButton(
                onPressed: _applying ? null : () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: _applying ? null : _confirm,
                icon: _applying
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check, size: 18),
                label: const Text('确认拼接'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildControls() {
    final vertical = _direction == 'v';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('拼入页', style: TextStyle(fontSize: 13, color: Colors.white70)),
        const SizedBox(height: 4),
        DropdownButton<String>(
          isExpanded: true,
          value: _partner.imagePath,
          items: [
            for (final t in widget.partners)
              DropdownMenuItem(
                value: t.imagePath,
                child: Text(
                  '第 ${t.pageIndex + 1} 页'
                  '${t.confirmed ? '（已确认）' : ''}'
                  '${t.pageIndex < widget.currentIndex ? ' · 上一页' : ''}',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
          ],
          onChanged: (v) {
            final t = widget.partners
                .where((x) => x.imagePath == v)
                .firstOrNull;
            if (t == null) return;
            setState(() {
              _partner = t;
              // 顺序未手动选过时随书序重推：拼上一页 → 拼入页作前段。
              if (!_orderTouched) {
                _partnerFirst = t.pageIndex < widget.currentIndex;
              }
            });
            _schedulePreview();
          },
        ),
        const SizedBox(height: 10),
        const Text('方向', style: TextStyle(fontSize: 13, color: Colors.white70)),
        const SizedBox(height: 4),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'v', label: Text('上下拼', style: TextStyle(fontSize: 12))),
            ButtonSegment(value: 'h', label: Text('左右拼', style: TextStyle(fontSize: 12))),
          ],
          selected: {_direction},
          onSelectionChanged: (s) {
            setState(() => _direction = s.first);
            _schedulePreview();
          },
          showSelectedIcon: false,
        ),
        const SizedBox(height: 10),
        Text(
          vertical ? '上下顺序' : '左右顺序',
          style: const TextStyle(fontSize: 13, color: Colors.white70),
        ),
        const SizedBox(height: 4),
        SegmentedButton<bool>(
          segments: [
            ButtonSegment(
              value: false,
              label: Text(
                vertical ? '本页在上' : '本页在左',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            ButtonSegment(
              value: true,
              label: Text(
                vertical ? '拼入页在上' : '拼入页在左',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
          selected: {_partnerFirst},
          onSelectionChanged: (s) {
            setState(() {
              _partnerFirst = s.first;
              _orderTouched = true;
            });
            _schedulePreview();
          },
          showSelectedIcon: false,
        ),
        const SizedBox(height: 10),
        _panelSwitch('自动裁空白（接缝侧空白按墨迹裁掉）', _autoTrim, (v) {
          setState(() => _autoTrim = v);
          _schedulePreview();
        }),
        _panelSwitch('自动对齐（错位/重复扫描重叠）', _autoAlign, (v) {
          setState(() => _autoAlign = v);
          _schedulePreview();
        }),
        const SizedBox(height: 6),
        _sliderRow(
          label: '手动重叠',
          enabled: _manualOverlap,
          onEnabled: (v) {
            setState(() => _manualOverlap = v);
            _schedulePreview();
          },
          value: _overlap.toDouble(),
          min: 0,
          max: 300,
          divisions: 60,
          valueLabel: '$_overlap px',
          onChanged: (v) {
            setState(() => _overlap = v.round());
            _schedulePreview();
          },
        ),
        _sliderRow(
          label: '手动错位',
          enabled: _manualOffset,
          onEnabled: (v) {
            setState(() => _manualOffset = v);
            _schedulePreview();
          },
          value: _offset.toDouble(),
          min: -300,
          max: 300,
          divisions: 120,
          valueLabel: '$_offset px',
          onChanged: (v) {
            setState(() => _offset = v.round());
            _schedulePreview();
          },
        ),
        _sliderRow(
          label: '接缝羽化',
          value: _seamFade.toDouble(),
          min: 0,
          max: 60,
          divisions: 30,
          valueLabel: '$_seamFade px',
          onChanged: (v) {
            setState(() => _seamFade = v.round());
            _schedulePreview();
          },
        ),
      ],
    );
  }

  Widget _panelSwitch(String label, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(label, style: const TextStyle(fontSize: 13)),
      value: value,
      onChanged: onChanged,
    );
  }

  /// 一行微调：可开关的滑条（开关关闭 = 自动判定）。[enabled]/[onEnabled]
  /// 缺省的行是常开滑条。
  Widget _sliderRow({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String valueLabel,
    required ValueChanged<double> onChanged,
    bool? enabled,
    ValueChanged<bool>? onEnabled,
  }) {
    final toggleable = enabled != null && onEnabled != null;
    return Row(
      children: [
        SizedBox(
          width: 176,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: const TextStyle(fontSize: 12)),
              if (toggleable) ...[
                Switch(value: enabled, onChanged: onEnabled),
              ] else
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    valueLabel,
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: valueLabel,
            onChanged: (!toggleable || !enabled) ? null : onChanged,
          ),
        ),
        if (toggleable)
          SizedBox(
            width: 48,
            child: Text(
              toggleable && !enabled ? '自动' : valueLabel,
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
      ],
    );
  }

  /// 后端 trace → 自动判定摘要块（多行，含置信度）。
  Widget _buildTraceBlock() {
    final t = _trace;
    if (t == null) {
      return const SizedBox.shrink();
    }
    final offsetAuto = t['offset_auto'] == true;
    final overlapAuto = t['overlap_auto'] == true;
    final conf = (t['align_confidence'] as num?) ?? -1;
    const style = TextStyle(fontSize: 12, color: Colors.white54, height: 1.5);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('拼接判定', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
        const SizedBox(height: 2),
        Text(
          '裁空白 ${t['trim_a']}/${t['trim_b']} px · '
          '${t['direction'] == 'h' ? '左右' : '上下'}输出 ${t['out_w']}×${t['out_h']}\n'
          '错位 ${t['offset']} px（${offsetAuto ? '自动·置信 ${conf.toStringAsFixed(2)}' : '手动'}） · '
          '重叠 ${t['overlap']} px（${overlapAuto ? '自动' : '手动'}）',
          style: style,
        ),
      ],
    );
  }
}
