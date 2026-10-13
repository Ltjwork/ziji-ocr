import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../services/python_service.dart';
import '../services/storage.dart';
import 'book_region_grid_page.dart';

/// 「按参考页适配」执行统计（返回给网格页汇总提示用）。
class ReferenceApplyStats {
  const ReferenceApplyStats({
    required this.referenceIndex,
    required this.labelsDesc,
    required this.scopeDesc,
    required this.applied,
    required this.emptySkipped,
    required this.inkFailures,
    required this.failed,
    required this.cancelled,
  });

  final int referenceIndex;
  final String labelsDesc;
  final String scopeDesc;

  /// 成功适配的页数（含内容本来就没有变化、未写盘的页——应用幂等）。
  final int applied;

  /// 墨迹判空跳过的框数（该页没有这个页眉/页脚/页码）。
  final int emptySkipped;

  /// 墨迹检测失败的页数（保守保留了框）。
  final int inkFailures;
  final int failed;
  final bool cancelled;
}

/// 适配范围。
enum ReferenceApplyScope {
  /// 仅未确认的页面（跳过绿色"已确认"角标）。
  unconfirmed,

  /// 全部页面（含主区已确认页；校对完成的页仍恒跳过）。
  all,

  /// 指定页范围（1~pageCount，含两端；同样套用保护口径）。
  range,
}

/// 单页保存回调（网格页 [_saveRegion] 的 batch 包装）：[mainRects] 为
/// null = 不动主区；返回 false = 写盘失败。
typedef ReferenceApplySave =
    Future<bool> Function(
      int index,
      List<Rect>? mainRects,
      Map<String, List<Rect>> extras,
    );

/// 「按参考页适配」的纯逻辑本体（供单测，与
/// [BookRegionGridPage.splitTargetsFrom] 同一惯例）。
class ReferenceApply {
  /// 适配目标页：
  /// 恒跳过参考页本身、校对完成的页（整页绿框「确认并保存」/玫红框
  /// 「确认识别框」/旧版 reviewed——校对成果不因批量改框被动）与「确认
  /// 无正文」的页（扉页/插图，人工已判无正文）；[unconfirmedOnly] 再剔
  /// 除主区已确认（绿色角标）的页；[rangeFirst]/[rangeLast]（0 基、含两
  /// 端）限定页范围。返回 (目标页, 校对完成跳过数)。
  static (List<int>, int) targetsFor(
    Map<int, PageAnnotation> annotations,
    int pageCount,
    int refIndex,
    bool unconfirmedOnly, {
    int? rangeFirst,
    int? rangeLast,
  }) {
    final targets = <int>[];
    var proofreadSkip = 0;
    for (var i = 0; i < pageCount; i++) {
      if (i == refIndex) continue;
      if (rangeFirst != null && i < rangeFirst) continue;
      if (rangeLast != null && i > rangeLast) continue;
      final ann = annotations[i];
      if (ann != null &&
          (ann.isFullyConfirmed || ann.boxesReviewed || ann.reviewed)) {
        proofreadSkip++;
        continue;
      }
      if (ann?.noMainTextConfirmed == true) continue;
      if (unconfirmedOnly && BookRegionGridPage.pageRegionConfirmed(ann)) {
        continue;
      }
      targets.add(i);
    }
    return (targets, proofreadSkip);
  }

  /// 参考页矩形 → 目标页矩形：同一本书版式一致，按两页宽高各自比例线性
  /// 映射（分辨率/摆正后的尺寸差异由此吸收；尺寸未知按同尺寸，恒等）。
  static Rect mapRect(Rect rect, Size? from, Size? to) {
    if (from == null ||
        to == null ||
        from.isEmpty ||
        to.isEmpty ||
        (from.width == to.width && from.height == to.height)) {
      return rect;
    }
    final sx = to.width / from.width;
    final sy = to.height / from.height;
    return Rect.fromLTWH(
      rect.left * sx,
      rect.top * sy,
      rect.width * sx,
      rect.height * sy,
    );
  }
}

/// 对话框确认结果（null = 取消）。
typedef ReferenceApplyConfig =
    ({
      int refIndex,
      Set<String> labels,
      ReferenceApplyScope scope,
      int rangeFirst,
      int rangeLast,
      bool inkCheck,
    });

/// 「按参考页适配」对话框 + 批量应用（主区快设底部入口）：选一页已画好
/// 版面区的页做参考，把它各类区域框（正文/页眉/页脚/页码…，可勾选）按
/// 页面尺寸比例复制到其他页——同一本书的扫描页版式一致，页大小不一
/// （分辨率/摆正差异）时按宽高分别线性缩放吸收。**只写框、绝不触发识
/// 别、不自动确认**（结果为待确认候选，由用户逐页核对后自己确认）；
/// 非正文类框逐页做墨迹判空（[PythonService.measureRegionInk]）：该页
/// 这个位置没有页眉/页脚/页码的，框不落。
///
/// 目标页保护：参考页本身、校对完成的页（整页绿框「确认并保存」/玫红
/// 框「确认识别框」/旧版 reviewed）、「确认无正文」的页（扉页/插图）
/// 任何范围下都跳过。
///
/// 返回 null = 没有可用参考页或用户取消配置（无参考页时本函数自己提
/// 示）；否则返回统计，由调用方弹汇总 SnackBar。
Future<ReferenceApplyStats?> showReferenceApplyAndRun({
  required BuildContext context,
  required Project project,
  required Map<int, PageAnnotation> annotations,
  required Map<int, Size> pageSizes,
  required ReferenceApplySave savePage,
}) async {
  final pageCount = project.imageFiles.length;
  // 候选参考页：画过任一版面区的页。
  final candidates = <int>[
    for (var i = 0; i < pageCount; i++)
      if ((annotations[i]?.mainRegions ?? const <MainRegion>[]).isNotEmpty) i,
  ];
  if (candidates.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('还没有画过版面区的页可作参考；先在某页画好正文/页眉/页脚'),
      ),
    );
    return null;
  }
  final config = await showDialog<ReferenceApplyConfig>(
    context: context,
    builder: (_) => _ReferenceApplyDialog(
      candidates: candidates,
      annotations: annotations,
      pageCount: pageCount,
    ),
  );
  if (config == null || !context.mounted) return null;
  final (
    :refIndex,
    :labels,
    :scope,
    :rangeFirst,
    :rangeLast,
    :inkCheck,
  ) = config;

  // 参考页矩形读盘（网格快照建立后校对页级联 flush 可能落过盘，动作时
  // 刻以盘为准）；页大小探不到时按同尺寸处理（映射即恒等）。
  final refAnn =
      await ProjectStorage.loadAnnotation(
        project.projectDir,
        project.pageIdAt(refIndex),
      ) ??
      annotations[refIndex];
  if (!context.mounted || refAnn == null || refAnn.mainRegions.isEmpty) {
    return null;
  }
  final rectsByLabel = <String, List<Rect>>{};
  for (final r in refAnn.mainRegions) {
    (rectsByLabel[RegionLabel.normalize(r.label)] ??= []).add(r.rect);
  }
  final labelsDesc = [
    for (final label in RegionLabel.all)
      if (labels.contains(label)) RegionLabel.displayName(label),
  ].join('、');
  final scopeDesc = switch (scope) {
    ReferenceApplyScope.unconfirmed => '仅未确认页',
    ReferenceApplyScope.all => '全部页面',
    ReferenceApplyScope.range => '第 ${rangeFirst + 1}~${rangeLast + 1} 页',
  };
  final (targets, proofreadSkip) = ReferenceApply.targetsFor(
    annotations,
    pageCount,
    refIndex,
    scope == ReferenceApplyScope.unconfirmed,
    rangeFirst: scope == ReferenceApplyScope.range ? rangeFirst : null,
    rangeLast: scope == ReferenceApplyScope.range ? rangeLast : null,
  );
  PythonService.addAppLog(
    '[主区快设] 按参考页适配开始：参考第 ${refIndex + 1} 页'
    '（$labelsDesc），范围=$scopeDesc，目标 ${targets.length} 页'
    '${inkCheck ? '，非正文框逐页墨迹判空' : ''}'
    '${proofreadSkip > 0 ? '，校对完成跳过 $proofreadSkip 页' : ''}',
  );

  final refSize = pageSizes[refIndex];
  var cancel = false;
  var applied = 0;
  var failed = 0;
  var emptySkipped = 0;
  var inkFailures = 0;
  var done = 0;
  StateSetter? setProgress;
  final progressFuture = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => PopScope(
      canPop: false,
      child: StatefulBuilder(
        builder: (dialogContext, setStateInDialog) {
          setProgress = setStateInDialog;
          return AlertDialog(
            title: const Text('按参考页适配'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(
                  value: targets.isEmpty ? 1 : done / targets.length,
                ),
                const SizedBox(height: 12),
                Text(
                  '参考第 ${refIndex + 1} 页 · 已完成 $done / ${targets.length}',
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 4),
                Text(
                  inkCheck ? '页眉/页脚/页码逐页判空中（无内容的不落框）' : '只写框，不识别、不自动确认',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  cancel = true;
                  Navigator.of(dialogContext).pop();
                },
                child: const Text('停止'),
              ),
            ],
          );
        },
      ),
    ),
  );

  for (var k = 0; k < targets.length; k++) {
    if (cancel) break;
    final i = targets[k];
    done = k;
    setProgress?.call(() {});
    final targetSize = pageSizes[i] ?? refSize;
    var extras = <String, List<Rect>>{};
    for (final label in labels) {
      if (label == RegionLabel.mainText) continue;
      final rects = rectsByLabel[label];
      if (rects == null) continue;
      extras[label] = [
        for (final r in rects) ReferenceApply.mapRect(r, refSize, targetSize),
      ];
    }
    // 墨迹判空：非正文框逐个测（同页一批）。检测失败（null/异常）保守
    // 保留框——宁可多落一个人工删，不能把真页眉漏掉。
    if (inkCheck && extras.isNotEmpty) {
      final flat = <(String, Rect)>[
        for (final e in extras.entries)
          for (final r in e.value) (e.key, r),
      ];
      try {
        final inks = await PythonService.measureRegionInk(
          project.imageFiles[i],
          [for (final t in flat) t.$2],
        );
        final kept = <String, List<Rect>>{};
        for (var n = 0; n < flat.length; n++) {
          final ink = n < inks.length ? inks[n] : null;
          if (ink != null &&
              ink < PythonService.regionInkEmptyThreshold) {
            emptySkipped++;
            continue; // 该页这个位置没有页眉/页脚/页码
          }
          (kept[flat[n].$1] ??= []).add(flat[n].$2);
        }
        extras = kept;
      } catch (_) {
        inkFailures++; // 后端不可达等：本页判空跳过，框照常落
      }
    }
    final mains = labels.contains(RegionLabel.mainText)
        ? [
            for (final r in rectsByLabel[RegionLabel.mainText] ?? const <Rect>[])
              ReferenceApply.mapRect(r, refSize, targetSize),
          ]
        : null;
    if (await savePage(i, mains, extras)) {
      applied++;
    } else {
      failed++;
    }
  }
  done = targets.length;
  if (!cancel && context.mounted) {
    Navigator.of(context).pop();
  }
  await progressFuture;
  PythonService.addAppLog(
    '[主区快设] 按参考页适配结束${cancel ? '（用户停止）' : ''}：'
    '$applied 页，判空跳过 $emptySkipped 框'
    '${inkFailures > 0 ? '，$inkFailures 页判空失败（框保守保留）' : ''}'
    '${failed > 0 ? '，写盘失败 $failed 页' : ''}',
  );
  return ReferenceApplyStats(
    referenceIndex: refIndex,
    labelsDesc: labelsDesc,
    scopeDesc: scopeDesc,
    applied: applied,
    emptySkipped: emptySkipped,
    inkFailures: inkFailures,
    failed: failed,
    cancelled: cancel,
  );
}

/// 配置对话框（参考页 / 复制类别 / 范围 / 判空开关）。
class _ReferenceApplyDialog extends StatefulWidget {
  const _ReferenceApplyDialog({
    required this.candidates,
    required this.annotations,
    required this.pageCount,
  });

  final List<int> candidates;
  final Map<int, PageAnnotation> annotations;
  final int pageCount;

  @override
  State<_ReferenceApplyDialog> createState() => _ReferenceApplyDialogState();
}

class _ReferenceApplyDialogState extends State<_ReferenceApplyDialog> {
  late int _refIndex;
  late Set<String> _labels;
  ReferenceApplyScope _scope = ReferenceApplyScope.unconfirmed;
  bool _inkCheck = true;
  final _rangeFrom = TextEditingController();
  final _rangeTo = TextEditingController();

  @override
  void initState() {
    super.initState();
    // 默认参考页：第一条主区已确认的页（"设定完的页"），否则第一候选。
    _refIndex = widget.candidates.firstWhere(
      (i) => BookRegionGridPage.pageRegionConfirmed(widget.annotations[i]),
      orElse: () => widget.candidates.first,
    );
    _labels = _labelsOf(widget.annotations[_refIndex]);
    _rangeFrom.text = '1';
    _rangeTo.text = '${widget.pageCount}';
  }

  @override
  void dispose() {
    _rangeFrom.dispose();
    _rangeTo.dispose();
    super.dispose();
  }

  /// 范围输入 → 0 基含两端区间；不完整/非法返回 null。
  (int, int)? get _range {
    final from = int.tryParse(_rangeFrom.text.trim());
    final to = int.tryParse(_rangeTo.text.trim());
    if (from == null || to == null) return null;
    final first = from.clamp(1, widget.pageCount);
    final last = to.clamp(1, widget.pageCount);
    return first <= last ? (first - 1, last - 1) : (last - 1, first - 1);
  }

  (List<int>, int) _targetsFor(ReferenceApplyScope scope) {
    final range = _range;
    return ReferenceApply.targetsFor(
      widget.annotations,
      widget.pageCount,
      _refIndex,
      scope == ReferenceApplyScope.unconfirmed,
      rangeFirst: scope == ReferenceApplyScope.range ? range?.$1 : null,
      rangeLast: scope == ReferenceApplyScope.range ? range?.$2 : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final refCounts = _labelCounts(widget.annotations[_refIndex]);
    final unconfirmedCount = _targetsFor(
      ReferenceApplyScope.unconfirmed,
    ).$1.length;
    final allCount = _targetsFor(ReferenceApplyScope.all);
    final rangeCount = _scope == ReferenceApplyScope.range
        ? _targetsFor(ReferenceApplyScope.range).$1.length
        : null;
    final targets = _targetsFor(_scope);
    final valid = targets.$1.isNotEmpty && _labels.isNotEmpty;
    return AlertDialog(
      title: const Text('按参考页适配'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionLabel('参考页'),
            DropdownButtonFormField<int>(
              isExpanded: true,
              initialValue: _refIndex,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
              ),
              items: [
                for (final i in widget.candidates)
                  DropdownMenuItem(
                    value: i,
                    child: Text(
                      _refPageLabel(i, widget.annotations[i]),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
              ],
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  _refIndex = value;
                  _labels = _labelsOf(widget.annotations[_refIndex]);
                });
              },
            ),
            const SizedBox(height: 12),
            _sectionLabel('复制类别'),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 2,
              children: [
                for (final label in RegionLabel.all)
                  if (refCounts.containsKey(label))
                    FilterChip(
                      avatar: Icon(
                        Icons.circle,
                        size: 10,
                        color: RegionLabel.color(label),
                      ),
                      label: Text(
                        '${RegionLabel.displayName(label)}×${refCounts[label]}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      selected: _labels.contains(label),
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      onSelected: (on) => setState(() {
                        on ? _labels.add(label) : _labels.remove(label);
                      }),
                    ),
              ],
            ),
            const SizedBox(height: 12),
            _sectionLabel('适配范围'),
            RadioGroup<ReferenceApplyScope>(
              groupValue: _scope,
              onChanged: (v) => setState(() => _scope = v ?? _scope),
              child: Column(
                children: [
                  RadioListTile<ReferenceApplyScope>(
                    value: ReferenceApplyScope.unconfirmed,
                    title: const Text(
                      '仅未确认的页面',
                      style: TextStyle(fontSize: 13),
                    ),
                    subtitle: Text('$unconfirmedCount 页', style: _subStyle),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  RadioListTile<ReferenceApplyScope>(
                    value: ReferenceApplyScope.all,
                    title: const Text(
                      '全部页面（含已确认页）',
                      style: TextStyle(fontSize: 13),
                    ),
                    subtitle: Text(
                      '${allCount.$1.length} 页'
                      '${allCount.$2 > 0 ? '，校对完成 ${allCount.$2} 页恒跳过' : ''}',
                      style: _subStyle,
                    ),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  RadioListTile<ReferenceApplyScope>(
                    value: ReferenceApplyScope.range,
                    title: const Text('指定范围', style: TextStyle(fontSize: 13)),
                    subtitle:
                        _scope == ReferenceApplyScope.range && rangeCount != null
                        ? Text('$rangeCount 页（范围同样跳过校对完成的页）',
                            style: _subStyle)
                        : null,
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  if (_scope == ReferenceApplyScope.range)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Row(
                        children: [
                          _rangeField(_rangeFrom, '起始页'),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: Text('～', style: TextStyle(fontSize: 13)),
                          ),
                          _rangeField(_rangeTo, '结束页'),
                          const Spacer(),
                          Text(
                            '共 ${widget.pageCount} 页',
                            style: _subStyle,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            CheckboxListTile(
              value: _inkCheck,
              onChanged: (v) => setState(() => _inkCheck = v ?? true),
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                '逐页判空：页眉/页脚/页码位置无墨迹的框不落（正文框不受影响）',
                style: TextStyle(fontSize: 13),
              ),
            ),
            const Divider(height: 10),
            Text(
              '适配只写框、不识别，结果为待确认候选（不自动确认）；'
              '参考页本身与「确认无正文」的页不会被改。',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: valid ? () => _start() : null,
          child: Text(
            targets.$1.isEmpty ? '没有可适配的页' : '开始适配 ${targets.$1.length} 页',
          ),
        ),
      ],
    );
  }

  TextStyle? get _subStyle => TextStyle(fontSize: 12, color: Colors.grey.shade600);

  static const TextStyle _sectionStyle = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
  );

  Widget _sectionLabel(String text) => Text(text, style: _sectionStyle);

  Widget _rangeField(TextEditingController controller, String hint) => SizedBox(
    width: 90,
    height: 36,
    child: TextField(
      controller: controller,
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      style: const TextStyle(fontSize: 13),
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      onChanged: (_) => setState(() {}),
    ),
  );

  void _start() {
    final range = _range;
    Navigator.of(context).pop((
      refIndex: _refIndex,
      labels: Set<String>.of(_labels),
      scope: _scope,
      rangeFirst:
          _scope == ReferenceApplyScope.range ? range?.$1 ?? 0 : 0,
      rangeLast:
          _scope == ReferenceApplyScope.range
          ? range?.$2 ?? (widget.pageCount - 1)
          : widget.pageCount - 1,
      inkCheck: _inkCheck,
    ));
  }
}

/// 某页各类区域的框数（label → 数量，只列画过的类）。
Map<String, int> _labelCounts(PageAnnotation? ann) {
  final counts = <String, int>{};
  for (final r in ann?.mainRegions ?? const <MainRegion>[]) {
    final label = RegionLabel.normalize(r.label);
    counts[label] = (counts[label] ?? 0) + 1;
  }
  return counts;
}

/// 参考页当前画过的类别（切换参考页时类别勾选重置为全选）。
Set<String> _labelsOf(PageAnnotation? ann) => _labelCounts(ann).keys.toSet();

/// 参考页下拉项文案：第 N 页 · 正文×2 · 页眉×1 …（已确认）。
String _refPageLabel(int index, PageAnnotation? ann) {
  final counts = _labelCounts(ann);
  final desc = [
    for (final label in RegionLabel.all)
      if (counts.containsKey(label))
        '${RegionLabel.displayName(label)}×${counts[label]}',
  ].join(' · ');
  final confirmed =
      BookRegionGridPage.pageRegionConfirmed(ann) ? ' · 已确认' : '';
  return '第 ${index + 1} 页 · $desc$confirmed';
}
