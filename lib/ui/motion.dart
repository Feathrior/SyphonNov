library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../store/settings_store.dart';

/// 全应用动效节奏。位移动画用平滑减速曲线，直接操控始终即时跟手。
class MotionTokens {
  MotionTokens._();

  static const enter = Cubic(0.22, 1, 0.36, 1);
  static const exit = Cubic(0.4, 0, 1, 1);
  static const emphasized = Cubic(0.16, 1, 0.3, 1);

  static Duration quick(BuildContext context) => _duration(context, 110, 70);
  static Duration standard(BuildContext context) =>
      _duration(context, 230, 170);
  static Duration spatial(BuildContext context) => _duration(context, 320, 250);

  static Duration _duration(BuildContext context, int full, int reduced) {
    final setting = SettingsStore.instance.motionMode;
    final systemReduced =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (setting == MotionMode.off) return Duration.zero;
    if (setting == MotionMode.reduced || systemReduced) {
      return Duration(milliseconds: reduced == 70 ? 0 : reduced);
    }
    return Duration(milliseconds: full);
  }
}

/// iOS 风格的统一显隐过渡。内容在轻微缩放、淡入的同时由模糊恢复清晰；
/// 动画结束后关闭滤镜，避免静止界面持续占用离屏渲染资源。
class BlurScaleTransition extends AnimatedWidget {
  final Widget child;
  final Alignment alignment;
  final double beginScale;
  final double maxBlur;

  const BlurScaleTransition({
    super.key,
    required Animation<double> animation,
    required this.child,
    this.alignment = Alignment.center,
    this.beginScale = 0.965,
    this.maxBlur = 8,
  }) : super(listenable: animation);

  Animation<double> get animation => listenable as Animation<double>;

  @override
  Widget build(BuildContext context) {
    final value = animation.value.clamp(0.0, 1.0);
    final sigma = maxBlur * (1 - value);
    final content = Opacity(
      opacity: value,
      child: Transform.scale(
        scale: beginScale + (1 - beginScale) * value,
        alignment: alignment,
        child: child,
      ),
    );
    if (sigma <= 0.05) return content;
    return ImageFiltered(
      imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      child: content,
    );
  }
}

/// 把外层 AnimatedSwitcher 的动画传给真正的浮动内容，避免对覆盖整个窗口的
/// 透明点击拦截层做模糊滤镜。
class PopupMotionScope extends InheritedWidget {
  final Animation<double> animation;

  const PopupMotionScope({
    super.key,
    required this.animation,
    required super.child,
  });

  static Animation<double>? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PopupMotionScope>()?.animation;

  @override
  bool updateShouldNotify(PopupMotionScope oldWidget) =>
      oldWidget.animation != animation;
}
