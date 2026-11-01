"""doma's pictograms: monoline icons on a 16-unit grid, 1.5 strokes, round caps and joins, drawn
in currentColor, as vink's state and kind glyphs are. One file per icon for docs and the asset
catalogue, one sprite (doma-icons.svg, <symbol id="i-<name>">) for the server's web pages, and
sheet.html for a look at all of them on both grounds.

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
print('ok', len(ICONS), 'icons')
