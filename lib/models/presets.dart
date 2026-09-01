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
  List<Map<String, dynamic>> edges,
) {
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
  ];
}
