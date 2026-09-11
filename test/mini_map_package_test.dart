import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/main.dart';
import 'package:syphon_nov/store/graph_store.dart';
import 'package:syphon_nov/ui/mini_map.dart';

void main() {
  setUp(() {
    GraphStore.useIsolate = false;
    GraphStore.instance.clearAll();
  });

  tearDown(() {
    GraphStore.instance.clearAll();
    GraphStore.useIsolate = true;
  });

  /// 构造:两个节点打包成折叠 Package + 一个 Package 外部节点
  ({GraphStore store, String packageId, String first, String second, String outside})
  buildGraph() {
    final store = GraphStore.instance;
    final first = store.addNode(
      'table_input',
      const Offset(20, 30),
      triggerRun: false,
    );
    final second = store.addNode(
      'table_to_scatter',
      const Offset(360, 30),
      triggerRun: false,
    );
    final outside = store.addNode(
      'axis_input',
      const Offset(760, 30),
      triggerRun: false,
    );
    store.onConnect(
      source: first,
      target: second,
      sourceHandle: 'out0',
      targetHandle: 'in0',
      triggerRun: false,
    );
    store.onConnect(
      source: second,
      target: outside,
      sourceHandle: 'out0',
      targetHandle: 'in0',
      triggerRun: false,
    );
    final packageId = store.createPackage([first, second], '清洗模板')!;
    return (
      store: store,
      packageId: packageId,
      first: first,
      second: second,
      outside: outside,
    );
  }

  test('collapsed package hides its members and shows a proxy', () {
    final g = buildGraph();
    expect(g.store.groups.single.collapsed, isTrue);

    final scene = buildMiniMapScene(
      g.store.nodes,
      g.store.edges,
      g.store.groups,
    );
    // 成员节点不再出现在迷你图里,只留 Package 外部的节点
    expect(scene.nodes.map((node) => node.id), [g.outside]);
    expect(scene.hidden, containsAll([g.first, g.second]));
    expect(scene.packages.keys, [g.packageId]);
    expect(scene.packageOf[g.first], g.packageId);
    expect(scene.packageOf[g.second], g.packageId);

    final rect = scene.packages[g.packageId]!;
    expect(rect.width, greaterThan(0));
    expect(rect.height, greaterThan(0));

    // Package 内部连线不画;跨边界连线改指到代理矩形边缘
    final internal = g.store.edges.firstWhere((e) => e.source == g.first);
    expect(miniMapEdgeRoute(scene, internal), isNull);

    final crossing = g.store.edges.firstWhere((e) => e.target == g.outside);
    final route = miniMapEdgeRoute(scene, crossing)!;
    // 源端被折叠隐藏 → 端点落在代理矩形右缘;目标端仍是真实节点中心
    expect(route.a, rect.centerRight);
    expect(route.b.dx, greaterThan(rect.right));
  });

  test('expanded package restores its members in the minimap scene', () {
    final g = buildGraph();
    g.store.setPackageCollapsed(g.packageId, false);

    final scene = buildMiniMapScene(
      g.store.nodes,
      g.store.edges,
      g.store.groups,
    );
    expect(scene.nodes.map((node) => node.id), [g.first, g.second, g.outside]);
    expect(scene.packages, isEmpty);
    expect(scene.hidden, isEmpty);

    final internal = g.store.edges.firstWhere((e) => e.source == g.first);
    expect(miniMapEdgeRoute(scene, internal), isNotNull);
  });

  testWidgets('minimap renders a collapsed package without exceptions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    buildGraph();

    await tester.pumpWidget(const SyphonApp());
    await tester.pump();

    final map = find.byType(MiniMapView);
    expect(map, findsOneWidget);
    final view = tester.widget<MiniMapView>(map);
    expect(view.groups.where((group) => group.isPackage), hasLength(1));
    expect(tester.takeException(), isNull);

    // 画布缩放/平移变化后仍能正常重绘
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });
}
