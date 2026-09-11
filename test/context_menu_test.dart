// 视口自适应菜单定位回归测试:下方/右侧空间不足时应向鼠标左上方翻转,
// 避免菜单被窗口边缘截断(修复"右键菜单在底部被遮挡"问题)。
// 另含 NodeMenu 顶部搜索框(中英文过滤)的行为测试。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/ui/context_menu.dart';

void main() {
  // 测试窗口尺寸为 800x600;菜单 100x80;ViewportAwareMenu 距光标 4px、距边缘 8px
  // 结构与应用一致:菜单层 Stack 位于 Positioned.fill 之内(中间隔着菜单层 Stack,
  // 避免内部 Positioned 与 Positioned.fill 竞争 parent data)
  Future<void> pumpMenu(WidgetTester tester, Offset mouse) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox.expand(
          child: Stack(
            children: [
              Positioned.fill(
                child: Stack(
                  children: [
                    ViewportAwareMenu(
                      mouse: mouse,
                      width: 100,
                      child: const SizedBox(height: 80),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    // 首帧在屏幕外测量实际尺寸,次帧落位
    await tester.pump();
  }

  testWidgets('空间充足时从鼠标右下方弹出', (tester) async {
    await pumpMenu(tester, const Offset(100, 100));
    final pos = tester.getTopLeft(find.byType(ViewportAwareMenu));
    expect(pos.dx, closeTo(104, 0.01)); // 100 + 4
    expect(pos.dy, closeTo(104, 0.01)); // 100 + 4
  });

  testWidgets('下方空间不足时向上翻转', (tester) async {
    // y=580 时下方仅剩 16px,放不下 80px 高的菜单 → 翻到鼠标上方
    await pumpMenu(tester, const Offset(400, 580));
    final pos = tester.getTopLeft(find.byType(ViewportAwareMenu));
    expect(pos.dx, closeTo(404, 0.01)); // 右侧空间充足,保持右下方
    expect(pos.dy, closeTo(496, 0.01)); // 580 - 80 - 4
  });

  testWidgets('右侧空间不足时向左翻转', (tester) async {
    // x=780 时右侧仅剩 16px,放不下 100px 宽的菜单 → 翻到鼠标左侧
    await pumpMenu(tester, const Offset(780, 200));
    final pos = tester.getTopLeft(find.byType(ViewportAwareMenu));
    expect(pos.dx, closeTo(676, 0.01)); // 780 - 100 - 4
    expect(pos.dy, closeTo(204, 0.01)); // 下方空间充足,保持下方
  });

  testWidgets('右下角空间同时不足时向鼠标左上方弹出', (tester) async {
    await pumpMenu(tester, const Offset(780, 580));
    final pos = tester.getTopLeft(find.byType(ViewportAwareMenu));
    expect(pos.dx, closeTo(676, 0.01));
    expect(pos.dy, closeTo(496, 0.01));
    // 菜单整体仍在视口内(不被窗口边缘截断)
    expect(pos.dx + 100, lessThanOrEqualTo(800));
    expect(pos.dy + 80, lessThanOrEqualTo(600));
  });

  // ==================== NodeMenu 搜索框测试 ====================
  // 测试环境未加载语言表,L.t(key) 返回 key 本身:
  // 中文搜索走 label 键名,英文搜索走 id(下划线按空格处理)
  group('NodeMenu 搜索框', () {
    final picked = <String>[];
    var closed = 0;

    Future<void> pumpNodeMenu(WidgetTester tester) async {
      picked.clear();
      closed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox.expand(
            child: Stack(
              children: [
                Positioned.fill(
                  child: Stack(
                    children: [
                      NodeMenu(
                        position: const Offset(50, 50),
                        onPick: picked.add,
                        onClose: () => closed++,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      // 首帧屏幕外测量落位 + autofocus 焦点线重绘
      await tester.pump();
      await tester.pump();
    }

    testWidgets('搜索框位于菜单最上方并显示占位文本', (tester) async {
      await pumpNodeMenu(tester);
      final box = find.byType(TextField);
      expect(box, findsOneWidget);
      expect(find.text('搜索节点…'), findsOneWidget);
      // 搜索框应位于"新建节点"标题之上
      final searchTop = tester.getTopLeft(box).dy;
      final titleTop = tester.getTopLeft(find.text('新建节点')).dy;
      expect(searchTop, lessThan(titleTop));
    });

    testWidgets('输入分类优先排列点、曲线、曲面', (tester) async {
      await pumpNodeMenu(tester);
      final yPoint = tester.getTopLeft(find.text('点输入')).dy;
      final yCurve = tester.getTopLeft(find.text('曲线输入')).dy;
      final ySurface = tester.getTopLeft(find.text('曲面输入')).dy;
      expect(yPoint, lessThan(yCurve));
      expect(yCurve, lessThan(ySurface));
    });

    testWidgets('中文搜索按节点名过滤', (tester) async {
      await pumpNodeMenu(tester);
      await tester.enterText(find.byType(TextField), '拟合');
      await tester.pump();
      expect(find.text('曲线拟合'), findsOneWidget);
      expect(find.text('表格输入'), findsNothing);
    });

    testWidgets('英文搜索按节点 id 过滤', (tester) async {
      await pumpNodeMenu(tester);
      await tester.enterText(find.byType(TextField), 'scatter');
      await tester.pump();
      // scatter_to_table(散点转表格)应命中;table_input 不含 scatter 应排除
      expect(find.text('散点转表格'), findsOneWidget);
      expect(find.text('表格输入'), findsNothing);
    });

    testWidgets('无匹配时显示空状态', (tester) async {
      await pumpNodeMenu(tester);
      await tester.enterText(find.byType(TextField), 'zzz不存在的节点');
      await tester.pump();
      expect(find.text('无匹配节点'), findsOneWidget);
    });

    testWidgets('Enter 选中首个匹配结果', (tester) async {
      await pumpNodeMenu(tester);
      await tester.enterText(find.byType(TextField), 'table');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      // kNodeConfigs 中首个 id 含 table 的节点为 table_input(表格输入)
      expect(picked, contains('table_input'));
    });

    testWidgets('Esc 先清空查询,再次 Esc 关闭菜单', (tester) async {
      await pumpNodeMenu(tester);
      await tester.enterText(find.byType(TextField), '拟合');
      await tester.pump();
      // 第一次 Esc:清空查询,回到分类视图
      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('曲线拟合'), findsNothing);
      expect(find.text('新建节点'), findsOneWidget);
      expect(closed, 0);
      // 第二次 Esc:关闭菜单
      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(closed, 1);
    });
  });
}
