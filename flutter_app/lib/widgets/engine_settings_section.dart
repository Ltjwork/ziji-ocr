import 'package:flutter/material.dart';

import '../services/python_service.dart';

/// PaddleOCR 识别模型清单——后端 paddle_proc.PP_OCRV6_MODELS 的 Dart 镜像
/// （JSON 字段基线在后端，此处只作展示；两侧同步修改、只追加不改名）。
class PaddleModelChoice {
  const PaddleModelChoice({
    required this.name,
    required this.label,
    required this.requirement,
  });

  final String name; // 后端模型名（PP-OCRv6_*_rec）
  final String label; // 下拉展示名（含体积）
  final String requirement; // 配置要求文案（用户按此选档）
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
  });

  final String engine; // 'kraken' | 'paddle'
  final String paddleModel;
  final ValueChanged<String> onEngineChanged;
  final ValueChanged<String> onPaddleModelChanged;

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
              title: choice.label,
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
        ],
      ],
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
