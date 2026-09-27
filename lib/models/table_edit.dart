// 表格编辑窗口的数据模型:列(名称 / 类型 / [X][Y] 标记)+ 单元格文本,
// 以及 JSON 双向序列化(节点参数 tableJson)、块操作、TSV 剪贴板与撤销历史。
//
// 为什么用 JSON 而不是 CSV 作为编辑结果的存储:CSV 丢信息(整数/浮点/文本
// 无法区分、空行会被解析器丢弃、首行表头受 headerMode 影响)。tableJson 只在
// 编辑窗口保存时写入,CSV(dataText)仍保留给文件导入与工程预设使用。
library;

import 'dart:convert';

import 'data.dart';

/// 列类型取值 → 表头 {…} 文案
const Map<String, String> kColumnTypeLabels = {
  'double': '双精度浮点',
  'int': '整数',
  'text': '文本',
};

/// 列标记取值 → 表头 […] 文案(空串表示不作标记)
const Map<String, String> kColumnDesignationLabels = {
  'none': '',
  'x': 'X',
  'y': 'Y',
  'z': 'Z',
  'xerr': 'xEr',
  'yerr': 'yEr',
};

/// 合法的列标记取值
const Set<String> kColumnDesignationIds = {
  'none',
  'x',
  'y',
  'z',
  'xerr',
  'yerr',
};

String columnTypeLabel(String type) =>
    kColumnTypeLabels[type] ?? kColumnTypeLabels['double']!;

String columnDesignationLabel(String designation) =>
    kColumnDesignationLabels[designation] ?? '';

/// 列字母:0 → A、25 → Z、26 → AA(与电子表格一致)
String columnLetter(int index) {
  var i = index < 0 ? 0 : index;
  final buffer = StringBuffer();
  do {
    buffer.write(String.fromCharCode(65 + i % 26));
    i = i ~/ 26 - 1;
  } while (i >= 0);
  return String.fromCharCodes(buffer.toString().codeUnits.reversed);
}

/// 按列内容推断类型:全部整数→int,全部数值→double,否则 text
String detectColumnType(List<dynamic> values) {
  var sawValue = false;
  var allInt = true;
  for (final v in values) {
    if (v == null || '$v'.trim().isEmpty) continue;
    sawValue = true;
    final n = v is num ? v : num.tryParse('$v'.trim());
    if (n == null) return 'text';
    if (n is double && n != n.roundToDouble()) allInt = false;
  }
  if (!sawValue) return 'double';
  return allInt ? 'int' : 'double';
}

String _cellText(dynamic v) => formatCellValue(v);

/// 单元格值 → 编辑文本
String formatCellValue(dynamic v) {
  if (v == null) return '';
  if (v is double) {
    if (v == v.roundToDouble() && v.abs() < 1e15) {
      return v.toInt().toString();
    }
    return '$v';
  }
  return '$v';
}

/// 可编辑表格:行优先的单元格文本 + 每列的元数据。
class EditableTable {
  final List<String> names;
  final List<String> types;
  final List<String> designations;
  final List<List<String>> cells;

  EditableTable({
    required this.names,
    required this.types,
    required this.designations,
    required this.cells,
  });

  /// 空表:rows 行 columns 列,列名留空(表头只显示列字母,与 SciDAVis 一致)
  factory EditableTable.empty({int rows = 10, int columns = 2}) {
    return EditableTable(
      names: List<String>.generate(columns, (_) => '', growable: true),
      types: List<String>.generate(columns, (_) => 'double', growable: true),
      designations: List<String>.generate(
        columns,
        (_) => 'none',
        growable: true,
      ),
      cells: List.generate(
        rows,
        (_) => List<String>.generate(columns, (_) => '', growable: true),
      ),
    );
  }

  factory EditableTable.fromColumns(List<Column> columns) {
    final names = <String>[];
    final types = <String>[];
    final designations = <String>[];
    final rows = <List<String>>[];
    for (final c in columns) {
      names.add(c.name);
      types.add(
        c.type.isNotEmpty && kColumnTypeLabels.containsKey(c.type)
            ? c.type
            : detectColumnType(c.values),
      );
      designations.add(
        kColumnDesignationIds.contains(c.designation) ? c.designation : 'none',
      );
    }
    final rowCount = columns.fold<int>(
      0,
      (m, c) => c.values.length > m ? c.values.length : m,
    );
    for (var r = 0; r < rowCount; r++) {
      rows.add([
        for (final c in columns)
          r < c.values.length ? _cellText(c.values[r]) : '',
      ]);
    }
    return EditableTable(
      names: names,
      types: types,
      designations: designations,
      cells: rows,
    );
  }

  int get rowCount => cells.length;
  int get columnCount => names.length;
  bool get isEmpty => names.isEmpty && cells.isEmpty;

  EditableTable clone() => EditableTable(
    names: List<String>.of(names),
    types: List<String>.of(types),
    designations: List<String>.of(designations),
    cells: [for (final row in cells) List<String>.of(row)],
  );

  String cellAt(int row, int column) {
    if (row < 0 || row >= cells.length) return '';
    final r = cells[row];
    if (column < 0 || column >= r.length) return '';
    return r[column];
  }

  void setCell(int row, int column, String text) {
    if (row < 0 || row >= cells.length) return;
    if (column < 0 || column >= columnCount) return;
    while (cells[row].length < columnCount) {
      cells[row].add('');
    }
    cells[row][column] = text;
  }

  void insertRow(int at) {
    final index = at.clamp(0, rowCount);
    cells.insert(
      index,
      List<String>.generate(columnCount, (_) => '', growable: true),
    );
  }

  void removeRow(int at) {
    if (at < 0 || at >= rowCount) return;
    cells.removeAt(at);
  }

  void insertColumn(int at) {
    final index = at.clamp(0, columnCount);
    names.insert(index, '');
    types.insert(index, 'double');
    designations.insert(index, 'none');
    for (final row in cells) {
      while (row.length < columnCount - 1) {
        row.add('');
      }
      row.insert(index, '');
    }
  }

  void removeColumn(int at) {
    if (columnCount <= 1) return; // 至少保留一列
    if (at < 0 || at >= columnCount) return;
    names.removeAt(at);
    types.removeAt(at);
    designations.removeAt(at);
    for (final row in cells) {
      if (at < row.length) row.removeAt(at);
    }
  }

  void setColumnName(int column, String name) {
    if (column < 0 || column >= columnCount) return;
    names[column] = name;
  }

  void setColumnType(int column, String type) {
    if (column < 0 || column >= columnCount) return;
    types[column] = kColumnTypeLabels.containsKey(type) ? type : 'double';
  }

  void setColumnDesignation(int column, String designation) {
    if (column < 0 || column >= columnCount) return;
    designations[column] = kColumnDesignationIds.contains(designation)
        ? designation
        : 'none';
  }

  void clearRange(int r0, int c0, int r1, int c1) {
    for (var r = r0; r <= r1; r++) {
      for (var c = c0; c <= c1; c++) {
        setCell(r, c, '');
      }
    }
  }

  /// 选区(含端点)的文本块
  List<List<String>> block(int r0, int c0, int r1, int c1) {
    final rows = <List<String>>[];
    for (var r = r0; r <= r1; r++) {
      rows.add([for (var c = c0; c <= c1; c++) cellAt(r, c)]);
    }
    return rows;
  }

  /// 选区转为 TSV(剪贴板格式,与 Excel 互通)
  String blockToTsv(int r0, int c0, int r1, int c1) {
    return block(r0, c0, r1, c1).map((row) => row.join('\t')).join('\r\n');
  }

  /// 从 (row, column) 起粘贴文本块,行/列不足时自动扩展。
  void pasteBlock(int row, int column, List<List<String>> block) {
    if (block.isEmpty) return;
    var width = 0;
    for (final r in block) {
      if (r.length > width) width = r.length;
    }
    for (var i = 0; i < width; i++) {
      if (column + i >= columnCount) insertColumn(columnCount);
    }
    for (var i = 0; i < block.length; i++) {
      if (row + i >= rowCount) insertRow(rowCount);
    }
    for (var i = 0; i < block.length; i++) {
      for (var j = 0; j < block[i].length; j++) {
        setCell(row + i, column + j, block[i][j]);
      }
    }
  }

  /// 解析剪贴板文本(TSV/CSV 都接受)
  static List<List<String>> parseClipboard(String text) {
    final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = normalized.split('\n');
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    final delimiter = lines.any((l) => l.contains('\t')) ? '\t' : ',';
    return [
      for (final line in lines)
        delimiter == '\t' ? line.split('\t') : _splitCsvLine(line),
    ];
  }

  static List<String> _splitCsvLine(String line) {
    final out = <String>[];
    final cell = StringBuffer();
    var quoted = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (quoted) {
        if (ch == '"') {
          if (i + 1 < line.length && line[i + 1] == '"') {
            cell.write('"');
            i++;
          } else {
            quoted = false;
          }
        } else {
          cell.write(ch);
        }
      } else if (ch == '"' && cell.isEmpty) {
        quoted = true;
      } else if (ch == ',') {
        out.add(cell.toString());
        cell.clear();
      } else {
        cell.write(ch);
      }
    }
    out.add(cell.toString());
    return out;
  }

  /// 转为数据列:按列类型解析数值,空单元格 → null
  List<Column> toColumns() {
    return [
      for (var c = 0; c < columnCount; c++)
        Column(
          name: names[c],
          type: types[c],
          designation: designations[c],
          values: [
            for (var r = 0; r < rowCount; r++)
              parseCellValue(cells[r][c], types[c]),
          ],
        ),
    ];
  }

  Map<String, dynamic> toJson() => {
    'columns': [
      for (var c = 0; c < columnCount; c++)
        {
          'name': names[c],
          'type': types[c],
          'designation': designations[c],
          'values': [
            for (var r = 0; r < rowCount; r++)
              parseCellValue(cells[r][c], types[c]),
          ],
        },
    ],
  };

  String encode() => jsonEncode(toJson());

  static EditableTable fromJson(Map<String, dynamic> json) {
    final raw = json['columns'];
    final columns = <Column>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        final values = item['values'];
        columns.add(
          Column(
            name: '${item['name'] ?? ''}',
            type: '${item['type'] ?? 'double'}',
            designation: '${item['designation'] ?? 'none'}',
            values: values is List ? List<dynamic>.of(values) : <dynamic>[],
          ),
        );
      }
    }
    return EditableTable.fromColumns(columns);
  }

  static EditableTable? decode(String text) {
    if (text.trim().isEmpty) return null;
    try {
      final json = jsonDecode(text);
      if (json is Map<String, dynamic>) return fromJson(json);
      if (json is Map) return fromJson(Map<String, dynamic>.from(json));
    } catch (_) {
      return null;
    }
    return null;
  }
}

/// 单元格文本 → 该列类型的值(空 → null)
dynamic parseCellValue(String text, String type) {
  final raw = text.trim();
  if (raw.isEmpty) return null;
  switch (type) {
    case 'text':
      return text;
    case 'int':
      final i = int.tryParse(raw);
      if (i != null) return i;
      final d = double.tryParse(raw);
      if (d != null && d == d.roundToDouble()) return d.toInt();
      return text;
    default:
      final d = double.tryParse(raw);
      if (d != null) return d;
      final i = int.tryParse(raw);
      return i ?? text;
  }
}

/// 撤销/重做:保存整表快照(表格通常只有几百个单元格,快照足够廉价)
class TableEditHistory {  final int limit;
  final List<EditableTable> _past = [];
  final List<EditableTable> _future = [];

  TableEditHistory({this.limit = 60});

  bool get canUndo => _past.isNotEmpty;
  bool get canRedo => _future.isNotEmpty;

  /// 在修改之前调用:记录当前状态
  void record(EditableTable before) {
    _past.add(before.clone());
    if (_past.length > limit) _past.removeAt(0);
    _future.clear();
  }

  /// 返回撤销后的表格(无可撤销时返回 null)
  EditableTable? undo(EditableTable current) {
    if (_past.isEmpty) return null;
    _future.add(current.clone());
    if (_future.length > limit) _future.removeAt(0);
    return _past.removeLast();
  }

  EditableTable? redo(EditableTable current) {
    if (_future.isEmpty) return null;
    _past.add(current.clone());
    return _future.removeLast();
  }

  void clear() {
    _past.clear();
    _future.clear();
  }
}
