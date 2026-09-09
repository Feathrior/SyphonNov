// 数值计算工具:拟合、求导、积分、平滑、直方图等(由 React 版 utils/math.ts 移植)
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'data.dart';

final math.Random _rand = math.Random();

List<double> linspace(double a, double b, int n) {
  if (n <= 1) return [a];
  final out = <double>[];
  for (var i = 0; i < n; i++) {
    out.add(a + (b - a) * i / (n - 1));
  }
  return out;
}

List<double> arange(double a, double b, [double step = 1]) {
  final out = <double>[];
  for (var v = a; v < b; v += step) {
    out.add(v);
  }
  return out;
}

/// 高斯随机数(Box-Muller)
double gaussRand([double mean = 0, double std = 1]) {
  var u = 0.0;
  var v = 0.0;
  while (u == 0) {
    u = _rand.nextDouble();
  }
  while (v == 0) {
    v = _rand.nextDouble();
  }
  return mean + std * math.sqrt(-2 * math.log(u)) * math.cos(2 * math.pi * v);
}

class XY {
  final double x;
  final double y;
  const XY(this.x, this.y);
}

/// 数值求导:中心差分
List<XY> derivative(List<Pt> points) {
  final out = <XY>[];
  final n = points.length;
  for (var i = 0; i < n; i++) {
    final x0 = points[i].x;
    final y0 = points[i].y;
    if (i == 0 && n > 1) {
      final y1 = points[1].y;
      final x1 = points[1].x;
      out.add(XY(x0, (y1 - y0) / (x1 - x0 == 0 ? 1e-9 : x1 - x0)));
    } else if (i == n - 1 && n > 1) {
      final ym = points[n - 2].y;
      final xm = points[n - 2].x;
      out.add(XY(x0, (y0 - ym) / (x0 - xm == 0 ? 1e-9 : x0 - xm)));
    } else {
      final yp = points[i + 1].y;
      final xp = points[i + 1].x;
      final ym = points[i - 1].y;
      final xm = points[i - 1].x;
      out.add(XY(x0, (yp - ym) / (xp - xm == 0 ? 1e-9 : xp - xm)));
    }
  }
  return out;
}

/// 数值积分:梯形法则累积
List<XY> cumulativeIntegral(List<Pt> points) {
  final out = <XY>[];
  var acc = 0.0;
  out.add(XY(points[0].x, 0));
  for (var i = 1; i < points.length; i++) {
    final x0 = points[i - 1].x;
    final y0 = points[i - 1].y;
    final x1 = points[i].x;
    final y1 = points[i].y;
    acc += ((y0 + y1) / 2) * (x1 - x0);
    out.add(XY(x1, acc));
  }
  return out;
}

/// 高斯消元解线性方程组 Ax = b
List<double> solveLinear(List<List<double>> A, List<double> b) {
  final n = b.length;
  final M = List.generate(n, (i) => [...A[i], b[i]]);
  for (var col = 0; col < n; col++) {
    var pivot = col;
    for (var r = col + 1; r < n; r++) {
      if (M[r][col].abs() > M[pivot][col].abs()) pivot = r;
    }
    if (M[pivot][col].abs() < 1e-12) continue;
    final tmp = M[col];
    M[col] = M[pivot];
    M[pivot] = tmp;
    for (var r = 0; r < n; r++) {
      if (r == col) continue;
      final f = M[r][col] / M[col][col];
      for (var c = col; c <= n; c++) {
        M[r][c] -= f * M[col][c];
      }
    }
  }
  final x = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    if (M[i][i].abs() > 1e-12) x[i] = M[i][n] / M[i][i];
  }
  return x;
}

/// 多项式最小二乘拟合 y = c0 + c1*x + ... + cd*x^d
List<double> polyFit(List<double> xs, List<double> ys, int degree) {
  final d = degree + 1;
  final A = List.generate(d, (_) => List<double>.filled(d, 0));
  final b = List<double>.filled(d, 0);
  final n = xs.length;
  for (var i = 0; i < n; i++) {
    var pw = 1.0;
    final powers = <double>[];
    for (var p = 0; p < d; p++) {
      powers.add(pw);
      pw *= xs[i];
    }
    for (var r = 0; r < d; r++) {
      b[r] += ys[i] * powers[r];
      for (var c = 0; c < d; c++) {
        A[r][c] += powers[r] * powers[c];
      }
    }
  }
  return solveLinear(A, b);
}

double polyEval(List<double> coeffs, double x) {
  var y = 0.0;
  for (var i = coeffs.length - 1; i >= 0; i--) {
    y = y * x + coeffs[i];
  }
  return y;
}

class LinearFitResult {
  final double a;
  final double b;
  final double r2;
  const LinearFitResult(this.a, this.b, this.r2);
}

/// 线性拟合 y = a + b*x
LinearFitResult linearFit(List<double> xs, List<double> ys) {
  final n = xs.length;
  final mx = xs.reduce((s, v) => s + v) / n;
  final my = ys.reduce((s, v) => s + v) / n;
  var sxx = 0.0, sxy = 0.0, syy = 0.0;
  for (var i = 0; i < n; i++) {
    sxx += math.pow(xs[i] - mx, 2).toDouble();
    sxy += (xs[i] - mx) * (ys[i] - my);
    syy += math.pow(ys[i] - my, 2).toDouble();
  }
  final b = sxx != 0 ? sxy / sxx : 0.0;
  final a = my - b * mx;
  final r2 = (sxx != 0 && syy != 0) ? (sxy * sxy) / (sxx * syy) : 0.0;
  return LinearFitResult(a, b, r2);
}

class ExpoFitResult {
  final double a;
  final double b;
  final double r2;
  const ExpoFitResult(this.a, this.b, this.r2);
}

/// 指数拟合 y = a * exp(b*x),取对数后线性拟合
ExpoFitResult? exponentialFit(List<double> xs, List<double> ys) {
  final lx = <double>[];
  final ly = <double>[];
  for (var i = 0; i < xs.length; i++) {
    if (ys[i] > 0) {
      lx.add(xs[i]);
      ly.add(math.log(ys[i]));
    }
  }
  if (lx.length < 2) return null;
  final fit = linearFit(lx, ly);
  return ExpoFitResult(math.exp(fit.a), fit.b, fit.r2);
}

/// 滑动平均平滑
List<Pt> movingAverage(List<Pt> points, int window) {
  final w = math.max(1, window);
  final out = <Pt>[];
  for (var i = 0; i < points.length; i++) {
    final lo = i - w;
    final hi = i + w;
    var sum = 0.0;
    var cnt = 0;
    for (var j = lo; j <= hi; j++) {
      if (j >= 0 && j < points.length) {
        sum += points[j].y;
        cnt++;
      }
    }
    out.add(Pt(points[i].x, cnt > 0 ? sum / cnt : 0));
  }
  return out;
}

class Bin {
  final double x0;
  final double x1;
  final int count;
  const Bin(this.x0, this.x1, this.count);
}

/// 直方图
List<Bin> histogram(List<double> values, int bins) {
  if (values.isEmpty) return [];
  final b = math.max(2, bins);
  final mn = values.reduce(math.min);
  final mx = values.reduce(math.max);
  final width = mx - mn;
  if (width == 0) {
    return [Bin(mn - 0.5, mn + 0.5, values.length)];
  }
  final step = width / b;
  final counts = List<int>.filled(b, 0);
  for (final v in values) {
    var idx = ((v - mn) / step).floor();
    if (idx >= b) idx = b - 1;
    if (idx < 0) idx = 0;
    counts[idx]++;
  }
  return List.generate(
    b,
    (i) => Bin(mn + i * step, mn + (i + 1) * step, counts[i]),
  );
}

String fmt(double v, [int digits = 4]) {
  if (!v.isFinite) return '$v';
  return v.toStringAsFixed(digits).replaceFirst(RegExp(r'\.?0+$'), '');
}

// ==================== 精确有理数 ====================
// 每个有限 double 都是"二进有理数"(m × 2^e),可用 BigInt 分子/分母精确表示。
// 曲线交点求解用它做精确几何判定:小数量值(如 1e-9 量级坐标)下,
// 浮点叉积误差会淹没平行判定/区间判定,有理化后无任何精度损失。

/// BigInt 有理数(经 [_norm] 归一化:分母恒正、自动约分)
class Frac {
  final BigInt n; // 分子(带符号)
  final BigInt d; // 分母(恒正)

  const Frac._(this.n, this.d);

  static final Frac zero = Frac._(BigInt.zero, BigInt.one);
  static final Frac one = Frac._(BigInt.one, BigInt.one);

  /// 归一化:分母转正 + gcd 约分
  static Frac _norm(BigInt n, BigInt d) {
    if (d.isNegative) {
      n = -n;
      d = -d;
    }
    final g = n == BigInt.zero ? BigInt.one : n.gcd(d);
    return Frac._(n ~/ g, d ~/ g);
  }

  Frac operator +(Frac o) => _norm(n * o.d + o.n * d, d * o.d);
  Frac operator -(Frac o) => _norm(n * o.d - o.n * d, d * o.d);
  Frac operator *(Frac o) => _norm(n * o.n, d * o.d);
  Frac operator -() => Frac._(-n, d);

  /// 除法(o 为 0 时返回 null,由调用方处理)
  Frac? div(Frac o) => o.n == BigInt.zero ? null : _norm(n * o.d, d * o.n);

  bool get isZero => n == BigInt.zero;

  /// 精确比较:a ? b → -1/0/1
  int cmp(Frac o) => (n * o.d).compareTo(o.n * d);

  /// double → 精确有理数(IEEE754 位分解:m × 2^(e-1075))
  static Frac fromDouble(double v) {
    if (v == 0.0) return zero;
    final bytes = (ByteData(8)..setFloat64(0, v)).getUint64(0);
    // 注意:getUint64 在 VM 上最高位为 1 时返回负 int,必须用无符号右移取符号位
    final sign = bytes >>> 63;
    var exp = (bytes >> 52) & 0x7FF;
    var mant = BigInt.from(bytes & 0xFFFFFFFFFFFFF);
    if (exp == 0) {
      // 次正规数:m × 2^(-1074)
      exp = 1;
    } else {
      mant |= BigInt.one << 52;
    }
    var num = mant;
    // 指数 = exp - 1075(含隐含位);正指数进分子,负指数进分母
    final e = exp - 1075;
    BigInt den = BigInt.one;
    if (e > 0) {
      num = num << e;
    } else if (e < 0) {
      den = BigInt.one << -e;
    }
    if (sign == 1) num = -num;
    return _norm(num, den);
  }

  /// 有理数 → double(最近舍入;超范围返回 ±inf)
  double toDouble() => _bigDiv(n, d);

  static double _bigDiv(BigInt a, BigInt b) {
    // 缩放到 53 位尾数再相除,避免 BigInt→int 溢出
    int shift(BigInt v) => v.bitLength > 53 ? v.bitLength - 53 : 0;
    final sa = shift(a.abs());
    final sb = shift(b.abs());
    final ma = (a.abs() >> sa).toInt().toDouble();
    final mb = (b.abs() >> sb).toInt().toDouble();
    final r = ma / mb;
    // a/b = (ma/mb) × 2^(sa-sb)
    final scale = math.pow(2.0, sa - sb).toDouble();
    final v = r * scale;
    return a.isNegative ? -v : v;
  }
}

/// 两线段精确交点(有理化几何):P1→P2 与 Q1→Q2。
/// 返回 null 表示平行/共线或无交点;命中时 t/u/交点均为精确值(最后转 double)。
({double x, double y})? exactSegIntersect(
  double p1x, double p1y,
  double p2x, double p2y,
  double q1x, double q1y,
  double q2x, double q2y,
) {
  final p1 = Frac.fromDouble(p1x), p1y_ = Frac.fromDouble(p1y);
  final r = Frac.fromDouble(p2x) - p1, rY = Frac.fromDouble(p2y) - p1y_;
  final q1f = Frac.fromDouble(q1x), q1fY = Frac.fromDouble(q1y);
  final s = Frac.fromDouble(q2x) - q1f, sY = Frac.fromDouble(q2y) - q1fY;
  // d = r × s(叉积);t = qp × s / d;u = qp × r / d
  final d = r * sY - rY * s;
  if (d.isZero) return null; // 精确平行/共线
  final qpx = q1f - p1, qpy = q1fY - p1y_;
  final t = (qpx * sY - qpy * s).div(d);
  final u = (qpx * rY - qpy * r).div(d);
  if (t == null || u == null) return null;
  // 区间判定 [0,1] 精确无误差(小数量值场景浮点常在此误判)
  final t0 = t.cmp(Frac.zero), t1 = t.cmp(Frac.one);
  final u0 = u.cmp(Frac.zero), u1 = u.cmp(Frac.one);
  if (t0 < 0 || t1 > 0 || u0 < 0 || u1 > 0) return null;
  final x = p1 + t * r;
  final y = p1y_ + t * rY;
  return (x: x.toDouble(), y: y.toDouble());
}

/// 简单数学表达式求值(支持 x/y/pi/e/sin/cos/tan/exp/log/sqrt/abs/^)
/// 返回 null 表示表达式非法
double Function(double x, double y)? compileFormula(String src) {
  var s = src
      .replaceAll('^', '**')
      .replaceAll('sin', 'SIN')
      .replaceAll('cos', 'COS')
      .replaceAll('tan', 'TAN')
      .replaceAll('exp', 'EXP')
      .replaceAll('log10', 'LOG10')
      .replaceAll('log', 'LOG')
      .replaceAll('sqrt', 'SQRT')
      .replaceAll('abs', 'ABS')
      .replaceAll(RegExp('pi', caseSensitive: false), 'PI')
      .replaceAll('e', 'E');
  try {
    final parser = _ExprParser(s);
    final fn = parser.parse();
    return (x, y) {
      final v = fn(x, y);
      return v.isFinite ? v : double.nan;
    };
  } catch (_) {
    return null;
  }
}

// 简单递归下降表达式解析器
class _ExprParser {
  final String src;
  int _pos = 0;
  _ExprParser(this.src);

  double Function(double, double) parse() {
    final e = _parseExpr();
    return e;
  }

  double Function(double, double) _parseExpr() {
    var left = _parseTerm();
    while (true) {
      _skipWs(); // 运算符前允许空格(修复 '4 - x' 被解析成常数 4 的问题)
      if (_pos >= src.length) break;
      final ch = src[_pos];
      if (ch == '+' || ch == '-') {
        _pos++;
        final right = _parseTerm();
        final l = left;
        if (ch == '+') {
          left = (x, y) => l(x, y) + right(x, y);
        } else {
          left = (x, y) => l(x, y) - right(x, y);
        }
      } else {
        break;
      }
    }
    return left;
  }

  double Function(double, double) _parseTerm() {
    var left = _parseFactor();
    while (true) {
      _skipWs(); // 运算符前允许空格
      if (_pos >= src.length) break;
      final ch = src[_pos];
      if (ch == '*' && _pos + 1 < src.length && src[_pos + 1] == '*') {
        // 幂(优先于单个乘号检测)
        _pos += 2;
        final right = _parseFactor();
        final l = left;
        left = (x, y) => math.pow(l(x, y), right(x, y)).toDouble();
      } else if (ch == '*' || ch == '/') {
        _pos++;
        final right = _parseFactor();
        final l = left;
        if (ch == '*') {
          left = (x, y) => l(x, y) * right(x, y);
        } else {
          left = (x, y) => l(x, y) / right(x, y);
        }
      } else {
        break;
      }
    }
    return left;
  }

  double Function(double, double) _parseFactor() {
    _skipWs();
    if (_pos >= src.length) throw const FormatException('unexpected end');
    final ch = src[_pos];
    if (ch == '(') {
      _pos++;
      final inner = _parseExpr();
      _skipWs();
      if (_pos < src.length && src[_pos] == ')') _pos++;
      return inner;
    }
    if (ch == '-') {
      _pos++;
      final inner = _parseFactor();
      return (x, y) => -inner(x, y);
    }
    if (ch == '+') {
      _pos++;
      return _parseFactor();
    }
    // 数字
    final code = ch.codeUnitAt(0);
    if (ch == '.' || (code >= 0x30 && code <= 0x39)) {
      final start = _pos;
      while (_pos < src.length &&
          (src[_pos] == '.' ||
              ((src[_pos].codeUnitAt(0) >= 0x30 &&
                  src[_pos].codeUnitAt(0) <= 0x39)) ||
              src[_pos] == 'e' ||
              src[_pos] == 'E')) {
        _pos++;
      }
      final numStr = src.substring(start, _pos);
      final v = double.tryParse(numStr);
      if (v == null) throw const FormatException('bad number');
      return (x, y) => v;
    }
    // 标识符:函数 / 常量 / 变量
    if (RegExp(r'[a-zA-Z]').hasMatch(ch)) {
      final start = _pos;
      while (_pos < src.length && RegExp(r'[a-zA-Z0-9]').hasMatch(src[_pos])) {
        _pos++;
      }
      final id = src.substring(start, _pos).toUpperCase();
      _skipWs();
      if (_pos < src.length && src[_pos] == '(') {
        _pos++;
        final inner = _parseExpr();
        _skipWs();
        if (_pos < src.length && src[_pos] == ')') _pos++;
        switch (id) {
          case 'SIN':
            return (x, y) => math.sin(inner(x, y));
          case 'COS':
            return (x, y) => math.cos(inner(x, y));
          case 'TAN':
            return (x, y) => math.tan(inner(x, y));
          case 'EXP':
            return (x, y) => math.exp(inner(x, y));
          case 'LOG10':
            return (x, y) => math.log(inner(x, y)) / math.ln10;
          case 'LOG':
            return (x, y) => math.log(inner(x, y));
          case 'SQRT':
            return (x, y) => math.sqrt(inner(x, y));
          case 'ABS':
            return (x, y) => inner(x, y).abs();
          case 'PI':
            return (x, y) => math.pi * inner(x, y);
          default:
            throw const FormatException('unknown function');
        }
      }
      switch (id) {
        case 'PI':
          return (x, y) => math.pi;
        case 'E':
          return (x, y) => math.e;
        case 'X':
          return (x, y) => x;
        case 'Y':
          return (x, y) => y;
        case 'T':
          // 参数方程模式:t 作为第一参数传入(与 x 同槽位)
          return (x, y) => x;
        default:
          throw const FormatException('unknown identifier');
      }
    }
    throw const FormatException('unexpected char');
  }

  void _skipWs() {
    while (_pos < src.length && src[_pos] == ' ') {
      _pos++;
    }
  }
}
