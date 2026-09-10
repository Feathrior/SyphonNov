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

  setUp(() {
    GraphStore.useIsolate = false;
    GraphStore.instance.clearAll();
  });

  tearDown(() {
    GraphStore.instance.clearAll();
    GraphStore.useIsolate = true;
  });

  testWidgets(
    'coordinate sections expand immediately without animated blank area',
    (tester) async {
      await pumpApp(tester);
      GraphStore.instance.addNode('axis_input', Offset.zero, triggerRun: false);
      await tester.pump();

      expect(find.text('基础'), findsOneWidget);
      await tester.drag(
        find.descendant(
          of: find.byType(PropertiesPanel),
          matching: find.byType(ListView),
        ),
        const Offset(0, -420),
      );
      await tester.pump();
      expect(find.text('坐标轴与网格'), findsOneWidget);
      expect(find.text('X 方向网格线'), findsNothing);

      await tester.tap(find.text('坐标轴与网格'));
      await tester.pump();

      expect(find.text('X 方向网格线'), findsOneWidget);
      expect(find.byType(ExpansionTile), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('ordinary nodes use semantic property sections', (tester) async {
    await pumpApp(tester);
    GraphStore.instance.addNode('func_curve', Offset.zero, triggerRun: false);
    await tester.pump();

    expect(find.text('基础'), findsOneWidget);
    expect(find.text('数据与计算'), findsOneWidget);
    expect(find.text('范围与精度'), findsOneWidget);
    expect(find.text('表达式'), findsNothing);

    await tester.tap(find.text('数据与计算'));
    await tester.pump();
    expect(find.text('表达式'), findsWidgets);
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
