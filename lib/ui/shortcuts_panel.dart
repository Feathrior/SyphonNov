// 快捷键面板:列出全部快捷键分组(由 React 版 ShortcutsPanel.tsx 移植)
library;

import 'package:flutter/material.dart';

import 'theme.dart';

const List<({String title, List<({String keys, String desc})> items})> _kShortcutGroups = [
  (
    title: '编辑',
    items: [
      (keys: 'Ctrl+Z', desc: '撤销'),
      (keys: 'Ctrl+Y / Ctrl+Shift+Z', desc: '重做'),
      (keys: 'Delete / Backspace', desc: '删除选中的节点 / 连线 / 分割点'),
      (keys: 'Escape', desc: '关闭菜单、设置或快捷键面板'),
    ],
  ),
  (
    title: '画布',
    items: [
      (keys: 'Ctrl+滚轮', desc: '任意位置缩放画布'),
      (keys: 'Ctrl+按住左键划过连线', desc: '切断连线'),
      (keys: 'Shift+拖拽节点到连线上', desc: '把节点插入连线中间(拆分连线)'),
      (keys: '右键空白处', desc: '打开"新建节点"菜单'),
      (keys: '右键节点', desc: '折叠 / 展开节点'),
    ],
  ),
  (
    title: '曲线整理',
    items: [
      (keys: 'Alt+悬停曲线', desc: '预览拆分点位置'),
      (keys: 'Alt+点击曲线', desc: '插入分割点(小圆点),曲线外观分为两段'),
      (keys: '点击小圆点', desc: '单独选中分割点(显示高亮光环)'),
      (keys: 'Delete', desc: '删除选中的分割点,曲线恢复原始形状'),
      (keys: '拖拽小圆点', desc: '调整曲线外观'),
    ],
  ),
];

class ShortcutsPanel extends StatefulWidget {
  final VoidCallback onClose;

  const ShortcutsPanel({super.key, required this.onClose});

  @override
  State<ShortcutsPanel> createState() => _ShortcutsPanelState();
}

class _ShortcutsPanelState extends State<ShortcutsPanel> {
  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    // fluent.showDialog 不自动居中,这里用 Center + Padding 模拟原 Dialog 的居中/inset
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 70),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height - 140,
            ),
            decoration: BoxDecoration(
              color: t.bgSurface,
              border: Border.all(color: t.strokeStrong),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35), blurRadius: 40),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(t),
                Divider(height: 1, thickness: 1, color: t.stroke),
                // 主体:可滚动的快捷键列表
                _buildShortcutList(context, t),
                Divider(height: 1, thickness: 1, color: t.stroke),
                _buildFooter(t),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 头部:标题 + 关闭按钮
  Widget _buildHeader(SyphonTheme t) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 10, 14),
      child: Row(
        children: [
          Text('快捷键',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: t.text)),
          const Spacer(),
          _CloseButton(onPressed: widget.onClose),
        ],
      ),
    );
  }

  /// 快捷键列表:按分组渲染,每组含标题 + 若干 按键+说明 行
  Widget _buildShortcutList(BuildContext context, SyphonTheme t) {
    return Flexible(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height - 240,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final g in _kShortcutGroups) ...[
                _groupTitle(t, g.title),
                const SizedBox(height: 4),
                for (final it in g.items) _shortcutRow(t, it),
                const SizedBox(height: 16),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // .nf-shortcut-group:fontSize 11、w600、letterSpacing 0.8、textFaint
  Widget _groupTitle(SyphonTheme t, String title) {
    return Text(title,
        style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
            color: t.textFaint));
  }

  // .nf-shortcut-row:下边框分隔、按键 + 说明
  Widget _shortcutRow(SyphonTheme t, ({String keys, String desc}) it) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.stroke)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Kbd(text: it.keys),
          const SizedBox(width: 12),
          Expanded(
            child: Text(it.desc,
                style: TextStyle(fontSize: 12, color: t.textDim)),
          ),
        ],
      ),
    );
  }

  /// 底部:版本号 + 完成按钮
  Widget _buildFooter(SyphonTheme t) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
      child: Row(
        children: [
          Text('Syphon v0.2.0',
              style: TextStyle(fontSize: 11, color: t.textFaint)),
          const Spacer(),
          _PrimaryButton(
            label: '完成',
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }
}

/// 键盘按键标签(bgRaise 背景,底部加粗边框模拟立体按键)
class _Kbd extends StatelessWidget {
  final String text;
  const _Kbd({required this.text});

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: t.bgRaise,
        borderRadius: BorderRadius.circular(SyphonDims.radiusS),
        border: Border(
          top: BorderSide(color: t.strokeStrong),
          left: BorderSide(color: t.strokeStrong),
          right: BorderSide(color: t.strokeStrong),
          bottom: BorderSide(color: t.strokeStrong, width: 2),
        ),
      ),
      child: Text(text, style: TextStyle(fontSize: 11, color: t.textDim)),
    );
  }
}

/// 关闭按钮(28px 圆形)
class _CloseButton extends StatefulWidget {
  final VoidCallback onPressed;
  const _CloseButton({required this.onPressed});

  @override
  State<_CloseButton> createState() => _CloseButtonState();
}

class _CloseButtonState extends State<_CloseButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          width: 28,
          height: 28,
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            // 同色 alpha=0,避免 transparent(黑 RGB)插值先变黑
            color: _hover ? t.bgFloat : t.bgFloat.withValues(alpha: 0),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Text('✕', style: TextStyle(fontSize: 13, color: t.textDim)),
        ),
      ),
    );
  }
}

/// 主按钮(accent 背景)
class _PrimaryButton extends StatefulWidget {
  final String label;
  final VoidCallback onPressed;
  const _PrimaryButton({required this.label, required this.onPressed});

  @override
  State<_PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<_PrimaryButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 7),
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: _hover ? t.accentHover : t.accent,
            borderRadius: BorderRadius.circular(SyphonDims.radiusS),
            border: Border.all(color: t.accent),
          ),
          child: Text(widget.label,
              style: TextStyle(
                  fontSize: 12, color: t.onAccent, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}
