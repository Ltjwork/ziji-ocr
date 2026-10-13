import 'package:gujichazi/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 按页识别方向覆盖：旧格式兼容、序列化、settingsAt 合成。
void main() {
  group('PageDirectionOverride 解析', () {
    test('旧格式字符串（仅排版方向）兼容读取', () {
      final o = PageDirectionOverride.fromDynamic('horizontal');
      expect(o?.orientation, 'horizontal');
      expect(o?.horizontalDir, isNull);
      expect(o?.verticalDir, isNull);
      // 无法识别的字符串不建覆盖
      expect(PageDirectionOverride.fromDynamic('diagonal'), isNull);
    });

    test('新格式 map 解析，非法值忽略', () {
      final o = PageDirectionOverride.fromDynamic({
        'orientation': 'vertical',
        'horizontal_dir': 'rtl',
        'vertical_dir': 'bogus',
      });
      expect(o?.orientation, 'vertical');
      expect(o?.horizontalDir, 'rtl');
      expect(o?.verticalDir, isNull);
      // 全非法 = 空覆盖，不建
      expect(PageDirectionOverride.fromDynamic({'horizontal_dir': 'x'}), isNull);
    });

    test('序列化只写非空字段', () {
      final o = PageDirectionOverride(horizontalDir: 'rtl');
      expect(o.toJson(), {'horizontal_dir': 'rtl'});
      expect(o.isEmpty, isFalse);
      expect(PageDirectionOverride().isEmpty, isTrue);
    });
  });

  group('Project 按页方向覆盖', () {
    Project makeProject() => Project(
          id: 'p',
          name: 'book',
          projectDir: 'dir',
          imageFiles: ['page_000.png'],
          settings: ProjectSettings(
            orientation: 'vertical',
            horizontalDir: 'ltr',
            verticalDir: 'ttb',
          ),
        );

    test('未覆盖时跟随整书', () {
      final p = makeProject();
      expect(p.effectiveOrientationAt(0), 'vertical');
      expect(p.settingsAt(0).horizontalDir, 'ltr');
      expect(p.settingsAt(0).verticalDir, 'ttb');
    });

    test('覆盖排版与阅读方向后 settingsAt 合成生效，整书设置不动', () {
      final p = makeProject();
      p.pageDirectionOverrides['page_000'] = PageDirectionOverride(
        orientation: 'horizontal',
        horizontalDir: 'rtl',
      );
      expect(p.effectiveOrientationAt(0), 'horizontal');
      expect(p.effectiveHorizontalDirFor('page_000'), 'rtl');
      // 未覆盖项跟随整书
      expect(p.effectiveVerticalDirFor('page_000'), 'ttb');
      final s = p.settingsAt(0);
      expect(s.orientation, 'horizontal');
      expect(s.horizontalDir, 'rtl');
      expect(s.verticalDir, 'ttb');
      // 整书 settings 不被按页覆盖改动
      expect(p.settings.orientation, 'vertical');
      expect(p.settings.horizontalDir, 'ltr');
    });

    test('project.json 旧覆盖格式读入 + 新格式往返', () {
      final legacy = Project.fromJsonMap({
        'id': 'p',
        'name': 'b',
        'project_dir': 'd',
        'image_files': ['page_000.png'],
        'page_orientation_overrides': {'page_000': 'horizontal'},
      });
      expect(legacy.effectiveOrientationAt(0), 'horizontal');
      expect(legacy.effectiveHorizontalDirFor('page_000'), 'ltr');

      final modern = Project.fromJsonMap({
        'id': 'p',
        'name': 'b',
        'project_dir': 'd',
        'image_files': ['page_000.png'],
        'page_orientation_overrides': {
          'page_000': {'orientation': 'horizontal', 'horizontal_dir': 'rtl'},
        },
      });
      expect(modern.effectiveOrientationAt(0), 'horizontal');
      expect(modern.effectiveHorizontalDirFor('page_000'), 'rtl');
      expect(
        modern.toJson()['page_orientation_overrides'],
        {
          'page_000': {'orientation': 'horizontal', 'horizontal_dir': 'rtl'},
        },
      );
    });
  });
}
