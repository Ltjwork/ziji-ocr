import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:gujichazi/services/update_service.dart';

void main() {
  group('AppVersion', () {
    test('parses tags and compares semantic version components', () {
      final old = AppVersion.tryParse('v1.2.9+18')!;
      final next = AppVersion.tryParse('1.3.0')!;
      expect(old.toString(), '1.2.9+18');
      expect(old.compareTo(next), lessThan(0));
      expect(AppVersion.tryParse('1.2.9+2')!.compareTo(old), 0);
      expect(AppVersion.tryParse('1.2'), isNull);
      expect(AppVersion.tryParse('v1.2.3-beta'), isNull);
    });
  });

  group('UpdateService Release parsing', () {
    const assetName = 'ziji_setup_1.2.3.exe';
    Map<String, dynamic> releaseJson({
      String tag = 'v1.2.3',
      bool draft = false,
      bool prerelease = false,
      String? digest,
      List<Map<String, dynamic>>? assets,
    }) => {
      'tag_name': tag,
      'name': 'ZiJi $tag',
      'body': 'Bug fixes',
      'html_url': 'https://github.com/Ltjwork/ziji-ocr/releases/tag/$tag',
      'draft': draft,
      'prerelease': prerelease,
      'assets':
          assets ??
          [
            {
              'name': assetName,
              'browser_download_url':
                  'https://github.com/Ltjwork/ziji-ocr/releases/download/v1.2.3/$assetName',
              'size': 100,
              if (digest != null) 'digest': digest,
            },
          ],
    };

    test('selects exact Windows asset and GitHub digest', () async {
      final client = MockClient(
        (request) async => http.Response(
          jsonEncode(releaseJson(digest: 'sha256:${'a' * 64}')),
          200,
        ),
      );
      final service = UpdateService(client: client, currentVersion: '1.0.0');
      final release = await service.fetchLatestRelease();
      expect(release.asset.name, assetName);
      expect(release.asset.sha256, 'a' * 64);
      expect(release.version.toString(), '1.2.3');
      service.dispose();
    });

    test('rejects prerelease, malformed tag, and absent installer', () async {
      for (final json in [
        releaseJson(prerelease: true),
        releaseJson(tag: 'v1.2.3-beta'),
        releaseJson(assets: const []),
      ]) {
        final service = UpdateService(
          client: MockClient((_) async => http.Response(jsonEncode(json), 200)),
          currentVersion: '1.0.0',
        );
        await expectLater(service.fetchLatestRelease(), throwsA(anything));
        service.dispose();
      }
    });

    test('compares current version to latest Release', () async {
      final service = UpdateService(
        client: MockClient(
          (_) async => http.Response(jsonEncode(releaseJson()), 200),
        ),
        currentVersion: '1.2.2',
      );
      await service.checkForUpdates();
      expect(service.status, UpdateStatus.available);
      expect(service.updateAvailable, isTrue);
      service.dispose();
    });

    test('rejects malformed provided checksum', () async {
      final service = UpdateService(
        client: MockClient(
          (_) async =>
              http.Response(jsonEncode(releaseJson(digest: 'sha256:bad')), 200),
        ),
        currentVersion: '1.0.0',
      );
      await expectLater(service.fetchLatestRelease(), throwsFormatException);
      service.dispose();
    });
  });

  group('UpdateService download', () {
    test('downloads to final file and verifies digest', () async {
      final bytes = utf8.encode('installer payload');
      final expected = 'sha256:${sha256.convert(bytes)}';
      final temp = Directory.systemTemp.createTempSync('update_test');
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/releases/latest')) {
          return http.Response(
            jsonEncode({
              'tag_name': 'v1.2.3',
              'name': 'ZiJi 1.2.3',
              'body': '',
              'html_url':
                  'https://github.com/Ltjwork/ziji-ocr/releases/tag/v1.2.3',
              'draft': false,
              'prerelease': false,
              'assets': [
                {
                  'name': 'ziji_setup_1.2.3.exe',
                  'browser_download_url':
                      'https://github.com/Ltjwork/ziji-ocr/releases/download/v1.2.3/ziji_setup_1.2.3.exe',
                  'size': bytes.length,
                  'digest': expected,
                },
              ],
            }),
            200,
          );
        }
        return http.Response.bytes(bytes, 200);
      });
      final service = UpdateService(
        client: client,
        currentVersion: '1.0.0',
        temporaryDirectory: () async => temp,
      );
      await service.checkForUpdates();
      await service.downloadUpdate();
      expect(service.status, UpdateStatus.downloaded);
      expect(service.downloadedBytes, bytes.length);
      expect(File(service.installerPath!).readAsBytesSync(), bytes);
      expect(service.checksumAvailable, isTrue);
      service.dispose();
      temp.deleteSync(recursive: true);
    });

    test('removes partial file when checksum does not match', () async {
      final bytes = utf8.encode('bad installer');
      final temp = Directory.systemTemp.createTempSync('update_test');
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/releases/latest')) {
          return http.Response(
            jsonEncode({
              'tag_name': 'v1.2.3',
              'name': 'ZiJi 1.2.3',
              'body': '',
              'html_url':
                  'https://github.com/Ltjwork/ziji-ocr/releases/tag/v1.2.3',
              'draft': false,
              'prerelease': false,
              'assets': [
                {
                  'name': 'ziji_setup_1.2.3.exe',
                  'browser_download_url':
                      'https://github.com/Ltjwork/ziji-ocr/releases/download/v1.2.3/ziji_setup_1.2.3.exe',
                  'size': bytes.length,
                  'digest': 'sha256:${'0' * 64}',
                },
              ],
            }),
            200,
          );
        }
        return http.Response.bytes(bytes, 200);
      });
      final service = UpdateService(
        client: client,
        currentVersion: '1.0.0',
        temporaryDirectory: () async => temp,
      );
      await service.checkForUpdates();
      await service.downloadUpdate();
      expect(service.status, UpdateStatus.error);
      expect(temp.listSync(), isEmpty);
      service.dispose();
      temp.deleteSync(recursive: true);
    });
  });
}
