#!/usr/bin/env bash
#
# demo-local.sh — end-to-end smoke test of the entire backup pipeline against
# a fake source on localhost. Run by CI and useful as a local sanity check.
#
# Exercises:
#   * backup.sh local-demo         (initial pull)
#   * backup.sh local-demo         (unchanged files — expect hardlink reuse)
#   * backup.sh local-demo         (modified file — expect divergence)
#   * verify-checksums.sh          (happy path, then corrupted snapshot)
#   * retention.sh                 (GFS pruning with a synthetic set)
#
# Requirements:
#   - openssh-server running on localhost:22
#   - current user can SSH to themselves with an ed25519 key (installed here)
#   - rsync, sha256sum on PATH
#
# All state lives under $BACKUP_DEMO_DIR (default /tmp/backup-demo) and is
# wiped at the start of each run. Your real ~/.ssh/authorized_keys gains one
# throwaway key line on first run; subsequent runs re-use it.

set -Eeuo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SELF_DIR/.." && pwd)"

export BACKUP_DEMO_DIR=${BACKUP_DEMO_DIR:-/tmp/backup-demo}
export BACKUP_ROOT="$BACKUP_DEMO_DIR/repo"
export BACKUP_CONFIG_DIR="$BACKUP_DEMO_DIR/unused-config"
export BACKUP_METRICS_DIR="$BACKUP_ROOT/metrics"
export BACKUP_LOCK_DIR="$BACKUP_DEMO_DIR"

# ------------------------------------------------------------- tiny asserts -
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }
step() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
assert_eq()     { if [[ $1 == "$2" ]]; then ok "$3 ($1)"; else bad "$3 (want '$2' got '$1')"; fi; }
assert_ne()     { if [[ $1 != "$2" ]]; then ok "$3 (differs)"; else bad "$3 (expected != $2, got $1)"; fi; }
assert_exists() { if [[ -e $1 ]]; then ok "exists: $1"; else bad "missing: $1"; fi; }
assert_contains() {
    if grep -q -F "$2" "$1"; then ok "$1 contains '$2'"
    else bad "$1 missing '$2'"; fi
}

inode_of() { stat -c '%i' "$1"; }

# --------------------------------------------------- environment preflight -
step "Preflight"
command -v rsync     >/dev/null || { echo "rsync missing" >&2; exit 2; }
command -v ssh       >/dev/null || { echo "ssh missing"   >&2; exit 2; }
command -v sha256sum >/dev/null || { echo "sha256sum missing" >&2; exit 2; }
command -v ssh-keygen>/dev/null || { echo "ssh-keygen missing" >&2; exit 2; }

# -------------------------------------------------- scratch dirs & src tree -
step "Resetting scratch dir $BACKUP_DEMO_DIR"
rm -rf "$BACKUP_DEMO_DIR"
mkdir -p "$BACKUP_DEMO_DIR/src" "$BACKUP_ROOT"
echo "hello from windows-pc" > "$BACKUP_DEMO_DIR/src/dummy.txt"
mkdir -p "$BACKUP_DEMO_DIR/src/nested"
echo "nested content" > "$BACKUP_DEMO_DIR/src/nested/deeper.txt"
head -c 4096 /dev/urandom > "$BACKUP_DEMO_DIR/src/random.bin"

# ---------------------------------------------------------- ssh prep -------
step "Generating throwaway SSH key and installing in authorized_keys"
ssh-keygen -q -t ed25519 -N '' -f "$BACKUP_DEMO_DIR/id_demo" -C "backup-demo@$(hostname)"

mkdir -p ~/.ssh && chmod 700 ~/.ssh
touch  ~/.ssh/authorized_keys ~/.ssh/known_hosts
chmod  600 ~/.ssh/authorized_keys ~/.ssh/known_hosts

PUB="$(cat "$BACKUP_DEMO_DIR/id_demo.pub")"
if ! grep -q -F "$PUB" ~/.ssh/authorized_keys; then
    echo "$PUB" >> ~/.ssh/authorized_keys
fi

# Pin 127.0.0.1's host key so StrictHostKeyChecking=yes works, then
# de-duplicate so repeat runs don't pile up lines.
ssh-keyscan -T 3 127.0.0.1 2>/dev/null >> ~/.ssh/known_hosts
awk '!seen[$0]++' ~/.ssh/known_hosts > ~/.ssh/known_hosts.$$ \
    && mv ~/.ssh/known_hosts.$$ ~/.ssh/known_hosts
chmod 600 ~/.ssh/known_hosts

step "Verifying sshd reachability"
if ! ssh -i "$BACKUP_DEMO_DIR/id_demo" -o BatchMode=yes -o StrictHostKeyChecking=yes \
        127.0.0.1 'echo reachable' >/dev/null 2>&1; then
    echo "ERROR: cannot ssh to 127.0.0.1 with demo key." >&2
    echo "       install and start openssh-server:" >&2
    echo "         sudo apt-get install -y openssh-server && sudo systemctl start ssh" >&2
    exit 2
fi
ok "ssh to localhost works"

# ---------------------------------------------------------- first run ------
step "Backup run #1 (initial)"
"$REPO_DIR/scripts/backup.sh" local-demo
SNAP1=$(readlink "$BACKUP_ROOT/local-demo/current")
SNAP1_PATH="$BACKUP_ROOT/local-demo/$SNAP1"
assert_exists "$SNAP1_PATH/dummy.txt"
assert_exists "$SNAP1_PATH/nested/deeper.txt"
assert_exists "$SNAP1_PATH/random.bin"
assert_exists "$SNAP1_PATH/MANIFEST.sha256"
METRICS="$BACKUP_METRICS_DIR/backup_local-demo.prom"
CHK_METRICS="$BACKUP_METRICS_DIR/backup_local-demo_checksum.prom"
assert_contains "$METRICS"     'backup_last_exit_code{source="local-demo"} 0'
# Checksum gauge is owned by verify-checksums.sh — not asserted here. The
# clean-path and failure-path assertions live further down in this script.

step "Manifest validates"
if (cd "$SNAP1_PATH" && sha256sum --quiet -c MANIFEST.sha256); then
    ok "sha256sum -c MANIFEST.sha256"
else
    bad "sha256sum -c MANIFEST.sha256"
fi

# ---------------------------------------------------------- second run ----
# No file changes → expect hardlink reuse between SNAP1 and SNAP2.
step "Backup run #2 (no changes — expect hardlinks)"
sleep 1   # second-precision stamps; one second is enough to force a new dir
"$REPO_DIR/scripts/backup.sh" local-demo
SNAP2=$(readlink "$BACKUP_ROOT/local-demo/current")
SNAP2_PATH="$BACKUP_ROOT/local-demo/$SNAP2"
assert_ne "$SNAP1" "$SNAP2" "new snapshot directory created"
I1=$(inode_of "$SNAP1_PATH/dummy.txt")
I2=$(inode_of "$SNAP2_PATH/dummy.txt")
assert_eq "$I1" "$I2" "dummy.txt hardlinked between snapshots"

# ---------------------------------------------------------- third run ----
step "Backup run #3 (modify one file — expect inode divergence)"
echo "hello from windows-pc — modified" > "$BACKUP_DEMO_DIR/src/dummy.txt"
sleep 1
"$REPO_DIR/scripts/backup.sh" local-demo
SNAP3=$(readlink "$BACKUP_ROOT/local-demo/current")
SNAP3_PATH="$BACKUP_ROOT/local-demo/$SNAP3"
I1_POST=$(inode_of "$SNAP1_PATH/dummy.txt")
I3=$(inode_of "$SNAP3_PATH/dummy.txt")
assert_eq "$I1_POST" "$I1" "earlier snapshot still has original inode"
assert_ne "$I1" "$I3"       "modified file has new inode in latest snapshot"
assert_contains "$SNAP1_PATH/dummy.txt" "hello from windows-pc"
assert_contains "$SNAP3_PATH/dummy.txt" "modified"

# random.bin unchanged should still be hardlinked through to SNAP3
IR1=$(inode_of "$SNAP1_PATH/random.bin")
IR3=$(inode_of "$SNAP3_PATH/random.bin")
assert_eq "$IR1" "$IR3" "unchanged random.bin hardlinks survive through 3 runs"

# ------------------------------------------------ checksum verification ---
step "verify-checksums.sh on clean snapshot"
"$REPO_DIR/scripts/verify-checksums.sh" local-demo
assert_contains "$CHK_METRICS" 'backup_checksum_verification{source="local-demo"} 1'

step "verify-checksums.sh on corrupted snapshot (expect failure)"
# Break the hardlink so we don't mutate earlier snapshots, then replace with
# garbage of the same filename. Manifest still records the original hash.
rm -f "$SNAP3_PATH/dummy.txt"
echo "CORRUPTED_PAYLOAD" > "$SNAP3_PATH/dummy.txt"
if "$REPO_DIR/scripts/verify-checksums.sh" local-demo; then
    bad "verify should have failed on corrupted snapshot"
else
    ok "verify correctly reported failure"
fi
assert_contains "$CHK_METRICS" 'backup_checksum_verification{source="local-demo"} 0'

# Regression: backup.sh used to re-write the checksum gauge to 1 at the end of
# every run. Because the manifest is (re)built from the on-disk tree, that
# self-check is tautological — so a real verify-time mismatch would be
# silently cleared by the next backup. Fix: backup.sh no longer touches the
# gauge; verify-checksums.sh owns it.
step "backup after verify-failure keeps checksum gauge at 0"
sleep 1
"$REPO_DIR/scripts/backup.sh" local-demo
assert_contains "$CHK_METRICS" 'backup_checksum_verification{source="local-demo"} 0'

# Also check that no orphan snapshot dir was left by any of the runs above.
step "no .partial-* orphan dirs left behind"
ORPHANS=$(find "$BACKUP_ROOT/local-demo" -maxdepth 1 -type d -name '.partial-*' | wc -l)
assert_eq "$ORPHANS" "0" "no leftover .partial-* dirs under local-demo/"

# ---------------------------------------------------------- retention ----
step "retention.sh against synthetic dated dirs"
RETENTION_DIR="$BACKUP_DEMO_DIR/retention-test"
mkdir -p "$RETENTION_DIR"
# Seed 60 daily dirs going back two months so GFS has Sundays & 1sts to keep.
for n in $(seq 0 59); do
    stamp=$(date -u -d "$n days ago" +%FT0200Z)
    mkdir -p "$RETENTION_DIR/$stamp"
    echo seed > "$RETENTION_DIR/$stamp/file"
done
SEEDED=$(find "$RETENTION_DIR" -maxdepth 1 -mindepth 1 -type d | wc -l)
"$REPO_DIR/scripts/retention.sh" "$RETENTION_DIR"
KEPT=$(find "$RETENTION_DIR" -maxdepth 1 -mindepth 1 -type d | wc -l)
assert_eq "$SEEDED" "60" "seeded 60 dirs"
# Policy: 7d + up to 4w (Sundays) + up to 6m (1st) — some overlap possible.
# In a 60-day window we always have ≥4 Sundays and ≥2 month-firsts, so
# KEPT ∈ [9, 17]. Bound the check loosely.
if (( KEPT >= 9 && KEPT <= 17 )); then
    ok "retention kept $KEPT dirs (expected 9..17)"
else
    bad "retention kept $KEPT dirs, outside expected 9..17"
fi

# ---------------------------------------------------------- summary ------
step "Summary"
printf "  %d passed, %d failed\n" "$pass" "$fail"
if (( fail > 0 )); then exit 1; fi
echo "demo-local.sh: all checks passed"
