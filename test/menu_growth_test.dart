import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/main.dart';
import 'package:syphon_nov/models/data.dart' show Category;
import 'package:syphon_nov/store/graph_store.dart';
import 'package:syphon_nov/store/settings_store.dart';
import 'package:syphon_nov/ui/context_menu.dart';
import 'package:syphon_nov/ui/motion.dart';
import 'package:syphon_nov/ui/node_canvas.dart';

/// 回归:
/// 1. 右键菜单与顶栏次级菜单改用与"节点生成"同一套生长动画(从一点长出 + 模糊转清晰);
/// 2. 上边栏书脊的拓宽动画与弹层尺寸过渡同曲线同时长,横向扫过不再跳变。
void main() {
  setUp(() {
    GraphStore.useIsolate = false;
    GraphStore.instance.clearAll();
    SettingsStore.instance.nodeShelfEnabled = true;
    SettingsStore.instance.motionSpeed = MotionSpeed.fast;
    SettingsStore.instance.motionMode = MotionMode.full;
    SettingsStore.instance.nodeMenuMode = NodeMenuMode.both;
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

  bool isGrow(BlurScaleTransition transition) =>
      transition.beginScale == MotionTokens.growBeginScale &&
      transition.maxBlur == MotionTokens.growMaxBlur &&
      transition.reveal == MotionTokens.growReveal &&
      transition.blurUntil == MotionTokens.menuBlurUntil;

  testWidgets('right-click menu grows like a generated node', (tester) async {
    await pumpApp(tester);
    await tester.tapAt(
      tester.getCenter(find.byType(NodeCanvas)),
      buttons: kSecondaryButton,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.byType(NodeMenu), findsOneWidget);
    final transitions = tester.widgetList<BlurScaleTransition>(
      find.descendant(
        of: find.byType(NodeMenu),
        matching: find.byType(BlurScaleTransition),
      ),
    );
    expect(transitions, isNotEmpty);
    expect(
      transitions.any(isGrow),
      isTrue,
      reason: '右键菜单应使用节点生成的生长参数',
    );
    await tester.pumpAndSettle();
  });

  testWidgets('toolbar submenu grows like a generated node', (tester) async {
    await pumpApp(tester);
    // 顶栏菜单的 dismissOnPointerMoveAway 依赖鼠标悬停事件,须用鼠标设备点击
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('文件')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final transitions = tester.widgetList<BlurScaleTransition>(
      find.byType(BlurScaleTransition),
    );
    expect(
      transitions.any(isGrow),
      isTrue,
      reason: '顶栏次级菜单应使用节点生成的生长参数',
    );
    await tester.pumpAndSettle();
  });

  testWidgets('shelf tile widening is synced with the panel resize', (
    tester,
  ) async {
    await pumpApp(tester);
    final pointer = TestPointer(94, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(
        tester.getCenter(
          find.byKey(ValueKey('node-category-${Category.compute.name}')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final tile = tester.widget<AnimatedContainer>(
      find.byKey(const ValueKey('node-spine-derivative')),
    );
    final panel = tester.widget<AnimatedContainer>(
      find.byKey(const Key('node-library-size-transition')),
    );
    expect(tile.duration, panel.duration, reason: '书脊与背景矩形同时长');
    expect(tile.curve, panel.curve, reason: '书脊与背景矩形同曲线(无过冲)');
  });
}
