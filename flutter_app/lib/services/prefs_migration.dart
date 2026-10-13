import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// +103 品牌更名的偏好迁移。Windows 上 shared_preferences 的存储路径跟随
/// exe 版本信息（%APPDATA%\CompanyName\ProductName\shared_preferences.json），
/// 更名把 ProductName 从模板默认 flutter_app 改成「字迹」后，新版读写
/// 全新的空目录——用户更名前的全部设置（鼠标手势、Ollama、导出选项、
/// 悬浮窗位置等）留在旧目录里，表现为"设置完没有被保存"。启动时一次
/// 性把旧文件里的键补进当前存储：已存在的键**不覆盖**（更名后新产生
/// 的值优先），迁移完成（或确认无旧文件）置标志，之后启动直接返回。
const String _legacyCompanyDir = 'com.example';
const String _legacyProductDir = 'flutter_app';

/// 迁移已完成的标志键（测试用来断言只跑一次）。
const String kLegacyPrefsMigratedFlag = 'legacy_prefs_migrated_v1';

/// 把旧身份目录的偏好迁入当前存储。任何异常都静默放弃——迁移是尽力
/// 而为，绝不能挡启动。[appDataDir] 仅供测试注入 %APPDATA%，缺省取
/// 环境变量。
Future<void> migrateLegacyPrefs({String? appDataDir}) async {
  if (!Platform.isWindows) return;
  try {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(kLegacyPrefsMigratedFlag) ?? false) return;
    await _copyMissingKeys(prefs, appDataDir);
    // 走到这（含无旧文件/文件损坏）都算完成，置标志不再扫；中途抛
    // 异常则不置，下次启动再试。
    await prefs.setBool(kLegacyPrefsMigratedFlag, true);
  } catch (_) {
    // 读不了/写不了都当没发生过：下次启动标志未置会再试一次。
  }
}

/// 逐键拷贝旧文件里当前存储缺失的键；旧文件不存在或损坏则什么都不做。
Future<void> _copyMissingKeys(
  SharedPreferences prefs,
  String? appDataDir,
) async {
  final appData = appDataDir ?? Platform.environment['APPDATA'];
  if (appData == null) return;
  final file = File(
    p.join(appData, _legacyCompanyDir, _legacyProductDir, 'shared_preferences.json'),
  );
  if (!await file.exists()) return;
  final Object? decoded;
  try {
    decoded = jsonDecode(await file.readAsString());
  } catch (_) {
    return; // 文件在但损坏：当无可迁内容
  }
  if (decoded is! Map) return;
  for (final entry in decoded.entries) {
    // 文件里键带 flutter. 前缀，Dart API 用去前缀的键；非前缀键不是
    // 本框架写的，跳过。
    final key = entry.key;
    if (key is! String || !key.startsWith('flutter.')) continue;
    final dartKey = key.substring('flutter.'.length);
    if (prefs.containsKey(dartKey)) continue;
    final value = entry.value;
    if (value is bool) {
      await prefs.setBool(dartKey, value);
    } else if (value is int) {
      await prefs.setInt(dartKey, value);
    } else if (value is double) {
      await prefs.setDouble(dartKey, value);
    } else if (value is String) {
      await prefs.setString(dartKey, value);
    } else if (value is List) {
      await prefs.setStringList(dartKey, value.cast<String>());
    }
  }
}
