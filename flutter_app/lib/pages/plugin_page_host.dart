import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart';

import '../services/plugin_host/plugin_runtime.dart';

/// 插件页面宿主：一个普通全屏 Scaffold，内容是插件的 WebView 页面。
/// 页面自行 `ziji.invoke('ui.closePage', {result})` 关闭时走会话回执；
/// 用户按返回键/手势关闭视为无回执（null）。
class PluginPageHostWidget extends StatefulWidget {
  const PluginPageHostWidget({super.key, required this.session, this.title});

  final PluginPageSession session;
  final String? title;

  @override
  State<PluginPageHostWidget> createState() => _PluginPageHostWidgetState();
}

class _PluginPageHostWidgetState extends State<PluginPageHostWidget> {
  @override
  void initState() {
    super.initState();
    widget.session.requestClose = _closeFromPlugin;
  }

  @override
  void dispose() {
    if (widget.session.requestClose == _closeFromPlugin) {
      widget.session.requestClose = null;
    }
    super.dispose();
  }

  void _closeFromPlugin(Map<String, dynamic>? result) {
    if (!mounted) return;
    Navigator.of(context).pop(widget.session.pendingResult ?? result);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? widget.session.plugin.manifest.name),
      ),
      body: Webview(widget.session.controller),
    );
  }
}
