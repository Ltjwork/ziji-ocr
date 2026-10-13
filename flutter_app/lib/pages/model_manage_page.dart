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
    final best = run['best']?.toString() ?? '';
    if (runDir.isEmpty || best.isEmpty) return;
    final label = _runDirName(best);
    showDialog(
      context: context,
      builder: (ctx) => TrainingCurveDialog(
        runs: [(dir: runDir, label: label)],
        title: '${layer.label} · $label',
        activePath: (_models[layer.key]?['active_source'] as String?) ??
            (_models[layer.key]?['active'] as String?),
        onActivate: (path) => _activate(layer.key, modelPath: path),
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
    final runs = ((entry['runs'] as List?) ?? const [])
        .map((r) => Map<String, dynamic>.from(r as Map))
        .where((r) => (r['best'] as String?)?.isNotEmpty == true)
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
            for (final run in runs) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_runDirName(run['best'] as String)} · '
                      '${run['epochs'] ?? '?'} 轮'
                      '${run['metrics'] is Map && (run['metrics'] as Map)['metrics/mAP50(B)'] is num ? ' · mAP50 ${(run['metrics'] as Map)['metrics/mAP50(B)'].toStringAsFixed(2)}' : ''}',
                      style: const TextStyle(fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(
                    onPressed: _busy.contains(layer.key)
                        ? null
                        : () => _activate(
                            layer.key,
                            modelPath: run['best'] as String,
                          ),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: Text(
                      _project == null ? '启用' : '启用为全局',
                      style: const TextStyle(fontSize: 11.5),
                    ),
                  ),
                  if (_project != null)
                    TextButton(
                      onPressed: () =>
                          _setProjectOverride(layer.key, run['best'] as String),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      child: Text(
                        '本项目使用',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: Colors.blue.shade700,
                        ),
                      ),
                    ),
                  IconButton(
                    icon: const Icon(Icons.show_chart, size: 16),
                    tooltip: '训练曲线 · 按轮启用（best/last/第 N 轮）',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _showRunCurve(layer, run),
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.delete_outline,
                      size: 16,
                      color: Colors.red.shade400,
                    ),
                    tooltip: '删除该 run（目录+注册表条目；启用中先自动停用）',
                    visualDensity: VisualDensity.compact,
                    onPressed: _busy.contains(layer.key)
                        ? null
                        : () => unawaited(_confirmDeleteRun(layer.key, run)),
                  ),
                ],
              ),
            ],
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
