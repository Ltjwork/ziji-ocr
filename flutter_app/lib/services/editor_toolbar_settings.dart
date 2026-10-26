import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 编辑器命令栏的四条可停靠工具栏（PS 式）：顶部（Word 式菜单+功能区）、
/// 底部、左侧、右侧。分组可整组拖到任意一条，组内按钮可跨组/跨条拖。
class EditorToolbarDocks {
  static const String top = 'top';
  static const String bottom = 'bottom';
  static const String left = 'left';
  static const String right = 'right';

  /// 渲染与菜单行拼接的固定顺序。
  static const List<String> all = [top, bottom, left, right];

  static String label(String dock) => switch (dock) {
        bottom => '底部工具栏',
        left => '左侧工具栏',
        right => '右侧工具栏',
        _ => '顶部工具栏',
      };
}

/// 编辑器命令栏的自定义布局：
/// - [docks]：每条工具栏里有序的分组 id（分组默认都在顶部）；
/// - [actionOrder]：组内动作顺序；
/// - 隐藏的分组/动作与组名小字开关。
/// 只存 id 与顺序——动作定义（图标/文案/回调）在编辑器页内，升级新增
/// 动作/分组时未登记的 id 自动按默认位置补齐，旧布局不失效。
class EditorToolbarSettings {
  const EditorToolbarSettings({
    this.docks = const <String, List<String>>{},
    this.hiddenGroups = const <String>{},
    this.actionOrder = const <String, List<String>>{},
    this.hiddenActions = const <String>{},
    this.showGroupLabels = true,
  });

  /// dock id -> 有序分组 id。未登记的分组视为在顶部按默认顺序。
  final Map<String, List<String>> docks;

  /// 整组隐藏。
  final Set<String> hiddenGroups;

  /// 组内动作顺序：groupId -> 有序 actionId 列表（未登记的动作按
  /// 定义顺序追加在该组末尾）。
  final Map<String, List<String>> actionOrder;

  /// 单个动作隐藏（组隐藏优先——组被隐藏时动作可见性无意义）。
  final Set<String> hiddenActions;

  /// 横向工具栏（顶部/底部）分组下方是否显示组名小字（Word「组」
  /// 标题样式）。侧边竖条不显示组名。
  final bool showGroupLabels;

  static const String _prefsKey = 'editor_toolbar_settings_v2';

  factory EditorToolbarSettings.fromJson(Map<String, dynamic> j) {
    final rawDocks = j['docks'];
    List<String> idList(dynamic raw) => [
      if (raw is List)
        for (final v in raw)
          if (v is String) v,
    ];
    return EditorToolbarSettings(
      docks: {
        if (rawDocks is Map)
          for (final e in rawDocks.entries)
            if (e.key is String) e.key as String: idList(e.value),
      },
      hiddenGroups: idList(j['hiddenGroups']).toSet(),
      actionOrder: {
        if (j['actionOrder'] is Map)
          for (final e in (j['actionOrder'] as Map).entries)
            if (e.key is String && e.value is List)
              e.key as String: idList(e.value),
      },
      hiddenActions: idList(j['hiddenActions']).toSet(),
      showGroupLabels: j['showGroupLabels'] is bool
          ? j['showGroupLabels'] as bool
          : true,
    );
  }

  Map<String, dynamic> toJson() => {
    'docks': docks,
    'hiddenGroups': hiddenGroups.toList(),
    'actionOrder': actionOrder,
    'hiddenActions': hiddenActions.toList(),
    'showGroupLabels': showGroupLabels,
  };

  static Future<EditorToolbarSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        return EditorToolbarSettings.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw) as Map),
        );
      } catch (_) {}
    }
    // v1（只有单一顺序、无 dock 概念）迁移：全部组进顶部，其余字段照搬。
    final v1raw = prefs.getString('editor_toolbar_settings_v1');
    if (v1raw != null && v1raw.isNotEmpty) {
      try {
        final v1 = EditorToolbarSettings.fromJson(
          Map<String, dynamic>.from(jsonDecode(v1raw) as Map),
        );
        final v1Order = () {
          final raw = jsonDecode(v1raw);
          final list =
              (raw is Map && raw['groupOrder'] is List)
                  ? raw['groupOrder'] as List
                  : const [];
          return [
            for (final v in list)
              if (v is String) v,
          ];
        }();
        return EditorToolbarSettings(
          docks: {if (v1Order.isNotEmpty) EditorToolbarDocks.top: v1Order},
          hiddenGroups: v1.hiddenGroups,
          actionOrder: v1.actionOrder,
          hiddenActions: v1.hiddenActions,
          showGroupLabels: v1.showGroupLabels,
        );
      } catch (_) {}
    }
    return const EditorToolbarSettings();
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(toJson()));
  }

  EditorToolbarSettings copyWith({
    Map<String, List<String>>? docks,
    Set<String>? hiddenGroups,
    Map<String, List<String>>? actionOrder,
    Set<String>? hiddenActions,
    bool? showGroupLabels,
  }) => EditorToolbarSettings(
    docks: docks ?? this.docks,
    hiddenGroups: hiddenGroups ?? this.hiddenGroups,
    actionOrder: actionOrder ?? this.actionOrder,
    hiddenActions: hiddenActions ?? this.hiddenActions,
    showGroupLabels: showGroupLabels ?? this.showGroupLabels,
  );

  /// 某条 dock 里已登记的分组顺序（不含默认补齐）。
  List<String> dockGroups(String dock) => docks[dock] ?? const <String>[];

  /// [gid] 当前停靠的 dock（未登记默认顶部）。
  String dockOfGroup(String gid) {
    for (final dock in EditorToolbarDocks.all) {
      if ((docks[dock] ?? const <String>[]).contains(gid)) return dock;
    }
    return EditorToolbarDocks.top;
  }

  /// 某条 dock 的完整分组顺序：已登记的在前，默认归属顶部、未在任何
  /// dock 登记的分组按默认顺序补在顶部末尾。
  List<String> groupsInDock(String dock, List<String> defaultGroupIds) {
    final result = (docks[dock] ?? const <String>[])
        .where(defaultGroupIds.contains)
        .toList();
    if (dock == EditorToolbarDocks.top) {
      final placed = <String>{
        for (final d in EditorToolbarDocks.all) ...(docks[d] ?? const []),
      };
      for (final gid in defaultGroupIds) {
        if (!placed.contains(gid) && !result.contains(gid)) result.add(gid);
      }
    }
    return result;
  }

  /// 全部分组的展示顺序（菜单行与自定义对话框用）：按
  /// top→bottom→left→right 拼接，未登记的分组按默认顺序补在末尾。
  List<String> orderedGroupIds(List<String> defaultGroupIds) {
    final result = <String>[];
    for (final dock in EditorToolbarDocks.all) {
      for (final gid in groupsInDock(dock, defaultGroupIds)) {
        if (!result.contains(gid)) result.add(gid);
      }
    }
    for (final gid in defaultGroupIds) {
      if (!result.contains(gid)) result.add(gid);
    }
    return result;
  }

  /// 组内动作排序，口径同上：已登记的在前，未登记的按定义顺序追加。
  List<String> orderedActionIds(String groupId, List<String> defaultIds) {
    final saved = actionOrder[groupId] ?? const <String>[];
    final known = saved.where(defaultIds.contains).toList();
    for (final id in defaultIds) {
      if (!known.contains(id)) known.add(id);
    }
    return known;
  }

  /// 把分组 [gid] 移到 [dock] 里 [beforeGid] 之前（null = 追加到末尾）。
  /// [currentDocksFull] 是调用方按定义补齐默认分组后的各 dock 完整顺序
  ///（未登记分组隐式在顶部，直接改登记表会丢掉它们的相对位置）。
  EditorToolbarSettings withGroupMoved(
    String gid,
    String dock,
    String? beforeGid, {
    required Map<String, List<String>> currentDocksFull,
  }) {
    final next = <String, List<String>>{
      for (final d in EditorToolbarDocks.all)
        d: List<String>.of(currentDocksFull[d] ?? const <String>[]),
    };
    for (final d in EditorToolbarDocks.all) {
      next[d]!.remove(gid);
    }
    final list = next[dock]!;
    final i = beforeGid == null ? list.length : list.indexOf(beforeGid);
    list.insert(i < 0 ? list.length : i, gid);
    return copyWith(docks: next);
  }

  /// 组内动作重排（自定义对话框上下移用）。
  EditorToolbarSettings withActionOrder(String groupId, List<String> order) {
    final next = Map<String, List<String>>.of(actionOrder);
    next[groupId] = List<String>.unmodifiable(order);
    return copyWith(actionOrder: next);
  }

  /// 把动作 [aid] 从 [fromGroup] 移到 [toGroup] 里 [beforeAid] 之前
  /// （null = 追加）。跨组拖拽与同组重排共用。
  EditorToolbarSettings withActionMoved(
    String aid,
    String fromGroup,
    String toGroup,
    String? beforeAid, {
    required List<String> fromOrder,
    required List<String> toOrder,
  }) {
    final from = List<String>.of(fromOrder);
    final to = fromGroup == toGroup ? from : List<String>.of(toOrder);
    from.remove(aid);
    to.remove(aid);
    final i = beforeAid == null ? to.length : to.indexOf(beforeAid);
    to.insert(i < 0 ? to.length : i, aid);
    final next = Map<String, List<String>>.of(actionOrder);
    if (fromGroup == toGroup) {
      next[toGroup] = List<String>.unmodifiable(to);
    } else {
      next[fromGroup] = List<String>.unmodifiable(from);
      next[toGroup] = List<String>.unmodifiable(to);
    }
    return copyWith(actionOrder: next);
  }

  EditorToolbarSettings withGroupHidden(String groupId, bool hidden) {
    final next = Set<String>.of(hiddenGroups);
    hidden ? next.add(groupId) : next.remove(groupId);
    return copyWith(hiddenGroups: next);
  }

  EditorToolbarSettings withActionHidden(String actionId, bool hidden) {
    final next = Set<String>.of(hiddenActions);
    hidden ? next.add(actionId) : next.remove(actionId);
    return copyWith(hiddenActions: next);
  }

  EditorToolbarSettings withShowGroupLabels(bool value) =>
      copyWith(showGroupLabels: value);
}
