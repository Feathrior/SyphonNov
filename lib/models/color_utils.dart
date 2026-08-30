// 颜色工具:hex / hsl / rgb 字符串 → Flutter Color(由 React 版 CSS 颜色体系移植)
library;

import 'dart:ui';

import 'package:flutter/material.dart' show Colors;

/// 解析颜色字符串(#hex / hsl() / rgb() / rgba() / 命名色),失败回退 [fallback]
Color parseColor(String? s, [Color fallback = const Color(0xFF333333)]) {
  if (s == null || s.trim().isEmpty) return fallback;
  final str = s.trim();
  if (str.startsWith('#')) {
    return _parseHex(str, fallback);
  }
  if (str.startsWith('hsl')) {
    return _parseHsl(str, fallback);
  }
  if (str.startsWith('rgb')) {
    return _parseRgb(str, fallback);
  }
  // 常见命名色
  switch (str.toLowerCase()) {
    case 'white':
      return Colors.white;
    case 'black':
      return Colors.black;
    case 'red':
      return Colors.red;
    case 'green':
      return Colors.green;
    case 'blue':
      return Colors.blue;
    case 'orange':
      return Colors.orange;
    case 'gray' || 'grey':
      return Colors.grey;
    case 'purple':
      return Colors.purple;
    case 'cyan':
      return Colors.cyan;
    case 'yellow':
      return Colors.yellow;
    case 'pink':
      return Colors.pink;
    case 'transparent':
      return const Color(0x00000000);
  }
  return fallback;
}

Color _parseHex(String s, Color fallback) {
  var h = s.replaceFirst('#', '');
  if (h.length == 3) {
    h = h.split('').map((c) => '$c$c').join();
  }
  if (h.length == 4) {
    // #RGBA
    h = h.split('').map((c) => '$c$c').join();
  }
  if (h.length == 6) h = 'FF$h';
  final v = int.tryParse(h, radix: 16);
  if (v == null) return fallback;
  // 若已是 8 位(含 alpha),直接使用
  if (h.length == 8) return Color(v);
  return Color(0xFF000000 | v);
}

Color _parseHsl(String s, Color fallback) {
  final m = RegExp(r'[\d.]+').allMatches(s).map((e) => double.parse(e.group(0)!)).toList();
  if (m.length < 3) return fallback;
  final h = m[0];
  final sat = (m.length > 1 ? m[1] : 100) / 100;
  final lig = (m.length > 2 ? m[2] : 50) / 100;
  final alpha = m.length > 3 ? m[3] : 1.0;
  return _hslToRgb(h, sat, lig).withValues(alpha: alpha.clamp(0.0, 1.0));
}

Color _hslToRgb(double h, double s, double l) {
  final c = (1 - (2 * l - 1).abs()) * s;
  final hp = h / 60;
  final x = c * (1 - (hp % 2 - 1).abs());
  double r = 0, g = 0, b = 0;
  if (hp < 1) {
    r = c; g = x;
  } else if (hp < 2) {
    r = x; g = c;
  } else if (hp < 3) {
    g = c; b = x;
  } else if (hp < 4) {
    g = x; b = c;
  } else if (hp < 5) {
    r = x; b = c;
  } else {
    r = c; b = x;
  }
  final m = l - c / 2;
  return Color.fromRGBO(((r + m) * 255).round(), ((g + m) * 255).round(), ((b + m) * 255).round(), 1.0);
}

Color _parseRgb(String s, Color fallback) {
  final m = RegExp(r'[\d.]+').allMatches(s).map((e) => double.parse(e.group(0)!)).toList();
  if (m.length < 3) return fallback;
  final r = m[0].clamp(0, 255).toInt();
  final g = m[1].clamp(0, 255).toInt();
  final b = m[2].clamp(0, 255).toInt();
  final a = m.length > 3 ? m[3] : 1.0;
  return Color.fromRGBO(r, g, b, a.clamp(0.0, 1.0));
}

/// 颜色 → 十六进制字符串(#rrggbb)
String colorToHex(Color c) {
  final r = (c.r * 255).round().toRadixString(16).padLeft(2, '0');
  final g = (c.g * 255).round().toRadixString(16).padLeft(2, '0');
  final b = (c.b * 255).round().toRadixString(16).padLeft(2, '0');
  return '#$r$g$b';
}

/// 对颜色做明度混合(用于悬停/边框等)
Color withBrightness(Color c, double factor) {
  if (factor <= 1.0) {
    // 变亮:向白色混合
    return Color.lerp(c, Colors.white, 1 - factor)!;
  }
  return Color.lerp(c, Colors.black, factor - 1)!;
}
