// 模型目录推荐逻辑与 /api/pull NDJSON 进度聚合的守门员测试。
// 推荐必须在不同硬件档位下选出合理模型；多层下载进度必须聚合不回跳。
import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/services/hardware_info.dart';
import 'package:gujichazi/services/ollama_model_catalog.dart';
import 'package:gujichazi/services/ollama_service.dart';

void main() {
  group('硬件推荐 recommendForHardware', () {
    test('12GB 显存：视觉最优是 qwen3.5:9b，文本最优是 qwen3:8b', () {
      final recs = OllamaModelCatalog.recommendForHardware(
        const HardwareInfo(
          hasNvidiaGpu: true,
          gpuName: 'RTX 3060',
          vramTotalMb: 12288,
          ramTotalMb: 32768,
          cpuCores: 16,
        ),
      );
      final bestVision = recs
          .where((r) => r.entry.kind == OllamaModelKind.vision && r.bestPick)
          .single;
      final bestText = recs
          .where((r) => r.entry.kind == OllamaModelKind.text && r.bestPick)
          .single;
      expect(bestVision.entry.name, 'qwen3.5:9b');
      expect(bestVision.fit, OllamaModelFit.smooth);
      expect(bestText.entry.name, 'qwen3:8b');
      expect(bestText.fit, OllamaModelFit.smooth);
      // 27b（17GB 权重）超出 12GB 显存也不满足 CPU 兜底 → 不推荐。
      final b27 = recs.firstWhere((r) => r.entry.name == 'qwen3.5:27b');
      expect(b27.fit, OllamaModelFit.tooHeavy);
      expect(b27.bestPick, isFalse);
    });

    test('8GB 显存：9b 降为吃紧，4b 成为视觉最优', () {
      final recs = OllamaModelCatalog.recommendForHardware(
        const HardwareInfo(
          hasNvidiaGpu: true,
          gpuName: 'RTX 3070',
          vramTotalMb: 8192,
          ramTotalMb: 16384,
          cpuCores: 8,
        ),
      );
      final bestVision = recs
          .where((r) => r.entry.kind == OllamaModelKind.vision && r.bestPick)
          .single;
      expect(bestVision.entry.name, 'qwen3.5:4b');
      expect(bestVision.fit, OllamaModelFit.smooth);
      final b9 = recs.firstWhere((r) => r.entry.name == 'qwen3.5:9b');
      expect(b9.fit, OllamaModelFit.tight);
    });

    test('无独显 + 16GB 内存：只有小模型 CPU 可跑，文本最优为最小档', () {
      final recs = OllamaModelCatalog.recommendForHardware(
        const HardwareInfo(
          hasNvidiaGpu: false,
          gpuName: '',
          vramTotalMb: 0,
          ramTotalMb: 16384,
          cpuCores: 8,
        ),
      );
      final bestVision = recs
          .where((r) => r.entry.kind == OllamaModelKind.vision && r.bestPick)
          .single;
      // 视觉组 CPU 可跑上限 3.5GB：qwen3.5:4b（3.4GB）是体积最大的可跑项。
      expect(bestVision.entry.name, 'qwen3.5:4b');
      expect(bestVision.fit, OllamaModelFit.cpuOk);
      final bestText = recs
          .where((r) => r.entry.kind == OllamaModelKind.text && r.bestPick)
          .single;
      // 文本组 CPU 可跑上限 3.5GB：1.7b（1.4GB）与 4b（2.5GB）可跑，
      // 最优取档位内体积最大的 qwen3:4b；8b（5.2GB）超限不推荐。
      expect(bestText.entry.name, 'qwen3:4b');
      final b8 = recs.firstWhere((r) => r.entry.name == 'qwen3:8b');
      expect(b8.fit, OllamaModelFit.tooHeavy);
    });

    test('无独显 + 内存太小：全部不推荐，没有最优选择', () {
      final recs = OllamaModelCatalog.recommendForHardware(
        const HardwareInfo(
          hasNvidiaGpu: false,
          gpuName: '',
          vramTotalMb: 0,
          ramTotalMb: 4096,
          cpuCores: 4,
        ),
      );
      expect(recs.every((r) => r.fit == OllamaModelFit.tooHeavy), isTrue);
      expect(recs.any((r) => r.bestPick), isFalse);
    });

    test('排序：先视觉后文本，同组内适配档位升序、同档位体积降序', () {
      final recs = OllamaModelCatalog.recommendForHardware(
        const HardwareInfo(
          hasNvidiaGpu: true,
          gpuName: 'RTX 4090',
          vramTotalMb: 24576,
          ramTotalMb: 65536,
          cpuCores: 24,
        ),
      );
      final kinds = recs.map((r) => r.entry.kind).toList();
      expect(kinds.first, OllamaModelKind.vision);
      expect(kinds.last, OllamaModelKind.text);
      // 24GB 显存：视觉组最优（27b）应排第一且标记 smooth。
      expect(recs.first.entry.name, 'qwen3.5:27b');
      expect(recs.first.fit, OllamaModelFit.smooth);
      expect(recs.first.bestPick, isTrue);
      // 同为 smooth 的条目按体积降序。
      final smoothSizes = recs
          .where(
            (r) =>
                r.entry.kind == OllamaModelKind.vision &&
                r.fit == OllamaModelFit.smooth,
          )
          .map((r) => r.entry.sizeGb)
          .toList();
      expect(smoothSizes, isNotEmpty);
      for (var i = 1; i < smoothSizes.length; i++) {
        expect(smoothSizes[i], lessThanOrEqualTo(smoothSizes[i - 1]));
      }
    });
  });

  group('模型名解析 parseModelNameFromCommand', () {
    test('纯模型名直接通过', () {
      expect(OllamaModelCatalog.parseModelNameFromCommand('qwen3.5:4b'),
          'qwen3.5:4b');
    });

    test('粘贴完整 ollama pull 命令（含引号与前后空白）', () {
      expect(
        OllamaModelCatalog.parseModelNameFromCommand('  ollama pull "qwen3.5:4b" '),
        'qwen3.5:4b',
      );
    });

    test('远程仓库路径（hf.co/...）合法', () {
      expect(
        OllamaModelCatalog.parseModelNameFromCommand(
          'hf.co/Qwen/Qwen3-VL-4B-Instruct-GGUF:latest',
        ),
        'hf.co/Qwen/Qwen3-VL-4B-Instruct-GGUF:latest',
      );
    });

    test('空白、中文、特殊字符一律拒绝', () {
      expect(OllamaModelCatalog.parseModelNameFromCommand(''), isNull);
      expect(OllamaModelCatalog.parseModelNameFromCommand('   '), isNull);
      expect(OllamaModelCatalog.parseModelNameFromCommand('qwen 3.5'), isNull);
      expect(OllamaModelCatalog.parseModelNameFromCommand('模型名'), isNull);
      expect(OllamaModelCatalog.parseModelNameFromCommand(r'C:\model'), isNull);
    });
  });

  group('/api/pull NDJSON 进度聚合 OllamaPullProgress', () {
    test('多层数据按 digest 聚合，整体进度不回跳', () {
      final p = OllamaPullProgress('qwen3.5:4b');
      // 清单阶段：还没有字节量。
      final e1 = p.apply('{"status":"pulling manifest"}');
      expect(e1, isNotNull);
      expect(e1!.progress, isNull);
      expect(e1.done, isFalse);
      // 第一层 100B 中完成 40B。
      final e2 = p.apply(
        '{"status":"pulling sha256:a","digest":"sha256:a",'
        '"total":100,"completed":40}',
      );
      expect(e2!.completedBytes, 40);
      expect(e2.totalBytes, 100);
      // 第二层 50B 全部完成：聚合 90/150。
      final e3 = p.apply(
        '{"status":"pulling sha256:b","digest":"sha256:b",'
        '"total":50,"completed":50}',
      );
      expect(e3!.completedBytes, 90);
      expect(e3.totalBytes, 150);
      expect(e3.progress, closeTo(0.6, 1e-9));
      // 第一层继续完成：150/150。
      final e4 = p.apply(
        '{"status":"pulling sha256:a","digest":"sha256:a",'
        '"total":100,"completed":100}',
      );
      expect(e4!.completedBytes, 150);
      expect(e4.totalBytes, 150);
      expect(e4.progress, 1.0);
      // 校验与成功：进度保持，done 只在 success 时为 true。
      final e5 = p.apply('{"status":"verifying sha256 digest"}');
      expect(e5!.done, isFalse);
      expect(e5.progress, 1.0);
      final e6 = p.apply('{"status":"success"}');
      expect(e6!.done, isTrue);
      expect(e6.error, isEmpty);
    });

    test('服务端错误行转为 done 事件且带错误信息', () {
      final p = OllamaPullProgress('no:such');
      final e = p.apply('{"error":"pull model manifest: file does not exist"}');
      expect(e!.done, isTrue);
      expect(e.error, contains('file does not exist'));
    });

    test('乱码行与空行被忽略', () {
      final p = OllamaPullProgress('m');
      expect(p.apply(''), isNull);
      expect(p.apply('not-json'), isNull);
    });

    test('completed 超过 total 时进度被夹到 1.0', () {
      final p = OllamaPullProgress('m');
      p.apply('{"digest":"a","total":10,"completed":20}');
      expect(p.apply('{"digest":"a","total":10,"completed":20}')!.progress, 1.0);
    });
  });

  test('显存需求估算 = 权重体积 + 1.5GB 运行开销', () {
    const e = OllamaCatalogEntry(
      name: 'x:1b',
      kind: OllamaModelKind.vision,
      sizeGb: 2.0,
      releaseDate: '2026-01',
      summary: '',
    );
    expect(e.vramNeedGb, closeTo(3.5, 1e-9));
    expect(e.baseName, 'x');
  });

  test('目录条目都带合法的发布月份（YYYY-MM）', () {
    final re = RegExp(r'^\d{4}-\d{2}$');
    for (final e in OllamaModelCatalog.catalog) {
      expect(e.releaseDate, matches(re), reason: e.name);
      expect(int.parse(e.releaseDate.substring(0, 4)), inInclusiveRange(2024, 2026),
          reason: e.name);
      expect(int.parse(e.releaseDate.substring(5)), inInclusiveRange(1, 12),
          reason: e.name);
    }
  });
}
