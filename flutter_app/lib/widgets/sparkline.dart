import 'package:flutter/material.dart';

/// 迷你折线图（0~100 归一）：0.15 透明度面积填充 + 1.5px 折线 + 末点
/// 圆点；无数据时画一条底部基线示意。自绘 CustomPainter，无第三方图表
/// 依赖（与项目"依赖最简"一致）。识别监控悬浮窗的系统占用曲线用它。
class Sparkline extends StatelessWidget {
  const Sparkline({super.key, required this.history, required this.color});

  /// 0~100 的滚动历史，旧→新从左到右；空列表 = 不可用（画基线）。
  final List<double> history;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.infinite,
      painter: _SparklinePainter(history: history, color: color),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({required this.history, required this.color});

  final List<double> history;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (history.isEmpty) {
      final paint = Paint()
        ..color = color.withValues(alpha: 0.25)
        ..strokeWidth = 1;
      canvas.drawLine(
        Offset(0, size.height - 0.5),
        Offset(size.width, size.height - 0.5),
        paint,
      );
      return;
    }
    final step = history.length == 1 ? 0.0 : size.width / (history.length - 1);
    Offset pointAt(int i) => Offset(
          i * step,
          size.height - (history[i] / 100) * (size.height - 3) - 1.5,
        );

    final fill = Path()..moveTo(0, size.height);
    final line = Path();
    for (var i = 0; i < history.length; i++) {
      final p = pointAt(i);
      fill.lineTo(p.dx, p.dy);
      if (i == 0) {
        line.moveTo(p.dx, p.dy);
      } else {
        line.lineTo(p.dx, p.dy);
      }
    }
    fill.lineTo((history.length - 1) * step, size.height);
    fill.close();
    canvas.drawPath(
      fill,
      Paint()
        ..color = color.withValues(alpha: 0.15)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    final last = pointAt(history.length - 1);
    canvas.drawCircle(last, 2, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_SparklinePainter oldDelegate) =>
      oldDelegate.history.length != history.length ||
      (history.isNotEmpty && oldDelegate.history.isNotEmpty
          ? oldDelegate.history.first != history.first ||
              oldDelegate.history.last != history.last
          : false) ||
      oldDelegate.color != color;
}
