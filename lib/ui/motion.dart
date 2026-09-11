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
///
/// [reveal] 控制"显形"（透明度与去模糊）占整段动画的比例:小于 1 表示在
/// 前 [reveal] 段就完全显形,剩下的时间专门留给缩放回弹 —— 这样"从小变大"
/// 的过程是在完全不透明的状态下发生的,才会被看到。默认 1 表示与整体同步。
///
/// [blurUntil] 大于 0 时改用"在整段的前 [blurUntil] 比例内线性消退"的模糊
/// 节奏(默认的平方衰减几乎一开始就模糊归零,节点还小而透明时根本看不到
/// 模糊→清晰)。节点入场用 1:整段都在由模糊转清晰。
PopMotionFrame popMotionFrame(
  double progress, {
  double beginScale = .9,
  double maxBlur = 14,
  bool opening = true,
  double reveal = 1,
  double blurUntil = 0,
}) {
  final t = progress.clamp(0.0, 1.0);
  final scaleProgress = opening
      ? Curves.easeOutBack.transform(t)
      : Curves.easeOutCubic.transform(t);
  final clarity = Curves.easeOutCubic.transform(
    reveal <= 0 ? 1.0 : (t / reveal).clamp(0.0, 1.0),
  );
  final blur = blurUntil > 0
      ? maxBlur * (1 - (t / blurUntil).clamp(0.0, 1.0))
      : maxBlur * (1 - clarity) * (1 - clarity);
  return PopMotionFrame(
    scale: beginScale + (1 - beginScale) * scaleProgress,
    opacity: clarity,
    blur: blur,
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
  static Duration spatial(BuildContext context) =>
      _duration(context, 320, 250);

  /// 菜单/浮层退场:比全局节奏再快一倍 —— 收场要干脆
  static Duration dismiss(BuildContext context) =>
      _duration(context, 110, 70, times: brisk);

  /// 上边栏弹层这类面板级退场:基础时长更长,同样再快一倍
  static Duration dismissPanel(BuildContext context) =>
      _duration(context, 230, 170, times: brisk);

  /// 右键圆环的呼出回弹与圆球分离/收束:比全局节奏快(约 240ms)
  static Duration radialBounce(BuildContext context) =>
      _duration(context, 320, 250, times: brisk * .75);

  /// 新节点入场(生长 + 回弹):比全局节奏快(约 240ms)
  static Duration nodeEntry(BuildContext context) =>
      _duration(context, 320, 250, times: brisk * .75);

  /// "生长出现"共用参数:新节点生成、右键菜单与顶栏次级菜单呼出都用这一套,
  /// 于是三者的出现轨迹完全一致(从一点长出来 + 由模糊转清晰 + 弹性回弹)。
  ///
  /// - [growBeginScale] 起始缩放(0.08 = 从一点长出来)
  /// - [growMaxBlur] 起始模糊;显形阶段线性消退,幅度克制
  /// - [growReveal] 透明度在前 40% 完成,之后专做缩放回弹
  /// - [growBlurUntil] 节点的模糊窗口:长到原尺寸时已经清晰
  /// - [menuBlurUntil] 菜单的模糊窗口:菜单整体尺寸小、放大又快,模糊若也
  ///   在 40% 处归零,等看清内容时已经没什么可看 —— 所以铺满整段动画
  static const double growBeginScale = .08;
  static const double growMaxBlur = 14;
  static const double growReveal = .4;
  static const double growBlurUntil = .4;
  static const double menuBlurUntil = 1;

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

  /// "利落"系数:退场、圆环回弹这类希望干脆的过渡,在全局节奏上再乘它
  /// ([times] 参数)。0.5 = 再快一倍。
  static const double brisk = .5;

  /// 按设置中的动画速度倍率缩放任意动画时长(1.0× 时原样返回)。
  /// 速度越慢,时长越长:适中 0.75× 速度 → 时长 ×1.33,慢速 0.6× → ×1.67。
  /// [times] 用于单个动画的额外加减速(见 [brisk])。
  static Duration scaled(Duration base, {double times = 1}) {
    if (base <= Duration.zero) return Duration.zero;
    final factor =
        SettingsStore.instance.motionSpeed.durationFactor * pacing * times;
    if (factor == 1) return base;
    return Duration(microseconds: (base.inMicroseconds * factor).round());
  }

  static Duration _duration(
    BuildContext context,
    int full,
    int reduced, {
    double times = 1,
  }) {
    final setting = SettingsStore.instance.motionMode;
    final systemReduced =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (setting == MotionMode.off) return Duration.zero;
    if (setting == MotionMode.reduced || systemReduced) {
      // 简化模式下"快速"过渡直接归零,其余按简化时长(同样受速度倍率影响)
      return reduced == 70
          ? Duration.zero
          : scaled(Duration(milliseconds: reduced), times: times);
    }
    return scaled(Duration(milliseconds: full), times: times);
  }
}

/// iOS 风格的统一显隐过渡。内容在明显缩放、淡入的同时由模糊恢复清晰；
/// 动画结束后关闭滤镜，避免静止界面持续占用离屏渲染资源。
///
/// [origin] 可指定缩放的锚点(相对左下角对齐点的偏移),让内容"从某个位置
/// 长出来"——例如新节点从上边栏拖出的圆环位置生长。
///
/// [reveal] 指定"显形"(透明度/去模糊)占整段动画的比例(默认 1 = 与整体同步)。
/// 节点入场用 .4:前 40% 就完全显形,后面的时间专门展示缩放回弹,于是
/// "从小变大"是在不透明状态下发生的,看得见。
///
/// [blurUntil] > 0 时模糊改为在这段比例内线性消退(见 [popMotionFrame]),
/// 节点入场用 1,让"模糊→清晰"贯穿整段动画。
class BlurScaleTransition extends AnimatedWidget {
  final Widget child;
  final Alignment alignment;
  final Offset? origin;
  final double beginScale;
  final double maxBlur;
  final Offset beginOffset;
  final bool elastic;
  final double reveal;
  final double blurUntil;

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
    this.reveal = 1,
    this.blurUntil = 0,
  }) : super(listenable: animation);

  Animation<double> get animation => listenable as Animation<double>;

  @override
  Widget build(BuildContext context) {
    final value = animation.value.clamp(0.0, 1.0);
    final amplitude = MotionTokens.amplitude(context);
    final effectiveBeginScale = 1 - (1 - beginScale) * amplitude;
    final effectiveBlur = maxBlur * amplitude;
    // 显形进度:在前 reveal 段内完成(reveal = 1 时就是整体进度)
    final revealed = reveal <= 0 ? 1.0 : (value / reveal).clamp(0.0, 1.0);
    final blurFade = blurUntil <= 0
        ? 1 - revealed
        : 1 - (value / blurUntil).clamp(0.0, 1.0);
    final frame = elastic
        ? popMotionFrame(
            value,
            beginScale: effectiveBeginScale,
            maxBlur: effectiveBlur,
            opening: animation.status != AnimationStatus.reverse,
            reveal: reveal,
            blurUntil: blurUntil,
          )
        : PopMotionFrame(
            scale: effectiveBeginScale + (1 - effectiveBeginScale) * value,
            // 线性分支保持线性节奏,reveal 只压缩显形区间(1 时与旧行为一致)
            opacity: revealed,
            blur: effectiveBlur * blurFade,
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
