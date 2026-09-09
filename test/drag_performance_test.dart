import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/models/presets.dart';
import 'package:syphon_nov/store/graph_store.dart';

void main() {
  test('drag frames use layout notifications and commit global state once', () {
    final store = GraphStore.instance;
    expect(store.loadGraph(kDemoGraphJson, silent: true), isTrue);
    var globalFrames = 0, layoutFrames = 0;
    void onGlobal() => globalFrames++;
    void onLayout() => layoutFrames++;
    store.addListener(onGlobal);
    store.layoutRevision.addListener(onLayout);
    addTearDown(() {
      store.removeListener(onGlobal);
      store.layoutRevision.removeListener(onLayout);
    });

    final node = store.nodes.first;
    store.moveNodesTo(
      {node.id},
      {node.id: node.position + const Offset(10, 5)},
    );
    expect(layoutFrames, 1);
    expect(
      globalFrames,
      0,
      reason:
          '3D previews and other global listeners must not rebuild per pointer event',
    );

    store.finishLayoutChange();
    expect(globalFrames, 1);
  });
}
