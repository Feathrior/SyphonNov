// 执行引擎:拓扑排序 + 自动执行(由 React 版 nodes/execEngine.ts 移植)
library;

import 'data.dart';
import 'registry.dart';

class GraphNodeLite {
  final String id;
  final String configId;
  final Map<String, dynamic> params;

  GraphNodeLite({required this.id, required this.configId, required this.params});
}

class GraphEdgeLite {
  final String source;
  final String target;
  final String? sourceHandle;
  final String? targetHandle;

  GraphEdgeLite({
    required this.source,
    required this.target,
    this.sourceHandle,
    this.targetHandle,
  });
}

class ExecResult {
  final Map<String, DataObject> inputs;
  final Map<String, DataObject> outputs;
  /// 多连接端口收到的全部上游对象(仅 multi 端口)
  final Map<String, List<DataObject>> multiInputs;
  final String? error;

  ExecResult({
    this.inputs = const {},
    this.outputs = const {},
    this.multiInputs = const {},
    this.error,
  });
}

class RunOutcome {
  final Map<String, ExecResult> results;
  final List<String> order;
  final bool hasCycle;
  final double totalMs;

  RunOutcome({
    required this.results,
    required this.order,
    required this.hasCycle,
    required this.totalMs,
  });
}

/// 拓扑排序(Kahn)。返回 null 表示存在环。
List<String>? topoSort(List<String> nodeIds, List<GraphEdgeLite> edges) {
  final indeg = <String, int>{};
  final adj = <String, List<String>>{};
  for (final id in nodeIds) {
    indeg[id] = 0;
    adj[id] = [];
  }
  for (final e in edges) {
    if (!indeg.containsKey(e.source) || !indeg.containsKey(e.target)) continue;
    indeg[e.target] = (indeg[e.target] ?? 0) + 1;
    adj[e.source]!.add(e.target);
  }
  final queue = <String>[];
  for (final e in indeg.entries) {
    if (e.value == 0) queue.add(e.key);
  }
  final order = <String>[];
  var head = 0;
  while (head < queue.length) {
    final u = queue[head++];
    order.add(u);
    for (final v in adj[u]!) {
      indeg[v] = indeg[v]! - 1;
      if (indeg[v] == 0) queue.add(v);
    }
  }
  if (order.length != nodeIds.length) return null;
  return order;
}

RunOutcome runGraph(List<GraphNodeLite> nodes, List<GraphEdgeLite> edges) {
  final t0 = DateTime.now().microsecondsSinceEpoch;
  final nodeIds = nodes.map((n) => n.id).toList();
  final order = topoSort(nodeIds, edges);
  final results = <String, ExecResult>{};
  final hasCycle = order == null;
  final seq = order ?? nodeIds;
  final idSet = nodeIds.toSet();
  final nodeMap = {for (final n in nodes) n.id: n};

  for (final nodeId in seq) {
    final node = nodeMap[nodeId];
    if (node == null) continue;
    final config = getConfig(node.configId);
    if (config == null) {
      results[nodeId] = ExecResult(error: '未知节点类型 ${node.configId}');
      continue;
    }
    final inputs = <String, DataObject>{};
    final multiInputs = <String, List<DataObject>>{};
    final inSockets = config.inputs;
    for (final e in edges) {
      if (e.target != nodeId || !idSet.contains(e.source)) continue;
      final src = results[e.source];
      if (src == null) continue;
      final outId = e.sourceHandle ?? 'out0';
      final obj = src.outputs[outId];
      if (obj == null) continue;
      final key = e.targetHandle ?? 'in0';
      var isMulti = false;
      for (final ins in inSockets) {
        if (ins.id == key && ins.multi == true) {
          isMulti = true;
          break;
        }
      }
      if (isMulti) {
        multiInputs.putIfAbsent(key, () => []).add(obj);
        inputs.putIfAbsent(key, () => obj);
      } else {
        inputs[key] = obj;
      }
    }
    String? error;
    var outputs = <String, DataObject>{};
    if (config.exec != null) {
      try {
        final ctx = ExecContext(nodeId: nodeId, params: node.params, inputs: inputs);
        outputs = config.exec!(ctx);
      } catch (e) {
        error = '$e';
      }
    }
    results[nodeId] = ExecResult(
      inputs: inputs,
      outputs: outputs,
      multiInputs: multiInputs,
      error: error,
    );
  }
  final elapsed = (DateTime.now().microsecondsSinceEpoch - t0) / 1000.0;
  return RunOutcome(
    results: results,
    order: seq,
    hasCycle: hasCycle,
    totalMs: elapsed,
  );
}
