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

  const SocketHoverState(this.nodeId, this.socketId, this.isSource);

  bool match(String nodeId, String socketId, bool isSource) =>
      this.nodeId == nodeId &&
      this.socketId == socketId &&
      this.isSource == isSource;

  @override
  bool operator ==(Object other) =>
      other is SocketHoverState &&
      other.nodeId == nodeId &&
      other.socketId == socketId &&
      other.isSource == isSource;

  @override
  int get hashCode => Object.hash(nodeId, socketId, isSource);
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
  final w = nodeWidth(node.configId);
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
    h += NodeGeom.viewerMargin + NodeGeom.viewerH;
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

/// 连线端点(世界坐标)。多条连线共用端口时端点纵向均匀排开。
/// handle 11px 宽、溢出节点边缘 7px,锚点取 handle 中点:
/// 输出 = 节点右边缘 - 4 + 5.5 = 右 + 1.5;输入 = 节点左边缘 - 7 + 5.5 = 左 - 1.5
Offset edgeSourceAnchor(GraphEdge edge, GraphNode node, List<GraphEdge> edges) {
  final w = nodeWidth(node.configId);
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
