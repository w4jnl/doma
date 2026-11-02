#!/bin/sh
# A throwaway doma for the apps' UI and live tests: build the server, start it on a free port
# with a fresh data directory, run its setup page, create a household and an owner invite, write
# tmp/live.json for the tests, run the command given, and stop the server. The admin login is in
# the file too, so a test can mint its own invites.
#
#   scripts/ui-test.sh <command...>
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
PORT=${DOMA_UI_TEST_PORT:-$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')}
BASE="http://127.0.0.1:$PORT"
DIR=$(mktemp -d "${TMPDIR:-/tmp}/doma-ui-test.XXXXXX")
JAR="$DIR/jar"
LOGIN=j
PASSWORD='long enough password'

make build >/dev/null
DOMA_SERVER_LISTEN="127.0.0.1:$PORT" DOMA_SERVER_BASE_URL="$BASE" DOMA_DB_PATH="$DIR/doma.db" DOMA_LOG_FORMAT=json \
  bin/doma serve >"$DIR/server.log" 2>&1 &
PID=$!
stop() {
  kill "$PID" 2>/dev/null || true
  rm -f tmp/live.json
}
trap stop EXIT INT TERM

for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sf "$BASE/healthz" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -sf -c "$JAR" -o /dev/null -X POST "$BASE/setup" --data-urlencode "login=$LOGIN" --data-urlencode "password=$PASSWORD" --data-urlencode "confirm=$PASSWORD"
CSRF=$(curl -sf -b "$JAR" "$BASE/admin" | grep -oE 'name="_csrf" value="[^"]+"' | head -1 | sed 's/.*value="//; s/"//')
LOC=$(curl -sf -b "$JAR" -o /dev/null -w '%{redirect_url}' -X POST "$BASE/admin/households" --data-urlencode "_csrf=$CSRF" --data-urlencode 'name=De Vries' --data-urlencode 'timezone=Europe/Amsterdam' --data-urlencode 'home=Gouda')
HH=${LOC##*/}
TOKEN=$(curl -sf -b "$JAR" -X POST "$BASE/admin/h/$HH/invite" --data-urlencode "_csrf=$CSRF" | grep -oE '/i/[A-Za-z0-9_-]+' | head -1 | sed 's#/i/##')
mkdir -p tmp
printf '{"base_url":"%s","invite":"%s","household":"%s","admin":{"login":"%s","password":"%s"}}\n' "$BASE" "$TOKEN" "$HH" "$LOGIN" "$PASSWORD" > tmp/live.json
echo "ui-test: doma at $BASE, household $HH, log $DIR/server.log"

"$@"
