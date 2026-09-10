import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/main.dart';
import 'package:syphon_nov/store/graph_store.dart';
import 'package:syphon_nov/store/settings_store.dart';
import 'package:syphon_nov/ui/context_menu.dart';
import 'package:syphon_nov/ui/node_canvas.dart';
import 'package:syphon_nov/ui/radial_node_menu.dart';

void main() {
  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const SyphonApp());
    await tester.pump();
  }

  setUp(() {
    GraphStore.useIsolate = false;
    GraphStore.instance.clearAll();
    SettingsStore.instance.nodeShelfEnabled = true;
    SettingsStore.instance.contextNodeMenuEnabled = true;
    SettingsStore.instance.radialNodeMenuEnabled = true;
    SettingsStore.instance.packageLibrary = [];
  });

  tearDown(() {
    GraphStore.instance.clearAll();
    GraphStore.useIsolate = true;
  });

  test('radial hit testing has a dead zone and six stable directions', () {
    expect(radialSectionIndex(Offset.zero), isNull);
    expect(radialSectionIndex(const Offset(0, -60)), 0);
    expect(radialSectionIndex(const Offset(60, -20)), 1);
    expect(radialSectionIndex(const Offset(60, 35)), 2);
    expect(radialSectionIndex(const Offset(0, 60)), 3);
    expect(radialSectionIndex(const Offset(-60, 35)), 4);
    expect(radialSectionIndex(const Offset(-60, -20)), 5);
  });

  test(
    'detail hit testing activates at the color ring and clamps its item',
    () {
      expect(radialDetailIndex(const Offset(0, -30), 0, 5), isNull);
      expect(radialDetailIndex(const Offset(0, -60), 0, 5), 2);
      expect(radialDetailIndex(const Offset(0, -120), 0, 0), isNull);
    },
  );

  testWidgets('quick secondary click uses the traditional node menu', (
    tester,
  ) async {
    await pumpApp(tester);
    final center = tester.getCenter(find.byType(NodeCanvas));
    await tester.tapAt(center, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.byType(NodeMenu), findsOneWidget);
    expect(find.byKey(const Key('radial-node-menu')), findsNothing);
  });

  testWidgets('hold without touching the ring closes without creating', (
    tester,
  ) async {
    await pumpApp(tester);
    final center = tester.getCenter(find.byType(NodeCanvas));
    final gesture = await tester.startGesture(
      center,
      buttons: kSecondaryButton,
    );
    await tester.pump(const Duration(milliseconds: 180));
    expect(find.byKey(const Key('radial-node-menu')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      tester.getRect(find.byKey(const Key('radial-node-menu'))).center,
      within(distance: 1, from: center),
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('radial-node-menu')), findsNothing);
    expect(find.byType(NodeMenu), findsNothing);
    expect(GraphStore.instance.nodes, isEmpty);
  });

  testWidgets('outward radial gesture creates a dot-selected node', (
    tester,
  ) async {
    await pumpApp(tester);
    final center = tester.getCenter(find.byType(NodeCanvas));
    final gesture = await tester.startGesture(
      center,
      buttons: kSecondaryButton,
    );
    await gesture.moveBy(const Offset(0, -180));
    await tester.pump();
    expect(find.byKey(const Key('radial-node-menu')), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(GraphStore.instance.nodes, hasLength(1));
    expect(find.byKey(const Key('radial-node-menu')), findsNothing);
  });

  testWidgets('node type locks at the ring detachment point', (tester) async {
    await pumpApp(tester);
    final center = tester.getCenter(find.byType(NodeCanvas));
    final inputItems = radialItemsFor(RadialNodeSection.input, const []);
    final initialDelta = const Offset(0, -130);
    final expectedIndex = radialDetailIndex(
      initialDelta,
      0,
      inputItems.length,
    )!;
    final gesture = await tester.startGesture(
      center,
      buttons: kSecondaryButton,
    );
    await gesture.moveBy(initialDelta);
    await tester.pump();
    await gesture.moveBy(const Offset(200, 100));
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      GraphStore.instance.nodes.single.configId,
      inputItems[expectedIndex].id,
    );
  });

  testWidgets('node shelf can be hidden independently', (tester) async {
    SettingsStore.instance.nodeShelfEnabled = false;
    await pumpApp(tester);
    expect(find.byKey(const Key('node-shelf')), findsNothing);
  });
}
