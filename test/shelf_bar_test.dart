import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/main.dart';
import 'package:syphon_nov/models/data.dart' show Category, kAllCategories;
import 'package:syphon_nov/models/registry.dart';
import 'package:syphon_nov/store/graph_store.dart';
import 'package:syphon_nov/store/settings_store.dart';

/// 上边栏改造回归:
/// 1. 所有分类 + Package 合并成一条分段条:低饱和填充 + 彩色内描边,不做发光;
/// 2. 书脊 hover 拓宽时,弹层宽度跟着加宽,不再裁切右侧内容;
/// 3. 弹层水平居中于当前胶囊下方;
/// 4. 在同一分段条内横向扫过时,次级菜单不会关闭,而是直接切换分类。
void main() {
  setUp(() {
    GraphStore.useIsolate = false;
    GraphStore.instance.clearAll();
    SettingsStore.instance.nodeShelfEnabled = true;
    SettingsStore.instance.motionSpeed = MotionSpeed.fast;
    SettingsStore.instance.packageLibrary = [];
  });

  tearDown(() {
    GraphStore.instance.clearAll();
    GraphStore.useIsolate = true;
    SettingsStore.instance.nodeShelfEnabled = true;
  });

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const SyphonApp());
    await tester.pump();
  }

  Finder spineOf(Category category) {
    final ids = kNodeConfigs
        .where((cfg) => cfg.category == category)
        .map((cfg) => cfg.id)
        .toSet();
    return find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          ids.contains((w.key! as ValueKey<String>).value.replaceFirst('node-spine-', '')),
    );
  }

  testWidgets('shelf segments are low-saturation pills with an inner stroke', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(find.byKey(const Key('node-shelf')), findsOneWidget);
    expect(find.byKey(const Key('node-shelf-bar')), findsOneWidget);
    // 5 个分类 + Package 都在同一条内
    for (final category in kAllCategories) {
      expect(
        find.byKey(ValueKey('node-category-${category.name}')),
        findsOneWidget,
      );
    }
    expect(find.byKey(const Key('node-category-package')), findsOneWidget);

    for (final category in kAllCategories) {
      // tileKey 就在分段自身的 AnimatedContainer 上(便于按分类定位胶囊)
      final container = tester.widget<AnimatedContainer>(
        find.byKey(ValueKey('node-category-${category.name}')),
      );
      final decoration = container.decoration! as BoxDecoration;
      // 未呼出:低饱和填充 + 彩色内描边
      expect(
        decoration.color!.a,
        lessThanOrEqualTo(0.2),
        reason: '${category.name} 填充应收敛,不再整块纯色',
      );
      final border = decoration.border! as Border;
      expect(border.top.width, closeTo(1.2, 0.01), reason: '静息描边较细');
      expect(border.top.color.a, greaterThan(0.2), reason: '描边应带分类色');
      // 不再发光(阴影列表必须为空,否则 hover 时会插值出负模糊半径)
      expect(decoration.boxShadow, isNull, reason: '不做发光 hover');
    }

    // 呼出后:描边加粗、填充加深(仍是内描边,不是整块纯色)
    final pointer = TestPointer(94, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(
        tester.getCenter(
          find.byKey(ValueKey('node-category-${Category.compute.name}')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final opened = tester
        .widget<AnimatedContainer>(
          find.byKey(ValueKey('node-category-${Category.compute.name}')),
        )
        .decoration! as BoxDecoration;
    final openedBorder = opened.border! as Border;
    expect(openedBorder.top.width, closeTo(1.8, 0.01));
    expect(openedBorder.top.color.a, greaterThan(0.8));
    expect(opened.color!.a, lessThanOrEqualTo(0.2));
    expect(opened.boxShadow, isNull);
  });

  testWidgets('flyout width follows the hovered spine', (tester) async {
    await pumpApp(tester);
    final pointer = TestPointer(91, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(
        tester.getCenter(
          find.byKey(ValueKey('node-category-${Category.compute.name}')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final panel = find.byKey(const Key('node-library-size-transition'));
    final restWidth = tester.getSize(panel).width;

    // 悬停某个书脊:书脊 48 → 64,弹层同步 +16
    final spine = spineOf(Category.compute).first;
    final spinePos = tester.getCenter(spine);
    await tester.sendEventToBinding(pointer.hover(spinePos));
    await tester.pumpAndSettle();
    final hoverWidth = tester.getSize(panel).width;
    expect(hoverWidth, closeTo(restWidth + 16, 0.6));

    // 移出书脊(仍在弹层内):宽度收回
    final panelRect = tester.getRect(panel);
    await tester.sendEventToBinding(
      pointer.hover(Offset(panelRect.center.dx, panelRect.bottom - 8)),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).width, closeTo(restWidth, 0.6));
  });

  testWidgets('sweeping across the bar switches category without closing', (
    tester,
  ) async {
    await pumpApp(tester);
    final pointer = TestPointer(92, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(
        tester.getCenter(
          find.byKey(ValueKey('node-category-${Category.input.name}')),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 160));
    expect(find.byKey(const Key('node-library-overlay')), findsOneWidget);
    expect(spineOf(Category.input), findsWidgets);

    // 直接扫到相邻的分类段:不应触发关闭(条内没有间隙)
    await tester.sendEventToBinding(
      pointer.hover(
        tester.getCenter(
          find.byKey(ValueKey('node-category-${Category.clean.name}')),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      find.byKey(const Key('node-library-overlay')),
      findsWidgets,
      reason: '同一分段条内横扫不应关闭弹层(切换过渡期间新旧内容会短暂并存)',
    );
    await tester.pumpAndSettle();
    expect(spineOf(Category.clean), findsWidgets);
    expect(spineOf(Category.input), findsNothing);

    // 继续扫回上一个分类,依旧保持打开
    await tester.sendEventToBinding(
      pointer.hover(
        tester.getCenter(
          find.byKey(ValueKey('node-category-${Category.input.name}')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(spineOf(Category.input), findsWidgets);

    // 指针停在书脊上时横扫到 Package 段:直接切到 Package 库,不先关闭
    await tester.sendEventToBinding(
      pointer.hover(tester.getCenter(spineOf(Category.input).first)),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.sendEventToBinding(
      pointer.hover(
        tester.getCenter(find.byKey(const Key('node-category-package'))),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('package-library-overlay')),
      findsOneWidget,
      reason: '横扫到 Package 段应直接切换为 Package 库',
    );
    expect(spineOf(Category.input), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('category switch swaps content instantly (no exit/enter pass)', (
    tester,
  ) async {    await pumpApp(tester);
    final pointer = TestPointer(93, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(
        tester.getCenter(
          find.byKey(ValueKey('node-category-${Category.compute.name}')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(spineOf(Category.compute), findsWidgets);

    // 切到另一个分类:当帧就应换成新内容,不保留旧内容做退场
    await tester.sendEventToBinding(
      pointer.hover(
        tester.getCenter(
          find.byKey(ValueKey('node-category-${Category.visualize.name}')),
        ),
      ),
    );
    await tester.pump();
    expect(spineOf(Category.visualize), findsWidgets, reason: '内容直接替换');
    expect(spineOf(Category.compute), findsNothing, reason: '不应保留旧内容退场');

    // 尺寸过渡仍在:背景矩形按"利落"档扩缩
    expect(
      tester
          .widget<AnimatedContainer>(
            find.byKey(const Key('node-library-size-transition')),
          )
          .duration,
      const Duration(milliseconds: 220),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('flyout background stays the same element across categories', (
    tester,
  ) async {
    await pumpApp(tester);
    final pointer = TestPointer(95, PointerDeviceKind.mouse);
    final panel = find.byKey(const Key('node-library-panel'));

    await tester.sendEventToBinding(
      pointer.hover(
        tester.getCenter(
          find.byKey(ValueKey('node-category-${Category.compute.name}')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final before = tester.element(panel);
    final widthBefore = tester.getSize(panel).width;

    await tester.sendEventToBinding(
      pointer.hover(
        tester.getCenter(
          find.byKey(ValueKey('node-category-${Category.visualize.name}')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final after = tester.element(panel);
    expect(
      identical(before, after),
      isTrue,
      reason: '背景矩形必须是同一个元素,不能被替换/重建',
    );
    // 水平位置跟随当前胶囊:面板中心对齐 visualize 段中心;若会超窗则贴边钳制
    final segCenter = tester
        .getRect(find.byKey(ValueKey('node-category-${Category.visualize.name}')))
        .center
        .dx;
    final screenW =
        tester.view.physicalSize.width / tester.view.devicePixelRatio;
    final panelRect = tester.getRect(panel);
    expect(panelRect.left, greaterThanOrEqualTo(15.5));
    expect(panelRect.right, lessThanOrEqualTo(screenW - 15.5));
    final clamped =
        panelRect.left <= 16.5 || panelRect.right >= screenW - 16.5;
    if (!clamped) {
      expect(panelRect.center.dx, closeTo(segCenter, 2.0));
    }
    expect(tester.getSize(panel).width, isNot(widthBefore));
    expect(tester.takeException(), isNull);
  });
}
