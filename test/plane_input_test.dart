// 平面输入节点回归测试:xy 平面图元生成(圆/椭圆/矩形/自定义多边形)与样式传递。
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/models/data.dart' as md;
import 'package:syphon_nov/models/exec.dart';
import 'package:syphon_nov/models/exec_engine.dart';
import 'package:syphon_nov/models/registry.dart';

void main() {
  test('注册表:平面输入取代旧面输入', () {
    expect(getConfig('plane_input'), isNotNull);
    expect(getConfig('plane_input')!.label, '平面输入');
    expect(getConfig('plane_input')!.outputs.first.type, md.SocketType.mesh);
    expect(getConfig('face_input'), isNull);
  });

  test('圆面:圆心+圆周扇区,z 恒为 0', () {
    final out = kExec['plane_input']!(
      md.ExecContext(
        nodeId: 'n',
        params: {
          'name': '圆',
          'shape': 'circle',
          'cx': 1,
          'cy': 2,
          'radius': 3,
          'slices': 36,
        },
        inputs: const {},
      ),
    );
    final mesh = out['out0']! as md.MeshData;
    expect(mesh.vertices.length, 37); // 圆心 + 36 圆周点
    expect(mesh.faces.length, 36);
    expect(mesh.vertices.every((v) => v.z == 0), isTrue);
    expect(mesh.vertices[1].x, closeTo(4, 1e-9)); // (1+3, 2)
  });

  test('椭圆面与矩形面顶点/面数正确', () {
    final ellipse =
        kExec['plane_input']!(
              md.ExecContext(
                nodeId: 'n',
                params: {
                  'shape': 'ellipse',
                  'cx': 0,
                  'cy': 0,
                  'rx': 3,
                  'ry': 2,
                  'slices': 24,
                },
                inputs: const {},
              ),
            )['out0']!
            as md.MeshData;
    expect(ellipse.vertices.length, 24);
    expect(ellipse.faces.length, 22);

    final rect =
        kExec['plane_input']!(
              md.ExecContext(
                nodeId: 'n',
                params: {'shape': 'rect', 'cx': 0, 'cy': 0, 'w': 4, 'h': 2},
                inputs: const {},
              ),
            )['out0']!
            as md.MeshData;
    expect(rect.vertices.length, 4);
    expect(rect.faces.length, 2);
    expect(rect.vertices[0].x, -2);
    expect(rect.vertices[0].y, -1);
    expect(rect.vertices[3].x, -2);
    expect(rect.vertices[3].y, 1);
  });

  test('自定义点列多边形(含闭合去重)与样式传递', () {
    final out = kExec['plane_input']!(
      md.ExecContext(
        nodeId: 'n',
        params: {
          'name': '多边形',
          'shape': 'polygon',
          // 末尾点与首点相同:应去重
          'pointsText': '0,0\n4,0\n4,3\n0,3\n0,0',
          'color': '#ff0000',
          'opacity': 0.5,
          'showEdge': false,
          'edgeColor': '#00ff00',
          'wireframe': true,
          'fillFaces': false,
        },
        inputs: const {},
      ),
    );
    final mesh = out['out0']! as md.MeshData;
    expect(mesh.vertices.length, 4); // 去重后 4 个角点
    expect(mesh.faces.length, 2); // 三角扇:2 个三角形
    expect(mesh.color, '#ff0000');
    expect(mesh.opacity, 0.5);
    expect(mesh.showEdge, isFalse);
    expect(mesh.edgeColor, '#00ff00');
    expect(mesh.wireframe, isTrue);
    expect(mesh.fill, isFalse);
  });

  test('坐标系输入携带原理化旋转角(x/y/z)', () {
    final out = kExec['axis_input']!(
      md.ExecContext(
        nodeId: 'n',
        params: {'rotX': -30, 'rotY': 40, 'rotZ': 15},
        inputs: const {},
      ),
    );
    final axes = out['out0']! as md.AxesData;
    expect(axes.rotX, -30);
    expect(axes.rotY, 40);
    expect(axes.rotZ, 15);
    // 默认旋转角
    final def =
        kExec['axis_input']!(
              md.ExecContext(nodeId: 'n', params: const {}, inputs: const {}),
            )['out0']!
            as md.AxesData;
    expect(def.rotX, -20);
    expect(def.rotY, 25);
    expect(def.rotZ, 0);
    // 坐标系节点参数齐全
    final cfg = getConfig('axis_input')!;
    final keys = cfg.params.map((p) => p.key).toSet();
    expect(keys.containsAll(['rotX', 'rotY', 'rotZ']), isTrue);
  });

  test('表格转分布节点已移除', () {
    expect(getConfig('table_to_distribution'), isNull);
  });

  test('经执行引擎送达下游可视化节点', () {
    final outcome = runGraph(
      [
        GraphNodeLite(
          id: 'p',
          configId: 'plane_input',
          params: {'shape': 'circle', 'radius': 3, 'slices': 12},
        ),
        GraphNodeLite(id: 'viz', configId: 'viz_bar', params: const {}),
      ],
      [
        GraphEdgeLite(
          source: 'p',
          target: 'viz',
          sourceHandle: 'out0',
          targetHandle: 'in_faces',
        ),
      ],
    );
    expect(outcome.results['viz']!.inputs['in_faces'], isA<md.MeshData>());
    expect(outcome.results['viz']!.multiInputs['in_faces']!.length, 1);
  });
}
