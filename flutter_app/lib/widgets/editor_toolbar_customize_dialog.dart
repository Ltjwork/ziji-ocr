import 'package:flutter/material.dart';

import '../services/editor_toolbar_settings.dart';
import 'editor_command_bar.dart';

/// 「自定义工具栏」对话框：每条 dock 的分组可以勾选显隐、上下移、
/// 改停靠位置；组内动作可勾选显隐、上下移；组名小字开关；恢复默认。
/// 修改即时回调（页面落盘并刷新，对话框后的工具栏实时预览）。
/// 除对话框外，工具栏本身也支持直接拖拽摆位（拖到哪算哪）。
Future<void> showEditorToolbarCustomizeDialog(
  BuildContext context, {
  required List<EditorActionGroup> groups,
  required EditorToolbarSettings settings,
  required ValueChanged<EditorToolbarSettings> onChanged,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _ToolbarCustomizeDialog(
      groups: groups,
      settings: settings,
      onChanged: onChanged,
    ),
  );
}

class _ToolbarCustomizeDialog extends StatefulWidget {
  const _ToolbarCustomizeDialog({
    required this.groups,
    required this.settings,
    required this.onChanged,
  });

  final List<EditorActionGroup> groups;
  final EditorToolbarSettings settings;
  final ValueChanged<EditorToolbarSettings> onChanged;

  @override
  State<_ToolbarCustomizeDialog> createState() =>
      _ToolbarCustomizeDialogState();
}

class _ToolbarCustomizeDialogState extends State<_ToolbarCustomizeDialog> {
  late EditorToolbarSettings _s;

  @override
  void initState() {
    super.initState();
    _s = widget.settings;
  }

  void _apply(EditorToolbarSettings next) {
    setState(() => _s = next);
    widget.onChanged(next);
  }

  List<String> get _defaultGroupIds => [
    for (final g in widget.groups) g.id,
    if (settingsUseCustomGroup(_s)) kCustomGroupId,
  ];

  void _moveGroup(String gid, int delta) {
    final dock = _s.dockOfGroup(gid);
    final list = _s.groupsInDock(dock, _defaultGroupIds);
    final i = list.indexOf(gid);
    final j = i + delta;
    if (i < 0 || j < 0 || j >= list.length) return;
    final before = j + 1 < list.length ? list[j + 1] : null;
    _apply(_s.withGroupMoved(gid, dock, before, currentDocksFull: _docksFull()));
  }

  /// 各 dock 当前完整顺序（含默认补齐），供 withGroupMoved 精确改位。
  Map<String, List<String>> _docksFull() => {
    for (final d in EditorToolbarDocks.all)
      d: _s.groupsInDock(d, _defaultGroupIds),
  };

  void _setGroupDock(String gid, String dock) {
    if (_s.dockOfGroup(gid) == dock) return;
    _apply(
      _s.withGroupMoved(gid, dock, null, currentDocksFull: _docksFull()),
    );
  }

  void _moveAction(String gid, String aid, int delta) {
    EditorActionGroup? group;
    for (final g in widget.groups) {
      if (g.id == gid) {
        group = g;
        break;
      }
    }
    if (group == null) return;
    final list = _s.orderedActionIds(gid, [for (final a in group.actions) a.id]);
    final i = list.indexOf(aid);
    final j = i + delta;
    if (i < 0 || j < 0 || j >= list.length) return;
    final before = j + 1 < list.length ? list[j + 1] : null;
    _apply(
      _s.withActionMoved(
        aid,
        gid,
        gid,
        before,
        fromOrder: list,
        toOrder: list,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.tune, size: 20),
          SizedBox(width: 8),
          Text('自定义工具栏', style: TextStyle(fontSize: 17)),
        ],
      ),
      content: SizedBox(
        width: 580,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('显示分组标签', style: TextStyle(fontSize: 13)),
                Switch(
                  value: _s.showGroupLabels,
                  onChanged: (v) => _apply(_s.withShowGroupLabels(v)),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => _apply(const EditorToolbarSettings()),
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label: const Text('恢复默认布局'),
                ),
              ],
            ),
            Text(
              '也可以直接在界面上拖：按钮拖到别的组/别的工具栏，组名（或竖排'
              '工具栏的握把）可整组拖动；这里改的是同一份布局，即时生效并自动保存。',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: ListView(
                children: [
                  for (final gid in _s.orderedGroupIds(_defaultGroupIds))
                    _groupCard(context, gid),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('完成'),
        ),
      ],
    );
  }

  Widget _groupCard(BuildContext context, String gid) {
    final scheme = Theme.of(context).colorScheme;
    final dock = _s.dockOfGroup(gid);
    EditorActionGroup? found;
    for (final g in widget.groups) {
      if (g.id == gid) {
        found = g;
        break;
      }
    }
    // 「自定义」组：定义由被拖入的动作登记而来，对话框里给个占位。
    final group =
        found ??
        const EditorActionGroup(
          id: kCustomGroupId,
          label: kCustomGroupLabel,
          actions: [],
        );
    final visible = !_s.hiddenGroups.contains(gid);
    final actionIds = _s.orderedActionIds(gid, [
      for (final a in group.actions) a.id,
    ]);
    final byActionId = {for (final a in group.actions) a.id: a};
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Checkbox(
                value: visible,
                onChanged: (v) => _apply(_s.withGroupHidden(gid, !(v ?? true))),
              ),
              Expanded(
                child: Text(
                  '${group.label}（${actionIds.length} 项）',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5,
                  ),
                ),
              ),
              // 停靠位置：四条工具栏任选。
              PopupMenuButton<String>(
                tooltip: '停靠位置',
                onSelected: (d) => _setGroupDock(gid, d),
                initialValue: dock,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.dock, size: 16, color: scheme.primary),
                      const SizedBox(width: 4),
                      Text(
                        EditorToolbarDocks.label(dock),
                        style: TextStyle(fontSize: 12, color: scheme.primary),
                      ),
                      const Icon(Icons.arrow_drop_down, size: 16),
                    ],
                  ),
                ),
                itemBuilder: (_) => [
                  for (final d in EditorToolbarDocks.all)
                    PopupMenuItem(
                      value: d,
                      child: Text(EditorToolbarDocks.label(d)),
                    ),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.arrow_upward, size: 18),
                tooltip: '在本栏内上移',
                onPressed: () => _moveGroup(gid, -1),
              ),
              IconButton(
                icon: const Icon(Icons.arrow_downward, size: 18),
                tooltip: '在本栏内下移',
                onPressed: () => _moveGroup(gid, 1),
              ),
            ],
          ),
          if (visible)
            for (final aid in actionIds)
              Row(
                children: [
                  const SizedBox(width: 28),
                  Checkbox(
                    value: !_s.hiddenActions.contains(aid),
                    onChanged: (v) =>
                        _apply(_s.withActionHidden(aid, !(v ?? true))),
                  ),
                  if (byActionId[aid] != null)
                    Icon(
                      byActionId[aid]!.icon,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    )
                  else
                    Icon(
                      Icons.extension_outlined,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      byActionId[aid]?.label ?? aid,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.arrow_upward, size: 16),
                    tooltip: '上移',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _moveAction(gid, aid, -1),
                  ),
                  IconButton(
                    icon: const Icon(Icons.arrow_downward, size: 16),
                    tooltip: '下移',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _moveAction(gid, aid, 1),
                  ),
                ],
              ),
        ],
      ),
    );
  }
}
