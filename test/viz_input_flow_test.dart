// 可视化节点图元输入数据流验证:点/线/面/文本(含多路)应能经执行引擎
// 送达可视化节点(results.inputs / multiInputs),供 ChartPainter 叠加渲染。
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/models/data.dart' as md;
import 'package:syphon_nov/models/exec_engine.dart';

void main() {
  test('可视化节点接收点/文本输入(含多路合并)', () {
    final nodes = [
      GraphNodeLite(
        id: 'pts1',
        configId: 'scatter_input',
        params: {
          'name': '点1',
          'points': [
            {'x': 0, 'y': 0, 'size': 4, 'shape': 'circle', 'color': '#1f77b4'},
          ],
        },
      ),
      GraphNodeLite(
        id: 'pts2',
        configId: 'scatter_input',
        params: {
          'name': '点2',
          'points': [
            {'x': 1, 'y': 1, 'size': 5, 'shape': 'square', 'color': '#ff7f0e'},
          ],
        },
      ),
      GraphNodeLite(
        id: 'txt',
        configId: 'text_input',
        params: {
          'text': '图例',
          'fontSize': 3,
          'halign': 'center',
          'valign': 'top',
          'bgColor': '',
          'textColor': '#333333',
          'fontFamily': 'sans-serif',
        },
      ),
      GraphNodeLite(
        id: 'viz',
        configId: 'viz_bar',
        params: {'xCol': '', 'yCol': '', 'title': ''},
      ),
    ];
    final edges = [
      GraphEdgeLite(
        source: 'pts1',
        target: 'viz',
        sourceHandle: 'out0',
        targetHandle: 'in_pts',
      ),
      GraphEdgeLite(
        source: 'pts2',
        target: 'viz',
        sourceHandle: 'out0',
        targetHandle: 'in_pts',
      ),
      GraphEdgeLite(
        source: 'txt',
        target: 'viz',
        sourceHandle: 'out0',
        targetHandle: 'in_texts',
      ),
    ];
    final out = runGraph(nodes, edges);
    expect(out.hasCycle, isFalse);
    final viz = out.results['viz']!;
    expect(viz.error, isNull);
    // 单路:inputs 携带一个对象
    expect(viz.inputs['in_pts'], isA<md.ScatterData>());
    expect(viz.inputs['in_texts'], isA<md.TextData>());
    // 多路:multiInputs 聚合全部上游
    final multi = viz.multiInputs['in_pts']!;
    expect(multi.length, 2);
    expect(multi.every((o) => o is md.ScatterData), isTrue);
  });

  test('无 exec 的可视化节点仅透传输入,不产生输出错误', () {
    final nodes = [
      GraphNodeLite(
        id: 'viz',
        configId: 'viz_line',
        params: {'xCol': '', 'yCol': '', 'title': ''},
      ),
    ];
    final out = runGraph(nodes, const []);
    expect(out.results['viz']!.error, isNull);
    expect(out.results['viz']!.inputs, isEmpty);
  });
}
