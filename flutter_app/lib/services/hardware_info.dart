import 'dart:io';

/// 本机硬件摘要（「AI 辅助设置 → 模型安装」的推荐依据）。
/// 探测失败时各字段给安全缺省（0/空），推荐逻辑按保守档位兜底，
/// 因此这里不抛异常、不阻塞设置页。
class HardwareInfo {
  const HardwareInfo({
    required this.hasNvidiaGpu,
    required this.gpuName,
    required this.vramTotalMb,
    required this.ramTotalMb,
    required this.cpuCores,
  });

  static const HardwareInfo unknown = HardwareInfo(
    hasNvidiaGpu: false,
    gpuName: '',
    vramTotalMb: 0,
    ramTotalMb: 0,
    cpuCores: 0,
  );

  /// 是否检测到 NVIDIA 独显（Ollama 的 CUDA 加速只认 N 卡；
  /// A/I 卡与核显在 Windows 上按 CPU 推理档位评估）。
  final bool hasNvidiaGpu;

  /// 显卡名（如 NVIDIA GeForce RTX 4070），无卡时为空串。
  final String gpuName;

  /// 显存总量（MiB，所有卡中最大的一块）。
  final int vramTotalMb;

  /// 物理内存总量（MiB），探测失败为 0。
  final int ramTotalMb;

  /// 逻辑 CPU 核数。
  final int cpuCores;

  HardwareInfo copyWith({
    bool? hasNvidiaGpu,
    String? gpuName,
    int? vramTotalMb,
    int? ramTotalMb,
    int? cpuCores,
  }) => HardwareInfo(
    hasNvidiaGpu: hasNvidiaGpu ?? this.hasNvidiaGpu,
    gpuName: gpuName ?? this.gpuName,
    vramTotalMb: vramTotalMb ?? this.vramTotalMb,
    ramTotalMb: ramTotalMb ?? this.ramTotalMb,
    cpuCores: cpuCores ?? this.cpuCores,
  );
}

/// 硬件探测：结果进程级缓存（子进程探测要 1~2 秒，设置页反复进出
/// 不应重复跑），[force] 为 true 时重测（「刷新」按钮）。
class HardwareDetector {
  static HardwareInfo? _cache;
  static Future<HardwareInfo>? _pending;

  static Future<HardwareInfo> detect({bool force = false}) {
    if (!force) {
      final cached = _cache;
      if (cached != null) return Future.value(cached);
    }
    // 并发调用合并成同一次探测。
    return _pending ??= _detect().then((info) {
      _cache = info;
      _pending = null;
      return info;
    }, onError: (Object e) {
      _pending = null;
      // 探测管线自身出错也返回安全缺省，绝不让设置页崩掉。
      return HardwareInfo.unknown.copyWith(cpuCores: Platform.numberOfProcessors);
    });
  }

  static Future<HardwareInfo> _detect() async {
    final gpu = await _detectGpu();
    final ram = await _detectRam();
    return HardwareInfo(
      hasNvidiaGpu: gpu.vramTotalMb > 0,
      gpuName: gpu.gpuName,
      vramTotalMb: gpu.vramTotalMb,
      ramTotalMb: ram,
      cpuCores: Platform.numberOfProcessors,
    );
  }

  static const Duration _probeTimeout = Duration(seconds: 10);

  /// nvidia-smi 查询显卡名与显存总量。多卡时取显存最大的一张
  /// （推荐按最够用的卡评估）。不可用/超时返回空结果（视为无 N 卡）。
  static Future<({String gpuName, int vramTotalMb})> _detectGpu() async {
    try {
      final r = await Process.run(
        'nvidia-smi',
        ['--query-gpu=name,memory.total', '--format=csv,noheader,nounits'],
        runInShell: true,
      ).timeout(_probeTimeout);
      if (r.exitCode != 0) {
        return (gpuName: '', vramTotalMb: 0);
      }
      String bestName = '';
      var bestVram = 0;
      for (final rawLine in r.stdout.toString().split('\n')) {
        final line = rawLine.trim();
        if (line.isEmpty) continue;
        final idx = line.lastIndexOf(',');
        if (idx <= 0) continue;
        final name = line.substring(0, idx).trim();
        final vram = int.tryParse(
          line.substring(idx + 1).replaceAll(RegExp(r'[^0-9]'), ''),
        );
        if (name.isEmpty || vram == null) continue;
        if (vram > bestVram) {
          bestVram = vram;
          bestName = name;
        }
      }
      return (gpuName: bestName, vramTotalMb: bestVram);
    } catch (_) {
      return (gpuName: '', vramTotalMb: 0);
    }
  }

  /// 物理内存总量（MiB）。Windows 优先 PowerShell CIM（wmic 在新版
  /// Win11 已移除），失败再退 wmic；非 Windows 读 /proc/meminfo。
  static Future<int> _detectRam() async {
    if (Platform.isWindows) {
      final ps = await _runOutput('powershell', [
        '-NoProfile',
        '-Command',
        '(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory',
      ]);
      final bytes = int.tryParse(ps.trim());
      if (bytes != null && bytes > 0) return bytes ~/ (1024 * 1024);
      final wmic = await _runOutput('wmic', [
        'ComputerSystem',
        'get',
        'TotalPhysicalMemory',
      ]);
      final match = RegExp(r'(\d{9,})').firstMatch(wmic);
      if (match != null) {
        final bytes = int.tryParse(match.group(1)!);
        if (bytes != null && bytes > 0) return bytes ~/ (1024 * 1024);
      }
      return 0;
    }
    final meminfo = await _runOutput('cat', ['/proc/meminfo']);
    final match = RegExp(r'MemTotal:\s+(\d+)\s+kB').firstMatch(meminfo);
    if (match != null) {
      return (int.tryParse(match.group(1)!) ?? 0) ~/ 1024;
    }
    return 0;
  }

  static Future<String> _runOutput(
    String executable,
    List<String> args,
  ) async {
    try {
      final r = await Process.run(
        executable,
        args,
        runInShell: true,
      ).timeout(_probeTimeout);
      if (r.exitCode != 0) return '';
      return r.stdout.toString();
    } catch (_) {
      return '';
    }
  }
}
