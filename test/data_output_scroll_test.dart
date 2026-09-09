// 数据输出节点内部表格滚动回归测试:
// "有时候数据输出节点内部表格无法滚动" —— 在真实画布环境(节点卡片内)验证
// MiniTable 纵向滚动确实生效(滚动位置变化),且可双向拖动。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/main.dart';
import 'package:syphon_nov/models/presets.dart';
import 'package:syphon_nov/store/graph_store.dart';
import 'package:syphon_nov/ui/node_card.dart';

void main() {
  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const SyphonApp());
    await tester.pump();
  }

  testWidgets('数据输出节点内部表格可纵向滚动', (WidgetTester tester) async {
    GraphStore.useIsolate = false;
    addTearDown(() => GraphStore.useIsolate = true);

    await pumpApp(tester);
    final store = GraphStore.instance;
    store.loadGraph(kDemoGraphJson, silent: true);
    await tester.pump();
    // 数据输出节点 maxRows 调大,让表格内容必然溢出可视区
    final doNode = store.nodes.firstWhere((n) => n.configId == 'data_output');
    store.updateNodeParams(doNode.id, {'maxRows': 40});
    store.runPipeline();
    await tester.pump();
    await tester.pump();

    final doCard = find.byWidgetPredicate(
      (w) => w is NodeCard && w.nodeId == doNode.id,
    );
    expect(doCard, findsOneWidget);

    // 节点卡片内的纵向 Scrollable(内容溢出时 maxScrollExtent > 0)
    ScrollableState? scrollable;
    for (final s in tester.stateList<ScrollableState>(
      find.descendant(of: doCard, matching: find.byType(Scrollable)),
    )) {
      if (s.position.axis == Axis.vertical &&
          s.position.maxScrollExtent > 0) {
        scrollable = s;
        break;
      }
    }
    expect(scrollable, isNotNull, reason: '表格内容溢出时必须存在可滚动的纵向 Scrollable');
    final pos = scrollable!.position;
    expect(pos.maxScrollExtent, greaterThan(0), reason: '表格内容必须产生纵向溢出');

    // 拖动点:纵向 Scrollable 可视视口上部(表格本体远大于节点,
    // 表格自身 rect 的中心可能落在节点外的裁剪区域,不可直接使用)
    final box = scrollable.context.findRenderObject() as RenderBox;
    final vpRect = box.localToGlobal(Offset.zero) & box.size;
    // 取视口上部 1/4 处:避开被后绘制节点(viz_line 等)遮挡的下半区域
    final center = Offset(vpRect.center.dx, vpRect.top + vpRect.height * 0.25);

    // 向上拖 → 内容上移(scrollOffset 增大)
    final before = pos.pixels;
    final g1 = await tester.startGesture(center);
    await g1.moveBy(const Offset(0, -60));
    await tester.pump();
    await g1.moveBy(const Offset(0, -60));
    await tester.pump();
    await g1.up();
    await tester.pump();
    expect(pos.pixels, greaterThan(before), reason: '纵向拖动后滚动位置应增大');

    // 向下拖 → 滚动位置减小(可回滚)
    final mid = pos.pixels;
    final g2 = await tester.startGesture(center);
    await g2.moveBy(const Offset(0, 60));
    await tester.pump();
    await g2.moveBy(const Offset(0, 60));
    await tester.pump();
    await g2.up();
    await tester.pump();
    expect(pos.pixels, lessThan(mid), reason: '反向拖动后滚动位置应减小');
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
