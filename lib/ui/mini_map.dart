// 迷你缩略预览窗(MiniMap):位于画布右下角的全局概览,展示全部节点/连线与当前视口范围
// (由 React 版 src/ui/NodeCanvas.tsx 的 <MiniMap> 移植)
library;

import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../models/color_utils.dart';
import '../models/registry.dart';
import '../store/graph_store.dart';
import 'canvas_geometry.dart';
import 'theme.dart';

/// 缩略图尺寸(与 React 版 MiniMap 的 180x120 一致)
const double kMiniMapWidth = 180;
const double kMiniMapHeight = 120;

/// 世界边界外扩的 padding
const double _kMiniMapPad = 20;

/// 世界坐标 → 迷你图坐标的映射参数
typedef _MiniLayout = ({Rect bbox, double scale, Offset offset, Rect? vp});

/// 迷你缩略预览窗
class MiniMapView extends StatefulWidget {
  final List<GraphNode> nodes; // 全部节点
  final double zoom; // 当前画布缩放
  final Offset pan; // 当前画布平移
  final Size viewport; // 画布视口尺寸(屏幕像素)
  final List<GraphEdge> edges; // 全部连线
  /// 画布平移更新回调(预览窗内拖拽改变视口位置);null 时预览窗仅展示
  final ValueChanged<Offset>? onPanChanged;
  /// 预览窗拖拽结束回调(画布层据此解除交互守卫)
  final VoidCallback? onPanEnd;

  const MiniMapView({
    super.key,
    required this.nodes,
    required this.zoom,
    required this.pan,
    required this.viewport,
    required this.edges,
    this.onPanChanged,
    this.onPanEnd,
  });

  @override
  State<MiniMapView> createState() => _MiniMapViewState();
}

class _MiniMapViewState extends State<MiniMapView> {
  Offset? _panStartLocal; // 拖拽起点(迷你图坐标)
  Offset? _panStartValue; // 拖拽开始时的画布 pan

  void _onPanStart(DragStartDetails d) {
    if (widget.onPanChanged == null) return;
    _panStartLocal = d.localPosition;
    _panStartValue = widget.pan;
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final start = _panStartLocal;
    final base = _panStartValue;
    final cb = widget.onPanChanged;
    if (start == null || base == null || cb == null) return;
    // 与绘制共用同一布局计算(节点 + 视口 bbox,含 scale 钳制),
    // 基于拖拽起点 pan 计算 → 拖拽期间映射保持线性
    final L = _MiniPainter.computeLayout(
      widget.nodes,
      widget.edges,
      zoom: widget.zoom,
      pan: base,
      viewport: widget.viewport,
    );
    if (L.scale <= 0) return;
    // 视口矩形跟随鼠标:拖 Δ(迷你图 px)→ 世界位移 Δ/scale → pan 反向移动 Δ*zoom/scale
    cb(base - (d.localPosition - start) * (widget.zoom / L.scale));
  }

  void _endPan() {
    _panStartLocal = null;
    _panStartValue = null;
  }

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    // 高斯模糊毛玻璃:BackdropFilter 模糊预览窗背后的画布内容,
    // ClipRRect 限制模糊范围在圆角面板内(与背景圆角 8 一致)
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: widget.onPanChanged == null ? null : _onPanStart,
          onPanUpdate: widget.onPanChanged == null ? null : _onPanUpdate,
          onPanEnd: widget.onPanChanged == null
              ? null
              : (_) {
                  _endPan();
                  widget.onPanEnd?.call();
                },
          onPanCancel: widget.onPanChanged == null
              ? null
              : () {
                  _endPan();
                  widget.onPanEnd?.call();
                },
          child: CustomPaint(
            size: const Size(kMiniMapWidth, kMiniMapHeight),
            painter: _MiniPainter(
              nodes: widget.nodes,
              edges: widget.edges,
              zoom: widget.zoom,
              pan: widget.pan,
              viewport: widget.viewport,
              isDark: t.isDark,
              accent: t.accent,
              stroke: t.stroke,
              flowEdge: t.flowEdge,
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniPainter extends CustomPainter {
  final List<GraphNode> nodes;
  final List<GraphEdge> edges;
  final double zoom;
  final Offset pan;
  final Size viewport;
  final bool isDark;
  final Color accent;
  final Color stroke;
  final Color flowEdge;

  const _MiniPainter({
    required this.nodes,
    required this.edges,
    required this.zoom,
    required this.pan,
    required this.viewport,
    required this.isDark,
    required this.accent,
    required this.stroke,
    required this.flowEdge,
  });

  /// 统一布局计算:节点 bbox ∪ 视口矩形 → 等比缩放 + 居中偏移;
  /// 绘制与拖拽换算共用同一结果,保证两者一致。
  ///
  /// 钳制:视口世界尺寸 = 画布/zoom,缩小(zoom<1)时会远大于节点群,
  /// 纳入 bbox 会把 scale 拉低到节点不可见 —— 因此 scale 不低于
  /// 节点-only scale 的 55%,视口矩形伸出面板的部分被圆角裁剪(仍指示方向)。
  static _MiniLayout computeLayout(
    List<GraphNode> nodes,
    List<GraphEdge> edges, {
    required double zoom,
    required Offset pan,
    required Size viewport,
  }) {
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    for (final n in nodes) {
      final s = nodeSize(n, edges);
      minX = math.min(minX, n.position.dx);
      minY = math.min(minY, n.position.dy);
      maxX = math.max(maxX, n.position.dx + s.width);
      maxY = math.max(maxY, n.position.dy + s.height);
    }
    // 无节点时使用默认 0~400 区域
    if (nodes.isEmpty) {
      minX = 0;
      minY = 0;
      maxX = 400;
      maxY = 400;
    }
    final nodesBbox = Rect.fromLTRB(
      minX - _kMiniMapPad,
      minY - _kMiniMapPad,
      maxX + _kMiniMapPad,
      maxY + _kMiniMapPad,
    );
    final nodesScale = math.min(
      kMiniMapWidth / nodesBbox.width,
      kMiniMapHeight / nodesBbox.height,
    );

    // 当前屏幕可视区域的世界坐标;zoom/viewport 无效时忽略(不纳入 bbox、不绘制)
    Rect? vp;
    if (zoom > 0 && viewport.isFinite && viewport.width > 0 && viewport.height > 0) {
      vp = Rect.fromLTWH(
        -pan.dx / zoom,
        -pan.dy / zoom,
        viewport.width / zoom,
        viewport.height / zoom,
      );
    }

    var bbox = nodesBbox;
    if (vp != null) bbox = nodesBbox.expandToInclude(vp);
    var scale = math.min(kMiniMapWidth / bbox.width, kMiniMapHeight / bbox.height);
    final floor = nodesScale * 0.55;
    if (scale < floor) scale = floor;

    // bbox 等比缩放后居中映射到 180x120 画布
    final offset = Offset(
      (kMiniMapWidth - bbox.width * scale) / 2,
      (kMiniMapHeight - bbox.height * scale) / 2,
    );
    return (bbox: bbox, scale: scale, offset: offset, vp: vp);
  }

  /// 世界坐标 → 迷你图坐标
  Offset _map(Offset p, _MiniLayout L) => (p - L.bbox.topLeft) * L.scale + L.offset;

  @override
  void paint(Canvas canvas, Size size) {
    final L = computeLayout(nodes, edges, zoom: zoom, pan: pan, viewport: viewport);
    final rrect = RRect.fromRectAndRadius(
        Offset.zero & size, const Radius.circular(8));

    // 背景:半透明 surface 色(暗色 0xCC1F1F1F / 亮色 0xCCFFFFFF),1px 描边,圆角 8
    canvas.drawRRect(
      rrect,
      Paint()..color = isDark ? const Color(0xCC1F1F1F) : const Color(0xCCFFFFFF),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = stroke,
    );
    // 绘制内容裁剪在面板圆角内
    canvas.clipRRect(rrect);

    // 无节点时只画背景
    if (nodes.isEmpty) return;

    final nodeMap = {for (final n in nodes) n.id: n};

    // 连线:源/目标节点中心连 1px 细线(flowEdge 色,透明度 0.6)
    final edgePaint = Paint()
      ..strokeWidth = 1
      ..color = flowEdge.withValues(alpha: 0.6);
    for (final e in edges) {
      final src = nodeMap[e.source];
      final dst = nodeMap[e.target];
      if (src == null || dst == null) continue;
      final srcSize = nodeSize(src, edges);
      final dstSize = nodeSize(dst, edges);
      canvas.drawLine(
        _map(src.position + Offset(srcSize.width / 2, srcSize.height / 2), L),
        _map(dst.position + Offset(dstSize.width / 2, dstSize.height / 2), L),
        edgePaint,
      );
    }

    // 节点:分类色圆角矩形(圆角 2px),宽高 = nodeSize * scale
    final nodePaint = Paint();
    for (final n in nodes) {
      final cfg = getConfig(n.configId);
      final colorHex = cfg == null ? null : kCatInfo[cfg.category.name]?.color;
      nodePaint.color = parseColor(colorHex, const Color(0xFF888888));
      final s = nodeSize(n, edges);
      final rect = Rect.fromLTWH(
        _map(n.position, L).dx,
        _map(n.position, L).dy,
        s.width * L.scale,
        s.height * L.scale,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        nodePaint,
      );
    }

    // 视口矩形:相当于屏幕大小的一块区域,灰色半透明填充 + 灰边,
    // 绘制在预览窗最上层,指示当前屏幕位置(40% 灰填充,底下节点仍可透见);
    // bbox 已纳入视口且 scale 有下限 → 屏幕区域始终可见、节点不会缩成不可见
    final vp = L.vp;
    if (vp != null) {
      final tl = _map(vp.topLeft, L);
      final miniVp = Rect.fromLTWH(
        tl.dx,
        tl.dy,
        vp.width * L.scale,
        vp.height * L.scale,
      );
      canvas.drawRect(
        miniVp,
        Paint()..color = const Color(0x66808080),
      );
      canvas.drawRect(
        miniVp,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = const Color(0xCCB0B0B0),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MiniPainter old) =>
      old.nodes != nodes ||
      old.edges != edges ||
      old.zoom != zoom ||
      old.pan != pan ||
      old.viewport != viewport ||
      old.isDark != isDark ||
      old.accent != accent ||
      old.stroke != stroke ||
      old.flowEdge != flowEdge;
}
