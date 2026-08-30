// 预制图表查看器:散点/折线/柱状/火山/热力/箱线/小提琴/桑基/网络 CustomPaint 渲染 + 预览交互 + 导出 PNG
// (由 React 版 ui/ViewerRender.tsx 移植,不含 ECharts 依赖)
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart'
    show PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/material.dart';

import '../models/color_utils.dart';
import '../models/data.dart' as md;
import '../models/exec_engine.dart';
import '../store/graph_store.dart';

// ==================== 表格辅助 ====================

List<md.Column> numericCols(md.TableData t) => t.columns
    .where((c) => c.values.every((v) => v == null || md.toNum(v) != null))
    .toList();

md.Column? pickCol(md.TableData t, String name, int fallback) {
  if (name.isNotEmpty) {
    for (final c in t.columns) {
      if (c.name == name) return c;
    }
  }
  final numeric = numericCols(t);
  if (numeric.length > fallback) return numeric[fallback];
  if (t.columns.length > fallback) return t.columns[fallback];
  return t.columns.isEmpty ? null : t.columns.first;
}

bool isCategoryCol(md.Column? col) {
  if (col == null) return false;
  final n = math.min(20, col.values.length);
  var strCount = 0;
  for (var i = 0; i < n; i++) {
    final v = col.values[i];
    if (v is String && md.toNum(v) == null) strCount++;
  }
  return strCount > n / 2;
}

double percentile(List<double> sorted, double p) {
  if (sorted.isEmpty) return 0;
  final idx = p * (sorted.length - 1);
  final lo = idx.floor();
  final hi = idx.ceil();
  if (lo == hi) return sorted[lo];
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (idx - lo);
}

md.Column? colByName(md.TableData t, String name) {
  if (name.isEmpty) return null;
  for (final c in t.columns) {
    if (c.name == name) return c;
  }
  return null;
}

class Link {
  final String source;
  final String target;
  final double value;
  const Link(this.source, this.target, this.value);
}

({List<Link> links, List<String> names}) buildLinks(
  md.TableData t,
  String sourceCol,
  String targetCol,
  String valueCol,
) {
  final sc = colByName(t, sourceCol);
  final tc = colByName(t, targetCol);
  if (sc == null || tc == null) return (links: [], names: []);
  final vc = valueCol.isEmpty ? null : colByName(t, valueCol);
  final map = <String, double>{};
  final nameSet = <String>{};
  final n = math.min(sc.values.length, tc.values.length);
  for (var i = 0; i < n; i++) {
    final s = '${sc.values[i] ?? ''}'.trim();
    final t = '${tc.values[i] ?? ''}'.trim();
    if (s.isEmpty || t.isEmpty || s == t) continue;
    final v = vc == null ? 1.0 : (md.toNum(vc.values[i]) ?? 1.0);
    map['$s\u0000$t'] = (map['$s\u0000$t'] ?? 0) + math.max(0, v);
    nameSet.add(s);
    nameSet.add(t);
  }
  final links = <Link>[];
  map.forEach((k, v) {
    final parts = k.split('\u0000');
    links.add(Link(parts[0], parts[1], v));
  });
  return (links: links, names: nameSet.toList());
}

/// 渐变色带插值
Color gradientColor(List<md.GradientStop> stops, double v01) {
  if (stops.isEmpty) return const Color(0xFF3B82F6);
  if (stops.length == 1) return parseColor(stops.first.color);
  var i = 0;
  while (i < stops.length - 1 && stops[i + 1].offset <= v01) {
    i++;
  }
  final a = stops[i];
  final b = stops[i + 1];
  final span = (b.offset - a.offset).abs();
  final t = span <= 1e-9 ? 0.0 : ((v01 - a.offset) / span).clamp(0.0, 1.0);
  return Color.lerp(parseColor(a.color), parseColor(b.color), t)!;
}

// ==================== 刻度 ====================

class _Ticks {
  final List<double> ticks;
  final double step;
  const _Ticks(this.ticks, this.step);
}

_Ticks _niceTicks(double min, double max, int targetCount) {
  final span = max - min;
  if (!span.isFinite || span <= 1e-9) return _Ticks([min], 1);
  final raw = span / math.max(1, targetCount);
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final norm = raw / mag;
  double step;
  if (norm < 1.5) {
    step = 1;
  } else if (norm < 3.5) {
    step = 2;
  } else if (norm < 7.5) {
    step = 5;
  } else {
    step = 10;
  }
  step *= mag;
  final ticks = <double>[];
  final first = (min / step - 1e-9).ceil() * step;
  for (var v = first; v <= max + step * 1e-6; v += step) {
    ticks.add(double.parse(v.toStringAsFixed(10)));
  }
  if (ticks.isEmpty) ticks.add(min);
  return _Ticks(ticks, step);
}

String _fmtTick(double v, double step) {
  if (!v.isFinite) return '';
  if (v.abs() < 1e-9) v = 0;
  final dec = step >= 1
      ? 0
      : math.min(6, math.max(0, (-math.log(step) / math.ln10).ceil()));
  return v.toStringAsFixed(dec);
}

// ==================== 绘制辅助 ====================

void _drawText(
  Canvas canvas,
  String text,
  Offset pos, {
  Color color = const Color(0xFF333333),
  double size = 11,
  FontWeight weight = FontWeight.normal,
  TextAlign align = TextAlign.center,
  double maxWidth = 400,
}) {
  if (text.isEmpty) return;
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(color: color, fontSize: size, fontWeight: weight),
    ),
    textDirection: TextDirection.ltr,
    textAlign: align,
  )..layout(maxWidth: maxWidth);
  final w = tp.width;
  final h = tp.height;
  double x = pos.dx;
  if (align == TextAlign.center) x -= w / 2;
  if (align == TextAlign.right) x -= w;
  tp.paint(canvas, Offset(x, pos.dy - h / 2));
}

class _ValueAxis {
  final double min;
  final double max;
  final _Ticks ticks;
  _ValueAxis(double min, double max, int target)
    : min = min,
      max = max,
      ticks = _niceTicks(min, max, target);
}

double _mapV(double v, double min, double max, double a, double b) =>
    a + (v - min) / math.max(max - min, 1e-9) * (b - a);

/// 绘制值轴(轴线 + 刻度 + 数字 + 名称)
void _drawValueAxis(
  Canvas canvas,
  Rect plot, {
  required bool vertical,
  required _ValueAxis axis,
  required List<Color> axisColors,
  required double labelSize,
  required Color textColor,
  String? name,
  double nameGap = 18,
}) {
  final paint = Paint()
    ..color = axisColors[0]
    ..strokeWidth = 1;
  final tickPaint = Paint()
    ..color = textColor.withValues(alpha: 0.75)
    ..strokeWidth = 1;
  const tickSize = 4.0;
  if (!vertical) {
    canvas.drawLine(
      Offset(plot.left, plot.bottom),
      Offset(plot.right, plot.bottom),
      paint,
    );
    for (final t in axis.ticks.ticks) {
      final x = _mapV(t, axis.min, axis.max, plot.left, plot.right);
      canvas.drawLine(
        Offset(x, plot.bottom - tickSize),
        Offset(x, plot.bottom + tickSize),
        tickPaint,
      );
      _drawText(
        canvas,
        _fmtTick(t, axis.ticks.step),
        Offset(x, plot.bottom + tickSize + 6),
        color: textColor,
        size: labelSize,
      );
    }
    if (name != null) {
      _drawText(
        canvas,
        name,
        Offset(plot.center.dx, plot.bottom + nameGap),
        color: textColor,
        size: labelSize + 2,
      );
    }
  } else {
    canvas.drawLine(
      Offset(plot.left, plot.bottom),
      Offset(plot.left, plot.top),
      paint,
    );
    for (final t in axis.ticks.ticks) {
      final y = _mapV(t, axis.min, axis.max, plot.bottom, plot.top);
      canvas.drawLine(
        Offset(plot.left - tickSize, y),
        Offset(plot.left + tickSize, y),
        tickPaint,
      );
      _drawText(
        canvas,
        _fmtTick(t, axis.ticks.step),
        Offset(plot.left - tickSize - 5, y),
        color: textColor,
        size: labelSize,
        align: TextAlign.right,
      );
    }
    if (name != null) {
      canvas.save();
      canvas.translate(plot.left - nameGap, plot.center.dy);
      canvas.rotate(-math.pi / 2);
      _drawText(
        canvas,
        name,
        Offset.zero,
        color: textColor,
        size: labelSize + 2,
      );
      canvas.restore();
    }
  }
}

void _drawCatAxis(
  Canvas canvas,
  Rect plot, {
  required bool vertical,
  required List<String> cats,
  required Color color,
  required double labelSize,
  required Color textColor,
  double rotateDeg = 0,
}) {
  final paint = Paint()
    ..color = color
    ..strokeWidth = 1;
  if (!vertical) {
    canvas.drawLine(
      Offset(plot.left, plot.bottom),
      Offset(plot.right, plot.bottom),
      paint,
    );
    final n = cats.length;
    for (var i = 0; i < n; i++) {
      final x = plot.left + (i + 0.5) / n * plot.width;
      canvas.drawLine(
        Offset(x, plot.bottom - 4),
        Offset(x, plot.bottom + 4),
        paint,
      );
      if (rotateDeg != 0) {
        canvas.save();
        canvas.translate(x, plot.bottom + 6);
        canvas.rotate(-rotateDeg * math.pi / 180);
        _drawText(
          canvas,
          cats[i],
          Offset.zero,
          color: textColor,
          size: labelSize,
        );
        canvas.restore();
      } else {
        _drawText(
          canvas,
          cats[i],
          Offset(x, plot.bottom + 6),
          color: textColor,
          size: labelSize,
        );
      }
    }
  } else {
    canvas.drawLine(
      Offset(plot.left, plot.bottom),
      Offset(plot.left, plot.top),
      paint,
    );
    final n = cats.length;
    for (var i = 0; i < n; i++) {
      final y = plot.top + (i + 0.5) / n * plot.height;
      canvas.drawLine(
        Offset(plot.left - 4, y),
        Offset(plot.left + 4, y),
        paint,
      );
      _drawText(
        canvas,
        cats[i],
        Offset(plot.left - 5, y),
        color: textColor,
        size: labelSize,
        align: TextAlign.right,
      );
    }
  }
}

void _drawPlotFrame(
  Canvas canvas,
  Rect plot, {
  required _ValueAxis xa,
  required _ValueAxis ya,
  required Color gridColor,
  required Color borderColor,
}) {
  final grid = Paint()
    ..color = gridColor
    ..strokeWidth = 0.8;
  for (final t in xa.ticks.ticks) {
    if (t == xa.min || t == xa.max) continue;
    final x = _mapV(t, xa.min, xa.max, plot.left, plot.right);
    canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), grid);
  }
  for (final t in ya.ticks.ticks) {
    if (t == ya.min || t == ya.max) continue;
    final y = _mapV(t, ya.min, ya.max, plot.bottom, plot.top);
    canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
  }
  canvas.drawRect(
    plot,
    Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1,
  );
}

void _drawTitle(Canvas canvas, Size size, String title) {
  if (title.isEmpty) return;
  _drawText(
    canvas,
    title,
    Offset(size.width / 2, 16),
    color: const Color(0xFF333333),
    size: 13,
    weight: FontWeight.w500,
  );
}

// ==================== 图表 Painter ====================

class ChartData {
  final String chartType;
  final Map<String, dynamic> params;
  final ExecResult? result;
  const ChartData({required this.chartType, required this.params, this.result});
}

class ChartPainter extends CustomPainter {
  final ChartData data;
  final bool compact;
  final Color bg;
  ChartPainter({
    required this.data,
    this.compact = false,
    this.bg = Colors.white,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    canvas.drawRect(Offset.zero & size, Paint()..color = bg);
    final params = data.params;
    final result = data.result;
    final title = '${params['title'] ?? ''}';
    _drawTitle(canvas, size, title);

    final inputs = result?.inputs ?? const <String, md.DataObject?>{};
    final table = inputs['in0'];
    final scatter = inputs['in1'];
    final series = inputs['in2'];
    final multi = result?.multiInputs ?? const <String, List<md.DataObject>>{};

    final labelSize = compact ? 10.0 : 11.0;
    final textColor = const Color(0xFF475569);
    final axisColor = const Color(0xFF94A3B8);

    switch (data.chartType) {
      case 'scatter':
        _paintScatter(
          canvas,
          size,
          params,
          table,
          scatter,
          labelSize,
          textColor,
          axisColor,
        );
        break;
      case 'line':
        _paintLine(
          canvas,
          size,
          params,
          table,
          series,
          labelSize,
          textColor,
          axisColor,
        );
        break;
      case 'bar':
        _paintBar(canvas, size, params, table, labelSize, textColor, axisColor);
        break;
      case 'volcano':
        _paintVolcano(
          canvas,
          size,
          params,
          table,
          labelSize,
          textColor,
          axisColor,
        );
        break;
      case 'heatmap':
        _paintHeatmap(
          canvas,
          size,
          params,
          table,
          inputs,
          labelSize,
          textColor,
          axisColor,
        );
        break;
      case 'box':
        _paintBox(canvas, size, params, table, labelSize, textColor, axisColor);
        break;
      case 'violin':
        _paintViolin(
          canvas,
          size,
          params,
          table,
          labelSize,
          textColor,
          axisColor,
        );
        break;
      case 'sankey':
        _paintSankey(canvas, size, params, table, textColor);
        break;
      case 'graph':
        _paintGraph(canvas, size, params, table, textColor);
        break;
      default:
        _paintEmpty(canvas, size);
    }
    // 图元叠加层:接入的点/线/面/文本(可多连)像"原理化输出"一样画进图中
    _paintOverlayPrimitives(canvas, size, inputs, multi);
  }

  Rect _plot(Size size, double left, double top, double right, double bottom) =>
      Rect.fromLTRB(left, top, size.width - right, size.height - bottom);

  void _paintScatter(
    Canvas canvas,
    Size size,
    Map<String, dynamic> params,
    md.DataObject? table,
    md.DataObject? scatter,
    double labelSize,
    Color textColor,
    Color axisColor,
  ) {
    List<Offset> pts = [];
    List<Color> colors = [];
    String? xName, yName;
    if (scatter is md.ScatterData) {
      final pts3 = scatter.points.take(4000).toList();
      final hasZ = pts3.any((p) => p.z != null);
      pts = pts3.map((p) => Offset(p.x, p.y)).toList();
      colors = hasZ
          ? pts3
                .map(
                  (p) => parseColor(
                    'hsl(${((210 + (p.z ?? 0) * 60) % 360).toStringAsFixed(0)},70%,60%)',
                  ),
                )
                .toList()
          : List.filled(pts.length, const Color(0xFF3B82F6));
    } else if (table is md.TableData) {
      final xCol = pickCol(table, '${params['xCol'] ?? ''}', 0);
      final yCol = pickCol(table, '${params['yCol'] ?? ''}', 1);
      xName = xCol?.name ?? 'X';
      yName = yCol?.name ?? 'Y';
      final n = math.min(
        table.columns.isEmpty ? 0 : table.columns.first.values.length,
        5000,
      );
      for (var i = 0; i < n; i++) {
        final x = md.toNum(xCol?.values[i]);
        final y = md.toNum(yCol?.values[i]);
        if (x != null && y != null) pts.add(Offset(x, y));
      }
      colors = List.filled(pts.length, const Color(0xFF3B82F6));
    }
    if (pts.isEmpty) {
      _paintEmpty(canvas, size);
      return;
    }
    final xmin = pts.map((p) => p.dx).reduce(math.min);
    final xmax = pts.map((p) => p.dx).reduce(math.max);
    final ymin = pts.map((p) => p.dy).reduce(math.min);
    final ymax = pts.map((p) => p.dy).reduce(math.max);
    final plot = _plot(size, 45, 30, 20, 40);
    _drawPlotFrame(
      canvas,
      plot,
      xa: _ValueAxis(xmin, xmax, 6),
      ya: _ValueAxis(ymin, ymax, 6),
      gridColor: const Color(0xFFE5E7EB),
      borderColor: axisColor,
    );
    _drawValueAxis(
      canvas,
      plot,
      vertical: false,
      axis: _ValueAxis(xmin, xmax, 6),
      axisColors: [axisColor],
      labelSize: labelSize,
      textColor: textColor,
      name: xName,
    );
    _drawValueAxis(
      canvas,
      plot,
      vertical: true,
      axis: _ValueAxis(ymin, ymax, 6),
      axisColors: [axisColor],
      labelSize: labelSize,
      textColor: textColor,
      name: yName,
    );
    final r = (7.0 * size.shortestSide / 480).clamp(1.5, 5.0);
    final pp = Paint();
    for (var i = 0; i < pts.length; i++) {
      pp.color = colors[i];
      canvas.drawCircle(
        Offset(
          _mapV(pts[i].dx, xmin, xmax, plot.left, plot.right),
          _mapV(pts[i].dy, ymin, ymax, plot.bottom, plot.top),
        ),
        r,
        pp,
      );
    }
  }

  void _paintLine(
    Canvas canvas,
    Size size,
    Map<String, dynamic> params,
    md.DataObject? table,
    md.DataObject? series,
    double labelSize,
    Color textColor,
    Color axisColor,
  ) {
    List<String> cats = [];
    List<double> vals = [];
    if (series is md.SeriesData) {
      cats = series.points.map((p) => p.x.toString()).toList();
      vals = series.points.map((p) => p.y).toList();
    } else if (table is md.TableData) {
      final xCol = pickCol(table, '${params['xCol'] ?? ''}', 0);
      final yCol = pickCol(table, '${params['yCol'] ?? ''}', 1);
      final cat = isCategoryCol(xCol);
      final n = table.columns.isEmpty ? 0 : table.columns.first.values.length;
      for (var i = 0; i < n; i++) {
        final y = md.toNum(yCol?.values[i]);
        if (y == null) continue;
        cats.add(
          cat ? '${xCol?.values[i] ?? i}' : '${md.toNum(xCol?.values[i]) ?? i}',
        );
        vals.add(y);
      }
    }
    if (cats.isEmpty || vals.isEmpty) {
      _paintEmpty(canvas, size);
      return;
    }
    final plot = _plot(size, 45, 30, 20, 40);
    final n = cats.length;
    final stepX = plot.width / math.max(1, n - 1);
    final ymin = vals.reduce(math.min);
    final ymax = vals.reduce(math.max);
    _drawCatAxis(
      canvas,
      plot,
      vertical: false,
      cats: cats,
      color: axisColor,
      labelSize: labelSize,
      textColor: textColor,
      rotateDeg: n > 8 ? 30 : 0,
    );
    _drawValueAxis(
      canvas,
      plot,
      vertical: true,
      axis: _ValueAxis(ymin, ymax, 6),
      axisColors: [axisColor],
      labelSize: labelSize,
      textColor: textColor,
    );
    final path = Path();
    for (var i = 0; i < n; i++) {
      final x = i == 0 ? plot.left : plot.left + i * stepX;
      final y = _mapV(vals[i], ymin, ymax, plot.bottom, plot.top);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF3B82F6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  void _paintBar(
    Canvas canvas,
    Size size,
    Map<String, dynamic> params,
    md.DataObject? table,
    double labelSize,
    Color textColor,
    Color axisColor,
  ) {
    if (table is! md.TableData) {
      _paintEmpty(canvas, size);
      return;
    }
    final numeric = numericCols(table);
    final yCol = pickCol(table, '${params['yCol'] ?? ''}', -1);
    final target = (yCol != null && numeric.any((c) => c.name == yCol.name))
        ? yCol
        : (numeric.isEmpty ? null : numeric.first);
    if (target == null) {
      _paintEmpty(canvas, size);
      return;
    }
    final xCol = pickCol(table, '${params['xCol'] ?? ''}', 0);
    final cat = isCategoryCol(xCol);
    final cats = <String>[];
    final vals = <double>[];
    final n = table.columns.isEmpty ? 0 : table.columns.first.values.length;
    for (var i = 0; i < n; i++) {
      final v = md.toNum(target.values[i]);
      if (v == null) continue;
      cats.add(cat ? '${xCol?.values[i] ?? i}' : '$i');
      vals.add(v);
    }
    if (cats.isEmpty) {
      _paintEmpty(canvas, size);
      return;
    }
    final plot = _plot(size, 45, 30, 20, 40);
    _drawCatAxis(
      canvas,
      plot,
      vertical: false,
      cats: cats,
      color: axisColor,
      labelSize: labelSize,
      textColor: textColor,
      rotateDeg: cats.length > 8 ? 30 : 0,
    );
    final ymax = vals.reduce(math.max);
    _drawValueAxis(
      canvas,
      plot,
      vertical: true,
      axis: _ValueAxis(0, ymax * 1.05, 6),
      axisColors: [axisColor],
      labelSize: labelSize,
      textColor: textColor,
    );
    final bw = plot.width / cats.length * 0.6;
    for (var i = 0; i < cats.length; i++) {
      final cx = plot.left + (i + 0.5) / cats.length * plot.width;
      final y0 = _mapV(0, 0, ymax * 1.05, plot.bottom, plot.top);
      final y1 = _mapV(vals[i], 0, ymax * 1.05, plot.bottom, plot.top);
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTRB(
            cx - bw / 2,
            math.min(y0, y1),
            cx + bw / 2,
            math.max(y0, y1),
          ),
          topLeft: const Radius.circular(1),
          topRight: const Radius.circular(1),
        ),
        Paint()..color = const Color(0xFF3B82F6),
      );
    }
  }

  void _paintVolcano(
    Canvas canvas,
    Size size,
    Map<String, dynamic> params,
    md.DataObject? table,
    double labelSize,
    Color textColor,
    Color axisColor,
  ) {
    if (table is! md.TableData) {
      _paintEmpty(canvas, size);
      return;
    }
    final fcCol = pickCol(table, '${params['fcCol'] ?? ''}', 0);
    final pCol = pickCol(table, '${params['pCol'] ?? ''}', 1);
    if (fcCol == null || pCol == null) {
      _paintEmpty(canvas, size);
      return;
    }
    final pts = <Offset>[];
    final colors = <Color>[];
    final n = table.columns.isEmpty ? 0 : table.columns.first.values.length;
    for (var i = 0; i < n; i++) {
      final fc = md.toNum(fcCol.values[i]);
      final p = md.toNum(pCol.values[i]);
      if (fc == null || p == null || p <= 0) continue;
      final negLog = -math.log(p) / math.ln10;
      final color = fc.abs() > 1 && p < 0.05
          ? const Color(0xFFEF4444)
          : p < 0.05
          ? const Color(0xFFF59E0B)
          : const Color(0xFF64748B);
      pts.add(Offset(fc, negLog));
      colors.add(color);
    }
    if (pts.isEmpty) {
      _paintEmpty(canvas, size);
      return;
    }
    final xs = pts.map((p) => p.dx).toList();
    final ys = pts.map((p) => p.dy).toList();
    final xmin = xs.reduce(math.min);
    final xmax = xs.reduce(math.max);
    final ymin = ys.reduce(math.min);
    final ymax = ys.reduce(math.max);
    final plot = _plot(size, 50, 30, 20, 40);
    final xa = _ValueAxis(xmin, xmax, 6);
    final ya = _ValueAxis(ymin, ymax, 6);
    _drawPlotFrame(
      canvas,
      plot,
      xa: xa,
      ya: ya,
      gridColor: const Color(0xFFE5E7EB),
      borderColor: axisColor,
    );
    _drawValueAxis(
      canvas,
      plot,
      vertical: false,
      axis: xa,
      axisColors: [axisColor],
      labelSize: labelSize,
      textColor: textColor,
      name: fcCol.name,
    );
    _drawValueAxis(
      canvas,
      plot,
      vertical: true,
      axis: ya,
      axisColors: [axisColor],
      labelSize: labelSize,
      textColor: textColor,
      name: '-log10(${pCol.name})',
    );
    final mark = Paint()
      ..color = const Color(0xFF475569)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    const dash = <double>[4, 4];
    mark.strokeCap = StrokeCap.round;
    for (final v in [1.0, -1.0]) {
      if (v < xmin || v > xmax) continue;
      final x = _mapV(v, xmin, xmax, plot.left, plot.right);
      canvas.drawPath(
        _dashPath(Offset(x, plot.top), Offset(x, plot.bottom), dash),
        mark,
      );
    }
    final y05 = -math.log(0.05) / math.ln10;
    if (y05 >= ymin && y05 <= ymax) {
      final y = _mapV(y05, ymin, ymax, plot.bottom, plot.top);
      canvas.drawPath(
        _dashPath(Offset(plot.left, y), Offset(plot.right, y), dash),
        mark,
      );
    }
    final pp = Paint();
    final r = (6.0 * size.shortestSide / 480).clamp(1.5, 4.0);
    for (var i = 0; i < pts.length; i++) {
      pp.color = colors[i];
      canvas.drawCircle(
        Offset(
          _mapV(pts[i].dx, xmin, xmax, plot.left, plot.right),
          _mapV(pts[i].dy, ymin, ymax, plot.bottom, plot.top),
        ),
        r,
        pp,
      );
    }
  }

  Path _dashPath(Offset a, Offset b, List<double> dash) {
    final p = Path();
    final d = (b - a).distance;
    if (d <= 0) return p;
    final dir = (b - a) / d;
    var pos = 0.0;
    var idx = 0;
    var drawing = true;
    p.moveTo(a.dx, a.dy);
    while (pos < d) {
      final len = math.min(dash[idx], d - pos);
      if (drawing) {
        p.lineTo(a.dx + dir.dx * (pos + len), a.dy + dir.dy * (pos + len));
      } else {
        p.moveTo(a.dx + dir.dx * (pos + len), a.dy + dir.dy * (pos + len));
      }
      pos += len;
      idx = (idx + 1) % dash.length;
      drawing = !drawing;
    }
    return p;
  }

  void _paintHeatmap(
    Canvas canvas,
    Size size,
    Map<String, dynamic> params,
    md.DataObject? table,
    Map<String, md.DataObject?> inputs,
    double labelSize,
    Color textColor,
    Color axisColor,
  ) {
    if (table is! md.TableData) {
      _paintEmpty(canvas, size);
      return;
    }
    final cols = numericCols(table).take(10).toList();
    if (cols.isEmpty) {
      _paintEmpty(canvas, size);
      return;
    }
    final rows = math.min(120, cols.first.values.length);
    final cells = <List<double?>>[];
    var dMin = double.infinity;
    var dMax = -double.infinity;
    for (var i = 0; i < rows; i++) {
      final row = <double?>[];
      for (var j = 0; j < cols.length; j++) {
        final v = md.toNum(cols[j].values[i]);
        row.add(v);
        if (v != null) {
          if (v < dMin) dMin = v;
          if (v > dMax) dMax = v;
        }
      }
      cells.add(row);
    }
    if (!dMin.isFinite) dMin = 0;
    if (!dMax.isFinite) dMax = 1;
    final cb = inputs['in1'];
    List<md.GradientStop> stops;
    double heatMin, heatMax;
    if (cb is md.ColorbarData && cb.stops.isNotEmpty) {
      stops = cb.stops;
      heatMin = cb.min?.isFinite == true ? cb.min! : dMin;
      heatMax = cb.max?.isFinite == true ? cb.max! : dMax;
    } else {
      stops = md.parseGradient(params['gradient']);
      heatMin = dMin;
      heatMax = dMax;
    }
    final plot = _plot(size, 60, 30, 20, 48);
    final cw = plot.width / cols.length;
    final ch = plot.height / rows;
    for (var i = 0; i < rows; i++) {
      for (var j = 0; j < cols.length; j++) {
        final v = cells[i][j];
        final color = v == null
            ? const Color(0xFFF3F4F6)
            : gradientColor(
                stops,
                ((v - heatMin) / math.max(heatMax - heatMin, 1e-9)).clamp(
                  0.0,
                  1.0,
                ),
              );
        canvas.drawRect(
          Rect.fromLTWH(
            plot.left + j * cw,
            plot.top + i * ch,
            cw + 0.5,
            ch + 0.5,
          ),
          Paint()..color = color,
        );
      }
    }
    canvas.drawRect(
      plot,
      Paint()
        ..color = axisColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    for (var j = 0; j < cols.length; j++) {
      canvas.save();
      canvas.translate(plot.left + j * cw + cw / 2, plot.bottom + 6);
      canvas.rotate(-math.pi / 3.5);
      _drawText(
        canvas,
        cols[j].name,
        Offset.zero,
        color: textColor,
        size: labelSize,
        align: TextAlign.left,
      );
      canvas.restore();
    }
    final step = math.max(1, rows ~/ 20).toInt();
    for (var i = 0; i < rows; i += step) {
      _drawText(
        canvas,
        '$i',
        Offset(plot.left - 5, plot.top + i * ch + ch / 2),
        color: textColor,
        size: labelSize,
        align: TextAlign.right,
      );
    }
    final bar = Rect.fromLTRB(
      plot.left,
      plot.bottom + 14,
      plot.right,
      plot.bottom + 22,
    );
    final sw = Paint();
    for (var x = 0.0; x <= 100; x += 1) {
      sw.color = gradientColor(stops, x / 100);
      canvas.drawRect(
        Rect.fromLTWH(
          bar.left + x / 100 * bar.width,
          bar.top,
          bar.width / 100 + 0.5,
          bar.height,
        ),
        sw,
      );
    }
    _drawText(
      canvas,
      heatMin.toStringAsFixed(2),
      Offset(bar.left, bar.bottom + 8),
      color: textColor,
      size: labelSize,
      align: TextAlign.left,
    );
    _drawText(
      canvas,
      heatMax.toStringAsFixed(2),
      Offset(bar.right, bar.bottom + 8),
      color: textColor,
      size: labelSize,
      align: TextAlign.right,
    );
  }

  void _paintBox(
    Canvas canvas,
    Size size,
    Map<String, dynamic> params,
    md.DataObject? table,
    double labelSize,
    Color textColor,
    Color axisColor,
  ) {
    if (table is! md.TableData) {
      _paintEmpty(canvas, size);
      return;
    }
    final cols = numericCols(table).take(12).toList();
    if (cols.isEmpty) {
      _paintEmpty(canvas, size);
      return;
    }
    double yMin = double.infinity, yMax = -double.infinity;
    final boxData = <List<double>>[];
    for (final c in cols) {
      final vals = c.values.map(md.toNum).whereType<double>().toList()..sort();
      if (vals.isEmpty) continue;
      double q(double r) => percentile(vals, r);
      boxData.add([q(0), q(0.25), q(0.5), q(0.75), q(1)]);
      if (vals.first < yMin) yMin = vals.first;
      if (vals.last > yMax) yMax = vals.last;
    }
    if (boxData.isEmpty) {
      _paintEmpty(canvas, size);
      return;
    }
    final plot = _plot(size, 45, 30, 20, 60);
    _drawValueAxis(
      canvas,
      plot,
      vertical: true,
      axis: _ValueAxis(yMin, yMax, 6),
      axisColors: [axisColor],
      labelSize: labelSize,
      textColor: textColor,
    );
    final names = cols
        .where((c) => c.values.map(md.toNum).whereType<double>().isNotEmpty)
        .map((c) => c.name)
        .toList();
    _drawCatAxis(
      canvas,
      plot,
      vertical: false,
      cats: names,
      color: axisColor,
      labelSize: labelSize,
      textColor: textColor,
      rotateDeg: 30,
    );
    final n = boxData.length;
    final bw = plot.width / n * 0.5;
    for (var i = 0; i < n; i++) {
      final d = boxData[i];
      final cx = plot.left + (i + 0.5) / n * plot.width;
      double yv(double v) => _mapV(v, yMin, yMax, plot.bottom, plot.top);
      final box = Rect.fromLTRB(cx - bw / 2, yv(d[3]), cx + bw / 2, yv(d[1]));
      final whisker = Paint()
        ..color = const Color(0xFF3B82F6)
        ..strokeWidth = 1.5;
      canvas.drawLine(Offset(cx, yv(d[0])), Offset(cx, yv(d[1])), whisker);
      canvas.drawLine(
        Offset(cx - bw / 4, yv(d[0])),
        Offset(cx + bw / 4, yv(d[0])),
        whisker,
      );
      canvas.drawLine(Offset(cx, yv(d[3])), Offset(cx, yv(d[4])), whisker);
      canvas.drawLine(
        Offset(cx - bw / 4, yv(d[4])),
        Offset(cx + bw / 4, yv(d[4])),
        whisker,
      );
      canvas.drawRect(
        box,
        Paint()..color = const Color(0xFF3B82F6).withValues(alpha: 0.55),
      );
      canvas.drawRect(
        box,
        Paint()
          ..color = const Color(0xFF1D4ED8)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
      canvas.drawLine(
        Offset(box.left, yv(d[2])),
        Offset(box.right, yv(d[2])),
        Paint()
          ..color = Colors.white
          ..strokeWidth = 1.5,
      );
    }
  }

  void _paintViolin(
    Canvas canvas,
    Size size,
    Map<String, dynamic> params,
    md.DataObject? table,
    double labelSize,
    Color textColor,
    Color axisColor,
  ) {
    if (table is! md.TableData) {
      _paintEmpty(canvas, size);
      return;
    }
    final cols = numericCols(table).take(8).toList();
    if (cols.isEmpty) {
      _paintEmpty(canvas, size);
      return;
    }
    double yMin = double.infinity, yMax = -double.infinity;
    final groups = <({String name, List<double> sorted})>[];
    for (final c in cols) {
      final vals = c.values.map(md.toNum).whereType<double>().toList()..sort();
      if (vals.length < 2) continue;
      if (vals.first < yMin) yMin = vals.first;
      if (vals.last > yMax) yMax = vals.last;
      groups.add((name: c.name, sorted: vals));
    }
    if (groups.isEmpty) {
      _paintEmpty(canvas, size);
      return;
    }
    if (!yMin.isFinite) yMin = 0;
    if (!yMax.isFinite) yMax = 1;
    final span = yMax - yMin;
    final yPad = span == 0 ? 0.5 : span * 0.05;
    final plot = _plot(size, 45, 30, 20, 60);
    _drawValueAxis(
      canvas,
      plot,
      vertical: true,
      axis: _ValueAxis(yMin - yPad, yMax + yPad, 6),
      axisColors: [axisColor],
      labelSize: labelSize,
      textColor: textColor,
    );
    _drawCatAxis(
      canvas,
      plot,
      vertical: false,
      cats: groups.map((g) => g.name).toList(),
      color: axisColor,
      labelSize: labelSize,
      textColor: textColor,
      rotateDeg: 30,
    );
    final n = groups.length;
    final bandW = plot.width / n * 0.3;
    for (var gi = 0; gi < n; gi++) {
      final g = groups[gi];
      final sorted = g.sorted;
      final min = sorted.first;
      final max = sorted.last;
      final n2 = sorted.length;
      final iqr = percentile(sorted, 0.75) - percentile(sorted, 0.25);
      var sigma = math.min(iqr / 1.349, (max - min) / 2);
      if (sigma <= 0) sigma = max - min == 0 ? 1.0 : (max - min);
      final bw = math.max(1e-6, 1.06 * sigma * math.pow(n2, -0.2).toDouble());
      const samples = 40;
      final xs = <double>[];
      final dens = <double>[];
      var maxD = 0.0;
      for (var i = 0; i <= samples; i++) {
        final v = min + (max - min) * i / samples;
        var s = 0.0;
        for (final x in sorted) {
          s += math.exp(-(v - x) * (v - x) / (2 * bw * bw));
        }
        final d = s / (n2 * bw * math.sqrt(2 * math.pi));
        xs.add(v);
        dens.add(d);
        if (d > maxD) maxD = d;
      }
      final cx = plot.left + (gi + 0.5) / n * plot.width;
      double yv(double v) =>
          _mapV(v, yMin - yPad, yMax + yPad, plot.bottom, plot.top);
      final path = Path();
      for (var i = 0; i <= samples; i++) {
        final x = cx - (dens[i] / maxD) * bandW;
        final y = yv(xs[i]);
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      for (var i = samples; i >= 0; i--) {
        path.lineTo(cx + (dens[i] / maxD) * bandW, yv(xs[i]));
      }
      path.close();
      canvas.drawPath(
        path,
        Paint()..color = const Color(0xFF3B82F6).withValues(alpha: 0.6),
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xFF1D4ED8)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
      final med = percentile(sorted, 0.5);
      canvas.drawLine(
        Offset(cx - bandW * 0.85, yv(med)),
        Offset(cx + bandW * 0.85, yv(med)),
        Paint()
          ..color = Colors.white
          ..strokeWidth = 1.5,
      );
    }
  }

  void _paintSankey(
    Canvas canvas,
    Size size,
    Map<String, dynamic> params,
    md.DataObject? table,
    Color textColor,
  ) {
    if (table is! md.TableData) {
      _paintEmpty(canvas, size);
      return;
    }
    final bl = buildLinks(
      table,
      '${params['sourceCol'] ?? ''}',
      '${params['targetCol'] ?? ''}',
      '${params['valueCol'] ?? ''}',
    );
    if (bl.links.isEmpty || bl.names.isEmpty) {
      _paintEmpty(canvas, size);
      return;
    }
    final plot = Rect.fromLTRB(20, 30, size.width - 70, size.height - 30);
    final sources = <String>{};
    final targets = <String>{};
    for (final l in bl.links) {
      sources.add(l.source);
      targets.add(l.target);
    }
    double flowOf(String name, {required bool asSource}) {
      var s = 0.0;
      for (final l in bl.links) {
        if (asSource && l.source == name) s += l.value;
        if (!asSource && l.target == name) s += l.value;
      }
      return s;
    }

    final left = sources.toList();
    final right = targets.toList();
    final lTotal = left.fold<double>(
      0,
      (a, n) => a + flowOf(n, asSource: true),
    );
    final rTotal = right.fold<double>(
      0,
      (a, n) => a + flowOf(n, asSource: false),
    );
    final maxFlow = math.max(lTotal, math.max(rTotal, 1e-9));
    final colW = plot.width * 0.08;
    final laneW = plot.width - colW;

    final pos = <String, double>{};
    var y = plot.top + 10;
    for (final name in left) {
      final h = plot.height * 0.7 * flowOf(name, asSource: true) / maxFlow + 4;
      pos[name] = y;
      y += h + 8;
    }
    y = plot.top + 10;
    for (final name in right) {
      final h = plot.height * 0.7 * flowOf(name, asSource: false) / maxFlow + 4;
      pos[name] = y;
      y += h + 8;
    }

    final barFill = Paint()
      ..color = const Color(0xFF3B82F6).withValues(alpha: 0.75);
    final linkPaint = Paint()
      ..color = const Color(0xFF93C5FD).withValues(alpha: 0.45);
    for (final l in bl.links) {
      final ls = pos[l.source];
      final lt = pos[l.target];
      if (ls == null || lt == null) continue;
      final hs = plot.height * 0.7 * l.value / maxFlow + 4;
      final ht = plot.height * 0.7 * l.value / maxFlow + 4;
      final x0 = plot.left;
      final x1 = plot.left + laneW;
      final path = Path()
        ..moveTo(x0, ls)
        ..cubicTo(x0 + laneW / 2, ls, x1 - laneW / 2, lt, x1, lt)
        ..lineTo(x1, lt + ht)
        ..cubicTo(x1 - laneW / 2, lt + ht, x0 + laneW / 2, ls + hs, x0, ls + hs)
        ..close();
      canvas.drawPath(path, linkPaint);
      canvas.drawRect(Rect.fromLTWH(x0 - colW, ls, colW, hs), barFill);
      canvas.drawRect(Rect.fromLTWH(x1, lt, colW, ht), barFill);
      _drawText(
        canvas,
        l.source,
        Offset(x0 - colW - 4, ls + hs / 2),
        color: textColor,
        size: 9,
        align: TextAlign.right,
      );
      _drawText(
        canvas,
        l.target,
        Offset(x1 + colW + 4, lt + ht / 2),
        color: textColor,
        size: 9,
        align: TextAlign.left,
      );
    }
  }

  void _paintGraph(
    Canvas canvas,
    Size size,
    Map<String, dynamic> params,
    md.DataObject? table,
    Color textColor,
  ) {
    if (table is! md.TableData) {
      _paintEmpty(canvas, size);
      return;
    }
    final bl = buildLinks(
      table,
      '${params['sourceCol'] ?? ''}',
      '${params['targetCol'] ?? ''}',
      '${params['valueCol'] ?? ''}',
    );
    if (bl.links.isEmpty || bl.names.isEmpty) {
      _paintEmpty(canvas, size);
      return;
    }
    final plot = Rect.fromLTRB(20, 30, size.width - 20, size.height - 20);
    final centers = <String, Offset>{};
    final n = bl.names.length;
    for (var i = 0; i < n; i++) {
      final ang = 2 * math.pi * i / n;
      centers[bl.names[i]] = Offset(
        plot.center.dx + math.cos(ang) * plot.width * 0.35,
        plot.center.dy + math.sin(ang) * plot.height * 0.35,
      );
    }
    final maxV = bl.links.map((l) => l.value).fold<double>(1.0, math.max);
    for (var iter = 0; iter < 180; iter++) {
      final forces = <String, Offset>{};
      for (final name in bl.names) {
        forces[name] = Offset.zero;
      }
      for (var i = 0; i < bl.names.length; i++) {
        for (var j = i + 1; j < bl.names.length; j++) {
          final a = centers[bl.names[i]]!;
          final b = centers[bl.names[j]]!;
          var d = (b - a).distance;
          if (d < 1) d = 1;
          final f = 9000 / (d * d);
          final dir = (b - a) / d;
          forces[bl.names[i]] = forces[bl.names[i]]! - dir * f;
          forces[bl.names[j]] = forces[bl.names[j]]! + dir * f;
        }
      }
      for (final l in bl.links) {
        final a = centers[l.source];
        final b = centers[l.target];
        if (a == null || b == null) continue;
        var d = (b - a).distance;
        if (d < 1) d = 1;
        final k = 0.05 * (1 + (l.value / maxV) * 2);
        final dir = (b - a) / d;
        final f = dir * k * (d - 90);
        forces[l.source] = forces[l.source]! + f;
        forces[l.target] = forces[l.target]! - f;
      }
      for (final name in bl.names) {
        var p = centers[name]! + forces[name]! * 0.08;
        p = p + (plot.center - p) * 0.01;
        p = Offset(
          p.dx.clamp(plot.left + 20, plot.right - 20),
          p.dy.clamp(plot.top + 20, plot.bottom - 20),
        );
        centers[name] = p;
      }
    }
    final linkPaint = Paint()
      ..color = const Color(0xFF93C5FD).withValues(alpha: 0.55);
    for (final l in bl.links) {
      final a = centers[l.source];
      final b = centers[l.target];
      if (a == null || b == null) continue;
      linkPaint.strokeWidth = math.max(1.0, (l.value / maxV) * 4);
      canvas.drawLine(a, b, linkPaint);
    }
    final nodeFill = Paint()..color = const Color(0xFF3B82F6);
    final nodeBorder = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final name in bl.names) {
      final c = centers[name]!;
      canvas.drawCircle(c, 5, nodeFill);
      canvas.drawCircle(c, 5, nodeBorder);
      _drawText(
        canvas,
        name,
        c + const Offset(0, 12),
        color: textColor,
        size: 9,
      );
    }
  }

  void _paintEmpty(Canvas canvas, Size size) {
    _drawText(
      canvas,
      '无可用数据',
      Offset(size.width / 2, size.height / 2),
      color: const Color(0xFF94A3B8),
      size: 12,
    );
  }

  /// 图元叠加层:把接入的点/线/面/文本输入(in_pts/in_lines/in_faces/in_texts,
  /// 均可多路连接)像"原理化输出"一样叠加绘制进图中。点/线/面共用同一套坐标映射
  /// (fit 到绘图区),文本按九宫格定位;无图表数据时也可单独展示图元。
  void _paintOverlayPrimitives(
    Canvas canvas,
    Size size,
    Map<String, md.DataObject?> inputs,
    Map<String, List<md.DataObject>> multi,
  ) {
    final scatters = _gather(
      inputs,
      multi,
      'in_pts',
    ).whereType<md.ScatterData>().toList();
    final seriesList = _gather(
      inputs,
      multi,
      'in_lines',
    ).whereType<md.SeriesData>().toList();
    final meshes = _gather(
      inputs,
      multi,
      'in_faces',
    ).whereType<md.MeshData>().toList();
    final texts = _gather(
      inputs,
      multi,
      'in_texts',
    ).whereType<md.TextData>().toList();
    if (scatters.isEmpty &&
        seriesList.isEmpty &&
        meshes.isEmpty &&
        texts.isEmpty) {
      return;
    }
    // 点/线/面的全部 2D 坐标统一 fit 到绘图区(同一坐标系)。
    // 注意:文本不参与坐标收集——仅有文本输入时也必须绘制(coords 为空)。
    final coords = <Offset>[];
    for (final s in scatters) {
      for (final p in s.points) {
        coords.add(Offset(p.x, p.y));
      }
    }
    for (final l in seriesList) {
      for (final p in l.points) {
        coords.add(Offset(p.x, p.y));
      }
    }
    for (final m in meshes) {
      for (final v in m.vertices) {
        coords.add(Offset(v.x, v.y));
      }
    }
    var xmin = -1.0, xmax = 1.0, ymin = -1.0, ymax = 1.0;
    if (coords.isNotEmpty) {
      var lo = double.infinity, hi = -double.infinity;
      for (final c in coords) {
        lo = math.min(lo, c.dx);
        hi = math.max(hi, c.dx);
      }
      xmin = lo;
      xmax = hi;
      lo = double.infinity;
      hi = -double.infinity;
      for (final c in coords) {
        lo = math.min(lo, c.dy);
        hi = math.max(hi, c.dy);
      }
      ymin = lo;
      ymax = hi;
      // 单点/单值时防退化
      if (xmax - xmin < 1e-9) {
        xmin -= 1;
        xmax += 1;
      }
      if (ymax - ymin < 1e-9) {
        ymin -= 1;
        ymax += 1;
      }
    }
    final plot = _plot(size, 45, 30, 20, 40);
    double px(double x) => _mapV(x, xmin, xmax, plot.left, plot.right);
    double py(double y) => _mapV(y, ymin, ymax, plot.bottom, plot.top);

    // 面:三角形线框(XY 俯视投影,最底层)
    if (meshes.isNotEmpty) {
      final paint = Paint()
        ..color = const Color(0xFF2CA02C)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      for (final m in meshes) {
        for (final tri in m.faces) {
          if (tri.length < 3) continue;
          final path = Path();
          for (var i = 0; i < tri.length; i++) {
            final idx = tri[i];
            if (idx < 0 || idx >= m.vertices.length) continue;
            final v = m.vertices[idx];
            final o = Offset(px(v.x), py(v.y));
            if (i == 0) {
              path.moveTo(o.dx, o.dy);
            } else {
              path.lineTo(o.dx, o.dy);
            }
          }
          path.close();
          canvas.drawPath(path, paint);
        }
      }
    }

    // 线:逐条折线,支持逐段颜色/宽度与虚线样式
    for (final l in seriesList) {
      if (l.points.length < 2) continue;
      final baseColor = l.lineColor != null
          ? parseColor(l.lineColor!)
          : const Color(0xFFF59E0B);
      final baseWidth = l.lineWidth ?? 2.0;
      final dash = l.lineStyle == 'dashed' ? const <double>[5, 4] : null;
      for (var i = 0; i < l.points.length - 1; i++) {
        final a = Offset(px(l.points[i].x), py(l.points[i].y));
        final b = Offset(px(l.points[i + 1].x), py(l.points[i + 1].y));
        final color = l.colors != null && i < l.colors!.length
            ? parseColor(l.colors![i])
            : baseColor;
        final w = l.sizes != null && i < l.sizes!.length
            ? l.sizes![i]
            : baseWidth;
        final paint = Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = w
          ..strokeCap = StrokeCap.round;
        if (dash != null) {
          canvas.drawPath(_dashPath(a, b, dash), paint);
        } else {
          canvas.drawPath(
            Path()
              ..moveTo(a.dx, a.dy)
              ..lineTo(b.dx, b.dy),
            paint,
          );
        }
      }
    }

    // 点:按形状/大小/颜色绘制(最顶层数据)
    const defaultColor = Color(0xFF3B82F6);
    for (final s in scatters) {
      final baseColor = s.pointColor != null
          ? parseColor(s.pointColor!)
          : defaultColor;
      final baseShape = s.pointShape ?? 'circle';
      final baseR = ((s.pointSize ?? 4) * size.shortestSide / 480)
          .clamp(1.5, 5.0)
          .toDouble();
      for (var i = 0; i < s.points.length; i++) {
        final p = s.points[i];
        final color = s.colors != null && i < s.colors!.length
            ? parseColor(s.colors![i])
            : baseColor;
        final shape = s.shapes != null && i < s.shapes!.length
            ? s.shapes![i]
            : baseShape;
        final r = s.sizes != null && i < s.sizes!.length
            ? (s.sizes![i] * size.shortestSide / 480).clamp(1.5, 6.0).toDouble()
            : baseR;
        _drawPointShape(canvas, shape, Offset(px(p.x), py(p.y)), r, color);
      }
    }

    // 文本:按 halign/valign 九宫格定位在绘图区内(最顶层)。
    // 文本锚点取左上角并整体夹在绘图区内,避免大字号文本溢出绘图区,
    // 与坐标轴刻度数字重叠。
    for (final t in texts) {
      if (t.text.isEmpty) continue;
      final fs = (t.fontSize * 3).clamp(8.0, 42.0).toDouble();
      const pad = 10.0;
      final tp = TextPainter(
        text: TextSpan(
          text: t.text,
          style: TextStyle(
            fontSize: fs,
            color: parseColor(t.textColor.isEmpty ? '#333333' : t.textColor),
            fontFamily: t.fontFamily.isEmpty ? null : t.fontFamily,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: math.max(40, plot.width - 2 * pad));
      final w = tp.width;
      final h = tp.height;
      // 边缘对齐并向绘图区内侧展开:left/right/top/bottom 贴边,center 居中
      final tx = switch (t.halign) {
        'left' => plot.left + pad,
        'right' => plot.right - pad - w,
        _ => plot.center.dx - w / 2,
      };
      final ty = switch (t.valign) {
        'top' => plot.top + pad,
        'bottom' => plot.bottom - pad - h,
        _ => plot.center.dy - h / 2,
      };
      // 兜底:即便字号超出绘图区也不覆盖坐标轴数字
      final box = Rect.fromLTWH(
        tx.clamp(plot.left, math.max(plot.left, plot.right - w)).toDouble(),
        ty.clamp(plot.top, math.max(plot.top, plot.bottom - h)).toDouble(),
        w,
        h,
      );
      final bg = t.bgColor;
      if (bg != null && bg.isNotEmpty) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(box.inflate(3), const Radius.circular(3)),
          Paint()..color = parseColor(bg),
        );
      }
      tp.paint(canvas, box.topLeft);
    }
  }

  /// 收集某端口的全部数据(多路输入合并,单路包装为单元素列表)
  List<md.DataObject> _gather(
    Map<String, md.DataObject?> inputs,
    Map<String, List<md.DataObject>> multi,
    String key,
  ) {
    final m = multi[key];
    if (m != null && m.isNotEmpty) return m;
    final s = inputs[key];
    return s == null ? [] : [s];
  }

  /// 按形状绘制一个点(圆形/方形/菱形/三角形,以 r 为半径)
  void _drawPointShape(
    Canvas canvas,
    String shape,
    Offset c,
    double r,
    Color color,
  ) {
    final path = Path();
    switch (shape) {
      case 'square':
        path.addRect(Rect.fromLTWH(c.dx - r, c.dy - r, r * 2, r * 2));
        break;
      case 'diamond':
        path
          ..moveTo(c.dx, c.dy - r * 1.4)
          ..lineTo(c.dx + r * 1.4, c.dy)
          ..lineTo(c.dx, c.dy + r * 1.4)
          ..lineTo(c.dx - r * 1.4, c.dy)
          ..close();
        break;
      case 'triangle':
        path
          ..moveTo(c.dx, c.dy - r * 1.6)
          ..lineTo(c.dx + r * 1.4, c.dy + r * 1.1)
          ..lineTo(c.dx - r * 1.4, c.dy + r * 1.1)
          ..close();
        break;
      default:
        path.addOval(Rect.fromCircle(center: c, radius: r));
    }
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant ChartPainter old) =>
      old.data.chartType != data.chartType ||
      old.compact != compact ||
      old.bg != bg ||
      old.data.result != data.result ||
      old.data.params != data.params;
}

// ==================== 预览交互 + 导出 ====================

Future<void> savePngImage(ui.Image image, String suggestedName) async {
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  if (bytes == null) return;
  final loc = await getSaveLocation(
    suggestedName: suggestedName,
    acceptedTypeGroups: const [
      XTypeGroup(label: 'PNG 图片', extensions: ['png']),
    ],
  );
  if (loc == null) return;
  await File(loc.path).writeAsBytes(bytes.buffer.asUint8List());
}

/// 将 painter 渲染为指定像素尺寸的 PNG 并保存
Future<void> exportPainterPng(
  CustomPainter painter,
  int w,
  int h,
  String name,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  painter.paint(canvas, Size(w.toDouble(), h.toDouble()));
  final pic = recorder.endRecording();
  final img = await pic.toImage(w, h);
  await savePngImage(img, name);
}

/// 图表预览窗(节点内):滚轮缩放 / 拖拽平移 / 初始化 / 导出 PNG
class ChartViewer extends StatefulWidget {
  final String nodeId;
  const ChartViewer({super.key, required this.nodeId});

  @override
  State<ChartViewer> createState() => _ChartViewerState();
}

class _ChartViewerState extends State<ChartViewer> {
  double _zoom = 1;
  Offset _pan = Offset.zero;
  Offset? _dragStart;
  Offset? _dragPan;

  String get _chartType {
    final node = GraphStore.instance.nodes
        .where((n) => n.id == widget.nodeId)
        .toList();
    if (node.isEmpty) return 'scatter';
    final configId = node.first.configId;
    if (configId.startsWith('viz_') && configId != 'viz_principled') {
      return configId.substring(4);
    }
    return '${node.first.params['chartType'] ?? 'scatter'}';
  }

  void _onWheel(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final local = e.localPosition;
    final factor = e.scrollDelta.dy < 0 ? 1.12 : 1 / 1.12;
    setState(() {
      final nz = math.min(4.0, math.max(0.5, _zoom * factor));
      final f = nz / _zoom;
      _zoom = nz;
      _pan = Offset(
        local.dx - (local.dx - _pan.dx) * f,
        local.dy - (local.dy - _pan.dy) * f,
      );
    });
  }

  void _reset() {
    setState(() {
      _zoom = 1;
      _pan = Offset.zero;
    });
  }

  Future<void> _export() async {
    final node = GraphStore.instance.nodes
        .where((n) => n.id == widget.nodeId)
        .toList();
    final params = node.isEmpty ? <String, dynamic>{} : node.first.params;
    final result = GraphStore.instance.results[widget.nodeId];
    final w = (md.toNum(params['canvasPxW']) ?? 1200).round().clamp(100, 12000);
    final h = (md.toNum(params['canvasPxH']) ?? 900).round().clamp(100, 12000);
    final painter = ChartPainter(
      data: ChartData(chartType: _chartType, params: params, result: result),
      compact: true,
    );
    await exportPainterPng(painter, w, h, 'chart.png');
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: GraphStore.instance,
      builder: (context, _) {
        final node = GraphStore.instance.nodes
            .where((n) => n.id == widget.nodeId)
            .toList();
        final result = GraphStore.instance.results[widget.nodeId];
        if (node.isEmpty) return const SizedBox.shrink();
        return Stack(
          children: [
            Positioned.fill(child: _buildChartArea(node.first.params, result)),
            Positioned(left: 8, bottom: 6, child: _buildControls()),
          ],
        );
      },
    );
  }

  /// 图表主体:滚轮缩放监听 + 拖拽平移 + 缩放变换 + 绘制
  Widget _buildChartArea(Map<String, dynamic> params, ExecResult? result) {
    return Listener(
      onPointerSignal: _onWheel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (d) {
          _dragStart = d.localPosition;
          _dragPan = _pan;
        },
        onPanUpdate: (d) {
          final s = _dragStart;
          if (s == null) return;
          setState(() {
            _pan = _dragPan! + (d.localPosition - s);
          });
        },
        onPanEnd: (_) => _dragStart = null,
        onPanCancel: () => _dragStart = null,
        child: ClipRect(
          child: Transform(
            transform: Matrix4.identity()
              ..translateByDouble(_pan.dx, _pan.dy, 0, 1)
              ..scaleByDouble(_zoom, _zoom, 1, 1),
            alignment: Alignment.topLeft,
            child: CustomPaint(
              size: Size.infinite,
              painter: ChartPainter(
                data: ChartData(
                  chartType: _chartType,
                  params: params,
                  result: result,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 左下角控制条:缩放百分比 + 初始化 + 导出 PNG
  Widget _buildControls() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${(_zoom * 100).round()}%',
          style: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8)),
        ),
        const SizedBox(width: 8),
        _miniBtn('初始化', _reset),
        const SizedBox(width: 6),
        _miniBtn('导出 PNG', _export),
      ],
    );
  }

  Widget _miniBtn(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xFF2563EB),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 10, color: Colors.white),
        ),
      ),
    );
  }
}

// ==================== 数据输出(表格预览) ====================

class DataOutputView extends StatelessWidget {
  final String nodeId;
  const DataOutputView({super.key, required this.nodeId});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: GraphStore.instance,
      builder: (context, _) {
        final node = GraphStore.instance.nodes
            .where((n) => n.id == nodeId)
            .toList();
        final result = GraphStore.instance.results[nodeId];
        if (node.isEmpty) return const SizedBox.shrink();
        final obj = result?.inputs['in0'];
        final table = obj is md.TableData ? obj : null;
        if (table == null) return _emptyHint('请连接表格数据');
        if (table.columns.isEmpty) return _emptyHint('表格为空');
        final params = node.first.params;
        final maxRows = math.max(1, (md.toNum(params['maxRows']) ?? 8).round());
        final total = table.columns.first.values.length;
        final rows = math.min(maxRows, total);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _buildTable(table, rows)),
            _buildFooter(total, table.columns.length, rows),
          ],
        );
      },
    );
  }

  Widget _emptyHint(String msg) {
    return Center(
      child: Text(
        msg,
        style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
      ),
    );
  }

  /// 表格主体:横向 + 纵向双层滚动
  Widget _buildTable(md.TableData table, int rows) {
    final headerStyle = const TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: Color(0xFF1E293B),
    );
    final cellStyle = const TextStyle(fontSize: 11, color: Color(0xFF334155));
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SingleChildScrollView(
        child: Table(
          border: TableBorder.all(color: const Color(0xFFE2E8F0), width: 0.5),
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          columnWidths: const {0: FixedColumnWidth(28)},
          children: [
            _buildHeaderRow(table.columns, headerStyle),
            for (var i = 0; i < rows; i++) _buildDataRow(table, i, cellStyle),
          ],
        ),
      ),
    );
  }

  TableRow _buildHeaderRow(List<md.Column> columns, TextStyle style) {
    return TableRow(
      decoration: const BoxDecoration(color: Color(0xFFF1F5F9)),
      children: [
        _cell('#', style),
        for (final c in columns) _cell(c.name, style),
      ],
    );
  }

  TableRow _buildDataRow(md.TableData table, int i, TextStyle style) {
    return TableRow(
      decoration: BoxDecoration(
        color: i.isEven ? Colors.white : const Color(0xFFF8FAFC),
      ),
      children: [
        _cell('${i + 1}', style, vPad: 3),
        for (final c in table.columns)
          _cell('${c.values[i] ?? ''}', style, vPad: 3),
      ],
    );
  }

  Widget _cell(String text, TextStyle style, {double vPad = 4}) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 6, vertical: vPad),
      child: Text(text, style: style),
    );
  }

  Widget _buildFooter(int total, int cols, int rows) {
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Text(
        '共 $total 行 · $cols 列(显示前 $rows 行)',
        style: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8)),
      ),
    );
  }
}
