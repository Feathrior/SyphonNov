// 节点画布几何:节点尺寸、端口锚点、贝塞尔连线路径与命中检测(与 React 版布局保持一致)
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../models/data.dart';
import '../models/exec_engine.dart';
import '../models/registry.dart';
import '../store/graph_store.dart';

/// 节点卡片布局常量(与 React 版 styles.css 对应)
class NodeGeom {
  static const double headerH = 28;
  static const double bodyPadTop = 8;
  static const double bodyPadLeft = 12;
  static const double bodyPadRight = 12;
  static const double bodyPadBottom = 10;
  static const double socketGap = 5;
  static const double paramLineH = 20;
  static const double paramLineMargin = 7;
  static const double viewerH = 215; // 节点内预览窗高度
  static const double viewerMargin = 8;
  static const double outputsLineH = 14;
  static const double outputsLineMargin = 8;
  static const double collapsedPadTop = 6;
  static const double collapsedPadBottom = 8;
  static const double errorLineH = 30;
}

/// 端口圆角矩形高度:未连线/单连线为 11px;每多 1 条连线延长 10px,上限 64px
double handleH(int c) => c <= 1 ? 11 : math.min(64, 11 + (c - 1) * 10);

/// 端口行高
double rowH(int c) => math.max(18, handleH(c));

/// 画布缩放量的 InheritedWidget:节点卡片据此反向缩放边框/阴影,保持像素宽度恒定
class CanvasZoom extends InheritedNotifier<ValueNotifier<double>> {
  const CanvasZoom({
    super.key,
    required ValueNotifier<double> notifier,
    required super.child,
  }) : super(notifier: notifier);

  static double of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<CanvasZoom>()
          ?.notifier
          ?.value ??
      1.0;
}

/// 某端口上的连线数
int portCount(String nodeId, String? handleId, List<GraphEdge> edges) {
  if (handleId == null) return 0;
  var c = 0;
  for (final e in edges) {
    if (e.source == nodeId && e.sourceHandle == handleId) c++;
    if (e.target == nodeId && e.targetHandle == handleId) c++;
  }
  return c;
}

/// 端口悬停/激活状态(画布层命中检测后广播,卡片内 handle 据此播放强调动画)
class SocketHoverState {
  final String nodeId;
  final String socketId;
  final bool isSource;

  /// 命中端口与被拖拽端口类型不兼容,但 Alt 模式下可经转换节点连接
  final bool conversion;

  const SocketHoverState(
    this.nodeId,
    this.socketId,
    this.isSource, {
    this.conversion = false,
  });

  bool match(
    String nodeId,
    String socketId,
    bool isSource, {
    bool conversion = false,
  }) =>
      this.nodeId == nodeId &&
      this.socketId == socketId &&
      this.isSource == isSource &&
      this.conversion == conversion;

  @override
  bool operator ==(Object other) =>
      other is SocketHoverState &&
      other.nodeId == nodeId &&
      other.socketId == socketId &&
      other.isSource == isSource &&
      other.conversion == conversion;

  @override
  int get hashCode => Object.hash(nodeId, socketId, isSource, conversion);
}

/// 悬停广播值:active = 连线拖拽起点端口;hover = 当前悬停端口
typedef SocketHovers = ({SocketHoverState? active, SocketHoverState? hover});

/// 端口悬停状态广播(handle 溢出节点边缘,卡片内收不到指针事件,
/// 悬停/点击命中在画布层完成,通过本 InheritedNotifier 驱动卡片动画)
class CanvasSockets extends InheritedNotifier<ValueNotifier<SocketHovers>> {
  const CanvasSockets({
    super.key,
    required ValueNotifier<SocketHovers> notifier,
    required super.child,
  }) : super(notifier: notifier);

  static SocketHovers of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<CanvasSockets>()
          ?.notifier
          ?.value ??
      (active: null, hover: null);
}

/// 单行端口几何:y 为行顶(相对节点顶部),h 为行高
class SocketGeom {
  final String id;
  final double y;
  final double h;
  const SocketGeom(this.id, this.y, this.h);
  double get center => y + h / 2;
}

List<String> inputSocketIds(NodeConfig cfg, GraphNode node) => [
  ...cfg.inputs.map((s) => s.id),
  ...node.exposed.map((k) => 'exp_$k'),
];

/// 输入端口行(从节点顶部起算)
List<SocketGeom> inputSockets(GraphNode node, List<GraphEdge> edges) {
  final cfg = getConfig(node.configId);
  if (cfg == null) return [];
  return _rows(node, inputSocketIds(cfg, node), edges);
}

/// 输出端口行
List<SocketGeom> outputSockets(GraphNode node, List<GraphEdge> edges) {
  final cfg = getConfig(node.configId);
  if (cfg == null) return [];
  return _rows(node, cfg.outputs.map((s) => s.id).toList(), edges);
}

List<SocketGeom> _rows(
  GraphNode node,
  List<String> ids,
  List<GraphEdge> edges,
) {
  if (ids.isEmpty) return [];
  final start = node.collapsed ? NodeGeom.collapsedPadTop : NodeGeom.bodyPadTop;
  final out = <SocketGeom>[];
  var y = NodeGeom.headerH + start;
  for (var i = 0; i < ids.length; i++) {
    final id = ids[i];
    final h = rowH(portCount(node.id, id, edges));
    out.add(SocketGeom(id, y, h));
    y += h + NodeGeom.socketGap;
  }
  return out;
}

/// 参数摘要文本(取前 3 个非按钮参数的当前值)
String paramSummary(GraphNode node, NodeConfig cfg) {
  final keys = cfg.params
      .where((p) => p.type != 'button')
      .take(3)
      .map((p) => p.key)
      .toList();
  final parts = <String>[];
  for (final k in keys) {
    final v = node.params[k];
    if (v == null || v == '' || v == false) continue;
    if (v is Map || v is List) continue;
    if (v is String && v.startsWith('#')) continue;
    parts.add('$v');
  }
  return parts.join(' · ');
}

/// 节点尺寸(根据配置、折叠状态与端口连线数确定)
Size nodeSize(GraphNode node, List<GraphEdge> edges, {ExecResult? result}) {
  final cfg = getConfig(node.configId);
  final w = nodeVisualWidth(node);
  if (cfg == null) return Size(w, NodeGeom.headerH + 24);
  final inRows = inputSockets(node, edges);
  final outRows = outputSockets(node, edges);
  double colH = 0;
  if (inRows.isNotEmpty) {
    colH = math.max(colH, inRows.last.y + inRows.last.h - NodeGeom.headerH);
  }
  if (outRows.isNotEmpty) {
    colH = math.max(colH, outRows.last.y + outRows.last.h - NodeGeom.headerH);
  }
  double h = NodeGeom.headerH;
  if (node.collapsed) {
    h += NodeGeom.collapsedPadTop + colH + NodeGeom.collapsedPadBottom;
    return Size(w, h);
  }
  h += NodeGeom.bodyPadTop + colH;
  if (paramSummary(node, cfg).isNotEmpty) {
    h += NodeGeom.paramLineMargin + NodeGeom.paramLineH;
  }
  if (cfg.isViewer) {
    h += NodeGeom.viewerMargin + nodeViewerHeight(node);
  }
  if (cfg.outputs.isNotEmpty) {
    h += NodeGeom.outputsLineMargin + NodeGeom.outputsLineH;
  }
  h += NodeGeom.bodyPadBottom;
  if (result?.error != null) {
    h += NodeGeom.errorLineH;
  }
  return Size(w, h);
}

typedef PackagePort = ({
  String nodeId,
  String socketId,
  String name,
  SocketType type,
});

List<PackagePort> packageInputPorts(
  NodeGroup group,
  List<GraphNode> nodes,
  List<GraphEdge> edges,
) {
  final ids = group.nodeIds.toSet();
  final internallyConnected = {
    for (final edge in edges)
      if (ids.contains(edge.source) && ids.contains(edge.target))
        '${edge.target}\u0000${edge.targetHandle}',
  };
  final externallyConnected = {
    for (final edge in edges)
      if (!ids.contains(edge.source) && ids.contains(edge.target))
        '${edge.target}\u0000${edge.targetHandle}',
  };
  return [
    for (final node in nodes)
      if (ids.contains(node.id))
        for (final socket
            in getConfig(node.configId)?.inputs ?? const <Socket>[])
          if (!internallyConnected.contains('${node.id}\u0000${socket.id}') ||
              externallyConnected.contains('${node.id}\u0000${socket.id}'))
            (
              nodeId: node.id,
              socketId: socket.id,
              name:
                  '${getConfig(node.configId)?.label ?? node.configId} · ${socket.name}',
              type: socket.type,
            ),
  ];
}

List<PackagePort> packageOutputPorts(
  NodeGroup group,
  List<GraphNode> nodes,
  List<GraphEdge> edges,
) {
  final ids = group.nodeIds.toSet();
  final internallyConnected = {
    for (final edge in edges)
      if (ids.contains(edge.source) && ids.contains(edge.target))
        '${edge.source}\u0000${edge.sourceHandle}',
  };
  final externallyConnected = {
    for (final edge in edges)
      if (ids.contains(edge.source) && !ids.contains(edge.target))
        '${edge.source}\u0000${edge.sourceHandle}',
  };
  return [
    for (final node in nodes)
      if (ids.contains(node.id))
        for (final socket
            in getConfig(node.configId)?.outputs ?? const <Socket>[])
          if (!internallyConnected.contains('${node.id}\u0000${socket.id}') ||
              externallyConnected.contains('${node.id}\u0000${socket.id}'))
            (
              nodeId: node.id,
              socketId: socket.id,
              name:
                  '${getConfig(node.configId)?.label ?? node.configId} · ${socket.name}',
              type: socket.type,
            ),
  ];
}

Size packageNodeVisualSize(
  NodeGroup group,
  List<GraphNode> nodes,
  List<GraphEdge> edges,
) {
  final rows = math.max(
    packageInputPorts(group, nodes, edges).length,
    packageOutputPorts(group, nodes, edges).length,
  );
  return Size(260, math.max(110, 54 + rows * 22));
}

Rect? packageProxyRect(
  NodeGroup group,
  List<GraphNode> nodes,
  List<GraphEdge> edges,
) {
  if (!group.isPackage || !group.collapsed) return null;
  Rect? bounds;
  final ids = group.nodeIds.toSet();
  for (final node in nodes) {
    if (!ids.contains(node.id)) continue;
    final rect = node.position & nodeSize(node, edges);
    bounds = bounds == null ? rect : bounds.expandToInclude(rect);
  }
  return bounds == null
      ? null
      : bounds.topLeft & packageNodeVisualSize(group, nodes, edges);
}

Offset packagePortAnchor(
  Rect rect,
  List<PackagePort> ports,
  PackagePort port, {
  required bool isSource,
}) {
  final index = ports.indexWhere(
    (item) => item.nodeId == port.nodeId && item.socketId == port.socketId,
  );
  final y = rect.top + 43 + math.max(0, index) * 22;
  return Offset(isSource ? rect.right + 1.5 : rect.left - 1.5, y);
}

/// 将一组新节点从首选位置推出已有节点的占用范围。
///
/// 算法逐个求解最小轴向位移，并把已安置的新节点加入障碍集合。这样 Alt
/// 自动补出的转换链保持原有顺序，同时不会堆叠在已有节点或彼此之上。
Map<String, Offset> resolveRepulsiveNodeLayout({
  required List<({String id, Offset position, Size size})> moving,
  required Iterable<Rect> obstacles,
  double gap = 28,
  int maxIterations = 96,
}) {
  final occupied = obstacles.toList(growable: true);
  final result = <String, Offset>{};
  for (final item in moving) {
    var rect = item.position & item.size;
    for (var iteration = 0; iteration < maxIterations; iteration++) {
      Rect? hit;
      for (final obstacle in occupied) {
        if (rect.overlaps(obstacle.inflate(gap))) {
          hit = obstacle.inflate(gap);
          break;
        }
      }
      if (hit == null) break;
      final shifts = <Offset>[
        Offset(hit.left - rect.right, 0),
        Offset(hit.right - rect.left, 0),
        Offset(0, hit.top - rect.bottom),
        Offset(0, hit.bottom - rect.top),
      ]..sort((a, b) => a.distanceSquared.compareTo(b.distanceSquared));
      var shift = shifts.first;
      // 避免恰好贴边时因浮点误差下一轮仍被判为相交。
      if (shift.dx < 0) shift += const Offset(-0.01, 0);
      if (shift.dx > 0) shift += const Offset(0.01, 0);
      if (shift.dy < 0) shift += const Offset(0, -0.01);
      if (shift.dy > 0) shift += const Offset(0, 0.01);
      rect = rect.shift(shift);
    }
    result[item.id] = rect.topLeft;
    occupied.add(rect);
  }
  return result;
}

/// 连线端点(世界坐标)。多条连线共用端口时端点纵向均匀排开。
/// handle 11px 宽、溢出节点边缘 7px,锚点取 handle 中点:
/// 输出 = 节点右边缘 - 4 + 5.5 = 右 + 1.5;输入 = 节点左边缘 - 7 + 5.5 = 左 - 1.5
Offset edgeSourceAnchor(GraphEdge edge, GraphNode node, List<GraphEdge> edges) {
  final w = nodeVisualWidth(node);
  return Offset(
    node.position.dx + w + 1.5,
    node.position.dy + _anchorY(edge, node, edges, isSource: true),
  );
}

Offset edgeTargetAnchor(GraphEdge edge, GraphNode node, List<GraphEdge> edges) {
  return Offset(
    node.position.dx - 1.5,
    node.position.dy + _anchorY(edge, node, edges, isSource: false),
  );
}

double _anchorY(
  GraphEdge edge,
  GraphNode node,
  List<GraphEdge> edges, {
  required bool isSource,
}) {
  final rows = isSource
      ? outputSockets(node, edges)
      : inputSockets(node, edges);
  final handleId = isSource ? edge.sourceHandle : edge.targetHandle;
  SocketGeom? g;
  for (final r in rows) {
    if (r.id == handleId) {
      g = r;
      break;
    }
  }
  if (g == null) return nodeSize(node, edges).height / 2;
  final conns =
      edges
          .where(
            (e) => isSource
                ? (e.source == node.id && e.sourceHandle == handleId)
                : (e.target == node.id && e.targetHandle == handleId),
          )
          .toList()
        ..sort((a, b) => a.id.compareTo(b.id));
  final idx = conns.indexWhere((c) => c.id == edge.id);
  if (idx < 0) return g.center;
  final n = conns.length;
  final h = handleH(n);
  // handle 在行内垂直居中(行高 g.h ≥ handle 高 h),端点沿 handle 高度
  // "从上到下均匀分布"(两端各留 1 份间距);单连线时即 handle 正中央
  final handleTop = g.y + (g.h - h) / 2;
  return handleTop + h * (idx + 1) / (n + 1);
}

/// 三次贝塞尔曲线(源在右、目标在左,曲率 0.25,与 React Flow getBezierPath 一致)
Offset _cubic(Offset p0, Offset p1, Offset p2, Offset p3, double t) {
  final u = 1 - t;
  final a = u * u * u;
  final b = 3 * u * u * t;
  final c = 3 * u * t * t;
  final d = t * t * t;
  return Offset(
    a * p0.dx + b * p1.dx + c * p2.dx + d * p3.dx,
    a * p0.dy + b * p1.dy + c * p2.dy + d * p3.dy,
  );
}

Offset _c1(Offset a, Offset b) =>
    Offset(a.dx + (b.dx - a.dx).abs() * 0.25, a.dy);
Offset _c2(Offset a, Offset b) =>
    Offset(b.dx - (b.dx - a.dx).abs() * 0.25, b.dy);

/// 两点间贝塞尔采样点(right→left)
List<Offset> bezierSamples(Offset a, Offset b, {int n = 40}) {
  final p1 = _c1(a, b);
  final p2 = _c2(a, b);
  final out = <Offset>[];
  for (var i = 0; i <= n; i++) {
    out.add(_cubic(a, p1, p2, b, i / n));
  }
  return out;
}

/// 一条连线(可能含分割点)的整体采样点
List<Offset> edgeSamples({required Offset a, required Offset b, Offset? mid}) {
  if (mid == null) return bezierSamples(a, b);
  return [...bezierSamples(a, mid), ...bezierSamples(mid, b)];
}

/// 命中检测:点到连线路径最近距离
class EdgeHit {
  final Offset point;
  final double dist;
  const EdgeHit(this.point, this.dist);
}

EdgeHit? closestOnEdge({
  required Offset a,
  required Offset b,
  Offset? mid,
  required Offset p,
}) {
  final samples = edgeSamples(a: a, b: b, mid: mid);
  EdgeHit? best;
  for (final s in samples) {
    final d = (s - p).distance;
    if (best == null || d < best.dist) best = EdgeHit(s, d);
  }
  return best;
}
