import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/services/annotation_hit_geometry.dart';
import 'package:gujichazi/services/editor_shortcut_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('mergeCharBoxes 合并两个字框', () {
    CharBlock box(
      String id,
      int x,
      int y,
      int w,
      int h, {
      String text = '',
      String status = AnnotationStatus.proposed,
      bool marked = false,
      String origText = 'ocr',
    }) => CharBlock(
      id: id,
      x: x,
      y: y,
      w: w,
      h: h,
      col: 0,
      order: 0,
      text: text,
      status: status,
      marked: marked,
      origText: origText,
    );

    test('竖排行：矩形取并集、文字按 y 上→下拼接、沿用第一个框的 id 与标记', () {
      final top = box('a', 10, 0, 20, 30, text: '木', marked: true);
      final bottom = box('b', 12, 30, 16, 30, text: '子');
      final merged = mergeCharBoxes(top, bottom, horizontal: false, rtl: false);
      expect(merged.id, 'a'); // 阅读序在前的框 id 保留
      expect(merged.x, 10);
      expect(merged.y, 0);
      expect(merged.w, 20); // 并集：max(10+20, 12+16) - min(10, 12)
      expect(merged.h, 60);
      expect(merged.text, '木子');
      expect(merged.marked, true); // 元数据沿用
      expect(merged.origText, ''); // 人工合并产物不再有识别基线
    });

    test('竖排行参数顺序无关：结果一致（内部按阅读轴归位）', () {
      final top = box('a', 10, 0, 20, 30, text: '木');
      final bottom = box('b', 12, 30, 16, 30, text: '子');
      final m1 = mergeCharBoxes(top, bottom, horizontal: false, rtl: false);
      final m2 = mergeCharBoxes(bottom, top, horizontal: false, rtl: false);
      expect(m2.id, 'a');
      expect(m2.text, m1.text);
      expect(m2.x, m1.x);
      expect(m2.y, m1.y);
      expect(m2.w, m1.w);
      expect(m2.h, m1.h);
    });

    test('横排 ltr：文字按 x 左→右拼接', () {
      final left = box('a', 0, 0, 20, 30, text: '日');
      final right = box('b', 20, 2, 20, 30, text: '月');
      final merged = mergeCharBoxes(left, right, horizontal: true, rtl: false);
      expect(merged.text, '日月');
      expect(merged.id, 'a');
      expect(merged.w, 40);
    });

    test('横排 rtl：文字按 x 右→左拼接', () {
      final left = box('a', 0, 0, 20, 30, text: '日');
      final right = box('b', 20, 2, 20, 30, text: '月');
      final merged = mergeCharBoxes(left, right, horizontal: true, rtl: true);
      expect(merged.text, '月日');
      expect(merged.id, 'b'); // rtl 时右边的框是阅读序第一
    });

    test('JSON 往返：origText 空不落盘、几何/文字保持', () {
      final top = box('a', 10, 0, 20, 30, text: '木');
      final bottom = box('b', 12, 30, 16, 30, text: '子');
      final merged = mergeCharBoxes(top, bottom, horizontal: false, rtl: false);
      final json = merged.toJson();
      expect(json.containsKey('orig_text'), isFalse);
      final back = CharBlock.fromJson(Map<String, dynamic>.from(json));
      expect(back.x, merged.x);
      expect(back.h, merged.h);
      expect(back.text, '木子');
    });
  });

  group('EditorShortcutSettings 快捷键配置', () {
    test('默认值：合并 M、删除 X', () {
      const s = EditorShortcutSettings();
      expect(s.mergeChars.keyId, LogicalKeyboardKey.keyM.keyId);
      expect(s.deleteChars.keyId, LogicalKeyboardKey.keyX.keyId);
      expect(s.mergeChars.label, 'M');
      expect(s.deleteChars.label, 'X');
    });

    test('JSON 往返：自定义按键保留 keyId 与 label', () {
      const s = EditorShortcutSettings(
        mergeChars: ShortcutKey(keyId: 0x71, label: 'Q'),
        deleteChars: ShortcutKey(keyId: 0x77, label: 'W'),
      );
      final back = EditorShortcutSettings.fromJson(s.toJson());
      expect(back.mergeChars.keyId, 0x71);
      expect(back.mergeChars.label, 'Q');
      expect(back.deleteChars.keyId, 0x77);
    });

    test('坏 JSON 回退默认', () {
      final back = EditorShortcutSettings.fromJson({
        'mergeChars': 'not-a-map',
        'deleteChars': null,
      });
      expect(back.mergeChars, ShortcutKey.defaultMerge);
      expect(back.deleteChars, ShortcutKey.defaultDelete);
    });

    test('冲突判定：改一个动作的键与另一动作相同即冲突，原键不冲突', () {
      const s = EditorShortcutSettings();
      // 给合并换到 X（删除的当前键）→ 冲突
      expect(s.conflictsWith(s.deleteChars, forAction: 'mergeChars'), isTrue);
      // 给合并换到 Q → 不冲突
      expect(
        s.conflictsWith(
          const ShortcutKey(keyId: 0x71, label: 'Q'),
          forAction: 'mergeChars',
        ),
        isFalse,
      );
      // 正在改的动作自身当前键不算冲突（录制同一键允许）
      expect(s.conflictsWith(s.mergeChars, forAction: 'mergeChars'), isFalse);
    });
  });
}
