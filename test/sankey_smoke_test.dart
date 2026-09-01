// 桑基图渲染冒烟测试:直线/环形 × 默认色带/外部色带输入,均不抛异常
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/models/data.dart' as md;
import 'package:syphon_nov/models/exec_engine.dart';
import 'package:syphon_nov/ui/viewer.dart';

void main() {
  final table = md.TableData([
    md.Column(name: '来源', values: [
      '收入', '收入', '收入', '支出', '支出', '支出', '支出', '储蓄', '储蓄',
    ]),
    md.Column(name: '去向', values: [
      '工资', '兼职', '理财', '房租', '餐饮', '出行', '娱乐', '银行', '基金',
    ]),
    md.Column(name: '流量', values: [
      4200, 1500, 800, 1800, 1350, 640, 420, 3800, 1200,
    ]),
  ]);

  for (final layout in ['linear', 'circular']) {
    for (final withColorbar in [false, true]) {
      test('桑基图 $layout colorbar=$withColorbar 渲染不抛错', () {
        final inputs = <String, md.DataObject>{'in0': table};
        if (withColorbar) {
          inputs['in1'] = md.ColorbarData(
            stops: md.kDefaultGradient.map((s) => s.copy()).toList(),
            min: 0,
            max: 4200,
            label: '流量',
          );
        }
        final recorder = ui.PictureRecorder();
        ChartPainter(
          data: ChartData(
            chartType: 'sankey',
            params: {
              'sourceCol': '来源',
              'targetCol': '去向',
              'valueCol': '流量',
              'layout': layout,
              'title': '',
            },
            result: ExecResult(inputs: inputs, outputs: const {}),
          ),
        ).paint(Canvas(recorder), const Size(400, 300));
      });
    }
  }
}
