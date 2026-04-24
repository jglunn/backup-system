# Monitoring

The stack is three containers: **node_exporter** (scrapes host + textfile metrics), **Prometheus** (stores them, evaluates alerts), and **Grafana** (dashboards + alert routing → SMTP).

All services bind to `127.0.0.1` on the host. There is no public attack surface; reach the UIs via SSH tunnel.

## Metrics emitted by the backup scripts

| Metric | Source | Notes |
|---|---|---|
| `backup_last_success_timestamp_seconds{source}` | `write_metrics` in `backup.sh` | Only advances on exit 0. Preserved across subsequent failures so `BackupStale` fires correctly. |
| `backup_last_run_timestamp_seconds{source}` | `write_metrics` | Advances on every run, success or fail. |
| `backup_last_exit_code{source}` | `write_metrics` | 0 = OK, anything else = failure. |
| `backup_last_duration_seconds{source}` | `write_metrics` | Wall-clock duration of the run. |
| `backup_last_bytes_transferred{source}` | `write_metrics` | `du --apparent-size` of the new snapshot — logical size, ignoring hardlink dedup. |
| `backup_last_files_count{source}` | `write_metrics` | Line count of `MANIFEST.sha256`. |
| `backup_checksum_verification{source}` | `write_checksum_metric` in `verify-checksums.sh` | 1 = manifest verified; 0 = mismatch. Only the weekly integrity job updates this — a fresh backup does not reset it, so a flagged mismatch keeps firing until verify runs again. |
| `backup_checksum_last_run_timestamp_seconds{source}` | `write_checksum_metric` | When the last verification ran. |

Everything else (capacity, load, memory) comes from stock node_exporter collectors.

## Alert rules

Defined canonically in [`monitoring/prometheus/alerts.yml`](../monitoring/prometheus/alerts.yml) and mirrored for Grafana-native evaluation in [`monitoring/grafana/provisioning/alerting/rules.yml`](../monitoring/grafana/provisioning/alerting/rules.yml).

| Alert | Fires when | `for` | Severity |
|---|---|---|---|
| `BackupStale` | `time() - backup_last_success_timestamp_seconds > 26h` | 10 min | warning |
| `BackupFailed` | `backup_last_exit_code != 0` | 1 min | critical |
| `BackupNeverRan` | `absent(backup_last_run_timestamp_seconds)` | 1 h | critical |
| `ChecksumMismatch` | `backup_checksum_verification == 0` | 5 min | critical |
| `BackupDiskLow` | `<15%` free on `/srv/backups` | 10 min | warning |

## SMTP contact point

Configured in [`monitoring/grafana/provisioning/alerting/contact-points.yml`](../monitoring/grafana/provisioning/alerting/contact-points.yml). Credentials come from `monitoring/.env` as `GF_SMTP_*`.

To change the recipient:
```yaml
# contact-points.yml
    settings:
      addresses: ops@example.com
```

Reload Grafana (`docker compose restart grafana`) to apply.

## Dashboard

[`backup-overview.json`](../monitoring/grafana/dashboards/backup-overview.json) — one dashboard with:

1. Per-source stat panels: last-success age, last exit code, checksum OK/FAIL
2. Time-series: last-run duration, snapshot size
3. Gauge + time-series: `/srv/backups` free space and usage
4. Per-source details table

A `source` dashboard variable is populated from `label_values(backup_last_run_timestamp_seconds, source)` so filtering to a single host is one click.

## Reloading after edits

- Prometheus config: `curl -X POST http://127.0.0.1:9090/-/reload`
- Grafana provisioning: `docker compose restart grafana` (provisioning is applied at startup)
- Dashboards under `dashboards/` auto-reload every 30 s

## Retention / backfill

Prometheus retains 90 days of data (`--storage.tsdb.retention.time=90d`). Adjust in `docker-compose.yml` if you want a longer window.
