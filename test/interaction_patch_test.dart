import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/main.dart';
import 'package:syphon_nov/models/presets.dart';
import 'package:syphon_nov/store/graph_store.dart';
import 'package:syphon_nov/store/settings_store.dart';
import 'package:syphon_nov/ui/canvas_geometry.dart';
import 'package:syphon_nov/ui/node_card.dart';
import 'package:syphon_nov/ui/shortcuts_panel.dart';

void main() {
  setUp(() {
    GraphStore.useIsolate = false;
    GraphStore.instance.clearAll();
    SettingsStore.instance.shortcutBindings = {...defaultShortcutBindings};
  });

  tearDown(() {
    GraphStore.instance.clearAll();
    GraphStore.useIsolate = true;
    SettingsStore.instance.resetShortcuts();
  });

  test('viewer dimensions resize and survive node serialization', () {
    final store = GraphStore.instance;
    store.nodes = const [
      GraphNode(id: 'viewer', configId: 'viz_line', params: {}),
    ];
    final before = nodeSize(store.nodes.single, const []);
    store.resizeViewerNode('viewer', 720, 480);
    final resized = store.nodes.single;
    final after = nodeSize(resized, const []);

    expect(after.width, 720);
    expect(after.height - before.height, closeTo(265, .001));
    final restored = GraphNode.fromJson(resized.toJson());
    expect(nodeVisualWidth(restored), 720);
    expect(nodeViewerHeight(restored), 480);
  });

  testWidgets('Ctrl+A selects all and Ctrl+X cuts the selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    GraphStore.instance.loadGraph(kDemoGraphJson, silent: true);
    await tester.pumpWidget(const SyphonApp());
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(
      GraphStore.instance.multiSelected.length,
      GraphStore.instance.nodes.length,
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyX);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyX);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(GraphStore.instance.nodes, isEmpty);
    expect(GraphStore.instance.hasClipboard, isTrue);
  });

  testWidgets('a customized shortcut replaces its previous binding', (
    tester,
  ) async {
    SettingsStore.instance.setShortcut('selectAll', 'Alt+A');
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    final event = KeyDownEvent(
      logicalKey: LogicalKeyboardKey.keyA,
      physicalKey: PhysicalKeyboardKey.keyA,
      timeStamp: Duration.zero,
    );
    expect(SettingsStore.instance.matchesShortcut('selectAll', event), isTrue);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    expect(SettingsStore.instance.shortcutFor('selectAll'), 'Alt+A');
  });

  testWidgets('viewer resize handle updates the rendered card geometry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final id = GraphStore.instance.addNode(
      'viz_line',
      const Offset(240, 80),
      triggerRun: false,
    );
    await tester.pumpWidget(const SyphonApp());
    await tester.pumpAndSettle();
    final card = find.byWidgetPredicate(
      (widget) => widget is NodeCard && widget.nodeId == id,
    );
    final before = tester.getSize(card);

    await tester.drag(
      find.byKey(ValueKey('viewer-resize-$id')),
      const Offset(80, 60),
    );
    await tester.pump();
    final after = tester.getSize(card);
    expect(after.width, greaterThan(before.width));
    expect(after.height, greaterThan(before.height));

    await tester.drag(
      find.byKey(ValueKey('viewer-resize-$id')),
      const Offset(50, 40),
    );
    await tester.pump();
    final afterSecondResize = tester.getSize(card);
    expect(afterSecondResize.width, greaterThan(after.width));
    expect(afterSecondResize.height, greaterThan(after.height));
  });

  testWidgets('shortcut panel records a replacement chord', (tester) async {
    await tester.pumpWidget(MaterialApp(home: ShortcutsPanel(onClose: () {})));
    await tester.tap(find.text('Ctrl+A'));
    await tester.pump();
    expect(find.text('请按下新的组合键 · Esc 取消'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyQ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyQ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    expect(SettingsStore.instance.shortcutFor('selectAll'), 'Alt+Q');
  });
}
