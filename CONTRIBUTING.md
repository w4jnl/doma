# Contributing

doma is a family's tool, built for one household and kept in the shape of its siblings flok,
vink and nt. Features are the ones the family needs; requests that do not fit will probably be
declined, politely.

What is welcome:

- Bug reports with a reproduction and the relevant lines of `doma serve -d`, secrets removed.
- Fixes with a test. Tests are table-driven, use `httptest` and a temporary SQLite file per
  test, and never mock the database. `make lint` (gofmt, vet, golangci-lint, the tenancy gate
  and the egress gate) and `make test` (`go test -race ./...`) must pass; `make e2e` after a
  change to the sync path or the fold.
- Small, focused pull requests. Describe what changed and what you verified, in plain words.

Before a larger change, open an issue and ask; it saves both of us a rewrite.

`docs/design.md` is the specification; ask before deviating from it. `docs/design-system/` is
the brand and UI rules, with `tokens.json` as the source of every colour, glyph and size. Every
query on a household table filters by `household_id`, and a request for another household's
resource is a 404. The fold under `internal/fold` is the only code that writes the materialised
tables from events; a change to it is a change to `docs/fixtures/fold.json` first, which the
Swift port under `app/` reads too. `CLAUDE.md` has the house conventions and the make targets.
