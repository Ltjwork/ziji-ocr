import 'dart:async';

import 'package:flutter/material.dart';

import '../pages/about_update_page.dart';
import '../services/update_service.dart';
import 'release_markdown.dart';

/// Remembers whether the startup prompt was shown, even if its widget remounts.
class StartupUpdatePromptSession {
  bool _shown = false;
}

final _processSession = StartupUpdatePromptSession();

/// Observes the startup check without starting a check or downloading anything.
class StartupUpdatePrompt extends StatefulWidget {
  const StartupUpdatePrompt({
    super.key,
    required this.updates,
    required this.navigatorKey,
    required this.child,
    this.session,
  });

  final UpdateService updates;
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  /// Omit in production to show at most once for the lifetime of the process.
  final StartupUpdatePromptSession? session;

  @override
  State<StartupUpdatePrompt> createState() => _StartupUpdatePromptState();
}

class _StartupUpdatePromptState extends State<StartupUpdatePrompt> {
  bool _scheduled = false;

  StartupUpdatePromptSession get _session => widget.session ?? _processSession;

  bool get _available =>
      widget.updates.status == UpdateStatus.available &&
      widget.updates.updateAvailable;

  @override
  void initState() {
    super.initState();
    widget.updates.addListener(_schedulePrompt);
    _schedulePrompt();
  }

  @override
  void didUpdateWidget(StartupUpdatePrompt oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.updates != widget.updates) {
      oldWidget.updates.removeListener(_schedulePrompt);
      widget.updates.addListener(_schedulePrompt);
    }
    _schedulePrompt();
  }

  void _schedulePrompt() {
    if (!mounted || _scheduled || _session._shown || !_available) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted || _session._shown || !_available) return;
      final navigator = widget.navigatorKey.currentState;
      if (navigator == null || !navigator.mounted) return;
      _session._shown = true;
      unawaited(_showPrompt(navigator, widget.updates));
    });
    // A service notification can arrive while the app has no pending frame.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _showPrompt(
    NavigatorState navigator,
    UpdateService updates,
  ) async {
    final release = updates.release!;
    final openUpdates = await showDialog<bool>(
      context: navigator.context,
      builder: (context) => AlertDialog(
        title: Text('发现新版本 ${release.version}'),
        scrollable: true,
        content: SizedBox(
          width: 480,
          child: ReleaseMarkdown(data: release.notes, emptyText: '此版本暂无更新说明。'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('前往更新'),
          ),
        ],
      ),
    );
    if (openUpdates != true ||
        !mounted ||
        !navigator.mounted ||
        widget.navigatorKey.currentState != navigator) {
      return;
    }
    unawaited(
      navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => AboutUpdatePage(updates: updates),
        ),
      ),
    );
  }

  @override
  void dispose() {
    widget.updates.removeListener(_schedulePrompt);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
