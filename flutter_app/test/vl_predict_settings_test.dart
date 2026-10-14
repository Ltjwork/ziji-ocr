import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';

void main() {
  test('vlPredict 请求体：默认全空（不传键）', () {
    final s = ProjectSettings();
    expect(s.vlPredict, isEmpty);
  });

  test('vlPredict：prompt/生成参数/像素数透传', () {
    final s = ProjectSettings(
      vlPromptLabel: 'spotting',
      vlRepetitionPenalty: 1.2,
      vlTemperature: 0.1,
      vlTopP: 0.9,
      vlMinPixels: 147384,
      vlMaxPixels: 1000000,
    );
    expect(s.vlPredict['prompt_label'], 'spotting');
    expect(s.vlPredict['repetition_penalty'], 1.2);
    expect(s.vlPredict['temperature'], 0.1);
    expect(s.vlPredict['top_p'], 0.9);
    expect(s.vlPredict['min_pixels'], 147384);
    expect(s.vlPredict['max_pixels'], 1000000);
    // 辅助内容全关 = 模型默认 → 不传清单键
    expect(s.vlPredict.containsKey('markdown_ignore_labels'), isFalse);
  });

  test('vlPredict：辅助内容开启 = 移出忽略清单', () {
    final s = ProjectSettings(vlParsePageNumber: true, vlParseFooter: true);
    final ignore = (s.vlPredict['markdown_ignore_labels'] as List)
        .cast<String>();
    expect(ignore, isNot(contains('number')));
    expect(ignore, isNot(contains('footer')));
    expect(ignore, contains('header'));
  });

  test('辅助内容全开 → 不传忽略清单（恢复解析）', () {
    final s = ProjectSettings(
      vlParseHeader: true,
      vlParseHeaderImage: true,
      vlParseFooter: true,
      vlParseFooterImage: true,
      vlParsePageNumber: true,
      vlParseFootnote: true,
      vlParseAsideText: true,
    );
    expect(s.vlPredict['markdown_ignore_labels'], isEmpty);
  });

  test('settings JSON 往返保留 VL predict 参数', () {
    final s = ProjectSettings(
      vlPromptLabel: 'table',
      vlTemperature: 0.3,
      vlMaxPixels: 800000,
      vlParseFootnote: true,
    );
    final restored = ProjectSettings.fromJson(s.toJson());
    expect(restored.vlPromptLabel, 'table');
    expect(restored.vlTemperature, 0.3);
    expect(restored.vlMaxPixels, 800000);
    expect(restored.vlParseFootnote, isTrue);
    // 非法 prompt 归一
    expect(
      ProjectSettings.fromJson({...s.toJson(), 'vl_prompt_label': 'xyz'})
          .vlPromptLabel,
      'ocr',
    );
  });
}
