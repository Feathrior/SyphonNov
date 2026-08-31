// 散点转表格节点测试:x/y(/z)列输出。
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/models/data.dart' as md;
import 'package:syphon_nov/models/exec.dart';
import 'package:syphon_nov/models/exec_engine.dart';
import 'package:syphon_nov/models/registry.dart';

void main() {
  test('注册表:散点转表格输入输出正确', () {
    final cfg = getConfig('scatter_to_table');
    expect(cfg, isNotNull);
    expect(cfg!.inputs.first.type, md.SocketType.scatter);
    expect(cfg.outputs.first.type, md.SocketType.table);
  });

  test('2D 散点转 x/y 两列表格', () {
    final out = kExec['scatter_to_table']!(
      md.ExecContext(
        nodeId: 'n',
        params: const {},
        inputs: {
          'in0': md.ScatterData(
            name: '点',
            points: const [md.Pt3(1, 2), md.Pt3(3, 4), md.Pt3(5, 6)],
          ),
        },
      ),
    );
    final table = out['out0']! as md.TableData;
    expect(table.columns.map((c) => c.name), ['x', 'y']);
    expect(table.columns[0].values, [1, 3, 5]);
    expect(table.columns[1].values, [2, 4, 6]);
  });

  test('含 z 的散点输出三列', () {
    final out = kExec['scatter_to_table']!(
      md.ExecContext(
        nodeId: 'n',
        params: const {},
        inputs: {
          'in0': md.ScatterData(
            name: '点',
            points: const [md.Pt3(0, 0, 1), md.Pt3(1, 1, 2), md.Pt3(2, 2)],
          ),
        },
      ),
    );
    final table = out['out0']! as md.TableData;
    expect(table.columns.map((c) => c.name), ['x', 'y', 'z']);
    expect(table.columns[2].values, [1, 2, null]);
  });

  test('经执行引擎:聚合点输入 → 散点转表格 → 数据输出链路', () {
    final outcome = runGraph(
      [
        GraphNodeLite(id: 's', configId: 'scatter_input', params: {
          'points': [
            {'x': 1, 'y': 2, 'size': 4, 'shape': 'circle', 'color': '#1f77b4'},
          ],
        }),
        GraphNodeLite(id: 't', configId: 'scatter_to_table', params: const {}),
      ],
      [
        GraphEdgeLite(
            source: 's', target: 't', sourceHandle: 'out0', targetHandle: 'in0'),
      ],
    );
    final res = outcome.results['t']!;
    expect(res.error, isNull);
    final table = res.outputs['out0']! as md.TableData;
    expect(table.columns.map((c) => c.name), ['x', 'y']);
    expect(table.columns[0].values[0], 1);
  });
}
