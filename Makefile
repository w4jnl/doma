# doma: build, test and release targets. e2e arrives with the smoke test (phase 0 step 7),
# mac-* and ios-* with the apps.
BIN        := $(CURDIR)/bin
VERSION    ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
COMMIT     ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo none)
DATE       ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
LDFLAGS    := -s -w -buildid= \
  -X github.com/w4jnl/doma/internal/version.Version=$(VERSION) \
  -X github.com/w4jnl/doma/internal/version.Commit=$(COMMIT) \
  -X github.com/w4jnl/doma/internal/version.Date=$(DATE)

SQLC_VERSION        := v1.31.1
GOLANGCI_VERSION    := v2.14.0
GORELEASER_VERSION  := v2.18.2

# Prefer the pinned tool in ./bin, fall back to PATH.
tool = $(shell test -x $(BIN)/$(1) && echo $(BIN)/$(1) || echo $(1))
SQLC       := $(call tool,sqlc)
GOLANGCI   := $(call tool,golangci-lint)
GORELEASER := $(call tool,goreleaser)

.PHONY: build run test vet lint fmt generate generate-check migrate check-tenancy check-egress release-check tools brand clean

build:
	CGO_ENABLED=0 go build -trimpath -ldflags "$(LDFLAGS)" -o $(BIN)/doma ./cmd/doma

# A throwaway server: the database and photos under tmp/data, the config in tmp/doma.toml.
run: build
	@mkdir -p tmp/data
	@test -f tmp/doma.toml || printf '[server]\nlisten = ":8080"\nbase_url = "http://localhost:8080"\n\n[db]\npath = "tmp/data/doma.db"\n' > tmp/doma.toml
	$(BIN)/doma serve -d --config tmp/doma.toml

test:
	go test -race ./...

vet:
	go vet ./...

lint: check-tenancy check-egress
	@unformatted="$$(gofmt -l ./cmd ./internal)"; if [ -n "$$unformatted" ]; then echo "gofmt:"; echo "$$unformatted"; exit 1; fi
	go vet ./...
	$(GOLANGCI) run

fmt:
	$(GOLANGCI) fmt

# sqlc from internal/db/queries over db/schema.sql, and the embedded copies: the event schema,
# tokens.css, the fonts and the marks the web pages serve.
generate:
	$(SQLC) generate
	cp docs/event-schema.json internal/events/event-schema.json
	cp docs/design-system/tokens.css internal/http/web/static/tokens.css
	cp docs/design-system/fonts/*.woff2 docs/design-system/fonts/OFL.txt internal/http/web/static/fonts/
	cp assets/brand/favicon.svg assets/brand/favicon-alert.svg assets/brand/doma-mark.svg internal/http/web/static/
	cp assets/icons/doma-icons.svg internal/http/web/static/doma-icons.svg

generate-check: generate
	git diff --exit-code -- internal/db internal/events/event-schema.json internal/http/web/static

# Apply the embedded migrations to a scratch database and dump db/schema.sql for sqlc.
migrate:
	go run ./internal/db/schemadump db/schema.sql

check-tenancy:
	@scripts/check-tenancy.sh

check-egress:
	@scripts/check-egress.sh

release-check:
	$(GORELEASER) check

tools:
	GOBIN=$(BIN) go install github.com/sqlc-dev/sqlc/cmd/sqlc@$(SQLC_VERSION)
	GOBIN=$(BIN) go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@$(GOLANGCI_VERSION)
	GOBIN=$(BIN) go install github.com/goreleaser/goreleaser/v2@$(GORELEASER_VERSION)
	GOBIN=$(BIN) go install golang.org/x/vuln/cmd/govulncheck@latest

brand: ## regenerate tokens.css, assets/brand and assets/icons (needs fontTools, brotli, cairosvg, playwright)
	python3 docs/design-system/tokens.py
	python3 assets/brand/gen.py
	python3 assets/brand/render.py
	python3 assets/icons/gen.py

clean:
	rm -rf $(BIN)/doma tmp dist
