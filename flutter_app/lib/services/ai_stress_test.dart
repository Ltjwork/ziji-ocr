// -*- coding: utf-8 -*-
// AI 并行数压力测试：自动阶梯爬坡，测出本机可稳定承载的 AI 并发数。
//
// 探针是真实形态的整行裁决请求（合成行图+单字图、真实 prompt、输出
// 上限 256）——极小无图请求测不出视觉编码耗时与显存占用，测出来的
// 数会偏乐观。爬坡不看任何手填值：先发 1 条预热（把模型加载算进去，
// 不计档），再从 k=1 逐档自动加并发，每档同时发 k 条，全部成功且
// 最长耗时 ≤ 单条基准×3+15 秒才算该档通过——判据识破服务端排队串行
// （真并发下 k 条几乎同时完成；串行队列里最后一条要等前面跑完，耗时
// 近似 ×k），"排队轮完"不再算过。任一失败/超时/排队即停，实测上限
// ＝上一档；一路全过则到绝对上限 32 为止。护栏：逐档递增绝不满额发
// 起、总时长上限 10 分钟、显存占用 ≥95% 立即中止、可随时取消——不
// 会把软件或电脑压死。
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart'
    show TextPainter, TextSpan, TextStyle;

import 'ollama_service.dart';
import 'ai_concurrency.dart';
import 'python_service.dart';

/// 压测进度（进度框展示用）。
@immutable
class AiStressProgress {
  const AiStressProgress({
    required this.step,
    required this.cap,
    required this.maxStable,
    required this.message,
  });

  /// 当前测试档位（并发 k 条）；0 = 预热阶段。
  final int step;
  final int cap;

  /// 已确认稳定的最高档；0 = 还没有档通过。
  final int maxStable;
  final String message;
}

/// 显存看门狗阈值：占用比例达到该值立即中止爬坡。
const double aiStressVramGuard = 0.95;

/// 排队串行判据倍数：并发档最长单条耗时超过「单条基准 × 该倍数 +
/// [aiStressLatencySlack]」视为被服务端排队串行。真并发下 k 条几乎
/// 同时完成；串行队列里第 k 条要等前面跑完，耗时近似 ×k（未设
/// OLLAMA_NUM_PARALLEL 的 Ollama 常见）。取 3：容忍算力分摊造成的
/// 合理变慢，拦住纯排队。
const int aiStressLatencyFactor = 3;

/// 排队判据的绝对宽限：基准很短时（快卡）纯倍数太苛刻，补 15 秒。
const Duration aiStressLatencySlack = Duration(seconds: 15);

String _sec(Duration d) => (d.inMilliseconds / 1000).toStringAsFixed(1);

class AiStressTester {
  /// 阶梯爬坡。probe 由调用方注入（真实实现见 [AiStressProbe]，测试
  /// 注入假实现）：成功返回该条耗时，失败/超时返回 null；vramRatio
  /// 返回 0~1 或 null（不可用）。自动从 1 爬到测出真实上限——不接收
  /// 任何手填目标值，[hardCap] 只是绝对安全上限。
  ///
  /// [prepareLevel]：每档开测前调用（Kraken 进程数压测用它先把进程池
  /// 重建到 k 个并等就绪），返回 false = 该档达不到，上限停在上一档；
  /// AI 并行压测不传，行为不变。[levelLabel] 自定义每档的进度文案主语
  /// （默认"并发 k 条"）。[warmupFailHint] 覆盖预热失败的提示文案。
  static Future<AiStressResult> run({
    required String model,
    required Future<Duration?> Function() probe,
    Future<double?> Function()? vramRatio,
    bool Function()? isCancelled,
    void Function(AiStressProgress p)? onProgress,
    Duration totalBudget = const Duration(minutes: 10),
    int hardCap = 32,
    Future<bool> Function(int level)? prepareLevel,
    String Function(int level)? levelLabel,
    String? warmupFailHint,
  }) async {
    final cap = hardCap;
    var maxStable = 0;
    String? abortReason;
    final watch = Stopwatch()..start();

    // 取消/时长/显存三道护栏：预热前查一次，之后每档开测前都查。
    Future<bool> tripped() async {
      if (isCancelled?.call() ?? false) {
        abortReason = '用户取消（已测到 $maxStable 条）';
        return true;
      }
      if (watch.elapsed > totalBudget) {
        abortReason =
            '达到测试时长上限（${totalBudget.inMinutes} 分钟），'
            '以已测到的 $maxStable 条为准';
        return true;
      }
      final ratio = await vramRatio?.call();
      if (ratio != null && ratio >= aiStressVramGuard) {
        abortReason =
            '显存占用已达 ${(ratio * 100).round()}%，触发保护中止'
            '（已测到 $maxStable 条）';
        return true;
      }
      return false;
    }

    if (await tripped()) return _finish(model, maxStable, abortReason, hardCap);
    // 预热：第一次请求含模型加载（大模型可达几十秒），不能当并发基准。
    onProgress?.call(
      AiStressProgress(
        step: 0,
        cap: cap,
        maxStable: 0,
        message: '正在预热：加载模型并发 1 条真实行请求…',
      ),
    );
    if (await probe() == null) {
      return AiStressResult(
        // 一条都跑不动时钳到 1（保底不除零），reason 已说明。
        maxStable: 1,
        model: model,
        testedAt: DateTime.now(),
        abortedReason: warmupFailHint ??
            '预热请求就失败——请先确认推理服务（Ollama/外部 API）'
                '与所选模型可用',
      );
    }
    // k=1（已预热）的单条耗时基准，排队判据以它为尺度。
    Duration? baseline;
    for (var k = 1; k <= cap; k++) {
      if (await tripped()) break;
      final label = levelLabel?.call(k) ?? '并发 $k 条';
      onProgress?.call(
        AiStressProgress(
          step: k,
          cap: cap,
          maxStable: maxStable,
          message: baseline == null
              ? '正在测试$label…'
              : '正在测试$label（单条基准 ${_sec(baseline)} 秒）…',
        ),
      );
      if (prepareLevel != null && !(await prepareLevel(k))) {
        abortReason =
            '第 $k 档准备未就绪，上限为上一档（$maxStable ${maxStable > 0 ? '个' : ''}）';
        break;
      }
      // k 个探针同时发出；单探针失败/超时都算该档失败。
      final outcomes = await Future.wait([for (var i = 0; i < k; i++) probe()]);
      if (outcomes.any((t) => t == null)) {
        abortReason = maxStable == 0
            ? '并发 1 条都失败——请先确认推理服务（Ollama/外部 API）'
                  '与所选模型可用'
            : '并发 $k 条出现失败/超时，上限为上一档（$maxStable 条）';
        break;
      }
      final longest = outcomes.cast<Duration>().reduce((a, b) => a > b ? a : b);
      if (baseline != null &&
          longest > baseline * aiStressLatencyFactor + aiStressLatencySlack) {
        abortReason =
            '并发 $k 条被服务端排队串行（单条基准 ${_sec(baseline)} 秒'
            ' → 并发最长 ${_sec(longest)} 秒），上限为上一档（$maxStable 条）';
        break;
      }
      if (k == 1) baseline = longest;
      maxStable = k;
      onProgress?.call(
        AiStressProgress(
          step: k,
          cap: cap,
          maxStable: maxStable,
          message: '$label 稳定 ✓',
        ),
      );
    }
    return _finish(model, maxStable, abortReason, hardCap);
  }

  static AiStressResult _finish(
    String model,
    int maxStable,
    String? abortReason,
    int hardCap,
  ) => AiStressResult(
    // 一条都跑不动时钳到 1（保底不除零），reason 已说明。
    maxStable: maxStable.clamp(1, hardCap),
    model: model,
    testedAt: DateTime.now(),
    abortedReason: abortReason,
  );
}

/// 真实探针实现。
class AiStressProbe {
  /// 真实形态探针：合成 1 张竖排整行条图 + [glyphs] 张单字图（渲染一次、
  /// 全部探针复用），每条走 [OllamaService.lineStressProbe]（与整行裁决
  /// 同款 prompt/通道，不过限流器）。图片只要像素量级贴近真实裁图——
  /// 视觉编码的耗时与显存随像素走，内容语义无关紧要。
  static Future<Future<Duration?> Function()> realLine(
    OllamaSettings settings,
    String model, {
    List<String> glyphs = const ['天', '地', '玄'],
  }) async {
    final line = await _textStripPng(glyphs);
    final chars = <String>[];
    for (final g in glyphs) {
      final b64 = await _glyphPng(g);
      if (b64 == null) throw StateError('合成压测字图失败（$g）');
      chars.add(b64);
    }
    if (line == null) throw StateError('合成压测行图失败');
    return () => OllamaService.lineStressProbe(
      settings: settings,
      model: model,
      lineImage: line,
      charImages: chars,
    );
  }

  /// 显存占用（0~1）：后端 /process_stats 整卡口径；不可用返回 null。
  static Future<double?> vramViaBackend() async {
    try {
      final stats = await PythonService.fetchProcessStats();
      final sys = stats?.system;
      final used = sys?.vramUsedBytes;
      final total = sys?.vramTotalBytes;
      if (used == null || total == null || total <= 0) return null;
      return used / total;
    } catch (_) {
      return null;
    }
  }

  // ── 合成压测图（dart:ui 白底黑字渲染 → PNG base64）──

  /// 单字图：80×80 白底单字（贴近真实单字裁图的量级）。
  static Future<String?> _glyphPng(String glyph) =>
      _png(80, 80, (canvas) => _paintGlyph(canvas, glyph, 80, 80, 0, 0));

  /// 竖排整行条图：字自上而下等距排布（古籍一列的典型形态）。
  static Future<String?> _textStripPng(List<String> glyphs) {
    const cell = 160;
    const width = 120;
    final height = glyphs.length * cell + 40;
    return _png(width, height, (canvas) {
      for (var i = 0; i < glyphs.length; i++) {
        _paintGlyph(
          canvas,
          glyphs[i],
          width.toDouble(),
          cell.toDouble(),
          0,
          20.0 + i * cell,
          fontSize: 88,
        );
      }
    });
  }

  static void _paintGlyph(
    ui.Canvas canvas,
    String glyph,
    double cellW,
    double cellH,
    double x,
    double y, {
    double? fontSize,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: glyph,
        style: TextStyle(
          color: const ui.Color(0xFF000000),
          fontSize: fontSize ?? cellH * 0.65,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      ui.Offset(x + (cellW - tp.width) / 2, y + (cellH - tp.height) / 2),
    );
  }

  static Future<String?> _png(
    int w,
    int h,
    void Function(ui.Canvas canvas) draw,
  ) async {
    try {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawRect(
        ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        ui.Paint()..color = const ui.Color(0xFFFFFFFF),
      );
      draw(canvas);
      final image = await recorder.endRecording().toImage(w, h);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return null;
      return base64Encode(data.buffer.asUint8List());
    } catch (_) {
      return null;
    }
  }
}
