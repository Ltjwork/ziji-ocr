// 设置面板数字输入框（NumField）行为测试。
//
// 背景：旧实现在 build 里现建 TextEditingController（每敲一键保存设置并
// 重建界面 → 光标重置行首、`1` 回写成 `1.0`，继续输入插在开头越打越乱，
// 实测出现 `.15`、`.5151511.0`）。本套件锁定重构后的行为：
// 1. 打字过程中的父级重建（保存回写同值）不打断输入、不移动光标；
// 2. 小数逐键输入（1 → 1. → 1.15）正确累积并上报；
// 3. 外部值真正变化时回写到框（含清空）；
// 4. 非数字字符被输入格式化器拦截。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/widgets/engine_settings_section.dart' show NumField;

class _Host extends StatefulWidget {
  const _Host({this.initial, this.asInt = false});

  final num? initial;
  final bool asInt;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late num? value = widget.initial;

  // 供测试模拟"设置被别处修改后回写"：外部入口不直接碰 State.setState。
  void setExternal(num? v) => setState(() => value = v);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: NumField(
          value: value,
          hint: 'hint',
          asInt: widget.asInt,
          onChanged: (v) => setState(() => value = v),
        ),
      ),
    );
  }
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
}

String _fieldText(WidgetTester tester) => tester
    .widget<TextField>(find.byType(TextField))
    .controller!
    .text;

num? _hostValue(WidgetTester tester) =>
    tester.state<_HostState>(find.byType(_Host)).value;

void main() {
  testWidgets('打字中途父级重建不回写同值、光标保持在文本末尾', (tester) async {
    await tester.pumpWidget(const _Host());
    await _type(tester, '1');
    // onChanged 已上报 1.0 并触发父级重建：旧实现此时会显示 "1.0"。
    expect(_hostValue(tester), 1.0);
    expect(_fieldText(tester), '1');
    final selection =
        tester.widget<TextField>(find.byType(TextField)).controller!.selection;
    expect(selection.baseOffset, 1); // 光标仍在末尾，续打不会插到行首
  });

  testWidgets('小数逐键输入正确累积（1 → 1. → 1.15）', (tester) async {
    await tester.pumpWidget(const _Host());
    await _type(tester, '1');
    await _type(tester, '1.');
    expect(_hostValue(tester), 1.0);
    expect(_fieldText(tester), '1.'); // 拖尾小数点不被回写成 "1.0"
    await _type(tester, '1.15');
    expect(_hostValue(tester), 1.15);
    expect(_fieldText(tester), '1.15');
  });

  testWidgets('外部值真正变化时回写输入框', (tester) async {
    await tester.pumpWidget(const _Host(initial: 1.15));
    expect(_fieldText(tester), '1.15');
    final state = tester.state<_HostState>(find.byType(_Host));
    state.setExternal(2.5);
    await tester.pump();
    expect(_fieldText(tester), '2.5');

    // 清空：上报 null、框保持空、不被旧值回填。
    await _type(tester, '');
    expect(_hostValue(tester), isNull);
    expect(_fieldText(tester), '');
    await tester.pump();
    expect(_fieldText(tester), '');
  });

  testWidgets('非数字字符被输入格式化器拦截', (tester) async {
    await tester.pumpWidget(const _Host());
    await _type(tester, 'abc1.5x');
    expect(_fieldText(tester), '1.5');
    expect(_hostValue(tester), 1.5);
  });

  testWidgets('整数档（像素数）按 int 上报', (tester) async {
    await tester.pumpWidget(const _Host(asInt: true));
    await _type(tester, '100');
    expect(_hostValue(tester), 100);
    expect(_hostValue(tester) is int, isTrue);
  });
}
