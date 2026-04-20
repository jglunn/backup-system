# Raspberry Pi source setup

Goal: expose `/var/lib/docker/volumes/` to the Ubuntu repo over SSH, read-only, via a non-root `backup` user. A separate hook key can run `docker compose stop`/`start` around each backup to get crash-consistent snapshots.

## 1. Create the backup user

```bash
sudo useradd -m -s /bin/bash backup
sudo mkdir -p /home/backup/.ssh && sudo chmod 700 /home/backup/.ssh
sudo chown -R backup:backup /home/backup/.ssh
```

## 2. Install sudoers rule

Copy [`ssh/sudoers.pi.example`](../ssh/sudoers.pi.example) to the Pi and install:

```bash
sudo install -m 0440 -o root -g root sudoers.pi.example /etc/sudoers.d/backup
sudo visudo -c -f /etc/sudoers.d/backup       # validate
```

This grants `backup` NOPASSWD for exactly three commands:
- `/usr/bin/rrsync -ro /var/lib/docker/volumes`
- `/usr/bin/docker compose -f /home/pi/stack/compose.yml stop`
- `/usr/bin/docker compose -f /home/pi/stack/compose.yml start`

Nothing else. Adjust the compose-file path if your stack lives elsewhere.

## 3. Install the backup hook

Copy [`ssh/backup-hook.sh`](../ssh/backup-hook.sh) to the Pi:

```bash
sudo install -m 0755 -o root -g root backup-hook.sh /usr/local/sbin/backup-hook.sh
```

Override `COMPOSE_FILE` at the top of the script or via an environment variable set in the SSH session if your compose file lives elsewhere.

## 4. Install the two authorized_keys entries

On the Ubuntu host, generate the keys:

```bash
sudo -u backup ssh-keygen -t ed25519 -f /home/backup/.ssh/id_backup_pi      -N ''  # data pull
sudo -u backup ssh-keygen -t ed25519 -f /home/backup/.ssh/id_backup_pi_hook -N ''  # stop/start
```

On the Pi, append both public keys to `/home/backup/.ssh/authorized_keys`, each prefixed per the templates:

```
# /home/backup/.ssh/authorized_keys on the Pi
command="sudo /usr/bin/rrsync -ro /var/lib/docker/volumes",restrict ssh-ed25519 AAAA... backup-data@ubuntu-vm
command="/usr/local/sbin/backup-hook.sh",restrict                    ssh-ed25519 AAAA... backup-hook@ubuntu-vm
```

`chmod 600 /home/backup/.ssh/authorized_keys` and `chown backup:backup` it.

## 5. Smoke test

From the Ubuntu host:

```bash
# hook works:
sudo -u backup ssh -i /home/backup/.ssh/id_backup_pi_hook backup@raspberrypi 'stop'
sudo -u backup ssh -i /home/backup/.ssh/id_backup_pi_hook backup@raspberrypi 'start'
sudo -u backup ssh -i /home/backup/.ssh/id_backup_pi_hook backup@raspberrypi 'whoami'   # should be rejected

# data key works:
sudo -u backup /usr/local/bin/backup raspberry-pi
ls /srv/backups/raspberry-pi/
```

## 6. Consistency notes

The backup workflow calls `stop` → rsync → `start`. For most home stacks (Pi-hole, Home Assistant, Vaultwarden, a small Postgres) the stop/start window is sub-30 seconds and produces perfectly consistent on-disk state. If any service can't tolerate a nightly restart, either exclude its volume via `/etc/backup/excludes/pi.txt` and back it up with a service-level dump (e.g. `pg_dump`) instead, or run the backup during a dedicated maintenance window.
