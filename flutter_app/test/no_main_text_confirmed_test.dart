import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';

/// 「已确认无正文」（noMainTextConfirmed，主区快设对扉页/插图/空白页
/// 的"确认并下一页"）的序列化与回退测试：旧项目 JSON 无此键回退
/// false；确认落盘后重开不丢；false 不写键（旧文件零扰动）。
void main() {
  PageAnnotation baseAnn() => PageAnnotation(
    pageId: 'page_001',
    imagePath: 'page_001.png',
    mainRegions: [
      MainRegion(id: 'mr_h', x: 0, y: 0, w: 99, h: 20, label: 'header'),
    ],
  );

  test('旧 JSON 无 no_main_text_confirmed 键回退为 false', () {
    final legacy = baseAnn().toJson();
    expect(legacy.containsKey('no_main_text_confirmed'), isFalse);
    final restored = PageAnnotation.fromJson(legacy);
    expect(restored.noMainTextConfirmed, isFalse);
  });

  test('确认无正文序列化往返（含旧版只有 blocks 的分支）', () {
    final ann = baseAnn()..noMainTextConfirmed = true;
    expect(ann.toJson()['no_main_text_confirmed'], isTrue);
    final restored = PageAnnotation.fromJson(ann.toJson());
    expect(restored.noMainTextConfirmed, isTrue);

    // 旧版只有 blocks 的 fromJson 分支同样读到该键。
    final legacyShape = <String, dynamic>{
      'page_id': 'page_002',
      'image_path': 'page_002.png',
      'no_main_text_confirmed': true,
      'blocks': <dynamic>[],
    };
    expect(PageAnnotation.fromJson(legacyShape).noMainTextConfirmed, isTrue);
  });

  test('无正文确认只依赖页面标记，不影响既有字段', () {
    final ann = baseAnn()
      ..noMainTextConfirmed = true
      ..draftSaved = true;
    final restored = PageAnnotation.fromJson(ann.toJson());
    expect(restored.noMainTextConfirmed, isTrue);
    expect(restored.draftSaved, isTrue);
    expect(restored.reviewed, isFalse);
    // 页眉等非正文区不受影响。
    expect(restored.mainRegions, hasLength(1));
    expect(restored.mainRegions.single.label, 'header');
  });
}
