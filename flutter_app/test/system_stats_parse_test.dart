// /process_stats 的 system 块（整机口径）解析。跨语言格式基准在
// python_service/api_base.py 的 _system_stats；本测试锁住 Dart 侧镜像
// 解析的容错行为（缺块/缺字段/数值类型漂移）。
import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/services/python_service.dart';

void main() {
  test('完整 system 块解析（含 nvidia-smi 三值）', () {
    final stats = ServiceStats.fromJson({
      'available': true,
      'cpu_percent': 12.5,
      'memory_bytes': 123456789,
      'vram_bytes': 2345678,
      'workers': {'total': 4, 'ready': 2},
      'system': {
        'cpu_percent': 33.3,
        'memory_used_bytes': 1234500000,
        'memory_total_bytes': 3400000000,
        'gpu_util_percent': 45,
        'vram_used_bytes': 6668000000,
        'vram_total_bytes': 1288000000,
      },
    });
    expect(stats.cpuPercent, 12.5);
    expect(stats.workersTotal, 4);
    final sys = stats.system;
    expect(sys, isNotNull);
    expect(sys!.cpuPercent, 33.3);
    expect(sys.memoryUsedBytes, 1234500000);
    expect(sys.memoryTotalBytes, 3400000000);
    expect(sys.memoryRatio, closeTo(0.363, 0.001));
    // JSON 里的整数 45 要能当 double 读。
    expect(sys.gpuUtilPercent, 45.0);
    expect(sys.vramUsedBytes, 6668000000);
    expect(sys.vramTotalBytes, 1288000000);
    expect(sys.vramRatio, closeTo(5.17, 0.01));
  });

  test('旧版后端：无 system 块时为 null，进程树字段照常解析', () {
    final stats = ServiceStats.fromJson({
      'available': true,
      'cpu_percent': 5,
      'memory_bytes': 1000,
    });
    expect(stats.system, isNull);
    expect(stats.cpuPercent, 5.0);
    expect(stats.vramBytes, isNull);
    expect(stats.workersTotal, isNull);
  });

  test('无 N 卡：system 块 GPU 三值缺失为 null，比率不抛异常', () {
    final stats = ServiceStats.fromJson({
      'available': true,
      'cpu_percent': 1,
      'memory_bytes': 1,
      'system': {
        'cpu_percent': 10,
        'memory_used_bytes': 100,
        'memory_total_bytes': 200,
      },
    });
    final sys = stats.system!;
    expect(sys.gpuUtilPercent, isNull);
    expect(sys.vramUsedBytes, isNull);
    expect(sys.vramTotalBytes, isNull);
    expect(sys.vramRatio, isNull);
    // 内存比率仍可算。
    expect(sys.memoryRatio, 0.5);
  });

  test('system 为非 Map 值（异常负载）不炸，按缺失处理', () {
    final stats = ServiceStats.fromJson({
      'available': true,
      'cpu_percent': 1,
      'memory_bytes': 1,
      'system': 'oops',
    });
    expect(stats.system, isNull);
  });
}
