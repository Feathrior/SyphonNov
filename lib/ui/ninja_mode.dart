// 彩蛋:水果忍者模式。
//
// 每一"波"抛上来固定的一组节点 + 连线:2 节点 1 连线、3 节点 2 连线、
// 4 节点 3 连线……(链式相连,结构完全固定,不随节点相对位置实时生成),
// 所以切干净就是真的干净。每隔几波会抛一颗"大榴莲"——坐标系输入节点,
// 它总是和几个普通节点一起出现并与之全部相连。
//
// 连线可以切,节点也可以切:节点被切开后立刻爆开消失,属于它的连线一并断开。
// 切中榴莲进入"子弹时间";累计切够 15 颗榴莲会引发剧烈爆炸,清空整个场地。
//
// 计分鼓励连击:短时间窗口内连切,分数按连击数递增,并弹出连击提示。
// 左上角五颗心,漏掉一个节点扣一颗,扣完游戏结束并显示得分。
//
// 物理与命中都在屏幕坐标(画布局部坐标)里做,进入该模式时会把缩放/平移
// 归位到 1/0,所以 flow 坐标与屏幕坐标一致,刀光轨迹可以直接复用。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/color_utils.dart' show parseColor;
import '../models/registry.dart';
import 'canvas_geometry.dart' show bezierSamples, closestSegmentPair;
import 'theme.dart';

/// 两个飞行节点之间的一条连线。
///
/// 折线每帧按两端节点当前位置重算(贴着卡片边缘,形状沿用画布连线),
/// 被切断后改用 [frozen] 定格,两半各自散开。
class NinjaWire {
  NinjaWire({required this.from, required this.to, required this.color});

  final NinjaFruit from;
  final NinjaFruit to;
  final Color color;

  bool cut = false;
  /// 切断后的动画进度(秒)、切点与定格折线(世界坐标)
  double cutT = 0;
  int cutIndex = 0;
  Offset cutPoint = Offset.zero;
  List<Offset> frozen = const [];
}

/// 一个飞上来的"节点"(坐标系输入会变成"大榴莲")
class NinjaFruit {
  NinjaFruit({
    required this.configId,
    required this.label,
    required this.icon,
    required this.color,
    required this.position,
    required this.velocity,
    required this.angle,
    required this.spin,
    required this.size,
    this.isDurian = false,
    this.isBomb = false,
    this.hitsToExplode = 1,
  });

  final String configId;
  final String label;
  final String icon;
  final Color color;
  final Size size;

  /// 大榴莲:坐标系输入,与数个节点一起出现并全部相连
  final bool isDurian;

  /// 炸弹(Package):切到会扣分,并冒烟爆炸
  final bool isBomb;

  /// 大榴莲挨刀次数与"砍多少刀才爆"(15~20 下)
  final int hitsToExplode;
  int hits = 0;
  /// 同一颗榴莲两次挨刀之间的最小间隔(秒):防止快速抖动一次刷满
  double hitCooldown = 0;
  /// 挨刀后的闪动(0~1)
  double hitFlash = 0;

  Offset position;
  Offset velocity;
  double angle;
  double spin;
}

/// 一刀的结果:切中的连线或节点、切点(屏幕坐标)与颜色
typedef NinjaCut = ({
  NinjaWire? wire,
  NinjaFruit? fruit,
  Offset point,
  Color color,
});

/// 切点冒出的浮动文字:连击 "×N 连击" 或炸弹扣分 "-20"
class NinjaPop {
  NinjaPop({required this.at, required this.text, required this.color});

  final Offset at;
  final String text;
  final Color color;
  double life = 0;
  static const double duration = .9;
}

/// 待入场节点(延迟可变,所以用一个可变的小对象)
class _QueuedFruit {
  _QueuedFruit({required this.fruit, required this.delay, this.prev});

  final NinjaFruit fruit;
  double delay;
  final NinjaFruit? prev;
}

/// 忍者模式的模拟:成组生成、抛物线运动、切割判定、生命与连击
class NinjaGame extends ChangeNotifier {
  static const double gravity = 980; // px/s²
  /// 切断的连线两半散开消失的时间(秒)
  static const double wireLife = .6;
  /// 一波最多抛几个节点(链式连线数 = 节点数 - 1)
  static const int maxWaveNodes = 5;
  /// 同屏节点上限
  static const int maxFruits = 12;
  /// 同一波节点之间的错开时间(秒):不必完全同时
  static const double waveStagger = .12;
  /// 每波节点之间的水平间距(px):留足空间才切得到节点之间的连线
  static const double waveGap = 250;
  /// 生命(左上角五颗心)
  static const int maxLives = 5;
  /// 连击窗口(真实秒)
  static const double comboWindow = .85;
  /// 子弹时间:物理放慢到 1/5,画面聚焦到被砍的榴莲上。
  /// 结束条件不是计时,而是那颗榴莲掉出画面或被砍爆。
  static const double bulletTimeScale = .2;
  /// 大榴莲需要挨多少刀才爆(随机 15~20 下)
  static const int durianMinHits = 15;
  static const int durianMaxHits = 20;
  /// 同一颗榴莲两次挨刀的最小间隔(秒)
  static const double durianHitCooldown = .12;
  /// 炸掉一颗榴莲的额外奖励分
  static const int durianExplodeBonus = 50;
  /// 切到炸弹(Package)的扣分
  static const int bombPenalty = 20;

  final List<NinjaFruit> fruits = [];
  final List<NinjaWire> wires = [];
  final List<NinjaPop> pops = [];
  final math.Random _random = math.Random();
  final List<_QueuedFruit> _pending = [];

  int score = 0;
  int lives = maxLives;
  int bestCombo = 0;
  int combo = 0;
  double comboLeft = 0;
  bool gameOver = false;
  /// 子弹时间聚焦的榴莲:非空即处于子弹时间(它掉出画面/被砍爆即结束)
  NinjaFruit? bulletFocus;
  /// 剧烈爆炸次数(每炸掉一颗榴莲 +1)
  int durianExplosions = 0;
  /// 剧烈爆炸次数与位置:画布据此炸出大量粒子
  int explosionSerial = 0;
  Offset explosionAt = Offset.zero;
  /// 炸弹冒烟爆炸次数与位置:画布据此炸出烟团
  int smokeSerial = 0;
  Offset smokeAt = Offset.zero;
  /// 刚掉心时的高亮计时(心形闪一下)
  double livesFlash = 0;

  double width = 0;
  double height = 0;
  double _spawnTimer = 0.6;
  /// 下一波抛几个节点:2 → 3 → 4 → …(到上限后循环)
  int _nextWaveNodes = 2;
  /// 波次序号:用来决定哪一波是"榴莲波"
  int _waveSerial = 0;

  /// 下一波的节点数(测试用:确认波次固定递增)
  @visibleForTesting
  int get nextWaveSize => _nextWaveNodes;

  /// 是否在普通波次里混入炸弹(测试固定结构时可关闭)
  @visibleForTesting
  bool mixBombs = true;

  /// 当前是否处于子弹时间(聚焦的榴莲还在场上)
  bool get bulletTimeActive => bulletFocus != null;

  void reset() {
    fruits.clear();
    wires.clear();
    pops.clear();
    _pending.clear();
    score = 0;
    lives = maxLives;
    bestCombo = 0;
    combo = 0;
    comboLeft = 0;
    gameOver = false;
    bulletFocus = null;
    durianExplosions = 0;
    explosionSerial = 0;
    smokeSerial = 0;
    livesFlash = 0;
    _spawnTimer = 0.6;
    _nextWaveNodes = 2;
    _waveSerial = 0;
  }

  /// 推进一帧。[dt] 为真实秒。
  void update(double dt) {
    if (width <= 0 || height <= 0 || gameOver) return;
    // 连击窗口与提示气泡走真实时间
    if (comboLeft > 0) {
      comboLeft -= dt;
      if (comboLeft <= 0) combo = 0;
    }
    if (livesFlash > 0) livesFlash = math.max(0, livesFlash - dt * 1.6);
    for (final pop in pops) {
      pop.life += dt;
    }
    pops.removeWhere((pop) => pop.life > NinjaPop.duration);

    // 子弹时间:物理与入场一起变慢(玩家有更多时间挥刀)。
    // 聚焦的榴莲掉出画面或被砍爆后自动结束。
    if (bulletFocus != null &&
        !fruits.any((f) => identical(f, bulletFocus))) {
      bulletFocus = null;
    }
    final scaled = bulletTimeActive ? dt * bulletTimeScale : dt;

    _spawnTimer -= scaled;
    if (_spawnTimer <= 0 && fruits.length + _pending.length < maxFruits) {
      _spawnWave();
      _spawnTimer = 1.7 + _random.nextDouble() * .5;
    }
    // 错开入场的节点:到点才真正飞进来,并和同波前一个节点连上
    if (_pending.isNotEmpty) {
      for (final p in _pending) {
        p.delay -= scaled;
      }
      final ready = _pending.where((p) => p.delay <= 0).toList();
      for (final p in ready) {
        _pending.remove(p);
        fruits.add(p.fruit);
        final prev = p.prev;
        if (prev != null && fruits.any((f) => identical(f, prev))) {
          wires.add(NinjaWire(from: prev, to: p.fruit, color: _wireColor()));
        }
      }
    }

    final alive = <NinjaFruit>[];
    for (final f in fruits) {
      f.velocity = f.velocity + Offset(0, gravity * scaled);
      f.position = f.position + f.velocity * scaled;
      f.angle += f.spin * scaled;
      // 榴莲:挨刀间隔计时(走真实时间:子弹时间里能砍得更快)与挨刀闪动
      if (f.hitCooldown > 0) f.hitCooldown = math.max(0, f.hitCooldown - dt);
      if (f.hitFlash > 0) f.hitFlash = math.max(0, f.hitFlash - dt * 4);
      if (f.position.dy - f.size.height > height + 80) {
        // 掉出画面 = 漏掉了 → 扣一颗心;炸弹是"该躲的",掉了不扣
        if (!f.isBomb) _loseLife();
        continue;
      }
      alive.add(f);
    }
    fruits
      ..clear()
      ..addAll(alive);

    // 连线:切开的继续播放两半散开动画;两端节点都在的保留。
    // 绝不会"凭空补线":连线只在这一波节点入场时按固定结构建立。
    wires.removeWhere((w) {
      if (w.cut) {
        w.cutT += scaled;
        return w.cutT > wireLife;
      }
      final hasFrom = fruits.any((f) => identical(f, w.from));
      final hasTo = fruits.any((f) => identical(f, w.to));
      return !hasFrom || !hasTo;
    });
    notifyListeners();
  }

  void _loseLife() {
    if (gameOver) return;
    lives = math.max(0, lives - 1);
    livesFlash = 1;
    combo = 0;
    comboLeft = 0;
    if (lives == 0) gameOver = true;
  }

  /// 抛出一波:[count] 个节点 + (count-1) 条链式连线。
  ///
  /// 每 3 波来一次"榴莲波":一颗坐标系输入(大榴莲)+ 2~3 个普通节点,
  /// 榴莲与它们全部相连,并且总是和它们一起出现。
  void _spawnWave() {
    _waveSerial++;
    final durianWave = _waveSerial % 3 == 0;
    if (durianWave) {
      _spawnDurianWave();
      return;
    }
    final n = _nextWaveNodes.clamp(2, maxWaveNodes);
    _nextWaveNodes = _nextWaveNodes >= maxWaveNodes ? 2 : _nextWaveNodes + 1;
    final span = math.min(width - 240, waveGap * (n - 1));
    final left = (width - span) / 2 + (_random.nextDouble() - .5) * 40;
    final vy = _throwSpeed();
    final dir = _random.nextBool() ? 1.0 : -1.0;
    NinjaFruit? prev;
    for (var i = 0; i < n; i++) {
      final x = n == 1 ? left : left + span * i / (n - 1);
      final fruit = _makeFruit(
        x: x,
        y: height + 60 + i * 12,
        vy: vy,
        dir: dir,
        label: null,
      );
      _pending.add(
        _QueuedFruit(
          fruit: fruit,
          delay: i * waveStagger * (0.8 + _random.nextDouble() * .5),
          prev: prev,
        ),
      );
      prev = fruit;
    }
    // 混一颗炸弹(Package):不参与链式连线,切到要扣分
    if (mixBombs && n >= 3 && _random.nextBool()) {
      _pending.add(
        _QueuedFruit(
          fruit: _makeFruit(
            x: (left + span / 2 + (_random.nextDouble() - .5) * 160).clamp(
              80.0,
              width - 80,
            ),
            y: height + 60,
            vy: vy * (.95 + _random.nextDouble() * .1),
            dir: -dir,
            label: null,
            bomb: true,
          ),
          delay: waveStagger * .5,
          prev: null,
        ),
      );
    }
  }

  /// 榴莲波:一颗大榴莲居中,两侧各 1~2 个普通节点,全部与榴莲相连
  void _spawnDurianWave() {
    final vy = _throwSpeed();
    final dir = _random.nextBool() ? 1.0 : -1.0;
    final centerX = width / 2 + (_random.nextDouble() - .5) * 60;
    final durian = _makeFruit(
      x: centerX,
      y: height + 60,
      vy: vy,
      dir: dir,
      label: null,
      durian: true,
    );
    // 大榴莲先入场,随后两侧节点依次抛出并与它连线
    _pending.add(_QueuedFruit(fruit: durian, delay: 0, prev: null));
    final sides = _random.nextBool() ? [-1, 1, -1] : [-1, 1, 1, -1];
    var delay = waveStagger;
    for (final side in sides) {
      final offset = waveGap * (side < 0 ? -1 : 1) * (1 + delay ~/ 1);
      _pending.add(
        _QueuedFruit(
          fruit: _makeFruit(
            x: (centerX + offset * (0.8 + _random.nextDouble() * .5)).clamp(
              80.0,
              width - 80,
            ),
            y: height + 60,
            vy: vy,
            dir: dir,
            label: null,
          ),
          delay: delay,
          prev: durian,
        ),
      );
      delay += waveStagger * (0.8 + _random.nextDouble() * .6);
    }
  }

  double _throwSpeed() {
    final peak = height * (.5 + _random.nextDouble() * .2);
    return -math.sqrt(2 * gravity * peak);
  }

  NinjaFruit _makeFruit({
    required double x,
    required double y,
    required double vy,
    required double dir,
    required String? label,
    bool durian = false,
    bool bomb = false,
  }) {
    final config = durian
        ? kNodeConfigs.firstWhere(
            (c) => c.id == 'axis_input',
            orElse: () => kNodeConfigs.first,
          )
        : kNodeConfigs[_random.nextInt(kNodeConfigs.length)];
    return NinjaFruit(
      configId: config.id,
      label: bomb ? 'Package' : config.label,
      icon: bomb ? '⧉' : (kCatInfo[config.category.name]?.icon ?? '▣'),
      color: bomb
          ? const Color(0xFF8A9099)
          : _categoryColor(config.category.name),
      position: Offset(x, y),
      // 斜抛:横向速度 = 整波方向 + 个体抖动,再叠一点向中心收拢
      velocity: Offset(
        dir * (50 + _random.nextDouble() * 90) + (width / 2 - x) * .12,
        vy,
      ),
      angle: (_random.nextDouble() - .5) * .5,
      spin: (_random.nextDouble() - .5) * 1.8,
      size: durian ? const Size(210, 120) : const Size(146, 86),
      isDurian: durian,
      isBomb: bomb,
      // 榴莲要砍 15~20 刀才爆
      hitsToExplode: durian
          ? durianMinHits + _random.nextInt(durianMaxHits - durianMinHits + 1)
          : 1,
    );
  }

  /// 连线当前的世界坐标折线:两端贴着节点卡片边缘,形状沿用画布贝塞尔
  List<Offset> wirePath(NinjaWire w) {
    if (w.cut) return w.frozen;
    final a = _edgeAnchor(w.from, w.to.position);
    final b = _edgeAnchor(w.to, w.from.position);
    return bezierSamples(a, b, n: 14);
  }

  /// 从节点中心指向 [toward] 的射线与卡片矩形的交点(已考虑节点自身旋转)
  static Offset _edgeAnchor(NinjaFruit f, Offset toward) {
    final local = _rotate(toward - f.position, -f.angle);
    if (local.distance < .001) return f.position;
    final halfW = f.size.width / 2 + 3;
    final halfH = f.size.height / 2 + 3;
    var s = double.infinity;
    if (local.dx.abs() > 1e-6) s = math.min(s, halfW / local.dx.abs());
    if (local.dy.abs() > 1e-6) s = math.min(s, halfH / local.dy.abs());
    if (!s.isFinite) return f.position;
    return f.position + _rotate(local * s.clamp(0.0, 1.0), f.angle);
  }

  /// 鼠标从 [from] 划到 [to]:返回这一刀切中的连线与节点。
  ///
  /// 节点被切中时立刻消失(靠画布上的大团爆炸粒子表现"炸开"),属于它的
  /// 连线一并断开;切中榴莲进入子弹时间,累计够 15 颗则剧烈爆炸清场。
  List<NinjaCut> slice(Offset from, Offset to, {double threshold = 7}) {
    if (gameOver) return const [];
    if ((to - from).distance < 1) return const [];
    final cuts = <NinjaCut>[];

    // 1) 节点:切中即炸开消失;大榴莲要挨够 15~20 刀才爆
    final blown = <NinjaFruit>[];
    Offset? explosion;
    for (final fruit in fruits) {
      if (!_segmentHitsRotatedRect(from, to, fruit)) continue;
      if (fruit.isBomb) {
        // 炸弹:扣分 + 冒烟爆炸(不算连击,也不扣心)
        blown.add(fruit);
        cuts.add((
          wire: null,
          fruit: fruit,
          point: fruit.position,
          color: fruit.color,
        ));
        _hitBomb(fruit.position);
        continue;
      }
      if (fruit.isDurian) {
        // 挨刀间隔太小不算(防止一次抖动刷满)
        if (fruit.hitCooldown > 0) continue;
        fruit.hitCooldown = durianHitCooldown;
        fruit.hits++;
        fruit.hitFlash = 1;
        // 砍榴莲就进子弹时间(方便把剩下的刀数砍完)
        bulletFocus = fruit;
        cuts.add((
          wire: null,
          fruit: fruit,
          point: fruit.position,
          color: fruit.color,
        ));
        // 连击只认"切到不同节点":同一颗榴莲后续的刀只算伤害
        if (fruit.hits == 1) {
          _registerCut(fruit.position, durian: true);
        } else {
          score += 1;
        }
        if (fruit.hits < fruit.hitsToExplode) {
          // 还没爆:留在场上,连线不断
          pops.add(
            NinjaPop(
              at: fruit.position,
              text: '${fruit.hits}/${fruit.hitsToExplode}',
              color: const Color(0xFF2E7D32),
            ),
          );
          continue;
        }
        // 挨够刀数:剧烈爆炸
        score += durianExplodeBonus;
        pops.add(
          NinjaPop(
            at: fruit.position,
            text: '+$durianExplodeBonus 爆炸!',
            color: const Color(0xFFFF6D00),
          ),
        );
        explosion = fruit.position;
      }
      // 普通节点(或终于爆掉的榴莲):消失 + 挂在它身上的连线一并断开
      blown.add(fruit);
      cuts.add((
        wire: null,
        fruit: fruit,
        point: fruit.position,
        color: fruit.color,
      ));
      if (!fruit.isDurian) _registerCut(fruit.position, durian: false);
      for (final wire in wires) {
        if (wire.cut) continue;
        if (!identical(wire.from, fruit) && !identical(wire.to, fruit)) {
          continue;
        }
        _cutWire(wire, wirePath(wire), 0);
      }
    }
    if (blown.isNotEmpty) {
      fruits.removeWhere((f) => blown.any((b) => identical(b, f)));
      // 还没来得及入场的同波节点:同波连线也就不该再接了
      _pending.removeWhere(
        (p) => p.prev != null && blown.any((b) => identical(b, p.prev)),
      );
    }

    // 2) 连线:切断只加固定 1 分,不进连击(连击只认"短时间切到多个节点")
    for (final wire in wires) {
      if (wire.cut) continue;
      final path = wirePath(wire);
      for (var i = 0; i < path.length - 1; i++) {
        final pair = closestSegmentPair(from, to, path[i], path[i + 1]);
        if (pair.dist > threshold) continue;
        _cutWire(wire, path, i, pair.b);
        cuts.add((wire: wire, fruit: null, point: pair.b, color: wire.color));
        score += 1;
        break;
      }
    }

    // 剧烈爆炸:清空全场(算作被打爆,不扣心)
    if (explosion != null) {
      explosionSerial++;
      durianExplosions++;
      explosionAt = explosion;
      for (final wire in wires) {
        if (!wire.cut) _cutWire(wire, wirePath(wire), 0);
      }
      _pending.clear();
      fruits.clear();
      bulletFocus = null;
    }
    if (cuts.isNotEmpty) notifyListeners();
    return cuts;
  }

  /// 记一次切割:连击窗口内连切会累加连击数,分数按连击递增
  void _registerCut(Offset at, {required bool durian}) {
    combo = comboLeft > 0 ? combo + 1 : 1;
    comboLeft = comboWindow;
    bestCombo = math.max(bestCombo, combo);
    // 基础 1 分 × 连击数;榴莲额外 ×5
    score += combo * (durian ? 5 : 1);
    if (combo >= 2) {
      pops.add(
        NinjaPop(at: at, text: '×$combo 连击', color: const Color(0xFFFFC107)),
      );
      if (pops.length > 12) pops.removeAt(0);
    }
  }

  /// 切到炸弹:扣分 + 冒烟爆炸(不延长连击,也不扣心)
  void _hitBomb(Offset at) {
    score = math.max(0, score - bombPenalty);
    combo = 0;
    comboLeft = 0;
    pops.add(
      NinjaPop(
        at: at,
        text: '-$bombPenalty',
        color: const Color(0xFFD32F2F),
      ),
    );
    if (pops.length > 12) pops.removeAt(0);
    smokeSerial++;
    smokeAt = at;
  }

  void _cutWire(NinjaWire wire, List<Offset> path, int index, [Offset? at]) {
    wire.cut = true;
    wire.cutT = 0;
    wire.cutIndex = index;
    wire.cutPoint = at ?? path[index];
    wire.frozen = path;
  }

  /// 刀锋线段是否切中节点的卡片矩形(把线段反向旋转到节点局部坐标)
  static bool _segmentHitsRotatedRect(Offset from, Offset to, NinjaFruit f) {
    final cos = math.cos(-f.angle);
    final sin = math.sin(-f.angle);
    Offset toLocal(Offset p) {
      final v = p - f.position;
      return Offset(v.dx * cos - v.dy * sin, v.dx * sin + v.dy * cos);
    }

    final a = toLocal(from);
    final b = toLocal(to);
    final rect = Rect.fromCenter(
      center: Offset.zero,
      width: f.size.width,
      height: f.size.height,
    );
    if (rect.contains(a) || rect.contains(b)) return true;
    final corners = [
      rect.topLeft,
      rect.topRight,
      rect.bottomRight,
      rect.bottomLeft,
    ];
    for (var i = 0; i < 4; i++) {
      if (_segmentsIntersect(a, b, corners[i], corners[(i + 1) % 4])) {
        return true;
      }
    }
    return false;
  }

  static bool _segmentsIntersect(Offset p1, Offset p2, Offset p3, Offset p4) {
    double cross(Offset a, Offset b) => a.dx * b.dy - a.dy * b.dx;
    final d1 = cross(p4 - p3, p1 - p3);
    final d2 = cross(p4 - p3, p2 - p3);
    final d3 = cross(p2 - p1, p3 - p1);
    final d4 = cross(p2 - p1, p4 - p1);
    return ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0));
  }

  int get flying => fruits.length;

  Color _wireColor() {
    final values = kSocketColors.values.toList();
    return parseColor(values[_random.nextInt(values.length)]);
  }
}

Offset _rotate(Offset p, double angle) {
  final cos = math.cos(angle);
  final sin = math.sin(angle);
  return Offset(p.dx * cos - p.dy * sin, p.dx * sin + p.dy * cos);
}

Color _categoryColor(String name) {
  final hex = kCatInfo[name]?.color ?? '#7C8DB5';
  final value = int.tryParse(hex.replaceFirst('#', '0xFF'));
  return Color(value ?? 0xFF7C8DB5);
}

/// 忍者模式的绘制层:节点卡片(榴莲带尖刺)、连线、HUD(心/分数/连击/子弹时间)
class NinjaPainter extends CustomPainter {
  final NinjaGame game;
  final SyphonTheme theme;

  /// 摄像机偏移(子弹时间把画面拉到榴莲附近);HUD 不受它影响
  final Offset camera;

  NinjaPainter({required this.game, required this.theme, this.camera = Offset.zero})
    : super(repaint: game);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(camera.dx, camera.dy);
    // 先画连线(在节点下层,像真实连线一样从卡片边缘接出),再画节点卡片
    for (final wire in game.wires) {
      _paintWire(canvas, game.wirePath(wire), wire);
    }
    for (final f in game.fruits) {
      canvas.save();
      canvas.translate(f.position.dx, f.position.dy);
      canvas.rotate(f.angle);
      // 挨刀瞬间抖一下
      if (f.hitFlash > 0) {
        canvas.translate(f.hitFlash * 4, -f.hitFlash * 3);
      }
      final rect = Rect.fromCenter(
        center: Offset.zero,
        width: f.size.width,
        height: f.size.height,
      );
      if (f.isDurian) _paintDurianSpikes(canvas, rect, f);
      _paintCard(canvas, rect, f, 1);
      if (f.isBomb) _paintBombFuse(canvas, rect);
      if (f.isDurian) _paintDurianDamage(canvas, rect, f);
      canvas.restore();
    }
    if (game.bulletTimeActive) _paintBulletTime(canvas, size);
    for (final pop in game.pops) {
      _paintPop(canvas, pop);
    }
    canvas.restore();
    // HUD 固定在屏幕上,不跟着摄像机偏移
    _paintHud(canvas, size);
    if (game.gameOver) _paintGameOver(canvas, size);
  }

  /// 大榴莲:卡片四周一圈尖刺
  void _paintDurianSpikes(Canvas canvas, Rect rect, NinjaFruit f) {
    const spikes = 22;
    final path = Path();
    final center = rect.center;
    final rx = rect.width / 2;
    final ry = rect.height / 2;
    for (var i = 0; i < spikes * 2; i++) {
      final t = i / (spikes * 2) * 2 * math.pi;
      final long = i.isEven;
      final k = long ? 1.16 : 1.0;
      final p = Offset(
        center.dx + math.cos(t) * rx * k,
        center.dy + math.sin(t) * ry * k,
      );
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    path.close();
    canvas.drawPath(path, Paint()..color = const Color(0xFF2E7D32));
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = const Color(0xFF1B5E20),
    );
  }

  /// 榴莲的"挨刀进度":底部一条进度条 + 剩余刀数
  void _paintDurianDamage(Canvas canvas, Rect rect, NinjaFruit f) {
    final progress = (f.hits / f.hitsToExplode).clamp(0.0, 1.0);
    final bar = Rect.fromLTWH(
      rect.left + 12,
      rect.bottom - 12,
      rect.width - 24,
      6,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(bar, const Radius.circular(3)),
      Paint()..color = Colors.white.withValues(alpha: .22),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(bar.left, bar.top, bar.width * progress, bar.height),
        const Radius.circular(3),
      ),
      Paint()
        ..color = Color.lerp(
          const Color(0xFFFDD835),
          const Color(0xFFFF1744),
          progress,
        )!,
    );
    _text(
      canvas,
      '${f.hits}/${f.hitsToExplode} 刀',
      Offset(rect.left + 12, rect.bottom - 34),
      rect.width - 24,
      TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w800,
        color: Color.lerp(
          const Color(0xFFFDD835),
          const Color(0xFFFF1744),
          progress,
        )!,
      ),
    );
  }

  /// 炸弹(Package)的引信:右上角一根斜线 + 冒火星,提示"别切"
  void _paintBombFuse(Canvas canvas, Rect rect) {
    final start = Offset(rect.right - 6, rect.top + 6);
    final end = Offset(rect.right + 12, rect.top - 12);
    canvas.drawLine(
      start,
      end,
      Paint()
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..color = const Color(0xFF5D4037),
    );
    canvas.drawCircle(
      end,
      5.5,
      Paint()
        ..color = const Color(0xFFFFB300)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawCircle(end, 2.6, Paint()..color = const Color(0xFFFFF176));
  }

  void _paintWire(Canvas canvas, List<Offset> path, NinjaWire w) {
    if (!w.cut) {
      _stroke(canvas, path, w.color, 1);
      return;
    }
    final fade = (1 - w.cutT / NinjaGame.wireLife).clamp(0.0, 1.0);
    if (fade <= 0 || path.length < 2) return;
    final i = w.cutIndex.clamp(0, path.length - 2);
    final dir = path[i + 1] - path[i];
    final len = dir.distance;
    final normal = len < .001
        ? const Offset(0, 1)
        : Offset(-dir.dy / len, dir.dx / len);
    final spread = 26 * fade;
    // 断开处左右两半:沿切点法向分开,并各自轻微反转,像被刀带开
    _stroke(
      canvas,
      _transformHalf(
        [...path.sublist(0, i + 1), w.cutPoint],
        w.cutPoint,
        normal * spread,
        .35 * fade,
      ),
      w.color,
      fade,
    );
    _stroke(
      canvas,
      _transformHalf(
        [w.cutPoint, ...path.sublist(i + 1)],
        w.cutPoint,
        -normal * spread,
        -.35 * fade,
      ),
      w.color,
      fade,
    );
  }

  /// 绕 [pivot] 旋转 [rot],再整体平移 [offset]
  List<Offset> _transformHalf(
    List<Offset> pts,
    Offset pivot,
    Offset offset,
    double rot,
  ) {
    final cos = math.cos(rot);
    final sin = math.sin(rot);
    return [
      for (final p in pts)
        () {
          final v = p - pivot;
          return Offset(v.dx * cos - v.dy * sin, v.dx * sin + v.dy * cos) +
              pivot +
              offset;
        }(),
    ];
  }

  void _stroke(Canvas canvas, List<Offset> pts, Color color, double alpha) {
    if (pts.length < 2) return;
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (final p in pts.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    // 不加深色描边:连线本身就是"要切的目标",描边只会让画面显脏
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 3.6
        ..color = color.withValues(alpha: alpha),
    );
  }

  void _paintCard(Canvas canvas, Rect rect, NinjaFruit f, double alpha) {
    if (alpha <= 0) return;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(9));
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = (f.isBomb ? const Color(0xFF37474F) : theme.bgNode)
            .withValues(alpha: .96 * alpha),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = (f.isDurian
                ? const Color(0xFF2E7D32)
                : (f.isBomb ? const Color(0xFFFF7043) : theme.strokeStrong))
            .withValues(alpha: .9 * alpha),
    );
    // 标题带
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTWH(rect.left, rect.top, rect.width, 24),
        topLeft: const Radius.circular(9),
        topRight: const Radius.circular(9),
      ),
      Paint()..color = f.color.withValues(alpha: .95 * alpha),
    );
    _text(
      canvas,
      '${f.icon}  ${f.label}',
      Offset(rect.left + 9, rect.top + 5),
      rect.width - 18,
      TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: Colors.white.withValues(alpha: alpha),
      ),
    );
    // 参数示意
    for (var i = 0; i < 2; i++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            rect.left + 12,
            rect.top + 38 + i * 18,
            rect.width - 24,
            9,
          ),
          const Radius.circular(4),
        ),
        Paint()..color = theme.stroke.withValues(alpha: .85 * alpha),
      );
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(rect.left + 12, rect.bottom - 22, rect.width * .42, 9),
        const Radius.circular(4),
      ),
      Paint()..color = f.color.withValues(alpha: .35 * alpha),
    );
    if (f.isDurian) {
      _text(
        canvas,
        '坐标系输入',
        Offset(rect.left + 12, rect.bottom - 40),
        rect.width - 24,
        TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: const Color(0xFF2E7D32).withValues(alpha: alpha),
        ),
      );
    }
    if (f.isBomb) {
      _text(
        canvas,
        '炸弹 · 切到扣分',
        Offset(rect.left + 12, rect.bottom - 40),
        rect.width - 24,
        TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w800,
          color: const Color(0xFFFF7043).withValues(alpha: alpha),
        ),
      );
    }
  }

  /// 子弹时间:轻微冷色调压暗 + 两侧速度线
  void _paintBulletTime(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0x00000000),
            const Color(0x335FC8FF),
          ],
        ).createShader(rect),
    );
    _text(
      canvas,
      '子弹时间',
      Offset(size.width / 2 - 26, 26),
      80,
      const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w800,
        color: Color(0xFF0B6E99),
      ),
    );
  }

  /// 切点浮动文字(连击 "×N 连击" / 炸弹 "-20"):先放大后淡出
  void _paintPop(Canvas canvas, NinjaPop pop) {
    final t = (pop.life / NinjaPop.duration).clamp(0.0, 1.0);
    final appear = Curves.easeOutBack.transform(math.min(1, t * 3));
    final alpha = (1 - t).clamp(0.0, 1.0);
    final style = TextStyle(
      fontSize: 20 * (0.7 + .3 * appear),
      fontWeight: FontWeight.w900,
      color: pop.color.withValues(alpha: alpha),
      shadows: [
        Shadow(
          color: Colors.black.withValues(alpha: .35 * alpha),
          blurRadius: 6,
        ),
      ],
    );
    final painter = TextPainter(
      text: TextSpan(text: pop.text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      pop.at - Offset(painter.width / 2, painter.height + 12 + 18 * t),
    );
  }

  /// HUD:左上角五颗心 + 分数/连击/榴莲进度
  void _paintHud(Canvas canvas, Size size) {
    const heartSize = 20.0;
    for (var i = 0; i < NinjaGame.maxLives; i++) {
      final alive = i < game.lives;
      final rect = Rect.fromLTWH(20 + i * (heartSize + 6), 16, heartSize, heartSize);
      // 刚掉的那颗:闪一下
      final flash = (!alive && game.lives == i && game.livesFlash > 0)
          ? game.livesFlash
          : 0.0;
      _paintHeart(
        canvas,
        rect,
        alive: alive,
        highlight: flash,
      );
    }
    final scoreStyle = TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w800,
      color: theme.text.withValues(alpha: .9),
    );
    _text(
      canvas,
      '得分 ${game.score}',
      Offset(20, 44),
      200,
      scoreStyle,
    );
    if (game.combo >= 2) {
      _text(
        canvas,
        '连击 ×${game.combo}',
        Offset(20, 66),
        200,
        TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w800,
          color: const Color(0xFFFF7043),
        ),
      );
    }
    _text(
      canvas,
      '爆炸 ${game.durianExplosions} 次',
      Offset(20, game.combo >= 2 ? 88 : 66),
      200,
      TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: const Color(0xFF2E7D32).withValues(alpha: .9),
      ),
    );

    const hint = '按住左键划过连线或节点,把它们一刀两断 · ↑↑↓↓←→←→ 退出';
    final painter = TextPainter(
      text: TextSpan(
        text: hint,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: theme.textDim.withValues(alpha: .85),
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: size.width - 40);
    painter.paint(
      canvas,
      Offset((size.width - painter.width) / 2, size.height - 34),
    );
  }

  void _paintHeart(
    Canvas canvas,
    Rect rect, {
    required bool alive,
    required double highlight,
  }) {
    final path = Path();
    final w = rect.width;
    final h = rect.height;
    final cx = rect.left + w / 2;
    final top = rect.top + h * .28;
    path.moveTo(cx, rect.bottom);
    path.cubicTo(
      rect.left - w * .18,
      rect.top + h * .58,
      rect.left + w * .06,
      top - h * .22,
      cx,
      top,
    );
    path.cubicTo(
      rect.right - w * .06,
      top - h * .22,
      rect.right + w * .18,
      rect.top + h * .58,
      cx,
      rect.bottom,
    );
    path.close();
    if (alive) {
      canvas.drawPath(path, Paint()..color = const Color(0xFFE53935));
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = const Color(0xFF8E1F1B),
      );
    } else {
      final color = highlight > 0
          ? Color.lerp(
              const Color(0x33E53935),
              const Color(0xFFFF1744),
              highlight,
            )!
          : const Color(0x33E53935);
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = highlight > 0 ? 2.4 : 1.6
          ..color = color,
      );
    }
  }

  void _paintGameOver(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Colors.black.withValues(alpha: .45),
    );
    final panel = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: 320,
      height: 190,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(panel, const Radius.circular(12)),
      Paint()..color = theme.bgSurface,
    );
    _text(
      canvas,
      '游戏结束',
      Offset(panel.left + 24, panel.top + 22),
      panel.width - 48,
      TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w900,
        color: theme.text,
      ),
    );
    _text(
      canvas,
      '得分 ${game.score}',
      Offset(panel.left + 24, panel.top + 62),
      panel.width - 48,
      TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w800,
        color: theme.text,
      ),
    );
    _text(
      canvas,
      '最高连击 ×${game.bestCombo}',
      Offset(panel.left + 24, panel.top + 94),
      panel.width - 48,
      TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: theme.textDim,
      ),
    );
    _text(
      canvas,
      '↑↑↓↓←→←→ 退出忍者模式',
      Offset(panel.left + 24, panel.top + 128),
      panel.width - 48,
      TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: theme.textFaint,
      ),
    );
  }

  void _text(
    Canvas canvas,
    String text,
    Offset at,
    double maxWidth,
    TextStyle style,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
    painter.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant NinjaPainter old) =>
      old.game != game || old.theme != theme || old.camera != camera;
}
