# Metrics

doma serves Prometheus metrics at `/metrics`. With `metrics.token` set (`DOMA_METRICS_TOKEN`),
only a request with `Authorization: Bearer <token>` is answered; without it the page is open to
anyone who can reach the server, so set the token on anything that faces the internet.

## Scrape

```yaml
scrape_configs:
  - job_name: doma
    scheme: https
    authorization:
      credentials: <the metrics token>
    static_configs:
      - targets: ["doma.example.com"]
```

`/healthz` says the process is up and answers with the version. `/readyz` answers 503 when the
database cannot take a write within two seconds or the snapshot job has not run in 36 hours,
once the process is older than that; point the container's or the proxy's health check at it.

## The collectors

| Name | Kind | Labels | What it says |
| --- | --- | --- | --- |
| `doma_households` | gauge | | households on this server |
| `doma_members{household}` | gauge | household | members and owners per household |
| `doma_events_total{household,kind}` | counter | household, kind | events appended |
| `doma_sync_requests_total{result}` | counter | result: `ok`, `not_found`, `error`, … | sync requests by outcome |
| `doma_sync_duration_seconds` | histogram | | sync request duration |
| `doma_push_total{result}` | counter | result | push attempts by outcome |
| `doma_photo_bytes{household}` | gauge | household | photo bytes stored |
| `doma_snapshot_age_seconds{household}` | gauge | household | age of the newest snapshot |
| `doma_db_write_duration_seconds` | histogram | | write transaction duration |
| `doma_build_info{version}` | gauge | version | always 1, the running version |

The test `TestCollectorsAsTheSpecNamesThem` holds these names and labels to the spec.

## A dashboard

One row of numbers, then the rates, then the health. Each query is one panel.

- Households: `doma_households`
- Members: `sum(doma_members)`
- Events in the last hour, by kind: `sum by (kind) (increase(doma_events_total[1h]))`
- Events per household today: `sum by (household) (increase(doma_events_total[24h]))`
- Sync requests per minute, by result: `sum by (result) (rate(doma_sync_requests_total[5m])) * 60`
- Sync p99: `histogram_quantile(0.99, sum by (le) (rate(doma_sync_duration_seconds_bucket[5m])))`
- Sync p50: `histogram_quantile(0.5, sum by (le) (rate(doma_sync_duration_seconds_bucket[5m])))`
- Write p99: `histogram_quantile(0.99, sum by (le) (rate(doma_db_write_duration_seconds_bucket[5m])))`
- Push failures per hour: `sum(increase(doma_push_total{result!="sent"}[1h]))`
- Photo storage per household: `doma_photo_bytes`
- Snapshot age per household: `doma_snapshot_age_seconds`
- Version: `doma_build_info`

## Alerts worth having

- Snapshot job stale: `max(doma_snapshot_age_seconds) > 36 * 3600` for 1h, the same threshold
  `/readyz` uses.
- Sync slow: p99 above 0.5 s for 15 min, well above the 50 ms the load test holds on a laptop.
- Sync erroring: `sum(rate(doma_sync_requests_total{result="error"}[5m])) > 0` for 10 min.
- Push failing: `sum(increase(doma_push_total{result!="sent"}[1h])) > 10`, when push is on.
- Scrape failing: `up{job="doma"} == 0` for 5 min.
