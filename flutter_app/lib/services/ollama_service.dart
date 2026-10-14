import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart' show RegionLabel;
import 'ai_concurrency.dart';
import 'isolate_codec.dart';

/// AI 辅助的推理来源：本地 Ollama 服务，或外部模型 API（OpenAI
/// Chat Completions 兼容协议，覆盖智谱 GLM、DeepSeek、Kimi、通义、
/// SiliconFlow、OpenAI 等服务商）。
enum AiProvider {
  localOllama('local'),
  externalApi('external');

  const AiProvider(this.wire);

  /// 持久化用的字符串标识。
  final String wire;

  static AiProvider fromWire(String? s) => s == AiProvider.externalApi.wire
      ? AiProvider.externalApi
      : AiProvider.localOllama;

  /// 设置页等处的显示名。
  String get label => this == AiProvider.localOllama ? '本地 Ollama' : '外部模型 API';
}

/// 外部模型 API 的服务商预设：选中和填好 base URL，模型名从各自控制台
/// 获取后填入（或用「测试连接并获取模型」直接拉取列表）。
class ExternalApiPreset {
  const ExternalApiPreset(
    this.name,
    this.baseUrl,
    this.visionHint,
    this.textHint,
  );

  /// 显示名（下拉选项）。
  final String name;

  /// API 根地址（填到 /v1 这一级，不含 /chat/completions）。
  final String baseUrl;

  /// 视觉模型名示例（占位提示，以各控制台实际可用为准）。
  final String visionHint;

  /// 文本模型名示例（占位提示，以各控制台实际可用为准）。
  final String textHint;
}

const List<ExternalApiPreset> externalApiPresets = [
  ExternalApiPreset(
    '智谱 GLM',
    'https://open.bigmodel.cn/api/paas/v4',
    'glm-4.5v',
    'glm-4.5',
  ),
  ExternalApiPreset(
    'DeepSeek',
    'https://api.deepseek.com/v1',
    '（以模型列表为准）',
    'deepseek-chat',
  ),
  ExternalApiPreset(
    'Kimi（月之暗面）',
    'https://api.moonshot.cn/v1',
    '（以模型列表为准）',
    'kimi-latest',
  ),
  ExternalApiPreset(
    '通义千问（阿里）',
    'https://dashscope.aliyuncs.com/compatible-mode/v1',
    'qwen-vl-max',
    'qwen-plus',
  ),
  ExternalApiPreset(
    'SiliconFlow 硅基流动',
    'https://api.siliconflow.cn/v1',
    'Qwen/Qwen2.5-VL-32B-Instruct',
    'deepseek-ai/DeepSeek-V3',
  ),
  ExternalApiPreset(
    'OpenAI',
    'https://api.openai.com/v1',
    'gpt-4o-mini',
    'gpt-4o-mini',
  ),
  ExternalApiPreset('自定义', '', '', ''),
];

/// 外部模型供应商的一份完整配置（OpenAI 兼容 API）：名称、地址、密钥，
/// 以及在该供应商下配好的模型名列表。可同时配置多家（智谱、DeepSeek、
/// 自建 one-api 网关……），视觉/文本槽位各自绑定其中一家与一个模型。
class ExternalApiProvider {
  const ExternalApiProvider({
    required this.id,
    required this.name,
    this.baseUrl = '',
    this.apiKey = '',
    this.models = const [],
  });

  /// 稳定唯一 id（创建时生成）：槽位绑定与激活选择都引用它，改名不变。
  final String id;

  /// 显示名（下拉与徽章）。
  final String name;

  /// API 根地址（填到 /v1 这一级，不含 /chat/completions）。
  final String baseUrl;

  /// API 密钥（Bearer）。随配置明文存本机 SharedPreferences。
  final String apiKey;

  /// 该供应商下配置好的模型名（手动添加或从 GET /models 拉取勾选）。
  final List<String> models;

  /// 生成新的供应商 id：时间戳 + 随机尾，本地唯一即可。
  static String newId() {
    final rnd = math.Random();
    return 'p${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
        '${rnd.nextInt(0x10000).toRadixString(36).padLeft(4, '0')}';
  }

  ExternalApiProvider copyWith({
    String? name,
    String? baseUrl,
    String? apiKey,
    List<String>? models,
  }) => ExternalApiProvider(
    id: id,
    name: name ?? this.name,
    baseUrl: baseUrl ?? this.baseUrl,
    apiKey: apiKey ?? this.apiKey,
    models: models ?? this.models,
  );

  factory ExternalApiProvider.fromJson(Map<String, dynamic> j) =>
      ExternalApiProvider(
        id: j['id']?.toString() ?? '',
        name: j['name']?.toString() ?? '',
        baseUrl: j['base_url']?.toString() ?? '',
        apiKey: j['api_key']?.toString() ?? '',
        models: [
          for (final raw in (j['models'] as List? ?? const []))
            if (raw.toString().trim().isNotEmpty) raw.toString().trim(),
        ],
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'base_url': baseUrl,
    'api_key': apiKey,
    'models': models,
  };
}

/// 一次外部 API 调用解析出的完整端点：地址 + 密钥 + 模型名。传输层
/// （_chatExternal / 模型列表）只依赖它，不感知多供应商结构。
class ExternalEndpoint {
  const ExternalEndpoint({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });

  final String baseUrl;
  final String apiKey;
  final String model;
}

/// Ollama AI 辅助的本地配置（首页「AI 辅助设置」页读写）。
class OllamaSettings {
  /// Ollama 服务地址（含端口，不带末尾斜杠）。
  final String baseUrl;

  /// 视觉模型（qwen3.5 之类）：单字辅助识别、整行裁决、识别框诊断都用它；
  /// 空 = 相关功能提示先到「AI 辅助设置」选择。
  final String visionModel;

  /// 文本模型：标点辅助识别（按前后文推荐句读）；整行裁决仅在无视觉模型时兜底。
  final String textModel;

  /// 字框轻点后的候选条里提供「AI 辅助识别」。
  final bool enableCharAssist;

  /// 标点字框（小字文本/标点文本）提供「AI 标点辅助」（按上下文推荐）。
  final bool enablePunctAssist;

  /// 「AI 检查识别框」：按本机几何信号 + 视觉模型诊断可疑行并重摆。
  /// 几何修复不需要 Ollama；视觉诊断需要视觉模型。默认关。
  final bool enableBoxAssist;

  /// 「AI 整页预标注」：编辑器 region 视图按页把版面区候选（页眉/页脚/
  /// 页码/眉批/正文）交给视觉模型判定，坐标经后端几何精修后落为
  /// proposed 区域。默认关。
  final bool enablePagePrelabel;

  /// AI 自动参与整本/本行识别；全局默认关闭，项目创建时复制为项目设置。
  final bool enableLineAssist;

  /// 用户显式执行“本行重新识别”时启用整行 AI；默认关闭。
  final bool enableManualLineAssist;
  final bool autoApplyBoxRepairs;

  /// 整行三步分析时记录模型思维链进溯源（推理模型耗时与 token 略增）；
  /// 默认开启——溯源面板的「思考过程」依赖它。
  final bool enableAiThinking;

  /// 推理来源：本地 Ollama 或外部模型 API（各保留一份配置，可随时切换）。
  final AiProvider provider;

  /// 外部模型供应商列表（支持多家并存，各家各配地址/密钥/模型）。
  final List<ExternalApiProvider> extProviders;

  /// 当前激活的外部供应商 id（设置页的编辑目标；槽位未绑供应商时的
  /// 回退）。空 = 无供应商或取第一个。
  final String activeExtProviderId;

  /// 视觉/文本槽位绑定的外部供应商 id；空 = 回退激活供应商（旧配置
  /// 迁移后即此形态，行为与单供应商时代一致）。
  final String extVisionProviderId;
  final String extTextProviderId;

  /// 外部 API 的视觉模型名（如 glm-4.5v、gpt-4o-mini）。
  final String extVisionModel;

  /// 外部 API 的文本模型名。
  final String extTextModel;

  /// AI 请求并行度模式：smart（智能，压测结果优先、硬件启发兜底、给
  /// 交互留通道）/ maxPerf（最大效能，用压测实测上限）/ lowVram（低显存，
  /// 恒 2）/ manual（手动取 [aiParallelManual]，上限跟压测实测值走）。
  /// 词表见 [AiParallelMode]；默认智能。
  final String aiParallelMode;

  /// 手动并行度的取值（1~压测实测上限，未测按显存启发；越界钳制）。
  final int aiParallelManual;

  /// 识别进程数（Kraken 整行识别引擎的 daemon 池大小）。null = 自动按
  /// 硬件决策（显存预算+CPU 核数）；非空经 OCR_KRAKEN_WORKERS 传给后端
  /// 覆盖自动决策（后端钳 1..12）。压测（KrakenStressCache）实测后建议值。
  final int? krakenWorkers;

  /// PaddleOCR 引擎的默认识别模型档（PP-OCRv6_*_rec）。全局默认：新建
  /// 任务预填此档；每本书的 project.json settings.paddle_model 可单独
  /// 覆盖（编辑器「识别引擎（本书）」）。词表与后端 paddle_proc 同源。
  final String paddleModel;

  /// copyWith 的"未传"哨兵：krakenWorkers 可空，需区分"不改"与"改回 null"。
  static const Object _unset = Object();

  const OllamaSettings({
    this.baseUrl = defaultBaseUrl,
    this.visionModel = '',
    this.textModel = '',
    this.enableCharAssist = true,
    this.enablePunctAssist = true,
    this.enableBoxAssist = false,
    this.enablePagePrelabel = false,
    this.enableLineAssist = false,
    this.enableManualLineAssist = false,
    this.autoApplyBoxRepairs = true,
    this.enableAiThinking = true,
    this.provider = AiProvider.localOllama,
    this.extProviders = const [],
    this.activeExtProviderId = '',
    this.extVisionProviderId = '',
    this.extTextProviderId = '',
    this.extVisionModel = '',
    this.extTextModel = '',
    this.aiParallelMode = AiParallelMode.smart,
    this.aiParallelManual = 3,
    this.krakenWorkers,
    this.paddleModel = 'PP-OCRv6_small_rec',
  });

  static const String defaultBaseUrl = 'http://localhost:11434';
  static const String _prefsKey = 'ollama_settings_v1';

  factory OllamaSettings.fromJson(Map<String, dynamic> j) {
    var providers = [
      for (final raw in (j['ext_providers'] as List? ?? const []))
        if (raw is Map)
          ExternalApiProvider.fromJson(Map<String, dynamic>.from(raw)),
    ];
    // 旧版单供应商配置（ext_base_url/ext_api_key 平铺）迁移为第一家
    // 供应商，模型槽位照旧——升级后行为无缝衔接。
    if (providers.isEmpty) {
      final legacyUrl = ((j['ext_base_url'] as String?) ?? '').trim();
      if (legacyUrl.isNotEmpty) {
        final vision = ((j['ext_vision_model'] as String?) ?? '').trim();
        final text = ((j['ext_text_model'] as String?) ?? '').trim();
        providers = [
          ExternalApiProvider(
            id: ExternalApiProvider.newId(),
            name: _legacyProviderName(legacyUrl),
            baseUrl: legacyUrl,
            apiKey: ((j['ext_api_key'] as String?) ?? '').trim(),
            models: [
              if (vision.isNotEmpty) vision,
              if (text.isNotEmpty && text != vision) text,
            ],
          ),
        ];
      }
    }
    // 激活供应商：存了 id 且仍存在则用之，否则取第一个。
    final storedActiveId = (j['ext_active_provider'] as String?) ?? '';
    final activeId = providers.any((p) => p.id == storedActiveId)
        ? storedActiveId
        : (providers.isEmpty ? '' : providers.first.id);
    // 槽位绑定的供应商空/失效时归一到激活供应商（解析层也做同样回退，
    // 这里归一是为了让落盘的配置自描述、不依赖解析层兜底）。
    String normalizeSlot(String id) =>
        providers.any((p) => p.id == id) ? id : activeId;
    return OllamaSettings(
      baseUrl: (j['base_url'] as String?)?.trim().isNotEmpty == true
          ? (j['base_url'] as String).trim()
          : defaultBaseUrl,
      visionModel: j['vision_model'] as String? ?? '',
      textModel: j['text_model'] as String? ?? '',
      enableCharAssist: j['enable_char_assist'] as bool? ?? true,
      enablePunctAssist: j['enable_punct_assist'] as bool? ?? true,
      enableBoxAssist: j['enable_box_assist'] as bool? ?? false,
      enablePagePrelabel: j['enable_page_prelabel'] as bool? ?? false,
      enableLineAssist: j['enable_line_assist'] as bool? ?? false,
      enableManualLineAssist: j['enable_manual_line_assist'] as bool? ?? false,
      autoApplyBoxRepairs: j['auto_apply_box_repairs'] as bool? ?? true,
      enableAiThinking: j['enable_ai_thinking'] as bool? ?? true,
      provider: AiProvider.fromWire(j['ai_provider'] as String?),
      extProviders: providers,
      activeExtProviderId: activeId,
      extVisionProviderId: normalizeSlot(
        (j['ext_vision_provider'] as String?) ?? '',
      ),
      extTextProviderId: normalizeSlot((j['ext_text_provider'] as String?) ?? ''),
      extVisionModel: (j['ext_vision_model'] as String?) ?? '',
      extTextModel: (j['ext_text_model'] as String?) ?? '',
      aiParallelMode: AiParallelMode.normalize(j['ai_parallel_mode'] as String?),
      aiParallelManual: (j['ai_parallel_manual'] as num?)?.toInt() ?? 3,
      krakenWorkers: (j['kraken_workers'] as num?)?.toInt(),
      // 未知/历史脏值归一到默认档（与后端 paddle_proc.normalize_model
      // 同口径；三档词表见 engine_settings_section.kPaddleModelChoices）。
      paddleModel: _normalizePaddleModel(j['paddle_model'] as String?),
    );
  }

  /// paddle 模型档位归一：空或未知名回落默认小档。
  static String _normalizePaddleModel(String? value) {
    const known = {
      'PP-OCRv6_tiny_rec',
      'PP-OCRv6_small_rec',
      'PP-OCRv6_medium_rec',
      'PP-OCRv3_mobile_rec',
      'PaddleOCR-VL-1.6',
    };
    final v = (value ?? '').trim();
    return known.contains(v) ? v : 'PP-OCRv6_small_rec';
  }

  /// 旧版平铺地址 → 供应商显示名：命中预设用预设名，否则按自定义。
  static String _legacyProviderName(String baseUrl) {
    for (final p in externalApiPresets) {
      if (p.name != '自定义' && p.baseUrl == baseUrl) return p.name;
    }
    return '自定义供应商';
  }

  Map<String, dynamic> toJson() => {
    'base_url': baseUrl,
    'vision_model': visionModel,
    'text_model': textModel,
    'enable_char_assist': enableCharAssist,
    'enable_punct_assist': enablePunctAssist,
    'enable_box_assist': enableBoxAssist,
    'enable_page_prelabel': enablePagePrelabel,
    'enable_line_assist': enableLineAssist,
    'enable_manual_line_assist': enableManualLineAssist,
    'auto_apply_box_repairs': autoApplyBoxRepairs,
    'enable_ai_thinking': enableAiThinking,
    'ai_provider': provider.wire,
    // 平铺的地址/密钥继续写激活供应商的值：回滚旧版本也不丢配置。
    'ext_base_url': extBaseUrl,
    'ext_api_key': extApiKey,
    'ext_vision_model': extVisionModel,
    'ext_text_model': extTextModel,
    'ext_providers': [for (final p in extProviders) p.toJson()],
    'ext_active_provider': activeExtProviderId,
    'ext_vision_provider': extVisionProviderId,
    'ext_text_provider': extTextProviderId,
    'ai_parallel_mode': aiParallelMode,
    'ai_parallel_manual': aiParallelManual,
    'kraken_workers': krakenWorkers,
    'paddle_model': paddleModel,
  };

  static Future<OllamaSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return const OllamaSettings();
    try {
      return OllamaSettings.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      return const OllamaSettings();
    }
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(toJson()));
  }

  OllamaSettings copyWith({
    String? baseUrl,
    String? visionModel,
    String? textModel,
    bool? enableCharAssist,
    bool? enablePunctAssist,
    bool? enableBoxAssist,
    bool? enablePagePrelabel,
    bool? enableLineAssist,
    bool? enableManualLineAssist,
    bool? autoApplyBoxRepairs,
    bool? enableAiThinking,
    AiProvider? provider,
    List<ExternalApiProvider>? extProviders,
    String? activeExtProviderId,
    String? extVisionProviderId,
    String? extTextProviderId,
    String? extVisionModel,
    String? extTextModel,
    String? aiParallelMode,
    int? aiParallelManual,
    Object? krakenWorkers = _unset,
    String? paddleModel,
  }) => OllamaSettings(
    baseUrl: baseUrl ?? this.baseUrl,
    visionModel: visionModel ?? this.visionModel,
    textModel: textModel ?? this.textModel,
    enableCharAssist: enableCharAssist ?? this.enableCharAssist,
    enablePunctAssist: enablePunctAssist ?? this.enablePunctAssist,
    enableBoxAssist: enableBoxAssist ?? this.enableBoxAssist,
    enablePagePrelabel: enablePagePrelabel ?? this.enablePagePrelabel,
    enableLineAssist: enableLineAssist ?? this.enableLineAssist,
    enableManualLineAssist:
        enableManualLineAssist ?? this.enableManualLineAssist,
    autoApplyBoxRepairs: autoApplyBoxRepairs ?? this.autoApplyBoxRepairs,
    enableAiThinking: enableAiThinking ?? this.enableAiThinking,
    provider: provider ?? this.provider,
    extProviders: extProviders ?? this.extProviders,
    activeExtProviderId: activeExtProviderId ?? this.activeExtProviderId,
    extVisionProviderId: extVisionProviderId ?? this.extVisionProviderId,
    extTextProviderId: extTextProviderId ?? this.extTextProviderId,
    extVisionModel: extVisionModel ?? this.extVisionModel,
    extTextModel: extTextModel ?? this.extTextModel,
    aiParallelMode: aiParallelMode != null
        ? AiParallelMode.normalize(aiParallelMode)
        : this.aiParallelMode,
    aiParallelManual: aiParallelManual ?? this.aiParallelManual,
    krakenWorkers: krakenWorkers == _unset
        ? this.krakenWorkers
        : krakenWorkers as int?,
    paddleModel: paddleModel == null
        ? this.paddleModel
        : _normalizePaddleModel(paddleModel),
  );

  /// 按 id 查供应商（不存在为 null）。
  ExternalApiProvider? extProviderOf(String id) {
    for (final p in extProviders) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 激活的外部供应商：存的 id 失效时回退第一个；无供应商为 null。
  ExternalApiProvider? get activeExtProvider =>
      extProviderOf(activeExtProviderId) ??
      (extProviders.isEmpty ? null : extProviders.first);

  /// 兼容读：激活供应商的地址/密钥（单供应商时代的等价口径，压测的
  /// 环回判断与提示文案仍用）。
  String get extBaseUrl => activeExtProvider?.baseUrl ?? '';
  String get extApiKey => activeExtProvider?.apiKey ?? '';

  /// 槽位绑定 id 实际生效的供应商 id：绑定空/失效回退激活供应商。
  String? get effectiveVisionProviderId =>
      _effectiveProviderId(extVisionProviderId);

  /// 文本槽位同款。
  String? get effectiveTextProviderId =>
      _effectiveProviderId(extTextProviderId);

  String? _effectiveProviderId(String id) =>
      extProviderOf(id)?.id ?? activeExtProvider?.id;

  /// 外部视觉槽位的调用端点：绑定供应商（空/失效回退激活供应商）的
  /// 地址密钥 + 槽位模型名。模型未配或无可用供应商为 null。
  ExternalEndpoint? resolveVisionEndpoint() =>
      _resolveEndpoint(extVisionProviderId, extVisionModel);

  /// 外部文本槽位的调用端点；文本模型空时视觉槽兜底（与
  /// [activeTextModel] 同口径）。
  ExternalEndpoint? resolveTextEndpoint() {
    final direct = _resolveEndpoint(extTextProviderId, extTextModel);
    if (direct != null) return direct;
    return _resolveEndpoint(extVisionProviderId, extVisionModel);
  }

  /// 按 [model] 名解析端点：先精确匹配视觉/文本槽位（两槽可绑不同
  /// 供应商），都不匹配时视觉槽优先、文本槽兜底。
  ExternalEndpoint? resolveEndpointForModel(String model) {
    if (model.isNotEmpty) {
      if (model == extVisionModel) {
        final e = _resolveEndpoint(extVisionProviderId, extVisionModel);
        if (e != null) return e;
      }
      if (model == extTextModel) {
        final e = _resolveEndpoint(extTextProviderId, extTextModel);
        if (e != null) return e;
      }
    }
    return resolveVisionEndpoint() ?? resolveTextEndpoint();
  }

  ExternalEndpoint? _resolveEndpoint(String providerId, String model) {
    final m = model.trim();
    if (m.isEmpty) return null;
    final p = extProviderOf(providerId) ?? activeExtProvider;
    if (p == null || p.baseUrl.trim().isEmpty) return null;
    return ExternalEndpoint(baseUrl: p.baseUrl, apiKey: p.apiKey, model: m);
  }

  /// 标点辅助实际使用的模型：文本模型优先，其次视觉模型。
  String get effectiveTextModel =>
      textModel.isNotEmpty ? textModel : visionModel;

  /// 当前提供方实际使用的视觉模型（本地/外部各记一份配置）。
  String get activeVisionModel =>
      provider == AiProvider.externalApi ? extVisionModel : visionModel;

  /// 当前提供方实际使用的文本模型：文本槽优先，空则视觉槽兜底。
  String get activeTextModel => provider == AiProvider.externalApi
      ? (extTextModel.isNotEmpty ? extTextModel : extVisionModel)
      : effectiveTextModel;

  /// 往当前提供方的视觉槽位写模型名（对比页逐模型注入用）；外部模式
  /// 可同时绑定供应商 [extProviderId]，不传则保留原绑定（解析时回退
  /// 激活供应商）。
  OllamaSettings withVisionModel(String model, {String? extProviderId}) =>
      provider == AiProvider.externalApi
      ? copyWith(extVisionModel: model, extVisionProviderId: extProviderId)
      : copyWith(visionModel: model);

  /// 往当前提供方的文本槽位写模型名；[extProviderId] 同上。
  OllamaSettings withTextModel(String model, {String? extProviderId}) =>
      provider == AiProvider.externalApi
      ? copyWith(extTextModel: model, extTextProviderId: extProviderId)
      : copyWith(textModel: model);

  /// 连接可用 + 至少选了（或能自动落到）一个模型。
  bool get configured => provider == AiProvider.externalApi
      ? extBaseUrl.trim().isNotEmpty
      : baseUrl.isNotEmpty;
}

/// 单条 AI 候选（单字或标点）。
class OllamaSuggestion {
  final String text;
  final double score;
  final String reason;

  const OllamaSuggestion({
    required this.text,
    required this.score,
    this.reason = '',
  });
}

/// 一次 AI 辅助调用的过程记录（「AI 模型对比」页展示用）：把可变实例
/// 经四个辅助函数的 `trace` 参数传入，调用完成后可读到实际使用的模型
/// （整行裁决含 vision→text 回退）、发送的完整 prompt 与图像、模型
/// 原始返回和总耗时。不传则完全不影响原行为。
/// AI 整页预标注输出的单个版面区候选（归一化坐标 0~1，相对整页）。
class OllamaPageRegion {
  const OllamaPageRegion({
    required this.label,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });

  final String label;
  final double x, y, w, h;
}

class OllamaPagePrelabel {
  const OllamaPagePrelabel({required this.regions, required this.rawContent});

  final List<OllamaPageRegion> regions;

  /// 模型原始返回（报告对话框/排障用）。
  final String rawContent;
}

/// AI 画框测试的坐标口径：素材图像素（测 VLM 裸像素定位）或归一化 0~1
/// （与版面预标注同口径，对照两种提示方式的差距）。
enum AiBoxCoordMode {
  materialPixel('素材图像素'),
  normalized('归一化 0~1');

  const AiBoxCoordMode(this.label);

  final String label;
}

/// AI 画框测试输出的单个字框候选。坐标保持在模型输出的口径空间
/// （[AiBoxCoordMode]），换算回原图像素由编排层（ai_char_boxes.dart）做。
class OllamaCharBox {
  const OllamaCharBox({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
  });

  final double x1, y1, x2, y2;
}

class OllamaCharBoxes {
  const OllamaCharBoxes({
    required this.boxes,
    required this.rawContent,
    required this.truncated,
  });

  final List<OllamaCharBox> boxes;

  /// 模型原始返回（原始 JSON 面板/排障用）。
  final String rawContent;

  /// JSON 未闭合（num_predict 或超时把输出截断）时为 true——已闭合的
  /// 框已经打捞出来可用，页面以此提示"已收 N 框（不完整）"。
  final bool truncated;
}

class OllamaTrace {
  /// 实际执行本次推理的模型（回退逻辑解析后的名字）。
  String model = '';

  /// 发送给模型的完整 prompt 文本。
  String prompt = '';

  /// 随 prompt 附带的图像（base64 PNG），纯文本任务为 null。
  /// 多图任务（整行三步分析）只放首图，全部图像看 [images]。
  String? imageBase64;

  /// 随 prompt 附带的全部图像（base64 PNG），按发送顺序；单图/纯文本
  /// 任务为空列表。
  List<String> images = const [];

  /// 模型不支持图像（400 multimodal），已自动去图按纯上下文重试：
  /// 结果只反映模型的文字判断，没有看字。false 或 null 图像时无意义。
  bool imageDropped = false;

  /// 模型思维链（对比页开启 wantThinking 时）：Ollama 的 message.thinking
  /// 或外部 API 的 reasoning_content / reasoning.summary。模型未输出时为空。
  String thinking = '';

  /// 模型原始返回（解析前的 content）。
  String rawContent = '';

  /// 调用总耗时（毫秒，含网络；解析失败也会填）。
  int elapsedMs = 0;
}

/// 发送给整行裁决模型的上下文项。
class AiContextItem {
  const AiContextItem({
    required this.order,
    required this.text,
    this.confidence = 0,
    this.agree = '',
    this.punctuation = false,
    this.scope = 'current',
  });

  final int order;
  final String text;
  final double confidence;
  final String agree;
  final bool punctuation;

  /// current / before / after; keeps context characters out of the target
  /// line even when their numeric order happens to overlap.
  final String scope;
}

class AiLineItem {
  const AiLineItem({
    required this.order,
    required this.text,
    required this.confidence,
    this.reason = '',
    this.punctuation = false,
    this.candidates = const [],
    this.cropIssue,
    this.cropNote = '',
  });

  final int order;
  final String text;
  final double confidence;
  final String reason;
  final bool punctuation;

  /// AI 给出的逐字候选（按可能性排序，去重、已过字符集校验）。
  final List<OllamaSuggestion> candidates;

  /// AI 判断的裁切问题：char_clipped / char_merged / char_extra_ink；
  /// null = AI 认为该字框裁切无问题。
  final String? cropIssue;

  /// 裁切问题的一句话说明（AI note 字段）。
  final String cropNote;
}

/// 整行三步分析里 AI 可报告的裁切问题白名单（与框诊断菜单同词表）。
const Set<String> kAiCropIssues = {
  'char_clipped',
  'char_merged',
  'char_extra_ink',
};

class AiLineDecision {
  const AiLineDecision({
    required this.lineText,
    required this.confidence,
    required this.items,
  });

  final String lineText;
  final double confidence;
  final List<AiLineItem> items;

  bool get eligible => confidence >= 0.80 && lineText.isNotEmpty;
}

/// 一个已安装（或下载中缓存）的本地模型，GET /api/tags 返回的信息。
class OllamaInstalledModel {
  const OllamaInstalledModel({
    required this.name,
    required this.sizeBytes,
    required this.modifiedAt,
  });

  /// 模型名（含 tag，如 'qwen3.5:4b'）。
  final String name;

  /// 磁盘占用（字节）。
  final int sizeBytes;

  /// 最后更新时间（Ollama 记录的拉取/修改时间），解析失败为 null。
  final DateTime? modifiedAt;
}

/// /api/pull 的一条进度快照（已聚合所有层）。
class OllamaPullEvent {
  const OllamaPullEvent({
    required this.model,
    required this.completedBytes,
    required this.totalBytes,
    required this.status,
    this.done = false,
    this.error = '',
  });

  final String model;

  /// 按 digest 聚合后的整体已下载字节（多层之间不回跳）。
  final int completedBytes;

  /// 聚合后的总体积（仅含已报告 total 的层，下载早期可能偏小）。
  final int totalBytes;

  /// 最近一条状态文本（原始英文，如 "pulling manifest"）。
  final String status;

  /// true = 下载成功（或失败，看 [error]），流即将结束。
  final bool done;

  /// 非空 = 服务端报错（磁盘满、模型名不存在等）。
  final String error;

  /// 0~1；totalBytes 还是 0（清单未拿到）时为 null（不确定进度）。
  double? get progress =>
      totalBytes > 0 ? (completedBytes / totalBytes).clamp(0.0, 1.0) : null;
}

/// /api/pull NDJSON 进度聚合器。Ollama 对每个模型层（视觉投影层 +
/// 主权重等）单独从 0 报 completed，直接用最后一行算百分比会来回跳；
/// 这里按 digest 分别记各层的最大 completed，再求和得到整体进度。
class OllamaPullProgress {
  OllamaPullProgress(this.model);

  final String model;
  final Map<String, int> _completed = {};
  final Map<String, int> _totals = {};
  String _status = '';

  int get completedBytes => _completed.values.fold(0, (a, b) => a + b);
  int get totalBytes => _totals.values.fold(0, (a, b) => a + b);

  /// 处理一行 NDJSON；空行/无法解析的行返回 null（忽略）。
  OllamaPullEvent? apply(String line) {
    final t = line.trim();
    if (t.isEmpty) return null;
    Map<String, dynamic> j;
    try {
      j = Map<String, dynamic>.from(jsonDecode(t) as Map);
    } catch (_) {
      return null;
    }
    final error = j['error']?.toString() ?? '';
    if (error.isNotEmpty) {
      return OllamaPullEvent(
        model: model,
        completedBytes: completedBytes,
        totalBytes: totalBytes,
        status: _status,
        done: true,
        error: error,
      );
    }
    final status = j['status']?.toString() ?? '';
    final digest = j['digest']?.toString() ?? '';
    if (digest.isNotEmpty && j['total'] is num) {
      _totals[digest] = (j['total'] as num).toInt();
      final done = (j['completed'] as num?)?.toInt() ?? 0;
      final prev = _completed[digest] ?? 0;
      if (done > prev) _completed[digest] = done;
    }
    if (status.isNotEmpty) _status = status;
    return OllamaPullEvent(
      model: model,
      completedBytes: completedBytes,
      totalBytes: totalBytes,
      status: _status,
      done: status == 'success',
    );
  }
}

/// Ollama HTTP API 封装：模型列表、对话补全，以及面向本工具的辅助
/// 识别场景（单字辅助、标点推荐、整行裁决、识别框诊断）。服务不可用等异常
/// 统一抛 [OllamaException]，消息已转成用户可读的排查提示。
class OllamaException implements Exception {
  final String message;
  OllamaException(this.message);

  @override
  String toString() => message;
}

class OllamaService {
  /// 拉取已安装模型列表（GET /api/tags），含磁盘占用与更新时间。
  static Future<List<OllamaInstalledModel>> listModels(String baseUrl) async {
    final uri = _uri(baseUrl, '/api/tags');
    final http.Response r;
    try {
      r = await http.get(uri).timeout(const Duration(seconds: 6));
    } on TimeoutException {
      throw OllamaException('连接 Ollama 超时（$uri）——服务可能未启动或地址不对');
    } catch (e) {
      throw OllamaException(_connectionHint(baseUrl, e));
    }
    if (r.statusCode != 200) {
      throw OllamaException('Ollama 返回 ${r.statusCode}：${_snippet(r.body)}');
    }
    try {
      final data = jsonDecode(r.body) as Map<String, dynamic>;
      final models = (data['models'] as List? ?? const [])
          .map((raw) {
            final m = raw as Map;
            final name = m['name']?.toString() ?? '';
            if (name.isEmpty) return null;
            return OllamaInstalledModel(
              name: name,
              sizeBytes: (m['size'] as num?)?.toInt() ?? 0,
              modifiedAt: DateTime.tryParse(m['modified_at']?.toString() ?? ''),
            );
          })
          .whereType<OllamaInstalledModel>()
          .toList();
      return models;
    } catch (e) {
      throw OllamaException('解析模型列表失败：${_snippet(r.body)}');
    }
  }

  /// 按当前提供方拉取模型列表：本地走 GET /api/tags（含体积/时间），
  /// 外部取激活供应商走 OpenAI 兼容的 GET /v1/models（无体积信息，按名
  /// 排序）。
  static Future<List<OllamaInstalledModel>> listModelsFor(
    OllamaSettings settings,
  ) async {
    if (settings.provider != AiProvider.externalApi) {
      return listModels(settings.baseUrl);
    }
    final p = settings.activeExtProvider;
    if (p == null || p.baseUrl.trim().isEmpty) {
      throw OllamaException(
        '外部模型供应商未配置地址——请到「AI 辅助设置」填写 API 地址',
      );
    }
    return listModelsOfProvider(p);
  }

  /// 拉取指定外部供应商的模型列表（OpenAI 兼容 GET /models）。
  static Future<List<OllamaInstalledModel>> listModelsOfProvider(
    ExternalApiProvider provider,
  ) async {
    final uri = externalUri(provider.baseUrl, '/models');
    final apiKey = provider.apiKey.trim();
    final http.Response r;
    try {
      r = await http
          .get(
            uri,
            headers: {if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey'},
          )
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw OllamaException('连接外部模型 API 超时（$uri）');
    } catch (e) {
      throw OllamaException(_externalConnectionHint(provider.baseUrl, e));
    }
    if (r.statusCode != 200) {
      throw OllamaException(_externalApiError(r.statusCode, r.body));
    }
    final names = _parseExternalModels(r.body);
    if (names.isEmpty) {
      throw OllamaException('外部 API 未返回任何模型（${_snippet(r.body)}）');
    }
    return [
      for (final n in names)
        OllamaInstalledModel(name: n, sizeBytes: 0, modifiedAt: null),
    ];
  }

  /// 按当前提供方测试连接：本地返回 Ollama 版本号，外部对激活供应商拉
  /// 一次模型列表确认地址与密钥可用。
  static Future<String> checkConnectionFor(OllamaSettings settings) async {
    if (settings.provider != AiProvider.externalApi) {
      return checkConnection(settings.baseUrl);
    }
    final p = settings.activeExtProvider;
    if (p == null || p.baseUrl.trim().isEmpty) {
      throw OllamaException(
        '外部模型供应商未配置地址——请到「AI 辅助设置」填写 API 地址',
      );
    }
    return checkConnectionOfProvider(p);
  }

  /// 测试指定外部供应商的连接（拉一次模型列表确认可用）。
  static Future<String> checkConnectionOfProvider(
    ExternalApiProvider provider,
  ) async {
    final models = await listModelsOfProvider(provider);
    return 'API 可用 · 共 ${models.length} 个模型';
  }

  /// 删除已安装模型（DELETE /api/delete，等价 ollama rm）。正在运行
  /// 的对话不受影响，删除后模型不可再用；Ollama 返回非 200 视为失败。
  static Future<void> deleteModel(String baseUrl, String model) async {
    final uri = _uri(baseUrl, '/api/delete');
    final http.Response r;
    try {
      r = await http
          .delete(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'model': model}),
          )
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw OllamaException('删除请求超时（$uri）');
    } catch (e) {
      throw OllamaException(_connectionHint(baseUrl, e));
    }
    if (r.statusCode != 200) {
      throw OllamaException(
        '删除模型 $model 失败（${r.statusCode}）：${_snippet(r.body)}',
      );
    }
  }

  /// 连接测试：成功返回 Ollama 版本号，失败抛 [OllamaException]。
  static Future<String> checkConnection(String baseUrl) async {
    final uri = _uri(baseUrl, '/api/version');
    final http.Response r;
    try {
      r = await http.get(uri).timeout(const Duration(seconds: 6));
    } on TimeoutException {
      throw OllamaException('连接超时（$uri）——服务可能未启动');
    } catch (e) {
      throw OllamaException(_connectionHint(baseUrl, e));
    }
    if (r.statusCode != 200) {
      throw OllamaException('Ollama 返回 ${r.statusCode}：${_snippet(r.body)}');
    }
    try {
      final data = jsonDecode(r.body) as Map<String, dynamic>;
      return data['version']?.toString() ?? '未知版本';
    } catch (_) {
      return '未知版本';
    }
  }

  /// 拉取模型（POST /api/pull，NDJSON 流式进度）。取消 = 调用方关闭
  /// 传入的 [client]，Ollama 服务端在连接断开时会中止下载（已下载的
  /// 层保留为缓存，下次续传）。连接失败/非 200 抛 [OllamaException]。
  static Stream<OllamaPullEvent> pullModel(
    String baseUrl,
    String model, {
    required http.Client client,
  }) async* {
    final uri = _uri(baseUrl, '/api/pull');
    final request = http.Request('POST', uri)
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({'model': model, 'stream': true});
    final http.StreamedResponse response;
    try {
      response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw OllamaException('连接 Ollama 超时（$uri）——服务可能未启动或地址不对');
    } catch (e) {
      throw OllamaException(_connectionHint(baseUrl, e));
    }
    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw OllamaException(
        'Ollama 返回 ${response.statusCode}：${_snippet(body)}',
      );
    }
    final progress = OllamaPullProgress(model);
    final lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      final event = progress.apply(line);
      if (event != null) yield event;
    }
  }

  /// 单字辅助识别：把该字所在行的整行裁图（橙框标出目标字）+ 行内
  /// 上下文交给视觉模型，返回按可信度排序的候选（汉字或标点：句读、
  /// 括号、书名号、引号等）。识别服务未启动时 [imageBase64] 传 null，
  /// 退化为纯上下文猜测。
  static Future<List<OllamaSuggestion>> suggestChar({
    required OllamaSettings settings,
    String? imageBase64,
    String contextBefore = '',
    String contextAfter = '',
    String currentText = '',
    bool wantThinking = false,
    OllamaTrace? trace,
  }) async {
    final sw = Stopwatch()..start();
    final model = settings.activeVisionModel;
    if (model.isEmpty) {
      throw OllamaException('未选择视觉模型——请在「AI 辅助设置」中选择');
    }
    final contextDesc = StringBuffer();
    if (contextBefore.isNotEmpty) {
      contextDesc.write('该字之前的文字（按阅读顺序）：$contextBefore\n');
    }
    if (contextAfter.isNotEmpty) {
      contextDesc.write('该字之后的文字（按阅读顺序）：$contextAfter\n');
    }
    if (currentText.isNotEmpty) {
      contextDesc.write('OCR 初步识别结果（可能不对）：$currentText\n');
    }

    final prompt = StringBuffer();
    if (imageBase64 == null || imageBase64.isEmpty) {
      prompt.write('下面要对古籍（竖排刻本，繁体/异体字常见）中的一个字做识别。\n');
      if (contextDesc.isNotEmpty) prompt.write(contextDesc);
      prompt.write('请凭上下文判断这是什么字或标点（本次没有图像，请仅凭上下文推断）。');
    } else {
      prompt.write(
        '这是一张从古籍扫描页（竖排刻本，繁体/异体字常见）中裁出的整行（列）'
        '文字裁图，图上用半透明橙色高亮和橙色方框标出了需要识别的目标字'
        '（高亮为淡橙色、透出字形；旁边的白底数字是它的序号）。\n',
      );
      if (contextDesc.isNotEmpty) prompt.write(contextDesc);
      prompt.write(
        '请结合整行的字形、版式与上下文判断橙色框内是什么字或标点'
        '（候选时以框内字形为准，不要被 OCR 初步结果带偏）。',
      );
    }
    prompt.write(
      '\n只输出 JSON，不要输出其他任何内容，格式：'
      '{"candidates":[{"text":"单字","score":0.9,"reason":"不超过十个字的理由"}]}'
      '，candidates 给 3 到 5 个按可能性排序的候选，'
      '每个 text 必须是单个汉字或单个标点符号'
      '（句读、括号、书名号、引号等成对标点的一半）。',
    );

    trace
      ?..model = model
      ..prompt = prompt.toString()
      ..imageBase64 = imageBase64;
    final content = await _chat(
      settings: settings,
      model: model,
      prompt: prompt.toString(),
      imageBase64: imageBase64,
      wantThinking: wantThinking,
      trace: trace,
    );
    trace?.elapsedMs = sw.elapsedMilliseconds;
    return _parseSuggestions(
      content,
      allowedCharset: _cjkAndPunctChars,
      fallbackExtractor: _extractCjkOrPunct,
    );
  }

  /// 标点辅助：古籍刻本的句读点很小、识别不稳。把该标点在行内的位置
  /// （前文/后文）交给文本模型，按文意推荐应是什么标点。
  static Future<List<OllamaSuggestion>> suggestPunctuation({
    required OllamaSettings settings,
    required String contextBefore,
    required String contextAfter,
    String currentText = '',
    bool wantThinking = false,
    OllamaTrace? trace,
  }) async {
    final sw = Stopwatch()..start();
    final model = settings.activeTextModel;
    if (model.isEmpty) {
      throw OllamaException('未选择文本模型——请在「AI 辅助设置」中选择');
    }
    final prompt = StringBuffer();
    prompt.write(
      '下面是从古籍（竖排刻本，繁体字）整理出的一段文字，'
      '其中标记「◈」的位置原本刻有一个句读标点（轮廓很小，OCR 识别不准）。\n',
    );
    if (contextBefore.isNotEmpty) prompt.write('标点之前的文字：$contextBefore\n');
    if (contextAfter.isNotEmpty) prompt.write('标点之后的文字：$contextAfter\n');
    if (currentText.isNotEmpty) {
      prompt.write('OCR 初步识别的标点（可能不对）：$currentText\n');
    }
    prompt.write(
      '请根据上下文文意判断该位置最可能是什么标点。'
      '候选范围：。，、；：？！以及书名号引号等成对标点的一半。',
    );
    prompt.write(
      '\n只输出 JSON，不要输出其他任何内容，格式：'
      '{"candidates":[{"text":"标点","score":0.9,"reason":"不超过十个字的理由"}]}'
      '，candidates 给 2 到 4 个按可能性排序的候选，每个 text 是单个标点符号。',
    );

    trace
      ?..model = model
      ..prompt = prompt.toString();
    final content = await _chat(
      settings: settings,
      model: model,
      prompt: prompt.toString(),
      wantThinking: wantThinking,
      trace: trace,
    );
    trace?.elapsedMs = sw.elapsedMilliseconds;
    return _parseSuggestions(
      content,
      allowedCharset: _punctChars,
      fallbackExtractor: _extractPunct,
    );
  }

  /// 整行三步分析（读行 → 逐字对应 → 切分诊断）：一次调用同时发送
  /// 干净整行裁图 [lineImageBase64] 与按阅读序排列的单字裁图
  /// [charImages]，让模型先从整行图独立读出文字，再逐张单字图给出
  /// 候选与文字/标点判断，最后检查每张单字图的裁切边界。不给当前行
  /// 的 OCR 文本，避免模型被初步结果带偏；调用方在固定 0.80 阈值和
  /// 字框数量校验通过后才写回。[horizontalDir]/[verticalDir] 告诉模型
  /// 本书行内的阅读方向（ltr/rtl、ttb/btt），读行与逐字对应都依赖它。
  static Future<AiLineDecision> analyzeLine({
    required OllamaSettings settings,
    required String lineImageBase64,
    List<String> charImages = const [],
    required List<AiContextItem> context,
    required String orientation,
    String horizontalDir = 'ltr',
    String verticalDir = 'ttb',
    required String layoutRole,
    bool wantThinking = false,
    OllamaTrace? trace,

    /// false = 批量链路（整行裁决的行请求走后台许可，给编辑器手动
    /// 操作留通道）；编辑器手动单行重识别保持默认 true。
    bool interactive = true,
  }) async {
    final sw = Stopwatch()..start();
    // 三步分析必须优先使用视觉模型：文本模型看不到当前字形。没有视觉
    // 模型时才回退文本模型（_chat 会在 400 时自动去图按纯上下文重试）。
    final model = settings.activeVisionModel.isNotEmpty
        ? settings.activeVisionModel
        : settings.activeTextModel;
    if (model.isEmpty) {
      throw OllamaException('未选择文本/视觉模型——请在「AI 辅助设置」中选择');
    }
    final horizontal = orientation == 'horizontal';
    final readingDir = horizontal
        ? (horizontalDir == 'rtl' ? '从右到左' : '从左到右')
        : (verticalDir == 'btt' ? '从下到上' : '从上到下');
    final before = context.where((c) => c.scope == 'before').toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    final after = context.where((c) => c.scope == 'after').toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    final images = [
      lineImageBase64,
      ...charImages.where((b64) => b64.isNotEmpty),
    ];
    final prompt = _lineAnalysisPrompt(
      charCount: charImages.length,
      horizontal: horizontal,
      annotation: layoutRole == 'annotation',
      readingDir: readingDir,
      beforeTexts: before.map((c) => c.text).toList(),
      afterTexts: after.map((c) => c.text).toList(),
    );
    trace
      ?..model = model
      ..prompt = prompt
      ..images = images
      ..imageBase64 = images.first;
    final content = await _chat(
      settings: settings,
      model: model,
      prompt: prompt,
      images: images,
      // 每字一对象（候选+标点+裁切）比旧整行裁决长得多：按 110 token/字
      // 预算并钳在 4096，防止长行截断；上限不再放大以免个别本地视觉
      // runner 重复 token（见 _parseLineAnalysis 的回退路径兜底）。
      numPredict: math.min(4096, math.max(1024, charImages.length * 110)),
      jsonFormat: true,
      wantThinking: wantThinking,
      trace: trace,
      interactive: interactive,
    );
    trace?.elapsedMs = sw.elapsedMilliseconds;
    return _parseLineAnalysis(content);
  }

  /// 整页直读文本的 AI 校对（「文本」视图）：以页图（视觉模型时）+
  /// OCR 全文为输入，让模型按原行结构逐行校对误识/断句，返回校对后
  /// 文本。与 analyzeLine 同一条请求通道（限流/追踪/400 去图重试）。
  static Future<String> proofreadPageText({
    required OllamaSettings settings,
    required String pageText,
    String? pageImageBase64,
    required String orientation,
    String horizontalDir = 'ltr',
    String verticalDir = 'ttb',
    bool wantThinking = false,
    OllamaTrace? trace,
    bool interactive = true,
  }) async {
    final model = settings.activeVisionModel.isNotEmpty
        ? settings.activeVisionModel
        : settings.activeTextModel;
    if (model.isEmpty) {
      throw OllamaException('未选择文本/视觉模型——请在「AI 辅助设置」中选择');
    }
    final horizontal = orientation == 'horizontal';
    final buf = StringBuffer()
      ..write('你是古籍 OCR 校对器。这是一页${horizontal ? '横排' : '竖排'}古籍的'
          '整页 OCR 文本（按阅读序、每行一段）。\n')
      ..write('阅读方向：')
      ..write(horizontal
          ? (horizontalDir == 'rtl' ? '从右到左' : '从左到右')
          : '列${horizontalDir == 'rtl' ? '从右到左' : '从左到右'}、'
              '${verticalDir == 'btt' ? '从下到上' : '从上到下'}。\n');
    if (pageImageBase64 != null && pageImageBase64.isNotEmpty) {
      buf.write('随消息发送 1 张图片：整页原图（无任何标注）。\n');
    }
    buf
      ..write('\n【OCR 全文，每行一段】：\n')
      ..write(pageText)
      ..write('\n\n请校对：以图像字形为准（未附图时按文意），改正明显的'
          '误识字与断句/标点错误；异体字、繁体写法保持原样，没有把握的'
          '地方一律保留 OCR 原字，不要增删行、不要补充内容。')
      ..write('古籍影印本的标点多为印在字旁的小号符号，OCR 整行识别时'
          '常整页丢失——若 OCR 文本整行/整页几乎没有标点，请按文意用'
          '标准中文标点（，。、；：「」）为全文断句补全；原文已有的'
          '标点保持原样，不要在同一位置堆叠或改写。')
      ..write('输出行数必须与输入一致（每行对应）。\n')
      ..write('只输出 JSON，不要输出其他任何内容，格式：'
          '{"text":"校对后的整页文本，每行一段"}。');
    final prompt = buf.toString();
    final images = (pageImageBase64 != null && pageImageBase64.isNotEmpty)
        ? [pageImageBase64]
        : const <String>[];
    trace
      ?..model = model
      ..prompt = prompt
      ..images = images
      ..imageBase64 = images.isEmpty ? null : images.first;
    final chars = pageText.length;
    final content = await _chat(
      settings: settings,
      model: model,
      prompt: prompt,
      images: images,
      // 整页文本可达数千字：按 2 token/字预算并钳在 8192。
      numPredict: math.min(8192, math.max(2048, chars * 2)),
      jsonFormat: true,
      wantThinking: wantThinking,
      trace: trace,
      interactive: interactive,
      // 整页（视觉）校对远慢于单行：放宽到 10 分钟。
      timeout: const Duration(minutes: 10),
    );
    return _parseProofreadText(content);
  }

  /// 解析 proofreadPageText 的 JSON 输出；解析失败时把原文原样返回
  /// （校对失败不该丢掉 OCR 文本）。
  static String _parseProofreadText(String content) {
    try {
      final decoded = jsonDecode(content);
      if (decoded is Map && decoded['text'] is String) {
        final text = decoded['text'] as String;
        if (text.trim().isNotEmpty) return text;
      }
    } catch (_) {}
    // 模型偶尔在 JSON 外包一层 ```json 围栏：剥掉再试一次。
    final stripped = content.trim();
    if (stripped.startsWith('```')) {
      final inner = stripped
          .replaceFirst(RegExp(r'^```[a-zA-Z]*\s*'), '')
          .replaceFirst(RegExp(r'\s*```$'), '');
      try {
        final decoded = jsonDecode(inner);
        if (decoded is Map && decoded['text'] is String) {
          final text = decoded['text'] as String;
          if (text.trim().isNotEmpty) return text;
        }
      } catch (_) {}
    }
    throw OllamaException('AI 校对输出无法解析（未得到 {"text": ...}）');
  }

  /// 整行三步分析 prompt（analyzeLine 与压测探针共用同一口径——抽出来
  /// 就是为了让压测请求与真实行裁决逐字同形，测出的并发数才代表真实
  /// 负载）。[charCount] 为单字图数量（0 = 只发整行图）。
  static String _lineAnalysisPrompt({
    required int charCount,
    required bool horizontal,
    required bool annotation,
    required String readingDir,
    required List<String> beforeTexts,
    required List<String> afterTexts,
  }) {
    final buf = StringBuffer()
      ..write('你是古籍 OCR 校对器。这是一条${horizontal ? '横排' : '竖排'}')
      ..write('${annotation ? '夹注' : '正文'}文字列，')
      ..write('行内阅读顺序：$readingDir。\n\n');
    if (charCount == 0) {
      buf.write('随消息发送 1 张图片：整行裁图（无任何标注）。\n');
    } else {
      buf
        ..write('随消息发送 ${charCount + 1} 张图片：\n')
        ..write('- 第 1 张：整行裁图（无任何标注）。\n')
        ..write(
          '- 第 2 张起：按阅读顺序（$readingDir）逐字裁出的单字图'
          '（白底）：第 2 张是 0 号字框，第 3 张是 1 号字框，依此类推，'
          '共 $charCount 张单字图。\n',
        );
    }
    buf.write('\n【前文，仅作上下文，不要输出】：');
    buf.write(beforeTexts.take(32).join());
    buf.write('\n【后文，仅作上下文，不要输出】：');
    buf.write(afterTexts.take(32).join());
    buf.write('\n\n请分三步工作：\n');
    buf.write(
      '1. 只看第 1 张整行图，按阅读顺序（$readingDir）直接读出这一行'
      '应有的完整文字'
      '（以图像字形为准，不要参考任何 OCR 结果；注意古籍异体字、'
      '繁体写法与句读标点）。\n'
      '2. 逐张查看单字图，把每张图与整行读出的文字对应，判断该字框'
      '里的字应该是什么：给出 2 到 4 个按可能性排序的候选'
      '（每个 text 必须是单个汉字或单个标点），并判断它是文字还是标点。\n'
      '3. 检查每张单字图的裁切边界：字形被切掉一半或一角（墨迹紧贴'
      '图片边缘）、一张图里挤着两个完整字形、或混入了旁边字的墨迹，'
      '都属于裁切问题，在 crop_issue 里报告。\n\n',
    );
    if (charCount == 0) {
      buf.write(
        '只输出 JSON，不要输出其他任何内容，格式：'
        '{"line_text":"整行文字","confidence":0.0,"items":'
        '[{"order":0,"text":"字","punctuation":false}]}。'
        'items 按阅读顺序逐字给出（本次未提供单字图，不需要候选与'
        '裁切判断），order 从 0 连续递增，每个 text 只能是一个汉字或'
        '一个标点。',
      );
    } else {
      buf.write(
        '只输出 JSON，不要输出其他任何内容，格式：'
        '{"line_text":"第 1 步读出的整行文字","confidence":0.0,"items":'
        '[{"order":0,"text":"字","candidates":[{"text":"字","score":0.9}],'
        '"punctuation":false,"crop_ok":true,"crop_issue":null,'
        '"note":"裁切问题的说明，无问题时留空"}]}。'
        'items 数量必须等于单字图数量（$charCount 张），order '
        '从 0 连续递增；text 是候选中最可能的那个字；confidence 是你对'
        '整行读出的把握；crop_issue 只能取 char_clipped（切掉字形一部分）/'
        'char_merged（一个框装了两个字）/ char_extra_ink（多包进旁边墨迹）'
        '之一，无问题时为 null 且 crop_ok 为 true。',
      );
    }
    return buf.toString();
  }

  /// 整行裁决压测探针（真实形态）：与 analyzeLine 同款 prompt（合成
  /// 上下文）与同一条请求通道（_chatBody，**不过 AiRequestLimiter**——
  /// 探针不能被待校准的限流器卡住），带 1 张行图 + [charImages]。输出
  /// 上限 256（真实链路 1024+，取约 1/4 控制单条时长）、不带思考。
  /// 成功返回耗时（排队判据的原始数据），失败/超时返回 null。
  static Future<Duration?> lineStressProbe({
    required OllamaSettings settings,
    required String model,
    required String lineImage,
    required List<String> charImages,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final prompt = _lineAnalysisPrompt(
      charCount: charImages.length,
      horizontal: false,
      annotation: false,
      readingDir: '从上到下',
      beforeTexts: const ['天地玄黄', '宇宙洪荒'],
      afterTexts: const ['日月盈昃', '辰宿列张'],
    );
    final sw = Stopwatch()..start();
    try {
      await _chatBody(
        settings: settings,
        model: model,
        prompt: prompt,
        images: [lineImage, ...charImages],
        numPredict: 256,
        jsonFormat: true,
      ).timeout(timeout);
      return sw.elapsed;
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static AiLineDecision parseLineAnalysisForTest(String content) =>
      _parseLineAnalysis(content);

  static AiLineDecision _parseLineAnalysis(String content) {
    for (final chunk in _jsonCandidates(content)) {
      try {
        final raw = jsonDecode(chunk);
        if (raw is! Map) continue;
        final lineText = raw['line_text']?.toString().trim() ?? '';
        final confidence = ((raw['confidence'] as num?)?.toDouble() ?? 0).clamp(
          0.0,
          1.0,
        );
        final items = <AiLineItem>[];
        final list = raw['items'];
        if (list is List) {
          for (final value in list) {
            if (value is! Map) continue;
            final text = value['text']?.toString().trim() ?? '';
            if (text.runes.length != 1 ||
                (!_isCjkRune(text.runes.first) && !isPunctuationText(text))) {
              continue;
            }
            // 逐字候选：单字 + 字符集校验 + 去重，score 钳到 [0,1]。
            final candidates = <OllamaSuggestion>[];
            final rawCandidates = value['candidates'];
            if (rawCandidates is List) {
              for (final rc in rawCandidates) {
                String t;
                double s;
                if (rc is Map) {
                  t = rc['text']?.toString().trim() ?? '';
                  s = ((rc['score'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0);
                } else if (rc is String) {
                  t = rc.trim();
                  s = 0;
                } else {
                  continue;
                }
                if (t.runes.length != 1 ||
                    (!_isCjkRune(t.runes.first) && !isPunctuationText(t))) {
                  continue;
                }
                if (candidates.any((c) => c.text == t)) continue;
                candidates.add(OllamaSuggestion(text: t, score: s));
              }
            }
            // 逐字置信度取候选首位的给分（那才是模型对判定字的把握）；
            // 模型没给候选时才用显式 confidence 字段。
            final explicitConf =
                ((value['confidence'] as num?)?.toDouble() ?? 0).clamp(
                  0.0,
                  1.0,
                );
            final itemConf = candidates.isNotEmpty
                ? candidates.first.score
                : explicitConf;
            final issueWire = value['crop_issue']?.toString().trim() ?? '';
            final cropIssue = kAiCropIssues.contains(issueWire)
                ? issueWire
                : null;
            items.add(
              AiLineItem(
                order: (value['order'] as num?)?.toInt() ?? items.length,
                text: text,
                confidence: itemConf,
                reason:
                    value['note']?.toString() ??
                    value['reason']?.toString() ??
                    '',
                punctuation:
                    value['punctuation'] == true || isPunctuationText(text),
                candidates: candidates,
                cropIssue: cropIssue,
                cropNote: cropIssue == null
                    ? ''
                    : value['note']?.toString() ?? '',
              ),
            );
          }
        }
        return AiLineDecision(
          lineText: lineText,
          confidence: confidence,
          items: items,
        );
      } catch (_) {
        // 继续尝试下一个 JSON 片段。
      }
    }
    // 与旧整行裁决相同的抢救路径：视觉 runner 偶尔在 reason 里输出未转义
    // 引号/换行使整个对象解析失败，但 line_text 前缀仍完好。调用方仍会做
    // 字框数量与字符集校验，散文不可能经此路径变成整行结果。
    final lineMatch = RegExp(
      r'"line_text"\s*:\s*"((?:\\.|[^"\\])*)"',
      dotAll: true,
    ).firstMatch(content);
    if (lineMatch != null) {
      var lineText = lineMatch.group(1)!;
      try {
        lineText = (jsonDecode('"$lineText"') as String).trim();
      } catch (_) {
        lineText = lineText.replaceAll(r'\"', '"').trim();
      }
      final confidenceMatch = RegExp(
        r'"confidence"\s*:\s*([01](?:\.\d+)?)',
      ).firstMatch(content);
      final confidence = double.tryParse(confidenceMatch?.group(1) ?? '') ?? 0;
      if (lineText.isNotEmpty &&
          lineText.runes.length <= 256 &&
          lineText.runes.every(
            (rune) =>
                _isCjkRune(rune) ||
                isPunctuationText(String.fromCharCode(rune)),
          )) {
        return AiLineDecision(
          lineText: lineText,
          confidence: confidence.clamp(0.0, 1.0),
          items: const [],
        );
      }
    }
    throw OllamaException('AI 返回内容无法解析为整行分析（原始输出：${_snippet(content)}）');
  }

  /// AI 框检查：把带当前字框叠加（橙框+序号）的行条图和逐字信息交给
  /// 视觉模型，从固定操作菜单里诊断框摆得准不准。只要求选类型+序号，
  /// 不要求输出坐标（VLM 出坐标不可靠，几何执行全部在后端算子里）。
  /// [horizontalDir]/[verticalDir] 告诉模型本书的行内阅读方向（ltr/rtl、
  /// ttb/btt）——编号与"下一个字"的方位判断都依赖它。
  static Future<OllamaBoxDiagnosis> diagnoseLineBox({
    required OllamaSettings settings,
    required String imageBase64,
    required List<({int order, String text, double conf, double relSize})>
    chars,
    bool horizontal = false,
    String horizontalDir = 'ltr',
    String verticalDir = 'ttb',
    bool wantThinking = false,
    OllamaTrace? trace,
  }) async {
    final sw = Stopwatch()..start();
    final model = settings.activeVisionModel;
    if (model.isEmpty) {
      throw OllamaException('未选择视觉模型——请在「AI 辅助设置」中选择');
    }
    final readingDir = horizontal
        ? (horizontalDir == 'rtl' ? '从右到左' : '从左到右')
        : (verticalDir == 'btt' ? '从下到上' : '从上到下');
    final buf = StringBuffer();
    buf.write(
      '这是一张古籍${horizontal ? '横排（行内阅读顺序：$readingDir）' : '竖排行/列（列内阅读顺序：$readingDir）'}的裁图。',
    );
    buf.write(
      '图上用半透明橙色高亮和橙色方框标出了当前识别系统的切字框，'
      '每个框旁边（竖排行在框左侧、横排行在框上方）的白底数字是该框序号'
      '（按阅读顺序编号，$readingDir）。\n',
    );
    buf.write('当前逐字识别结果（序号=框序号，conf=识别置信度，rel=框长边/行内中位框长边）：\n');
    for (final c in chars.take(60)) {
      final t = c.text.isEmpty ? '（空）' : c.text;
      buf.write(
        '${c.order}. $t conf=${c.conf.toStringAsFixed(2)} rel=${c.relSize.toStringAsFixed(2)}\n',
      );
    }
    buf.write(
      '\n请检查切字框与字形是否对齐，只输出 JSON，不要输出其他任何内容，格式：'
      '{"line_ok": true, "issues": [], "confidence": 0.9}。'
      '发现问题时 line_ok 为 false，issues 给出问题列表，每条形如 '
      '{"type": "类型", "pos": 序号, "note": "不超过十个字的说明"}。'
      'type 只能取以下五种：'
      'merge_two_lines（这一"行"其实是并排的两列文字，应拆开）、'
      'char_merged（某个框里装了两个字）、'
      'char_clipped（某个框切掉了字形的一部分）、'
      'char_extra_ink（某个框多包进了旁边的墨迹）、'
      'missing_chars（行内有字但框漏了没切出来）。'
      'pos 填对应框的序号（拆行/漏字类型填 0）。'
      '以下情况属于明显问题，见到必须报告，不要因为"能读出字"就放过：'
      '橙框只盖住字形的一半或一角、字形大半露在框外；'
      '本条行框明显只覆盖了半列文字（另一半在框外）；'
      '一个框里明显挤着两个完整字形。'
      '只有拿不准的疑似问题才不报。',
    );

    trace
      ?..model = model
      ..prompt = buf.toString()
      ..imageBase64 = imageBase64;
    final content = await _chat(
      settings: settings,
      model: model,
      prompt: buf.toString(),
      imageBase64: imageBase64,
      wantThinking: wantThinking,
      trace: trace,
    );
    trace?.elapsedMs = sw.elapsedMilliseconds;
    return _parseBoxDiagnosis(content, charCount: chars.length);
  }

  /// AI 整页版面区预标注：把后端生成的素材图（降采样整页 + 1/8 网格坐标
  /// 刻度 + 已有区域半透明底色）交给视觉模型，让它按七个类别输出版面区
  /// 候选（归一化坐标 0~1）。与框检查同一哲学的例外说明：这里模型必须
  /// 给坐标（没有坐标的版面区没有意义），但坐标只当粗框——真正的像素
  /// 精度由后端 /region_refine 的墨迹几何精修保证（语义归模型，像素归
  /// 几何）。已有底色区域在提示里明确"不用再标"（只填空原则）。
  static Future<OllamaPagePrelabel> prelabelPageLayout({
    required OllamaSettings settings,
    required String imageBase64,
    bool wantThinking = false,
    OllamaTrace? trace,
  }) async {
    final sw = Stopwatch()..start();
    final model = settings.activeVisionModel;
    if (model.isEmpty) {
      throw OllamaException('未选择视觉模型——请在「AI 辅助设置」中选择');
    }
    final buf = StringBuffer();
    buf.write(
      '这是一张古籍书页的整页图。图上叠加了浅灰色网格（把页面横竖各'
      '分成 8 格，顶边和左边的数字是归一化坐标刻度，0 到 1）。',
    );
    buf.write(
      '半透明色块是已标注好的版面区（块上写了类别名），这些区域'
      '不需要再标。\n',
    );
    buf.write(
      '请找出页面上其余的版面区，按七个类别标注：'
      'main_text（正文）、header（页眉）、footer（页脚）、'
      'page_number（页码）、margin_note（页眉上方或正文旁的眉批小字）、'
      'figure（插图/版画）、table（表格——有横竖格线构成的网格结构，'
      '如年表、职官表）。'
      '古籍常见形态：天头的书名/卷次是页眉，版心或页脚的"卷几·第几叶"'
      '是页码，天头小字批注是眉批。\n',
    );
    buf.write(
      '坐标用归一化数值（0 到 1，参考网格刻度），x/y 是区域左上角，'
      'w/h 是宽高，都相对整页。坐标允许粗略（会被后续几何步骤收紧到'
      '真实墨迹），但类别判断要尽量准。\n',
    );
    buf.write(
      '只输出 JSON，不要输出其他任何内容，格式：'
      '{"regions": [{"label": "类别", "x": 0.1, "y": 0.02, '
      '"w": 0.3, "h": 0.05}]}。'
      '不确定的区域宁可不报；已标注（有色块）的区域不要重复报；'
      '一般不超过 8 个区域。',
    );

    trace
      ?..model = model
      ..prompt = buf.toString()
      ..imageBase64 = imageBase64;
    final content = await _chat(
      settings: settings,
      model: model,
      prompt: buf.toString(),
      imageBase64: imageBase64,
      numPredict: 1024,
      wantThinking: wantThinking,
      trace: trace,
    );
    trace?.elapsedMs = sw.elapsedMilliseconds;
    return _parsePagePrelabel(content);
  }

  /// AI 画框测试（实验功能）：把带网格刻度的整页素材图发给视觉模型，
  /// 只要求输出每个字的坐标框，返回值不做任何几何精修。与生产链路
  /// 「语义归模型，像素归几何」相对，这里故意只留前半句——专门测
  /// VLM 裸定位的真实水平（测试页 ai_box_test_page.dart 消费）。
  ///
  /// [imageWidth]/[imageHeight] 是素材图尺寸（进 prompt 告知模型，也是
  /// 像素口径的钳制边界）；[gridDiv] 与素材图网格密度一致（prompt 里
  /// 换算成"每格多少像素"帮助锚定）。整页几百个字的 JSON 输出量很大，
  /// num_predict 给到 8192、超时放宽到 10 分钟，截断由解析层打捞。
  static Future<OllamaCharBoxes> charBoxesFromImage({
    required OllamaSettings settings,
    required String imageBase64,
    required int imageWidth,
    required int imageHeight,
    required int gridDiv,
    AiBoxCoordMode coordMode = AiBoxCoordMode.materialPixel,
    bool wantThinking = false,
    OllamaTrace? trace,
  }) async {
    final sw = Stopwatch()..start();
    final model = settings.activeVisionModel;
    if (model.isEmpty) {
      throw OllamaException('未选择视觉模型——请在「AI 辅助设置」中选择');
    }
    final buf = StringBuffer();
    buf.write(
      '这是一张古籍书页图片，上面叠加了浅灰色网格（横竖各 $gridDiv 格，'
      '顶边和左边的数字是归一化坐标刻度，0 到 1）。',
    );
    buf.write('图片尺寸：宽 $imageWidth 像素、高 $imageHeight 像素；'
        '每个网格格约 ${imageWidth ~/ gridDiv} 像素宽、'
        '${imageHeight ~/ gridDiv} 像素高。\n');
    buf.write(
      '请找出图中所有的字——每个字一个独立的矩形框（正文、批注小字、'
      '标点都要），按阅读顺序（古籍通常从上到下、从右到左）依次输出。\n',
    );
    if (coordMode == AiBoxCoordMode.materialPixel) {
      buf.write(
        '每个框用这张图片的像素坐标表示：x1/y1 是左上角，x2/y2 是右下角，'
        '数值参考网格（每格 ${imageWidth ~/ gridDiv}×${imageHeight ~/ gridDiv} 像素）。'
        '框要贴住字的墨迹，不要切开笔画。\n',
      );
      buf.write(
        '只输出 JSON，不要输出其他任何内容，格式：'
        '{"chars": [{"x1": 100, "y1": 200, "x2": 140, "y2": 240}, ...]}',
      );
    } else {
      buf.write(
        '每个框用归一化坐标表示（0 到 1，参考网格刻度），x/y 是左上角，'
        'w/h 是宽高，都相对整张图。框要贴住字的墨迹，不要切开笔画。\n',
      );
      buf.write(
        '只输出 JSON，不要输出其他任何内容，格式：'
        '{"chars": [{"x": 0.72, "y": 0.05, "w": 0.02, "h": 0.02}, ...]}',
      );
    }

    trace
      ?..model = model
      ..prompt = buf.toString()
      ..imageBase64 = imageBase64;
    final content = await _chat(
      settings: settings,
      model: model,
      prompt: buf.toString(),
      imageBase64: imageBase64,
      numPredict: 8192,
      wantThinking: wantThinking,
      trace: trace,
      timeout: const Duration(seconds: 600),
    );
    trace?.elapsedMs = sw.elapsedMilliseconds;
    return _parseCharBoxes(
      content,
      mode: coordMode,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
    );
  }

  static OllamaPagePrelabel _parsePagePrelabel(String content) {
    final regions = <OllamaPageRegion>[];
    for (final chunk in _jsonCandidates(content)) {
      Map<String, dynamic>? doc;
      try {
        final decoded = jsonDecode(chunk);
        if (decoded is Map) {
          doc = Map<String, dynamic>.from(decoded);
        }
      } catch (_) {
        continue;
      }
      final raw = doc?['regions'];
      if (doc == null || raw is! List) continue;
      for (final e in raw) {
        if (e is! Map) continue;
        final label = RegionLabel.normalize(e['label']?.toString());
        double? readNum(String key) {
          final v = e[key];
          if (v is num) return v.toDouble();
          if (v is String) return double.tryParse(v);
          return null;
        }

        final x = readNum('x'), y = readNum('y');
        final w = readNum('w'), h = readNum('h');
        if (x == null || y == null || w == null || h == null) continue;
        // 归一化坐标钳回 0~1，退化框（宽高 <0.5% 页面）丢弃
        final cx = x.clamp(0.0, 1.0), cy = y.clamp(0.0, 1.0);
        final cw = w.clamp(0.0, 1.0 - cx), ch = h.clamp(0.0, 1.0 - cy);
        if (cw < 0.005 || ch < 0.005) continue;
        regions.add(OllamaPageRegion(label: label, x: cx, y: cy, w: cw, h: ch));
      }
      break; // 用第一个有效 JSON 文档
    }
    return OllamaPagePrelabel(regions: regions, rawContent: content);
  }

  /// 解析 AI 画框测试响应：优先完整 JSON 文档；文档未闭合（num_predict
  /// 或超时截断）时从 "chars" 数组里逐个打捞已闭合的对象，残尾丢弃——
  /// 整页几百个字的输出量下截断是常态，能捡多少是多少。
  static OllamaCharBoxes _parseCharBoxes(
    String content, {
    required AiBoxCoordMode mode,
    required int imageWidth,
    required int imageHeight,
  }) {
    for (final chunk in _jsonCandidates(content)) {
      Map<String, dynamic>? doc;
      try {
        final decoded = jsonDecode(chunk);
        if (decoded is Map) doc = Map<String, dynamic>.from(decoded);
      } catch (_) {
        continue;
      }
      final raw = doc?['chars'];
      if (doc == null || raw is! List) continue;
      final boxes = <OllamaCharBox>[];
      for (final e in raw) {
        final b = _charBoxFromEntry(e, mode, imageWidth, imageHeight);
        if (b != null) boxes.add(b);
      }
      return OllamaCharBoxes(
        boxes: boxes,
        rawContent: content,
        truncated: false,
      );
    }
    final (entries, truncated) = _salvageCharEntries(content);
    final boxes = <OllamaCharBox>[];
    for (final e in entries) {
      final b = _charBoxFromEntry(e, mode, imageWidth, imageHeight);
      if (b != null) boxes.add(b);
    }
    return OllamaCharBoxes(boxes: boxes, rawContent: content, truncated: truncated);
  }

  /// 截断打捞：定位 "chars" 数组的 `[` 之后，逐个收取花括号配对完整的
  /// 对象（字符串感知，防止字串里的花括号/引号干扰配对）；遇到 `]` 视为
  /// 数组完整，扫到结尾仍未闭合则记为截断、丢弃残尾对象。
  static (List<Map<String, dynamic>>, bool) _salvageCharEntries(String content) {
    final entries = <Map<String, dynamic>>[];
    final charsIdx = content.indexOf('"chars"');
    if (charsIdx < 0) return (entries, false);
    final arrOpen = content.indexOf('[', charsIdx);
    if (arrOpen < 0) return (entries, false);
    var truncated = false;
    var i = arrOpen + 1;
    while (i < content.length) {
      final c = content[i];
      if (c == ']') break; // 数组完整闭合，不算截断
      if (c == '{') {
        final end = _balancedBraceEnd(content, i);
        if (end < 0) {
          truncated = true;
          break;
        }
        try {
          final decoded = jsonDecode(content.substring(i, end + 1));
          if (decoded is Map) entries.add(Map<String, dynamic>.from(decoded));
        } catch (_) {
          // 单个对象损坏就跳过，继续捡后面的
        }
        i = end + 1;
      } else {
        i++;
      }
    }
    return (entries, truncated);
  }

  /// 从 [openIdx] 的 `{` 起找配对 `}`（跳过字符串字面量），未闭合返回 -1。
  static int _balancedBraceEnd(String s, int openIdx) {
    var depth = 0;
    var inStr = false;
    var esc = false;
    for (var i = openIdx; i < s.length; i++) {
      final c = s[i];
      if (inStr) {
        if (esc) {
          esc = false;
        } else if (c == '\\') {
          esc = true;
        } else if (c == '"') {
          inStr = false;
        }
      } else if (c == '"') {
        inStr = true;
      } else if (c == '{') {
        depth++;
      } else if (c == '}') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  /// 单个字框条目 → [OllamaCharBox]：数值兼容 num/String，角点颠倒互换，
  /// 坐标钳回图内，退化框（像素口径 <2px / 归一化口径 <0.2% 图）返回
  /// null 丢弃。
  static OllamaCharBox? _charBoxFromEntry(
    Object? e,
    AiBoxCoordMode mode,
    int imageWidth,
    int imageHeight,
  ) {
    if (e is! Map) return null;
    double? readNum(String key) {
      final v = e[key];
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v);
      return null;
    }

    double x1, y1, x2, y2;
    if (mode == AiBoxCoordMode.materialPixel) {
      final a = readNum('x1'), b = readNum('y1');
      final c = readNum('x2'), d = readNum('y2');
      if (a == null || b == null || c == null || d == null) return null;
      x1 = a;
      y1 = b;
      x2 = c;
      y2 = d;
      if (x2 < x1) {
        final t = x1;
        x1 = x2;
        x2 = t;
      }
      if (y2 < y1) {
        final t = y1;
        y1 = y2;
        y2 = t;
      }
      final maxX = imageWidth.toDouble(), maxY = imageHeight.toDouble();
      x1 = x1.clamp(0.0, maxX);
      x2 = x2.clamp(0.0, maxX);
      y1 = y1.clamp(0.0, maxY);
      y2 = y2.clamp(0.0, maxY);
      if (x2 - x1 < 2 || y2 - y1 < 2) return null;
    } else {
      final x = readNum('x'), y = readNum('y');
      final w = readNum('w'), h = readNum('h');
      if (x == null || y == null || w == null || h == null) return null;
      final cx = x.clamp(0.0, 1.0), cy = y.clamp(0.0, 1.0);
      final cw = w.clamp(0.0, 1.0 - cx), ch = h.clamp(0.0, 1.0 - cy);
      if (cw < 0.002 || ch < 0.002) return null;
      x1 = cx;
      y1 = cy;
      x2 = cx + cw;
      y2 = cy + ch;
    }
    return OllamaCharBox(x1: x1, y1: y1, x2: x2, y2: y2);
  }

  // ── 底层对话 ──

  /// 统一入口：过全局限流器（AiRequestLimiter）后再发请求。[interactive]
  /// 标记用户直排操作（编辑器手动单字/单行等，优先获得许可）；批量链路
  /// （整行裁决的行请求）传 false——智能模式给交互保留通道。
  static Future<String> _chat({
    required OllamaSettings settings,
    required String model,
    required String prompt,
    String? imageBase64,
    List<String>? images,
    int numPredict = 256,
    bool jsonFormat = false,
    bool wantThinking = false,
    OllamaTrace? trace,
    bool interactive = true,
    Duration timeout = const Duration(seconds: 120),
  }) {
    return AiRequestLimiter.instance.guard(
      () => _chatBody(
        settings: settings,
        model: model,
        prompt: prompt,
        imageBase64: imageBase64,
        images: images,
        numPredict: numPredict,
        jsonFormat: jsonFormat,
        wantThinking: wantThinking,
        trace: trace,
        timeout: timeout,
      ),
      interactive: interactive,
    );
  }

  static Future<String> _chatBody({
    required OllamaSettings settings,
    required String model,
    required String prompt,
    String? imageBase64,
    List<String>? images,
    int numPredict = 256,
    bool jsonFormat = false,
    bool wantThinking = false,
    OllamaTrace? trace,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    // 多图任务传 [images]；单图任务仍走 [imageBase64]，这里统一收拢成
    // 一份列表供两个通道共用。
    final imgs =
        images ??
        (imageBase64 != null && imageBase64.isNotEmpty
            ? [imageBase64]
            : const <String>[]);
    if (settings.provider == AiProvider.externalApi) {
      // 按模型名解析所在供应商的端点（视觉/文本槽可绑不同供应商）。
      final endpoint = settings.resolveEndpointForModel(model);
      if (endpoint == null) {
        throw OllamaException(
          '外部模型 API 未配置完整——请到「AI 辅助设置」为供应商填写 '
          'API 地址，并在「模型选择」中选好模型',
        );
      }
      return _chatExternal(
        endpoint: endpoint,
        prompt: prompt,
        images: imgs,
        numPredict: numPredict,
        jsonFormat: jsonFormat,
        wantThinking: wantThinking,
        trace: trace,
        timeout: timeout,
      );
    }
    final uri = _uri(settings.baseUrl, '/api/chat');
    // 纯文本模型收到图像会整单拒绝（400 multimodal）：第一次带图请求被
    // 拒后去掉图像按纯上下文重试一次——文本模型兜底路径（如未配视觉
    // 模型时的整行裁决）仍然可用，对比页也能从 trace 看出"该模型没看图"。
    var includeImages = imgs.isNotEmpty;
    // 默认关闭思维链（思考型模型 qwen3 等只出结论，省时间）；对比页
    // 开 wantThinking 保留思维链进 trace（思维链也占 num_predict，补
    // 2048 token 余量避免截断正文）。
    var useThink = wantThinking;
    Map<String, dynamic> buildBody() => {
      'model': model,
      'messages': [
        {'role': 'user', 'content': prompt, if (includeImages) 'images': imgs},
      ],
      'stream': false,
      'think': useThink,
      'options': {
        'temperature': 0.2,
        'num_predict': useThink ? numPredict + 2048 : numPredict,
      },
      if (jsonFormat) 'format': 'json',
    };
    http.Response r;
    // 请求体带整行图 + 40 张字图的 base64 时达 MB 级：编码搬后台
    // isolate（重试路径最多重编 3 次，不能落在 UI isolate 上）。
    Future<http.Response> send() async {
      final body = await encodeJsonInIsolate(buildBody());
      return http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(timeout);
    }
    try {
      r = await send();
      // 模型 runner 崩溃（显存/内存不足、驱动重置）多为偶发，Ollama 在
      // 下次请求时会自动重启 runner：等 2 秒自动重试一次再报错。
      if (_isRunnerCrash(r.statusCode, r.body)) {
        await Future<void>.delayed(const Duration(seconds: 2));
        r = await send();
      }
      if (includeImages && r.statusCode == 400 && _isNoMultimodal(r.body)) {
        includeImages = false;
        trace?.imageDropped = true;
        r = await send();
      }
      // 非思考型模型收到 think:true 会 400：关掉重试一次（只是拿不到
      // 思维链，结论照常）。
      if (useThink && r.statusCode == 400 && _rejectsThinking(r.body)) {
        useThink = false;
        r = await send();
      }
    } on TimeoutException {
      throw OllamaException(
        'AI 推理超时（>${timeout.inSeconds} 秒）——模型太大或机器太忙，'
        '可换更小的模型',
      );
    } catch (e) {
      throw OllamaException(_connectionHint(settings.baseUrl, e));
    }
    if (r.statusCode != 200) {
      final detail = _snippet(r.body);
      if (r.statusCode == 404) {
        throw OllamaException(
          '模型 $model 不存在——请在 Ollama 里先 pull，'
          '或在「AI 辅助设置」中改选其他模型',
        );
      }
      if (_isRunnerCrash(r.statusCode, r.body)) {
        throw OllamaException(
          '模型 $model 推理中断（Ollama 推理进程崩溃，已自动重试仍失败）。'
          '常见原因：显存/内存不足、显卡驱动重置。\n'
          '建议：① 在「AI 辅助设置 → 模型安装」换更小的视觉模型；'
          '② 重启 Ollama（托盘退出再启动）或更新显卡驱动。'
          '原始错误：$detail',
        );
      }
      throw OllamaException('Ollama 返回 ${r.statusCode}：$detail');
    }
    try {
      final data =
          await decodeJsonInIsolate(r.body) as Map<String, dynamic>;
      final message = data['message'] as Map<String, dynamic>? ?? const {};
      trace?.thinking = message['thinking']?.toString().trim() ?? '';
      final content = (message['content'] ?? data['response'] ?? '')
          .toString()
          .trim();
      if (content.isEmpty) {
        throw OllamaException('AI 返回了空内容，请重试或换模型');
      }
      trace?.rawContent = content;
      return content;
    } on OllamaException {
      rethrow;
    } catch (e) {
      throw OllamaException('解析 AI 响应失败：${_snippet(r.body)}');
    }
  }

  // ── 外部模型 API（OpenAI Chat Completions 兼容协议）──

  /// 外部 API 对话补全。降级策略与本地路径同思路：网关不支持
  /// response_format 时去掉重试一次；纯文本模型收到图像报 400 时去图按
  /// 纯上下文重试一次（trace.imageDropped 留痕）。端点由调用方按槽位
  /// 解析好传入（[ExternalEndpoint]，多供应商下视觉/文本可各走各家）。
  static Future<String> _chatExternal({
    required ExternalEndpoint endpoint,
    required String prompt,
    String? imageBase64,
    List<String>? images,
    int numPredict = 256,
    bool jsonFormat = false,
    bool wantThinking = false,
    OllamaTrace? trace,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final uri = externalUri(endpoint.baseUrl, '/chat/completions');
    final apiKey = endpoint.apiKey.trim();
    final model = endpoint.model;
    final headers = {
      'Content-Type': 'application/json',
      if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
    };
    final imgs =
        images ??
        (imageBase64 != null && imageBase64.isNotEmpty
            ? [imageBase64]
            : const <String>[]);
    var includeImages = imgs.isNotEmpty;
    var useJsonFormat = jsonFormat;
    // 请求体带整行图 + 40 张字图的 base64 时达 MB 级：编码搬后台
    // isolate（12 worker 并发时 UI isolate 上的同步编码会饿死消息泵）。
    Future<http.Response> send() async {
      final body = await encodeJsonInIsolate(
        _externalChatBody(
          model: model,
          prompt: prompt,
          images: includeImages ? imgs : null,
          // 推理模型（GLM/DeepSeek-R1 等）的思维链也计入 max_tokens
          // 并默认输出 reasoning_content：开启思考过程时放大限额，
          // 避免思维链把正文挤到截断。
          numPredict: wantThinking ? numPredict + 2048 : numPredict,
          jsonFormat: useJsonFormat,
        ),
      );
      return http.post(uri, headers: headers, body: body).timeout(timeout);
    }
    http.Response r;
    try {
      r = await send();
      // 部分兼容网关不认 json_object：去掉 response_format 重试一次，
      // prompt 本身已要求只输出 JSON，解析层也容忍围栏与废话。
      if (useJsonFormat &&
          r.statusCode == 400 &&
          _rejectsResponseFormat(r.body)) {
        useJsonFormat = false;
        r = await send();
      }
      // 纯文本模型拒绝图像（400）：去图按纯上下文重试一次。
      if (includeImages && r.statusCode == 400 && _isNoMultimodal(r.body)) {
        includeImages = false;
        trace?.imageDropped = true;
        r = await send();
      }
    } on TimeoutException {
      throw OllamaException(
        'AI 推理超时（>${timeout.inSeconds} 秒）——外部模型响应太慢，'
        '可换更小的模型或稍后重试',
      );
    } catch (e) {
      throw OllamaException(_externalConnectionHint(endpoint.baseUrl, e));
    }
    if (r.statusCode != 200) {
      throw OllamaException(_externalApiError(r.statusCode, r.body));
    }
    final (content, thinking) = await _parseExternalChat(r.body);
    if (content.isEmpty) {
      throw OllamaException('AI 返回了空内容，请重试或换模型');
    }
    trace
      ?..thinking = thinking
      ..rawContent = content;
    return content;
  }

  /// 构建 chat/completions 请求体（测试直接覆盖）。带图时 content 用
  /// OpenAI 多模态分片数组（多图任务输出多个 image_url 分片），纯文本时
  /// 保持字符串（兼容面最广）。
  static Map<String, dynamic> _externalChatBody({
    required String model,
    required String prompt,
    String? imageBase64,
    List<String>? images,
    int numPredict = 256,
    bool jsonFormat = false,
  }) {
    final allImages =
        images ??
        (imageBase64 != null && imageBase64.isNotEmpty
            ? [imageBase64]
            : const <String>[]);
    return {
      'model': model,
      'messages': [
        {
          'role': 'user',
          'content': allImages.isEmpty
              ? prompt
              : [
                  {'type': 'text', 'text': prompt},
                  for (final b64 in allImages)
                    {
                      'type': 'image_url',
                      'image_url': {'url': 'data:image/png;base64,$b64'},
                    },
                ],
        },
      ],
      'max_tokens': numPredict,
      'temperature': 0.2,
      if (jsonFormat) 'response_format': {'type': 'json_object'},
    };
  }

  /// 从 chat/completions 响应提取回答文本与思维链：content 少数网关拆成
  /// 分片数组（逐片取 text 拼接）；思维链取 reasoning_content（GLM /
  /// DeepSeek-R1 / Kimi 兼容口径）或 reasoning.summary（OpenAI o 系兼容
  /// 层）。解析失败返回空串（上层报可读错误）。解码在后台 isolate 做
  ///（响应含思维链时达数十 KB~MB 级）。
  static Future<(String, String)> _parseExternalChat(String body) async {
    try {
      final data = await decodeJsonInIsolate(body);
      return _parseExternalChatData(data is Map ? data : null);
    } catch (_) {
      return ('', '');
    }
  }

  static (String, String) _parseExternalChatData(Map? data) {
    try {
      final choices = data?['choices'];
      if (choices is List && choices.isNotEmpty) {
        final choice = choices.first;
        final message = choice is Map ? choice['message'] : null;
        if (message is Map) {
          final raw = message['content'];
          final content = raw is List
              ? raw
                    .map((p) => p is Map ? (p['text']?.toString() ?? '') : '')
                    .join()
                    .trim()
              : raw?.toString().trim() ?? '';
          final thinking = _extractReasoning(message);
          return (content, thinking);
        }
      }
      return ('', '');
    } catch (_) {
      return ('', '');
    }
  }

  /// 兼容各家的思维链字段：reasoning_content 字符串优先；其次
  /// reasoning.summary 数组（OpenAI o 系兼容层）；再其次 reasoning
  /// 字符串（部分网关直接放字符串）。
  static String _extractReasoning(Map message) {
    final rc = message['reasoning_content'];
    if (rc is String && rc.trim().isNotEmpty) return rc.trim();
    final rs = message['reasoning'];
    if (rs is String && rs.trim().isNotEmpty) return rs.trim();
    if (rs is Map) {
      final summary = rs['summary'];
      if (summary is List) {
        final parts = <String>[];
        for (final e in summary) {
          if (e is Map) {
            final t = e['text']?.toString() ?? '';
            if (t.isNotEmpty) parts.add(t);
          }
        }
        return parts.join('\n').trim();
      }
    }
    return '';
  }

  /// OpenAI 兼容 GET /models 响应 → 模型名列表（按名排序，无体积信息）。
  static List<String> _parseExternalModels(String body) {
    try {
      final data = jsonDecode(body) as Map<String, dynamic>;
      final list = data['data'];
      if (list is! List) return const [];
      final names = <String>[];
      for (final raw in list) {
        if (raw is! Map) continue;
        final id = raw['id']?.toString() ?? '';
        if (id.isNotEmpty) names.add(id);
      }
      names.sort();
      return names;
    } catch (_) {
      return const [];
    }
  }

  /// 外部 API 地址 → 请求端点。粘贴完整 …/chat/completions 也能归一到
  /// 根地址再拼路径；未填地址直接抛可读错误。（压测探针在外部 API 实为
  /// 本机服务时也用它拼 /chat/completions。）
  static Uri externalUri(String baseUrl, String path) {
    var base = baseUrl.trim();
    if (base.isEmpty) {
      throw OllamaException('未填写外部 API 地址——请在「AI 辅助设置」中填写');
    }
    if (!base.startsWith('http://') && !base.startsWith('https://')) {
      base = 'https://$base';
    }
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    const suffix = '/chat/completions';
    if (base.endsWith(suffix)) {
      base = base.substring(0, base.length - suffix.length);
    }
    return Uri.parse('$base$path');
  }

  /// 外部 API 地址是否指向本机环回（localhost / 127.0.0.0/8 / ::1 /
  /// 0.0.0.0）。为真时「外部模型」实为本机推理服务（one-api、LiteLLM、
  /// llama.cpp server、vLLM 等本地 OpenAI 兼容网关），并发瓶颈在本机，
  /// 压测照常适用、显存看门狗有效；解析失败按非环回处理（不放开压测）。
  /// 局域网地址（192.168.x 等）不算——那是另一台机器，本机显存看门狗
  /// 对它没有意义。
  static bool isLoopbackBaseUrl(String baseUrl) {
    try {
      final host = externalUri(baseUrl, '').host.toLowerCase();
      if (host == 'localhost' || host == '::1' || host == '0.0.0.0') {
        return true;
      }
      final parts = host.split('.');
      return parts.length == 4 &&
          parts.first == '127' &&
          parts.every((p) {
            final v = int.tryParse(p);
            return v != null && v >= 0 && v <= 255;
          });
    } catch (_) {
      return false;
    }
  }

  /// 网关拒绝 response_format 的 400 签名（各家措辞不一，统一按
  /// 关键字识别，不再细分 json_object / json_schema）。
  static bool _rejectsResponseFormat(String body) =>
      body.toLowerCase().contains('response_format');

  /// 非思考型模型收到 think:true 的 400 签名（Ollama 2026 版措辞
  /// "model does not support thinking"，宽匹配兼容变体）。
  static bool _rejectsThinking(String body) {
    final lower = body.toLowerCase();
    return lower.contains('thinking') &&
        (lower.contains('support') ||
            lower.contains('disabled') ||
            lower.contains('not enabled'));
  }

  /// HTTP 状态 → 用户可读的排查提示，正文优先取 error.message。
  static String _externalApiError(int status, String body) {
    final detail = _extractApiError(body);
    switch (status) {
      case 401:
      case 403:
        return 'API Key 无效或没有权限（$status）'
            '${detail.isEmpty ? '' : '：$detail'}。'
            '请到服务商控制台核对密钥后重填。';
      case 404:
        return '接口地址或模型名不存在（404）'
            '${detail.isEmpty ? '' : '：$detail'}。'
            '请检查 API 地址（填到 /v1 这一级）与模型名。';
      case 429:
        return '请求过于频繁或额度不足（429）'
            '${detail.isEmpty ? '' : '：$detail'}。'
            '请稍后重试，或到服务商控制台查看余额与限流。';
      default:
        final text = detail.isNotEmpty ? detail : _snippet(body);
        return '外部模型 API 返回 $status${text.isEmpty ? '' : '：$text'}';
    }
  }

  /// 从错误响应正文提取 message（OpenAI 风格 {"error":{"message":…}}
  /// 或部分网关的顶层 message）。
  static String _extractApiError(String body) {
    try {
      final data = jsonDecode(body);
      if (data is Map) {
        final err = data['error'];
        if (err is Map) return _snippet(err['message']?.toString() ?? '');
        if (err is String) return _snippet(err);
        final msg = data['message'];
        if (msg is String) return _snippet(msg);
      }
    } catch (_) {}
    return '';
  }

  static String _externalConnectionHint(String baseUrl, Object e) {
    return '无法连接外部模型 API（$baseUrl）：$e。\n'
        '请确认：① API 地址填写正确（一般以 /v1 结尾，'
        '如 https://api.deepseek.com/v1）；② 本机可访问对应服务。';
  }

  /// Ollama 推理 runner 崩溃的响应签名（Windows 上 wsarecv 连接被强制
  /// 关闭 = runner 子进程死了，典型于显存不足/驱动重置，多为偶发）。
  static bool _isRunnerCrash(int status, String body) =>
      status == 500 &&
      (body.contains('running the model') ||
          body.contains('forcibly closed') ||
          body.contains('wsarecv'));

  /// 纯文本模型拒绝图像请求的 400 签名。实测 Ollama 2026 版报
  /// "Multimodal data provided, but model does not support multimodal
  /// requests."，外部 OpenAI 兼容服务多为 "does not support image
  /// input(s)" 一类措辞；统一小写匹配，可能被上游再包一层 JSON。
  static bool _isNoMultimodal(String body) {
    final lower = body.toLowerCase();
    return lower.contains('multimodal data provided') ||
        lower.contains('does not support multimodal') ||
        lower.contains('does not support image') ||
        lower.contains('not support image input') ||
        lower.contains('does not accept image') ||
        lower.contains('image input is not supported') ||
        lower.contains('image is not supported');
  }

  /// 测试入口：直接暴露整页预标注解析（生产代码请走 prelabelPageLayout）。
  @visibleForTesting
  static OllamaPagePrelabel parsePagePrelabelForTest(String content) =>
      _parsePagePrelabel(content);

  /// 测试入口：AI 画框测试解析（生产代码请走 charBoxesFromImage）。
  @visibleForTesting
  static OllamaCharBoxes parseCharBoxesForTest(
    String content, {
    required AiBoxCoordMode mode,
    required int imageWidth,
    required int imageHeight,
  }) => _parseCharBoxes(
    content,
    mode: mode,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
  );

  /// 测试入口：暴露 multimodal 拒绝签名判定。
  @visibleForTesting
  static bool noMultimodalForTest(String body) => _isNoMultimodal(body);

  /// 测试入口：暴露 runner 崩溃签名判定（生产代码走 _chat 的自动重试）。
  @visibleForTesting
  static bool isRunnerCrashForTest(int status, String body) =>
      _isRunnerCrash(status, body);

  /// 测试入口：外部 chat/completions 请求体构建（多图任务传 [images]）。
  @visibleForTesting
  static Map<String, dynamic> externalChatBodyForTest({
    required String model,
    required String prompt,
    String? imageBase64,
    List<String>? images,
    int numPredict = 256,
    bool jsonFormat = false,
  }) => _externalChatBody(
    model: model,
    prompt: prompt,
    imageBase64: imageBase64,
    images: images,
    numPredict: numPredict,
    jsonFormat: jsonFormat,
  );

  /// 测试入口：chat/completions 响应解析，返回 (content, thinking)。
  /// 非法 JSON 返回空串（与 _parseExternalChat 同口径）。
  @visibleForTesting
  static (String, String) parseExternalChatForTest(String body) {
    try {
      return _parseExternalChatData(jsonDecode(body) as Map<String, dynamic>?);
    } catch (_) {
      return ('', '');
    }
  }

  /// 测试入口：GET /models 响应解析。
  @visibleForTesting
  static List<String> parseExternalModelsForTest(String body) =>
      _parseExternalModels(body);

  /// 测试入口：HTTP 状态 → 用户可读错误。
  @visibleForTesting
  static String externalApiErrorForTest(int status, String body) =>
      _externalApiError(status, body);

  /// 测试入口：response_format 拒绝签名判定。
  @visibleForTesting
  static bool rejectsResponseFormatForTest(String body) =>
      _rejectsResponseFormat(body);

  /// 测试入口：think:true 拒绝签名判定。
  @visibleForTesting
  static bool rejectsThinkingForTest(String body) => _rejectsThinking(body);

  static Uri _uri(String baseUrl, String path) {
    var base = baseUrl.trim();
    if (base.isEmpty) base = OllamaSettings.defaultBaseUrl;
    if (!base.startsWith('http://') && !base.startsWith('https://')) {
      base = 'http://$base';
    }
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return Uri.parse('$base$path');
  }

  static String _connectionHint(String baseUrl, Object e) {
    return '无法连接 Ollama（$baseUrl）：$e。\n'
        '请确认：① 已安装并运行 Ollama（命令行执行 ollama serve 或桌面版已启动）；'
        '② 地址端口正确（默认 http://localhost:11434）。';
  }

  static String _snippet(String body) {
    final t = body.trim().replaceAll('\n', ' ');
    return t.length <= 200 ? t : '${t.substring(0, 200)}…';
  }

  // ── 响应解析 ──

  /// 测试入口：直接暴露响应解析（生产代码请走 suggestChar/suggestPunctuation）。
  /// [punct] = 标点辅助的白名单；[cjkAndPunct] = 单字辅助的合并白名单。
  @visibleForTesting
  static List<OllamaSuggestion> parseSuggestionsForTest(
    String content, {
    bool punct = false,
    bool cjkAndPunct = false,
  }) {
    return _parseSuggestions(
      content,
      allowedCharset: cjkAndPunct
          ? _cjkAndPunctChars
          : (punct ? _punctChars : _cjkChars),
      fallbackExtractor: cjkAndPunct
          ? _extractCjkOrPunct
          : (punct ? _extractPunct : _extractCjk),
    );
  }

  /// 测试入口：直接暴露框检查诊断解析（生产代码请走 diagnoseLineBox）。
  @visibleForTesting
  static OllamaBoxDiagnosis parseDiagnosisForTest(
    String content, {
    int charCount = 10,
  }) => _parseBoxDiagnosis(content, charCount: charCount);

  /// 解析框检查诊断 JSON：容忍围栏与前后废话；type 白名单外的条目
  /// 丢弃、pos 钳到 [0, charCount]；line_ok 缺省按"有问题=issues 非空"
  /// 推。解析不出任何结构时视为"模型答非所问"，返回 line_ok 的空诊断
  /// （调用方当作无问题处理，不阻塞检查）。
  static OllamaBoxDiagnosis _parseBoxDiagnosis(
    String content, {
    required int charCount,
  }) {
    for (final chunk in _jsonCandidates(content)) {
      try {
        final decoded = jsonDecode(chunk);
        if (decoded is! Map) continue;
        final okRaw = decoded['line_ok'];
        final rawIssues = decoded['issues'];
        final issues = <OllamaBoxIssue>[];
        if (rawIssues is List) {
          for (final raw in rawIssues) {
            if (raw is! Map) continue;
            final type = OllamaBoxIssueType.fromWire(
              raw['type']?.toString() ?? '',
            );
            if (type == null) continue;
            var pos = (raw['pos'] as num?)?.toInt() ?? 0;
            if (pos < 0) pos = 0;
            if (charCount > 0 && pos > charCount) pos = charCount;
            issues.add(
              OllamaBoxIssue(
                type: type,
                pos: pos,
                note: raw['note']?.toString() ?? '',
              ),
            );
          }
        }
        final lineOk = okRaw is bool ? okRaw : issues.isEmpty;
        final confidence = (decoded['confidence'] as num?)?.toDouble() ?? 0;
        return OllamaBoxDiagnosis(
          lineOk: lineOk,
          issues: issues,
          confidence: confidence.clamp(0.0, 1.0),
        );
      } catch (_) {
        // 这一段不是合法 JSON，试下一段。
      }
    }
    return const OllamaBoxDiagnosis(lineOk: true, issues: []);
  }

  /// 优先解析模型输出的 JSON（容忍 ```json 围栏与前后废话）；解析不出
  /// 时退化为按出现顺序抽取候选字符。所有候选都过滤到 [allowedCharset]。
  static List<OllamaSuggestion> _parseSuggestions(
    String content, {
    required String allowedCharset,
    required List<String> Function(String) fallbackExtractor,
  }) {
    final results = <OllamaSuggestion>[];
    void add(String text, double score, String reason) {
      final t = text.trim();
      if (t.isEmpty || t.length > 1) return;
      if (!allowedCharset.contains(t)) return;
      if (results.any((s) => s.text == t)) return;
      results.add(OllamaSuggestion(text: t, score: score, reason: reason));
    }

    for (final chunk in _jsonCandidates(content)) {
      try {
        final decoded = jsonDecode(chunk);
        if (decoded is Map) {
          final list = decoded['candidates'];
          if (list is List) {
            for (final item in list) {
              if (item is Map) {
                add(
                  item['text']?.toString() ?? '',
                  (item['score'] as num?)?.toDouble() ?? 0,
                  item['reason']?.toString() ?? '',
                );
              } else if (item is String) {
                add(item, 0, '');
              }
            }
          }
        } else if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              add(
                item['text']?.toString() ?? '',
                (item['score'] as num?)?.toDouble() ?? 0,
                item['reason']?.toString() ?? '',
              );
            } else if (item is String) {
              add(item, 0, '');
            }
          }
        }
      } catch (_) {
        // 这一段不是合法 JSON，试下一段。
      }
      if (results.isNotEmpty) return results;
    }

    for (final t in fallbackExtractor(content)) {
      add(t, 0, '');
    }
    if (results.isEmpty) {
      throw OllamaException(
        'AI 返回内容无法解析为候选（原始输出：'
        '${content.length > 120 ? '${content.substring(0, 120)}…' : content}）',
      );
    }
    return results;
  }

  /// 从可能被废话/围栏包住的文本里抠出 JSON 对象片段。
  static List<String> _jsonCandidates(String content) {
    final chunks = <String>[];
    var fenced = RegExp(r'```(?:json)?\s*([\s\S]*?)```').allMatches(content);
    for (final m in fenced) {
      chunks.add(m.group(1)!.trim());
    }
    // Vision models occasionally append a second JSON object or put braces in
    // a short explanation.  The old first-{}/last-{} slice then became an
    // invalid combined document even though the first object was valid.  Pick
    // balanced top-level objects before trying that permissive fallback.
    var start = -1;
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = 0; i < content.length; i++) {
      final code = content.codeUnitAt(i);
      final ch = String.fromCharCode(code);
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch == '\\') {
          escaped = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }
      if (ch == '"') {
        inString = true;
      } else if (ch == '{') {
        if (depth == 0) start = i;
        depth++;
      } else if (ch == '}' && depth > 0) {
        depth--;
        if (depth == 0 && start >= 0) {
          chunks.add(content.substring(start, i + 1).trim());
          start = -1;
        }
      }
    }
    // Keep the original greedy candidate as a final fallback for malformed
    // escaped output; valid balanced objects above always win first.
    final first = content.indexOf('{');
    final end = content.lastIndexOf('}');
    if (first >= 0 && end > first) {
      chunks.add(content.substring(first, end + 1));
    }
    chunks.add(content.trim());
    return chunks;
  }

  /// 兜底抽取：优先收「字」『字』“字”这类引号包裹的单字（模型常用
  /// 引号列出候选），没有引号再按出现顺序收内容里的字（去重，最多 5 个）。
  static List<String> _extractCjk(String content) {
    return _extractChars(content, _cjkChars, 5);
  }

  /// 单字辅助兜底抽取：汉字与标点同集（最多 5 个）。引号包裹位允许
  /// 标点——括号/书名号本身常是被推荐的候选，通用抽取的包裹位排除了
  /// 括号字符（只服务汉字），这里需要放宽；包裹位抽到非白名单字符仍
  /// 会被字符集检查剔除。
  static List<String> _extractCjkOrPunct(String content) {
    final seen = <String>{};
    final quoted = RegExp('[「『《〈（(【\\[]([^\\s])[」』》〉（）)】\\[\\]]');
    for (final m in quoted.allMatches(content)) {
      final ch = m.group(1)!;
      if (_cjkAndPunctChars.contains(ch)) seen.add(ch);
      if (seen.length >= 5) return seen.toList();
    }
    if (seen.isNotEmpty) return seen.toList();
    return _extractChars(content, _cjkAndPunctChars, 5);
  }

  /// 标点兜底抽取：同上策略，收标点集合内的字符（最多 4 个）。
  static List<String> _extractPunct(String content) {
    return _extractChars(content, _punctChars, 4);
  }

  /// 引号优先、出现顺序兜底的字符抽取。模型用散文回答时（如"这个字
  /// 最有可能是「德」"），直接按顺序收会把散文的"这个字最"也当候选，
  /// 因此先收引号内的，收不满再收裸露的。
  static List<String> _extractChars(String content, String charset, int limit) {
    final seen = <String>{};
    // 直角引号/书名号/括号包裹的单字（模式刻意不含引号字符，避免
    // 原始字符串转义问题）。弯引号场景罕见，兜底循环已能覆盖。
    final quoted = RegExp(
      '[「『《〈（(【\\[]'
      '([^\\s「」『』《》〈〉（）()【】\\[\\]])'
      '[」』》〉（）)】\\[\\]]',
    );
    for (final m in quoted.allMatches(content)) {
      final ch = m.group(1)!;
      if (charset.contains(ch)) seen.add(ch);
      if (seen.length >= limit) return seen.toList();
    }
    // 引号里一个都没抽到才退回裸露顺序抽取：模型散文作答时裸抽会把
    // "这个字最"这类废话字也带进来，有引号结果时不能再混入。
    if (seen.isNotEmpty) return seen.toList();
    for (final rune in content.runes) {
      final ch = String.fromCharCode(rune);
      if (charset.contains(ch)) seen.add(ch);
      if (seen.length >= limit) break;
    }
    return seen.toList();
  }

  /// CJK 统一表意文字（含扩展 A）+ 部首符号，覆盖古籍常用字。
  static bool _isCjkRune(int r) =>
      (r >= 0x3400 && r <= 0x9FFF) || (r >= 0xF900 && r <= 0xFAFF);

  static final String _cjkChars = String.fromCharCodes([
    for (var r = 0x3400; r <= 0x9FFF; r++)
      if (_isCjkRune(r)) r,
    for (var r = 0xF900; r <= 0xFAFF; r++)
      if (_isCjkRune(r)) r,
  ]);

  /// 古籍句读与常见标点。
  static const String _punctChars = '。，、；：？！…—·「」『』《》〈〉（）()【】[]〔］"\'「」○●◎〇※~～';

  /// 单字辅助的候选集：汉字 + 各类标点（句读、括号、书名号、引号等）。
  static final String _cjkAndPunctChars = _cjkChars + _punctChars;
}

/// AI 框检查的一条问题诊断（VLM 从固定操作菜单里选，不出坐标）。
enum OllamaBoxIssueType {
  /// 该"行"实为并排双列（夹注/旁注），应拆成多行。
  mergeTwoLines('merge_two_lines'),

  /// pos 处一个框盖住了两个字（粘连未切开）。
  charMerged('char_merged'),

  /// pos 处的框切掉了字形的一部分（框太小）。
  charClipped('char_clipped'),

  /// pos 处的框把旁边墨迹（邻字/污渍）多包了进来（框太大）。
  charExtraInk('char_extra_ink'),

  /// 行内有字但没识别出来（漏字/漏框）。
  missingChars('missing_chars');

  const OllamaBoxIssueType(this.wire);

  /// 协议里的字符串标识。
  final String wire;

  /// 修复优先级：先拆行，再补字，再修单字框。
  int get priority => switch (this) {
    OllamaBoxIssueType.mergeTwoLines => 0,
    OllamaBoxIssueType.missingChars => 1,
    OllamaBoxIssueType.charMerged ||
    OllamaBoxIssueType.charClipped ||
    OllamaBoxIssueType.charExtraInk => 2,
  };

  static OllamaBoxIssueType? fromWire(String s) {
    for (final t in OllamaBoxIssueType.values) {
      if (t.wire == s) return t;
    }
    return null;
  }
}

/// 一条经校验的诊断（type 在白名单内、pos 已钳到 [1, charCount]）。
class OllamaBoxIssue {
  const OllamaBoxIssue({
    required this.type,
    required this.pos,
    required this.note,
  });

  final OllamaBoxIssueType type;

  /// 1 基字序号；与字无关的类型（拆行/漏字）为 0。
  final int pos;

  final String note;
}

/// 一行的 AI 框检查诊断结果：line_ok + 校验过的问题列表（按修复优先级
/// 排序，调用方只取第一条执行）+ VLM 自评置信度。
class OllamaBoxDiagnosis {
  const OllamaBoxDiagnosis({
    required this.lineOk,
    required this.issues,
    this.confidence = 0,
  });

  final bool lineOk;
  final List<OllamaBoxIssue> issues;
  final double confidence;

  OllamaBoxIssue? get topIssue => issues.isEmpty
      ? null
      : issues.reduce((a, b) => a.type.priority <= b.type.priority ? a : b);
}

/// 该文本是否为标点（用于判定小字框是否走"标点辅助"分支）。
bool isPunctuationText(String text) {
  final t = text.trim();
  if (t.isEmpty || t.length > 1) return false;
  return '。，、；：？！…—·「」『』《》〈〉（）()【】[]〔］"\'○●◎〇※~～'.contains(t);
}
