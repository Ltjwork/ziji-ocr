import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/services/book_cache.dart';
import 'package:gujichazi/services/python_service.dart';
import 'package:gujichazi/services/storage.dart';

/// 书目录级缓存测试：
/// - PageStateCache：指纹（mtime+size+图片路径）命中只 stat 不解析
///   （同尺寸不同内容的标注不再重读），指纹变化重新派生并回写；
/// - ClusterCache：store→lookup 往返、阈值/摘要变化即未命中、
///   digestForPages 对改字（几何不变）稳定、对几何变化敏感。
void main() {
  late Directory tmp;
  late Project project;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('book_cache_test');
    final imgDir = Directory('${tmp.path}/warped')..createSync();
    project = Project(
      id: 'cache_test',
      name: '缓存测试书',
      projectDir: tmp.path,
      imageFiles: [
        for (var i = 1; i <= 3; i++)
          '${imgDir.path}/page_${i.toString().padLeft(3, '0')}.png',
      ],
    );
    for (final f in project.imageFiles) {
      File(f).writeAsBytesSync(List.filled(16, 7));
    }
  });

  tearDown(() async {
    // 重试删除：测试触发的标注/账本钩子是 fire-and-forget，Windows 上
    // 偶发与删除枚举竞态（errno 2），临时目录由 OS 兜底清理。
    for (var i = 0; i < 3; i++) {
      try {
        await tmp.delete(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  PageAnnotation ann(String pageId, String imagePath,
      {bool reviewed = false, bool draft = false, bool boxes = false,
      String text = '天'}) {
    final line = LineBlock(
      id: 'l1',
      x: 0,
      y: 0,
      w: 100,
      h: 200,
      lineNo: 0,
      orientation: 'vertical',
      status: reviewed ? AnnotationStatus.confirmed : AnnotationStatus.proposed,
    );
    final char = CharBlock(
      id: 'b1',
      x: 10,
      y: 10,
      w: 40,
      h: 40,
      col: 0,
      order: 0,
      text: text,
      status: reviewed ? AnnotationStatus.confirmed : AnnotationStatus.proposed,
      confirmed: reviewed,
    );
    line.chars = [char];
    line.text = text;
    return PageAnnotation(
      pageId: pageId,
      imagePath: imagePath,
      reviewed: reviewed,
      draftSaved: draft,
      boxesReviewed: boxes,
      lines: [line],
      blocks: [char],
    );
  }

  group('PageStateCache', () {
    test('指纹未变只 stat 不解析（同尺寸不同内容不再重读）', () async {
      await ProjectStorage.saveAnnotation(
        project.projectDir,
        ann(project.pageIdAt(0), project.imageFiles[0], draft: true),
      );
      final first = await PageStateCache.load(project);
      expect(first.markers.draftPages, {0});
      expect(first.reviewedCount, 0);
      expect(File('${project.projectDir}/page_state_cache.json').existsSync(),
          isTrue);

      // 覆写成同字节长度的垃圾内容并保持 mtime/size：指纹命中，缓存
      // 读数原样返回（证明没有重新解析）。长度必须按 UTF-8 字节数算
      // （原文含中文时字符数 ≠ 字节数）；mtime 直接取缓存里记录的值
      // 并轮询确认 stat 已生效（Windows 元数据刷新偶发滞后，直接
      // set 完就读会时序 flaky）。
      final f = File(
          '${project.projectDir}/annotations/${project.pageIdAt(0)}.json');
      final original = await f.readAsString();
      final garbage = List.filled(utf8.encode(original).length, 'x').join();
      final cacheRaw = jsonDecode(
        await File('${project.projectDir}/page_state_cache.json')
            .readAsString(),
      ) as Map;
      final cachedMtime = ((cacheRaw['pages'] as Map)[project.pageIdAt(0)]
          as Map)['m'] as int;
      final target = DateTime.fromMillisecondsSinceEpoch(cachedMtime);
      await f.writeAsString(garbage);
      for (var i = 0; i < 5; i++) {
        await f.setLastModified(target);
        final stat = await f.stat();
        if (stat.modified.millisecondsSinceEpoch == cachedMtime) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      final second = await PageStateCache.load(project);
      expect(second.markers.draftPages, {0});
    });

    test('保存后指纹变化，状态与计数重算', () async {
      await ProjectStorage.saveAnnotation(
        project.projectDir,
        ann(project.pageIdAt(0), project.imageFiles[0]),
      );
      await ProjectStorage.saveAnnotation(
        project.projectDir,
        ann(project.pageIdAt(1), project.imageFiles[1]),
      );
      final before = await PageStateCache.load(project);
      expect(before.markers.savedPages, isEmpty);
      expect(before.countersByPage[1]!.charCls, 0);

      // 第 2 页确认并保存：reviewed + 计数更新。
      await ProjectStorage.saveAnnotation(
        project.projectDir,
        ann(project.pageIdAt(1), project.imageFiles[1], reviewed: true),
      );
      final after = await PageStateCache.load(project);
      expect(after.reviewedCount, 1);
      expect(after.markers.savedPages, {1});
      expect(after.countersByPage[1]!.charDet, 1);
      expect(after.countersByPage[1]!.charCls, 1);
      expect(after.countersByPage[1]!.charTexts, ['天']);
    });

    test('确认识别框（boxesReviewed）归入框已确认集合，优先于临时保存', () async {
      // 第 1 页确认过框、之后又有草稿写盘（draftSaved 同时为真）；
      // 第 2 页只是临时保存——两页必须落在不同集合里。
      await ProjectStorage.saveAnnotation(
        project.projectDir,
        ann(project.pageIdAt(0), project.imageFiles[0],
            draft: true, boxes: true),
      );
      await ProjectStorage.saveAnnotation(
        project.projectDir,
        ann(project.pageIdAt(1), project.imageFiles[1], draft: true),
      );
      final first = await PageStateCache.load(project);
      expect(first.markers.boxesReviewedPages, {0});
      expect(first.markers.draftPages, {1});

      // 缓存往返（指纹命中走 state 4 分支）分类保持不变。
      final second = await PageStateCache.load(project);
      expect(second.markers.boxesReviewedPages, {0});
      expect(second.markers.draftPages, {1});
    });

    test('换图片路径（同 pageId）指纹失效', () async {
      await ProjectStorage.saveAnnotation(
        project.projectDir,
        ann(project.pageIdAt(0), project.imageFiles[0], draft: true),
      );
      await PageStateCache.load(project);

      // 图片换成新路径（拆页/摆正后同 pageId 指向新图）：expectedImagePath
      // 错配丢弃口径下该页应回到无状态。
      final newImg = '${tmp.path}/warped/page_001_new.png';
      File(newImg).writeAsBytesSync(List.filled(16, 9));
      final moved = Project(
        id: project.id,
        name: project.name,
        projectDir: project.projectDir,
        imageFiles: [newImg, project.imageFiles[1], project.imageFiles[2]],
      );
      final result = await PageStateCache.load(moved);
      expect(result.markers.draftPages, isEmpty);
    });
  });

  group('ClusterCache', () {
    test('digest：改字（几何不变）稳定，几何变化敏感', () async {
      List<({String imagePath, List<CharBlock> blocks})> pagesOf(
              String text, int x) =>
          [
            (
              imagePath: project.imageFiles[0],
              blocks: [
                CharBlock(
                    id: 'b1', x: x, y: 10, w: 40, h: 40, col: 0, order: 0,
                    text: text),
              ],
            ),
          ];
      final a = await ClusterCache.digestForPages(pagesOf('天', 10));
      final b = await ClusterCache.digestForPages(pagesOf('地', 10));
      final c = await ClusterCache.digestForPages(pagesOf('天', 11));
      expect(a, b); // 文字不参与聚类 → 改字不失效
      expect(a, isNot(c)); // 几何变化 → 失效
    });

    test('store → lookup 往返；阈值或摘要变化未命中；条目数封顶', () async {
      final blocks = [
        CharBlock(id: 'b1', x: 1, y: 2, w: 3, h: 4, col: 0, order: 0),
      ];
      final digest = await ClusterCache.digestForPages([
        (imagePath: project.imageFiles[0], blocks: blocks),
      ]);
      final entry = ClusterCacheEntry(
        rangeStart: 0,
        rangeEnd: 2,
        threshold: 0.15,
        digest: digest,
        clusters: const [
          CharClusterGroup(blockIds: ['0|b1', '1|b1'], cohesion: 0.123),
        ],
        singletons: const ['2|b1'],
        skipped: const [],
        savedAt: DateTime.now(),
      );
      await ClusterCache.store(project, entry);

      final hit = await ClusterCache.lookup(project, 0, 2, 0.15, digest);
      expect(hit, isNotNull);
      expect(hit!.clusters.single.blockIds, ['0|b1', '1|b1']);
      expect(hit.clusters.single.cohesion, closeTo(0.123, 1e-9));
      expect(hit.singletons, ['2|b1']);
      expect(hit.toResult().clusters, isNotEmpty);

      // 摘要变化（几何改了）→ 未命中。
      final digest2 = await ClusterCache.digestForPages([
        (
          imagePath: project.imageFiles[0],
          blocks: [
            CharBlock(id: 'b1', x: 9, y: 2, w: 3, h: 4, col: 0, order: 0),
          ],
        ),
      ]);
      expect(await ClusterCache.lookup(project, 0, 2, 0.15, digest2), isNull);
      // 阈值变化 → 未命中。
      expect(await ClusterCache.lookup(project, 0, 2, 0.2, digest), isNull);

      // 同 key 覆盖 + 条目数封顶：连存 8 条不同 key 的条目，最早的
      // （含上面那条）被挤出 6 条上限。
      for (var i = 0; i < 8; i++) {
        await ClusterCache.store(
          project,
          ClusterCacheEntry(
            rangeStart: i,
            rangeEnd: i + 10,
            threshold: 0.1 + i * 0.01,
            digest: 'd$i',
            clusters: const [],
            singletons: const [],
            skipped: const [],
            savedAt: DateTime.now(),
          ),
        );
      }
      expect(await ClusterCache.lookup(project, 0, 2, 0.15, digest), isNull,
          reason: '8 条新条目把最早的条目挤出 6 条上限');
      expect(
        await ClusterCache.lookup(project, 7, 17, 0.1 + 7 * 0.01, 'd7'),
        isNotNull,
        reason: '最新的条目仍在',
      );
    });
  });
}
