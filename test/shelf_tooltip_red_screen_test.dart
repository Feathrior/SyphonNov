import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/main.dart';
import 'package:syphon_nov/models/data.dart' show Category;
import 'package:syphon_nov/store/graph_store.dart';
import 'package:syphon_nov/store/settings_store.dart';

/// 回归:上边栏弹层曾用 `CompositedTransformFollower` 定位,书脊上的 Tooltip 弹出
/// 时需要计算锚点的 paint transform,而 follower 层的变换尚未建立 →
/// "The paint transform cannot be reliably computed because of RenderFollowerLayer(s)",
/// 随后连续触发 `_dependents.isEmpty` / "check that it really is our descendant"
/// 两条框架断言(整屏红色报错)。弹层改为按上边栏渲染框直接定位后不再产生 follower 层。
void main() {
  setUp(() {
    GraphStore.useIsolate = false;
    GraphStore.instance.clearAll();
    SettingsStore.instance.nodeShelfEnabled = true;
    SettingsStore.instance.motionSpeed = MotionSpeed.fast;
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

  Finder spines() => find.byWidgetPredicate(
    (w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('node-spine-'),
  );

  testWidgets('flyout stays anchored below the shelf without a follower layer', (
    tester,
  ) async {
    await pumpApp(tester);
    final pointer = TestPointer(81, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(
        tester.getCenter(
          find.byKey(ValueKey('node-category-${Category.compute.name}')),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 140));

    final overlay = find.byKey(const Key('node-library-overlay'));
    expect(overlay, findsOneWidget);
    final shelfRect = tester.getRect(find.byKey(const Key('node-shelf')));
    // 上边栏正下方 8px;水平方向居中于当前胶囊(超窗时贴边,最小边距 16)
    final panel = tester.getRect(
      find.byKey(const Key('node-library-size-transition')),
    );
    expect(panel.top, closeTo(shelfRect.bottom + 8, 0.5));
    final screenW =
        tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expect(panel.left, greaterThanOrEqualTo(15.5));
    expect(panel.right, lessThanOrEqualTo(screenW - 15.5));
    final segCenter = tester
        .getRect(
          find.byKey(ValueKey('node-category-${Category.compute.name}')),
        )
        .center
        .dx;
    final clamped = panel.left <= 16.5 || panel.right >= screenW - 16.5;
    if (!clamped) {
      expect(panel.center.dx, closeTo(segCenter, 2.0));
    }
    // 弹层内部不能再有 follower 层(Tooltip 需要沿锚点链路计算变换)
    expect(
      find.descendant(
        of: overlay,
        matching: find.byType(CompositedTransformFollower),
      ),
      findsNothing,
    );
  });

  testWidgets('tooltip over a spine then picking the node stays clean', (
    tester,
  ) async {
    await pumpApp(tester);
    final pointer = TestPointer(82, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(
        tester.getCenter(
          find.byKey(ValueKey('node-category-${Category.compute.name}')),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 140));
    expect(spines(), findsWidgets);

    // 悬停到书脊上等 Tooltip 弹出(waitDuration 500ms)
    final spine = tester.getCenter(spines().first);
    await tester.sendEventToBinding(pointer.hover(spine));
    await tester.pump(const Duration(milliseconds: 700));
    expect(tester.takeException(), isNull);

    await tester.tapAt(spine);
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(GraphStore.instance.nodes, hasLength(1));
  });

  testWidgets('repeated tooltip + pick rounds stay clean', (tester) async {
    await pumpApp(tester);
    final pointer = TestPointer(83, PointerDeviceKind.mouse);
    for (var round = 0; round < 6; round++) {
      await tester.sendEventToBinding(
        pointer.hover(
          tester.getCenter(
            find.byKey(ValueKey('node-category-${Category.clean.name}')),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 120));
      if (spines().evaluate().isEmpty) continue;
      final spine = tester.getCenter(spines().first);
      await tester.sendEventToBinding(pointer.hover(spine));
      await tester.pump(const Duration(milliseconds: 650));
      expect(tester.takeException(), isNull, reason: 'tooltip round $round');
      await tester.tapAt(spine);
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.takeException(), isNull, reason: 'pick round $round');
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.takeException(), isNull, reason: 'settle round $round');
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
