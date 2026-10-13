import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';

/// 特殊字标记（marked，墨迹归类时人工打标）的序列化与回退测试：
/// 旧项目 JSON 无此键时回退为 false；打标落盘后重开项目不丢失；
/// 标记独立于文字/确认状态，不影响既有字段。
void main() {
  CharBlock baseBlock() => CharBlock(
    id: 'p_b0001',
    x: 10,
    y: 20,
    w: 30,
    h: 40,
    col: 0,
    order: 1,
  );

  test('旧 JSON 无 marked 键回退为 false（未标记态）', () {
    final legacy = {
      'id': 'p_b0001',
      'x': 10,
      'y': 20,
      'w': 30,
      'h': 40,
      'col': 0,
      'order': 1,
      'text': '天',
    };
    final block = CharBlock.fromJson(legacy);
    expect(block.marked, isFalse);
  });

  test('标记序列化往返', () {
    final block = baseBlock().copyWith(text: '之', marked: true);
    expect(block.toJson()['marked'], isTrue);
    final restored = CharBlock.fromJson(block.toJson());
    expect(restored.marked, isTrue);
  });

  test('未标记不写入 JSON 键（旧文件零扰动）', () {
    final untouched = baseBlock();
    expect(untouched.toJson().containsKey('marked'), isFalse);
  });

  test('copyWith 只翻转标记，不动文字/确认/校验字段', () {
    final block = baseBlock().copyWith(
      text: '日',
      status: AnnotationStatus.needsReview,
      verifyLevel: 'suspect',
    );
    final marked = block.copyWith(marked: true);
    expect(marked.marked, isTrue);
    expect(marked.text, '日');
    expect(marked.status, AnnotationStatus.needsReview);
    expect(marked.verifyLevel, 'suspect');
    // 再翻回 false，与原块等价
    final unmarked = marked.copyWith(marked: false);
    expect(unmarked.marked, isFalse);
    expect(unmarked.toJson().containsKey('marked'), isFalse);
  });
}
