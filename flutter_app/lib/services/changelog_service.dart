import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// GitHub Release 发布说明；正文保留原始 Markdown。
class ChangelogEntry {
  const ChangelogEntry({
    required this.version,
    required this.markdown,
    this.id,
    this.name = '',
    this.url,
    this.publishedAt,
  });

  final String version;
  final String markdown;
  final int? id;
  final String name;
  final Uri? url;
  final DateTime? publishedAt;

  String get title => name.isEmpty ? version : name;
}

class ChangelogPageResult {
  const ChangelogPageResult({required this.entries, this.nextPage});

  final List<ChangelogEntry> entries;
  final int? nextPage;
}

/// 发布记录独立于安装包查询，不要求版本标签或安装器资产。
class ChangelogService {
  ChangelogService({
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  static final Uri releasesUri = Uri.parse(
    'https://api.github.com/repos/Ltjwork/ziji-ocr/releases',
  );

  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;

  Future<ChangelogPageResult> load({int page = 1}) async {
    if (page < 1) throw ArgumentError.value(page, 'page');
    final response = await _client
        .get(
          releasesUri.replace(
            queryParameters: {'per_page': '20', 'page': '$page'},
          ),
          headers: const {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'ZiJi-OCR-Updater',
            'X-GitHub-Api-Version': '2022-11-28',
          },
        )
        .timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      if (response.statusCode == 403 || response.statusCode == 429) {
        throw const HttpException('GitHub 请求受限，请稍后重试');
      }
      throw HttpException('读取 GitHub 更新日志失败：HTTP ${response.statusCode}');
    }
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    if (data is! List) throw const FormatException('GitHub 发布记录格式无效');
    final entries = <ChangelogEntry>[];
    for (final item in data) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('GitHub 发布记录格式无效');
      }
      if (item['draft'] == true || item['prerelease'] == true) continue;
      final tag = item['tag_name'];
      final id = item['id'];
      if (tag is! String || tag.trim().isEmpty || id is! int) {
        throw const FormatException('GitHub 发布记录缺少版本信息');
      }
      entries.add(
        ChangelogEntry(
          id: id,
          version: tag,
          name: (item['name'] as String?)?.trim() ?? '',
          markdown: item['body'] as String? ?? '',
          url: Uri.tryParse(item['html_url'] as String? ?? ''),
          publishedAt: DateTime.tryParse(item['published_at'] as String? ?? ''),
        ),
      );
    }
    // 只向固定 GitHub API 请求下一页，不跟随响应里的任意地址。
    final hasNext = RegExp(
      r'rel="next"',
    ).hasMatch(response.headers['link'] ?? '');
    return ChangelogPageResult(
      entries: entries,
      nextPage: hasNext ? page + 1 : null,
    );
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }

  /// 保留发布文档的纯文本解析工具；应用日志页不读取本地文件。
  static List<ChangelogEntry> parse(String content) {
    final entries = <ChangelogEntry>[];
    final lines = content.replaceAll('\r\n', '\n').split('\n');
    String? version;
    final body = <String>[];
    for (final line in lines) {
      if (line.startsWith('## ')) {
        if (version != null) {
          entries.add(ChangelogEntry(version: version, markdown: _trim(body)));
        }
        version = line.substring(3).trim();
        body.clear();
      } else if (version != null) {
        body.add(line);
      }
    }
    if (version != null) {
      entries.add(ChangelogEntry(version: version, markdown: _trim(body)));
    }
    return entries;
  }

  static String _trim(List<String> body) {
    var text = body.join('\n');
    while (text.startsWith('\n')) {
      text = text.substring(1);
    }
    while (text.endsWith('\n')) {
      text = text.substring(0, text.length - 1);
    }
    return text;
  }
}
