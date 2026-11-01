package main

import (
	"net/http"

	"github.com/w4jnl/doma/internal/client"
)

func newTestClient(base string, h *http.Client) (*client.Client, error) { return client.New(base, h) }
