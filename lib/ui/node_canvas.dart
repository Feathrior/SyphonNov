// 节点画布:平移/缩放/节点拖拽/连线拖拽/右键菜单/框选/Alt拆分/Ctrl切断/Shift插入/分割点拖动
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart'
    show
        PointerScrollEvent,
        PointerSignalEvent,
        kPrimaryButton,
        kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';

import '../models/data.dart';
import '../models/registry.dart';
import '../store/graph_store.dart';
import 'canvas_geometry.dart';
import 'context_menu.dart';
import 'mini_map.dart';
import 'node_card.dart';
import 'theme.dart';

// ==================== 背景网格 ====================

class _BgPainter extends CustomPainter {
  final Color bg;
  final Color dot;
  final Offset pan; // 屏幕平移量
  final double zoom; // 当前缩放
  const _BgPainter({
    required this.bg,
    required this.dot,
    required this.pan,
    required this.zoom,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (zoom <= 0 || size.isEmpty) return;
    // 视口左上角在 flow 坐标中的位置;网格锚定在世界原点(flow 坐标 0),覆盖整个可见区域,
    // 平移时无缝跟随、缩放时屏幕间距保持 22px
    final originX = -pan.dx / zoom;
    final originY = -pan.dy / zoom;
    final endX = originX + size.width / zoom;
    final endY = originY + size.height / zoom;
    // 背景色同样用 flow 坐标覆盖整个可见区域:本 painter 位于 Transform 内,
    // 若只画 (0,0,size) 会被平移/缩放带出视口,露出外层底色(深色模式下出现浅色矩形)
    canvas.drawRect(
      Rect.fromLTRB(originX, originY, endX, endY),
      Paint()..color = bg,
    );
    final dotPaint = Paint()..color = dot;
    // 点阵屏幕间距 22px 恒定(React Background gap=22);本 painter 绘制在 Transform(已乘 zoom)
    // 内部,故 flow 间距 = 22/zoom、点直径 1.7 → flow 半径 = 0.85/zoom
    final step = 22.0 / zoom;
    final r = 0.85 / zoom;
    for (
      var x = (originX / step).floorToDouble() * step;
      x <= endX;
      x += step
    ) {
      for (
        var y = (originY / step).floorToDouble() * step;
        y <= endY;
        y += step
      ) {
        canvas.drawCircle(Offset(x, y), r, dotPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BgPainter old) =>
      old.bg != bg || old.dot != dot || old.pan != pan || old.zoom != zoom;
}

// ==================== 连线绘制 ====================

class _Conn {
  final String nodeId;
  final String socketId;
  final SocketType type;
  final bool isSource;
  final Offset anchor;

  const _Conn(
    this.nodeId,
    this.socketId,
    this.type,
    this.isSource,
    this.anchor,
  );
}

// ==================== 切断粒子爆裂(模仿水果忍者) ====================

/// 单颗爆裂粒子:初始位置由爆裂原点决定,速度/尺寸为 flow 单位
/// (生成时按 zoom 折算,保证屏幕上看起来屏幕恒定)。
class _Particle {
  final Offset vel; // flow 单位/秒(方向 + 速率)
  final double size; // 半径(flow)
  final Color color;

  const _Particle({required this.vel, required this.size, required this.color});
}

/// 一次切断的粒子爆裂:原点 + 粒子束 + 重力 + 起始时刻(驱动 450ms 扩散淡出动画)
class _ParticleBurst {
  final Offset origin; // flow 坐标
  final List<_Particle> particles;
  final double g; // 重力加速度(flow 单位/秒²,向下为正)
  final DateTime at;

  const _ParticleBurst({
    required this.origin,
    required this.particles,
    required this.g,
    required this.at,
  });
}

class _EdgesPainter extends CustomPainter {
  final List<GraphEdge> edges;
  final List<NodeGroup> groups; // 分组框(Blender 风格):边框 + 名称标签
  final String? hoverEdge;
  final String? altSplitEdge;
  final Offset? altSplitPoint;
  final String? insertPreviewEdge;
  final Offset? insertPreviewPoint;
  // 切断粒子爆裂(水果忍者式):每次切断一颗,各带独立动画进度
  final List<({_ParticleBurst burst, double progress})> liveBursts;
  final _Conn? connecting;
  final Offset? connectPos;
  final String? selectedSplitEdgeId;
  final int revision;
  final Color flowEdge;
  final Color accent;
  final bool isDark; // 亮色模式下连线颜色压暗一档(避免鲜艳色刺眼)
  final double zoom; // 当前缩放:Transform 内绘制,所有标记尺寸除以 zoom 保持屏幕恒定
  // 切水果刀光:划过轨迹点(flow 坐标)与整体淡出进度 0~1
  final List<Offset> slashTrail;
  final double slashTrailProgress;
  final Map<String, GraphNode> nodeMap; // 节点 id → 节点(由 nodes 派生,绘制时查询用)

  // 预计算锚点:edgeId → (源锚点, 目标锚点)。
  // 一次性遍历节点端口统计,避免逐边重复 O(E) 扫描(连线多时性能关键)
  late final Map<String, ({Offset a, Offset b})> _anchors;

  _EdgesPainter({
    required List<GraphNode> nodes,
    required this.edges,
    required this.groups,
    this.hoverEdge,
    this.altSplitEdge,
    this.altSplitPoint,
    this.insertPreviewEdge,
    this.insertPreviewPoint,
    this.liveBursts = const [],
    this.connecting,
    this.connectPos,
    this.selectedSplitEdgeId,
    required this.revision,
    required this.flowEdge,
    required this.accent,
    required this.isDark,
    required this.zoom,
    this.slashTrail = const [],
    this.slashTrailProgress = 1,
  }) : nodeMap = {for (final n in nodes) n.id: n} {
    _initAnchors();
  }

  /// 预计算每条连线的端点锚点(世界坐标):按端口分组统计连接,
  /// 端点沿 handle 高度从上到下均匀分布(与 _anchorY 公式一致)
  void _initAnchors() {
    _anchors = <String, ({Offset a, Offset b})>{};
    for (final n in nodeMap.values) {
      final cfg = getConfig(n.configId);
      if (cfg == null) continue;
      final w = nodeWidth(n.configId);
      final inRows = inputSockets(n, edges);
      final outRows = outputSockets(n, edges);
      // 输出锚点(源)
      for (final row in outRows) {
        final conns =
            edges
                .where((e) => e.source == n.id && e.sourceHandle == row.id)
                .toList()
              ..sort((a, b) => a.id.compareTo(b.id));
        if (conns.isEmpty) continue;
        final h = handleH(conns.length);
        final top = row.y + (row.h - h) / 2;
        for (var i = 0; i < conns.length; i++) {
          final y = top + h * (i + 1) / (conns.length + 1);
          final a = Offset(n.position.dx + w + 1.5, n.position.dy + y);
          final prev = _anchors[conns[i].id];
          _anchors[conns[i].id] = (a: a, b: prev?.b ?? Offset.zero);
        }
      }
      // 输入锚点(目标)
      for (final row in inRows) {
        final conns =
            edges
                .where((e) => e.target == n.id && e.targetHandle == row.id)
                .toList()
              ..sort((a, b) => a.id.compareTo(b.id));
        if (conns.isEmpty) continue;
        final h = handleH(conns.length);
        final top = row.y + (row.h - h) / 2;
        for (var i = 0; i < conns.length; i++) {
          final y = top + h * (i + 1) / (conns.length + 1);
          final b = Offset(n.position.dx - 1.5, n.position.dy + y);
          final prev = _anchors[conns[i].id];
          _anchors[conns[i].id] = (a: prev?.a ?? Offset.zero, b: b);
        }
      }
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    // 分组框在最底层(连线/节点之上被遮挡部分自然隐藏,标签始终可见)
    _paintGroupFrames(canvas);
    for (final e in edges) {
      final src = nodeMap[e.source];
      final tgt = nodeMap[e.target];
      if (src == null || tgt == null) continue;
      _paintEdge(canvas, e, src, tgt);
    }
    // 连线拖拽中:三次贝塞尔曲线预览(与正式连线同曲率,虚线区分)
    if (connecting != null && connectPos != null) {
      final samples = bezierSamples(connecting!.anchor, connectPos!);
      if (samples.length >= 2) {
        _drawDashedPath(canvas, samples, flowEdge, 2, dash: [6, 4]);
        _drawArrow(
          canvas,
          samples[samples.length - 2],
          samples.last,
          8,
          flowEdge,
        );
      }
    }
    // Alt 拆分预览点
    if (altSplitEdge != null && altSplitPoint != null) {
      _paintAltSplitDot(canvas, altSplitPoint!);
    }
    // Shift 插入预览(圆点 + “插入”标签)
    if (insertPreviewEdge != null && insertPreviewPoint != null) {
      _paintInsertPreview(canvas, insertPreviewPoint!);
    }
    // 切断粒子爆裂(水果忍者果肉迸溅,扩散 + 淡出)
    if (liveBursts.isNotEmpty) {
      _paintBursts(canvas);
    }
    // 切水果刀光(白色渐变光带,随轨迹渐隐)
    if (slashTrail.length >= 2 && slashTrailProgress < 1) {
      _paintSlashTrail(canvas);
    }
  }

  void _paintEdge(Canvas canvas, GraphEdge e, GraphNode src, GraphNode tgt) {
    final anchor = _anchors[e.id];
    final a = anchor?.a ?? edgeSourceAnchor(e, src, edges);
    final b = anchor?.b ?? edgeTargetAnchor(e, tgt, edges);
    final mid = e.mid;
    final samples = edgeSamples(a: a, b: b, mid: mid);
    if (samples.length < 2) return;

    // 基础连线色 = 源端口颜色(与 React buildEdgeProps 的 SOCKET_COLOR 一致)
    var color = _edgeColor(e, src);
    if (!isDark) {
      // 亮色模式:明度压低一档,连线更沉稳不刺眼
      final hsv = HSVColor.fromColor(color);
      color = hsv.withValue(hsv.value * 0.82).toColor();
    }
    var width = 2.2;
    if (e.id == hoverEdge) {
      // 普通悬停:accent 色
      color = accent;
      width = 3.6;
    }
    if (e.id == altSplitEdge) {
      // Alt 拆分悬停:紫(React #8b5cf6)
      color = const Color(0xFF8B5CF6);
      width = 5.0;
    }
    if (e.id == insertPreviewEdge) {
      // Shift 拖拽插入目标:橙(对应 React cutHighlight #f59e0b)
      color = const Color(0xFFF59E0B);
      width = 5.0;
    }
    if (e.id == selectedSplitEdgeId) {
      // 选中分割点的连线:accent 色
      color = accent;
      width = 3.6;
    }

    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..style = PaintingStyle.stroke;
    final path = Path()..moveTo(samples.first.dx, samples.first.dy);
    for (final p in samples.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, paint);

    // 末端箭头:与连线同色(React ArrowClosed 15×15,取 14)
    _drawArrow(canvas, samples[samples.length - 2], samples.last, 14, color);

    // 分割点小圆点:与连线同色 + 白描边,选中时额外光环(与 React edges.tsx 一致);
    // 尺寸除以 zoom 保持屏幕恒定
    if (mid != null) {
      if (e.id == selectedSplitEdgeId) {
        canvas.drawCircle(
          mid,
          9 / zoom,
          Paint()
            ..color = color.withValues(alpha: 0.65)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5 / zoom,
        );
      }
      canvas.drawCircle(mid, 3.5 / zoom, Paint()..color = color);
      canvas.drawCircle(
        mid,
        3.5 / zoom,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6 / zoom,
      );
    }
  }

  /// 连线基础色 = 源端口颜色(kSocketColor 映射);找不到端口时回退 React 默认色 #7c8db5
  Color _edgeColor(GraphEdge e, GraphNode src) {
    final cfg = getConfig(src.configId);
    if (cfg != null) {
      for (final o in cfg.outputs) {
        if (o.id == e.sourceHandle) {
          final hex = kSocketColor[o.type];
          if (hex != null) return _colorFromHex(hex);
        }
      }
    }
    return const Color(0xFF7C8DB5);
  }

  /// #RRGGBB → Color
  Color _colorFromHex(String hex) {
    var h = hex.replaceFirst('#', '');
    if (h.length == 6) h = 'FF$h';
    return Color(int.tryParse(h, radix: 16) ?? 0xFF000000);
  }

  /// 分组外框(Blender 风格):包围所有成员的圆角矩形 + 名称标签。
  /// 尺寸除以 zoom 保持屏幕恒定;底噪小,分组数量少,无需单独图层
  void _paintGroupFrames(Canvas canvas) {
    if (groups.isEmpty) return;
    final pad = 14.0 / zoom;
    final stroke = Paint()
      ..color = accent.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2 / zoom;
    final fill = Paint()..color = accent.withValues(alpha: 0.05);
    for (final g in groups) {
      // 成员包围盒
      Rect? box;
      for (final id in g.nodeIds) {
        final n = nodeMap[id];
        if (n == null) continue;
        final r = n.position & nodeSize(n, edges);
        box = box == null ? r : box.expandToInclude(r);
      }
      // 分组默认包含组内节点之间所有连线的断点:包围盒扩展到断点,
      // 保证凸出到成员包围盒之外的断点也落在分组框内(与 _groupRect 一致)
      final inGroup = g.nodeIds.toSet();
      for (final e in edges) {
        final mid = e.mid;
        if (mid == null) continue;
        if (!inGroup.contains(e.source) || !inGroup.contains(e.target)) {
          continue;
        }
        box = box == null
            ? Rect.fromCircle(center: mid, radius: 0)
            : box.expandToInclude(Rect.fromCircle(center: mid, radius: 0));
      }
      if (box == null) continue;
      final rect = Rect.fromLTRB(
        box.left - pad,
        box.top - pad,
        box.right + pad,
        box.bottom + pad,
      );
      final rrect = RRect.fromRectAndRadius(rect, Radius.circular(10 / zoom));
      canvas.drawRRect(rrect, fill);
      canvas.drawRRect(rrect, stroke);
      // 名称标签:框顶中央小圆角胶囊
      final tp = TextPainter(
        text: TextSpan(
          text: g.name,
          style: TextStyle(
            color: Colors.white,
            fontSize: 10 / zoom,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final chipW = tp.width + 14 / zoom;
      final chipH = tp.height + 6 / zoom;
      final chipRect = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(rect.center.dx, rect.top - chipH / 2),
          width: chipW,
          height: chipH,
        ),
        Radius.circular(chipH / 2),
      );
      canvas.drawRRect(
        chipRect,
        Paint()..color = accent.withValues(alpha: 0.92),
      );
      tp.paint(
        canvas,
        Offset(rect.center.dx - tp.width / 2, chipRect.top + 3 / zoom),
      );
    }
  }

  /// Alt 拆分预览点:12px 白底圆 + 2px 紫边 + 外圈光晕(React .nf-alt-split-dot)
  void _paintAltSplitDot(Canvas canvas, Offset p) {
    final r = 6.0 / zoom;
    final bw = 2.0 / zoom;
    // 外圈光晕 rgba(139,92,246,0.25)
    canvas.drawCircle(
      p,
      r + bw,
      Paint()
        ..color = const Color(0xFF8B5CF6).withValues(alpha: 0.25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = bw,
    );
    canvas.drawCircle(p, r, Paint()..color = Colors.white);
    canvas.drawCircle(
      p,
      r,
      Paint()
        ..color = const Color(0xFF8B5CF6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = bw,
    );
  }

  /// Shift 插入预览:14px 白底圆 + 2.5px accent 边 + 外圈光晕 + 下方“插入”标签
  /// (React .nf-insert-dot / .nf-insert-label)
  void _paintInsertPreview(Canvas canvas, Offset p) {
    final r = 7.0 / zoom;
    final bw = 2.5 / zoom;
    final glow = 3.0 / zoom;
    // 外圈光晕 rgba(0,103,192,0.22)(与 React CSS 硬编码一致)
    canvas.drawCircle(
      p,
      r + glow,
      Paint()
        ..color = const Color(0x380067C0)
        ..style = PaintingStyle.stroke
        ..strokeWidth = glow,
    );
    canvas.drawCircle(p, r, Paint()..color = Colors.white);
    canvas.drawCircle(
      p,
      r,
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = bw,
    );
    // 下方“插入”标签:accent 底白字 10px,圆角 4px
    final tp = TextPainter(
      text: TextSpan(
        text: '插入',
        style: TextStyle(color: Colors.white, fontSize: 10 / zoom),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final labelW = tp.width + 12 / zoom;
    final labelH = tp.height + 2 / zoom;
    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(p.dx, p.dy + r + 3 / zoom + labelH / 2),
        width: labelW,
        height: labelH,
      ),
      Radius.circular(4 / zoom),
    );
    canvas.drawRRect(rect, Paint()..color = accent);
    tp.paint(canvas, Offset(p.dx - tp.width / 2, rect.top + 1 / zoom));
  }

  /// 切断粒子爆裂:每次切断的粒子束各自沿方向飞散,
  /// 受重力向下弯曲;开头保持近不透明(更显眼),随后线性淡出 + 半径收缩
  void _paintBursts(Canvas canvas) {
    final paint = Paint();
    for (final lb in liveBursts) {
      final t = lb.progress.clamp(0.0, 1.0).toDouble();
      // 前 14% 完全不透明,之后线性淡出到 0(比原曲线更显眼)
      final fade = t < 0.14 ? 1.0 : ((1 - t) / 0.86).clamp(0.0, 1.0);
      for (final p in lb.burst.particles) {
        final pos =
            lb.burst.origin +
            p.vel * t +
            Offset(0, 0.5 * lb.burst.g * t * t); // 重力:½gt² 向下
        paint.color = p.color.withValues(alpha: fade);
        canvas.drawCircle(pos, p.size * (1 - 0.4 * t), paint);
      }
    }
  }

  /// 切水果刀光:沿轨迹绘制渐变光带,头部亮白、尾部淡出,宽度随轨迹衰减
  void _paintSlashTrail(Canvas canvas) {
    final pts = slashTrail;
    if (pts.length < 2) return;
    final fade = (1 - slashTrailProgress).clamp(0.0, 1.0).toDouble();
    // 轨迹整体淡出:最近的点(末尾)最亮,越远越暗
    for (var i = 0; i < pts.length - 1; i++) {
      final f = i / (pts.length - 2); // 0=最旧 → 1=最新
      final alpha = (0.05 + 0.5 * f) * fade;
      if (alpha <= 0.005) continue;
      final width = (1.5 + 4.0 * f) / zoom;
      final paint = Paint()
        ..color = Colors.white.withValues(alpha: alpha)
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(pts[i], pts[i + 1], paint);
    }
    // 刀尖:最新点处一圈亮白高光
    final tip = pts.last;
    final tipAlpha = 0.9 * fade;
    if (tipAlpha > 0.01) {
      canvas.drawCircle(
        tip,
        3.5 / zoom,
        Paint()
          ..color = Colors.white.withValues(alpha: tipAlpha * 0.4)
          ..style = PaintingStyle.fill,
      );
    }
  }

  /// 沿采样点路径绘制虚线(用于三次贝塞尔连线预览)
  void _drawDashedPath(
    Canvas canvas,
    List<Offset> samples,
    Color color,
    double width, {
    List<double> dash = const [6, 4],
  }) {
    if (samples.length < 2) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..style = PaintingStyle.stroke;
    final path = Path();
    var idx = 0;
    var drawing = true;
    path.moveTo(samples.first.dx, samples.first.dy);
    // 沿折线段累计长度切分 dash 段
    var seg = samples.first;
    void emit(Offset p) {
      if (drawing) {
        path.lineTo(p.dx, p.dy);
      } else {
        path.moveTo(p.dx, p.dy);
      }
    }

    for (var i = 1; i < samples.length; i++) {
      final next = samples[i];
      final d = (next - seg).distance;
      if (d <= 0) continue;
      var remain = d;
      while (remain > 0) {
        final segLen = math.min(dash[idx], remain);
        final f = segLen / d;
        final p = Offset(
          seg.dx + (next.dx - seg.dx) * f,
          seg.dy + (next.dy - seg.dy) * f,
        );
        emit(p);
        remain -= segLen;
        idx = (idx + 1) % dash.length;
        drawing = !drawing;
        seg = p;
      }
    }
    canvas.drawPath(path, paint);
  }

  void _drawArrow(
    Canvas canvas,
    Offset p1,
    Offset p2,
    double size,
    Color color,
  ) {
    final ang = math.atan2(p2.dy - p1.dy, p2.dx - p1.dx);
    final path = Path()
      ..moveTo(p2.dx, p2.dy)
      ..lineTo(
        p2.dx - size * math.cos(ang - 0.42),
        p2.dy - size * math.sin(ang - 0.42),
      )
      ..lineTo(
        p2.dx - size * math.cos(ang + 0.42),
        p2.dy - size * math.sin(ang + 0.42),
      )
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _EdgesPainter old) =>
      old.nodeMap != nodeMap ||
      old.edges != edges ||
      old.groups != groups ||
      old.revision != revision ||
      old.zoom != zoom ||
      old.isDark != isDark ||
      old.slashTrailProgress != slashTrailProgress ||
      old.slashTrail != slashTrail ||
      old.hoverEdge != hoverEdge ||
      old.altSplitEdge != altSplitEdge ||
      old.altSplitPoint != altSplitPoint ||
      old.insertPreviewEdge != insertPreviewEdge ||
      old.insertPreviewPoint != insertPreviewPoint ||
      old.liveBursts != liveBursts ||
      old.selectedSplitEdgeId != selectedSplitEdgeId ||
      old.connecting != connecting ||
      old.connectPos != connectPos;
}

// ==================== 画布 ====================

class NodeCanvas extends StatefulWidget {
  final bool boxSelect;
  final void Function()? onRequestAddNode;
  const NodeCanvas({super.key, this.boxSelect = false, this.onRequestAddNode});

  @override
  State<NodeCanvas> createState() => NodeCanvasState();
}

class NodeCanvasState extends State<NodeCanvas>
    with SingleTickerProviderStateMixin {
  final GraphStore store = GraphStore.instance;
  final ValueNotifier<double> _zoomNotifier = ValueNotifier(1);
  final FocusNode _focusNode = FocusNode();

  // 切断粒子爆裂动画:每帧刷新直到动画结束
  late final Ticker _cutTicker;
  final List<_ParticleBurst> _bursts = []; // 一次手势可爆出多次(每次切断追加一颗)

  double _zoom = 1;
  Offset _pan = Offset.zero;
  int _revision = 0;
  Size _canvasSize = Size.zero; // 画布视口尺寸(画布层 LayoutBuilder 捕获,预览窗换算屏幕区域用)

  // 预览窗(MiniMap)交互:GlobalKey 定位面板全局矩形,
  // 预览窗在画布 Listener 子树内,指针事件会冒泡 → down/up/move 需按矩形跳过画布逻辑
  final GlobalKey _miniMapKey = GlobalKey();
  bool _miniMapDragging = false; // 预览窗拖拽进行中(拖出面板松开时仍能正确守卫)

  /// 指针全局坐标是否落在预览窗面板内(4px 容差)
  bool _inMiniMap(Offset globalPos) {
    final ctx = _miniMapKey.currentContext;
    if (ctx == null) return false;
    final ro = ctx.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return false;
    final rect = ro.localToGlobal(Offset.zero) & ro.size;
    return rect.inflate(4).contains(globalPos);
  }

  // 交互状态
  String? _draggingId; // 主拖动节点(Shift 插入连线预览仅单节点拖动时启用)
  Set<String> _dragIds = {}; // 本次手势实际移动的节点集(单节点/多选/分组)
  Map<String, Offset> _dragOrigins = {}; // 各拖动节点按下时的世界坐标(位移基准)
  bool _downAddedNode = false; // 本次按下是否把节点新加入多选(down 与 tap 共用,防重复切换)
  bool _dragSnapshotted = false; // 本次拖动是否已记录撤销快照(首次实际位移时才记录)
  int _downButtons = 0; // 本次按下包含的鼠标按钮(区分左/右键 up:右键不触发空白清选)
  bool _spaceDown = false;
  bool _panFromNode = false; // 背景 pan 起点落在节点内部:忽略平移(节点内拖动不移动背景)
  String? _hoverEdge;
  String? _altSplitEdge;
  Offset? _altSplitPoint;
  String? _insertPreviewEdge;
  Offset? _insertPreviewPoint;
  // 切水果刀光:记录 Ctrl 拖拽划过画布的轨迹点(flow 坐标),用于绘制渐隐光带
  final List<Offset> _slashTrail = [];
  DateTime _slashTrailAt = DateTime.now();
  // 鼠标划过速度(flow 单位/秒):由最近几次移动采样测得,作为粒子初速度
  final List<({Offset pos, DateTime t})> _motionSamples = [];
  Offset _swipeVel = Offset.zero;
  String? _draggingMidEdge;
  // Alt 划线加断点:按住 Alt 拖拽,划过每条连线自动添加分割点
  bool _altSweeping = false;
  final Set<String> _altSweptEdges = {}; // 本次手势已加断点的连线
  Offset? _lastAltSweepFlow; // 上一次扫过点(段插值捕捉快速滑动)
  bool _altJustSplit = false; // 本次手势创建过断点(松开时不取消选中)
  _Conn? _connecting;
  Offset? _connectFlowPos;
  Offset? _connectDownScreen; // 连线按下时的屏幕坐标(区分"点击"与"拖拽连线")
  // 端口悬停/连线激活广播(handle 溢出节点边缘,命中在画布层完成后广播给卡片动画)
  final ValueNotifier<SocketHovers> _sockHover = ValueNotifier<SocketHovers>((
    active: null,
    hover: null,
  ));
  Offset? _menuPos;
  _Conn? _pendingConn;
  Set<String>? _nodeMenuFor; // 多选右键菜单对应的节点集(与 _menuPos 配合)
  String? _groupMenuFor; // 分组右键菜单对应的分组 id(与 _menuPos 配合)

  // 分组标签双击重命名检测(双击 = 两次快速按下标签)
  DateTime? _lastGroupLabelDownAt;
  String? _lastGroupLabelDownId;
  Offset _lastGroupLabelDownFlow = Offset.zero;
  // 鼠标最后位置(flow 坐标):Ctrl+V 粘贴定位用(hover/move 时更新)
  Offset _lastPointerFlow = Offset.zero;
  Offset? _boxStart; // 屏幕坐标
  Offset? _boxEnd;
  Offset? _downPosScreen;
  bool _boxDragging = false;

  bool get _ctrl => HardwareKeyboard.instance.isControlPressed;
  bool get _alt => HardwareKeyboard.instance.isAltPressed;
  bool get _shift => HardwareKeyboard.instance.isShiftPressed;

  Offset _toFlow(Offset screen) =>
      Offset((screen.dx - _pan.dx) / _zoom, (screen.dy - _pan.dy) / _zoom);

  Offset _toScreen(Offset flow) =>
      Offset(flow.dx * _zoom + _pan.dx, flow.dy * _zoom + _pan.dy);

  void _bump() {
    _revision++;
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    // 切断粒子爆裂/刀光动画:每帧刷新直到动画全部结束(渲染层,不改交互逻辑)
    _cutTicker = createTicker((_) {
      if (!mounted) return;
      final now = DateTime.now();
      final burstAlive = _bursts.any(
        (b) => now.difference(b.at).inMilliseconds < 450,
      );
      final trailAlive =
          _slashTrail.isNotEmpty &&
          now.difference(_slashTrailAt).inMilliseconds < 300;
      if (!burstAlive && !trailAlive) {
        _cutTicker.stop();
        if (_bursts.isNotEmpty) {
          _bursts.clear();
          _bump();
        }
        if (_slashTrail.isNotEmpty) {
          _slashTrail.clear();
          _bump();
        }
        return;
      }
      _bump();
    });
  }

  // ---------------- 节点卡片回调 ----------------

  /// 单击选中 / Shift+单击切换多选。
  /// 注意:节点选择在 pointer-down(_onBackgroundDown)已先落定(保证拖动立即生效):
  /// - 非 Shift:点击已选节点保持多选(Blender 语义),点击未选节点重置单选
  /// - Shift:down 已新加入多选的节点,此处跳过(防 down 加选 → tap 再切换互相抵消)
  void _onSelect(String id) {
    if (_shift) {
      if (_downAddedNode) return; // down 已加入多选,点击/拖动共用,不重复处理
      final sel = store.multiSelected;
      if (sel.contains(id)) {
        store.setMultiSelected({...sel}..remove(id));
      } else {
        store.setMultiSelected({...sel, id});
      }
    } else if (!_downAddedNode && !store.multiSelected.contains(id)) {
      // 非 Shift:选择已在 down 落定。仅兜底 down 未命中的边界(如菜单拦截),
      // 避免 tap 重复重置把"点击已选节点保持的多选"清掉
      store.setMultiSelected({id});
    }
    if (store.selectedSplitEdgeId != null) store.selectSplitEdge(null);
  }

  bool _pointInAnyNode(Offset flow) {
    for (final n in store.nodes) {
      final r = n.position & nodeSize(n, store.edges);
      if (r.contains(flow)) return true;
    }
    return false;
  }

  /// 节点拖拽(画布层统一管理,绕开手势竞技场)
  /// 按下:命中节点时记录 _draggingId/_dragIds/_dragOrigins(_onBackgroundDown)
  /// 移动/松开:画布级 Listener 跟踪(_onBackgroundMove/_onBackgroundUp),
  /// 以各节点按下坐标为基准累计位移,坐标恒为画布局部,与节点卡片重建无关
  /// 拖动移动:绝对定位 —— 各节点目标 = 按下坐标 + 累计位移。
  /// 每次 move 均以按下原点为基准(不叠加历史位移),节点 1:1 跟随鼠标
  void _onNodeDragTo(String id, Offset flowPos) {
    if (_draggingId != id) return;
    final origin = _dragOrigins[id];
    if (origin == null) return;
    final delta = flowPos - origin; // 累计位移(相对按下原点)
    if (delta == Offset.zero) return;
    if (!_dragSnapshotted) {
      // 首次实际位移才记录撤销快照(单击选中不产生快照,不污染撤销历史)
      _dragSnapshotted = true;
      store.snapshotNow();
    }
    // 目标位置 = 各拖动节点按下坐标 + 统一累计位移(绝对定位,整组同步跟随)
    store.moveNodesTo(_dragIds, {
      for (final nid in _dragIds) nid: _dragOrigins[nid]! + delta,
    });
    // Shift 插入连线预览仅在单节点拖动时启用(整组插入无意义)
    if (_shift && _dragIds.length == 1) {
      _updateInsertPreview(id);
    } else {
      _insertPreviewEdge = null;
      _insertPreviewPoint = null;
    }
  }

  void _onNodeDragEnd(String id, {required bool single}) {
    _draggingId = null;
    _dragIds = {};
    _dragOrigins = {};
    _dragSnapshotted = false;
    if (_shift && single && _insertPreviewEdge != null) {
      _insertNodeIntoEdge(id, _insertPreviewEdge!);
    }
    _insertPreviewEdge = null;
    _insertPreviewPoint = null;
    _bump();
  }

  /// 开始节点拖动:记录参与移动的节点集与其世界坐标原点。
  /// Blender 语义 —— 拖动只移动当前选中集(分组为组织容器,不强制整组跟随;
  /// 全选组内节点时自然整体移动)
  void _startNodeDrag(Set<String> sel) {
    if (sel.isEmpty) return;
    _draggingId = sel.first;
    _dragIds = {...sel};
    _dragOrigins = {for (final id in _dragIds) id: _nodePos(id)};
    _dragSnapshotted = false;
  }

  Offset _nodePos(String id) {
    for (final n in store.nodes) {
      if (n.id == id) return n.position;
    }
    return Offset.zero;
  }

  // ---------------- 分组几何(与 _EdgesPainter._paintGroupFrames 一致) ----------------

  /// 分组包围盒:成员矩形 + 组内连线断点 + 14px/zoom 内边距(世界坐标;
  /// 与 _EdgesPainter._paintGroupFrames 一致)
  Rect? _groupRect(NodeGroup g) {
    Rect? box;
    for (final id in g.nodeIds) {
      for (final n in store.nodes) {
        if (n.id == id) {
          final r = n.position & nodeSize(n, store.edges);
          box = box == null ? r : box.expandToInclude(r);
          break;
        }
      }
    }
    // 分组默认包含组内节点之间所有连线的断点(与绘制层一致)
    final inGroup = g.nodeIds.toSet();
    for (final e in store.edges) {
      final mid = e.mid;
      if (mid == null) continue;
      if (!inGroup.contains(e.source) || !inGroup.contains(e.target)) continue;
      box = box == null
          ? Rect.fromCircle(center: mid, radius: 0)
          : box.expandToInclude(Rect.fromCircle(center: mid, radius: 0));
    }
    if (box == null) return null;
    final pad = 14.0 / _zoom;
    return Rect.fromLTRB(
      box.left - pad,
      box.top - pad,
      box.right + pad,
      box.bottom + pad,
    );
  }

  /// 返回包含 flow 点的分组 id(整个分组框内部,右键解散分组用)
  String? _groupAt(Offset flow) {
    for (final g in store.groups) {
      final r = _groupRect(g);
      if (r != null && r.contains(flow)) return g.id;
    }
    return null;
  }

  /// 命中分组顶部名称标签(蓝色胶囊,含屏幕 6px 边距)—— 拖拽标签整体移动分组
  String? _groupLabelAt(Offset flow) {
    for (final g in store.groups) {
      final rect = _groupRect(g);
      if (rect == null) continue;
      final tp = TextPainter(
        text: TextSpan(
          text: g.name,
          style: TextStyle(fontSize: 10 / _zoom, fontWeight: FontWeight.w600),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final chipW = tp.width + 14 / _zoom;
      final chipH = tp.height + 6 / _zoom;
      final m = 6.0 / _zoom;
      final chip = Rect.fromCenter(
        center: Offset(rect.center.dx, rect.top - chipH / 2),
        width: chipW + 2 * m,
        height: chipH + 2 * m,
      );
      if (chip.contains(flow)) return g.id;
    }
    return null;
  }

  void _updateInsertPreview(String draggedId) {
    final n = store.nodes.firstWhere((x) => x.id == draggedId);
    final center = n.position + nodeSize(n, store.edges).center(Offset.zero);
    final hit = _hitEdgeAt(center, threshold: 56 / _zoom);
    final nextEdge = hit?.edge.id;
    final nextPoint = hit?.hit.point;
    // 仅在预览状态变化时触发重建,拖动中不重复 setState(性能关键)
    if (nextEdge != _insertPreviewEdge || nextPoint != _insertPreviewPoint) {
      _insertPreviewEdge = nextEdge;
      _insertPreviewPoint = nextPoint;
      _bump();
    }
  }

  void _insertNodeIntoEdge(String draggedId, String edgeId) {
    final e = store.edges.firstWhere((x) => x.id == edgeId);
    final node = store.nodes.firstWhere((x) => x.id == draggedId);
    final cfg = getConfig(node.configId);
    if (cfg == null || cfg.inputs.isEmpty || cfg.outputs.isEmpty) return;
    if (e.source == draggedId || e.target == draggedId) return;
    store.snapshotNow();
    store.edges = store.edges.where((x) => x.id != edgeId).toList();
    store.edges = [
      ...store.edges,
      GraphEdge(
        id: genId('e'),
        source: e.source,
        target: draggedId,
        sourceHandle: e.sourceHandle,
        targetHandle: cfg.inputs.first.id,
      ),
      GraphEdge(
        id: genId('e'),
        source: draggedId,
        target: e.target,
        sourceHandle: cfg.outputs.first.id,
        targetHandle: e.targetHandle,
      ),
    ];
    store.structureVersion++;
    store.addLog('ok', '已将节点插入连线');
    store.touch();
    if (store.autoRun) store.runPipeline();
  }

  // ---------------- 连线拖拽 ----------------
  // 起点:画布层 handle 命中(_onBackgroundDown → _handleAt → _onConnectStart)
  // 拖动/松开:画布级 Listener(_onBackgroundMove/_onBackgroundUp)统一跟踪,
  // 坐标恒为画布局部,与卡片重建无关

  void _onConnectStart(
    String id,
    bool isSource,
    String socketId,
    SocketType type,
    Offset anchor,
  ) {
    _connecting = _Conn(id, socketId, type, isSource, anchor);
    _connectFlowPos = anchor;
    _connectDownScreen = null; // 首次 move 时记录
    // 广播激活状态:起点端口播放脉冲强调动画
    _sockHover.value = (
      active: SocketHoverState(id, socketId, isSource),
      hover: null,
    );
    store.selectNode(id);
    _bump();
  }

  /// 连线松开:命中兼容端口 → 建边;空白处 → 弹出新建节点菜单并携带待连线
  void _finishConnect(_Conn conn, Offset flowPos) {
    final target = _findSocketAt(flowPos, conn);
    if (target != null) {
      if (conn.isSource) {
        store.onConnect(
          source: conn.nodeId,
          target: target.nodeId,
          sourceHandle: conn.socketId,
          targetHandle: target.socketId,
        );
      } else {
        store.onConnect(
          source: target.nodeId,
          target: conn.nodeId,
          sourceHandle: target.socketId,
          targetHandle: conn.socketId,
        );
      }
      if (store.autoRun) store.runPipeline();
    } else {
      // 空白处松开:弹出新建节点菜单并携带待连线
      _menuPos = _toScreen(flowPos);
      _pendingConn = conn;
    }
    _bump();
  }

  ({
    String nodeId,
    String socketId,
    bool isSource,
    SocketType type,
    Offset anchor,
  })?
  _findSocketAt(Offset flowPos, _Conn conn) {
    final threshold = 26 / _zoom;
    ({
      String nodeId,
      String socketId,
      bool isSource,
      SocketType type,
      Offset anchor,
    })?
    best;
    var bestDist = threshold;
    for (final n in store.nodes) {
      if (n.id == conn.nodeId) continue;
      final cfg = getConfig(n.configId);
      if (cfg == null) continue;
      final isTargetInput = conn.isSource; // 源为输出 → 目标为输入;反之输出
      final rows = isTargetInput
          ? inputSockets(n, store.edges)
          : outputSockets(n, store.edges);
      final socks = isTargetInput ? cfg.inputs : cfg.outputs;
      if (rows.length != socks.length) continue;
      for (var i = 0; i < rows.length; i++) {
        // 目标端口位置 = handle 中点(与起点锚点一致:输入 左-1.5 / 输出 右+1.5)
        final pos = Offset(
          n.position.dx + (isTargetInput ? -1.5 : nodeWidth(n.configId) + 1.5),
          n.position.dy + rows[i].center,
        );
        final d = (pos - flowPos).distance;
        if (d < bestDist && isCompatible(conn.type, socks[i].type)) {
          bestDist = d;
          best = (
            nodeId: n.id,
            socketId: rows[i].id,
            isSource: !isTargetInput,
            type: socks[i].type,
            anchor: pos,
          );
        }
      }
    }
    return best;
  }

  void _onSecondaryTap(String id) {
    // 多选(≥2)状态下右键所选节点:弹出分组/批量操作菜单(Blender 风格)
    final sel = store.multiSelected;
    if (sel.contains(id) && sel.length > 1) {
      _nodeMenuFor = {...sel};
      _menuPos = _toScreen(_nodePos(id)); // 从节点左上角弹出
      _bump();
      return;
    }
    store.toggleCollapse(id);
    _bump();
  }

  // ---------------- Alt 划线加断点 ----------------
  // 按住 Alt 拖拽:光标经过的每条连线自动添加分割点(单次手势内每条连线只加一个)

  void _startAltSweep(Offset flow) {
    _altSweeping = true;
    _altSweptEdges.clear();
    _altJustSplit = false;
    _lastAltSweepFlow = flow;
    // 清除悬停预览点,避免划线过程中残留紫色标记
    _altSplitEdge = null;
    _altSplitPoint = null;
  }

  void _addAltSplit(GraphEdge e, Offset point) {
    if (_altSweptEdges.contains(e.id)) return;
    if (e.mid != null) return; // 已有断点的连线不重复添加(避免覆盖原断点)
    _altSweptEdges.add(e.id);
    store.updateEdgeData(e.id, point);
    if (store.selectedSplitEdgeId != e.id) store.selectSplitEdge(e.id);
    _altJustSplit = true;
  }

  // ---------------- 端口 handle 命中检测(画布层) ----------------
  // handle 溢出节点边缘 7px,卡片内 Padding/Column 各层命中测试会裁剪越界子级,
  // 卡片内挂 Listener/MouseRegion 收不到事件,故悬停/点击命中统一在画布层完成

  SocketType _socketTypeOf(
    GraphNode n,
    String socketId, {
    required bool isSource,
  }) {
    final cfg = getConfig(n.configId);
    if (cfg == null) return SocketType.any;
    final list = isSource ? cfg.outputs : cfg.inputs;
    for (final s in list) {
      if (s.id == socketId) return s.type;
    }
    return SocketType.any;
  }

  /// 世界坐标下命中端口 handle(与卡片视觉位置一致:输入柄 x∈[-7,+4],输出柄 x∈[W-4,W+7])
  ({
    String nodeId,
    String socketId,
    bool isSource,
    SocketType type,
    Offset anchor,
  })?
  _handleAt(Offset flow) {
    const hw = 11.0; // handle 宽
    final m = 5.0 / _zoom; // 屏幕恒定 5px 命中边距
    // 逆序遍历:后绘制的节点位于图层上方,其端口判定区优先(与渲染顺序一致)
    for (final n in store.nodes.reversed) {
      final size = nodeSize(n, store.edges);
      for (final s in inputSockets(n, store.edges)) {
        final hh = handleH(portCount(n.id, s.id, store.edges));
        // 命中区 = handle 视觉本体(左 -7 ~ +4)+ 外部 5px 边距,不深入节点内部,
        // 避免点击节点左侧想拖动时误触发连线预览线"乱飞"
        final rect = Rect.fromLTWH(
          n.position.dx - 7 - m,
          n.position.dy + s.center - hh / 2 - m,
          hw + m,
          hh + 2 * m,
        );
        if (rect.contains(flow)) {
          return (
            nodeId: n.id,
            socketId: s.id,
            isSource: false,
            type: _socketTypeOf(n, s.id, isSource: false),
            // 锚点 = handle 中点(handle 宽 11、溢出边缘 7 → 左 - 1.5)
            anchor: Offset(n.position.dx - 1.5, n.position.dy + s.center),
          );
        }
      }
      for (final s in outputSockets(n, store.edges)) {
        final hh = handleH(portCount(n.id, s.id, store.edges));
        // 命中区 = handle 视觉本体(左 size.width-4 ~ +12)+ 外部 5px 边距,
        // 不深入节点内部,避免点击节点右侧想拖动时误触发连线预览线"乱飞"
        final rect = Rect.fromLTWH(
          n.position.dx + size.width - 4,
          n.position.dy + s.center - hh / 2 - m,
          hw + m,
          hh + 2 * m,
        );
        if (rect.contains(flow)) {
          return (
            nodeId: n.id,
            socketId: s.id,
            isSource: true,
            type: _socketTypeOf(n, s.id, isSource: true),
            // 锚点 = handle 中点(handle 宽 11、溢出边缘 7 → 右 + 1.5)
            anchor: Offset(
              n.position.dx + size.width + 1.5,
              n.position.dy + s.center,
            ),
          );
        }
      }
    }
    return null;
  }

  /// 悬停更新:端口优先(卡片动画),其次连线悬停高亮(Alt 拆分预览/普通高亮)
  void _updateHover(Offset local) {
    final flow = _toFlow(local);
    _lastPointerFlow = flow; // Ctrl+V 粘贴定位
    final h = _handleAt(flow);
    final cur = _sockHover.value;
    // 连线拖拽中保留 active(起点端口脉冲),仅更新 hover(候选目标端口)
    final hover = h == null
        ? null
        : SocketHoverState(h.nodeId, h.socketId, h.isSource);
    if (cur.hover != hover) {
      _sockHover.value = (active: cur.active, hover: hover);
    }
    if (h != null) {
      // 悬停端口时清除连线悬停高亮,避免视觉混杂
      if (_hoverEdge != null || _altSplitEdge != null) {
        _hoverEdge = null;
        _altSplitEdge = null;
        _altSplitPoint = null;
        _bump();
      }
      return;
    }
    _hoverPass(flow);
  }

  /// 无按键悬停:Alt 拆分预览 / 普通连线高亮
  void _hoverPass(Offset flow) {
    if (_pointInAnyNode(flow)) return;
    final hit = _hitEdgeAt(flow, threshold: 46 / _zoom);
    if (_alt) {
      // 实时预览:沿同一条连线滑动时 hit.point 也在变化,需同时比较点位置,
      // 否则预览点停留在首次命中的位置,不跟随鼠标
      if (hit != null &&
          (hit.edge.id != _altSplitEdge || hit.hit.point != _altSplitPoint)) {
        _altSplitEdge = hit.edge.id;
        _altSplitPoint = hit.hit.point;
        _bump();
      } else if (hit == null && _altSplitEdge != null) {
        _altSplitEdge = null;
        _altSplitPoint = null;
        _bump();
      }
    } else {
      final hid = hit?.edge.id;
      if (hid != _hoverEdge) {
        _hoverEdge = hid;
        _bump();
      }
    }
  }

  // ---------------- 背景交互 ----------------

  void _onBackgroundDown(PointerDownEvent e) {
    // 菜单打开期间:事件由菜单自身处理,画布层一律忽略(防反复重建)
    if (_menuPos != null) return;
    // 预览窗面板内:指针事件由预览窗自身处理,画布层一律忽略
    // (防误触发清空多选/框选/Alt 划线等画布逻辑)
    if (_inMiniMap(e.position)) return;
    _downButtons = e.buttons;
    _downPosScreen = e.localPosition;
    // 按下即结束实时预览:点击生成断点/命中节点/断点圆点等任何操作时,
    // 预览圆点立即消失、不残留(清除后必须 _bump 触发重绘)
    if (_altSplitEdge != null || _altSplitPoint != null) {
      _altSplitEdge = null;
      _altSplitPoint = null;
      _bump();
    }
    final flow = _toFlow(e.localPosition);
    // 右键:节点上走卡片折叠;分组框内部空白 → 分组右键菜单(取消分组/复制分组);
    // 其余空白 → 新建节点菜单
    if (e.buttons & kSecondaryMouseButton != 0) {
      if (_pointInAnyNode(flow)) return; // 节点上右键走卡片折叠
      final gid = _groupAt(flow);
      if (gid != null) {
        _menuPos = e.localPosition;
        _groupMenuFor = gid;
        _nodeMenuFor = null;
        _pendingConn = null;
        _bump();
        return;
      }
      _menuPos = e.localPosition;
      _pendingConn = null;
      _bump();
      return;
    }
    // 主键命中端口 handle:开始连线拖拽(画布层命中,见 _handleAt 注释)
    if (e.buttons & kPrimaryButton != 0) {
      final h = _handleAt(flow);
      if (h != null) {
        _onConnectStart(h.nodeId, h.isSource, h.socketId, h.type, h.anchor);
        return;
      }
    }
    // 命中分割点拖拽(扫描所有连线的断点,不限选中;Alt 创建后无需再次选中即可拖动)
    for (final e in store.edges) {
      if (e.mid == null) continue;
      if ((e.mid! - flow).distance < 16 / _zoom) {
        _draggingMidEdge = e.id;
        store.selectSplitEdge(e.id);
        return;
      }
    }
    // 命中节点本体:拖动只从顶部着色层(标题栏 headerH 高)发起(画布层 Listener
    // 统一管理,绕开手势竞技场)。逆序遍历:后绘制的节点在图层上方,应优先命中
    // (与渲染顺序一致)。主体内按下仅完成选中,不拖动节点。
    for (final n in store.nodes.reversed) {
      final size = nodeSize(n, store.edges);
      final r = n.position & size;
      if (r.contains(flow)) {
        if (_shift) {
          // Shift:已在多选的节点保持原状(tap 时切换去留),未选中的立即加入
          // —— 拖动立即包含新加入节点;tap 端通过 _downAddedNode 避免重复切换
          if (store.multiSelected.contains(n.id)) {
            _downAddedNode = false;
          } else {
            _downAddedNode = true;
            store.setMultiSelected({...store.multiSelected, n.id});
          }
        } else {
          // 点击已在多选中的节点:保持多选(Blender 语义,拖动任一成员整组跟随);
          // 点击未选中节点:重置为单选
          if (store.multiSelected.contains(n.id)) {
            _downAddedNode = false;
          } else {
            _downAddedNode = true;
            store.setMultiSelected({n.id});
          }
        }
        // 仅标题栏着色层可拖动;主体点击选中但保持原位置
        final headerRect = Rect.fromLTWH(
          n.position.dx,
          n.position.dy,
          size.width,
          NodeGeom.headerH,
        );
        if (headerRect.contains(flow)) {
          _startNodeDrag(store.multiSelected);
        }
        if (store.selectedSplitEdgeId != null) store.selectSplitEdge(null);
        return;
      }
    }
    // 命中分组标签(顶部蓝色矩形):选中组内节点并整体拖动(Blender 分组语义);
    // 快速连续两次按下(双击)标签 → 弹出重命名分组对话框
    final gid = _groupLabelAt(flow);
    if (gid != null) {
      final g = store.groups.firstWhere((x) => x.id == gid);
      final now = DateTime.now();
      if (gid == _lastGroupLabelDownId &&
          _lastGroupLabelDownAt != null &&
          now.difference(_lastGroupLabelDownAt!).inMilliseconds < 400 &&
          (flow - _lastGroupLabelDownFlow).distance < 12 / _zoom) {
        _lastGroupLabelDownAt = null;
        _renameGroupDialog(g);
        return;
      }
      _lastGroupLabelDownAt = now;
      _lastGroupLabelDownId = gid;
      _lastGroupLabelDownFlow = flow;
      final ids = g.nodeIds.toSet();
      store.setMultiSelected(ids);
      _downAddedNode = false;
      _startNodeDrag(ids);
      if (store.selectedSplitEdgeId != null) store.selectSplitEdge(null);
      return;
    }
    // 命中连线(无修饰键 → 取消分割点选择;Alt → 进入划线模式,给经过的连线加断点)
    if (!_ctrl && !_shift) {
      final hit = _hitEdgeAt(flow, threshold: 46 / _zoom);
      if (hit != null) {
        if (_alt) {
          _startAltSweep(flow);
          _addAltSplit(hit.edge, hit.hit.point);
          return;
        }
        if (store.selectedSplitEdgeId != null) store.selectSplitEdge(null);
        return;
      }
      if (_alt) {
        // Alt 按在空白处:同样进入划线模式(光标继续移动时给划过的连线加断点)
        _startAltSweep(flow);
      }
    }
  }

  void _onBackgroundMove(PointerMoveEvent e) {
    // 菜单打开期间:事件由菜单自身处理,画布层一律忽略(防反复重建)
    if (_menuPos != null) return;
    // 预览窗拖拽进行中:画布层忽略(拖出面板后 up 位置在面板外,仍需此标志守卫)
    if (_miniMapDragging) return;
    // 连线拖拽中:更新预览终点(画布局部坐标 → 世界坐标),并高亮候选目标端口。
    // 悬停在兼容端口附近时把终点吸附到该端口中心(与松开后真正建线一致),
    // 避免虚线末端停在鼠标处、偏移于端口中心;一次 move 内两次 _toFlow 会重复计算,故先存一次。
    if (_connecting != null) {
      _connectDownScreen ??= e.position;
      final flow = _toFlow(e.localPosition);
      final target = _findSocketAt(flow, _connecting!);
      _connectFlowPos = target?.anchor ?? flow;
      final cur = _sockHover.value;
      final hover = target == null
          ? null
          : SocketHoverState(target.nodeId, target.socketId, target.isSource);
      if (cur.hover != hover) {
        _sockHover.value = (active: cur.active, hover: hover);
      }
      _bump();
      return;
    }
    // 节点拖动中:以各节点按下坐标为基准累计位移移动(Shift 插入预览在 _onNodeDragTo 内处理)
    if (_draggingId != null) {
      final down = _downPosScreen;
      final origin = _dragOrigins[_draggingId];
      if (down != null && origin != null) {
        _onNodeDragTo(_draggingId!, origin + (e.localPosition - down) / _zoom);
      }
      return;
    }
    final flow = _toFlow(e.localPosition);
    final left = e.buttons & kPrimaryButton != 0;
    final inNode = _pointInAnyNode(flow);

    if (_draggingMidEdge != null) {
      store.updateEdgeData(_draggingMidEdge!, flow);
      _bump();
      return;
    }

    // Alt 拖拽划线:划过每条连线自动添加断点(段内插值,快速滑动不漏线)
    if (left && _alt && _altSweeping) {
      final last = _lastAltSweepFlow;
      _lastAltSweepFlow = flow;
      if (last != null) {
        final dist = (flow - last).distance;
        final steps = math.max(1, (dist / (16 / _zoom)).ceil());
        for (var i = 1; i <= steps; i++) {
          final p = Offset.lerp(last, flow, i / steps)!;
          final hit = _hitEdgeAt(p, threshold: 46 / _zoom);
          if (hit != null) _addAltSplit(hit.edge, hit.hit.point);
        }
      }
      _bump();
      return;
    }

    // Ctrl 拖拽切断(切水果):记录刀光轨迹,划过连线即砍断
    if (left && _ctrl && !inNode) {
      // 刀光轨迹:追加当前点并限长,更新时刻驱动渐隐动画
      _slashTrail.add(flow);
      if (_slashTrail.length > 24) _slashTrail.removeAt(0);
      _slashTrailAt = DateTime.now();
      if (!_cutTicker.isActive) _cutTicker.start();
      // 采样鼠标运动:最近 4 点求平均速度,作为粒子初速度(与划过速度相同)
      _motionSamples.add((pos: flow, t: DateTime.now()));
      if (_motionSamples.length > 4) _motionSamples.removeAt(0);
      if (_motionSamples.length >= 2) {
        final a = _motionSamples.first;
        final b = _motionSamples.last;
        final dt = b.t.difference(a.t).inMicroseconds / 1e6;
        if (dt > 0.004) _swipeVel = (b.pos - a.pos) / dt;
      }
      final hit = _hitEdgeAt(flow, threshold: 46 / _zoom);
      if (hit != null) {
        store.removeEdge(hit.edge.id);
        // 每砍断一条线都在其切点生成一次粒子爆裂(颜色跟随该连线端口色)
        _bursts.add(
          _makeBurst(hit.hit.point, _edgeBaseColor(hit.edge), _swipeVel),
        );
        if (_bursts.length > 16) _bursts.removeAt(0); // 手势中限长防堆积
        if (!_cutTicker.isActive) _cutTicker.start();
        if (store.autoRun) store.runPipeline();
      }
      _bump();
      return;
    }

    // 无按键:悬停高亮(端口动画 + 连线高亮)
    if (!left && !_ctrl && !_shift) {
      _updateHover(e.localPosition);
    }

    // 框选拖拽
    if (_boxDragging && _boxStart != null) {
      _boxEnd = e.localPosition;
      _bump();
    }
  }

  void _onBackgroundUp(PointerUpEvent e) {
    // 菜单打开期间:事件由菜单自身处理,画布层一律忽略(防反复重建)
    if (_menuPos != null) return;
    // 预览窗内的松开/预览窗拖拽结束(可能拖出面板后松开):画布层忽略,
    // 否则会走到"点击空白清空多选"误清选择
    if (_inMiniMap(e.position) || _miniMapDragging) {
      _miniMapDragging = false;
      _downPosScreen = null;
      return;
    }
    // 结束 Alt 划线手势:为新增断点统一记录日志并触发一次流水线
    if (_altSweeping) {
      if (_altSweptEdges.isNotEmpty) {
        store.addLog('info', '已在 ${_altSweptEdges.length} 条曲线上插入分割点');
        if (store.autoRun) store.runPipeline();
      }
      _altSweeping = false;
      _altSweptEdges.clear();
      _lastAltSweepFlow = null;
    }
    // 连线拖拽松开:位移 > 4px 才算连线,否则视为点击 handle 静默取消
    // (避免单击端口误弹新建节点菜单)
    if (_connecting != null) {
      final down = _connectDownScreen;
      final moved = down != null && (e.position - down).distance > 4;
      final conn = _connecting;
      _connecting = null;
      _connectDownScreen = null;
      _sockHover.value = (active: null, hover: null);
      if (moved && conn != null) {
        // 用最后一次绘制的终点(若已吸附目标端口则为中心)判定建线,
        // 保证松开时实际连接的端口与虚线末端一致,不产生偏移
        _finishConnect(conn, _connectFlowPos ?? _toFlow(e.localPosition));
      } else {
        _bump();
      }
      _downPosScreen = null;
      return;
    }
    // 节点拖动松开:结束拖动(Shift 插入预览可能在此提交)
    if (_draggingId != null) {
      final id = _draggingId!;
      final single = _dragIds.length == 1;
      _draggingId = null;
      _dragIds = {};
      _dragOrigins = {};
      _downPosScreen = null;
      _onNodeDragEnd(id, single: single);
      return;
    }
    final down = _downPosScreen;
    final moved = down != null && (e.localPosition - down).distance > 3;
    if (_draggingMidEdge != null) {
      _draggingMidEdge = null;
      return;
    }
    if (_boxDragging) {
      _finishBoxSelect(e.localPosition);
      _boxDragging = false;
      _boxStart = null;
      _boxEnd = null;
      return;
    }
    // 仅主键点击空白处才清空多选;右键 up(如右键取消分组后松开)不触发
    if (!moved &&
        !_pointInAnyNode(_toFlow(e.localPosition)) &&
        _downButtons & kPrimaryButton != 0) {
      store.setMultiSelected({});
      // 刚通过 Alt 创建的断点保持选中(便于直接拖动微调)
      if (store.selectedSplitEdgeId != null && !_altJustSplit) {
        store.selectSplitEdge(null);
      }
    }
    _altJustSplit = false;
    _downPosScreen = null;
  }

  void _finishBoxSelect(Offset end) {
    final start = _boxStart;
    if (start == null) return;
    final a = _toFlow(start);
    final b = _toFlow(end);
    final rect = Rect.fromPoints(a, b);
    final sel = <String>[];
    for (final n in store.nodes) {
      final r = n.position & nodeSize(n, store.edges);
      if (rect.overlaps(r)) sel.add(n.id);
    }
    if (sel.isEmpty) {
      store.setMultiSelected({});
      return;
    }
    store.setMultiSelected(sel.toSet());
  }

  // ---------------- 命中检测 ----------------

  ({GraphEdge edge, EdgeHit hit})? _hitEdgeAt(
    Offset flowPos, {
    required double threshold,
  }) {
    // 预计算节点索引:避免逐边遍历 store.nodes(效率关键,框选/Ctrl 切断高频调用)
    final nodeMap = {for (final n in store.nodes) n.id: n};
    GraphEdge? bestEdge;
    EdgeHit? bestHit;
    for (final e in store.edges) {
      final src = nodeMap[e.source];
      final tgt = nodeMap[e.target];
      if (src == null || tgt == null) continue;
      final a = edgeSourceAnchor(e, src, store.edges);
      final b = edgeTargetAnchor(e, tgt, store.edges);
      final hit = closestOnEdge(a: a, b: b, mid: e.mid, p: flowPos);
      if (hit != null &&
          hit.dist < threshold &&
          (bestHit == null || hit.dist < bestHit.dist)) {
        bestHit = hit;
        bestEdge = e;
      }
    }
    return bestEdge == null ? null : (edge: bestEdge, hit: bestHit!);
  }

  // ---------------- 视图 ----------------

  void _onWheel(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    // 菜单打开期间:滚轮滚动菜单内容,不缩放画布
    if (_menuPos != null) return;
    // 仅 Ctrl+滚轮缩放画布,普通滚轮不响应
    if (!_ctrl) return;
    final local = e.localPosition;
    final factor = e.scrollDelta.dy < 0 ? 1.1 : 1 / 1.1;
    setState(() {
      final nz = math.min(2.5, math.max(0.25, _zoom * factor));
      final f = nz / _zoom;
      _zoom = nz;
      _zoomNotifier.value = nz;
      _pan = Offset(
        local.dx - (local.dx - _pan.dx) * f,
        local.dy - (local.dy - _pan.dy) * f,
      );
    });
  }

  void _onBackgroundPanStart(DragStartDetails d) {
    // 菜单打开期间:pan 手势与 Listener 指针事件是两条独立路径,
    // 菜单弹出瞬间可能仍有残余 pan 手势在竞技场中,此处一并忽略(防反复重建)
    if (_menuPos != null) return;
    // 记录起点是否落在节点内部:节点内部拖动不移动背景
    // (端口连线手势在节点卡内部,此处只处理冒泡到背景的 pan)
    _panFromNode = _pointInAnyNode(_toFlow(d.localPosition));
    // 节点/多选/分组拖动中(分组标签在节点外,无法靠 _pointInAnyNode 命中):绝不平移、不框选
    if (_draggingId != null) _panFromNode = true;
    // 连线拖拽中(handle 可能溢出节点边缘,不在节点矩形内):绝不平移、不框选
    if (_connecting != null) _panFromNode = true;
    // 分割点拖拽中:与节点拖拽同理,不平移背景、不框选(否则断点跟着画布漂移)
    if (_draggingMidEdge != null) _panFromNode = true;
    // Ctrl 切断 / Alt 划线:按住修饰键拖拽时不平移画布
    if (_ctrl || _alt) _panFromNode = true;
    // 框选只从空白处开始:Shift 拖拽节点时若在此启动框选,
    // 手势结束会覆盖多选(破坏"Shift 多选后整体拖动"的核心交互)
    if ((_spaceDown || widget.boxSelect || _shift) && !_panFromNode) {
      _boxDragging = true;
      _boxStart = d.localPosition;
      _boxEnd = d.localPosition;
      _bump();
    }
  }

  void _onBackgroundPanUpdate(DragUpdateDetails d) {
    if (_menuPos != null) return;
    if (_boxDragging) {
      _boxEnd = d.localPosition;
      _bump();
      return;
    }
    if (_panFromNode || _connecting != null) return; // 节点内/连线中:不平移背景
    if (_ctrl || _alt) return; // Ctrl/Alt 拖拽(切断/划线):不平移画布
    setState(() {
      _pan += d.delta;
    });
  }

  void _onBackgroundPanEnd(DragEndDetails d) {
    if (_menuPos != null) return;
    _panFromNode = false;
    if (_boxDragging) {
      _finishBoxSelect(_boxEnd ?? _boxStart ?? Offset.zero);
      _boxDragging = false;
      _boxStart = null;
      _boxEnd = null;
    }
    _bump();
  }

  void _closeMenu() {
    _menuPos = null;
    _pendingConn = null;
    _nodeMenuFor = null;
    _groupMenuFor = null;
    _bump();
  }

  // ---------------- 多选右键菜单动作(分组/复制/删除) ----------------

  void _groupSelection() {
    final sel = _nodeMenuFor;
    if (sel == null || sel.length < 2) return;
    store.createGroup(sel.toList());
    _closeMenu();
  }

  void _ungroupSelection() {
    final sel = _nodeMenuFor;
    if (sel == null) return;
    final gids = <String>{};
    for (final id in sel) {
      final gid = store.groupOf(id);
      if (gid != null) gids.add(gid);
    }
    for (final gid in gids) {
      store.dissolveGroup(gid);
    }
    _closeMenu();
  }

  void _duplicateSelection() {
    final sel = _nodeMenuFor;
    if (sel == null || sel.isEmpty) return;
    store.duplicateNodes(sel.toList());
    _closeMenu();
  }

  void _deleteSelectionFromMenu() {
    final sel = _nodeMenuFor;
    if (sel == null || sel.isEmpty) return;
    store.removeNodes(sel.toList());
    _closeMenu();
  }

  // ---------------- 分组右键菜单动作(取消分组/复制分组) ----------------

  void _ungroupFromGroupMenu() {
    final gid = _groupMenuFor;
    if (gid != null) store.dissolveGroup(gid);
    _closeMenu();
  }

  void _duplicateGroupFromMenu() {
    final gid = _groupMenuFor;
    if (gid != null) store.duplicateGroup(gid);
    _closeMenu();
  }

  /// 双击分组标签 → 重命名分组
  Future<void> _renameGroupDialog(NodeGroup g) async {
    final controller = TextEditingController(text: g.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名分组'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入分组名称'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null && name.trim().isNotEmpty) {
      store.renameGroup(g.id, name.trim());
    }
  }

  // ---------------- Ctrl+C / Ctrl+V 复制粘贴(节点/节点组) ----------------

  /// Ctrl+C:复制多选(或单选)节点;所选构成完整分组的节点,分组信息一并复制
  void _copySelection() {
    final sel = store.multiSelected.isNotEmpty
        ? store.multiSelected
        : (store.selectedId != null ? {store.selectedId!} : <String>{});
    if (sel.isEmpty) return;
    store.copySelection(sel);
  }

  /// Ctrl+V:在鼠标当前位置粘贴剪贴板内容(节点/节点组);无鼠标记录时用视口中心
  void _pasteSelection() {
    if (!store.hasClipboard) return;
    final anchor = _lastPointerFlow == Offset.zero
        ? Offset(
            (_canvasSize.width / 2 - _pan.dx) / _zoom,
            (_canvasSize.height / 2 - _pan.dy) / _zoom,
          )
        : _lastPointerFlow;
    store.pasteAt(anchor);
  }

  void _pickNode(String configId) {
    final menuPos = _menuPos;
    _menuPos = null;
    if (menuPos == null) return;
    final flowPos = _toFlow(menuPos);
    store.addNode(configId, Offset(flowPos.dx - 30, flowPos.dy - 20));
    final newNodeId = store.selectedId;
    final pc = _pendingConn;
    if (pc != null && newNodeId != null) {
      final cfg = getConfig(configId);
      if (cfg != null) {
        if (pc.isSource && cfg.inputs.isNotEmpty) {
          store.onConnect(
            source: pc.nodeId,
            target: newNodeId,
            sourceHandle: pc.socketId,
            targetHandle: cfg.inputs.first.id,
          );
        } else if (!pc.isSource && cfg.outputs.isNotEmpty) {
          store.onConnect(
            source: newNodeId,
            target: pc.nodeId,
            sourceHandle: cfg.outputs.first.id,
            targetHandle: pc.socketId,
          );
        }
      }
    }
    _pendingConn = null;
    _connecting = null;
    if (store.autoRun) store.runPipeline();
    _bump();
  }

  void deleteSelection() {
    if (store.selectedSplitEdgeId != null) {
      store.updateEdgeData(store.selectedSplitEdgeId!, null);
      store.selectSplitEdge(null);
      _bump();
      return;
    }
    // 优先删除多选集;退化为单选
    final sel = store.multiSelected;
    final ids = sel.isNotEmpty
        ? sel.toList()
        : (store.selectedId != null ? [store.selectedId!] : const <String>[]);
    if (ids.isEmpty) return;
    store.removeNodes(ids);
    _bump();
  }

  /// 外部 CSV/Excel 文件拖入窗口:在放下位置生成"表格输入"节点并自动导入。
  /// [clientPos] 为窗口客户区坐标(逻辑像素),[text] 为解析后的统一 CSV 文本。
  void dropFileText(Offset clientPos, String text) {
    if (text.trim().isEmpty) return;
    // 客户区坐标 → 画布局部坐标(画布在窗口内可能有偏移,如右侧属性面板区域)
    final box = context.findRenderObject() as RenderBox?;
    var local = box == null ? clientPos : box.globalToLocal(clientPos);
    if (box != null) {
      local = Offset(
        local.dx.clamp(0.0, math.max(0.0, box.size.width - 1)),
        local.dy.clamp(0.0, math.max(0.0, box.size.height - 1)),
      );
    }
    final flow = _toFlow(local);
    final delimiter = text.contains('\t') && !text.contains(',')
        ? 'tsv'
        : 'csv';
    final id = store.addNode('table_input', flow);
    // updateNodeParams 在自动执行开启时会自动重算
    store.updateNodeParams(id, {
      'mode': 'manual',
      'dataText': text,
      'delimiter': delimiter,
    });
    store.addLog('ok', '已导入数据文件生成表格输入节点');
  }

  void resetView() {
    setState(() {
      _zoom = 1;
      _pan = Offset.zero;
      _zoomNotifier.value = 1;
    });
  }

  /// 适应视图:缩放平移使全部节点居中可见
  void fitView() {
    if (store.nodes.isEmpty) {
      resetView();
      return;
    }
    final size = context.size;
    if (size == null) return;
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    for (final n in store.nodes) {
      final s = nodeSize(n, store.edges);
      minX = math.min(minX, n.position.dx);
      minY = math.min(minY, n.position.dy);
      maxX = math.max(maxX, n.position.dx + s.width);
      maxY = math.max(maxY, n.position.dy + s.height);
    }
    final w = maxX - minX;
    final h = maxY - minY;
    final nz = math.min(
      1.5,
      math.max(0.25, math.min(size.width / (w + 60), size.height / (h + 60))),
    );
    setState(() {
      _zoom = nz;
      _zoomNotifier.value = nz;
      _pan = Offset(
        (size.width - (w + 60) * nz) / 2 - minX * nz,
        (size.height - (h + 60) * nz) / 2 - minY * nz,
      );
    });
  }

  @override
  void dispose() {
    _cutTicker.dispose();
    _zoomNotifier.dispose();
    _sockHover.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// 切断连线的基准色(与连线绘制一致:源端口颜色,找不到时回退默认色)
  Color _edgeBaseColor(GraphEdge e) {
    for (final n in store.nodes) {
      if (n.id != e.source) continue;
      final cfg = getConfig(n.configId);
      if (cfg == null) break;
      for (final o in cfg.outputs) {
        if (o.id == e.sourceHandle) {
          final hex = kSocketColor[o.type];
          if (hex != null) return socketColor(o.type);
        }
      }
      break;
    }
    return const Color(0xFF7C8DB5);
  }

  /// 生成切断粒子爆裂:10~17 颗,颜色以连线色为基准——隔一颗提亮提饱和
  /// (更显眼),其余保持原色轻微偏差;初速度 = 自身径向速度 + 鼠标划过速度;
  /// 重力向下;速度/尺寸/重力均按 zoom 折算成 flow 单位(屏幕恒定)。
  _ParticleBurst _makeBurst(Offset p, Color base, Offset swipeVel) {
    final rand = math.Random();
    final hsv = HSVColor.fromColor(base);
    final n = 10 + rand.nextInt(8);
    // boost=true:更亮更饱和;否则接近原色(仅轻微偏差)
    Color vary(bool boost) {
      final hue = (hsv.hue + rand.nextDouble() * 14 - 7) % 360.0;
      if (boost) {
        final sat = (hsv.saturation * 1.3 + 0.1).clamp(0.0, 1.0);
        final val = (hsv.value * 1.25 + 0.1).clamp(0.0, 1.0);
        return HSVColor.fromAHSV(1, hue, sat, val).toColor();
      }
      final sat = (hsv.saturation * (0.9 + rand.nextDouble() * 0.2)).clamp(
        0.0,
        1.0,
      );
      final val = (hsv.value * (0.9 + rand.nextDouble() * 0.2)).clamp(0.0, 1.0);
      return HSVColor.fromAHSV(1, hue, sat, val).toColor();
    }

    return _ParticleBurst(
      origin: p,
      at: DateTime.now(),
      // 重力:向屏幕下方,云图上以 zoom 折算保持视觉一致
      g: 380 / _zoom,
      particles: [
        for (var i = 0; i < n; i++)
          _Particle(
            vel:
                Offset.fromDirection(
                  rand.nextDouble() * 2 * math.pi,
                  (45 + rand.nextDouble() * 105) / _zoom,
                ) +
                swipeVel * 0.07, // 刀尖速度衰减为 7%,保留方向不过猛
            size: (2.0 + rand.nextDouble() * 2.6) / _zoom,
            color: vary(i.isEven),
          ),
      ],
    );
  }

  // ---------------- 交互回调装配 ----------------

  NodeCardCallbacks get _cardCallbacks =>
      NodeCardCallbacks(onSelect: _onSelect, onSecondaryTap: _onSecondaryTap);

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);

    // 外层 Stack:画布层与菜单层平级 —— 菜单是 Listener 的兄弟而非后代,
    // 菜单交互的指针事件不会冒泡到画布指针链(消除"菜单打开期间画布反复重建"的结构性耦合)
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: _buildCanvasLayer(t)),
          if (_menuPos != null) _buildMenuLayer(),
        ],
      ),
    );
  }

  /// 画布层:指针交互(Listener)+ 光标(MouseRegion)+ 端口状态广播(CanvasSockets)+ 分层渲染
  Widget _buildCanvasLayer(SyphonTheme t) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onBackgroundDown,
      onPointerMove: _onBackgroundMove,
      onPointerUp: _onBackgroundUp,
      onPointerHover: _onPointerHover,
      onPointerCancel: _onPointerCancel,
      onPointerSignal: _onWheel,
      child: MouseRegion(
        cursor: _alt
            ? SystemMouseCursors.precise
            : (_spaceDown ? SystemMouseCursors.grab : SystemMouseCursors.basic),
        // 鼠标离开画布:清除悬停强调
        onExit: _onMouseExit,
        child: CanvasSockets(
          notifier: _sockHover,
          // 捕获画布视口尺寸(Positioned.fill 下为紧约束,保证有限):
          // 预览窗据此换算"相当于屏幕"的区域矩形;尺寸变化时补一帧,
          // 避免首帧/窗口 resize 后预览窗的屏幕区域指示不刷新
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = constraints.biggest;
              if (size.isFinite && size != _canvasSize) {
                _canvasSize = size;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) setState(() {});
                });
              }
              // 不裁剪画布世界:节点可平移到窗口外仍可绘制与拖拽(React 版 overflow visible)
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(child: _buildCanvasWorld(t)),
                  // 框选矩形(屏幕坐标)
                  if (_boxDragging && _boxStart != null && _boxEnd != null)
                    _buildBoxSelect(t),
                  _buildMiniMap(),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// 画布世界(平移+缩放):pan 手势 + 世界渲染(背景/连线/节点三层)
  Widget _buildCanvasWorld(SyphonTheme t) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: _onBackgroundPanStart,
      onPanUpdate: _onBackgroundPanUpdate,
      onPanEnd: _onBackgroundPanEnd,
      onPanCancel: _onBackgroundPanCancel,
      child: AnimatedBuilder(
        animation: Listenable.merge([store, _zoomNotifier]),
        // 注意:store 变化(移动/连线/增删节点)不触发本 State setState,
        // 必须在 builder 内重新读取 store.nodes/store.edges 才能实时刷新
        builder: (context, _) {
          final nodes = store.nodes;
          final edges = store.edges;
          return Transform(
            transform: Matrix4.identity()
              ..translateByDouble(_pan.dx, _pan.dy, 0, 1)
              ..scaleByDouble(_zoom, _zoom, 1, 1),
            alignment: Alignment.topLeft,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                _buildBgLayer(t),
                _buildEdgesLayer(t, nodes, edges),
                for (final n in nodes) _buildNodeLayer(n),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 背景点阵层(独立 RepaintBoundary:与连线/节点层互不触发重绘)
  Widget _buildBgLayer(SyphonTheme t) {
    return Positioned.fill(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _BgPainter(
            bg: t.bgCanvas,
            dot: t.flowDot,
            pan: _pan,
            zoom: _zoom,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }

  /// 连线层(独立 RepaintBoundary:pan/zoom 平移时仅重新合成缓存位图)
  Widget _buildEdgesLayer(
    SyphonTheme t,
    List<GraphNode> nodes,
    List<GraphEdge> edges,
  ) {
    return Positioned.fill(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _buildEdgePainter(t, nodes, edges),
          size: Size.infinite,
        ),
      ),
    );
  }

  /// 连线层画笔(含切断/刀光动画进度)
  _EdgesPainter _buildEdgePainter(
    SyphonTheme t,
    List<GraphNode> nodes,
    List<GraphEdge> edges,
  ) {
    // 切断粒子爆裂:每次切断各自计时(各 0~1,450ms)
    final now = DateTime.now();
    final liveBursts = [
      for (final b in _bursts)
        (
          burst: b,
          progress: (now.difference(b.at).inMilliseconds / 450.0).clamp(
            0.0,
            1.0,
          ),
        ),
    ];
    // 刀光整体淡出:距最后一次划过的时刻 0→300ms 内从 0 → 1
    final slashProg = _slashTrail.isEmpty
        ? 1.0
        : (DateTime.now().difference(_slashTrailAt).inMilliseconds / 300.0)
              .clamp(0.0, 1.0);
    return _EdgesPainter(
      nodes: nodes,
      edges: edges,
      groups: store.groups,
      hoverEdge: _hoverEdge,
      altSplitEdge: _altSplitEdge,
      altSplitPoint: _altSplitPoint,
      insertPreviewEdge: _insertPreviewEdge,
      insertPreviewPoint: _insertPreviewPoint,
      liveBursts: liveBursts,
      connecting: _connecting,
      connectPos: _connectFlowPos,
      selectedSplitEdgeId: store.selectedSplitEdgeId,
      revision: _revision + store.structureVersion + store.runVersion,
      flowEdge: t.flowEdge,
      accent: t.accent,
      isDark: t.isDark,
      zoom: _zoom,
      slashTrail: _slashTrail,
      slashTrailProgress: slashProg,
    );
  }

  /// 单节点卡片层(独立 RepaintBoundary:hover/拖拽只重绘该卡片层)
  Widget _buildNodeLayer(GraphNode n) {
    return Positioned(
      left: n.position.dx,
      top: n.position.dy,
      child: CanvasZoom(
        notifier: _zoomNotifier,
        child: RepaintBoundary(
          child: NodeCard(nodeId: n.id, callbacks: _cardCallbacks),
        ),
      ),
    );
  }

  /// 框选矩形(屏幕坐标,不随世界缩放)
  Widget _buildBoxSelect(SyphonTheme t) {
    return Positioned(
      left: math.min(_boxStart!.dx, _boxEnd!.dx),
      top: math.min(_boxStart!.dy, _boxEnd!.dy),
      width: (_boxEnd!.dx - _boxStart!.dx).abs(),
      height: (_boxEnd!.dy - _boxStart!.dy).abs(),
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: t.accent, width: 1),
            color: t.accent.withValues(alpha: 0.08),
          ),
        ),
      ),
    );
  }

  /// 右下角缩略预览窗(MiniMap):180x120,展示全部节点与视口范围;
  /// 预览窗内拖拽可移动画布(灰色视口矩形跟随鼠标)
  Widget _buildMiniMap() {
    return Positioned(
      right: 14,
      bottom: 14,
      child: AnimatedBuilder(
        animation: store,
        builder: (context, _) => MiniMapView(
          key: _miniMapKey,
          nodes: store.nodes,
          edges: store.edges,
          zoom: _zoom,
          pan: _pan,
          // 画布视口尺寸:画布层 LayoutBuilder 捕获(紧约束,保证有限);
          // 预览窗自身位于 Positioned(right,bottom) 下,拿到的约束可能无界,
          // 直接用会因 isFinite 守卫跳过屏幕区域绘制
          viewport: _canvasSize,
          onPanChanged: _onMiniMapPan,
          onPanEnd: () => _miniMapDragging = false,
        ),
      ),
    );
  }

  /// 预览窗拖拽:更新画布平移(视口在迷你图中跟随鼠标)
  void _onMiniMapPan(Offset newPan) {
    _miniMapDragging = true;
    setState(() => _pan = newPan);
  }

  /// 菜单层:与画布层平级,独立指针链。
  /// 分组右键 → GroupContextMenu(取消分组/复制分组);
  /// 多选右键 → NodeContextMenu(分组/复制/删除);空白/连线拖拽 → NodeMenu(新建节点)
  Widget _buildMenuLayer() {
    final nodeMenu = _nodeMenuFor;
    final groupMenuId = _groupMenuFor;
    Widget? menu;
    if (groupMenuId != null) {
      NodeGroup? g;
      for (final x in store.groups) {
        if (x.id == groupMenuId) {
          g = x;
          break;
        }
      }
      if (g != null) {
        menu = GroupContextMenu(
          position: _menuPos!,
          groupName: g.name,
          onUngroup: _ungroupFromGroupMenu,
          onDuplicate: _duplicateGroupFromMenu,
        );
      }
    } else if (nodeMenu != null) {
      menu = NodeContextMenu(
        position: _menuPos!,
        canGroup: nodeMenu.length >= 2,
        canUngroup: nodeMenu.any((id) => store.groupOf(id) != null),
        onGroup: _groupSelection,
        onUngroup: _ungroupSelection,
        onDuplicate: _duplicateSelection,
        onDelete: _deleteSelectionFromMenu,
      );
    } else {
      menu = NodeMenu(
        position: _menuPos!,
        onPick: _pickNode,
        onClose: _closeMenu,
      );
    }
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _closeMenu,
        onSecondaryTap: _closeMenu,
        child: Stack(clipBehavior: Clip.none, children: [?menu]),
      ),
    );
  }

  // ---------------- 画布层事件回调 ----------------

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.space) {
      _spaceDown = event is KeyUpEvent ? false : true;
      _bump();
      return KeyEventResult.handled;
    }
    // Ctrl+C 复制所选(节点/节点组)/ Ctrl+V 粘贴(仅 down 触发一次,repeat 忽略)
    if (event is KeyDownEvent &&
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed)) {
      if (event.logicalKey == LogicalKeyboardKey.keyC) {
        _copySelection();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyV) {
        _pasteSelection();
        return KeyEventResult.handled;
      }
    }
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (event.logicalKey == LogicalKeyboardKey.delete ||
          event.logicalKey == LogicalKeyboardKey.backspace) {
        deleteSelection();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        if (_menuPos != null) {
          _closeMenu();
        } else {
          store.selectNode(null);
          store.setMultiSelected({});
          store.selectSplitEdge(null);
        }
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  /// 悬停(未按下)事件:驱动端口强调动画与连线悬停高亮
  void _onPointerHover(PointerHoverEvent e) {
    // 菜单打开期间:不更新画布悬停,避免与菜单交互冲突
    if (_menuPos != null) return;
    if (_inMiniMap(e.position)) return; // 预览窗上悬停不高亮其背后的连线/端口
    if (_connecting != null) return; // 拖拽中由 move 更新
    _updateHover(e.localPosition);
  }

  /// 指针取消(如窗口失焦):清理连线拖拽状态,避免残留预览线
  void _onPointerCancel(PointerCancelEvent e) {
    if (_connecting != null || _connectDownScreen != null) {
      _connecting = null;
      _connectDownScreen = null;
      _bump();
    }
    _sockHover.value = (active: null, hover: null);
  }

  /// 鼠标离开画布:清除悬停强调
  void _onMouseExit(PointerExitEvent e) {
    if (_sockHover.value != (active: null, hover: null)) {
      _sockHover.value = (active: null, hover: null);
    }
    if (_hoverEdge != null || _altSplitEdge != null) {
      _hoverEdge = null;
      _altSplitEdge = null;
      _altSplitPoint = null;
      _bump();
    }
  }

  /// pan 手势取消:清理框选状态
  void _onBackgroundPanCancel() {
    _boxDragging = false;
    _boxStart = null;
    _boxEnd = null;
  }
}
