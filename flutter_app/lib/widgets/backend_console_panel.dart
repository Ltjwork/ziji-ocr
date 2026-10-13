import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/python_service.dart';

/// 后端日志面板。
///
/// [active] 为 false 时（IndexedStack 隐藏页）暂停 UI 刷新：日志仍留在
/// [PythonService] 的缓冲里，回到前台一次性补刷。识别期间后端日志是
/// 洪流（每秒数十行），逐条 setState + 滚动动画会把 UI 线程压进 build
/// 风暴，引擎任务在 Windows 消息队列积压打满后表现为
/// "Failed to post message to main thread" 刷屏——刷新统一节流合批。
class BackendConsolePanel extends StatefulWidget {
  final bool active;

  const BackendConsolePanel({super.key, this.active = true});

  @override
  State<BackendConsolePanel> createState() => _BackendConsolePanelState();
}

class _BackendConsolePanelState extends State<BackendConsolePanel> {
  final ScrollController _scrollController = ScrollController();
  StreamSubscription<BackendLogEntry>? _subscription;
  Timer? _flushTimer;
  bool _pending = false;
  late List<BackendLogEntry> _entries;
  bool _autoScroll = true;

  @override
  void initState() {
    super.initState();
    _entries = PythonService.logSnapshot;
    _subscription = PythonService.logs.listen((_) {
      _pending = true;
      _flushTimer ??= Timer(const Duration(milliseconds: 250), _flush);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  @override
  void didUpdateWidget(BackendConsolePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 回到控制台视图：把隐藏期间积累的日志一次刷出（洪流期延迟最多
    // 一个节流周期，肉眼无感）。
    if (widget.active && !oldWidget.active) {
      _flushNow();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _flushTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _flush() {
    _flushTimer = null;
    if (!_pending) return;
    _pending = false;
    if (!mounted || !widget.active) return;
    setState(() => _entries = PythonService.logSnapshot);
    if (_autoScroll) _scrollToBottom();
  }

  void _flushNow() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _pending = false;
    if (!mounted) return;
    setState(() => _entries = PythonService.logSnapshot);
    if (_autoScroll) _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _copyLogs() async {
    final text = _entries.map(_formatEntry).join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('后台日志已复制')),
    );
  }

  String _formatEntry(BackendLogEntry entry) =>
      '[${entry.timeLabel}] [${entry.source}] ${entry.message}';

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF101418),
      child: Column(
        children: [
          _ConsoleToolbar(
            total: _entries.length,
            autoScroll: _autoScroll,
            onAutoScrollChanged: (value) {
              setState(() => _autoScroll = value);
              if (value) _scrollToBottom();
            },
            onCopy: _entries.isEmpty ? null : _copyLogs,
            onClear: () {
              PythonService.clearLogs();
              _flushNow();
            },
          ),
          const Divider(height: 1, color: Color(0xFF2B333B)),
          Expanded(
            child: _entries.isEmpty
                ? const Center(
                    child: Text(
                      '暂无后台日志。启动 OCR 或重新识别后，会显示识别引擎 / OpenCC / 请求状态。',
                      style: TextStyle(color: Color(0xFF8A949E)),
                    ),
                  )
                // SelectionArea 包整个列表：行项用普通 Text（每行一个
                // SelectableText 各带焦点/手势子系统，洪流期重建是
                // build 风暴的主力）。
                : SelectionArea(
                    child: ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(12),
                      itemCount: _entries.length,
                      itemBuilder: (_, index) {
                        final entry = _entries[index];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            _formatEntry(entry),
                            style: TextStyle(
                              fontFamily: 'Consolas',
                              fontFamilyFallback: const [
                                'Courier New',
                                'monospace',
                              ],
                              fontSize: 12.5,
                              height: 1.35,
                              color: entry.isError
                                  ? const Color(0xFFFF8080)
                                  : _sourceColor(entry.source),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Color _sourceColor(String source) {
    return switch (source) {
      'stdout' => const Color(0xFFD8DEE9),
      'stderr' => const Color(0xFFFF8080),
      'http' => const Color(0xFF8FBCBB),
      _ => const Color(0xFFA3BE8C),
    };
  }
}

class _ConsoleToolbar extends StatelessWidget {
  final int total;
  final bool autoScroll;
  final ValueChanged<bool> onAutoScrollChanged;
  final VoidCallback? onCopy;
  final VoidCallback onClear;

  const _ConsoleToolbar({
    required this.total,
    required this.autoScroll,
    required this.onAutoScrollChanged,
    required this.onCopy,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: const Color(0xFF151B22),
      child: Row(
        children: [
          const Icon(Icons.terminal, color: Color(0xFF88C0D0), size: 20),
          const SizedBox(width: 8),
          Text(
            '后台控制台 · $total 行',
            style: TextStyle(
              color: const Color(0xFFE5E9F0),
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          Row(
            children: [
              const Text(
                '自动滚动',
                style: TextStyle(color: Color(0xFFB8C0C8), fontSize: 12),
              ),
              Switch.adaptive(
                value: autoScroll,
                onChanged: onAutoScrollChanged,
              ),
            ],
          ),
          IconButton(
            tooltip: '复制日志',
            onPressed: onCopy,
            icon: const Icon(Icons.copy, color: Color(0xFFD8DEE9)),
          ),
          IconButton(
            tooltip: '清空日志',
            onPressed: onClear,
            icon: const Icon(Icons.delete_sweep, color: Color(0xFFD8DEE9)),
          ),
        ],
      ),
    );
  }
}
