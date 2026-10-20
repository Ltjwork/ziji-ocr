import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/models.dart';
import '../../services/crowd_dataset_exporter.dart';
import '../../services/python_service.dart';
import '../../services/storage.dart';
import 'plugin_bridge.dart';

/// [PluginHostServices] 的生产实现：真网络、真文件、真后端。
///
/// 安全边界：所有按 projectDir 寻址的命令都先规范路径并要求落在书库
/// 根之下——插件拿不到书库以外的任意目录读写。导出临时文件走能力
/// 路径（一次导出登记一个），multipart 上传只接受能力路径，插件不能
/// 随意读盘上传。
class ZijiPluginHostServices implements PluginHostServices {
  ZijiPluginHostServices({required this.appVersion, this.debugHttpClient});

  /// 应用版本（宿主启动时从 PackageInfo 填入；可变便于先建服务后补版本）。
  @override
  String appVersion;

  /// 测试注入的 HTTP 客户端（null = 真实网络；与 PythonService 的
  /// debugHttpClient 同模式）。
  final http.Client? debugHttpClient;

  String? _booksRoot;
  final Map<String, String> _shaByImagePath = {};
  final Set<String> _capabilities = {};

  @override
  Future<String?> booksRoot() async {
    if (_booksRoot != null) return _booksRoot;
    try {
      final docs = await getApplicationDocumentsDirectory();
      _booksRoot = p.join(docs.path, 'GujiBT');
    } catch (_) {
      _booksRoot = null;
    }
    return _booksRoot;
  }

  Future<String> _guardProjectDir(String projectDir) async {
    final root = await booksRoot();
    final canonical = p.canonicalize(projectDir);
    if (root == null ||
        projectDir.trim().isEmpty ||
        !p.isWithin(p.canonicalize(root), canonical)) {
      throw StateError('projectDir 不在书库范围内');
    }
    return canonical;
  }

  // ── 后端代理 ──

  @override
  Future<Map<String, dynamic>> backendGet(
    String path,
    Map<String, String>? query,
  ) => PythonService.pluginBackendGet(path, query);

  @override
  Future<Map<String, dynamic>> backendPost(
    String path,
    Map<String, dynamic> body,
  ) => PythonService.pluginBackendPost(path, body);

  // ── 书与标注 ──

  @override
  Future<List<Map<String, dynamic>>> listProjects() async {
    final root = await booksRoot();
    if (root == null) return [];
    final projects = await ProjectStorage.loadAll(root);
    final list = projects
        .map(
          (pr) => {
            'dir': pr.projectDir,
            'name': pr.name,
            'pageCount': pr.imageFiles.length,
            'lastPageIndex': pr.lastPageIndex,
            'importPending': pr.importPending,
          },
        )
        .toList()
      ..sort((a, b) => a['name'].toString().compareTo(b['name'].toString()));
    return list;
  }

  @override
  Future<Map<String, dynamic>?> readAnnotationCompact(
    String projectDir,
    String pageId,
  ) async {
    final dir = await _guardProjectDir(projectDir);
    final ann = await ProjectStorage.loadAnnotation(dir, pageId);
    if (ann == null) return null;
    return {
      'pageId': ann.pageId,
      'imagePath': ann.imagePath,
      'reviewed': ann.reviewed,
      'draftSaved': ann.draftSaved,
      'boxesReviewed': ann.boxesReviewed,
      'mainRegionCount': ann.mainRegions.length,
      'lines': [
        for (final line in ann.lines)
          {
            'id': line.id,
            'text': line.text,
            'orientation': line.orientation,
            'chars': [
              for (final c in line.chars)
                {
                  'id': c.id,
                  'x': c.x,
                  'y': c.y,
                  'w': c.w,
                  'h': c.h,
                  'col': c.col,
                  'order': c.order,
                  'type': c.type,
                  'status': c.status,
                  'confirmed': c.confirmed,
                  'boxConfirmed': c.boxConfirmed,
                  'text': c.text,
                },
            ],
          },
      ],
    };
  }

  @override
  Future<Map<String, int>> annotationMtimes(String projectDir) async {
    final dir = await _guardProjectDir(projectDir);
    final result = <String, int>{};
    final annDir = Directory(p.join(dir, 'annotations'));
    if (!await annDir.exists()) return result;
    await for (final entry in annDir.list()) {
      if (entry is! File) continue;
      final name = p.basename(entry.path);
      if (!name.endsWith('.json')) continue;
      final stat = await entry.stat();
      result[name.substring(0, name.length - 5)] = stat.modified.millisecondsSinceEpoch;
    }
    return result;
  }

  @override
  Future<List<String>> charUids({
    required String projectDir,
    required String pageId,
    required List<({int x, int y, int w, int h, int order})> chars,
  }) async {
    final dir = await _guardProjectDir(projectDir);
    final ann = await ProjectStorage.loadAnnotation(dir, pageId);
    final imagePath = ann?.imagePath ?? '';
    if (imagePath.isEmpty) {
      throw StateError('页 $pageId 无标注，无法计算字 uid');
    }
    final sha = await _sourceSha(imagePath);
    return [
      for (final c in chars)
        CrowdDatasetExporter.charUidFor(sha, c.x, c.y, c.w, c.h, c.order),
    ];
  }

  Future<String> _sourceSha(String imagePath) async {
    final cached = _shaByImagePath[imagePath];
    if (cached != null) return cached;
    try {
      final bytes = await File(imagePath).readAsBytes();
      final sha = sha256.convert(bytes).toString();
      _shaByImagePath[imagePath] = sha;
      return sha;
    } catch (e) {
      throw StateError('源图不可读（$imagePath）：$e');
    }
  }

  @override
  Future<({String zipPath, int taskCount})> exportCharPackage({
    required String projectDir,
    required Set<String> pageIds,
    required Set<String> onlyCharUids,
  }) async {
    final dir = await _guardProjectDir(projectDir);
    final project = await _loadProject(dir);
    final workDir = p.join(
      Directory.systemTemp.path,
      'ziji_plugin_export',
      project.id,
      DateTime.now().millisecondsSinceEpoch.toString(),
    );
    final exporter = CrowdDatasetExporter(project: project);
    final result = await exporter.export(
      outputDir: workDir,
      createZip: true,
      unconfirmedOnly: true,
      pageIds: pageIds,
      onlyCharUids: onlyCharUids,
      autoSegment: false,
    );
    final zipPath = result.zipPath;
    if (zipPath == null) {
      throw StateError(
        '任务包构建失败${result.errors.isEmpty ? '' : '：${result.errors.take(3).join('；')}'}',
      );
    }
    _capabilities.add(p.canonicalize(zipPath));
    return (zipPath: zipPath, taskCount: result.taskCount);
  }

  Future<Project> _loadProject(String projectDir) async {
    final file = File(p.join(projectDir, 'project.json'));
    Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } catch (_) {}
    if (decoded is! Map) {
      throw StateError('书目录无有效 project.json：$projectDir');
    }
    return Project.fromJsonMap(Map<String, dynamic>.from(decoded));
  }

  @override
  Future<void> releaseCapability(String path) async {
    if (path.isEmpty) return;
    final canonical = p.canonicalize(path);
    if (!_capabilities.remove(canonical)) return;
    try {
      final file = File(canonical);
      if (await file.exists()) await file.delete();
      // 导出工作目录（zip 的兄弟目录）一并清理。
      final workDir = Directory(canonical.substring(
        0,
        canonical.length - p.extension(canonical).length,
      ));
      if (await workDir.exists()) {
        await workDir.delete(recursive: true);
      }
    } catch (_) {
      // 删除失败只留临时文件，不影响插件。
    }
  }

  @override
  Future<(List<String>, List<String>)> applyCharConfirmations({
    required String projectDir,
    required String pageId,
    required List<({String id, String text})> chars,
  }) async {
    final dir = await _guardProjectDir(projectDir);
    final ann = await ProjectStorage.loadAnnotation(dir, pageId);
    if (ann == null) {
      return (<String>[], [for (final c in chars) c.id]);
    }
    final byId = <String, CharBlock?>{};
    for (final line in ann.lines) {
      for (final c in line.chars) {
        byId[c.id] ??= c;
      }
    }
    for (final b in ann.blocks) {
      byId[b.id] ??= b;
    }
    final ids = <String>{};
    final applied = <String>[];
    final unmatched = <String>[];
    for (final c in chars) {
      final block = byId[c.id];
      if (block == null) {
        unmatched.add(c.id);
        continue;
      }
      block.text = c.text;
      ids.add(block.id);
      applied.add(block.id);
    }
    if (ids.isNotEmpty) {
      ann.confirmCharsById(ids);
      if (!ann.isFullyConfirmed) ann.draftSaved = true;
      // 行文本与字块保持一致（阅读顺序以行为单位拼接）。
      for (final line in ann.lines) {
        line.text = line.chars.map((c) => c.text).join();
      }
      await ProjectStorage.saveAnnotation(dir, ann);
    }
    return (applied, unmatched);
  }

  // ── 通用 HTTP（宿主代理，免 CORS） ──

  http.Client get _client => debugHttpClient ?? http.Client();

  @override
  Future<PluginHttpResponse> httpRequest({
    required String method,
    required String url,
    Map<String, String>? headers,
    String? body,
    int? timeoutMs,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw StateError('无效的请求地址：$url');
    }
    final request = http.Request(method.toUpperCase(), uri);
    if (headers != null) request.headers.addAll(headers);
    if (body != null) request.body = body;
    final timeout = timeoutMs == null
        ? const Duration(seconds: 60)
        : Duration(milliseconds: timeoutMs);
    try {
      final streamed = await _client.send(request).timeout(timeout);
      final response = await http.Response.fromStream(streamed);
      return PluginHttpResponse(
        status: response.statusCode,
        headers: response.headers.map(
          (k, v) => MapEntry(k.toLowerCase(), v),
        ),
        body: utf8.decode(response.bodyBytes, allowMalformed: true),
      );
    } on TimeoutException {
      throw StateError('请求超时：$url');
    }
  }

  @override
  Future<PluginHttpResponse> httpUploadFile({
    required String url,
    required String filePath,
    Map<String, String>? fields,
    Map<String, String>? headers,
    int? timeoutMs,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw StateError('无效的上传地址：$url');
    }
    final canonical = p.canonicalize(filePath);
    if (!_capabilities.contains(canonical)) {
      throw StateError('只能上传宿主导出的任务包文件（能力路径）');
    }
    final request = http.MultipartRequest('POST', uri);
    if (fields != null) request.fields.addAll(fields);
    if (headers != null) request.headers.addAll(headers);
    request.files.add(await http.MultipartFile.fromPath('file', canonical));
    final timeout = timeoutMs == null
        ? const Duration(minutes: 10)
        : Duration(milliseconds: timeoutMs);
    try {
      final streamed = await _client.send(request).timeout(timeout);
      final response = await http.Response.fromStream(streamed);
      return PluginHttpResponse(
        status: response.statusCode,
        headers: response.headers.map(
          (k, v) => MapEntry(k.toLowerCase(), v),
        ),
        body: utf8.decode(response.bodyBytes, allowMalformed: true),
      );
    } on TimeoutException {
      throw StateError('上传超时：$url');
    }
  }

  @override
  void addLog(String text, {bool isError = false}) =>
      PythonService.addAppLog(text, isError: isError);
}
