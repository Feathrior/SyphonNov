library;

import 'dart:math' as math;

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

const double radialDeadRadius = 28;
const double radialCategoryRadius = 84;
const double radialDetailRadius = 96;
const double radialCommitRadius = 154;

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
  if (delta.distance < radialDetailRadius || itemCount == 0) return null;
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

class RadialNodeMenu extends StatelessWidget {
  final Offset center;
  final Offset pointer;
  final int? sectionIndex;
  final int? detailIndex;
  final List<RadialNodeItem> detailItems;
  final bool armed;

  const RadialNodeMenu({
    super.key,
    required this.center,
    required this.pointer,
    required this.sectionIndex,
    required this.detailIndex,
    required this.detailItems,
    required this.armed,
  });

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    return IgnorePointer(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: MotionTokens.standard(context),
        curve: MotionTokens.emphasized,
        builder: (context, value, child) => Opacity(
          opacity: value,
          child: Transform.scale(
            scale: .82 + .18 * value,
            origin: center,
            child: child,
          ),
        ),
        child: RepaintBoundary(
          child: CustomPaint(
            key: const Key('radial-node-menu'),
            painter: _RadialNodeMenuPainter(
              center: center,
              pointer: pointer,
              sectionIndex: sectionIndex,
              detailIndex: detailIndex,
              detailItems: detailItems,
              armed: armed,
              theme: t,
            ),
          ),
        ),
      ),
    );
  }
}

class _RadialNodeMenuPainter extends CustomPainter {
  final Offset center;
  final Offset pointer;
  final int? sectionIndex;
  final int? detailIndex;
  final List<RadialNodeItem> detailItems;
  final bool armed;
  final SyphonTheme theme;

  const _RadialNodeMenuPainter({
    required this.center,
    required this.pointer,
    required this.sectionIndex,
    required this.detailIndex,
    required this.detailItems,
    required this.armed,
    required this.theme,
  });

  Color _sectionColor(int index) {
    if (index == 5) return const Color(0xFF8A9099);
    final category = categoryForRadialSection(radialNodeSections[index])!;
    return parseColor(kCategoryInfo[category]!.color);
  }

  String _sectionLabel(int index) {
    if (index == 5) return 'Package';
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
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 86);
    painter.paint(canvas, at - Offset(painter.width / 2, painter.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    const sectionSweep = math.pi * 2 / 6;
    const gap = .025;
    canvas.drawCircle(
      center,
      88,
      Paint()
        ..color = Colors.black.withValues(alpha: theme.isDark ? .2 : .08)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16),
    );
    for (var index = 0; index < 6; index++) {
      final selected = sectionIndex == index;
      final color = _sectionColor(index);
      final start = -math.pi / 2 - sectionSweep / 2 + index * sectionSweep;
      final path = _sector(
        radialDeadRadius + 2,
        radialCategoryRadius,
        start + gap,
        sectionSweep - gap * 2,
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = selected
              ? color.withValues(alpha: .9)
              : theme.bgFloat.withValues(alpha: .97),
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = selected ? color : theme.strokeStrong.withValues(alpha: .75)
          ..style = PaintingStyle.stroke
          ..strokeWidth = selected ? 1.8 : 1,
      );
      final angle = -math.pi / 2 + index * sectionSweep;
      _drawCentered(
        canvas,
        _sectionLabel(index),
        center + Offset(math.cos(angle), math.sin(angle)) * 57,
        TextStyle(
          color: selected ? Colors.white : theme.textDim,
          fontSize: 9,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        ),
      );
    }
    canvas.drawCircle(
      center,
      radialDeadRadius - 3,
      Paint()..color = theme.bgSurface,
    );
    _drawCentered(
      canvas,
      '滑动',
      center,
      TextStyle(color: theme.textFaint, fontSize: 8),
    );

    final selectedSection = sectionIndex;
    if (selectedSection != null && detailItems.isNotEmpty) {
      final color = _sectionColor(selectedSection);
      final sectionStart =
          -math.pi / 2 - sectionSweep / 2 + selectedSection * sectionSweep;
      final itemSweep = sectionSweep / detailItems.length;
      for (var index = 0; index < detailItems.length; index++) {
        final selected = detailIndex == index;
        final path = _sector(
          radialDetailRadius,
          radialCommitRadius - 8,
          sectionStart + index * itemSweep + .008,
          itemSweep - .016,
        );
        canvas.drawPath(
          path,
          Paint()
            ..color = selected
                ? color.withValues(alpha: .82)
                : theme.bgSurface.withValues(alpha: .82),
        );
        canvas.drawPath(
          path,
          Paint()
            ..color = selected ? color : theme.stroke
            ..style = PaintingStyle.stroke
            ..strokeWidth = selected ? 1.4 : .8,
        );
      }
      final selectedDetail = detailIndex;
      if (selectedDetail != null && selectedDetail < detailItems.length) {
        final item = detailItems[selectedDetail];
        final labelPainter = TextPainter(
          text: TextSpan(
            text: item.label,
            style: TextStyle(
              color: theme.text,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '…',
        )..layout(maxWidth: 150);
        final labelRect = RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: center + const Offset(0, 112),
            width: labelPainter.width + 22,
            height: 28,
          ),
          const Radius.circular(9),
        );
        canvas.drawRRect(labelRect, Paint()..color = theme.bgFloat);
        canvas.drawRRect(
          labelRect,
          Paint()
            ..color = color.withValues(alpha: .65)
            ..style = PaintingStyle.stroke,
        );
        labelPainter.paint(
          canvas,
          Offset(
            labelRect.center.dx - labelPainter.width / 2,
            labelRect.center.dy - labelPainter.height / 2,
          ),
        );
      }
    }

    if (armed) {
      final color = sectionIndex == null
          ? theme.accent
          : _sectionColor(sectionIndex!);
      canvas.drawCircle(
        pointer,
        25,
        Paint()..color = color.withValues(alpha: .12),
      );
      canvas.drawCircle(
        pointer,
        12,
        Paint()
          ..color = theme.bgSurface
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        pointer,
        12,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RadialNodeMenuPainter oldDelegate) =>
      oldDelegate.pointer != pointer ||
      oldDelegate.sectionIndex != sectionIndex ||
      oldDelegate.detailIndex != detailIndex ||
      oldDelegate.armed != armed ||
      oldDelegate.detailItems != detailItems ||
      oldDelegate.theme != theme;
}
