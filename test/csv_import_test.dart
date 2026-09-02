// CSV/Excel 导入回归测试:UTF-8 中文文本文件不乱码,xlsx(OOML)解析正常。
// 测试夹具用 archive 包手写最小 xlsx zip,不依赖 excel 包。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/models/csv.dart';
import 'package:syphon_nov/models/data.dart';

/// 手写最小 xlsx(zip + OOXML):一张表,首行列名,混合 inlineStr/数值
List<int> minimalXlsx() {
  final wb =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
      '<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>';
  final rels =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" '
      'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" '
      'Target="worksheets/sheet1.xml"/></Relationships>';
  final sheet =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
      '<sheetData>'
      '<row r="1"><c r="A1" t="inlineStr"><is><t>名称</t></is></c>'
      '<c r="B1" t="inlineStr"><is><t>数值</t></is></c></row>'
      '<row r="2"><c r="A2" t="inlineStr"><is><t>甲</t></is></c><c r="B2"><v>1</v></c></row>'
      '<row r="3"><c r="A3" t="inlineStr"><is><t>乙</t></is></c><c r="B3"><v>2.5</v></c></row>'
      '<row r="4"><c r="A4" t="inlineStr"><is><t>丙</t></is></c>'
      '<c r="B4" t="inlineStr"><is><t>3</t></is></c></row>'
      '</sheetData></worksheet>';
  final zip = Archive();
  void add(String name, String content) {
    final data = utf8.encode(content);
    zip.addFile(ArchiveFile(name, data.length, data));
  }

  add('xl/workbook.xml', wb);
  add('xl/_rels/workbook.xml.rels', rels);
  add('xl/worksheets/sheet1.xml', sheet);
  return ZipEncoder().encode(zip);
}

void main() {
  test('UTF-8 中文 CSV 解码不乱码', () async {
    final file = File('${Directory.systemTemp.path}/syphon_utf8_test.csv');
    await file.writeAsString('名称,数值\n苹果,1\n香蕉,2\n');
    final text = await dataFileToCsvText(file.path);
    expect(text, contains('苹果'));
    expect(text, contains('香蕉'));
    await file.delete();
  });

  test('Excel 列转 CSV 文本可被解析器重新读回', () {
    final csv = columnsToCsv([
      Column(name: '名称', values: ['甲', '乙']),
      Column(name: '数值', values: [1.5, 2]),
    ]);
    final cols = parseDelimitedText(csv);
    expect(cols.length, 2);
    expect(cols[0].name, '名称');
    expect(cols[0].values[0], '甲');
    expect(cols[1].values[1], 2);
  });

  test('xlsx OOXML 解析器:字符串/数字/中文列名', () {
    final bytes = minimalXlsx();
    final cols = xlsxBytesToColumns(bytes);
    expect(cols.length, 2);
    expect(cols[0].name, '名称');
    expect(cols[0].values, ['甲', '乙', '丙']);
    expect(cols[1].values[0], 1);
    expect(cols[1].values[1], 2.5);
  });

  test('dataFileToCsvText 读取 xlsx 文件', () async {
    final file = File('${Directory.systemTemp.path}/syphon_xlsx_test.xlsx');
    await file.writeAsBytes(minimalXlsx());
    final text = await dataFileToCsvText(file.path);
    expect(text, contains('名称'));
    expect(text, contains('甲'));
    expect(text, contains('2.5'));
    await file.delete();
  });
}
