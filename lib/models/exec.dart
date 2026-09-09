// 节点执行函数(由 React 版 nodes/exec.ts 移植)
library;

import 'dart:math' as math;

import 'csv.dart';
import 'data.dart';
import 'math.dart';
import 'sample_data.dart';
import 'scales.dart';

class _SegmentBox {
  final Pt a;
  final Pt b;
  final double minX, maxX, minY, maxY;
  _SegmentBox(this.a, this.b)
    : minX = math.min(a.x, b.x),
      maxX = math.max(a.x, b.x),
      minY = math.min(a.y, b.y),
      maxY = math.max(a.y, b.y);
  bool overlaps(double x0, double x1, double y0, double y1) =>
      maxX >= x0 && minX <= x1 && maxY >= y0 && minY <= y1;
}

class _SegmentBvh {
  final double minX, maxX, minY, maxY;
  final _SegmentBvh? left, right;
  final List<_SegmentBox> leaf;
  _SegmentBvh._(
    this.minX,
    this.maxX,
    this.minY,
    this.maxY,
    this.left,
    this.right,
    this.leaf,
  );

  factory _SegmentBvh.build(List<_SegmentBox> segments) {
    final minX = segments.map((s) => s.minX).reduce(math.min);
    final maxX = segments.map((s) => s.maxX).reduce(math.max);
    final minY = segments.map((s) => s.minY).reduce(math.min);
    final maxY = segments.map((s) => s.maxY).reduce(math.max);
    if (segments.length <= 8) {
      return _SegmentBvh._(minX, maxX, minY, maxY, null, null, segments);
    }
    final splitX = maxX - minX >= maxY - minY;
    segments.sort(
      (a, b) => (splitX ? a.minX + a.maxX : a.minY + a.maxY).compareTo(
        splitX ? b.minX + b.maxX : b.minY + b.maxY,
      ),
    );
    final mid = segments.length ~/ 2;
    return _SegmentBvh._(
      minX,
      maxX,
      minY,
      maxY,
      _SegmentBvh.build(segments.sublist(0, mid)),
      _SegmentBvh.build(segments.sublist(mid)),
      const [],
    );
  }

  void query(
    double x0,
    double x1,
    double y0,
    double y1,
    List<_SegmentBox> out,
  ) {
    if (maxX < x0 || minX > x1 || maxY < y0 || minY > y1) return;
    if (left == null) {
      for (final segment in leaf) {
        if (segment.overlaps(x0, x1, y0, y1)) out.add(segment);
      }
      return;
    }
    left!.query(x0, x1, y0, y1, out);
    right!.query(x0, x1, y0, y1, out);
  }
}

double num_(dynamic v, double d) {
  final n = v is num ? v.toDouble() : double.tryParse('$v');
  return (n != null && n.isFinite) ? n : d;
}

String str(dynamic v, [String d = '']) => (v == null || v == '') ? d : '$v';

/// 任意数据对象 → 曲线点列
List<Pt>? toSeries(DataObject? obj) {
  if (obj == null) return null;
  if (obj is SeriesData) return obj.points;
  if (obj is ScatterData) {
    return obj.points.map((p) => Pt(p.x, p.y)).toList();
  }
  return null;
}

/// 任意数据对象 → 表格列
List<Column>? toTable(DataObject? obj) {
  if (obj == null || obj is! TableData) return null;
  return obj.columns;
}

dynamic _cell(Column column, int row) =>
    row >= 0 && row < column.values.length ? column.values[row] : null;

bool _isMissing(dynamic value) =>
    value == null || (value is String && value.trim().isEmpty);

double _safeMean(List<double> values) {
  if (values.isEmpty) return 0;
  final scale = values.fold<double>(0, (m, v) => math.max(m, v.abs()));
  if (scale == 0) return 0;
  return values.fold<double>(0, (s, v) => s + v / scale) /
      values.length *
      scale;
}

List<double> _stableZScores(List<double> values) {
  if (values.isEmpty) return const [];
  final scale = values.fold<double>(0, (m, v) => math.max(m, v.abs()));
  if (scale == 0) return List<double>.filled(values.length, 0);
  final scaled = values.map((v) => v / scale).toList();
  var mean = 0.0;
  var m2 = 0.0;
  for (var i = 0; i < scaled.length; i++) {
    final delta = scaled[i] - mean;
    mean += delta / (i + 1);
    m2 += delta * (scaled[i] - mean);
  }
  final std = math.sqrt(m2 / scaled.length);
  if (std == 0) return List<double>.filled(values.length, 0);
  return scaled.map((v) => (v - mean) / std).toList();
}

List<double> _stableMinMax(List<double> values) {
  if (values.isEmpty) return const [];
  final mn = values.reduce(math.min);
  final mx = values.reduce(math.max);
  if (mn == mx) return List<double>.filled(values.length, 0);
  final scale = math.max(mn.abs(), mx.abs());
  final lo = mn / scale;
  final span = mx / scale - lo;
  return values.map((v) => (v / scale - lo) / span).toList();
}

List<Column> firstNumericCols(List<Column> columns, int count) {
  final out = <Column>[];
  for (final c in columns) {
    final allNum = c.values.every((v) => v == null || toNum(v) != null);
    if (allNum) {
      out.add(c);
      if (out.length >= count) break;
    }
  }
  return out;
}

/// 按列名或 1 起始索引解析列
List<Column> resolveColumns(List<Column> columns, String spec) {
  final wanted = spec
      .split(RegExp(r'[,，;；\s]+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  final out = <Column>[];
  for (final w in wanted) {
    final idx = int.tryParse(w);
    if (idx != null && idx >= 1 && idx <= columns.length) {
      out.add(columns[idx - 1].copy());
    } else {
      for (final c in columns) {
        if (c.name == w) {
          out.add(c.copy());
          break;
        }
      }
    }
  }
  return out;
}

/// 获取曲线/散点输入
List<Pt> makeSeries(ExecContext ctx, String inId) {
  final pts = toSeries(ctx.inputs[inId]);
  if (pts == null) throw Exception('输入 $inId 不是曲线/散点');
  return pts;
}

// ---------- 坐标系预设 ----------
class AxisPreset {
  final String colorX, colorY, colorZ;
  final double widthX, widthY, widthZ;
  final bool gridX, gridY, gridZ, border;

  /// 隐藏坐标系:完全不绘制坐标轴/网格/刻度/标签
  final bool hidden;
  const AxisPreset(
    this.colorX,
    this.colorY,
    this.colorZ,
    this.widthX,
    this.widthY,
    this.widthZ,
    this.gridX,
    this.gridY,
    this.gridZ,
    this.border, {
    this.hidden = false,
  });
}

const Map<String, AxisPreset> kAxisPresets = {
  'default': AxisPreset(
    '#333333',
    '#333333',
    '#333333',
    0.12,
    0.12,
    0.12,
    true,
    true,
    true,
    true,
  ),
  'math': AxisPreset(
    '#111111',
    '#111111',
    '#111111',
    0.08,
    0.08,
    0.08,
    true,
    true,
    true,
    true,
  ),
  'engineering': AxisPreset(
    '#1f77b4',
    '#2ca02c',
    '#d62728',
    0.16,
    0.16,
    0.16,
    true,
    true,
    true,
    true,
  ),
  'minimal': AxisPreset(
    '#666666',
    '#666666',
    '#666666',
    0.08,
    0.08,
    0.08,
    false,
    false,
    false,
    true,
  ),
  'borderless': AxisPreset(
    '#333333',
    '#333333',
    '#333333',
    0.12,
    0.12,
    0.12,
    true,
    true,
    true,
    false,
  ),
  'hidden': AxisPreset(
    '#00000000',
    '#00000000',
    '#00000000',
    0.01,
    0.01,
    0.01,
    false,
    false,
    false,
    false,
    hidden: true,
  ),
};

final Map<String, ExecFn> kExec = _buildExec();

Map<String, ExecFn> _buildExec() {
  return {
    'table_input': (ctx) {
      final mode = str(ctx.params['mode'], 'preset');
      if (mode == 'manual') {
        final text = str(ctx.params['dataText'], '');
        if (text.trim().isEmpty) throw Exception('未提供数据文本');
        final delimiter = str(ctx.params['delimiter'], 'csv') == 'tsv'
            ? '\t'
            : ',';
        final headerMode = HeaderMode.values.firstWhere(
          (mode) => mode.name == str(ctx.params['headerMode'], 'auto'),
          orElse: () => HeaderMode.auto,
        );
        return {
          'out0': TableData(parseDelimitedText(text, delimiter, headerMode)),
        };
      }
      return {
        'out0': TableData(
          presetTable(
            str(ctx.params['preset'], 'phys'),
            seed: num_(ctx.params['seed'], 0).round(),
          ),
        ),
      };
    },

    'axis_input': (ctx) {
      final p = ctx.params;
      final name = str(p['name'], '坐标系');
      final dim = str(p['dim'], '3d') == '2d' ? 2 : 3;
      final xLen = math.max(0.5, num_(p['xLen'], 16));
      final yLen = math.max(0.5, num_(p['yLen'], 10));
      final zLen = math.max(0.5, num_(p['zLen'], 8));
      final grid = p['grid'] != false;
      var xMin = num_(p['xStart'], 0);
      var xMax = num_(p['xEnd'], 10);
      var yMin = num_(p['yStart'], 0);
      var yMax = num_(p['yEnd'], 10);
      var zMin = num_(p['zStart'], -5);
      var zMax = num_(p['zEnd'], 5);
      if (xMax < xMin || yMax < yMin || zMax < zMin) {
        throw Exception('坐标轴终点不得小于起点');
      }
      if (xMax == xMin) xMax = xMin + math.max(1, xMin.abs()) * 1e-6;
      if (yMax == yMin) yMax = yMin + math.max(1, yMin.abs()) * 1e-6;
      if (zMax == zMin) zMax = zMin + math.max(1, zMin.abs()) * 1e-6;
      final axisOrigin = str(p['axisOrigin'], 'origin') == 'left'
          ? 'left'
          : 'origin';
      final labelX = str(p['labelX'], 'X').isEmpty ? 'X' : str(p['labelX']);
      final labelY = str(p['labelY'], 'Y').isEmpty ? 'Y' : str(p['labelY']);
      final labelZ = str(p['labelZ'], 'Z').isEmpty ? 'Z' : str(p['labelZ']);

      final base =
          kAxisPresets[str(p['axisPreset'], 'default')] ??
          kAxisPresets['default']!;
      final def = kAxisPresets['default']!;
      // 与"默认"预设不同即视为已自定义,覆盖预设
      dynamic pick(dynamic v, dynamic defVal, dynamic baseVal) {
        if (v != null && v != defVal) return v;
        return baseVal;
      }

      final showBorder =
          pick(p['showBorder'], def.border, base.border) != false;
      final colorX = '${pick(p['axisColorX'], def.colorX, base.colorX)}';
      final colorY = '${pick(p['axisColorY'], def.colorY, base.colorY)}';
      final colorZ = '${pick(p['axisColorZ'], def.colorZ, base.colorZ)}';
      final widthX = math.max(
        0.02,
        num_(pick(p['axisWidthX'], def.widthX, base.widthX), 0.12),
      );
      final widthY = math.max(
        0.02,
        num_(pick(p['axisWidthY'], def.widthY, base.widthY), 0.12),
      );
      final widthZ = math.max(
        0.02,
        num_(pick(p['axisWidthZ'], def.widthZ, base.widthZ), 0.12),
      );
      final gridX = pick(p['gridX'], def.gridX, base.gridX) != false;
      final gridY = pick(p['gridY'], def.gridY, base.gridY) != false;
      final gridZ = pick(p['gridZ'], def.gridZ, base.gridZ) != false;

      final fontSize = math.max(6.0, math.min(24.0, num_(p['fontSize'], 10)));
      final fontFamily = str(p['fontFamily'], 'sans-serif');
      final arrowX = p['arrowX'] != false;
      final arrowY = p['arrowY'] != false;
      // 隐藏坐标系预设:完全不绘制坐标轴/网格/刻度/标签
      final hidden = str(p['axisPreset'], 'default') == 'hidden';

      // 收集输入口的图元(点/线/面/分布/文本,均可多连):
      // 端口未接时 inputs 为空,multiInputs 也为空 → 空列表。
      List<T> collect<T>(String key) {
        final out = <T>[];
        final m = ctx.multiInputs[key];
        if (m != null) {
          for (final o in m) {
            if (o is T) out.add(o as T);
          }
        } else {
          final s = ctx.inputs[key];
          if (s is T) out.add(s as T);
        }
        return out;
      }

      final points = collect<ScatterData>('in0');
      final lines = collect<SeriesData>('in1');
      final meshes = collect<MeshData>('in2');
      final texts = collect<TextData>('in4');
      final distI = ctx.inputs['in3'];
      final dist = distI is DistributionData ? distI : null;

      final colorPreset = str(p['colorPreset'], 'paper');
      final bgColor = '${p['bgColor'] ?? '#ffffff'}';
      final xScale = str(p['xScale'], 'linear');
      final yScale = str(p['yScale'], 'linear');
      final zScale = str(p['zScale'], 'linear');
      final symlogThreshold = num_(p['symlogThreshold'], 1);
      // 构造即验证范围；对数轴的非正范围在执行阶段给出明确错误。
      AxisScale.named(xScale, xMin, xMax, linearThreshold: symlogThreshold);
      AxisScale.named(yScale, yMin, yMax, linearThreshold: symlogThreshold);
      AxisScale.named(zScale, zMin, zMax, linearThreshold: symlogThreshold);
      final exportPreset = str(p['exportPreset'], 'custom');
      var exportUnit = str(p['exportUnit'], 'px');
      var exportWidth = num_(p['exportWidth'], num_(p['canvasPxW'], 1920));
      var exportHeight = num_(p['exportHeight'], num_(p['canvasPxH'], 1200));
      switch (exportPreset) {
        case 'single':
          exportUnit = 'mm';
          exportWidth = 89;
          exportHeight = 60;
          break;
        case 'double':
          exportUnit = 'mm';
          exportWidth = 183;
          exportHeight = 110;
          break;
        case 'poster':
          exportUnit = 'mm';
          exportWidth = 420;
          exportHeight = 297;
          break;
        case 'slides':
          exportUnit = 'inch';
          exportWidth = 13.333;
          exportHeight = 7.5;
          break;
        default:
          break;
      }
      final exportDpi = num_(p['exportDpi'], 300).clamp(36, 2400).toDouble();
      double pixels(double value) => exportUnit == 'mm'
          ? value / 25.4 * exportDpi
          : exportUnit == 'inch'
          ? value * exportDpi
          : value;
      final canvasPxW = pixels(exportWidth).round().clamp(100, 12000);
      final canvasPxH = pixels(exportHeight).round().clamp(100, 12000);
      List<String> names(dynamic value) => '$value'
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(growable: false);

      return {
        'out0': AxesData(
          name: name,
          dim: dim,
          xLen: xLen,
          yLen: yLen,
          zLen: zLen,
          xMin: xMin,
          xMax: xMax,
          yMin: yMin,
          yMax: yMax,
          zMin: zMin,
          zMax: zMax,
          grid: grid,
          axisOrigin: axisOrigin,
          showBorder: showBorder,
          labelX: labelX,
          labelY: labelY,
          labelZ: labelZ,
          axisColors: AxisColors(x: colorX, y: colorY, z: colorZ),
          axisWidths: AxisWidths(x: widthX, y: widthY, z: widthZ),
          gridX: gridX,
          gridY: gridY,
          gridZ: gridZ,
          fontSize: fontSize,
          fontFamily: fontFamily,
          axisPreset: str(p['axisPreset'], 'default'),
          aspectMode: str(p['aspectMode'], 'free'),
          xScale: xScale,
          yScale: yScale,
          zScale: zScale,
          symlogThreshold: symlogThreshold,
          legendMode: str(p['legendMode'], 'auto'),
          legendPosition: str(p['legendPosition'], 'right'),
          legendGrouping: str(p['legendGrouping'], 'type'),
          legendOrder: names(p['legendOrder'] ?? ''),
          legendHidden: names(p['legendHidden'] ?? ''),
          arrows: AxisArrows(x: arrowX, y: arrowY),
          rotX: num_(p['rotX'], -20),
          rotY: num_(p['rotY'], 25),
          rotZ: num_(p['rotZ'], 0),
          points: points,
          lines: lines,
          meshes: meshes,
          dist: dist,
          texts: texts,
          hidden: hidden,
          colorPreset: colorPreset,
          bgColor: bgColor,
          canvasPxW: canvasPxW.toDouble(),
          canvasPxH: canvasPxH.toDouble(),
          exportUnit: exportUnit,
          exportPreset: exportPreset,
          fontExportStrategy: str(p['fontExportStrategy'], 'embed'),
          exportWidth: exportWidth,
          exportHeight: exportHeight,
          exportDpi: exportDpi,
        ),
      };
    },

    'text_input': (ctx) {
      final p = ctx.params;
      final bg = p['bgColor'];
      return {
        'out0': TextData(
          text: str(p['text'], '文本'),
          fontSize: math.max(0.2, num_(p['fontSize'], 3)),
          halign: str(p['halign'], 'center'),
          valign: str(p['valign'], 'middle'),
          bgColor: bg != null && '$bg'.isNotEmpty ? '$bg' : null,
          textColor: '${p['textColor'] ?? '#333333'}',
          fontFamily: str(p['fontFamily'], 'sans-serif'),
        ),
      };
    },

    'surface_input': (ctx) => {'out0': genSurface(ctx)},

    'scatter_input': (ctx) {
      final p = ctx.params;
      final name = str(p['name'], '点输入');
      final raw = p['points'];
      final list = raw is List ? raw : <dynamic>[];
      final points = <Pt3>[];
      final sizes = <double>[];
      final shapes = <String>[];
      final colors = <String>[];
      var hasSize = false, hasShape = false, hasColor = false;
      for (final item in list) {
        final rec = item is Map ? item : <String, dynamic>{};
        final x = toNum(rec['x']);
        final y = toNum(rec['y']);
        if (x == null || y == null) continue;
        points.add(Pt3(x, y));
        final size = toNum(rec['size']);
        final shape = str(rec['shape'], 'circle');
        final color = str(rec['color'], '#1f77b4');
        if (size != null && size != 4) hasSize = true;
        if (shape.isNotEmpty && shape != 'circle') hasShape = true;
        if (color.isNotEmpty && color != '#1f77b4') hasColor = true;
        sizes.add(math.max(0.5, num_(size, 4)));
        shapes.add(
          ['square', 'diamond', 'triangle'].contains(shape) ? shape : 'circle',
        );
        colors.add(color.isEmpty ? '#1f77b4' : color);
      }
      if (points.isEmpty) throw Exception('请添加点(至少一个有效点)');
      // 基础样式(点形状/大小/颜色):逐点未设置或未暴露时作为兜底
      final base = pointStyleFields(ctx, points.length);
      return {
        'out0': ScatterData(
          name: name,
          points: points,
          pointSize: base.size,
          pointColor: base.color,
          pointShape: base.shape,
          sizes: hasSize ? sizes : base.sizes,
          shapes: hasShape ? shapes : null,
          colors: hasColor ? colors : base.colors,
        ),
      };
    },

    /// 曲线输入:三种方式采样输出曲线(Desmos 级覆盖)。
    /// - function:函数 y=f(x) 直接采样;
    /// - implicit:隐式方程 F(x,y)=0,marching squares 轮廓追踪
    ///   (圆/椭圆/双曲线等全部隐式曲线,多分支以 NaN 断点分隔);
    /// - parametric:参数方程 x(t)/y(t) 均匀采样。
    'func_curve': (ctx) {
      final p = ctx.params;
      final name = str(p['name'], '曲线');
      final mode = str(p['mode'], 'function');
      final samples = math.max(2, num_(p['samples'], 200).round());

      List<Pt> points;
      if (mode == 'implicit') {
        final expr = str(p['expression'], 'x^2+y^2-25');
        final f = compileFormula(expr);
        if (f == null) throw Exception('表达式无效:$expr');
        final xMin = num_(p['xMin'], -5), xMax = num_(p['xMax'], 5);
        final yMin = num_(p['yMin'], -5), yMax = num_(p['yMax'], 5);
        if (xMax <= xMin) throw Exception('X 结束需大于 X 起始');
        if (yMax <= yMin) throw Exception('Y 结束需大于 Y 起始');
        points = _implicitCurve(f, xMin, xMax, yMin, yMax, samples);
        if (points.isEmpty) throw Exception('此范围内曲线无有效值');
      } else if (mode == 'parametric') {
        final fx = compileFormula(str(p['exprX'], '3*cos(t)'));
        final fy = compileFormula(str(p['exprY'], '2*sin(t)'));
        if (fx == null || fy == null) throw Exception('参数表达式无效');
        final tMin = num_(p['xMin'], 0), tMax = num_(p['xMax'], 2 * math.pi);
        if (tMax <= tMin) throw Exception('t 结束需大于 t 起始');
        points = [
          for (final t in linspace(tMin, tMax, samples))
            (() {
              final x = fx(t, 0);
              final y = fy(t, 0);
              return x.isFinite && y.isFinite
                  ? Pt(x, y)
                  : const Pt(double.nan, double.nan);
            })(),
        ];
        if (points.isEmpty) throw Exception('函数在此范围内无有效值');
      } else {
        final expr = str(p['expression'], 'sin(x)');
        final f = compileFormula(expr);
        if (f == null) throw Exception('表达式无效:$expr');
        final xMin = num_(p['xMin'], 0);
        final xMax = num_(p['xMax'], 10);
        if (xMax <= xMin) throw Exception('X 结束需大于 X 起始');
        points = [
          for (final x in linspace(xMin, xMax, samples))
            (() {
              final y = f(x, 0);
              return y.isFinite ? Pt(x, y) : const Pt(double.nan, double.nan);
            })(),
        ];
        if (points.isEmpty) throw Exception('函数在此范围内无有效值');
      }
      return {'out0': styledSeries(ctx, name, points)};
    },

    // ---------- 数据初步 ----------
    'clean': (ctx) {
      final cols = toTable(ctx.inputs['in0']);
      if (cols == null) throw Exception('缺少表格输入');
      final fillMode = str(ctx.params['fillMissing'], 'none');
      final dropMissing = ctx.params['dropMissing'] == true;
      final dedupe = ctx.params['dedupe'] == true;

      var columns = cols.map((c) => c.copy()).toList();

      if (fillMode != 'none') {
        columns = columns.map((col) {
          final vals = col.values;
          if (fillMode == 'zero') {
            return Column(
              name: col.name,
              values: vals.map((v) => v ?? 0).toList(),
            );
          }
          final nums = vals.map(toNum).toList();
          final present = nums.whereType<double>().toList();
          final mean = _safeMean(present);
          if (fillMode == 'mean') {
            return Column(
              name: col.name,
              values: vals.map((v) => v ?? mean).toList(),
            );
          }
          // 线性插值
          final out = List<dynamic>.of(vals);
          var prevIdx = -1;
          for (var i = 0; i < vals.length; i++) {
            if (vals[i] != null) {
              if (prevIdx >= 0 && i - prevIdx > 1) {
                final a = num_(vals[prevIdx], 0);
                final b = num_(vals[i], a);
                for (var k = prevIdx + 1; k < i; k++) {
                  out[k] = a + (b - a) * (k - prevIdx) / (i - prevIdx);
                }
              }
              prevIdx = i;
            }
          }
          for (var i = 0; i < out.length; i++) {
            if (out[i] == null) out[i] = mean;
          }
          return Column(name: col.name, values: out);
        }).toList();
      }

      final rowCount = columns.fold<int>(
        0,
        (count, column) => math.max(count, column.values.length),
      );
      final keep = <int>[];
      final seen = <String>{};
      for (var r = 0; r < rowCount; r++) {
        final rowMissing = columns.any((c) => _isMissing(_cell(c, r)));
        if (dropMissing && rowMissing) continue;
        final key = columns.map((c) => '${_cell(c, r)}').join('\u0001');
        if (dedupe && seen.contains(key)) continue;
        if (dedupe) seen.add(key);
        keep.add(r);
      }
      return {
        'out0': TableData(
          columns
              .map(
                (c) => Column(
                  name: c.name,
                  values: keep.map((r) => _cell(c, r)).toList(),
                ),
              )
              .toList(),
        ),
      };
    },

    'normalize': (ctx) {
      final cols = toTable(ctx.inputs['in0']);
      if (cols == null) throw Exception('缺少表格输入');
      final method = str(ctx.params['method'], 'minmax');
      final spec = str(ctx.params['columns'], '');
      List<String> targets;
      if (spec.isNotEmpty) {
        targets = resolveColumns(cols, spec).map((c) => c.name).toList();
      } else {
        targets = cols
            .where((c) => c.values.every((v) => toNum(v) != null))
            .map((c) => c.name)
            .toList();
      }
      final columns = cols.map((col) {
        if (!targets.contains(col.name)) return col.copy();
        final nums = col.values.map(toNum).toList();
        final present = nums.whereType<double>().toList();
        final normalized = method == 'zscore'
            ? _stableZScores(present)
            : _stableMinMax(present);
        var valueIndex = 0;
        return Column(
          name: col.name,
          values: col.values.map((v) {
            final number = toNum(v);
            return number == null ? null : normalized[valueIndex++];
          }).toList(),
        );
      }).toList();
      return {'out0': TableData(columns)};
    },

    'filter': (ctx) {
      final cols = toTable(ctx.inputs['in0']);
      if (cols == null) throw Exception('缺少表格输入');
      final colName = str(
        ctx.params['column'],
        cols.isEmpty ? '' : cols.first.name,
      );
      Column? col;
      for (final c in cols) {
        if (c.name == colName) {
          col = c;
          break;
        }
      }
      if (col == null) throw Exception('找不到列:$colName');
      final minS = str(ctx.params['min'], '');
      final maxS = str(ctx.params['max'], '');
      final mn = double.tryParse(minS);
      final mx = double.tryParse(maxS);
      final hasMin = mn != null;
      final hasMax = mx != null;
      final keep = <int>[];
      for (var r = 0; r < col.values.length; r++) {
        final n = toNum(col.values[r]);
        if (n == null) continue;
        if (hasMin && n < mn) continue;
        if (hasMax && n > mx) continue;
        keep.add(r);
      }
      return {
        'out0': TableData(
          cols
              .map(
                (c) => Column(
                  name: c.name,
                  values: keep.map((r) => c.values[r]).toList(),
                ),
              )
              .toList(),
        ),
      };
    },

    'sample': (ctx) {
      final cols = toTable(ctx.inputs['in0']);
      if (cols == null) throw Exception('缺少表格输入');
      final method = str(ctx.params['method'], 'first');
      final count = math.max(0, num_(ctx.params['count'], 20).round());
      final rowCount = cols.isEmpty ? 0 : cols.first.values.length;
      var keep = <int>[];
      if (method == 'every') {
        final step = math.max(1, num_(ctx.params['step'], 2).round());
        for (var r = 0; r < rowCount; r += step) {
          keep.add(r);
        }
      } else if (method == 'random') {
        final all = List<int>.generate(rowCount, (i) => i);
        final seed = num_(ctx.params['seed'], 0).round();
        all.shuffle(math.Random(seed));
        final n = math.min(count, rowCount);
        keep = all.sublist(0, n)..sort();
      } else {
        keep = List<int>.generate(math.min(count, rowCount), (i) => i);
      }
      return {
        'out0': TableData(
          cols
              .map(
                (c) => Column(
                  name: c.name,
                  values: keep.map((r) => c.values[r]).toList(),
                ),
              )
              .toList(),
        ),
      };
    },

    // ---------- 数据运算 ----------
    'derivative': (ctx) {
      final pts = makeSeries(ctx, 'in0');
      return {
        'out0': styledSeries(
          ctx,
          str(ctx.params['name'], '导数'),
          derivative(pts).map((p) => Pt(p.x, p.y)).toList(),
        ),
      };
    },

    'integral': (ctx) {
      final pts = makeSeries(ctx, 'in0');
      return {
        'out0': styledSeries(
          ctx,
          str(ctx.params['name'], '积分'),
          cumulativeIntegral(pts).map((p) => Pt(p.x, p.y)).toList(),
        ),
      };
    },

    'fit': (ctx) {
      final pts = makeSeries(ctx, 'in0');
      if (pts.length < 2) throw Exception('拟合至少需要两个有限数据点');
      final xs = pts.map((p) => p.x).toList();
      final ys = pts.map((p) => p.y).toList();
      final method = str(ctx.params['method'], 'linear');
      final name = str(ctx.params['name'], '拟合曲线');
      final xmin = xs.reduce(math.min);
      final xmax = xs.reduce(math.max);

      if (method == 'exponential') {
        final ef = exponentialFit(xs, ys);
        if (ef == null) throw Exception('指数拟合失败(需要 y>0)');
        final out = linspace(
          xmin,
          xmax,
          200,
        ).map((x) => Pt(x, ef.evaluate(x))).toList();
        return {
          'out0': styledSeries(ctx, name, out),
          'out1': TableData([
            Column(
              name: '参数',
              values: ['a', 'b', 'R²'].map((s) => s as dynamic).toList(),
            ),
            Column(
              name: '值',
              values: [
                ef.a,
                ef.b,
                ef.r2.isFinite ? ef.r2 : null,
              ].map((s) => s as dynamic).toList(),
            ),
          ]),
        };
      }
      final degree = num_(ctx.params['degree'], 1).round();
      final coeffs = polyFit(xs, ys, degree);
      final out = linspace(
        xmin,
        xmax,
        200,
      ).map((x) => Pt(x, polyEval(coeffs, x))).toList();
      return {
        'out0': styledSeries(ctx, name, out),
        'out1': TableData([
          Column(
            name: '参数',
            values: List.generate(coeffs.length, (i) => 'c$i' as dynamic),
          ),
          Column(name: '值', values: coeffs.map((c) => c as dynamic).toList()),
        ]),
      };
    },

    'linreg': (ctx) {
      final pts = makeSeries(ctx, 'in0');
      final xs = pts.map((p) => p.x).toList();
      final ys = pts.map((p) => p.y).toList();
      final fit = linearFit(xs, ys);
      final xmin = xs.reduce(math.min);
      final xmax = xs.reduce(math.max);
      final out = linspace(
        xmin,
        xmax,
        200,
      ).map((x) => Pt(x, fit.a + fit.b * x)).toList();
      return {
        'out0': SeriesData(name: '线性回归', points: out),
        'out1': TableData([
          Column(
            name: '参数',
            values: ['a(截距)', 'b(斜率)', 'R²'].map((s) => s as dynamic).toList(),
          ),
          Column(
            name: '值',
            values: [
              fit.a,
              fit.b,
              fit.r2.isFinite ? fit.r2 : null,
            ].map((s) => s as dynamic).toList(),
          ),
        ]),
      };
    },

    'smooth': (ctx) {
      final pts = makeSeries(ctx, 'in0');
      final window = math.max(1, num_(ctx.params['window'], 5).round());
      return {
        'out0': styledSeries(
          ctx,
          str(ctx.params['name'], '平滑曲线'),
          movingAverage(pts, window),
        ),
      };
    },

    'formula': (ctx) {
      final pts = makeSeries(ctx, 'in0');
      final expr = str(ctx.params['expression'], 'y');
      final f = compileFormula(expr);
      if (f == null) throw Exception('表达式无效:$expr');
      final points = pts.map((p) {
        final v = f(p.x, p.y);
        if (!v.isFinite) throw Exception('表达式计算失败');
        return Pt(p.x, v);
      }).toList();
      return {
        'out0': styledSeries(
          ctx,
          str(ctx.params['name'], 'f(x)=$expr'),
          points,
        ),
      };
    },

    /// 两条曲线的折线段相交检测,输出交点散点(点组)。
    /// 精度策略(有理化几何):先浮点粗筛(相对阈值,与坐标量级成比例),
    /// 命中/临界/近平行的线段对用 BigInt 有理数精确求解——
    /// 小数量值(如 1e-9 量级坐标)下浮点叉积误差会淹没平行/区间判定,
    /// 有理化后 t/u ∈ [0,1] 与交点坐标均为精确值,无精度损失。
    /// 平行/共线段忽略;交点按距离去重(相对坐标尺度);容量上限 10000 点。
    'curve_intersect': (ctx) {
      final a = ctx.inputs['in0'];
      final b = ctx.inputs['in1'];
      if (a is! SeriesData || b is! SeriesData) {
        throw Exception('需要两条曲线输入');
      }
      final list = <Pt3>[];
      final pa = a.points;
      final pb = b.points;
      // 坐标尺度:全部点最大绝对值(尺度自适应阈值,小数量值不被绝对 eps 吞掉);
      // 跳过 NaN 断点(隐式曲线多分支分隔),防 max 污染成 NaN
      var scale = 0.0;
      for (final p in pa) {
        if (!p.x.isFinite || !p.y.isFinite) continue;
        scale = math.max(scale, p.x.abs());
        scale = math.max(scale, p.y.abs());
      }
      for (final p in pb) {
        if (!p.x.isFinite || !p.y.isFinite) continue;
        scale = math.max(scale, p.x.abs());
        scale = math.max(scale, p.y.abs());
      }
      if (scale == 0) scale = 1;
      // 叉积量纲为坐标²:相对平行阈值与 scale² 成比例
      final eps = 1e-12 * scale * scale;
      final dedup = 1e-6 * scale;
      final bSegments = <_SegmentBox>[];
      for (var j = 0; j < pb.length - 1; j++) {
        final q1 = pb[j], q2 = pb[j + 1];
        if (q1.x.isFinite && q1.y.isFinite && q2.x.isFinite && q2.y.isFinite) {
          bSegments.add(_SegmentBox(q1, q2));
        }
      }
      final bvh = bSegments.isEmpty ? null : _SegmentBvh.build(bSegments);
      for (var i = 0; i < pa.length - 1; i++) {
        final p1 = pa[i];
        final p2 = pa[i + 1];
        // NaN 断点:该处不是真实线段,跳过
        if (!p1.x.isFinite || !p1.y.isFinite) continue;
        if (!p2.x.isFinite || !p2.y.isFinite) continue;
        final rdx = p2.x - p1.x;
        final rdy = p2.y - p1.y;
        final candidates = <_SegmentBox>[];
        bvh?.query(
          math.min(p1.x, p2.x),
          math.max(p1.x, p2.x),
          math.min(p1.y, p2.y),
          math.max(p1.y, p2.y),
          candidates,
        );
        for (final segment in candidates) {
          final q1 = segment.a;
          final q2 = segment.b;
          if (math.max(p1.x, p2.x) < math.min(q1.x, q2.x) ||
              math.max(q1.x, q2.x) < math.min(p1.x, p2.x) ||
              math.max(p1.y, p2.y) < math.min(q1.y, q2.y) ||
              math.max(q1.y, q2.y) < math.min(p1.y, p2.y)) {
            continue;
          }
          final sdx = q2.x - q1.x;
          final sdy = q2.y - q1.y;
          final d = rdx * sdy - rdy * sdx;
          final qpx = q1.x - p1.x;
          final qpy = q1.y - p1.y;
          double x, y;
          if (d.abs() <= eps) {
            // 近平行(浮点不可分辨):交给有理化精确判定——
            // 精确平行跳过;否则精确求交(此时浮点结果已不可信)
            final ex = exactSegIntersect(
              p1.x,
              p1.y,
              p2.x,
              p2.y,
              q1.x,
              q1.y,
              q2.x,
              q2.y,
            );
            if (ex == null) continue;
            x = ex.x;
            y = ex.y;
          } else {
            final t = (qpx * sdy - qpy * sdx) / d;
            final u = (qpx * rdy - qpy * rdx) / d;
            // 临界(贴边)判定浮点易误判:贴边时同样走精确路径
            final nearEdge =
                t > -1e-9 && t < 1e-9 ||
                t > 1 - 1e-9 && t < 1 + 1e-9 ||
                u > -1e-9 && u < 1e-9 ||
                u > 1 - 1e-9 && u < 1 + 1e-9;
            if (nearEdge) {
              final ex = exactSegIntersect(
                p1.x,
                p1.y,
                p2.x,
                p2.y,
                q1.x,
                q1.y,
                q2.x,
                q2.y,
              );
              if (ex == null) continue;
              x = ex.x;
              y = ex.y;
            } else if (t < 0 || t > 1 || u < 0 || u > 1) {
              continue;
            } else {
              x = p1.x + t * rdx;
              y = p1.y + t * rdy;
            }
          }
          // 按距离去重(相对坐标尺度);容量上限 10000 点
          if (list.length >= 10000) break;
          var dup = false;
          for (final e in list) {
            if ((e.x - x).abs() < dedup && (e.y - y).abs() < dedup) {
              dup = true;
              break;
            }
          }
          if (dup) continue;
          list.add(Pt3(x, y, 0));
        }
        if (list.length >= 10000) break;
      }
      return {'out0': styledScatter(ctx, str(ctx.params['name'], '交点'), list)};
    },

    /// 统一几何求交：保留成熟的二维曲线精确求交，并将含曲面的组合
    /// 转交给三维 BVH + 线段/三角形窄相检测。
    'geometry_intersect': (ctx) {
      final a = ctx.inputs['in0'], b = ctx.inputs['in1'];
      if (a == null || b == null) throw Exception('需要两个几何输入');
      if (a is MeshData || b is MeshData) {
        return _intersectWithSurface(ctx, a, b);
      }
      if (a is SeriesData && b is SeriesData) {
        final result = kExec['curve_intersect']!(ctx);
        return {
          ...result,
          'out1': SeriesData(
            name: str(ctx.params['curveName'], '交线'),
            points: const [],
          ),
        };
      }
      throw Exception('只支持曲线×曲线、曲线×曲面或曲面×曲面');
    },

    'stat_uncertainty': (ctx) {
      final table = ctx.inputs['in0'];
      if (table is! TableData) throw Exception('误差与区间节点需要表格输入');
      Column requiredColumn(String key, String fallback) {
        final name = str(ctx.params[key], fallback);
        return table.columns.firstWhere(
          (c) => c.name == name,
          orElse: () => throw Exception('表格中不存在 $name 列'),
        );
      }

      Column? optionalColumn(String key) {
        final name = str(ctx.params[key]);
        if (name.isEmpty) return null;
        return table.columns.where((c) => c.name == name).firstOrNull;
      }

      final xc = requiredColumn('xCol', 'x'), yc = requiredColumn('yCol', 'y');
      final xm = optionalColumn('xMinusCol'), xp = optionalColumn('xPlusCol');
      final ym = optionalColumn('yMinusCol'), yp = optionalColumn('yPlusCol');
      final band = str(ctx.params['representation'], 'error') == 'band';
      if (band && (ym == null || yp == null)) {
        throw Exception('区间带必须指定 Y 下界列和 Y 上界列');
      }
      final count = [
        xc,
        yc,
        ?xm,
        ?xp,
        ?ym,
        ?yp,
      ].map((c) => c.values.length).reduce(math.max);
      final points = <Pt>[],
          xMinus = <double>[],
          xPlus = <double>[],
          yMinus = <double>[],
          yPlus = <double>[];
      for (var i = 0; i < count; i++) {
        final x = toNum(_cell(xc, i)), y = toNum(_cell(yc, i));
        if (x == null || y == null || !x.isFinite || !y.isFinite) {
          points.add(const Pt(double.nan, double.nan));
          xMinus.add(double.nan);
          xPlus.add(double.nan);
          yMinus.add(double.nan);
          yPlus.add(double.nan);
          continue;
        }
        points.add(Pt(x, y));
        double value(Column? c, [double fallback = 0]) {
          final v = c == null ? null : toNum(_cell(c, i));
          return v != null && v.isFinite ? v : fallback;
        }

        final xv = value(xm), yv = value(ym);
        xMinus.add(xv);
        xPlus.add(value(xp, xv));
        yMinus.add(yv);
        yPlus.add(value(yp, yv));
      }
      if (!band &&
          [
            ...xMinus,
            ...xPlus,
            ...yMinus,
            ...yPlus,
          ].where((v) => v.isFinite).any((v) => v < 0)) {
        throw Exception('误差量不得为负数');
      }
      return {
        'out0': SeriesData(
          name: str(ctx.params['name'], '统计曲线'),
          points: points,
          lineWidth: num_(ctx.params['lineWidth'], 2),
          lineColor: str(ctx.params['lineColor'], '#2563eb'),
          lineStyle: str(ctx.params['lineStyle'], 'solid'),
          xErrorMinus: band ? null : xMinus,
          xErrorPlus: band ? null : xPlus,
          yErrorMinus: band ? null : yMinus,
          yErrorPlus: band ? null : yPlus,
          bandLow: band ? yMinus : null,
          bandHigh: band ? yPlus : null,
          uncertaintyKind: str(ctx.params['uncertaintyKind'], 'sd'),
          uncertaintySource: str(ctx.params['source']),
        ),
      };
    },

    // ---------- 数据转化 ----------
    'extract_columns': (ctx) {
      final cols = toTable(ctx.inputs['in0']);
      if (cols == null) throw Exception('缺少表格输入');
      final columns = resolveColumns(cols, str(ctx.params['columns'], '1,2'));
      if (columns.isEmpty) throw Exception('未匹配到列');
      return {'out0': TableData(columns)};
    },

    'extract_rows': (ctx) {
      final cols = toTable(ctx.inputs['in0']);
      if (cols == null) throw Exception('缺少表格输入');
      final start = math.max(0, num_(ctx.params['start'], 0).round());
      var end = num_(ctx.params['end'], 0).round();
      if (end < start) end = start;
      final step = math.max(1, num_(ctx.params['step'], 1).round());
      final rowCount = cols.isEmpty ? 0 : cols.first.values.length;
      final keep = <int>[];
      for (var r = start; r <= end && r < rowCount; r += step) {
        keep.add(r);
      }
      return {
        'out0': TableData(
          cols
              .map(
                (c) => Column(
                  name: c.name,
                  values: keep.map((r) => c.values[r]).toList(),
                ),
              )
              .toList(),
        ),
      };
    },

    'scatter_to_table': (ctx) {
      final obj = ctx.inputs['in0'];
      if (obj is! ScatterData) throw Exception('需要散点输入');
      final hasZ = obj.points.any((p) => p.z != null);
      final cols = <Column>[
        Column(name: 'x', values: obj.points.map((p) => p.x).toList()),
        Column(name: 'y', values: obj.points.map((p) => p.y).toList()),
      ];
      if (hasZ) {
        cols.add(
          Column(name: 'z', values: obj.points.map((p) => p.z).toList()),
        );
      }
      return {'out0': TableData(cols)};
    },

    'table_to_scatter': (ctx) {
      final cols = toTable(ctx.inputs['in0']);
      if (cols == null) throw Exception('缺少表格输入');
      final numeric = firstNumericCols(cols, 3);
      final xColName = str(ctx.params['xCol'], '');
      final yColName = str(ctx.params['yCol'], '');
      var xCol = _findCol(cols, xColName);
      xCol ??= numeric.isNotEmpty ? numeric[0] : null;
      var yCol = _findCol(cols, yColName);
      yCol ??= numeric.length > 1
          ? numeric[1]
          : (numeric.isNotEmpty ? numeric[0] : null);
      if (xCol == null || yCol == null) throw Exception('请选择 x/y 列');
      final zCol = ctx.params['zCol'] != null && '$ctx.params[zCol]'.isNotEmpty
          ? _findCol(cols, '$ctx.params[zCol]')
          : null;
      final sizeVals = exposedValues(ctx.inputs['exp_pointSize']);
      final colorVals = exposedValues(ctx.inputs['exp_pointColor']);
      final normSize = sizeVals != null ? norm01(sizeVals) : null;
      final normColor = colorVals != null ? norm01(colorVals) : null;
      final baseSize = math.max(1.0, num_(ctx.params['pointSize'], 4));
      final baseColor = str(ctx.params['pointColor'], '#1f77b4');
      final shape = str(ctx.params['pointShape'], 'circle');
      final points = <Pt3>[];
      final sizes = <double>[];
      final colors = <String>[];
      final n = math.max(xCol.values.length, yCol.values.length);
      for (var i = 0; i < n; i++) {
        final x = toNum(_cell(xCol, i));
        final y = toNum(_cell(yCol, i));
        if (x == null || y == null) continue;
        final z = zCol != null ? toNum(_cell(zCol, i)) : null;
        if (zCol != null && z == null) continue;
        points.add(Pt3(x, y, z));
        if (normSize != null) {
          sizes.add(
            baseSize * math.max(0.3, i < normSize.length ? normSize[i] : 0.5),
          );
        }
        if (normColor != null) {
          colors.add(valueColor(i < normColor.length ? normColor[i] : 0));
        }
      }
      return {
        'out0': ScatterData(
          name: str(ctx.params['name'], '散点'),
          points: points,
          pointSize: baseSize,
          pointColor: baseColor,
          pointShape: shape,
          sizes: sizes.isEmpty ? null : sizes,
          colors: colors.isEmpty ? null : colors,
        ),
      };
    },

    'table_to_series': (ctx) {
      final cols = toTable(ctx.inputs['in0']);
      if (cols == null) throw Exception('缺少表格输入');
      final numeric = firstNumericCols(cols, 2);
      final xColName = str(ctx.params['xCol'], '');
      final yColName = str(ctx.params['yCol'], '');
      var xCol = _findCol(cols, xColName);
      xCol ??= numeric.isNotEmpty ? numeric[0] : null;
      var yCol = _findCol(cols, yColName);
      yCol ??= numeric.length > 1
          ? numeric[1]
          : (numeric.isNotEmpty ? numeric[0] : null);
      if (xCol == null || yCol == null) throw Exception('请选择 x/y 列');
      final widthVals = exposedValues(ctx.inputs['exp_lineWidth']);
      final colorVals = exposedValues(ctx.inputs['exp_lineColor']);
      final normW = widthVals != null ? norm01(widthVals) : null;
      final normC = colorVals != null ? norm01(colorVals) : null;
      final baseW = math.max(0.5, num_(ctx.params['lineWidth'], 2));
      final baseC = str(ctx.params['lineColor'], '#ff7f0e');
      final style = str(ctx.params['lineStyle'], 'solid') == 'dashed'
          ? 'dashed'
          : 'solid';
      final points = <Pt>[];
      final sizes = <double>[];
      final colors = <String>[];
      final n = math.max(xCol.values.length, yCol.values.length);
      for (var i = 0; i < n; i++) {
        final x = toNum(_cell(xCol, i));
        final y = toNum(_cell(yCol, i));
        if (x == null || y == null) {
          points.add(const Pt(double.nan, double.nan));
          continue;
        }
        points.add(Pt(x, y));
        if (normW != null) {
          sizes.add(baseW * math.max(0.3, i < normW.length ? normW[i] : 0.5));
        }
        if (normC != null) {
          colors.add(valueColor(i < normC.length ? normC[i] : 0));
        }
      }
      return {
        'out0': SeriesData(
          name: str(ctx.params['name'], '曲线'),
          points: points,
          lineWidth: baseW,
          lineColor: baseC,
          lineStyle: style,
          sizes: sizes.isEmpty ? null : sizes,
          colors: colors.isEmpty ? null : colors,
        ),
      };
    },

    'series_to_scatter': (ctx) {
      final pts = makeSeries(ctx, 'in0');
      final sizeVals = exposedValues(ctx.inputs['exp_pointSize']);
      final colorVals = exposedValues(ctx.inputs['exp_pointColor']);
      final normSize = sizeVals != null ? norm01(sizeVals) : null;
      final normColor = colorVals != null ? norm01(colorVals) : null;
      final baseSize = math.max(1.0, num_(ctx.params['pointSize'], 4));
      final baseColor = str(ctx.params['pointColor'], '#1f77b4');
      final shape = str(ctx.params['pointShape'], 'circle');
      final sizes = <double>[];
      final colors = <String>[];
      for (var i = 0; i < pts.length; i++) {
        if (normSize != null) {
          sizes.add(
            baseSize * math.max(0.3, i < normSize.length ? normSize[i] : 0.5),
          );
        }
        if (normColor != null) {
          colors.add(valueColor(i < normColor.length ? normColor[i] : 0));
        }
      }
      return {
        'out0': ScatterData(
          name: str(ctx.params['name'], '散点'),
          points: pts.map((p) => Pt3(p.x, p.y)).toList(),
          pointSize: baseSize,
          pointColor: baseColor,
          pointShape: shape,
          sizes: sizes.isEmpty ? null : sizes,
          colors: colors.isEmpty ? null : colors,
        ),
      };
    },
  };
}

Column? _findCol(List<Column> cols, String name) {
  for (final c in cols) {
    if (c.name == name) return c;
  }
  return null;
}

// ---------- 输出样式:曲线 / 点(供所有弧线/散点生产者复用) ----------

/// 由节点参数 + 暴露输入解析曲线样式(线型/线宽/线色;接入数据列后逐段变化)
({
  double width,
  String color,
  String style,
  List<double>? sizes,
  List<String>? colors,
})
lineStyleFields(ExecContext ctx, int n) {
  final widthVals = exposedValues(ctx.inputs['exp_lineWidth']);
  final colorVals = exposedValues(ctx.inputs['exp_lineColor']);
  final normW = widthVals != null ? norm01(widthVals) : null;
  final normC = colorVals != null ? norm01(colorVals) : null;
  final baseW = math.max(0.5, num_(ctx.params['lineWidth'], 2));
  final baseC = str(ctx.params['lineColor'], '#ff7f0e');
  final style = str(ctx.params['lineStyle'], 'solid') == 'dashed'
      ? 'dashed'
      : 'solid';
  List<double>? sizes;
  if (normW != null) {
    sizes = [
      for (var i = 0; i < n; i++)
        baseW * math.max(0.3, normW.isEmpty ? 0.5 : normW[i % normW.length]),
    ];
  }
  List<String>? colors;
  if (normC != null) {
    colors = [
      for (var i = 0; i < n; i++)
        valueColor(normC.isEmpty ? 0 : normC[i % normC.length]),
    ];
  }
  return (
    width: baseW,
    color: baseC,
    style: style,
    sizes: sizes,
    colors: colors,
  );
}

/// 由节点参数 + 暴露输入解析点样式(形状/大小/颜色;接入数据列后逐点变化)
({
  double size,
  String color,
  String shape,
  List<double>? sizes,
  List<String>? colors,
})
pointStyleFields(ExecContext ctx, int n) {
  final sizeVals = exposedValues(ctx.inputs['exp_pointSize']);
  final colorVals = exposedValues(ctx.inputs['exp_pointColor']);
  final normSize = sizeVals != null ? norm01(sizeVals) : null;
  final normColor = colorVals != null ? norm01(colorVals) : null;
  final baseSize = math.max(1.0, num_(ctx.params['pointSize'], 4));
  final baseColor = str(ctx.params['pointColor'], '#1f77b4');
  final shape = str(ctx.params['pointShape'], 'circle');
  List<double>? sizes;
  if (normSize != null) {
    sizes = [
      for (var i = 0; i < n; i++)
        baseSize *
            math.max(
              0.3,
              normSize.isEmpty ? 0.5 : normSize[i % normSize.length],
            ),
    ];
  }
  List<String>? colors;
  if (normColor != null) {
    colors = [
      for (var i = 0; i < n; i++)
        valueColor(normColor.isEmpty ? 0 : normColor[i % normColor.length]),
    ];
  }
  return (
    size: baseSize,
    color: baseColor,
    shape: shape,
    sizes: sizes,
    colors: colors,
  );
}

/// 构造携带曲线样式的输出(所有输出弧线节点的统一个出口)
SeriesData styledSeries(ExecContext ctx, String name, List<Pt> points) {
  final s = lineStyleFields(ctx, points.length);
  return SeriesData(
    name: name,
    points: points,
    lineWidth: s.width,
    lineColor: s.color,
    lineStyle: s.style,
    sizes: s.sizes,
    colors: s.colors,
  );
}

/// 构造携带点样式的输出(所有输出散点节点的统一个出口)
ScatterData styledScatter(ExecContext ctx, String name, List<Pt3> points) {
  final s = pointStyleFields(ctx, points.length);
  return ScatterData(
    name: name,
    points: points,
    pointSize: s.size,
    pointColor: s.color,
    pointShape: s.shape,
    sizes: s.sizes,
    colors: s.colors,
  );
}

// ==================== 隐式曲线提取(marching squares) ====================

/// 端点键:相邻单元共享棱边时,两侧对同一棱边的插值点由相同角值/相同公式
/// 计算而来,是位级相同的 double → 精确相等可作链接口点。
/// (hashCode 冲突概率在数万点量级下可忽略,且匹配时仍会校验精确相等。)
String _ptKey(double x, double y) => '${x.hashCode}:${y.hashCode}';

/// 隐式方程 F(x,y)=0 的轮廓提取(marching squares):
/// 规则网格采样 F → 逐单元按四角符号查案例表 → 棱边线性插值得等值点 →
/// 把共端点的单元线段链接为连续折线(闭合圈自动首尾相接)。
/// 多条分支轮廓(如双曲线两支)之间以 NaN 断点分隔,渲染层按非有限值断线。
///
/// [samples] 为每轴网格数(2..400);返回空列表表示该范围无零等值线。
List<Pt> _implicitCurve(
  double Function(double x, double y) f,
  double xMin,
  double xMax,
  double yMin,
  double yMax,
  int samples,
) {
  final n = samples.clamp(2, 400);
  final dx = (xMax - xMin) / n;
  final dy = (yMax - yMin) / n;
  // 网格线坐标:预计算成数组,保证相邻单元共享棱边引用位级相同的坐标值,
  // 从而两侧插值点完全相等,轮廓链才能正确接续(浮点逐次累加会有 ulp 误差)
  final xs = [for (var i = 0; i <= n; i++) xMin + i * dx];
  final ys = [for (var j = 0; j <= n; j++) yMin + j * dy];
  // 网格值 g[j][i]:角点 (xs[i], ys[j]),j=0 为底边;NaN 角点所在单元直接跳过
  final g = List.generate(
    n + 1,
    (j) => List.generate(n + 1, (i) => f(xs[i], ys[j])),
  );

  // 生成全部等值线段(每段两个端点)
  final segs = <List<Pt>>[];
  // 四角:bl=(i,j) br=(i+1,j) tr=(i+1,j+1) tl=(i,j+1);棱边交点线性插值
  Pt edgePt(double v0, double v1, Pt p0, Pt p1) {
    final t = v0 / (v0 - v1); // v0、v1 异号(或一侧为 0),分母不为 0
    return Pt(p0.x + (p1.x - p0.x) * t, p0.y + (p1.y - p0.y) * t);
  }

  for (var j = 0; j < n; j++) {
    for (var i = 0; i < n; i++) {
      final bl = g[j][i], br = g[j][i + 1];
      final tr = g[j + 1][i + 1], tl = g[j + 1][i];
      if (!bl.isFinite || !br.isFinite || !tr.isFinite || !tl.isFinite) {
        continue;
      }
      final x0 = xs[i], x1 = xs[i + 1];
      final y0 = ys[j], y1 = ys[j + 1];
      var idx = 0;
      if (bl > 0) idx |= 1;
      if (br > 0) idx |= 2;
      if (tr > 0) idx |= 4;
      if (tl > 0) idx |= 8;
      if (idx == 0 || idx == 15) continue;
      // 惰性计算四条棱边的等值点(仅在案例表需要时插值)
      Pt? bottom, right, top, left;
      Pt bot() => bottom ??= edgePt(bl, br, Pt(x0, y0), Pt(x1, y0));
      Pt rgt() => right ??= edgePt(br, tr, Pt(x1, y0), Pt(x1, y1));
      Pt top_() => top ??= edgePt(tl, tr, Pt(x0, y1), Pt(x1, y1));
      Pt lft() => left ??= edgePt(bl, tl, Pt(x0, y0), Pt(x0, y1));
      void seg(Pt a, Pt b) {
        // 等值线恰好穿过网格角点时会产生 a==b 的退化段(零长度),
        // 它们自成伪链污染输出 → 直接丢弃;真实链路不受影响
        if (a.x == b.x && a.y == b.y) return;
        segs.add([a, b]);
      }

      switch (idx) {
        case 1:
        case 14:
          seg(lft(), bot());
        case 2:
        case 13:
          seg(bot(), rgt());
        case 3:
        case 12:
          seg(lft(), rgt());
        case 4:
        case 11:
          seg(rgt(), top_());
        case 6:
        case 9:
          seg(bot(), top_());
        case 7:
          seg(lft(), top_());
        case 8:
          seg(top_(), lft());
        case 5: // 马鞍点 1:正角 bl/tr —— 中心值决定连通方式
          if ((bl + br + tr + tl) / 4 > 0) {
            seg(bot(), rgt());
            seg(lft(), top_()); // 正区域连通,负角被隔离
          } else {
            seg(lft(), bot());
            seg(rgt(), top_()); // 正角被隔离
          }
        case 10: // 马鞍点 2:正角 br/tl
          if ((bl + br + tr + tl) / 4 > 0) {
            seg(lft(), bot());
            seg(rgt(), top_()); // 正区域连通,负角被隔离
          } else {
            seg(bot(), rgt());
            seg(lft(), top_()); // 正角被隔离
          }
      }
    }
  }
  if (segs.isEmpty) return const [];

  // 链接:端点 → 所在线段索引
  final byPoint = <String, List<int>>{};
  for (var i = 0; i < segs.length; i++) {
    for (final p in segs[i]) {
      final k = _ptKey(p.x, p.y);
      (byPoint[k] ??= []).add(i);
    }
  }
  final used = List<bool>.filled(segs.length, false);
  // 从链尾(或链头)延伸一段;返回 false 表示闭合或到端点
  // (Pt 未重载 ==,此处按坐标精确相等比较;共享棱边的插值点为位级相同 double)
  bool samePt(Pt a, Pt b) => a.x == b.x && a.y == b.y;
  bool extend(List<Pt> chain, bool fromEnd) {
    final tail = fromEnd ? chain.last : chain.first;
    for (final j in byPoint[_ptKey(tail.x, tail.y)] ?? const <int>[]) {
      if (used[j]) continue;
      final s = segs[j];
      Pt next;
      if (samePt(s[0], tail)) {
        next = s[1];
      } else if (samePt(s[1], tail)) {
        next = s[0];
      } else {
        continue; // 哈希碰撞:并非同一点,跳过
      }
      used[j] = true;
      if (fromEnd) {
        chain.add(next);
      } else {
        chain.insert(0, next);
      }
      return true;
    }
    return false;
  }

  final out = <Pt>[];
  for (var i = 0; i < segs.length; i++) {
    if (used[i]) continue;
    used[i] = true;
    final chain = <Pt>[segs[i][0], segs[i][1]];
    while (extend(chain, true)) {}
    while (extend(chain, false)) {}
    if (out.isNotEmpty) out.add(const Pt(double.nan, double.nan)); // 分支断点
    out.addAll(chain);
  }
  return out;
}

String _implicitFormula(String raw) {
  final parts = raw.split('=');
  if (parts.length == 1) return raw;
  if (parts.length != 2 || parts.any((part) => part.trim().isEmpty)) {
    throw Exception('隐式方程只能包含一个等号');
  }
  return '(${parts[0]})-(${parts[1]})';
}

class _TriangleBox {
  final Vec3 a, b, c;
  final double minX, maxX, minY, maxY, minZ, maxZ;
  _TriangleBox(this.a, this.b, this.c)
    : minX = math.min(a.x, math.min(b.x, c.x)),
      maxX = math.max(a.x, math.max(b.x, c.x)),
      minY = math.min(a.y, math.min(b.y, c.y)),
      maxY = math.max(a.y, math.max(b.y, c.y)),
      minZ = math.min(a.z, math.min(b.z, c.z)),
      maxZ = math.max(a.z, math.max(b.z, c.z));
  bool overlaps(_Box3 q) =>
      maxX >= q.minX &&
      minX <= q.maxX &&
      maxY >= q.minY &&
      minY <= q.maxY &&
      maxZ >= q.minZ &&
      minZ <= q.maxZ;
}

class _Box3 {
  final double minX, maxX, minY, maxY, minZ, maxZ;
  const _Box3(this.minX, this.maxX, this.minY, this.maxY, this.minZ, this.maxZ);
  factory _Box3.segment(Vec3 a, Vec3 b) => _Box3(
    math.min(a.x, b.x),
    math.max(a.x, b.x),
    math.min(a.y, b.y),
    math.max(a.y, b.y),
    math.min(a.z, b.z),
    math.max(a.z, b.z),
  );
  factory _Box3.triangle(_TriangleBox t) =>
      _Box3(t.minX, t.maxX, t.minY, t.maxY, t.minZ, t.maxZ);
  bool overlaps(_Box3 other) =>
      maxX >= other.minX &&
      minX <= other.maxX &&
      maxY >= other.minY &&
      minY <= other.maxY &&
      maxZ >= other.minZ &&
      minZ <= other.maxZ;
}

class _TriangleBvh {
  final _Box3 box;
  final _TriangleBvh? left, right;
  final List<_TriangleBox> leaf;
  _TriangleBvh._(this.box, this.left, this.right, this.leaf);
  factory _TriangleBvh.build(List<_TriangleBox> triangles) {
    final box = _Box3(
      triangles.map((t) => t.minX).reduce(math.min),
      triangles.map((t) => t.maxX).reduce(math.max),
      triangles.map((t) => t.minY).reduce(math.min),
      triangles.map((t) => t.maxY).reduce(math.max),
      triangles.map((t) => t.minZ).reduce(math.min),
      triangles.map((t) => t.maxZ).reduce(math.max),
    );
    if (triangles.length <= 8) {
      return _TriangleBvh._(box, null, null, triangles);
    }
    final spans = [
      box.maxX - box.minX,
      box.maxY - box.minY,
      box.maxZ - box.minZ,
    ];
    var axis = 0;
    if (spans[1] > spans[axis]) axis = 1;
    if (spans[2] > spans[axis]) axis = 2;
    double center(_TriangleBox t) => axis == 0
        ? t.minX + t.maxX
        : axis == 1
        ? t.minY + t.maxY
        : t.minZ + t.maxZ;
    triangles.sort((a, b) => center(a).compareTo(center(b)));
    final mid = triangles.length ~/ 2;
    return _TriangleBvh._(
      box,
      _TriangleBvh.build(triangles.sublist(0, mid)),
      _TriangleBvh.build(triangles.sublist(mid)),
      const [],
    );
  }
  void query(_Box3 q, List<_TriangleBox> out) {
    if (!box.overlaps(q)) return;
    if (left == null) {
      for (final t in leaf) {
        if (t.overlaps(q)) out.add(t);
      }
      return;
    }
    left!.query(q, out);
    right!.query(q, out);
  }
}

List<_TriangleBox> _meshTriangles(MeshData mesh) {
  final out = <_TriangleBox>[];
  for (final face in mesh.faces) {
    if (face.length < 3) continue;
    final a = mesh.vertices[face[0]];
    for (var i = 1; i < face.length - 1; i++) {
      final b = mesh.vertices[face[i]], c = mesh.vertices[face[i + 1]];
      if ([
        a,
        b,
        c,
      ].every((v) => v.x.isFinite && v.y.isFinite && v.z.isFinite)) {
        out.add(_TriangleBox(a, b, c));
      }
    }
  }
  return out;
}

Vec3? _segmentTriangle(Vec3 p0, Vec3 p1, _TriangleBox tri, double eps) {
  final d = p1 - p0, e1 = tri.b - tri.a, e2 = tri.c - tri.a;
  final h = _cross3(d, e2), det = e1.x * h.x + e1.y * h.y + e1.z * h.z;
  if (det.abs() <= eps) return null;
  final inv = 1 / det, s = p0 - tri.a;
  final u = inv * (s.x * h.x + s.y * h.y + s.z * h.z);
  if (u < -eps || u > 1 + eps) return null;
  final q = _cross3(s, e1);
  final v = inv * (d.x * q.x + d.y * q.y + d.z * q.z);
  if (v < -eps || u + v > 1 + eps) return null;
  final t = inv * (e2.x * q.x + e2.y * q.y + e2.z * q.z);
  return t < -eps || t > 1 + eps ? null : p0 + d.scale(t.clamp(0.0, 1.0));
}

Map<String, DataObject> _intersectWithSurface(
  ExecContext ctx,
  DataObject a,
  DataObject b,
) {
  final points = <Vec3>[], segments = <({Vec3 a, Vec3 b})>[];
  void addPoint(Vec3 q, double tol) {
    if (!points.any((p) => _length3(p - q) <= tol)) points.add(q);
    if (points.length > 10000) throw Exception('求交结果超过 10000 点的资源预算');
  }

  if (a is SeriesData && b is MeshData || a is MeshData && b is SeriesData) {
    final curve = a is SeriesData ? a : b as SeriesData;
    final mesh = a is MeshData ? a : b as MeshData;
    final triangles = _meshTriangles(mesh);
    if (triangles.isEmpty) throw Exception('曲面没有有效三角面');
    final bvh = _TriangleBvh.build(triangles);
    final scale = mesh.vertices.fold(
      1.0,
      (s, v) =>
          math.max(s, math.max(v.x.abs(), math.max(v.y.abs(), v.z.abs()))),
    );
    final tol = scale * 1e-8, eps = scale * scale * 1e-12;
    for (var i = 0; i < curve.points.length - 1; i++) {
      final p = curve.points[i], q = curve.points[i + 1];
      if (!p.x.isFinite || !p.y.isFinite || !q.x.isFinite || !q.y.isFinite) {
        continue;
      }
      final z0 = curve.zValues != null && i < curve.zValues!.length
          ? curve.zValues![i]
          : 0.0;
      final z1 = curve.zValues != null && i + 1 < curve.zValues!.length
          ? curve.zValues![i + 1]
          : 0.0;
      if (!z0.isFinite || !z1.isFinite) continue;
      final p3 = Vec3(p.x, p.y, z0),
          q3 = Vec3(q.x, q.y, z1),
          candidates = <_TriangleBox>[];
      bvh.query(_Box3.segment(p3, q3), candidates);
      for (final tri in candidates) {
        final hit = _segmentTriangle(p3, q3, tri, eps);
        if (hit != null) addPoint(hit, tol);
      }
    }
  } else if (a is MeshData && b is MeshData) {
    final ta = _meshTriangles(a), tb = _meshTriangles(b);
    if (ta.isEmpty || tb.isEmpty) throw Exception('曲面没有有效三角面');
    final bvh = _TriangleBvh.build(tb);
    final all = [...a.vertices, ...b.vertices];
    final scale = all.fold(
      1.0,
      (s, v) =>
          math.max(s, math.max(v.x.abs(), math.max(v.y.abs(), v.z.abs()))),
    );
    final tol = scale * 1e-7, eps = scale * scale * 1e-12;
    for (final x in ta) {
      final candidates = <_TriangleBox>[];
      bvh.query(_Box3.triangle(x), candidates);
      for (final y in candidates) {
        final hits = <Vec3>[];
        void hit(Vec3 p, Vec3 q, _TriangleBox tri) {
          final h = _segmentTriangle(p, q, tri, eps);
          if (h != null && !hits.any((v) => _length3(v - h) <= tol)) {
            hits.add(h);
          }
        }

        hit(x.a, x.b, y);
        hit(x.b, x.c, y);
        hit(x.c, x.a, y);
        hit(y.a, y.b, x);
        hit(y.b, y.c, x);
        hit(y.c, y.a, x);
        if (hits.length >= 2) {
          var p0 = hits[0], p1 = hits[1], best = _length3(p1 - p0);
          for (var i = 0; i < hits.length; i++) {
            for (var j = i + 1; j < hits.length; j++) {
              final d = _length3(hits[j] - hits[i]);
              if (d > best) {
                best = d;
                p0 = hits[i];
                p1 = hits[j];
              }
            }
          }
          if (best > tol) {
            segments.add((a: p0, b: p1));
            addPoint(p0, tol);
            addPoint(p1, tol);
          }
          if (segments.length > 10000) throw Exception('曲面求交超过 10000 条线段的资源预算');
        }
      }
    }
  } else {
    throw Exception('线面求交只接受 曲线+曲面 或 曲面+曲面');
  }
  final pts = [for (final p in points) Pt3(p.x, p.y, p.z)];
  final curvePts = <Pt>[], zs = <double>[];
  for (final s in segments) {
    if (curvePts.isNotEmpty) {
      curvePts.add(const Pt(double.nan, double.nan));
      zs.add(double.nan);
    }
    curvePts.add(Pt(s.a.x, s.a.y));
    zs.add(s.a.z);
    curvePts.add(Pt(s.b.x, s.b.y));
    zs.add(s.b.z);
  }
  return {
    'out0': styledScatter(ctx, str(ctx.params['name'], '交点'), pts),
    'out1': SeriesData(
      name: str(ctx.params['curveName'], '交线'),
      points: curvePts,
      zValues: zs,
      lineColor: str(ctx.params['lineColor'], '#ef4444'),
      lineWidth: num_(ctx.params['lineWidth'], 2),
    ),
  };
}

Vec3 _cross3(Vec3 a, Vec3 b) =>
    Vec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);

double _length3(Vec3 a) => math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z);

Vec3 _unit3(Vec3 a) {
  final length = _length3(a);
  return length > 0 && length.isFinite
      ? a.scale(1 / length)
      : const Vec3(0, 0, 1);
}

/// Marching tetrahedra 提取 F(x,y,z)=0。每个立方体采用同一体对角线的
/// 六四面体分解，避免相邻立方体在共享面上选择不同对角线而产生裂缝。
MeshData _genImplicitSurface(ExecContext ctx, int nx, int ny) {
  final p = ctx.params;
  final nz = (toNum(p['depthSamples']) ?? 25).round();
  final x0 = toNum(p['xMin']) ?? -3, x1 = toNum(p['xMax']) ?? 3;
  final y0 = toNum(p['yMin']) ?? -3, y1 = toNum(p['yMax']) ?? 3;
  final z0 = toNum(p['zMin']) ?? -3, z1 = toNum(p['zMax']) ?? 3;
  if (nx < 2 || nx > 100 || ny < 2 || ny > 100 || nz < 2 || nz > 100) {
    throw Exception('隐式曲面每个方向的采样数必须在 2 到 100 之间');
  }
  if (nx * ny * nz > 500000) throw Exception('隐式曲面超过 500000 个体采样点的资源预算');
  if (![x0, x1, y0, y1, z0, z1].every((v) => v.isFinite) ||
      x0 >= x1 ||
      y0 >= y1 ||
      z0 >= z1) {
    throw Exception('隐式曲面 X/Y/Z 范围必须是递增的有限区间');
  }
  final f = compileFormula3(
    _implicitFormula(str(p['implicitExpr'], 'x^2+y^2+z^2=1')),
  );
  if (f == null) throw Exception('无法解析隐式曲面方程');
  final dx = (x1 - x0) / (nx - 1), dy = (y1 - y0) / (ny - 1);
  final dz = (z1 - z0) / (nz - 1);
  int index(int i, int j, int k) => (i * ny + j) * nz + k;
  final field = List<double>.filled(nx * ny * nz, double.nan);
  for (var i = 0; i < nx; i++) {
    for (var j = 0; j < ny; j++) {
      for (var k = 0; k < nz; k++) {
        field[index(i, j, k)] = f(x0 + i * dx, y0 + j * dy, z0 + k * dz);
      }
    }
  }
  const tetrahedra = [
    [0, 5, 1, 6],
    [0, 1, 2, 6],
    [0, 2, 3, 6],
    [0, 3, 7, 6],
    [0, 7, 4, 6],
    [0, 4, 5, 6],
  ];
  const tetraEdges = [
    [0, 1],
    [0, 2],
    [0, 3],
    [1, 2],
    [1, 3],
    [2, 3],
  ];
  final vertices = <Vec3>[], faces = <List<int>>[];
  final normals = <Vec3>[];
  final values = <double>[];
  final mergeTol = math.max(dx, math.max(dy, dz)) * 1e-8;
  bool same(Vec3 a, Vec3 b) => _length3(a - b) <= mergeTol;
  Vec3 gradient(Vec3 q) {
    final hx = dx * 0.25, hy = dy * 0.25, hz = dz * 0.25;
    return _unit3(
      Vec3(
        f(q.x + hx, q.y, q.z) - f(q.x - hx, q.y, q.z),
        f(q.x, q.y + hy, q.z) - f(q.x, q.y - hy, q.z),
        f(q.x, q.y, q.z + hz) - f(q.x, q.y, q.z - hz),
      ),
    );
  }

  void emit(List<Vec3> polygon) {
    if (polygon.length < 3) return;
    final center = polygon.reduce((a, b) => a + b).scale(1 / polygon.length);
    final normal = gradient(center);
    var basis = normal.x.abs() < 0.8
        ? const Vec3(1, 0, 0)
        : const Vec3(0, 1, 0);
    basis = _unit3(_cross3(normal, basis));
    final second = _cross3(normal, basis);
    polygon.sort((a, b) {
      final da = a - center, db = b - center;
      return math
          .atan2(
            da.x * second.x + da.y * second.y + da.z * second.z,
            da.x * basis.x + da.y * basis.y + da.z * basis.z,
          )
          .compareTo(
            math.atan2(
              db.x * second.x + db.y * second.y + db.z * second.z,
              db.x * basis.x + db.y * basis.y + db.z * basis.z,
            ),
          );
    });
    for (var t = 1; t < polygon.length - 1; t++) {
      final tri = [polygon[0], polygon[t], polygon[t + 1]];
      if (_length3(_cross3(tri[1] - tri[0], tri[2] - tri[0])) <=
          mergeTol * mergeTol) {
        continue;
      }
      final start = vertices.length;
      for (final q in tri) {
        vertices.add(q);
        normals.add(gradient(q));
        values.add(q.z);
      }
      faces.add([start, start + 1, start + 2]);
      if (faces.length > 500000) throw Exception('隐式曲面超过 500000 个三角面的资源预算');
    }
  }

  for (var i = 0; i < nx - 1; i++) {
    for (var j = 0; j < ny - 1; j++) {
      for (var k = 0; k < nz - 1; k++) {
        final cube = <Vec3>[
          Vec3(x0 + i * dx, y0 + j * dy, z0 + k * dz),
          Vec3(x0 + (i + 1) * dx, y0 + j * dy, z0 + k * dz),
          Vec3(x0 + (i + 1) * dx, y0 + (j + 1) * dy, z0 + k * dz),
          Vec3(x0 + i * dx, y0 + (j + 1) * dy, z0 + k * dz),
          Vec3(x0 + i * dx, y0 + j * dy, z0 + (k + 1) * dz),
          Vec3(x0 + (i + 1) * dx, y0 + j * dy, z0 + (k + 1) * dz),
          Vec3(x0 + (i + 1) * dx, y0 + (j + 1) * dy, z0 + (k + 1) * dz),
          Vec3(x0 + i * dx, y0 + (j + 1) * dy, z0 + (k + 1) * dz),
        ];
        final fv = [
          field[index(i, j, k)],
          field[index(i + 1, j, k)],
          field[index(i + 1, j + 1, k)],
          field[index(i, j + 1, k)],
          field[index(i, j, k + 1)],
          field[index(i + 1, j, k + 1)],
          field[index(i + 1, j + 1, k + 1)],
          field[index(i, j + 1, k + 1)],
        ];
        if (fv.any((v) => !v.isFinite)) continue;
        for (final tet in tetrahedra) {
          final points = <Vec3>[];
          for (final edge in tetraEdges) {
            final ia = tet[edge[0]],
                ib = tet[edge[1]],
                va = fv[ia],
                vb = fv[ib];
            Vec3? q;
            if (va == 0) {
              q = cube[ia];
            } else if (vb == 0) {
              q = cube[ib];
            } else if ((va < 0) != (vb < 0)) {
              q = cube[ia] + (cube[ib] - cube[ia]).scale(va / (va - vb));
            }
            if (q != null && !points.any((old) => same(old, q!))) points.add(q);
          }
          emit(points);
        }
      }
    }
  }
  if (faces.isEmpty) throw Exception('当前范围内没有检测到隐式曲面，请调整方程或范围');
  final cb = ctx.inputs['in1'];
  final display = str(p['displayMode'], 'surface');
  return MeshData(
    name: str(p['name'], '隐式曲面'),
    vertices: vertices,
    faces: faces,
    normals: normals,
    vertexValues: str(p['valueMode'], 'z') == 'none' ? null : values,
    gradient: cb is ColorbarData
        ? cb.stops.map((s) => s.copy()).toList()
        : null,
    valueMin: cb is ColorbarData && cb.min != null
        ? cb.min
        : values.reduce(math.min),
    valueMax: cb is ColorbarData && cb.max != null
        ? cb.max
        : values.reduce(math.max),
    valueLabel: cb is ColorbarData ? cb.label ?? 'Z' : 'Z',
    previewFaceBudget: (toNum(p['previewFaceBudget']) ?? 6000).round().clamp(
      100,
      100000,
    ),
    sourceVertexCount: vertices.length,
    sourceFaceCount: faces.length,
    doubleSided: p['doubleSided'] != false,
    color: p['color'] is String && '${p['color']}'.isNotEmpty
        ? '${p['color']}'
        : null,
    opacity: num_(p['opacity'], .6).clamp(.05, 1),
    showEdge: display != 'surface',
    edgeColor: p['edgeColor'] is String && '${p['edgeColor']}'.isNotEmpty
        ? '${p['edgeColor']}'
        : null,
    wireframe: display == 'wireframe',
    fill: display != 'wireframe',
  );
}

/// 统一曲面生成。规则网格保留非有限采样点作为孔洞标记，但面不会跨孔洞。
MeshData genSurface(ExecContext ctx) {
  final p = ctx.params;
  final mode = str(p['mode'], 'explicit');
  var rows = (toNum(p['rows']) ?? 31).round();
  var columns = (toNum(p['columns']) ?? 31).round();
  if (rows < 2 || rows > 400 || columns < 2 || columns > 400) {
    throw Exception('曲面每个方向的采样数必须在 2 到 400 之间');
  }
  if (rows * columns > 160000) throw Exception('曲面超过 160000 个顶点的资源预算');

  var wrapRows = p['wrapRows'] == true;
  var wrapColumns = p['wrapColumns'] == true;
  var a0 = toNum(p['xMin']) ?? -3;
  var a1 = toNum(p['xMax']) ?? 3;
  var b0 = toNum(p['yMin']) ?? -3;
  var b1 = toNum(p['yMax']) ?? 3;
  if (mode == 'implicit') return _genImplicitSurface(ctx, rows, columns);
  Vec3 Function(double, double)? sample;
  List<double>? externalValues;
  var valueLabel = str(p['valueMode'], 'z') == 'radius' ? '距原点距离' : 'Z';

  if (mode == 'grid') {
    final table = ctx.inputs['in0'];
    if (table is! TableData) throw Exception('表格网格模式需要连接表格输入');
    if (table.columns.length < 3) throw Exception('表格曲面至少需要三列');
    if (str(p['gridLayout'], 'xyz') == 'matrix') {
      final yColumn = table.columns.first;
      final zColumns = table.columns.sublist(1);
      final validRows = <int>[];
      final ys = <double>[];
      for (var i = 0; i < yColumn.values.length; i++) {
        final y = toNum(yColumn.values[i]);
        if (y != null && y.isFinite) {
          validRows.add(i);
          ys.add(y);
        }
      }
      if (validRows.length < 2 || zColumns.length < 2) {
        throw Exception('二维矩阵至少需要 2×2 个坐标');
      }
      final parsedX = zColumns.map((c) => double.tryParse(c.name)).toList();
      final useNames = parsedX.every((x) => x != null && x.isFinite);
      final xs = [
        for (var i = 0; i < zColumns.length; i++)
          useNames ? parsedX[i]! : i.toDouble(),
      ];
      if (xs.toSet().length != xs.length || ys.toSet().length != ys.length) {
        throw Exception('二维矩阵坐标不得重复');
      }
      rows = xs.length;
      columns = ys.length;
      if (rows * columns > 160000) throw Exception('表格曲面超过 160000 个顶点的资源预算');
      a0 = 0;
      a1 = (rows - 1).toDouble();
      b0 = 0;
      b1 = (columns - 1).toDouble();
      sample = (a, b) {
        final xi = a.round(), yi = b.round();
        final z = toNum(_cell(zColumns[xi], validRows[yi]));
        return Vec3(xs[xi], ys[yi], z != null && z.isFinite ? z : double.nan);
      };
    } else {
      Column find(String key, String fallback) {
        final name = str(p[key], fallback);
        return table.columns.firstWhere(
          (c) => c.name == name,
          orElse: () => throw Exception('表格中不存在 $name 列'),
        );
      }

      final xc = find('xCol', 'x'),
          yc = find('yCol', 'y'),
          zc = find('zCol', 'z');
      final count = math.max(
        xc.values.length,
        math.max(yc.values.length, zc.values.length),
      );
      final valueName = str(p['valueCol']);
      final valueColumn = valueName.isEmpty
          ? null
          : table.columns.where((c) => c.name == valueName).firstOrNull;
      final records = <(double, double, double, double?)>[];
      for (var i = 0; i < count; i++) {
        final x = toNum(_cell(xc, i)),
            y = toNum(_cell(yc, i)),
            z = toNum(_cell(zc, i));
        if (x == null || y == null || !x.isFinite || !y.isFinite) {
          continue;
        }
        final scalar = valueColumn == null
            ? null
            : toNum(_cell(valueColumn, i));
        records.add((
          x,
          y,
          z != null && z.isFinite ? z : double.nan,
          scalar != null && scalar.isFinite ? scalar : double.nan,
        ));
      }
      if (records.isEmpty) throw Exception('表格没有有效的 X/Y/Z 数值行');
      final xs = records.map((r) => r.$1).toSet().toList()..sort();
      final ys = records.map((r) => r.$2).toSet().toList()..sort();
      rows = xs.length;
      columns = ys.length;
      if (rows < 2 || columns < 2) throw Exception('表格曲面至少需要 2×2 个不同的 X/Y 坐标');
      if (rows * columns > 160000) throw Exception('表格曲面超过 160000 个顶点的资源预算');
      final cells = <String, double>{};
      String key(double x, double y) =>
          '${x.toStringAsPrecision(17)}|${y.toStringAsPrecision(17)}';
      for (final r in records) {
        if (cells.containsKey(key(r.$1, r.$2))) {
          throw Exception('表格存在重复的 (X,Y) 坐标: (${r.$1}, ${r.$2})');
        }
        cells[key(r.$1, r.$2)] = r.$3;
      }
      a0 = 0;
      a1 = (rows - 1).toDouble();
      b0 = 0;
      b1 = (columns - 1).toDouble();
      sample = (a, b) {
        final x = xs[a.round()], y = ys[b.round()];
        return Vec3(x, y, cells[key(x, y)] ?? double.nan);
      };
      if (valueColumn != null) {
        final scalarCells = <String, double>{
          for (final r in records) key(r.$1, r.$2): r.$4 ?? double.nan,
        };
        externalValues = [
          for (final x in xs)
            for (final y in ys) scalarCells[key(x, y)] ?? double.nan,
        ];
        valueLabel = valueName;
      }
    }
    wrapRows = false;
    wrapColumns = false;
  } else if (mode == 'preset') {
    final preset = str(p['preset'], 'plane');
    final size = toNum(p['size']) ?? 2;
    final minor = toNum(p['minorRadius']) ?? 0.65;
    final constantZ = toNum(p['constantZ']) ?? 0;
    if (!size.isFinite || size <= 0 || !minor.isFinite || minor <= 0) {
      throw Exception('预设尺度必须是正有限数');
    }
    switch (preset) {
      case 'disk' || 'ellipse':
        a0 = 0;
        a1 = 2 * math.pi;
        b0 = 0;
        b1 = 1;
        wrapRows = true;
        wrapColumns = false;
        sample = (u, v) => Vec3(
          size * v * math.cos(u),
          (preset == 'ellipse' ? size * 0.6 : size) * v * math.sin(u),
          constantZ,
        );
      case 'sphere':
        a0 = 0;
        a1 = 2 * math.pi;
        b0 = -math.pi / 2;
        b1 = math.pi / 2;
        wrapRows = true;
        wrapColumns = false;
        sample = (u, v) => Vec3(
          size * math.cos(v) * math.cos(u),
          size * math.cos(v) * math.sin(u),
          size * math.sin(v),
        );
      case 'cylinder' || 'cone':
        a0 = 0;
        a1 = 2 * math.pi;
        b0 = -size;
        b1 = size;
        wrapRows = true;
        wrapColumns = false;
        sample = (u, v) {
          final r = preset == 'cone'
              ? size * (1 - (v + size) / (2 * size))
              : size;
          return Vec3(r * math.cos(u), r * math.sin(u), v);
        };
      case 'torus':
        a0 = 0;
        a1 = 2 * math.pi;
        b0 = 0;
        b1 = 2 * math.pi;
        wrapRows = true;
        wrapColumns = true;
        sample = (u, v) => Vec3(
          (size + minor * math.cos(v)) * math.cos(u),
          (size + minor * math.cos(v)) * math.sin(u),
          minor * math.sin(v),
        );
      case 'paraboloid':
        a0 = -size;
        a1 = size;
        b0 = -size;
        b1 = size;
        sample = (x, y) => Vec3(x, y, (x * x + y * y) / size);
      case 'saddle':
        a0 = -size;
        a1 = size;
        b0 = -size;
        b1 = size;
        sample = (x, y) => Vec3(x, y, (x * x - y * y) / size);
      case 'gaussian':
        a0 = -2 * size;
        a1 = 2 * size;
        b0 = -2 * size;
        b1 = 2 * size;
        sample = (x, y) =>
            Vec3(x, y, size * math.exp(-(x * x + y * y) / (size * size)));
      default:
        a0 = -size;
        a1 = size;
        b0 = -size;
        b1 = size;
        sample = (x, y) => Vec3(x, y, constantZ);
    }
  } else {
    if (![a0, a1, b0, b1].every((v) => v.isFinite) || a0 >= a1 || b0 >= b1) {
      throw Exception('曲面参数范围必须是递增的有限区间');
    }
    final fz = compileFormula(str(p['exprZ'], 'sin(x)*cos(y)'));
    if (fz == null) throw Exception('无法解析曲面 Z 表达式');
    if (mode == 'parametric') {
      final fx = compileFormula(str(p['exprX'], 'x'));
      final fy = compileFormula(str(p['exprY'], 'y'));
      if (fx == null || fy == null) throw Exception('无法解析参数曲面的 X/Y 表达式');
      sample = (u, v) => Vec3(fx(u, v), fy(u, v), fz(u, v));
    } else if (mode == 'explicit') {
      sample = (x, y) => Vec3(x, y, fz(x, y));
    } else {
      throw Exception('未知曲面生成方式: $mode');
    }
  }

  final vertices = <Vec3>[];
  for (var i = 0; i < rows; i++) {
    final a = a0 + (a1 - a0) * i / (wrapRows ? rows : rows - 1);
    for (var j = 0; j < columns; j++) {
      final b = b0 + (b1 - b0) * j / (wrapColumns ? columns : columns - 1);
      try {
        vertices.add(sample(a, b));
      } catch (_) {
        vertices.add(const Vec3(double.nan, double.nan, double.nan));
      }
    }
  }
  bool finite(Vec3 v) => v.x.isFinite && v.y.isFinite && v.z.isFinite;
  final faces = <List<int>>[];
  final rowCells = wrapRows ? rows : rows - 1;
  final columnCells = wrapColumns ? columns : columns - 1;
  for (var i = 0; i < rowCells; i++) {
    for (var j = 0; j < columnCells; j++) {
      final i1 = (i + 1) % rows, j1 = (j + 1) % columns;
      final q = [
        i * columns + j,
        i1 * columns + j,
        i1 * columns + j1,
        i * columns + j1,
      ];
      if (q.every((k) => finite(vertices[k]))) {
        faces.add([q[0], q[1], q[2]]);
        faces.add([q[0], q[2], q[3]]);
      }
    }
  }
  if (faces.isEmpty) throw Exception('曲面没有可绘制的有限网格面');

  final sums = List<Vec3>.filled(vertices.length, const Vec3(0, 0, 0));
  for (final f in faces) {
    final a = vertices[f[0]], b = vertices[f[1]], c = vertices[f[2]];
    final u = b - a, v = c - a;
    final n = Vec3(
      u.y * v.z - u.z * v.y,
      u.z * v.x - u.x * v.z,
      u.x * v.y - u.y * v.x,
    );
    for (final k in f) {
      sums[k] = sums[k] + n;
    }
  }
  final normals = sums.map((n) {
    final length = math.sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
    return length > 0 && length.isFinite
        ? n.scale(1 / length)
        : const Vec3(0, 0, 0);
  }).toList();
  final valueMode = str(p['valueMode'], 'z');
  final values =
      externalValues ??
      (valueMode == 'none'
          ? null
          : vertices
                .map(
                  (v) => !finite(v)
                      ? double.nan
                      : valueMode == 'radius'
                      ? math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
                      : v.z,
                )
                .toList());
  final finiteValues =
      values?.where((v) => v.isFinite).toList() ?? const <double>[];
  final cb = ctx.inputs['in1'];
  final display = str(p['displayMode'], 'surface');
  return MeshData(
    name: str(p['name'], '曲面'),
    vertices: vertices,
    faces: faces,
    normals: normals,
    vertexValues: values,
    gradient: cb is ColorbarData
        ? cb.stops.map((s) => s.copy()).toList()
        : null,
    valueMin: cb is ColorbarData && cb.min != null
        ? cb.min
        : finiteValues.isEmpty
        ? null
        : finiteValues.reduce(math.min),
    valueMax: cb is ColorbarData && cb.max != null
        ? cb.max
        : finiteValues.isEmpty
        ? null
        : finiteValues.reduce(math.max),
    valueLabel: cb is ColorbarData ? cb.label ?? valueLabel : valueLabel,
    gridRows: rows,
    gridColumns: columns,
    wrapRows: wrapRows,
    wrapColumns: wrapColumns,
    previewFaceBudget: (toNum(p['previewFaceBudget']) ?? 6000).round().clamp(
      100,
      100000,
    ),
    sourceVertexCount: vertices.length,
    sourceFaceCount: faces.length,
    doubleSided: p['doubleSided'] != false,
    color: p['color'] is String && '${p['color']}'.isNotEmpty
        ? '${p['color']}'
        : null,
    opacity: num_(p['opacity'], 0.6).clamp(0.05, 1.0),
    showEdge: display != 'surface',
    edgeColor: p['edgeColor'] is String && '${p['edgeColor']}'.isNotEmpty
        ? '${p['edgeColor']}'
        : null,
    wireframe: display == 'wireframe',
    fill: display != 'wireframe',
  );
}

/// 从任意数据对象中提取一行一个的数值序列(表格取首列,曲线/散点取 y)
List<double>? exposedValues(DataObject? obj) {
  if (obj == null) return null;
  if (obj is TableData) {
    if (obj.columns.isEmpty) return null;
    final vals = obj.columns.first.values
        .map(toNum)
        .whereType<double>()
        .toList();
    return vals.isEmpty ? null : vals;
  }
  if (obj is SeriesData) return obj.points.map((p) => p.y).toList();
  if (obj is ScatterData) return obj.points.map((p) => p.y).toList();
  if (obj is DistributionData) {
    return obj.bins.map((b) => b.count.toDouble()).toList();
  }
  if (obj is MeshData) {
    return obj.vertices
        .map((v) => math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z))
        .toList();
  }
  return null;
}

/// 归一化到 [0,1](成正比)
List<double> norm01(List<double> values) {
  final mx = values.reduce(math.max);
  if (!mx.isFinite || mx <= 0) return List.filled(values.length, 1.0);
  return values.map((v) => math.max(0.0, math.min(1.0, v / mx))).toList();
}

/// 数值 → 颜色(蓝→红渐变)
String valueColor(double t) {
  final hue = 210 - 210 * t;
  return 'hsl(${hue.round()}, 75%, 55%)';
}
