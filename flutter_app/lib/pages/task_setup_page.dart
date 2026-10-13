import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../models/models.dart';
import '../services/book_import.dart';
import '../services/python_service.dart';
import '../services/recognition_queue.dart';
import '../services/storage.dart';
import '../services/ollama_service.dart';
import '../widgets/engine_settings_section.dart';
import 'book_split_page.dart';
import 'straighten_batch_page.dart';

class TaskSetupPage extends StatefulWidget {
  final String rootDir;
  const TaskSetupPage({super.key, required this.rootDir});

  @override
  State<TaskSetupPage> createState() => _TaskSetupPageState();
}

class _TaskSetupPageState extends State<TaskSetupPage> {
  final _nameController = TextEditingController();
  final _authorController = TextEditingController();
  final _editionController = TextEditingController();
  final _volumeController = TextEditingController();
  final _sourceController = TextEditingController();
  List<PlatformFile> _picked = [];
  String _sourceFileType = 'images'; // 'images' | 'pdf'
  bool _autoNamed = true;

  String _layoutMode = 'main_text_only'; // 'main_text_only' | 'all_text'
  String _orientation = 'vertical'; // 'horizontal' | 'vertical'
  String _horizontalDir = 'rtl'; // 'ltr' | 'rtl'（古籍竖排的列序：右→左）
  String _verticalDir = 'ttb'; // 'ttb' | 'btt'
  String _engine = 'kraken'; // 'kraken' | 'paddle'（每本书可选识别引擎）
  String _paddleModel = 'PP-OCRv6_small_rec'; // paddle 引擎的模型档位

  /// 用户已手动改过模型档位（改过则不再用全局默认快照覆盖）。
  bool _paddleModelTouched = false;

  /// 勾选后新书不自动排队识别：先进入书籍整理页面，再在首页/编辑器
  /// 手动开始整本识别。
  bool _manualStart = true;

  /// 导入后先进入跨页拆分：左右两页合扫的跨页图按中缝拆成两页（编辑器
  /// 「跨页拆分」同款交互），拆完再进入后续步骤。默认关：绝大多数导入
  /// 是单页扫描，直接进摆正/识别，需要拆跨页时再手动勾。
  bool _autoSplit = false;

  /// 拆分后进入批量摆正（仿白描"校对摆正"）：智能检测每页裁切点并
  /// 透视拉平，可预览/单页微调，完成后再进入识别流程。
  bool _autoStraighten = true;
  bool _aiRecognitionAssist = false;
  bool _aiRecognitionAssistTouched = false;

  bool _creating = false;
  String? _error;

  /// 创建进行中的秒数（按钮文案显示"已 Ns"——大 PDF 转图要数分钟，
  /// 一个会走的数字说明没卡死，避免用户以为挂了直接关应用）。
  int _creatingSeconds = 0;
  Timer? _creatingTimer;

  /// PDF 转图阶段（_creatingPhase='pdf'）的逐页进度：按钮文案显示
  /// "第 N/M 页"。
  String _creatingPhase = ''; // '' = 复制/收尾，'pdf' = 逐页转图
  int _pdfCurrent = 0;
  int _pdfTotal = 0;

  @override
  void initState() {
    super.initState();
    // A new task takes a snapshot of the global whole-book AI setting.  The
    // old page always started with false, so enabling the switch in AI
    // settings had no effect unless it was toggled again here.
    OllamaSettings.load().then((settings) {
      if (!mounted) return;
      setState(() {
        if (!_aiRecognitionAssistTouched) {
          _aiRecognitionAssist = settings.enableLineAssist;
        }
        // PaddleOCR 默认档同样取全局快照（设置页「PaddleOCR 模型」卡里
        // 选择；用户已在本页手动改过模型则不覆盖）。
        if (!_paddleModelTouched) {
          _paddleModel = settings.paddleModel;
        }
      });
    });
  }

  @override
  void dispose() {
    _creatingTimer?.cancel();
    _nameController.dispose();
    _authorController.dispose();
    _editionController.dispose();
    _volumeController.dispose();
    _sourceController.dispose();
    super.dispose();
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'pdf'],
    );
    if (result == null || result.files.isEmpty) return;

    final hasPdf = result.files.any((f) => f.extension?.toLowerCase() == 'pdf');
    // 导入崩溃排查：文件选择完成后立即记录清单与总大小，锁定崩溃发生
    // 在选择阶段（平台文件对话框）还是之后的复制/转图阶段。
    final totalMb =
        result.files.fold<int>(0, (sum, f) => sum + f.size) / (1 << 20);
    PythonService.addAppLog(
      '已选择 ${result.files.length} 个文件（合计 ${totalMb.toStringAsFixed(1)}MB）：'
      '${result.files.map((f) => f.name).join('、')}',
    );
    setState(() {
      _picked = result.files;
      _sourceFileType = hasPdf ? 'pdf' : 'images';
      if (_autoNamed || _nameController.text.isEmpty) {
        final first = result.files.first;
        final base = first.name;
        final dot = base.lastIndexOf('.');
        _nameController.text = dot > 0 ? base.substring(0, dot) : base;
        _autoNamed = true;
      }
    });
  }

  void _onNameChanged(String v) => _autoNamed = false;

  Future<void> _create() async {
    if (_picked.isEmpty) {
      setState(() => _error = '请先选择文件');
      return;
    }
    if (_nameController.text.trim().isEmpty) {
      setState(() => _error = '任务名称不能为空');
      return;
    }

    setState(() {
      _creating = true;
      _creatingSeconds = 0;
      _error = null;
    });
    _creatingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _creatingSeconds++);
    });
    try {
      final id = DateTime.now().millisecondsSinceEpoch.toString();
      final projectDir = p.join(widget.rootDir, id);
      final dir = Directory(projectDir);
      await dir.create(recursive: true);

      // 第一段：复制源文件进项目目录
      final sourcesDir = Directory(p.join(projectDir, 'sources'));
      await sourcesDir.create(recursive: true);
      final savedPaths = <String>[];
      final totalSw = Stopwatch()..start();
      PythonService.addAppLog('导入开始：${_picked.length} 个文件 → $projectDir');

      for (final f in _picked) {
        final src = f.path;
        if (src == null) continue;
        final dest = p.join(sourcesDir.path, p.basename(src));
        // 大文件（数百 MB）复制也计入诊断：崩溃若发生在复制阶段，
        // 能从日志看到"复制开始但无完成"的直接证据。
        final srcMb = await File(src).length() / (1 << 20);
        final copySw = Stopwatch()..start();
        await File(src).copy(dest);
        PythonService.addAppLog(
          '已复制 ${p.basename(src)}（${srcMb.toStringAsFixed(0)}MB，'
          '耗时 ${copySw.elapsed.inSeconds}s，'
          'app RSS=${(ProcessInfo.currentRss / (1 << 20)).round()}MB）',
        );
        if (_sourceFileType != 'pdf') {
          savedPaths.add(dest);
        }
      }

      // 第二段：先把书记录落盘（import_pending=true）——书立即出现在
      // 书库；此后任何时刻退出应用，书都不会丢，书卡片可「继续导入」
      // 从断点续完（后端跳过已转换页）。转图完成后再回填页表。
      final project = Project(
        id: id,
        name: _nameController.text.trim(),
        projectDir: projectDir,
        imageFiles: _sourceFileType == 'pdf' ? <String>[] : savedPaths,
        sourceFileType: _sourceFileType,
        settings: ProjectSettings(
          layoutMode: _layoutMode,
          orientation: _orientation,
          horizontalDir: _horizontalDir,
          verticalDir: _verticalDir,
          engine: _engine,
          paddleModel: _paddleModel,
        ),
        bookMetadata: BookMetadata(
          title: _nameController.text.trim(),
          author: _authorController.text.trim().isEmpty
              ? null
              : _authorController.text.trim(),
          edition: _editionController.text.trim().isEmpty
              ? null
              : _editionController.text.trim(),
          volume: _volumeController.text.trim().isEmpty
              ? null
              : _volumeController.text.trim(),
          source: _sourceController.text.trim().isEmpty
              ? null
              : _sourceController.text.trim(),
        ),
        // 新书要走整本后台识别流程：入队后进度到 100% 才允许进入编辑。
        recognitionStatus: RecognitionStatus.pending,
        autoRecognize: !_manualStart,
        aiRecognitionAssist: _aiRecognitionAssist,
        importPending: _sourceFileType == 'pdf',
      );
      await ProjectStorage.save(project);

      // 第三段：PDF 逐页转图（进度回调驱动按钮文案"第 N/M 页"）。
      if (_sourceFileType == 'pdf') {
        setState(() => _creatingPhase = 'pdf');
        await BookImport.convertPdf(
          project,
          onProgress: (current, total) {
            if (mounted) {
              setState(() {
                _pdfCurrent = current;
                _pdfTotal = total;
              });
            }
          },
        );
        PythonService.addAppLog(
          'PDF 转图完成：${project.imageFiles.length} 页，'
          '累计 ${totalSw.elapsed.inSeconds}s',
        );
      }

      if (project.imageFiles.isEmpty) {
        throw Exception('未能生成可识别的图片');
      }

      // 导入流水线：跨页拆分 → 批量摆正 → 识别。拆分与摆正都会替换/
      // 扩充页面文件，识别必须基于最终页面列表，因此放在最后入队。
      if (_autoSplit) {
        if (!mounted) return;
        // 用户在拆分页确认应用返回 true（页面列表已重建）；直接返回
        // 视为跳过拆分，流水线继续。
        await Navigator.of(context).push<bool>(
          MaterialPageRoute(
            builder: (_) =>
                BookSplitPage(project: project, enqueueRecognitionAfter: false),
          ),
        );
        if (!mounted) return;
      }
      if (_autoStraighten) {
        if (!mounted) return;
        await Navigator.of(context).push<bool>(
          MaterialPageRoute(
            builder: (_) => StraightenBatchPage(project: project),
          ),
        );
        if (!mounted) return;
      }
      if (_manualStart) {
        PythonService.addAppLog(
          '任务「${project.name}」已创建（手动模式：未排队识别，'
          '共 ${project.imageFiles.length} 页，总耗时 ${totalSw.elapsed.inSeconds}s）',
        );
      } else {
        RecognitionQueue.instance.enqueue(project);
        PythonService.addAppLog(
          '任务「${project.name}」已入识别队列（共 ${project.imageFiles.length} 页，'
          '总耗时 ${totalSw.elapsed.inSeconds}s）',
        );
      }

      if (!mounted) return;
      // 回到书列表：自动模式的书显示识别进度，手动模式的书可立即进入
      // 编辑整理，或用卡片上的按钮手动开始识别。
      Navigator.pop(context);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      _creatingTimer?.cancel();
      if (mounted) setState(() => _creating = false);
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
            width: 140,
            child: Text(
              title,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
          Expanded(
            child: SegmentedButton<String>(
              segments: options
                  .map(
                    (o) => ButtonSegment<String>(
                      value: o.value,
                      label: Text(
                        o.label,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  )
                  .toList(),
              selected: {value},
              onSelectionChanged: (s) => onChanged(s.first),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('新建识别任务')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 文件选择
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Text(
                              '上传文件',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Spacer(),
                            FilledButton.tonalIcon(
                              onPressed: _creating ? null : _pickFiles,
                              icon: const Icon(Icons.upload_file),
                              label: const Text('选择文件'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (_picked.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Text(
                              '支持图片（jpg/png/webp/bmp，可多选）或 PDF 文件',
                              style: TextStyle(
                                color: Colors.grey,
                                fontSize: 12,
                              ),
                            ),
                          )
                        else ...[
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.blue.shade50,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '文件类型：${_sourceFileType == 'pdf' ? 'PDF' : '图片'}（${_picked.length} 个）',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.blue.shade700,
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          ..._picked
                              .take(8)
                              .map(
                                (f) => Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 2,
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        f.extension?.toLowerCase() == 'pdf'
                                            ? Icons.picture_as_pdf
                                            : Icons.image,
                                        size: 16,
                                        color: Colors.grey.shade600,
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          f.name,
                                          style: const TextStyle(fontSize: 12),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          if (_picked.length > 8)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Text(
                                '... 还有 ${_picked.length - 8} 个文件',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // 任务名
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '任务名称',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _nameController,
                          onChanged: _onNameChanged,
                          decoration: const InputDecoration(
                            hintText: '默认为文件名',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // 书籍元数据
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '书籍信息（可选）',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _metadataField(_authorController, '作者'),
                        _metadataField(_editionController, '版本'),
                        _metadataField(_volumeController, '卷册'),
                        _metadataField(_sourceController, '来源'),
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
                        const Text(
                          '版面识别设置',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _buildSegment(
                          title: '文字排版',
                          value: _orientation,
                          options: const [
                            (value: 'vertical', label: '竖排'),
                            (value: 'horizontal', label: '横排'),
                          ],
                          onChanged: (v) => setState(() => _orientation = v),
                        ),
                        _buildSegment(
                          title: '识别范围',
                          value: _layoutMode,
                          options: const [
                            (value: 'main_text_only', label: '只识别正文'),
                            (value: 'all_text', label: '识别全部'),
                          ],
                          onChanged: (v) => setState(() => _layoutMode = v),
                        ),
                        const Divider(height: 24),
                        const Text(
                          '句子文字排序方向',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _buildSegment(
                          title: '横排方向',
                          value: _horizontalDir,
                          options: const [
                            (value: 'ltr', label: '从左到右'),
                            (value: 'rtl', label: '从右到左'),
                          ],
                          onChanged: (v) => setState(() => _horizontalDir = v),
                        ),
                        _buildSegment(
                          title: '竖排方向',
                          value: _verticalDir,
                          options: const [
                            (value: 'ttb', label: '从上到下'),
                            (value: 'btt', label: '从下到上'),
                          ],
                          onChanged: (v) => setState(() => _verticalDir = v),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // 识别引擎（每本书可选：Kraken / PaddleOCR + 模型档位）
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '识别引擎',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          '本书识别文字所用引擎；进入书籍后也可在编辑器里随时切换'
                          '（版面/切字始终由自训模型负责）',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                        EngineSettingsSection(
                          engine: _engine,
                          paddleModel: _paddleModel,
                          onEngineChanged: (v) => setState(() => _engine = v),
                          onPaddleModelChanged: (v) => setState(() {
                            _paddleModel = v;
                            _paddleModelTouched = true;
                          }),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // 识别方式
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '识别方式',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Text(
                          '导入后依次执行：跨页拆分 → 批量摆正 → 识别'
                          '（可逐项关闭；任一步骤都可跳过或手动调整）',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: const Text(
                            '导入后先跨页拆分',
                            style: TextStyle(fontSize: 13),
                          ),
                          subtitle: const Text(
                            '左右两页合扫的跨页图先按中缝拆成两页：进入跨页'
                            '拆分页拖动中缝线并确认（无跨页书可直接返回跳过）',
                            style: TextStyle(fontSize: 12),
                          ),
                          value: _autoSplit,
                          onChanged: (v) => setState(() => _autoSplit = v),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: const Text(
                            '拆分后批量摆正（校对摆正）',
                            style: TextStyle(fontSize: 13),
                          ),
                          subtitle: const Text(
                            '逐页智能检测裁切点，透视拉平书页并裁掉页边'
                            '（可去色、锐化），逐页预览与微调。原始图片'
                            '始终保留',
                            style: TextStyle(fontSize: 12),
                          ),
                          value: _autoStraighten,
                          onChanged: (v) => setState(() => _autoStraighten = v),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: const Text(
                            '创建后手动开始识别',
                            style: TextStyle(fontSize: 13),
                          ),
                          subtitle: const Text(
                            '新书不自动排队识别：可先进入书籍查看和整理页面'
                            '（旋转、删页、跨页拆分、手画框），再手动开始整本'
                            '识别',
                            style: TextStyle(fontSize: 12),
                          ),
                          value: _manualStart,
                          onChanged: (v) => setState(() => _manualStart = v),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: const Text(
                            '全本识别时启用 AI 上下文裁决',
                            style: TextStyle(fontSize: 13),
                          ),
                          subtitle: const Text(
                            '继承 AI 辅助设置中的开关；整行置信度达到 0.80 才写回，失败自动回退 OCR',
                            style: TextStyle(fontSize: 12),
                          ),
                          value: _aiRecognitionAssist,
                          onChanged: (v) => setState(() {
                            _aiRecognitionAssistTouched = true;
                            _aiRecognitionAssist = v;
                          }),
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
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.red.shade700,
                      ),
                    ),
                  ),

                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: (_creating || _picked.isEmpty) ? null : _create,
                    icon: _creating
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Icon(
                            _manualStart ? Icons.library_add : Icons.play_arrow,
                          ),
                    label: Text(
                      _creating
                          ? (_creatingPhase == 'pdf'
                                ? '正在转换 PDF 第 $_pdfCurrent/$_pdfTotal 页…'
                                : '正在创建任务（已 ${_creatingSeconds}s）…')
                          : _manualStart
                          ? '创建任务（暂不识别）'
                          : '开始识别',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _metadataField(TextEditingController controller, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}
