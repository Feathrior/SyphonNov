import 'package:flutter/foundation.dart' show ValueKey;
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/main.dart';
import 'package:syphon_nov/store/graph_store.dart';
import 'package:syphon_nov/store/settings_store.dart';
import 'package:syphon_nov/ui/canvas_geometry.dart';
import 'package:syphon_nov/ui/node_canvas.dart';
import 'package:syphon_nov/ui/node_card.dart';

void main() {
  setUp(() {
    GraphStore.useIsolate = false;
    GraphStore.instance.clearAll();
    SettingsStore.instance.packageLibrary = [];
    SettingsStore.instance.shortcutBindings = {...defaultShortcutBindings};
  });

  tearDown(() {
    GraphStore.instance.clearAll();
    GraphStore.useIsolate = true;
  });

  test(
    'Package preserves its subgraph, serializes, and can be instantiated',
    () {
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
        const Offset(700, 30),
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

      final packageId = store.createPackage([first, second], '清洗模板');
      expect(packageId, isNotNull);
      final package = store.groups.single;
      expect(package.isPackage, isTrue);
      expect(package.collapsed, isTrue);
      expect(packageProxyRect(package, store.nodes, store.edges), isNotNull);
      expect(
        packageOutputPorts(package, store.nodes, store.edges),
        hasLength(1),
      );
      expect(
        packageOutputPorts(package, store.nodes, store.edges).single.nodeId,
        second,
      );
      expect(store.edges, hasLength(2));

      final template = store.packageTemplate(packageId!);
      expect(template, isNotNull);
      final json = store.saveGraph();
      expect(json, contains('"kind": "package"'));
      expect(store.loadGraph(json, silent: true), isTrue);
      expect(store.groups.single.collapsed, isTrue);

      final before = store.nodes.length;
      final cloneId = store.instantiatePackage(
        template!,
        const Offset(800, 120),
      );
      expect(cloneId, isNotNull);
      expect(store.nodes.length, before + 2);
      expect(store.edges, hasLength(3));
      expect(store.groups.where((group) => group.isPackage), hasLength(2));
    },
  );

  testWidgets('file drop creates a named table input node', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const SyphonApp());
    await tester.pump();
    final state = tester.state<NodeCanvasState>(find.byType(NodeCanvas));
    state.dropFileText(
      tester.getCenter(find.byType(NodeCanvas)),
      'x,y\n1,2\n',
      fileName: '实验数据',
    );
    await tester.pump();
    final node = GraphStore.instance.nodes.single;
    expect(node.configId, 'table_input');
    expect(node.params['name'], '实验数据');
    expect(node.params['mode'], 'manual');
  });

  testWidgets('collapsed Package renders one proxy and expands to its nodes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final first = GraphStore.instance.addNode(
      'table_input',
      const Offset(120, 90),
      triggerRun: false,
    );
    final second = GraphStore.instance.addNode(
      'table_to_scatter',
      const Offset(440, 90),
      triggerRun: false,
    );
    final packageId = GraphStore.instance.createPackage([
      first,
      second,
    ], '课堂数据');
    await tester.pumpWidget(const SyphonApp());
    await tester.pump();

    final proxy = find.byKey(ValueKey('package-node-$packageId'));
    expect(proxy, findsOneWidget);
    expect(find.byType(NodeCard), findsNothing);
    await tester.tapAt(tester.getCenter(proxy), buttons: kSecondaryButton);
    await tester.pump();
    await tester.pump();
    expect(find.text('展开 Package'), findsOneWidget);
    await tester.tap(find.text('展开 Package'));
    await tester.pump();
    expect(proxy, findsNothing);
    expect(find.byType(NodeCard), findsNWidgets(2));
  });

  testWidgets('physical Delete remains available after rebinding deletion', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final id = GraphStore.instance.addNode(
      'table_input',
      const Offset(100, 80),
      triggerRun: false,
    );
    GraphStore.instance.setMultiSelected({id});
    SettingsStore.instance.shortcutBindings['delete'] = 'Ctrl+D';
    await tester.pumpWidget(const SyphonApp());
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.delete);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect(GraphStore.instance.nodes, isEmpty);
  });
}
