import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 一条曲线：x 取轮数（epoch），y 取指标值；y 为 null 的点按断开处理
/// （results.csv 里解析失败的单元格）。
class ChartSeries {
  final String name;
  final Color color;
  final List<(double, double?)> points;

  const ChartSeries({
    required this.name,
    required this.color,
    required this.points,
  });
}

/// 轻量多序列折线图（无三方依赖）：值轴 + 轮数轴 + 网格，悬停/点按出现
/// 竖线并在图下方显示该轮各序列取值，图例点按可隐藏/恢复序列。
class TrainingLineChart extends StatefulWidget {
  final List<ChartSeries> series;
  final double height;

  /// 按序号取曲线配色（构造 ChartSeries 时用，保证曲线/图例一致）。
  static Color paletteColor(int index) =>
      _paletteColors[index % _paletteColors.length];

  static const _paletteColors = [
    Color(0xFF1E88E5),
    Color(0xFFE53935),
    Color(0xFF43A047),
    Color(0xFFFB8C00),
    Color(0xFF8E24AA),
    Color(0xFF00897B),
  ];

  const TrainingLineChart({super.key, required this.series, this.height = 220});

  @override
  State<TrainingLineChart> createState() => _TrainingLineChartState();
}

class _TrainingLineChartState extends State<TrainingLineChart> {
  final Set<String> _hidden = {};
  double? _activeX; // 悬停/点按定位到的轮数

  List<ChartSeries> get _visible =>
      widget.series.where((s) => !_hidden.contains(s.name)).toList();

  void _toggle(String name) {
    // 至少保留一条可见曲线，避免全隐藏后图表空置
    if (_visible.length <= 1 && !_hidden.contains(name)) return;
    setState(() {
      _hidden.contains(name) ? _hidden.remove(name) : _hidden.add(name);
      _activeX = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return SizedBox(
              width: double.infinity,
              height: widget.height,
              child: MouseRegion(
                onHover: (e) => _locate(e.localPosition, width),
                onExit: (_) => setState(() => _activeX = null),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => _locate(d.localPosition, width),
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: _LineChartPainter(
                      series: _visible,
                      activeX: _activeX,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 4),
        _buildLegend(),
        _buildValueRow(),
      ],
    );
  }

  // 图表内像素坐标 → 轮数（与 painter 的布局参数保持一致）
  void _locate(Offset local, double width) {
    const left = 46.0, right = 10.0;
    final plotW = math.max(1.0, width - left - right);
    final xs =
        widget.series.expand((s) => s.points.map((p) => p.$1)).toList();
    if (xs.isEmpty) return;
    final xMin = xs.reduce(math.min), xMax = xs.reduce(math.max);
    final ratio = ((local.dx - left) / plotW).clamp(0.0, 1.0);
    final domain = xMin + ratio * (xMax - xMin);
    final snapped = domain.roundToDouble().clamp(xMin, xMax);
    if (snapped != _activeX) setState(() => _activeX = snapped);
  }

  Widget _buildLegend() {
    return Wrap(
      spacing: 10,
      runSpacing: 2,
      children: [
        for (final s in widget.series)
          InkWell(
            onTap: () => _toggle(s.name),
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 14,
                    height: 3,
                    color: _hidden.contains(s.name)
                        ? Colors.grey.shade300
                        : s.color,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    s.name,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: _hidden.contains(s.name)
                          ? Colors.grey
                          : Colors.black87,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildValueRow() {
    final x = _activeX;
    if (x == null) {
      final n = widget.series
          .fold<int>(0, (m, s) => math.max(m, s.points.length));
      return Text(
        n > 0 ? '共 $n 轮 · 悬停或点按曲线查看数值' : '暂无数据',
        style: const TextStyle(fontSize: 10.5, color: Colors.grey),
      );
    }
    final parts = <String>['第 ${x.round()} 轮'];
    for (final s in _visible) {
      final hit = _nearest(s.points, x);
      if (hit == null || hit.$2 == null) continue;
      parts.add('${s.name}=${_fmt(hit.$2!)}');
    }
    return Text(
      parts.join(' · '),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 10.5, color: Colors.black87),
    );
  }

  static (double, double?)? _nearest(
      List<(double, double?)> points, double x) {
    (double, double?)? best;
    var bestDist = double.infinity;
    for (final p in points) {
      final d = (p.$1 - x).abs();
      if (d < bestDist) {
        bestDist = d;
        best = p;
      }
    }
    return best;
  }

  static String _fmt(double v) {
    final a = v.abs();
    if (a >= 100) return v.toStringAsFixed(0);
    if (a >= 10) return v.toStringAsFixed(1);
    if (a >= 1) return v.toStringAsFixed(2);
    return v.toStringAsFixed(4);
  }
}

/// 图表绘图区矩形 + 数据域范围（painter 内部的公共换算基准）。
class _Grid {
  final double left, top, right, bottom, xMin, xMax, yMin, yMax;
  const _Grid(this.left, this.top, this.right, this.bottom, this.xMin,
      this.xMax, this.yMin, this.yMax);
}

class _LineChartPainter extends CustomPainter {
  final List<ChartSeries> series;
  final double? activeX;

  static const _left = 46.0, _top = 10.0, _right = 10.0, _bottom = 22.0;

  _LineChartPainter({required this.series, required this.activeX});

  @override
  void paint(Canvas canvas, Size size) {
    final g = _computeGrid(size);
    _axes(canvas, size, g);
    if (series.isEmpty) return;
    for (final s in series) {
      final path = Path();
      var penDown = false;
      for (final (x, y) in s.points) {
        if (y == null) {
          penDown = false;
          continue;
        }
        final px = _px(x, g), py = _py(y, g);
        penDown ? path.lineTo(px, py) : path.moveTo(px, py);
        penDown = true;
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = s.color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6
            ..isAntiAlias = true);
      // 点太多时省略圆点，只留折线
      if (s.points.length <= 60) {
        for (final (x, y) in s.points) {
          if (y == null) continue;
          canvas.drawCircle(
              Offset(_px(x, g), _py(y, g)), 1.8, Paint()..color = s.color);
        }
      }
    }
    final ax = activeX;
    if (ax != null) {
      final px = _px(ax, g);
      if (px >= g.left && px <= g.right) {
        canvas.drawLine(
            Offset(px, g.top),
            Offset(px, g.bottom),
            Paint()
              ..color = Colors.black45
              ..strokeWidth = 1);
      }
    }
  }

  _Grid _computeGrid(Size size) {
    final xs = series.expand((s) => s.points.map((p) => p.$1)).toList();
    final ys = series
        .expand((s) => s.points)
        .where((p) => p.$2 != null)
        .map((p) => p.$2!)
        .toList();
    final xMin = xs.isEmpty ? 0.0 : xs.reduce(math.min);
    var xMax = xs.isEmpty ? 1.0 : xs.reduce(math.max);
    var yMin = ys.isEmpty ? 0.0 : ys.reduce(math.min);
    var yMax = ys.isEmpty ? 1.0 : ys.reduce(math.max);
    final ySpan = (yMax - yMin).abs();
    final pad = ySpan < 1e-9 ? 0.5 : ySpan * 0.08;
    yMin -= pad;
    yMax += pad;
    if (xMax == xMin) xMax = xMin + 1;
    return _Grid(
      _left,
      _top,
      math.max(_left + 1, size.width - _right),
      math.max(_top + 1, size.height - _bottom),
      xMin,
      xMax,
      yMin,
      yMax,
    );
  }

  double _px(double x, _Grid g) =>
      g.left + (x - g.xMin) / (g.xMax - g.xMin) * (g.right - g.left);

  double _py(double y, _Grid g) =>
      g.bottom - (y - g.yMin) / (g.yMax - g.yMin) * (g.bottom - g.top);

  void _axes(Canvas canvas, Size size, _Grid g) {
    final border = Paint()
      ..color = Colors.grey.shade300
      ..strokeWidth = 1;
    canvas.drawLine(Offset(g.left, g.top), Offset(g.left, g.bottom), border);
    canvas.drawLine(
        Offset(g.left, g.bottom), Offset(g.right, g.bottom), border);
    const gridStyle = TextStyle(fontSize: 9.5, color: Colors.grey);
    for (var i = 0; i <= 4; i++) {
      final t = i / 4;
      final v = g.yMin + t * (g.yMax - g.yMin);
      final y = g.bottom - t * (g.bottom - g.top);
      if (i > 0 && i < 4) {
        canvas.drawLine(
            Offset(g.left, y),
            Offset(g.right, y),
            Paint()
              ..color = Colors.grey.shade200
              ..strokeWidth = 1);
      }
      _label(canvas, _fmtAxis(v), Offset(g.left - 4, y - 6), gridStyle,
          align: TextAlign.right, maxWidth: 42);
    }
    // 轮数标签：约 6 个刻度
    final n = (g.xMax - g.xMin).round();
    if (n <= 0) return;
    final step = (n / 6).ceil().clamp(1, n);
    var epoch = (g.xMin.ceil() / step).ceil() * step;
    const style = TextStyle(fontSize: 9.5, color: Colors.grey);
    for (; epoch <= g.xMax; epoch += step) {
      _label(canvas, '$epoch', Offset(_px(epoch.toDouble(), g), g.bottom + 3),
          style,
          align: TextAlign.center, maxWidth: 40);
    }
  }

  static String _fmtAxis(double v) {
    final a = v.abs();
    if (a >= 10) return v.toStringAsFixed(0);
    if (a >= 1) return v.toStringAsFixed(1);
    return v.toStringAsFixed(2);
  }

  void _label(Canvas canvas, String text, Offset pos, TextStyle style,
      {TextAlign align = TextAlign.left, double maxWidth = 120}) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textWidthBasis: TextWidthBasis.longestLine,
    )..layout(maxWidth: maxWidth);
    var dx = pos.dx;
    if (align == TextAlign.right) dx -= tp.width;
    if (align == TextAlign.center) dx -= tp.width / 2;
    tp.paint(canvas, Offset(dx, pos.dy));
  }

  @override
  bool shouldRepaint(_LineChartPainter old) =>
      old.activeX != activeX ||
      old.series.length != series.length ||
      _seriesSig(old.series) != _seriesSig(series);

  static String _seriesSig(List<ChartSeries> s) => s
      .map((e) =>
          '${e.name}:${e.points.length}:${e.points.isEmpty ? 0 : e.points.last.$2}')
      .join('|');
}
