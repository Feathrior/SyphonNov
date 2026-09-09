// 顶栏菜单栏回归测试(自绘 _MenuButton + fluent MenuFlyout):
// 验证:菜单可单击打开、菜单项点击后关闭、点击外部关闭;
// 四个按钮彼此独立——划过其它按钮不再切换菜单(仅单击唤出)。
//
// 说明:全部用"鼠标"设备手势驱动(与真实桌面一致)。flyout 的
// dismissOnPointerMoveAway 依赖鼠标悬停事件,触摸指针在测试中会误触发关闭。
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/main.dart';

void main() {
  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const SyphonApp());
    await tester.pump();
  }

  /// 鼠标左键单击 [label] 文本对应的菜单按钮
  Future<void> clickButton(WidgetTester tester, String label) async {
    final g = await tester.startGesture(
      tester.getCenter(find.text(label)),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 16));
    await g.up();
    await tester.pump();
    await tester.pumpAndSettle();
  }

  testWidgets(
    '顶栏菜单:打开、菜单项触发关闭、点击外部关闭',
    (WidgetTester tester) async {
      await pumpApp(tester);

      // 菜单未打开时,弹层菜单项不可见
      expect(find.text('适应视图'), findsNothing);

      // 点击"视图"按钮打开菜单
      await clickButton(tester, '视图');
      expect(find.text('适应视图'), findsOneWidget);
      expect(find.text('一键整理'), findsOneWidget);

      // 点击菜单项:菜单项动作触发后弹层关闭
      await clickButton(tester, '适应视图');
      expect(find.text('适应视图'), findsNothing);

      // 再次打开,点击画布空白区域:弹层随点击外部关闭
      await clickButton(tester, '视图');
      expect(find.text('适应视图'), findsOneWidget);
      await tester.tapAt(const Offset(700, 500));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('适应视图'), findsNothing);

      // 编辑菜单:ToggleMenuFlyoutItem(框选模式)可见且点击后关闭
      await clickButton(tester, '编辑');
      expect(find.text('框选模式'), findsOneWidget);
      await clickButton(tester, '框选模式');
      expect(find.text('框选模式'), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    '顶栏菜单:打开状态下划过其它按钮不切换菜单',
    (WidgetTester tester) async {
      await pumpApp(tester);

      // 打开"视图"
      await clickButton(tester, '视图');
      expect(find.text('适应视图'), findsOneWidget);

      // 鼠标移入"帮助":视图菜单随光标离开关闭,帮助菜单不得弹出
      final ptr = TestPointer(7, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        ptr.hover(tester.getCenter(find.text('帮助'))),
      );
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('快捷键'), findsNothing, reason: '划过其它按钮不应弹出其菜单');
      expect(find.text('适应视图'), findsNothing, reason: '光标离开后原菜单应关闭');

      // 点击"帮助":仅单击唤出帮助菜单
      await clickButton(tester, '帮助');
      expect(find.text('快捷键'), findsOneWidget);

      // 点击菜单外部收起,避免遗留打开的弹层
      await tester.tapAt(const Offset(700, 500));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('快捷键'), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
