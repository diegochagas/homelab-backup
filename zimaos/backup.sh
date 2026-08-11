#!/bin/sh
# Daily ZimaOS server-side backup - v2 (config-driven)
#
# Runs locally on the ZimaOS box:
#   1. Stops the app containers, mirrors SRC_APPDATA onto the external
#      drive (DST_APPDATA), restarts the containers.
#   2. Mirrors the whole external drive (SRC_DATA) onto the second
#      drive (DST_MIRROR).
#
# This is stage 1 of the backup chain; homelab-backup/backup.sh (stage 2,
# runs on Linux Mint) then pulls SRC_DATA's folders over SSH.
set -eu

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ ! -f "$SCRIPT_DIR/config.sh" ]; then
    echo "Missing $SCRIPT_DIR/config.sh - copy config.sh.example and adjust it." >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$SCRIPT_DIR/config.sh"

mkdir -p "$(dirname "$LOG")"

log() { echo "$(date '+%F %T') $1" >> "$LOG"; }

for p in "$SRC_APPDATA" "$SRC_DATA" "$DST_MIRROR"; do
  [ -d "$p" ] || { log "ABORT: $p missing - drive not mounted?"; exit 1; }
done
mountpoint -q "$SRC_DATA"   || { log "ABORT: $SRC_DATA not a mountpoint"; exit 1; }
mountpoint -q "$DST_MIRROR" || { log "ABORT: $DST_MIRROR not a mountpoint"; exit 1; }

mkdir -p "$DST_APPDATA"
log "=== Backup started ==="

restart_apps() { for c in $APPS; do docker start "$c" >> "$LOG" 2>&1 || true; done; }
trap restart_apps EXIT

for c in $APPS; do docker stop "$c" >> "$LOG" 2>&1 || true; done

rsync -a --delete "$SRC_APPDATA/" "$DST_APPDATA/" >> "$LOG" 2>&1
restart_apps
trap - EXIT

rsync -a --delete --exclude "$MIRROR_EXCLUDE" "$SRC_DATA/" "$DST_MIRROR/" >> "$LOG" 2>&1

log "=== Backup finished ==="
