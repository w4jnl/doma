"""Render the PNGs from what gen.py writes.

hero.html -> doma-hero.png (1280x320) and social.html -> doma-social.png (1280x640) with
Playwright's Chromium; doma-tile.svg -> doma-avatar.png (460) and doma-512.png, and
doma-appicon.svg -> app/ios/Doma/Assets.xcassets/AppIcon.appiconset/AppIcon.png (1024, flattened on
the tile's bottom colour, as the App Store refuses an alpha channel) with cairosvg. The fonts come from docs/design-system/fonts, so no
network is needed. Run gen.py first after changing the geometry, the tagline or the claim.

    pip install playwright cairosvg && playwright install chromium
    python3 assets/brand/render.py
"""
import os
import cairosvg
from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
os.chdir(HERE)

def shot(page_file, w, h, out):
    with sync_playwright() as p:
        b = p.chromium.launch()
        pg = b.new_page(viewport={'width': w, 'height': h}, device_scale_factor=1)
        pg.goto('file://' + os.path.join(HERE, page_file))
        pg.wait_for_timeout(300)   # let the woff2 fonts settle
        pg.screenshot(path=out, clip={'x': 0, 'y': 0, 'width': w, 'height': h})
        b.close()

shot('hero.html', 1280, 320, 'doma-hero.png')
shot('social.html', 1280, 640, 'doma-social.png')
cairosvg.svg2png(url='doma-tile.svg', write_to='doma-avatar.png', output_width=460, output_height=460)
cairosvg.svg2png(url='doma-tile.svg', write_to='doma-512.png', output_width=512, output_height=512)
appicon = os.environ.get('DOMA_APPICON', os.path.join(HERE, '..', '..', 'app', 'ios', 'Doma', 'Assets.xcassets', 'AppIcon.appiconset', 'AppIcon.png'))
cairosvg.svg2png(url='doma-appicon.svg', write_to=appicon, output_width=1024, output_height=1024, background_color='#0f1214')
for f in ('doma-hero.png', 'doma-social.png', 'doma-avatar.png', 'doma-512.png', appicon):
    print(f, os.path.getsize(f), 'bytes')
