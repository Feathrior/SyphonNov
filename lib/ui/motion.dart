library;

import 'package:flutter/material.dart';

import '../store/settings_store.dart';

/// 全应用动效节奏。位移动画用平滑减速曲线，直接操控始终即时跟手。
class MotionTokens {
  MotionTokens._();

  static const enter = Cubic(0.22, 1, 0.36, 1);
  static const exit = Cubic(0.4, 0, 1, 1);
  static const emphasized = Cubic(0.16, 1, 0.3, 1);

  static Duration quick(BuildContext context) => _duration(context, 90, 60);
  static Duration standard(BuildContext context) =>
      _duration(context, 180, 140);
  static Duration spatial(BuildContext context) => _duration(context, 260, 220);

  static Duration _duration(BuildContext context, int full, int reduced) {
    final setting = SettingsStore.instance.motionMode;
    final systemReduced =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (setting == MotionMode.off) return Duration.zero;
    if (setting == MotionMode.reduced || systemReduced) {
      return Duration(milliseconds: reduced == 60 ? 0 : reduced);
    }
    return Duration(milliseconds: full);
  }
}
