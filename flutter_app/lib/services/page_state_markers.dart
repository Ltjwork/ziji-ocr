import 'package:flutter/material.dart';

import '../models/models.dart';
import 'storage.dart';

/// 全书页状态标记：编辑器缩略图条与全书网格总览共用一套状态判定与
/// 边框色。持有的是可变集合——编辑器在保存/确认流程中就地增删，
/// 这里只提供加载与查询，不主动变更。
class PageStateMarkers {
  PageStateMarkers();

  /// 框已确认档（「确认识别框」过、文字未确认）的统一取色：边框与
  /// 三处图例共用，改色只动这一处。玫红与已确认的绿、临时保存的橘黄、
  /// 识别未确认的紫、当前页的蓝全部拉开色相。
  static final Color boxesReviewedColor = Colors.pink.shade600;

  /// 已确认并保存的页（绿框，isFullyConfirmed）。
  final Set<int> savedPages = <int>{};

  /// 「确认识别框」过但文字未完全确认的页（玫红框，boxesReviewed）：
  /// 框几何已固化计入检测训练，与"只是临时保存"（橘黄）区分开。
  /// 完全确认的页不在本集合（绿框优先）。
  final Set<int> boxesReviewedPages = <int>{};

  /// 临时保存过但尚未确认的页（橘黄框，draftSaved）。
  final Set<int> draftPages = <int>{};

  /// 有识别框但从未确认过的页（紫框，hasUnconfirmedBoxes）：批量识别
  /// 完没人动过的页落在这里，与"从未识别"的灰框区分开。
  final Set<int> boxedUnconfirmedPages = <int>{};

  /// 扫描全书标注文件计算三类状态页集合。逐页读 JSON（页数很多时
  /// 调用方应自行展示进度）；单页损坏按"无标注"处理。
  static Future<PageStateMarkers> load(Project project) async {
    final markers = PageStateMarkers();
    for (var i = 0; i < project.imageFiles.length; i++) {
      final pageId = project.pageIdAt(i);
      final ann = await ProjectStorage.loadAnnotation(
        project.projectDir,
        pageId,
        expectedImagePath: project.imageFiles[i],
      );
      if (ann == null) continue;
      if (ann.isFullyConfirmed) {
        markers.savedPages.add(i);
      } else if (ann.boxesReviewed) {
        markers.boxesReviewedPages.add(i);
      } else if (ann.draftSaved) {
        markers.draftPages.add(i);
      } else if (ann.hasUnconfirmedBoxes) {
        markers.boxedUnconfirmedPages.add(i);
      }
    }
    return markers;
  }

  /// 从已载入的标注直接计算（网格总览等已经读过全部 JSON 的调用方
  /// 用这个，避免重复扫盘）。分类规则与 [load] 完全一致。
  factory PageStateMarkers.fromAnnotations(
    Map<int, PageAnnotation> annotations,
  ) {
    final markers = PageStateMarkers();
    annotations.forEach((index, ann) {
      if (ann.isFullyConfirmed) {
        markers.savedPages.add(index);
      } else if (ann.boxesReviewed) {
        markers.boxesReviewedPages.add(index);
      } else if (ann.draftSaved) {
        markers.draftPages.add(index);
      } else if (ann.hasUnconfirmedBoxes) {
        markers.boxedUnconfirmedPages.add(index);
      }
    });
    return markers;
  }

  /// 是否处于任一"值得注意"的状态（缩略图边框加粗显示）。
  bool isMarked(int index) =>
      savedPages.contains(index) ||
      boxesReviewedPages.contains(index) ||
      draftPages.contains(index) ||
      boxedUnconfirmedPages.contains(index);

  /// 缩略图边框颜色（与编辑器图例一一对应）：蓝=当前页、绿=已确认、
  /// 玫红=确认识别框（文字未确认）、橘黄=临时保存、紫=有识别框未确认、
  /// 灰=无标注。框确认优先于临时保存：确认过框的页即使再改文字草稿，
  /// 也仍显示"框已确认"（剩余工作是文字校对）。
  Color borderColor(int index, {int? currentIndex}) {
    if (index == currentIndex) return Colors.blue;
    if (savedPages.contains(index)) return Colors.green.shade600;
    if (boxesReviewedPages.contains(index)) return boxesReviewedColor;
    if (draftPages.contains(index)) return Colors.orange.shade700;
    if (boxedUnconfirmedPages.contains(index)) return Colors.purple;
    return Colors.grey.shade300;
  }
}
