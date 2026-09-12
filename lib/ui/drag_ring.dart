// 拖拽指示环(上方栏拖出节点/Package、右键圆环分离后共用)
//
// 起始形状是一条分类胶囊那样的横条,随后很快(与节点入场同节奏)"长"成空心
// 圆环:环体是几乎纯白的亮色(只留一点底色),外面套一层同色发光阴影,
// 不再额外描一圈细线 —— 任何"最外圈的细线/亮边"都会显得很脏。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'motion.dart';

/// 指示环的反馈框尺寸(环本身 19px,其余留白给"从条形长出来"的形变)
const double kDragRingExtent = 52;

class DragRing extends StatefulWidget {
  final Color color;

  const DragRing({super.key, required this.color});

  @override
  State<DragRing> createState() => _DragRingState();
}

class _DragRingState extends State<DragRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 与节点入场同节奏:条形变圆环要利落,不能拖成"慢动作"
    _controller.duration = MotionTokens.nodeEntry(context);
    if (!_started) {
      _started = true;
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, _) {
      final amplitude = MotionTokens.amplitude(context);
      final frame = popMotionFrame(
        _controller.value,
        beginScale: 1 - .82 * amplitude,
        maxBlur: 16 * amplitude,
      );
      final turn =
          -.2 *
          amplitude *
          (1 - Curves.easeOutCubic.transform(_controller.value));
      final content = Opacity(
        opacity: amplitude == 0 ? 1 : frame.opacity,
        child: Transform.rotate(
          angle: turn,
          child: Transform.scale(
            scale: amplitude == 0 ? 1 : frame.scale,
            child: IgnorePointer(
              child: CustomPaint(
                key: const Key('node-drag-dot'),
                size: const Size(kDragRingExtent, kDragRingExtent),
                painter: DragRingPainter(
                  color: widget.color,
                  progress: amplitude == 0 ? 1 : _controller.value,
                ),
              ),
            ),
          ),
        ),
      );
      if (frame.blur <= .05) return content;
      return ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: frame.blur,
          sigmaY: frame.blur,
        ),
        child: content,
      );
    },
  );
}

/// 指示环的画笔:条形 → 圆环的形变 + 亮色粗环 + 同色发光
class DragRingPainter extends CustomPainter {
  /// 与右键圆环拖出的圆点同尺寸(radial_node_menu 中半径为 9.5)
  static const double ringDiameter = 19;
  static const double _ringStroke = 3.8;
  static const double _barWidth = 44;
  static const double _barHeight = 13;

  final Color color;
  final double progress;

  /// 整体不透明度(右键圆环分离后渐变成指示环时用来淡入)
  final double appear;

  const DragRingPainter({
    required this.color,
    required this.progress,
    this.appear = 1,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final clamped = progress.clamp(0.0, 1.0);
    // 轻微过冲:条形先缩到略小于圆环,再回弹到圆环尺寸
    final morph = Curves.easeOutBack.transform(clamped);
    final width = _barWidth + (ringDiameter - _barWidth) * morph;
    final height = _barHeight + (ringDiameter - _barHeight) * morph;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: size.center(Offset.zero),
        width: width,
        height: height,
      ),
      Radius.circular(height / 2),
    );
    final alpha = appear.clamp(0.0, 1.0);
    final fade = Curves.easeOut.transform(clamped) * alpha;
    if (fade <= 0) return;
    // 环体接近纯白,只留一点底色 —— 在任何背景上都"跳"出来
    final bright = Color.lerp(color, Colors.white, .86)!;
    // 1) 底色的发光阴影(柔和的模糊,不产生硬边)
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _ringStroke * 3
        ..color = color.withValues(alpha: .62 * fade)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );
    // 2) 环体本身:粗一点、亮一点;不再额外描一圈细线
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _ringStroke
        ..color = bright.withValues(alpha: .96 * fade),
    );
  }

  @override
  bool shouldRepaint(covariant DragRingPainter old) =>
      old.color != color || old.progress != progress || old.appear != appear;
}
