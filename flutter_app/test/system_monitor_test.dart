// SystemMonitor 的历史缓冲与失败处理。fetch 注入缝替换为假实现，不碰
// 真实 HTTP；只驱动 poll()，不起 Timer。
import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/services/python_service.dart';
import 'package:gujichazi/services/system_monitor.dart';

ServiceStats _stats({
  double cpu = 10,
  double memRatio = 0.5,
  double? gpuUtil,
  double? vramRatio,
}) {
  return ServiceStats(
    cpuPercent: 0,
    memoryBytes: 0,
    system: SystemStats(
      cpuPercent: cpu,
      memoryUsedBytes: (memRatio * 100).round(),
      memoryTotalBytes: 100,
      gpuUtilPercent: gpuUtil,
      vramUsedBytes: vramRatio == null ? null : (vramRatio * 100).round(),
      vramTotalBytes: vramRatio == null ? null : 100,
    ),
  );
}

void main() {
  late SystemMonitor monitor;
  late Future<ServiceStats?> Function() originalFetch;

  setUp(() {
    monitor = SystemMonitor.instance;
    monitor.debugReset();
    originalFetch = SystemMonitor.fetch;
  });

  tearDown(() {
    SystemMonitor.fetch = originalFetch;
    monitor.debugReset();
  });

  test('poll 追加四条历史（百分比换算）', () async {
    SystemMonitor.fetch = () async => _stats(
          cpu: 33,
          memRatio: 0.6,
          gpuUtil: 45,
          vramRatio: 0.25,
        );
    await monitor.poll();
    expect(monitor.cpuHistory, [33]);
    expect(monitor.memHistory, [60]);
    expect(monitor.gpuHistory, [45]);
    expect(monitor.vramHistory, [25]);
    expect(monitor.missStreak, 0);
    expect(monitor.latest!.system!.cpuPercent, 33);
  });

  test('历史上限裁剪：只留最近 maxHistory 个点', () async {
    var n = 0;
    SystemMonitor.fetch = () async {
      n++;
      return _stats(cpu: n.toDouble(), memRatio: 0.1);
    };
    for (var i = 0; i < SystemMonitor.maxHistory + 7; i++) {
      await monitor.poll();
    }
    expect(monitor.cpuHistory.length, SystemMonitor.maxHistory);
    // 最旧的 7 个点被裁掉，首值应为 8。
    expect(monitor.cpuHistory.first, 8);
    expect(monitor.cpuHistory.last, SystemMonitor.maxHistory + 7);
  });

  test('超界值钳到 0~100（曲线归一前提）', () async {
    SystemMonitor.fetch = () async => _stats(cpu: 150, memRatio: 0.0);
    await monitor.poll();
    expect(monitor.cpuHistory.single, 100);
    expect(monitor.memHistory.single, 0);
  });

  test('无 N 卡：显存/GPU 历史保持为空（空曲线 = 不可用）', () async {
    SystemMonitor.fetch = () async => _stats(cpu: 5, memRatio: 0.2);
    await monitor.poll();
    await monitor.poll();
    expect(monitor.cpuHistory.length, 2);
    expect(monitor.vramHistory, isEmpty);
    expect(monitor.gpuHistory, isEmpty);
  });

  test('后端不可达：missStreak 递增，历史与 latest 保留', () async {
    SystemMonitor.fetch = () async => _stats(cpu: 20, memRatio: 0.3);
    await monitor.poll();
    SystemMonitor.fetch = () async => null;
    await monitor.poll();
    await monitor.poll();
    expect(monitor.missStreak, 2);
    expect(monitor.cpuHistory, [20]); // 断连期间曲线不动
    expect(monitor.latest!.system!.cpuPercent, 20);
  });

  test('start/stop 幂等且 start 立即先采一次', () async {
    var calls = 0;
    SystemMonitor.fetch = () async {
      calls++;
      return _stats(cpu: 1, memRatio: 0.1);
    };
    monitor.start();
    monitor.start(); // 幂等：不重复起 Timer
    expect(monitor.isRunning, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(calls, 1); // 立即的一次已发出
    monitor.stop();
    expect(monitor.isRunning, isFalse);
  });
}
