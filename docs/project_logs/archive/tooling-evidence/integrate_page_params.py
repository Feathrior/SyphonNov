from pathlib import Path
import re

root = Path(__file__).parent.parent / 'SyphonNov'
path = root / 'lib/models/registry.dart'
text = path.read_text(encoding='utf-8')
text, count = re.subn(r"      param\(\n        key: 'canvasPxW',.*?\n      \),", "      ...figurePageParams(),", text, flags=re.S)
assert count == 10, count
text, count = re.subn(r"      param\(\n        key: 'canvasPxH',.*?\n      \),\n", '', text, flags=re.S)
assert count == 1, count
helper = """/// Physical page layout is shared by previews and every export format.
List<ParamSpec> figurePageParams() => [
  param(key: 'pageWidthMm', label: '页面宽度 (mm)', type: 'number',
      defaultValue: 160, min: 20, max: 2000, step: 1),
  param(key: 'pageHeightMm', label: '页面高度 (mm)', type: 'number',
      defaultValue: 100, min: 20, max: 2000, step: 1),
  param(key: 'exportDpi', label: 'PNG DPI', type: 'number',
      defaultValue: 300, min: 36, max: 2400, step: 1,
      help: '只改变 PNG 像素数量，SVG/PDF 的物理尺寸与布局保持不变'),
];

"""
text = text.replace('const List<Map<String, String>> kFontOptions = [', helper + 'const List<Map<String, String>> kFontOptions = [')
text = text.replace('图表文字尺寸,单位厘米(96dpi);与导出像素大小互相独立', '图表文字的物理尺寸（厘米）；DPI 不改变布局')
path.write_text(text, encoding='utf-8')
print('Updated 10 chart page parameter groups.')
