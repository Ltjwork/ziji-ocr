// 朝代基准目录解析（DynastyBenchStore）测试：
// - choose() 只接受含 gt/01_xianqin.json 的合法基准目录并记住；
// - resolve() 优先返回记住的目录；
// - 自动探测结果要么为空、要么确实是基准目录（探测路径因运行环境而异，
//   不断言具体值，防测试随仓库状态漂移）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/services/dynasty_bench_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('choose 拒绝非基准目录且不落盘', () async {
    SharedPreferences.setMockInitialValues({});
    final tmp = await Directory.systemTemp.createTemp('bench_not');
    addTearDown(() => tmp.delete(recursive: true));
    expect(await DynastyBenchStore.choose(tmp.path), isFalse);
    expect(await DynastyBenchStore.resolve(), anyOf(isNull, (String s) => File(
      '$s${Platform.pathSeparator}gt${Platform.pathSeparator}01_xianqin.json',
    ).existsSync()));
  });

  test('choose 接受合法基准目录且 resolve 优先返回它', () async {
    SharedPreferences.setMockInitialValues({});
    final tmp = await Directory.systemTemp.createTemp('bench_ok');
    addTearDown(() => tmp.delete(recursive: true));
    await Directory(
      '${tmp.path}${Platform.pathSeparator}gt',
    ).create(recursive: true);
    await File(
      '${tmp.path}${Platform.pathSeparator}gt${Platform.pathSeparator}01_xianqin.json',
    ).writeAsString('{}');
    expect(await DynastyBenchStore.choose(tmp.path), isTrue);
    expect(await DynastyBenchStore.resolve(), tmp.path);
  });

  test('记住的目录失效（被删除）后 resolve 不再返回它', () async {
    final tmp = await Directory.systemTemp.createTemp('bench_gone');
    final gtDir = Directory('${tmp.path}${Platform.pathSeparator}gt');
    await gtDir.create(recursive: true);
    await File(
      '${tmp.path}${Platform.pathSeparator}gt${Platform.pathSeparator}01_xianqin.json',
    ).writeAsString('{}');
    SharedPreferences.setMockInitialValues({'dynasty_bench_dir_v1': tmp.path});
    await tmp.delete(recursive: true);
    addTearDown(() {
      if (tmp.existsSync()) tmp.delete(recursive: true);
    });
    final resolved = await DynastyBenchStore.resolve();
    expect(resolved == tmp.path, isFalse);
  });
}
