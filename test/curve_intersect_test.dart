// 曲线求交节点测试:两条曲线折线段相交检测,输出交点散点。
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/models/data.dart' as md;
import 'package:syphon_nov/models/exec.dart';
import 'package:syphon_nov/models/exec_engine.dart';
import 'package:syphon_nov/models/registry.dart';

md.SeriesData _series(List<md.Pt> pts) => md.SeriesData(name: 's', points: pts);

md.ExecContext _ctx(
  md.DataObject a,
  md.DataObject b, {
  Map<String, dynamic>? extra,
}) => md.ExecContext(
  nodeId: 'n',
  params: {'name': '交点', ...?extra},
  inputs: {'in0': a, 'in1': b},
);

void main() {
  test('注册表:线面求交节点支持任意几何并输出交点和交线', () {
    final cfg = getConfig('geometry_intersect');
    expect(cfg, isNotNull);
    expect(cfg!.category, md.Category.compute);
    expect(cfg.inputs.map((s) => s.type), everyElement(md.SocketType.any));
    expect(cfg.outputs.first.type, md.SocketType.scatter);
    expect(cfg.outputs.last.type, md.SocketType.series);
  });

  test('三维曲线穿过曲面时保留交点 Z 坐标', () {
    final line = md.SeriesData(
      name: 'line',
      points: const [md.Pt(0.2, 0.2), md.Pt(0.2, 0.2)],
      zValues: const [-1, 1],
    );
    final plane = md.MeshData(
      name: 'plane',
      vertices: const [md.Vec3(0, 0, 0), md.Vec3(1, 0, 0), md.Vec3(0, 1, 0)],
      faces: const [
        [0, 1, 2],
      ],
    );
    final out = kExec['geometry_intersect']!(_ctx(line, plane));
    final pts = (out['out0']! as md.ScatterData).points;
    expect(pts, hasLength(1));
    expect(pts.single.z, closeTo(0, 1e-10));
  });

  test('两个三角曲面输出带 Z 的交线', () {
    final a = md.MeshData(
      name: 'horizontal',
      vertices: const [md.Vec3(-1, -1, 0), md.Vec3(1, -1, 0), md.Vec3(0, 1, 0)],
      faces: const [
        [0, 1, 2],
      ],
    );
    final b = md.MeshData(
      name: 'vertical',
      vertices: const [md.Vec3(0, -1, -1), md.Vec3(0, 1, -1), md.Vec3(0, 0, 1)],
      faces: const [
        [0, 1, 2],
      ],
    );
    final out = kExec['geometry_intersect']!(_ctx(a, b));
    final curve = out['out1']! as md.SeriesData;
    expect(curve.points.length, greaterThanOrEqualTo(2));
    expect(curve.zValues, isNotNull);
    expect(
      curve.points.where((p) => p.x.isFinite).every((p) => p.x.abs() < 1e-8),
      isTrue,
    );
  });

  test('两条相交折线输出唯一交点', () {
    // 直线 y = x(0,0)-(4,4) 与直线 y = -x+4(0,4)-(4,0):交点 (2,2)
    final a = _series(const [md.Pt(0, 0), md.Pt(4, 4)]);
    final b = _series(const [md.Pt(0, 4), md.Pt(4, 0)]);
    final out = kExec['curve_intersect']!(_ctx(a, b));
    final scatter = out['out0']! as md.ScatterData;
    expect(scatter.points.length, 1);
    expect(scatter.points[0].x, closeTo(2, 1e-9));
    expect(scatter.points[0].y, closeTo(2, 1e-9));
    expect(scatter.points[0].z, 0);
  });

  test('同一交点被多段重复命中时去重', () {
    // 曲线 A 两段都穿过 B 的交点处(共点相交)
    final a = _series(const [
      md.Pt(0, 0),
      md.Pt(2, 2),
      md.Pt(4, 4), // (2,2) 同时是两段的端点
    ]);
    final b = _series(const [md.Pt(0, 4), md.Pt(4, 0)]);
    final out = kExec['curve_intersect']!(_ctx(a, b));
    final scatter = out['out0']! as md.ScatterData;
    expect(scatter.points.length, 1);
    expect(scatter.points[0].x, closeTo(2, 1e-9));
  });

  test('不相交曲线输出为空点组', () {
    final a = _series(const [md.Pt(0, 0), md.Pt(4, 0)]);
    final b = _series(const [md.Pt(0, 4), md.Pt(4, 4)]);
    final out = kExec['curve_intersect']!(_ctx(a, b));
    expect((out['out0']! as md.ScatterData).points, isEmpty);
  });

  test('正弦×余弦多交点:像素采样下几何上应检出 2 个交点(π/4 与 5π/4 附近)', () {
    final xs = List.generate(201, (i) => i * 2 * 3.141592653589793 / 200);
    final sa = _series([for (final x in xs) md.Pt(x, math.sin(x))]);
    final sb = _series([for (final x in xs) md.Pt(x, math.cos(x))]);
    final out = kExec['curve_intersect']!(_ctx(sa, sb));
    final pts = (out['out0']! as md.ScatterData).points;
    expect(pts.length, 2);
    expect(pts[0].x, closeTo(3.141592653589793 / 4, 0.02));
    expect(pts[0].y, closeTo(0.7071, 0.02));
    expect(pts[1].x, closeTo(5 * 3.141592653589793 / 4, 0.02));
  });

  test('经执行引擎:两条曲线输入送达并输出散点', () {
    final outcome = runGraph(
      [
        GraphNodeLite(
          id: 'a',
          configId: 'func_curve',
          params: const {'expression': 'x'},
        ),
        GraphNodeLite(
          id: 'b',
          configId: 'func_curve',
          params: const {'expression': '4 - x'},
        ),
        GraphNodeLite(
          id: 'ci',
          configId: 'geometry_intersect',
          params: const {},
        ),
      ],
      [
        GraphEdgeLite(
          source: 'a',
          target: 'ci',
          sourceHandle: 'out0',
          targetHandle: 'in0',
        ),
        GraphEdgeLite(
          source: 'b',
          target: 'ci',
          sourceHandle: 'out0',
          targetHandle: 'in1',
        ),
      ],
    );
    final res = outcome.results['ci']!;
    expect(res.error, isNull);
    final scatter = res.outputs['out0']! as md.ScatterData;
    expect(scatter.points.length, 1);
    expect(scatter.points[0].x, closeTo(2, 0.05));
    expect(scatter.points[0].y, closeTo(2, 0.05));
  });
}
