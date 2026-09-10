import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/models/data.dart';
import 'package:syphon_nov/models/exec.dart';
import 'package:syphon_nov/models/publication_export.dart';
import 'package:syphon_nov/models/registry.dart';
import 'package:syphon_nov/models/scales.dart';
import 'package:syphon_nov/ui/properties_panel.dart';

AxesData axes([Map<String, dynamic> params = const {}]) {
  return kExec['axis_input']!(
        ExecContext(nodeId: 'axis', params: params, inputs: const {}),
      )['out0']
      as AxesData;
}

void main() {
  test('coordinate defaults are symmetric and equal aspect', () {
    final value = axes();
    expect((value.xMin, value.xMax), (-5, 5));
    expect((value.yMin, value.yMax), (-5, 5));
    expect((value.zMin, value.zMax), (-5, 5));
    expect(value.aspectMode, 'equal');
    expect(value.axisOrigin, 'origin');
  });

  test(
    'redundant controls are absent and every coordinate property is grouped',
    () {
      final config = getConfig('axis_input')!;
      final keys = config.params.map((p) => p.key).toSet();
      expect(keys, isNot(contains('axisPreset')));
      expect(keys, isNot(contains('grid')));
      expect(keys, isNot(contains('canvasPxW')));
      expect(keys, isNot(contains('canvasPxH')));
      final grouped = kAxisPropertyGroups.values
          .expand((group) => group)
          .toSet();
      expect(grouped, containsAll(keys));
      expect(kAxisPropertyGroups.keys, contains('坐标轴与网格'));
    },
  );

  test(
    'individual grid switches override defaults without preset interference',
    () {
      final value = axes({'gridX': false, 'gridY': true, 'gridZ': false});
      expect((value.gridX, value.gridY, value.gridZ), (false, true, false));
    },
  );

  test('3D vector export implements all three grid families', () {
    int gridLineCount(String direction) {
      final params = <String, dynamic>{
        'dim': '3d',
        'gridX': direction == 'x',
        'gridY': direction == 'y',
        'gridZ': direction == 'z',
      };
      return buildScientificScene(axes(params)).commands
          .whereType<SceneLine>()
          .where((line) => line.color == '#dddddd')
          .length;
    }

    expect(gridLineCount('x'), greaterThan(0));
    expect(gridLineCount('y'), greaterThan(0));
    expect(gridLineCount('z'), greaterThan(0));
  });

  test('axis crossing uses zero when available and the edge otherwise', () {
    expect(axisCrossingValue(-5, 5), 0);
    expect(axisCrossingValue(2, 5), 2);
    expect(axisCrossingValue(-5, 5, atOrigin: false), -5);
  });

  test('equal aspect uses one physical scale for every data unit', () {
    final value = equalAspectLengths(
      dim: 3,
      xLength: 16,
      yLength: 10,
      zLength: 8,
      xSpan: 20,
      ySpan: 10,
      zSpan: 4,
    );
    expect(value.x / 20, closeTo(value.y / 10, 1e-12));
    expect(value.y / 10, closeTo(value.z / 4, 1e-12));
  });

  test('publication scene preserves equal data units', () {
    final scene = buildScientificScene(
      axes({
        'dim': '2d',
        'xStart': -10,
        'xEnd': 10,
        'yStart': -5,
        'yEnd': 5,
        'aspectMode': 'equal',
        'axisColorX': '#ff0000',
        'axisColorY': '#00ff00',
      }),
    );
    final xAxis = scene.commands.whereType<SceneLine>().singleWhere(
      (line) => line.color == '#ff0000',
    );
    final yAxis = scene.commands.whereType<SceneLine>().singleWhere(
      (line) => line.color == '#00ff00',
    );
    final xPixels = (xAxis.x2 - xAxis.x1).abs();
    final yPixels = (yAxis.y2 - yAxis.y1).abs();
    expect(xPixels / 20, closeTo(yPixels / 10, 1e-9));
  });

  test('mouse wheel adjusts bounded, one-sided and unbounded numbers', () {
    final bounded = param(
      key: 'bounded',
      label: 'bounded',
      type: 'number',
      min: 0,
      max: 1,
      step: .1,
    );
    final oneSided = param(
      key: 'oneSided',
      label: 'oneSided',
      type: 'number',
      min: 0,
      step: .5,
    );
    final unbounded = param(
      key: 'unbounded',
      label: 'unbounded',
      type: 'number',
    );
    expect(numericWheelValue(bounded, .95, -24), 1);
    expect(numericWheelValue(oneSided, 0, 24), 0);
    expect(numericWheelValue(unbounded, 20, -24), 30);
  });
}
