import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/main.dart';
import 'package:syphon_nov/models/data.dart' show Category;
import 'package:syphon_nov/models/registry.dart';
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
    SettingsStore.instance.packageLibrary = [];
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
    final spine = find.byKey(const ValueKey('node-spine-derivative'));
    expect(spine, findsOneWidget);
    expect(
      tester.getSize(spine).height,
      greaterThan(tester.getSize(spine).width),
    );
  });

  testWidgets('short categories size to their spines and labels stay upright', (
    tester,
  ) async {
    await pumpApp(tester);
    final pointer = TestPointer(32, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(tester.getCenter(find.text('数据初步'))),
    );
    await tester.pump();
    final overlay = find.byKey(const Key('node-library-overlay'));
    expect(overlay, findsOneWidget);
    expect(tester.getSize(overlay).width, lessThan(360));
    expect(
      find.descendant(of: overlay, matching: find.byType(RotatedBox)),
      findsNothing,
    );
    final verticalLabels = tester
        .widgetList<Text>(
          find.descendant(of: overlay, matching: find.byType(Text)),
        )
        .where((text) => (text.data ?? '').contains('\n'));
    expect(verticalLabels, isNotEmpty);
  });

  testWidgets(
    'category changes animate the shelf width and preserve fixed order',
    (tester) async {
      final cleanNodes = kNodeConfigs
          .where((config) => config.category == Category.clean)
          .toList();
      expect(cleanNodes.length, greaterThan(1));
      SettingsStore.instance.favoriteNodeIds = [cleanNodes[1].id];
      SettingsStore.instance.recentNodeIds = [cleanNodes[1].id];
      await pumpApp(tester);
      final pointer = TestPointer(33, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        pointer.hover(tester.getCenter(find.text('数据初步'))),
      );
      await tester.pumpAndSettle();
      final sizeTransition = find.byKey(
        const Key('node-library-size-transition'),
      );
      final initialWidth = tester.getSize(sizeTransition).width;
      expect(
        tester
            .getCenter(find.byKey(ValueKey('node-spine-${cleanNodes[0].id}')))
            .dx,
        lessThan(
          tester
              .getCenter(find.byKey(ValueKey('node-spine-${cleanNodes[1].id}')))
              .dx,
        ),
      );

      await tester.sendEventToBinding(
        pointer.hover(tester.getCenter(find.text('数据可视化'))),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      final middleWidth = tester.getSize(sizeTransition).width;
      expect(
        find.descendant(
          of: find.byKey(const Key('node-library-overlay')),
          matching: find.byType(ImageFiltered),
        ),
        findsNothing,
      );
      await tester.pumpAndSettle();
      final finalWidth = tester.getSize(sizeTransition).width;
      expect(middleWidth, greaterThan(initialWidth));
      expect(middleWidth, lessThan(finalWidth));
      expect(
        tester.widget<AnimatedContainer>(sizeTransition).duration,
        const Duration(milliseconds: 640),
      );
      expect(
        tester
            .widget<AnimatedSwitcher>(
              find.byKey(const Key('node-library-content-transition')),
            )
            .duration,
        const Duration(milliseconds: 460),
      );
    },
  );

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

  testWidgets('full motion uses the relaxed interaction timing', (
    tester,
  ) async {
    await pumpApp(tester);
    final shelf = tester.element(find.byKey(const Key('node-shelf')));
    // 基础节奏 110/230/320,再乘以全局节奏倍率(回弹整体放慢一倍)
    expect(MotionTokens.pacing, 2);
    expect(MotionTokens.quick(shelf), const Duration(milliseconds: 220));
    expect(MotionTokens.standard(shelf), const Duration(milliseconds: 460));
    expect(MotionTokens.spatial(shelf), const Duration(milliseconds: 640));
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
