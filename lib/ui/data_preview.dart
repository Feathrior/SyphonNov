// 迷你表格:检查器"数据预览"与"数据输出"节点共用同一套实现
// (原 inspector.dart 的 _MiniTable/_Cell 提取;列宽 IntrinsicColumnWidth
//  按内容自适应,不会撑满整个预览窗)
// 竖向滚动条:自绘 + Listener 直接驱动(绕开手势竞技场)——画布层背景 pan 手势
// 会抢占 Material Scrollbar 的拇指拖拽,导致滚动条拖不动;自绘滚动条用 Listener
// (不受竞技场影响)接管指针,与滚轮接管同一思路,稳定可拖动。
library;

import 'package:flutter/gestures.dart' show GestureBinding, PointerScrollEvent;
import 'package:flutter/material.dart';

import 'theme.dart';

/// 迷你表格:内容宽度自适应、纵向/横向双层滚动,竖向滚动条自绘常显可拖动。
/// 表格左侧自动带序号列(角格留空)。
///
/// [maxHeight]:有限值时限制表格可视高度(超出部分滚动);
/// `double.infinity` 时不做显式限制,由父级约束(如 Expanded)决定可视高度。
class MiniTable extends StatefulWidget {
  final List<String> headers;
  final List<List<String>> rows;
  final String? footer;
  final double maxHeight;

  const MiniTable({
    super.key,
    required this.headers,
    required this.rows,
    this.footer,
    this.maxHeight = 96,
  });

  @override
  State<MiniTable> createState() => _MiniTableState();
}

class _MiniTableState extends State<MiniTable> {
  // 外层纵向滚动控制器:滚轮与滚动条共用,保证同滚同止
  final ScrollController _v = ScrollController();

  @override
  void dispose() {
    _v.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    final table = Listener(
      behavior: HitTestBehavior.translucent,
      onPointerSignal: (e) {
        // 纵向滚轮接管:命中链最深处优先注册 PointerSignalResolver,
        // 直接驱动外层纵向滚动——修复内嵌横向滚动体布局下外层 Scrollable
        // 收不到纵向滚轮事件的问题(如数据输出节点 Expanded 内嵌表格)。
        // 方向与 SDK 原生 _handlePointerScroll 完全一致(delta 直接累加)。
        if (e is! PointerScrollEvent || e.scrollDelta.dy == 0) return;
        if (!_v.hasClients) return;
        GestureBinding.instance.pointerSignalResolver.register(e, (event) {
          final se = event as PointerScrollEvent;
          _v.position.pointerScroll(se.scrollDelta.dy);
          se.respond(allowPlatformDefault: false);
        });
      },
      child: Table(
        border: TableBorder.all(color: t.stroke, width: 1),
        columnWidths: {0: const FixedColumnWidth(30)},
        defaultColumnWidth: const IntrinsicColumnWidth(),
        children: [
          TableRow(
            decoration: BoxDecoration(color: t.bgFloat),
            children: [
              MiniTableCell('', header: true),
              for (final h in widget.headers) MiniTableCell(h, header: true),
            ],
          ),
          for (final r in widget.rows)
            TableRow(
              children: [
                MiniTableCell('${widget.rows.indexOf(r)}'),
                for (var i = 0; i < r.length; i++) MiniTableCell(r[i]),
              ],
            ),
        ],
      ),
    );
    // 外:纵向滚动(带控制器);内:横向滚动。
    // ScrollConfiguration(scrollbars:false) 关闭 Fluent 自动包裹的滚动条,
    // 避免双滚动条;竖向滚动条由下方自绘的 _MiniVScrollbar 接管。
    final scroll = ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: SingleChildScrollView(
        controller: _v,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: table,
        ),
      ),
    );
    // 叠加自绘竖向滚动条:用 LayoutBuilder 拿到可视高度(紧约束下必有限)
    final body = LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            scroll,
            _MiniVScrollbar(
              controller: _v,
              viewportHeight: constraints.maxHeight,
            ),
          ],
        );
      },
    );
    final sized = widget.maxHeight.isFinite
        ? ConstrainedBox(
            constraints: BoxConstraints(maxHeight: widget.maxHeight),
            child: body,
          )
        : Expanded(child: body);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        sized,
        if (widget.footer != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text(
              widget.footer!,
              style: TextStyle(fontSize: 10, color: t.textFaint),
            ),
          ),
      ],
    );
  }
}

/// 自绘竖向滚动条:轨道 + 拇指,Listenter 直接驱动滚动(绕开手势竞技场)。
/// 画布层背景 pan 手势(arena)会抢占 Material 滚动条拇指拖拽,故这里不走
/// 手势竞技场,改为 Listener 手动接管按下/移动/松开。
class _MiniVScrollbar extends StatefulWidget {
  final ScrollController controller;
  final double viewportHeight;

  const _MiniVScrollbar({
    required this.controller,
    required this.viewportHeight,
  });

  @override
  State<_MiniVScrollbar> createState() => _MiniVScrollbarState();
}

class _MiniVScrollbarState extends State<_MiniVScrollbar> {
  static const double _width = 10;
  static const double _trackInset = 2;
  static const double _minThumb = 24;

  double _dragStartPixel = 0;
  double _dragStartY = 0;
  bool _dragging = false;

  double get _trackTop => _trackInset;
  double get _trackBottom => widget.viewportHeight - _trackInset;
  double get _trackH => (_trackBottom - _trackTop).clamp(0, double.infinity);

  // 拇指高度:与内容/视口比例相关,并保证最小可点击高度
  double _thumbH(ScrollPosition p) {
    final contentH = p.viewportDimension + p.maxScrollExtent;
    if (contentH <= 0) return 0;
    final h = _trackH * (p.viewportDimension / contentH);
    return h.clamp(_minThumb, _trackH);
  }

  // 拇指顶部位置(随滚动偏移在轨道内滑动)
  double _thumbTop(ScrollPosition p) {
    if (p.maxScrollExtent <= 0) return _trackTop;
    return _trackTop + (p.pixels / p.maxScrollExtent) * (_trackH - _thumbH(p));
  }

  void _onDown(PointerDownEvent e) {
    final p = widget.controller.position;
    if (!p.haveDimensions || p.maxScrollExtent <= 0) return;
    final y = e.localPosition.dy;
    final top = _thumbTop(p);
    final h = _thumbH(p);
    if (y >= top && y <= top + h) {
      // 落在拇指上:记录拖动基准
      _dragging = true;
      _dragStartPixel = p.pixels;
      _dragStartY = y;
    } else {
      // 落在轨道上:跳到该位置(拇指中心对准点击点)
      final max = p.maxScrollExtent;
      final ratio = ((y - _trackTop) - h / 2) / (_trackH - h);
      p.jumpTo((ratio * max).clamp(0.0, max));
    }
  }

  void _onMove(PointerMoveEvent e) {
    if (!_dragging) return;
    final p = widget.controller.position;
    if (!p.haveDimensions) return;
    final max = p.maxScrollExtent;
    final scale = max / (_trackH - _thumbH(p));
    final dy = e.localPosition.dy - _dragStartY;
    p.jumpTo((_dragStartPixel + dy * scale).clamp(0.0, max));
  }

  void _onUp() {
    _dragging = false;
  }

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    return Positioned(
      right: 0,
      top: 0,
      bottom: 0,
      width: _width,
      child: Listener(
        key: const ValueKey('mini_v_scrollbar'),
        behavior: HitTestBehavior.opaque,
        onPointerDown: _onDown,
        onPointerMove: _onMove,
        onPointerUp: (_) => _onUp(),
        onPointerCancel: (_) => _onUp(),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: ListenableBuilder(
            listenable: widget.controller,
            builder: (context, _) {
              // 始终渲染条带(保持可命中);无可滚动内容时只画空轨道
              final has = widget.controller.hasClients;
              final p = has ? widget.controller.position : null;
              final scrollable =
                  p != null && p.haveDimensions && p.maxScrollExtent > 0;
              final thumbTop = scrollable ? _thumbTop(p) : _trackTop;
              final thumbH = scrollable ? _thumbH(p) : 0.0;
              return CustomPaint(
                size: Size(_width, widget.viewportHeight),
                painter: _VScrollbarPainter(
                  thumbTop: thumbTop,
                  thumbH: thumbH,
                  trackTop: _trackTop,
                  trackBottom: _trackBottom,
                  width: _width,
                  thumbColor: _dragging ? t.accent : t.textFaint,
                  trackColor: t.stroke.withValues(alpha: 0.35),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _VScrollbarPainter extends CustomPainter {
  final double thumbTop;
  final double thumbH;
  final double trackTop;
  final double trackBottom;
  final double width;
  final Color thumbColor;
  final Color trackColor;

  const _VScrollbarPainter({
    required this.thumbTop,
    required this.thumbH,
    required this.trackTop,
    required this.trackBottom,
    required this.width,
    required this.thumbColor,
    required this.trackColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width / 2;
    // 轨道
    final trackRect = RRect.fromRectAndRadius(
      Rect.fromLTRB(x - 1, trackTop, x + 1, trackBottom),
      const Radius.circular(1),
    );
    canvas.drawRRect(trackRect, Paint()..color = trackColor);
    // 拇指
    if (thumbH <= 0) return;
    final thumbRect = RRect.fromRectAndRadius(
      Rect.fromLTRB(1, thumbTop, size.width - 1, thumbTop + thumbH),
      Radius.circular(size.width / 2),
    );
    canvas.drawRRect(thumbRect, Paint()..color = thumbColor);
  }

  @override
  bool shouldRepaint(covariant _VScrollbarPainter old) =>
      old.thumbTop != thumbTop ||
      old.thumbH != thumbH ||
      old.trackTop != trackTop ||
      old.trackBottom != trackBottom ||
      old.width != width ||
      old.thumbColor != thumbColor ||
      old.trackColor != trackColor;
}

class MiniTableCell extends StatelessWidget {
  final String text;
  final bool header;

  const MiniTableCell(this.text, {this.header = false, super.key});

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Text(
        text,
        softWrap: false,
        overflow: TextOverflow.visible,
        style: TextStyle(
          fontSize: 11,
          color: header ? t.textDim : t.text,
          fontWeight: header ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
    );
  }
}
