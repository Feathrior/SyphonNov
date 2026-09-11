// 数据输出节点:真实 FluentApp 环境下滚轮 + 滚动条拇指拖拽回归测试。
// 复现用户反馈:表格多行时滚动条无法拖动、滚轮不响应。
// 注:演示图里数据输出节点会被其他节点遮挡,故先把节点挪到空白区再测。
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
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

  testWidgets('数据输出表格:滚轮与滚动条拇指均可操作', (WidgetTester tester) async {
    GraphStore.useIsolate = false;
    addTearDown(() => GraphStore.useIsolate = true);

    await pumpApp(tester);
    final store = GraphStore.instance;
    store.loadGraph(kDemoGraphJson, silent: true);
    await tester.pump();
    final doNode = store.nodes.firstWhere((n) => n.configId == 'data_output');
    // 挪到空白区,排除演示图其他节点的遮挡
    // v0.4.3 顶部节点条占用固定高度，测试节点上移以完整露出滚动条。
    store.moveNode(doNode.id, const Offset(120, 40));
    store.updateNodeParams(doNode.id, {'maxRows': 60});
    store.runPipeline();
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    final doCard = find.byWidgetPredicate(
      (w) => w is NodeCard && w.nodeId == doNode.id,
    );
    expect(doCard, findsOneWidget);

    ScrollableState? vertical;
    for (final s in tester.stateList<ScrollableState>(
      find.descendant(of: doCard, matching: find.byType(Scrollable)),
    )) {
      if (vertical == null &&
          s.position.axis == Axis.vertical &&
          s.position.maxScrollExtent > 0) {
        vertical = s;
      }
    }
    expect(vertical, isNotNull);
    final pos = vertical!.position;
    final box = vertical.context.findRenderObject() as RenderBox;
    final vp = box.localToGlobal(Offset.zero) & box.size;

    // ---- 1. 滚轮:正 dy 向前滚动(pixels+delta) ----
    final probe = Offset(vp.center.dx, vp.top + vp.height * 0.15);
    final tp = TestPointer(1, PointerDeviceKind.mouse);
    tp.hover(probe);
    final before = pos.pixels;
    await tester.sendEventToBinding(tp.scroll(const Offset(0, 240)));
    await tester.pump();
    final afterWheel = pos.pixels;
    expect(
      afterWheel,
      greaterThan(before),
      reason: '滚轮应使表格滚动,实际 before=$before after=$afterWheel',
    );

    // ---- 2. 滚动条拇指拖拽(自绘:宽10、上下留白2、最小拇指24) ----
    pos.jumpTo(40);
    await tester.pump();
    final trackH = vp.height - 4;
    final rawThumbH = trackH * (vp.height / (vp.height + pos.maxScrollExtent));
    final thumbH = rawThumbH.clamp(24.0, trackH);
    final thumbTopLocal =
        2 + (pos.pixels / pos.maxScrollExtent) * (trackH - thumbH);
    final thumbX = vp.right - 5; // 条宽10 → 中心
    final thumbY = vp.top + thumbTopLocal + 8;
    final midPixels = pos.pixels;
    final g = await tester.startGesture(Offset(thumbX, thumbY));
    await tester.pump(const Duration(milliseconds: 16));
    await g.moveBy(const Offset(0, 60)); // 向下拖 → 滚动位置增大
    await tester.pump();
    await g.up();
    await tester.pump();
    final afterDrag = pos.pixels;
    expect(
      afterDrag,
      greaterThan(midPixels),
      reason: '向下拖拇指应增大滚动位置,实际 mid=$midPixels after=$afterDrag',
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
