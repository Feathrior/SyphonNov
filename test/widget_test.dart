// Syphon 应用冒烟测试:验证主应用可构建;
// 以及"文本框聚焦时按键不被画布快捷键吞掉"的回归测试
// (空格/回车/退格在右键菜单搜索框中完全失效的问题)。
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart' show TextField, ValueKey;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

import 'package:syphon_nov/main.dart';
import 'package:syphon_nov/models/presets.dart';
import 'package:syphon_nov/store/graph_store.dart';
import 'package:syphon_nov/ui/node_card.dart';

void main() {
  // 应用默认窗口 1440x900(测试默认表面 800x600 低于窗口最小尺寸 960x600,
  // 属性面板在 600 高度下必然溢出),与生产环境保持一致
  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const SyphonApp());
    await tester.pump();
  }

  testWidgets('Syphon app builds', (WidgetTester tester) async {
    await pumpApp(tester);
    expect(find.text('Syphon'), findsWidgets);
  });

  // ==================== 键盘事件冒泡回归测试 ====================
  // 搜索框位于画布 Focus 子树内,按键自输入框向上冒泡经过画布 _onKey;
  // 文本框聚焦时画布必须放行(ignored),App 层的 DefaultTextEditingShortcuts
  // 才能处理退格删除(真实应用中空格/回车同理交由引擎文本输入插入字符)。
  testWidgets('右键菜单搜索框中退格可删除字符', (WidgetTester tester) async {
    await pumpApp(tester);
    // 画布空白处右键(画布区域:工具栏 48 高、检查器 190 高、属性面板 300 宽之内)
    await tester.tapAt(const Offset(200, 200), buttons: kSecondaryButton);
    await tester.pump();
    await tester.pump(); // 菜单屏幕外测量 + 落位
    final search = find.byType(TextField);
    expect(search, findsOneWidget);

    await tester.enterText(search, '拟合');
    await tester.pump();
    // 退格事件自搜索框冒泡:画布守卫放行 → 框架文本快捷键删除末字符
    await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(find.text('拟'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  // ==================== Delete 快捷键删除节点 ====================
  // 事件链:Delete 冒泡到画布 _onKey → deleteSelection → removeNodes →
  // 自动执行增量重算。曾因 propagateDirty 对"已删除节点仍在脏种子中"
  // 做空断言崩溃,导致删除键失效——此处端到端回归。
  testWidgets('Delete 键删除选中节点', (WidgetTester tester) async {
    // testWidgets 假异步不会派发 Isolate 消息:本测试改主 Isolate 同步执行
    GraphStore.useIsolate = false;
    addTearDown(() => GraphStore.useIsolate = true);

    await pumpApp(tester);
    // 测试不经过 main():手动载入演示图(与首启动逻辑一致)
    GraphStore.instance.loadGraph(kDemoGraphJson, silent: true);
    await tester.pump();
    final store = GraphStore.instance;
    // 先全量执行一次:results 非空时删除才走"增量重算"崩溃路径
    store.runPipeline();
    await tester.pump();

    final cards = find.byType(NodeCard);
    final countBefore = tester.widgetList<NodeCard>(cards).length;
    expect(countBefore, greaterThan(0));

    final rect = tester.getRect(cards.first);
    await tester.tapAt(Offset(rect.center.dx, rect.top + 12));
    await tester.pump();

    // 模拟先编辑属性：旧实现中 EditableText 会一直保留焦点，即使随后已经
    // 点击并选中了节点，Delete 仍会被输入框吞掉。
    final propertyFields = find.byType(fluent.TextBox);
    expect(propertyFields, findsWidgets);
    await tester.tap(propertyFields.last);
    await tester.pump();

    // 点击第一个节点卡片(标题栏区域)选中
    await tester.tapAt(Offset(rect.center.dx, rect.top + 12));
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.delete);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.delete);
    await tester.pump();

    expect(
      tester.widgetList<NodeCard>(find.byType(NodeCard)).length,
      countBefore - 1,
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  // ==================== 节点菜单与折叠 ====================
  // 右键节点 = 节点操作菜单(从指针处弹出),折叠改由标题栏箭头负责;
  // 这样右键不会再"顺手"把节点折叠起来。
  testWidgets('右键节点弹菜单而不折叠,折叠由标题栏箭头负责', (tester) async {
    GraphStore.useIsolate = false;
    addTearDown(() => GraphStore.useIsolate = true);
    GraphStore.instance.clearAll();
    final id = GraphStore.instance.addNode(
      'table_input',
      const Offset(120, 90),
      triggerRun: false,
    );
    await pumpApp(tester);
    await tester.pumpAndSettle();

    final card = find.byWidgetPredicate(
      (widget) => widget is NodeCard && widget.nodeId == id,
    );
    final center = tester.getCenter(card);
    await tester.tapAt(center, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('复制所选'), findsOneWidget, reason: '右键节点弹节点菜单');
    expect(
      GraphStore.instance.nodeOf(id)!.collapsed,
      isFalse,
      reason: '右键不再折叠节点',
    );

    // 关掉菜单
    await tester.tapAt(Offset(center.dx, center.dy + 320));
    await tester.pumpAndSettle();
    expect(find.text('复制所选'), findsNothing);

    final arrow = find.byKey(ValueKey('node-collapse-$id'));
    expect(arrow, findsOneWidget);
    await tester.tap(arrow);
    await tester.pumpAndSettle();
    expect(GraphStore.instance.nodeOf(id)!.collapsed, isTrue);
    await tester.tap(arrow);
    await tester.pumpAndSettle();
    expect(GraphStore.instance.nodeOf(id)!.collapsed, isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
