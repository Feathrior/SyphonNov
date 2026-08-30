// 自动执行回归测试:参数改动(updateNodeParams)在 autoRun 开启时应自动重算。
// 修复前参数修改只刷新 UI 不执行,导致"原理化输出等图参数改了没反应"。
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/store/graph_store.dart';

void main() {
  GraphStore buildStore(Map<String, dynamic> params) {
    final store = GraphStore.instance;
    store.nodes = [
      GraphNode(
        id: 'n1',
        configId: 'table_input',
        params: params,
        position: const Offset(0, 0),
      ),
    ];
    store.edges = [];
    store.groups = [];
    store.results = {};
    store.autoRun = true;
    return store;
  }

  test('updateNodeParams 在自动执行开启时重新计算 results', () {
    final store = buildStore({'mode': 'preset', 'preset': 'volcano'});
    expect(store.results.containsKey('n1'), isFalse);
    store.updateNodeParams('n1', {'preset': 'sales'});
    expect(store.results.containsKey('n1'), isTrue);
    final table = store.results['n1']!.outputs['out0'];
    expect(table, isNotNull);
  });

  test('updateNodeParams 在自动执行关闭时不执行', () {
    final store = buildStore({'mode': 'preset', 'preset': 'volcano'});
    store.autoRun = false;
    store.updateNodeParams('n1', {'preset': 'sales'});
    expect(store.results.containsKey('n1'), isFalse);
  });

  // 构造:表格输入 n0 → 柱状图 v1;autoRun 开启
  GraphStore buildPipeline() {
    final store = GraphStore.instance;
    store.nodes = [
      GraphNode(
        id: 'n0',
        configId: 'table_input',
        params: const {'mode': 'preset', 'preset': 'volcano'},
        position: const Offset(0, 0),
      ),
      GraphNode(
        id: 'v1',
        configId: 'viz_bar',
        params: const {'xCol': '', 'yCol': '', 'title': ''},
        position: const Offset(300, 0),
      ),
    ];
    store.edges = [
      GraphEdge(
        id: 'e1',
        source: 'n0',
        target: 'v1',
        sourceHandle: 'out0',
        targetHandle: 'in0',
      ),
    ];
    store.groups = [];
    store.results = {};
    store.past = [];
    store.future = [];
    store.autoRun = true;
    return store;
  }

  test('删除节点后下游图自动重算(不再残留旧输入)', () {
    final store = buildPipeline();
    store.runPipeline();
    expect(store.results['v1']!.inputs['in0'], isNotNull);
    store.removeNodes(['n0']);
    // 自动执行后:v1 无输入边 → inputs 清空(图不再显示旧数据)
    expect(store.results.containsKey('v1'), isTrue);
    expect(store.results['v1']!.inputs, isEmpty);
  });

  test('切断连线后下游图自动重算', () {
    final store = buildPipeline();
    store.runPipeline();
    expect(store.results['v1']!.inputs['in0'], isNotNull);
    store.removeEdge('e1');
    expect(store.results['v1']!.inputs, isEmpty);
  });

  test('撤销后图自动重算并恢复显示', () {
    final store = buildPipeline();
    store.runPipeline();
    expect(store.results['v1']!.inputs['in0'], isNotNull);
    // 制造一次可撤销的结构变更:删除连线
    store.removeEdge('e1');
    expect(store.results['v1']!.inputs, isEmpty);
    store.undo();
    // 撤销恢复连线,自动执行后 v1 重新收到表格输入
    expect(store.results['v1']!.inputs['in0'], isNotNull);
  });
}
