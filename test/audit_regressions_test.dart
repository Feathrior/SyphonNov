// Desired-behavior probes for the official SyphonNov v0.3.6 source archive.
// Kept outside test/ so known defects do not turn the author's suite green.
import 'dart:convert';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:flutter/material.dart' hide Column;
import 'package:flutter_test/flutter_test.dart';
import 'package:syphon_nov/models/csv.dart';
import 'package:syphon_nov/models/data.dart';
import 'package:syphon_nov/models/exec.dart';
import 'package:syphon_nov/models/exec_engine.dart';
import 'package:syphon_nov/models/math.dart';
import 'package:syphon_nov/store/graph_store.dart';
import 'package:syphon_nov/ui/principled.dart';
import 'package:syphon_nov/ui/viewer.dart';

DataMap execute(
  String kind, {
  Map<String, dynamic> params = const {},
  Map<String, DataObject?> inputs = const {},
}) =>
    kExec[kind]!(ExecContext(nodeId: 'audit', params: params, inputs: inputs));

class AuditCanvas extends Fake implements Canvas {
  var taggedPaths = 0;
  var circles = 0;
  final paths = <Path>[];

  @override
  void drawPath(Path path, Paint paint) {
    paths.add(Path.from(path));
    if (paint.color.toARGB32() == 0xff123456) taggedPaths++;
  }

  @override
  void drawCircle(Offset center, double radius, Paint paint) => circles++;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

List<int> sparseWorkbook() {
  final archive = Archive();
  final parts = {
    'xl/workbook.xml':
        '<workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<sheets><sheet name="Data" sheetId="1" r:id="rId1"/></sheets></workbook>',
    'xl/_rels/workbook.xml.rels':
        '<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>',
    'xl/worksheets/sheet1.xml':
        '<worksheet><sheetData>'
        '<row r="1"><c r="A1" t="inlineStr"><is><t>sample</t></is></c></row>'
        '<row r="2"><c r="A2" t="inlineStr"><is><t>A</t></is></c>'
        '<c r="C2"><v>2.5</v></c></row>'
        '</sheetData></worksheet>',
  };
  for (final entry in parts.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return ZipEncoder().encode(archive);
}

String workflow(List<Map<String, dynamic>> nodes) => jsonEncode({
  'format': 'syphon-graph',
  'version': 1,
  'nodes': nodes,
  'edges': <Object>[],
});

Map<String, dynamic> tableNode(String id, String text) => {
  'id': id,
  'configId': 'table_input',
  'params': {'mode': 'manual', 'dataText': text, 'delimiter': 'csv'},
};

List<List<dynamic>> valuesOf(GraphStore store, String id) =>
    (store.results[id]!.outputs['out0'] as TableData).columns
        .map((column) => List<dynamic>.of(column.values))
        .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('numerical correctness', () {
    test('operator precedence keeps 2*x^2 equal to 18 at x=3', () {
      expect(compileFormula('2*x^2')!(3, 0), 18);
    });

    test('small finite function values are not rounded out of the data', () {
      final curve =
          execute(
                'func_curve',
                params: {
                  'expression': '0.0000001*x',
                  'xMin': 1,
                  'xMax': 2,
                  'samples': 2,
                },
              )['out0']!
              as SeriesData;
      expect(curve.points.first.y, closeTo(1e-7, 1e-20));
    });

    test('quadratic derivative is correct on a nonuniform grid', () {
      final d = derivative(const [Pt(0, 0), Pt(1, 1), Pt(3, 9)]);
      expect(d[1].y, closeTo(2, 1e-12));
    });

    test('duplicate abscissas are rejected by differentiation', () {
      expect(() => derivative(const [Pt(1, 1), Pt(1, 2)]), throwsArgumentError);
    });

    test('linear solve is invariant under a harmless unit scale', () {
      expect(
        solveLinear(
          const [
            [1e-20, 0],
            [0, 1e-20],
          ],
          const [1e-20, 2e-20],
        ),
        [1, 2],
      );
    });

    test('singular linear systems are rejected', () {
      expect(
        () => solveLinear(
          const [
            [1, 1],
            [2, 2],
          ],
          const [2, 4],
        ),
        throwsArgumentError,
      );
    });

    test('z-score remains scale invariant for large finite values', () {
      final result =
          execute(
                'normalize',
                params: {'method': 'zscore'},
                inputs: {
                  'in0': TableData([
                    Column(name: 'v', values: [1e200, 2e200]),
                  ]),
                },
              )['out0']!
              as TableData;
      expect(result.columns.first.values, [-1, 1]);
    });

    test('min-max normalization handles an extreme finite span', () {
      final result =
          execute(
                'normalize',
                params: {'method': 'minmax'},
                inputs: {
                  'in0': TableData([
                    Column(name: 'v', values: [-1e308, 1e308]),
                  ]),
                },
              )['out0']!
              as TableData;
      expect(result.columns.first.values, [0, 1]);
    });
  });

  group('data semantics and import', () {
    test('complete categorical rows survive drop-missing cleaning', () {
      final result =
          execute(
                'clean',
                params: {'dropMissing': true},
                inputs: {
                  'in0': TableData([
                    Column(name: 'group', values: ['control', 'treated']),
                    Column(name: 'response', values: [1, 2]),
                  ]),
                },
              )['out0']!
              as TableData;
      expect(result.columns.first.values, ['control', 'treated']);
    });

    test('quoted multiline CSV survives an export/import roundtrip', () {
      final original = [
        Column(name: 'sample', values: ['A\nB', 'C']),
        Column(name: 'value', values: [1, 2]),
      ];
      final parsed = parseDelimitedText(columnsToCsv(original));
      expect(parsed.map((c) => c.values).toList(), [
        ['A\nB', 'C'],
        [1, 2],
      ]);
    });

    test('headerless mixed data does not discard its first observation', () {
      final parsed = parseDelimitedText('A,1\nB,2');
      expect(parsed.map((c) => c.values).toList(), [
        ['A', 'B'],
        [1, 2],
      ]);
    });

    test('sparse XLSX rows are widened consistently', () {
      final columns = xlsxBytesToColumns(sparseWorkbook());
      expect(columns.length, 3);
      expect(columns[2].values, [2.5]);
    });

    test('a missing table row remains a break after table-to-series', () {
      final curve =
          execute(
                'table_to_series',
                params: {'xCol': 'x', 'yCol': 'y'},
                inputs: {
                  'in0': TableData([
                    Column(name: 'x', values: [0, 1, 2]),
                    Column(name: 'y', values: [0, null, 2]),
                  ]),
                },
              )['out0']!
              as SeriesData;
      expect(curve.points, hasLength(3));
      expect(curve.points[1].x.isNaN && curve.points[1].y.isNaN, isTrue);
    });
  });

  group('geometry and plotting fidelity', () {
    test('1/x does not acquire a false root across its discontinuity', () {
      final reciprocal =
          execute(
                'func_curve',
                params: {
                  'expression': '1/x',
                  'xMin': -1,
                  'xMax': 1,
                  'samples': 3,
                },
              )['out0']!
              as SeriesData;
      final zero = SeriesData(
        name: 'zero',
        points: const [Pt(-1, 0), Pt(1, 0)],
      );
      final roots =
          execute(
                'curve_intersect',
                inputs: {'in0': reciprocal, 'in1': zero},
              )['out0']!
              as ScatterData;
      expect(roots.points, isEmpty);
    });

    test('intersection includes the final segment after point 3000', () {
      final long = SeriesData(
        name: 'long',
        points: [for (var i = 0; i <= 3000; i++) Pt(i.toDouble(), 0)],
      );
      final cross = SeriesData(
        name: 'cross',
        points: const [Pt(2999.5, -1), Pt(2999.5, 1)],
      );
      final hits =
          execute(
                'curve_intersect',
                inputs: {'in0': long, 'in1': cross},
              )['out0']!
              as ScatterData;
      expect(hits.points, hasLength(1));
    });

    test('tiny finite explicit axis intervals are preserved', () {
      final axes =
          execute(
                'axis_input',
                params: {'dim': '2d', 'xStart': 0, 'xEnd': 1e-12},
              )['out0']!
              as AxesData;
      expect(axes.xMax, 1e-12);
    });

    test('standard scatter renders row 5001', () {
      final canvas = AuditCanvas();
      ChartPainter(
        data: ChartData(
          chartType: 'scatter',
          params: {'xCol': 'x', 'yCol': 'y'},
          result: ExecResult(
            inputs: {
              'in0': TableData([
                Column(name: 'x', values: List.generate(5001, (i) => i)),
                Column(name: 'y', values: List.filled(5001, 0)),
              ]),
            },
          ),
        ),
      ).paint(canvas, const Size(400, 300));
      expect(canvas.circles, 5001);
    });

    test('principled output renders every supplied point', () {
      final scatter = ScatterData(
        name: 'all',
        pointColor: '#123456',
        points: List.generate(6001, (_) => const Pt3(0, 0, 0)),
      );
      final axes =
          execute(
                'axis_input',
                params: {'dim': '2d', 'axisPreset': 'hidden'},
                inputs: const {},
              )['out0']!
              as AxesData;
      final combined =
          kExec['axis_input']!(
                ExecContext(
                  nodeId: 'axes',
                  params: {'dim': '2d', 'axisPreset': 'hidden'},
                  inputs: const {},
                  multiInputs: {
                    'in0': [scatter],
                  },
                ),
              )['out0']!
              as AxesData;
      expect(axes.dim, combined.dim);
      final canvas = AuditCanvas();
      PrincipledPainter(
        params: const {},
        fixedSize: const Size(600, 400),
        result: ExecResult(inputs: {'in0': combined}),
      ).paint(canvas, const Size(600, 400));
      expect(canvas.taggedPaths, 6001);
    });

    test('numeric table X keeps nonuniform spacing', () {
      final canvas = AuditCanvas();
      ChartPainter(
        data: ChartData(
          chartType: 'line',
          params: {'xCol': 'x', 'yCol': 'y'},
          result: ExecResult(
            inputs: {
              'in0': TableData([
                Column(name: 'x', values: [0, 1, 10]),
                Column(name: 'y', values: [0, 1, 2]),
              ]),
            },
          ),
        ),
      ).paint(canvas, const Size(400, 300));
      final metric = canvas.paths.single.computeMetrics().single;
      final bounds = canvas.paths.single.getBounds();
      final distanceToMiddle = math.sqrt(
        math.pow(bounds.width * 0.1, 2) + math.pow(bounds.height * 0.5, 2),
      );
      final middle = metric.getTangentForOffset(distanceToMiddle)!.position;
      expect((middle.dx - bounds.left) / bounds.width, closeTo(0.1, 1e-6));
    });
  });

  group('workflow reproducibility and execution', () {
    test('saved random preset preserves realized observations', () async {
      final store = GraphStore.instance..autoRun = true;
      expect(
        store.loadGraph(
          workflow([
            {
              'id': 'random',
              'configId': 'table_input',
              'params': {'mode': 'preset', 'preset': 'volcano'},
            },
          ]),
        ),
        isTrue,
      );
      await store.settled;
      final before = valuesOf(store, 'random');
      expect(store.loadGraph(store.saveGraph()), isTrue);
      await store.settled;
      expect(valuesOf(store, 'random'), before);
    });

    test('queued independent edits retain both final values', () async {
      GraphStore.useIsolate = true;
      final store = GraphStore.instance..autoRun = true;
      expect(
        store.loadGraph(
          workflow([tableNode('a', 'v\n1'), tableNode('b', 'v\n10')]),
        ),
        isTrue,
      );
      await store.settled;
      store.updateNodeParams('a', {'dataText': 'v\n2'});
      store.updateNodeParams('b', {'dataText': 'v\n20'});
      await store.settled;
      expect(valuesOf(store, 'a'), [
        [2],
      ]);
      expect(valuesOf(store, 'b'), [
        [20],
      ]);
    });
  });
}
