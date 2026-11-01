# doma: build, test and release targets. generate and migrate arrive with the schema (phase 0
# step 2), e2e with the smoke test (step 7), mac-* and ios-* with the apps.
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

.PHONY: build run test vet lint fmt check-tenancy check-egress release-check tools brand clean

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
