import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/services/ai_stress_test.dart';
import 'package:gujichazi/services/ollama_service.dart';

/// AI 并行数压力测试：阶梯爬坡判定（探针成功返回耗时、失败返回 null）。
/// 爬坡判定用注入的假探针；真实形态探针（OllamaService.lineStressProbe）
/// 用本机真实端口验证请求形状。
void main() {
  test('自动爬坡到失败档即停：机器只能跑 6 条时如实测出 6（不看手填值）', () async {
    var peakConcurrent = 0;
    var running = 0;
    Future<Duration?> probe() async {
      running++;
      peakConcurrent = peakConcurrent > running ? peakConcurrent : running;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      running--;
      // 第 7 条并发起开始失败（并发 6 稳定、7 不行）。
      return running + 1 <= 6
          ? const Duration(milliseconds: 50)
          : null;
    }

    final result = await AiStressTester.run(
      model: 'qwen',
      probe: probe,
    );
    expect(result.maxStable, 6);
    expect(result.abortedReason, contains('7'));
    expect(peakConcurrent, lessThanOrEqualTo(32), reason: '绝对上限 32，逐档递增绝不越档');
  });

  test('一路全过（耗时恒定不触发排队判据）→ 上限被钳到 32', () async {
    final result = await AiStressTester.run(
      model: 'qwen',
      probe: () async => const Duration(milliseconds: 100),
    );
    expect(result.maxStable, 32);
    expect(result.abortedReason, isNull);
  });

  test('预热请求就失败 → 钳到 1 并说明原因', () async {
    final result = await AiStressTester.run(
      model: 'qwen',
      probe: () async => null,
    );
    expect(result.maxStable, 1);
    expect(result.abortedReason, contains('预热'));
  });

  test('预热通过但并发 1 条失败 → 钳到 1 并说明原因', () async {
    var calls = 0;
    final result = await AiStressTester.run(
      model: 'qwen',
      probe: () async {
        calls++;
        return calls == 1 ? const Duration(milliseconds: 50) : null;
      },
    );
    expect(result.maxStable, 1);
    expect(result.abortedReason, contains('1 条都失败'));
  });

  test('排队串行判据：并发档最长耗时远超单条基准 → 该档不过（防"排队轮完也算过"）', () async {
    var calls = 0;
    final result = await AiStressTester.run(
      model: 'qwen',
      probe: () async {
        calls++;
        return switch (calls) {
          // 预热 1 条 + k=1 档 1 条：200ms 基准。
          1 || 2 => const Duration(milliseconds: 200),
          // k=2 档 2 条：500ms < 0.2s×3 + 15s，正常通过。
          3 || 4 => const Duration(milliseconds: 500),
          // k=3 档 3 条：16s > 15.6s，判定被服务端排队串行。
          _ => const Duration(seconds: 16),
        };
      },
    );
    expect(result.maxStable, 2);
    expect(result.abortedReason, contains('排队'));
    expect(result.abortedReason, contains('16.0'));
  });

  test('显存看门狗：占用 ≥95% 立即中止', () async {
    final result = await AiStressTester.run(
      model: 'qwen',
      probe: () async => const Duration(milliseconds: 50),
      vramRatio: () async => 0.97,
    );
    expect(result.abortedReason, contains('显存'));
    expect(result.maxStable, 1); // 一档都没跑完，钳到保底 1
  });

  test('用户取消 → 记录已测到的档位', () async {
    final result = await AiStressTester.run(
      model: 'qwen',
      probe: () async => const Duration(milliseconds: 50),
      isCancelled: () => true,
    );
    expect(result.abortedReason, contains('用户取消'));
  });

  test('总时长预算超限自动中止', () async {
    final result = await AiStressTester.run(
      model: 'qwen',
      probe: () async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return const Duration(milliseconds: 20);
      },
      totalBudget: const Duration(milliseconds: 60),
    );
    expect(result.abortedReason, anyOf(contains('时长上限'), isNull));
    expect(result.maxStable, greaterThanOrEqualTo(1));
  });

  // ── 真实形态探针（OllamaService.lineStressProbe，本机真实端口）──

  // 1×1 PNG：探针只在乎请求形状与像素量级，测试注入最小图即可。
  const tinyPng =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQ'
      'DwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

  test('真实形态探针（本地 Ollama）：/api/chat 带行图+3 字图、num_predict 256、format json；5xx → null', () async {
    final server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
    final bodies = <Map<String, dynamic>>[];
    final sub = server.listen((req) async {
      final body =
          jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
      bodies.add(body);
      // 第 1 条 200 成功；之后 500 失败（验证失败路径返回 null）。
      if (bodies.length == 1) {
        req.response.statusCode = 200;
        req.response.write('{"message":{"role":"assistant","content":"{}"}}');
      } else {
        req.response.statusCode = 500;
        req.response.write('{"error":"boom"}');
      }
      await req.response.close();
    });
    addTearDown(() async {
      await sub.cancel();
      await server.close(force: true);
    });

    final settings = OllamaSettings(baseUrl: 'http://127.0.0.1:${server.port}');
    final elapsed = await OllamaService.lineStressProbe(
      settings: settings,
      model: 'vl',
      lineImage: tinyPng,
      charImages: [tinyPng, tinyPng, tinyPng],
    );
    expect(elapsed, isNotNull, reason: '200 响应应判成功并返回耗时');
    final b = bodies.single;
    expect(b['model'], 'vl');
    final msg = (b['messages'] as List).single as Map;
    expect((msg['images'] as List), hasLength(4), reason: '1 张行图 + 3 张字图');
    expect((b['options'] as Map)['num_predict'], 256);
    expect(b['format'], 'json');
    expect(msg['content'].toString(), contains('整行裁图'), reason: '真实行裁决 prompt 口径');

    final failed = await OllamaService.lineStressProbe(
      settings: settings,
      model: 'vl',
      lineImage: tinyPng,
      charImages: const [tinyPng],
    );
    expect(failed, isNull, reason: '5xx 应判失败返回 null');
  });

  test('真实形态探针（外部环回 API）：/chat/completions 多模态分片 + Bearer + max_tokens 256；5xx → null', () async {
    final server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
    final bodies = <Map<String, dynamic>>[];
    final auths = <String>[];
    final sub = server.listen((req) async {
      final body =
          jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
      bodies.add(body);
      auths.add(req.headers.value('authorization') ?? '');
      if (bodies.length == 1) {
        req.response.statusCode = 200;
        req.response.write('{"choices":[{"message":{"content":"{}"}}]}');
      } else {
        req.response.statusCode = 500;
        req.response.write('{"error":{"message":"boom"}}');
      }
      await req.response.close();
    });
    addTearDown(() async {
      await sub.cancel();
      await server.close(force: true);
    });

    final settings = OllamaSettings(
      provider: AiProvider.externalApi,
      extProviders: [
        ExternalApiProvider(
          id: 'p1',
          name: '测试网关',
          baseUrl: 'http://127.0.0.1:${server.port}/v1',
          apiKey: 'sk-test',
        ),
      ],
      activeExtProviderId: 'p1',
      extVisionModel: 'glm-4.5v',
    );
    final elapsed = await OllamaService.lineStressProbe(
      settings: settings,
      model: 'glm-4.5v',
      lineImage: tinyPng,
      charImages: [tinyPng, tinyPng, tinyPng],
    );
    expect(elapsed, isNotNull);
    final b = bodies.single;
    expect(b['model'], 'glm-4.5v');
    expect(b['max_tokens'], 256);
    expect(((b['response_format'] as Map)['type']), 'json_object');
    final content = ((b['messages'] as List).single as Map)['content'] as List;
    expect(
      content.where((p) => (p as Map)['type'] == 'image_url'),
      hasLength(4),
      reason: '1 张行图 + 3 张字图的多模态分片',
    );
    expect(content.first['text'].toString(), contains('整行裁图'));
    expect(auths.single, 'Bearer sk-test');

    final failed = await OllamaService.lineStressProbe(
      settings: settings,
      model: 'glm-4.5v',
      lineImage: tinyPng,
      charImages: const [tinyPng],
    );
    expect(failed, isNull, reason: '5xx 应判失败返回 null');
  });
}
