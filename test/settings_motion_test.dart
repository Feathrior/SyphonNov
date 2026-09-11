import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/main.dart';
import 'package:syphon_nov/store/graph_store.dart';
import 'package:syphon_nov/store/settings_store.dart';
import 'package:syphon_nov/ui/motion.dart';

void main() {
  setUp(() {
    GraphStore.useIsolate = false;
    GraphStore.instance.clearAll();
    SettingsStore.instance.motionMode = MotionMode.full;
    SettingsStore.instance.motionSpeed = MotionSpeed.fast;
    SettingsStore.instance.nodeMenuMode = NodeMenuMode.both;
    SettingsStore.instance.nodeShelfEnabled = true;
  });

  tearDown(() {
    GraphStore.instance.clearAll();
    GraphStore.useIsolate = true;
    SettingsStore.instance.motionSpeed = MotionSpeed.fast;
    SettingsStore.instance.motionMode = MotionMode.full;
  });

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const SyphonApp());
    await tester.pump();
  }

  test('animation speed offers fast/medium/slow multipliers', () {
    expect(MotionSpeed.fast.speedFactor, 1.0);
    expect(MotionSpeed.medium.speedFactor, 0.75);
    expect(MotionSpeed.slow.speedFactor, 0.6);
    expect(MotionSpeed.fast.durationFactor, 1.0);
    expect(MotionSpeed.medium.durationFactor, closeTo(1 / 0.75, 1e-9));
    expect(MotionSpeed.slow.durationFactor, closeTo(1 / 0.6, 1e-9));
  });

  test('animation speed scales hard-coded durations', () {
    const base = Duration(milliseconds: 230);
    const pacing = MotionTokens.pacing;
    expect(MotionTokens.scaled(base), const Duration(milliseconds: 460));

    SettingsStore.instance.motionSpeed = MotionSpeed.medium;
    expect(
      MotionTokens.scaled(base),
      Duration(microseconds: (base.inMicroseconds / 0.75 * pacing).round()),
    );

    SettingsStore.instance.motionSpeed = MotionSpeed.slow;
    expect(
      MotionTokens.scaled(base),
      Duration(microseconds: (base.inMicroseconds / 0.6 * pacing).round()),
    );
    // 零时长(关闭动效)不会被放大
    expect(MotionTokens.scaled(Duration.zero), Duration.zero);
  });

  testWidgets('motion tokens follow the speed setting', (tester) async {
    await pumpApp(tester);
    final context = tester.element(find.byKey(const Key('node-shelf')));
    expect(MotionTokens.standard(context), const Duration(milliseconds: 460));

    SettingsStore.instance.motionSpeed = MotionSpeed.medium;
    expect(
      MotionTokens.standard(context),
      Duration(microseconds: (230000 / 0.75 * MotionTokens.pacing).round()),
    );

    SettingsStore.instance.motionSpeed = MotionSpeed.slow;
    expect(
      MotionTokens.spatial(context),
      Duration(microseconds: (320000 / 0.6 * MotionTokens.pacing).round()),
    );
    expect(
      MotionTokens.quick(context),
      Duration(microseconds: (110000 / 0.6 * MotionTokens.pacing).round()),
    );

    // 关闭动效:速度设置不再生效,一律零时长
    SettingsStore.instance.motionSpeed = MotionSpeed.fast;
    SettingsStore.instance.motionMode = MotionMode.off;
    expect(MotionTokens.standard(context), Duration.zero);
    expect(MotionTokens.spatial(context), Duration.zero);
  });

  testWidgets('motion amplitude maps full reduced and off settings', (
    tester,
  ) async {
    await pumpApp(tester);
    final context = tester.element(find.byKey(const Key('node-shelf')));

    SettingsStore.instance.motionMode = MotionMode.full;
    expect(MotionTokens.amplitude(context), 1);
    SettingsStore.instance.motionMode = MotionMode.reduced;
    expect(MotionTokens.amplitude(context), .42);
    SettingsStore.instance.motionMode = MotionMode.off;
    expect(MotionTokens.amplitude(context), 0);
  });

  test('one right-click setting drives the menu and the ring entries', () {
    final settings = SettingsStore.instance;
    settings.nodeMenuMode = NodeMenuMode.menu;
    expect(settings.contextNodeMenuEnabled, isTrue);
    expect(settings.radialNodeMenuEnabled, isFalse);

    settings.nodeMenuMode = NodeMenuMode.radial;
    expect(settings.contextNodeMenuEnabled, isFalse);
    expect(settings.radialNodeMenuEnabled, isTrue);

    settings.nodeMenuMode = NodeMenuMode.both;
    expect(settings.contextNodeMenuEnabled, isTrue);
    expect(settings.radialNodeMenuEnabled, isTrue);
  });

  testWidgets('settings panel exposes animation speed and right-click modes', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();

    expect(find.text('动画速度'), findsOneWidget);
    expect(find.text('右键设置'), findsOneWidget);
    // 旧的独立开关不再出现
    expect(find.text('右键菜单'), findsNothing);
    expect(find.text('右键圆环'), findsNothing);

    await tester.ensureVisible(find.text('慢速'));
    await tester.tap(find.text('慢速'));
    await tester.pumpAndSettle();
    expect(SettingsStore.instance.motionSpeed, MotionSpeed.slow);

    await tester.ensureVisible(find.text('圆环'));
    await tester.tap(find.text('圆环'));
    await tester.pumpAndSettle();
    expect(SettingsStore.instance.nodeMenuMode, NodeMenuMode.radial);

    await tester.ensureVisible(find.text('菜单+圆环'));
    await tester.tap(find.text('菜单+圆环'));
    await tester.pumpAndSettle();
    expect(SettingsStore.instance.nodeMenuMode, NodeMenuMode.both);

    await tester.ensureVisible(find.text('快速'));
    await tester.tap(find.text('快速'));
    await tester.pumpAndSettle();
    expect(SettingsStore.instance.motionSpeed, MotionSpeed.fast);
  });
}
