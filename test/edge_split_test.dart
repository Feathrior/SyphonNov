// Alt 断点(连线 mid 分割点)的选择/删除回归测试。
// 修复前 updateEdgeData(id, null) 经过 copyWith 时被当作"保持旧值",
// 断点永远删不掉(deleteSelection 空操作)。
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/store/graph_store.dart';

void main() {
  test('updateEdgeData 清除断点', () {
    final store = GraphStore.instance;
    store.nodes = [
      GraphNode(
        id: 'n1',
        configId: 'table_input',
        params: const {},
        position: const Offset(0, 0),
      ),
      GraphNode(
        id: 'n2',
        configId: 'viz_scatter',
        params: const {'xCol': '', 'yCol': '', 'title': ''},
        position: const Offset(200, 0),
      ),
    ];
    store.edges = [
      const GraphEdge(
        id: 'e1',
        source: 'n1',
        target: 'n2',
        targetHandle: 'in0',
        mid: Offset(100, 100),
      ),
    ];
    store.groups = [];
    store.results = {};

    // 先确认有断点
    expect(store.edges.first.mid, const Offset(100, 100));

    // Alt 创建/拖动断点:传坐标
    store.updateEdgeData('e1', const Offset(120, 80));
    expect(store.edges.first.mid, const Offset(120, 80));

    // 删除断点:传 null 必须真正清除(之前是空操作)
    store.updateEdgeData('e1', null);
    expect(store.edges.first.mid, isNull);
  });
}
