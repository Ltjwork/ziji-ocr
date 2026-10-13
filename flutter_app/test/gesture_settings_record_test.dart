import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/pages/gesture_settings_page.dart';
import 'package:gujichazi/services/mouse_gesture.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 手势录制面板（+97）：点「录制」→ 面板显示动作名 → 中键直接画出手势
/// → 松手即保存（映射立即落库）。模拟鼠标中键拖动验证整条链路。
void main() {
  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: GestureSettingsPage(embedded: true)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('中键画出 L 形（先左后下）→ 松手即保存到对应动作', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await pumpPage(tester);

    // 第一行的录制按钮 = 主区快设「确认并下一页」。
    await tester.tap(
      find.byTooltip('录制：在面板上用中键画出手势').first,
    );
    await tester.pumpAndSettle();

    // 面板显示当前要设置的动作名（背景列表里也有同名行，至少两处）。
    expect(find.text('确认并下一页'), findsWidgets);
    expect(find.text('录制手势'), findsOneWidget);

    // 在绘制区按住中键画 L：先向左、再向下。
    final center = tester.getCenter(find.text('按住中键在这里画…'));
    final gesture = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
      buttons: kMiddleMouseButton,
    );
    await gesture.moveBy(const Offset(-14, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-16, 1));
    await tester.pump();
    await gesture.moveBy(const Offset(1, 15));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 16));
    await gesture.up();
    await tester.pumpAndSettle();

    // 松手即保存：手势目录内的识别结果直接落库。
    final saved = await GestureSettings.load();
    expect(saved.quick['LD'], 'confirmNext');
    // 面板显示识别结果（箭头大字），停留待确认。
    expect(find.text('←↓'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('录制手势'), findsNothing);
  });

  testWidgets('纯点击（无位移）不保存，提示重画', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpPage(tester);

    await tester.tap(
      find.byTooltip('录制：在面板上用中键画出手势').first,
    );
    await tester.pumpAndSettle();

    final center = tester.getCenter(find.text('按住中键在这里画…'));
    final gesture = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
      buttons: kMiddleMouseButton,
    );
    await gesture.moveBy(const Offset(2, 2));
    await gesture.up();
    await tester.pumpAndSettle();

    final saved = await GestureSettings.load();
    // 未新增绑定：仍是默认三条（LD/L/R → confirmNext/prevPage/nextPage）。
    expect(saved.quick.length, GestureSettings.defaultQuick.length);
    expect(saved.quick, GestureSettings.defaultQuick);
    // 面板仍在等待重画（提示文案保留）。
    expect(find.text('按住中键在这里画…'), findsOneWidget);
  });

  testWidgets('三段手势被拒（最多两段），提示重画', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpPage(tester);

    await tester.tap(
      find.byTooltip('录制：在面板上用中键画出手势').first,
    );
    await tester.pumpAndSettle();

    final center = tester.getCenter(find.text('按住中键在这里画…'));
    final gesture = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
      buttons: kMiddleMouseButton,
    );
    // 左 → 下 → 右（三段）。
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    await gesture.moveBy(const Offset(20, 0));
    await gesture.up();
    await tester.pumpAndSettle();

    final saved = await GestureSettings.load();
    expect(saved.quick['LDR'], isNull);
    expect(find.text('按住中键在这里画…'), findsOneWidget); // 停留在重画态
  });
}
