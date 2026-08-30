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
// ==================== 按钮体系:全部统一为 _Pressable ====================
//
//   所有按钮(文字菜单 / 圆形图标 / 窗口控制)共用同一个交互外壳 _Pressable:
//
//     _Pressable = MouseRegion(悬停) + GestureDetector(按下/抬起/点击)
//     ├── 视觉:builder(hover, pressed) 把两个状态交给按钮上色
//     └── 动作:onTap 在点击完成瞬间触发
//
//   无 InkWell / 波纹 / Timer / 动画容器——状态即时生效:
//   按下无延迟,快速点击不闪烁。按钮类只剩"长什么样"一种职责。
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:file_selector/file_selector.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

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
/// - `onTap`:点击完成的瞬间触发;
/// - `onHoverEnter`:鼠标进入时回调(菜单栏用它做"已展开时滑过即切换")。
class _Pressable extends StatefulWidget {
  final VoidCallback onTap;
  final Widget Function(bool hover, bool pressed) builder;
  final VoidCallback? onHoverEnter;

  const _Pressable({
    required this.onTap,
    required this.builder,
    this.onHoverEnter,
  });

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
      onEnter: (_) {
        setState(() => _hover = true);
        widget.onHoverEnter?.call();
      },
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
        // 主题切换:图标随当前主题取反
        _CircleIconBtn(
          icon: t.isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
          tooltip: t.isDark ? '切换到亮色主题' : '切换到暗色主题',
          onPressed: () => SettingsStore.instance.setTheme(
            t.isDark ? AppTheme.light : AppTheme.dark,
          ),
        ),
        _CircleIconBtn(
          icon: Icons.settings_outlined,
          tooltip: '设置',
          onPressed: onOpenSettings,
        ),
        _CircleIconBtn(icon: Icons.play_arrow, tooltip: '运行数据流', isRun: true, onPressed: onRun),
        const SizedBox(width: 8),
        const _WindowButtons(),
      ],
    );
  }

  // ---------- 菜单项(fluent.MenuFlyout) ----------

  List<_MenuEntry> _menuEntries(BuildContext context) {
    final t = SyphonTheme.of(context);
    return [
      _MenuEntry('文件', _fileMenu(context, t)),
      _MenuEntry('编辑', _editMenu(context, t)),
      _MenuEntry('视图', _viewMenu()),
      _MenuEntry('帮助', _helpMenu(context)),
    ];
  }

  /// 文件:保存 / 加载 / 预设列表 / 清空
  List<fluent.MenuFlyoutItemBase> _fileMenu(BuildContext context, SyphonTheme t) {
    return [
      fluent.MenuFlyoutItem(
        text: const Text('保存画布'),
        leading: const Icon(Icons.save_outlined, size: 16),
        onPressed: () => _saveCanvas(context),
      ),
      fluent.MenuFlyoutItem(
        text: const Text('加载画布'),
        leading: const Icon(Icons.folder_open_outlined, size: 16),
        onPressed: () => _loadCanvas(context),
      ),
      const fluent.MenuFlyoutSeparator(),
      for (final preset in kPresetsReady)
        fluent.MenuFlyoutItem(
          text: Text('预设 · ${preset.name}'),
          leading: const Icon(Icons.dashboard_outlined, size: 16),
          onPressed: () => _loadPreset(context, preset),
        ),
      const fluent.MenuFlyoutSeparator(),
      fluent.MenuFlyoutItem(
        text: Text('清空画布', style: TextStyle(color: t.danger)),
        leading: Icon(Icons.delete_outline, size: 16, color: t.danger),
        onPressed: () => _clearCanvas(context),
      ),
    ];
  }

  /// 编辑:撤销 / 重做 / 框选模式
  List<fluent.MenuFlyoutItemBase> _editMenu(BuildContext context, SyphonTheme t) {
    return [
      fluent.MenuFlyoutItem(
        text: const Text('撤销'),
        leading: const Icon(Icons.undo, size: 16),
        trailing: Text('Ctrl+Z', style: _shortcutStyle(t)),
        onPressed: () => GraphStore.instance.undo(),
      ),
      fluent.MenuFlyoutItem(
        text: const Text('重做'),
        leading: const Icon(Icons.redo, size: 16),
        trailing: Text('Ctrl+Y', style: _shortcutStyle(t)),
        onPressed: () => GraphStore.instance.redo(),
      ),
      const fluent.MenuFlyoutSeparator(),
      fluent.ToggleMenuFlyoutItem(
        text: const Text('框选模式'),
        value: boxSelect,
        onChanged: onBoxSelectChanged,
      ),
    ];
  }

  /// 视图:适应视图 / 一键整理
  List<fluent.MenuFlyoutItemBase> _viewMenu() {
    return [
      fluent.MenuFlyoutItem(
        text: const Text('适应视图'),
        leading: const Icon(Icons.fit_screen_outlined, size: 16),
        onPressed: onFitView,
      ),
      fluent.MenuFlyoutItem(
        text: const Text('一键整理'),
        leading: const Icon(Icons.grid_view_outlined, size: 16),
        onPressed: onAutoLayout,
      ),
    ];
  }

  /// 帮助:快捷键 / 关于
  List<fluent.MenuFlyoutItemBase> _helpMenu(BuildContext context) {
    return [
      fluent.MenuFlyoutItem(
        text: const Text('快捷键'),
        leading: const Icon(Icons.keyboard_outlined, size: 16),
        onPressed: onOpenShortcuts,
      ),
      const fluent.MenuFlyoutSeparator(),
      fluent.MenuFlyoutItem(
        text: const Text('关于 Syphon'),
        leading: const Icon(Icons.info_outline, size: 16),
        onPressed: () => _showAbout(context),
      ),
    ];
  }

  /// 菜单项快捷键小字样式
  TextStyle _shortcutStyle(SyphonTheme t) => TextStyle(
    fontSize: 11,
    color: t.textFaint,
    fontFamily: SyphonDims.monoFont,
  );

  // ---------- 文件动作 ----------

  Future<void> _saveCanvas(BuildContext context) async {
    final store = GraphStore.instance;
    if (store.nodes.isEmpty) return;
    final json = store.saveGraph();
    const group = XTypeGroup(label: 'Syphon 画布', extensions: ['json']);
    final loc = await getSaveLocation(
      suggestedName: 'syphon-graph.json',
      acceptedTypeGroups: const [group],
    );
    if (loc == null) return;
    try {
      await File(loc.path).writeAsString(json);
      store.addLog('ok', '已保存画布:${loc.path}');
    } catch (e) {
      if (!context.mounted) return;
      _toast(context, '保存画布失败:$e');
    }
  }

  Future<void> _loadCanvas(BuildContext context) async {
    final store = GraphStore.instance;
    const group = XTypeGroup(label: 'Syphon 画布', extensions: ['json']);
    final file = await openFile(acceptedTypeGroups: const [group]);
    if (file == null) return;
    String text;
    try {
      text = await File(file.path).readAsString();
    } catch (e) {
      if (!context.mounted) return;
      _toast(context, '读取画布失败:$e');
      return;
    }
    if (!store.loadGraph(text)) {
      if (!context.mounted) return;
      _toast(context, '画布文件格式无效,无法加载');
    } else {
      onFitView();
    }
  }

  Future<void> _loadPreset(BuildContext context, Preset p) async {
    final store = GraphStore.instance;
    if (store.nodes.isNotEmpty) {
      final ok = await _confirm(context, '加载预设「${p.name}」将替换当前画布,确定吗?');
      if (ok != true) return;
    }
    if (store.loadGraph(p.json)) {
      onFitView();
    } else {
      if (!context.mounted) return;
      _toast(context, '预设加载失败');
    }
  }

  Future<void> _clearCanvas(BuildContext context) async {
    final store = GraphStore.instance;
    if (store.nodes.isEmpty) return;
    final ok = await _confirm(context, '确定清空画布上的所有节点吗?');
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
            const Text('Syphon v0.2.0', style: TextStyle(fontSize: 15)),
          ],
        ),
        content: const Text(
          '节点化数据处理工作台\n\n数据加载 → 变换 → 可视化,全部可视化连线完成。',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          fluent.FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('确定'),
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
            child: const Text('取消'),
          ),
          fluent.FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
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
  final List<fluent.MenuFlyoutItemBase> items;

  const _MenuEntry(this.label, this.items);
}

// ---------- 信号总线:按钮按下/悬停 → 菜单呼出 ----------

/// 菜单信号总线:按钮侧只管"发送",菜单栏侧只管"接收",两侧互不持有引用。
///
/// - 按下信号(press):点击按钮 → 呼出/关闭对应菜单
/// - 悬停信号(hover):已有菜单展开时滑过按钮 → 切换到它
///
/// 用 broadcast Stream 而非直接回调:事件先进队列、同一微任务批次内依次消费,
/// 避免按钮的视觉 setState 与菜单栏的 setState 挤在同一帧内竞争渲染。
class _MenuSignal {
  final _press = StreamController<int>.broadcast();
  final _hover = StreamController<int>.broadcast();

  /// 发送:按钮被点击(索引)
  void sendPress(int index) => _press.add(index);

  /// 发送:鼠标滑入按钮(索引)
  void sendHover(int index) => _hover.add(index);

  /// 接收:点击信号流
  Stream<int> get press => _press.stream;

  /// 接收:悬停信号流
  Stream<int> get hover => _hover.stream;

  void dispose() {
    _press.close();
    _hover.close();
  }
}

/// 菜单栏:订阅按钮信号并呼出 MenuFlyout(与 Win11 原生菜单栏行为一致)。
class _AppMenuBar extends StatefulWidget {
  final List<_MenuEntry> entries;

  const _AppMenuBar({required this.entries});

  @override
  State<_AppMenuBar> createState() => _AppMenuBarState();
}

class _AppMenuBarState extends State<_AppMenuBar> {
  late final _MenuSignal _signal = _MenuSignal();
  late final List<fluent.FlyoutController> _controllers =
      List.generate(widget.entries.length, (_) => fluent.FlyoutController());
  late final List<StreamSubscription<int>> _signalSubs;
  int? _openIndex;

  @override
  void initState() {
    super.initState();
    // 订阅信号:按下 → 呼出菜单;悬停 → 展开状态下切换
    _signalSubs = [
      _signal.press.listen(_onPressed),
      _signal.hover.listen(_onHovered),
    ];
  }

  @override
  void dispose() {
    for (final s in _signalSubs) {
      s.cancel();
    }
    _signal.dispose();
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  /// 接收「按下」信号:呼出第 index 个菜单;重复点击同一按钮由 barrier 关闭。
  void _onPressed(int index) {
    if (_openIndex != null && _openIndex != index) {
      _controllers[_openIndex!].close();
    }
    _show(index);
  }

  /// 接收「悬停」信号:已有菜单展开时,滑到其他按钮上即切换到它。
  void _onHovered(int index) {
    if (_openIndex == null || _openIndex == index) return;
    _show(index);
  }

  Future<void> _show(int index) async {
    if (mounted) setState(() => _openIndex = index);
    await _controllers[index].showFlyout(
      barrierColor: Colors.transparent, // 菜单语义:点击外部即关,不遮暗界面
      placementMode: fluent.FlyoutPlacementMode.bottomCenter,
      additionalOffset: 0,
      transitionDuration: Duration.zero, // 松开即显示,无淡入等待
      builder: (ctx) => fluent.MenuFlyout(items: widget.entries[index].items),
    );
    // 关闭后复位;若因悬停切换已指向新菜单,则不覆盖
    if (mounted && _openIndex == index) {
      setState(() => _openIndex = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 2,
      children: [
        for (var i = 0; i < widget.entries.length; i++)
          fluent.FlyoutTarget(
            controller: _controllers[i],
            child: _MenuBtn(
              label: widget.entries[i].label,
              index: i,
              signal: _signal,
              open: _openIndex == i,
            ),
          ),
      ],
    );
  }
}

/// 菜单文字按钮:只发送信号,不关心菜单如何呼出。
/// Win11 风格外观——圆角 5,悬停/展开 bgFloat,按下 strokeStrong。
class _MenuBtn extends StatelessWidget {
  final String label;
  final int index;
  final _MenuSignal signal;
  final bool open;

  const _MenuBtn({
    required this.label,
    required this.index,
    required this.signal,
    required this.open,
  });

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    return _Pressable(
      onTap: () => signal.sendPress(index), // 按下信号 → 菜单栏接收后呼出
      onHoverEnter: () => signal.sendHover(index), // 悬停信号 → 展开状态下切换
      builder: (hover, pressed) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: pressed
              ? t.strokeStrong
              : (open || hover ? t.bgFloat : t.bgFloat.withValues(alpha: 0)),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            height: 1.2,
            color: t.text,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  圆形图标按钮:30x30(主题 / 设置 / 运行)
// ════════════════════════════════════════════════════════════════════

class _CircleIconBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool isRun; // 运行按钮:accent 色 + 半透明 accent 背景

  const _CircleIconBtn({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.isRun = false,
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
            child: Icon(
              icon,
              size: 16,
              color: isRun ? t.accent : (active ? t.text : t.textDim),
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

  const _WindowBtn({required this.icon, required this.onTap, this.close = false});

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
