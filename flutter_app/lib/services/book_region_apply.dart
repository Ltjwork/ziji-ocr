import 'dart:ui';

import '../models/models.dart';
import 'python_service.dart';

/// 全书正文区批量应用（全书叠加页入口），也承载编辑器区域级联的
/// 行合并规则——规则微妙（防"调好的框被级联重建洗掉"），只允许存在
/// 这一份实现，编辑器与批量应用都委托到这里。
///
/// 两种应用模式：
/// - [applyRegionOnly]：只替换主区几何，不重识别。快（全书秒级），
///   适合「先框后字」阶段只为 region_det 修框；行/段/字原样保留，
///   可能与新区边界不一致。
/// - [applyRegionWithCascade]：替换主区并按新区调后端重识别行/字，
///   合并规则与编辑器单页主区级联一致。
class BookRegionApply {
  /// 替换 [ann] 的**正文主区**（全部 main_text 区域）为单一矩形（全书
  /// 叠加"只改框"的入口，多主区页同样收敛为这一条）：语义与
  /// [applyRegionsOnly] 一致，见那里的说明。
  static void applyRegionOnly(PageAnnotation ann, Rect rect) =>
      applyRegionsOnly(ann, [rect]);

  /// 替换 [ann] 的**正文主区**为 [rects] 整组（快设每类多条的语义：未
  /// 裁开的书左右两页正文、多张插图各框一块）。按位置对应保留原主区的
  /// id/uid/label/status/boxConfirmed（训练身份与确认状态不因批量改框
  /// 丢失）：前 N 条就地替换几何，多余的原主区删除，不足时新建
  /// proposed 主区（无原主区时整组插到最前，否则接在最后一个原主区
  /// 后）。页眉/页脚/页码等其它版面区是独立成果，原样保留。不触发
  /// 任何重识别。返回是否有实际变化（几何数量或任一条几何不同）。
  ///
  /// **状态降级**：主区几何实际变化且页面处于「确认并保存」（reviewed
  /// /绿框）或「确认识别框」（boxesReviewed/玫红框）时，页面状态降回
  /// **只确认了主区**——这两个状态建立在旧主区的识别结果上，主区变了
  /// 旧成果的框几何不再成立。降级走 resetToProposed（几何/文字/候选全
  /// 保留，只回退生命周期状态），各原主区自身的 boxConfirmed 身份按位
  /// 继承下来（网格仍显示绿色"已确认"角标、仍可进拆分队列）。
  static bool applyRegionsOnly(PageAnnotation ann, List<Rect> rects) {
    final normalized = RegionLabel.mainText;
    final existing = <MainRegion>[];
    for (final r in ann.mainRegions) {
      if (RegionLabel.normalize(r.label) == normalized) existing.add(r);
    }
    // 几何变化按落盘的整数口径比较：画的框可能是小数坐标，取整后与
    // 现值相同视为未变（幂等保存不触发降级）。
    final next = [
      for (final r in rects)
        (
          r.left.round(),
          r.top.round(),
          r.width.round(),
          r.height.round(),
        ),
    ];
    var changed = existing.length != next.length;
    var geometryChanged = changed;
    for (var i = 0; i < existing.length && i < next.length; i++) {
      final e = existing[i];
      if (e.x != next[i].$1 ||
          e.y != next[i].$2 ||
          e.w != next[i].$3 ||
          e.h != next[i].$4) {
        changed = true;
        geometryChanged = true;
      }
    }
    if (geometryChanged && (ann.reviewed || ann.boxesReviewed)) {
      // 降级前快照各主区确认身份：resetToProposed 会清掉全部
      // boxConfirmed，存活的（前 next.length 条）要继承回来。
      final wasConfirmed = [for (final r in existing) r.boxConfirmed];
      ann.resetToProposed();
      for (var i = 0; i < existing.length; i++) {
        existing[i].boxConfirmed = wasConfirmed[i];
      }
    }
    _replaceLabelRegionSet(
      ann,
      normalized,
      existing,
      next
          .map(
            (t) => Rect.fromLTWH(
              t.$1.toDouble(),
              t.$2.toDouble(),
              t.$3.toDouble(),
              t.$4.toDouble(),
            ),
          )
          .toList(),
      newId: (i) => existing.isEmpty && i == 0
          // 历史缺省 id（models 旧标注重建同款），测试与旧数据约定。
          ? 'mr_001'
          : 'mr_${DateTime.now().millisecondsSinceEpoch}_$i',
      insertAtFrontWhenNone: true,
    );
    return changed;
  }

  /// 批量统一设置后的「退回未确认」（主区快设指定页叠加的配套语义）：
  /// 清掉 [ann] 全部**正文主区**的 boxConfirmed，返回清掉的条数。批量
  /// 写入的几何未经逐页核对，不得沿用位置继承来的旧确认（
  /// [applyRegionsOnly] 按位保留 boxConfirmed）直接进「按主区拆分」队
  /// 列——用户要求：设置后不自动确认，由用户分页查看后自己确认；页
  /// 眉/页脚等其它类别本次没动，确认状态原样保留。
  static int clearMainRegionConfirmed(PageAnnotation ann) {
    var cleared = 0;
    for (final r in ann.mainRegions) {
      if (RegionLabel.normalize(r.label) == RegionLabel.mainText &&
          r.boxConfirmed) {
        r.boxConfirmed = false;
        cleared++;
      }
    }
    return cleared;
  }

  /// 快设/批量保存的"每类多条"语义：把 [label] 类已有区域整组替换为
  /// [rects]——按位置对应保留同类区域的 id/uid/status/boxConfirmed
  /// （训练身份与确认状态不因改框丢失），多余的同类框删除，不足时新建
  /// proposed 框（该类原本没有框时：主区插到最前、其余类追加到尾）；
  /// 空列表删除该类全部。返回是否有实际变化（调用方用于"未改动不落盘"
  /// 与日志文案）。
  static bool replaceLabeledRegions(
    PageAnnotation ann,
    String label,
    List<Rect> rects,
  ) {
    final normalized = RegionLabel.normalize(label);
    final existing = <MainRegion>[];
    for (final r in ann.mainRegions) {
      if (RegionLabel.normalize(r.label) == normalized) existing.add(r);
    }
    return _replaceLabelRegionSet(
      ann,
      normalized,
      existing,
      rects,
      newId: (i) =>
          'mr_${DateTime.now().millisecondsSinceEpoch}_$normalized' '_$i',
      insertAtFrontWhenNone: false,
    );
  }

  /// 整组替换的共用本体（[applyRegionsOnly] 与 [replaceLabeledRegions]
  /// 委托）：[existing] 为该类现存区域（按列表顺序），[rects] 为新组。
  /// 前 N 条就地替换几何（保位保身份）；多余的原区域删除；不足的新建
  /// proposed 框——该类原本一条都没有时按 [insertAtFrontWhenNone] 决定
  /// 插到最前（主区约定）还是追加到尾（页眉/页脚等），否则接在该类
  /// 最后一条存活框之后。返回是否有实际变化。
  static bool _replaceLabelRegionSet(
    PageAnnotation ann,
    String normalized,
    List<MainRegion> existing,
    List<Rect> rects, {
    required String Function(int index) newId,
    required bool insertAtFrontWhenNone,
  }) {
    if (rects.isEmpty) {
      if (existing.isEmpty) return false;
      for (final r in existing) {
        ann.mainRegions.remove(r);
      }
      return true;
    }
    var changed = existing.length != rects.length;
    // 锚点 = 该类最后一条存活框的位置：必须在就地替换**之前**取——
    // 替换会把旧对象换成新对象（同位），事后再 indexOf 旧对象会得 -1。
    final survivorCount = rects.length < existing.length
        ? rects.length
        : existing.length;
    final anchorAt = existing.isEmpty
        ? -1
        : ann.mainRegions.indexOf(existing[survivorCount - 1]);
    for (var i = 0; i < rects.length && i < existing.length; i++) {
      final prev = existing[i];
      final rect = rects[i];
      if (prev.x != rect.left.round() ||
          prev.y != rect.top.round() ||
          prev.w != rect.width.round() ||
          prev.h != rect.height.round()) {
        changed = true;
      }
      ann.mainRegions[ann.mainRegions.indexOf(prev)] = MainRegion(
        id: prev.id,
        x: rect.left.round(),
        y: rect.top.round(),
        w: rect.width.round(),
        h: rect.height.round(),
        label: normalized,
        status: prev.status,
        boxConfirmed: prev.boxConfirmed,
        uid: prev.uid,
      );
    }
    // 多余的原区域删除（对象引用定位，不受前面替换影响；它们都在锚点
    // 之后，删除不移动锚点位置）。
    for (var i = rects.length; i < existing.length; i++) {
      ann.mainRegions.remove(existing[i]);
    }
    // 不足的补 proposed 新框：该类原本没有框时按约定插最前（主区）或
    // 追加到尾（页眉/页脚等），否则接在锚点（该类最后一条存活框）之后
    // 逐条顺排。
    for (var i = survivorCount; i < rects.length; i++) {
      final rect = rects[i];
      final next = MainRegion(
        id: newId(i),
        x: rect.left.round(),
        y: rect.top.round(),
        w: rect.width.round(),
        h: rect.height.round(),
        label: normalized,
        status: AnnotationStatus.proposed,
        boxConfirmed: false,
        uid: '',
      );
      if (existing.isEmpty) {
        if (insertAtFrontWhenNone) {
          ann.mainRegions.insert(i, next);
        } else {
          ann.mainRegions.add(next);
        }
      } else {
        ann.mainRegions.insert(
          (anchorAt + 1 + (i - survivorCount))
              .clamp(0, ann.mainRegions.length),
          next,
        );
      }
    }
    return changed;
  }

  /// 删除 [label] 类的全部区域（快设里"清除本类"的落盘动作）。
  /// 返回是否删除了任何框。
  static bool removeLabeledRegions(PageAnnotation ann, String label) {
    final normalized = RegionLabel.normalize(label);
    final before = ann.mainRegions.length;
    ann.mainRegions.removeWhere(
      (r) => RegionLabel.normalize(r.label) == normalized,
    );
    return ann.mainRegions.length != before;
  }

  /// 替换主区并按新区重识别：调 `/segment_lines_in_region` 分行+拆字
  /// +OCR，用 [spliceRegionLines] 合并（用户成果行保护、区外残留删
  /// 除、新行去重插入、行号重排），随后重建段落归属与扁平字列表。
  /// settings 应传入按页合并后的有效设置（Project.settingsAt）。
  static Future<RegionApplyStats> applyRegionWithCascade({
    required PageAnnotation ann,
    required String imagePath,
    required Rect rect,
    required ProjectSettings settings,
  }) async {
    applyRegionOnly(ann, rect);
    return cascadeRegion(
      ann: ann,
      imagePath: imagePath,
      rect: rect,
      settings: settings,
    );
  }

  /// 只对 [rect] 区域级联重识别（不改动任何区域几何）：拆分队列对一页
  /// 的多个正文主区逐块调用时，不能让每块把别的块洗掉——几何替换由
  /// 调用方统一决定，这里只做识别与合并。区外残留删除按"中心不在任何
  /// 正文宿主区内"判定（见 [spliceRegionLines]），多主区页各块的行互
  /// 相不受影响。
  static Future<RegionApplyStats> cascadeRegion({
    required PageAnnotation ann,
    required String imagePath,
    required Rect rect,
    required ProjectSettings settings,
  }) async {
    final newLines = await PythonService.segmentLinesInRegion(
      imagePath: imagePath,
      x: rect.left.toInt(),
      y: rect.top.toInt(),
      w: rect.width.toInt(),
      h: rect.height.toInt(),
      settings: settings,
      // 本页人工已确认版面区同款门控（与整页识别保持同一批次的
      // 一致性）：已确认页眉/页脚在字检测前被抹除。
      gateRegions: ann.confirmedGateRegions,
    );
    final stats = spliceRegionLines(
      ann,
      newLines: newLines,
      rect: rect,
      pruneOutsideRegions: true,
    );
    ann.rebuildParagraphs(
      orientation: settings.orientation,
      horizontalDir: settings.horizontalDir,
      verticalDir: settings.verticalDir,
    );
    ann.rebuildBlocks();
    return stats;
  }

  /// 对矩形区域内旧线框做替换式合并（编辑器主区/段级联与批量应用
  /// 共用的核心）：
  /// - 中心落在 [rect] 内的旧行 → 用重识别结果替换；
  /// - [pruneOutsideRegions] 时中心不在任何主区内的旧行 → 历史残留
  ///   删除（如已缩小的主区外余留）；
  /// - 用户成果行（[isUserPinnedLine]）在上述两种位置都保留原行；
  /// - 新行中心落在保留行框内则不插入（同一文字位置的重复行）；
  /// - 新行 reid 后原位插入并重排全页行号，段落的孤立 lineIds 同步
  ///   清理。
  static RegionApplyStats spliceRegionLines(
    PageAnnotation ann, {
    required List<LineBlock> newLines,
    required Rect rect,
    bool pruneOutsideRegions = false,
  }) {
    final oldLines = <LineBlock>[];
    final pinnedLines = <LineBlock>[];
    var removedOutside = 0;
    for (final l in ann.lines) {
      if (centerInRect(l.x, l.y, l.w, l.h, rect)) {
        // 用户成果行（手工调整过框几何、或字框已全部确认）：保留原行，
        // 不被重识别的"删旧插新"洗掉——识别器对同一位置的输出与原结果
        // 相同，重建等于把用户调整悄悄还原。
        if (isUserPinnedLine(l)) {
          pinnedLines.add(l);
          continue;
        }
        oldLines.add(l); // 新区域内的旧行 → 用重识别结果替换
        continue;
      }
      if (pruneOutsideRegions) {
        // 正文边界只认正文宿主类（main_text/margin_note）：页眉/页脚/页码
        // 区不保护其中的行——它们本来就该被级联清掉（与 Python 侧
        // _filter_layout 的 REGION_BODY_LABELS 同语义）。
        final inAnyRegion = ann.mainRegions.any(
          (r) =>
              RegionLabel.isBody(RegionLabel.normalize(r.label)) &&
              centerInRect(l.x, l.y, l.w, l.h, r.rect),
        );
        if (!inAnyRegion) {
          // 区域外残留同样保护用户成果：手工行不属于任何主区时保留
          // （用户特意把它移到区外的情形），只有机器识别残留才删除。
          if (isUserPinnedLine(l)) {
            pinnedLines.add(l);
            removedOutside++;
            continue;
          }
          oldLines.add(l); // 不属于任何主区的旧行 → 历史残留，删除
          removedOutside++;
        }
      }
    }
    final oldIds = oldLines.map((l) => l.id).toList();
    // 去重基准 = 本批替换后仍留在页面上的行（钉住的手工行 + 中心不在
    // 本区的机器行）：后端区域过滤按"行中心**或任一字中心**在区内"整行
    // 保留（seg_layout.filter_result_to_region），一页多主区逐块级联时，
    // 跨区域边界的行（中心在左区、字跨到右区）会被后一个区域的批次再
    // 带回一次——中心落在已保留行框内的新行即同一物理行，不插第二条
    // （单区域级联的边界列与编辑器行级联同样受益，替代原"只对钉住行
    // 去重"）。
    final oldSet = oldLines.toSet();
    final retained = [
      for (final l in ann.lines)
        if (!oldSet.contains(l)) l,
    ];
    final rebuilt = reidLines(
      newLines
          .where(
            (l) =>
                !retained.any((p) => centerInRect(l.x, l.y, l.w, l.h, p.rect)),
          )
          .toList(),
    );
    final insertAt = oldLines.isEmpty
        ? ann.lines.length
        : ann.lines.indexOf(oldLines.first);
    // 被替换的旧行可能属于其它段落；先从所有段落的成员列表中移除，
    // 避免新段识别后留下指向已删除行的孤立 lineIds。
    final removedIdSet = oldIds.toSet();
    for (final paragraph in ann.paragraphs) {
      paragraph.lineIds.removeWhere(removedIdSet.contains);
    }
    for (final l in oldLines) {
      ann.lines.remove(l);
    }
    ann.lines.insertAll(insertAt.clamp(0, ann.lines.length), rebuilt);
    renumberLines(ann);
    return RegionApplyStats(
      removedIds: oldIds,
      newLines: rebuilt,
      pinnedCount: pinnedLines.length,
      removedOutside: removedOutside,
    );
  }

  static bool centerInRect(int x, int y, int w, int h, Rect outer) =>
      outer.contains(Offset(x + w / 2, y + h / 2));

  /// 用户成果行：手工调整过行/字框几何（manual），或行内字框已全部
  /// 确认（「确认识别框」的成果）。区域/段级联重建时保留这些行。
  static bool isUserPinnedLine(LineBlock l) =>
      l.manual || (l.chars.isNotEmpty && l.chars.every((c) => c.boxConfirmed));

  /// 给后端返回的行/字分配本页唯一 ID（后端 ID 如 yolo_l_000 / p_b0001
  /// 会与旧数据冲突）。
  static List<LineBlock> reidLines(List<LineBlock> lines) {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final rebuilt = <LineBlock>[];
    for (var i = 0; i < lines.length; i++) {
      final src = lines[i];
      final lineId = 'l_${stamp}_${i.toString().padLeft(3, '0')}';
      for (var j = 0; j < src.chars.length; j++) {
        final c = src.chars[j];
        c.id = 'c_${stamp}_${i}_$j';
        c.lineId = lineId;
      }
      rebuilt.add(
        LineBlock(
          id: lineId,
          x: src.x,
          y: src.y,
          w: src.w,
          h: src.h,
          lineNo: src.lineNo,
          orientation: src.orientation,
          text: src.text,
          chars: src.chars,
        ),
      );
    }
    return rebuilt;
  }

  /// 全页行号重排：lineNo = 列表下标，char 的 col/order/lineId 同步。
  static void renumberLines(PageAnnotation ann) {
    for (var li = 0; li < ann.lines.length; li++) {
      final line = ann.lines[li];
      line.lineNo = li;
      for (var ci = 0; ci < line.chars.length; ci++) {
        final c = line.chars[ci];
        c.col = li;
        c.order = ci;
        c.lineId = line.id;
      }
    }
  }
}

/// 一次区域级联合并的统计（日志与批量进度展示用）。
class RegionApplyStats {
  final List<String> removedIds;
  final List<LineBlock> newLines;
  final int pinnedCount;
  final int removedOutside;

  const RegionApplyStats({
    required this.removedIds,
    required this.newLines,
    required this.pinnedCount,
    required this.removedOutside,
  });
}
