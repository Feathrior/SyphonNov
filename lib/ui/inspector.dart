// 检查器:选中节点的输出数据预览 + 运行日志(由 React 版 Inspector.tsx 移植)
library;

import 'package:flutter/material.dart';

import '../models/data.dart' as md;
import '../models/registry.dart';
import '../store/graph_store.dart';
import 'theme.dart';

String _kindName(md.DataObject o) {
  if (o is md.TableData) return 'table';
  if (o is md.SeriesData) return 'series';
  if (o is md.ScatterData) return 'scatter';
  if (o is md.MeshData) return 'mesh';
  if (o is md.GridData) return 'grid';
  if (o is md.DistributionData) return 'distribution';
  if (o is md.AxesData) return 'axes';
  if (o is md.TextData) return 'text';
  if (o is md.ColorbarData) return 'colorbar';
  return 'object';
}

// ==================== 数据表格 ====================

class _MiniTable extends StatelessWidget {
  final List<String> headers;
  final List<List<String>> rows;
  final String? footer;

  const _MiniTable({required this.headers, required this.rows, this.footer});

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    // .nf-table-wrap:overflow auto、max-height 96
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 96),
          child: SingleChildScrollView(
            scrollDirection: Axis.vertical,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Table(
                // .nf-table th,td:border 1px stroke
                border: TableBorder.all(color: t.stroke, width: 1),
                columnWidths: {0: const FixedColumnWidth(30)},
                defaultColumnWidth: const IntrinsicColumnWidth(),
                children: [
                  // .nf-table th:bg-float、textDim
                  TableRow(
                    decoration: BoxDecoration(color: t.bgFloat),
                    children: [
                      _Cell('', header: true),
                      for (final h in headers) _Cell(h, header: true),
                    ],
                  ),
                  for (final r in rows)
                    TableRow(children: [
                      _Cell('${rows.indexOf(r)}'),
                      for (var i = 0; i < r.length; i++) _Cell(r[i]),
                    ]),
                ],
              ),
            ),
          ),
        ),
        if (footer != null)
          // .nf-table-more:textFaint、fontSize 10、padding 3 0
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text(footer!,
                style: TextStyle(fontSize: 10, color: t.textFaint)),
          ),
      ],
    );
  }
}

// .nf-table th,td:padding 2 8、fontSize 11、nowrap;th 为 textDim + w600
class _Cell extends StatelessWidget {
  final String text;
  final bool header;

  const _Cell(this.text, {this.header = false});

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Text(
        text,
        softWrap: false,
        overflow: TextOverflow.visible,
        style: TextStyle(
          fontSize: 11,
          color: header ? t.textDim : t.text,
          fontWeight: header ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
    );
  }
}

// .nf-obj-summary:fontSize 12、text、line-height 1.8
class _Summary extends StatelessWidget {
  final List<String> lines;

  const _Summary(this.lines);

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final l in lines)
          Text(l, style: TextStyle(fontSize: 12, color: t.text, height: 1.8)),
      ],
    );
  }
}

// ==================== 对象预览 ====================

class ObjectPreview extends StatelessWidget {
  final md.DataObject obj;

  const ObjectPreview({super.key, required this.obj});

  @override
  Widget build(BuildContext context) {
    final o = obj; // 局部变量以便类型提升
    if (o is md.TableData) {
      final cols = o.columns;
      final rows = cols.isEmpty ? 0 : cols.first.values.length;
      final shown = rows < 8 ? rows : 8;
      return _MiniTable(
        headers: [for (final c in cols) c.name],
        rows: [
          for (var r = 0; r < shown; r++)
            [for (final c in cols) c.values[r] == null ? '—' : '${c.values[r]}'],
        ],
        footer: rows > shown ? '…共 $rows 行' : null,
      );
    }
    if (o is md.SeriesData) {
      final pts = o.points.length < 12 ? o.points : o.points.sublist(0, 12);
      return _MiniTable(
        headers: const ['x', 'y'],
        rows: [
          for (final p in pts) [p.x.toString(), p.y.toString()],
        ],
        footer: '共 ${o.points.length} 个点',
      );
    }
    if (o is md.ScatterData) {
      final pts = o.points.length < 12 ? o.points : o.points.sublist(0, 12);
      return _MiniTable(
        headers: const ['x', 'y', 'z'],
        rows: [
          for (final p in pts)
            [p.x.toString(), p.y.toString(), p.z?.toString() ?? '—'],
        ],
        footer: '共 ${o.points.length} 个点',
      );
    }
    if (o is md.MeshData) {
      return _Summary([
        '顶点: ${o.vertices.length}',
        '三角面: ${o.faces.length}',
        '名称: ${o.name}',
      ]);
    }
    if (o is md.GridData) {
      final finite = <double>[
        for (final row in o.values)
          for (final v in row)
            if (v.isFinite) v
      ];
      final zMin = finite.isEmpty ? double.nan : finite.reduce((a, b) => a < b ? a : b);
      final zMax = finite.isEmpty ? double.nan : finite.reduce((a, b) => a > b ? a : b);
      final x0 = o.x.isEmpty ? 0 : o.x.first;
      final x1 = o.x.isEmpty ? 0 : o.x.last;
      final y0 = o.y.isEmpty ? 0 : o.y.first;
      final y1 = o.y.isEmpty ? 0 : o.y.last;
      return _Summary([
        'X 范围: $x0 ~ $x1(${o.x.length})',
        'Y 范围: $y0 ~ $y1(${o.y.length})',
        'Z 范围: ${zMin.isNaN ? '—' : zMin} ~ ${zMax.isNaN ? '—' : zMax}',
      ]);
    }
    if (o is md.DistributionData) {
      final bins = o.bins.length < 12 ? o.bins : o.bins.sublist(0, 12);
      return _MiniTable(
        headers: const ['区间', '计数'],
        rows: [
          for (final b in bins)
            ['[${b.x0.toStringAsFixed(3)}, ${b.x1.toStringAsFixed(3)})', '${b.count}'],
        ],
        footer: '共 ${o.bins.length} 组, ${o.sampleCount} 个样本',
      );
    }
    if (o is md.AxesData) {
      return _Summary([
        '维度: ${o.dim}D',
        '像素: ${o.xLen} × ${o.yLen} × ${o.zLen}',
        '范围: X ${o.xMin}~${o.xMax} / Y ${o.yMin}~${o.yMax}'
            '${o.dim == 3 ? ' / Z ${o.zMin}~${o.zMax}' : ''}',
        '定位: ${o.axisOrigin == 'origin' ? '以原点为中心' : '总贴左边沿'}'
            '${o.grid ? ' · 网格开' : ' · 网格关'}'
            '${o.showBorder ? ' · 边框开' : ' · 边框关'}',
        '标签: ${o.labelX} / ${o.labelY} / ${o.labelZ}',
      ]);
    }
    if (o is md.TextData) {
      return _Summary([
        '文本: "${o.text}"',
        '大小: ${o.fontSize}cm · 对齐: ${o.halign}/${o.valign}',
      ]);
    }
    if (o is md.ColorbarData) {
      return _Summary([
        '渐变: ${o.stops.length} 段',
        '范围: ${o.min ?? '—'} ~ ${o.max ?? '—'}'
            '${o.horizontal == false ? ' · 垂直' : ' · 水平'}',
      ]);
    }
    return const _Summary(['未知数据对象']);
  }
}

// ==================== 检查器主体 ====================

class Inspector extends StatefulWidget {
  const Inspector({super.key});

  @override
  State<Inspector> createState() => _InspectorState();
}

class _InspectorState extends State<Inspector> {
  String _tab = 'data';

  @override
  Widget build(BuildContext context) {
    final store = GraphStore.instance;
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final t = SyphonTheme.of(context);
        final errors = _collectErrors(store);

        // .nf-inspector:height 190、bg-surface、border-top 1px stroke、flex column
        return Container(
          height: SyphonDims.inspectorH,
          decoration: BoxDecoration(
            color: t.bgSurface,
            border: Border(top: BorderSide(color: t.stroke, width: 1)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // .nf-inspector-tabs:flex gap 4、padding 6 12 0
              Padding(
                padding: const EdgeInsets.only(left: 12, right: 12, top: 6),
                child: Row(
                  children: [
                    _TabBtn(
                      text: '数据预览',
                      active: _tab == 'data',
                      errorCount: 0,
                      showBadge: false,
                      onTap: () => setState(() => _tab = 'data'),
                    ),
                    const SizedBox(width: 4),
                    _TabBtn(
                      text: '日志',
                      active: _tab == 'log',
                      errorCount: errors.length,
                      showBadge: true,
                      onTap: () => setState(() => _tab = 'log'),
                    ),
                  ],
                ),
              ),
              // .nf-inspector-body:flex 1、overflow auto、padding 8 12、bg-raise
              Expanded(
                child: Container(
                  color: t.bgRaise,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: _tab == 'data'
                      ? _dataTab(context, t, store)
                      : _logTab(context, t, store, errors),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  List<({String nodeId, String label, String msg})> _collectErrors(GraphStore store) {
    final out = <({String nodeId, String label, String msg})>[];
    for (final entry in store.results.entries) {
      final r = entry.value;
      if (r.error == null) continue;
      String label = entry.key;
      for (final n in store.nodes) {
        if (n.id == entry.key) {
          final cfg = getConfig(n.configId);
          label = cfg?.label ?? entry.key;
          break;
        }
      }
      out.add((nodeId: entry.key, label: label, msg: r.error!));
    }
    return out;
  }

  // ---------------- 数据预览 ----------------

  Widget _dataTab(BuildContext context, SyphonTheme t, GraphStore store) {
    GraphNode? node;
    for (final n in store.nodes) {
      if (n.id == store.selectedId) {
        node = n;
        break;
      }
    }
    if (node == null) {
      return _hint('点击节点查看输出数据预览', t);
    }
    final cfg = getConfig(node.configId);
    final result = store.results[node.id];
    if (cfg == null || result == null) {
      return _hint('点击节点查看输出数据预览', t);
    }
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        // .nf-inspector-title:fontSize 12、textFaint、margin-bottom 8
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text('${cfg.label} 的输出',
              style: TextStyle(fontSize: 12, color: t.textFaint)),
        ),
        if (result.outputs.isEmpty)
          _hint(
            result.error != null
                ? '执行出错:${result.error}'
                : (cfg.isViewer ? '此节点为可视化节点,查看节点内图表' : '该节点无输出'),
            t,
          )
        else
          for (final entry in result.outputs.entries) ...[
            // .nf-inspector-block-title:fontSize 10、textFaint、mono、margin-bottom 4
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('${entry.key} · ${_kindName(entry.value)}',
                  style: TextStyle(
                      fontSize: 10,
                      color: t.textFaint,
                      fontFamily: SyphonDims.monoFont)),
            ),
            ObjectPreview(obj: entry.value),
            const SizedBox(height: 10), // .nf-inspector-block margin-bottom 10
          ],
      ],
    );
  }

  // ---------------- 日志 ----------------

  Widget _logTab(
      BuildContext context, SyphonTheme t, GraphStore store,
      List<({String nodeId, String label, String msg})> errors) {
    final okCount = store.results.values.where((r) => r.error == null).length;
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        // .nf-inspector-log:mono、fontSize 11
        for (final l in store.logs) _logEntry(t, l),
        if (store.logs.isNotEmpty)
          // .nf-log-sep:border-top 1px dashed strokeStrong、margin 6 0
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: _DashedLine(t.strokeStrong),
          ),
        if (store.hasCycle)
          _logLine(t, '⚠ 检测到连接回路,部分节点未按顺序执行', error: true),
        if (store.lastError != null)
          _logLine(t, store.lastError!, error: true),
        if (errors.isEmpty && !store.hasCycle && store.logs.isEmpty)
          _logLine(t, '执行正常,无错误。'),
        for (final e in errors)
          _logLine(t, '[${e.label}] ${e.msg}', error: true),
        if (okCount > 0)
          _logLine(t, '$okCount 个节点执行成功', ok: true),
      ],
    );
  }

  // .nf-log-line:padding 3 0、textDim;error → danger;ok → success
  Widget _logEntry(SyphonTheme t, LogEntry l) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3), // .nf-log-line padding 3 0
      child: Text.rich(
        TextSpan(
          style: TextStyle(
              fontFamily: SyphonDims.monoFont, fontSize: 11, color: t.textDim),
          children: [
            // .nf-log-time:textFaint、mono、margin-right 6
            TextSpan(text: l.time, style: TextStyle(color: t.textFaint)),
            TextSpan(
              text: '  ${l.msg}',
              style: TextStyle(
                color: l.level == 'error'
                    ? t.danger
                    : (l.level == 'ok' ? t.success : t.textDim),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // .nf-log-line:padding 3 0、textDim;error → danger;ok → success
  Widget _logLine(SyphonTheme t, String text, {bool error = false, bool ok = false}) {
    final color = error ? t.danger : (ok ? t.success : t.textDim);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Text(text,
          style: TextStyle(
              fontFamily: SyphonDims.monoFont, fontSize: 11, color: color)),
    );
  }

  // .nf-inspector-hint:textFaint、fontSize 12、padding 10 0
  Widget _hint(String text, SyphonTheme t) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Text(text, style: TextStyle(fontSize: 12, color: t.textFaint)),
    );
  }
}

// ==================== 标签页按钮 ====================
// .nf-inspector-tab:透明、textFaint、padding 6 14、fontSize 12、radius 4 4 0 0
// hover:bg-raise + text   active:accent + 底部 2px accent 指示条(左右内缩 10)
class _TabBtn extends StatefulWidget {
  final String text;
  final bool active;
  final int errorCount;
  final bool showBadge;
  final VoidCallback onTap;

  const _TabBtn({
    required this.text,
    required this.active,
    required this.errorCount,
    required this.showBadge,
    required this.onTap,
  });

  @override
  State<_TabBtn> createState() => _TabBtnState();
}

class _TabBtnState extends State<_TabBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    final fg = widget.active
        ? t.accent
        : (_hover ? t.text : t.textFaint);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            _buildButton(t, fg),
            // 底部 accent 指示条(左右内缩 10)
            if (widget.active) _buildIndicator(t),
          ],
        ),
      ),
    );
  }

  Widget _buildButton(SyphonTheme t, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: _hover && !widget.active ? t.bgRaise : Colors.transparent,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(SyphonDims.radiusS),
          topRight: Radius.circular(SyphonDims.radiusS),
        ),
      ),
      child: Row(
        children: [
          Text(widget.text,
              style: TextStyle(
                  fontSize: 12,
                  color: fg,
                  fontWeight:
                      widget.active ? FontWeight.w600 : FontWeight.w400)),
          if (widget.showBadge && widget.errorCount > 0) _buildBadge(t),
        ],
      ),
    );
  }

  // .nf-log-badge:height 15、margin-left 5、padding 0 4、radius 8、bg danger、#fff、fontSize 10
  Widget _buildBadge(SyphonTheme t) {
    return Container(
      margin: const EdgeInsets.only(left: 5),
      height: 15,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      constraints: const BoxConstraints(minWidth: 15),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: t.danger,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text('${widget.errorCount}',
          style: const TextStyle(fontSize: 10, color: Color(0xFFFFFFFF))),
    );
  }

  Widget _buildIndicator(SyphonTheme t) {
    return Positioned(
      left: 10,
      right: 10,
      bottom: 0,
      child: Container(
        height: 2,
        decoration: BoxDecoration(
          color: t.accent,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

// 水平虚线(用于日志分隔符 .nf-log-sep)
class _DashedLine extends StatelessWidget {
  final Color color;
  const _DashedLine(this.color);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, c) => SizedBox(
        height: 1,
        width: c.maxWidth,
        child: CustomPaint(painter: _DashPainter(color)),
      ),
    );
  }
}

class _DashPainter extends CustomPainter {
  final Color color;
  _DashPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    const dash = 4.0, gap = 3.0;
    for (var x = 0.0; x < size.width; x += dash + gap) {
      canvas.drawLine(
        Offset(x, 0.5),
        Offset((x + dash).clamp(0.0, size.width), 0.5),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_DashPainter old) => old.color != color;
}
