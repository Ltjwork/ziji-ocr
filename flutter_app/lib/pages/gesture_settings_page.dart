import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../services/mouse_gesture.dart';

/// 映射表所属页（quick=主区快设 / editor=书籍校对 / straighten=校对摆正）。
enum _GestureScope { quick, editor, straighten }

/// [scope] 的手势 → 动作映射表。
Map<String, String> _mappingsOf(GestureSettings s, _GestureScope scope) =>
    switch (scope) {
      _GestureScope.quick => s.quick,
      _GestureScope.editor => s.editor,
      _GestureScope.straighten => s.straighten,
    };

/// [scope] 的动作目录（设置页按动作视角展示）。
Map<String, String> _catalogOf(_GestureScope scope) => switch (scope) {
  _GestureScope.quick => GestureCatalog.quickActions,
  _GestureScope.editor => GestureCatalog.editorActions,
  _GestureScope.straighten => GestureCatalog.straightenActions,
};

/// [scope] 换映射表后的新配置。
GestureSettings _withMappings(
  GestureSettings s,
  _GestureScope scope,
  Map<String, String> m,
) => switch (scope) {
  _GestureScope.quick => s.copyWith(quick: m),
  _GestureScope.editor => s.copyWith(editor: m),
  _GestureScope.straighten => s.copyWith(straighten: m),
};

/// 鼠标手势设置页（设置整合页的"鼠标手势"标签，embedded 模式；照
/// OllamaSettingsPage 模板：无保存按钮，改动即时落盘）。**动作视角**：
/// 每页一节、每个动作一行（当前绑定的手势 chips + 录制/清除），点
/// 「录制」弹出面板——面板上直接按住中键画出手势即录即存（见
/// [_GestureRecordDialog]），不再从下拉里挑方向。
class GestureSettingsPage extends StatefulWidget {
  const GestureSettingsPage({super.key, this.embedded = false});

  /// true = 由设置整合页提供标题与脚手架，本页只出内容。
  final bool embedded;

  @override
  State<GestureSettingsPage> createState() => _GestureSettingsPageState();
}

class _GestureSettingsPageState extends State<GestureSettingsPage> {
  GestureSettings _settings = const GestureSettings();

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final s = await GestureSettings.load();
    if (!mounted) return;
    setState(() => _settings = s);
  }

  void _update(GestureSettings Function(GestureSettings) fn) {
    setState(() => _settings = fn(_settings));
    unawaited(_settings.save());
  }

  /// 录制面板"松手即保存"的落库口（页面级持最新映射——卡片是无状态
  /// 快照，对话框期间连续覆盖录制若基于旧快照会丢前一次结果）：
  /// [seq] 绑定到 [actionId]；该手势原绑定其它动作时自动换绑并提示
  ///（一个手势只触发一个动作；一个动作可以绑多个手势）。
  void _recordGesture({
    required _GestureScope scope,
    required String seq,
    required String actionId,
    required String actionLabel,
  }) {
    final current = _mappingsOf(_settings, scope);
    final takenFrom = current[seq];
    final next = Map.of(current)..[seq] = actionId;
    _update((s) => _withMappings(s, scope, next));
    if (mounted && takenFrom != null && takenFrom != actionId) {
      final catalog = _catalogOf(scope);
      final oldLabel = catalog[takenFrom] ?? takenFrom;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '手势 ${GestureCatalog.gestureLabel(seq)} 已从「$oldLabel」改绑到「$actionLabel」',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _switchCard(),
        const SizedBox(height: 8),
        _helpCard(),
        const SizedBox(height: 8),
        _MappingSectionCard(
          title: '主区快设（逐页框正文/页眉页脚）',
          mappings: _settings.quick,
          actionCatalog: GestureCatalog.quickActions,
          enabled: _settings.enabled,
          onChanged: (m) => _update((s) => _withMappings(s, _GestureScope.quick, m)),
          onRecorded: (seq, actionId, label) => _recordGesture(
            scope: _GestureScope.quick,
            seq: seq,
            actionId: actionId,
            actionLabel: label,
          ),
        ),
        const SizedBox(height: 8),
        _MappingSectionCard(
          title: '书籍校对（编辑器）',
          mappings: _settings.editor,
          actionCatalog: GestureCatalog.editorActions,
          enabled: _settings.enabled,
          onChanged: (m) => _update((s) => _withMappings(s, _GestureScope.editor, m)),
          onRecorded: (seq, actionId, label) => _recordGesture(
            scope: _GestureScope.editor,
            seq: seq,
            actionId: actionId,
            actionLabel: label,
          ),
        ),
        const SizedBox(height: 8),
        _MappingSectionCard(
          title: '校对摆正（裁切框调整）',
          mappings: _settings.straighten,
          actionCatalog: GestureCatalog.straightenActions,
          enabled: _settings.enabled,
          onChanged: (m) => _update((s) => _withMappings(s, _GestureScope.straighten, m)),
          onRecorded: (seq, actionId, label) => _recordGesture(
            scope: _GestureScope.straighten,
            seq: seq,
            actionId: actionId,
            actionLabel: label,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '手势感应范围：快设为编辑窗口；校对、摆正为整个窗口（含面板/'
          '缩略图）。左键画框/拖裁切点、右键平移、滚轮缩放不受影响。',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
      ],
    );
    if (widget.embedded) return content;
    return Scaffold(
      appBar: AppBar(title: const Text('鼠标手势')),
      body: content,
    );
  }

  Widget _switchCard() {
    return Card(
      child: SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        title: const Text('启用鼠标中键手势', style: TextStyle(fontSize: 14)),
        subtitle: const Text(
          '关闭后中键拖动无任何效果（不影响左键/右键/滚轮）',
          style: TextStyle(fontSize: 12),
        ),
        value: _settings.enabled,
        onChanged: (v) => _update((s) => s.copyWith(enabled: v)),
      ),
    );
  }

  Widget _helpCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('用法', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              '按住鼠标中键在窗口里拖动：拖出方向序列（拖动中有橙色轨迹），'
              '松手时匹配映射触发对应动作。方向为四向（←/→/↑/↓），连续同向'
              '只记一次，最多两段；例如「←↓（L 形）」= 先向左拖一段、再向下'
              '拖一段。也可以画一个整圈（↻ 顺时针 / ↺ 逆时针）或对勾'
              '（✓，正反画法都认）。位移太小视为'
              '中键点击，不触发。给动作配手势：点下表「录制」，在弹出的面板'
              '上直接画出即可。',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单页（快设/校对）的映射编辑卡——动作视角：每个动作一行，显示已绑定
/// 的手势 chips；「录制」弹出画手势面板（松手即保存），「清除」移除该
/// 动作的全部绑定。
class _MappingSectionCard extends StatelessWidget {
  const _MappingSectionCard({
    required this.title,
    required this.mappings,
    required this.actionCatalog,
    required this.enabled,
    required this.onChanged,
    required this.onRecorded,
  });

  final String title;

  /// 手势序列 → 动作 id（存储方向；本卡按动作反查展示）。
  final Map<String, String> mappings;
  final Map<String, String> actionCatalog;
  final bool enabled;
  final ValueChanged<Map<String, String>> onChanged;

  /// 录制面板松手即保存（页面级实现，读最新映射做冲突换绑）。
  final void Function(String seq, String actionId, String actionLabel)
  onRecorded;

  List<String> _gesturesOf(String actionId) => [
        for (final e in mappings.entries)
          if (e.value == actionId) e.key,
      ]..sort((a, b) => a.length.compareTo(b.length));

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            for (final action in actionCatalog.entries)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(action.value, style: const TextStyle(fontSize: 13)),
                          ...[
                            for (final g in _gesturesOf(action.key))
                              _gestureChip(g),
                            if (_gesturesOf(action.key).isEmpty)
                              Text(
                                '未设置',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade500,
                                ),
                              ),
                          ],
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.gesture, size: 18),
                      tooltip: '录制：在面板上用中键画出手势',
                      onPressed: enabled
                          ? () => _record(context, action.key, action.value)
                          : null,
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      tooltip: '清除该动作的全部手势',
                      onPressed: enabled && _gesturesOf(action.key).isNotEmpty
                          ? () {
                              final next = Map.of(mappings)
                                ..removeWhere(
                                  (_, v) => v == action.key,
                                );
                              onChanged(next);
                            }
                          : null,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _gestureChip(String seq) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        border: Border.all(color: Colors.orange.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        GestureCatalog.gestureLabel(seq),
        style: const TextStyle(fontSize: 13),
      ),
    );
  }

  Future<void> _record(
    BuildContext context,
    String actionId,
    String actionLabel,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _GestureRecordDialog(
        actionLabel: actionLabel,
        onRecorded: (seq) => onRecorded(seq, actionId, actionLabel),
      ),
    );
  }
}

/// 手势录制面板：显示当前要设置的动作名，用户按住鼠标中键直接画出手势
/// ——松手即识别即保存（[onRecorded] 即时落库），面板停留可再画一次覆盖
/// 或点「完成」关闭。无效输入（纯点击/超两段）提示重画。最多两段（与
/// 手势目录一致，如 ←↓）。
class _GestureRecordDialog extends StatefulWidget {
  const _GestureRecordDialog({
    required this.actionLabel,
    required this.onRecorded,
  });

  final String actionLabel;
  final void Function(String seq) onRecorded;

  @override
  State<_GestureRecordDialog> createState() => _GestureRecordDialogState();
}

class _GestureRecordDialogState extends State<_GestureRecordDialog> {
  final MouseGestureTracker _tracker = MouseGestureTracker();
  bool _drawing = false;
  String? _doneSeq;

  /// 无效输入的提示（纯点击/超两段）：面板内嵌显示，不依赖外层
  /// Scaffold 的 SnackBar（embedded 设置页可能没有 Scaffold 祖先）。
  String? _error;

  void _onDown(PointerEvent e) {
    if (e.buttons != kMiddleMouseButton) return;
    setState(() {
      _drawing = true;
      _doneSeq = null;
      _error = null;
    });
    _tracker.start(e.localPosition);
  }

  void _onMove(PointerEvent e) {
    if (!_drawing) return;
    _tracker.extend(e.localPosition);
    setState(() {});
  }

  void _onUp() {
    if (!_drawing) return;
    final seq = _tracker.finish();
    setState(() => _drawing = false);
    if (seq == null) {
      setState(() => _error = '未识别出方向：请按住中键拖出至少一段（≥12 像素）');
      return;
    }
    if (!GestureCatalog.gestures.containsKey(seq)) {
      setState(() => _error = '手势为单方向、两段折线（如 ←↓）、整圈圆或对勾（✓），请重画');
      return;
    }
    setState(() => _doneSeq = seq);
    widget.onRecorded(seq); // 松手即保存（面板停留，可覆盖重画）
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('录制手势', style: TextStyle(fontSize: 13, color: Colors.grey)),
            const SizedBox(height: 4),
            Text(
              widget.actionLabel,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              _doneSeq != null
                  ? '已录制 ${GestureCatalog.gestureLabel(_doneSeq!)}，'
                        '松手即已保存；可再画一次覆盖，或点「完成」。'
                  : '在下方区域按住鼠标中键拖动，画出手势（松手即保存）。'
                        '方向为 ←/→/↑/↓、最多两段（如 L 形 = 先向左再向下），'
                        '也可以画一个整圈（↻ 顺时针 / ↺ 逆时针圆）或对勾'
                        '（✓，正反画法都认）。',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700, height: 1.5),
            ),
            if (_error != null) ...[
              const SizedBox(height: 6),
              Text(
                _error!,
                style: TextStyle(fontSize: 12, color: Colors.red.shade700),
              ),
            ],
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                height: 240,
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _onDown,
                  onPointerMove: _onMove,
                  onPointerUp: (_) => _onUp(),
                  onPointerCancel: (_) {
                    if (_drawing) {
                      _tracker.cancel();
                      setState(() => _drawing = false);
                    }
                  },
                  child: Stack(
                    children: [
                      if (_drawing)
                        Positioned.fill(
                          child: CustomPaint(
                            painter: GestureTrailPainter(points: _tracker.trail),
                          ),
                        ),
                      Center(
                        child: _doneSeq != null
                            ? _GestureGlyph(seq: _doneSeq!)
                            : Text(
                                '按住中键在这里画…',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.grey.shade500,
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(_doneSeq != null ? '完成' : '关闭'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 录制结果的"标准像"：按方向序列把箭头字符串画成大字（与实际手势形状
/// 对应，方便核对画的是不是想要的）。
class _GestureGlyph extends StatelessWidget {
  const _GestureGlyph({required this.seq});

  final String seq;

  @override
  Widget build(BuildContext context) {
    // 几何特检手势（圆/对勾）有专属字形，其余（方向组合）逐字符映射箭头。
    final special = const {'CW': '↻', 'CCW': '↺', 'CK': '✓'}[seq];
    final glyph = special ??
        [
          for (final c in seq.split(''))
            switch (c) {
              'L' => '←',
              'R' => '→',
              'U' => '↑',
              'D' => '↓',
              _ => c,
            },
        ].join();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          glyph,
          style: TextStyle(
            fontSize: 40,
            fontWeight: FontWeight.w600,
            color: Colors.orange.shade800,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          GestureCatalog.gestureLabel(seq),
          style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
        ),
      ],
    );
  }
}
