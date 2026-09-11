from pathlib import Path
import json
import math
import struct
import xml.etree.ElementTree as ET
from pypdf import PdfReader

project = Path(__file__).resolve().parent.parent / 'SyphonNov'
folder = project / 'build/export-qa'
results = []
for path in sorted(folder.glob('viz_*.pdf')):
    reader = PdfReader(path)
    assert len(reader.pages) == 1, path
    page = reader.pages[0]
    width, height = float(page.mediabox.width), float(page.mediabox.height)
    assert abs(width - 160 * 72 / 25.4) < 1e-4, path
    assert abs(height - 100 * 72 / 25.4) < 1e-4, path
    assert len(page.images) == 0, path
    text = page.extract_text()
    assert any('\u4e00' <= c <= '\u9fff' for c in text), path
    svg = ET.parse(path.with_suffix('.svg')).getroot()
    tag = lambda name: '{http://www.w3.org/2000/svg}' + name
    assert svg.attrib['width'].endswith('mm'), path
    assert svg.attrib['height'].endswith('mm'), path
    assert float(svg.attrib['width'][:-2]) == 160, path
    assert float(svg.attrib['height'][:-2]) == 100, path
    assert not list(svg.iter(tag('image'))), path
    paths = len(list(svg.iter(tag('path'))))
    texts = len(list(svg.iter(tag('text'))))
    assert paths and texts, path
    png = path.with_suffix('.png').read_bytes()
    assert png[:8] == b'\x89PNG\r\n\x1a\n', path
    pixels = struct.unpack('>II', png[16:24])
    assert pixels == (1890, 1181), path
    offset, dpi = 8, None
    while offset < len(png):
        length = struct.unpack('>I', png[offset:offset + 4])[0]
        kind = png[offset + 4:offset + 8]
        data = png[offset + 8:offset + 8 + length]
        if kind == b'pHYs':
            xppm, yppm, unit = struct.unpack('>IIB', data)
            assert unit == 1 and xppm == yppm, path
            dpi = xppm * 0.0254
            assert abs(dpi - 300) < 0.02, path
        offset += length + 12
    assert dpi is not None, path
    results.append(dict(chart=path.stem, pdf_page_points=[width, height],
                        pdf_images=len(page.images), pdf_text_characters=len(text),
                        pdf_chinese_text_extractable=True,
                        svg_paths=paths, svg_text_runs=texts,
                        svg_images=0, png_pixels=pixels, png_dpi=dpi))
assert len(results) == 10, len(results)
report = dict(validation='Actual generated files; structure only, separate visual review required.',
              logical_page_mm=[160, 100], charts=results)
destination = project / 'docs/verification/export-structure.json'
destination.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print(f'{len(results)} chart triplets passed PDF/SVG/PNG file inspection.')
print(destination)
