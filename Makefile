# doma: build, test and release targets. mac-* and ios-* arrive with the apps.
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

.PHONY: build run test vet lint fmt generate generate-check migrate e2e check-tenancy check-egress release-check tools brand clean \
	mac-project mac-build mac-test mac-run ios-project ios-build ios-test ios-device ios-testflight ui-test snapshots

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

# The end-to-end smoke: build the binary, start it, and walk a household from the setup page
# to a committed trip with the Go client.
e2e:
	go test -race -count=1 -tags e2e -v ./scripts/e2e/...

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

# The apps: app/ios and app/macos over app/shared (docs/design.md, "iPhone and Mac apps"), as
# nt's. XcodeGen writes the projects from project.yml; Local.xcconfig holds the team id for a
# device build and stays empty for the simulator and for a Mac build that runs here. Simulator
# builds are signed ad hoc, so the Keychain, which holds the device key, has the entitlement it
# asks for. Xcode 26 or later; brew install xcodegen.
MAC := app/macos
MAC_XCODEBUILD = cd $(MAC) && xcodebuild -project Doma.xcodeproj -scheme Doma -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData

mac-project:
	@[ -f $(MAC)/Local.xcconfig ] || printf 'DOMA_TEAM_ID =\n' > $(MAC)/Local.xcconfig
	cd $(MAC) && xcodegen generate --quiet

mac-build: mac-project
	$(MAC_XCODEBUILD) build -quiet

mac-test: mac-project
	$(MAC_XCODEBUILD) test -quiet

mac-run: mac-build
	open $(MAC)/build/DerivedData/Build/Products/Debug/doma.app

IOS := app/ios
IOS_SIM ?= platform=iOS Simulator,name=iPhone 17
IOS_XCODEBUILD = cd $(IOS) && xcodebuild -project Doma.xcodeproj -scheme Doma -configuration Debug -derivedDataPath build/DerivedData
# The App Store Connect API key in app/ios/Local.xcconfig (DOMA_ASC_KEY_ID, DOMA_ASC_ISSUER_ID)
# signs in for signing and uploads in place of Xcode's account; without one, Xcode's account is used.
ios_conf = $(shell sed -n 's/^$(1)[[:space:]]*=[[:space:]]*//p' $(IOS)/Local.xcconfig 2>/dev/null)
IOS_ASC_KEY_ID ?= $(call ios_conf,DOMA_ASC_KEY_ID)
IOS_ASC_ISSUER_ID ?= $(call ios_conf,DOMA_ASC_ISSUER_ID)
IOS_ASC_AUTH = $(if $(IOS_ASC_KEY_ID),-authenticationKeyPath '$(HOME)/.appstoreconnect/private_keys/AuthKey_$(IOS_ASC_KEY_ID).p8' -authenticationKeyID $(IOS_ASC_KEY_ID) -authenticationKeyIssuerID $(IOS_ASC_ISSUER_ID))

ios-project:
	@[ -f $(IOS)/Local.xcconfig ] || printf 'DOMA_TEAM_ID =\n' > $(IOS)/Local.xcconfig
	cd $(IOS) && xcodegen generate --quiet

ios-build: ios-project
	$(IOS_XCODEBUILD) -destination '$(IOS_SIM)' build CODE_SIGN_IDENTITY=- -quiet

ios-test: ios-project
	$(IOS_XCODEBUILD) -destination '$(IOS_SIM)' test CODE_SIGN_IDENTITY=- -collect-test-diagnostics never -quiet

# The UI tests and the live test against a throwaway doma that scripts/ui-test.sh starts, sets up
# and stops; it writes tmp/live.json for them.
ui-test: ios-project
	scripts/ui-test.sh sh -c "$(IOS_XCODEBUILD) -destination '$(IOS_SIM)' test -only-testing:DomaUITests -only-testing:DomaTests/LiveTests CODE_SIGN_IDENTITY=- -quiet"

# Record the snapshots of every screen, light and dark at two Dynamic Type sizes, on both
# platforms, into app/shared/Tests/Snapshots; make mac-test and make ios-test compare against them.
snapshots: ios-project mac-project
	@mkdir -p tmp && touch tmp/record-snapshots
	@rm -rf "$(HOME)/Library/Containers/nl.w4j.doma.mac/Data/tmp/doma-snapshots"
	@$(MAC_XCODEBUILD) test -only-testing:DomaTests/SnapshotTests -quiet || { rm -f tmp/record-snapshots; exit 1; }
	@mkdir -p app/shared/Tests/Snapshots/macos && cp "$(HOME)/Library/Containers/nl.w4j.doma.mac/Data/tmp/doma-snapshots/"*.png app/shared/Tests/Snapshots/macos/
	@$(IOS_XCODEBUILD) -destination '$(IOS_SIM)' test -only-testing:DomaTests/SnapshotTests CODE_SIGN_IDENTITY=- -collect-test-diagnostics never -quiet || { rm -f tmp/record-snapshots; exit 1; }
	@rm -f tmp/record-snapshots
	@ls app/shared/Tests/Snapshots/*/ | wc -l | xargs echo "snapshots:"

# Build, install and launch on the iPhone (unlocked; on a cable, or on Wi-Fi once paired), signed
# with Local.xcconfig's team. The first device devicectl lists as reachable is taken;
# IOS_DEVICE=<udid> picks one.
ios-device: ios-project
	@udid=$(IOS_DEVICE); [ -n "$$udid" ] || udid=$$(xcrun devicectl list devices 2>/dev/null | grep -v simulated | grep -E ' connected | available \(paired\) ' | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1); \
	[ -n "$$udid" ] || { echo "ios-device: no iPhone reachable: unlock it, on a cable or on the same Wi-Fi" >&2; exit 1; }; \
	$(IOS_XCODEBUILD) -destination "id=$$udid" -allowProvisioningUpdates -allowProvisioningDeviceRegistration $(IOS_ASC_AUTH) build -quiet && \
	xcrun devicectl device install app --device "$$udid" build/DerivedData/Build/Products/Debug-iphoneos/doma.app >/dev/null && \
	xcrun devicectl device process launch --terminate-existing --device "$$udid" nl.w4j.doma >/dev/null && echo "ios-device: installed and launched on $$udid"

# TestFlight: a Release archive, exported for App Store Connect and uploaded (ExportOptions.plist;
# Xcode raises the build number when the one in project.yml is taken). The app's record for
# nl.w4j.doma must exist in App Store Connect.
ios-testflight: ios-project
	@echo "ios-testflight: archiving and uploading $(IOS) (the key's ids stay out of the log)"
	@cd $(IOS) && rm -rf build/Doma.xcarchive build/export && \
	xcodebuild -project Doma.xcodeproj -scheme Doma -configuration Release -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData -archivePath build/Doma.xcarchive -allowProvisioningUpdates $(IOS_ASC_AUTH) archive -quiet && \
	xcodebuild -exportArchive -archivePath build/Doma.xcarchive -exportOptionsPlist ExportOptions.plist -exportPath build/export -allowProvisioningUpdates $(IOS_ASC_AUTH)

brand: ## regenerate tokens.css, assets/brand and assets/icons (needs fontTools, brotli, cairosvg, playwright)
	python3 docs/design-system/tokens.py
	python3 assets/brand/gen.py
	python3 assets/brand/render.py
	python3 assets/icons/gen.py

clean:
	rm -rf $(BIN)/doma tmp dist
