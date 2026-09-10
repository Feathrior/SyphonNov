// 原理化输出:3D/2D 场景 Canvas 渲染(坐标轴盒/网格/刻度/图元/文本/色带/导出 PNG)
// (由 React 版 ViewerRender.tsx 的 PrincipledCanvas 移植)
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart'
    show PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/material.dart';

import '../models/color_utils.dart';
import '../models/data.dart';
import '../models/exec_engine.dart';
import '../models/publication_export.dart';
import '../models/scales.dart';
import '../store/graph_store.dart';
import 'viewer.dart' show savePngImage;

// ==================== 3D 数学 ====================

Vec3 _rotate(Vec3 p, double rotX, double rotY, double rotZ) {
  final rx = rotX * math.pi / 180;
  final ry = rotY * math.pi / 180;
  final rz = rotZ * math.pi / 180;
  final x = p.x;
  final y = p.y;
  final z = p.z;
  // 先绕 Y 轴,再绕 X 轴,最后绕 Z 轴
  final x1 = x * math.cos(ry) + z * math.sin(ry);
  final z1 = -x * math.sin(ry) + z * math.cos(ry);
  final y2 = y * math.cos(rx) - z1 * math.sin(rx);
  final z2 = y * math.sin(rx) + z1 * math.cos(rx);
  final x2 = x1 * math.cos(rz) - y2 * math.sin(rz);
  final y3 = x1 * math.sin(rz) + y2 * math.cos(rz);
  return Vec3(x2, y3, z2);
}

class _DrawCtx {
  final double w;
  final double h;
  final double scale;
  final double ox;
  final double oy;
  final double rotX;
  final double rotY;
  final double rotZ;
  final bool ortho2d;
  const _DrawCtx(
    this.w,
    this.h,
    this.scale,
    this.ox,
    this.oy,
    this.rotX,
    this.rotY, {
    this.rotZ = 0,
    this.ortho2d = false,
  });
}

class _SurfaceTri {
  final List<Vec3> points;
  final Color? color;
  const _SurfaceTri(this.points, this.color);
}

Offset _project(_DrawCtx d, Vec3 p) {
  if (d.ortho2d) return Offset(d.ox + p.x * d.scale, d.oy - p.y * d.scale);
  final r = _rotate(p, d.rotX, d.rotY, d.rotZ);
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
  final String xScale, yScale, zScale;
  final double symlogThreshold;
  final String legendMode, legendPosition, legendGrouping;
  final List<String> legendOrder, legendHidden;

  /// 原理化 3D 视角旋转角(度,来自坐标系输入;2D 时忽略)
  final double rotX;
  final double rotY;
  final double rotZ;

  /// 隐藏坐标系:完全不绘制坐标轴/网格/刻度/标签
  final bool hidden;

  /// 场景外观与导出(坐标系输入承担)
  final String colorPreset;
  final String bgColor;
  final double canvasPxW;
  final double canvasPxH;

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
    this.xScale = 'linear',
    this.yScale = 'linear',
    this.zScale = 'linear',
    this.symlogThreshold = 1,
    this.legendMode = 'auto',
    this.legendPosition = 'right',
    this.legendGrouping = 'type',
    this.legendOrder = const [],
    this.legendHidden = const [],
    this.rotX = -20,
    this.rotY = 25,
    this.rotZ = 0,
    this.hidden = false,
    this.colorPreset = 'paper',
    this.bgColor = '#ffffff',
    this.canvasPxW = 1920,
    this.canvasPxH = 1200,
  });
}

/// 在给定坐标盒内保持每个数据单位的物理长度一致。
({double x, double y, double z}) equalDataAspectLengths(AxesData input) {
  return equalAspectLengths(
    dim: input.dim,
    xLength: input.xLen,
    yLength: input.yLen,
    zLength: input.zLen,
    xSpan: input.xMax - input.xMin,
    ySpan: input.yMax - input.yMin,
    zSpan: input.zMax - input.zMin,
  );
}

_AxesInfo _resolveAxes(DataObject? input) {
  if (input is AxesData) {
    final xMin = input.xMin.isFinite ? input.xMin : 0.0;
    final xMax = input.xMax.isFinite && input.xMax > xMin
        ? input.xMax
        : xMin + 10.0;
    final yMin = input.yMin.isFinite ? input.yMin : 0.0;
    final yMax = input.yMax.isFinite && input.yMax > yMin
        ? input.yMax
        : yMin + 10.0;
    final zMin = input.zMin.isFinite ? input.zMin : -5.0;
    final zMax = input.zMax.isFinite && input.zMax > zMin
        ? input.zMax
        : zMin + 10.0;
    var xLen = _mx(input.xLen, 0.1);
    var yLen = _mx(input.yLen, 0.1);
    var zLen = _mx(input.zLen, 0.1);
    if (input.aspectMode == 'equal') {
      final equal = equalDataAspectLengths(input);
      xLen = equal.x;
      yLen = equal.y;
      zLen = equal.z;
    }
    return _AxesInfo(
      dim: input.dim == 2 ? 2 : 3,
      xLen: xLen,
      yLen: yLen,
      zLen: zLen,
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
      xScale: input.xScale,
      yScale: input.yScale,
      zScale: input.zScale,
      symlogThreshold: input.symlogThreshold,
      legendMode: input.legendMode,
      legendPosition: input.legendPosition,
      legendGrouping: input.legendGrouping,
      legendOrder: input.legendOrder,
      legendHidden: input.legendHidden,
      // 视角旋转随坐标系输入(原理化 3D 旋转)
      rotX: input.rotX.isFinite ? input.rotX : -20,
      rotY: input.rotY.isFinite ? input.rotY : 25,
      rotZ: input.rotZ.isFinite ? input.rotZ : 0,
      // 场景外观与导出(坐标系输入承担)
      colorPreset: input.colorPreset.isEmpty ? 'paper' : input.colorPreset,
      bgColor: input.bgColor.isEmpty ? '#ffffff' : input.bgColor,
      canvasPxW: _mx(100, input.canvasPxW.isFinite ? input.canvasPxW : 1920),
      canvasPxH: _mx(100, input.canvasPxH.isFinite ? input.canvasPxH : 1200),
      hidden: input.hidden == true,
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

// ==================== 绘制 ====================

void _pText(
  Canvas canvas,
  String text,
  Offset pos, {
  Color color = const Color(0xFF333333),
  double size = 11,
  String align = 'center',
  String baseline = 'middle',
  double maxWidth = 800,
}) {
  if (text.isEmpty) return;
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(color: color, fontSize: size),
    ),
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
    ..lineTo(
      p2.dx - size * math.cos(ang - 0.42),
      p2.dy - size * math.sin(ang - 0.42),
    )
    ..lineTo(
      p2.dx - size * math.cos(ang + 0.42),
      p2.dy - size * math.sin(ang + 0.42),
    )
    ..close();
  canvas.drawPath(path, Paint()..color = color);
}

/// 按形状绘制一个点(以 size 为半径)
void _drawShapeFilled(
  Canvas canvas,
  String shape,
  Offset c,
  double size,
  Color color,
) {
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
    // 新架构坐标系在 in0;兼容旧图(坐标系接在 in4)
    final axInput = inputs['in0'] ?? inputs['in4'];
    final axes = _resolveAxes(axInput);
    // 视角旋转随坐标系输入(原理化 3D 旋转);保留旧画布参数兜底
    final rotX = toNum(params['rotX']) ?? axes.rotX;
    final rotY = toNum(params['rotY']) ?? axes.rotY;
    final rotZ = toNum(params['rotZ']) ?? axes.rotZ;
    // 场景外观随坐标系输入(原原理化输出承担)
    final C = presetColors({
      'colorPreset': axes.colorPreset,
      'bgColor': axes.bgColor,
    });

    // 点/线/面/分布/文本图元由坐标系输入携带
    final scatterList = axInput is AxesData
        ? axInput.points
        : const <ScatterData>[];
    final seriesList = axInput is AxesData
        ? axInput.lines
        : const <SeriesData>[];
    final meshList = axInput is AxesData ? axInput.meshes : const <MeshData>[];
    final textList = axInput is AxesData ? axInput.texts : const <TextData>[];
    final dist = axInput is AxesData ? axInput.dist : inputs['in3'];
    final hasData =
        scatterList.isNotEmpty ||
        seriesList.isNotEmpty ||
        meshList.isNotEmpty ||
        dist != null ||
        textList.isNotEmpty;

    final mapP = _buildMapper(axes);
    final b = _projectBounds(axes, rotX, rotY, rotZ);

    // 画布 contain 适配(预览时按导出宽高比居中贴合;导出时直接全幅)
    final canvasW = fixedSize?.width ?? size.width;
    final canvasH = fixedSize?.height ?? size.height;
    if (fixedSize != null) {
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0, 0, canvasW, canvasH));
    } else {
      final exportW = axes.canvasPxW;
      final exportH = axes.canvasPxH;
      final ratio = exportH / exportW;
      var cw = size.width;
      var ch = cw * ratio;
      if (ch > size.height) {
        ch = size.height;
        cw = ch / ratio;
      }
      canvas.save();
      canvas.clipRect(
        Rect.fromCenter(
          center: Offset(size.width / 2, size.height / 2),
          width: cw,
          height: ch,
        ),
      );
    }

    final fz = _mx(0.5, _mn(canvasW, canvasH) / 187.5);
    final pad = _mx(34, 24 * fz);
    final scale = _mn(
      (canvasW - 2 * pad) / _mx(b.max.dx - b.min.dx, 1),
      (canvasH - 2 * pad) / _mx(b.max.dy - b.min.dy, 1),
    );
    final d = _DrawCtx(
      canvasW,
      canvasH,
      scale,
      canvasW / 2,
      canvasH / 2,
      rotX,
      rotY,
      rotZ: rotZ,
      ortho2d: axes.dim == 2,
    );

    // 背景
    canvas.drawRect(
      Rect.fromLTWH(0, 0, canvasW, canvasH),
      Paint()..color = parseColor(C.bg),
    );

    // 网格 / 边界边框 / 坐标轴(隐藏坐标系时全部跳过,仅保留场景图元)
    if (!axes.hidden) {
      if (axes.grid) _drawGrid(canvas, d, axes, mapP, C);
      if (axes.showBorder) _drawBoxBorder(canvas, d, axes, mapP, fz, C);
    }

    if (!hasData) {
      if (!axes.hidden) _drawAxes(canvas, d, axes, mapP, C);
      _pText(
        canvas,
        '无输入数据',
        Offset(canvasW / 2, canvasH / 2),
        color: const Color(0xFF94A3B8),
        size: _mx(6, 12 * fz),
      );
      canvas.restore();
      return;
    }

    // 面 / 分布柱(坐标映射为场景三角形)
    final distTris = _buildDistTris(dist, axes, mapP);

    // 分布(最底层)
    if (distTris.isNotEmpty) {
      _drawTris(canvas, d, distTris, C.dist, false, 1, true);
    }

    // 曲面:预览可使用拓扑感知的确定性 LOD；导出始终遍历全量面。
    if (meshList.isNotEmpty) {
      for (final mesh in meshList) {
        final tris = _meshTris(mesh, mapP, preview: fixedSize == null);
        if (tris.isEmpty) continue;
        final wireframe = mesh.wireframe == true;
        final fill = mesh.fill ?? true;
        final color = (mesh.color ?? '').isEmpty ? C.face : mesh.color!;
        final opacity = (mesh.opacity ?? 0.85).clamp(0.0, 1.0);
        // 线框模式:画全部三角形边线;否则仅按"显示边缘线"描边
        final showEdge = mesh.showEdge ?? true;
        final wire = wireframe || showEdge;
        final edgeColor = (mesh.edgeColor ?? '').isEmpty
            ? color
            : mesh.edgeColor!;
        _drawSurfaceTris(
          canvas,
          d,
          tris,
          color,
          wire,
          opacity,
          fill,
          edgeColor,
          mesh.doubleSided ?? true,
        );
      }
    }

    // 线 / 点 / 文本
    _drawSeries(canvas, d, seriesList, mapP, fz, C);
    _drawScatter(canvas, d, scatterList, mapP, fz, C);
    if (textList.isNotEmpty) {
      _drawTexts(canvas, d, textList, mapP, axes, fz, b, scale, C);
    }

    // 坐标轴与刻度(最后绘制;隐藏坐标系时不绘制)
    if (!axes.hidden) _drawAxes(canvas, d, axes, mapP, C);
    _drawLegend(canvas, size, axes, seriesList, scatterList, meshList, C);
    canvas.restore();
  }

  /// 世界坐标 → 以原点为中心的场景坐标映射
  Vec3 Function(Vec3) _buildMapper(_AxesInfo axes) {
    final hx = axes.xLen / 2;
    final hy = axes.yLen / 2;
    final hz = axes.zLen / 2;
    final xs = AxisScale.named(
      axes.xScale,
      axes.xMin,
      axes.xMax,
      linearThreshold: axes.symlogThreshold,
    );
    final ys = AxisScale.named(
      axes.yScale,
      axes.yMin,
      axes.yMax,
      linearThreshold: axes.symlogThreshold,
    );
    final zs = AxisScale.named(
      axes.zScale,
      axes.zMin,
      axes.zMax,
      linearThreshold: axes.symlogThreshold,
    );
    return (Vec3 p) => Vec3(
      xs.transform(p.x) * axes.xLen - hx,
      ys.transform(p.y) * axes.yLen - hy,
      zs.transform(p.z) * axes.zLen - hz,
    );
  }

  void _drawLegend(
    Canvas canvas,
    Size size,
    _AxesInfo axes,
    List<SeriesData> lines,
    List<ScatterData> points,
    List<MeshData> meshes,
    PresetColors colors,
  ) {
    if (axes.legendMode == 'hidden') return;
    var items =
        <({String name, String color, String kind})>[
              for (final line in lines)
                (
                  name: line.name,
                  color: line.lineColor ?? colors.line,
                  kind: 'line',
                ),
              for (final point in points)
                (
                  name: point.name,
                  color: point.pointColor ?? colors.point,
                  kind: 'point',
                ),
              for (final mesh in meshes)
                (
                  name: mesh.name,
                  color: mesh.color ?? colors.face,
                  kind: 'surface',
                ),
            ]
            .where(
              (item) =>
                  item.name.trim().isNotEmpty &&
                  !axes.legendHidden.contains(item.name),
            )
            .toList();
    if (axes.legendMode == 'manual') {
      int rank(String name) {
        final i = axes.legendOrder.indexOf(name);
        return i < 0 ? 1 << 20 : i;
      }

      items.sort((a, b) => rank(a.name).compareTo(rank(b.name)));
    } else if (axes.legendGrouping == 'type') {
      const rank = {'line': 0, 'point': 1, 'surface': 2};
      items.sort((a, b) => (rank[a.kind] ?? 9).compareTo(rank[b.kind] ?? 9));
    }
    if (items.isEmpty) return;
    const row = 18.0, width = 150.0, pad = 8.0;
    final height = items.length * row + pad * 2;
    final left = axes.legendPosition == 'left'
        ? 12.0
        : axes.legendPosition == 'bottom'
        ? (size.width - width) / 2
        : size.width - width - 12;
    final top = axes.legendPosition == 'bottom'
        ? size.height - height - 12
        : 12.0;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, width, height),
        const Radius.circular(4),
      ),
      Paint()..color = parseColor(colors.bg).withValues(alpha: .86),
    );
    for (var i = 0; i < items.length; i++) {
      final item = items[i], y = top + pad + i * row + row / 2;
      final paint = Paint()
        ..color = parseColor(item.color)
        ..strokeWidth = 2;
      if (item.kind == 'line') {
        canvas.drawLine(Offset(left + 8, y), Offset(left + 28, y), paint);
      } else if (item.kind == 'point') {
        canvas.drawCircle(Offset(left + 18, y), 3, paint);
      } else {
        canvas.drawRect(
          Rect.fromCenter(center: Offset(left + 18, y), width: 18, height: 8),
          paint,
        );
      }
      _pText(
        canvas,
        item.name,
        Offset(left + 36, y),
        color: parseColor(colors.axis),
        size: 10,
        align: 'left',
        maxWidth: width - 44,
      );
    }
  }

  List<ScaleTick> _ticks(
    String kind,
    double min,
    double max,
    double length,
    double threshold,
  ) => AxisScale.named(
    kind,
    min,
    max,
    linearThreshold: threshold,
  ).ticks(_targetCount(length));

  /// 计算场景角点投影后的屏幕包围盒
  ({Offset min, Offset max}) _projectBounds(
    _AxesInfo axes,
    double rotX,
    double rotY,
    double rotZ,
  ) {
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
    final tmp = _DrawCtx(
      1,
      1,
      1,
      0,
      0,
      rotX,
      rotY,
      rotZ: rotZ,
      ortho2d: axes.dim == 2,
    );
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
  void _drawGrid(
    Canvas canvas,
    _DrawCtx d,
    _AxesInfo axes,
    Vec3 Function(Vec3) mapP,
    PresetColors C,
  ) {
    final gridPaint = Paint()
      ..color = parseColor(C.grid)
      ..strokeWidth = _mx(0.5, _fzFor(d));
    final path = Path();
    if (axes.dim == 3) {
      final xt = _ticks(
        axes.xScale,
        axes.xMin,
        axes.xMax,
        axes.xLen,
        axes.symlogThreshold,
      );
      final zt = _ticks(
        axes.zScale,
        axes.zMin,
        axes.zMax,
        axes.zLen,
        axes.symlogThreshold,
      );
      final yt = _ticks(
        axes.yScale,
        axes.yMin,
        axes.yMax,
        axes.yLen,
        axes.symlogThreshold,
      );
      void add(Vec3 a, Vec3 b) {
        final pa = _project(d, mapP(a));
        final pb = _project(d, mapP(b));
        if (!pa.dx.isFinite ||
            !pa.dy.isFinite ||
            !pb.dx.isFinite ||
            !pb.dy.isFinite) {
          return;
        }
        path.moveTo(pa.dx, pa.dy);
        path.lineTo(pb.dx, pb.dy);
      }

      if (axes.gridX) {
        for (final t in xt) {
          add(
            Vec3(t.value, axes.yMin, axes.zMin),
            Vec3(t.value, axes.yMin, axes.zMax),
          );
          add(
            Vec3(t.value, axes.yMin, axes.zMin),
            Vec3(t.value, axes.yMax, axes.zMin),
          );
        }
      }
      if (axes.gridY) {
        for (final t in yt) {
          add(
            Vec3(axes.xMin, t.value, axes.zMin),
            Vec3(axes.xMax, t.value, axes.zMin),
          );
          add(
            Vec3(axes.xMin, t.value, axes.zMin),
            Vec3(axes.xMin, t.value, axes.zMax),
          );
        }
      }
      if (axes.gridZ) {
        for (final t in zt) {
          add(
            Vec3(axes.xMin, axes.yMin, t.value),
            Vec3(axes.xMax, axes.yMin, t.value),
          );
          add(
            Vec3(axes.xMin, axes.yMin, t.value),
            Vec3(axes.xMin, axes.yMax, t.value),
          );
        }
      }
    } else {
      final xt = _ticks(
        axes.xScale,
        axes.xMin,
        axes.xMax,
        axes.xLen,
        axes.symlogThreshold,
      );
      final yt = _ticks(
        axes.yScale,
        axes.yMin,
        axes.yMax,
        axes.yLen,
        axes.symlogThreshold,
      );
      if (axes.gridX) {
        for (final t in xt) {
          final a = _project(d, mapP(Vec3(t.value, axes.yMin, 0)));
          final b = _project(d, mapP(Vec3(t.value, axes.yMax, 0)));
          path.moveTo(a.dx, a.dy);
          path.lineTo(b.dx, b.dy);
        }
      }
      if (axes.gridY) {
        for (final t in yt) {
          final a = _project(d, mapP(Vec3(axes.xMin, t.value, 0)));
          final b = _project(d, mapP(Vec3(axes.xMax, t.value, 0)));
          path.moveTo(a.dx, a.dy);
          path.lineTo(b.dx, b.dy);
        }
      }
    }
    canvas.drawPath(path, gridPaint);
  }

  /// 场景包围盒边框
  void _drawBoxBorder(
    Canvas canvas,
    _DrawCtx d,
    _AxesInfo axes,
    Vec3 Function(Vec3) mapP,
    double fz,
    PresetColors C,
  ) {
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
    canvas.drawPath(
      bp,
      Paint()
        ..color = parseColor(C.axis).withValues(alpha: 0.55)
        ..strokeWidth = 1.2 * fz
        ..style = PaintingStyle.stroke,
    );
  }

  /// 单个曲面网格 → 场景三角形。LOD 均匀覆盖完整面序列并保留首尾。
  List<_SurfaceTri> _meshTris(
    MeshData mesh,
    Vec3 Function(Vec3) mapP, {
    required bool preview,
  }) {
    final raw = <_SurfaceTri>[];
    final budget = preview
        ? (mesh.previewFaceBudget ?? 12000)
        : mesh.faces.length;
    final step = mesh.faces.length > budget ? mesh.faces.length / budget : 1.0;
    final selected = <int>{};
    if (step > 1) {
      for (var i = 0; i < budget; i++) {
        selected.add((i * step).floor().clamp(0, mesh.faces.length - 1));
      }
      selected.add(0);
      selected.add(mesh.faces.length - 1);
    }
    for (var faceIndex = 0; faceIndex < mesh.faces.length; faceIndex++) {
      if (step > 1 && !selected.contains(faceIndex)) continue;
      final f = mesh.faces[faceIndex];
      if (f.length < 3) continue;
      if (f.any((i) => i < 0 || i >= mesh.vertices.length)) continue;
      final vertices = [
        mesh.vertices[f[0]],
        mesh.vertices[f[1]],
        mesh.vertices[f[2]],
      ];
      if (vertices.any(
        (v) => !v.x.isFinite || !v.y.isFinite || !v.z.isFinite,
      )) {
        continue;
      }
      final mapped = vertices.map(mapP).toList();
      if (mapped.any((v) => !v.x.isFinite || !v.y.isFinite || !v.z.isFinite)) {
        continue;
      }
      Color? faceColor;
      final values = mesh.vertexValues;
      final gradient = mesh.gradient;
      final lo = mesh.valueMin, hi = mesh.valueMax;
      if (values != null &&
          gradient != null &&
          lo != null &&
          hi != null &&
          f.every((i) => i < values.length)) {
        final value = (values[f[0]] + values[f[1]] + values[f[2]]) / 3;
        if (value.isFinite) {
          final t = (hi - lo).abs() <= 1e-15 ? 0.5 : (value - lo) / (hi - lo);
          faceColor = gradientColorAt(gradient, t);
        }
      }
      raw.add(_SurfaceTri(mapped, faceColor));
    }
    return raw;
  }

  /// 分布柱 → 场景三角形(每柱两个三角面)
  List<List<Vec3>> _buildDistTris(
    DataObject? dist,
    _AxesInfo axes,
    Vec3 Function(Vec3) mapP,
  ) {
    final raw = <List<Vec3>>[];
    if (dist is DistributionData) {
      final maxC = dist.bins
          .map((b) => b.count)
          .fold<double>(1.0, (a, b) => _mx(a, b));
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
  void _drawSeries(
    Canvas canvas,
    _DrawCtx d,
    List<SeriesData> seriesList,
    Vec3 Function(Vec3) mapP,
    double fz,
    PresetColors C,
  ) {
    for (final sr in seriesList) {
      final baseW = _mx(0.5, sr.lineWidth ?? 1);
      final baseC = (sr.lineColor ?? '').isEmpty ? C.line : sr.lineColor!;
      final style = (sr.lineStyle ?? '').isEmpty ? 'solid' : sr.lineStyle!;
      final pts = sr.points;
      final zs = sr.zValues;
      if (pts.isEmpty) continue;
      final low = sr.bandLow, high = sr.bandHigh;
      if (low != null && high != null) {
        var start = 0;
        while (start < pts.length) {
          while (start < pts.length &&
              (start >= low.length ||
                  start >= high.length ||
                  !pts[start].x.isFinite ||
                  !low[start].isFinite ||
                  !high[start].isFinite)) {
            start++;
          }
          var end = start;
          while (end < pts.length &&
              end < low.length &&
              end < high.length &&
              pts[end].x.isFinite &&
              low[end].isFinite &&
              high[end].isFinite) {
            end++;
          }
          if (end - start >= 2) {
            final upper = <Offset>[], lower = <Offset>[];
            for (var i = start; i < end; i++) {
              final up = mapP(Vec3(pts[i].x, high[i], 0));
              final lo = mapP(Vec3(pts[i].x, low[i], 0));
              if (up.x.isFinite &&
                  up.y.isFinite &&
                  lo.x.isFinite &&
                  lo.y.isFinite) {
                upper.add(_project(d, up));
                lower.add(_project(d, lo));
              }
            }
            if (upper.length >= 2 && upper.length == lower.length) {
              final path = Path()..moveTo(upper.first.dx, upper.first.dy);
              for (final p in upper.skip(1)) {
                path.lineTo(p.dx, p.dy);
              }
              for (final p in lower.reversed) {
                path.lineTo(p.dx, p.dy);
              }
              path.close();
              canvas.drawPath(
                path,
                Paint()..color = parseColor(baseC).withValues(alpha: .18),
              );
            }
          }
          start = math.max(end, start + 1);
        }
      }
      if (pts.length == 1) {
        final mapped = mapP(Vec3(pts[0].x, pts[0].y, zs?.first ?? 0));
        if (!mapped.x.isFinite || !mapped.y.isFinite || !mapped.z.isFinite) {
          continue;
        }
        final sp = _project(d, mapped);
        final col = (sr.colors ?? const []).isNotEmpty ? sr.colors![0] : baseC;
        final sz = _mx(
          1.5,
          ((sr.sizes ?? const []).isNotEmpty ? sr.sizes![0] : baseW) * fz * 0.9,
        );
        _drawShapeFilled(canvas, 'circle', sp, sz, parseColor(col));
        continue;
      }
      final dash = style == 'dashed' ? [7.0, 5.0] : <double>[];
      for (var i = 0; i < pts.length - 1; i++) {
        // NaN 断点(隐式曲线多分支分隔):断线跳过该段
        if (!pts[i].x.isFinite ||
            !pts[i].y.isFinite ||
            !pts[i + 1].x.isFinite ||
            !pts[i + 1].y.isFinite) {
          continue;
        }
        final w = _mx(
          0.4,
          ((sr.sizes ?? const []).isNotEmpty && i < (sr.sizes?.length ?? 0)
                  ? sr.sizes![i]
                  : baseW) *
              fz,
        );
        final c =
            (sr.colors ?? const []).isNotEmpty && i < (sr.colors?.length ?? 0)
            ? sr.colors![i]
            : baseC;
        final a = _project(
          d,
          mapP(
            Vec3(pts[i].x, pts[i].y, zs != null && i < zs.length ? zs[i] : 0),
          ),
        );
        final b = _project(
          d,
          mapP(
            Vec3(
              pts[i + 1].x,
              pts[i + 1].y,
              zs != null && i + 1 < zs.length ? zs[i + 1] : 0,
            ),
          ),
        );
        if (![a.dx, a.dy, b.dx, b.dy].every((v) => v.isFinite)) continue;
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
      final em = sr.xErrorMinus,
          ep = sr.xErrorPlus,
          fm = sr.yErrorMinus,
          fp = sr.yErrorPlus;
      if (em != null || ep != null || fm != null || fp != null) {
        final paint = Paint()
          ..color = parseColor(baseC)
          ..strokeWidth = _mx(.7, baseW * fz * .7);
        for (var i = 0; i < pts.length; i++) {
          final p = pts[i];
          if (!p.x.isFinite || !p.y.isFinite) continue;
          final xm = em != null && i < em.length ? em[i] : 0,
              xp = ep != null && i < ep.length ? ep[i] : xm;
          final ym = fm != null && i < fm.length ? fm[i] : 0,
              yp = fp != null && i < fp.length ? fp[i] : ym;
          if ([xm, xp, ym, yp].any((v) => !v.isFinite || v < 0)) continue;
          void bar(Vec3 va, Vec3 vb) {
            final ma = mapP(va), mb = mapP(vb);
            if ([ma.x, ma.y, mb.x, mb.y].every((v) => v.isFinite)) {
              canvas.drawLine(_project(d, ma), _project(d, mb), paint);
            }
          }

          if (xm > 0 || xp > 0) {
            bar(Vec3(p.x - xm, p.y, 0), Vec3(p.x + xp, p.y, 0));
          }
          if (ym > 0 || yp > 0) {
            bar(Vec3(p.x, p.y - ym, 0), Vec3(p.x, p.y + yp, 0));
          }
        }
      }
    }
  }

  /// 散点绘制
  void _drawScatter(
    Canvas canvas,
    _DrawCtx d,
    List<ScatterData> scatterList,
    Vec3 Function(Vec3) mapP,
    double fz,
    PresetColors C,
  ) {
    for (final sc in scatterList) {
      final baseSize = _mx(1, sc.pointSize ?? 2);
      final baseColor = (sc.pointColor ?? '').isEmpty
          ? C.point
          : sc.pointColor!;
      final baseShape = (sc.pointShape ?? '').isEmpty
          ? 'circle'
          : sc.pointShape!;
      final n = sc.points.length;
      for (var i = 0; i < n; i++) {
        final p = sc.points[i];
        final sz = _mx(
          0.5,
          ((sc.sizes ?? const []).isNotEmpty && i < (sc.sizes?.length ?? 0)
                  ? sc.sizes![i]
                  : baseSize) *
              fz,
        );
        final col =
            (sc.colors ?? const []).isNotEmpty && i < (sc.colors?.length ?? 0)
            ? sc.colors![i]
            : baseColor;
        final shp =
            (sc.shapes ?? const []).isNotEmpty && i < (sc.shapes?.length ?? 0)
            ? sc.shapes![i]
            : baseShape;
        final mapped = mapP(Vec3(p.x, p.y, p.z ?? 0));
        if (!mapped.x.isFinite || !mapped.y.isFinite || !mapped.z.isFinite) {
          continue;
        }
        final sp = _project(d, mapped);
        _drawShapeFilled(canvas, shp, sp, sz, parseColor(col));
      }
    }
  }

  /// 文本绘制(可选背景块)
  void _drawTexts(
    Canvas canvas,
    _DrawCtx d,
    List<TextData> textList,
    Vec3 Function(Vec3) mapP,
    _AxesInfo axes,
    double fz,
    ({Offset min, Offset max}) b,
    double scale,
    PresetColors C,
  ) {
    final hx = axes.xLen / 2;
    final hy = axes.yLen / 2;
    final pxPerCm =
        ((_mx(b.max.dx - b.min.dx, 1) * scale) / _mx(axes.xLen, 0.01)) * 0.62;
    for (final txt in textList) {
      final ax = txt.halign == 'left'
          ? -hx
          : txt.halign == 'right'
          ? hx
          : 0.0;
      final ay = txt.valign == 'top'
          ? hy
          : txt.valign == 'bottom'
          ? -hy
          : 0.0;
      final pp = _project(d, mapP(Vec3(ax, ay, 0)));
      final fontPx = _mx(6, txt.fontSize * pxPerCm);
      if (txt.bgColor != null && txt.bgColor!.isNotEmpty) {
        final tp = TextPainter(
          text: TextSpan(
            text: txt.text,
            style: TextStyle(fontSize: fontPx),
          ),
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
        canvas.drawRect(
          Rect.fromLTWH(bx - 4, by - 2, tw + 8, th + 4),
          Paint()..color = parseColor(txt.bgColor!),
        );
      }
      _pText(
        canvas,
        txt.text,
        pp,
        color: parseColor(txt.textColor.isEmpty ? '#333333' : txt.textColor),
        size: fontPx,
        align: txt.halign,
        baseline: txt.valign,
      );
    }
  }

  void _drawTris(
    Canvas canvas,
    _DrawCtx d,
    List<List<Vec3>> tris,
    String color,
    bool wire,
    double opacity,
    bool fill, [
    String? edgeColor,
  ]) {
    final sorted = tris.map((t) {
      final zAvg =
          (_rotate(t[0], d.rotX, d.rotY, d.rotZ).z +
              _rotate(t[1], d.rotX, d.rotY, d.rotZ).z +
              _rotate(t[2], d.rotX, d.rotY, d.rotZ).z) /
          3;
      return (t: t, zAvg: zAvg);
    }).toList()..sort((a, b) => a.zAvg.compareTo(b.zAvg));
    final fillColor = fill ? parseColor(color) : null;
    final strokeColor = wire ? parseColor(edgeColor ?? color) : null;
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
        canvas.drawPath(
          path,
          Paint()..color = fillColor.withValues(alpha: opacity),
        );
      }
      if (strokeColor != null) {
        canvas.drawPath(
          path,
          Paint()
            ..color = strokeColor.withValues(alpha: opacity)
            ..style = PaintingStyle.stroke
            ..strokeWidth = _mx(0.5, _fzFor(d)),
        );
      }
    }
  }

  void _drawSurfaceTris(
    Canvas canvas,
    _DrawCtx d,
    List<_SurfaceTri> tris,
    String color,
    bool wire,
    double opacity,
    bool fill,
    String edgeColor,
    bool doubleSided,
  ) {
    final sorted = tris.map((tri) {
      final p = tri.points;
      final depth =
          (_rotate(p[0], d.rotX, d.rotY, d.rotZ).z +
              _rotate(p[1], d.rotX, d.rotY, d.rotZ).z +
              _rotate(p[2], d.rotX, d.rotY, d.rotZ).z) /
          3;
      return (tri: tri, depth: depth);
    }).toList()..sort((a, b) => a.depth.compareTo(b.depth));
    final fallback = parseColor(color);
    final stroke = parseColor(edgeColor);
    for (final item in sorted) {
      final p = item.tri.points;
      final pa = _project(d, p[0]);
      final pb = _project(d, p[1]);
      final pc = _project(d, p[2]);
      final signedArea =
          (pb.dx - pa.dx) * (pc.dy - pa.dy) - (pb.dy - pa.dy) * (pc.dx - pa.dx);
      if (!doubleSided && signedArea >= 0) continue;
      final path = Path()
        ..moveTo(pa.dx, pa.dy)
        ..lineTo(pb.dx, pb.dy)
        ..lineTo(pc.dx, pc.dy)
        ..close();
      if (fill) {
        canvas.drawPath(
          path,
          Paint()
            ..color = (item.tri.color ?? fallback).withValues(alpha: opacity),
        );
      }
      if (wire) {
        canvas.drawPath(
          path,
          Paint()
            ..color = stroke.withValues(alpha: opacity)
            ..style = PaintingStyle.stroke
            ..strokeWidth = _mx(0.5, _fzFor(d)),
        );
      }
    }
  }

  double _fzFor(_DrawCtx d) => _mx(0.5, _mn(d.w, d.h) / 187.5);

  /// 坐标轴、刻度(自动)与数字标注(2D 正交 / 3D 过盒中心)
  void _drawAxes(
    Canvas canvas,
    _DrawCtx d,
    _AxesInfo axes,
    Vec3 Function(Vec3) mapP,
    PresetColors C,
  ) {
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
  void _drawAxes2D(
    Canvas canvas,
    _DrawCtx d,
    _AxesInfo axes,
    Vec3 Function(Vec3) mapP,
    String cx,
    String cy,
  ) {
    final fz = _fzFor(d);
    double fontPx(double base) => _mx(6, (base * fz).roundToDouble());
    double aw(double cm) => _mx(0.5, cm * d.scale);
    final axisXY =
        axes.axisOrigin == 'origin' && 0.0 >= axes.yMin && 0.0 <= axes.yMax
        ? 0.0
        : axes.yMin;
    final axisYX =
        axes.axisOrigin == 'origin' && 0.0 >= axes.xMin && 0.0 <= axes.xMax
        ? 0.0
        : axes.xMin;
    // X 轴
    final x1 = _project(d, mapP(Vec3(axes.xMin, axisXY, 0)));
    final x2 = _project(d, mapP(Vec3(axes.xMax, axisXY, 0)));
    canvas.drawLine(
      x1,
      x2,
      Paint()
        ..color = parseColor(cx)
        ..strokeWidth = aw(axes.widthX),
    );
    // Y 轴
    final y1 = _project(d, mapP(Vec3(axisYX, axes.yMin, 0)));
    final y2 = _project(d, mapP(Vec3(axisYX, axes.yMax, 0)));
    canvas.drawLine(
      y1,
      y2,
      Paint()
        ..color = parseColor(cy)
        ..strokeWidth = aw(axes.widthY),
    );

    final tickPaint = Paint()
      ..color = parseColor(cx)
      ..strokeWidth = _mx(1, fz);
    final xt = _ticks(
      axes.xScale,
      axes.xMin,
      axes.xMax,
      axes.xLen,
      axes.symlogThreshold,
    );
    for (final t in xt) {
      final p = _project(d, mapP(Vec3(t.value, axisXY, 0)));
      canvas.drawLine(
        Offset(p.dx, p.dy - 4 * fz),
        Offset(p.dx, p.dy + 4 * fz),
        tickPaint,
      );
      _pText(
        canvas,
        t.label,
        Offset(p.dx, p.dy + 14 * fz),
        color: parseColor(cx),
        size: fontPx(axes.fontSize),
      );
    }
    final tickYPaint = Paint()
      ..color = parseColor(cy)
      ..strokeWidth = _mx(1, fz);
    final yt = _ticks(
      axes.yScale,
      axes.yMin,
      axes.yMax,
      axes.yLen,
      axes.symlogThreshold,
    );
    for (final t in yt) {
      final p = _project(d, mapP(Vec3(axisYX, t.value, 0)));
      canvas.drawLine(
        Offset(p.dx - 4 * fz, p.dy),
        Offset(p.dx + 4 * fz, p.dy),
        tickYPaint,
      );
      _pText(
        canvas,
        t.label,
        Offset(p.dx - 6 * fz, p.dy + 3 * fz),
        color: parseColor(cy),
        size: fontPx(axes.fontSize),
        align: 'right',
      );
    }
    // 轴标签
    final xLab = _project(d, mapP(Vec3(axes.xMax, axisXY, 0)));
    final yLab = _project(d, mapP(Vec3(axisYX, axes.yMax, 0)));
    if (axes.axisOrigin == 'left') {
      final xMid = _project(
        d,
        mapP(Vec3((axes.xMin + axes.xMax) / 2, axisXY, 0)),
      );
      final yMid = _project(
        d,
        mapP(Vec3(axisYX, (axes.yMin + axes.yMax) / 2, 0)),
      );
      _pText(
        canvas,
        axes.labelX,
        Offset(xMid.dx, xMid.dy + 26 * fz),
        color: parseColor(cx),
        size: fontPx(axes.fontSize + 2),
      );
      canvas.save();
      canvas.translate(yMid.dx - 24 * fz, yMid.dy);
      canvas.rotate(-math.pi / 2);
      _pText(
        canvas,
        axes.labelY,
        Offset.zero,
        color: parseColor(cy),
        size: fontPx(axes.fontSize + 2),
      );
      canvas.restore();
    } else {
      _pText(
        canvas,
        axes.labelX,
        Offset(xLab.dx, xLab.dy - 6 * fz),
        color: parseColor(cx),
        size: fontPx(axes.fontSize + 2),
      );
      _pText(
        canvas,
        axes.labelY,
        Offset(yLab.dx + 8 * fz, yLab.dy),
        color: parseColor(cy),
        size: fontPx(axes.fontSize + 2),
      );
    }
    // 末端箭头
    if (axes.arrowX) {
      final p0 = _project(
        d,
        mapP(Vec3(axes.xMax - (axes.xMax - axes.xMin) * 0.08, axisXY, 0)),
      );
      _drawArrow(canvas, p0, xLab, 8 * fz, parseColor(cx));
    }
    if (axes.arrowY) {
      final p0 = _project(
        d,
        mapP(Vec3(axisYX, axes.yMax - (axes.yMax - axes.yMin) * 0.08, 0)),
      );
      _drawArrow(canvas, p0, yLab, 8 * fz, parseColor(cy));
    }
  }

  /// 3D 坐标轴:三条轴线 + 刻度 + 标签 + 箭头
  void _drawAxes3D(
    Canvas canvas,
    _DrawCtx d,
    _AxesInfo axes,
    Vec3 Function(Vec3) mapP,
    String cx,
    String cy,
    String cz,
  ) {
    final fz = _fzFor(d);
    double fontPx(double base) => _mx(6, (base * fz).roundToDouble());
    double aw(double cm) => _mx(0.5, cm * d.scale);
    final atOrigin = axes.axisOrigin == 'origin';
    final crossX = axisCrossingValue(axes.xMin, axes.xMax, atOrigin: atOrigin);
    final crossY = axisCrossingValue(axes.yMin, axes.yMax, atOrigin: atOrigin);
    final crossZ = axisCrossingValue(axes.zMin, axes.zMax, atOrigin: atOrigin);
    final ranges = <(double, double)>[
      (axes.xMin, axes.xMax),
      (axes.yMin, axes.yMax),
      (axes.zMin, axes.zMax),
    ];
    final scaleKinds = <String>[axes.xScale, axes.yScale, axes.zScale];
    final lengths = <double>[axes.xLen, axes.yLen, axes.zLen];
    final labels = <String>[axes.labelX, axes.labelY, axes.labelZ];
    final axisColors = <String>[cx, cy, cz];
    final axisWidthsCm = <double>[axes.widthX, axes.widthY, axes.widthZ];
    Vec3 point(int axis, double value) => axis == 0
        ? Vec3(value, crossY, crossZ)
        : axis == 1
        ? Vec3(crossX, value, crossZ)
        : Vec3(crossX, crossY, value);

    for (var axisIdx = 0; axisIdx < 3; axisIdx++) {
      final rMin = ranges[axisIdx].$1;
      final rMax = ranges[axisIdx].$2;
      final start = _project(d, mapP(point(axisIdx, rMin)));
      final end = _project(d, mapP(point(axisIdx, rMax)));
      final color = parseColor(axisColors[axisIdx]);
      canvas.drawLine(
        start,
        end,
        Paint()
          ..color = color
          ..strokeWidth = aw(axisWidthsCm[axisIdx]),
      );
      final axisScale = AxisScale.named(
        scaleKinds[axisIdx],
        rMin,
        rMax,
        linearThreshold: axes.symlogThreshold,
      );
      final tk = axisScale.ticks(_targetCount(lengths[axisIdx]));
      final dx = end.dx - start.dx;
      final dy = end.dy - start.dy;
      final L = math.sqrt(dx * dx + dy * dy);
      if (L > 1e-9) {
        final px = -dy / L;
        final py = dx / L;
        final tickPaint = Paint()
          ..color = color.withValues(alpha: 0.7)
          ..strokeWidth = _mx(1, fz);
        for (final t in tk) {
          final tp = _project(d, mapP(point(axisIdx, t.value)));
          canvas.drawLine(
            Offset(tp.dx - px * 3.5 * fz, tp.dy - py * 3.5 * fz),
            Offset(tp.dx + px * 3.5 * fz, tp.dy + py * 3.5 * fz),
            tickPaint,
          );
          _pText(
            canvas,
            t.label,
            Offset(
              tp.dx + (dx / L) * 12 * fz,
              tp.dy + (dy / L) * 12 * fz - 2 * fz,
            ),
            color: color,
            size: fontPx(axes.fontSize - 1),
          );
        }
      }
      _pText(
        canvas,
        labels[axisIdx],
        Offset(end.dx, end.dy - 6 * fz),
        color: color,
        size: fontPx(axes.fontSize + 2),
      );
      if ((axisIdx == 0 && axes.arrowX) || (axisIdx == 1 && axes.arrowY)) {
        _drawArrow(canvas, start, end, 8 * fz, color);
      }
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
      _pan = Offset(
        local.dx - (local.dx - _pan.dx) * f,
        local.dy - (local.dy - _pan.dy) * f,
      );
    });
  }

  void _reset() {
    setState(() {
      _zoom = 1;
      _pan = Offset.zero;
    });
  }

  Future<void> _export() async {
    final node = GraphStore.instance.nodes
        .where((n) => n.id == widget.nodeId)
        .toList();
    final result = GraphStore.instance.results[widget.nodeId];
    if (node.isEmpty) return;
    final params = node.first.params;
    // 导出像素尺寸由坐标系输入携带(原原理化输出参数)
    final ax = result?.inputs['in0'] ?? result?.inputs['in4'];
    var w = (toNum(params['canvasPxW']) ?? 1920).round();
    var h = (toNum(params['canvasPxH']) ?? 1200).round();
    if (ax is AxesData) {
      w = ax.canvasPxW.round();
      h = ax.canvasPxH.round();
    }
    w = w.clamp(100, 12000);
    h = h.clamp(100, 12000);
    final painter = PrincipledPainter(
      params: params,
      result: result,
      fixedSize: Size(w.toDouble(), h.toDouble()),
    );
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    painter.paint(canvas, Size(w.toDouble(), h.toDouble()));
    final img = await recorder.endRecording().toImage(w, h);
    await savePngImage(
      img,
      'principled.png',
      manifest: ax is AxesData ? exportManifest(ax, 'png') : null,
      dpi: ax is AxesData ? ax.exportDpi : null,
    );
  }

  Future<void> _exportVector(String format) async {
    final result = GraphStore.instance.results[widget.nodeId];
    final input = result?.inputs['in0'] ?? result?.inputs['in4'];
    if (input is AxesData) await saveVectorPublication(input, format);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: GraphStore.instance,
      builder: (context, _) {
        final node = GraphStore.instance.nodes
            .where((n) => n.id == widget.nodeId)
            .toList();
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
            child: RepaintBoundary(
              child: CustomPaint(
                size: Size.infinite,
                painter: PrincipledPainter(params: params, result: result),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 左下角控制条:缩放百分比 + 初始化 + 导出 PNG
  Widget _buildControls() {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        Text(
          '${(_zoom * 100).round()}%',
          style: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8)),
        ),
        const SizedBox(width: 8),
        _miniBtn('初始化', _reset),
        _miniBtn('导出 PNG', _export),
        _miniBtn('SVG', () => _exportVector('svg')),
        _miniBtn('PDF', () => _exportVector('pdf')),
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
        child: Text(
          label,
          style: const TextStyle(fontSize: 10, color: Colors.white),
        ),
      ),
    );
  }
}
