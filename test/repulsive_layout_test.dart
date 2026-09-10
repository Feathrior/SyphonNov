import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/ui/canvas_geometry.dart';

void main() {
  test('conversion nodes are pushed clear of existing and earlier nodes', () {
    final targets = resolveRepulsiveNodeLayout(
      moving: const [
        (id: 'a', position: Offset(40, 20), size: Size(100, 60)),
        (id: 'b', position: Offset(70, 30), size: Size(100, 60)),
      ],
      obstacles: const [Rect.fromLTWH(0, 0, 120, 100)],
      gap: 20,
    );

    final a = targets['a']! & const Size(100, 60);
    final b = targets['b']! & const Size(100, 60);
    expect(
      a.overlaps(const Rect.fromLTWH(0, 0, 120, 100).inflate(20)),
      isFalse,
    );
    expect(
      b.overlaps(const Rect.fromLTWH(0, 0, 120, 100).inflate(20)),
      isFalse,
    );
    expect(b.overlaps(a.inflate(20)), isFalse);
  });

  test('repulsive layout leaves already clear positions unchanged', () {
    final targets = resolveRepulsiveNodeLayout(
      moving: const [(id: 'a', position: Offset(300, 200), size: Size(80, 50))],
      obstacles: const [Rect.fromLTWH(0, 0, 100, 100)],
    );
    expect(targets['a'], const Offset(300, 200));
  });
}
