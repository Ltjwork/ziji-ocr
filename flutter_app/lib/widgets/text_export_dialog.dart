import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/book_text_export.dart';

/// 导出全文对话框：整本书按页序合并为一个文件。
///
/// 选项：格式（Markdown / 纯文本 / Word）三选一；「段与段之间空一行」
/// 开关（默认开）。非正文行（页眉/页脚/页码/边注）不导出，未归属段落
/// 的行合并为一段——规则见 [BookTextExporter]。
class TextExportDialog extends StatefulWidget {
  final Project project;
  const TextExportDialog({super.key, required this.project});

  static Future<void> show(BuildContext context, Project project) =>
      showDialog(
        context: context,
        builder: (_) => TextExportDialog(project: project),
      );

  @override
  State<TextExportDialog> createState() => _TextExportDialogState();
}

class _TextExportDialogState extends State<TextExportDialog> {
  TextExportFormat _format = TextExportFormat.md;
  bool _blankLine = true; // 段与段之间空一行，默认开
  bool _busy = false;
  String? _error;

  Future<void> _export() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await BookTextExporter(widget.project).build();
      if (!mounted) return;
      if (result.isEmpty) {
        final messenger = ScaffoldMessenger.of(context);
        Navigator.of(context).pop();
        messenger.showSnackBar(
          const SnackBar(content: Text('没有可导出的正文文本（所有页均无标注或无正文行）')),
        );
        return;
      }
      final fileName =
          '${BookTextExporter.safeFileName(widget.project.name)}.${_format.ext}';
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '导出全文',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: [_format.ext],
      );
      if (path == null) {
        // 用户取消保存：留在对话框，可改选项再导。
        setState(() => _busy = false);
        return;
      }
      if (_format == TextExportFormat.docx) {
        final bytes = BookTextExporter.toDocx(
          result.blocks,
          blankLineBetween: _blankLine,
        );
        await File(path).writeAsBytes(bytes, flush: true);
      } else {
        final content = BookTextExporter.toPlainText(
          result.blocks,
          blankLineBetween: _blankLine,
          format: _format,
        );
        await File(path).writeAsString(content, flush: true);
      }
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      final savedName = path.split(Platform.pathSeparator).last;
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '已导出 ${result.exportedPages} 页 · ${result.blocks.length} 段'
            '${result.skippedPages > 0 ? '（${result.skippedPages} 页无正文已跳过）' : ''}'
            ' → $savedName',
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '导出失败：$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('导出全文'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RadioGroup<TextExportFormat>(
              groupValue: _format,
              onChanged: (v) {
                if (_busy || v == null) return;
                setState(() => _format = v);
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final f in TextExportFormat.values)
                    RadioListTile<TextExportFormat>(
                      value: f,
                      title: Text('${f.label}（.${f.ext}）'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                ],
              ),
            ),
            SwitchListTile(
              title: const Text('段与段之间空一行'),
              value: _blankLine,
              onChanged:
                  _busy ? null : (v) => setState(() => _blankLine = v),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 4),
            Text(
              '整本书按页序合并为一个文件：同一自然段内的行合并成一段，'
              '未归属段落的行合并为一段；页眉、页脚、页码、边注不导出。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _export,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('导出'),
        ),
      ],
    );
  }
}
