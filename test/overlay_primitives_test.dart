// 图元叠加渲染冒烟测试:可视化节点接入点/线/面/文本输入后,
// ChartPainter 应像"原理化输出"一样把图元绘制进图中而不抛异常。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syphon_nov/models/data.dart' as md;
import 'package:syphon_nov/models/exec_engine.dart';
import 'package:syphon_nov/ui/viewer.dart';

void main() {
  testWidgets('图表叠加渲染点线面文本不抛错', (tester) async {
    final result = ExecResult(
      inputs: {
        'in_pts': md.ScatterData(
          name: '点',
          points: const [md.Pt3(0, 0), md.Pt3(1, 1), md.Pt3(2, 0)],
          pointShape: 'diamond',
          pointSize: 5,
          pointColor: '#1f77b4',
        ),
        'in_lines': md.SeriesData(
          name: '线',
          points: const [md.Pt(0, 0), md.Pt(1, 2), md.Pt(2, 1)],
          lineColor: '#ff0000',
          lineStyle: 'dashed',
          lineWidth: 2,
        ),
        'in_faces': md.MeshData(
          name: '面',
          vertices: const [
            md.Vec3(0, 0, 0),
            md.Vec3(2, 0, 0),
            md.Vec3(0, 2, 1),
          ],
          faces: const [
            [0, 1, 2],
          ],
        ),
        'in_texts': md.TextData(
          text: '图表标题',
          fontSize: 3,
          halign: 'center',
          valign: 'top',
          textColor: '#333333',
          fontFamily: '',
        ),
      },
      outputs: const {},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 400,
          height: 300,
          child: CustomPaint(
            painter: ChartPainter(
              data: ChartData(
                chartType: 'bar',
                params: const {'title': ''},
                result: result,
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('多路连接的图元也会被叠加渲染', (tester) async {
    final result = ExecResult(
      inputs: {
        'in_lines': md.SeriesData(
          name: '线1',
          points: [md.Pt(0, 0), md.Pt(1, 1)],
        ),
      },
      multiInputs: {
        'in_lines': [
          md.SeriesData(name: '线1', points: const [md.Pt(0, 0), md.Pt(1, 1)]),
          md.SeriesData(name: '线2', points: const [md.Pt(0, 1), md.Pt(1, 0)]),
        ],
      },
      outputs: const {},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 400,
          height: 300,
          child: CustomPaint(
            painter: ChartPainter(
              data: ChartData(
                chartType: 'scatter',
                params: const {'title': ''},
                result: result,
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('仅接入文本输入也能叠加渲染(修复文本不显示)', (tester) async {
    final result = ExecResult(
      inputs: {
        'in_texts': md.TextData(
          text: '图表标题',
          fontSize: 3,
          halign: 'left',
          valign: 'top',
          textColor: '#333333',
          fontFamily: '',
        ),
      },
      outputs: const {},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 400,
          height: 300,
          child: CustomPaint(
            painter: ChartPainter(
              data: ChartData(
                chartType: 'bar',
                params: const {'title': ''},
                result: result,
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('空散点(无坐标)也带头绘制不抛错', (tester) async {
    final result = ExecResult(
      inputs: {'in_pts': md.ScatterData(name: '空点', points: const [])},
      outputs: const {},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 400,
          height: 300,
          child: CustomPaint(
            painter: ChartPainter(
              data: ChartData(
                chartType: 'scatter',
                params: const {'title': ''},
                result: result,
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
