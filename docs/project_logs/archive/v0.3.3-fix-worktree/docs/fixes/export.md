# 固定物理页面与真实矢量导出

## 原问题与新的约定

原导出把当前 Flutter 画布绘制成 PNG。提高像素数可以改善像素边缘，但不能产生可编辑路径、可搜索文字，也不能单独保证期刊要求的物理尺寸。

新增 `lib/ui/vector_export.dart`，在同一页面模型下提供 PNG、SVG、PDF 三种后端：

| 项目 | 约定 |
| --- | --- |
| 页面 | `widthMm`、`heightMm`，默认 160 × 100 mm |
| 布局坐标 | 每英寸 96 个逻辑单位，与显示器和导出 DPI 无关 |
| PNG | `round(mm / 25.4 × DPI)` 像素，包含 `pHYs` 分辨率元数据 |
| SVG | 根元素用 mm 指定宽高，`viewBox` 使用固定布局坐标 |
| PDF | `MediaBox = mm / 25.4 × 72`，原生路径、文字、渐变指令 |

因此只改 DPI 时，标题大小、数据点相对位置和图例布局不会改变。PNG 的整数像素舍入最多引入每边半个像素的物理尺寸差；SVG/PDF 没有这个整数像素限制。

## 接入现有绘图器

`renderVectorSvg(painter, page)` 与 `renderVectorPdf(painter, page)` 接受现有 `CustomPainter`。`VectorExportCanvas implements Canvas` 记录图形、仿射变换和裁剪，再生成各格式的原生内容。它不调用截图、图像编码或 PNG 嵌入。

绘图器有两处需要保留高层信息：

1. 已完成 `TextPainter.layout()` 后，用 `exportAwareTextPaint(canvas, painter, offset)` 替代 `painter.paint(canvas, offset)`。普通画布仍调用原方法；矢量画布读取每行文本、基线和实测宽度，输出 SVG `<text>` 或 PDF 文本指令。
2. 用 `exportAwareLinearGradientPaint(Paint(), start, end, colors)` 创建线性渐变。`ui.Shader` 本身不能反向读取色标；辅助函数保存同一组渐变参数供矢量后端使用。

`renderPagePng(painter, page)` 按同一逻辑尺寸排版后缩放到像素尺寸，编码完成后写入 PNG 的物理分辨率。PNG 限制为 6400 万像素，避免无意创建过大的图像。

## 路径近似与误差边界

Flutter 的 `Path` 不公开原始直线/贝塞尔控制点序列，因此通用路径利用 `Path.computeMetrics()` 按弧长离散。默认最大步长为 **0.25 个页面逻辑单位**。记录器跟踪完整二维变换，使用线性部分的 Frobenius 范数上界收紧局部采样步长；放大或剪切后也保持页面上的同一界限。

设相邻样本之间的弧长不超过 \(h\)。原曲线的任意点至少距离一个端点不超过 \(h/2\)；连接样本的线段上的任意点，也至少距离一个端点不超过半条弦长，而弦长不超过弧长。因此曲线与折线的双向距离最多 \(h/2\)。默认对应 **0.125 个逻辑单位 ≈ 0.0331 mm**。

这个界限相对于 Flutter `PathMetrics` 返回的度量路径成立，另有图形引擎自身计算路径度量的近似误差；它不是对任意原始解析函数或最终文件总误差的承诺。当前 PDF 库还把指令坐标写到小数点后 5 位，单个坐标的舍入不超过 0.000005 个局部单位，后续变换会放大这个误差；极大的局部变换应另作成品验证。图形原本就是数据点连接成的折线时，也不能凭矢量导出恢复尚未采集的数据。可以调小 `maxPathStep` 获得更细路径，代价是更多顶点、更大文件。总采样点上限为 200 万，超限明确报错。

## 文本、字体和效果边界

- SVG 保留文字、字号、字体族、粗斜体、每行基线和宽度，不把文字转成位图或轮廓。未嵌入字体文件；接收端需要相应字体，缺失时由其字体替换规则处理。
- PDF 的拉丁文本使用标准 PDF 字体。遇到不能覆盖的字符时，Windows 下读取并嵌入可用的 Arial / 黑体 TTF 子集；库也接受调用方提供的有权使用的 TTF 字节。缺字明确报错，不静默丢失文字。PDF 含 `ToUnicode` 映射，中文保持可搜索语义。
- 文本宽度按 Flutter 的实测宽度约束，但不同后端或回退字体的字形、粗细和垂直度量可能略有差异。自定义字体族不会自动找到同名字体文件；要求字形严格一致时应传入相应 TTF，并检查成品。
- SVG 支持线性渐变和逐色标透明度。PDF 支持填充用的线性渐变与统一透明度；渐变描边或色标间透明度变化暂时明确报错。
- 图片、阴影、滤镜、未登记的 shader、混合样式文本、未知 Canvas 操作不会被悄悄忽略。导出中止并报告不支持；不会生成缺少内容或整体栅格化的“矢量文件”。
- 这里导出的是既有二维画布，包括已经投影到二维的三维图景；PDF/SVG 不保存可旋转的三维模型。

## 验证

`test/export_vector_test.dart` 对以下结果作直接断言：

- 改变 DPI 不改变逻辑尺寸或 SVG 内容；PDF 页面尺寸正确。
- SVG 包含路径、椭圆与转义后可读文字，没有 `<image>` 或 base64 位图。
- 保存/恢复状态正确隔离变换与裁剪。
- 已知曲线经放大后，采样点间距和密集检查点的误差满足声明界限。
- PDF 含路径与文本操作、渐变 shading，不含 image XObject；有字体时嵌入中文并生成 ToUnicode。
- 缺字、原始段落绘制、未登记 shader 明确失败。
- PNG 像素尺寸与 `pHYs` 分辨率相符。
- 全景预设中的 10 类现有绘图器（包括桑基图、投影三维图）均能生成 SVG/PDF，且无 image 图元。
- 完整长热力图列名的旋转边界在页面内；3D 刻度保持声明的逻辑像素字号，标签测量框互不重叠。

本次验证环境 Flutter 3.47.2 / Dart 3.13.2：导出测试 **11 项通过**，原有 CSV/XLSX 导入测试 **4 项通过**。验证时仍需查看实际成品，尤其是字体回退、很密集的标签和复杂路径。`SYPHON_EXPORT_QA_DIR` 环境变量可让预设集成测试额外输出三种格式供检查；测试环境默认使用 Ahem 测试字体，目视比较前需要加载真实字体，不能把方块测试字体当作产品最终字形。

最终视觉 QA 追加两项排版回归后，`export_vector_test.dart` **13 项**与 `chart_coordinates_test.dart` **14 项**合计 **27/27 通过，退出码 0**。再次生成十类 PNG/SVG/PDF，实际检查发现并修正：

1. Ahem 是 Flutter 测试用方块字体。仅注册同名替代字体不足以改变引擎默认选择；绘图测量和绘制现在显式指定默认字体族 `Microsoft YaHei`，有字体参数时使用该参数。Windows QA 将本机 `simhei.ttf` 注册到同一明确字体族后再输出，PNG 中的中文及数字均恢复实际字形。
2. 原理化输出的坐标轴参数明确以 px 为单位，但绘制时又乘页面尺寸因子，导致字号被放大。现在字号按逻辑像素使用，3D 刻度文字沿轴法向偏移，轴名优先保留；测量框碰撞时减少刻度文字，仍保留刻度线及数据图元。
3. 热力图根据完整列名的旋转后尺寸预留底部和右侧空间，保留原标签内容；火山图左边距根据刻度与轴标题的实际尺寸计算。PNG 与 PDF 中原先确认的裁切已消除。

这属于固定默认页面下已确认问题的修复，不是任意长度文字、任意密度数据或任意三维视角的自动排版保证。不同 PDF 回退字体仍可能有轻微字形差异，仍应检查最终成品。

## 技术来源

- [Flutter Canvas](https://api.flutter.dev/flutter/dart-ui/Canvas-class.html)
- [Flutter Path.computeMetrics](https://api.flutter.dev/flutter/dart-ui/Path/computeMetrics.html)
- [pdf 包](https://pub.dev/packages/pdf) 与 [PdfGraphics API](https://pub.dev/documentation/pdf/latest/pdf/PdfGraphics-class.html)
- [PNG 物理像素尺寸 pHYs](https://www.w3.org/TR/png-3/#11pHYs)

新增依赖 `pdf: ^3.12.0`，由锁文件记录实际解析版本。它要求 `archive <4.1`，因此将直接依赖下限由 `^4.2.0` 调整为 `^4.0.9`，在原有 4.x API 内求解兼容版本，不使用 `dependency_overrides`。现有 XLSX 导入回归测试覆盖 `ZipDecoder.decodeBytes`、`ArchiveFile.content` 与测试夹具的 ZIP 编码，需随本次依赖调整一起运行。没有打包或再分发 Windows 字体文件。
