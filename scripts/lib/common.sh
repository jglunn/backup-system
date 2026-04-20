# Shared helpers for backup scripts. Source this file from the top of each
# script — it does not produce side effects on its own.
#
#   source "$(dirname "$0")/lib/common.sh"
#
# Everything here is POSIX-ish bash; shellcheck-clean.

# shellcheck shell=bash

: "${BACKUP_ROOT:=/srv/backups}"
: "${BACKUP_CONFIG_DIR:=/etc/backup}"
: "${BACKUP_METRICS_DIR:=${BACKUP_ROOT}/metrics}"
: "${BACKUP_LOCK_DIR:=/var/lock}"

# ---------------------------------------------------------------- logging ---

log()  { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
warn() { log "WARN: $*" >&2; }
die()  {
    local rc=$?
    [[ $rc -eq 0 ]] && rc=1
    log "FATAL: $*" >&2
    # Best-effort failure metric so Grafana sees the failure even if the
    # script aborts mid-flight. Only fires for scripts that have loaded a
    # source config (NAME set) — otherwise we'd pollute the metrics dir with
    # backup_unknown.prom from unrelated error paths (e.g. verify-checksums).
    if [[ -n ${NAME:-} ]] && command -v write_metrics >/dev/null 2>&1; then
        write_metrics "$NAME" "$rc" "${BACKUP_DURATION:-0}" 0 0 || true
    fi
    exit "$rc"
}

# Install a trap that fires die() on any error. Call install_error_trap near
# the top of each script after sourcing this file.
install_error_trap() {
    set -Eeuo pipefail
    trap 'die "unhandled error on line $LINENO (cmd: $BASH_COMMAND)"' ERR
}

# ----------------------------------------------------------------- config ---

# load_source_config <name>
#   Reads $BACKUP_CONFIG_DIR/sources/<name>.conf (or, if that is missing, the
#   bundled repo copy at ./config/sources/<name>.conf for demo/CI use).
#   Populates: NAME, HOST, PORT, REMOTE_USER, KEY, SRC_PATH, RSYNC_OPTS,
#              EXCLUDE_FILE, PRE_CMD, POST_CMD, HOOK_KEY.
load_source_config() {
    local name=$1
    local candidates=(
        "${BACKUP_CONFIG_DIR}/sources/${name}.conf"
        "$(dirname "${BASH_SOURCE[0]}")/../../config/sources/${name}.conf"
    )
    local conf=""
    for c in "${candidates[@]}"; do
        [[ -r $c ]] && { conf=$c; break; }
    done
    [[ -n $conf ]] || die "no config found for source '$name' (tried: ${candidates[*]})"

    # Reset so values from a previous source do not leak in. These are
    # consumed by backup.sh after the function returns — shellcheck can't
    # see that, hence the disable.
    # shellcheck disable=SC2034
    {
        NAME=""; HOST=""; PORT=22; REMOTE_USER=""; KEY=""
        SRC_PATH="./"; RSYNC_OPTS=""; EXCLUDE_FILE=""
        PRE_CMD=""; POST_CMD=""; HOOK_KEY=""
    }

    # shellcheck disable=SC1090
    source "$conf"

    [[ -n $NAME        ]] || die "$conf: NAME unset"
    [[ -n $HOST        ]] || die "$conf: HOST unset"
    [[ -n $REMOTE_USER ]] || die "$conf: REMOTE_USER unset"
    [[ -n $KEY         ]] || die "$conf: KEY unset"
    log "loaded config for '$NAME' from $conf"
}

# ------------------------------------------------------------------ locks ---

# acquire_lock <name>
#   flock(1) on /var/lock/backup-<name>.lock — prevents two concurrent runs
#   for the same source. Held until the script exits.
acquire_lock() {
    local name=$1
    local lockfile="${BACKUP_LOCK_DIR}/backup-${name}.lock"
    exec 9>"$lockfile" || die "cannot open lockfile $lockfile"
    if ! flock -n 9; then
        die "another backup-$name run appears to be in progress (lock: $lockfile)"
    fi
}

# ---------------------------------------------------------------- metrics ---

# write_metrics <name> <exit_code> <duration_s> <bytes> <files>
#   Emits a Prometheus textfile-collector file for node_exporter to scrape.
#   Writes atomically via tmp + rename so node_exporter never reads partial.
#   On a clean run, also advances backup_last_success_timestamp_seconds.
#   Does NOT touch checksum metrics — see write_checksum_metric.
write_metrics() {
    local name=$1 rc=$2 duration=$3 bytes=$4 files=$5
    mkdir -p "$BACKUP_METRICS_DIR"
    local out="${BACKUP_METRICS_DIR}/backup_${name}.prom"
    local tmp="${out}.$$.tmp"
    local now; now=$(date +%s)

    # Preserve the previous success timestamp on failure — without this, a
    # failed run would make BackupStale look healthy (last_success = now).
    local last_success=$now
    if [[ $rc -ne 0 && -r $out ]]; then
        last_success=$(awk '/^backup_last_success_timestamp_seconds/ {print $2}' "$out" | tail -n1)
        [[ -n $last_success ]] || last_success=0
    fi

    {
        printf '# HELP backup_last_success_timestamp_seconds Unix time of last successful backup run.\n'
        printf '# TYPE backup_last_success_timestamp_seconds gauge\n'
        printf 'backup_last_success_timestamp_seconds{source="%s"} %s\n' "$name" "$last_success"

        printf '# HELP backup_last_run_timestamp_seconds Unix time of last backup attempt (success or fail).\n'
        printf '# TYPE backup_last_run_timestamp_seconds gauge\n'
        printf 'backup_last_run_timestamp_seconds{source="%s"} %s\n' "$name" "$now"

        printf '# HELP backup_last_exit_code Exit code of last backup run (0 = success).\n'
        printf '# TYPE backup_last_exit_code gauge\n'
        printf 'backup_last_exit_code{source="%s"} %s\n' "$name" "$rc"

        printf '# HELP backup_last_duration_seconds Wall-clock duration of last backup run.\n'
        printf '# TYPE backup_last_duration_seconds gauge\n'
        printf 'backup_last_duration_seconds{source="%s"} %s\n' "$name" "$duration"

        printf '# HELP backup_last_bytes_transferred Bytes pulled during last backup run.\n'
        printf '# TYPE backup_last_bytes_transferred gauge\n'
        printf 'backup_last_bytes_transferred{source="%s"} %s\n' "$name" "$bytes"

        printf '# HELP backup_last_files_count Number of files in last snapshot.\n'
        printf '# TYPE backup_last_files_count gauge\n'
        printf 'backup_last_files_count{source="%s"} %s\n' "$name" "$files"
    } >"$tmp"

    mv -f "$tmp" "$out"
    log "metrics written: $out (rc=$rc duration=${duration}s bytes=$bytes files=$files)"
}

# write_checksum_metric <name> <ok:0|1>
#   Updates only the checksum-verification gauge in a side-car .prom file.
#   Kept separate so verify-checksums.sh (which runs on its own cron) does
#   not overwrite backup-run metrics such as last_success_timestamp.
write_checksum_metric() {
    local name=$1 ok=$2
    mkdir -p "$BACKUP_METRICS_DIR"
    local out="${BACKUP_METRICS_DIR}/backup_${name}_checksum.prom"
    local tmp="${out}.$$.tmp"
    {
        printf '# HELP backup_checksum_verification Whether last sha256 verification of the latest snapshot passed (1/0).\n'
        printf '# TYPE backup_checksum_verification gauge\n'
        printf 'backup_checksum_verification{source="%s"} %s\n' "$name" "$ok"
        printf '# HELP backup_checksum_last_run_timestamp_seconds Unix time of last checksum verification.\n'
        printf '# TYPE backup_checksum_last_run_timestamp_seconds gauge\n'
        printf 'backup_checksum_last_run_timestamp_seconds{source="%s"} %s\n' "$name" "$(now_s)"
    } >"$tmp"
    mv -f "$tmp" "$out"
    log "checksum metric written: $out (source=$name ok=$ok)"
}

# ---------------------------------------------------------------- helpers ---

require_cmd() {
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
    done
}

# Seconds since epoch, portable.
now_s() { date +%s; }
