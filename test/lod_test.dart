import 'package:flutter_test/flutter_test.dart';
import 'package:syphon_nov/models/data.dart';
import 'package:syphon_nov/models/lod.dart';

void main() {
  test('line LOD preserves endpoints, extrema, and gap separators', () {
    final input = <Pt>[
      ...List.generate(
        1000,
        (i) => Pt(i.toDouble(), i == 500 ? 10000 : i.toDouble()),
      ),
      const Pt(double.nan, double.nan),
      ...List.generate(1000, (i) => Pt(1001 + i.toDouble(), -i.toDouble())),
    ];
    final lod = linePreviewLod(input, 100);
    expect(lod.reduced, isTrue);
    expect(lod.values.first, input.first);
    expect(lod.values.last, input.last);
    expect(lod.values.any((p) => p.y == 10000), isTrue);
    expect(lod.values.any((p) => !p.x.isFinite), isTrue);
    expect(lod.label, contains('${lod.values.length}/${input.length}'));
  });

  test('scatter LOD aggregates cells while retaining endpoints', () {
    final input = List.generate(
      5000,
      (i) => Pt3((i % 10).toDouble(), (i % 10).toDouble()),
    );
    final lod = scatterPreviewLod(input, 1);
    expect(lod.values.length, lessThan(20));
    expect(lod.values.first, input.first);
    expect(lod.values.last, input.last);
  });
}
