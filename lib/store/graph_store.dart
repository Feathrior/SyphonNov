// 图状态管理(由 React 版 store/useGraph.ts 移植,采用 ChangeNotifier)
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../models/color_utils.dart';
import '../models/data.dart';
import '../models/exec_engine.dart';
import '../models/registry.dart';

class _RunRequest {
  final List<GraphNodeLite> nodes;
  final List<GraphEdgeLite> edges;
  final Set<String>? dirtyIds;
  final Map<String, ExecResult> previous;

  const _RunRequest(this.nodes, this.edges, this.dirtyIds, this.previous);

  RunOutcome run() =>
      runGraph(nodes, edges, dirtyIds: dirtyIds, prevResults: previous);
}

class _RunWorkerRequest {
  final _RunRequest request;
  final SendPort sendPort;

  const _RunWorkerRequest(this.request, this.sendPort);
}

void _runWorker(_RunWorkerRequest worker) {
  try {
    final outcome = runGraph(
      worker.request.nodes,
      worker.request.edges,
      dirtyIds: worker.request.dirtyIds,
      prevResults: worker.request.previous,
      onProgress: (completed, total) => worker.sendPort.send({
        'kind': 'progress',
        'completed': completed,
        'total': total,
      }),
    );
    worker.sendPort.send({'kind': 'outcome', 'value': outcome});
  } catch (error, stack) {
    worker.sendPort.send({
      'kind': 'error',
      'message': '$error',
      'stack': '$stack',
    });
  }
}

/// 画布节点
class GraphNode {
  final String id;
  final String configId;
  final Map<String, dynamic> params;
  final List<String> exposed;
  final bool collapsed;
  final Offset position;

  const GraphNode({
    required this.id,
    required this.configId,
    required this.params,
    this.exposed = const [],
    this.collapsed = false,
    this.position = Offset.zero,
  });

  GraphNode copyWith({
    String? id,
    String? configId,
    Map<String, dynamic>? params,
    List<String>? exposed,
    bool? collapsed,
    Offset? position,
  }) {
    return GraphNode(
      id: id ?? this.id,
      configId: configId ?? this.configId,
      params: params ?? this.params,
      exposed: exposed ?? this.exposed,
      collapsed: collapsed ?? this.collapsed,
      position: position ?? this.position,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'configId': configId,
    'params': params,
    'exposed': exposed,
    'collapsed': collapsed,
    'position': {'x': position.dx, 'y': position.dy},
  };

  factory GraphNode.fromJson(Map<String, dynamic> j) {
    final pos = j['position'];
    return GraphNode(
      id: '${j['id'] ?? ''}',
      configId: '${j['configId'] ?? ''}',
      params: j['params'] is Map
          ? Map<String, dynamic>.from(j['params'] as Map)
          : {},
      exposed: j['exposed'] is List
          ? j['exposed']!.map((e) => '$e').toList()
          : [],
      collapsed: j['collapsed'] == true,
      position: pos is Map
          ? Offset(
              (pos['x'] is num) ? (pos['x'] as num).toDouble() : 0,
              (pos['y'] is num) ? (pos['y'] as num).toDouble() : 0,
            )
          : Offset.zero,
    );
  }

  static GraphNode deepCopy(GraphNode n) {
    // params 里的值都是不可变的 int/double/String/List/map,浅拷贝足够;
    // 避免 jsonDecode(jsonEncode) 全量序列化,性能提升显著
    final copiedParams = <String, dynamic>{};
    for (final e in n.params.entries) {
      final v = e.value;
      if (v is List) {
        copiedParams[e.key] = List.of(v);
      } else if (v is Map) {
        copiedParams[e.key] = Map<String, dynamic>.from(v);
      } else {
        copiedParams[e.key] = v;
      }
    }
    return GraphNode(
      id: n.id,
      configId: n.configId,
      params: copiedParams,
      exposed: List.of(n.exposed),
      collapsed: n.collapsed,
      position: n.position,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GraphNode &&
      other.id == id &&
      other.configId == configId &&
      mapEquals(other.params, params) &&
      listEquals(other.exposed, exposed) &&
      other.collapsed == collapsed &&
      other.position == position;

  @override
  int get hashCode => Object.hash(id, configId, position.dx, position.dy);
}

/// 画布连线
class GraphEdge {
  final String id;
  final String source;
  final String target;
  final String? sourceHandle;
  final String? targetHandle;

  /// 曲线内部分割点(Alt 拆分;非空时曲线按贝塞尔中点绘制)
  final Offset? mid;

  const GraphEdge({
    required this.id,
    required this.source,
    required this.target,
    this.sourceHandle,
    this.targetHandle,
    this.mid,
  });

  GraphEdge copyWith({String? id, Offset? mid, Object? midDel}) {
    return GraphEdge(
      id: id ?? this.id,
      source: source,
      target: target,
      sourceHandle: sourceHandle,
      targetHandle: targetHandle,
      mid: midDel == null ? (mid ?? this.mid) : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'source': source,
    'target': target,
    'sourceHandle': sourceHandle,
    'targetHandle': targetHandle,
    'mid': mid == null ? null : {'x': mid!.dx, 'y': mid!.dy},
  };

  factory GraphEdge.fromJson(Map<String, dynamic> j) {
    final m = j['mid'];
    return GraphEdge(
      id: '${j['id'] ?? ''}',
      source: '${j['source'] ?? ''}',
      target: '${j['target'] ?? ''}',
      sourceHandle: j['sourceHandle'] == null ? null : '${j['sourceHandle']}',
      targetHandle: j['targetHandle'] == null ? null : '${j['targetHandle']}',
      mid: m is Map && m['x'] is num
          ? Offset((m['x'] as num).toDouble(), (m['y'] as num).toDouble())
          : null,
    );
  }

  static GraphEdge deepCopy(GraphEdge e) => GraphEdge(
    id: e.id,
    source: e.source,
    target: e.target,
    sourceHandle: e.sourceHandle,
    targetHandle: e.targetHandle,
    mid: e.mid,
  );

  @override
  bool operator ==(Object other) =>
      other is GraphEdge &&
      other.id == id &&
      other.source == source &&
      other.target == target &&
      other.sourceHandle == sourceHandle &&
      other.targetHandle == targetHandle &&
      other.mid == mid;

  @override
  int get hashCode =>
      Object.hash(id, source, target, sourceHandle, targetHandle, mid);
}

class LogEntry {
  final String id;
  final String time;
  final String level; // info | ok | error
  final String msg;

  const LogEntry({
    required this.id,
    required this.time,
    required this.level,
    required this.msg,
  });
}

/// 节点分组(Blender 风格):将多个节点组成一个分组,成员整体拖动,保存到画布文件
class NodeGroup {
  final String id;
  final String name;
  final List<String> nodeIds;

  const NodeGroup({
    required this.id,
    required this.name,
    required this.nodeIds,
  });

  NodeGroup copyWith({String? name, List<String>? nodeIds}) => NodeGroup(
    id: id,
    name: name ?? this.name,
    nodeIds: nodeIds ?? this.nodeIds,
  );

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'nodeIds': nodeIds};

  factory NodeGroup.fromJson(Map<String, dynamic> j) => NodeGroup(
    id: '${j['id'] ?? genId('g')}',
    name: '${j['name'] ?? '分组'}',
    nodeIds: j['nodeIds'] is List
        ? (j['nodeIds'] as List).map((e) => '$e').toList()
        : const [],
  );

  static NodeGroup deepCopy(NodeGroup g) =>
      NodeGroup(id: g.id, name: g.name, nodeIds: List.of(g.nodeIds));

  @override
  bool operator ==(Object other) =>
      other is NodeGroup &&
      other.id == id &&
      other.name == name &&
      listEquals(other.nodeIds, nodeIds);

  @override
  int get hashCode => Object.hash(id, name, Object.hashAll(nodeIds));
}

/// 连线端口颜色
Color socketColor(SocketType t) =>
    parseColor(kSocketColor[t], const Color(0xFF7C8DB5));

int _idCounter = 0;

String genId([String prefix = 'n']) {
  _idCounter += 1;
  return '${prefix}_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}_$_idCounter';
}

double nodeWidth(String configId) {
  final cfg = getConfig(configId);
  if (cfg == null) return 260;
  return cfg.isViewer ? 440 : 260;
}

/// 撤销快照:节点 + 连线 + 分组
typedef GraphSnapshot = ({
  List<GraphNode> nodes,
  List<GraphEdge> edges,
  List<NodeGroup> groups,
});

class GraphStore extends ChangeNotifier {
  /// 仅描述节点/断点的几何位移。拖动期间使用独立通知，避免让所有
  /// GraphStore 监听者（尤其三维预览）随每个指针事件重建。
  final ValueNotifier<int> layoutRevision = ValueNotifier<int>(0);
  List<GraphNode> nodes = [];
  List<GraphEdge> edges = [];
  List<NodeGroup> groups = []; // 节点分组(Blender 风格,成员整体拖动)
  String? selectedId;
  Set<String> multiSelected = {}; // 多选节点集(Shift 点击/框选/分组)
  String? selectedSplitEdgeId; // 选中断点(Alt 创建 / 点击 mid)
  String? selectedEdgeId; // 选中整条连线(点击连线本体)
  bool autoRun = true;
  int runVersion = 0;
  int structureVersion = 0;
  Map<String, ExecResult> results = {};
  bool hasCycle = false;
  String? lastError;
  int executionRevision = 0;
  int committedRevision = 0;
  String executionStatus = 'idle';
  double executionProgress = 0;
  int executionCompletedNodes = 0;
  int executionTotalNodes = 0;
  Map<String, dynamic>? structuredError;
  List<String> cyclePath = const [];
  List<LogEntry> logs = [];
  List<GraphSnapshot> past = [];
  List<GraphSnapshot> future = [];

  static final GraphStore instance = GraphStore._();
  GraphStore._();

  /// 节点 O(1) 查找表(每次访问重建,因 nodes 经常被整体替换为新 List)
  Map<String, GraphNode> get nodeMap => {for (final n in nodes) n.id: n};

  GraphNode? nodeOf(String id) {
    for (final n in nodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  // ---------- 撤销快照(节点/连线/分组) ----------
  void snapshotNow() {
    final snap = (
      nodes: nodes.map(GraphNode.deepCopy).toList(),
      edges: edges.map(GraphEdge.deepCopy).toList(),
      groups: groups.map(NodeGroup.deepCopy).toList(),
    );
    if (past.isNotEmpty) {
      final last = past.last;
      if (_snapEquals(last, snap)) return;
    }
    past.add(snap);
    if (past.length > 100) past.removeAt(0);
    future.clear();
  }

  bool _snapEquals(GraphSnapshot a, GraphSnapshot b) {
    if (a.nodes.length != b.nodes.length || a.edges.length != b.edges.length) {
      return false;
    }
    if (a.groups.length != b.groups.length) return false;
    for (var i = 0; i < a.nodes.length; i++) {
      if (a.nodes[i] != b.nodes[i]) return false;
    }
    for (var i = 0; i < a.edges.length; i++) {
      if (a.edges[i] != b.edges[i]) return false;
    }
    for (var i = 0; i < a.groups.length; i++) {
      if (a.groups[i] != b.groups[i]) return false;
    }
    return true;
  }

  // ---------- 节点/连线操作 ----------
  String addNode(String configId, Offset position, {bool triggerRun = true}) {
    snapshotNow();
    final cfg = getConfig(configId);
    final defaults = <String, dynamic>{};
    if (cfg != null) {
      for (final p in cfg.params) {
        if (p.type != 'button') {
          final d = p.defaultValue;
          // 列表型默认值(渐变停止点等)规范化为 Map:GradientStop 对象
          // 无法 JSON 序列化,且属性面板按 Map 解析——统一转 toJson
          if (d is List) {
            defaults[p.key] = [
              for (final s in d)
                if (s is GradientStop) s.toJson() else s,
            ];
          } else {
            defaults[p.key] = d;
          }
        }
      }
    }
    final node = GraphNode(
      id: genId(),
      configId: configId,
      params: defaults,
      position: position,
    );
    nodes = [...nodes, node];
    selectedId = node.id;
    structureVersion++;
    notifyListeners();
    if (autoRun && triggerRun) runAfterGraphChange(changedIds: {node.id});
    return node.id;
  }

  void addNodeDirect(GraphNode node) {
    nodes = [...nodes, node];
    selectedId = node.id;
    structureVersion++;
    notifyListeners();
  }

  /// 一次拖动结束后提交布局变化，让保存、缩略图之外的状态只刷新一次。
  void finishLayoutChange() => notifyListeners();

  void removeNodes(List<String> ids) {
    if (ids.isEmpty) return;
    snapshotNow();
    final setIds = ids.toSet();
    // 先记下被删节点的直接下游:边过滤后无法再从 edges 找到,
    // 不记则下游节点不会标脏、会残留旧输入(下游自身也在删除集时无妨,
    // propagateDirty 会跳过不存在的节点)
    final downstream = <String>{
      for (final e in edges)
        if (setIds.contains(e.source)) e.target,
    };
    nodes = nodes.where((n) => !setIds.contains(n.id)).toList();
    edges = edges
        .where((e) => !setIds.contains(e.source) && !setIds.contains(e.target))
        .toList();
    // 从分组中剔除被删除的成员;空分组自动解散
    groups = groups
        .map(
          (g) => g.copyWith(
            nodeIds: g.nodeIds.where((id) => !setIds.contains(id)).toList(),
          ),
        )
        .where((g) => g.nodeIds.isNotEmpty)
        .toList();
    multiSelected.removeAll(setIds);
    if (setIds.contains(selectedId)) selectedId = null;
    structureVersion++;
    notifyListeners();
    // 删除节点改变数据流:自动执行下重算(否则下游残留旧结果不刷新)
    if (autoRun) {
      runAfterGraphChange(
        changedIds: {...setIds, ...downstream},
        edgeChanged: true,
      );
    }
  }

  void duplicateNodes(List<String> ids) {
    final setIds = ids.toSet();
    final srcNodes = nodes.where((n) => setIds.contains(n.id)).toList();
    if (srcNodes.isEmpty) return;
    snapshotNow();
    final idMap = <String, String>{};
    final clones = <GraphNode>[];
    for (final n in srcNodes) {
      final newId = genId();
      idMap[n.id] = newId;
      clones.add(
        GraphNode(
          id: newId,
          configId: n.configId,
          params: GraphNode.deepCopy(n).params,
          exposed: List.of(n.exposed),
          position: n.position + const Offset(40, 40),
        ),
      );
    }
    final newEdges = <GraphEdge>[];
    for (final e in edges) {
      if (setIds.contains(e.source) && setIds.contains(e.target)) {
        newEdges.add(
          GraphEdge(
            id: genId('e'),
            source: idMap[e.source]!,
            target: idMap[e.target]!,
            sourceHandle: e.sourceHandle,
            targetHandle: e.targetHandle,
          ),
        );
      }
    }
    nodes = [...nodes, ...clones];
    edges = [...edges, ...newEdges];
    selectedId = clones.isNotEmpty ? clones.first.id : null;
    multiSelected = clones.map((c) => c.id).toSet();
    structureVersion++;
    notifyListeners();
    // 复制节点后自动执行,新节点输出立即可见
    if (autoRun) {
      runAfterGraphChange(changedIds: clones.map((c) => c.id).toSet());
    }
  }

  /// 复制分组:克隆组内全部节点(含内部连线与断点),并对克隆重建分组,
  /// 整体偏移 (40,40);克隆组成为新的多选集
  void duplicateGroup(String groupId) {
    final target = groups.where((g) => g.id == groupId).toList();
    if (target.isEmpty) return;
    final g = target.first;
    final members = nodes.where((n) => g.nodeIds.contains(n.id)).toList();
    if (members.isEmpty) return;
    snapshotNow();
    final idMap = <String, String>{};
    final clones = <GraphNode>[];
    for (final n in members) {
      final newId = genId();
      idMap[n.id] = newId;
      clones.add(
        GraphNode(
          id: newId,
          configId: n.configId,
          params: GraphNode.deepCopy(n).params,
          exposed: List.of(n.exposed),
          collapsed: n.collapsed,
          position: n.position + const Offset(40, 40),
        ),
      );
    }
    final newEdges = <GraphEdge>[];
    for (final e in edges) {
      if (idMap.containsKey(e.source) && idMap.containsKey(e.target)) {
        newEdges.add(
          GraphEdge(
            id: genId('e'),
            source: idMap[e.source]!,
            target: idMap[e.target]!,
            sourceHandle: e.sourceHandle,
            targetHandle: e.targetHandle,
            mid: e.mid,
          ),
        );
      }
    }
    _groupCounter++;
    final newGroup = NodeGroup(
      id: genId('g'),
      name: '${g.name} 副本',
      nodeIds: clones.map((c) => c.id).toList(),
    );
    nodes = [...nodes, ...clones];
    edges = [...edges, ...newEdges];
    groups = [...groups, newGroup];
    selectedId = clones.isNotEmpty ? clones.first.id : null;
    multiSelected = clones.map((c) => c.id).toSet();
    addLog('ok', '已复制分组「${g.name}」');
    structureVersion++;
    notifyListeners();
  }

  // ---------- 复制 / 粘贴(节点/节点组,内部剪贴板) ----------

  Map<String, GraphNode>? _clipNodes;
  List<GraphEdge>? _clipEdges;
  List<NodeGroup>? _clipGroups;
  Offset _clipOrigin = Offset.zero;

  /// 剪贴板中是否有可粘贴内容
  bool get hasClipboard => _clipNodes != null && _clipNodes!.isNotEmpty;

  /// 复制所选节点到内部剪贴板;所选构成完整分组的节点,分组信息一并复制
  void copySelection(Set<String> ids) {
    if (ids.isEmpty) {
      _clipNodes = null;
      _clipEdges = null;
      _clipGroups = null;
      return;
    }
    final src = <String, GraphNode>{
      for (final n in nodes)
        if (ids.contains(n.id)) n.id: GraphNode.deepCopy(n),
    };
    if (src.isEmpty) {
      _clipNodes = null;
      _clipEdges = null;
      _clipGroups = null;
      return;
    }
    _clipNodes = src;
    // 内部连线(两端均在剪贴板内),保留断点
    _clipEdges = [
      for (final e in edges)
        if (src.containsKey(e.source) && src.containsKey(e.target))
          GraphEdge.deepCopy(e),
    ];
    // 完整包含于所选的分组(组内成员全部在剪贴板)
    _clipGroups = [
      for (final g in groups)
        if (g.nodeIds.isNotEmpty && g.nodeIds.every(src.containsKey))
          NodeGroup(id: g.id, name: g.name, nodeIds: List.of(g.nodeIds)),
    ];
    // 原内容包围盒左上角(粘贴定位锚点)
    var minX = double.infinity;
    var minY = double.infinity;
    for (final n in src.values) {
      minX = math.min(minX, n.position.dx);
      minY = math.min(minY, n.position.dy);
    }
    _clipOrigin = Offset(
      minX == double.infinity ? 0 : minX,
      minY == double.infinity ? 0 : minY,
    );
  }

  /// 在 anchor(flow 坐标)处粘贴剪贴板内容:原内容左上角对齐 anchor;
  /// 克隆节点/连线/分组,粘贴后成为新的多选集
  void pasteAt(Offset anchor) {
    final src = _clipNodes;
    if (src == null || src.isEmpty) return;
    snapshotNow();
    final shift = anchor - _clipOrigin;
    final idMap = <String, String>{};
    final clones = <GraphNode>[];
    for (final n in src.values) {
      final newId = genId();
      idMap[n.id] = newId;
      clones.add(
        GraphNode(
          id: newId,
          configId: n.configId,
          params: GraphNode.deepCopy(n).params,
          exposed: List.of(n.exposed),
          collapsed: n.collapsed,
          position: n.position + shift,
        ),
      );
    }
    final newEdges = <GraphEdge>[];
    for (final e in _clipEdges ?? const <GraphEdge>[]) {
      newEdges.add(
        GraphEdge(
          id: genId('e'),
          source: idMap[e.source]!,
          target: idMap[e.target]!,
          sourceHandle: e.sourceHandle,
          targetHandle: e.targetHandle,
          mid: e.mid,
        ),
      );
    }
    final newGroups = <NodeGroup>[];
    for (final g in _clipGroups ?? const <NodeGroup>[]) {
      if (g.nodeIds.isNotEmpty && g.nodeIds.every(idMap.containsKey)) {
        newGroups.add(
          NodeGroup(
            id: genId('g'),
            name: g.name,
            nodeIds: [for (final id in g.nodeIds) idMap[id]!],
          ),
        );
      }
    }
    nodes = [...nodes, ...clones];
    edges = [...edges, ...newEdges];
    groups = [...groups, ...newGroups];
    selectedId = clones.isNotEmpty ? clones.first.id : null;
    multiSelected = clones.map((c) => c.id).toSet();
    addLog(
      'ok',
      '已粘贴 ${clones.length} 个节点'
          '${newGroups.isNotEmpty ? '(含 ${newGroups.length} 个分组)' : ''}',
    );
    structureVersion++;
    notifyListeners();
  }

  void clearAll() {
    if (nodes.isEmpty) return;
    snapshotNow();
    nodes = [];
    edges = [];
    groups = [];
    selectedId = null;
    multiSelected = {};
    results = {};
    lastError = null;
    structureVersion++;
    notifyListeners();
  }

  void selectNode(String? id) {
    selectedId = id;
    notifyListeners();
  }

  /// 设置多选集合;selectedId 同步指向集合内一个节点(无则取首元素)
  void setMultiSelected(Set<String> ids) {
    multiSelected = {...ids};
    if (!multiSelected.contains(selectedId)) {
      selectedId = multiSelected.isNotEmpty ? multiSelected.first : null;
    }
    notifyListeners();
  }

  /// 批量移动节点:绝对定位 —— 各节点设置为 targets 指定的目标坐标。
  /// 拖动以"按下坐标 + 累计位移"为目标,而非"当前位置 + 位移",
  /// 避免增量累加导致节点越拖越快(不跟随鼠标"乱飞")
  void moveNodesTo(Set<String> ids, Map<String, Offset> targets) {
    if (ids.isEmpty || targets.isEmpty) return;
    var moved = false;
    final updated = <GraphNode>[];
    final origins = <String, Offset>{}; // 移动节点原位置(计算位移)
    for (final n in nodes) {
      final t = targets[n.id];
      if (t != null) {
        origins[n.id] = n.position;
        if (t == n.position) {
          updated.add(n);
        } else {
          updated.add(n.copyWith(position: t));
          moved = true;
        }
      } else {
        updated.add(n);
      }
    }
    if (!moved) return;
    nodes = updated;
    // 断点跟随源节点:任意拖动(单选/多选/分组)时,断点相对源节点左上角的
    // 偏移保持不变 —— 多选/分组整体移动时,源节点与整体同移,
    // 断点随整体同步平移,与节点的相对位置始终不变
    var edgesChanged = false;
    final newEdges = <GraphEdge>[];
    for (final e in edges) {
      final mid = e.mid;
      final srcOrigin = origins[e.source];
      final srcTarget = targets[e.source];
      // 源节点不在移动集(或拖动未使其位移)→ 断点保持原位
      if (mid == null || srcOrigin == null || srcTarget == null) {
        newEdges.add(e);
        continue;
      }
      final ds = srcTarget - srcOrigin;
      if (ds == Offset.zero) {
        newEdges.add(e);
        continue;
      }
      newEdges.add(e.copyWith(mid: mid + ds));
      edgesChanged = true;
    }
    if (edgesChanged) edges = newEdges;
    layoutRevision.value++;
  }

  // ---------- 节点分组(Blender 风格) ----------

  int _groupCounter = 0;

  /// 节点所属分组 id(未分组返回 null)
  String? groupOf(String nodeId) {
    for (final g in groups) {
      if (g.nodeIds.contains(nodeId)) return g.id;
    }
    return null;
  }

  /// 将多个节点创建为一个分组(少于 2 个节点时忽略)
  void createGroup(List<String> nodeIds) {
    final ids = nodeIds
        .where((id) => nodes.any((n) => n.id == id))
        .toSet()
        .toList();
    if (ids.length < 2) return;
    snapshotNow();
    _groupCounter++;
    groups = [
      ...groups,
      NodeGroup(id: genId('g'), name: '分组 $_groupCounter', nodeIds: ids),
    ];
    addLog('ok', '已将 ${ids.length} 个节点创建为「分组 $_groupCounter」');
    structureVersion++;
    notifyListeners();
  }

  /// 将已有节点加入指定分组(节点已在该组或组不存在时忽略)
  void addNodeToGroup(String nodeId, String groupId) {
    final target = groups.where((g) => g.id == groupId).toList();
    if (target.isEmpty) return;
    final g = target.first;
    if (g.nodeIds.contains(nodeId)) return;
    // 节点不允许同时属于多个分组:先从原分组移除
    final oldGid = groupOf(nodeId);
    snapshotNow();
    if (oldGid != null && oldGid != groupId) {
      groups = groups
          .map((og) {
            if (og.id == oldGid) {
              return og.copyWith(
                nodeIds: og.nodeIds.where((id) => id != nodeId).toList(),
              );
            }
            return og;
          })
          .where((og) => og.nodeIds.isNotEmpty)
          .toList();
    }
    groups = groups.map((og) {
      if (og.id == groupId) {
        return og.copyWith(nodeIds: [...og.nodeIds, nodeId]);
      }
      return og;
    }).toList();
    addLog('info', '节点已加入「${g.name}」');
    structureVersion++;
    notifyListeners();
  }

  /// 解散分组(节点保留,仅移除分组容器)
  void dissolveGroup(String groupId) {
    final target = groups.where((g) => g.id == groupId).toList();
    if (target.isEmpty) return;
    snapshotNow();
    groups = groups.where((g) => g.id != groupId).toList();
    addLog('info', '已解散分组「${target.first.name}」');
    structureVersion++;
    notifyListeners();
  }

  /// 重命名分组(空名忽略)
  void renameGroup(String groupId, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final target = groups.where((g) => g.id == groupId).toList();
    if (target.isEmpty) return;
    snapshotNow();
    groups = [
      for (final g in groups) g.id == groupId ? g.copyWith(name: trimmed) : g,
    ];
    addLog('info', '分组已重命名为「$trimmed」');
    structureVersion++;
    notifyListeners();
  }

  /// 节点拖动:snapshot=true 时先记录撤销快照(拖动开始调用一次)
  void moveNode(String id, Offset position, {bool snapshot = false}) {
    if (snapshot) snapshotNow();
    var moved = false;
    final updated = <GraphNode>[];
    for (final n in nodes) {
      if (n.id == id) {
        if (n.position == position) {
          updated.add(n);
        } else {
          updated.add(n.copyWith(position: position));
          moved = true;
        }
      } else {
        updated.add(n);
      }
    }
    if (!moved) return;
    nodes = updated;
    notifyListeners();
  }

  void selectSplitEdge(String? id) {
    selectedSplitEdgeId = id;
    if (id != null) selectedEdgeId = null; // 互斥
    notifyListeners();
  }

  /// 选中整条连线
  void selectEdge(String? id) {
    selectedEdgeId = id;
    if (id != null) selectedSplitEdgeId = null; // 互斥
    notifyListeners();
  }

  void updateNodeParams(String id, Map<String, dynamic> patch) {
    var idx = -1;
    for (var i = 0; i < nodes.length; i++) {
      if (nodes[i].id == id) {
        idx = i;
        break;
      }
    }
    if (idx < 0) return;
    var changed = false;
    patch.forEach((k, v) {
      if (_jsonStr(nodes[idx].params[k]) != _jsonStr(v)) changed = true;
    });
    if (!changed) return;
    snapshotNow();
    final updated = List<GraphNode>.of(nodes);
    final n = nodes[idx];
    updated[idx] = GraphNode(
      id: n.id,
      configId: n.configId,
      params: {...n.params, ...patch},
      exposed: n.exposed,
      collapsed: n.collapsed,
      position: n.position,
    );
    nodes = updated;
    selectedId = id;
    structureVersion++;
    notifyListeners();
    // 参数变化影响数据流:自动执行下立即重算(原理化输出等图据此实时刷新)
    if (autoRun) runAfterGraphChange(changedIds: {nodes[idx].id});
  }

  String _jsonStr(dynamic v) {
    try {
      return jsonEncode(v);
    } catch (_) {
      return '$v';
    }
  }

  void toggleExposed(String id, String key) {
    snapshotNow();
    nodes = nodes.map((n) {
      if (n.id != id) return n;
      final cur = n.exposed;
      final exposed = cur.contains(key)
          ? cur.where((k) => k != key).toList()
          : [...cur, key];
      return n.copyWith(exposed: exposed);
    }).toList();
    structureVersion++;
    notifyListeners();
    // 暴露参数开关改变输入口,影响连线数据流:自动执行下重新计算
    if (autoRun) runAfterGraphChange(changedIds: {id});
  }

  void toggleCollapse(String id) {
    snapshotNow();
    nodes = nodes.map((n) {
      if (n.id != id) return n;
      return n.copyWith(collapsed: !n.collapsed);
    }).toList();
    notifyListeners();
  }

  bool onConnect({
    required String source,
    required String target,
    String? sourceHandle,
    String? targetHandle,
    bool triggerRun = true,
  }) {
    GraphNode? srcNode;
    GraphNode? tnNode;
    for (final n in nodes) {
      if (n.id == source) srcNode = n;
      if (n.id == target) tnNode = n;
    }
    final srcConfig = srcNode == null ? null : getConfig(srcNode.configId);
    final targetConfig = tnNode == null ? null : getConfig(tnNode.configId);
    if (srcConfig == null || targetConfig == null || source == target) {
      addLog('error', '连接失败:节点不存在或不能连接自身');
      return false;
    }
    final outputId =
        sourceHandle ??
        (srcConfig.outputs.isEmpty ? null : srcConfig.outputs.first.id);
    final inputId =
        targetHandle ??
        (targetConfig.inputs.isEmpty ? null : targetConfig.inputs.first.id);
    final outputs = srcConfig.outputs.where((socket) => socket.id == outputId);
    final inputs = targetConfig.inputs.where((socket) => socket.id == inputId);
    if (outputs.isEmpty ||
        inputs.isEmpty ||
        !isCompatible(outputs.first.type, inputs.first.type)) {
      addLog('error', '连接失败:端口不存在或类型不兼容');
      return false;
    }
    var nextEdges = edges;
    if (inputs.first.multi != true) {
      nextEdges = nextEdges
          .where(
            (edge) => edge.target != target || edge.targetHandle != inputId,
          )
          .toList();
    }
    if (nextEdges.any(
      (edge) =>
          edge.source == source &&
          edge.target == target &&
          edge.sourceHandle == outputId &&
          edge.targetHandle == inputId,
    )) {
      return false;
    }
    final candidate = GraphEdge(
      id: genId('e'),
      source: source,
      target: target,
      sourceHandle: outputId,
      targetHandle: inputId,
    );
    final graphEdges = [...nextEdges, candidate];
    if (topoSort(
          nodes.map((node) => node.id).toList(),
          graphEdges
              .map(
                (edge) => GraphEdgeLite(
                  source: edge.source,
                  target: edge.target,
                  sourceHandle: edge.sourceHandle,
                  targetHandle: edge.targetHandle,
                ),
              )
              .toList(),
        ) ==
        null) {
      addLog('error', '连接失败:该连接会形成循环');
      return false;
    }
    snapshotNow();
    edges = graphEdges;
    structureVersion++;
    addLog(
      'ok',
      '已连接 ${srcNode?.configId ?? ''} → ${tnNode?.configId ?? ''}(${targetHandle ?? 'in0'})',
    );
    // 连线变化改变数据流:自动执行下重算
    if (autoRun && triggerRun) runAfterGraphChange(edgeChanged: true);
    return true;
  }

  /// 更新连线 data(mid 分割点;不入撤销历史)。
  /// 注意:mid 为 null 表示删除断点——copyWith 的 midDel 哨兵区分"保持"与"清除"
  void updateEdgeData(String id, Offset? mid) {
    edges = edges.map((e) {
      if (e.id != id) return e;
      if (mid != null) {
        return e.copyWith(mid: mid);
      }
      return e.copyWith(midDel: const Object()); // 非空哨兵 → 清除分割点
    }).toList();
    notifyListeners();
  }

  /// 切断连线(Ctrl 拖拽删除;记录撤销)
  void removeEdge(String id) {
    if (!edges.any((e) => e.id == id)) return;
    snapshotNow();
    edges = edges.where((e) => e.id != id).toList();
    if (selectedSplitEdgeId == id) selectedSplitEdgeId = null;
    if (selectedEdgeId == id) selectedEdgeId = null;
    structureVersion++;
    notifyListeners();
    // 切断连线后自动执行,下游不再残留旧结果
    if (autoRun) runAfterGraphChange(edgeChanged: true);
  }

  // ---------- 撤销/重做 ----------
  void undo() {
    if (past.isEmpty) return;
    final prev = past.last;
    past = past.sublist(0, past.length - 1);
    future = [
      (
        nodes: nodes.map(GraphNode.deepCopy).toList(),
        edges: edges.map(GraphEdge.deepCopy).toList(),
        groups: groups.map(NodeGroup.deepCopy).toList(),
      ),
      ...future,
    ];
    if (future.length > 100) future = future.sublist(0, 100);
    _restore(prev);
    addLog('info', '已撤销');
  }

  void redo() {
    if (future.isEmpty) return;
    final next = future.first;
    future = future.sublist(1);
    past.add((
      nodes: nodes.map(GraphNode.deepCopy).toList(),
      edges: edges.map(GraphEdge.deepCopy).toList(),
      groups: groups.map(NodeGroup.deepCopy).toList(),
    ));
    if (past.length > 100) past.removeAt(0);
    _restore(next);
    addLog('info', '已重做');
  }

  void _restore(GraphSnapshot snap) {
    nodes = snap.nodes.map(GraphNode.deepCopy).toList();
    edges = snap.edges.map(GraphEdge.deepCopy).toList();
    groups = snap.groups.map(NodeGroup.deepCopy).toList();
    selectedId = null;
    multiSelected = {};
    results = {};
    hasCycle = false;
    lastError = null;
    structureVersion++;
    notifyListeners();
    // 撤销/重做改变图结构:快照可能包含任意变化 → 保守全量
    if (autoRun) runPipeline();
  }

  // ---------- 保存/加载 ----------
  static const int workflowFormatVersion = 2;

  String saveGraph() {
    return const JsonEncoder.withIndent('  ').convert({
      'format': 'syphon-graph',
      'formatVersion': workflowFormatVersion,
      'version': workflowFormatVersion,
      'provenance': {
        'application': 'SyphonNov',
        'applicationVersion': '0.4.2',
        'numericSemantics': 'full-precision',
      },
      'nodes': nodes.map((n) => n.toJson()).toList(),
      'edges': edges.map((e) => e.toJson()).toList(),
      'groups': groups.map((g) => g.toJson()).toList(),
    });
  }

  int _stableSeed(String id) {
    var value = 0x811c9dc5;
    for (final unit in id.codeUnits) {
      value = ((value ^ unit) * 0x01000193) & 0x7fffffff;
    }
    return value;
  }

  bool loadGraph(String json, {bool silent = false}) {
    try {
      final data = jsonDecode(json);
      if (data is! Map ||
          data['format'] != 'syphon-graph' ||
          data['nodes'] is! List) {
        throw const FormatException('不是 SyphonNov 工作流文件');
      }
      final rawVersion = data['formatVersion'] ?? data['version'] ?? 1;
      if (rawVersion is! num ||
          rawVersion.toInt() < 1 ||
          rawVersion.toInt() > workflowFormatVersion) {
        throw FormatException('不支持的工作流格式版本: $rawVersion');
      }
      const vizMap = {
        'scatter': 'viz_scatter',
        'line': 'viz_line',
        'bar': 'viz_bar',
        'volcano': 'viz_volcano',
        'heatmap': 'viz_heatmap',
        'box': 'viz_box',
        'violin': 'viz_violin',
        'sankey': 'viz_sankey',
        'graph': 'viz_graph',
      };
      final loadedNodes = <GraphNode>[];
      final ids = <String>{};
      for (final raw in data['nodes'] as List) {
        if (raw is! Map) throw const FormatException('节点必须是对象');
        final n = Map<String, dynamic>.from(raw);
        final id = '${n['id'] ?? ''}'.trim();
        if (id.isEmpty || !ids.add(id)) {
          throw FormatException('节点 ID 为空或重复: $id');
        }
        var configId = '${n['configId'] ?? ''}';
        if (configId == 'plane_input' || configId == 'face_input') {
          throw const FormatException(
            '该工作流含已在 v0.4.1 删除的平面节点；请用曲面输入的平面预设重新建立该节点',
          );
        }
        if (configId == 'curve_intersect') configId = 'geometry_intersect';
        if (configId == 'viz_preset') {
          final p = n['params'] is Map ? n['params'] as Map : const {};
          configId = vizMap['${p['chartType'] ?? 'scatter'}'] ?? 'viz_scatter';
        }
        if (getConfig(configId) == null) {
          throw FormatException('未知节点类型: $configId');
        }
        final pos = n['position'];
        if (pos != null &&
            (pos is! Map || pos['x'] is! num || pos['y'] is! num)) {
          throw FormatException('节点 $id 的坐标无效');
        }
        final x = pos is Map ? (pos['x'] as num).toDouble() : 0.0;
        final y = pos is Map ? (pos['y'] as num).toDouble() : 0.0;
        if (!x.isFinite || !y.isFinite) {
          throw FormatException('节点 $id 的坐标不是有限数');
        }
        final params = n['params'] is Map
            ? Map<String, dynamic>.from(n['params'] as Map)
            : <String, dynamic>{};
        if (configId == 'table_input') {
          params.putIfAbsent('headerMode', () => 'auto');
        }
        if (configId == 'table_input' || configId == 'sample') {
          params.putIfAbsent('seed', () => _stableSeed(id));
        }
        loadedNodes.add(
          GraphNode(
            id: id,
            configId: configId,
            params: params,
            exposed: n['exposed'] is List
                ? (n['exposed'] as List).map((e) => '$e').toList()
                : const [],
            collapsed: n['collapsed'] == true,
            position: Offset(x, y),
          ),
        );
      }

      final byId = {for (final n in loadedNodes) n.id: n};
      final loadedEdges = <GraphEdge>[];
      final occupied = <String>{}, edgeIds = <String>{};
      for (final raw
          in data['edges'] is List ? data['edges'] as List : const []) {
        if (raw is! Map) throw const FormatException('连线必须是对象');
        final e = Map<String, dynamic>.from(raw);
        final id = '${e['id'] ?? ''}'.trim(),
            source = '${e['source'] ?? ''}',
            target = '${e['target'] ?? ''}';
        if (id.isEmpty || !edgeIds.add(id)) {
          throw FormatException('连线 ID 为空或重复: $id');
        }
        final sourceNode = byId[source], targetNode = byId[target];
        if (sourceNode == null || targetNode == null || source == target) {
          throw FormatException('连线 $id 引用了无效节点');
        }
        final sourceConfig = getConfig(sourceNode.configId)!,
            targetConfig = getConfig(targetNode.configId)!;
        final sourceHandle = e['sourceHandle'] == null
            ? (sourceConfig.outputs.isEmpty
                  ? null
                  : sourceConfig.outputs.first.id)
            : '${e['sourceHandle']}';
        final targetHandle = e['targetHandle'] == null
            ? (targetConfig.inputs.isEmpty
                  ? null
                  : targetConfig.inputs.first.id)
            : '${e['targetHandle']}';
        final outs = sourceConfig.outputs.where((s) => s.id == sourceHandle),
            ins = targetConfig.inputs.where((s) => s.id == targetHandle);
        if (outs.isEmpty ||
            ins.isEmpty ||
            !isCompatible(outs.first.type, ins.first.type)) {
          throw FormatException('连线 $id 的端口不存在或类型不兼容');
        }
        final portKey = '$target\u0000$targetHandle';
        if (ins.first.multi != true && !occupied.add(portKey)) {
          throw FormatException('非多连接端口 $targetHandle 收到多条连线');
        }
        final mid = e['mid'];
        Offset? midpoint;
        if (mid != null) {
          if (mid is! Map || mid['x'] is! num || mid['y'] is! num) {
            throw FormatException('连线 $id 的控制点无效');
          }
          midpoint = Offset(
            (mid['x'] as num).toDouble(),
            (mid['y'] as num).toDouble(),
          );
          if (!midpoint.dx.isFinite || !midpoint.dy.isFinite) {
            throw FormatException('连线 $id 的控制点不是有限数');
          }
        }
        loadedEdges.add(
          GraphEdge(
            id: id,
            source: source,
            target: target,
            sourceHandle: sourceHandle,
            targetHandle: targetHandle,
            mid: midpoint,
          ),
        );
      }
      final liteEdges = loadedEdges
          .map(
            (e) => GraphEdgeLite(
              source: e.source,
              target: e.target,
              sourceHandle: e.sourceHandle,
              targetHandle: e.targetHandle,
            ),
          )
          .toList();
      if (topoSort(loadedNodes.map((n) => n.id).toList(), liteEdges) == null) {
        final path = findCyclePath(
          loadedNodes.map((n) => n.id).toList(),
          liteEdges,
        );
        throw FormatException('工作流包含循环: ${path.join(' → ')}');
      }

      final loadedGroups = <NodeGroup>[];
      if (data['groups'] is List) {
        final groupIds = <String>{};
        for (final raw in data['groups'] as List) {
          if (raw is! Map) throw const FormatException('分组必须是对象');
          final group = NodeGroup.fromJson(Map<String, dynamic>.from(raw));
          if (group.id.isEmpty ||
              !groupIds.add(group.id) ||
              group.nodeIds.any((id) => !byId.containsKey(id))) {
            throw FormatException('分组 ${group.id} 无效');
          }
          loadedGroups.add(group);
        }
      }

      snapshotNow();
      nodes = loadedNodes;
      edges = loadedEdges;
      groups = loadedGroups;
      selectedId = null;
      multiSelected = {};
      results = {};
      hasCycle = false;
      lastError = null;
      structureVersion++;
      if (!silent) {
        addLog(
          'ok',
          '已加载 schema v$rawVersion 画布:${nodes.length} 个节点 / ${edges.length} 条连线',
        );
      }
      notifyListeners();
      if (autoRun) runPipeline();
      return true;
    } catch (e) {
      debugPrint('加载画布失败: $e');
      if (!silent) addLog('error', '加载失败:$e');
      return false;
    }
  }

  // ---------- 自动布局 ----------
  void autoLayout() {
    if (nodes.isEmpty) return;
    snapshotNow();
    final indeg = <String, int>{};
    final outAdj = <String, List<String>>{};
    final layer = <String, int>{};
    for (final n in nodes) {
      indeg[n.id] = 0;
      outAdj[n.id] = [];
      layer[n.id] = 0;
    }
    for (final e in edges) {
      if (!indeg.containsKey(e.target) || !outAdj.containsKey(e.source)) {
        continue;
      }
      indeg[e.target] = indeg[e.target]! + 1;
      outAdj[e.source]!.add(e.target);
    }
    final q = <String>[];
    for (final n in nodes) {
      if (indeg[n.id] == 0) q.add(n.id);
    }
    var head = 0;
    while (head < q.length) {
      final id = q[head++];
      final cur = layer[id]!;
      for (final t in outAdj[id]!) {
        layer[t] = math.max(layer[t]!, cur + 1);
        indeg[t] = indeg[t]! - 1;
        if (indeg[t] == 0) q.add(t);
      }
    }
    final byLayer = <int, List<String>>{};
    for (final n in nodes) {
      final l = layer[n.id] ?? 0;
      byLayer.putIfAbsent(l, () => []).add(n.id);
    }
    double estH(GraphNode n) {
      final cfg = getConfig(n.configId);
      if (cfg?.isViewer == true) return 400;
      final rows =
          (cfg?.inputs.length ?? 0) +
          (cfg?.outputs.length ?? 0) +
          n.exposed.length;
      return 100 + rows * 18;
    }

    final pos = <String, Offset>{};
    const gapX = 340.0;
    const gapY = 70.0;
    final layerHeights = <double>[];
    final layerWidths = <double>[];
    final maxLayer = byLayer.keys.fold<int>(0, (a, b) => a > b ? a : b);
    for (var l = 0; l <= maxLayer; l++) {
      final ids = byLayer[l] ?? [];
      var hSum = 0.0;
      for (final id in ids) {
        for (final n in nodes) {
          if (n.id == id) {
            hSum += estH(n);
            break;
          }
        }
      }
      layerHeights.add(hSum + math.max(0, ids.length - 1) * gapY);
      var w = 0.0;
      for (final id in ids) {
        for (final n in nodes) {
          if (n.id == id) {
            if (nodeWidth(n.configId) > w) w = nodeWidth(n.configId);
            break;
          }
        }
      }
      layerWidths.add(w);
    }
    var totalH = 0.0;
    for (final h in layerHeights) {
      totalH += h;
    }
    var yOffset = -totalH / 2;
    for (var l = 0; l <= maxLayer; l++) {
      final ids = byLayer[l] ?? [];
      final sorted = List<String>.of(ids);
      sorted.sort((a, b) {
        double ya = 0, yb = 0;
        for (final n in nodes) {
          if (n.id == a) ya = n.position.dy;
          if (n.id == b) yb = n.position.dy;
        }
        return ya.compareTo(yb);
      });
      var x = 0.0;
      for (var i = 0; i < l; i++) {
        x += layerWidths[i] + gapX;
      }
      final layerW = layerWidths[l] == 0 ? 260.0 : layerWidths[l];
      var y = yOffset;
      for (final id in sorted) {
        double w = 260;
        for (final n in nodes) {
          if (n.id == id) {
            w = nodeWidth(n.configId);
            pos[id] = Offset(x + (layerW - w) / 2, y);
            y += estH(n) + gapY;
            break;
          }
        }
      }
      yOffset += layerHeights[l] + gapY;
    }
    nodes = nodes.map((n) {
      final p = pos[n.id];
      return p == null ? n : n.copyWith(position: p);
    }).toList();
    notifyListeners();
  }

  // ---------- 执行 ----------

  /// 全量执行(清除所有结果,重算整张图)。
  void runPipeline() {
    results = {};
    hasCycle = false;
    lastError = null;
    _runDirty(null);
  }

  /// 增量执行:只重算 [dirtySeeds] 及其下游节点,未脏节点复用旧结果。
  void runPipelineDirty(Set<String> dirtySeeds) {
    _runDirty(dirtySeeds);
  }

  /// 从 [changedIds](节点增删/修改) + 连线变化(所有边视为 dirty) → 全图脏标记 → 执行。
  /// 节点删除时 changedIds 包含被删节点,但其下游节点仍标记为 dirty(因为连线变了)。
  void runAfterGraphChange({
    Set<String>? changedIds,
    bool edgeChanged = false,
  }) {
    if (results.isEmpty) {
      // 首次执行无旧结果可复用 → 全量
      runPipeline();
      return;
    }
    if (nodes.isEmpty) {
      results = {};
      hasCycle = false;
      lastError = null;
      return;
    }
    final seeds = <String>{};
    if (changedIds != null) {
      seeds.addAll(changedIds);
      // 节点被删或增后,其邻居也脏(边连接关系变了)
      for (final id in changedIds) {
        for (final e in edges) {
          if (e.source == id) seeds.add(e.target);
          if (e.target == id) seeds.add(e.source);
        }
      }
    }
    if (edgeChanged) {
      // 连线变更:所有边的 target 及其下游都脏
      for (final e in edges) {
        seeds.add(e.target);
      }
    }
    if (seeds.isEmpty) {
      // 没有明确的脏节点,保守全量
      runPipeline();
      return;
    }
    _runDirty(seeds);
  }

  // 执行任务链:多次触发串行排队,结果按触发顺序落定;
  // 测试可通过 settled 等待异步执行完成
  Future<void> _runChain = Future<void>.value();
  Isolate? _activeExecutionIsolate;

  /// 测试开关:false 时在主 Isolate 同步执行。
  /// (testWidgets 假异步事件循环不会派发 Isolate 消息,真实 Isolate 会挂起)
  static bool useIsolate = true;

  /// 等待所有已排队的执行任务完成
  Future<void> get settled => _runChain;

  /// 落定一次执行结果并广播
  void _applyOutcome(RunOutcome outcome, int revision) {
    if (revision != executionRevision) return;
    results = outcome.results;
    hasCycle = outcome.hasCycle;
    cyclePath = outcome.cyclePath;
    lastError = null;
    structuredError = null;
    if (outcome.hasCycle) {
      lastError = '工作流包含循环: ${outcome.cyclePath.join(' → ')}';
      structuredError = {
        'code': 'cycle',
        'message': lastError,
        'cyclePath': outcome.cyclePath,
      };
    }
    for (final r in outcome.results.entries) {
      if (r.value.error != null) {
        lastError = r.value.error;
        break;
      }
    }
    if (lastError != null && structuredError == null) {
      structuredError = {'code': 'node_execution', 'message': lastError};
    }
    committedRevision = revision;
    executionStatus = lastError == null ? 'succeeded' : 'failed';
    executionProgress = 1;
    executionCompletedNodes = outcome.order.length;
    executionTotalNodes = outcome.order.length;
    runVersion++;
    notifyListeners();
  }

  Future<void> _runDirty(Set<String>? dirtySeeds) {
    final revision = ++executionRevision;
    executionStatus = 'queued';
    executionProgress = 0;
    executionCompletedNodes = 0;
    executionTotalNodes = nodes.length;
    structuredError = null;
    const maxNodesPerRun = 10000;
    const maxEdgesPerRun = 50000;
    if (nodes.length > maxNodesPerRun || edges.length > maxEdgesPerRun) {
      executionStatus = 'failed';
      lastError =
          '工作流超过执行预算:节点 ${nodes.length}/$maxNodesPerRun，连线 ${edges.length}/$maxEdgesPerRun';
      structuredError = {
        'code': 'resource_budget',
        'message': lastError,
        'nodes': nodes.length,
        'edges': edges.length,
      };
      notifyListeners();
      return Future<void>.value();
    }
    // 触发时即固化输入(节点/边/旧结果快照):
    // 任务在 Isolate 中异步执行,排队期间图可能被继续修改
    final liteNodes = nodes
        .map(
          (n) =>
              GraphNodeLite(id: n.id, configId: n.configId, params: n.params),
        )
        .toList();
    final liteEdges = edges
        .map(
          (e) => GraphEdgeLite(
            source: e.source,
            target: e.target,
            sourceHandle: e.sourceHandle,
            targetHandle: e.targetHandle,
          ),
        )
        .toList();
    // 同步模式(测试):主 Isolate 直接执行,保持旧的同步语义
    if (!useIsolate) {
      _applyOutcome(
        runGraph(
          liteNodes,
          liteEdges,
          dirtyIds: dirtySeeds,
          prevResults: results,
        ),
        revision,
      );
      return Future<void>.value();
    }

    Future<void> task() async {
      if (revision != executionRevision) return;
      executionStatus = 'running';
      executionProgress = 0;
      notifyListeners();
      // Read predecessor results when the queued task actually starts. A
      // snapshot captured at enqueue time can overwrite a newer sibling.
      final previous = results;
      RunOutcome? outcome;
      final port = ReceivePort();
      Isolate? workerIsolate;
      try {
        final isolate = await Isolate.spawn(
          _runWorker,
          // A full latest-revision run is deliberate: it coalesces all dirty
          // edits that invalidated older queued partial snapshots.
          _RunWorkerRequest(
            _RunRequest(liteNodes, liteEdges, null, previous),
            port.sendPort,
          ),
          onExit: port.sendPort,
        );
        workerIsolate = isolate;
        _activeExecutionIsolate = isolate;
        await for (final message in port) {
          if (revision != executionRevision) {
            isolate.kill(priority: Isolate.immediate);
            break;
          }
          if (message == null) {
            if (outcome == null) throw StateError('后台执行意外终止');
            break;
          }
          if (message is! Map) continue;
          switch (message['kind']) {
            case 'progress':
              final completed = message['completed'] as int;
              final total = message['total'] as int;
              executionCompletedNodes = completed;
              executionTotalNodes = total;
              executionProgress = total == 0 ? 1 : completed / total;
              notifyListeners();
              break;
            case 'outcome':
              outcome = message['value'] as RunOutcome;
              break;
            case 'error':
              throw StateError('${message['message']}\n${message['stack']}');
          }
          if (outcome != null) break;
        }
      } catch (error, stack) {
        debugPrint('后台执行失败: $error\n$stack');
        if (revision == executionRevision) {
          executionStatus = 'failed';
          lastError = '$error';
          structuredError = {
            'code': 'isolate_failure',
            'message': '$error',
            'stack': '$stack',
          };
          notifyListeners();
        }
        return;
      } finally {
        port.close();
        if (identical(_activeExecutionIsolate, workerIsolate)) {
          _activeExecutionIsolate = null;
        }
        workerIsolate?.kill(priority: Isolate.immediate);
      }
      if (outcome != null) _applyOutcome(outcome, revision);
    }

    _runChain = _runChain.then((_) => task()).catchError((Object e) {
      addLog('error', '执行失败:$e');
    });
    return _runChain;
  }

  /// Logically cancels queued/running work. An isolate already computing may
  /// finish, but its obsolete revision is forbidden from committing results.
  void cancelExecution() {
    executionRevision++;
    _activeExecutionIsolate?.kill(priority: Isolate.immediate);
    _activeExecutionIsolate = null;
    executionStatus = 'cancelled';
    executionProgress = 0;
    executionCompletedNodes = 0;
    notifyListeners();
  }

  /// 运行单个节点及其全部下游(右键菜单"运行此节点")
  void runNodeAndDownstream(String nodeId) {
    if (nodes.every((n) => n.id != nodeId)) return;
    if (results.isEmpty) {
      runPipeline();
      return;
    }
    _runDirty({nodeId});
  }

  // ---------- 日志 ----------
  void addLog(String level, String msg) {
    final now = DateTime.now();
    final time =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    final entry = LogEntry(
      id: genId('log'),
      time: time,
      level: level,
      msg: msg,
    );
    logs = [...logs, entry];
    if (logs.length > 200) logs = logs.sublist(logs.length - 200);
    notifyListeners();
  }

  void clearLogs() {
    logs = [];
    notifyListeners();
  }

  /// 仅通知所有监听者刷新(用于 UI 直接改内部字段后)
  void touch() => notifyListeners();
}
