package qr

import (
	"strings"
	"testing"
)

func TestSVG(t *testing.T) {
	svg, err := SVG("https://doma.example.com/i/abc")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(svg, "<svg viewBox=\"0 0 ") || !strings.Contains(svg, "fill=\"currentColor\"") || !strings.Contains(svg, "M") {
		t.Errorf("svg: %.80s", svg)
	}
}
