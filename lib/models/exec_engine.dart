// 执行引擎:拓扑排序 + 自动执行(由 React 版 nodes/execEngine.ts 移植)
// v2:邻接表优化 O(nodes+edges)+ 单节点耗时 + 脏标记增量执行
library;

import 'data.dart';
import 'registry.dart';

class GraphNodeLite {
  final String id;
  final String configId;
  final Map<String, dynamic> params;
  GraphNodeLite({
    required this.id,
    required this.configId,
    required this.params,
  });
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

  /// 该节点本次 exec 耗时(毫秒)。skip 时为 null。
  final double? execMs;

  ExecResult({
    this.inputs = const {},
    this.outputs = const {},
    this.multiInputs = const {},
    this.error,
    this.execMs,
  });
}

class RunOutcome {
  final Map<String, ExecResult> results;
  final List<String> order;
  final bool hasCycle;
  final double totalMs;

  /// 本次实际执行了多少个节点(非跳过)
  final int executedCount;
  RunOutcome({
    required this.results,
    required this.order,
    required this.hasCycle,
    required this.totalMs,
    this.executedCount = 0,
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

/// 构建入边邻接表: incoming[nodeId] = 指向该节点的全部入边列表。
Map<String, List<GraphEdgeLite>> _buildIncoming(
  List<String> nodeIds,
  List<GraphEdgeLite> edges,
) {
  final incoming = <String, List<GraphEdgeLite>>{};
  for (final id in nodeIds) incoming[id] = [];
  for (final e in edges) {
    if (!incoming.containsKey(e.target)) continue;
    incoming[e.target]!.add(e);
  }
  return incoming;
}

/// 构建出边邻接表(用于下游传播):outgoing[source] = 从该节点出发的全部出边。
Map<String, List<GraphEdgeLite>> _buildOutgoing(
  List<String> nodeIds,
  List<GraphEdgeLite> edges,
) {
  final outgoing = <String, List<GraphEdgeLite>>{};
  for (final id in nodeIds) outgoing[id] = [];
  for (final e in edges) {
    if (!outgoing.containsKey(e.source)) continue;
    outgoing[e.source]!.add(e);
  }
  return outgoing;
}

/// 从一组脏节点出发,传播得到全部下游脏节点集合(包括自身)。
Set<String> propagateDirty(
  Set<String> seeds,
  List<String> nodeIds,
  List<GraphEdgeLite> edges,
) {
  final outgoing = _buildOutgoing(nodeIds, edges);
  final dirty = <String>{...seeds};
  final queue = <String>[...seeds];
  while (queue.isNotEmpty) {
    final u = queue.removeLast();
    // 种子可能含已删除的节点 id(节点删除后触发增量重算):
    // 邻接表按现存节点构建、无此键,跳过即可(其下游已由调用方
    // 通过邻居/边变更标记为脏)
    final outs = outgoing[u];
    if (outs == null) continue;
    for (final e in outs) {
      if (dirty.add(e.target)) queue.add(e.target);
    }
  }
  return dirty;
}

/// 核心执行函数。
/// [dirtyIds] 为脏节点集合(null 表示全量执行);脏集合内的节点及其下游会重新 exec,
/// 未脏节点直接复用 [prevResults] 中的 outputs 作为上游输入。
RunOutcome runGraph(
  List<GraphNodeLite> nodes,
  List<GraphEdgeLite> edges, {
  Set<String>? dirtyIds,
  Map<String, ExecResult>? prevResults,
}) {
  final t0 = DateTime.now().microsecondsSinceEpoch;
  final nodeIds = nodes.map((n) => n.id).toList();
  final order = topoSort(nodeIds, edges);
  final hasCycle = order == null;
  final seq = order ?? nodeIds;
  final idSet = nodeIds.toSet();
  final nodeMap = {for (final n in nodes) n.id: n};
  // 邻接表:O(nodes+edges) 构建,按节点查表 O(1)
  final incoming = _buildIncoming(nodeIds, edges);
  // 计算实际要重新执行的脏集合:传入的 dirtyIds ∪ 其全部下游
  Set<String> execSet;
  if (dirtyIds == null) {
    execSet = idSet;
  } else {
    execSet = propagateDirty(dirtyIds, nodeIds, edges);
  }
  final results = <String, ExecResult>{};
  var executed = 0;
  for (final nodeId in seq) {
    final node = nodeMap[nodeId];
    if (node == null) continue;
    final config = getConfig(node.configId);
    // 未脏节点:直接继承 prevResults(有就用,无就保持空 outputs 让下游报错)
    if (!execSet.contains(nodeId)) {
      if (prevResults != null && prevResults.containsKey(nodeId)) {
        results[nodeId] = prevResults[nodeId]!;
      } else {
        // 首次执行但不在脏集合里(不应该发生,保守处理)
        results[nodeId] = ExecResult();
      }
      continue;
    }
    if (config == null) {
      results[nodeId] = ExecResult(error: '未知节点类型 ${node.configId}');
      continue;
    }
    final inputs = <String, DataObject>{};
    final multiInputs = <String, List<DataObject>>{};
    final inSockets = config.inputs;
    // O(incoming[nodeId].length) 查表,不再遍历全部 edges
    for (final e in incoming[nodeId]!) {
      final src = results[e.source];
      if (src == null) continue;
      final outId = e.sourceHandle ?? 'out0';
      final obj = src.outputs[outId];
      if (obj == null) continue;
      final key = e.targetHandle ?? 'in0';
      // 查 multi 标记:O(inputs.length) 可接受(端口数极少)
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
    double? execMs;
    if (config.exec != null) {
      final tNode = DateTime.now().microsecondsSinceEpoch;
      try {
        final ctx = ExecContext(
          nodeId: nodeId,
          params: node.params,
          inputs: inputs,
          multiInputs: multiInputs,
        );
        outputs = config.exec!(ctx);
      } catch (e) {
        error = '$e';
      }
      execMs = (DateTime.now().microsecondsSinceEpoch - tNode) / 1000.0;
      executed++;
    }
    results[nodeId] = ExecResult(
      inputs: inputs,
      outputs: outputs,
      multiInputs: multiInputs,
      error: error,
      execMs: execMs,
    );
  }
  final elapsed = (DateTime.now().microsecondsSinceEpoch - t0) / 1000.0;
  return RunOutcome(
    results: results,
    order: seq,
    hasCycle: hasCycle,
    totalMs: elapsed,
    executedCount: executed,
  );
}
