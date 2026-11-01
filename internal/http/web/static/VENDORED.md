# Vendored files

| file | source | licence |
| --- | --- | --- |
| `tokens.css` | `docs/design-system/tokens.css` in this repo, generated from `tokens.json` | copied verbatim by `make generate`; a test fails when it drifts |
| `fonts/*.woff2`, `fonts/OFL.txt` | `docs/design-system/fonts/` (JetBrains Mono) | SIL Open Font License 1.1, copied verbatim |
| `favicon.svg`, `favicon-alert.svg`, `doma-mark.svg` | `assets/brand/` | copied verbatim |
| `doma-icons.svg` | `assets/icons/`, the pictogram sprite inlined in the layout | copied verbatim |
| `doma.css` | hand-written here, the `dm-*` classes over `tokens.css` | |
| `htmx.min.js` | https://unpkg.com/htmx.org@2.0.4/dist/htmx.min.js | 2.0.4, sha256 e209dda5c8235479f3166defc7750e1dbcd5a5c1808b7792fc2e6733768fb447; Zero-Clause BSD, `htmx-LICENSE.txt` |

Nothing here is loaded from a CDN; the binary embeds this directory.
