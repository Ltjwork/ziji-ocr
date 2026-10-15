import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import '../services/python_service.dart';
import '../services/storage.dart';
import 'training_curve_dialog.dart';
import 'model_cleanup_dialog.dart';
import '../widgets/model_run_tile.dart';

/// 模型使用管理：集中查看/配置五个层级（正文区/段落/行/单字检测/单字候选
/// 分类）各自使用的自训模型。
///
/// - 全局启用：对所有项目生效（等价于训练页卡片上的启用/停用）；
/// - 项目覆写：选择某个项目后，可单独指定该项目某层使用哪一次训练的
///   模型（或不使用模型走基线），仅对该项目生效，配置保存在该项目的
///   project.json 中。
class ModelManagePage extends StatefulWidget {
  /// 作为整合页（HubPage）标签嵌入时不包自己的 Scaffold；刷新按钮
  /// 移入「配置对象」行末尾。
  final bool embedded;

  const ModelManagePage({super.key, this.embedded = false});

  @override
  State<ModelManagePage> createState() => _ModelManagePageState();
}

class _ManagedLayer {
  final String key;
  final String label;
  const _ManagedLayer(this.key, this.label);
}

const _managedLayers = [
  _ManagedLayer('region_det', '正文区检测'),
  _ManagedLayer('paragraph_det', '段落检测'),
  _ManagedLayer('line_det', '行检测'),
  _ManagedLayer('char_det', '单字检测（切字框）'),
  _ManagedLayer('char_cls', '单字候选分类'),
];
// 墨迹比对模型（verify_pair）不走这里——训练与激活在训练页的专属卡片
// 上（非 ultralytics 训练器，注册表层键为 verify_pair）。

class _ModelManagePageState extends State<ModelManagePage> {
  List<Project> _projects = [];
  Project? _project; // null = 查看/配置全局
  Map<String, Map<String, dynamic>> _models = {};
  bool _loading = true;
  String? _error;
  final Set<String> _busy = {};

  /// 数据集/训练模型根目录配置（train_paths.json）；应用模型目录
  /// （models/）从 config_path 推导。
  Map<String, dynamic> _paths = {};
  final Set<String> _pathBusy = {};

  /// 发版打包进行中（POST /models/pack，几秒到几分钟，期间按钮禁用）。
  bool _packing = false;

  /// 多选批量删除模式：开启后每个模型版本（best/last/第 N 轮）前出现
  /// 勾选框，顶栏出现 全选/反选/删除所选。
  bool _selectMode = false;

  /// 已勾选的检查点：路径 → 所属层（删除接口需要 layer）。
  final Map<String, String> _selected = {};

  /// 批量删除进行中（进度文案展示在多选工具条上）。
  bool _batchDeleting = false;
  String? _batchProgress;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final docs = await getApplicationDocumentsDirectory();
      final root = p.join(docs.path, 'GujiBT');
      final projects = await ProjectStorage.loadAll(root);
      projects.sort((a, b) => a.id.compareTo(b.id));
      final models = await PythonService.listModels();
      Map<String, dynamic> paths = {};
      try {
        paths = await PythonService.trainPathsGet();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _paths = paths;
        _projects = projects;
        // 选中的项目按 id 重新指向磁盘上的新实例（保持覆写配置最新）。
        final keepId = _project?.id;
        _project = null;
        if (keepId != null) {
          for (final pr in projects) {
            if (pr.id == keepId) {
              _project = pr;
              break;
            }
          }
        }
        _models = models;
        // 多选勾选清理：列表刷新后已不存在的检查点路径自动落选
        final livePaths = <String>{};
        for (final entry in models.values) {
          for (final raw in (entry['runs'] as List?) ?? const []) {
            for (final rawCk
                in ((raw as Map)['checkpoints'] as List?) ?? const []) {
              livePaths.add((rawCk as Map)['path']?.toString() ?? '');
            }
          }
        }
        _selected.removeWhere((k, v) => !livePaths.contains(k));
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _activate(String layer, {String? modelPath}) async {
    setState(() => _busy.add(layer));
    try {
      await PythonService.activateModel(layer, modelPath: modelPath);
      final models = await PythonService.listModels();
      if (!mounted) return;
      setState(() => _models = models);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$layer 模型已启用，后续识别自动使用')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('启用失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _busy.remove(layer));
    }
  }

  Future<void> _deactivate(String layer) async {
    setState(() => _busy.add(layer));
    try {
      await PythonService.deactivateModel(layer);
      final models = await PythonService.listModels();
      if (!mounted) return;
      setState(() => _models = models);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('停用失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _busy.remove(layer));
    }
  }

  /// 清理训练模型目录：扫描各 run 占用，按 run 清理中间轮/删残目录。
  Future<void> _openCleanupCenter() async {
    await showDialog<void>(
      context: context,
      builder: (_) => const ModelCleanupDialog(),
    );
    unawaited(_load());
  }

  /// 当前页面上所有可勾选（可删除）的检查点：跨层扁平清单，排除当前
  /// 启用来源（唯一不可删项；其运行副本独立，删除其余不影响推理）。
  List<({String layer, String path, String name, int size, String runName})>
      _allDeletableCheckpoints() {
    String norm(String s) =>
        p.normalize(s).replaceAll('/', '\\').toLowerCase();
    final out = <({String layer, String path, String name, int size, String runName})>[];
    _models.forEach((layer, entry) {
      final activeSource = entry['active_source']?.toString();
      final activeNc = (activeSource == null || activeSource.isEmpty)
          ? null
          : norm(activeSource);
      for (final raw in (entry['runs'] as List?) ?? const []) {
        final run = Map<String, dynamic>.from(raw as Map);
        final runDir = run['run_dir']?.toString() ?? '';
        final runName = p.basename(runDir).replaceFirst(RegExp(r'^run_'), '');
        for (final rawCk in (run['checkpoints'] as List?) ?? const []) {
          final ck = Map<String, dynamic>.from(rawCk as Map);
          final path = ck['path']?.toString() ?? '';
          if (path.isEmpty) continue;
          if (activeNc != null && norm(path) == activeNc) continue;
          out.add((
            layer: layer,
            path: path,
            name: ck['name']?.toString() ?? p.basename(path),
            size: ((ck['size'] as num?) ?? 0).toInt(),
            runName: runName,
          ));
        }
      }
    });
    return out;
  }

  void _enterSelectMode() => setState(() {
        _selectMode = true;
        _selected.clear();
      });

  void _exitSelectMode() => setState(() {
        _selectMode = false;
        _selected.clear();
      });

  void _selectAll() {
    for (final ck in _allDeletableCheckpoints()) {
      _selected[ck.path] = ck.layer;
    }
    setState(() {});
  }

  void _invertSelection() {
    for (final ck in _allDeletableCheckpoints()) {
      if (_selected.remove(ck.path) == null) {
        _selected[ck.path] = ck.layer;
      }
    }
    setState(() {});
  }

  /// 批量删除勾选的模型文件：逐个走 /models/delete_checkpoint（当前启
  /// 用来源由后端拒绝），完成后汇总成功/释放/失败。
  Future<void> _deleteSelected() async {
    final byPath = {
      for (final ck in _allDeletableCheckpoints()) ck.path: ck
    };
    final targets = <({String layer, String path, String name, int size, String runName})>[];
    for (final path in _selected.keys) {
      final ck = byPath[path];
      if (ck != null) targets.add(ck);
    }
    if (targets.isEmpty) return;
    final totalMb =
        targets.fold<int>(0, (s, ck) => s + ck.size) / 1024 / 1024;
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('批量删除 ${targets.length} 个模型文件'),
        content: Text(
            '共约 ${totalMb.toStringAsFixed(1)} MB，删除后不可恢复。\n'
            '正在使用的版本已自动排除；删除某次训练的 best 后，'
            '该训练保留剩余轮数与训练曲线，只是不再有 best 标记。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Colors.red.shade400),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _batchDeleting = true;
      _batchProgress = null;
    });
    var deleted = 0;
    var freedBytes = 0;
    final failures = <String>[];
    try {
      for (var i = 0; i < targets.length; i++) {
        final ck = targets[i];
        if (!mounted) return;
        setState(() =>
            _batchProgress = '正在删除 ${i + 1}/${targets.length}：${ck.name}');
        try {
          await PythonService.deleteModelCheckpoint(
              layer: ck.layer, path: ck.path);
          deleted++;
          freedBytes += ck.size;
          _selected.remove(ck.path);
        } catch (e) {
          failures.add('${ck.runName}/${ck.name}');
        }
      }
      await _load();
      if (!mounted) return;
      final msg = '已删除 $deleted 个，释放 '
          '${(freedBytes / 1024 / 1024).toStringAsFixed(1)} MB'
          '${failures.isEmpty ? '' : '；失败 ${failures.length} 个'
              '（如 ${failures.first}，多为正在使用的版本）'}';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    } finally {
      if (mounted) {
        setState(() {
          _batchDeleting = false;
          _batchProgress = null;
        });
      }
    }
  }

  /// 导入外部 .pt 模型为该层的一个 run：复制进训练根并登记，与训练
  /// 产物同等管理（启用/删除/对比测试/按轮启用）。
  Future<void> _importModel(_ManagedLayer layer) async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pt'],
      dialogTitle: '选择要导入的${layer.label}模型（.pt）',
    );
    if (picked == null || picked.files.isEmpty) return;
    final path = picked.files.single.path;
    if (path == null || !mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('导入${layer.label}模型'),
        content: Text('$path\n\n'
            '复制进训练模型目录并登记为一个新 run，'
            '可随时启用、删除或参与对比测试（导入的模型没有训练曲线）。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy.add(layer.key));
    try {
      await PythonService.importModel(layer: layer.key, path: path);
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入为${layer.label}新模型，可在列表里启用')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove(layer.key));
    }
  }

  /// 删除一个中间轮检查点（epoch{N}.pt）释放磁盘：确认框 → 后端拒绝
  /// best/last 与当前启用来源 → 刷新模型列表与检查点清单。
  Future<void> _deleteCheckpoint(String layer, String path) async {
    final name = p.basename(path);
    final sizeMb = (await File(path).length()) / 1024 / 1024;
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除模型文件'),
        content: Text(
            '$name（约 ${sizeMb.toStringAsFixed(0)} MB）删除后不可恢复。\n'
            '当前启用的模型是独立副本，不受影响。'
            '${name == 'best.pt' ? '\n注意：best 是该 run 的登记产物，删除后该 run 将失去 best 标记（剩余轮数与训练曲线保留）。' : ''}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade400),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await PythonService.deleteModelCheckpoint(layer: layer, path: path);
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已删除：$name')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败：$e')),
        );
      }
    }
  }

  /// 发版打包确认框：输入包版本号（预填当天日期）后执行。只打包当前
  /// 各层「启用中」的模型——训练里弃用的 run 永不进包。
  Future<void> _confirmPackRelease() async {
    final now = DateTime.now();
    final ymd =
        '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}';
    final controller = TextEditingController(text: ymd);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('打包发版'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '把当前各层启用中的模型（无启用层的打基线）与 Kraken 识别模型'
              '打成签名的 models_release.zjpack，随安装包分发。',
              style: TextStyle(fontSize: 12.5),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: '包版本号',
                hintText: '如 20261009',
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('打包'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _packing = true);
    try {
      final result = await PythonService.packModels(
        packVersion: controller.text.trim(),
      );
      if (!mounted) return;
      _showPackResult(result);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('打包失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _packing = false);
    }
  }

  /// 打包结果：条目清单（来源溯源 + 大小 + 整包哈希），可复制进 CHANGELOG。
  void _showPackResult(Map<String, dynamic> result) {
    final buf = StringBuffer();
    final sizeMb = ((result['size_bytes'] as num?) ?? 0) / 1e6;
    buf.writeln(
      '模型包 v${result['pack_version']} · ${sizeMb.toStringAsFixed(1)}MB',
    );
    buf.writeln('sha256=${result['sha256']}');
    final layers = (result['layers'] as Map?)?.cast<String, dynamic>() ?? {};
    final entries = (result['entries'] as List?) ?? const [];
    for (final e in entries) {
      final m = (e as Map).cast<String, dynamic>();
      final kind = m['kind']?.toString() ?? '';
      if (kind == 'manifest') continue;
      final prov = (layers[kind] as Map?)?.cast<String, dynamic>();
      final src = prov == null
          ? ''
          : (prov['run'] ?? prov['file'] ?? prov['source'] ?? '')
              .toString();
      buf.writeln(
        '${m['name']}  '
        '${(((m['length'] as num?) ?? 0) / 1e6).toStringAsFixed(1)}MB'
        '${src.isEmpty ? '' : '  ← $src'}',
      );
    }
    final text = buf.toString();
    final packPath = result['path']?.toString() ?? '';
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('打包完成'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: SelectableText(
              text,
              style: const TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                height: 1.5,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(content: Text('清单已复制，可粘贴进更新日志')),
              );
            },
            child: const Text('复制清单'),
          ),
          if (packPath.isNotEmpty)
            TextButton(
              onPressed: () => _openFolder(p.dirname(packPath)),
              child: const Text('打开所在文件夹'),
            ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 保存所选项目的层级模型覆写；path 为 null 表示移除覆写（回到全局）。
  Future<void> _setProjectOverride(String layer, String? path) async {
    final project = _project;
    if (project == null) return;
    setState(() {
      if (path == null) {
        project.modelOverrides.remove(layer);
      } else {
        project.modelOverrides[layer] = path;
      }
    });
    try {
      await ProjectStorage.save(project);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已保存「${project.name}」的模型配置')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存失败：$e')));
      }
    }
  }

  Future<void> _openFolder(String path) async {
    try {
      await Process.run('explorer.exe', [path]);
    } catch (_) {}
  }

  /// 选择并保存目录配置（dataset_root / trained_root）。空 = 取消。
  Future<void> _pickAndSavePath(String key, String label) async {
    if (_pathBusy.contains(key)) return;
    final current = _paths[key] as String? ?? '';
    setState(() => _pathBusy.add(key));
    try {
      final picked = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择$label 文件夹',
        initialDirectory: current.isNotEmpty && Directory(current).existsSync()
            ? current
            : null,
      );
      if (picked == null || picked.isEmpty) return;
      await PythonService.trainPathsSet(
        datasetRoot: key == 'dataset_root' ? picked : '',
        trainedRoot: key == 'trained_root' ? picked : '',
      );
      final paths = await PythonService.trainPathsGet();
      if (!mounted) return;
      setState(() => _paths = paths);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已设置$label：$picked（热生效，无需重启）')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('设置失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _pathBusy.remove(key));
    }
  }

  /// 删除一次训练 run（目录+注册表条目；启用中的先自动停用）。
  Future<void> _confirmDeleteRun(String layer, Map<String, dynamic> run) async {
    final runDir = run['run_dir'] as String? ?? '';
    if (runDir.isEmpty) return;
    double sizeMb = 0;
    try {
      sizeMb = await PythonService.modelRunSize(runDir);
    } catch (_) {}
    if (!mounted) return;
    final name = p.basename(runDir);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除训练 $name？'),
        content: Text(
          '将删除该 run 的全部产物（${sizeMb > 0 ? '${sizeMb.toStringAsFixed(0)} MB' : '含权重与曲线'}）'
          '并从注册表移除；${run['best'] != null && (run['best'] as String).isNotEmpty ? '若它正是当前启用的模型，会先自动停用。' : ''}'
          '此操作不可撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade700,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy.add(layer));
    try {
      await PythonService.deleteModelRun(layer: layer, runDir: runDir);
      final models = await PythonService.listModels();
      if (!mounted) return;
      setState(() => _models = models);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已删除 $name（${sizeMb.toStringAsFixed(0)} MB）')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('删除失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _busy.remove(layer));
    }
  }

  String _baseName(String path) =>
      path.replaceAll('\\', '/').split('/').last;

  String _runDirName(String bestPath) {
    final dir = p.basename(p.dirname(p.dirname(p.dirname(bestPath))));
    return dir.replaceFirst(RegExp(r'^run_'), '');
  }

  /// 检查点文件短名：best / last / 第 N 轮。
  String _ckptLabel(String path) {
    final name = _baseName(path);
    final epoch = RegExp(r'^epoch(\d+)\.pt$').firstMatch(name);
    if (epoch != null) return '第 ${epoch.group(1)} 轮';
    if (name == 'best.pt') return 'best';
    if (name == 'last.pt') return 'last';
    return name;
  }

  /// 当前启用模型的展示：优先溯源到来源 run 与具体文件（best/第 N 轮），
  /// 旧注册表没有 active_source 时退回稳定副本文件名。
  String _activeDisplay(Map<String, dynamic> entry, String active) {
    final source = entry['active_source'] as String?;
    if (source == null || source.isEmpty) return _baseName(active);
    return '${_runDirName(source)} · ${_ckptLabel(source)}';
  }

  /// 打开该 run 的训练曲线弹窗：按逐轮指标挑中间检查点（best/last/
  /// 第 N 轮）直接启用——onActivate 走 /models/activate（收任意 .pt）。
  void _showRunCurve(_ManagedLayer layer, Map<String, dynamic> run) {
    final runDir = run['run_dir']?.toString() ?? '';
    if (runDir.isEmpty) return;
    final label = p.basename(runDir).replaceFirst(RegExp(r'^run_'), '');
    showDialog(
      context: context,
      builder: (ctx) => TrainingCurveDialog(
        runs: [(dir: runDir, label: label)],
        title: '${layer.label} · $label',
        activePath: (_models[layer.key]?['active_source'] as String?) ??
            (_models[layer.key]?['active'] as String?),
        onActivate: (path) => _activate(layer.key, modelPath: path),
        onDeleteCheckpoint: (path) async {
          await PythonService.deleteModelCheckpoint(
              layer: layer.key, path: path);
          await _load();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
        ? Center(
            child: Text('加载失败：$_error', style: const TextStyle(fontSize: 12)),
          )
        : _buildBody();
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(
        title: const Text('模型使用管理'),
        actions: [
          IconButton(
            icon: Icon(Icons.checklist,
                color: _selectMode ? Colors.blue.shade700 : null),
            tooltip: _selectMode ? '退出多选' : '多选（批量删除）',
            onPressed:
                _selectMode ? _exitSelectMode : _enterSelectMode,
          ),
          IconButton(
            icon: const Icon(Icons.cleaning_services),
            tooltip: '清理训练模型目录',
            onPressed: _openCleanupCenter,
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: body,
    );
  }

  Widget _buildBody() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Row(
            children: [
              const Text('配置对象：', style: TextStyle(fontSize: 13)),
              const SizedBox(width: 8),
              DropdownButton<Project?>(
                value: _project,
                items: [
                  const DropdownMenuItem(
                    value: null,
                    child: Text('全局默认（所有项目）', style: TextStyle(fontSize: 12)),
                  ),
                  for (final pr in _projects)
                    DropdownMenuItem(
                      value: pr,
                      child: Text('项目：${pr.name}', style: const TextStyle(fontSize: 12)),
                    ),
                ],
                onChanged: (v) => setState(() => _project = v),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _project == null
                      ? '全局启用对所有未单独配置的项目生效'
                      : '「${_project!.name}」的覆写仅对该项目生效，已单独配置的层不受全局启停影响',
                  style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700),
                ),
              ),
              if (widget.embedded) ...[
                const SizedBox(width: 8),
                IconButton(
                  icon: Icon(Icons.checklist,
                      size: 20,
                      color: _selectMode
                          ? Colors.blue.shade700
                          : null),
                  tooltip: _selectMode ? '退出多选' : '多选（批量删除）',
                  onPressed:
                      _selectMode ? _exitSelectMode : _enterSelectMode,
                ),
                IconButton(
                  icon: const Icon(Icons.cleaning_services, size: 19),
                  tooltip: '清理训练模型目录',
                  onPressed: _openCleanupCenter,
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 20),
                  tooltip: '刷新',
                  onPressed: _load,
                ),
              ],
            ],
          ),
        ),
        const Divider(height: 16),
        // 路径与文件夹入口：数据集统一目录 / 训练模型目录（可配置），
        // 应用模型目录（models/，启用=拷贝到这里）只读直达
        _buildPathsPanel(),
        if (_selectMode) _buildSelectionBar(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              for (final layer in _managedLayers)
                _buildLayerCard(layer),
            ],
          ),
        ),
      ],
    );
  }

  /// 多选模式工具条：全选/反选/批量删除（勾选时显示已选数量与体积）。
  Widget _buildSelectionBar() {
    final all = _allDeletableCheckpoints();
    final selectedCks =
        all.where((ck) => _selected.containsKey(ck.path)).toList();
    final selectedMb = selectedCks.fold<int>(0, (s, ck) => s + ck.size) /
        1024 / 1024;
    return Container(
      color: Colors.blueGrey.shade50,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: _batchDeleting
          ? Row(children: [
              const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(_batchProgress ?? '正在删除…',
                    style: const TextStyle(fontSize: 12)),
              ),
            ])
          : Row(children: [
              Text(
                '已选 ${_selected.length} 个'
                '${selectedMb > 0 ? ' · 约 ${selectedMb.toStringAsFixed(1)} MB' : ''}',
                style: const TextStyle(fontSize: 12.5),
              ),
              const Spacer(),
              TextButton(
                onPressed: all.isEmpty ? null : _selectAll,
                child: const Text('全选', style: TextStyle(fontSize: 12)),
              ),
              TextButton(
                onPressed: all.isEmpty ? null : _invertSelection,
                child: const Text('反选', style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 4),
              FilledButton.icon(
                onPressed:
                    _selected.isEmpty ? null : () => unawaited(_deleteSelected()),
                icon: const Icon(Icons.delete_outline, size: 16),
                label: Text('删除所选${_selected.isEmpty ? '' : '（${_selected.length}）'}',
                    style: const TextStyle(fontSize: 12)),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.red.shade400,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              TextButton(
                onPressed: _exitSelectMode,
                child: const Text('取消', style: TextStyle(fontSize: 12)),
              ),
            ]),
    );
  }

  Widget _buildPathsPanel() {
    final datasetRoot = _paths['dataset_root'] as String? ?? '';
    final trainedRoot = _paths['trained_root'] as String? ?? '';
    final configPath = _paths['config_path'] as String? ?? '';
    final serviceDir = configPath.isNotEmpty ? p.dirname(configPath) : '';
    final appModelsDir =
        serviceDir.isNotEmpty ? p.join(serviceDir, 'models') : '';
    Widget pathRow(String key, String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(label, style: const TextStyle(fontSize: 12)),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '（默认位置）' : value,
              style: TextStyle(
                fontSize: 11.5,
                color: Colors.grey.shade700,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (value.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.folder_open, size: 16),
              tooltip: '打开文件夹',
              visualDensity: VisualDensity.compact,
              onPressed: () => _openFolder(value),
            ),
          OutlinedButton(
            onPressed:
                _pathBusy.contains(key) ? null : () => _pickAndSavePath(key, label),
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            child: Text(
              _pathBusy.contains(key) ? '…' : '选择',
              style: const TextStyle(fontSize: 11.5),
            ),
          ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '数据与模型位置',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade800,
                  ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: _packing ? null : _confirmPackRelease,
                icon: _packing
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.inventory_2_outlined, size: 16),
                label: Text(
                  _packing ? '打包中…' : '打包发版',
                  style: const TextStyle(fontSize: 11.5),
                ),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
              ),
            ],
          ),
          pathRow('dataset_root', '数据集目录', datasetRoot),
          pathRow('trained_root', '训练模型目录', trainedRoot),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              children: [
                const SizedBox(
                  width: 92,
                  child: Text(
                    '应用模型目录',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                Expanded(
                  child: Text(
                    appModelsDir.isEmpty ? 'models/' : appModelsDir,
                    style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.folder_open, size: 16),
                  tooltip: '打开应用模型文件夹（启用中的模型拷贝存放在这里）',
                  visualDensity: VisualDensity.compact,
                  onPressed: appModelsDir.isEmpty
                      ? null
                      : () => _openFolder(appModelsDir),
                ),
                const SizedBox(width: 8),
                Text(
                  '数据集文件夹可整体拷到另一台电脑：清单与统计随行',
                  style: TextStyle(fontSize: 10.5, color: Colors.grey.shade500),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLayerCard(_ManagedLayer layer) {
    final entry = _models[layer.key] ?? const {};
    final active = entry['active'] as String?;
    final activeMetrics = entry['active_metrics'] as Map<String, dynamic>?;
    // best 被单独删除的 run 仍显示（按 run_dir + 剩余检查点渲染），
    // 只有彻底空壳（无 best 无检查点）的占位条目才过滤掉。
    final runs = ((entry['runs'] as List?) ?? const [])
        .map((r) => Map<String, dynamic>.from(r as Map))
        .where((r) =>
            (r['best'] as String?)?.isNotEmpty == true ||
            ((r['checkpoints'] as List?) ?? const []).isNotEmpty)
        .toList();

    final map50 = activeMetrics?['metrics/mAP50(B)'];
    final override = _project?.modelOverrides[layer.key];

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  active != null ? Icons.check_circle : Icons.radio_button_unchecked,
                  size: 16,
                  color: active != null ? Colors.green : Colors.grey,
                ),
                const SizedBox(width: 8),
                Text(
                  layer.label,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.upload_file, size: 16),
                  tooltip: '导入外部 .pt 模型为该层新模型',
                  visualDensity: VisualDensity.compact,
                  onPressed: _busy.contains(layer.key)
                      ? null
                      : () => unawaited(_importModel(layer)),
                ),
                if (_project != null)
                  Text(
                    override == null
                        ? '本项目：跟随全局'
                        : override == ''
                        ? '本项目：不使用模型（基线）'
                        : '本项目：${_runDirName(override)}',
                    style: TextStyle(fontSize: 11, color: Colors.blue.shade700),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              active == null
                  ? '全局：未启用模型（该层走基线识别）'
                  : '全局：${_activeDisplay(entry, active)}'
                        '${map50 is num ? ' · mAP50 ${map50.toStringAsFixed(2)}' : ''}',
              style: TextStyle(
                fontSize: 12,
                color: active != null ? Colors.green.shade700 : Colors.grey.shade600,
              ),
            ),
            if (runs.isEmpty) ...[
              const SizedBox(height: 6),
              Text(
                '还没有训练产出（训练成功后会出现在这里）',
                style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
              ),
            ],
            for (final run in runs)
              ModelRunTile(
                run: run,
                metricLabel:
                    layer.key == 'char_cls' ? 'top1' : 'mAP50-95',
                activeSource: entry['active_source'] as String?,
                projectMode: _project != null,
                projectOverride: _project?.modelOverrides[layer.key],
                selectionMode: _selectMode,
                isSelected: (path) => _selected.containsKey(path),
                onToggleSelect: (path, v) => setState(() {
                  if (v) {
                    _selected[path] = layer.key;
                  } else {
                    _selected.remove(path);
                  }
                }),
                onActivate: (path) => _activate(layer.key, modelPath: path),
                onProjectUse: (path) =>
                    _setProjectOverride(layer.key, path),
                onDeleteCheckpoint: (path) =>
                    _deleteCheckpoint(layer.key, path),
                onShowCurve: () => _showRunCurve(layer, run),
                onDeleteRun: () async {
                  await _confirmDeleteRun(layer.key, run);
                },
              ),
            if (active != null) ...[
              const SizedBox(height: 2),
              Row(
                children: [
                  if (runs.isNotEmpty)
                    TextButton.icon(
                      onPressed: () => _openFolder(
                        p.dirname(
                          p.dirname(
                            p.dirname(runs.last['best'] as String),
                          ),
                        ),
                      ),
                      icon: const Icon(Icons.folder_open, size: 15),
                      label: const Text(
                        '打开模型目录',
                        style: TextStyle(fontSize: 11.5),
                      ),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: _busy.contains(layer.key)
                        ? null
                        : () => _deactivate(layer.key),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.red.shade700,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: const Text('停用（走基线）', style: TextStyle(fontSize: 11.5)),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
