// 顶栏:毛玻璃 + 品牌 + 菜单 + 主题/设置/运行 + 窗口控制
// (由 React 版 Toolbar.tsx 移植;窗口控制配合 window_manager 无边框模式)
//
// ==================== 结构总览(自上而下) ====================
//
//   Toolbar           —— 对外装配:回调字段 + 全部动作方法(保存/加载/预设/关于…)
//   _ToolbarScaffold  —— 毛玻璃容器(BackdropFilter 用户要求保留)
//   _LeftArea         —— 可拖拽移动窗口:品牌 + 菜单栏
//   _RightArea        —— 主题 / 设置 / 运行 + 窗口控制按钮
//
// ==================== 按钮体系 ====================
//
//   图标按钮(主题/设置/运行 + 窗口控制)统一为 _Pressable 交互外壳:
//
//     _Pressable = MouseRegion(悬停) + GestureDetector(按下/抬起/点击)
//     ├── 视觉:builder(hover, pressed) 把两个状态交给按钮上色
//     └── 动作:onTap 在点击完成瞬间触发
//
//   无 InkWell / 波纹 / Timer / 动画容器——状态即时生效:
//   按下无延迟,快速点击不闪烁。按钮类只剩"长什么样"一种职责。
//
//   顶栏文字菜单(文件/编辑/视图/帮助)为 Material MenuBar + SubmenuButton:
//   见文件底部 _AppMenuBar,视觉同样适配 fluent(悬停底色、无波纹)。
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:file_selector/file_selector.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../i18n.dart';
import '../models/presets.dart';
import '../store/graph_store.dart';
import '../store/settings_store.dart';
import 'theme.dart';

// ════════════════════════════════════════════════════════════════════
//  _Pressable:统一交互外壳(全部按钮的唯一交互实现)
// ════════════════════════════════════════════════════════════════════

/// 交互外壳:悬停 + 按下/抬起 + 点击动作。
///
/// - `builder(hover, pressed)`:按两个布尔值给按钮上色;
/// - `onTap`:点击完成的瞬间触发。
class _Pressable extends StatefulWidget {
  final VoidCallback onTap;
  final Widget Function(bool hover, bool pressed) builder;

  const _Pressable({required this.onTap, required this.builder});

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: widget.builder(_hover, _pressed),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  Toolbar:对外装配 + 全部动作
// ════════════════════════════════════════════════════════════════════

class Toolbar extends StatelessWidget {
  final bool boxSelect;
  final ValueChanged<bool> onBoxSelectChanged;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenShortcuts;
  final VoidCallback onFitView;
  final VoidCallback onAutoLayout;
  final VoidCallback onRun;

  const Toolbar({
    super.key,
    required this.boxSelect,
    required this.onBoxSelectChanged,
    required this.onOpenSettings,
    required this.onOpenShortcuts,
    required this.onFitView,
    required this.onAutoLayout,
    required this.onRun,
  });

  @override
  Widget build(BuildContext context) {
    return _ToolbarScaffold(
      child: Row(children: [_leftArea(context), _rightArea(context)]),
    );
  }

  // ---------- 布局:左(品牌+菜单,可拖拽) / 右(图标+窗口控制) ----------

  Widget _leftArea(BuildContext context) {
    return Expanded(
      child: DragToMoveArea(
        child: Row(
          children: [
            const SizedBox(width: 14),
            const _Brand(),
            const SizedBox(width: 10),
            _AppMenuBar(entries: _menuEntries(context)),
          ],
        ),
      ),
    );
  }

  Widget _rightArea(BuildContext context) {
    final t = SyphonTheme.of(context);
    return Row(
      children: [
        // 主题切换:图标随当前主题取反;悬停有轻微旋转动画
        _CircleIconBtn(
          icon: t.isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
          tooltip: t.isDark ? L.t('切换到亮色主题') : L.t('切换到暗色主题'),
          spinOnHover: true,
          onPressed: () => SettingsStore.instance.setTheme(
            t.isDark ? AppTheme.light : AppTheme.dark,
          ),
        ),
        _CircleIconBtn(
          icon: Icons.settings_outlined,
          tooltip: L.t('设置'),
          spinOnHover: true,
          onPressed: onOpenSettings,
        ),
        _CircleIconBtn(
          icon: Icons.play_arrow,
          tooltip: L.t('运行数据流'),
          isRun: true,
          onPressed: onRun,
        ),
        const SizedBox(width: 8),
        const _WindowButtons(),
      ],
    );
  }

  // ---------- 菜单项(Material MenuBar 次级菜单,视觉适配 fluent) ----------

  List<_MenuEntry> _menuEntries(BuildContext context) {
    final t = SyphonTheme.of(context);
    return [
      _MenuEntry(L.t('文件'), _fileMenu(context, t)),
      _MenuEntry(L.t('编辑'), _editMenu(context, t)),
      _MenuEntry(L.t('视图'), _viewMenu(t)),
      _MenuEntry(L.t('帮助'), _helpMenu(context, t)),
    ];
  }

  /// 普通菜单项:图标 + 文字(+ 快捷键)
  MenuItemButton _mItem(
    SyphonTheme t,
    String label, {
    IconData? icon,
    String? shortcut,
    bool danger = false,
    VoidCallback? onTap,
  }) {
    return MenuItemButton(
      onPressed: onTap,
      style: _flyoutItemStyle(t, danger: danger),
      child: Row(
        children: [
          SizedBox(
            width: 20,
            child: icon == null
                ? null
                : Icon(icon, size: 16, color: danger ? t.danger : t.textDim),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                color: danger ? t.danger : t.text,
              ),
            ),
          ),
          if (shortcut != null) Text(shortcut, style: _shortcutStyle(t)),
        ],
      ),
    );
  }

  /// 勾选菜单项(带 ✓,如"框选模式")
  MenuItemButton _mCheck(
    SyphonTheme t,
    String label,
    bool checked,
    VoidCallback onToggle,
  ) {
    return MenuItemButton(
      onPressed: onToggle,
      style: _flyoutItemStyle(t),
      child: Row(
        children: [
          SizedBox(
            width: 20,
            child: checked
                ? Icon(Icons.check, size: 16, color: t.accent)
                : null,
          ),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(fontSize: 12.5, color: t.text)),
        ],
      ),
    );
  }

  /// 菜单分隔线:细线 + 上下留白,贴近 fluent MenuFlyoutSeparator
  Widget _mDivider(SyphonTheme t) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Divider(height: 1, thickness: 1, color: t.stroke),
  );

  /// 文件:保存 / 加载 / 预设列表 / 清空
  List<Widget> _fileMenu(BuildContext context, SyphonTheme t) {
    return [
      _mItem(
        t,
        L.t('保存画布'),
        icon: Icons.save_outlined,
        onTap: () => _saveCanvas(context),
      ),
      _mItem(
        t,
        L.t('加载画布'),
        icon: Icons.folder_open_outlined,
        onTap: () => _loadCanvas(context),
      ),
      _mDivider(t),
      for (final preset in kPresetsReady)
        _mItem(
          t,
          '${L.t('预设')} · ${preset.name}',
          icon: Icons.dashboard_outlined,
          onTap: () => _loadPreset(context, preset),
        ),
      _mDivider(t),
      _mItem(
        t,
        L.t('清空画布'),
        icon: Icons.delete_outline,
        danger: true,
        onTap: () => _clearCanvas(context),
      ),
    ];
  }

  /// 编辑:撤销 / 重做 / 框选模式
  List<Widget> _editMenu(BuildContext context, SyphonTheme t) {
    return [
      _mItem(
        t,
        L.t('撤销'),
        icon: Icons.undo,
        shortcut: 'Ctrl+Z',
        onTap: () => GraphStore.instance.undo(),
      ),
      _mItem(
        t,
        L.t('重做'),
        icon: Icons.redo,
        shortcut: 'Ctrl+Y',
        onTap: () => GraphStore.instance.redo(),
      ),
      const PopupMenuDivider(height: 9),
      _mCheck(t, L.t('框选模式'), boxSelect, () => onBoxSelectChanged(!boxSelect)),
    ];
  }

  /// 视图:适应视图 / 一键整理
  List<Widget> _viewMenu(SyphonTheme t) {
    return [
      _mItem(t, L.t('适应视图'), icon: Icons.fit_screen_outlined, onTap: onFitView),
      _mItem(
        t,
        L.t('一键整理'),
        icon: Icons.grid_view_outlined,
        onTap: onAutoLayout,
      ),
    ];
  }

  /// 帮助:快捷键 / 关于
  List<Widget> _helpMenu(BuildContext context, SyphonTheme t) {
    return [
      _mItem(
        t,
        L.t('快捷键'),
        icon: Icons.keyboard_outlined,
        onTap: onOpenShortcuts,
      ),
      _mDivider(t),
      _mItem(
        t,
        L.t('关于 Syphon'),
        icon: Icons.info_outline,
        onTap: () => _showAbout(context),
      ),
    ];
  }

  /// 菜单项快捷键小字样式
  TextStyle _shortcutStyle(SyphonTheme t) =>
      TextStyle(fontSize: 11, color: t.textFaint);

  // ---------- 文件动作 ----------

  Future<void> _saveCanvas(BuildContext context) async {
    final store = GraphStore.instance;
    if (store.nodes.isEmpty) return;
    final json = store.saveGraph();
    final group = XTypeGroup(
      label: L.t('Syphon 画布'),
      extensions: const ['json'],
    );
    final loc = await getSaveLocation(
      suggestedName: 'syphon-graph.json',
      acceptedTypeGroups: [group],
    );
    if (loc == null) return;
    try {
      await File(loc.path).writeAsString(json);
      store.addLog('ok', '${L.t('已保存画布')}:${loc.path}');
    } catch (e) {
      if (!context.mounted) return;
      _toast(context, '${L.t('保存画布失败')}:$e');
    }
  }

  Future<void> _loadCanvas(BuildContext context) async {
    final store = GraphStore.instance;
    final group = XTypeGroup(
      label: L.t('Syphon 画布'),
      extensions: const ['json'],
    );
    final file = await openFile(acceptedTypeGroups: [group]);
    if (file == null) return;
    String text;
    try {
      text = await File(file.path).readAsString();
    } catch (e) {
      if (!context.mounted) return;
      _toast(context, '${L.t('读取画布失败')}:$e');
      return;
    }
    if (!store.loadGraph(text)) {
      if (!context.mounted) return;
      _toast(context, L.t('画布文件格式无效,无法加载'));
    } else {
      onFitView();
    }
  }

  Future<void> _loadPreset(BuildContext context, Preset p) async {
    final store = GraphStore.instance;
    if (store.nodes.isNotEmpty) {
      final ok = await _confirm(
        context,
        '${L.t('加载预设')}「${p.name}」${L.t('将替换当前画布,确定吗')}',
      );
      if (ok != true) return;
    }
    if (store.loadGraph(p.json)) {
      onFitView();
    } else {
      if (!context.mounted) return;
      _toast(context, L.t('预设加载失败'));
    }
  }

  Future<void> _clearCanvas(BuildContext context) async {
    final store = GraphStore.instance;
    if (store.nodes.isEmpty) return;
    final ok = await _confirm(context, L.t('确定清空画布上的所有节点吗'));
    if (ok == true) store.clearAll();
  }

  // ---------- 弹窗 ----------

  void _showAbout(BuildContext context) {
    fluent.showDialog<void>(
      context: context,
      builder: (ctx) => fluent.ContentDialog(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: Image.asset(
                'assets/images/syphon.png',
                width: 20,
                height: 20,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 8),
            Text('Syphon v0.3.3', style: const TextStyle(fontSize: 15)),
          ],
        ),
        content: Text(
          '${L.t('节点化数据处理工作台')}\n\n${L.t('about_subtitle')}',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          fluent.FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(L.t('确定')),
          ),
        ],
      ),
    );
  }

  Future<bool?> _confirm(BuildContext context, String message) {
    return fluent.showDialog<bool>(
      context: context,
      builder: (ctx) => fluent.ContentDialog(
        content: Text(message, style: const TextStyle(fontSize: 13)),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(L.t('取消')),
          ),
          fluent.FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(L.t('确定')),
          ),
        ],
      ),
    );
  }

  void _toast(BuildContext context, String msg) {
    fluent.displayInfoBar(
      context,
      builder: (context, close) => fluent.InfoBar(
        title: Text(msg, style: const TextStyle(fontSize: 12)),
        severity: fluent.InfoBarSeverity.warning,
        onClose: close,
      ),
      duration: const Duration(seconds: 2),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  毛玻璃容器
// ════════════════════════════════════════════════════════════════════

/// 毛玻璃顶栏(用户要求保留,不可去除):悬浮于画布之上,内容经过时被模糊遮盖。
/// RepaintBoundary 隔离:按钮按下/悬停重绘不牵动下方画布(性能关键)。
class _ToolbarScaffold extends StatelessWidget {
  final Widget child;

  const _ToolbarScaffold({required this.child});

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    return RepaintBoundary(
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            height: SyphonDims.toolbarH,
            decoration: BoxDecoration(
              color: t.bgToolbar.withValues(alpha: 0.72),
              border: Border(bottom: BorderSide(color: t.stroke, width: 1)),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  品牌
// ════════════════════════════════════════════════════════════════════

/// 品牌:syphon.png 图标 + 名称,右边框分隔
class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    return Container(
      padding: const EdgeInsets.only(right: 14),
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: t.stroke, width: 1)),
      ),
      child: Row(
        children: [
          // logo:26x26 圆角 7,带轻阴影
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(7),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 2,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(7),
              child: Image.asset(
                'assets/images/syphon.png',
                width: 26,
                height: 26,
                fit: BoxFit.cover,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'Syphon',
            style: TextStyle(fontSize: 13, color: t.text, letterSpacing: 0.2),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  菜单栏:文字按钮(_Pressable)+ fluent.MenuFlyout 弹出层
// ════════════════════════════════════════════════════════════════════

/// 一个菜单入口(标题 + 菜单项)
class _MenuEntry {
  final String label;
  final List<Widget> items;

  const _MenuEntry(this.label, this.items);
}

// ════════════════════════════════════════════════════════════════════
//  菜单栏:Material MenuBar + 次级菜单(MenuItemButton),视觉适配 fluent
// ════════════════════════════════════════════════════════════════════

/// 顶栏菜单栏:Material MenuBar + SubmenuButton,视觉适配 fluent。
/// 弹层 bgFloat 底 + stroke 边框 + 圆角 6 + 投影;栏内按钮悬停 bgFloat、无波纹;
/// 首次点击展开后可在各菜单间悬停切换(贴近原生 Windows 菜单栏交互)。
/// 应用根是 FluentApp(无 MaterialApp),这里显式提供 Theme 供 Material 组件使用。
class _AppMenuBar extends StatelessWidget {
  final List<_MenuEntry> entries;

  const _AppMenuBar({required this.entries});

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    // 弹层(次级菜单)样式:bgFloat 底 + 细边框 + 圆角 6 + 投影
    final flyoutStyle = MenuStyle(
      backgroundColor: WidgetStatePropertyAll(t.bgFloat),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      elevation: const WidgetStatePropertyAll(6),
      shadowColor: const WidgetStatePropertyAll(Colors.black26),
      side: WidgetStatePropertyAll(BorderSide(color: t.stroke, width: 1)),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(vertical: 4, horizontal: 4),
      ),
    );
    // 栏体本身透明:毛玻璃背景由 _ToolbarScaffold 提供
    final barStyle = MenuStyle(
      backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      elevation: const WidgetStatePropertyAll(0),
      shadowColor: const WidgetStatePropertyAll(Colors.transparent),
      side: const WidgetStatePropertyAll(BorderSide.none),
      padding: const WidgetStatePropertyAll(EdgeInsets.zero),
    );
    return Theme(
      data: ThemeData(
        useMaterial3: true,
        // 顶栏按钮与弹出菜单统一使用微软雅黑(中文渲染更清晰)
        fontFamily: 'Microsoft YaHei',
        colorScheme: ColorScheme.fromSeed(
          seedColor: t.accent,
          brightness: t.isDark ? Brightness.dark : Brightness.light,
        ).copyWith(surface: t.bgFloat),
        menuTheme: MenuThemeData(style: flyoutStyle),
        menuButtonTheme: MenuButtonThemeData(style: _barBtnStyle(t)),
      ),
      child: MenuBar(
        style: barStyle,
        children: [
          for (final e in entries)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: SubmenuButton(
                menuChildren: e.items,
                child: Text(
                  e.label,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.2,
                    color: t.text,
                    letterSpacing: 0.2,
                    // 显式指定常规字重:统一四个按钮为细体(避免 CJK 回退渲染出粗体)
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 菜单栏顶层按钮(MenuBar):圆角 5、紧凑行高、悬停 bgFloat、无波纹
ButtonStyle _barBtnStyle(SyphonTheme t) => ButtonStyle(
  minimumSize: const WidgetStatePropertyAll(Size(0, 32)),
  padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 11)),
  shape: WidgetStatePropertyAll(
    RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
  ),
  backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
  foregroundColor: WidgetStatePropertyAll(t.text),
  overlayColor: WidgetStateProperty.resolveWith((states) {
    if (states.contains(WidgetState.pressed)) {
      return t.strokeStrong.withValues(alpha: 0.4);
    }
    if (states.contains(WidgetState.hovered) ||
        states.contains(WidgetState.focused)) {
      return t.bgFloat.withValues(alpha: 0.9);
    }
    return Colors.transparent;
  }),
  splashFactory: NoSplash.splashFactory,
  elevation: const WidgetStatePropertyAll(0),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

/// 弹层内菜单项:行高 34 + 悬停底色提亮(贴近 fluent MenuFlyoutItem)
ButtonStyle _flyoutItemStyle(SyphonTheme t, {bool danger = false}) =>
    ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(0, 34)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 10),
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
      foregroundColor: WidgetStatePropertyAll(danger ? t.danger : t.text),
      overlayColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.pressed)) {
          return t.strokeStrong.withValues(alpha: 0.6);
        }
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)) {
          return t.lighten(t.bgFloat, t.isDark ? 0.07 : 0.04);
        }
        return Colors.transparent;
      }),
      splashFactory: NoSplash.splashFactory,
      elevation: const WidgetStatePropertyAll(0),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );

// ════════════════════════════════════════════════════════════════════
//  圆形图标按钮:30x30(主题 / 设置 / 运行)
// ════════════════════════════════════════════════════════════════════

class _CircleIconBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool isRun; // 运行按钮:accent 色 + 半透明 accent 背景
  final bool spinOnHover; // 悬停时图标轻微旋转(设置 / 主题切换)

  const _CircleIconBtn({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.isRun = false,
    this.spinOnHover = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    return fluent.Tooltip(
      message: tooltip,
      child: _Pressable(
        onTap: onPressed,
        builder: (hover, pressed) {
          final active = hover || pressed;
          return Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              // 注意:用"同色 alpha=0"而非 transparent——后者 RGB 是黑色,
              // 主题切换时颜色插值会先变黑
              color: isRun
                  ? t.accent.withValues(alpha: hover ? 0.16 : 0.08)
                  : (active ? t.bgFloat : t.bgFloat.withValues(alpha: 0)),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: AnimatedRotation(
              // 悬停时旋转约 30°(1/12 圈),移出后转回
              turns: spinOnHover && hover ? 0.0833 : 0,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              child: Icon(
                icon,
                size: 16,
                color: isRun ? t.accent : (active ? t.text : t.textDim),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  窗口控制:最小化 / 最大化(还原) / 关闭
// ════════════════════════════════════════════════════════════════════

/// 窗口控制按钮组,配合 window_manager 无边框模式接管窗口控制。
class _WindowButtons extends StatefulWidget {
  const _WindowButtons();

  @override
  State<_WindowButtons> createState() => _WindowButtonsState();
}

class _WindowButtonsState extends State<_WindowButtons> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((v) {
      if (mounted && v != _maximized) setState(() => _maximized = v);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => _maximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => _maximized = false);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _WindowBtn(
          icon: fluent.FluentIcons.chrome_minimize,
          onTap: () => windowManager.minimize(),
        ),
        _WindowBtn(
          icon: _maximized
              ? fluent.FluentIcons.chrome_restore
              : fluent.FluentIcons.chrome_full_screen,
          onTap: () => _maximized
              ? windowManager.unmaximize()
              : windowManager.maximize(),
        ),
        _WindowBtn(
          icon: fluent.FluentIcons.chrome_close,
          onTap: () => windowManager.close(),
          close: true,
        ),
      ],
    );
  }
}

/// 单个窗口控制按钮:46 宽,悬停/按下上色;关闭按钮悬停为 Windows 原生红。
class _WindowBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool close;

  const _WindowBtn({
    required this.icon,
    required this.onTap,
    this.close = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    // Windows 原生标题栏关闭色(#E81123,Win10/11 一致),不随主题变化
    const closeRed = Color(0xFFE81123);
    return _Pressable(
      onTap: onTap,
      builder: (hover, pressed) {
        final active = hover || pressed;
        return Container(
          width: 46,
          height: double.infinity,
          color: close
              ? (active ? closeRed : closeRed.withValues(alpha: 0))
              : (active ? t.bgRaise : t.bgRaise.withValues(alpha: 0)),
          alignment: Alignment.center,
          child: fluent.Icon(
            icon,
            size: 12,
            color: close && active ? Colors.white : t.textDim,
          ),
        );
      },
    );
  }
}
