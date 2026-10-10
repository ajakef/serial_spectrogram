#!/usr/bin/env python
"""Makes the Android launcher icons from icon.png (the source artwork: a dark green leaf on white).
Run from the app/ folder after changing icon.png: python make_icons.py

Writes, in android/app/src/main/res/:
  mipmap-*/ic_launcher.png             old-style square icon (Android 7 and earlier)
  mipmap-*/ic_launcher_foreground.png  leaf on a transparent background, for the adaptive icon
  mipmap-anydpi-v26/ic_launcher.xml    adaptive icon: foreground leaf on a white background
  values/ic_launcher_background.xml    the white
Adaptive icons are cropped by the phone into a circle, squircle, etc., and only the middle 66/108
of the image is guaranteed to stay visible, so the leaf is scaled to fit inside that area.
"""
import os
import numpy as np
from PIL import Image

here = os.path.dirname(os.path.abspath(__file__))
res = os.path.join(here, 'android', 'app', 'src', 'main', 'res')
src = Image.open(os.path.join(here, 'icon.png')).convert('RGB')

LEAF = (46, 125, 40)  # leaf color in icon.png
densities = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}

# Leaf on transparent background: opacity is how far each pixel is from white. Laid over white,
# this reproduces the original artwork (including its white veins and smooth edges).
rgb = np.asarray(src).astype(float)
alpha = np.clip((255 - rgb[:, :, 0]) / (255 - LEAF[0]), 0, 1)
alpha = np.clip((alpha - 0.08) / 0.84, 0, 1)  # the source's "white" isn't quite white; treat near-white as fully transparent
leaf = np.zeros(rgb.shape[:2] + (4,), np.uint8)
leaf[:, :, :3] = LEAF
leaf[:, :, 3] = (alpha * 255).round()
leaf = Image.fromarray(leaf, 'RGBA')
leaf = leaf.crop(leaf.getchannel('A').point(lambda a: 255 if a > 40 else 0).getbbox())  # tight box around the leaf

for name, scale in densities.items():
    d = os.path.join(res, 'mipmap-' + name)
    os.makedirs(d, exist_ok=True)
    # old-style icon: 48 dp square, artwork as is
    src.resize((round(48 * scale),) * 2, Image.LANCZOS).save(os.path.join(d, 'ic_launcher.png'))
    # adaptive foreground: 108 dp square; leaf 62 dp tall, centered
    size = round(108 * scale)
    h = round(62 * scale)
    w = round(leaf.width / leaf.height * h)
    fg = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    fg.paste(leaf.resize((w, h), Image.LANCZOS), ((size - w) // 2, (size - h) // 2))
    fg.save(os.path.join(d, 'ic_launcher_foreground.png'))

os.makedirs(os.path.join(res, 'mipmap-anydpi-v26'), exist_ok=True)
with open(os.path.join(res, 'mipmap-anydpi-v26', 'ic_launcher.xml'), 'w') as f:
    f.write('''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
''')
with open(os.path.join(res, 'values', 'ic_launcher_background.xml'), 'w') as f:
    f.write('''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#FFFFFF</color>
</resources>
''')
print('done')
