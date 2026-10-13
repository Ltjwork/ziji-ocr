import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/python_service.dart';
import '../widgets/attached_scrollbar.dart';
import '../services/setup_service.dart';

/// 运行环境准备页：分组卡片（基础环境 / 识别服务环境 / Kraken 引擎 / 训练组件）
/// + 状态横幅 + 右侧安装日志。检测走 SetupService 的并行探针与内存缓存，
/// 进页先渲染缓存再后台刷新，只有"重新检测"和安装完成才强制重查。
class SetupPage extends StatefulWidget {
  const SetupPage({
    super.key,
    required this.serviceDir,
    this.error,
    this.standalone = false,
    this.onStart,
  });

  final String? serviceDir;
  final String? error;
  final bool standalone;
  final Future<void> Function()? onStart;

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  SetupSnapshot? _snapshot;
  RuntimeOption? _selectedRuntime;
  bool _useChinaMirror = true;
  bool _checking = true;
  bool _installing = false;
  String _installingLabel = '';
  bool _starting = false;
  final List<String> _logs = [];
  final ScrollController _logScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // 检测过程的每一步都打进安装日志，便于排查"检测不到"类问题
    SetupService.logger = _appendLog;
    // 先渲染缓存（若有），再后台刷新
    final cached = SetupService.cachedSnapshot;
    if (cached != null && cached.serviceDir == widget.serviceDir) {
      _snapshot = cached;
      _selectedRuntime = cached.recommendedRuntime;
      _checking = false;
    }
    _refresh();
  }

  @override
  void didUpdateWidget(covariant SetupPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serviceDir != widget.serviceDir ||
        oldWidget.error != widget.error) {
      _refresh();
    }
  }

  @override
  void dispose() {
    if (SetupService.logger == _appendLog) SetupService.logger = null;
    _logScroll.dispose();
    super.dispose();
  }

  Future<void> _refresh({bool force = false}) async {
    setState(() => _checking = true);
    try {
      final snapshot = await SetupService.inspect(
        widget.serviceDir,
        force: force,
      );
      if (!mounted) return;
      final keep = _selectedRuntime != null &&
          snapshot.options.any((e) => e.id == _selectedRuntime!.id);
      setState(() {
        _snapshot = snapshot;
        _selectedRuntime = keep
            ? snapshot.options.firstWhere(
                (e) => e.id == _selectedRuntime!.id,
              )
            : snapshot.recommendedRuntime;
        _checking = false;
      });
    } catch (e) {
      _appendLog('[ui:error] 环境检测失败: $e');
      if (mounted) setState(() => _checking = false);
    }
  }

  void _appendLog(String line) {
    debugPrint(line);
    if (!mounted) return;
    setState(() => _logs.add(line));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _runInstall(
    String label,
    Future<Process> Function() starter,
  ) async {
    if (_installing) return;
    setState(() {
      _installing = true;
      _installingLabel = label;
      _logs.clear();
      _logs.add('[ui] $label ...');
    });
    try {
      final process = await starter();
      final stdoutDone = process.stdout
          .transform(systemEncoding.decoder)
          .listen(_appendLog)
          .asFuture<void>();
      final stderrDone = process.stderr
          .transform(systemEncoding.decoder)
          .listen(_appendLog)
          .asFuture<void>();
      final exitCode = await process.exitCode;
      await Future.wait([stdoutDone, stderrDone]);
      _appendLog('[ui] $label exit code: $exitCode');
      // conda 可能刚装好/环境刚变化，先失效缓存再强制重查
      SetupService.invalidateCaches();
      await _refresh(force: true);
    } catch (e) {
      _appendLog('[ui:error] $label 失败: $e');
    } finally {
      if (mounted) {
        setState(() {
          _installing = false;
          _installingLabel = '';
        });
      }
    }
  }

  Future<void> _resetServiceEnvironment() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重置识别服务环境'),
        content: const Text(
          '将删除识别服务的 conda 环境并清除残留目录，之后需要重新执行'
          '"安装识别服务环境"。确定继续吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('重置'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _runInstall('重置识别服务环境', () {
      final conda = _snapshot?.condaExecutable ?? '';
      return SetupService.deleteServiceEnvironment(condaExecutable: conda);
    });
  }

  Future<void> _start() async {
    final callback = widget.onStart;
    if (_starting || callback == null) return;
    setState(() => _starting = true);
    try {
      await callback();
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  // ── 构建界面 ──

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final ready = snapshot?.ready ?? false;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Column(
              children: [
                _Header(
                  snapshot: snapshot,
                  checking: _checking,
                  installingLabel: _installingLabel,
                  starting: _starting,
                  canStart: ready && !_installing && widget.onStart != null,
                  onRefresh: () => _refresh(force: true),
                  onStart: _start,
                ),
                // 控制台窗口开关放在启动入口旁：是否以 ComfyUI 式独立控制台
                // 窗口运行后端（关闭则后台静默运行，日志仍落盘可查）。
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: Checkbox(
                          value: PythonService.autoOpenLogConsole(
                            serviceDir: widget.serviceDir,
                          ),
                          onChanged: (v) async {
                            await PythonService.setAutoOpenLogConsole(
                              v ?? true,
                              serviceDir: widget.serviceDir,
                            );
                            if (mounted) setState(() {});
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '在独立控制台窗口运行后端（实时显示启动、端口与识别日志；'
                          '关闭则后台静默运行，日志仍可在主页工具栏查看）',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (widget.error != null && widget.error!.isNotEmpty)
                  _ErrorBanner(message: widget.error!),
                Expanded(
                  child: snapshot == null
                      ? const Center(child: CircularProgressIndicator())
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              flex: 5,
                              child: ListView(
                                padding: const EdgeInsets.only(
                                  left: 16,
                                  top: 4,
                                  bottom: 16,
                                ),
                                children: [
                                  _BasicEnvCard(
                                    snapshot: snapshot,
                                    installing: _installing,
                                    onInstallConda: () =>
                                        _runInstall('安装 Miniconda', () {
                                          return SetupService.installMiniconda();
                                        }),
                                  ),
                                  _ServiceEnvCard(
                                    snapshot: snapshot,
                                    selectedRuntime: _selectedRuntime,
                                    useChinaMirror: _useChinaMirror,
                                    onUseChinaMirrorChanged: (v) =>
                                        setState(() => _useChinaMirror = v),
                                    onRuntimeChanged: (v) => setState(
                                      () => _selectedRuntime = v,
                                    ),
                                    installing: _installing,
                                    onInstall: () =>
                                        _runInstall('安装识别服务环境', () {
                                          return SetupService
                                              .installServiceEnvironment(
                                                runtime: _selectedRuntime!,
                                                serviceDir:
                                                    snapshot.serviceDir ?? '',
                                                useChinaMirror: _useChinaMirror,
                                                condaExecutable:
                                                    snapshot.condaExecutable,
                                              );
                                        }),
                                    onRepairPymupdf: () =>
                                        _runInstall('修复 PDF 组件', () {
                                          return SetupService.installPyMuPDF(
                                            condaExecutable:
                                                snapshot.condaExecutable,
                                            useChinaMirror: _useChinaMirror,
                                          );
                                        }),
                                  ),
                                  _KrakenCard(
                                    snapshot: snapshot,
                                    installing: _installing,
                                    onInstall: () =>
                                        _runInstall('安装 Kraken 识别引擎', () {
                                          return SetupService.installKrakenEngine(
                                            condaExecutable:
                                                snapshot.condaExecutable,
                                            gpuTorch: true,
                                          );
                                        }),
                                  ),
                                  _PaddleCard(
                                    snapshot: snapshot,
                                    installing: _installing,
                                    onInstall: () =>
                                        _runInstall('安装 PaddleOCR 引擎（可选）', () {
                                          return SetupService.installPaddleEngine(
                                            condaExecutable:
                                                snapshot.condaExecutable,
                                            gpuPaddle: snapshot.gpu.available,
                                          );
                                        }),
                                  ),
                                  _TrainingCard(
                                    snapshot: snapshot,
                                    installing: _installing,
                                    selectedRuntime: _selectedRuntime,
                                    onInstall: () =>
                                        _runInstall('安装训练组件', () {
                                          return SetupService.installYolo(
                                            condaExecutable:
                                                snapshot.condaExecutable,
                                            useChinaMirror: _useChinaMirror,
                                          );
                                        }),
                                    onInstallCudaTorch: () =>
                                        _runInstall('安装 CUDA 训练组件', () {
                                          return SetupService.installCudaTorch(
                                            runtime: _selectedRuntime ??
                                                snapshot.recommendedRuntime,
                                            condaExecutable:
                                                snapshot.condaExecutable,
                                          );
                                        }),
                                  ),
                                  _AdvancedCard(
                                    onReset: _resetServiceEnvironment,
                                    installing: _installing,
                                  ),
                                ],
                              ),
                            ),
                            Expanded(
                              flex: 4,
                              child: _LogPanel(logs: _logs, controller: _logScroll),
                            ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── 顶部横幅 ────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({
    required this.snapshot,
    required this.checking,
    required this.installingLabel,
    required this.starting,
    required this.canStart,
    required this.onRefresh,
    required this.onStart,
  });

  final SetupSnapshot? snapshot;
  final bool checking;
  final String installingLabel;
  final bool starting;
  final bool canStart;
  final VoidCallback onRefresh;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final snap = snapshot;
    final ready = snap?.ready ?? false;
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          Icon(
            ready ? Icons.check_circle : Icons.build_circle,
            size: 34,
            color: ready ? Colors.green.shade600 : Colors.orange.shade700,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '运行环境准备',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  () {
                    if (installingLabel.isNotEmpty) return '$installingLabel 进行中，请查看右侧日志';
                    if (checking) return '正在检测环境 …';
                    if (ready) {
                      return '环境就绪（检测于 ${_timeLabel(snap!.checkedAt)}）· 识别引擎 Kraken 常驻加速已启用';
                    }
                    return '环境未就绪（检测于 ${_timeLabel(snap!.checkedAt)}），请按下方卡片提示安装';
                  }(),
                  style: TextStyle(
                    fontSize: 12.5,
                    color: ready ? Colors.green.shade700 : Colors.orange.shade800,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: checking ? null : onRefresh,
            icon: checking
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh, size: 18),
            label: const Text('重新检测'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: canStart ? onStart : null,
            style: FilledButton.styleFrom(
              backgroundColor: colorScheme.primary,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            ),
            icon: starting
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        colorScheme.onPrimary,
                      ),
                    ),
                  )
                : const Icon(Icons.rocket_launch, size: 18),
            label: const Text('进入 OCR'),
          ),
        ],
      ),
    );
  }

  static String _timeLabel(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.red.shade200),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: Colors.red.shade700, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 12.5, color: Colors.red.shade900),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── 分组卡片 ────────────────────────────────────────────────────────────────

class _BasicEnvCard extends StatelessWidget {
  const _BasicEnvCard({
    required this.snapshot,
    required this.installing,
    required this.onInstallConda,
  });

  final SetupSnapshot snapshot;
  final bool installing;
  final VoidCallback onInstallConda;

  @override
  Widget build(BuildContext context) {
    final gpu = snapshot.gpu;
    return _EnvCard(
      icon: Icons.memory,
      title: '基础环境',
      ok: snapshot.condaInstalled && gpu.available,
      action: snapshot.condaInstalled
          ? null
          : _CardAction(
              label: '安装 Miniconda',
              loading: installing,
              onPressed: onInstallConda,
            ),
      children: [
        _StatusLine(
          label: 'Conda',
          value: snapshot.condaInstalled
              ? snapshot.condaExecutable
              : '未找到（需先安装 Miniconda）',
          ok: snapshot.condaInstalled,
        ),
        _StatusLine(
          label: '显卡',
          value: gpu.available ? gpu.name : '未检测到 NVIDIA 显卡',
          ok: gpu.available,
        ),
        if (gpu.available)
          _StatusLine(
            label: '驱动 / CUDA',
            value: '${gpu.driverVersion.isEmpty ? '?' : gpu.driverVersion} / '
                '${gpu.driverCuda.isEmpty ? '?' : gpu.driverCuda}',
            ok: true,
            soft: true,
          ),
      ],
    );
  }
}

class _ServiceEnvCard extends StatelessWidget {
  const _ServiceEnvCard({
    required this.snapshot,
    required this.selectedRuntime,
    required this.useChinaMirror,
    required this.onUseChinaMirrorChanged,
    required this.onRuntimeChanged,
    required this.installing,
    required this.onInstall,
    required this.onRepairPymupdf,
  });

  final SetupSnapshot snapshot;
  final RuntimeOption? selectedRuntime;
  final bool useChinaMirror;
  final ValueChanged<bool> onUseChinaMirrorChanged;
  final ValueChanged<RuntimeOption> onRuntimeChanged;
  final bool installing;
  final VoidCallback onInstall;
  final VoidCallback onRepairPymupdf;

  @override
  Widget build(BuildContext context) {
    final service = snapshot.service;
    final missing = service.missingCore;
    // 修复按钮两种情况都给：包装都没装（missing 列出）、装了但 import 失败
    // （DLL 损坏，/pdf_to_images 会挂）。
    final pymupdfIssue = missing.contains('PyMuPDF') || service.pymupdfNeedsRepair;
    final fitzPkgMissing = missing.contains('PyMuPDF');
    return _EnvCard(
      icon: Icons.dns,
      title: '识别服务环境',
      ok: service.coreReady && service.fitzReady,
      action: service.coreReady
          ? (pymupdfIssue
                ? _CardAction(
                    label: '修复 PDF 组件',
                    loading: installing,
                    onPressed: onRepairPymupdf,
                  )
                : null)
          : _CardAction(
              label: '安装 / 修复识别服务环境',
              loading: installing,
              onPressed: onInstall,
            ),
      footer: service.coreReady
          ? null
          : _InstallOptions(
              options: snapshot.options,
              selected: selectedRuntime,
              useChinaMirror: useChinaMirror,
              onUseChinaMirrorChanged: onUseChinaMirrorChanged,
              onRuntimeChanged: onRuntimeChanged,
            ),
      children: [
        _StatusLine(
          label: 'Conda 环境',
          value: service.envExists ? '已创建' : '未创建',
          ok: service.envExists,
        ),
        if (service.pythonVersion.isNotEmpty)
          _StatusLine(label: 'Python', value: service.pythonVersion, ok: true, soft: true),
        _StatusLine(
          label: '服务依赖',
          value: missing.isEmpty
              ? '核心组件齐全'
              : '缺少 ${missing.length} 项：${missing.join('、')}',
          ok: missing.isEmpty,
        ),
        _StatusLine(
          label: 'PDF 组件',
          value: fitzPkgMissing
              ? '未安装 PyMuPDF（处理 PDF 书籍必需）'
              : service.fitzReady
              ? 'PyMuPDF ${service.packages['PyMuPDF']}（导入正常）'
              : '已安装但导入失败（DLL 损坏）'
                    '${service.fitzImportError.isEmpty ? '' : '：${service.fitzImportError}'}',
          ok: service.fitzReady,
        ),
      ],
    );
  }
}

class _KrakenCard extends StatelessWidget {
  const _KrakenCard({
    required this.snapshot,
    required this.installing,
    required this.onInstall,
  });

  final SetupSnapshot snapshot;
  final bool installing;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    final kraken = snapshot.kraken;
    return _EnvCard(
      icon: Icons.auto_stories,
      title: 'Kraken 识别引擎',
      ok: kraken.ready,
      action: kraken.ready
          ? null
          : _CardAction(
              label: '安装 Kraken 识别引擎',
              loading: installing,
              onPressed: onInstall,
            ),
      children: [
        _StatusLine(
          label: 'Conda 环境',
          value: kraken.envExists ? 'kraken' : '未创建',
          ok: kraken.envExists,
        ),
        _StatusLine(
          label: 'Kraken',
          value: kraken.krakenVersion.isEmpty ? '未安装' : kraken.krakenVersion,
          ok: kraken.krakenVersion.isNotEmpty,
        ),
        _StatusLine(
          label: 'PyTorch',
          value: kraken.torchVersion.isEmpty
              ? '未安装'
              : '${kraken.torchVersion}${kraken.torchCudaBuild ? '（GPU）' : '（CPU 构建）'}',
          ok: kraken.torchVersion.isNotEmpty,
          soft: kraken.torchVersion.isNotEmpty && !kraken.torchCudaBuild,
        ),
        _StatusLine(
          label: 'CHAT 识别模型',
          value: kraken.modelExists
              ? '已下载（${kraken.modelSizeMb} MB）'
              : '未下载（首次识别时自动下载，约 42 MB）',
          ok: kraken.modelExists,
          soft: !kraken.modelExists,
        ),
      ],
    );
  }
}

class _PaddleCard extends StatelessWidget {
  const _PaddleCard({
    required this.snapshot,
    required this.installing,
    required this.onInstall,
  });

  final SetupSnapshot snapshot;
  final bool installing;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    final paddle = snapshot.paddle;
    return _EnvCard(
      icon: Icons.auto_awesome_outlined,
      title: 'PaddleOCR 引擎（可选）',
      ok: paddle.ready,
      subtle: true,
      action: paddle.ready
          ? null
          : _CardAction(
              label: '安装 PaddleOCR 引擎',
              loading: installing,
              onPressed: onInstall,
            ),
      children: [
        _StatusLine(
          label: 'Conda 环境',
          value: paddle.envExists ? 'paddleocr' : '未创建',
          ok: paddle.envExists,
        ),
        _StatusLine(
          label: 'paddleocr',
          value: paddle.paddleocrVersion.isEmpty
              ? '未安装'
              : paddle.paddleocrVersion,
          ok: paddle.paddleocrVersion.isNotEmpty,
        ),
        _StatusLine(
          label: 'paddlepaddle',
          value: paddle.paddleVersion.isEmpty
              ? '未安装'
              : paddle.paddleVersion,
          ok: paddle.paddleVersion.isNotEmpty,
        ),
        _StatusLine(
          label: 'PP-OCRv6 模型',
          value: '选择 PaddleOCR 的书首次识别时自动下载'
              '（默认 PP-OCRv6_small_rec，20.4 MB）',
          ok: true,
          soft: true,
        ),
      ],
    );
  }
}

class _TrainingCard extends StatelessWidget {
  const _TrainingCard({
    required this.snapshot,
    required this.installing,
    required this.selectedRuntime,
    required this.onInstall,
    required this.onInstallCudaTorch,
  });

  final SetupSnapshot snapshot;
  final bool installing;
  final RuntimeOption? selectedRuntime;
  final VoidCallback onInstall;
  final VoidCallback onInstallCudaTorch;

  @override
  Widget build(BuildContext context) {
    final service = snapshot.service;
    final ok = service.trainingReady && service.yoloModelExists;
    // 有 NVIDIA 显卡且训练 torch 尚无 CUDA 可用时，提供 CUDA 安装按钮
    //（识别不依赖它，纯训练提速；wheel 约 2.5 GB）。
    final cudaActionNeeded =
        snapshot.gpu.available && service.trainingReady && !service.torchCuda;
    return _EnvCard(
      icon: Icons.model_training,
      title: '训练组件',
      ok: ok,
      subtle: true,
      action: !service.trainingReady
          ? _CardAction(
              label: '安装训练组件',
              loading: installing,
              onPressed: onInstall,
            )
          : cudaActionNeeded
          ? _CardAction(
              label: '安装 CUDA 训练组件',
              loading: installing,
              onPressed: onInstallCudaTorch,
            )
          : null,
      children: [
        _StatusLine(
          label: 'ultralytics',
          value: service.packages['ultralytics'] ?? '',
          ok: service.trainingReady,
        ),
        _StatusLine(
          label: '训练 PyTorch',
          value: () {
            final v = service.torchVersion;
            if (!snapshot.gpu.available) {
              return v.isEmpty ? '未安装（未检测到 NVIDIA 显卡，CPU 训练即可）' : '$v（CPU）';
            }
            if (v.isEmpty) {
              return '未安装（安装训练组件后带 CPU 版）';
            }
            if (service.torchCuda) return '$v（GPU 可用）';
            if (service.torchIsCudaBuild) {
              return '$v（CUDA 构建，但 GPU 不可用，请检查驱动）';
            }
            return '$v（CPU 版，训练慢，可安装 CUDA 版提速）';
          }(),
          ok: service.torchCuda,
          soft: !service.torchCuda,
        ),
        _StatusLine(
          label: '已启用单字模型',
          value: service.yoloModelExists
              ? 'yolo_char.pt（各层模型在训练页的"模型使用管理"中查看与切换）'
              : '未启用（不影响识别，可用标注数据训练后提速）',
          ok: service.yoloModelExists,
          soft: !service.yoloModelExists,
        ),
      ],
    );
  }
}

class _AdvancedCard extends StatelessWidget {
  const _AdvancedCard({required this.onReset, required this.installing});

  final VoidCallback onReset;
  final bool installing;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Row(
          children: [
            Icon(Icons.tune, size: 18, color: Colors.grey.shade600),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '高级：重置识别服务环境（删除 conda 环境后需重新安装）',
                style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700),
              ),
            ),
            TextButton(
              onPressed: installing ? null : onReset,
              style: TextButton.styleFrom(
                foregroundColor: Colors.red.shade700,
              ),
              child: const Text('重置'),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── 卡片骨架 / 状态行 / 动作 ────────────────────────────────────────────────

class _EnvCard extends StatelessWidget {
  const _EnvCard({
    required this.icon,
    required this.title,
    required this.ok,
    required this.children,
    this.subtle = false,
    this.action,
    this.footer,
  });

  final IconData icon;
  final String title;
  final bool ok;
  final List<Widget> children;
  final bool subtle;
  final _CardAction? action;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final color = ok
        ? Colors.green.shade600
        : (subtle ? Colors.grey : Colors.orange.shade700);
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Icon(
                  ok ? Icons.check_circle : Icons.error_outline,
                  size: 18,
                  color: color,
                ),
              ],
            ),
            const SizedBox(height: 10),
            ...children,
            if (footer != null) ...[
              const SizedBox(height: 8),
              footer!,
            ],
            if (action != null) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: action!.loading ? null : action!.onPressed,
                  icon: action!.loading
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download, size: 18),
                  label: Text(action!.label),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CardAction {
  const _CardAction({
    required this.label,
    required this.loading,
    required this.onPressed,
  });

  final String label;
  final bool loading;
  final VoidCallback onPressed;
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.label,
    required this.value,
    required this.ok,
    this.soft = false,
  });

  final String label;
  final String value;
  final bool ok;
  final bool soft;

  @override
  Widget build(BuildContext context) {
    final color = soft ? Colors.amber.shade700 : (ok ? Colors.green : Colors.red);
    final icon = soft
        ? Icons.remove_circle_outline
        : (ok ? Icons.check_circle_outline : Icons.cancel_outlined);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 8),
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '—' : value,
              style: TextStyle(
                fontSize: 12.5,
                color: Theme.of(context).textTheme.bodyMedium?.color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 服务环境安装参数：CUDA 运行时版本 + 国内镜像开关（仅在缺失时展开）。
class _InstallOptions extends StatelessWidget {
  const _InstallOptions({
    required this.options,
    required this.selected,
    required this.useChinaMirror,
    required this.onUseChinaMirrorChanged,
    required this.onRuntimeChanged,
  });

  final List<RuntimeOption> options;
  final RuntimeOption? selected;
  final bool useChinaMirror;
  final ValueChanged<bool> onUseChinaMirrorChanged;
  final ValueChanged<RuntimeOption> onRuntimeChanged;

  @override
  Widget build(BuildContext context) {
    final current = selected ?? options.first;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('CUDA 运行时', style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButton<RuntimeOption>(
                  value: current,
                  isDense: true,
                  isExpanded: true,
                  items: options
                      .map(
                        (o) => DropdownMenuItem(value: o, child: Text(o.label)),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v != null) onRuntimeChanged(v);
                  },
                ),
              ),
            ],
          ),
          InkWell(
            onTap: () => onUseChinaMirrorChanged(!useChinaMirror),
            child: Row(
              children: [
                SizedBox(
                  width: 22,
                  height: 22,
                  child: Checkbox(
                    value: useChinaMirror,
                    onChanged: (v) => onUseChinaMirrorChanged(v ?? true),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '使用国内镜像（清华 PyPI）',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── 安装日志面板 ────────────────────────────────────────────────────────────

class _LogPanel extends StatelessWidget {
  const _LogPanel({required this.logs, required this.controller});

  final List<String> logs;

  /// 日志滚动控制器：必须同时挂到 Scrollbar 和 ListView 上——Scrollbar
  /// 没有关联 ScrollPosition 时在桌面端会直接断言崩溃。
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(8, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Row(
              children: [
                const Icon(Icons.terminal, size: 16),
                const SizedBox(width: 6),
                const Text(
                  '安装日志',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.copy, size: 16),
                  tooltip: '复制日志',
                  onPressed: logs.isEmpty
                      ? null
                      : () {
                          Clipboard.setData(
                            ClipboardData(text: logs.join('\n')),
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('日志已复制'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              decoration: BoxDecoration(
                color: const Color(0xFF101418),
                borderRadius: BorderRadius.circular(8),
              ),
              child: logs.isEmpty
                  ? Center(
                      child: Text(
                        '暂无日志\n安装动作的输出会实时显示在这里',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.grey.shade500,
                          fontSize: 12,
                        ),
                      ),
                    )
                  : AttachedScrollbar(
                      controller: controller,
                      child: ListView.builder(
                        controller: controller,
                        padding: const EdgeInsets.all(10),
                        itemCount: logs.length,
                        itemBuilder: (context, index) => Text(
                          logs[index],
                          style: const TextStyle(
                            fontFamily: 'Consolas',
                            fontSize: 11.5,
                            height: 1.45,
                            color: Color(0xFFD7DEE7),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
