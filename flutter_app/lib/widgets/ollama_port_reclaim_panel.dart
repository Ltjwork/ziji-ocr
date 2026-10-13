import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'attached_scrollbar.dart';
import 'package:flutter/services.dart';

import '../services/ollama_port_reclaim.dart';

/// 「抢回 Ollama 端口」面板（服务连接卡内，仅 Windows 有意义）：Hyper-V/
/// WSL 的 winnat 开机随机保留端口段可能盖住 Ollama 端口，服务端 bind 被
/// 系统拒绝、重启 Ollama 也没用。这里先体检（试绑定 + 读系统保留区间），
/// 确认被抢占后一键提权修复（net stop winnat → 登记应用保留 → net start
/// winnat），成功后回调 [onReclaimed] 自动重测连接。
class OllamaPortReclaimPanel extends StatefulWidget {
  const OllamaPortReclaimPanel({
    super.key,
    required this.baseUrl,
    this.onReclaimed,
  });

  final String baseUrl;

  /// 抢回成功后调用（返回是否已重连成功，面板据此收尾提示）。
  final Future<bool> Function()? onReclaimed;

  @override
  State<OllamaPortReclaimPanel> createState() => _OllamaPortReclaimPanelState();
}

class _OllamaPortReclaimPanelState extends State<OllamaPortReclaimPanel> {
  OllamaPortHealth? _health;
  bool _probing = false;
  bool _working = false;
  String? _hint;
  bool _hintOk = false;
  int _port = OllamaPortReclaim.defaultOllamaPort;
  final List<String> _log = [];
  final ScrollController _logCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _port = OllamaPortReclaim.portFromBaseUrl(widget.baseUrl);
    unawaited(_probe());
  }

  @override
  void didUpdateWidget(covariant OllamaPortReclaimPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final p = OllamaPortReclaim.portFromBaseUrl(widget.baseUrl);
    if (p != _port) {
      _port = p;
      _health = null;
      _hint = null;
      _log.clear();
      unawaited(_probe());
    }
  }

  @override
  void dispose() {
    _logCtrl.dispose();
    super.dispose();
  }

  Future<void> _probe() async {
    setState(() => _probing = true);
    final h = await OllamaPortReclaim.probe(_port);
    if (!mounted) return;
    setState(() {
      _health = h;
      _probing = false;
    });
  }

  Future<void> _reclaim() async {
    final confirmed = await _confirmDialog();
    if (confirmed != true || _working || !mounted) return;
    setState(() {
      _working = true;
      _hint = null;
      _log.clear();
    });
    try {
      await OllamaPortReclaim.reclaim(_port, onLog: _appendLog);
      // winnat 刚重启完 Ollama 还没轮到下一次重试绑定，稍等再重测连接。
      await Future<void>.delayed(const Duration(seconds: 3));
      if (!mounted) return;
      final reconnected = await widget.onReclaimed?.call() ?? false;
      if (!mounted) return;
      unawaited(_probe());
      setState(() {
        _working = false;
        _hintOk = reconnected;
        _hint = reconnected
            ? '端口 $_port 已抢回并重新连上 Ollama；该端口已登记为应用保留，'
                  '重启电脑也不会再被抢占。'
            : '端口 $_port 已抢回（应用保留，重启后也不会再被抢占）。'
                  'Ollama 还没重新绑定成功，稍后点「测试连接并获取模型」重试。';
      });
    } on OllamaPortReclaimException catch (e) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _hintOk = false;
        _hint = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _hintOk = false;
        _hint = '执行失败：$e';
      });
    }
  }

  Future<bool?> _confirmDialog() {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('抢回端口 $_port'),
        content: Text(
          '将请求管理员权限执行以下修复（会弹出系统授权窗口）：\n\n'
          '1. 暂停 Windows NAT 服务（winnat）\n'
          '2. 把端口 $_port 登记为应用保留（此后开机不再被 Hyper-V/WSL 抢占）\n'
          '3. 重新启动 winnat\n\n'
          'winnat 重启期间 Docker/WSL 的网络会瞬断几秒；完成后 Ollama 会自动'
          '重新绑定端口。\n\n确定继续吗？',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('继续')),
        ],
      ),
    );
  }

  void _appendLog(String line) {
    if (!mounted) return;
    setState(() {
      _log.add(line);
      if (_log.length > 200) _log.removeRange(0, _log.length - 200);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logCtrl.hasClients) {
        _logCtrl.jumpTo(_logCtrl.position.maxScrollExtent);
      }
    });
  }

  void _copyLog() {
    Clipboard.setData(ClipboardData(text: _log.join('\n')));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('日志已复制'), duration: Duration(seconds: 1)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) return const SizedBox.shrink();
    final (icon, color, text, showButton) = _status;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_probing)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(fontSize: 12, color: color),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (showButton)
                FilledButton.tonalIcon(
                  onPressed: _working ? null : () => unawaited(_reclaim()),
                  icon: _working
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.lock_open, size: 18),
                  label: Text(_working ? '正在抢回…' : '抢回端口'),
                ),
              const Spacer(),
              if (_log.isNotEmpty)
                IconButton(
                  tooltip: '复制日志',
                  icon: const Icon(Icons.copy, size: 16),
                  onPressed: _copyLog,
                ),
              TextButton(
                onPressed: _working ? null : () => unawaited(_probe()),
                child: const Text('重新检测'),
              ),
            ],
          ),
          if (_hint != null) ...[
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  _hintOk ? Icons.check_circle : Icons.error_outline,
                  size: 14,
                  color: _hintOk ? Colors.green.shade700 : Colors.orange.shade800,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    _hint!,
                    style: TextStyle(
                      fontSize: 12,
                      color: _hintOk ? Colors.green.shade700 : Colors.orange.shade800,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (_log.isNotEmpty) ...[
            const SizedBox(height: 8),
            _logPanel(),
          ],
        ],
      ),
    );
  }

  Widget _logPanel() {
    return Container(
      height: 132,
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF101418),
        borderRadius: BorderRadius.circular(8),
      ),
      child: AttachedScrollbar(
        controller: _logCtrl,
        child: ListView.builder(
          controller: _logCtrl,
          itemCount: _log.length,
          itemBuilder: (context, index) => Text(
            _log[index],
            style: const TextStyle(fontSize: 11, height: 1.5, color: Color(0xFFC9D4DC)),
          ),
        ),
      ),
    );
  }

  /// (图标, 颜色, 结论文案, 是否显示「抢回端口」按钮)。
  (IconData, Color, String, bool) get _status {
    final h = _health;
    if (_probing || h == null) {
      return (Icons.hourglass_top, Colors.grey.shade600, '正在检测端口 $_port 的绑定情况…', false);
    }
    if (h.bindable) {
      final r = h.hitRange;
      return (
        Icons.check_circle,
        Colors.teal.shade700,
        r?.administered ?? false
            ? '端口 $_port 可正常绑定（已在应用保留区间 ${r!.start}–${r.end} 内），不是端口问题。'
            : '端口 $_port 当前未被系统保留，可正常绑定；连接失败应是 Ollama 没在运行或服务地址不对。',
        false,
      );
    }
    if (h.bindError == OllamaPortReclaim.errorInUse) {
      return (
        Icons.info_outline,
        Colors.orange.shade800,
        '端口 $_port 已被其他程序占用（错误 10048）。若 Ollama 正在运行说明服务正常，'
            '否则需找出占用程序或修改服务地址。',
        false,
      );
    }
    if (h.bindError == OllamaPortReclaim.errorAccessDenied) {
      final r = h.hitRange;
      return (
        Icons.warning_amber_rounded,
        Colors.orange.shade800,
        r == null
            ? '端口 $_port 被 Windows 系统保留（绑定被拒绝，错误 10013），'
                  'Ollama 服务端无法监听该端口，重启 Ollama 也无效。'
            : '端口 $_port 被 Windows 系统保留（端口段 ${r.start}–${r.end}，'
                  'Hyper-V/WSL 开机随机保留），Ollama 服务端无法绑定，重启 Ollama 也无效。',
        true,
      );
    }
    return (
      Icons.help_outline,
      Colors.grey.shade600,
      '端口 $_port 绑定失败（错误 ${h.bindError ?? '未知'}）。',
      false,
    );
  }
}
