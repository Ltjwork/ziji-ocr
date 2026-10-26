import 'dart:async';

import 'package:flutter/material.dart';

import 'pages/hub_page.dart';
import 'services/python_service.dart';
import 'services/service_dir.dart';

/// 训练器独立窗口（同一 exe 的第二实例，见 main.dart 入口分支）。
///
/// 主窗口保持可用于图书校对，本窗口专职模型训练：训练状态本就住在
/// Python 后端里，两个窗口各自轮询互不干扰。后端生命周期仍归主实例
/// （本实例 PythonService.attach 只连接：不拉起、不关闭、不复活），
/// 主窗口退出会停止后端、训练随之中断——届时本窗口会提示重新打开主应用。
class TrainingWindowApp extends StatefulWidget {
  const TrainingWindowApp({super.key});

  @override
  State<TrainingWindowApp> createState() => _TrainingWindowAppState();
}

class _TrainingWindowAppState extends State<TrainingWindowApp> {
  _Phase _phase = _Phase.resolving;
  String? _serviceDir;
  String _statusLine = '正在定位识别服务目录…';
  Timer? _retryTicker;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _retryTicker?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    setState(() => _phase = _Phase.resolving);
    final dir = await resolveServiceDir();
    if (!mounted) return;
    if (dir == null) {
      setState(() => _phase = _Phase.failed);
      return;
    }
    _serviceDir = dir;
    setState(() => _phase = _Phase.attaching);
    final ok = await PythonService.attach(
      dir,
      onProgress: (line) {
        if (mounted) setState(() => _statusLine = line);
      },
    );
    if (!mounted) return;
    if (ok) {
      setState(() => _phase = _Phase.ready);
    } else {
      setState(() => _phase = _Phase.failed);
      // 端口文件可能稍后才出现（主应用仍在启动后端）：静默重试。
      _retryTicker?.cancel();
      _retryTicker = Timer.periodic(const Duration(seconds: 5), (_) {
        if (mounted && _phase == _Phase.failed) unawaited(_bootstrap());
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '字迹 · 模型训练',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: _buildHome(),
    );
  }

  Widget _buildHome() {
    switch (_phase) {
      case _Phase.resolving:
      case _Phase.attaching:
        return Scaffold(
          appBar: AppBar(title: const Text('模型训练')),
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
                const SizedBox(height: 18),
                Text(
                  _phase == _Phase.resolving
                      ? '正在定位识别服务目录…'
                      : '正在连接识别服务…',
                  style: const TextStyle(fontSize: 13.5),
                ),
                const SizedBox(height: 6),
                Text(
                  _phase == _Phase.attaching
                      ? _statusLine
                      : '训练器窗口不单独启动识别服务',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
        );
      case _Phase.failed:
        return Scaffold(
          appBar: AppBar(title: const Text('模型训练')),
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.link_off, size: 34, color: Colors.orange.shade700),
                const SizedBox(height: 12),
                const Text(
                  '暂时连不上识别服务',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Text(
                    _serviceDir == null
                        ? '没有找到 python_service 目录。训练器窗口请从主应用'
                            '「模型训练」页的独立窗口按钮打开。'
                        : '识别服务由主应用启动与托管（本窗口只连接）。请先打开'
                            '主应用；连上后这里会自动继续，期间每 5 秒重试。',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
                ),
                const SizedBox(height: 14),
                FilledButton.tonalIcon(
                  onPressed: _bootstrap,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('立即重试'),
                ),
              ],
            ),
          ),
        );
      case _Phase.ready:
        return const TrainingHubPage();
    }
  }
}

enum _Phase { resolving, attaching, failed, ready }
