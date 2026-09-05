// 设置面板:自动执行开关 + 亮暗主题(由 React 版 SettingsPanel.tsx 移植)
library;

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';

import '../store/graph_store.dart';
import '../i18n.dart';
import '../store/settings_store.dart';
import 'theme.dart';

class SettingsPanel extends StatefulWidget {
  final VoidCallback onClose;

  const SettingsPanel({super.key, required this.onClose});

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  @override
  Widget build(BuildContext context) {
    final settings = SettingsStore.instance;
    // fluent.showDialog 不自动居中,这里用 Center + Padding 模拟原 Dialog 的居中/inset
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 70),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: AnimatedBuilder(
            animation: settings,
            builder: (context, _) {
              final t = SyphonTheme.of(context);
              return Container(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height - 140,
                ),
                decoration: BoxDecoration(
                  color: t.bgSurface,
                  border: Border.all(color: t.strokeStrong),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.35),
                      blurRadius: 40,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildHeader(t),
                    Divider(height: 1, thickness: 1, color: t.stroke),
                    // 主体:导航 + 内容
                    _buildBody(context, settings, t),
                    Divider(height: 1, thickness: 1, color: t.stroke),
                    _buildFooter(t),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// 头部:标题 + 关闭按钮
  Widget _buildHeader(SyphonTheme t) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 10, 14),
      child: Row(
        children: [
          Text(L.t('设置'),
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: t.text)),
          const Spacer(),
          _CloseButton(onPressed: widget.onClose),
        ],
      ),
    );
  }

  /// 主体:左侧导航 + 右侧设置内容
  Widget _buildBody(BuildContext context, SettingsStore settings, SyphonTheme t) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 240),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildNav(t),
            // 右侧内容
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 16, 20, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionTitle(L.t('通用'), t),
                    const SizedBox(height: 4),
                    _row(
                      L.t('自动执行'),
                      L.t('图元或连线变更后自动重新执行整个数据流'),
                      fluent.ToggleSwitch(
                        checked: settings.autoRun,
                        onChanged: (v) {
                          settings.setAutoRun(v);
                          GraphStore.instance.autoRun = v;
                        },
                      ),
                      t,
                    ),
                    _row(
                      L.t('主题'),
                      L.t('界面亮暗模式,切换后立即生效并持久化保存'),
                      _Segmented<AppTheme>(
                        value: settings.theme,
                        options: [
                          (AppTheme.light, L.t('亮色')),
                          (AppTheme.dark, L.t('暗色')),
                        ],
                        onChanged: settings.setTheme,
                      ),
                      t,
                    ),
                    _row(
                      L.t('语言'),
                      L.t('界面显示语言'),
                      _Segmented<String>(
                        value: settings.locale,
                        options: [
                          ('zh', '中文'),
                          ('en', 'English'),
                        ],
                        onChanged: settings.setLocale,
                      ),
                      t,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 左侧导航:当前仅"常用设置"一项(高亮选中态)
  Widget _buildNav(SyphonTheme t) {
    return Container(
      width: 152,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: t.stroke)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: t.accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(SyphonDims.radiusS),
            ),
            child: Text(L.t('常用设置'),
                style: TextStyle(fontSize: 12, color: t.text)),
          ),
        ],
      ),
    );
  }

  /// 底部:保存提示 + 完成按钮
  Widget _buildFooter(SyphonTheme t) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
      child: Row(
        children: [
          Text(L.t('修改自动保存至 settings.json'),
              style: TextStyle(fontSize: 11, color: t.textFaint)),
          const Spacer(),
          _PrimaryButton(
            label: L.t('完成'),
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  // 分组标题(小号大写)
  Widget _sectionTitle(String text, SyphonTheme t) {
    return Text(text,
        style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
            color: t.textFaint));
  }

  // 设置行:标签 + 描述 + 控件
  Widget _row(String label, String desc, Widget control, SyphonTheme t) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 13),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.stroke)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(fontSize: 13, color: t.text)),
                const SizedBox(height: 2),
                Text(desc, style: TextStyle(fontSize: 11, color: t.textFaint)),
              ],
            ),
          ),
          const SizedBox(width: 16),
          control,
        ],
      ),
    );
  }
}

/// 关闭按钮(28px 圆形)
class _CloseButton extends StatefulWidget {
  final VoidCallback onPressed;
  const _CloseButton({required this.onPressed});

  @override
  State<_CloseButton> createState() => _CloseButtonState();
}

class _CloseButtonState extends State<_CloseButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          width: 28,
          height: 28,
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            // 同色 alpha=0,避免 transparent(黑 RGB)插值先变黑
            color: _hover ? t.bgFloat : t.bgFloat.withValues(alpha: 0),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Text('✕', style: TextStyle(fontSize: 13, color: t.textDim)),
        ),
      ),
    );
  }
}

/// 主按钮(accent 背景)
class _PrimaryButton extends StatefulWidget {
  final String label;
  final VoidCallback onPressed;
  const _PrimaryButton({required this.label, required this.onPressed});

  @override
  State<_PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<_PrimaryButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 7),
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: _hover ? t.accentHover : t.accent,
            borderRadius: BorderRadius.circular(SyphonDims.radiusS),
            border: Border.all(color: t.accent),
          ),
          child: Text(widget.label,
              style: TextStyle(
                  fontSize: 12, color: t.onAccent, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}

/// 分段选择(bgRaise 容器,选中项 bgSurface + 阴影)
class _Segmented<T> extends StatefulWidget {
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;

  const _Segmented({
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  State<_Segmented<T>> createState() => _SegmentedState<T>();
}

class _SegmentedState<T> extends State<_Segmented<T>> {
  int _hover = -1;

  @override
  Widget build(BuildContext context) {
    final t = SyphonTheme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: t.bgRaise,
        borderRadius: BorderRadius.circular(SyphonDims.radiusS),
        border: Border.all(color: t.strokeStrong),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < widget.options.length; i++) _buildOption(i, t),
        ],
      ),
    );
  }

  /// 单个分段选项:悬停/选中态高亮
  Widget _buildOption(int i, SyphonTheme t) {
    final selected = widget.value == widget.options[i].$1;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = i),
      onExit: (_) => setState(() {
        if (_hover == i) _hover = -1;
      }),
      child: GestureDetector(
        onTap: () => widget.onChanged(widget.options[i].$1),
        child: AnimatedContainer(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: selected
                ? t.bgSurface
                : (_hover == i ? t.bgFloat : t.bgFloat.withValues(alpha: 0)),
            borderRadius: BorderRadius.circular(3),
            boxShadow: selected
                ? [
                    BoxShadow(
                        color: Colors.black.withValues(alpha: 0.12),
                        blurRadius: 2,
                        offset: const Offset(0, 1))
                  ]
                : null,
          ),
          child: Text(widget.options[i].$2,
              style: TextStyle(
                  fontSize: 12,
                  color: selected ? t.text : t.textDim)),
        ),
      ),
    );
  }
}
