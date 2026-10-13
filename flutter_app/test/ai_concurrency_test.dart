import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/services/ai_concurrency.dart';
import 'package:gujichazi/services/ollama_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// AI 并行度：许可解析（纯函数）、交互通道预留、设置字段序列化与
/// 限流器行为（+115 引入）。
void main() {
  group('resolveAiPermits 四档解析', () {
    test('低显存恒 2；手动上限跟压测实测值走（未测按显存启发）', () {
      expect(
        resolveAiPermits(mode: AiParallelMode.lowVram, manual: 99),
        2,
      );
      expect(
        resolveAiPermits(mode: AiParallelMode.manual, manual: 0),
        1,
      );
      // 未压测：上限＝显存启发（默认无 N 卡 → 2），不再是固定 32。
      expect(
        resolveAiPermits(mode: AiParallelMode.manual, manual: 100),
        2,
      );
      // 有显存：24G 卡未压测 → 上限 6。
      expect(
        resolveAiPermits(
          mode: AiParallelMode.manual,
          manual: 100,
          hasNvidiaGpu: true,
          vramTotalMb: 24576,
        ),
        6,
      );
      // 压测过：上限＝实测值，手填超了就地钳到实测。
      final measured = AiStressResult(
        maxStable: 10,
        model: 'qwen',
        testedAt: DateTime.now(),
      );
      expect(
        resolveAiPermits(
          mode: AiParallelMode.manual,
          manual: 100,
          stress: measured,
          currentModel: 'qwen',
        ),
        10,
      );
      expect(
        resolveAiPermits(
          mode: AiParallelMode.manual,
          manual: 6,
          stress: measured,
          currentModel: 'qwen',
        ),
        6,
      );
      // manualPermitCap（面板步进的可填上限）与解析层同一把尺。
      expect(
        manualPermitCap(stress: measured, currentModel: 'qwen'),
        10,
      );
      expect(
        manualPermitCap(hasNvidiaGpu: true, vramTotalMb: 32768),
        8,
      );
    });

    test('智能：无压测按显存启发', () {
      int of({bool nvidia = true, int mb = 0}) => resolveAiPermits(
        mode: AiParallelMode.smart,
        manual: 3,
        hasNvidiaGpu: nvidia,
        vramTotalMb: mb,
      );
      expect(of(nvidia: false, mb: 24576), 2); // 无 N 卡不冒进
      expect(of(mb: 0), 2); // 显存未知
      expect(of(mb: 8192), 2);
      expect(of(mb: 12288), 3);
      expect(of(mb: 16384), 4);
      expect(of(mb: 24576), 6);
      expect(of(mb: 32768), 8);
    });

    test('智能：新鲜压测直接采用实测值，过期/换模型回退启发', () {
      final fresh = AiStressResult(
        maxStable: 10,
        model: 'qwen',
        testedAt: DateTime.now(),
      );
      expect(
        resolveAiPermits(
          mode: AiParallelMode.smart,
          manual: 3,
          stress: fresh,
          currentModel: 'qwen',
          hasNvidiaGpu: false,
        ),
        10, // 排队判据后实测值即真实负载上限，智能直接采用（不再砍到 6）
      );
      final stale = AiStressResult(
        maxStable: 10,
        model: 'qwen',
        testedAt: DateTime.now().subtract(const Duration(days: 31)),
      );
      expect(
        resolveAiPermits(
          mode: AiParallelMode.smart,
          manual: 3,
          stress: stale,
          currentModel: 'qwen',
          hasNvidiaGpu: false,
        ),
        2, // 过期 → 无 N 卡启发
      );
      expect(
        resolveAiPermits(
          mode: AiParallelMode.smart,
          manual: 3,
          stress: fresh,
          currentModel: 'other', // 换模型 → 作废
          hasNvidiaGpu: false,
        ),
        2,
      );
    });

    test('最大效能：新鲜压测取实测值，没测过给 8', () {
      expect(
        resolveAiPermits(
          mode: AiParallelMode.maxPerf,
          manual: 3,
          stress: AiStressResult(
            maxStable: 10,
            model: 'qwen',
            testedAt: DateTime.now(),
          ),
          currentModel: 'qwen',
        ),
        10,
      );
      expect(resolveAiPermits(mode: AiParallelMode.maxPerf, manual: 3), 8);
    });

    test('智能模式给交互留 1 条通道；其余模式用满', () {
      expect(backgroundPermits(6, AiParallelMode.smart), 5);
      expect(backgroundPermits(2, AiParallelMode.smart), 2); // 总数不足 3 不留
      expect(backgroundPermits(8, AiParallelMode.manual), 8);
      expect(backgroundPermits(8, AiParallelMode.maxPerf), 8);
    });
  });

  group('OllamaSettings 并行度字段', () {
    test('序列化往返（旧 JSON 缺键回退默认智能/3）', () {
      const s = OllamaSettings(
        aiParallelMode: AiParallelMode.manual,
        aiParallelManual: 6,
      );
      final restored = OllamaSettings.fromJson(s.toJson());
      expect(restored.aiParallelMode, AiParallelMode.manual);
      expect(restored.aiParallelManual, 6);

      final legacy = OllamaSettings.fromJson(const {});
      expect(legacy.aiParallelMode, AiParallelMode.smart);
      expect(legacy.aiParallelManual, 3);

      expect(
        s.copyWith(aiParallelManual: 9).aiParallelManual,
        9,
      );
      // 未知档位字符串归一到智能。
      expect(AiParallelMode.normalize('bogus'), AiParallelMode.smart);
    });
  });

  group('AiRequestLimiter 行为', () {
    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      // 默认设置（智能）+ 固定总许可 3：后台最多 2，交互可占第 3 条。
      AiRequestLimiter.permitsOverrideForTest = () => 3;
      // 预热：首次解析要跑硬件探测子进程（nvidia-smi/PowerShell），先等
      // 它完成，测试里的时序才可控。
      await AiRequestLimiter.instance.backgroundPermitCount();
    });

    tearDownAll(() {
      AiRequestLimiter.permitsOverrideForTest = null;
    });

    test('后台受许可限制，交互走预留通道且插队', () async {
      final limiter = AiRequestLimiter.instance;
      final order = <String>[];
      final bg1 = limiter
          .guard(() async {
            order.add('bg1');
            await Future<void>.delayed(const Duration(milliseconds: 50));
          })
          .then((_) => order.add('bg1-end'));
      final bg2 = limiter
          .guard(() async {
            order.add('bg2');
            await Future<void>.delayed(const Duration(milliseconds: 50));
          })
          .then((_) => order.add('bg2-end'));
      // 轮询等前两个后台许可真正发出（设置重读是异步的）。
      for (var i = 0; i < 200 && limiter.inFlight < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(limiter.inFlight, 2, reason: '后台许可上限 2');
      final bg3 = limiter
          .guard(() async {
            order.add('bg3');
          })
          .then((_) => order.add('bg3-end'));
      final ia = limiter
          .guard(() async {
            order.add('interactive');
          }, interactive: true)
          .then((_) => order.add('interactive-end'));
      // 轮询等交互任务真正发出（异步许可获取；全量并发负载下固定 5ms
      // 不够，改为有界轮询消竞态——bg3 在前两条释放许可前不可能执行，
      // 断言强度不变）。
      for (var i = 0; i < 400 && !order.contains('interactive'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      // 交互用预留的第 3 条通道执行；第三个后台仍在等待。
      expect(order, contains('interactive'));
      expect(order, isNot(contains('bg3')));
      await Future.wait([bg1, bg2, bg3, ia]);
      // 后台释放后第三个后台补上。
      expect(order, contains('bg3'));
      expect(order.indexOf('bg3'), greaterThan(order.indexOf('bg2-end')));
      expect(limiter.inFlight, 0);
      expect(limiter.waiting, 0);
    });
  });
}
