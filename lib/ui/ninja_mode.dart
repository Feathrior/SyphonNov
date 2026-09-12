// 彩蛋:水果忍者模式。节点以抛物线飞入,节点之间随机连出若干条连线,
// 鼠标划过连线即可把它一刀两断(节点本体切不动)。
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

/// 一个飞上来的"节点"
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
  });

  final String configId;
  final String label;
  final String icon;
  final Color color;
  final Size size;

  Offset position;
  Offset velocity;
  double angle;
  double spin;
}

/// 一刀的结果:切断的连线、切点(屏幕坐标)与连线颜色
typedef NinjaCut = ({NinjaWire wire, Offset point, Color color});

/// 忍者模式的模拟:生成、抛物线运动、连线切割判定
class NinjaGame extends ChangeNotifier {
  static const double gravity = 980; // px/s²
  /// 切断的连线两半散开消失的时间(秒)
  static const double wireLife = .6;
  /// 同屏最多几条连线(节点数量上限内保持可玩)
  static const int maxWires = 6;

  final List<NinjaFruit> fruits = [];
  final List<NinjaWire> wires = [];
  final math.Random _random = math.Random();

  int score = 0;
  double width = 0;
  double height = 0;
  double _spawnTimer = 0.6;
  double _wireTimer = 0.9;

  /// 满场节点数量上限(性能与可玩性平衡)
  static const int _maxFruits = 7;

  void reset() {
    fruits.clear();
    wires.clear();
    score = 0;
    _spawnTimer = 0.6;
    _wireTimer = 0.9;
  }

  /// 推进一帧。[dt] 为秒。
  void update(double dt) {
    if (width <= 0 || height <= 0) return;
    _spawnTimer -= dt;
    if (_spawnTimer <= 0 && fruits.length < _maxFruits) {
      _spawn();
      _spawnTimer = .45 + _random.nextDouble() * .55;
    }
    // 节点掉光时也要继续连出新线:定时在现有节点之间随机补一条
    _wireTimer -= dt;
    if (_wireTimer <= 0) {
      _wireTimer = 1.1 + _random.nextDouble() * .7;
      _linkRandomPair();
    }

    final alive = <NinjaFruit>[];
    for (final f in fruits) {
      f.velocity = f.velocity + Offset(0, gravity * dt);
      f.position = f.position + f.velocity * dt;
      f.angle += f.spin * dt;
      if (f.position.dy - f.size.height > height + 80) {
        // 掉出画面(抛物线回落)后移除
        continue;
      }
      alive.add(f);
    }
    fruits
      ..clear()
      ..addAll(alive);

    // 连线:切开的继续播放两半散开动画;两端节点都在的保留
    wires.removeWhere((w) {
      if (w.cut) {
        w.cutT += dt;
        return w.cutT > wireLife;
      }
      final hasFrom = fruits.any((f) => identical(f, w.from));
      final hasTo = fruits.any((f) => identical(f, w.to));
      return !hasFrom || !hasTo;
    });
    notifyListeners();
  }

  void _spawn() {
    final config = kNodeConfigs[_random.nextInt(kNodeConfigs.length)];
    final color = _categoryColor(config.category.name);
    final x = 80 + _random.nextDouble() * math.max(1, width - 160);
    // 目标最高点约为画布高度的 50%~75%,由 vy = -sqrt(2*g*h) 反推
    final peak = height * (.5 + _random.nextDouble() * .25);
    final vy = -math.sqrt(2 * gravity * peak);
    final vx = (width / 2 - x) * .35;
    final fruit = NinjaFruit(
      configId: config.id,
      label: config.label,
      icon: kCatInfo[config.category.name]?.icon ?? '▣',
      color: color,
      position: Offset(x, height + 60),
      velocity: Offset(vx, vy),
      angle: (_random.nextDouble() - .5) * .6,
      spin: (_random.nextDouble() - .5) * 2.4,
      size: const Size(146, 86),
    );
    // 先与已有节点连线,再把新节点加进去(避免连到自己)
    _linkToExisting(fruit);
    fruits.add(fruit);
  }

  /// 新节点随机与场上 1~2 个节点相连(节点之间连出连线,而不是节点自带连线)
  void _linkToExisting(NinjaFruit fruit) {
    final others = fruits.toList();
    if (others.isEmpty) return;
    final links = 1 + _random.nextInt(2);
    for (var i = 0; i < links; i++) {
      if (_liveWireCount >= maxWires) return;
      final other = others[_random.nextInt(others.length)];
      if (_hasWire(fruit, other)) continue;
      wires.add(NinjaWire(from: fruit, to: other, color: _wireColor()));
    }
  }

  /// 在场上任意两个节点之间补一条连线(节点各自在动,连线一直有新目标)
  void _linkRandomPair() {
    if (_liveWireCount >= maxWires) return;
    final live = fruits.toList();
    if (live.length < 2) return;
    for (var attempt = 0; attempt < 8; attempt++) {
      final a = live[_random.nextInt(live.length)];
      final b = live[_random.nextInt(live.length)];
      if (identical(a, b) || _hasWire(a, b)) continue;
      wires.add(NinjaWire(from: a, to: b, color: _wireColor()));
      return;
    }
  }

  int get _liveWireCount => wires.where((w) => !w.cut).length;

  bool _hasWire(NinjaFruit a, NinjaFruit b) => wires.any(
    (w) =>
        (identical(w.from, a) && identical(w.to, b)) ||
        (identical(w.from, b) && identical(w.to, a)),
  );

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

  /// 鼠标从 [from] 划到 [to]:返回本刀切断的连线(供调用方生成爆裂粒子)。
  ///
  /// 判定用"上次指针位置 → 本次位置"这条线段与连线折线逐段精确求交,
  /// 采样点之间的线段同样参与,快速划过不会漏切。节点本体不参与命中。
  List<NinjaCut> slice(Offset from, Offset to, {double threshold = 7}) {
    if ((to - from).distance < 1) return const [];
    final cuts = <NinjaCut>[];
    for (final wire in wires) {
      if (wire.cut) continue;
      final path = wirePath(wire);
      for (var i = 0; i < path.length - 1; i++) {
        final pair = closestSegmentPair(from, to, path[i], path[i + 1]);
        if (pair.dist > threshold) continue;
        wire.cut = true;
        wire.cutT = 0;
        wire.cutIndex = i;
        wire.cutPoint = pair.b;
        wire.frozen = path;
        cuts.add((wire: wire, point: pair.b, color: wire.color));
        score++;
        break;
      }
    }
    if (cuts.isNotEmpty) notifyListeners();
    return cuts;
  }

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

/// 忍者模式的绘制层:节点卡片、节点之间的连线、被切断的两半、分数与提示
class NinjaPainter extends CustomPainter {
  final NinjaGame game;
  final SyphonTheme theme;

  NinjaPainter({required this.game, required this.theme})
    : super(repaint: game);

  @override
  void paint(Canvas canvas, Size size) {
    // 先画连线(在节点下层,像真实连线一样从卡片边缘接出),再画节点卡片
    for (final wire in game.wires) {
      _paintWire(canvas, game.wirePath(wire), wire);
    }
    for (final f in game.fruits) {
      canvas.save();
      canvas.translate(f.position.dx, f.position.dy);
      canvas.rotate(f.angle);
      _paintCard(
        canvas,
        Rect.fromCenter(
          center: Offset.zero,
          width: f.size.width,
          height: f.size.height,
        ),
        f,
      );
      canvas.restore();
    }
    _paintHud(canvas, size);
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
    // 深色描边:连线压在背景/卡片上时依然清晰
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 7
        ..color = Colors.black.withValues(alpha: .38 * alpha),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 3.6
        ..color = color.withValues(alpha: alpha),
    );
  }

  void _paintCard(Canvas canvas, Rect rect, NinjaFruit f) {
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(9));
    canvas.drawRRect(
      rrect,
      Paint()..color = theme.bgNode.withValues(alpha: .96),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = theme.strokeStrong.withValues(alpha: .9),
    );
    // 标题带
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTWH(rect.left, rect.top, rect.width, 24),
        topLeft: const Radius.circular(9),
        topRight: const Radius.circular(9),
      ),
      Paint()..color = f.color.withValues(alpha: .95),
    );
    _text(
      canvas,
      '${f.icon}  ${f.label}',
      Offset(rect.left + 9, rect.top + 5),
      rect.width - 18,
      const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: Colors.white,
      ),
    );
    // 参数示意
    for (var i = 0; i < 2; i++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(rect.left + 12, rect.top + 38 + i * 18, rect.width - 24, 9),
          const Radius.circular(4),
        ),
        Paint()..color = theme.stroke.withValues(alpha: .85),
      );
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(rect.left + 12, rect.bottom - 22, rect.width * .42, 9),
        const Radius.circular(4),
      ),
      Paint()..color = f.color.withValues(alpha: .35),
    );
  }

  void _paintHud(Canvas canvas, Size size) {
    const hint = '按住左键划过节点之间的连线,把它一刀两断 · ↑↑↓↓←→←→ 退出';
    final painter = TextPainter(
      text: TextSpan(
        text: game.score == 0 ? hint : '$hint   得分 ${game.score}',
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
      old.game != game || old.theme != theme;
}
