// 表格编辑浮窗:双击「表格输入」节点(或属性面板的「编辑表格…」按钮)弹出,
// 一个独立、可拖动、可缩放的窗口,具备电子表格的基础能力:
//   · 单元格编辑(双击 / 直接输入 / Enter 提交 / Esc 取消 / 方向键移动)
//   · 增删行列、清空选区、列名重命名(表头双击)
//   · 列类型({双精度浮点}/{整数}/{文本})与列标记([X]/[Y]/[Z]/误差列)
//   · 框选(Shift+方向键 / Shift+点击)、Ctrl+C/X/V 与系统剪贴板互通
//   · Ctrl+Z / Ctrl+Y 撤销重做(只影响本窗口内的编辑)
//
// 编辑立即写回节点参数(tableJson),自动执行开启时图表随之刷新;
// 表头与行号固定不滚动(与 Excel 一致的冻结窗格),整片单元格共用一个手势
// 识别器(按固定单元格尺寸换算行列),避免为上千个单元格各建一套识别器。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

// 表格度量:固定单元格尺寸,冻结表头与主体按同一套数值滚动
const double _cellW = 132;
const double _cellH = 26;
const double _rowHeadW = 46;
const double _colHeadH = 38;
const double _titleBarH = 34;
const double _toolBarH = 40;
const double _statusBarH = 24;
const Size _minWindow = Size(460, 280);

/// 浮窗层:挂在应用最上层(见 main.dart 的 Stack),未打开时不占任何命中区域。
class TableWindowLayer extends StatefulWidget {
  const TableWindowLayer({super.key});

  @override
  State<TableWindowLayer> createState() => _TableWindowLayerState();
}

class _TableWindowLayerState extends State<TableWindowLayer> {
  // 几何跨节点、跨开关保留:关闭再打开保持上次的位置与大小
  Offset? _pos;
  Size _size = const Size(820, 540);

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
            final area = constraints.biggest;
            final size = Size(
              _size.width.clamp(_minWindow.width, math.max(_minWindow.width, area.width - 16)),
              _size.height.clamp(_minWindow.height, math.max(_minWindow.height, area.height - 16)),
            );
            final pos =
                _pos ??
                Offset(
                  math.max(10, (area.width - size.width) / 2),
                  math.max(10, (area.height - size.height) / 3),
                );
            return Stack(
              children: [
                Positioned(
                  left: pos.dx.clamp(-(size.width - 120), math.max(0.0, area.width - 120)),
                  top: pos.dy.clamp(0.0, math.max(0.0, area.height - _titleBarH)),
                  width: size.width,
                  height: size.height,
                  child: _TableWindow(
                    key: ValueKey('table-window-$id'),
                    nodeId: id,
                    initialPosition: pos,
                    initialSize: size,
                    onGeometry: (p, s) {
                      _pos = p;
                      _size = s;
                    },
                  ),
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
    required this.initialPosition,
    required this.initialSize,
    required this.onGeometry,
  });

  final String nodeId;
  final Offset initialPosition;
  final Size initialSize;
  final void Function(Offset position, Size size) onGeometry;

  @override
  State<_TableWindow> createState() => _TableWindowState();
}

class _TableWindowState extends State<_TableWindow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entry;
  late final Animation<double> _entryCurve;

  Offset _position = Offset.zero;
  Size _size = const Size(820, 540);

  EditableTable _table = EditableTable.empty();
  final TableEditHistory _history = TableEditHistory();
  final FocusNode _gridFocus = FocusNode(debugLabel: 'table-grid');
  final FocusNode _editFocus = FocusNode(debugLabel: 'table-cell');
  final TextEditingController _editText = TextEditingController();

  final ScrollController _hBody = ScrollController();
  final ScrollController _vBody = ScrollController();
  final ScrollController _hHead = ScrollController();
  final ScrollController _vHead = ScrollController();

  /// 光标单元格与选区锚点(选区 = 两者围成的矩形)
  int _row = 0;
  int _col = 0;
  int _anchorRow = 0;
  int _anchorCol = 0;

  bool _editing = false;
  int? _renamingColumn;
  String? _error;
  String _title = '表格编辑';
  String _sourceStamp = '';
  bool _fromPreset = false;

  /// 正在写回节点:期间的 store 通知不算外部改动
  bool _writing = false;

  @override
  void initState() {
    super.initState();
    _position = widget.initialPosition;
    _size = widget.initialSize;
    // 时长依赖 MediaQuery(动画倍率),只能在 didChangeDependencies 里设置
    _entry = AnimationController(vsync: this);
    _entryCurve = CurvedAnimation(
      parent: _entry,
      curve: MotionTokens.emphasized,
    );
    _loadFromNode();
    _hBody.addListener(_syncHorizontal);
    _vBody.addListener(_syncVertical);
    _editFocus.addListener(_onEditFocusChanged);
    GraphStore.instance.addListener(_onStoreChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _gridFocus.requestFocus();
    });
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
  void didUpdateWidget(covariant _TableWindow old) {
    super.didUpdateWidget(old);
    // 父级按我们上报的几何重新定位:同步本地副本,保证增量拖动/缩放不漂移
    _position = widget.initialPosition;
    _size = widget.initialSize;
  }

  @override
  void dispose() {
    GraphStore.instance.removeListener(_onStoreChanged);
    _hBody.dispose();
    _vBody.dispose();
    _hHead.dispose();
    _vHead.dispose();
    _editFocus.removeListener(_onEditFocusChanged);
    _editFocus.dispose();
    _gridFocus.dispose();
    _editText.dispose();
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
    _editing = false;
    _renamingColumn = null;

    final edited = EditableTable.decode('${node.params['tableJson'] ?? ''}');
    if (edited != null) {
      _table = edited;
      _fromPreset = false;
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
          ? EditableTable.empty()
          : EditableTable.fromColumns(columns);
      _fromPreset = false;
    } else {
      _table = EditableTable.fromColumns(
        presetTable(
          '${node.params['preset'] ?? 'phys'}',
          seed: num.tryParse('${node.params['seed'] ?? 0}')?.round() ?? 0,
        ),
      );
      _fromPreset = true;
    }
    _row = 0;
    _col = 0;
    _anchorRow = 0;
    _anchorCol = 0;
  }

  /// 把当前表格写回节点参数;自动执行开启时图表随之刷新
  void _commit() {
    final store = GraphStore.instance;
    if (store.nodeOf(widget.nodeId) == null) return;
    // 写回会同步触发 store 通知;期间必须忽略,否则会被当成"外部改动"重载,
    // 把撤销历史清空(表现为撤销按一次后就变成不可用)。
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
    _fromPreset = false;
    final node = store.nodeOf(widget.nodeId);
    if (node != null) _sourceStamp = _stampOf(node);
  }

  void _mutate(void Function(EditableTable table) op, {bool commit = true}) {
    _history.record(_table);
    op(_table);
    _clampCursor();
    if (commit) _commit();
    setState(() {});
    _ensureCursorVisible();
  }

  void _onStoreChanged() {
    if (!mounted || _writing) return;
    final node = GraphStore.instance.nodeOf(widget.nodeId);
    if (node == null) {
      closeTableWindow();
      return;
    }
    // 外部改动(重新导入文件、切换预设等):非编辑状态下重新载入
    if (_editing || _renamingColumn != null || _stampOf(node) == _sourceStamp) {
      return;
    }
    setState(_loadFromNode);
  }

  void _syncHorizontal() {
    if (!_hHead.hasClients || !_hBody.hasClients) return;
    if ((_hHead.offset - _hBody.offset).abs() < 0.5) return;
    _hHead.jumpTo(
      _hBody.offset.clamp(
        _hHead.position.minScrollExtent,
        _hHead.position.maxScrollExtent,
      ),
    );
  }

  void _syncVertical() {
    if (!_vHead.hasClients || !_vBody.hasClients) return;
    if ((_vHead.offset - _vBody.offset).abs() < 0.5) return;
    _vHead.jumpTo(
      _vBody.offset.clamp(
        _vHead.position.minScrollExtent,
        _vHead.position.maxScrollExtent,
      ),
    );
  }

  // ==================== 光标 / 选区 ====================

  void _clampCursor() {
    _row = _table.rowCount == 0 ? 0 : _row.clamp(0, _table.rowCount - 1);
    _col = _table.columnCount == 0 ? 0 : _col.clamp(0, _table.columnCount - 1);
    _anchorRow = _table.rowCount == 0
        ? 0
        : _anchorRow.clamp(0, _table.rowCount - 1);
    _anchorCol = _table.columnCount == 0
        ? 0
        : _anchorCol.clamp(0, _table.columnCount - 1);
  }

  int get _selTop => _table.rowCount == 0 ? 0 : math.min(_row, _anchorRow);
  int get _selBottom => _table.rowCount == 0 ? -1 : math.max(_row, _anchorRow);
  int get _selLeft => _table.columnCount == 0 ? 0 : math.min(_col, _anchorCol);
  int get _selRight =>
      _table.columnCount == 0 ? -1 : math.max(_col, _anchorCol);

  bool _inSelection(int row, int column) =>
      row >= _selTop &&
      row <= _selBottom &&
      column >= _selLeft &&
      column <= _selRight;

  void _moveCursor(int dRow, int dColumn, {bool extend = false}) {
    _row = (_row + dRow).clamp(0, math.max(0, _table.rowCount - 1));
    _col = (_col + dColumn).clamp(0, math.max(0, _table.columnCount - 1));
    if (!extend) {
      _anchorRow = _row;
      _anchorCol = _col;
    }
    setState(() {});
    _ensureCursorVisible();
  }

  void _ensureCursorVisible() {
    if (_table.rowCount == 0 || _table.columnCount == 0) return;
    if (_vBody.hasClients && _vBody.position.haveDimensions) {
      final viewport = _vBody.position.viewportDimension;
      final top = _row * _cellH;
      final bottom = top + _cellH;
      final offset = _vBody.offset;
      if (top < offset) {
        _vBody.jumpTo(top);
      } else if (bottom > offset + viewport) {
        _vBody.jumpTo(bottom - viewport);
      }
    }
    if (_hBody.hasClients && _hBody.position.haveDimensions) {
      final viewport = _hBody.position.viewportDimension;
      final left = _col * _cellW;
      final right = left + _cellW;
      final offset = _hBody.offset;
      if (left < offset) {
        _hBody.jumpTo(left);
      } else if (right > offset + viewport) {
        _hBody.jumpTo(right - viewport);
      }
    }
  }

  // ==================== 单元格编辑 ====================

  void _beginEdit({String? initial, int? row, int? column}) {
    if (row != null) _row = row;
    if (column != null) _col = column;
    if (_table.rowCount == 0 || _table.columnCount == 0) return;
    final text = initial ?? _table.cellAt(_row, _col);
    _editText.value = TextEditingValue(
      text: text,
      selection: TextSelection(
        baseOffset: 0,
        extentOffset: text.length,
      ),
    );
    _clampCursor();
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editing) _editFocus.requestFocus();
    });
  }

  void _commitEdit({int dRow = 0, int dColumn = 0}) {
    if (!_editing) return;
    final next = _editText.text;
    final row = _row;
    final column = _col;
    final changed = next != _table.cellAt(row, column);
    setState(() => _editing = false);
    if (changed) {
      _history.record(_table);
      _table.setCell(row, column, next);
      _commit();
    }
    if (dRow != 0 || dColumn != 0) {
      _moveCursor(dRow, dColumn);
    } else {
      _gridFocus.requestFocus();
    }
  }

  void _cancelEdit() {
    if (!_editing) return;
    setState(() => _editing = false);
    _gridFocus.requestFocus();
  }

  void _onEditFocusChanged() {
    if (_editFocus.hasFocus || !_editing) return;
    // 焦点被别的控件拿走(点了别的单元格/工具条):提交当前输入
    _commitEdit();
  }

  // ==================== 剪贴板 / 撤销 ====================

  Future<void> _copy({bool cut = false}) async {
    if (_table.rowCount == 0 || _table.columnCount == 0) return;
    await Clipboard.setData(
      ClipboardData(
        text: _table.blockToTsv(_selTop, _selLeft, _selBottom, _selRight),
      ),
    );
    if (cut) {
      _mutate((t) => t.clearRange(_selTop, _selLeft, _selBottom, _selRight));
    }
  }

  Future<void> _paste() async {
    if (_table.columnCount == 0) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    final block = EditableTable.parseClipboard(text);
    if (block.isEmpty) return;
    final row = _selTop;
    final column = _selLeft;
    _mutate((t) => t.pasteBlock(row, column, block));
    setState(() {
      _row = math.min(row + block.length - 1, math.max(0, _table.rowCount - 1));
      _col = column;
      _anchorRow = row;
      _anchorCol = column;
    });
  }

  void _undo() {
    final previous = _history.undo(_table);
    if (previous == null) return;
    setState(() {
      _table = previous;
      _clampCursor();
    });
    _commit();
    _ensureCursorVisible();
  }

  void _redo() {
    final next = _history.redo(_table);
    if (next == null) return;
    setState(() {
      _table = next;
      _clampCursor();
    });
    _commit();
    _ensureCursorVisible();
  }

  // ==================== 键盘 ====================

  KeyEventResult _onGridKey(FocusNode node, KeyEvent event) {
    // 焦点在单元格编辑器/工具条输入框里时交给它们处理
    if (!_gridFocus.hasFocus) return KeyEventResult.ignored;
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    final shift = keyboard.isShiftPressed;

    if (keyboard.isControlPressed || keyboard.isMetaPressed) {
      if (key == LogicalKeyboardKey.keyZ) {
        shift ? _redo() : _undo();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyY) {
        _redo();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyC) {
        _copy();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyX) {
        _copy(cut: true);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyV) {
        _paste();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyA) {
        setState(() {
          _anchorRow = 0;
          _anchorCol = 0;
          _row = math.max(0, _table.rowCount - 1);
          _col = math.max(0, _table.columnCount - 1);
        });
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.arrowLeft) {
      _moveCursor(0, -1, extend: shift);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _moveCursor(0, 1, extend: shift);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveCursor(-1, 0, extend: shift);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveCursor(1, 0, extend: shift);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab) {
      _moveCursor(0, shift ? -1 : 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.f2) {
      _beginEdit();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      _mutate((t) => t.clearRange(_selTop, _selLeft, _selBottom, _selRight));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      _moveCursor(0, -_table.columnCount, extend: shift);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      _moveCursor(0, _table.columnCount, extend: shift);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      closeTableWindow();
      return KeyEventResult.handled;
    }

    final character = event.character;
    if (character != null &&
        character.isNotEmpty &&
        character.codeUnitAt(0) >= 32) {
      _beginEdit(initial: character);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _onEditorKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _cancelEdit();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _commitEdit(dRow: 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab) {
      final back = HardwareKeyboard.instance.isShiftPressed;
      _commitEdit(dColumn: back ? -1 : 1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ==================== 拖动 / 缩放 ====================

  void _dragWindow(Offset delta, Size bounds) {
    final pos = Offset(
      (_position.dx + delta.dx).clamp(-(_size.width - 120), bounds.width - 120),
      (_position.dy + delta.dy).clamp(0.0, math.max(0.0, bounds.height - 30)),
    );
    _position = pos;
    widget.onGeometry(pos, _size);
  }

  void _resizeWindow(Offset delta, Size bounds) {
    final size = Size(
      (_size.width + delta.dx).clamp(_minWindow.width, bounds.width),
      (_size.height + delta.dy).clamp(_minWindow.height, bounds.height),
    );
    _size = size;
    widget.onGeometry(_position, size);
  }

  // ==================== 骨架 ====================

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final bounds = constraints.biggest;
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
                    _buildTitleBar(t, bounds),
                    _buildToolBar(t),
                    Expanded(child: _buildGrid(t)),
                    _buildStatusBar(t),
                  ],
                ),
                // 右下角缩放手柄
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: (d) => _resizeWindow(d.delta, bounds),
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
      },
    );
  }

  // ==================== 标题栏 ====================

  Widget _buildTitleBar(SyphonTheme t, Size bounds) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: (details) => _dragWindow(details.delta, bounds),
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

  // ==================== 工具条 ====================

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
              onPressed: () => _mutate((t) => t.insertRow(_selTop)),
            ),
            _WinButton(
              label: '删除行',
              enabled: _table.rowCount > 0,
              onPressed: () => _mutate((t) => t.removeRow(_selTop)),
            ),
            const _WinBarDivider(),
            _WinButton(
              label: '插入列',
              onPressed: () => _mutate((t) => t.insertColumn(_selLeft)),
            ),
            _WinButton(
              label: '删除列',
              enabled: _table.columnCount > 1,
              onPressed: () => _mutate((t) => t.removeColumn(_selLeft)),
            ),
            _WinButton(
              label: '清空',
              enabled: _table.rowCount > 0 && _table.columnCount > 0,
              onPressed: () => _mutate(
                (t) => t.clearRange(_selTop, _selLeft, _selBottom, _selRight),
              ),
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
                key: ValueKey('table-col-type-label-$column'),
                value: columnTypeLabel(_table.types[column]),
                width: 88,
                dropdown: {
                  for (final e in kColumnTypeLabels.entries) e.value: () {
                    _mutate((t) => t.setColumnType(column, e.key));
                  },
                },
              ),
              const SizedBox(width: 6),
              _WinField(
                key: ValueKey('table-col-flag-label-$column'),
                value: columnDesignationLabel(_table.designations[column]).isEmpty
                    ? '无标记'
                    : '[${columnDesignationLabel(_table.designations[column])}]',
                width: 82,
                dropdown: {
                  for (final e in kColumnDesignationLabels.entries)
                    (e.value.isEmpty ? '无标记' : '[${e.value}]'): () {
                      _mutate((t) => t.setColumnDesignation(column, e.key));
                    },
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ==================== 网格 ====================

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
    return Container(
      color: t.bgApp,
      child: Focus(
        focusNode: _gridFocus,
        onKeyEvent: _onGridKey,
        child: Column(
          children: [
            SizedBox(height: _colHeadH, child: _buildHeaderRow(t)),
            Expanded(
              child: Row(
                children: [
                  SizedBox(width: _rowHeadW, child: _buildRowHeader(t)),
                  Expanded(
                    child: ScrollConfiguration(
                      behavior: ScrollConfiguration.of(
                        context,
                      ).copyWith(scrollbars: false),
                      child: SingleChildScrollView(
                        controller: _vBody,
                        child: SingleChildScrollView(
                          controller: _hBody,
                          scrollDirection: Axis.horizontal,
                          child: _buildCellArea(t),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderRow(SyphonTheme t) {
    return Row(
      children: [
        Container(
          width: _rowHeadW,
          height: _colHeadH,
          decoration: BoxDecoration(
            color: t.bgRaise,
            border: Border(
              right: BorderSide(color: t.strokeStrong),
              bottom: BorderSide(color: t.strokeStrong),
            ),
          ),
        ),
        Expanded(
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(
              context,
            ).copyWith(scrollbars: false),
            child: SingleChildScrollView(
              controller: _hHead,
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              child: Row(
                children: [
                  for (var c = 0; c < _table.columnCount; c++)
                    _buildColumnHeader(t, c),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildColumnHeader(SyphonTheme t, int column) {
    final selected = column >= _selLeft && column <= _selRight;
    final designation = _table.designations[column];
    final flag = columnDesignationLabel(designation);
    final flagColor = switch (designation) {
      'x' => const Color(0xFF3B82F6),
      'y' => const Color(0xFF22C55E),
      'z' => const Color(0xFFF59E0B),
      'xerr' || 'yerr' => t.danger,
      _ => t.textFaint,
    };
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() {
        _col = column;
        _anchorCol = column;
        if (_table.rowCount > 0) {
          _anchorRow = 0;
          _row = _table.rowCount - 1;
        }
      }),
      onDoubleTap: () => _startRename(column),
      child: Container(
        width: _cellW,
        height: _colHeadH,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: selected ? t.accent.withValues(alpha: .14) : t.bgRaise,
          border: Border(
            right: BorderSide(color: t.strokeStrong),
            bottom: BorderSide(color: t.strokeStrong),
          ),
        ),
        child: _renamingColumn == column
            ? Center(
                child: _WinField(
                  key: const ValueKey('table-col-rename'),
                  value: _table.names[column],
                  placeholder: '列名',
                  autofocus: true,
                  onSubmit: (name) {
                    setState(() => _renamingColumn = null);
                    if (name != _table.names[column]) {
                      _mutate((t) => t.setColumnName(column, name));
                    }
                    _gridFocus.requestFocus();
                  },
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      Text(
                        columnLetter(column),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: t.textFaint,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          _table.names[column],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: t.text,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 1),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '{${columnTypeLabel(_table.types[column])}}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 9, color: t.textFaint),
                        ),
                      ),
                      if (flag.isNotEmpty)
                        Text(
                          '[$flag]',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: flagColor,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }

  void _startRename(int column) {
    setState(() {
      _renamingColumn = column;
      _col = column;
      _anchorCol = column;
    });
  }

  Widget _buildRowHeader(SyphonTheme t) {
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: SingleChildScrollView(
        controller: _vHead,
        physics: const NeverScrollableScrollPhysics(),
        child: Column(
          children: [
            for (var r = 0; r < _table.rowCount; r++)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() {
                  _row = r;
                  _anchorRow = r;
                  if (_table.columnCount > 0) {
                    _anchorCol = 0;
                    _col = _table.columnCount - 1;
                  }
                }),
                child: Container(
                  width: _rowHeadW,
                  height: _cellH,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: r >= _selTop && r <= _selBottom
                        ? t.accent.withValues(alpha: .12)
                        : t.bgRaise,
                    border: Border(
                      right: BorderSide(color: t.strokeStrong),
                      bottom: BorderSide(color: t.stroke),
                    ),
                  ),
                  child: Text(
                    '${r + 1}',
                    style: TextStyle(
                      fontSize: 10,
                      color: t.textFaint,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 整片单元格共用一个手势识别器:按固定尺寸把局部坐标换算成行列
  Widget _buildCellArea(SyphonTheme t) {
    if (_table.rowCount == 0 || _table.columnCount == 0) {
      return SizedBox(
        width: 320,
        height: 90,
        child: Center(
          child: Text(
            _table.columnCount == 0
                ? '空表:点击工具条的「插入列」开始'
                : '空表:点击工具条的「插入行」开始',
            style: TextStyle(fontSize: 11, color: t.textFaint),
          ),
        ),
      );
    }
    return GestureDetector(
      key: const ValueKey('table-cell-area'),
      behavior: HitTestBehavior.opaque,
      onTapDown: (details) => _onCellDown(details.localPosition),
      onDoubleTapDown: (details) {
        final cell = _cellAt(details.localPosition);
        _beginEdit(row: cell.$1, column: cell.$2);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var r = 0; r < _table.rowCount; r++)
            Row(
              children: [
                for (var c = 0; c < _table.columnCount; c++)
                  _buildCell(t, r, c),
              ],
            ),
        ],
      ),
    );
  }

  (int, int) _cellAt(Offset local) {
    final row = (local.dy / _cellH).floor().clamp(0, _table.rowCount - 1);
    final column = (local.dx / _cellW).floor().clamp(0, _table.columnCount - 1);
    return (row, column);
  }

  void _onCellDown(Offset local) {
    final cell = _cellAt(local);
    if (_editing && (cell.$1 != _row || cell.$2 != _col)) {
      _commitEdit();
    }
    final extend = HardwareKeyboard.instance.isShiftPressed;
    setState(() {
      _row = cell.$1;
      _col = cell.$2;
      if (!extend) {
        _anchorRow = cell.$1;
        _anchorCol = cell.$2;
      }
      _renamingColumn = null;
    });
    _gridFocus.requestFocus();
  }

  Widget _buildCell(SyphonTheme t, int row, int column) {
    final cursor = row == _row && column == _col;
    final selected = _inSelection(row, column);
    final editing = cursor && _editing;
    return Container(
      width: _cellW,
      height: _cellH,
      decoration: BoxDecoration(
        color: editing
            ? t.bgInput
            : selected
            ? t.accent.withValues(alpha: cursor ? .16 : .08)
            : Colors.transparent,
        border: Border(
          right: BorderSide(color: t.stroke),
          bottom: BorderSide(color: t.stroke),
          left: cursor
              ? BorderSide(color: t.accent, width: 1.4)
              : BorderSide.none,
          top: cursor
              ? BorderSide(color: t.accent, width: 1.4)
              : BorderSide.none,
        ),
      ),
      child: editing
          ? _buildCellEditor(t)
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _table.cellAt(row, column),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: t.text),
                ),
              ),
            ),
    );
  }

  Widget _buildCellEditor(SyphonTheme t) {
    return Focus(
      onKeyEvent: _onEditorKey,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Center(
          // TextField 需要 Material 祖先(应用根是 FluentApp)
          child: Material(
            type: MaterialType.transparency,
            child: TextField(
              key: const ValueKey('table-cell-editor'),
              controller: _editText,
              focusNode: _editFocus,
              autofocus: true,
              style: TextStyle(fontSize: 11.5, color: t.text),
              cursorColor: t.accent,
              cursorWidth: 1.2,
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
              onSubmitted: (_) => _commitEdit(dRow: 1),
            ),
          ),
        ),
      ),
    );
  }

  // ==================== 状态栏 ====================

  Widget _buildStatusBar(SyphonTheme t) {
    return Container(
      height: _statusBarH,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: t.bgRaise,
        border: Border(top: BorderSide(color: t.stroke)),
      ),
      child: Row(
        children: [
          Text(
            '${_table.rowCount} 行 × ${_table.columnCount} 列',
            style: TextStyle(fontSize: 10, color: t.textDim),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '双击单元格编辑 · Shift+方向键框选 · Ctrl+C/V 复制粘贴 · Ctrl+Z 撤销',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: t.textFaint),
            ),
          ),
          Text(
            _fromPreset ? '预设数据 · 修改后转为文件数据' : '已实时同步到节点',
            style: TextStyle(
              fontSize: 10,
              color: _fromPreset ? t.warn : t.textFaint,
            ),
          ),
        ],
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
    this.autofocus = false,
    this.dropdown,
  });

  final String value;
  final String? placeholder;
  final ValueChanged<String>? onSubmit;
  final double width;
  final bool autofocus;

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
              autofocus: widget.autofocus,
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
