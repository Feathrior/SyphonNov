// 彩蛋:水果忍者模式。
//
// 每一"波"抛上来固定的一组节点 + 连线:2 节点 1 连线、3 节点 2 连线、
// 4 节点 3 连线……(链式相连,结构完全固定,不随节点相对位置实时生成),
// 所以切干净就是真的干净。
//
// 连线可以切,节点也可以切:节点被切开后从中间裂成两半,属于它的连线一并
// 断开消失,同时炸出一大团粒子。
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

  /// 被刀切中:从中间裂成两半
  bool sliced = false;
  double sliceAngle = 0;
  double slicedLife = 0;
}

/// 一刀的结果:切中的连线或节点、切点(屏幕坐标)与颜色
typedef NinjaCut = ({
  NinjaWire? wire,
  NinjaFruit? fruit,
  Offset point,
  Color color,
});

/// 忍者模式的模拟:成组生成、抛物线运动、连线与节点切割判定
class NinjaGame extends ChangeNotifier {
  static const double gravity = 980; // px/s²
  /// 切断的连线两半散开消失的时间(秒)
  static const double wireLife = .6;
  /// 被切开的节点两半散开消失的时间(秒)
  static const double slicedLife = 1.5;
  /// 一波最多抛几个节点(链式连线数 = 节点数 - 1)
  static const int maxWaveNodes = 5;
  /// 同屏节点上限
  static const int maxFruits = 12;

  final List<NinjaFruit> fruits = [];
  final List<NinjaWire> wires = [];
  final math.Random _random = math.Random();

  int score = 0;
  double width = 0;
  double height = 0;
  double _spawnTimer = 0.6;
  /// 下一波抛几个节点:2 → 3 → 4 → …(到上限后循环)
  int _nextWaveNodes = 2;

  void reset() {
    fruits.clear();
    wires.clear();
    score = 0;
    _spawnTimer = 0.6;
    _nextWaveNodes = 2;
  }

  /// 推进一帧。[dt] 为秒。
  void update(double dt) {
    if (width <= 0 || height <= 0) return;
    _spawnTimer -= dt;
    if (_spawnTimer <= 0 && fruits.length < maxFruits) {
      _spawnWave(_nextWaveNodes);
      _nextWaveNodes = _nextWaveNodes >= maxWaveNodes
          ? 2
          : _nextWaveNodes + 1;
      _spawnTimer = 1.6 + _random.nextDouble() * .5;
    }

    final alive = <NinjaFruit>[];
    for (final f in fruits) {
      f.velocity = f.velocity + Offset(0, gravity * dt);
      f.position = f.position + f.velocity * dt;
      f.angle += f.spin * dt;
      if (f.sliced) {
        // 切开的两半散开淡出
        f.slicedLife += dt;
        if (f.slicedLife > slicedLife) continue;
      } else if (f.position.dy - f.size.height > height + 80) {
        // 掉出画面(抛物线回落)后移除
        continue;
      }
      alive.add(f);
    }
    fruits
      ..clear()
      ..addAll(alive);

    // 连线:切开的继续播放两半散开动画;两端节点都还在的保留。
    // 绝不会"凭空补线":连线只在这一波节点入场时按固定结构建立。
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

  /// 抛出一波:固定 [count] 个节点 + (count-1) 条链式连线。
  ///
  /// 节点一起从画面下方抛入,水平方向均匀铺开,抛物线几乎同步;
  /// 连线按入场顺序首尾相接,结构固定。
  void _spawnWave(int count) {
    final n = count.clamp(2, maxWaveNodes);
    // 一波的整体落点:屏幕中段随机横向偏移
    final span = math.min(width * .7, 190.0 * (n - 1));
    final left = (width - span) / 2 + (_random.nextDouble() - .5) * 40;
    final peak = height * (.5 + _random.nextDouble() * .2);
    final vy = -math.sqrt(2 * gravity * peak);
    final wave = <NinjaFruit>[];
    for (var i = 0; i < n; i++) {
      final config = kNodeConfigs[_random.nextInt(kNodeConfigs.length)];
      final x = n == 1 ? left : left + span * i / (n - 1);
      final fruit = NinjaFruit(
        configId: config.id,
        label: config.label,
        icon: kCatInfo[config.category.name]?.icon ?? '▣',
        color: _categoryColor(config.category.name),
        position: Offset(x, height + 60 + i * 18),
        velocity: Offset((width / 2 - x) * .18, vy),
        angle: (_random.nextDouble() - .5) * .5,
        spin: (_random.nextDouble() - .5) * 1.8,
        size: const Size(146, 86),
      );
      wave.add(fruit);
      fruits.add(fruit);
    }
    // 链式连线:1-2,2-3,3-4…(固定结构,数量 = 节点数 - 1)
    for (var i = 0; i < wave.length - 1; i++) {
      wires.add(
        NinjaWire(from: wave[i], to: wave[i + 1], color: _wireColor()),
      );
    }
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
  /// 连线按"上次指针位置 → 本次位置"与之逐段精确求交;节点则按卡片矩形
  /// (旋转变换回局部坐标后)判定。节点被切中时,属于它的连线一并断开。
  List<NinjaCut> slice(Offset from, Offset to, {double threshold = 7}) {
    if ((to - from).distance < 1) return const [];
    final cuts = <NinjaCut>[];

    // 1) 节点:从中间一切两半
    for (final fruit in fruits) {
      if (fruit.sliced) continue;
      if (!_segmentHitsRotatedRect(from, to, fruit)) continue;
      fruit.sliced = true;
      fruit.slicedLife = 0;
      fruit.sliceAngle = math.atan2(to.dy - from.dy, to.dx - from.dx);
      cuts.add((
        wire: null,
        fruit: fruit,
        point: fruit.position,
        color: fruit.color,
      ));
      score++;
      // 挂在它身上的连线一并断开消失
      for (final wire in wires) {
        if (wire.cut) continue;
        if (!identical(wire.from, fruit) && !identical(wire.to, fruit)) {
          continue;
        }
        _cutWire(wire, wirePath(wire), 0);
      }
    }

    // 2) 连线
    for (final wire in wires) {
      if (wire.cut) continue;
      final path = wirePath(wire);
      for (var i = 0; i < path.length - 1; i++) {
        final pair = closestSegmentPair(from, to, path[i], path[i + 1]);
        if (pair.dist > threshold) continue;
        _cutWire(wire, path, i, pair.b);
        cuts.add((wire: wire, fruit: null, point: pair.b, color: wire.color));
        score++;
        break;
      }
    }
    if (cuts.isNotEmpty) notifyListeners();
    return cuts;
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

  int get flying => fruits.where((f) => !f.sliced).length;

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
      final rect = Rect.fromCenter(
        center: Offset.zero,
        width: f.size.width,
        height: f.size.height,
      );
      if (!f.sliced) {
        _paintCard(canvas, rect, f, 1);
      } else {
        // 切开的节点:从切口分成两半,各自平移旋转着散开并淡出
        final p = (f.slicedLife / NinjaGame.slicedLife).clamp(0.0, 1.0);
        final alpha = (1 - p).clamp(0.0, 1.0);
        final normal = Offset(
          math.cos(f.sliceAngle + math.pi / 2),
          math.sin(f.sliceAngle + math.pi / 2),
        );
        final spread = 34 * p;
        _paintHalf(
          canvas,
          rect,
          f,
          f.sliceAngle,
          upper: true,
          offset: normal * spread,
          rotation: .4 * p,
          alpha: alpha,
        );
        _paintHalf(
          canvas,
          rect,
          f,
          f.sliceAngle,
          upper: false,
          offset: -normal * spread,
          rotation: -.4 * p,
          alpha: alpha,
        );
      }
      canvas.restore();
    }
    _paintHud(canvas, size);
  }

  void _paintHalf(
    Canvas canvas,
    Rect rect,
    NinjaFruit f,
    double sliceAngle, {
    required bool upper,
    required Offset offset,
    required double rotation,
    required double alpha,
  }) {
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    // 转到切线水平 → 只留一侧 → 转回来再画卡片,得到"半个节点"
    canvas.rotate(sliceAngle);
    canvas.clipRect(Rect.fromLTWH(-600, upper ? -600 : 0, 1200, 600));
    canvas.rotate(-sliceAngle);
    canvas.rotate(rotation);
    _paintCard(canvas, rect, f, alpha);
    canvas.restore();
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
      Paint()..color = theme.bgNode.withValues(alpha: .96 * alpha),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = theme.strokeStrong.withValues(alpha: .9 * alpha),
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
  }

  void _paintHud(Canvas canvas, Size size) {
    const hint = '按住左键划过连线或节点,把它们一刀两断 · ↑↑↓↓←→←→ 退出';
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
