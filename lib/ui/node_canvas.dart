// 节点画布:平移/缩放/节点拖拽/连线拖拽/右键菜单/框选/Alt拆分/Ctrl切断/Shift插入/分割点拖动
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart'
    show
        PointerScrollEvent,
        PointerSignalEvent,
        kPrimaryButton,
        kSecondaryMouseButton;
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';

import '../models/color_utils.dart';
import '../models/data.dart' hide Column;
import '../models/registry.dart';
import '../store/graph_store.dart';
import '../store/settings_store.dart';
import 'canvas_geometry.dart';
import 'context_menu.dart';
import 'mini_map.dart';
import 'motion.dart';
import 'node_card.dart';
import 'node_context_menus.dart';
import 'radial_node_menu.dart';
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

class _PackageRegionPainter extends CustomPainter {
  final Color color;
  final double zoom;

  const _PackageRegionPainter({required this.color, required this.zoom});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final radius = Radius.circular(10 / zoom);
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, radius);
    canvas.drawRRect(rrect, Paint()..color = color.withValues(alpha: .105));
    final path = Path()..addRRect(rrect);
    final paint = Paint()
      ..color = color.withValues(alpha: .78)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.35 / zoom;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      final dash = 7 / zoom;
      final gap = 5 / zoom;
      while (distance < metric.length) {
        canvas.drawPath(
          metric.extractPath(
            distance,
            math.min(distance + dash, metric.length),
          ),
          paint,
        );
        distance += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PackageRegionPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.zoom != zoom;
}

class _PackageOverviewPainter extends CustomPainter {
  final List<GraphNode> nodes;
  final List<GraphEdge> edges;
  final Color color;
  final int revision;

  const _PackageOverviewPainter({
    required this.nodes,
    required this.edges,
    required this.color,
    required this.revision,
  });

  Color _nodeColor(GraphNode node) {
    final category = getConfig(node.configId)?.category;
    final hex = category == null ? null : kCategoryInfo[category]?.color;
    return parseColor(hex, color);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (nodes.isEmpty || size.isEmpty) return;
    final nodeRects = <String, Rect>{
      for (final node in nodes) node.id: node.position & nodeSize(node, edges),
    };
    Rect? world;
    for (final rect in nodeRects.values) {
      world = world == null ? rect : world.expandToInclude(rect);
    }
    if (world == null || world.width <= 0 || world.height <= 0) return;
    final scale = math.min(
      (size.width - 12) / world.width,
      (size.height - 10) / world.height,
    );
    final fitted = Size(world.width * scale, world.height * scale);
    final origin = Offset(
      (size.width - fitted.width) / 2 - world.left * scale,
      (size.height - fitted.height) / 2 - world.top * scale,
    );
    Offset map(Offset point) => origin + point * scale;

    final ids = nodeRects.keys.toSet();
    final edgePaint = Paint()
      ..color = color.withValues(alpha: .42)
      ..strokeWidth = 1.15
      ..strokeCap = StrokeCap.round;
    for (final edge in edges) {
      if (!ids.contains(edge.source) || !ids.contains(edge.target)) continue;
      final source = nodeRects[edge.source]!;
      final target = nodeRects[edge.target]!;
      final a = map(source.centerRight);
      final b = map(target.centerLeft);
      final path = Path()
        ..moveTo(a.dx, a.dy)
        ..cubicTo((a.dx + b.dx) / 2, a.dy, (a.dx + b.dx) / 2, b.dy, b.dx, b.dy);
      canvas.drawPath(path, edgePaint);
    }
    for (final node in nodes) {
      final nodeColor = _nodeColor(node);
      final rect = nodeRects[node.id]!;
      final mapped = Rect.fromPoints(map(rect.topLeft), map(rect.bottomRight));
      final compact = Rect.fromCenter(
        center: mapped.center,
        width: mapped.width.clamp(12, 34),
        height: mapped.height.clamp(7, 19),
      );
      final rrect = RRect.fromRectAndRadius(compact, const Radius.circular(3));
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = nodeColor.withValues(alpha: .48)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.3),
      );
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = nodeColor.withValues(alpha: .92)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PackageOverviewPainter oldDelegate) =>
      oldDelegate.revision != revision ||
      oldDelegate.color != color ||
      oldDelegate.nodes.length != nodes.length ||
      oldDelegate.edges.length != edges.length;
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
  final bool connectConversion; // Alt 拖拽悬停到“需经转换节点”的端口:预览线琥珀色
  final String? selectedSplitEdgeId;
  final String? selectedEdgeId;
  final int revision;
  final Color flowEdge;
  final Color accent;
  final Color warn;
  final bool isDark; // 亮色模式下连线颜色压暗一档(避免鲜艳色刺眼)
  final double zoom; // 当前缩放:Transform 内绘制,所有标记尺寸除以 zoom 保持屏幕恒定
  // 切水果刀光:划过轨迹点(flow 坐标)与整体淡出进度 0~1
  final List<Offset> slashTrail;
  final double slashTrailProgress;
  final Map<String, GraphNode> nodeMap; // 节点 id → 节点(由 nodes 派生,绘制时查询用)

  // 预计算锚点:edgeId → (源锚点, 目标锚点)。
  // 一次性遍历节点端口统计,避免逐边重复 O(E) 扫描(连线多时性能关键)
  late final Map<String, ({Offset a, Offset b})> _anchors;
  late final Map<String, NodeGroup> _collapsedPackageByNode;
  late final Map<String, Rect> _packageRects;

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
    this.connectConversion = false,
    this.selectedSplitEdgeId,
    this.selectedEdgeId,
    required this.revision,
    required this.flowEdge,
    required this.accent,
    required this.warn,
    required this.isDark,
    required this.zoom,
    this.slashTrail = const [],
    this.slashTrailProgress = 1,
  }) : nodeMap = {for (final n in nodes) n.id: n} {
    _collapsedPackageByNode = {
      for (final group in groups)
        if (group.isPackage && group.collapsed)
          for (final id in group.nodeIds) id: group,
    };
    _packageRects = {};
    for (final group in groups) {
      final rect = packageProxyRect(group, nodes, edges);
      if (rect != null) _packageRects[group.id] = rect;
    }
    _initAnchors();
  }

  /// 预计算每条连线的端点锚点(世界坐标):按端口分组统计连接,
  /// 端点沿 handle 高度从上到下均匀分布(与 _anchorY 公式一致)
  void _initAnchors() {
    _anchors = <String, ({Offset a, Offset b})>{};
    for (final n in nodeMap.values) {
      if (_collapsedPackageByNode.containsKey(n.id)) continue;
      final cfg = getConfig(n.configId);
      if (cfg == null) continue;
      final w = nodeVisualWidth(n);
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
    for (final e in edges) {
      final src = nodeMap[e.source];
      final tgt = nodeMap[e.target];
      if (src == null || tgt == null) continue;
      final sourcePackage = _collapsedPackageByNode[e.source];
      final targetPackage = _collapsedPackageByNode[e.target];
      if (sourcePackage != null && sourcePackage.id == targetPackage?.id) {
        continue;
      }
      _paintEdge(canvas, e, src, tgt);
    }
    // 连线拖拽中:三次贝塞尔曲线预览(与正式连线同曲率,虚线区分);
    // 悬停在“需转换”端口上时用琥珀色提示即将自动插入转换节点
    if (connecting != null && connectPos != null) {
      final samples = bezierSamples(connecting!.anchor, connectPos!);
      if (samples.length >= 2) {
        final lineColor = connectConversion ? warn : flowEdge;
        _drawDashedPath(canvas, samples, lineColor, 2, dash: [6, 4]);
        _drawArrow(
          canvas,
          samples[samples.length - 2],
          samples.last,
          8,
          lineColor,
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
    final sourcePackage = _collapsedPackageByNode[e.source];
    final targetPackage = _collapsedPackageByNode[e.target];
    final sourceRect = sourcePackage == null
        ? null
        : _packageRects[sourcePackage.id];
    final targetRect = targetPackage == null
        ? null
        : _packageRects[targetPackage.id];
    final a = sourceRect == null || sourcePackage == null
        ? anchor?.a ?? edgeSourceAnchor(e, src, edges)
        : _packageAnchor(sourcePackage, sourceRect, e, isSource: true);
    final b = targetRect == null || targetPackage == null
        ? anchor?.b ?? edgeTargetAnchor(e, tgt, edges)
        : _packageAnchor(targetPackage, targetRect, e, isSource: false);
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
    if (e.id == selectedSplitEdgeId || e.id == selectedEdgeId) {
      // 选中的连线(分割点选中或整条选中):accent 色高亮
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

  Offset _packageAnchor(
    NodeGroup group,
    Rect rect,
    GraphEdge edge, {
    required bool isSource,
  }) {
    final ports = isSource
        ? packageOutputPorts(group, nodeMap.values.toList(), edges)
        : packageInputPorts(group, nodeMap.values.toList(), edges);
    final nodeId = isSource ? edge.source : edge.target;
    final socketId = isSource ? edge.sourceHandle : edge.targetHandle;
    final port = ports
        .where((item) => item.nodeId == nodeId && item.socketId == socketId)
        .firstOrNull;
    return port == null
        ? (isSource ? rect.centerRight : rect.centerLeft)
        : packagePortAnchor(rect, ports, port, isSource: isSource);
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

  /// 最后记录的鼠标世界坐标(flow 坐标);由 NodeCanvasState 在悬停/移动时更新,
  /// 供 main.dart 全局 Ctrl+V 粘贴定位使用
  static Offset lastMouseWorldPos = Offset.zero;

  const NodeCanvas({super.key, this.boxSelect = false, this.onRequestAddNode});

  @override
  State<NodeCanvas> createState() => NodeCanvasState();
}

class NodeCanvasState extends State<NodeCanvas> with TickerProviderStateMixin {
  final GraphStore store = GraphStore.instance;
  final ValueNotifier<double> _zoomNotifier = ValueNotifier(1);
  final FocusNode _focusNode = FocusNode();
  final ValueNotifier<({Offset local, Color color, bool accepted})?>
  _dropPreview = ValueNotifier(null);

  // 切断粒子爆裂动画:每帧刷新直到动画结束
  late final Ticker _cutTicker;
  late final AnimationController _conversionLayoutController;
  Map<String, Offset> _conversionLayoutOrigins = const {};
  Map<String, Offset> _conversionLayoutTargets = const {};
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

  // 缩放控制(+/-)按钮组:同样位于画布 Listener 子树内,指针事件会冒泡,
  // down/up/hover 需按矩形跳过画布逻辑(与预览窗同模式)
  final GlobalKey _zoomControlKey = GlobalKey();

  /// 指针全局坐标是否落在缩放控制按钮组内(4px 容差)
  bool _inZoomControl(Offset globalPos) {
    final ctx = _zoomControlKey.currentContext;
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
  String? _resizingViewerId;
  bool _viewerResizeSnapshotted = false;
  String? _draggingPackageId;
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
  bool _connectConversion = false; // 当前连线预览悬停在“需转换”端口上
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
  Timer? _radialHoldTimer;
  Offset? _rightPressScreen;
  Offset _radialPointer = Offset.zero;
  bool _radialVisible = false;
  int? _radialSection;
  int? _radialDetail;
  List<RadialNodeItem> _radialItems = const [];
  RadialNodeItem? _radialLockedItem;
  Offset? _radialDetachAnchor;

  // 鼠标最后位置(flow 坐标):Ctrl+V 粘贴定位用(hover/move 时更新)
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

  /// 顶部节点条拖动时，仅刷新这个轻量 overlay，不触发节点世界重建。
  void updateExternalNodeDrag(
    String configId,
    Category category,
    Offset globalPosition,
  ) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final local = box.globalToLocal(globalPosition);
    final accepted = (Offset.zero & box.size).contains(local);
    final hex = kCategoryInfo[category]?.color ?? '#7c8db5';
    final color = Color(
      int.tryParse(hex.replaceFirst('#', '0xFF')) ?? 0xFF7C8DB5,
    );
    _dropPreview.value = (local: local, color: color, accepted: accepted);
  }

  void cancelExternalNodeDrag() => _dropPreview.value = null;

  /// 用全局指针坐标放置节点。返回 false 表示画布外取消，工作流不变化。
  bool addNodeFromGlobal(String configId, Offset globalPosition) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return false;
    final local = box.globalToLocal(globalPosition);
    if (!(Offset.zero & box.size).contains(local)) return false;
    var flow = _toFlow(local) - const Offset(30, 20);
    if (SettingsStore.instance.snapNodePlacement) {
      const step = 20.0;
      flow = Offset(
        (flow.dx / step).round() * step,
        (flow.dy / step).round() * step,
      );
    }
    final id = store.addNode(configId, flow);
    final node = store.nodeOf(id);
    if (node != null) {
      final size = nodeSize(node, store.edges, result: store.results[id]);
      final min = _toFlow(const Offset(12, 12));
      final bottomRight = _toFlow(
        Offset(
          math.max(12, box.size.width - 12),
          math.max(12, box.size.height - 12),
        ),
      );
      final maxX = math.max(min.dx, bottomRight.dx - size.width);
      final maxY = math.max(min.dy, bottomRight.dy - size.height);
      final clamped = Offset(
        flow.dx.clamp(min.dx, maxX),
        flow.dy.clamp(min.dy, maxY),
      );
      if (clamped != flow) store.moveNode(id, clamped);
    }
    cancelExternalNodeDrag();
    _focusNode.requestFocus();
    return true;
  }

  void addNodeAtViewportCenter(String configId) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final global = box.localToGlobal(box.size.center(Offset.zero));
    addNodeFromGlobal(configId, global);
  }

  void createPackageAtViewportCenter(Map<String, dynamic> template) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final center = _toFlow(box.size.center(Offset.zero));
    store.instantiatePackage(template, center - const Offset(130, 55));
    _focusNode.requestFocus();
  }

  void _startPackageDrag(NodeGroup group) {
    _focusNode.requestFocus();
    store.setMultiSelected(group.nodeIds.toSet());
    store.snapshotNow();
    _draggingPackageId = group.id;
  }

  void _updatePackageDrag(NodeGroup group, Offset screenDelta) {
    if (_draggingPackageId != group.id) return;
    final delta = screenDelta / _zoom;
    store.moveNodesTo(group.nodeIds.toSet(), {
      for (final id in group.nodeIds) id: _nodePos(id) + delta,
    });
  }

  void _endPackageDrag(NodeGroup group) {
    if (_draggingPackageId != group.id) return;
    _draggingPackageId = null;
    store.finishLayoutChange();
  }

  void _expandPackage(NodeGroup group) {
    final members = [
      for (final node in store.nodes)
        if (group.nodeIds.contains(node.id)) node,
    ];
    if (members.isEmpty) {
      store.setPackageCollapsed(group.id, false);
      return;
    }
    if (_conversionLayoutController.isAnimating) {
      _conversionLayoutController.stop();
      if (_conversionLayoutTargets.isNotEmpty) {
        store.moveNodesTo(
          _conversionLayoutTargets.keys.toSet(),
          _conversionLayoutTargets,
        );
        store.finishLayoutChange();
      }
    }
    final ids = group.nodeIds.toSet();
    final sizes = {
      for (final node in members)
        node.id: nodeSize(node, store.edges, result: store.results[node.id]),
    };
    final obstacles = [
      for (final node in store.nodes)
        if (!ids.contains(node.id))
          node.position &
              nodeSize(node, store.edges, result: store.results[node.id]),
    ];
    final targets = resolveRepulsiveNodeLayout(
      moving: [
        for (final node in members)
          (id: node.id, position: node.position, size: sizes[node.id]!),
      ],
      obstacles: obstacles,
      gap: 34,
    );
    final proxy = packageProxyRect(
      group.copyWith(collapsed: true),
      store.nodes,
      store.edges,
    );
    final center =
        proxy?.center ??
        members
                .map(
                  (node) => node.position + sizes[node.id]!.center(Offset.zero),
                )
                .reduce((a, b) => a + b) /
            members.length.toDouble();
    final origins = {
      for (final node in members)
        node.id: Offset.lerp(
          center - sizes[node.id]!.center(Offset.zero),
          targets[node.id]!,
          .2,
        )!,
    };

    store.setPackageCollapsed(group.id, false);
    store.moveNodesTo(ids, origins);
    final duration = MotionTokens.spatial(context);
    if (duration == Duration.zero) {
      store.moveNodesTo(ids, targets);
      store.finishLayoutChange();
      return;
    }
    _conversionLayoutOrigins = origins;
    _conversionLayoutTargets = targets;
    _conversionLayoutController.duration = Duration(
      milliseconds: (duration.inMilliseconds * 1.25).round(),
    );
    _conversionLayoutController.forward(from: 0);
  }

  void _collapsePackage(NodeGroup group) {
    final memberIds = group.nodeIds.toSet();
    if (_conversionLayoutController.isAnimating &&
        _conversionLayoutTargets.keys.any(memberIds.contains)) {
      _conversionLayoutController.stop();
      final targets = Map<String, Offset>.from(_conversionLayoutTargets);
      _conversionLayoutOrigins = const {};
      _conversionLayoutTargets = const {};
      store.moveNodesTo(targets.keys.toSet(), targets);
      store.finishLayoutChange();
    }
    store.setPackageCollapsed(group.id, true);
  }

  void _bump() {
    _revision++;
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _conversionLayoutController = AnimationController(vsync: this)
      ..addListener(() {
        if (_conversionLayoutTargets.isEmpty) return;
        final progress = MotionTokens.emphasized.transform(
          _conversionLayoutController.value,
        );
        store.moveNodesTo(_conversionLayoutTargets.keys.toSet(), {
          for (final entry in _conversionLayoutTargets.entries)
            entry.key: Offset.lerp(
              _conversionLayoutOrigins[entry.key],
              entry.value,
              progress,
            )!,
        });
      })
      ..addStatusListener((status) {
        if (status != AnimationStatus.completed) return;
        store.finishLayoutChange();
        _conversionLayoutOrigins = const {};
        _conversionLayoutTargets = const {};
      });
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
    // onTap 在手势竞技场结束后执行；此处再次收回焦点，覆盖属性输入框在
    // pointer-down 之后完成的延迟聚焦，保证随后 Delete 到达画布。
    _focusNode.requestFocus();
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
    store.selectEdge(null);
    if (store.selectedEdgeId != null) store.selectEdge(null);
  }

  bool _pointInAnyNode(Offset flow) {
    for (final n in store.nodes) {
      if (_nodeHiddenByCollapsedPackage(n.id)) continue;
      final r = n.position & nodeSize(n, store.edges);
      if (r.contains(flow)) return true;
    }
    return false;
  }

  bool _nodeHiddenByCollapsedPackage(String nodeId) => store.groups.any(
    (group) =>
        group.isPackage && group.collapsed && group.nodeIds.contains(nodeId),
  );

  NodeGroup? _collapsedPackageForNode(String nodeId) => store.groups
      .where(
        (group) =>
            group.isPackage &&
            group.collapsed &&
            group.nodeIds.contains(nodeId),
      )
      .firstOrNull;

  Offset _packageAnchorForEdge(
    NodeGroup group,
    Rect rect,
    GraphEdge edge, {
    required bool isSource,
  }) {
    final ports = isSource
        ? packageOutputPorts(group, store.nodes, store.edges)
        : packageInputPorts(group, store.nodes, store.edges);
    final nodeId = isSource ? edge.source : edge.target;
    final socketId = isSource ? edge.sourceHandle : edge.targetHandle;
    final port = ports
        .where((item) => item.nodeId == nodeId && item.socketId == socketId)
        .firstOrNull;
    return port == null
        ? (isSource ? rect.centerRight : rect.centerLeft)
        : packagePortAnchor(rect, ports, port, isSource: isSource);
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
    final moved = _dragSnapshotted;
    _draggingId = null;
    _dragIds = {};
    _dragOrigins = {};
    _dragSnapshotted = false;
    if (_shift && single && _insertPreviewEdge != null) {
      _insertNodeIntoEdge(id, _insertPreviewEdge!);
    }
    _insertPreviewEdge = null;
    _insertPreviewPoint = null;
    if (moved) store.finishLayoutChange();
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

  // ---------------- Package 几何与命中 ----------------

  /// 分组包围盒:成员矩形 + 组内连线断点 + 14px/zoom 内边距(世界坐标;
  /// 与 _EdgesPainter._paintGroupFrames 一致)
  Rect? _groupRect(NodeGroup g, {bool expandedGeometry = false}) {
    final proxy = expandedGeometry
        ? null
        : packageProxyRect(g, store.nodes, store.edges);
    if (proxy != null) return proxy;
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
    // 与 _paintGroupFrames 一致:顶部额外空间容纳内嵌标签(不对称 pad)
    final padX = 14.0 / _zoom;
    final padBottom = 14.0 / _zoom;
    final padTop = 22.0 / _zoom;
    return Rect.fromLTRB(
      box.left - padX,
      box.top - padTop,
      box.right + padX,
      box.bottom + padBottom,
    );
  }

  Rect? _packageTargetRect(NodeGroup group) {
    Rect? box;
    for (final node in store.nodes) {
      if (!group.nodeIds.contains(node.id)) continue;
      final position = _conversionLayoutTargets[node.id] ?? node.position;
      final rect = position & nodeSize(node, store.edges);
      box = box == null ? rect : box.expandToInclude(rect);
    }
    if (box == null) return null;
    return Rect.fromLTRB(
      box.left - 14 / _zoom,
      box.top - 22 / _zoom,
      box.right + 14 / _zoom,
      box.bottom + 14 / _zoom,
    );
  }

  /// 返回包含 flow 点的 Package id。
  String? _groupAt(Offset flow) {
    for (final g in store.groups) {
      if (!g.isPackage) continue;
      final r = _groupRect(g);
      if (r != null && r.contains(flow)) return g.id;
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
    _connectConversion = false;
    _connectDownScreen = null; // 首次 move 时记录
    // 广播激活状态:起点端口播放脉冲强调动画
    _sockHover.value = (
      active: SocketHoverState(id, socketId, isSource),
      hover: null,
    );
    store.selectNode(id);
    _bump();
  }

  /// 连线松开:命中兼容端口 → 建边;Alt 命中可转换端口 → 中插转换节点链建边;
  /// 空白处 → 弹出新建节点菜单并携带待连线
  void _finishConnect(_Conn conn, Offset flowPos) {
    final target = _findSocketAt(flowPos, conn, allowConversion: _alt);
    if (target != null) {
      // 类型不兼容但可转换:自动插入转换节点链(可能多步),置于两端口路径上
      final convPath = target.conversion
          ? _conversionPath(conn, target.type)
          : null;
      if (convPath != null && convPath.isNotEmpty) {
        _insertConversion(conn, target, convPath);
      } else if (conn.isSource) {
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
    } else {
      // 空白处松开:弹出新建节点菜单并携带待连线
      _menuPos = _toScreen(flowPos);
      _pendingConn = conn;
    }
    _bump();
  }

  /// Alt 拖拽到不可直连但可转换的端口:在两端口路径上自动插入一条转换节点链
  /// (依次为 [path] 中每个转换节点),并依次建立 源端口→→→目标端口 连线。
  /// 多步时节点沿两端口连线方向均匀排布,间距不足时自动向两端延展避免重叠。
  void _insertConversion(
    _Conn conn,
    ({
      String nodeId,
      String socketId,
      bool isSource,
      SocketType type,
      Offset anchor,
      bool conversion,
    })
    target,
    List<String> path,
  ) {
    if (path.isEmpty) return;
    final k = path.length;
    final dir = target.anchor - conn.anchor;
    final len = dir.distance;
    final unit = len < 1e-6 ? const Offset(1, 0) : dir / len;
    // 相邻节点中心距:略大于节点宽,保证不互相遮挡
    const spacing = 300.0;
    final half = math.max(len / 2, spacing * (k + 1) / 2);
    final center = (conn.anchor + target.anchor) / 2;
    // 先建全部节点(不依赖后面的连线),再统一建边
    final ids = <String>[];
    final inSocks = <String>[];
    final outSocks = <String>[];
    var logLabels = <String>[];
    for (var i = 0; i < k; i++) {
      final cfg = getConfig(path[i]);
      if (cfg == null || cfg.inputs.isEmpty || cfg.outputs.isEmpty) continue;
      // 第 i 个节点位置:整段(中心 ± half)内按 (i+1)/(k+1) 等分
      final t = (i + 1) / (k + 1);
      final pos = center + unit * (t - 0.5) * 2 * half;
      final nid = store.addNode(path[i], pos, triggerRun: false);
      ids.add(nid);
      inSocks.add(cfg.inputs.first.id);
      outSocks.add(cfg.outputs.first.id);
      logLabels.add(cfg.label);
    }
    if (ids.isEmpty) return;
    // 依次接线:源端口 → 节点1 → 节点2 → … → 目标端口
    if (conn.isSource) {
      store.onConnect(
        source: conn.nodeId,
        target: ids.first,
        sourceHandle: conn.socketId,
        targetHandle: inSocks.first,
        triggerRun: false,
      );
      for (var i = 0; i + 1 < ids.length; i++) {
        store.onConnect(
          source: ids[i],
          target: ids[i + 1],
          sourceHandle: outSocks[i],
          targetHandle: inSocks[i + 1],
          triggerRun: false,
        );
      }
      store.onConnect(
        source: ids.last,
        target: target.nodeId,
        sourceHandle: outSocks.last,
        targetHandle: target.socketId,
        triggerRun: false,
      );
    } else {
      store.onConnect(
        source: target.nodeId,
        target: ids.first,
        sourceHandle: target.socketId,
        targetHandle: inSocks.first,
        triggerRun: false,
      );
      for (var i = 0; i + 1 < ids.length; i++) {
        store.onConnect(
          source: ids[i],
          target: ids[i + 1],
          sourceHandle: outSocks[i],
          targetHandle: inSocks[i + 1],
          triggerRun: false,
        );
      }
      store.onConnect(
        source: ids.last,
        target: conn.nodeId,
        sourceHandle: outSocks.last,
        targetHandle: conn.socketId,
        triggerRun: false,
      );
    }
    store.addLog('ok', '已自动插入转换节点:${logLabels.join('→')}');
    _startConversionLayout(
      conn.isSource
          ? [conn.nodeId, ...ids, target.nodeId]
          : [target.nodeId, ...ids, conn.nodeId],
    );
    if (store.autoRun) store.runAfterGraphChange(edgeChanged: true);
  }

  void _startConversionLayout(List<String> orderedIds) {
    if (_conversionLayoutController.isAnimating) {
      _conversionLayoutController.stop();
      if (_conversionLayoutTargets.isNotEmpty) {
        store.moveNodesTo(
          _conversionLayoutTargets.keys.toSet(),
          _conversionLayoutTargets,
        );
        store.finishLayoutChange();
      }
    }
    final movingIds = orderedIds.toSet();
    final nodesById = {for (final node in store.nodes) node.id: node};
    final ordered = [
      for (final id in orderedIds)
        if (nodesById[id] != null) nodesById[id]!,
    ];
    if (ordered.length < 2) return;
    final sizes = {
      for (final node in ordered)
        node.id: nodeSize(node, store.edges, result: store.results[node.id]),
    };
    final obstacles = <Rect>[];
    for (final node in store.nodes) {
      final size = nodeSize(node, store.edges, result: store.results[node.id]);
      if (!movingIds.contains(node.id)) {
        obstacles.add(node.position & size);
      }
    }

    final first = ordered.first;
    final last = ordered.last;
    final firstCenter = first.position + sizes[first.id]!.center(Offset.zero);
    final lastCenter = last.position + sizes[last.id]!.center(Offset.zero);
    final midpoint = (firstCenter + lastCenter) / 2;
    final delta = lastCenter - firstCenter;
    const chainGap = 72.0;
    final horizontal = delta.dx.abs() >= delta.dy.abs();
    final sign = horizontal
        ? (delta.dx < 0 ? -1.0 : 1.0)
        : (delta.dy < 0 ? -1.0 : 1.0);
    final totalExtent =
        ordered.fold<double>(
          0,
          (sum, node) =>
              sum +
              (horizontal ? sizes[node.id]!.width : sizes[node.id]!.height),
        ) +
        chainGap * (ordered.length - 1);
    var cursor =
        (horizontal ? midpoint.dx : midpoint.dy) - sign * totalExtent / 2;
    final preferred = <String, Offset>{};
    for (final node in ordered) {
      final size = sizes[node.id]!;
      if (horizontal) {
        final left = sign > 0 ? cursor : cursor - size.width;
        preferred[node.id] = Offset(left, midpoint.dy - size.height / 2);
        cursor += sign * (size.width + chainGap);
      } else {
        final top = sign > 0 ? cursor : cursor - size.height;
        preferred[node.id] = Offset(midpoint.dx - size.width / 2, top);
        cursor += sign * (size.height + chainGap);
      }
    }
    final groupBounds = ordered
        .map((node) => preferred[node.id]! & sizes[node.id]!)
        .reduce((a, b) => a.expandToInclude(b));
    final groupTarget = resolveRepulsiveNodeLayout(
      moving: [
        (id: '_chain', position: groupBounds.topLeft, size: groupBounds.size),
      ],
      obstacles: obstacles,
      gap: 36,
    )['_chain']!;
    final groupShift = groupTarget - groupBounds.topLeft;
    final targets = {
      for (final node in ordered) node.id: preferred[node.id]! + groupShift,
    };
    final origins = {for (final node in ordered) node.id: node.position};
    if (targets.entries.every((e) => origins[e.key] == e.value)) return;
    final duration = MotionTokens.spatial(context);
    if (duration == Duration.zero) {
      store.moveNodesTo(movingIds, targets);
      store.finishLayoutChange();
      return;
    }
    _conversionLayoutOrigins = origins;
    _conversionLayoutTargets = targets;
    _conversionLayoutController.duration = duration;
    _conversionLayoutController.forward(from: 0);
  }

  /// 被拖拽端口 → 目标端口类型 的最短转换链(多步);无转换路径返回 null
  List<String>? _conversionPath(_Conn conn, SocketType targetType) {
    return conn.isSource
        ? conversionPath(conn.type, targetType)
        : conversionPath(targetType, conn.type);
  }

  ({
    String nodeId,
    String socketId,
    bool isSource,
    SocketType type,
    Offset anchor,
    bool conversion,
  })?
  _findSocketAt(Offset flowPos, _Conn conn, {bool allowConversion = false}) {
    final threshold = 26 / _zoom;
    ({
      String nodeId,
      String socketId,
      bool isSource,
      SocketType type,
      Offset anchor,
      bool conversion,
    })?
    best;
    var bestDist = threshold;
    for (final n in store.nodes) {
      if (_nodeHiddenByCollapsedPackage(n.id)) continue;
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
          n.position.dx + (isTargetInput ? -1.5 : nodeVisualWidth(n) + 1.5),
          n.position.dy + rows[i].center,
        );
        final d = (pos - flowPos).distance;
        // 直连:类型兼容;Alt 拖拽:类型不兼容但存在转换链也可作为落点
        final compat = isCompatible(conn.type, socks[i].type);
        final convertible =
            !compat &&
            allowConversion &&
            _conversionPath(conn, socks[i].type) != null;
        if (d < bestDist && (compat || convertible)) {
          bestDist = d;
          best = (
            nodeId: n.id,
            socketId: rows[i].id,
            isSource: !isTargetInput,
            type: socks[i].type,
            anchor: pos,
            conversion: convertible,
          );
        }
      }
    }
    for (final group in store.groups.reversed) {
      if (!group.isPackage || !group.collapsed) continue;
      if (group.nodeIds.contains(conn.nodeId)) continue;
      final rect = packageProxyRect(group, store.nodes, store.edges);
      if (rect == null) continue;
      final isTargetInput = conn.isSource;
      final ports = isTargetInput
          ? packageInputPorts(group, store.nodes, store.edges)
          : packageOutputPorts(group, store.nodes, store.edges);
      for (final port in ports) {
        final pos = packagePortAnchor(
          rect,
          ports,
          port,
          isSource: !isTargetInput,
        );
        final distance = (pos - flowPos).distance;
        final compatible = isCompatible(conn.type, port.type);
        final convertible =
            !compatible &&
            allowConversion &&
            _conversionPath(conn, port.type) != null;
        if (distance < bestDist && (compatible || convertible)) {
          bestDist = distance;
          best = (
            nodeId: port.nodeId,
            socketId: port.socketId,
            isSource: !isTargetInput,
            type: port.type,
            anchor: pos,
            conversion: convertible,
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
    for (final group in store.groups.reversed) {
      final rect = packageProxyRect(group, store.nodes, store.edges);
      if (rect == null) continue;
      final inputs = packageInputPorts(group, store.nodes, store.edges);
      final outputs = packageOutputPorts(group, store.nodes, store.edges);
      for (final port in inputs) {
        final anchor = packagePortAnchor(rect, inputs, port, isSource: false);
        if (Rect.fromCircle(
          center: anchor,
          radius: hw / 2 + m,
        ).contains(flow)) {
          return (
            nodeId: port.nodeId,
            socketId: port.socketId,
            isSource: false,
            type: port.type,
            anchor: anchor,
          );
        }
      }
      for (final port in outputs) {
        final anchor = packagePortAnchor(rect, outputs, port, isSource: true);
        if (Rect.fromCircle(
          center: anchor,
          radius: hw / 2 + m,
        ).contains(flow)) {
          return (
            nodeId: port.nodeId,
            socketId: port.socketId,
            isSource: true,
            type: port.type,
            anchor: anchor,
          );
        }
      }
    }
    // 逆序遍历:后绘制的节点位于图层上方,其端口判定区优先(与渲染顺序一致)
    for (final n in store.nodes.reversed) {
      if (_nodeHiddenByCollapsedPackage(n.id)) continue;
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
    NodeCanvas.lastMouseWorldPos = flow; // 同步到 static 供外部(main.dart)访问
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
    // 缩放手柄先在子 Listener 中开启状态；祖先 Listener 收到同一个 down 时
    // 不得再把它解释为节点拖动，否则缩放结束后会残留拖动态。
    if (_resizingViewerId != null) return;
    // 预览窗面板内:指针事件由预览窗自身处理,画布层一律忽略
    // (防误触发清空多选/框选/Alt 划线等画布逻辑)
    if (_inMiniMap(e.position)) return;
    // 缩放控制按钮组内:指针事件由按钮自身处理,画布层一律忽略
    if (_inZoomControl(e.position)) return;
    // 从属性输入框等控件返回画布时立即收回键盘焦点，确保 Delete/Backspace
    // 由画布快捷键处理。此前节点虽然已选中，EditableText 仍会吞掉删除键。
    if (e.buttons & kPrimaryButton != 0) _focusNode.requestFocus();
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
    // 右键:节点上走卡片折叠；Package 区域打开 Package 菜单；
    // 其余空白打开新建节点菜单。
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
      final settings = SettingsStore.instance;
      if (settings.radialNodeMenuEnabled) {
        _beginRadialGesture(e.localPosition);
      } else if (settings.contextNodeMenuEnabled) {
        _menuPos = e.localPosition;
        _pendingConn = null;
        _bump();
      }
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
      if (_nodeHiddenByCollapsedPackage(n.id)) continue;
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
        store.selectEdge(null);
        if (store.selectedEdgeId != null) store.selectEdge(null);
        return;
      }
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
        store.selectEdge(hit.edge.id); // 选中整条连线
        return;
      }
      if (_alt) {
        // Alt 按在空白处:同样进入划线模式(光标继续移动时给划过的连线加断点)
        _startAltSweep(flow);
      }
    }
  }

  void _onBackgroundMove(PointerMoveEvent e) {
    final resizingViewerId = _resizingViewerId;
    if (resizingViewerId != null) {
      _onViewerResizeUpdate(resizingViewerId, e.delta);
      return;
    }
    if (_rightPressScreen != null) {
      _updateRadialGesture(e.localPosition);
      return;
    }
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
      // Alt 拖拽:兼容端口与"可转换端口"均可作为落点(转换落点稍后中插转换节点)
      final target = _findSocketAt(flow, _connecting!, allowConversion: _alt);
      _connectFlowPos = target?.anchor ?? flow;
      _connectConversion = target?.conversion ?? false;
      final cur = _sockHover.value;
      final hover = target == null
          ? null
          : SocketHoverState(
              target.nodeId,
              target.socketId,
              target.isSource,
              conversion: target.conversion,
            );
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
    NodeCanvas.lastMouseWorldPos = flow; // 拖动中也同步 world pos(main.dart 粘贴定位用)
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
    final resizingViewerId = _resizingViewerId;
    if (resizingViewerId != null) {
      _onViewerResizeEnd(resizingViewerId);
      _downPosScreen = null;
      return;
    }
    if (_rightPressScreen != null) {
      _finishRadialGesture(e.localPosition);
      _downPosScreen = null;
      return;
    }
    // 菜单打开期间:事件由菜单自身处理,画布层一律忽略(防反复重建)
    if (_menuPos != null) return;
    // 预览窗内的松开/预览窗拖拽结束(可能拖出面板后松开):画布层忽略,
    // 否则会走到"点击空白清空多选"误清选择
    if (_inMiniMap(e.position) || _miniMapDragging) {
      _miniMapDragging = false;
      _downPosScreen = null;
      return;
    }
    // 缩放控制按钮组内松开:画布层忽略(防误触“点击空白清空多选”)
    if (_inZoomControl(e.position)) {
      _downPosScreen = null;
      return;
    }
    // 结束 Alt 划线手势:为新增断点统一记录日志并触发一次流水线
    if (_altSweeping) {
      if (_altSweptEdges.isNotEmpty) {
        store.addLog('info', '已在 ${_altSweptEdges.length} 条曲线上插入分割点');
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
      _connectConversion = false;
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
        store.selectEdge(null);
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
      if (_nodeHiddenByCollapsedPackage(n.id)) continue;
      final r = n.position & nodeSize(n, store.edges);
      if (rect.overlaps(r)) sel.add(n.id);
    }
    for (final group in store.groups) {
      final proxy = packageProxyRect(group, store.nodes, store.edges);
      if (proxy != null && rect.overlaps(proxy)) sel.addAll(group.nodeIds);
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
      final sourcePackage = _collapsedPackageForNode(e.source);
      final targetPackage = _collapsedPackageForNode(e.target);
      if (sourcePackage != null && sourcePackage.id == targetPackage?.id) {
        continue;
      }
      final sourceRect = sourcePackage == null
          ? null
          : packageProxyRect(sourcePackage, store.nodes, store.edges);
      final targetRect = targetPackage == null
          ? null
          : packageProxyRect(targetPackage, store.nodes, store.edges);
      final a = sourceRect == null || sourcePackage == null
          ? edgeSourceAnchor(e, src, store.edges)
          : _packageAnchorForEdge(sourcePackage, sourceRect, e, isSource: true);
      final b = targetRect == null || targetPackage == null
          ? edgeTargetAnchor(e, tgt, store.edges)
          : _packageAnchorForEdge(
              targetPackage,
              targetRect,
              e,
              isSource: false,
            );
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
    final factor = e.scrollDelta.dy < 0 ? 1.1 : 1 / 1.1;
    _zoomAt(e.localPosition, factor);
  }

  /// 以屏幕 anchor 为锚点缩放 factor 倍(钳制在 0.25~2.5),锚点保持不动
  void _zoomAt(Offset anchor, double factor) {
    setState(() {
      final nz = math.min(2.5, math.max(0.25, _zoom * factor));
      final f = nz / _zoom;
      _zoom = nz;
      _zoomNotifier.value = nz;
      _pan = Offset(
        anchor.dx - (anchor.dx - _pan.dx) * f,
        anchor.dy - (anchor.dy - _pan.dy) * f,
      );
    });
  }

  /// +/− 按钮缩放:以视口中心为锚点
  void _zoomStep(double factor) {
    _zoomAt(Offset(_canvasSize.width / 2, _canvasSize.height / 2), factor);
  }

  void _onBackgroundPanStart(DragStartDetails d) {
    // 菜单打开期间:pan 手势与 Listener 指针事件是两条独立路径,
    // 菜单弹出瞬间可能仍有残余 pan 手势在竞技场中,此处一并忽略(防反复重建)
    if (_menuPos != null) return;
    final flow = _toFlow(d.localPosition);
    for (final group in store.groups) {
      if (!group.isPackage || !group.collapsed) continue;
      final proxy = packageProxyRect(group, store.nodes, store.edges);
      if (proxy != null && proxy.contains(flow)) {
        _startPackageDrag(group);
        _panFromNode = true;
        return;
      }
    }
    // 记录起点是否落在节点内部:节点内部拖动不移动背景
    // (端口连线手势在节点卡内部,此处只处理冒泡到背景的 pan)
    _panFromNode = _pointInAnyNode(_toFlow(d.localPosition));
    // 节点/多选/分组拖动中(分组标签在节点外,无法靠 _pointInAnyNode 命中):绝不平移、不框选
    if (_draggingId != null || _draggingPackageId != null) {
      _panFromNode = true;
    }
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
    final packageId = _draggingPackageId;
    if (packageId != null) {
      final group = store.groups
          .where((item) => item.id == packageId)
          .firstOrNull;
      if (group != null) _updatePackageDrag(group, d.delta);
      return;
    }
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
    final packageId = _draggingPackageId;
    if (packageId != null) {
      final group = store.groups
          .where((item) => item.id == packageId)
          .firstOrNull;
      if (group != null) _endPackageDrag(group);
      _panFromNode = false;
      _bump();
      return;
    }
    _panFromNode = false;
    if (_boxDragging) {
      _finishBoxSelect(_boxEnd ?? _boxStart ?? Offset.zero);
      _boxDragging = false;
      _boxStart = null;
      _boxEnd = null;
    }
    _bump();
  }

  void _beginRadialGesture(Offset localPosition) {
    _rightPressScreen = localPosition;
    _radialPointer = localPosition;
    _radialVisible = false;
    _radialSection = null;
    _radialDetail = null;
    _radialItems = const [];
    _radialLockedItem = null;
    _radialDetachAnchor = null;
    _radialHoldTimer?.cancel();
    _radialHoldTimer = Timer(const Duration(milliseconds: 170), () {
      if (!mounted || _rightPressScreen == null) return;
      _radialVisible = true;
      _updateRadialGesture(_radialPointer);
    });
  }

  void _updateRadialGesture(Offset localPosition) {
    final center = _rightPressScreen;
    if (center == null) return;
    _radialPointer = localPosition;
    final delta = localPosition - center;
    if (!_radialVisible && delta.distance >= 12) {
      _radialHoldTimer?.cancel();
      _radialVisible = true;
    }
    if (!_radialVisible) return;
    if (_radialLockedItem != null) {
      if (delta.distance < radialDeadRadius) {
        _radialLockedItem = null;
        _radialDetachAnchor = null;
        _radialSection = null;
        _radialDetail = null;
        _radialItems = const [];
      }
      _bump();
      return;
    }
    final section = radialSectionIndex(delta);
    final items = section == null
        ? const <RadialNodeItem>[]
        : radialItemsFor(
            radialNodeSections[section],
            SettingsStore.instance.packageLibrary,
          );
    final detail = section == null
        ? null
        : radialDetailIndex(delta, section, items.length);
    _radialSection = section;
    _radialItems = items;
    _radialDetail = detail;
    if (delta.distance >= radialDetachRadius &&
        detail != null &&
        detail < items.length) {
      _radialLockedItem = items[detail];
      _radialDetachAnchor = radialAttachmentPoint(center, localPosition);
    }
    _bump();
  }

  void _finishRadialGesture(Offset localPosition) {
    final center = _rightPressScreen;
    if (center == null) return;
    _radialHoldTimer?.cancel();
    final wasVisible = _radialVisible;
    if (wasVisible) _updateRadialGesture(localPosition);
    final item = _radialLockedItem;
    _rightPressScreen = null;
    _radialVisible = false;
    _radialSection = null;
    _radialDetail = null;
    _radialItems = const [];
    _radialLockedItem = null;
    _radialDetachAnchor = null;
    if (item != null) {
      if (item.isPackage) {
        final value = SettingsStore.instance.packageLibrary
            .where((entry) => '${entry['id']}' == item.id)
            .firstOrNull;
        if (value != null) {
          store.instantiatePackage(
            value,
            _toFlow(localPosition) - const Offset(130, 55),
          );
        }
      } else {
        final box = context.findRenderObject();
        if (box is RenderBox && box.hasSize) {
          addNodeFromGlobal(item.id, box.localToGlobal(localPosition));
          SettingsStore.instance.recordNodeUse(item.id);
        }
      }
    } else if (!wasVisible && SettingsStore.instance.contextNodeMenuEnabled) {
      _menuPos = center;
      _pendingConn = null;
    }
    _bump();
  }

  void _cancelRadialGesture() {
    _radialHoldTimer?.cancel();
    _rightPressScreen = null;
    _radialVisible = false;
    _radialSection = null;
    _radialDetail = null;
    _radialItems = const [];
    _radialLockedItem = null;
    _radialDetachAnchor = null;
  }

  void _closeMenu() {
    _menuPos = null;
    _pendingConn = null;
    _nodeMenuFor = null;
    _groupMenuFor = null;
    _bump();
  }

  // ---------------- 多选右键菜单动作(Package/复制/删除) ----------------

  Future<void> _packageSelection() async {
    final sel = _nodeMenuFor;
    if (sel == null || sel.length < 2) return;
    final t = SyphonTheme.of(context);
    final panelColor = t.isDark
        ? const Color(0xFF34383E)
        : const Color(0xFFE1E3E6);
    var draftName = 'Package';
    final name = await showDialog<String>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .3),
      builder: (ctx) => AlertDialog(
        backgroundColor: panelColor,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.black.withValues(alpha: .35),
        shape: RoundedRectangleBorder(
          side: BorderSide(color: t.strokeStrong),
          borderRadius: BorderRadius.circular(14),
        ),
        title: Text('创建 Package', style: TextStyle(color: t.text)),
        content: TextFormField(
          initialValue: draftName,
          autofocus: true,
          style: TextStyle(color: t.text),
          decoration: InputDecoration(
            labelText: 'Package 名称',
            labelStyle: TextStyle(color: t.textDim),
            filled: true,
            fillColor: t.bgNode.withValues(alpha: .72),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide: BorderSide(color: t.strokeStrong),
            ),
          ),
          onChanged: (value) => draftName = value,
          onFieldSubmitted: (value) => Navigator.of(ctx).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(draftName),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name == null) return;
    store.createPackage(sel.toList(), name);
    _closeMenu();
  }

  void _savePackageToLibrary(String groupId) {
    final value = store.packageTemplate(groupId);
    if (value == null) return;
    SettingsStore.instance.savePackage(value);
    store.addLog('ok', 'Package 已保存到库');
    _closeMenu();
  }

  void _instantiateSavedPackage(Map<String, dynamic> value) {
    final menu = _menuPos;
    if (menu == null) return;
    store.instantiatePackage(value, _toFlow(menu));
    _closeMenu();
  }

  Widget? _savedPackageMenu() {
    final items = SettingsStore.instance.packageLibrary;
    if (items.isEmpty) return null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 5, 10, 3),
          child: Text(
            'PACKAGE 库',
            style: TextStyle(
              color: SyphonTheme.of(context).textFaint,
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: .8,
            ),
          ),
        ),
        for (final item in items.take(8))
          CtxMenuItem(
            icon: Icons.inventory_2_outlined,
            label: '${item['name'] ?? 'Package'}',
            onTap: () => _instantiateSavedPackage(item),
          ),
      ],
    );
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

  void _dissolvePackageFromMenu() {
    final gid = _groupMenuFor;
    if (gid != null) store.dissolvePackage(gid);
    _closeMenu();
  }

  void _activateViewer(String id) {
    _focusNode.requestFocus();
    final selected = _shift ? {...store.multiSelected, id} : <String>{id};
    if (!setEquals(selected, store.multiSelected)) {
      store.setMultiSelected(selected);
    }
    if (store.selectedSplitEdgeId != null) store.selectSplitEdge(null);
    if (store.selectedEdgeId != null) store.selectEdge(null);
  }

  void _pickNode(String configId) {
    final menuPos = _menuPos;
    _menuPos = null;
    _groupMenuFor = null;
    if (menuPos == null) return;
    final flowPos = _toFlow(menuPos);
    final initPos = Offset(flowPos.dx - 30, flowPos.dy - 20);

    store.addNode(configId, initPos);
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
    _bump();
  }

  void deleteSelection() {
    // 优先级 1:选中整条连线 → 删连线
    if (store.selectedEdgeId != null) {
      store.removeEdge(store.selectedEdgeId!);
      store.selectEdge(null);
      _bump();
      return;
    }
    // 优先级 2:选中断点 → 清断点(mid),保留连线
    if (store.selectedSplitEdgeId != null) {
      store.updateEdgeData(store.selectedSplitEdgeId!, null);
      store.selectSplitEdge(null);
      store.selectEdge(null);
      _bump();
      return;
    }
    // 优先级 3:删除多选集节点;退化为单选
    final sel = store.multiSelected;
    final ids = sel.isNotEmpty
        ? sel.toList()
        : (store.selectedId != null ? [store.selectedId!] : const <String>[]);
    if (ids.isEmpty) return;
    store.removeNodes(ids);
    _bump();
  }

  /// 外部 CSV/Excel 文件拖入窗口:在放下位置生成"表格输入"节点并自动导入。
  /// [clientPos] 为窗口客户区坐标(逻辑像素),[text] 为解析后的统一 CSV 文本,
  /// [fileName] 为文件基础名(不含扩展名),节点标题栏据此显示。
  void dropFileText(Offset clientPos, String text, {String fileName = ''}) {
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
      'name': fileName,
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
    _radialHoldTimer?.cancel();
    _cutTicker.dispose();
    _conversionLayoutController.dispose();
    _zoomNotifier.dispose();
    _dropPreview.dispose();
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

  NodeCardCallbacks get _cardCallbacks => NodeCardCallbacks(
    onSelect: _onSelect,
    onActivateViewer: _activateViewer,
    onSecondaryTap: _onSecondaryTap,
    onResizeStart: _onViewerResizeStart,
    onResizeUpdate: _onViewerResizeUpdate,
    onResizeEnd: _onViewerResizeEnd,
  );

  void _onViewerResizeStart(String id) {
    _activateViewer(id);
    _draggingId = null;
    _dragIds = {};
    _dragOrigins = {};
    _resizingViewerId = id;
    _viewerResizeSnapshotted = false;
  }

  void _onViewerResizeUpdate(String id, Offset screenDelta) {
    if (_resizingViewerId != id) return;
    final node = store.nodeOf(id);
    if (node == null) return;
    if (!_viewerResizeSnapshotted && screenDelta != Offset.zero) {
      store.snapshotNow();
      _viewerResizeSnapshotted = true;
    }
    store.resizeViewerNode(
      id,
      nodeVisualWidth(node) + screenDelta.dx / _zoom,
      nodeViewerHeight(node) + screenDelta.dy / _zoom,
    );
  }

  void _onViewerResizeEnd(String id) {
    if (_resizingViewerId != id) return;
    _resizingViewerId = null;
    _viewerResizeSnapshotted = false;
    store.finishLayoutChange();
  }

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
          _buildExternalDropPreview(t),
          Positioned.fill(
            child: AnimatedSwitcher(
              duration: MotionTokens.standard(context),
              reverseDuration: MotionTokens.quick(context),
              switchInCurve: MotionTokens.emphasized,
              switchOutCurve: MotionTokens.exit,
              child: !_radialVisible || _rightPressScreen == null
                  ? const SizedBox.shrink(
                      key: ValueKey('radial-node-menu-empty'),
                    )
                  : RadialNodeMenu(
                      key: const ValueKey('radial-node-menu-visible'),
                      center: _rightPressScreen!,
                      pointer: _radialPointer,
                      sectionIndex: _radialSection,
                      detailIndex: _radialDetail,
                      detailItems: _radialItems,
                      lockedItem: _radialLockedItem,
                      detachAnchor: _radialDetachAnchor,
                    ),
            ),
          ),
          Positioned.fill(
            child: AnimatedSwitcher(
              duration: MotionTokens.standard(context),
              reverseDuration: MotionTokens.quick(context),
              switchInCurve: MotionTokens.emphasized,
              switchOutCurve: MotionTokens.exit,
              transitionBuilder: (child, animation) =>
                  PopupMotionScope(animation: animation, child: child),
              child: _menuPos == null
                  ? const SizedBox.shrink(key: ValueKey('canvas-menu-empty'))
                  : KeyedSubtree(
                      key: const ValueKey('canvas-menu-visible'),
                      child: _buildMenuLayer(),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExternalDropPreview(SyphonTheme t) {
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _dropPreview,
          builder: (context, _) {
            final preview = _dropPreview.value;
            if (preview == null) return const SizedBox.shrink();
            final color = preview.accepted ? preview.color : t.textFaint;
            return Stack(
              children: [
                Positioned(
                  left: preview.local.dx - 25,
                  top: preview.local.dy - 25,
                  child: Container(
                    key: const Key('canvas-node-drop-preview'),
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: color.withValues(alpha: .09),
                      border: Border.all(
                        color: color.withValues(alpha: .72),
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: color.withValues(alpha: .24),
                          blurRadius: 20,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
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
                  _buildZoomControl(t),
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
          final selected = store.selectedId;
          final paintNodes = selected == null
              ? nodes
              : [
                  ...nodes.where((node) => node.id != selected),
                  ...nodes.where((node) => node.id == selected),
                ];
          return Transform(
            transform: Matrix4.identity()
              ..translateByDouble(_pan.dx, _pan.dy, 0, 1)
              ..scaleByDouble(_zoom, _zoom, 1, 1),
            alignment: Alignment.topLeft,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                _buildBgLayer(t),
                for (final group in store.groups)
                  if (group.isPackage) _buildPackageBackgroundLayer(group, t),
                _buildEdgesLayer(t, nodes, edges),
                for (final n in paintNodes) _buildNodeLayer(n),
                // Keep collapsed Package proxies above their hidden members so
                // the whole card, including its expand button, remains hittable.
                for (final group in store.groups)
                  if (group.isPackage) _buildPackageLayer(group, t),
                for (final group in store.groups)
                  if (group.isPackage) _buildExpandedPackageToggle(group, t),
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
      child: AnimatedBuilder(
        animation: store.layoutRevision,
        builder: (context, _) => RepaintBoundary(
          child: CustomPaint(
            painter: _buildEdgePainter(t, store.nodes, store.edges),
            size: Size.infinite,
          ),
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
      connectConversion: _connectConversion,
      selectedSplitEdgeId: store.selectedSplitEdgeId,
      selectedEdgeId: store.selectedEdgeId,
      revision: _revision,
      flowEdge: t.flowEdge,
      accent: t.accent,
      warn: t.warn,
      isDark: t.isDark,
      zoom: _zoom,
      slashTrail: _slashTrail,
      slashTrailProgress: slashProg,
    );
  }

  /// 单节点卡片层(独立 RepaintBoundary:hover/拖拽只重绘该卡片层)
  Widget _buildNodeLayer(GraphNode n) {
    return AnimatedBuilder(
      key: ValueKey('node-layer-${n.id}'),
      animation: store.layoutRevision,
      child: CanvasZoom(
        notifier: _zoomNotifier,
        child: RepaintBoundary(
          child: TweenAnimationBuilder<double>(
            key: ValueKey('node-entry-${n.id}'),
            tween: Tween(begin: 0.0, end: 1.0),
            duration: MotionTokens.spatial(context),
            curve: MotionTokens.emphasized,
            builder: (context, value, child) => BlurScaleTransition(
              animation: AlwaysStoppedAnimation(value),
              alignment: Alignment.topLeft,
              child: child!,
            ),
            child: NodeCard(nodeId: n.id, callbacks: _cardCallbacks),
          ),
        ),
      ),
      builder: (context, child) {
        final current = store.nodes
            .where((node) => node.id == n.id)
            .firstOrNull;
        if (current == null) return const SizedBox.shrink();
        final package = store.groups
            .where(
              (group) => group.isPackage && group.nodeIds.contains(current.id),
            )
            .firstOrNull;
        if (package == null) {
          return Transform.translate(offset: current.position, child: child);
        }
        final hidden = package.collapsed;
        return TweenAnimationBuilder<double>(
          key: ValueKey('package-member-motion-${current.id}'),
          tween: Tween(end: hidden ? 0 : 1),
          duration: MotionTokens.spatial(context),
          curve: MotionTokens.emphasized,
          builder: (context, value, positionedChild) => IgnorePointer(
            ignoring: hidden,
            child: Opacity(
              opacity: value,
              child: Transform.scale(
                scale: .94 + .06 * value,
                alignment: Alignment.topLeft,
                child: positionedChild,
              ),
            ),
          ),
          child: Transform.translate(offset: current.position, child: child),
        );
      },
    );
  }

  Widget _buildPackageBackgroundLayer(NodeGroup group, SyphonTheme t) {
    return AnimatedBuilder(
      key: ValueKey('package-region-layout-${group.id}'),
      animation: store.layoutRevision,
      builder: (context, _) {
        final current = store.groups
            .where((item) => item.id == group.id)
            .firstOrNull;
        if (current == null) return const SizedBox.shrink();
        final isExpanding =
            _conversionLayoutController.isAnimating &&
            _conversionLayoutTargets.keys.any(current.nodeIds.contains);
        // During repulsive expansion the nodes move every frame. Anchor the
        // control to the final frame so it cannot slide out from under a click.
        final rect = isExpanding
            ? _packageTargetRect(current)
            : _groupRect(current, expandedGeometry: true);
        if (rect == null) return const SizedBox.shrink();
        return Positioned(
          left: rect.left,
          top: rect.top,
          width: rect.width,
          height: rect.height,
          child: IgnorePointer(
            child: AnimatedOpacity(
              key: ValueKey('package-region-${current.id}'),
              opacity: current.collapsed ? 0 : 1,
              duration: MotionTokens.spatial(context),
              curve: MotionTokens.emphasized,
              child: AnimatedScale(
                scale: current.collapsed ? .97 : 1,
                duration: MotionTokens.spatial(context),
                curve: MotionTokens.emphasized,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _PackageRegionPainter(
                          color: const Color(0xFF8A9099),
                          zoom: _zoom,
                        ),
                      ),
                    ),
                    Positioned(
                      left: 7 / _zoom,
                      top: 5 / _zoom,
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 6 / _zoom,
                          vertical: 2 / _zoom,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF777D86).withValues(alpha: .88),
                          borderRadius: BorderRadius.circular(4 / _zoom),
                        ),
                        child: Text(
                          current.name,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 11 / _zoom,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildExpandedPackageToggle(NodeGroup group, SyphonTheme t) {
    return AnimatedBuilder(
      key: ValueKey('package-expanded-control-layout-${group.id}'),
      animation: store.layoutRevision,
      builder: (context, _) {
        final current = store.groups
            .where((item) => item.id == group.id)
            .firstOrNull;
        if (current == null) return const SizedBox.shrink();
        final isExpanding =
            _conversionLayoutController.isAnimating &&
            _conversionLayoutTargets.keys.any(current.nodeIds.contains);
        final rect = isExpanding
            ? _packageTargetRect(current)
            : _groupRect(current, expandedGeometry: true);
        if (rect == null) return const SizedBox.shrink();
        final size = 24 / _zoom;
        return Positioned(
          left: rect.right - size - 6 / _zoom,
          top: rect.top + 5 / _zoom,
          width: size,
          height: size,
          child: IgnorePointer(
            ignoring: current.collapsed,
            child: AnimatedOpacity(
              opacity: current.collapsed ? 0 : 1,
              duration: MotionTokens.spatial(context),
              curve: MotionTokens.emphasized,
              child: Tooltip(
                message: '收起 Package',
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    key: ValueKey('package-toggle-expanded-${current.id}'),
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (_) => _collapsePackage(current),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xFF8A9099).withValues(alpha: .2),
                        borderRadius: BorderRadius.circular(6 / _zoom),
                        border: Border.all(
                          color: const Color(0xFF8A9099).withValues(alpha: .5),
                          width: 1 / _zoom,
                        ),
                      ),
                      child: Icon(
                        Icons.unfold_less_rounded,
                        size: 15 / _zoom,
                        color: t.textDim,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPackageLayer(NodeGroup group, SyphonTheme t) {
    return AnimatedBuilder(
      key: ValueKey('package-layout-${group.id}'),
      animation: store.layoutRevision,
      builder: (context, _) {
        final current = store.groups
            .where((item) => item.id == group.id)
            .firstOrNull;
        if (current == null) return const SizedBox.shrink();
        final compact = current.copyWith(collapsed: true);
        final rect = packageProxyRect(compact, store.nodes, store.edges);
        if (rect == null) return const SizedBox.shrink();
        final selected = current.nodeIds.every(store.multiSelected.contains);
        final inputs = packageInputPorts(current, store.nodes, store.edges);
        final outputs = packageOutputPorts(current, store.nodes, store.edges);
        final members = [
          for (final node in store.nodes)
            if (current.nodeIds.contains(node.id)) node,
        ];
        return Positioned(
          key: ValueKey('package-node-${group.id}'),
          left: rect.left,
          top: rect.top,
          width: rect.width,
          height: rect.height,
          child: IgnorePointer(
            ignoring: !current.collapsed,
            child: AnimatedOpacity(
              opacity: current.collapsed ? 1 : 0,
              duration: MotionTokens.spatial(context),
              curve: MotionTokens.emphasized,
              child: AnimatedScale(
                scale: current.collapsed ? 1 : .92,
                duration: MotionTokens.spatial(context),
                curve: MotionTokens.emphasized,
                alignment: Alignment.topLeft,
                child: MouseRegion(
                  cursor: SystemMouseCursors.move,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      _focusNode.requestFocus();
                      store.setMultiSelected(current.nodeIds.toSet());
                    },
                    child: AnimatedContainer(
                      duration: MotionTokens.standard(context),
                      decoration: BoxDecoration(
                        color: const Color(0xFF8A9099).withValues(alpha: .12),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: selected ? t.accent : const Color(0xFF8A9099),
                          width: selected ? 2 : 1.2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: .12),
                            blurRadius: 18,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(11),
                        child: BackdropFilter(
                          filter: ui.ImageFilter.blur(sigmaX: 7, sigmaY: 7),
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Positioned(
                                left: 10,
                                top: 10,
                                child: Text(
                                  inputs.isEmpty ? '无前置输入' : '前置输入',
                                  key: ValueKey(
                                    'package-input-label-${group.id}',
                                  ),
                                  style: TextStyle(
                                    color: t.textFaint,
                                    fontSize: 8,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              Positioned(
                                right: 10,
                                top: 10,
                                child: Text(
                                  outputs.isEmpty ? '无后续输出' : '后续输出',
                                  key: ValueKey(
                                    'package-output-label-${group.id}',
                                  ),
                                  style: TextStyle(
                                    color: t.textFaint,
                                    fontSize: 8,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              for (
                                var index = 0;
                                index < inputs.length;
                                index++
                              )
                                _packagePortVisual(
                                  inputs[index],
                                  index,
                                  isSource: false,
                                  theme: t,
                                ),
                              for (
                                var index = 0;
                                index < outputs.length;
                                index++
                              )
                                _packagePortVisual(
                                  outputs[index],
                                  index,
                                  isSource: true,
                                  theme: t,
                                ),
                              Positioned(
                                left: 72,
                                right: 72,
                                top: 27,
                                bottom: 8,
                                child: RepaintBoundary(
                                  key: ValueKey(
                                    'package-glass-overview-${current.id}',
                                  ),
                                  child: ImageFiltered(
                                    imageFilter: ui.ImageFilter.blur(
                                      sigmaX: .75,
                                      sigmaY: .75,
                                    ),
                                    child: CustomPaint(
                                      painter: _PackageOverviewPainter(
                                        nodes: members,
                                        edges: store.edges,
                                        color: const Color(0xFF737983),
                                        revision: store.layoutRevision.value,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                left: 86,
                                right: 86,
                                bottom: 13,
                                child: IgnorePointer(
                                  child: Text(
                                    '${current.name} · ${current.nodeIds.length}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: t.text,
                                      fontSize: 9,
                                      fontWeight: FontWeight.w700,
                                      shadows: [
                                        Shadow(
                                          color: t.bgNode.withValues(alpha: .9),
                                          blurRadius: 5,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                right: 8,
                                bottom: 8,
                                child: Tooltip(
                                  message: '展开 Package',
                                  child: MouseRegion(
                                    cursor: SystemMouseCursors.click,
                                    child: GestureDetector(
                                      key: ValueKey(
                                        'package-toggle-${current.id}',
                                      ),
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () => _expandPackage(current),
                                      child: Container(
                                        width: 28,
                                        height: 24,
                                        decoration: BoxDecoration(
                                          color: const Color(
                                            0xFF8A9099,
                                          ).withValues(alpha: .16),
                                          borderRadius: BorderRadius.circular(
                                            7,
                                          ),
                                        ),
                                        child: const Icon(
                                          Icons.unfold_more_rounded,
                                          size: 16,
                                          color: Color(0xFF737983),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                left: 92,
                                right: 92,
                                top: 7,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.drag_indicator_rounded,
                                      size: 12,
                                      color: t.textFaint,
                                    ),
                                    const SizedBox(width: 2),
                                    Text(
                                      '拖动区域',
                                      style: TextStyle(
                                        color: t.textFaint,
                                        fontSize: 8,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _packagePortVisual(
    PackagePort port,
    int index, {
    required bool isSource,
    required SyphonTheme theme,
  }) {
    final dot = Container(
      width: 11,
      height: 11,
      decoration: BoxDecoration(
        color: socketColor(port.type),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: theme.bgSurface, width: 1),
      ),
    );
    final label = Flexible(
      child: Text(
        port.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: theme.textDim, fontSize: 9),
      ),
    );
    return Positioned(
      key: ValueKey(
        'package-${isSource ? 'output' : 'input'}-${port.nodeId}-${port.socketId}',
      ),
      left: isSource ? null : -5.5,
      right: isSource ? -5.5 : null,
      top: 37.5 + index * 22,
      width: 82,
      height: 18,
      child: IgnorePointer(
        child: Row(
          mainAxisAlignment: isSource
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          children: isSource
              ? [label, const SizedBox(width: 5), dot]
              : [dot, const SizedBox(width: 5), label],
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
        animation: Listenable.merge([store, store.layoutRevision]),
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

  /// 左下角缩放控制:竖直胶囊按钮组(+/-),点击以视口中心为锚点缩放画布
  Widget _buildZoomControl(SyphonTheme t) {
    return Positioned(
      left: 14,
      bottom: 14,
      child: Container(
        key: _zoomControlKey,
        width: 44,
        decoration: BoxDecoration(
          color: t.bgFloat,
          borderRadius: BorderRadius.circular(22), // 胶囊:圆角 = 半宽
          border: Border.all(color: t.stroke),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: t.isDark ? 0.35 : 0.12),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ZoomControlButton(
              icon: Icons.add,
              tooltip: '放大',
              onTap: () => _zoomStep(1.2),
            ),
            Container(height: 1, color: t.stroke),
            _ZoomControlButton(
              icon: Icons.remove,
              tooltip: '缩小',
              onTap: () => _zoomStep(1 / 1.2),
            ),
          ],
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
  /// Package 右键 → Package 菜单；多选右键 → Package/复制/删除；
  /// 空白 → NodeMenu(新建节点)。
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
      if (g != null && g.isPackage) {
        menu = PackageContextMenu(
          position: _menuPos!,
          onSave: () => _savePackageToLibrary(g!.id),
          onDissolve: _dissolvePackageFromMenu,
        );
      }
    } else if (nodeMenu != null) {
      menu = NodeContextMenu(
        position: _menuPos!,
        canPackage: nodeMenu.length >= 2,
        onRunNode: () {
          store.runPipelineDirty(nodeMenu);
          _closeMenu();
        },
        onPackage: _packageSelection,
        onDuplicate: _duplicateSelection,
        onDelete: _deleteSelectionFromMenu,
      );
    } else {
      menu = NodeMenu(
        position: _menuPos!,
        onPick: _pickNode,
        onClose: _closeMenu,
        bottomSlot: _savedPackageMenu(),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _closeMenu,
      onSecondaryTap: _closeMenu,
      child: Stack(clipBehavior: Clip.none, children: [?menu]),
    );
  }

  // ---------------- 画布层事件回调 ----------------

  /// 当前焦点是否位于文本输入框内(EditableText 子树)。
  /// 搜索框等输入框位于画布 Focus 子树内,按键会自输入框向上冒泡经过此处;
  /// 若不甄别直接标记 handled,会吞掉空格/退格/回车,输入框将完全无法编辑。
  static bool _focusInTextField() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    return ctx != null &&
        ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // 文本框聚焦时:所有按键交还输入框——冒泡到 App 层的
    // DefaultTextEditingShortcuts 与引擎文本输入(IME)才能真正处理:
    // 空格/回车插入字符、退格删除、Ctrl+C/V 复制粘贴选中文本。
    if (_focusInTextField()) {
      // 按住空格期间焦点移入输入框:KeyUp 也被放行,需在此复位平移态
      if (event is KeyUpEvent && event.logicalKey == LogicalKeyboardKey.space) {
        _spaceDown = false;
      }
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.space) {
      _spaceDown = event is KeyUpEvent ? false : true;
      _bump();
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (SettingsStore.instance.matchesShortcut('delete', event) ||
          event.logicalKey == LogicalKeyboardKey.delete ||
          event.logicalKey == LogicalKeyboardKey.backspace) {
        // 节点菜单打开期间(焦点在搜索框,已被上方 _focusInTextField 守卫放行;
        // 此分支仅覆盖焦点仍在画布的兜底场景):退格/删除不删除选中节点。
        if (_menuPos != null) return KeyEventResult.handled;
        deleteSelection();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        if (_rightPressScreen != null || _radialVisible) {
          _cancelRadialGesture();
          _bump();
        } else if (_menuPos != null) {
          _closeMenu();
        } else {
          store.selectNode(null);
          store.setMultiSelected({});
          store.selectSplitEdge(null);
          store.selectEdge(null);
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
    if (_inZoomControl(e.position)) return; // 缩放控制按钮上不高亮画布内容
    if (_connecting != null) return; // 拖拽中由 move 更新
    _updateHover(e.localPosition);
  }

  /// 指针取消(如窗口失焦):清理连线拖拽状态,避免残留预览线
  void _onPointerCancel(PointerCancelEvent e) {
    final resizingViewerId = _resizingViewerId;
    if (resizingViewerId != null) _onViewerResizeEnd(resizingViewerId);
    if (_rightPressScreen != null || _radialVisible) {
      _cancelRadialGesture();
      _bump();
    }
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
    final packageId = _draggingPackageId;
    if (packageId != null) {
      final group = store.groups
          .where((item) => item.id == packageId)
          .firstOrNull;
      if (group != null) _endPackageDrag(group);
    }
    _panFromNode = false;
    _boxDragging = false;
    _boxStart = null;
    _boxEnd = null;
  }
}

/// 缩放胶囊内的单个半圆按钮:悬停/按下高亮(与 Fluent 悬停反馈一致)
class _ZoomControlButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _ZoomControlButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_ZoomControlButton> createState() => _ZoomControlButtonState();
}

class _ZoomControlButtonState extends State<_ZoomControlButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: Tooltip(
        message: widget.tooltip,
        child: GestureDetector(
          onTapDown: (_) => setState(() => _hover = true),
          onTapUp: (_) => setState(() => _hover = false),
          onTapCancel: () => setState(() => _hover = false),
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 44,
            height: 40,
            decoration: BoxDecoration(
              // 同色 alpha=0,避免 transparent(黑 RGB)插值先变黑
              color: _hover ? t.bgRaise : t.bgRaise.withValues(alpha: 0),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(
              widget.icon,
              size: 20,
              color: _hover ? t.accent : t.text,
            ),
          ),
        ),
      ),
    );
  }
}
