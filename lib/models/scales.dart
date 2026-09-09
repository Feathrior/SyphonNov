library;

import 'dart:math' as math;

enum ScaleKind { linear, log, log10, log2, symlog, time }

class ScaleTick {
  final double value;
  final String label;
  const ScaleTick(this.value, this.label);
}

/// 坐标尺度的唯一实现：预览、命中测试与导出均通过同一 transform/inverse。
class AxisScale {
  final ScaleKind kind;
  final double min;
  final double max;
  final double linearThreshold;
  late final double _tMin = _raw(min);
  late final double _tMax = _raw(max);

  AxisScale(this.kind, this.min, this.max, {this.linearThreshold = 1}) {
    if (!min.isFinite || !max.isFinite || min >= max) {
      throw ArgumentError('尺度范围必须是递增的有限区间');
    }
    if ((kind == ScaleKind.log ||
            kind == ScaleKind.log10 ||
            kind == ScaleKind.log2) &&
        min <= 0) {
      throw ArgumentError('对数尺度范围必须全部大于 0');
    }
    if (!linearThreshold.isFinite || linearThreshold <= 0) {
      throw ArgumentError('symlog 线性阈值必须是正有限数');
    }
  }

  factory AxisScale.named(
    String name,
    double min,
    double max, {
    double linearThreshold = 1,
  }) {
    final kind = ScaleKind.values.firstWhere(
      (value) => value.name == name,
      orElse: () => ScaleKind.linear,
    );
    return AxisScale(kind, min, max, linearThreshold: linearThreshold);
  }

  double _raw(double value) {
    switch (kind) {
      case ScaleKind.linear || ScaleKind.time:
        return value;
      case ScaleKind.log || ScaleKind.log10:
        return value > 0 ? math.log(value) / math.ln10 : double.nan;
      case ScaleKind.log2:
        return value > 0 ? math.log(value) / math.ln2 : double.nan;
      case ScaleKind.symlog:
        return value.sign * math.log(1 + value.abs() / linearThreshold);
    }
  }

  double _unraw(double value) {
    switch (kind) {
      case ScaleKind.linear || ScaleKind.time:
        return value;
      case ScaleKind.log || ScaleKind.log10:
        return math.pow(10, value).toDouble();
      case ScaleKind.log2:
        return math.pow(2, value).toDouble();
      case ScaleKind.symlog:
        return value.sign * linearThreshold * (math.exp(value.abs()) - 1);
    }
  }

  /// 映射到 [0,1]。对数尺度的非正数据返回 NaN，绘图层据此断线/跳点。
  double transform(double value) {
    final transformed = _raw(value);
    if (!transformed.isFinite) return double.nan;
    return (transformed - _tMin) / (_tMax - _tMin);
  }

  double inverse(double normalized) =>
      _unraw(_tMin + normalized * (_tMax - _tMin));

  List<ScaleTick> ticks([int target = 6]) {
    target = target.clamp(2, 12);
    if (kind == ScaleKind.log ||
        kind == ScaleKind.log10 ||
        kind == ScaleKind.log2) {
      final base = kind == ScaleKind.log2 ? 2.0 : 10.0;
      final lo = (_raw(min)).ceil(), hi = (_raw(max)).floor();
      final out = <ScaleTick>[];
      for (var power = lo; power <= hi; power++) {
        final value = math.pow(base, power).toDouble();
        out.add(ScaleTick(value, base == 2 ? '2^$power' : '10^$power'));
      }
      return out.isEmpty
          ? [ScaleTick(min, _format(min)), ScaleTick(max, _format(max))]
          : out;
    }
    final out = <ScaleTick>[];
    for (var i = 0; i < target; i++) {
      final value = inverse(i / (target - 1));
      out.add(
        ScaleTick(
          value,
          kind == ScaleKind.time ? _formatTime(value) : _format(value),
        ),
      );
    }
    return out;
  }

  static String _format(double value) {
    final magnitude = value == 0 ? 0 : math.log(value.abs()) / math.ln10;
    if (magnitude >= 5 || magnitude <= -4) {
      return value.toStringAsExponential(3);
    }
    return value.toStringAsPrecision(5).replaceFirst(RegExp(r'\.?0+$'), '');
  }

  static String _formatTime(double millis) {
    final date = DateTime.fromMillisecondsSinceEpoch(
      millis.round(),
      isUtc: true,
    );
    if (date.hour == 0 && date.minute == 0 && date.second == 0) {
      return '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    }
    return '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }
}
