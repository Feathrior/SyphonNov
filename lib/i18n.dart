// Minimal i18n: JSON-driven. Add a new language by placing <locale>.json in assets/language/.
// Usage:
//   L.t('key')       → 翻译,找不到则返回 key 本身
//   L.fmt('{n} 个', {'n':'3'}) → 带参数翻译
//   L.rebuildNotifier → ChangeNotifier,监听它可在语言切换时重建 widget
// 根 widget 处包一层 AnimatedBuilder(animation: L.rebuildNotifier, ...) 即可让整棵树随语言切换重建。
library;

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class L {
  L._();
  static String _locale = 'zh';
  static final Map<String, Map<String, String>> _table = {};
  static final RebuildNotifier rebuildNotifier = RebuildNotifier();

  static String get locale => _locale;

  static Future<void> load([String? locale]) async {
    if (locale != null) _locale = locale;
    if (_table.containsKey(_locale)) {
      rebuildNotifier.trigger();
      return;
    }
    try {
      final raw = await rootBundle.loadString('assets/language/$_locale.json');
      final j = jsonDecode(raw);
      if (j is Map) {
        _table[_locale] = {
          for (final e in j.entries) '${e.key}': '${e.value}',
        };
      }
    } catch (_) {
      _table[_locale] = {};
    }
    rebuildNotifier.trigger();
  }

  static String t(String key) {
    final map = _table[_locale];
    if (map == null) return key;
    return map[key] ?? key;
  }

  /// 带参数的翻译:键中的 `{name}` 会被替换为 params[name]。
  /// 例: `L.fmt('{n} 个节点执行成功', {'n': '3'})`
  static String fmt(String key, Map<String, String> params) {
    var s = t(key);
    for (final e in params.entries) {
      s = s.replaceAll('{${e.key}}', e.value);
    }
    return s;
  }
}

class RebuildNotifier extends ChangeNotifier {
  void trigger() => notifyListeners();
}
