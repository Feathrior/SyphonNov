// MiniTable 渲染与滚动冒烟测试(回归:"Null check operator"崩溃 + 滚动条拖到底无法回滚)
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/ui/data_preview.dart';

void main() {
  testWidgets('MiniTable 渲染不抛错,滚动条可双向拖动', (tester) async {
    final rows = [
      for (var i = 0; i < 30; i++) [for (var c = 0; c < 4; c++) 'v$i-$c'],
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MiniTable(
            headers: const ['a', 'b', 'c', 'd'],
            rows: rows,
            maxHeight: 100,
          ),
        ),
      ),
    );
    // 布局维度就绪后滚动条才会出现(通知→重建需要若干帧)
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(tester.takeException(), isNull);

    // 侧边滚动条应渲染出来
    final strip = find.byType(GestureDetector).last;
    expect(strip, findsOneWidget);

    // 按住滚动条拖到最下面,再拖回上面:双向都不抛错
    await tester.dragFrom(
      tester.getBottomLeft(strip) + const Offset(5, -10),
      const Offset(0, 500),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.dragFrom(
      tester.getTopLeft(strip) + const Offset(5, 90),
      const Offset(0, -500),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
