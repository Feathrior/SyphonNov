// 坐标系自适应范围:按接入的图元(散点/曲线/曲面/分布)收集数据范围,
// 再算出"合适"的坐标轴范围。
//
// 规则:
//   · 只自动适配真正有数据的轴(纯 2D 数据不会去改 Z 范围);
//   · 先留 [padRatio] 边距,点/线不会贴在轴框上;
//   · 「扩展」(extend)开启时再向外取整到 1/2/5×10ⁿ 的整齐刻度;
//   · 对数轴在 log10 空间里做同样的事,并只统计正值数据。
library;

import 'dart:math' as math;

import 'data.dart';

/// 数据范围收集器:记录每根轴上出现过的最小/最大值,以及最小正值(对数轴用)。
class AxisBounds {
  double? xMin, xMax, yMin, yMax, zMin, zMax;
  double? xPositive, yPositive, zPositive;

  bool get hasX => xMin != null && xMax != null;
  bool get hasY => yMin != null && yMax != null;
  bool get hasZ => zMin != null && zMax != null;

  void includeX(double value) {
    if (!value.isFinite) return;
    xMin = xMin == null ? value : math.min(xMin!, value);
    xMax = xMax == null ? value : math.max(xMax!, value);
    if (value > 0) {
      xPositive = xPositive == null ? value : math.min(xPositive!, value);
    }
  }

  void includeY(double value) {
    if (!value.isFinite) return;
    yMin = yMin == null ? value : math.min(yMin!, value);
    yMax = yMax == null ? value : math.max(yMax!, value);
    if (value > 0) {
      yPositive = yPositive == null ? value : math.min(yPositive!, value);
    }
  }

  void includeZ(double value) {
    if (!value.isFinite) return;
    zMin = zMin == null ? value : math.min(zMin!, value);
    zMax = zMax == null ? value : math.max(zMax!, value);
    if (value > 0) {
      zPositive = zPositive == null ? value : math.min(zPositive!, value);
    }
  }

  void include(double x, double y, [double? z]) {
    includeX(x);
    includeY(y);
    if (z != null) includeZ(z);
  }
}

/// 收集接入坐标系的全部图元范围;没有任何可用数值时返回 null。
AxisBounds? collectAxisBounds({
  List<ScatterData> points = const [],
  List<SeriesData> lines = const [],
  List<MeshData> meshes = const [],
  DistributionData? dist,
}) {
  final bounds = AxisBounds();

  for (final sc in points) {
    for (final p in sc.points) {
      bounds.include(p.x, p.y, p.z);
    }
  }

  for (final sr in lines) {
    final zs = sr.zValues;
    for (var i = 0; i < sr.points.length; i++) {
      final p = sr.points[i];
      bounds.include(
        p.x,
        p.y,
        zs != null && i < zs.length ? zs[i] : null,
      );
    }
    // 误差棒与误差带同样要落在轴框内,否则自适应后会被裁掉
    _includeErrors(
      bounds,
      sr.points,
      sr.xErrorMinus,
      sr.xErrorPlus,
      sr.yErrorMinus,
      sr.yErrorPlus,
    );
    final low = sr.bandLow, high = sr.bandHigh;
    if (low != null) {
      for (final v in low) {
        bounds.includeY(v);
      }
    }
    if (high != null) {
      for (final v in high) {
        bounds.includeY(v);
      }
    }
  }

  for (final mesh in meshes) {
    for (final v in mesh.vertices) {
      bounds.include(v.x, v.y, v.z);
    }
  }

  if (dist != null) {
    for (final bin in dist.bins) {
      bounds.includeX(bin.x0);
      bounds.includeX(bin.x1);
    }
  }

  return bounds.hasX || bounds.hasY || bounds.hasZ ? bounds : null;
}

void _includeErrors(
  AxisBounds bounds,
  List<Pt> pts,
  List<double>? xMinus,
  List<double>? xPlus,
  List<double>? yMinus,
  List<double>? yPlus,
) {
  if (xMinus == null && xPlus == null && yMinus == null && yPlus == null) {
    return;
  }
  for (var i = 0; i < pts.length; i++) {
    final p = pts[i];
    if (!p.x.isFinite || !p.y.isFinite) continue;
    final xm = xMinus != null && i < xMinus.length ? xMinus[i] : 0.0;
    final xp = xPlus != null && i < xPlus.length ? xPlus[i] : xm;
    final ym = yMinus != null && i < yMinus.length ? yMinus[i] : 0.0;
    final yp = yPlus != null && i < yPlus.length ? yPlus[i] : ym;
    if (xm.isFinite && xm > 0) bounds.includeX(p.x - xm);
    if (xp.isFinite && xp > 0) bounds.includeX(p.x + xp);
    if (ym.isFinite && ym > 0) bounds.includeY(p.y - ym);
    if (yp.isFinite && yp > 0) bounds.includeY(p.y + yp);
  }
}

/// 数据范围 → 自适应轴范围。
///
/// [extend] 为「扩展」:把上下界向外取整到整齐刻度(线性 1/2/5×10ⁿ,对数整十
/// 次幂),取整本身通常就带来了边距;关闭时改为按 [padRatio] 留白,不做取整。
/// [log] 用于对数轴:在 log10 空间处理;数据里有非正值时用 [minPositive] 作下界,
/// 完全没有正数数据时原样返回(由尺度校验给出明确报错)。
(double, double) fitAxisRange(
  double min,
  double max, {
  bool extend = true,
  double padRatio = 0.05,
  bool log = false,
  double? minPositive,
}) {
  if (!min.isFinite || !max.isFinite) return (min, max);
  var lo = math.min(min, max);
  final hi = math.max(min, max);

  if (log) {
    if (lo <= 0) {
      final positive = minPositive;
      if (positive == null || !positive.isFinite || positive <= 0 || hi <= 0) {
        return (min, max);
      }
      lo = positive;
    }
    final l0 = math.log(lo) / math.ln10;
    final l1 = math.log(hi) / math.ln10;
    final (a, b) = _fit(l0, l1, extend: extend, padRatio: padRatio);
    // 对数轴的刻度只在整十次幂上,范围也取整到整十次幂
    var start = extend ? a.floorToDouble() : a;
    var end = extend ? b.ceilToDouble() : b;
    if (!(end > start)) end = start + 1;
    return (_pow10(start), _pow10(end));
  }
  return _fit(lo, hi, extend: extend, padRatio: padRatio);
}

(double, double) _fit(
  double lo,
  double hi, {
  required bool extend,
  required double padRatio,
}) {
  final span = hi - lo;
  if (span <= 0) {
    // 单值(或全等值)数据:给出一个对称的小区间
    final pad = lo == 0 ? 1.0 : lo.abs() * 0.5;
    return (lo - pad, hi + pad);
  }
  if (!extend) {
    final pad = span * padRatio;
    return (lo - pad, hi + pad);
  }
  final step = _niceStep(span / 5);
  final start = _snap(lo, step, floor: true);
  final end = _snap(hi, step, floor: false);
  return end > start ? (start, end) : (start, start + step);
}

/// 1/2/5×10ⁿ 里最接近 [raw] 且不小于它的刻度
double _niceStep(double raw) {
  if (!raw.isFinite || raw <= 0) return 1;
  final exponent = (math.log(raw) / math.ln10).floor();
  final base = math.pow(10, exponent).toDouble();
  final fraction = raw / base;
  final nice = fraction <= 1
      ? 1.0
      : fraction <= 2
      ? 2.0
      : fraction <= 5
      ? 5.0
      : 10.0;
  return nice * base;
}

double _snap(double value, double step, {required bool floor}) {
  final units = floor ? (value / step).floor() : (value / step).ceil();
  final snapped = units * step;
  // 抹掉浮点乘法带来的尾巴(0.30000000000000004 → 0.3)
  return double.tryParse(snapped.toStringAsPrecision(12)) ?? snapped;
}

double _pow10(double exponent) =>
    double.tryParse(math.pow(10, exponent).toStringAsPrecision(12)) ??
    math.pow(10, exponent).toDouble();
