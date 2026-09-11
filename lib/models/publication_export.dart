library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'data.dart';
import 'color_utils.dart';
import 'scales.dart';

sealed class SceneCommand {
  const SceneCommand();
}

class SceneClipBegin extends SceneCommand {
  final double x, y, width, height;
  const SceneClipBegin(this.x, this.y, this.width, this.height);
}

class SceneClipEnd extends SceneCommand {
  const SceneClipEnd();
}

class SceneLine extends SceneCommand {
  final double x1, y1, x2, y2, width, opacity;
  final String color;
  final bool dashed;
  const SceneLine(
    this.x1,
    this.y1,
    this.x2,
    this.y2,
    this.color, {
    this.width = 1,
    this.opacity = 1,
    this.dashed = false,
  });
}

class ScenePolyline extends SceneCommand {
  final List<(double, double)> points;
  final String color;
  final double width, opacity;
  final bool closed, fill;
  final bool dashed;
  const ScenePolyline(
    this.points,
    this.color, {
    this.width = 1,
    this.opacity = 1,
    this.closed = false,
    this.fill = false,
    this.dashed = false,
  });
}

class SceneCircle extends SceneCommand {
  final double x, y, r;
  final String color, shape;
  const SceneCircle(
    this.x,
    this.y,
    this.r,
    this.color, {
    this.shape = 'circle',
  });
}

class SceneText extends SceneCommand {
  final double x, y, size;
  final String text, color;
  const SceneText(this.x, this.y, this.text, this.color, {this.size = 10});
}

class ScientificScene {
  final double width, height;
  final String background, fontFamily;
  final List<SceneCommand> commands;
  const ScientificScene(
    this.width,
    this.height,
    this.background,
    this.commands, {
    this.fontFamily = 'sans-serif',
  });
}

String _xml(String value) =>
    const HtmlEscape(HtmlEscapeMode.element).convert(value);
String _n(double value) => value.toStringAsFixed(3);

Vec3 _rotateForExport(Vec3 p, double rotX, double rotY, double rotZ) {
  final rx = rotX * math.pi / 180;
  final ry = rotY * math.pi / 180;
  final rz = rotZ * math.pi / 180;
  final x1 = p.x * math.cos(ry) + p.z * math.sin(ry);
  final z1 = -p.x * math.sin(ry) + p.z * math.cos(ry);
  final y2 = p.y * math.cos(rx) - z1 * math.sin(rx);
  final z2 = p.y * math.sin(rx) + z1 * math.cos(rx);
  return Vec3(
    x1 * math.cos(rz) - y2 * math.sin(rz),
    x1 * math.sin(rz) + y2 * math.cos(rz),
    z2,
  );
}

ScientificScene buildScientificScene(AxesData axes) {
  final width = axes.canvasPxW, height = axes.canvasPxH;
  final effectiveLengths = axes.aspectMode == 'equal'
      ? equalAspectLengths(
          dim: axes.dim,
          xLength: axes.xLen,
          yLength: axes.yLen,
          zLength: axes.zLen,
          xSpan: axes.xMax - axes.xMin,
          ySpan: axes.yMax - axes.yMin,
          zSpan: axes.zMax - axes.zMin,
        )
      : (x: axes.xLen, y: axes.yLen, z: axes.zLen);
  final left = 72.0,
      right = axes.legendMode == 'hidden' ? 28.0 : 175.0,
      top = 35.0,
      bottom = 62.0;
  final plotW = math.max(1, width - left - right).toDouble(),
      plotH = math.max(1, height - top - bottom).toDouble();
  final xs = AxisScale.named(
    axes.xScale,
    axes.xMin,
    axes.xMax,
    linearThreshold: axes.symlogThreshold,
  );
  final ys = AxisScale.named(
    axes.yScale,
    axes.yMin,
    axes.yMax,
    linearThreshold: axes.symlogThreshold,
  );
  final zs = AxisScale.named(
    axes.zScale,
    axes.zMin,
    axes.zMax,
    linearThreshold: axes.symlogThreshold,
  );
  Vec3? local(double x, double y, double z) {
    final tx = xs.transform(x), ty = ys.transform(y), tz = zs.transform(z);
    if (!tx.isFinite || !ty.isFinite || (axes.dim == 3 && !tz.isFinite)) {
      return null;
    }
    return Vec3(
      (tx - .5) * effectiveLengths.x,
      (ty - .5) * effectiveLengths.y,
      axes.dim == 3 ? (tz - .5) * effectiveLengths.z : 0,
    );
  }

  late final double projectionMinX,
      projectionMaxX,
      projectionMinY,
      projectionMaxY;
  if (axes.dim == 3) {
    final corners = <Vec3>[
      for (final x in [-effectiveLengths.x / 2, effectiveLengths.x / 2])
        for (final y in [-effectiveLengths.y / 2, effectiveLengths.y / 2])
          for (final z in [-effectiveLengths.z / 2, effectiveLengths.z / 2])
            _rotateForExport(Vec3(x, y, z), axes.rotX, axes.rotY, axes.rotZ),
    ];
    projectionMinX = corners.map((p) => p.x).reduce(math.min);
    projectionMaxX = corners.map((p) => p.x).reduce(math.max);
    projectionMinY = corners.map((p) => p.y).reduce(math.min);
    projectionMaxY = corners.map((p) => p.y).reduce(math.max);
  } else {
    projectionMinX = -effectiveLengths.x / 2;
    projectionMaxX = effectiveLengths.x / 2;
    projectionMinY = -effectiveLengths.y / 2;
    projectionMaxY = effectiveLengths.y / 2;
  }
  final projectionW = projectionMaxX - projectionMinX;
  final projectionH = projectionMaxY - projectionMinY;
  final equalScale = math.min(plotW / projectionW, plotH / projectionH);
  final scaleX = axes.aspectMode == 'equal' ? equalScale : plotW / projectionW;
  final scaleY = axes.aspectMode == 'equal' ? equalScale : plotH / projectionH;
  final mapLeft = left + (plotW - projectionW * scaleX) / 2;
  final mapTop = top + (plotH - projectionH * scaleY) / 2;
  (double, double)? map(double x, double y, [double z = 0]) {
    var p = local(x, y, z);
    if (p == null) return null;
    if (axes.dim == 3) {
      p = _rotateForExport(p, axes.rotX, axes.rotY, axes.rotZ);
    }
    return (
      mapLeft + (p.x - projectionMinX) * scaleX,
      mapTop + (projectionMaxY - p.y) * scaleY,
    );
  }

  final c = <SceneCommand>[];
  if (axes.dim == 3) {
    final corners = <(double, double, double)>[
      for (final x in [axes.xMin, axes.xMax])
        for (final y in [axes.yMin, axes.yMax])
          for (final z in [axes.zMin, axes.zMax]) (x, y, z),
    ];
    const edges = <(int, int)>[
      (0, 1),
      (0, 2),
      (0, 4),
      (1, 3),
      (1, 5),
      (2, 3),
      (2, 6),
      (3, 7),
      (4, 5),
      (4, 6),
      (5, 7),
      (6, 7),
    ];
    void addLine(
      (double, double, double) a,
      (double, double, double) b,
      String color, {
      double width = .7,
    }) {
      final p = map(a.$1, a.$2, a.$3), q = map(b.$1, b.$2, b.$3);
      if (p != null && q != null) {
        c.add(SceneLine(p.$1, p.$2, q.$1, q.$2, color, width: width));
      }
    }

    if (axes.showBorder) {
      for (final edge in edges) {
        addLine(corners[edge.$1], corners[edge.$2], '#777777');
      }
    }

    if (axes.grid) {
      if (axes.gridX) {
        for (final tick in xs.ticks()) {
          addLine(
            (tick.value, axes.yMin, axes.zMin),
            (tick.value, axes.yMin, axes.zMax),
            '#dddddd',
          );
          addLine(
            (tick.value, axes.yMin, axes.zMin),
            (tick.value, axes.yMax, axes.zMin),
            '#dddddd',
          );
        }
      }
      if (axes.gridY) {
        for (final tick in ys.ticks()) {
          addLine(
            (axes.xMin, tick.value, axes.zMin),
            (axes.xMax, tick.value, axes.zMin),
            '#dddddd',
          );
          addLine(
            (axes.xMin, tick.value, axes.zMin),
            (axes.xMin, tick.value, axes.zMax),
            '#dddddd',
          );
        }
      }
      if (axes.gridZ) {
        for (final tick in zs.ticks()) {
          addLine(
            (axes.xMin, axes.yMin, tick.value),
            (axes.xMax, axes.yMin, tick.value),
            '#dddddd',
          );
          addLine(
            (axes.xMin, axes.yMin, tick.value),
            (axes.xMin, axes.yMax, tick.value),
            '#dddddd',
          );
        }
      }
    }

    final atOrigin = axes.axisOrigin == 'origin';
    final ox = axisCrossingValue(axes.xMin, axes.xMax, atOrigin: atOrigin);
    final oy = axisCrossingValue(axes.yMin, axes.yMax, atOrigin: atOrigin);
    final oz = axisCrossingValue(axes.zMin, axes.zMax, atOrigin: atOrigin);
    addLine(
      (axes.xMin, oy, oz),
      (axes.xMax, oy, oz),
      axes.axisColors?.x ?? '#333333',
      width: axes.axisWidths?.x ?? .7,
    );
    addLine(
      (ox, axes.yMin, oz),
      (ox, axes.yMax, oz),
      axes.axisColors?.y ?? '#333333',
      width: axes.axisWidths?.y ?? .7,
    );
    addLine(
      (ox, oy, axes.zMin),
      (ox, oy, axes.zMax),
      axes.axisColors?.z ?? '#333333',
      width: axes.axisWidths?.z ?? .7,
    );
  } else {
    if (axes.showBorder) {
      final lowerLeft = map(axes.xMin, axes.yMin);
      final lowerRight = map(axes.xMax, axes.yMin);
      final upperLeft = map(axes.xMin, axes.yMax);
      if (lowerLeft != null && lowerRight != null && upperLeft != null) {
        c.add(
          SceneLine(
            lowerLeft.$1,
            upperLeft.$2,
            lowerLeft.$1,
            lowerLeft.$2,
            '#333333',
          ),
        );
        c.add(
          SceneLine(
            lowerLeft.$1,
            lowerLeft.$2,
            lowerRight.$1,
            lowerRight.$2,
            '#333333',
          ),
        );
      }
    }
    final atOrigin = axes.axisOrigin == 'origin';
    final ox = axisCrossingValue(axes.xMin, axes.xMax, atOrigin: atOrigin);
    final oy = axisCrossingValue(axes.yMin, axes.yMax, atOrigin: atOrigin);
    final x0 = map(axes.xMin, oy), x1 = map(axes.xMax, oy);
    final y0 = map(ox, axes.yMin), y1 = map(ox, axes.yMax);
    if (x0 != null && x1 != null) {
      c.add(
        SceneLine(
          x0.$1,
          x0.$2,
          x1.$1,
          x1.$2,
          axes.axisColors?.x ?? '#333333',
          width: axes.axisWidths?.x ?? .7,
        ),
      );
    }
    if (y0 != null && y1 != null) {
      c.add(
        SceneLine(
          y0.$1,
          y0.$2,
          y1.$1,
          y1.$2,
          axes.axisColors?.y ?? '#333333',
          width: axes.axisWidths?.y ?? .7,
        ),
      );
    }
  }
  final atOrigin = axes.axisOrigin == 'origin';
  final tickCrossX = axisCrossingValue(
    axes.xMin,
    axes.xMax,
    atOrigin: atOrigin,
  );
  final tickCrossY = axisCrossingValue(
    axes.yMin,
    axes.yMax,
    atOrigin: atOrigin,
  );
  for (final tick in xs.ticks()) {
    final p = map(
      tick.value,
      axes.dim == 3 ? axes.yMin : tickCrossY,
      axes.dim == 3 ? axes.zMin : 0,
    );
    if (p == null) continue;
    if (axes.dim == 2 && axes.grid && axes.gridX) {
      final q = map(tick.value, axes.yMax);
      final r = map(tick.value, axes.yMin);
      if (q != null && r != null) {
        c.add(SceneLine(q.$1, q.$2, r.$1, r.$2, '#dddddd'));
      }
    }
    c.add(SceneText(p.$1 - 12, p.$2 + 22, tick.label, '#333333'));
  }
  for (final tick in ys.ticks()) {
    final p = map(
      axes.dim == 3 ? axes.xMin : tickCrossX,
      tick.value,
      axes.dim == 3 ? axes.zMin : 0,
    );
    if (p == null) continue;
    if (axes.dim == 2 && axes.grid && axes.gridY) {
      final q = map(axes.xMin, tick.value);
      final r = map(axes.xMax, tick.value);
      if (q != null && r != null) {
        c.add(SceneLine(q.$1, q.$2, r.$1, r.$2, '#dddddd'));
      }
    }
    c.add(SceneText(p.$1 - 52, p.$2 + 4, tick.label, '#333333'));
  }
  if (axes.dim == 3) {
    for (final tick in zs.ticks()) {
      final p = map(axes.xMin, axes.yMin, tick.value);
      if (p != null) {
        c.add(SceneText(p.$1 - 42, p.$2 + 4, tick.label, '#333333'));
      }
    }
  }
  c.add(
    SceneText(
      left + plotW / 2 - 20,
      height - 14,
      axes.labelX,
      '#222222',
      size: 12,
    ),
  );
  c.add(SceneText(8, 18, axes.labelY, '#222222', size: 12));
  if (axes.hidden) c.clear();
  c.add(SceneClipBegin(left, top, plotW, plotH));
  final distribution = axes.dist;
  if (distribution != null && distribution.bins.isNotEmpty) {
    final maxCount = distribution.bins
        .map((bin) => bin.count)
        .fold<int>(1, math.max);
    final heightScale = (axes.yMax - axes.yMin) * .8 / maxCount;
    for (final bin in distribution.bins) {
      final x0 = bin.x0, x1 = bin.x1;
      final y0 = axes.yMin, y1 = y0 + bin.count * heightScale;
      final points = [
        map(x0, y0),
        map(x1, y0),
        map(x1, y1),
        map(x0, y1),
      ].whereType<(double, double)>().toList();
      if (points.length == 4) {
        c.add(
          ScenePolyline(
            points,
            '#94a3b8',
            closed: true,
            fill: true,
            opacity: .75,
          ),
        );
      }
    }
  }
  for (final mesh in axes.meshes) {
    for (final face in mesh.faces) {
      if (face.length < 3) continue;
      final pts = <(double, double)>[];
      for (final index in face) {
        if (index < 0 || index >= mesh.vertices.length) continue;
        final v = mesh.vertices[index], p = map(v.x, v.y, v.z);
        if (p != null) pts.add(p);
      }
      if (pts.length >= 3) {
        var faceColor = mesh.color ?? '#60a5fa';
        final values = mesh.vertexValues;
        if (values != null &&
            mesh.gradient != null &&
            mesh.valueMin != null &&
            mesh.valueMax != null &&
            face.every((index) => index >= 0 && index < values.length)) {
          final value =
              face.map((index) => values[index]).reduce((a, b) => a + b) /
              face.length;
          if (value.isFinite) {
            final span = mesh.valueMax! - mesh.valueMin!;
            final t = span.abs() <= 1e-15
                ? .5
                : (value - mesh.valueMin!) / span;
            faceColor = colorToHex(gradientColorAt(mesh.gradient!, t));
          }
        }
        c.add(
          ScenePolyline(
            pts,
            faceColor,
            closed: true,
            fill: mesh.fill != false,
            opacity: mesh.opacity ?? .6,
            width: .5,
          ),
        );
      }
    }
  }
  for (final line in axes.lines) {
    final color = line.lineColor ?? '#2563eb';
    if (line.bandLow != null && line.bandHigh != null) {
      var up = <(double, double)>[], lo = <(double, double)>[];
      void flushBand() {
        if (up.length >= 2) {
          c.add(
            ScenePolyline(
              [...up, ...lo.reversed],
              color,
              closed: true,
              fill: true,
              opacity: .18,
            ),
          );
        }
        up = [];
        lo = [];
      }

      for (
        var i = 0;
        i < line.points.length &&
            i < line.bandLow!.length &&
            i < line.bandHigh!.length;
        i++
      ) {
        final a = map(line.points[i].x, line.bandHigh![i]),
            b = map(line.points[i].x, line.bandLow![i]);
        if (a != null && b != null) {
          up.add(a);
          lo.add(b);
        } else {
          flushBand();
        }
      }
      flushBand();
    }
    var run = <(double, double)>[];
    (double, double)? previous;
    var previousIndex = -1;
    final mappedStyle =
        (line.colors?.isNotEmpty ?? false) || (line.sizes?.isNotEmpty ?? false);
    void flush() {
      if (!mappedStyle && run.length >= 2) {
        c.add(
          ScenePolyline(
            List.of(run),
            color,
            width: line.lineWidth ?? 1.5,
            dashed: line.lineStyle == 'dashed',
          ),
        );
      }
      run = [];
      previous = null;
      previousIndex = -1;
    }

    for (var i = 0; i < line.points.length; i++) {
      final z = line.zValues != null && i < line.zValues!.length
          ? line.zValues![i]
          : 0.0;
      final p = map(line.points[i].x, line.points[i].y, z);
      if (p == null) {
        flush();
        continue;
      }
      if (mappedStyle && previous != null) {
        final segmentColor =
            line.colors != null && previousIndex < line.colors!.length
            ? line.colors![previousIndex]
            : color;
        final segmentWidth =
            line.sizes != null && previousIndex < line.sizes!.length
            ? line.sizes![previousIndex]
            : line.lineWidth ?? 1.5;
        c.add(
          SceneLine(
            previous!.$1,
            previous!.$2,
            p.$1,
            p.$2,
            segmentColor,
            width: segmentWidth,
            dashed: line.lineStyle == 'dashed',
          ),
        );
      }
      run.add(p);
      previous = p;
      previousIndex = i;
      final xm = line.xErrorMinus != null && i < line.xErrorMinus!.length
              ? line.xErrorMinus![i]
              : 0.0,
          xp = line.xErrorPlus != null && i < line.xErrorPlus!.length
              ? line.xErrorPlus![i]
              : xm,
          ym = line.yErrorMinus != null && i < line.yErrorMinus!.length
              ? line.yErrorMinus![i]
              : 0.0,
          yp = line.yErrorPlus != null && i < line.yErrorPlus!.length
              ? line.yErrorPlus![i]
              : ym;
      final xa = map(line.points[i].x - xm, line.points[i].y),
          xb = map(line.points[i].x + xp, line.points[i].y),
          ya = map(line.points[i].x, line.points[i].y - ym),
          yb = map(line.points[i].x, line.points[i].y + yp);
      if (xa != null && xb != null && (xm > 0 || xp > 0)) {
        c.add(SceneLine(xa.$1, xa.$2, xb.$1, xb.$2, color));
      }
      if (ya != null && yb != null && (ym > 0 || yp > 0)) {
        c.add(SceneLine(ya.$1, ya.$2, yb.$1, yb.$2, color));
      }
    }
    flush();
  }
  for (final group in axes.points) {
    for (var i = 0; i < group.points.length; i++) {
      final point = group.points[i];
      final p = map(point.x, point.y, point.z ?? 0);
      if (p != null) {
        c.add(
          SceneCircle(
            p.$1,
            p.$2,
            group.sizes != null && i < group.sizes!.length
                ? group.sizes![i]
                : group.pointSize ?? 2.5,
            group.colors != null && i < group.colors!.length
                ? group.colors![i]
                : group.pointColor ?? '#dc2626',
            shape: group.shapes != null && i < group.shapes!.length
                ? group.shapes![i]
                : group.pointShape ?? 'circle',
          ),
        );
      }
    }
  }
  for (final item in axes.texts) {
    final fontPx = math.max(
      6.0,
      item.fontSize * plotW / effectiveLengths.x * .62,
    );
    final estimatedWidth = item.text.runes.length * fontPx * .58;
    final x = item.halign == 'left'
        ? left + 4
        : item.halign == 'right'
        ? left + plotW - estimatedWidth - 4
        : left + (plotW - estimatedWidth) / 2;
    final y = item.valign == 'top'
        ? top + fontPx
        : item.valign == 'bottom'
        ? top + plotH - 4
        : top + plotH / 2 + fontPx / 2;
    if (item.bgColor != null && item.bgColor!.isNotEmpty) {
      c.add(
        ScenePolyline(
          [
            (x - 3, y - fontPx - 2),
            (x + estimatedWidth + 3, y - fontPx - 2),
            (x + estimatedWidth + 3, y + 3),
            (x - 3, y + 3),
          ],
          item.bgColor!,
          closed: true,
          fill: true,
        ),
      );
    }
    c.add(SceneText(x, y, item.text, item.textColor, size: fontPx));
  }
  c.add(const SceneClipEnd());
  if (axes.legendMode != 'hidden') {
    var items =
        <({String name, String color, String kind})>[
              for (final line in axes.lines)
                (
                  name: line.name,
                  color: line.lineColor ?? '#2563eb',
                  kind: 'line',
                ),
              for (final group in axes.points)
                (
                  name: group.name,
                  color: group.pointColor ?? '#dc2626',
                  kind: 'point',
                ),
              for (final mesh in axes.meshes)
                (
                  name: mesh.name,
                  color: mesh.color ?? '#60a5fa',
                  kind: 'surface',
                ),
            ]
            .where(
              (item) =>
                  item.name.trim().isNotEmpty &&
                  !axes.legendHidden.contains(item.name),
            )
            .toList();
    if (axes.legendMode == 'manual') {
      int rank(String name) {
        final i = axes.legendOrder.indexOf(name);
        return i < 0 ? 1 << 20 : i;
      }

      items.sort((a, b) => rank(a.name).compareTo(rank(b.name)));
    } else if (axes.legendGrouping == 'type') {
      const rank = {'line': 0, 'point': 1, 'surface': 2};
      items.sort((a, b) => (rank[a.kind] ?? 9).compareTo(rank[b.kind] ?? 9));
    }
    var y = top + 15;
    for (final item in items) {
      if (item.kind == 'point') {
        c.add(SceneCircle(width - right + 26, y, 3, item.color));
      } else if (item.kind == 'surface') {
        c.add(
          ScenePolyline(
            [
              (width - right + 16, y - 4),
              (width - right + 36, y - 4),
              (width - right + 36, y + 4),
              (width - right + 16, y + 4),
            ],
            item.color,
            closed: true,
            fill: true,
            opacity: .7,
          ),
        );
      } else {
        c.add(
          SceneLine(
            width - right + 15,
            y,
            width - right + 38,
            y,
            item.color,
            width: 2,
          ),
        );
      }
      c.add(SceneText(width - right + 45, y + 4, item.name, '#222222'));
      y += 18;
    }
  }
  return ScientificScene(
    width,
    height,
    axes.bgColor,
    c,
    fontFamily: axes.fontFamily,
  );
}

String sceneToSvg(ScientificScene scene) {
  final b = StringBuffer(
    '<svg xmlns="http://www.w3.org/2000/svg" width="${_n(scene.width)}" height="${_n(scene.height)}" viewBox="0 0 ${_n(scene.width)} ${_n(scene.height)}">',
  );
  b.write(
    '<rect width="100%" height="100%" fill="${_xml(scene.background)}"/>',
  );
  for (final cmd in scene.commands) {
    switch (cmd) {
      case SceneClipBegin():
        b.write(
          '<defs><clipPath id="plot-clip"><rect x="${_n(cmd.x)}" y="${_n(cmd.y)}" width="${_n(cmd.width)}" height="${_n(cmd.height)}"/></clipPath></defs><g clip-path="url(#plot-clip)">',
        );
      case SceneClipEnd():
        b.write('</g>');
      case SceneLine():
        b.write(
          '<line x1="${_n(cmd.x1)}" y1="${_n(cmd.y1)}" x2="${_n(cmd.x2)}" y2="${_n(cmd.y2)}" stroke="${_xml(cmd.color)}" stroke-width="${_n(cmd.width)}" opacity="${_n(cmd.opacity)}"${cmd.dashed ? ' stroke-dasharray="6 4"' : ''}/>',
        );
      case ScenePolyline():
        final pts = cmd.points.map((p) => '${_n(p.$1)},${_n(p.$2)}').join(' ');
        b.write(
          '<${cmd.closed ? 'polygon' : 'polyline'} points="$pts" fill="${cmd.fill ? _xml(cmd.color) : 'none'}" stroke="${_xml(cmd.color)}" stroke-width="${_n(cmd.width)}" opacity="${_n(cmd.opacity)}"${cmd.dashed ? ' stroke-dasharray="6 4"' : ''}/>',
        );
      case SceneCircle():
        if (cmd.shape == 'square') {
          b.write(
            '<rect x="${_n(cmd.x - cmd.r)}" y="${_n(cmd.y - cmd.r)}" width="${_n(cmd.r * 2)}" height="${_n(cmd.r * 2)}" fill="${_xml(cmd.color)}"/>',
          );
        } else if (cmd.shape == 'diamond') {
          b.write(
            '<polygon points="${_n(cmd.x)},${_n(cmd.y - cmd.r)} ${_n(cmd.x + cmd.r)},${_n(cmd.y)} ${_n(cmd.x)},${_n(cmd.y + cmd.r)} ${_n(cmd.x - cmd.r)},${_n(cmd.y)}" fill="${_xml(cmd.color)}"/>',
          );
        } else if (cmd.shape == 'triangle') {
          b.write(
            '<polygon points="${_n(cmd.x)},${_n(cmd.y - cmd.r)} ${_n(cmd.x + cmd.r)},${_n(cmd.y + cmd.r)} ${_n(cmd.x - cmd.r)},${_n(cmd.y + cmd.r)}" fill="${_xml(cmd.color)}"/>',
          );
        } else {
          b.write(
            '<circle cx="${_n(cmd.x)}" cy="${_n(cmd.y)}" r="${_n(cmd.r)}" fill="${_xml(cmd.color)}"/>',
          );
        }
      case SceneText():
        b.write(
          '<text x="${_n(cmd.x)}" y="${_n(cmd.y)}" fill="${_xml(cmd.color)}" font-size="${_n(cmd.size)}" font-family="${_xml(scene.fontFamily)}">${_xml(cmd.text)}</text>',
        );
    }
  }
  return '${b.toString()}</svg>';
}

Map<String, dynamic> exportManifest(AxesData axes, String format) => {
  'application': 'SyphonNov',
  'version': '0.5.2',
  'format': format,
  'width': axes.exportWidth,
  'height': axes.exportHeight,
  'unit': axes.exportUnit,
  'dpi': axes.exportDpi,
  'pixelWidth': axes.canvasPxW,
  'pixelHeight': axes.canvasPxH,
  'fontFamily': axes.fontFamily,
  'fontStrategy': axes.fontExportStrategy,
  'fontStrategyApplied': format == 'pdf' && axes.fontExportStrategy != 'system'
      ? (_exportFontPath() == null
            ? 'core-font-fallback'
            : axes.fontExportStrategy == 'outline'
            ? 'embedded-subset-outline-fallback'
            : 'embedded-subset')
      : 'editable-svg-text',
  'fontWarning': _exportFontPath() == null && format == 'pdf'
      ? '未找到可嵌入的 Unicode 字体；PDF 阅读器可能报告缺字'
      : axes.fontExportStrategy == 'outline'
      ? '当前 PDF 后端不支持字形轮廓化，已回退为子集嵌入'
      : null,
  'scales': {'x': axes.xScale, 'y': axes.yScale, 'z': axes.zScale},
  'uncertainty': [
    for (final line in axes.lines)
      if (line.uncertaintyKind != null)
        {
          'series': line.name,
          'kind': line.uncertaintyKind,
          'source': line.uncertaintySource,
        },
  ],
};

String? _exportFontPath() {
  const candidates = [
    'assets/fonts/NotoSansCJKsc-Regular.otf',
    r'C:\Windows\Fonts\simhei.ttf',
    r'C:\Windows\Fonts\simsunb.ttf',
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  return null;
}

Future<pw.Font?> _loadExportFont(String strategy) async {
  if (strategy == 'system') return null;
  final path = _exportFontPath();
  if (path == null) return null;
  final bytes = await File(path).readAsBytes();
  return pw.Font.ttf(ByteData.sublistView(bytes));
}

Future<List<int>> sceneToPdf(AxesData axes) async {
  final svg = sceneToSvg(buildScientificScene(axes));
  final doc = pw.Document();
  final font = await _loadExportFont(axes.fontExportStrategy);
  final page = PdfPageFormat(
    axes.canvasPxW / axes.exportDpi * PdfPageFormat.inch,
    axes.canvasPxH / axes.exportDpi * PdfPageFormat.inch,
  );
  doc.addPage(
    pw.Page(
      pageFormat: page,
      margin: pw.EdgeInsets.zero,
      build: (_) => pw.SvgImage(
        svg: svg,
        fit: pw.BoxFit.fill,
        customFontLookup: font == null ? null : (_, _, _) => font,
      ),
    ),
  );
  return doc.save();
}

Future<String?> saveVectorPublication(AxesData axes, String format) async {
  final svg = sceneToSvg(buildScientificScene(axes));
  final ext = format == 'pdf' ? 'pdf' : 'svg';
  final loc = await getSaveLocation(
    suggestedName: 'figure.$ext',
    acceptedTypeGroups: [
      XTypeGroup(label: ext.toUpperCase(), extensions: [ext]),
    ],
  );
  if (loc == null) return null;
  if (format == 'pdf') {
    await File(loc.path).writeAsBytes(await sceneToPdf(axes));
  } else {
    await File(loc.path).writeAsString(svg);
  }
  await File('${loc.path}.manifest.json').writeAsString(
    const JsonEncoder.withIndent('  ').convert(exportManifest(axes, format)),
  );
  return loc.path;
}
