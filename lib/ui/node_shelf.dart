library;

import 'dart:async';

import 'package:flutter/gestures.dart'
    show GestureBinding, PointerDownEvent, PointerEvent, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart'
    show SchedulerBinding, SchedulerPhase;
import 'package:flutter/services.dart';

import '../i18n.dart';
import '../models/color_utils.dart';
import '../models/data.dart' hide Column;
import '../models/registry.dart';
import '../store/settings_store.dart';
import 'motion.dart';
import 'theme.dart';

typedef NodeDropCallback =
    bool Function(String configId, Offset globalPosition);
typedef NodeDragCallback =
    void Function(String configId, Category category, Offset globalPosition);

/// 顶部节点提示条。折叠条固定高度，节点库通过 Overlay 展开，不参与画布布局。
class NodeShelf extends StatefulWidget {
  final ValueChanged<String> onCreateNode;
  final ValueChanged<Map<String, dynamic>> onCreatePackage;
  final NodeDropCallback onDropNode;
  final NodeDragCallback onDragUpdate;
  final VoidCallback onDragCancel;

  const NodeShelf({
    super.key,
    required this.onCreateNode,
    required this.onCreatePackage,
    required this.onDropNode,
    required this.onDragUpdate,
    required this.onDragCancel,
  });

  @override
  State<NodeShelf> createState() => _NodeShelfState();
}

class _NodeShelfState extends State<NodeShelf> {
  final LayerLink _link = LayerLink();
  OverlayEntry? _entry;
  Timer? _leaveTimer;
  Category _category = Category.input;
  bool _packageMode = false;
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
    _ensureOverlay();
    if (mounted) setState(() {});
  }

  void _openPackages() {
    _leaveTimer?.cancel();
    _closing = false;
    _packageMode = true;
    _ensureOverlay();
    if (mounted) setState(() {});
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
    _leaveTimer = Timer(MotionTokens.standard(context), _removeOverlay);
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
      child: CompositedTransformTarget(
        link: _link,
        child: RepaintBoundary(
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
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                for (final category in kAllCategories) ...[
                  _CategoryPill(
                    category: category,
                    active: _entry != null && _category == category,
                    onEnter: () => _open(category),
                    onExit: _scheduleClose,
                    onTap: () => _open(category),
                  ),
                  const SizedBox(width: 6),
                ],
                _PackagePill(
                  active: _entry != null && _packageMode,
                  onEnter: _openPackages,
                  onExit: _scheduleClose,
                  onTap: _openPackages,
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
      ),
    );
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    // 弹层可能在被移除的同一帧内仍收到一次重建请求:此时宿主已销毁,
    // 继续查询 MediaQuery 等祖先会抛"deactivated widget's ancestor"并整屏报错
    if (!mounted) return const SizedBox.shrink();
    final screen = MediaQuery.sizeOf(overlayContext);
    final count = _packageMode
        ? SettingsStore.instance.packageLibrary.length
        : kNodeConfigs.where((cfg) => cfg.category == _category).length;
    final available = (screen.width - SyphonDims.propsW - 32).clamp(
      160.0,
      680.0,
    );
    final width = (count * 55.0 + 24).clamp(160.0, available);
    return Positioned.fill(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            targetAnchor: Alignment.bottomLeft,
            followerAnchor: Alignment.topLeft,
            offset: const Offset(16, 8),
            child: MouseRegion(
              onEnter: (_) => _leaveTimer?.cancel(),
              onExit: (_) => _scheduleClose(),
              child: AnimatedContainer(
                key: const Key('node-library-size-transition'),
                width: width,
                duration: MotionTokens.spatial(overlayContext),
                curve: MotionTokens.emphasized,
                child: AnimatedSwitcher(
                  key: const Key('node-library-content-transition'),
                  duration: MotionTokens.standard(overlayContext),
                  reverseDuration: MotionTokens.quick(overlayContext),
                  switchInCurve: MotionTokens.enter,
                  switchOutCurve: MotionTokens.exit,
                  layoutBuilder: (current, previous) => Stack(
                    alignment: Alignment.topLeft,
                    children: [...previous, ?current],
                  ),
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(
                      scale: Tween(begin: .94, end: 1.0).animate(animation),
                      alignment: Alignment.topLeft,
                      child: child,
                    ),
                  ),
                  child: KeyedSubtree(
                    key: ValueKey(
                      _packageMode ? 'package-library' : _category.name,
                    ),
                    child: _packageMode
                        ? _PackageLibrary(
                            width: width,
                            visible: !_closing,
                            onPick: (value) {
                              widget.onCreatePackage(value);
                              _removeOverlay();
                            },
                            onDelete: (id) {
                              SettingsStore.instance.deletePackage(id);
                              _markOverlay();
                            },
                          )
                        : _NodeLibrary(
                            width: width,
                            visible: !_closing,
                            category: _category,
                            onLibraryChanged: _markOverlay,
                            onPick: (id) {
                              SettingsStore.instance.recordNodeUse(id);
                              widget.onCreateNode(id);
                              _removeOverlay();
                            },
                            onDragStarted: () {
                              _dragging = true;
                              _dragCanceled = false;
                              _lastDragGlobal = null;
                              _leaveTimer?.cancel();
                              _installPointerRoute();
                            },
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
                              _dragging = false;
                              _dragCanceled = false;
                              _lastDragGlobal = null;
                              if (_pointerRouteInstalled) {
                                GestureBinding.instance.pointerRouter
                                    .removeGlobalRoute(_handleGlobalPointer);
                                _pointerRouteInstalled = false;
                              }
                              widget.onDragCancel();
                              if (accepted) {
                                SettingsStore.instance.recordNodeUse(cfg.id);
                                _removeOverlay();
                              } else {
                                _markOverlay();
                              }
                            },
                            onDragCancel: () {
                              _dragging = false;
                              _dragCanceled = false;
                              _lastDragGlobal = null;
                              if (_pointerRouteInstalled) {
                                GestureBinding.instance.pointerRouter
                                    .removeGlobalRoute(_handleGlobalPointer);
                                _pointerRouteInstalled = false;
                              }
                              widget.onDragCancel();
                            },
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

class _CategoryPill extends StatefulWidget {
  final Category category;
  final bool active;
  final VoidCallback onEnter;
  final VoidCallback onExit;
  final VoidCallback onTap;

  const _CategoryPill({
    required this.category,
    required this.active,
    required this.onEnter,
    required this.onExit,
    required this.onTap,
  });

  @override
  State<_CategoryPill> createState() => _CategoryPillState();
}

class _CategoryPillState extends State<_CategoryPill> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    final info = kCategoryInfo[widget.category]!;
    final color = parseColor(info.color);
    final active = _hover || widget.active;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        setState(() => _hover = true);
        widget.onEnter();
      },
      onExit: (_) {
        setState(() => _hover = false);
        widget.onExit();
      },
      child: Semantics(
        button: true,
        label: L.t(info.label),
        child: InkWell(
          onTap: widget.onTap,
          mouseCursor: SystemMouseCursors.click,
          borderRadius: BorderRadius.circular(10),
          splashColor: Colors.transparent,
          hoverColor: Colors.transparent,
          focusColor: color.withValues(alpha: .08),
          child: AnimatedContainer(
            key: ValueKey('node-category-${widget.category.name}'),
            duration: MotionTokens.standard(context),
            curve: MotionTokens.enter,
            padding: EdgeInsets.symmetric(
              horizontal: active ? 13 : 10,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              color: color.withValues(alpha: active ? 0.14 : 0.07),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: color.withValues(alpha: active ? 0.38 : 0.14),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(info.icon, style: TextStyle(fontSize: 11, color: color)),
                const SizedBox(width: 6),
                Text(
                  L.t(info.label),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: t.text,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PackagePill extends StatefulWidget {
  final bool active;
  final VoidCallback onEnter;
  final VoidCallback onExit;
  final VoidCallback onTap;

  const _PackagePill({
    required this.active,
    required this.onEnter,
    required this.onExit,
    required this.onTap,
  });

  @override
  State<_PackagePill> createState() => _PackagePillState();
}

class _PackagePillState extends State<_PackagePill> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    final active = _hover || widget.active;
    const color = Color(0xFF8A9099);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        setState(() => _hover = true);
        widget.onEnter();
      },
      onExit: (_) {
        setState(() => _hover = false);
        widget.onExit();
      },
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          key: const Key('node-category-package'),
          duration: MotionTokens.standard(context),
          padding: EdgeInsets.symmetric(
            horizontal: active ? 13 : 10,
            vertical: 6,
          ),
          decoration: BoxDecoration(
            color: color.withValues(alpha: active ? .18 : .08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: color.withValues(alpha: active ? .5 : .2),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.inventory_2_outlined, size: 13, color: color),
              const SizedBox(width: 6),
              Text(
                'Package',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: t.text,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PackageLibrary extends StatelessWidget {
  final double width;
  final bool visible;
  final ValueChanged<Map<String, dynamic>> onPick;
  final ValueChanged<String> onDelete;

  const _PackageLibrary({
    required this.width,
    required this.visible,
    required this.onPick,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    final items = SettingsStore.instance.packageLibrary;
    return Material(
      type: MaterialType.transparency,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: visible ? 1 : 0),
        duration: MotionTokens.standard(context),
        curve: MotionTokens.emphasized,
        builder: (context, value, child) => Opacity(
          opacity: value,
          child: Transform.scale(
            scale: .93 + .07 * value,
            alignment: Alignment.topLeft,
            child: child,
          ),
        ),
        child: RepaintBoundary(
          child: Container(
            key: const Key('package-library-overlay'),
            width: width,
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
            child: items.isEmpty
                ? Center(
                    child: Text(
                      '尚未保存 Package',
                      style: TextStyle(color: t.textFaint),
                    ),
                  )
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 7),
                    itemBuilder: (context, index) {
                      final item = items[index];
                      final name = '${item['name'] ?? 'Package'}';
                      return InkWell(
                        key: ValueKey('package-spine-${item['id']}'),
                        onTap: () => onPick(item),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          width: 48,
                          padding: const EdgeInsets.symmetric(
                            vertical: 10,
                            horizontal: 7,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(
                              0xFF8A9099,
                            ).withValues(alpha: .14),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: const Color(
                                0xFF8A9099,
                              ).withValues(alpha: .42),
                            ),
                          ),
                          child: Column(
                            children: [
                              const Icon(
                                Icons.inventory_2_outlined,
                                size: 16,
                                color: Color(0xFF8A9099),
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
                        ),
                      );
                    },
                  ),
          ),
        ),
      ),
    );
  }
}

class _NodeLibrary extends StatelessWidget {
  final double width;
  final bool visible;
  final Category category;
  final VoidCallback onLibraryChanged;
  final ValueChanged<String> onPick;
  final VoidCallback onDragStarted;
  final void Function(NodeConfig, Offset) onDragUpdate;
  final ValueChanged<NodeConfig> onDragEnd;
  final VoidCallback onDragCancel;

  const _NodeLibrary({
    required this.width,
    required this.visible,
    required this.category,
    required this.onLibraryChanged,
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

    return Material(
      type: MaterialType.transparency,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: visible ? 1 : 0),
        duration: MotionTokens.standard(context),
        curve: MotionTokens.emphasized,
        builder: (context, value, child) => Opacity(
          opacity: value,
          child: Transform.scale(
            scale: .93 + .07 * value,
            alignment: Alignment.topLeft,
            child: child,
          ),
        ),
        child: RepaintBoundary(
          child: Container(
            key: const Key('node-library-overlay'),
            width: width,
            height: 250,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: t.bgFloat.withValues(alpha: 0.985),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: t.strokeStrong),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: t.isDark ? 0.34 : 0.14),
                  blurRadius: 36,
                  offset: const Offset(0, 14),
                ),
              ],
            ),
            child: Column(
              children: [
                Expanded(
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
                          separatorBuilder: (_, _) => const SizedBox(width: 7),
                          itemBuilder: (context, index) => _NodeTile(
                            cfg: items[index],
                            favorite: settings.favoriteNodeIds.contains(
                              items[index].id,
                            ),
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
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NodeTile extends StatefulWidget {
  final NodeConfig cfg;
  final bool favorite;
  final VoidCallback onFavorite;
  final VoidCallback onPick;
  final VoidCallback onDragStarted;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onDragCancel;
  const _NodeTile({
    required this.cfg,
    required this.favorite,
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
      duration: MotionTokens.standard(context),
      curve: MotionTokens.enter,
      width: _hover ? 64 : 48,
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 10),
      decoration: BoxDecoration(
        color: _hover ? color.withValues(alpha: 0.22) : t.bgRaise,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _hover ? color.withValues(alpha: 0.42) : t.stroke,
        ),
        boxShadow: _hover
            ? [
                BoxShadow(
                  color: color.withValues(alpha: .2),
                  blurRadius: 12,
                  offset: const Offset(0, 5),
                ),
              ]
            : null,
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
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
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
/// 起始形状是分类胶囊那样的横条,随后"长"成与右键圆环拖出的圆球同尺寸的
/// 空心圆环:环内不再发光,描边加粗到 3px,以 30% 透明度 + 叠加(变亮)
/// 混合绘制 —— 与画布/节点重叠时只提亮,不遮挡下层内容。
class _DragRing extends StatefulWidget {
  final Color color;

  const _DragRing({required this.color});

  @override
  State<_DragRing> createState() => _DragRingState();
}

class _DragRingState extends State<_DragRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => CustomPaint(
        key: const Key('node-drag-dot'),
        size: const Size(_kDragRingExtent, _kDragRingExtent),
        painter: _DragRingPainter(
          color: widget.color,
          progress: _controller.value,
        ),
      ),
    ),
  );
}

class _DragRingPainter extends CustomPainter {
  /// 与右键圆环拖出的圆点同尺寸(radial_node_menu 中半径为 9.5)
  static const double _ringDiameter = 19;
  static const double _ringStroke = 3;
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
    final rect = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: width,
      height: height,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(height / 2)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _ringStroke
        ..color = color.withValues(
          alpha: .3 * Curves.easeOut.transform(clamped),
        )
        ..blendMode = BlendMode.plus,
    );
  }

  @override
  bool shouldRepaint(covariant _DragRingPainter old) =>
      old.color != color || old.progress != progress;
}