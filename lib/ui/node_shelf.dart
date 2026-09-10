library;

import 'dart:async';

import 'package:flutter/gestures.dart'
    show GestureBinding, PointerDownEvent, PointerEvent, kSecondaryMouseButton;
import 'package:flutter/material.dart';
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
  final NodeDropCallback onDropNode;
  final NodeDragCallback onDragUpdate;
  final VoidCallback onDragCancel;

  const NodeShelf({
    super.key,
    required this.onCreateNode,
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
    if (_entry == null) {
      _entry = OverlayEntry(builder: _buildOverlay);
      Overlay.of(context).insert(_entry!);
      HardwareKeyboard.instance.addHandler(_handleGlobalKey);
      _keyHandlerInstalled = true;
    } else {
      _entry!.markNeedsBuild();
    }
    if (mounted) setState(() {});
  }

  void _scheduleClose() {
    _leaveTimer?.cancel();
    if (_dragging) return;
    _leaveTimer = Timer(const Duration(milliseconds: 120), _beginClose);
  }

  void _beginClose() {
    if (_entry == null || _dragging || !mounted) return;
    _closing = true;
    _entry!.markNeedsBuild();
    _leaveTimer = Timer(MotionTokens.standard(context), _removeOverlay);
  }

  void _removeOverlay() {
    _leaveTimer?.cancel();
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
                Icon(
                  Icons.add_circle_outline_rounded,
                  size: 15,
                  color: t.textFaint,
                ),
                const SizedBox(width: 8),
                Text(
                  L.t('拖出节点'),
                  style: TextStyle(fontSize: 11, color: t.textFaint),
                ),
                const SizedBox(width: 12),
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
    final screen = MediaQuery.sizeOf(overlayContext);
    final width = (screen.width - SyphonDims.propsW - 32).clamp(360.0, 680.0);
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
              child: _NodeLibrary(
                width: width,
                visible: !_closing,
                category: _category,
                onLibraryChanged: () => _entry?.markNeedsBuild(),
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
                  widget.onDragUpdate(cfg.id, cfg.category, position);
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
                    GestureBinding.instance.pointerRouter.removeGlobalRoute(
                      _handleGlobalPointer,
                    );
                    _pointerRouteInstalled = false;
                  }
                  widget.onDragCancel();
                  if (accepted) {
                    SettingsStore.instance.recordNodeUse(cfg.id);
                    _removeOverlay();
                  } else {
                    _entry?.markNeedsBuild();
                  }
                },
                onDragCancel: () {
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
                },
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
    final source = kNodeConfigs.where((cfg) => cfg.category == category);
    final items = source.toList()
      ..sort((a, b) {
        final af = settings.favoriteNodeIds.contains(a.id) ? 0 : 1;
        final bf = settings.favoriteNodeIds.contains(b.id) ? 0 : 1;
        if (af != bf) return af.compareTo(bf);
        final ar = settings.recentNodeIds.indexOf(a.id);
        final br = settings.recentNodeIds.indexOf(b.id);
        if (ar >= 0 || br >= 0) {
          if (ar < 0) return 1;
          if (br < 0) return -1;
          return ar.compareTo(br);
        }
        return a.label.compareTo(b.label);
      });

    return Material(
      type: MaterialType.transparency,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: visible ? 1 : 0),
        duration: MotionTokens.standard(context),
        curve: MotionTokens.emphasized,
        builder: (context, value, child) => BlurScaleTransition(
          animation: AlwaysStoppedAnimation(value),
          alignment: Alignment.topLeft,
          child: child!,
        ),
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
            child: RotatedBox(
              quarterTurns: 3,
              child: Center(
                child: Text(
                  L.t(widget.cfg.label),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: t.text,
                  ),
                ),
              ),
            ),
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
          dragAnchorStrategy: pointerDragAnchorStrategy,
          feedback: _DragDot(color: color, icon: info.icon),
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

class _DragDot extends StatelessWidget {
  final Color color;
  final String icon;
  const _DragDot({required this.color, required this.icon});

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Container(
      key: const Key('node-drag-dot'),
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withValues(alpha: .9), width: 2),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: .48),
            blurRadius: 18,
            spreadRadius: 4,
          ),
        ],
      ),
      child: Text(
        icon,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          decoration: TextDecoration.none,
        ),
      ),
    ),
  );
}
