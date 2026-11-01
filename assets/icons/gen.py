"""doma's pictograms: monoline icons on a 16-unit grid, 1.5 strokes, round caps and joins, drawn
in currentColor, as vink's state and kind glyphs are. One file per icon for docs and the asset
catalogue, one sprite (doma-icons.svg, <symbol id="i-<name>">) for the server's web pages,
sheet.html for a look at all of them on both grounds, and the custom SF Symbols the apps use
where the shape is the brand's (the four flags, open and done, the home, the jar, the guest):
SF Symbol templates, outlined from the same geometry in three weights and three scales, under
app/shared/Design/Symbols.xcassets as doma.<name>.

Deterministic: running it again writes the same bytes.

    python3 assets/icons/gen.py
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
S = 'stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" fill="none"'
F = 'fill="currentColor"'

# name: (body, what it means in the app)
ICONS = {
    # the four flags and the two list states: shapes first, colour never alone
    'have':     (f'<circle cx="8" cy="8" r="4" {F}/>', 'flag: it is there'),
    'low':      (f'<circle cx="8" cy="8" r="4" {S}/><path d="M8 4 A4 4 0 0 0 8 12 Z" {F}/>', 'flag: last one open'),
    'out':      (f'<path d="M8 3.2 L12.8 8 L8 12.8 L3.2 8 Z" {F}/>', 'flag: not there'),
    'unknown':  (f'<circle cx="8" cy="8" r="4.25" {S} stroke-dasharray="2.1 2.1"/>', 'flag: nobody has said'),
    'open':     (f'<circle cx="8" cy="8" r="4.25" {S}/>', 'list entry still to get'),
    'done':     (f'<path d="M3.5 8.5 L6.6 11.6 L12.5 5" {S}/>', 'list entry struck, a task done'),
    # objects
    'list':     (f'<path d="M6 4.5 H13 M6 8 H13 M6 11.5 H13" {S}/><circle cx="3.2" cy="4.5" r="1" {F}/><circle cx="3.2" cy="8" r="1" {F}/><circle cx="3.2" cy="11.5" r="1" {F}/>', 'a shared list'),
    'personal': (f'<circle cx="8" cy="5.2" r="2.4" {S}/><path d="M3.3 13.5 C3.3 10.7 5.4 9.1 8 9.1 S12.7 10.7 12.7 13.5" {S}/>', 'a personal list; one person'),
    'home':     (f'<path d="M3 7.6 L8 3 L13 7.6 V12.3 a1 1 0 0 1 -1 1 H4 a1 1 0 0 1 -1 -1 Z M11 5.8 V4" {S}/>', 'a home: the mark\'s house with its chimney'),
    'spot':     (f'<rect x="2.5" y="3.5" width="11" height="9" rx="1.5" {S}/><path d="M2.5 8 H13.5 M6.5 5.8 H9.5 M6.5 10.3 H9.5" {S}/>', 'a spot: a drawer, a shelf, a cabinet'),
    'item':     (f'<rect x="4.5" y="5" width="7" height="8.5" rx="1.6" {S}/><path d="M5.5 3 H10.5" {S}/>', 'an item: the jar'),
    'photo':    (f'<rect x="2" y="5" width="12" height="8" rx="1.5" {S}/><circle cx="8" cy="9" r="2.2" {S}/><path d="M5.6 5 L6.5 3.3 H9.5 L10.4 5" {S}/>', 'a spot photo, the departure sweep'),
    'trip':     (f'<circle cx="3.2" cy="8" r="1.3" {F}/><path d="M6 8 H13 M10.4 5.4 L13 8 L10.4 10.6" {S}/>', 'a trip: from one home to the other'),
    'family':   (f'<circle cx="5.6" cy="5.4" r="2.1" {S}/><circle cx="11" cy="6" r="1.7" {S}/><path d="M1.6 13.2 C1.6 10.8 3.4 9.3 5.6 9.3 S9.6 10.8 9.6 13.2 M10.2 9.6 C12.5 9.4 14.4 10.6 14.4 12.9" {S}/>', 'the household: members and roles'),
    'guest':    (f'<circle cx="8" cy="5.2" r="2.4" {S}/><path d="M3.3 13.5 C3.3 10.7 5.4 9.1 8 9.1 S12.7 10.7 12.7 13.5" {S} stroke-dasharray="2.1 2.1"/>', 'a guest: a person on a link, for a while'),
    'basket':   (f'<path d="M2.4 6.6 H13.6 L12.4 13 H3.6 Z M5.4 6.6 L8 2.6 L10.6 6.6 M6.6 9 V11 M9.4 9 V11" {S}/>', 'shop mode'),
    'qr':       (f'<rect x="2.5" y="2.5" width="4" height="4" rx="0.8" {S}/><rect x="9.5" y="2.5" width="4" height="4" rx="0.8" {S}/><rect x="2.5" y="9.5" width="4" height="4" rx="0.8" {S}/><rect x="9.5" y="9.5" width="1.6" height="1.6" {F}/><rect x="11.9" y="11.9" width="1.6" height="1.6" {F}/><rect x="11.9" y="9.5" width="1.6" height="1.6" {F}/><rect x="9.5" y="11.9" width="1.6" height="1.6" {F}/>', 'an invite or a guest link'),
    'add':      (f'<path d="M8 3 V13 M3 8 H13" {S}/>', 'add'),
    'clear':    (f'<rect x="2.5" y="9.2" width="11" height="4.3" rx="1.2" {S}/><path d="M8 2.6 V7.4 M5.8 5.2 L8 7.4 L10.2 5.2" {S}/>', 'clear struck entries: put them away'),
}

def icon_svg(name, body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="16" height="16">'
            f'<title>doma - {name}</title>{body}</svg>\n')

def sprite():
    syms = ''.join(f'<symbol id="i-{n}" viewBox="0 0 16 16">{b}</symbol>' for n, (b, _) in ICONS.items())
    return f'<svg xmlns="http://www.w3.org/2000/svg" style="display:none">{syms}</svg>\n'

def sheet():
    # every icon at 32px with its name and meaning, once on the dark ground and once on the light
    def half(bg, ink, muted):
        cells = ''.join(
            f'<div class="c"><svg viewBox="0 0 16 16" width="32" height="32">{b}</svg>'
            f'<div><b>{n}</b><br><span>{m}</span></div></div>' for n, (b, m) in ICONS.items())
        return f'<div class="half" style="background:{bg};color:{ink}"><div class="grid">{cells}</div></div>'
    css = ('@font-face{font-family:"JetBrains Mono";font-weight:400;src:url("../../docs/design-system/fonts/JetBrainsMono-400.woff2")}'
           '@font-face{font-family:"JetBrains Mono";font-weight:700;src:url("../../docs/design-system/fonts/JetBrainsMono-700.woff2")}'
           'html,body{margin:0;width:1280px;font-family:"JetBrains Mono",ui-monospace,monospace;font-size:12px}'
           '.half{padding:28px 32px}.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:14px 28px}'
           '.c{display:flex;align-items:center;gap:14px;height:40px}.c b{font-weight:700}.c span{opacity:.6}')
    return ('<!doctype html><html><head><meta charset="utf-8"><style>' + css + '</style></head><body>'
            + half('#14181A', '#F2F5F5', '#8A999C') + half('#F6F8F8', '#14181A', '#5A686B') + '</body></html>\n')

for n, (b, _) in ICONS.items():
    with open(os.path.join(HERE, f'{n}.svg'), 'w') as fh:
        fh.write(icon_svg(n, b))
with open(os.path.join(HERE, 'doma-icons.svg'), 'w') as fh:
    fh.write(sprite())
with open(os.path.join(HERE, 'sheet.html'), 'w') as fh:
    fh.write(sheet())

# --- SF Symbol templates -----------------------------------------------------------------------
# A template is one SVG per symbol, 3300x2200, with Guides (cap and base lines per scale, margins
# per variant) and Symbols (one group per weight-scale). Xcode wants filled outlines, so every
# stroke above is rebuilt here as the union of round-capped capsules, rings and arcs: the same
# 16-grid geometry, outlined.
import math

SYMBOLS = ['have', 'low', 'out', 'unknown', 'open', 'done', 'home', 'item', 'guest']
WEIGHTS = {'Ultralight': 0.55, 'Regular': 1.0, 'Black': 1.75}
# (capline, baseline) per scale and the column centre per weight, in template units
SCALES = {'S': (1556.33, 1626.33), 'M': (1030.79, 1126.79), 'L': (495.82, 625.82)}
COLUMNS = {'Ultralight': 528.0, 'Regular': 1736.0, 'Black': 2944.0}

def fmt(v):
    return ('%.2f' % v).rstrip('0').rstrip('.')

class Pen:
    """Builds filled path data in template units from 16-grid coordinates. Every shape is drawn
    counter-clockwise on screen (arc sweep 0) so overlapping subpaths union under nonzero."""
    def __init__(self, cx, cy, k):
        self.cx, self.cy, self.k, self.d = cx, cy, k, []
    def pt(self, x, y):
        return (self.cx + (x - 8) * self.k, self.cy + (y - 8) * self.k)
    def disc(self, x, y, r, hole=False):
        (px, py), r = self.pt(x, y), r * self.k
        sw = 1 if hole else 0
        self.d.append('M%s %s A%s %s 0 1 %d %s %s A%s %s 0 1 %d %s %s Z' % (
            fmt(px - r), fmt(py), fmt(r), fmt(r), sw, fmt(px + r), fmt(py), fmt(r), fmt(r), sw, fmt(px - r), fmt(py)))
    def ring(self, x, y, r, w):
        self.disc(x, y, r + w / 2)
        self.disc(x, y, r - w / 2, hole=True)
    def capsule(self, x1, y1, x2, y2, w):
        (ax, ay), (bx, by) = self.pt(x1, y1), self.pt(x2, y2)
        h = w * self.k / 2
        dx, dy = bx - ax, by - ay
        L = math.hypot(dx, dy)
        nx, ny = -dy / L * h, dx / L * h
        self.d.append('M%s %s L%s %s A%s %s 0 0 0 %s %s L%s %s A%s %s 0 0 0 %s %s Z' % (
            fmt(ax + nx), fmt(ay + ny), fmt(bx + nx), fmt(by + ny), fmt(h), fmt(h), fmt(bx - nx), fmt(by - ny),
            fmt(ax - nx), fmt(ay - ny), fmt(h), fmt(h), fmt(ax + nx), fmt(ay + ny)))
    def polyline(self, pts, w, close=False):
        seq = list(pts) + ([pts[0]] if close else [])
        for (x1, y1), (x2, y2) in zip(seq, seq[1:]):
            self.capsule(x1, y1, x2, y2, w)
    def polygon(self, pts):
        p = [self.pt(x, y) for x, y in pts]
        # ensure counter-clockwise on screen: signed area in y-down coordinates is positive for clockwise
        area = sum((p[i][0] * p[(i + 1) % len(p)][1] - p[(i + 1) % len(p)][0] * p[i][1]) for i in range(len(p)))
        if area > 0:
            p.reverse()
        self.d.append('M' + ' L'.join('%s %s' % (fmt(x), fmt(y)) for x, y in p) + ' Z')
    def halfdisc(self, x, y, r):
        # the left half of a disc: the low flag's half jar
        (px, py), r = self.pt(x, y), r * self.k
        self.d.append('M%s %s A%s %s 0 0 0 %s %s Z' % (fmt(px), fmt(py - r), fmt(r), fmt(r), fmt(px), fmt(py + r)))
    def rrect_ring(self, x, y, wd, ht, rad, w):
        self._rrect(x - w / 2, y - w / 2, wd + w, ht + w, rad + w / 2, hole=False)
        self._rrect(x + w / 2, y + w / 2, wd - w, ht - w, max(rad - w / 2, 0.01), hole=True)
    def _rrect(self, x, y, wd, ht, rad, hole):
        k = self.k
        (px, py), rr = self.pt(x, y), rad * k
        W, H = wd * k, ht * k
        # corners as (line end, arc end): down the left side, along the bottom, up the right, back
        # along the top; counter-clockwise on screen for the outline, reversed for a hole
        edges = [((px, py + H - rr), (px + rr, py + H)), ((px + W - rr, py + H), (px + W, py + H - rr)),
                 ((px + W, py + rr), (px + W - rr, py)), ((px + rr, py), (px, py + rr))]
        start = (px, py + rr)
        if hole:
            # clockwise on screen: right along the top, down the right side, back along the bottom
            pts = [(px + rr, py), (px + W - rr, py), (px + W, py + rr), (px + W, py + H - rr), (px + W - rr, py + H),
                   (px + rr, py + H), (px, py + H - rr), (px, py + rr)]
            d = 'M%s %s' % (fmt(pts[0][0]), fmt(pts[0][1]))
            for i in range(1, 8):
                verb = ' L%s %s' if i % 2 == 1 else ' A%s %s 0 0 1 %%s %%s' % (fmt(rr), fmt(rr))
                d += verb % (fmt(pts[i][0]), fmt(pts[i][1]))
            d += ' A%s %s 0 0 1 %s %s Z' % (fmt(rr), fmt(rr), fmt(pts[0][0]), fmt(pts[0][1]))
            self.d.append(d)
            return
        d = 'M%s %s' % (fmt(start[0]), fmt(start[1]))
        for line_end, arc_end in edges:
            d += ' L%s %s A%s %s 0 0 0 %s %s' % (fmt(line_end[0]), fmt(line_end[1]), fmt(rr), fmt(rr), fmt(arc_end[0]), fmt(arc_end[1]))
        self.d.append(d + ' Z')
    def arc_dash(self, x, y, rx, ry, a1, a2, w):
        # a round-capped stroke along an ellipse from angle a1 to a2 (degrees, screen orientation)
        k = self.k
        (px, py) = self.pt(x, y)
        h = w * k / 2
        def at(r_x, r_y, a):
            return (px + r_x * k * math.cos(math.radians(a)), py + r_y * k * math.sin(math.radians(a)))
        o1, o2 = at(rx + w / 2, ry + w / 2, a1), at(rx + w / 2, ry + w / 2, a2)
        i1, i2 = at(rx - w / 2, ry - w / 2, a1), at(rx - w / 2, ry - w / 2, a2)
        large = 1 if abs(a2 - a1) > 180 else 0
        # outer arc backwards (a2 -> a1) keeps the loop counter-clockwise on screen
        self.d.append('M%s %s A%s %s 0 %d 0 %s %s A%s %s 0 0 0 %s %s A%s %s 0 %d 1 %s %s A%s %s 0 0 0 %s %s Z' % (
            fmt(o2[0]), fmt(o2[1]), fmt((rx + w / 2) * k), fmt((ry + w / 2) * k), large, fmt(o1[0]), fmt(o1[1]),
            fmt(h), fmt(h), fmt(i1[0]), fmt(i1[1]),
            fmt((rx - w / 2) * k), fmt((ry - w / 2) * k), large, fmt(i2[0]), fmt(i2[1]),
            fmt(h), fmt(h), fmt(o2[0]), fmt(o2[1])))
    def dashed_arc(self, x, y, rx, ry, a1, a2, n, w):
        span = (a2 - a1) / n
        for i in range(n):
            s = a1 + i * span
            self.arc_dash(x, y, rx, ry, s + span * 0.12, s + span * 0.62, w)

def draw(name, pen, w):
    """The 16-grid geometry of ICONS, outlined: w is the stroke width for this weight."""
    if name == 'have':
        pen.disc(8, 8, 4)
    elif name == 'low':
        pen.ring(8, 8, 4, w)
        pen.halfdisc(8, 8, 4)
    elif name == 'out':
        pen.polygon([(8, 3.2), (12.8, 8), (8, 12.8), (3.2, 8)])
    elif name == 'unknown':
        pen.dashed_arc(8, 8, 4.25, 4.25, -90, 270, 6, w)
    elif name == 'open':
        pen.ring(8, 8, 4.25, w)
    elif name == 'done':
        pen.polyline([(3.5, 8.5), (6.6, 11.6), (12.5, 5)], w)
    elif name == 'home':
        pen.polyline([(3, 7.6), (8, 3), (13, 7.6), (13, 12.3), (12.3, 13.3), (3.7, 13.3), (3, 12.3)], w, close=True)
        pen.capsule(11, 5.8, 11, 4, w)
    elif name == 'item':
        pen.rrect_ring(4.5, 5, 7, 8.5, 1.6, w)
        pen.capsule(5.5, 3, 10.5, 3, w)
    elif name == 'guest':
        pen.ring(8, 5.2, 2.4, w)
        pen.dashed_arc(8, 13.5, 4.7, 4.4, 180, 360, 4, w)
    return ' '.join(pen.d)

def template(name):
    guides, symbols = [], []
    line = '<line id="%s" x1="%s" y1="%s" x2="%s" y2="%s" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;"/>'
    for sc, (cap, base) in SCALES.items():
        guides.append(line % ('Capline-' + sc, 263, fmt(cap), 3036, fmt(cap)))
        guides.append(line % ('Baseline-' + sc, 263, fmt(base), 3036, fmt(base)))
    for wt, f in WEIGHTS.items():
        for sc, (cap, base) in SCALES.items():
            k = (base - cap) * 1.1 / 16
            cx, cy = COLUMNS[wt], (cap + base) / 2
            pen = Pen(cx, cy, k)
            d = draw(name, pen, 1.5 * f)
            v = '%s-%s' % (wt, sc)
            half = 8 * k
            guides.append(line % ('left-margin-' + v, fmt(cx - half), fmt(cap - 30), fmt(cx - half), fmt(base + 30)))
            guides.append(line % ('right-margin-' + v, fmt(cx + half), fmt(cap - 30), fmt(cx + half), fmt(base + 30)))
            symbols.append('  <g id="%s"><path d="%s"/></g>' % (v, d))
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" version="1.1" '
            'width="3300" height="2200" viewBox="0 0 3300 2200">\n'
            ' <g id="Notes">\n'
            '  <rect id="artboard" x="0" y="0" width="3300" height="2200" style="fill:white;opacity:1"/>\n'
            '  <text id="template-version" x="263" y="140" style="font-family:sans-serif;font-size:13px;">Template v.3.0</text>\n'
            '  <text id="descriptive-name" x="263" y="180" style="font-family:sans-serif;font-size:13px;">doma.%s</text>\n'
            ' </g>\n <g id="Guides">\n  ' % name + '\n  '.join(guides) +
            '\n </g>\n <g id="Symbols">\n' + '\n'.join(symbols) + '\n </g>\n</svg>\n')

XCASSETS = os.path.join(HERE, '..', '..', 'app', 'shared', 'Design', 'Symbols.xcassets')
os.makedirs(XCASSETS, exist_ok=True)
with open(os.path.join(XCASSETS, 'Contents.json'), 'w') as fh:
    fh.write('{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n')
for name in SYMBOLS:
    d = os.path.join(XCASSETS, 'doma.%s.symbolset' % name)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, 'Contents.json'), 'w') as fh:
        fh.write('{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  },\n  "symbols" : [\n    {\n'
                 '      "filename" : "doma.%s.svg",\n      "idiom" : "universal"\n    }\n  ]\n}\n' % name)
    with open(os.path.join(d, 'doma.%s.svg' % name), 'w') as fh:
        fh.write(template(name))
print('ok', len(ICONS), 'icons', len(SYMBOLS), 'symbols')
