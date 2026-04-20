# Windows source setup

Goal: a folder on the Windows PC (for this project, `C:\backup-src\` with a `dummy.txt`) reachable from the Ubuntu repo host via rsync over SSH, limited to read-only access.

## 1. Install WSL2 Ubuntu

```powershell
wsl --install -d Ubuntu
wsl --set-default-version 2
```

Reboot if prompted.

## 2. WSL2 networking

WSL2's default NAT'd networking makes the internal sshd unreachable from the LAN. Two ways to fix it:

- **Preferred (Windows 11 22H2+)** — add to `%USERPROFILE%\.wslconfig`:
  ```ini
  [wsl2]
  networkingMode=mirrored
  ```
  Then `wsl --shutdown` and restart. WSL now shares the host's LAN interface.

- **Fallback (older Windows)** — `netsh interface portproxy add v4tov4 listenport=2222 listenaddress=0.0.0.0 connectport=2222 connectaddress=$(wsl hostname -I)` on each boot. Brittle; worth automating with a scheduled task at boot.

(A fuller how-to is listed under **future work** in the README.)

## 3. Inside WSL: install and configure sshd

```bash
sudo apt-get update && sudo apt-get install -y openssh-server rsync
sudo sed -i -e 's/^#\?Port .*/Port 2222/' \
            -e 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' \
            -e 's/^#\?PermitRootLogin .*/PermitRootLogin no/' \
            /etc/ssh/sshd_config
sudo useradd -m -s /bin/bash backup
sudo mkdir -p /home/backup/.ssh && sudo chmod 700 /home/backup/.ssh
sudo chown -R backup:backup /home/backup/.ssh
sudo service ssh restart
```

## 4. Install the Ubuntu repo's public key

On the Ubuntu host, generate the keypair if you haven't:
```bash
sudo -u backup ssh-keygen -t ed25519 -f /home/backup/.ssh/id_backup_windows -N ''
sudo -u backup cat /home/backup/.ssh/id_backup_windows.pub
```

Paste the public key into `/home/backup/.ssh/authorized_keys` on the Windows side, prefixed exactly per [`ssh/authorized_keys.windows.example`](../ssh/authorized_keys.windows.example):

```
command="/usr/bin/rrsync -ro /mnt/c/backup-src",restrict ssh-ed25519 AAA... backup@ubuntu-vm
```

The `command=` jail ensures the key can only run rrsync rooted at `/mnt/c/backup-src`, regardless of what the client attempts.

## 5. Populate the folder

On the Windows side, create `C:\backup-src\dummy.txt` with any content. WSL sees it as `/mnt/c/backup-src/dummy.txt`.

## 6. Smoke test from Ubuntu

```bash
sudo -u backup ssh -i /home/backup/.ssh/id_backup_windows -p 2222 backup@windows-pc rsync
# Expect rsync usage/help — the rrsync jail rejects anything else.
sudo -u backup /usr/local/bin/backup windows-pc
ls /srv/backups/windows-pc/
```

You should see a timestamped snapshot directory containing `dummy.txt` and a `MANIFEST.sha256`.
