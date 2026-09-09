import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syphon_nov/models/data.dart' as md;
import 'package:syphon_nov/models/exec_engine.dart';
import 'package:syphon_nov/ui/chart_coordinates.dart';
import 'package:syphon_nov/ui/viewer.dart';

// Observe actual painter geometry before rasterization. These assertions use
// hand-calculated data coordinates, independent of the mapping implementation.
// Paths store float32 geometry; 1e-4 px covers that representation error.
// Paint colors are compared after 8-bit round-trip, not float-channel identity.
class _RecordingCanvas implements Canvas {
  final circles = <({Offset center, Color color})>[];
  final paths = <({Path path, Color color})>[];
  final rects = <({Rect rect, Color color})>[];

  @override
  void drawCircle(Offset c, double radius, Paint paint) =>
      circles.add((center: c, color: Color(paint.color.toARGB32())));

  @override
  void drawPath(Path path, Paint paint) =>
      paths.add((path: Path.from(path), color: Color(paint.color.toARGB32())));

  @override
  void drawRect(Rect rect, Paint paint) =>
      rects.add((rect: rect, color: Color(paint.color.toARGB32())));

  @override
  void drawRRect(RRect rect, Paint paint) =>
      rects.add((rect: rect.outerRect, color: Color(paint.color.toARGB32())));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

_RecordingCanvas _paint(
  String chart,
  Map<String, md.DataObject> inputs, {
  Map<String, dynamic> params = const {},
}) {
  final canvas = _RecordingCanvas();
  ChartPainter(
    data: ChartData(
      chartType: chart,
      params: params,
      result: ExecResult(inputs: inputs),
    ),
  ).paint(canvas, const Size(400, 300));
  return canvas;
}

md.TableData _table(List<dynamic> x, List<dynamic> y) => md.TableData([
  md.Column(name: 'x', values: x),
  md.Column(name: 'y', values: y),
]);

void _expectPoint(Offset actual, Offset expected) {
  expect(actual.dx, closeTo(expected.dx, 1e-4));
  expect(actual.dy, closeTo(expected.dy, 1e-4));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const blue = Color(0xFF3B82F6);
  const red = Color(0xFFFF0000);

  test('table and overlay use the same value coordinate, including meshes', () {
    final canvas = _paint('scatter', {
      'in0': _table([0, 100, 25], [0, 100, 50]),
      'in_pts': md.ScatterData(
        name: 'reference',
        pointColor: '#ff0000',
        points: const [md.Pt3(25, 50)],
      ),
      'in_lines': md.SeriesData(
        name: 'reference line',
        lineColor: '#ff0000',
        points: const [md.Pt(25, 0), md.Pt(25, 100)],
      ),
      'in_faces': md.MeshData(
        name: 'reference region',
        color: '#ff0000',
        opacity: 1,
        vertices: const [
          md.Vec3(20, 40, 0),
          md.Vec3(30, 40, 0),
          md.Vec3(25, 60, 0),
        ],
        faces: const [
          [0, 1, 2],
        ],
        showEdge: false,
      ),
    });
    // Plot is [45,380] x [30,260], data is [0,100] on each axis.
    const expected = Offset(128.75, 145);
    _expectPoint(canvas.circles.last.center, expected);
    final redPaths = canvas.paths.where((p) => p.color == red).toList();
    _expectPoint(redPaths.last.path.getBounds().center, expected);
    final line = redPaths[1].path.getBounds();
    expect(line.left, closeTo(expected.dx, 1e-4));
    expect(line.top, 30);
    expect(line.bottom, 260);
    expect(redPaths.first.path.getBounds().left, closeTo(112, 1e-4));
  });

  test('overlay extending the range also rescales table marks', () {
    final canvas = _paint('scatter', {
      'in0': _table([0, 10], [0, 10]),
      'in_pts': md.ScatterData(
        name: 'extended',
        pointColor: '#ff0000',
        points: const [md.Pt3(20, 20)],
      ),
    });
    _expectPoint(canvas.circles.last.center, const Offset(212.5, 145));
    _expectPoint(
      canvas.paths.last.path.getBounds().center,
      const Offset(380, 30),
    );
  });

  test('all point and line inputs are drawn once without a table', () {
    for (final chart in ['scatter', 'line']) {
      final canvas = _paint(chart, {
        'in_pts': md.ScatterData(
          name: 'point',
          pointColor: '#ff0000',
          points: const [md.Pt3(1, 1)],
        ),
        'in_lines': md.SeriesData(
          name: 'line',
          lineColor: '#ff0000',
          points: const [md.Pt(0, 0), md.Pt(10, 10)],
        ),
      });
      final paths = canvas.paths.where((p) => p.color == red).toList();
      expect(paths.length, 2);
      _expectPoint(paths.last.path.getBounds().center, const Offset(78.5, 237));
    }
  });

  test('numeric line X preserves nonuniform sample spacing', () {
    final canvas = _paint('line', {
      'in0': _table([0, 1, 10], [0, 1, 0]),
    });
    final path = canvas.paths.singleWhere((p) => p.color == blue).path;
    final distanceToPeak = math.sqrt(33.5 * 33.5 + 230 * 230);
    final atPeak = path.computeMetrics().single.getTangentForOffset(
      distanceToPeak,
    )!;
    expect(atPeak.position.dx, closeTo(78.5, 1e-4));
    expect(atPeak.position.dy, closeTo(30, 1e-4));
  });

  test('missing rows leave a gap and mismatched columns do not overrun', () {
    final canvas = _paint('line', {
      'in0': _table([0, 1, 2, 3, 4, 5], [0, 1, null, 3, 4]),
    });
    final path = canvas.paths.singleWhere((p) => p.color == blue).path;
    expect(path.computeMetrics().length, 2);
  });

  test('categorical line and overlay use zero-based category centers', () {
    final canvas = _paint(
      'line',
      {
        'in0': _table(['A', 'B', 'C'], [0, 1, 0]),
        'in_pts': md.ScatterData(
          name: 'B',
          pointColor: '#ff0000',
          points: const [md.Pt3(1, 1)],
        ),
      },
      params: {'xCol': 'x', 'yCol': 'y'},
    );
    _expectPoint(
      canvas.paths.last.path.getBounds().center,
      const Offset(212.5, 30),
    );
    final line = canvas.paths
        .firstWhere((p) => p.color == blue)
        .path
        .getBounds();
    expect(line.left, closeTo(45 + 335 / 6, 1e-4));
    expect(line.right, closeTo(380 - 335 / 6, 1e-4));
  });

  test('scatter includes row 5001 and its outlier affects the axis', () {
    final canvas = _paint('scatter', {
      'in0': _table(
        [...List.filled(5000, 0), 100],
        [...List.filled(5000, 0), 100],
      ),
    });
    expect(canvas.circles.length, 5001);
    _expectPoint(canvas.circles.last.center, const Offset(380, 30));
  });

  test('changing units to 1e-12 leaves visible geometry unchanged', () {
    final ordinary = _paint('scatter', {
      'in0': _table([0, 1, 2], [0, 1, 2]),
    });
    final tiny = _paint('scatter', {
      'in0': _table([0, 1e-12, 2e-12], [0, 1e-12, 2e-12]),
    });
    for (var i = 0; i < 3; i++) {
      _expectPoint(tiny.circles[i].center, ordinary.circles[i].center);
    }
    final ticks = nicePlotTicks(0, 2e-12, 6);
    expect(ticks.ticks.length, greaterThan(2));
    final labels = ticks.ticks
        .map((v) => formatPlotTick(v, ticks.step))
        .toSet();
    expect(labels.length, ticks.ticks.length);
    expect(labels.any((s) => s.contains('e-')), isTrue);
  });

  test('constant and extreme finite data have finite centered mappings', () {
    final single = PlotRange.fit([1e-12]);
    expect(single.fraction(1e-12), closeTo(0.5, 1e-12));
    const extremes = PlotRange(-1e308, 1e308);
    expect(extremes.fraction(0), 0.5);
    expect(extremes.fraction(-1e308), 0);
    expect(extremes.fraction(1e308), 1);
    final ticks = nicePlotTicks(1e16, 1e16 + 2, 6);
    expect(ticks.ticks.length, lessThan(33));
    expect(ticks.ticks.every((v) => v.isFinite), isTrue);
  });

  test(
    'negative bars and overlaid zero-based categories share the value axis',
    () {
      final canvas = _paint(
        'bar',
        {
          'in0': _table(['A', 'B'], [-2, 2]),
          'in_pts': md.ScatterData(
            name: 'negative',
            pointColor: '#ff0000',
            points: const [md.Pt3(0, -2)],
          ),
        },
        params: {'xCol': 'x', 'yCol': 'y'},
      );
      final bars = canvas.rects.where((r) => r.color == blue).toList();
      expect(bars.length, 2);
      expect(bars.first.rect.bottom, lessThanOrEqualTo(260));
      expect(bars.first.rect.top, closeTo(145, 1e-4));
      _expectPoint(
        canvas.paths.last.path.getBounds().center,
        Offset(bars.first.rect.center.dx, bars.first.rect.bottom),
      );
    },
  );

  test('heatmap includes column 11 and row 121 with scale-aware colors', () {
    final canvas = _paint('heatmap', {
      'in0': md.TableData(
        List.generate(
          11,
          (j) => md.Column(
            name: 'c$j',
            values: List.generate(121, (i) => i == 120 && j == 10 ? 2e-12 : 0),
          ),
        ),
      ),
      'in_pts': md.ScatterData(
        name: 'last cell',
        pointColor: '#ff0000',
        points: const [md.Pt3(10, 120)],
      ),
    });
    // Background and frame are excluded by the heatmap cell dimensions.
    final cells = canvas.rects
        .where((r) => r.rect.width < 30 && r.rect.height < 3)
        .toList();
    expect(cells.length, greaterThanOrEqualTo(11 * 121));
    expect(cells[11 * 121 - 1].color, isNot(cells.first.color));
    final cell = cells[11 * 121 - 1].rect;
    // Labels now determine margins; the data-coordinate overlay must still
    // land at the final cell's center (cells overlap by 0.5 px to avoid seams).
    _expectPoint(
      canvas.paths.last.path.getBounds().center,
      cell.topLeft + Offset((cell.width - 0.5) / 2, (cell.height - 0.5) / 2),
    );
  });

  test('non-finite primitive positions do not reach the drawing canvas', () {
    final canvas = _paint('scatter', {
      'in_pts': md.ScatterData(
        name: 'partial',
        pointColor: '#ff0000',
        points: const [md.Pt3(0, 0), md.Pt3(double.nan, 1), md.Pt3(1, 1)],
      ),
      'in_lines': md.SeriesData(
        name: 'gap',
        lineColor: '#ff0000',
        points: const [md.Pt(0, 0), md.Pt(double.infinity, 1), md.Pt(1, 1)],
      ),
    });
    expect(canvas.paths.where((p) => p.color == red).length, 2);
    expect(canvas.paths.every((p) => p.path.getBounds().isFinite), isTrue);
  });

  test('off-screen dashed references are clipped before generating dashes', () {
    final canvas = _paint(
      'bar',
      {
        'in0': _table(['A', 'B'], [-2, 2]),
        'in_lines': md.SeriesData(
          name: 'wide reference',
          lineColor: '#ff0000',
          lineStyle: 'dashed',
          points: const [md.Pt(-1e9, 0), md.Pt(1e9, 0)],
        ),
      },
      params: {'xCol': 'x', 'yCol': 'y'},
    );
    final path = canvas.paths.singleWhere((p) => p.color == red).path;
    expect(path.getBounds().left, 45);
    expect(path.getBounds().right, lessThanOrEqualTo(380));
    expect(path.computeMetrics().length, lessThan(100));
  });

  test('plot-relative text still renders without a numeric viewport', () {
    final recorder = ui.PictureRecorder();
    ChartPainter(
      data: ChartData(
        chartType: 'graph',
        params: const {},
        result: ExecResult(
          inputs: {
            'in_texts': md.TextData(
              text: 'annotation',
              fontSize: 3,
              halign: 'left',
              valign: 'top',
              textColor: '#333333',
              fontFamily: '',
            ),
          },
        ),
      ),
    ).paint(Canvas(recorder), const Size(400, 300));
    final picture = recorder.endRecording();
    expect(picture, isA<ui.Picture>());
    picture.dispose();
  });

  test('full chart rasterizes to a valid PNG export', () async {
    final recorder = ui.PictureRecorder();
    ChartPainter(
      data: ChartData(
        chartType: 'line',
        params: const {'xCol': 'x', 'yCol': 'y'},
        result: ExecResult(inputs: {'in0': _table([0, 1, 2], [0, 1, 4])}),
      ),
    ).paint(Canvas(recorder), const Size(400, 300));
    final image = await recorder.endRecording().toImage(400, 300);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    expect(bytes, isNotNull);
    expect(bytes!.lengthInBytes, greaterThan(100));
    expect(bytes.buffer.asUint8List(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
  });
}
