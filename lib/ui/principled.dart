// 原理化输出:3D/2D 场景 Canvas 渲染(坐标轴盒/网格/刻度/图元/文本/色带/导出 PNG)
// (由 React 版 ViewerRender.tsx 的 PrincipledCanvas 移植)
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/material.dart';

import '../models/color_utils.dart';
import '../models/data.dart';
import '../models/exec_engine.dart';
import '../store/graph_store.dart';
import 'viewer.dart' show savePngImage;

// ==================== 3D 数学 ====================

Vec3 _rotate(Vec3 p, double rotX, double rotY) {
  final rx = rotX * math.pi / 180;
  final ry = rotY * math.pi / 180;
  final x = p.x;
  final y = p.y;
  final z = p.z;
  final x1 = x * math.cos(ry) + z * math.sin(ry);
  final z1 = -x * math.sin(ry) + z * math.cos(ry);
  final y2 = y * math.cos(rx) - z1 * math.sin(rx);
  final z2 = y * math.sin(rx) + z1 * math.cos(rx);
  return Vec3(x1, y2, z2);
}

class _DrawCtx {
  final double w;
  final double h;
  final double scale;
  final double ox;
  final double oy;
  final double rotX;
  final double rotY;
  final bool ortho2d;
  const _DrawCtx(this.w, this.h, this.scale, this.ox, this.oy, this.rotX, this.rotY,
      {this.ortho2d = false});
}

Offset _project(_DrawCtx d, Vec3 p) {
  if (d.ortho2d) return Offset(d.ox + p.x * d.scale, d.oy - p.y * d.scale);
  final r = _rotate(p, d.rotX, d.rotY);
  return Offset(d.ox + r.x * d.scale, d.oy - r.y * d.scale);
}

/// math.max/min 返回 num,这里统一转 double 以便直接用于 Canvas 参数
double _mx(num a, num b) => (a > b ? a : b).toDouble();
double _mn(num a, num b) => (a < b ? a : b).toDouble();

// ==================== 坐标系 ====================

class _AxesInfo {
  final int dim;
  final double xLen, yLen, zLen;
  final double xMin, xMax, yMin, yMax, zMin, zMax;
  final bool grid;
  final String axisOrigin;
  final bool showBorder;
  final String labelX, labelY, labelZ;
  final String? colorX, colorY, colorZ;
  final double widthX, widthY, widthZ;
  final bool gridX, gridY, gridZ;
  final double fontSize;
  final String fontFamily;
  final bool arrowX, arrowY;

  const _AxesInfo({
    required this.dim,
    required this.xLen,
    required this.yLen,
    required this.zLen,
    required this.xMin,
    required this.xMax,
    required this.yMin,
    required this.yMax,
    required this.zMin,
    required this.zMax,
    required this.grid,
    required this.axisOrigin,
    required this.showBorder,
    required this.labelX,
    required this.labelY,
    required this.labelZ,
    this.colorX,
    this.colorY,
    this.colorZ,
    required this.widthX,
    required this.widthY,
    required this.widthZ,
    required this.gridX,
    required this.gridY,
    required this.gridZ,
    required this.fontSize,
    required this.fontFamily,
    required this.arrowX,
    required this.arrowY,
  });
}

_AxesInfo _resolveAxes(DataObject? input) {
  if (input is AxesData) {
    final xMin = input.xMin.isFinite ? input.xMin : 0.0;
    final xMax = input.xMax.isFinite && input.xMax > xMin ? input.xMax : xMin + 10.0;
    final yMin = input.yMin.isFinite ? input.yMin : 0.0;
    final yMax = input.yMax.isFinite && input.yMax > yMin ? input.yMax : yMin + 10.0;
    final zMin = input.zMin.isFinite ? input.zMin : -5.0;
    final zMax = input.zMax.isFinite && input.zMax > zMin ? input.zMax : zMin + 10.0;
    return _AxesInfo(
      dim: input.dim == 2 ? 2 : 3,
      xLen: _mx(input.xLen, 0.1),
      yLen: _mx(input.yLen, 0.1),
      zLen: _mx(input.zLen, 0.1),
      xMin: xMin,
      xMax: xMax,
      yMin: yMin,
      yMax: yMax,
      zMin: zMin,
      zMax: zMax,
      grid: input.grid,
      axisOrigin: input.axisOrigin == 'left' ? 'left' : 'origin',
      showBorder: input.showBorder,
      labelX: input.labelX.isEmpty ? 'X' : input.labelX,
      labelY: input.labelY.isEmpty ? 'Y' : input.labelY,
      labelZ: input.labelZ.isEmpty ? 'Z' : input.labelZ,
      colorX: input.axisColors?.x,
      colorY: input.axisColors?.y,
      colorZ: input.axisColors?.z,
      widthX: _mx(0.02, input.axisWidths?.x ?? 0.12),
      widthY: _mx(0.02, input.axisWidths?.y ?? 0.12),
      widthZ: _mx(0.02, input.axisWidths?.z ?? 0.12),
      gridX: input.gridX,
      gridY: input.gridY,
      gridZ: input.gridZ,
      fontSize: _mx(6, _mn(24, input.fontSize)),
      fontFamily: input.fontFamily.isEmpty ? 'sans-serif' : input.fontFamily,
      arrowX: input.arrows?.x ?? true,
      arrowY: input.arrows?.y ?? true,
    );
  }
  return const _AxesInfo(
    dim: 3,
    xLen: 10,
    yLen: 8,
    zLen: 6,
    xMin: -5,
    xMax: 5,
    yMin: -5,
    yMax: 5,
    zMin: -5,
    zMax: 5,
    grid: true,
    axisOrigin: 'origin',
    showBorder: true,
    labelX: 'X',
    labelY: 'Y',
    labelZ: 'Z',
    widthX: 0.12,
    widthY: 0.12,
    widthZ: 0.12,
    gridX: true,
    gridY: true,
    gridZ: true,
    fontSize: 10,
    fontFamily: 'sans-serif',
    arrowX: true,
    arrowY: true,
  );
}

int _targetCount(double cmLen) => _mx(3, _mn(10, (cmLen / 2).round())).toInt();

({List<double> ticks, double step}) _niceTicks(double min, double max, int targetCount) {
  final span = max - min;
  if (!span.isFinite || span <= 1e-9) return (ticks: [min], step: 1);
  final raw = span / _mx(1, targetCount);
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final norm = raw / mag;
  double step;
  if (norm < 1.5) {
    step = 1;
  } else if (norm < 3.5) {
    step = 2;
  } else if (norm < 7.5) {
    step = 5;
  } else {
    step = 10;
  }
  step *= mag;
  final ticks = <double>[];
  final first = (min / step - 1e-9).ceil() * step;
  for (var v = first; v <= max + step * 1e-6; v += step) {
    ticks.add(double.parse(v.toStringAsFixed(10)));
  }
  if (ticks.isEmpty) ticks.add(min);
  return (ticks: ticks, step: step);
}

String _fmtTick(double v, double step) {
  if (!v.isFinite) return '';
  if (v.abs() < 1e-9) v = 0;
  final dec = step >= 1 ? 0 : _mn(6, _mx(0, (-math.log(step) / math.ln10).ceil())).toInt();
  return double.parse(v.toStringAsFixed(dec)).toString();
}

// ==================== 绘制 ====================

void _pText(Canvas canvas, String text, Offset pos,
    {Color color = const Color(0xFF333333),
    double size = 11,
    String align = 'center',
    String baseline = 'middle',
    double maxWidth = 800}) {
  if (text.isEmpty) return;
  final tp = TextPainter(
    text: TextSpan(text: text, style: TextStyle(color: color, fontSize: size)),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: maxWidth);
  var x = pos.dx;
  if (align == 'center') x -= tp.width / 2;
  if (align == 'right') x -= tp.width;
  var y = pos.dy;
  if (baseline == 'top') y = pos.dy;
  if (baseline == 'bottom') y = pos.dy - tp.height;
  if (baseline == 'middle') y = pos.dy - tp.height / 2;
  tp.paint(canvas, Offset(x, y));
}

Path _dashPath(Offset a, Offset b, List<double> dash) {
  final p = Path();
  final d = (b - a).distance;
  if (d <= 0) return p;
  final dir = (b - a) / d;
  var pos = 0.0;
  var idx = 0;
  var drawing = true;
  p.moveTo(a.dx, a.dy);
  while (pos < d) {
    final len = _mn(dash[idx], d - pos);
    if (drawing) {
      p.lineTo(a.dx + dir.dx * (pos + len), a.dy + dir.dy * (pos + len));
    } else {
      p.moveTo(a.dx + dir.dx * (pos + len), a.dy + dir.dy * (pos + len));
    }
    pos += len;
    idx = (idx + 1) % dash.length;
    drawing = !drawing;
  }
  return p;
}

/// 在 p2 处绘制实心三角箭头(方向沿 p1→p2,size 为箭头长度)
void _drawArrow(Canvas canvas, Offset p1, Offset p2, double size, Color color) {
  final ang = math.atan2(p2.dy - p1.dy, p2.dx - p1.dx);
  final path = Path()
    ..moveTo(p2.dx, p2.dy)
    ..lineTo(p2.dx - size * math.cos(ang - 0.42), p2.dy - size * math.sin(ang - 0.42))
    ..lineTo(p2.dx - size * math.cos(ang + 0.42), p2.dy - size * math.sin(ang + 0.42))
    ..close();
  canvas.drawPath(path, Paint()..color = color);
}

/// 按形状绘制一个点(以 size 为半径)
void _drawShapeFilled(Canvas canvas, String shape, Offset c, double size, Color color) {
  final path = Path();
  switch (shape) {
    case 'square':
      path.addRect(Rect.fromLTWH(c.dx - size, c.dy - size, size * 2, size * 2));
      break;
    case 'diamond':
      path
        ..moveTo(c.dx, c.dy - size * 1.4)
        ..lineTo(c.dx + size * 1.4, c.dy)
        ..lineTo(c.dx, c.dy + size * 1.4)
        ..lineTo(c.dx - size * 1.4, c.dy)
        ..close();
      break;
    case 'triangle':
      path
        ..moveTo(c.dx, c.dy - size * 1.6)
        ..lineTo(c.dx + size * 1.4, c.dy + size * 1.1)
        ..lineTo(c.dx - size * 1.4, c.dy + size * 1.1)
        ..close();
      break;
    default:
      path.addOval(Rect.fromCircle(center: c, radius: size));
  }
  canvas.drawPath(path, Paint()..color = color);
}

// ==================== 场景绘制 ====================

class PrincipledPainter extends CustomPainter {
  final Map<String, dynamic> params;
  final ExecResult? result;
  /// 导出像素尺寸;null 时按容器 contain 适配
  final Size? fixedSize;

  PrincipledPainter({required this.params, this.result, this.fixedSize});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final inputs = result?.inputs ?? const <String, DataObject?>{};
    final multi = result?.multiInputs ?? const <String, List<DataObject>>{};
    final C = presetColors(params);
    final rotX = toNum(params['rotX']) ?? -20;
    final rotY = toNum(params['rotY']) ?? 25;
    final axes = _resolveAxes(inputs['in4']);

    final scatterList = _collect(inputs, multi, 'in0').whereType<ScatterData>().toList();
    final seriesList = _collect(inputs, multi, 'in1').whereType<SeriesData>().toList();
    final meshList = _collect(inputs, multi, 'in2').whereType<MeshData>().toList();
    final textList = _collect(inputs, multi, 'in5').whereType<TextData>().toList();
    final dist = inputs['in3'];
    final hasData = scatterList.isNotEmpty ||
        seriesList.isNotEmpty ||
        meshList.isNotEmpty ||
        dist != null ||
        textList.isNotEmpty;

    final mapP = _buildMapper(axes);
    final b = _projectBounds(axes, rotX, rotY);

    // 画布 contain 适配(预览时按导出宽高比居中贴合;导出时直接全幅)
    final canvasW = fixedSize?.width ?? size.width;
    final canvasH = fixedSize?.height ?? size.height;
    if (fixedSize != null) {
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0, 0, canvasW, canvasH));
    } else {
      final exportW = (toNum(params['canvasPxW']) ?? 1920).toDouble();
      final exportH = (toNum(params['canvasPxH']) ?? 1200).toDouble();
      final ratio = exportH / exportW;
      var cw = size.width;
      var ch = cw * ratio;
      if (ch > size.height) {
        ch = size.height;
        cw = ch / ratio;
      }
      canvas.save();
      canvas.clipRect(
          Rect.fromCenter(center: Offset(size.width / 2, size.height / 2), width: cw, height: ch));
    }

    final fz = _mx(0.5, _mn(canvasW, canvasH) / 187.5);
    final pad = _mx(34, 24 * fz);
    final scale = _mn((canvasW - 2 * pad) / _mx(b.max.dx - b.min.dx, 1),
        (canvasH - 2 * pad) / _mx(b.max.dy - b.min.dy, 1));
    final d = _DrawCtx(canvasW, canvasH, scale, canvasW / 2, canvasH / 2, rotX, rotY,
        ortho2d: axes.dim == 2);

    // 背景
    canvas.drawRect(Rect.fromLTWH(0, 0, canvasW, canvasH), Paint()..color = parseColor(C.bg));

    // 网格
    if (axes.grid) _drawGrid(canvas, d, axes, mapP, C);
    // 边界边框
    if (axes.showBorder) _drawBoxBorder(canvas, d, axes, mapP, fz, C);

    if (!hasData) {
      _drawAxes(canvas, d, axes, mapP, C);
      _pText(canvas, '无输入数据', Offset(canvasW / 2, canvasH / 2),
          color: const Color(0xFF94A3B8), size: _mx(6, 12 * fz));
      canvas.restore();
      return;
    }

    // 网格面 / 分布柱(坐标映射为场景三角形)
    final meshTris = _buildMeshTris(meshList, mapP);
    final distTris = _buildDistTris(dist, axes, mapP);

    // 分布(最底层)
    if (distTris.isNotEmpty) _drawTris(canvas, d, distTris, C.dist, false, 1, true);

    // 面
    if (meshTris.isNotEmpty) {
      final wire = params['wireframe'] == true;
      final fill = params['fillFaces'] != false;
      final opacity = (toNum(params['faceOpacity']) ?? 0.85).clamp(0.0, 1.0);
      _drawTris(canvas, d, meshTris, C.face, wire, opacity, fill);
    }

    // 线 / 点 / 文本
    _drawSeries(canvas, d, seriesList, mapP, fz, C);
    _drawScatter(canvas, d, scatterList, mapP, fz, C);
    if (textList.isNotEmpty) _drawTexts(canvas, d, textList, mapP, axes, fz, b, scale, C);

    // 坐标轴与刻度(最后绘制)
    _drawAxes(canvas, d, axes, mapP, C);
    canvas.restore();
  }

  /// 收集某个输入端口的全部数据(多路输入合并,单路包装为单元素列表)
  List<DataObject> _collect(Map<String, DataObject?> inputs,
      Map<String, List<DataObject>> multi, String key) {
    final m = multi[key];
    if (m != null && m.isNotEmpty) return m;
    final s = inputs[key];
    return s == null ? [] : [s];
  }

  /// 世界坐标 → 以原点为中心的场景坐标映射
  Vec3 Function(Vec3) _buildMapper(_AxesInfo axes) {
    final hx = axes.xLen / 2;
    final hy = axes.yLen / 2;
    final hz = axes.zLen / 2;
    final sx = axes.xLen / _mx(axes.xMax - axes.xMin, 1e-9);
    final sy = axes.yLen / _mx(axes.yMax - axes.yMin, 1e-9);
    final sz = axes.zLen / _mx(axes.zMax - axes.zMin, 1e-9);
    return (Vec3 p) => Vec3((p.x - axes.xMin) * sx - hx, (p.y - axes.yMin) * sy - hy,
        (p.z - axes.zMin) * sz - hz);
  }

  /// 计算场景角点投影后的屏幕包围盒
  ({Offset min, Offset max}) _projectBounds(_AxesInfo axes, double rotX, double rotY) {
    final hx = axes.xLen / 2;
    final hy = axes.yLen / 2;
    final hz = axes.zLen / 2;
    final corners = <Vec3>[];
    if (axes.dim == 2) {
      corners.addAll([
        Vec3(-hx, -hy, 0),
        Vec3(hx, -hy, 0),
        Vec3(hx, hy, 0),
        Vec3(-hx, hy, 0),
      ]);
    } else {
      for (final x in [-hx, hx]) {
        for (final y in [-hy, hy]) {
          for (final z in [-hz, hz]) {
            corners.add(Vec3(x, y, z));
          }
        }
      }
    }
    final tmp = _DrawCtx(1, 1, 1, 0, 0, rotX, rotY, ortho2d: axes.dim == 2);
    var pMinX = double.infinity, pMinY = double.infinity;
    var pMaxX = -double.infinity, pMaxY = -double.infinity;
    for (final c in corners) {
      final p = _project(tmp, c);
      pMinX = _mn(pMinX, p.dx);
      pMaxX = _mx(pMaxX, p.dx);
      pMinY = _mn(pMinY, p.dy);
      pMaxY = _mx(pMaxY, p.dy);
    }
    return (min: Offset(pMinX, pMinY), max: Offset(pMaxX, pMaxY));
  }

  /// 底平面网格线
  void _drawGrid(Canvas canvas, _DrawCtx d, _AxesInfo axes, Vec3 Function(Vec3) mapP,
      PresetColors C) {
    final gridPaint = Paint()
      ..color = parseColor(C.grid)
      ..strokeWidth = _mx(0.5, _fzFor(d));
    final path = Path();
    if (axes.dim == 3) {
      final xt = _niceTicks(axes.xMin, axes.xMax, _targetCount(axes.xLen)).ticks;
      final zt = _niceTicks(axes.zMin, axes.zMax, _targetCount(axes.zLen)).ticks;
      if (axes.gridX) {
        for (final t in xt) {
          final a = _project(d, mapP(Vec3(t, axes.yMin, axes.zMin)));
          final b = _project(d, mapP(Vec3(t, axes.yMin, axes.zMax)));
          path.moveTo(a.dx, a.dy);
          path.lineTo(b.dx, b.dy);
        }
      }
      if (axes.gridZ) {
        for (final t in zt) {
          final a = _project(d, mapP(Vec3(axes.xMin, axes.yMin, t)));
          final b = _project(d, mapP(Vec3(axes.xMax, axes.yMin, t)));
          path.moveTo(a.dx, a.dy);
          path.lineTo(b.dx, b.dy);
        }
      }
    } else {
      final xt = _niceTicks(axes.xMin, axes.xMax, _targetCount(axes.xLen)).ticks;
      final yt = _niceTicks(axes.yMin, axes.yMax, _targetCount(axes.yLen)).ticks;
      if (axes.gridX) {
        for (final t in xt) {
          final a = _project(d, mapP(Vec3(t, axes.yMin, 0)));
          final b = _project(d, mapP(Vec3(t, axes.yMax, 0)));
          path.moveTo(a.dx, a.dy);
          path.lineTo(b.dx, b.dy);
        }
      }
      if (axes.gridY) {
        for (final t in yt) {
          final a = _project(d, mapP(Vec3(axes.xMin, t, 0)));
          final b = _project(d, mapP(Vec3(axes.xMax, t, 0)));
          path.moveTo(a.dx, a.dy);
          path.lineTo(b.dx, b.dy);
        }
      }
    }
    canvas.drawPath(path, gridPaint);
  }

  /// 场景包围盒边框
  void _drawBoxBorder(Canvas canvas, _DrawCtx d, _AxesInfo axes, Vec3 Function(Vec3) mapP,
      double fz, PresetColors C) {
    final hx = axes.xLen / 2;
    final hy = axes.yLen / 2;
    final hz = axes.zLen / 2;
    final boxEdges = <List<Vec3>>[];
    if (axes.dim == 3) {
      boxEdges.addAll([
        [Vec3(-hx, -hy, -hz), Vec3(hx, -hy, -hz)],
        [Vec3(-hx, -hy, -hz), Vec3(-hx, hy, -hz)],
        [Vec3(-hx, -hy, -hz), Vec3(-hx, -hy, hz)],
        [Vec3(hx, -hy, -hz), Vec3(hx, hy, -hz)],
        [Vec3(hx, -hy, -hz), Vec3(hx, -hy, hz)],
        [Vec3(-hx, hy, -hz), Vec3(hx, hy, -hz)],
        [Vec3(-hx, hy, -hz), Vec3(-hx, hy, hz)],
        [Vec3(-hx, -hy, hz), Vec3(hx, -hy, hz)],
        [Vec3(-hx, -hy, hz), Vec3(-hx, hy, hz)],
        [Vec3(hx, hy, -hz), Vec3(hx, hy, hz)],
        [Vec3(hx, -hy, hz), Vec3(hx, hy, hz)],
        [Vec3(-hx, hy, hz), Vec3(hx, hy, hz)],
      ]);
    } else {
      boxEdges.addAll([
        [Vec3(-hx, -hy, 0), Vec3(hx, -hy, 0)],
        [Vec3(hx, -hy, 0), Vec3(hx, hy, 0)],
        [Vec3(hx, hy, 0), Vec3(-hx, hy, 0)],
        [Vec3(-hx, hy, 0), Vec3(-hx, -hy, 0)],
      ]);
    }
    final bp = Path();
    for (final e in boxEdges) {
      final a = _project(d, e[0]);
      final b = _project(d, e[1]);
      bp.moveTo(a.dx, a.dy);
      bp.lineTo(b.dx, b.dy);
    }
    canvas.drawPath(bp, Paint()
      ..color = parseColor(C.axis).withValues(alpha: 0.55)
      ..strokeWidth = 1.2 * fz
      ..style = PaintingStyle.stroke);
  }

  /// 网格面 → 场景三角形
  List<List<Vec3>> _buildMeshTris(List<MeshData> meshList, Vec3 Function(Vec3) mapP) {
    final raw = <List<Vec3>>[];
    for (final mesh in meshList) {
      for (final f in mesh.faces) {
        if (f.length < 3) continue;
        final v0 = mesh.vertices.length > f[0] ? mesh.vertices[f[0]] : null;
        final v1 = mesh.vertices.length > f[1] ? mesh.vertices[f[1]] : null;
        final v2 = mesh.vertices.length > f[2] ? mesh.vertices[f[2]] : null;
        if (v0 != null && v1 != null && v2 != null) raw.add([v0, v1, v2]);
      }
    }
    return raw.map((t) => t.map(mapP).toList()).toList();
  }

  /// 分布柱 → 场景三角形(每柱两个三角面)
  List<List<Vec3>> _buildDistTris(
      DataObject? dist, _AxesInfo axes, Vec3 Function(Vec3) mapP) {
    final raw = <List<Vec3>>[];
    if (dist is DistributionData) {
      final maxC = dist.bins.map((b) => b.count).fold<double>(1.0, (a, b) => _mx(a, b));
      final hScale = ((axes.yMax - axes.yMin) * 0.8) / maxC;
      final baseY = axes.yMin;
      for (final b in dist.bins) {
        final mid = (b.x0 + b.x1) / 2;
        final half = _mx((b.x1 - b.x0) / 2, (axes.xMax - axes.xMin) * 0.01);
        final hgt = b.count * hScale;
        final x0 = mid - half;
        final x1 = mid + half;
        final a = Vec3(x0, baseY, 0);
        final b1 = Vec3(x1, baseY, 0);
        final c1 = Vec3(x1, baseY + hgt, 0);
        final d1 = Vec3(x0, baseY + hgt, 0);
        raw.add([a, b1, c1]);
        raw.add([a, c1, d1]);
      }
    }
    return raw.map((t) => t.map(mapP).toList()).toList();
  }

  /// 曲线系列绘制(单点退化为圆点,虚线走 dash path)
  void _drawSeries(Canvas canvas, _DrawCtx d, List<SeriesData> seriesList,
      Vec3 Function(Vec3) mapP, double fz, PresetColors C) {
    for (final sr in seriesList) {
      final baseW = _mx(0.5, sr.lineWidth ?? 1);
      final baseC = (sr.lineColor ?? '').isEmpty ? C.line : sr.lineColor!;
      final style = (sr.lineStyle ?? '').isEmpty ? 'solid' : sr.lineStyle!;
      final pts = sr.points;
      if (pts.isEmpty) continue;
      if (pts.length == 1) {
        final sp = _project(d, mapP(Vec3(pts[0].x, pts[0].y, 0)));
        final col = (sr.colors ?? const []).isNotEmpty ? sr.colors![0] : baseC;
        final sz = _mx(1.5, ((sr.sizes ?? const []).isNotEmpty ? sr.sizes![0] : baseW) * fz * 0.9);
        _drawShapeFilled(canvas, 'circle', sp, sz, parseColor(col));
        continue;
      }
      final dash = style == 'dashed' ? [7.0, 5.0] : <double>[];
      for (var i = 0; i < pts.length - 1; i++) {
        final w = _mx(0.4,
            ((sr.sizes ?? const []).isNotEmpty && i < (sr.sizes?.length ?? 0) ? sr.sizes![i] : baseW) * fz);
        final c = (sr.colors ?? const []).isNotEmpty && i < (sr.colors?.length ?? 0) ? sr.colors![i] : baseC;
        final a = _project(d, mapP(Vec3(pts[i].x, pts[i].y, 0)));
        final b = _project(d, mapP(Vec3(pts[i + 1].x, pts[i + 1].y, 0)));
        final pp = Paint()
          ..color = parseColor(c)
          ..strokeWidth = w
          ..style = PaintingStyle.stroke;
        if (dash.isNotEmpty) {
          canvas.drawPath(_dashPath(a, b, dash), pp);
        } else {
          canvas.drawLine(a, b, pp);
        }
      }
    }
  }

  /// 散点绘制
  void _drawScatter(Canvas canvas, _DrawCtx d, List<ScatterData> scatterList,
      Vec3 Function(Vec3) mapP, double fz, PresetColors C) {
    for (final sc in scatterList) {
      final baseSize = _mx(1, sc.pointSize ?? 2);
      final baseColor = (sc.pointColor ?? '').isEmpty ? C.point : sc.pointColor!;
      final baseShape = (sc.pointShape ?? '').isEmpty ? 'circle' : sc.pointShape!;
      final n = _mn(6000, sc.points.length);
      for (var i = 0; i < n; i++) {
        final p = sc.points[i];
        final sz = _mx(0.5,
            ((sc.sizes ?? const []).isNotEmpty && i < (sc.sizes?.length ?? 0) ? sc.sizes![i] : baseSize) * fz);
        final col = (sc.colors ?? const []).isNotEmpty && i < (sc.colors?.length ?? 0) ? sc.colors![i] : baseColor;
        final shp =
            (sc.shapes ?? const []).isNotEmpty && i < (sc.shapes?.length ?? 0) ? sc.shapes![i] : baseShape;
        final sp = _project(d, mapP(Vec3(p.x, p.y, p.z ?? 0)));
        _drawShapeFilled(canvas, shp, sp, sz, parseColor(col));
      }
    }
  }

  /// 文本绘制(可选背景块)
  void _drawTexts(Canvas canvas, _DrawCtx d, List<TextData> textList, Vec3 Function(Vec3) mapP,
      _AxesInfo axes, double fz, ({Offset min, Offset max}) b, double scale, PresetColors C) {
    final hx = axes.xLen / 2;
    final hy = axes.yLen / 2;
    final pxPerCm = ((_mx(b.max.dx - b.min.dx, 1) * scale) / _mx(axes.xLen, 0.01)) * 0.62;
    for (final txt in textList) {
      final ax = txt.halign == 'left' ? -hx : txt.halign == 'right' ? hx : 0.0;
      final ay = txt.valign == 'top' ? hy : txt.valign == 'bottom' ? -hy : 0.0;
      final pp = _project(d, mapP(Vec3(ax, ay, 0)));
      final fontPx = _mx(6, txt.fontSize * pxPerCm);
      if (txt.bgColor != null && txt.bgColor!.isNotEmpty) {
        final tp = TextPainter(
          text: TextSpan(text: txt.text, style: TextStyle(fontSize: fontPx)),
          textDirection: TextDirection.ltr,
        )..layout();
        final tw = tp.width;
        final th = fontPx * 1.45;
        var bx = txt.halign == 'left'
            ? pp.dx
            : txt.halign == 'right'
                ? pp.dx - tw
                : pp.dx - tw / 2;
        var by = txt.valign == 'top'
            ? pp.dy
            : txt.valign == 'bottom'
                ? pp.dy - th
                : pp.dy - th / 2;
        canvas.drawRect(Rect.fromLTWH(bx - 4, by - 2, tw + 8, th + 4), Paint()..color = parseColor(txt.bgColor!));
      }
      _pText(canvas, txt.text, pp,
          color: parseColor(txt.textColor.isEmpty ? '#333333' : txt.textColor),
          size: fontPx,
          align: txt.halign,
          baseline: txt.valign);
    }
  }

  void _drawTris(Canvas canvas, _DrawCtx d, List<List<Vec3>> tris, String color,
      bool wire, double opacity, bool fill) {
    final sorted = tris.map((t) {
      final zAvg = (_rotate(t[0], d.rotX, d.rotY).z +
              _rotate(t[1], d.rotX, d.rotY).z +
              _rotate(t[2], d.rotX, d.rotY).z) /
          3;
      return (t: t, zAvg: zAvg);
    }).toList()
      ..sort((a, b) => a.zAvg.compareTo(b.zAvg));
    final fillColor = fill ? parseColor(color) : null;
    final strokeColor = wire ? parseColor(color) : null;
    for (final s in sorted) {
      final t = s.t;
      final a = _project(d, t[0]);
      final b = _project(d, t[1]);
      final c = _project(d, t[2]);
      final path = Path()
        ..moveTo(a.dx, a.dy)
        ..lineTo(b.dx, b.dy)
        ..lineTo(c.dx, c.dy)
        ..close();
      if (fillColor != null) {
        canvas.drawPath(path, Paint()
          ..color = fillColor.withValues(alpha: opacity));
      }
      if (strokeColor != null) {
        canvas.drawPath(path, Paint()
          ..color = strokeColor.withValues(alpha: opacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = _mx(0.5, _fzFor(d)));
      }
    }
  }

  double _fzFor(_DrawCtx d) => _mx(0.5, _mn(d.w, d.h) / 187.5);

  /// 坐标轴、刻度(自动)与数字标注(2D 正交 / 3D 过盒中心)
  void _drawAxes(Canvas canvas, _DrawCtx d, _AxesInfo axes, Vec3 Function(Vec3) mapP,
      PresetColors C) {
    final cx = axes.colorX == null ? C.axis : axes.colorX!;
    final cy = axes.colorY == null ? C.axis : axes.colorY!;
    final cz = axes.colorZ == null ? C.axis : axes.colorZ!;
    if (axes.dim == 2) {
      _drawAxes2D(canvas, d, axes, mapP, cx, cy);
    } else {
      _drawAxes3D(canvas, d, axes, mapP, cx, cy, cz);
    }
  }

  /// 2D 正交坐标轴:轴线 + 刻度 + 标签 + 箭头
  void _drawAxes2D(Canvas canvas, _DrawCtx d, _AxesInfo axes, Vec3 Function(Vec3) mapP,
      String cx, String cy) {
    final fz = _fzFor(d);
    double fontPx(double base) => _mx(6, (base * fz).roundToDouble());
    double aw(double cm) => _mx(0.5, cm * d.scale);
    final axisXY = axes.axisOrigin == 'origin' && 0.0 >= axes.yMin && 0.0 <= axes.yMax ? 0.0 : axes.yMin;
    final axisYX = axes.axisOrigin == 'origin' && 0.0 >= axes.xMin && 0.0 <= axes.xMax ? 0.0 : axes.xMin;
    // X 轴
    final x1 = _project(d, mapP(Vec3(axes.xMin, axisXY, 0)));
    final x2 = _project(d, mapP(Vec3(axes.xMax, axisXY, 0)));
    canvas.drawLine(x1, x2, Paint()
      ..color = parseColor(cx)
      ..strokeWidth = aw(axes.widthX));
    // Y 轴
    final y1 = _project(d, mapP(Vec3(axisYX, axes.yMin, 0)));
    final y2 = _project(d, mapP(Vec3(axisYX, axes.yMax, 0)));
    canvas.drawLine(y1, y2, Paint()
      ..color = parseColor(cy)
      ..strokeWidth = aw(axes.widthY));

    final tickPaint = Paint()
      ..color = parseColor(cx)
      ..strokeWidth = _mx(1, fz);
    final xt = _niceTicks(axes.xMin, axes.xMax, _targetCount(axes.xLen));
    for (final t in xt.ticks) {
      final p = _project(d, mapP(Vec3(t, axisXY, 0)));
      canvas.drawLine(Offset(p.dx, p.dy - 4 * fz), Offset(p.dx, p.dy + 4 * fz), tickPaint);
      _pText(canvas, _fmtTick(t, xt.step), Offset(p.dx, p.dy + 14 * fz),
          color: parseColor(cx), size: fontPx(axes.fontSize));
    }
    final tickYPaint = Paint()
      ..color = parseColor(cy)
      ..strokeWidth = _mx(1, fz);
    final yt = _niceTicks(axes.yMin, axes.yMax, _targetCount(axes.yLen));
    for (final t in yt.ticks) {
      final p = _project(d, mapP(Vec3(axisYX, t, 0)));
      canvas.drawLine(Offset(p.dx - 4 * fz, p.dy), Offset(p.dx + 4 * fz, p.dy), tickYPaint);
      _pText(canvas, _fmtTick(t, yt.step), Offset(p.dx - 6 * fz, p.dy + 3 * fz),
          color: parseColor(cy), size: fontPx(axes.fontSize), align: 'right');
    }
    // 轴标签
    final xLab = _project(d, mapP(Vec3(axes.xMax, axisXY, 0)));
    final yLab = _project(d, mapP(Vec3(axisYX, axes.yMax, 0)));
    if (axes.axisOrigin == 'left') {
      final xMid = _project(d, mapP(Vec3((axes.xMin + axes.xMax) / 2, axisXY, 0)));
      final yMid = _project(d, mapP(Vec3(axisYX, (axes.yMin + axes.yMax) / 2, 0)));
      _pText(canvas, axes.labelX, Offset(xMid.dx, xMid.dy + 26 * fz),
          color: parseColor(cx), size: fontPx(axes.fontSize + 2));
      canvas.save();
      canvas.translate(yMid.dx - 24 * fz, yMid.dy);
      canvas.rotate(-math.pi / 2);
      _pText(canvas, axes.labelY, Offset.zero,
          color: parseColor(cy), size: fontPx(axes.fontSize + 2));
      canvas.restore();
    } else {
      _pText(canvas, axes.labelX, Offset(xLab.dx, xLab.dy - 6 * fz),
          color: parseColor(cx), size: fontPx(axes.fontSize + 2));
      _pText(canvas, axes.labelY, Offset(yLab.dx + 8 * fz, yLab.dy),
          color: parseColor(cy), size: fontPx(axes.fontSize + 2));
    }
    // 末端箭头
    if (axes.arrowX) {
      final p0 = _project(d, mapP(Vec3(axes.xMax - (axes.xMax - axes.xMin) * 0.08, axisXY, 0)));
      _drawArrow(canvas, p0, xLab, 8 * fz, parseColor(cx));
    }
    if (axes.arrowY) {
      final p0 = _project(d, mapP(Vec3(axisYX, axes.yMax - (axes.yMax - axes.yMin) * 0.08, 0)));
      _drawArrow(canvas, p0, yLab, 8 * fz, parseColor(cy));
    }
  }

  /// 3D 坐标轴:三条轴线 + 刻度 + 标签 + 箭头
  void _drawAxes3D(Canvas canvas, _DrawCtx d, _AxesInfo axes, Vec3 Function(Vec3) mapP,
      String cx, String cy, String cz) {
    final fz = _fzFor(d);
    double fontPx(double base) => _mx(6, (base * fz).roundToDouble());
    double aw(double cm) => _mx(0.5, cm * d.scale);
    final hx = axes.xLen / 2;
    final hy = axes.yLen / 2;
    final hz = axes.zLen / 2;
    final off = (0.05 * _mn(axes.xLen, _mn(axes.yLen, axes.zLen))) / 2;
    final ends = <(Vec3, String, int)>[
      (Vec3(hx + off, 0, 0), axes.labelX, 0),
      (Vec3(0, hy + off, 0), axes.labelY, 1),
      (Vec3(0, 0, hz + off), axes.labelZ, 2),
    ];
    final ranges = <(double, double)>[(axes.xMin, axes.xMax), (axes.yMin, axes.yMax), (axes.zMin, axes.zMax)];
    final scales = <double>[
      axes.xLen / _mx(axes.xMax - axes.xMin, 1e-9),
      axes.yLen / _mx(axes.yMax - axes.yMin, 1e-9),
      axes.zLen / _mx(axes.zMax - axes.zMin, 1e-9),
    ];
    final lengths = <double>[axes.xLen, axes.yLen, axes.zLen];
    final axisColors = <String>[cx, cy, cz];
    final axisWidthsCm = <double>[axes.widthX, axes.widthY, axes.widthZ];
    for (final e in ends) {
      _drawAxisEnd3D(canvas, d, axes, e, fz, fontPx, aw, axisColors, axisWidthsCm, scales,
          lengths, ranges);
    }
  }

  /// 单条 3D 轴:正负半轴 + 刻度数字 + 标签 + 箭头
  void _drawAxisEnd3D(Canvas canvas, _DrawCtx d, _AxesInfo axes, (Vec3, String, int) e,
      double fz, double Function(double) fontPx, double Function(double) aw,
      List<String> axisColors, List<double> axisWidthsCm, List<double> scales,
      List<double> lengths, List<(double, double)> ranges) {
    final end = e.$1;
    final label = e.$2;
    final axisIdx = e.$3;
    final o = _project(d, Vec3(0, 0, 0));
    final ep = _project(d, end);
    canvas.drawLine(o, ep, Paint()
      ..color = parseColor(axisColors[axisIdx])
      ..strokeWidth = aw(axisWidthsCm[axisIdx]));
    // 负半轴
    final np = _project(d, Vec3(-end.x, -end.y, -end.z));
    canvas.drawLine(o, np, Paint()
      ..color = parseColor(axisColors[axisIdx]).withValues(alpha: 0.35)
      ..strokeWidth = _mx(0.5, aw(axisWidthsCm[axisIdx]) * 0.5));
    // 刻度 + 数字
    final rMin = ranges[axisIdx].$1;
    final rMax = ranges[axisIdx].$2;
    final tk = _niceTicks(rMin, rMax, _targetCount(lengths[axisIdx]));
    final dx = ep.dx - o.dx;
    final dy = ep.dy - o.dy;
    final L = math.sqrt(dx * dx + dy * dy);
    if (L > 1e-9) {
      final px = -dy / L;
      final py = dx / L;
      final tickPaint = Paint()
        ..color = parseColor(axisColors[axisIdx]).withValues(alpha: 0.7)
        ..strokeWidth = _mx(1, fz);
      for (final t in tk.ticks) {
        final loc = (t - rMin) * scales[axisIdx] - lengths[axisIdx] / 2;
        final tickVec = axisIdx == 0
            ? Vec3(loc, 0, 0)
            : axisIdx == 1
                ? Vec3(0, loc, 0)
                : Vec3(0, 0, loc);
        final tp = _project(d, tickVec);
        canvas.drawLine(Offset(tp.dx - px * 3.5 * fz, tp.dy - py * 3.5 * fz),
            Offset(tp.dx + px * 3.5 * fz, tp.dy + py * 3.5 * fz), tickPaint);
        _pText(canvas, _fmtTick(t, tk.step),
            Offset(tp.dx + (dx / L) * 12 * fz, tp.dy + (dy / L) * 12 * fz - 2 * fz),
            color: parseColor(axisColors[axisIdx]), size: fontPx(axes.fontSize - 1));
      }
    }
    // 标签
    _pText(canvas, label, Offset(ep.dx, ep.dy - 6 * fz),
        color: parseColor(axisColors[axisIdx]), size: fontPx(axes.fontSize + 2));
    // 末端箭头(X/Y)
    if ((axisIdx == 0 && axes.arrowX) || (axisIdx == 1 && axes.arrowY)) {
      _drawArrow(canvas, o, ep, 8 * fz, parseColor(axisColors[axisIdx]));
    }
  }

  @override
  bool shouldRepaint(covariant PrincipledPainter old) =>
      old.params != params ||
      old.result != result ||
      old.fixedSize != fixedSize;
}

// ==================== 预览组件 ====================

/// 原理化输出预览窗:滚轮缩放 / 拖拽平移 / 初始化 / 导出 PNG
class PrincipledCanvas extends StatefulWidget {
  final String nodeId;
  const PrincipledCanvas({super.key, required this.nodeId});

  @override
  State<PrincipledCanvas> createState() => _PrincipledCanvasState();
}

class _PrincipledCanvasState extends State<PrincipledCanvas> {
  double _zoom = 1;
  Offset _pan = Offset.zero;
  Offset? _dragStart;
  Offset? _dragPan;

  void _onWheel(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final local = e.localPosition;
    final factor = e.scrollDelta.dy < 0 ? 1.12 : 1 / 1.12;
    setState(() {
      final nz = _mn(4.0, _mx(0.5, _zoom * factor));
      final f = nz / _zoom;
      _zoom = nz;
      _pan = Offset(local.dx - (local.dx - _pan.dx) * f, local.dy - (local.dy - _pan.dy) * f);
    });
  }

  void _reset() {
    setState(() {
      _zoom = 1;
      _pan = Offset.zero;
    });
  }

  Future<void> _export() async {
    final node = GraphStore.instance.nodes.where((n) => n.id == widget.nodeId).toList();
    final result = GraphStore.instance.results[widget.nodeId];
    if (node.isEmpty) return;
    final params = node.first.params;
    final w = (toNum(params['canvasPxW']) ?? 1920).round().clamp(100, 12000);
    final h = (toNum(params['canvasPxH']) ?? 1200).round().clamp(100, 12000);
    final painter = PrincipledPainter(params: params, result: result, fixedSize: Size(w.toDouble(), h.toDouble()));
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    painter.paint(canvas, Size(w.toDouble(), h.toDouble()));
    final img = await recorder.endRecording().toImage(w, h);
    await savePngImage(img, 'principled.png');
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: GraphStore.instance,
      builder: (context, _) {
        final node = GraphStore.instance.nodes.where((n) => n.id == widget.nodeId).toList();
        final result = GraphStore.instance.results[widget.nodeId];
        if (node.isEmpty) return const SizedBox.shrink();
        return Stack(
          children: [
            Positioned.fill(child: _buildCanvasArea(node.first.params, result)),
            Positioned(left: 8, bottom: 6, child: _buildControls()),
          ],
        );
      },
    );
  }

  /// 画布主体:滚轮缩放监听 + 拖拽平移 + 缩放变换 + 绘制
  Widget _buildCanvasArea(Map<String, dynamic> params, ExecResult? result) {
    return Listener(
      onPointerSignal: _onWheel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (d) {
          _dragStart = d.localPosition;
          _dragPan = _pan;
        },
        onPanUpdate: (d) {
          final s = _dragStart;
          if (s == null) return;
          setState(() {
            _pan = _dragPan! + (d.localPosition - s);
          });
        },
        onPanEnd: (_) => _dragStart = null,
        onPanCancel: () => _dragStart = null,
        child: ClipRect(
          child: Transform(
            transform: Matrix4.identity()
              ..translateByDouble(_pan.dx, _pan.dy, 0, 1)
              ..scaleByDouble(_zoom, _zoom, 1, 1),
            alignment: Alignment.topLeft,
            child: CustomPaint(
              size: Size.infinite,
              painter: PrincipledPainter(params: params, result: result),
            ),
          ),
        ),
      ),
    );
  }

  /// 左下角控制条:缩放百分比 + 初始化 + 导出 PNG
  Widget _buildControls() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('${(_zoom * 100).round()}%',
            style: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8))),
        const SizedBox(width: 8),
        _miniBtn('初始化', _reset),
        const SizedBox(width: 6),
        _miniBtn('导出 PNG', _export),
      ],
    );
  }

  Widget _miniBtn(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xFF2563EB),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(label, style: const TextStyle(fontSize: 10, color: Colors.white)),
      ),
    );
  }
}
