// CSV/TSV 解析与 Excel 导入(由 React 版 utils/csv.ts 移植)
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'data.dart';

/// 取文件路径的基础名:去掉目录与扩展名(兼容 / 与 \ 分隔符)。
/// 如 `C:/data/销量报表.csv` → `销量报表`。
String fileBaseName(String path) {
  final base = path.split(RegExp(r'[\\/]')).last;
  final dot = base.lastIndexOf('.');
  return dot > 0 ? base.substring(0, dot) : base;
}

enum HeaderMode { auto, present, absent }

/// RFC-style CSV/TSV parser. Record separators inside quoted fields are data.
List<Column> parseDelimitedText(
  String text, [
  String delimiter = ',',
  HeaderMode headerMode = HeaderMode.auto,
]) {
  if (delimiter.length != 1) {
    throw ArgumentError.value(delimiter, 'delimiter', '必须是单个字符');
  }
  final rows = <List<String>>[];
  var row = <String>[];
  var cell = StringBuffer();
  var quoted = false;
  var afterQuote = false;
  void finishCell() {
    row.add(cell.toString());
    cell = StringBuffer();
    afterQuote = false;
  }

  void finishRow() {
    finishCell();
    if (row.any((value) => value.isNotEmpty)) rows.add(row);
    row = <String>[];
  }

  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (quoted) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = false;
          afterQuote = true;
        }
      } else {
        cell.write(ch);
      }
      continue;
    }
    if (ch == '"' && cell.isEmpty && !afterQuote) {
      quoted = true;
    } else if (ch == delimiter) {
      finishCell();
    } else if (ch == '\n' || ch == '\r') {
      if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      finishRow();
    } else if (afterQuote && ch.trim().isNotEmpty) {
      throw const FormatException('引号字段结束后出现非法字符');
    } else if (!afterQuote) {
      cell.write(ch);
    }
  }
  if (quoted) throw const FormatException('CSV 引号字段未闭合');
  if (cell.isNotEmpty || row.isNotEmpty) finishRow();
  if (rows.isEmpty) return [];
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
  final firstAllText = List.generate(width, (c) {
    final first = c < rows[0].length ? rows[0][c].trim() : '';
    return first.isNotEmpty && num.tryParse(first) == null;
  }).every((value) => value);
  final laterHasNumeric = rows
      .skip(1)
      .any((r) => r.any((value) => num.tryParse(value.trim()) != null));
  final autoHeader = rows.length > 1 && firstAllText && laterHasNumeric;
  final hasHeader = switch (headerMode) {
    HeaderMode.present => true,
    HeaderMode.absent => false,
    HeaderMode.auto => autoHeader,
  };
  if (!hasHeader) {
    for (var c = 0; c < names.length; c++) {
      names[c] = '列${c + 1}';
    }
  }
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

/// 解析 Excel 文件字节(取第一个工作表)→ 表格列。
/// 直接解压 zip 读取 OOXML(workbook / sharedStrings / sheet),
/// 首行为列名,数值转为 num,其余为字符串。
List<Column> xlsxBytesToColumns(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);

  // 1) 工作簿:sheets 顺序 + 名称 + rId
  final wb = _xlsxPart(archive, 'xl/workbook.xml');
  if (wb == null) throw Exception('缺少 xl/workbook.xml,不是有效的 xlsx');
  final wbDoc = XmlDocument.parse(wb);
  final sheetEls = wbDoc.findAllElements('sheet').toList();
  if (sheetEls.isEmpty) throw Exception('xlsx 没有工作表');
  final rId = _attrLocal(sheetEls.first, 'id');

  // 2) 关系表:rId → sheet 文件路径
  var target = 'xl/worksheets/sheet1.xml';
  final rels = _xlsxPart(archive, 'xl/_rels/workbook.xml.rels');
  if (rels != null && rId != null) {
    final relsDoc = XmlDocument.parse(rels);
    for (final rel in relsDoc.findAllElements('Relationship')) {
      if (_attrLocal(rel, 'Id') == rId) {
        final t = _attrLocal(rel, 'Target');
        if (t != null) {
          target = t.startsWith('/') ? t.substring(1) : 'xl/$t';
        }
        break;
      }
    }
  }

  // 3) 共享字符串表
  final shared = <String>[];
  final ss = _xlsxPart(archive, 'xl/sharedStrings.xml');
  if (ss != null) {
    final ssDoc = XmlDocument.parse(ss);
    for (final si in ssDoc.findAllElements('si')) {
      shared.add(si.findAllElements('t').map((t) => t.innerText).join());
    }
  }

  // 4) 工作表数据
  final sheetXml =
      _xlsxPart(archive, target) ??
      _xlsxPart(archive, 'xl/worksheets/sheet1.xml');
  if (sheetXml == null) throw Exception('找不到工作表文件 $target');
  final sheetDoc = XmlDocument.parse(sheetXml);

  /// "A1" → 列索引;无法解析时用顺序编号
  int colOf(String ref, int fallback) {
    var col = 0;
    var seen = false;
    for (final ch in ref.codeUnits) {
      if (ch >= 65 && ch <= 90) {
        col = col * 26 + (ch - 64);
        seen = true;
      } else if (seen) {
        break;
      }
    }
    return seen ? col - 1 : fallback;
  }

  final rows = <List<dynamic>>[];
  var maxW = 0;
  for (final row in sheetDoc.findAllElements('row')) {
    final cells = <(int, dynamic)>[];
    var fallbackIdx = 0;
    for (final c in row.findAllElements('c')) {
      final ref = _attrLocal(c, 'r') ?? '';
      final idx = colOf(ref, fallbackIdx);
      fallbackIdx++;
      final t = _attrLocal(c, 't');
      dynamic v;
      if (t == 's') {
        final vNode = c.findAllElements('v').isEmpty
            ? null
            : c.findAllElements('v').first;
        final si = vNode == null ? null : int.tryParse(vNode.innerText);
        v = (si == null || si < 0 || si >= shared.length) ? '' : shared[si];
      } else if (t == 'inlineStr') {
        v = c.findAllElements('t').map((e) => e.innerText).join();
      } else {
        final vNode = c.findAllElements('v').isEmpty
            ? null
            : c.findAllElements('v').first;
        final raw = vNode == null ? '' : vNode.innerText;
        if (t == 'b') {
          v = raw == '1';
        } else if (t == 'str' || t == 'e') {
          v = raw;
        } else {
          // 默认为数值/文本:数字 -> num,否则原文
          v = num.tryParse(raw) ?? raw;
        }
      }
      cells.add((idx, v));
      if (idx + 1 > maxW) maxW = idx + 1;
    }
    final line = List<dynamic>.filled(maxW, '', growable: false);
    for (final (idx, v) in cells) {
      if (idx < line.length) line[idx] = v;
    }
    rows.add(line);
  }
  if (rows.isEmpty) return [];
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].length < maxW) {
      rows[i] = [
        ...rows[i],
        ...List<dynamic>.filled(maxW - rows[i].length, ''),
      ];
    }
  }

  // 5) 首行作列名(与 excel 包逻辑一致),其余为数据
  final names = <String>[];
  for (var c = 0; c < maxW; c++) {
    final first = '${rows[0][c]}'.trim();
    names.add(
      first.isNotEmpty && num.tryParse(first) == null ? first : '列${c + 1}',
    );
  }
  final columns = names
      .map((n) => Column(name: n, values: <dynamic>[]))
      .toList();
  // 数据从第二行起(首行为列名)
  for (var r = 1; r < rows.length; r++) {
    for (var c = 0; c < maxW; c++) {
      final raw = '${rows[r][c] ?? ''}'.trim();
      if (raw.isEmpty) {
        columns[c].values.add(null);
      } else {
        columns[c].values.add(num.tryParse(raw) ?? raw);
      }
    }
  }
  return columns;
}

/// 提取元素的本地名属性
String? _attrLocal(XmlElement e, String local) {
  for (final a in e.attributes) {
    if (a.name.local == local) return a.value;
  }
  return null;
}

/// 从 zip 中读取第一个后缀匹配的文件内容(UTF-8)
String? _xlsxPart(Archive archive, String suffix) {
  for (final f in archive.files) {
    if (f.name.endsWith(suffix)) {
      return utf8.decode(f.content, allowMalformed: false);
    }
  }
  return null;
}

/// 读取数据文件(csv/tsv/txt/xlsx)并转为统一 CSV 文本。
/// - 文本文件严格按 UTF-8 解码，损坏内容会明确报错;
/// - Excel 取第一个工作表并序列化为 CSV 文本(自研 OOXML 解析器);
/// 失败(不存在/损坏/不支持格式)时抛出异常。
Future<String> dataFileToCsvText(
  String path, {
  bool strictEncoding = true,
}) async {
  final lower = path.toLowerCase();
  final bytes = await File(path).readAsBytes();
  if (lower.endsWith('.xls')) {
    throw const FormatException('不支持传统二进制 .xls；请另存为 .xlsx 或 CSV');
  }
  if (lower.endsWith('.xlsx')) {
    try {
      return columnsToCsv(xlsxBytesToColumns(bytes));
    } catch (e) {
      throw Exception('无法解析 Excel 文件(仅支持 .xlsx):$e');
    }
  }
  return utf8.decode(bytes, allowMalformed: !strictEncoding);
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
