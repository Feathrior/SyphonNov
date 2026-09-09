import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:syphon_nov/models/data.dart' as md;
import 'package:syphon_nov/models/exec.dart';
import 'package:syphon_nov/models/registry.dart';
import 'package:syphon_nov/store/graph_store.dart';
import 'package:syphon_nov/ui/principled.dart';

md.MeshData surface(
  Map<String, dynamic> params, {
  Map<String, md.DataObject?> inputs = const {},
}) {
  return kExec['surface_input']!(
        md.ExecContext(nodeId: 'surface', params: params, inputs: inputs),
      )['out0']!
      as md.MeshData;
}

void main() {
  test('v0.4.1 directly replaces the plane node', () {
    expect(getConfig('surface_input')?.label, '曲面输入');
    expect(kExec['surface_input'], isNotNull);
    expect(getConfig('plane_input'), isNull);
    expect(kExec['plane_input'], isNull);
  });

  test('explicit surface samples values, faces, and unit normals', () {
    final mesh = surface({
      'mode': 'explicit',
      'exprZ': 'x^2-y^2',
      'xMin': -1,
      'xMax': 1,
      'yMin': -1,
      'yMax': 1,
      'rows': 3,
      'columns': 3,
    });
    expect(mesh.vertices.length, 9);
    expect(mesh.faces.length, 8);
    expect(mesh.vertices[4].z, 0);
    expect(mesh.normals, hasLength(9));
    for (final n in mesh.normals!) {
      final length = math.sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
      expect(length, closeTo(1, 1e-9));
    }
  });

  test('non-finite samples become holes and are never referenced by faces', () {
    final mesh = surface({
      'mode': 'explicit',
      'exprZ': '1/(x^2+y^2)',
      'xMin': -1,
      'xMax': 1,
      'yMin': -1,
      'yMax': 1,
      'rows': 5,
      'columns': 5,
    });
    expect(mesh.vertices[12].z.isFinite, isFalse);
    expect(mesh.faces.expand((f) => f), isNot(contains(12)));
    expect(mesh.faces.length, lessThan(32));
  });

  test(
    'periodic parametric sphere closes seam without duplicate endpoint row',
    () {
      final mesh = surface({
        'mode': 'parametric',
        'exprX': 'cos(y)*cos(x)',
        'exprY': 'cos(y)*sin(x)',
        'exprZ': 'sin(y)',
        'xMin': 0,
        'xMax': 2 * math.pi,
        'yMin': -math.pi / 2,
        'yMax': math.pi / 2,
        'rows': 12,
        'columns': 7,
        'wrapRows': true,
      });
      expect(mesh.vertices.length, 84);
      expect(mesh.faces.length, 12 * 6 * 2);
      expect(
        mesh.faces.any((f) => f.contains(0) && f.any((i) => i >= 77)),
        isTrue,
      );
    },
  );

  test(
    'table grid reconstructs rectangle and keeps a missing cell as a hole',
    () {
      final table = md.TableData([
        md.Column(name: 'x', values: [0, 0, 1]),
        md.Column(name: 'y', values: [0, 1, 0]),
        md.Column(name: 'z', values: [0, 1, 1]),
      ]);
      expect(
        () => surface({'mode': 'grid'}, inputs: {'in0': table}),
        throwsA(isA<Exception>()),
        reason: 'a 2x2 grid with one missing corner has no complete face',
      );

      final full = md.TableData([
        md.Column(name: 'x', values: [0, 0, 1, 1]),
        md.Column(name: 'y', values: [0, 1, 0, 1]),
        md.Column(name: 'z', values: [0, 1, 1, 2]),
      ]);
      final mesh = surface({'mode': 'grid'}, inputs: {'in0': full});
      expect(mesh.vertices.length, 4);
      expect(mesh.faces.length, 2);
    },
  );

  test('presets are finite meshes and plane is a surface preset', () {
    for (final preset in [
      'plane',
      'disk',
      'ellipse',
      'sphere',
      'cylinder',
      'cone',
      'torus',
      'paraboloid',
      'saddle',
      'gaussian',
    ]) {
      final mesh = surface({
        'mode': 'preset',
        'preset': preset,
        'rows': 12,
        'columns': 9,
      });
      expect(mesh.faces, isNotEmpty, reason: preset);
      expect(
        mesh.faces.expand((f) => f).every((i) => mesh.vertices[i].z.isFinite),
        isTrue,
        reason: preset,
      );
    }
    final plane = surface({
      'mode': 'preset',
      'preset': 'plane',
      'constantZ': 1.25,
      'doubleSided': false,
      'rows': 3,
      'columns': 3,
    });
    expect(plane.vertices.every((v) => v.z == 1.25), isTrue);
    expect(plane.doubleSided, isFalse);
  });

  test('matrix table layout uses row coordinates and numeric column names', () {
    final table = md.TableData([
      md.Column(name: 'y', values: [10, 20]),
      md.Column(name: '0', values: [1, 2]),
      md.Column(name: '2', values: [3, 4]),
    ]);
    final mesh = surface(
      {'mode': 'grid', 'gridLayout': 'matrix'},
      inputs: {'in0': table},
    );
    expect(mesh.vertices.map((v) => v.x).toSet(), {0, 2});
    expect(mesh.vertices.map((v) => v.y).toSet(), {10, 20});
    expect(mesh.vertices.map((v) => v.z).toList(), [1, 2, 3, 4]);
    expect(mesh.faces.length, 2);
  });

  test('equal data aspect gives identical physical scale on x/y/z', () {
    final axes = md.AxesData(
      name: 'equal',
      dim: 3,
      xLen: 12,
      yLen: 8,
      zLen: 6,
      xMin: -2,
      xMax: 2,
      yMin: -1,
      yMax: 1,
      zMin: -0.5,
      zMax: 0.5,
      grid: true,
      axisOrigin: 'origin',
      showBorder: true,
      labelX: 'x',
      labelY: 'y',
      labelZ: 'z',
      gridX: true,
      gridY: true,
      gridZ: true,
      fontSize: 10,
      fontFamily: 'sans-serif',
      aspectMode: 'equal',
    );
    final lengths = equalDataAspectLengths(axes);
    expect(lengths.x / 4, closeTo(lengths.y / 2, 1e-12));
    expect(lengths.y / 2, closeTo(lengths.z, 1e-12));
  });

  test('connected colorbar controls scalar range and gradient', () {
    final cb = md.ColorbarData(
      stops: [
        md.GradientStop(offset: 0, color: '#0000ff'),
        md.GradientStop(offset: 1, color: '#ff0000'),
      ],
      min: -2,
      max: 2,
      label: 'height',
    );
    final mesh = surface(
      {'mode': 'preset', 'preset': 'saddle', 'rows': 5, 'columns': 5},
      inputs: {'in1': cb},
    );
    expect(mesh.gradient, hasLength(2));
    expect(mesh.valueMin, -2);
    expect(mesh.valueMax, 2);
    expect(mesh.valueLabel, 'height');

    final table = md.TableData([
      md.Column(name: 'x', values: [0, 0, 1, 1]),
      md.Column(name: 'y', values: [0, 1, 0, 1]),
      md.Column(name: 'z', values: [0, 1, 1, 2]),
      md.Column(name: 'temperature', values: [10, 20, 30, 40]),
    ]);
    final external = surface(
      {'mode': 'grid', 'valueCol': 'temperature'},
      inputs: {'in0': table, 'in1': cb},
    );
    expect(external.vertexValues, [10, 20, 30, 40]);
    expect(
      external.valueLabel,
      'height',
      reason: 'connected Colorbar owns the displayed label',
    );
  });

  test('invalid ranges, budgets, and duplicate table coordinates fail', () {
    expect(() => surface({'xMin': 1, 'xMax': 1}), throwsException);
    expect(() => surface({'rows': 401}), throwsException);
    final duplicate = md.TableData([
      md.Column(name: 'x', values: [0, 0, 1, 1, 1]),
      md.Column(name: 'y', values: [0, 0, 0, 1, 0]),
      md.Column(name: 'z', values: [0, 2, 1, 2, 1]),
    ]);
    expect(
      () => surface({'mode': 'grid'}, inputs: {'in0': duplicate}),
      throwsException,
    );
  });

  test('old plane workflows are rejected atomically with upgrade guidance', () {
    final store = GraphStore.instance;
    final before = store.nodes.length;
    final json = jsonEncode({
      'format': 'syphon-graph',
      'formatVersion': 2,
      'nodes': [
        {
          'id': 'old',
          'configId': 'plane_input',
          'params': {},
          'position': {'x': 0, 'y': 0},
        },
      ],
      'edges': [],
    });
    expect(store.loadGraph(json, silent: true), isFalse);
    expect(store.nodes.length, before);
  });
}
