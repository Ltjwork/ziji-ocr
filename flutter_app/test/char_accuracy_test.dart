import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/services/char_stats.dart';

/// 正确识别率统计口径（+119）：CharBlock.origText 基线的序列化与
/// countAccuracy 的分母/修正判定。
void main() {
  CharBlock char(
    String id,
    String text, {
    String origText = '',
    bool confirmed = true,
    String type = 'main_text',
  }) => CharBlock(
    id: id,
    x: 0,
    y: 0,
    w: 20,
    h: 20,
    col: 0,
    order: 0,
    text: text,
    origText: origText,
    type: type,
    confirmed: confirmed,
  );

  test('origText 序列化：有基线即写（含未修改的），无基线不写', () {
    // 识别后没改过的字：orig_text 也要落盘——重载后才能区分"没改过"
    // 与"没有基线"（旧数据/人工新框）。
    final kept = char('c1', '大', origText: '大').toJson();
    expect(kept['orig_text'], '大');
    final restoredKept = CharBlock.fromJson(kept);
    expect(restoredKept.origText, '大');

    // 识别后改过的字：基线保留，当前文字另存。
    final fixed = char('c2', '太', origText: '大').toJson();
    expect(fixed['orig_text'], '大');
    expect(fixed['text'], '太');

    // 人工新画字框/旧数据：无基线不写键，重载后仍为空（不进统计）。
    final manual = char('c3', '手').toJson();
    expect(manual.containsKey('orig_text'), isFalse);
    expect(CharBlock.fromJson(manual).origText, isEmpty);

    // copyWith 不显式传 origText 时基线随行（编辑文字不改基线）。
    final edited = char('c4', '大', origText: '大').copyWith(text: '太');
    expect(edited.origText, '大');
    expect(edited.text, '太');
  });

  test('countAccuracy：分母只计识别产出且已确认的字，text!=orig 计修正', () {
    final ann = PageAnnotation(
      pageId: 'page_001',
      imagePath: 'page_001.png',
      lines: [
        LineBlock(
          id: 'l1',
          x: 0,
          y: 0,
          w: 100,
          h: 300,
          lineNo: 0,
          chars: [
            char('a', '大', origText: '大'), // 识别正确 → 分母，不修正
            char('b', '太', origText: '大'), // 识别后改过 → 分母 + 修正
            char('c', '手'), // 人工新框（无基线）→ 不计
            char('d', '古', origText: '古', confirmed: false), // 未确认 → 不计
            char('e', 'x', origText: 'x', type: 'ignore'), // ignore → 不计
            char('f', '今', origText: '令'), // 改过 → 分母 + 修正
          ],
        ),
      ],
    );
    final acc = CharStatsService.countAccuracy(ann);
    expect(acc.total, 3);
    expect(acc.fixed, 2);
  });

  test('BookAccuracy.rate：正确率 = (total-fixed)/total；无数据为 null', () {
    const empty = BookAccuracy(total: 0, fixed: 0);
    expect(empty.rate, isNull);
    const some = BookAccuracy(total: 200, fixed: 5);
    expect(some.rate, closeTo(0.975, 1e-9));
  });
}
