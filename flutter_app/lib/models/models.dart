import 'dart:math' as math;
import 'dart:ui' show Color, Offset, Rect;

import 'package:path/path.dart' as p;

import 'table_block.dart';

/// Annotation lifecycle shared by automatic OCR, editors and future crowd
/// submissions.  Legacy values are normalized when reading older projects.
class AnnotationStatus {
  static const proposed = 'proposed';
  static const confirmed = 'confirmed';
  static const rejected = 'rejected';
  static const needsReview = 'needs_review';

  static String normalize(String? value, {bool confirmed = false}) {
    if (confirmed) return AnnotationStatus.confirmed;
    switch ((value ?? '').trim().toLowerCase()) {
      case proposed:
      case 'candidate':
      case 'unverified':
      case 'auto':
      case 'automatic':
        return proposed;
      case AnnotationStatus.confirmed:
      case 'reviewed':
      case 'accepted':
      case 'approved':
        return AnnotationStatus.confirmed;
      case rejected:
      case 'invalid':
      case 'ignored':
      case 'ignore':
        return rejected;
      default:
        return needsReview;
    }
  }
}

class ProjectSettings {
  String layoutMode; // 'main_text_only' | 'all_text'
  String orientation; // 'horizontal' | 'vertical'
  String horizontalDir; // 'ltr' | 'rtl'
  String verticalDir; // 'ttb' | 'btt'
  String engine; // 识别引擎：'kraken'（默认）| 'paddle'（PaddleOCR）
  String paddleModel; // paddle 引擎的识别模型（PP-OCRv6_*_rec），kraken 时忽略

  ProjectSettings({
    this.layoutMode = 'all_text',
    this.orientation = 'vertical',
    this.horizontalDir = 'ltr',
    this.verticalDir = 'ttb',
    this.engine = 'kraken',
    this.paddleModel = 'PP-OCRv6_small_rec',
  });

  factory ProjectSettings.fromJson(Map<String, dynamic>? j) {
    if (j == null) {
      return ProjectSettings();
    }
    // 未知引擎值一律归一为 kraken（默认引擎）；历史数据的 'paddle' 是
    // 旧版单引擎时代写入的占位值，但语义相同（选 PaddleOCR），保留。
    final engine = (j['engine'] as String?) == 'paddle' ? 'paddle' : 'kraken';
    return ProjectSettings(
      layoutMode: j['layout_mode'] as String? ?? 'all_text',
      orientation: j['orientation'] as String? ?? 'vertical',
      horizontalDir: j['horizontal_dir'] as String? ?? 'ltr',
      verticalDir: j['vertical_dir'] as String? ?? 'ttb',
      engine: engine,
      paddleModel: j['paddle_model'] as String? ?? 'PP-OCRv6_small_rec',
    );
  }

  Map<String, dynamic> toJson() => {
    'layout_mode': layoutMode,
    'orientation': orientation,
    'horizontal_dir': horizontalDir,
    'vertical_dir': verticalDir,
    'engine': engine,
    'paddle_model': paddleModel,
  };

  ProjectSettings copyWith({
    String? layoutMode,
    String? orientation,
    String? horizontalDir,
    String? verticalDir,
    String? engine,
    String? paddleModel,
  }) => ProjectSettings(
    layoutMode: layoutMode ?? this.layoutMode,
    orientation: orientation ?? this.orientation,
    horizontalDir: horizontalDir ?? this.horizontalDir,
    verticalDir: verticalDir ?? this.verticalDir,
    engine: engine ?? this.engine,
    paddleModel: paddleModel ?? this.paddleModel,
  );
}

class BookMetadata {
  String title;
  String? author;
  String? edition;
  String? volume;
  String? source;

  BookMetadata({
    required this.title,
    this.author,
    this.edition,
    this.volume,
    this.source,
  });

  factory BookMetadata.fromJson(
    Map<String, dynamic>? j, {
    String fallbackTitle = '',
  }) {
    return BookMetadata(
      title: (j?['title'] as String?)?.trim().isNotEmpty == true
          ? (j!['title'] as String).trim()
          : fallbackTitle,
      author: j?['author'] as String?,
      edition: j?['edition'] as String?,
      volume: j?['volume'] as String?,
      source: j?['source'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'title': title,
    if (author?.trim().isNotEmpty == true) 'author': author!.trim(),
    if (edition?.trim().isNotEmpty == true) 'edition': edition!.trim(),
    if (volume?.trim().isNotEmpty == true) 'volume': volume!.trim(),
    if (source?.trim().isNotEmpty == true) 'source': source!.trim(),
  };
}

class CharCandidate {
  final String text;
  final double score;

  /// 该候选来自 AI 整行/单字辅助（编辑器候选条显示紫色角标）；OCR
  /// 候选缺省 false。旧标注文件无此字段时按 false 读回。
  final bool ai;

  const CharCandidate({required this.text, required this.score, this.ai = false});

  factory CharCandidate.fromJson(Map<String, dynamic> j) => CharCandidate(
    text: j['text']?.toString() ?? '',
    score: (j['score'] as num?)?.toDouble() ?? 0,
    ai: j['ai'] == true,
  );

  Map<String, dynamic> toJson() =>
      {'text': text, 'score': score, if (ai) 'ai': true};
}

/// 主区/段落/行/字的公共可变矩形接口：clampAllToImage 就地钳制用。
abstract interface class _RectBox {
  abstract int x;
  abstract int y;
  abstract int w;
  abstract int h;
}

class CharBlock implements _RectBox {
  String id;
  @override
  int x, y, w, h;
  int col, order;
  String type; // main_text | annotation | ignore
  bool confirmed;

  /// 只确认了字框几何、文字候选仍待确认（「确认识别框」）：检测训练
  /// 可读此框，分类训练仍要求完全确认。完全确认（confirmed）蕴含它。
  bool boxConfirmed;
  String text;
  String source;

  /// 识别产出时的原始 OCR 文字（正确识别率统计基线）：识别结果解析时
  /// 记录，此后任何人工/AI 改写都不碰它；text != origText 即"识别后被
  /// 修改过"。空 = 非识别产出（人工新画字框/历史旧数据）——不参与
  /// 正确率统计。落盘：非空即写（即使等于 text——重载后才能区分
  /// "没改过"与"没有基线"）。
  String origText;
  String lineId; // 所属行，旧数据可能为空
  List<CharCandidate> candidates;
  String status; // proposed | confirmed | rejected | needs_review
  String uid;

  /// 两路识别（整行序列 ↔ 单字框内）的逐字合作状态：
  /// both=一致 / conflict=分歧 / seq=仅整行 / box=仅单字 /
  /// box_multi=单字框读出多字 / none=两路皆空；旧数据为 null。
  String? agree;

  /// 识别置信度（0~1，两路融合后落字的置信度）；旧数据为 null。
  double? conf;

  /// 墨迹校验等级（后端 /verify_char* 的 level）：
  /// ok=通过 / suspect=存疑 / mismatch=不匹配 / skipped=未校验；
  /// null=从未校验（旧数据）。mismatch/suspect 时文字标红并转待复核。
  String? verifyLevel;

  /// 墨迹校验综合分（0~1，拓扑+特征点位置+骨架形状三层加权）；
  /// skipped/null 时无意义。
  double? verifyScore;

  /// AI 整行裁决留下的可追溯建议；旧标注缺省为空。
  String? aiText;
  double? aiConfidence;
  String? aiReason;
  bool aiUsed;

  /// AI 三步分析判断的切分问题（char_clipped / char_merged /
  /// char_extra_ink）；null = AI 认为裁切无问题或从未分析。只作标记
  /// 提示，不自动改框；用户调整字框或重新识别时清除。
  String? aiBoxIssue;

  /// 切分问题的一句话说明（AI note）；aiBoxIssue 为 null 时无意义。
  String? aiBoxNote;

  /// 特殊字标记（墨迹归类时人工打标）：该字可能裁分有问题或暂时
  /// 无法识别，先跳过、等全书识别完成后统一校对。独立于确认状态
  /// （status）——标记/取消标记不改变确认与训练数据口径。
  bool marked;

  CharBlock({
    required this.id,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.col,
    required this.order,
    this.type = 'main_text',
    this.confirmed = false,
    this.boxConfirmed = false,
    this.text = '',
    this.source = '',
    this.origText = '',
    this.lineId = '',
    List<CharCandidate>? candidates,
    this.status = AnnotationStatus.proposed,
    this.uid = '',
    this.agree,
    this.conf,
    this.verifyLevel,
    this.verifyScore,
    this.aiText,
    this.aiConfidence,
    this.aiReason,
    this.aiUsed = false,
    this.aiBoxIssue,
    this.aiBoxNote,
    this.marked = false,
  }) : candidates = candidates ?? [];

  factory CharBlock.fromJson(Map<String, dynamic> j) => CharBlock(
    id: j['id'],
    x: j['x'],
    y: j['y'],
    w: j['w'],
    h: j['h'],
    col: j['col'] ?? 0,
    order: j['order'] ?? 0,
    type: j['type'] ?? 'main_text',
    confirmed: j['confirmed'] ?? false,
    boxConfirmed: j['confirmed'] == true || j['box_confirmed'] == true,
    text: j['text'] ?? '',
    source: j['source'] ?? '',
    origText: j['orig_text'] as String? ?? '',
    lineId: j['line_id'] ?? '',
    candidates:
        (j['candidates'] as List?)
            ?.whereType<Map>()
            .map((e) => CharCandidate.fromJson(Map<String, dynamic>.from(e)))
            .toList() ??
        // 可增长空列表（不能用 const []）：AI 辅助写回会往里追加候选，
        // const 列表原地 add 会抛 "Cannot add to an unmodifiable list"。
        <CharCandidate>[],
    status: AnnotationStatus.normalize(
      j['status'] as String?,
      confirmed: j['confirmed'] == true,
    ),
    uid: j['uid'] as String? ?? '',
    agree: j['agree'] as String?,
    conf: (j['conf'] as num?)?.toDouble(),
    verifyLevel: j['verify_level'] as String?,
    verifyScore: (j['verify_score'] as num?)?.toDouble(),
    aiText: j['ai_text'] as String?,
    aiConfidence: (j['ai_confidence'] as num?)?.toDouble(),
    aiReason: j['ai_reason'] as String?,
    aiUsed: j['ai_used'] == true,
    aiBoxIssue: j['ai_box_issue'] as String?,
    aiBoxNote: j['ai_box_note'] as String?,
    marked: j['marked'] == true,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'x': x,
    'y': y,
    'w': w,
    'h': h,
    'col': col,
    'order': order,
    'type': type,
    'confirmed': confirmed || status == AnnotationStatus.confirmed,
    if (boxConfirmed) 'box_confirmed': true,
    'text': text,
    'source': source,
    if (origText.isNotEmpty) 'orig_text': origText,
    if (candidates.isNotEmpty)
      'candidates': candidates.map((e) => e.toJson()).toList(),
    'status': status,
    if (uid.isNotEmpty) 'uid': uid,
    if (lineId.isNotEmpty) 'line_id': lineId,
    if (agree != null && agree!.isNotEmpty) 'agree': agree,
    if (conf != null) 'conf': conf,
    if (verifyLevel != null && verifyLevel!.isNotEmpty)
      'verify_level': verifyLevel,
    if (verifyScore != null) 'verify_score': verifyScore,
    if (aiText != null && aiText!.isNotEmpty) 'ai_text': aiText,
    if (aiConfidence != null) 'ai_confidence': aiConfidence,
    if (aiReason != null && aiReason!.isNotEmpty) 'ai_reason': aiReason,
    if (aiUsed) 'ai_used': true,
    if (aiBoxIssue != null && aiBoxIssue!.isNotEmpty) 'ai_box_issue': aiBoxIssue,
    if (aiBoxNote != null && aiBoxNote!.isNotEmpty) 'ai_box_note': aiBoxNote,
    if (marked) 'marked': true,
  };

  CharBlock copyWith({
    String? id,
    int? x,
    int? y,
    int? w,
    int? h,
    int? col,
    int? order,
    String? type,
    bool? confirmed,
    bool? boxConfirmed,
    String? text,
    String? source,
    String? origText,
    String? lineId,
    List<CharCandidate>? candidates,
    String? status,
    String? uid,
    String? agree,
    double? conf,
    String? verifyLevel,
    double? verifyScore,
    String? aiText,
    double? aiConfidence,
    String? aiReason,
    bool? aiUsed,
    String? aiBoxIssue,
    String? aiBoxNote,
    bool? marked,
  }) => CharBlock(
    id: id ?? this.id,
    x: x ?? this.x,
    y: y ?? this.y,
    w: w ?? this.w,
    h: h ?? this.h,
    col: col ?? this.col,
    order: order ?? this.order,
    type: type ?? this.type,
    confirmed: confirmed ?? this.confirmed,
    boxConfirmed: boxConfirmed ?? this.boxConfirmed,
    text: text ?? this.text,
    source: source ?? this.source,
    origText: origText ?? this.origText,
    lineId: lineId ?? this.lineId,
    candidates: candidates ?? this.candidates,
    status: status ?? this.status,
    uid: uid ?? this.uid,
    agree: agree ?? this.agree,
    conf: conf ?? this.conf,
    verifyLevel: verifyLevel ?? this.verifyLevel,
    verifyScore: verifyScore ?? this.verifyScore,
    aiText: aiText ?? this.aiText,
    aiConfidence: aiConfidence ?? this.aiConfidence,
    aiReason: aiReason ?? this.aiReason,
    aiUsed: aiUsed ?? this.aiUsed,
    aiBoxIssue: aiBoxIssue ?? this.aiBoxIssue,
    aiBoxNote: aiBoxNote ?? this.aiBoxNote,
    marked: marked ?? this.marked,
  );
}

class LineBlock implements _RectBox {
  final String id;
  @override
  int x, y, w, h;
  int lineNo;
  String orientation; // 'horizontal' | 'vertical'
  String text;
  List<CharBlock> chars;
  int readingOrder; // 导出时重排后的全局阅读顺序索引，-1 表示未计算
  String paragraphId; // 所属自然段，空表示未归属
  String status;

  /// 只确认了本行框几何（「确认识别框」）：检测训练（line_det）读这个
  /// 标记；完全确认（「确认并保存」）蕴含置位。行内文字的 Kraken 导出、
  /// char_cls 门槛不受影响——那些仍要求行 status 完全确认。
  bool boxConfirmed;
  String uid;

  /// 用户手工调整过本行框（或行内字框）几何 → 区域/段级联重识别时
  /// 保留本行，不被"删旧插新"重建洗掉（识别器输出与原结果相同，
  /// 表现为"调好的框切页后回到原样"）。
  bool manual;

  /// 后端版面级双列拆分元数据。
  String layoutRole; // body | annotation
  String columnGroup;
  String parentLineId;
  double layoutConfidence;

  LineBlock({
    required this.id,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.lineNo,
    this.orientation = 'vertical',
    this.text = '',
    List<CharBlock>? chars,
    this.readingOrder = -1,
    this.paragraphId = '',
    this.status = AnnotationStatus.proposed,
    this.boxConfirmed = false,
    this.uid = '',
    this.manual = false,
    this.layoutRole = 'body',
    this.columnGroup = '',
    this.parentLineId = '',
    this.layoutConfidence = 0,
  }) : chars = chars ?? [];

  factory LineBlock.fromJson(Map<String, dynamic> j) {
    final rawChars = (j['chars'] as List?) ?? const [];
    final line = LineBlock(
      id: j['id'] as String,
      x: j['x'] as int,
      y: j['y'] as int,
      w: j['w'] as int,
      h: j['h'] as int,
      lineNo: j['line_no'] as int? ?? 0,
      orientation: j['orientation'] as String? ?? 'vertical',
      text: j['text'] as String? ?? '',
      readingOrder: (j['reading_order'] as num?)?.toInt() ?? -1,
      paragraphId: j['paragraph_id'] as String? ?? '',
      status: AnnotationStatus.normalize(
        j['status'] as String?,
        confirmed: j['confirmed'] == true,
      ),
      boxConfirmed: j['box_confirmed'] == true,
      uid: j['uid'] as String? ?? '',
      manual: j['manual'] == true,
      layoutRole: j['layout_role'] as String? ?? 'body',
      columnGroup: j['column_group'] as String? ?? '',
      parentLineId: j['parent_line_id'] as String? ?? '',
      layoutConfidence: (j['layout_confidence'] as num?)?.toDouble() ?? 0,
    );
    for (final c in rawChars) {
      final block = CharBlock.fromJson(c as Map<String, dynamic>);
      block.lineId = line.id;
      line.chars.add(block);
    }
    return line;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'x': x,
    'y': y,
    'w': w,
    'h': h,
    'line_no': lineNo,
    'orientation': orientation,
    'text': text,
    'chars': chars.map((c) => c.toJson()).toList(),
    'reading_order': readingOrder,
    'paragraph_id': paragraphId,
    'status': status,
    if (boxConfirmed) 'box_confirmed': true,
    if (uid.isNotEmpty) 'uid': uid,
    if (manual) 'manual': true,
    if (layoutRole != 'body') 'layout_role': layoutRole,
    if (columnGroup.isNotEmpty) 'column_group': columnGroup,
    if (parentLineId.isNotEmpty) 'parent_line_id': parentLineId,
    if (layoutConfidence > 0) 'layout_confidence': layoutConfidence,
  };

  Rect get rect =>
      Rect.fromLTWH(x.toDouble(), y.toDouble(), w.toDouble(), h.toDouble());

  /// 仅复制几何字段（x/y/w/h/lineNo），其余属性保持引用不变
  LineBlock copyWith({int? x, int? y, int? w, int? h, int? lineNo}) =>
      LineBlock(
        id: id,
        x: x ?? this.x,
        y: y ?? this.y,
        w: w ?? this.w,
        h: h ?? this.h,
        lineNo: lineNo ?? this.lineNo,
        orientation: orientation,
        text: text,
        chars: chars,
        readingOrder: readingOrder,
        paragraphId: paragraphId,
        status: status,
        boxConfirmed: boxConfirmed,
        uid: uid,
        manual: manual,
      );
}

/// region_det 多类词表（跨语言协议：与 python_service/train_data.py 的
/// LAYER_INFO['region_det']['names'] 同序——main_text 恒为 id=0、新类只追加
/// 不重排；重排会让旧标注/旧模型的类别 id 静默错标）。
class RegionLabel {
  static const mainText = 'main_text';
  static const header = 'header';
  static const footer = 'footer';
  static const pageNumber = 'page_number';
  static const marginNote = 'margin_note';
  static const figure = 'figure';
  static const table = 'table';

  /// 词表顺序 = 训练类别 id 顺序（YoloExporter region 层按此映射 classId）。
  /// figure/table（+83 表格识别）暂无训练数据、旧模型不产出，人工确认
  /// 的框会进入 region_det 训练集，积累够了即可训出自动检测。
  static const all = <String>[
    mainText,
    header,
    footer,
    pageNumber,
    marginNote,
    figure,
    table,
  ];

  /// 词表外/缺省一律归 main_text（与 Python 侧 name_index 缺省同口径，
  /// 旧标注没有 label 字段时行为不变）。
  static String normalize(String? label) =>
      all.contains(label) ? label! : mainText;

  static String displayName(String label) => switch (label) {
        mainText => '正文',
        header => '页眉',
        footer => '页脚',
        pageNumber => '页码',
        marginNote => '眉批',
        figure => '图片',
        table => '表格',
        _ => '正文',
      };

  /// 编辑器配色（dart:ui Color，数据模型不依赖 Material；正文沿用旧主区
  /// deepPurple，眉批/段注避开 cyan/teal）。
  static Color color(String label) => switch (label) {
        mainText => const Color(0xFF673AB7),
        header => const Color(0xFF0097A7),
        footer => const Color(0xFF78909C),
        pageNumber => const Color(0xFF2E7D32),
        marginNote => const Color(0xFF9E7C0C),
        figure => const Color(0xFF6D4C41),
        table => const Color(0xFFAD1457),
        _ => const Color(0xFF673AB7),
      };

  /// 正文宿主类：段落认领/行修剪把这类区当正文边界（眉批内容有价值，
  /// 保留并按夹注打标；与 Python 侧 REGION_BODY_LABELS 同义）。
  static bool isBody(String label) =>
      label == mainText || label == marginNote;

  /// 排除类：不作为正文边界（与 Python 侧 REGION_EXCLUDED_LABELS 同义；
  /// 图/表区在后端字检测前被抹底色，格线/插图不再被误切成字）。
  static bool isExcluded(String label) =>
      label == header ||
      label == footer ||
      label == pageNumber ||
      label == figure ||
      label == table;
}

class MainRegion implements _RectBox {
  final String id;
  @override
  int x, y, w, h;
  String label; // 默认 'main_text'，多栏页面可自定义
  String status;

  /// 只确认了本框几何（「确认识别框」）：检测训练（region_det）读这个
  /// 标记；完全确认（「确认并保存」）蕴含置位。文字类门槛不受影响。
  bool boxConfirmed;
  String uid;

  MainRegion({
    required this.id,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    this.label = 'main_text',
    this.status = AnnotationStatus.proposed,
    this.boxConfirmed = false,
    this.uid = '',
  });

  Rect get rect =>
      Rect.fromLTWH(x.toDouble(), y.toDouble(), w.toDouble(), h.toDouble());

  factory MainRegion.fromJson(Map<String, dynamic> j) => MainRegion(
    id: j['id'] as String,
    x: j['x'] as int,
    y: j['y'] as int,
    w: j['w'] as int,
    h: j['h'] as int,
    label: j['label'] as String? ?? 'main_text',
    status: AnnotationStatus.normalize(
      j['status'] as String?,
      confirmed: j['confirmed'] == true,
    ),
    boxConfirmed: j['box_confirmed'] == true,
    uid: j['uid'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'x': x,
    'y': y,
    'w': w,
    'h': h,
    'label': label,
    'status': status,
    if (boxConfirmed) 'box_confirmed': true,
    if (uid.isNotEmpty) 'uid': uid,
  };
}

class Paragraph implements _RectBox {
  final String id;
  @override
  int x, y, w, h;
  String mainRegionId; // 所属主内容区
  List<String> lineIds; // 段内行 ID
  String type; // 'body' 正文段 | 'annotation' 小注段
  bool manual; // 用户手动画/调整过 → 级联重建时保留，按矩形认领行
  String status;

  /// 只确认了本段框几何（「确认识别框」）：检测训练（paragraph_det）
  /// 读这个标记；完全确认（「确认并保存」）蕴含置位。
  bool boxConfirmed;
  String uid;

  Paragraph({
    required this.id,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    this.mainRegionId = '',
    List<String>? lineIds,
    this.type = 'body',
    this.manual = false,
    this.status = AnnotationStatus.proposed,
    this.boxConfirmed = false,
    this.uid = '',
  }) : lineIds = lineIds ?? [];

  Rect get rect =>
      Rect.fromLTWH(x.toDouble(), y.toDouble(), w.toDouble(), h.toDouble());

  factory Paragraph.fromJson(Map<String, dynamic> j) => Paragraph(
    id: j['id'] as String,
    x: j['x'] as int,
    y: j['y'] as int,
    w: j['w'] as int,
    h: j['h'] as int,
    mainRegionId: j['main_region_id'] as String? ?? '',
    lineIds:
        (j['line_ids'] as List?)?.map((e) => e as String).toList() ??
        // 可增长空列表（不能用 const []）：主区/段级联会 removeWhere 改写。
        <String>[],
    type: j['type'] as String? ?? 'body',
    manual: j['manual'] as bool? ?? false,
    status: AnnotationStatus.normalize(
      j['status'] as String?,
      confirmed: j['confirmed'] == true,
    ),
    boxConfirmed: j['box_confirmed'] == true,
    uid: j['uid'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'x': x,
    'y': y,
    'w': w,
    'h': h,
    'main_region_id': mainRegionId,
    'line_ids': lineIds,
    'type': type,
    'manual': manual,
    'status': status,
    if (boxConfirmed) 'box_confirmed': true,
    if (uid.isNotEmpty) 'uid': uid,
  };
}

class PageAnnotation {
  final String pageId;
  final String imagePath;
  int schemaVersion;
  String ocrRevision;
  String modelVersion;
  String sourceSha256;

  /// True once the user has run 确认并保存 on this page in the editor.
  /// Temporary saves (draft edits, page turns) and batch recognition write
  /// annotation files but leave this false — the proofread counters on the
  /// home screen only count explicitly confirmed pages.
  bool reviewed;

  /// True once this page has been 临时保存 (explicit draft save, or the
  /// automatic flush while turning pages / leaving the editor).  Machine
  /// recognition files and pages nobody ever opened stay false — the editor
  /// shows draft-saved pages with an amber thumbnail border until they are
  /// 确认并保存 (green).  Cleared again by 重置为未确认.
  bool draftSaved;

  /// True once the user has run 确认识别框 (boxes-only confirm) on this
  /// page: box geometry (正文区/段落/行/字框) is approved for detection
  /// training while the per-character text/candidates remain unconfirmed.
  /// Full 确认并保存 implies this.  Cleared again by 重置为未确认.
  bool boxesReviewed;

  /// 用户确认"本页没有正文区"（扉页/插图页/空白页等，主区快设里「确认
  /// 并下一页」时不画正文框）：快设网格据此显示已确认角标/可隐藏，也
  /// 用于"该页已处理"的判断。之后重新画了正文主区时自动清除。
  bool noMainTextConfirmed;
  List<MainRegion> mainRegions;
  List<Paragraph> paragraphs;
  List<LineBlock> lines;
  List<CharBlock> blocks; // 扁平字级，与 lines 同步

  /// 表格识别结果（+83）：每张表一次 /recognize_table 的网格 + 文字，
  /// 在表格校对页修正后随页落盘。旧标注无此字段，读侧缺省空。
  List<TableAnnotation> tables;

  /// 识别响应携带的书页图片尺寸（/segment 返回 image_width/height）。
  /// 不落盘：仅用于层级推断（主区外接矩形 + 2% 边距）钳回图片范围，
  /// 以及 clampAllToImage 的兜底。磁盘标注无此信息。
  int sourceImageWidth;
  int sourceImageHeight;

  /// region_det 多类互证冲突（/segment 的 region_conflicts）：main_text 区
  /// 与 header/footer/page_number 区重叠超阈值（交集占排除类框 ≥30%）。
  /// 运行时诊断，不落盘——编辑器据此提示走预标注或人工修正。
  List<Map<String, dynamic>> regionConflicts;

  PageAnnotation({
    required this.pageId,
    required this.imagePath,
    this.schemaVersion = 2,
    this.ocrRevision = '',
    this.modelVersion = '',
    this.sourceSha256 = '',
    this.reviewed = false,
    this.draftSaved = false,
    this.boxesReviewed = false,
    this.noMainTextConfirmed = false,
    this.sourceImageWidth = 0,
    this.sourceImageHeight = 0,
    List<MainRegion>? mainRegions,
    List<Paragraph>? paragraphs,
    List<LineBlock>? lines,
    List<CharBlock>? blocks,
    List<TableAnnotation>? tables,
    List<Map<String, dynamic>>? regionConflicts,
  }) : mainRegions = mainRegions ?? [],
       paragraphs = paragraphs ?? [],
       lines = lines ?? [],
       blocks = blocks ?? [],
       tables = tables ?? [],
       regionConflicts = regionConflicts ?? [];

  /// 页面上是否有任何识别/标注内容（正文区、段落、行、字块任一非空）。
  /// 「创建后手动开始识别」的书据此区分"识别过的页"与"只打开/旋转过的
  /// 页"——后者不落盘，标注文件的存在仍是整本识别「该页已完成」的标记。
  bool get hasAnyContent =>
      mainRegions.isNotEmpty ||
      paragraphs.isNotEmpty ||
      lines.isNotEmpty ||
      blocks.isNotEmpty;

  /// 旧版 JSON 没有 lines，只有扁平 blocks：按 col 分组、组内按 order 排序，
  /// 反推合成 LineBlock。orientation 默认 vertical。
  factory PageAnnotation.fromJson(Map<String, dynamic> j) {
    final pageId = j['page_id'] as String;
    final imagePath = j['image_path'] as String;

    final rawLines = (j['lines'] as List?)?.cast<Map<String, dynamic>>();
    if (rawLines != null && rawLines.isNotEmpty) {
      final lines = rawLines.map((l) => LineBlock.fromJson(l)).toList();
      final blocks = <CharBlock>[];
      for (final line in lines) {
        blocks.addAll(line.chars);
      }
      return PageAnnotation(
        pageId: pageId,
        imagePath: imagePath,
        schemaVersion: (j['schema_version'] as num?)?.toInt() ?? 1,
        ocrRevision: j['ocr_revision'] as String? ?? '',
        modelVersion: j['model_version'] as String? ?? '',
        sourceSha256: j['source_sha256'] as String? ?? '',
        reviewed: j['reviewed'] as bool? ?? false,
        draftSaved: j['draft_saved'] as bool? ?? false,
        boxesReviewed: j['boxes_reviewed'] as bool? ?? false,
        noMainTextConfirmed: j['no_main_text_confirmed'] as bool? ?? false,
        mainRegions:
            (j['main_regions'] as List?)
                ?.map((r) => MainRegion.fromJson(r as Map<String, dynamic>))
                .toList() ??
            // 可增长空列表（不能用 const []）：统一设置/批量清框等会就地
            // 改写这些字段，const 列表一改就抛 UnsupportedError。
            <MainRegion>[],
        paragraphs:
            (j['paragraphs'] as List?)
                ?.map((p) => Paragraph.fromJson(p as Map<String, dynamic>))
                .toList() ??
            <Paragraph>[],
        lines: lines,
        blocks: blocks,
        tables: (j['tables'] as List?)
                ?.map((t) =>
                    TableAnnotation.fromJson(t as Map<String, dynamic>))
                .toList() ??
            <TableAnnotation>[],
      );
    }

    // 兼容旧版只有 blocks 的数据
    final rawBlocks = (j['blocks'] as List?) ?? const [];
    final flatBlocks = rawBlocks
        .map((b) => CharBlock.fromJson(b as Map<String, dynamic>))
        .toList();
    final inferredLines = _inferLinesFromBlocks(flatBlocks);
    for (final line in inferredLines) {
      for (final c in line.chars) {
        c.lineId = line.id;
      }
    }
    return PageAnnotation(
      pageId: pageId,
      imagePath: imagePath,
      schemaVersion: (j['schema_version'] as num?)?.toInt() ?? 1,
      ocrRevision: j['ocr_revision'] as String? ?? '',
      modelVersion: j['model_version'] as String? ?? '',
      sourceSha256: j['source_sha256'] as String? ?? '',
      reviewed: j['reviewed'] as bool? ?? false,
      draftSaved: j['draft_saved'] as bool? ?? false,
      boxesReviewed: j['boxes_reviewed'] as bool? ?? false,
      noMainTextConfirmed: j['no_main_text_confirmed'] as bool? ?? false,
      mainRegions:
          (j['main_regions'] as List?)
              ?.map((r) => MainRegion.fromJson(r as Map<String, dynamic>))
              .toList() ??
          // 同上：可增长空列表，不用 const []。
          <MainRegion>[],
      paragraphs:
          (j['paragraphs'] as List?)
              ?.map((p) => Paragraph.fromJson(p as Map<String, dynamic>))
              .toList() ??
          <Paragraph>[],
      lines: inferredLines,
      blocks: flatBlocks,
      tables: (j['tables'] as List?)
              ?.map((t) => TableAnnotation.fromJson(t as Map<String, dynamic>))
              .toList() ??
          <TableAnnotation>[],
    );
  }

  static List<LineBlock> _inferLinesFromBlocks(List<CharBlock> blocks) {
    if (blocks.isEmpty) return [];
    final byCol = <int, List<CharBlock>>{};
    for (final b in blocks) {
      byCol.putIfAbsent(b.col, () => []).add(b);
    }
    final cols = byCol.keys.toList()..sort();
    final lines = <LineBlock>[];
    for (final col in cols) {
      final colBlocks = byCol[col]!..sort((a, b) => a.order.compareTo(b.order));
      if (colBlocks.isEmpty) continue;
      int minX = colBlocks.first.x;
      int minY = colBlocks.first.y;
      int maxR = colBlocks.first.x + colBlocks.first.w;
      int maxB = colBlocks.first.y + colBlocks.first.h;
      final textBuf = StringBuffer();
      for (final b in colBlocks) {
        if (b.x < minX) minX = b.x;
        if (b.y < minY) minY = b.y;
        if (b.x + b.w > maxR) maxR = b.x + b.w;
        if (b.y + b.h > maxB) maxB = b.y + b.h;
        textBuf.write(b.text);
      }
      lines.add(
        LineBlock(
          id: 'l_col${col.toString().padLeft(3, '0')}',
          x: minX,
          y: minY,
          w: maxR - minX,
          h: maxB - minY,
          lineNo: col,
          orientation: 'vertical',
          text: textBuf.toString(),
          chars: colBlocks,
        ),
      );
    }
    return lines;
  }

  /// 由 lines 重建扁平 blocks，并回填 lineId
  void rebuildBlocks() {
    blocks = [];
    for (final line in lines) {
      for (final c in line.chars) {
        c.lineId = line.id;
        blocks.add(c);
      }
    }
  }

  /// 将当前页面已有标注统一标记为已确认。
  ///
  /// 编辑器的「确认并保存」操作调用此方法，把自动识别结果和人工修改后的
  /// 几何/文字一起固化为可导出的标注（临时保存不会调用）。忽略类型仍保留
  /// 其 type 值，导出器会按类型过滤；这里只统一生命周期状态，避免界面再
  /// 要求逐项确认。
  void markAllConfirmed() {
    boxesReviewed = true; // 完全确认蕴含字框确认
    for (final region in mainRegions) {
      region.status = AnnotationStatus.confirmed;
      region.boxConfirmed = true;
    }
    for (final paragraph in paragraphs) {
      paragraph.status = AnnotationStatus.confirmed;
      paragraph.boxConfirmed = true;
    }
    for (final table in tables) {
      table.status = AnnotationStatus.confirmed;
      for (final cell in table.cells) {
        cell.status = AnnotationStatus.confirmed;
      }
    }
    for (final line in lines) {
      line.status = AnnotationStatus.confirmed;
      line.boxConfirmed = true;
      for (final char in line.chars) {
        char.confirmed = true;
        char.boxConfirmed = true;
        char.status = AnnotationStatus.confirmed;
      }
    }
    // 兼容调用方尚未 rebuildBlocks 的旧数据，同时确保扁平列表里的
    // 字块状态与行内引用保持一致。
    for (final char in blocks) {
      char.confirmed = true;
      char.boxConfirmed = true;
      char.status = AnnotationStatus.confirmed;
    }
  }

  /// 确认本页全部识别框几何（「确认识别框」）：正文区/段落/行/字框
  /// 一并标记 boxConfirmed，计入各自的检测训练统计（region_det/
  /// paragraph_det/line_det/char_det）；单字文字与候选保持 proposed
  /// ——分类训练（char_cls）、Kraken 行导出、校对进度仍要求完全
  /// 确认，不受此影响。适合"框都校完了、字还没逐个过候选"的中间
  /// 状态：先固化切分成果，文字后续再校。
  void markBoxesConfirmed() {
    boxesReviewed = true;
    for (final region in mainRegions) {
      region.boxConfirmed = true;
    }
    for (final paragraph in paragraphs) {
      paragraph.boxConfirmed = true;
    }
    for (final line in lines) {
      line.boxConfirmed = true;
      for (final char in line.chars) {
        char.boxConfirmed = true;
      }
    }
    for (final char in blocks) {
      char.boxConfirmed = true;
    }
  }

  /// 组级确认（墨迹归类页每组的「确认」按钮）：把 [ids] 里的字块标记
  /// 为已确认（confirmed/boxConfirmed/status），随后级联——行内全部字
  /// 都已确认的行升级为已确认；全书所有行都已确认时再级联段落、正文
  /// 区并置 reviewed（与编辑器「确认并保存」同口径：整页绿框、计入
  /// 校对进度与训练数据）。部分确认的页保持原状态，由调用方临时保存。
  /// 返回是否有任何字块状态发生了变化。
  bool confirmCharsById(Set<String> ids) {
    if (ids.isEmpty) return false;
    var changed = false;
    for (final block in blocks) {
      if (ids.contains(block.id) &&
          block.status != AnnotationStatus.confirmed) {
        block.confirmed = true;
        block.boxConfirmed = true;
        block.status = AnnotationStatus.confirmed;
        changed = true;
      }
    }
    if (!changed) return false;

    // 行：全部字已确认（且至少有一个字）→ 行升级；空行/含未确认字
    // 的行不升级，它们仍由「确认并保存」兜底。
    for (final line in lines) {
      if (line.status == AnnotationStatus.confirmed) continue;
      if (line.chars.isEmpty) continue;
      if (line.chars.every((c) => c.status == AnnotationStatus.confirmed)) {
        line.status = AnnotationStatus.confirmed;
        line.boxConfirmed = true;
      }
    }
    final allLinesConfirmed = lines.every(
      (l) => l.status == AnnotationStatus.confirmed,
    );
    if (!allLinesConfirmed) return true;

    // 整页字/行全部确认 → 段落、正文区一并升级，等同「确认并保存」。
    for (final paragraph in paragraphs) {
      paragraph.status = AnnotationStatus.confirmed;
      paragraph.boxConfirmed = true;
    }
    for (final region in mainRegions) {
      region.status = AnnotationStatus.confirmed;
      region.boxConfirmed = true;
    }
    for (final line in lines) {
      for (final char in line.chars) {
        char.confirmed = true;
        char.boxConfirmed = true;
        char.status = AnnotationStatus.confirmed;
      }
    }
    reviewed = true;
    boxesReviewed = true;
    return true;
  }

  /// 页面图像旋转/镜像后的标注几何同步变换（与后端 /transform_page
  /// 的像素映射逐点一致）。op: rotate_cw | rotate_ccw | flip_h | flip_v；
  /// newW/newH 为变换后图像尺寸（90° 旋转交换宽高）。行 orientation 在
  /// 90° 旋转时互换；col/order 序号保持原值——方向变化后建议重新识别
  /// 本页，此前已校对的文字与框仍然对齐。
  void transformGeometry(String op, int newW, int newH) {
    (int, int, int, int) map(int x, int y, int w, int h) {
      switch (op) {
        case 'rotate_cw':
          return (newW - (y + h), x, h, w);
        case 'rotate_ccw':
          return (y, newH - (x + w), h, w);
        case 'flip_h':
          return (newW - (x + w), y, w, h);
        case 'flip_v':
          return (x, newH - (y + h), w, h);
      }
      return (x, y, w, h);
    }

    for (final r in mainRegions) {
      final (x, y, w, h) = map(r.x, r.y, r.w, r.h);
      r.x = x;
      r.y = y;
      r.w = w;
      r.h = h;
    }
    for (final p in paragraphs) {
      final (x, y, w, h) = map(p.x, p.y, p.w, p.h);
      p.x = x;
      p.y = y;
      p.w = w;
      p.h = h;
    }
    for (final table in tables) {
      table.transform(op, newW, newH);
    }
    final swapOrientation = op == 'rotate_cw' || op == 'rotate_ccw';
    for (final line in lines) {
      final (x, y, w, h) = map(line.x, line.y, line.w, line.h);
      line.x = x;
      line.y = y;
      line.w = w;
      line.h = h;
      if (swapOrientation) {
        line.orientation = line.orientation == 'horizontal'
            ? 'vertical'
            : 'horizontal';
      }
      for (final c in line.chars) {
        final (x, y, w, h) = map(c.x, c.y, c.w, c.h);
        c.x = x;
        c.y = y;
        c.w = w;
        c.h = h;
      }
    }
    rebuildBlocks();
  }

  /// 跨页拆分：把本页标注按源图像素坐标的裁剪矩形 [crop] 投影成半页
  /// 标注。返回全新实例（两个半页互不共享任何实体引用），所有几何取
  /// 实体矩形与 [crop] 的交集并平移到新页坐标：
  /// - 行/自然段按矩形中心点归属（中心落在 [crop] 内才保留）——中缝
  ///   劈开一列时整列跟中心侧走、字块随所属行，同一列不会拆到两页；
  /// - 行内字块几何逐块取交集（贴缝的半截字框收进页内，整块在缝对侧
  ///   的随几何丢弃），行文本按保留字块重拼；
  /// - 正文区是工作区域不是内容：与 [crop] 相交即保留相交部分（跨缝
  ///   的区在两侧各留一半）。
  /// 行的 paragraphId 在所属段不在本侧时清空；确认状态与 uid 原样保留。
  PageAnnotation croppedTo({
    required String newPageId,
    required String newImagePath,
    required Rect crop,
  }) {
    final result = PageAnnotation(
      pageId: newPageId,
      imagePath: newImagePath,
      schemaVersion: schemaVersion,
      ocrRevision: ocrRevision,
      modelVersion: modelVersion,
      sourceSha256: sourceSha256,
      reviewed: reviewed,
      draftSaved: draftSaved,
      boxesReviewed: boxesReviewed,
    );

    // 实体矩形裁剪：交集不足 1px（含不相交）时返回 null 表示丢弃。
    // 圆整回整数坐标后可能退化成 0 宽/高，按丢弃计。
    Rect? clipped(Rect r) {
      final c = r.intersect(crop);
      if (c.width < 1 || c.height < 1) return null;
      return Rect.fromLTWH(
        (c.left - crop.left).roundToDouble(),
        (c.top - crop.top).roundToDouble(),
        c.width.roundToDouble(),
        c.height.roundToDouble(),
      );
    }

    for (final region in mainRegions) {
      final c = clipped(region.rect);
      if (c == null) continue;
      result.mainRegions.add(
        MainRegion(
          id: region.id,
          x: c.left.round(),
          y: c.top.round(),
          w: c.width.round(),
          h: c.height.round(),
          label: region.label,
          status: region.status,
          boxConfirmed: region.boxConfirmed,
          uid: region.uid,
        ),
      );
    }

    final keptParaIds = <String>{};
    for (final para in paragraphs) {
      if (!crop.contains(para.rect.center)) continue;
      final c = clipped(para.rect);
      if (c == null) continue;
      keptParaIds.add(para.id);
      result.paragraphs.add(
        Paragraph(
          id: para.id,
          x: c.left.round(),
          y: c.top.round(),
          w: c.width.round(),
          h: c.height.round(),
          mainRegionId: para.mainRegionId,
          lineIds: const [],
          type: para.type,
          manual: para.manual,
          status: para.status,
          boxConfirmed: para.boxConfirmed,
          uid: para.uid,
        ),
      );
    }

    for (final line in lines) {
      if (!crop.contains(line.rect.center)) continue;
      final c = clipped(line.rect);
      if (c == null) continue;
      final newLine = LineBlock(
        id: line.id,
        x: c.left.round(),
        y: c.top.round(),
        w: c.width.round(),
        h: c.height.round(),
        lineNo: line.lineNo,
        orientation: line.orientation,
        readingOrder: line.readingOrder,
        paragraphId: keptParaIds.contains(line.paragraphId)
            ? line.paragraphId
            : '',
        status: line.status,
        boxConfirmed: line.boxConfirmed,
        uid: line.uid,
        manual: line.manual,
      );
      final textBuf = StringBuffer();
      for (final char in line.chars) {
        final cc = clipped(
          Rect.fromLTWH(
            char.x.toDouble(),
            char.y.toDouble(),
            char.w.toDouble(),
            char.h.toDouble(),
          ),
        );
        if (cc == null) continue;
        textBuf.write(char.text);
        newLine.chars.add(
          CharBlock(
            id: char.id,
            x: cc.left.round(),
            y: cc.top.round(),
            w: cc.width.round(),
            h: cc.height.round(),
            col: char.col,
            order: char.order,
            type: char.type,
            confirmed: char.confirmed,
            boxConfirmed: char.boxConfirmed,
            text: char.text,
            source: char.source,
            lineId: newLine.id,
            candidates: char.candidates,
            status: char.status,
            uid: char.uid,
            agree: char.agree,
            conf: char.conf,
          ),
        );
      }
      if (newLine.chars.isEmpty) continue;
      newLine.text = textBuf.toString();
      result.lines.add(newLine);
    }

    // 表格按中心点归属（跨缝的表格整体跟中心侧走，不劈成两个残表）；
    // 行列结构原样保留，几何整体平移到新页坐标。
    for (final table in tables) {
      if (!crop.contains(
        Rect.fromLTWH(
          table.x.toDouble(),
          table.y.toDouble(),
          table.w.toDouble(),
          table.h.toDouble(),
        ).center,
      )) {
        continue;
      }
      final dx = -crop.left.round();
      final dy = -crop.top.round();
      final newTable = TableAnnotation.fromJson(table.toJson());
      newTable.x += dx;
      newTable.y += dy;
      newTable.hLines =
          newTable.hLines.map((v) => v + dy).toList();
      newTable.vLines =
          newTable.vLines.map((v) => v + dx).toList();
      for (final cell in newTable.cells) {
        cell.x += dx;
        cell.y += dy;
        for (final ch in cell.chars) {
          ch.x += dx;
          ch.y += dy;
        }
      }
      result.tables.add(newTable);
    }
    result.rebuildBlocks();
    return result;
  }

  /// 整页是否已完全确认（编辑器绿框、训练导出门槛共用的判定口径）。
  ///
  /// 整页被清空的页面没有任何实体，只要「确认并保存」过（reviewed）同样
  /// 视为已确认。
  bool get isFullyConfirmed {
    final regionsOk = mainRegions.every(
      (r) => r.status == AnnotationStatus.confirmed,
    );
    final paragraphsOk = paragraphs.every(
      (p) => p.status == AnnotationStatus.confirmed,
    );
    final linesOk = lines.every(
      (l) =>
          l.status == AnnotationStatus.confirmed &&
          l.chars.every((c) => c.status == AnnotationStatus.confirmed),
    );
    final hasContent =
        mainRegions.isNotEmpty || paragraphs.isNotEmpty || lines.isNotEmpty;
    return regionsOk && paragraphsOk && linesOk && (hasContent || reviewed);
  }

  /// 页面带有识别框（行/字块）但从未以任何方式确认：编辑器缩略图
  /// 紫框（"识别未确认"）的判定口径。批量识别完没人动过的页落在
  /// 这个状态，与"从未识别"的灰框区分开；「确认识别框」（玫红框）
  /// 「确认并保存」（绿框）或任何临时保存（draftSaved，橘黄框）都
  /// 不算未确认。
  bool get hasUnconfirmedBoxes =>
      !reviewed &&
      !boxesReviewed &&
      !draftSaved &&
      (lines.any((l) => l.chars.isNotEmpty) || blocks.isNotEmpty);

  /// 已确认的排除类版面区（页眉/页脚/页码/图/表）矩形：其中的行/字/
  /// 段落框不参与内容层训练数据与本书计数（用户规则：页眉页脚只作为
  /// 版面标注训练 region_det）。proposed 候选不排除。与 Python 侧
  /// train_datasets.confirmed_excluded_regions 是同一协议的两半，两侧
  /// 判定（框中心点落在已确认排除类区内）必须保持一致。
  List<Rect> get confirmedExcludedRects => [
    for (final r in mainRegions)
      if (r.boxConfirmed &&
          RegionLabel.isExcluded(RegionLabel.normalize(r.label)))
        r.rect,
  ];

  /// 框 (x,y,w,h) 的中心是否落在已确认排除类区内（页眉/页脚/页码/
  /// 图/表）——内容层（段落/行/字）统计与导出排除的共用判定。
  bool centerInConfirmedExcluded(int x, int y, int w, int h) {
    final cx = x + w / 2;
    final cy = y + h / 2;
    for (final rect in confirmedExcludedRects) {
      if (rect.contains(Offset(cx, cy))) return true;
    }
    return false;
  }

  /// 重识别的区域门控输入（/segment 的 gate_regions）：人工已确认的
  /// 版面区原样带给后端——已确认的页眉/页脚/页码在字检测前被抹除
  /// （region_det 模型未训出也能门控），且确认身份随结果带回、不因
  /// 重识别丢失。
  List<Map<String, dynamic>> get confirmedGateRegions => [
    for (final r in mainRegions)
      if (r.boxConfirmed) r.toJson(),
  ];

  /// 将本页全部标注状态重置回 proposed（未确认），并清除 reviewed。
  ///
  /// 「本书重置为未确认」调用，用于清理被旧版"翻页自动确认"污染的数据：
  /// 几何、文字、候选全部保留，只回退生命周期状态，重新校对后可再次
  /// 「确认并保存」。
  void resetToProposed() {
    reviewed = false;
    draftSaved = false;
    boxesReviewed = false;
    for (final region in mainRegions) {
      region.status = AnnotationStatus.proposed;
      region.boxConfirmed = false;
    }
    for (final paragraph in paragraphs) {
      paragraph.status = AnnotationStatus.proposed;
      paragraph.boxConfirmed = false;
    }
    for (final line in lines) {
      line.status = AnnotationStatus.proposed;
      line.boxConfirmed = false;
      for (final char in line.chars) {
        char.confirmed = false;
        char.boxConfirmed = false;
        char.status = AnnotationStatus.proposed;
      }
    }
    for (final char in blocks) {
      char.confirmed = false;
      char.boxConfirmed = false;
      char.status = AnnotationStatus.proposed;
    }
  }

  Map<String, dynamic> toJson() => {
    'page_id': pageId,
    'image_path': imagePath,
    'schema_version': schemaVersion,
    if (ocrRevision.isNotEmpty) 'ocr_revision': ocrRevision,
    if (modelVersion.isNotEmpty) 'model_version': modelVersion,
    if (sourceSha256.isNotEmpty) 'source_sha256': sourceSha256,
    if (reviewed) 'reviewed': true,
    if (draftSaved) 'draft_saved': true,
    if (boxesReviewed) 'boxes_reviewed': true,
    if (noMainTextConfirmed) 'no_main_text_confirmed': true,
    'main_regions': mainRegions.map((r) => r.toJson()).toList(),
    'paragraphs': paragraphs.map((p) => p.toJson()).toList(),
    'lines': lines.map((l) => l.toJson()).toList(),
    'blocks': blocks.map((b) => b.toJson()).toList(),
    if (tables.isNotEmpty) 'tables': tables.map((t) => t.toJson()).toList(),
  };

  /// 启发式自动推断 main_regions 和 paragraphs（hybrid 模式的自动部分）。
  /// 仅在对应列表为空时填充，不覆盖用户已手动修正的数据；
  /// [force] 为 true 时强制重建已有段落（手动段落保留并按矩形重新认领）。
  /// [horizontalDir] 决定竖排列的阅读序（rtl=右→左），影响断段位置。
  /// 主区 = 所有行的外接矩形 + 2% 边距；imageWidth/imageHeight（缺省用
  /// 识别响应携带的 sourceImageWidth/Height）用于把主区钳回图片范围——
  /// 边距会把框推出图片边界（实测 h=2074+2%×2=2157 超出页面 83px）。
  void inferHierarchy({
    String? orientation,
    String horizontalDir = 'ltr',
    String verticalDir = 'ttb',
    bool force = false,
    int? imageWidth,
    int? imageHeight,
  }) {
    if (lines.isEmpty) return;
    final effW = imageWidth ?? sourceImageWidth;
    final effH = imageHeight ?? sourceImageHeight;

    // ---- 主内容区：取所有行的外接矩形 + 2% 边距 ----
    if (mainRegions.isEmpty) {
      double minX = double.infinity, minY = double.infinity;
      double maxX = -double.infinity, maxY = -double.infinity;
      for (final line in lines) {
        if (line.x < minX) minX = line.x.toDouble();
        if (line.y < minY) minY = line.y.toDouble();
        if (line.x + line.w > maxX) maxX = (line.x + line.w).toDouble();
        if (line.y + line.h > maxY) maxY = (line.y + line.h).toDouble();
      }
      if (minX.isFinite) {
        final w = maxX - minX;
        final h = maxY - minY;
        final padX = w * 0.02;
        final padY = h * 0.02;
        var rx = ((minX - padX).round()).clamp(0, double.maxFinite.toInt());
        var ry = ((minY - padY).round()).clamp(0, double.maxFinite.toInt());
        var rw = (w + padX * 2).round();
        var rh = (h + padY * 2).round();
        if (effW > 0) {
          rx = rx.clamp(0, effW);
          rw = rw.clamp(0, effW - rx);
        }
        if (effH > 0) {
          ry = ry.clamp(0, effH);
          rh = rh.clamp(0, effH - ry);
        }
        mainRegions.add(MainRegion(id: 'mr_001', x: rx, y: ry, w: rw, h: rh));
      }
    }

    // ---- 自然段：按版式方向聚类分段 ----
    if (paragraphs.isEmpty) {
      _clusterLinesIntoParagraphs(
        lines,
        orientation: orientation,
        horizontalDir: horizontalDir,
        verticalDir: verticalDir,
      );
    } else if (force) {
      rebuildParagraphs(
        orientation: orientation,
        horizontalDir: horizontalDir,
        verticalDir: verticalDir,
      );
    }
  }

  /// 把主区、段落、行、字框全部钳回图片范围（识别框不得超出书页图片
  /// 本身）。用于：① 编辑器载入旧标注时修复盘上已有的越界框（实测主区
  /// 0,0,1342,2157 超出 1298×2074 页面）；② 旧版后端识别结果没有出口
  /// 钳制时的兜底。返回是否有任何框被修改（供调用方决定是否落盘）。
  /// 容器包含关系修复（**只扩不缩**）：行框不被裁小——段落框扩到
  /// 包含其成员行，主区框扩到包含各段落（按 mainRegionId 归属，缺省
  /// 取相交的主区）。识别重建行后段落/主区还是旧几何时，行会伸出段
  /// 外、段伸出主区外（用户所见"行框在段框外面"）；扩容器而不是裁
  /// 行，保留识别几何。返回是否有改动。随后的 clampAllToImage 保证
  /// 扩容结果仍不越出图片。
  bool ensureHierarchyContainment() {
    var changed = false;
    final lineById = {for (final l in lines) l.id: l};
    for (final p in paragraphs) {
      var x1 = p.x, y1 = p.y, x2 = p.x + p.w, y2 = p.y + p.h;
      for (final id in p.lineIds) {
        final l = lineById[id];
        if (l == null) continue;
        if (l.x < x1) x1 = l.x;
        if (l.y < y1) y1 = l.y;
        if (l.x + l.w > x2) x2 = l.x + l.w;
        if (l.y + l.h > y2) y2 = l.y + l.h;
      }
      if (x1 != p.x || y1 != p.y || x2 != p.x + p.w || y2 != p.y + p.h) {
        p
          ..x = x1
          ..y = y1
          ..w = x2 - x1
          ..h = y2 - y1;
        changed = true;
      }
    }
    if (mainRegions.isNotEmpty) {
      final regionById = {for (final r in mainRegions) r.id: r};
      // 多类化后宿主只认 main_text：页眉/页脚/页码区不是段落的容器，
      // 段落也不该把它们撑大（与 Python 侧 _enforce_hierarchy_containment
      // 同语义）。
      final hostRegions = mainRegions
          .where((r) => !RegionLabel.isExcluded(RegionLabel.normalize(r.label)))
          .toList();
      if (hostRegions.isNotEmpty) {
        for (final p in paragraphs) {
          MainRegion? host;
          if (p.mainRegionId.isNotEmpty) {
            final byId = regionById[p.mainRegionId];
            if (byId != null && hostRegions.contains(byId)) host = byId;
          }
          host ??= hostRegions.firstWhere(
            (r) => r.rect.overlaps(p.rect),
            orElse: () => hostRegions.first,
          );
          var x1 = host.x,
              y1 = host.y,
              x2 = host.x + host.w,
              y2 = host.y + host.h;
          if (p.x < x1) x1 = p.x;
          if (p.y < y1) y1 = p.y;
          if (p.x + p.w > x2) x2 = p.x + p.w;
          if (p.y + p.h > y2) y2 = p.y + p.h;
          if (x1 != host.x ||
              y1 != host.y ||
              x2 != host.x + host.w ||
              y2 != host.y + host.h) {
            host
              ..x = x1
              ..y = y1
              ..w = x2 - x1
              ..h = y2 - y1;
            changed = true;
          }
        }
      }
    }
    return changed;
  }

  bool clampAllToImage(int imageWidth, int imageHeight) {
    if (imageWidth <= 0 || imageHeight <= 0) return false;
    var changed = false;

    void clampRect(_RectBox r) {
      final x2 = r.x + r.w;
      final y2 = r.y + r.h;
      final nx = r.x.clamp(0, imageWidth);
      final ny = r.y.clamp(0, imageHeight);
      final nx2 = x2.clamp(0, imageWidth);
      final ny2 = y2.clamp(0, imageHeight);
      if (nx != r.x || ny != r.y || nx2 != x2 || ny2 != y2) {
        r
          ..x = nx
          ..y = ny
          ..w = nx2 - nx
          ..h = ny2 - ny;
        changed = true;
      }
    }

    for (final r in mainRegions) {
      clampRect(r);
    }
    for (final p in paragraphs) {
      clampRect(p);
    }
    for (final l in lines) {
      clampRect(l);
      for (final c in l.chars) {
        clampRect(c);
      }
    }
    return changed;
  }

  /// 区域级联重建段落结构：
  /// 手动段落（用户画/调过的）保留并按矩形重新认领行；其余行按版式
  /// 方向重新聚类为自动段落。自动段整体重建；手动段即使认领后为空也
  /// 保留——用户刚画的新段（区内还没有行框）正在等自己的段级联补行，
  /// 空是暂态，与手工行/主区同款"manual=用户成果"钉住；删除由用户在
  /// 段面板执行。此前"空手动段即移除"会让并发识别的回包把新段洗掉
  /// （用户所见"识别进行中新画的段框消失"）。
  void rebuildParagraphs({
    String? orientation,
    String horizontalDir = 'ltr',
    String verticalDir = 'ttb',
  }) {
    if (lines.isEmpty) {
      // 页面没有行时手动段同样钉住保留（空页上新画的段在等段级联），
      // 只清自动段。
      paragraphs.removeWhere((p) => !p.manual);
      return;
    }

    // 1. 手动段落优先认领中心点落在其矩形内的行
    final claimed = <String>{};
    final manualParas = paragraphs.where((p) => p.manual).toList();
    for (final p in manualParas) {
      final members = <String>[];
      for (final l in lines) {
        if (claimed.contains(l.id)) continue;
        if (p.rect.contains(Offset(l.x + l.w / 2, l.y + l.h / 2))) {
          members.add(l.id);
          l.paragraphId = p.id;
          claimed.add(l.id);
        }
      }
      p.lineIds = members;
    }

    // 2. 未被手动段落认领的行 → 移除所有自动段落并重新聚类
    paragraphs.removeWhere((p) => !p.manual);
    for (final l in lines) {
      if (l.paragraphId.isNotEmpty && !claimed.contains(l.id)) {
        l.paragraphId = '';
      }
    }
    final unclaimed = lines.where((l) => !claimed.contains(l.id)).toList();
    _clusterLinesIntoParagraphs(
      unclaimed,
      orientation: orientation,
      horizontalDir: horizontalDir,
      verticalDir: verticalDir,
    );
  }

  /// 删除段并连带删除其成员行与行内单字，返回删除的行数。
  ///
  /// 段是成员行的宿主：只删段会留下 paragraphId 指向死段的孤儿行——
  /// 画布上仍在、导出里仍算内容。成员按 lineIds 与 paragraphId 双口径
  /// 取并集（lineIds 可能滞后于行拖移后的实际归属）；其它段的 lineIds
  /// 里指向这批死行的历史引用也一并清掉。调用方随后需 rebuildBlocks。
  int removeParagraphWithLines(Paragraph paragraph) {
    final victimIds = <String>{...paragraph.lineIds};
    for (final l in lines) {
      if (l.paragraphId == paragraph.id) victimIds.add(l.id);
    }
    var removedLines = 0;
    if (victimIds.isNotEmpty) {
      removedLines = lines.where((l) => victimIds.contains(l.id)).length;
      lines.removeWhere((l) => victimIds.contains(l.id));
      for (final p in paragraphs) {
        p.lineIds.removeWhere(victimIds.contains);
      }
    }
    paragraphs.removeWhere(
      (p) => identical(p, paragraph) || p.id == paragraph.id,
    );
    return removedLines;
  }

  /// 新增段并立即按中心点认领行（行的归属从旧段移到新段），返回被移
  /// 除的旧段 id 列表。
  ///
  /// 被本次认领掏空（原本有成员、全被抢走）的旧段移除——新框是用户
  /// 最新意图，重叠抢行时"最后修改者胜"。**本来就空的段不动**：刚画
  /// 完、区内还没有行框的新段正在等自己的段级联补行，认领清理若把它
  /// 顺带删掉，连画两个新段时前一个就会被后一个顶替消失。
  List<String> addParagraphClaiming(Paragraph np) {
    final members = <String>[];
    for (final l in lines) {
      if (np.rect.contains(Offset(l.x + l.w / 2, l.y + l.h / 2))) {
        l.paragraphId = np.id;
        members.add(l.id);
      }
    }
    np.lineIds = members;
    final removedIds = <String>[];
    paragraphs.removeWhere((op) {
      if (op.id == np.id) return false;
      final hadMembers = op.lineIds.isNotEmpty;
      op.lineIds.removeWhere(members.contains);
      if (hadMembers && op.lineIds.isEmpty) {
        removedIds.add(op.id);
        return true;
      }
      return false;
    });
    paragraphs.add(np);
    return removedIds;
  }

  /// 段落聚类。竖排（古籍默认）：每行是一列，按阅读序遍历相邻列，
  /// 遇短列（未写到版心底，说明段落结束）或列间距过大时断段；
  /// 横排：按 x 聚列、列内按 y 排序、行距断段（原逻辑）。
  void _clusterLinesIntoParagraphs(
    List<LineBlock> poolLines, {
    String? orientation,
    String horizontalDir = 'ltr',
    String verticalDir = 'ttb',
  }) {
    if (poolLines.isEmpty) return;

    final verticalCount = poolLines.where((l) => l.h >= l.w).length;
    final isVertical = orientation != null
        ? orientation == 'vertical'
        : verticalCount * 2 >= poolLines.length;

    if (isVertical) {
      _clusterVerticalLines(poolLines, horizontalDir, verticalDir);
      return;
    }

    // 横排：每条水平行就是一个阅读行。按 y 排序（上→下）后按行距断段，
    // 段内顺序在 btt（自下而上）时反转。horizontalDir（ltr/rtl）只影响
    // 行内字符序，由行内插入逻辑处理，不参与行间分段。
    final avgH =
        poolLines.map((l) => l.h).reduce((a, b) => a + b) / poolLines.length;
    final gapThreshold = avgH * 1.5;

    final sortedLines = List<LineBlock>.from(poolLines)
      ..sort((a, b) => a.y.compareTo(b.y)); // 上→下

    final ttb = verticalDir != 'btt';
    var paraIdx = 0;
    var segStart = 0;
    for (var i = 1; i <= sortedLines.length; i++) {
      final isLast = i == sortedLines.length;
      final shouldBreak =
          isLast ||
          (sortedLines[i].y - sortedLines[i - 1].y - sortedLines[i - 1].h) >
              gapThreshold;
      if (shouldBreak) {
        final seg = sortedLines.sublist(segStart, i);
        if (seg.isNotEmpty) {
          final ordered = ttb ? seg : seg.reversed.toList();
          _buildParagraph(ordered, _uniqueParagraphId(paraIdx));
          paraIdx++;
        }
        segStart = i;
      }
    }
    return;
  }

  /// 竖排分段：段末短列断段 + 段首空格断段 + 列间距断段。
  ///
  /// 段末短列：上一列终止边（ttb=底边）明显没到版面终止边 → 上一列是段末。
  /// 段首空格：当前列起始边（ttb=顶边）比版面基准晚超过 1.2 个字高
  /// （段首空两格起头）→ 当前列是新段首。阈值取 1.2 字高是为了避开
  /// 行框抖动（实测可到 0.7 字高），空两格（2 字高）能稳定命中。
  void _clusterVerticalLines(
    List<LineBlock> poolLines,
    String horizontalDir,
    String verticalDir,
  ) {
    final rtl = horizontalDir == 'rtl';
    final ttb = verticalDir != 'btt';
    final sorted = List<LineBlock>.from(poolLines)
      ..sort((a, b) => rtl ? b.x.compareTo(a.x) : a.x.compareTo(b.x));

    final widths = poolLines.map((l) => l.w).toList()..sort();
    final medianW = widths[widths.length ~/ 2].toDouble();
    // 正常列距约等于列宽；放宽到 2.2 倍，只拦真正的版面分离
    // （界欄伪列被剔除后相邻段列距会接近 2 倍列宽，不应误断段）
    final gapLimit = medianW * 2.2;

    var maxBottom = 0;
    var minTop = 1 << 30;
    for (final l in poolLines) {
      if (l.y + l.h > maxBottom) maxBottom = l.y + l.h;
      if (l.y < minTop) minTop = l.y;
    }
    final heights = poolLines.map((l) => l.h).toList()..sort();
    final medianH = heights[heights.length ~/ 2];
    final shortTolerance = medianH * 0.35;

    // 单字高度：优先用行内字框均分估计，无字框时按典型古籍列字数折算
    final charHeights =
        poolLines
            .where((l) => l.chars.isNotEmpty)
            .map((l) => l.h / l.chars.length)
            .toList()
          ..sort();
    final charH = charHeights.isEmpty
        ? medianH / 30
        : charHeights[charHeights.length ~/ 2];
    final indentTolerance = charH * 1.2;
    // 段首基准边：书写起始侧最早（最靠版面起点）的列边
    final startRef = ttb ? minTop : maxBottom;

    var paraIdx = 0;
    var seg = <LineBlock>[];
    LineBlock? prev;
    // 标点尾列：段末句号/逗号独占一列（≤2 个字块、高 ≤2.2 字高）——
    // 它是上一段溢出到下一列的标点，跟随上一段；否则短列断段规则会把
    // 它切成自成一"段"（实测整列一个句号）。
    bool isPunctTail(LineBlock l) => l.chars.length <= 2 && l.h <= charH * 2.2;
    for (final l in sorted) {
      if (prev != null && !isPunctTail(l)) {
        final gap = (prev.x - l.x).abs();
        // 段末信号：上一列终止边没写满到版面终止边
        final prevEnd = ttb ? prev.y + prev.h : prev.y;
        final prevEndsShort = ttb
            ? (maxBottom - prevEnd) > shortTolerance
            : (prevEnd - minTop) > shortTolerance;
        // 段首信号：当前列起始边比版面基准晚（空格起头）
        final startEdge = ttb ? l.y : l.y + l.h;
        final startsIndented = ttb
            ? startEdge - startRef > indentTolerance
            : startRef - startEdge > indentTolerance;
        if (prevEndsShort || startsIndented || gap > gapLimit) {
          if (seg.isNotEmpty) {
            _buildParagraph(seg, _uniqueParagraphId(paraIdx));
            paraIdx++;
          }
          seg = [];
        }
      }
      seg.add(l);
      prev = l;
    }
    if (seg.isNotEmpty) {
      _buildParagraph(seg, _uniqueParagraphId(paraIdx));
    }
  }

  /// 生成不与现有段落冲突的段落 ID。
  String _uniqueParagraphId(int hint) {
    var candidate = 'p_${hint.toString().padLeft(3, '0')}';
    var n = hint;
    while (paragraphs.any((p) => p.id == candidate)) {
      n++;
      candidate = 'p_${n.toString().padLeft(3, '0')}';
    }
    return candidate;
  }

  /// 返回包含 rect 中心点的主区 ID，无包含时回退到第一个主区。
  String _mainRegionIdFor(Rect rect) {
    final center = rect.center;
    for (final r in mainRegions) {
      if (r.rect.contains(center)) return r.id;
    }
    return mainRegions.isNotEmpty ? mainRegions.first.id : '';
  }

  /// 中心点落在其中的第一个主区；无包含时返回 null（与行/段认领、
  /// 后端 _filter_layout 的中心判定同口径）。
  MainRegion? _regionContaining(Rect rect) {
    final center = rect.center;
    for (final r in mainRegions) {
      if (r.rect.contains(center)) return r;
    }
    return null;
  }

  void _buildParagraph(List<LineBlock> segLines, String id) {
    if (segLines.isEmpty) return;
    int minX = segLines.first.x;
    int minY = segLines.first.y;
    int maxX = segLines.first.x + segLines.first.w;
    int maxY = segLines.first.y + segLines.first.h;
    for (final l in segLines) {
      if (l.x < minX) minX = l.x;
      if (l.y < minY) minY = l.y;
      if (l.x + l.w > maxX) maxX = l.x + l.w;
      if (l.y + l.h > maxY) maxY = l.y + l.h;
    }
    var paraRect = Rect.fromLTWH(
      minX.toDouble(),
      minY.toDouble(),
      (maxX - minX).toDouble(),
      (maxY - minY).toDouble(),
    );
    // 层级包含（用户规则）：行框 ⊆ 段落框 ⊆ 主区框。段落框取成员行
    // 外接矩形后钳进包含其中心的主区；伸出主区的行框（标点墨迹外扩、
    // 条带越界）随之钳进段落框，三层框严格嵌套。段落中心在所有主区外
    // （版面边缘的夹注小字段）时不钳制——没有可归属的主区。
    final host = _regionContaining(paraRect);
    if (host != null) {
      final clampedPara = paraRect.intersect(host.rect);
      if (clampedPara.width >= 1 && clampedPara.height >= 1) {
        paraRect = clampedPara;
        for (final l in segLines) {
          final lr = Rect.fromLTWH(
            l.x.toDouble(),
            l.y.toDouble(),
            l.w.toDouble(),
            l.h.toDouble(),
          );
          final inner = lr.intersect(paraRect);
          if (inner.width >= 1 && inner.height >= 1) {
            l.x = inner.left.round();
            l.y = inner.top.round();
            l.w = inner.width.round();
            l.h = inner.height.round();
          }
        }
      }
    }
    // 判定小注段：段内所有字的 type 都是 annotation → annotation 段
    var allAnnotation = true;
    for (final l in segLines) {
      for (final c in l.chars) {
        if (c.type != 'annotation') {
          allAnnotation = false;
          break;
        }
      }
      if (!allAnnotation) break;
    }
    final para = Paragraph(
      id: id,
      x: paraRect.left.round(),
      y: paraRect.top.round(),
      w: paraRect.width.round(),
      h: paraRect.height.round(),
      mainRegionId: host?.id ?? _mainRegionIdFor(paraRect),
      lineIds: segLines.map((l) => l.id).toList(),
      type: allAnnotation && segLines.any((l) => l.chars.isNotEmpty)
          ? 'annotation'
          : 'body',
    );
    paragraphs.add(para);
    for (final l in segLines) {
      l.paragraphId = id;
    }
  }
}

/// Whole-book recognition pipeline state persisted on [Project].
abstract final class RecognitionStatus {
  static const String pending = 'pending'; // queued, not started yet
  static const String recognizing = 'recognizing'; // pages being processed
  static const String completed = 'completed'; // every page has a result

  static bool isCompleted(String? status) => status == completed;
}

/// 页号的唯一真相来源：图片文件名 stem（page_037.png → page_037，
/// warped/split_page_273.png → split_page_273）。
///
/// 删除页时图片文件不重命名（天然稳定标识），而 imageFiles 下标会前移。
/// 历史上对非 page_NNN 文件名（跨页拆分/摆正输出的 split_page_273.png
/// 等）回退按下标命名标注文件：删页后后续所有页的下标漂移，标注文件
/// 名却停在旧下标，与当前页全部错配，被 loadAnnotation 的
/// expectedImagePath 守卫整书丢弃——表现为"全书识别丢失"。stem 直接作
/// 页号后，删页/插页/重排不再改变任何页的标注文件名。同书内 stem 天然
/// 不重复：拆分输出页号避开输入页号（见 [splitOutputStartIndex]），摆
/// 正输出同源永远同名。存量下标型标注文件由
/// python_service/tool_realign_annotations.py 按标注内记录的 image_path
/// 一次性归位。
String pageIdForImage(String imagePath, int index) {
  final stem = p.basenameWithoutExtension(imagePath);
  // 兜底：空 stem 或点开头的隐藏文件名（如 ".png" 的 stem 仍是 ".png"）
  // 退回下标页号，避免生成空/点开头的标注文件名。
  final usable = stem.isNotEmpty && !stem.startsWith('.');
  return usable
      ? stem
      : 'page_${index.toString().padLeft(3, '0')}';
}

/// 跨页拆分输出页号的起始值：保证输出页的 pageId（page_NNN stem）避开
/// 所有输入页的页号——输入文件名 stem 是 page_NNN 时取最大编号 +1，
/// 否则退回输入页数（输出从 N 起同样不撞）。输出从该值连续编号后，重
/// 拆时同序输入得到同一批页号，旧输出文件原位覆盖；源页标注文件在整
/// 轮拆分中不被触碰（成为孤儿，「恢复拆分前」因此无需备份即可还原）。
int splitOutputStartIndex(List<String> imageFiles) {
  var maxStem = -1;
  for (final f in imageFiles) {
    final m = RegExp(
      r'^page_(\d{3,})$',
    ).firstMatch(p.basenameWithoutExtension(f));
    if (m != null) {
      final v = int.parse(m.group(1)!);
      if (v > maxStem) maxStem = v;
    }
  }
  return math.max(maxStem + 1, imageFiles.length);
}

/// 跨页拆分记录（project.json 的 `split_info`）：拆分前的源页面与拆分
/// 参数。存在该记录时，编辑器「跨页拆分」页基于 [sourceFiles]（拆分前
/// 的原始页面，文件保留在盘上）叠加与重拆，「恢复拆分前」按
/// [sourceFiles] 直接还原页面列表——源页标注从未被拆分改写，恢复即
/// 回到拆分前状态；拆分输出页的标注按 [outputPageIds] 清理。
class SplitInfo {
  final List<String> sourceFiles;
  final double spineRatio; // 中缝相对页宽的比例（0~1）
  final String order; // 'left_first' | 'right_first'
  final String outputDir; // 拆分输出图片目录
  final List<String> outputPageIds;

  const SplitInfo({
    required this.sourceFiles,
    required this.spineRatio,
    required this.order,
    required this.outputDir,
    required this.outputPageIds,
  });

  factory SplitInfo.fromJson(Map<String, dynamic>? j) => SplitInfo(
    sourceFiles: j == null
        ? const []
        : (j['source_files'] as List?)?.map((e) => e.toString()).toList() ??
              const [],
    spineRatio: (j?['spine_ratio'] as num?)?.toDouble() ?? 0.5,
    order: j?['order'] as String? ?? 'right_first',
    outputDir: j?['output_dir'] as String? ?? '',
    outputPageIds: j == null
        ? const []
        : (j['output_page_ids'] as List?)?.map((e) => e.toString()).toList() ??
              const [],
  );

  Map<String, dynamic> toJson() => {
    'source_files': sourceFiles,
    'spine_ratio': spineRatio,
    'order': order,
    'output_dir': outputDir,
    'output_page_ids': outputPageIds,
  };
}

/// 跨页拆分输出计划：从源页列表推导每张图的左右输出路径与全书阅读序
/// 页列表（纯函数，拆分执行与测试共用同一份推导）。
///
/// 输出统一为 `page_NNN.png`（从 [SplitInfo] 拆分起始页号起连续编号），
/// 阅读序按 [leftFirst] 交错：每张源图拆出的两页先左后右或先右后左依次
/// 排入全书页列表。
class SplitPlan {
  /// 每张源图的输出：路径与对应页号（pageIdForImage 的 stem，输出统一
  /// page_NNN 命名所以页号即文件名 stem）。
  final List<
    ({String leftPath, String rightPath, String leftPageId, String rightPageId})
  >
  perSource;

  /// 全书阅读序的输出图片路径（拆分后的 imageFiles）。
  final List<String> readingOrderPaths;

  /// 全书阅读序的输出页号（清理旧输出标注文件用）。
  final List<String> outputPageIds;

  const SplitPlan({
    required this.perSource,
    required this.readingOrderPaths,
    required this.outputPageIds,
  });

  factory SplitPlan.build({
    required List<String> sources,
    required bool leftFirst,
    required String outputDir,
    required int startIndex,
  }) {
    String pathFor(int k) =>
        p.join(outputDir, 'page_${k.toString().padLeft(3, '0')}.png');
    String pageIdFor(int k) => 'page_${k.toString().padLeft(3, '0')}';

    final perSource =
        <
          ({
            String leftPath,
            String rightPath,
            String leftPageId,
            String rightPageId,
          })
        >[];
    final readingOrderPaths = <String>[];
    final outputPageIds = <String>[];
    for (var i = 0; i < sources.length; i++) {
      final leftK = startIndex + i * 2;
      final rightK = startIndex + i * 2 + 1;
      final entry = (
        leftPath: pathFor(leftK),
        rightPath: pathFor(rightK),
        leftPageId: pageIdFor(leftK),
        rightPageId: pageIdFor(rightK),
      );
      perSource.add(entry);
      if (leftFirst) {
        readingOrderPaths
          ..add(entry.leftPath)
          ..add(entry.rightPath);
        outputPageIds
          ..add(entry.leftPageId)
          ..add(entry.rightPageId);
      } else {
        readingOrderPaths
          ..add(entry.rightPath)
          ..add(entry.leftPath);
        outputPageIds
          ..add(entry.rightPageId)
          ..add(entry.leftPageId);
      }
    }
    return SplitPlan(
      perSource: perSource,
      readingOrderPaths: readingOrderPaths,
      outputPageIds: outputPageIds,
    );
  }
}

/// 本页识别方向覆盖：null 字段 = 该项跟随整书设置。
///
/// 覆盖按页保存（pageId -> 覆盖项），识别方向决定行切分/读法/阅读序，
/// 修改后需重新识别该页才生效。旧格式（值仅为 'horizontal'|'vertical'
/// 字符串）在 [fromDynamic] 里兼容读取。
class PageDirectionOverride {
  String? orientation; // 'horizontal' | 'vertical'
  String? horizontalDir; // 'ltr' | 'rtl'
  String? verticalDir; // 'ttb' | 'btt'

  PageDirectionOverride({
    this.orientation,
    this.horizontalDir,
    this.verticalDir,
  });

  bool get isEmpty =>
      orientation == null && horizontalDir == null && verticalDir == null;

  /// 解析 project.json 里的覆盖值：旧格式是 'horizontal'|'vertical' 字符串
  /// （仅覆盖排版方向），新格式是 {orientation?, horizontal_dir?, vertical_dir?}。
  /// 无法识别的值返回 null（不建覆盖）。
  static PageDirectionOverride? fromDynamic(Object? v) {
    if (v is String) {
      return (v == 'horizontal' || v == 'vertical')
          ? PageDirectionOverride(orientation: v)
          : null;
    }
    if (v is Map) {
      String? pick(String key, Set<String> allowed) {
        final val = v[key]?.toString();
        return val != null && allowed.contains(val) ? val : null;
      }

      final override = PageDirectionOverride(
        orientation: pick('orientation', const {'horizontal', 'vertical'}),
        horizontalDir: pick('horizontal_dir', const {'ltr', 'rtl'}),
        verticalDir: pick('vertical_dir', const {'ttb', 'btt'}),
      );
      return override.isEmpty ? null : override;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    if (orientation != null) 'orientation': orientation,
    if (horizontalDir != null) 'horizontal_dir': horizontalDir,
    if (verticalDir != null) 'vertical_dir': verticalDir,
  };
}

class Project {
  final String id;
  String name;
  final String projectDir;
  List<String> imageFiles; // absolute paths
  ProjectSettings settings;
  BookMetadata bookMetadata;
  String sourceFileType; // 'images' | 'pdf'
  int schemaVersion;

  /// 本页标注的页号（图片文件名 stem；见 [pageIdForImage]）。
  String pageIdAt(int index) => pageIdForImage(imageFiles[index], index);

  /// 本页的有效识别方向：按页覆盖优先，否则整书设置。
  String effectiveOrientationAt(int index) =>
      effectiveOrientationFor(pageIdAt(index));

  /// 按页号取有效识别方向（覆盖优先，否则整书设置）。
  String effectiveOrientationFor(String pageId) =>
      pageDirectionOverrides[pageId]?.orientation ?? settings.orientation;

  /// 按页号取有效横排方向/竖排方向（覆盖优先，否则整书设置）。
  String effectiveHorizontalDirFor(String pageId) =>
      pageDirectionOverrides[pageId]?.horizontalDir ?? settings.horizontalDir;

  String effectiveVerticalDirFor(String pageId) =>
      pageDirectionOverrides[pageId]?.verticalDir ?? settings.verticalDir;

  /// 本页识别用的设置（排版方向与阅读方向按页覆盖后的副本，
  /// 不改动整书 settings）。
  ProjectSettings settingsAt(int index) {
    final override = pageDirectionOverrides[pageIdAt(index)];
    return settings.copyWith(
      orientation: override?.orientation ?? settings.orientation,
      horizontalDir: override?.horizontalDir ?? settings.horizontalDir,
      verticalDir: override?.verticalDir ?? settings.verticalDir,
    );
  }

  /// Index of the last page opened in the editor for this book.
  int lastPageIndex;

  /// Whole-book background recognition state. Projects created before the
  /// pipeline existed have no stored value and default to [RecognitionStatus.completed]
  /// so they remain directly editable.
  String recognitionStatus;

  /// Number of pages whose annotation file has been produced. Display only —
  /// the annotation files on disk remain the source of truth and this counter
  /// is healed from disk when a book resumes.
  int recognizedPages;

  /// 创建后是否自动排队整本识别。新建任务勾选「创建后手动开始识别」时
  /// 为 false：书不进识别队列、重启也不自动续跑，可先进入编辑整理页面，
  /// 由用户手动开始整本识别；一经 enqueue（手动开始、拆分后自动识别等
  /// 任何入口）即置回 true，此后断点续跑照旧。旧数据缺键读回 true。
  bool autoRecognize;

  /// 导入未完成：PDF 页图还在转换（或转换中断待续跑）。true 时书已在
  /// 书库可见但不可进入编辑/识别，书卡片提供「继续导入」从断点续跑
  /// （后端跳过已转换页）。旧数据缺键读 false。
  bool importPending;

  /// 固定在项目上的整行 AI 裁决开关，避免全局设置变化影响进行中的书。
  bool aiRecognitionAssist;

  /// 按项目配置的自训模型覆写：层级（如 char_det）-> 模型文件路径；
  /// 空字符串 = 该层强制停用（走基线）；未出现的层 = 使用全局启用的模型。
  final Map<String, String> modelOverrides = {};

  /// 按页识别方向覆盖：pageId（图片文件名 stem）-> 覆盖项（null 字段
  /// 跟随整书）。个别页与整书排版/阅读方向不同时单独指定；未出现的页
  /// 用整书 settings。方向在识别时决定行切分/读法/阅读序，设置后需
  /// 重新识别该页才生效。
  final Map<String, PageDirectionOverride> pageDirectionOverrides = {};

  /// 跨页拆分记录：非 null 表示本书拆分过（编辑器「跨页拆分」页据此
  /// 基于原始页面重拆或恢复）。见 [SplitInfo]。
  SplitInfo? splitInfo;

  Project({
    required this.id,
    required this.name,
    required this.projectDir,
    required this.imageFiles,
    ProjectSettings? settings,
    BookMetadata? bookMetadata,
    this.sourceFileType = 'images',
    this.schemaVersion = 2,
    this.lastPageIndex = 0,
    String? recognitionStatus,
    this.recognizedPages = 0,
    this.autoRecognize = true,
    this.importPending = false,
    this.aiRecognitionAssist = false,
    this.splitInfo,
  }) : settings = settings ?? ProjectSettings(),
       bookMetadata = bookMetadata ?? BookMetadata(title: name),
       recognitionStatus = recognitionStatus ?? RecognitionStatus.completed;

  bool get recognitionCompleted =>
      RecognitionStatus.isCompleted(recognitionStatus);

  factory Project.fromJson(Map<String, dynamic> j) => Project(
    id: j['id'],
    name: j['name'],
    projectDir: j['project_dir'],
    imageFiles: List<String>.from(j['image_files'] ?? []),
    settings: ProjectSettings.fromJson(
      (j['settings'] as Map<String, dynamic>?)?.cast<String, dynamic>(),
    ),
    bookMetadata: BookMetadata.fromJson(
      (j['book_metadata'] as Map<String, dynamic>?)?.cast<String, dynamic>(),
      fallbackTitle: j['name'] as String? ?? '',
    ),
    sourceFileType: j['source_file_type'] as String? ?? 'images',
    schemaVersion: (j['schema_version'] as num?)?.toInt() ?? 1,
    lastPageIndex: (j['last_page_index'] as num?)?.toInt() ?? 0,
    recognitionStatus: j['recognition_status'] as String?,
    recognizedPages: (j['recognized_pages'] as num?)?.toInt() ?? 0,
    autoRecognize: j['auto_recognize'] as bool? ?? true,
    importPending: j['import_pending'] as bool? ?? false,
    aiRecognitionAssist: j['ai_recognition_assist'] as bool? ?? false,
    splitInfo: j['split_info'] is Map
        ? SplitInfo.fromJson((j['split_info'] as Map).cast<String, dynamic>())
        : null,
  );

  static Project fromJsonMap(Map<String, dynamic> j) {
    final project = Project.fromJson(j);
    final overrides = j['model_overrides'];
    if (overrides is Map) {
      overrides.forEach((k, v) {
        project.modelOverrides[k.toString()] = v.toString();
      });
    }
    final pageOrientation = j['page_orientation_overrides'];
    if (pageOrientation is Map) {
      pageOrientation.forEach((k, v) {
        final override = PageDirectionOverride.fromDynamic(v);
        if (override != null) {
          project.pageDirectionOverrides[k.toString()] = override;
        }
      });
    }
    return project;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'project_dir': projectDir,
    'image_files': imageFiles,
    'settings': settings.toJson(),
    'book_metadata': bookMetadata.toJson(),
    'source_file_type': sourceFileType,
    'schema_version': schemaVersion,
    'last_page_index': lastPageIndex,
    'recognition_status': recognitionStatus,
    'recognized_pages': recognizedPages,
    'auto_recognize': autoRecognize,
    'import_pending': importPending,
    'ai_recognition_assist': aiRecognitionAssist,
    if (modelOverrides.isNotEmpty) 'model_overrides': modelOverrides,
    if (pageDirectionOverrides.isNotEmpty)
      'page_orientation_overrides': pageDirectionOverrides.map(
        (k, v) => MapEntry(k, v.toJson()),
      ),
    if (splitInfo != null) 'split_info': splitInfo!.toJson(),
  };
}
