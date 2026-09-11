import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/models/data.dart';
import 'package:syphon_nov/models/exec.dart';
import 'package:syphon_nov/models/publication_export.dart';
import 'package:syphon_nov/models/registry.dart';
import 'package:syphon_nov/models/scales.dart';
import 'package:syphon_nov/ui/viewer.dart' show pngWithPhysicalResolution;

Map<String, DataObject> execute(
  String id,
  Map<String, dynamic> params, {
  Map<String, DataObject?> inputs = const {},
  Map<String, List<DataObject>> multiInputs = const {},
}) => kExec[id]!(
  ExecContext(
    nodeId: id,
    params: params,
    inputs: inputs,
    multiInputs: multiInputs,
  ),
);

void main() {
  test('surface defaults keep interactive mesh light', () {
    final cfg = getConfig('surface_input')!;
    dynamic value(String key) =>
        cfg.params.firstWhere((p) => p.key == key).defaultValue;
    expect(value('rows'), 31);
    expect(value('columns'), 31);
    expect(value('depthSamples'), 25);
    expect(value('previewFaceBudget'), 6000);
    expect(value('opacity'), 0.6);
    expect(value('displayMode'), 'surface');
  });

  test('time scale emits UTC calendar labels', () {
    final scale = AxisScale.named(
      'time',
      DateTime.utc(2026, 1, 1).millisecondsSinceEpoch.toDouble(),
      DateTime.utc(2026, 1, 3).millisecondsSinceEpoch.toDouble(),
    );
    expect(scale.ticks(3).map((tick) => tick.label), [
      '2026-01-01',
      '2026-01-02',
      '2026-01-03',
    ]);
  });

  test('scale transform and inverse agree for log2 and symlog', () {
    final log = AxisScale.named('log2', 1, 64);
    expect(log.transform(8), closeTo(0.5, 1e-12));
    expect(log.inverse(log.transform(32)), closeTo(32, 1e-10));
    final sym = AxisScale.named('symlog', -100, 100, linearThreshold: 2);
    expect(sym.transform(0), closeTo(0.5, 1e-12));
    expect(sym.inverse(sym.transform(-17)), closeTo(-17, 1e-10));
  });

  test('non-positive logarithmic axis range is rejected', () {
    expect(
      () => execute('axis_input', {'xScale': 'log10', 'xStart': 0, 'xEnd': 10}),
      throwsArgumentError,
    );
  });

  test('uncertainty node preserves asymmetric error and CI provenance', () {
    final table = TableData([
      Column(name: 'x', values: [1, 2]),
      Column(name: 'mean', values: [10, 12]),
      Column(name: 'lo', values: [8, 9]),
      Column(name: 'hi', values: [13, 15]),
    ]);
    final series =
        execute(
              'stat_uncertainty',
              {
                'xCol': 'x',
                'yCol': 'mean',
                'yMinusCol': 'lo',
                'yPlusCol': 'hi',
                'representation': 'band',
                'uncertaintyKind': 'ci',
                'source': 'bootstrap 95%',
              },
              inputs: {'in0': table},
            )['out0']!
            as SeriesData;
    expect(series.bandLow, [8, 9]);
    expect(series.bandHigh, [13, 15]);
    expect(series.uncertaintyKind, 'ci');
    expect(series.uncertaintySource, 'bootstrap 95%');
  });

  test('SVG and export manifest share scale and uncertainty semantics', () {
    final statistical = SeriesData(
      name: 'mean ± CI',
      points: const [Pt(1, 10), Pt(10, 20), Pt(100, 30)],
      bandLow: const [8, 17, 25],
      bandHigh: const [12, 23, 35],
      uncertaintyKind: 'ci',
      uncertaintySource: 'analytical 95%',
    );
    final axes =
        execute(
              'axis_input',
              {
                'dim': '2d',
                'xStart': 1,
                'xEnd': 100,
                'xScale': 'log10',
                'yStart': 0,
                'yEnd': 40,
                'exportPreset': 'single',
                'exportDpi': 300,
              },
              inputs: {'in1': statistical},
            )['out0']!
            as AxesData;
    final svg = sceneToSvg(buildScientificScene(axes));
    expect(svg, startsWith('<svg'));
    expect(svg, contains('<polygon'));
    expect(svg, contains('clip-path'));
    expect(svg, contains('10^'));
    final manifest = exportManifest(axes, 'svg');
    expect((manifest['scales'] as Map)['x'], 'log10');
    expect((manifest['uncertainty'] as List).single['kind'], 'ci');
    expect(axes.exportUnit, 'mm');
    expect(axes.canvasPxW, closeTo(89 / 25.4 * 300, 1));
  });

  test('3D vector scene projects Z instead of flattening a surface', () {
    final mesh = MeshData(
      name: 'vertical',
      vertices: const [Vec3(0, 0, -1), Vec3(0, 0, 1), Vec3(1, 0, 0)],
      faces: const [
        [0, 1, 2],
      ],
    );
    final axes =
        execute(
              'axis_input',
              {
                'dim': '3d',
                'xStart': -2,
                'xEnd': 2,
                'yStart': -2,
                'yEnd': 2,
                'zStart': -2,
                'zEnd': 2,
              },
              inputs: {'in2': mesh},
            )['out0']!
            as AxesData;
    final polygon = buildScientificScene(
      axes,
    ).commands.whereType<ScenePolyline>().first;
    expect(polygon.points[0], isNot(polygon.points[1]));
  });

  test('manual legend order and hiding are reflected by SVG', () {
    final first = SeriesData(name: 'first', points: const [Pt(0, 0), Pt(1, 1)]);
    final second = SeriesData(
      name: 'second',
      points: const [Pt(0, 1), Pt(1, 0)],
    );
    final axes =
        execute(
              'axis_input',
              {
                'dim': '2d',
                'legendMode': 'manual',
                'legendOrder': 'second,first',
                'legendHidden': 'first',
              },
              multiInputs: {
                'in1': [first, second],
              },
            )['out0']!
            as AxesData;
    final svg = sceneToSvg(buildScientificScene(axes));
    expect(svg, contains('second'));
    expect(svg, isNot(contains('>first<')));
  });

  test('vector export keeps mapped line and marker aesthetics', () {
    final line = SeriesData(
      name: 'mapped line',
      points: const [Pt(0, 0), Pt(1, 1)],
      sizes: const [3, 3],
      colors: const ['#112233', '#445566'],
      lineStyle: 'dashed',
    );
    final points = ScatterData(
      name: 'mapped points',
      points: const [Pt3(0.5, 0.5, 0)],
      sizes: const [4],
      colors: const ['#abcdef'],
      shapes: const ['diamond'],
    );
    final axes =
        execute(
              'axis_input',
              {'dim': '2d'},
              inputs: {'in0': points, 'in1': line},
            )['out0']!
            as AxesData;
    final svg = sceneToSvg(buildScientificScene(axes));
    expect(svg, contains('stroke="#112233"'));
    expect(svg, contains('stroke-dasharray="6 4"'));
    expect(svg, contains('fill="#abcdef"'));
  });

  test('vector scene includes existing distribution and text primitives', () {
    final distribution = DistributionData(
      name: 'histogram',
      bins: const [DistributionBin(0, 1, 3)],
      sampleCount: 3,
    );
    final label = TextData(
      text: '教学标注',
      fontSize: .3,
      halign: 'center',
      valign: 'top',
      textColor: '#123456',
      fontFamily: 'sans-serif',
    );
    final axes =
        execute(
              'axis_input',
              {'dim': '2d'},
              inputs: {'in3': distribution},
              multiInputs: {
                'in4': [label],
              },
            )['out0']!
            as AxesData;
    final svg = sceneToSvg(buildScientificScene(axes));
    expect(svg, contains('教学标注'));
    expect(svg, contains('fill="#94a3b8"'));
  });

  test('PDF serializer creates a real PDF document', () async {
    final axes = execute('axis_input', {'dim': '2d'})['out0']! as AxesData;
    final bytes = await sceneToPdf(axes);
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
  });

  test('PNG physical resolution writes a pHYs chunk', () {
    final minimalHeader = Uint8List(33);
    final tagged = pngWithPhysicalResolution(minimalHeader, 300);
    expect(String.fromCharCodes(tagged.sublist(37, 41)), 'pHYs');
    expect(ByteData.sublistView(tagged, 41, 45).getUint32(0), 11811);
    expect(tagged[49], 1);
  });
}
