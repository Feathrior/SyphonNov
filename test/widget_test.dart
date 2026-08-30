// Syphon 应用冒烟测试:验证主应用可构建。
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/main.dart';

void main() {
  testWidgets('Syphon app builds', (WidgetTester tester) async {
    await tester.pumpWidget(const SyphonApp());
    await tester.pump();
    expect(find.text('Syphon'), findsWidgets);
  });
}
