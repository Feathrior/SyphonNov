// Syphon Flutter 桌面版:节点化科研数据处理工作台(由 React 版 App.tsx 移植)
library;

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../models/csv.dart';
import 'store/graph_store.dart';
import 'store/settings_store.dart';
import 'ui/inspector.dart';
import 'ui/node_canvas.dart';
import 'ui/properties_panel.dart';
import 'ui/settings_panel.dart';
import 'ui/shortcuts_panel.dart';
import 'ui/status_bar.dart';
import 'ui/theme.dart';
import 'ui/toolbar.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 无边框窗口:隐藏原生标题栏,由应用内工具栏窗口按钮接管窗口控制
  await windowManager.ensureInitialized();
  const opts = WindowOptions(
    size: Size(1440, 900),
    minimumSize: Size(960, 600),
    center: true,
    title: 'Syphon',
    titleBarStyle: TitleBarStyle.hidden,
  );
  windowManager.waitUntilReadyToShow(opts, () async {
    await windowManager.show();
    await windowManager.focus();
  });
  await SettingsStore.instance.init();
  GraphStore.instance.autoRun = SettingsStore.instance.autoRun;
  runApp(const SyphonApp());
}

class SyphonApp extends StatelessWidget {
  const SyphonApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = SettingsStore.instance;
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) {
        final dark = settings.theme == AppTheme.dark;
        final accent =
            (dark
                    ? SyphonTheme.darkTheme.accent
                    : SyphonTheme.lightTheme.accent)
                .toAccentColor();
        final dim = dark
            ? SyphonTheme.darkTheme.textFaint
            : SyphonTheme.lightTheme.textFaint;
        final bgApp = dark
            ? SyphonTheme.darkTheme.bgApp
            : SyphonTheme.lightTheme.bgApp;
        final bgSurface = dark
            ? SyphonTheme.darkTheme.bgSurface
            : SyphonTheme.lightTheme.bgSurface;
        return fluent.FluentApp(
          title: 'Syphon',
          debugShowCheckedModeBanner: false,
          theme: fluent.FluentThemeData(
            brightness: Brightness.light,
            accentColor: accent,
            inactiveColor: dim,
            // 全局默认字体:微软雅黑(全部文字内容统一渲染)
            fontFamily: 'Microsoft YaHei',
            scaffoldBackgroundColor: bgApp,
            cardColor: bgSurface,
            // 细腻过渡动画:菜单/弹窗/ComboBox/InfoBar 等 fluent 控件的动画时长。
            // 层级 faster < fast < medium < slow;fast 90ms——MenuBar 点击到
            // 弹出次级菜单的主要延迟就是它(叠加 easeIn 淡入起始慢),提速后接近原生
            fasterAnimationDuration: const Duration(milliseconds: 60),
            fastAnimationDuration: const Duration(milliseconds: 90),
            mediumAnimationDuration: const Duration(milliseconds: 180),
            slowAnimationDuration: const Duration(milliseconds: 358),
          ),
          darkTheme: fluent.FluentThemeData(
            brightness: Brightness.dark,
            accentColor: accent,
            inactiveColor: dim,
            fontFamily: 'Microsoft YaHei',
            scaffoldBackgroundColor: bgApp,
            cardColor: bgSurface,
            fasterAnimationDuration: const Duration(milliseconds: 60),
            fastAnimationDuration: const Duration(milliseconds: 90),
            mediumAnimationDuration: const Duration(milliseconds: 180),
            slowAnimationDuration: const Duration(milliseconds: 358),
          ),
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          // 普通 Text 继承微软雅黑(merge 保留各组件自带的字号/颜色)
          home: DefaultTextStyle.merge(
            style: const TextStyle(fontFamily: 'Microsoft YaHei'),
            child: const _AppShell(),
          ),
        );
      },
    );
  }
}

class _AppShell extends StatefulWidget {
  const _AppShell();

  @override
  State<_AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<_AppShell> {
  final GlobalKey<NodeCanvasState> _canvasKey = GlobalKey();
  // 最外层 Focus:让快捷键在应用任意位置(画布失焦时)都能被捕获
  final FocusNode _shellFocus = FocusNode();
  bool _boxSelect = false;

  // 外部文件拖拽(Win32 WM_DROPFILES → 平台通道 → 这里)→ 在放点生成表格输入节点
  static const _fileDropChannel = MethodChannel('syphon/file_drop');

  void _fitView() => _canvasKey.currentState?.fitView();

  @override
  void initState() {
    super.initState();
    _fileDropChannel.setMethodCallHandler(_onFileDrop);
  }

  @override
  void dispose() {
    _fileDropChannel.setMethodCallHandler(null);
    _shellFocus.dispose();
    super.dispose();
  }

  Future<void> _onFileDrop(MethodCall call) async {
    if (call.method != 'drop') return;
    final args = call.arguments;
    if (args is! Map) return;
    final paths =
        (args['paths'] as List?)?.whereType<String>().toList() ?? const [];
    if (paths.isEmpty) return;
    // 客户区坐标由 Win32 以物理像素给出,按 DPR 换算为 Flutter 逻辑像素
    final views = WidgetsBinding.instance.platformDispatcher.views;
    final dpr = views.isEmpty ? 1.0 : views.first.devicePixelRatio;
    final pos = Offset(
      ((args['x'] as num?)?.toDouble() ?? 0) / dpr,
      ((args['y'] as num?)?.toDouble() ?? 0) / dpr,
    );
    // 取第一个受支持的数据文件;全部不识别也尝试读取第一个
    const exts = {'.csv', '.tsv', '.txt', '.xlsx', '.xls'};
    final path = paths.firstWhere(
      (p) => exts.any((e) => p.toLowerCase().endsWith(e)),
      orElse: () => paths.first,
    );
    try {
      final text = await dataFileToCsvText(path);
      _canvasKey.currentState?.dropFileText(pos, text);
    } catch (e) {
      GraphStore.instance.addLog('error', '导入文件失败:$e');
    }
  }

  /// 当前焦点是否位于文本输入框(EditableText)内
  bool _editing() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  /// 全局级快捷键(输入框聚焦时也优先响应的组合键)
  bool _isGlobalShortcut(KeyEvent event) {
    final ctrl =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (!ctrl) return false;
    final k = event.logicalKey;
    return k == LogicalKeyboardKey.keyZ || k == LogicalKeyboardKey.keyY;
  }

  /// 全局键盘快捷键(对应 React 版 App.tsx 的 keydown 监听):
  /// Ctrl+Z 撤销、Ctrl+Shift+Z / Ctrl+Y 重做、Escape 取消选中、Delete/Backspace 删除
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    // 输入框聚焦时:普通编辑键交还给输入框自身处理(文本内 Ctrl+Z/Delete 等),
    // 但 Ctrl+Z/Ctrl+Y 属于全局撤销/重做——即使焦点在参数输入框内也优先
    // 撤销画布/参数操作(修复"改完参数后 Ctrl+Z 无反应")
    if (_editing() && !_isGlobalShortcut(event)) {
      return KeyEventResult.ignored;
    }

    final ctrl =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;

    // Ctrl+Z 撤销;Ctrl+Shift+Z 重做
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyZ) {
      if (shift) {
        GraphStore.instance.redo();
      } else {
        GraphStore.instance.undo();
      }
      return KeyEventResult.handled;
    }
    // Ctrl+Y 重做
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyY) {
      GraphStore.instance.redo();
      return KeyEventResult.handled;
    }

    // Escape:取消选中(画布右键菜单/分割点编辑由 NodeCanvas 自身的 Focus 处理)
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      GraphStore.instance.selectNode(null);
      GraphStore.instance.selectSplitEdge(null);
      return KeyEventResult.handled;
    }

    // Delete/Backspace:删除选中节点(或分割点)
    if (event.logicalKey == LogicalKeyboardKey.delete ||
        event.logicalKey == LogicalKeyboardKey.backspace) {
      _canvasKey.currentState?.deleteSelection();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    // 最外层 Focus 并 autofocus:全局捕获快捷键,与 NodeCanvas 自身的
    // Focus(space/delete/escape)不冲突——按键自焦点节点向上冒泡,
    // NodeCanvas 处理过的事件不会到达此处,未处理的(Ctrl+Z/Y 等)在此兜底。
    return Focus(
      focusNode: _shellFocus,
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: Container(
        color: t.bgApp,
        child: Stack(
          children: [
            // 内容层:画布/属性面板 + 检查器 + 状态栏,填满整个窗口
            // RepaintBoundary 隔离:任一面板重绘不牵动其他层/工具栏(性能关键)
            RepaintBoundary(
              child: Column(
                children: [
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: RepaintBoundary(
                            child: NodeCanvas(
                              key: _canvasKey,
                              boxSelect: _boxSelect,
                            ),
                          ),
                        ),
                        const SizedBox(
                          width: SyphonDims.propsW,
                          child: RepaintBoundary(child: PropertiesPanel()),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(
                    height: SyphonDims.inspectorH,
                    child: RepaintBoundary(child: Inspector()),
                  ),
                  const RepaintBoundary(child: StatusBar()),
                ],
              ),
            ),
            // 顶栏层:悬浮于所有图层之上
            Toolbar(
              boxSelect: _boxSelect,
              onBoxSelectChanged: (v) => setState(() => _boxSelect = v),
              onOpenSettings: () => fluent.showDialog<void>(
                context: context,
                builder: (ctx) =>
                    SettingsPanel(onClose: () => Navigator.pop(ctx)),
              ),
              onOpenShortcuts: () => fluent.showDialog<void>(
                context: context,
                builder: (ctx) =>
                    ShortcutsPanel(onClose: () => Navigator.pop(ctx)),
              ),
              onFitView: _fitView,
              onAutoLayout: () {
                GraphStore.instance.autoLayout();
                _fitView();
              },
              onRun: () {
                GraphStore.instance.runPipeline();
              },
            ),
          ],
        ),
      ),
    );
  }
}
