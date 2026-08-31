// CSV/Excel 导入修复回归测试:UTF-8 中文文本文件不乱码,Excel 转换正常。
import 'dart:io';

import 'package:excel/excel.dart' as xls;
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/models/csv.dart';
import 'package:syphon_nov/models/data.dart';

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

  test('xlsx 兜底解析器:字符串/数字/中文列名/稀疏单元格', () async {
    final excel = xls.Excel.createExcel();
    final sheet = excel['Sheet1'];
    sheet.appendRow([xls.TextCellValue('名称'), xls.TextCellValue('数值')]);
    sheet.appendRow([xls.TextCellValue('甲'), xls.IntCellValue(1)]);
    sheet.appendRow([xls.TextCellValue('乙'), xls.DoubleCellValue(2.5)]);
    sheet.appendRow([xls.TextCellValue('丙'), xls.TextCellValue('3')]);
    // 稀疏单元格:B2 留空(单元格缺省)
    final bytes = excel.encode()!;

    // 兜底解析器应能读出与 excel 包一致的结果
    final cols = xlsxBytesToColumnsFallback(bytes);
    expect(cols.length, 2);
    expect(cols[0].name, '名称');
    expect(cols[0].values, ['甲', '乙', '丙']);
    expect(cols[1].values[0], 1);
    expect(cols[1].values[1], 2.5);
  });

  test('兜底解析器输出与 excel 包输出一致', () async {
    final excel = xls.Excel.createExcel();
    final sheet = excel['Sheet1'];
    sheet.appendRow([xls.TextCellValue('a'), xls.TextCellValue('b')]);
    sheet.appendRow([xls.IntCellValue(7), xls.TextCellValue('x')]);
    final bytes = excel.encode()!;
    final viaExcel = excelBytesToColumns(bytes);
    final viaFallback = xlsxBytesToColumnsFallback(bytes);
    expect(viaFallback.length, viaExcel.length);
    expect(viaFallback[0].name, viaExcel[0].name);
    expect(viaFallback[0].values, viaExcel[0].values);
    expect(viaFallback[1].values, viaExcel[1].values);
  });
}
