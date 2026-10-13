// -*- coding: utf-8 -*-
// 识别进程数压力测试：逐档把 Kraken daemon 池重建到 k 个并各发 k 路单行
// 探针，测出本机显存/算力可稳定承载的进程数。
//
// 爬坡/判稳/显存看门狗/取消完全复用 [AiStressTester]（prepareLevel 钩子
// 每档先调 /kraken/pool/resize 重建进程池并等就绪——模型加载是每档的
// 主要耗时，整轮可达数分钟；探针 /kraken/probe 一次占住一个池成员，k 路
// 并发在 k 成员池上无排队、在更小的池上必然排队变慢，判据与 AI 压测同
// 口径：最长耗时 ≤ 单条基准×3+15 秒）。测完无论结果如何都把池恢复到用
// 户当前设置（手动值或自动），结果对话框确认"应用"时再重建到实测值。
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_concurrency.dart' show AiStressResult;
import 'ai_stress_test.dart';
import 'python_service.dart';

/// 与后端 daemon_sizing.WORKERS_MAX 对齐的绝对上限。
const int krakenWorkersHardCap = 12;

/// 一次识别进程数压测的结果（无模型绑定维度；换识别模型影响显存，
/// 但量级远小于 AI 模型切换，30 天新鲜期足够）。
@immutable
class KrakenStressResult {
  const KrakenStressResult({
    required this.maxStable,
    required this.testedAt,
    this.abortedReason,
  });

  /// 实测稳定进程数上限；**0 = 测试未能开始**（预热探针连续失败，
  /// 不是实测值——不缓存、不提供"应用"）。
  final int maxStable;
  final DateTime testedAt;

  /// 中止原因（用户取消/显存看门狗/档位准备失败/预热失败等），null = 自然跑完。
  final String? abortedReason;

  bool get fresh =>
      maxStable > 0 &&
      DateTime.now().difference(testedAt) <= KrakenStressCache.maxAge;
}

/// 压测结果缓存（SharedPreferences `kraken_stress_v1`）。
class KrakenStressCache {
  KrakenStressCache._();
  static const String _prefsKey = 'kraken_stress_v1';
  static const Duration maxAge = Duration(days: 30);

  static KrakenStressResult? _cached;
  static KrakenStressResult? get cached => _cached;

  static Future<KrakenStressResult?> load() async {
    if (_cached != null) return _cached;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_prefsKey);
      if (raw == null || raw.isEmpty) return null;
      final j = jsonDecode(raw);
      if (j is! Map) return null;
      final tested = DateTime.tryParse(j['tested_at'] as String? ?? '');
      final maxStable = (j['max_stable'] as num?)?.toInt();
      if (tested == null || maxStable == null || maxStable < 1) return null;
      _cached = KrakenStressResult(
        maxStable: maxStable,
        testedAt: tested,
        abortedReason: j['aborted_reason'] as String?,
      );
      return _cached;
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(KrakenStressResult result) async {
    _cached = result;
    await (await SharedPreferences.getInstance()).setString(
      _prefsKey,
      jsonEncode({
        'max_stable': result.maxStable,
        'tested_at': result.testedAt.toIso8601String(),
        'aborted_reason': result.abortedReason,
      }),
    );
  }
}

class KrakenStressTester {
  /// 预检：池能服务一次探针才进爬坡（后端未启动/模型仍在加载/环境损坏
  /// 在这里报清楚，不进爬坡）。瞬时问题（后端冷启动中、模型加载中）重试
  /// 3 次、每次间隔 10 秒。返回 null = 预检通过；否则为失败原因（含最后
  /// 一次的真实报错）——引擎不可用就没有可测的东西，不存在"基线保底"。
  static Future<String?> _preflight({
    required String sampleImage,
    bool Function()? isCancelled,
  }) async {
    Object? lastError;
    for (var attempt = 1; attempt <= 3; attempt++) {
      if (isCancelled?.call() ?? false) return '用户取消（测试未开始）';
      try {
        await PythonService.krakenProbe(imagePath: sampleImage);
        return null;
      } catch (e) {
        lastError = e;
        if (attempt < 3) {
          await Future<void>.delayed(const Duration(seconds: 10));
        }
      }
    }
    return '预热探针连续 3 次失败，测试未能开始：$lastError'
        '（请确认识别服务已启动、识别模型可用；识别进行中请等结束再测）';
  }

  /// 逐档重建进程池爬坡。结束后把池恢复到 [restoreWorkers]（调用方传
  /// 用户当前设置：手动值或 null=自动），失败不抛——恢复只是收尾。
  /// 预检失败时不动进程池、直接返回 maxStable=0 的失败结果。
  static Future<KrakenStressResult> run({
    required String sampleImage,
    required int? restoreWorkers,
    bool Function()? isCancelled,
    void Function(AiStressProgress p)? onProgress,
  }) async {
    onProgress?.call(
      const AiStressProgress(
        step: 0,
        cap: 0,
        maxStable: 0,
        message: '正在预检识别引擎（单行探针，模型加载中会等待重试）…',
      ),
    );
    final preError = await _preflight(
      sampleImage: sampleImage,
      isCancelled: isCancelled,
    );
    if (preError != null) {
      return KrakenStressResult(
        maxStable: 0,
        testedAt: DateTime.now(),
        abortedReason: preError,
      );
    }

    final AiStressResult result;
    try {
      result = await AiStressTester.run(
        model: 'kraken-pool',
        probe: () async {
          try {
            final r = await PythonService.krakenProbe(
              imagePath: sampleImage,
            );
            final s = (r['elapsed_s'] as num?)?.toDouble() ?? 0;
            return Duration(milliseconds: (s * 1000).round());
          } catch (_) {
            return null;
          }
        },
        vramRatio: AiStressProbe.vramViaBackend,
        isCancelled: isCancelled,
        onProgress: onProgress,
        prepareLevel: (k) async {
          try {
            final r = await PythonService.resizeKrakenPool(k);
            // 池没起齐（个别 daemon 加载失败缩容）= 该档达不到
            return (r['size'] as num?)?.toInt() == k;
          } catch (_) {
            return false;
          }
        },
        levelLabel: (k) => '$k 个识别进程',
        warmupFailHint:
            '预热请求就失败——请先确认识别服务已启动、识别模型可用',
        hardCap: krakenWorkersHardCap,
        totalBudget: const Duration(minutes: 15),
      );
    } finally {
      try {
        await PythonService.resizeKrakenPool(restoreWorkers);
      } catch (_) {}
    }
    return KrakenStressResult(
      maxStable: result.maxStable,
      testedAt: result.testedAt,
      abortedReason: result.abortedReason,
    );
  }
}
