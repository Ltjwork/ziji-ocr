// Ollama 响应解析的守门员测试：小模型经常把 JSON 用 ```json 围栏、
// 前后废话甚至纯文本包住，解析必须兜住这些形态并抽取到候选字符。
import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/services/ollama_service.dart';

void main() {
  test('整行 AI 裁决开关可独立持久化且默认关闭', () {
    const defaults = OllamaSettings();
    expect(defaults.enableManualLineAssist, isFalse);
    final restored = OllamaSettings.fromJson({
      ...defaults.toJson(),
      'enable_manual_line_assist': true,
    });
    expect(restored.enableManualLineAssist, isTrue);
  });

  test('直接 JSON 输出解析出带分值的候选', () {
    final result = OllamaService.parseSuggestionsForTest(
      '{"candidates":[{"text":"之","score":0.9,"reason":"字形接近"},'
      '{"text":"文","score":0.5}]}',
    );
    expect(result.map((e) => e.text).toList(), ['之', '文']);
    expect(result.first.score, closeTo(0.9, 1e-9));
    expect(result.first.reason, '字形接近');
  });

  test('markdown 围栏与前后废话包住的 JSON 也能解析', () {
    final result = OllamaService.parseSuggestionsForTest(
      '好的，我的判断如下：\n```json\n'
      '{"candidates":[{"text":"觀","score":0.8}]}\n'
      '```\n希望对你有帮助。',
    );
    expect(result.map((e) => e.text).toList(), ['觀']);
  });

  test('非汉字候选（英文/多字）被过滤', () {
    final result = OllamaService.parseSuggestionsForTest(
      '{"candidates":[{"text":"abc","score":0.9},{"text":"之人","score":0.8},'
      '{"text":"之","score":0.7},{"text":"3","score":0.6}]}',
    );
    expect(result.map((e) => e.text).toList(), ['之']);
  });

  test('完全不是 JSON 时优先抽引号里的候选字', () {
    final result = OllamaService.parseSuggestionsForTest(
      '这个字最有可能是「德」，其次是「惠」、「慧」。',
    );
    expect(result.map((e) => e.text).toList(), ['德', '惠', '慧']);
  });

  test('没有引号的短回答按出现顺序抽取', () {
    final result = OllamaService.parseSuggestionsForTest('之文');
    expect(result.map((e) => e.text).toList(), ['之', '文']);
  });

  test('解析不出任何候选时抛出可读异常', () {
    expect(
      () => OllamaService.parseSuggestionsForTest('12345 !!!'),
      throwsA(isA<OllamaException>()),
    );
  });

  test('标点候选：只保留标点集合内的字符', () {
    final result = OllamaService.parseSuggestionsForTest(
      '{"candidates":[{"text":"。","score":0.8},{"text":"甲","score":0.7},'
      '{"text":"，","score":0.6}]}',
      punct: true,
    );
    expect(result.map((e) => e.text).toList(), ['。', '，']);
  });

  test('单字辅助（合并白名单）：汉字与各类括号候选都保留，字母丢弃', () {
    final result = OllamaService.parseSuggestionsForTest(
      '{"candidates":[{"text":"（","score":0.9},{"text":"德","score":0.8},'
      '{"text":"【","score":0.7},{"text":"a","score":0.6},'
      '{"text":"《","score":0.5}]}',
      cjkAndPunct: true,
    );
    expect(result.map((e) => e.text).toList(), ['（', '德', '【', '《']);
  });

  test('单字辅助（合并白名单）：兜底抽取支持引号包住的标点', () {
    final result = OllamaService.parseSuggestionsForTest(
      '先是「（」，后是「）」。', cjkAndPunct: true,
    );
    expect(result.map((e) => e.text).toList(), ['（', '）']);
  });

  test('单字辅助旧白名单（仅汉字）仍拒绝标点候选', () {
    // 不带任何 flag 的旧调用保持原行为：括号候选被过滤，兜底也抽不到
    // 汉字时抛可读异常。
    expect(
      () => OllamaService.parseSuggestionsForTest(
        '{"candidates":[{"text":"（","score":0.9}]}',
      ),
      throwsA(isA<OllamaException>()),
    );
  });

  test('同一候选重复出现时去重', () {
    final result = OllamaService.parseSuggestionsForTest(
      '{"candidates":[{"text":"之","score":0.9},{"text":"之","score":0.5}]}',
    );
    expect(result.length, 1);
  });

  test('isPunctuationText 判定常见句读', () {
    expect(isPunctuationText('。'), isTrue);
    expect(isPunctuationText('、'), isTrue);
    expect(isPunctuationText('「'), isTrue);
    expect(isPunctuationText('之'), isFalse);
    expect(isPunctuationText(''), isFalse);
    expect(isPunctuationText('。，'), isFalse);
  });

  test('整行三步分析解析并过滤非法多字结果', () {
    final d = OllamaService.parseLineAnalysisForTest(
      '```json\n'
      '{"line_text":"天地。","confidence":0.87,"items":['
      '{"order":0,"text":"天","confidence":0.91},'
      '{"order":1,"text":"地","confidence":0.82},'
      '{"order":2,"text":"。","confidence":0.85},'
      '{"order":3,"text":"兩字","confidence":0.99}]}\n```',
    );
    expect(d.lineText, '天地。');
    expect(d.eligible, isTrue);
    expect(d.items.map((e) => e.text).toList(), ['天', '地', '。']);
  });

  test('整行三步分析低于固定阈值不具备采用资格', () {
    final d = OllamaService.parseLineAnalysisForTest(
      '{"line_text":"天地","confidence":0.79,"items":['
      '{"order":0,"text":"天","confidence":0.99},'
      '{"order":1,"text":"地","confidence":0.99}]}',
    );
    expect(d.eligible, isFalse);
  });

  test('整行三步分析：候选与裁切问题逐字解析', () {
    final d = OllamaService.parseLineAnalysisForTest(
      '{"line_text":"天地玄","confidence":0.9,"items":['
      '{"order":0,"text":"天","candidates":['
      '{"text":"天","score":0.95},{"text":"夫","score":0.4},'
      '{"text":"abc","score":0.3}],"punctuation":false,'
      '"crop_ok":true,"crop_issue":null,"note":""},'
      '{"order":1,"text":"地","candidates":['
      '{"text":"地","score":0.92},{"text":"地","score":0.5}],'
      '"crop_ok":false,"crop_issue":"char_clipped","note":"下半被切"},'
      '{"order":2,"text":"。","candidates":[{"text":"。","score":0.88}],'
      '"punctuation":true,"crop_ok":false,'
      '"crop_issue":"not_in_menu","note":"白名单外"}]}',
    );
    expect(d.items.length, 3);
    // 候选过滤非法条目并去重；逐字置信度取候选首位给分。
    expect(d.items[0].candidates.map((c) => c.text).toList(), ['天', '夫']);
    expect(d.items[0].confidence, closeTo(0.95, 1e-9));
    expect(d.items[1].candidates.length, 1);
    // 裁切问题只认白名单内的值。
    expect(d.items[0].cropIssue, isNull);
    expect(d.items[1].cropIssue, 'char_clipped');
    expect(d.items[1].cropNote, '下半被切');
    expect(d.items[2].cropIssue, isNull);
    expect(d.items[2].punctuation, isTrue);
  });

  test('整行三步分析：模型只给候选不给显式置信度时按候选给分', () {
    final d = OllamaService.parseLineAnalysisForTest(
      '{"line_text":"天地","confidence":0.9,"items":['
      '{"order":0,"text":"天","candidates":[{"text":"天","score":0.83}]},'
      '{"order":1,"text":"地","candidates":[]}]}',
    );
    expect(d.items[0].confidence, closeTo(0.83, 1e-9));
    expect(d.items[1].confidence, 0); // 无候选也无显式置信度
  });

  test('整行三步分析：多个 JSON 或前后说明时取完整的首个对象', () {
    final d = OllamaService.parseLineAnalysisForTest(
      '模型说明：先看这一条。'
      '{"line_text":"天地","confidence":0.88,"items":['
      '{"order":0,"text":"天","confidence":0.9},'
      '{"order":1,"text":"地","confidence":0.9}]}'
      '补充说明 {不是有效 JSON}',
    );
    expect(d.lineText, '天地');
    expect(d.eligible, isTrue);
  });

  test('整行 JSON 的 note/reason 损坏时仍恢复 line_text', () {
    final d = OllamaService.parseLineAnalysisForTest(
      '{"line_text":"天地。","confidence":0.88,"items":['
      '{"order":0,"text":"天","note":"模型说："天地"字形一致"},'
      '{"order":1,"text":"地"},'
      '{"order":2,"text":"。"}',
      // 末尾故意不闭合，模拟视觉模型输出被截断。
    );
    expect(d.lineText, '天地。');
    expect(d.eligible, isTrue);
    expect(d.items, isEmpty); // 调用方按 line_text 与字框数安全回退
  });

  group('框检查诊断解析 parseDiagnosisForTest', () {
    test('标准 JSON：问题列表按优先级取 topIssue', () {
      final d = OllamaService.parseDiagnosisForTest(
        '{"line_ok": false, "confidence": 0.8, "issues": ['
        '{"type": "char_merged", "pos": 5, "note": "两字粘连"},'
        '{"type": "merge_two_lines", "pos": 0, "note": "实为双列"}]}',
        charCount: 8,
      );
      expect(d.lineOk, isFalse);
      expect(d.confidence, 0.8);
      // merge_two_lines 优先级高于 char_merged。
      expect(d.topIssue!.type, OllamaBoxIssueType.mergeTwoLines);
    });

    test('围栏与前后废话包住的 JSON 也能解析', () {
      final d = OllamaService.parseDiagnosisForTest(
        '好的，检查结果：\n```json\n'
        '{"line_ok": true, "issues": [], "confidence": 0.9}\n'
        '```\n以上。',
        charCount: 8,
      );
      expect(d.lineOk, isTrue);
      expect(d.issues, isEmpty);
    });

    test('未知 type 丢弃、pos 越界钳到字数', () {
      final d = OllamaService.parseDiagnosisForTest(
        '{"line_ok": false, "issues": ['
        '{"type": "move_box_to", "pos": 2, "note": "不在菜单里"},'
        '{"type": "char_clipped", "pos": 99, "note": "切边"},'
        '{"type": "char_clipped", "pos": -3, "note": "负数"}]}',
        charCount: 8,
      );
      expect(d.issues.length, 2);
      expect(
        d.issues.every((i) => i.type == OllamaBoxIssueType.charClipped),
        isTrue,
      );
      expect(d.issues[0].pos, 8); // 99 → 8
      expect(d.issues[1].pos, 0); // -3 → 0
    });

    test('line_ok 缺省按 issues 非空推断', () {
      final d = OllamaService.parseDiagnosisForTest(
        '{"issues": [{"type": "missing_chars", "pos": 0}]}',
        charCount: 4,
      );
      expect(d.lineOk, isFalse);
    });

    test('答非所问（解析不出结构）按无问题处理', () {
      final d = OllamaService.parseDiagnosisForTest(
        '这行看起来挺好的，没什么问题。',
        charCount: 4,
      );
      expect(d.lineOk, isTrue);
      expect(d.issues, isEmpty);
    });
  });

  group('runner 崩溃签名 isRunnerCrashForTest', () {
    test('识别 Windows wsarenov/forcibly closed 与 running the model', () {
      expect(
        OllamaService.isRunnerCrashForTest(
          500,
          '{"error":"an error was encountered while running the model: '
          'read tcp 127.0.0.1:4303->127.0.0.1:6456: wsarecv: '
          'An existing connection was forcibly closed..."}',
        ),
        isTrue,
      );
      expect(
        OllamaService.isRunnerCrashForTest(
          500,
          'error while running the model',
        ),
        isTrue,
      );
    });

    test('普通 500 / 400 / 200 不算 runner 崩溃', () {
      expect(OllamaService.isRunnerCrashForTest(500, 'disk full'), isFalse);
      expect(
        OllamaService.isRunnerCrashForTest(
          404,
          'model not found running the model',
        ),
        isFalse,
      );
      expect(OllamaService.isRunnerCrashForTest(200, 'ok'), isFalse);
    });
  });
  group('外部模型 API：配置', () {
    test('provider 与外部字段持久化 round-trip，默认仍为本地 Ollama', () {
      const defaults = OllamaSettings();
      expect(defaults.provider, AiProvider.localOllama);
      expect(defaults.extBaseUrl, isEmpty);
      expect(defaults.configured, isTrue); // 本地默认地址视为已配置

      final restored = OllamaSettings.fromJson({
        ...defaults.toJson(),
        'ai_provider': 'external',
        'ext_base_url': 'https://api.deepseek.com/v1',
        'ext_api_key': 'sk-test',
        'ext_vision_model': 'gpt-4o-mini',
        'ext_text_model': 'deepseek-chat',
      });
      expect(restored.provider, AiProvider.externalApi);
      expect(restored.extBaseUrl, 'https://api.deepseek.com/v1');
      expect(restored.extApiKey, 'sk-test');
      expect(restored.activeVisionModel, 'gpt-4o-mini');
      expect(restored.activeTextModel, 'deepseek-chat');

      // 未知 provider 值回落本地。
      final legacy = OllamaSettings.fromJson(defaults.toJson());
      expect(legacy.provider, AiProvider.localOllama);
    });

    test('旧版单供应商平铺配置自动迁移为第一家供应商（预设命名、模型入列）', () {
      final migrated = OllamaSettings.fromJson({
        'ai_provider': 'external',
        'ext_base_url': 'https://api.deepseek.com/v1',
        'ext_api_key': 'sk-old',
        'ext_vision_model': 'glm-4.5v',
        'ext_text_model': 'deepseek-chat',
      });
      expect(migrated.extProviders, hasLength(1));
      final p = migrated.extProviders.single;
      expect(p.baseUrl, 'https://api.deepseek.com/v1');
      expect(p.apiKey, 'sk-old');
      expect(p.name, 'DeepSeek'); // 地址命中预设 → 预设名
      expect(p.models, ['glm-4.5v', 'deepseek-chat']);
      // 激活与两个槽位都归一到这家供应商。
      expect(migrated.activeExtProviderId, p.id);
      expect(migrated.effectiveVisionProviderId, p.id);
      expect(migrated.effectiveTextProviderId, p.id);
      // 端点解析不受迁移影响。
      final vision = migrated.resolveVisionEndpoint();
      expect(vision!.baseUrl, 'https://api.deepseek.com/v1');
      expect(vision.model, 'glm-4.5v');
      // 未命中预设的地址按自定义命名。
      final custom = OllamaSettings.fromJson({
        'ai_provider': 'external',
        'ext_base_url': 'https://gw.local/v1',
        'ext_api_key': '',
      });
      expect(custom.extProviders.single.name, '自定义供应商');
    });

    test('多供应商 round-trip：列表、激活指针与槽位绑定都保真', () {
      const pA = ExternalApiProvider(
        id: 'pa',
        name: '智谱 GLM',
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
        apiKey: 'sk-a',
        models: ['glm-4.5v', 'glm-4.5'],
      );
      const pB = ExternalApiProvider(
        id: 'pb',
        name: 'DeepSeek',
        baseUrl: 'https://api.deepseek.com/v1',
        apiKey: 'sk-b',
        models: ['deepseek-chat'],
      );
      const s = OllamaSettings(
        provider: AiProvider.externalApi,
        extProviders: [pA, pB],
        activeExtProviderId: 'pb',
        extVisionProviderId: 'pa',
        extVisionModel: 'glm-4.5v',
        extTextProviderId: 'pb',
        extTextModel: 'deepseek-chat',
      );
      final restored = OllamaSettings.fromJson(s.toJson());
      expect([for (final p in restored.extProviders) p.id], ['pa', 'pb']);
      expect(restored.activeExtProviderId, 'pb');
      expect(restored.extVisionProviderId, 'pa');
      expect(restored.extTextProviderId, 'pb');
      expect(restored.extBaseUrl, 'https://api.deepseek.com/v1'); // 激活=pb
      expect(restored.toJson()['ext_base_url'], 'https://api.deepseek.com/v1');
    });

    test('activeVision/TextModel 按提供方取槽位，外部文本空时视觉兜底', () {
      const p = ExternalApiProvider(
        id: 'p1',
        name: 'DeepSeek',
        baseUrl: 'https://api.deepseek.com/v1',
        models: ['glm-4.5v'],
      );
      const s = OllamaSettings(
        visionModel: 'qwen3.5:4b',
        textModel: 'qwen3:8b',
        provider: AiProvider.externalApi,
        extProviders: [p],
        extVisionModel: 'glm-4.5v',
      );
      expect(s.activeVisionModel, 'glm-4.5v');
      expect(s.activeTextModel, 'glm-4.5v'); // extTextModel 空 → 视觉兜底

      const local = OllamaSettings(visionModel: 'qwen3.5:4b');
      expect(local.activeVisionModel, 'qwen3.5:4b');
      expect(local.activeTextModel, 'qwen3.5:4b'); // 本地同款兜底
    });

    test('withVisionModel/withTextModel 注入当前提供方的槽位', () {
      const ext = OllamaSettings(provider: AiProvider.externalApi);
      final injected = ext.withVisionModel('glm-4.5v');
      expect(injected.extVisionModel, 'glm-4.5v');
      expect(injected.visionModel, isEmpty); // 本地槽位不受影响

      const local = OllamaSettings();
      final localInjected = local.withTextModel('qwen3:8b');
      expect(localInjected.textModel, 'qwen3:8b');
      expect(localInjected.extTextModel, isEmpty);
    });

    test('端点解析：视觉/文本槽可绑不同供应商，模型名精确匹配优先', () {
      const glm = ExternalApiProvider(
        id: 'glm',
        name: '智谱 GLM',
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
        apiKey: 'sk-glm',
        models: ['glm-4.5v'],
      );
      const ds = ExternalApiProvider(
        id: 'ds',
        name: 'DeepSeek',
        baseUrl: 'https://api.deepseek.com/v1',
        apiKey: 'sk-ds',
        models: ['deepseek-chat'],
      );
      final s = OllamaSettings(
        provider: AiProvider.externalApi,
        extProviders: [glm, ds],
        activeExtProviderId: 'glm',
        extVisionProviderId: 'glm',
        extVisionModel: 'glm-4.5v',
        extTextProviderId: 'ds',
        extTextModel: 'deepseek-chat',
      );
      final vision = s.resolveVisionEndpoint();
      expect(vision!.baseUrl, 'https://open.bigmodel.cn/api/paas/v4');
      expect(vision.apiKey, 'sk-glm');
      expect(vision.model, 'glm-4.5v');
      final text = s.resolveTextEndpoint();
      expect(text!.baseUrl, 'https://api.deepseek.com/v1');
      expect(text.apiKey, 'sk-ds');
      expect(text.model, 'deepseek-chat');
      // 按模型名解析：各回各家。
      expect(
        s.resolveEndpointForModel('glm-4.5v')!.baseUrl,
        'https://open.bigmodel.cn/api/paas/v4',
      );
      expect(
        s.resolveEndpointForModel('deepseek-chat')!.baseUrl,
        'https://api.deepseek.com/v1',
      );
      // 未知名（如压测传任意模型）：视觉槽优先兜底。
      expect(
        s.resolveEndpointForModel('whatever')!.model,
        'glm-4.5v',
      );
    });

    test('端点解析回退：槽位未绑/绑定失效时回退激活供应商；无地址为 null', () {
      const only = ExternalApiProvider(
        id: 'p1',
        name: 'DeepSeek',
        baseUrl: 'https://api.deepseek.com/v1',
        models: ['deepseek-chat'],
      );
      // 槽位 providerId 为空（旧配置形态）→ 回退激活供应商。
      final fallback = OllamaSettings(
        provider: AiProvider.externalApi,
        extProviders: [only],
        activeExtProviderId: 'p1',
        extVisionModel: 'deepseek-chat',
      );
      expect(
        fallback.resolveVisionEndpoint()!.baseUrl,
        'https://api.deepseek.com/v1',
      );
      // 绑定指向不存在的供应商 → 同样回退。
      final stale = fallback.copyWith(extVisionProviderId: 'gone');
      expect(stale.resolveVisionEndpoint(), isNotNull);
      // 模型名没配 → null。
      expect(
        fallback.copyWith(extVisionModel: '').resolveVisionEndpoint(),
        isNull,
      );
      // 供应商地址没填 → null。
      expect(
        fallback
            .copyWith(
              extProviders: [
                only.copyWith(baseUrl: ''),
              ],
            )
            .resolveVisionEndpoint(),
        isNull,
      );
      // 一个供应商都没有 → null。
      expect(
        const OllamaSettings(
          provider: AiProvider.externalApi,
          extVisionModel: 'm',
        ).resolveVisionEndpoint(),
        isNull,
      );
    });
  });

  group('外部模型 API：地址归一', () {
    test('/v1 根地址拼出 chat/completions 与 models 端点', () {
      expect(
        OllamaService.externalUri(
          'https://api.deepseek.com/v1',
          '/chat/completions',
        ).toString(),
        'https://api.deepseek.com/v1/chat/completions',
      );
      expect(
        OllamaService.externalUri(
          'https://open.bigmodel.cn/api/paas/v4',
          '/models',
        ).toString(),
        'https://open.bigmodel.cn/api/paas/v4/models',
      );
    });

    test('粘贴完整端点/尾斜杠/缺协议都能归一', () {
      expect(
        OllamaService.externalUri(
          'https://api.deepseek.com/v1/chat/completions',
          '/chat/completions',
        ).toString(),
        'https://api.deepseek.com/v1/chat/completions',
      );
      expect(
        OllamaService.externalUri('https://api.deepseek.com/v1/', '/models')
            .toString(),
        'https://api.deepseek.com/v1/models',
      );
      expect(
        OllamaService.externalUri('api.deepseek.com/v1', '/models').toString(),
        'https://api.deepseek.com/v1/models',
      );
    });

    test('空地址抛可读异常', () {
      expect(
        () => OllamaService.externalUri('  ', '/models'),
        throwsA(isA<OllamaException>()),
      );
    });
  });

  group('外部模型 API：本机环回判定（决定能否压测）', () {
    test('环回地址为真：127 段/localhost/::1/0.0.0.0，缺协议也算', () {
      expect(OllamaService.isLoopbackBaseUrl('http://127.0.0.1:9094/v1'), isTrue);
      expect(OllamaService.isLoopbackBaseUrl('http://127.0.0.1:11434'), isTrue);
      expect(OllamaService.isLoopbackBaseUrl('http://localhost:9094/v1'), isTrue);
      expect(OllamaService.isLoopbackBaseUrl('http://[::1]:9094/v1'), isTrue);
      expect(OllamaService.isLoopbackBaseUrl('http://0.0.0.0:8080/v1'), isTrue);
      // 缺协议会被补成 https://，host 判定不受 scheme 影响。
      expect(OllamaService.isLoopbackBaseUrl('127.0.0.1:9094/v1'), isTrue);
      // 整个 127.0.0.0/8 段都指向本机。
      expect(OllamaService.isLoopbackBaseUrl('http://127.8.8.8:9/v1'), isTrue);
      // 粘贴完整 chat/completions 端点也能归一后判定。
      expect(
        OllamaService.isLoopbackBaseUrl(
          'http://127.0.0.1:9094/v1/chat/completions',
        ),
        isTrue,
      );
    });

    test('云端/局域网/空/乱地址为假（保守：不放开压测）', () {
      expect(
        OllamaService.isLoopbackBaseUrl('https://api.deepseek.com/v1'),
        isFalse,
      );
      // 局域网是另一台机器，本机显存看门狗对它没有意义。
      expect(
        OllamaService.isLoopbackBaseUrl('http://192.168.1.5:11434/v1'),
        isFalse,
      );
      expect(OllamaService.isLoopbackBaseUrl('http://10.0.0.2:8000/v1'), isFalse);
      expect(OllamaService.isLoopbackBaseUrl(''), isFalse);
      expect(OllamaService.isLoopbackBaseUrl('not a url'), isFalse);
    });
  });

  group('外部模型 API：请求体', () {
    test('纯文本：content 为字符串，无 response_format', () {
      final body = OllamaService.externalChatBodyForTest(
        model: 'deepseek-chat',
        prompt: '只输出 JSON',
        numPredict: 512,
      );
      expect(body['model'], 'deepseek-chat');
      expect(body['messages'], [
        {'role': 'user', 'content': '只输出 JSON'},
      ]);
      expect(body['max_tokens'], 512);
      expect(body.containsKey('response_format'), isFalse);
    });

    test('带图：content 为分片数组，图像走 data URL', () {
      final body = OllamaService.externalChatBodyForTest(
        model: 'glm-4.5v',
        prompt: '看图',
        imageBase64: 'QUJD',
        jsonFormat: true,
      );
      final content = body['messages'][0]['content'] as List;
      expect(content[0], {'type': 'text', 'text': '看图'});
      expect(content[1], {
        'type': 'image_url',
        'image_url': {'url': 'data:image/png;base64,QUJD'},
      });
      expect(body['response_format'], {'type': 'json_object'});
    });
  });

  group('外部模型 API：响应解析', () {
    test('标准 choices[0].message.content', () {
      final (content, thinking) = OllamaService.parseExternalChatForTest(
        '{"choices":[{"message":{"role":"assistant",'
        '"content":"{\\"candidates\\":[{\\"text\\":\\"之\\"}]}"}}]}',
      );
      expect(content, '{"candidates":[{"text":"之"}]}');
      expect(thinking, isEmpty);
    });

    test('少数网关把 content 拆分片：逐片取 text 拼接', () {
      final (content, _) = OllamaService.parseExternalChatForTest(
        '{"choices":[{"message":{"content":'
        '[{"type":"text","text":"A"},{"type":"text","text":"B"}]}}]}',
      );
      expect(content, 'AB');
    });

    test('缺 choices / 非法 JSON 返回空串（上层报可读错误）', () {
      final (a, t) = OllamaService.parseExternalChatForTest('{"data":1}');
      expect(a, isEmpty);
      expect(t, isEmpty);
      expect(OllamaService.parseExternalChatForTest('not json').$1, isEmpty);
    });

    test('思维链：reasoning_content（GLM/DeepSeek-R1 口径）', () {
      final (content, thinking) = OllamaService.parseExternalChatForTest(
        '{"choices":[{"message":{"role":"assistant",'
        '"reasoning_content":"这个字是「之」的异体写法…",'
        '"content":"{\\"candidates\\":[]}"}}]}',
      );
      expect(content, '{"candidates":[]}');
      expect(thinking, contains('异体写法'));
    });

    test('思维链：reasoning.summary 数组（OpenAI o 系兼容层）', () {
      final (_, thinking) = OllamaService.parseExternalChatForTest(
        '{"choices":[{"message":{"role":"assistant","content":"ok",'
        '"reasoning":{"summary":[{"type":"summary_text","text":"先看字形"},'
        '{"type":"summary_text","text":"再对上下文"}]}}}]}',
      );
      expect(thinking, contains('先看字形'));
      expect(thinking, contains('再对上下文'));
    });

    test('思维链：reasoning 字符串（部分网关）', () {
      final (_, thinking) = OllamaService.parseExternalChatForTest(
        '{"choices":[{"message":{"content":"ok","reasoning":"看笔画"}}]}',
      );
      expect(thinking, '看笔画');
    });

    test('think:true 拒绝签名识别（非思考型模型 400 降级）', () {
      expect(
        OllamaService.rejectsThinkingForTest(
          '{"error":"model does not support thinking"}',
        ),
        isTrue,
      );
      expect(
        OllamaService.rejectsThinkingForTest('thinking is disabled for this model'),
        isTrue,
      );
      expect(OllamaService.rejectsThinkingForTest('some other error'), isFalse);
    });

    test('/models 列表解析并排序', () {
      expect(
        OllamaService.parseExternalModelsForTest(
          '{"data":[{"id":"deepseek-chat"},{"id":"deepseek-reasoner"},'
          '{"id":""},{"no_id":1}]}',
        ),
        ['deepseek-chat', 'deepseek-reasoner'],
      );
      expect(OllamaService.parseExternalModelsForTest('{}'), isEmpty);
    });
  });

  group('外部模型 API：错误映射', () {
    test('401/404/429 给出针对性排查提示', () {
      expect(
        OllamaService.externalApiErrorForTest(401, '').contains('API Key'),
        isTrue,
      );
      expect(
        OllamaService.externalApiErrorForTest(404, '').contains('地址'),
        isTrue,
      );
      expect(
        OllamaService.externalApiErrorForTest(429, '').contains('限'),
        isTrue,
      );
    });

    test('OpenAI 风格 error.message 被提取进提示', () {
      final msg = OllamaService.externalApiErrorForTest(
        400,
        '{"error":{"message":"Invalid model: nope","type":"invalid_request_error"}}',
      );
      expect(msg, contains('Invalid model: nope'));
    });

    test('response_format 拒绝签名识别', () {
      expect(
        OllamaService.rejectsResponseFormatForTest(
          '{"error":{"message":"response_format is not supported"}}',
        ),
        isTrue,
      );
      expect(OllamaService.rejectsResponseFormatForTest('other error'), isFalse);
    });

    test('纯文本模型拒图签名兼容 OpenAI 措辞', () {
      expect(
        OllamaService.noMultimodalForTest(
          '{"error":{"message":"This model does not support image inputs"}}',
        ),
        isTrue,
      );
    });
  });
  group('单字辅助 prompt（整行图口径）', () {
    // 端口 1 无服务：连接立即拒绝，trace 在请求前已填，可离线断言 prompt。
    const offline = OllamaSettings(
      baseUrl: 'http://127.0.0.1:1',
      visionModel: 'm',
    );

    test('带图：整行裁图 + 橙框标出目标字的口径', () async {
      final trace = OllamaTrace();
      await expectLater(
        OllamaService.suggestChar(
          settings: offline,
          imageBase64: 'QUJD',
          contextBefore: '甲乙',
          contextAfter: '丙',
          currentText: '丁',
          trace: trace,
        ),
        throwsA(isA<OllamaException>()),
      );
      expect(trace.prompt, contains('整行'));
      expect(trace.prompt, contains('橙色方框'));
      expect(trace.prompt, contains('甲乙'));
      expect(trace.prompt, contains('OCR 初步识别结果'));
    });

    test('无图：纯上下文口径并保留行内上下文', () async {
      final trace = OllamaTrace();
      await expectLater(
        OllamaService.suggestChar(
          settings: offline,
          contextBefore: '甲乙',
          trace: trace,
        ),
        throwsA(isA<OllamaException>()),
      );
      expect(trace.prompt, contains('没有图像'));
      expect(trace.prompt, contains('仅凭上下文推断'));
      expect(trace.prompt, contains('甲乙'));
    });
  });
}
