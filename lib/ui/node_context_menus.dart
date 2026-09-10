// 节点/Package 右键菜单 + 菜单单项
// (P3:巨型文件拆分第一步——自 context_menu.dart 拆出;
//  ViewportAwareMenu(视口自适应壳)与 NodeMenu 仍留在原文件)
library;

import 'package:flutter/material.dart';

import '../i18n.dart';
import 'context_menu.dart';
import 'theme.dart';

// ==================== 节点右键菜单(多选后) ====================
// 由画布层在 Shift 多选后右键弹出:Package / 复制所选 / 删除所选

class NodeContextMenu extends StatelessWidget {
  final Offset position;
  final bool canPackage;
  final VoidCallback? onRunNode;
  final VoidCallback onPackage;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;

  const NodeContextMenu({
    super.key,
    required this.position,
    required this.canPackage,
    this.onRunNode,
    required this.onPackage,
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
            if (onRunNode != null) ...[
              CtxMenuItem(
                icon: Icons.play_arrow_outlined,
                label: L.t('运行此节点及下游'),
                onTap: onRunNode!,
              ),
              const SizedBox(height: 4),
              Divider(height: 1, thickness: 1, color: t.stroke),
              const SizedBox(height: 4),
            ],
            CtxMenuItem(
              icon: Icons.inventory_2_outlined,
              label: '打包为 Package',
              enabled: canPackage,
              onTap: onPackage,
            ),
            const SizedBox(height: 4),
            Divider(height: 1, thickness: 1, color: t.stroke),
            const SizedBox(height: 4),
            CtxMenuItem(
              icon: Icons.copy_outlined,
              label: L.t('复制所选'),
              onTap: onDuplicate,
            ),
            CtxMenuItem(
              icon: Icons.delete_outline,
              label: L.t('删除所选'),
              danger: true,
              onTap: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

class PackageContextMenu extends StatelessWidget {
  final Offset position;
  final VoidCallback onSave;
  final VoidCallback onDissolve;

  const PackageContextMenu({
    super.key,
    required this.position,
    required this.onSave,
    required this.onDissolve,
  });

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    return ViewportAwareMenu(
      mouse: position,
      width: 174,
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: t.bgSurface,
          border: Border.all(color: t.strokeStrong),
          borderRadius: BorderRadius.circular(SyphonDims.radiusM),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: .26),
              blurRadius: 22,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CtxMenuItem(
              icon: Icons.save_outlined,
              label: '保存到 Package 库',
              onTap: onSave,
            ),
            CtxMenuItem(
              icon: Icons.inventory_2_outlined,
              label: '解散 Package',
              onTap: onDissolve,
            ),
          ],
        ),
      ),
    );
  }
}

/// 右键菜单单项:图标 + 名称,悬停高亮,支持禁用态与危险色
class CtxMenuItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool enabled;
  final bool danger;
  final VoidCallback onTap;

  const CtxMenuItem({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.enabled = true,
    this.danger = false,
  });

  @override
  State<CtxMenuItem> createState() => _CtxMenuItemState();
}

class _CtxMenuItemState extends State<CtxMenuItem> {
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
