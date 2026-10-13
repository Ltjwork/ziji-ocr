// -*- coding: utf-8 -*-
// AI 请求并行度：模式词表、压测结果缓存、许可解析（纯函数）与全局
// 请求限流器。
//
// 整行裁决从串行改为按许可并发行请求后，并发度必须可控：Ollama 本地
// 推理吃满 GPU/显存时，用户在编辑器里的手动单字/单行请求会被排队拖
// 死；显存小的机器并发过猛还可能把 runner 打崩。四档模式：
// - 智能（默认）：有新鲜压测结果直接用实测值（v2 起压测是真实负载
//   口径＋排队判据，实测值即真实上限，不再额外砍到 6），否则按显存
//   总量启发；并且给交互请求永远保留 1 条通道（后台批量最多用 N-1）。
// - 最大效能：用压测实测上限（没测过给 8），不留交互通道。
// - 低显存：恒 2 条。
// - 手动：用户指定，可填上限跟随压测实测值（未测按显存启发保守）。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hardware_info.dart';
import 'ollama_service.dart';

/// AI 并行度模式词表。
class AiParallelMode {
  static const String smart = 'smart';
  static const String maxPerf = 'max_perf';
  static const String lowVram = 'low_vram';
  static const String manual = 'manual';

  static const List<String> all = [smart, maxPerf, lowVram, manual];

  static String normalize(String? v) =>
      v != null && all.contains(v) ? v : smart;

  static String label(String v) => switch (normalize(v)) {
    maxPerf => '最大效能',
    lowVram => '低显存',
    manual => '手动',
    _ => '智能',
  };
}

/// 一次压力测试的结果。
@immutable
class AiStressResult {
  const AiStressResult({
    required this.maxStable,
    required this.model,
    required this.testedAt,
    this.abortedReason,
  });

  final int maxStable;

  /// 测的是哪个模型（换模型后结果作废）。
  final String model;
  final DateTime testedAt;

  /// 中止原因（用户取消/显存看门狗触发等），null = 自然跑完。
  final String? abortedReason;

  /// 结果对 [currentModel] 是否仍可信（同模型且 ≤30 天）。
  bool freshFor(String currentModel) =>
      model == currentModel &&
      DateTime.now().difference(testedAt) <= AiStressCache.maxAge;
}

/// 压测结果缓存（SharedPreferences `ai_stress_test_v2`，内存态单例；
/// v2 起探针为真实形态行请求 + 排队串行判据，与 v1 口径不可比，作废
/// 旧结果强制重测）。
class AiStressCache {
  AiStressCache._();
  static const String _prefsKey = 'ai_stress_test_v2';
  static const Duration maxAge = Duration(days: 30);

  static AiStressResult? _cached;
  static AiStressResult? get cached => _cached;

  static Future<AiStressResult?> load() async {
    if (_cached != null) return _cached;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_prefsKey);
      if (raw == null || raw.isEmpty) return null;
      final j = jsonDecode(raw);
      if (j is! Map) return null;
      final tested = DateTime.tryParse(j['tested_at'] as String? ?? '');
      final maxStable = (j['max_stable'] as num?)?.toInt();
      if (tested == null || maxStable == null || maxStable < 1) return null;
      _cached = AiStressResult(
        maxStable: maxStable,
        model: j['model'] as String? ?? '',
        testedAt: tested,
        abortedReason: j['aborted_reason'] as String?,
      );
      return _cached;
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(AiStressResult result) async {
    _cached = result;
    await (await SharedPreferences.getInstance()).setString(
      _prefsKey,
      jsonEncode({
        'max_stable': result.maxStable,
        'model': result.model,
        'tested_at': result.testedAt.toIso8601String(),
        'aborted_reason': result.abortedReason,
      }),
    );
  }
}

/// 未压测时的显存启发（智能/手动两档的兜底口径，同一把尺）：
/// 无 NVIDIA/未知显存 → 2；≤8G→2、≤12G→3、≤16G→4、≤24G→6、更大→8。
int _heuristicPermits(bool hasNvidiaGpu, int vramTotalMb) {
  if (!hasNvidiaGpu || vramTotalMb <= 0) return 2;
  if (vramTotalMb <= 8192) return 2;
  if (vramTotalMb <= 12288) return 3;
  if (vramTotalMb <= 16384) return 4;
  if (vramTotalMb <= 24576) return 6;
  return 8;
}

/// 手动档可填上限：有新鲜压测结果＝实测上限（设置页步进据此放宽，
/// 压测自动爬坡到测出真实上限）；没测过按显存启发保守，先测再放宽。
/// [resolveAiPermits] 的手动钳制也走这里，保证两处永远一致。
int manualPermitCap({
  AiStressResult? stress,
  String? currentModel,
  bool hasNvidiaGpu = false,
  int vramTotalMb = 0,
}) {
  final fresh =
      stress != null &&
          currentModel != null &&
          currentModel.isNotEmpty &&
          stress.freshFor(currentModel)
      ? stress.maxStable
      : null;
  return fresh ?? _heuristicPermits(hasNvidiaGpu, vramTotalMb);
}

/// 解析当前总许可数（纯函数，单测覆盖）。
///
/// [stress] 为压测缓存（可能过期/换模型，内部校验 [AiStressResult.freshFor]）；
/// [currentModel] 为当前活跃模型名。规则：
/// - lowVram → 2；
/// - manual → [manual] 钳 1..[manualPermitCap]（上限跟压测实测值走，
///   不再是固定 32；未测按显存启发）；
/// - smart → 新鲜压测结果直接采用（排队判据之后实测值即真实负载上
///   限）；否则显存启发；
/// - maxPerf → 新鲜压测结果（钳 1..32）；没测过给 8。
int resolveAiPermits({
  required String mode,
  required int manual,
  AiStressResult? stress,
  String? currentModel,
  bool hasNvidiaGpu = false,
  int vramTotalMb = 0,
}) {
  final normalized = AiParallelMode.normalize(mode);
  final freshStress =
      stress != null &&
          currentModel != null &&
          currentModel.isNotEmpty &&
          stress.freshFor(currentModel)
      ? stress.maxStable
      : null;
  switch (normalized) {
    case AiParallelMode.lowVram:
      return 2;
    case AiParallelMode.manual:
      return manual.clamp(
        1,
        manualPermitCap(
          stress: stress,
          currentModel: currentModel,
          hasNvidiaGpu: hasNvidiaGpu,
          vramTotalMb: vramTotalMb,
        ),
      );
    case AiParallelMode.maxPerf:
      return (freshStress ?? 8).clamp(1, 32);
    case AiParallelMode.smart:
    default:
      return freshStress ?? _heuristicPermits(hasNvidiaGpu, vramTotalMb);
  }
}

/// 后台批量类请求的许可上限：智能模式且总数 ≥3 时给交互请求保留
/// 1 条通道（用户在编辑器手动操作不被后台排队拖住），其余模式用满。
int backgroundPermits(int total, String mode) =>
    AiParallelMode.normalize(mode) == AiParallelMode.smart && total >= 3
    ? total - 1
    : total;

/// 全局 AI 请求限流器：`_chat`/`_chatExternal` 的统一闸门。
/// - [guard] 的 [interactive]：编辑器手动单字/单行/标点/诊断等用户直
///   排队优先（插到后台等待者前面，且可占用智能模式预留的通道）；
///   批量链路（整行裁决的行请求）传 false。
/// - 许可在空闲时（无在途无等待）按最新设置重解析，设置页改档位/
///   压测保存后立即生效。
class AiRequestLimiter {
  AiRequestLimiter._();
  static final AiRequestLimiter instance = AiRequestLimiter._();

  final _waiters = <_Waiter>[];
  int _inFlight = 0;
  int _backgroundInFlight = 0;

  int _total = 2;
  int _backgroundCap = 2;
  String _mode = AiParallelMode.smart;
  bool _initialized = false;
  bool _hwLoaded = false;
  bool _hasNvidia = false;
  int _vramMb = 0;

  /// 测试缝：非 null 时许可数直接取它（单测注入；0 表示用真实解析）。
  static int Function()? permitsOverrideForTest;

  /// 设置/压测变化后调用：下次空闲时重解析（也可立即无伤调用）。
  void markStale() => _initialized = false;

  int get inFlight => _inFlight;
  int get waiting => _waiters.length;

  /// 后台批量当前可用的许可数（worker 池规模用；至少 1）。
  Future<int> backgroundPermitCount() async {
    await _ensureFresh();
    return _backgroundCap.clamp(1, 32);
  }

  Future<void> _reload() async {
    try {
      final settings = await OllamaSettings.load();
      if (!_hwLoaded) {
        final hw = await HardwareDetector.detect();
        _hasNvidia = hw.hasNvidiaGpu;
        _vramMb = hw.vramTotalMb;
        _hwLoaded = true;
      }
      final stress = AiStressCache.cached ?? await AiStressCache.load();
      final model = settings.activeVisionModel.isNotEmpty
          ? settings.activeVisionModel
          : settings.activeTextModel;
      _mode = AiParallelMode.normalize(settings.aiParallelMode);
      final total =
          permitsOverrideForTest != null && permitsOverrideForTest!() > 0
          ? permitsOverrideForTest!()
          : resolveAiPermits(
              mode: settings.aiParallelMode,
              manual: settings.aiParallelManual,
              stress: stress,
              currentModel: model,
              hasNvidiaGpu: _hasNvidia,
              vramTotalMb: _vramMb,
            );
      _total = total;
      _backgroundCap = backgroundPermits(total, _mode);
    } catch (_) {
      // 设置/硬件/压测缓存读不出来（如测试环境无 SharedPreferences）：
      // 回退最保守的可用配置，绝不因为限流器本身让 AI 请求失败。
      _mode = AiParallelMode.smart;
      _total = 2;
      _backgroundCap = 2;
    }
  }

  Future<void> _ensureFresh() async {
    if (_initialized && _inFlight == 0 && _waiters.isEmpty) {
      // 空闲窗口：廉价地重读设置，改档位立即生效。
      await _reload();
      return;
    }
    if (!_initialized) {
      await _reload();
      _initialized = true;
    }
  }

  Future<T> guard<T>(
    Future<T> Function() task, {
    bool interactive = false,
  }) async {
    await _acquire(interactive);
    try {
      return await task();
    } finally {
      _release(interactive);
    }
  }

  Future<void> _acquire(bool interactive) async {
    await _ensureFresh();
    if (_tryGrant(interactive)) return;
    final waiter = _Waiter(interactive);
    if (interactive) {
      // 交互优先：插到第一个后台等待者前面（交互之间仍先来先得）。
      final idx = _waiters.indexWhere((w) => !w.interactive);
      if (idx < 0) {
        _waiters.add(waiter);
      } else {
        _waiters.insert(idx, waiter);
      }
    } else {
      _waiters.add(waiter);
    }
    await waiter.completer.future;
  }

  bool _tryGrant(bool interactive) {
    if (_inFlight >= _total) return false;
    if (!interactive && _backgroundInFlight >= _backgroundCap) return false;
    _inFlight++;
    if (!interactive) _backgroundInFlight++;
    return true;
  }

  void _release(bool interactive) {
    _inFlight--;
    if (!interactive) _backgroundInFlight--;
    assert(_inFlight >= 0 && _backgroundInFlight >= 0);
    _pump();
  }

  void _pump() {
    for (var i = 0; i < _waiters.length; i++) {
      if (_inFlight >= _total) break;
      final w = _waiters[i];
      if (_tryGrant(w.interactive)) {
        _waiters.removeAt(i);
        i--;
        w.completer.complete();
      }
    }
  }
}

class _Waiter {
  _Waiter(this.interactive);

  final bool interactive;
  final completer = Completer<void>();
}
