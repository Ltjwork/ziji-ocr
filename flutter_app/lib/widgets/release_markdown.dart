import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

/// Renders GitHub Release notes while keeping the source Markdown unchanged.
class ReleaseMarkdown extends StatelessWidget {
  const ReleaseMarkdown({
    super.key,
    required this.data,
    this.emptyText = '此版本未填写发布说明',
  });

  final String data;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    if (data.trim().isEmpty) return Text(emptyText);

    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final styleSheet = MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: textTheme.bodyMedium,
      h1: textTheme.headlineSmall,
      h2: textTheme.titleLarge,
      h3: textTheme.titleMedium,
      blockSpacing: 8,
    );
    return MarkdownBody(
      data: data,
      selectable: true,
      shrinkWrap: true,
      styleSheet: styleSheet,
    );
  }
}
