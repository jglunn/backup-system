#!/usr/bin/env bash
#
# verify-checksums.sh [source-name]
#
# Re-validates the MANIFEST.sha256 of the `current` snapshot for a source,
# detecting silent bit-rot. With no argument, iterates every source found
# under $BACKUP_ROOT.
#
# Emits backup_checksum_verification{source="…"} via write_checksum_metric.
# Returns non-zero if any source fails so that cron emails the operator.

set -Eeuo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$SELF_DIR/lib/common.sh"
install_error_trap

require_cmd sha256sum

verify_one() {
    local name=$1
    local snap="$BACKUP_ROOT/$name/current"
    if [[ ! -e $snap ]]; then
        warn "$name: no 'current' snapshot at $snap — skipping"
        write_checksum_metric "$name" 0
        return 1
    fi
    local manifest="$snap/MANIFEST.sha256"
    if [[ ! -r $manifest ]]; then
        warn "$name: no MANIFEST.sha256 inside $snap — marking failed"
        write_checksum_metric "$name" 0
        return 1
    fi

    log "$name: verifying $(wc -l <"$manifest") entries in $snap"
    if (cd "$snap" && sha256sum --quiet -c MANIFEST.sha256); then
        log "$name: checksum OK"
        write_checksum_metric "$name" 1
        return 0
    else
        warn "$name: checksum MISMATCH"
        write_checksum_metric "$name" 0
        return 1
    fi
}

sources=()
if [[ $# -ge 1 ]]; then
    sources=("$@")
else
    [[ -d $BACKUP_ROOT ]] || die "no $BACKUP_ROOT to scan"
    while IFS= read -r d; do
        [[ $d == metrics ]] && continue
        sources+=("$d")
    done < <(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d -printf '%f\n')
fi

[[ ${#sources[@]} -gt 0 ]] || { log "no sources to verify"; exit 0; }

failed=0
for s in "${sources[@]}"; do
    verify_one "$s" || failed=$((failed+1))
done

if (( failed > 0 )); then
    # Use warn+exit, not die, so we do not trigger die()'s write_metrics side
    # effect (which is backup-run-specific and would emit a bogus
    # backup_unknown.prom file).
    warn "$failed source(s) failed verification"
    exit 1
fi
log "all ${#sources[@]} source(s) verified OK"
