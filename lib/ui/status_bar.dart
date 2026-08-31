// 状态栏:节点/连接数、拓扑状态、自动执行状态与操作提示(由 React 版 StatusBar.tsx 移植)
library;

import 'package:flutter/material.dart';

import '../store/graph_store.dart';
import 'theme.dart';

class StatusBar extends StatelessWidget {
  const StatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    final store = GraphStore.instance;
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final t = SyphonTheme.of(context);
        final statusColor = store.hasCycle ? t.warn : t.success;
        return Container(
          height: SyphonDims.statusH,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: t.bgSurface,
            border: Border(top: BorderSide(color: t.stroke, width: 1)),
          ),
          child: Row(
            children: [
              Text(
                '节点数: ${store.nodes.length}',
                style: TextStyle(fontSize: 11, color: t.textFaint),
              ),
              const SizedBox(width: 16),
              Text(
                '连接数: ${store.edges.length}',
                style: TextStyle(fontSize: 11, color: t.textFaint),
              ),
              const SizedBox(width: 16),
              Text(
                store.hasCycle ? '回路警告' : '拓扑正常',
                style: TextStyle(fontSize: 11, color: statusColor),
              ),
              const SizedBox(width: 16),
              Text(
                '自动执行:${store.autoRun ? '开' : '关'}',
                style: TextStyle(fontSize: 11, color: t.textFaint),
              ),
              const Spacer(),
              // 提示文案允许收缩:窄窗口(或测试用的小窗口)下省略号截断,
              // 避免 RenderFlex 溢出
              Flexible(
                child: Text(
                  '右键新建节点 · 删除键移除 · Ctrl+拖拽连线 · Ctrl+滚轮缩放画布 · 滚轮在预览窗内缩放 · Alt+悬停曲线拆分',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: TextStyle(
                    fontSize: 11,
                    color: t.textFaint.withValues(alpha: 0.75),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
