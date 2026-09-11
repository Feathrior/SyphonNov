from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.image as mpimg

folder = Path(__file__).parent.parent / 'SyphonNov/build/export-qa'
files = sorted(folder.glob('*-pdf.png'))
for start in [0, 5]:
    fig, axes = plt.subplots(3, 2, figsize=(13, 12), layout='constrained')
    for ax in axes.flat:
        ax.axis('off')
    for ax, path in zip(axes.flat, files[start:start+5]):
        ax.imshow(mpimg.imread(path))
        ax.set_title(path.stem, fontsize=13)
    fig.savefig(folder / f'contact-{start//5+1}.png', dpi=140, facecolor='#f2f3f5')
    plt.close(fig)
