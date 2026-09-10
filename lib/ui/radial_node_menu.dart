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

const double radialInnerRadius = 48;
const double radialOuterRadius = 66;
const double radialDetachRadius = 88;
const double radialDeadRadius = radialInnerRadius - 10;

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

class RadialNodeMenu extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    final radius = math.max(124.0, (pointer - center).distance + 36);
    final bounds = Rect.fromCircle(center: center, radius: radius);
    final localCenter = center - bounds.topLeft;
    final localPointer = pointer - bounds.topLeft;
    final localAnchor = detachAnchor == null
        ? null
        : detachAnchor! - bounds.topLeft;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fromRect(
          rect: bounds,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: MotionTokens.spatial(context),
            curve: MotionTokens.emphasized,
            builder: (context, opening, child) => ImageFiltered(
              imageFilter: ui.ImageFilter.blur(
                sigmaX: 7 * (1 - opening),
                sigmaY: 7 * (1 - opening),
              ),
              child: Opacity(
                opacity: opening,
                child: Transform.scale(
                  scale: .78 + .22 * opening,
                  alignment: Alignment.topLeft,
                  origin: localCenter,
                  child: child,
                ),
              ),
            ),
            child: TweenAnimationBuilder<double>(
              key: ValueKey(lockedItem?.id ?? 'radial-attached'),
              tween: Tween(begin: 0, end: lockedItem == null ? 0 : 1),
              duration: MotionTokens.spatial(context),
              curve: Curves.easeOutBack,
              builder: (context, detachProgress, _) => RepaintBoundary(
                child: CustomPaint(
                  key: const Key('radial-node-menu'),
                  painter: _RadialNodeMenuPainter(
                    center: localCenter,
                    pointer: localPointer,
                    sectionIndex: sectionIndex,
                    detailIndex: detailIndex,
                    detailItems: detailItems,
                    lockedItem: lockedItem,
                    detachAnchor: localAnchor,
                    detachProgress: detachProgress,
                    theme: t,
                  ),
                ),
              ),
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
    required this.theme,
  });

  Color _sectionColor(int index) {
    if (index == 5) return const Color(0xFF8A9099);
    final category = categoryForRadialSection(radialNodeSections[index])!;
    return parseColor(kCategoryInfo[category]!.color);
  }

  String _sectionLabel(int index) {
    if (index == 5) return 'PKG';
    final category = categoryForRadialSection(radialNodeSections[index])!;
    return L.t(kCategoryInfo[category]!.label);
  }

  Path _sector(double inner, double outer, double start, double sweep) {
    final outerRect = Rect.fromCircle(center: center, radius: outer);
    final innerRect = Rect.fromCircle(center: center, radius: inner);
    return Path()
      ..arcTo(outerRect, start, sweep, false)
      ..arcTo(innerRect, start + sweep, -sweep, false)
      ..close();
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
    canvas.drawCircle(
      center,
      radialOuterRadius + 5,
      Paint()
        ..color = Colors.black.withValues(alpha: theme.isDark ? .28 : .14)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
    );
    canvas.drawCircle(
      center,
      radialInnerRadius - 4,
      Paint()..color = theme.bgSurface.withValues(alpha: .88),
    );

    for (var index = 0; index < 6; index++) {
      final selected = sectionIndex == index;
      final color = _sectionColor(index);
      final start = -math.pi / 2 - sweep / 2 + index * sweep + .025;
      final path = _sector(
        selected ? radialInnerRadius - 3 : radialInnerRadius,
        selected ? radialOuterRadius + 6 : radialOuterRadius,
        start,
        sweep - .05,
      );
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
        _sectionLabel(index),
        center + Offset(math.cos(angle), math.sin(angle)) * 56.5,
        TextStyle(
          color: Colors.white.withValues(alpha: selected ? 1 : .82),
          fontSize: 7.5,
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
    _drawCentered(
      canvas,
      lockedItem?.label ?? selectedItem?.label ?? '滑向色环',
      center,
      TextStyle(
        color: theme.text,
        fontSize: lockedItem == null ? 8.5 : 9,
        fontWeight: lockedItem == null ? FontWeight.w500 : FontWeight.w700,
      ),
    );

    final delta = pointer - center;
    if (delta.distance < radialDeadRadius || sectionIndex == null) return;
    final color = _sectionColor(sectionIndex!);
    final unit = delta / delta.distance;
    final anchor =
        detachAnchor ??
        center + unit * ((radialInnerRadius + radialOuterRadius) / 2);
    Offset dot;
    if (lockedItem == null) {
      final pull = math.max(0.0, delta.distance - radialInnerRadius);
      final resisted =
          ((radialInnerRadius + radialOuterRadius) / 2) + pull * .22;
      dot = center + unit * math.min(resisted, radialDetachRadius - 4);
    } else {
      dot = Offset.lerp(anchor, pointer, detachProgress.clamp(0, 1))!;
      final tether = Path()
        ..moveTo(anchor.dx, anchor.dy)
        ..quadraticBezierTo(
          (anchor.dx + dot.dx) / 2 - unit.dy * 5 * (1 - detachProgress),
          (anchor.dy + dot.dy) / 2 + unit.dx * 5 * (1 - detachProgress),
          dot.dx,
          dot.dy,
        );
      canvas.drawPath(
        tether,
        Paint()
          ..color = color.withValues(alpha: .5 * (1 - detachProgress))
          ..strokeWidth = 5 * (1 - detachProgress) + 1
          ..strokeCap = StrokeCap.round
          ..style = PaintingStyle.stroke
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
      );
    }
    final pulse = lockedItem == null ? 0.0 : math.sin(detachProgress * math.pi);
    canvas.drawCircle(
      dot,
      13 + pulse * 4,
      Paint()
        ..color = color.withValues(alpha: .35)
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
      oldDelegate.theme != theme;
}
