import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'pages/ai_box_test_page.dart';
import 'pages/home_page.dart';
import 'pages/setup_page.dart';
import 'services/plugin_host/plugin_runtime.dart';
import 'services/prefs_migration.dart';
import 'services/python_service.dart';
import 'services/update_service.dart';
import 'widgets/floating_monitor_window.dart';
import 'widgets/startup_update_prompt.dart';

/// 诊断钩子：环境变量 `OCR_AI_BOX_AUTOTEST=<图片路径>` 启动 → 服务就绪后
/// 直接进「AI 画框测试」页并自动执行一次（复现"应用消失"用；直接跑 exe
/// 可拿到进程退出码，flutter run 看不到）。`OCR_AI_BOX_AUTOTEST_PIPELINE=1`
/// 再追加一次管线对比（关 AI 裁决，不依赖外部网关）。正常启动不设变量，
/// 行为不变。
final String? _kAiBoxAutotestImage =
    Platform.environment['OCR_AI_BOX_AUTOTEST'];
final bool _kAiBoxAutotestPipeline =
    Platform.environment['OCR_AI_BOX_AUTOTEST_PIPELINE'] == '1';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // GitHub 更新检查不等待后端或首屏；用户可在「设置 → 关于 / 更新」查看结果。
  unawaited(UpdateService.instance.initializeAndCheck());
  // +103 更名（ProductName flutter_app → 字迹）把 SharedPreferences 的
  // 存储目录整个换新，旧设置留在旧目录：先迁入再 runApp，任何页面首次
  // 读到的都是迁移后的值。
  await migrateLegacyPrefs();
  // 外挂插件宿主：扫描已安装插件并按开关启动后台运行时（无插件时空转，
  // 不阻塞启动；WebView2 缺失只记日志）。
  unawaited(PluginHost.instance.load());
  // 崩溃排查：未捕获异常落 app_console.log。原生层崩溃看不到 Dart 栈，
  // 但"应用闪退 = Dart 层未捕获异常"这一可能必须先证实或排除。
  // 崩溃栈走 writeCrashLineSync 同步落盘——异步日志链在进程死亡时会
  // 丢掉最后一段日志（排障时崩溃栈正是这么丢的）。
  final defaultFlutterErrorHandler = FlutterError.onError;
  FlutterError.onError = (details) {
    defaultFlutterErrorHandler?.call(details);
    final text =
        '未捕获 Flutter 异常：${details.exceptionAsString()}'
        '${details.stack == null ? '' : '\n${details.stack}'}';
    PythonService.addAppLog(text, isError: true);
    PythonService.writeCrashLineSync(text);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    final text = '未捕获异步异常：$error\n$stack';
    PythonService.addAppLog(text, isError: true);
    PythonService.writeCrashLineSync(text);
    return true;
  };
  runApp(const App());
}

class App extends StatefulWidget {
  const App({super.key});

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  bool _serviceReady = false;
  bool _starting = false;
  bool _resolving = true;
  String? _error;
  String? _serviceDir;

  @override
  void initState() {
    super.initState();
    // 插件宿主开页需要一个全局 Navigator（运行时 ui.openPage 用）。
    PluginHost.instance.navigatorKey = _navigatorKey;
    _resolveServiceDir();
  }

  Future<void> _resolveServiceDir() async {
    final candidates = _serviceDirCandidates();
    for (final c in candidates) {
      if (await File(p.join(c, 'main.py')).exists()) {
        setState(() {
          _serviceDir = p.canonicalize(c);
          _resolving = false;
        });
        if (_kAiBoxAutotestImage != null) unawaited(_startService());
        return;
      }
    }
    setState(() {
      _error = 'python_service/main.py not found';
      _resolving = false;
    });
  }

  List<String> _serviceDirCandidates() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final roots = <String>{
      Directory.current.path,
      exeDir,
      p.dirname(Platform.script.toFilePath(windows: Platform.isWindows)),
    };

    return roots
        .expand(_ancestorDirectories)
        .map((root) => p.join(root, 'python_service'))
        .toSet()
        .toList();
  }

  Iterable<String> _ancestorDirectories(String start) sync* {
    var current = p.canonicalize(start);
    while (true) {
      yield current;
      final parent = p.dirname(current);
      if (parent == current) break;
      current = parent;
    }
  }

  Future<void> _startService() async {
    final serviceDir = _serviceDir;
    if (serviceDir == null || _starting) return;
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      // 后端默认直接运行在独立控制台窗口里（ComfyUI 式，start() 内部
      // 处理；开关在主页工具栏）。就绪检测走 health 轮询，与窗口无关。
      await PythonService.start(serviceDir);
      setState(() => _serviceReady = true);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  void dispose() {
    PythonService.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: '字迹',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      // 识别监控悬浮窗挂在 Navigator 之上的全局 Stack 顶层：任何页面、
      // 对话框、编辑器浮层之上都可见（窗口自身隐藏时是 SizedBox，不占
      // 命中区域）。插件隐藏运行时层同挂此处（1×1 透明区域承载启用
      // 插件的常驻 WebView）。
      builder: (context, child) => StartupUpdatePrompt(
        updates: UpdateService.instance,
        navigatorKey: _navigatorKey,
        child: Stack(
          fit: StackFit.expand,
          children: [
            child!,
            const FloatingMonitorWindow(),
            const PluginRuntimeLayer(),
          ],
        ),
      ),
      home: _buildHome(),
    );
  }

  Widget _buildHome() {
    if (_serviceReady) {
      if (_kAiBoxAutotestImage != null) {
        return AiBoxTestPage(
          initialImagePath: _kAiBoxAutotestImage,
          autoRun: true,
          autoRunPipeline: _kAiBoxAutotestPipeline,
        );
      }
      return const HomePage();
    }
    if (_resolving) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('正在定位 python_service 目录...'),
            ],
          ),
        ),
      );
    }
    return SetupPage(
      serviceDir: _serviceDir,
      error: _error,
      onStart: _startService,
    );
  }
}
