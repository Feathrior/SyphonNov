import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/foundation.dart' show ValueKey;
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/material.dart'
    show AlertDialog, DecoratedBox, IgnorePointer, Key;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/main.dart';
import 'package:syphon_nov/store/graph_store.dart';
import 'package:syphon_nov/store/settings_store.dart';
import 'package:syphon_nov/ui/canvas_geometry.dart';
import 'package:syphon_nov/ui/context_menu.dart';
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

  test('Package exposes stable predecessor and successor interfaces', () {
    final store = GraphStore.instance;
    final source = store.addNode(
      'table_input',
      const Offset(0, 40),
      triggerRun: false,
    );
    final first = store.addNode(
      'extract_columns',
      const Offset(260, 40),
      triggerRun: false,
    );
    final last = store.addNode(
      'extract_rows',
      const Offset(520, 40),
      triggerRun: false,
    );
    final sink = store.addNode(
      'data_output',
      const Offset(780, 40),
      triggerRun: false,
    );
    store.onConnect(
      source: source,
      target: first,
      sourceHandle: 'out0',
      targetHandle: 'in0',
      triggerRun: false,
    );
    store.onConnect(
      source: first,
      target: last,
      sourceHandle: 'out0',
      targetHandle: 'in0',
      triggerRun: false,
    );
    store.onConnect(
      source: last,
      target: sink,
      sourceHandle: 'out0',
      targetHandle: 'in0',
      triggerRun: false,
    );

    final packageId = store.createPackage([first, last], '前后接口');
    final package = store.groups.singleWhere((group) => group.id == packageId);
    final inputs = packageInputPorts(package, store.nodes, store.edges);
    final outputs = packageOutputPorts(package, store.nodes, store.edges);
    expect(inputs, hasLength(1));
    expect(inputs.single.nodeId, first);
    expect(inputs.single.socketId, 'in0');
    expect(inputs.single.name, contains('提取列'));
    expect(outputs, hasLength(1));
    expect(outputs.single.nodeId, last);
    expect(outputs.single.socketId, 'out0');
    expect(outputs.single.name, contains('提取行'));
    expect(store.edges, hasLength(3));
  });

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
    IgnorePointer memberPointer(String nodeId) => tester.widget<IgnorePointer>(
      find.descendant(
        of: find.byKey(ValueKey('package-member-motion-$nodeId')),
        matching: find.byType(IgnorePointer),
      ),
    );
    expect(proxy, findsOneWidget);
    final overview = find.byKey(ValueKey('package-glass-overview-$packageId'));
    expect(overview, findsOneWidget);
    expect(
      find.descendant(of: overview, matching: find.byType(DecoratedBox)),
      findsNothing,
    );
    expect(find.byType(NodeCard), findsNWidgets(2));
    expect(memberPointer(first).ignoring, isTrue);
    expect(memberPointer(second).ignoring, isTrue);
    expect(
      find.byKey(ValueKey('package-input-label-$packageId')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('package-output-label-$packageId')),
      findsOneWidget,
    );
    expect(find.byKey(ValueKey('package-input-$second-in0')), findsOneWidget);
    expect(find.byKey(ValueKey('package-output-$first-out0')), findsOneWidget);
    final beforeExpansion = {
      for (final node in GraphStore.instance.nodes) node.id: node.position,
    };
    await tester.tap(find.byKey(ValueKey('package-toggle-$packageId')));
    await tester.pump();
    expect(proxy.hitTestable(), findsNothing);
    final duringExpansion = {
      for (final node in GraphStore.instance.nodes) node.id: node.position,
    };
    expect(
      (duringExpansion[first]! - duringExpansion[second]!).distance,
      lessThan((beforeExpansion[first]! - beforeExpansion[second]!).distance),
    );
    await tester.pumpAndSettle();
    final afterExpansion = {
      for (final node in GraphStore.instance.nodes) node.id: node.position,
    };
    expect(
      (afterExpansion[first]! - afterExpansion[second]!).distance,
      greaterThan(
        (duringExpansion[first]! - duringExpansion[second]!).distance,
      ),
    );
    expect(memberPointer(first).ignoring, isFalse);
    expect(memberPointer(second).ignoring, isFalse);
    expect(find.byKey(ValueKey('package-region-$packageId')), findsOneWidget);
    expect(
      find.byKey(ValueKey('package-toggle-expanded-$packageId')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(ValueKey('package-toggle-expanded-$packageId')),
    );
    await tester.pumpAndSettle();
    expect(proxy.hitTestable(), findsOneWidget);
    expect(memberPointer(first).ignoring, isTrue);
    expect(memberPointer(second).ignoring, isTrue);

    await tester.tapAt(tester.getCenter(proxy), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('保存到 Package 库'), findsOneWidget);
    expect(find.text('解散 Package'), findsOneWidget);
    expect(find.byType(NodeMenu), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('package-toggle-$packageId')));
    await tester.pump(const Duration(milliseconds: 32));
    expect(
      GraphStore.instance.groups
          .singleWhere((g) => g.id == packageId)
          .collapsed,
      isFalse,
    );
    await tester.tap(
      find.byKey(ValueKey('package-toggle-expanded-$packageId')),
    );
    await tester.pumpAndSettle();
    expect(
      GraphStore.instance.groups
          .singleWhere((g) => g.id == packageId)
          .collapsed,
      isTrue,
    );
    expect(proxy.hitTestable(), findsOneWidget);
  });

  testWidgets('Package creation dialog matches the About dialog style', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SettingsStore.instance.nodeMenuMode = NodeMenuMode.menu;
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
    GraphStore.instance.setMultiSelected({first, second});
    await tester.pumpWidget(const SyphonApp());
    await tester.pumpAndSettle();

    // 节点右键菜单里不再有"打包为 Package"
    final canvasRect = tester.getRect(find.byType(NodeCanvas));
    final firstCard = find.byWidgetPredicate(
      (widget) => widget is NodeCard && widget.nodeId == first,
    );
    await tester.tapAt(tester.getCenter(firstCard), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('打包为 Package'), findsNothing);
    expect(find.text('复制所选'), findsOneWidget);
    // 菜单层是全屏的,点菜单外任意处即关闭(不会连带清掉多选)
    await tester.tapAt(Offset(canvasRect.center.dx, canvasRect.top + 12));
    await tester.pumpAndSettle();
    expect(find.text('复制所选'), findsNothing);

    // 空白右键:新建节点菜单底部提供"打包为 Package"(选中 ≥2 个节点时)
    GraphStore.instance.setMultiSelected({first, second});
    await tester.pumpAndSettle();
    await tester.tapAt(
      Offset(canvasRect.center.dx, canvasRect.top + 12),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('打包为 Package'), findsOneWidget);
    await tester.tap(find.text('打包为 Package'));
    await tester.pumpAndSettle();

    // 与「帮助 → 关于 Syphon」一致:fluent ContentDialog + TextBox(不再是 AlertDialog)
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(fluent.ContentDialog), findsOneWidget);
    expect(find.text('创建 Package'), findsOneWidget);
    final box = find.descendant(
      of: find.byType(fluent.ContentDialog),
      matching: find.byType(fluent.TextBox),
    );
    expect(box, findsOneWidget);
    final textBox = tester.widget<fluent.TextBox>(box);
    expect(textBox.autofocus, isTrue);
    expect(textBox.maxLines, 1, reason: '正常单行输入框,不能被对话框撑高');
    // 输入框高度必须接近单行控件高度(此前会被对话框拉成几百像素的大白框)
    expect(tester.getSize(box).height, lessThan(64));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(fluent.ContentDialog), findsNothing);
    // 取消后不应建出 Package
    expect(GraphStore.instance.groups, isEmpty);
  });

  testWidgets('collapsed Package follows the pointer during drag', (
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
    ], '可拖动区域');
    await tester.pumpWidget(const SyphonApp());
    await tester.pumpAndSettle();

    final proxy = find.byKey(ValueKey('package-node-$packageId'));
    final before = tester.getTopLeft(proxy);
    final gesture = await tester.startGesture(tester.getCenter(proxy));
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(60, 35));
    await tester.pump();
    final during = tester.getTopLeft(proxy);
    expect(during.dx, closeTo(before.dx + 60, 1));
    expect(during.dy, closeTo(before.dy + 35, 1));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(proxy), during);
  });

  testWidgets('saved Package can be dragged out of the shelf onto the canvas', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SettingsStore.instance.nodeShelfEnabled = true;
    final store = GraphStore.instance;
    final first = store.addNode(
      'table_input',
      const Offset(120, 90),
      triggerRun: false,
    );
    final second = store.addNode(
      'table_to_scatter',
      const Offset(440, 90),
      triggerRun: false,
    );
    final packaged = store.createPackage([first, second], '拖拽包');
    final template = store.packageTemplate(packaged!)!;
    store.clearAll();
    SettingsStore.instance.packageLibrary = [template];

    await tester.pumpWidget(const SyphonApp());
    await tester.pumpAndSettle();
    expect(store.nodes, isEmpty);

    // 悬停 Package 胶囊打开库
    final pointer = TestPointer(77, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(
        tester.getCenter(find.byKey(const Key('node-category-package'))),
      ),
    );
    await tester.pumpAndSettle();
    final tile = find.byKey(ValueKey('package-spine-${template['id']}'));
    expect(tile, findsOneWidget);

    // 从节点条拖到画布中央:拖动中有跟随的指示环,松手后落地成折叠 Package
    final canvasRect = tester.getRect(find.byType(NodeCanvas));
    final drop = canvasRect.center;
    final start = tester.getCenter(tile);
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    // 分几步移动:真实拖拽会持续上报指针位置
    await gesture.moveTo(start + const Offset(0, 60));
    await tester.pump();
    await gesture.moveTo(drop);
    await tester.pump();
    await gesture.moveTo(drop + const Offset(1, 1));
    await tester.pump();
    expect(find.byKey(const Key('node-drag-dot')), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(store.groups.where((g) => g.name == '拖拽包'), hasLength(1));
    final created = store.groups.first;
    expect(created.collapsed, isTrue);
    expect(created.nodeIds, hasLength(2));
    expect(store.nodes, hasLength(2));
    // 落点即指针位置:折叠代理中心贴在松手处附近
    final proxy = find.byKey(ValueKey('package-node-${created.id}'));
    expect(
      (tester.getCenter(proxy) - drop).distance,
      lessThan(40),
      reason: 'Package 应落在指针松手的位置',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('nodes created inside an expanded Package join it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SettingsStore.instance.nodeShelfEnabled = false;
    SettingsStore.instance.nodeMenuMode = NodeMenuMode.menu;
    final store = GraphStore.instance;
    final first = store.addNode(
      'table_input',
      const Offset(80, 60),
      triggerRun: false,
    );
    final second = store.addNode(
      'table_to_scatter',
      const Offset(340, 60),
      triggerRun: false,
    );
    final packageId = store.createPackage([first, second], '包内新建')!;
    await tester.pumpWidget(const SyphonApp());
    await tester.pumpAndSettle();
    // 展开
    await tester.tap(find.byKey(ValueKey('package-toggle-$packageId')));
    await tester.pumpAndSettle();

    final region = tester.getRect(
      find.byKey(ValueKey('package-region-$packageId')),
    );
    // 区域内部空白:右键 = 新建节点菜单,且 Package 自身选项附在下方
    final inside = Offset(region.center.dx, region.top + 40);
    await tester.tapAt(inside, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    final menu = find.byType(NodeMenu);
    expect(menu, findsOneWidget, reason: '包内应能呼出新建节点菜单');
    expect(
      find.text('收起 Package'),
      findsOneWidget,
      reason: 'Package 自身选项要附在新建节点菜单下方',
    );
    expect(find.text('保存到 Package 库'), findsOneWidget);
    expect(find.text('解散 Package'), findsOneWidget);

    final before = store.nodes.length;
    await tester.tap(find.text('表格输入').last);
    await tester.pumpAndSettle();
    expect(store.nodes.length, before + 1);
    final created = store.selectedId!;
    final group = store.groups.singleWhere((g) => g.id == packageId);
    expect(
      group.nodeIds,
      contains(created),
      reason: '在 Package 内部新建的节点应并入该 Package',
    );

    // 包内任意位置右键都带 Package 选项(不再是"只有边框一圈"):
    // 取区域底部内边距(不在任何成员节点上)
    final grown = tester.getRect(
      find.byKey(ValueKey('package-region-$packageId')),
    );
    await tester.tapAt(
      Offset(grown.center.dx, grown.bottom - 6),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    expect(find.byType(NodeMenu), findsOneWidget);
    expect(find.text('收起 Package'), findsOneWidget);
    await tester.tapAt(const Offset(4, 400));
    await tester.pumpAndSettle();
  });

  testWidgets('a node dragged from the shelf into an expanded Package joins it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SettingsStore.instance.nodeShelfEnabled = true;
    final store = GraphStore.instance;
    final first = store.addNode(
      'table_input',
      const Offset(80, 60),
      triggerRun: false,
    );
    final second = store.addNode(
      'table_to_scatter',
      const Offset(340, 60),
      triggerRun: false,
    );
    final packageId = store.createPackage([first, second], '拖入')!;
    await tester.pumpWidget(const SyphonApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('package-toggle-$packageId')));
    await tester.pumpAndSettle();

    final region = tester.getRect(
      find.byKey(ValueKey('package-region-$packageId')),
    );
    final dropInside = Offset(region.center.dx, region.top + 60);
    final state = tester.state<NodeCanvasState>(find.byType(NodeCanvas));
    final before = store.nodes.length;
    // 上方栏拖出的光点落进 Package:新节点并入该 Package
    expect(state.addNodeFromGlobal('axis_input', dropInside), isTrue);
    await tester.pumpAndSettle();
    expect(store.nodes.length, before + 1);
    final created = store.selectedId!;
    expect(
      store.groups.singleWhere((g) => g.id == packageId).nodeIds,
      contains(created),
    );

    // 落在 Package 外面的节点不并入
    final outside = Offset(region.right + 60, region.bottom + 60);
    expect(state.addNodeFromGlobal('axis_input', outside), isTrue);
    await tester.pumpAndSettle();
    expect(
      store.groups.singleWhere((g) => g.id == packageId).nodeIds,
      isNot(contains(store.selectedId)),
    );
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
