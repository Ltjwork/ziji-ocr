import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gujichazi/widgets/line_chart.dart';

Widget _host(List<ChartSeries> series) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 600,
            height: 260,
            child: TrainingLineChart(series: series),
          ),
        ),
      ),
    );

List<ChartSeries> _demoSeries() => [
      ChartSeries(name: 'mAP50', color: Colors.blue, points: [
        for (var i = 1; i <= 10; i++) (i.toDouble(), i / 10.0),
      ]),
      ChartSeries(name: 'loss', color: Colors.red, points: [
        for (var i = 1; i <= 10; i++) (i.toDouble(), 2.0 - i / 10.0),
      ]),
    ];

void main() {
  testWidgets('默认显示轮数提示，点图例可隐藏序列（至少留一条）', (tester) async {
    await tester.pumpWidget(_host(_demoSeries()));
    expect(find.text('共 10 轮 · 悬停或点按曲线查看数值'), findsOneWidget);

    await tester.tap(find.text('loss'));
    await tester.pump();
    // 隐藏后图例变灰但仍在（可再次点回），提示行不变
    expect(find.text('loss'), findsOneWidget);

    // 只剩一条可见时再点不允许多隐藏
    await tester.tap(find.text('mAP50'));
    await tester.pump();
    final chart = tester.widget<TrainingLineChart>(
      find.byType(TrainingLineChart),
    );
    expect(chart.series.length, 2);
  });

  testWidgets('点按图表定位到最近轮数并在值行显示各序列取值', (tester) async {
    await tester.pumpWidget(_host(_demoSeries()));
    final box = tester.renderObject<RenderBox>(
      find.byType(TrainingLineChart),
    );
    final center = box.localToGlobal(box.size.center(Offset.zero));
    await tester.tapAt(center);
    await tester.pump();
    // 600 宽、绘图区 46..590：中点映射到第 5 轮附近，两条序列都有取值
    expect(find.textContaining('第 '), findsOneWidget);
    expect(find.textContaining('mAP50='), findsOneWidget);
    expect(find.textContaining('loss='), findsOneWidget);
  });

  testWidgets('空序列不抛异常并显示暂无数据', (tester) async {
    await tester.pumpWidget(_host([
      const ChartSeries(name: 'mAP50', color: Colors.blue, points: []),
    ]));
    expect(find.text('暂无数据'), findsWidgets);
  });
}
