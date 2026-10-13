// 文字汇总账本（char_stats）生命周期测试：
// - 确认保存（reviewed=true 经 saveAnnotation 咽喉点）→ 记账；
// - 重复确认/改字后确认 → 覆盖同页账目，不重复计数；
// - 页面重新识别（reviewed=false 覆盖写）/ 单页删除 → 撤账；
// - 全书重新识别（clearAllAnnotations）→ 该书全部撤账；
// - 删除整本书 → 账目保留（校对成果历史累计，需求约定）；
// - 跨页拆分等页面集合变化 → reconcileProject 按当前页列表对账；
// - 升级一次性存量回填 → reviewed 页入账、marker 防重跑。
// 注：CharStatsService 的字频缓存按"账本文件路径"键控，各测试使用
// 互不相同的项目目录名，避免静态缓存跨测试串味。
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/pages/char_stats_page.dart';
import 'package:gujichazi/services/char_stats.dart';
import 'package:gujichazi/services/storage.dart';
import 'package:path/path.dart' as p;

/// 组一个已确认页标注：字块文字来自 [texts]，全部置 confirmed/reviewed。
PageAnnotation _confirmedAnn(String pageId, String imagePath, List<String> texts) {
  final line = LineBlock(id: 'l1', x: 0, y: 0, w: 1000, h: 100, lineNo: 0);
  for (var i = 0; i < texts.length; i++) {
    line.chars.add(
      CharBlock(
        id: 'c$i',
        x: i * 20,
        y: 0,
        w: 20,
        h: 100,
        col: 0,
        order: i,
        text: texts[i],
      ),
    );
  }
  final ann = PageAnnotation(pageId: pageId, imagePath: imagePath)
    ..lines.add(line);
  ann.markAllConfirmed();
  ann.reviewed = true;
  ann.rebuildBlocks();
  return ann;
}

PageAnnotation _freshAnn(String pageId, String imagePath) =>
    PageAnnotation(pageId: pageId, imagePath: imagePath);

/// 等 unawaited 的账本钩子（saveAnnotation 尾部 fire-and-forget）跑完：
/// 真实文件 IO（含 Windows 上杀毒/索引器瞬时锁的重试退避）需要墙钟
/// 时间，零延迟循环只消化微任务不等 IO 完成。
Future<void> _drain() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('char_stats_test');
  });
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('countConfirmedChars 统计口径', () {
    test('只计确认字块：未确认、ignore、空文字不计，批注计入', () {
      final line = LineBlock(id: 'l1', x: 0, y: 0, w: 100, h: 10, lineNo: 0)
        ..chars = [
          CharBlock(id: 'a', x: 0, y: 0, w: 10, h: 10, col: 0, order: 0, text: '天')
            ..confirmed = true
            ..status = AnnotationStatus.confirmed,
          CharBlock(id: 'b', x: 10, y: 0, w: 10, h: 10, col: 0, order: 1, text: '地'),
          CharBlock(id: 'c', x: 20, y: 0, w: 10, h: 10, col: 0, order: 2, text: '玄')
            ..type = 'ignore'
            ..confirmed = true
            ..status = AnnotationStatus.confirmed,
          CharBlock(id: 'd', x: 30, y: 0, w: 10, h: 10, col: 0, order: 3, text: '')
            ..confirmed = true
            ..status = AnnotationStatus.confirmed,
          CharBlock(id: 'e', x: 40, y: 0, w: 10, h: 10, col: 0, order: 4, text: '黃')
            ..type = 'annotation'
            ..confirmed = true
            ..status = AnnotationStatus.confirmed,
          // 旧数据风格：仅 confirmed 标记、status 仍 proposed（fromJson
          // 会归一，这里直接模拟兼容分支）。
          CharBlock(id: 'f', x: 50, y: 0, w: 10, h: 10, col: 0, order: 5, text: '宇')
            ..confirmed = true,
        ];
      final ann = PageAnnotation(pageId: 'page_001', imagePath: 'x.png')
        ..lines.add(line);
      final counts = CharStatsService.countConfirmedChars(ann);
      expect(counts, {'天': 1, '黃': 1, '宇': 1});
    });

    test('多字 text 逐字符计数', () {
      final line = LineBlock(id: 'l1', x: 0, y: 0, w: 100, h: 10, lineNo: 0)
        ..chars = [
          CharBlock(id: 'a', x: 0, y: 0, w: 10, h: 10, col: 0, order: 0, text: '天地')
            ..confirmed = true
            ..status = AnnotationStatus.confirmed,
        ];
      final ann = PageAnnotation(pageId: 'page_001', imagePath: 'x.png')
        ..lines.add(line);
      expect(CharStatsService.countConfirmedChars(ann), {'天': 1, '地': 1});
    });
  });

  group('账本生命周期', () {
    test('确认保存（saveAnnotation 咽喉点）→ 记账并可汇总', () async {
      final projectDir = p.join(tmp.path, '1700000000001');
      await Directory(projectDir).create(recursive: true);
      final img = p.join(projectDir, 'page_001.png');

      await ProjectStorage.saveAnnotation(
        projectDir,
        _confirmedAnn('page_001', img, ['天', '地', '天']),
      );
      await _drain();

      final summary = await CharStatsService.summary(tmp.path);
      expect(summary.pageCount, 1);
      expect(summary.charCounts, {'天': 2, '地': 1});
      expect(summary.bookIds, {'1700000000001'});
    });

    test('重复确认 / 改字后确认 → 覆盖同页账目，不重复计数', () async {
      final projectDir = p.join(tmp.path, '1700000000002');
      await Directory(projectDir).create(recursive: true);
      final img = p.join(projectDir, 'page_001.png');

      await ProjectStorage.saveAnnotation(
        projectDir,
        _confirmedAnn('page_001', img, ['天', '地']),
      );
      await _drain();
      await ProjectStorage.saveAnnotation(
        projectDir,
        _confirmedAnn('page_001', img, ['天', '玄']),
      );
      await _drain();

      final summary = await CharStatsService.summary(tmp.path);
      expect(summary.pageCount, 1);
      expect(summary.charCounts, {'天': 1, '玄': 1});
    });

    test('页面重新识别（reviewed=false 覆盖写）→ 撤账', () async {
      final projectDir = p.join(tmp.path, '1700000000003');
      await Directory(projectDir).create(recursive: true);
      final img = p.join(projectDir, 'page_001.png');

      await ProjectStorage.saveAnnotation(
        projectDir,
        _confirmedAnn('page_001', img, ['天']),
      );
      await _drain();
      // 重新识别：ensurePageAnnotation(force) 用全新标注覆盖保存。
      await ProjectStorage.saveAnnotation(
        projectDir,
        _freshAnn('page_001', img),
      );
      await _drain();

      final summary = await CharStatsService.summary(tmp.path);
      expect(summary.pageCount, 0);
      expect(summary.charCounts, isEmpty);
    });

    test('删除单页（removePage）→ 撤账', () async {
      final projectDir = p.join(tmp.path, '1700000000004');
      await Directory(projectDir).create(recursive: true);
      final img1 = p.join(projectDir, 'page_001.png');
      final img2 = p.join(projectDir, 'page_002.png');

      await ProjectStorage.saveAnnotation(
        projectDir,
        _confirmedAnn('page_001', img1, ['天']),
      );
      await ProjectStorage.saveAnnotation(
        projectDir,
        _confirmedAnn('page_002', img2, ['地']),
      );
      await _drain();

      await CharStatsService.removePage(projectDir, 'page_001');
      final summary = await CharStatsService.summary(tmp.path);
      expect(summary.pageCount, 1);
      expect(summary.charCounts, {'地': 1});
    });

    test('确认保存后立刻删页：在途记账写不得把账目写回复活', () async {
      // 编辑器"确认并保存 → 删除该页"的最短间隔路径：saveAnnotation 尾部
      // 的记账任务是 fire-and-forget，removePage 必须等该条目的在途记账
      // 任务与其排队中的原子写落定再删——否则删除先执行，在途写的
      // rename 把刚删的账目复活，该页文字从此永久多计。
      final projectDir = p.join(tmp.path, '1700000000013');
      await Directory(projectDir).create(recursive: true);
      final img = p.join(projectDir, 'page_001.png');

      await ProjectStorage.saveAnnotation(
        projectDir,
        _confirmedAnn('page_001', img, ['天']),
      );
      // 不 _drain()，直接撤账（最大化与在途记账任务的竞争窗口）。
      await CharStatsService.removePage(projectDir, 'page_001');
      await ProjectStorage.drainPendingWrites();
      await _drain();

      final summary = await CharStatsService.summary(tmp.path);
      expect(summary.pageCount, 0, reason: '在途写把刚删的账目写回了');
      expect(summary.charCounts, isEmpty);
    });

    test('全书重新识别（clearAllAnnotations）→ 该书撤账，别书保留', () async {
      final dirA = p.join(tmp.path, '1700000000005');
      final dirB = p.join(tmp.path, '1700000000006');
      await Directory(dirA).create(recursive: true);
      await Directory(dirB).create(recursive: true);

      await ProjectStorage.saveAnnotation(
        dirA,
        _confirmedAnn('page_001', p.join(dirA, 'page_001.png'), ['天']),
      );
      await ProjectStorage.saveAnnotation(
        dirB,
        _confirmedAnn('page_001', p.join(dirB, 'page_001.png'), ['地']),
      );
      await _drain();

      await ProjectStorage.clearAllAnnotations(dirA);
      await _drain();

      final summary = await CharStatsService.summary(tmp.path);
      expect(summary.pageCount, 1);
      expect(summary.charCounts, {'地': 1});
      expect(summary.bookIds, {'1700000000006'});
    });

    test('删除整本书（项目目录删除）→ 账目保留', () async {
      final projectDir = p.join(tmp.path, '1700000000007');
      await Directory(projectDir).create(recursive: true);

      await ProjectStorage.saveAnnotation(
        projectDir,
        _confirmedAnn('page_001', p.join(projectDir, 'page_001.png'), ['天', '地']),
      );
      await _drain();
      await Directory(projectDir).delete(recursive: true);

      final summary = await CharStatsService.summary(tmp.path);
      expect(summary.pageCount, 1);
      expect(summary.charCounts, {'天': 1, '地': 1});
      expect(summary.bookIds, {'1700000000007'});
    });

    test('reconcileProject：页面集合外的账目撤、在册保留', () async {
      final projectDir = p.join(tmp.path, '1700000000008');
      await Directory(projectDir).create(recursive: true);

      // 拆分场景：源页 page_000（确认过、已入账）被两个半页 page_100/
      // page_101 取代（半页由 saveAnnotation 钩子入账）。
      await ProjectStorage.saveAnnotation(
        projectDir,
        _confirmedAnn('page_000', p.join(projectDir, 'page_000.png'), ['天']),
      );
      await ProjectStorage.saveAnnotation(
        projectDir,
        _confirmedAnn('page_100', p.join(projectDir, 'page_100.png'), ['地']),
      );
      await ProjectStorage.saveAnnotation(
        projectDir,
        _confirmedAnn('page_101', p.join(projectDir, 'page_101.png'), ['玄']),
      );
      await _drain();

      await CharStatsService.reconcileProject(projectDir, [
        p.join(projectDir, 'page_100.png'),
        p.join(projectDir, 'page_101.png'),
      ]);
      final summary = await CharStatsService.summary(tmp.path);
      expect(summary.charCounts, {'地': 1, '玄': 1});
      expect(summary.pageCount, 2);
    });
  });

  group('存量回填', () {
    test('reviewed 页入账，未确认页不入账；marker 防重跑', () async {
      final projectDir = p.join(tmp.path, '1700000000009');
      await Directory(projectDir).create(recursive: true);
      final img1 = p.join(projectDir, 'page_001.png');
      final img2 = p.join(projectDir, 'page_002.png');

      await ProjectStorage.saveAnnotation(
        projectDir,
        _confirmedAnn('page_001', img1, ['天']),
      );
      await ProjectStorage.saveAnnotation(
        projectDir,
        _freshAnn('page_002', img2),
      );
      await _drain();

      // 回填前清掉钩子已写的账目，验证 backfill 独立读盘入账。
      await CharStatsService.removeProject(projectDir);
      final project = Project(
        id: '1700000000009',
        name: '测试书',
        projectDir: projectDir,
        imageFiles: [img1, img2],
      );
      await CharStatsService.backfillOnce(tmp.path, [project]);

      var summary = await CharStatsService.summary(tmp.path);
      expect(summary.pageCount, 1);
      expect(summary.charCounts, {'天': 1});

      // marker 已写：删掉账目后再跑不会重新入账。
      await CharStatsService.removeProject(projectDir);
      await CharStatsService.backfillOnce(tmp.path, [project]);
      summary = await CharStatsService.summary(tmp.path);
      expect(summary.pageCount, 0);
    });
  });

  group('统计页 UI', () {
    testWidgets('挂载冒烟：列表渲染不崩（回归：Scrollbar 无挂载位置首帧退出）', (tester) async {
      final projectDir = p.join(tmp.path, '1700000000010');
      await tester.runAsync(() async {
        await Directory(projectDir).create(recursive: true);
        await CharStatsService.syncPage(
          projectDir,
          _confirmedAnn(
            'page_001',
            p.join(projectDir, 'page_001.png'),
            ['天', '地', '天'],
          ),
        );
      });

      await tester.pumpWidget(
        MaterialApp(
          home: CharStatsPage(
            dataRoot: tmp.path,
            bookNames: const {'1700000000010': '测试书'},
          ),
        ),
      );
      // 页面 initState 的账本汇总是真实文件 IO：testWidgets 的假时间不
      // 走真实 IO，用 runAsync 分批等待真实完成再泵帧（同
      // book_split_page_test 的模式）。
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump();
        if (find.text('天').evaluate().isNotEmpty) break;
      }
      await tester.pumpAndSettle();

      // 默认网格视图：字格渲染（天/地两格）。
      expect(find.text('天'), findsOneWidget);
      expect(find.text('地'), findsOneWidget);
      // 切到列表视图：行尾「N 次」文本出现。
      await tester.tap(find.byTooltip('切换为列表视图'));
      await tester.pump();
      expect(find.text('2 次'), findsOneWidget);
      expect(find.text('1 次'), findsOneWidget);
      // 搜索框直接过滤：输入拼音也命中。
      await tester.enterText(find.byType(TextField), 'di');
      await tester.pump();
      expect(find.text('地'), findsOneWidget);
      expect(find.text('天'), findsNothing);
    });
  });
}
