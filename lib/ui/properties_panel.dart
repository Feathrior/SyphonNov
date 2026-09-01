// 属性面板:节点参数控件(选择/数值/布尔/颜色/文本/聚合点/渐变)、暴露开关、输出状态与节点操作
// (由 React 版 PropertiesPanel.tsx 移植)
library;

import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';

import '../models/color_utils.dart';
import '../models/csv.dart';
import '../models/data.dart' as md;
import '../models/exec_engine.dart';
import '../models/registry.dart';
import '../store/graph_store.dart';
import 'theme.dart';

// ==================== 输出描述 ====================

String _describeOutput(md.DataObject? obj) {
  if (obj == null) return '';
  if (obj is md.TableData) {
    return '${obj.columns.length} 列 × ${obj.columns.isEmpty ? 0 : obj.columns.first.values.length} 行';
  }
  if (obj is md.SeriesData) {
    return '${obj.points.length} 个点';
  }
  if (obj is md.ScatterData) {
    return '${obj.points.length} 个点';
  }
  if (obj is md.MeshData) {
    return '${obj.vertices.length} 顶点 / ${obj.faces.length} 面';
  }
  if (obj is md.DistributionData) {
    return '${obj.bins.length} 组 / ${obj.sampleCount} 样本';
  }
  if (obj is md.AxesData) {
    return '${obj.dim}D ${obj.xLen}×${obj.yLen}×${obj.zLen} '
        '${obj.xMin}~${obj.xMax}/${obj.yMin}~${obj.yMax} '
        '${obj.axisOrigin == 'origin' ? '原点居中' : '贴左沿'}';
  }
  if (obj is md.TextData) {
    return '"${obj.text}" ${obj.fontSize}cm ${obj.halign}/${obj.valign}';
  }
  if (obj is md.ColorbarData) {
    final v = obj.stops.length;
    return '$v 段渐变 ${obj.min ?? ''}~${obj.max ?? ''}${obj.horizontal == false ? '(垂直)' : ''}';
  }
  return '';
}

Color _catColor(md.Category c) {
  final info = md.kCategoryInfo[c];
  if (info == null) return const Color(0xFF7C8DB5);
  return Color(
    int.tryParse(info.color.replaceFirst('#', '0xFF')) ?? 0xFF7C8DB5,
  );
}

// ==================== 基础输入框 ====================
// 对应 CSS:.nf-param-row input —— bg-input、text、border 1px strokeStrong、
// 圆角 radius-s、padding 5px 8px、fontSize 12;聚焦时 border accent + 双层光晕。

class _TextField extends StatefulWidget {
  final String text;
  final ValueChanged<String> onChanged;
  final int maxLines;
  final String? placeholder;

  const _TextField({
    required this.text,
    required this.onChanged,
    this.maxLines = 1,
    this.placeholder,
  });

  @override
  State<_TextField> createState() => _TextFieldState();
}

class _TextFieldState extends State<_TextField> {
  late final TextEditingController _c;

  @override
  void initState() {
    super.initState();
    _c = TextEditingController(text: widget.text);
  }

  @override
  void didUpdateWidget(covariant _TextField old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text && _c.text != widget.text) {
      _c.text = widget.text;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    final mono = widget.maxLines > 1; // textarea 使用等宽字体
    // Fluent 文本框:placeholder 提示、焦点光晕由 FluentTheme 提供
    return fluent.TextBox(
      controller: _c,
      placeholder: widget.placeholder,
      minLines: widget.maxLines,
      maxLines: widget.maxLines,
      onChanged: widget.onChanged,
      style: TextStyle(
        fontSize: 12,
        color: t.text,
        fontFamily: mono ? SyphonDims.monoFont : null,
      ),
    );
  }
}

/// 数字输入框:空串回传 ''(视为默认),否则回传 num
class _NumField extends StatelessWidget {
  final String text;
  final ValueChanged<dynamic> onChanged;

  const _NumField({required this.text, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return _TextField(
      text: text,
      onChanged: (s) => onChanged(s.isEmpty ? '' : num.tryParse(s)),
    );
  }
}

// ==================== 颜色选择 ====================

const List<String> _kPresetColors = [
  '#1f77b4',
  '#ff7f0e',
  '#2ca02c',
  '#d62728',
  '#9467bd',
  '#8c564b',
  '#e377c2',
  '#7f7f7f',
  '#bcbd22',
  '#17becf',
  '#ef4444',
  '#f59e0b',
  '#10b981',
  '#3b82f6',
  '#8b5cf6',
  '#000000',
  '#ffffff',
  '#888888',
  '#f97316',
  '#14b8a6',
];

class _ColorField extends StatefulWidget {
  final String value;
  final ValueChanged<String> onChanged;

  const _ColorField({required this.value, required this.onChanged});

  @override
  State<_ColorField> createState() => _ColorFieldState();
}

class _ColorFieldState extends State<_ColorField> {
  late final TextEditingController _c;

  @override
  void initState() {
    super.initState();
    _c = TextEditingController(text: widget.value);
  }

  @override
  void didUpdateWidget(covariant _ColorField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && _c.text != widget.value) {
      _c.text = widget.value;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Color get _swatchColor =>
      Color(int.tryParse(widget.value.replaceFirst('#', '0xFF')) ?? 0xFF888888);

  Future<void> _pickPreset() async {
    final t = SyphonTheme.of(context);
    final picked = await fluent.showDialog<String>(
      context: context,
      builder: (ctx) => fluent.ContentDialog(
        title: const Text('选择颜色', style: TextStyle(fontSize: 14)),
        content: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final c in _kPresetColors)
              GestureDetector(
                onTap: () => Navigator.pop(ctx, c),
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: Color(
                      int.tryParse(c.replaceFirst('#', '0xFF')) ?? 0xFF888888,
                    ),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: t.strokeStrong),
                  ),
                ),
              ),
          ],
        ),
        actions: [
          fluent.FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (picked != null) {
      widget.onChanged(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    return Row(
      children: [
        GestureDetector(
          onTap: _pickPreset,
          child: Container(
            width: 36,
            height: 28,
            decoration: BoxDecoration(
              color: _swatchColor,
              borderRadius: BorderRadius.circular(SyphonDims.radiusS),
              border: Border.all(color: t.strokeStrong),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: _TextField(text: widget.value, onChanged: widget.onChanged),
        ),
      ],
    );
  }
}

// ==================== 聚合点编辑器 ====================

class _PointsEditor extends StatelessWidget {
  final List<dynamic> points;
  final ValueChanged<List<dynamic>> onChanged;

  const _PointsEditor({required this.points, required this.onChanged});

  void _setPoint(int i, Map<String, dynamic> patch) {
    final out = List<dynamic>.of(points);
    final rec = (out[i] is Map)
        ? Map<String, dynamic>.from(out[i] as Map)
        : <String, dynamic>{};
    out[i] = {...rec, ...patch};
    onChanged(out);
  }

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < points.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _pointRow(context, t, i),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: fluent.Button(
            onPressed: () => onChanged([
              ...points,
              {
                'x': 0,
                'y': 0,
                'size': 4,
                'shape': 'circle',
                'color': '#1f77b4',
              },
            ]),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add, size: 14),
                SizedBox(width: 4),
                Text('添加点', style: TextStyle(fontSize: 12)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // .nf-point-row:bg-raise、border stroke、radius-m、padding 6
  Widget _pointRow(BuildContext context, SyphonTheme t, int i) {
    final rec = (points[i] is Map)
        ? points[i] as Map
        : const <String, dynamic>{};
    final x = rec['x'];
    final y = rec['y'];
    final size = rec['size'];
    final shape = '${rec['shape'] ?? 'circle'}';
    final color = '${rec['color'] ?? '#1f77b4'}';
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: t.bgRaise,
        border: Border.all(color: t.stroke, width: 1),
        borderRadius: BorderRadius.circular(SyphonDims.radiusM),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const _RowLabel('X'),
              Expanded(
                child: _NumField(
                  text: _valStr(x, ''),
                  onChanged: (v) => _setPoint(i, {'x': v}),
                ),
              ),
              const SizedBox(width: 8),
              const _RowLabel('Y'),
              Expanded(
                child: _NumField(
                  text: _valStr(y, ''),
                  onChanged: (v) => _setPoint(i, {'y': v}),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const _RowLabel('大小'),
              Expanded(
                child: _NumField(
                  text: _valStr(size, '4'),
                  onChanged: (v) => _setPoint(i, {'size': v}),
                ),
              ),
              const SizedBox(width: 8),
              const _RowLabel('形状'),
              Expanded(
                child: _ShapeDropdown(
                  value: shape,
                  onChanged: (s) => _setPoint(i, {'shape': s}),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const _RowLabel('颜色'),
              Expanded(
                child: _ColorField(
                  value: color,
                  onChanged: (s) => _setPoint(i, {'color': s}),
                ),
              ),
              fluent.IconButton(
                icon: const Icon(Icons.close, size: 14),
                onPressed: () =>
                    onChanged([...points.take(i), ...points.skip(i + 1)]),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// .nf-point-fields label:fontSize 10、text-faint
class _RowLabel extends StatelessWidget {
  final String text;
  const _RowLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Text(text, style: TextStyle(fontSize: 10, color: t.textFaint)),
    );
  }
}

class _ShapeDropdown extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;

  const _ShapeDropdown({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    const shapes = [
      ('circle', '圆形'),
      ('square', '方形'),
      ('diamond', '菱形'),
      ('triangle', '三角形'),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: t.bgInput,
        border: Border.all(color: t.strokeStrong),
        borderRadius: BorderRadius.circular(SyphonDims.radiusS),
      ),
      child: fluent.ComboBox<String>(
        value: value,
        isExpanded: true,
        style: TextStyle(fontSize: 11, color: t.text),
        iconEnabledColor: t.textDim,
        popupColor: t.bgFloat,
        items: [
          for (final s in shapes)
            fluent.ComboBoxItem(
              value: s.$1,
              child: Text(s.$2, style: TextStyle(fontSize: 11, color: t.text)),
            ),
        ],
        onChanged: (nv) {
          if (nv != null) onChanged(nv);
        },
      ),
    );
  }
}

// ==================== 渐变编辑器(PS 风格) ====================

/// PS 风格渐变编辑器:
/// - 渐变条上方为相邻停止点之间的"中点"菱形(水平拖动调整过渡重心)
/// - 渐变条下方为颜色停止点标记(点击选中;水平拖动改位置;向下拖出条带删除)
/// - 点击渐变条空白处新增停止点(取当前位置的插值色),并自动选中
/// - 选中停止点后可改位置 / 颜色(HSV 取色器)/ 删除
class _GradientEditor extends StatefulWidget {
  final List<dynamic> stops;
  final ValueChanged<List<dynamic>> onChanged;

  const _GradientEditor({required this.stops, required this.onChanged});

  @override
  State<_GradientEditor> createState() => _GradientEditorState();
}

class _GradientEditorState extends State<_GradientEditor> {
  static const _barH = 22.0;
  static const _zoneH = 16.0; // 停止点标记区高度

  int _sel = 0; // 选中停止点索引(按 offset 排序)
  late double _dragT = 0; // 拖动起点时的 offset/mid 基准
  late double _dragX = 0; // 拖动起点全局 X
  late double _dragY = 0; // 拖动起点全局 Y

  List<Map<String, dynamic>> get _parsed => [
    for (final s in widget.stops)
      if (s is md.GradientStop)
        {'offset': s.offset, 'color': s.color, 'mid': s.mid ?? 0.5}
      else if (s is Map)
        {
          'offset': (s['offset'] is num)
              ? (s['offset'] as num).toDouble()
              : 0.0,
          'color': '${s['color'] ?? '#888888'}',
          'mid': s['mid'] is num ? (s['mid'] as num).toDouble() : 0.5,
        },
  ];

  List<md.GradientStop> _toStops(List<Map<String, dynamic>> parsed) => [
    for (final s in parsed)
      md.GradientStop(
        offset: s['offset'] as double,
        color: s['color'] as String,
        mid: (s['mid'] as double) == 0.5 ? null : (s['mid'] as double),
      ),
  ];

  void _emit(List<Map<String, dynamic>> list) {
    final sorted = List<Map<String, dynamic>>.of(
      list,
    )..sort((a, b) => (a['offset'] as double).compareTo(b['offset'] as double));
    widget.onChanged(List<dynamic>.of(sorted));
  }

  void _addStop(double raw) {
    final parsed = _parsed;
    final t = raw.clamp(0.0, 1.0);
    if (parsed.any((s) => ((s['offset'] as double) - t).abs() < 0.004)) return;
    final color = colorToHex(md.gradientColorAt(_toStops(parsed), t));
    final next = [
      ...parsed,
      {'offset': t, 'color': color, 'mid': 0.5},
    ]..sort((a, b) => (a['offset'] as double).compareTo(b['offset'] as double));
    final idx = next.indexWhere((s) => (s['offset'] as double) == t);
    setState(() => _sel = idx < 0 ? next.length - 1 : idx);
    _emit(next);
  }

  void _moveStop(int i, double raw) {
    final parsed = _parsed;
    final prev = i > 0 ? (parsed[i - 1]['offset'] as double) + 0.006 : 0.0;
    final max = i < parsed.length - 1
        ? (parsed[i + 1]['offset'] as double) - 0.006
        : 1.0;
    final o = raw.clamp(prev, max);
    final out = List<Map<String, dynamic>>.of(parsed);
    out[i] = {...out[i], 'offset': o};
    _emit(out);
  }

  void _moveMid(int i, double raw) {
    final parsed = _parsed;
    if (i >= parsed.length - 1) return; // 最后一段无中点
    final out = List<Map<String, dynamic>>.of(parsed);
    out[i] = {...out[i], 'mid': raw.clamp(0.05, 0.95)};
    _emit(out);
  }

  void _removeStop(int i) {
    if (widget.stops.length <= 1) return; // 至少保留一个停止点
    _emit([..._parsed.take(i), ..._parsed.skip(i + 1)]);
    setState(() => _sel = i == 0 ? 0 : i - 1);
  }

  void _setStopColor(int i, String c) {
    final out = List<Map<String, dynamic>>.of(_parsed);
    out[i] = {...out[i], 'color': c};
    _emit(out);
  }

  double _midX(List<Map<String, dynamic>> parsed, int i, double w) {
    final o0 = parsed[i]['offset'] as double;
    final o1 = parsed[i + 1]['offset'] as double;
    return (o0 + (parsed[i]['mid'] as double) * (o1 - o0)) * w;
  }

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    final parsed = _parsed;
    if (parsed.isEmpty) return const SizedBox.shrink();
    if (_sel >= parsed.length) _sel = parsed.length - 1;
    final sel = parsed[_sel];
    final selColor = parseColor(sel['color'] as String);
    final preview = _previewColors(parsed);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (ctx, cons) {
            final w = cons.maxWidth;
            if (w <= 0) return const SizedBox.shrink();
            return SizedBox(
              height: _barH + _zoneH,
              width: w,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // 渐变条(点击空白 → 新增停止点)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: _barH,
                    child: GestureDetector(
                      onTapDown: (d) => _addStop(d.localPosition.dx / w),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(
                            SyphonDims.radiusM,
                          ),
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: [for (final p in preview) p.$2],
                            stops: [for (final p in preview) p.$1],
                          ),
                          border: Border.all(color: t.stroke, width: 1),
                        ),
                      ),
                    ),
                  ),
                  // 中点菱形(相邻停止点之间)
                  for (var i = 0; i < parsed.length - 1; i++)
                    Positioned(
                      left: _midX(parsed, i, w) - 4,
                      top: -3,
                      child: _midDiamond(i, w),
                    ),
                  // 颜色停止点标记(条带下方,PS 屋檐形)
                  for (var i = 0; i < parsed.length; i++)
                    Positioned(
                      left: (parsed[i]['offset'] as double) * w - 6,
                      top: _barH - 2,
                      child: _colorMarker(i, w),
                    ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 4),
        // 选中停止点控制:颜色 / 位置 / 删除
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: t.bgRaise,
            border: Border.all(color: t.stroke, width: 1),
            borderRadius: BorderRadius.circular(SyphonDims.radiusM),
          ),
          child: Row(
            children: [
              GestureDetector(
                onTap: () => _pickColor(context),
                child: Tooltip(
                  message: '打开取色器',
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: selColor,
                      borderRadius: BorderRadius.circular(SyphonDims.radiusS),
                      border: Border.all(color: t.strokeStrong),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              const _RowLabel('位置'),
              Expanded(
                child: _NumField(
                  text: (sel['offset'] as double).toStringAsFixed(2),
                  onChanged: (v) {
                    final n = v is num ? v.toDouble() : 0.0;
                    if (n.isFinite && n >= 0 && n <= 1) {
                      _moveStop(_sel, n);
                    }
                  },
                ),
              ),
              const SizedBox(width: 6),
              const _RowLabel('颜色'),
              Expanded(
                child: _TextField(
                  text: sel['color'] as String,
                  onChanged: (c) => _setStopColor(_sel, c),
                ),
              ),
              fluent.IconButton(
                icon: const Icon(Icons.close, size: 14),
                onPressed: () => _removeStop(_sel),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 按 PS 中点语义重采样预览渐变(与渲染共用 gradientColorAt)
  List<(double, Color)> _previewColors(List<Map<String, dynamic>> parsed) {
    final stops = _toStops(parsed);
    const n = 64;
    return [
      for (var i = 0; i <= n; i++) (i / n, md.gradientColorAt(stops, i / n)),
    ];
  }

  Widget _colorMarker(int i, double w) {
    final s = _parsed[i];
    final selected = i == _sel;
    final t = SyphonTheme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => setState(() => _sel = i),
      onPanStart: (d) {
        _sel = i;
        setState(() {});
        _dragT = s['offset'] as double;
        _dragX = d.globalPosition.dx;
        _dragY = d.globalPosition.dy;
      },
      onPanUpdate: (d) {
        _moveStop(i, _dragT + (d.globalPosition.dx - _dragX) / w);
        // 向下拖出条带区域 → 删除(PS 行为)
        if (d.globalPosition.dy - _dragY > 24) _removeStop(i);
      },
      child: CustomPaint(
        size: const Size(12, 13),
        painter: _StopMarkerPainter(
          color: parseColor(s['color'] as String),
          selected: selected,
          accent: t.accent,
        ),
      ),
    );
  }

  Widget _midDiamond(int i, double w) {
    final s = _parsed[i];
    final t = SyphonTheme.of(context);
    final seg =
        ((s['offset'] as double) - (_parsed[i + 1]['offset'] as double)).abs() *
        w;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (d) {
        _dragT = s['mid'] as double;
        _dragX = d.globalPosition.dx;
      },
      onPanUpdate: (d) {
        if (seg > 1.0) {
          _moveMid(i, _dragT + (d.globalPosition.dx - _dragX) / seg);
        }
      },
      child: Container(
        width: 9,
        height: 9,
        margin: const EdgeInsets.only(top: 3),
        transform: Matrix4.rotationZ(0.785398), // 45° 菱形
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: t.strokeStrong, width: 1),
        ),
      ),
    );
  }

  Future<void> _pickColor(BuildContext context) async {
    final initial = _parsed[_sel]['color'] as String;
    final picked = await fluent.showDialog<String>(
      context: context,
      builder: (ctx) => _HsvPickerDialog(initial: initial),
    );
    if (picked != null && picked.isNotEmpty) _setStopColor(_sel, picked);
  }
}

/// 颜色停止点标记:PS 屋檐形小旗(上方三角 + 下方窄条),选中时白描边
class _StopMarkerPainter extends CustomPainter {
  final Color color;
  final bool selected;
  final Color accent;

  _StopMarkerPainter({
    required this.color,
    required this.selected,
    required this.accent,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final tri = Path()
      ..moveTo(0, 0)
      ..lineTo(w, 0)
      ..lineTo(w / 2, h - 4)
      ..close();
    canvas.drawPath(
      tri,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      tri,
      Paint()
        ..color = selected ? accent : Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = selected ? 1.6 : 1,
    );
    // 底部小柄
    canvas.drawRect(
      Rect.fromLTWH(w / 2 - 1.5, h - 4, 3, 4),
      Paint()
        ..color = selected ? accent : Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _StopMarkerPainter old) =>
      old.color != color || old.selected != selected || old.accent != accent;
}

/// HSV 取色器对话框(SV 方形取色区 + 色相滑杆 + 十六进制输入)
class _HsvPickerDialog extends StatefulWidget {
  final String initial;
  const _HsvPickerDialog({required this.initial});

  @override
  State<_HsvPickerDialog> createState() => _HsvPickerDialogState();
}

class _HsvPickerDialogState extends State<_HsvPickerDialog> {
  late double _h, _s, _v;

  @override
  void initState() {
    super.initState();
    final c = parseColor(widget.initial, const Color(0xFF888888));
    final hsv = HSVColor.fromColor(c);
    _h = hsv.hue;
    _s = hsv.saturation;
    _v = hsv.value;
  }

  Color get _color => HSVColor.fromAHSV(1, _h, _s, _v).toColor();

  void _updateSv(Offset pos, Size size) {
    setState(() {
      _s = (pos.dx / size.width).clamp(0.0, 1.0);
      _v = 1 - (pos.dy / size.height).clamp(0.0, 1.0);
    });
  }

  void _updateH(double x, double w) {
    setState(() => _h = (x / w).clamp(0.0, 1.0) * 360);
  }

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    return fluent.ContentDialog(
      title: const Text('选择颜色', style: TextStyle(fontSize: 14)),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // SV 方形取色区
            LayoutBuilder(
              builder: (ctx, cons) {
                final w = cons.maxWidth;
                final h = 140.0;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => _updateSv(d.localPosition, Size(w, h)),
                  onPanDown: (d) => _updateSv(d.localPosition, Size(w, h)),
                  onPanUpdate: (d) => _updateSv(d.localPosition, Size(w, h)),
                  child: SizedBox(
                    width: w,
                    height: h,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(
                                SyphonDims.radiusS,
                              ),
                              gradient: LinearGradient(
                                begin: Alignment.centerLeft,
                                end: Alignment.centerRight,
                                colors: [
                                  Colors.white,
                                  HSVColor.fromAHSV(1, _h, 1, 1).toColor(),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(
                                SyphonDims.radiusS,
                              ),
                              gradient: const LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [Colors.transparent, Colors.black],
                              ),
                            ),
                          ),
                        ),
                        // 取色圆环
                        Positioned(
                          left: _s * w - 6,
                          top: (1 - _v) * h - 6,
                          child: IgnorePointer(
                            child: Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.transparent,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
            // 色相滑杆
            LayoutBuilder(
              builder: (ctx, cons) {
                final w = cons.maxWidth;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => _updateH(d.localPosition.dx, w),
                  onPanDown: (d) => _updateH(d.localPosition.dx, w),
                  onPanUpdate: (d) => _updateH(d.localPosition.dx, w),
                  child: SizedBox(
                    height: 16,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(
                                SyphonDims.radiusS,
                              ),
                              gradient: const LinearGradient(
                                colors: [
                                  Color(0xFFFF0000),
                                  Color(0xFFFFFF00),
                                  Color(0xFF00FF00),
                                  Color(0xFF00FFFF),
                                  Color(0xFF0000FF),
                                  Color(0xFFFF00FF),
                                  Color(0xFFFF0000),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          left: _h / 360 * w - 4,
                          top: -2,
                          child: IgnorePointer(
                            child: Container(
                              width: 8,
                              height: 20,
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: _color,
                    borderRadius: BorderRadius.circular(SyphonDims.radiusS),
                    border: Border.all(color: t.strokeStrong),
                  ),
                ),
                const SizedBox(width: 8),
                const _RowLabel('HEX'),
                const SizedBox(width: 4),
                Expanded(
                  child: _TextField(
                    text: colorToHex(_color),
                    onChanged: (s) {
                      final c = parseColor(s, const Color(0xFF808080));
                      if (s.startsWith('#')) {
                        final hsv = HSVColor.fromColor(c);
                        setState(() {
                          _h = hsv.hue;
                          _s = hsv.saturation;
                          _v = hsv.value;
                        });
                      }
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        fluent.Button(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        fluent.FilledButton(
          onPressed: () => Navigator.pop(context, colorToHex(_color)),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

// ==================== 参数控件 ====================

String _valStr(dynamic v, String d) => v == null || v == '' ? d : '$v';

class _ParamControl extends StatelessWidget {
  final md.ParamSpec spec;
  final dynamic value;
  final String nodeId;
  final ValueChanged<dynamic> onChanged;

  const _ParamControl({
    required this.spec,
    required this.value,
    required this.nodeId,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    if (spec.type == 'button') {
      // .nf-btn .nf-btn-sm .nf-btn-import:全宽、accent 文字、虚线 strokeStrong 边框
      return _SmButton(
        label: '选择 CSV/Excel 文件…',
        dashed: true,
        accent: true,
        fullWidth: true,
        onPressed: () => _pickDataFile(context),
      );
    }
    final v = value ?? spec.defaultValue;
    switch (spec.type) {
      case 'select':
        final options = spec.options ?? const <Map<String, String>>[];
        final cur = _valStr(
          v,
          options.isNotEmpty ? options.first['value'] ?? '' : '',
        );
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: t.bgInput,
            border: Border.all(color: t.strokeStrong),
            borderRadius: BorderRadius.circular(SyphonDims.radiusS),
          ),
          child: fluent.ComboBox<String>(
            value: cur,
            isExpanded: true,
            style: TextStyle(fontSize: 11, color: t.text),
            iconEnabledColor: t.textDim,
            popupColor: t.bgFloat,
            items: [
              for (final o in options)
                fluent.ComboBoxItem(
                  value: o['value'] ?? '',
                  child: Text(
                    o['label'] ?? '',
                    style: TextStyle(fontSize: 11, color: t.text),
                  ),
                ),
            ],
            onChanged: (nv) {
              if (nv != null) onChanged(nv);
            },
          ),
        );
      case 'boolean':
        return Align(
          alignment: Alignment.centerLeft,
          child: fluent.Checkbox(
            checked: v == true,
            onChanged: (b) => onChanged(b == true),
          ),
        );
      case 'number':
      case 'range':
        // 数字参数:有明确 min/max 时"输入框 + 拉杆";
        // 取值无界(实数域或 0~∞)时仅输入框,滚轮在输入框上滑/下滑步进
        return _buildNumControl(spec, v);
      case 'color':
        return _ColorField(value: _valStr(v, '#888888'), onChanged: onChanged);
      case 'points':
        final pts = v is List ? v : <dynamic>[];
        return _PointsEditor(points: pts, onChanged: onChanged);
      case 'gradient':
        final stops = v is List ? v : <dynamic>[];
        return _GradientEditor(stops: stops, onChanged: onChanged);
      case 'textarea':
        return _TextField(
          text: _valStr(v, ''),
          maxLines: 4,
          placeholder: spec.placeholder,
          onChanged: onChanged,
        );
      default:
        return _TextField(
          text: _valStr(v, ''),
          placeholder: spec.placeholder,
          onChanged: onChanged,
        );
    }
  }

  /// 数字参数控件:
  /// - 有明确 min/max → 输入框 + 拉杆(滑块按 step 取整,输入框自由输入,
  ///   输入框内滚轮可步进);
  /// - 无界(实数域 / 0~∞)→ 仅输入框占满整行,不提供滚轮增减。
  Widget _buildNumControl(md.ParamSpec spec, dynamic v) {
    final cv = v is num
        ? v.toDouble()
        : (spec.defaultValue is num
              ? (spec.defaultValue as num).toDouble()
              : 0.0);
    final bounded = spec.min != null && spec.max != null;
    final step = spec.step;

    final field = _NumField(
      text: _valStr(v, ''),
      // 空/非法输入不提交,保持当前值
      onChanged: (nv) {
        if (nv is num) onChanged(nv);
      },
    );

    // 无界参数:仅输入框(整行宽度),无拉杆、无滚轮步进
    if (!bounded) return field;

    // 有界参数:拉杆 + 输入框;输入框内滚轮上滑/下滑按数量级步进
    final wheelField = Listener(
      behavior: HitTestBehavior.translucent,
      onPointerSignal: (e) {
        if (e is! PointerScrollEvent) return;
        // 上滑(scrollDelta.dy<0)递增,下滑递减;幅度按滚动量折算 1~12 步
        final count = (e.scrollDelta.dy.abs() / 24).ceil().clamp(1, 12);
        final dir = e.scrollDelta.dy < 0 ? 1 : -1;
        var nv = cv + dir * count * _wheelUnit(spec, cv);
        nv = nv.clamp(spec.min!, spec.max!);
        if (step != null && step > 0) nv = (nv / step).round() * step;
        onChanged(nv);
      },
      child: field,
    );

    final min = spec.min ?? 0.0;
    final max = spec.max ?? 1.0;
    final snapped = step != null && step > 0 ? (cv / step).round() * step : cv;
    return Row(
      children: [
        Expanded(
          child: fluent.Slider(
            value: snapped.clamp(min, max),
            min: min,
            max: max,
            divisions: step != null && step > 0
                ? ((max - min) / step).round().clamp(1, 1000)
                : null,
            onChanged: (d) =>
                onChanged(step != null ? (d / step).round() * step : d),
          ),
        ),
        SizedBox(width: 64, child: wheelField),
      ],
    );
  }

  /// 滚轮步进步长:参数定义了 step 用之;否则按当前值数量级取整
  /// (1/0.1/0.01… 与 1/10/100…),保证任意量级都能"合适地"步进。
  double _wheelUnit(md.ParamSpec spec, double cv) {
    final s = spec.step;
    if (s != null && s > 0) return s;
    final a = cv.abs();
    if (a < 1e-12) return 1.0;
    return math.pow(10, (math.log(a) / math.ln10).floor()).toDouble();
  }

  Future<void> _pickDataFile(BuildContext context) async {
    const group = XTypeGroup(
      label: '数据文件',
      extensions: ['csv', 'tsv', 'txt', 'xlsx', 'xls'],
    );
    final file = await openFile(acceptedTypeGroups: const [group]);
    if (file == null) return;
    final path = file.path;
    if (path.isEmpty) return;
    try {
      // UTF-8 解码文本文件;Excel 取第一个工作表转 CSV(GraphStore 自动执行会刷新图)
      final text = await dataFileToCsvText(path);
      if (!context.mounted) return;
      _applyImportedTable(path, text);
    } catch (e) {
      if (!context.mounted) return;
      fluent.displayInfoBar(
        context,
        builder: (context, close) => fluent.InfoBar(
          title: const Text('导入失败'),
          content: Text('$e'),
          severity: fluent.InfoBarSeverity.error,
        ),
      );
    }
  }

  /// 将导入的表格文本写入节点参数(手动模式),并触发自动执行
  void _applyImportedTable(String path, String text) {
    if (text.trim().isEmpty) return;
    final delimiter = text.contains('\t') && !text.contains(',')
        ? 'tsv'
        : 'csv';
    GraphStore.instance.updateNodeParams(nodeId, {
      'mode': 'manual',
      'dataText': text,
      'delimiter': delimiter,
    });
  }
}

// ==================== 小按钮 / 暴露按钮 ====================

// .nf-btn .nf-btn-sm:padding 3 10、fontSize 11、透明边框、hover bg-float
// .nf-btn-danger:danger 文字   .nf-btn-import:全宽 + accent + 虚线 strokeStrong 边框
class _SmButton extends StatefulWidget {
  final String label;
  final VoidCallback onPressed;
  final bool danger;
  final bool accent;
  final bool dashed;
  final bool fullWidth;

  const _SmButton({
    required this.label,
    required this.onPressed,
    this.danger = false,
    this.accent = false,
    this.dashed = false,
    this.fullWidth = false,
  });

  @override
  State<_SmButton> createState() => _SmButtonState();
}

class _SmButtonState extends State<_SmButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    final fg = widget.danger ? t.danger : (widget.accent ? t.accent : t.text);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: CustomPaint(
          foregroundPainter: widget.dashed
              ? _DashedBorderPainter(t.strokeStrong)
              : null,
          child: AnimatedContainer(
            width: widget.fullWidth ? double.infinity : null,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              // 同色 alpha=0,避免 transparent(黑 RGB)插值先变黑
              color: _hover ? t.bgFloat : t.bgFloat.withValues(alpha: 0),
              borderRadius: BorderRadius.circular(SyphonDims.radiusS),
            ),
            alignment: widget.fullWidth
                ? Alignment.center
                : Alignment.centerLeft,
            child: Text(
              widget.label,
              textAlign: widget.fullWidth ? TextAlign.center : TextAlign.start,
              style: TextStyle(fontSize: 11, color: fg),
            ),
          ),
        ),
      ),
    );
  }
}

// 沿圆角矩形描虚线边框(用于导入按钮)
class _DashedBorderPainter extends CustomPainter {
  final Color color;
  _DashedBorderPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(SyphonDims.radiusS),
    );
    final path = Path()..addRRect(rrect);
    const dash = 4.0, gap = 3.0;
    for (final metric in path.computeMetrics()) {
      var dist = 0.0;
      while (dist < metric.length) {
        final next = (dist + dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(dist, next), paint);
        dist += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) => old.color != color;
}

// .nf-expose-btn:18px 圆形、border strokeStrong、text-faint
// hover:accent 边框/文字   .nf-expose-on:accent 16% 底 + accent 边框/文字
// .nf-expose-dot:8px 圆、border 1.5 currentColor;激活时填充 accent
class _ExposeButton extends StatefulWidget {
  final bool exposed;
  final VoidCallback onTap;

  const _ExposeButton({required this.exposed, required this.onTap});

  @override
  State<_ExposeButton> createState() => _ExposeButtonState();
}

class _ExposeButtonState extends State<_ExposeButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    final on = widget.exposed;
    final color = on || _hover ? t.accent : t.textFaint;
    final border = on || _hover ? t.accent : t.strokeStrong;
    final bg = on ? t.accent.withValues(alpha: 0.16) : Colors.transparent;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: fluent.Tooltip(
          message: on
              ? '已暴露(点击取消):节点上已生成输入口,接入数据列后逐点驱动该参数'
              : '暴露(点击启用):在节点上生成输入口,可接入表格数据列逐点驱动该参数',
          child: Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: bg,
              shape: BoxShape.circle,
              border: Border.all(color: border, width: 1),
            ),
            alignment: Alignment.center,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: on ? t.accent : Colors.transparent,
                shape: BoxShape.circle,
                border: Border.all(color: color, width: 1.5),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ==================== 面板主体 ====================

class PropertiesPanel extends StatelessWidget {
  const PropertiesPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final store = GraphStore.instance;
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final t = SyphonTheme.of(context);

        GraphNode? node;
        for (final n in store.nodes) {
          if (n.id == store.selectedId) {
            node = n;
            break;
          }
        }
        final cfg = node == null ? null : getConfig(node.configId);
        if (node == null || cfg == null) {
          return _emptyState(t);
        }
        final exposedKeys = node.exposed;
        final result = store.results[node.id];
        final catColor = _catColor(cfg.category);
        final catInfo = md.kCategoryInfo[cfg.category];
        final selId = node.id;

        // .nf-props:width 300、bg-surface、border-left 1px stroke
        return Container(
          width: SyphonDims.propsW,
          decoration: BoxDecoration(
            color: t.bgSurface,
            border: Border(left: BorderSide(color: t.stroke, width: 1)),
          ),
          child: ListView(
            padding: const EdgeInsets.all(12), // .nf-props-body
            children: [
              _buildHead(t, cfg, catColor, catInfo),
              _buildDesc(t, cfg),

              // 参数
              if (cfg.params.isNotEmpty)
                _section(t, '参数', [
                  for (final p in cfg.params)
                    _paramRow(context, t, p, node, exposedKeys),
                ]),

              // 输出状态
              if (cfg.outputs.isNotEmpty)
                _section(t, '输出状态', [
                  for (final o in cfg.outputs) _outputRow(t, o, result),
                  if (result?.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        '错误:${result!.error}',
                        style: TextStyle(
                          fontSize: 11,
                          color: t.danger,
                          height: 1.5,
                        ),
                      ),
                    ),
                ]),

              // 节点操作
              _section(t, '节点操作', [
                // .nf-props-actions:flex gap 6
                Row(
                  children: [
                    _SmButton(
                      label: '复制',
                      onPressed: () => store.duplicateNodes([selId]),
                    ),
                    const SizedBox(width: 6),
                    _SmButton(
                      label: '删除',
                      danger: true,
                      onPressed: () => store.removeNodes([selId]),
                    ),
                  ],
                ),
              ]),
            ],
          ),
        );
      },
    );
  }

  // .nf-props-head:border-left 3px catColor、padding-left 10、margin-bottom 8
  Widget _buildHead(
    SyphonTheme t,
    md.NodeConfig cfg,
    Color catColor,
    md.CategoryInfo? catInfo,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.only(left: 10),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: catColor, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // .nf-props-title:fontSize 14、gap 6
          Row(
            children: [
              Text(
                catInfo?.icon ?? '•',
                style: TextStyle(color: catColor, fontSize: 14),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  cfg.label,
                  style: TextStyle(fontSize: 14, color: t.text),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2), // .nf-props-cat margin-top 2
          Text(
            catInfo?.label ?? '',
            style: TextStyle(fontSize: 11, color: catColor),
          ),
        ],
      ),
    );
  }

  // .nf-props-desc:fontSize 12、textDim、bg-raise、border stroke、radius 8
  Widget _buildDesc(SyphonTheme t, md.NodeConfig cfg) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: t.bgRaise,
        border: Border.all(color: t.stroke, width: 1),
        borderRadius: BorderRadius.circular(SyphonDims.radiusM),
      ),
      child: Text(
        cfg.description,
        style: TextStyle(fontSize: 12, color: t.textDim, height: 1.6),
      ),
    );
  }

  // .nf-props-section:margin-bottom 12、padding 8 10、bg-surface、border stroke、radius 8
  Widget _section(SyphonTheme t, String title, List<Widget> children) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: t.bgSurface,
        border: Border.all(color: t.stroke, width: 1),
        borderRadius: BorderRadius.circular(SyphonDims.radiusM),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // .nf-props-section-title:fontSize 11、textFaint、uppercase、letterSpacing 0.8
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              title.toUpperCase(),
              style: TextStyle(
                fontSize: 11,
                color: t.textFaint,
                letterSpacing: 0.8,
              ),
            ),
          ),
          ...children,
        ],
      ),
    );
  }

  // .nf-param-row:margin-bottom 8
  Widget _paramRow(
    BuildContext context,
    SyphonTheme t,
    md.ParamSpec p,
    GraphNode node,
    List<String> exposedKeys,
  ) {
    final store = GraphStore.instance;
    final isExposed = exposedKeys.contains(p.key);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _paramHeadRow(t, p, node, isExposed),
          const SizedBox(height: 3),
          _ParamControl(
            spec: p,
            nodeId: node.id,
            value: node.params[p.key],
            onChanged: (v) => store.updateNodeParams(node.id, {p.key: v}),
          ),
          if (p.help != null && p.help!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                p.help!,
                style: TextStyle(
                  fontSize: 10,
                  color: t.textFaint,
                  height: 1.35,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // .nf-param-head:flex justify-between gap 6、margin-bottom 3
  Widget _paramHeadRow(
    SyphonTheme t,
    md.ParamSpec p,
    GraphNode node,
    bool isExposed,
  ) {
    return Row(
      children: [
        Expanded(
          child: fluent.Tooltip(
            message: p.help ?? '',
            child: Text(
              p.label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: t.textDim),
            ),
          ),
        ),
        if (p.type != 'button' && p.expose == true)
          _ExposeButton(
            exposed: isExposed,
            onTap: () => GraphStore.instance.toggleExposed(node.id, p.key),
          ),
      ],
    );
  }

  // .nf-out-row:flex gap 6、fontSize 11、padding 3 0
  Widget _outputRow(SyphonTheme t, md.Socket o, ExecResult? result) {
    final obj = result?.outputs[o.id];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          // .nf-out-name:width 76、ellipsis、text
          SizedBox(
            width: 76,
            child: Text(
              o.name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: t.text),
            ),
          ),
          const SizedBox(width: 6),
          // .nf-out-type:width 62、textFaint、fontSize 10
          SizedBox(
            width: 62,
            child: Text(
              md.kSocketLabel[o.type] ?? '',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: t.textFaint),
            ),
          ),
          // .nf-out-val:margin-left auto、右对齐;有值时 success(.nf-out-ok)
          Expanded(
            child: Text(
              obj != null ? _describeOutput(obj) : '未计算',
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: obj != null ? t.success : t.textFaint,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // .nf-props-empty:padding 24 20、textFaint
  Widget _emptyState(SyphonTheme t) {
    const items = [
      ('组输入', '表格 / 坐标轴 / 线 / 面 / 网格'),
      ('数据初步', '清洗 / 标准化 / 筛选 / 抽样'),
      ('数据运算', '求导 / 积分 / 拟合 / 平滑'),
      ('数据转化', '行列提取 / 转散点 / 转曲线 / 转分布'),
      ('数据可视化', '预制图表 + 原理化输出'),
    ];
    return Container(
      width: SyphonDims.propsW,
      color: t.bgSurface,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // .nf-props-empty-title:fontSize 15、text、margin-bottom 12
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text('未选择节点', style: TextStyle(fontSize: 15, color: t.text)),
          ),
          Text(
            '在画布右键弹出"新建节点"菜单,添加节点开始构建数据处理流程。',
            style: TextStyle(fontSize: 12, color: t.textFaint, height: 1.5),
          ),
          // .nf-help-list:margin 12 0 0、padding-left 18、line-height 1.9
          Padding(
            padding: const EdgeInsets.only(top: 12, left: 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [for (final item in items) _helpItem(t, item)],
            ),
          ),
        ],
      ),
    );
  }

  // .nf-help-item:fontSize 12、textFaint、行高 1.9;分类名加粗
  Widget _helpItem(SyphonTheme t, (String, String) item) {
    return Text.rich(
      TextSpan(
        style: TextStyle(fontSize: 12, color: t.textFaint, height: 1.9),
        children: [
          const TextSpan(text: '• '),
          TextSpan(
            text: item.$1,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          TextSpan(text: ' — ${item.$2}'),
        ],
      ),
    );
  }
}
