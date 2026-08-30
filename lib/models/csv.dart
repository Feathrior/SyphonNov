// CSV/TSV 解析与 Excel 导入(由 React 版 utils/csv.ts 移植)
library;

import 'dart:convert';
import 'dart:io';

import 'package:excel/excel.dart' as xls;

import 'data.dart';

/// 简易 CSV/TSV 解析(支持引号包裹)
List<Column> parseDelimitedText(String text, [String delimiter = ',']) {
  final lines = text
      .replaceAll('\r\n', '\n')
      .split('\n')
      .map((l) => l.trimRight())
      .where((l) => l.trim().isNotEmpty)
      .toList();
  if (lines.isEmpty) return [];

  List<String> splitLine(String line) {
    final cells = <String>[];
    var cur = '';
    var inQuote = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (inQuote && i + 1 < line.length && line[i + 1] == '"') {
          cur += '"';
          i++;
        } else {
          inQuote = !inQuote;
        }
      } else if (ch == delimiter && !inQuote) {
        cells.add(cur);
        cur = '';
      } else {
        cur += ch;
      }
    }
    cells.add(cur);
    return cells;
  }

  final rows = lines.map(splitLine).toList();
  var width = 0;
  for (final r in rows) {
    if (r.length > width) width = r.length;
  }
  final names = <String>[];
  for (var c = 0; c < width; c++) {
    final first = (rows[0].length > c ? rows[0][c] : '').trim();
    final looksHeader = first.isNotEmpty && num.tryParse(first) == null;
    names.add(looksHeader ? first : '列${c + 1}');
  }
  final hasHeader = rows[0].asMap().entries.any(
    (e) =>
        e.value.trim() == names[e.key] && num.tryParse(e.value.trim()) == null,
  );
  final startRow = hasHeader ? 1 : 0;

  final columns = names
      .map((name) => Column(name: name, values: <dynamic>[]))
      .toList();
  for (var r = startRow; r < rows.length; r++) {
    for (var c = 0; c < width; c++) {
      final raw = (rows[r].length > c ? rows[r][c] : '').trim();
      if (raw.isEmpty) {
        columns[c].values.add(null);
      } else {
        // 数字字符串转为 num,非数字字符串(如中文分类标签)保留原始文本。
        final n = num.tryParse(raw);
        columns[c].values.add(n ?? raw);
      }
    }
  }
  return columns;
}

/// 解析 Excel 文件字节(取第一个工作表)→ 表格列
/// 依赖 excel 包,失败时抛出异常
List<Column> excelBytesToColumns(List<int> bytes) {
  final excel = xls.Excel.decodeBytes(bytes);
  final tables = excel.tables;
  if (tables.isEmpty) throw Exception('Excel 文件没有工作表');
  final sheet = tables.values.first;
  final rows = sheet.rows;
  if (rows.isEmpty) return [];
  var width = 0;
  for (final r in rows) {
    if (r.length > width) width = r.length;
  }
  if (width == 0) return [];
  // 首行作为列名
  final names = <String>[];
  for (var c = 0; c < width; c++) {
    final cell = rows[0].length > c ? rows[0][c] : null;
    final raw = _cellText(cell).trim();
    names.add(raw.isNotEmpty && num.tryParse(raw) == null ? raw : '列${c + 1}');
  }
  final columns = names
      .map((n) => Column(name: n, values: <dynamic>[]))
      .toList();
  for (var r = 1; r < rows.length; r++) {
    for (var c = 0; c < width; c++) {
      final cell = rows[r].length > c ? rows[r][c] : null;
      final raw = _cellText(cell).trim();
      if (raw.isEmpty) {
        columns[c].values.add(null);
      } else {
        final n = num.tryParse(raw);
        columns[c].values.add(n ?? raw);
      }
    }
  }
  return columns;
}

String _cellText(xls.Data? cell) {
  if (cell == null) return '';
  final v = cell.value;
  if (v == null) return '';
  return '$v';
}

/// 读取数据文件(csv/tsv/txt/xlsx/xls)并转为统一 CSV 文本。
/// - 文本文件按 UTF-8 解码(容错),避免中文乱码;
/// - Excel 取第一个工作表并序列化为 CSV 文本;
/// 失败(不存在/损坏/不支持格式)时抛出异常。
Future<String> dataFileToCsvText(String path) async {
  final lower = path.toLowerCase();
  final bytes = await File(path).readAsBytes();
  if (lower.endsWith('.xlsx') || lower.endsWith('.xls')) {
    return columnsToCsv(excelBytesToColumns(bytes));
  }
  return utf8.decode(bytes, allowMalformed: true);
}

/// 表格列 → CSV 文本(带引号转义;列名/数值原样输出)
String columnsToCsv(List<Column> columns) {
  if (columns.isEmpty) return '';
  final rows = <List<String>>[];
  rows.add(columns.map((c) => csvCell(c.name)).toList());
  final n = columns
      .map((c) => c.values.length)
      .fold(0, (a, b) => a > b ? a : b);
  for (var i = 0; i < n; i++) {
    rows.add(
      columns
          .map((c) => csvCell(i < c.values.length ? c.values[i] : null))
          .toList(),
    );
  }
  return rows.map((r) => r.join(',')).join('\n');
}

String csvCell(dynamic v) {
  if (v == null) return '';
  final s = '$v';
  if (s.contains(',') || s.contains('"') || s.contains('\n')) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}
