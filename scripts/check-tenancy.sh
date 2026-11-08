#!/bin/sh
# Fails when a query touches a household table without filtering on
# household_id. Every query on a household table carries the predicate in
# its WHERE clause. A query that is instance-wide by design (the snapshot
# job, the admin pages' counts) carries "-- tenancy: root" and is skipped.
set -eu

dir="$(dirname "$0")/../internal/db/queries"
[ -d "$dir" ] || { echo "tenancy gate: no queries yet"; exit 0; }

household_tables="memberships invites events snapshots homes spots items item_aliases lists entries flags staples photos trips push_log cards proposals"
status=0

for table in $household_tables; do
  for f in "$dir"/*.sql; do
    # one statement per "-- name:" block; a block is the text up to the next "-- name:"
    awk -v tbl="$table" -v file="$f" '
      /^-- name:/ { if (block != "") inspect(); block=""; name=$3 }
      { block = block "\n" $0 }
      END { if (block != "") inspect(); exit exit_code }
      function inspect() {
        lower = tolower(block)
        if (lower ~ /-- tenancy: root/) return
        if (lower ~ ("(from|update|into|join)[[:space:]]+" tbl "([[:space:]]|$|\\()") && lower !~ /household_id/) {
          printf "%s: %s touches %s without household_id\n", file, name, tbl
          exit_code = 1
        }
      }
    ' "$f" || status=1
  done
done

if [ "$status" -ne 0 ]; then
  echo "tenancy gate failed: add WHERE household_id = ? to the queries above" >&2
  exit 1
fi
echo "tenancy gate ok"
