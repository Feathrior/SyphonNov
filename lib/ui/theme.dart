// Syphon 统一主题:亮/暗色变量、尺寸常量(由 React 版 styles.css 移植)
library;

import 'package:flutter/material.dart';

// ==================== 亮色主题 ====================
class _Light {
  static const bgApp = Color(0xFFDEDEDE);
  static const bgSurface = Color(0xFFDEDEDE);
  static const bgToolbar = Color(0xFFFFFFFF);
  static const bgRaise = Color(0xFFF2F2F2);
  static const bgFloat = Color(0xFFE9E9E9);
  static const bgCanvas = Color(0xFFDEDEDE);
  static const bgNode = Color(0xFFFFFFFF);
  static const bgInput = Color(0xFFFFFFFF);
  static const stroke = Color(0x14000000); // rgba(0,0,0,0.08)
  static const strokeStrong = Color(0x24000000); // rgba(0,0,0,0.14)
  static const text = Color(0xFF1C1C1C);
  static const textDim = Color(0xFF5F5F5F);
  static const textFaint = Color(0xFF9D9D9D);
  static const accent = Color(0xFF0067C0);
  static const accentHover = Color(0xFF0060AF);
  static const accentPress = Color(0xFF00529A);
  static const accentGlow = Color(0x380067C0); // rgba(0,103,192,0.22)
  static const onAccent = Color(0xFFFFFFFF);
  static const success = Color(0xFF107C10);
  static const danger = Color(0xFFC42B1C);
  static const warn = Color(0xFF9D5D00);
  static const flowDot = Color(0x47000000); // rgba(0,0,0,0.28)
  static const flowEdge = Color(0xFFB3B3B3);
}

// ==================== 暗色主题 ====================
class _Dark {
  static const bgApp = Color(0xFF1F1F1F);
  static const bgSurface = Color(0xFF2B2B2B);
  static const bgToolbar = Color(0xFF2B2B2B);
  static const bgRaise = Color(0xFF333333);
  static const bgFloat = Color(0xFF3D3D3D);
  static const bgCanvas = Color(0xFF2B2B2B);
  static const bgNode = Color(0xFF2B2B2B);
  static const bgInput = Color(0xFF333333);
  static const stroke = Color(0x14FFFFFF); // rgba(255,255,255,0.08)
  static const strokeStrong = Color(0x24FFFFFF); // rgba(255,255,255,0.14)
  static const text = Color(0xFFF9F9FA);
  static const textDim = Color(0xFFC7C7C7);
  static const textFaint = Color(0xFF8A8A8A);
  static const accent = Color(0xFF60CDFF);
  static const accentHover = Color(0xFF79D8FF);
  static const accentPress = Color(0xFF4CC2FF);
  static const accentGlow = Color(0x5260CDFF); // rgba(96,205,255,0.32)
  static const onAccent = Color(0xFF0A0A0A);
  static const success = Color(0xFF6CCB5F);
  static const danger = Color(0xFFFF99A4);
  static const warn = Color(0xFFFCE100);
  static const flowDot = Color(0xFF475569);
  static const flowEdge = Color(0xFF64748B);
}

// ==================== 主题访问器 ====================
class SyphonTheme {
  final bool isDark;
  final Color bgApp;
  final Color bgSurface;
  final Color bgToolbar;
  final Color bgRaise;
  final Color bgFloat;
  final Color bgCanvas;
  final Color bgNode;
  final Color bgInput;
  final Color stroke;
  final Color strokeStrong;
  final Color text;
  final Color textDim;
  final Color textFaint;
  final Color accent;
  final Color accentHover;
  final Color accentPress;
  final Color accentGlow;
  final Color onAccent;
  final Color success;
  final Color danger;
  final Color warn;
  final Color flowDot;
  final Color flowEdge;

  const SyphonTheme._({
    required this.isDark,
    required this.bgApp,
    required this.bgSurface,
    required this.bgToolbar,
    required this.bgRaise,
    required this.bgFloat,
    required this.bgCanvas,
    required this.bgNode,
    required this.bgInput,
    required this.stroke,
    required this.strokeStrong,
    required this.text,
    required this.textDim,
    required this.textFaint,
    required this.accent,
    required this.accentHover,
    required this.accentPress,
    required this.accentGlow,
    required this.onAccent,
    required this.success,
    required this.danger,
    required this.warn,
    required this.flowDot,
    required this.flowEdge,
  });

  static const lightTheme = SyphonTheme._(
    isDark: false,
    bgApp: _Light.bgApp,
    bgSurface: _Light.bgSurface,
    bgToolbar: _Light.bgToolbar,
    bgRaise: _Light.bgRaise,
    bgFloat: _Light.bgFloat,
    bgCanvas: _Light.bgCanvas,
    bgNode: _Light.bgNode,
    bgInput: _Light.bgInput,
    stroke: _Light.stroke,
    strokeStrong: _Light.strokeStrong,
    text: _Light.text,
    textDim: _Light.textDim,
    textFaint: _Light.textFaint,
    accent: _Light.accent,
    accentHover: _Light.accentHover,
    accentPress: _Light.accentPress,
    accentGlow: _Light.accentGlow,
    onAccent: _Light.onAccent,
    success: _Light.success,
    danger: _Light.danger,
    warn: _Light.warn,
    flowDot: _Light.flowDot,
    flowEdge: _Light.flowEdge,
  );

  static const darkTheme = SyphonTheme._(
    isDark: true,
    bgApp: _Dark.bgApp,
    bgSurface: _Dark.bgSurface,
    bgToolbar: _Dark.bgToolbar,
    bgRaise: _Dark.bgRaise,
    bgFloat: _Dark.bgFloat,
    bgCanvas: _Dark.bgCanvas,
    bgNode: _Dark.bgNode,
    bgInput: _Dark.bgInput,
    stroke: _Dark.stroke,
    strokeStrong: _Dark.strokeStrong,
    text: _Dark.text,
    textDim: _Dark.textDim,
    textFaint: _Dark.textFaint,
    accent: _Dark.accent,
    accentHover: _Dark.accentHover,
    accentPress: _Dark.accentPress,
    accentGlow: _Dark.accentGlow,
    onAccent: _Dark.onAccent,
    success: _Dark.success,
    danger: _Dark.danger,
    warn: _Dark.warn,
    flowDot: _Dark.flowDot,
    flowEdge: _Dark.flowEdge,
  );

  static SyphonTheme of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? darkTheme : lightTheme;

  // 暗色主题下顶栏提亮:向白色混合 amt 比例
  Color lighten(Color c, double amt) {
    return Color.lerp(c, const Color(0xFFFFFFFF), amt)!;
  }
}

// ==================== 尺寸常量 ====================
class SyphonDims {
  static const toolbarH = 48.0;
  static const statusH = 26.0;
  static const inspectorH = 190.0;
  static const propsW = 300.0;
  static const nodeW = 260.0;
  static const nodeViewerW = 440.0;
  static const radiusS = 4.0;
  static const radiusM = 8.0;
  static const viewerH = 230.0;
  static const viewerActionH = 38.0;
  static const monoFont = 'Consolas';
  static const fontFamily = 'Segoe UI Variable Text';
}

// ==================== 分类信息 ====================
class CatInfo {
  final String label;
  final String color;
  final String icon;
  const CatInfo(this.label, this.color, this.icon);
}

const kCatInfo = <String, CatInfo>{
  'input': CatInfo('组输入', '#10b981', '▣'),
  'clean': CatInfo('数据初步', '#3b82f6', '◈'),
  'compute': CatInfo('数据运算', '#ef4444', 'ƒ'),
  'transform': CatInfo('数据转化', '#f59e0b', '⇄'),
  'visualize': CatInfo('数据可视化', '#8b5cf6', '◉'),
};

// ==================== Socket 颜色 ====================
const kSocketColors = <String, String>{
  'table': '#22c55e',
  'series': '#f59e0b',
  'scatter': '#3b82f6',
  'mesh': '#ec4899',
  'grid': '#14b8a6',
  'distribution': '#a78bfa',
  'axes': '#22d3ee',
  'text': '#e879f9',
  'colorbar': '#38bdf8',
  'any': '#94a3b8',
};

const kSocketLabels = <String, String>{
  'table': '表格',
  'series': '曲线/线',
  'scatter': '散点',
  'mesh': '面/网格',
  'grid': '网格数据',
  'distribution': '分布',
  'axes': '坐标系',
  'text': '文本',
  'colorbar': '色带',
  'any': '任意',
};
