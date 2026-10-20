import 'dart:async';
import 'dart:convert';

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch, {this.build = ''});

  final int major;
  final int minor;
  final int patch;
  final String build;

  static AppVersion? tryParse(String value) {
    final match = RegExp(
      r'^v?(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?$',
    ).firstMatch(value.trim());
    if (match == null) return null;
    return AppVersion(
      int.parse(match[1]!),
      int.parse(match[2]!),
      int.parse(match[3]!),
      build: match[4] ?? '',
    );
  }

  @override
  int compareTo(AppVersion other) {
    final majorResult = major.compareTo(other.major);
    if (majorResult != 0) return majorResult;
    final minorResult = minor.compareTo(other.minor);
    if (minorResult != 0) return minorResult;
    return patch.compareTo(other.patch);
  }

  @override
  String toString() => '$major.$minor.$patch${build.isEmpty ? '' : '+$build'}';
}

class UpdateAsset {
  const UpdateAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
    this.sha256,
  });

  final String name;
  final Uri downloadUrl;
  final int size;
  final String? sha256;
}

class GitHubRelease {
  const GitHubRelease({
    required this.version,
    required this.name,
    required this.notes,
    required this.url,
    required this.asset,
  });

  final AppVersion version;
  final String name;
  final String notes;
  final Uri url;
  final UpdateAsset asset;
}

enum UpdateStatus {
  idle,
  checking,
  current,
  available,
  downloading,
  downloaded,
  error,
}

class _DigestSink implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest data) => digest = data;

  @override
  void close() {}
}

class UpdateService extends ChangeNotifier {
  UpdateService({
    http.Client? client,
    String? currentVersion,
    Future<Directory> Function()? temporaryDirectory,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _currentVersion = currentVersion,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  static final UpdateService instance = UpdateService();
  static final Uri latestReleaseUri = Uri.parse(
    'https://api.github.com/repos/Ltjwork/ziji-ocr/releases/latest',
  );

  final http.Client _client;
  final bool _ownsClient;
  final Future<Directory> Function() _temporaryDirectory;
  String? _currentVersion;
  UpdateStatus status = UpdateStatus.idle;
  GitHubRelease? release;
  String? error;
  String? installerPath;
  int downloadedBytes = 0;
  int totalBytes = 0;
  bool checksumAvailable = false;
  Completer<void>? _downloadAbort;

  String? get currentVersion => _currentVersion;
  bool get updateAvailable =>
      release != null &&
      (AppVersion.tryParse(
                _currentVersion ?? '',
              )?.compareTo(release!.version) ??
              0) <
          0;
  double? get downloadProgress =>
      totalBytes > 0 ? downloadedBytes / totalBytes : null;

  Future<void> initializeAndCheck() async {
    try {
      final info = await PackageInfo.fromPlatform();
      _currentVersion ??= info.version;
      await checkForUpdates();
    } catch (e) {
      _setError('读取当前版本失败：$e');
    }
  }

  Future<GitHubRelease> fetchLatestRelease() async {
    final response = await _client
        .get(
          latestReleaseUri,
          headers: const {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'ZiJi-OCR-Updater',
            'X-GitHub-Api-Version': '2022-11-28',
          },
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('GitHub API 返回 HTTP ${response.statusCode}');
    }
    final data = jsonDecode(response.body);
    if (data is! Map<String, dynamic> ||
        data['draft'] == true ||
        data['prerelease'] == true) {
      throw const FormatException('GitHub 未返回正式版本 Release');
    }

    final tag = data['tag_name']?.toString() ?? '';
    final version = AppVersion.tryParse(tag);
    if (version == null) throw FormatException('Release 标签格式不支持：$tag');
    final assets = data['assets'];
    if (assets is! List) throw const FormatException('Release 缺少安装包资产');
    final expectedName =
        'ziji_setup_${version.major}.${version.minor}.${version.patch}.exe';
    Map<String, dynamic>? installer;
    Map<String, dynamic>? checksum;
    for (final item in assets) {
      if (item is! Map) continue;
      final asset = Map<String, dynamic>.from(item);
      final name = asset['name']?.toString();
      if (name == expectedName) installer = asset;
      if (name == '$expectedName.sha256') checksum = asset;
    }
    if (installer == null) {
      throw FormatException('Release 中找不到 Windows 安装包 $expectedName');
    }
    final downloadUrl = Uri.tryParse(
      installer['browser_download_url']?.toString() ?? '',
    );
    if (downloadUrl == null ||
        downloadUrl.scheme != 'https' ||
        downloadUrl.host != 'github.com') {
      throw const FormatException('Release 安装包下载地址无效');
    }
    var expectedHash = _parseDigest(installer['digest']?.toString());
    if (expectedHash == null && checksum != null) {
      expectedHash = await _fetchChecksum(checksum);
    }
    return GitHubRelease(
      version: version,
      name: data['name']?.toString().trim().isNotEmpty == true
          ? data['name'].toString()
          : tag,
      notes: data['body']?.toString() ?? '',
      url: Uri.parse(data['html_url']?.toString() ?? ''),
      asset: UpdateAsset(
        name: expectedName,
        downloadUrl: downloadUrl,
        size: (installer['size'] as num?)?.toInt() ?? 0,
        sha256: expectedHash,
      ),
    );
  }

  Future<String?> _fetchChecksum(Map<String, dynamic> asset) async {
    final uri = Uri.tryParse(asset['browser_download_url']?.toString() ?? '');
    if (uri == null || uri.scheme != 'https' || uri.host != 'github.com') {
      throw const FormatException('Release 校验文件地址无效');
    }
    final response = await _client
        .get(uri)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('读取 SHA-256 文件失败：HTTP ${response.statusCode}');
    }
    final match = RegExp(r'\b([a-fA-F0-9]{64})\b').firstMatch(response.body);
    if (match == null) throw const FormatException('Release SHA-256 文件格式无效');
    return match[1]!.toLowerCase();
  }

  static String? _parseDigest(String? digest) {
    if (digest == null || digest.isEmpty) return null;
    final match = RegExp(r'^sha256:([a-fA-F0-9]{64})$').firstMatch(digest);
    if (match == null) {
      throw const FormatException('GitHub Release digest 格式无效');
    }
    return match[1]!.toLowerCase();
  }

  Future<void> checkForUpdates() async {
    status = UpdateStatus.checking;
    error = null;
    notifyListeners();
    try {
      final latest = await fetchLatestRelease();
      release = latest;
      final current = AppVersion.tryParse(_currentVersion ?? '');
      if (current == null) throw FormatException('当前应用版本格式无效：$_currentVersion');
      status = current.compareTo(latest.version) < 0
          ? UpdateStatus.available
          : UpdateStatus.current;
    } catch (e) {
      error = e.toString().replaceFirst('Exception: ', '');
      status = UpdateStatus.error;
    }
    notifyListeners();
  }

  Future<void> downloadUpdate() async {
    final target = release;
    if (target == null || status == UpdateStatus.downloading) return;
    status = UpdateStatus.downloading;
    error = null;
    installerPath = null;
    downloadedBytes = 0;
    totalBytes = target.asset.size;
    checksumAvailable = target.asset.sha256 != null;
    final abort = Completer<void>();
    _downloadAbort = abort;
    File? partial;
    IOSink? output;
    http.StreamedResponse? response;
    try {
      final request = http.AbortableRequest(
        'GET',
        target.asset.downloadUrl,
        abortTrigger: abort.future,
      )..headers.addAll(const {'User-Agent': 'ZiJi-OCR-Updater'});
      response = await _client
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('下载失败：HTTP ${response.statusCode}');
      }
      if (response.contentLength != null && response.contentLength! > 0) {
        totalBytes = response.contentLength!;
      }
      final directory = await _temporaryDirectory();
      partial = File(p.join(directory.path, '${target.asset.name}.part'));
      output = partial.openWrite();
      final digestSink = _DigestSink();
      final digestInput = sha256.startChunkedConversion(digestSink);
      final sink = output;
      await for (final chunk in response.stream) {
        sink.add(chunk);
        digestInput.add(chunk);
        downloadedBytes += chunk.length;
        notifyListeners();
      }
      await sink.flush();
      await sink.close();
      output = null;
      digestInput.close();
      final expectedHash = target.asset.sha256;
      if (expectedHash != null &&
          digestSink.digest?.toString() != expectedHash) {
        throw const FormatException('安装包 SHA-256 校验失败，已拒绝运行');
      }
      final finalFile = File(p.join(directory.path, target.asset.name));
      if (await finalFile.exists()) await finalFile.delete();
      await partial.rename(finalFile.path);
      installerPath = finalFile.path;
      status = UpdateStatus.downloaded;
    } catch (e) {
      await output?.close();
      if (partial != null && await partial.exists()) await partial.delete();
      error = e.toString().replaceFirst('Exception: ', '');
      status = UpdateStatus.error;
    } finally {
      _downloadAbort = null;
      notifyListeners();
    }
  }

  void cancelDownload() {
    final abort = _downloadAbort;
    if (abort != null && !abort.isCompleted) abort.complete();
  }

  Future<void> launchInstaller() async {
    final path = installerPath;
    if (path == null || !Platform.isWindows) {
      throw StateError('当前平台不支持运行 Windows 安装包');
    }
    final result = await Process.start(
      path,
      const [],
      mode: ProcessStartMode.detached,
    );
    if (result.pid <= 0) throw StateError('无法启动安装程序');
  }

  void _setError(String message) {
    error = message;
    status = UpdateStatus.error;
    notifyListeners();
  }

  @override
  void dispose() {
    _downloadAbort == null ? null : cancelDownload();
    if (_ownsClient) _client.close();
    super.dispose();
  }
}
