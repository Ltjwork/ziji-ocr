import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../models/models.dart';
import '../services/python_service.dart';
import '../widgets/backend_console_panel.dart';

/// 切分调试页：上传图片 → 跑 /segment(debug=true) → 展示可视化图。
class DebugPage extends StatefulWidget {
  /// 作为整合页（HubPage）标签嵌入时不包自己的 Scaffold；页内
  /// 可视化/日志切换条移到正文顶部。
  final bool embedded;

  const DebugPage({super.key, this.embedded = false});

  @override
  State<DebugPage> createState() => _DebugPageState();
}

class _DebugPageState extends State<DebugPage> {
  String? _imagePath;
  String _layoutMode = 'all_text';
  String _horizontalDir = 'ltr';
  String _verticalDir = 'ttb';

  bool _running = false;
  String? _error;
  String? _debugImagePath;
  String? _maskImagePath;
  int _linesCount = 0;
  int _blocksCount = 0;
  String _engine = '';
  int _tabIndex = 0; // 0=可视化结果, 1=后台日志
  int _viewMode = 0; // 0=框线图, 1=mask图, 2=并排对比

  Future<void> _pickImage() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp', 'bmp'],
    );
    if (result == null || result.files.isEmpty) return;
    final f = result.files.first;
    if (f.path == null) return;
    setState(() {
      _imagePath = f.path;
      _debugImagePath = null;
      _maskImagePath = null;
      _error = null;
      _linesCount = 0;
      _blocksCount = 0;
      _engine = '';
    });
  }

  Future<void> _run() async {
    if (_imagePath == null) {
      setState(() => _error = '请先选择图片');
      return;
    }
    setState(() {
      _running = true;
      _error = null;
      _debugImagePath = null;
      _maskImagePath = null;
    });
    try {
      final settings = ProjectSettings(
        layoutMode: _layoutMode,
        horizontalDir: _horizontalDir,
        verticalDir: _verticalDir,
      );
      final result = await PythonService.segmentDebug(
        imagePath: _imagePath!,
        settings: settings,
      );
      setState(() {
        _debugImagePath = result.debugImagePath;
        _maskImagePath = result.maskImagePath;
        _linesCount = result.linesCount;
        _blocksCount = result.blocksCount;
        _engine = result.engine;
        if (result.debugImagePath == null) {
          _error = '后端未返回可视化图（debug_image_path 为空）';
        }
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Widget _buildSegment({
    required String title,
    required String value,
    required List<({String value, String label})> options,
    required ValueChanged<String> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(title,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w500)),
          ),
          Expanded(
            child: SegmentedButton<String>(
              segments: options
                  .map((o) => ButtonSegment<String>(
                        value: o.value,
                        label: Text(o.label, style: const TextStyle(fontSize: 12)),
                      ))
                  .toList(),
              selected: {value},
              onSelectionChanged: (s) => onChanged(s.first),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDebugImage(String path, String label) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.file(
        File(path),
        fit: BoxFit.contain,
        cacheWidth: 1800,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, err, __) => Container(
          padding: const EdgeInsets.all(16),
          color: Colors.red.shade50,
          child: Text('无法加载$label：$err',
              style: TextStyle(color: Colors.red.shade700)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabSwitch = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 0, label: Text('可视化结果')),
            ButtonSegment(value: 1, label: Text('后台日志')),
          ],
          selected: {_tabIndex},
          onSelectionChanged: (s) => setState(() => _tabIndex = s.first),
        ),
      ),
    );
    final body = Column(
      children: [
        // 嵌入整合页时页内切换条搬到正文顶部（独立打开时挂在 AppBar 下）。
        if (widget.embedded) tabSwitch,
        Expanded(
          child: IndexedStack(
            index: _tabIndex,
            children: [
          SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 说明
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.amber.shade50,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.amber.shade200),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline,
                              size: 18, color: Colors.amber.shade800),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '上传一张古籍图片，点击"开始调试"后会执行切分并返回可视化结果：\n'
                              '绿框 = 行/列框，蓝框 = 单字框。',
                              style: TextStyle(
                                  fontSize: 12, color: Colors.amber.shade900),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // 图片选择
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Text('选择图片',
                                    style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600)),
                                const Spacer(),
                                FilledButton.tonalIcon(
                                  onPressed: _running ? null : _pickImage,
                                  icon: const Icon(Icons.image),
                                  label: const Text('选择图片'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            if (_imagePath == null)
                              const Text(
                                '支持 jpg / png / webp / bmp',
                                style: TextStyle(color: Colors.grey, fontSize: 12),
                              )
                            else
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 8),
                                decoration: BoxDecoration(
                                  color: Colors.blue.shade50,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  p.basename(_imagePath!),
                                  style: TextStyle(
                                      fontSize: 12, color: Colors.blue.shade700),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // 识别设置
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('识别设置',
                                style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(height: 8),
                            _buildSegment(
                              title: '识别范围',
                              value: _layoutMode,
                              options: const [
                                (value: 'main_text_only', label: '只识别正文'),
                                (value: 'all_text', label: '识别全部'),
                              ],
                              onChanged: (v) =>
                                  setState(() => _layoutMode = v),
                            ),
                            _buildSegment(
                              title: '横排方向',
                              value: _horizontalDir,
                              options: const [
                                (value: 'ltr', label: '从左到右'),
                                (value: 'rtl', label: '从右到左'),
                              ],
                              onChanged: (v) =>
                                  setState(() => _horizontalDir = v),
                            ),
                            _buildSegment(
                              title: '竖排方向',
                              value: _verticalDir,
                              options: const [
                                (value: 'ttb', label: '从上到下'),
                                (value: 'btt', label: '从下到上'),
                              ],
                              onChanged: (v) =>
                                  setState(() => _verticalDir = v),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    if (_error != null)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _error!,
                          style:
                              TextStyle(fontSize: 12, color: Colors.red.shade700),
                        ),
                      ),

                    // 运行按钮
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: (_running || _imagePath == null) ? null : _run,
                        icon: _running
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.play_arrow),
                        label: Text(_running ? '正在切分…' : '开始调试'),
                      ),
                    ),

                    // 结果
                    if (_debugImagePath != null) ...[
                      const SizedBox(height: 24),
                      const Text('切分结果',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 12,
                        children: [
                          Chip(
                            label: Text('引擎: $_engine'),
                            visualDensity: VisualDensity.compact,
                          ),
                          Chip(
                            label: Text('行数: $_linesCount'),
                            visualDensity: VisualDensity.compact,
                          ),
                          Chip(
                            label: Text('单字数: $_blocksCount'),
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      // 视图切换
                      if (_maskImagePath != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: SegmentedButton<int>(
                            segments: const [
                              ButtonSegment(value: 0, label: Text('框线图')),
                              ButtonSegment(value: 1, label: Text('墨迹图')),
                              ButtonSegment(value: 2, label: Text('并排对比')),
                            ],
                            selected: {_viewMode},
                            onSelectionChanged: (s) =>
                                setState(() => _viewMode = s.first),
                          ),
                        ),
                      // 图片展示
                      if (_viewMode == 2 && _maskImagePath != null)
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 350,
                                child: _buildDebugImage(_debugImagePath!, '框线图'),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 350,
                                child: _buildDebugImage(_maskImagePath!, '墨迹图'),
                              ),
                            ],
                          ),
                        )
                      else if (_viewMode == 1 && _maskImagePath != null)
                        _buildDebugImage(_maskImagePath!, '墨迹图')
                      else
                        _buildDebugImage(_debugImagePath!, '可视化图'),
                      const SizedBox(height: 8),
                      Text(
                        _viewMode == 1 && _maskImagePath != null
                            ? '墨迹图路径：$_maskImagePath'
                            : '可视化图路径：$_debugImagePath',
                        style: const TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const BackendConsolePanel(),
            ],
          ),
        ),
      ],
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(
        title: const Text('切分调试'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: tabSwitch,
        ),
      ),
      body: body,
    );
  }
}