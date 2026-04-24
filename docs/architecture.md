# Architecture

## Design tenets

1. **Simplicity** — plain rsync, plain cron, plain bash. No orchestrator, no message bus, no bespoke daemon. The operator can read every moving part in one sitting.
2. **Pull model** — Ubuntu is the only scheduler. The source hosts expose nothing except a locked-down SSH account. This keeps blast radius tight: a compromised source cannot write to the repository.
3. **One hop per transfer** — data only moves once, over SSH. No intermediate S3 bucket, no sync daemon, no VPN tunnel beyond what SSH already provides.
4. **Integrity is independent of transport** — rsync ensures bits land intact; `MANIFEST.sha256` stored inside each snapshot lets us re-prove integrity months later.
5. **Space efficient** — `rsync --link-dest` means unchanged files cost one inode, not one full copy. Disk use scales with churn, not total data.

## Data flow

For each `<source>` scheduled in `/etc/cron.d/backup`:

```
                ┌───────────────────────────── backup.sh <source> ────────────────────────────┐
cron  ──▶       │                                                                            │
                │ 1. load /etc/backup/sources/<source>.conf                                 │
                │ 2. flock /var/lock/backup-<source>.lock                                   │
                │ 3. [optional] ssh -i HOOK_KEY  <source> "$PRE_CMD"   (e.g. docker stop)   │
                │ 4. rsync ${RSYNC_OPTS} --link-dest=../current \                            │
                │         -e 'ssh -i KEY ...' source:SRC_PATH → repo/<stamp>/               │
                │ 5. [optional] ssh -i HOOK_KEY  <source> "$POST_CMD"  (e.g. docker start)  │
                │ 6. find repo/<stamp> -type f | xargs sha256sum > MANIFEST.sha256          │
                │ 7. ln -sfn <stamp> current.new && mv -Tf current.new current              │
                │ 8. retention.sh repo/                 # GFS prune                         │
                │ 9. write_metrics <source> 0 <dur> <bytes> <files>                         │
                └────────────────────────────────────────────────────────────────────────────┘
```

A separate weekly job runs `verify-checksums.sh` across every source and flips `backup_checksum_verification` to `0` on any mismatch, independent of whether the latest backup succeeded.

## Threat model

| Threat | Mitigation |
|---|---|
| Compromised source host deletes or tampers with backups | Source holds zero credentials to the repo. Its authorized_key is pinned to `rrsync -ro` (read-only), so even if the attacker owns the source, they cannot write back. |
| Compromised Ubuntu repo host | Same credentials permit reading sources only. Does not compound to source compromise. |
| Backup user runs as root | It does not. `--fake-super` stores owner/perm metadata in xattrs so ownership is preserved without write-as-root on receive. |
| Docker volumes read by an unprivileged backup user | `sudo rrsync -ro /var/lib/docker/volumes` on the Pi, authorised by a narrow `sudoers.d` rule. rrsync jails the allowed path; sudoers matches a literal string, not a glob. |
| Attacker on the network sniffs credentials | SSH with `StrictHostKeyChecking=yes` and pinned host keys. No plaintext protocols. |
| Bit-rot on repository disk | Weekly `sha256sum -c MANIFEST.sha256` produces an alert via Grafana. |
| Backup-time ransomware on a source encrypts a file and we rsync the encrypted version | Hardlink snapshots retain earlier unencrypted versions. Retention policy keeps 6 monthly snapshots. Not bulletproof, but buys recovery room. At-rest encryption + off-site copy are listed as v2 work. |
| Silent partial run leaves `current` pointing at an incomplete snapshot | `current` is swung only after rsync + manifest both succeed. The atomic `mv -T` means readers never see a broken or missing link. |
| Two overlapping cron runs for the same source | `flock -n` on `/var/lock/backup-<source>.lock` — second invocation exits fast with a clear log line. |

## What this is *not*

- A DR/bare-metal restore system — files only, no disk images.
- A high-availability backup cluster — single Ubuntu host.
- Encrypted at rest — see future work in the README.
- Off-site — v1 is single-site.
