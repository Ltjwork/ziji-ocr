import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../services/python_service.dart';

/// PaddleOCR 识别模型清单——后端 paddle_proc.PP_OCRV6_MODELS 的 Dart 镜像
/// （JSON 字段基线在后端，此处只作展示；两侧同步修改、只追加不改名）。
class PaddleModelChoice {
  const PaddleModelChoice({
    required this.name,
    required this.label,
    required this.requirement,
  });

  final String name; // 后端模型名（PP-OCRv6_*_rec / PaddleOCR-VL-1.6）
  final String label; // 下拉展示名（含体积）
  final String requirement; // 配置要求文案（用户按此选档）

  /// 选项标题：模型名在前（用户要知道"用的到底是哪个模型"，只看
  /// "轻量/小模型"这类昵称分不清），友好描述跟在后面。
  String get displayLabel => '$name · $label';
}

const List<PaddleModelChoice> kPaddleModelChoices = [
  PaddleModelChoice(
    name: 'PP-OCRv6_tiny_rec',
    label: '极轻量 4.4MB',
    requirement: 'CPU 即可运行，无独立显卡/低配电脑可用；速度最快、精度最低',
  ),
  PaddleModelChoice(
    name: 'PP-OCRv6_small_rec',
    label: '小模型（蒸馏）20.4MB · 默认',
    requirement: 'CPU 可运行（速度较慢）；入门独立显卡（显存 ≥2GB）即流畅；精度与速度均衡，古籍识别推荐起点',
  ),
  PaddleModelChoice(
    name: 'PP-OCRv6_medium_rec',
    label: '中等 73.3MB',
    requirement: '建议 NVIDIA 独立显卡（显存 ≥4GB）+ GPU 版 paddlepaddle；精度最高、最慢',
  ),
  PaddleModelChoice(
    name: 'PP-OCRv3_mobile_rec',
    label: 'v3 轻量 9.8MB',
    requirement: 'CPU 即可运行；老一代模型（2022），精度低于 v5/v6；整页直读不支持竖排（v5 起原生支持），适合横排书籍或引擎对照',
  ),
  PaddleModelChoice(
    name: 'PaddleOCR-VL-1.6',
    label: '视觉语言模型 0.9B · 古籍最强',
    requirement: '需 NVIDIA 独立显卡（建议显存 ≥8GB）+ GPU 版 paddlepaddle，首次下载约 1.9GB；古籍竖排、标点、复杂版式显著更强；CPU 极慢不建议；仅整页直读（文本视图）可用，行/字识别请选 PP-OCR 系模型',
  ),
];

const String kDefaultPaddleModel = 'PP-OCRv6_small_rec';

/// 识别引擎选择区（Kraken / PaddleOCR 二选一 + Paddle 模型档位）。
/// 任务创建页（task_setup_page）与编辑器书内"识别引擎"对话框共用。
class EngineSettingsSection extends StatefulWidget {
  const EngineSettingsSection({
    super.key,
    required this.engine,
    required this.paddleModel,
    required this.onEngineChanged,
    required this.onPaddleModelChanged,
    this.vlSettings,
    this.onVlSettingsChanged,
  });

  final String engine; // 'kraken' | 'paddle'
  final String paddleModel;
  final ValueChanged<String> onEngineChanged;
  final ValueChanged<String> onPaddleModelChanged;

  /// VL 解析配置（书级，选 VL 模型时展示面板）；null = 不展示。
  final ProjectSettings? vlSettings;
  final ValueChanged<ProjectSettings>? onVlSettingsChanged;

  @override
  State<EngineSettingsSection> createState() => _EngineSettingsSectionState();
}

class _EngineSettingsSectionState extends State<EngineSettingsSection> {
  /// null = 未查询到（后端未就绪）；选 paddle 时仅作提示不阻断。
  bool? _paddleInstalled;
  String? _paddleInstallError;

  @override
  void initState() {
    super.initState();
    _refreshPaddleStatus();
  }

  Future<void> _refreshPaddleStatus() async {
    try {
      final status = await PythonService.paddleStatus();
      if (!mounted) return;
      setState(() {
        _paddleInstalled = status['installed'] == true;
        _paddleInstallError = status['error']?.toString();
      });
    } catch (_) {
      // 后端未就绪等场景：保持 null（不展示安装提示，识别时后端会给
      // 带安装指引的明确报错）。
    }
  }

  Widget _optionRow({
    required bool selected,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_off,
        color: selected ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text(title),
      subtitle: subtitle == null
          ? null
          : Text(subtitle, style: const TextStyle(fontSize: 12)),
      dense: true,
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final paddle = widget.engine == 'paddle';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _optionRow(
          selected: !paddle,
          title: 'Kraken（默认）',
          subtitle: 'CHAT 古籍识别模型；独立 kraken 环境常驻进程池',
          onTap: () => widget.onEngineChanged('kraken'),
        ),
        _optionRow(
          selected: paddle,
          title: 'PaddleOCR',
          subtitle: 'PP-OCRv6 识别模型（tiny / small / medium）；独立 paddleocr 环境',
          onTap: () => widget.onEngineChanged('paddle'),
        ),
        if (paddle) ...[
          if (_paddleInstalled == false)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Text(
                '未检测到 paddleocr 环境：${_paddleInstallError ?? ''}\n'
                '请先运行 python_service\\install_paddleocr.bat（或应用内环境安装），'
                '否则本书识别会报错。',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 16, top: 8, bottom: 2),
            child: Text(
              'Paddle 识别模型（按电脑配置选择，首次使用需下载）',
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
            ),
          ),
          for (final choice in kPaddleModelChoices)
            _optionRow(
              selected: widget.paddleModel == choice.name,
              title: choice.displayLabel,
              subtitle: choice.requirement,
              onTap: () => widget.onPaddleModelChanged(choice.name),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 4),
            child: PaddleModelProbeButton(
              model: widget.paddleModel,
              onReady: _refreshPaddleStatus,
            ),
          ),
          if (_vlPanelVisible) _buildVlPanel(),
        ],
      ],
    );
  }

  bool get _vlPanelVisible =>
      widget.engine == 'paddle' &&
      widget.paddleModel.startsWith('PaddleOCR-VL') &&
      widget.vlSettings != null &&
      widget.onVlSettingsChanged != null;

  /// VL 配置面板（PaddleOCR-VL 选中时展示，官网演示同款全参数）：
  /// 构造器开关（池绑定）+ predict 级参数（Prompt 类型/生成参数/辅助
  /// 内容解析，随每次请求不换池）。
  Widget _buildVlPanel() {
    final st = widget.vlSettings!;
    void upd(ProjectSettings next) => widget.onVlSettingsChanged!(next);

    Widget row(String title, String subtitle, bool value, void Function(bool v) fn) =>
        SwitchListTile(
          value: value,
          onChanged: fn,
          title: Text(title, style: const TextStyle(fontSize: 13.5)),
          subtitle: Text(
            subtitle,
            style: const TextStyle(fontSize: 11.5, color: Colors.grey),
          ),
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        );

    Widget header(String text) => Padding(
          padding: const EdgeInsets.only(left: 16, top: 10, bottom: 2),
          child: Text(
            text,
            style:
                const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
          ),
        );

    Widget numFieldTyped(
      String label,
      Object? initial,
      String hint,
      void Function(num? v) fn,
      bool asInt,
    ) =>
        Padding(
          padding: const EdgeInsets.only(left: 16, right: 8, top: 2),
          child: Row(
            children: [
              SizedBox(
                width: 130,
                child: Text(label, style: const TextStyle(fontSize: 12.5)),
              ),
              Expanded(
                child: NumField(
                  value: initial,
                  hint: hint,
                  asInt: asInt,
                  onChanged: fn,
                ),
              ),
            ],
          ),
        );

    const promptLabels = {
      'ocr': '文本（默认）',
      'formula': '公式',
      'table': '表格',
      'chart': '图表',
      'seal': '印章',
      'spotting': '文本检测与识别（逐行）',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header('模型参数（改动后首次直读会重建进程池）'),
        row('图片方向矫正', '自动检测页面旋转（扫描件歪斜时开）',
            st.vlUseDocOrientation,
            (v) => upd(st.copyWith(vlUseDocOrientation: v))),
        row('图片扭曲矫正', '弯曲页面展平（拍照件开，扫描件一般不用）',
            st.vlUseDocUnwarping,
            (v) => upd(st.copyWith(vlUseDocUnwarping: v))),
        row('版面分析', '按版面块输出（标题/表格/图片分区）；古籍竖排推荐关——关闭时 VL 按列输出逐行文本，与行文对照对齐更好',
            st.vlUseLayoutDetection,
            (v) => upd(st.copyWith(vlUseLayoutDetection: v))),
        row('图表识别', '图表内容解析', st.vlUseChartRecognition,
            (v) => upd(st.copyWith(vlUseChartRecognition: v))),
        row('印章识别', '印章文字识别', st.vlUseSealRecognition,
            (v) => upd(st.copyWith(vlUseSealRecognition: v))),
        row('图片文字识别', '对图片类版面块做文字识别', st.vlUseOcrForImageBlock,
            (v) => upd(st.copyWith(vlUseOcrForImageBlock: v))),
        header('Prompt 类型（仅关闭版面分析时生效）'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          // spotting 在超大图上可能触发底层原生崩溃（实测），提示保留在
          // 选项说明里由用户自行斟酌。
          child: DropdownButtonFormField<String>(
            // ignore: deprecated_member_use
            value: promptLabels.containsKey(st.vlPromptLabel)
                ? st.vlPromptLabel
                : 'ocr',
            items: [
              for (final e in promptLabels.entries)
                DropdownMenuItem(value: e.key, child: Text(e.value)),
            ],
            onChanged: (v) => upd(st.copyWith(vlPromptLabel: v ?? 'ocr')),
            decoration: const InputDecoration(isDense: true),
          ),
        ),
        header('生成参数（留空 = 模型默认；古籍竖排推荐只把重复抑制强度填 1.15，其余保持留空）'),
        numFieldTyped('重复抑制强度', st.vlRepetitionPenalty,
            '留空=1.0；压制重复退化填 1.15（1.1~1.2）',
            (v) => upd(st.copyWith(vlRepetitionPenalty: v?.toDouble())), false),
        numFieldTyped('识别稳定性', st.vlTemperature,
            '留空=0（贪心最稳）；>0 启用采样（结果带随机性）',
            (v) => upd(st.copyWith(vlTemperature: v?.toDouble())), false),
        numFieldTyped('结果可信范围', st.vlTopP,
            '留空=1.0（不截断）；仅稳定性>0 时生效',
            (v) => upd(st.copyWith(vlTopP: v?.toDouble())), false),
        numFieldTyped('图像最小总像素数', st.vlMinPixels, '留空=模型默认，无需填写',
            (v) => upd(st.copyWith(vlMinPixels: v?.toInt())), true),
        numFieldTyped('图像最大总像素数', st.vlMaxPixels,
            '留空=模型默认；调大更清晰但更慢更吃显存',
            (v) => upd(st.copyWith(vlMaxPixels: v?.toInt())), true),
        header('辅助内容解析（默认过滤；开启后恢复解析）'),
        row('页眉', '页眉文字', st.vlParseHeader,
            (v) => upd(st.copyWith(vlParseHeader: v))),
        row('页眉图片', '页眉区域图片', st.vlParseHeaderImage,
            (v) => upd(st.copyWith(vlParseHeaderImage: v))),
        row('页脚', '页脚文字', st.vlParseFooter,
            (v) => upd(st.copyWith(vlParseFooter: v))),
        row('页脚图片', '页脚区域图片', st.vlParseFooterImage,
            (v) => upd(st.copyWith(vlParseFooterImage: v))),
        row('页码', '页码数字', st.vlParsePageNumber,
            (v) => upd(st.copyWith(vlParsePageNumber: v))),
        row('脚注', '脚注内容', st.vlParseFootnote,
            (v) => upd(st.copyWith(vlParseFootnote: v))),
        row('旁注文本', '旁批/边栏文字', st.vlParseAsideText,
            (v) => upd(st.copyWith(vlParseAsideText: v))),
      ],
    );
  }
}

/// 设置面板的数字输入框（生成参数 5 项共用）。
///
/// controller 由 State 持有、跨父级重建存活：设置是"每敲一键就保存并
/// 重建界面"的写法，若在 build 里现建 controller（旧实现），每次按键
/// 光标被重置到行首、`1` 还会被格式化回写成 `1.0`，继续输入就插在开头
/// 越打越乱（实测出现 `.15`、`.5151511.0`）。回写外部值只在"值既不等于
/// 本框最近上报值、也不等于当前文本解析值"时发生——打字过程中父级重建
/// （解析值 == 已上报值）不打断输入、不移动光标。
class NumField extends StatefulWidget {
  const NumField({
    super.key,
    required this.value,
    required this.hint,
    required this.asInt,
    required this.onChanged,
  });

  final Object? value; // 当前设置值（num?；null = 留空）
  final String hint;
  final bool asInt; // true = 整数档（像素数），false = 小数档
  final void Function(num? v) onChanged;

  @override
  State<NumField> createState() => _NumFieldState();
}

class _NumFieldState extends State<NumField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.value?.toString() ?? '');
  num? _emitted;

  num? _parse(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    final d = double.tryParse(t);
    if (d == null) return null;
    return widget.asInt ? d.toInt() : d;
  }

  @override
  void initState() {
    super.initState();
    _emitted = _parse(_controller.text);
  }

  @override
  void didUpdateWidget(covariant NumField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final incoming = widget.value;
    if (incoming == _emitted) return;
    if (incoming == _parse(_controller.text)) {
      _emitted = incoming is num ? incoming : null;
      return;
    }
    final text = incoming?.toString() ?? '';
    if (_controller.text != text) {
      _controller
        ..text = text
        ..selection = TextSelection.collapsed(offset: text.length);
    }
    _emitted = incoming is num ? incoming : null;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
      ],
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        isDense: true,
        hintText: widget.hint,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      ),
      style: const TextStyle(fontSize: 12.5),
      onChanged: (v) {
        final parsed = _parse(v);
        _emitted = parsed;
        widget.onChanged(parsed);
      },
    );
  }
}

/// "下载 / 测试所选模型"按钮：调 /paddle/probe 建池并 ping——首次会从
/// 官方源自动下载模型并加载（可达数分钟），完成后提示实际设备与耗时。
class PaddleModelProbeButton extends StatefulWidget {
  const PaddleModelProbeButton({super.key, required this.model, this.onReady});

  final String model;
  final VoidCallback? onReady;

  @override
  State<PaddleModelProbeButton> createState() => _PaddleModelProbeButtonState();
}

class _PaddleModelProbeButtonState extends State<PaddleModelProbeButton> {
  bool _busy = false;

  Future<void> _run() async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await PythonService.paddleProbe(widget.model);
      final device = result['device']?.toString();
      final elapsed = result['elapsed_s']?.toString();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '模型 ${widget.model} 已就绪'
            '${device == null || device.isEmpty ? '' : '（$device）'}'
            '${elapsed == null || elapsed.isEmpty ? '' : '，用时 ${elapsed}s'}',
          ),
        ),
      );
      widget.onReady?.call();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('PaddleOCR 探测失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: _busy ? null : _run,
      icon: _busy
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.cloud_download_outlined, size: 18),
      label: Text(_busy ? '正在下载 / 加载模型…' : '下载 / 测试所选模型'),
    );
  }
}
