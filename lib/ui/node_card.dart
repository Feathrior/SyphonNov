// 节点卡片:标题栏 + 端口列 + 参数摘要 + 查看器预览 + 输出行(由 React 版 NodeComponent.tsx 移植)
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/color_utils.dart';
import '../models/data.dart' hide Column;
import '../models/exec_engine.dart';
import '../models/registry.dart';
import '../store/graph_store.dart';
import 'canvas_geometry.dart';
import 'principled.dart';
import 'theme.dart';
import 'viewer.dart';

/// 节点卡片交互回调(由画布注入)
/// 说明:节点拖动由画布层 Listener 统一管理(绕开手势竞技场,见 node_canvas.dart),
/// 卡片仅负责选中/折叠等轻量点击事件
class NodeCardCallbacks {
  final void Function(String id) onSelect;
  final void Function(String id) onSecondaryTap;

  const NodeCardCallbacks({
    required this.onSelect,
    required this.onSecondaryTap,
  });
}

class NodeCard extends StatelessWidget {
  final String nodeId;
  final NodeCardCallbacks callbacks;
  const NodeCard({super.key, required this.nodeId, required this.callbacks});

  @override
  Widget build(BuildContext context) {
    final store = GraphStore.instance;
    GraphNode? node;
    for (final n in store.nodes) {
      if (n.id == nodeId) {
        node = n;
        break;
      }
    }
    if (node == null) return const SizedBox.shrink();
    final cfg = getConfig(node.configId);
    if (cfg == null) return const SizedBox.shrink();
    final edges = store.edges;
    final result = store.results[nodeId];
    // 选中态:多选集合内任一成员均显示 accent 光环(Shift 多选/框选/分组)
    final selected = store.multiSelected.contains(nodeId);
    final zoom = CanvasZoom.of(context);
    final t = SyphonTheme.of(context);
    final dark = t.isDark;

    final size = nodeSize(node, edges, result: result);
    // 描边像素不随缩放变化(CSS border 不参与 transform)
    final borderW = math.max(0.75, 2 / zoom);
    final category =
        kCategoryInfo[cfg.category] ?? const CategoryInfo('', '#7c8db5', '•');
    final catColor = parseColor(category.color);
    // 暗色主题下顶栏稍微压暗 0.15,提升白字可读性(原先提亮会稀释对比度)
    final headerBg = dark ? t.darken(catColor, 0.15) : catColor;
    // 输出计数:有数据的输出口数量
    final outputCount = cfg.outputs
        .where((o) => result?.outputs[o.id] != null)
        .length;

    final inSocks = inputSockets(node, edges);
    final outSocks = outputSockets(node, edges);
    final summary = node.collapsed ? '' : paramSummary(node, cfg);
    // 缩放隐藏阈值(React zoom<0.55):仅内容渐隐,端口保持原位置原尺寸;
    // 折叠时节点变矮走紧凑柄视图(handlesOnly)。
    final zoomHidden = zoom < 0.55;
    final collapsed = node.collapsed;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => callbacks.onSelect(nodeId),
      onSecondaryTapUp: (_) => callbacks.onSecondaryTap(nodeId),
      child: Container(
        width: size.width,
        height: size.height,
        decoration: _cardDecoration(t, selected, borderW, zoom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 标题栏:分类色背景,图标/标题/折叠指示一律白字(React .nf-node-header)
            // 节点拖动由画布层 Listener 统一管理,此处不挂手势(见 NodeCardCallbacks 注释)
            _buildHeader(cfg, category, node, result, t, headerBg),
            // 主体(React .nf-node-body: padding 8px 12px 10px)
            // 折叠/缩放切换时渐隐渐显;切换器子级强制 topLeft 对齐,
            // 避免 AnimatedSwitcher 默认居中布局把端口挪到中间
            Expanded(
              child: Padding(
                padding: _bodyPadding(node),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 160),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  layoutBuilder: (currentChild, previousChildren) => Stack(
                    alignment: Alignment.topLeft,
                    children: <Widget>[...previousChildren, ?currentChild],
                  ),
                  child: collapsed
                      ? KeyedSubtree(
                          key: const ValueKey('handles'),
                          child: _handlesOnly(
                            node,
                            inSocks,
                            outSocks,
                            edges,
                            t,
                            zoom,
                          ),
                        )
                      : KeyedSubtree(
                          key: const ValueKey('body'),
                          child: _buildBody(
                            context,
                            node,
                            cfg,
                            inSocks,
                            outSocks,
                            edges,
                            size,
                            zoom,
                            t,
                            dark,
                            summary,
                            outputCount,
                            result,
                            contentOpacity: zoomHidden ? 0 : 1,
                          ),
                        ),
                ),
              ),
            ),
            // 底部错误条:danger 背景 10% 透明(React .nf-error)
            if (!node.collapsed && result?.error != null)
              _buildErrorBar(result!, t, zoom),
          ],
        ),
      ),
    );
  }

  /// 卡片描边与投影:选中态 accent 光环,常态轻微阴影(阴影随 zoom 缩放)
  BoxDecoration _cardDecoration(
    SyphonTheme t,
    bool selected,
    double borderW,
    double zoom,
  ) {
    return BoxDecoration(
      color: t.bgNode,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(
        color: selected ? t.accent : t.strokeStrong,
        width: borderW,
      ),
      boxShadow: selected
          ? [
              // 0 0 0 1px accent
              BoxShadow(color: t.accent, spreadRadius: 1 / zoom, blurRadius: 0),
              // 0 0 8px accentGlow
              BoxShadow(color: t.accentGlow, blurRadius: 8 / zoom),
            ]
          : [
              // 0 1px 2px rgba(0,0,0,0.05)
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 2 / zoom,
                offset: Offset(0, 1 / zoom),
              ),
            ],
    );
  }

  EdgeInsets _bodyPadding(GraphNode node) {
    return EdgeInsets.fromLTRB(
      NodeGeom.bodyPadLeft,
      node.collapsed ? NodeGeom.collapsedPadTop : NodeGeom.bodyPadTop,
      NodeGeom.bodyPadRight,
      node.collapsed ? NodeGeom.collapsedPadBottom : NodeGeom.bodyPadBottom,
    );
  }

  /// 标题栏(React .nf-header):分类图标 + 标题 + 折叠指示 + 错误徽章
  Widget _buildHeader(
    NodeConfig cfg,
    CategoryInfo category,
    GraphNode node,
    ExecResult? result,
    SyphonTheme t,
    Color headerBg,
  ) {
    return Container(
      height: NodeGeom.headerH,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: headerBg,
        // 上圆角 6px,比节点本体小 2px(React border-radius 6px 6px 0 0)
        borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
      ),
      child: Row(
        children: [
          // 分类图标:16px 宽,居中(React .nf-cat-icon)
          SizedBox(
            width: 16,
            child: Text(
              category.icon,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.white),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              cfg.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Colors.white),
            ),
          ),
          // 折叠指示(React .nf-collapse-ind,opacity 0.85)
          Text(
            node.collapsed ? '▸' : '▾',
            style: TextStyle(
              fontSize: 10,
              color: Colors.white.withValues(alpha: 0.85),
            ),
          ),
          // 错误徽章:16px 圆点,白字(React .nf-node-badge)
          if (result?.error != null)
            Container(
              width: 16,
              height: 16,
              alignment: Alignment.center,
              margin: const EdgeInsets.only(left: 5),
              decoration: BoxDecoration(
                color: t.danger,
                shape: BoxShape.circle,
              ),
              child: Text(
                '!',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 主体内容:端口两列(始终原位置原尺寸)+ 参数摘要 + 查看器 + 输出状态行
  /// (React .nf-node-body)。[contentOpacity] 控制非端口内容的渐隐
  /// (缩放隐藏时端口不动,只有内容淡出)。
  Widget _buildBody(
    BuildContext context,
    GraphNode node,
    NodeConfig cfg,
    List<SocketGeom> inSocks,
    List<SocketGeom> outSocks,
    List<GraphEdge> edges,
    Size size,
    double zoom,
    SyphonTheme t,
    bool dark,
    String summary,
    int outputCount,
    ExecResult? result, {
    double contentOpacity = 1.0,
  }) {
    const fade = Duration(milliseconds: 160);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 输入/输出端口两列(React .nf-sockets: gap 8)——handle 永不渐隐,
        // 位置/尺寸与正常模式完全一致;行内名称文字随 contentOpacity 淡出
        _buildSocketColumns(
          context,
          node,
          cfg,
          inSocks,
          outSocks,
          edges,
          size,
          zoom,
          labelOpacity: contentOpacity,
        ),
        // 非端口内容:只改透明度、不动布局
        AnimatedOpacity(
          opacity: contentOpacity,
          duration: fade,
          curve: Curves.easeOut,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (summary.isNotEmpty) ...[
                const SizedBox(height: NodeGeom.paramLineMargin),
                _buildSummary(summary, t, dark),
              ],
              if (cfg.outputs.isNotEmpty) ...[
                const SizedBox(height: NodeGeom.outputsLineMargin),
                _buildOutputsLine(cfg, outputCount, result, t),
              ],
            ],
          ),
        ),
        if (cfg.isViewer) ...[
          const SizedBox(height: NodeGeom.viewerMargin),
          Expanded(
            child: AnimatedOpacity(
              opacity: contentOpacity,
              duration: fade,
              curve: Curves.easeOut,
              child: _viewer(cfg, nodeId),
            ),
          ),
        ],
      ],
    );
  }

  /// 输入/输出端口两列:输入靠左、输出靠右,行内省略号截断。
  /// [labelOpacity] 控制行内名称/类型文字的渐隐(缩放隐藏时无任何文字)。
  Widget _buildSocketColumns(
    BuildContext context,
    GraphNode node,
    NodeConfig cfg,
    List<SocketGeom> inSocks,
    List<SocketGeom> outSocks,
    List<GraphEdge> edges,
    Size size,
    double zoom, {
    double labelOpacity = 1.0,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            children: [
              // 行间 gap 与几何计算(_rows 的 y += h + socketGap)保持一致,
              // 否则曲线锚点/命中区会逐行比 handle 实际位置偏下
              for (var i = 0; i < inSocks.length; i++) ...[
                if (i > 0) const SizedBox(height: NodeGeom.socketGap),
                _socketRow(
                  context,
                  node,
                  inSocks[i],
                  i,
                  edges,
                  isSource: false,
                  sock: i < cfg.inputs.length ? cfg.inputs[i] : null,
                  nodeSize: size,
                  zoom: zoom,
                  labelOpacity: labelOpacity,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            children: [
              for (var i = 0; i < outSocks.length; i++) ...[
                if (i > 0) const SizedBox(height: NodeGeom.socketGap),
                _socketRow(
                  context,
                  node,
                  outSocks[i],
                  i,
                  edges,
                  isSource: true,
                  sock: cfg.outputs[i],
                  nodeSize: size,
                  zoom: zoom,
                  labelOpacity: labelOpacity,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 参数摘要(React .nf-param-line):单行省略号,等宽字体
  Widget _buildSummary(String summary, SyphonTheme t, bool dark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: t.bgRaise,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        summary,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 10,
          color: dark ? t.textFaint : const Color(0xFF333333),
        ),
      ),
    );
  }

  /// 输出状态行(React .nf-outputs-line):小圆点 + "N/M 输出[ · 出错]"
  Widget _buildOutputsLine(
    NodeConfig cfg,
    int outputCount,
    ExecResult? result,
    SyphonTheme t,
  ) {
    return Row(
      children: [
        // 输出小圆点:有输出 success 色,否则 textFaint
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: outputCount > 0 ? t.success : t.textFaint,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          '$outputCount/${cfg.outputs.length} 输出${result?.error != null ? ' · 出错' : ''}',
          style: TextStyle(fontSize: 10, color: t.textFaint),
        ),
      ],
    );
  }

  /// 底部错误条:danger 背景 10% 透明(React .nf-error)
  Widget _buildErrorBar(ExecResult result, SyphonTheme t, double zoom) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: t.danger.withValues(alpha: 0.1),
        border: Border(
          top: BorderSide(
            color: t.danger.withValues(alpha: 0.24),
            width: 1 / zoom,
          ),
        ),
      ),
      child: Text(
        result.error!,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: t.danger),
      ),
    );
  }

  Widget _viewer(NodeConfig cfg, String nodeId) {
    if (cfg.id == 'viz_principled') {
      return PrincipledCanvas(nodeId: nodeId);
    }
    if (cfg.id == 'data_output') {
      return DataOutputView(nodeId: nodeId);
    }
    return ChartViewer(nodeId: nodeId);
  }

  /// 折叠/缩放过小:仅显示端口 handle,位置保持在节点边缘(左输入/右输出)
  Widget _handlesOnly(
    GraphNode node,
    List<SocketGeom> inSocks,
    List<SocketGeom> outSocks,
    List<GraphEdge> edges,
    SyphonTheme t,
    double zoom,
  ) {
    // 折叠/缩放隐藏时 handle 仍保持在节点边缘位置(输入贴左、输出贴右),
    // 垂直居中于所在行 —— 与正常模式 _socketRow 的定位公式一致,
    // 画布层 _handleAt 命中检测与连线锚点均按此几何计算
    final start = node.collapsed
        ? NodeGeom.collapsedPadTop
        : NodeGeom.bodyPadTop;
    double colH = 0;
    for (final s in [...inSocks, ...outSocks]) {
      colH = math.max(colH, s.y + s.h - NodeGeom.headerH);
    }
    Widget wrapHandle(SocketGeom s, bool isSource) {
      final type = _sockType(node, s.id, isSource: isSource);
      final hh = handleH(portCount(node.id, s.id, edges));
      // 与 _socketRow 一致:输入 left -(bodyPadLeft+7)、输出 right -(bodyPadRight+7),
      // 行内垂直居中;top 以 body 顶(headerH+start)为基准换算到本 Stack 内
      return Positioned(
        left: isSource ? null : -(NodeGeom.bodyPadLeft + 7),
        right: isSource ? -(NodeGeom.bodyPadRight + 7) : null,
        top: (s.y - NodeGeom.headerH - start) + (s.h - hh) / 2,
        child: _SocketHandle(
          nodeId: node.id,
          socketId: s.id,
          isSource: isSource,
          color: socketColor(type),
          hh: hh,
          t: t,
          zoom: zoom,
        ),
      );
    }

    return SizedBox(
      height: colH,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final s in inSocks) wrapHandle(s, false),
          for (final s in outSocks) wrapHandle(s, true),
        ],
      ),
    );
  }

  SocketType _sockType(
    GraphNode node,
    String socketId, {
    required bool isSource,
  }) {
    final cfg = getConfig(node.configId);
    if (cfg == null) return SocketType.any;
    final list = isSource ? cfg.outputs : cfg.inputs;
    for (final s in list) {
      if (s.id == socketId) return s.type;
    }
    return SocketType.any;
  }

  Widget _socketRow(
    BuildContext context,
    GraphNode node,
    SocketGeom g,
    int index,
    List<GraphEdge> edges, {
    required bool isSource,
    required Socket? sock,
    required Size nodeSize,
    required double zoom,
    double labelOpacity = 1.0,
  }) {
    final t = SyphonTheme.of(context);
    final dark = t.isDark;
    final type = sock?.type ?? SocketType.any;
    final color = socketColor(type);
    final regCount = _regularInputCount(node);
    final exposedKey = isSource
        ? null
        : (index >= regCount ? node.exposed[index - regCount] : null);
    final label =
        sock?.name ??
        (exposedKey != null
            ? paramLabel(node, exposedKey)
            : kSocketLabel[type] ?? '输入');
    final isExposed = exposedKey != null;
    // 端口名颜色:暴露参数用 textFaint,其余亮色 #141414 / 暗色 textDim(React)
    final nameColor = isExposed
        ? t.textFaint
        : (dark ? t.textDim : const Color(0xFF141414));
    // handle 高度:单连线 11px,多连线动态延长(React handleH(portCount))
    final hh = handleH(portCount(node.id, g.id, edges));

    final handle = _SocketHandle(
      nodeId: node.id,
      socketId: g.id,
      isSource: isSource,
      color: color,
      hh: hh,
      isExposed: isExposed,
      t: t,
      zoom: zoom,
    );

    // 行内容:输入 [名称 类型],输出右对齐 [名称 类型]
    final textRow = Row(
      mainAxisAlignment: isSource
          ? MainAxisAlignment.end
          : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: nameColor,
              fontWeight: isExposed ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
        const SizedBox(width: 5),
        // 端口类型小字(React .nf-socket-type,9px,与端口同色)
        Text(
          kSocketLabel[type] ?? '',
          style: TextStyle(fontSize: 9, color: color),
        ),
      ],
    );

    return SizedBox(
      height: g.h,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 名称/类型文字:缩放隐藏时淡出(只留 handle),布局不变
          AnimatedOpacity(
            opacity: labelOpacity,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            child: textRow,
          ),
          // handle 绝对定位,溢出节点边缘:左输入 left -7,右输出 right -7
          // (body 有 12px 左右内边距,故需额外减 12 才能对齐节点边框外 7px)
          // 纯视觉组件:手势/悬停命中在画布层完成(卡片内越界子级收不到事件)
          Positioned(
            left: isSource ? null : -(NodeGeom.bodyPadLeft + 7),
            right: isSource ? -(NodeGeom.bodyPadRight + 7) : null,
            top: (g.h - hh) / 2,
            child: handle,
          ),
        ],
      ),
    );
  }

  int _regularInputCount(GraphNode node) {
    final cfg = getConfig(node.configId);
    return cfg?.inputs.length ?? 0;
  }

  String paramLabel(GraphNode node, String key) {
    final cfg = getConfig(node.configId);
    if (cfg == null) return key;
    for (final p in cfg.params) {
      if (p.key == key) return p.label;
    }
    return key;
  }
}

/// 端口 handle(纯视觉 + 强调动画,无手势):
/// - 常态:11px 宽圆角矩形(暴露参数为圆形),边框像素恒定(React .nf-handle)
/// - 悬停:easeOutBack 弹性放大 1.28 + 端口同色发光
/// - 连线拖拽起点:放大 1.5 + 更强发光 + 向外扩散的脉冲光环
/// 悬停/激活状态由画布层命中检测后经 CanvasSockets 广播
/// (handle 溢出节点边缘,Padding/Column 等各层命中测试会裁剪越界子级,
/// 卡片内挂 MouseRegion/Listener 均收不到事件,必须在画布层处理)
class _SocketHandle extends StatefulWidget {
  final String nodeId;
  final String socketId;
  final bool isSource;
  final Color color;
  final double hh;
  final bool isExposed;
  final SyphonTheme t;
  final double zoom;

  const _SocketHandle({
    required this.nodeId,
    required this.socketId,
    required this.isSource,
    required this.color,
    required this.hh,
    required this.t,
    this.isExposed = false,
    required this.zoom,
  });

  @override
  State<_SocketHandle> createState() => _SocketHandleState();
}

class _SocketHandleState extends State<_SocketHandle>
    with SingleTickerProviderStateMixin {
  bool _dragging = false; // 该端口为连线拖拽起点
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    // 提前初始化而非惰性:避免从未使用过的 _pulse 在 dispose() 时才创建
    // (此时查找 TickerMode 祖先已不安全,测试卸载整树时会崩溃)
    _pulse =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 900),
        )..addListener(() {
          if (mounted && _dragging) setState(() {});
        });
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = CanvasSockets.of(context);
    final hovered =
        s.hover?.match(widget.nodeId, widget.socketId, widget.isSource) ??
        false;
    final active =
        s.active?.match(widget.nodeId, widget.socketId, widget.isSource) ??
        false;
    // 状态切换时启停脉冲
    if (active && !_dragging) {
      _dragging = true;
      _pulse.repeat();
    } else if (!active && _dragging) {
      _dragging = false;
      _pulse.stop();
      _pulse.value = 0;
    }

    final c = widget.color;
    final radius = BorderRadius.circular(widget.isExposed ? 5.5 : 2);
    return AnimatedScale(
      scale: active ? 1.5 : (hovered ? 1.28 : 1.0),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutBack,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          // 连线拖拽中:向外扩散并淡出的脉冲光环
          if (active)
            Transform.scale(
              scale: 1.0 + _pulse.value * 1.1,
              child: Opacity(
                opacity: (1 - _pulse.value) * 0.6,
                child: Container(
                  width: 11,
                  height: widget.hh,
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    border: Border.all(
                      color: c,
                      width: math.max(1.0, 1.5 / widget.zoom),
                    ),
                  ),
                ),
              ),
            ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            width: 11,
            height: widget.hh,
            decoration: BoxDecoration(
              color: c,
              borderRadius: radius,
              border: Border.all(
                color: widget.t.bgSurface,
                width: 1.5 / widget.zoom,
              ),
              boxShadow: (hovered || active)
                  ? [
                      BoxShadow(
                        color: c.withValues(alpha: active ? 0.8 : 0.45),
                        blurRadius: active ? 12 : 8,
                        spreadRadius: active ? 2 : 1,
                      ),
                    ]
                  : const <BoxShadow>[],
            ),
          ),
        ],
      ),
    );
  }
}
