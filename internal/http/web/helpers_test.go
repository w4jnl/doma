package web_test

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
)

type httptestRecorder = httptest.ResponseRecorder

func newRecorder() *httptest.ResponseRecorder { return httptest.NewRecorder() }

func newRequest(method, path string, form url.Values) *http.Request {
	var body string
	if form != nil {
		body = form.Encode()
	}
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	if form != nil {
		r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	return r
}
