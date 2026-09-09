// 曲线输入节点(函数/隐式/参数方程)与有理化精确求交测试。
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/models/data.dart' as md;
import 'package:syphon_nov/models/exec.dart';
import 'package:syphon_nov/models/math.dart';

md.ExecContext _ctx(
  Map<String, dynamic> params, {
  Map<String, md.DataObject>? inputs,
}) => md.ExecContext(
  nodeId: 'n',
  params: params,
  inputs: inputs ?? const {},
);

md.SeriesData _curve(Map<String, dynamic> params) {
  final out = kExec['func_curve']!(_ctx(params));
  return out['out0']! as md.SeriesData;
}

void main() {
  // ==================== Frac 有理数 ====================
  group('Frac 有理数', () {
    test('fromDouble 精确位分解:0.5 → 1/2', () {
      final f = Frac.fromDouble(0.5);
      expect(f.n, BigInt.one);
      expect(f.d, BigInt.two);
    });

    test('fromDouble 负数与约分:-2.75 → -11/4', () {
      final f = Frac.fromDouble(-2.75);
      expect(f.n, BigInt.from(-11));
      expect(f.d, BigInt.from(4));
    });

    test('fromDouble → toDouble 往返精确(含小数量值与次正规数)', () {
      for (final v in [1e-9, 3.7e-300, 5e-324, 1e300, -0.1, 42.0]) {
        expect(Frac.fromDouble(v).toDouble(), v);
      }
    });

    test('四则运算与比较', () {
      final a = Frac.fromDouble(0.25); // 1/4
      final b = Frac.fromDouble(0.5); // 1/2
      final sum = a + b; // 3/4
      expect(sum.n, BigInt.from(3));
      expect(sum.d, BigInt.from(4));
      expect(sum.toDouble(), 0.75);

      final diff = b - a; // 1/4
      expect(diff.cmp(a), 0);
      expect(a.cmp(b), lessThan(0));
      expect(b.cmp(a), greaterThan(0));

      final prod = a * b; // 1/8
      expect(prod.toDouble(), 0.125);

      final quot = b.div(a)!; // 2
      expect(quot.n, BigInt.two);
      expect(quot.d, BigInt.one);
      expect(a.div(Frac.zero), isNull); // 除零返回 null
    });
  });

  // ==================== exactSegIntersect 精确求交 ====================
  group('exactSegIntersect 有理化精确线段求交', () {
    test('常规交点', () {
      final r = exactSegIntersect(0, 0, 4, 4, 0, 4, 4, 0);
      expect(r, isNotNull);
      expect(r!.x, closeTo(2, 1e-12));
      expect(r.y, closeTo(2, 1e-12));
    });

    test('小数量值(1e-9 量级)交点精确', () {
      // y=x 与 y=-x+4e-9 交于 (2e-9, 2e-9):浮点叉积 ~3e-17,
      // 浮点区间判定已不可信,有理化路径应精确命中
      final r = exactSegIntersect(0, 0, 4e-9, 4e-9, 0, 4e-9, 4e-9, 0);
      expect(r, isNotNull);
      expect(r!.x, closeTo(2e-9, 1e-21));
      expect(r.y, closeTo(2e-9, 1e-21));
    });

    test('交点恰在线段端点(t=1)时命中', () {
      // (1e-9,1e-9) 同时是 A 的终点与 B 上的点
      final r = exactSegIntersect(0, 0, 1e-9, 1e-9, 0, 2e-9, 2e-9, 0);
      expect(r, isNotNull);
      expect(r!.x, closeTo(1e-9, 1e-21));
      expect(r.y, closeTo(1e-9, 1e-21));
    });

    test('平行与共线返回 null', () {
      expect(exactSegIntersect(0, 0, 4, 0, 0, 1, 4, 1), isNull); // 平行
      expect(exactSegIntersect(0, 0, 4, 0, 1, 0, 3, 0), isNull); // 共线
    });

    test('区间外不相交返回 null', () {
      // 交点在 A 的延长线上(t > 1)
      expect(exactSegIntersect(0, 0, 1, 1, 2, 0, 2, 4), isNull);
      // 交点在 B 的延长线上(u > 1)
      expect(exactSegIntersect(0, 0, 4, 4, 5, 0, 5, 4), isNull);
    });
  });

  // ==================== 曲线输入节点:函数/隐式/参数 ====================
  group('曲线输入节点', () {
    test('函数模式:y=sin(x) 采样', () {
      final s = _curve({
        'mode': 'function',
        'expression': 'sin(x)',
        'xMin': 0,
        'xMax': 3.141592653589793,
        'samples': 50,
      });
      final finite = s.points.where((p) => p.x.isFinite).toList();
      expect(finite.length, 50);
      // 中点接近 π/2 处 sin≈1
      final mid = finite[25];
      expect(mid.y, closeTo(1, 0.05));
    });

    test('隐式模式:圆 x^2+y^2=16 的所有点都在半径 4 上', () {
      final s = _curve({
        'mode': 'implicit',
        'expression': 'x^2+y^2-16',
        'xMin': -5,
        'xMax': 5,
        'yMin': -5,
        'yMax': 5,
        'samples': 120,
      });
      final finite = s.points.where((p) => p.x.isFinite && p.y.isFinite).toList();
      expect(finite.length, greaterThan(50), reason: '圆轮廓必须有足够采样点');
      for (final p in finite) {
        expect(math.sqrt(p.x * p.x + p.y * p.y), closeTo(4, 0.05));
      }
      // 闭合圈首尾相接(无 NaN 断点,或仅尾部)
      expect(
        s.points.any((p) => p.x.isNaN),
        isFalse,
        reason: '单个闭合圆不应产生分支断点',
      );
    });

    test('隐式模式:双曲线 x^2-y^2=1 两支以 NaN 断点分隔', () {
      final s = _curve({
        'mode': 'implicit',
        'expression': 'x^2-y^2-1',
        'xMin': -5,
        'xMax': 5,
        'yMin': -5,
        'yMax': 5,
        'samples': 120,
      });
      final finite = s.points.where((p) => p.x.isFinite && p.y.isFinite).toList();
      expect(finite.length, greaterThan(50));
      // 两支分支之间必有 NaN 分隔
      expect(s.points.any((p) => p.x.isNaN), isTrue);
      // 所有有限点都在双曲线上:x²-y²≈1
      for (final p in finite) {
        expect(p.x * p.x - p.y * p.y, closeTo(1, 0.1));
      }
      // 左右两支都有点
      expect(finite.any((p) => p.x < -0.9), isTrue);
      expect(finite.any((p) => p.x > 0.9), isTrue);
    });

    test('隐式模式:椭圆 x^2/9+y^2/4=1', () {
      final s = _curve({
        'mode': 'implicit',
        'expression': 'x^2/9+y^2/4-1',
        'xMin': -4,
        'xMax': 4,
        'yMin': -3,
        'yMax': 3,
        'samples': 120,
      });
      final finite = s.points.where((p) => p.x.isFinite && p.y.isFinite).toList();
      expect(finite.length, greaterThan(50));
      for (final p in finite) {
        expect(p.x * p.x / 9 + p.y * p.y / 4, closeTo(1, 0.05));
      }
    });

    test('参数模式:椭圆 x=3cos(t), y=2sin(t)', () {
      final s = _curve({
        'mode': 'parametric',
        'exprX': '3*cos(t)',
        'exprY': '2*sin(t)',
        'xMin': 0,
        'xMax': 6.283185307179586,
        'samples': 100,
      });
      expect(s.points.length, 100);
      for (final p in s.points) {
        expect(p.x * p.x / 9 + p.y * p.y / 4, closeTo(1, 1e-3));
      }
    });

    test('隐式模式:空范围抛错(无有效值)', () {
      // x^2+y^2+1=0 无实数解
      expect(
        () => _curve({
          'mode': 'implicit',
          'expression': 'x^2+y^2+1',
          'xMin': -2,
          'xMax': 2,
          'yMin': -2,
          'yMax': 2,
          'samples': 20,
        }),
        throwsException,
      );
    });
  });

  // ==================== 隐式曲线 × 精确求交(端到端) ====================
  group('隐式曲线求交', () {
    test('圆 x^2+y^2=16 与直线 y=0 交于 (±4, 0)', () {
      final circle = _curve({
        'mode': 'implicit',
        'expression': 'x^2+y^2-16',
        'xMin': -5,
        'xMax': 5,
        'yMin': -5,
        'yMax': 5,
        'samples': 120,
      });
      final line = _curve({
        'mode': 'function',
        'expression': '0',
        'xMin': -5,
        'xMax': 5,
        'samples': 50,
      });
      final out = kExec['curve_intersect']!(_ctx(const {'name': '交点'}, inputs: {
        'in0': circle,
        'in1': line,
      }));
      final pts = (out['out0']! as md.ScatterData).points;
      expect(pts.length, 2);
      final xs = pts.map((p) => p.x).toList()..sort();
      expect(xs[0], closeTo(-4, 0.05));
      expect(xs[1], closeTo(4, 0.05));
      for (final p in pts) {
        expect(p.y, closeTo(0, 0.05));
      }
    });

    test('小数量值线段经 curve_intersect 检出精确交点', () {
      // 1e-9 量级两条交叉线段,交点 (2e-9, 2e-9)
      final a = md.SeriesData(name: 'a', points: const [
        md.Pt(0, 0),
        md.Pt(4e-9, 4e-9),
      ]);
      final b = md.SeriesData(name: 'b', points: const [
        md.Pt(0, 4e-9),
        md.Pt(4e-9, 0),
      ]);
      final out = kExec['curve_intersect']!(_ctx(const {}, inputs: {
        'in0': a,
        'in1': b,
      }));
      final pts = (out['out0']! as md.ScatterData).points;
      expect(pts.length, 1);
      expect(pts[0].x, closeTo(2e-9, 2e-11));
      expect(pts[0].y, closeTo(2e-9, 2e-11));
    });

    test('NaN 断点不参与求交(隐式多分支曲线间)', () {
      // 构造带 NaN 断点的曲线:两段平行线,与一条横线各交一点
      final a = md.SeriesData(name: 'a', points: const [
        md.Pt(0, 1),
        md.Pt(2, 1),
        md.Pt(double.nan, double.nan),
        md.Pt(0, 3),
        md.Pt(2, 3),
      ]);
      final b = md.SeriesData(name: 'b', points: const [
        md.Pt(0, 0),
        md.Pt(2, 4),
      ]);
      final out = kExec['curve_intersect']!(_ctx(const {}, inputs: {
        'in0': a,
        'in1': b,
      }));
      final pts = (out['out0']! as md.ScatterData).points;
      // b 与 y=1 交于 (1,1),与 y=3 交于 (1.5,3);NaN 段不产生伪交点
      expect(pts.length, 2);
      final ys = pts.map((p) => p.y).toList()..sort();
      expect(ys[0], closeTo(1, 1e-9));
      expect(ys[1], closeTo(3, 1e-9));
    });
  });
}
