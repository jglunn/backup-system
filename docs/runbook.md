# Runbook — "my backup just failed"

Grafana fired an alert. This is the triage path.

## 1. Identify which alert and which source

Grafana email subject and body name the alert and source. Or check:
```bash
curl -s http://127.0.0.1:9090/api/v1/alerts | jq '.data.alerts[] | {name: .labels.alertname, source: .labels.source, state}'
```

## 2. Look at the metric files directly

```bash
cat /srv/backups/metrics/backup_<source>.prom
cat /srv/backups/metrics/backup_<source>_checksum.prom
```

`backup_last_exit_code` tells you if the last run failed; `backup_last_success_timestamp_seconds` tells you how far behind you are.

## 3. Look at the actual run log

Cron writes to syslog under tag `CRON`:
```bash
sudo journalctl -t CRON -S '24 hours ago' | less
```

The script itself also emits to stdout (captured by cron and mailed on non-empty output). For a live test run:
```bash
sudo -u backup /usr/local/bin/backup <source> 2>&1 | tee /tmp/backup.log
```

## 4. Alert-specific triage

### BackupFailed (`backup_last_exit_code != 0`)
- **rsync exit 23** — partial transfer, usually a permission issue on the source (a file couldn't be read). Check the log for the filename; add it to `config/excludes/` or fix permissions.
- **rsync exit 30** — timeout. Network flaky or source busy. Re-run manually.
- **rsync exit 12** — protocol error, often SSH-level. Validate: `sudo -u backup ssh -i <key> <host> rsync`.
- **"command not found: rrsync"** on source — install `rsync` (which provides rrsync) on the source.
- **sudo: a password is required** on Pi — sudoers rule missing or `!requiretty` forgotten. Re-check `/etc/sudoers.d/backup` against `ssh/sudoers.pi.example`.

### BackupStale
Backup hasn't succeeded in >26 h but metric is present → at least one past run worked. Likely a flaky source. Check last-success timestamp, reach out to the source host, re-run manually.

### BackupNeverRan
`absent(backup_last_run_timestamp_seconds)` — no metric file has ever been written. Causes:
- `node_exporter` container not mounting `/srv/backups/metrics` — `docker compose logs node_exporter`.
- `backup` user can't write `/srv/backups/metrics` — ownership; re-run `scripts/install.sh`.
- Cron job not installed — `cat /etc/cron.d/backup`.

### ChecksumMismatch
A file in the `current` snapshot no longer matches its MANIFEST.sha256. Possible causes:
- Disk bit-rot — run `smartctl -a /dev/sdX`, then restore the affected file from an earlier snapshot.
- Tampering — someone/something wrote into `/srv/backups/<source>/current/`. It should never be written to by anything but rsync; investigate.

To find the offending file:
```bash
cd /srv/backups/<source>/current
sha256sum -c MANIFEST.sha256 | grep -v ': OK$'
```

To restore from a prior snapshot:
```bash
cp -a /srv/backups/<source>/<older-stamp>/<path> /srv/backups/<source>/current/<path>
```
(Manually re-run `verify-checksums.sh` afterwards to clear the alert.)

### BackupDiskLow
```bash
df -h /srv/backups
du -sh /srv/backups/*/ | sort -h | tail -n 10
```

Quickest wins:
- Lower `KEEP_DAILY`/`KEEP_WEEKLY`/`KEEP_MONTHLY` in `cron/backup.crontab` env.
- Grow the filesystem.
- Identify a surprise volume on the Pi and add it to `config/excludes/pi.txt`.

## 5. Restoring a file

```bash
# pick any snapshot
ls /srv/backups/windows-pc/
cp /srv/backups/windows-pc/2026-04-19T0200Z/path/to/file /somewhere/
```

For Pi data (which used `--fake-super`), use `rsync --fake-super` on the way out if you need real UID/permissions restored:
```bash
rsync -aHAX --fake-super /srv/backups/raspberry-pi/2026-04-19T0215Z/<vol>/ root@pi:/var/lib/docker/volumes/<vol>/
```

## 6. Full disaster — Ubuntu host lost

This is file-level backup. There is no bare-metal restore. Rebuild Ubuntu, clone the repo, run `install.sh`, restore `/srv/backups/` from whatever off-site copy you hopefully set up (see the *Future work* section — off-site replication is v2).
