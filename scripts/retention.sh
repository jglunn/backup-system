#!/usr/bin/env bash
#
# retention.sh <target-dir>
#
# Prunes dated snapshot directories in <target-dir> using GFS-style rules:
#   - keep the $KEEP_DAILY   most recent snapshots outright
#   - additionally keep the $KEEP_WEEKLY  most recent snapshots that fall on Sunday
#   - additionally keep the $KEEP_MONTHLY most recent snapshots dated day=01
# Anything not matching any of those rules is removed (rm -rf).
#
# Snapshot dirs are expected to be named like `YYYY-MM-DDTHHMMZ`, produced by
# backup.sh. The `current` symlink and any non-matching files are left alone.

set -Eeuo pipefail

: "${KEEP_DAILY:=7}"
: "${KEEP_WEEKLY:=4}"
: "${KEEP_MONTHLY:=6}"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$SELF_DIR/lib/common.sh"

[[ $# -eq 1 ]] || { echo "usage: retention.sh <target-dir>" >&2; exit 2; }
TARGET=$1
[[ -d $TARGET ]] || { echo "retention: not a directory: $TARGET" >&2; exit 2; }

cd "$TARGET"

# Gather snapshot dirs newest-first. The ISO-8601 stamp sorts correctly as a
# string, so no date math is required for ordering.
mapfile -t ALL < <(find . -maxdepth 1 -mindepth 1 -type d \
    -regextype posix-extended \
    -regex '\./[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{4}Z' \
    -printf '%f\n' | sort -r)

if [[ ${#ALL[@]} -eq 0 ]]; then
    log "retention: no snapshots in $TARGET, nothing to do"
    exit 0
fi

declare -A KEEP=()
daily=0; weekly=0; monthly=0

for stamp in "${ALL[@]}"; do
    # Extract YYYY-MM-DD from the stamp and compute day-of-week.
    date_only=${stamp%%T*}
    dow=$(date -d "$date_only" +%u 2>/dev/null || echo "")   # 1=Mon..7=Sun
    dom=${date_only##*-}

    if   (( daily   < KEEP_DAILY   )); then KEEP[$stamp]=1; daily=$((daily+1));
    elif [[ $dow == 7 ]] && (( weekly < KEEP_WEEKLY )); then
        KEEP[$stamp]=1; weekly=$((weekly+1))
    elif [[ $dom == 01 ]] && (( monthly < KEEP_MONTHLY )); then
        KEEP[$stamp]=1; monthly=$((monthly+1))
    fi
done

kept=0; pruned=0
for stamp in "${ALL[@]}"; do
    if [[ ${KEEP[$stamp]:-0} == 1 ]]; then
        kept=$((kept+1))
    else
        log "retention: pruning $TARGET/$stamp"
        rm -rf --one-file-system -- "$stamp"
        pruned=$((pruned+1))
    fi
done

log "retention: $TARGET — kept $kept, pruned $pruned (policy: ${KEEP_DAILY}d/${KEEP_WEEKLY}w/${KEEP_MONTHLY}m)"
