// 转换链查询测试:conversionPath 应返回最短转换链(允许多步),
// 用于 Alt 拖拽连线时自动插入转换节点。不可转换返回 null。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:syphon_nov/models/data.dart' as md;
import 'package:syphon_nov/models/registry.dart';

void main() {
  test('一步转换:表格→散点/曲线、曲线→散点、散点→表格', () {
    expect(conversionPath(md.SocketType.table, md.SocketType.scatter), [
      'table_to_scatter',
    ]);
    expect(conversionPath(md.SocketType.table, md.SocketType.series), [
      'table_to_series',
    ]);
    expect(conversionPath(md.SocketType.series, md.SocketType.scatter), [
      'series_to_scatter',
    ]);
    expect(conversionPath(md.SocketType.scatter, md.SocketType.table), [
      'scatter_to_table',
    ]);
  });

  test('多步转换:曲线→表格、散点→曲线', () {
    // 曲线→表格:只能 曲线转散点 → 散点转表格
    expect(conversionPath(md.SocketType.series, md.SocketType.table), [
      'series_to_scatter',
      'scatter_to_table',
    ]);
    // 散点→曲线:只能 散点转表格 → 表格转曲线
    expect(conversionPath(md.SocketType.scatter, md.SocketType.series), [
      'scatter_to_table',
      'table_to_series',
    ]);
  });

  test('同类型与不可转换组合返回 null', () {
    expect(conversionPath(md.SocketType.table, md.SocketType.table), isNull);
    expect(conversionPath(md.SocketType.series, md.SocketType.series), isNull);
    expect(conversionPath(md.SocketType.axes, md.SocketType.table), isNull);
    expect(conversionPath(md.SocketType.text, md.SocketType.table), isNull);
    expect(conversionPath(md.SocketType.series, md.SocketType.axes), isNull);
  });

  test('转换链两端类型正确(首节点输入=源,末节点输出=目标)', () {
    final path = conversionPath(md.SocketType.series, md.SocketType.table)!;
    final first = getConfig(path.first)!;
    final last = getConfig(path.last)!;
    expect(first.inputs.first.type, md.SocketType.series);
    expect(last.outputs.first.type, md.SocketType.table);
    // 链内相邻节点首尾相接:前一个输出类型 == 后一个输入类型
    for (var i = 0; i + 1 < path.length; i++) {
      final a = getConfig(path[i])!;
      final b = getConfig(path[i + 1])!;
      expect(a.outputs.first.type, b.inputs.first.type);
    }
  });
}
