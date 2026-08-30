// 视口自适应菜单定位回归测试:下方/右侧空间不足时应向鼠标左上方翻转,
// 避免菜单被窗口边缘截断(修复"右键菜单在底部被遮挡"问题)。
import 'package:flutter/material.dart';
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
}
