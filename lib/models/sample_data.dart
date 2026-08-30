// 示例数据集预设(由 React 版 utils/sampleData.ts 移植)
library;

import 'dart:math' as math;

import 'data.dart';
import 'math.dart';

/// 预设表格数据
List<Column> presetTable(String preset) {
  switch (preset) {
    case 'volcano':
      {
        // 火山图风格:基因差异表达数据
        final gene = <dynamic>[];
        final log2fc = <dynamic>[];
        final pvalue = <dynamic>[];
        final exprA = <dynamic>[];
        final exprB = <dynamic>[];
        for (var i = 0; i < 200; i++) {
          final fc = gaussRand(0, 1.4);
          final p = math.exp(-gaussRand(0, 3.2).abs() * 1.1);
          gene.add('基因${i + 1}');
          log2fc.add(double.parse(fc.toStringAsFixed(3)));
          pvalue.add(double.parse(p.toStringAsFixed(5)));
          exprA.add(double.parse((50 + fc * 6 + gaussRand(0, 4)).toStringAsFixed(2)));
          exprB.add(double.parse((50 + fc * 6 + gaussRand(0, 4)).toStringAsFixed(2)));
        }
        return [
          Column(name: 'gene', values: gene),
          Column(name: 'log2FC', values: log2fc),
          Column(name: 'pvalue', values: pvalue),
          Column(name: 'exprA', values: exprA),
          Column(name: 'exprB', values: exprB),
        ];
      }
    case 'sales':
      {
        final month = <dynamic>[];
        final sales = <dynamic>[];
        final profit = <dynamic>[];
        for (var m = 1; m <= 24; m++) {
          month.add('$m月');
          sales.add(double.parse((120 + 40 * math.sin(m / 3) + m * 3 + gaussRand(0, 12)).toStringAsFixed(0)));
          profit.add(double.parse((30 + 15 * math.sin(m / 2.5) + m * 1.2 + gaussRand(0, 5)).toStringAsFixed(1)));
        }
        return [
          Column(name: '月份', values: month),
          Column(name: '销量', values: sales),
          Column(name: '利润', values: profit),
        ];
      }
    case 'iris':
      {
        final sl = <dynamic>[];
        final sw = <dynamic>[];
        final pl = <dynamic>[];
        final pw = <dynamic>[];
        final species = <dynamic>[];
        const centers = <List<Object>>[
        [5.0, 3.4, 1.5, 0.2, 'setosa'],
        [5.9, 2.8, 4.3, 1.3, 'versicolor'],
        [6.6, 3.0, 5.6, 2.0, 'virginica'],
      ];
      for (var i = 0; i < 150; i++) {
        final c = centers[i % 3];
        sl.add(double.parse(((c[0] as num).toDouble() + gaussRand(0, 0.35)).toStringAsFixed(1)));
        sw.add(double.parse(((c[1] as num).toDouble() + gaussRand(0, 0.3)).toStringAsFixed(1)));
        pl.add(double.parse(((c[2] as num).toDouble() + gaussRand(0, 0.4)).toStringAsFixed(1)));
        pw.add(double.parse(((c[3] as num).toDouble() + gaussRand(0, 0.25)).toStringAsFixed(1)));
        species.add(c[4]);
      }
        return [
          Column(name: 'sepal_length', values: sl),
          Column(name: 'sepal_width', values: sw),
          Column(name: 'petal_length', values: pl),
          Column(name: 'petal_width', values: pw),
          Column(name: 'species', values: species),
        ];
      }
    default:
      {
        // phys:带噪声的物理曲线数据
        final n = 200;
        final xs = linspace(0, 6 * math.pi, n);
        final ys = xs
            .map((x) => double.parse((math.sin(x) + 0.12 * gaussRand(0, 1)).toStringAsFixed(4)))
            .toList();
        return [
          Column(name: 'x', values: xs.map((v) => double.parse(v.toStringAsFixed(4))).toList()),
          Column(name: 'y', values: ys),
        ];
      }
  }
}

/// 预设曲线数据
DataObject presetSeries(String preset) {
  final n = 200;
  if (preset == 'random-walk') {
    var v = 0.0;
    final pts = <Pt>[];
    for (var i = 0; i < n; i++) {
      v += gaussRand(0, 0.6);
      pts.add(Pt(i.toDouble(), double.parse(v.toStringAsFixed(4))));
    }
    return SeriesData(name: '随机游走', points: pts);
  }
  if (preset == 'sin-noise') {
    final xs = linspace(0, 4 * math.pi, n);
    return SeriesData(
      name: '正弦+噪声',
      points: xs
          .map((x) => Pt(
              double.parse(x.toStringAsFixed(4)),
              double.parse((math.sin(x) + 0.15 * gaussRand(0, 1)).toStringAsFixed(4))))
          .toList(),
    );
  }
  final xs = linspace(0, 10, n);
  return SeriesData(
    name: '二次曲线',
    points: xs
        .map((x) => Pt(
            double.parse(x.toStringAsFixed(4)),
            double.parse((0.5 * x * x - 3 * x + 2 + gaussRand(0, 1.2)).toStringAsFixed(4))))
        .toList(),
  );
}

/// 预设散点数据
DataObject presetScatter(String preset) {
  final n = 300;
  if (preset == 'cluster') {
    final pts = <Pt3>[];
    const centers = [
      [0.0, 0.0],
      [4.0, 3.0],
      [-2.0, 5.0],
    ];
    for (var i = 0; i < n; i++) {
      final c = centers[i % 3];
      pts.add(Pt3(
        double.parse((c[0] + gaussRand(0, 0.9)).toStringAsFixed(3)),
        double.parse((c[1] + gaussRand(0, 0.9)).toStringAsFixed(3)),
        (i % 3).toDouble(),
      ));
    }
    return ScatterData(name: '聚类散点', points: pts);
  }
  // 3D 螺旋
  final pts = <Pt3>[];
  for (var i = 0; i < n; i++) {
    final t = (i / n) * 8 * math.pi;
    pts.add(Pt3(
      double.parse((math.cos(t) * t * 0.4).toStringAsFixed(3)),
      double.parse((math.sin(t) * t * 0.4).toStringAsFixed(3)),
      double.parse((t * 0.5).toStringAsFixed(3)),
    ));
  }
  return ScatterData(name: '螺旋散点', points: pts);
}
