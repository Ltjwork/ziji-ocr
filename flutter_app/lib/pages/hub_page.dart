import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'about_update_page.dart';
import 'char_verify_debug_page.dart';
import 'cleanup_page.dart';
import 'crowd_import_page.dart';
import 'debug_page.dart';
import 'gesture_settings_page.dart';
import 'keyboard_shortcuts_page.dart';
import 'model_compare_page.dart';
import 'model_manage_page.dart';
import 'ollama_settings_page.dart';
import 'plugins_page.dart';
import '../services/python_service.dart';
import 'training_page.dart';

/// 首页功能入口整合容器：一个 AppBar + 标签条（tag 区分功能区），内容
/// 用 IndexedStack 保活——训练/对比/调试页都有"进行中"状态（训练任务、
/// 对比结果、调试图），TabBarView 切远页销毁 State 会全部丢失。
/// 各功能页经 `embedded: true` 以无 Scaffold 的裸内容嵌入，标题由
/// 标签承担，避免双层标题。
class HubPage extends StatefulWidget {
  const HubPage({
    super.key,
    required this.title,
    required this.tabs,
    this.actions,
  });

  final String title;
  final List<HubTab> tabs;
  final List<Widget>? actions;

  @override
  State<HubPage> createState() => _HubPageState();
}

/// 一个标签：文字 + 图标 + 内容构造器（IndexedStack 建一次后复用）。
class HubTab {
  const HubTab({required this.label, required this.icon, required this.child});

  final String label;
  final IconData icon;
  final Widget child;
}

class _HubPageState extends State<HubPage> with TickerProviderStateMixin {
  late final TabController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TabController(length: widget.tabs.length, vsync: this);
    _controller.addListener(_onTabChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onTabChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    // 只在用户点选（非动画中间态）时重建 IndexedStack 的显示层。
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: widget.actions,
        bottom: TabBar(
          controller: _controller,
          // 全部走主题 token 的透明度节奏：未选中 onSurface@70%、
          // 选中 primary、分隔线描边档——不写死颜色。
          labelColor: scheme.primary,
          unselectedLabelColor: scheme.onSurface.withValues(alpha: 0.70),
          labelStyle: const TextStyle(fontWeight: FontWeight.w600),
          dividerColor: scheme.onSurface.withValues(alpha: 0.10),
          tabs: [
            for (final tab in widget.tabs)
              Tab(icon: Icon(tab.icon, size: 18), text: tab.label),
          ],
        ),
      ),
      // IndexedStack：所有 tag 页常驻（离屏不销毁），切标签只换显示层。
      body: IndexedStack(
        index: _controller.index,
        children: [for (final tab in widget.tabs) tab.child],
      ),
    );
  }
}

/// 「模型训练」整合页：训练 / 对比测试。
class TrainingHubPage extends StatelessWidget {
  const TrainingHubPage({super.key});

  @override
  Widget build(BuildContext context) {
    return HubPage(
      title: '模型训练',
      tabs: [
        HubTab(
          label: '训练',
          icon: Icons.model_training,
          child: const TrainingPage(embedded: true),
        ),
        HubTab(
          label: '对比测试',
          icon: Icons.compare,
          child: const ModelComparePage(embedded: true),
        ),
      ],
    );
  }
}

/// 「设置」整合页：模型管理 / AI 辅助 / 插件 / 鼠标手势。
class SettingsHubPage extends StatelessWidget {
  const SettingsHubPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const HubPage(
      title: '设置',
      tabs: [
        HubTab(
          label: '模型管理',
          icon: Icons.manage_accounts,
          child: ModelManagePage(embedded: true),
        ),
        HubTab(
          label: 'AI 辅助',
          icon: Icons.smart_toy_outlined,
          child: OllamaSettingsPage(embedded: true),
        ),
        HubTab(
          label: '插件',
          icon: Icons.extension_outlined,
          child: PluginsPage(),
        ),
        HubTab(
          label: '鼠标手势',
          icon: Icons.gesture,
          child: GestureSettingsPage(embedded: true),
        ),
        HubTab(
          label: '快捷键',
          icon: Icons.keyboard_outlined,
          child: KeyboardShortcutsPage(embedded: true),
        ),
        HubTab(
          label: '关于 / 更新',
          icon: Icons.system_update_outlined,
          child: AboutUpdatePage(embedded: true),
        ),
      ],
    );
  }
}

/// 「调试」整合页：切分调试 / 墨迹校验 / 共识导入 + 后端控制台入口。
class DebugHubPage extends StatefulWidget {
  const DebugHubPage({super.key});

  @override
  State<DebugHubPage> createState() => _DebugHubPageState();
}

class _DebugHubPageState extends State<DebugHubPage> {
  /// 共识导入页需要的书库根目录（与首页同口径：文档目录/GujiBT）。
  String? _rootDir;

  @override
  void initState() {
    super.initState();
    _loadRootDir();
  }

  Future<void> _loadRootDir() async {
    final docs = await getApplicationDocumentsDirectory();
    if (mounted) setState(() => _rootDir = p.join(docs.path, 'GujiBT'));
  }

  @override
  Widget build(BuildContext context) {
    return HubPage(
      title: '调试',
      tabs: [
        const HubTab(
          label: '切分调试',
          icon: Icons.bug_report,
          child: DebugPage(embedded: true),
        ),
        const HubTab(
          label: '墨迹校验',
          icon: Icons.fact_check_outlined,
          child: CharVerifyDebugPage(embedded: true),
        ),
        HubTab(
          label: '共识导入',
          icon: Icons.history_edu,
          child: _rootDir == null
              ? const Center(child: CircularProgressIndicator())
              : CrowdImportPage(rootDir: _rootDir!, embedded: true),
        ),
        const HubTab(
          label: '诊断清理',
          icon: Icons.cleaning_services,
          child: CleanupPage(embedded: true),
        ),
      ],
      actions: [_consoleMenu()],
    );
  }

  /// 后端控制台菜单（从首页 AppBar 原样迁来：打开只读日志窗口 / 切换
  /// 独立控制台运行后端）。
  Widget _consoleMenu() {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.terminal),
      tooltip: '后端控制台窗口（ComfyUI 式）',
      onSelected: (value) async {
        if (value == 'open') {
          await PythonService.openStandaloneConsole();
        } else if (value == 'toggle') {
          await PythonService.setAutoOpenLogConsole(
            !PythonService.autoOpenLogConsole(),
          );
        }
        if (mounted) setState(() {});
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'open', child: Text('打开日志查看窗口（只读）')),
        PopupMenuItem(
          value: 'toggle',
          child: Row(
            children: [
              Icon(
                PythonService.autoOpenLogConsole()
                    ? Icons.check_box
                    : Icons.check_box_outline_blank,
                size: 18,
              ),
              const SizedBox(width: 6),
              const Expanded(child: Text('在独立控制台窗口运行后端（重启生效）')),
            ],
          ),
        ),
      ],
    );
  }
}
