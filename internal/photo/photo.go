// Package photo turns an uploaded picture into what the server keeps: a
// JPEG re-encoded from the decoded pixels, so no metadata and no malformed
// structure survives, scaled to at most MaxEdge on its long side, and a
// Thumb-wide thumbnail. It is pure: bytes in, bytes out.
package photo

import (
	"bytes"
	"errors"
	"fmt"
	"image"
	"image/jpeg"
	"io"

	"golang.org/x/image/draw"
)

const (
	// MaxEdge is the long side the server keeps; the apps already send
	// 1600, a larger upload is scaled down.
	MaxEdge = 1600
	// ThumbEdge is the long side of the thumbnail.
	ThumbEdge = 320
	// Quality is the JPEG quality of both encodings.
	Quality = 80
	// maxPixels refuses a picture that would not fit in memory decoded.
	maxPixels = 40_000_000
)

// ErrNotJPEG is anything but a JPEG the decoder accepts.
var ErrNotJPEG = errors.New("not a JPEG")

// Result is the two encodings and the kept size.
type Result struct {
	Full, Thumb   []byte
	Width, Height int
}

// Process decodes r as a JPEG and returns the re-encoded picture and its
// thumbnail.
func Process(r io.Reader) (*Result, error) {
	raw, err := io.ReadAll(r)
	if err != nil {
		return nil, err
	}
	cfg, err := jpeg.DecodeConfig(bytes.NewReader(raw))
	if err != nil {
		return nil, fmt.Errorf("%w: %w", ErrNotJPEG, err)
	}
	if cfg.Width <= 0 || cfg.Height <= 0 || cfg.Width*cfg.Height > maxPixels {
		return nil, fmt.Errorf("%w: %dx%d is not a size this server keeps", ErrNotJPEG, cfg.Width, cfg.Height)
	}
	img, err := jpeg.Decode(bytes.NewReader(raw))
	if err != nil {
		return nil, fmt.Errorf("%w: %w", ErrNotJPEG, err)
	}
	full := Fit(img, MaxEdge)
	out := &Result{Width: full.Bounds().Dx(), Height: full.Bounds().Dy()}
	if out.Full, err = encode(full); err != nil {
		return nil, err
	}
	if out.Thumb, err = encode(Fit(full, ThumbEdge)); err != nil {
		return nil, err
	}
	return out, nil
}

// Fit scales img down so its long side is at most edge; a smaller picture
// is returned as is.
func Fit(img image.Image, edge int) image.Image {
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	long := max(w, h)
	if long <= edge {
		return img
	}
	if w >= h {
		h = max(1, h*edge/w)
		w = edge
	} else {
		w = max(1, w*edge/h)
		h = edge
	}
	dst := image.NewRGBA(image.Rect(0, 0, w, h))
	draw.CatmullRom.Scale(dst, dst.Bounds(), img, b, draw.Src, nil)
	return dst
}

func encode(img image.Image) ([]byte, error) {
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: Quality}); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
