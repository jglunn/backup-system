#!/usr/bin/env bash
#
# install.sh — idempotent bootstrap of the Ubuntu backup host.
#
# Creates the `backup` system user, /srv/backups and /etc/backup trees, drops
# the scripts under /usr/local/bin, and installs the crontab under
# /etc/cron.d/. Safe to re-run after `git pull`.
#
# Run as root: sudo ./scripts/install.sh

set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "install.sh must be run as root" >&2; exit 1; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_USER=${BACKUP_USER:-backup}

log() { printf '[install] %s\n' "$*"; }

# ------------------------------------------------------------ apt packages -
log "installing apt packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq rsync openssh-client cron coreutils

# ------------------------------------------------------------ backup user --
if ! id -u "$BACKUP_USER" >/dev/null 2>&1; then
    log "creating system user: $BACKUP_USER"
    useradd --system --create-home --home-dir "/home/$BACKUP_USER" \
            --shell /bin/bash --user-group "$BACKUP_USER"
fi
install -d -o "$BACKUP_USER" -g "$BACKUP_USER" -m 0700 "/home/$BACKUP_USER/.ssh"

# ------------------------------------------------------- repository + conf -
log "ensuring /srv/backups, /etc/backup, /var/lock ownership"
install -d -o "$BACKUP_USER" -g "$BACKUP_USER" -m 0750 /srv/backups
install -d -o "$BACKUP_USER" -g "$BACKUP_USER" -m 0750 /srv/backups/metrics
install -d -o root           -g root           -m 0755 /etc/backup
install -d -o root           -g root           -m 0755 /etc/backup/sources
install -d -o root           -g root           -m 0755 /etc/backup/excludes

# Seed example configs (do not overwrite live ones)
for src in "$REPO_DIR"/config/sources/*.conf.example; do
    dest="/etc/backup/sources/$(basename "$src")"
    [[ -e $dest ]] || install -m 0644 "$src" "$dest"
done
for src in "$REPO_DIR"/config/excludes/*.txt.example; do
    dest="/etc/backup/excludes/$(basename "$src")"
    [[ -e $dest ]] || install -m 0644 "$src" "$dest"
done

# ------------------------------------------------------------ scripts -----
# We install thin shims under /usr/local/bin that exec the scripts in-place
# from the repo. This lets `git pull` update the scripts without re-running
# install.sh, and preserves SELF_DIR resolution for lib/common.sh.
log "installing /usr/local/bin shims pointing at $REPO_DIR/scripts"
for name in backup retention verify-checksums; do
    cat >"/usr/local/bin/$name" <<EOF
#!/usr/bin/env bash
exec "$REPO_DIR/scripts/${name}.sh" "\$@"
EOF
    chmod 0755 "/usr/local/bin/$name"
done

# ------------------------------------------------------------ cron --------
log "installing cron job to /etc/cron.d/backup"
install -m 0644 "$REPO_DIR/cron/backup.crontab" /etc/cron.d/backup

# ------------------------------------------------------------ summary ----
cat <<EOF

Install complete.

Next steps:
  1. Edit /etc/backup/sources/*.conf and fill in real hostnames + key paths.
  2. As the backup user, generate SSH keys and install public keys on the
     Windows and Pi hosts per the templates in ssh/authorized_keys.*.example.
  3. cd $REPO_DIR/monitoring && cp .env.example .env && \$EDITOR .env \\
        && docker compose up -d
  4. Run a manual test:  sudo -u $BACKUP_USER /usr/local/bin/backup windows-pc

See docs/setup-ubuntu.md for the full walkthrough.
EOF
