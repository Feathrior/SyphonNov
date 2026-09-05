# Syphon

节点化数据处理与可视化工作台。像搭积木一样把"输入 → 处理 → 可视化"节点连成流水线，改参数自动重算、图表实时刷新。

A node-based data processing & visualization workbench. Connect input → transform → visualize nodes like building blocks—tweak a parameter, the whole pipeline re-runs and charts refresh in real time.

[中文](#中文) · [English](#english)

---

## 中文

### 功能

- **节点式画布**：右键创建节点、拖线连接，平移/缩放/框选/Shift 多选，迷你地图快速导航，曲线可 Alt 插入分割点、Ctrl 划切
- **自动执行**：拓扑顺序自动重算整条流水线，参数修改即时反映到图上
- **数据导入**：内置预设、粘贴 CSV/TSV、选择文件，或把 `.csv` / `.xlsx` 直接拖进窗口生成表格节点
- **数据处理**：清洗(缺失值/去重)、标准化、条件筛选、抽样、提取列/行、表格↔散点/曲线互转
- **数据运算**：求导、积分、拟合、平滑、公式运算、曲线求交
- **数据可视化**：散点 / 折线 / 柱状 / 火山 / 热力 / 箱线 / 小提琴 / 桑基 / 网络 共 9 类图表，全部自绘（无图表库依赖），支持缩放平移与导出 PNG；桑基图支持直线/环形两种布局与多色带
- **原理化输出**：像 Blender 一样在坐标系内组合点/线/面/文本图元，支持颜色预设、导出与预览等比例
- **参数暴露**：点大小/颜色、线宽/颜色等参数可暴露为输入口，接入数据列后逐点/逐段变化
- 其他：撤销/重做、亮/暗主题、全局快捷键、无边框自定义标题栏

### 节点库

| 分类 | 节点 |
| --- | --- |
| 输入 | 表格、坐标系、文本、色带、线、平面、网格数据、聚合点、曲线、函数曲线 |
| 清洗 | 数据清洗、标准化、条件筛选、数据抽样 |
| 运算 | 数值求导、数值积分、曲线拟合、平滑、公式运算、曲线求交 |
| 转化 | 提取列、提取行、表格转散点、表格转曲线、曲线转散点、散点转表格 |
| 可视化 | 散点图、折线图、柱状图、火山图、热力图、箱线图、小提琴图、桑基图、网络示意图、原理化输出、数据输出 |

### 快速上手

1. 空白处右键 → 新建「表格输入」（选预设 / 粘贴 CSV / 选择或拖入文件）
2. 再添加一个可视化节点（如「散点图」），从表格输出口拖线连到图表输入口
3. 任意修改参数都会自动重算；或点工具栏「运行」手动触发
4. 想画 3D：添加「坐标系输入」+ 点/线/面/文本输入，连到「原理化输出」

### 快捷键

| 快捷键 | 功能 |
| --- | --- |
| `Ctrl+Z` / `Ctrl+Y` | 撤销 / 重做 |
| `Delete` / `Backspace` | 删除选中 |
| `Ctrl+滚轮` | 缩放画布 |
| `Ctrl+划过连线` | 切断连线 |
| `Shift+拖节点到连线` | 节点插入连线 |
| `右键空白` | 新建节点菜单 |
| `Alt+悬停/点击曲线` | 插入分割点 |

### 构建

环境：Flutter 3.35+（Dart ^3.12）、Windows + Visual Studio 2022（C++ 桌面开发）。仅支持 Windows。

```
flutter pub get
flutter run -d windows
flutter build windows
```

### License

[MIT](LICENSE)

---

## English

### Features

- **Node-based canvas**: right-click to create nodes, drag sockets to connect; pan / zoom / marquee-select / Shift multi-select; minimap navigation; Alt-click curves to insert split points, Ctrl-drag to cut edges
- **Auto execution**: the whole pipeline re-runs in topological order whenever a parameter changes; charts update live
- **Data import**: built-in presets, paste CSV/TSV, pick files, or drag `.csv` / `.xlsx` directly into the window to create a table input node at the drop position
- **Data cleaning & transform**: missing-value / dedup clean, standardize, filter, sample, extract columns / rows, table ↔ scatter / curve
- **Compute**: numerical derivative, integral, polynomial / exponential fit, smoothing, formula eval, curve-curve intersection
- **Visualization**: 9 chart types (scatter, line, bar, volcano, heatmap, box, violin, sankey, network), all custom-painted with zero chart-library dependency; pan / zoom inside each viewport; PNG export; sankey supports linear or circular layout with multiple palettes
- **Principled output**: compose point / line / surface / text primitives in a coordinate space (Blender-style); 3D rotation, color presets, wireframe / filled surfaces; export isometric to preview
- **Param exposure**: point size / color, line width / color, etc. can be exposed as input sockets and driven by data columns (per-point / per-segment variation)
- Undo / redo, light & dark themes, global shortcuts, custom frameless title bar

### Node Library

| Category | Nodes |
| --- | --- |
| Input | Table, CoordinateSystem, Text, Colorbar, Line, Plane, Grid, AggregatePoints, Curve, FunctionCurve |
| Clean | Clean, Standardize, Filter, Sample |
| Compute | Derivative, Integral, Fit, Smooth, Formula, CurveIntersect |
| Transform | SelectCols, SelectRows, TableToScatter, TableToCurve, CurveToScatter, ScatterToTable |
| Visualize | Scatter, Line, Bar, Volcano, Heatmap, Box, Violin, Sankey, Network, Principled, DataOutput |

### Quick Start

1. Right-click the canvas → **New Node → Table Input** (pick a preset, paste CSV, or choose / drag a file)
2. Add a visualization node (e.g. **Scatter Plot**), drag a wire from the table's output socket to the chart's input socket
3. Change any parameter — the pipeline re-runs automatically; or click **Run** in the toolbar to trigger manually
4. For 3D scenes: add **CoordinateSystem + Point / Line / Surface / Text** inputs and wire them into **Principled Output**

### Shortcuts

| Shortcut | Action |
| --- | --- |
| `Ctrl+Z` / `Ctrl+Y` | Undo / Redo |
| `Delete` / `Backspace` | Delete selection |
| `Ctrl+Wheel` | Zoom canvas |
| `Ctrl+drag over edge` | Cut edge |
| `Shift+drag node onto edge` | Split edge, insert node |
| `Right-click empty space` | New-node menu |
| `Alt+hover / click curve` | Insert split point |

### Build

Requirements: Flutter 3.35+ (Dart ^3.12), Windows + Visual Studio 2022 (C++ desktop workload). Windows desktop only.

```
flutter pub get
flutter run -d windows
flutter build windows
```

### License

[MIT](LICENSE)
