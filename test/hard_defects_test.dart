import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syphon_nov/models/csv.dart';
import 'package:syphon_nov/models/exec_engine.dart';
import 'package:syphon_nov/models/registry.dart';
import 'package:syphon_nov/store/graph_store.dart';

Map<String, dynamic> _node(
  String id,
  String type, [
  Map<String, dynamic>? params,
]) => {
  'id': id,
  'configId': type,
  'params': params ?? <String, dynamic>{},
  'position': {'x': 0, 'y': 0},
};

String _graph(
  List<Map<String, dynamic>> nodes, [
  List<Map<String, dynamic>> edges = const [],
]) => jsonEncode({
  'format': 'syphon-graph',
  'version': 1,
  'nodes': nodes,
  'edges': edges,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final store = GraphStore.instance;
  setUp(() {
    store.autoRun = false;
    expect(store.loadGraph(_graph([]), silent: true), isTrue);
  });

  test(
    'schema v2 records provenance and migrates deterministic seeds/header mode',
    () {
      expect(
        store.loadGraph(
          _graph([
            _node('r', 'table_input', {'mode': 'preset'}),
          ]),
          silent: true,
        ),
        isTrue,
      );
      expect(store.nodes.single.params['headerMode'], 'auto');
      expect(store.nodes.single.params['seed'], isA<int>());
      final saved = jsonDecode(store.saveGraph()) as Map<String, dynamic>;
      expect(saved['formatVersion'], 2);
      expect(saved['provenance']['applicationVersion'], '0.4.1');
    },
  );

  test('invalid workflow is rejected atomically', () {
    expect(
      store.loadGraph(_graph([_node('keep', 'table_input')]), silent: true),
      isTrue,
    );
    final before = store.saveGraph();
    expect(
      store.loadGraph(_graph([_node('bad', 'unknown_node')]), silent: true),
      isFalse,
    );
    expect(store.saveGraph(), before);
  });

  test('non-multi connection replaces atomically and cycle is rejected', () {
    final nodes = [
      _node('a', 'table_input'),
      _node('b', 'table_input'),
      _node('c', 'clean'),
      _node('d', 'clean'),
    ];
    expect(store.loadGraph(_graph(nodes), silent: true), isTrue);
    expect(store.onConnect(source: 'a', target: 'c'), isTrue);
    expect(store.onConnect(source: 'b', target: 'c'), isTrue);
    expect(store.edges.where((e) => e.target == 'c'), hasLength(1));
    expect(store.edges.single.source, 'b');
    expect(store.onConnect(source: 'c', target: 'd'), isTrue);
    expect(store.onConnect(source: 'd', target: 'c'), isFalse);
  });

  test('cycle execution fails atomically and reports its path', () {
    final nodes = [
      GraphNodeLite(id: 'a', configId: 'clean', params: const {}),
      GraphNodeLite(id: 'b', configId: 'clean', params: const {}),
    ];
    final outcome = runGraph(nodes, [
      GraphEdgeLite(source: 'a', target: 'b'),
      GraphEdgeLite(source: 'b', target: 'a'),
    ]);
    expect(outcome.hasCycle, isTrue);
    expect(outcome.results, isEmpty);
    expect(outcome.cyclePath.first, outcome.cyclePath.last);
  });

  test('execution exposes revision/status/progress and cancellation', () {
    GraphStore.useIsolate = false;
    expect(
      store.loadGraph(_graph([_node('a', 'table_input')]), silent: true),
      isTrue,
    );
    store.runPipeline();
    expect(store.committedRevision, store.executionRevision);
    expect(store.executionStatus, 'succeeded');
    expect(store.executionProgress, 1);
    expect(store.executionCompletedNodes, 1);
    expect(store.executionTotalNodes, 1);
    store.cancelExecution();
    expect(store.executionStatus, 'cancelled');
    GraphStore.useIsolate = true;
  });

  test('execution reports progress once per topological node', () {
    final progress = <(int, int)>[];
    final outcome = runGraph(
      [
        GraphNodeLite(id: 'a', configId: 'table_input', params: const {}),
        GraphNodeLite(id: 'b', configId: 'clean', params: const {}),
      ],
      [GraphEdgeLite(source: 'a', target: 'b')],
      onProgress: (completed, total) => progress.add((completed, total)),
    );
    expect(outcome.hasCycle, isFalse);
    expect(progress, [(1, 2), (2, 2)]);
  });

  test('strict UTF-8 reports corruption and legacy XLS is rejected', () async {
    final dir = await Directory.systemTemp.createTemp('syphon-hard-defects-');
    addTearDown(() => dir.delete(recursive: true));
    final badCsv = File('${dir.path}/bad.csv')..writeAsBytesSync([0x61, 0xff]);
    await expectLater(
      dataFileToCsvText(badCsv.path),
      throwsA(isA<FormatException>()),
    );
    expect(
      await dataFileToCsvText(badCsv.path, strictEncoding: false),
      contains('\uFFFD'),
    );
    final xls = File('${dir.path}/legacy.xls')..writeAsBytesSync([0xd0, 0xcf]);
    await expectLater(
      dataFileToCsvText(xls.path),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('.xlsx'),
        ),
      ),
    );
  });

  test('statistical controls and Colorbar are registered', () {
    expect(getConfig('colorbar_input'), isNotNull);
    expect(
      getConfig(
        'viz_box',
      )!.params.any((p) => p.key == 'whiskerMode' && p.defaultValue == 'tukey'),
      isTrue,
    );
    expect(
      getConfig('viz_violin')!.params.any((p) => p.key == 'bandwidthMode'),
      isTrue,
    );
    expect(
      getConfig('viz_volcano')!.params.map((p) => p.key),
      containsAll(['fcThreshold', 'significanceThreshold', 'significanceKind']),
    );
  });

  test(
    'release metadata, license, and Windows CI are present and consistent',
    () {
      expect(
        File('LICENSE').readAsStringSync(),
        contains('Copyright (c) 2026 Feathrior'),
      );
      expect(
        File('pubspec.yaml').readAsStringSync(),
        contains('version: 0.4.1+1'),
      );
      final nsi = File('install.nsi').readAsStringSync();
      expect(nsi, contains('DisplayVersion" "0.4.1"'));
      expect(nsi, isNot(contains('SyphonNov2')));
      expect(File('.github/workflows/windows.yml').existsSync(), isTrue);
    },
  );
}
