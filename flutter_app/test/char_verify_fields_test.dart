import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';

/// 墨迹校验字段（verifyLevel/verifyScore）的序列化与回退测试：
/// 旧项目 JSON 无这两个键时必须回退为 null（未校验态），校验结果
/// 落盘后重开项目不丢失。
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

  test('旧 JSON 无校验字段回退为 null（未校验态）', () {
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
    expect(block.verifyLevel, isNull);
    expect(block.verifyScore, isNull);
  });

  test('校验字段序列化往返', () {
    final block = baseBlock()
        .copyWith(text: '昌', verifyLevel: 'mismatch', verifyScore: 0.4321);
    final restored = CharBlock.fromJson(block.toJson());
    expect(restored.verifyLevel, 'mismatch');
    expect(restored.verifyScore, closeTo(0.4321, 1e-9));
  });

  test('未校验（null）不写入 JSON 键，skipped 级别可持久化', () {
    final untouched = baseBlock();
    expect(untouched.toJson().containsKey('verify_level'), isFalse);
    expect(untouched.toJson().containsKey('verify_score'), isFalse);

    final skipped = baseBlock().copyWith(
      verifyLevel: 'skipped',
      verifyScore: null,
    );
    final restored = CharBlock.fromJson(skipped.toJson());
    expect(restored.verifyLevel, 'skipped');
    expect(restored.verifyScore, isNull);
  });

  test('copyWith 只更新校验字段，不动文字与状态', () {
    final block = baseBlock().copyWith(
      text: '日',
      status: AnnotationStatus.needsReview,
    );
    final updated = block.copyWith(verifyLevel: 'mismatch', verifyScore: 0.3);
    expect(updated.text, '日');
    expect(updated.status, AnnotationStatus.needsReview);
    expect(updated.verifyLevel, 'mismatch');
    // 原 block 不变（不可变更新语义）
    expect(block.verifyLevel, isNull);
  });
}
