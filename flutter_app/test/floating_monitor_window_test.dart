// 悬浮窗挂载冒烟：MaterialApp.builder 的 Stack 顶层没有 Overlay/Material
// 祖源——v76 首版在此环境下悬停按钮即抛 "No Overlay widget found" 启动
// 崩溃（IconButton 的 tooltip 包 Tooltip，气泡要插最近的 Overlay）。此
// 用例锁住该回归：渲染 + 鼠标悬停出现气泡 + 队列空闲态文案。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/services/system_monitor.dart';
import 'package:gujichazi/widgets/floating_monitor_window.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host() => MaterialApp(
      // 与 main.dart 相同的接线方式（窗口在 Navigator 之外）。
      builder: (context, child) => Stack(
        fit: StackFit.expand,
        children: [child!, const FloatingMonitorWindow()],
      ),
      home: const Scaffold(body: Center(child: Text('首页'))),
    );

void main() {
  testWidgets('builder Stack（无 Overlay 祖源）中渲染与悬停不崩', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final originalFetch = SystemMonitor.fetch;
    SystemMonitor.fetch = () async => null; // 不碰真实 HTTP
    addTearDown(() {
      SystemMonitor.fetch = originalFetch;
      SystemMonitor.instance.debugReset();
    });

    await tester.pumpWidget(_host());
    // 等 _restore（SharedPreferences 异步）与首轮 poll 完成。
    await tester.pumpAndSettle();
    expect(find.text('识别监控'), findsOneWidget);
    expect(
      find.text('队列空闲 · 可在首页开始整本识别，或主区快设批量拆分'),
      findsOneWidget,
    );
    expect(find.text('连接后端失败，自动重试中…'), findsOneWidget);

    // 悬停关闭按钮：修复前这里抛 "No Overlay widget found"。
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    await gesture.moveTo(tester.getCenter(find.byIcon(Icons.close)));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
    // 气泡真的弹出来了——本地 Overlay 在工作。
    expect(find.text('关闭悬浮窗（首页工具栏可重新打开）'), findsOneWidget);

    // 卸载窗口：dispose 应停掉 SystemMonitor 的周期 Timer。
    await gesture.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('隐藏时完全不参与渲染与命中', (tester) async {
    SharedPreferences.setMockInitialValues({
      'monitorWindow.visible': false,
    });
    final originalFetch = SystemMonitor.fetch;
    SystemMonitor.fetch = () async => null;
    addTearDown(() {
      SystemMonitor.fetch = originalFetch;
      SystemMonitor.instance.debugReset();
      FloatingMonitorWindow.visible.value = true;
    });

    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    expect(find.text('识别监控'), findsNothing);
    expect(SystemMonitor.instance.isRunning, isFalse); // 隐藏即停轮询

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
