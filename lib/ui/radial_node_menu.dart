library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../i18n.dart';
import '../models/color_utils.dart';
import '../models/data.dart';
import '../models/registry.dart';
import 'motion.dart';
import 'theme.dart';

enum RadialNodeSection { input, clean, compute, transform, visualize, package }

const radialNodeSections = <RadialNodeSection>[
  RadialNodeSection.input,
  RadialNodeSection.clean,
  RadialNodeSection.compute,
  RadialNodeSection.transform,
  RadialNodeSection.visualize,
  RadialNodeSection.package,
];

typedef RadialNodeItem = ({String id, String label, bool isPackage});

const double radialInnerRadius = 61;
const double radialOuterRadius = 82;
const double radialDetachRadius = 112;
const double radialDeadRadius = radialInnerRadius - 10;

/// 撤回(取消本次放置)的判定半径:从色环分离出的圆点被拖回到**圆环外圈以内**
/// 即撤销锁定,松开右键不再创建节点(此前只有回到圆环内圈才会撤回)。
const double radialCancelRadius = radialOuterRadius;

Category? categoryForRadialSection(RadialNodeSection section) =>
    switch (section) {
      RadialNodeSection.input => Category.input,
      RadialNodeSection.clean => Category.clean,
      RadialNodeSection.compute => Category.compute,
      RadialNodeSection.transform => Category.transform,
      RadialNodeSection.visualize => Category.visualize,
      RadialNodeSection.package => null,
    };

List<RadialNodeItem> radialItemsFor(
  RadialNodeSection section,
  List<Map<String, dynamic>> packages,
) {
  final category = categoryForRadialSection(section);
  if (category != null) {
    return [
      for (final config in kNodeConfigs)
        if (config.category == category)
          (id: config.id, label: L.t(config.label), isPackage: false),
    ];
  }
  return [
    for (final package in packages)
      (
        id: '${package['id'] ?? ''}',
        label: '${package['name'] ?? 'Package'}',
        isPackage: true,
      ),
  ];
}

int? radialSectionIndex(Offset delta) {
  if (delta.distance < radialDeadRadius) return null;
  const sweep = math.pi * 2 / 6;
  final angle = math.atan2(delta.dy, delta.dx);
  final normalized = (angle + math.pi / 2 + sweep / 2) % (math.pi * 2);
  return (normalized / sweep).floor().clamp(0, 5);
}

int? radialDetailIndex(Offset delta, int sectionIndex, int itemCount) {
  if (delta.distance < radialDeadRadius || itemCount == 0) return null;
  const sweep = math.pi * 2 / 6;
  final center = -math.pi / 2 + sectionIndex * sweep;
  var relative = math.atan2(delta.dy, delta.dx) - center;
  while (relative <= -math.pi) {
    relative += math.pi * 2;
  }
  while (relative > math.pi) {
    relative -= math.pi * 2;
  }
  final normalized = ((relative + sweep / 2) / sweep).clamp(0.0, .999999);
  return (normalized * itemCount).floor().clamp(0, itemCount - 1);
}

Offset radialAttachmentPoint(Offset center, Offset pointer) {
  final delta = pointer - center;
  if (delta.distance == 0) return center;
  return center +
      delta / delta.distance * ((radialInnerRadius + radialOuterRadius) / 2);
}

@immutable
class RadialEntranceFrame {
  final double scale;
  final double rotation;
  final double blur;
  final double opacity;

  const RadialEntranceFrame({
    required this.scale,
    required this.rotation,
    required this.blur,
    required this.opacity,
  });
}

/// 色环的完整入场轨迹。全幅模式从上一版 1.5% 的一半尺寸开始，旋转角、
/// 越界量和模糊幅度提高 50%；旋转仍在总时长的前 2/3 完成，因此平均角
/// 速度同步提高 50%。[amplitude] 对应完整、简化、关闭三档动效幅度。
RadialEntranceFrame radialEntranceFrame(
  double progress, {
  double amplitude = 1,
}) {
  final t = progress.clamp(0.0, 1.0);
  final strength = amplitude.clamp(0.0, 1.0);
  final double fullScale;
  if (t <= .62) {
    final growth = Curves.easeInOutCubic.transform(t / .62);
    fullScale = .0075 + 1.0975 * growth;
  } else {
    final settle = Curves.easeInOutCubic.transform((t - .62) / .38);
    fullScale = 1.105 - .105 * settle;
  }
  final rotationTime = (t * 1.5).clamp(0.0, 1.0);
  final turn = Curves.easeOutCubic.transform(rotationTime);
  final fullRotation =
      -math.pi * 1.17 * (1 - turn) +
      .165 * math.sin(rotationTime * math.pi * 2) * (1 - rotationTime);
  final clarity = Curves.easeOutCubic.transform(t);
  final fullOpacity =
      .32 + .68 * Curves.easeOut.transform((t / .34).clamp(0.0, 1.0));
  return RadialEntranceFrame(
    scale: 1 + (fullScale - 1) * strength,
    rotation: fullRotation * strength,
    blur: 45 * math.pow(1 - clarity, 1.35) * strength,
    opacity: 1 - (1 - fullOpacity) * strength,
  );
}

/// iOS 式橡皮筋距离：起初跟手，拉得越远阻力增长越明显，并渐近到上限。
double radialRubberBand(double pull) {
  if (pull <= 0) return 0;
  const limit =
      radialDetachRadius - ((radialInnerRadius + radialOuterRadius) / 2) - 4;
  return limit * (1 - 1 / (1 + .55 * pull / limit));
}

class RadialNodeMenu extends StatefulWidget {
  final Offset center;
  final Offset pointer;
  final int? sectionIndex;
  final int? detailIndex;
  final List<RadialNodeItem> detailItems;
  final RadialNodeItem? lockedItem;
  final Offset? detachAnchor;

  const RadialNodeMenu({
    super.key,
    required this.center,
    required this.pointer,
    required this.sectionIndex,
    required this.detailIndex,
    required this.detailItems,
    required this.lockedItem,
    required this.detachAnchor,
  });

  @override
  State<RadialNodeMenu> createState() => _RadialNodeMenuState();
}

class _RadialNodeMenuState extends State<RadialNodeMenu>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(vsync: this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _entrance.duration = Duration(
      milliseconds: (MotionTokens.radialBounce(context).inMilliseconds * 1.45)
          .round(),
    );
    if (!_started) {
      _started = true;
      _entrance.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    final radius = math.max(
      154.0,
      (widget.pointer - widget.center).distance + 42,
    );
    final bounds = Rect.fromCircle(center: widget.center, radius: radius);
    final localCenter = widget.center - bounds.topLeft;
    final localPointer = widget.pointer - bounds.topLeft;
    final localAnchor = widget.detachAnchor == null
        ? null
        : widget.detachAnchor! - bounds.topLeft;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fromRect(
          rect: bounds,
          child: AnimatedBuilder(
            animation: _entrance,
            builder: (context, child) {
              final frame = radialEntranceFrame(
                _entrance.value,
                amplitude: MotionTokens.amplitude(context),
              );
              return ImageFiltered(
                key: const Key('radial-entrance-blur'),
                imageFilter: ui.ImageFilter.blur(
                  sigmaX: frame.blur,
                  sigmaY: frame.blur,
                ),
                child: Opacity(
                  opacity: frame.opacity,
                  child: Transform.rotate(
                    key: const Key('radial-entrance-rotation'),
                    angle: frame.rotation,
                    alignment: Alignment.center,
                    child: Transform.scale(
                      key: const Key('radial-entrance-scale'),
                      scale: frame.scale,
                      alignment: Alignment.center,
                      child: child,
                    ),
                  ),
                ),
              );
            },
            child: TweenAnimationBuilder<double>(
              // key 固定:撤回时同一个 builder 反向动画,扇区辉光平滑收回,
              // 而不是换 key 重建后瞬间归零(那样看起来像"刷新"一下)
              key: const ValueKey('radial-hover-progress'),
              tween: Tween(begin: 0, end: widget.sectionIndex == null ? 0 : 1),
              duration: MotionTokens.standard(context),
              curve: MotionTokens.emphasized,
              builder: (context, hoverProgress, child) =>
                  TweenAnimationBuilder<double>(
                    // 同理:key 不能带项 id,否则锁定/撤回切换 key 时会重建,
                    // detachProgress 直接归零 → 圆球与连接带闪断
                    key: const ValueKey('radial-detach-progress'),
                    tween: Tween(
                      begin: 0,
                      end: widget.lockedItem == null ? 0 : 1,
                    ),
                    duration: MotionTokens.radialBounce(context),
                    curve: Curves.easeOutBack,
                    builder: (context, detachProgress, _) => RepaintBoundary(
                      child: CustomPaint(
                        key: const Key('radial-node-menu'),
                        painter: _RadialNodeMenuPainter(
                          center: localCenter,
                          pointer: localPointer,
                          sectionIndex: widget.sectionIndex,
                          detailIndex: widget.detailIndex,
                          detailItems: widget.detailItems,
                          lockedItem: widget.lockedItem,
                          detachAnchor: localAnchor,
                          detachProgress: detachProgress,
                          hoverProgress: hoverProgress,
                          theme: t,
                        ),
                      ),
                    ),
                  ),
              child: const SizedBox.shrink(),
            ),
          ),
        ),
      ],
    );
  }
}

class _RadialNodeMenuPainter extends CustomPainter {
  final Offset center;
  final Offset pointer;
  final int? sectionIndex;
  final int? detailIndex;
  final List<RadialNodeItem> detailItems;
  final RadialNodeItem? lockedItem;
  final Offset? detachAnchor;
  final double detachProgress;
  final double hoverProgress;
  final SyphonTheme theme;

  const _RadialNodeMenuPainter({
    required this.center,
    required this.pointer,
    required this.sectionIndex,
    required this.detailIndex,
    required this.detailItems,
    required this.lockedItem,
    required this.detachAnchor,
    required this.detachProgress,
    required this.hoverProgress,
    required this.theme,
  });

  Color _sectionColor(int index) {
    if (index == 5) return const Color(0xFF8A9099);
    final category = categoryForRadialSection(radialNodeSections[index])!;
    return parseColor(kCategoryInfo[category]!.color);
  }

  static const _sectionSymbols = ['↓', '◇', 'Σ', '⇄', '◉', '⧉'];

  Path _sector(double inner, double outer, double start, double sweep) {
    final outerRect = Rect.fromCircle(center: center, radius: outer);
    final innerRect = Rect.fromCircle(center: center, radius: inner);
    return Path()
      ..arcTo(outerRect, start, sweep, false)
      ..arcTo(innerRect, start + sweep, -sweep, false)
      ..close();
  }

  Path _hoverSector(double start, double sectorSweep, double pointerAngle) {
    const samples = 28;
    double radiusAt(double angle, {required bool outer}) {
      var distance = (angle - pointerAngle).abs();
      if (distance > math.pi) distance = math.pi * 2 - distance;
      final normalized = (distance / (sectorSweep * .48)).clamp(0.0, 1.0);
      final gaussian = math.exp(-5.2 * normalized * normalized);
      final impulse = hoverProgress * gaussian;
      return outer
          ? radialOuterRadius + 18 * impulse
          : radialInnerRadius - 4.5 * impulse;
    }

    final path = Path();
    for (var index = 0; index <= samples; index++) {
      final angle = start + sectorSweep * index / samples;
      final point =
          center +
          Offset(math.cos(angle), math.sin(angle)) *
              radiusAt(angle, outer: true);
      if (index == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    for (var index = samples; index >= 0; index--) {
      final angle = start + sectorSweep * index / samples;
      final point =
          center +
          Offset(math.cos(angle), math.sin(angle)) *
              radiusAt(angle, outer: false);
      path.lineTo(point.dx, point.dy);
    }
    return path..close();
  }

  void _drawCentered(Canvas canvas, String text, Offset at, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 112);
    painter.paint(canvas, at - Offset(painter.width / 2, painter.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    const sweep = math.pi * 2 / 6;
    for (var index = 0; index < 6; index++) {
      final selected = sectionIndex == index;
      final color = _sectionColor(index);
      final start = -math.pi / 2 - sweep / 2 + index * sweep + .025;
      final pointerAngle = math.atan2(
        pointer.dy - center.dy,
        pointer.dx - center.dx,
      );
      final path = selected
          ? _hoverSector(start, sweep - .05, pointerAngle)
          : _sector(radialInnerRadius, radialOuterRadius, start, sweep - .05);
      if (selected) {
        canvas.drawPath(
          path,
          Paint()
            ..color = color.withValues(alpha: .48)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
        );
      }
      canvas.drawPath(
        path,
        Paint()..color = color.withValues(alpha: selected ? .96 : .72),
      );
      final angle = -math.pi / 2 + index * sweep;
      _drawCentered(
        canvas,
        _sectionSymbols[index],
        center + Offset(math.cos(angle), math.sin(angle)) * 71.5,
        TextStyle(
          color: Colors.white.withValues(alpha: selected ? 1 : .82),
          fontSize: 12,
          fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
        ),
      );
    }

    if (sectionIndex != null && detailItems.isNotEmpty) {
      final start = -math.pi / 2 - sweep / 2 + sectionIndex! * sweep;
      final itemSweep = sweep / detailItems.length;
      for (var index = 1; index < detailItems.length; index++) {
        final angle = start + index * itemSweep;
        final unit = Offset(math.cos(angle), math.sin(angle));
        canvas.drawLine(
          center + unit * (radialInnerRadius + 2),
          center + unit * (radialOuterRadius - 2),
          Paint()
            ..color = Colors.white.withValues(alpha: .54)
            ..strokeWidth = .75,
        );
      }
    }

    final selectedItem =
        detailIndex == null || detailIndex! >= detailItems.length
        ? null
        : detailItems[detailIndex!];
    final shownItem = lockedItem ?? selectedItem;
    if (shownItem != null && sectionIndex != null) {
      final angle = -math.pi / 2 + sectionIndex! * sweep;
      final labelRadius = radialOuterRadius + 39 + 10 * hoverProgress;
      _drawCentered(
        canvas,
        shownItem.label,
        center + Offset(math.cos(angle), math.sin(angle)) * labelRadius,
        TextStyle(
          color: theme.text,
          fontSize: 13.5,
          fontWeight: FontWeight.w700,
          shadows: [
            Shadow(color: theme.bgCanvas.withValues(alpha: .9), blurRadius: 10),
          ],
        ),
      );
    }

    final delta = pointer - center;
    if (delta.distance < radialDeadRadius || sectionIndex == null) return;
    final color = _sectionColor(sectionIndex!);
    final unit = delta / delta.distance;
    final midRadius = (radialInnerRadius + radialOuterRadius) / 2;
    final anchor = detachAnchor ?? center + unit * midRadius;
    final progress = detachProgress.clamp(0.0, 1.0);
    // 未分离时的"归位点":贴在圆环带内,并随指针带橡皮筋阻力移动
    final pull = math.max(0.0, delta.distance - radialInnerRadius);
    final home = center + unit * (midRadius + radialRubberBand(pull));
    // 分离态位置(与连接带同一条插值),再按 progress 与归位点混合。
    // 撤回时 progress 反向动画,圆球顺着连接带平滑"融回"圆环,
    // 而不是瞬间跳回归位点、连接带同时消失(那种观感就是"刷新")
    final detachedDot = Offset.lerp(anchor, pointer, progress)!;
    final dot = Offset.lerp(home, detachedDot, progress)!;
    if (progress > .01) {
      final tether = Path()
        ..moveTo(anchor.dx, anchor.dy)
        ..quadraticBezierTo(
          (anchor.dx + dot.dx) / 2 - unit.dy * 5 * (1 - progress),
          (anchor.dy + dot.dy) / 2 + unit.dx * 5 * (1 - progress),
          dot.dx,
          dot.dy,
        );
      canvas.drawPath(
        tether,
        Paint()
          ..color = color.withValues(alpha: .5 * (1 - progress))
          ..strokeWidth = 5 * (1 - progress) + 1
          ..strokeCap = StrokeCap.round
          ..style = PaintingStyle.stroke
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
      );
    }
    // 光晕脉冲同样只看 progress:分离与收束过程中都有一次呼吸,静止时归零
    final pulse = math.sin(progress * math.pi);
    // 圆球形光晕:叠加(变亮)混合 —— 与色环/节点重叠处只提亮,不出现暗边
    canvas.drawCircle(
      dot,
      13 + pulse * 4,
      Paint()
        ..color = color.withValues(alpha: .35)
        ..blendMode = BlendMode.plus
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 8 + pulse * 5),
    );
    canvas.drawCircle(dot, 9.5, Paint()..color = color);
    canvas.drawCircle(
      dot - const Offset(2.5, 2.5),
      2.2,
      Paint()..color = Colors.white.withValues(alpha: .7),
    );
  }

  @override
  bool shouldRepaint(covariant _RadialNodeMenuPainter oldDelegate) =>
      oldDelegate.center != center ||
      oldDelegate.pointer != pointer ||
      oldDelegate.sectionIndex != sectionIndex ||
      oldDelegate.detailIndex != detailIndex ||
      oldDelegate.detailItems != detailItems ||
      oldDelegate.lockedItem != lockedItem ||
      oldDelegate.detachAnchor != detachAnchor ||
      oldDelegate.detachProgress != detachProgress ||
      oldDelegate.hoverProgress != hoverProgress ||
      oldDelegate.theme != theme;
}
