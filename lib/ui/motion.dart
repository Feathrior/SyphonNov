library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../store/settings_store.dart';

@immutable
class PopMotionFrame {
  final double scale;
  final double opacity;
  final double blur;

  const PopMotionFrame({
    required this.scale,
    required this.opacity,
    required this.blur,
  });
}

/// 浮层与新节点共用的弹性出现轨迹。打开时允许轻微越过终点，关闭时保持
/// 单调，避免菜单收起时反向弹跳。
PopMotionFrame popMotionFrame(
  double progress, {
  double beginScale = .9,
  double maxBlur = 14,
  bool opening = true,
}) {
  final t = progress.clamp(0.0, 1.0);
  final scaleProgress = opening
      ? Curves.easeOutBack.transform(t)
      : Curves.easeOutCubic.transform(t);
  final clarity = Curves.easeOutCubic.transform(t);
  return PopMotionFrame(
    scale: beginScale + (1 - beginScale) * scaleProgress,
    opacity: clarity,
    blur: maxBlur * (1 - clarity) * (1 - clarity),
  );
}

/// 全应用动效节奏。位移动画用平滑减速曲线，直接操控始终即时跟手。
/// 除"完整/简化/关闭"外,还提供整体速度倍率(快速 = 当前速度),统一作用于
/// [quick]/[standard]/[spatial] 以及各处硬编码时长([scaled])。
class MotionTokens {
  MotionTokens._();

  static const enter = Cubic(0.22, 1, 0.36, 1);
  static const exit = Cubic(0.4, 0, 1, 1);
  static const emphasized = Cubic(0.16, 1, 0.3, 1);

  static Duration quick(BuildContext context) => _duration(context, 110, 70);
  static Duration standard(BuildContext context) =>
      _duration(context, 230, 170);
  static Duration spatial(BuildContext context) => _duration(context, 320, 250);

  /// 三档动效幅度与系统“减少动态效果”共用同一语义。完整保留全部位移、
  /// 缩放、旋转和模糊；简化只保留 42%；关闭直接落在最终静态状态。
  static double amplitude(BuildContext context) {
    final setting = SettingsStore.instance.motionMode;
    final systemReduced =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (setting == MotionMode.off) return 0;
    if (setting == MotionMode.reduced || systemReduced) return .42;
    return 1;
  }

  /// 全局节奏倍率:所有动画时长统一 ×该系数。
  ///
  /// 面板/标签页等切换的弹性回弹在最慢档位下仍然偏快,这里整体放慢一倍
  /// (时长 ×2 = 速度 ×0.5)。它与设置里的"动画速度"相乘,所以快速/适中/慢速
  /// 三档会一起变慢;想回调只需改这一个数。
  static const double pacing = 2;

  /// 按设置中的动画速度倍率缩放任意动画时长(1.0× 时原样返回)。
  /// 速度越慢,时长越长:适中 0.75× 速度 → 时长 ×1.33,慢速 0.6× → ×1.67。
  static Duration scaled(Duration base) {
    if (base <= Duration.zero) return Duration.zero;
    final factor = SettingsStore.instance.motionSpeed.durationFactor * pacing;
    if (factor == 1) return base;
    return Duration(microseconds: (base.inMicroseconds * factor).round());
  }

  static Duration _duration(BuildContext context, int full, int reduced) {
    final setting = SettingsStore.instance.motionMode;
    final systemReduced =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (setting == MotionMode.off) return Duration.zero;
    if (setting == MotionMode.reduced || systemReduced) {
      // 简化模式下"快速"过渡直接归零,其余按简化时长(同样受速度倍率影响)
      return reduced == 70
          ? Duration.zero
          : scaled(Duration(milliseconds: reduced));
    }
    return scaled(Duration(milliseconds: full));
  }
}

/// iOS 风格的统一显隐过渡。内容在明显缩放、淡入的同时由模糊恢复清晰；
/// 动画结束后关闭滤镜，避免静止界面持续占用离屏渲染资源。
///
/// [origin] 可指定缩放的锚点(相对左下角对齐点的偏移),让内容"从某个位置
/// 长出来"——例如新节点从上边栏拖出的圆环位置生长。
class BlurScaleTransition extends AnimatedWidget {
  final Widget child;
  final Alignment alignment;
  final Offset? origin;
  final double beginScale;
  final double maxBlur;
  final Offset beginOffset;
  final bool elastic;

  const BlurScaleTransition({
    super.key,
    required Animation<double> animation,
    required this.child,
    this.alignment = Alignment.center,
    this.origin,
    this.beginScale = 0.9,
    this.maxBlur = 14,
    this.beginOffset = Offset.zero,
    this.elastic = true,
  }) : super(listenable: animation);

  Animation<double> get animation => listenable as Animation<double>;

  @override
  Widget build(BuildContext context) {
    final value = animation.value.clamp(0.0, 1.0);
    final amplitude = MotionTokens.amplitude(context);
    final effectiveBeginScale = 1 - (1 - beginScale) * amplitude;
    final effectiveBlur = maxBlur * amplitude;
    final frame = elastic
        ? popMotionFrame(
            value,
            beginScale: effectiveBeginScale,
            maxBlur: effectiveBlur,
            opening: animation.status != AnimationStatus.reverse,
          )
        : PopMotionFrame(
            scale: effectiveBeginScale + (1 - effectiveBeginScale) * value,
            opacity: value,
            blur: effectiveBlur * (1 - value),
          );
    final content = Transform.translate(
      offset:
          beginOffset * amplitude * (1 - Curves.easeOutCubic.transform(value)),
      child: Opacity(
        opacity: amplitude == 0 ? 1 : frame.opacity,
        child: Transform.scale(
          scale: amplitude == 0 ? 1 : frame.scale,
          alignment: alignment,
          origin: origin,
          child: child,
        ),
      ),
    );
    if (frame.blur <= 0.05) return content;
    return ImageFiltered(
      imageFilter: ui.ImageFilter.blur(sigmaX: frame.blur, sigmaY: frame.blur),
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
