// Syphon Flutter 桌面版:节点化科研数据处理工作台(由 React 版 App.tsx 移植)
library;

import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:file_selector/file_selector.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../models/csv.dart';
import '../models/presets.dart';
import 'store/graph_store.dart';
import 'store/settings_store.dart';
import 'ui/inspector.dart';
import 'ui/motion.dart';
import 'ui/node_canvas.dart';
import 'ui/node_shelf.dart';
import 'ui/properties_panel.dart';
import 'ui/settings_panel.dart';
import 'ui/shortcuts_panel.dart';
import 'ui/status_bar.dart';
import 'ui/theme.dart';
import 'ui/toolbar.dart';
import 'i18n.dart';

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
  // 首次启动:载入"功能全景演示"示例节点组(之后不再自动出现,可在 文件→预设 重新加载)
  if (!SettingsStore.instance.demoLoaded) {
    GraphStore.instance.loadGraph(kDemoGraphJson, silent: true);
    SettingsStore.instance.setDemoLoaded();
  }
  runApp(const SyphonApp());
}

class SyphonApp extends StatelessWidget {
  const SyphonApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = SettingsStore.instance;
    return AnimatedBuilder(
      animation: Listenable.merge([settings, L.rebuildNotifier]),
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
        // fluent 菜单弹层(MenuBar/MenuFlyout 等)背景色:与 SyphonTheme
        // 浮层色统一,避免原生默认灰白/深灰与应用配色割裂
        final bgFloat = dark
            ? SyphonTheme.darkTheme.bgFloat
            : SyphonTheme.lightTheme.bgFloat;
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
            menuColor: bgFloat,
            // 细腻过渡动画:菜单/弹窗/ComboBox/InfoBar 等 fluent 控件的动画时长。
            // 层级 faster < fast < medium < slow;fast 90ms——MenuBar 点击到
            // 弹出次级菜单的主要延迟就是它(叠加 easeIn 淡入起始慢),提速后接近原生。
            // 同时按设置中的动画速度倍率整体缩放。
            fasterAnimationDuration: MotionTokens.scaled(
              const Duration(milliseconds: 75),
            ),
            fastAnimationDuration: MotionTokens.scaled(
              const Duration(milliseconds: 110),
            ),
            mediumAnimationDuration: MotionTokens.scaled(
              const Duration(milliseconds: 230),
            ),
            slowAnimationDuration: MotionTokens.scaled(
              const Duration(milliseconds: 420),
            ),
          ),
          darkTheme: fluent.FluentThemeData(
            brightness: Brightness.dark,
            accentColor: accent,
            inactiveColor: dim,
            fontFamily: 'Microsoft YaHei',
            scaffoldBackgroundColor: bgApp,
            cardColor: bgSurface,
            menuColor: bgFloat,
            fasterAnimationDuration: MotionTokens.scaled(
              const Duration(milliseconds: 75),
            ),
            fastAnimationDuration: MotionTokens.scaled(
              const Duration(milliseconds: 110),
            ),
            mediumAnimationDuration: MotionTokens.scaled(
              const Duration(milliseconds: 230),
            ),
            slowAnimationDuration: MotionTokens.scaled(
              const Duration(milliseconds: 420),
            ),
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
  // 画布 RepaintBoundary:导出画布图片时捕获其渲染层
  final GlobalKey _canvasBoundaryKey = GlobalKey();
  // 最外层 Focus:让快捷键在应用任意位置(画布失焦时)都能被捕获
  final FocusNode _shellFocus = FocusNode();
  bool _boxSelect = false;

  // 外部文件拖拽(Win32 WM_DROPFILES → 平台通道 → 这里)→ 在放点生成表格输入节点
  static const _fileDropChannel = MethodChannel('syphon/file_drop');

  // ---- 彩蛋:上上下下左右左右 → 水果忍者模式 ----
  static const List<LogicalKeyboardKey> _konamiCode = [
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
  ];
  final List<LogicalKeyboardKey> _konamiBuffer = [];

  /// 累计方向键序列。命中返回 true(该按键已被彩蛋消费)。
  bool _trackKonami(LogicalKeyboardKey key) {
    if (!_konamiCode.contains(key)) return false;
    final next = _konamiCode[_konamiBuffer.length];
    if (key == next) {
      _konamiBuffer.add(key);
    } else {
      // 按错则重置;若按错的正好是序列首位,则以它作为新的开始
      _konamiBuffer.clear();
      if (key == _konamiCode.first) _konamiBuffer.add(key);
    }
    if (_konamiBuffer.length == _konamiCode.length) {
      _konamiBuffer.clear();
      _openNinjaPrompt();
    }
    return true;
  }

  /// 序列完成:已在该模式则直接退出,否则弹窗确认后进入
  Future<void> _openNinjaPrompt() async {
    final canvas = _canvasKey.currentState;
    if (canvas == null) return;
    if (canvas.ninjaActive) {
      canvas.exitNinjaMode();
      return;
    }
    final go = await fluent.showDialog<bool>(
      context: context,
      builder: (ctx) => fluent.ContentDialog(
        title: const Text('水果忍者'),
        content: const SizedBox(
          width: 320,
          child: Text('检测到隐藏指令。是否进入水果忍者模式?\n(进入后当前画布会暂存,再次输入指令即可退出)'),
        ),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          fluent.FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('进入'),
          ),
        ],
      ),
    );
    if (go == true) _canvasKey.currentState?.enterNinjaMode();
  }

  void _fitView() => _canvasKey.currentState?.fitView();

  /// 导出画布图片:捕获画布 RepaintBoundary(当前视口)→ PNG(2x)→ 另存为
  Future<void> _exportCanvasImage() async {
    final store = GraphStore.instance;
    if (store.nodes.isEmpty) return;
    final ctx = _canvasBoundaryKey.currentContext;
    final ro = ctx?.findRenderObject();
    if (ro is! RenderRepaintBoundary) return;
    try {
      final image = await ro.toImage(pixelRatio: 2.0);
      final data = await image.toByteData(format: ImageByteFormat.png);
      if (data == null) return;
      final group = XTypeGroup(label: L.t('PNG 图片'), extensions: const ['png']);
      final loc = await getSaveLocation(
        suggestedName: 'syphon-canvas.png',
        acceptedTypeGroups: [group],
      );
      if (loc == null) return;
      await File(loc.path).writeAsBytes(data.buffer.asUint8List());
      store.addLog('ok', '${L.t('已导出画布图片')}:${loc.path}');
    } catch (e) {
      store.addLog('error', '${L.t('导出画布图片失败')}:$e');
    }
  }

  @override
  void initState() {
    super.initState();
    _fileDropChannel.setMethodCallHandler(_onFileDrop);
    // 首次启动载入演示图时:首帧后自动缩放至全图
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (GraphStore.instance.nodes.isNotEmpty) {
        _canvasKey.currentState?.fitView();
      }
    });
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
    const exts = {'.csv', '.tsv', '.txt', '.xlsx'};
    final supported = paths
        .where((path) => exts.any((ext) => path.toLowerCase().endsWith(ext)))
        .toList();
    if (supported.isEmpty) {
      GraphStore.instance.addLog('error', '拖入的文件格式不受支持');
      return;
    }
    for (var index = 0; index < supported.length; index++) {
      final path = supported[index];
      try {
        final text = await dataFileToCsvText(path);
        _canvasKey.currentState?.dropFileText(
          pos + Offset(index * 32.0, index * 32.0),
          text,
          fileName: fileBaseName(path),
        );
      } catch (e) {
        GraphStore.instance.addLog('error', '导入文件失败:$e');
      }
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
    final settings = SettingsStore.instance;
    return settings.matchesShortcut('undo', event) ||
        settings.matchesShortcut('redo', event);
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

    // 彩蛋:方向键序列(上上下下左右左右)在画布内始终可用
    if (_trackKonami(event.logicalKey)) {
      return KeyEventResult.handled;
    }
    // 水果忍者模式期间:吞掉所有编辑快捷键,只保留上面的退出指令
    if (_canvasKey.currentState?.ninjaActive ?? false) {
      return KeyEventResult.handled;
    }

    final settings = SettingsStore.instance;

    if (settings.matchesShortcut('undo', event)) {
      GraphStore.instance.undo();
      return KeyEventResult.handled;
    }
    if (settings.matchesShortcut('redo', event)) {
      GraphStore.instance.redo();
      return KeyEventResult.handled;
    }
    if (settings.matchesShortcut('copy', event)) {
      final s = GraphStore.instance;
      final ids = <String>{};
      ids.addAll(s.multiSelected);
      if (s.selectedId != null) ids.add(s.selectedId!);
      s.copySelection(ids);
      return KeyEventResult.handled;
    }
    if (settings.matchesShortcut('paste', event)) {
      final world = NodeCanvas.lastMouseWorldPos;
      GraphStore.instance.pasteAt(world);
      return KeyEventResult.handled;
    }
    if (settings.matchesShortcut('cut', event)) {
      final s = GraphStore.instance;
      final ids = <String>{...s.multiSelected, ?s.selectedId};
      s.copySelection(ids);
      s.removeNodes(ids.toList());
      return KeyEventResult.handled;
    }
    if (settings.matchesShortcut('selectAll', event)) {
      final s = GraphStore.instance;
      s.setMultiSelected(s.nodes.map((item) => item.id).toSet());
      return KeyEventResult.handled;
    }
    // Escape:取消选中(画布右键菜单/分割点编辑由 NodeCanvas 自身的 Focus 处理)
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      GraphStore.instance.selectNode(null);
      GraphStore.instance.selectSplitEdge(null);
      return KeyEventResult.handled;
    }

    // Delete/Backspace:删除选中节点(或分割点)
    if (settings.matchesShortcut('delete', event) ||
        event.logicalKey == LogicalKeyboardKey.delete ||
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
                  // 上边栏关闭时不再预留节点条高度,否则工具栏下方会残留一条空带
                  SizedBox(
                    height:
                        SyphonDims.toolbarH +
                        (SettingsStore.instance.nodeShelfEnabled
                            ? SyphonDims.nodeShelfH
                            : 0),
                  ),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: RepaintBoundary(
                            key: _canvasBoundaryKey,
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
            if (SettingsStore.instance.nodeShelfEnabled)
              Positioned(
                top: SyphonDims.toolbarH,
                left: 0,
                right: 0,
                child: NodeShelf(
                  onCreateNode: (id) =>
                      _canvasKey.currentState?.addNodeAtViewportCenter(id),
                  onCreatePackage: (value) => _canvasKey.currentState
                      ?.createPackageAtViewportCenter(value),
                  onDropNode: (id, position) =>
                      _canvasKey.currentState?.addNodeFromGlobal(
                        id,
                        position,
                      ) ??
                      false,
                  onDropPackage: (value, position) =>
                      _canvasKey.currentState?.addPackageFromGlobal(
                        value,
                        position,
                      ) ??
                      false,
                  onDragUpdate: (id, category, position) => _canvasKey
                      .currentState
                      ?.updateExternalNodeDrag(id, category, position),
                  onPackageDragUpdate: (position) => _canvasKey.currentState
                      ?.updateExternalPackageDrag(position),
                  onDragCancel: () =>
                      _canvasKey.currentState?.cancelExternalNodeDrag(),
                ),
              ),
            // 顶栏层:悬浮于所有图层之上
            Toolbar(
              boxSelect: _boxSelect,
              onBoxSelectChanged: (v) {
                // 先让菜单完成关闭，再更新工具栏状态，避免重建打断退出动画。
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) setState(() => _boxSelect = v);
                });
              },
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
              onExportImage: _exportCanvasImage,
            ),
          ],
        ),
      ),
    );
  }
}
