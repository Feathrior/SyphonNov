// 表格编辑窗口:双击「表格输入」节点(或属性面板的「编辑表格…」按钮)弹出。
//
// 表格本体交给成熟的开源数据网格 pluto_grid(MIT,桌面端键盘导航/编辑/复制
// 粘贴/列宽拖拽/列冻结都是现成的),本文件只负责:
//   · 节点参数双向同步(读 tableJson / dataText / 预设 → 编辑 → 写回 tableJson)
//   · 浮窗外壳(标题栏拖动、右下角缩放)—— 用 ChangeNotifier 驱动几何,
//     拖动时只重排 Positioned、不重建表格,保证跟手
//   · 列名/列类型/[X][Y] 标记工具条、撤销重做、状态栏
//
// 为什么不引入"浮窗库":pub.dev 上现成的浮窗包(draggable_overlay_window 2 赞 /
// simple_floating_panel 仅 4 个版本)都是个人早期项目,稳定性和可维护性都不如
// 这 300 行外壳;真正成熟的方案是 desktop_multi_window 开独立系统窗口(见 README
// 讨论),那是另一个量级的架构改动。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:grid_sheet/grid_sheet.dart';

import '../models/csv.dart';
import '../models/data.dart' as md;
import '../models/registry.dart';
import '../models/sample_data.dart';
import '../models/table_edit.dart';
import '../store/graph_store.dart';
import 'motion.dart';
import 'theme.dart';

/// 当前打开的表格编辑窗口对应的节点 id(null = 未打开)
final ValueNotifier<String?> tableWindowNode = ValueNotifier<String?>(null);

void openTableWindow(String nodeId) {
  tableWindowNode.value = nodeId;
}

void closeTableWindow() {
  tableWindowNode.value = null;
}

const Size _minWindowSize = Size(520, 320);
const Size _defaultWindowSize = Size(860, 560);
const double _titleBarH = 34;
const double _toolBarH = 40;
const double _statusBarH = 24;

/// 浮窗几何(位置 + 尺寸)。用 ChangeNotifier 驱动:拖动/缩放只让包住窗口的
/// Positioned 重排,表格子树作为 child 复用,不会被逐帧重建。
class _WindowGeometry extends ChangeNotifier {
  _WindowGeometry({required Rect rect, required Rect area})
    : _rect = _clampTo(rect, area),
      _area = area;

  Rect _rect;
  Rect _area;

  Rect get rect => _rect;
  Offset get position => _rect.topLeft;
  Size get size => _rect.size;

  /// 可用区域(应用窗口尺寸变化时更新,会顺带把窗口拉回可视范围)
  set area(Rect value) {
    if (value == _area) return;
    _area = value;
    final next = _clampTo(_rect, value);
    if (next != _rect) {
      _rect = next;
      notifyListeners();
    }
  }

  void moveBy(Offset delta) {
    final next = _clampTo(_rect.shift(delta), _area);
    if (next == _rect) return;
    _rect = next;
    notifyListeners();
  }

  void resizeBy(Offset delta) {
    final size = Size(
      (_rect.width + delta.dx).clamp(_minWindowSize.width, _area.width),
      (_rect.height + delta.dy).clamp(_minWindowSize.height, _area.height),
    );
    final next = _clampTo(
      Rect.fromLTWH(_rect.left, _rect.top, size.width, size.height),
      _area,
    );
    if (next == _rect) return;
    _rect = next;
    notifyListeners();
  }

  static Rect _clampTo(Rect rect, Rect area) {
    final width = rect.width.clamp(
      _minWindowSize.width,
      math.max(_minWindowSize.width, area.width),
    );
    final height = rect.height.clamp(
      _minWindowSize.height,
      math.max(_minWindowSize.height, area.height),
    );
    final left = rect.left
        .clamp(-(width - 140), math.max(0.0, area.width - 140))
        .toDouble();
    final top = rect.top
        .clamp(0.0, math.max(0.0, area.height - _titleBarH))
        .toDouble();
    return Rect.fromLTWH(left, top, width.toDouble(), height.toDouble());
  }
}

/// 浮窗层:挂在应用最上层(见 main.dart 的 Stack),未打开时不占命中区域。
class TableWindowLayer extends StatefulWidget {
  const TableWindowLayer({super.key});

  @override
  State<TableWindowLayer> createState() => _TableWindowLayerState();
}

class _TableWindowLayerState extends State<TableWindowLayer> {
  // 几何跨节点、跨开关保留:关闭再打开回到上次的位置与大小
  _WindowGeometry? _geometry;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: tableWindowNode,
      builder: (context, nodeId, _) {
        final id = nodeId;
        if (id == null || GraphStore.instance.nodeOf(id) == null) {
          return const SizedBox.shrink();
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final area = Offset.zero & constraints.biggest;
            final geometry = _geometry ??= _WindowGeometry(
              rect: Rect.fromLTWH(
                math.max(10, (area.width - _defaultWindowSize.width) / 2),
                math.max(10, (area.height - _defaultWindowSize.height) / 3),
                _defaultWindowSize.width,
                _defaultWindowSize.height,
              ),
              area: area,
            );
            // 应用窗口变化后(不能在 build 里 notify)再把窗口拉回可视范围
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) geometry.area = area;
            });
            return Stack(
              children: [
                AnimatedBuilder(
                  animation: geometry,
                  // 表格作为 child 复用:拖动/缩放不会重建上千个单元格
                  child: _TableWindow(
                    key: ValueKey('table-window-$id'),
                    nodeId: id,
                    geometry: geometry,
                  ),
                  builder: (context, child) {
                    final r = geometry.rect;
                    return Positioned(
                      left: r.left,
                      top: r.top,
                      width: r.width,
                      height: r.height,
                      child: child!,
                    );
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _TableWindow extends StatefulWidget {
  const _TableWindow({
    super.key,
    required this.nodeId,
    required this.geometry,
  });

  final String nodeId;
  final _WindowGeometry geometry;

  @override
  State<_TableWindow> createState() => _TableWindowState();
}

class _TableWindowState extends State<_TableWindow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entry;
  late final Animation<double> _entryCurve;

  EditableTable _table = EditableTable.empty();
  final TableEditHistory _history = TableEditHistory();

  /// 结构变化(增删行列/重命名/撤销)后重挂载网格,让 pluto_grid 用新列新行
  int _generation = 0;
  GridSheetManager? _manager;

  int _row = 0;
  int _col = 0;
  String? _error;
  String _title = '表格编辑';
  String _sourceStamp = '';

  /// 正在写回节点:期间的 store 通知不算外部改动
  bool _writing = false;

  /// 单元格内联编辑:第二次点击同一格才进入
  bool _editingCell = false;
  final TextEditingController _cellEditor = TextEditingController();
  final FocusNode _cellFocus = FocusNode(debugLabel: 'sheet-cell');

  /// 公式提示(等同代码补全)
  static const List<String> _kFormulaFunctions = [
    'SUM(',
    'AVERAGE(',
    'MIN(',
    'MAX(',
    'COUNT(',
    'ABS(',
    'ROUND(',
    'SQRT(',
    'POWER(',
  ];
  final GlobalKey _editorKey = GlobalKey();
  OverlayEntry? _suggestionEntry;
  List<String> _suggestions = const [];
  int _suggestionIndex = 0;

  /// 编辑公式时用鼠标圈选的多行多列范围
  ({int row, int column})? _rangeAnchor;
  ({int row, int column})? _rangeEnd;

  @override
  void initState() {
    super.initState();
    // 时长依赖 MediaQuery(动画倍率),只能在 didChangeDependencies 里设置
    _entry = AnimationController(vsync: this);
    _entryCurve = CurvedAnimation(
      parent: _entry,
      curve: MotionTokens.emphasized,
    );
    _loadFromNode();
    GraphStore.instance.addListener(_onStoreChanged);
  }

  bool _entered = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _entry.duration = MotionTokens.standard(context);
    _entry.reverseDuration = MotionTokens.dismiss(context);
    if (!_entered) {
      _entered = true;
      _entry.forward();
    }
  }

  @override
  void dispose() {
    GraphStore.instance.removeListener(_onStoreChanged);
    _entry.dispose();
    super.dispose();
  }

  // ==================== 数据装载 / 写回 ====================

  String _stampOf(GraphNode node) =>
      '${node.params['mode']}|${node.params['tableJson']}|'
      '${node.params['dataText']}|${node.params['preset']}|'
      '${node.params['seed']}|${node.params['delimiter']}|'
      '${node.params['headerMode']}';

  void _loadFromNode() {
    final node = GraphStore.instance.nodeOf(widget.nodeId);
    if (node == null) return;
    final cfg = getConfig(node.configId);
    final name = '${node.params['name'] ?? ''}'.trim();
    _title = '表格编辑 — ${name.isEmpty ? (cfg?.label ?? '表格') : name}';
    _sourceStamp = _stampOf(node);
    _history.clear();
    _error = null;
    _row = 0;
    _col = 0;

    final edited = EditableTable.decode('${node.params['tableJson'] ?? ''}');
    if (edited != null) {
      _table = edited;
      } else if ('${node.params['mode'] ?? 'preset'}' == 'manual') {
      final text = '${node.params['dataText'] ?? ''}';
      List<md.Column> columns = const [];
      if (text.trim().isNotEmpty) {
        try {
          final delimiter = '${node.params['delimiter'] ?? 'csv'}' == 'tsv'
              ? '\t'
              : ',';
          columns = parseDelimitedText(
            text,
            delimiter,
            switch ('${node.params['headerMode'] ?? 'auto'}') {
              'present' => HeaderMode.present,
              'absent' => HeaderMode.absent,
              _ => HeaderMode.auto,
            },
          );
        } catch (e) {
          _error = '数据解析失败:$e';
        }
      }
      _table = columns.isEmpty
          ? EditableTable.empty(rows: 0, columns: 2)
          : EditableTable.fromColumns(columns);
      } else {
      _table = EditableTable.fromColumns(
        presetTable(
          '${node.params['preset'] ?? 'phys'}',
          seed: num.tryParse('${node.params['seed'] ?? 0}')?.round() ?? 0,
        ),
      );
    }
    _generation++;
  }

  /// 把当前表格写回节点参数;自动执行开启时图表随之刷新
  void _commit() {
    final store = GraphStore.instance;
    if (store.nodeOf(widget.nodeId) == null) return;
    // 写回会同步触发 store 通知;期间必须忽略,否则会被当成"外部改动"重载,
    // 把撤销历史清空(表现为撤销一次后就变成不可用)。
    _writing = true;
    try {
      store.updateNodeParams(widget.nodeId, {
        'mode': 'manual',
        'tableJson': _table.encode(),
        // 编辑窗口接管数据后清空 CSV 源,避免两份数据互相矛盾
        'dataText': '',
        'delimiter': 'csv',
      });
    } finally {
      _writing = false;
    }
    final node = store.nodeOf(widget.nodeId);
    if (node != null) _sourceStamp = _stampOf(node);
  }

  void _onStoreChanged() {
    if (!mounted || _writing) return;
    final node = GraphStore.instance.nodeOf(widget.nodeId);
    if (node == null) {
      closeTableWindow();
      return;
    }
    // 外部改动(重新导入文件、切换预设等):重新载入
    if (_stampOf(node) == _sourceStamp) return;
    setState(_loadFromNode);
  }

  /// 修改表格并写回:结构变化需要重挂载网格
  void _mutate(void Function(EditableTable table) op) {
    _history.record(_table);
    op(_table);
    _clampCursor();
    _commit();
    setState(() => _generation++);
  }

  void _clampCursor() {
    _row = _table.rowCount == 0 ? 0 : _row.clamp(0, _table.rowCount - 1);
    _col = _table.columnCount == 0 ? 0 : _col.clamp(0, _table.columnCount - 1);
  }

  // ==================== pluto_grid 桥接 ====================

  String _columnTitle(int index) {
    final designation = columnDesignationLabel(_table.designations[index]);
    final parts = <String>[
      columnLetter(index),
      if (_table.names[index].trim().isNotEmpty) _table.names[index].trim(),
      '{${columnTypeLabel(_table.types[index])}}',
      if (designation.isNotEmpty) '[$designation]',
    ];
    return parts.join(' ');
  }

  List<GridSheetColumn> _sheetColumns() => [
    for (var c = 0; c < _table.columnCount; c++)
      GridSheetColumn(
        key: ValueKey('sheet-col-$c'),
        index: c,
        name: 'c$c',
        title: _columnTitle(c),
        // 全部按公式列:单元格可以放 '=A1+B2',由库负责求值与显示
        type: GridSheetColumnType.formula,
        width: 172,
      ),
  ];

  List<GridSheetRow> _sheetRows() => [
    for (var r = 0; r < _table.rowCount; r++)
      GridSheetRow(
        key: ValueKey('sheet-row-$r'),
        index: r,
        data: [
          for (var c = 0; c < _table.columnCount; c++) _table.cellAt(r, c),
        ],
      ),
  ];

  int _rowIndexOf(Key key) {
    final rows = _manager?.rows ?? const <GridSheetRow>[];
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].key == key) return i;
    }
    return -1;
  }

  /// 单元格渲染:选中门控 + 行列表头高亮。
  /// 未选中的格子由我们自己画成只读文本(第一次点击只选中),被选中的格子返回
  /// null 交回 grid_sheet 自己的可编辑单元格 —— 再点一次同一格即进入编辑。
  Widget? _sheetCellBuilder(GridSheetCellContext cell) {
    final t = SyphonTheme.of(context);
    final rowIdx = cell.rowIndex;
    final colIdx = cell.columnIndex;
    switch (cell.kind) {
      case GridSheetCellKind.header:
        final active = colIdx == _col;
        return Container(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          color: active ? t.accent.withValues(alpha: .18) : null,
          child: Text(
            cell.column.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: active ? t.accent : t.text,
            ),
          ),
        );
      case GridSheetCellKind.indexing:
        final active = rowIdx == _row;
        return Container(
          alignment: Alignment.center,
          color: active ? t.accent.withValues(alpha: .18) : null,
          child: Text(
            '${(rowIdx ?? 0) + 1}',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: active ? t.accent : t.textFaint,
            ),
          ),
        );
      case GridSheetCellKind.row:
        final r = rowIdx ?? 0;
        final isRow = r == _row;
        final isCol = colIdx == _col;
        final isSelected = isRow && isCol;
        final row = cell.row;
        final value = row == null ? '' : '${row.data[colIdx] ?? ''}';
        // 第二次点击同一格才出现输入框(第一次只高亮整行整列)
        if (isSelected && _editingCell) {
          return _buildCellEditor(t, r, colIdx);
        }
        // 正在编辑公式:点/圈选其它格子把引用插进公式(Excel 的选多行多列)
        if (_editingCell) {
          final inRange = _inDragRange(r, colIdx);
          return Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) => setState(() {
              _rangeAnchor = (row: r, column: colIdx);
              _rangeEnd = (row: r, column: colIdx);
            }),
            onPointerUp: (_) => _insertRangeRef(),
            child: MouseRegion(
              onEnter: (_) {
                if (_rangeAnchor == null) return;
                setState(() => _rangeEnd = (row: r, column: colIdx));
              },
              child: Container(
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                color: inRange
                    ? t.accent.withValues(alpha: .22)
                    : Colors.transparent,
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: t.text),
                ),
              ),
            ),
          );
        }
        return GestureDetector(
          key: ValueKey('sheet-cell-$r-$colIdx'),
          behavior: HitTestBehavior.opaque,
          onTap: () => _onCellTap(r, colIdx),
          child: Container(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            color: isSelected
                ? t.accent.withValues(alpha: .20)
                : (isRow || isCol ? t.accent.withValues(alpha: .08) : null),
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: t.text),
            ),
          ),
        );
      case GridSheetCellKind.selectAll:
      case GridSheetCellKind.filter:
        return null;
    }
  }

  /// 第一次点击:只把整行整列高亮;再次点击同一格:进入编辑
  void _onCellTap(int row, int column) {
    if (row == _row && column == _col) {
      _cellEditor.text = _table.cellAt(row, column);
      _cellEditor.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _cellEditor.text.length,
      );
      setState(() => _editingCell = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _cellFocus.requestFocus();
      });
      return;
    }
    setState(() {
      _row = row;
      _col = column;
      _editingCell = false;
    });
  }

  Widget _buildCellEditor(SyphonTheme t, int row, int column) {
    return Material(
      type: MaterialType.transparency,
      child: Focus(
        onKeyEvent: _onEditorKey,
        // 编辑态:纯白背景
        child: Container(
          key: _editorKey,
          color: Colors.white,
          child: TextField(
            key: const ValueKey('sheet-cell-editor'),
            controller: _cellEditor,
            focusNode: _cellFocus,
            autofocus: true,
            style: TextStyle(fontSize: 12, color: t.text),
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(horizontal: 6),
            ),
            onChanged: (_) => _refreshSuggestions(),
            onSubmitted: (_) => _commitCellEditor(),
          ),
        ),
      ),
    );
  }

  KeyEventResult _onEditorKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (_suggestions.isNotEmpty) {
      if (key == LogicalKeyboardKey.arrowDown) {
        setState(
          () => _suggestionIndex = (_suggestionIndex + 1) % _suggestions.length,
        );
        _showSuggestions();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        setState(
          () => _suggestionIndex =
              (_suggestionIndex - 1 + _suggestions.length) % _suggestions.length,
        );
        _showSuggestions();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.tab ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter) {
        _acceptSuggestion(_suggestions[_suggestionIndex]);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape) {
        _hideSuggestions();
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.escape) {
      _hideSuggestions();
      setState(() => _editingCell = false);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _commitCellEditor();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ==================== 公式提示(类似代码补全) ====================

  /// 光标前的标识符前缀 → 过滤函数名;`=` 之后或 `(`/`,`/运算符之后列全部
  void _refreshSuggestions() {
    final text = _cellEditor.text;
    if (!text.trimLeft().startsWith('=')) {
      _hideSuggestions();
      return;
    }
    final caret = _cellEditor.selection.isValid
        ? _cellEditor.selection.start
        : text.length;
    final head = text.substring(0, caret);
    final match = RegExp(r'([A-Za-z]+)$').firstMatch(head);
    final prefix = match?.group(1)?.toUpperCase() ?? '';
    final tail = head.substring(0, head.length - prefix.length);
    final allowed =
        prefix.isNotEmpty ||
        tail.isEmpty ||
        RegExp(r'[=(,+\-*/^:]$').hasMatch(tail);
    final next = allowed
        ? [
            for (final f in _kFormulaFunctions)
              if (f.startsWith(prefix)) f,
          ]
        : const <String>[];
    setState(() {
      _suggestions = next;
      _suggestionIndex = 0;
    });
    if (next.isEmpty) {
      _hideSuggestions();
    } else {
      _showSuggestions();
    }
  }

  void _showSuggestions() {
    _suggestionEntry?.remove();
    _suggestionEntry = null;
    final box = _editorKey.currentContext?.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
    final theme = SyphonTheme.of(context);
    _suggestionEntry = OverlayEntry(
      builder: (ctx) => Positioned(
        left: origin.dx,
        top: origin.dy + box.size.height,
        child: Material(
          color: Colors.transparent,
          child: Container(
            constraints: const BoxConstraints(minWidth: 132),
            decoration: BoxDecoration(
              color: theme.bgFloat,
              border: Border.all(color: theme.strokeStrong),
              borderRadius: BorderRadius.circular(SyphonDims.radiusS),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: .2),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < _suggestions.length; i++)
                  GestureDetector(
                    key: ValueKey('formula-suggestion-$i'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _acceptSuggestion(_suggestions[i]),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      color: i == _suggestionIndex
                          ? theme.accent.withValues(alpha: .18)
                          : null,
                      child: Text(
                        _suggestions[i].replaceAll('(', ''),
                        style: TextStyle(fontSize: 11.5, color: theme.text),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_suggestionEntry!);
  }

  void _hideSuggestions() {
    _suggestionEntry?.remove();
    _suggestionEntry = null;
    if (_suggestions.isNotEmpty) _suggestions = const [];
  }

  /// 用提示里的函数替换光标前的标识符
  void _acceptSuggestion(String function) {
    final text = _cellEditor.text;
    final caret = _cellEditor.selection.isValid
        ? _cellEditor.selection.start
        : text.length;
    final head = text.substring(0, caret);
    final match = RegExp(r'[A-Za-z]*$').firstMatch(head)!;
    final next = text.replaceRange(match.start, caret, function);
    _cellEditor.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: match.start + function.length),
    );
    _hideSuggestions();
    _cellFocus.requestFocus();
  }

  // ==================== 编辑时圈选多行多列 ====================

  void _insertAtCaret(String snippet) {
    final value = _cellEditor.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    final next = value.text.replaceRange(start, end, snippet);
    _cellEditor.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + snippet.length),
    );
    _refreshSuggestions();
  }

  /// 拖拽中的范围高亮
  bool _inDragRange(int row, int column) {
    final a = _rangeAnchor;
    final b = _rangeEnd;
    if (a == null || b == null) return false;
    final r0 = a.row < b.row ? a.row : b.row;
    final r1 = a.row < b.row ? b.row : a.row;
    final c0 = a.column < b.column ? a.column : b.column;
    final c1 = a.column < b.column ? b.column : a.column;
    return row >= r0 && row <= r1 && column >= c0 && column <= c1;
  }

  /// 圈选结束:插入 `A1` 或 `A1:B3`
  void _insertRangeRef() {
    final a = _rangeAnchor;
    final b = _rangeEnd ?? a;
    if (a == null || b == null) return;
    setState(() {
      _rangeAnchor = null;
      _rangeEnd = null;
    });
    final r0 = a.row < b.row ? a.row : b.row;
    final r1 = a.row < b.row ? b.row : a.row;
    final c0 = a.column < b.column ? a.column : b.column;
    final c1 = a.column < b.column ? b.column : a.column;
    final start = '${columnLetter(c0)}${r0 + 1}';
    final snippet = (r0 == r1 && c0 == c1)
        ? start
        : '$start:${columnLetter(c1)}${r1 + 1}';
    _insertAtCaret(snippet);
  }


  void _commitCellEditor() {
    final text = _cellEditor.text;
    final row = _row;
    final column = _col;
    if (mounted) setState(() => _editingCell = false);
    if (_table.cellAt(row, column) == text) return;
    _history.record(_table);
    _table.setCell(row, column, text);
    _commit();
    setState(() => _generation++);
  }

  void _onCellChanged(GridSheetCellValueChangedEvent event) {
    _editingCell = false;
    final row = _rowIndexOf(event.rowKey);
    final column = event.columnIndex;
    if (row < 0 || column < 0 || column >= _table.columnCount) return;
    // 单元格里保留公式原文(库把求值结果放在 data 里),节点侧再求值
    final formula = _manager?.getCellFormula(
      rowKey: event.rowKey,
      columnKey: event.columnKey,
    );
    final text = formula ?? _cellText(event.newValue);
    if (_table.cellAt(row, column) == text) return;
    _row = row;
    _col = column;
    _history.record(_table);
    _table.setCell(row, column, text);
    _commit();
    setState(() {});
  }

  String _cellText(dynamic value) {
    if (value == null) return '';
    if (value is double && value == value.roundToDouble()) {
      return value.toInt().toString();
    }
    return '$value';
  }

  // ==================== 键盘(补 pluto 未覆盖的键) ====================

  bool get _typingInCell {
    final context = FocusManager.instance.primaryFocus?.context;
    return context != null &&
        context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  KeyEventResult _onGridKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (_typingInCell) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed || keyboard.isMetaPressed) {
      // 复制/粘贴/全选交给 pluto_grid 自己的快捷键
      if (key == LogicalKeyboardKey.keyZ) {
        keyboard.isShiftPressed ? _redo() : _undo();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyY) {
        _redo();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.delete || key == LogicalKeyboardKey.backspace) {
      // 清空当前单元格(不能让 Delete 冒泡到画布删掉整个节点)
      _mutate((t) => t.setCell(_row, _col, ''));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      closeTableWindow();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ==================== 撤销 / 重做 ====================

  void _undo() {
    final previous = _history.undo(_table);
    if (previous == null) return;
    _table = previous;
    _clampCursor();
    _commit();
    setState(() => _generation++);
  }

  void _redo() {
    final next = _history.redo(_table);
    if (next == null) return;
    _table = next;
    _clampCursor();
    _commit();
    setState(() => _generation++);
  }

  // ==================== 骨架 ====================

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    final geometry = widget.geometry;
    return BlurScaleTransition(
      animation: _entryCurve,
      beginScale: .96,
      maxBlur: 6,
      elastic: false,
      child: Container(
        decoration: BoxDecoration(
          color: t.bgFloat,
          border: Border.all(color: t.strokeStrong),
          borderRadius: BorderRadius.circular(SyphonDims.radiusM),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: t.isDark ? .5 : .22),
              blurRadius: 28,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildTitleBar(t, geometry),
                _buildToolBar(t),
                Expanded(child: _buildGrid(t)),
                _buildStatusBar(t),
              ],
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (details) => geometry.resizeBy(details.delta),
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeDownRight,
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CustomPaint(
                      painter: _ResizeGripPainter(t.textFaint),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTitleBar(SyphonTheme t, _WindowGeometry geometry) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: (details) => geometry.moveBy(details.delta),
      child: MouseRegion(
        cursor: SystemMouseCursors.move,
        child: Container(
          height: _titleBarH,
          padding: const EdgeInsets.only(left: 10, right: 4),
          decoration: BoxDecoration(
            color: t.bgRaise,
            border: Border(bottom: BorderSide(color: t.stroke)),
          ),
          child: Row(
            children: [
              Text('⊞', style: TextStyle(fontSize: 13, color: t.accent)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: t.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _WinIconButton(
                icon: Icons.undo,
                enabled: _history.canUndo,
                onPressed: _undo,
              ),
              _WinIconButton(
                icon: Icons.redo,
                enabled: _history.canRedo,
                onPressed: _redo,
              ),
              const _WinBarDivider(),
              _WinIconButton(icon: Icons.close, onPressed: closeTableWindow),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToolBar(SyphonTheme t) {
    final hasColumn = _table.columnCount > 0;
    final column = hasColumn ? _col.clamp(0, _table.columnCount - 1) : 0;
    return Container(
      height: _toolBarH,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: t.bgSurface,
        border: Border(bottom: BorderSide(color: t.stroke)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _WinButton(
              label: '插入行',
              onPressed: () => _mutate((t) => t.insertRow(_row)),
            ),
            _WinButton(
              label: '删除行',
              enabled: _table.rowCount > 0,
              onPressed: () => _mutate((t) => t.removeRow(_row)),
            ),
            const _WinBarDivider(),
            _WinButton(
              label: '插入列',
              onPressed: () => _mutate((t) => t.insertColumn(_col)),
            ),
            _WinButton(
              label: '删除列',
              enabled: _table.columnCount > 1,
              onPressed: () => _mutate((t) => t.removeColumn(_col)),
            ),
            _WinButton(
              label: '清空单元格',
              enabled: _table.rowCount > 0 && _table.columnCount > 0,
              onPressed: () => _mutate((t) => t.setCell(_row, _col, '')),
            ),
            const _WinBarDivider(),
            if (hasColumn) ...[
              Text(
                '列 ${columnLetter(column)}',
                style: TextStyle(
                  fontSize: 11,
                  color: t.textFaint,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 6),
              _WinField(
                key: ValueKey('table-col-name-$column'),
                value: _table.names[column],
                placeholder: '列名',
                width: 96,
                onSubmit: (name) {
                  if (name == _table.names[column]) return;
                  _mutate((t) => t.setColumnName(column, name));
                },
              ),
              const SizedBox(width: 8),
              _WinField(
                key: ValueKey('table-col-type-$column'),
                value: columnTypeLabel(_table.types[column]),
                width: 88,
                dropdown: {
                  for (final e in kColumnTypeLabels.entries) e.value: () => _mutate(
                    (t) => t.setColumnType(column, e.key),
                  ),
                },
              ),
              const SizedBox(width: 6),
              _WinField(
                key: ValueKey('table-col-flag-$column'),
                value: columnDesignationLabel(_table.designations[column]).isEmpty
                    ? '无标记'
                    : '[${columnDesignationLabel(_table.designations[column])}]',
                width: 82,
                dropdown: {
                  for (final e in kColumnDesignationLabels.entries)
                    (e.value.isEmpty ? '无标记' : '[${e.value}]'): () => _mutate(
                      (t) => t.setColumnDesignation(column, e.key),
                    ),
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildGrid(SyphonTheme t) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: t.danger),
          ),
        ),
      );
    }
    if (_table.columnCount == 0) {
      return Center(
        child: Text(
          '空表:点击工具条的「插入列」开始',
          style: TextStyle(fontSize: 11, color: t.textFaint),
        ),
      );
    }
    return Material(
      // grid_sheet 的单元格编辑器是 Material TextField,而应用根是 FluentApp
      type: MaterialType.transparency,
      child: Focus(
        onKeyEvent: _onGridKey,
        child: GridSheet(
          key: ValueKey('table-grid-$_generation'),
          columns: _sheetColumns(),
          rows: _sheetRows(),
          cellBuilder: _sheetCellBuilder,
          // 与设计图一致:全部数据放在一张表里,不翻页、不显示行号列
          indexColumn: null,
          configuration: const GridSheetConfiguration(
            enableDefaultPagination: false,
            showColumnFilters: false,
            stretchColumnsToFillWidth: true,
          ),
          autofillConfiguration: const GridSheetAutoFillConfiguration(
            enabled: true,
            fillHandleSize: 7,
          ),
          styleConfiguration: GridSheetStyleConfiguration(
            gridBackgroundColor: t.bgApp,
            rowColor: t.bgFloat,
            headerColor: t.bgRaise,
            gridBorderColor: t.stroke,
            rowBorderColor: t.stroke,
            columnBorderColor: t.stroke,
            selectionColor: t.accent,
            cellTextStyle: TextStyle(fontSize: 12, color: t.text),
            headerTextStyle: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: t.text,
            ),
          ),
          onLoaded: (event) {
            _manager = event.gridManager;
            _clampCursor();
          },
          onCellValueChanged: _onCellChanged,
        ),
      ),
    );
  }

  Widget _buildStatusBar(SyphonTheme t) {
    return Container(
      height: _statusBarH,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: t.bgRaise,
        border: Border(top: BorderSide(color: t.stroke)),
      ),
      child: Text(
        '${_table.rowCount} 行 × ${_table.columnCount} 列',
        style: TextStyle(fontSize: 10, color: t.textDim),
      ),
    );
  }
}

// ==================== 小控件 ====================

class _ResizeGripPainter extends CustomPainter {
  final Color color;

  const _ResizeGripPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: .8)
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 3; i++) {
      final offset = 4.0 + i * 4;
      canvas.drawLine(
        Offset(size.width - offset, size.height - 2),
        Offset(size.width - 2, size.height - offset),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ResizeGripPainter old) => old.color != color;
}

class _WinBarDivider extends StatelessWidget {
  const _WinBarDivider();

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    return Container(
      width: 1,
      height: 16,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      color: t.stroke,
    );
  }
}

class _WinButton extends StatefulWidget {
  const _WinButton({
    required this.label,
    required this.onPressed,
    this.enabled = true,
  });

  final String label;
  final VoidCallback onPressed;
  final bool enabled;

  @override
  State<_WinButton> createState() => _WinButtonState();
}

class _WinButtonState extends State<_WinButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    final enabled = widget.enabled;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? widget.onPressed : null,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 2),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: enabled && _hover ? t.bgRaise : Colors.transparent,
            borderRadius: BorderRadius.circular(SyphonDims.radiusS),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 11,
              color: enabled
                  ? (_hover ? t.text : t.textDim)
                  : t.textFaint.withValues(alpha: .5),
            ),
          ),
        ),
      ),
    );
  }
}

class _WinIconButton extends StatefulWidget {
  const _WinIconButton({
    required this.icon,
    required this.onPressed,
    this.enabled = true,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final bool enabled;

  @override
  State<_WinIconButton> createState() => _WinIconButtonState();
}

class _WinIconButtonState extends State<_WinIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    final enabled = widget.enabled;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? widget.onPressed : null,
        child: Container(
          width: 26,
          height: 24,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: enabled && _hover ? t.bgFloat : Colors.transparent,
            borderRadius: BorderRadius.circular(SyphonDims.radiusS),
          ),
          child: Icon(
            widget.icon,
            size: 15,
            color: enabled
                ? (_hover ? t.text : t.textDim)
                : t.textFaint.withValues(alpha: .45),
          ),
        ),
      ),
    );
  }
}

/// 工具条上的紧凑输入框 / 点击下拉(样式与属性面板输入框一致)
class _WinField extends StatefulWidget {
  const _WinField({
    super.key,
    required this.value,
    this.placeholder,
    this.onSubmit,
    this.width = 96,
    this.dropdown,
  });

  final String value;
  final String? placeholder;
  final ValueChanged<String>? onSubmit;
  final double width;

  /// 非空时点击弹出一个下拉列表(值 → 回调)
  final Map<String, VoidCallback>? dropdown;

  @override
  State<_WinField> createState() => _WinFieldState();
}

class _WinFieldState extends State<_WinField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.value,
  );
  final FocusNode _focus = FocusNode(debugLabel: 'table-field');
  bool _hover = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) widget.onSubmit?.call(_controller.text);
    });
  }

  @override
  void didUpdateWidget(covariant _WinField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && _controller.text != widget.value) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    final dropdown = widget.dropdown;
    final body = dropdown == null
        ? Material(
            type: MaterialType.transparency,
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              style: TextStyle(fontSize: 11, color: t.text),
              cursorColor: t.accent,
              decoration: InputDecoration(
                isDense: true,
                hintText: widget.placeholder,
                hintStyle: TextStyle(fontSize: 11, color: t.textFaint),
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
              onSubmitted: widget.onSubmit,
            ),
          )
        : Row(
            children: [
              Expanded(
                child: Text(
                  widget.value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: t.text),
                ),
              ),
              Icon(Icons.arrow_drop_down, size: 14, color: t.textDim),
            ],
          );
    return MouseRegion(
      cursor: dropdown == null
          ? SystemMouseCursors.text
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: dropdown == null ? null : () => _openDropdown(dropdown),
        child: Container(
          width: widget.width,
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: t.bgInput,
            border: Border.all(
              color: _focus.hasFocus || _hover ? t.strokeStrong : t.stroke,
            ),
            borderRadius: BorderRadius.circular(SyphonDims.radiusS),
          ),
          child: Center(child: body),
        ),
      ),
    );
  }

  Future<void> _openDropdown(Map<String, VoidCallback> items) async {
    final t = SyphonTheme.of(context);
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
    final chosen = await showMenu<String>(
      context: context,
      color: t.bgFloat,
      position: RelativeRect.fromLTRB(
        origin.dx,
        origin.dy + box.size.height + 2,
        overlay.size.width - origin.dx - box.size.width,
        0,
      ),
      items: [
        for (final entry in items.keys)
          PopupMenuItem<String>(
            value: entry,
            height: 30,
            child: Text(
              entry,
              style: TextStyle(fontSize: 11, color: t.text),
            ),
          ),
      ],
    );
    if (chosen != null) items[chosen]?.call();
  }
}
