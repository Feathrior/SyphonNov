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
  test('注册表:曲线求交节点存在且输入输出类型正确', () {
    final cfg = getConfig('curve_intersect');
    expect(cfg, isNotNull);
    expect(cfg!.category, md.Category.compute);
    expect(cfg.inputs.map((s) => s.type), everyElement(md.SocketType.series));
    expect(cfg.outputs.first.type, md.SocketType.scatter);
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
        GraphNodeLite(id: 'ci', configId: 'curve_intersect', params: const {}),
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
