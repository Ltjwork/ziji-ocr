import 'hardware_info.dart';

/// 目录条目的用途（对应「AI 辅助设置」里两个模型槽位）。
enum OllamaModelKind { vision, text }

/// 与当前硬件的适配程度（推荐列表的排序与徽章依据）。
enum OllamaModelFit {
  /// 显存充裕：推理全进显存，响应快，"无感"。
  smooth,

  /// 显存刚好够：基本流畅，偶有波动。
  usable,

  /// 显存吃紧：部分层回落内存，速度明显下降，可用但不快。
  tight,

  /// 无独显时的 CPU 推理档：模型足够小，速度尚可接受。
  cpuOk,

  /// 超出当前配置：不建议安装（列表仍可手动安装）。
  tooHeavy,
}

/// 推荐目录中的一条模型。
class OllamaCatalogEntry {
  const OllamaCatalogEntry({
    required this.name,
    required this.kind,
    required this.sizeGb,
    required this.releaseDate,
    required this.summary,
  });

  /// Ollama 模型 tag（默认 q4_K_M 量化档），如 'qwen3.5:4b'。
  final String name;

  final OllamaModelKind kind;

  /// 下载体积（GB，ollama.com 2026-09 实测默认量化档）。
  final double sizeGb;

  /// 发布月份（YYYY-MM，按官方发布/ollama.com 模型库收录时间，
  /// 月份粒度），供选型时参考新旧。
  final String releaseDate;

  /// 一句话说明（列表行副标题）。
  final String summary;

  /// 推理期显存占用估算：权重体积 + KV 缓存/视觉编码器等运行开销。
  /// Ollama 默认还会常驻一层几百 MB 的 embedding 模型，取 1.5GB 起步。
  double get vramNeedGb => sizeGb + 1.5;

  String get baseName => name.split(':').first;
}

/// 目录 + 推荐逻辑。体积为 2026-09 从 ollama.com 模型库核实的默认
/// 量化档下载体积；新模型直接往 [catalog] 里加条目即可。
class OllamaModelCatalog {
  OllamaModelCatalog._();

  /// 单字图像辅助（视觉多模态）：古籍单字字形 + 上下文给候选。
  static const List<OllamaCatalogEntry> vision = [
    OllamaCatalogEntry(
      name: 'minicpm-v4.6:1b',
      kind: OllamaModelKind.vision,
      sizeGb: 1.6,
      releaseDate: '2026-06',
      summary: '手机级小模型，无独显时 CPU 推理的兜底选择',
    ),
    OllamaCatalogEntry(
      name: 'glm-ocr:latest',
      kind: OllamaModelKind.vision,
      sizeGb: 2.2,
      releaseDate: '2026-02',
      summary: 'OCR 专用模型，体积小、文档理解强，性价比高',
    ),
    OllamaCatalogEntry(
      name: 'qwen3-vl:2b',
      kind: OllamaModelKind.vision,
      sizeGb: 1.9,
      releaseDate: '2025-10',
      summary: 'OCR 能力强的多模态小模型，低配独显可带动',
    ),
    OllamaCatalogEntry(
      name: 'qwen3.5:4b',
      kind: OllamaModelKind.vision,
      sizeGb: 3.4,
      releaseDate: '2026-02',
      summary: '质量/速度均衡，8GB 级显存的主力',
    ),
    OllamaCatalogEntry(
      name: 'qwen3-vl:4b',
      kind: OllamaModelKind.vision,
      sizeGb: 3.3,
      releaseDate: '2025-10',
      summary: 'OCR 强项的多模态小模型，与 qwen3.5:4b 二选一',
    ),
    OllamaCatalogEntry(
      name: 'qwen3.5:9b',
      kind: OllamaModelKind.vision,
      sizeGb: 6.6,
      releaseDate: '2026-02',
      summary: '单字识别质量首选，12GB+ 显存可流畅运行',
    ),
    OllamaCatalogEntry(
      name: 'qwen3.5:27b',
      kind: OllamaModelKind.vision,
      sizeGb: 17,
      releaseDate: '2026-02',
      summary: '识别质量上限，需要 24GB+ 显存',
    ),
  ];

  /// 标点上下文辅助（纯文本）：按前后文推荐句读，小模型即可。
  static const List<OllamaCatalogEntry> text = [
    OllamaCatalogEntry(
      name: 'qwen3:1.7b',
      kind: OllamaModelKind.text,
      sizeGb: 1.4,
      releaseDate: '2025-04',
      summary: '句读推荐足够用，响应最快',
    ),
    OllamaCatalogEntry(
      name: 'qwen3:4b',
      kind: OllamaModelKind.text,
      sizeGb: 2.5,
      releaseDate: '2025-04',
      summary: '句读质量与速度均衡',
    ),
    OllamaCatalogEntry(
      name: 'qwen3:8b',
      kind: OllamaModelKind.text,
      sizeGb: 5.2,
      releaseDate: '2025-04',
      summary: '文本理解更好，显存/内存富余时选',
    ),
  ];

  static const List<OllamaCatalogEntry> catalog = [...vision, ...text];

  static OllamaCatalogEntry? findEntry(String name) {
    final base = name.split(':').first;
    for (final e in catalog) {
      if (e.name == name || e.baseName == base) return e;
    }
    return null;
  }

  /// 按当前硬件生成推荐列表：先视觉后文本，同组内适配好的在前、
  /// 同档位体积大的（质量更高）在前，并标出每组的「最优选择」。
  static List<OllamaModelRecommendation> recommendForHardware(
    HardwareInfo hw,
  ) {
    final vramGb = hw.hasNvidiaGpu ? hw.vramTotalMb / 1024 : 0.0;
    final ramGb = hw.ramTotalMb / 1024;

    OllamaModelFit fitOf(OllamaCatalogEntry e) {
      if (vramGb > 0) {
        final need = e.vramNeedGb;
        if (vramGb >= need * 1.15) return OllamaModelFit.smooth;
        if (vramGb >= need) return OllamaModelFit.usable;
        if (vramGb >= need * 0.8) return OllamaModelFit.tight;
      }
      // 显存带不动（或没有独显）：小模型看内存，CPU 推理兜底。
      return _cpuFit(e, ramGb);
    }

    const fitRank = {
      OllamaModelFit.smooth: 0,
      OllamaModelFit.usable: 1,
      OllamaModelFit.tight: 2,
      OllamaModelFit.cpuOk: 3,
      OllamaModelFit.tooHeavy: 4,
    };

    final result = <OllamaModelRecommendation>[];
    for (final kind in OllamaModelKind.values) {
      final group =
          catalog.where((e) => e.kind == kind).map((e) => (e, fitOf(e))).toList()
            ..sort((a, b) {
              final byFit = fitRank[a.$2]!.compareTo(fitRank[b.$2]!);
              if (byFit != 0) return byFit;
              return b.$1.sizeGb.compareTo(a.$1.sizeGb);
            });
      final best = _bestOf(group);
      result.addAll([
        for (final (entry, fit) in group)
          OllamaModelRecommendation(
            entry: entry,
            fit: fit,
            bestPick: identical(entry, best),
          ),
      ]);
    }
    return result;
  }

  /// 每组最优：按 smooth > usable > tight > cpuOk 取档位内体积最大的
  /// （体积大 ≈ 质量高）；全是 tooHeavy 时该组没有推荐。
  static OllamaCatalogEntry? _bestOf(
    List<(OllamaCatalogEntry, OllamaModelFit)> group,
  ) {
    for (final fit in [
      OllamaModelFit.smooth,
      OllamaModelFit.usable,
      OllamaModelFit.tight,
      OllamaModelFit.cpuOk,
    ]) {
      final candidates = [
        for (final (entry, f) in group)
          if (f == fit) entry,
      ];
      if (candidates.isNotEmpty) {
        return candidates.reduce(
          (a, b) => a.sizeGb >= b.sizeGb ? a : b,
        );
      }
    }
    return null;
  }

  /// CPU 推理可行性：模型权重 + 运行时开销约按 2.5 倍体积估内存，
  /// 且超过 3.5GB 的模型在 CPU 上慢到失去"辅助"意义，直接不推荐。
  static OllamaModelFit _cpuFit(OllamaCatalogEntry e, double ramGb) {
    if (e.sizeGb <= 3.5 && ramGb >= e.sizeGb * 2.5 + 2) {
      return OllamaModelFit.cpuOk;
    }
    return OllamaModelFit.tooHeavy;
  }

  /// 从用户输入抠出模型名：容忍直接粘贴完整命令（"ollama pull
  /// qwen3.5:4b"、带引号、前后空白），也接受纯模型名。不合法返回 null。
  static String? parseModelNameFromCommand(String input) {
    var t = input.trim();
    if (t.isEmpty) return null;
    final pull = RegExp(r'ollama\s+pull\s+(\S+)').firstMatch(t);
    if (pull != null) t = pull.group(1)!;
    t = t.replaceAll('"', '').replaceAll("'", '').trim();
    // 模型名只允许 字母数字 . : / - _（含 hf.co/... 这类远程仓库路径），
    // 有空白或反斜杠一律视为没输入对。
    if (t.isEmpty || RegExp(r'[\s\\]').hasMatch(t)) return null;
    if (!RegExp(r'^[A-Za-z0-9._:/\-]+$').hasMatch(t)) return null;
    return t;
  }
}

/// 推荐列表的一行：条目 + 适配评级 + 是否该组最优。
class OllamaModelRecommendation {
  const OllamaModelRecommendation({
    required this.entry,
    required this.fit,
    required this.bestPick,
  });

  final OllamaCatalogEntry entry;
  final OllamaModelFit fit;
  final bool bestPick;

  /// 徽章文案（UI 直接用）。
  String get fitLabel => switch (fit) {
    OllamaModelFit.smooth => '显存充裕 · 流畅',
    OllamaModelFit.usable => '显存够用',
    OllamaModelFit.tight => '显存吃紧 · 偏慢',
    OllamaModelFit.cpuOk => 'CPU 可跑',
    OllamaModelFit.tooHeavy => '超出配置 · 不推荐',
  };
}
