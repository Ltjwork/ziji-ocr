import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/services/changelog_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, Object?> release(
  int id, {
  bool draft = false,
  bool prerelease = false,
}) => {
  'id': id,
  'tag_name': 'historical-$id',
  'name': '发布 $id',
  'body': '- 修复识别\n\n**保留格式**',
  'published_at': '2026-10-20T10:00:00Z',
  'html_url': 'https://github.com/Ltjwork/ziji-ocr/releases/tag/historical-$id',
  'draft': draft,
  'prerelease': prerelease,
};

void main() {
  test(
    'loads Chinese notes without installer or semantic version requirements',
    () async {
      final client = MockClient((request) async {
        expect(
          request.url,
          ChangelogService.releasesUri.replace(
            queryParameters: {'per_page': '20', 'page': '1'},
          ),
        );
        expect(request.headers['Accept'], 'application/vnd.github+json');
        return http.Response.bytes(utf8.encode(jsonEncode([release(10)])), 200);
      });
      final service = ChangelogService(client: client);
      addTearDown(client.close);
      final result = await service.load();
      final entry = result.entries.single;
      expect(entry.id, 10);
      expect(entry.title, '发布 10');
      expect(entry.version, 'historical-10');
      expect(entry.markdown, '- 修复识别\n\n**保留格式**');
      expect(entry.publishedAt, DateTime.utc(2026, 10, 20, 10));
      expect(entry.url?.host, 'github.com');
      expect(result.nextPage, isNull);
      service.dispose();
    },
  );

  test('follows pagination even when a page is filtered empty', () async {
    final pages = <String?>[];
    final client = MockClient((request) async {
      pages.add(request.url.queryParameters['page']);
      if (pages.length == 1) {
        return http.Response.bytes(
          utf8.encode(
            jsonEncode([release(1, draft: true), release(2, prerelease: true)]),
          ),
          200,
          headers: {
            'link':
                '<https://api.github.com/repos/Ltjwork/ziji-ocr/releases?page=2>; rel="next"',
          },
        );
      }
      return http.Response.bytes(
        utf8.encode(jsonEncode([release(3)..['body'] = null])),
        200,
      );
    });
    addTearDown(client.close);
    final service = ChangelogService(client: client);
    final first = await service.load();
    expect(first.entries, isEmpty);
    expect(first.nextPage, 2);
    final second = await service.load(page: first.nextPage!);
    expect(second.entries.single.markdown, isEmpty);
    expect(second.nextPage, isNull);
    expect(pages, ['1', '2']);
  });

  test('empty response means no releases', () async {
    final client = MockClient((_) async => http.Response('[]', 200));
    addTearDown(client.close);
    expect((await ChangelogService(client: client).load()).entries, isEmpty);
  });

  test(
    'HTTP and malformed responses fail instead of returning empty history',
    () async {
      for (final response in [
        http.Response('not found', 404),
        http.Response('rate limited', 403),
        http.Response('busy', 429),
        http.Response('server failure', 500),
        http.Response('not json', 200),
        http.Response('{}', 200),
        http.Response('[{}]', 200),
      ]) {
        final client = MockClient((_) async => response);
        addTearDown(client.close);
        await expectLater(
          ChangelogService(client: client).load(),
          throwsA(anything),
        );
      }
    },
  );

  test('times out an unresponsive GitHub request', () async {
    final response = Completer<http.Response>();
    final client = MockClient((_) => response.future);
    addTearDown(client.close);
    await expectLater(
      ChangelogService(
        client: client,
        timeout: const Duration(milliseconds: 1),
      ).load(),
      throwsA(isA<TimeoutException>()),
    );
    response.complete(http.Response('[]', 200));
  });
}
