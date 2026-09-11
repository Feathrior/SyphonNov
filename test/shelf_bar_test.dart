import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/main.dart';
import 'package:syphon_nov/models/data.dart' show Category, kAllCategories;
import 'package:syphon_nov/models/registry.dart';
import 'package:syphon_nov/store/graph_store.dart';
import 'package:syphon_nov/store/settings_store.dart';

/// 上边栏改造回归:
/// 1. 所有分类 + Package 合并成一条纯色分段条(无描边);
/// 2. 书脊 hover 拓宽时,弹层宽度跟着加宽,不再裁切右侧内容;
/// 3. 在同一分段条内横向扫过时,次级菜单不会关闭,而是直接切换分类。
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

  testWidgets('shelf categories merge into one solid bar without borders', (
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
      final container = tester.widget<AnimatedContainer>(
        find.descendant(
          of: find.byKey(ValueKey('node-category-${category.name}')),
          matching: find.byType(AnimatedContainer),
        ),
      );
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.border, isNull, reason: '${category.name} 不应有描边');
      final fill = decoration.color!;
      // 纯色填充:不透明度不低于 85%
      expect(fill.a, greaterThanOrEqualTo(0.85));
      // 阴影列表恒定非空(避免 AnimatedContainer 装饰插值产生负模糊半径)
      expect(decoration.boxShadow, isNotNull);
      expect(decoration.boxShadow, hasLength(1));
    }
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
    // 左端不动,只有宽度变化
    expect(tester.getTopLeft(panel).dx, tester.getTopLeft(panel).dx);
    expect(tester.getSize(panel).width, isNot(widthBefore));
    expect(tester.takeException(), isNull);
  });
}
