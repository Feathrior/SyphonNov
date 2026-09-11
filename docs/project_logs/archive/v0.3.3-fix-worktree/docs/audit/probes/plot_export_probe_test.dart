// Snapshot audit probes, not regression contracts for desired product behavior.
// These assertions deliberately describe observed limitations on 2026-09-06.
// Once the limitations are fixed, revise the audit and retire these probes.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syphon_nov/models/data.dart' as md;
import 'package:syphon_nov/models/exec.dart';
import 'package:syphon_nov/models/exec_engine.dart';
import 'package:syphon_nov/ui/principled.dart';
import 'package:syphon_nov/ui/vector_export.dart';
import 'package:syphon_nov/ui/viewer.dart';
import 'package:xml/xml.dart';

class _Canvas extends Fake implements Canvas {
  final paths = <Path>[];
  final rects = <({Rect rect, Color color})>[];
  var taggedShapes = 0;
  @override
  void drawPath(Path path, Paint paint) {
    paths.add(Path.from(path));
    if (paint.color.toARGB32() == 0xff123456) taggedShapes++;
  }

  @override
  void drawRect(Rect rect, Paint paint) =>
      rects.add((rect: rect, color: Color(paint.color.toARGB32())));
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('audit: tiny valid explicit axis interval is replaced by one', () {
    final axes =
        kExec['axis_input']!(
              md.ExecContext(
                nodeId: 'probe',
                params: {'dim': '2d', 'xStart': 0, 'xEnd': 1e-12},
                inputs: {},
              ),
            )['out0']!
            as md.AxesData;
    debugPrint(
      jsonEncode({
        'probe': 'tiny-axis',
        'requestedMax': 1e-12,
        'actualMax': axes.xMax,
      }),
    );
    expect(axes.xMax, 1);
  });

  test('audit: date strings receive equal category spacing', () {
    final canvas = _Canvas();
    ChartPainter(
      data: ChartData(
        chartType: 'line',
        params: {'xCol': 'date', 'yCol': 'value'},
        result: ExecResult(
          inputs: {
            'in0': md.TableData([
              md.Column(
                name: 'date',
                values: ['2020-01-01', '2020-01-02', '2020-12-31'],
              ),
              md.Column(name: 'value', values: [0, 1, 2]),
            ]),
          },
        ),
      ),
    ).paint(canvas, const Size(400, 300));
    final metric = canvas.paths.single.computeMetrics().single;
    final first = metric.getTangentForOffset(0)!.position;
    final middle = metric.getTangentForOffset(metric.length / 2)!.position;
    final last = metric.getTangentForOffset(metric.length)!.position;
    final ratio = (middle.dx - first.dx) / (last.dx - first.dx);
    debugPrint(
      jsonEncode({
        'probe': 'date-axis',
        'middleFraction': ratio,
        'elapsedTimeFraction': 1 / 365,
      }),
    );
    expect(ratio, closeTo(0.5, 1e-6));
  });

  test('audit: shared requested heatmap range changes with data extrema', () {
    final cb = md.ColorbarData(
      min: 0,
      max: 1,
      stops: [
        md.GradientStop(offset: 0, color: '#000000'),
        md.GradientStop(offset: 1, color: '#ffffff'),
      ],
    );
    int colorOfOne(List<int> values) {
      final canvas = _Canvas();
      ChartPainter(
        data: ChartData(
          chartType: 'heatmap',
          params: {},
          result: ExecResult(
            inputs: {
              'in0': md.TableData([md.Column(name: 'x', values: values)]),
              'in1': cb,
            },
          ),
        ),
      ).paint(canvas, const Size(400, 300));
      // First rectangle is page background; following rectangles are cells.
      return canvas.rects[1 + values.indexOf(1)].color.toARGB32();
    }

    final a = colorOfOne([0, 1]);
    final b = colorOfOne([0, 1, 10]);
    debugPrint(
      jsonEncode({
        'probe': 'fixed-colorrange',
        'range': [0, 1],
        'value': 1,
        'colorWithout10': a.toRadixString(16),
        'colorWith10': b.toRadixString(16),
      }),
    );
    expect(a, isNot(b));
  });

  test('audit: distribution count multiples produce identical geometry', () {
    String render(int count) {
      final page = ExportPageSpec();
      return renderVectorSvg(
        PrincipledPainter(
          params: {},
          fixedSize: page.logicalSize,
          result: ExecResult(
            inputs: {
              'in3': md.DistributionData(
                name: 'samples',
                bins: [md.DistributionBin(0, 1, count)],
                sampleCount: count,
              ),
            },
          ),
        ),
        page,
      );
    }

    final a = render(1);
    final b = render(100);
    debugPrint(
      jsonEncode({
        'probe': 'distribution-count',
        'counts': [1, 100],
        'identicalSvg': a == b,
      }),
    );
    expect(a, b);
  });

  test('audit: principled scatter silently caps at 6000 points', () {
    final canvas = _Canvas();
    PrincipledPainter(
      params: {},
      fixedSize: const Size(600, 400),
      result: ExecResult(
        inputs: {
          'in0': md.ScatterData(
            name: 'all points',
            pointColor: '#123456',
            points: List.generate(6001, (i) => const md.Pt3(0, 0, 0)),
          ),
        },
      ),
    ).paint(canvas, const Size(600, 400));
    debugPrint(
      jsonEncode({
        'probe': 'principled-point-cap',
        'input': 6001,
        'drawn': canvas.taggedShapes,
      }),
    );
    expect(canvas.taggedShapes, 6000);
  });

  test(
    'audit: principled centered annotation shifts with explicit axis range',
    () {
      final axes = kExec['axis_input']!(
        md.ExecContext(
          nodeId: 'axes',
          params: {
            'dim': '2d',
            'xStart': 0,
            'xEnd': 10,
            'yStart': 0,
            'yEnd': 10,
            'xLen': 10,
            'yLen': 10,
          },
          inputs: {},
        ),
      )['out0']!;
      final page = ExportPageSpec();
      final svg = renderVectorSvg(
        PrincipledPainter(
          params: {},
          fixedSize: page.logicalSize,
          result: ExecResult(
            inputs: {
              'in4': axes,
              'in5': md.TextData(
                text: 'AUDIT_CENTER',
                fontSize: 0.3,
                halign: 'center',
                valign: 'middle',
                textColor: '#000000',
                fontFamily: 'sans-serif',
              ),
            },
          ),
        ),
        page,
      );
      final label = XmlDocument.parse(svg)
          .findAllElements('text')
          .singleWhere((e) => e.innerText == 'AUDIT_CENTER');
      final centerX =
          double.parse(label.getAttribute('x')!) +
          double.parse(label.getAttribute('textLength')!) / 2;
      debugPrint(
        jsonEncode({
          'probe': 'principled-text-anchor',
          'expectedCenterX': page.logicalSize.width / 2,
          'actualCenterX': centerX,
        }),
      );
      expect(centerX, lessThan(page.logicalSize.width / 2 - 50));
    },
  );
}
