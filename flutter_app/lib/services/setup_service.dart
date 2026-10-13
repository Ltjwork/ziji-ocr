import 'dart:async';
import 'dart:convert';
import 'dart:io';

class GpuInfo {
  const GpuInfo({
    required this.available,
    required this.name,
    required this.driverVersion,
    required this.driverCuda,
  });

  final bool available;
  final String name;
  final String driverVersion;
  final String driverCuda;
}

/// 识别服务环境（运行后端的 conda 环境）状态。
/// [packages] 为 包名 → 版本（空串 = 未安装）。
class ServiceEnvStatus {
  const ServiceEnvStatus({
    required this.envExists,
    required this.pythonVersion,
    required this.packages,
    required this.yoloModelPath,
    required this.yoloModelExists,
    this.fitzVersion = '',
    this.fitzImportError = '',
    this.torchVersion = '',
    this.torchCuda = false,
    this.torchError = '',
  });

  const ServiceEnvStatus.empty()
    : envExists = false,
      pythonVersion = '',
      packages = const {},
      yoloModelPath = '',
      yoloModelExists = false,
      fitzVersion = '',
      fitzImportError = '',
      torchVersion = '',
      torchCuda = false,
      torchError = '';

  final bool envExists;
  final String pythonVersion;
  final Map<String, String> packages;
  final String yoloModelPath;
  final bool yoloModelExists;

  /// `import fitz` 的实际结果：成功为版本号，失败为空串。
  /// pip 元数据在但 DLL 损坏时（"DLL load failed"）这里为空。
  final String fitzVersion;

  /// fitz 导入失败的具体原因（成功时为空串）。
  final String fitzImportError;

  /// 训练用 PyTorch 的版本（probe 真实 import torch 取得；失败为空串）。
  final String torchVersion;

  /// probe 时 torch.cuda.is_available() 的结果：GPU 真正可用于训练。
  final bool torchCuda;

  /// torch 导入失败的原因（成功时为空串）。
  final String torchError;

  /// 后端运行必需的包（服务框架 + 图像处理 + PDF 导入）。
  static const corePackages = [
    'fastapi',
    'opencv-python',
    'numpy',
    'PyMuPDF',
  ];

  List<String> get missingCore => corePackages
      .where((name) => (packages[name] ?? '').isEmpty)
      .toList();

  bool get coreReady => envExists && pythonVersion.isNotEmpty && missingCore.isEmpty;

  /// PDF 组件是否真的可用：包装上了还不够，必须 import 成功。
  bool get fitzReady => (packages['PyMuPDF'] ?? '').isNotEmpty && fitzVersion.isNotEmpty;

  /// PDF 组件缺失或损坏，需要「修复 PDF 组件」。
  bool get pymupdfNeedsRepair => !fitzReady;

  bool get trainingReady => (packages['ultralytics'] ?? '').isNotEmpty;

  /// 训练 torch 是否为 CUDA 构建（版本号带 +cuXX 后缀）。
  bool get torchIsCudaBuild => torchVersion.contains('+cu');
}

/// Kraken 识别引擎（独立 conda 环境）状态。
class KrakenStatus {
  const KrakenStatus({
    required this.envExists,
    required this.krakenVersion,
    required this.torchVersion,
    required this.modelExists,
    required this.modelSizeMb,
  });

  const KrakenStatus.empty()
    : envExists = false,
      krakenVersion = '',
      torchVersion = '',
      modelExists = false,
      modelSizeMb = 0;

  final bool envExists;
  final String krakenVersion;
  final String torchVersion;
  final bool modelExists;
  final int modelSizeMb;

  /// torch 是否为 GPU 构建（版本号带 +cuXX 后缀）。
  bool get torchCudaBuild => torchVersion.contains('+cu');

  bool get ready =>
      envExists && krakenVersion.isNotEmpty && torchVersion.isNotEmpty;
}

/// PaddleOCR 识别引擎（独立 conda 环境 paddleocr）状态。
/// 可选引擎：不参与 SetupSnapshot.ready 门槛（Kraken 仍是默认引擎），
/// 仅在选择 PaddleOCR 的书识别前作环境提示。
class PaddleEnvStatus {
  const PaddleEnvStatus({
    required this.envExists,
    required this.paddleocrVersion,
    required this.paddleVersion,
  });

  const PaddleEnvStatus.empty()
    : envExists = false,
      paddleocrVersion = '',
      paddleVersion = '';

  final bool envExists;
  final String paddleocrVersion; // paddleocr 包版本（>=3.7 才带 PP-OCRv6）
  final String paddleVersion; // paddlepaddle / paddlepaddle-gpu 包版本

  bool get ready => envExists && paddleocrVersion.isNotEmpty;
}

class RuntimeOption {
  const RuntimeOption({
    required this.id,
    required this.label,
    required this.pytorchIndex,
    required this.pytorchLabel,
    required this.cudaRuntimeVersion,
    required this.recommended,
  });

  final String id;
  final String label;
  final String pytorchIndex;
  final String pytorchLabel;
  final String cudaRuntimeVersion;
  final bool recommended;
}

class SetupSnapshot {
  const SetupSnapshot({
    required this.checkedAt,
    required this.condaInstalled,
    required this.condaExecutable,
    required this.service,
    required this.kraken,
    required this.paddle,
    required this.gpu,
    required this.options,
    required this.serviceDir,
  });

  final DateTime checkedAt;
  final bool condaInstalled;
  final String condaExecutable;
  final ServiceEnvStatus service;
  final KrakenStatus kraken;
  final PaddleEnvStatus paddle; // 可选引擎，不进 ready 门槛
  final GpuInfo gpu;
  final List<RuntimeOption> options;
  final String? serviceDir;

  RuntimeOption get recommendedRuntime =>
      options.firstWhere((o) => o.recommended, orElse: () => options.first);

  /// 进入 OCR 的硬性条件：conda + 服务环境核心包 + Kraken 引擎 + NVIDIA 显卡。
  /// CHAT 模型缺失不算阻塞（首次识别时自动下载）；PaddleOCR 为可选引擎
  /// （未安装只影响选了它的书，识别时后端报带安装指引的错误）。
  bool get ready =>
      condaInstalled &&
      service.coreReady &&
      kraken.ready &&
      gpu.available;
}

class SetupService {
  static SetupSnapshot? _cache;
  static String? _cacheServiceDir;
  static bool _refreshing = false;
  static String? _condaExeCache;

  /// 检测过程日志钩子：设置后每个检测步骤的尝试/失败/耗时都会输出，
  /// 供环境准备页写入安装日志面板排查问题。
  static void Function(String message)? logger;

  static void _log(String message) {
    final hook = logger;
    if (hook != null) hook(message);
  }

  /// 上一次检测结果（进页先渲染缓存，再后台刷新）。
  static SetupSnapshot? get cachedSnapshot => _cache;

  static bool get isRefreshing => _refreshing;

  /// 快速环境检测：4 个并行子进程 + 文件系统检查，替代旧的 10+ 串行
  /// conda run（每次 15–60s → 约 4–8s）。[force] 为 true 时跳过缓存。
  static Future<SetupSnapshot> inspect(String? serviceDir, {bool force = false}) async {
    final cached = _cache;
    if (!force && cached != null && _cacheServiceDir == serviceDir) {
      _log('[detect] 使用缓存结果（${cached.checkedAt}），点"重新检测"强制刷新');
      return cached;
    }
    _refreshing = true;
    final sw = Stopwatch()..start();
    _log(
      '[detect] 环境检测开始 force=$force USERPROFILE='
      '${Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME']} '
      'CONDA_EXE=${Platform.environment['CONDA_EXE'] ?? '<未设置>'}',
    );
    try {
      final condaExe = await _resolveCondaExecutable();
      _log('[detect] conda 解析完成: $condaExe，并行探测开始 …');
      final envListFuture = _run(
        condaExe,
        ['env', 'list'],
        timeout: const Duration(seconds: 40),
      );
      final gpuFuture = _checkGpu();
      final serviceProbeFuture = _probeEnvPackages(condaExe, 'paddle', _serviceProbeScript);
      final krakenProbeFuture = _probeEnvPackages(condaExe, 'kraken', _krakenProbeScript);
      final paddleProbeFuture = _probeEnvPackages(condaExe, 'paddleocr', _paddleProbeScript);
      final results = await Future.wait([
        envListFuture.catchError((_) => ''),
        gpuFuture,
        serviceProbeFuture,
        krakenProbeFuture,
        paddleProbeFuture,
      ]);
      final envList = results[0] as String;
      final gpu = results[1] as GpuInfo;
      // Future.wait 的 map 结果不可修改（remove 需要拷贝）
      final servicePkgs = Map<String, String>.from(results[2] as Map);
      final krakenPkgs = Map<String, String>.from(results[3] as Map);
      final paddlePkgs = Map<String, String>.from(results[4] as Map);
      _log(
        '[detect] 并行探测完成：env list=${envList.isEmpty ? '<空!>' : '${envList.trim().split('\n').length} 行'} '
        'GPU=${gpu.available ? gpu.name : '<不可用>'} '
        '服务环境包=${servicePkgs.isEmpty ? '<空!>' : '${servicePkgs.length} 项'} '
        'Kraken 包=${krakenPkgs.isEmpty ? '<空!>' : '${krakenPkgs.length} 项'} '
        'Paddle 包=${paddlePkgs.isEmpty ? '<未安装/可选>' : '${paddlePkgs.length} 项'}',
      );
      if (envList.isEmpty) {
        _log('[detect] 警告：conda env list 输出为空，可能执行失败（详见上方候选日志）');
      } else {
        for (final line in envList.trim().split('\n')) {
          final t = line.trim();
          if (t.isNotEmpty && !t.startsWith('#')) _log('[detect] env: $t');
        }
      }

      final condaInstalled = envList.isNotEmpty;
      final serviceEnvExists = RegExp(
        r'^paddle\s+',
        multiLine: true,
      ).hasMatch(envList);
      final krakenEnvExists = RegExp(
        r'^kraken\s+',
        multiLine: true,
      ).hasMatch(envList);
      final paddleEnvExists = RegExp(
        r'^paddleocr\s+',
        multiLine: true,
      ).hasMatch(envList);

      final modelPath = serviceDir == null
          ? ''
          : '$serviceDir${Platform.pathSeparator}kraken_models${Platform.pathSeparator}chat_rec.mlmodel';
      final modelFile = modelPath.isNotEmpty ? File(modelPath) : null;
      final modelExists = modelFile != null && modelFile.existsSync();
      final modelSizeMb =
          modelFile != null && modelExists ? (modelFile.lengthSync() ~/ 1048576) : 0;
      _log('[detect] CHAT 模型 $modelPath => ${modelExists ? '存在（$modelSizeMb MB）' : '不存在'}');

      final envModelPath = Platform.environment['OCR_YOLO_CHAR_MODEL']?.trim();
      final yoloModelFromEnv = envModelPath != null && envModelPath.isNotEmpty;
      final yoloModelPath = yoloModelFromEnv
          ? envModelPath
          : serviceDir == null
          ? ''
          : '$serviceDir${Platform.pathSeparator}models${Platform.pathSeparator}yolo_char.pt';

      final snapshot = SetupSnapshot(
        checkedAt: DateTime.now(),
        condaInstalled: condaInstalled,
        condaExecutable: condaInstalled ? condaExe : '',
        service: ServiceEnvStatus(
          envExists: serviceEnvExists,
          pythonVersion: servicePkgs.remove('__python__') ?? '',
          packages: servicePkgs,
          yoloModelPath: yoloModelPath,
          yoloModelExists:
              yoloModelPath.isNotEmpty && File(yoloModelPath).existsSync(),
          fitzVersion: servicePkgs.remove('__fitz__') ?? '',
          fitzImportError: servicePkgs.remove('__fitz_error__') ?? '',
          torchVersion: servicePkgs.remove('__torch__') ?? '',
          torchCuda: servicePkgs.remove('__torch_cuda__') == '1',
          torchError: servicePkgs.remove('__torch_error__') ?? '',
        ),
        kraken: KrakenStatus(
          envExists: krakenEnvExists,
          krakenVersion: krakenPkgs['kraken'] ?? '',
          torchVersion: krakenPkgs['torch'] ?? '',
          modelExists: modelExists,
          modelSizeMb: modelSizeMb,
        ),
        paddle: PaddleEnvStatus(
          envExists: paddleEnvExists,
          paddleocrVersion: paddlePkgs['paddleocr'] ?? '',
          // paddlepaddle 与 paddlepaddle-gpu 二选一，任一在即算已装框架。
          paddleVersion:
              (paddlePkgs['paddlepaddle-gpu'] ?? paddlePkgs['paddlepaddle'] ?? ''),
        ),
        gpu: gpu,
        options: _runtimeOptions(gpu.driverCuda),
        serviceDir: serviceDir,
      );
      _cache = snapshot;
      _cacheServiceDir = serviceDir;
      sw.stop();
      _log(
        '[detect] 检测完成（${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s）：'
        'conda=${condaInstalled ? '✓' : '✗'} '
        '服务环境=${snapshot.service.coreReady ? '✓' : '✗'} '
        'Kraken=${snapshot.kraken.ready ? '✓' : '✗'} '
        'GPU=${gpu.available ? '✓' : '✗'} => ${snapshot.ready ? '整体就绪' : '未就绪'}',
      );
      return snapshot;
    } catch (e) {
      _log('[detect:error] 检测异常: $e');
      // conda 都找不到：显卡探测仍然给出，其余为空。
      final gpu = await _checkGpu();
      final snapshot = SetupSnapshot(
        checkedAt: DateTime.now(),
        condaInstalled: false,
        condaExecutable: '',
        service: const ServiceEnvStatus.empty(),
        kraken: const KrakenStatus.empty(),
        paddle: const PaddleEnvStatus.empty(),
        gpu: gpu,
        options: _runtimeOptions(gpu.driverCuda),
        serviceDir: serviceDir,
      );
      _cache = snapshot;
      _cacheServiceDir = serviceDir;
      return snapshot;
    } finally {
      _refreshing = false;
    }
  }

  /// 包探针：单条 conda run python -c，用 importlib.metadata 汇总包版本
  /// （不 import 重型库，秒级完成），输出 "###ENV_JSON###" 前缀加一行 JSON。
  /// PyMuPDF 额外做一次真实 import：pip 元数据在但 DLL 损坏时
  /// （"DLL load failed while importing _extra"）version() 依然成功，
  /// 只有真 import 才能暴露（/pdf_to_images 就是这么挂的）。
  static const String _serviceProbeScript = '''
import json, sys
from importlib.metadata import version
names = ['fastapi', 'opencv-python', 'numpy', 'torch',
         'ultralytics', 'PyMuPDF', 'lmdb',
         'opencc-python-reimplemented']
out = {'__python__': '.'.join(map(str, sys.version_info[:3]))}
for n in names:
    try:
        out[n] = version(n)
    except Exception:
        out[n] = ''
try:
    import fitz
    out['__fitz__'] = getattr(fitz, '__version__', '') or 'ok'
except Exception as e:
    out['__fitz__'] = ''
    out['__fitz_error__'] = type(e).__name__ + ': ' + str(e)
try:
    import torch
    out['__torch__'] = getattr(torch, '__version__', '') or 'ok'
    out['__torch_cuda__'] = '1' if torch.cuda.is_available() else '0'
except Exception as e:
    out['__torch__'] = ''
    out['__torch_cuda__'] = '0'
    out['__torch_error__'] = type(e).__name__ + ': ' + str(e)
print('###ENV_JSON###' + json.dumps(out))
''';

  static const String _krakenProbeScript = '''
import json, sys
from importlib.metadata import version
out = {'__python__': '.'.join(map(str, sys.version_info[:3]))}
for n in ['kraken', 'torch', 'torchvision']:
    try:
        out[n] = version(n)
    except Exception:
        out[n] = ''
print('###ENV_JSON###' + json.dumps(out))
''';

  /// paddleocr 环境包探针（与 kraken 同款：只查 pip 元数据，不 import
  /// 重型库）。paddlepaddle-gpu 与 paddlepaddle 二选一装。
  static const String _paddleProbeScript = '''
import json, sys
from importlib.metadata import version
out = {'__python__': '.'.join(map(str, sys.version_info[:3]))}
for n in ['paddleocr', 'paddlepaddle', 'paddlepaddle-gpu']:
    try:
        out[n] = version(n)
    except Exception:
        out[n] = ''
print('###ENV_JSON###' + json.dumps(out))
''';

  static Future<Map<String, String>> _probeEnvPackages(
    String condaExe,
    String envName,
    String script,
  ) async {
    final sw = Stopwatch()..start();
    // 多行脚本不能作为 -c 参数直传：runInShell 经 cmd.exe 转发时换行会被
    // 当成命令分隔符，Python 只收到第一行（实测静默返回空）。写入临时
    // .py 文件再执行，彻底绕开 shell 引号/换行问题。
    final probeFile = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'ocr_env_probe_${envName}_${DateTime.now().millisecondsSinceEpoch}.py',
    );
    try {
      probeFile.writeAsStringSync(script, flush: true);
      final output = await _run(
        condaExe,
        ['run', '-n', envName, 'python', '-X', 'utf8', probeFile.path],
        timeout: const Duration(seconds: 90),
      );
      for (final line in output.split('\n')) {
        final marker = line.indexOf('###ENV_JSON###');
        if (marker < 0) continue;
        final raw = line.substring(marker + '###ENV_JSON###'.length).trim();
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) {
            sw.stop();
            _log(
              '[detect] $envName 环境探针成功'
              '（${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s，'
              '${decoded.length} 项）',
            );
            return decoded.map((k, v) => MapEntry(k, v?.toString() ?? ''));
          }
        } catch (e) {
          _log('[detect] $envName 环境探针 JSON 解析失败: $e 原始: ${raw.substring(0, raw.length.clamp(0, 200))}');
        }
      }
      sw.stop();
      _log(
        '[detect] $envName 环境探针输出中没有 JSON 标记'
        '（${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s），视为空。'
        '输出前 200 字符: ${output.trim().substring(0, output.trim().length.clamp(0, 200))}',
      );
      return const {};
    } catch (e) {
      sw.stop();
      final reason = e is TimeoutException ? '超时（>90s）' : '执行失败';
      _log(
        '[detect] $envName 环境探针失败'
        '（${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s，$reason）: $e',
      );
      return const {};
    } finally {
      try {
        if (probeFile.existsSync()) probeFile.deleteSync();
      } catch (_) {}
    }
  }

  /// 删除识别服务环境（conda env 历史名称为 "paddle"，现仅是环境名）。
  static Future<Process> deleteServiceEnvironment({
    required String condaExecutable,
  }) async {
    final condaCommand = condaExecutable.isEmpty ? 'conda' : condaExecutable;
    if (Platform.isWindows) {
      final command = [
        r"$ErrorActionPreference = 'Stop'",
        "\$conda = '${condaCommand.replaceAll("'", "''")}'",
        r"$envName = 'paddle'",
        r"$envDir = Join-Path $env:USERPROFILE '.conda\envs\paddle'",
        r"Write-Output '[delete] Target conda environment: paddle'",
        r'Write-Output "[delete] Target directory: $envDir"',
        r"$envList = & $conda env list | Out-String",
        r'if ($envList -match "(?m)^paddle\s+") { Write-Output "[delete] Removing registered conda environment..."; & $conda env remove -y -n $envName; if ($LASTEXITCODE -ne 0) { throw "conda env remove failed with exit code $LASTEXITCODE" } }',
        r'if (Test-Path -LiteralPath $envDir) { Write-Output "[delete] Removing remaining environment directory..."; Remove-Item -LiteralPath $envDir -Recurse -Force } else { Write-Output "[delete] No remaining environment directory found." }',
        r"Write-Output '[delete] Done.'",
      ].join('; ');
      return Process.start('powershell', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        command,
      ], runInShell: true);
    }

    final command = [
      'set -e',
      r'env_dir="$HOME/.conda/envs/paddle"',
      'echo "[delete] Target conda environment: paddle"',
      r'echo "[delete] Target directory: $env_dir"',
      'if "$condaCommand" env list | grep -E "^paddle[[:space:]]+" >/dev/null; then echo "[delete] Removing registered conda environment..."; "$condaCommand" env remove -y -n paddle; fi',
      r'if [ -d "$env_dir" ]; then echo "[delete] Removing remaining environment directory..."; rm -rf "$env_dir"; else echo "[delete] No remaining environment directory found."; fi',
      'echo "[delete] Done."',
    ].join(' && ');
    return Process.start('sh', ['-lc', command], runInShell: true);
  }

  /// 安装 Kraken 识别引擎（等价于 install_kraken.bat）：建 conda 环境 →
  /// 装 GPU/CPU torch → 装 kraken → 验证导入。日志流式输出到安装控制台。
  static Future<Process> installKrakenEngine({
    required String condaExecutable,
    bool gpuTorch = true,
  }) async {
    final conda = condaExecutable.isEmpty ? 'conda' : condaExecutable;
    if (Platform.isWindows) {
      final script = [
        r"$ErrorActionPreference = 'Continue'",
        r"$ProgressPreference = 'SilentlyContinue'",
        "\$conda = '${conda.replaceAll("'", "''")}'",
        r"$envName = 'kraken'",
        r"Write-Output '[kraken] step 1/4: conda environment'",
        r'function Invoke-Logged($arguments) { $output = & cmd.exe /d /c "`"$conda`" $arguments 2>&1" | ForEach-Object { $_.ToString() }; $exitCode = $LASTEXITCODE; $output | ForEach-Object { [Console]::Out.WriteLine($_) }; return @{ ExitCode = $exitCode; Output = ($output -join "`n") } }',
        r'function Invoke-CondaStep($arguments) { $result = Invoke-Logged $arguments; if ($result.ExitCode -ne 0) { exit $result.ExitCode }; return $result.Output }',
        r'$envList = Invoke-CondaStep "env list"',
        r'if ($envList -match "(?m)^kraken\s+") { Write-Output "[kraken] conda environment already exists: kraken" } else { Invoke-CondaStep "create -y -n $envName python=3.10" }',
        r"Write-Output '[kraken] step 2/4: PyTorch'",
        if (gpuTorch)
          r'Invoke-CondaStep "run -n $envName python -m pip install torch torchvision --index-url https://download.pytorch.org/whl/cu126 --timeout 120 --retries 5"'
        else
          r'Invoke-CondaStep "run -n $envName python -m pip install torch torchvision --timeout 120 --retries 5 -i https://pypi.tuna.tsinghua.edu.cn/simple"',
        r"Write-Output '[kraken] step 3/4: kraken'",
        r'Invoke-CondaStep "run -n $envName python -m pip install kraken --timeout 120 --retries 5 -i https://pypi.tuna.tsinghua.edu.cn/simple"',
        r"Write-Output '[kraken] step 4/4: verify'",
        r'Invoke-CondaStep "run -n $envName python -c `"import kraken.rpred, kraken.blla; import torch; from importlib.metadata import version; print(chr(91)+chr(107)+chr(114)+chr(97)+chr(107)+chr(101)+chr(110)+chr(93), version(chr(107)+chr(114)+chr(97)+chr(107)+chr(101)+chr(110)), chr(124), torch.__version__, chr(99)+chr(117)+chr(100)+chr(97), torch.cuda.is_available())`""',
        r"Write-Output '[kraken] Done.'",
      ].join('; ');
      final encodedScript = base64Encode(
        script.codeUnits.expand((unit) => [unit & 0xff, unit >> 8]).toList(),
      );
      return Process.start('powershell', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-EncodedCommand',
        encodedScript,
      ]);
    }

    final command = [
      'set -e',
      'echo "[kraken] step 1/4: conda environment"',
      '"$conda" env list | grep -E "^kraken\\s+" || "$conda" create -y -n kraken python=3.10',
      'echo "[kraken] step 2/4: PyTorch"',
      if (gpuTorch)
        '"$conda" run -n kraken python -m pip install torch torchvision --index-url https://download.pytorch.org/whl/cu126 --timeout 120 --retries 5'
      else
        '"$conda" run -n kraken python -m pip install torch torchvision --timeout 120 --retries 5 -i https://pypi.tuna.tsinghua.edu.cn/simple',
      'echo "[kraken] step 3/4: kraken"',
      '"$conda" run -n kraken python -m pip install kraken --timeout 120 --retries 5 -i https://pypi.tuna.tsinghua.edu.cn/simple',
      'echo "[kraken] step 4/4: verify"',
      '"$conda" run -n kraken python -c "import kraken.rpred, kraken.blla; import torch; print(\'[kraken] ok\', torch.__version__)"',
      'echo "[kraken] Done."',
    ].join(' && ');
    return Process.start('sh', ['-lc', command], runInShell: true);
  }

  /// 安装 PaddleOCR 识别引擎（等价于 install_paddleocr.bat）：建独立
  /// conda 环境 paddleocr → 装 GPU/CPU paddlepaddle → 装 paddleocr(>=3.7，
  /// 带 PP-OCRv6) → 验证导入。日志流式输出到安装控制台。可选引擎，不在
  /// SetupSnapshot.ready 门槛内。
  static Future<Process> installPaddleEngine({
    required String condaExecutable,
    bool gpuPaddle = true,
  }) async {
    final conda = condaExecutable.isEmpty ? 'conda' : condaExecutable;
    // paddlepaddle 的 GPU 轮子不在 PyPI 镜像上，只能走官方包源（cu126）。
    const paddleGpuIndex = 'https://www.paddlepaddle.org.cn/packages/stable/cu126/';
    if (Platform.isWindows) {
      final script = [
        r"$ErrorActionPreference = 'Continue'",
        r"$ProgressPreference = 'SilentlyContinue'",
        "\$conda = '${conda.replaceAll("'", "''")}'",
        r"$envName = 'paddleocr'",
        "\$paddleGpuIndex = '$paddleGpuIndex'",
        r"Write-Output '[paddle] step 1/4: conda environment'",
        r'function Invoke-Logged($arguments) { $output = & cmd.exe /d /c "`"$conda`" $arguments 2>&1" | ForEach-Object { $_.ToString() }; $exitCode = $LASTEXITCODE; $output | ForEach-Object { [Console]::Out.WriteLine($_) }; return @{ ExitCode = $exitCode; Output = ($output -join "`n") } }',
        r'function Invoke-CondaStep($arguments) { $result = Invoke-Logged $arguments; if ($result.ExitCode -ne 0) { exit $result.ExitCode }; return $result.Output }',
        r'$envList = Invoke-CondaStep "env list"',
        r'if ($envList -match "(?m)^paddleocr\s+") { Write-Output "[paddle] conda environment already exists: paddleocr" } else { Invoke-CondaStep "create -y -n $envName python=3.10" }',
        r"Write-Output '[paddle] step 2/4: paddlepaddle'",
        if (gpuPaddle)
          r'Invoke-CondaStep "run -n $envName python -m pip install paddlepaddle-gpu -i $paddleGpuIndex --timeout 120 --retries 5"'
        else
          r'Invoke-CondaStep "run -n $envName python -m pip install paddlepaddle --timeout 120 --retries 5 -i https://pypi.tuna.tsinghua.edu.cn/simple"',
        r"Write-Output '[paddle] step 3/4: paddleocr (PP-OCRv6)'",
        r'Invoke-CondaStep "run -n $envName python -m pip install paddleocr>=3.7 --timeout 120 --retries 5 -i https://pypi.tuna.tsinghua.edu.cn/simple"',
        r"Write-Output '[paddle] step 4/4: verify'",
        r'Invoke-CondaStep "run -n $envName python -c `"import paddle; from paddleocr import TextRecognition; from importlib.metadata import version; print(version(chr(112)+chr(97)+chr(100)+chr(100)+chr(108)+chr(101)+chr(111)+chr(99)+chr(114)), paddle.__version__)`""',
        r"Write-Output '[paddle] Done. PP-OCRv6 models download on first use.'",
      ].join('; ');
      final encodedScript = base64Encode(
        script.codeUnits.expand((unit) => [unit & 0xff, unit >> 8]).toList(),
      );
      return Process.start('powershell', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-EncodedCommand',
        encodedScript,
      ]);
    }

    final command = [
      'set -e',
      'echo "[paddle] step 1/4: conda environment"',
      '"$conda" env list | grep -E "^paddleocr\\s+" || "$conda" create -y -n paddleocr python=3.10',
      'echo "[paddle] step 2/4: paddlepaddle"',
      if (gpuPaddle)
        '"$conda" run -n paddleocr python -m pip install paddlepaddle-gpu -i $paddleGpuIndex --timeout 120 --retries 5'
      else
        '"$conda" run -n paddleocr python -m pip install paddlepaddle --timeout 120 --retries 5 -i https://pypi.tuna.tsinghua.edu.cn/simple',
      'echo "[paddle] step 3/4: paddleocr (PP-OCRv6)"',
      '"$conda" run -n paddleocr python -m pip install paddleocr>=3.7 --timeout 120 --retries 5 -i https://pypi.tuna.tsinghua.edu.cn/simple',
      'echo "[paddle] step 4/4: verify"',
      '"\$conda" run -n paddleocr python -c "import paddle; from paddleocr import TextRecognition; print(\'[paddle] ok\', paddle.__version__)"',
      'echo "[paddle] Done."',
    ].join(' && ');
    return Process.start('sh', ['-lc', command], runInShell: true);
  }

  /// 一键安装/修复识别服务环境：建环境 → CUDA runtime → 后端依赖。
  /// （识别引擎在各自独立环境：Kraken 见 installKrakenEngine（默认引擎），
  /// PaddleOCR 见 installPaddleEngine（可选引擎）。）
  static Future<Process> installServiceEnvironment({
    required RuntimeOption runtime,
    required String serviceDir,
    required bool useChinaMirror,
    required String condaExecutable,
  }) async {
    final conda = condaExecutable.isEmpty ? 'conda' : condaExecutable;
    final requirements =
        '${serviceDir.replaceAll('\\', '\\\\')}\\requirements.txt';
    final cudaMajor = runtime.cudaRuntimeVersion.split('.').first;
    final cudaRuntimePackage = 'nvidia-cuda-runtime-cu$cudaMajor';
    if (Platform.isWindows) {
      final script = [
        r"$ErrorActionPreference = 'Continue'",
        r"$ProgressPreference = 'SilentlyContinue'",
        "\$conda = '${conda.replaceAll("'", "''")}'",
        r"$envName = 'paddle'",
        "\$requirements = '$requirements'",
        "\$useChinaMirror = ${useChinaMirror ? '\$true' : '\$false'}",
        "\$cudaRuntimePackage = '$cudaRuntimePackage'",
        r'function Invoke-Logged($arguments) { $output = & cmd.exe /d /c "`"$conda`" $arguments 2>&1" | ForEach-Object { $_.ToString() }; $exitCode = $LASTEXITCODE; $output | ForEach-Object { [Console]::Out.WriteLine($_) }; return @{ ExitCode = $exitCode; Output = ($output -join "`n") } }',
        r'function Invoke-CondaStep($arguments) { $result = Invoke-Logged $arguments; if ($result.ExitCode -ne 0) { exit $result.ExitCode }; return $result.Output }',
        r"Write-Output '[service] step 1/3: conda environment'",
        r'$envList = Invoke-CondaStep "env list"',
        r'if ($envList -match "(?m)^paddle\s+") { Write-Output "[service] conda environment already exists: paddle" } else { Invoke-CondaStep "create -y -n $envName python=3.10" }',
        r"Write-Output '[service] step 2/3: CUDA runtime package'",
        r'if ($useChinaMirror) { $pipOptions = "--timeout 120 --retries 5 -i https://pypi.tuna.tsinghua.edu.cn/simple" } else { $pipOptions = "--timeout 120 --retries 5" }',
        r'Invoke-CondaStep "run -n $envName python -m pip install $cudaRuntimePackage $pipOptions"',
        r"Write-Output '[service] step 3/3: backend dependencies (requirements.txt)'",
        r'if (-not (Test-Path $requirements)) { Write-Output "requirements.txt not found: $requirements"; exit 1 }',
        r'Invoke-CondaStep "run -n $envName python -m pip install --upgrade pip $pipOptions"',
        r'Invoke-CondaStep "run -n $envName python -m pip install -r `"$requirements`" $pipOptions"',
        r"Write-Output '[service] Done.'",
      ].join('; ');
      final encodedScript = base64Encode(
        script.codeUnits.expand((unit) => [unit & 0xff, unit >> 8]).toList(),
      );
      return Process.start('powershell', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-EncodedCommand',
        encodedScript,
      ]);
    }

    final mirror = useChinaMirror
        ? '-i https://pypi.tuna.tsinghua.edu.cn/simple'
        : '';
    final command = [
      'set -e',
      'echo "[service] step 1/3: conda environment"',
      '"\$conda" env list | grep -E "^paddle\\s+" || "\$conda" create -y -n paddle python=3.10',
      'echo "[service] step 2/3: CUDA runtime package"',
      '"\$conda" run -n paddle python -m pip install $cudaRuntimePackage --timeout 120 --retries 5 $mirror',
      'echo "[service] step 3/3: backend dependencies"',
      '"\$conda" run -n paddle python -m pip install --upgrade pip --timeout 120 --retries 5 $mirror',
      '"\$conda" run -n paddle python -m pip install -r requirements.txt --timeout 120 --retries 5 $mirror',
      'echo "[service] Done."',
    ].join(' && ');
    return Process.start('sh', [
      '-lc',
      command,
    ], workingDirectory: serviceDir, runInShell: true);
  }

  static Future<Process> installYolo({
    required String condaExecutable,
    required bool useChinaMirror,
  }) async {
    final conda = condaExecutable.isEmpty ? 'conda' : condaExecutable;
    if (Platform.isWindows) {
      final mirrorFlag = useChinaMirror
          ? '-i https://pypi.tuna.tsinghua.edu.cn/simple'
          : '';
      final script = [
        r"$ErrorActionPreference = 'Continue'",
        r"$ProgressPreference = 'SilentlyContinue'",
        "\$conda = '${conda.replaceAll("'", "''")}'",
        r"$envName = 'paddle'",
        r"Write-Output '[yolo] Installing ultralytics into service environment...'",
        r'function Invoke-Logged($arguments) { $output = & cmd.exe /d /c "`"$conda`" $arguments 2>&1" | ForEach-Object { $_.ToString() }; $exitCode = $LASTEXITCODE; $output | ForEach-Object { [Console]::Out.WriteLine($_) }; return @{ ExitCode = $exitCode; Output = ($output -join "`n") } }',
        r'function Invoke-CondaStep($arguments) { $result = Invoke-Logged $arguments; if ($result.ExitCode -ne 0) { exit $result.ExitCode }; return $result.Output }',
        'Invoke-CondaStep "run -n \$envName python -m pip install ultralytics --timeout 120 --retries 5 $mirrorFlag"',
        r'$version = Invoke-CondaStep "run -n $envName python -c `"import ultralytics; print(ultralytics.__version__)`""',
        r'Write-Output "[yolo] ultralytics version installed: $version"',
        r"Write-Output '[yolo] Done. Put trained model at python_service\models\yolo_char.pt or set OCR_YOLO_CHAR_MODEL.'",
      ].join('; ');
      final encodedScript = base64Encode(
        script.codeUnits.expand((unit) => [unit & 0xff, unit >> 8]).toList(),
      );
      return Process.start('powershell', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-EncodedCommand',
        encodedScript,
      ]);
    }

    final mirror = useChinaMirror
        ? '-i https://pypi.tuna.tsinghua.edu.cn/simple'
        : '';
    final command = [
      'set -e',
      'echo "[yolo] Installing ultralytics into service environment..."',
      '"$conda" run -n paddle python -m pip install ultralytics --timeout 120 --retries 5 $mirror',
      '"$conda" run -n paddle python -c "import ultralytics; print(ultralytics.__version__)"',
      'echo "[yolo] Done. Put trained model at python_service/models/yolo_char.pt or set OCR_YOLO_CHAR_MODEL."',
    ].join(' && ');
    return Process.start('sh', ['-lc', command], runInShell: true);
  }

  /// 修复 PDF 组件（PyMuPDF）。必须 --force-reinstall：包元数据还在时普通
  /// install 会提示"Requirement already satisfied"跳过，修不了 DLL 损坏；
  /// --no-cache-dir 避免把损坏的本地缓存 wheel 又装回去。
  /// 安装 CUDA 版 PyTorch（训练用）：从所选 CUDA 运行时对应的 PyTorch
  /// 官方源安装 torch + torchvision，替换「安装训练组件」默认带进来的
  /// CPU 版（PyPI 的 torch 默认无 CUDA）。wheel 约 2.5 GB，装完用
  /// torch.cuda.is_available() 验证。
  static Future<Process> installCudaTorch({
    required RuntimeOption runtime,
    required String condaExecutable,
  }) async {
    final conda = condaExecutable.isEmpty ? 'conda' : condaExecutable;
    final indexUrl = runtime.pytorchIndex;
    if (Platform.isWindows) {
      final script = [
        r"$ErrorActionPreference = 'Continue'",
        r"$ProgressPreference = 'SilentlyContinue'",
        "\$conda = '${conda.replaceAll("'", "''")}'",
        r"$envName = 'paddle'",
        "\$indexUrl = '$indexUrl'",
        r"Write-Output '[cudatorch] Installing CUDA PyTorch into service environment (~2.5 GB, please wait)...'",
        r'function Invoke-Logged($arguments) { $output = & cmd.exe /d /c "`"$conda`" $arguments 2>&1" | ForEach-Object { $_.ToString() }; $exitCode = $LASTEXITCODE; $output | ForEach-Object { [Console]::Out.WriteLine($_) }; return @{ ExitCode = $exitCode; Output = ($output -join "`n") } }',
        r'function Invoke-CondaStep($arguments) { $result = Invoke-Logged $arguments; if ($result.ExitCode -ne 0) { exit $result.ExitCode }; return $result.Output }',
        r'Invoke-CondaStep "run -n $envName python -m pip install --upgrade torch torchvision --index-url $indexUrl --timeout 120 --retries 5"',
        r'$verify = Invoke-CondaStep "run -n $envName python -c `"import torch; print(torch.__version__, torch.cuda.is_available())`""',
        r'Write-Output "[cudatorch] verify: $verify"',
        r"Write-Output '[cudatorch] Done.'",
      ].join('; ');
      final encodedScript = base64Encode(
        script.codeUnits.expand((unit) => [unit & 0xff, unit >> 8]).toList(),
      );
      return Process.start('powershell', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-EncodedCommand',
        encodedScript,
      ]);
    }

    final command = [
      'set -e',
      'echo "[cudatorch] Installing CUDA PyTorch into service environment..."',
      '"$conda" run -n paddle python -m pip install --upgrade torch torchvision --index-url $indexUrl --timeout 120 --retries 5',
      '"$conda" run -n paddle python -c "import torch; print(torch.__version__, torch.cuda.is_available())"',
      'echo "[cudatorch] Done."',
    ].join(' && ');
    return Process.start('sh', ['-lc', command], runInShell: true);
  }

  static Future<Process> installPyMuPDF({
    required String condaExecutable,
    required bool useChinaMirror,
  }) async {
    final conda = condaExecutable.isEmpty ? 'conda' : condaExecutable;
    if (Platform.isWindows) {
      final mirrorFlag = useChinaMirror
          ? '-i https://pypi.tuna.tsinghua.edu.cn/simple'
          : '';
      final script = [
        r"$ErrorActionPreference = 'Continue'",
        r"$ProgressPreference = 'SilentlyContinue'",
        "\$conda = '${conda.replaceAll("'", "''")}'",
        r"$envName = 'paddle'",
        r"Write-Output '[pymupdf] Reinstalling PyMuPDF into service environment...'",
        r'function Invoke-Logged($arguments) { $output = & cmd.exe /d /c "`"$conda`" $arguments 2>&1" | ForEach-Object { $_.ToString() }; $exitCode = $LASTEXITCODE; $output | ForEach-Object { [Console]::Out.WriteLine($_) }; return @{ ExitCode = $exitCode; Output = ($output -join "`n") } }',
        r'function Invoke-CondaStep($arguments) { $result = Invoke-Logged $arguments; if ($result.ExitCode -ne 0) { exit $result.ExitCode }; return $result.Output }',
        'Invoke-CondaStep "run -n \$envName python -m pip install --force-reinstall --no-cache-dir PyMuPDF --timeout 120 --retries 5 $mirrorFlag"',
        r'$version = Invoke-CondaStep "run -n $envName python -c `"import fitz; print(fitz.__version__)`""',
        r'Write-Output "[pymupdf] PyMuPDF version installed: $version"',
        r"Write-Output '[pymupdf] Done.'",
      ].join('; ');
      final encodedScript = base64Encode(
        script.codeUnits.expand((unit) => [unit & 0xff, unit >> 8]).toList(),
      );
      return Process.start('powershell', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-EncodedCommand',
        encodedScript,
      ]);
    }

    final mirror = useChinaMirror
        ? '-i https://pypi.tuna.tsinghua.edu.cn/simple'
        : '';
    final command = [
      'set -e',
      'echo "[pymupdf] Reinstalling PyMuPDF into service environment..."',
      '"$conda" run -n paddle python -m pip install --force-reinstall --no-cache-dir PyMuPDF --timeout 120 --retries 5 $mirror',
      '"$conda" run -n paddle python -c "import fitz; print(fitz.__version__)"',
      'echo "[pymupdf] Done."',
    ].join(' && ');
    return Process.start('sh', ['-lc', command], runInShell: true);
  }

  static Future<Process> installMiniconda() async {
    if (!Platform.isWindows) {
      throw UnsupportedError(
        'Built-in Miniconda install currently supports Windows only.',
      );
    }
    final userProfile =
        Platform.environment['USERPROFILE'] ?? Directory.current.path;
    final installDir = '$userProfile\\miniconda3';
    final command = [
      r"$ErrorActionPreference = 'Stop'",
      r"[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls",
      r"$urls = @('https://repo.anaconda.com/miniconda/Miniconda3-latest-Windows-x86_64.exe', 'https://mirrors.tuna.tsinghua.edu.cn/anaconda/miniconda/Miniconda3-latest-Windows-x86_64.exe')",
      r"$installer = Join-Path $env:TEMP 'Miniconda3-latest-Windows-x86_64.exe'",
      "\$installDir = '$installDir'",
      r'if (Test-Path $installer) { Remove-Item $installer -Force }',
      r"Write-Output '[conda] downloading Miniconda installer...'",
      r'$downloaded = $false',
      r'foreach ($url in $urls) { try { Write-Output "[conda] try: $url"; Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing -TimeoutSec 600; if ((Test-Path $installer) -and ((Get-Item $installer).Length -gt 10485760)) { $downloaded = $true; break } } catch { Write-Output "[conda:warn] download failed: $($_.Exception.Message)" } }',
      r"if (-not $downloaded) { throw 'Miniconda installer download failed. Please check network or proxy.' }",
      r"Write-Output '[conda] installing Miniconda silently...'",
      '\$arguments = @("/InstallationType=JustMe", "/RegisterPython=0", "/S", "/D=\$installDir")',
      r'Start-Process -FilePath $installer -ArgumentList $arguments -Wait',
      r'if (-not (Test-Path "$installDir\Scripts\conda.exe")) { throw "Miniconda installer finished but conda.exe was not found at $installDir\Scripts\conda.exe" }',
      'Write-Output "[conda] installed: \$installDir"',
      'Write-Output "[conda] executable: \$installDir\\Scripts\\conda.exe"',
    ].join('; ');
    return Process.start('powershell', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      command,
    ], runInShell: true);
  }

  /// 一键安装 Ollama 桌面端（winget 静默安装，AI 辅助设置页的
  /// 「一键安装 Ollama」按钮）。返回 [Process] 供调用方流式读日志；
  /// winget 不在 PATH 时脚本 exit 2，调用方可引导手动下载。
  static Future<Process> installOllamaApp() async {
    final script = [
      r"$ErrorActionPreference = 'Continue'",
      r"$ProgressPreference = 'SilentlyContinue'",
      r"Write-Output '[ollama] checking winget...'",
      r"$winget = Get-Command winget -ErrorAction SilentlyContinue",
      r'if (-not $winget) { Write-Output "[ollama:error] winget not found"; exit 2 }',
      r"Write-Output '[ollama] installing Ollama via winget (download several hundred MB, please wait)...'",
      r'& winget install --id Ollama.Ollama -e --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | ForEach-Object { [Console]::Out.WriteLine($_.ToString()) }',
      r'if ($LASTEXITCODE -ne 0) { Write-Output "[ollama:error] winget exit $LASTEXITCODE"; exit $LASTEXITCODE }',
      r"Write-Output '[ollama] Done. Ollama installed; the background service usually starts automatically.'",
    ].join('; ');
    final encodedScript = base64Encode(
      script.codeUnits.expand((unit) => [unit & 0xff, unit >> 8]).toList(),
    );
    return Process.start('powershell', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-EncodedCommand',
      encodedScript,
    ]);
  }

  /// 安装/检测后使缓存失效（conda 可能刚装好、环境可能刚变化）。
  static void invalidateCaches() {
    _condaExeCache = null;
    _cache = null;
  }

  static Future<String> _resolveCondaExecutable() async {
    final cached = _condaExeCache;
    if (cached != null) {
      _log('[detect] conda 使用缓存: $cached');
      return cached;
    }
    final home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
    final condaExeEnv = Platform.environment['CONDA_EXE']?.trim();
    final programData = Platform.environment['ProgramData'];
    final candidates = <String>[
      // 安装器写入的用户环境变量，覆盖自定义安装位置
      if (condaExeEnv != null && condaExeEnv.isNotEmpty) condaExeEnv,
      'conda',
      if (home != null && home.isNotEmpty) ...[
        '$home\\miniconda3\\Scripts\\conda.exe',
        '$home\\miniconda3\\condabin\\conda.bat',
        '$home\\anaconda3\\Scripts\\conda.exe',
      ],
      if (programData != null && programData.isNotEmpty) ...[
        '$programData\\miniconda3\\Scripts\\conda.exe',
        '$programData\\anaconda3\\Scripts\\conda.exe',
      ],
    ];
    _log('[detect] conda 候选（按顺序尝试）:');
    for (final c in candidates) {
      _log('[detect]   - $c');
    }
    for (final candidate in candidates) {
      // 绝对路径先做存在性检查（毫秒级），避免对不存在的候选白等 shell 报错
      final isPath = candidate.contains('\\') || candidate.contains('/');
      if (isPath && !File(candidate).existsSync()) {
        _log('[detect] 候选文件不存在，跳过: $candidate');
        continue;
      }
      final sw = Stopwatch()..start();
      try {
        _log('[detect] 尝试执行: $candidate --version');
        final output = await _run(
          candidate,
          ['--version'],
          timeout: const Duration(seconds: 20),
        );
        sw.stop();
        final versionLine =
            output.trim().split('\n').where((l) => l.trim().isNotEmpty).first;
        _log(
          '[detect] conda 可用: $candidate '
          '（${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s，$versionLine）',
        );
        _condaExeCache = candidate;
        return candidate;
      } catch (e) {
        sw.stop();
        final reason = e is TimeoutException ? '超时（>${20}s）' : 'exitCode!=0 或启动失败';
        _log(
          '[detect] 候选失败: $candidate '
          '（${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s，$reason）',
        );
      }
    }
    _log('[detect] 所有 conda 候选均不可用');
    throw Exception('conda not found');
  }

  /// 显卡检测：单次 nvidia-smi 全量输出解析（旧版要跑 2–3 个子进程）。
  static Future<GpuInfo> _checkGpu() async {
    try {
      final raw = await _run('nvidia-smi', [], timeout: const Duration(seconds: 10));
      final cuda = RegExp(
        r'CUDA Version:\s*([0-9]+\.[0-9]+)',
      ).firstMatch(raw)?.group(1);
      final driver = RegExp(
        r'Driver Version:\s*([0-9]+\.[0-9]+)',
      ).firstMatch(raw)?.group(1);
      final nameMatch = RegExp(r'\|\s+\d+\s+([^|]+?)\s{2,}').firstMatch(raw);
      return GpuInfo(
        available: true,
        name: nameMatch?.group(1)?.trim() ?? 'NVIDIA GPU',
        driverVersion: driver ?? '',
        driverCuda: cuda ?? '',
      );
    } catch (_) {
      return const GpuInfo(
        available: false,
        name: '',
        driverVersion: '',
        driverCuda: '',
      );
    }
  }

  static List<RuntimeOption> _runtimeOptions(String driverCuda) {
    final recommended = _recommendCuda(driverCuda);
    return [
      RuntimeOption(
        id: 'cu118',
        label: 'CUDA 11.8',
        pytorchIndex: 'https://download.pytorch.org/whl/cu118',
        pytorchLabel:
            'PyTorch cu118, compatible with older drivers and RTX 20/30 series',
        cudaRuntimeVersion: '11.8',
        recommended: recommended == 'cu118',
      ),
      RuntimeOption(
        id: 'cu126',
        label: 'CUDA 12.6',
        pytorchIndex: 'https://download.pytorch.org/whl/cu126',
        pytorchLabel: 'PyTorch cu126, recommended general GPU runtime',
        cudaRuntimeVersion: '12.6',
        recommended: recommended == 'cu126',
      ),
      RuntimeOption(
        id: 'cu129',
        label: 'CUDA 12.9',
        pytorchIndex: 'https://download.pytorch.org/whl/cu129',
        pytorchLabel: 'PyTorch cu129, for newer drivers when available',
        cudaRuntimeVersion: '12.9',
        recommended: recommended == 'cu129',
      ),
      RuntimeOption(
        id: 'cu130',
        label: 'CUDA 13.0',
        pytorchIndex: 'https://download.pytorch.org/whl/cu130',
        pytorchLabel: 'PyTorch cu130, for latest drivers when available',
        cudaRuntimeVersion: '13.0',
        recommended: recommended == 'cu130',
      ),
    ];
  }

  static String _recommendCuda(String driverCuda) {
    final parts = driverCuda.split('.');
    final major = int.tryParse(parts.isNotEmpty ? parts[0] : '');
    final minor = int.tryParse(parts.length > 1 ? parts[1] : '');
    if (major == null || minor == null) return 'cu126';
    if (major >= 13) return 'cu130';
    if (major == 12 && minor >= 9) return 'cu129';
    if (major == 12 && minor >= 6) return 'cu126';
    if (major == 11 && minor >= 8) return 'cu118';
    return 'cu126';
  }

  static Future<String> _run(
    String executable,
    List<String> args, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final result = await Process.run(
      executable,
      args,
      runInShell: true,
    ).timeout(timeout);
    final output = '${result.stdout}\n${result.stderr}';
    if (result.exitCode != 0) throw Exception(output);
    return output;
  }
}
