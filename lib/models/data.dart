// 核心数据模型:节点配置、端口、数据对象(由 React 版 types/data.ts 移植)
library;

import 'dart:convert';

import 'package:flutter/material.dart' show Color;

import 'color_utils.dart';

/// 节点类别
enum Category { input, clean, compute, transform, visualize }

const List<Category> kAllCategories = [
  Category.input,
  Category.clean,
  Category.compute,
  Category.transform,
  Category.visualize,
];

/// 端口数据类型
enum SocketType {
  table, // 表格
  series, // 曲线/线(一维轴也可视作 series)
  scatter, // 散点
  mesh, // 面/网格体
  distribution, // 分布
  axes, // 坐标系
  text, // 文本
  colorbar, // 渐变色带
  any, // 任意
}

/// 渐变停止点:offset 0~1,color 为颜色。
/// [mid] 为该停止点与下一停止点之间渐变的中点(0~1,0.5 = 线性过渡,
/// PS 中点语义:两个颜色 50% 混色点位于段内 mid 处);最后一段无中点。
class GradientStop {
  double offset;
  String color;
  double? mid;

  GradientStop({required this.offset, required this.color, this.mid});

  GradientStop copy() => GradientStop(offset: offset, color: color, mid: mid);

  Map<String, dynamic> toJson() => {
    'offset': offset,
    'color': color,
    if (mid != null) 'mid': mid,
  };

  factory GradientStop.fromJson(Map<String, dynamic> j) => GradientStop(
    offset: toNum(j['offset']) ?? 0,
    color: '${j['color'] ?? '#888888'}',
    mid: j['mid'] is num ? (j['mid'] as num).toDouble() : null,
  );
}

/// 热力图默认渐变色带(蓝→青→黄→橙→红)
final List<GradientStop> kDefaultGradient = [
  GradientStop(offset: 0, color: '#4575b4'),
  GradientStop(offset: 0.25, color: '#91bfdb'),
  GradientStop(offset: 0.5, color: '#ffffbf'),
  GradientStop(offset: 0.75, color: '#fc8d59'),
  GradientStop(offset: 1, color: '#d73027'),
];

/// 解析渐变 JSON(容错:非法时回退默认色带)
List<GradientStop> parseGradient(dynamic v) {
  if (v is List && v.isNotEmpty) {
    final stops = <GradientStop>[];
    for (final s in v) {
      if (s is GradientStop) {
        stops.add(s);
      } else if (s is Map) {
        final color = s['color'];
        if (color is String && color.isNotEmpty) {
          stops.add(
            GradientStop(
              offset: toNum(s['offset']) ?? 0,
              color: color,
              mid: s['mid'] is num ? (s['mid'] as num).toDouble() : null,
            ),
          );
        }
      }
    }
    if (stops.isNotEmpty) return stops;
  }
  if (v is String) {
    try {
      return parseGradient(jsonDecode(v));
    } catch (_) {
      /* 非法 JSON,回退默认 */
    }
  }
  return kDefaultGradient.map((s) => s.copy()).toList();
}

/// PS 风格渐变插值:相邻停止点之间按各自中点(mid,0.5=线性)分段映射。
/// 段内位置 u∈[0,1]:u < mid 时线性过渡到 50% 混色,之后过渡到下一色。
Color gradientColorAt(List<GradientStop> stops, double v01) {
  if (stops.isEmpty) return const Color(0xFF3B82F6);
  if (stops.length == 1) return parseColor(stops.first.color);
  final t = v01.clamp(0.0, 1.0);
  var i = 0;
  while (i < stops.length - 2 && stops[i + 1].offset <= t) {
    i++;
  }
  final a = stops[i];
  final b = stops[i + 1];
  final span = (b.offset - a.offset).abs();
  final u = span <= 1e-9 ? 0.0 : ((t - a.offset) / span);
  final mid = (a.mid ?? 0.5).clamp(0.02, 0.98);
  final f = u < mid ? (0.5 / mid) * u : 0.5 + 0.5 * (u - mid) / (1 - mid);
  return Color.lerp(
    parseColor(a.color),
    parseColor(b.color),
    f.clamp(0.0, 1.0),
  )!;
}

/// 表格列:values 元素为 num / String / null
class Column {
  String name;
  List<dynamic> values;

  Column({required this.name, required this.values});

  Column copy() => Column(name: name, values: List.of(values));
}

/// 2D 点
class Pt {
  final double x;
  final double y;

  const Pt(this.x, this.y);
}

/// 3D 点(z 可缺省)
class Pt3 {
  final double x;
  final double y;
  final double? z;

  const Pt3(this.x, this.y, [this.z]);
}

/// 3D 向量(用于原理化输出渲染)
class Vec3 {
  final double x;
  final double y;
  final double z;

  const Vec3(this.x, this.y, this.z);

  Vec3 operator +(Vec3 o) => Vec3(x + o.x, y + o.y, z + o.z);

  Vec3 operator -(Vec3 o) => Vec3(x - o.x, y - o.y, z - o.z);

  Vec3 scale(double s) => Vec3(x * s, y * s, z * s);
}

/// 数据对象(由 exec 节点输出)
sealed class DataObject {}

class TableData extends DataObject {
  final List<Column> columns;

  TableData(this.columns);
}

class SeriesData extends DataObject {
  final String name;
  final List<Pt> points;

  /// 线样式(由"表格转曲线"等源节点提供)
  final double? lineWidth;
  final String? lineColor;
  final String? lineStyle; // 'solid' | 'dashed'
  /// 逐点线宽/颜色(由暴露参数接入数据列驱动,逐段变化)
  final List<double>? sizes;
  final List<String>? colors;

  SeriesData({
    required this.name,
    required this.points,
    this.lineWidth,
    this.lineColor,
    this.lineStyle,
    this.sizes,
    this.colors,
  });
}

class ScatterData extends DataObject {
  final String name;
  final List<Pt3> points;

  /// 点样式(由"表格转散点"等源节点提供)
  final double? pointSize;
  final String? pointColor;
  final String? pointShape; // 'circle' | 'square' | 'diamond' | 'triangle'
  /// 逐点大小/颜色(由暴露参数接入数据列驱动,与 points 一一对应)
  final List<double>? sizes;
  final List<String>? colors;

  /// 逐点形状(由"点输入输入"等节点提供,与 points 一一对应)
  final List<String>? shapes;

  ScatterData({
    required this.name,
    required this.points,
    this.pointSize,
    this.pointColor,
    this.pointShape,
    this.sizes,
    this.colors,
    this.shapes,
  });
}

class MeshData extends DataObject {
  final String name;
  final List<Vec3> vertices;
  final List<List<int>> faces;

  /// 面样式(由"平面输入"等节点提供;为空时使用渲染层默认)
  final String? color; // 面填充色
  final double? opacity; // 面透明度 0~1
  final bool? showEdge; // 是否绘制边缘线(空白时按渲染层默认:true)
  final String? edgeColor; // 边缘线颜色(仅 showEdge 时生效,空则同填充色)
  final bool? wireframe; // 线框模式:true 仅画三角形边线不填充
  final bool? fill; // 填充面:false 不填充(与 wireframe 独立)

  MeshData({
    required this.name,
    required this.vertices,
    required this.faces,
    this.color,
    this.opacity,
    this.showEdge,
    this.edgeColor,
    this.wireframe,
    this.fill,
  });
}

class DistributionBin {
  final double x0;
  final double x1;
  final int count;

  const DistributionBin(this.x0, this.x1, this.count);
}

class DistributionData extends DataObject {
  final String name;
  final List<DistributionBin> bins;
  final int sampleCount;

  DistributionData({
    required this.name,
    required this.bins,
    required this.sampleCount,
  });
}

class TextData extends DataObject {
  final String text;

  /// 文本大小(厘米,在坐标轴盒语境下与图元同比例)
  final double fontSize;

  /// 轴盒内水平位置
  final String halign; // left|center|right
  /// 轴盒内垂直位置
  final String valign; // top|middle|bottom
  /// 背景色(空 = 无背景)
  final String? bgColor;
  final String textColor;
  final String fontFamily;

  TextData({
    required this.text,
    required this.fontSize,
    required this.halign,
    required this.valign,
    this.bgColor,
    required this.textColor,
    required this.fontFamily,
  });
}

class ColorbarData extends DataObject {
  /// 渐变色带停止点
  final List<GradientStop> stops;

  /// 色带数值范围(标签显示用)
  final double? min;
  final double? max;
  final String? label;

  /// 色带方向:水平(默认) / 垂直
  final bool? horizontal;

  ColorbarData({
    required this.stops,
    this.min,
    this.max,
    this.label,
    this.horizontal,
  });
}

class AxisColors {
  final String? x;
  final String? y;
  final String? z;

  const AxisColors({this.x, this.y, this.z});
}

class AxisWidths {
  final double? x;
  final double? y;
  final double? z;

  const AxisWidths({this.x, this.y, this.z});
}

class AxisArrows {
  final bool x;
  final bool y;

  const AxisArrows({required this.x, required this.y});
}

class AxesData extends DataObject {
  final String name;
  final int dim; // 2|3
  final double xLen, yLen, zLen; // 各轴长度(厘米)
  final double xMin, xMax, yMin, yMax, zMin, zMax; // 数字范围
  final bool grid; // 网格总开关
  final String axisOrigin; // 'origin'|'left'
  final bool showBorder;
  final String labelX, labelY, labelZ;
  final AxisColors? axisColors;
  final AxisWidths? axisWidths;
  final bool gridX, gridY, gridZ;
  final double fontSize;
  final String fontFamily;
  final String? axisPreset;
  final AxisArrows? arrows;

  /// 原理化 3D 视角旋转角(度);2D 坐标系下不生效
  final double rotX;
  final double rotY;
  final double rotZ;

  AxesData({
    required this.name,
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
    this.axisColors,
    this.axisWidths,
    required this.gridX,
    required this.gridY,
    required this.gridZ,
    required this.fontSize,
    required this.fontFamily,
    this.axisPreset,
    this.arrows,
    this.rotX = -20,
    this.rotY = 25,
    this.rotZ = 0,
  });
}

typedef DataMap = Map<String, DataObject>;

/// "点输入输入"中的单个点
class PointInput {
  dynamic x; // number | string
  dynamic y;
  dynamic size;
  String shape;
  String color;

  PointInput({
    this.x = 0,
    this.y = 0,
    this.size = 4,
    this.shape = 'circle',
    this.color = '#1f77b4',
  });

  Map<String, dynamic> toJson() => {
    'x': x,
    'y': y,
    'size': size,
    'shape': shape,
    'color': color,
  };

  factory PointInput.fromJson(Map<String, dynamic> j) => PointInput(
    x: j['x'],
    y: j['y'],
    size: j['size'],
    shape: '${j['shape'] ?? 'circle'}',
    color: '${j['color'] ?? '#1f77b4'}',
  );
}

class Socket {
  final String id;
  final String name;
  final SocketType type;
  final bool? multi; // 是否允许多路连接

  const Socket({
    required this.id,
    required this.name,
    required this.type,
    this.multi,
  });
}

class ParamSpec {
  final String key;
  final String label;
  final String
  type; // text|number|select|boolean|color|textarea|range|button|points|gradient
  final dynamic defaultValue;
  final List<Map<String, String>>? options;
  final double? min;
  final double? max;
  final double? step;
  final String? placeholder;
  final String? help;
  final bool? expose;
  final String? action;

  const ParamSpec({
    required this.key,
    required this.label,
    required this.type,
    required this.defaultValue,
    this.options,
    this.min,
    this.max,
    this.step,
    this.placeholder,
    this.help,
    this.expose,
    this.action,
  });
}

class ExecContext {
  final String nodeId;
  final Map<String, dynamic> params;
  final Map<String, DataObject?> inputs;

  ExecContext({
    required this.nodeId,
    required this.params,
    required this.inputs,
  });
}

typedef ExecFn = DataMap Function(ExecContext ctx);

class NodeConfig {
  final String id;
  final String label;
  final Category category;
  final String description;
  final List<Socket> inputs;
  final List<Socket> outputs;
  final List<ParamSpec> params;
  final ExecFn? exec;
  final double? width;
  final bool isViewer;

  const NodeConfig({
    required this.id,
    required this.label,
    required this.category,
    required this.description,
    required this.inputs,
    required this.outputs,
    required this.params,
    this.exec,
    this.width,
    this.isViewer = false,
  });
}

const Map<SocketType, String> kSocketLabel = {
  SocketType.table: '表格',
  SocketType.series: '曲线/线',
  SocketType.scatter: '散点',
  SocketType.mesh: '面/网格',
  SocketType.distribution: '分布',
  SocketType.axes: '坐标系',
  SocketType.text: '文本',
  SocketType.colorbar: '色带',
  SocketType.any: '任意',
};

const Map<SocketType, String> kSocketColor = {
  SocketType.table: '#22c55e',
  SocketType.series: '#f59e0b',
  SocketType.scatter: '#3b82f6',
  SocketType.mesh: '#ec4899',
  SocketType.distribution: '#a78bfa',
  SocketType.axes: '#22d3ee',
  SocketType.text: '#e879f9',
  SocketType.colorbar: '#38bdf8',
  SocketType.any: '#94a3b8',
};

class CategoryInfo {
  final String label;
  final String color;
  final String icon;

  const CategoryInfo(this.label, this.color, this.icon);
}

const Map<Category, CategoryInfo> kCategoryInfo = {
  Category.input: CategoryInfo('组输入', '#10b981', '▣'),
  Category.clean: CategoryInfo('数据初步', '#3b82f6', '◈'),
  Category.compute: CategoryInfo('数据运算', '#ef4444', 'ƒ'),
  Category.transform: CategoryInfo('数据转化', '#f59e0b', '⇄'),
  Category.visualize: CategoryInfo('数据可视化', '#8b5cf6', '◉'),
};

bool isCompatible(SocketType from, SocketType to) {
  if (from == to) return true;
  if (from == SocketType.any || to == SocketType.any) return true;
  return false;
}

class ColorPreset {
  final String value;
  final String label;
  final PresetColors colors;

  const ColorPreset({
    required this.value,
    required this.label,
    required this.colors,
  });
}

class PresetColors {
  final String bg;
  final String point;
  final String line;
  final String face;
  final String dist;
  final String axis;
  final String grid;

  const PresetColors({
    required this.bg,
    required this.point,
    required this.line,
    required this.face,
    required this.dist,
    required this.axis,
    required this.grid,
  });
}

const List<ColorPreset> kColorPresets = [
  ColorPreset(
    value: 'paper',
    label: '论文白(亮色)',
    colors: PresetColors(
      bg: '#ffffff',
      point: '#1f77b4',
      line: '#ff7f0e',
      face: '#2ca02c',
      dist: '#9467bd',
      axis: '#333333',
      grid: '#d9dee4',
    ),
  ),
  ColorPreset(
    value: 'tech',
    label: '暗色科技',
    colors: PresetColors(
      bg: '#0b1220',
      point: '#3b82f6',
      line: '#f59e0b',
      face: '#ec4899',
      dist: '#a78bfa',
      axis: '#f8fafc',
      grid: 'rgba(148,163,184,0.18)',
    ),
  ),
  ColorPreset(
    value: 'ocean',
    label: '海洋蓝',
    colors: PresetColors(
      bg: '#02101f',
      point: '#38bdf8',
      line: '#818cf8',
      face: '#22d3ee',
      dist: '#7dd3fc',
      axis: '#e0f2fe',
      grid: 'rgba(125,211,252,0.14)',
    ),
  ),
  ColorPreset(
    value: 'sunset',
    label: '落日橙',
    colors: PresetColors(
      bg: '#1c0f1c',
      point: '#fb923c',
      line: '#fde047',
      face: '#f472b6',
      dist: '#fb7185',
      axis: '#fef3c7',
      grid: 'rgba(253,224,71,0.12)',
    ),
  ),
  ColorPreset(
    value: 'forest',
    label: '森林绿',
    colors: PresetColors(
      bg: '#06130c',
      point: '#4ade80',
      line: '#a3e635',
      face: '#2dd4bf',
      dist: '#86efac',
      axis: '#ecfccb',
      grid: 'rgba(163,230,53,0.12)',
    ),
  ),
  ColorPreset(
    value: 'neon',
    label: '霓虹紫',
    colors: PresetColors(
      bg: '#0a0618',
      point: '#c084fc',
      line: '#22d3ee',
      face: '#f0abfc',
      dist: '#a5b4fc',
      axis: '#f5d0fe',
      grid: 'rgba(192,132,252,0.14)',
    ),
  ),
  ColorPreset(
    value: 'gray',
    label: '灰度',
    colors: PresetColors(
      bg: '#0a0a0a',
      point: '#d4d4d8',
      line: '#a1a1aa',
      face: '#71717a',
      dist: '#3f3f46',
      axis: '#fafafa',
      grid: 'rgba(244,244,245,0.12)',
    ),
  ),
];

PresetColors presetColors(Map<String, dynamic> params) {
  final preset = kColorPresets
      .where((p) => p.value == '${params['colorPreset'] ?? 'paper'}')
      .toList();
  if (preset.isNotEmpty && preset.first.value != 'custom') {
    return preset.first.colors;
  }
  return PresetColors(
    bg: '${params['bgColor'] ?? '#ffffff'}',
    point: '${params['pointColor'] ?? '#1f77b4'}',
    line: '${params['lineColor'] ?? '#ff7f0e'}',
    face: '${params['faceColor'] ?? '#2ca02c'}',
    dist: '${params['distColor'] ?? '#9467bd'}',
    axis: '${params['axisColor'] ?? '#333333'}',
    grid: 'rgba(51,51,51,0.15)',
  );
}

/// 数字转换:null/空/非法 → null
double? toNum(dynamic v) {
  if (v == null || v == '') return null;
  final n = v is num ? v.toDouble() : double.tryParse('$v'.trim());
  return (n != null && n.isFinite) ? n : null;
}

/// number|string → double,非法回退默认
double numOr(dynamic v, double d) {
  final n = v is num ? v.toDouble() : double.tryParse('$v');
  return (n != null && n.isFinite) ? n : d;
}

String strOf(dynamic v, [String d = '']) => v == null ? d : '$v';

bool boolOf(dynamic v, [bool d = false]) => v is bool ? v : d;
