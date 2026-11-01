package http_test

import (
	"bytes"
	"compress/gzip"
	"io"
	"strconv"
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
