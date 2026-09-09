import 'dart:math' as math;

import 'data.dart';

class LodResult<T> {
  final List<T> values;
  final int originalCount;
  final String method;
  const LodResult(this.values, this.originalCount, this.method);
  bool get reduced => values.length < originalCount;
  String get label => reduced
      ? 'LOD ${values.length}/$originalCount · $method'
      : '全量 $originalCount';
}

/// Preview-only line reduction. Each bucket keeps its first/last point and Y
/// extrema; non-finite separators are copied and reset bucketing, so gaps can
/// never be bridged. Computation and export continue to use the source list.
LodResult<Pt> linePreviewLod(List<Pt> source, int budget) {
  if (source.length <= budget || budget < 8) {
    return LodResult(List.of(source), source.length, 'full');
  }
  final out = <Pt>[];
  var start = 0;
  void reduceRun(int end) {
    final length = end - start;
    if (length <= 0) return;
    final bucket = math.max(1, (length / math.max(1, budget ~/ 4)).ceil());
    for (var i = start; i < end; i += bucket) {
      final hi = math.min(end, i + bucket);
      var loIndex = i, hiIndex = i;
      for (var j = i + 1; j < hi; j++) {
        if (source[j].y < source[loIndex].y) loIndex = j;
        if (source[j].y > source[hiIndex].y) hiIndex = j;
      }
      final indices = <int>{i, loIndex, hiIndex, hi - 1}.toList()..sort();
      for (final index in indices) {
        out.add(source[index]);
      }
    }
  }

  for (var i = 0; i <= source.length; i++) {
    if (i == source.length || !source[i].x.isFinite || !source[i].y.isFinite) {
      reduceRun(i);
      if (i < source.length) out.add(source[i]);
      start = i + 1;
    }
  }
  return LodResult(out, source.length, '端点+极值+缺口');
}

/// Preview-only scatter aggregation: one representative per pixel cell, plus
/// the first and last finite observations for stable visual feedback.
LodResult<Pt3> scatterPreviewLod(List<Pt3> source, double cellSize) {
  if (source.length < 2000 || cellSize <= 0) {
    return LodResult(List.of(source), source.length, 'full');
  }
  final cells = <(int, int), Pt3>{};
  Pt3? first, last;
  for (final point in source) {
    if (!point.x.isFinite || !point.y.isFinite) continue;
    first ??= point;
    last = point;
    cells.putIfAbsent((
      (point.x / cellSize).floor(),
      (point.y / cellSize).floor(),
    ), () => point);
  }
  final values = <Pt3>[
    ?first,
    ...cells.values,
    if (last != null && last != first) last,
  ];
  return LodResult(values, source.length, '像素网格');
}
