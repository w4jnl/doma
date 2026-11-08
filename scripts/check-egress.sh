#!/bin/sh
# Fails when Go code opens network connections anywhere but the three
# clients behind their switches: APNs (push.enabled), the vision model
# (vision.enabled) and logo.dev (logos.enabled); with all three off doma
# makes no outbound call at all. The allowlist names the places that dial.
set -eu

cd "$(dirname "$0")/.."

pattern='http\.Client{|http\.Get\(|http\.Post\(|http\.Head\(|http\.DefaultClient|http\.DefaultTransport|net\.Dial\(|net\.DialTimeout\(|tls\.Dial\(|tls\.Dialer\{|net\.Dialer\{|net\.LookupHost|net\.LookupIP|net\.LookupAddr|net\.DefaultResolver|smtp\.Dial\('

# file:reason — the code the gate accepts
allow='
internal/push/apns.go:the APNs client, built only when push.enabled is true
internal/vision/client.go:the vision model client, built only when vision.enabled is true
internal/logos/client.go:the logo.dev client, built only when logos.enabled is true
internal/client/client.go:the Go client of a doma server, used by tests and the e2e smoke
cmd/domaload/main.go:the load check, many Go clients of the doma under test
'

status=0
for f in $(grep -rlE "$pattern" --include='*.go' internal cmd 2>/dev/null | grep -v '_test\.go$' | sort); do
  if ! printf '%s\n' "$allow" | grep -q "^$f:"; then
    echo "egress gate: $f opens connections outside internal/push, internal/vision and internal/logos:" >&2
    grep -nE "$pattern" "$f" >&2
    status=1
  fi
done
for entry in $(printf '%s\n' "$allow" | grep -v '^$' | cut -d: -f1); do
  if [ -f "$entry" ] && ! grep -qE "$pattern" "$entry"; then
    echo "egress gate: allowlist entry $entry no longer matches; remove it" >&2
    status=1
  fi
done
if [ "$status" -ne 0 ]; then
  echo "egress gate failed: outbound connections belong in internal/push" >&2
  exit 1
fi
echo "egress gate ok"
