# doma — the build, test and release targets are added by the implementing agent per CLAUDE.md.
# This file starts with the one target the brand kit needs.

.PHONY: brand
brand: ## regenerate tokens.css, assets/brand and assets/icons (needs fontTools, brotli, cairosvg, playwright)
	python3 docs/design-system/tokens.py
	python3 assets/brand/gen.py
	python3 assets/brand/render.py
	python3 assets/icons/gen.py
