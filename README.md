# Syphon — 节点化科研绘图与数据处理工作台

> 节点式(Blender 风格)科研数据处理与可视化桌面应用:导入数据 → 清洗/运算/变换 → 一键出图。
> A node-based scientific data processing & visualization desktop app (ported from the React
> prototype): import data → clean / compute / transform → publish-ready figures in one flow.

[中文](#中文) · [English](#english)

---

## 中文

### 简介

Syphon 是一个**节点化科研数据处理工作台**,原型为 React 版(Syphon/React Flow 移植),现以
Flutter 桌面版重写。用户像搭积木一样把"输入 → 处理 → 可视化"节点连接成流水线,参数修改
**自动重算**,图表实时刷新。

### 功能特性

- **节点式画布**:右键创建节点、拖线连接;平移 / 缩放 / 框选 / Shift 多选与节点分组
  (Blender 风格,成员整体拖动);迷你地图快速导航;曲线可 Alt 插入分割点、Ctrl 划切。
- **自动执行**:按拓扑顺序自动重算整条流水线;参数滑块、颜色、文本修改即时反映到图上。
- **数据导入**:内置数据预设;粘贴 CSV/TSV;通过属性面板选择 CSV/Excel 文件;或把
  `.csv` / `.xlsx` 等文件**直接拖拽进窗口**,松开左键即在鼠标位置生成已导入数据的
  "表格输入"节点。
- **数据处理**:数据清洗(缺失值/去重)、标准化、条件筛选、抽样;提取列 / 行;表格与
  散点 / 曲线互转。
- **数据运算**:数值求导、积分、多项式/指数拟合、滑动平均平滑、公式运算。
- **数据可视化**:散点 / 折线 / 柱状 / 火山 / 热力 / 箱线 / 小提琴 / 桑基 / 网络共 9 类图表,
  全部由 CustomPaint 自绘(无图表库依赖),支持缩放平移与**导出 PNG**。
- **原理化输出**:像 Blender 一样在坐标系内组合**点 / 线 / 面 / 文本**图元(可多路连接),
  3D 场景旋转、颜色预设、线框 / 填充面,导出与预览等比例。
- **图元叠加**:所有可视化节点均可额外接入点 / 线 / 面 / 文本,直接叠加绘制进图中。
- **参数暴露**:点大小 / 颜色、线宽 / 颜色等参数可"暴露"为输入口,接入数据列后逐点 / 逐段变化。
- 其他:撤销 / 重做、亮 / 暗主题、全局快捷键、无边框自定义标题栏。

### 节点库

| 分类 | 分类名 | 节点 |
| --- | --- | --- |
| 组输入 | Input | 表格输入、坐标系输入、文本输入、色带输入、线输入、平面输入、网格数据输入、聚合点输入、曲线输入、函数曲线 |
| 数据初步 | Clean | 数据清洗、标准化、条件筛选、数据抽样 |
| 数据运算 | Compute | 数值求导、数值积分、曲线拟合、平滑、公式运算、曲线求交 |
| 数据转化 | Transform | 提取列、提取行、表格转散点、表格转曲线、曲线转散点、散点转表格 |
| 数据可视化 | Visualize | 散点图、折线图、柱状图、火山图、热力图、箱线图、小提琴图、桑基图、网络示意图、原理化输出、数据输出 |

### 快速上手

1. 在画布**空白处右键** → 打开"新建节点"菜单,选择「表格输入」(选数据预设,或
   粘贴 CSV,或选择/拖入文件)。
2. 再添加一个数据可视化节点(如「散点图」),从表格输入的输出口**拖线**连到图表输入口。
3. 任意修改参数(列选择、标题、颜色、旋转角……)都会**自动重算**;也可点工具栏「运行」
   手动触发。
4. 想画 3D 场景:添加「坐标系输入」与「面输入 / 点输入 / 线输入 / 文本输入」,全部连到
   「原理化输出」。

### 快捷键

| 快捷键 | 功能 |
| --- | --- |
| `Ctrl+Z` / `Ctrl+Y`(或 `Ctrl+Shift+Z`) | 撤销 / 重做 |
| `Delete` / `Backspace` | 删除选中的节点 / 连线 / 分割点 |
| `Escape` | 关闭菜单、设置或快捷键面板 |
| `Ctrl+滚轮` | 任意位置缩放画布 |
| `Ctrl+按住左键划过连线` | 切断连线 |
| `Shift+拖拽节点到连线上` | 把节点插入连线中间(拆分连线) |
| `右键空白处` | 打开"新建节点"菜单 |
| `右键节点` | 折叠 / 展开节点 |
| `Alt+悬停 / 点击曲线` | 预览 / 插入分割点(小圆点) |
| `点击 / 拖拽小圆点`,`Delete` | 选中 / 调整 / 删除分割点 |

### 构建与运行

环境要求:

- Flutter SDK(Dart `^3.12`,建议 Flutter stable≥3.35)
- Windows:Visual Studio 2022(需勾选「使用 C++ 的桌面开发」)
- 仅支持 Windows 桌面(原生无边框窗口 + 文件拖拽依赖 Win32)

```bash
flutter pub get
flutter run -d windows          # 开发运行
flutter build windows --release # 发布构建 → build/windows/x64/runner/Release/
makensis install.nsi            # (可选)NSIS 打包 → dist/SyphonNov2_Setup.exe
```

### 项目结构

```
lib/
  models/  数据模型、节点注册表、执行引擎(拓扑排序)、CSV/Excel 解析
  store/   图存储(节点/连线/撤销重做)、设置存储(主题/自动执行)
  ui/      画布与节点卡、图表/原理化 CustomPaint 渲染、属性面板、迷你地图、状态栏、主题
  main.dart 应用入口(无边框窗口、快捷键、文件拖拽通道)
windows/
  runner/  Win32 宿主:无边框窗口、WM_DROPFILES 文件拖拽(平台通道 syphon/file_drop)
assets/    品牌图标等资源
```

### 技术要点

- 图表与 3D 场景全部为 **CustomPaint 自绘**(React 版 ECharts 改写成自研渲染器)。
- 执行引擎按依赖**拓扑排序**,`GraphStore` 驱动自动执行与撤销快照。
- 文件拖拽走 Win32 `WM_DROPFILES` → `MethodChannel("syphon/file_drop")` → 画布在放下点
  生成节点,并按 DPI 换算坐标。
- 数据流:节点因多路连接端口(multi)可同时接多条上游线,渲染层按输入端口聚合。

---

## English

### Overview

Syphon is a **node-based scientific data-processing and visualization workbench**, rebuilt from
the React prototype as a native Flutter Windows app. You chain "input → process → visualize"
nodes into a pipeline like building blocks; every parameter change is **recomputed
automatically** and the figure updates in real time.

### Highlights

- **Node canvas**: right-click to create nodes, drag wires to connect; pan / zoom /
  box-select / Shift multi-select and node groups (Blender-style group dragging);
  mini-map navigation; curves support Alt-split points and Ctrl-cut.
- **Auto execution**: the whole pipeline re-runs in topological order on every change —
  sliders, colors and text edits reflect on the figure immediately.
- **Data import**: built-in presets; paste CSV/TSV; pick a CSV/Excel file from the properties
  panel; or simply **drag a `.csv` / `.xlsx` file into the window** — releasing the mouse
  creates a "Table Input" node at the drop point, already loaded with the data.
- **Data processing**: clean (missing values / dedupe), normalize, filter, sample; extract
  columns / rows; convert table ↔ scatter / series.
- **Data math**: numerical derivative, integral, polynomial/exponential fit, moving-average
  smoothing, formula evaluation.
- **Visualization**: 9 chart types (scatter, line, bar, volcano, heatmap, box, violin, sankey,
  graph), all hand-drawn with `CustomPaint` (no chart dependency); zoom / pan and **PNG export**.
- **Principled output**: a Blender-like canvas that composes **points / curves / faces /
  text** primitives (multi-connect) inside a coordinate system — 3D rotation, color presets,
  wireframe / filled faces, proportional preview & export.
- **Primitive overlay**: every visualization node can additionally accept point / line / face /
  text inputs and draw them directly into the chart.
- **Exposed parameters**: point size/color, line width/color etc. can be *exposed* as input
  sockets, so per-point / per-segment styling can be driven by data columns.
- Plus: undo/redo, light/dark theme, global shortcuts, frameless custom title bar.

### Node Library

| Category | Nodes |
| --- | --- |
| Input | Table Input, Axis System, Text, Colorbar, Line, Plane, Grid, Aggregate Points, Series, Function Curve |
| Clean | Clean, Normalize, Filter, Sample |
| Compute | Derivative, Integral, Curve Fit, Smooth, Formula, Curve Intersect |
| Transform | Extract Columns, Extract Rows, Table→Scatter, Table→Series, Series→Scatter, Scatter→Table |
| Visualize | Scatter, Line, Bar, Volcano, Heatmap, Box, Violin, Sankey, Graph, Principled Output, Data Output |

### Quick Start

1. Right-click empty canvas → "New Node" menu → pick **Table Input** (choose a preset, paste
   CSV, or select/drag in a file).
2. Add a visualization node (e.g. **Scatter Plot**), then drag a wire from the table's output
   socket to the chart's input socket.
3. Edit any parameter (column, title, color, rotation…) — the pipeline **re-runs
   automatically**; the toolbar "Run" button also triggers a manual run.
4. For a 3D scene: add **Axis System** plus **Face / Point / Line / Text** inputs and connect
   them all into **Principled Output**.

### Shortcuts

| Keys | Action |
| --- | --- |
| `Ctrl+Z` / `Ctrl+Y` (or `Ctrl+Shift+Z`) | Undo / Redo |
| `Delete` / `Backspace` | Delete selected nodes / wires / split points |
| `Escape` | Close menu, settings or shortcuts panel |
| `Ctrl+Wheel` | Zoom canvas anywhere |
| `Ctrl+drag across a wire` | Cut the wire |
| `Shift+drag a node onto a wire` | Insert the node into the wire |
| Right-click empty area | Open "New Node" menu |
| Right-click a node | Collapse / expand node |
| `Alt+hover / click a wire` | Preview / insert a split point |
| Click / drag split dot, `Delete` | Select / adjust / remove split point |

### Build & Run

Requirements:

- Flutter SDK (Dart `^3.12`, Flutter stable ≥ 3.35 recommended)
- On Windows: Visual Studio 2022 with the "Desktop development with C++" workload
- Windows desktop only (the frameless window and file-drag support rely on Win32)

```bash
flutter pub get
flutter run -d windows          # develop
flutter build windows --release # release → build/windows/x64/runner/Release/
makensis install.nsi            # (optional) NSIS installer → dist/SyphonNov2_Setup.exe
```

### Project Layout

```
lib/
  models/  data models, node registry, execution engine (topological sort), CSV/Excel parsing
  store/   graph store (nodes/wires/undo-redo), settings store (theme / auto-run)
  ui/      canvas & node cards, chart/principled CustomPaint renderers, properties panel,
           mini-map, status bar, theme
  main.dart app entry (frameless window, global shortcuts, file-drop channel)
windows/
  runner/  Win32 host: frameless window, WM_DROPFILES drag-in (channel "syphon/file_drop")
assets/    branding icon, etc.
```

### Technical Notes

- Charts and the 3D scene are **hand-drawn with `CustomPaint`** (the React version's ECharts
  was replaced by a self-built renderer).
- The engine runs the graph in **topological order**; `GraphStore` drives auto-run and undo
  snapshots.
- File drag-in uses Win32 `WM_DROPFILES` → `MethodChannel("syphon/file_drop")` → the canvas
  creates a node at the drop point (DPI-aware coordinate conversion).
- Data flow: multi-connect sockets aggregate all upstream outputs per port in the render layer.

---

Syphon · v0.2.0