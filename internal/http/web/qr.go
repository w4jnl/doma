package web

import "github.com/w4jnl/doma/internal/qr"

func qrSVG(text string) (string, error) { return qr.SVG(text) }
