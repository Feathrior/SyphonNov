// Explicit capability audit, excluded from the normal test/ suite.
// These assertions describe required behavior; failures document open issues.
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syphon_nov/models/csv.dart';
import 'package:syphon_nov/models/data.dart';
import 'package:syphon_nov/store/graph_store.dart';

List<int> sparseWorkbook() {
  final archive = Archive();
  final parts = {
    'xl/workbook.xml':
        '<workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<sheets><sheet name="Data" sheetId="1" r:id="rId1"/></sheets></workbook>',
    'xl/_rels/workbook.xml.rels':
        '<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>',
    'xl/worksheets/sheet1.xml':
        '<worksheet><sheetData>'
        '<row r="1"><c r="A1" t="inlineStr"><is><t>sample</t></is></c></row>'
        '<row r="2"><c r="A2" t="inlineStr"><is><t>A</t></is></c>'
        '<c r="C2"><v>2.5</v></c></row>'
        '</sheetData></worksheet>',
  };
  for (final entry in parts.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return ZipEncoder().encode(archive);
}

String workflow({required String mode, String dataText = ''}) => jsonEncode({
  'format': 'syphon-graph',
  'version': 1,
  'nodes': [
    {
      'id': 'source',
      'configId': 'table_input',
      'params': {'mode': mode, 'preset': 'volcano', 'dataText': dataText},
    },
  ],
  'edges': [],
});

List<List<dynamic>> sourceValues(GraphStore store) =>
    (store.results['source']!.outputs['out0'] as TableData).columns
        .map((c) => List<dynamic>.of(c.values))
        .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('audit: quoted multiline CSV survives export and import', () {
    final original = [
      Column(name: 'sample', values: ['A\nB', 'C']),
      Column(name: 'value', values: [1, 2]),
    ];
    final parsed = parseDelimitedText(columnsToCsv(original));
    expect(parsed.map((c) => c.values).toList(), [
      ['A\nB', 'C'],
      [1, 2],
    ]);
  });

  test('audit: XLSX missing trailing header cells do not crash import', () {
    final columns = xlsxBytesToColumns(sparseWorkbook());
    expect(columns.length, 3);
    expect(columns[2].values, [2.5]);
  });

  test('audit control: manual data survives workflow roundtrip', () {
    final store = GraphStore.instance..autoRun = true;
    expect(
      store.loadGraph(workflow(mode: 'manual', dataText: 'x,y\n0,1\n1,2')),
      isTrue,
    );
    final before = sourceValues(store);
    expect(store.loadGraph(store.saveGraph()), isTrue);
    expect(sourceValues(store), before);
  });

  test('audit: saved random preset preserves the data used for a figure', () {
    final store = GraphStore.instance..autoRun = true;
    expect(store.loadGraph(workflow(mode: 'preset')), isTrue);
    final before = sourceValues(store);
    final serialized = store.saveGraph();
    expect(store.loadGraph(serialized), isTrue);
    final after = sourceValues(store);
    expect(
      after,
      before,
      reason:
          'A saved workflow needs a realized data snapshot or reproducible generator state.',
    );
  });
}
