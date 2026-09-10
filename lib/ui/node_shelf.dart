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
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
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
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _open(Category category, {bool focusSearch = false}) {
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
    if (focusSearch) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _searchFocus.requestFocus(),
      );
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
    _search.clear();
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
                    onTap: () => _open(category, focusSearch: true),
                  ),
                  const SizedBox(width: 6),
                ],
                const Spacer(),
                Icon(Icons.search_rounded, size: 14, color: t.textFaint),
                const SizedBox(width: 5),
                Text(
                  L.t('单击搜索 · 拖拽创建'),
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
                search: _search,
                searchFocus: _searchFocus,
                onSearchChanged: (_) => _entry?.markNeedsBuild(),
                onSwitchCategory: _open,
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
  final TextEditingController search;
  final FocusNode searchFocus;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<Category> onSwitchCategory;
  final ValueChanged<String> onPick;
  final VoidCallback onDragStarted;
  final void Function(NodeConfig, Offset) onDragUpdate;
  final ValueChanged<NodeConfig> onDragEnd;
  final VoidCallback onDragCancel;

  const _NodeLibrary({
    required this.width,
    required this.visible,
    required this.category,
    required this.search,
    required this.searchFocus,
    required this.onSearchChanged,
    required this.onSwitchCategory,
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
    final query = search.text.trim().toLowerCase();
    final source = query.isEmpty
        ? kNodeConfigs.where((cfg) => cfg.category == category)
        : kNodeConfigs.where((cfg) {
            final haystack =
                '${cfg.label} ${cfg.description} ${cfg.id.replaceAll('_', ' ')}'
                    .toLowerCase();
            return haystack.contains(query);
          });
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
        builder: (context, value, child) => Opacity(
          opacity: value,
          child: Transform.scale(
            scale: .965 + .035 * value,
            alignment: Alignment.topLeft,
            child: child,
          ),
        ),
        child: Container(
          key: const Key('node-library-overlay'),
          width: width,
          height: 342,
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
              _SearchField(
                controller: search,
                focusNode: searchFocus,
                onChanged: onSearchChanged,
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 30,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: kAllCategories.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 5),
                  itemBuilder: (context, index) {
                    final cat = kAllCategories[index];
                    final info = kCategoryInfo[cat]!;
                    return ChoiceChip(
                      label: Text(
                        L.t(info.label),
                        style: const TextStyle(fontSize: 10),
                      ),
                      selected: cat == category && query.isEmpty,
                      onSelected: (_) => onSwitchCategory(cat),
                      visualDensity: VisualDensity.compact,
                      showCheckmark: false,
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: items.isEmpty
                    ? Center(
                        child: Text(
                          L.t('无匹配节点'),
                          style: TextStyle(color: t.textFaint),
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.only(bottom: 2),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 220,
                              mainAxisExtent: 58,
                              crossAxisSpacing: 7,
                              mainAxisSpacing: 7,
                            ),
                        itemCount: items.length,
                        itemBuilder: (context, index) => _NodeTile(
                          cfg: items[index],
                          favorite: settings.favoriteNodeIds.contains(
                            items[index].id,
                          ),
                          onFavorite: () {
                            settings.toggleFavoriteNode(items[index].id);
                            onSearchChanged(search.text);
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

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    return TextField(
      key: const Key('node-shelf-search'),
      controller: controller,
      focusNode: focusNode,
      onChanged: onChanged,
      style: TextStyle(fontSize: 12, color: t.text),
      decoration: InputDecoration(
        isDense: true,
        hintText: L.t('搜索名称、说明或节点 ID'),
        prefixIcon: Icon(Icons.search_rounded, size: 17, color: t.textFaint),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close_rounded, size: 16),
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
              ),
        filled: true,
        fillColor: t.bgInput,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(11),
          borderSide: BorderSide(color: t.stroke),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(11),
          borderSide: BorderSide(color: t.stroke),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(11),
          borderSide: BorderSide(color: t.accent, width: 1.4),
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
      duration: MotionTokens.standard(context),
      curve: MotionTokens.enter,
      transform: Matrix4.translationValues(0, _hover ? -1.5 : 0, 0),
      padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
      decoration: BoxDecoration(
        color: _hover ? color.withValues(alpha: 0.11) : t.bgRaise,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _hover ? color.withValues(alpha: 0.42) : t.stroke,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: _hover
                  ? [
                      BoxShadow(
                        color: color.withValues(alpha: .35),
                        blurRadius: 8,
                      ),
                    ]
                  : null,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  L.t(widget.cfg.label),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: t.text,
                  ),
                ),
                Text(
                  widget.cfg.id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 9, color: t.textFaint),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: widget.favorite ? L.t('取消收藏') : L.t('收藏'),
            icon: Icon(
              widget.favorite ? Icons.star_rounded : Icons.star_border_rounded,
              size: 16,
              color: widget.favorite ? color : t.textFaint,
            ),
            onPressed: widget.onFavorite,
            splashRadius: 15,
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
