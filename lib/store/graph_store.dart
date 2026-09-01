// 图状态管理(由 React 版 store/useGraph.ts 移植,采用 ChangeNotifier)
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../models/color_utils.dart';
import '../models/data.dart';
import '../models/exec_engine.dart';
import '../models/registry.dart';

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
    return GraphNode(
      id: n.id,
      configId: n.configId,
      params: jsonDecode(jsonEncode(n.params)) as Map<String, dynamic>,
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
  List<GraphNode> nodes = [];
  List<GraphEdge> edges = [];
  List<NodeGroup> groups = []; // 节点分组(Blender 风格,成员整体拖动)
  String? selectedId;
  Set<String> multiSelected = {}; // 多选节点集(Shift 点击/框选/分组)
  String? selectedSplitEdgeId;
  bool autoRun = true;
  int runVersion = 0;
  int structureVersion = 0;
  Map<String, ExecResult> results = {};
  bool hasCycle = false;
  String? lastError;
  List<LogEntry> logs = [];
  List<GraphSnapshot> past = [];
  List<GraphSnapshot> future = [];

  static final GraphStore instance = GraphStore._();
  GraphStore._();

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
  String addNode(String configId, Offset position) {
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
    if (autoRun) runPipeline();
    return node.id;
  }

  void addNodeDirect(GraphNode node) {
    nodes = [...nodes, node];
    selectedId = node.id;
    structureVersion++;
    notifyListeners();
  }

  void removeNodes(List<String> ids) {
    if (ids.isEmpty) return;
    snapshotNow();
    final setIds = ids.toSet();
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
    if (autoRun) runPipeline();
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
          params: jsonDecode(jsonEncode(n.params)) as Map<String, dynamic>,
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
    if (autoRun) runPipeline();
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
          params: jsonDecode(jsonEncode(n.params)) as Map<String, dynamic>,
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
          params: jsonDecode(jsonEncode(n.params)) as Map<String, dynamic>,
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
    notifyListeners();
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
    structureVersion++;
    notifyListeners();
    // 参数变化影响数据流:自动执行下立即重算(原理化输出等图据此实时刷新)
    if (autoRun) runPipeline();
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
    if (autoRun) runPipeline();
  }

  void toggleCollapse(String id) {
    snapshotNow();
    nodes = nodes.map((n) {
      if (n.id != id) return n;
      return n.copyWith(collapsed: !n.collapsed);
    }).toList();
    notifyListeners();
  }

  void onConnect({
    required String source,
    required String target,
    String? sourceHandle,
    String? targetHandle,
  }) {
    snapshotNow();
    GraphNode? srcNode;
    GraphNode? tnNode;
    for (final n in nodes) {
      if (n.id == source) srcNode = n;
      if (n.id == target) tnNode = n;
    }
    edges = [
      ...edges,
      GraphEdge(
        id: genId('e'),
        source: source,
        target: target,
        sourceHandle: sourceHandle,
        targetHandle: targetHandle,
      ),
    ];
    structureVersion++;
    addLog(
      'ok',
      '已连接 ${srcNode?.configId ?? ''} → ${tnNode?.configId ?? ''}(${targetHandle ?? 'in0'})',
    );
    // 连线变化改变数据流:自动执行下重算
    if (autoRun) runPipeline();
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
    structureVersion++;
    notifyListeners();
    // 切断连线后自动执行,下游不再残留旧结果
    if (autoRun) runPipeline();
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
    // 撤销/重做改变图结构:自动执行下重算,恢复后的图立即可见
    if (autoRun) runPipeline();
  }

  // ---------- 保存/加载 ----------
  String saveGraph() {
    return const JsonEncoder.withIndent('  ').convert({
      'format': 'syphon-graph',
      'version': 1,
      'nodes': nodes.map((n) => n.toJson()).toList(),
      'edges': edges.map((e) => e.toJson()).toList(),
      'groups': groups.map((g) => g.toJson()).toList(),
    });
  }

  bool loadGraph(String json, {bool silent = false}) {
    try {
      final data = jsonDecode(json);
      if (data is! Map ||
          data['format'] != 'syphon-graph' ||
          data['nodes'] is! List) {
        return false;
      }
      snapshotNow();
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
      for (final raw in data['nodes'] as List) {
        final n = raw is Map
            ? Map<String, dynamic>.from(raw)
            : <String, dynamic>{};
        var configId = '${n['configId'] ?? ''}';
        // 旧版"面输入"(3D 网格)已改为"平面输入":加载旧画布时迁移
        if (configId == 'face_input') configId = 'plane_input';
        if (configId == 'viz_preset') {
          final params = n['params'] is Map ? n['params'] as Map : const {};
          final ct = '${params['chartType'] ?? 'scatter'}';
          configId = vizMap[ct] ?? 'viz_scatter';
        }
        final pos = n['position'];
        loadedNodes.add(
          GraphNode(
            id: '${n['id'] ?? ''}',
            configId: configId,
            params: n['params'] is Map
                ? Map<String, dynamic>.from(n['params'] as Map)
                : <String, dynamic>{},
            exposed: n['exposed'] is List
                ? (n['exposed'] as List).map((e) => '$e').toList()
                : [],
            collapsed: n['collapsed'] == true,
            position: pos is Map
                ? Offset(
                    (pos['x'] is num) ? (pos['x'] as num).toDouble() : 0,
                    (pos['y'] is num) ? (pos['y'] as num).toDouble() : 0,
                  )
                : Offset.zero,
          ),
        );
      }
      final loadedEdges = <GraphEdge>[];
      final rawEdges = data['edges'] is List
          ? data['edges'] as List
          : <dynamic>[];
      for (final raw in rawEdges) {
        final e = raw is Map
            ? Map<String, dynamic>.from(raw)
            : <String, dynamic>{};
        final m = e['mid'];
        loadedEdges.add(
          GraphEdge(
            id: '${e['id'] ?? genId('e')}',
            source: '${e['source'] ?? ''}',
            target: '${e['target'] ?? ''}',
            sourceHandle: e['sourceHandle'] == null
                ? null
                : '${e['sourceHandle']}',
            targetHandle: e['targetHandle'] == null
                ? null
                : '${e['targetHandle']}',
            mid: m is Map && m['x'] is num
                ? Offset((m['x'] as num).toDouble(), (m['y'] as num).toDouble())
                : null,
          ),
        );
      }
      nodes = loadedNodes;
      edges = loadedEdges;
      // 兼容旧画布文件(无 groups 字段):分组默认为空
      final rawGroups = data['groups'];
      groups = rawGroups is List
          ? rawGroups
                .map(
                  (raw) => raw is Map
                      ? NodeGroup.fromJson(Map<String, dynamic>.from(raw))
                      : null,
                )
                .whereType<NodeGroup>()
                .toList()
          : [];
      selectedId = null;
      multiSelected = {};
      results = {};
      hasCycle = false;
      lastError = null;
      structureVersion++;
      if (!silent) {
        addLog('ok', '已加载画布:${nodes.length} 个节点 / ${edges.length} 条连线');
      }
      notifyListeners();
      // 加载/预设替换画布后自动执行,图表立即出图
      if (autoRun) runPipeline();
      return true;
    } catch (e) {
      debugPrint('加载画布失败: $e');
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
  void runPipeline() {
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
    final outcome = runGraph(liteNodes, liteEdges);
    results = outcome.results;
    hasCycle = outcome.hasCycle;
    lastError = null;
    for (final r in outcome.results.entries) {
      if (r.value.error != null) {
        lastError = r.value.error;
        break;
      }
    }
    runVersion++;
    notifyListeners();
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
