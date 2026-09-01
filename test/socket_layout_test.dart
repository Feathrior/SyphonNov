// 端口行布局回归测试:渲染行间距必须与几何计算(_rows 的 socketGap)一致。
// 修复前渲染端漏了行间距,导致曲线锚点/命中区逐行比 handle 实际位置偏下
// (接口越多偏移越大,表现为"曲线结束点与接口位置偏移")。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/store/graph_store.dart';
import 'package:syphon_nov/ui/canvas_geometry.dart';
import 'package:syphon_nov/ui/node_card.dart';

void main() {
  Future<void> pumpNode(WidgetTester tester) async {
    final store = GraphStore.instance;
    store.nodes = [
      GraphNode(
        id: 'n1',
        configId: 'viz_line',
        params: const {'xCol': '', 'yCol': '', 'title': ''},
        position: const Offset(40, 40),
      ),
    ];
    store.edges = [];
    store.groups = [];
    store.results = {};
    final hovers = ValueNotifier<SocketHovers>((active: null, hover: null));
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasZoom(
          notifier: ValueNotifier(1.0),
          child: CanvasSockets(
            notifier: hovers,
            child: NodeCard(
              nodeId: 'n1',
              callbacks: NodeCardCallbacks(
                onSelect: (_) {},
                onSecondaryTap: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('端口行间距与几何 socketGap 一致', (tester) async {
    await pumpNode(tester);
    // viz_line 输入依次:表格 / 点(散点·可多连) / 线(曲线·可多连) / 面(网格·可多连) / 文本(可多连)
    final y1 = tester.getTopLeft(find.text('点(散点·可多连)')).dy;
    final y2 = tester.getTopLeft(find.text('线(曲线·可多连)')).dy;
    final y3 = tester.getTopLeft(find.text('面(网格·可多连)')).dy;
    // 每行间距 = 行高(单连线 18)+ socketGap(5),与 _rows 几何累计一致
    final expected = rowH(0) + NodeGeom.socketGap;
    expect(y2 - y1, closeTo(expected, 0.01));
    expect(y3 - y2, closeTo(expected, 0.01));
    // 首行起点也与几何一致(headerH + bodyPadTop,文本行内居中故略大于 36)
    final y0 = tester.getTopLeft(find.text('表格').first).dy;
    expect(y0, greaterThanOrEqualTo(NodeGeom.headerH + NodeGeom.bodyPadTop));
    expect(y0, lessThanOrEqualTo(NodeGeom.headerH + NodeGeom.bodyPadTop + 6));
  });
}
