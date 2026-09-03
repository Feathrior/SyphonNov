// 迷你表格:检查器"数据预览"与"数据输出"节点共用同一套实现
// (原 inspector.dart 的 _MiniTable/_Cell 提取;列宽 IntrinsicColumnWidth
//  按内容自适应,不会撑满整个预览窗)
library;

import 'package:flutter/material.dart';

import 'theme.dart';

/// 迷你表格:内容宽度自适应、横向/纵向双层滚动 + 常显竖向滚动条、主题配色。
/// 表格左侧自动带序号列(角格留空)。
///
/// [maxHeight]:有限值时限制表格可视高度(超出部分滚动);
/// `double.infinity` 时不做显式限制,由父级约束(如 Expanded)决定可视高度。
class MiniTable extends StatefulWidget {
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
  State<MiniTable> createState() => _MiniTableState();
}

class _MiniTableState extends State<MiniTable> {
  // 竖向滚动控制器:滚动条与视图共用,保证同滚同止
  final ScrollController _v = ScrollController();

  @override
  void dispose() {
    _v.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    final table = Table(
      // .nf-table th,td:border 1px stroke
      border: TableBorder.all(color: t.stroke, width: 1),
      columnWidths: {0: const FixedColumnWidth(30)},
      defaultColumnWidth: const IntrinsicColumnWidth(),
      children: [
        // .nf-table th:bg-float、textDim
        TableRow(
          decoration: BoxDecoration(color: t.bgFloat),
          children: [
            MiniTableCell('', header: true),
            for (final h in widget.headers) MiniTableCell(h, header: true),
          ],
        ),
        for (final r in widget.rows)
          TableRow(
            children: [
              MiniTableCell('${widget.rows.indexOf(r)}'),
              for (var i = 0; i < r.length; i++) MiniTableCell(r[i]),
            ],
          ),
      ],
    );
    // 竖向滚动 + 常显滚动条;内部再包横向滚动(列多时可左右滚动)。
    // 注意:应用根(FluentApp)自带 FluentScrollBehavior,Windows 上会给每个
    // 纵向 Scrollable 再包一层 Scrollbar——这里显式关闭,避免双滚动条。
    final scroll = ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: Scrollbar(
        controller: _v,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _v,
          scrollDirection: Axis.vertical,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: table,
          ),
        ),
      ),
    );
    // maxHeight 为有限数字 → ConstrainedBox 显式封顶(检查器"数据预览"用 96);
    // double.infinity → 必须用 Expanded(flex 子级)让父级分配高度——
    // 普通非弹性子级会被 Flex 以无界主轴约束布局,行一多就超高溢出。
    final body = widget.maxHeight.isFinite
        ? ConstrainedBox(
            constraints: BoxConstraints(maxHeight: widget.maxHeight),
            child: scroll,
          )
        : Expanded(child: scroll);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        body,
        if (widget.footer != null)
          // .nf-table-more:textFaint、fontSize 10、padding 3 0
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text(
              widget.footer!,
              style: TextStyle(fontSize: 10, color: t.textFaint),
            ),
          ),
      ],
    );
  }
}

// .nf-table th,td:padding 2 8、fontSize 11、nowrap;th 为 textDim + w600
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
