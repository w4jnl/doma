# Changelog

User-facing changes per release, newest first. `scripts/release.sh` refuses to tag a version
that has no section here and uses the section as the GitHub release notes, so every release
updates this file first. Dates are the tag dates.

## Unreleased

- **The server skeleton.** `doma serve` with `-d`, `--config` and `--print-config`; `doma.toml`
  with `DOMA_*` overrides and `env:` references for secrets; JSON logs, colour in debug;
  `/healthz`. Nothing a family can use yet.
