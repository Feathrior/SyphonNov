// 坐标系自适应范围:数据范围收集、整齐刻度取整、对数轴处理,
// 以及 axis_input 执行时的自动适配。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/models/auto_range.dart';
import 'package:syphon_nov/models/data.dart';
import 'package:syphon_nov/models/exec.dart';
import 'package:syphon_nov/models/registry.dart';

AxesData axesWith(
  Map<String, DataObject> inputs, [
  Map<String, dynamic> params = const {},
]) {
  return kExec['axis_input']!(
        ExecContext(nodeId: 'axis', params: params, inputs: inputs),
      )['out0']
      as AxesData;
}

void main() {
  group('collectAxisBounds', () {
    test('散点带 z 与不带 z 的差别', () {
      final flat = collectAxisBounds(
        points: [
          ScatterData(name: 'p', points: const [Pt3(10, 20), Pt3(30, 45)]),
        ],
      )!;
      expect((flat.xMin, flat.xMax), (10, 30));
      expect((flat.yMin, flat.yMax), (20, 45));
      expect(flat.hasZ, isFalse, reason: '纯 2D 数据不应去定 Z 范围');

      final space = collectAxisBounds(
        points: [
          ScatterData(
            name: 'p',
            points: const [Pt3(1, 2, 3), Pt3(4, 5, 9)],
          ),
        ],
      )!;
      expect(space.hasZ, isTrue);
      expect((space.zMin, space.zMax), (3, 9));
    });

    test('曲线把误差棒与误差带算进范围', () {
      final bounds = collectAxisBounds(
        lines: [
          SeriesData(
            name: 's',
            points: const [Pt(0, 1), Pt(10, 2)],
            yErrorMinus: const [0.5, 1],
            yErrorPlus: const [0.5, 4],
            bandLow: const [0.2, 0.3],
            bandHigh: const [3, 8],
          ),
        ],
      )!;
      expect((bounds.yMin, bounds.yMax), (0.2, 8));
      expect((bounds.xMin, bounds.xMax), (0, 10));
    });

    test('曲面顶点与分布分箱', () {
      final mesh = collectAxisBounds(
        meshes: [
          MeshData(
            name: 'm',
            vertices: const [Vec3(0, 0, 0), Vec3(2, 3, 1)],
            faces: const [],
          ),
        ],
      )!;
      expect((mesh.xMin, mesh.xMax, mesh.yMax, mesh.zMax), (0, 2, 3, 1));

      final dist = collectAxisBounds(
        dist: DistributionData(
          name: 'd',
          bins: const [DistributionBin(-2, -1, 3), DistributionBin(-1, 0, 7)],
          sampleCount: 10,
        ),
      )!;
      expect((dist.xMin, dist.xMax), (-2, 0));
      expect(dist.hasY, isFalse, reason: '分布的高度是相对坐标,不需要定 Y 范围');
    });

    test('没有可用数据时返回 null', () {
      expect(collectAxisBounds(), isNull);
      expect(
        collectAxisBounds(
          points: [ScatterData(name: 'p', points: const [Pt3(0, 0)])],
        ),
        isNotNull,
      );
    });
  });

  group('fitAxisRange', () {
    test('扩展:向外取整到整齐刻度', () {
      expect(fitAxisRange(0, 100), (0, 100));
      expect(fitAxisRange(3, 97), (0, 100));
      expect(fitAxisRange(10, 30), (10, 30));
      expect(fitAxisRange(-3.2, 4.6), (-4, 6));
      expect(fitAxisRange(1.2, 3.7), (1, 4));
    });

    test('关掉扩展只留边距', () {
      final (lo, hi) = fitAxisRange(0, 100, extend: false);
      expect(lo, closeTo(-5, 1e-9));
      expect(hi, closeTo(105, 1e-9));
    });

    test('单值数据给出对称小区间', () {
      final (lo, hi) = fitAxisRange(5, 5);
      expect(lo, lessThan(5));
      expect(hi, greaterThan(5));
      expect(fitAxisRange(0, 0), (-1, 1));
    });

    test('对数轴在 log10 空间取整,非正数据用最小正值', () {
      expect(fitAxisRange(1, 1000, log: true), (1, 1000));
      expect(fitAxisRange(30, 400, log: true), (10, 1000));
      // 数据里有 0:下界退到最小正值再取整
      expect(fitAxisRange(0, 400, log: true, minPositive: 25), (10, 1000));
      // 完全没有正值:原样返回,交给尺度校验报错
      expect(fitAxisRange(-5, 0, log: true), (-5, 0));
    });
  });

  group('axis_input 自动适配', () {
    final scatter = ScatterData(
      name: 'p',
      points: const [Pt3(10, 20), Pt3(30, 45)],
    );

    test('默认按接入的数据定范围,手动起止值被覆盖', () {
      final value = axesWith({'in0': scatter}, {'xStart': -5, 'xEnd': 5});
      expect((value.xMin, value.xMax), (10, 30));
      expect((value.yMin, value.yMax), (20, 45));
      // 没有 z 数据:保留手动的 Z 范围
      expect((value.zMin, value.zMax), (-5, 5));
    });

    test('关掉 X 范围自动就退回手动值', () {
      final value = axesWith({'in0': scatter}, {
        'xAuto': false,
        'xStart': -1,
        'xEnd': 1,
      });
      expect((value.xMin, value.xMax), (-1, 1));
      expect((value.yMin, value.yMax), (20, 45));
    });

    test('没有接入数据时保持手动范围', () {
      final value = axesWith(const {}, {'xStart': -2, 'xEnd': 8});
      expect((value.xMin, value.xMax), (-2, 8));
    });

    test('扩展开关控制取整', () {
      final snug = axesWith({'in0': scatter}, {'extendAuto': false});
      expect(snug.xMin, closeTo(9, 1e-9));
      expect(snug.xMax, closeTo(31, 1e-9));
      final nice = axesWith({'in0': scatter}, {'extendAuto': true});
      expect((nice.xMin, nice.xMax), (10, 30));
    });

    test('三维数据同时适配 Z', () {
      final value = axesWith({
        'in0': ScatterData(
          name: 'p',
          points: const [Pt3(1, 2, 30), Pt3(3, 4, 70)],
        ),
      });
      expect((value.zMin, value.zMax), (30, 70));
      final manualZ = axesWith(
        {
          'in0': ScatterData(
            name: 'p',
            points: const [Pt3(1, 2, 30), Pt3(3, 4, 70)],
          ),
        },
        {'zAuto': false},
      );
      expect((manualZ.zMin, manualZ.zMax), (-5, 5));
    });

    test('对数轴自动适配不会抛错', () {
      final value = axesWith({'in0': scatter}, {'xScale': 'log'});
      expect(value.xMin, greaterThan(0));
      expect(value.xMin, lessThanOrEqualTo(10));
      expect(value.xMax, greaterThanOrEqualTo(30));
    });

    test('Z 范围自动是坐标系参数的一部分', () {
      final keys = getConfig('axis_input')!.params.map((p) => p.key).toSet();
      expect(keys, contains('zAuto'));
    });
  });
}
