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
      // 播放完散开动画后移除(期间可能有新一波入场,所以只查这一条)
      for (var i = 0; i < 60; i++) {
        t.game.update(1 / 60);
      }
      expect(t.game.wires.contains(t.wire), isFalse);
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

    test('每一波固定成组:2 节点 1 连线、3 节点 2 连线…且切完不会补线', () {
      final game = NinjaGame()
        ..width = 1600
        ..height = 6000
        // 关掉炸弹:只抛普通波次,便于核对固定结构
        ..mixBombs = false;
      // 等到抛完两波(2 节点 + 3 节点 = 5 个节点)
      var frames = 0;
      while (game.fruits.length < 5 && frames < 60 * 30) {
        game.update(1 / 60);
        frames++;
      }
      expect(game.fruits, hasLength(5));
      // 第一波 2 节点 1 连线;第二波 3 节点 2 连线 → 共 3 条
      expect(game.wires, hasLength(3));
      final f = game.fruits;
      bool linked(NinjaFruit a, NinjaFruit b) => game.wires.any(
        (w) =>
            (identical(w.from, a) && identical(w.to, b)) ||
            (identical(w.from, b) && identical(w.to, a)),
      );
      expect(linked(f[0], f[1]), isTrue, reason: '第一波:2 节点 1 连线');
      expect(linked(f[2], f[3]), isTrue, reason: '第二波:链式第一段');
      expect(linked(f[3], f[4]), isTrue, reason: '第二波:链式第二段');
      expect(linked(f[1], f[2]), isFalse, reason: '跨波不连线');

      // 全部切开后:老节点之间不会再冒出新线
      for (final w in game.wires.toList()) {
        final path = game.wirePath(w);
        final mid = path[path.length ~/ 2];
        game.slice(Offset(mid.dx, mid.dy - 30), Offset(mid.dx, mid.dy + 30));
      }
      expect(game.wires.where((w) => !w.cut), isEmpty);
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

    test('波次节点数递增:下一波比上一波多一个(到上限循环)', () {
      final game = NinjaGame()
        ..width = 1600
        ..height = 8000;
      // 同一波节点错开入场,所以直接看"下一波规模"计数器
      expect(game.nextWaveSize, 2);
      // 首波在 0.6s 后抛出 → 抛出后排到 3
      for (var i = 0; i < 45; i++) {
        game.update(1 / 60);
      }
      expect(game.fruits, isNotEmpty);
      expect(game.nextWaveSize, 3, reason: '抛出第一波(2 节点)后排到 3');
      for (var i = 0; i < 60 * 3; i++) {
        game.update(1 / 60);
      }
      expect(game.nextWaveSize, 4);
      expect(game.nextWaveSize, lessThanOrEqualTo(NinjaGame.maxWaveNodes));
    });

    test('线节点都可以切:切中节点立刻爆开消失,并带走属于它的连线', () {
      final game = NinjaGame()
        ..width = 800
        ..height = 600;
      final a = nodeAt(const Offset(240, 300));
      final b = nodeAt(const Offset(640, 300));
      game.fruits.addAll([a, b]);
      final wire = NinjaWire(from: a, to: b, color: const Color(0xFFF59E0B));
      game.wires.add(wire);

      // 一刀竖直划过节点 a
      final cuts = game.slice(
        const Offset(240, 180),
        const Offset(240, 420),
      );
      expect(cuts, hasLength(1));
      expect(cuts.single.fruit, same(a));
      expect(game.fruits, isNot(contains(a)), reason: '节点被切中后立刻消失(爆开)');
      expect(game.fruits, contains(b));
      expect(
        wire.cut,
        isTrue,
        reason: '节点被切开后,挂在它身上的连线一并断开',
      );
    });

    test('随时间入场时连线只在入场瞬间建立', () {
      final game = NinjaGame()
        ..width = 1600
        ..height = 2400;
      // 画布够高:节点不会很快落回画面外
      for (var i = 0; i < 60 * 4; i++) {
        game.update(1 / 60);
      }
      expect(game.wires, isNotEmpty);
      for (final w in game.wires) {
        expect(identical(w.from, w.to), isFalse);
        expect(game.fruits, contains(w.from));
        expect(game.fruits, contains(w.to));
      }
      // 每波节点数 N → 该波连线数 N-1,场上总连线数 < 节点数
      expect(game.wires.length, lessThan(game.fruits.length));
    });

    test('漏掉节点扣一颗心,扣完游戏结束且不再抛新节点', () {
      final game = NinjaGame()
        ..width = 800
        ..height = 600;
      expect(game.lives, NinjaGame.maxLives);
      // 连抛 5 个直接掉出画面(速度向下)
      for (var i = 0; i < NinjaGame.maxLives; i++) {
        final fruit = nodeAt(Offset(200.0 + i * 60, 700))
          ..velocity = const Offset(0, 400);
        game.fruits.add(fruit);
      }
      for (var i = 0; i < 60 * 6 && !game.gameOver; i++) {
        game.update(1 / 60);
      }
      expect(game.gameOver, isTrue, reason: '扣完五颗心就结束');
      expect(game.lives, 0);
      final fruitsAtEnd = game.fruits.length;
      for (var i = 0; i < 60 * 5; i++) {
        game.update(1 / 60);
      }
      expect(game.fruits.length, lessThanOrEqualTo(fruitsAtEnd));
      expect(game.fruits, isEmpty, reason: '结束后不再抛新节点');
    });

    test('连击:窗口内连切累加连击数,分数按连击递增', () {
      final game = NinjaGame()
        ..width = 800
        ..height = 600;
      final a = nodeAt(const Offset(200, 300));
      final b = nodeAt(const Offset(400, 300));
      final c = nodeAt(const Offset(600, 300));
      game.fruits.addAll([a, b, c]);
      // 依次切三个(每次 0.1s,仍在连击窗口内)
      game.slice(const Offset(200, 180), const Offset(200, 420));
      expect(game.combo, 1);
      expect(game.score, 1);
      game.update(.1);
      game.slice(const Offset(400, 180), const Offset(400, 420));
      expect(game.combo, 2);
      expect(game.score, 1 + 2, reason: '连击 2 → 得 2 分');
      game.update(.1);
      game.slice(const Offset(600, 180), const Offset(600, 420));
      expect(game.combo, 3);
      expect(game.score, 1 + 2 + 3);
      expect(game.bestCombo, 3);
      expect(game.pops, isNotEmpty, reason: '连击要有弹出提示');
      // 超过窗口后连击清零
      game.update(NinjaGame.comboWindow + .1);
      expect(game.combo, 0);
    });

    test('一颗榴莲要挨 15~20 刀才爆:中途不消失、连线不断', () {
      // 画布够高:测试期间榴莲不会因为重力掉出画面
      final game = NinjaGame()
        ..width = 800
        ..height = 6000;
      final durian = NinjaFruit(
        configId: 'axis_input',
        label: '坐标系输入',
        icon: '▦',
        color: const Color(0xFF22C55E),
        position: const Offset(400, 300),
        velocity: Offset.zero,
        angle: 0,
        spin: 0,
        size: const Size(210, 120),
        isDurian: true,
        hitsToExplode: 17,
      );
      final other = nodeAt(const Offset(700, 300));
      game.fruits.addAll([durian, other]);
      final wire = NinjaWire(
        from: durian,
        to: other,
        color: const Color(0xFFF59E0B),
      );
      game.wires.add(wire);

      // 第一刀:进子弹时间、记连击、留血(不消失)
      game.slice(const Offset(400, 180), const Offset(400, 420));
      expect(durian.hits, 1);
      expect(game.bulletTimeActive, isTrue, reason: '砍榴莲进入子弹时间');
      expect(game.combo, 1);
      expect(game.fruits, contains(durian), reason: '没砍够刀数不能爆');
      expect(wire.cut, isFalse, reason: '榴莲还活着,连线不断');

      // 后续刀数:过了冷却才计数,且不再涨连击(连击只认切到不同节点)
      final comboAfterFirst = game.combo;
      for (var i = 1; i < 17; i++) {
        game.update(NinjaGame.durianHitCooldown + .01);
        // 每次都对着榴莲当前位置下刀(它在往下掉)
        game.slice(
          Offset(durian.position.dx, durian.position.dy - 60),
          Offset(durian.position.dx, durian.position.dy + 60),
        );
      }
      expect(durian.hits, 17);
      expect(
        game.combo,
        lessThanOrEqualTo(comboAfterFirst),
        reason: '同一颗榴莲反复挨刀不算连击',
      );
      expect(game.bestCombo, 1, reason: '只有第一刀算一次切割');
      expect(game.explosionSerial, 1, reason: '第 17 刀剧烈爆炸');
      expect(game.durianExplosions, 1);
      expect(wire.cut, isTrue, reason: '爆掉的榴莲连线一并断开');
      expect(game.fruits, isEmpty, reason: '剧烈爆炸清空全场');
    });

    test('砍榴莲的刀数上限在 15~20 之间', () {
      final game = NinjaGame()
        ..width = 1600
        ..height = 6000;
      // 抛到榴莲波(每 3 波一次)
      var frames = 0;
      NinjaFruit? durian;
      while (durian == null && frames < 60 * 40) {
        game.update(1 / 60);
        frames++;
        durian = game.fruits.where((f) => f.isDurian).firstOrNull;
      }
      expect(durian, isNotNull, reason: '每隔几波会抛一颗大榴莲');
      expect(
        durian!.hitsToExplode,
        inInclusiveRange(NinjaGame.durianMinHits, NinjaGame.durianMaxHits),
      );
      // 同一波的普通节点错开一点点入场:等它们都进来再看连线
      for (var i = 0; i < 60; i++) {
        game.update(1 / 60);
      }
      // 榴莲波:榴莲与若干普通节点相连
      final linked = game.wires
          .where(
            (w) => identical(w.from, durian) || identical(w.to, durian),
          )
          .length;
      expect(linked, greaterThanOrEqualTo(2), reason: '榴莲与数个节点全部相连');
    });

    test('子弹时间:聚焦到榴莲上,榴莲掉出画面/被砍爆后结束', () {
      final game = NinjaGame()
        ..width = 800
        ..height = 600;
      final durian = NinjaFruit(
        configId: 'axis_input',
        label: '坐标系输入',
        icon: '▦',
        color: const Color(0xFF22C55E),
        position: const Offset(400, 200),
        velocity: Offset.zero,
        angle: 0,
        spin: 0,
        size: const Size(210, 120),
        isDurian: true,
        hitsToExplode: 15,
      );
      game.fruits.add(durian);
      expect(game.bulletTimeActive, isFalse);
      game.slice(const Offset(400, 100), const Offset(400, 320));
      expect(game.bulletTimeActive, isTrue);
      expect(game.bulletFocus, same(durian), reason: '聚焦到被砍的这颗榴莲');

      // 物理放慢到 1/5:同样真实时间内的位移明显更小
      final probe = nodeAt(const Offset(100, 100))
        ..velocity = const Offset(0, -600);
      game.fruits.add(probe);
      final slowBefore = probe.position;
      game.update(.1);
      final slowMoved = (probe.position - slowBefore).dy;
      // 让榴莲掉出画面 → 子弹时间结束
      durian.position = const Offset(400, 800);
      durian.velocity = const Offset(0, 400);
      for (var i = 0; i < 120 && game.bulletTimeActive; i++) {
        game.update(1 / 60);
      }
      expect(game.bulletTimeActive, isFalse, reason: '榴莲掉下去后子弹时间结束');
      expect(game.bulletFocus, isNull);

      // 正常速度下同样时间的位移更大(对照组)
      final fastBefore = probe.position;
      game.update(.1);
      final fastMoved = (probe.position - fastBefore).dy;
      expect(slowMoved.abs(), lessThan(fastMoved.abs()));
    });

    test('炸弹:切到扣分并冒烟,漏掉不扣心', () {
      final game = NinjaGame()
        ..width = 800
        ..height = 600;
      final bomb = NinjaFruit(
        configId: 'table_input',
        label: 'Package',
        icon: '⧉',
        color: const Color(0xFF8A9099),
        position: const Offset(400, 300),
        velocity: Offset.zero,
        angle: 0,
        spin: 0,
        size: const Size(146, 86),
        isBomb: true,
      );
      game.fruits.add(bomb);
      game.score = 50;
      game.slice(const Offset(400, 240), const Offset(400, 360));
      expect(game.score, 50 - NinjaGame.bombPenalty, reason: '切到炸弹扣分');
      expect(game.smokeSerial, 1, reason: '炸弹要冒烟爆炸');
      expect(game.fruits, isNot(contains(bomb)));

      // 漏掉炸弹不扣心(只跑半秒:此时还没有普通节点落回画面外)
      final missed = NinjaFruit(
        configId: 'table_input',
        label: 'Package',
        icon: '⧉',
        color: const Color(0xFF8A9099),
        position: const Offset(120, 700),
        velocity: const Offset(0, 400),
        angle: 0,
        spin: 0,
        size: const Size(146, 86),
        isBomb: true,
      );
      game.fruits.add(missed);
      final lives = game.lives;
      for (var i = 0; i < 30; i++) {
        game.update(1 / 60);
      }
      expect(game.fruits, isNot(contains(missed)), reason: '炸弹已掉出画面');
      expect(game.lives, lives, reason: '炸弹是躲开的目标,漏掉不扣心');
    });

    test('节点之间留出足够间距:同波相邻节点中心相距不小于 200px', () {
      final game = NinjaGame()
        ..width = 1400
        ..height = 3000
        ..mixBombs = false;
      // 等到第二个节点刚入场:此时两个节点的水平间距就是入场时的间距
      var frames = 0;
      while (game.fruits.length < 2 && frames < 60 * 20) {
        game.update(1 / 60);
        frames++;
      }
      expect(game.fruits, hasLength(2));
      expect(
        (game.fruits[0].position - game.fruits[1].position).dx.abs(),
        greaterThanOrEqualTo(200),
        reason: '节点之间要留够空间,才切得到它们之间的连线',
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
