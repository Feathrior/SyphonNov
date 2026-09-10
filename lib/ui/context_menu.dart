// 新建节点右键菜单(按分类分组;可选 pendingConn 以自动连线)
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;

import '../i18n.dart';
import '../models/data.dart' hide Column;
import '../models/registry.dart';
import 'motion.dart';
import 'theme.dart';

/// 视口自适应浮动菜单壳:优先从鼠标右下方弹出;
/// 右侧/下方空间不足时翻转到鼠标左上方,避免菜单被窗口边缘截断。
/// 首帧先在屏幕外布局测量实际尺寸,次帧落位(无可见闪烁)。
class ViewportAwareMenu extends StatefulWidget {
  final Offset mouse; // 鼠标位置(与承载 Stack 同坐标系)
  final double width; // 菜单固定宽度
  final Widget child;

  const ViewportAwareMenu({
    super.key,
    required this.mouse,
    required this.width,
    required this.child,
  });

  @override
  State<ViewportAwareMenu> createState() => _ViewportAwareMenuState();
}

class _ViewportAwareMenuState extends State<ViewportAwareMenu> {
  // 测量完成前先放到屏幕外,避免在错误位置闪现一帧
  static const _offscreen = Offset(-100000, -100000);
  // 菜单与光标/视口边缘的间距
  static const _gap = 4.0;
  static const _margin = 8.0;

  Offset? _pos;

  @override
  void initState() {
    super.initState();
    _scheduleMeasure();
  }

  @override
  void didUpdateWidget(covariant ViewportAwareMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 内容变化(如搜索增删条目)导致尺寸变化时重新适配位置
    if (oldWidget.child != widget.child) _scheduleMeasure();
  }

  void _scheduleMeasure() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  void _measure() {
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    // 视口 = 最近的 RenderBox 祖先(菜单层 Stack,与 mouse 同坐标系覆盖整个画布)
    final viewportBox = context.findAncestorRenderObjectOfType<RenderBox>();
    final viewport = viewportBox?.size ?? MediaQuery.sizeOf(context);
    setState(() => _pos = _fit(viewport, box.size, widget.mouse));
  }

  /// 优先从鼠标右下方弹出;右侧/下方空间不足时翻转到鼠标左上方;
  /// 最后夹回视口内兜底(极端小窗口也不越界)
  static Offset _fit(Size viewport, Size menu, Offset mouse) {
    double dx = mouse.dx + _gap;
    double dy = mouse.dy + _gap;
    if (dx + menu.width > viewport.width - _margin) {
      dx = mouse.dx - menu.width - _gap;
    }
    if (dy + menu.height > viewport.height - _margin) {
      dy = mouse.dy - menu.height - _gap;
    }
    final maxX = (viewport.width - menu.width - _margin)
        .clamp(_margin, viewport.width)
        .toDouble();
    final maxY = (viewport.height - menu.height - _margin)
        .clamp(_margin, viewport.height)
        .toDouble();
    return Offset(
      dx.clamp(_margin, maxX).toDouble(),
      dy.clamp(_margin, maxY).toDouble(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pos = _pos ?? _offscreen;
    final animation = PopupMotionScope.maybeOf(context);
    final content = animation == null
        ? widget.child
        : BlurScaleTransition(
            animation: animation,
            alignment: Alignment.topLeft,
            child: widget.child,
          );
    return Positioned(
      left: pos.dx,
      top: pos.dy,
      width: widget.width,
      child: content,
    );
  }
}

class NodeMenu extends StatefulWidget {
  final Offset position;
  final void Function(String configId) onPick;
  final VoidCallback onClose;
  final Widget? bottomSlot; // 可选底部扩展区（例如 Package 库）

  const NodeMenu({
    super.key,
    required this.position,
    required this.onPick,
    required this.onClose,
    this.bottomSlot,
  });

  @override
  State<NodeMenu> createState() => _NodeMenuState();
}

class _NodeMenuState extends State<NodeMenu> {
  Category _hovered = Category.input;

  // 搜索框状态:过滤支持中文(label 键名/当前语言显示名)与英文(id)
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchFocus.addListener(() {
      // 聚焦态变化时重绘底部强调线(Fluent TextBox 焦点样式)
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// 全量配置一次构建,供分类视图复用
  late final List<NodeConfig> _allConfigs = List.unmodifiable(kNodeConfigs);

  /// 按分类分组
  late final Map<Category, List<NodeConfig>> _byCat = () {
    final m = <Category, List<NodeConfig>>{};
    for (final cfg in _allConfigs) {
      m.putIfAbsent(cfg.category, () => []).add(cfg);
    }
    const inputOrder = {
      'scatter_input': 0,
      'func_curve': 1,
      'surface_input': 2,
    };
    m[Category.input]?.sort((a, b) {
      final pa = inputOrder[a.id] ?? 100;
      final pb = inputOrder[b.id] ?? 100;
      return pa != pb ? pa.compareTo(pb) : 0;
    });
    return m;
  }();
  late final List<Category> _cats = Category.values
      .where((c) => _byCat.containsKey(c))
      .toList();

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);

    final q = _query.trim();
    final searching = q.isNotEmpty;
    final results = searching
        ? _allConfigs.where((c) => _matches(c, q)).toList(growable: false)
        : const <NodeConfig>[];

    final catItems = _byCat[_hovered] ?? const <NodeConfig>[];

    final mq = MediaQuery.of(context);
    const menuW = 340.0;

    return ViewportAwareMenu(
      mouse: widget.position,
      width: menuW,
      // 透明 Material:为搜索框 TextField 提供 Material 祖先(菜单本身自绘背景)
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          constraints: BoxConstraints(maxHeight: mq.size.height - 80),
          decoration: BoxDecoration(
            color: t.bgSurface,
            border: Border.all(color: t.strokeStrong),
            borderRadius: BorderRadius.circular(SyphonDims.radiusM),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 24,
              ),
            ],
          ),
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildSearchBox(t),
              const SizedBox(height: 6),
              if (!searching) ...[
                _buildTitle(t),
                _buildCategoryColumns(t, catItems),
              ] else ...[
                _buildSearchResults(t, results),
              ],
              _buildFooter(t),
              if (widget.bottomSlot != null) ...[
                const SizedBox(height: 6),
                Divider(height: 1, thickness: 1, color: t.stroke),
                const SizedBox(height: 2),
                widget.bottomSlot!,
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 中英文匹配:中文搜 label 键名/当前语言显示名,英文搜 id(下划线按空格处理)
  static bool _matches(NodeConfig cfg, String q) {
    final lower = q.toLowerCase();
    return cfg.label.toLowerCase().contains(lower) ||
        L.t(cfg.label).toLowerCase().contains(lower) ||
        cfg.id.replaceAll('_', ' ').toLowerCase().contains(lower);
  }

  /// Fluent 风格搜索框(AutoSuggestBox):圆角 4、聚焦时底部 2px 强调线;
  /// Esc 清空/关闭,Enter 选中首个结果
  Widget _buildSearchBox(SyphonTheme t) {
    final focused = _searchFocus.hasFocus;
    return CallbackShortcuts(
      bindings: {
        SingleActivator(LogicalKeyboardKey.escape): () {
          if (_query.isNotEmpty) {
            _searchCtrl.clear();
            setState(() => _query = '');
          } else {
            widget.onClose();
          }
        },
      },
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            height: 32,
            decoration: BoxDecoration(
              color: t.bgInput,
              borderRadius: BorderRadius.circular(SyphonDims.radiusS),
              border: Border.all(
                color: focused
                    ? t.accent.withValues(alpha: 0.5)
                    : t.strokeStrong,
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Icon(Icons.search, size: 14, color: t.textFaint),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    focusNode: _searchFocus,
                    autofocus: true,
                    style: TextStyle(fontSize: 12, color: t.text),
                    cursorColor: t.accent,
                    onChanged: (v) => setState(() => _query = v),
                    onSubmitted: (_) => _pickFirst(),
                    decoration: InputDecoration(
                      hintText: L.t('搜索节点…'),
                      hintStyle: TextStyle(fontSize: 12, color: t.textFaint),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 9),
                    ),
                  ),
                ),
                if (_query.isNotEmpty)
                  _ClearButton(
                    onTap: () {
                      _searchCtrl.clear();
                      setState(() => _query = '');
                    },
                  ),
              ],
            ),
          ),
          // Fluent TextBox 焦点样式:底部 2px 强调线
          if (focused)
            Positioned(
              left: 4,
              right: 4,
              bottom: 0,
              child: Container(
                height: 2,
                decoration: BoxDecoration(
                  color: t.accent,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Enter 选中首个搜索结果
  void _pickFirst() {
    final q = _query.trim();
    if (q.isEmpty) return;
    final results = _allConfigs
        .where((c) => _matches(c, q))
        .toList(growable: false);
    if (results.isNotEmpty) widget.onPick(results.first.id);
  }

  /// 搜索结果视图:跨分类扁平列表,与分类双栏同高保持菜单尺寸稳定
  Widget _buildSearchResults(SyphonTheme t, List<NodeConfig> results) {
    return SizedBox(
      height: 300,
      child: results.isEmpty
          ? Center(
              child: Text(
                L.t('无匹配节点'),
                style: TextStyle(fontSize: 11, color: t.textFaint),
              ),
            )
          : SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final cfg in results)
                    _NodeItem(cfg: cfg, onTap: () => widget.onPick(cfg.id)),
                ],
              ),
            ),
    );
  }

  Widget _buildCategoryColumns(SyphonTheme t, List<NodeConfig> catItems) {
    return SizedBox(
      height: 300,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: 132,
            padding: const EdgeInsets.only(right: 4),
            decoration: BoxDecoration(
              border: Border(right: BorderSide(color: t.stroke)),
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final cat in _cats)
                    _CatItem(
                      cat: cat,
                      active: cat == _hovered,
                      onTap: () => setState(() => _hovered = cat),
                      onHover: () => setState(() => _hovered = cat),
                    ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 4),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final cfg in catItems)
                      _NodeItem(cfg: cfg, onTap: () => widget.onPick(cfg.id)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTitle(SyphonTheme t) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
      child: Text(
        L.t('新建节点'),
        style: TextStyle(
          fontSize: 11,
          color: t.textFaint,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
      ),
    );
  }

  Widget _buildFooter(SyphonTheme t) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.stroke)),
      ),
      child: Text(
        L.t('单击添加'),
        textAlign: TextAlign.right,
        style: TextStyle(fontSize: 10, color: t.textFaint),
      ),
    );
  }
}

/// 分类条目(左侧栏:图标 + 名称,悬停切换分类)
class _CatItem extends StatefulWidget {
  final Category cat;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onHover;

  const _CatItem({
    required this.cat,
    required this.active,
    required this.onTap,
    required this.onHover,
  });

  @override
  State<_CatItem> createState() => _CatItemState();
}

class _CatItemState extends State<_CatItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    final info = kCategoryInfo[widget.cat];
    final color = _catColor(widget.cat);
    return MouseRegion(
      onEnter: (_) {
        setState(() => _hover = true);
        widget.onHover();
      },
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: widget.active
                ? t.accent.withValues(alpha: 0.12)
                // 同色 alpha=0,避免 transparent(黑 RGB)插值先变黑
                : (_hover ? t.bgFloat : t.bgFloat.withValues(alpha: 0)),
            borderRadius: BorderRadius.circular(SyphonDims.radiusS),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 14,
                child: Text(
                  info?.icon ?? '',
                  style: TextStyle(fontSize: 12, color: color),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  L.t(info?.label ?? ''),
                  style: TextStyle(fontSize: 12, color: t.text),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 节点条目(圆点 + 名称)
class _NodeItem extends StatefulWidget {
  final NodeConfig cfg;
  final VoidCallback onTap;

  const _NodeItem({required this.cfg, required this.onTap});

  @override
  State<_NodeItem> createState() => _NodeItemState();
}

class _NodeItemState extends State<_NodeItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    final color = _catColor(widget.cfg.category);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
            color: _hover ? t.bgFloat : t.bgFloat.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(SyphonDims.radiusS),
          ),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  L.t(widget.cfg.label),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: t.text),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 搜索框清除按钮:小号关闭图标,悬停高亮
class _ClearButton extends StatefulWidget {
  final VoidCallback onTap;

  const _ClearButton({required this.onTap});

  @override
  State<_ClearButton> createState() => _ClearButtonState();
}

class _ClearButtonState extends State<_ClearButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            // 同色 alpha=0,避免 transparent(黑 RGB)插值先变黑
            color: _hover ? t.bgFloat : t.bgFloat.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(SyphonDims.radiusS),
          ),
          child: Icon(Icons.close, size: 13, color: t.textDim),
        ),
      ),
    );
  }
}

/// 解析分类颜色(十六进制字符串 → Color)
Color _catColor(Category c) {
  final info = kCategoryInfo[c];
  if (info == null) return const Color(0xFF7C8DB5);
  return Color(
    int.tryParse(info.color.replaceFirst('#', '0xFF')) ?? 0xFF7C8DB5,
  );
}
