// CSV/Excel 导入修复回归测试:UTF-8 中文文本文件不乱码,Excel 转换正常。
import 'dart:io';

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
}
