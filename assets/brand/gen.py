"""Generate doma's brand SVGs and render pages from one geometry, on flok's 24-unit grid.

The mark: flok's terminal bracket holding a house and a cursor. flok's chevron is a bird in
flight, vink's tick is the bird landed on the line, nt's two lines are a note being written;
doma's glyph is a small house drawn in line, roof, walls and a chimney, standing alone in the
bracket: doma is the one mark without the cursor, because the house is the place the prompt
went home to. The house is drawn at 1.9, lighter than the siblings' 2.9 glyphs, because a closed
outline at 2.9 fills itself in; the chimney is what keeps it from being flok's chevron. Thin
frame (1.6) as in the siblings. The bracket is copied from vink's gen.py unchanged.

Wordmark text is outlined from JetBrains Mono, so no file needs the font to render.
Deterministic: running it again writes the same bytes.

    python3 assets/brand/gen.py        # needs fontTools and brotli (woff2)
    python3 assets/brand/render.py     # then the PNGs (Playwright + cairosvg)
"""
import os
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.transformPen import TransformPen

HERE = os.path.dirname(os.path.abspath(__file__))
FONTS = os.environ.get('DOMA_FONTS', os.path.join(HERE, '..', '..', 'docs', 'design-system', 'fonts'))

# ---- palette (docs/design-system/tokens.json is the source of truth; these mirror it) ----
TEAL = '#12999D'     # brand: W4J teal, the tie to w4jnl
CYAN = '#3FD0D4'     # accent and mark on dark
INK_D = '#F2F5F5'    # ink, dark theme
GROUND = '#14181A'   # ground, dark theme
MUTED = '#8A999C'    # ink-muted, dark theme
HAVE = '#5FC47A'     # have, dark theme (vink's up)
LOW = '#E8963C'      # low, dark theme (vink's late)
OUT = '#F0645A'      # out, dark theme (vink's down)
OUT_TILE = '#C0342B' # out, light theme: tile fill under a white mark

TAGLINE = 'what to buy, what is there, what to bring'
REPO = 'w4jnl/doma'

# ---- geometry (bracket and cursor: vink's gen.py, unchanged) ----
BRACKET = ('<g stroke="{c}" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" fill="none">'
           '<path d="M8 3.2 H6 a2.2 2.2 0 0 0 -2.2 2.2 V18.6 a2.2 2.2 0 0 0 2.2 2.2 H8"/>'
           '<path d="M16 3.2 H18 a2.2 2.2 0 0 1 2.2 2.2 V18.6 a2.2 2.2 0 0 1 -2.2 2.2 H16"/></g>')
# the siblings' cursor, kept for reference; doma's mark does not use it
CURSOR = '<rect x="9.6" y="16.2" width="4.8" height="2.2" rx="1.1" fill="{c}"/>'
# doma's glyph: a house in line, roof and walls closed into one path with a chimney on the right
# slope, 8.6 wide at the eaves and centred in the bracket, drawn at 1.9 so the inside stays open.
# No cursor: the house stands alone, which is doma's one departure from the siblings.
HOUSE_D = 'M7.7 11.8 L12 7.5 L16.3 11.8 V15.3 a1 1 0 0 1 -1 1 H8.7 a1 1 0 0 1 -1 -1 Z M14.4 9.9 V7.8'
HOUSE_W = 1.9
HOUSE = '<path d="' + HOUSE_D + '" stroke="{c}" stroke-width="' + str(HOUSE_W) + '" stroke-linecap="round" stroke-linejoin="round" fill="none"/>'

def mark_inner(c):
    return BRACKET.format(c=c) + HOUSE.format(c=c)

def mark_alert_inner(c, mid='domaAlert'):
    # solid tile, house knocked out: at 16-22px value, not detail, carries the state
    return (f'<mask id="{mid}"><rect x="2.6" y="2.2" width="18.8" height="19.6" rx="5.2" fill="#fff"/>'
            f'<path d="{HOUSE_D}" stroke="#000" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round" fill="none"/></mask>'
            f'<rect x="2.6" y="2.2" width="18.8" height="19.6" rx="5.2" fill="{c}" mask="url(#{mid})"/>')

def svg(w, h, body, title, vb=None):
    vb = vb or f'0 0 {w} {h}'
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}" width="{w}" height="{h}"><title>{title}</title>{body}</svg>\n'

# ---- outlined text ----
def num(v):
    s = ('%.2f' % v).rstrip('0').rstrip('.')
    return '0' if s in ('-0', '') else s

_fonts = {}
def font(weight):
    if weight not in _fonts:
        _fonts[weight] = TTFont(os.path.join(FONTS, f'JetBrainsMono-{weight}.woff2'))
    return _fonts[weight]

def text_path(txt, size, x, y, weight=700, spacing=0.0):
    f = font(weight)
    gs = f.getGlyphSet(); cmap = f.getBestCmap(); upm = f['head'].unitsPerEm
    s = size / upm
    parts = []
    cx = x
    for ch in txt:
        gname = cmap[ord(ch)]
        pen = SVGPathPen(gs, ntos=num)
        gs[gname].draw(TransformPen(pen, (s, 0, 0, -s, cx, y)))
        d = pen.getCommands()
        if d:
            parts.append(d)
        cx += gs[gname].width * s + spacing
    return ' '.join(parts), cx

def text_el(txt, size, x, y, fill, weight=700, spacing=0.0):
    d, _ = text_path(txt, size, x, y, weight, spacing)
    return f'<path d="{d}" fill="{fill}"/>'

def text_end(txt, size, x, weight=700, spacing=0.0):
    return text_path(txt, size, x, 0, weight, spacing)[1]

def text_ink(txt, size, x, weight=700, spacing=0.0):
    # the ink's left and right edge, as opposed to the advance: side bearings differ per letter,
    # so anything placed symmetrically around a word must use these
    f = font(weight)
    gs = f.getGlyphSet(); cmap = f.getBestCmap(); s = size / f['head'].unitsPerEm
    cx = x; left = right = None
    for ch in txt:
        g = gs[cmap[ord(ch)]]
        bp = BoundsPen(gs); g.draw(bp)
        xmin, _, xmax, _ = bp.bounds
        l, r = cx + xmin * s, cx + xmax * s
        left = l if left is None else min(left, l)
        right = r if right is None else max(right, r)
        cx += g.width * s + spacing
    return left, right

# ---- builders ----
def mark(c, title='doma'):
    return svg(24, 24, mark_inner(c), title)

def mark_alert(c):
    return svg(24, 24, mark_alert_inner(c), 'doma - something is out')

def lockup_body(mark_c, word_c):
    return f'<g transform="scale(1.83333)">{mark_inner(mark_c)}</g>' + text_el('doma', 34, 56, 32, word_c, 700, -1)

def lockup(mark_c, word_c):
    w = round(text_end('doma', 34, 56, 700, -1) + 4)
    return svg(w, 44, lockup_body(mark_c, word_c), 'doma - horizontal lockup')

def lockup_tagline_body(mark_c, word_c, tag_c, tag_size=11):
    return (f'<g transform="translate(0 4) scale(1.83333)">{mark_inner(mark_c)}</g>'
            + text_el('doma', 28, 56, 30, word_c, 700, -1)
            + text_el(TAGLINE, tag_size, 57, 46, tag_c, 400, 0))

def lockup_tagline(mark_c, word_c, tag_c):
    w = round(max(text_end('doma', 28, 56, 700, -1), text_end(TAGLINE, 11, 57, 400)) + 4)
    return svg(w, 52, lockup_tagline_body(mark_c, word_c, tag_c), 'doma - lockup with tagline')

WORDMARK_GAP = 7   # units between a bracket's arm and the word's ink, the same on both sides

def wordmark(bracket_c, word_c):
    # [doma]: the brackets sit WORDMARK_GAP from the ink on both sides. The left arm ends at 16 as
    # in the siblings; the text is placed by its ink, not its advance, because side bearings differ
    # per letter (the siblings' advance-based placement hid the difference behind an n or a t).
    ink_l0, _ = text_ink('doma', 40, 0, 700, -1)
    x = 16 + WORDMARK_GAP - ink_l0
    _, ink_r = text_ink('doma', 40, x, 700, -1)
    a = num(ink_r + WORDMARK_GAP)
    b = num(ink_r + WORDMARK_GAP + 7)
    w = round(ink_r + WORDMARK_GAP + 7 + 5 + 4)
    body = (f'<g stroke="{bracket_c}" stroke-width="4.2" stroke-linecap="round" stroke-linejoin="round" fill="none">'
            '<path d="M16 5 H9 a5 5 0 0 0 -5 5 V42 a5 5 0 0 0 5 5 H16"/>'
            f'<path d="M{a} 5 H{b} a5 5 0 0 1 5 5 V42 a5 5 0 0 1 -5 5 H{a}"/></g>'
            + text_el('doma', 40, x, 38, word_c, 700, -1))
    return svg(w, 52, body, '[doma]')

def favicon(tile, fg):
    return svg(32, 32, f'<rect width="32" height="32" rx="7" fill="{tile}"/><g transform="translate(4 4)">{mark_inner(fg)}</g>', 'doma')

def favicon_alert(tile, fg):
    body = (f'<rect width="32" height="32" rx="7" fill="{tile}"/>'
            f'<g transform="translate(4 4)">{mark_alert_inner(fg, "domaFavAlert")}</g>')
    return svg(32, 32, body, 'doma - something is out')

def tile(fill, fg):
    # W4J's rounded square (radius-tile, 22%) with the mark at 35% of the width, like vink's avatar
    return svg(120, 120, f'<rect width="120" height="120" rx="26.4" fill="{fill}"/>'
               f'<g transform="translate(29.28 29.28) scale(2.56)">{mark_inner(fg)}</g>', 'doma')

def appicon():
    # the Mac and phone app icon, flok's recipe: cyan mark on a dark gradient tile, the frame and
    # the house a step heavier because the icon is seen small and on busy wallpapers
    body = ('<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1b2124"/>'
            '<stop offset="1" stop-color="#0f1214"/></linearGradient></defs><rect width="120" height="120" fill="url(#g)"/>'
            f'<g transform="translate(19.2 19.2) scale(3.4)"><g stroke="{CYAN}" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round" fill="none">'
            '<path d="M7.6 3.2 H5 a2.4 2.4 0 0 0 -2.4 2.4 V18.4 a2.4 2.4 0 0 0 2.4 2.4 H7.6"/>'
            '<path d="M16.4 3.2 H19 a2.4 2.4 0 0 1 2.4 2.4 V18.4 a2.4 2.4 0 0 1 -2.4 2.4 H16.4"/></g>'
            f'<path d="M7.2 11.7 L12 6.9 L16.8 11.7 V15.6 a1.1 1.1 0 0 1 -1.1 1.1 H8.3 a1.1 1.1 0 0 1 -1.1 -1.1 Z M14.7 9.6 V7.2" stroke="{CYAN}" stroke-width="2.3" stroke-linecap="round" stroke-linejoin="round" fill="none"/></g>')
    return svg(1024, 1024, body, 'doma', vb='0 0 120 120')

def write(path, text):
    with open(path, 'w') as fh:
        fh.write(text)

# ---- render pages: a headless browser turns these into the PNGs (render.py) ----
FONT_FACE = ''.join(
    f'@font-face{{font-family:"JetBrains Mono";font-weight:{w};src:url("../../docs/design-system/fonts/JetBrainsMono-{w}.woff2") format("woff2")}}'
    for w in (400, 700))

def page(w, h, body, extra_css=''):
    return ('<!doctype html>\n<!-- generated by gen.py; render.py turns it into a PNG with a headless browser -->\n'
            '<html><head><meta charset="utf-8"><style>'
            + FONT_FACE
            + f'html,body{{margin:0;width:{w}px;height:{h}px;overflow:hidden;background:{GROUND};color:{INK_D};'
            'font-family:"JetBrains Mono",ui-monospace,monospace}'
            f'.bar{{position:absolute;left:0;top:0;width:6px;height:{h}px;background:{CYAN}}}'
            + extra_css + '</style></head><body><div class="bar"></div>' + body + '</body></html>\n')

def hero_page():
    # flok's banner: the tagline lockup at 3.2x, the tagline set smaller than the small lockup's
    vw = round(text_end(TAGLINE, 6.4, 57, 400) + 4)
    lk = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {vw} 52" width="{round(vw * 3.2)}" height="166">'
          + lockup_tagline_body(CYAN, INK_D, MUTED, tag_size=6.4) + '</svg>')
    return page(1280, 320, f'<div class="lockup">{lk}</div>', '.lockup{position:absolute;left:72px;top:77px}')

def social_page():
    # the family social card: lockup, repo line, a two-line claim and the states in their colours
    lk = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {round(text_end("doma", 34, 56, 700, -1) + 4)} 44" '
          f'height="132">' + lockup_body(CYAN, INK_D) + '</svg>')
    states = ''.join(f'<span style="color:{c}">{g}&nbsp;{w}</span>' for g, w, c in (
        ('●', 'have', HAVE), ('◐', 'low', LOW), ('◆', 'out', OUT), ('◌', 'unknown', MUTED)))
    body = (f'<div class="lockup">{lk}</div>'
            f'<div class="repo">{REPO}&nbsp;&nbsp;·&nbsp;&nbsp;Go&nbsp;&nbsp;·&nbsp;&nbsp;Swift</div>'
            '<div class="claim">One list the family shares.<br>What is at each home, and what to bring.</div>'
            f'<div class="states">{states}</div>')
    css = ('.lockup{position:absolute;left:96px;top:180px}'
           f'.repo{{position:absolute;left:266px;top:288px;font-size:20px;color:{MUTED}}}'
           '.claim{position:absolute;left:96px;top:396px;font-size:36px;font-weight:700;line-height:52px}'
           '.states{position:absolute;left:96px;top:540px;font-size:18px;display:flex;gap:36px}')
    return page(1280, 640, body, css)

# ---- the repo set: currentColor masters, so docs and templates can tint them ----
R = HERE
write(f'{R}/doma-mark.svg', mark('currentColor'))
write(f'{R}/doma-mark-alert.svg', mark_alert('currentColor'))
write(f'{R}/doma-mark-teal.svg', mark(TEAL))
write(f'{R}/doma-mark-cyan.svg', mark(CYAN))
write(f'{R}/doma-lockup.svg', lockup('currentColor', 'currentColor'))
write(f'{R}/doma-lockup-tagline.svg', lockup_tagline('currentColor', 'currentColor', MUTED))
write(f'{R}/doma-wordmark.svg', wordmark('currentColor', 'currentColor'))
write(f'{R}/favicon.svg', favicon(TEAL, '#ffffff'))
write(f'{R}/favicon-alert.svg', favicon_alert(OUT_TILE, '#ffffff'))
write(f'{R}/doma-tile.svg', tile(TEAL, '#ffffff'))
write(f'{R}/doma-appicon.svg', appicon())
write(f'{R}/hero.html', hero_page())
write(f'{R}/social.html', social_page())
print('ok')
