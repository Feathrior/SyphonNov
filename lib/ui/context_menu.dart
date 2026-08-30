// 新建节点右键菜单(按分类分组;可选 pendingConn 以自动连线)
library;

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';

import '../models/data.dart' hide Column;
import '../models/registry.dart';
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
    return Positioned(
      left: pos.dx,
      top: pos.dy,
      width: widget.width,
      child: widget.child,
    );
  }
}

class NodeMenu extends StatefulWidget {
  final Offset position;
  final void Function(String configId) onPick;
  final VoidCallback onClose;

  const NodeMenu({
    super.key,
    required this.position,
    required this.onPick,
    required this.onClose,
  });

  @override
  State<NodeMenu> createState() => _NodeMenuState();
}

class _NodeMenuState extends State<NodeMenu> {
  final TextEditingController _searchCtrl = TextEditingController();
  Category _hovered = Category.input;
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);

    // 按分类分组节点
    final byCat = <Category, List<NodeConfig>>{};
    for (final cfg in kNodeConfigs) {
      byCat.putIfAbsent(cfg.category, () => []).add(cfg);
    }
    final cats = Category.values.where((c) => byCat.containsKey(c)).toList();

    // 搜索过滤:有搜索词时全局搜索(扁平列表),否则按当前分类展示(双栏)
    final q = _query.trim().toLowerCase();
    final isSearching = q.isNotEmpty;
    final flatItems = isSearching
        ? kNodeConfigs.where((c) {
            return c.label.toLowerCase().contains(q) ||
                c.description.toLowerCase().contains(q);
          }).toList()
        : const <NodeConfig>[];
    final catItems = byCat[_hovered] ?? const <NodeConfig>[];

    // 位置适配交给 ViewportAwareMenu:下方/右侧空间不足时向鼠标左上方翻转
    final mq = MediaQuery.of(context);
    const menuW = 340.0;

    return ViewportAwareMenu(
      mouse: widget.position,
      width: menuW,
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
            _buildTitle(t),
            // 搜索框
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: fluent.TextBox(
                controller: _searchCtrl,
                autofocus: true,
                placeholder: '搜索节点…',
                style: TextStyle(fontSize: 12, color: t.text),
                onChanged: (v) => setState(() => _query = v),
                onSubmitted: (_) {
                  if (flatItems.isNotEmpty) {
                    widget.onPick(flatItems.first.id);
                  }
                },
              ),
            ),
            // 主体:搜索时扁平列表,否则双栏(分类 + 节点)
            if (isSearching)
              _buildSearchResults(t, flatItems)
            else
              _buildCategoryColumns(t, cats, catItems),
            _buildFooter(t),
          ],
        ),
      ),
    );
  }

  /// 标题栏
  Widget _buildTitle(SyphonTheme t) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
      child: Text(
        '新建节点',
        style: TextStyle(
          fontSize: 11,
          color: t.textFaint,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
      ),
    );
  }

  /// 搜索模式:扁平节点列表(或"无匹配"占位)
  Widget _buildSearchResults(SyphonTheme t, List<NodeConfig> flatItems) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 300),
      child: SingleChildScrollView(
        child: flatItems.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  '无匹配节点',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: t.textFaint),
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final cfg in flatItems)
                    _NodeItem(
                      cfg: cfg,
                      showCat: true,
                      onTap: () => widget.onPick(cfg.id),
                    ),
                ],
              ),
      ),
    );
  }

  /// 双栏模式:左侧分类列 + 右侧节点列表
  Widget _buildCategoryColumns(
    SyphonTheme t,
    List<Category> cats,
    List<NodeConfig> catItems,
  ) {
    return SizedBox(
      height: 300,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 分类列(左侧 132px)
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
                  for (final cat in cats)
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
          // 节点列表(右侧)
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

  /// 底部提示
  Widget _buildFooter(SyphonTheme t) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.stroke)),
      ),
      child: Text(
        '单击添加 · Enter 快捷添加',
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
                  info?.label ?? '',
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

/// 节点条目(圆点 + 名称,搜索时附带分类标签)
class _NodeItem extends StatefulWidget {
  final NodeConfig cfg;
  final bool showCat;
  final VoidCallback onTap;

  const _NodeItem({
    required this.cfg,
    required this.onTap,
    this.showCat = false,
  });

  @override
  State<_NodeItem> createState() => _NodeItemState();
}

class _NodeItemState extends State<_NodeItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    final color = _catColor(widget.cfg.category);
    final info = kCategoryInfo[widget.cfg.category];
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            // 同色 alpha=0,避免 transparent(黑 RGB)插值先变黑
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
                  widget.cfg.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: t.text),
                ),
              ),
              if (widget.showCat && info != null)
                Text(
                  info.label,
                  style: TextStyle(fontSize: 10, color: t.textFaint),
                ),
            ],
          ),
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

// ==================== 节点右键菜单(多选后) ====================
// 由画布层在 Shift 多选后右键弹出:分组 / 取消分组 / 复制所选 / 删除所选
// (Blender 风格:多个节点组成一个分组,成员整体拖动)

class NodeContextMenu extends StatelessWidget {
  final Offset position;
  final bool canGroup; // 所选 >= 2 节点时才可分组
  final bool canUngroup; // 所选节点中有成员处于分组内才可取消分组
  final VoidCallback onGroup;
  final VoidCallback onUngroup;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;

  const NodeContextMenu({
    super.key,
    required this.position,
    required this.canGroup,
    required this.canUngroup,
    required this.onGroup,
    required this.onUngroup,
    required this.onDuplicate,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    const menuW = 168.0;
    // 位置适配交给 ViewportAwareMenu:下方/右侧空间不足时向鼠标左上方翻转
    return ViewportAwareMenu(
      mouse: position,
      width: menuW,
      child: Container(
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
        padding: const EdgeInsets.all(6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _CtxMenuItem(
              icon: Icons.group_add_outlined,
              label: '分组',
              enabled: canGroup,
              onTap: onGroup,
            ),
            _CtxMenuItem(
              icon: Icons.group_remove_outlined,
              label: '取消分组',
              enabled: canUngroup,
              onTap: onUngroup,
            ),
            const SizedBox(height: 4),
            Divider(height: 1, thickness: 1, color: t.stroke),
            const SizedBox(height: 4),
            _CtxMenuItem(
              icon: Icons.copy_outlined,
              label: '复制所选',
              onTap: onDuplicate,
            ),
            _CtxMenuItem(
              icon: Icons.delete_outline,
              label: '删除所选',
              danger: true,
              onTap: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== 分组右键菜单 ====================
// 在分组框内部空白处右键弹出:取消分组 / 复制分组
// (重命名分组由"双击分组标签"触发,见 node_canvas.dart)

class GroupContextMenu extends StatelessWidget {
  final Offset position;
  final String groupName;
  final VoidCallback onUngroup; // 取消分组
  final VoidCallback onDuplicate; // 复制分组

  const GroupContextMenu({
    super.key,
    required this.position,
    required this.groupName,
    required this.onUngroup,
    required this.onDuplicate,
  });

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    const menuW = 168.0;
    // 位置适配交给 ViewportAwareMenu:下方/右侧空间不足时向鼠标左上方翻转
    return ViewportAwareMenu(
      mouse: position,
      width: menuW,
      child: Container(
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
        padding: const EdgeInsets.all(6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _CtxMenuItem(
              icon: Icons.group_remove_outlined,
              label: '取消分组',
              onTap: onUngroup,
            ),
            const SizedBox(height: 4),
            Divider(height: 1, thickness: 1, color: t.stroke),
            const SizedBox(height: 4),
            _CtxMenuItem(
              icon: Icons.copy_outlined,
              label: '复制分组',
              onTap: onDuplicate,
            ),
          ],
        ),
      ),
    );
  }
}

/// 右键菜单单项:图标 + 名称,悬停高亮,支持禁用态与危险色
class _CtxMenuItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool enabled;
  final bool danger;
  final VoidCallback onTap;

  const _CtxMenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.enabled = true,
    this.danger = false,
  });

  @override
  State<_CtxMenuItem> createState() => _CtxMenuItemState();
}

class _CtxMenuItemState extends State<_CtxMenuItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    final fg = widget.enabled
        ? (widget.danger ? t.danger : t.text)
        : t.textFaint.withValues(alpha: 0.4);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.enabled ? widget.onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
            // 同色 alpha=0,避免 transparent(黑 RGB)插值先变黑
            color: widget.enabled && _hover
                ? t.bgFloat
                : t.bgFloat.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(SyphonDims.radiusS),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 15, color: fg),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.label,
                  style: TextStyle(fontSize: 12, color: fg),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
