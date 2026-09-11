// 数值计算工具:拟合、求导、积分、平滑、直方图等(由 React 版 utils/math.ts 移植)
library;

import 'dart:math' as math;



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

void _validateGrid(List<Pt> points) {
  for (var i = 0; i < points.length; i++) {
    if (!points[i].x.isFinite || !points[i].y.isFinite) {
      throw ArgumentError('坐标必须为有限数值');
    }
    if (i > 0 && points[i].x <= points[i - 1].x) {
      throw ArgumentError('X 必须严格递增；请先排序并处理重复 X');
    }
  }
}

/// 内点使用非均匀网格三点差分；端点保持一阶单边差分。
List<XY> derivative(List<Pt> points) {
  if (points.isEmpty) return [];
  if (points.length < 2) throw ArgumentError('求导至少需要两个不同 X 的点');
  _validateGrid(points);
  final out = <XY>[];
  final n = points.length;
  for (var i = 0; i < n; i++) {
    final x0 = points[i].x;
    final y0 = points[i].y;
    if (i == 0 && n > 1) {
      final y1 = points[1].y;
      final x1 = points[1].x;
      out.add(XY(x0, (y1 - y0) / (x1 - x0)));
    } else if (i == n - 1 && n > 1) {
      final ym = points[n - 2].y;
      final xm = points[n - 2].x;
      out.add(XY(x0, (y0 - ym) / (x0 - xm)));
    } else {
      final yp = points[i + 1].y;
      final xp = points[i + 1].x;
      final ym = points[i - 1].y;
      final xm = points[i - 1].x;
      final hs = x0 - xm;
      final hd = xp - x0;
      final span = hs + hd;
      out.add(
        XY(x0, (hd / span) * ((y0 - ym) / hs) + (hs / span) * ((yp - y0) / hd)),
      );
    }
  }
  return out;
}

/// 数值积分:梯形法则累积
List<XY> cumulativeIntegral(List<Pt> points) {
  if (points.isEmpty) return [];
  _validateGrid(points);
  final out = <XY>[];
  var acc = 0.0;
  var correction = 0.0;
  out.add(XY(points[0].x, 0));
  for (var i = 1; i < points.length; i++) {
    final x0 = points[i - 1].x;
    final y0 = points[i - 1].y;
    final x1 = points[i].x;
    final y1 = points[i].y;
    // Kahan 累加减少许多小梯形叠加到大面积时丢失低位。
    final area = (y0 / 2 + y1 / 2) * (x1 - x0);
    final corrected = area - correction;
    final next = acc + corrected;
    correction = (next - acc) - corrected;
    acc = next;
    out.add(XY(x1, acc));
  }
  return out;
}

/// 高斯消元解线性方程组 Ax = b
List<double> solveLinear(List<List<double>> A, List<double> b) {
  final n = b.length;
  if (n == 0 || A.length != n || A.any((row) => row.length != n)) {
    throw ArgumentError('线性方程组必须是非空方阵且维数一致');
  }
  if (A.expand((row) => row).any((v) => !v.isFinite) ||
      b.any((v) => !v.isFinite)) {
    throw ArgumentError('线性方程组包含非有限数值');
  }
  final scales = A
      .map((row) => row.fold(0.0, (s, v) => math.max(s, v.abs())))
      .toList();
  if (scales.any((v) => v == 0)) throw ArgumentError('矩阵奇异，无法唯一求解');
  final M = List.generate(n, (i) => [...A[i], b[i]]);
  for (var col = 0; col < n; col++) {
    var pivot = col;
    for (var r = col + 1; r < n; r++) {
      if (M[r][col].abs() / scales[r] > M[pivot][col].abs() / scales[pivot])
        pivot = r;
    }
    if (M[pivot][col].abs() / scales[pivot] <= 2.220446049250313e-16 * n) {
      throw ArgumentError('矩阵奇异或数值秩不足，无法可靠求解');
    }
    final tmp = M[col];
    M[col] = M[pivot];
    M[pivot] = tmp;
    final scale = scales[col];
    scales[col] = scales[pivot];
    scales[pivot] = scale;
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
    x[i] = M[i][n] / M[i][i];
  }
  if (x.any((v) => !v.isFinite)) throw ArgumentError('方程组求解超出浮点数范围');
  return x;
}

void _validateFitData(List<double> xs, List<double> ys) {
  if (xs.isEmpty || xs.length != ys.length) {
    throw ArgumentError('拟合需要等长且非空的 X/Y 数据');
  }
  if (xs.any((v) => !v.isFinite) || ys.any((v) => !v.isFinite)) {
    throw ArgumentError('拟合数据必须为有限数值');
  }
}

/// 保留中心缩放基底，绘图时避免展开成巨大系数再互相抵消。
class PolynomialFitResult {
  final double center;
  final double scale;
  final List<double> scaledCoefficients;
  const PolynomialFitResult(this.center, this.scale, this.scaledCoefficients);

  double evaluate(double x) =>
      polyEval(scaledCoefficients, (x - center) / scale);

  /// 兼容传统系数表 y = c0 + c1*x + ...；该表示本身可能病态。
  List<double> get coefficients {
    var result = <double>[scaledCoefficients.last];
    for (var i = scaledCoefficients.length - 2; i >= 0; i--) {
      final next = List<double>.filled(result.length + 1, 0);
      for (var j = 0; j < result.length; j++) {
        next[j] -= result[j] * (center / scale);
        next[j + 1] += result[j] / scale;
      }
      next[0] += scaledCoefficients[i];
      result = next;
    }
    if (result.any((v) => !v.isFinite)) {
      throw ArgumentError('原坐标多项式系数溢出，请缩放 X 后拟合');
    }
    return result;
  }
}

/// 中心缩放 Vandermonde 矩阵 + Householder QR，不形成 AᵀA。
PolynomialFitResult fitPolynomial(
  List<double> xs,
  List<double> ys,
  int degree,
) {
  _validateFitData(xs, ys);
  final n = xs.length;
  final d = degree + 1;
  if (degree < 0 || d > n || xs.toSet().length < d) {
    throw ArgumentError('d 阶拟合至少需要 d+1 个不同 X，且阶数不能为负');
  }
  final xmin = xs.reduce(math.min);
  final xmax = xs.reduce(math.max);
  final center = xmin / 2 + xmax / 2;
  final span = math.max((xmin - center).abs(), (xmax - center).abs());
  final scale = span == 0 ? 1.0 : span;
  final yScale = ys.fold(0.0, (s, v) => math.max(s, v.abs()));
  final valueScale = yScale == 0 ? 1.0 : yScale;
  final a = List.generate(n, (i) {
    final t = (xs[i] - center) / scale;
    final row = List<double>.filled(d, 1);
    for (var j = 1; j < d; j++) {
      row[j] = row[j - 1] * t;
    }
    return row;
  });
  final b = ys.map((y) => y / valueScale).toList();
  final tolerance = 2.220446049250313e-16 * math.max(n, d) * math.sqrt(n);
  for (var k = 0; k < d; k++) {
    var norm = 0.0;
    for (var i = k; i < n; i++) {
      norm += a[i][k] * a[i][k];
    }
    norm = math.sqrt(norm);
    if (norm <= tolerance) throw ArgumentError('拟合矩阵数值秩不足，请降低阶数或检查 X');
    final alpha = a[k][k] >= 0 ? -norm : norm;
    final v = [for (var i = k; i < n; i++) a[i][k]];
    v[0] -= alpha;
    final vv = v.fold(0.0, (s, value) => s + value * value);
    for (var j = k; j < d; j++) {
      var dot = 0.0;
      for (var i = k; i < n; i++) {
        dot += v[i - k] * a[i][j];
      }
      for (var i = k; i < n; i++) {
        a[i][j] -= 2 * (dot / vv) * v[i - k];
      }
    }
    var dot = 0.0;
    for (var i = k; i < n; i++) {
      dot += v[i - k] * b[i];
    }
    for (var i = k; i < n; i++) {
      b[i] -= 2 * (dot / vv) * v[i - k];
    }
    a[k][k] = alpha;
  }
  final c = List<double>.filled(d, 0);
  for (var i = d - 1; i >= 0; i--) {
    var rhs = b[i];
    for (var j = i + 1; j < d; j++) {
      rhs -= a[i][j] * c[j];
    }
    c[i] = rhs / a[i][i];
  }
  final coefficients = c.map((v) => v * valueScale).toList();
  if (coefficients.any((v) => !v.isFinite)) throw ArgumentError('拟合超出浮点数范围');
  return PolynomialFitResult(center, scale, coefficients);
}

List<double> polyFit(List<double> xs, List<double> ys, int degree) =>
    fitPolynomial(xs, ys, degree).coefficients;

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
  final double center;
  final double centeredIntercept;
  const LinearFitResult(
    this.a,
    this.b,
    this.r2, {
    this.center = 0,
    double? centeredIntercept,
  }) : centeredIntercept = centeredIntercept ?? a;
  double evaluate(double x) => centeredIntercept + b * (x - center);
}

/// 线性拟合 y = a + b*x
LinearFitResult linearFit(List<double> xs, List<double> ys) {
  final model = fitPolynomial(xs, ys, 1);
  final n = xs.length;
  final yScale = ys.fold(0.0, (s, v) => math.max(s, v.abs()));
  final scale = yScale == 0 ? 1.0 : yScale;
  final my = ys.fold(0.0, (s, v) => s + v / scale / n);
  var residual = 0.0, total = 0.0;
  for (var i = 0; i < n; i++) {
    residual += math.pow((ys[i] - model.evaluate(xs[i])) / scale, 2).toDouble();
    total += math.pow(ys[i] / scale - my, 2).toDouble();
  }
  // 常数响应的 R² 数学上未定义，以 NaN 明示，避免伪报 0/1。
  final constantResponse = ys.every((y) => y == ys.first);
  final r2 = constantResponse || total == 0 ? double.nan : 1 - residual / total;
  final coefficients = model.coefficients;
  return LinearFitResult(
    coefficients[0],
    coefficients[1],
    r2,
    center: model.center,
    centeredIntercept: model.scaledCoefficients[0],
  );
}

class ExpoFitResult {
  final double a;
  final double b;
  final double r2;
  const ExpoFitResult(this.a, this.b, this.r2);
}

/// 指数拟合 y = a * exp(b*x),取对数后线性拟合
ExpoFitResult? exponentialFit(List<double> xs, List<double> ys) {
  _validateFitData(xs, ys);
  if (ys.any((y) => y <= 0)) return null;
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

/// 简单数学表达式求值(支持 x/y/pi/e/sin/cos/tan/exp/log/sqrt/abs/^)
/// 返回 null 表示表达式非法
double Function(double x, double y)? compileFormula(String src) {
  try {
    final parser = _ExprParser(src);
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
    _skipWs();
    if (_pos != src.length)
      throw const FormatException('unexpected trailing input');
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
    var left = _parseUnary();
    while (true) {
      _skipWs(); // 运算符前允许空格
      if (_pos >= src.length) break;
      final ch = src[_pos];
      if (ch == '*' || ch == '/') {
        _pos++;
        final right = _parseUnary();
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

  // unary := ('+' | '-') unary | power
  // power := primary (('^' | '**') unary)?
  // 幂右结合且高于前置负号，同时允许 2^-3。
  double Function(double, double) _parseUnary() {
    _skipWs();
    if (_pos < src.length && (src[_pos] == '+' || src[_pos] == '-')) {
      final negative = src[_pos++] == '-';
      final inner = _parseUnary();
      return negative ? (x, y) => -inner(x, y) : inner;
    }
    return _parsePower();
  }

  double Function(double, double) _parsePower() {
    final left = _parseFactor();
    _skipWs();
    if (_pos < src.length && src[_pos] == '^') {
      _pos++;
    } else if (src.startsWith('**', _pos)) {
      _pos += 2;
    } else {
      return left;
    }
    final right = _parseUnary();
    return (x, y) => math.pow(left(x, y), right(x, y)).toDouble();
  }

  void _closeParen() {
    _skipWs();
    if (_pos >= src.length || src[_pos] != ')') {
      throw const FormatException('missing closing parenthesis');
    }
    _pos++;
  }

  double Function(double, double) _parseFactor() {
    _skipWs();
    if (_pos >= src.length) throw const FormatException('unexpected end');
    final ch = src[_pos];
    if (ch == '(') {
      _pos++;
      final inner = _parseExpr();
      _closeParen();
      return inner;
    }
    // 数字
    final code = ch.codeUnitAt(0);
    if (ch == '.' || (code >= 0x30 && code <= 0x39)) {
      final token = RegExp(r'(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?')
          .matchAsPrefix(src, _pos);
      if (token == null) throw const FormatException('bad number');
      final numStr = token.group(0)!;
      _pos = token.end;
      final v = double.tryParse(numStr);
      if (v == null || !v.isFinite) throw const FormatException('bad number');
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
        _closeParen();
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
        default:
          throw const FormatException('unknown identifier');
      }
    }
    throw const FormatException('unexpected char');
  }

  void _skipWs() {
    while (_pos < src.length && RegExp(r'\s').hasMatch(src[_pos])) {
      _pos++;
    }
  }
}

class Pt {
  final double x, y;
  const Pt(this.x, this.y);
}
void check(bool ok, String message) {
  if (!ok) throw StateError(message);
}
void main() {
  check(compileFormula('2*x^2')!(3, 0) == 18, 'precedence');
  check(compileFormula('2^3^2')!(0, 0) == 512, 'association');
  check(compileFormula('-2^-2')!(0, 0) == -.25, 'unary');
  check(compileFormula('1e-7*x')!(3, 0) == 3e-7, 'scientific');
  check(compileFormula('x junk') == null, 'trailing input');
  check(derivative([Pt(0,0),Pt(1,1),Pt(3,9)])[1].y == 2, 'nonuniform');
  final xs = List.generate(11, (i) => 1e9+i);
  final ys = xs.map((x) { final t=x-1e9; return 2+3*t+.5*t*t; }).toList();
  final model = fitPolynomial(xs,ys,2);
  check((model.evaluate(1e9+4.5)-25.625).abs() < 1e-11, 'QR');
  final lr = linearFit([1e9,1e9+1], [2,5]);
  check((lr.evaluate(1e9+.5)-3.5).abs() < 1e-12, 'linear');
  check(linearFit([0,1,2],[5,5,5]).r2.isNaN, 'R2');
  final pts = [Pt(0,1e16),Pt(1,1e16)];
  for(var i=2;i<=101;i++) { pts.add(Pt(i.toDouble(),i.isEven?-1e16+2:1e16)); }
  check(cumulativeIntegral(pts).last.y == 1e16+100, 'Kahan');
  print('Standalone source probe: 10 checks passed');
}
