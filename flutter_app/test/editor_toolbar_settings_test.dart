import 'dart:convert';

import 'package:gujichazi/services/editor_toolbar_settings.dart';
import 'package:gujichazi/widgets/editor_command_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('EditorToolbarSettings JSON 往返', () {
    test('默认值 → JSON → 对象，字段一致', () {
      final back = EditorToolbarSettings.fromJson(
        Map<String, dynamic>.from(
          const EditorToolbarSettings().toJson(),
        ),
      );
      expect(back.docks, isEmpty);
      expect(back.hiddenGroups, isEmpty);
      expect(back.hiddenActions, isEmpty);
      expect(back.actionOrder, isEmpty);
      expect(back.showGroupLabels, isTrue);
    });

    test('完整自定义布局（多 dock）往返不丢字段', () {
      final s = const EditorToolbarSettings().copyWith(
        docks: {
          'top': ['page'],
          'left': ['book'],
        },
        hiddenGroups: {'ai'},
        hiddenActions: {'show_index'},
        actionOrder: {
          'page': ['delete_page', 'straighten'],
        },
        showGroupLabels: false,
      );
      final back = EditorToolbarSettings.fromJson(
        Map<String, dynamic>.from(s.toJson()),
      );
      expect(back.docks['top'], ['page']);
      expect(back.docks['left'], ['book']);
      expect(back.hiddenGroups, {'ai'});
      expect(back.hiddenActions, {'show_index'});
      expect(back.actionOrder['page'], ['delete_page', 'straighten']);
      expect(back.showGroupLabels, isFalse);
    });

    test('脏数据（类型不对）回退默认，不抛异常', () {
      final back = EditorToolbarSettings.fromJson({
        'docks': 'oops',
        'showGroupLabels': 'yes',
        'hiddenGroups': [1, 2],
      });
      expect(back.docks, isEmpty);
      expect(back.showGroupLabels, isTrue);
      expect(back.hiddenGroups, isEmpty);
    });

    test('load/save 走 SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({});
      await const EditorToolbarSettings()
          .withGroupHidden('ai', true)
          .save();
      final loaded = await EditorToolbarSettings.load();
      expect(loaded.hiddenGroups, {'ai'});
    });

    test('v1 布局（单一顺序）自动迁移为顶部 dock', () async {
      SharedPreferences.setMockInitialValues({
        'editor_toolbar_settings_v1': jsonEncode({
          'groupOrder': ['export', 'page'],
          'hiddenGroups': ['book'],
          'actionOrder': {
            'page': ['delete_page'],
          },
          'hiddenActions': ['show_index'],
          'showGroupLabels': false,
        }),
      });
      final loaded = await EditorToolbarSettings.load();
      expect(loaded.docks['top'], ['export', 'page']);
      expect(loaded.hiddenGroups, {'book'});
      expect(loaded.actionOrder['page'], ['delete_page']);
      expect(loaded.showGroupLabels, isFalse);
    });
  });

  group('dock 归属与排序口径', () {
    test('未登记的分组默认归顶部（按默认顺序追加在登记项之后）', () {
      const s = EditorToolbarSettings(docks: {
        'top': ['export'],
      });
      expect(
        s.groupsInDock('top', ['page', 'view', 'export']),
        ['export', 'page', 'view'],
      );
      expect(s.groupsInDock('left', ['page']), isEmpty);
      expect(s.dockOfGroup('export'), 'top');
      expect(s.dockOfGroup('page'), 'top');
    });

    test('orderedGroupIds 按 top→bottom→left→right 拼接', () {
      final s = const EditorToolbarSettings().withGroupMoved(
        'view',
        'left',
        null,
        currentDocksFull: {
          for (final d in EditorToolbarDocks.all)
            d: d == 'top' ? ['page', 'view', 'book'] : <String>[],
        },
      );
      expect(s.orderedGroupIds(['page', 'view', 'book']), [
        'page',
        'book',
        'view',
      ]);
      expect(s.dockOfGroup('view'), 'left');
    });

    test('orderedActionIds：登记的在前，未登记的按定义顺序追加', () {
      const s = EditorToolbarSettings(
        actionOrder: {'save': ['save_confirm']},
      );
      expect(
        s.orderedActionIds('save', [
          'save_draft',
          'save_confirm',
          'save_boxes',
        ]),
        ['save_confirm', 'save_draft', 'save_boxes'],
      );
      expect(s.orderedActionIds('page', ['a', 'b']), ['a', 'b']);
    });
  });

  group('移动 API（拖拽落盘用）', () {
    test('withGroupMoved：跨 dock 移动 + 栏内重排', () {
      const full = {
        'top': ['page', 'book'],
        'bottom': <String>[],
        'left': <String>[],
        'right': <String>[],
      };
      final moved = const EditorToolbarSettings().withGroupMoved(
        'book',
        'left',
        null,
        currentDocksFull: full,
      );
      expect(moved.dockOfGroup('book'), 'left');
      expect(moved.docks['top'], ['page']);
      expect(moved.docks['left'], ['book']);

      // 把 view 移到 page 之前（同栏重排，beforeGid 语义）。
      final before = moved.withGroupMoved(
        'view',
        'top',
        'page',
        currentDocksFull: {
          'top': ['page', 'export', 'view'],
          'bottom': <String>[],
          'left': ['book'],
          'right': <String>[],
        },
      );
      expect(before.docks['top'], ['view', 'page', 'export']);
    });

    test('withActionMoved：跨组移动带完整顺序，不丢组内其他动作', () {
      final moved = const EditorToolbarSettings().withActionMoved(
        'a2',
        'g1',
        'g2',
        'b1',
        fromOrder: ['a1', 'a2', 'a3'],
        toOrder: ['b1', 'b2'],
      );
      expect(moved.actionOrder['g1'], ['a1', 'a3']);
      expect(moved.actionOrder['g2'], ['a2', 'b1', 'b2']);
    });

    test('withActionMoved：同组重排（拖到自己组内新位置）', () {
      final moved = const EditorToolbarSettings().withActionMoved(
        'a1',
        'g1',
        'g1',
        null,
        fromOrder: ['a1', 'a2', 'a3'],
        toOrder: ['a1', 'a2', 'a3'],
      );
      expect(moved.actionOrder['g1'], ['a2', 'a3', 'a1']);
    });
  });

  group('applyToolbarLayout', () {
    List<EditorActionGroup> defs() => [
      EditorActionGroup(
        id: 'g1',
        label: '组一',
        actions: [
          EditorAction(id: 'a1', label: '一', icon: Icons.home, tooltip: ''),
          EditorAction(
            id: 'a2',
            label: '二',
            icon: Icons.home,
            tooltip: '',
            visible: false,
          ),
        ],
      ),
      EditorActionGroup(
        id: 'g2',
        label: '组二',
        actions: [
          EditorAction(id: 'b1', label: '乙', icon: Icons.home, tooltip: ''),
        ],
      ),
    ];

    test('默认布局：全部组在顶部（不可见动作被过滤）', () {
      final out = applyToolbarLayout(const EditorToolbarSettings(), defs());
      expect(out['top']!.map((g) => g.id), ['g1', 'g2']);
      expect(out['top']![0].actions.map((a) => a.id), ['a1']);
      expect(out['left'], isEmpty);
    });

    test('分组停靠不同 dock + 隐藏组生效', () {
      final s = const EditorToolbarSettings().withGroupMoved(
        'g2',
        'bottom',
        null,
        currentDocksFull: {
          'top': ['g1', 'g2'],
          'bottom': <String>[],
          'left': <String>[],
          'right': <String>[],
        },
      ).withGroupHidden('g1', true);
      final out = applyToolbarLayout(s, defs());
      expect(out['top'], isEmpty);
      expect(out['bottom']!.map((g) => g.id), ['g2']);
    });

    test('空栏落点链路：applyActionDrop 拖进空白 dock 后在新栏渲染', () {
      // 与控制器同一实现（applyActionDrop）：拖「一」进空白左栏。
      final payload = EditorActionDragPayload(fromGroup: 'g1', actionId: 'a1');
      final next = applyActionDrop(
        const EditorToolbarSettings(),
        defs(),
        payload,
        toGroup: kCustomGroupId,
        dockHint: 'left',
      );
      // 关键区分：动作移入后「自定义」组名下非空（自愈口径已真），
      // 但落点守卫必须看"是否停靠过"——否则登记被跳过、按钮落不到新栏。
      expect(customGroupDocked(next), isTrue);
      final out = applyToolbarLayout(next, defs());
      expect(out['left']!.single.id, kCustomGroupId);
      expect(out['left']!.single.actions.single.id, 'a1');
      expect(out['top']!.map((g) => g.id), ['g2']);
    });

    test('applyActionDrop 守卫：自定义组已停靠在别栏时不再重复登记', () {
      final dockedBottom = const EditorToolbarSettings().withGroupMoved(
        kCustomGroupId,
        'bottom',
        null,
        currentDocksFull: {
          'top': ['g1', 'g2'],
          'bottom': [kCustomGroupId],
          'left': const <String>[],
          'right': const <String>[],
        },
      );
      final next = applyActionDrop(
        dockedBottom,
        defs(),
        const EditorActionDragPayload(fromGroup: 'g1', actionId: 'a1'),
        toGroup: kCustomGroupId,
        dockHint: 'left', // 占位框给了 left，但自定义组已在 bottom。
      );
      expect(next.docks['bottom'], [kCustomGroupId]);
      expect(next.docks['left'] ?? const [], isEmpty);
      expect(next.actionOrder[kCustomGroupId], contains('a1'));
    });

    test('自愈：修复前拖丢的按钮（只有 actionOrder 登记）重新按顶部渲染', () {
      // 修复前的坏数据：动作登记进了「自定义」组但组没登记进任何 dock。
      final broken = const EditorToolbarSettings(
        actionOrder: {
          kCustomGroupId: ['a1'],
        },
      );
      final out = applyToolbarLayout(broken, defs());
      // 未登记 dock 的分组默认按顶部补齐——按钮找回来了（可再拖走）。
      expect(out['top']!.map((g) => g.id), contains(kCustomGroupId));
      final custom = out['top']!.firstWhere((g) => g.id == kCustomGroupId);
      expect(custom.actions.single.id, 'a1');
    });

    test('「自定义」组：拖入的动作经 actionOrder 登记后可解析渲染', () {
      final s = const EditorToolbarSettings(
        docks: {'left': [kCustomGroupId]},
        actionOrder: {
          kCustomGroupId: ['a1'],
        },
      );
      final out = applyToolbarLayout(s, defs());
      expect(out['left']!.single.id, kCustomGroupId);
      expect(out['left']!.single.actions.single.id, 'a1');
      // 顶部还剩 g2（g1 的可见动作 a1 被拖去了「自定义」，g1 整组隐去）。
      expect(out['top']!.map((g) => g.id), ['g2']);
    });
  });
}
