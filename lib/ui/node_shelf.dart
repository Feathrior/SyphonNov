library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart'
    show GestureBinding, PointerDownEvent, PointerEvent, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:flutter/services.dart';

import '../i18n.dart';
import '../models/color_utils.dart';
import '../models/data.dart' hide Column;
import '../models/registry.dart';
import '../store/settings_store.dart';
import 'motion.dart';
import 'theme.dart';

typedef NodeDropCallback = bool Function(
  String configId,
  Offset globalPosition,
);
typedef NodeDragCallback = void Function(
  String configId,
  Category category,
  Offset globalPosition,
);

/// 书脊格子尺寸与间距:悬停时从 [_kNodeTileWidth] 拓宽到 [_kNodeTileHoverWidth],
/// 弹层宽度按同一差值同步加宽(否则弹层右侧的书脊会被裁切)。
const double _kNodeTileWidth = 48;
const double _kNodeTileHoverWidth = 64;
const double _kNodeTileGap = 7;

/// 弹层与窗口边缘的最小间距(居中放不下时贴边用)
const double _kShelfPanelMargin = 16;

/// 顶部节点提示条。折叠条固定高度，节点库通过 Overlay 展开，不参与画布布局。
class NodeShelf extends StatefulWidget {
  final ValueChanged<String> onCreateNode;
  final ValueChanged<Map<String, dynamic>> onCreatePackage;
  final NodeDropCallback onDropNode;

  /// 从 Package 库拖出并松手:返回 true 表示画布接收(节点条随即收起)
  final bool Function(Map<String, dynamic> value, Offset globalPosition)
  onDropPackage;
  final NodeDragCallback onDragUpdate;

  /// Package 库拖动中:刷新画布上的落点预览
  final ValueChanged<Offset> onPackageDragUpdate;
  final VoidCallback onDragCancel;

  const NodeShelf({
    super.key,
    required this.onCreateNode,
    required this.onCreatePackage,
    required this.onDropNode,
    required this.onDropPackage,
    required this.onDragUpdate,
    required this.onPackageDragUpdate,
    required this.onDragCancel,
  });

  @override
  State<NodeShelf> createState() => _NodeShelfState();
}

class _NodeShelfState extends State<NodeShelf> {
  /// 锚点:上边栏自身的渲染框。弹层直接按它的屏幕矩形定位。
  ///
  /// 这里刻意**不用** `CompositedTransformTarget/Follower`:弹层内部每个书脊都带
  /// Tooltip,而 Tooltip 需要计算锚点的 paint transform;当锚点位于 follower 层
  /// 内、且该层变换尚未建立时,会抛
  /// "The paint transform cannot be reliably computed because of RenderFollowerLayer(s)"。
  /// 该异常会打断错误恢复流程(子树被 deactivate、InheritedWidget 依赖登记错乱),
  /// 随后连续触发 `_dependents.isEmpty` / "check that it really is our descendant"
  /// 两条框架断言,表现为整屏红色报错。
  final GlobalKey _anchorKey = GlobalKey();
  OverlayEntry? _entry;
  Timer? _leaveTimer;
  Category _category = Category.input;
  bool _packageMode = false;

  /// 当前被悬停的书脊索引:书脊 hover 时会左右拓宽,弹层宽度跟着一起加宽,
  /// 否则右侧内容会被裁掉。
  int? _hoveredTile;

  /// 分类段落锚点:弹层水平居中到当前段落下方
  final Map<Category, GlobalKey> _segmentKeys = {
    for (final category in kAllCategories) category: GlobalKey(),
  };
  final GlobalKey _packageKey = GlobalKey();

  Offset? _lastDragGlobal;
  bool _dragging = false;
  bool _closing = false;
  bool _dragCanceled = false;
  bool _keyHandlerInstalled = false;
  bool _pointerRouteInstalled = false;

  @override
  void dispose() {
    _leaveTimer?.cancel();
    _removeGlobalHandlers();
    _entry?.remove();
    _entry = null;
    super.dispose();
  }

  void _open(Category category) {
    _leaveTimer?.cancel();
    _closing = false;
    _category = category;
    _packageMode = false;
    _hoveredTile = null;
    _ensureOverlay();
    if (mounted) setState(() {});
  }

  void _openPackages() {
    _leaveTimer?.cancel();
    _closing = false;
    _packageMode = true;
    _hoveredTile = null;
    _ensureOverlay();
    if (mounted) setState(() {});
  }

  /// 书脊 hover 状态上报:弹层宽度需要同步加宽/收窄
  void _onTileHover(int index, bool hovered) {
    final next = hovered
        ? index
        : (_hoveredTile == index ? null : _hoveredTile);
    if (next == _hoveredTile) return;
    _hoveredTile = next;
    _markOverlay();
  }

  /// 建立/刷新弹层。
  ///
  /// 关键点:任何会改动 Overlay 的操作都不能落在帧的构建/布局阶段,
  /// 否则会抛 "setState() or markNeedsBuild() called during build",
  /// 整屏短暂变成红色报错页。这里统一推迟到帧后执行。
  void _ensureOverlay() {
    if (!mounted) return;
    if (_entry == null) {
      if (_inFrame) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _ensureOverlay();
        });
        return;
      }
      final entry = OverlayEntry(builder: _buildOverlay);
      _entry = entry;
      Overlay.of(context).insert(entry);
      HardwareKeyboard.instance.addHandler(_handleGlobalKey);
      _keyHandlerInstalled = true;
      return;
    }
    _markOverlay();
  }

  /// 帧的构建/布局/绘制阶段内不能直接 setState / markNeedsBuild
  static bool get _inFrame =>
      SchedulerBinding.instance.schedulerPhase != SchedulerPhase.idle &&
      SchedulerBinding.instance.schedulerPhase !=
          SchedulerPhase.postFrameCallbacks;

  void _markOverlay() {
    final entry = _entry;
    if (entry == null || !mounted) return;
    if (_inFrame) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _markOverlay();
      });
      return;
    }
    entry.markNeedsBuild();
  }

  void _scheduleClose() {
    _leaveTimer?.cancel();
    if (_dragging) return;
    _leaveTimer = Timer(const Duration(milliseconds: 120), _beginClose);
  }

  void _beginClose() {
    if (_entry == null || _dragging || !mounted) return;
    _closing = true;
    _markOverlay();
    // 退场用更短的时长,并与之匹配地移除弹层
    _leaveTimer = Timer(MotionTokens.dismissPanel(context), _removeOverlay);
  }

  void _removeOverlay() {
    _leaveTimer?.cancel();
    if (!mounted) {
      _detachOverlay();
      return;
    }
    // 同样避免在帧内移除 OverlayEntry(会打断正在构建的子树)
    if (_inFrame) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _detachOverlay());
      return;
    }
    _detachOverlay();
  }

  void _detachOverlay() {
    _entry?.remove();
    _entry = null;
    _closing = false;
    _hoveredTile = null;
    _removeGlobalHandlers();
    if (mounted) setState(() {});
  }

  bool _handleGlobalKey(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return false;
    }
    _dragCanceled = true;
    _lastDragGlobal = null;
    widget.onDragCancel();
    if (!_dragging) _removeOverlay();
    return true;
  }

  void _handleGlobalPointer(PointerEvent event) {
    if (event is PointerDownEvent &&
        (event.buttons & kSecondaryMouseButton) != 0) {
      _dragCanceled = true;
      _lastDragGlobal = null;
      widget.onDragCancel();
    }
  }

  void _installPointerRoute() {
    if (_pointerRouteInstalled) return;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_handleGlobalPointer);
    _pointerRouteInstalled = true;
  }

  /// 开始从节点条往外拖(书脊或 Package 卡片):拖拽期间不收起弹层,
  /// 并挂上全局指针/按键监听(右键或 Esc 取消)
  void _beginDrag() {
    _dragging = true;
    _dragCanceled = false;
    _lastDragGlobal = null;
    _leaveTimer?.cancel();
    _installPointerRoute();
  }

  /// 结束拖拽:清标志与全局监听,并通知画布撤掉落点预览
  void _endDrag() {
    _dragging = false;
    _dragCanceled = false;
    _lastDragGlobal = null;
    if (_pointerRouteInstalled) {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(
        _handleGlobalPointer,
      );
      _pointerRouteInstalled = false;
    }
    widget.onDragCancel();
  }

  void _removeGlobalHandlers() {
    if (_keyHandlerInstalled) {
      HardwareKeyboard.instance.removeHandler(_handleGlobalKey);
      _keyHandlerInstalled = false;
    }
    if (_pointerRouteInstalled) {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(
        _handleGlobalPointer,
      );
      _pointerRouteInstalled = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    return Material(
      type: MaterialType.transparency,
      child: RepaintBoundary(
        key: _anchorKey,
        child: Container(
          key: const Key('node-shelf'),
          height: SyphonDims.nodeShelfH,
          decoration: BoxDecoration(
            color: t.bgToolbar.withValues(alpha: 0.96),
            border: Border(bottom: BorderSide(color: t.stroke)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(
                  alpha: t.isDark ? 0.12 : 0.035,
                ),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              // 所有分类 + Package 融合成一条纯色分段条:段落之间没有空隙,
              // 鼠标横扫时不会"先关再开",弹层宽度连续变化
              _ShelfBar(
                opened: _entry != null,
                activeCategory: _category,
                packageActive: _packageMode,
                onCategory: _open,
                onPackages: _openPackages,
                onEnter: () => _leaveTimer?.cancel(),
                onExit: _scheduleClose,
                segmentKeys: _segmentKeys,
                packageKey: _packageKey,
              ),
              const Spacer(),
              Text(
                L.t('悬停展开 · 拖拽创建'),
                style: TextStyle(fontSize: 10, color: t.textFaint),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    // 弹层可能在被移除的同一帧内仍收到一次重建请求:此时宿主已销毁,
    // 继续查询 MediaQuery 等祖先会抛"deactivated widget's ancestor"并整屏报错
    if (!mounted) return const SizedBox.shrink();
    final overlayBox = Overlay.of(overlayContext).context.findRenderObject();
    final anchorBox = _anchorKey.currentContext?.findRenderObject();
    if (overlayBox is! RenderBox || anchorBox is! RenderBox) {
      return const SizedBox.shrink();
    }
    // 上边栏左下角 + 16/8 偏移(与旧 CompositedTransformFollower 的锚点一致),
    // 换算到 Overlay 坐标系;窗口尺寸变化时 MediaQuery 会驱动本弹层重建并重算
    final anchor = overlayBox.globalToLocal(anchorBox.localToGlobal(Offset.zero));
    final origin = Offset(anchor.dx + 16, anchor.dy + anchorBox.size.height + 8);

    final screen = MediaQuery.sizeOf(overlayContext);
    final count = _packageMode
        ? SettingsStore.instance.packageLibrary.length
        : kNodeConfigs.where((cfg) => cfg.category == _category).length;
    final available = (screen.width - SyphonDims.propsW - 32).clamp(
      160.0,
      680.0,
    );
    // 书脊布局:48 + 7 间距;悬停时该格加宽到 64,弹层同步加宽同样的差值
    const perTile = _kNodeTileWidth + _kNodeTileGap;
    final hoverExtra = _hoveredTile == null
        ? 0.0
        : (_kNodeTileHoverWidth - _kNodeTileWidth);
    final width = (count * perTile + 24 + hoverExtra).clamp(160.0, available);

    // 水平位置:居中于当前胶囊的正下方;若会超出窗口则紧贴窗口(与旧行为一致)
    var left = origin.dx;
    final segmentBox =
        (_packageMode ? _packageKey : _segmentKeys[_category])
            ?.currentContext
            ?.findRenderObject();
    if (segmentBox is RenderBox && segmentBox.hasSize) {
      final segmentCenter = overlayBox.globalToLocal(
        segmentBox.localToGlobal(segmentBox.size.center(Offset.zero)),
      );
      left = (segmentCenter.dx - width / 2).clamp(
        _kShelfPanelMargin,
        math.max(_kShelfPanelMargin, screen.width - width - _kShelfPanelMargin),
      );
    }
    return Positioned.fill(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AnimatedPositioned(
            left: left,
            top: origin.dy,
            // 与宽度过渡同节奏:横扫胶囊时整个面板平移到新位置
            duration: MotionTokens.quick(overlayContext),
            curve: MotionTokens.emphasized,
            child: MouseRegion(
              onEnter: (_) => _leaveTimer?.cancel(),
              onExit: (_) => _scheduleClose(),
              child: AnimatedContainer(
                key: const Key('node-library-size-transition'),
                width: width,
                // 只让背景矩形扩缩到新内容所需的尺寸;时长取"利落"档,
                // 切换分类时看起来就是矩形直接变宽/变窄
                duration: MotionTokens.quick(overlayContext),
                curve: MotionTokens.emphasized,
                // 背景矩形与开合动画固定在这一层:切换分类时它不会被重建、
                // 也不参与任何过渡,只有宽度在拉伸/收缩
                child: _LibraryPanel(
                  visible: !_closing,
                  child: AnimatedSwitcher(
                    key: const Key('node-library-content-transition'),
                    // 不同分类之间切换不做"退场→入场"两段动画:时长归零,
                    // 内容直接替换,尺寸过渡交给上面的 AnimatedContainer
                    duration: Duration.zero,
                    // 必须固定左上对齐:默认 layoutBuilder 是居中的 Stack,
                    // 宽度一变内容就跟着左右移动,看起来像左边缘在"跃变"
                    layoutBuilder: (current, previous) => Stack(
                      alignment: Alignment.topLeft,
                      children: [...previous, ?current],
                    ),
                    child: KeyedSubtree(
                      key: ValueKey(
                        _packageMode ? 'package-library' : _category.name,
                      ),
                      child: _packageMode
                          ? _PackageLibrary(
                              onPick: (value) {
                                widget.onCreatePackage(value);
                                _removeOverlay();
                              },
                              onDelete: (id) {
                                SettingsStore.instance.deletePackage(id);
                                _markOverlay();
                              },
                              onDragStarted: _beginDrag,
                              onDragUpdate: (position) {
                                _lastDragGlobal = position;
                                widget.onPackageDragUpdate(position);
                              },
                              onDragEnd: (value) {
                                final position = _lastDragGlobal;
                                final accepted =
                                    !_dragCanceled &&
                                    position != null &&
                                    widget.onDropPackage(value, position);
                                _endDrag();
                                if (accepted) {
                                  _removeOverlay();
                                } else {
                                  _markOverlay();
                                }
                              },
                              onDragCancel: _endDrag,
                            )
                          : _NodeLibrary(
                              category: _category,
                              onLibraryChanged: _markOverlay,
                              onTileHover: _onTileHover,
                              onPick: (id) {
                                SettingsStore.instance.recordNodeUse(id);
                                widget.onCreateNode(id);
                                _removeOverlay();
                              },
                              onDragStarted: _beginDrag,
                              onDragUpdate: (cfg, position) {
                                _lastDragGlobal = position;
                                widget.onDragUpdate(
                                  cfg.id,
                                  cfg.category,
                                  position,
                                );
                              },
                              onDragEnd: (cfg) {
                                final position = _lastDragGlobal;
                                final accepted =
                                    !_dragCanceled &&
                                    position != null &&
                                    widget.onDropNode(cfg.id, position);
                                _endDrag();
                                if (accepted) {
                                  SettingsStore.instance.recordNodeUse(cfg.id);
                                  _removeOverlay();
                                } else {
                                  _markOverlay();
                                }
                              },
                              onDragCancel: _endDrag,
                            ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
  }
}

/// 上边栏的一体化分类条:所有分类与 Package 位于同一个分段容器内。
///
/// 段落之间没有空隙,鼠标横向扫过时整条栏只触发一次 onEnter/onExit,
/// 次级菜单不会再"先关再开",而是直接切换分类并让宽度连续变化。
class _ShelfBar extends StatelessWidget {
  final bool opened;
  final Category activeCategory;
  final bool packageActive;
  final ValueChanged<Category> onCategory;
  final VoidCallback onPackages;
  final VoidCallback onEnter;
  final VoidCallback onExit;
  /// 各段落的锚点 key:弹层据此把自己的中心对齐到当前段落下方
  final Map<Category, GlobalKey> segmentKeys;
  final GlobalKey packageKey;

  const _ShelfBar({
    required this.opened,
    required this.activeCategory,
    required this.packageActive,
    required this.onCategory,
    required this.onPackages,
    required this.onEnter,
    required this.onExit,
    required this.segmentKeys,
    required this.packageKey,
  });

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    return MouseRegion(
      onEnter: (_) => onEnter(),
      onExit: (_) => onExit(),
      child: Container(
        key: const Key('node-shelf-bar'),
        height: 40,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: t.bgRaise,
          borderRadius: BorderRadius.circular(11),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final category in kAllCategories)
              _ShelfSegment(
                key: segmentKeys[category],
                tileKey: ValueKey('node-category-${category.name}'),
                symbol: kCategoryInfo[category]!.icon,
                label: L.t(kCategoryInfo[category]!.label),
                color: parseColor(kCategoryInfo[category]!.color),
                highlighted: opened && activeCategory == category,
                onEnter: () => onCategory(category),
                onTap: () => onCategory(category),
              ),
            _ShelfSegment(
              key: packageKey,
              tileKey: const Key('node-category-package'),
              symbol: '⧉',
              label: 'Package',
              color: const Color(0xFF8A9099),
              highlighted: opened && packageActive,
              onEnter: onPackages,
              onTap: onPackages,
            ),
          ],
        ),
      ),
    );
  }
}

/// 分类条里的一段:低饱和填充 + 彩色内描边(呼出时加粗)。
///
/// 不做发光:状态只靠内描边的粗细/透明度与文字明度区分,整体比过去的
/// 实心高饱和更收敛。
class _ShelfSegment extends StatefulWidget {
  final String symbol;
  final String label;
  final Color color;
  final bool highlighted;
  final Key? tileKey;
  final VoidCallback onEnter;
  final VoidCallback onTap;

  const _ShelfSegment({
    super.key,
    required this.symbol,
    required this.label,
    required this.color,
    required this.highlighted,
    required this.tileKey,
    required this.onEnter,
    required this.onTap,
  });

  @override
  State<_ShelfSegment> createState() => _ShelfSegmentState();
}

class _ShelfSegmentState extends State<_ShelfSegment> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    final on = _hover || widget.highlighted;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        setState(() => _hover = true);
        widget.onEnter();
      },
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          key: widget.tileKey,
          duration: MotionTokens.standard(context),
          curve: MotionTokens.enter,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          // 内边距恒定:hover 只加粗内描边/提亮文字,胶囊尺寸不变——
          // 尺寸变化会让后续胶囊整体位移,弹层"居中于胶囊"的定位就会差几像素。
          // 上下留 4px:文字行高(含回退字形)完全落在胶囊内,不会被切掉下半截
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          decoration: BoxDecoration(
            // 低饱和填充 + 彩色内描边;无发光
            color: widget.color.withValues(alpha: on ? .20 : .07),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: widget.color.withValues(alpha: on ? .95 : .45),
              width: on ? 1.8 : 1.2,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.symbol,
                style: TextStyle(fontSize: 11, color: widget.color),
              ),
              const SizedBox(width: 5),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: on ? t.text : t.textDim,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
/// 上边栏弹层的持久外壳:圆角背景矩形 + 边框 + 阴影 + 开合动画。
///
/// 它位于会被替换的库内容之外,所以鼠标在分类胶囊之间扫过时,这块背景
/// 始终是同一个元素、只随内容宽度拉伸收缩,没有任何重建或淡入淡出;
/// 只有真正呼出/收起弹层时(鼠标离开所有胶囊)才播放淡入淡出。
class _LibraryPanel extends StatelessWidget {
  final bool visible;
  final Widget child;

  const _LibraryPanel({required this.visible, required this.child});

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: visible ? 1 : 0),
      // 退场比呼出快一倍(与 _beginClose 的移除计时一致)
      duration: visible
          ? MotionTokens.standard(context)
          : MotionTokens.dismissPanel(context),
      curve: MotionTokens.emphasized,
      builder: (context, value, child) {
        final amplitude = MotionTokens.amplitude(context);
        final eased = Curves.easeOutBack.transform(value);
        return Opacity(
          opacity: amplitude == 0 ? 1 : Curves.easeOutCubic.transform(value),
          child: Transform.translate(
            offset: Offset(0, -10 * amplitude * (1 - value)),
            child: Transform.scale(
              scale: 1 + (.92 + .08 * eased - 1) * amplitude,
              alignment: Alignment.topLeft,
              child: child,
            ),
          ),
        );
      },
      child: RepaintBoundary(
        child: Container(
          key: const Key('node-library-panel'),
          height: 250,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: t.bgFloat.withValues(alpha: .985),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: t.strokeStrong),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: t.isDark ? .34 : .14),
                blurRadius: 36,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: Material(
            // InkWell 需要 Material 祖先;放在持久外壳里,内容替换时不会重建
            type: MaterialType.transparency,
            child: child,
          ),
        ),
      ),
    );
  }
}

class _PackageLibrary extends StatelessWidget {
  final ValueChanged<Map<String, dynamic>> onPick;
  final ValueChanged<String> onDelete;
  final VoidCallback onDragStarted;
  final ValueChanged<Offset> onDragUpdate;
  final ValueChanged<Map<String, dynamic>> onDragEnd;
  final VoidCallback onDragCancel;

  const _PackageLibrary({
    required this.onPick,
    required this.onDelete,
    required this.onDragStarted,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
  });

  /// Package 卡片统一用中性灰(与画布上 Package 代理同色)
  static const Color _tint = Color(0xFF8A9099);

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    final items = SettingsStore.instance.packageLibrary;
    return KeyedSubtree(
      key: const Key('package-library-overlay'),
      child: items.isEmpty
          ? Center(
              child: Text('尚未保存 Package', style: TextStyle(color: t.textFaint)),
            )
          : ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(2, 2, 2, 4),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(width: _kNodeTileGap),
              itemBuilder: (context, index) {
                final item = items[index];
                final name = '${item['name'] ?? 'Package'}';
                final tile = Container(
                  width: _kNodeTileWidth,
                  padding: const EdgeInsets.symmetric(
                    vertical: 10,
                    horizontal: 7,
                  ),
                  decoration: BoxDecoration(
                    color: _tint.withValues(alpha: .14),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _tint.withValues(alpha: .42)),
                  ),
                  child: Column(
                    children: [
                      const Icon(
                        Icons.inventory_2_outlined,
                        size: 16,
                        color: _tint,
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: _VerticalSpineLabel(name, color: t.text),
                      ),
                      IconButton(
                        key: ValueKey('delete-package-${item['id']}'),
                        tooltip: '从 Package 库删除',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                          width: 24,
                          height: 24,
                        ),
                        icon: Icon(
                          Icons.delete_outline,
                          size: 15,
                          color: t.textFaint,
                        ),
                        onPressed: () => onDelete('${item['id']}'),
                      ),
                    ],
                  ),
                );
                // 与节点书脊一致:可拖到画布落位,也可单击直接创建
                return Tooltip(
                  message: name,
                  waitDuration: const Duration(milliseconds: 500),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.grab,
                    child: Draggable<Map<String, dynamic>>(
                      key: ValueKey('package-spine-${item['id']}'),
                      data: item,
                      dragAnchorStrategy: (_, _, _) => const Offset(
                        _kDragRingExtent / 2,
                        _kDragRingExtent / 2,
                      ),
                      feedback: const _DragRing(color: _tint),
                      childWhenDragging: Opacity(opacity: .45, child: tile),
                      onDragStarted: onDragStarted,
                      onDragUpdate: (details) =>
                          onDragUpdate(details.globalPosition),
                      onDragEnd: (_) => onDragEnd(item),
                      onDraggableCanceled: (_, _) => onDragCancel(),
                      child: InkWell(
                        onTap: () => onPick(item),
                        borderRadius: BorderRadius.circular(8),
                        child: tile,
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _NodeLibrary extends StatelessWidget {
  final Category category;
  final VoidCallback onLibraryChanged;
  final void Function(int index, bool hovered) onTileHover;
  final ValueChanged<String> onPick;
  final VoidCallback onDragStarted;
  final void Function(NodeConfig, Offset) onDragUpdate;
  final ValueChanged<NodeConfig> onDragEnd;
  final VoidCallback onDragCancel;

  const _NodeLibrary({
    required this.category,
    required this.onLibraryChanged,
    required this.onTileHover,
    required this.onPick,
    required this.onDragStarted,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
  });

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    final settings = SettingsStore.instance;
    // 顶栏是空间记忆入口：始终遵循注册表顺序，收藏和最近使用只记录状态，
    // 不再移动书脊，避免用户每次创建节点后目标位置发生变化。
    final items = kNodeConfigs
        .where((cfg) => cfg.category == category)
        .toList(growable: false);

    return RepaintBoundary(
      key: const Key('node-library-overlay'),
      child: items.isEmpty
          ? Center(
              child: Text(
                L.t('无匹配节点'),
                style: TextStyle(color: t.textFaint),
              ),
            )
          : ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(2, 2, 2, 4),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(width: _kNodeTileGap),
              itemBuilder: (context, index) => _NodeTile(
                cfg: items[index],
                favorite: settings.favoriteNodeIds.contains(items[index].id),
                onHoverChanged: (hovered) => onTileHover(index, hovered),
                onFavorite: () {
                  settings.toggleFavoriteNode(items[index].id);
                  onLibraryChanged();
                },
                onPick: () => onPick(items[index].id),
                onDragStarted: onDragStarted,
                onDragUpdate: (position) =>
                    onDragUpdate(items[index], position),
                onDragEnd: () => onDragEnd(items[index]),
                onDragCancel: onDragCancel,
              ),
            ),
    );
  }
}

class _NodeTile extends StatefulWidget {
  final NodeConfig cfg;
  final bool favorite;
  final ValueChanged<bool> onHoverChanged;
  final VoidCallback onFavorite;
  final VoidCallback onPick;
  final VoidCallback onDragStarted;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onDragCancel;
  const _NodeTile({
    required this.cfg,
    required this.favorite,
    required this.onHoverChanged,
    required this.onFavorite,
    required this.onPick,
    required this.onDragStarted,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
  });

  @override
  State<_NodeTile> createState() => _NodeTileState();
}

class _NodeTileState extends State<_NodeTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    final info = kCategoryInfo[widget.cfg.category]!;
    final color = parseColor(info.color);
    final tile = AnimatedContainer(
      key: ValueKey('node-spine-${widget.cfg.id}'),
      // 与弹层尺寸过渡同一条曲线与时长:横向扫过书脊时,书脊位移与背景矩形
      // 边缘同步推进(此前 easeOutBack 过冲 + 时长不一致,看起来会"跳变")
      duration: MotionTokens.quick(context),
      curve: MotionTokens.emphasized,
      width: _hover ? _kNodeTileHoverWidth : _kNodeTileWidth,
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 10),
      decoration: BoxDecoration(
        color: _hover ? color.withValues(alpha: 0.22) : t.bgRaise,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _hover ? color.withValues(alpha: 0.42) : t.stroke,
        ),
        // 阴影的模糊与偏移在两种状态下保持一致,只让颜色淡入淡出。
        // 曲线 easeOutBack 会过冲到 t>1,而 lerpDouble 是外插:
        // 若模糊从 12 插到 0,t=1.1 时会得到负的 blurRadius 并触发框架断言
        // "Text shadow blur radius should be non-negative"(构建期红色报错,
        // 还会连带引发 _dependents.isEmpty 等次生断言)。
        boxShadow: [
          BoxShadow(
            color: _hover
                ? color.withValues(alpha: .2)
                : color.withValues(alpha: 0),
            blurRadius: 12,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            width: 18,
            height: 4,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: _VerticalSpineLabel(L.t(widget.cfg.label), color: t.text),
          ),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: widget.onFavorite,
            child: Icon(
              widget.favorite ? Icons.star_rounded : Icons.star_border_rounded,
              size: 15,
              color: widget.favorite ? color : t.textFaint,
            ),
          ),
        ],
      ),
    );

    return Tooltip(
      message: L.t(widget.cfg.description),
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        onEnter: (_) {
          setState(() => _hover = true);
          widget.onHoverChanged(true);
        },
        onExit: (_) {
          setState(() => _hover = false);
          widget.onHoverChanged(false);
        },
        child: Draggable<String>(
          data: widget.cfg.id,
          // 指示环以指针为中心(与右键圆环拖出的圆球一致),
          // 因此锚点取反馈框中心而不是左上角
          dragAnchorStrategy: (_, _, _) =>
              const Offset(_kDragRingExtent / 2, _kDragRingExtent / 2),
          feedback: _DragRing(color: color),
          childWhenDragging: Opacity(opacity: .45, child: tile),
          onDragStarted: widget.onDragStarted,
          onDragUpdate: (details) =>
              widget.onDragUpdate(details.globalPosition),
          onDragEnd: (_) => widget.onDragEnd(),
          onDraggableCanceled: (_, _) => widget.onDragCancel(),
          child: InkWell(
            onTap: widget.onPick,
            borderRadius: BorderRadius.circular(12),
            splashColor: Colors.transparent,
            hoverColor: Colors.transparent,
            child: tile,
          ),
        ),
      ),
    );
  }
}

class _VerticalSpineLabel extends StatelessWidget {
  final String label;
  final Color color;

  const _VerticalSpineLabel(this.label, {required this.color});

  @override
  Widget build(BuildContext context) {
    final vertical = label.runes.map(String.fromCharCode).join('\n');
    return Center(
      child: Text(
        vertical,
        maxLines: 9,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 12,
          height: 1.05,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

/// 拖拽指示环的反馈框尺寸(环本身 19px,其余留白给"从条形长出来"的形变)
const double _kDragRingExtent = 52;

/// 从顶部书脊拖出节点时的跟随指示环。
///
/// 起始形状是分类胶囊那样的横条,随后很快(与节点入场同节奏)"长"成与右键
/// 圆环拖出的圆球同尺寸的圆环:环体是几乎纯白的亮色(只留一点分类底色),
/// 外面套一层同色发光阴影,不再额外描一圈细线。
class _DragRing extends StatefulWidget {
  final Color color;

  const _DragRing({required this.color});

  @override
  State<_DragRing> createState() => _DragRingState();
}

class _DragRingState extends State<_DragRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 与节点入场同节奏:条形变圆环要利落,不能拖成"慢动作"
    _controller.duration = MotionTokens.nodeEntry(context);
    if (!_started) {
      _started = true;
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, _) {
      final amplitude = MotionTokens.amplitude(context);
      final frame = popMotionFrame(
        _controller.value,
        beginScale: 1 - .82 * amplitude,
        maxBlur: 16 * amplitude,
      );
      final turn =
          -.2 *
          amplitude *
          (1 - Curves.easeOutCubic.transform(_controller.value));
      final content = Opacity(
        opacity: amplitude == 0 ? 1 : frame.opacity,
        child: Transform.rotate(
          angle: turn,
          child: Transform.scale(
            scale: amplitude == 0 ? 1 : frame.scale,
            child: IgnorePointer(
              child: CustomPaint(
                key: const Key('node-drag-dot'),
                size: const Size(_kDragRingExtent, _kDragRingExtent),
                painter: _DragRingPainter(
                  color: widget.color,
                  progress: amplitude == 0 ? 1 : _controller.value,
                ),
              ),
            ),
          ),
        ),
      );
      if (frame.blur <= .05) return content;
      return ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: frame.blur,
          sigmaY: frame.blur,
        ),
        child: content,
      );
    },
  );
}

class _DragRingPainter extends CustomPainter {
  /// 与右键圆环拖出的圆点同尺寸(radial_node_menu 中半径为 9.5)
  static const double _ringDiameter = 19;
  static const double _ringStroke = 3.8;
  static const double _barWidth = 44;
  static const double _barHeight = 13;

  final Color color;
  final double progress;

  const _DragRingPainter({required this.color, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final clamped = progress.clamp(0.0, 1.0);
    // 轻微过冲:条形先缩到略小于圆环,再回弹到圆环尺寸
    final morph = Curves.easeOutBack.transform(clamped);
    final width = _barWidth + (_ringDiameter - _barWidth) * morph;
    final height = _barHeight + (_ringDiameter - _barHeight) * morph;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: size.center(Offset.zero),
        width: width,
        height: height,
      ),
      Radius.circular(height / 2),
    );
    final appear = Curves.easeOut.transform(clamped);
    // 环体接近纯白,只留一点分类底色 —— 在任何背景上都"跳"出来
    final bright = Color.lerp(color, Colors.white, .86)!;
    // 1) 分类色的发光阴影(柔和的模糊,不产生硬边)
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _ringStroke * 3
        ..color = color.withValues(alpha: .62 * appear)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );
    // 2) 环体本身:粗一点、亮一点;不再额外描一圈细线
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _ringStroke
        ..color = bright.withValues(alpha: .96 * appear),
    );
  }

  @override
  bool shouldRepaint(covariant _DragRingPainter old) =>
      old.color != color || old.progress != progress;
}
