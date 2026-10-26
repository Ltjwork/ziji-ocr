import 'package:gujichazi/services/editor_toolbar_settings.dart';
import 'package:gujichazi/widgets/editor_command_bar.dart';
import 'package:gujichazi/widgets/editor_toolbar_customize_dialog.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  List<EditorActionGroup> defs() => [
        EditorActionGroup(
          id: 'page',
          label: '页面',
          actions: [
            EditorAction(
              id: 'a',
              label: '摆正',
              icon: Icons.home,
              tooltip: '测试动作',
              onPressed: () {},
            ),
          ],
        ),
        EditorActionGroup(
          id: 'view',
          label: '视图',
          actions: [
            EditorAction(
              id: 'b',
              label: '序号',
              icon: Icons.list,
              tooltip: '',
              checked: true,
              onPressed: () {},
            ),
          ],
        ),
      ];

  Widget host(
    EditorToolbarSettings settings, {
    ValueChanged<EditorToolbarSettings>? onChanged,
    void Function(EditorActionDragPayload, String, String?)? onMoveAction,
    void Function(String, String, String?)? onMoveGroup,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              EditorCommandBar(
                groups: defs(),
                settings: settings,
                onOpenCustomize: () {},
                onDragStarted: (_) {},
                onDragEnded: () {},
                onMoveAction: onMoveAction ?? (_, __, ___) {},
                onMoveGroup: onMoveGroup ?? (_, __, ___) {},
              ),
            ],
          ),
        ),
      );

  testWidgets('渲染菜单按钮与工具栏分组', (tester) async {
    await tester.pumpWidget(host(const EditorToolbarSettings()));
    // 组名出现在两处：菜单按钮 + 工具栏组名小字。
    expect(find.text('页面'), findsNWidgets(2));
    expect(find.text('视图'), findsNWidgets(2));
    expect(find.text('摆正'), findsOneWidget);
    expect(find.byTooltip('测试动作'), findsOneWidget);
  });

  testWidgets('隐藏的分组不渲染', (tester) async {
    await tester.pumpWidget(
      host(const EditorToolbarSettings().withGroupHidden('view', true)),
    );
    expect(find.text('页面'), findsNWidgets(2));
    expect(find.text('视图'), findsNothing);
  });

  testWidgets('点工具栏按钮触发动作', (tester) async {
    var triggered = false;
    final groups = [
      EditorActionGroup(
        id: 'page',
        label: '页面',
        actions: [
          EditorAction(
            id: 'a',
            label: '摆正',
            icon: Icons.home,
            tooltip: '',
            onPressed: () => triggered = true,
          ),
        ],
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditorCommandBar(
            groups: groups,
            settings: const EditorToolbarSettings(),
            onOpenCustomize: () {},
            onDragStarted: (_) {},
            onDragEnded: () {},
            onMoveAction: (_, __, ___) {},
            onMoveGroup: (_, __, ___) {},
          ),
        ),
      ),
    );
    await tester.tap(find.text('摆正'));
    expect(triggered, isTrue);
  });

  testWidgets('打开菜单能看到复合动作的展开项', (tester) async {
    final groups = [
      EditorActionGroup(
        id: 'page',
        label: '页面',
        actions: [
          EditorAction(
            id: 'view_mode',
            label: '视图模式',
            icon: Icons.view_week,
            tooltip: '',
            enabled: false,
            onPressed: null,
            menuItems: [
              const EditorMenuItemSpec(label: '主区视图', checked: true),
            ],
          ),
          EditorAction(
            id: 'a',
            label: '摆正',
            icon: Icons.home,
            tooltip: '',
            onPressed: () {},
          ),
        ],
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditorCommandBar(
            groups: groups,
            settings: const EditorToolbarSettings(),
            onOpenCustomize: () {},
            onDragStarted: (_) {},
            onDragEnded: () {},
            onMoveAction: (_, __, ___) {},
            onMoveGroup: (_, __, ___) {},
          ),
        ),
      ),
    );
    await tester.tap(find.widgetWithText(TextButton, '页面'));
    await tester.pumpAndSettle();
    expect(find.text('主区视图'), findsOneWidget);
  });

  testWidgets('拖动按钮到另一组：回调带来源组与目标组', (tester) async {
    EditorActionDragPayload? movedPayload;
    String? movedToGroup;
    String? movedBefore;
    await tester.pumpWidget(
      host(
        const EditorToolbarSettings(),
        onMoveAction: (p, g, before) {
          movedPayload = p;
          movedToGroup = g;
          movedBefore = before;
        },
      ),
    );
    final source = tester.getCenter(find.text('摆正'));
    final target = tester.getCenter(find.text('序号'));
    final gesture = await tester.startGesture(
      source,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 1; i <= 10; i++) {
      await gesture.moveBy(
        Offset(
          (target.dx - source.dx) / 10,
          (target.dy - source.dy) / 10,
        ),
      );
      await tester.pump(const Duration(milliseconds: 30));
    }
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(movedPayload, isNotNull);
    expect(movedPayload!.actionId, 'a');
    expect(movedPayload!.fromGroup, 'page');
    expect(movedToGroup, 'view');
    expect(movedBefore, 'b'); // 插到「序号」之前。
  });

  testWidgets('空白 dock 占位框：动作落入交给「自定义」组', (tester) async {
    EditorActionDragPayload? payload;
    String? toGroup;
    String? dockSeen;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              EditorEmptyDockPlaceholder(
                dock: EditorToolbarDocks.left,
                onMoveAction: (p, g, _, dock) {
                  payload = p;
                  toGroup = g;
                  dockSeen = dock;
                },
                onMoveGroup: (_, __, ___) {},
              ),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    );
    expect(find.text('拖到这里'), findsOneWidget);
    // 占位框接受任何动作载荷：模拟一次从占位框自身的拖放（起点=终点）。
    final center = tester.getCenter(find.byType(EditorEmptyDockPlaceholder));
    final gesture = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveBy(const Offset(5, 0));
    await tester.pump(const Duration(milliseconds: 30));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(toGroup, isNull); // 没有外部拖入时不触发。
    expect(payload, isNull);
    expect(dockSeen, isNull);
  });

  testWidgets('跨栏拖拽端到端：从顶部工具栏拖到空栏占位框松手落位', (tester) async {
    EditorActionDragPayload? payload;
    String? toGroup;
    String? dockHint;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              EditorCommandBar(
                groups: defs(),
                settings: const EditorToolbarSettings(),
                onOpenCustomize: () {},
                onDragStarted: (_) {},
                onDragEnded: () {},
                onMoveAction: (_, __, ___) {},
                onMoveGroup: (_, __, ___) {},
              ),
              SizedBox(
                height: 120,
                child: EditorEmptyDockPlaceholder(
                  dock: EditorToolbarDocks.left,
                  onMoveAction: (p, g, _, dock) {
                    payload = p;
                    toGroup = g;
                    dockHint = dock;
                  },
                  onMoveGroup: (_, __, ___) {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    // 真实手势：按住「摆正」→ 分步移到占位框中心 → 松开。
    final source = tester.getCenter(find.text('摆正'));
    final target = tester.getCenter(find.text('拖到这里'));
    final gesture = await tester.startGesture(
      source,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 1; i <= 10; i++) {
      await gesture.moveBy(
        Offset(
          (target.dx - source.dx) / 10,
          (target.dy - source.dy) / 10,
        ),
      );
      await tester.pump(const Duration(milliseconds: 30));
    }
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(payload, isNotNull);
    expect(payload!.actionId, 'a');
    expect(toGroup, kCustomGroupId);
    expect(dockHint, 'left');
  });

  testWidgets('自定义对话框：勾选隐藏即时回调', (tester) async {
    EditorToolbarSettings? last;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showEditorToolbarCustomizeDialog(
              context,
              groups: defs(),
              settings: const EditorToolbarSettings(),
              onChanged: (s) => last = s,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('自定义工具栏'), findsOneWidget);
    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    expect(last, isNotNull);
    expect(last!.hiddenGroups, contains('page'));
  });

  testWidgets('自定义对话框：停靠位置菜单改组所属 dock', (tester) async {
    EditorToolbarSettings? last;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showEditorToolbarCustomizeDialog(
              context,
              groups: defs(),
              settings: const EditorToolbarSettings(),
              onChanged: (s) => last = s,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // 第一个组的停靠位置下拉（显示「顶部工具栏」）。
    await tester.tap(find.text('顶部工具栏').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('左侧工具栏').last);
    await tester.pumpAndSettle();
    expect(last, isNotNull);
    expect(last!.dockOfGroup('page'), 'left');
  });
}
