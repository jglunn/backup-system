# Ubuntu VM setup (central repo)

The Ubuntu host is both the scheduler and the repository. Everything happens as the unprivileged `backup` user; root is used only for `install.sh` bootstrap.

## 1. Clone and bootstrap

```bash
sudo apt-get update && sudo apt-get install -y git
sudo git clone <repo-url> /opt/backup
sudo /opt/backup/scripts/install.sh
```

That creates:

- user `backup` with home `/home/backup`
- `/srv/backups/` (0750 backup:backup)
- `/etc/backup/sources/*.conf` (seeded from `.example` files)
- `/etc/backup/excludes/*.txt`
- `/usr/local/bin/backup`, `/usr/local/bin/retention`, `/usr/local/bin/verify-checksums` (shims pointing at `/opt/backup/scripts/*.sh`)
- `/etc/cron.d/backup` with daily runs and the weekly integrity job

## 2. Per-source SSH keys

```bash
sudo -u backup ssh-keygen -t ed25519 -f /home/backup/.ssh/id_backup_windows  -N ''
sudo -u backup ssh-keygen -t ed25519 -f /home/backup/.ssh/id_backup_pi       -N ''
sudo -u backup ssh-keygen -t ed25519 -f /home/backup/.ssh/id_backup_pi_hook  -N ''
```

Distribute the public keys to the source hosts per [docs/setup-windows.md](setup-windows.md) and [docs/setup-pi.md](setup-pi.md).

## 3. Pin host keys

```bash
sudo -u backup ssh-keyscan -p 2222 windows-pc.lan >> /home/backup/.ssh/known_hosts
sudo -u backup ssh-keyscan         raspberrypi.lan >> /home/backup/.ssh/known_hosts
sudo -u backup chmod 600 /home/backup/.ssh/known_hosts
```

Verify these against the fingerprints displayed on the source hosts — this is the step that binds the SSH connection to the right server.

## 4. Edit `/etc/backup/sources/*.conf`

Replace `windows-pc.lan`, `raspberrypi.lan`, port numbers, and paths with your reality. The fields are documented in each `.conf.example`.

## 5. Manual dry run

```bash
sudo -u backup /usr/local/bin/backup windows-pc
sudo -u backup /usr/local/bin/backup raspberry-pi
sudo -u backup /usr/local/bin/verify-checksums
```

Artifacts:
- Snapshots in `/srv/backups/<source>/YYYY-MM-DDTHHMMZ/`
- `current` symlink in each source dir
- `/srv/backups/metrics/backup_<source>.prom` and `backup_<source>_checksum.prom`

## 6. Stand up the monitoring stack

```bash
cd /opt/backup/monitoring
cp .env.example .env && $EDITOR .env   # set admin password + SMTP creds
docker compose up -d
```

Grafana is on `http://127.0.0.1:3000` — expose via SSH tunnel:

```bash
ssh -L 3000:127.0.0.1:3000 your-user@ubuntu-host
```

Log in as `admin`, password from `.env`, change it on first login. The **Backups / Backup Overview** dashboard is pre-provisioned. Alert rules and the SMTP contact point are provisioned in `grafana/provisioning/alerting/`.

## 7. Confirm cron is wired

```bash
sudo cat /etc/cron.d/backup
sudo systemctl status cron
sudo journalctl -t CRON -S today
```

## 8. End-to-end smoke test without real sources

If the Windows or Pi hosts aren't ready yet, the local demo exercises the entire pipeline against 127.0.0.1:

```bash
sudo apt-get install -y openssh-server
sudo systemctl enable --now ssh
cd /opt/backup && ./scripts/demo-local.sh
```

This is the same script CI runs on every push.
