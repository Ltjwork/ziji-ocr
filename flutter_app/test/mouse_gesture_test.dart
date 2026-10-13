import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/services/mouse_gesture.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('MouseGestureTracker 方向序列识别', () {
    test('水平拖动 → 单方向 L / R', () {
      final t = MouseGestureTracker()..start(const Offset(100, 100));
      t.extend(const Offset(60, 100));
      t.extend(const Offset(20, 100));
      expect(t.finish(), 'L');

      final t2 = MouseGestureTracker()..start(const Offset(0, 0));
      t2.extend(const Offset(50, 5)); // 斜向但水平主导
      t2.extend(const Offset(120, 8));
      expect(t2.finish(), 'R');
    });

    test('垂直拖动 → U / D', () {
      final t = MouseGestureTracker()..start(const Offset(0, 100));
      t.extend(const Offset(3, 40));
      expect(t.finish(), 'U');

      final t2 = MouseGestureTracker()..start(const Offset(0, 0));
      t2.extend(const Offset(3, 60));
      expect(t2.finish(), 'D');
    });

    test('L 形（先左后下）→ LD；连续同向合并', () {
      final t = MouseGestureTracker()..start(const Offset(300, 100));
      // 先横：多段采样，同为 L 只记一次
      t.extend(const Offset(250, 102));
      t.extend(const Offset(200, 100));
      t.extend(const Offset(150, 103));
      // 再竖：向下
      t.extend(const Offset(148, 160));
      t.extend(const Offset(150, 220));
      expect(t.finish(), 'LD');
    });

    test('位移不足阈值 → 纯点击返回 null；轨迹仍记录', () {
      final t = MouseGestureTracker()..start(const Offset(50, 50));
      t.extend(const Offset(55, 52));
      t.extend(const Offset(48, 55));
      expect(t.finish(), isNull);
      expect(t.trail.length, 3);
    });

    test('方向往返 → 各记一段（RL 可表达来回）', () {
      final t = MouseGestureTracker()..start(const Offset(100, 0));
      t.extend(const Offset(160, 0)); // R
      t.extend(const Offset(100, 0)); // L
      expect(t.finish(), 'RL');
    });

    test('段数上限：超过 4 段的拖动截断为 4', () {
      final t = MouseGestureTracker()..start(const Offset(0, 0));
      var x = 0.0, y = 0.0;
      // 交替 R/D 五次（10 段）
      for (var i = 0; i < 5; i++) {
        x += 20;
        t.extend(Offset(x, y)); // R
        y += 20;
        t.extend(Offset(x, y)); // D
      }
      final seq = t.finish()!;
      expect(seq.length, 4);
      expect(seq, 'RDRD');
    });

    test('finish 后可复用（翻页连续画手势）', () {
      final t = MouseGestureTracker()..start(const Offset(0, 0));
      t.extend(const Offset(30, 0));
      expect(t.finish(), 'R');
      expect(t.isActive, isFalse);
      t.start(const Offset(0, 0));
      t.extend(const Offset(0, 30));
      expect(t.finish(), 'D');
    });
  });

  group('圆手势识别（CW/CCW）', () {
    /// 沿圆周撒点喂给 tracker：[sweep] 为正=顺时针（屏幕坐标 y 向下）、
    /// 为负=逆时针（步进方向随符号）。
    MouseGestureTracker drawCircle({
      required double radius,
      required double sweep,
      Offset center = const Offset(200, 200),
    }) {
      final t = MouseGestureTracker()..start(center + Offset(radius, 0));
      final step = sweep >= 0 ? 0.15 : -0.15;
      for (var a = step;
          sweep >= 0 ? a <= sweep : a >= sweep;
          a += step) {
        t.extend(
          center + Offset(radius * math.cos(a), radius * math.sin(a)),
        );
      }
      return t;
    }

    test('顺时针整圈 → CW；逆时针整圈 → CCW', () {
      expect(drawCircle(radius: 60, sweep: 2 * math.pi).finish(), 'CW');
      expect(drawCircle(radius: 60, sweep: -2 * math.pi).finish(), 'CCW');
    });

    test('画得欠一点（约 330°）仍是圆；绕过一圈也认', () {
      expect(drawCircle(radius: 60, sweep: 1.85 * math.pi).finish(), 'CW');
      expect(drawCircle(radius: 60, sweep: 2.4 * math.pi).finish(), 'CW');
    });

    test('C 形半圆不足一圈 → 不判圆（回落为方向序列）', () {
      final seq = drawCircle(radius: 60, sweep: math.pi).finish();
      expect(seq, isNot(anyOf('CW', 'CCW')));
      expect(seq, isNotNull); // 仍给出方向序列（如 ←↓ 或 D 之类）
    });

    test('半径太小的圈不算（点击级乱画）', () {
      final seq = drawCircle(radius: 8, sweep: 2 * math.pi).finish();
      expect(seq, isNot('CW'));
      expect(seq, isNot('CCW'));
    });

    test('来回直线转角抵消，不误判为圆', () {
      final t = MouseGestureTracker()..start(const Offset(0, 0));
      for (var i = 0; i < 6; i++) {
        t.extend(Offset(30.0 * (i.isEven ? 1 : -1) + 30, i * 5.0));
      }
      final seq = t.finish();
      expect(seq, isNot(anyOf('CW', 'CCW')));
    });

    test('目录与往返：圆手势可绑定可持久化', () {
      expect(GestureCatalog.gestures.containsKey('CW'), isTrue);
      expect(GestureCatalog.gestures.containsKey('CCW'), isTrue);
      final s = GestureSettings.fromJson({
        'enabled': true,
        'quick': {'CW': 'confirmNext'},
        'editor': {'CCW': 'saveAll'},
      });
      expect(s.quick['CW'], 'confirmNext');
      expect(s.editor['CCW'], 'saveAll');
    });
  });

  group('对勾识别（CK）', () {
    /// 沿折线锚点插值撒点喂给 tracker（默认步长足够触发方向段量化）。
    MouseGestureTracker drawPolyline(List<Offset> anchors, [double step = 14]) {
      final t = MouseGestureTracker()..start(anchors.first);
      for (var i = 1; i < anchors.length; i++) {
        final a = anchors[i - 1], b = anchors[i];
        final n = ((b - a).distance / step).ceil();
        for (var k = 1; k <= n; k++) {
          t.extend(
            Offset(a.dx + (b.dx - a.dx) * k / n, a.dy + (b.dy - a.dy) * k / n),
          );
        }
      }
      return t;
    }

    test('标准对勾（左上起笔下折再上挑）→ CK', () {
      // 该轨迹的方向量化是 "DU"（先↓后↑）——正是与既有目录冲突、必须走
      // 几何特检的原因。
      final t = drawPolyline([
        const Offset(100, 100),
        const Offset(160, 190),
        const Offset(280, 60),
      ]);
      expect(t.finish(), 'CK');
    });

    test('镜像对勾（右上起笔）与 V 形 → CK', () {
      expect(
        drawPolyline([
          const Offset(300, 80),
          const Offset(200, 190),
          const Offset(80, 110),
        ]).finish(),
        'CK',
      );
      expect(
        drawPolyline([
          const Offset(100, 100),
          const Offset(190, 200),
          const Offset(280, 100),
        ]).finish(),
        'CK',
      );
    });

    test('轴对齐 L（→ 再 ↑）仍是 RU，不被对勾吃掉', () {
      expect(
        drawPolyline([
          const Offset(100, 200),
          const Offset(250, 200),
          const Offset(250, 60),
        ]).finish(),
        'RU',
      );
    });

    test('Z 形 / W 形 / 纯斜线不判对勾', () {
      // Z：终点与底部横行同高，顶点深度不足。
      expect(
        drawPolyline([
          const Offset(100, 100),
          const Offset(300, 100),
          const Offset(100, 300),
          const Offset(300, 300),
        ]).finish(),
        isNot('CK'),
      );
      // W：顶点后段带弯折，直线度不够。
      expect(
        drawPolyline([
          const Offset(50, 100),
          const Offset(125, 200),
          const Offset(200, 110),
          const Offset(275, 200),
          const Offset(350, 100),
        ]).finish(),
        isNot('CK'),
      );
      // 单斜线：顶点即终点。
      expect(
        drawPolyline([const Offset(100, 100), const Offset(300, 260)])
            .finish(),
        isNot('CK'),
      );
    });

    test('太小的对勾不算（点击级乱画）', () {
      // 步长取小让点数足够（排除点数门），专测宽度门（整体宽 34px < 36）。
      final seq = drawPolyline([
        const Offset(100, 100),
        const Offset(117, 132),
        const Offset(134, 98),
      ], 6).finish();
      expect(seq, isNot('CK'));
    });

    test('下半圆弧（画圆画欠了的 C 形）不判对勾', () {
      // 弧上点到弦的垂距占比约 0.21，被直线度门（0.15）排除。
      final t = MouseGestureTracker()..start(const Offset(260, 200));
      for (var a = 0.12; a <= math.pi; a += 0.12) {
        t.extend(Offset(200 + 60 * math.cos(a), 200 + 60 * math.sin(a)));
      }
      expect(t.finish(), isNot('CK'));
    });

    test('圆优先于对勾：整圈轨迹仍判圆', () {
      final t = MouseGestureTracker()..start(const Offset(260, 200));
      for (var a = 0.15; a <= 2 * math.pi; a += 0.15) {
        t.extend(Offset(200 + 60 * math.cos(a), 200 + 60 * math.sin(a)));
      }
      expect(t.finish(), 'CW');
    });

    test('目录与持久化：对勾可绑定可持久化', () {
      expect(GestureCatalog.gestures.containsKey('CK'), isTrue);
      final s = GestureSettings.fromJson({
        'enabled': true,
        'editor': {'CK': 'confirmBoxes'},
      });
      expect(s.editor['CK'], 'confirmBoxes');
    });
  });

  group('GestureSettings 持久化与容错', () {
    test('默认值：开关开、含完整默认映射', () {
      const s = GestureSettings();
      expect(s.enabled, isTrue);
      expect(s.quick['LD'], 'confirmNext');
      expect(s.editor['LD'], 'saveAll');
      expect(s.editor['DR'], 'confirmBoxes');
      // 校对摆正：L 形确认并下一页，圆手势按圈向旋转 90°。
      expect(s.straighten['LD'], 'confirmNext');
      expect(s.straighten['CW'], 'rotateCw');
      expect(s.straighten['CCW'], 'rotateCcw');
    });

    test('JSON 往返', () {
      final s = GestureSettings.fromJson(const GestureSettings().toJson());
      expect(s.enabled, const GestureSettings().enabled);
      expect(s.quick, const GestureSettings().quick);
      expect(s.editor, const GestureSettings().editor);
      expect(s.straighten, const GestureSettings().straighten);
    });

    test('无效手势/动作剔除，合法项保留', () {
      final s = GestureSettings.fromJson({
        'enabled': false,
        'quick': {
          'LD': 'confirmNext', // 合法
          'XYZ': 'nextPage', // 手势不在目录
          'R': 'nonexistent_action', // 动作不在目录
        },
        'editor': <String, String>{},
        'straighten': {'CW': 'rotateCw', 'U': 'saveAll'}, // saveAll 不属于本页
      });
      expect(s.enabled, isFalse);
      expect(s.quick, {'LD': 'confirmNext'});
      expect(s.straighten, {'CW': 'rotateCw'});
    });

    test('旧数据空映射表回退默认，开关选择保留', () {
      final s = GestureSettings.fromRawJson({
        'enabled': false,
        'quick': <String, String>{},
        'editor': <String, String>{},
        'straighten': <String, String>{},
      });
      expect(s.enabled, isFalse);
      expect(s.quick, GestureSettings.defaultQuick);
      expect(s.editor, GestureSettings.defaultEditor);
      expect(s.straighten, GestureSettings.defaultStraighten);
    });

    test('straighten 键整键缺失（该页手势功能加入前的老数据）回退默认', () {
      final s = GestureSettings.fromRawJson({
        'enabled': true,
        'quick': {'L': 'prevPage'},
        'editor': {'D': 'saveDraft'},
      });
      expect(s.straighten, GestureSettings.defaultStraighten);
      // 已有页的映射不受影响。
      expect(s.quick, {'L': 'prevPage'});
      expect(s.editor, {'D': 'saveDraft'});
    });

    test('copyWith', () {
      const s = GestureSettings();
      final s2 = s.copyWith(
        enabled: false,
        quick: {'U': 'restore'},
        straighten: {'U': 'rotateCw'},
      );
      expect(s2.enabled, isFalse);
      expect(s2.quick, {'U': 'restore'});
      expect(s2.straighten, {'U': 'rotateCw'});
      expect(s2.editor, s.editor); // 未动的字段保持
    });

    test('load/save 经 SharedPreferences 往返', () async {
      SharedPreferences.setMockInitialValues({});
      final s = const GestureSettings().copyWith(
        enabled: false,
        quick: {'U': 'restore'},
      );
      await s.save();
      final loaded = await GestureSettings.load();
      expect(loaded.enabled, isFalse);
      expect(loaded.quick, {'U': 'restore'});
      expect(loaded.editor, GestureSettings.defaultEditor);
      expect(loaded.straighten, GestureSettings.defaultStraighten);
    });

    test('损坏的持久化 JSON → 回默认', () async {
      SharedPreferences.setMockInitialValues({
        'mouse_gesture_settings_v1': '{not json',
      });
      final loaded = await GestureSettings.load();
      expect(loaded.enabled, isTrue);
      expect(loaded.quick, GestureSettings.defaultQuick);
    });
  });

  group('GestureTrailPainter', () {
    test('对同一活引用始终重绘（回归：画手势时只显示起点一个点）', () {
      final trail = <Offset>[const Offset(10, 10)];
      final p1 = GestureTrailPainter(points: trail);
      // 新旧 painter 拿到的是 tracker.trail 同一个 List 引用，追加后
      // 长度比较在两个实例间看到的值相同——此前 shouldRepaint 恒 false，
      // 首帧之后轨迹不再重绘（用户实测只显示一个点）。
      final p2 = GestureTrailPainter(points: trail);
      trail.add(const Offset(40, 12));
      expect(p2.shouldRepaint(p1), isTrue);
    });

    test('空轨迹/单点不抛异常', () {
      const GestureTrailPainter(points: [])
          .paint(ui.Canvas(ui.PictureRecorder()), ui.Size.zero);
      const GestureTrailPainter(points: [ui.Offset(5, 5)])
          .paint(ui.Canvas(ui.PictureRecorder()), ui.Size.zero);
    });
  });
}
