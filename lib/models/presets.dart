// 内置画布预设:火山图 / 热力图 / 箱线图 / 小提琴图 / 桑基图(由 React 版 presets.ts 移植)
library;

import 'dart:convert';

class Preset {
  final String name;
  final String desc;
  final String json;

  const Preset({required this.name, required this.desc, required this.json});
}

String _buildGraph(
  List<Map<String, dynamic>> nodes,
  List<Map<String, dynamic>> edges, {
  List<Map<String, dynamic>>? groups,
}) {
  return const JsonEncoder.withIndent('  ').convert({
    'format': 'syphon-graph',
    'version': 1,
    'nodes': nodes
        .map(
          (n) => {
            'id': n['id'],
            'configId': n['configId'],
            'params': n['params'] ?? <String, dynamic>{},
            'exposed': n['exposed'] ?? <String>[],
            'collapsed': n['collapsed'] ?? false,
            'position': n['position'],
          },
        )
        .toList(),
    'edges': edges
        .map(
          (e) => {
            'id': e['id'],
            'source': e['source'],
            'target': e['target'],
            'sourceHandle': e['sourceHandle'] ?? 'out0',
            'targetHandle': e['targetHandle'] ?? 'in0',
            'mid': e['mid'],
          },
        )
        .toList(),
    'groups': groups ?? <Map<String, dynamic>>[],
  });
}

String _tableToChart(
  Map<String, dynamic> tableParams,
  String chartConfigId,
  Map<String, dynamic> chartParams,
  double y,
) {
  return _buildGraph(
    [
      {
        'id': 't',
        'configId': 'table_input',
        'params': tableParams,
        'position': {'x': 40, 'y': y},
      },
      {
        'id': 'v',
        'configId': chartConfigId,
        'params': chartParams,
        'position': {'x': 420, 'y': y},
      },
    ],
    [
      {'id': 't-v', 'source': 't', 'target': 'v'},
    ],
  );
}

final List<Preset> kPresetsReady = _buildPresets();

List<Preset> _buildPresets() {
  return [
    Preset(
      name: '火山图',
      desc: '基因差异表达:以 log2FC 与 p 值两列绘制火山图,自动标注显著点',
      json: _tableToChart({'preset': 'volcano'}, 'viz_volcano', {}, 60),
    ),
    Preset(
      name: '热力图',
      desc: '鸢尾花数值矩阵热力图(每个数值列一条色带)',
      json: _tableToChart({'preset': 'iris'}, 'viz_heatmap', {}, 60),
    ),
    Preset(
      name: '箱线图',
      desc: '鸢尾花四组数值分布的箱线图',
      json: _tableToChart({'preset': 'iris'}, 'viz_box', {}, 60),
    ),
    Preset(
      name: '小提琴图',
      desc: '鸢尾花四组数值分布的小提琴图(核密度估计)',
      json: _tableToChart({'preset': 'iris'}, 'viz_violin', {}, 60),
    ),
    Preset(
      name: '桑基图',
      desc: '收支流程桑基图:按 来源→去向 聚合流量',
      json: _tableToChart(
        {
          'mode': 'manual',
          'dataText': [
            '来源,去向,流量',
            '收入,工资,4200',
            '收入,兼职,1500',
            '收入,理财,800',
            '支出,房租,1800',
            '支出,餐饮,1350',
            '支出,出行,640',
            '支出,娱乐,420',
            '储蓄,银行,3800',
            '储蓄,基金,1200',
          ].join('\n'),
        },
        'viz_sankey',
        {
          'sourceCol': '来源',
          'targetCol': '去向',
          'valueCol': '流量',
          'title': '收支流程',
        },
        60,
      ),
    ),
    Preset(
      name: '网络示意图',
      desc: '关系网络图(力导向布局):按 源→目标 构建节点与连线,权重控制线宽',
      json: _tableToChart(
        {
          'mode': 'manual',
          'dataText': [
            '来源,目标,权重',
            'Alice,Bob,5',
            'Alice,Carol,3',
            'Bob,Carol,2',
            'Bob,David,4',
            'Carol,Eve,6',
            'David,Eve,2',
            'David,Frank,3',
            'Eve,Frank,5',
            'Frank,Alice,1',
          ].join('\n'),
        },
        'viz_graph',
        {
          'sourceCol': '来源',
          'targetCol': '目标',
          'valueCol': '权重',
          'title': '通信网络',
        },
        60,
      ),
    ),
    Preset(
      name: '功能全景演示',
      desc: '示例节点组:覆盖全部输入/清理/运算/转化/可视化节点与原理化输出(首次启动自动载入)',
      json: _buildDemoGraph(),
    ),
  ];
}

// ==================== 功能全景演示图 ====================
// 示例节点组:覆盖全部 36 种节点(输入/清理/运算/转化/可视化/原理化),
// 按区域分组布局;首次启动自动载入(见 main.dart)。

/// 首次启动自动载入的全景演示图画布 JSON
final String kDemoGraphJson = _buildDemoGraph();

String _buildDemoGraph() {
  Map<String, dynamic> node(
    String id,
    String configId,
    double x,
    double y, [
    Map<String, dynamic>? params,
  ]) => {
    'id': id,
    'configId': configId,
    'params': params ?? const <String, dynamic>{},
    'position': {'x': x, 'y': y},
  };
  Map<String, dynamic> edge(
    String id,
    String source,
    String target, {
    String? sourceHandle,
    String? targetHandle,
  }) => {
    'id': id,
    'source': source,
    'target': target,
    'sourceHandle': sourceHandle,
    'targetHandle': targetHandle,
    'mid': null,
  };

  return _buildGraph(
    [
      // ---- 区域 1:表格处理链(销售数据)+ 数据输出/基础图表 ----
      // 布局说明:节点高度按 nodeSize 计算(查看器节点 ~414/322 高),
      // 纵向间距必须大于上节点高度,避免节点重叠——重叠时上层节点
      // 拦截指针事件,下层节点(如数据输出的表格)将无法拖动滚动。
      node('t1', 'table_input', 30, 40, {'preset': 'sales'}),
      node('c1', 'clean', 330, 40),
      node('c2', 'normalize', 330, 165),
      node('c3', 'filter', 330, 330, {'column': '销量', 'min': '150'}),
      node('c4', 'sample', 330, 480),
      node('e1', 'extract_columns', 640, 40, {'columns': '月份,销量'}),
      node('e2', 'extract_rows', 640, 190, {'step': 2}),
      node('do1', 'data_output', 980, 40, {'maxRows': 8}),
      node('vl', 'viz_line', 980, 410, {
        'xCol': '月份',
        'yCol': '销量',
        'title': '折线图 · 月度销量',
      }),
      node('vb', 'viz_bar', 980, 860, {
        'xCol': '月份',
        'yCol': '利润',
        'title': '柱状图 · 月度利润',
      }),
      node('vs', 'viz_scatter', 1450, 200, {
        'xCol': '销量',
        'yCol': '利润',
        'title': '散点图 · 销量×利润',
      }),

      // ---- 区域 2:火山图 + 热力/箱线/小提琴(鸢尾花) ----
      node('t2', 'table_input', 30, 1330, {'preset': 'volcano'}),
      node('vv', 'viz_volcano', 330, 1330, {
        'fcCol': 'log2FC',
        'pCol': 'pvalue',
        'title': '火山图',
      }),
      node('t3', 'table_input', 30, 1590, {'preset': 'iris'}),
      node('vh', 'viz_heatmap', 330, 1800, {'title': '热力图 · 鸢尾花'}),
      node('vbx', 'viz_box', 770, 1330, {'title': '箱线图 · 鸢尾花'}),
      node('vvi', 'viz_violin', 1210, 1330, {'title': '小提琴图 · 鸢尾花'}),

      // ---- 区域 3:桑基图(双色带)+ 网络示意图 ----
      node('t4', 'table_input', 30, 1500, {
        'mode': 'manual',
        'dataText': [
          '来源,去向,流量',
          '收入,工资,4200',
          '收入,兼职,1500',
          '收入,理财,800',
          '支出,房租,1800',
          '支出,餐饮,1350',
          '支出,出行,640',
          '储蓄,银行,3800',
          '储蓄,基金,1200',
        ].join('\n'),
      }),
      node('vsk', 'viz_sankey', 330, 1500, {
        'sourceCol': '来源',
        'targetCol': '去向',
        'valueCol': '流量',
        'title': '桑基图 · 收支流',
      }),
      node('vg', 'viz_graph', 770, 1500, {
        'sourceCol': '来源',
        'targetCol': '去向',
        'title': '网络示意图',
      }),

      // ---- 区域 4:曲线运算链(求导/积分/平滑/公式/求交/曲线转散点) ----
      node('s1', 'func_curve', 30, 1940, {
        'name': '正弦二倍频',
        'mode': 'function',
        'expression': 'sin(2*x)',
      }),
      node('d1', 'derivative', 330, 1940),
      node('i1', 'integral', 330, 2060),
      node('sm1', 'smooth', 330, 2180, {'window': 5}),
      node('f1', 'formula', 330, 2300, {'expression': 'y*2+1'}),
      node('fc', 'func_curve', 640, 1940, {
        'name': '正弦函数',
        'expression': 'sin(x)',
      }),
      node('ci', 'curve_intersect', 900, 1940),
      node('ct', 'series_to_scatter', 1180, 1940),

      // ---- 区域 5:点/线/面/文本/坐标系 → 原理化输出 ----
      node('ax', 'axis_input', 30, 2500, {'name': '演示坐标系'}),
      node('lt', 'func_curve', 330, 2500, {
        'name': '参数曲线',
        'mode': 'function',
        'expression': 'sin(2*x)',
      }),
      node('ps', 'scatter_input', 330, 2660, {
        'name': '点输入',
        'points': [
          {'x': 1, 'y': 2, 'size': 6, 'color': '#e63946'},
          {'x': 3, 'y': 5, 'size': 8, 'color': '#f4a261'},
          {'x': 5, 'y': 3, 'size': 5, 'color': '#2a9d8f'},
        ],
      }),
      node('pl', 'plane_input', 330, 2820, {
        'shape': 'circle',
        'radius': 3,
        'color': '#4f8ef7',
        'opacity': 0.7,
      }),
      node('tx', 'text_input', 330, 2980, {'text': '示例文本', 'fontSize': 1.2}),
      node('pr', 'viz_principled', 640, 2500, {}),

      // ---- 区域 6:表格↔散点/曲线变换 + 拟合 + 系数表预览 ----
      node('tts', 'table_to_scatter', 30, 3120, {
        'xCol': 'sepal_length',
        'yCol': 'petal_width',
        'pointSize': 5,
      }),
      node('ft', 'fit', 330, 3120, {
        'name': '多项式拟合',
        'method': 'poly',
        'degree': 2,
      }),
      node('tse', 'table_to_series', 640, 3120, {
        'xCol': 'sepal_length',
        'yCol': 'sepal_width',
      }),
      node('do2', 'data_output', 980, 3120, {'maxRows': 6}),
    ],
    [
      // 区域 1
      edge('t1-c1', 't1', 'c1'),
      edge('c1-c2', 'c1', 'c2'),
      edge('c2-c3', 'c2', 'c3'),
      edge('c3-c4', 'c3', 'c4'),
      edge('c2-e1', 'c2', 'e1'),
      edge('c2-e2', 'c2', 'e2'),
      edge('e1-do1', 'e1', 'do1'),
      edge('c2-vl', 'c2', 'vl'),
      edge('c2-vb', 'c2', 'vb'),
      edge('c2-vs', 'c2', 'vs'),
      // 区域 2
      edge('t2-vv', 't2', 'vv'),
      edge('t3-vh', 't3', 'vh'),
      edge('t3-vbx', 't3', 'vbx'),
      edge('t3-vvi', 't3', 'vvi'),
      // 区域 3
      edge('t4-vsk', 't4', 'vsk'),
      edge('t4-vg', 't4', 'vg'),
      // 区域 4
      edge('s1-d1', 's1', 'd1'),
      edge('s1-i1', 's1', 'i1'),
      edge('s1-sm1', 's1', 'sm1'),
      edge('s1-f1', 's1', 'f1'),
      edge('s1-ci', 's1', 'ci'),
      edge('fc-ci', 'fc', 'ci', targetHandle: 'in1'),
      edge('sm1-ct', 'sm1', 'ct'),
      // 区域 5:图元实例化到坐标系,原理化输出仅渲染坐标系
      edge('ax-pr', 'ax', 'pr', targetHandle: 'in0'),
      edge('lt-ax', 'lt', 'ax', targetHandle: 'in1'),
      edge('ps-ax', 'ps', 'ax', targetHandle: 'in0'),
      edge('pl-ax', 'pl', 'ax', targetHandle: 'in2'),
      edge('tx-ax', 'tx', 'ax', targetHandle: 'in4'),
      edge('ci-ax', 'ci', 'ax', targetHandle: 'in0'),
      edge('ct-ax', 'ct', 'ax', targetHandle: 'in0'),
      edge('ft-ax', 'ft', 'ax', sourceHandle: 'out0', targetHandle: 'in1'),
      edge('tse-ax', 'tse', 'ax', targetHandle: 'in1'),
      // 区域 6
      edge('t3-tts', 't3', 'tts'),
      edge('tts-ft', 'tts', 'ft'),
      edge('ft-do2', 'ft', 'do2', sourceHandle: 'out1'),
      edge('t3-tse', 't3', 'tse'),
    ],
    groups: [
      {
        'id': 'g_sales',
        'name': '销售分析',
        'nodeIds': [
          't1',
          'c1',
          'c2',
          'c3',
          'c4',
          'e1',
          'e2',
          'do1',
          'vl',
          'vb',
          'vs',
        ],
      },
      {
        'id': 'g_viz',
        'name': '可视化对比',
        'nodeIds': ['t2', 'vv', 't3', 'vh', 'vbx', 'vvi', 't4', 'vsk', 'vg'],
      },
      {
        'id': 'g_math',
        'name': '曲线运算',
        'nodeIds': ['s1', 'd1', 'i1', 'sm1', 'f1', 'fc', 'ci', 'ct'],
      },
      {
        'id': 'g_pr',
        'name': '原理化与变换',
        'nodeIds': [
          'ax',
          'lt',
          'ps',
          'pl',
          'tx',
          'pr',
          'tts',
          'ft',
          'tse',
          'do2',
        ],
      },
    ],
  );
}
