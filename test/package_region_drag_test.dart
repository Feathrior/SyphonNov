import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/main.dart';
import 'package:syphon_nov/models/exec_engine.dart';
import 'package:syphon_nov/store/graph_store.dart';
import 'package:syphon_nov/store/settings_store.dart';
import 'package:syphon_nov/ui/canvas_geometry.dart';
import 'package:syphon_nov/ui/node_canvas.dart';
import 'package:syphon_nov/ui/node_card.dart';

void main() {
  setUp(() {
    GraphStore.useIsolate = false;
    GraphStore.instance.clearAll();
    SettingsStore.instance.nodeShelfEnabled = true;
    SettingsStore.instance.motionSpeed = MotionSpeed.fast;
    SettingsStore.instance.nodeMenuMode = NodeMenuMode.both;
    SettingsStore.instance.packageLibrary = [];
  });

  tearDown(() {
    GraphStore.instance.clearAll();
    GraphStore.useIsolate = true;
  });

  /// 先启动再建图:画布保持 zoom=1 / pan=0,几何断言才可精确换算
  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const SyphonApp());
    await tester.pump();
  }

  /// 两个节点打包成折叠 Package
  String buildPackage() {
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
    return GraphStore.instance.createPackage([first, second], '区域测试')!;
  }

  Future<void> expand(WidgetTester tester, String packageId) async {
    await tester.tap(find.byKey(ValueKey('package-toggle-$packageId')));
    await tester.pumpAndSettle();
  }

  testWidgets('expanded package region follows node error height', (
    tester,
  ) async {
    await pumpApp(tester);
    final packageId = buildPackage();
    await tester.pumpAndSettle();
    await expand(tester, packageId);

    final region = find.byKey(ValueKey('package-region-$packageId'));
    final before = tester.getSize(region);

    // 给"底边最低"的成员加错误 → 内容高度正好增加底部红色区域(30)
    final store = GraphStore.instance;
    GraphNode? lowest;
    for (final node in store.nodes) {
      final bottom =
          node.position.dy + nodeSize(node, store.edges).height;
      if (lowest == null ||
          bottom >
              lowest.position.dy + nodeSize(lowest, store.edges).height) {
        lowest = node;
      }
    }
    store.results[lowest!.id] = ExecResult(error: '区域跟随测试');
    store.touch();
    await tester.pumpAndSettle();

    final after = tester.getSize(region);
    expect(after.height - before.height, closeTo(30, 1));
  });

  testWidgets('expanded package can be dragged from its region frame', (
    tester,
  ) async {
    await pumpApp(tester);
    final packageId = buildPackage();
    await tester.pumpAndSettle();
    await expand(tester, packageId);

    final region = find.byKey(ValueKey('package-region-$packageId'));
    final rect = tester.getRect(region);
    // 抓区域底部内边距(不在任何成员节点上)
    final grab = Offset(rect.center.dx, rect.bottom - 6);
    final before = {
      for (final n in GraphStore.instance.nodes) n.id: n.position,
    };
    final gesture = await tester.startGesture(grab);
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    final after = {
      for (final n in GraphStore.instance.nodes) n.id: n.position,
    };
    for (final id in before.keys) {
      expect(after[id]!.dy, closeTo(before[id]!.dy - 100, 1));
    }
  });

  testWidgets('package context menu collapses an expanded package', (
    tester,
  ) async {
    await pumpApp(tester);
    final packageId = buildPackage();
    await tester.pumpAndSettle();
    await expand(tester, packageId);

    final region = find.byKey(ValueKey('package-region-$packageId'));
    // 区域底边本身是开区间(contains 不含下边界),向内 4px 落在内边距上
    final target = tester.getRect(region).bottomCenter - const Offset(0, 4);
    await tester.tapAt(target, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('收起 Package'), findsOneWidget);

    await tester.tap(find.text('收起 Package'));
    await tester.pumpAndSettle();
    expect(
      GraphStore.instance.groups
          .singleWhere((g) => g.id == packageId)
          .collapsed,
      isTrue,
    );
  });

  testWidgets('new node grows out of the drag ring position', (tester) async {
    await pumpApp(tester);
    final canvas = find.byType(NodeCanvas);
    final drop = tester.getRect(canvas).center;
    final state = tester.state<NodeCanvasState>(canvas);
    expect(state.addNodeFromGlobal('table_input', drop), isTrue);

    // 第一帧:入场动画起点,卡片仍很小且贴着投放点(指示环位置)
    await tester.pump();
    final id = GraphStore.instance.nodes.single.id;
    final card = find.byWidgetPredicate((w) => w is NodeCard && w.nodeId == id);
    expect(card, findsOneWidget);
    final start = tester.getRect(card);
    await tester.pumpAndSettle();
    final settled = tester.getRect(card);
    expect(start.width, lessThan(settled.width * .4));
    expect((start.topLeft - drop).distance, lessThan(24));
  });

  testWidgets('shelf drag feedback is a pointer-centred ring', (tester) async {
    await pumpApp(tester);
    final pointer = TestPointer(41, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(tester.getCenter(find.text('数据运算'))),
    );
    await tester.pumpAndSettle();

    final spine = find.byKey(const ValueKey('node-spine-derivative'));
    expect(spine, findsOneWidget);
    final start = tester.getCenter(spine);
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, 240));
    await tester.pump();

    final ring = find.byKey(const Key('node-drag-dot'));
    expect(ring, findsOneWidget);
    expect(tester.getSize(ring), const Size(52, 52));
    // 指示环以指针为中心(与右键圆环拖出的圆球一致)
    expect(
      (tester.getRect(ring).center - (start + const Offset(0, 240))).distance,
      lessThan(1),
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('shelf overlay picking never throws', (tester) async {
    await pumpApp(tester);
    expect(find.byKey(const Key('node-shelf')), findsOneWidget);
    final pills = ['组输入', '数据初步', '数据运算', '数据转化', '数据可视化'];
    for (var round = 0; round < 6; round++) {
      await tester.tap(find.text(pills[round % pills.length]));
      await tester.pump(const Duration(milliseconds: 40));
      final tiles = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('node-spine-'),
      );
      if (tiles.evaluate().isNotEmpty) {
        await tester.tap(tiles.first, warnIfMissed: false);
      }
      await tester.pump(const Duration(milliseconds: 30));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
