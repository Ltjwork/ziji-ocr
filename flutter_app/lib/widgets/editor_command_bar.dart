import 'package:flutter/material.dart';

import '../services/editor_toolbar_settings.dart';

/// 拖入空白 dock 的按钮落进这个隐式分组（侧边/底部工具栏不显示组名，
/// 分组只是组织单位；菜单行会多出一个「自定义」菜单）。
const String kCustomGroupId = 'custom';
const String kCustomGroupLabel = '自定义';

/// 命令栏一条动作：同一份定义同时渲染成菜单项与工具栏按钮
///（Word「命令一条、两处入口」的口径）。`menuItems` 非空时是复合动作
///（视图模式/新框类别这类一组互斥选项）：横向工具栏渲染 `ribbonBody`
/// 自定义控件，竖向工具栏渲染为带下拉的图标按钮，菜单展开为逐项勾选。
class EditorAction {
  const EditorAction({
    required this.id,
    required this.label,
    required this.icon,
    required this.tooltip,
    this.enabled = true,
    this.checked = false,
    this.danger = false,
    this.trailingSeparator = false,
    this.onPressed,
    this.ribbonBody,
    this.menuItems,
    this.visible = true,
  });

  final String id;
  final String label;
  final IconData icon;
  final String tooltip;
  final bool enabled;

  /// 切换类动作的生效态：工具栏高亮底色，菜单尾缀对勾。
  final bool checked;

  /// 危险动作（删除页）：红显。
  final bool danger;

  /// 动作后追加组内分隔线（同类操作与下一簇之间）。
  final bool trailingSeparator;
  final VoidCallback? onPressed;

  /// 复合动作的横向工具栏内嵌控件（分段按钮/类别 chips）。
  final WidgetBuilder? ribbonBody;

  /// 复合动作的菜单展开项（勾选列表；竖向工具栏的同名下拉同源）。
  final List<EditorMenuItemSpec>? menuItems;

  /// 按当前视图状态是否出现（如新框类别仅主区视图）。
  final bool visible;
}

/// 复合动作在菜单/竖向工具栏下拉里的展开项（或显式分隔线）。
class EditorMenuItemSpec {
  const EditorMenuItemSpec({
    required this.label,
    this.icon,
    this.colorDot,
    this.checked = false,
    this.enabled = true,
    this.onPressed,
  }) : isSeparator = false;

  const EditorMenuItemSpec.separator()
    : label = '',
      icon = null,
      colorDot = null,
      checked = false,
      enabled = false,
      onPressed = null,
      isSeparator = true;

  final String label;
  final IconData? icon;

  /// 类别色圆点（新框类别等带语义色的选项）。
  final Color? colorDot;
  final bool checked;
  final bool enabled;
  final VoidCallback? onPressed;
  final bool isSeparator;
}

/// 命令栏的一个功能分组：菜单栏的一列下拉菜单，工具栏的一簇按钮
///（簇间竖分隔线、簇下组名小字）。
class EditorActionGroup {
  const EditorActionGroup({
    required this.id,
    required this.label,
    required this.actions,
  });

  final String id;
  final String label;
  final List<EditorAction> actions;
}

/// 拖拽载荷：按钮（可跨组/跨 dock 重摆）或整组（按组名/握把拖动）。
sealed class EditorDragPayload {
  const EditorDragPayload();
}

class EditorActionDragPayload extends EditorDragPayload {
  const EditorActionDragPayload({
    required this.fromGroup,
    required this.actionId,
  });

  final String fromGroup;
  final String actionId;
}

class EditorGroupDragPayload extends EditorDragPayload {
  const EditorGroupDragPayload({required this.groupId});

  final String groupId;
}

/// 动作登记归属表：actionId -> 登记它的组 id。拖拽移动只改
/// actionOrder，渲染时按归属决定"这个动作现在属于哪组"——源组定义
/// 里的同 id 不再渲染。从未自定义时返回空表，一切按默认定义渲染。
Map<String, String> _actionOwners(EditorToolbarSettings settings) {
  final owners = <String, String>{};
  for (final dock in EditorToolbarDocks.all) {
    for (final gid in settings.docks[dock] ?? const <String>[]) {
      for (final aid in settings.actionOrder[gid] ?? const <String>[]) {
        owners.putIfAbsent(aid, () => gid);
      }
    }
  }
  return owners;
}

/// 解析某组的完整动作清单：组内定义的动作（未被其它组登记夺走的）+
/// 登记到本组的外来动作（如「自定义」组本身没有定义项，全靠登记）。
List<EditorAction> _resolveGroupActions(
  EditorToolbarSettings settings,
  EditorActionGroup group,
  Map<String, EditorAction> globalActions,
) {
  final owners = _actionOwners(settings);
  final defined = <String>[
    for (final a in group.actions)
      if (owners[a.id] == null || owners[a.id] == group.id) a.id,
  ];
  final imported = [
    for (final id in settings.actionOrder[group.id] ?? const <String>[])
      if (globalActions.containsKey(id) &&
          !defined.contains(id) &&
          // 归属在别的组的历史残留不渲染回来（拖走后又被算回来会复活）。
          (owners[id] == null || owners[id] == group.id))
        id,
  ];
  return [
    for (final id in settings.orderedActionIds(group.id, [
      ...defined,
      ...imported,
    ]))
      if (globalActions[id] != null) globalActions[id]!,
  ];
}

/// 某组按布局过滤后的动作（隐藏/当前不可见剔除）。
List<EditorAction> visibleActionsOf(
  EditorToolbarSettings settings,
  EditorActionGroup group,
  Map<String, EditorAction> globalActions,
) => [
  for (final a in _resolveGroupActions(settings, group, globalActions))
    if (!settings.hiddenActions.contains(a.id) && a.visible) a,
];

/// 某组当前"名下"的动作 id 完整清单（定义 - 被其它组登记夺走的 +
/// 登记进来的）：拖拽落盘时喂给 withActionMoved 的 fromOrder/toOrder。
List<String> fullActionIdsFor(
  EditorToolbarSettings settings,
  List<EditorActionGroup> defs,
  String gid,
) {
  final owners = _actionOwners(settings);
  EditorActionGroup? group;
  for (final d in defs) {
    if (d.id == gid) {
      group = d;
      break;
    }
  }
  if (group == null) {
    return [
      ...?(settings.actionOrder[gid])?.where(
        (id) => owners[id] == null || owners[id] == gid,
      ),
    ];
  }
  final defined = <String>[
    for (final a in group.actions)
      if (owners[a.id] == null || owners[a.id] == gid) a.id,
  ];
  final imported = [
    for (final id in settings.actionOrder[gid] ?? const <String>[])
      if (!defined.contains(id) &&
          (owners[id] == null || owners[id] == gid))
        id,
  ];
  return settings.orderedActionIds(gid, [...defined, ...imported]);
}

/// 「自定义」组是否被引用（引用时页面要注入它的定义，菜单行才有多
/// 出来的「自定义」列）：在某个 dock 里登记过，或名下登记过动作。
/// 后半句是自愈口径——修复前的版本拖按钮进空栏只写了 actionOrder、
/// 漏了 dock 登记，那些按钮靠这条重新按顶部渲染出来（可再拖走）。
bool settingsUseCustomGroup(EditorToolbarSettings settings) =>
    settings.docks.values.any((l) => l.contains(kCustomGroupId)) ||
    ((settings.actionOrder[kCustomGroupId] ?? const <String>[]).isNotEmpty);

/// 「自定义」组是否已登记进某条 dock。与 [settingsUseCustomGroup] 的
/// 区别是落点守卫用：动作移入「自定义」组后名下必然非空（自愈口径
/// 恒真），若用它做守卫会把"登记进落点 dock"这步永远跳过，按钮就
/// 永远落不到新栏上。
bool customGroupDocked(EditorToolbarSettings settings) =>
    settings.docks.values.any((l) => l.contains(kCustomGroupId));

/// 拖放落点的统一落盘逻辑（控制器与测试共用）：动作移入 [toGroup]
/// 的 [beforeActionId] 之前（null = 组尾）；拖进空白 dock 时占位框会
/// 带上 [dockHint]——目标组是「自定义」且它还没停靠过任何 dock，就
/// 把它登记进落点 dock，否则按钮会渲染不到新栏。
EditorToolbarSettings applyActionDrop(
  EditorToolbarSettings settings,
  List<EditorActionGroup> defs,
  EditorActionDragPayload payload, {
  required String toGroup,
  String? beforeActionId,
  String? dockHint,
}) {
  var next = settings.withActionMoved(
    payload.actionId,
    payload.fromGroup,
    toGroup,
    beforeActionId,
    fromOrder: fullActionIdsFor(settings, defs, payload.fromGroup),
    toOrder: toGroup == payload.fromGroup
        ? fullActionIdsFor(settings, defs, payload.fromGroup)
        : fullActionIdsFor(settings, defs, toGroup),
  );
  if (toGroup == kCustomGroupId &&
      dockHint != null &&
      !customGroupDocked(next)) {
    final defaults = [for (final g in defs) g.id, kCustomGroupId];
    next = next.withGroupMoved(
      kCustomGroupId,
      dockHint,
      null,
      currentDocksFull: {
        for (final d in EditorToolbarDocks.all)
          d: next.groupsInDock(d, defaults),
      },
    );
  }
  return next;
}

/// 把用户布局套到动作定义上，产出每条 dock 的分组序列：
/// 分组按各 dock 登记顺序排（未登记的默认归顶部），过滤隐藏分组/
/// 动作与不可见动作；空组不出现。
Map<String, List<EditorActionGroup>> applyToolbarLayout(
  EditorToolbarSettings settings,
  List<EditorActionGroup> groups,
) {
  final globalActions = {
    for (final g in groups)
      for (final a in g.actions) a.id: a,
  };
  final byId = {for (final g in groups) g.id: g};
  final result = <String, List<EditorActionGroup>>{
    for (final d in EditorToolbarDocks.all) d: <EditorActionGroup>[],
  };
  for (final dock in EditorToolbarDocks.all) {
    final gids = settings.groupsInDock(dock, [
      for (final g in groups) g.id,
      if (settingsUseCustomGroup(settings)) kCustomGroupId,
    ]);
    for (final gid in gids) {
      if (settings.hiddenGroups.contains(gid)) continue;
      final def =
          byId[gid] ??
          (gid == kCustomGroupId
              ? const EditorActionGroup(
                  id: kCustomGroupId,
                  label: kCustomGroupLabel,
                  actions: [],
                )
              : null);
      if (def == null) continue;
      final actions = visibleActionsOf(settings, def, globalActions);
      if (actions.isNotEmpty) {
        result[dock]!.add(
          EditorActionGroup(id: def.id, label: def.label, actions: actions),
        );
      }
    }
  }
  return result;
}

/// 按全局顺序取得某组的菜单版（跨 dock 有效；空组返回 null）。
EditorActionGroup? menuGroupFor(
  EditorToolbarSettings settings,
  List<EditorActionGroup> groups,
  String gid,
) {
  EditorActionGroup? def;
  for (final g in groups) {
    if (g.id == gid) {
      def = g;
      break;
    }
  }
  if (def == null) return null;
  final globalActions = {
    for (final g in groups)
      for (final a in g.actions) a.id: a,
  };
  final actions = visibleActionsOf(settings, def, globalActions);
  if (actions.isEmpty) return null;
  return EditorActionGroup(id: def.id, label: def.label, actions: actions);
}

/// 编辑器命令栏（顶部）：上行菜单（全部分组按类归列，与停靠位置无关），
/// 下行顶部工具栏（四条可停靠 dock 之一）。其余三条 dock 由页面用
/// [EditorDockBar] / [EditorEmptyDockPlaceholder] 渲染；拖拽回调统一
/// 由页面（命令栏控制器）处理并落盘。
class EditorCommandBar extends StatelessWidget {
  const EditorCommandBar({
    super.key,
    required this.groups,
    required this.settings,
    required this.onOpenCustomize,
    required this.onDragStarted,
    required this.onDragEnded,
    required this.onMoveAction,
    this.onMoveActionToDock,
    required this.onMoveGroup,
  });

  /// 全量动作定义（按当前页面状态构造好 enabled/checked/visible）。
  final List<EditorActionGroup> groups;
  final EditorToolbarSettings settings;
  final VoidCallback onOpenCustomize;
  final ValueChanged<EditorDragPayload> onDragStarted;
  final VoidCallback onDragEnded;
  final void Function(
    EditorActionDragPayload payload,
    String toGroup,
    String? beforeActionId,
  )
  onMoveAction;

  /// 顶部被搬空时的占位落点用：带 dock 信息（把拖入动作归入的
  /// 「自定义」组登记回顶部）。缺省时退化为 [onMoveAction]（不登记）。
  final void Function(
    EditorActionDragPayload payload,
    String toGroup,
    String? beforeActionId,
    String dock,
  )?
  onMoveActionToDock;
  final void Function(String groupId, String toDock, String? beforeGroupId)
  onMoveGroup;

  @override
  Widget build(BuildContext context) {
    final laidOut = applyToolbarLayout(settings, groups);
    final menuGids = settings.orderedGroupIds([
      for (final g in groups) g.id,
      if (settingsUseCustomGroup(settings)) kCustomGroupId,
    ]);
    final menuGroups = <EditorActionGroup>[];
    for (final gid in menuGids) {
      if (settings.hiddenGroups.contains(gid)) continue;
      final g = menuGroupFor(settings, groups, gid);
      if (g != null) menuGroups.add(g);
    }
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Colors.black12)),
      ),
      child: Column(
        children: [
          // 菜单行：全部功能分组（不管停靠在哪条 dock），保证"菜单里
          // 什么都有"。
          Row(
            children: [
              for (final menuGroup in menuGroups)
                _MenuBarButton(group: menuGroup),
              const Spacer(),
              Tooltip(
                message: '自定义工具栏：显示/隐藏、拖拽摆位、调整顺序（自动保存）',
                child: IconButton(
                  icon: const Icon(Icons.tune, size: 20),
                  visualDensity: VisualDensity.compact,
                  onPressed: onOpenCustomize,
                ),
              ),
              const SizedBox(width: 4),
            ],
          ),
          // 顶部工具栏；被搬空时留一条可落点的占位（拖回即恢复）。
          if (laidOut[EditorToolbarDocks.top]!.isNotEmpty)
            EditorDockBar(
              dock: EditorToolbarDocks.top,
              groups: laidOut[EditorToolbarDocks.top]!,
              settings: settings,
              showBorder: false,
              onDragStarted: onDragStarted,
              onDragEnded: onDragEnded,
              onMoveAction: onMoveAction,
              onMoveGroup: onMoveGroup,
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: EditorEmptyDockPlaceholder(
                dock: EditorToolbarDocks.top,
                onMoveAction: onMoveActionToDock ??
                    (payload, group, before, _) =>
                        onMoveAction(payload, group, before),
                onMoveGroup: onMoveGroup,
              ),
            ),
        ],
      ),
    );
  }
}

/// 一条可停靠工具栏（顶部/底部横排，左/右竖排）：分组功能区 + 拖拽
/// 吸附。拖动按钮时每个落点前显示插入指示线；组名（横排）或握把
///（竖排）可整组拖动跨 dock。
class EditorDockBar extends StatelessWidget {
  const EditorDockBar({
    super.key,
    required this.dock,
    required this.groups,
    required this.settings,
    required this.onDragStarted,
    required this.onDragEnded,
    required this.onMoveAction,
    required this.onMoveGroup,
    this.showBorder = true,
  });

  final String dock;
  final List<EditorActionGroup> groups;
  final EditorToolbarSettings settings;
  final ValueChanged<EditorDragPayload> onDragStarted;
  final VoidCallback onDragEnded;
  final void Function(
    EditorActionDragPayload payload,
    String toGroup,
    String? beforeActionId,
  )
  onMoveAction;
  final void Function(String groupId, String toDock, String? beforeGroupId)
  onMoveGroup;
  final bool showBorder;

  bool get _vertical =>
      dock == EditorToolbarDocks.left || dock == EditorToolbarDocks.right;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_vertical) {
      return Container(
        width: 48,
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border(
            right: dock == EditorToolbarDocks.left
                ? BorderSide(
                    color: scheme.outlineVariant.withValues(alpha: 0.5),
                  )
                : BorderSide.none,
            left: dock == EditorToolbarDocks.right
                ? BorderSide(
                    color: scheme.outlineVariant.withValues(alpha: 0.5),
                  )
                : BorderSide.none,
          ),
        ),
        child: SingleChildScrollView(
          child: Column(
            children: [
              const SizedBox(height: 2),
              _GroupGapTarget(
                dock: this,
                beforeGroup: groups.isEmpty ? null : groups.first.id,
              ),
              for (var i = 0; i < groups.length; i++) ...[
                _DockGroupSection(bar: this, group: groups[i]),
                if (i < groups.length - 1) ...[
                  Divider(
                    height: 5,
                    thickness: 1,
                    indent: 8,
                    endIndent: 8,
                    color: scheme.outlineVariant.withValues(alpha: 0.6),
                  ),
                  _GroupGapTarget(dock: this, beforeGroup: groups[i + 1].id),
                ],
              ],
              const SizedBox(height: 2),
            ],
          ),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: showBorder
            ? Border(
                top: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.5),
                ),
              )
            : null,
      ),
      height: settings.showGroupLabels ? 62 : 46,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _GroupGapTarget(
              dock: this,
              beforeGroup: groups.isEmpty ? null : groups.first.id,
            ),
            for (var i = 0; i < groups.length; i++) ...[
              _DockGroupSection(bar: this, group: groups[i]),
              if (i < groups.length - 1)
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 8),
                  width: 1,
                  color: scheme.outlineVariant,
                ),
              if (i < groups.length - 1)
                _GroupGapTarget(dock: this, beforeGroup: groups[i + 1].id),
            ],
          ],
        ),
      ),
    );
  }
}

/// 组与组之间的落点（拖动时的吸附指示位）：动作落入 = 插到
/// [beforeGroup] 组的第一个动作前；组落入 = 整组移到 [beforeGroup] 前。
class _GroupGapTarget extends StatelessWidget {
  const _GroupGapTarget({required this.dock, required this.beforeGroup});

  final EditorDockBar dock;
  final String? beforeGroup;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final horizontal = !dock._vertical;
    return DragTarget<EditorDragPayload>(
      onWillAccept: (data) {
        if (data is EditorActionDragPayload) return beforeGroup != null;
        if (data is EditorGroupDragPayload) {
          return data.groupId != beforeGroup &&
              data.groupId != _nextGroupId(dock.groups, beforeGroup);
        }
        return false;
      },
      builder: (context, candidates, _) {
        final hovered = candidates.isNotEmpty;
        return Container(
          width: horizontal ? (hovered ? 12 : 5) : 48,
          height: horizontal ? double.infinity : (hovered ? 12 : 4),
          margin: horizontal
              ? null
              : const EdgeInsets.symmetric(vertical: 1),
          color: hovered ? scheme.primary.withValues(alpha: 0.18) : null,
          alignment: Alignment.center,
          child: hovered
              ? Container(
                  width: horizontal ? 3 : 36,
                  height: horizontal ? 40 : 3,
                  color: scheme.primary,
                )
              : null,
        );
      },
      onAccept: (data) {
        if (data is EditorActionDragPayload && beforeGroup != null) {
          EditorActionGroup? target;
          for (final g in dock.groups) {
            if (g.id == beforeGroup) {
              target = g;
              break;
            }
          }
          dock.onMoveAction(
            data,
            beforeGroup!,
            target == null || target.actions.isEmpty
                ? null
                : target.actions.first.id,
          );
        } else if (data is EditorGroupDragPayload) {
          dock.onMoveGroup(data.groupId, dock.dock, beforeGroup);
        }
      },
    );
  }

  static String? _nextGroupId(List<EditorActionGroup> groups, String? gid) {
    if (gid == null) return null;
    final i = groups.indexWhere((g) => g.id == gid);
    return i >= 0 && i + 1 < groups.length ? groups[i + 1].id : null;
  }
}

/// 一条 dock 里的一组：横排为「按钮行 + 组名小字（可拖整组）」，竖排
/// 为「握把 + 图标按钮列 + 组尾落点」。
class _DockGroupSection extends StatelessWidget {
  const _DockGroupSection({required this.bar, required this.group});

  final EditorDockBar bar;
  final EditorActionGroup group;

  @override
  Widget build(BuildContext context) {
    if (bar._vertical) return _buildVertical(context);
    final scheme = Theme.of(context).colorScheme;
    final buttons = <Widget>[];
    for (final action in group.actions) {
      buttons.add(
        _DropActionSlot(bar: bar, action: action, group: group, vertical: false),
      );
      if (action.trailingSeparator) {
        buttons.add(
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            width: 1,
            color: scheme.outlineVariant,
          ),
        );
      }
    }
    buttons.add(_GroupEndTarget(bar: bar, group: group, vertical: false));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // IntrinsicHeight + stretch：组尾落点的占满高度（infinity）在
          // 无界高度的普通 Row 里会炸（infinite height），靠它定界。
          IntrinsicHeight(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: buttons,
            ),
          ),
          if (bar.settings.showGroupLabels)
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: _GroupDragHandle(
                bar: bar,
                group: group,
                child: Text(
                  group.label,
                  style: TextStyle(
                    fontSize: 10,
                    height: 1.2,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildVertical(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        _GroupDragHandle(
          bar: bar,
          group: group,
          child: Icon(
            Icons.drag_indicator,
            size: 12,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
          ),
        ),
        for (final action in group.actions)
          _DropActionSlot(bar: bar, action: action, group: group, vertical: true),
        _GroupEndTarget(bar: bar, group: group, vertical: true),
      ],
    );
  }
}

/// 组名/握把：整组拖拽的把手（拖动跨 dock 摆放整组）。
class _GroupDragHandle extends StatelessWidget {
  const _GroupDragHandle({
    required this.bar,
    required this.group,
    required this.child,
  });

  final EditorDockBar bar;
  final EditorActionGroup group;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.move,
      child: Draggable<EditorDragPayload>(
        data: EditorGroupDragPayload(groupId: group.id),
        onDragStarted: () =>
            bar.onDragStarted(EditorGroupDragPayload(groupId: group.id)),
        onDragEnd: (_) => bar.onDragEnded(),
        feedback: Material(
          color: Colors.transparent,
          child: Chip(
            avatar: const Icon(Icons.drag_indicator, size: 14),
            label: Text(group.label),
            visualDensity: VisualDensity.compact,
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.3, child: child),
        child: child,
      ),
    );
  }
}

/// 按钮落点槽：自身是可拖走的按钮（Draggable），同时是「插到本按钮前」
/// 的 DragTarget。悬停时在本按钮边缘显示吸附指示线（覆盖式，不挤动
/// 邻居导致抖动）。
class _DropActionSlot extends StatelessWidget {
  const _DropActionSlot({
    required this.bar,
    required this.action,
    required this.group,
    required this.vertical,
  });

  final EditorDockBar bar;
  final EditorAction action;
  final EditorActionGroup group;
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final payload = EditorActionDragPayload(
      fromGroup: group.id,
      actionId: action.id,
    );
    final button = vertical
        ? _VerticalActionButton(action: action)
        : _RibbonButton(action: action);
    return MouseRegion(
      cursor: SystemMouseCursors.move,
      child: Draggable<EditorDragPayload>(
        data: payload,
        onDragStarted: () => bar.onDragStarted(payload),
        onDragEnd: (_) => bar.onDragEnded(),
        feedback: _DragFeedback(action: action, vertical: vertical),
        childWhenDragging: Opacity(opacity: 0.3, child: button),
        child: DragTarget<EditorDragPayload>(
          onWillAccept: (data) => data is EditorActionDragPayload
              ? data.actionId != action.id
              : data is EditorGroupDragPayload && data.groupId != group.id,
          builder: (context, candidates, _) {
            final hovered = candidates.isNotEmpty;
            if (!hovered) return button;
            // 吸附指示：插入线亮在本按钮前缘（负偏移覆盖，不挤布局）。
            return Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                button,
                Positioned(
                  left: vertical ? null : -4,
                  top: vertical ? -3 : null,
                  child: Container(
                    width: vertical ? 36 : 3,
                    height: vertical ? 3 : 40,
                    color: scheme.primary,
                  ),
                ),
              ],
            );
          },
          onAccept: (data) {
            if (data is EditorActionDragPayload) {
              bar.onMoveAction(data, group.id, action.id);
            } else if (data is EditorGroupDragPayload) {
              bar.onMoveGroup(data.groupId, bar.dock, group.id);
            }
          },
        ),
      ),
    );
  }
}

/// 组尾落点：动作落入 = 追加到本组末尾；组落入 = 移到本 dock 末尾。
class _GroupEndTarget extends StatelessWidget {
  const _GroupEndTarget({
    required this.bar,
    required this.group,
    required this.vertical,
  });

  final EditorDockBar bar;
  final EditorActionGroup group;
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lastId = group.actions.isEmpty ? null : group.actions.last.id;
    return DragTarget<EditorDragPayload>(
      onWillAccept: (data) => data is EditorActionDragPayload
          ? data.actionId != lastId
          : data is EditorGroupDragPayload && data.groupId != group.id,
      builder: (context, candidates, _) {
        final hovered = candidates.isNotEmpty;
        return Container(
          width: vertical ? 40 : (hovered ? 14 : 6),
          height: vertical ? (hovered ? 14 : 6) : double.infinity,
          margin: EdgeInsets.only(left: vertical ? 0 : 2, top: vertical ? 2 : 0),
          color: hovered ? scheme.primary.withValues(alpha: 0.18) : null,
          alignment: Alignment.center,
          child: hovered
              ? Container(
                  width: vertical ? 36 : 3,
                  height: vertical ? 3 : 36,
                  color: scheme.primary,
                )
              : null,
        );
      },
      onAccept: (data) {
        if (data is EditorActionDragPayload) {
          bar.onMoveAction(data, group.id, null);
        } else if (data is EditorGroupDragPayload) {
          bar.onMoveGroup(data.groupId, bar.dock, null);
        }
      },
    );
  }
}

Icon _actionIcon(EditorAction action, ColorScheme scheme, {double? size}) {
  final color = action.enabled
      ? action.danger
            ? scheme.error
            : action.checked
            ? scheme.onSecondaryContainer
            : scheme.onSurface.withValues(alpha: 0.85)
      : scheme.onSurface.withValues(alpha: 0.35);
  return Icon(action.icon, size: size ?? 20, color: color);
}

/// 拖动时跟随指针的按钮影子（带投影，一眼可辨）。
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.action, required this.vertical});

  final EditorAction action;
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: Container(
        width: vertical ? 40 : null,
        height: vertical ? 34 : null,
        padding: vertical
            ? null
            : const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        constraints: vertical ? null : const BoxConstraints(minWidth: 52),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(6),
          boxShadow: [
            BoxShadow(color: scheme.shadow.withValues(alpha: 0.35), blurRadius: 8),
          ],
        ),
        child: vertical
            ? Center(child: _actionIcon(action, scheme, size: 19))
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _actionIcon(action, scheme),
                  const SizedBox(height: 2),
                  Text(
                    action.label,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 10.5,
                      height: 1.2,
                      color: scheme.onSurface.withValues(alpha: 0.85),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// 横向工具栏按钮：图标 + 小字标签，Word 观感（平铺、悬停浅底、
/// 切换态色底、危险动作红显）。复合动作内嵌分段控件。纯展示——
/// 拖拽与点击落点由 [_DropActionSlot] 统一包。
class _RibbonButton extends StatelessWidget {
  const _RibbonButton({required this.action});

  final EditorAction action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = action.enabled && action.onPressed != null;
    final disabledColor = scheme.onSurface.withValues(alpha: 0.35);
    if (action.ribbonBody != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Builder(builder: action.ribbonBody!),
      );
    }
    return Tooltip(
      message: action.tooltip,
      child: Material(
        color: action.checked ? scheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: enabled ? action.onPressed : null,
          child: Container(
            constraints: const BoxConstraints(minWidth: 52),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _actionIcon(action, scheme),
                const SizedBox(height: 2),
                Text(
                  action.label,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.2,
                    color: enabled
                        ? (action.danger
                              ? scheme.error
                              : scheme.onSurface.withValues(alpha: 0.85))
                        : disabledColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 竖向工具栏按钮：纯图标；复合动作带下拉箭头，点开同源菜单。
class _VerticalActionButton extends StatelessWidget {
  const _VerticalActionButton({required this.action});

  final EditorAction action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget button = Tooltip(
      message: '${action.label}：${action.tooltip}',
      child: SizedBox(
        width: 40,
        height: 34,
        child: Material(
          color: action.checked ? scheme.secondaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: action.enabled && action.onPressed != null
                ? action.onPressed
                : null,
            child: Stack(
              alignment: Alignment.center,
              children: [
                _actionIcon(action, scheme, size: 19),
                if (action.menuItems != null)
                  Positioned(
                    right: 2,
                    bottom: 2,
                    child: Icon(
                      Icons.arrow_drop_down,
                      size: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (action.menuItems != null) {
      button = MenuAnchor(
        menuChildren: [
          for (final item in action.menuItems!)
            item.isSeparator
                ? const Divider(height: 9, indent: 12, endIndent: 12)
                : MenuItemButton(
                    leadingIcon: item.icon != null
                        ? Icon(item.icon, size: 18)
                        : item.colorDot != null
                        ? Container(
                            width: 18,
                            alignment: Alignment.center,
                            child: Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: item.colorDot,
                                shape: BoxShape.circle,
                              ),
                            ),
                          )
                        : null,
                    trailingIcon: item.checked
                        ? Icon(Icons.check, size: 18, color: scheme.primary)
                        : null,
                    onPressed: item.enabled ? item.onPressed : null,
                    style: MenuItemButton.styleFrom(
                      minimumSize: const Size(160, 36),
                    ),
                    child: Text(item.label),
                  ),
        ],
        builder: (context, controller, child) => InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () =>
              controller.isOpen ? controller.close() : controller.open(),
          child: child,
        ),
        child: button,
      );
    }
    return button;
  }
}

/// 菜单栏里的一列（一个功能分组）。
class _MenuBarButton extends StatefulWidget {
  const _MenuBarButton({required this.group});

  final EditorActionGroup group;

  @override
  State<_MenuBarButton> createState() => _MenuBarButtonState();
}

class _MenuBarButtonState extends State<_MenuBarButton> {
  final _controller = MenuController();

  List<Widget> _menuChildren(BuildContext context, EditorActionGroup group) {
    final scheme = Theme.of(context).colorScheme;
    final children = <Widget>[];
    for (final action in group.actions) {
      final items = action.menuItems;
      if (items != null) {
        for (final item in items) {
          children.add(
            item.isSeparator
                ? const Divider(height: 9, indent: 12, endIndent: 12)
                : _menuItemTile(context, scheme, item),
          );
        }
        continue;
      }
      final enabled = action.enabled && action.onPressed != null;
      children.add(
        MenuItemButton(
          leadingIcon: Icon(
            action.icon,
            size: 18,
            color: action.danger
                ? scheme.error
                : enabled
                ? null
                : scheme.onSurface.withValues(alpha: 0.35),
          ),
          trailingIcon: action.checked
              ? Icon(Icons.check, size: 18, color: scheme.primary)
              : null,
          onPressed: enabled ? action.onPressed : null,
          style: MenuItemButton.styleFrom(
            minimumSize: const Size(180, 38),
            foregroundColor: action.danger ? scheme.error : null,
          ),
          child: Text(action.label),
        ),
      );
      if (action.trailingSeparator) {
        children.add(const Divider(height: 9, indent: 12, endIndent: 12));
      }
    }
    return children;
  }

  Widget _menuItemTile(
    BuildContext context,
    ColorScheme scheme,
    EditorMenuItemSpec item,
  ) {
    return MenuItemButton(
      leadingIcon: item.icon != null
          ? Icon(
              item.icon,
              size: 18,
              color: item.enabled
                  ? null
                  : scheme.onSurface.withValues(alpha: 0.35),
            )
          : item.colorDot != null
          ? Container(
              width: 18,
              alignment: Alignment.center,
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: item.colorDot,
                  shape: BoxShape.circle,
                ),
              ),
            )
          : null,
      trailingIcon: item.checked
          ? Icon(Icons.check, size: 18, color: scheme.primary)
          : null,
      onPressed: item.enabled ? item.onPressed : null,
      style: MenuItemButton.styleFrom(minimumSize: const Size(180, 36)),
      child: Text(item.label),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MenuAnchor(
      controller: _controller,
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(scheme.surface),
      ),
      menuChildren: _menuChildren(context, widget.group),
      builder: (context, controller, child) => TextButton(
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          foregroundColor: controller.isOpen ? scheme.primary : null,
        ),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.group.label),
            Icon(
              controller.isOpen
                  ? Icons.arrow_drop_up
                  : Icons.arrow_drop_down,
              size: 16,
            ),
          ],
        ),
      ),
    );
  }
}

/// 拖拽期间空白 dock 的落点占位：细高亮框 + 提示字。动作落入 = 建一个
/// 「自定义」组收下它；组落入 = 整组搬来。也用作顶部被搬空时的恢复落点。
class EditorEmptyDockPlaceholder extends StatelessWidget {
  const EditorEmptyDockPlaceholder({
    super.key,
    required this.dock,
    required this.onMoveAction,
    required this.onMoveGroup,
  });

  final String dock;

  /// [dock] 参数要一起回传：动作落进空白 dock 时，控制器除了把它
  /// 登记进「自定义」组，还必须把「自定义」组登记进这条 dock——
  /// 否则组不在任何 dock 的分组表里，按钮会"消失"（原组移除、新栏
  /// 又不渲染）。
  final void Function(
    EditorActionDragPayload payload,
    String toGroup,
    String? beforeActionId,
    String dock,
  )
  onMoveAction;
  final void Function(String groupId, String toDock, String? beforeGroupId)
  onMoveGroup;

  bool get _vertical =>
      dock == EditorToolbarDocks.left || dock == EditorToolbarDocks.right;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DragTarget<EditorDragPayload>(
      onWillAccept: (data) =>
          data is! EditorGroupDragPayload || data.groupId != kCustomGroupId,
      builder: (context, candidates, _) {
        final hovered = candidates.isNotEmpty;
        return Container(
          width: _vertical ? 44 : double.infinity,
          height: _vertical ? double.infinity : 30,
          margin: _vertical
              ? const EdgeInsets.symmetric(vertical: 8, horizontal: 2)
              : const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: hovered
                  ? scheme.primary
                  : scheme.outlineVariant.withValues(alpha: 0.6),
            ),
            color: hovered
                ? scheme.primary.withValues(alpha: 0.08)
                : scheme.surfaceContainerHighest.withValues(alpha: 0.25),
          ),
          alignment: Alignment.center,
          child: Text(
            hovered ? '松开停靠到${EditorToolbarDocks.label(dock)}' : '拖到这里',
            style: TextStyle(
              fontSize: 11,
              color: hovered
                  ? scheme.primary
                  : scheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        );
      },
      onAccept: (data) {
        if (data is EditorActionDragPayload) {
          onMoveAction(data, kCustomGroupId, null, dock);
        } else if (data is EditorGroupDragPayload) {
          onMoveGroup(data.groupId, dock, null);
        }
      },
    );
  }
}
