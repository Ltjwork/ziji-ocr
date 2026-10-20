import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/pages/about_update_page.dart';
import 'package:gujichazi/services/update_service.dart';
import 'package:gujichazi/widgets/release_markdown.dart';
import 'package:gujichazi/widgets/startup_update_prompt.dart';

GitHubRelease _release({String notes = '修复识别问题', int major = 2}) =>
    GitHubRelease(
      version: AppVersion(major, 0, 0),
      name: '字迹 $major.0.0',
      notes: notes,
      url: Uri.parse(
        'https://github.com/Ltjwork/ziji-ocr/releases/tag/v$major.0.0',
      ),
      asset: UpdateAsset(
        name: 'ziji_setup_$major.0.0.exe',
        downloadUrl: Uri.parse('https://github.com/Ltjwork/ziji-ocr/setup.exe'),
        size: 1024,
      ),
    );

class _TestUpdates extends UpdateService {
  _TestUpdates() : super(currentVersion: '1.0.0');

  Future<GitHubRelease>? nextRelease;
  int downloads = 0;
  int initializations = 0;

  bool get observed => hasListeners;

  void emit(
    UpdateStatus value, {
    GitHubRelease? latest,
    bool withoutRelease = false,
  }) {
    status = value;
    release = withoutRelease ? null : latest ?? _release();
    notifyListeners();
  }

  @override
  Future<GitHubRelease> fetchLatestRelease() async => nextRelease ?? _release();

  @override
  Future<void> initializeAndCheck() async {
    initializations++;
  }

  @override
  Future<void> downloadUpdate() async {
    downloads++;
  }
}

class _Routes extends NavigatorObserver {
  int dialogs = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is DialogRoute) dialogs++;
    super.didPush(route, previousRoute);
  }
}

Widget _app({
  required UpdateService updates,
  required GlobalKey<NavigatorState> navigatorKey,
  required StartupUpdatePromptSession session,
  _Routes? observer,
  bool prompt = true,
  String home = '正在定位后端',
}) => MaterialApp(
  navigatorKey: navigatorKey,
  navigatorObservers: [if (observer != null) observer],
  builder: (context, child) => prompt
      ? StartupUpdatePrompt(
          updates: updates,
          navigatorKey: navigatorKey,
          session: session,
          child: child!,
        )
      : child!,
  home: Scaffold(body: Center(child: Text(home))),
);

void main() {
  late _TestUpdates updates;
  late GlobalKey<NavigatorState> navigatorKey;
  late StartupUpdatePromptSession session;
  late _Routes routes;

  setUp(() {
    updates = _TestUpdates();
    navigatorKey = GlobalKey<NavigatorState>();
    session = StartupUpdatePromptSession();
    routes = _Routes();
  });

  tearDown(() => updates.dispose());

  Future<void> mount(WidgetTester tester, {bool prompt = true}) async {
    await tester.pumpWidget(
      _app(
        updates: updates,
        navigatorKey: navigatorKey,
        session: session,
        observer: routes,
        prompt: prompt,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows a check completed before mount, independent of backend', (
    tester,
  ) async {
    await updates.checkForUpdates();
    await mount(tester);

    expect(find.text('发现新版本 2.0.0'), findsOneWidget);
    expect(find.byType(ReleaseMarkdown), findsOneWidget);
    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.text('修复识别问题'), findsOneWidget);
    expect(find.text('正在定位后端'), findsOneWidget);
    expect(find.text('稍后'), findsOneWidget);
    expect(find.text('前往更新'), findsOneWidget);
    expect(updates.initializations, 0);
    expect(updates.downloads, 0);
  });

  testWidgets('later completion requests a frame and shows the prompt', (
    tester,
  ) async {
    final completed = Completer<GitHubRelease>();
    updates.nextRelease = completed.future;
    final check = updates.checkForUpdates();
    await mount(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.binding.hasScheduledFrame, isFalse);

    completed.complete(_release());
    await check;
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(routes.dialogs, 1);
  });

  testWidgets('only available status with a strictly newer release prompts', (
    tester,
  ) async {
    await mount(tester);
    for (final status in UpdateStatus.values) {
      if (status == UpdateStatus.available) continue;
      updates.emit(status);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing, reason: status.name);
    }
    for (final major in [0, 1]) {
      updates.emit(UpdateStatus.available, latest: _release(major: major));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    }
    updates.emit(UpdateStatus.available, withoutRelease: true);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    updates.emit(UpdateStatus.available);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets(
    'coalesces callbacks and does not repeat after dismissal or remount',
    (tester) async {
      await mount(tester);
      for (var i = 0; i < 5; i++) {
        updates.emit(UpdateStatus.available);
      }
      await tester.pumpAndSettle();
      expect(routes.dialogs, 1);
      updates.emit(UpdateStatus.available);
      await tester.pumpAndSettle();
      expect(routes.dialogs, 1);

      await tester.tap(find.text('稍后'));
      await tester.pumpAndSettle();
      updates.emit(UpdateStatus.available);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(routes.dialogs, 1);

      await tester.pumpWidget(const SizedBox());
      await mount(tester);
      updates.emit(UpdateStatus.available, latest: _release(major: 3));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(routes.dialogs, 1);
      expect(updates.downloads, 0);
    },
  );

  testWidgets('rechecks eligibility before the scheduled frame', (
    tester,
  ) async {
    await mount(tester);
    updates.emit(UpdateStatus.available);
    updates.emit(UpdateStatus.error);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    updates.emit(UpdateStatus.available);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets(
    'affirmative opens a standalone update page without downloading',
    (tester) async {
      updates.emit(UpdateStatus.available);
      await mount(tester);
      await tester.tap(find.text('前往更新'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(AboutUpdatePage), findsOneWidget);
      final page = tester.widget<AboutUpdatePage>(find.byType(AboutUpdatePage));
      expect(page.embedded, isFalse);
      expect(page.updates, same(updates));
      expect(find.text('关于 / 更新'), findsOneWidget);
      expect(find.text('当前版本 1.0.0'), findsOneWidget);
      expect(updates.downloads, 0);
      expect(updates.initializations, 0);

      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      updates.emit(UpdateStatus.available);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(routes.dialogs, 1);
    },
  );

  testWidgets('startup prompt renders release notes as Markdown', (
    tester,
  ) async {
    updates.emit(
      UpdateStatus.available,
      latest: _release(notes: '**重要更新**\n\n- 修复识别'),
    );
    await mount(tester);

    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.text('重要更新'), findsOneWidget);
    expect(find.text('修复识别'), findsOneWidget);
    expect(find.textContaining('**重要更新**'), findsNothing);
  });

  testWidgets('long release notes scroll while actions stay reachable', (
    tester,
  ) async {
    final notes = List.generate(100, (i) => '更新说明第 $i 行').join('\n');
    updates.emit(UpdateStatus.available, latest: _release(notes: notes));
    await mount(tester);

    expect(find.byType(MarkdownBody), findsOneWidget);
    final scrollable = find
        .descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(Scrollable),
        )
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.maxScrollExtent, greaterThan(0));
    await tester.drag(scrollable, const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
    expect(find.text('稍后').hitTestable(), findsOneWidget);
    expect(find.text('前往更新').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty release notes show a fallback', (tester) async {
    updates.emit(UpdateStatus.available, latest: _release(notes: ' \n '));
    await mount(tester);
    expect(find.byType(MarkdownBody), findsNothing);
    expect(find.text('此版本暂无更新说明。'), findsOneWidget);
  });

  testWidgets('unmount cancels pending work and removes the listener', (
    tester,
  ) async {
    await mount(tester);
    expect(updates.observed, isTrue);
    updates.emit(UpdateStatus.available);
    await mount(tester, prompt: false);
    expect(updates.observed, isFalse);
    expect(find.byType(AlertDialog), findsNothing);
    updates.emit(UpdateStatus.available);
    await tester.pumpAndSettle();
    expect(routes.dialogs, 0);
    expect(tester.takeException(), isNull);

    // A callback that never showed a dialog must not consume the session.
    await mount(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('unmount while dialog is open prevents later navigation', (
    tester,
  ) async {
    updates.emit(UpdateStatus.available);
    await mount(tester);
    await mount(tester, prompt: false);
    expect(updates.observed, isFalse);
    await tester.tap(find.text('前往更新'));
    await tester.pumpAndSettle();
    expect(find.byType(AboutUpdatePage), findsNothing);
    expect(updates.downloads, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('replacing the service unsubscribes and observes the new one', (
    tester,
  ) async {
    await mount(tester);
    final replacement = _TestUpdates()..emit(UpdateStatus.available);
    addTearDown(replacement.dispose);
    await tester.pumpWidget(
      _app(
        updates: replacement,
        navigatorKey: navigatorKey,
        session: session,
        observer: routes,
        home: '后端设置',
      ),
    );
    await tester.pumpAndSettle();
    expect(updates.observed, isFalse);
    expect(replacement.observed, isTrue);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('后端设置'), findsOneWidget);
  });
}
