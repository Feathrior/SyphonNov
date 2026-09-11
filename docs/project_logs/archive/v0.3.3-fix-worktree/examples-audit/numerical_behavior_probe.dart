// Read-only diagnostic harness. Not named *_test.dart: these observations do
// not belong in the passing regression suite and do not freeze known defects.
// Run explicitly with flutter test examples/audit/numerical_behavior_probe.dart.
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:syphon_nov/models/data.dart';
import 'package:syphon_nov/models/exec.dart';
import 'package:syphon_nov/models/math.dart';

DataMap execute(
  String kind, {
  Map<String, dynamic> params = const {},
  Map<String, DataObject?> inputs = const {},
}) =>
    kExec[kind]!(ExecContext(nodeId: 'audit', params: params, inputs: inputs));

List<List<double>> intersections(SeriesData a, SeriesData b) {
  final result =
      execute('curve_intersect', inputs: {'in0': a, 'in1': b})['out0']!
          as ScatterData;
  return [
    for (final p in result.points) [p.x, p.y],
  ];
}

void observation(String id, Object expected, Object actual) {
  // ignore: avoid_print
  print(
    'AUDIT ${jsonEncode({'id': id, 'reference': expected, 'observed': actual})}',
  );
}

void main() {
  test(
    'record bounded numerical audit observations; product code is unchanged',
    () {
      final baseline = compileFormula('2*x^2')!(3, 0);
      final derivativeValue = derivative(const [
        Pt(0, 0),
        Pt(1, 1),
        Pt(3, 9),
      ])[1].y;
      observation(
        'control_previous_fixes',
        {'formula': 18, 'unequal_grid_derivative': 2},
        {'formula': baseline, 'unequal_grid_derivative': derivativeValue},
      );

      SeriesData crossingA(double s) =>
          SeriesData(name: 'a', points: [Pt(0, 0), Pt(s, s)]);
      SeriesData crossingB(double s) =>
          SeriesData(name: 'b', points: [Pt(0, s), Pt(s, 0)]);
      observation(
        'intersection_unit_scaling',
        {
          'counts_at_scales_1_and_1e-7': [1, 1],
        },
        {
          'counts_at_scales_1_and_1e-7': [
            intersections(crossingA(1), crossingB(1)).length,
            intersections(crossingA(1e-7), crossingB(1e-7)).length,
          ],
        },
      );

      final horizontal = SeriesData(
        name: 'zero',
        points: const [Pt(-1, 0), Pt(1, 0)],
      );
      final closeCrossings = SeriesData(
        name: 'two crossings',
        points: const [Pt(0, -1), Pt(0, 1), Pt(5e-7, 1), Pt(5e-7, -1)],
      );
      observation('intersection_close_distinct_points', [
        [0, 0],
        [5e-7, 0],
      ], intersections(horizontal, closeCrossings));

      final longCurve = SeriesData(
        name: '3001 samples',
        points: [for (var i = 0; i <= 3000; i++) Pt(i.toDouble(), 0)],
      );
      final finalCrossing = SeriesData(
        name: 'last segment crossing',
        points: const [Pt(2999.5, -1), Pt(2999.5, 1)],
      );
      observation('intersection_3001st_point', [
        [2999.5, 0],
      ], intersections(longCurve, finalCrossing));

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
      observation(
        'reciprocal_false_root',
        {
          'intersections_with_y0': <Object>[],
          'reason': '1/x never equals zero; x=0 is outside its domain',
        },
        {
          'generated_points': [
            for (final p in reciprocal.points) [p.x, p.y],
          ],
          'intersections_with_y0': intersections(reciprocal, horizontal),
        },
      );

      final namedGroups = TableData([
        Column(name: 'group', values: ['control', 'treated']),
        Column(name: 'response', values: [1, 2]),
      ]);
      final cleaned =
          execute(
                'clean',
                inputs: {'in0': namedGroups},
                params: {'dropMissing': true},
              )['out0']!
              as TableData;
      observation(
        'complete_categorical_rows_dropped',
        {'remaining_rows': 2},
        {'remaining_rows': cleaned.columns.first.values.length},
      );

      final irregularMissing = TableData([
        Column(name: 'x', values: [0, 1, 10]),
        Column(name: 'y', values: [0, null, 10]),
      ]);
      final filled =
          execute(
                'clean',
                inputs: {'in0': irregularMissing},
                params: {'fillMissing': 'interp'},
              )['out0']!
              as TableData;
      observation(
        'imputation_coordinate_assumption',
        {'linear_in_physical_x': 1, 'linear_in_row_index': 5},
        {'filled_middle_y': filled.columns[1].values[1]},
      );
      final converted =
          execute(
                'table_to_series',
                inputs: {'in0': irregularMissing},
                params: {'xCol': 'x', 'yCol': 'y'},
              )['out0']!
              as SeriesData;
      observation(
        'missing_gap_lost_after_series_conversion',
        {'missing_position': 1, 'separate_segments_needed': true},
        {
          'output_point_sequence': [
            for (final p in converted.points) [p.x, p.y],
          ],
        },
      );

      List<dynamic> zscores(List<double> values) =>
          (execute(
                    'normalize',
                    inputs: {
                      'in0': TableData([Column(name: 'v', values: values)]),
                    },
                    params: {'method': 'zscore'},
                  )['out0']!
                  as TableData)
              .columns
              .first
              .values;
      observation(
        'zscore_scale_invariance',
        {
          'both_outputs': [-1, 1],
        },
        {
          'ordinary': zscores([1, 2]),
          'large_but_finite': zscores([1e200, 2e200]),
        },
      );
    },
  );
}
