import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/main.dart';
import 'package:syphon_nov/models/registry.dart';
import 'package:syphon_nov/store/graph_store.dart';
import 'package:syphon_nov/ui/properties_panel.dart';

void main() {
  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const SyphonApp());
    await tester.pump();
  }

  Future<void> tapTab(WidgetTester tester, String name) async {
    final chip = find.byKey(ValueKey('props-tab-$name'));
    expect(chip, findsOneWidget, reason: '缺少页签 $name');
    await tester.tap(chip);
    await tester.pumpAndSettle();
  }

  setUp(() {
    GraphStore.useIsolate = false;
    GraphStore.instance.clearAll();
  });

  tearDown(() {
    GraphStore.instance.clearAll();
    GraphStore.useIsolate = true;
  });

  testWidgets('coordinate panel is split into top category tabs', (
    tester,
  ) async {
    await pumpApp(tester);
    GraphStore.instance.addNode('axis_input', Offset.zero, triggerRun: false);
    await tester.pump();

    // 顶部分类完全对齐绘图区域面板:常规 / 标题 / 布局 / 区域 / 游标。
    for (final name in ['常规', '标题', '布局', '区域', '游标']) {
      expect(
        find.byKey(ValueKey('props-tab-$name')),
        findsOneWidget,
        reason: '坐标系输入应有 $name 页签',
      );
    }

    // 默认停在常规页:基础 / 数据范围 / 范围与尺度 三张分组卡片。
    expect(find.text('范围与尺度'), findsOneWidget);
    expect(find.text('区域背景'), findsNothing);
    expect(find.text('启用游标'), findsNothing);

    // 区域页承载背景/边框/网格/箭头。
    await tapTab(tester, '区域');
    expect(find.text('区域背景'), findsOneWidget);
    expect(find.text('范围与尺度'), findsNothing);

    // 游标页只放游标参数。
    await tapTab(tester, '游标');
    expect(find.text('游标线宽(pt)'), findsOneWidget);
    expect(find.text('区域背景'), findsNothing);

    // 切回常规页。
    await tapTab(tester, '常规');
    expect(find.text('范围与尺度'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ordinary nodes use semantic property tabs', (tester) async {
    await pumpApp(tester);
    GraphStore.instance.addNode('func_curve', Offset.zero, triggerRun: false);
    await tester.pump();

    expect(find.byKey(const ValueKey('props-tab-基础')), findsOneWidget);
    expect(find.byKey(const ValueKey('props-tab-数据与计算')), findsOneWidget);
    expect(find.byKey(const ValueKey('props-tab-范围与精度')), findsOneWidget);
    expect(find.text('表达式'), findsNothing);

    await tapTab(tester, '数据与计算');
    expect(find.text('表达式'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('table input sidebar keeps its content under the top categories', (
    tester,
  ) async {
    await pumpApp(tester);
    GraphStore.instance.addNode('table_input', Offset.zero, triggerRun: false);
    await tester.pumpAndSettle();
    for (final name in ['基础', '范围与精度', '导入导出']) {
      expect(find.byKey(ValueKey('props-tab-$name')), findsOneWidget);
    }
    // 基础页要有内容(不能只剩页签)
    expect(find.text('名称'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  test('ordinary parameters are assigned to semantic groups', () {
    final config = getConfig('func_curve')!;
    String group(String key) => propertyGroupForParam(
      config.params.singleWhere((param) => param.key == key),
    );
    expect(group('expression'), '数据与计算');
    expect(group('xMin'), '范围与精度');
    expect(group('lineStyle'), '外观');
    expect(group('name'), '基础');
  });
}
