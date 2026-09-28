// 表格公式:单元格文本以 `=` 开头时按算式求值(Excel 的最小子集)。
//
//   =A1+B2*2          引用(列字母 + 1 起始行号;`$A$1` 表示锁定,拖拽填充时不变)
//   =SUM(A1:B3)       区间
//   =ROUND(A1/3, 2)   函数与参数(SUM/AVERAGE/MIN/MAX/COUNT/ABS/ROUND/SQRT/POWER)
//
// 词法/语法解析交给 expressions 包,这里只做"电子表格"这一层的粘连:
// 单元格引用与区间的展开、函数求值、循环引用检测、填充时的相对引用平移。
library;

import 'dart:math' as math;

import 'package:expressions/expressions.dart';

/// 循环引用 / 非法算式的占位文本(Excel 风格)
const String kFormulaCycle = '#循环';
const String kFormulaError = '#错误';

/// 一个表格里的公式求值器:按需取单元格文本、递归求值并缓存。
class SheetFormulas {
  SheetFormulas({
    required this.textAt,
    required this.rowCount,
    required this.columnCount,
  });

  /// (row, column) → 单元格原始文本
  final String Function(int row, int column) textAt;
  final int rowCount;
  final int columnCount;

  final Map<int, dynamic> _cache = {};
  final Set<int> _visiting = {};

  int _key(int row, int column) => row * columnCount + column;

  static bool looksLikeFormula(String text) => text.trimLeft().startsWith('=');

  bool isFormula(int row, int column) => looksLikeFormula(textAt(row, column));

  /// 显示文本:公式 → 计算结果;普通单元格 → 原文本。
  String display(int row, int column) {
    final raw = textAt(row, column);
    if (!looksLikeFormula(raw)) return raw;
    return formatValue(value(row, column));
  }

  /// 求值:数字 / 文本 / null;错误返回占位字符串。
  dynamic value(int row, int column) {
    if (row < 0 || row >= rowCount || column < 0 || column >= columnCount) {
      return null;
    }
    final key = _key(row, column);
    if (_cache.containsKey(key)) return _cache[key];
    final raw = textAt(row, column);
    if (!looksLikeFormula(raw)) {
      final parsed = _asNumber(raw);
      final result = parsed ?? (raw.trim().isEmpty ? null : raw);
      _cache[key] = result;
      return result;
    }
    if (_visiting.contains(key)) return kFormulaCycle;
    _visiting.add(key);
    dynamic result;
    try {
      result = _evaluate(raw.trimLeft().substring(1));
    } catch (_) {
      result = kFormulaError;
    }
    _visiting.remove(key);
    _cache[key] = result;
    return result;
  }

  // ==================== 求值 ====================

  dynamic _evaluate(String source) {
    final prepared = _expandFunctions(_expandPowers(source));
    if (prepared.trim().isEmpty) return kFormulaError;
    final context = <String, dynamic>{};
    for (final match in _refPattern.allMatches(prepared)) {
      final name = match.group(0)!;
      final ref = _parseRef(name);
      if (ref == null) continue;
      final cellValue = value(ref.$1, ref.$2);
      if (cellValue == kFormulaCycle) return kFormulaCycle;
      context[name] = cellValue is num ? cellValue : 0;
    }
    final expression = Expression.parse(prepared);
    final result = const ExpressionEvaluator().eval(expression, context);
    if (result is num) return result.isFinite ? result : kFormulaError;
    if (result == null) return 0;
    return result;
  }

  /// 把 `FUNC(参数…)` 就地替换成算好的数字;区间参数会展开成多个值。
  String _expandFunctions(String source) {
    var text = source;
    var guard = 0;
    while (guard++ < 32) {
      final call = _findFunctionCall(text);
      if (call == null) break;
      final numbers = _functionArgs(call.args);
      final value = _applyFunction(call.name.toUpperCase(), numbers);
      if (value == null) throw const FormatException('未知函数');
      text =
          '${text.substring(0, call.start)}${_numberLiteral(value)}'
          '${text.substring(call.end)}';
    }
    return text;
  }

  /// Excel 的 ^ 是乘方,而 expressions 包把它当按位异或:先换成 POWER()。
  /// 右结合(2^3^2 = 2^9),所以每次都处理最后一个 ^。
  String _expandPowers(String source) {
    var text = source;
    var guard = 0;
    while (guard++ < 32) {
      final index = text.lastIndexOf('^');
      if (index < 0) break;
      final left = _operandBefore(text, index);
      final right = _operandAfter(text, index + 1);
      if (left == null || right == null) {
        throw const FormatException('乘方写法有误');
      }
      text =
          'POWER(${left.text}, ${right.text})'
          '';
    }
    return text;
  }

  static ({int start, String text})? _operandBefore(String text, int index) {
    var end = index;
    while (end > 0 && text[end - 1] == ' ') {
      end--;
    }
    if (end == 0) return null;
    if (text[end - 1] == ')') {
      var depth = 0;
      for (var i = end - 1; i >= 0; i--) {
        if (text[i] == ')') depth++;
        if (text[i] == '(') {
          depth--;
          if (depth == 0) return (start: i, text: text.substring(i, end));
        }
      }
      return null;
    }
    var start = end;
    while (start > 0 && _isOperandChar(text[start - 1])) {
      start--;
    }
    if (start == end) return null;
    return (start: start, text: text.substring(start, end));
  }

  static ({int end, String text})? _operandAfter(String text, int index) {
    var start = index;
    while (start < text.length && text[start] == ' ') {
      start++;
    }
    var negative = false;
    if (start < text.length && (text[start] == '-' || text[start] == '+')) {
      negative = text[start] == '-';
      start++;
      while (start < text.length && text[start] == ' ') {
        start++;
      }
    }
    if (start >= text.length) return null;
    var end = start;
    if (text[start] == '(') {
      var depth = 0;
      while (end < text.length) {
        if (text[end] == '(') depth++;
        if (text[end] == ')') {
          depth--;
          if (depth == 0) {
            end++;
            break;
          }
        }
        end++;
      }
    } else {
      while (end < text.length && _isOperandChar(text[end])) {
        end++;
      }
    }
    if (end == start) return null;
    final operand = text.substring(start, end);
    return (end: end, text: negative ? '0-()' : operand);
  }

  static bool _isOperandChar(String ch) =>
      RegExp(r'[0-9A-Za-z_.$]').hasMatch(ch);

  /// 找第一个函数调用并取出配对括号内的参数(正则是处理不了嵌套括号的)
  static _FunctionCall? _findFunctionCall(String text) {
    final match = _functionPattern.firstMatch(text);
    if (match == null) return null;
    final open = match.end - 1;
    var depth = 0;
    for (var i = open; i < text.length; i++) {
      final ch = text[i];
      if (ch == '(') {
        depth++;
      } else if (ch == ')') {
        depth--;
        if (depth == 0) {
          return _FunctionCall(
            start: match.start,
            end: i + 1,
            name: match.group(1)!,
            args: text.substring(open + 1, i),
          );
        }
      }
    }
    throw const FormatException('函数括号不匹配');
  }

  /// 函数参数 → 数字列表(区间展开,标量求值)
  List<num> _functionArgs(String args) {
    final out = <num>[];
    for (final part in _splitArgs(args)) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) continue;
      final range = _rangePattern.firstMatch(trimmed);
      if (range != null && range.group(0) == trimmed) {
        final a = _parseRef(range.group(1)!);
        final b = _parseRef(range.group(2)!);
        if (a == null || b == null) continue;
        final r0 = a.$1 < b.$1 ? a.$1 : b.$1;
        final r1 = a.$1 < b.$1 ? b.$1 : a.$1;
        final c0 = a.$2 < b.$2 ? a.$2 : b.$2;
        final c1 = a.$2 < b.$2 ? b.$2 : a.$2;
        for (var r = r0; r <= r1; r++) {
          for (var c = c0; c <= c1; c++) {
            final cellValue = value(r, c);
            if (cellValue is num) out.add(cellValue);
          }
        }
        continue;
      }
      final evaluated = _evaluate(trimmed);
      if (evaluated is num) out.add(evaluated);
    }
    return out;
  }

  num? _applyFunction(String name, List<num> args) {
    switch (name) {
      case 'SUM':
        return args.fold<num>(0, (a, b) => a + b);
      case 'AVERAGE':
      case 'AVG':
        return args.isEmpty
            ? 0
            : args.fold<num>(0, (a, b) => a + b) / args.length;
      case 'MIN':
        return args.isEmpty ? 0 : args.reduce((a, b) => a < b ? a : b);
      case 'MAX':
        return args.isEmpty ? 0 : args.reduce((a, b) => a > b ? a : b);
      case 'COUNT':
        return args.length;
      case 'ABS':
        return args.isEmpty ? 0 : args.first.abs();
      case 'SQRT':
        if (args.isEmpty || args.first < 0) return null;
        return _sqrt(args.first);
      case 'POWER':
        return args.length < 2 ? null : _pow(args[0], args[1]);
      case 'ROUND':
        if (args.isEmpty) return 0;
        final digits = args.length > 1 ? args[1].round() : 0;
        final factor = _pow(10, digits).toDouble();
        return (args.first * factor).round() / factor;
      default:
        return null;
    }
  }

  static double _sqrt(num v) => math.sqrt(v.toDouble());

  static num _pow(num base, num exponent) => math.pow(base, exponent);

  // ==================== 引用 / 数值 ====================

  /// `A1` → (rowIdx, colIdx);非法引用返回 null
  static (int, int)? _parseRef(String name) {
    final match = _singleRefPattern.firstMatch(name.trim());
    if (match == null) return null;
    final letters = match.group(1)!.toUpperCase().replaceAll(r'$', '');
    final digits = match.group(2)!.replaceAll(r'$', '');
    var column = 0;
    for (final unit in letters.codeUnits) {
      if (unit < 65 || unit > 90) return null;
      column = column * 26 + (unit - 64);
    }
    final row = int.tryParse(digits);
    if (row == null || row < 1) return null;
    return (row - 1, column - 1);
  }

  static num? _asNumber(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    return num.tryParse(trimmed);
  }

  static String _numberLiteral(num value) {
    if (value is int) return '$value';
    if (value == value.roundToDouble() && value.abs() < 1e15) {
      return value.toInt().toString();
    }
    return '$value';
  }

  /// 结果显示:整数不带小数点,浮点最多 10 位有效数字
  static String formatValue(dynamic value) {
    if (value == null) return '';
    if (value is String) return value;
    if (value is num) {
      if (value is int) return '$value';
      if (value == value.roundToDouble() && value.abs() < 1e15) {
        return value.toInt().toString();
      }
      return value
          .toStringAsPrecision(10)
          .replaceFirst(RegExp(r'0+$'), '')
          .replaceFirst(RegExp(r'\.$'), '');
    }
    return '$value';
  }
}

class _FunctionCall {
  const _FunctionCall({
    required this.start,
    required this.end,
    required this.name,
    required this.args,
  });

  final int start;
  final int end;
  final String name;
  final String args;
}

final RegExp _singleRefPattern = RegExp(r'^([A-Za-z$]+)(\d+)$');
final RegExp _functionPattern = RegExp(r'([A-Za-z_][A-Za-z0-9_]*)\s*\(');
final RegExp _rangePattern = RegExp(
  r'^(\$?[A-Za-z]+\$?\d+)\s*:\s*(\$?[A-Za-z]+\$?\d+)$',
);
final RegExp _refPattern = RegExp(r'\$?[A-Za-z]+\$?\d+');
final RegExp _refInFormula = RegExp(r'(\$?)([A-Za-z]+)(\$?)(\d+)');

/// 拆函数参数:按顶层逗号切分(括号内的逗号不切)
List<String> _splitArgs(String args) {
  final out = <String>[];
  var depth = 0;
  final current = StringBuffer();
  for (var i = 0; i < args.length; i++) {
    final ch = args[i];
    if (ch == '(') depth++;
    if (ch == ')') depth--;
    if (ch == ',' && depth == 0) {
      out.add(current.toString());
      current.clear();
      continue;
    }
    current.write(ch);
  }
  if (current.isNotEmpty) out.add(current.toString());
  return out;
}

/// 填充时平移公式里的相对引用(Excel 行为):`$` 锁定的行列不动。
String shiftFormulaRefs(String formula, {int rowDelta = 0, int colDelta = 0}) {
  if (!SheetFormulas.looksLikeFormula(formula)) return formula;
  if (rowDelta == 0 && colDelta == 0) return formula;
  return formula.replaceAllMapped(_refInFormula, (match) {
    final colLock = match.group(1) == r'$';
    final letters = match.group(2)!;
    final rowLock = match.group(3) == r'$';
    final row = int.tryParse(match.group(4)!);
    if (row == null) return match.group(0)!;
    final column = _columnIndex(letters);
    final nextColumn = colLock ? column : column + colDelta;
    final nextRow = rowLock ? row : row + rowDelta;
    if (nextColumn < 0 || nextRow < 1) return match.group(0)!;
    return '${colLock ? r'$' : ''}${_columnLetters(nextColumn)}'
        '${rowLock ? r'$' : ''}$nextRow';
  });
}

int _columnIndex(String letters) {
  var column = 0;
  for (final unit in letters.toUpperCase().codeUnits) {
    column = column * 26 + (unit - 64);
  }
  return column - 1;
}

/// 0 → A、25 → Z、26 → AA
String columnName(int index) {
  var i = index < 0 ? 0 : index;
  final buffer = StringBuffer();
  do {
    buffer.write(String.fromCharCode(65 + i % 26));
    i = i ~/ 26 - 1;
  } while (i >= 0);
  return String.fromCharCodes(buffer.toString().codeUnits.reversed);
}

String _columnLetters(int index) => columnName(index);


