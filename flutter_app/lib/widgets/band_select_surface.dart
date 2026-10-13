import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 可框选（橡皮筋）+ 点选的字块网格容器。
///
/// 为什么不用普通手势竞争：格子网格长在 ListView 里，鼠标拖动时外层
/// 滚动的认领阈值（竖直方向 1 逻辑像素）小于任何框选需要的移动距离，
/// 常规 Pan 手势在竖直方向上永远抢不过列表滚动。这里用
/// [ImmediateMultiDragGestureRecognizer] 在按下瞬间赢下 gesture arena，
/// 点选与框选自行判定：按下后移动超过 [_bandStartSlop] 进入框选
/// （橡皮筋实时高亮相交格子，起点格子的选中态决定加选/减选），否则
/// 在抬指时按命中位置路由点选——先小按钮（角标/定位，叠在格子图上）
/// 后格子本体。
///
/// 代价与约定：
/// - 格子区域上按住拖动不再滚动列表（滚轮不受影响）；
/// - 格子内部按钮的点击经 [onTapAction] 路由，按钮自己的 InkWell
///   onTap 不会触发（arena 被占），按钮仍保留悬停光标；
/// - [cellKeys] 里的格子 key 挂在格子图块容器上，key 缺失（未挂载）
///   的格子不参与命中。
class BandSelectSurface extends StatefulWidget {
  const BandSelectSurface({
    super.key,
    required this.cellKeys,
    this.actionKeys = const {},
    required this.selectedIds,
    required this.onTapCell,
    required this.onTapAction,
    required this.onBandStart,
    required this.onBandUpdate,
    required this.onBandEnd,
    required this.onBandCancel,
    required this.child,
  });

  /// 格子 id → 挂在格子图块容器上的 GlobalKey（点选与框选的命中目标）。
  final Map<String, GlobalKey> cellKeys;

  /// 小按钮 id（如 'edit:b3' / 'locate:b3'）→ 按钮上的 GlobalKey；
  /// 命中优先于格子（角标按钮叠在格子图上）。
  final Map<String, GlobalKey> actionKeys;

  /// 当前选中集合：框选起点落在已选中格子上 → 本次框选为减选模式。
  final Set<String> selectedIds;

  final void Function(String cellId) onTapCell;
  final void Function(String actionId) onTapAction;

  /// 框选开始（[bool] = 是否加选模式）。
  final void Function(bool addMode) onBandStart;

  /// 框选中相交集合变化（仅在变化时回调）。
  final void Function(Set<String> hits, bool addMode) onBandUpdate;
  final VoidCallback onBandEnd;
  final VoidCallback onBandCancel;
  final Widget child;

  @override
  State<BandSelectSurface> createState() => _BandSelectSurfaceState();
}

class _BandSelectSurfaceState extends State<BandSelectSurface> {
  /// 点选与框选的分界：移动超过该距离按框选处理，否则按点选。
  static const double _bandStartSlop = 6.0;

  Offset? _pressGlobal;
  Offset? _currentGlobal;
  bool _banding = false;
  bool _addMode = true;
  Set<String> _hits = const {};

  /// 橡皮筋矩形（本容器局部坐标），只在框选中非空。
  final ValueNotifier<Rect?> _bandRect = ValueNotifier(null);

  @override
  void dispose() {
    _bandRect.dispose();
    super.dispose();
  }

  /// 按下即被调用（ImmediateMultiDrag 立即取胜）。非主键（右键等）
  /// 不接管，返回 null 让事件自然结束。
  Drag? _onStart(Offset position) {
    _pressGlobal = position;
    _currentGlobal = position;
    _banding = false;
    _hits = const {};
    return _SurfaceDrag(this);
  }

  void _handleUpdate(Offset global) {
    if (!mounted) return;
    final press = _pressGlobal;
    if (press == null) return;
    if (!_banding) {
      if ((global - press).distance < _bandStartSlop) return;
      _banding = true;
      final startCell = _hitAt(widget.cellKeys, press);
      _addMode = startCell == null || !widget.selectedIds.contains(startCell);
      widget.onBandStart(_addMode);
    }
    _currentGlobal = global;
    _refreshBand();
  }

  void _refreshBand() {
    final press = _pressGlobal;
    final current = _currentGlobal;
    if (press == null || current == null) return;
    final band = Rect.fromPoints(press, current);
    final hits = <String>{};
    widget.cellKeys.forEach((id, key) {
      final rect = _rectOf(key);
      if (rect != null && rect.overlaps(band)) hits.add(id);
    });
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      _bandRect.value = Rect.fromPoints(
        box.globalToLocal(press),
        box.globalToLocal(current),
      );
    }
    if (!setEquals(hits, _hits)) {
      _hits = hits;
      widget.onBandUpdate(hits, _addMode);
    }
  }

  void _handleEnd() {
    if (!mounted) return;
    final press = _pressGlobal;
    final wasBanding = _banding;
    _reset();
    if (press == null) return;
    if (wasBanding) {
      widget.onBandEnd();
      return;
    }
    // 点选路由：先小按钮（角标叠在格子图上，必须先命中），再格子本体。
    final action = _hitAt(widget.actionKeys, press);
    if (action != null) {
      widget.onTapAction(action);
      return;
    }
    final cell = _hitAt(widget.cellKeys, press);
    if (cell != null) widget.onTapCell(cell);
  }

  void _handleCancel() {
    if (!mounted) return;
    final wasBanding = _banding;
    _reset();
    if (wasBanding) widget.onBandCancel();
  }

  void _reset() {
    _banding = false;
    _pressGlobal = null;
    _currentGlobal = null;
    _hits = const {};
    _bandRect.value = null;
  }

  Rect? _rectOf(GlobalKey key) {
    final ctx = key.currentContext;
    if (ctx == null) return null;
    final rb = ctx.findRenderObject();
    if (rb is! RenderBox || !rb.attached || !rb.hasSize) return null;
    return rb.localToGlobal(Offset.zero) & rb.size;
  }

  String? _hitAt(Map<String, GlobalKey> keys, Offset global) {
    for (final entry in keys.entries) {
      final rect = _rectOf(entry.value);
      if (rect != null && rect.contains(global)) return entry.key;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: {
        ImmediateMultiDragGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<
              ImmediateMultiDragGestureRecognizer
            >(
              () => ImmediateMultiDragGestureRecognizer(
                allowedButtonsFilter: (buttons) => buttons == kPrimaryButton,
              ),
              (instance) => instance.onStart = _onStart,
            ),
      },
      child: Stack(
        children: [
          widget.child,
          Positioned.fill(
            child: IgnorePointer(
              child: ValueListenableBuilder<Rect?>(
                valueListenable: _bandRect,
                builder: (context, rect, _) => rect == null
                    ? const SizedBox.shrink()
                    : CustomPaint(painter: _BandRectPainter(rect)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SurfaceDrag implements Drag {
  _SurfaceDrag(this._state);

  final _BandSelectSurfaceState _state;

  @override
  void update(DragUpdateDetails details) =>
      _state._handleUpdate(details.globalPosition);

  @override
  void end(DragEndDetails details) => _state._handleEnd();

  @override
  void cancel() => _state._handleCancel();
}

class _BandRectPainter extends CustomPainter {
  const _BandRectPainter(this.rect);

  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(rect, Paint()..color = Colors.blue.withValues(alpha: 0.15));
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.blue.shade600,
    );
  }

  @override
  bool shouldRepaint(covariant _BandRectPainter oldDelegate) =>
      oldDelegate.rect != rect;
}
