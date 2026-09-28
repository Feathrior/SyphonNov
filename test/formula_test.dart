// 表格公式:引用、区间、函数、循环检测与填充时的相对引用平移。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/models/formula.dart';

SheetFormulas sheetOf(List<List<String>> grid) {
  final rows = grid.length;
  final columns = rows == 0 ? 0 : grid.first.length;
  return SheetFormulas(
    textAt: (r, c) =>
        r >= 0 && r < rows && c >= 0 && c < columns ? grid[r][c] : '',
    rowCount: rows,
    columnCount: columns,
  );
}

void main() {
  test('单元格引用与四则运算', () {
    final sheet = sheetOf([
      ['1', '2', '=A1+B1'],
      ['10', '4', '=A2*B2-B1'],
    ]);
    expect(sheet.display(0, 2), '3');
    expect(sheet.display(1, 2), '38');
    expect(sheet.isFormula(0, 0), isFalse);
    expect(sheet.isFormula(0, 2), isTrue);
  });

  test('区间与函数', () {
    final sheet = sheetOf([
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['=SUM(A1:C2)', '=AVERAGE(A1:A2)', '=MAX(A1:B2)'],
      ['=MIN(A1:C2)', '=COUNT(A1:C2)', '=ROUND(AVERAGE(A1:C2), 2)'],
    ]);
    expect(sheet.display(2, 0), '21');
    expect(sheet.display(2, 1), '2.5');
    expect(sheet.display(2, 2), '5');
    expect(sheet.display(3, 0), '1');
    expect(sheet.display(3, 1), '6');
    expect(sheet.display(3, 2), '3.5');
  });

  test('数值函数与乘方', () {
    final sheet = sheetOf([
      ['9', '=SQRT(A1)', '=ABS(0-A1)', '=POWER(A1, 2)'],
      ['=2^10', '=ROUND(2/3, 3)', '=SUM(A1:B1)', '=A1/0'],
    ]);
    expect(sheet.display(0, 1), '3');
    expect(sheet.display(0, 2), '9');
    expect(sheet.display(0, 3), '81');
    expect(sheet.display(1, 0), '1024');
    expect(sheet.display(1, 1), '0.667');
    expect(sheet.display(1, 2), '12');
  });

  test('循环引用与非法算式给出占位文本', () {
    final sheet = sheetOf([
      ['=B1', '=A1'],
      ['=1+', '=NOPE(A1)'],
    ]);
    expect(sheet.display(0, 0), kFormulaCycle);
    expect(sheet.display(0, 1), kFormulaCycle);
    expect(sheet.display(1, 0), kFormulaError);
    expect(sheet.display(1, 1), kFormulaError);
  });

  test('空单元格与文本单元格按 0 参与运算', () {
    final sheet = sheetOf([
      ['', '文本', '=A1+1'],
      ['=B1+1', '=A2*2', '=SUM(A1:B1)'],
    ]);
    expect(sheet.display(0, 2), '1');
    expect(sheet.display(1, 0), '1');
    expect(sheet.display(1, 1), '2');
    expect(sheet.display(1, 2), '0');
  });

  test('填充时相对引用随行列平移,\$ 锁定的不变', () {
    expect(shiftFormulaRefs('=A1*2', rowDelta: 1), '=A2*2');
    expect(shiftFormulaRefs('=A1+B2', colDelta: 1), '=B1+C2');
    expect(shiftFormulaRefs(r'=$A1+B$2', rowDelta: 2), r'=$A3+B$2');
    expect(shiftFormulaRefs(r'=$A$1', rowDelta: 5, colDelta: 5), r'=$A$1');
    expect(shiftFormulaRefs('=SUM(A1:A3)', rowDelta: 1), '=SUM(A2:A4)');
    expect(shiftFormulaRefs('42', rowDelta: 1), '42');
  });

  test('列名与格式', () {
    expect(columnName(0), 'A');
    expect(columnName(25), 'Z');
    expect(columnName(26), 'AA');
    expect(SheetFormulas.formatValue(3.0), '3');
    expect(SheetFormulas.formatValue(3.25), '3.25');
    expect(SheetFormulas.formatValue(null), '');
  });
}
