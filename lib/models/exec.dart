// 节点执行函数(由 React 版 nodes/exec.ts 移植)
library;

import 'dart:math' as math;

import 'csv.dart';
import 'data.dart';
import 'math.dart';
import 'sample_data.dart';

double num_(dynamic v, double d) {
  final n = v is num ? v.toDouble() : double.tryParse('$v');
  return (n != null && n.isFinite) ? n : d;
}

String str(dynamic v, [String d = '']) =>
    (v == null || v == '') ? d : '$v';

/// 任意数据对象 → 曲线点列
List<Pt>? toSeries(DataObject? obj) {
  if (obj == null) return null;
  if (obj is SeriesData) return obj.points;
  if (obj is ScatterData) {
    return obj.points
        .map((p) => Pt(p.x, p.z != null ? 0.0 : p.y))
        .toList();
  }
  return null;
}

/// 任意数据对象 → 表格列
List<Column>? toTable(DataObject? obj) {
  if (obj == null || obj is! TableData) return null;
  return obj.columns;
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
  const AxisPreset(this.colorX, this.colorY, this.colorZ, this.widthX,
      this.widthY, this.widthZ, this.gridX, this.gridY, this.gridZ, this.border);
}

const Map<String, AxisPreset> kAxisPresets = {
  'default': AxisPreset('#333333', '#333333', '#333333', 0.12, 0.12, 0.12, true, true, true, true),
  'math': AxisPreset('#111111', '#111111', '#111111', 0.08, 0.08, 0.08, true, true, true, true),
  'engineering': AxisPreset('#1f77b4', '#2ca02c', '#d62728', 0.16, 0.16, 0.16, true, true, true, true),
  'minimal': AxisPreset('#666666', '#666666', '#666666', 0.08, 0.08, 0.08, false, false, false, true),
  'borderless': AxisPreset('#333333', '#333333', '#333333', 0.12, 0.12, 0.12, true, true, true, false),
};

final Map<String, ExecFn> kExec = _buildExec();

Map<String, ExecFn> _buildExec() {
  return {
    'table_input': (ctx) {
      final mode = str(ctx.params['mode'], 'preset');
      if (mode == 'manual') {
        final text = str(ctx.params['dataText'], '');
        if (text.trim().isEmpty) throw Exception('未提供数据文本');
        final delimiter = str(ctx.params['delimiter'], 'csv') == 'tsv' ? '\t' : ',';
        return {'out0': TableData(parseDelimitedText(text, delimiter))};
      }
      return {'out0': TableData(presetTable(str(ctx.params['preset'], 'phys')))};
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
      if (xMax - xMin < 1e-9) xMax = xMin + 1;
      if (yMax - yMin < 1e-9) yMax = yMin + 1;
      if (zMax - zMin < 1e-9) zMax = zMin + 1;
      final axisOrigin = str(p['axisOrigin'], 'origin') == 'left' ? 'left' : 'origin';
      final labelX = str(p['labelX'], 'X').isEmpty ? 'X' : str(p['labelX']);
      final labelY = str(p['labelY'], 'Y').isEmpty ? 'Y' : str(p['labelY']);
      final labelZ = str(p['labelZ'], 'Z').isEmpty ? 'Z' : str(p['labelZ']);

      final base = kAxisPresets[str(p['axisPreset'], 'default')] ?? kAxisPresets['default']!;
      final def = kAxisPresets['default']!;
      // 与"默认"预设不同即视为已自定义,覆盖预设
      dynamic pick(dynamic v, dynamic defVal, dynamic baseVal) {
        if (v != null && v != defVal) return v;
        return baseVal;
      }

      final showBorder = pick(p['showBorder'], def.border, base.border) != false;
      final colorX = '${pick(p['axisColorX'], def.colorX, base.colorX)}';
      final colorY = '${pick(p['axisColorY'], def.colorY, base.colorY)}';
      final colorZ = '${pick(p['axisColorZ'], def.colorZ, base.colorZ)}';
      final widthX = math.max(0.02, num_(pick(p['axisWidthX'], def.widthX, base.widthX), 0.12));
      final widthY = math.max(0.02, num_(pick(p['axisWidthY'], def.widthY, base.widthY), 0.12));
      final widthZ = math.max(0.02, num_(pick(p['axisWidthZ'], def.widthZ, base.widthZ), 0.12));
      final gridX = pick(p['gridX'], def.gridX, base.gridX) != false;
      final gridY = pick(p['gridY'], def.gridY, base.gridY) != false;
      final gridZ = pick(p['gridZ'], def.gridZ, base.gridZ) != false;

      final fontSize = math.max(6.0, math.min(24.0, num_(p['fontSize'], 10)));
      final fontFamily = str(p['fontFamily'], 'sans-serif');
      final arrowX = p['arrowX'] != false;
      final arrowY = p['arrowY'] != false;

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
          arrows: AxisArrows(x: arrowX, y: arrowY),
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

    'colorbar_input': (ctx) {
      final p = ctx.params;
      return {
        'out0': ColorbarData(
          stops: parseGradient(p['gradient']),
          min: num_(p['min'], 0),
          max: num_(p['max'], 1),
          label: str(p['label'], ''),
          horizontal: str(p['orientation'], 'horizontal') != 'vertical',
        ),
      };
    },

    'line_input': (ctx) {
      final p = ctx.params;
      final name = str(p['name'], '线');
      final mode = str(p['mode'], 'parametric');
      if (mode == 'points') {
        final raw = str(p['pointsText'], '');
        final pts = <Pt>[];
        for (final l in raw.split('\n')) {
          final r = l.split(RegExp(r'[,，\t;；\s]+')).where((s) => s.isNotEmpty).toList();
          if (r.length >= 2) {
            final x = double.tryParse(r[0]);
            final y = double.tryParse(r[1]);
            if (x != null && y != null) pts.add(Pt(x, y));
          }
        }
        if (pts.isEmpty) throw Exception('未解析到有效点(格式:每行 x,y)');
        return {'out0': SeriesData(name: name, points: pts)};
      }
      final start = num_(p['start'], 0);
      final end = num_(p['end'], 10);
      final count = math.max(2, num_(p['count'], 200).round());
      final xs = linspace(start, end, count);
      final fx = compileFormula(str(p['fx'], 'x'));
      final fy = compileFormula(str(p['fy'], 'sin(x)'));
      final points = <Pt>[];
      for (final x in xs) {
        final px = fx != null ? fx(x, 0) : x;
        final py = fy != null ? fy(x, 0) : 0.0;
        if (px.isFinite && py.isFinite) points.add(Pt(px, py));
      }
      return {'out0': SeriesData(name: name, points: points)};
    },

    'face_input': (ctx) => {'out0': genMesh(ctx.params)},

    'grid_input': (ctx) {
      final p = ctx.params;
      final name = str(p['name'], '网格');
      final nx = math.max(2, num_(p['nx'], 40).round());
      final ny = math.max(2, num_(p['ny'], 40).round());
      final xmin = num_(p['xmin'], -4);
      final xmax = num_(p['xmax'], 4);
      final ymin = num_(p['ymin'], -4);
      final ymax = num_(p['ymax'], 4);
      final f = compileFormula(str(p['formula'], 'sin(sqrt(x*x+y*y))'));
      final x = linspace(xmin, xmax, nx);
      final y = linspace(ymin, ymax, ny);
      final values = <List<double>>[];
      for (final yi in y) {
        values.add(x.map((xi) => f != null ? f(xi, yi) : double.nan).toList());
      }
      return {'out0': GridData(name: name, x: x, y: y, values: values)};
    },

    'scatter_input': (ctx) {
      final p = ctx.params;
      final name = str(p['name'], '聚合点');
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
        points.add(Pt3(double.parse(x.toStringAsFixed(5)), double.parse(y.toStringAsFixed(5))));
        final size = toNum(rec['size']);
        final shape = str(rec['shape'], 'circle');
        final color = str(rec['color'], '#1f77b4');
        if (size != null && size != 4) hasSize = true;
        if (shape.isNotEmpty && shape != 'circle') hasShape = true;
        if (color.isNotEmpty && color != '#1f77b4') hasColor = true;
        sizes.add(math.max(0.5, num_(size, 4)));
        shapes.add(['square', 'diamond', 'triangle'].contains(shape) ? shape : 'circle');
        colors.add(color.isEmpty ? '#1f77b4' : color);
      }
      if (points.isEmpty) throw Exception('请添加点(至少一个有效点)');
      return {
        'out0': ScatterData(
          name: name,
          points: points,
          sizes: hasSize ? sizes : null,
          shapes: hasShape ? shapes : null,
          colors: hasColor ? colors : null,
        ),
      };
    },

    'func_curve': (ctx) {
      final p = ctx.params;
      final name = str(p['name'], '函数曲线');
      final expr = str(p['expression'], 'sin(x)');
      final f = compileFormula(expr);
      if (f == null) throw Exception('表达式无效:$expr');
      final xMin = num_(p['xMin'], 0);
      final xMax = num_(p['xMax'], 10);
      if (xMax <= xMin) throw Exception('X 结束需大于 X 起始');
      final samples = math.max(2, num_(p['samples'], 200).round());
      final points = <Pt>[];
      for (final x in linspace(xMin, xMax, samples)) {
        final y = f(x, 0);
        if (y.isFinite) {
          points.add(Pt(double.parse(x.toStringAsFixed(6)), double.parse(y.toStringAsFixed(6))));
        }
      }
      if (points.isEmpty) throw Exception('函数在此范围内无有效值');
      return {'out0': SeriesData(name: name, points: points)};
    },

    'series_input': (ctx) {
      return {'out0': presetSeries(str(ctx.params['preset'], 'quadratic'))};
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
                values: vals.map((v) => v ?? 0).toList());
          }
          final nums = vals.map(toNum).toList();
          final present = nums.whereType<double>().toList();
          final mean = present.isEmpty ? 0.0 : present.reduce((s, v) => s + v) / present.length;
          if (fillMode == 'mean') {
            return Column(
                name: col.name,
                values: vals
                    .map((v) => v ?? double.parse(mean.toStringAsFixed(4)))
                    .toList());
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
                  out[k] = double.parse(
                      (a + (b - a) * (k - prevIdx) / (i - prevIdx)).toStringAsFixed(4));
                }
              }
              prevIdx = i;
            }
          }
          for (var i = 0; i < out.length; i++) {
            if (out[i] == null) out[i] = double.parse(mean.toStringAsFixed(4));
          }
          return Column(name: col.name, values: out);
        }).toList();
      }

      final rowCount = columns.isEmpty ? 0 : columns.first.values.length;
      final keep = <int>[];
      final seen = <String>{};
      for (var r = 0; r < rowCount; r++) {
        final rowMissing = columns.any((c) => toNum(c.values[r]) == null);
        if (dropMissing && rowMissing) continue;
        final key = columns.map((c) => '${c.values[r]}').join('\u0001');
        if (dedupe && seen.contains(key)) continue;
        if (dedupe) seen.add(key);
        keep.add(r);
      }
      return {
        'out0': TableData(columns
            .map((c) => Column(
                name: c.name, values: keep.map((r) => c.values[r]).toList()))
            .toList()),
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
        double? Function(double?) fn = (v) => v;
        if (present.isNotEmpty) {
          if (method == 'zscore') {
            final mean = present.reduce((s, v) => s + v) / present.length;
            final variance = present.fold(0.0,
                (s, v) => s + math.pow(v - mean, 2).toDouble()) / present.length;
            var std = math.sqrt(variance);
            if (std == 0) std = 1.0;
            fn = (v) => v == null ? null : double.parse(((v - mean) / std).toStringAsFixed(5));
          } else {
            final mn = present.reduce(math.min);
            final mx = present.reduce(math.max);
            final span = (mx - mn) == 0 ? 1.0 : mx - mn;
            fn = (v) => v == null ? null : double.parse(((v - mn) / span).toStringAsFixed(5));
          }
        }
        return Column(
            name: col.name,
            values: col.values.map((v) => fn(toNum(v))).toList());
      }).toList();
      return {'out0': TableData(columns)};
    },

    'filter': (ctx) {
      final cols = toTable(ctx.inputs['in0']);
      if (cols == null) throw Exception('缺少表格输入');
      final colName = str(ctx.params['column'], cols.isEmpty ? '' : cols.first.name);
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
        'out0': TableData(cols
            .map((c) => Column(
                name: c.name, values: keep.map((r) => c.values[r]).toList()))
            .toList()),
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
        all.shuffle(math.Random());
        final n = math.min(count, rowCount);
        keep = all.sublist(0, n)..sort();
      } else {
        keep = List<int>.generate(math.min(count, rowCount), (i) => i);
      }
      return {
        'out0': TableData(cols
            .map((c) => Column(
                name: c.name, values: keep.map((r) => c.values[r]).toList()))
            .toList()),
      };
    },

    // ---------- 数据运算 ----------
    'derivative': (ctx) {
      final pts = makeSeries(ctx, 'in0');
      return {
        'out0': SeriesData(
          name: str(ctx.params['name'], '导数'),
          points: derivative(pts)
              .map((p) => Pt(
                  double.parse(p.x.toStringAsFixed(6)),
                  double.parse(p.y.toStringAsFixed(6))))
              .toList(),
        ),
      };
    },

    'integral': (ctx) {
      final pts = makeSeries(ctx, 'in0');
      return {
        'out0': SeriesData(
          name: str(ctx.params['name'], '积分'),
          points: cumulativeIntegral(pts)
              .map((p) => Pt(
                  double.parse(p.x.toStringAsFixed(6)),
                  double.parse(p.y.toStringAsFixed(6))))
              .toList(),
        ),
      };
    },

    'fit': (ctx) {
      final pts = makeSeries(ctx, 'in0');
      if (pts.length < 3) throw Exception('数据点过少,无法拟合');
      final xs = pts.map((p) => p.x).toList();
      final ys = pts.map((p) => p.y).toList();
      final method = str(ctx.params['method'], 'linear');
      final name = str(ctx.params['name'], '拟合曲线');
      final xmin = xs.reduce(math.min);
      final xmax = xs.reduce(math.max);

      if (method == 'exponential') {
        final ef = exponentialFit(xs, ys);
        if (ef == null) throw Exception('指数拟合失败(需要 y>0)');
        final out = linspace(xmin, xmax, 200)
            .map((x) => Pt(double.parse(x.toStringAsFixed(4)),
                double.parse((ef.a * math.exp(ef.b * x)).toStringAsFixed(5))))
            .toList();
        return {
          'out0': SeriesData(name: name, points: out),
          'out1': TableData([
            Column(
                name: '参数',
                values: ['a', 'b', 'R²'].map((s) => s as dynamic).toList()),
            Column(
                name: '值',
                values: [ef.a.toStringAsFixed(4), ef.b.toStringAsFixed(4), ef.r2.toStringAsFixed(4)]
                    .map((s) => s as dynamic)
                    .toList()),
          ]),
        };
      }
      final degree = num_(ctx.params['degree'], 1).round();
      final coeffs = polyFit(xs, ys, degree);
      final out = linspace(xmin, xmax, 200)
          .map((x) => Pt(double.parse(x.toStringAsFixed(4)),
              double.parse(polyEval(coeffs, x).toStringAsFixed(5))))
          .toList();
      return {
        'out0': SeriesData(name: name, points: out),
        'out1': TableData([
          Column(
              name: '参数',
              values:
                  List.generate(coeffs.length, (i) => 'c$i' as dynamic)),
          Column(
              name: '值',
              values:
                  coeffs.map((c) => double.parse(c.toStringAsFixed(6)) as dynamic).toList()),
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
      final out = linspace(xmin, xmax, 200)
          .map((x) => Pt(double.parse(x.toStringAsFixed(4)),
              double.parse((fit.a + fit.b * x).toStringAsFixed(5))))
          .toList();
      return {
        'out0': SeriesData(name: '线性回归', points: out),
        'out1': TableData([
          Column(
              name: '参数',
              values: ['a(截距)', 'b(斜率)', 'R²'].map((s) => s as dynamic).toList()),
          Column(
              name: '值',
              values: [
                double.parse(fit.a.toStringAsFixed(5)),
                double.parse(fit.b.toStringAsFixed(5)),
                double.parse(fit.r2.toStringAsFixed(5)),
              ].map((s) => s as dynamic).toList()),
        ]),
      };
    },

    'smooth': (ctx) {
      final pts = makeSeries(ctx, 'in0');
      final window = math.max(1, num_(ctx.params['window'], 5).round());
      return {
        'out0': SeriesData(
          name: str(ctx.params['name'], '平滑曲线'),
          points: movingAverage(pts, window),
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
        return Pt(double.parse(p.x.toStringAsFixed(6)), double.parse(v.toStringAsFixed(6)));
      }).toList();
      return {
        'out0': SeriesData(name: str(ctx.params['name'], 'f(x)=$expr'), points: points),
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
        'out0': TableData(cols
            .map((c) => Column(
                name: c.name, values: keep.map((r) => c.values[r]).toList()))
            .toList()),
      };
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
      yCol ??= numeric.length > 1 ? numeric[1] : (numeric.isNotEmpty ? numeric[0] : null);
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
        final x = toNum(xCol.values[i]);
        final y = toNum(yCol.values[i]);
        if (x == null || y == null) continue;
        final z = zCol != null ? toNum(zCol.values[i]) : null;
        if (zCol != null && z == null) continue;
        points.add(Pt3(double.parse(x.toStringAsFixed(5)),
            double.parse(y.toStringAsFixed(5)), z == null ? null : double.parse(z.toStringAsFixed(5))));
        if (normSize != null) sizes.add(baseSize * math.max(0.3, i < normSize.length ? normSize[i] : 0.5));
        if (normColor != null) colors.add(valueColor(i < normColor.length ? normColor[i] : 0));
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
      yCol ??= numeric.length > 1 ? numeric[1] : (numeric.isNotEmpty ? numeric[0] : null);
      if (xCol == null || yCol == null) throw Exception('请选择 x/y 列');
      final widthVals = exposedValues(ctx.inputs['exp_lineWidth']);
      final colorVals = exposedValues(ctx.inputs['exp_lineColor']);
      final normW = widthVals != null ? norm01(widthVals) : null;
      final normC = colorVals != null ? norm01(colorVals) : null;
      final baseW = math.max(0.5, num_(ctx.params['lineWidth'], 2));
      final baseC = str(ctx.params['lineColor'], '#ff7f0e');
      final style = str(ctx.params['lineStyle'], 'solid') == 'dashed' ? 'dashed' : 'solid';
      final points = <Pt>[];
      final sizes = <double>[];
      final colors = <String>[];
      for (var i = 0; i < xCol.values.length; i++) {
        final x = toNum(xCol.values[i]);
        final y = toNum(yCol.values[i]);
        if (x == null || y == null) continue;
        points.add(Pt(double.parse(x.toStringAsFixed(5)), double.parse(y.toStringAsFixed(5))));
        if (normW != null) sizes.add(baseW * math.max(0.3, i < normW.length ? normW[i] : 0.5));
        if (normC != null) colors.add(valueColor(i < normC.length ? normC[i] : 0));
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

    'table_to_distribution': (ctx) {
      final cols = toTable(ctx.inputs['in0']);
      if (cols == null) throw Exception('缺少表格输入');
      final colName = str(ctx.params['column'], cols.isEmpty ? '' : cols.first.name);
      var col = _findCol(cols, colName);
      col ??= cols.isNotEmpty ? cols.first : null;
      if (col == null) throw Exception('请选择数据列');
      final values = col.values
          .map(toNum)
          .whereType<double>()
          .toList();
      if (values.isEmpty) throw Exception('该列无数值数据');
      final bins = histogram(values, num_(ctx.params['bins'], 20).round());
      return {
        'out0': DistributionData(
          name: str(ctx.params['name'], '${col.name} 分布'),
          bins: bins.map((b) => DistributionBin(b.x0, b.x1, b.count)).toList(),
          sampleCount: values.length,
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
        if (normSize != null) sizes.add(baseSize * math.max(0.3, i < normSize.length ? normSize[i] : 0.5));
        if (normColor != null) colors.add(valueColor(i < normColor.length ? normColor[i] : 0));
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

/// 网格面生成
MeshData genMesh(Map<String, dynamic> params) {
  final name = str(params['name'], '面');
  final geo = str(params['geometry'], 'plane');
  final nu = math.max(2, num_(params['nu'], 24).round());
  final nv = math.max(2, num_(params['nv'], 24).round());
  final r1 = num_(params['radius'], 2);
  final r2 = num_(params['radius2'], 0.8);
  final verts = <Vec3>[];
  final faces = <List<int>>[];
  int idx(int i, int j) => i * (nv + 1) + j;
  for (var i = 0; i <= nu; i++) {
    final u = i / nu;
    for (var j = 0; j <= nv; j++) {
      final v = j / nv;
      if (geo == 'sphere') {
        final theta = u * math.pi;
        final phi = v * 2 * math.pi;
        verts.add(Vec3(r1 * math.sin(theta) * math.cos(phi),
            r1 * math.cos(theta), r1 * math.sin(theta) * math.sin(phi)));
      } else if (geo == 'torus') {
        final theta = u * 2 * math.pi;
        final phi = v * 2 * math.pi;
        verts.add(Vec3((r1 + r2 * math.cos(phi)) * math.cos(theta),
            (r1 + r2 * math.cos(phi)) * math.sin(theta), r2 * math.sin(phi)));
      } else {
        verts.add(Vec3((u * 2 - 1) * r1, (v * 2 - 1) * r1, 0));
      }
    }
  }
  for (var i = 0; i < nu; i++) {
    for (var j = 0; j < nv; j++) {
      final a = idx(i, j);
      final b = idx(i, j + 1);
      final c = idx(i + 1, j + 1);
      final d = idx(i + 1, j);
      faces.add([a, b, c]);
      faces.add([a, c, d]);
    }
  }
  return MeshData(name: name, vertices: verts, faces: faces);
}

/// 从任意数据对象中提取一行一个的数值序列(表格取首列,曲线/散点取 y)
List<double>? exposedValues(DataObject? obj) {
  if (obj == null) return null;
  if (obj is TableData) {
    if (obj.columns.isEmpty) return null;
    final vals = obj.columns.first.values.map(toNum).whereType<double>().toList();
    return vals.isEmpty ? null : vals;
  }
  if (obj is SeriesData) return obj.points.map((p) => p.y).toList();
  if (obj is ScatterData) return obj.points.map((p) => p.y).toList();
  if (obj is GridData) {
    final flat = <double>[];
    for (final row in obj.values) {
      for (final v in row) {
        if (v.isFinite) flat.add(v);
      }
    }
    return flat.isEmpty ? null : flat;
  }
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
  return values
      .map((v) => math.max(0.0, math.min(1.0, v / mx)))
      .toList();
}

/// 数值 → 颜色(蓝→红渐变)
String valueColor(double t) {
  final hue = 210 - 210 * t;
  return 'hsl(${hue.round()}, 75%, 55%)';
}
