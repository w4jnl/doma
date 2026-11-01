"""Write tokens.css from tokens.json. tokens.json is the source of truth; run this after any change.

    python3 docs/design-system/tokens.py
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
t = json.load(open(os.path.join(HERE, 'tokens.json')))
col = t['color']['tokens']
size = t['size']['tokens']

def theme(th, indent='  '):
    return '\n'.join(f'{indent}--{c["name"]}: {c["value"][th]};' for c in col)

sizes = '\n'.join(f'  --{s["name"]}: {s["value"]};' for s in size)
css = f'''/* doma tokens, generated from tokens.json by tokens.py. Serve fonts/ next to this file (the server embeds both with embed.FS).
   Theme: follows the OS by default. data-theme="light" or "dark" forces one, on <html> or on any element.
   The apps mirror these values in app/shared/Design/Tokens.swift; a test keeps the two equal. */
@font-face {{ font-family: "JetBrains Mono"; src: url("fonts/JetBrainsMono-400.woff2") format("woff2"); font-weight: 400; font-display: swap; }}
@font-face {{ font-family: "JetBrains Mono"; src: url("fonts/JetBrainsMono-700.woff2") format("woff2"); font-weight: 700; font-display: swap; }}
@font-face {{ font-family: "JetBrains Mono"; src: url("fonts/JetBrainsMono-800.woff2") format("woff2"); font-weight: 800; font-display: swap; }}

:root {{
{sizes}
}}
:root, [data-theme="light"] {{
  color-scheme: light;
{theme("light")}
}}
@media (prefers-color-scheme: dark) {{
  :root:not([data-theme="light"]) {{
    color-scheme: dark;
{theme("dark", "    ")}
  }}
}}
[data-theme="dark"] {{
  color-scheme: dark;
{theme("dark")}
}}
/* touch: controls and chips grow to tap size */
@media (pointer: coarse) {{
  :root {{ --control-h: 44px; --chip-h: 32px; }}
}}
'''
with open(os.path.join(HERE, 'tokens.css'), 'w') as fh:
    fh.write(css)
print('ok')
