import 'dart:math' as math;
import 'dart:ui';

/// A data interval, without a unit-dependent epsilon. A constant series is
/// expanded only for display; distinct representable numbers remain distinct.
class PlotRange {
  final double min;
  final double max;

  const PlotRange(this.min, this.max);

  factory PlotRange.fit(Iterable<double> values) {
    var lo = double.infinity;
    var hi = -double.infinity;
    for (final value in values) {
      if (!value.isFinite) continue;
      lo = math.min(lo, value);
      hi = math.max(hi, value);
    }
    if (!lo.isFinite) return const PlotRange(-1, 1);
    if (lo != hi) return PlotRange(lo, hi);
    final pad = lo == 0 ? 1.0 : lo.abs() * 0.05;
    final lower = lo - pad;
    final upper = hi + pad;
    // At the ends of double's range only one side may be representable.
    return PlotRange(
      lower.isFinite && lower < lo ? lower : lo,
      upper.isFinite && upper > hi ? upper : hi,
    );
  }

  double fraction(double value) {
    if (min == max) return 0.5;
    final span = max - min;
    final delta = value - min;
    if (span.isFinite && delta.isFinite) return delta / span;
    // Avoid overflow for e.g. [-1e308, 1e308].
    return (value / 2 - min / 2) / (max / 2 - min / 2);
  }
}

/// One mapping shared by axes, table marks and all connected primitives.
class PlotViewport {
  final Rect plot;
  final PlotRange x;
  final PlotRange y;
  final bool yDown;

  const PlotViewport({
    required this.plot,
    required this.x,
    required this.y,
    this.yDown = false,
  });

  factory PlotViewport.fit(Rect plot, Iterable<Offset> points) {
    final finite = points.where((p) => p.dx.isFinite && p.dy.isFinite).toList();
    return PlotViewport(
      plot: plot,
      x: PlotRange.fit(finite.map((p) => p.dx)),
      y: PlotRange.fit(finite.map((p) => p.dy)),
    );
  }

  double px(double value) => plot.left + x.fraction(value) * plot.width;
  double py(double value) => yDown
      ? plot.top + y.fraction(value) * plot.height
      : plot.bottom - y.fraction(value) * plot.height;
  Offset map(Offset point) => Offset(px(point.dx), py(point.dy));
}

class PlotTicks {
  final List<double> ticks;
  final double step;
  const PlotTicks(this.ticks, this.step);
}

PlotTicks nicePlotTicks(double min, double max, int targetCount) {
  if (!min.isFinite || !max.isFinite || max <= min) {
    return PlotTicks(min.isFinite ? [min] : [], 1);
  }
  final target = math.max(1, targetCount);
  final raw = max / target - min / target;
  if (raw <= 0 || !raw.isFinite) return PlotTicks([min, max], max - min);
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  if (mag == 0 || !mag.isFinite) return PlotTicks([min, max], raw);
  final norm = raw / mag;
  final step =
      (norm < 1.5
          ? 1
          : norm < 3.5
          ? 2
          : norm < 7.5
          ? 5
          : 10) *
      mag;
  if (!step.isFinite || step == 0) return PlotTicks([min, max], raw);
  final first = (min / step).ceilToDouble() * step;
  final ticks = <double>[];
  // Counted loop: repeated floating-point addition can stop advancing when
  // step is below one ulp of a large offset. Never let that hang the renderer.
  for (var i = 0; i < target * 4 + 8; i++) {
    final value = first + i * step;
    if (!value.isFinite || value > max) break;
    if (value >= min && (ticks.isEmpty || value > ticks.last)) ticks.add(value);
  }
  if (ticks.length < 2) return PlotTicks([min, max], raw);
  return PlotTicks(ticks, step);
}

String formatPlotTick(double value, double step) {
  if (!value.isFinite) return '';
  if (value == 0) return '0';
  final magnitude = value.abs();
  if (magnitude < 1e-4 || magnitude >= 1e6) {
    final exponent = (math.log(magnitude) / math.ln10).floor();
    final stepExponent = step > 0 && step.isFinite
        ? (math.log(step) / math.ln10).floor()
        : exponent - 4;
    return value.toStringAsExponential(
      (exponent - stepExponent + 1).clamp(1, 16),
    );
  }
  final decimals = step >= 1 || step <= 0 || !step.isFinite
      ? 0
      : (-math.log(step) / math.ln10).ceil().clamp(0, 16);
  return value.toStringAsFixed(decimals);
}
