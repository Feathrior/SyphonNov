// MiniTable 渲染与滚动冒烟测试(回归:"Null check operator"崩溃 + 滚动到底无法回滚)
// 实现已改为双层 SingleChildScrollView(MiniTable 自带实现,无自定义滚动条),
// 冒烟点为:渲染不抛错、纵向/横向滚动双向均不抛错。
// 另含鼠标滚轮回归:纵向滚轮必须驱动外层纵向滚动(数据输出节点 Expanded 布局)。
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/ui/data_preview.dart';

void main() {
  testWidgets('MiniTable 渲染不抛错,纵横向滚动可双向拖动', (tester) async {
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
    // 布局维度就绪(通知→重建需要若干帧)
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(tester.takeException(), isNull);
    expect(find.text('v29-3'), findsOneWidget);

    final center = tester.getCenter(find.byType(Table));

    // 纵向:向下滚动到底,再滚回顶部,双向都不抛错
    await tester.dragFrom(center, const Offset(0, -500));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.dragFrom(center, const Offset(0, 500));
    await tester.pump();
    expect(tester.takeException(), isNull);

    // 横向:向右滚动,再滚回左侧,双向都不抛错
    await tester.dragFrom(center, const Offset(-500, 0));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.dragFrom(center, const Offset(500, 0));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  /// 滚轮必须落在表格可视区域内:表格完整布局超出 maxHeight 的裁剪区,
  /// getCenter(Table) 会落在空白处。探针取可视区内一点。
  Future<ScrollableState> pumpMiniTable(
    WidgetTester tester, {
    required double maxHeight,
  }) async {
    final rows = [
      for (var i = 0; i < 40; i++) [for (var c = 0; c < 4; c++) 'w$i-$c'],
    ];
    final widget = MiniTable(
      headers: const ['a', 'b', 'c', 'd'],
      rows: rows,
      maxHeight: maxHeight,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: maxHeight.isFinite
              ? widget
              : Column(children: [Expanded(child: widget)]),
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    final outer = tester
        .stateList<ScrollableState>(
          find.descendant(
            of: find.byType(MiniTable),
            matching: find.byType(Scrollable),
          ),
        )
        .first;
    // 滚到中间再滚轮,避免边界钳制
    outer.position.jumpTo(outer.position.maxScrollExtent / 2);
    await tester.pump();
    return outer;
  }

  Future<void> wheelAt(WidgetTester tester, {required Offset delta}) async {
    // 探针取外层纵向滚动体(可视视口)中心:表格被裁剪/滚动后,
    // MiniTable/Table 的几何中心会落在可视区之外,滚轮事件将无法命中。
    final scrollable = find
        .descendant(
          of: find.byType(MiniTable),
          matching: find.byType(Scrollable),
        )
        .first;
    final tp = TestPointer(1, PointerDeviceKind.mouse);
    tp.hover(tester.getRect(scrollable).center);
    await tester.sendEventToBinding(tp.scroll(delta));
    await tester.pump();
  }

  testWidgets('滚轮:maxHeight 有限(检查器预览)时纵向滚动生效', (tester) async {
    final outer = await pumpMiniTable(tester, maxHeight: 100);
    final mid = outer.position.pixels;
    await wheelAt(tester, delta: const Offset(0, 300));
    final after = outer.position.pixels;
    expect(after, greaterThan(mid));
  });

  testWidgets('滚轮:Expanded 布局(数据输出节点)时纵向滚动生效', (tester) async {
    final outer = await pumpMiniTable(tester, maxHeight: double.infinity);
    final mid = outer.position.pixels;
    await wheelAt(tester, delta: const Offset(0, -300));
    final after = outer.position.pixels;
    expect(after, lessThan(mid));
  });
}
