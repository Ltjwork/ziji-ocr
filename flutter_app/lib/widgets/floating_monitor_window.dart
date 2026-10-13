import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../services/recognition_queue.dart';
import '../services/system_monitor.dart';
import 'sparkline.dart';

/// 识别监控悬浮窗：全局常驻（挂在 MaterialApp.builder 的 Stack 顶层），
/// 任何页面、对话框、编辑器浮层之上都可见。可拖动、可折叠成圆形徽标、
/// 可关闭（首页工具栏开关再打开）。
///
/// 内容三块：
/// · 当前书的整本识别进度（页数/百分比/预计剩余）+ 等待队列数；
/// · 「全部识别完成后关机」开关——关机倒计时期间任何页面都能在此看到
///   剩余秒数并一键取消（首页的 _ShutdownBanner 只在首页可见，这里补
///   齐其他页面的缺口）；
/// · 整机 CPU/内存/显存/GPU 占用与约 3 分钟滚动曲线（SystemMonitor）。
class FloatingMonitorWindow extends StatefulWidget {
  const FloatingMonitorWindow({super.key});

  /// 全局可见开关：窗口自身与首页工具栏按钮共用；位置/折叠态由窗口
  /// State 自己持久化。
  static final ValueNotifier<bool> visible = ValueNotifier<bool>(true);

  static const String _prefVisible = 'monitorWindow.visible';
  static const String _prefCollapsed = 'monitorWindow.collapsed';
  static const String _prefOffsetDx = 'monitorWindow.offsetDx';
  static const String _prefOffsetDy = 'monitorWindow.offsetDy';

  /// 切换悬浮窗可见性（写 ValueNotifier + SharedPreferences）。
  static Future<void> setVisible(bool value) async {
    visible.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefVisible, value);
  }

  @override
  State<FloatingMonitorWindow> createState() => _FloatingMonitorWindowState();
}

class _FloatingMonitorWindowState extends State<FloatingMonitorWindow> {
  static const double _panelWidth = 300;
  static const double _badgeSize = 56;

  /// 偏移上限的头部余量：面板高度随内容浮动，用估值钳住拖动范围即可。
  static const double _dragTopMargin = 8;
  static const double _dragBottomMargin = 120;

  bool _restored = false;
  bool _collapsed = false;

  /// null = 未拖过/未持久化过，取默认位置（右上角，避开首页 AppBar）。
  Offset? _offset;
  Timer? _shutdownTicker;

  @override
  void initState() {
    super.initState();
    FloatingMonitorWindow.visible.addListener(_onVisibleChanged);
    RecognitionQueue.instance.addListener(_onQueueChanged);
    _restore();
  }

  @override
  void dispose() {
    RecognitionQueue.instance.removeListener(_onQueueChanged);
    FloatingMonitorWindow.visible.removeListener(_onVisibleChanged);
    _shutdownTicker?.cancel();
    // 悬浮窗是 SystemMonitor 唯一消费者，销毁即停轮询。
    SystemMonitor.instance.stop();
    super.dispose();
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    // 常驻模式：首次运行默认显示，之后记住用户的选择。
    final visible = prefs.getBool(FloatingMonitorWindow._prefVisible) ?? true;
    FloatingMonitorWindow.visible.value = visible;
    final dx = prefs.getDouble(FloatingMonitorWindow._prefOffsetDx);
    final dy = prefs.getDouble(FloatingMonitorWindow._prefOffsetDy);
    if (!mounted) return;
    setState(() {
      _collapsed = prefs.getBool(FloatingMonitorWindow._prefCollapsed) ?? false;
      _offset = dx == null || dy == null ? null : Offset(dx, dy);
      _restored = true;
    });
    if (visible) SystemMonitor.instance.start();
    _syncShutdownTicker();
  }

  void _onVisibleChanged() {
    if (FloatingMonitorWindow.visible.value) {
      SystemMonitor.instance.start();
    } else {
      SystemMonitor.instance.stop();
    }
  }

  /// 队列变化驱动进度/等待数/关机状态刷新；关机倒计时期间起 1s ticker
  /// （与首页 _ShutdownBanner 同一手法）。
  void _onQueueChanged() {
    if (!mounted) return;
    setState(() {});
    _syncShutdownTicker();
  }

  void _syncShutdownTicker() {
    final pending = RecognitionQueue.instance.shutdownPending;
    if (pending && _shutdownTicker == null) {
      _shutdownTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!pending && _shutdownTicker != null) {
      _shutdownTicker?.cancel();
      _shutdownTicker = null;
    }
  }

  // ── 拖动与持久化 ──

  Offset _defaultOffset(Size screen) =>
      Offset(screen.width - _panelWidth - 24, 76);

  void _onDrag(DragUpdateDetails details, double width, Size screen) {
    setState(() {
      final base = _offset ?? _defaultOffset(screen);
      _offset = Offset(
        (base.dx + details.delta.dx).clamp(
          _dragTopMargin,
          (screen.width - width - _dragTopMargin).clamp(
            _dragTopMargin,
            double.infinity,
          ),
        ),
        (base.dy + details.delta.dy).clamp(
          _dragTopMargin,
          screen.height - _dragBottomMargin,
        ),
      );
    });
  }

  Future<void> _persistGeometry() async {
    final offset = _offset;
    if (offset == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(FloatingMonitorWindow._prefOffsetDx, offset.dx);
    await prefs.setDouble(FloatingMonitorWindow._prefOffsetDy, offset.dy);
    await prefs.setBool(FloatingMonitorWindow._prefCollapsed, _collapsed);
  }

  void _setCollapsed(bool value) {
    setState(() => _collapsed = value);
    unawaited(_persistGeometry());
  }

  // ── 构建 ──

  @override
  Widget build(BuildContext context) {
    if (!_restored) return const SizedBox.shrink();
    return ValueListenableBuilder<bool>(
      valueListenable: FloatingMonitorWindow.visible,
      builder: (context, visible, _) {
        if (!visible) return const SizedBox.shrink();
        final screen = MediaQuery.of(context).size;
        final offset = _offset ?? _defaultOffset(screen);
        return Positioned(
          left: offset.dx,
          top: offset.dy,
          // 本地 Overlay + 透明 Material：窗口在 Navigator 之外，树里没有
          // 现成的 Overlay/Material 祖源，而 IconButton/Switch 需要Material，
          // Tooltip 的悬停气泡要插进最近的 Overlay——缺了会抛
          // "No Overlay widget found"（v76 首版启动即崩的根因）。
          // clipBehavior: none 允许气泡画出窗口边界。
          child: _LocalOverlayHost(
            child: Material(
              type: MaterialType.transparency,
              child: _collapsed ? _buildBadge(screen) : _buildPanel(screen),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPanel(Size screen) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: _panelWidth,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.97),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(screen),
          Divider(
            height: 1,
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
            child: _buildQueueSection(),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 8),
            child: _buildShutdownSection(scheme),
          ),
          Divider(
            height: 1,
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            child: _buildSystemSection(scheme),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(Size screen) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: (d) => _onDrag(d, _panelWidth, screen),
      onPanEnd: (_) => unawaited(_persistGeometry()),
      child: MouseRegion(
        cursor: SystemMouseCursors.move,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
          child: Row(
            children: [
              Icon(
                Icons.monitor_heart_outlined,
                size: 14,
                color: scheme.primary,
              ),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  '识别监控',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
              _headerButton(
                icon: Icons.remove,
                tooltip: '折叠成徽标',
                onPressed: () => _setCollapsed(true),
              ),
              _headerButton(
                icon: Icons.close,
                tooltip: '关闭悬浮窗（首页工具栏可重新打开）',
                onPressed: () =>
                    unawaited(FloatingMonitorWindow.setVisible(false)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _headerButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      icon: Icon(icon, size: 15),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      padding: const EdgeInsets.all(4),
      onPressed: onPressed,
    );
  }

  // ── 队列进度区 ──

  Widget _buildQueueSection() {
    final queue = RecognitionQueue.instance;
    final jobs = queue.queuedJobs;
    RecognitionProgress? running;
    for (final p in queue.progress.values) {
      if (p.status == RecognitionStatus.recognizing ||
          p.status == RecognitionProgress.stopping) {
        running = p;
        break;
      }
    }

    if (running == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(Icons.event_available, size: 14, color: Colors.grey.shade500),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '队列空闲 · 可在首页开始整本识别，或主区快设批量拆分',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
            ),
          ],
        ),
      );
    }

    // 闭包里会用到，先落成非空局部（running 的类型提升进不了闭包）。
    final run = running;
    final isSplit = run.kind == RecognitionProgress.kindRegionSplit;
    final kindLabel = isSplit ? '按主区拆分' : '整本识别';
    final doneWord = isSplit ? '已处理' : '已识别';
    final total = run.totalPages;
    final done = run.recognizedPages;
    final percent = (run.ratio * 100).round();
    final stopping = run.status == RecognitionProgress.stopping;
    final current = run.currentPage > 0 ? run.currentPage : done + 1;
    final eta = run.etaSeconds;
    final waitingJobs = jobs
        .where((j) => j.$1.id != run.projectId)
        .toList(growable: false);
    final runningName = jobs
        .where((j) => j.$1.id == run.projectId)
        .map((j) => j.$1.name)
        .firstOrNull;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.auto_stories,
              size: 14,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '《${runningName ?? '当前书目'}》· $kindLabel',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            // 运行中任务的停止按钮（当前页完成后停住，可继续）。
            _headerButton(
              icon: Icons.stop_circle_outlined,
              tooltip: '停止该任务（当前页完成后停住，之后可继续）',
              onPressed: () => queue.pause(run.projectId),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: LinearProgressIndicator(
                value: running.ratio,
                minHeight: 5,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$percent%',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          stopping
              ? '正在停止 · 第 $current/$total 页完成后停住'
              : '第 $current/$total 页 · $doneWord $done 页'
                    '${eta == null ? '' : ' · 预计还需 ${_fmtEta(eta)}'}',
          style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
        ),
        // 排队中的任务列表：每行可删除（出队）。运行中的在上面停止。
        for (final (idx, j) in waitingJobs.indexed)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                Icon(
                  j.$2 == RecognitionProgress.kindRegionSplit
                      ? Icons.crop_free
                      : Icons.auto_stories,
                  size: 12,
                  color: Colors.grey.shade500,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    '《${j.$1.name}》·'
                    '${j.$2 == RecognitionProgress.kindRegionSplit ? '按主区拆分' : '整本识别'}'
                    ' · 排队第 ${idx + 2}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                ),
                _headerButton(
                  icon: Icons.delete_outline,
                  tooltip: '从队列删除该任务（未开始，不影响已识别内容）',
                  onPressed: () => queue.remove(j.$1.id),
                ),
              ],
            ),
          ),
      ],
    );
  }

  // ── 完成后关机区 ──

  Widget _buildShutdownSection(ColorScheme scheme) {
    final queue = RecognitionQueue.instance;
    final active = queue.shutdownWhenIdle || queue.shutdownPending;
    final deadline = queue.shutdownAt;
    final error = queue.shutdownError;

    Widget? trailing;
    if (deadline != null) {
      final remain = deadline
          .difference(DateTime.now())
          .inSeconds
          .clamp(0, 999);
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: scheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$remain 秒后关机',
              style: TextStyle(
                fontSize: 10,
                color: scheme.onErrorContainer,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          TextButton(
            onPressed: () => unawaited(queue.cancelScheduledShutdown()),
            style: TextButton.styleFrom(
              minimumSize: const Size(40, 26),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              textStyle: const TextStyle(fontSize: 11),
            ),
            child: const Text('取消'),
          ),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 34,
              height: 20,
              child: Transform.scale(
                scale: 0.7,
                child: Switch(
                  value: active,
                  // 队列级选项（与首页卡片同一开关、同一状态源）：空队列时
                  // 勾上立即触发关机没有意义，但也无害——enqueue 会先撤销
                  // 已计划的关机，语义与首页一致。
                  onChanged: (v) => queue.setShutdownWhenIdle(v),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
            const SizedBox(width: 2),
            const Text('全部识别完成后关机', style: TextStyle(fontSize: 12)),
            const Spacer(),
            if (trailing != null) trailing,
          ],
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '关机失败：$error',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10, color: scheme.error),
                  ),
                ),
                TextButton(
                  onPressed: queue.clearShutdownError,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(40, 24),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    textStyle: const TextStyle(fontSize: 11),
                  ),
                  child: const Text('知道了'),
                ),
              ],
            ),
          ),
      ],
    );
  }

  // ── 系统占用区（整机口径） ──

  Widget _buildSystemSection(ColorScheme scheme) {
    final monitor = SystemMonitor.instance;
    final sys = monitor.latest?.system;
    if (sys == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '系统占用',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            monitor.missStreak > 0 ? '连接后端失败，自动重试中…' : '后端未运行或版本过旧，暂不可用',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
          ),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '系统占用（整机）',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Colors.grey.shade600,
          ),
        ),
        const SizedBox(height: 6),
        _metricRow(
          label: 'CPU',
          value: '${sys.cpuPercent.round()}%',
          history: monitor.cpuHistory,
          color: const Color(0xFF5B7CF2),
        ),
        _metricRow(
          label: '内存',
          value:
              '${_fmtBytes(sys.memoryUsedBytes)}/${_fmtBytes(sys.memoryTotalBytes)}',
          history: monitor.memHistory,
          color: const Color(0xFF3FA37C),
        ),
        _metricRow(
          label: '显存',
          value: sys.vramUsedBytes == null || sys.vramTotalBytes == null
              ? '不可用'
              : '${_fmtBytes(sys.vramUsedBytes!)}/${_fmtBytes(sys.vramTotalBytes!)}',
          history: monitor.vramHistory,
          color: const Color(0xFFB06BE0),
        ),
        _metricRow(
          label: 'GPU',
          value: sys.gpuUtilPercent == null
              ? '不可用'
              : '${sys.gpuUtilPercent!.round()}%',
          history: monitor.gpuHistory,
          color: const Color(0xFFE0952F),
        ),
        const SizedBox(height: 2),
        Text(
          '任务管理器口径 · 每两秒刷新 · 曲线约 ${SystemMonitor.maxHistory * SystemMonitor.pollInterval.inSeconds ~/ 60} 分钟',
          style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
        ),
      ],
    );
  }

  Widget _metricRow({
    required String label,
    required String value,
    required List<double> history,
    required Color color,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 30,
            child: Text(
              label,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 118,
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: SizedBox(
              height: 24,
              child: Sparkline(history: history, color: color),
            ),
          ),
        ],
      ),
    );
  }

  // ── 折叠徽标 ──

  Widget _buildBadge(Size screen) {
    final scheme = Theme.of(context).colorScheme;
    RecognitionProgress? running;
    for (final p in RecognitionQueue.instance.progress.values) {
      if (p.status == RecognitionStatus.recognizing ||
          p.status == RecognitionProgress.stopping) {
        running = p;
        break;
      }
    }
    final ratio = running?.ratio;
    return Tooltip(
      message: '识别监控 · 点击展开',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (d) => _onDrag(d, _badgeSize, screen),
        onPanEnd: (_) => unawaited(_persistGeometry()),
        onTap: () => _setCollapsed(false),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            width: _badgeSize,
            height: _badgeSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.surfaceContainerHigh.withValues(alpha: 0.97),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.6),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 12,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: ratio == null
                ? Icon(
                    Icons.menu_book_outlined,
                    size: 22,
                    color: scheme.primary,
                  )
                : Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 40,
                        height: 40,
                        child: CircularProgressIndicator(
                          value: ratio.clamp(0.0, 1.0),
                          strokeWidth: 3,
                          strokeCap: StrokeCap.round,
                        ),
                      ),
                      Text(
                        '${(ratio * 100).round()}',
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          fontFeatures: [FontFeature.tabularFigures()],
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

// 与 home_page.dart 的私有 _formatBytes/_formatEta 重复（那里是页面私有
// 函数）；两处格式化口径需保持一致，改动时同改。

/// 给无 Overlay 祖源的子树提供一个本地 Overlay（SDK 尚无 Overlay.child
/// 构造）。Tooltip 的悬停气泡会插进最近的 Overlay，没有它会抛
/// "No Overlay widget found"。子树变化通过 markNeedsBuild 传导——
/// OverlayEntry 不随外围 rebuild 自动重建，必须手动标脏。
class _LocalOverlayHost extends StatefulWidget {
  const _LocalOverlayHost({required this.child});

  final Widget child;

  @override
  State<_LocalOverlayHost> createState() => _LocalOverlayHostState();
}

class _LocalOverlayHostState extends State<_LocalOverlayHost> {
  // canSizeOverlay：Positioned 只给 left/top 时子约束无界，Overlay 无法
  // 自决定尺寸——声明 entry 参与定尺， theaters 以面板（宽 300/徽标 56，
  // Column mainAxisSize.min）为尺寸依据。
  late final OverlayEntry _entry = OverlayEntry(
    builder: (_) => widget.child,
    canSizeOverlay: true,
  );

  @override
  void didUpdateWidget(covariant _LocalOverlayHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    _entry.markNeedsBuild();
  }

  @override
  void dispose() {
    _entry.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Overlay(initialEntries: [_entry], clipBehavior: Clip.none);
}

String _fmtBytes(int bytes) {
  final gb = bytes / (1024 * 1024 * 1024);
  if (gb >= 10) return '${gb.round()} GB';
  if (gb >= 1) return '${gb.toStringAsFixed(1)} GB';
  final mb = bytes / (1024 * 1024);
  return '${mb.round()} MB';
}

String _fmtEta(int seconds) {
  if (seconds < 60) return '小于 1 分钟';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '约 $minutes 分钟';
  return '约 ${minutes ~/ 60} 小时 ${minutes % 60} 分钟';
}
