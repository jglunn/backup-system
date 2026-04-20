#!/usr/bin/env bash
#
# backup-hook.sh — invoked on the Raspberry Pi via the hook SSH key to start
# or stop the Docker stack during a backup window. Install at
# /usr/local/sbin/backup-hook.sh (owned root:root, mode 0755).
#
# Hardens a trivial command-whitelist: the only strings accepted as
# $SSH_ORIGINAL_COMMAND are "start" and "stop". Anything else exits 2 and is
# logged to the system journal so tampering attempts are visible.
#
# Paired with:
#   - ssh/authorized_keys.pi-hook.example
#   - ssh/sudoers.pi.example (NOPASSWD for exactly `docker compose -f <stack> {stop,start}`)

set -Eeuo pipefail

COMPOSE_FILE=${COMPOSE_FILE:-/home/pi/stack/compose.yml}

log() { logger -t backup-hook -- "$*"; printf '%s\n' "$*"; }

cmd=${SSH_ORIGINAL_COMMAND:-}
case "$cmd" in
    stop)
        log "stopping stack: $COMPOSE_FILE"
        exec sudo /usr/bin/docker compose -f "$COMPOSE_FILE" stop
        ;;
    start)
        log "starting stack: $COMPOSE_FILE"
        exec sudo /usr/bin/docker compose -f "$COMPOSE_FILE" start
        ;;
    *)
        log "rejected command: $cmd"
        exit 2
        ;;
esac
