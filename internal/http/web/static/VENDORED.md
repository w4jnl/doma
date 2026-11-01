# Vendored files

| file | source | licence |
| --- | --- | --- |
| `tokens.css` | `docs/design-system/tokens.css` in this repo, generated from `tokens.json` | copied verbatim by `make generate`; a test fails when it drifts |
| `fonts/*.woff2`, `fonts/OFL.txt` | `docs/design-system/fonts/` (JetBrains Mono) | SIL Open Font License 1.1, copied verbatim |
| `favicon.svg`, `favicon-alert.svg`, `doma-mark.svg` | `assets/brand/` | copied verbatim |
| `doma.css` | hand-written here, the `dm-*` classes over `tokens.css` | |

Nothing here is loaded from a CDN; the binary embeds this directory. htmx arrives with the
guest and admin pages.
