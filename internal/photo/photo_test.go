package photo

import (
	"bytes"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"testing"
)

// sample is a w by h JPEG with an APP1 segment carrying an Exif marker,
// as a phone would write it.
func sample(t *testing.T, w, h int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for x := range w {
		for y := range h {
			img.Set(x, y, color.RGBA{uint8(x), uint8(y), 128, 255})
		}
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, nil); err != nil {
		t.Fatal(err)
	}
	raw := buf.Bytes()
	exif := append([]byte{0xFF, 0xE1, 0x00, 0x10}, []byte("Exif\x00\x00secret-place")...)
	return append(append(append([]byte{}, raw[:2]...), exif...), raw[2:]...)
}

func TestProcess(t *testing.T) {
	cases := []struct {
		name           string
		w, h           int
		wantW, wantH   int
		thumbW, thumbH int
	}{
		{"small stays", 400, 300, 400, 300, 320, 240},
		{"wide shrinks to the edge", 3200, 2400, 1600, 1200, 320, 240},
		{"tall shrinks to the edge", 1000, 4000, 400, 1600, 80, 320},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			in := sample(t, c.w, c.h)
			if !bytes.Contains(in, []byte("secret-place")) {
				t.Fatal("the sample must carry metadata")
			}
			res, err := Process(bytes.NewReader(in))
			if err != nil {
				t.Fatal(err)
			}
			if res.Width != c.wantW || res.Height != c.wantH {
				t.Errorf("kept %dx%d, want %dx%d", res.Width, res.Height, c.wantW, c.wantH)
			}
			for name, b := range map[string][]byte{"full": res.Full, "thumb": res.Thumb} {
				if bytes.Contains(b, []byte("secret-place")) {
					t.Errorf("%s keeps the metadata", name)
				}
				cfg, err := jpeg.DecodeConfig(bytes.NewReader(b))
				if err != nil {
					t.Fatalf("%s is not a JPEG: %v", name, err)
				}
				if name == "thumb" && (cfg.Width != c.thumbW || cfg.Height != c.thumbH) {
					t.Errorf("thumb %dx%d, want %dx%d", cfg.Width, cfg.Height, c.thumbW, c.thumbH)
				}
			}
		})
	}
}

func TestProcessRefusesWhatIsNotAJPEG(t *testing.T) {
	var pngBuf bytes.Buffer
	_ = png.Encode(&pngBuf, image.NewRGBA(image.Rect(0, 0, 4, 4)))
	for name, in := range map[string][]byte{"png": pngBuf.Bytes(), "text": []byte("hello"), "empty": nil, "truncated": sample(t, 100, 100)[:60]} {
		if _, err := Process(bytes.NewReader(in)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}
