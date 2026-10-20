import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/pages/about_update_page.dart';
import 'package:gujichazi/pages/changelog_page.dart';
import 'package:gujichazi/services/changelog_service.dart';
import 'package:gujichazi/services/update_service.dart';
import 'package:gujichazi/widgets/release_markdown.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, Object?> entry(int id, {String? notes = 'GitHub 发布说明'}) => {
  'id': id,
  'tag_name': 'v1.0.$id',
  'name': '版本 $id',
  'body': notes,
};

http.Response jsonResponse(
  Object body, {
  Map<String, String> headers = const {},
}) => http.Response.bytes(utf8.encode(jsonEncode(body)), 200, headers: headers);

void main() {
  testWidgets('loads online notes and copies original markdown', (
    tester,
  ) async {
    final response = Completer<http.Response>();
    final client = MockClient((_) => response.future);
    addTearDown(client.close);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = call.arguments['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ChangelogPage(service: ChangelogService(client: client)),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    response.complete(jsonResponse([entry(1, notes: '**来自 GitHub**\n\n- 改进')]));
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.text('来自 GitHub'), findsOneWidget);
    expect(find.text('改进'), findsOneWidget);
    expect(find.textContaining('**来自 GitHub**'), findsNothing);
    expect(find.textContaining('CHANGELOG.md'), findsNothing);
    expect(find.text('本版本'), findsNothing);
    await tester.tap(find.byTooltip('复制发布说明'));
    await tester.pump();
    expect(copied, '## v1.0.1\n\n**来自 GitHub**\n\n- 改进');
  });

  testWidgets('request error retries and blank notes show explicit fallback', (
    tester,
  ) async {
    var calls = 0;
    final client = MockClient(
      (_) async => ++calls == 1
          ? http.Response('offline', 503)
          : jsonResponse([entry(1, notes: null)]),
    );
    addTearDown(client.close);
    await tester.pumpWidget(
      MaterialApp(
        home: ChangelogPage(service: ChangelogService(client: client)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('HTTP 503'), findsOneWidget);
    expect(find.text('GitHub 暂无正式版本发布记录'), findsNothing);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('此版本未填写发布说明'), findsOneWidget);
  });

  testWidgets('empty successful response shows no releases', (tester) async {
    final client = MockClient((_) async => jsonResponse([]));
    addTearDown(client.close);
    await tester.pumpWidget(
      MaterialApp(
        home: ChangelogPage(service: ChangelogService(client: client)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('GitHub 暂无正式版本发布记录'), findsOneWidget);
  });

  testWidgets(
    'pagination failure preserves entries, retries same page and deduplicates',
    (tester) async {
      final pages = <String?>[];
      final client = MockClient((request) async {
        pages.add(request.url.queryParameters['page']);
        if (pages.length == 1) {
          return jsonResponse(
            [entry(1)],
            headers: {
              'link':
                  '<https://api.github.com/repos/Ltjwork/ziji-ocr/releases?page=2>; rel="next"',
            },
          );
        }
        if (pages.length == 2) return http.Response('failed', 500);
        return jsonResponse([entry(1), entry(2)]);
      });
      addTearDown(client.close);
      await tester.pumpWidget(
        MaterialApp(
          home: ChangelogPage(service: ChangelogService(client: client)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(find.text('版本 1'), findsOneWidget);
      expect(find.textContaining('HTTP 500'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(pages, ['1', '2', '2']);
      expect(find.text('版本 1'), findsOneWidget);
      expect(find.text('版本 2'), findsOneWidget);
    },
  );

  testWidgets(
    'latest release notes remain visible when installed version is current',
    (tester) async {
      final updates = UpdateService(currentVersion: '1.0.1');
      updates.status = UpdateStatus.current;
      updates.release = GitHubRelease(
        version: const AppVersion(1, 0, 1),
        name: '当前正式版',
        notes: '**当前版**\n\nGitHub 说明',
        url: Uri.parse(
          'https://github.com/Ltjwork/ziji-ocr/releases/tag/v1.0.1',
        ),
        asset: UpdateAsset(
          name: 'ziji_setup_1.0.1.exe',
          downloadUrl: Uri.parse(
            'https://github.com/Ltjwork/ziji-ocr/releases/download/v1.0.1/ziji_setup_1.0.1.exe',
          ),
          size: 10,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(home: AboutUpdatePage(updates: updates)),
      );
      expect(find.text('已是最新版本'), findsOneWidget);
      expect(find.byType(ReleaseMarkdown), findsOneWidget);
      expect(find.byType(MarkdownBody), findsOneWidget);
      expect(find.text('当前版'), findsOneWidget);
      expect(find.text('GitHub 说明'), findsOneWidget);
      expect(find.textContaining('**当前版**'), findsNothing);
      expect(find.text('GitHub 更新日志'), findsOneWidget);
      expect(find.textContaining('下载 Windows'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      updates.dispose();
    },
  );
}
