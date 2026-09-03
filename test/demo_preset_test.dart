// 功能全景演示图:确保 JSON 可加载、可执行、无回路
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/models/presets.dart';
import 'package:syphon_nov/store/graph_store.dart';

void main() {
  test('功能全景演示:画布可加载且流水线执行无错误', () {
    final store = GraphStore.instance;
    expect(store.loadGraph(kDemoGraphJson, silent: true), isTrue);
    // loadGraph 在 autoRun 下已执行;这里强制再跑一轮并检查错误
    store.runPipeline();
    final errors = store.results.values.where((r) => r.error != null).toList();
    expect(errors, isEmpty, reason: '执行错误: ${errors.map((e) => e.error)}');
    expect(store.nodes.length, greaterThanOrEqualTo(35));
    expect(store.edges.length, greaterThanOrEqualTo(35));
    expect(store.groups.length, 4);
  });
}
