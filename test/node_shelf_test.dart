import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/main.dart';
import 'package:syphon_nov/store/graph_store.dart';
import 'package:syphon_nov/store/settings_store.dart';
import 'package:syphon_nov/ui/node_canvas.dart';
import 'package:syphon_nov/ui/motion.dart';
import 'package:syphon_nov/ui/theme.dart';

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
    SettingsStore.instance.motionMode = MotionMode.full;
    SettingsStore.instance.snapNodePlacement = false;
    SettingsStore.instance.favoriteNodeIds = [];
    SettingsStore.instance.recentNodeIds = [];
  });

  tearDown(() {
    GraphStore.instance.clearAll();
    GraphStore.useIsolate = true;
  });

  testWidgets('five-category shelf keeps a fixed collapsed height', (
    tester,
  ) async {
    await pumpApp(tester);
    final shelf = find.byKey(const Key('node-shelf'));
    expect(shelf, findsOneWidget);
    expect(tester.getSize(shelf).height, SyphonDims.nodeShelfH);
    for (final label in ['组输入', '数据初步', '数据运算', '数据转化', '数据可视化']) {
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('hover opens the selected category without duplicate filters', (
    tester,
  ) async {
    await pumpApp(tester);
    final pointer = TestPointer(31, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(tester.getCenter(find.text('数据运算'))),
    );
    await tester.pump();
    expect(find.byKey(const Key('node-library-overlay')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('node-shelf'))).height,
      SyphonDims.nodeShelfH,
    );

    expect(find.byKey(const Key('node-shelf-search')), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('func_curve'), findsNothing);
    expect(find.text('table_input'), findsNothing);
  });

  testWidgets('canvas accepts one global drop and rejects outside release', (
    tester,
  ) async {
    await pumpApp(tester);
    final canvasFinder = find.byType(NodeCanvas);
    final state = tester.state<NodeCanvasState>(canvasFinder);
    final center = tester.getCenter(canvasFinder);

    expect(state.addNodeFromGlobal('func_curve', center), isTrue);
    expect(GraphStore.instance.nodes, hasLength(1));
    expect(GraphStore.instance.nodes.single.configId, 'func_curve');

    expect(
      state.addNodeFromGlobal('table_input', const Offset(-50, -50)),
      isFalse,
    );
    expect(GraphStore.instance.nodes, hasLength(1));
  });

  testWidgets('disabled motion resolves token durations to zero', (
    tester,
  ) async {
    SettingsStore.instance.motionMode = MotionMode.off;
    await pumpApp(tester);
    final shelf = tester.element(find.byKey(const Key('node-shelf')));
    expect(MediaQuery.maybeOf(shelf), isNotNull);
    expect(MotionTokens.standard(shelf), Duration.zero);
  });

  for (final scale in [1.0, 1.25, 1.5]) {
    testWidgets('shelf and edge placement remain valid at ${scale}x DPI', (
      tester,
    ) async {
      tester.view.physicalSize = Size(1440 * scale, 900 * scale);
      tester.view.devicePixelRatio = scale;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const SyphonApp());
      await tester.pump();

      expect(tester.getSize(find.byKey(const Key('node-shelf'))).height, 42);
      final canvas = find.byType(NodeCanvas);
      final state = tester.state<NodeCanvasState>(canvas);
      final rect = tester.getRect(canvas);
      expect(
        state.addNodeFromGlobal(
          'func_curve',
          rect.bottomRight - const Offset(2, 2),
        ),
        isTrue,
      );
      final node = GraphStore.instance.nodes.single;
      expect(node.position.dx, lessThan(rect.width - 100));
      expect(node.position.dy, lessThan(rect.height - 80));
    });
  }
}
