import 'dart:math';

import '../models/models.dart';
import 'ollama_service.dart';
import 'python_service.dart';

/// AI 框检查：可疑扫描（纯函数）→ 两档修复（A 档几何直修免 VLM /
/// B 档视觉模型诊断）→ 后端重摆 → 前后置信度裁决（提升才采纳）。
///
/// 设计约束：修复动作全部映射后端已有算子（/segment_region 推倒重摆），
/// VLM 只从固定菜单选问题类型不给坐标；重摆会把字重置为 proposed，因此
/// 扫描必须跳过用户成果行（manual / 全部字框已确认 / 含已确认字）。

/// 可疑档位：A 档几何信号可直接修（免 VLM，不依赖 Ollama）；B 档语义
/// 信号需要视觉模型诊断。
enum BoxSuspectTier { geometry, semantic }

/// 一条可疑行：行 + 档位 + 触发原因（中文短标签）+ A 档执行参数。
class BoxSuspect {
  const BoxSuspect({
    required this.line,
    required this.tier,
    required this.reasons,
    this.geometryExpectedCount,
    this.overlapPartner,
    this.duplicatePartner,
    this.blankInk = false,
    this.contentFloor,
  });

  final LineBlock line;
  final BoxSuspectTier tier;
  final List<String> reasons;

  /// A 档按几何推算的期望字数（行高÷中位字高，或高框+1）；null = 不
  /// 带期望字数（交给双列拆分/默认策略）。
  final int? geometryExpectedCount;

  /// 与本行重叠的伴生行（A 档重叠规则）：修复时取两行并集矩形重跑。
  final LineBlock? overlapPartner;

  /// 与本行重复的伴生行（同列重复检测：重叠率高且字数相同/文本一致，
  /// 实测同一条文字列被检测器输出成两条互相重叠的行）：修复动作 = 删
  /// 除质量分较差的一条，纯前端操作，不调后端（后端重摆会原样复检）。
  final LineBlock? duplicatePartner;

  /// 空框（字框内无文字墨迹，/line_ink 实测）：修复动作 = 直接删除该
  /// 行，不调后端也不调视觉模型。界格线/邻列渗墨已被结构性过滤剔除，
  /// 实测真文字行墨迹中位 ≈0.23~0.47，幽灵行 ≈0。
  final bool blankInk;

  /// 内容守恒下限（重摆结果的最少字数）：默认旧字数的一半；"过半字框
  /// 空白"的行按非空字数下推（诚实修复会删掉空白字框，字数下降是预期
  /// 内的）。
  final int? contentFloor;
}

/// 用户成果行判定：重摆会重置字的确认状态，这些行不允许自动修。
/// manual（手工调过框）、字框全部 boxConfirmed、含任何已确认字。
bool isProtectedLine(LineBlock l) =>
    l.manual ||
    (l.chars.isNotEmpty && l.chars.every((c) => c.boxConfirmed)) ||
    l.chars.any((c) => c.confirmed);

/// 两个像素矩形的交集面积（不相交为 0）。
int _rectOverlap(
  int ax,
  int ay,
  int aw,
  int ah,
  int bx,
  int by,
  int bw,
  int bh,
) {
  final aRight = ax + aw, bRight = bx + bw;
  final aBottom = ay + ah, bBottom = by + bh;
  final right = aRight < bRight ? aRight : bRight;
  final left = ax > bx ? ax : bx;
  final bottom = aBottom < bBottom ? aBottom : bBottom;
  final top = ay > by ? ay : by;
  final ix = right - left;
  final iy = bottom - top;
  if (ix <= 0 || iy <= 0) return 0;
  return ix * iy;
}

/// 只有会吞掉有效文字的重叠才需要 AI 框修复。相邻正文/夹注的安全
/// 边距可能有少量几何交集；为了追求“零重叠”把它裁窄会切掉边缘笔画。
bool _meaningfulLineOverlap(LineBlock a, LineBlock b, int area) {
  if (area <= 0) return false;
  final aArea = max(1, a.w * a.h);
  final bArea = max(1, b.w * b.h);
  final fraction = area / min(aArea, bArea);
  final vertical = a.orientation != 'horizontal';
  final crossOverlap = vertical
      ? max(0, min(a.x + a.w, b.x + b.w) - max(a.x, b.x))
      : max(0, min(a.y + a.h, b.y + b.h) - max(a.y, b.y));
  final crossMin = vertical ? min(a.w, b.w) : min(a.h, b.h);
  // 两个相邻列只在安全边距处相交时，不把它们当作会影响识别的
  // 重叠。这样 AI 检查不会为了“零重叠”把真实列裁窄。
  if (crossOverlap < crossMin * 0.25) return false;
  if (fraction >= 0.12) return true;
  // 不同版面角色的窄边交集是安全边距，不作为可疑框。
  if (a.layoutRole != b.layoutRole && fraction < 0.30) return false;
  return crossOverlap >= crossMin * 0.25;
}

/// 字的"沿阅读轴尺寸"：竖排行沿 y 轴、横排行沿 x 轴。高框判定、字数
/// 推算都用这个口径（与编辑器 isTallCharBox、后端标点拆分同源）。
double _alongAxis(CharBlock c, String orientation) =>
    orientation == 'horizontal' ? c.w.toDouble() : c.h.toDouble();

/// 行的沿阅读轴总长：竖排行沿 y 轴（=高），横排行沿 x 轴（=宽）。
double _lineAlongAxis(LineBlock l) =>
    l.orientation == 'horizontal' ? l.w.toDouble() : l.h.toDouble();

/// 行的"厚度"（跨阅读轴）：竖排=行宽，横排=行高。一列被拆成两行时
/// 两条窄行的厚度都远小于页面中位厚度。
double _lineCrossAxis(LineBlock l) =>
    l.orientation == 'horizontal' ? l.h.toDouble() : l.w.toDouble();

double _medianAlongAxis(LineBlock l) {
  final sizes = [for (final c in l.chars) _alongAxis(c, l.orientation)]..sort();
  if (sizes.isEmpty) return 0;
  final mid = sizes.length ~/ 2;
  return sizes.length.isOdd ? sizes[mid] : (sizes[mid - 1] + sizes[mid]) / 2.0;
}

/// 异常高字框（可能"字+标点"同框或多字粘连）：沿轴尺寸 > 行中位×1.18
/// 且超出 5px（与后端 _split_punct_merged 后检同口径）。
bool isTallCharBox(CharBlock c, double medianAlong, String orientation) {
  if (medianAlong <= 0) return false;
  return _alongAxis(c, orientation) > medianAlong * 1.18 + 5;
}

/// 空框判定阈值：逐字核心区结构性墨迹占比中位数低于此值视为框内无文
/// 字。实测校准（split_page_345）：真文字行 0.23~0.43，落在列间空白
/// 带/界格上的幽灵行 ≈0；0.08 留足余量。
const double kBlankLineInk = 0.08;

/// 字框空白占比阈值：超过一半字框无墨迹 → 行框切分与实际字形错位。
const double kBlankCharRatio = 0.5;

/// 扫描一页的可疑行（纯函数）。规则分两档：
/// A 档（几何）：空框（墨迹实测）/ 行框重叠 / 异常高字框 / 字数与行长
/// 比超 [0.7, 1.35] / 过半字框无墨迹；
/// B 档（语义）：存在 conf<0.55 的字 / conflict·box_multi·none 占比
/// 超 30% / 墨迹校验 mismatch·suspect。
/// 保护行（见 [isProtectedLine]）跳过；无字的行仅在墨迹数据佐证为空框
/// 时报告（避免误删尚待识别的手工行）。
/// [inkByLineId] 为 /line_ink 的批量测量结果（编辑器在扫描前一次性拉
/// 取）；缺项的行走原有几何/语义规则。
List<BoxSuspect> scanSuspects(
  PageAnnotation ann, {
  Map<String, LineInkResult> inkByLineId = const {},
}) {
  final out = <BoxSuspect>[];
  // 页面级中位行厚：窄行判定（一列被拆成两行时两条窄行厚度都远小于
  // 中位）的基准。页面行数太少（<4）时中位数不稳，不做窄行判定。
  final crossWidths = [for (final l in ann.lines) _lineCrossAxis(l)]..sort();
  final medianCross = crossWidths.isEmpty
      ? 0.0
      : (crossWidths.length.isOdd
            ? crossWidths[crossWidths.length ~/ 2]
            : (crossWidths[crossWidths.length ~/ 2 - 1] +
                      crossWidths[crossWidths.length ~/ 2]) /
                  2.0);
  for (final line in ann.lines) {
    if (isProtectedLine(line)) continue;
    final ink = inkByLineId[line.id];
    // charCount==0 的退化测量（异常形态）按无数据处理，不据此删行。
    final hasInk = ink != null && ink.charCount > 0;
    final blank = hasInk && ink.charInkMedian < kBlankLineInk;

    // 空框：框内无文字墨迹（幽灵框——检测器把版心空白/界格带误检成行，
    // 读出的"文字"全是噪声）。删框是唯一正确修复，重摆会原样复检、
    // 视觉模型对空白条的判断不可靠（实测会说"没问题"）。
    if (blank) {
      out.add(
        BoxSuspect(
          line: line,
          tier: BoxSuspectTier.geometry,
          reasons: [
            if (line.chars.isEmpty)
              '空框（无字块且无墨迹）'
            else
              '空框（${line.chars.length} 个字框内均无墨迹）',
          ],
          blankInk: true,
        ),
      );
      continue;
    }

    if (line.chars.isEmpty) continue;
    final reasons = <String>[];
    var expected = 0;
    var contentFloor = 0;

    // ── A 档：几何 ──
    // 重叠伴生行只取非保护行（manual/已确认的行不能被并集重跑洗掉）；
    // 保护行伴生时仍报重叠原因，但只重跑本行自身矩形。已判空的幽灵行
    // 既不作为伴生也不累计重叠（它会被自己的空框可疑删除，重叠随之
    // 消失——报了只会触发一次注定"维持原切分"的重跑）。
    var overlapArea = 0;
    var partnerArea = 0;
    LineBlock? partner;
    for (final other in ann.lines) {
      if (identical(other, line)) continue;
      final area = _rectOverlap(
        line.x,
        line.y,
        line.w,
        line.h,
        other.x,
        other.y,
        other.w,
        other.h,
      );
      if (!_meaningfulLineOverlap(line, other, area)) continue;
      if (isProtectedLine(other)) {
        if (area > overlapArea) overlapArea = area;
        continue;
      }
      final otherInk = inkByLineId[other.id];
      if (otherInk != null &&
          otherInk.charCount > 0 &&
          otherInk.charInkMedian < kBlankLineInk) {
        continue;
      }
      if (area > overlapArea) overlapArea = area;
      if (area > partnerArea) {
        partnerArea = area;
        partner = other;
      }
    }
    LineBlock? duplicate;
    if (overlapArea > 0) {
      // 同列重复检测：重叠覆盖率高（交/较小方面积 ≥0.5）且字数相同
      // （±1）或文本一致 → 同一条文字列被输出成两条行，重摆救不了
      // （后端会再检出同样的框），修复动作是删除较差的一条。
      if (partner != null && partner.chars.isNotEmpty) {
        final inter = _rectOverlap(
          line.x,
          line.y,
          line.w,
          line.h,
          partner.x,
          partner.y,
          partner.w,
          partner.h,
        );
        final lineArea = line.w * line.h;
        final partnerArea2 = partner.w * partner.h;
        final minArea = lineArea < partnerArea2 ? lineArea : partnerArea2;
        final sameCount = (line.chars.length - partner.chars.length).abs() <= 1;
        final sameText = line.text.isNotEmpty && line.text == partner.text;
        if (minArea > 0 && inter / minArea >= 0.5 && (sameCount || sameText)) {
          duplicate = partner;
        }
      }
      reasons.add(duplicate != null ? '与相邻行重复（同列重复检测）' : '与相邻行框重叠');
    }

    final median = _medianAlongAxis(line);
    if (median > 0) {
      final tallCount = line.chars
          .where((c) => isTallCharBox(c, median, line.orientation))
          .length;
      if (tallCount > 0) {
        reasons.add('$tallCount 个异常高字框');
        // "字+标点"同框 → 每个高框大约多藏 1 个字。
        expected = line.chars.length + tallCount;
      }
      final axisLen = _lineAlongAxis(line);
      final geoCount = max(1, (axisLen / median).round());
      final ratio = line.chars.length / geoCount;
      if (ratio < 0.7 || ratio > 1.35) {
        reasons.add('字数与行长不符（${line.chars.length}/约$geoCount）');
        // 几何推算的字数优先于高框增量（它直接来自行长）。
        expected = geoCount;
      }
    }

    // 过半字框无墨迹：行框与实际字形错位（框飘到了列间）。期望字数按
    // 非空字数下推（给后端变化的参数），内容守恒下限同步下推——诚实
    // 修复会删掉空白字框，字数下降是预期内的。
    if (hasInk) {
      final inked = ink.charCount - ink.blankChars;
      if (ink.blankChars / ink.charCount >= kBlankCharRatio && inked >= 1) {
        reasons.add('${ink.blankChars}/${ink.charCount} 个字框内无墨迹');
        expected = inked;
        contentFloor = max(1, (inked * 0.7).round());
      }
    }

    var tier = BoxSuspectTier.geometry;
    if (reasons.isEmpty) {
      // ── B 档：语义 ──
      // 窄行：厚度 < 0.65×页面中位 → 疑似一列被拆成两行（也可能真是
      // 夹注窄列——交给视觉模型看图确认，不自动并，避免误并真双列）。
      if (medianCross > 0 &&
          ann.lines.length >= 4 &&
          _lineCrossAxis(line) < 0.65 * medianCross) {
        reasons.add('行宽异常窄（疑一列被拆两行）');
      }
      final n = line.chars.length;
      final lowConf = line.chars.where((c) => (c.conf ?? 1.0) < 0.55).length;
      if (lowConf > 0) reasons.add('$lowConf 个低置信度字');
      final disagree = line.chars
          .where(
            (c) =>
                c.agree == 'conflict' ||
                c.agree == 'box_multi' ||
                c.agree == 'none',
          )
          .length;
      if (n >= 3 && disagree / n > 0.3) reasons.add('两路识别分歧 $disagree/$n');
      final verifyBad = line.chars
          .where(
            (c) => c.verifyLevel == 'mismatch' || c.verifyLevel == 'suspect',
          )
          .length;
      if (verifyBad > 0) reasons.add('$verifyBad 个墨迹校验存疑');
      if (reasons.isEmpty) continue;
      tier = BoxSuspectTier.semantic;
    }
    out.add(
      BoxSuspect(
        line: line,
        tier: tier,
        reasons: reasons,
        geometryExpectedCount: expected > 0 ? expected : null,
        overlapPartner: duplicate == null ? partner : null,
        duplicatePartner: duplicate,
        contentFloor: contentFloor > 0 ? contentFloor : null,
      ),
    );
  }
  return out;
}

/// 组装视觉模型诊断用的逐字信息（序号/字/置信度/相对尺寸）。
List<({int order, String text, double conf, double relSize})> diagnosisCharsOf(
  LineBlock line,
) {
  final median = _medianAlongAxis(line);
  // 先按 order 排序再从 1 连续重编号：手工编辑过的行 order 可能乱序/
  // 跳号，原样给 AI 会让文字编号与行条图上的框序号（叠加层按数组顺序
  // 编号）对不上——模型报 pos 就会指错框。
  final sorted = List<CharBlock>.from(line.chars)
    ..sort((a, b) => a.order.compareTo(b.order));
  return [
    for (var i = 0; i < sorted.length; i++)
      (
        order: i + 1,
        text: sorted[i].text,
        conf: sorted[i].conf ?? 0.5,
        relSize: median > 0
            ? _alongAxis(sorted[i], line.orientation) / median
            : 1.0,
      ),
  ];
}

// ── 裁决（纯函数）──

/// 行质量分：mean conf − 分歧/低分/高框惩罚 + 两路一致奖励。
/// before/after 用同一把尺子量；无 conf 数据（旧标注）按 0.5 中性计。
double lineScore(List<CharBlock> chars, String orientation) {
  if (chars.isEmpty) return 0;
  final confs = [
    for (final c in chars)
      if (c.conf != null) c.conf!,
  ];
  final meanConf = confs.isEmpty
      ? 0.5
      : confs.reduce((a, b) => a + b) / confs.length;
  final n = chars.length;
  final disagree = chars
      .where(
        (c) =>
            c.agree == 'conflict' ||
            c.agree == 'box_multi' ||
            c.agree == 'none',
      )
      .length;
  final low = chars.where((c) => (c.conf ?? 1.0) < 0.55).length;
  final sizes = [for (final c in chars) _alongAxis(c, orientation)]..sort();
  final mid = sizes.length ~/ 2;
  final median = sizes.isEmpty
      ? 0.0
      : (sizes.length.isOdd
            ? sizes[mid].toDouble()
            : (sizes[mid - 1] + sizes[mid]) / 2.0);
  final tall = median <= 0
      ? 0
      : chars
            .where((c) => _alongAxis(c, orientation) > median * 1.18 + 5)
            .length;
  final both = chars.where((c) => c.agree == 'both').length;
  return meanConf -
      0.15 * disagree / n -
      0.10 * low / n -
      0.10 * tall / n +
      0.10 * both / n;
}

/// 重摆结果的基本合理性（防“更整齐但更错”的退化结果被采纳）：
/// 每行有字、字数不超物理上限（沿轴长度 ÷ 6px）。相邻列允许安全
/// 几何交集，不能用“必须零重叠”把真实字形裁窄。
bool sanityOk(List<LineBlock> lines) {
  if (lines.isEmpty) return false;
  var totalChars = 0;
  for (final l in lines) {
    if (l.chars.isEmpty) return false;
    final axis = _lineAlongAxis(l);
    if (l.chars.length * 6 > axis + 20) return false;
    totalChars += l.chars.length;
  }
  if (totalChars > 500) return false;
  return true;
}

/// 采纳门槛：B 档（VLM 诊断重摆）要求质量分净提升；A 档传更低的
/// margin（几何收益本身不在分数里，质量不暴跌即可）。
const double kAdoptMargin = 0.03;

/// A 档容差：几何修复（重叠消除/字数恢复）的正收益不计入 lineScore，
/// 只要文本质量不明显劣化（> −0.05）即采纳。
const double kGeometryMargin = -0.05;

/// 采纳判定（两档共用）：结果合理 + 内容守恒（新字数 ≥ [minNewCount]
/// （默认旧的一半），挡住"1 个字吞掉整行"）且 ≤ 旧的 2 倍 + 4（挡住
/// 过度粉碎）+ 质量分过门槛 + 新字框无显著互相重叠（挡住区域重摆错位
/// 产出的叠框）。分歧率惩罚已计入 lineScore，不再单设硬闸
/// （诚实重读常带更多 conflict 标记，实测硬闸会把整体更好的结果也拒掉）。
bool shouldAdopt(
  List<CharBlock> oldChars,
  List<CharBlock> newChars,
  String orientation, {
  double margin = kAdoptMargin,
  int? minNewCount,
}) {
  if (!sanityOkChars(newChars, orientation)) return false;
  if (hasSignificantBoxOverlap(newChars)) return false;
  final oldN = oldChars.length;
  final newN = newChars.length;
  final floor = minNewCount ?? max(1, (oldN * 0.5).ceil());
  if (newN < floor) return false;
  if (newN > oldN * 2 + 4) return false;
  return lineScore(newChars, orientation) >
      lineScore(oldChars, orientation) + margin;
}

/// 字框两两显著重叠检测：任一对的交集面积占较小框超过 [fraction]
/// 视为重叠。正常相邻字框的安全边距交集很小（百分之几）；重摆区域
/// 选错（裁到邻列/邻行）或后端把多行结构摊平进一行时，会产出大量
/// 大面积互叠框——这类结果必须挡在采纳之外（实测表现为"重复出现
/// 大量重叠的单行识别框"）。O(n²)，每行几十框，代价可忽略。
bool hasSignificantBoxOverlap(List<CharBlock> chars, {double fraction = 0.30}) {
  for (var i = 0; i < chars.length; i++) {
    final a = chars[i];
    for (var j = i + 1; j < chars.length; j++) {
      final b = chars[j];
      final right = min(a.x + a.w, b.x + b.w);
      final left = max(a.x, b.x);
      final bottom = min(a.y + a.h, b.y + b.h);
      final top = max(a.y, b.y);
      final ix = right - left, iy = bottom - top;
      if (ix <= 0 || iy <= 0) continue;
      final minArea = min(a.w * a.h, b.w * b.h);
      if (minArea <= 0) continue;
      if (ix * iy / minArea > fraction) return true;
    }
  }
  return false;
}

bool sanityOkChars(List<CharBlock> chars, String orientation) {
  if (chars.isEmpty) return false;
  final axisSum = chars.fold<double>(
    0,
    (sum, c) => sum + _alongAxis(c, orientation),
  );
  // 沿轴总长与字数严重失配（每个字至少占 6px）视为退化结果。
  return chars.length * 6 <= axisSum + 40;
}

/// 重摆结果是否与原行"实质相同"：行数一致、矩形逐行差 ≤2px、字数与
/// 整行文本一致。后端在同一条链路上近乎相同输入的复检常返回这种结果
/// ——不是修复，调用方应按"保持原样"报告。
bool _materiallySame(List<LineBlock> oldLines, List<LineBlock> newLines) {
  if (oldLines.length != newLines.length) return false;
  for (var i = 0; i < oldLines.length; i++) {
    final a = oldLines[i], b = newLines[i];
    if ((a.x - b.x).abs() > 2 ||
        (a.y - b.y).abs() > 2 ||
        (a.w - b.w).abs() > 2 ||
        (a.h - b.h).abs() > 2) {
      return false;
    }
    if (a.chars.length != b.chars.length || a.text != b.text) return false;
  }
  return true;
}

// ── 单行闭环 ──

enum BoxReviewStatus {
  /// 重摆通过裁决，已采纳（newLines 待编辑器合回）。
  fixed,

  /// 重摆未过裁决，保持原样（不应用即回滚）。
  kept,

  /// 视觉模型认为该行没有问题。
  vlmOk,

  /// 执行失败（网络/后端/裁图失败等）。
  failed,

  /// 受保护（用户成果行），跳过。
  protected,

  /// 检查期间该行已被其他修复替换/更新（如重叠伴生行），本轮跳过。
  stale,
}

class LineReviewResult {
  const LineReviewResult({
    required this.status,
    required this.reason,
    required this.oldLine,
    this.newLines = const [],
    this.beforeScore = 0,
    this.afterScore = 0,
    this.replaceStub,
  });

  final BoxReviewStatus status;
  final String reason;
  final LineBlock oldLine;

  /// status == fixed 时的替换行（已 reid/重编由编辑器合回时处理）。
  final List<LineBlock> newLines;
  final double beforeScore;
  final double afterScore;

  /// 实际发给后端的重跑矩形（重叠行 = 两行并集；其余 = 原行框）。
  final LineBlock? replaceStub;
}

/// 单行检查执行器。网络依赖全部注入（测试可替换）；编辑器用真实
/// PythonService/OllamaService 构造。
class AiBoxReviewer {
  AiBoxReviewer({
    required this.fetchThumbnails,
    required this.resegment,
    this.diagnose,
  });

  /// 行条裁图（含字框叠加），见 PythonService.fetchLineThumbnails。
  final Future<List<String?>> Function(List<LineThumbRequest> items)
  fetchThumbnails;

  /// 行级重摆（/segment_region 不带 charBoxes）。实现方负责 409 重试。
  final Future<List<LineBlock>> Function(
    LineBlock stub, {
    int? expectedCharCount,
  })
  resegment;

  /// 视觉模型诊断；null = Ollama 不可用（B 档行直接 failed 并说明）。
  final Future<OllamaBoxDiagnosis> Function(String imageBase64, LineBlock line)?
  diagnose;

  /// 检查一行：可疑行分档执行 → 后端重摆 → 裁决。永不抛异常，失败
  /// 落 [LineReviewResult.failed]。
  Future<LineReviewResult> reviewLine(
    BoxSuspect suspect, {
    required String imagePath,
  }) async {
    final line = suspect.line;
    if (isProtectedLine(line)) {
      return LineReviewResult(
        status: BoxReviewStatus.protected,
        reason: '用户已校对的行，跳过',
        oldLine: line,
      );
    }
    // 空框：字框内无文字墨迹（/line_ink 实测）→ 直接删除，不调后端
    // （重摆会原样复检空白带）也不调视觉模型（对空白条的判断不可靠）。
    // newLines 为空 = 编辑器只移除旧行、不插入新行。
    if (suspect.blankInk) {
      return LineReviewResult(
        status: BoxReviewStatus.fixed,
        reason: '空框已删除（框内无文字墨迹，框上文字均为识别噪声）',
        oldLine: line,
        newLines: const [],
      );
    }
    LineBlock stub = line;
    int? expected;
    var vlmNote = '';
    if (suspect.tier == BoxSuspectTier.semantic) {
      final diag = diagnose;
      if (diag == null) {
        return LineReviewResult(
          status: BoxReviewStatus.failed,
          reason: '未配置 Ollama 视觉模型，语义档检查不可用',
          oldLine: line,
        );
      }
      try {
        final thumb = await _thumbOf(imagePath, line);
        if (thumb == null) {
          return LineReviewResult(
            status: BoxReviewStatus.failed,
            reason: '行条裁图失败',
            oldLine: line,
          );
        }
        final d = await diag(thumb, line);
        final issue = d.topIssue;
        if (issue == null || d.lineOk) {
          return LineReviewResult(
            status: BoxReviewStatus.vlmOk,
            reason: issue == null
                ? 'AI 认为该行没有问题'
                : 'AI 认为该行没有问题（${issue.note}）',
            oldLine: line,
          );
        }
        vlmNote = 'AI：${issue.note.isEmpty ? issue.type.wire : issue.note}';
        switch (issue.type) {
          case OllamaBoxIssueType.mergeTwoLines:
            // 双列拆分在 kraken_segment_rect 内置（行级阈值更宽），不带
            // 期望字数交给结构检测。
            expected = null;
          case OllamaBoxIssueType.missingChars:
          case OllamaBoxIssueType.charMerged:
            // 漏字/两字同框：真实字数比现框数多。
            expected = line.chars.length + 1;
          case OllamaBoxIssueType.charClipped:
          case OllamaBoxIssueType.charExtraInk:
            // 字数对、几何歪：按现字数重切。
            expected = line.chars.length;
        }
      } on OllamaException catch (e) {
        return LineReviewResult(
          status: BoxReviewStatus.failed,
          reason: 'AI 诊断失败：${e.message}',
          oldLine: line,
        );
      }
    } else {
      // A 档·重复行：同列重复检测的修复是删除较差的一条——纯前端操作，
      // 不调后端（后端重摆会原样复检同样的条带，修不掉重复）。
      final dup = suspect.duplicatePartner;
      if (dup != null) {
        final keep =
            lineScore(line.chars, line.orientation) >=
                lineScore(dup.chars, dup.orientation)
            ? line
            : dup;
        return LineReviewResult(
          status: BoxReviewStatus.fixed,
          reason: '删除重复行（两条行盖同一列文字，保留识别质量更好的一条）',
          oldLine: line,
          newLines: [keep],
          beforeScore: lineScore(line.chars, line.orientation),
          afterScore: lineScore(keep.chars, keep.orientation),
        );
      }
      // A 档·其余几何：重叠行取并集矩形重跑（覆盖两行的区域重新分行）。
      final partner = suspect.overlapPartner;
      if (partner != null) {
        final x = min(line.x, partner.x);
        final y = min(line.y, partner.y);
        stub = LineBlock(
          id: line.id,
          x: x,
          y: y,
          w: max(line.x + line.w, partner.x + partner.w) - x,
          h: max(line.y + line.h, partner.y + partner.h) - y,
          lineNo: min(line.lineNo, partner.lineNo),
          orientation: line.orientation,
        );
      }
      expected = suspect.geometryExpectedCount;
    }

    final before = lineScore(line.chars, line.orientation);
    try {
      final newLines = await resegment(stub, expectedCharCount: expected);
      final newChars = [for (final l in newLines) ...l.chars];
      final after = lineScore(newChars, line.orientation);
      // 实质变化检查：后端在几乎相同输入上重跑同一条链路，常原样复检
      // （几何/字数/文本都不变）——那不是修复，如实报告为"保持原样"，
      // 避免报告写着"修复 N"而画面毫无变化。
      final oldLines = [
        line,
        if (suspect.overlapPartner != null) suspect.overlapPartner!,
      ];
      if (_materiallySame(oldLines, newLines)) {
        return LineReviewResult(
          status: BoxReviewStatus.kept,
          reason: '重摆复检结果与原框相同（后端维持原切分），保持原样',
          oldLine: line,
          beforeScore: before,
          afterScore: after,
          replaceStub: stub,
        );
      }
      // A 档的收益是几何本身（重叠消除/字数恢复），质量分不暴跌即可；
      // B 档（VLM 诊断）要求质量分净提升。两档都有内容守恒闸。
      final margin = suspect.tier == BoxSuspectTier.geometry
          ? kGeometryMargin
          : kAdoptMargin;
      if (shouldAdopt(
        line.chars,
        newChars,
        line.orientation,
        margin: margin,
        minNewCount: suspect.contentFloor,
      )) {
        return LineReviewResult(
          status: BoxReviewStatus.fixed,
          reason: vlmNote.isEmpty
              ? suspect.reasons.join('；')
              : '${suspect.reasons.join('；')}｜$vlmNote',
          oldLine: line,
          newLines: newLines,
          beforeScore: before,
          afterScore: after,
          replaceStub: stub,
        );
      }
      return LineReviewResult(
        status: BoxReviewStatus.kept,
        reason:
            '重摆后质量分未提升'
            '（${before.toStringAsFixed(2)} → ${after.toStringAsFixed(2)}），保持原样',
        oldLine: line,
        beforeScore: before,
        afterScore: after,
        replaceStub: stub,
      );
    } catch (e) {
      return LineReviewResult(
        status: BoxReviewStatus.failed,
        reason: '重摆失败：$e',
        oldLine: line,
        beforeScore: before,
        replaceStub: stub,
      );
    }
  }

  Future<String?> _thumbOf(String imagePath, LineBlock line) async {
    // 叠加框按阅读序排序：后端按数组顺序给框编号，必须与
    // diagnosisCharsOf 的 1 基连续编号同序，AI 报的 pos 才能对上框。
    final sorted = List<CharBlock>.from(line.chars)
      ..sort((a, b) => a.order.compareTo(b.order));
    final thumbs = await fetchThumbnails([
      LineThumbRequest(
        imagePath: imagePath,
        x: line.x,
        y: line.y,
        w: line.w,
        h: line.h,
        orientation: line.orientation,
        boxes: [for (final c in sorted) (c.x, c.y, c.w, c.h)],
      ),
    ]);
    return thumbs.isEmpty ? null : thumbs.first;
  }
}
