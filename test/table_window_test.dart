// 表格编辑窗口:数据模型(增删行列/类型/标记/剪贴板/JSON/撤销)+
// 独立浮窗的交互(双击节点打开、单元格编辑写回、结构操作、关闭)。
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_sheet/grid_sheet.dart';

import 'package:syphon_nov/main.dart';
import 'package:syphon_nov/models/data.dart' as md;
import 'package:syphon_nov/models/exec.dart';
import 'package:syphon_nov/models/table_edit.dart';
import 'package:syphon_nov/store/graph_store.dart';
import 'package:syphon_nov/ui/node_canvas.dart';
import 'package:syphon_nov/ui/table_window.dart';

void main() {
  group('EditableTable', () {
    test('列字母与类型推断', () {
      expect(columnLetter(0), 'A');
      expect(columnLetter(25), 'Z');
      expect(columnLetter(26), 'AA');
      expect(detectColumnType([1, 2, 3]), 'int');
      expect(detectColumnType([1, 2.5]), 'double');
      expect(detectColumnType(['a', 1]), 'text');
      expect(detectColumnType([null, '']), 'double');
    });

    test('列 → 表格 → 列 往返保留名称/类型/标记/空值', () {
      final table = EditableTable.fromColumns([
        md.Column(
          name: 'x',
          values: [0, 10, 20],
          type: 'int',
          designation: 'x',
        ),
        md.Column(
          name: 'y',
          values: [1.5, null, 3.25],
          type: 'double',
          designation: 'y',
        ),
      ]);
      expect(table.rowCount, 3);
      expect(table.columnCount, 2);
      expect(table.cellAt(1, 1), '');

      final columns = table.toColumns();
      expect(columns[0].name, 'x');
      expect(columns[0].type, 'int');
      expect(columns[0].designation, 'x');
      expect(columns[0].values, [0, 10, 20]);
      expect(columns[1].values, [1.5, null, 3.25]);
      expect(columns[0].values.first, isA<int>());
      expect(columns[1].values.first, isA<double>());
    });

    test('JSON 编解码保留全部列元数据', () {
      final table = EditableTable.fromColumns([
        md.Column(name: 't', values: ['a', 'b'], type: 'text'),
      ]);
      table.insertRow(2);
      table.setCell(2, 0, 'c');
      table.setColumnDesignation(0, 'yerr');

      final decoded = EditableTable.decode(table.encode())!;
      expect(decoded.names, ['t']);
      expect(decoded.types, ['text']);
      expect(decoded.designations, ['yerr']);
      expect(decoded.rowCount, 3);
      expect(decoded.cellAt(2, 0), 'c');
      expect(EditableTable.decode(''), isNull);
      expect(EditableTable.decode('{oops'), isNull);
    });

    test('增删行列保持矩形,至少保留一列', () {
      final table = EditableTable.empty(rows: 2, columns: 2);
      table.insertRow(0);
      expect(table.rowCount, 3);
      expect(table.cells.every((r) => r.length == 2), isTrue);

      table.insertColumn(1);
      expect(table.columnCount, 3);
      expect(table.cells.every((r) => r.length == 3), isTrue);

      table.removeRow(0);
      expect(table.rowCount, 2);

      table.removeColumn(0);
      table.removeColumn(0);
      expect(table.columnCount, 1, reason: '最后一列不可删除');
    });

    test('粘贴块自动扩展行列', () {
      final table = EditableTable.empty(rows: 1, columns: 1);
      table.pasteBlock(0, 0, [
        ['1', '2', '3'],
        ['4', '5', '6'],
      ]);
      expect(table.rowCount, 2);
      expect(table.columnCount, 3);
      expect(table.cellAt(1, 2), '6');
    });

    test('TSV 复制 / 解析往返', () {
      final table = EditableTable.fromColumns([
        md.Column(name: 'a', values: [1, 2]),
        md.Column(name: 'b', values: ['x', 'y']),
      ]);
      final tsv = table.blockToTsv(0, 0, 1, 1);
      expect(tsv, '1\tx\r\n2\ty');
      final parsed = EditableTable.parseClipboard(tsv);
      expect(parsed.length, 2);
      expect(parsed[0], ['1', 'x']);
      expect(EditableTable.parseClipboard('1,2\n3,4'), [
        ['1', '2'],
        ['3', '4'],
      ]);
    });

    test('撤销/重做按快照回滚', () {
      final history = TableEditHistory();
      final table = EditableTable.empty(rows: 1, columns: 1);
      expect(history.canUndo, isFalse);

      history.record(table);
      table.setCell(0, 0, '42');
      expect(history.canUndo, isTrue);

      final undone = history.undo(table)!;
      expect(undone.cellAt(0, 0), '');
      expect(history.canUndo, isFalse);
      expect(history.canRedo, isTrue);

      final redone = history.redo(undone)!;
      expect(redone.cellAt(0, 0), '42');
    });
  });

  test('table_input 优先读取编辑窗口保存的 tableJson', () {
    final table = EditableTable.fromColumns([
      md.Column(name: 'A', values: [1, 2, 3], type: 'int', designation: 'x'),
      md.Column(name: 'B', values: [1.5, 2.5, 3.5]),
    ]);
    final out = kExec['table_input']!(
      md.ExecContext(
        nodeId: 'n1',
        params: {
          'mode': 'manual',
          'dataText': 'A,B\n9,9',
          'tableJson': table.encode(),
        },
        inputs: const {},
      ),
    );
    final result = out['out0']! as md.TableData;
    expect(result.columns[0].name, 'A');
    expect(result.columns[0].designation, 'x');
    expect(result.columns[0].values, [1, 2, 3]);
    expect(result.columns[1].values, [1.5, 2.5, 3.5]);
  });

  group('表格编辑浮窗', () {
    setUp(() {
      GraphStore.useIsolate = false;
      GraphStore.instance.clearAll();
      closeTableWindow();
    });

    tearDown(() {
      closeTableWindow();
      GraphStore.instance.clearAll();
      GraphStore.useIsolate = true;
    });

    Future<void> pumpApp(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const SyphonApp());
      await tester.pump();
    }

    /// 建一个只有 2×2 数据的表格输入节点(避免预设的上千个单元格拖慢测试)
    Future<String> addTableNode(WidgetTester tester) async {
      final id = GraphStore.instance.addNode(
        'table_input',
        const Offset(40, 60),
        triggerRun: false,
      );
      GraphStore.instance.updateNodeParams(id, {
        'mode': 'manual',
        'dataText': 'A,B\n1,2\n3,4',
        'headerMode': 'present',
      });
      await tester.pump();
      return id;
    }

    testWidgets('双击表格输入节点打开独立编辑窗口', (tester) async {
      await pumpApp(tester);
      final id = await addTableNode(tester);
      expect(find.byKey(ValueKey('table-window-$id')), findsNothing);

      final canvasOrigin = tester.getTopLeft(find.byType(NodeCanvas));
      final node = GraphStore.instance.nodeOf(id)!;
      final point = canvasOrigin + node.position + const Offset(70, 14);

      // 真实时间戳的两次主键按下(间隔 80ms)= 双击
      final pointer = TestPointer(7, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        pointer.down(point, timeStamp: const Duration(milliseconds: 100)),
      );
      await tester.sendEventToBinding(
        pointer.up(timeStamp: const Duration(milliseconds: 130)),
      );
      await tester.pump(const Duration(milliseconds: 40));
      await tester.sendEventToBinding(
        pointer.down(point, timeStamp: const Duration(milliseconds: 180)),
      );
      await tester.sendEventToBinding(
        pointer.up(timeStamp: const Duration(milliseconds: 210)),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(ValueKey('table-window-$id')), findsOneWidget);
      expect(find.text('表格编辑 — 表格输入'), findsOneWidget);
      expect(find.byType(GridSheet), findsOneWidget);
      // 表头按 SciDAVis 风格显示列字母 + 类型(1..4 全是整数);pluto 用
      // TextSpan 渲染标题,所以按 RichText 的纯文本判断
      bool hasTitle(String text) => tester
          .widgetList<RichText>(find.byType(RichText))
          .any((w) => w.text.toPlainText().contains(text));
      expect(hasTitle('A {整数}'), isTrue);
      expect(hasTitle('B {整数}'), isTrue);
    });

    testWidgets('窗口可以拖动与缩放,且不重建表格', (tester) async {
      await pumpApp(tester);
      final id = await addTableNode(tester);
      openTableWindow(id);
      await tester.pumpAndSettle();

      final window = find.byKey(ValueKey('table-window-$id'));
      final before = tester.getRect(window);

      // 拖标题栏
      await tester.dragFrom(
        before.topCenter + const Offset(0, 12),
        const Offset(120, 60),
      );
      await tester.pumpAndSettle();
      final moved = tester.getRect(window);
      expect(moved.left - before.left, closeTo(120, 4), reason: '窗口应跟随指针水平移动');
      expect(moved.top - before.top, closeTo(60, 4), reason: '窗口应跟随指针垂直移动');

      // 拖右下角缩放手柄
      await tester.dragFrom(
        moved.bottomRight - const Offset(6, 6),
        const Offset(90, 50),
      );
      await tester.pumpAndSettle();
      final resized = tester.getRect(window);
      expect(resized.width - moved.width, closeTo(90, 4));
      expect(resized.height - moved.height, closeTo(50, 4));
      expect(find.byType(GridSheet), findsOneWidget, reason: '拖动/缩放不应弄丢表格');
    });

    testWidgets('增删行列与撤销重做', (tester) async {
      await pumpApp(tester);
      final id = await addTableNode(tester);
      openTableWindow(id);
      await tester.pumpAndSettle();

      md.TableData tableOf() {
        final table = EditableTable.decode(
          '${GraphStore.instance.nodeOf(id)!.params['tableJson']}',
        )!;
        return md.TableData(table.toColumns());
      }

      // 尚未编辑时节点里只有 CSV 源:第一次结构操作才会写入结构化表格
      await tester.tap(find.text('插入行'));
      await tester.pumpAndSettle();
      expect(tableOf().columns.first.values.length, 3);

      await tester.tap(find.text('插入列'));
      await tester.pumpAndSettle();
      expect(tableOf().columns.length, 3);

      // 撤销两次回到 2 行 2 列
      await tester.tap(find.byIcon(Icons.undo));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.undo));
      await tester.pumpAndSettle();
      final undone = tableOf();
      expect(undone.columns.length, 2);
      expect(undone.columns.first.values.length, 2);

      await tester.tap(find.byIcon(Icons.redo));
      await tester.pumpAndSettle();
      expect(tableOf().columns.length, 2, reason: '重做回到"插入列"之前');
      await tester.tap(find.byIcon(Icons.redo));
      await tester.pumpAndSettle();
      expect(tableOf().columns.length, 3, reason: '再次重做"插入列"');

      await tester.tap(find.text('删除列'));
      await tester.pumpAndSettle();
      expect(tableOf().columns.length, 2);
    });

    testWidgets('列类型与标记可改,并随表保存', (tester) async {
      await pumpApp(tester);
      final id = await addTableNode(tester);
      openTableWindow(id);
      await tester.pumpAndSettle();

      // 选中 A 列,把标记设成 [X]
      await tester.tap(find.text('A').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('table-col-flag-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('[X]').last);
      await tester.pumpAndSettle();

      final table = EditableTable.decode(
        '${GraphStore.instance.nodeOf(id)!.params['tableJson']}',
      )!;
      expect(table.designations.first, 'x');
      expect(find.text('[X]'), findsWidgets);
    });

    testWidgets('关闭按钮收起窗口,节点删除时窗口自动关闭', (tester) async {
      await pumpApp(tester);
      final id = await addTableNode(tester);
      openTableWindow(id);
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('table-window-$id')), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('table-window-$id')), findsNothing);

      openTableWindow(id);
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('table-window-$id')), findsOneWidget);

      GraphStore.instance.removeNodes([id]);
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('table-window-$id')), findsNothing);
    });

    testWidgets('属性面板按钮也能打开窗口', (tester) async {
      await pumpApp(tester);
      final id = await addTableNode(tester);
      expect(find.text('打开表格编辑窗口…'), findsOneWidget);
      await tester.tap(find.text('打开表格编辑窗口…'));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('table-window-$id')), findsOneWidget);
    });
  });
}
