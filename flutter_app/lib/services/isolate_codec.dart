/// 大块 JSON/base64 编解码与诊断图落盘搬离 UI isolate。
///
/// Flutter Windows 的 root isolate 兼任平台消息泵线程：批量拆分时
/// 12 个 AI worker 的多 MB 同步 jsonEncode（请求体带整行图 + 40 张字
/// 图的 base64）、缩略图响应 jsonDecode、每行 40+ 张溯源图的
/// base64Decode + 逐张 fsync、每页溯源 JSON 的缩进序列化——全部背靠
/// 背执行时消息泵断粮超过 5 秒，Windows 判定 AppHang 把进程强杀
///（批量"每次都异常退出"的根因，事件日志 Application Hang 佐证）。
/// Isolate.run 每次几毫秒的派生开销，远小于搬走的同步段。
///
/// 约定：入参须为可发送的纯数据（Map/List/String/num）；返回值跨
/// isolate 深拷贝回传，调用方自行 cast。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// 后台 isolate 里 jsonEncode。
Future<String> encodeJsonInIsolate(Object? data) =>
    Isolate.run(() => jsonEncode(data));

/// 后台 isolate 里 jsonDecode（返回值原样传回，调用方自行 cast）。
Future<Object?> decodeJsonInIsolate(String text) =>
    Isolate.run(() => jsonDecode(text));

/// 后台 isolate 里 base64 解码。
Future<Uint8List> base64DecodeInIsolate(String text) =>
    Isolate.run(() => base64Decode(text));

/// 后台 isolate 里"base64 解码 + 写文件"（诊断图落盘：解码与 fsync
/// 都不占 UI isolate；[flush] 落在 worker 上，持久性不受影响）。
Future<void> writeBase64FileInIsolate(
  String base64Text,
  String path, {
  bool flush = true,
}) =>
    Isolate.run(() {
      File(path).writeAsBytesSync(base64Decode(base64Text), flush: flush);
    });

/// 后台 isolate 里"JSON 缩进序列化 + 写文件"（溯源记录落盘）。
Future<void> writeJsonFileInIsolate(
  Object? data,
  String path, {
  bool flush = true,
}) =>
    Isolate.run(() {
      File(path).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(data),
        flush: flush,
      );
    });
