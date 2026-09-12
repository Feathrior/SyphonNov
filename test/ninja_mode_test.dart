// 彩蛋「水果忍者模式」回归:
// 1. 切断判定按"线段-线段"求交:采样点之间的线段也参与(快速划过不漏切);
// 2. 上上下下左右左右的序列弹出确认框,确认后保存原画布并进入空白画布;
// 3. 模式内鼠标拖拽只挥刀切水果,绝不拖动画布;
// 4. 再次输入序列退出并恢复原画布。
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kPrimaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/main.dart';
import 'package:syphon_nov/store/graph_store.dart';
import 'package:syphon_nov/store/settings_store.dart';
import 'package:syphon_nov/ui/canvas_geometry.dart';
import 'package:syphon_nov/ui/node_canvas.dart';
import 'package:syphon_nov/ui/ninja_mode.dart';

void main() {
  group('切断判定改为线段求交', () {
    test('划过线段穿过连线(两端都远离连线)依然判为命中', () {
      const a = Offset(0, 0);
      const b = Offset(200, 0);
      // 竖直划过:两个采样端点距连线各 40px,远超阈值,但线段本身穿过连线
      const from = Offset(100, -40);
      const to = Offset(100, 40);
      // 旧的点式判定(只比采样点)会漏掉
      expect(closestOnEdge(a: a, b: b, p: from)!.dist, greaterThan(20));
      // 线段判定命中交点
      final hit = closestOnEdgeSegment(
        a: a,
        b: b,
        from: from,
        to: to,
        threshold: 6,
      );
      expect(hit, isNotNull);
      expect(hit!.dist, lessThan(0.01));
      expect(hit.point.dx, closeTo(100, 0.5));
    });

    test('远离时仍然不命中', () {
      final hit = closestOnEdgeSegment(
        a: const Offset(0, 0),
        b: const Offset(200, 0),
        from: const Offset(100, 300),
        to: const Offset(300, 300),
        threshold: 6,
      );
      expect(hit, isNull);
    });
  });

  group('NinjaGame', () {
    NinjaFruit nodeAt(Offset at) => NinjaFruit(
      configId: 'table_input',
      label: '表格输入',
      icon: '▣',
      color: const Color(0xFF10B981),
      position: at,
      velocity: Offset.zero,
      angle: 0,
      spin: 0,
      size: const Size(146, 86),
    );

    /// 两个节点 + 它们之间的一条连线(连线从卡片边缘接出)
    ({NinjaGame game, NinjaFruit a, NinjaFruit b, NinjaWire wire}) twoNodes() {
      final game = NinjaGame()
        ..width = 800
        ..height = 600;
      final a = nodeAt(const Offset(240, 300));
      final b = nodeAt(const Offset(640, 300));
      game.fruits.addAll([a, b]);
      final wire = NinjaWire(
        from: a,
        to: b,
        color: const Color(0xFFF59E0B),
      );
      game.wires.add(wire);
      return (game: game, a: a, b: b, wire: wire);
    }

    test('连线连着两个节点,刀锋划过连线即切断(节点本体切不动)', () {
      final t = twoNodes();
      final path = t.game.wirePath(t.wire);
      // 两端都贴在卡片边缘之外(不是从节点中心连出)
      expect(path.first.dx, greaterThan(240 + 73 - 0.5));
      expect(path.last.dx, lessThan(640 - 73 + 0.5));

      // 从连线上方划到下方:起止点都远离节点本体,只有连线被切
      final mid = path[path.length ~/ 2];
      final cuts = t.game.slice(
        Offset(mid.dx, mid.dy - 60),
        Offset(mid.dx, mid.dy + 60),
      );
      expect(cuts, hasLength(1));
      expect(cuts.single.wire, same(t.wire));
      expect(t.wire.cut, isTrue);
      expect(cuts.single.point.dx, closeTo(mid.dx, 1));
      expect(t.game.score, 1);
      // 同一条连线不会被重复切断
      expect(
        t.game.slice(
          Offset(mid.dx, mid.dy - 60),
          Offset(mid.dx, mid.dy + 60),
        ),
        isEmpty,
      );
      expect(t.game.score, 1);
    });

    test('切开后连线定格成两半,散开后从列表移除', () {
      final t = twoNodes();
      t.game.slice(const Offset(0, 0), const Offset(0, 0)); // 空刀不计分
      final mid = t.game.wirePath(t.wire)[7];
      t.game.slice(Offset(mid.dx, mid.dy - 40), Offset(mid.dx, mid.dy + 40));
      expect(t.wire.cut, isTrue);
      expect(t.wire.frozen, isNotEmpty, reason: '切开的折线被定格,便于两半散开');
      // 播放完散开动画后移除
      for (var i = 0; i < 60; i++) {
        t.game.update(1 / 60);
      }
      expect(t.game.wires, isEmpty);
    });

    test('节点掉出画面后,与它相连的连线一并移除', () {
      final t = twoNodes();
      // 把 a 直接推出画面外
      t.a.position = Offset(240, 600 + t.a.size.height + 100);
      t.game.update(1 / 60);
      expect(t.game.fruits.map((f) => f.configId), isNotEmpty);
      expect(t.game.fruits.contains(t.a), isFalse);
      expect(t.game.wires, isEmpty);
    });

    test('连线结构固定:每个新节点与紧邻它之前的两个节点相连,切完不会补线', () {
      // 画布足够高:测试期间不会有节点落回画面外(出场顺序 = fruits 顺序)
      final game = NinjaGame()
        ..width = 800
        ..height = 4000;
      var frames = 0;
      while (game.fruits.length < 5 && frames < 60 * 20) {
        game.update(1 / 60);
        frames++;
      }
      final order = game.fruits.toList();
      expect(order, hasLength(5));
      // 第 1 个节点没有前驱 → 0 条;第 2 个只有 1 个前驱 → 1 条;之后固定 2 条
      expect(
        game.wires.length,
        1 + (order.length - 2) * NinjaGame.wiresPerNode,
      );
      expect(
        game.wires.where((w) => identical(w.to, order[1])).length,
        1,
        reason: '第 2 个节点只有 1 个前驱',
      );
      for (var i = 2; i < order.length; i++) {
        final linkedFrom = game.wires
            .where((w) => identical(w.to, order[i]))
            .map((w) => w.from)
            .toList();
        expect(linkedFrom, hasLength(NinjaGame.wiresPerNode));
        expect(linkedFrom, contains(order[i - 1]));
        expect(linkedFrom, contains(order[i - 2]));
      }

      // 一刀刀切开所有连线:之后不会再凭空长出新的
      for (final w in game.wires.toList()) {
        final path = game.wirePath(w);
        final mid = path[path.length ~/ 2];
        game.slice(Offset(mid.dx, mid.dy - 30), Offset(mid.dx, mid.dy + 30));
      }
      expect(game.wires.where((w) => !w.cut), isEmpty);
      // 之后运行的每一帧:已经在场的老节点之间绝不会再连出新线
      // (新节点入场时才会带来它们自己的固定几条线)
      final survivors = game.fruits.toSet();
      for (var i = 0; i < 60 * 3; i++) {
        game.update(1 / 60);
        for (final w in game.wires.where((w) => !w.cut)) {
          expect(
            survivors.contains(w.from) && survivors.contains(w.to),
            isFalse,
            reason: '切干净后,老节点之间不能再补线',
          );
        }
      }
    });

    test('随时间入场时连线只在入场瞬间建立', () {
      final game = NinjaGame()
        ..width = 800
        ..height = 600;
      for (var i = 0; i < 60 * 6; i++) {
        game.update(1 / 60);
      }
      expect(game.wires, isNotEmpty);
      for (final w in game.wires) {
        expect(identical(w.from, w.to), isFalse);
        expect(game.fruits, contains(w.from));
        expect(game.fruits, contains(w.to));
      }
      // 场上节点数 N → 连线数 ≤ (N-1) * 2
      expect(
        game.wires.length,
        lessThanOrEqualTo((game.fruits.length - 1) * NinjaGame.wiresPerNode),
      );
    });

    test('抛物线:节点飞起后落回画面外被移除', () {
      final game = NinjaGame()
        ..width = 800
        ..height = 600;
      // 从画面下方抛入(与 _spawn 的初速度同向:向上)
      final fruit = nodeAt(const Offset(400, 700))
        ..velocity = const Offset(0, -800);
      game.fruits.add(fruit);
      var minDy = fruit.position.dy;
      var removed = false;
      for (var i = 0; i < 60 * 10; i++) {
        game.update(1 / 60);
        if (fruit.position.dy < minDy) minDy = fruit.position.dy;
        if (!game.fruits.contains(fruit)) {
          removed = true;
          break;
        }
      }
      expect(minDy, lessThan(500), reason: '向上飞起后再回落');
      expect(removed, isTrue, reason: '掉出画面后被移除');
    });
  });

  testWidgets('上上下下左右左右:确认后进入忍者模式,再输入一次退出并恢复画布', (
    tester,
  ) async {
    GraphStore.useIsolate = false;
    GraphStore.instance.clearAll();
    SettingsStore.instance.nodeShelfEnabled = false;
    final nodeId = GraphStore.instance.addNode(
      'table_input',
      const Offset(120, 90),
      triggerRun: false,
    );
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const SyphonApp());
    await tester.pumpAndSettle();

    const sequence = [
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
    ];
    Future<void> konami() async {
      for (final key in sequence) {
        await tester.sendKeyDownEvent(key);
        await tester.sendKeyUpEvent(key);
        await tester.pump();
      }
    }

    // 序列完成 → 弹窗询问(此时还没进入)
    await konami();
    await tester.pumpAndSettle();
    expect(find.text('水果忍者'), findsOneWidget);
    final canvas = tester.state<NodeCanvasState>(find.byType(NodeCanvas));
    expect(canvas.ninjaActive, isFalse);

    // 取消:不进入模式,原画布保持
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(canvas.ninjaActive, isFalse);
    expect(GraphStore.instance.nodes.map((n) => n.id), contains(nodeId));

    // 再来一次并确认 → 进入:原画布被暂存,画布清空,忍者层出现
    await konami();
    await tester.pumpAndSettle();
    await tester.tap(find.text('进入'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(canvas.ninjaActive, isTrue);
    expect(find.byKey(const Key('ninja-layer')), findsOneWidget);
    expect(GraphStore.instance.nodes, isEmpty, reason: '进入后是新的空白画布');

    // 模式内:鼠标拖拽只挥刀切连线,画布绝不跟着平移
    // 手势坐标是全局坐标,画布局部坐标 = 全局 - 画布左上角
    final canvasOrigin = tester.getTopLeft(find.byType(NodeCanvas));
    Offset atCanvas(Offset local) => local + canvasOrigin;
    NinjaFruit node(Offset at) => NinjaFruit(
      configId: 'table_input',
      label: '表格输入',
      icon: '▣',
      color: const Color(0xFF10B981),
      position: at,
      velocity: Offset.zero,
      angle: 0,
      spin: 0,
      size: const Size(146, 86),
    );
    final left = node(const Offset(620, 420));
    final right = node(const Offset(1000, 420));
    canvas.ninjaGame.fruits.addAll([left, right]);
    final wire = NinjaWire(
      from: left,
      to: right,
      color: const Color(0xFFF59E0B),
    );
    canvas.ninjaGame.wires.add(wire);
    final panBefore = canvas.canvasPan;
    final gesture = await tester.startGesture(
      atCanvas(const Offset(700, 360)),
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await gesture.moveTo(atCanvas(const Offset(900, 480)));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(wire.cut, isTrue, reason: '刀锋划过的连线被切断');
    expect(canvas.ninjaGame.score, greaterThanOrEqualTo(1));
    expect(canvas.canvasPan, panBefore, reason: '忍者模式下不能拖动画布');

    // 再次输入序列 → 直接退出(不再弹窗),原画布恢复
    await konami();
    await tester.pumpAndSettle();
    expect(find.text('水果忍者'), findsNothing);
    expect(canvas.ninjaActive, isFalse);
    expect(find.byKey(const Key('ninja-layer')), findsNothing);
    expect(
      GraphStore.instance.nodes.map((n) => n.id),
      contains(nodeId),
      reason: '退出后恢复进入前的画布',
    );
  });
}
