import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../services/ai_concurrency.dart';
import '../services/ai_stress_test.dart';
import '../services/hardware_info.dart';
import '../services/kraken_stress_test.dart';
import '../services/ollama_model_catalog.dart';
import '../services/ollama_pull_manager.dart';
import '../services/ollama_service.dart';
import '../services/python_service.dart';
import '../services/recognition_queue.dart';
import '../services/setup_service.dart';
import '../services/storage.dart';
import '../widgets/attached_scrollbar.dart';
import '../widgets/engine_settings_section.dart';
import 'changelog_page.dart';
import 'ollama_compare_page.dart';
import '../widgets/ollama_port_reclaim_panel.dart';

/// AI 辅助设置：选择推理来源——本地/局域网 Ollama 服务，或外部模型 API
/// （OpenAI 兼容协议：智谱 GLM、DeepSeek、Kimi、通义、SiliconFlow、
/// OpenAI 等，填 API 地址 + 密钥即可）。按来源选择视觉模型（单字辅助
/// 识别、整行裁决、识别框诊断）与文本模型（标点辅助识别、整行裁决兜底）。
/// 本地模式另含「模型安装」卡（按本机硬件推荐一键拉取）；修改即自动
/// 保存（无需「保存」按钮）。
class OllamaSettingsPage extends StatefulWidget {
  /// 作为整合页（HubPage）标签嵌入时不包自己的 Scaffold。
  final bool embedded;

  const OllamaSettingsPage({super.key, this.embedded = false});

  @override
  State<OllamaSettingsPage> createState() => _OllamaSettingsPageState();
}

class _OllamaSettingsPageState extends State<OllamaSettingsPage> {
  OllamaSettings _settings = const OllamaSettings();
  late final TextEditingController _baseUrlCtrl;

  // ── AI 并行度 ──
  AiStressResult? _stressResult;
  bool _stressRunning = false;
  bool _stressCancel = false;

  // ── 识别进程数（Kraken daemon 池）──
  KrakenStressResult? _krakenStress;
  bool _krakenStressRunning = false;
  bool _krakenStressCancel = false;

  /// 正在重建进程池（单飞；期间「应用」按钮禁用转圈）。
  bool _krakenApplying = false;

  // ── PaddleOCR 模型管理（可选引擎：说明 / 逐档下载 / 默认档选择）──
  /// /paddle/status 的结果（null = 后端未连接/未就绪，界面降级提示）。
  Map<String, dynamic>? _paddleStatus;

  /// 正在下载/自检的模型名集合（逐档按钮各自的转圈态；单飞防连点）。
  final Set<String> _paddleDownloading = {};

  // ── 外部模型 API 配置（多供应商：编辑目标 = 当前激活供应商）──
  late final TextEditingController _extNameCtrl;
  late final TextEditingController _extBaseUrlCtrl;
  late final TextEditingController _extApiKeyCtrl;
  bool _obscureApiKey = true;
  bool _loading = true;

  List<String> _models = const [];

  /// 已安装模型的完整信息（磁盘占用/更新时间，供「已安装模型」区）。
  List<OllamaInstalledModel> _installed = const [];

  /// 正在删除的模型名（单飞防并发；非空时全部删除按钮禁用）。
  String? _deletingModel;
  bool _testing = false;
  String? _testError;
  String? _testOk;
  bool _loadingModels = false;
  String? _modelsError;

  // ── 模型安装：硬件摘要（推荐依据）──
  HardwareInfo _hardware = HardwareInfo.unknown;
  bool _loadingHardware = false;

  // ── 模型安装：自定义输入 ──
  final TextEditingController _customModelCtrl = TextEditingController();

  /// 推荐列表的多选勾选（批量下载所选）。
  final Set<String> _pickModels = {};

  // ── 模型拉取：状态在全局管理器里，独立于页面生命周期（离开页面
  // 下载继续，返回即见进度与日志；重启后可续传）。页面只订阅渲染。
  final OllamaPullManager _pull = OllamaPullManager.instance;
  bool _showPullLog = true;
  final ScrollController _pullLogCtrl = ScrollController();

  /// 已处理过「安装成功」收尾的模型（避免重复 SnackBar/刷新）。
  final Set<String> _handledSuccess = {};

  // ── 一键安装 Ollama 程序（winget）──
  bool _installingApp = false;
  String? _appHint;
  bool _appHintOk = false;
  final List<String> _appLog = [];
  final ScrollController _appLogCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _baseUrlCtrl = TextEditingController();
    _extNameCtrl = TextEditingController();
    _extBaseUrlCtrl = TextEditingController();
    _extApiKeyCtrl = TextEditingController();
    _init();
  }

  @override
  void dispose() {
    _baseUrlCtrl.dispose();
    _extNameCtrl.dispose();
    _extBaseUrlCtrl.dispose();
    _extApiKeyCtrl.dispose();
    _customModelCtrl.dispose();
    _pullLogCtrl.dispose();
    _appLogCtrl.dispose();
    // 拉取任务由全局管理器持有：离开页面下载继续，这里只解除订阅；
    // 千万不要关它的 HTTP client（那会把进行中的下载一并中止）。
    _pull.removeListener(_onPullChanged);
    // winget 安装进程不杀：页面退出后让它静默装完（杀了会留下半截安装）。
    super.dispose();
  }

  Future<void> _init() async {
    final s = await OllamaSettings.load();
    final stress = await AiStressCache.load();
    final krakenStress = await KrakenStressCache.load();
    if (!mounted) return;
    setState(() {
      _settings = s;
      _stressResult = stress;
      _krakenStress = krakenStress;
      _baseUrlCtrl.text = s.baseUrl;
      _syncExtCtrls();
      _loading = false;
    });
    // 进页自动测一次连接并顺带拉模型列表，已配置好的用户直接看到状态。
    unawaited(_testConnection());
    // PaddleOCR 模型状态（环境/已下载档）后台拉取：后端未起时静默降级。
    unawaited(_loadPaddleStatus());
    // 硬件探测要跑 1~2 秒子进程，后台进行，不阻塞页面。
    unawaited(_loadHardware());
    // 恢复上次未完成的下载记录（应用重启后续传提示），并订阅进度。
    _pull.addListener(_onPullChanged);
    unawaited(_pull.restore());
    // 拉取在本页面之外完成过（离开页面期间）：补刷新与自动选型。
    for (final t in _pull.tasks) {
      if (t.phase == OllamaPullPhase.succeeded &&
          !_handledSuccess.contains(t.model)) {
        _handledSuccess.add(t.model);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_afterPullSucceeded(t.model));
        });
      }
    }
  }

  Future<void> _save() async {
    await _settings.save();
  }

  void _update(OllamaSettings Function(OllamaSettings) fn) {
    setState(() => _settings = fn(_settings));
    unawaited(_save());
    // 并行度档位/手动值可能变了：限流器下次空闲时按新设置重解析。
    AiRequestLimiter.instance.markStale();
  }

  /// 切换推理来源：清掉另一来源的连接状态与模型列表（两边各留一份
  /// 配置，切回来还在），随后自动测一次连接。
  void _switchProvider(AiProvider p) {
    if (p == _settings.provider) return;
    _update((s) => s.copyWith(provider: p));
    setState(() {
      _models = const [];
      _installed = const [];
      _testOk = null;
      _testError = null;
      _modelsError = null;
    });
    unawaited(_testConnection());
  }

  /// 把三个外部供应商输入框同步成当前激活供应商的值（进页与切供应商时）。
  void _syncExtCtrls() {
    final p = _settings.activeExtProvider;
    _extNameCtrl.text = p?.name ?? '';
    _extBaseUrlCtrl.text = p?.baseUrl ?? '';
    _extApiKeyCtrl.text = p?.apiKey ?? '';
  }

  /// 对当前激活供应商做不可变更新并保存。
  void _updateActiveProvider(ExternalApiProvider Function(ExternalApiProvider) fn) {
    _update((s) {
      final cur = s.activeExtProvider;
      if (cur == null) return s;
      final next = fn(cur);
      return s.copyWith(
        extProviders: [
          for (final p in s.extProviders) if (p.id == cur.id) next else p,
        ],
      );
    });
  }

  /// 新增供应商：生成默认名并立即可编辑（地址/密钥随后填写）。
  void _addExtProvider() {
    _update((s) {
      final p = ExternalApiProvider(
        id: ExternalApiProvider.newId(),
        name: '供应商 ${s.extProviders.length + 1}',
      );
      return s.copyWith(
        extProviders: [...s.extProviders, p],
        activeExtProviderId: p.id,
      );
    });
    _syncExtCtrls();
    setState(() {
      _models = const [];
      _installed = const [];
      _testOk = null;
      _testError = null;
      _modelsError = null;
    });
  }

  /// 删除当前激活供应商：确认后移除；视觉/文本槽位若绑定它则一并清空。
  Future<void> _removeActiveProvider() async {
    final cur = _settings.activeExtProvider;
    if (cur == null) return;
    final bound = <String>[
      if (_settings.extVisionProviderId == cur.id &&
          _settings.extVisionModel.isNotEmpty)
        '视觉模型',
      if (_settings.extTextProviderId == cur.id &&
          _settings.extTextModel.isNotEmpty)
        '文本模型',
    ];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除供应商 ${cur.name}'),
        content: Text(
          '将移除该供应商的地址、密钥与模型配置。'
          '${bound.isNotEmpty ? '\n注意：${bound.join('与')}当前使用该供应商，删除后需重新选择。' : ''}'
          '\n确定删除吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _update((s) {
      final rest = s.extProviders.where((p) => p.id != cur.id).toList();
      // 只清绑定被删供应商的槽位；空绑定回退激活供应商（已切到 rest.first），
      // 模型名不属于被删供应商，继续有效。
      final visionBound = s.extVisionProviderId == cur.id;
      final textBound = s.extTextProviderId == cur.id;
      return s.copyWith(
        extProviders: rest,
        activeExtProviderId: rest.isEmpty ? '' : rest.first.id,
        extVisionProviderId: visionBound ? '' : null,
        extTextProviderId: textBound ? '' : null,
        extVisionModel: visionBound ? '' : null,
        extTextModel: textBound ? '' : null,
      );
    });
    _syncExtCtrls();
    setState(() {
      _models = const [];
      _installed = const [];
      _testOk = null;
      _testError = null;
      _modelsError = null;
    });
    unawaited(_testConnection());
  }

  /// 切换激活供应商：同步输入框、作废旧连接状态与模型列表，自动测一次。
  void _switchExtProvider(String id) {
    if (id == _settings.activeExtProviderId) return;
    _update((s) => s.copyWith(activeExtProviderId: id));
    _syncExtCtrls();
    setState(() {
      _models = const [];
      _installed = const [];
      _testOk = null;
      _testError = null;
      _modelsError = null;
    });
    unawaited(_testConnection());
  }

  /// 当前激活供应商的地址命中的服务商预设（未命中 = 自定义）。
  String get _extPresetName {
    final url = _extBaseUrlCtrl.text.trim();
    for (final p in externalApiPresets) {
      if (p.name != '自定义' && p.baseUrl == url) return p.name;
    }
    return '自定义';
  }

  /// 选用预设：填当前供应商的地址（密钥与模型不动——各家控制台各自获取）。
  void _applyPreset(String name) {
    final preset = externalApiPresets.firstWhere((p) => p.name == name);
    if (preset.baseUrl.isEmpty) return; // 自定义：保持手填地址
    _extBaseUrlCtrl.text = preset.baseUrl;
    _updateActiveProvider((p) => p.copyWith(baseUrl: preset.baseUrl));
    // 地址变了，旧连接状态与模型列表作废。
    setState(() {
      _models = const [];
      _installed = const [];
      _testOk = null;
      _testError = null;
      _modelsError = null;
    });
  }

  /// 往当前供应商加模型（去重；名字非法拒绝）。
  void _addModelToActiveProvider(String rawName) {
    final name = rawName.trim();
    if (name.isEmpty) return;
    final cur = _settings.activeExtProvider;
    if (cur == null) return;
    if (cur.models.contains(name)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('模型 $name 已在该供应商的列表里')),
      );
      return;
    }
    _updateActiveProvider((p) => p.copyWith(models: [...p.models, name]));
  }

  void _removeModelFromActiveProvider(String name) {
    _updateActiveProvider((p) => p.copyWith(
      models: p.models.where((m) => m != name).toList(),
    ));
    // 视觉/文本槽位正用着该模型：一并清空，避免悬空引用。
    _update((s) => s.copyWith(
      extVisionModel: s.extVisionModel == name ? '' : null,
      extTextModel: s.extTextModel == name ? '' : null,
    ));
  }

  Future<void> _testConnection() async {
    if (_settings.provider == AiProvider.externalApi) {
      return _testExternalConnection();
    }
    final url = _baseUrlCtrl.text.trim();
    if (url.isEmpty) {
      setState(() {
        _testError = '请先填写服务地址';
        _testOk = null;
      });
      return;
    }
    setState(() {
      _testing = true;
      _testError = null;
      _testOk = null;
    });
    try {
      final version = await OllamaService.checkConnection(url);
      if (!mounted) return;
      setState(() {
        _testOk = '连接成功 · Ollama $version';
        _testing = false;
      });
      _update((s) => s.copyWith(baseUrl: url));
      await _refreshModels();
    } on OllamaException catch (e) {
      if (!mounted) return;
      setState(() {
        _testError = e.message;
        _testing = false;
        _models = const [];
      });
    }
  }

  /// 外部 API 连接测试：先把名称/地址/密钥存进当前激活供应商（服务层
  /// 按供应商取数），再拉一次模型列表确认可用。
  Future<void> _testExternalConnection() async {
    if (_settings.activeExtProvider == null) return; // 无供应商不测
    final name = _extNameCtrl.text.trim();
    final url = _extBaseUrlCtrl.text.trim();
    final key = _extApiKeyCtrl.text.trim();
    if (url.isEmpty) {
      setState(() {
        _testError = '请先填写 API 地址（一般以 /v1 结尾）';
        _testOk = null;
      });
      return;
    }
    setState(() {
      _testing = true;
      _testError = null;
      _testOk = null;
    });
    _updateActiveProvider((p) => p.copyWith(
      name: name.isNotEmpty ? name : p.name,
      baseUrl: url,
      apiKey: key,
    ));
    final target = _settings.activeExtProvider;
    if (target == null) return;
    try {
      final ok = await OllamaService.checkConnectionOfProvider(target);
      if (!mounted) return;
      setState(() {
        _testOk = '连接成功 · $ok';
        _testing = false;
      });
      await _refreshModels();
    } on OllamaException catch (e) {
      if (!mounted) return;
      setState(() {
        _testError = e.message;
        _testing = false;
        _models = const [];
      });
    }
  }

  Future<void> _refreshModels() async {
    setState(() {
      _loadingModels = true;
      _modelsError = null;
    });
    try {
      final models = await OllamaService.listModelsFor(_settings);
      if (!mounted) return;
      setState(() {
        _installed = models;
        _models = [for (final m in models) m.name];
        _loadingModels = false;
      });
    } on OllamaException catch (e) {
      if (!mounted) return;
      setState(() {
        _modelsError = e.message;
        _loadingModels = false;
      });
    }
  }

  // ── 硬件检测 ──

  Future<void> _loadHardware({bool force = false}) async {
    setState(() => _loadingHardware = true);
    final hw = await HardwareDetector.detect(force: force);
    if (!mounted) return;
    setState(() {
      _hardware = hw;
      _loadingHardware = false;
    });
  }

  String get _hardwareSummary {
    final parts = <String>[];
    if (_hardware.hasNvidiaGpu) {
      parts.add(_hardware.gpuName);
      parts.add('${(_hardware.vramTotalMb / 1024).round()} GB 显存');
    } else {
      parts.add('未检测到 NVIDIA 独显（按 CPU 推理评估）');
    }
    if (_hardware.ramTotalMb > 0) {
      parts.add('${(_hardware.ramTotalMb / 1024).round()} GB 内存');
    }
    return parts.join(' · ');
  }

  // ── 模型拉取（委托全局管理器；页面只渲染其状态）──

  Future<void> _startPull(String rawName) async {
    final model = OllamaModelCatalog.parseModelNameFromCommand(rawName);
    if (model == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请输入合法的模型名，如 qwen3.5:4b')));
      return;
    }
    // 由全局管理器执行：离开页面/切换页面不影响下载，返回即见进度。
    unawaited(_pull.start(baseUrl: _settings.baseUrl, model: model));
  }

  /// 管理器状态变化：刷新 UI、滚日志到底；刚成功就补模型列表与选型。
  void _onPullChanged() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pullLogCtrl.hasClients) {
        _pullLogCtrl.jumpTo(_pullLogCtrl.position.maxScrollExtent);
      }
    });
    for (final t in _pull.tasks) {
      if (t.phase == OllamaPullPhase.succeeded &&
          !_handledSuccess.contains(t.model)) {
        _handledSuccess.add(t.model);
        unawaited(_afterPullSucceeded(t.model));
      }
    }
  }

  /// 拉取成功的收尾：提示、刷新模型列表、空槽位自动选上刚装的模型。
  Future<void> _afterPullSucceeded(String model) async {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('模型 $model 安装完成')));
    await _refreshModels();
    if (!mounted) return;
    // 对应槽位还空着就自动补上刚装的模型，装完即用。
    final entry = OllamaModelCatalog.findEntry(model);
    if (entry != null) {
      if (entry.kind == OllamaModelKind.vision &&
          _settings.visionModel.isEmpty) {
        _update((s) => s.copyWith(visionModel: model));
      } else if (entry.kind == OllamaModelKind.text &&
          _settings.textModel.isEmpty) {
        _update((s) => s.copyWith(textModel: model));
      }
    }
  }

  void _copyPullLog() {
    Clipboard.setData(ClipboardData(text: _pull.log.join('\n')));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('日志已复制'), duration: Duration(seconds: 1)),
    );
  }

  // ── 一键安装 Ollama 程序 ──

  Future<void> _installOllamaApp() async {
    if (_installingApp) return;
    setState(() {
      _installingApp = true;
      _appHint = null;
      _appLog
        ..clear()
        ..add('[ui] 一键安装 Ollama（winget 静默安装）…');
    });
    try {
      final process = await SetupService.installOllamaApp();
      final stdoutDone = process.stdout
          .transform(systemEncoding.decoder)
          .listen(_appendAppLog)
          .asFuture<void>();
      final stderrDone = process.stderr
          .transform(systemEncoding.decoder)
          .listen(_appendAppLog)
          .asFuture<void>();
      final code = await process.exitCode;
      await Future.wait([stdoutDone, stderrDone]);
      if (!mounted) return;
      _appendAppLog('[ui] exit code: $code');
      setState(() {
        _installingApp = false;
        _appHintOk = code == 0;
        _appHint = code == 0
            ? 'Ollama 安装完成，后台服务通常会自动启动。点上方「测试连接并获取模型」重试。'
            : '一键安装未成功（winget 不可用或下载失败），可到 ollama.com/download 手动下载。';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _installingApp = false;
        _appHintOk = false;
        _appHint = '启动安装器失败：$e。可到 ollama.com/download 手动下载。';
      });
    }
  }

  void _appendAppLog(String line) {
    if (!mounted) return;
    setState(() {
      _appLog.add(line);
      if (_appLog.length > 300) _appLog.removeRange(0, _appLog.length - 300);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_appLogCtrl.hasClients) {
        _appLogCtrl.jumpTo(_appLogCtrl.position.maxScrollExtent);
      }
    });
  }

  Future<void> _openOllamaDownloadPage() async {
    try {
      await Process.run('explorer.exe', ['https://ollama.com/download']);
    } catch (_) {
      // 打不开浏览器就算了，提示文案里已有网址。
    }
  }

  /// 抢回端口后的自动重连：端口释放后 Ollama 托盘会自动重试绑定，
  /// 最多等 3 轮 ×3 秒；返回是否已连上（面板据此提示）。
  Future<bool> _retestAfterPortReclaim() async {
    for (var attempt = 0; attempt < 3; attempt++) {
      await _testConnection();
      if (!mounted) return false;
      if (_testOk != null) return true;
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    return _testOk != null;
  }

  // ── UI ──

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      const spinner = Center(child: CircularProgressIndicator());
      if (widget.embedded) return spinner;
      return const Scaffold(body: spinner);
    }
    final body = ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _connectionCard(),
        if (_settings.provider == AiProvider.localOllama) ...[
          const SizedBox(height: 12),
          _installCard(),
        ],
        const SizedBox(height: 12),
        _modelCard(),
        const SizedBox(height: 12),
        _featureCard(),
        const SizedBox(height: 12),
        _parallelCard(),
        const SizedBox(height: 12),
        _krakenCard(),
        const SizedBox(height: 12),
        _paddleCard(),
        const SizedBox(height: 12),
        _compareEntryCard(),
        const SizedBox(height: 12),
        _helpCard(),
      ],
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(title: const Text('AI 辅助设置')),
      body: body,
    );
  }

  /// 模型对比入口：进「AI 模型对比」工作台（真实书页上并排对比各模型
  /// 在四个 AI 功能上的输出/耗时，附管线协作说明）。
  Widget _compareEntryCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.compare_arrows, size: 20),
            const SizedBox(width: 8),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('模型对比测试', style: TextStyle(fontWeight: FontWeight.w600)),
                  SizedBox(height: 2),
                  Text(
                    '选真实书页，并排对比各模型在单字辅助识别、整行裁决、'
                    '识别框诊断、标点辅助上的输出与耗时，可看每次调用的 '
                    'prompt 与原始返回，附管线（YOLO/OpenCV/Kraken）协作说明',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonalIcon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const OllamaComparePage(),
                ),
              ),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('打开对比页'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _connectionCard() {
    final external = _settings.provider == AiProvider.externalApi;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.lan_outlined, size: 20),
                const SizedBox(width: 8),
                const Text(
                  'AI 推理来源',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (_testOk != null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.check_circle,
                        size: 16,
                        color: Colors.green.shade700,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          _testOk!,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.green.shade700,
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 12),
            SegmentedButton<AiProvider>(
              segments: const [
                ButtonSegment(
                  value: AiProvider.localOllama,
                  label: Text('本地 Ollama'),
                  icon: Icon(Icons.dns_outlined, size: 16),
                ),
                ButtonSegment(
                  value: AiProvider.externalApi,
                  label: Text('外部模型 API'),
                  icon: Icon(Icons.cloud_outlined, size: 16),
                ),
              ],
              selected: {_settings.provider},
              onSelectionChanged: (set) => _switchProvider(set.first),
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
            ),
            const SizedBox(height: 12),
            if (external)
              _externalConnectionSection()
            else
              _localConnectionSection(),
          ],
        ),
      ),
    );
  }

  /// 本地 Ollama 配置区：服务地址 + 连接测试 + 排障（一键安装/抢回端口）。
  Widget _localConnectionSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _baseUrlCtrl,
          decoration: const InputDecoration(
            labelText: 'Ollama 服务地址',
            hintText: 'http://localhost:11434',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            FilledButton.tonalIcon(
              onPressed: _testing ? null : _testConnection,
              icon: _testing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.network_check, size: 18),
              label: const Text('测试连接并获取模型'),
            ),
          ],
        ),
        if (_testError != null) ...[
          const SizedBox(height: 10),
          Text(
            _testError!,
            style: TextStyle(fontSize: 12, color: Colors.red.shade700),
          ),
          const SizedBox(height: 10),
          const Divider(height: 1),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Expanded(
                child: Text(
                  '这台电脑还没装 Ollama？可在此一键安装（winget 静默安装，需联网）：',
                  style: TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: _installingApp ? null : _installOllamaApp,
                icon: _installingApp
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.downloading, size: 18),
                label: Text(_installingApp ? '正在安装…' : '一键安装 Ollama'),
              ),
            ],
          ),
          if (Platform.isWindows) ...[
            const SizedBox(height: 12),
            // 已装 Ollama 却总连不上？多为开机时 Hyper-V/WSL 把端口
            // 保留走了：这里体检并一键抢回端口。
            OllamaPortReclaimPanel(
              baseUrl: _baseUrlCtrl.text.trim(),
              onReclaimed: _retestAfterPortReclaim,
            ),
          ],
          if (_appHint != null) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  _appHintOk ? Icons.check_circle : Icons.error_outline,
                  size: 14,
                  color: _appHintOk
                      ? Colors.green.shade700
                      : Colors.orange.shade800,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    _appHint!,
                    style: TextStyle(
                      fontSize: 12,
                      color: _appHintOk
                          ? Colors.green.shade700
                          : Colors.orange.shade800,
                    ),
                  ),
                ),
                if (!_appHintOk)
                  TextButton(
                    onPressed: _openOllamaDownloadPage,
                    child: const Text('打开下载页'),
                  ),
              ],
            ),
          ],
          if (_appLog.isNotEmpty) ...[
            const SizedBox(height: 8),
            _miniLogPanel(logs: _appLog, controller: _appLogCtrl),
          ],
        ],
      ],
    );
  }

  /// 外部模型 API 配置区（多供应商）：供应商切换/新增/删除 + 当前供应商
  /// 的名称/预设/地址/密钥 + 连接测试 + 该供应商的模型列表管理。
  Widget _externalConnectionSection() {
    final active = _settings.activeExtProvider;
    final providers = _settings.extProviders;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('供应商', style: TextStyle(fontSize: 13)),
            const SizedBox(width: 10),
            Expanded(
              child: providers.isEmpty
                  ? Text(
                      '还没有供应商，点右侧「新增」开始配置',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                    )
                  : DropdownButton<String>(
                      value: active?.id,
                      underline: const SizedBox.shrink(),
                      isExpanded: true,
                      items: [
                        for (final p in providers)
                          DropdownMenuItem(
                            value: p.id,
                            child: Text(
                              p.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) {
                        if (v != null) _switchExtProvider(v);
                      },
                    ),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: _addExtProvider,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('新增'),
            ),
            if (active != null)
              TextButton.icon(
                onPressed: () => unawaited(_removeActiveProvider()),
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('删除'),
                style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
              ),
          ],
        ),
        if (active != null) ...[
          const SizedBox(height: 6),
          TextField(
            controller: _extNameCtrl,
            onChanged: (v) =>
                _updateActiveProvider((p) => p.copyWith(name: v.trim())),
            decoration: const InputDecoration(
              labelText: '供应商名称',
              hintText: '如 智谱 GLM、自建 one-api 网关',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Text('服务商预设', style: TextStyle(fontSize: 13)),
              const SizedBox(width: 10),
              DropdownButton<String>(
                value: _extPresetName,
                underline: const SizedBox.shrink(),
                items: [
                  for (final p in externalApiPresets)
                    DropdownMenuItem(value: p.name, child: Text(p.name)),
                ],
                onChanged: (v) {
                  if (v != null) _applyPreset(v);
                },
              ),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _extBaseUrlCtrl,
            onChanged: (v) =>
                _updateActiveProvider((p) => p.copyWith(baseUrl: v.trim())),
            decoration: const InputDecoration(
              labelText: 'API 地址（OpenAI 兼容，填到 /v1 这一级）',
              hintText: 'https://api.deepseek.com/v1',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _extApiKeyCtrl,
            obscureText: _obscureApiKey,
            onChanged: (v) =>
                _updateActiveProvider((p) => p.copyWith(apiKey: v.trim())),
            decoration: InputDecoration(
              labelText: 'API Key',
              hintText: '到服务商控制台创建（sk-…）',
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: IconButton(
                tooltip: _obscureApiKey ? '显示密钥' : '隐藏密钥',
                icon: Icon(
                  _obscureApiKey ? Icons.visibility_off : Icons.visibility,
                  size: 18,
                ),
                onPressed: () =>
                    setState(() => _obscureApiKey = !_obscureApiKey),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: _testing ? null : _testConnection,
                icon: _testing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.network_check, size: 18),
                label: const Text('测试连接并获取模型'),
              ),
            ],
          ),
          if (_testError != null) ...[
            const SizedBox(height: 10),
            Text(
              _testError!,
              style: TextStyle(fontSize: 12, color: Colors.red.shade700),
            ),
          ],
          const SizedBox(height: 10),
          _providerModelsSection(active),
        ],
        const SizedBox(height: 10),
        Text(
          'OpenAI Chat Completions 兼容协议，可同时配置多家供应商（智谱 GLM / '
          'DeepSeek / Kimi / 通义 / SiliconFlow / OpenAI / 自建网关均可），'
          '在下方「模型选择」里为视觉与文本槽位各选一家供应商的一个模型。'
          '密钥只保存在本机，请求由本机直发各服务商；'
          '注意：视觉类辅助会把裁出的字图/行图上传给所选服务商。',
          style: TextStyle(
            fontSize: 12,
            height: 1.5,
            color: Colors.grey.shade600,
          ),
        ),
      ],
    );
  }

  /// 当前供应商的模型列表管理：已配置模型 chips（可删）+ 从拉取列表
  /// 添加 + 手动输入添加。
  Widget _providerModelsSection(ExternalApiProvider active) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '该供应商的模型（${active.models.length}）',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        if (active.models.isEmpty)
          Text(
            '还没有配置模型——连接成功后从「从列表添加」选取，或「手动添加」输入模型名',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
          )
        else
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final m in active.models)
                InputChip(
                  label: Text(m, style: const TextStyle(fontSize: 12)),
                  visualDensity: VisualDensity.compact,
                  onDeleted: () => _removeModelFromActiveProvider(m),
                  tooltip: '从该供应商移除 $m',
                ),
            ],
          ),
        const SizedBox(height: 6),
        Row(
          children: [
            if (_models.isNotEmpty)
              Expanded(
                child: DropdownButtonFormField<String>(
                  // 绑定已配模型数：添加后重建表单复位选中态（不然下拉
                  // 一直显示上次选中的名字，像没加上一样）。
                  key: ValueKey('add-model-${active.models.length}'),
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: '从已拉取列表添加',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  hint: const Text(
                    '选择「测试连接」拉到的模型',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12),
                  ),
                  items: [
                    for (final m in _models)
                      if (!active.models.contains(m))
                        DropdownMenuItem(
                          value: m,
                          child: Text(m, overflow: TextOverflow.ellipsis),
                        ),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    _addModelToActiveProvider(v);
                    setState(() {}); // 复位下拉选中态
                  },
                ),
              )
            else
              Expanded(
                child: Text(
                  '「测试连接并获取模型」成功后，可在这里从列表勾选模型',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                ),
              ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: () => unawaited(_manualAddModelDialog()),
              icon: const Icon(Icons.edit, size: 16),
              label: const Text('手动添加'),
            ),
          ],
        ),
      ],
    );
  }

  /// 手动输入模型名加入当前供应商（部分网关不提供 /models 列表时的兜底）。
  Future<void> _manualAddModelDialog() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('手动添加模型'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '模型名',
            hintText: '如 glm-4.5v、deepseek-chat',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (name == null) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    _addModelToActiveProvider(trimmed);
  }

  Widget _installCard() {
    final connected = _testOk != null;
    final pull = _pull;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.download_outlined, size: 20),
                const SizedBox(width: 8),
                const Text(
                  '模型安装',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Flexible(
                  child: Text(
                    _hardwareSummary,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ),
                IconButton(
                  tooltip: '重新检测硬件',
                  onPressed: _loadingHardware
                      ? null
                      : () => _loadHardware(force: true),
                  icon: _loadingHardware
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.memory, size: 20),
                ),
              ],
            ),
            if (!connected)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '先在上方「测试连接并获取模型」连上 Ollama，才能安装模型。',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              )
            else ...[
              if (_pull.tasks.any(
                (t) =>
                    t.phase == OllamaPullPhase.interrupted ||
                    t.phase == OllamaPullPhase.failed,
              ))
                _resumeBanners(),
              _recommendSection(),
              const SizedBox(height: 12),
              _customInstallRow(),
              ..._activePullStrips(),
              if (_installed.isNotEmpty) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.inventory_2_outlined, size: 16),
                    const SizedBox(width: 6),
                    Text(
                      '已安装模型（${_installed.length}）',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '不用的可删除腾出磁盘空间',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade500,
                      ),
                    ),
                  ],
                ),
                for (final m in _installed) _installedRow(m),
              ],
              if (pull.log.isNotEmpty) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.terminal, size: 16),
                    const SizedBox(width: 6),
                    const Text(
                      '拉取日志',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 16),
                      tooltip: '复制日志',
                      onPressed: _copyPullLog,
                    ),
                    IconButton(
                      icon: Icon(
                        _showPullLog ? Icons.expand_less : Icons.expand_more,
                        size: 20,
                      ),
                      tooltip: _showPullLog ? '收起日志' : '展开日志',
                      onPressed: () =>
                          setState(() => _showPullLog = !_showPullLog),
                    ),
                  ],
                ),
                if (_showPullLog)
                  _miniLogPanel(logs: pull.log, controller: _pullLogCtrl),
              ],
            ],
          ],
        ),
      ),
    );
  }

  /// 中断/失败任务提示条：Ollama 服务端对已下载层原生续传，一键继续即可。
  /// 多条未完成记录逐条列出，多于一条时提供「全部继续/全部忽略」。
  Widget _resumeBanners() {
    final pending = _pull.tasks
        .where(
          (t) =>
              t.phase == OllamaPullPhase.interrupted ||
              t.phase == OllamaPullPhase.failed,
        )
        .toList();
    if (pending.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        if (pending.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Text(
                  '有 ${pending.length} 个未完成的下载',
                  style: TextStyle(fontSize: 12, color: Colors.orange.shade900),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    for (final t in pending) {
                      unawaited(_startPull(t.model));
                    }
                  },
                  child: const Text('全部继续'),
                ),
                TextButton(
                  onPressed: _pull.dismissAll,
                  child: const Text('全部忽略'),
                ),
              ],
            ),
          ),
        for (final t in pending) _resumeBannerFor(t),
      ],
    );
  }

  Widget _resumeBannerFor(OllamaPullTask task) {
    final failed = task.phase == OllamaPullPhase.failed;
    final detail = failed
        ? '${task.model} 安装失败：'
              '${(task.error?.isNotEmpty ?? false) ? task.error! : task.status}'
        : '上次下载 ${task.model} 未完成（继续下载会从已下载部分续传）';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: (failed ? Colors.red : Colors.orange).withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            failed ? Icons.error_outline : Icons.download_for_offline_outlined,
            size: 16,
            color: failed ? Colors.red.shade700 : Colors.orange.shade800,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              detail,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: failed ? Colors.red.shade700 : Colors.orange.shade900,
              ),
            ),
          ),
          TextButton(
            onPressed: () => unawaited(_startPull(task.model)),
            child: Text(failed ? '重试' : '继续下载'),
          ),
          TextButton(
            onPressed: () => _pull.dismiss(task.model),
            child: const Text('忽略'),
          ),
        ],
      ),
    );
  }

  /// 下载中的任务条（每个任务一条：模型 · 状态 · 进度 · 取消）。
  List<Widget> _activePullStrips() {
    final active = _pull.tasks
        .where((t) => t.phase == OllamaPullPhase.pulling)
        .toList();
    if (active.isEmpty) return const [];
    return [
      const SizedBox(height: 8),
      for (final t in active)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text(t.model, style: const TextStyle(fontSize: 12)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${t.status} · ${t.progressText}',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: t.error != null
                        ? Colors.red.shade700
                        : Colors.grey.shade800,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => _pull.cancel(t.model),
                child: const Text('取消'),
              ),
            ],
          ),
        ),
    ];
  }

  /// 推荐区：按本机硬件给「最优选择」横幅 + 视觉/文本两组模型行。
  Widget _recommendSection() {
    final recs = OllamaModelCatalog.recommendForHardware(_hardware);
    final bestVision = recs
        .where((r) => r.entry.kind == OllamaModelKind.vision && r.bestPick)
        .toList();
    final bestText = recs
        .where((r) => r.entry.kind == OllamaModelKind.text && r.bestPick)
        .toList();
    final bannerParts = <String>[
      if (bestVision.isNotEmpty)
        '视觉 ${bestVision.first.entry.name}（${bestVision.first.fitLabel}）',
      if (bestText.isNotEmpty)
        '文本 ${bestText.first.entry.name}（${bestText.first.fitLabel}）',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (bannerParts.isNotEmpty) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.star, size: 16, color: Colors.amber.shade800),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '根据本机配置推荐：${bannerParts.join('，')}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.amber.shade900,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
        _batchPullBar(),
        _groupLabel('视觉模型（单字辅助识别 · 整行裁决 · 识别框诊断）'),
        for (final r in recs)
          if (r.entry.kind == OllamaModelKind.vision) _recommendRow(r),
        const SizedBox(height: 8),
        _groupLabel('文本模型（标点辅助识别 · 整行裁决兜底）'),
        for (final r in recs)
          if (r.entry.kind == OllamaModelKind.text) _recommendRow(r),
      ],
    );
  }

  /// 批量下载条：多选已选数 + 同时下载数设置 + 下载所选/清空。
  Widget _batchPullBar() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Text(
            _pickModels.isEmpty ? '勾选模型可批量下载' : '已选 ${_pickModels.length} 个',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _pickModels.isEmpty
                ? null
                : () {
                    _pull.startAll(
                      baseUrl: _settings.baseUrl,
                      models: _pickModels.toList(),
                    );
                    setState(() => _pickModels.clear());
                  },
            icon: const Icon(Icons.download, size: 16),
            label: const Text('下载所选'),
          ),
          if (_pickModels.isNotEmpty) ...[
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => setState(() => _pickModels.clear()),
              child: const Text('清空'),
            ),
          ],
          const Spacer(),
          Text(
            '同时下载',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          const SizedBox(width: 4),
          DropdownButton<int>(
            value: _pull.concurrency,
            underline: const SizedBox.shrink(),
            items: [
              for (var n = 1; n <= 4; n++)
                DropdownMenuItem(value: n, child: Text('$n')),
            ],
            onChanged: (v) {
              if (v != null) unawaited(_pull.setConcurrency(v));
            },
          ),
        ],
      ),
    );
  }

  Widget _groupLabel(String label) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Text(
        label,
        style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
      ),
    );
  }

  Widget _recommendRow(OllamaModelRecommendation r) {
    final e = r.entry;
    final installed = _installedModelName(e);
    final task = _pull.taskOf(e.name);
    final pulling = task?.phase == OllamaPullPhase.pulling;
    final queued = task?.phase == OllamaPullPhase.queued;
    final failed = task?.phase == OllamaPullPhase.failed;
    final picked = _pickModels.contains(e.name);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 36,
            child: Checkbox(
              visualDensity: VisualDensity.compact,
              value: picked,
              onChanged: (v) => setState(() {
                if (v == true) {
                  _pickModels.add(e.name);
                } else {
                  _pickModels.remove(e.name);
                }
              }),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        e.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (r.bestPick) ...[
                      const SizedBox(width: 6),
                      Icon(Icons.star, size: 14, color: Colors.amber.shade700),
                      Text(
                        ' 推荐',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.amber.shade800,
                        ),
                      ),
                    ],
                    if (installed != null) ...[
                      const SizedBox(width: 6),
                      Icon(
                        Icons.check_circle,
                        size: 14,
                        color: Colors.green.shade700,
                      ),
                      Text(
                        ' 已安装',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.green.shade700,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${e.summary} · ${e.releaseDate} 发布 · 约 ${_formatGb(e.sizeGb)}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _fitBadge(r.fit),
          const SizedBox(width: 10),
          if (pulling && task != null) ...[
            SizedBox(
              width: 120,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(value: task.progress),
                  const SizedBox(height: 3),
                  Text(
                    task.progressText,
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: () => _pull.cancel(e.name),
              child: const Text('取消'),
            ),
          ] else if (queued)
            Row(
              children: [
                Text(
                  '排队中',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
                TextButton(
                  onPressed: () => _pull.cancel(e.name),
                  child: const Text('取消'),
                ),
              ],
            )
          else if (failed)
            FilledButton.tonal(
              onPressed: () => unawaited(_startPull(e.name)),
              child: const Text('重试'),
            )
          else
            FilledButton.tonal(
              onPressed: () => unawaited(_startPull(e.name)),
              child: Text(installed != null ? '重新拉取' : '安装'),
            ),
        ],
      ),
    );
  }

  /// 目录条目对应的已安装模型名（按 base 名匹配，兼容 :latest 别名）。
  String? _installedModelName(OllamaCatalogEntry e) {
    for (final m in _models) {
      if (m == e.name || m.split(':').first == e.baseName) return m;
    }
    return null;
  }

  Widget _fitBadge(OllamaModelFit fit) {
    final (Color color, String label) = switch (fit) {
      OllamaModelFit.smooth => (Colors.green.shade700, '流畅'),
      OllamaModelFit.usable => (Colors.teal.shade700, '可用'),
      OllamaModelFit.tight => (Colors.orange.shade800, '吃紧'),
      OllamaModelFit.cpuOk => (Colors.blue.shade700, 'CPU 可跑'),
      OllamaModelFit.tooHeavy => (Colors.grey.shade600, '不推荐'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, color: color)),
    );
  }

  Widget _customInstallRow() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _customModelCtrl,
            // 多任务队列：随时可再入队新模型，不再全局禁用。
            onSubmitted: (v) => unawaited(_startPull(v)),
            decoration: const InputDecoration(
              labelText: '自定义安装',
              hintText: '输入模型名（如 qwen3.5:4b），或直接粘贴 ollama pull 命令',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: () => unawaited(_startPull(_customModelCtrl.text)),
          icon: const Icon(Icons.download, size: 18),
          label: const Text('开始拉取'),
        ),
      ],
    );
  }

  /// 「已安装模型」区的一行：名称 + 磁盘占用/更新时间 + 删除按钮。
  Widget _installedRow(OllamaInstalledModel m) {
    final deleting = _deletingModel == m.name;
    // 该模型正在排队/拉取时不允许删（写入中删除会失败）。
    final busy = _deletingModel != null || _pull.isModelActive(m.name);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  m.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 2),
                Text(
                  '磁盘占用 ${OllamaPullManager.formatBytes(m.sizeBytes)}'
                  '${m.modifiedAt != null ? ' · ${_formatDate(m.modifiedAt!)} 更新' : ''}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: deleting ? '正在删除…' : '删除该模型（释放磁盘空间）',
            icon: deleting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.delete_outline, size: 18),
            color: Colors.red.shade700,
            onPressed: busy ? null : () => unawaited(_confirmDeleteModel(m)),
          ),
        ],
      ),
    );
  }

  /// 删除确认：列明体积与当前占用情况；被选为视觉/文本模型的删除后
  /// 自动清空对应槽位。
  Future<void> _confirmDeleteModel(OllamaInstalledModel m) async {
    final usedAs = <String>[
      if (_settings.visionModel == m.name) '视觉模型',
      if (_settings.textModel == m.name) '文本模型',
    ];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除模型 ${m.name}'),
        content: Text(
          '将从磁盘删除该模型（约 ${OllamaPullManager.formatBytes(m.sizeBytes)}）以释放空间，'
          '不影响其他模型。'
          '${usedAs.isNotEmpty ? '\n注意：它当前被选为${usedAs.join('与')}，删除后会自动清空该选择。' : ''}'
          '\n确定删除吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || _deletingModel != null) return;
    setState(() => _deletingModel = m.name);
    try {
      await OllamaService.deleteModel(_settings.baseUrl, m.name);
      if (!mounted) return;
      if (_settings.visionModel == m.name) {
        _update((s) => s.copyWith(visionModel: ''));
      }
      if (_settings.textModel == m.name) {
        _update((s) => s.copyWith(textModel: ''));
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已删除模型 ${m.name}（释放 ${OllamaPullManager.formatBytes(m.sizeBytes)}）',
          ),
        ),
      );
      await _refreshModels();
    } on OllamaException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _deletingModel = null);
    }
  }

  /// 深色终端风小型日志面板（拉取日志 / winget 安装日志共用）。
  Widget _miniLogPanel({
    required List<String> logs,
    required ScrollController controller,
  }) {
    return Container(
      height: 150,
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF101418),
        borderRadius: BorderRadius.circular(8),
      ),
      child: AttachedScrollbar(
        controller: controller,
        child: ListView.builder(
          controller: controller,
          itemCount: logs.length,
          itemBuilder: (context, index) => Text(
            logs[index],
            style: TextStyle(
              fontSize: 11,
              height: 1.5,
              color: logs[index].contains('[error]')
                  ? Colors.red.shade300
                  : const Color(0xFFC9D4DC),
            ),
          ),
        ),
      ),
    );
  }

  static String _formatGb(double gb) => gb % 1 == 0
      ? '${gb.toStringAsFixed(0)} GB'
      : '${gb.toStringAsFixed(1)} GB';

  static String _formatDate(DateTime d) {
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd';
  }

  Widget _modelCard() {
    final external = _settings.provider == AiProvider.externalApi;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.psychology_outlined, size: 20),
                const SizedBox(width: 8),
                const Text(
                  '模型选择',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '刷新模型列表',
                  onPressed: _loadingModels ? null : () => _refreshModels(),
                  icon: _loadingModels
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 20),
                ),
              ],
            ),
            if (_modelsError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _modelsError!,
                  style: TextStyle(fontSize: 12, color: Colors.orange.shade800),
                ),
              ),
            if (external) ...[
              _extSlotField(
                label: '视觉模型（单字辅助识别 · 整行裁决 · 识别框诊断）',
                providerId: _settings.effectiveVisionProviderId ?? '',
                model: _settings.extVisionModel,
                onProviderChanged: (pid) {
                  // 换供应商：原模型名大概率不属于新家，自动落到其首个模型。
                  final p = _settings.extProviderOf(pid);
                  final keep = p?.models.contains(_settings.extVisionModel) ?? false;
                  final first = (p?.models.isEmpty ?? true)
                      ? ''
                      : p!.models.first;
                  _update(
                    (s) => s.copyWith(
                      extVisionProviderId: pid,
                      extVisionModel: keep ? null : first,
                    ),
                  );
                },
                onModelChanged: (m) =>
                    _update((s) => s.copyWith(extVisionModel: m)),
              ),
              const SizedBox(height: 12),
              _extSlotField(
                label: '文本模型（标点辅助识别 · 整行裁决兜底）',
                providerId: _settings.effectiveTextProviderId ?? '',
                model: _settings.extTextModel.isEmpty
                    ? _settings.extVisionModel
                    : _settings.extTextModel,
                onProviderChanged: (pid) {
                  final p = _settings.extProviderOf(pid);
                  final keep = p?.models.contains(_settings.extTextModel) ?? false;
                  final first = (p?.models.isEmpty ?? true)
                      ? ''
                      : p!.models.first;
                  _update(
                    (s) => s.copyWith(
                      extTextProviderId: pid,
                      extTextModel: keep ? null : first,
                    ),
                  );
                },
                onModelChanged: (m) =>
                    _update((s) => s.copyWith(extTextModel: m)),
              ),
            ] else ...[
              _modelDropdown(
                label: '视觉模型（单字辅助识别 · 整行裁决 · 识别框诊断）',
                hint: '需要支持图像的模型，如 qwen3.5、qwen3-vl、minicpm-v 等',
                value: _settings.visionModel,
                onChanged: (v) =>
                    _update((s) => s.copyWith(visionModel: v ?? '')),
              ),
              const SizedBox(height: 12),
              _modelDropdown(
                label: '文本模型（标点辅助识别 · 整行裁决兜底）',
                hint: '纯文本模型即可，如 qwen3:8b、glm5 等',
                value: _settings.textModel,
                onChanged: (v) =>
                    _update((s) => s.copyWith(textModel: v ?? '')),
              ),
            ],
            if (_models.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  external
                      ? '模型下拉为空：到上方连接卡「测试连接并获取模型」，'
                            '再把拉到的模型加进该供应商；列表拉不到也可在'
                            '供应商卡里手动添加模型名。'
                      : '模型列表为空：请先点上方「测试连接并获取模型」；'
                            '若 Ollama 还没有模型，用上方「模型安装」卡选择推荐模型一键下载。',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 外部 API 的模型槽位：先选供应商，再从该供应商配好的模型里选一个。
  /// 槽位绑定（供应商 id + 模型名）决定该功能实际调用哪家的哪个模型；
  /// 上方还没配供应商/模型时给出引导。
  Widget _extSlotField({
    required String label,
    required String providerId,
    required String model,
    required ValueChanged<String> onProviderChanged,
    required ValueChanged<String> onModelChanged,
  }) {
    final providers = _settings.extProviders;
    final bound = _settings.extProviderOf(providerId);
    final models = bound?.models ?? const <String>[];
    // 已保存但不在供应商列表里的模型名也要出现在选项里，避免改设置丢配置。
    final items = [
      ...models,
      if (model.isNotEmpty && !models.contains(model)) model,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 13)),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              flex: 2,
              child: DropdownButtonFormField<String>(
                initialValue: providerId.isEmpty ? null : providerId,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: '供应商',
                  hintStyle: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade500,
                  ),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  for (final p in providers)
                    DropdownMenuItem(
                      value: p.id,
                      child: Text(p.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: providers.isEmpty
                    ? null
                    : (v) {
                        if (v != null) onProviderChanged(v);
                      },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 3,
              child: DropdownButtonFormField<String>(
                initialValue: model.isEmpty ? null : model,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: '模型',
                  hint: Text(
                    providers.isEmpty
                        ? '先在上方新增供应商'
                        : '该供应商还没有模型',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                  ),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  for (final m in items)
                    DropdownMenuItem(
                      value: m,
                      child: Text(m, overflow: TextOverflow.ellipsis),
                    ),
                ],
                // 没绑供应商或该供应商没有模型时禁用。
                onChanged: (bound == null || models.isEmpty)
                    ? null
                    : (v) {
                        if (v != null) onModelChanged(v);
                      },
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _modelDropdown({
    required String label,
    required String hint,
    required String value,
    required ValueChanged<String?> onChanged,
  }) {
    // 已保存但列表里没有的模型名也要出现在选项里，避免改设置时丢配置。
    final items = <String>[
      ..._models,
      if (value.isNotEmpty && !_models.contains(value)) value,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 13)),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          initialValue: value.isEmpty ? null : value,
          isExpanded: true,
          decoration: InputDecoration(
            hintText: hint,
            hintMaxLines: 2,
            hintStyle: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          items: [
            for (final m in items)
              DropdownMenuItem(
                value: m,
                child: Text(m, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _featureCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.tune, size: 20),
                const SizedBox(width: 8),
                const Text(
                  '功能开关',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('单字辅助识别', style: TextStyle(fontSize: 14)),
              subtitle: const Text(
                '编辑器里轻点字块时，候选条提供「AI 辅助识别」：把整行裁图（橙框标出该字）和行内上下文交给视觉模型补候选（汉字或标点：句读、括号、书名号、引号等）',
                style: TextStyle(fontSize: 12),
              ),
              value: _settings.enableCharAssist,
              onChanged: (v) => _update((s) => s.copyWith(enableCharAssist: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('标点辅助识别', style: TextStyle(fontSize: 14)),
              subtitle: const Text(
                '点开标点（小字框）时提供「AI 标点辅助」：结合前后文推荐句读',
                style: TextStyle(fontSize: 12),
              ),
              value: _settings.enablePunctAssist,
              onChanged: (v) =>
                  _update((s) => s.copyWith(enablePunctAssist: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('识别框检查', style: TextStyle(fontSize: 14)),
              subtitle: const Text(
                '编辑器「AI 检查识别框」：自动扫可疑行并重摆（几何修复无需 Ollama，'
                'AI 诊断需配置视觉模型）；重摆结果经识别置信度裁决，提升才采纳',
                style: TextStyle(fontSize: 12),
              ),
              value: _settings.enableBoxAssist,
              onChanged: (v) => _update((s) => s.copyWith(enableBoxAssist: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('AI 整页预标注', style: TextStyle(fontSize: 14)),
              subtitle: const Text(
                '编辑器主区视图「AI 整页预标注」：把整页图（带网格与已有区域底色）'
                '交给视觉模型判定页眉/页脚/页码/眉批/正文区，坐标经后端墨迹几何'
                '精修后落为待确认候选（永远不自动确认，不覆盖已有区域）',
                style: TextStyle(fontSize: 12),
              ),
              value: _settings.enablePagePrelabel,
              onChanged: (v) =>
                  _update((s) => s.copyWith(enablePagePrelabel: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('全本识别时启用 AI', style: TextStyle(fontSize: 14)),
              subtitle: const Text(
                '新建任务时复制到项目；整本/批量识别会按行结合字图、上下文和标点统一裁决，置信度低于 0.80 时回退 OCR',
                style: TextStyle(fontSize: 12),
              ),
              value: _settings.enableLineAssist,
              onChanged: (v) => _update((s) => s.copyWith(enableLineAssist: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                '本页或本行重新识别时启用 AI',
                style: TextStyle(fontSize: 14),
              ),
              subtitle: const Text(
                '仅在用户显式执行本页/本行重识别时启用整行裁决，不改变全本识别设置',
                style: TextStyle(fontSize: 12),
              ),
              value: _settings.enableManualLineAssist,
              onChanged: (v) =>
                  _update((s) => s.copyWith(enableManualLineAssist: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                '记录 AI 思维链（溯源）',
                style: TextStyle(fontSize: 14),
              ),
              subtitle: const Text(
                '整行三步分析时让推理模型输出思考过程，写进「AI 溯源」面板与'
                '对比页「AI 过程」；推理型模型耗时与 token 消耗会增加',
                style: TextStyle(fontSize: 12),
              ),
              value: _settings.enableAiThinking,
              onChanged: (v) => _update((s) => s.copyWith(enableAiThinking: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('自动应用识别框修复', style: TextStyle(fontSize: 14)),
              subtitle: const Text(
                'AI 检查完成后自动应用高可信空框删除、边界修正和双排拆分；'
                '只控制识别框修复，不会单独开启全页文字 AI；整轮修改可撤销',
                style: TextStyle(fontSize: 12),
              ),
              value: _settings.autoApplyBoxRepairs,
              onChanged: (v) =>
                  _update((s) => s.copyWith(autoApplyBoxRepairs: v)),
            ),
          ],
        ),
      ),
    );
  }

  // ── AI 并行度 ──

  String _parallelModeHint(String mode, bool stressFresh) {
    switch (AiParallelMode.normalize(mode)) {
      case AiParallelMode.maxPerf:
        return '用压测实测出的本机上限跑满队列（没测过按 8 条）；不给手动'
            '操作保留通道，队列跑动时编辑器操作可能需要排队';
      case AiParallelMode.lowVram:
        return '只用 2 条并行，显存占用最小；适合显存紧张或边跑队列边干别的';
      case AiParallelMode.manual:
        return '手动指定并行数，可填上限＝压测实测值（未压测时按显存保守'
            '估计${stressFresh ? '' : '，当前尚未压测'}）。点下方「测试并行数」'
            '实测——自动从 1 条逐档爬坡直到测出真实上限，测完自动放宽';
      case AiParallelMode.smart:
      default:
        return '压测过就按实测值跑'
            '${stressFresh ? '' : '（尚未压测，建议先测一次）'}，没测过按显存'
            '估算；并且永远给编辑器手动操作保留 1 条快速通道——'
            '后台跑整本识别/批量拆分时，你手动处理其他书页不被排队拖住';
    }
  }

  Widget _parallelCard() {
    final mode = AiParallelMode.normalize(_settings.aiParallelMode);
    final stress = _stressResult;
    final activeModel = _settings.activeVisionModel.isNotEmpty
        ? _settings.activeVisionModel
        : _settings.activeTextModel;
    final stressFresh = stress != null && stress.freshFor(activeModel);
    // 手动可填上限：压测过＝实测值，没测按显存启发（与解析层同一把
    // 尺，测完压测后面板自动放宽/收紧）。
    final manualCap = manualPermitCap(
      stress: stress,
      currentModel: activeModel,
      hasNvidiaGpu: _hardware.hasNvidiaGpu,
      vramTotalMb: _hardware.vramTotalMb,
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.speed, size: 20),
                SizedBox(width: 8),
                Text('AI 并行度', style: TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              '控制 AI 整行裁决（整本识别与按主区拆分）同时发出的行请求数',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            Wrap(
              children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: AiParallelMode.smart,
                      label: Text('智能'),
                    ),
                    ButtonSegment(
                      value: AiParallelMode.maxPerf,
                      label: Text('最大效能'),
                    ),
                    ButtonSegment(
                      value: AiParallelMode.lowVram,
                      label: Text('低显存'),
                    ),
                    ButtonSegment(
                      value: AiParallelMode.manual,
                      label: Text('手动'),
                    ),
                  ],
                  selected: {mode},
                  onSelectionChanged: (sel) =>
                      _update((s) => s.copyWith(aiParallelMode: sel.first)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _parallelModeHint(mode, stressFresh),
              style: const TextStyle(fontSize: 12, height: 1.5),
            ),
            if (mode == AiParallelMode.manual) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    tooltip: '减少 1',
                    onPressed: _settings.aiParallelManual <= 1
                        ? null
                        : () => _update(
                            (s) => s.copyWith(
                              aiParallelManual: s.aiParallelManual - 1,
                            ),
                          ),
                  ),
                  Text(
                    '${_settings.aiParallelManual} 条',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    tooltip: '增加 1',
                    onPressed: _settings.aiParallelManual >= manualCap
                        ? null
                        : () => _update(
                            (s) => s.copyWith(
                              aiParallelManual: s.aiParallelManual + 1,
                            ),
                          ),
                  ),
                  if (!stressFresh)
                    Text(
                      '上限 $manualCap 条${stress == null ? '（按显存估计，压测后放宽）' : '（上次结果已过期，建议重测）'}',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                ],
              ),
            ],
            // 面板级压测入口：四种模式共用——智能/最大效能直接采用实测
            // 值，手动档据此放宽可填上限；自动从 1 条爬坡直到测出上限。
            const SizedBox(height: 4),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _stressRunning ? null : _runStressTest,
                  icon: _stressRunning
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.bolt),
                  label: const Text('测试并行数'),
                ),
                if (stress != null) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '上次压测：并发 ${stress.maxStable} 条稳定 · ${stress.model}'
                      ' · ${stress.testedAt.toString().split('.').first}'
                      '${stressFresh ? '' : '（已过期或换过模型，建议重测）'}'
                      '${stress.abortedReason == null ? '' : ' · ${stress.abortedReason}'}',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _runStressTest() async {
    if (_stressRunning) return;
    final external = _settings.provider == AiProvider.externalApi;
    // 外部 API 只有指向本机环回（one-api/LiteLLM/llama.cpp server 等本地
    // 网关，如 http://127.0.0.1:9094/v1）才值得压测——瓶颈在本机、显存
    // 看门狗有效；真云端的并发由服务商限速控制，压测没有意义。
    if (external && !OllamaService.isLoopbackBaseUrl(_settings.extBaseUrl)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            '云端外部模型 API 不支持本测试——其并发由服务商限速控制；'
            '本机地址（如 http://127.0.0.1:9094/v1）可正常测试',
          ),
        ),
      );
      return;
    }
    final model = _settings.activeVisionModel.isNotEmpty
        ? _settings.activeVisionModel
        : _settings.activeTextModel;
    if (model.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先在「模型选择」里选一个模型再测试')));
      return;
    }
    _stressCancel = false;
    setState(() => _stressRunning = true);
    // 真实形态探针：先合成行图/字图（渲染一次、全档复用），失败直接
    // 退出不开进度框。
    Future<Duration?> Function() probe;
    try {
      probe = await AiStressProbe.realLine(_settings, model);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('生成压测用图失败：$e')),
        );
      }
      setState(() => _stressRunning = false);
      return;
    }
    if (!mounted) return;
    var progressMsg = '准备测试…';
    StateSetter? setDlg;
    final progressFuture = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: StatefulBuilder(
          builder: (dialogContext, setStateInDialog) {
            setDlg = setStateInDialog;
            return AlertDialog(
              title: const Text('测试并行数'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(progressMsg),
                  const SizedBox(height: 8),
                  const Text(
                    '先预热 1 条（含模型加载），再从 1 条逐档加并发，每档'
                    '发真实形态的行裁决请求（带合成图）；任一档失败/超时'
                    '或被排队串行即停；显存占用达 95% 或超过 10 分钟会自动'
                    '中止，不会压死机器',
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    _stressCancel = true;
                    Navigator.of(dialogContext).pop();
                  },
                  child: const Text('取消测试'),
                ),
              ],
            );
          },
        ),
      ),
    );
    final result = await AiStressTester.run(
      model: model,
      probe: probe,
      // 环回外部服务与本机 Ollama 同卡，显存看门狗对两者都有效。
      vramRatio: AiStressProbe.vramViaBackend,
      isCancelled: () => _stressCancel,
      onProgress: (p) {
        progressMsg = p.message;
        setDlg?.call(() {});
      },
    );
    // 用户没点取消时由这里关进度框（点了取消框已关，不能再 pop）。
    if (!_stressCancel && mounted) {
      Navigator.of(context).pop();
    }
    await progressFuture;
    await AiStressCache.save(result);
    AiRequestLimiter.instance.markStale();
    if (!mounted) return;
    // 新实测上限就是手动档新的可填上限：手填值超了就地收紧（面板立
    // 即反映，解析层的钳制兜底）。
    if (_settings.aiParallelManual > result.maxStable) {
      _update((s) => s.copyWith(aiParallelManual: result.maxStable));
    }
    setState(() {
      _stressResult = result;
      _stressRunning = false;
    });
    var apply = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('实测可稳定并行 ${result.maxStable} 条'),
        content: Text(
          '模型 ${result.model} 在本机的稳定并发上限为 ${result.maxStable} 条。'
          '${result.abortedReason == null ? '' : '\n${result.abortedReason}'}\n\n'
          '可一键按实测值设为手动并行数。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () {
              apply = true;
              Navigator.of(dialogContext).pop();
            },
            child: Text('应用为手动 ${result.maxStable} 条'),
          ),
        ],
      ),
    );
    if (apply && mounted) {
      _update(
        (s) => s.copyWith(
          aiParallelMode: AiParallelMode.manual,
          aiParallelManual: result.maxStable,
        ),
      );
    }
  }

  /// 识别进程数卡：Kraken daemon 池大小（首页"识别进程 x/y 路"）。
  /// 自动=按硬件决策；手动经 OCR_KRAKEN_WORKERS 覆盖（后端启动时生效，
  /// 「应用」立即重建池生效）；「测试进程数」逐档重建爬坡实测上限。
  Widget _krakenCard() {
    final stress = _krakenStress;
    final manual = _settings.krakenWorkers;
    final recognizing = RecognitionQueue.instance.isRunning;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.dns, size: 20),
                SizedBox(width: 8),
                Text('识别进程数', style: TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              '整行识别引擎（Kraken）的并行进程池——首页"识别进程 x/y 路"。'
              '进程越多整本识别越快，但显存占用越大；自动＝按显存与 CPU '
              '自动决策，手动＝固定进程数',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            Wrap(
              children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'auto',
                      label: Text('自动（按硬件）'),
                    ),
                    ButtonSegment(value: 'manual', label: Text('手动')),
                  ],
                  selected: {manual == null ? 'auto' : 'manual'},
                  onSelectionChanged: (sel) => _update(
                    (s) => s.copyWith(
                      // 切手动给个安全初值；切回 null 即恢复自动
                      krakenWorkers:
                          sel.first == 'manual' ? (s.krakenWorkers ?? 2) : null,
                    ),
                  ),
                ),
              ],
            ),
            if (manual != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    tooltip: '减少 1',
                    onPressed: manual <= 1
                        ? null
                        : () => _update(
                            (s) => s.copyWith(krakenWorkers: manual - 1),
                          ),
                  ),
                  Text(
                    '$manual 个',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    tooltip: '增加 1',
                    onPressed: manual >= krakenWorkersHardCap
                        ? null
                        : () => _update(
                            (s) => s.copyWith(krakenWorkers: manual + 1),
                          ),
                  ),
                  Text(
                    '上限 $krakenWorkersHardCap 个（后端同一上限）',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton.icon(
                  onPressed:
                      (_krakenApplying || recognizing) ? null : _applyKrakenPool,
                  icon: _krakenApplying
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  label: Text(
                    recognizing ? '识别进行中' : '应用并重建进程池',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    recognizing
                        ? '整本识别进行中，结束后才能重建进程池'
                        : '手动值随下次后端启动自动生效；「应用」立即重建'
                            '（逐个加载模型，需等约半分钟到几分钟）',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: (_krakenStressRunning || recognizing)
                      ? null
                      : _runKrakenStress,
                  icon: _krakenStressRunning
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.bolt),
                  label: const Text('测试进程数'),
                ),
                if (stress != null) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '上次压测：${stress.maxStable} 个进程稳定 · '
                      '${stress.testedAt.toString().split('.').first}'
                      '${stress.fresh ? '' : '（已过期，建议重测）'}'
                      '${stress.abortedReason == null ? '' : ' · ${stress.abortedReason}'}',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 立即按当前设置重建进程池（设置值已在，null=回硬件自动决策）。
  Future<void> _applyKrakenPool() async {
    if (_krakenApplying) return;
    setState(() => _krakenApplying = true);
    try {
      final r = await PythonService.resizeKrakenPool(_settings.krakenWorkers);
      if (!mounted) return;
      final size = (r['size'] as num?)?.toInt() ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('进程池已重建：当前 $size 个进程')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('重建失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _krakenApplying = false);
    }
  }

  /// 识别进程数压测：逐档把池重建到 k 个再发 k 路探针（每档要加载模型，
  /// 整轮数分钟）；测完池恢复原设置，实测值可一键应用为手动并重建。
  Future<void> _runKrakenStress() async {
    if (_krakenStressRunning) return;
    if (RecognitionQueue.instance.isRunning) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('整本识别进行中，结束后再测试')),
      );
      return;
    }
    // 探针样本图：从书库选一本有图的书（最近的优先）——识别进程压测
    // 需要一张真实页图走完整行识别链路；书库路径只有客户端知道。
    String? sampleImage;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final projects = await ProjectStorage.loadAll(
        p.join(docs.path, 'GujiBT'),
      );
      for (final pr in projects.reversed) {
        if (pr.imageFiles.isNotEmpty) {
          sampleImage = pr.imageFiles.first;
          break;
        }
      }
    } catch (_) {}
    if (!mounted) return;
    if (sampleImage == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('书库里没有带图片的书，无法测试进程数'
              '（先在书库导入至少一本书）'),
        ),
      );
      return;
    }
    _krakenStressCancel = false;
    setState(() => _krakenStressRunning = true);
    var progressMsg = '准备测试…';
    StateSetter? setDlg;
    final progressFuture = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: StatefulBuilder(
          builder: (dialogContext, setStateInDialog) {
            setDlg = setStateInDialog;
            return AlertDialog(
              title: const Text('测试进程数'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(progressMsg),
                  const SizedBox(height: 8),
                  const Text(
                    '每档先把进程池重建到 k 个（逐个加载模型，这一步较慢），'
                    '再同时发 k 路单行识别；某档失败或被排队串行即停；显存'
                    '占用达 95% 或超过 15 分钟自动中止。测完进程池恢复原设置',
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    _krakenStressCancel = true;
                    Navigator.of(dialogContext).pop();
                  },
                  child: const Text('取消测试'),
                ),
              ],
            );
          },
        ),
      ),
    );
    final restore = _settings.krakenWorkers;
    final result = await KrakenStressTester.run(
      sampleImage: sampleImage,
      restoreWorkers: restore,
      isCancelled: () => _krakenStressCancel,
      onProgress: (p) {
        progressMsg = p.message;
        setDlg?.call(() {});
      },
    );
    // 用户没点取消时由这里关进度框（点了取消框已关，不能再 pop）。
    if (!_krakenStressCancel && mounted) {
      Navigator.of(context).pop();
    }
    await progressFuture;
    if (!mounted) return;
    setState(() => _krakenStressRunning = false);
    if (result.maxStable == 0) {
      // 测试未能开始（预热探针失败/取消）："1 个"不是实测值——
      // 不缓存、不更新"上次压测"，只报真实原因。
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('测试未能开始'),
          content: Text(result.abortedReason ?? '未知原因'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
      return;
    }
    await KrakenStressCache.save(result);
    if (!mounted) return;
    setState(() {
      _krakenStress = result;
    });
    var apply = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('实测可稳定并行 ${result.maxStable} 个进程'),
        content: Text(
          '本机识别引擎的稳定进程数上限为 ${result.maxStable} 个。'
          '${result.abortedReason == null ? '' : '\n${result.abortedReason}'}\n\n'
          '可一键按实测值设为手动进程数并立即重建。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () {
              apply = true;
              Navigator.of(dialogContext).pop();
            },
            child: Text('应用为手动 ${result.maxStable} 个'),
          ),
        ],
      ),
    );
    if (apply && mounted) {
      _update((s) => s.copyWith(krakenWorkers: result.maxStable));
      unawaited(_applyKrakenPool());
    }
  }

  // ── PaddleOCR 模型管理（可选引擎）──

  Future<void> _loadPaddleStatus() async {
    try {
      final status = await PythonService.paddleStatus();
      if (!mounted) return;
      setState(() => _paddleStatus = status);
    } catch (_) {
      // 后端未就绪：保持 null，卡片降级提示（设置页常在后端冷启动时
      // 打开，不弹错误打扰）。
    }
  }

  Future<void> _downloadPaddleModel(PaddleModelChoice choice) async {
    if (_paddleDownloading.contains(choice.name)) return;
    setState(() => _paddleDownloading.add(choice.name));
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await PythonService.paddleDownload(choice.name);
      final cached = result['was_cached'] == true;
      final device = result['device']?.toString() ?? '';
      final elapsed = result['elapsed_s']?.toString() ?? '';
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${choice.displayLabel} ${cached ? '已在本机缓存，自检通过' : '下载完成'}'
            '${device.isEmpty ? '' : '（$device）'}'
            '${elapsed.isEmpty ? '' : '，用时 ${elapsed}s'}',
          ),
        ),
      );
      await _loadPaddleStatus();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('下载 ${choice.displayLabel} 失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _paddleDownloading.remove(choice.name));
    }
  }

  /// 每档模型行尾的下载区：已下载 ✓ / 未下载给「下载」按钮（含下载中
  /// 转圈态，逐档独立单飞）。
  Widget _paddleModelTrailing(PaddleModelChoice choice, Set<String> downloaded) {
    if (_paddleDownloading.contains(choice.name)) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 6),
          Text('下载中…', style: TextStyle(fontSize: 11)),
        ],
      );
    }
    if (downloaded.contains(choice.name)) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.check_circle,
            size: 16,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 4),
          const Text('已下载', style: TextStyle(fontSize: 11)),
        ],
      );
    }
    return TextButton.icon(
      onPressed: () => _downloadPaddleModel(choice),
      icon: const Icon(Icons.cloud_download_outlined, size: 16),
      label: const Text('下载'),
    );
  }

  /// PaddleOCR 模型卡：各档说明（体积 + 配置要求）、逐档下载与已下载
  /// 状态、默认档选择（全局默认 = 新建任务预填；每本书可在编辑器
  /// 「识别引擎（本书）」里单独覆盖）。
  Widget _paddleCard() {
    final status = _paddleStatus;
    final installed = status?['installed'] == true;
    final downloaded = <String>{
      for (final name in (status?['downloaded'] as List? ?? const []))
        name.toString(),
    };
    final poolModel = status?['current_model']?.toString() ?? '';
    final poolSize = (status?['pool_size'] as num?)?.toInt() ?? 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.auto_awesome_outlined, size: 20),
                SizedBox(width: 8),
                Text(
                  'PaddleOCR 模型（可选引擎）',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              '与 Kraken 二选一的识别引擎，每本书可选（编辑器「页面操作 → 识别'
              '引擎（本书）」切换）。识别模型三档，按电脑配置选档：点选即设为'
              '默认档（新建任务的初始选择）；未下载的档首次识别时也会自动下载',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 4),
            if (status == null)
              const Text(
                '· 后端未连接：暂无法检测环境与已下载状态（后端就绪后重进本页刷新）',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              )
            else if (!installed)
              Text(
                '· paddleocr 环境未安装：先到「环境准备」页安装 PaddleOCR 引擎'
                '（或运行 python_service\\install_paddleocr.bat），再回来下载模型',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.error,
                ),
              )
            else
              Text(
                '· 环境就绪${poolSize > 0 ? '；进程池已启动（当前 $poolModel，$poolSize 进程）' : '；进程池未启动（选用 PaddleOCR 的书首次识别时自动启动）'}',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            for (final choice in kPaddleModelChoices)
              ListTile(
                leading: Icon(
                  _settings.paddleModel == choice.name
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: _settings.paddleModel == choice.name
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                title: Text(choice.displayLabel),
                subtitle: Text(
                  choice.requirement,
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: _paddleModelTrailing(choice, downloaded),
                dense: true,
                onTap: () => _update(
                  (s) => s.copyWith(paddleModel: choice.name),
                ),
              ),
            const Padding(
              padding: EdgeInsets.only(left: 4, top: 2),
              child: Text(
                '默认档只影响新建任务的初始选择；已建书籍用各自的设置（编辑器'
                '里可随时改）。下载体积 4MB~73MB（VL 档约 1.9GB），来自 PaddleOCR 官方源',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _helpCard() {
    return Card(
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.info_outline, size: 18, color: Colors.grey.shade700),
                const SizedBox(width: 8),
                Text(
                  '说明',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '· AI 辅助默认走本机或局域网的 Ollama 服务；也可切到「外部模型 API」'
              '配置多家供应商（智谱 GLM、DeepSeek、Kimi、通义、SiliconFlow、'
              'OpenAI、自建网关等，OpenAI 兼容协议），每家各自填地址与密钥、'
              '维护模型列表；视觉与文本槽位可分别选「某家供应商的某个模型」。'
              '两种来源各记一份配置，随时切换。\n'
              '· 识别结果只作为候选建议，不会自动改动已确认的文字。\n'
              '· 本地模式：没有安装 Ollama 时可直接点连接卡里的「一键安装 Ollama」；'
              '模型在「模型安装」卡按本机配置推荐并一键下载，也可自己粘贴模型名/命令。\n'
              '· 外部模式：视觉类辅助（单字识别/整行裁决/识别框诊断）会把裁出的'
              '字图与行图上传给所选供应商，请在可接受的前提下使用；密钥只存本机。\n'
              '· Ollama 明明在运行却总提示「无法连接」？可能是开机时 Windows 把'
              '端口保留给了 Hyper-V/WSL（服务端绑定被系统拒绝），连接卡里点'
              '「抢回端口」可一键修复。\n'
              '· 单字识别质量主要取决于视觉模型：本地显存够用时优先选更大的多模态'
              '模型（如 qwen3.5 系列）；标点辅助用小文本模型即可；外部 API 的'
              '大杯视觉模型（如 glm-4.5v、gpt-4o 系列）通常明显强于本地小模型。',
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
                color: Colors.grey.shade700,
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ChangelogPage(),
                  ),
                ),
                icon: const Icon(Icons.history_edu, size: 18),
                label: const Text('GitHub 更新日志'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
