#!/usr/bin/env bash
#
# backup.sh <source-name>
#
# Generic backup driver. Loads $BACKUP_CONFIG_DIR/sources/<name>.conf, pulls
# into a new timestamped snapshot under $BACKUP_ROOT/<name>/, hardlinks
# unchanged files from the prior snapshot via rsync --link-dest, writes a
# SHA-256 manifest, atomically swings the `current` symlink, prunes old
# snapshots, and writes node_exporter textfile metrics.
#
# Intended to be invoked by cron as the unprivileged `backup` user.

set -Eeuo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$SELF_DIR/lib/common.sh"
install_error_trap

[[ $# -eq 1 ]] || die "usage: backup.sh <source-name>"
SOURCE_NAME=$1

require_cmd rsync ssh sha256sum find du flock

load_source_config "$SOURCE_NAME"
acquire_lock "$NAME"

TARGET="$BACKUP_ROOT/$NAME"
STAMP=$(date -u +%FT%H%MZ)
NEW="$TARGET/$STAMP"
CURRENT_LINK="$TARGET/current"

mkdir -p "$TARGET" "$BACKUP_METRICS_DIR"

START=$(now_s)
BACKUP_DURATION=0   # used by die() trap if we abort early

# ---- optional pre-hook (e.g. Pi: docker compose stop) ---------------------
if [[ -n $PRE_CMD ]]; then
    [[ -n $HOOK_KEY ]] || die "$NAME: PRE_CMD set but HOOK_KEY empty"
    log "running pre-hook: $PRE_CMD"
    ssh -i "$HOOK_KEY" -p "$PORT" \
        -o BatchMode=yes -o StrictHostKeyChecking=yes \
        "$REMOTE_USER@$HOST" "$PRE_CMD"
fi

# ---- rsync pull -----------------------------------------------------------
# --link-dest is evaluated relative to the destination dir, so "../current"
# resolves to $TARGET/current. On the first run the symlink doesn't exist
# yet — rsync skips link-dest silently and does a full pull.
log "rsync pull from $USER@$HOST:$SRC_PATH -> $NEW"
RSYNC_LOG=$(mktemp)

# $RSYNC_OPTS comes from the source config (e.g. "-aHAX --numeric-ids"); it
# must be word-split so each flag becomes its own argv entry. Same for the
# optional --exclude-from flag. shellcheck disables for this one invocation.
EXCLUDE_ARGS=()
[[ -n $EXCLUDE_FILE && -r $EXCLUDE_FILE ]] && EXCLUDE_ARGS=(--exclude-from="$EXCLUDE_FILE")

# shellcheck disable=SC2086
rsync $RSYNC_OPTS \
      --link-dest=../current \
      "${EXCLUDE_ARGS[@]}" \
      -e "ssh -i $KEY -p $PORT -o BatchMode=yes -o StrictHostKeyChecking=yes" \
      "$USER@$HOST:$SRC_PATH" "$NEW/" \
      >"$RSYNC_LOG" 2>&1 || {
        rc=$?
        warn "rsync failed (rc=$rc) — stderr/stdout:"
        cat "$RSYNC_LOG" >&2 || true
        BACKUP_DURATION=$(( $(now_s) - START ))
        exit "$rc"
      }
tail -n 5 "$RSYNC_LOG" | sed 's/^/  rsync: /'

# ---- optional post-hook (e.g. Pi: docker compose start) -------------------
if [[ -n $POST_CMD ]]; then
    log "running post-hook: $POST_CMD"
    ssh -i "$HOOK_KEY" -p "$PORT" \
        -o BatchMode=yes -o StrictHostKeyChecking=yes \
        "$REMOTE_USER@$HOST" "$POST_CMD"
fi

# ---- SHA-256 manifest ------------------------------------------------------
# Write to a tmp file first and rename — prevents a half-written manifest from
# being interpreted as valid by verify-checksums.sh if we crash mid-build.
log "building MANIFEST.sha256"
MANIFEST_TMP=$(mktemp)
(
    cd "$NEW"
    find . -type f -print0 \
        | LC_ALL=C sort -z \
        | xargs -0 sha256sum
) >"$MANIFEST_TMP"
mv -f "$MANIFEST_TMP" "$NEW/MANIFEST.sha256"
MANIFEST_FILES=$(wc -l < "$NEW/MANIFEST.sha256")

# ---- atomic symlink swap ---------------------------------------------------
# ln -sfn + mv -T is the standard trick for an atomic symlink rename on Linux
# (renameat2 under the hood). Readers of $CURRENT_LINK never see a missing
# link; they see either the old target or the new one.
ln -sfn "$STAMP" "$CURRENT_LINK.new"
mv -Tf "$CURRENT_LINK.new" "$CURRENT_LINK"
log "current -> $STAMP"

# ---- retention ------------------------------------------------------------
"$SELF_DIR/retention.sh" "$TARGET"

# ---- metrics --------------------------------------------------------------
BACKUP_DURATION=$(( $(now_s) - START ))
# du --apparent-size gives the logical (pre-hardlink) total, which is more
# useful than the on-disk delta for a "how big is this backup" panel.
BYTES=$(du -sb --apparent-size "$NEW" | awk '{print $1}')
write_metrics "$NAME" 0 "$BACKUP_DURATION" "$BYTES" "$MANIFEST_FILES"
# Manifest was just built from the on-disk tree, so by definition it matches.
# verify-checksums.sh will re-evaluate this gauge against the stored manifest
# on its own weekly schedule to catch post-backup bit-rot.
write_checksum_metric "$NAME" 1

rm -f "$RSYNC_LOG"
log "backup of '$NAME' complete in ${BACKUP_DURATION}s ($MANIFEST_FILES files, $BYTES bytes)"
