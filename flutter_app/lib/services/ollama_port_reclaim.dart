import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 一条 Windows TCP 端口排除（保留）区间（netsh excludedportrange）。
class ExcludedPortRange {
  const ExcludedPortRange({
    required this.start,
    required this.end,
    this.administered = false,
  });

  final int start;
  final int end;

  /// true = 管理员登记的应用保留（netsh add excludedportrange，输出里带
  /// * 标记）：winnat 不会再把这段动态保留给 Hyper-V/WSL，普通进程可绑定。
  final bool administered;

  bool contains(int port) => port >= start && port <= end;
}

/// 端口体检结果：普通进程能否绑定 + 系统保留区间快照。
class OllamaPortHealth {
  const OllamaPortHealth({
    required this.port,
    required this.bindable,
    this.bindError,
    this.ranges = const [],
  });

  final int port;

  /// 普通进程能否直接 bind 该端口（Ollama 服务端能不能监听的前提）。
  final bool bindable;

  /// bind 失败时的 Windows 错误码：10013（WSAEACCES）= 被 winnat 动态
  /// 保留挡住；10048（WSAEADDRINUSE）= 已被其他程序占用。
  final int? bindError;

  /// 当前的 TCP 端口排除区间（netsh 读取失败/非 Windows 为空）。
  final List<ExcludedPortRange> ranges;

  /// 命中端口的保留区间（没有则 null）。
  ExcludedPortRange? get hitRange {
    for (final r in ranges) {
      if (r.contains(port)) return r;
    }
    return null;
  }

  /// 被系统动态保留挡住且还没有应用保留登记 → 可用「抢回端口」修复。
  bool get reclaimable =>
      !bindable && bindError == 10013 && !(hitRange?.administered ?? false);
}

class OllamaPortReclaimException implements Exception {
  const OllamaPortReclaimException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 「抢回 Ollama 端口」：Windows 上 Hyper-V/WSL 的 winnat 服务开机随机
/// 保留一批 TCP 端口段，可能恰好盖住 Ollama 端口（如 11434），服务端
/// bind 被系统拒绝（server.log 刷 "bind: ... forbidden by its access
/// permissions"），托盘反复拉起也绑不上，端口上无人监听、客户端全被拒。
/// 修复 = 管理员执行：net stop winnat → 把端口登记为应用保留（此后
/// winnat 不再抢占）→ net start winnat；Ollama 检测到端口释放自动重绑。
class OllamaPortReclaim {
  /// Ollama 默认端口。
  static const int defaultOllamaPort = 11434;

  /// bind 被拒的"系统保留"错误码（WSAEACCES）。
  static const int errorAccessDenied = 10013;

  /// bind 被拒的"端口已被占用"错误码（WSAEADDRINUSE）。
  static const int errorInUse = 10048;

  /// 从服务地址提取端口；未写端口按 Ollama 默认 [defaultOllamaPort]。
  static int portFromBaseUrl(String baseUrl) {
    var t = baseUrl.trim();
    if (t.isEmpty) return defaultOllamaPort;
    if (!t.contains('://')) t = 'http://$t';
    final uri = Uri.tryParse(t);
    if (uri == null || !uri.hasPort) return defaultOllamaPort;
    return uri.port;
  }

  /// 体检：试绑定 + 解析系统保留区间。非 Windows 直接返回"可绑定"。
  static Future<OllamaPortHealth> probe(int port) async {
    if (!Platform.isWindows) {
      return OllamaPortHealth(port: port, bindable: true);
    }
    int? bindError;
    ServerSocket? probeSocket;
    try {
      probeSocket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    } on SocketException catch (e) {
      bindError = e.osError?.errorCode;
    } finally {
      try {
        await probeSocket?.close();
      } catch (_) {}
    }
    final ranges = await _excludedRanges();
    return OllamaPortHealth(
      port: port,
      bindable: bindError == null,
      bindError: bindError,
      ranges: ranges,
    );
  }

  /// 解析 `netsh interface ipv4 show excludedportrange protocol=tcp`
  /// 的输出：只收「起始端口 结束端口 [*]」行，表头/分隔线/杂讯忽略。
  static List<ExcludedPortRange> parseExcludedRanges(String output) {
    final result = <ExcludedPortRange>[];
    for (final raw in output.split(RegExp(r'\r?\n'))) {
      final m = _rangeLine.firstMatch(raw);
      if (m == null) continue;
      final start = int.tryParse(m.group(1)!);
      final end = int.tryParse(m.group(2)!);
      if (start == null || end == null || end < start) continue;
      result.add(
        ExcludedPortRange(
          start: start,
          end: end,
          administered: m.group(3) == '*',
        ),
      );
    }
    return result;
  }

  static final RegExp _rangeLine = RegExp(r'^\s*(\d+)\s+(\d+)\s*(\*?)\s*$');

  static Future<List<ExcludedPortRange>> _excludedRanges() async {
    try {
      final r = await Process.run('netsh', [
        'interface',
        'ipv4',
        'show',
        'excludedportrange',
        'protocol=tcp',
      ]).timeout(const Duration(seconds: 10));
      if (r.exitCode != 0) return const [];
      return parseExcludedRanges('${r.stdout}');
    } on Exception {
      return const [];
    }
  }

  /// 执行抢回（弹 UAC 管理员授权）。逐步日志经 [onLog] 回调；授权被
  /// 取消或脚本未跑完抛 [OllamaPortReclaimException]。成功返回后调用方
  /// 应重新 probe 并重测连接（Ollama 数秒内自动重绑）。
  static Future<void> reclaim(
    int port, {
    void Function(String line)? onLog,
  }) async {
    if (!Platform.isWindows) {
      throw const OllamaPortReclaimException('该修复仅支持 Windows。');
    }
    void log(String line) {
      final t = line.trim();
      if (t.isNotEmpty) onLog?.call(t);
    }

    // 提权脚本把 net 命令输出落盘到临时日志（隐藏窗口拿不到 stdout），
    // 结束后由 Dart 读回展示；末尾写 done 哨兵判断脚本是否跑完。
    final logFile = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}gujichazi_port_reclaim.log',
    );
    try {
      if (logFile.existsSync()) logFile.deleteSync();
    } catch (_) {}

    final inner = [
      r"$ErrorActionPreference = 'Continue'",
      "\$log = '${logFile.path.replaceAll("'", "''")}'",
      "'[reclaim] step 1/3: net stop winnat' | Out-File -FilePath \$log -Append -Encoding UTF8",
      'net stop winnat 2>&1 | Out-File -FilePath \$log -Append -Encoding UTF8',
      "'[reclaim] step 2/3: register port $port as app-reserved' | Out-File -FilePath \$log -Append -Encoding UTF8",
      'netsh int ipv4 add excludedportrange protocol=tcp startport=$port numberofports=1 2>&1 | Out-File -FilePath \$log -Append -Encoding UTF8',
      "'[reclaim] step 3/3: net start winnat' | Out-File -FilePath \$log -Append -Encoding UTF8",
      'net start winnat 2>&1 | Out-File -FilePath \$log -Append -Encoding UTF8',
      "'[reclaim] done' | Out-File -FilePath \$log -Append -Encoding UTF8",
    ].join('; ');
    final outer = [
      r"$ErrorActionPreference = 'Stop'",
      "\$p = Start-Process -FilePath 'powershell' -ArgumentList "
          "'-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',"
          "'${_utf16leBase64(inner)}' -Verb RunAs -Wait -PassThru",
      r'exit $p.ExitCode',
    ].join('; ');

    log('[reclaim] 正在请求管理员权限，请在弹出的授权窗口点「是」…');
    int exitCode;
    try {
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        outer,
      ]).timeout(const Duration(seconds: 180));
      exitCode = r.exitCode;
      log('${r.stderr}');
    } on TimeoutException {
      throw const OllamaPortReclaimException('等待管理员执行超时（>180 秒），请重试。');
    }

    var scriptLog = '';
    try {
      if (logFile.existsSync()) {
        scriptLog = logFile.readAsStringSync();
        if (scriptLog.startsWith('\uFEFF')) scriptLog = scriptLog.substring(1);
      }
    } catch (_) {}
    for (final line in scriptLog.split(RegExp(r'\r?\n'))) {
      log(line);
    }

    if (!scriptLog.contains('[reclaim] done')) {
      throw OllamaPortReclaimException(
        exitCode != 0
            ? '管理员授权被取消（或脚本未能运行），端口未做任何改动。'
            : '修复脚本未执行完成（exit=$exitCode），请重试。',
      );
    }
    log('[reclaim] 完成：端口 $port 已登记为应用保留。等待 Ollama 重新绑定…');
  }

  /// PowerShell -EncodedCommand 的 base64（UTF-16LE），同 setup_service
  /// 的既有模式，避免多层引号转义。
  static String _utf16leBase64(String script) => base64Encode(
    script.codeUnits.expand((unit) => [unit & 0xff, unit >> 8]).toList(),
  );
}
