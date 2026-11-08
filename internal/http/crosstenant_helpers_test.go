package http_test

import (
	"archive/zip"
	"bytes"
	"compress/gzip"
	"io"
	"strconv"
	"testing"
)

func gzipReader(raw []byte) (io.Reader, error) { return gzip.NewReader(bytes.NewReader(raw)) }

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

// gunzipMaybe decodes a gzip body unless the transport already did.
func gunzipMaybe(raw []byte) []byte {
	if len(raw) > 0 && raw[0] == '{' {
		return raw
	}
	r, err := gzipReader(raw)
	if err != nil {
		return raw
	}
	out, _ := io.ReadAll(r)
	return out
}

// zipEntry returns the named file of a zip, or "" when it is not there.
func zipEntry(t *testing.T, raw []byte, name string) string {
	t.Helper()
	zr, err := zip.NewReader(bytes.NewReader(raw), int64(len(raw)))
	if err != nil {
		t.Fatalf("zip: %v", err)
	}
	for _, f := range zr.File {
		if f.Name != name {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = rc.Close() }()
		b, err := io.ReadAll(rc)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	return ""
}
