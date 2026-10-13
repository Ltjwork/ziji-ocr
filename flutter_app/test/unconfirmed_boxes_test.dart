import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/models/models.dart';
import 'package:gujichazi/services/page_state_markers.dart';

/// 缩略图紫框（"识别未确认"）判定口径：有识别框、但从未以任何方式
/// 确认（reviewed / boxesReviewed）或临时保存（draftSaved）过。
/// 附带页状态分类（玫红框=确认识别框 vs 橘黄=临时保存）的口径测试。
void main() {
  PageAnnotation buildWithBoxes() {
    final char = CharBlock(
      id: 'c1',
      x: 30,
      y: 40,
      w: 20,
      h: 10,
      col: 0,
      order: 0,
    );
    final line = LineBlock(
      id: 'l1',
      x: 30,
      y: 40,
      w: 20,
      h: 10,
      lineNo: 0,
      chars: [char],
    );
    return PageAnnotation(
      pageId: 'page_000',
      imagePath: 'fake.png',
      lines: [line],
      blocks: [char],
    );
  }

  test('批量识别完的页（无任何确认标记）= 有未确认识别框', () {
    final ann = buildWithBoxes();
    expect(ann.hasUnconfirmedBoxes, isTrue);
  });

  test('确认并保存（markAllConfirmed）后不算', () {
    final ann = buildWithBoxes();
    ann.markAllConfirmed();
    expect(ann.hasUnconfirmedBoxes, isFalse);
  });

  test('确认识别框（markBoxesConfirmed）后不算', () {
    final ann = buildWithBoxes();
    ann.markBoxesConfirmed();
    expect(ann.boxesReviewed, isTrue);
    expect(ann.hasUnconfirmedBoxes, isFalse);
  });

  test('临时保存过（draftSaved）不算——走橘黄框口径', () {
    final ann = buildWithBoxes();
    ann.draftSaved = true;
    expect(ann.hasUnconfirmedBoxes, isFalse);
  });

  test('页状态分类：确认识别框（玫红框）与临时保存（橘黄）分开', () {
    final boxesConfirmed = buildWithBoxes()..markBoxesConfirmed();
    final draftOnly = buildWithBoxes()..draftSaved = true;
    // 常见轨迹：确认过框之后又改了文字（草稿写盘）——仍算框已确认。
    final both = buildWithBoxes()
      ..markBoxesConfirmed()
      ..draftSaved = true;
    final markers = PageStateMarkers.fromAnnotations({
      0: boxesConfirmed,
      1: draftOnly,
      2: both,
    });
    expect(markers.boxesReviewedPages, {0, 2});
    expect(markers.draftPages, {1});
  });

  test('没有识别框的空标注不算', () {
    final ann = PageAnnotation(pageId: 'page_000', imagePath: 'fake.png');
    expect(ann.hasUnconfirmedBoxes, isFalse);
  });

  test('重置为未确认后恢复"有未确认识别框"', () {
    final ann = buildWithBoxes();
    ann.markAllConfirmed();
    ann.resetToProposed();
    expect(ann.hasUnconfirmedBoxes, isTrue);
  });

  test('只有行内空壳（无字）也不算有识别框', () {
    final ann = buildWithBoxes();
    ann.lines.first.chars.clear();
    ann.blocks.clear();
    expect(ann.hasUnconfirmedBoxes, isFalse);
  });

  test('确认识别框标记全部框类型几何（区/段/行/字）', () {
    final ann = buildFull();
    ann.markBoxesConfirmed();
    expect(ann.mainRegions.first.boxConfirmed, isTrue);
    expect(ann.paragraphs.first.boxConfirmed, isTrue);
    expect(ann.lines.first.boxConfirmed, isTrue);
    expect(ann.lines.first.chars.first.boxConfirmed, isTrue);
    expect(ann.blocks.first.boxConfirmed, isTrue);
    // 文字/候选不被连带确认
    expect(ann.lines.first.status, AnnotationStatus.proposed);
    expect(ann.lines.first.chars.first.status, AnnotationStatus.proposed);
  });

  test('确认并保存蕴含全部框几何确认', () {
    final ann = buildFull();
    ann.markAllConfirmed();
    expect(ann.mainRegions.first.boxConfirmed, isTrue);
    expect(ann.paragraphs.first.boxConfirmed, isTrue);
    expect(ann.lines.first.boxConfirmed, isTrue);
    expect(ann.lines.first.status, AnnotationStatus.confirmed);
  });

  test('重置为未确认清除全部框几何确认标记', () {
    final ann = buildFull();
    ann.markBoxesConfirmed();
    ann.resetToProposed();
    expect(ann.mainRegions.first.boxConfirmed, isFalse);
    expect(ann.paragraphs.first.boxConfirmed, isFalse);
    expect(ann.lines.first.boxConfirmed, isFalse);
    expect(ann.lines.first.chars.first.boxConfirmed, isFalse);
  });

  test('box_confirmed 随 JSON 往返保留', () {
    final ann = buildFull();
    ann.markBoxesConfirmed();
    final restored = PageAnnotation.fromJson(ann.toJson());
    expect(restored.mainRegions.first.boxConfirmed, isTrue);
    expect(restored.paragraphs.first.boxConfirmed, isTrue);
    expect(restored.lines.first.boxConfirmed, isTrue);
    expect(restored.lines.first.chars.first.boxConfirmed, isTrue);
    // 未确认时不写键，读回为 false
    final plain = PageAnnotation.fromJson(buildFull().toJson());
    expect(plain.mainRegions.first.boxConfirmed, isFalse);
    expect(plain.lines.first.boxConfirmed, isFalse);
  });
}

PageAnnotation buildFull() {
  final char = CharBlock(
    id: 'c1',
    x: 30,
    y: 40,
    w: 20,
    h: 10,
    col: 0,
    order: 0,
  );
  final line = LineBlock(
    id: 'l1',
    x: 30,
    y: 40,
    w: 20,
    h: 10,
    lineNo: 0,
    chars: [char],
  );
  return PageAnnotation(
    pageId: 'page_000',
    imagePath: 'fake.png',
    mainRegions: [MainRegion(id: 'mr_1', x: 0, y: 0, w: 100, h: 200)],
    paragraphs: [Paragraph(id: 'mp_1', x: 0, y: 0, w: 100, h: 80)],
    lines: [line],
    blocks: [char],
  );
}
