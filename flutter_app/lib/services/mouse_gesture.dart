import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 鼠标中键手势：按住中键拖出方向序列（四方向，连续同向合并）或画一个
/// 整圈（顺/逆时针圆），松手匹配映射表触发动作。主区快设、书籍校对、
/// 校对摆正三页共用同一套识别与配置，映射各自独立
///（[GestureSettings.quick] / [GestureSettings.editor] /
/// [GestureSettings.straighten]）。
///
/// 方向字母约定：L=← R=→ U=↑ D=↓；手势序列即字母串（如 L 形 = "LD"，
/// 先横后竖）；圆为 "CW"（↻ 顺时针）/ "CCW"（↺ 逆时针）、对勾为 "CK"
///（✓，两段斜线成 V 形下折，正反画法都认），两者都是轨迹几何特检，
/// 识别优先于方向序列。左键画框、右键平移、滚轮缩放与中键互斥（按钮
/// 位不同），天然无冲突。

/// 单段方向判定的最小位移（屏幕像素）：低于它的移动视为抖动/中键
/// 纯点击，不产生方向段。
const double kGestureStepMinPx = 12;

/// 手势序列的方向段数上限：超过的段丢弃（防误拖出无意义长序列）。
const int kGestureMaxSegments = 4;

/// 中键手势轨迹识别器（纯逻辑，可单测）。
class MouseGestureTracker {
  Offset? _origin;
  Offset? _segOrigin;
  final List<String> _segments = [];
  final List<Offset> trail = [];

  bool get isActive => _origin != null;

  void start(Offset p) {
    _origin = p;
    _segOrigin = p;
    _segments.clear();
    trail
      ..clear()
      ..add(p);
  }

  /// 采样一个移动点：位移超过 [kGestureStepMinPx] 后按主导轴判定方向段，
  /// 连续同方向不重复追加。
  void extend(Offset p) {
    if (_segOrigin == null) return;
    trail.add(p);
    final dx = p.dx - _segOrigin!.dx;
    final dy = p.dy - _segOrigin!.dy;
    if (dx.abs() < kGestureStepMinPx && dy.abs() < kGestureStepMinPx) return;
    final dir = dx.abs() > dy.abs() ? (dx < 0 ? 'L' : 'R') : (dy < 0 ? 'U' : 'D');
    if (_segments.isEmpty || _segments.last != dir) {
      if (_segments.length < kGestureMaxSegments) _segments.add(dir);
    }
    // 段内继续沿同方向时以该点为新段起点，斜向漂移不会被累计成噪声。
    _segOrigin = p;
  }

  /// 结束识别：优先检测圆（整圈 → "CW"/"CCW"）与对勾（"CK"），否则
  /// 返回方向序列（如 "LD"）；未产生任何有效手势（纯点击/抖动）返回
  /// null。
  String? finish() {
    final shape = _detectCircle() ?? _detectCheckmark();
    final result = shape ?? (_segments.isEmpty ? null : _segments.join());
    _origin = null;
    _segOrigin = null;
    _segments.clear();
    return result;
  }

  /// 圆检测：轨迹绕质心累计转角达到约一整圈（≥306°，允许画得欠一点
  /// 或绕过一圈）、首尾大致闭合、半径不至于小成误触。方向由转角符号
  /// 决定（屏幕坐标 y 轴向下，转角增加 = 顺时针）。来回直线/C 形的
  /// 转角远不足一圈，不会误判。
  String? _detectCircle() {
    final pts = trail;
    if (pts.length < 8) return null;
    var cx = 0.0, cy = 0.0;
    for (final p in pts) {
      cx += p.dx;
      cy += p.dy;
    }
    cx /= pts.length;
    cy /= pts.length;
    var rSum = 0.0;
    for (final p in pts) {
      rSum += (Offset(cx, cy) - p).distance;
    }
    final r = rSum / pts.length;
    if (r < 15) return null; // 半径太小：点击级乱画不算圆
    var total = 0.0;
    for (var i = 1; i < pts.length; i++) {
      final a0 = math.atan2(pts[i - 1].dy - cy, pts[i - 1].dx - cx);
      final a1 = math.atan2(pts[i].dy - cy, pts[i].dx - cx);
      var d = a1 - a0;
      if (d > math.pi) d -= 2 * math.pi;
      if (d < -math.pi) d += 2 * math.pi;
      total += d;
    }
    if (total.abs() < 1.7 * math.pi) return null; // 不足约 306°：不是整圈
    final gap = (pts.last - pts.first).distance;
    if (gap > math.max(2 * r * 0.7, 40)) return null; // 首尾差太远：不是闭合圆
    return total > 0 ? 'CW' : 'CCW';
  }

  /// 对勾检测：轨迹呈 V 形下折——顶点（最低点）明显低于起点与终点，
  /// 起终点分居顶点左右两侧，两段都是斜线（非轴对齐）且大体笔直。
  /// 正向（左→右）与镜像（右→左）画法都认，V 形（无长尾）也算。轴对齐
  /// 的 L 形（→↑ 等）倾角不够，保持原方向序列语义不会被吃掉；W/M/Z、
  /// 半圆弧这类带弯折的轨迹被直线度门排除（判据见 [_isCheckStroke]）。
  String? _detectCheckmark() {
    final pts = trail;
    if (pts.length < 8) return null;
    var minX = pts.first.dx, maxX = pts.first.dx;
    var vi = 0;
    for (var i = 0; i < pts.length; i++) {
      final p = pts[i];
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy > pts[vi].dy) vi = i;
    }
    if (maxX - minX < 36) return null; // 太窄：点击级乱画不算对勾
    final start = pts.first, end = pts.last, vertex = pts[vi];
    // 顶点须明显低于两端（与 [kGestureStepMinPx] 同量级），否则只是斜线
    // 或下折的折线。
    if (vertex.dy < start.dy + 12 || vertex.dy < end.dy + 12) return null;
    // 起终点分居顶点左右两侧（正反画法都认）。
    final startSide = start.dx - vertex.dx;
    final endSide = end.dx - vertex.dx;
    if (startSide.abs() < 10 || endSide.abs() < 10) return null;
    if (startSide.sign == endSide.sign) return null;
    return _isCheckStroke(pts.sublist(0, vi + 1)) &&
            _isCheckStroke(pts.sublist(vi, pts.length))
        ? 'CK'
        : null;
  }

  /// 对勾的一笔：[stroke] 为顶点前/后的一段轨迹（含两端）。判定：弦够
  /// 长（≥24px）、斜率适中（水平/垂直分量互相占比 ≥0.25，即倾角约
  /// 14°–76°——轴对齐的横竖段不算）、大体笔直（段内点到弦的最大垂距
  /// ≤0.15×弦长——半圆弧的垂距占比约 0.21，被此门排除）。
  bool _isCheckStroke(List<Offset> stroke) {
    final a = stroke.first, b = stroke.last;
    final dx = (b.dx - a.dx).abs();
    final dy = (b.dy - a.dy).abs();
    final len = (b - a).distance;
    if (len < 24) return false;
    if (dx < 0.25 * dy || dy < 0.25 * dx) return false;
    final maxDev = 0.15 * len;
    for (final p in stroke) {
      // 点到弦 ab 的垂距 = 叉积 / 弦长。
      final cross =
          (b.dx - a.dx) * (p.dy - a.dy) - (b.dy - a.dy) * (p.dx - a.dx);
      if (cross.abs() / len > maxDev) return false;
    }
    return true;
  }

  void cancel() {
    _origin = null;
    _segOrigin = null;
    _segments.clear();
    trail.clear();
  }
}

/// 手势目录：设置页可选的手势集合（单方向 + 常用两段折线 + 整圈圆 +
/// 对勾）。显示名用箭头符号，与画布上的轨迹直觉一致。
class GestureCatalog {
  static const Map<String, String> gestures = {
    'L': '←', 'R': '→', 'U': '↑', 'D': '↓',
    'LR': '←→', 'RL': '→←', 'UD': '↑↓', 'DU': '↓↑',
    'LD': '←↓（L 形）', 'DL': '↓←', 'RD': '→↓', 'DR': '↓→',
    'UL': '←↑', 'LU': '↑←', 'RU': '→↑', 'UR': '↑→',
    'CW': '↻（顺时针圆）', 'CCW': '↺（逆时针圆）',
    'CK': '✓（对勾）',
  };

  /// 主区快设页的动作目录（动作 id → 显示名）。
  static const Map<String, String> quickActions = {
    'confirmNext': '确认并下一页',
    'prevPage': '上一页',
    'nextPage': '下一页',
    'restore': '恢复原区',
    'clearActive': '清除当前类框',
  };

  /// 书籍校对页的动作目录。
  static const Map<String, String> editorActions = {
    'saveAll': '确认并保存',
    'saveDraft': '临时保存',
    'confirmBoxes': '确认识别框',
    'prevPage': '上一页',
    'nextPage': '下一页',
  };

  /// 校对摆正页的动作目录。
  static const Map<String, String> straightenActions = {
    'rotateCw': '顺时针旋转 90°',
    'rotateCcw': '逆时针旋转 90°',
    'confirmNext': '确认并下一页',
  };

  static String gestureLabel(String seq) => gestures[seq] ?? seq;

  /// 解析持久化 JSON 里的映射表：手势序列与动作 id 都必须在目录内，
  /// 否则剔除（目录演进后旧数据自动收缩，不会读到悬空动作）。
  static Map<String, String> parseMappings(
    Object? raw,
    Map<String, String> actions,
  ) {
    if (raw is! Map) return const {};
    final out = <String, String>{};
    raw.forEach((key, value) {
      if (key is String &&
          value is String &&
          gestures.containsKey(key) &&
          actions.containsKey(value)) {
        out[key] = value;
      }
    });
    return out;
  }
}

/// 手势配置（SharedPreferences 单 JSON 串，照 OllamaSettings 模式）：
/// enabled 总开关 + 三页各自的手势 → 动作映射。
class GestureSettings {
  const GestureSettings({
    this.enabled = true,
    this.quick = defaultQuick,
    this.editor = defaultEditor,
    this.straighten = defaultStraighten,
  });

  final bool enabled;

  /// 主区快设页：手势序列 → 动作 id。
  final Map<String, String> quick;

  /// 书籍校对页：手势序列 → 动作 id。
  final Map<String, String> editor;

  /// 校对摆正页：手势序列 → 动作 id。
  final Map<String, String> straighten;

  static const Map<String, String> defaultQuick = {
    'LD': 'confirmNext', // L 形：确认并下一页
    'L': 'prevPage',
    'R': 'nextPage',
  };

  static const Map<String, String> defaultEditor = {
    'LD': 'saveAll', // L 形：确认并保存
    'D': 'saveDraft',
    'DR': 'confirmBoxes', // ↓→：确认识别框
    'L': 'prevPage',
    'R': 'nextPage',
  };

  static const Map<String, String> defaultStraighten = {
    'LD': 'confirmNext', // L 形：确认并下一页
    'CW': 'rotateCw', // 顺时针圆：顺时针旋转 90°
    'CCW': 'rotateCcw', // 逆时针圆：逆时针旋转 90°
  };

  static const String _prefsKey = 'mouse_gesture_settings_v1';

  factory GestureSettings.fromJson(Map<String, dynamic> j) => GestureSettings(
    enabled: j['enabled'] as bool? ?? true,
    quick: GestureCatalog.parseMappings(
      j['quick'],
      GestureCatalog.quickActions,
    ),
    editor: GestureCatalog.parseMappings(
      j['editor'],
      GestureCatalog.editorActions,
    ),
    straighten: GestureCatalog.parseMappings(
      j['straighten'],
      GestureCatalog.straightenActions,
    ),
  );

  /// 旧数据把手势映射成空表时回退默认（开关仍尊重用户选择）。straighten
  /// 键晚于该持久化格式加入，老数据整键缺失，同样回退默认。
  factory GestureSettings.fromRawJson(Map<String, dynamic> j) {
    final s = GestureSettings.fromJson(j);
    final quickEmpty = (j['quick'] is Map) && (j['quick'] as Map).isEmpty;
    final editorEmpty = (j['editor'] is Map) && (j['editor'] as Map).isEmpty;
    final straightenEmpty =
        j['straighten'] is! Map || (j['straighten'] as Map).isEmpty;
    return GestureSettings(
      enabled: s.enabled,
      quick: quickEmpty ? defaultQuick : s.quick,
      editor: editorEmpty ? defaultEditor : s.editor,
      straighten: straightenEmpty ? defaultStraighten : s.straighten,
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'quick': quick,
    'editor': editor,
    'straighten': straighten,
  };

  static Future<GestureSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return const GestureSettings();
    try {
      return GestureSettings.fromRawJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      return const GestureSettings();
    }
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(toJson()));
  }

  GestureSettings copyWith({
    bool? enabled,
    Map<String, String>? quick,
    Map<String, String>? editor,
    Map<String, String>? straighten,
  }) => GestureSettings(
    enabled: enabled ?? this.enabled,
    quick: quick ?? this.quick,
    editor: editor ?? this.editor,
    straighten: straighten ?? this.straighten,
  );
}

/// 手势拖动中的轨迹层画笔：橙色圆头折线 + 起点圆点，屏幕坐标直画
///（挂在页面顶层 Stack 的 Positioned.fill + IgnorePointer 里，不挡
/// 任何交互）。
class GestureTrailPainter extends CustomPainter {
  const GestureTrailPainter({required this.points});

  final List<Offset> points;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) {
      if (points.length == 1) {
        canvas.drawCircle(
          points[0],
          4,
          Paint()..color = Colors.orange.shade700,
        );
      }
      return;
    }
    final line = Paint()
      ..color = Colors.orange.shade700
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, line);
    canvas.drawCircle(
      points.first,
      4,
      Paint()..color = Colors.orange.shade700,
    );
    // 末端箭头感：终点画一个小圆 + 半透明方向尾。
    canvas.drawCircle(
      points.last,
      5,
      Paint()..color = Colors.orange.shade700.withValues(alpha: 0.55),
    );
  }

  @override
  bool shouldRepaint(GestureTrailPainter old) {
    // points 是 tracker.trail 的活引用（增量追加，新旧 painter 拿到的是
    // 同一个 List），比较 length/last 恒等——必须始终重绘，否则只画出
    // 首帧的起点圆点（用户实测"只显示一个点"）。轨迹是一条折线，
    // 无条件重绘的代价可忽略。
    return true;
  }
}
