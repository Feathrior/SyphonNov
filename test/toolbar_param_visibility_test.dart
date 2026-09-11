// 1. 曲线输入节点:只在对应模式下显示对应参数(参数方程模式才显示 x=/y=);
// 2. 顶栏四个菜单按钮:彼此独立,仅单击唤出——鼠标跨按钮划过不切换菜单。
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/main.dart';
import 'package:syphon_nov/models/presets.dart';
import 'package:syphon_nov/store/graph_store.dart';

void main() {
  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const SyphonApp());
    await tester.pump();
  }

  // 鼠标移到 widget 上(TestPointer 保持同一指针,模拟划过)

  testWidgets('曲线输入:参数随模式联动显示', (WidgetTester tester) async {
    await pumpApp(tester);
    GraphStore.instance.loadGraph(kDemoGraphJson, silent: true);
    await tester.pump();
    final store = GraphStore.instance;
    store.selectNode('fc'); // 演示图中的 func_curve 节点
    await tester.pump();
    await tester.tap(find.text('数据与计算'));
    await tester.pump();
    await tester.tap(find.text('范围与精度'));
    await tester.pump();

    // 默认 function 模式:显示"表达式",不显示 x(t)/y(t)
    expect(find.text('表达式'), findsWidgets, reason: '函数模式应显示表达式');
    expect(find.text('x(t) 参数式'), findsNothing);
    expect(find.text('y(t) 参数式'), findsNothing);

    // 参数方程模式:显示 x=/y=,隐藏通用表达式
    store.updateNodeParams('fc', {'mode': 'parametric'});
    await tester.pump();
    expect(find.text('x(t) 参数式'), findsOneWidget);
    expect(find.text('y(t) 参数式'), findsOneWidget);
    expect(find.text('表达式'), findsNothing, reason: '参数方程模式不应显示通用表达式');

    // 隐式方程模式:显示表达式与 Y 范围,隐藏 x(t)/y(t)
    store.updateNodeParams('fc', {'mode': 'implicit'});
    await tester.pump();
    expect(find.text('表达式'), findsWidgets);
    expect(find.text('Y 起始'), findsOneWidget);
    expect(find.text('x(t) 参数式'), findsNothing);
    expect(find.text('y(t) 参数式'), findsNothing);
  });

  testWidgets(
    '顶栏菜单:单击唤出,跨按钮划过不切换',
    (WidgetTester tester) async {
      // 隔离单例状态:清掉上一个测试遗留的演示图(其离屏节点会触发 RenderFlex
      // 溢出告警,并作为异常计入本测试)。
      GraphStore.instance.clearAll();
      GraphStore.instance.selectNode(null);
      await pumpApp(tester);
      final ptr = TestPointer(7, PointerDeviceKind.mouse);

      Future<void> hover(Finder f) async {
        await tester.sendEventToBinding(ptr.hover(tester.getCenter(f)));
        await tester.pump(const Duration(milliseconds: 120));
        await tester.pumpAndSettle();
      }

      // 未点击任何按钮时,划过四个按钮不应弹出任何次级菜单
      for (final label in ['文件', '编辑', '视图', '帮助']) {
        await hover(find.text(label));
      }
      expect(find.text('保存画布'), findsNothing, reason: '仅划过不应打开文件菜单');

      // 单击"文件"→ 打开文件菜单(mouse 左键 down/up)
      final fileBtn = find.text('文件');
      final click = await tester.startGesture(
        tester.getCenter(fileBtn),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 16));
      await click.up();
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('保存画布'), findsOneWidget);

      // 鼠标划过"编辑":当前菜单随光标离开关闭,且不弹出编辑菜单
      await hover(find.text('编辑'));
      expect(find.text('撤销'), findsNothing, reason: '划过其他按钮不应弹出编辑菜单');
      expect(find.text('保存画布'), findsNothing, reason: '光标离开后文件菜单应自动关闭');

      // 单击"编辑"→ 打开编辑菜单
      final editBtn = find.text('编辑');
      final g2 = await tester.startGesture(
        tester.getCenter(editBtn),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 16));
      await g2.up();
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('撤销'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
