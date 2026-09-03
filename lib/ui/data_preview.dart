// 迷你表格:检查器"数据预览"与"数据输出"节点共用同一套实现
// (原 inspector.dart 的 _MiniTable/_Cell 提取;列宽 IntrinsicColumnWidth
//  按内容自适应,不会撑满整个预览窗)
// 滚动条:直接用 Flutter 自动 Material Scrollbar,不自定义。
library;

import 'package:flutter/material.dart';

import 'theme.dart';

/// 迷你表格:内容宽度自适应、纵向/横向双层滚动,滚动条由 Flutter 自动提供。
/// 表格左侧自动带序号列(角格留空)。
///
/// [maxHeight]:有限值时限制表格可视高度(超出部分滚动);
/// `double.infinity` 时不做显式限制,由父级约束(如 Expanded)决定可视高度。
class MiniTable extends StatelessWidget {
  final List<String> headers;
  final List<List<String>> rows;
  final String? footer;
  final double maxHeight;

  const MiniTable({
    super.key,
    required this.headers,
    required this.rows,
    this.footer,
    this.maxHeight = 96,
  });

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    final table = Table(
      border: TableBorder.all(color: t.stroke, width: 1),
      columnWidths: {0: const FixedColumnWidth(30)},
      defaultColumnWidth: const IntrinsicColumnWidth(),
      children: [
        TableRow(
          decoration: BoxDecoration(color: t.bgFloat),
          children: [
            MiniTableCell('', header: true),
            for (final h in headers) MiniTableCell(h, header: true),
          ],
        ),
        for (final r in rows)
          TableRow(
            children: [
              MiniTableCell('${rows.indexOf(r)}'),
              for (var i = 0; i < r.length; i++) MiniTableCell(r[i]),
            ],
          ),
      ],
    );
    // 外:纵向滚动;内:横向滚动。Material Scrollbar 自动挂在最外层 ScrollView 上。
    final body = SingleChildScrollView(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: table,
      ),
    );
    final sized = maxHeight.isFinite
        ? ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: body,
          )
        : Expanded(child: body);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        sized,
        if (footer != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text(
              footer!,
              style: TextStyle(fontSize: 10, color: t.textFaint),
            ),
          ),
      ],
    );
  }
}

class MiniTableCell extends StatelessWidget {
  final String text;
  final bool header;

  const MiniTableCell(this.text, {this.header = false, super.key});

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
