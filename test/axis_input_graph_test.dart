// 坐标系输入大改回归测试:
// 1. 坐标系输入新增点/线/面/分布/文本输入口,exec 时把图元收集进坐标系输出;
// 2. 原理化输出只保留"坐标系"一个输入口;
// 3. 坐标系预设新增"隐藏坐标系"(AxesData.hidden);
// 4. 图表节点(除散点/折线/柱状图)仅保留 表格+坐标系 输入,渲染时按坐标系风格。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/main.dart';
import 'package:syphon_nov/models/data.dart' as md;
import 'package:syphon_nov/models/exec.dart' show kExec;
import 'package:syphon_nov/models/exec_engine.dart';
import 'package:syphon_nov/models/presets.dart';
import 'package:syphon_nov/models/registry.dart';
import 'package:syphon_nov/store/graph_store.dart';
import 'package:syphon_nov/ui/principled.dart';
import 'package:syphon_nov/ui/viewer.dart';

void main() {
  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const SyphonApp());
    await tester.pump();
  }

  testWidgets('坐标系输入:端口与图元收集、原理化输出仅接坐标系', (WidgetTester tester) async {
    GraphStore.useIsolate = false;
    addTearDown(() => GraphStore.useIsolate = true);

    // 配置层面:坐标系输入有点/线/面/分布/文本;原理化输出仅 1 个输入
    final axCfg = getConfig('axis_input')!;
    expect(axCfg.inputs.map((s) => s.type).toList(), [
      md.SocketType.scatter,
      md.SocketType.series,
      md.SocketType.mesh,
      md.SocketType.distribution,
      md.SocketType.text,
    ]);
    final prCfg = getConfig('viz_principled')!;
    expect(prCfg.inputs.length, 1, reason: '原理化输出只保留坐标系输入');
    expect(prCfg.inputs.first.type, md.SocketType.axes);
    expect(prCfg.params, isEmpty, reason: '原理化输出的属性已移交坐标系输入');

    // 数据流:演示图把图元接入坐标系,坐标系输出应携带图元集合
    await pumpApp(tester);
    final store = GraphStore.instance;
    store.loadGraph(kDemoGraphJson, silent: true);
    store.runPipeline();
    await tester.pump();

    final ax = store.results['ax'];
    expect(ax, isNotNull);
    expect(ax!.error, isNull);
    final out = ax.outputs['out0'];
    expect(out, isA<md.AxesData>());
    final axes = out as md.AxesData;
    // lt / ft / tse → 线;ps / ci / ct → 点;pl → 面;tx → 文本
    expect(axes.lines.length, 3, reason: '三条线应收集进坐标系');
    expect(axes.points.length, 3, reason: '三个点源应收集进坐标系');
    expect(axes.meshes.length, 1, reason: '平面应收集进坐标系');
    expect(axes.texts.length, 1, reason: '文本应收集进坐标系');
    expect(axes.dist, isNull);
    // 背景与导出属性随坐标系
    expect(axes.colorPreset, 'paper');
    expect(axes.canvasPxW, greaterThan(0));

    // 原理化输出结果只应携带坐标系输入(in0)
    final pr = store.results['pr']!;
    expect(pr.error, isNull);
    expect(pr.inputs.keys.toSet(), {'in0'});
    expect(pr.inputs['in0'], isA<md.AxesData>());
  });

  testWidgets('坐标系携带图元时,原理化渲染器可正常绘制', (WidgetTester tester) async {
    // 直接构造携带点/线/面/文本的坐标系,驱动渲染器,确认不抛异常
    final axes = md.AxesData(
      name: '测试坐标系',
      dim: 2,
      xLen: 10,
      yLen: 8,
      zLen: 6,
      xMin: 0,
      xMax: 10,
      yMin: 0,
      yMax: 10,
      zMin: -5,
      zMax: 5,
      grid: true,
      axisOrigin: 'origin',
      showBorder: true,
      labelX: 'X',
      labelY: 'Y',
      labelZ: 'Z',
      gridX: true,
      gridY: true,
      gridZ: true,
      fontSize: 10,
      fontFamily: 'sans-serif',
      points: [
        md.ScatterData(
          name: 'p',
          points: [md.Pt3(2, 3, 0)],
          pointSize: 4,
          pointShape: 'circle',
          pointColor: '#e63946',
        ),
      ],
      lines: [
        md.SeriesData(
          name: 'l',
          points: [md.Pt(1, 1), md.Pt(2, 4), md.Pt(3, 9)],
          lineColor: '#f59e0b',
          lineWidth: 0.12,
          lineStyle: 'solid',
        ),
      ],
      texts: [
        md.TextData(
          text: '标签',
          fontSize: 1.2,
          halign: 'center',
          valign: 'middle',
          textColor: '#333333',
          fontFamily: 'sans-serif',
        ),
      ],
      colorPreset: 'paper',
      bgColor: '#ffffff',
      canvasPxW: 1200,
      canvasPxH: 800,
    );

    final painter = PrincipledPainter(
      params: const {},
      result: ExecResult(inputs: {'in0': axes}, outputs: const {}),
    );
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    painter.paint(canvas, const Size(400, 300));
    expect(tester.takeException(), isNull);
  });

  testWidgets('坐标系预设"隐藏坐标系":AxesData.hidden 生效', (WidgetTester tester) async {
    final exec = kExec['axis_input']!;
    final out = exec(
      md.ExecContext(
        nodeId: 'x',
        params: {'axisPreset': 'hidden', 'dim': '2d'},
        inputs: const {},
      ),
    );
    final axes = out['out0'] as md.AxesData;
    expect(axes.hidden, isTrue, reason: '"隐藏坐标系"预设应置 hidden');

    final out2 = exec(
      md.ExecContext(nodeId: 'x', params: {'dim': '2d'}, inputs: const {}),
    );
    expect((out2['out0'] as md.AxesData).hidden, isFalse);
  });

  testWidgets('图表节点:除散点/折线/柱状图外仅 表格+坐标系 输入', (WidgetTester tester) async {
    for (final id in [
      'viz_volcano',
      'viz_heatmap',
      'viz_box',
      'viz_violin',
      'viz_sankey',
      'viz_graph',
    ]) {
      final cfg = getConfig(id)!;
      expect(cfg.inputs.map((s) => s.type).toList(), [
        md.SocketType.table,
        md.SocketType.axes,
      ], reason: '$id 应只保留 表格+坐标系 输入');
    }
    // 散点/折线/柱状图:保留原有输入(内置坐标系)
    for (final id in ['viz_scatter', 'viz_line', 'viz_bar']) {
      final cfg = getConfig(id)!;
      expect(cfg.inputs.first.type, md.SocketType.table, reason: '$id 首输入仍为表格');
      expect(
        cfg.inputs.any((s) => s.type == md.SocketType.axes),
        isFalse,
        reason: '$id 内置坐标系,不提供坐标系输入口',
      );
    }
  });

  testWidgets('火山图接入坐标系后可渲染(含隐藏坐标系)', (WidgetTester tester) async {
    final table = md.TableData([
      md.Column(name: 'log2FC', values: [-2.0, -0.5, 0.2, 1.5, 3.0]),
      md.Column(name: 'pvalue', values: [0.001, 0.06, 0.03, 0.002, 0.8]),
    ]);
    md.AxesData mkAxes({bool hidden = false}) => md.AxesData(
      name: 'cs',
      dim: 2,
      xLen: 12,
      yLen: 8,
      zLen: 6,
      xMin: -3,
      xMax: 4,
      yMin: 0,
      yMax: 4,
      zMin: -5,
      zMax: 5,
      grid: true,
      axisOrigin: 'origin',
      showBorder: true,
      labelX: 'log2FC',
      labelY: '-log10(p)',
      labelZ: 'Z',
      gridX: true,
      gridY: true,
      gridZ: true,
      fontSize: 10,
      fontFamily: 'sans-serif',
      hidden: hidden,
    );

    for (final hidden in [false, true]) {
      final painter = ChartPainter(
        data: ChartData(
          chartType: 'volcano',
          params: const {'fcCol': 'log2FC', 'pCol': 'pvalue'},
          result: ExecResult(
            inputs: {
              'in0': table,
              'in1': mkAxes(hidden: hidden),
            },
            outputs: const {},
          ),
        ),
      );
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      painter.paint(canvas, const Size(400, 320));
      expect(tester.takeException(), isNull);
    }
  });
}
